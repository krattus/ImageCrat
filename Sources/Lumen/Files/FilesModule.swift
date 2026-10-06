import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageCratCore

/// File formats & automation module: PSB, PDF, DICOM, Layers to Files, Save for Web, Video Timeline,
/// droplets / Image Processor / Variables, and JavaScript scripting & plugins.
enum FilesModule {
    /// True for command-line runs (self test, droplet processing): no modal UI.
    static var headless: Bool = {
        let a = CommandLine.arguments
        return a.contains("--selftest") || a.contains("--run-action") || a.contains("--run-script")
    }()

    static func register() {
        if !headless { ScriptLibrary.installSamplesIfNeeded() }
        registerFormats()
        registerMenus()
        registerDialogs()
        ScriptingPanels.register()
        VideoTimelineController.install()
        CommandLineRunner.installIfRequested()
        FeatureModules.selfTests.append(("files", { out in FilesSelfTest.run(out) }))
    }

    // MARK: Formats

    static func registerFormats() {
        DocumentIO.customLoaders["pdf"] = { try PDFImport.load(url: $0) }
        DocumentIO.customLoaders["dcm"] = { try DICOM.load(url: $0) }
        DocumentIO.customLoaders["dicom"] = { try DICOM.load(url: $0) }
        DocumentIO.customSavers["psb"] = { d, url in try PSBSupport.save(d, to: url, large: true) }
        DocumentIO.customSavers["psd"] = { d, url in try PSBSupport.save(d, to: url, large: false) }
        DocumentIO.customSavers["pdf"] = { d, url in try PDFUI.save(d, to: url) }
        let psb = UTType(filenameExtension: "psb") ?? .data
        let dcm = UTType(filenameExtension: "dcm") ?? .data
        DocumentIO.extraOpenTypes = [.pdf, psb, dcm]
        DocumentIO.extraSaveTypes = [psb, .pdf]
    }

    // MARK: Menus

    static func registerMenus() {
        let hasDoc: () -> Bool = { AppModel.shared.activeDocument != nil }
        // File > Export
        MenuRegistry.add("File", "Photoshop PDF…", submenu: "Export", enabled: hasDoc) { PDFUI.exportPanel() }
        MenuRegistry.add("File", "Layers to Files…", submenu: "Export", enabled: hasDoc) { DialogRegistry.show("layersToFiles") }
        MenuRegistry.add("File", "Save for Web (Legacy)…", submenu: "Export", key: "s", modifiers: [.command, .option, .shift], enabled: hasDoc) { DialogRegistry.show("saveForWeb") }
        MenuRegistry.add("File", "DICOM…", submenu: "Export", enabled: hasDoc) { DICOM.exportPanel() }
        MenuRegistry.add("File", "Data Sets as Files…", submenu: "Export", enabled: { AppModel.shared.activeDocument?.state.variables?.dataSets.isEmpty == false }) { DialogRegistry.show("exportDataSets") }
        MenuRegistry.add("File", "Render Video…", submenu: "Export", dividerBefore: true, enabled: hasDoc) { DialogRegistry.show("renderVideo") }
        // File > Import
        MenuRegistry.add("File", "Video to Layer…", submenu: "Import") { VideoLayerImport.importPanel() }
        // File > Automate
        MenuRegistry.add("File", "PDF Presentation…", submenu: "Automate") { DialogRegistry.show("pdfPresentation") }
        MenuRegistry.add("File", "Create Droplet…", submenu: "Automate") { DialogRegistry.show("createDroplet") }
        // File > Scripts
        MenuRegistry.add("File", "Image Processor…", submenu: "Scripts") { DialogRegistry.show("imageProcessor") }
        for s in ScriptLibrary.scripts() {
            MenuRegistry.add("File", s.deletingPathExtension().lastPathComponent, submenu: "Scripts", dividerBefore: s == ScriptLibrary.scripts().first) {
                ScriptRunner.runFile(s)
            }
        }
        MenuRegistry.add("File", "Browse…", submenu: "Scripts", dividerBefore: true) { ScriptRunner.browse() }
        MenuRegistry.add("File", "Reveal Scripts Folder", submenu: "Scripts") { NSWorkspace.shared.activateFileViewerSelecting([ScriptLibrary.scriptsFolder]) }
        MenuRegistry.add("File", "Scripting Console", submenu: "Scripts") { WorkspaceManager.shared.float("scriptConsole") }
        // Image > DICOM / Variables
        MenuRegistry.add("Image", "Window/Level…", submenu: "DICOM", enabled: { AppModel.shared.activeDocument.map { DICOMStore.shared.entries[$0.id] != nil } ?? false }) {
            DialogRegistry.show("dicomWindowLevel")
        }
        MenuRegistry.add("Image", "Define…", submenu: "Variables", enabled: hasDoc) { DialogRegistry.show("variablesDefine") }
        MenuRegistry.add("Image", "Data Sets…", submenu: "Variables", enabled: { AppModel.shared.activeDocument?.state.variables?.variables.isEmpty == false }) {
            DialogRegistry.show("variablesDataSets")
        }
        // Window > Plugins
        for p in PluginManager.shared.plugins {
            if p.manifest.entry != nil {
                MenuRegistry.add("Plugins", "Run \(p.manifest.name)") { PluginManager.shared.run(p) }
            }
            if p.manifest.panel != nil {
                MenuRegistry.add("Plugins", "\(p.manifest.name) Panel") { WorkspaceManager.shared.float(p.panelID) }
            }
        }
        MenuRegistry.add("Plugins", "Reveal Plugins Folder", dividerBefore: true) {
            try? FileManager.default.createDirectory(at: ScriptLibrary.pluginsFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([ScriptLibrary.pluginsFolder])
        }
        MenuRegistry.add("Plugins", "Scripting Console") { WorkspaceManager.shared.float("scriptConsole") }
    }

    // MARK: Dialogs

    static func registerDialogs() {
        DialogRegistry.register("layersToFiles") { AnyView(LayersToFilesDialog()) }
        DialogRegistry.register("saveForWeb") { AnyView(SaveForWebDialog()) }
        DialogRegistry.register("pdfPresentation") { AnyView(PDFPresentationDialog()) }
        DialogRegistry.register("renderVideo") { AnyView(RenderVideoDialog()) }
        DialogRegistry.register("createDroplet") { AnyView(CreateDropletDialog()) }
        DialogRegistry.register("imageProcessor") { AnyView(ImageProcessorDialog()) }
        DialogRegistry.register("dicomWindowLevel", dims: false) {
            guard let d = AppModel.shared.activeDocument, let e = DICOMStore.shared.entries[d.id] else { return AnyView(EmptyView()) }
            return AnyView(DICOMWindowLevelDialog(doc: d, entry: e))
        }
        DialogRegistry.register("variablesDefine") {
            guard let d = AppModel.shared.activeDocument else { return AnyView(EmptyView()) }
            return AnyView(VariablesDefineDialog(doc: d))
        }
        DialogRegistry.register("variablesDataSets", dims: false) {
            guard let d = AppModel.shared.activeDocument else { return AnyView(EmptyView()) }
            return AnyView(VariablesDataSetsDialog(doc: d))
        }
        DialogRegistry.register("exportDataSets") {
            guard let d = AppModel.shared.activeDocument else { return AnyView(EmptyView()) }
            return AnyView(ExportDataSetsDialog(doc: d))
        }
    }
}

// MARK: - PSB

enum PSBSupport {
    static let maxPSDDimension = 30000
    static let maxPSDBytes: Int64 = 2_000_000_000

    /// Rough uncompressed size of the PSD data (layer channels + merged image).
    static func estimatedBytes(_ st: DocumentState) -> Int64 {
        var total = Int64(st.width) * Int64(st.height) * 3
        for l in st.allLayers {
            if let r = l.raster { total += Int64(r.buffer.width) * Int64(r.buffer.height) * 4 }
            else if !l.isGroup && !l.isAdjustment { total += Int64(st.width) * Int64(st.height) * 4 }
            if let m = l.mask { total += Int64(m.buffer.width) * Int64(m.buffer.height) }
        }
        return total
    }

    static func needsPSB(_ st: DocumentState) -> Bool {
        st.width > maxPSDDimension || st.height > maxPSDDimension || estimatedBytes(st) > maxPSDBytes
    }

    /// Save As PSD / PSB. A PSD that exceeds the format limits suggests Large Document Format instead.
    static func save(_ d: Document, to url: URL, large: Bool) throws {
        var target = url
        var big = large
        if !large && needsPSB(d.state) {
            if FilesModule.headless {
                big = true
            } else {
                let a = NSAlert()
                a.messageText = tr("This document is too large for the PSD format.")
                a.informativeText = tr("PSD files are limited to 30,000 × 30,000 pixels and 2 GB. Save it in Large Document Format (PSB) instead?")
                a.addButton(withTitle: tr("Save as PSB"))
                a.addButton(withTitle: tr("Cancel"))
                guard UIBlock.run(a) == .alertFirstButtonReturn else { return }
                big = true
            }
            if big { target = url.deletingPathExtension().appendingPathExtension("psb") }
        }
        try PSDWriter.write(d.state, to: target, large: big)
        AppModel.shared.setStatus("Saved \(target.lastPathComponent)")
    }
}

// MARK: - Small UI helpers

enum FilesUI {
    static func chooseFolder(message: String? = nil) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if let m = message { p.message = tr(m) }
        return UIBlock.run(p) == .OK ? p.url : nil
    }

    static func chooseFiles(_ types: [UTType]) -> [URL] {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = types
        return UIBlock.run(p) == .OK ? p.urls : []
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
    }

    /// Runs `body` with `d` as the active document (restores the previous one).
    static func withActive<T>(_ d: Document, _ body: () throws -> T) rethrows -> T {
        let app = AppModel.shared
        let added = !app.documents.contains { $0 === d }
        if added { app.documents.append(d) }
        let prev = app.activeDocumentID
        app.activeDocumentID = d.id
        defer {
            if added { app.documents.removeAll { $0 === d } }
            app.activeDocumentID = prev.flatMap { id in app.documents.contains { $0.id == id } ? id : nil } ?? app.documents.last?.id
        }
        return try body()
    }
}
