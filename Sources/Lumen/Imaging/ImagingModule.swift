import SwiftUI
import ImageCratCore

/// Colour modes (Bitmap / Indexed / Duotone / Multichannel), spot channels, swatch libraries, Pattern Preview,
/// Photomerge, Auto-Align / Auto-Blend, Load Files into Stack, Stack Modes and Merge to HDR Pro.
enum ImagingModule {
    static func register() {
        // Dialogs
        DialogRegistry.register("imaging.bitmap") { AnyView(BitmapDialog()) }
        DialogRegistry.register("imaging.indexed", dims: false) { AnyView(IndexedColorDialog()) }
        DialogRegistry.register("imaging.duotone", dims: false) { AnyView(DuotoneDialog()) }
        DialogRegistry.register("imaging.colorTable") { AnyView(ColorTableDialog()) }
        DialogRegistry.register("imaging.spot") { AnyView(SpotChannelDialog()) }
        DialogRegistry.register("imaging.photomerge") { AnyView(PhotomergeDialog()) }
        DialogRegistry.register("imaging.autoAlign") { AnyView(AutoAlignDialog()) }
        DialogRegistry.register("imaging.autoBlend") { AnyView(AutoBlendDialog()) }
        DialogRegistry.register("imaging.loadStack") { AnyView(LoadStackDialog()) }
        DialogRegistry.register("imaging.hdrPro") { AnyView(HDRProDialog()) }
        DialogRegistry.register("imaging.pano360") { AnyView(Pano360Dialog()) }

        let hasDoc = { AppActions.doc != nil }

        // Image
        MenuRegistry.add("Image", "Color Table…", dividerBefore: true, enabled: { AppActions.doc?.state.colorMode == .indexed }) { DialogRegistry.show("imaging.colorTable") }
        MenuRegistry.add("Image", "Duotone Options…", enabled: { AppActions.doc?.state.colorMode == .duotone }) { DialogRegistry.show("imaging.duotone") }

        // View
        MenuRegistry.add("View", "Pattern Preview", submenu: "Pattern Preview", enabled: hasDoc) { if let d = AppActions.doc { PatternPreview.toggle(d) } }

        // File ▸ Automate / Scripts
        MenuRegistry.add("File", "Photomerge…", submenu: "Automate") { DialogRegistry.show("imaging.photomerge") }
        MenuRegistry.add("File", "Merge to HDR Pro…", submenu: "Automate") { DialogRegistry.show("imaging.hdrPro") }
        MenuRegistry.add("File", "Load Files into Stack…", submenu: "Scripts") { DialogRegistry.show("imaging.loadStack") }

        // Edit
        MenuRegistry.add("Edit", "Auto-Align Layers…", dividerBefore: true, enabled: { (AppActions.doc?.selectedLayerIDs.count ?? 0) >= 2 }) { DialogRegistry.show("imaging.autoAlign") }
        MenuRegistry.add("Edit", "Auto-Blend Layers…", enabled: { (AppActions.doc?.selectedLayerIDs.count ?? 0) >= 2 }) { DialogRegistry.show("imaging.autoBlend") }

        // Layer ▸ Smart Objects ▸ Stack Mode
        for m in StackMode.allCases {
            MenuRegistry.add("Layer", m.rawValue, submenu: "Stack Mode", dividerBefore: m == .entropy, enabled: { AppActions.doc?.activeLayer?.isSmartObject == true }) { StackModes.setStackMode(m) }
        }

        // Filter ▸ 360 Panorama
        MenuRegistry.add("Filter", "Export Equirectangular 360° (2:1)…", submenu: "360 Panorama", enabled: hasDoc) { DialogRegistry.show("imaging.pano360") }

        FeatureModules.selfTests.append(("imaging", { out in ImagingSelfTest.run(out) }))
    }
}
