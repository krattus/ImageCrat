import Foundation
import CoreGraphics
import ImageCratCore

/// Provider-agnostic request. Images are already cropped + resized for the provider.
struct GenRequest {
    var feature: GenFeature
    var prompt: String = ""
    var negativePrompt: String = ""
    /// Source (context crop), RGBA.
    var image: CGImage? = nil
    /// Edit mask at the same size as `image`: 8-bit gray, white = edit.
    var mask: PixelBuffer? = nil
    var references: [CGImage] = []
    var count = 1
    /// Output pixel size wanted (generation / fixed-size providers).
    var width = 1024
    var height = 1024
    var aspectRatio: String = "1:1"
    var padding = ExpandPadding()     // native outpaint endpoints: padding in send pixels…
    var unpadded: CGImage? = nil      // …around this (unpadded) original
    var upscaleFactor: Double = 2
    var stylePreset: String? = nil
    var contentType: ContentType = .photo
    var seed: Int? = nil
    var strength: Double = 0.6
    var quality: OutputQuality = .standard
    var storeIO = false
    var lightDirection: String? = nil
}

struct GenImage {
    var image: CGImage
    var seed: Int? = nil
    /// Cost of the call (USD): the provider-reported amount when `costReported`, else a list-price estimate; attached to the first image.
    var cost: Double? = nil
    /// True when `cost` comes from the provider's response (token usage, billed credits) rather than the local price table.
    var costReported = false
}

struct GenProgress {
    var fraction: Double?        // nil = indeterminate
    var message: String
}

/// State of an in-flight provider job.
enum GenJobHandle {
    case done([GenImage])
    case pending(PendingJob)
}

struct PendingJob {
    var id: String
    var pollURL: URL
    var cancelURL: URL?
    var resultURL: URL?
    var extra: [String: String] = [:]
}

enum PollState {
    case pending(GenProgress)
    case done([GenImage])
}

// MARK: - Errors

enum GenError: Error, LocalizedError, Equatable {
    case missingKey(ProviderID)
    case noProvider(GenFeature)
    case unsupported(String)
    case moderated(String)
    case rateLimited(retryAfter: Double?)
    case http(Int, String)
    case network(String)
    case badResponse(String)
    case cancelled
    case timeout
    case noSelection
    case noDocument
    case insufficientCredits(String)
    case unauthorized(String)
    case budget(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let p): return "No API key for \(p.displayName). Add one in Preferences ▸ Generative AI."
        case .noProvider(let f): return "No provider with a stored API key supports \(f.displayName). Add a key in Preferences ▸ Generative AI."
        case .unsupported(let s): return s
        case .moderated(let s): return "The request was blocked by the provider's content filter. \(s)".trimmingCharacters(in: .whitespaces)
        case .rateLimited(let r): return "Rate limited by the provider." + (r.map { " Try again in \(Int($0.rounded(.up))) s." } ?? " Try again shortly.")
        case .http(let c, let s): return "The provider returned HTTP \(c). \(s)".trimmingCharacters(in: .whitespaces)
        case .network(let s): return "Network error: \(s)"
        case .badResponse(let s): return "Unexpected response from the provider: \(s)"
        case .cancelled: return "Cancelled."
        case .timeout: return "The provider did not finish in time."
        case .noSelection: return "Make a selection first."
        case .noDocument: return "Open a document first."
        case .insufficientCredits(let s): return "Not enough credits / quota. \(s)".trimmingCharacters(in: .whitespaces)
        case .unauthorized(let s): return "The API key was rejected. \(s)".trimmingCharacters(in: .whitespaces)
        case .budget(let s): return s
        }
    }
}
