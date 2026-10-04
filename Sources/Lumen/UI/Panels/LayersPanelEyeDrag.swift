import AppKit
import SwiftUI
import ImageCratCore

/// Layers panel eyes, Photoshop style:
/// - press an eye and drag up / down the eye column: every row the pointer passes gets the new state of the first one
///   (all shown or all hidden; passing a row again leaves it as it is), across groups, nested layers and artboards. An
///   effect row's eye does the same for effect rows. Live while dragging, one history step at the end; the list scrolls
///   when the pointer reaches its top or bottom edge;
/// - ⌥-click: only this layer shown; ⌥-click it again brings back the visibility from before;
/// - right-click: Show / Hide This Layer, Show / Hide All Other Layers, Show All Layers.
///
/// One `EyeColumnView` (AppKit) lies over the eye column of the whole list and takes the mouse there: the rows report
/// their frames (`eyeRow`) in the list's coordinate space and `EyeDragCoordinator` maps the pointer to them. The
/// eye buttons below stay for accessibility (a press toggles one layer). The column takes the mouse before the row
/// does, so pressing an eye doesn't select the layer or start a reorder drag (dragging the row elsewhere still does).

/// What an eye switches.
enum EyeTarget: Hashable {
    case layer(UUID)                  // layer, group or artboard row
    case effects(UUID)                // the "Effects" row: the layer's master switch
    case effect(UUID, EffectSlot)     // one effect of the style

    var isLayer: Bool { if case .layer = self { return true }; return false }
    var layerID: UUID {
        switch self {
        case .layer(let id), .effects(let id), .effect(let id, _): return id
        }
    }
}

struct EyeRowFrame: Equatable {
    let target: EyeTarget
    let frame: CGRect
}

private struct EyeDragKey: EnvironmentKey {
    static let defaultValue: EyeDragCoordinator? = nil
}

extension EnvironmentValues {
    /// The eye-drag coordinator of the Layers panel list the view is in.
    var eyeDrag: EyeDragCoordinator? {
        get { self[EyeDragKey.self] }
        set { self[EyeDragKey.self] = newValue }
    }
}

/// Reports a row's frame (in the list's coordinate space) to the list's coordinator while the row is loaded. (From the
/// geometry reader's layout pass itself: the coordinator is not observed, so nothing re-renders; deferred actions such as
/// onGeometryChange / onPreferenceChange don't run in headless self tests.)
private struct EyeRowModifier: ViewModifier {
    let target: EyeTarget
    @Environment(\.eyeDrag) private var drag

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                let _ = drag?.setFrame(target, g.frame(in: .named(EyeDragCoordinator.space)))
                Color.clear
            })
            .onDisappear { drag?.removeFrame(target) }
    }
}

extension View {
    /// A row of the Layers panel with an eye: reports its frame to the list's eye column.
    func eyeRow(_ t: EyeTarget) -> some View { modifier(EyeRowModifier(target: t)) }

    /// The Layers panel's row list (`rows`: the layers it lists): its coordinate space, the coordinator for its rows and
    /// the eye column over it.
    func eyeDragColumn(_ c: EyeDragCoordinator, doc: Document, rows: [UUID]) -> some View {
        environment(\.eyeDrag, c)
            .coordinateSpace(name: EyeDragCoordinator.space)
            .overlay(alignment: .topLeading) {
                EyeColumn(drag: c, doc: doc, rows: rows).frame(width: EyeDragCoordinator.columnWidth).frame(maxHeight: .infinity)
            }
    }
}

// MARK: - Visibility commands

enum EyeVisibility {
    /// Whether the eye of `t` is open (nil: no such row any more).
    static func isOn(_ st: DocumentState, _ t: EyeTarget) -> Bool? {
        guard let l = st.layer(t.layerID) else { return nil }
        switch t {
        case .layer: return l.isVisible
        case .effects: return l.effects.hasStyle ? l.effects.enabled : nil
        case .effect(_, let s): return l.effects.item(s)?.isListed == true ? l.effects.isShown(s) : nil
        }
    }

    /// Sets the eye of `t`; false when it already was (nothing changed). Showing an effect of a layer whose effects are
    /// switched off switches them on (as `LayerFX.setShown`).
    @discardableResult
    static func set(_ st: inout DocumentState, _ t: EyeTarget, _ on: Bool) -> Bool {
        guard let l = st.layer(t.layerID) else { return false }
        switch t {
        case .layer(let id):
            guard l.isVisible != on else { return false }
            st.updateLayer(id) { $0.isVisible = on }
        case .effects(let id):
            guard l.effects.hasStyle, l.effects.enabled != on else { return false }
            st.updateLayer(id) { $0.effects.enabled = on }
        case .effect(let id, let s):
            guard l.effects.item(s)?.isListed == true, l.effects.isShown(s) != on || (on && !l.effects.enabled) else { return false }
            st.updateLayer(id) { x in
                x.effects.setShown(s, on)
                if on { x.effects.enabled = true }
            }
        }
        return true
    }

    /// History name of a change of the eyes `changed` to `on`.
    static func stepName(_ st: DocumentState, _ changed: [EyeTarget], _ on: Bool) -> String {
        let verb = on ? "Show" : "Hide"
        guard changed.count == 1, let t = changed.first else {
            return changed.first?.isLayer == false ? "\(verb) Effects" : "\(verb) Layers"
        }
        switch t {
        case .layer(let id): return st.layer(id)?.isArtboard == true ? "\(verb) Artboard" : "\(verb) Layer"
        case .effects: return "\(verb) Layer Effects"
        case .effect(_, let s): return "\(verb) \(s.kind.displayName)"
        }
    }

    /// Puts `st` in place as one change (one re-render), refreshing artboard caches when an artboard's eye changed.
    static func apply(_ d: Document, _ st: DocumentState, touched ids: [UUID]) {
        let artboard = ids.contains { d.state.layer($0)?.isArtboard == true }
        d.state = st
        if artboard { Compositor.shared.clearCaches() }
    }

    /// A plain click on one eye (also the eye buttons' action, e.g. through accessibility): toggles it, one step.
    /// ⌥ on a layer's eye: `soloOrRestore`.
    static func press(_ d: Document, _ t: EyeTarget, option: Bool = NSEvent.modifierFlags.contains(.option)) {
        if option, case .layer(let id) = t { soloOrRestore(d, id); return }
        guard let on = isOn(d.state, t) else { return }
        var st = d.state
        guard set(&st, t, !on) else { return }
        apply(d, st, touched: [t.layerID])
        d.commit(stepName(st, [t], !on))
    }

    // MARK: Show only this layer (⌥-click) and back

    /// What ⌥-click on `layer` remembers to undo it with a second ⌥-click (Photoshop): the visibility before, and the
    /// one it set (a change in between makes the memory stale).
    struct SoloMemory {
        let docID: UUID
        let layer: UUID
        let before: [UUID: Bool]
        let after: [UUID: Bool]
    }
    static var solo: SoloMemory?

    static func visibility(_ st: DocumentState) -> [UUID: Bool] {
        var out: [UUID: Bool] = [:]
        for l in st.allLayers { out[l.id] = l.isVisible }
        return out
    }

    /// Layers other than `id`, its own contents (a group's layers) and the groups around it.
    static func otherLayers(_ d: Document, _ id: UUID) -> [Layer] {
        guard let l = d.state.layer(id) else { return [] }
        let keep = Set(l.allIDs + LayerGroups.ancestors(d, id))
        return d.state.allLayers.filter { !keep.contains($0.id) }
    }

    /// ⌥-click on an eye: shows this layer (and the groups around it) and hides every other layer; ⌥-click on the same eye
    /// again, with nothing changed in between, restores the visibility from before. With every other layer hidden already
    /// (and nothing to restore) it shows them all. One history step either way.
    static func soloOrRestore(_ d: Document, _ id: UUID) {
        guard d.state.layer(id) != nil else { return }
        let now = visibility(d.state)
        var st = d.state
        if let m = solo, m.docID == d.id, m.layer == id, m.after == now {
            for (k, v) in m.before { set(&st, .layer(k), v) }
            solo = nil
        } else {
            let rest = otherLayers(d, id)
            let ancestors = LayerGroups.ancestors(d, id)
            let isSolo = rest.allSatisfy { !$0.isVisible } && (ancestors + [id]).allSatisfy { now[$0] == true }
            if isSolo {
                for o in rest { set(&st, .layer(o.id), true) }
                solo = nil
            } else {
                for o in rest { set(&st, .layer(o.id), false) }
                for a in ancestors + [id] { set(&st, .layer(a), true) }
                solo = SoloMemory(docID: d.id, layer: id, before: now, after: visibility(st))
            }
        }
        guard visibility(st) != now else { return }
        apply(d, st, touched: d.state.allLayers.map(\.id))
        d.commit("Show/Hide Layers")
    }

    // MARK: Right-click menu

    struct MenuItem {
        let title: String
        let enabled: Bool
        let action: () -> Void
    }

    /// The eye's menu for layer `id`: Show / Hide This Layer, Show / Hide All Other Layers, Show All Layers.
    static func menuItems(_ d: Document, _ id: UUID) -> [MenuItem] {
        guard let l = d.state.layer(id) else { return [] }
        let noun = l.isArtboard ? "Artboard" : "Layer"
        let rest = otherLayers(d, id)
        let anyOtherShown = rest.contains { $0.isVisible }
        let anyHidden = d.state.allLayers.contains { !$0.isVisible }
        return [
            MenuItem(title: (l.isVisible ? "Hide This " : "Show This ") + noun, enabled: true) { press(d, .layer(id), option: false) },
            // (hiding leaves the groups around the layer alone; showing shows them too)
            MenuItem(title: anyOtherShown ? "Hide All Other Layers" : "Show All Other Layers", enabled: !rest.isEmpty) {
                let ids = otherLayers(d, id).map(\.id) + (anyOtherShown ? [] : LayerGroups.ancestors(d, id))
                setLayers(d, ids, !anyOtherShown, name: anyOtherShown ? "Hide All Other Layers" : "Show All Other Layers")
            },
            MenuItem(title: "Show All Layers", enabled: anyHidden) {
                setLayers(d, d.state.allLayers.map(\.id), true, name: "Show All Layers")
            },
        ]
    }

    static func setLayers(_ d: Document, _ ids: [UUID], _ on: Bool, name: String) {
        var st = d.state
        var changed = false
        for id in ids where set(&st, .layer(id), on) { changed = true }
        guard changed else { return }
        apply(d, st, touched: ids)
        d.commit(name)
    }

    final class MenuHandler: NSObject {
        let f: () -> Void
        init(_ f: @escaping () -> Void) { self.f = f }
        @objc func run() { f() }
    }

    static func nsMenu(_ d: Document, _ id: UUID) -> NSMenu {
        let m = NSMenu(title: "Visibility")
        m.autoenablesItems = false
        for it in menuItems(d, id) {
            let h = MenuHandler(it.action)
            let mi = NSMenuItem(title: it.title, action: #selector(MenuHandler.run), keyEquivalent: "")
            mi.target = h
            mi.representedObject = h
            mi.isEnabled = it.enabled
            m.addItem(mi)
        }
        return m
    }
}

// MARK: - Drag coordinator

/// Maps the pointer in the list (its own coordinate space, y down from the top of the first row) to rows and runs a
/// drag across eyes. Not observed: frames change as rows load and scroll in, and that must not re-render the panel.
final class EyeDragCoordinator {
    static let space = "layersPanel.eyeList"
    /// The eye column: the eye (22 pt) of every row kind starts at the list's left edge.
    static let columnWidth: CGFloat = 24

    weak var doc: Document?
    /// The layers the list shows (nil: every row that reports). A row that went away (deleted, in a group just
    /// collapsed, filtered out) may report its frame once more on its way out.
    var listed: Set<UUID>? { didSet { if listed != oldValue { sorted = nil } } }
    /// Rows with an eye that are loaded in the list, with the order they last reported in.
    private var frameOf: [EyeTarget: (rect: CGRect, seq: Int)] = [:]
    private var seq = 0
    private var sorted: [EyeRowFrame]?
    /// Rows with an eye that are loaded in the list, top to bottom. Only rows of listed layers (and effect lists that are
    /// open); where two overlap, the one that reported last wins (the rows that took a removed row's place have).
    var frames: [EyeRowFrame] {
        if let s = sorted { return s }
        let fxClosed = LayersPanelUI.shared.fxCollapsed
        var kept: [EyeRowFrame] = []
        for (t, f) in frameOf.sorted(by: { $0.value.seq > $1.value.seq }) {
            if let l = listed, !l.contains(t.layerID) { continue }
            if !t.isLayer && fxClosed.contains(t.layerID) { continue }
            let r = f.rect
            if !kept.contains(where: { min($0.frame.maxY, r.maxY) - max($0.frame.minY, r.minY) > 0.5 }) { kept.append(EyeRowFrame(target: t, frame: r)) }
        }
        let s = kept.sorted { $0.frame.minY < $1.frame.minY }
        sorted = s
        return s
    }

    struct Session {
        weak var doc: Document?
        let layers: Bool          // layer rows (else effect rows)
        let on: Bool              // the state every passed row gets
        /// The span of the list the pointer has covered since the press: the pointer moves continuously, so every row
        /// in it was passed (also rows that loaded only once the list scrolled).
        var lo: CGFloat
        var hi: CGFloat
        var applied: Set<EyeTarget> = []
        var changed: [EyeTarget] = []
    }
    private(set) var session: Session?
    var isDragging: Bool { session != nil }

    func setFrame(_ t: EyeTarget, _ r: CGRect) {
        seq += 1
        frameOf[t] = (r, seq)
        sorted = nil
        rowsChanged()
    }

    func removeFrame(_ t: EyeTarget) {
        guard frameOf.removeValue(forKey: t) != nil else { return }
        sorted = nil
    }

    /// Replaces every frame (tests).
    func setFrames(_ f: [EyeRowFrame]) {
        frameOf = [:]
        for x in f { seq += 1; frameOf[x.target] = (x.frame, seq) }
        sorted = nil
        rowsChanged()
    }

    /// Rows coming in while the list autoscrolls (their frames arrive after the scroll) get the drag's state too.
    private func rowsChanged() {
        guard session != nil, !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in self?.pending = false; self?.applySpan() }
    }
    private var pending = false

    func target(at p: CGPoint) -> EyeTarget? {
        frames.last { $0.frame.minY <= p.y && p.y < $0.frame.maxY }?.target
    }

    func frame(of t: EyeTarget) -> CGRect? { frames.first { $0.target == t }?.frame }

    /// Mouse down at `p` (list coordinates). ⌥ on a layer's eye shows only that layer (or restores, see
    /// `EyeVisibility.soloOrRestore`) without starting a drag. False when there is no eye there.
    @discardableResult
    func begin(at p: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        if session != nil { end() }
        guard let d = doc, let t = target(at: p) else { return false }
        if modifiers.contains(.option), t.isLayer {
            EyeVisibility.soloOrRestore(d, t.layerID)
            return true
        }
        guard let on = EyeVisibility.isOn(d.state, t) else { return false }
        session = Session(doc: d, layers: t.isLayer, on: !on, lo: p.y, hi: p.y)
        apply([t])
        return true
    }

    /// The pointer moved to `p`: every row of the drag's kind it has passed gets the drag's state (a row passed again
    /// keeps it).
    func move(to p: CGPoint) {
        guard session != nil else { return }
        session!.lo = min(session!.lo, p.y)
        session!.hi = max(session!.hi, p.y)
        applySpan()
    }

    /// Mouse up: one history step for the whole drag (none when nothing changed).
    func end() {
        guard let s = session else { return }
        session = nil
        guard let d = s.doc, !s.changed.isEmpty else { return }
        d.commit(EyeVisibility.stepName(d.state, s.changed, s.on))
    }

    private func applySpan() {
        guard let s = session else { return }
        apply(frames.filter { $0.target.isLayer == s.layers && $0.frame.maxY > s.lo && $0.frame.minY <= s.hi && !s.applied.contains($0.target) }.map(\.target))
    }

    private func apply(_ targets: [EyeTarget]) {
        guard let s = session, let d = s.doc, !targets.isEmpty else { return }
        var st = d.state
        var changed: [EyeTarget] = []
        for t in targets where EyeVisibility.set(&st, t, s.on) { changed.append(t) }
        session?.applied.formUnion(targets)
        guard !changed.isEmpty else { return }
        EyeVisibility.apply(d, st, touched: changed.map(\.layerID))   // live: the canvas follows the drag
        session?.changed += changed
    }
}

// MARK: - The eye column (mouse)

struct EyeColumn: NSViewRepresentable {
    let drag: EyeDragCoordinator
    let doc: Document
    let rows: [UUID]

    func makeNSView(context: Context) -> EyeColumnView {
        let v = EyeColumnView()
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: EyeColumnView, context: Context) {
        v.drag = drag
        drag.doc = doc
        drag.listed = Set(rows)
    }
}

/// Transparent AppKit view over the eye column of the whole list (one view, so the drag survives rows scrolling out
/// and lazily unloading). Takes mouse down / dragged / up and right-clicks where a row has an eye.
final class EyeColumnView: NSView {
    var drag: EyeDragCoordinator?
    private var timer: Timer?
    /// Last pointer position (window coordinates) of the drag; the autoscroll timer re-reads it as the list moves.
    private(set) var lastWindowPoint: NSPoint = .zero
    /// Height of the band at the top / bottom edge of the visible list that scrolls it.
    static let edge: CGFloat = 14

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard AppModel.shared.dialog == nil, let v = super.hitTest(point), v === self else { return nil }
        return drag?.target(at: convert(point, from: superview)) != nil ? self : nil
    }

    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control) {
            if let m = menu(for: e) { NSMenu.popUpContextMenu(m, with: e, for: self) }
            return
        }
        lastWindowPoint = e.locationInWindow
        guard let d = drag, d.begin(at: convert(e.locationInWindow, from: nil), modifiers: e.modifierFlags) else { return }
        if d.isDragging { startAutoscroll() }
    }

    override func mouseDragged(with e: NSEvent) {
        lastWindowPoint = e.locationInWindow
        track()
    }

    override func mouseUp(with e: NSEvent) {
        lastWindowPoint = e.locationInWindow
        track()
        stopAutoscroll()
        drag?.end()
    }

    override func menu(for e: NSEvent) -> NSMenu? {
        guard let c = drag, let d = c.doc, case .layer(let id)? = c.target(at: convert(e.locationInWindow, from: nil)) else { return nil }
        return EyeVisibility.nsMenu(d, id)
    }

    /// The pointer (clamped into the visible part of the list) to the coordinator.
    func track() {
        guard let d = drag, d.isDragging else { return }
        let p = convert(lastWindowPoint, from: nil)
        let vis = visibleRect.isEmpty ? bounds : visibleRect
        d.move(to: CGPoint(x: p.x, y: min(max(p.y, vis.minY + 1), vis.maxY - 1)))
    }

    /// Drives a drag from window positions without mouse events (self tests).
    func simulate(_ phase: NSEvent.EventType, window p: NSPoint, modifiers: NSEvent.ModifierFlags = []) {
        lastWindowPoint = p
        switch phase {
        case .leftMouseDown: _ = drag?.begin(at: convert(p, from: nil), modifiers: modifiers)
        case .leftMouseUp: track(); drag?.end()
        default: track()
        }
    }

    // MARK: Autoscroll

    private func startAutoscroll() {
        stopAutoscroll()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.autoscrollTick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopAutoscroll() {
        timer?.invalidate()
        timer = nil
    }

    /// With the pointer at (or past) the top or bottom edge of the visible list, scrolls it a step and goes on with
    /// the rows that come into view. Returns the distance scrolled.
    @discardableResult
    func autoscrollTick() -> CGFloat {
        guard let d = drag, d.isDragging else { stopAutoscroll(); return 0 }
        let vis = visibleRect
        guard !vis.isEmpty else { return 0 }
        let p = convert(lastWindowPoint, from: nil)
        var target: CGRect?
        if p.y < vis.minY + Self.edge && vis.minY > bounds.minY {
            let step = min(40, max(4, vis.minY + Self.edge - p.y))
            target = CGRect(x: 0, y: max(bounds.minY, vis.minY - step), width: 1, height: 1)
        } else if p.y > vis.maxY - Self.edge && vis.maxY < bounds.maxY {
            let step = min(40, max(4, p.y - (vis.maxY - Self.edge)))
            target = CGRect(x: 0, y: min(bounds.maxY - 1, vis.maxY + step - 1), width: 1, height: 1)
        }
        guard let r = target else { return 0 }
        scrollToVisible(r)
        let moved = visibleRect.minY - vis.minY
        if moved != 0 { track() }
        return moved
    }
}
