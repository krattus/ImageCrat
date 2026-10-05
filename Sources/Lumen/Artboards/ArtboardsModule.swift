import AppKit
import SwiftUI
import ImageCratCore

/// Photoshop-style artboards: registers menus, dialogs, the commit hook (auto-size canvas, top-level artboards,
/// auto-nesting) and the `artboards2` / `artboards3` self tests.
enum ArtboardsModule {
    static func register() {
        ArtboardOps.installCommitHook()

        DialogRegistry.register("artboardsToFiles") { AnyView(ArtboardsExportDialog(pdf: false)) }
        DialogRegistry.register("artboardsToPDF") { AnyView(ArtboardsExportDialog(pdf: true)) }
        DialogRegistry.register("artboardBackground") { AnyView(ArtboardBackgroundDialog()) }
        DialogRegistry.register("artboardRename") { AnyView(ArtboardRenameDialog()) }

        for (title, menu, submenu, enabled, action) in menuItems() {
            MenuRegistry.add(menu, title, submenu: submenu, enabled: enabled, action: action)
        }
        for (title, checked, toggle) in showItems() {
            MenuRegistry.add("View", title, submenu: "Show", checked: checked, action: toggle)
        }
        ArtboardsSelfTest.register()
        ArtboardsSelfTest3.register()
    }

    static var doc: Document? { AppModel.shared.activeDocument }

    /// View ▸ Show items for artboards (title, checked, toggle). Photoshop has Artboard Names here; the border and the
    /// pasteboard colour are preferences (Preferences ▸ Artboards).
    static func showItems() -> [(String, () -> Bool, () -> Void)] {
        [("Artboard Names", { ArtboardSettings.shared.prefs.showNames }, { ArtboardSettings.shared.prefs.showNames.toggle() })]
    }
    static func boardsSelected() -> Bool { doc.map { !ArtboardOps.selectedBoards($0).isEmpty } ?? false }

    /// (title, menu, submenu, enabled, action) — Layer ▸ Artboards and File ▸ Export ▸ Artboards to PDF.
    static func menuItems() -> [(String, String, String?, () -> Bool, () -> Void)] {
        let hasBoards = { doc.map { !ArtboardOps.boards($0.state).isEmpty } ?? false }
        let selected = { boardsSelected() }
        func onSel(_ f: @escaping (Document, [UUID]) -> Void) -> () -> Void {
            { if let d = doc { let ids = ArtboardOps.selectedBoards(d); if ids.isEmpty { Beep.play() } else { f(d, ids) } } }
        }
        let groupSelected = {
            guard let d = doc, d.selectedLayerIDs.count == 1, let l = d.activeLayer else { return false }
            return l.isGroup && !l.isArtboard
        }
        return [
            ("Artboards to PDF…", "File", "Export", hasBoards, { if let d = doc { ArtboardExport.pdfPanel(d) } }),
            ("Duplicate Artboard", "Layer", "Artboards", selected, onSel { d, ids in ArtboardOps.duplicate(d, ids) }),
            ("Rename Artboard…", "Layer", "Artboards", selected, { DialogRegistry.show("artboardRename") }),
            ("Delete Artboard", "Layer", "Artboards", selected, onSel { d, ids in ArtboardOps.delete(d, ids, keepContents: false) }),
            ("Delete Artboard Only (Keep Contents)", "Layer", "Artboards", selected, onSel { d, ids in ArtboardOps.delete(d, ids, keepContents: true, commitName: "Delete Artboard Only") }),
            ("Artboard from Group", "Layer", "Artboards", groupSelected, { if let d = doc, let id = d.activeLayerID { ArtboardOps.fromGroup(d, id) } }),
            ("Artboard from Layers", "Layer", "Artboards", { doc.map { !$0.selectedLayerIDs.isEmpty } ?? false }, { AppActions.artboardFromLayers() }),
            ("Ungroup Artboards", "Layer", "Artboards", selected, onSel { d, ids in ArtboardOps.ungroup(d, ids) }),
            ("Background: White", "Layer", "Artboards", selected, onSel { d, ids in ArtboardOps.setBackground(d, ids, .white) }),
            ("Background: Black", "Layer", "Artboards", selected, onSel { d, ids in ArtboardOps.setBackground(d, ids, .black) }),
            ("Background: Transparent", "Layer", "Artboards", selected, onSel { d, ids in ArtboardOps.setBackground(d, ids, nil) }),
            ("Background: Other…", "Layer", "Artboards", selected, { DialogRegistry.show("artboardBackground") }),
            ("Fit Canvas to Artboards", "Layer", "Artboards", hasBoards, { if let d = doc { ArtboardActions.fitCanvas(d) } }),
            ("Export Artboard As…", "Layer", "Artboards", selected, onSel { d, ids in ArtboardExport.exportAsPanel(d, ids) }),
        ]
    }
}
