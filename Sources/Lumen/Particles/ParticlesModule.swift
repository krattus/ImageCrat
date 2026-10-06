import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers
import ImageCratCore

/// Particles feature module: top-level "Particles" menu, the editor dialog, re-editable smart objects and self tests.
enum ParticlesModule {
    static func register() {
        FeatureModules.selfTests.append(("particles", { out in ParticleSelfTest.run(out) }))
        registerMenus()
        DialogRegistry.register(ParticleEditor.dialogID, dims: false) { AnyView(ParticleEditorDialog()) }
        DialogRegistry.register("particles.presets") { AnyView(ParticlePresetManager()) }
        ParticleReedit.install()

        // `LUMEN_SELFTEST_ONLY=particles… Lumen --selftest <dir>` runs just these tests (skips the rest of the suite).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count,
           let only = ProcessInfo.processInfo.environment["LUMEN_SELFTEST_ONLY"], only.hasPrefix("particles") {
            _ = NSApplication.shared
            let out = URL(fileURLWithPath: args[i + 1])
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            ParticleSelfTest.run(out)
            print("done (particles only)")
            exit(ParticleSelfTest.failed == 0 ? 0 : 1)
        }
    }

    static let menu = "Particles"

    private static func registerMenus() {
        let hasDoc: () -> Bool = { AppActions.doc != nil }
        MenuRegistry.add(menu, "Particle Editor…", enabled: hasDoc) { ParticleActions.openEditor() }
        for cat in ParticlePresets.categories {
            for p in ParticlePresets.all where p.category == cat {
                let id = p.id
                MenuRegistry.add(menu, p.name + "…", submenu: cat, enabled: hasDoc) { ParticleEditor.open(presetID: id) }
            }
        }
        let tools = "Tools"
        MenuRegistry.add(menu, "Particle Brush (Emit Along Drawn Path)…", submenu: tools, enabled: hasDoc) { ParticleActions.particleBrush() }
        MenuRegistry.add(menu, "From Selection…", submenu: tools, enabled: { AppActions.doc?.state.selection != nil }) { ParticleActions.fromSelection(outline: false) }
        MenuRegistry.add(menu, "From Selection Outline…", submenu: tools, enabled: { AppActions.doc?.state.selection != nil }) { ParticleActions.fromSelection(outline: true) }
        MenuRegistry.add(menu, "From Layer / Text Outlines…", submenu: tools, enabled: hasDoc) { ParticleActions.fromLayer(edges: true) }
        MenuRegistry.add(menu, "Along Path…", submenu: tools, enabled: { AppActions.doc.map { ParticleSources.activePath($0) != nil } ?? false }) { ParticleActions.alongPath() }
        MenuRegistry.add(menu, "Randomize (New Seed)", submenu: tools, dividerBefore: true, enabled: { ParticleEditor.current != nil || (hasDoc() && ParticleEditor.lastEffect != nil) }) { ParticleActions.randomize() }
        MenuRegistry.add(menu, "Repeat Last", submenu: tools, enabled: { hasDoc() && ParticleEditor.lastEffect != nil }) { ParticleActions.repeatLast() }
        MenuRegistry.add(menu, "Edit Particle Layer…", submenu: tools, enabled: { AppActions.doc.map { ParticleStorage.effect(in: $0.activeLayer) != nil } ?? false }) { ParticleActions.editParticleLayer() }
        MenuRegistry.add(menu, "Save Preset…", submenu: tools, dividerBefore: true, enabled: { ParticleEditor.current != nil || ParticleEditor.lastEffect != nil }) { ParticleActions.savePreset(nil) }
        MenuRegistry.add(menu, "Manage Presets…", submenu: tools) { ParticleActions.managePresets() }
    }
}

/// Bumped when `ParticleEditor.current` / `lastEffect` change, so the menu re-evaluates Randomize / Repeat Last / Save Preset.
@Observable final class ParticleMenuState {
    static let shared = ParticleMenuState()
    var revision = 0
}

/// Contents of the top-level Particles menu (used by `ParticleCommands` in LumenApp.swift).
struct ParticleMenuItems: View {
    @Bindable var user = ParticleUserPresets.shared
    @Bindable private var session = ParticleMenuState.shared

    var body: some View {
        let _ = session.revision
        let list = MenuRegistry.items(for: ParticlesModule.menu)
        ForEach(list.filter { $0.submenu == nil }) { item in row(item) }
        Divider()
        let subs = list.compactMap(\.submenu).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        ForEach(subs.filter { $0 != "Tools" }, id: \.self) { s in
            Menu(tr(s)) { ForEach(list.filter { $0.submenu == s }) { item in row(item) } }
        }
        if !user.presets.isEmpty {
            Menu("User Presets") {
                ForEach(user.presets) { e in
                    Button(tr(e.name + "…")) { if let fx = user.load(e.url) { ParticleEditor.open(fx) } }.disabled(AppActions.doc == nil)
                }
            }
        }
        Divider()
        Menu("Tools") { ForEach(list.filter { $0.submenu == "Tools" }) { item in row(item) } }
    }

    @ViewBuilder private func row(_ item: MenuItemSpec) -> some View {
        if item.dividerBefore { Divider() }
        Button(tr(item.title), action: item.action).disabled(!item.enabled())
    }
}

/// Menu commands and small dialogs of the Particles module.
enum ParticleActions {
    static var aspect: Double {
        guard let d = AppActions.doc else { return 16.0 / 9 }
        return Double(d.state.width) / Double(max(1, d.state.height))
    }

    /// The effect to start from: the running session's, the last one used, or a default preset.
    static func baseEffect(default id: String = "magic") -> ParticleEffect {
        if let cur = ParticleEditor.current, !cur.isClosed { return cur.state.effect }
        if var last = ParticleEditor.lastEffect { last.sourceLayerID = nil; last.imagePNG = nil; last.maskCreated = false; return last }
        return ParticlePresets.effect(id, aspect: aspect) ?? ParticleEffect()
    }

    static func openEditor() {
        if let cur = ParticleEditor.current, !cur.isClosed { return }
        ParticleEditor.open(baseEffect(default: "bokeh.circle"))
    }

    static func defaultSubEmitter() -> ParticleSystemSettings {
        var c = ParticleSystemSettings()
        c.name = "Sub-burst"
        c.count = 40; c.spread = 360; c.speedMin = 60; c.speedMax = 300; c.lifeMin = 0.5; c.lifeMax = 1.2
        c.gravity = 200; c.drag = 1.5; c.colorBase = .parent
        c.sprite = .ember; c.sizeMin = 4; c.sizeMax = 7
        c.opacityCurve = .fadeOut
        return c
    }

    /// Particle Brush: drag on the canvas to draw the path the selected system emits along.
    static func particleBrush() {
        guard AppActions.doc != nil else { Beep.play(); return }
        var e = baseEffect()
        if !e.systems.isEmpty { e.systems[0].shape = .path }
        ParticleEditor.open(e, presetID: ParticleEditor.current?.state.presetID)
        ParticleEditor.current?.state.drawPath = true
        ParticleEditor.current?.state.selected = 0
        AppModel.shared.setStatus("Particle Brush: drag on the canvas to draw the emission path.")
    }

    static func fromSelection(outline: Bool) {
        guard let d = AppActions.doc, d.state.selection != nil else { Beep.play(); return }
        var e = baseEffect(default: outline ? "magic" : "glitter")
        for i in e.systems.indices where i == 0 || e.systems[i].shape == e.systems[0].shape {
            e.systems[i].shape = outline ? .selectionOutline : .selectionArea
        }
        e.clipToSelection = false      // the selection is the emitter, not a clip
        ParticleEditor.open(e)
    }

    static func fromLayer(edges: Bool) {
        guard AppActions.doc != nil else { Beep.play(); return }
        var e = baseEffect(default: "magic")
        for i in e.systems.indices where i == 0 || e.systems[i].shape == e.systems[0].shape {
            e.systems[i].shape = edges ? .layerEdges : .layerAlpha
        }
        ParticleEditor.open(e)
    }

    static func alongPath() {
        guard let d = AppActions.doc, let p = ParticleSources.activePath(d) else {
            AppActions.alert("There is no path to emit along.", "Draw a path with the Pen tool (or select a shape layer) first.")
            return
        }
        var e = baseEffect(default: "magic")
        for i in e.systems.indices where i == 0 || e.systems[i].shape == .path || e.systems[i].shape == e.systems[0].shape {
            e.systems[i].shape = .path; e.systems[i].pathPoints = p.points; e.systems[i].pathClosed = p.closed
        }
        ParticleEditor.open(e)
    }

    static func useActivePath(_ st: ParticleEditorState) {
        guard let d = AppActions.doc, let p = ParticleSources.activePath(d) else { Beep.play(); return }
        var s = st.system
        s.shape = .path; s.pathPoints = p.points; s.pathClosed = p.closed
        st.system = s
    }

    static func randomize() {
        if let cur = ParticleEditor.current, !cur.isClosed {
            cur.state.effect.seed = Int.random(in: 1...999_999)
            return
        }
        repeatLast(newSeed: true)
    }

    /// Applies the last effect again without opening the editor (one history step).
    static func repeatLast(newSeed: Bool = false) {
        guard let d = AppActions.doc, var e = ParticleEditor.lastEffect else { Beep.play(); return }
        AppActions.canvas?.commitCurrentTool()
        if newSeed { e.seed = Int.random(in: 1...999_999) }
        e.maskCreated = false; e.imagePNG = nil
        let ed = ParticleEditor(doc: d, effect: e, interactive: false)
        ed.apply()
    }

    static func editParticleLayer() {
        guard let d = AppActions.doc, let id = d.activeLayerID, ParticleEditor.reedit(layer: id) else { Beep.play(); return }
    }

    static func managePresets() {
        ParticleEditor.current?.cancel()
        DialogRegistry.show("particles.presets")
    }

    static func askName(_ title: String, initial: String) -> String? {
        let a = NSAlert()
        a.messageText = tr(title)
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        f.stringValue = initial
        a.accessoryView = f
        a.addButton(withTitle: tr("OK"))
        a.addButton(withTitle: tr("Cancel"))
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let n = f.stringValue.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : n
    }

    static func savePreset(_ effect: ParticleEffect?) {
        guard let e = effect ?? ParticleEditor.current?.state.effect ?? ParticleEditor.lastEffect else { Beep.play(); return }
        guard let name = askName("Save Particle Preset", initial: e.name.isEmpty ? "My Particles" : e.name) else { return }
        do {
            try ParticleUserPresets.shared.save(e, name: name)
            AppModel.shared.setStatus("Saved particle preset “\(name)”.")
        } catch {
            AppActions.alert("Could not save the preset.", error.localizedDescription)
        }
    }

    static func importPresets() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.allowsMultipleSelection = true
        p.message = tr("Choose particle preset files (.json)")
        guard p.runModal() == .OK else { return }
        let n = ParticleUserPresets.shared.importFiles(p.urls)
        AppModel.shared.setStatus(n == 0 ? "No valid particle presets found." : "Imported \(n) particle preset\(n == 1 ? "" : "s").")
    }

    static func exportPreset(_ e: ParticleUserPresets.Entry) {
        let p = NSSavePanel()
        p.allowedContentTypes = [.json]
        p.nameFieldStringValue = e.name + ".json"
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try ParticleUserPresets.shared.export(e, to: url) } catch { AppActions.alert("Could not export the preset.", error.localizedDescription) }
    }

    static func revealPresets() {
        let dir = ParticleUserPresets.shared.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    static func exportSequence(_ editor: ParticleEditor) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = tr("Export")
        p.message = tr("Choose a folder for the PNG sequence")
        let check = NSButton(checkboxWithTitle: tr("Composite over the document (otherwise particles on transparent)"), target: nil, action: nil)
        p.accessoryView = check
        p.isAccessoryViewDisclosed = true
        guard p.runModal() == .OK, let url = p.url else { return }
        let urls = editor.exportSequence(to: url, overDocument: check.state == .on)
        AppModel.shared.setStatus("Exported \(urls.count) PNG frames to “\(url.lastPathComponent)”.")
    }
}

/// Double-clicking a particle smart object (or Layer ▸ Smart Objects ▸ Edit Contents) re-opens the particle editor
/// instead of the embedded document. The app opens a child document for every smart object; this watches for the
/// child of a particle smart object becoming active and swaps it for the editor — no change to shared code.
enum ParticleReedit {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        observe()
    }

    private static func observe() {
        withObservationTracking { _ = AppModel.shared.activeDocumentID } onChange: {
            DispatchQueue.main.async { check(); observe() }
        }
    }

    /// Returns true when a freshly opened particle smart-object child document was replaced by the editor.
    @discardableResult
    static func check(openEditor: Bool = true) -> Bool {
        let app = AppModel.shared
        guard let d = app.activeDocument, let parent = d.smartParent, let lid = d.smartParentLayerID,
              !d.isDirty, d.history.count <= 1, ParticleStorage.effect(in: parent.state.layer(lid)) != nil else { return false }
        app.close(d)
        app.activeDocumentID = parent.id
        parent.selectLayer(lid)
        if openEditor {
            DispatchQueue.main.async { if AppModel.shared.activeDocument === parent { ParticleEditor.reedit(layer: lid) } }
        }
        return true
    }
}
