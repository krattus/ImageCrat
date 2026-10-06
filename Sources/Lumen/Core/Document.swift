import Foundation
import CoreGraphics
import CoreImage
import Observation
import ImageCratCore

/// `quickMask`: the selection itself, painted as a gray channel while Quick Mask mode is on (never `Document.editTarget`).
enum EditTarget: Equatable {
    case content, mask, quickMask
    /// Gray channel targets: colours are painted as their luminance.
    var isMask: Bool { self != .content }
}

enum ViewChannel: Equatable, Hashable {
    case composite, red, green, blue
    case alpha(UUID)
    /// CMYK ink (0 C, 1 M, 2 Y, 3 K) or Lab component (0 L, 1 a, 2 b) views.
    case ink(Int)
    case lab(Int)
}

struct HistoryEntry: Identifiable {
    let id = UUID()
    let name: String
    var state: DocumentState   // (var: view-only changes such as group disclosure apply to every step, see applyViewOnlyChange)
    /// Layer selection that belongs to this state (restored with it by undo / redo / the History panel).
    var activeLayerID: UUID? = nil
    var selectedLayerIDs: Set<UUID> = []
}

@Observable
final class Document: Identifiable {
    let id = UUID()
    var name: String
    var fileURL: URL?

    var state: DocumentState {
        didSet {
            guard !viewOnlyChange else { return }
            setNeedsRender()
            // feature modules keep derived content in step (type on a path follows its linked source path);
            // changes they make are not reported again
            if !reportingStateChange, let h = Document.stateDidChange {
                reportingStateChange = true
                h(self)
                reportingStateChange = false
            }
        }
    }
    /// Called after `state` changed (not for view-only changes), before the change is committed to history.
    static var stateDidChange: ((Document) -> Void)?
    @ObservationIgnored private var reportingStateChange = false

    private(set) var history: [HistoryEntry] = []
    private(set) var historyIndex: Int = 0
    private var savedEntryID: UUID?
    static var maxHistory = 60

    // (a change is remembered as the selection of the current history state, see `noteLayerSelection`)
    var activeLayerID: UUID? { didSet { noteLayerSelection() } }
    var selectedLayerIDs: Set<UUID> = [] { didSet { noteLayerSelection() } }
    var editTarget: EditTarget = .content
    var activePathID: UUID?
    var activeCompID: UUID?
    var activeChannelID: UUID?
    /// Bumped whenever layer content changes (for thumbnails / panels).
    var revision: Int = 0

    // View state
    var zoom: Double = 1
    var viewOffset: CGPoint = .zero
    var viewRotation: Double = 0      // radians (Rotate View tool)
    var needsFitOnScreen = true
    var showGrid = false
    var showGuides = true
    var showRulers = true
    var snapEnabled = true
    var showPixelGrid = true
    var showSelectionEdges = true
    var viewChannel: ViewChannel = .composite
    var proofColors = false
    var gamutWarning = false
    var quickMask = false
    var gridSpacing: Double = 50

    // Smart object editing
    @ObservationIgnored weak var smartParent: Document?
    @ObservationIgnored var smartParentLayerID: UUID?

    // Live previews (not undoable, not observed)
    @ObservationIgnored var contentOverrides: [UUID: (CIImage) -> CIImage] = [:]
    /// Live previews of a layer mask being edited: maps the placed mask (gray, before its feather / density) to the shown one.
    @ObservationIgnored var maskOverrides: [UUID: (CIImage) -> CIImage] = [:]
    @ObservationIgnored var hiddenLayers: Set<UUID> = []
    /// Display-only post-process of the composite (Select and Mask view modes, soft proofing, gamut warning).
    @ObservationIgnored var displayOverride: ((CIImage) -> CIImage)?
    @ObservationIgnored var renderCallback: (() -> Void)?
    @ObservationIgnored var overlayCallback: (() -> Void)?

    init(state: DocumentState, name: String) {
        self.state = state
        self.name = name
        history = [HistoryEntry(name: "Open", state: state)]
        historyIndex = 0
        savedEntryID = history[0].id
        activeLayerID = state.layers.last?.id
        if let a = activeLayerID { selectedLayerIDs = [a] }
        noteLayerSelection()   // (observers don't run inside init)
    }

    static func newBlank(width: Int, height: Int, resolution: Double = 72, background: RGBA?, name: String = "Untitled") -> Document {
        var st = DocumentState(width: width, height: height, resolution: resolution)
        let layer: Layer
        if let bg = background {
            let buf = PixelBuffer(width: width, height: height)
            buf.context.setFillColor(bg.cgColor)
            buf.context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            buf.markDirty()
            var l = Layer.raster(name: "Background", buffer: buf)
            l.locks.position = false
            layer = l
        } else {
            layer = Layer.raster(name: "Layer 1", width: width, height: height)
        }
        st.layers = [layer]
        let d = Document(state: st, name: name)
        d.history = [HistoryEntry(name: "New", state: st)]
        d.savedEntryID = d.history[0].id
        d.noteLayerSelection()   // (the entry was replaced after init recorded the selection)
        return d
    }

    // MARK: Rendering hooks

    /// Bumped on every visual change (drives the canvas composite cache).
    @ObservationIgnored private(set) var renderVersion = 0

    func setNeedsRender() {
        renderVersion &+= 1
        renderCallback?()
    }

    func setNeedsOverlay() {
        overlayCallback?()
    }

    // MARK: History

    var isDirty: Bool { history.indices.contains(historyIndex) ? history[historyIndex].id != savedEntryID : true }

    func markSaved() {
        if history.indices.contains(historyIndex) { savedEntryID = history[historyIndex].id }
    }

    /// Called right before a history step is recorded (Timeline: stores layer edits in the selected frame).
    static var willCommit: ((Document) -> Void)?
    /// Called after the document jumped to another history state (undo, redo, History panel).
    static var didRestore: ((Document) -> Void)?
    /// Workflow2 (History Tree): called with the redo steps `commit` is about to discard.
    static var willDiscardRedo: ((Document, [HistoryEntry]) -> Void)?
    /// Workflow2 (timelapse, history → action): called after a history step was recorded.
    static var didCommit: ((Document) -> Void)?

    /// Record the current state as a new history step.
    func commit(_ actionName: String) {
        Document.willCommit?(self)
        if historyIndex < history.count - 1 {
            Document.willDiscardRedo?(self, Array(history[(historyIndex + 1)...]))
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(HistoryEntry(name: actionName, state: state, activeLayerID: activeLayerID, selectedLayerIDs: selectedLayerIDs))
        if history.count > Document.maxHistory {
            history.removeFirst(history.count - Document.maxHistory)
        }
        historyIndex = history.count - 1
        revision += 1
        validateActiveLayer()
        Document.didCommit?(self)
    }

    /// Workflow2 (History Tree): replaces every step after `index` with `entries` (branch switching) and makes `select` current.
    func replaceHistoryTail(after index: Int, with entries: [HistoryEntry], select: Int) {
        guard history.indices.contains(index) else { return }
        history.removeSubrange((index + 1)...)
        history.append(contentsOf: entries)
        jumpToHistory(min(max(0, select), history.count - 1))
    }

    /// Replaces the newest history step with the current state instead of adding one (coalesces rapid repeats of the
    /// same action, e.g. flipping through generative variations). Falls back to `commit` when there is nothing to replace.
    func commitReplacingLast(_ actionName: String) {
        guard historyIndex > 0, historyIndex == history.count - 1 else { commit(actionName); return }
        Document.willCommit?(self)
        history[historyIndex] = HistoryEntry(name: actionName, state: state, activeLayerID: activeLayerID, selectedLayerIDs: selectedLayerIDs)
        revision += 1
        validateActiveLayer()
        Document.didCommit?(self)
    }

    /// Folds the last `n` history steps into one (a single gesture that is built from several recorded commands,
    /// e.g. Straighten = rotate + crop, must be one undo step).
    func coalesceLastSteps(_ n: Int, name: String) {
        guard n > 1, historyIndex == history.count - 1, history.count > n else { return }
        let last = history[historyIndex]
        history.removeLast(n)
        history.append(HistoryEntry(name: name, state: last.state, activeLayerID: last.activeLayerID, selectedLayerIDs: last.selectedLayerIDs))
        historyIndex = history.count - 1
    }

    /// Id of the current history step (MCP tool calls note it before they run, see `foldSteps(after:name:)`).
    var currentHistoryEntryID: UUID? { history.indices.contains(historyIndex) ? history[historyIndex].id : nil }

    /// Folds every step recorded after the step `base` into one step called `name` (an MCP tool call is one undo
    /// step, however many commands it ran). Steps that were undone during the call are dropped. Returns how many steps
    /// were folded (0 when nothing was recorded after `base`).
    @discardableResult
    func foldSteps(after base: UUID, name: String) -> Int {
        guard let i = history.firstIndex(where: { $0.id == base }), historyIndex > i else { return 0 }
        let n = historyIndex - i
        let last = history[historyIndex]
        let wasSaved = savedEntryID == last.id
        history.removeSubrange((i + 1)...)
        let folded = HistoryEntry(name: name, state: last.state, activeLayerID: last.activeLayerID, selectedLayerIDs: last.selectedLayerIDs)
        history.append(folded)
        historyIndex = history.count - 1
        if wasSaved { savedEntryID = folded.id }
        return n
    }

    var canUndo: Bool { historyIndex > 0 }
    var canRedo: Bool { historyIndex < history.count - 1 }

    func undo() {
        guard canUndo else { return }
        historyIndex -= 1
        restore(history[historyIndex])
    }

    func redo() {
        guard canRedo else { return }
        historyIndex += 1
        restore(history[historyIndex])
    }

    func jumpToHistory(_ index: Int) {
        guard history.indices.contains(index) else { return }
        historyIndex = index
        restore(history[index])
    }

    /// Discard uncommitted changes.
    func revertUncommitted() {
        guard history.indices.contains(historyIndex) else { return }
        state = history[historyIndex].state
        revision += 1
        validateActiveLayer()
    }

    /// Current committed state (e.g. for sampling originals during previews).
    var committedState: DocumentState { history[historyIndex].state }

    @ObservationIgnored private var viewOnlyChange = false

    /// Applies a view-only layer change (a group's disclosure state in the Layers panel) to the current state and to
    /// every history step: it is not a step of its own, Undo / Redo / Cancel (`revertUncommitted`) don't flip it back,
    /// and nothing re-renders. It is saved with the document like any other layer property.
    func applyViewOnlyChange(_ body: (inout DocumentState) -> Void) {
        var st = state
        body(&st)
        viewOnlyChange = true
        state = st
        viewOnlyChange = false
        for i in history.indices { body(&history[i].state) }
    }

    private func restore(_ e: HistoryEntry) {
        contentOverrides.removeAll()
        maskOverrides.removeAll()
        hiddenLayers.removeAll()
        state = e.state
        // The layer selection of that state comes back with it: otherwise undoing a step that added the active layer
        // left `validateActiveLayer` to pick the topmost layer, an unrelated one.
        if let a = e.activeLayerID, e.state.layer(a) != nil {
            activeLayerID = a
            selectedLayerIDs = e.selectedLayerIDs.contains(a) ? e.selectedLayerIDs : [a]
        }
        revision += 1
        validateActiveLayer()
        Document.didRestore?(self)
    }

    /// Records the current layer selection as the one of the current history state (a selection change is not a
    /// history step of its own, but undoing back to this state should return to it). A layer the recorded state doesn't
    /// have (one a command is adding right now) is not recorded: the step that adds it records it.
    func noteLayerSelection() {
        guard history.indices.contains(historyIndex), let a = activeLayerID, history[historyIndex].state.layer(a) != nil,
              history[historyIndex].activeLayerID != a || history[historyIndex].selectedLayerIDs != selectedLayerIDs else { return }
        history[historyIndex].activeLayerID = a
        history[historyIndex].selectedLayerIDs = selectedLayerIDs
    }

    func validateActiveLayer() {
        if let a = activeLayerID, state.layer(a) != nil {
            selectedLayerIDs = selectedLayerIDs.filter { state.layer($0) != nil }
            if selectedLayerIDs.isEmpty { selectedLayerIDs = [a] }
            if editTarget == .mask, state.layer(a)?.mask == nil { editTarget = .content }
            return
        }
        activeLayerID = state.layers.last?.id
        selectedLayerIDs = activeLayerID.map { [$0] } ?? []
        editTarget = .content
    }

    // MARK: Layers

    var activeLayer: Layer? { state.layer(activeLayerID) }

    func selectLayer(_ id: UUID, extend: Bool = false, range: Bool = false) {
        if range, let a = activeLayerID {
            let flat = state.layers.flattenedForDisplay(includeCollapsed: false).map { $0.0.id }
            if let i = flat.firstIndex(of: a), let j = flat.firstIndex(of: id) {
                selectedLayerIDs = Set(flat[min(i, j)...max(i, j)])
            }
            activeLayerID = id
        } else if extend {
            if selectedLayerIDs.contains(id) && selectedLayerIDs.count > 1 {
                selectedLayerIDs.remove(id)
                if activeLayerID == id { activeLayerID = selectedLayerIDs.first }
            } else {
                selectedLayerIDs.insert(id)
                activeLayerID = id
            }
        } else {
            selectedLayerIDs = [id]
            activeLayerID = id
        }
        if editTarget == .mask, state.layer(activeLayerID)?.mask == nil { editTarget = .content }
        setNeedsOverlay()
    }

    /// Selected layer IDs in bottom-to-top order.
    var orderedSelection: [UUID] {
        state.allLayers.map(\.id).filter { selectedLayerIDs.contains($0) }
    }

    /// `ids` without layers that sit inside another listed group: a group moves / transforms its children itself,
    /// so a child that is selected (or linked) together with its group must not be processed a second time.
    func withoutDescendants(_ ids: [UUID]) -> [UUID] {
        let set = Set(ids)
        guard set.count > 1 else { return ids }
        var nested = Set<UUID>()
        for id in ids {
            guard let l = state.layer(id), l.isGroup else { continue }
            for c in l.allIDs.dropFirst() where set.contains(c) { nested.insert(c) }
        }
        return nested.isEmpty ? ids : ids.filter { !nested.contains($0) }
    }

    /// `ids` plus every layer linked to one of them (Photoshop linked layers move/transform together).
    func withLinked(_ ids: [UUID]) -> [UUID] {
        let all = state.allLayers
        let links = Set(ids.compactMap { id in all.first { $0.id == id }?.linkID })
        if links.isEmpty { return ids }
        let set = Set(ids)
        return all.filter { set.contains($0.id) || ($0.linkID.map(links.contains) ?? false) }.map(\.id)
    }

    func updateLayer(_ id: UUID, _ body: (inout Layer) -> Void) {
        state.updateLayer(id, body)
    }

    func nextLayerName(_ base: String = "Layer") -> String {
        let names = Set(state.allLayers.map(\.name))
        var i = 1
        while names.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// Adds a layer above the active one and makes it active.
    func addLayer(_ layer: Layer, commitName: String? = nil) {
        if let a = activeLayerID, let al = state.layer(a) {
            state.insertLayer(layer, above: a, inside: al.isGroup && al.isExpanded)
        } else {
            state.layers.append(layer)
        }
        activeLayerID = layer.id
        selectedLayerIDs = [layer.id]
        editTarget = .content
        if let n = commitName { commit(n) }
    }

    // MARK: Pixel editing

    /// Prepares the active raster (or mask) buffer for mutation: clones it into the state (uncommitted)
    /// and optionally grows it to cover the canvas. Returns the working buffer and its doc origin.
    func beginPixelEdit(layerID: UUID, target: EditTarget, coverCanvas: Bool = true) -> (PixelBuffer, IPoint)? {
        if target == .quickMask {
            // the selection is the channel being painted; without one everything is selected (an all-white mask)
            let buf = state.selection?.copy() ?? PixelBuffer(width: state.width, height: state.height, gray: 255)
            state.selection = buf
            return (buf, .zero)
        }
        guard let layer = state.layer(layerID) else { return nil }
        if target == .mask {
            guard var m = layer.mask else { return nil }
            var buf = m.buffer.copy()
            var origin = m.origin
            if coverCanvas {
                let need = m.frame.union(state.canvasRect)
                if need != m.frame {
                    let nb = PixelBuffer(width: need.width, height: need.height, gray: m.outsideValue)
                    nb.copyPixels(from: buf, at: IPoint(x: m.origin.x - need.x, y: m.origin.y - need.y))
                    buf = nb
                    origin = need.origin
                }
            }
            m.buffer = buf
            m.origin = origin
            state.updateLayer(layerID) { $0.mask = m }
            return (buf, origin)
        }
        guard var r = layer.raster else { return nil }
        var buf = r.buffer.copy()
        var origin = r.origin
        if coverCanvas {
            let need = r.frame.union(state.canvasRect)
            if need != r.frame {
                let nb = PixelBuffer(width: need.width, height: need.height)
                nb.copyPixels(from: buf, at: IPoint(x: r.origin.x - need.x, y: r.origin.y - need.y))
                buf = nb
                origin = need.origin
            }
        }
        r.buffer = buf
        r.origin = origin
        state.updateLayer(layerID) { $0.raster = r }
        return (buf, origin)
    }

    // MARK: Selection

    /// The selection that limits pixel edits. None while Quick Mask is on: the selection is then what gets painted.
    var editSelection: PixelBuffer? { quickMask ? nil : state.selection }

    func setSelection(_ mask: PixelBuffer?, commitName: String? = nil) {
        if let m = mask, m.opaqueBounds() == nil {
            state.selection = nil
        } else {
            state.selection = mask
        }
        if let n = commitName { commit(n) }
        setNeedsOverlay()
    }
}
