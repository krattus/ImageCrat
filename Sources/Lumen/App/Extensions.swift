import SwiftUI

/// Extension points so feature modules can add menu items, dialogs and panels without editing shared files.
/// Each module exposes `static func register()` and is listed in `FeatureModules.registerAll()`.
struct MenuItemSpec: Identifiable {
    let id = UUID()
    var menu: String            // "File", "Edit", "Image", "Layer", "Type", "Select", "Filter", "View", "Window", "Help"
    var title: String
    var submenu: String? = nil   // groups items into a submenu of that name
    var key: KeyEquivalent? = nil
    var modifiers: EventModifiers = .command
    var dividerBefore = false
    var enabled: () -> Bool = { true }
    var action: () -> Void
    /// A toggle (shown with a checkmark when this returns true; the action flips it).
    var checked: (() -> Bool)? = nil
}

enum MenuRegistry {
    static private(set) var items: [MenuItemSpec] = []
    static func add(_ item: MenuItemSpec) { items.append(item) }
    static func add(_ menu: String, _ title: String, submenu: String? = nil, key: KeyEquivalent? = nil, modifiers: EventModifiers = .command,
                    dividerBefore: Bool = false, enabled: @escaping () -> Bool = { true }, checked: (() -> Bool)? = nil, action: @escaping () -> Void) {
        items.append(MenuItemSpec(menu: menu, title: title, submenu: submenu, key: key, modifiers: modifiers, dividerBefore: dividerBefore, enabled: enabled, action: action, checked: checked))
    }
    static func items(for menu: String) -> [MenuItemSpec] { items.filter { $0.menu == menu } }
}

/// Place at the end of a menu to show registered items.
struct ExtensionMenuItems: View {
    let menu: String
    var body: some View {
        let list = MenuRegistry.items(for: menu)
        if !list.isEmpty { Divider() }
        let loose = list.filter { $0.submenu == nil }
        ForEach(loose) { item in row(item) }
        let subs = list.compactMap(\.submenu).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        ForEach(subs, id: \.self) { s in
            Menu(s) { ForEach(list.filter { $0.submenu == s }) { item in row(item) } }
        }
    }

    @ViewBuilder func row(_ item: MenuItemSpec) -> some View {
        if item.dividerBefore { Divider() }
        if let c = item.checked {
            Toggle(item.title, isOn: Binding(get: c, set: { _ in item.action() })).disabled(!item.enabled() || blockedByDialog(item))
        } else if let k = item.key {
            Button(item.title, action: item.action).keyboardShortcut(k, modifiers: item.modifiers).disabled(!item.enabled() || blockedByDialog(item))
        } else {
            Button(item.title, action: item.action).disabled(!item.enabled() || blockedByDialog(item))
        }
    }

    /// While a dialog is open it owns the document (see `noDocument` in LumenApp.swift): module commands that edit the
    /// document or open another dialog wait until it is closed. View / Window / Help items and the character palette stay.
    private func blockedByDialog(_ item: MenuItemSpec) -> Bool {
        guard AppModel.shared.dialog != nil else { return false }
        if ["View", "Window", "Help"].contains(item.menu) || item.title == "Emoji & Symbols" { return false }
        return true
    }
}

/// Dialogs shown through `ActiveDialog.custom(id)`.
enum DialogRegistry {
    static var builders: [String: () -> AnyView] = [:]
    /// Dialog ids that float at the top-right without dimming the canvas (live-preview tools).
    static var nonDimming: Set<String> = []
    static func register(_ id: String, dims: Bool = true, _ make: @escaping () -> AnyView) {
        builders[id] = make
        if !dims { nonDimming.insert(id) }
    }
    static func show(_ id: String) { AppModel.shared.dialog = .custom(id) }
}

/// Feature modules register their menus, dialogs, panels and self tests here.
enum FeatureModules {
    static var selfTests: [(String, (URL) -> Void)] = []
    private static var done = false
    static func registerAll() {
        guard !done else { return }
        done = true
        // (modules add one line each below)
        QAMenusModule.register()   // first: headless automation hooks must be in place before other modules touch UI / defaults
        ModuleIntegration.registerCoreMenus()
        NeuralModule.register()
        ObjectSelectionModule.register()
        ImagingModule.register()
        EditsModule.register()
        FilesModule.register()
        ToolsModule.register()
        GenAIModule.register()
        TypeModule2.register()
        ModuleIntegration.register()
        RegressionTests.register()
        QALayersModule.register()
        QAToolsModule.register()
        WebExportModule.register()
        ParticlesModule.register()
        ArrangeModule.register()
        AssistModule.register()
        Workflow2Module.register()
        ComponentsModule.register()
        NodesModule.register()
        LayoutModule.register()
        ArtistModule.register()
        PDFVectorModule.register()   // after FilesModule: appends .ai to the open types it sets
        SVGImportModule.register()   // after FilesModule (appends to DocumentIO.extraOpenTypes)
        PSDImportModule.register()
        PSDExportSelfTest.register()
        InvFixesModule.register()
        ZoomFXModule.register()
        DocFixesTests.register()
        UIFixesSelfTest.register()   // QA fixes: dialogs, numeric fields, keyboard focus, menu wiring
        ShapeFillBarSelfTest.register()   // shape tools' Fill / Stroke per mode (Shape / Path / Pixels), bar edits of the selected shape, ⌥⌫, colour popover layout (selftest: shapefill; runs early: it hosts SwiftUI windows)
        PSDFidelitySelfTest.register()
        PSDOpenModule.register()     // last: its headless-only run needs every format and open type registered
        ZoomUISelfTest.register()    // status-bar zoom control, zoom presets and shortcuts
        ArtboardsModule.register()   // Photoshop-style artboards: pages on a pasteboard, Artboard tool, panel rows, export; self tests artboards2, artboards3
        Workspace2SelfTest.register()   // panel workspace: docking, tabs, floating windows, named workspaces; status-bar chips
        ShapesFillsModule.register() // stroke options & dashes, fill layer dialogs, shape × vector mask (selftest: shapesfills)
        LayersPanel2Module.register()   // Layers panel effect eyes, group disclosure, Layer Style commands, Move tool auto-select; self test layerspanel2
        TesterKitModule.register()   // Help ▸ Report a Bug… / Open Crash Reports Folder, diagnostic log, models packs (selftest: testerkit)
        RenameSelfTest.register()    // Lumen → ImageCrat: visible names, document types, legacy files, first-launch migration (selftest: rename)
        PanelSizeSelfTest.register()   // panel content vs. the room its group gives it, hosting frames; LUMEN_PANEL_TOUR=<dir> real-window tour (selftest: panelsize)
        BlurGallery2SelfTest.register()   // blur filters and the Blur Gallery with a feathered selection, masked layers, smart objects (selftest: blurgallery2)
        EyeDragSelfTest.register()   // Layers panel eyes: drag across eyes, ⌥-click solo / restore, eye menu (UI/Panels/LayersPanelEyeDrag.swift; selftest: eyedrag)
        BeepSelfTest.register()   // automated runs make no sound; no raw NSSound.beep() (App/Beep.swift)
        MaskTargetSelfTest.register()   // ask whether filters on a selected mask mean the picture (App/MaskTargetPrompt.swift)
        PathsModule.register()       // paths as non-printing outlines (Path mode, Paths panel, conversions) and type on a path (selftests: typepath, paths2)
        BevelFXSelfTest.register()   // inner effects stay inside the layer, smooth bevel shading (selftest: bevelfx)
        PSDFXAddSelfTest.register()  // adding effects to layers imported from PSD with a style (selftest: psdfxadd)
        EmojiSelfTest.register()     // emoji: Character Viewer insertText, text drops, ⌘V, Glyphs panel, emoji rendering and round trips (selftest: emoji)
        LiquifyBoundsSelfTest.register()   // Liquify never crops: layer grows over the canvas, off-canvas pixels kept, smart filter on smart objects (selftest: liquifybounds)
        TabletSelfTest.register()    // drawing tablets: pressure / tilt / rotation / wheel, pen eraser, curve, smoothing, ⌃⌥-drag HUD, keys, quick picker (selftest: tablet)
        FilterCenterSelfTest.register()   // Center option of Twirl / Pinch / Spherize / radial blurs …: Object, Selection, Canvas, Custom (selftest: filtercenter)
        BrushLibraryModule.register()   // brush library: import (.abr .tpl .brush(set) .gbr .gih .kpp .icbrushes), folders, export, Define Brush (selftest: brushlib)
    }
}
