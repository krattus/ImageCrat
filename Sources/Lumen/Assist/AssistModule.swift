import SwiftUI
import ImageCratCore

/// Smart assists: on-device helpers Photoshop does not have. Everything is optional, undoable and works offline
/// (Apple Vision + NaturalLanguage; Florence-2, SAM, LaMa, Depth Anything and NAFNet are used when installed).
///
/// Layer ▸ Name Layers Automatically · Layer ▸ Smart Assist ▸ … · Window ▸ Find Layers · Image ▸ Suggest Crops… /
/// Auto-Straighten + Crop / Analyze… / Auto Enhance / Describe Image… · Select ▸ Text in Image… ·
/// File ▸ Export ▸ Export with Alt Text…
enum AssistModule {
    static let findLayersPanelID = "assistFindLayers"

    static func register() {
        let hasDoc = { AppModel.shared.activeDocument != nil }
        let hasText = { AppActions.doc?.state.allLayers.contains { $0.isText } ?? false }
        let hasImageSelection = {
            guard let d = AppActions.doc else { return false }
            return d.orderedSelection.contains { d.state.layer($0).map { $0.isRaster || $0.isSmartObject || $0.isGroup } ?? false }
        }

        // Dialogs
        DialogRegistry.register("assistCrop") { AnyView(AssistCropDialog()) }
        DialogRegistry.register("assistAnalyze", dims: false) { AnyView(AssistAnalyzeDialog()) }
        DialogRegistry.register("assistDescribe") { AnyView(AssistDescribeDialog()) }
        DialogRegistry.register("assistAltExport") { AnyView(AssistAltExportDialog()) }
        DialogRegistry.register("assistOCR", dims: false) { AnyView(AssistOCRDialog()) }
        DialogRegistry.register("assistParallax", dims: false) { AnyView(AssistParallaxDialog()) }

        // Panel
        PanelRegistry.register(PanelRegistry.Def(id: findLayersPanelID, title: "Find Layers") { AnyView(AssistFindLayersPanel()) })

        // Layer
        MenuRegistry.add("Layer", "Name Layers Automatically", dividerBefore: true, enabled: hasDoc) { AssistNaming.autoNameAction() }
        MenuRegistry.add("Layer", "Find Layers…", key: "f", modifiers: [.command, .option, .shift], enabled: hasDoc) {
            AppModel.shared.showPanels = true
            WorkspaceManager.shared.reveal(findLayersPanelID)
        }
        MenuRegistry.add("Layer", "Select Similar Looking Layers", enabled: hasDoc) { AssistSearch.selectSimilarAction() }
        MenuRegistry.add("Layer", "Text Behind Subject", submenu: "Smart Assist", enabled: hasText) { AssistSubject.textBehindSubjectAction() }
        MenuRegistry.add("Layer", "Pop Subject", submenu: "Smart Assist", enabled: hasDoc) { AssistSubject.popSubjectAction() }
        MenuRegistry.add("Layer", "Depth Parallax…", submenu: "Smart Assist", enabled: hasDoc) { DialogRegistry.show("assistParallax") }
        MenuRegistry.add("Layer", "Remove Backgrounds of Selected Layers", submenu: "Smart Assist", dividerBefore: true, enabled: hasImageSelection) { AssistSubject.removeBackgroundsAction() }

        // Image
        MenuRegistry.add("Image", "Suggest Crops…", dividerBefore: true, enabled: hasDoc) { DialogRegistry.show("assistCrop") }
        MenuRegistry.add("Image", "Auto-Straighten + Crop", enabled: hasDoc) { AssistCrop.autoStraightenAction() }
        MenuRegistry.add("Image", "Analyze…", dividerBefore: true, enabled: hasDoc) { DialogRegistry.show("assistAnalyze") }
        MenuRegistry.add("Image", "Auto Enhance", enabled: hasDoc) { AssistQuality.autoEnhanceAction() }
        MenuRegistry.add("Image", "Describe Image…", enabled: hasDoc) { DialogRegistry.show("assistDescribe") }

        // Select
        MenuRegistry.add("Select", "Text in Image…", dividerBefore: true, enabled: hasDoc) {
            AssistOCRModel.shared.stop()
            DialogRegistry.show("assistOCR")
        }

        // File ▸ Export
        MenuRegistry.add("File", "Export with Alt Text…", submenu: "Export", dividerBefore: true, enabled: hasDoc) { DialogRegistry.show("assistAltExport") }

        FeatureModules.selfTests.append(("assist", { out in AssistSelfTest.run(out) }))
    }
}
