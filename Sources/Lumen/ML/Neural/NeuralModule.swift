import SwiftUI
import CoreGraphics

/// Neural Filters, generative Remove, Sky Replacement, AI Denoise / Sharpen / Upscale and Content Credentials.
enum NeuralModule {
    static func register() {
        NeuralModels.registerSpecs()
        let hasDoc: () -> Bool = { AppActions.doc != nil }
        let hasLayer: () -> Bool = { AppActions.doc?.activeLayer.map { !$0.isGroup && !$0.isAdjustment } ?? false }

        DialogRegistry.register("neuralFilters") { AnyView(NeuralFiltersDialog()) }
        DialogRegistry.register("skyReplacement") { AnyView(SkyReplacementDialog()) }
        DialogRegistry.register("aiDenoise") { AnyView(NeuralQuickDialog(kind: .denoise)) }
        DialogRegistry.register("aiSharpen") { AnyView(NeuralQuickDialog(kind: .sharpen)) }
        DialogRegistry.register("aiUpscale") { AnyView(NeuralQuickDialog(kind: .upscale)) }

        MenuRegistry.add("Filter", "Neural Filters…", dividerBefore: true, enabled: hasLayer) { DialogRegistry.show("neuralFilters") }
        // category submenus (shown inside Filter ▸ Noise / Sharpen via ExtensionMenuItems(menu: "Filter/<category>"))
        MenuRegistry.add("Filter/Noise", "AI Denoise…", enabled: hasLayer) { DialogRegistry.show("aiDenoise") }
        MenuRegistry.add("Filter/Sharpen", "AI Sharpen / Deblur…", enabled: hasLayer) { DialogRegistry.show("aiSharpen") }
        MenuRegistry.add("Edit", "Sky Replacement…", enabled: hasDoc) { DialogRegistry.show("skyReplacement") }
        MenuRegistry.add("Image", "AI Upscale (Real-ESRGAN)…", enabled: hasDoc) { DialogRegistry.show("aiUpscale") }

        PanelRegistry.register(PanelRegistry.Def(id: "contentCredentials", title: "Content Credentials") { AnyView(ContentCredentialsPanel()) })
        MenuRegistry.add("Window", "Content Credentials") { WorkspaceManager.shared.toggle("contentCredentials") }

        FeatureModules.selfTests.append(("neural", { NeuralSelfTest.run($0) }))
    }
}

// MARK: - Hooks for other modules

/// Sky masks from a segmentation service (set by the Object Selection module when it lands). Returns a gray mask
/// (white = sky) at the image's size, or nil to fall back to the built-in estimator.
enum SkyMaskProvider {
    static var provider: ((CGImage) async throws -> CGImage?)?
}

/// Cloud-only features (Smart Portrait expressions/age, Landscape Mixer) route through a generative provider.
enum NeuralCloudHook {
    /// (image, instruction) → edited image.
    static var editPortrait: ((CGImage, String) async throws -> CGImage)?
    static var mixLandscape: ((CGImage, String) async throws -> CGImage)?
}
