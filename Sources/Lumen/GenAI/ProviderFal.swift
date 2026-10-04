import Foundation
import CoreGraphics
import ImageCratCore

/// fal.ai queue API: `POST https://queue.fal.run/{model}` → `{request_id, status_url, response_url, cancel_url}`;
/// poll `status_url` (IN_QUEUE / IN_PROGRESS / COMPLETED), fetch `response_url`, cancel with `PUT cancel_url`.
/// Auth `Authorization: Key …`; `X-Fal-Store-IO: 0` when the user opts out of I/O storage. Images are sent as data URIs.
/// Docs: https://fal.ai/docs/documentation/model-apis/inference/queue , per-model OpenAPI at
/// https://fal.ai/api/openapi/queue/openapi.json?endpoint_id=<model>
final class FalProvider: GenerativeProvider {
    let id = ProviderID.fal
    var base: String { GenHTTP.base(.fal, "https://queue.fal.run") }

    static func caps(_ mask: MaskKind, n: Int, refs: Int = 0, edge: Int = 1024, mp: Double = 4, minMP: Double = 0) -> ProviderCapabilities {
        ProviderCapabilities(maxMegapixels: mp, minMegapixels: minMP, minAspect: 0.25, maxAspect: 4, maxEdge: max(edge, 2048), preferredEdge: edge,
                             maskKind: mask, alphaOutput: false, maxReferenceImages: refs, maxImagesPerCall: n, allowedSizes: nil, sizeMultiple: 16, async: true)
    }
    static let edit: Set<GenFeature> = [.fill, .expand, .remove, .promptEdit, .referenceFill, .harmonize, .similar, .background, .sky]

    lazy var models: [GenModel] = [
        GenModel(provider: .fal, model: "fal-ai/flux-pro/v1/fill", name: "FLUX.1 Pro Fill", features: [.fill, .expand, .remove, .sky, .background], caps: Self.caps(.grayWhiteEdit, n: 4), pricePerImage: 0.05),
        GenModel(provider: .fal, model: "fal-ai/nano-banana-2/edit", name: "Nano Banana 2 Edit", features: Self.edit, caps: Self.caps(.none, n: 4, refs: 13), pricePerImage: 0.08),
        GenModel(provider: .fal, model: "fal-ai/nano-banana-2", name: "Nano Banana 2", features: [.generateImage], caps: Self.caps(.none, n: 4), pricePerImage: 0.08),
        GenModel(provider: .fal, model: "openai/gpt-image-2.5/flare/edit", name: "GPT Image 2.5 Flare Edit (via fal)", features: Self.edit,
                 caps: Self.caps(.alphaTransparentEdit, n: 10, refs: 15, mp: 8.29, minMP: 0.656), pricePerImage: 0.053),
        GenModel(provider: .fal, model: "fal-ai/topaz/upscale/image", name: "Topaz Upscale", features: [.upscale], caps: Self.caps(.none, n: 1, edge: 4096, mp: 24), pricePerImage: 0.08),
        GenModel(provider: .fal, model: "fal-ai/topaz/upscale/image#denoise", name: "Topaz Denoise", features: [.denoise], caps: Self.caps(.none, n: 1, edge: 6000, mp: 24), pricePerImage: 0.08),
        GenModel(provider: .fal, model: "fal-ai/topaz/upscale/image#sharpen", name: "Topaz Sharpen", features: [.sharpen], caps: Self.caps(.none, n: 1, edge: 6000, mp: 24), pricePerImage: 0.08),
        GenModel(provider: .fal, model: "fal-ai/iclight-v2", name: "IC-Light v2 (relight)", features: [.harmonize], caps: Self.caps(.grayWhiteEdit, n: 4), pricePerImage: 0.1),
        GenModel(provider: .fal, model: "fal-ai/bria/eraser", name: "Bria Eraser", features: [.remove], caps: Self.caps(.grayWhiteEdit, n: 1, edge: 1536), pricePerImage: 0.04),
        GenModel(provider: .fal, model: "fal-ai/bria/background/replace", name: "Bria Background Replace", features: [.background], caps: Self.caps(.none, n: 4), pricePerImage: 0.04),
        GenModel(provider: .fal, model: "fal-ai/qwen-image-edit", name: "Qwen Image Edit", features: [.promptEdit], caps: Self.caps(.none, n: 4), pricePerImage: 0.03),
        GenModel(provider: .fal, model: "fal-ai/bytedance/seedream/v4/edit", name: "Seedream 4 Edit", features: [.promptEdit, .referenceFill, .similar], caps: Self.caps(.none, n: 4, refs: 9), pricePerImage: 0.03),
        GenModel(provider: .fal, model: "fal-ai/bytedance/seedream/v4/text-to-image", name: "Seedream 4", features: [.generateImage], caps: Self.caps(.none, n: 4), pricePerImage: 0.03),
    ]

    func headers(_ key: String, storeIO: Bool) -> [String: String] {
        var h = ["Authorization": "Key \(key)"]
        if !storeIO { h["X-Fal-Store-IO"] = "0" }
        return h
    }

    static let nanoAspects = ["21:9", "16:9", "3:2", "4:3", "5:4", "1:1", "4:5", "3:4", "2:3", "9:16"]

    func input(_ r: GenRequest, model: GenModel) throws -> [String: Any] {
        let endpoint = model.model.components(separatedBy: "#")[0]
        let variant = model.model.contains("#") ? model.model.components(separatedBy: "#")[1] : ""
        let n = max(1, min(model.caps.maxImagesPerCall, r.count))
        func need(_ i: CGImage?) throws -> CGImage { guard let i else { throw GenError.unsupported("\(model.name) needs an input image.") }; return i }
        var body: [String: Any] = [:]
        switch endpoint {
        case "fal-ai/flux-pro/v1/fill":
            body = ["prompt": GenPrompts.text(r), "image_url": GenHTTP.dataURI(png: try need(r.image)), "num_images": n, "output_format": "png", "safety_tolerance": "2"]
            if let m = r.mask { body["mask_url"] = "data:image/png;base64," + GenImaging.encodeMask(m, kind: .grayWhiteEdit).base64EncodedString() }
        case "fal-ai/nano-banana-2/edit":
            var urls: [String] = []
            if let i = r.image { urls.append(GenHTTP.dataURI(png: i)) }
            if let m = r.mask, r.image != nil { urls.append("data:image/png;base64," + GenImaging.encodeMask(m, kind: .grayWhiteEdit).base64EncodedString()) }
            urls += r.references.prefix(model.caps.maxReferenceImages).map { GenHTTP.dataURI(jpeg: $0) }
            if urls.isEmpty { throw GenError.unsupported("\(model.name) needs an input image.") }
            body = ["prompt": GenPrompts.maskless(r), "image_urls": urls, "num_images": n, "output_format": "png",
                    "resolution": r.quality == .high ? "2K" : "1K", "aspect_ratio": r.image == nil ? GenImaging.aspectString(r.width, r.height, allowed: Self.nanoAspects) : "auto"]
        case "fal-ai/nano-banana-2":
            body = ["prompt": GenPrompts.text(r), "num_images": n, "output_format": "png", "resolution": r.quality == .high ? "2K" : "1K",
                    "aspect_ratio": GenImaging.aspectString(r.width, r.height, allowed: Self.nanoAspects)]
        case "openai/gpt-image-2.5/flare/edit":
            var urls: [String] = []
            if let i = r.image { urls.append(GenHTTP.dataURI(png: i)) }
            urls += r.references.prefix(15).map { GenHTTP.dataURI(jpeg: $0) }
            if urls.isEmpty { throw GenError.unsupported("\(model.name) needs an input image.") }
            body = ["prompt": GenPrompts.text(r), "image_urls": urls, "num_images": n, "output_format": "png",
                    "quality": OpenAIProvider.quality(r.quality), "image_size": ["width": r.width, "height": r.height]]
            if let m = r.mask, r.image != nil { body["mask_url"] = "data:image/png;base64," + GenImaging.encodeMask(m, kind: .alphaTransparentEdit).base64EncodedString() }
        case "fal-ai/topaz/upscale/image":
            body = ["image_url": GenHTTP.dataURI(png: try need(r.image)), "output_format": "png", "model": "Standard V2"]
            switch variant {
            case "denoise": body["upscale_factor"] = 1; body["denoise"] = 0.6; body["sharpen"] = 0.0
            case "sharpen": body["upscale_factor"] = 1; body["sharpen"] = 0.6; body["denoise"] = 0.1
            default: body["upscale_factor"] = max(1, min(4, r.upscaleFactor)); if r.contentType == .art { body["model"] = "CGI" }
            }
        case "fal-ai/iclight-v2":
            body = ["prompt": GenPrompts.text(r).isEmpty ? "natural scene lighting" : GenPrompts.text(r), "image_url": GenHTTP.dataURI(png: try need(r.image)),
                    "num_images": n, "output_format": "png", "initial_latent": Self.latent(r.lightDirection)]
            if let m = r.mask { body["mask_image_url"] = "data:image/png;base64," + GenImaging.encodeMask(m, kind: .grayWhiteEdit).base64EncodedString() }
        case "fal-ai/bria/eraser":
            guard let m = r.mask else { throw GenError.noSelection }
            body = ["image_url": GenHTTP.dataURI(png: try need(r.image)), "mask_url": "data:image/png;base64," + GenImaging.encodeMask(m, kind: .grayWhiteEdit).base64EncodedString(), "mask_type": "manual"]
        case "fal-ai/bria/background/replace":
            body = ["image_url": GenHTTP.dataURI(png: try need(r.image)), "prompt": r.prompt.isEmpty ? "clean softly lit studio background" : r.prompt, "num_images": n]
            if let ref = r.references.first { body["ref_image_url"] = GenHTTP.dataURI(jpeg: ref) }
        case "fal-ai/qwen-image-edit":
            body = ["prompt": GenPrompts.text(r), "image_url": GenHTTP.dataURI(png: try need(r.image)), "num_images": n, "output_format": "png"]
        case "fal-ai/bytedance/seedream/v4/edit":
            var urls: [String] = []
            if let i = r.image { urls.append(GenHTTP.dataURI(png: i)) }
            urls += r.references.prefix(9).map { GenHTTP.dataURI(jpeg: $0) }
            if urls.isEmpty { throw GenError.unsupported("\(model.name) needs an input image.") }
            body = ["prompt": GenPrompts.maskless(r), "image_urls": urls, "num_images": n, "image_size": ["width": r.width, "height": r.height]]
        case "fal-ai/bytedance/seedream/v4/text-to-image":
            body = ["prompt": GenPrompts.text(r), "num_images": n, "image_size": ["width": r.width, "height": r.height]]
        default:
            throw GenError.unsupported("Unknown fal model \(model.model)")
        }
        if let s = r.seed, !endpoint.hasPrefix("fal-ai/topaz"), !endpoint.hasPrefix("fal-ai/bria/eraser") { body["seed"] = s }
        return body
    }

    static func latent(_ dir: String?) -> String {
        switch dir { case "left": return "Left"; case "right": return "Right"; case "above": return "Top"; case "below": return "Bottom"; default: return "None" }
    }

    func submit(_ r: GenRequest, model: GenModel, key: String) async throws -> GenJobHandle {
        let endpoint = model.model.components(separatedBy: "#")[0]
        let req = try GenHTTP.jsonRequest(try GenHTTP.url(base + "/" + endpoint), headers: headers(key, storeIO: r.storeIO), body: try input(r, model: model))
        let json = try await GenHTTP.sendJSON(req, provider: .fal)
        guard let rid = json["request_id"] as? String else { throw GenError.badResponse("missing request_id") }
        // Always use the URLs fal returns (they encode the right app path).
        let status = (json["status_url"] as? String) ?? (base + "/" + endpoint + "/requests/\(rid)/status")
        let resp = (json["response_url"] as? String) ?? (base + "/" + endpoint + "/requests/\(rid)")
        let cancel = (json["cancel_url"] as? String) ?? (resp + "/cancel")
        return .pending(PendingJob(id: rid, pollURL: try GenHTTP.url(status), cancelURL: URL(string: cancel), resultURL: URL(string: resp),
                                   extra: ["storeIO": r.storeIO ? "1" : "0"]))
    }

    func poll(_ job: PendingJob, model: GenModel, key: String) async throws -> PollState {
        let storeIO = job.extra["storeIO"] == "1"
        var comps = URLComponents(url: job.pollURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "logs", value: "1")]
        var r = URLRequest(url: comps.url!)
        for (k, v) in headers(key, storeIO: storeIO) { r.setValue(v, forHTTPHeaderField: k) }
        let st = try await GenHTTP.sendJSON(r, provider: .fal)
        let status = st["status"] as? String ?? ""
        switch status {
        case "IN_QUEUE":
            let pos = st["queue_position"] as? Int
            return .pending(GenProgress(fraction: nil, message: "fal: queued" + (pos.map { " (position \($0))" } ?? "")))
        case "IN_PROGRESS":
            let last = (st["logs"] as? [[String: Any]])?.last?["message"] as? String
            return .pending(GenProgress(fraction: nil, message: "fal: generating…" + (last.map { " \($0.prefix(60))" } ?? "")))
        case "COMPLETED":
            if let err = st["error"] as? String {
                if GenHTTP.looksModerated(err) || (st["error_type"] as? String)?.contains("content") == true { throw GenError.moderated(err) }
                throw GenError.badResponse(err)
            }
            guard let ru = job.resultURL else { throw GenError.badResponse("missing response_url") }
            var rr = URLRequest(url: ru)
            for (k, v) in headers(key, storeIO: storeIO) { rr.setValue(v, forHTTPHeaderField: k) }
            let out = try await GenHTTP.sendJSON(rr, provider: .fal)
            return .done(try await Self.parseOutput(out, cost: model.pricePerImage))
        default:
            return .pending(GenProgress(fraction: nil, message: "fal: \(status.isEmpty ? "waiting" : status)"))
        }
    }

    static func parseOutput(_ out: [String: Any], cost: Double) async throws -> [GenImage] {
        if let nsfw = out["has_nsfw_concepts"] as? [Bool], !nsfw.isEmpty, nsfw.allSatisfy({ $0 }) {
            throw GenError.moderated("fal's safety checker flagged the result.")
        }
        var urls: [String] = []
        if let imgs = out["images"] as? [[String: Any]] { urls += imgs.compactMap { $0["url"] as? String } }
        if let img = out["image"] as? [String: Any], let u = img["url"] as? String { urls.append(u) }
        if urls.isEmpty { throw GenError.badResponse("no images in fal output") }
        var res: [GenImage] = []
        for u in urls { res.append(GenImage(image: try await GenHTTP.fetchImage(u, provider: .fal), seed: out["seed"] as? Int)) }
        res[0].cost = cost * Double(res.count)
        return res
    }

    func cancel(_ job: PendingJob, model: GenModel, key: String) async {
        guard let u = job.cancelURL else { return }
        var r = URLRequest(url: u)
        r.httpMethod = "PUT"
        r.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        _ = try? await GenHTTP.session.data(for: r)
    }

    /// fal has no documented "whoami"; a status lookup of a random request id is authenticated and free:
    /// 401/403 = bad key, anything else (404 / 400) = the key was accepted.
    func testKey(_ key: String) async throws -> String {
        var r = URLRequest(url: try GenHTTP.url(base + "/fal-ai/flux-pro/requests/\(UUID().uuidString.lowercased())/status"))
        r.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        do {
            _ = try await GenHTTP.send(r, provider: .fal, retries: 0)
            return "Key OK"
        } catch GenError.unauthorized(let m) {
            throw GenError.unauthorized(m)
        } catch GenError.http(let code, _) where code == 404 || code == 400 || code == 422 {
            return "Key OK (authenticated)"
        }
    }
}
