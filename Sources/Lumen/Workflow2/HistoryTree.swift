import AppKit
import SwiftUI
import Observation
import ImageCratCore

/// A redo tail that was discarded by a new edit: kept as a branch of the history instead of being lost.
struct HistoryBranch: Identifiable {
    let id: UUID
    var name: String
    /// History step this branch departs from (on the active line or inside another branch).
    var forkEntryID: UUID
    var forkName: String
    var entries: [HistoryEntry]
    var date: Date

    init(id: UUID = UUID(), name: String, forkEntryID: UUID, forkName: String, entries: [HistoryEntry], date: Date = Date()) {
        self.id = id; self.name = name; self.forkEntryID = forkEntryID; self.forkName = forkName; self.entries = entries; self.date = date
    }
}

/// Branching history: per-document side store fed by `Document.willDiscardRedo`.
/// States share their pixel buffers with the live history, so a branch only costs what differs.
@Observable
final class HistoryTree {
    static let shared = HistoryTree()

    private(set) var byDoc: [UUID: [HistoryBranch]] = [:]
    /// Name of the line currently in the History panel (so switching back and forth keeps branch names).
    private(set) var lineName: [UUID: String] = [:]
    private var counter: [UUID: Int] = [:]
    /// Set while Workflow2 rewrites history itself (collapsing steps); discarded tails are not kept then.
    @ObservationIgnored var suppress = false

    func branches(_ d: Document) -> [HistoryBranch] { byDoc[d.id] ?? [] }
    func currentLineName(_ d: Document) -> String { lineName[d.id] ?? "Main" }

    private func nextName(_ d: Document) -> String {
        let n = (counter[d.id] ?? 0) + 1
        counter[d.id] = n
        return "Branch \(n)"
    }

    // MARK: Hook

    /// `commit` is about to drop `tail` (the steps after the current one).
    func noteDiscard(_ d: Document, _ tail: [HistoryEntry]) {
        guard !suppress, !tail.isEmpty, d.history.indices.contains(d.historyIndex) else { return }
        let fork = d.history[d.historyIndex]
        var list = byDoc[d.id] ?? []
        // The line being edited keeps its name; the steps it abandons become a new named branch.
        list.append(HistoryBranch(name: nextName(d), forkEntryID: fork.id, forkName: fork.name, entries: tail))
        trim(&list, live: d.history[...d.historyIndex])      // the tail is still in `history` at this point
        byDoc[d.id] = list
    }

    /// Index of the oldest branch that no other branch hangs off.
    private func oldestLeaf(_ list: [HistoryBranch]) -> Int {
        list.indices.first { i in
            !list.contains { o in o.id != list[i].id && list[i].entries.contains { $0.id == o.forkEntryID } }
        } ?? 0
    }

    /// `live`: the history steps that stay (their pixels are in memory anyway).
    private func trim(_ list: inout [HistoryBranch], live entries: ArraySlice<HistoryEntry>) {
        let prefs = Workflow2Settings.shared.prefs
        let cap = max(1, prefs.maxBranches)
        while list.count > cap { list.remove(at: oldestLeaf(list)) }
        // memory budget: pixels only the branches keep alive (history steps clone the layers they change)
        let budget = max(16, prefs.branchMemoryMB) * 1_048_576
        var live: [ObjectIdentifier: Int] = [:]
        for h in entries { HistoryTree.collectBuffers(h.state, into: &live) }
        while list.count > 1, HistoryTree.extraBytes(list, live: live) > budget { list.remove(at: oldestLeaf(list)) }
        if list.count == 1, HistoryTree.extraBytes(list, live: live) > budget {
            // a single oversized branch: keep as many of its first steps as fit (at least one)
            var keep = list[0].entries.count
            while keep > 1 {
                var probe = list[0]; probe.entries = Array(probe.entries.prefix(keep))
                if HistoryTree.extraBytes([probe], live: live) <= budget { break }
                keep -= 1
            }
            list[0].entries = Array(list[0].entries.prefix(keep))
        }
    }

    // MARK: Memory

    /// Pixel buffers referenced by a state (identity → bytes).
    static func collectBuffers(_ st: DocumentState, into set: inout [ObjectIdentifier: Int]) {
        func add(_ b: PixelBuffer) { set[ObjectIdentifier(b)] = b.bytesPerRow * b.height }
        func visit(_ layers: [Layer]) {
            for l in layers {
                if let m = l.mask { add(m.buffer) }
                switch l.content {
                case .raster(let r): add(r.buffer)
                case .smartObject(let so):
                    switch so.source { case .image(let b): add(b); case .document(let inner): collectBuffers(inner, into: &set) }
                case .group(let g): visit(g.children)
                default: break
                }
            }
        }
        visit(st.layers)
        if let s = st.selection { add(s) }
        for c in st.alphaChannels { add(c.buffer) }
    }

    static func extraBytes(_ list: [HistoryBranch], live: [ObjectIdentifier: Int]) -> Int {
        var mine: [ObjectIdentifier: Int] = [:]
        for b in list { for e in b.entries { collectBuffers(e.state, into: &mine) } }
        return mine.reduce(0) { $0 + (live[$1.key] == nil ? $1.value : 0) }
    }

    /// Bytes the branches of `d` hold beyond what its history already holds.
    func memory(_ d: Document) -> Int {
        var live: [ObjectIdentifier: Int] = [:]
        for h in d.history { HistoryTree.collectBuffers(h.state, into: &live) }
        return HistoryTree.extraBytes(branches(d), live: live)
    }

    // MARK: Queries

    /// Branches that fork directly from a step of the active history line, keyed by that step.
    func branchesByFork(_ d: Document) -> [UUID: [HistoryBranch]] {
        var out: [UUID: [HistoryBranch]] = [:]
        let ids = Set(d.history.map(\.id))
        let list = branches(d)
        for b in list {
            if ids.contains(b.forkEntryID) { out[b.forkEntryID, default: []].append(b) }
            else if !list.contains(where: { p in p.id != b.id && p.entries.contains { $0.id == b.forkEntryID } }), let first = d.history.first {
                out[first.id, default: []].append(b)     // fork step fell off the history limit: hang it off the oldest step
            }
        }
        return out
    }

    /// Branches nested inside `parent` (their fork step is one of its steps).
    func children(of parent: HistoryBranch, in d: Document) -> [HistoryBranch] {
        let ids = Set(parent.entries.map(\.id))
        return branches(d).filter { $0.id != parent.id && ids.contains($0.forkEntryID) }
    }

    /// The state at the tip of a branch (for Compare / Save as Version / New Document).
    func tipState(_ id: UUID, in d: Document) -> DocumentState? {
        branches(d).first { $0.id == id }?.entries.last?.state
    }

    // MARK: Switching

    /// Makes `branchID` the active line. The steps it replaces are kept as a branch. `step` selects a step inside the branch
    /// (default: its tip). Returns false when the branch is unknown.
    @discardableResult
    func switchTo(_ branchID: UUID, in d: Document, step: Int? = nil) -> Bool {
        var list = byDoc[d.id] ?? []
        guard let target = list.first(where: { $0.id == branchID }) else { return false }
        AppActions.canvas?.commitCurrentTool()

        // chain of branches from the active line down to the target (nested branches)
        var chain = [target]
        var rootIdx = d.history.firstIndex { $0.id == chain[0].forkEntryID }
        var hops = 0
        while rootIdx == nil, hops < 64 {
            guard let parent = list.first(where: { p in p.id != chain[0].id && p.entries.contains { $0.id == chain[0].forkEntryID } }) else { break }
            chain.insert(parent, at: 0)
            rootIdx = d.history.firstIndex { $0.id == parent.forkEntryID }
            hops += 1
        }
        let root = rootIdx ?? 0

        var tail: [HistoryEntry] = []
        for (i, c) in chain.enumerated() {
            if i < chain.count - 1, let k = c.entries.firstIndex(where: { $0.id == chain[i + 1].forkEntryID }) {
                tail += c.entries[...k]
                // what is left of the parent stays a branch hanging off the step where the child forked
                if let li = list.firstIndex(where: { $0.id == c.id }) {
                    let rest = Array(c.entries[(k + 1)...])
                    if rest.isEmpty { list.remove(at: li) } else {
                        list[li].entries = rest
                        list[li].forkEntryID = c.entries[k].id
                        list[li].forkName = c.entries[k].name
                    }
                }
            } else {
                tail += c.entries
            }
        }
        list.removeAll { $0.id == target.id }
        let old = Array(d.history[(root + 1)...])
        if !old.isEmpty {
            list.append(HistoryBranch(name: currentLineName(d), forkEntryID: d.history[root].id, forkName: d.history[root].name, entries: old))
        }
        lineName[d.id] = target.name
        byDoc[d.id] = list

        let tipIndex = root + tail.count
        let select = step.map { tipIndex - (target.entries.count - 1) + max(0, min($0, target.entries.count - 1)) } ?? tipIndex
        d.replaceHistoryTail(after: root, with: tail, select: select)
        trim(&list, live: d.history[...])
        byDoc[d.id] = list
        Compositor.shared.clearCaches()
        d.setNeedsRender()
        return true
    }

    func rename(_ id: UUID, in d: Document, to name: String) {
        guard !name.isEmpty, let i = byDoc[d.id]?.firstIndex(where: { $0.id == id }) else { return }
        byDoc[d.id]![i].name = name
    }

    func renameCurrentLine(_ d: Document, to name: String) { if !name.isEmpty { lineName[d.id] = name } }

    /// Deletes a branch; branches nested in it are re-attached to its fork step.
    func delete(_ id: UUID, in d: Document) {
        guard var list = byDoc[d.id], let b = list.first(where: { $0.id == id }) else { return }
        let ids = Set(b.entries.map(\.id))
        list.removeAll { $0.id == id }
        for i in list.indices where ids.contains(list[i].forkEntryID) {
            // keep the orphan self-contained: prefix the steps that led to its fork
            if let k = b.entries.firstIndex(where: { $0.id == list[i].forkEntryID }) {
                list[i].entries = Array(b.entries[...k]) + list[i].entries
            }
            list[i].forkEntryID = b.forkEntryID
            list[i].forkName = b.forkName
        }
        byDoc[d.id] = list
    }

    @discardableResult
    func openAsDocument(_ id: UUID, in d: Document) -> Document? {
        guard let b = branches(d).first(where: { $0.id == id }), let st = b.entries.last?.state else { return nil }
        let nd = Document(state: st, name: "\((d.name as NSString).deletingPathExtension) – \(b.name)")
        AppModel.shared.add(nd)
        return nd
    }

    func forget(_ docID: UUID) {
        byDoc[docID] = nil; lineName[docID] = nil; counter[docID] = nil
    }

    var trackedDocuments: [UUID] { Array(byDoc.keys) }
}

// MARK: - Panel

/// History Tree panel: the active line as a trunk, kept branches hanging off their fork steps.
struct HistoryTreePanel: View {
    @Bindable var app = AppModel.shared
    @Bindable var tree = HistoryTree.shared
    @State private var collapsed: Set<UUID> = []
    @State private var renaming: UUID?
    @State private var renameText = ""
    /// Snapshot tests pass the document explicitly.
    var docOverride: Document? = nil

    var body: some View {
        if let d = docOverride ?? app.activeDocument {
            VStack(spacing: 0) {
                header(d)
                Rectangle().fill(Theme.border).frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let forks = tree.branchesByFork(d)
                        ForEach(Array(d.history.enumerated()), id: \.element.id) { i, h in
                            trunkRow(d, i, h, hasFork: forks[h.id] != nil)
                            ForEach(forks[h.id] ?? []) { b in branchBlock(d, b, depth: 1) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .font(Theme.font)
        } else {
            Text("No document").foregroundStyle(Theme.textFaint).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func header(_ d: Document) -> some View {
        let n = tree.branches(d).count
        let mem = n > 0 ? tree.memory(d) : 0
        return HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(Theme.accent)
            if renaming == d.id {
                TextField("", text: $renameText).textFieldStyle(.plain).font(Theme.fontBold).frame(width: 90)
                    .onSubmit { tree.renameCurrentLine(d, to: renameText); renaming = nil }
            } else {
                Text(tree.currentLineName(d)).font(Theme.fontBold).lineLimit(1)
                    .onTapGesture(count: 2) { renaming = d.id; renameText = tree.currentLineName(d) }
                    .help("The line of history you are on. Double-click to rename.")
            }
            Text(verbatim: "\(d.history.count) steps · \(n) branch\(n == 1 ? "" : "es")" + (mem > 1_000_000 ? " · \(Workflow2Util.byteString(mem))" : ""))
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).lineLimit(1)
                .help("Memory held by branches beyond the history itself")
            Spacer()
            IconButton(symbol: "bookmark", help: "Save the current state as a named version", size: 20) { DialogRegistry.show("w2.saveVersion") }
        }
        .padding(.horizontal, 8).frame(height: 26)
    }

    func trunkRow(_ d: Document, _ i: Int, _ h: HistoryEntry, hasFork: Bool) -> some View {
        let current = i == d.historyIndex
        return HStack(spacing: 6) {
            ZStack {
                Rectangle().fill(Theme.accent.opacity(0.7)).frame(width: 2)
                Circle().fill(current ? Color.white : (i > d.historyIndex ? Theme.textFaint : Theme.accent))
                    .frame(width: hasFork ? 9 : 7, height: hasFork ? 9 : 7)
                    .overlay(Circle().stroke(Theme.accent, lineWidth: current ? 2 : 0))
            }
            .frame(width: 14, height: 22)
            Text(h.name).foregroundStyle(i > d.historyIndex ? Theme.textFaint : Theme.text).lineLimit(1)
            Spacer()
            if CommandLog.shared.stepsByEntry[h.id] != nil {
                Image(systemName: "record.circle").font(.system(size: 8)).foregroundStyle(Theme.textFaint).help("Recordable as an action step")
            }
        }
        .padding(.leading, 8).padding(.trailing, 8)
        .frame(height: 22)
        .background(current ? Theme.selection : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { d.jumpToHistory(i) }
        .contextMenu {
            Button("Compare with This State") { CompareController.shared.start(d, source: .historyEntry(h.id)) }
            Button("Save as Version…") { d.jumpToHistory(i); DialogRegistry.show("w2.saveVersion") }
            Button("Create Action from History Steps…") { DialogRegistry.show("w2.historyAction") }.disabled(d.history.count < 2)
        }
    }

    func branchBlock(_ d: Document, _ b: HistoryBranch, depth: Int) -> AnyView {
        let color = HistoryTreePanel.color(for: b.id)
        let open = !collapsed.contains(b.id)
        let kids = tree.children(of: b, in: d)
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Spacer().frame(width: CGFloat(8 + depth * 14 - 6))
                Image(systemName: "arrow.turn.down.right").font(.system(size: 8, weight: .bold)).foregroundStyle(color)
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.textDim)
                    .frame(width: 10, height: 18).contentShape(Rectangle())
                    .onTapGesture { if open { collapsed.insert(b.id) } else { collapsed.remove(b.id) } }
                if renaming == b.id {
                    TextField("", text: $renameText).textFieldStyle(.plain)
                        .onSubmit { tree.rename(b.id, in: d, to: renameText); renaming = nil }
                } else {
                    Text(b.name).font(Theme.fontBold).foregroundStyle(color).lineLimit(1)
                }
                Text("\(b.entries.count) step\(b.entries.count == 1 ? "" : "s") · \(Workflow2Util.relativeTime(b.date))")
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).lineLimit(1)
                Spacer()
                Button("Switch") { tree.switchTo(b.id, in: d) }.buttonStyle(.plain).font(Theme.fontSmall).foregroundStyle(Theme.accent)
                    .help("Make this branch the active history; the current steps are kept as a branch")
            }
            .padding(.trailing, 8).frame(height: 22)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Switch to Branch") { tree.switchTo(b.id, in: d) }
                Button("Compare with Branch") { CompareController.shared.start(d, source: .branch(b.id)) }
                Button("New Document from Branch") { tree.openAsDocument(b.id, in: d) }
                Button("Save Branch as Version") { if let st = b.entries.last?.state { VersionStore.shared.save(d, name: b.name, note: "From history branch", state: st) } }
                Divider()
                Button("Rename…") { renaming = b.id; renameText = b.name }
                Button("Delete Branch") { tree.delete(b.id, in: d) }
            }
            if open {
                ForEach(Array(b.entries.enumerated()), id: \.element.id) { i, h in
                    HStack(spacing: 6) {
                        Spacer().frame(width: CGFloat(8 + depth * 14))
                        ZStack {
                            Rectangle().fill(color.opacity(0.6)).frame(width: 2)
                            Circle().fill(color).frame(width: 6, height: 6)
                        }
                        .frame(width: 14, height: 20)
                        Text(h.name).foregroundStyle(Theme.textDim).lineLimit(1)
                        Spacer()
                    }
                    .padding(.trailing, 8).frame(height: 20)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { tree.switchTo(b.id, in: d, step: i) }
                    .help("Double-click to switch to this branch at “\(h.name)”")
                    ForEach(kids.filter { $0.forkEntryID == h.id }) { k in branchBlock(d, k, depth: depth + 1) }
                }
            }
        })
    }

    static let palette: [Color] = [Color(red: 0.95, green: 0.6, blue: 0.25), Color(red: 0.45, green: 0.8, blue: 0.5), Color(red: 0.8, green: 0.5, blue: 0.9),
                                   Color(red: 0.95, green: 0.45, blue: 0.5), Color(red: 0.4, green: 0.8, blue: 0.85), Color(red: 0.9, green: 0.8, blue: 0.35)]
    static func color(for id: UUID) -> Color {
        let h = id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return palette[h % palette.count]
    }
}
