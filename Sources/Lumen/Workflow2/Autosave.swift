import AppKit
import SwiftUI
import Observation
import ImageCratCore

// MARK: - Recovery manifest

/// One autosaved document inside a session folder (`Recovery/<session>/<doc>.json` + rolling `.imagecrat` copies).
struct RecoveryEntry: Codable, Identifiable {
    var id = ""
    var name = "Untitled"
    var originalPath: String? = nil
    var date = Date()
    var width = 0
    var height = 0
    var thumb: Data? = nil
    /// Recovery copies, newest first (file names inside the session folder).
    var files: [String] = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Untitled"
        originalPath = try? c.decodeIfPresent(String.self, forKey: .originalPath)
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? Date()
        width = (try? c.decodeIfPresent(Int.self, forKey: .width)) ?? 0
        height = (try? c.decodeIfPresent(Int.self, forKey: .height)) ?? 0
        thumb = try? c.decodeIfPresent(Data.self, forKey: .thumb)
        files = (try? c.decodeIfPresent([String].self, forKey: .files)) ?? []
    }
}

/// A recoverable document found after an unclean exit.
struct RecoveryItem: Identifiable {
    var id: String { session.lastPathComponent + "/" + entry.id }
    var session: URL
    var entry: RecoveryEntry
    var newestFile: URL? { entry.files.first.map { session.appendingPathComponent($0) } }
    var bytes: Int { newestFile.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size]) as? Int } ?? 0 }
}

// MARK: - Autosave

/// Autosave & crash recovery. Each app run owns a session folder; a clean quit removes it, so any session folder whose
/// process is gone means ImageCrat did not exit cleanly and its documents are offered for recovery on the next launch.
final class Autosave {
    static let shared = Autosave()

    let sessionID: String
    let pid: Int32
    private let rootOverride: URL?
    private let queue = DispatchQueue(label: "lumen.workflow2.autosave", qos: .utility)
    /// History step (entry id) each document was last autosaved at.
    private var savedAt: [UUID: UUID] = [:]
    private var counters: [UUID: Int] = [:]
    private var timer: Timer?
    private var lastRun = Date()
    private var observers: [NSObjectProtocol] = []
    private(set) var started = false
    /// Quitting to restart (L10nRestart): the session folder stays, so its documents are offered for recovery.
    var keepSessionOnQuit = false

    init(root: URL? = nil, sessionID: String = UUID().uuidString, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        rootOverride = root
        self.sessionID = sessionID
        self.pid = pid
    }

    var recoveryRoot: URL { rootOverride ?? Workflow2Paths.root.appendingPathComponent("Recovery", isDirectory: true) }
    var sessionDir: URL { recoveryRoot.appendingPathComponent(sessionID, isDirectory: true) }

    private struct SessionInfo: Codable { var pid: Int32; var started: Date }

    private func ensureSession() {
        let fm = FileManager.default
        if fm.fileExists(atPath: sessionDir.appendingPathComponent("session.json").path) { return }
        try? fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(SessionInfo(pid: pid, started: Date())) {
            try? d.write(to: sessionDir.appendingPathComponent("session.json"), options: .atomic)
        }
    }

    // MARK: Lifecycle (GUI runs only)

    func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
            let p = Workflow2Settings.shared.prefs
            if p.autosaveEnabled, p.autosaveOnDeactivate { self?.saveAll() }
        })
        observers.append(nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            if self?.keepSessionOnQuit == true { self?.flush(); return }
            self?.endSession()
        })
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let p = Workflow2Settings.shared.prefs
        reconcile()
        Workflow2Module.pruneClosedDocuments()
        guard p.autosaveEnabled, Date().timeIntervalSince(lastRun) >= max(1, p.autosaveMinutes) * 60 else { return }
        saveAll()
    }

    // MARK: Saving

    static func needsAutosave(_ d: Document) -> Bool { d.isDirty && d.smartParent == nil && d.history.count > 1 }

    /// Autosaves every unsaved document that changed since its last recovery copy.
    func saveAll(sync: Bool = false) {
        lastRun = Date()
        reconcile()
        for d in AppModel.shared.documents where Autosave.needsAutosave(d) { save(d, sync: sync) }
    }

    /// Writes a recovery copy of `d` from a snapshot of its committed state. The encoding and the (atomic) write happen
    /// off the main thread unless `sync`.
    func save(_ d: Document, sync: Bool = false, force: Bool = false, completion: (() -> Void)? = nil) {
        guard d.history.indices.contains(d.historyIndex) else { completion?(); return }
        let entryID = d.history[d.historyIndex].id
        if !force, savedAt[d.id] == entryID { completion?(); return }
        savedAt[d.id] = entryID
        ensureSession()

        // snapshot on the main thread (value types; pixel buffers referenced by history are immutable)
        let state = d.committedState
        let name = d.name
        let key = d.id.uuidString
        let n = (counters[d.id] ?? 0) + 1
        counters[d.id] = n
        let keep = max(1, Workflow2Settings.shared.prefs.autosaveKeep)
        let dir = sessionDir
        var entry = RecoveryEntry()
        entry.id = key; entry.name = name; entry.originalPath = d.fileURL?.path; entry.date = Date()
        entry.width = state.width; entry.height = state.height
        entry.thumb = Workflow2Util.thumbnail(state, maxSide: 160).flatMap(Workflow2Util.pngData)
        let extras: [String: () -> Data?] = Workflow2Module.extrasEncoders(for: d)

        let work = {
            let fm = FileManager.default
            let file = "\(key)-\(String(format: "%04d", n)).\(Brand.documentExtension)"
            var packedExtras: [String: Data] = [:]
            for (k, make) in extras { if let v = make() { packedExtras[k] = v } }
            let enc = PropertyListEncoder()
            enc.outputFormat = .binary
            guard let data = try? enc.encode(LumenFile(name: name, state: state, extras: packedExtras.isEmpty ? nil : packedExtras)) else { return }
            do { try data.write(to: dir.appendingPathComponent(file), options: .atomic) } catch { return }
            // rolling copies: newest first, prune beyond `keep`
            let manifestURL = dir.appendingPathComponent(key + ".json")
            var files = [file]
            if let old = try? Data(contentsOf: manifestURL), let prev = try? JSONDecoder().decode(RecoveryEntry.self, from: old) {
                files += prev.files.filter { $0 != file }
            }
            for f in files.dropFirst(keep) { try? fm.removeItem(at: dir.appendingPathComponent(f)) }
            entry.files = Array(files.prefix(keep))
            if let m = try? JSONEncoder().encode(entry) { try? m.write(to: manifestURL, options: .atomic) }
        }
        if sync { queue.sync(execute: work); completion?() } else {
            queue.async { work(); if let c = completion { DispatchQueue.main.async(execute: c) } }
        }
    }

    /// Waits for pending background writes (tests, quitting).
    func flush() { queue.sync {} }

    // MARK: Cleanup

    /// Removes the recovery copies of documents that were saved or closed.
    func reconcile() {
        let docs = AppModel.shared.documents
        let live = Set(docs.filter { Autosave.needsAutosave($0) }.map { $0.id.uuidString })
        let dir = sessionDir
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        for d in docs where !Autosave.needsAutosave(d) { savedAt[d.id] = nil }
        queue.async {
            for e in Autosave.entries(in: dir) where !live.contains(e.id) { Autosave.remove(e, in: dir) }
        }
    }

    /// Clean exit: nothing of this session is left behind.
    func endSession() {
        timer?.invalidate(); timer = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        flush()
        try? FileManager.default.removeItem(at: sessionDir)
        // remove the Recovery folder itself when it is empty
        if let rest = try? FileManager.default.contentsOfDirectory(atPath: recoveryRoot.path), rest.filter({ !$0.hasPrefix(".") }).isEmpty {
            try? FileManager.default.removeItem(at: recoveryRoot)
        }
        savedAt = [:]
    }

    static func entries(in session: URL) -> [RecoveryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "session.json" }.compactMap { u in
            guard let d = try? Data(contentsOf: u), let e = try? JSONDecoder().decode(RecoveryEntry.self, from: d), !e.id.isEmpty else { return nil }
            return e
        }
    }

    static func remove(_ e: RecoveryEntry, in session: URL) {
        let fm = FileManager.default
        for f in e.files { try? fm.removeItem(at: session.appendingPathComponent(f)) }
        try? fm.removeItem(at: session.appendingPathComponent(e.id + ".json"))
        // stray copies of the same document
        for u in (try? fm.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)) ?? [] where u.lastPathComponent.hasPrefix(e.id + "-") {
            try? fm.removeItem(at: u)
        }
    }

    // MARK: Recovery

    /// Whether the process that owns a session folder is an ImageCrat that is still running (another open copy of the app,
    /// or a Lumen from before the rename).
    /// A pid that was recycled by some other program does not count. Replaceable for tests.
    static var isSessionAlive: (Int32) -> Bool = { pid in
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier, kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return true }
        let theirs = (String(cString: buf) as NSString).lastPathComponent
        let ours = (Bundle.main.executablePath as NSString?)?.lastPathComponent ?? Brand.executableName
        return theirs == ours || theirs == Brand.Legacy.executableName
    }

    /// Documents left behind by sessions that did not exit cleanly (their process is gone), newest first.
    func recoverable() -> [RecoveryItem] {
        let fm = FileManager.default
        var out: [RecoveryItem] = []
        for s in (try? fm.contentsOfDirectory(at: recoveryRoot, includingPropertiesForKeys: nil)) ?? [] {
            guard s.lastPathComponent != sessionID, (try? s.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if let d = try? Data(contentsOf: s.appendingPathComponent("session.json")), let info = try? JSONDecoder().decode(SessionInfo.self, from: d),
               info.pid != pid, Autosave.isSessionAlive(info.pid) { continue }     // another running copy of the app
            let list = Autosave.entries(in: s).filter { e in e.files.contains { fm.fileExists(atPath: s.appendingPathComponent($0).path) } }
            if list.isEmpty { try? fm.removeItem(at: s); continue }
            out += list.map { RecoveryItem(session: s, entry: $0) }
        }
        return out.sorted { $0.entry.date > $1.entry.date }
    }

    /// Loads the newest readable recovery copy as an unsaved document (falls back to older copies when the newest is damaged).
    func load(_ item: RecoveryItem) -> Document? {
        for f in item.entry.files {
            let u = item.session.appendingPathComponent(f)
            guard let d = try? DocumentIO.load(url: u) else { continue }
            d.name = item.entry.name
            if let p = item.entry.originalPath, FileManager.default.fileExists(atPath: p) { d.fileURL = URL(fileURLWithPath: p) } else { d.fileURL = nil }
            d.commit("Recovered")        // unsaved: closing asks to save
            return d
        }
        return nil
    }

    /// Recovers documents into the app; their old recovery copies are removed once the new session has its own copy.
    @discardableResult
    func recover(_ items: [RecoveryItem], addToApp: Bool = true) -> [Document] {
        var docs: [Document] = []
        for it in items {
            guard let d = load(it) else { continue }
            docs.append(d)
            if addToApp { AppModel.shared.add(d) }
            save(d, sync: !addToApp, force: true) { self.discard([it]) }
        }
        return docs
    }

    func discard(_ items: [RecoveryItem]) {
        let fm = FileManager.default
        for it in items {
            Autosave.remove(it.entry, in: it.session)
            if Autosave.entries(in: it.session).isEmpty { try? fm.removeItem(at: it.session) }
        }
        if let rest = try? fm.contentsOfDirectory(atPath: recoveryRoot.path), rest.filter({ !$0.hasPrefix(".") }).isEmpty {
            try? fm.removeItem(at: recoveryRoot)
        }
    }
}

// MARK: - Recovery dialog

@Observable
final class RecoveryUI {
    static let shared = RecoveryUI()
    var items: [RecoveryItem] = []
    var chosen: Set<String> = []

    /// Called shortly after launch.
    func offerIfNeeded() {
        let found = Autosave.shared.recoverable()
        guard !found.isEmpty else { return }
        items = found
        chosen = Set(found.map(\.id))
        DialogRegistry.show("w2.recovery")
    }

    func refresh() {
        items = Autosave.shared.recoverable()
        chosen = Set(items.map(\.id))
    }
}

struct RecoveryDialog: View {
    @Bindable var ui = RecoveryUI.shared
    /// Snapshot tests pass items directly.
    var preview: [RecoveryItem]? = nil

    var body: some View {
        let items = preview ?? ui.items
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lifepreserver").font(.system(size: 20)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Recover \(items.count) document\(items.count == 1 ? "" : "s")").font(.system(size: 13, weight: .semibold))
                    Text("ImageCrat did not quit cleanly last time. These documents had unsaved changes.").font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                }
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { it in
                        let on = preview != nil || ui.chosen.contains(it.id)
                        HStack(spacing: 9) {
                            Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 12)).foregroundStyle(on ? Theme.accent : Theme.textDim)
                            ZStack {
                                CheckerBackground(size: 4)
                                if let img = Workflow2Util.image(fromPNG: it.entry.thumb) { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit) }
                            }
                            .frame(width: 56, height: 42).clipShape(RoundedRectangle(cornerRadius: 3))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tr(it.entry.name)).font(Theme.fontBold).lineLimit(1)
                                Text(verbatim: "Autosaved \(Workflow2Util.timeString(it.entry.date)) · \(it.entry.width)×\(it.entry.height) · \(Workflow2Util.byteString(it.bytes))")
                                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).lineLimit(1)
                                Text(tr(it.entry.originalPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Never saved"))
                                    .font(Theme.fontSmall).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { if ui.chosen.contains(it.id) { ui.chosen.remove(it.id) } else { ui.chosen.insert(it.id) } }
                    }
                }
            }
            .frame(width: 420, height: min(260, CGFloat(max(1, items.count)) * 56 + 4))
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.fieldBG))
            HStack {
                Button("Discard All") {
                    Autosave.shared.discard(ui.items); ui.items = []; AppModel.shared.dialog = nil
                }.buttonStyle(PanelButtonStyle())
                Spacer()
                Button("Later") { AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                    .help("Keep the recovery files; File ▸ Recover Documents… offers them again")
                Button("Recover Selected") {
                    let pick = ui.items.filter { ui.chosen.contains($0.id) }
                    AppModel.shared.dialog = nil
                    let docs = Autosave.shared.recover(pick)
                    ui.items.removeAll { ui.chosen.contains($0.id) }
                    AppModel.shared.setStatus("Recovered \(docs.count) document\(docs.count == 1 ? "" : "s").")
                }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(preview == nil && ui.chosen.isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
    }
}

// MARK: - Save Incremental / Revert to Saved

enum FileVersions {
    /// `poster.imagecrat` → `poster_v002.imagecrat`, `poster_v002.imagecrat` → `poster_v003.imagecrat` (a `.lumen` file keeps its
    /// extension); skips numbers already on disk.
    static func nextIncrementalURL(for url: URL, existing: [String]? = nil) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var base = stem, current = 1, digits = 3
        if let r = stem.range(of: #"_v(\d+)$"#, options: .regularExpression) {
            let num = String(stem[r].dropFirst(2))
            current = Int(num) ?? 1
            digits = max(3, num.count)
            base = String(stem[..<r.lowerBound])
        }
        let names = existing ?? ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        var maxN = current
        let prefix = base + "_v"
        for n in names {
            let s = (n as NSString).deletingPathExtension
            guard (n as NSString).pathExtension.lowercased() == ext.lowercased(), s.hasPrefix(prefix) else { continue }
            let tail = s.dropFirst(prefix.count)
            if !tail.isEmpty, tail.allSatisfy(\.isNumber), let v = Int(tail) { maxN = max(maxN, v); digits = max(digits, tail.count) }
        }
        let next = String(format: "%0\(digits)d", max(2, maxN + 1))
        return dir.appendingPathComponent("\(base)_v\(next)").appendingPathExtension(ext)
    }

    /// File ▸ Save Incremental: saves the document under the next version number and continues working in that file.
    @discardableResult
    static func saveIncremental(_ doc: Document? = nil) -> URL? {
        guard let d = doc ?? AppActions.doc else { return nil }
        AppActions.canvas?.commitCurrentTool()
        guard let url = d.fileURL, Brand.isNativeDocument(url) else {
            if !FilesModule.headless { AppActions.saveAs() }
            return nil
        }
        let next = nextIncrementalURL(for: url)
        do {
            try DocumentIO.saveNative(d, to: next)
            d.fileURL = next
            d.name = next.lastPathComponent
            d.markSaved()
            if !FilesModule.headless { NSDocumentController.shared.noteNewRecentDocumentURL(next) }
            AppModel.shared.setStatus("Saved as \(next.lastPathComponent).")
            return next
        } catch {
            if !FilesModule.headless { AppActions.alert("Could not save the document.", error.localizedDescription) }
            return nil
        }
    }

    static func canRevert(_ d: Document?) -> Bool {
        guard let d, let u = d.fileURL else { return false }
        return d.smartParent == nil && FileManager.default.fileExists(atPath: u.path)
    }

    /// File ▸ Revert to Saved: reloads the file as a new history step (so the revert itself can be undone).
    @discardableResult
    static func revertToSaved(_ doc: Document? = nil, confirm: Bool = true) -> Bool {
        guard let d = doc ?? AppActions.doc, canRevert(d), let url = d.fileURL else { Beep.play(); return false }
        if confirm, !FilesModule.headless, d.isDirty,
           !AppActions.confirm("Revert to the last saved version of “\(d.name)”?", "Your unsaved changes stay in the History panel and can be brought back with Undo.", ok: "Revert") { return false }
        AppActions.canvas?.commitCurrentTool()
        guard let loaded = try? DocumentIO.load(url: url) else {
            if !FilesModule.headless { AppActions.alert("Could not read “\(url.lastPathComponent)”.") }
            return false
        }
        Workflow2Module.forget(loaded.id)      // side data read for the temporary document
        let sizeChanged = loaded.state.width != d.state.width || loaded.state.height != d.state.height
        d.state = loaded.state
        d.commit("Revert")
        d.markSaved()
        Compositor.shared.clearCaches()
        if sizeChanged { d.needsFitOnScreen = true; AppActions.canvas?.fitOnScreen() }
        return true
    }
}
