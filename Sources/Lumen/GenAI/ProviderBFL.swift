import Foundation
import CoreGraphics
import ImageCratCore

/// Black Forest Labs API: `POST https://api.bfl.ai/v1/{endpoint}` (JSON, header `x-key`) → `{id, polling_url}`;
/// `GET polling_url` → `{status: Pending|Reasoning|Generating|Ready|Request Moderated|Content Moderated|Error|Task not found, result.sample}`.
/// Docs: https://docs.bfl.ai (OpenAPI https://api.bfl.ai/openapi.json), pricing https://docs.bfl.ai/quick_start/pricing
final class BFLProvider: GenerativeProvider {
    let id = ProviderID.bfl
    var base: String { GenHTTP.base(.bfl, "https://api.bfl.ai") }

    static func caps(_ mask: MaskKind, refs: Int = 0, edge: Int = 1024, mp: Double = 4) -> ProviderCapabilities {
        ProviderCapabilities(maxMegapixels: mp, minMegapixels: 0, minAspect: 0.25, maxAspect: 4, maxEdge: max(edge, 2048), preferredEdge: edge,
                             maskKind: mask, alphaOutput: false, maxReferenceImages: refs, maxImagesPerCall: 1, allowedSizes: nil, sizeMultiple: 16, async: true)
    }

    lazy var models: [GenModel] = [
        GenModel(provider: .bfl, model: "flux-pro-1.0-fill", name: "FLUX.1 Fill [pro]", features: [.fill, .sky, .background], caps: Self.caps(.grayWhiteEdit), pricePerImage: 0.05),
        GenModel(provider: .bfl, model: "flux-pro-1.0-expand", name: "FLUX.1 Expand [pro]", features: [.expand], caps: Self.caps(.grayWhiteEdit), pricePerImage: 0.05),
        GenModel(provider: .bfl, model: "flux-tools/erase-v1", name: "FLUX Tools Erase", features: [.remove], caps: Self.caps(.grayWhiteEdit), pricePerImage: 0.05),
        GenModel(provider: .bfl, model: "flux-kontext-pro", name: "FLUX.1 Kontext [pro]", features: [.promptEdit, .harmonize, .similar], caps: Self.caps(.none, refs: 3), pricePerImage: 0.04),
        GenModel(provider: .bfl, model: "flux-2-pro", name: "FLUX.2 [pro]", features: [.generateImage, .referenceFill, .similar, .promptEdit], caps: Self.caps(.none, refs: 7, mp: 4), pricePerImage: 0.03),
    ]

    static func b64(_ i: CGImage) -> String { GenHTTP.pngData(i).base64EncodedString() }

    func body(_ r: GenRequest, model: GenModel) throws -> [String: Any] {
        func need(_ i: CGImage?) throws -> CGImage { guard let i else { throw GenError.unsupported("\(model.name) needs an input image.") }; return i }
        var b: [String: Any] = ["output_format": "png"]
        switch model.model {
        case "flux-pro-1.0-fill":
            b["image"] = Self.b64(try need(r.image))
            if let m = r.mask { b["mask"] = GenImaging.encodeMask(m, kind: .grayWhiteEdit).base64EncodedString() }
            b["prompt"] = GenPrompts.text(r); b["steps"] = 50; b["guidance"] = 60; b["safety_tolerance"] = 2
        case "flux-pro-1.0-expand":
            b["image"] = Self.b64(try need(r.unpadded ?? r.image))
            b["top"] = min(2048, r.padding.top); b["bottom"] = min(2048, r.padding.bottom)
            b["left"] = min(2048, r.padding.left); b["right"] = min(2048, r.padding.right)
            if !r.prompt.isEmpty { b["prompt"] = r.prompt }
            b["steps"] = 50; b["guidance"] = 60; b["safety_tolerance"] = 2
        case "flux-tools/erase-v1":
            guard let m = r.mask else { throw GenError.noSelection }
            b["image"] = Self.b64(try need(r.image))
            b["mask"] = GenImaging.encodeMask(m, kind: .grayWhiteEdit).base64EncodedString()
            b["dilate_pixels"] = 10; b["safety_tolerance"] = 2
        case "flux-kontext-pro":
            b["prompt"] = GenPrompts.maskless(r)
            let imgs = ([r.image].compactMap { $0 } + (r.mask != nil && r.image != nil ? [r.mask!.makeCGImage()] : []) + r.references).prefix(4)
            for (i, img) in imgs.enumerated() { b[i == 0 ? "input_image" : "input_image_\(i + 1)"] = Self.b64(img) }
            if imgs.isEmpty { b["aspect_ratio"] = GenImaging.aspectString(r.width, r.height, allowed: ["21:9", "16:9", "4:3", "3:2", "1:1", "2:3", "3:4", "9:16", "9:21"]) }
            b["safety_tolerance"] = 2
        case "flux-2-pro":
            b["prompt"] = GenPrompts.maskless(r)
            let imgs = ([r.image].compactMap { $0 } + (r.mask != nil && r.image != nil ? [r.mask!.makeCGImage()] : []) + r.references).prefix(8)
            for (i, img) in imgs.enumerated() { b[i == 0 ? "input_image" : "input_image_\(i + 1)"] = Self.b64(img) }
            b["width"] = r.width; b["height"] = r.height; b["safety_tolerance"] = 2
        default:
            throw GenError.unsupported("Unknown BFL endpoint \(model.model)")
        }
        if let s = r.seed { b["seed"] = s }
        return b
    }

    func submit(_ r: GenRequest, model: GenModel, key: String) async throws -> GenJobHandle {
        let req = try GenHTTP.jsonRequest(try GenHTTP.url(base + "/v1/\(model.model)"), headers: ["x-key": key, "accept": "application/json"], body: try body(r, model: model))
        let json = try await GenHTTP.sendJSON(req, provider: .bfl)
        guard let jid = json["id"] as? String else { throw GenError.badResponse("missing id") }
        let poll = (json["polling_url"] as? String) ?? (base + "/v1/get_result?id=\(jid)")
        var extra: [String: String] = [:]
        if let c = json["cost"] as? Double { extra["cost"] = String(c) } else if let c = json["cost"] as? Int { extra["cost"] = String(c) }
        return .pending(PendingJob(id: jid, pollURL: try GenHTTP.url(poll), extra: extra))
    }

    func poll(_ job: PendingJob, model: GenModel, key: String) async throws -> PollState {
        var r = URLRequest(url: job.pollURL)
        r.setValue(key, forHTTPHeaderField: "x-key")
        r.setValue("application/json", forHTTPHeaderField: "accept")
        let json = try await GenHTTP.sendJSON(r, provider: .bfl)
        let status = json["status"] as? String ?? ""
        switch status {
        case "Ready":
            guard let res = json["result"] as? [String: Any], let sample = res["sample"] as? String else { throw GenError.badResponse("Ready without result.sample") }
            // signed delivery URL (expires ~10 min): no auth header
            var img = GenImage(image: try await GenHTTP.fetchImage(sample, provider: .bfl), seed: res["seed"] as? Int)
            // BFL reports cost in credits (1 credit = $0.01)
            let reported = job.extra["cost"].flatMap(Double.init).map { $0 * 0.01 }
            img.cost = reported ?? model.pricePerImage
            img.costReported = reported != nil
            return .done([img])
        case "Request Moderated", "Content Moderated":
            let d = (json["details"] as? [String: Any])?.values.flatMap { ($0 as? [String]) ?? ["\($0)"] }.joined(separator: ", ") ?? ""
            throw GenError.moderated("Black Forest Labs: \(status). \(d)")
        case "Error", "Task not found":
            throw GenError.badResponse("Black Forest Labs: \(status)")
        default:
            let p = (json["progress"] as? Double)
            return .pending(GenProgress(fraction: p.map { $0 > 1 ? $0 / 100 : $0 }, message: "BFL: \(status.isEmpty ? "pending" : status.lowercased())…"))
        }
    }

    func testKey(_ key: String) async throws -> String {
        var r = URLRequest(url: try GenHTTP.url(base + "/v1/credits"))
        r.setValue(key, forHTTPHeaderField: "x-key")
        let json = try await GenHTTP.sendJSON(r, provider: .bfl)
        let c = (json["credits"] as? Double) ?? Double(json["credits"] as? Int ?? 0)
        return String(format: "Key OK — %.0f credits (≈ $%.2f)", c, c * 0.01)
    }
}
