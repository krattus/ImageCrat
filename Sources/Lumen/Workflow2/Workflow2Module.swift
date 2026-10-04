import AppKit
import SwiftUI

/// Workflow features Photoshop lacks: command palette, branching history + versions + compare, autosave & recovery,
/// history → action, process timelapse, preflight, quick compare & isolate.
enum Workflow2Module {
    private static var hooksInstalled = false

    static func register() {
        installHooks()
        registerMenus()
        registerDialogs()
        PanelRegistry.register(PanelRegistry.Def(id: "historyTree", title: "History Tree") { AnyView(HistoryTreePanel()) })
        PanelRegistry.register(PanelRegistry.Def(id: "versions", title: "Versions") { AnyView(VersionsPanel()) })
        PanelRegistry.register(PanelRegistry.Def(id: "preflight", title: "Preflight") { AnyView(PreflightPanel()) })
        FeatureModules.selfTests.append(("workflow2", { out in Workflow2SelfTest.run(out) }))
        if !FilesModule.headless { startServices() }
    }

    // MARK: Hooks

    /// History, command and file hooks (idempotent; also used by the self test).
    static func installHooks() {
        guard !hooksInstalled else { return }
        hooksInstalled = true
        let prevDiscard = Document.willDiscardRedo
        Document.willDiscardRedo = { d, tail in
            prevDiscard?(d, tail)
            HistoryTree.shared.noteDiscard(d, tail)
        }
        let prevCommit = Document.didCommit
        Document.didCommit = { d in
            prevCommit?(d)
            CommandLog.shared.didCommit(d)
            Timelapse.shared.didCommit(d)
            IsolateMode.shared.refresh()
            CompareController.shared.validate()
        }
        let prevObserver = ActionRecorder.observer
        ActionRecorder.observer = { step in
            prevObserver?(step)
            CommandLog.shared.observe(step)
        }
        DocumentIO.nativeExtrasWriters[VersionStore.extrasKey] = { VersionStore.shared.encode($0) }
        DocumentIO.nativeExtrasReaders[VersionStore.extrasKey] = { VersionStore.shared.decode($0, $1) }
        DocumentIO.nativeExtrasWriters[Timelapse.extrasKey] = { Timelapse.shared.encode($0, markSaved: true) }
        DocumentIO.nativeExtrasReaders[Timelapse.extrasKey] = { Timelapse.shared.decode($0, $1) }
    }

    /// Side-data encoders for a recovery copy; the closures may run off the main thread.
    static func extrasEncoders(for d: Document) -> [String: () -> Data?] {
        var out: [String: () -> Data?] = [:]
        if let e = VersionStore.shared.encoder(for: d) { out[VersionStore.extrasKey] = e }
        if let t = Timelapse.shared.encode(d, markSaved: false) { out[Timelapse.extrasKey] = { t } }
        return out
    }

    /// Drops everything Workflow2 remembers about a document id.
    static func forget(_ id: UUID) {
        HistoryTree.shared.forget(id)
        VersionStore.shared.forget(id)
        Timelapse.shared.forget(id)
        PreflightModel.shared.forget(id)
    }

    /// Releases side data of documents that are no longer open (history branches and versions hold whole states).
    static func pruneClosedDocuments() {
        let open = Set(AppModel.shared.documents.map(\.id))
        let tracked = Set(HistoryTree.shared.trackedDocuments + VersionStore.shared.trackedDocuments + Timelapse.shared.trackedDocuments + PreflightModel.shared.trackedDocuments)
        for id in tracked.subtracting(open) { forget(id) }
        if let id = CompareController.shared.docID, !open.contains(id) { CompareController.shared.exit() }
        if let id = IsolateMode.shared.docID, !open.contains(id) { IsolateMode.shared.exit() }
    }

    // MARK: Services (GUI runs only)

    private static func startServices() {
        Autosave.shared.start()
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                RecoveryUI.shared.offerIfNeeded()
                DispatchQueue.global(qos: .utility).async { Timelapse.pruneOrphans() }
            }
        }
    }

    // MARK: Menus

    static func registerMenus() {
        let hasDoc: () -> Bool = { AppModel.shared.activeDocument != nil }
        let f12 = KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!))

        // Edit
        MenuRegistry.add("Edit", "Command Palette…", key: "p", modifiers: [.command, .shift], dividerBefore: true) { CommandPalette.shared.toggle() }
        MenuRegistry.add("Edit", "Repeat Last Command", key: "r", modifiers: [.command, .control], enabled: { HistoryActions.canRepeat }) { HistoryActions.repeatLast() }
        MenuRegistry.add("Edit", "Apply Last Command to Selected Layers", enabled: { HistoryActions.canRepeat }) { HistoryActions.applyLastToSelected() }
        MenuRegistry.add("Edit", "Apply Last Command to All Layers of This Kind", enabled: { HistoryActions.canRepeat }) { HistoryActions.applyLastToSameKind() }
        MenuRegistry.add("Edit", "Create Action from History Steps…", enabled: { (AppModel.shared.activeDocument?.history.count ?? 0) > 1 }) { DialogRegistry.show("w2.historyAction") }

        // File
        MenuRegistry.add("File", "Save Incremental", key: "s", modifiers: [.command, .option], dividerBefore: true, enabled: hasDoc) { FileVersions.saveIncremental() }
        MenuRegistry.add("File", "Save Version…", enabled: hasDoc) { DialogRegistry.show("w2.saveVersion") }
        MenuRegistry.add("File", "Revert to Saved", key: f12, modifiers: [], enabled: { FileVersions.canRevert(AppModel.shared.activeDocument) }) { FileVersions.revertToSaved() }
        MenuRegistry.add("File", "Recover Documents…") {
            RecoveryUI.shared.refresh()
            if RecoveryUI.shared.items.isEmpty { AppModel.shared.setStatus("There are no documents to recover.") } else { DialogRegistry.show("w2.recovery") }
        }
        MenuRegistry.add("File", "Clean Up Document…", enabled: hasDoc) { PreflightModel.showCleanUp() }
        MenuRegistry.add("File", "Toggle Timelapse Recording", dividerBefore: true, enabled: hasDoc) { if let d = AppActions.doc { Timelapse.shared.toggle(d) } }
        MenuRegistry.add("File", "Timelapse Video…", submenu: "Export", enabled: hasDoc) { DialogRegistry.show("w2.timelapseExport") }

        // View ▸ Compare
        func compare(_ s: CompareSource) { if let d = AppActions.doc { AppActions.canvas?.commitCurrentTool(); CompareController.shared.start(d, source: s) } }
        MenuRegistry.add("View", "with Original", submenu: "Compare", enabled: hasDoc) { compare(.original) }
        MenuRegistry.add("View", "with Previous History State", submenu: "Compare", enabled: { (AppModel.shared.activeDocument?.historyIndex ?? 0) > 0 }) { compare(.previous) }
        MenuRegistry.add("View", "with Snapshot, Version, Branch or History State…", submenu: "Compare", enabled: hasDoc) { DialogRegistry.show("w2.compareSource") }
        for l in CompareLayout.allCases {
            MenuRegistry.add("View", l.rawValue, submenu: "Compare", dividerBefore: l == .split, enabled: { CompareController.shared.isActive }) { CompareController.shared.layout = l }
        }
        MenuRegistry.add("View", "Exit Compare", submenu: "Compare", dividerBefore: true, enabled: { CompareController.shared.isActive }) { CompareController.shared.exit() }
        MenuRegistry.add("View", "Isolate Selected Layers", key: "i", modifiers: [.command, .control], enabled: hasDoc) { if let d = AppActions.doc { IsolateMode.shared.toggle(d) } }

        // Window
        MenuRegistry.add("Window", "History Tree", dividerBefore: true) { WorkspaceManager.shared.reveal("historyTree") }
        MenuRegistry.add("Window", "Versions") { WorkspaceManager.shared.reveal("versions") }
        MenuRegistry.add("Window", "Preflight") { WorkspaceManager.shared.reveal("preflight") }
    }

    static func registerDialogs() {
        DialogRegistry.register("w2.saveVersion") { AnyView(SaveVersionDialog()) }
        DialogRegistry.register("w2.compareSource") { AnyView(CompareSourceDialog()) }
        DialogRegistry.register("w2.recovery") { AnyView(RecoveryDialog()) }
        DialogRegistry.register("w2.historyAction") { AnyView(HistoryActionDialog()) }
        DialogRegistry.register("w2.timelapseExport") { AnyView(TimelapseExportDialog()) }
        DialogRegistry.register("w2.cleanup") { AnyView(CleanUpDialog()) }
    }
}
