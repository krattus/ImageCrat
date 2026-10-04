import Foundation
import CoreGraphics
import ImageCratCore

/// Google Gemini native image models via `POST /v1beta/models/{model}:generateContent` (header `x-goog-api-key`).
/// No mask input: the context crop and the mask are sent as two inline images with an instruction
/// ("crop + describe"); the result is blended locally through the mask.
/// Docs: https://ai.google.dev/gemini-api/docs/image-generation , https://ai.google.dev/gemini-api/docs/models
final class GeminiProvider: GenerativeProvider {
    let id = ProviderID.gemini
    var base: String { GenHTTP.base(.gemini, "https://generativelanguage.googleapis.com") }

    static let caps = ProviderCapabilities(maxMegapixels: 4.2, minMegapixels: 0, minAspect: 1.0 / 8, maxAspect: 8, maxEdge: 2048, preferredEdge: 1024,
                                           maskKind: .none, alphaOutput: false, maxReferenceImages: 12, maxImagesPerCall: 1, allowedSizes: nil, sizeMultiple: 8)
    private static let features: Set<GenFeature> = [.fill, .expand, .remove, .generateImage, .similar, .background, .promptEdit, .referenceFill, .harmonize, .sky]
    static let aspects = ["1:1", "1:4", "4:1", "1:8", "8:1", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4", "9:16", "16:9", "21:9"]

    lazy var models: [GenModel] = [
        GenModel(provider: .gemini, model: "gemini-3.1-flash-image", name: "Gemini 3.1 Flash Image (Nano Banana 2)", features: Self.features, caps: Self.caps, pricePerImage: 0.067),
        GenModel(provider: .gemini, model: "gemini-3-pro-image", name: "Gemini 3 Pro Image (Nano Banana Pro)", features: Self.features, caps: Self.caps, pricePerImage: 0.134),
        GenModel(provider: .gemini, model: "gemini-3.1-flash-lite-image", name: "Gemini 3.1 Flash-Lite Image (cheap, 1K)", features: Self.features, caps: Self.caps, pricePerImage: 0.0336),
    ]

    static func imageSize(_ q: OutputQuality, model: String) -> String {
        if model.contains("lite") { return "1K" }
        switch q { case .draft: return "1K"; case .standard: return "1K"; case .high: return "2K" }
    }

    static func price(model: String, size: String) -> Double {
        if model.contains("lite") { return 0.0336 }
        if model.contains("pro") { return size == "4K" ? 0.24 : 0.134 }
        switch size { case "512": return 0.045; case "2K": return 0.101; case "4K": return 0.151; default: return 0.067 }
    }

    func body(_ r: GenRequest, model: GenModel) -> [String: Any] {
        var parts: [[String: Any]] = [["text": GenPrompts.maskless(r)]]
        func inline(_ img: CGImage, png: Bool) -> [String: Any] {
            png ? ["inlineData": ["mimeType": "image/png", "data": GenHTTP.pngData(img).base64EncodedString()]]
                : ["inlineData": ["mimeType": "image/jpeg", "data": GenHTTP.jpegData(img).base64EncodedString()]]
        }
        if let img = r.image { parts.append(inline(img, png: true)) }
        if let m = r.mask, r.image != nil { parts.append(["inlineData": ["mimeType": "image/png", "data": GenImaging.encodeMask(m, kind: .grayWhiteEdit).base64EncodedString()]]) }
        for ref in r.references.prefix(Self.caps.maxReferenceImages) { parts.append(inline(ref, png: false)) }
        var imageConfig: [String: Any] = ["aspectRatio": GenImaging.aspectString(r.width, r.height, allowed: Self.aspects)]
        imageConfig["imageSize"] = Self.imageSize(r.quality, model: model.model)
        return [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["responseModalities": ["TEXT", "IMAGE"], "imageConfig": imageConfig] as [String: Any],
        ]
    }

    func submit(_ r: GenRequest, model: GenModel, key: String) async throws -> GenJobHandle {
        let url = try GenHTTP.url(base + "/v1beta/models/\(model.model):generateContent")
        let req = try GenHTTP.jsonRequest(url, headers: ["x-goog-api-key": key], body: body(r, model: model))
        let json = try await GenHTTP.sendJSON(req, provider: .gemini)
        var imgs = try Self.parse(json)
        imgs[0].cost = Self.price(model: model.model, size: Self.imageSize(r.quality, model: model.model))
        return .done(imgs)
    }

    static let blockReasons: Set<String> = ["SAFETY", "PROHIBITED_CONTENT", "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION", "IMAGE_RECITATION"]

    static func parse(_ json: [String: Any]) throws -> [GenImage] {
        if let pf = json["promptFeedback"] as? [String: Any], let br = pf["blockReason"] as? String {
            throw GenError.moderated("Gemini blocked the prompt (\(br)).")
        }
        guard let cands = json["candidates"] as? [[String: Any]], let c = cands.first else {
            throw GenError.badResponse("no candidates")
        }
        var out: [GenImage] = []
        var text = ""
        if let content = c["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] {
            for p in parts {
                if (p["thought"] as? Bool) == true { continue }
                let inline = (p["inlineData"] ?? p["inline_data"]) as? [String: Any]
                if let d = inline?["data"] as? String { out.append(GenImage(image: try GenHTTP.decodeBase64Image(d))) }
                if let t = p["text"] as? String { text += t }
            }
        }
        if out.isEmpty {
            let fr = c["finishReason"] as? String ?? ""
            if blockReasons.contains(fr) { throw GenError.moderated("Gemini stopped with \(fr). \(c["finishMessage"] as? String ?? "")") }
            throw GenError.badResponse("no image returned" + (fr.isEmpty ? "" : " (\(fr))") + (text.isEmpty ? "" : ": \(text.prefix(160))"))
        }
        return out
    }

    func testKey(_ key: String) async throws -> String {
        var r = URLRequest(url: try GenHTTP.url(base + "/v1beta/models?pageSize=100"))
        r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let json = try await GenHTTP.sendJSON(r, provider: .gemini)
        let names = (json["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let img = names.filter { $0.contains("image") }
        return "Key OK — \(names.count) models" + (img.isEmpty ? "" : " incl. \(img.prefix(2).map { $0.replacingOccurrences(of: "models/", with: "") }.joined(separator: ", "))")
    }
}
