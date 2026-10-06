import SwiftUI
import Observation
import ImageCratCore

// MARK: - History snapshots

struct HistorySnapshot: Identifiable {
    let id = UUID()
    var name: String
    let state: DocumentState
    let date = Date()
}

/// Per-document snapshots (in memory, like Photoshop). The first snapshot is taken of the document's
/// earliest available state the first time the History panel shows the document.
@Observable
final class SnapshotStore {
    static let shared = SnapshotStore()
    private(set) var byDoc: [UUID: [HistorySnapshot]] = [:]
    var selected: [UUID: UUID] = [:]

    func snapshots(_ d: Document) -> [HistorySnapshot] { byDoc[d.id] ?? [] }

    func ensureInitial(_ d: Document) {
        guard byDoc[d.id] == nil, let first = d.history.first else { return }
        byDoc[d.id] = [HistorySnapshot(name: d.name, state: first.state)]
    }

    @discardableResult
    func newSnapshot(_ d: Document, name: String? = nil) -> HistorySnapshot {
        ensureInitial(d)
        let n = name ?? "Snapshot \(snapshots(d).count)"
        let s = HistorySnapshot(name: n, state: d.committedState)
        byDoc[d.id, default: []].append(s)
        return s
    }

    /// Reverts to a snapshot non-destructively: the snapshot state becomes a new history step.
    func revert(_ d: Document, to s: HistorySnapshot) {
        AppActions.canvas?.commitCurrentTool()
        d.state = s.state
        d.commit("Snapshot: \(s.name)")
        selected[d.id] = s.id
        Compositor.shared.clearCaches()
    }

    @discardableResult
    func newDocument(from s: HistorySnapshot, of d: Document) -> Document {
        let nd = Document(state: s.state, name: s.name == d.name ? "\(d.name) copy" : s.name)
        AppModel.shared.add(nd)
        return nd
    }

    func rename(_ d: Document, _ id: UUID, to name: String) {
        guard let i = byDoc[d.id]?.firstIndex(where: { $0.id == id }) else { return }
        byDoc[d.id]![i].name = name
    }

    /// A closed document's snapshots (whole states) go with it.
    func forget(_ docID: UUID) {
        if byDoc[docID] != nil { byDoc.removeValue(forKey: docID) }
        if selected[docID] != nil { selected.removeValue(forKey: docID) }
    }

    func delete(_ d: Document, _ id: UUID) {
        byDoc[d.id]?.removeAll { $0.id == id }
    }
}

/// Snapshot rows at the top of the History panel, with New Snapshot / New Document / Delete buttons.
struct HistorySnapshotsSection: View {
    let doc: Document
    @Bindable var store = SnapshotStore.shared
    @State private var renaming: UUID?
    @State private var renameText = ""

    var body: some View {
        let _ = store.ensureInitialOnce(doc)
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Caption("Snapshots")
                Spacer()
                IconButton(symbol: "doc.badge.plus", help: "Create new document from current state", size: 20) {
                    let s = HistorySnapshot(name: "\(doc.name) state", state: doc.committedState)
                    store.newDocument(from: s, of: doc)
                }
                IconButton(symbol: "camera", help: "Create new snapshot", size: 20) { store.newSnapshot(doc) }
                IconButton(symbol: "trash", help: "Delete snapshot", size: 20) {
                    if let id = store.selected[doc.id] { store.delete(doc, id); store.selected[doc.id] = nil }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            ForEach(store.snapshots(doc)) { s in
                HStack(spacing: 6) {
                    Image(nsImage: Thumbnails.snapshotThumb(s.state, key: s.id))
                        .resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                        .frame(width: 26, height: 20)
                        .background(Color.white.opacity(0.1))
                    if renaming == s.id {
                        TextField("", text: $renameText).textFieldStyle(.plain).font(Theme.font)
                            .onSubmit { store.rename(doc, s.id, to: renameText); renaming = nil }
                    } else {
                        Text(tr(s.name)).font(Theme.font).foregroundStyle(Theme.text).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(store.selected[doc.id] == s.id ? Theme.selection : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { renaming = s.id; renameText = s.name }
                .onTapGesture { store.revert(doc, to: s) }
                .contextMenu {
                    Button("Revert to Snapshot") { store.revert(doc, to: s) }
                    Button("New Document from Snapshot") { store.newDocument(from: s, of: doc) }
                    Button("Rename…") { renaming = s.id; renameText = s.name }
                    Button("Delete") { store.delete(doc, s.id) }
                }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}

extension SnapshotStore {
    /// Creates the initial snapshot without mutating observed state during a view update.
    func ensureInitialOnce(_ d: Document) {
        guard byDoc[d.id] == nil else { return }
        DispatchQueue.main.async { self.ensureInitial(d) }
    }
}

extension Thumbnails {
    private static var snapCache: [String: NSImage] = [:]

    /// Small composite thumbnail of a snapshot state (cached per snapshot).
    static func snapshotThumb(_ st: DocumentState, key id: UUID) -> NSImage {
        let key = id.uuidString
        if let c = snapCache[key] { return c }
        let sp = CanvasSpace(width: st.width, height: st.height)
        let s = min(52 / CGFloat(max(1, st.width)), 40 / CGFloat(max(1, st.height)))
        let img = Compositor.shared.composite(st).cropped(to: sp.ciCanvas).transformed(by: CGAffineTransform(scaleX: s, y: s))
        let r = CGRect(x: 0, y: 0, width: max(1, CGFloat(st.width) * s), height: max(1, CGFloat(st.height) * s)).integral
        let ns: NSImage
        if let cg = RenderEngine.cgImage(img, rect: r) { ns = NSImage(cgImage: cg, size: r.size) } else { ns = NSImage(size: NSSize(width: 1, height: 1)) }
        if snapCache.count > 64 { snapCache.removeAll() }
        snapCache[key] = ns
        return ns
    }
}
