import SwiftUI
import AppKit
import ImageCratCore

/// Generative AI feature module: menus, dialogs, History panel, task-bar notification, upscaler hook, self test.
enum GenAIModule {
    nonisolated(unsafe) private static var observer: NSObjectProtocol?
    nonisolated(unsafe) private static var quitObserver: NSObjectProtocol?

    static func register() {
        GenAIDialogs.register()
        GenAIKeychain.warmUp()
        let hasDoc: () -> Bool = { AppActions.doc != nil }
        let hasSel: () -> Bool = { AppActions.doc?.state.selection != nil }

        // Edit
        MenuRegistry.add("Edit", "Generative Fill…", key: "f", modifiers: [.command, .option, .shift], dividerBefore: true, enabled: hasDoc) { GenAIDialogs.show(.fill) }
        MenuRegistry.add("Edit", "Remove with AI", enabled: hasSel) { MainActor.assumeIsolated { GenAIActions.removeWithAI() } }
        MenuRegistry.add("Edit", "Edit with Prompt…", enabled: hasDoc) { GenAIDialogs.show(.promptEdit) }
        MenuRegistry.add("Edit", "Generate Image…") { GenAIDialogs.show(.generateImage) }
        MenuRegistry.add("Edit", "Fill with Reference Image…", submenu: "Generative AI", enabled: hasDoc) { GenAIDialogs.show(.reference) }
        MenuRegistry.add("Edit", "Sky Replacement (Generative)…", submenu: "Generative AI", enabled: hasDoc) { GenAIDialogs.show(.sky) }
        MenuRegistry.add("Edit", "Generative AI Settings…", submenu: "Generative AI") { MainActor.assumeIsolated { GenAIActions.openPreferences() } }
        // Layer
        MenuRegistry.add("Layer", "Generate Image…", dividerBefore: true) { GenAIDialogs.show(.generateImage) }
        MenuRegistry.add("Layer", "Generate Similar", enabled: { AppActions.doc.map { $0.state.generative[$0.activeLayerID ?? UUID()] != nil } ?? false }) {
            MainActor.assumeIsolated { GenAIActions.generateSimilar() }
        }
        MenuRegistry.add("Layer", "Generate Background…", enabled: hasDoc) { GenAIDialogs.show(.background) }
        MenuRegistry.add("Layer", "Harmonize", enabled: hasDoc) { GenAIDialogs.show(.harmonize) }
        // Layer ▸ Generative (variations of the active generative layer). ⌥→ / ⌥← are handled by KeyRouter, only while a
        // generative layer is active and no text is being edited, so they never shadow word-wise cursor movement.
        let isGen: () -> Bool = { GenVariations.active != nil }
        let hasVariations: () -> Bool = { (GenVariations.active?.info.variations.count ?? 0) > 1 }
        MenuRegistry.add("Layer", "Next Variation (⌥→)", submenu: "Generative", enabled: hasVariations) { GenVariations.next() }
        MenuRegistry.add("Layer", "Previous Variation (⌥←)", submenu: "Generative", enabled: hasVariations) { GenVariations.previous() }
        MenuRegistry.add("Layer", "Generate More", submenu: "Generative", enabled: isGen) { MainActor.assumeIsolated { GenVariations.generateMoreActive() } }
        MenuRegistry.add("Layer", "Keep Only Current Variation", submenu: "Generative", dividerBefore: true, enabled: hasVariations) {
            if let a = GenVariations.active { GenVariations.keepOnlyCurrent(a.doc, layerID: a.layerID) }
        }
        MenuRegistry.add("Layer", "Flatten to Normal Layer", submenu: "Generative", enabled: isGen) {
            if let a = GenVariations.active { GenVariations.flatten(a.doc, layerID: a.layerID) }
        }
        // Image
        MenuRegistry.add("Image", "Generative Expand…", dividerBefore: true, enabled: hasDoc) { GenAIDialogs.show(.expand) }
        MenuRegistry.add("Image", "Generative Upscale…", submenu: "AI Enhance", enabled: hasDoc) { GenAIDialogs.show(.upscale) }
        MenuRegistry.add("Image", "AI Denoise", submenu: "AI Enhance", enabled: hasDoc) { MainActor.assumeIsolated { GenAIActions.denoise() } }
        MenuRegistry.add("Image", "AI Sharpen", submenu: "AI Enhance", enabled: hasDoc) { MainActor.assumeIsolated { GenAIActions.sharpen() } }
        // Window
        MenuRegistry.add("Window", "Generative History") { WorkspaceManager.shared.toggle("genHistory") }
        MenuRegistry.add("Window", "AI Usage") { GenUsageUI.open() }

        PanelRegistry.register(PanelRegistry.Def(id: "genHistory", title: "Generative History") { AnyView(GenHistoryPanel()) })
        PanelRegistry.register(PanelRegistry.Def(id: GenUsageUI.panelID, title: "AI Usage") { AnyView(GenUsagePanel()) })
        // Usage log: load (and migrate the old history on a first run) once the app is up; self tests stay in memory.
        if !GenUsageStore.isSelfTest {
            GenUsageStore.shared.loadIfNeeded()
            quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                GenUsageStore.shared.flush(wait: true)
            }
        }

        // Contextual Task Bar (another module) posts this to open Generative Fill; userInfo["prompt"] runs directly.
        observer = NotificationCenter.default.addObserver(forName: Notification.Name("LumenGenerativeFill"), object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                if let p = n.userInfo?["prompt"] as? String, n.userInfo?["run"] as? Bool == true {
                    GenAIActions.generativeFill(prompt: p)
                } else {
                    GenAIDialogs.pendingPrompt = n.userInfo?["prompt"] as? String
                    GenAIDialogs.show(.fill)
                }
            }
        }

        // Image Size hook
        UpscalerRegistry.upscalers.append((name: "Generative Upscale (cloud)", run: { img, factor in
            try await GenAIActions.upscaleImage(img, factor: factor)
        }))

        FeatureModules.selfTests.append(("genai", { out in GenAISelfTest.run(out) }))
    }
}
