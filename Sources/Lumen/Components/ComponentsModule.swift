import AppKit
import SwiftUI
import ImageCratCore

/// Components with overrides, Clipboard History and HTML & CSS export.
enum ComponentsModule {
    static func register() {
        ComponentActions.installCommitHook()
        registerPanels()
        registerDialogs()
        registerMenus()
        if !FilesModule.headless {
            // pasteboard watching starts once the app is running (never in self tests / command-line runs)
            DispatchQueue.main.async { ClipboardHistory.shared.start() }
        }
        FeatureModules.selfTests.append(("components", { out in ComponentsSelfTest.run(out) }))
    }

    static func registerPanels() {
        PanelRegistry.register(PanelRegistry.Def(id: "components", title: "Components") { AnyView(ComponentsPanel()) })
        PanelRegistry.register(PanelRegistry.Def(id: "clipboardHistory", title: "Clipboard History") { AnyView(ClipboardPanel()) })
    }

    static func registerDialogs() {
        DialogRegistry.register("htmlExport") { AnyView(HTMLExportDialog()) }
    }

    static func registerMenus() {
        let hasDoc: () -> Bool = { AppModel.shared.activeDocument != nil }
        let hasSelection: () -> Bool = { !(AppModel.shared.activeDocument?.orderedSelection.isEmpty ?? true) }
        let isInstance: () -> Bool = { AppModel.shared.activeDocument?.activeLayer?.isComponentInstance == true }
        let hasOverrides: () -> Bool = { AppModel.shared.activeDocument?.activeLayer?.componentInstance?.hasOverrides == true }

        // Layer ▸ Components
        MenuRegistry.add("Layer", "Create Component", submenu: "Components", key: "k", modifiers: [.command, .option], enabled: hasSelection) { ComponentCommands.create() }
        MenuRegistry.add("Layer", "Edit Main Component", submenu: "Components", enabled: isInstance) { ComponentCommands.editMain() }
        MenuRegistry.add("Layer", "Detach Instance", submenu: "Components", key: "b", modifiers: [.command, .option], enabled: isInstance) { ComponentCommands.detach() }
        MenuRegistry.add("Layer", "Reset All Overrides", submenu: "Components", dividerBefore: true, enabled: hasOverrides) { ComponentCommands.resetAll() }
        MenuRegistry.add("Layer", "Push Overrides to Main", submenu: "Components", enabled: hasOverrides) { ComponentCommands.push() }
        MenuRegistry.add("Layer", "New Variant from Overrides…", submenu: "Components", enabled: hasOverrides) { ComponentCommands.saveAsVariant() }
        MenuRegistry.add("Layer", "Select All Instances", submenu: "Components", dividerBefore: true, enabled: isInstance) { ComponentCommands.selectInstances() }
        MenuRegistry.add("Layer", "Components Panel", submenu: "Components") { WorkspaceManager.shared.reveal("components") }

        // Layer ▸ Copy for Web
        MenuRegistry.add("Layer", "Copy CSS", submenu: "Copy for Web", enabled: hasDoc) { WebCopyCommands.copyCSS() }
        MenuRegistry.add("Layer", "Copy as SVG", submenu: "Copy for Web", enabled: { WebCopyCommands.canCopySVG(AppModel.shared.activeDocument?.activeLayer) }) { WebCopyCommands.copySVG() }

        // File ▸ Export
        MenuRegistry.add("File", "HTML & CSS…", submenu: "Export", key: "h", modifiers: [.command, .option, .shift], dividerBefore: true, enabled: hasDoc) { DialogRegistry.show("htmlExport") }

        // Edit
        MenuRegistry.add("Edit", "Paste from History…", key: "v", modifiers: [.command, .control], dividerBefore: true) { ClipboardPopup.show() }
        MenuRegistry.add("Edit", "Copy Foreground Colour as Hex") { ClipboardHistory.shared.copyColor(AppModel.shared.foreground) }

        // Window
        MenuRegistry.add("Window", "Components", dividerBefore: true) { WorkspaceManager.shared.reveal("components") }
        MenuRegistry.add("Window", "Clipboard History") { WorkspaceManager.shared.reveal("clipboardHistory") }
    }
}
