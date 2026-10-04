import Foundation
import CoreGraphics
import ImageCratCore

/// Prompt text shared by all providers.
enum GenPrompts {
    static func text(_ r: GenRequest) -> String {
        let p = r.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        switch r.feature {
        case .fill:
            return p.isEmpty ? "Fill the masked area so it blends seamlessly with its surroundings: continue the existing background, lighting and texture. Do not add new objects." : p
        case .remove:
            return "Remove the object in the masked area and realistically reconstruct the background behind it. Do not add new objects." + (p.isEmpty ? "" : " " + p)
        case .expand:
            return p.isEmpty ? "Extend the scene naturally beyond the original borders, matching perspective, lighting, colour and texture." : p + ". Extend the scene seamlessly, matching perspective and lighting."
        case .referenceFill:
            return "Place the object from the reference image into the masked area, matching lighting, perspective, scale and colour of the scene." + (p.isEmpty ? "" : " " + p)
        case .background:
            return "Replace the background with: \(p.isEmpty ? "a clean, softly lit studio backdrop" : p). Keep the subject exactly as it is and match the lighting."
        case .promptEdit:
            return p
        case .harmonize:
            return "Relight and recolour the object in the masked area so it matches the light direction, colour temperature, contrast and shadows of the surrounding scene. Keep its shape, details and identity. Add a soft realistic contact shadow." + (p.isEmpty ? "" : " " + p)
        case .sky:
            return "Replace the sky with \(p.isEmpty ? "a beautiful natural sky" : p), matching the scene's lighting and horizon."
        case .similar:
            return "Create a close variation of this image with the same subject, composition and style." + (p.isEmpty ? "" : " " + p)
        case .generateImage:
            var s = p
            if let st = r.stylePreset, !st.isEmpty { s += ", \(st) style" }
            s += r.contentType == .photo ? ", photorealistic photograph" : ", digital art"
            return s
        case .upscale, .denoise, .sharpen:
            return p
        }
    }

    /// Instruction for models without mask input (Gemini, nano-banana): image 1 + mask image 2.
    static func maskless(_ r: GenRequest) -> String {
        let task = text(r)
        if r.mask == nil { return task }
        let region = r.feature == .expand ? "the border area (white in image 2, flat gray in image 1)" : "the region that is white in image 2"
        return "Image 1 is the picture to edit. Image 2 is a black-and-white mask with the same size: white marks the region to change." +
            (r.references.isEmpty ? "" : " Image 3 is a reference.") +
            " Task: \(task) Only change \(region); keep every other pixel, the framing and the image size exactly the same. Return only the edited image 1."
    }
}

// MARK: - OpenAI (GPT Image)

/// POST /v1/images/generations (JSON) and /v1/images/edits (multipart, `image[]`, `mask` RGBA PNG: transparent = edit).
/// Docs: https://developers.openai.com/api/reference/resources/images , https://developers.openai.com/api/docs/guides/image-generation
final class OpenAIProvider: GenerativeProvider {
    let id = ProviderID.openai
    var base: String { GenHTTP.base(.openai, "https://api.openai.com") }

    static let caps = ProviderCapabilities(maxMegapixels: 8.29, minMegapixels: 0.656, minAspect: 1.0 / 3, maxAspect: 3,
                                           maxEdge: 2048, preferredEdge: 1024, maskKind: .alphaTransparentEdit,
                                           alphaOutput: true, maxReferenceImages: 15, maxImagesPerCall: 10, allowedSizes: nil, sizeMultiple: 16)
    private static let features: Set<GenFeature> = [.fill, .expand, .remove, .generateImage, .similar, .background, .promptEdit, .referenceFill, .harmonize, .sky]

    lazy var models: [GenModel] = [
        GenModel(provider: .openai, model: "gpt-image-2.5-sunburst", name: "GPT Image 2.5 Sunburst (precise edits)", features: Self.features, caps: Self.caps, pricePerImage: 0.053),
        GenModel(provider: .openai, model: "gpt-image-2.5-flare", name: "GPT Image 2.5 Flare (fast)", features: Self.features, caps: Self.caps, pricePerImage: 0.013),
    ]

    func headers(_ key: String) -> [String: String] { ["Authorization": "Bearer \(key)"] }

    static func quality(_ q: OutputQuality) -> String {
        switch q { case .draft: return "low"; case .standard: return "medium"; case .high: return "high" }
    }

    func submit(_ r: GenRequest, model: GenModel, key: String) async throws -> GenJobHandle {
        let size = "\(r.width)x\(r.height)"
        let prompt = GenPrompts.text(r)
        let req: URLRequest
        if r.image == nil && r.references.isEmpty {
            req = try GenHTTP.jsonRequest(try GenHTTP.url(base + "/v1/images/generations"), headers: headers(key), body: [
                "model": model.model, "prompt": prompt, "n": max(1, min(10, r.count)), "size": size,
                "quality": Self.quality(r.quality), "output_format": "png", "background": "auto",
            ])
        } else {
            var mp = GenHTTP.Multipart()
            mp.field("model", model.model)
            mp.field("prompt", prompt)
            mp.field("n", String(max(1, min(10, r.count))))
            mp.field("size", size)
            mp.field("quality", Self.quality(r.quality))
            mp.field("output_format", "png")
            var images: [CGImage] = []
            if let img = r.image { images.append(img) }
            images += r.references.prefix(15)
            for (i, img) in images.enumerated() {
                mp.file("image[]", filename: "image\(i).png", mime: "image/png", data: GenHTTP.pngData(img))
            }
            if let m = r.mask, r.image != nil {
                // mask must match the first image's size; transparent = edit
                mp.file("mask", filename: "mask.png", mime: "image/png", data: GenImaging.encodeMask(m, kind: .alphaTransparentEdit))
            }
            req = mp.request(try GenHTTP.url(base + "/v1/images/edits"), headers: headers(key))
        }
        let json = try await GenHTTP.sendJSON(req, provider: .openai)
        return .done(try Self.parse(json, model: model))
    }

    static func parse(_ json: [String: Any], model: GenModel) throws -> [GenImage] {
        if let e = json["error"] as? [String: Any] {
            let msg = e["message"] as? String ?? "error"
            if (e["code"] as? String) == "moderation_blocked" || GenHTTP.looksModerated(msg) { throw GenError.moderated(msg) }
            throw GenError.badResponse(msg)
        }
        guard let data = json["data"] as? [[String: Any]] else { throw GenError.badResponse("missing data[]") }
        var out: [GenImage] = []
        for d in data {
            if let b = d["b64_json"] as? String { out.append(GenImage(image: try GenHTTP.decodeBase64Image(b))) }
        }
        if out.isEmpty { throw GenError.badResponse("no images in response") }
        // Token-based cost (official $/1M: text in 5, image in 8, image out 30).
        if let u = json["usage"] as? [String: Any] {
            let outTok = (u["output_tokens"] as? Double) ?? Double(u["output_tokens"] as? Int ?? 0)
            let det = u["input_tokens_details"] as? [String: Any]
            let imgIn = (det?["image_tokens"] as? Double) ?? Double(det?["image_tokens"] as? Int ?? 0)
            let txtIn = (det?["text_tokens"] as? Double) ?? Double(det?["text_tokens"] as? Int ?? 0)
            let c = (outTok * 30 + imgIn * 8 + txtIn * 5) / 1_000_000
            if c > 0 { out[0].cost = c; out[0].costReported = true }
        }
        return out
    }

    func testKey(_ key: String) async throws -> String {
        var r = URLRequest(url: try GenHTTP.url(base + "/v1/models"))
        for (k, v) in headers(key) { r.setValue(v, forHTTPHeaderField: k) }
        let json = try await GenHTTP.sendJSON(r, provider: .openai)
        let ids = (json["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        let img = ids.filter { $0.hasPrefix("gpt-image") }
        return "Key OK — \(ids.count) models" + (img.isEmpty ? "" : " (\(img.prefix(3).joined(separator: ", ")))")
    }
}
