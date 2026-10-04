import AppKit
import SwiftUI
import ImageCratCore

// Layout power tools: live repeater, tidy up & smart spacing, pack & fill, select similar,
// document-wide replace, smart resize for social formats, and per-layer constraints.

/// Geometry helpers shared by the layout features (all in document space, y-down).
enum LayoutGeom {
    static func bounds(_ id: UUID, _ st: DocumentState) -> CGRect? {
        guard let l = st.layer(id) else { return nil }
        return Compositor.shared.contentBounds(l, state: st)
    }

    /// (id, bounds) of the layers that have visible content, in the given order.
    static func items(_ ids: [UUID], _ st: DocumentState) -> [(id: UUID, rect: CGRect)] {
        ids.compactMap { id in bounds(id, st).flatMap { $0.width > 0 && $0.height > 0 ? (id, $0) : nil } }
    }

    static func union(_ rects: [CGRect]) -> CGRect? {
        guard var u = rects.first else { return nil }
        for r in rects.dropFirst() { u = u.union(r) }
        return u
    }

    static func translate(_ st: inout DocumentState, _ id: UUID, dx: CGFloat, dy: CGFloat) {
        let x = Double(dx.rounded()), y = Double(dy.rounded())
        guard x != 0 || y != 0 else { return }
        st.updateLayer(id) { $0.translate(dx: x, dy: y) }
    }

    /// Applies a document-space affine transform to a layer (pure translations keep pixels untouched).
    static func apply(_ st: inout DocumentState, _ id: UUID, _ t: CGAffineTransform) {
        if abs(t.a - 1) < 1e-6, abs(t.d - 1) < 1e-6, abs(t.b) < 1e-6, abs(t.c) < 1e-6 {
            translate(&st, id, dx: t.tx, dy: t.ty)
            return
        }
        guard let l = st.layer(id) else { return }
        let moved = transformed(l, t, space: CanvasSpace(width: st.width, height: st.height))
        st.updateLayer(id) { $0 = moved }
    }

    /// `LayerTransformer.apply` for an affine transform; repeaters inside follow a scale / flip with their spacing.
    static func transformed(_ l: Layer, _ t: CGAffineTransform, space: CanvasSpace, scaleEffects: Double? = nil, document: Bool = false) -> Layer {
        var out = LayerTransformer.apply(Homography(affine: t), to: l, space: space, scaleEffects: scaleEffects, document: document)
        RepeaterActions.follow(&out, t)
        return out
    }

    /// Transform taking rect `a` onto rect `b` (independent x / y scale).
    static func map(_ a: CGRect, to b: CGRect) -> CGAffineTransform {
        let sx = a.width > 0 ? b.width / a.width : 1, sy = a.height > 0 ? b.height / a.height : 1
        return CGAffineTransform(translationX: -a.minX, y: -a.minY)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(translationX: b.minX, y: b.minY))
    }

    /// Moves / scales a layer so its content bounds become `target`.
    static func setFrame(_ st: inout DocumentState, _ id: UUID, to target: CGRect) {
        guard let b = bounds(id, st), b.width > 0, b.height > 0 else { return }
        apply(&st, id, map(b, to: target))
    }

    /// Uniform scale around the layer's centre, then move the centre to `center`.
    static func place(_ st: inout DocumentState, _ id: UUID, center: CGPoint, scale: CGFloat = 1) {
        guard let b = bounds(id, st) else { return }
        let t = CGAffineTransform(translationX: -b.midX, y: -b.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        apply(&st, id, t)
    }

    /// A fillable outline (closed loops, even-odd) of a selection mask. `SelectionOps.outline` only gives loose edge
    /// segments for the marching ants; this chains them into polygons. Very intricate selections fall back to their bounding box.
    static func regionPath(fromMask m: PixelBuffer) -> CGPath {
        var segs: [(CGPoint, CGPoint)] = []
        var cur: CGPoint?
        SelectionOps.outline(m).applyWithBlock { e in
            switch e.pointee.type {
            case .moveToPoint: cur = e.pointee.points[0]
            case .addLineToPoint:
                if let c = cur { segs.append((c, e.pointee.points[0])) }
                cur = e.pointee.points[0]
            default: break
            }
        }
        if segs.count > 40_000 || segs.isEmpty {
            return CGPath(rect: m.opaqueBounds()?.cgRect ?? CGRect(x: 0, y: 0, width: m.width, height: m.height), transform: nil)
        }
        func key(_ p: CGPoint) -> Int { Int(p.y.rounded()) * 1_000_000 + Int(p.x.rounded()) }
        var at: [Int: [Int]] = [:]
        for (i, s) in segs.enumerated() { at[key(s.0), default: []].append(i); at[key(s.1), default: []].append(i) }
        var used = [Bool](repeating: false, count: segs.count)
        let path = CGMutablePath()
        for i in segs.indices where !used[i] {
            used[i] = true
            var pts = [segs[i].0, segs[i].1]
            var end = segs[i].1
            while key(end) != key(pts[0]) {
                guard let next = at[key(end)]?.first(where: { !used[$0] }) else { break }
                used[next] = true
                end = key(segs[next].0) == key(end) ? segs[next].1 : segs[next].0
                pts.append(end)
            }
            if pts.count >= 4 { path.addLines(between: pts); path.closeSubpath() }
        }
        return path
    }

    /// Ids whose position may be changed (not position-locked, has bounds).
    static func movable(_ d: Document) -> [UUID] {
        d.orderedSelection.filter { id in
            guard let l = d.state.layer(id), !l.locks.positionLocked else { return false }
            return Compositor.shared.contentBounds(l, state: d.state) != nil
        }
    }
}

/// View preferences of the layout module are stored in the user defaults; the headless tests switch that off.
enum LayoutPrefs {
    static var persist = true
    static func set(_ v: Any, _ key: String) { if persist { UserDefaults.standard.set(v, forKey: key) } }
}

/// A live-preview session for the layout dialogs: the document state is rebuilt from `base` on every change
/// and committed once (or restored on cancel).
final class LayoutPreviewSession {
    private(set) var base: DocumentState?
    private(set) var ids: [UUID] = []
    private var selection: Set<UUID> = []
    private var active: UUID?
    private var started = false

    func begin() {
        guard !started, let d = AppActions.doc else { return }
        started = true
        base = d.state
        ids = d.orderedSelection
        selection = d.selectedLayerIDs
        active = d.activeLayerID
    }

    func preview(_ make: (DocumentState, [UUID], Document) -> DocumentState) {
        guard let d = AppActions.doc, let b = base else { return }
        d.state = make(b, ids, d)
        d.setNeedsRender()
        AppActions.canvas?.overlay.needsDisplay = true
    }

    func finish(apply: Bool, name: String) {
        ArrangeGuide.path = nil
        AppActions.canvas?.overlay.needsDisplay = true
        guard let d = AppActions.doc, let b = base else { return }
        if apply {
            d.commit(name)
        } else {
            d.state = b
            d.activeLayerID = active
            d.selectedLayerIDs = selection
            d.setNeedsRender()
        }
    }
}

/// Non-printing canvas overlays of the layout module (spacing handles, social safe zones).
enum LayoutOverlays {
    static func draw(_ ctx: CGContext, canvas: CanvasView, doc: Document) {
        SafeZones.draw(ctx, canvas: canvas, doc: doc)
        SpacingHandles.shared.draw(ctx, canvas: canvas, doc: doc)
    }
}

/// Extra sections of the Properties panel (repeater controls, constraints).
struct LayoutProperties: View {
    @Bindable var doc: Document
    let layer: Layer

    var body: some View {
        if case .group(let g) = layer.content, let r = g.repeater {
            Divider()
            RepeaterProperties(doc: doc, layerID: layer.id, settings: r)
        } else if let rid = RepeaterActions.activeRepeater(doc), rid != layer.id {
            Divider()
            HStack {
                Text("Source of a Repeater — edits show in every copy").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                Spacer()
                Button("Repeater") { doc.selectLayer(rid) }.buttonStyle(PanelButtonStyle()).help("Select the repeater to change its pattern")
            }
        }
        if !layer.isAdjustment && doc.editTarget != .mask {
            Divider()
            ConstraintProperties(doc: doc, layer: layer)
        }
    }
}

// MARK: - Registration

enum LayoutModule {
    static func register() {
        let sel = { AppActions.doc?.orderedSelection.count ?? 0 }
        let any = { sel() >= 1 }
        let two = { sel() >= 2 }
        let hasDoc = { AppActions.doc != nil }
        let isRepeater = { RepeaterActions.activeRepeater(AppActions.doc) != nil }

        // 1. Live repeater
        DialogRegistry.register("layout.repeater", dims: false) { AnyView(RepeaterDialog()) }
        MenuRegistry.add("Layer", "Repeat…", submenu: "Repeater", enabled: any) { DialogRegistry.show("layout.repeater") }
        MenuRegistry.add("Layer", "Expand Repeater", submenu: "Repeater", enabled: isRepeater) { RepeaterActions.expandActive() }
        MenuRegistry.add("Layer", "Release Repeater", submenu: "Repeater", enabled: isRepeater) { RepeaterActions.releaseActive() }

        // 2. Tidy up & smart spacing (Layer ▸ Arrange)
        DialogRegistry.register("layout.spacing", dims: false) { AnyView(DistributeSpacingDialog()) }
        MenuRegistry.add("Layer/Arrange", "Tidy Up", enabled: two) { TidyUp.run() }
        MenuRegistry.add("Layer/Arrange", "Distribute with Spacing…", enabled: two) { DialogRegistry.show("layout.spacing") }
        MenuRegistry.add("Layer/Arrange", "Swap Positions", enabled: two) { TidyUp.swapPositions() }
        MenuRegistry.add("Layer/Arrange", "Width", submenu: "Match Size", enabled: two) { TidyUp.matchSize(width: true, height: false) }
        MenuRegistry.add("Layer/Arrange", "Height", submenu: "Match Size", enabled: two) { TidyUp.matchSize(width: false, height: true) }
        MenuRegistry.add("Layer/Arrange", "Width and Height", submenu: "Match Size", enabled: two) { TidyUp.matchSize(width: true, height: true) }
        MenuRegistry.add("Layer/Arrange", "Spacing Handles", dividerBefore: true) { SpacingHandles.shared.toggle() }

        // 3. Pack & fill
        DialogRegistry.register("layout.pack", dims: false) { AnyView(PackDialog()) }
        DialogRegistry.register("layout.collage", dims: false) { AnyView(CollageDialog()) }
        MenuRegistry.add("Layer", "Pack into Shape…", submenu: "Pack & Fill", enabled: two) { DialogRegistry.show("layout.pack") }
        MenuRegistry.add("Layer", "Auto Collage…", submenu: "Pack & Fill", enabled: hasDoc) { DialogRegistry.show("layout.collage") }

        // 4. Select similar
        for c in SimilarCriterion.allCases {
            MenuRegistry.add("Select", c.rawValue, submenu: "Similar Layers", enabled: { AppActions.doc?.activeLayer != nil }) { SelectSimilar.run(c) }
        }

        // 5. Document-wide replace
        DialogRegistry.register("layout.findReplace", dims: false) { AnyView(FindReplaceDialog()) }
        MenuRegistry.add("Edit", "Find and Replace in Document…", dividerBefore: true, enabled: hasDoc) { DialogRegistry.show("layout.findReplace") }

        // 6. Smart resize + safe zones
        DialogRegistry.register("layout.smartResize") { AnyView(SmartResizeDialog()) }
        MenuRegistry.add("File", "Smart Resize…", dividerBefore: true, enabled: hasDoc) { DialogRegistry.show("layout.smartResize") }
        for z in SafeZoneKind.allCases {
            MenuRegistry.add("View", z.rawValue, submenu: "Safe Zones") { SafeZones.set(z) }
        }

        // 7. Constraints: artboard resizes are picked up when the step is committed (repeaters follow whole-group transforms there too)
        LayoutConstraintEngine.installCommitHook()

        FeatureModules.selfTests.append(("layout", { out in LayoutSelfTest.run(out) }))
    }
}
