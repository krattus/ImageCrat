import Foundation

/// Generative metadata attached to a layer (side table `DocumentState.generative`, keyed by layer id).
/// Decoding is tolerant: unknown/missing keys fall back to defaults so older/newer documents still open.
package struct GenerativeLayerInfo: Codable {
    package var feature: String = GenFeature.fill.rawValue
    package var prompt: String = ""
    package var negativePrompt: String = ""
    package var providerID: String = ""
    package var modelID: String = ""
    package var createdAt = Date()
    /// Doc-space region the variations cover (the layer's raster frame).
    package var rect = IRect.zero
    /// Region-sized gray edit mask (white = edit) used for regeneration; nil = whole region.
    package var mask: PixelBuffer? = nil
    /// Region-sized RGBA variations (already blended through the mask).
    package var variations: [PixelBuffer] = []
    package var selected: Int = 0
    package var seeds: [Int?] = []
    /// Accumulated estimated cost (USD).
    package var cost: Double = 0
    package var reference: PixelBuffer? = nil
    package var aspectRatio: String = ""
    package var contentType: String = ContentType.photo.rawValue
    package var stylePreset: String = ""

    package var featureKind: GenFeature { GenFeature(rawValue: feature) ?? .fill }

    package init() {}

    private enum K: String, CodingKey {
        case feature, prompt, negativePrompt, providerID, modelID, createdAt, rect, mask, variations, selected, seeds, cost, reference, aspectRatio, contentType, stylePreset
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let d = GenerativeLayerInfo()
        feature = (try? c.decodeIfPresent(String.self, forKey: .feature)) ?? d.feature
        prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? d.prompt
        negativePrompt = (try? c.decodeIfPresent(String.self, forKey: .negativePrompt)) ?? d.negativePrompt
        providerID = (try? c.decodeIfPresent(String.self, forKey: .providerID)) ?? d.providerID
        modelID = (try? c.decodeIfPresent(String.self, forKey: .modelID)) ?? d.modelID
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? d.createdAt
        rect = (try? c.decodeIfPresent(IRect.self, forKey: .rect)) ?? d.rect
        mask = (try? c.decodeIfPresent(PixelBuffer.self, forKey: .mask)) ?? nil
        variations = (try? c.decodeIfPresent([PixelBuffer].self, forKey: .variations)) ?? []
        selected = (try? c.decodeIfPresent(Int.self, forKey: .selected)) ?? 0
        seeds = (try? c.decodeIfPresent([Int?].self, forKey: .seeds)) ?? []
        cost = (try? c.decodeIfPresent(Double.self, forKey: .cost)) ?? 0
        reference = (try? c.decodeIfPresent(PixelBuffer.self, forKey: .reference)) ?? nil
        aspectRatio = (try? c.decodeIfPresent(String.self, forKey: .aspectRatio)) ?? ""
        contentType = (try? c.decodeIfPresent(String.self, forKey: .contentType)) ?? d.contentType
        stylePreset = (try? c.decodeIfPresent(String.self, forKey: .stylePreset)) ?? ""
        if selected >= variations.count { selected = max(0, variations.count - 1) }
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(feature, forKey: .feature); try c.encode(prompt, forKey: .prompt); try c.encode(negativePrompt, forKey: .negativePrompt)
        try c.encode(providerID, forKey: .providerID); try c.encode(modelID, forKey: .modelID); try c.encode(createdAt, forKey: .createdAt)
        try c.encode(rect, forKey: .rect); try c.encodeIfPresent(mask, forKey: .mask); try c.encode(variations, forKey: .variations)
        try c.encode(selected, forKey: .selected); try c.encode(seeds, forKey: .seeds); try c.encode(cost, forKey: .cost)
        try c.encodeIfPresent(reference, forKey: .reference); try c.encode(aspectRatio, forKey: .aspectRatio)
        try c.encode(contentType, forKey: .contentType); try c.encode(stylePreset, forKey: .stylePreset)
    }
}
