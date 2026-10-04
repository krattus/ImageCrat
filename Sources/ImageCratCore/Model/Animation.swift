import Foundation

/// Frame-animation helpers (Timeline panel). Pure functions on `DocumentState`; no undo handling.
///
/// A frame stores, per layer, visibility, opacity and a position "anchor". The anchor is a cheap
/// reference point that moves 1:1 with `Layer.translate(dx:dy:)` (raster origin, text/shape
/// transform translation, smart object top-left corner, …); applying a frame translates each layer
/// by the difference between the stored and current anchor. Groups store visibility/opacity only;
/// their children carry positions.
package enum Animation {
    package static let delayPresets: [Double] = [0, 0.1, 0.2, 0.5, 1, 2, 5, 10]

    package static func delayLabel(_ d: Double) -> String {
        if d == 0 { return "0 sec." }
        if d == d.rounded() { return "\(Int(d)) sec." }
        return String(format: "%g", d)
    }

    // MARK: Anchor

    package static func anchor(_ l: Layer) -> CGPoint? {
        switch l.content {
        case .raster(let r): return CGPoint(x: r.origin.x, y: r.origin.y)
        case .text(let t): return CGPoint(x: t.transform.tx, y: t.transform.ty)
        case .shape(let s): return CGPoint(x: s.transform.tx, y: s.transform.ty)
        case .smartObject(let s): return s.quad.tl
        case .fill(let f):
            if case .gradient(let g) = f.paint, let s = g.start, g.end != nil { return s }
            return nil
        case .adjustment, .group: return nil
        }
    }

    /// True when `b` is `a` moved by `Layer.translate` and nothing else. Any other edit (scale, rotate, flip, warp,
    /// painting that grows the pixel buffer, rasterizing, converting to a shape …) changes where the anchor sits
    /// relative to the content.
    package static func isPureMove(_ a: Layer, _ b: Layer) -> Bool {
        func sameLinear(_ m: CGAffineTransform, _ n: CGAffineTransform) -> Bool { m.a == n.a && m.b == n.b && m.c == n.c && m.d == n.d }
        switch (a.content, b.content) {
        case (.raster(let x), .raster(let y)):
            if x.buffer === y.buffer { return true }
            // a move through Free Transform re-renders the pixels: identical pixels at a new origin are still a move
            guard x.buffer.width == y.buffer.width, x.buffer.height == y.buffer.height, x.buffer.format == y.buffer.format,
                  x.buffer.bytesPerRow == y.buffer.bytesPerRow else { return false }
            return memcmp(x.buffer.data, y.buffer.data, x.buffer.bytesPerRow * x.buffer.height) == 0
        case (.text(let x), .text(let y)):
            var z = x; z.transform = y.transform
            return z == y && sameLinear(x.transform, y.transform)
        case (.shape(let x), .shape(let y)):
            var z = x; z.transform = y.transform; z.perspective = y.perspective
            return z == y && sameLinear(x.transform, y.transform)
        case (.smartObject(let x), .smartObject(let y)):
            let d = y.quad.tl - x.quad.tl
            let moved = zip(x.quad.points, y.quad.points).allSatisfy { abs($1.x - $0.x - d.x) < 1e-6 && abs($1.y - $0.y - d.y) < 1e-6 }
            return moved && x.sourceRevision == y.sourceRevision && (x.warp == nil) == (y.warp == nil)
        case (.fill, .fill):
            return true
        default:
            return false
        }
    }

    // MARK: Capture / apply

    /// Records the current layer state. Keeps `base`'s id and delay when given.
    package static func capture(_ st: DocumentState, base: AnimationFrame? = nil) -> AnimationFrame {
        var f = base ?? AnimationFrame()
        f.visibility = [:]; f.positions = [:]; f.opacities = [:]
        for l in st.allLayers {
            f.visibility[l.id] = l.isVisible
            f.opacities[l.id] = l.opacity
            if let a = anchor(l) { f.positions[l.id] = a }
        }
        return f
    }

    /// Applies a frame's stored properties to the layers. Layers the frame doesn't know are left alone.
    package static func apply(_ f: AnimationFrame, to st: inout DocumentState) {
        for l in st.allLayers {
            let id = l.id
            let vis = f.visibility[id], op = f.opacities[id]
            var delta: CGPoint? = nil
            if let p = f.positions[id], let a = anchor(l) {
                let dx = p.x - a.x, dy = p.y - a.y
                if abs(dx) > 0.001 || abs(dy) > 0.001 { delta = CGPoint(x: dx, y: dy) }
            }
            if vis == nil && op == nil && delta == nil { continue }
            if (vis ?? l.isVisible) == l.isVisible && (op ?? l.opacity) == l.opacity && delta == nil { continue }
            st.updateLayer(id) { layer in
                if let v = vis { layer.isVisible = v }
                if let o = op { layer.opacity = o }
                if let d = delta { layer.translate(dx: d.x, dy: d.y) }
            }
        }
    }

    package static func applied(_ f: AnimationFrame, to st: DocumentState) -> DocumentState {
        var s = st
        apply(f, to: &s)
        return s
    }

    /// True when the layers currently look like the frame (within rounding).
    package static func matches(_ f: AnimationFrame, _ st: DocumentState) -> Bool {
        for l in st.allLayers {
            if let v = f.visibility[l.id], v != l.isVisible { return false }
            if let o = f.opacities[l.id], abs(o - l.opacity) > 0.001 { return false }
            if let p = f.positions[l.id], let a = anchor(l), abs(p.x - a.x) > 0.5 || abs(p.y - a.y) > 0.5 { return false }
        }
        return true
    }

    /// Fills entries for layers a frame doesn't know yet from the current layer state
    /// (Photoshop's "new layers visible in all frames").
    package static func fillMissing(_ f: inout AnimationFrame, from st: DocumentState) {
        for l in st.allLayers where f.visibility[l.id] == nil {
            f.visibility[l.id] = l.isVisible
            f.opacities[l.id] = l.opacity
            if let a = anchor(l) { f.positions[l.id] = a }
        }
    }

    // MARK: Tween

    /// `count` frames interpolated between `a` and `b` (exclusive), in order a → b.
    /// Layers visible in only one of the frames fade in/out through opacity.
    package static func tween(from a: AnimationFrame, to b: AnimationFrame, count: Int,
                      position: Bool = true, opacity: Bool = true) -> [AnimationFrame] {
        guard count > 0 else { return [] }
        let ids = Set(a.visibility.keys).union(b.visibility.keys).union(a.positions.keys).union(b.positions.keys)
        var out: [AnimationFrame] = []
        for k in 1...count {
            let t = Double(k) / Double(count + 1)
            var f = AnimationFrame()
            f.delay = a.delay
            for id in ids {
                let va = a.visibility[id] ?? b.visibility[id] ?? true
                let vb = b.visibility[id] ?? va
                let oa = a.opacities[id] ?? b.opacities[id] ?? 1
                let ob = b.opacities[id] ?? oa
                if opacity {
                    if va && vb {
                        f.visibility[id] = true; f.opacities[id] = oa + (ob - oa) * t
                    } else if va || vb {
                        let o = (va ? oa : 0) + ((vb ? ob : 0) - (va ? oa : 0)) * t
                        f.visibility[id] = o > 0.001; f.opacities[id] = o
                    } else {
                        f.visibility[id] = false; f.opacities[id] = oa
                    }
                } else {
                    f.visibility[id] = va; f.opacities[id] = oa
                }
                if let pa = a.positions[id] {
                    if position, let pb = b.positions[id] {
                        f.positions[id] = CGPoint(x: pa.x + (pb.x - pa.x) * t, y: pa.y + (pb.y - pa.y) * t)
                    } else {
                        f.positions[id] = pa
                    }
                } else if let pb = b.positions[id] {
                    f.positions[id] = pb
                }
            }
            out.append(f)
        }
        return out
    }

    // MARK: Frames from layers

    /// One frame per top-level layer (bottom → top); a bottom "Background" layer stays visible in all frames.
    package static func framesFromLayers(_ st: DocumentState, delay: Double) -> [AnimationFrame] {
        var base = capture(st)
        let top = st.layers
        var start = 0
        if let first = top.first, first.name == "Background", first.isRaster, top.count > 1 {
            base.visibility[first.id] = true
            start = 1
        }
        var frames: [AnimationFrame] = []
        for i in start..<top.count {
            var f = base
            f.id = UUID()
            f.delay = delay
            for j in start..<top.count { f.visibility[top[j].id] = (i == j) }
            // children keep their own visibility; only the top-level item is switched
            frames.append(f)
        }
        return frames
    }

    // MARK: Rendering
}
