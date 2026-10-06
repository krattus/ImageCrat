import AppKit
import SwiftUI
import Observation
import ImageCratCore

/// A named version of a document, stored inside the .lumen file (`LumenFile.extras["workflow2.versions"]`).
struct DocVersion: Identifiable {
    let id: UUID
    var name: String
    var note: String
    let date: Date
    /// PNG thumbnail.
    var thumbnail: Data?
    var width: Int
    var height: Int
    var layerCount: Int
}

@Observable
final class VersionStore {
    static let shared = VersionStore()
    static let extrasKey = "workflow2.versions"

    private(set) var byDoc: [UUID: [DocVersion]] = [:]
    /// Live states (share pixel buffers with the history they were taken from).
    @ObservationIgnored private var live: [UUID: DocumentState] = [:]
    /// Encoded, compressed states (from the file, or cached after the first save).
    @ObservationIgnored private var packed: [UUID: Data] = [:]
    @ObservationIgnored private var thumbs: [UUID: NSImage] = [:]
    var selected: [UUID: UUID] = [:]

    func versions(_ d: Document) -> [DocVersion] { byDoc[d.id] ?? [] }

    // MARK: Editing

    /// Saves `state` (default: the document's current committed state) as a named version.
    @discardableResult
    func save(_ d: Document, name: String, note: String = "", state: DocumentState? = nil) -> DocVersion {
        let st = state ?? d.committedState
        let n = name.trimmingCharacters(in: .whitespaces)
        let v = DocVersion(id: UUID(), name: n.isEmpty ? defaultName(d) : n, note: note, date: Date(),
                           thumbnail: Workflow2Util.thumbnail(st, maxSide: 256).flatMap(Workflow2Util.pngData),
                           width: st.width, height: st.height, layerCount: st.allLayers.count)
        live[v.id] = st
        byDoc[d.id, default: []].append(v)
        selected[d.id] = v.id
        // Versions live in the file: make the document dirty so closing asks to save (only when that doesn't cost redo steps).
        if state == nil, !d.canRedo { d.commit("Save Version “\(v.name)”") }
        return v
    }

    func defaultName(_ d: Document) -> String { "Version \(versions(d).count + 1)" }

    /// The full state of a version (decoded on first use for versions read from disk).
    func state(of id: UUID) -> DocumentState? {
        if let s = live[id] { return s }
        guard let data = packed[id], let st = VersionStore.unpack(data) else { return nil }
        live[id] = st
        return st
    }

    /// Restores a version as a new history step (undoable).
    @discardableResult
    func restore(_ id: UUID, in d: Document) -> Bool {
        guard let v = versions(d).first(where: { $0.id == id }), let st = state(of: id) else { return false }
        AppActions.canvas?.commitCurrentTool()
        d.state = st
        d.commit("Restore Version “\(v.name)”")
        selected[d.id] = id
        Compositor.shared.clearCaches()
        if st.width != d.history[max(0, d.historyIndex - 1)].state.width || st.height != d.history[max(0, d.historyIndex - 1)].state.height {
            d.needsFitOnScreen = true
            AppActions.canvas?.fitOnScreen()
        }
        return true
    }

    @discardableResult
    func openAsDocument(_ id: UUID, in d: Document) -> Document? {
        guard let v = versions(d).first(where: { $0.id == id }), let st = state(of: id) else { return nil }
        let nd = Document(state: st, name: "\((d.name as NSString).deletingPathExtension) – \(v.name)")
        AppModel.shared.add(nd)
        return nd
    }

    func delete(_ id: UUID, in d: Document) {
        byDoc[d.id]?.removeAll { $0.id == id }
        live[id] = nil; packed[id] = nil; thumbs[id] = nil
        if selected[d.id] == id { selected[d.id] = nil }
    }

    func update(_ id: UUID, in d: Document, name: String? = nil, note: String? = nil) {
        guard let i = byDoc[d.id]?.firstIndex(where: { $0.id == id }) else { return }
        if let n = name, !n.trimmingCharacters(in: .whitespaces).isEmpty { byDoc[d.id]![i].name = n }
        if let n = note { byDoc[d.id]![i].note = n }
    }

    func thumbnail(_ v: DocVersion) -> NSImage? {
        if let t = thumbs[v.id] { return t }
        guard let img = Workflow2Util.image(fromPNG: v.thumbnail) else { return nil }
        thumbs[v.id] = img
        return img
    }

    /// Rough bytes the versions add to the file (no packing needed).
    func estimatedBytes(_ d: Document) -> Int {
        versions(d).reduce(0) { $0 + (packed[$1.id]?.count ?? live[$1.id].map { Preflight.encodedSize($0) } ?? 0) + ($1.thumbnail?.count ?? 0) }
    }

    func forget(_ docID: UUID) {
        for v in byDoc[docID] ?? [] { live[v.id] = nil; packed[v.id] = nil; thumbs[v.id] = nil }
        byDoc[docID] = nil; selected[docID] = nil
    }

    var trackedDocuments: [UUID] { Array(byDoc.keys) }

    // MARK: File side data

    private struct Item: Codable {
        var id = UUID()
        var name = "Version"
        var note = ""
        var date = Date()
        var thumb: Data? = nil
        var width = 0
        var height = 0
        var layers = 0
        var payload = Data()

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Version"
            note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
            date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? Date()
            thumb = try? c.decodeIfPresent(Data.self, forKey: .thumb)
            width = (try? c.decodeIfPresent(Int.self, forKey: .width)) ?? 0
            height = (try? c.decodeIfPresent(Int.self, forKey: .height)) ?? 0
            layers = (try? c.decodeIfPresent(Int.self, forKey: .layers)) ?? 0
            payload = (try? c.decodeIfPresent(Data.self, forKey: .payload)) ?? Data()
        }
    }

    private struct Container: Codable {
        var format = 1
        var items: [Item] = []

        init(items: [Item]) { self.items = items }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = (try? c.decodeIfPresent(Int.self, forKey: .format)) ?? 1
            items = (try? c.decodeIfPresent([Item].self, forKey: .items)) ?? []
        }
    }

    static func pack(_ st: DocumentState) -> Data? {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        guard let raw = try? enc.encode(st) else { return nil }
        let z = (try? (raw as NSData).compressed(using: .lzfse) as Data) ?? raw
        // 1-byte header: 1 = LZFSE, 0 = plain
        return Data([z.count < raw.count ? 1 : 0]) + (z.count < raw.count ? z : raw)
    }

    static func unpack(_ data: Data) -> DocumentState? {
        guard let flag = data.first else { return nil }
        let body = data.dropFirst()
        let raw: Data
        if flag == 1 { guard let r = try? (Data(body) as NSData).decompressed(using: .lzfse) as Data else { return nil }; raw = r } else { raw = Data(body) }
        return try? PropertyListDecoder().decode(DocumentState.self, from: raw)
    }

    /// Captures what is needed to encode the versions of `d`; the returned closure may run off the main thread (autosave).
    func encoder(for d: Document) -> (() -> Data?)? {
        let list = versions(d)
        guard !list.isEmpty else { return nil }
        let states = list.map { live[$0.id] }
        let cached = list.map { packed[$0.id] }
        return { [weak self] in
            var items: [Item] = []
            for (i, v) in list.enumerated() {
                var payload = cached[i]
                if payload == nil, let st = states[i], let p = VersionStore.pack(st) {
                    payload = p
                    let store: () -> Void = { if self?.packed[v.id] == nil, self?.byDoc[d.id]?.contains(where: { $0.id == v.id }) == true { self?.packed[v.id] = p } }
                    if Thread.isMainThread { store() } else { DispatchQueue.main.async(execute: store) }
                }
                guard let payload else { continue }
                var it = Item()
                it.id = v.id; it.name = v.name; it.note = v.note; it.date = v.date; it.thumb = v.thumbnail
                it.width = v.width; it.height = v.height; it.layers = v.layerCount; it.payload = payload
                items.append(it)
            }
            let enc = PropertyListEncoder()
            enc.outputFormat = .binary
            return try? enc.encode(Container(items: items))
        }
    }

    /// Side data for `DocumentIO.saveNative` (nil when the document has no versions).
    func encode(_ d: Document) -> Data? { encoder(for: d)?() }

    /// Reads side data written by `encode` (tolerant: unreadable versions are skipped). States stay packed until used.
    func decode(_ d: Document, _ data: Data) {
        guard let c = try? PropertyListDecoder().decode(Container.self, from: data) else { return }
        var list: [DocVersion] = []
        for it in c.items where !it.payload.isEmpty {
            packed[it.id] = it.payload
            live[it.id] = nil
            list.append(DocVersion(id: it.id, name: it.name, note: it.note, date: it.date, thumbnail: it.thumb, width: it.width, height: it.height, layerCount: it.layers))
        }
        byDoc[d.id] = list
    }
}

// MARK: - Panel

struct VersionsPanel: View {
    @Bindable var app = AppModel.shared
    @Bindable var store = VersionStore.shared
    @State private var editingNote: UUID?
    @State private var noteText = ""
    @State private var renaming: UUID?
    @State private var nameText = ""
    var docOverride: Document? = nil

    var body: some View {
        if let d = docOverride ?? app.activeDocument {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let list = store.versions(d)
                        if list.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "bookmark").font(.system(size: 22, weight: .light)).foregroundStyle(Theme.textFaint)
                                Text("No versions yet").foregroundStyle(Theme.textDim)
                                Text("Versions are saved inside the document and survive closing it.")
                                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).multilineTextAlignment(.center)
                            }
                            .padding(18).frame(maxWidth: .infinity)
                        }
                        ForEach(list.reversed()) { v in row(d, v) }
                    }
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 4) {
                    let sel = store.selected[d.id]
                    IconButton(symbol: "arrow.uturn.backward", help: "Restore the selected version (adds a history step)", size: 22) { if let s = sel { store.restore(s, in: d) } }
                        .disabled(sel == nil)
                    IconButton(symbol: "rectangle.split.2x1", help: "Compare the canvas with the selected version", size: 22) {
                        if let s = sel { CompareController.shared.start(d, source: .version(s)) }
                    }.disabled(sel == nil)
                    IconButton(symbol: "doc.badge.plus", help: "Open the selected version as a new document", size: 22) { if let s = sel { store.openAsDocument(s, in: d) } }
                        .disabled(sel == nil)
                    Spacer()
                    IconButton(symbol: "plus.square", help: "Save the current state as a version…", size: 22) { DialogRegistry.show("w2.saveVersion") }
                    IconButton(symbol: "trash", help: "Delete the selected version", size: 22) { if let s = sel { store.delete(s, in: d) } }
                        .disabled(sel == nil)
                }
                .padding(.horizontal, 6).frame(height: 30).background(Theme.panelHeader)
            }
            .font(Theme.font)
        } else {
            Text("No document").foregroundStyle(Theme.textFaint).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func row(_ d: Document, _ v: DocVersion) -> some View {
        let sel = store.selected[d.id] == v.id
        return HStack(alignment: .top, spacing: 8) {
            ZStack {
                CheckerBackground(size: 4)
                if let img = store.thumbnail(v) { Image(nsImage: img).resizable().interpolation(.medium).aspectRatio(contentMode: .fit) }
            }
            .frame(width: 54, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                if renaming == v.id {
                    TextField("", text: $nameText).textFieldStyle(.plain).font(Theme.fontBold)
                        .onSubmit { store.update(v.id, in: d, name: nameText); renaming = nil }
                } else {
                    Text(tr(v.name)).font(Theme.fontBold).foregroundStyle(Theme.text).lineLimit(1)
                }
                Text(verbatim: "\(Workflow2Util.relativeTime(v.date)) · \(v.width)×\(v.height)")
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).lineLimit(1)
                    .help("\(Workflow2Util.timeString(v.date)) · \(v.layerCount) layer\(v.layerCount == 1 ? "" : "s")")
                if editingNote == v.id {
                    TextField("Note", text: $noteText).textFieldStyle(.plain).font(Theme.fontSmall)
                        .onSubmit { store.update(v.id, in: d, note: noteText); editingNote = nil }
                } else if !v.note.isEmpty {
                    Text(tr(v.note)).font(Theme.fontSmall).foregroundStyle(Theme.textDim).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(sel ? Theme.selection : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.restore(v.id, in: d) }
        .onTapGesture { store.selected[d.id] = v.id }
        .contextMenu {
            Button("Restore") { store.restore(v.id, in: d) }
            Button("Open as New Document") { store.openAsDocument(v.id, in: d) }
            Button("Compare with Canvas") { CompareController.shared.start(d, source: .version(v.id)) }
            Divider()
            Button("Rename…") { renaming = v.id; nameText = v.name }
            Button("Edit Note…") { editingNote = v.id; noteText = v.note }
            Button("Delete") { store.delete(v.id, in: d) }
        }
    }
}

struct SaveVersionDialog: View {
    @State private var name = ""
    @State private var note = ""

    var body: some View {
        DialogFrame(title: "Save Version", width: 360, okTitle: "Save", onOK: {
            guard let d = AppActions.doc else { return }
            AppActions.canvas?.commitCurrentTool()
            VersionStore.shared.save(d, name: name, note: note)
            WorkspaceManager.shared.reveal("versions")
        }) {
            HStack {
                Text("Name").foregroundStyle(Theme.textDim).frame(width: 50, alignment: .leading)
                TextField(tr(AppActions.doc.map { VersionStore.shared.defaultName($0) } ?? "Version"), text: $name).w2Field()
            }
            HStack(alignment: .top) {
                Text("Note").foregroundStyle(Theme.textDim).frame(width: 50, alignment: .leading)
                TextField("What changed?", text: $note, axis: .vertical).lineLimit(3...5).w2Field()
            }
            Text("Versions are stored inside the .imagecrat file with a thumbnail, and can be restored, compared or opened as a new document later.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
    }
}
