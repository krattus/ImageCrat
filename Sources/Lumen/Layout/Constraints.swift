import AppKit
import SwiftUI
import ImageCratCore

enum LayoutConstraintEngine {
    /// Re-lays out the direct children of a container that carry constraints. `ids` are looked up in `st`,
    /// whose layers still sit where they were for the `old` container rect.
    static func apply(_ st: inout DocumentState, ids: [UUID], from old: CGRect, to new: CGRect) {
        guard old != new, old.width > 0, old.height > 0 else { return }
        for id in ids {
            guard let l = st.layer(id), let c = l.constraints, !l.locks.positionLocked,
                  let b = Compositor.shared.contentBounds(l, state: st), b.width > 0, b.height > 0 else { continue }
            var target = c.frame(for: b, from: old, to: new)
            if l.isText, target.size != b.size {
                // type keeps its proportions: scale uniformly into the stretched box
                let k = min(target.width / b.width, target.height / b.height)
                let sz = CGSize(width: b.width * k, height: b.height * k)
                target = CGRect(x: target.midX - sz.width / 2, y: target.midY - sz.height / 2, width: sz.width, height: sz.height)
            }
            if target.size != b.size {     // snap resized frames to whole pixels (edges, not just the origin)
                let x0 = target.minX.rounded(), y0 = target.minY.rounded()
                target = CGRect(x: x0, y: y0, width: max(1, target.maxX.rounded() - x0), height: max(1, target.maxY.rounded() - y0))
            }
            LayoutGeom.setFrame(&st, id, to: target)
        }
    }

    /// Canvas Size hook. `st` is the resized state (layers already shifted by the anchor); `before` the state before the command.
    /// Layers with constraints ignore the anchor shift and follow their pins instead.
    static func canvasResized(_ st: inout DocumentState, from before: DocumentState) {
        let constrained = before.layers.filter { $0.constraints != nil }
        guard !constrained.isEmpty, before.width != st.width || before.height != st.height else { return }
        for l in constrained { st.updateLayer(l.id) { $0 = l } }     // back to the pre-resize position
        apply(&st, ids: constrained.map(\.id), from: before.canvasCGRect, to: CGRect(x: 0, y: 0, width: st.width, height: st.height))
    }

    /// Commit hook: when an artboard's rectangle changed but its constrained children did not move, lay them out again.
    static func artboardsResized(_ d: Document) {
        let before = d.committedState
        var st = d.state
        var changed = false
        for l in st.allLayers {
            guard let ab = l.artboard, let old = before.layer(l.id)?.artboard, old.rect.size != ab.rect.size else { continue }
            let kids = l.children.filter { $0.constraints != nil }
            guard !kids.isEmpty else { continue }
            // untouched children only (a free transform of the artboard already scaled them); a common shift is fine
            // (growing the canvas to the left / top moves every layer together with the artboard)
            var shift: CGPoint?
            var untouched = true
            for k in kids {
                guard let o = before.layer(k.id), let b0 = Compositor.shared.contentBounds(o, state: before),
                      let b1 = Compositor.shared.contentBounds(k, state: st),
                      abs(b0.width - b1.width) < 0.5, abs(b0.height - b1.height) < 0.5 else { untouched = false; break }
                let dlt = CGPoint(x: b1.minX - b0.minX, y: b1.minY - b0.minY)
                if let s0 = shift, s0.distance(to: dlt) > 0.5 { untouched = false; break }
                shift = dlt
            }
            guard untouched, let dl = shift else { continue }
            apply(&st, ids: kids.map(\.id), from: old.rect.offsetBy(dx: dl.x, dy: dl.y), to: ab.rect)
            changed = true
        }
        if changed { d.state = st }
    }

    private static var installed = false
    static func installCommitHook() {
        guard !installed else { return }
        installed = true
        let previous = Document.willCommit
        Document.willCommit = { d in
            previous?(d)
            artboardsResized(d)
            RepeaterActions.followTransforms(d)
        }
    }

    static func set(_ d: Document, ids: [UUID], _ c: LayoutConstraints?) {
        for id in ids { d.updateLayer(id) { $0.constraints = c } }
        d.commit(c == nil ? "Clear Constraints" : "Constraints")
    }
}

/// "Constraints" section of the Properties panel.
struct ConstraintProperties: View {
    @Bindable var doc: Document
    let layer: Layer

    private var ids: [UUID] { doc.selectedLayerIDs.contains(layer.id) ? doc.orderedSelection : [layer.id] }
    private var container: String {
        var id = doc.state.parentID(of: layer.id)
        while let i = id, let l = doc.state.layer(i) {
            if l.isArtboard { return "artboard “\(l.name)”" }
            id = doc.state.parentID(of: i)
        }
        return "canvas"
    }

    var body: some View {
        let c = layer.constraints
        Caption("Constraints")
        Toggle2(label: "Follow the \(container) when it is resized", on: Binding(get: { c != nil }, set: { on in
            LayoutConstraintEngine.set(doc, ids: ids, on ? LayoutConstraints() : nil)
        }))
        if let c {
            HStack(spacing: 8) {
                ConstraintGlyph(c: c).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: Binding(get: { c.horizontal }, set: { v in
                        var n = c; n.horizontal = v
                        LayoutConstraintEngine.set(doc, ids: ids, n)
                    })) { ForEach(LayoutConstraints.Axis.allCases) { Text(tr($0.title(horizontal: true))).tag($0) } }.labelsHidden().frame(width: 130)
                    Picker("", selection: Binding(get: { c.vertical }, set: { v in
                        var n = c; n.vertical = v
                        LayoutConstraintEngine.set(doc, ids: ids, n)
                    })) { ForEach(LayoutConstraints.Axis.allCases) { Text(tr($0.title(horizontal: false))).tag($0) } }.labelsHidden().frame(width: 130)
                }
            }
            Text("Pinned edges keep their distance, Centre keeps the offset from the middle, Scale resizes in proportion. Used by Canvas Size, artboard resizing and Smart Resize.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Small diagram of the pins (like the constraint widget in UI design tools).
struct ConstraintGlyph: View {
    let c: LayoutConstraints?

    var body: some View {
        Canvas { ctx, size in
            let outer = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            ctx.stroke(Path(roundedRect: outer, cornerRadius: 3), with: .color(Color(white: 0.45)), lineWidth: 1)
            let inner = outer.insetBy(dx: size.width * 0.3, dy: size.height * 0.3)
            ctx.fill(Path(roundedRect: inner, cornerRadius: 2), with: .color(Color(white: c == nil ? 0.3 : 0.55)))
            guard let c else { return }
            let on = Color(red: 0.25, green: 0.6, blue: 1)
            func line(_ a: CGPoint, _ b: CGPoint) {
                var p = Path(); p.move(to: a); p.addLine(to: b)
                ctx.stroke(p, with: .color(on), lineWidth: 2)
            }
            let h = c.horizontal, v = c.vertical
            if h == .start || h == .both || h == .scale { line(CGPoint(x: outer.minX, y: inner.midY), CGPoint(x: inner.minX, y: inner.midY)) }
            if h == .end || h == .both || h == .scale { line(CGPoint(x: inner.maxX, y: inner.midY), CGPoint(x: outer.maxX, y: inner.midY)) }
            if h == .center { line(CGPoint(x: inner.midX - 5, y: inner.midY), CGPoint(x: inner.midX + 5, y: inner.midY)) }
            if v == .start || v == .both || v == .scale { line(CGPoint(x: inner.midX, y: outer.minY), CGPoint(x: inner.midX, y: inner.minY)) }
            if v == .end || v == .both || v == .scale { line(CGPoint(x: inner.midX, y: inner.maxY), CGPoint(x: inner.midX, y: outer.maxY)) }
            if v == .center { line(CGPoint(x: inner.midX, y: inner.midY - 5), CGPoint(x: inner.midX, y: inner.midY + 5)) }
        }
    }
}
