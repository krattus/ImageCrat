import Foundation

// MARK: - Features

/// Generative features (Photoshop 2026 equivalents). Every feature creates new layers; nothing is destructive.
package enum GenFeature: String, CaseIterable, Codable, Identifiable {
    case fill, expand, remove, generateImage, similar, background, promptEdit, referenceFill, harmonize, upscale, denoise, sharpen, sky

    package var id: String { rawValue }
    package var displayName: String {
        switch self {
        case .fill: return "Generative Fill"
        case .expand: return "Generative Expand"
        case .remove: return "Remove (AI)"
        case .generateImage: return "Generate Image"
        case .similar: return "Generate Similar"
        case .background: return "Generate Background"
        case .promptEdit: return "Edit with Prompt"
        case .referenceFill: return "Fill with Reference Image"
        case .harmonize: return "Harmonize"
        case .upscale: return "Generative Upscale"
        case .denoise: return "AI Denoise"
        case .sharpen: return "AI Sharpen"
        case .sky: return "Sky Replacement (generative)"
        }
    }
}

// MARK: - Providers

package enum ProviderID: String, CaseIterable, Codable, Identifiable {
    case openai, gemini, stability, fal, replicate, bfl
    package var id: String { rawValue }
    package var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .stability: return "Stability AI"
        case .fal: return "fal.ai"
        case .replicate: return "Replicate"
        case .bfl: return "Black Forest Labs"
        }
    }
    /// Where the user gets a key.
    package var keyURL: String {
        switch self {
        case .openai: return "https://platform.openai.com/api-keys"
        case .gemini: return "https://aistudio.google.com/app/apikey"
        case .stability: return "https://platform.stability.ai/account/keys"
        case .fal: return "https://fal.ai/dashboard/keys"
        case .replicate: return "https://replicate.com/account/api-tokens"
        case .bfl: return "https://dashboard.bfl.ai/"
        }
    }
    /// Short data-use note shown in Preferences (summarised from each provider's published policy).
    package var privacyNote: String {
        switch self {
        case .openai: return "API inputs/outputs are not used for training by default; kept up to 30 days for abuse monitoring."
        case .gemini: return "Paid tier: not used to improve Google products. Free tier: prompts/images may be used for training and reviewed by humans."
        case .stability: return "API requests are not used for training; generations are retained briefly for safety review."
        case .fal: return "Inputs/outputs are stored on fal's CDN unless ‘Don't store I/O’ is on (sends X-Fal-Store-IO: 0)."
        case .replicate: return "API prediction inputs/outputs are deleted after about an hour; the model owner does not get them."
        case .bfl: return "Result URLs expire after ~10 minutes; API data is not used for training."
        }
    }
    /// Debug-only base URL override (mock servers): LUMEN_GENAI_BASEURL_<PROVIDER>.
    package var envOverrideKey: String { "LUMEN_GENAI_BASEURL_" + rawValue.uppercased() }
}

/// How a provider wants the edit mask.
package enum MaskKind: String, Codable {
    case none                 // no mask input: crop + describe (edited locally through the mask)
    case alphaTransparentEdit // RGBA PNG, alpha 0 = edit (OpenAI)
    case grayWhiteEdit        // grayscale/RGB PNG, white = edit (Stability, BFL, fal flux fill, Replicate)
}

package struct ProviderCapabilities: Codable, Equatable {
    package var maxMegapixels: Double = 1.05
    package var minMegapixels: Double = 0
    /// Accepted aspect-ratio range (w/h) for inputs.
    package var minAspect: Double = 0.25
    package var maxAspect: Double = 4
    package var maxEdge: Int = 1536
    /// Preferred longest edge for the image sent (context crop is resized to fit).
    package var preferredEdge: Int = 1024
    package var maskKind: MaskKind = .grayWhiteEdit
    /// Output can carry transparency.
    package var alphaOutput = false
    package var maxReferenceImages = 0
    /// Variations per call (`n` / `num_images`); features loop calls to reach 3.
    package var maxImagesPerCall = 1
    /// Fixed output sizes (OpenAI). nil = any size (multiple of `sizeMultiple`).
    package var allowedSizes: [CGSize]? = nil
    package var sizeMultiple = 16
    /// Asynchronous (queue / polling) API.
    package var async = false
    package init(maxMegapixels: Double = 1.05, minMegapixels: Double = 0, minAspect: Double = 0.25, maxAspect: Double = 4, maxEdge: Int = 1536, preferredEdge: Int = 1024, maskKind: MaskKind = .grayWhiteEdit, alphaOutput: Bool = false, maxReferenceImages: Int = 0, maxImagesPerCall: Int = 1, allowedSizes: [CGSize]? = nil, sizeMultiple: Int = 16, async: Bool = false) {
        self.maxMegapixels = maxMegapixels; self.minMegapixels = minMegapixels; self.minAspect = minAspect; self.maxAspect = maxAspect; self.maxEdge = maxEdge; self.preferredEdge = preferredEdge; self.maskKind = maskKind; self.alphaOutput = alphaOutput; self.maxReferenceImages = maxReferenceImages; self.maxImagesPerCall = maxImagesPerCall; self.allowedSizes = allowedSizes; self.sizeMultiple = sizeMultiple; self.async = async
    }
}

/// One model offered by a provider.
package struct GenModel: Identifiable, Hashable {
    package var provider: ProviderID
    package var model: String            // provider model id / endpoint path
    package var name: String
    package var features: Set<GenFeature>
    package var caps: ProviderCapabilities
    /// Estimated USD per output image (for the spend counter). Credits are converted at list price.
    package var pricePerImage: Double

    package var id: String { provider.rawValue + ":" + model }
    package static func == (a: GenModel, b: GenModel) -> Bool { a.id == b.id }
    package func hash(into h: inout Hasher) { h.combine(id) }
    package init(provider: ProviderID, model: String, name: String, features: Set<GenFeature>, caps: ProviderCapabilities, pricePerImage: Double) {
        self.provider = provider; self.model = model; self.name = name; self.features = features; self.caps = caps; self.pricePerImage = pricePerImage
    }
}

// MARK: - Requests / results

package enum OutputQuality: String, Codable, CaseIterable, Identifiable {
    case draft = "Draft (fast, cheapest)", standard = "Standard", high = "High (largest, slowest)"
    package var id: String { rawValue }
}

package enum ContentType: String, Codable, CaseIterable, Identifiable {
    case photo = "Photo", art = "Art"
    package var id: String { rawValue }
}

package struct ExpandPadding: Equatable, Codable {
    package var left = 0
    package var right = 0
    package var top = 0
    package var bottom = 0
    package var isZero: Bool { left == 0 && right == 0 && top == 0 && bottom == 0 }
    package init(left: Int = 0, right: Int = 0, top: Int = 0, bottom: Int = 0) {
        self.left = left; self.right = right; self.top = top; self.bottom = bottom
    }
}
