import Foundation
import Observation
import ImageCratCore

/// Persisted Generative AI settings (no secrets: keys live in the Keychain).
struct GenAISettingsData: Codable, Equatable {
    /// Feature → model id ("provider:model") chosen by the user; missing = automatic.
    var routing: [String: String] = [:]
    /// fal.ai: send `X-Fal-Store-IO: 0` so inputs/outputs are not kept on fal's CDN.
    var falDontStoreIO = true
    /// Ask before an image is uploaded for the first time in a session.
    var confirmUploads = false
    /// Replicate: use `Prefer: wait` (sync) before falling back to polling.
    var replicatePreferWait = true
    var quality: OutputQuality = .standard
    var variations: Int = 3
    /// Month ("2026-09") → estimated USD spent.
    var spend: [String: Double] = [:]
    var monthlyBudget: Double = 0          // 0 = no warning
    var removeUsesCloud = false            // Remove tool: "Generative AI (cloud)" mode
    var cropGenerativeExpand = false       // Crop tool: fill new canvas area generatively
    var cropExpandPrompt = ""
    /// Ask before a generation whose estimated cost exceeds the remaining monthly budget or provider balance.
    var warnOverBudget = true
    /// Refuse generations that would exceed the monthly budget.
    var budgetHardStop = false
    /// Balance (USD) below which balance cards and the status chip turn amber (red at a fifth of it).
    var lowBalanceWarning: Double = 5
    /// Privacy: keep prompts out of the usage log.
    var dontLogPrompts = false
    /// Bring the Properties panel (variation thumbnails) to the front when a generation finishes.
    var revealPropertiesAfterGenerate = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GenAISettingsData()
        routing = (try? c.decodeIfPresent([String: String].self, forKey: .routing)) ?? d.routing
        falDontStoreIO = (try? c.decodeIfPresent(Bool.self, forKey: .falDontStoreIO)) ?? d.falDontStoreIO
        confirmUploads = (try? c.decodeIfPresent(Bool.self, forKey: .confirmUploads)) ?? d.confirmUploads
        replicatePreferWait = (try? c.decodeIfPresent(Bool.self, forKey: .replicatePreferWait)) ?? d.replicatePreferWait
        quality = (try? c.decodeIfPresent(OutputQuality.self, forKey: .quality)) ?? d.quality
        variations = (try? c.decodeIfPresent(Int.self, forKey: .variations)) ?? d.variations
        spend = (try? c.decodeIfPresent([String: Double].self, forKey: .spend)) ?? d.spend
        monthlyBudget = (try? c.decodeIfPresent(Double.self, forKey: .monthlyBudget)) ?? d.monthlyBudget
        removeUsesCloud = (try? c.decodeIfPresent(Bool.self, forKey: .removeUsesCloud)) ?? d.removeUsesCloud
        cropGenerativeExpand = (try? c.decodeIfPresent(Bool.self, forKey: .cropGenerativeExpand)) ?? d.cropGenerativeExpand
        cropExpandPrompt = (try? c.decodeIfPresent(String.self, forKey: .cropExpandPrompt)) ?? d.cropExpandPrompt
        warnOverBudget = (try? c.decodeIfPresent(Bool.self, forKey: .warnOverBudget)) ?? d.warnOverBudget
        budgetHardStop = (try? c.decodeIfPresent(Bool.self, forKey: .budgetHardStop)) ?? d.budgetHardStop
        lowBalanceWarning = (try? c.decodeIfPresent(Double.self, forKey: .lowBalanceWarning)) ?? d.lowBalanceWarning
        dontLogPrompts = (try? c.decodeIfPresent(Bool.self, forKey: .dontLogPrompts)) ?? d.dontLogPrompts
        revealPropertiesAfterGenerate = (try? c.decodeIfPresent(Bool.self, forKey: .revealPropertiesAfterGenerate)) ?? d.revealPropertiesAfterGenerate
    }
}

@Observable
final class GenAISettings {
    static let shared = GenAISettings()
    private static let key = "Lumen.GenAI.Settings"

    var data: GenAISettingsData { didSet { save() } }
    /// Bumped when a key is added/removed (refreshes pickers).
    var keysRevision = 0
    @ObservationIgnored var persist = true

    private init() {
        if let d = UserDefaults.standard.data(forKey: GenAISettings.key), let s = try? JSONDecoder().decode(GenAISettingsData.self, from: d) {
            data = s
        } else {
            data = GenAISettingsData()
        }
    }

    private func save() {
        guard persist, let d = try? JSONEncoder().encode(data) else { return }
        UserDefaults.standard.set(d, forKey: GenAISettings.key)
    }

    static func monthKey(_ date: Date = Date()) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    var spendThisMonth: Double { data.spend[GenAISettings.monthKey()] ?? 0 }

    func addSpend(_ usd: Double) {
        guard usd > 0 else { return }
        data.spend[GenAISettings.monthKey(), default: 0] += usd
    }
}

/// Chooses a provider/model per feature: user override first, then the default priority table,
/// considering only providers with a stored key.
final class ProviderRouter {
    static let shared = ProviderRouter()

    let providers: [ProviderID: GenerativeProvider]

    init() {
        var p: [ProviderID: GenerativeProvider] = [:]
        for prov: GenerativeProvider in [OpenAIProvider(), GeminiProvider(), StabilityProvider(), FalProvider(), ReplicateProvider(), BFLProvider()] {
            p[prov.id] = prov
        }
        providers = p
    }

    var allModels: [GenModel] { ProviderID.allCases.flatMap { providers[$0]?.models ?? [] } }

    func model(_ id: String) -> GenModel? { allModels.first { $0.id == id } }

    /// Default feature → ordered model ids (first with a key wins).
    static let defaults: [GenFeature: [String]] = [
        .fill: ["openai:gpt-image-2.5-sunburst", "bfl:flux-pro-1.0-fill", "fal:fal-ai/flux-pro/v1/fill", "stability:inpaint", "replicate:black-forest-labs/flux-fill-pro", "gemini:gemini-3.1-flash-image"],
        .expand: ["bfl:flux-pro-1.0-expand", "stability:outpaint", "fal:fal-ai/flux-pro/v1/fill", "openai:gpt-image-2.5-sunburst", "replicate:black-forest-labs/flux-fill-pro", "gemini:gemini-3.1-flash-image"],
        .remove: ["stability:erase", "fal:fal-ai/bria/eraser", "bfl:flux-tools/erase-v1", "openai:gpt-image-2.5-flare", "replicate:black-forest-labs/flux-fill-pro", "gemini:gemini-3.1-flash-image"],
        .generateImage: ["gemini:gemini-3-pro-image", "openai:gpt-image-2.5-sunburst", "bfl:flux-2-pro", "stability:generate/ultra", "fal:fal-ai/nano-banana-2", "replicate:black-forest-labs/flux-kontext-pro"],
        .similar: ["gemini:gemini-3.1-flash-image", "openai:gpt-image-2.5-flare", "bfl:flux-2-pro", "fal:fal-ai/nano-banana-2/edit", "stability:generate/sd3", "replicate:black-forest-labs/flux-kontext-pro"],
        .background: ["stability:replace-background-and-relight", "fal:fal-ai/bria/background/replace", "openai:gpt-image-2.5-sunburst", "bfl:flux-pro-1.0-fill", "gemini:gemini-3.1-flash-image", "replicate:black-forest-labs/flux-fill-pro"],
        .promptEdit: ["gemini:gemini-3.1-flash-image", "openai:gpt-image-2.5-sunburst", "bfl:flux-kontext-pro", "fal:fal-ai/nano-banana-2/edit", "replicate:black-forest-labs/flux-kontext-pro", "stability:search-and-replace"],
        .referenceFill: ["gemini:gemini-3-pro-image", "openai:gpt-image-2.5-sunburst", "bfl:flux-2-pro", "fal:fal-ai/nano-banana-2/edit"],
        .harmonize: ["gemini:gemini-3.1-flash-image", "fal:fal-ai/iclight-v2", "stability:replace-background-and-relight", "openai:gpt-image-2.5-flare", "bfl:flux-kontext-pro", "replicate:black-forest-labs/flux-kontext-pro"],
        .upscale: ["fal:fal-ai/topaz/upscale/image", "stability:upscale/conservative", "stability:upscale/fast", "replicate:topazlabs/image-upscale"],
        .denoise: ["fal:fal-ai/topaz/upscale/image#denoise"],
        .sharpen: ["fal:fal-ai/topaz/upscale/image#sharpen"],
        .sky: ["bfl:flux-pro-1.0-fill", "fal:fal-ai/flux-pro/v1/fill", "openai:gpt-image-2.5-sunburst", "stability:inpaint", "gemini:gemini-3.1-flash-image", "replicate:black-forest-labs/flux-fill-pro"],
    ]

    func hasKey(_ p: ProviderID) -> Bool { GenAIKeychain.shared.hasKey(p) }

    /// Models for a feature whose provider has a key (for the routing pickers).
    func available(for f: GenFeature) -> [GenModel] {
        allModels.filter { $0.features.contains(f) && hasKey($0.provider) }
    }

    /// All models supporting the feature (keyed or not).
    func all(for f: GenFeature) -> [GenModel] { allModels.filter { $0.features.contains(f) } }

    private func candidates(_ f: GenFeature, override: String?) -> [(GenerativeProvider, GenModel)] {
        var order: [String] = []
        if let o = override { order.append(o) }
        if let u = GenAISettings.shared.data.routing[f.rawValue], !u.isEmpty { order.append(u) }
        order += ProviderRouter.defaults[f] ?? []
        order += all(for: f).map(\.id)
        return order.compactMap { id in
            guard let m = model(id), m.features.contains(f), let p = providers[m.provider], hasKey(m.provider) else { return nil }
            return (p, m)
        }
    }

    /// The model a feature would use. Only checks which keys exist, never reads a secret, so views can call it
    /// (reading one can block on a Keychain access prompt — see `GenAIKeychain.secrets`).
    func resolve(_ f: GenFeature, override: String? = nil) throws -> (GenerativeProvider, GenModel) {
        guard let c = candidates(f, override: override).first else { throw GenError.noProvider(f) }
        return c
    }

    /// Provider, model and key for a job. The key is read off the main thread; a provider whose key can't be read
    /// (access denied) is skipped like one without a key.
    func resolveWithKey(_ f: GenFeature, override: String? = nil) async throws -> (GenerativeProvider, GenModel, String) {
        await GenAIKeychain.shared.waitForPresence()
        var unreadable = Set<ProviderID>()
        for (p, m) in candidates(f, override: override) where !unreadable.contains(m.provider) {
            if let k = await GenAIKeychain.shared.loadKey(m.provider) { return (p, m, k) }
            unreadable.insert(m.provider)
        }
        throw GenError.noProvider(f)
    }
}
