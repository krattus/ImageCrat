import Foundation
import CoreGraphics
import ImageCratCore

/// Stability AI v2beta (multipart, `Authorization: Bearer`, `Accept: application/json` → `{image, finish_reason, seed}`).
/// Async endpoints return `{id}`; poll `GET /v2beta/results/{id}` (202 = in progress).
/// Docs: https://platform.stability.ai/docs/api-reference (OpenAPI: https://api.stability.ai/v2alpha/openapi)
final class StabilityProvider: GenerativeProvider {
    let id = ProviderID.stability
    var base: String { GenHTTP.base(.stability, "https://api.stability.ai") }

    static func caps(async: Bool = false, maxEdge: Int = 1536, mp: Double = 2.4) -> ProviderCapabilities {
        ProviderCapabilities(maxMegapixels: mp, minMegapixels: 0.0041, minAspect: 0.4, maxAspect: 2.5, maxEdge: maxEdge, preferredEdge: 1024,
                             maskKind: .grayWhiteEdit, alphaOutput: false, maxReferenceImages: 0, maxImagesPerCall: 1, allowedSizes: nil, sizeMultiple: 8, async: async)
    }
    /// 1 credit = $0.01.
    static func m(_ path: String, _ name: String, _ f: Set<GenFeature>, credits: Double, async: Bool = false, maxEdge: Int = 1536, mp: Double = 2.4) -> GenModel {
        GenModel(provider: .stability, model: path, name: name, features: f, caps: caps(async: async, maxEdge: maxEdge, mp: mp), pricePerImage: credits * 0.01)
    }

    lazy var models: [GenModel] = [
        Self.m("inpaint", "Stable Image Inpaint", [.fill, .sky], credits: 5),
        Self.m("outpaint", "Stable Image Outpaint", [.expand], credits: 4),
        Self.m("erase", "Stable Image Erase", [.remove], credits: 5),
        Self.m("search-and-replace", "Search & Replace (prompt: old -> new)", [.promptEdit], credits: 5),
        Self.m("search-and-recolor", "Search & Recolor (prompt: object: colour)", [.promptEdit], credits: 5),
        Self.m("replace-background-and-relight", "Replace Background & Relight", [.background, .harmonize], credits: 8, async: true),
        Self.m("upscale/fast", "Upscale Fast (4×)", [.upscale], credits: 2, maxEdge: 1536, mp: 1.0),
        Self.m("upscale/conservative", "Upscale Conservative", [.upscale], credits: 40, maxEdge: 3072, mp: 9.0),
        Self.m("upscale/creative", "Upscale Creative", [.upscale], credits: 60, async: true, maxEdge: 1536, mp: 1.0),
        Self.m("generate/ultra", "Stable Image Ultra", [.generateImage, .similar], credits: 8),
        Self.m("generate/core", "Stable Image Core", [.generateImage], credits: 3),
        Self.m("generate/sd3", "Stable Diffusion 3.5 Large", [.generateImage, .similar], credits: 6.5),
    ]

    static let stylePresets = ["3d-model", "analog-film", "anime", "cinematic", "comic-book", "digital-art", "enhance", "fantasy-art", "isometric", "line-art", "low-poly", "modeling-compound", "neon-punk", "origami", "photographic", "pixel-art", "tile-texture"]
    static let aspects = ["21:9", "16:9", "3:2", "5:4", "1:1", "4:5", "2:3", "9:16", "9:21"]

    func headers(_ key: String) -> [String: String] { ["Authorization": "Bearer \(key)", "Accept": "application/json"] }

    func endpoint(_ path: String) -> String {
        path.hasPrefix("upscale/") || path.hasPrefix("generate/") ? "/v2beta/stable-image/\(path)" : "/v2beta/stable-image/edit/\(path)"
    }

    /// "old -> new", "old → new", "replace old with new".
    static func splitReplace(_ p: String) -> (String, String)? {
        for sep in ["->", "→", "=>"] {
            let parts = p.components(separatedBy: sep)
            if parts.count == 2 { return (parts[0].trimmingCharacters(in: .whitespaces), parts[1].trimmingCharacters(in: .whitespaces)) }
        }
        let l = p.lowercased()
        if l.hasPrefix("replace "), let r = l.range(of: " with ") {
            return (String(p[p.index(p.startIndex, offsetBy: 8)..<r.lowerBound]), String(p[r.upperBound...]))
        }
        return nil
    }

    func submit(_ r: GenRequest, model: GenModel, key: String) async throws -> GenJobHandle {
        var mp = GenHTTP.Multipart()
        let path = model.model
        let prompt = GenPrompts.text(r)
        func img(_ name: String, _ i: CGImage?) throws {
            guard let i else { throw GenError.unsupported("\(model.name) needs an input image.") }
            mp.file(name, filename: "\(name).png", mime: "image/png", data: GenHTTP.pngData(i))
        }
        switch path {
        case "inpaint":
            try img("image", r.image)
            if let m = r.mask { mp.file("mask", filename: "mask.png", mime: "image/png", data: GenImaging.encodeMask(m, kind: .grayWhiteEdit)) }
            mp.field("prompt", prompt)
            if !r.negativePrompt.isEmpty { mp.field("negative_prompt", r.negativePrompt) }
            mp.field("grow_mask", "5")
        case "outpaint":
            try img("image", r.unpadded ?? r.image)
            mp.field("left", String(min(2000, r.padding.left))); mp.field("right", String(min(2000, r.padding.right)))
            mp.field("up", String(min(2000, r.padding.top))); mp.field("down", String(min(2000, r.padding.bottom)))
            mp.field("creativity", "0.5")
            if !r.prompt.isEmpty { mp.field("prompt", r.prompt) }
        case "erase":
            try img("image", r.image)
            if let m = r.mask { mp.file("mask", filename: "mask.png", mime: "image/png", data: GenImaging.encodeMask(m, kind: .grayWhiteEdit)) }
            mp.field("grow_mask", "5")
        case "search-and-replace":
            guard let (a, b) = Self.splitReplace(r.prompt) else { throw GenError.unsupported("Search & Replace needs a prompt like “red car -> blue bicycle”.") }
            try img("image", r.image)
            mp.field("search_prompt", a); mp.field("prompt", b)
        case "search-and-recolor":
            let parts = r.prompt.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { throw GenError.unsupported("Search & Recolor needs a prompt like “jacket: deep emerald green”.") }
            try img("image", r.image)
            mp.field("select_prompt", parts[0]); mp.field("prompt", parts[1])
        case "replace-background-and-relight":
            try img("subject_image", r.image)
            if r.feature == .harmonize {
                mp.field("keep_original_background", "true")
                mp.field("preserve_original_subject", "0.4")
                if !r.prompt.isEmpty { mp.field("foreground_prompt", r.prompt) }
            } else {
                mp.field("background_prompt", r.prompt.isEmpty ? "clean softly lit studio background" : r.prompt)
                if let ref = r.references.first { mp.file("background_reference", filename: "bg.jpg", mime: "image/jpeg", data: GenHTTP.jpegData(ref)) }
            }
            mp.field("light_source_direction", r.lightDirection ?? "above")
            mp.field("light_source_strength", "0.3")
        case "upscale/fast":
            try img("image", r.image)
        case "upscale/conservative", "upscale/creative":
            try img("image", r.image)
            mp.field("prompt", r.prompt.isEmpty ? "high quality, highly detailed, sharp photograph" : r.prompt)
            mp.field("creativity", path == "upscale/creative" ? "0.3" : "0.35")
        case "generate/ultra", "generate/core", "generate/sd3":
            mp.field("prompt", prompt)
            if !r.negativePrompt.isEmpty { mp.field("negative_prompt", r.negativePrompt) }
            if let src = r.image ?? r.references.first, path != "generate/core" {
                if path == "generate/sd3" { mp.field("mode", "image-to-image") }
                mp.file("image", filename: "image.png", mime: "image/png", data: GenHTTP.pngData(src))
                mp.field("strength", String(format: "%.2f", r.strength))
            } else {
                mp.field("aspect_ratio", GenImaging.aspectString(r.width, r.height, allowed: Self.aspects))
            }
            if path == "generate/sd3" { mp.field("model", "sd3.5-large") }
        default:
            throw GenError.unsupported("Unknown Stability endpoint \(path)")
        }
        if let s = r.stylePreset?.lowercased().replacingOccurrences(of: " ", with: "-"), Self.stylePresets.contains(s),
           ["inpaint", "outpaint", "search-and-replace", "search-and-recolor", "generate/ultra", "generate/core", "generate/sd3", "upscale/creative"].contains(path) {
            mp.field("style_preset", s)
        }
        if let seed = r.seed { mp.field("seed", String(seed)) }
        mp.field("output_format", "png")
        let (data, _) = try await GenHTTP.send(mp.request(try GenHTTP.url(base + endpoint(path)), headers: headers(key)), provider: .stability)
        let json = try GenHTTP.parseJSON(data)
        if model.caps.async {
            guard let jid = json["id"] as? String else { throw GenError.badResponse("missing id") }
            return .pending(PendingJob(id: jid, pollURL: try GenHTTP.url(base + "/v2beta/results/\(jid)")))
        }
        return .done([try Self.parseImage(json, cost: model.pricePerImage)])
    }

    static func parseImage(_ json: [String: Any], cost: Double?) throws -> GenImage {
        if (json["finish_reason"] as? String) == "CONTENT_FILTERED" { throw GenError.moderated("Stability filtered the output.") }
        if let errs = json["errors"] as? [String] {
            let msg = errs.joined(separator: "; ")
            if (json["name"] as? String) == "content_moderation" { throw GenError.moderated(msg) }
            throw GenError.badResponse(msg)
        }
        guard let b = json["image"] as? String else { throw GenError.badResponse("missing image") }
        return GenImage(image: try GenHTTP.decodeBase64Image(b), seed: (json["seed"] as? Int) ?? (json["seed"] as? Double).map { Int($0) }, cost: cost)
    }

    func poll(_ job: PendingJob, model: GenModel, key: String) async throws -> PollState {
        var r = URLRequest(url: job.pollURL)
        for (k, v) in headers(key) { r.setValue(v, forHTTPHeaderField: k) }
        let (data, http) = try await GenHTTP.send(r, provider: .stability)
        if http.statusCode == 202 { return .pending(GenProgress(fraction: nil, message: "Stability: in progress…")) }
        return .done([try Self.parseImage(try GenHTTP.parseJSON(data), cost: model.pricePerImage)])
    }

    func testKey(_ key: String) async throws -> String {
        var r = URLRequest(url: try GenHTTP.url(base + "/v1/user/balance"))
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let json = try await GenHTTP.sendJSON(r, provider: .stability)
        let c = (json["credits"] as? Double) ?? Double(json["credits"] as? Int ?? 0)
        return String(format: "Key OK — %.1f credits (≈ $%.2f)", c, c * 0.01)
    }
}
