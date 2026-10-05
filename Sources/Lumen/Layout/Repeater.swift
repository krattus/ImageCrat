import AppKit
import CoreImage
import ImageCratCore

// MARK: - Geometry

enum RepeaterLayout {
    /// Outline used by "Along Shape" (centred on the origin).
    static func shapePath(_ s: RepeaterSettings) -> CGPath? {
        if s.shape == ArrangeSettings.Shape.path.rawValue { return capturedPath(s)?.path }
        var a = arrangeSettings(s)
        if a.shape == .grid { a.shape = .circle }
        return ArrangeOnShape.path(a, doc: dummyDoc)
    }

    private static let dummyDoc = Document(state: DocumentState(width: 16, height: 16), name: "repeater")

    private static func arrangeSettings(_ s: RepeaterSettings) -> ArrangeSettings {
        var a = ArrangeSettings()
        a.shape = ArrangeSettings.Shape(rawValue: s.shape) ?? .circle
        a.width = max(1, s.shapeWidth); a.height = max(1, s.shapeHeight)
        a.centerX = 0; a.centerY = 0
        a.rotation = s.shapeRotation
        a.sides = s.sides; a.starInset = s.starInset; a.arcAngle = s.arcAngle; a.turns = s.turns; a.waves = s.waves
        a.customID = s.customID
        return a
    }

    /// Evenly spaced slots along the shape (origin-centred).
    static func slots(_ s: RepeaterSettings, count: Int) -> [ArrangeOnShape.Slot] {
        guard count > 0 else { return [] }
        if s.shape == ArrangeSettings.Shape.path.rawValue {
            guard let p = capturedPath(s)?.path else { return [] }
            return sample(p, count: count)
        }
        var a = arrangeSettings(s)
        if a.shape == .grid { a.shape = .circle }
        return ArrangeOnShape.slots(a, count: count, doc: dummyDoc, cellSize: .zero)
    }

    /// `count` points evenly spaced by arc length along the longest subpath.
    static func sample(_ path: CGPath, count: Int) -> [ArrangeOnShape.Slot] {
        guard let line = ArrangeOnShape.polylines(path).max(by: { ArrangeOnShape.length($0.pts) < ArrangeOnShape.length($1.pts) }) else { return [] }
        let total = ArrangeOnShape.length(line.pts)
        guard total > 0 else { return [] }
        let n = line.closed ? count : max(1, count - 1)
        return (0..<count).map { i in
            let dist = min(total, total * CGFloat(i) / CGFloat(n))
            var acc: CGFloat = 0
            for k in 1..<line.pts.count {
                let seg = line.pts[k].distance(to: line.pts[k - 1])
                if acc + seg >= dist || k == line.pts.count - 1 {
                    let f = seg > 0 ? min(1, max(0, (dist - acc) / seg)) : 0
                    return ArrangeOnShape.Slot(point: line.pts[k - 1].lerp(line.pts[k], f), angle: atan2(line.pts[k].y - line.pts[k - 1].y, line.pts[k].x - line.pts[k - 1].x))
                }
                acc += seg
            }
            return ArrangeOnShape.Slot(point: line.pts.last ?? .zero, angle: 0)
        }
    }

    /// The captured outline as a CGPath (origin = source centre) and its fill rule.
    static func capturedPath(_ s: RepeaterSettings) -> (path: CGPath, evenOdd: Bool)? {
        guard let c = s.captured, !c.isEmpty else { return nil }
        if s.capturedEvenOdd { return (c.cgPath, true) }
        return c.resolved
    }

    /// Scatter region outline around `center`, and whether it is filled even-odd.
    static func region(_ s: RepeaterSettings, center c: CGPoint) -> (path: CGPath, evenOdd: Bool) {
        let r = CGRect(x: c.x - s.regionWidth / 2, y: c.y - s.regionHeight / 2, width: max(1, s.regionWidth), height: max(1, s.regionHeight))
        switch s.region {
        case .circle: return (CGPath(ellipseIn: r, transform: nil), false)
        case .rectangle: return (CGPath(rect: r, transform: nil), false)
        case .custom:
            guard let res = ShapeLibrary.shape(s.customID)?.path(in: r).resolved else { return (CGPath(rect: r, transform: nil), false) }
            return (res.path, res.evenOdd)
        case .captured:
            guard let cap = capturedPath(s) else { return (CGPath(ellipseIn: r, transform: nil), false) }
            var t = CGAffineTransform(translationX: c.x, y: c.y)
            return (cap.path.copy(using: &t) ?? cap.path, cap.evenOdd)
        }
    }

    static func regionPath(_ s: RepeaterSettings, center c: CGPoint) -> CGPath { region(s, center: c).path }

    /// Guide outline (document space) shown while the dialog is open.
    static func guide(_ s: RepeaterSettings, source b: CGRect) -> CGPath? {
        let c = CGPoint(x: b.midX, y: b.midY)
        switch s.mode {
        case .scatter: return regionPath(s, center: c)
        case .radial:
            let r = CGFloat(s.radius)
            return CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y, width: 2 * r, height: 2 * r), transform: nil)
        case .path:
            guard let p = shapePath(s), let first = slots(s, count: max(1, s.count)).first else { return nil }
            var t = CGAffineTransform(translationX: c.x - first.point.x, y: c.y - first.point.y)
            return p.copy(using: &t)
        case .mirror:
            let p = CGMutablePath()
            let gap = CGFloat(s.mirrorGap)
            if s.mirror == .horizontal || s.mirror == .four {
                p.move(to: CGPoint(x: b.maxX + gap, y: b.minY - 40)); p.addLine(to: CGPoint(x: b.maxX + gap, y: b.maxY + 2 * gap + b.height + 40))
            }
            if s.mirror == .vertical || s.mirror == .four {
                p.move(to: CGPoint(x: b.minX - 40, y: b.maxY + gap)); p.addLine(to: CGPoint(x: b.maxX + 2 * gap + b.width + 40, y: b.maxY + gap))
            }
            if s.mirror == .kaleidoscope {
                let o = CGPoint(x: c.x, y: b.maxY + gap)
                p.addEllipse(in: CGRect(x: o.x - 3, y: o.y - 3, width: 6, height: 6))
            }
            return p
        case .grid: return nil
        }
    }

    private static func reflection(through p: CGPoint, angle a: CGFloat) -> CGAffineTransform {
        let c2 = cos(2 * a), s2 = sin(2 * a)
        return CGAffineTransform(translationX: -p.x, y: -p.y)
            .concatenating(CGAffineTransform(a: c2, b: s2, c: s2, d: -c2, tx: 0, ty: 0))
            .concatenating(CGAffineTransform(translationX: p.x, y: p.y))
    }

    private static func rotation(about p: CGPoint, by a: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: -p.x, y: -p.y).concatenating(CGAffineTransform(rotationAngle: a)).concatenating(CGAffineTransform(translationX: p.x, y: p.y))
    }

    /// Where each instance goes before the progressive / random adjustments. The first one is always the source itself.
    static func placements(_ s: RepeaterSettings, source b: CGRect) -> [CGAffineTransform] {
        let c = CGPoint(x: b.midX, y: b.midY)
        let limit = RepeaterSettings.maxInstances
        switch s.mode {
        case .grid:
            let cols = max(1, s.columns), rows = max(1, s.rows)
            let px = b.width + CGFloat(s.gapX), py = b.height + CGFloat(s.gapY)
            var out: [CGAffineTransform] = []
            for r in 0..<rows {
                for col in 0..<cols where out.count < limit {
                    let shift = r % 2 == 1 ? CGFloat(s.stagger / 100) * px : 0
                    out.append(CGAffineTransform(translationX: CGFloat(col) * px + shift, y: CGFloat(r) * py))
                }
            }
            return out
        case .radial:
            let n = min(limit, max(1, s.count))
            let o = CGPoint(x: c.x, y: c.y + CGFloat(s.radius))
            let full = abs(s.arc) >= 359.999
            return (0..<n).map { k in
                let a = CGFloat(s.arc * .pi / 180) * CGFloat(k) / CGFloat(full ? n : max(1, n - 1))
                if s.rotateInstances { return rotation(about: o, by: a) }
                let p = c.rotated(by: a, around: o)
                return CGAffineTransform(translationX: p.x - c.x, y: p.y - c.y)
            }
        case .path:
            let n = min(limit, max(1, s.count))
            let sl = slots(s, count: n)
            guard sl.count == n, let first = sl.first else { return [.identity] }
            return sl.map { slot in
                let d = slot.point - first.point
                var t = CGAffineTransform.identity
                if s.followPath { t = rotation(about: c, by: slot.angle - first.angle) }
                return t.concatenating(CGAffineTransform(translationX: d.x, y: d.y))
            }
        case .mirror:
            let gap = CGFloat(s.mirrorGap)
            let flipH = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * (b.maxX + gap), ty: 0)
            let flipV = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * (b.maxY + gap))
            switch s.mirror {
            case .horizontal: return [.identity, flipH]
            case .vertical: return [.identity, flipV]
            case .four: return [.identity, flipH, flipV, flipH.concatenating(flipV)]
            case .kaleidoscope:
                let n = min(limit / 2, max(2, s.segments))
                let o = CGPoint(x: c.x, y: b.maxY + gap)
                // dihedral symmetry: n rotations plus n mirrored rotations, alternating around the centre
                let mirrorT = reflection(through: o, angle: -.pi / 2 + .pi / (2 * CGFloat(n)))
                var out: [CGAffineTransform] = []
                for k in 0..<n {
                    let rot = rotation(about: o, by: 2 * .pi * CGFloat(k) / CGFloat(n))
                    out.append(rot)
                    out.append(mirrorT.concatenating(rot))
                }
                return out
            }
        case .scatter:
            let n = min(limit, max(1, s.count))
            let reg = region(s, center: c)
            let path = reg.path
            let box = path.boundingBoxOfPath
            var rng = SeededGenerator(seed: UInt64(max(1, s.seed)) &* 2654435761)
            var pts: [CGPoint] = [c]
            let grow = CGFloat(1 + max(0, s.varyScale) / 100)
            let rotates = s.varyRotation != 0 || s.stepRotation != 0
            let diag = sqrt(b.width * b.width + b.height * b.height) * grow
            var attempts = 0
            while pts.count < n && attempts < n * 300 {
                attempts += 1
                let p = CGPoint(x: box.minX + CGFloat(Double.random(in: 0...1, using: &rng)) * box.width,
                                y: box.minY + CGFloat(Double.random(in: 0...1, using: &rng)) * box.height)
                guard path.contains(p, using: reg.evenOdd ? .evenOdd : .winding) else { continue }
                var ok = true
                for q in pts {
                    if s.minDistance > 0, p.distance(to: q) < CGFloat(s.minDistance) { ok = false; break }
                    if s.noOverlap {
                        if rotates { if p.distance(to: q) < diag { ok = false; break } }
                        else if abs(p.x - q.x) < b.width * grow && abs(p.y - q.y) < b.height * grow { ok = false; break }
                    }
                }
                if ok { pts.append(p) }
            }
            return pts.map { CGAffineTransform(translationX: $0.x - c.x, y: $0.y - c.y) }
        }
    }

    /// All instances (the first is the untouched source).
    static func instances(_ s: RepeaterSettings, source b: CGRect) -> [RepeaterInstance] {
        let c = CGPoint(x: b.midX, y: b.midY)
        let place = placements(s, source: b)
        let varies = s.varyHue != 0 || s.varyBrightness != 0 || s.varyRotation != 0 || s.varyScale != 0
        // a flipped repeater lays its pattern out mirrored about the source (the source itself was flipped by the transform)
        let flip: CGAffineTransform? = s.flipX || s.flipY
            ? CGAffineTransform(translationX: -c.x, y: -c.y).concatenating(CGAffineTransform(scaleX: s.flipX ? -1 : 1, y: s.flipY ? -1 : 1))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y)) : nil
        func mirrored(_ t: CGAffineTransform) -> CGAffineTransform { flip.map { $0.concatenating(t).concatenating($0) } ?? t }
        return place.enumerated().map { i, p in
            var inst = RepeaterInstance()
            guard i > 0 else { inst.transform = p; return inst }
            let f = Double(i)
            var scale = pow(max(0.01, s.stepScale / 100), f)
            var rot = s.stepRotation * f
            if varies {
                var rng = SeededGenerator(seed: UInt64(max(1, s.seed)) &* 1_000_003 &+ UInt64(i) &* 7919)
                func r() -> Double { Double.random(in: -1...1, using: &rng) }
                inst.hue = r() * s.varyHue
                inst.brightness = r() * s.varyBrightness
                rot += r() * s.varyRotation
                scale *= max(0.05, 1 + r() * s.varyScale / 100)
            }
            var local = CGAffineTransform(translationX: -c.x, y: -c.y)
            if abs(scale - 1) > 1e-6 { local = local.concatenating(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))) }
            if abs(rot) > 1e-6 { local = local.concatenating(CGAffineTransform(rotationAngle: CGFloat(rot * .pi / 180))) }
            local = local.concatenating(CGAffineTransform(translationX: c.x, y: c.y))
            inst.transform = mirrored(local.concatenating(p).concatenating(CGAffineTransform(translationX: CGFloat(s.stepX * f), y: CGFloat(s.stepY * f))))
            inst.opacity = max(0, min(1, 1 - s.stepOpacity / 100 * f))
            return inst
        }
    }
}

// MARK: - Rendering

/// Compositor hooks: renders a repeater group and reports its bounds.
enum RepeaterRenderer {
    private static var cache: [UUID: (settings: RepeaterSettings, size: CGSize, instances: [RepeaterInstance])] = [:]
    private static let lock = NSLock()

    /// Instances for a source at `b`. The layout only depends on the source's size, so it is computed once for a source
    /// centred on the origin and moved to the real position (dragging a repeater does not re-run e.g. the scatter).
    static func instances(_ id: UUID, _ s: RepeaterSettings, source b: CGRect) -> [RepeaterInstance] {
        lock.lock(); defer { lock.unlock() }
        var base: [RepeaterInstance]
        if let c = cache[id], c.settings == s, c.size == b.size {
            base = c.instances
        } else {
            base = RepeaterLayout.instances(s, source: CGRect(x: -b.width / 2, y: -b.height / 2, width: b.width, height: b.height))
            if cache.count > 256 { cache.removeAll() }
            cache[id] = (s, b.size, base)
        }
        let to = CGAffineTransform(translationX: -b.midX, y: -b.midY), back = CGAffineTransform(translationX: b.midX, y: b.midY)
        for i in base.indices {
            let t = base[i].transform
            if t.a == 1, t.b == 0, t.c == 0, t.d == 1 { continue }       // pure translations are the same anywhere
            base[i].transform = to.concatenating(t).concatenating(back)
        }
        return base
    }

    /// Bounds of the group's own children (the source), in document space.
    static func sourceBounds(_ g: GroupContent, width: Int, height: Int) -> CGRect? {
        let st = DocumentState(width: width, height: height)
        var u: CGRect?
        for c in g.children where c.isVisible {
            if let b = Compositor.shared.contentBounds(c, state: st) { u = u.map { $0.union(b) } ?? b }
        }
        return u
    }

    private static func effectsExtent(_ layers: [Layer]) -> CGFloat {
        var e: CGFloat = 0
        for l in layers.allLayers where l.effects.enabled && l.effects.hasAny { e = max(e, CGFloat(l.effects.extent)) }
        return e
    }

    static func image(_ layer: Layer, _ g: GroupContent, space: CanvasSpace, options: Compositor.Options) -> CIImage {
        let clear = CIImage.clearImage.cropped(to: space.ciCanvas)
        let source = Compositor.shared.composite(layers: g.children, backdrop: clear, space: space, options: options)
        guard let s = g.repeater, let b = sourceBounds(g, width: space.width, height: space.height) else { return source }
        let pad = effectsExtent(g.children) + 2
        let crop = space.ciRect(b.insetBy(dx: -pad, dy: -pad)).intersection(space.ciCanvas)
        guard !crop.isEmpty else { return source }
        let src = source.cropped(to: crop)
        let view = space.ciCanvas.insetBy(dx: -2000, dy: -2000)
        var out: CIImage = clear
        for inst in instances(layer.id, s, source: b) where inst.opacity > 0.001 {
            var img = inst.transform.isIdentity ? src : src.transformed(by: space.ciTransform(inst.transform), highQualityDownsample: true)
            guard img.extent.intersects(view) else { continue }
            if inst.hue != 0 || inst.brightness != 0 { img = AdjustmentEngine.apply(tint(inst), to: img) }
            out = img.withOpacity(inst.opacity).composited(over: out)
        }
        return out
    }

    /// The Hue/Saturation settings that give an instance its random colour variation (also used when expanding).
    static func tint(_ inst: RepeaterInstance) -> AdjustmentSettings {
        var a = AdjustmentSettings(kind: .hueSaturation)
        a.hue = inst.hue
        a.lightness = inst.brightness
        return a
    }

    static func bounds(_ layer: Layer, _ g: GroupContent, source: CGRect?) -> CGRect? {
        guard let s = g.repeater, let b = source else { return source }
        var u = b
        for inst in instances(layer.id, s, source: b) where !inst.transform.isIdentity { u = u.union(b.applying(inst.transform)) }
        return u
    }
}

// MARK: - Commands

enum RepeaterActions {
    static func settings(_ l: Layer?) -> RepeaterSettings? {
        guard let l, case .group(let g) = l.content else { return nil }
        return g.repeater
    }

    /// The active layer when it is a repeater, or the repeater that contains it.
    static func activeRepeater(_ d: Document?) -> UUID? {
        guard let d else { return nil }
        var id = d.activeLayerID
        while let i = id, let l = d.state.layer(i) {
            if settings(l) != nil { return i }
            id = d.state.parentID(of: i)
        }
        return nil
    }

    /// Sensible starting values for a source of the given size.
    static func defaults(source b: CGRect, doc d: Document) -> RepeaterSettings {
        var s = RepeaterSettings()
        let side = Double(max(b.width, b.height))
        s.gapX = (Double(b.width) * 0.2).rounded(); s.gapY = (Double(b.height) * 0.2).rounded()
        s.radius = max(60, side * 1.6).rounded()
        s.shapeWidth = max(120, side * 4).rounded(); s.shapeHeight = s.shapeWidth
        s.regionWidth = max(200, side * 5).rounded(); s.regionHeight = s.regionWidth
        s.mirrorGap = (side * 0.1).rounded()
        let c = CGPoint(x: b.midX, y: b.midY)
        // capture the active path or the selection outline so "Along Shape ▸ Active Path" and "Scatter ▸ Selection" work later
        if let pid = d.activePathID, let np = d.state.paths.first(where: { $0.id == pid }), !np.path.isEmpty {
            s.captured = np.path.applying(CGAffineTransform(translationX: -c.x, y: -c.y))
        } else if let sel = d.state.selection {
            s.captured = VectorPath.from(cgPath: LayoutGeom.regionPath(fromMask: sel)).applying(CGAffineTransform(translationX: -c.x, y: -c.y))
            s.capturedEvenOdd = true
        }
        return s
    }

    /// Wraps the layers into a repeater group (no history step). Returns the group id.
    @discardableResult
    static func make(_ d: Document, ids: [UUID], settings: RepeaterSettings) -> UUID? {
        // nested selections: a parent already carries its children
        let set = Set(ids)
        let tops = ids.filter { id in
            var p = d.state.parentID(of: id)
            while let pid = p { if set.contains(pid) { return false }; p = d.state.parentID(of: pid) }
            return true
        }
        guard let top = tops.last else { return nil }
        let placeholder = Layer(name: "__repeater__", content: .group(GroupContent()))
        d.state.insertLayer(placeholder, above: top)
        var children: [Layer] = []
        for id in tops { if var l = d.state.removeLayer(id) { l.isClipped = false; children.append(l) } }
        var g = Layer(name: d.nextLayerName("Repeater"), content: .group(GroupContent(children: children, isExpanded: true, repeater: settings)))
        g.id = placeholder.id
        g.blendMode = .normal
        d.updateLayer(placeholder.id) { $0 = g }
        d.activeLayerID = g.id
        d.selectedLayerIDs = [g.id]
        return g.id
    }

    static func update(_ st: inout DocumentState, _ id: UUID, _ s: RepeaterSettings) {
        st.updateLayer(id) { l in
            guard case .group(var g) = l.content else { return }
            g.repeater = s
            l.content = .group(g)
        }
    }

    /// The real layers an instance expands to (the children transformed, wrapped when they need a tint).
    static func expandedLayers(_ group: Layer, state st: DocumentState) -> [Layer] {
        guard case .group(let g) = group.content, let s = g.repeater,
              let b = RepeaterRenderer.sourceBounds(g, width: st.width, height: st.height) else { return group.children }
        let sp = CanvasSpace(width: st.width, height: st.height)
        let inst = RepeaterLayout.instances(s, source: b)
        var out: [Layer] = []
        for (i, it) in inst.enumerated() {
            if i == 0 { out += g.children; continue }
            guard it.opacity > 0.001 else { continue }
            var copies = g.children.map { $0.duplicated() }
            if !it.transform.isIdentity {
                copies = copies.map { LayoutGeom.transformed($0, it.transform, space: sp, scaleEffects: Double(it.transform.scaleFactor)) }
            }
            let tinted = it.hue != 0 || it.brightness != 0
            if copies.count == 1 && !tinted {
                copies[0].name = "\(g.children[0].name) \(i + 1)"
                copies[0].opacity *= it.opacity
                out.append(copies[0])
            } else {
                if tinted { copies.append(Layer(name: "Variation", content: .adjustment(RepeaterRenderer.tint(it)))) }
                var wrap = Layer(name: "Instance \(i + 1)", content: .group(GroupContent(children: copies, isExpanded: false)))
                wrap.blendMode = .normal          // isolated, so the tint only affects this instance
                wrap.opacity = it.opacity
                out.append(wrap)
            }
        }
        return out
    }

    // MARK: Following transforms

    /// Scale factors (signed: negative = flipped) of an axis-aligned transform; nil when it rotates or skews.
    static func axisScale(_ t: CGAffineTransform) -> (kx: Double, ky: Double)? {
        let tol: CGFloat = 1e-4 * max(1, abs(t.a), abs(t.d))
        guard abs(t.b) < tol, abs(t.c) < tol, abs(t.a) > 1e-6, abs(t.d) > 1e-6 else { return nil }
        return (Double(t.a), Double(t.d))
    }

    /// Makes every repeater in `l` (itself or nested) follow a transform that was applied to `l` as a whole.
    static func follow(_ l: inout Layer, _ t: CGAffineTransform) {
        guard let k = axisScale(t), abs(k.kx - 1) > 1e-6 || abs(k.ky - 1) > 1e-6, case .group(var g) = l.content else { return }
        if var r = g.repeater { r.follow(kx: k.kx, ky: k.ky); g.repeater = r }
        for i in g.children.indices { follow(&g.children[i], t) }
        l.content = .group(g)
    }

    /// How layer `b` (a later version of `a`) was transformed, read off the first descendant that records its transform.
    static func relativeTransform(_ a: Layer, _ b: Layer, _ sa: DocumentState, _ sb: DocumentState) -> CGAffineTransform? {
        switch (a.content, b.content) {
        case (.shape(let x), .shape(let y)):
            guard x.perspective == nil, y.perspective == nil, x.geometry == y.geometry else { return nil }
            return x.transform.inverted().concatenating(y.transform)
        case (.text(let x), .text(let y)):
            return x.transform.inverted().concatenating(y.transform)
        case (.smartObject(let x), .smartObject(let y)):
            guard x.quad.isAffine, y.quad.isAffine else { return nil }
            return LayerTransformer.affineFrom3(x.quad.tl, x.quad.tr, x.quad.bl, y.quad.tl, y.quad.tr, y.quad.bl)
        case (.group(let x), .group(let y)):
            for (p, q) in zip(x.children, y.children) where p.id == q.id {
                if let t = relativeTransform(p, q, sa, sb) { return t }
            }
            return nil
        case (.raster, .raster):
            // pixels carry no transform: assume a plain scale from the change of their bounds
            guard let p = Compositor.shared.contentBounds(a, state: sa), let q = Compositor.shared.contentBounds(b, state: sb), p.width > 0, p.height > 0 else { return nil }
            return LayoutGeom.map(p, to: q)
        default: return nil
        }
    }

    /// Commit hook: when a repeater was scaled or flipped as a whole (Free Transform, Flip, Image Size…) its spacing follows,
    /// so the result is what the transform preview showed. Editing the source itself (a layer inside is selected) leaves the spacing alone.
    static func followTransforms(_ d: Document) {
        let before = d.committedState
        var st = d.state
        var changed = false
        // a document-wide resize (Image Size) always counts as "the whole repeater", whatever is selected
        let resized = before.width != d.state.width || before.height != d.state.height
        for l in d.state.allLayers {
            guard case .group(let g) = l.content, let s = g.repeater, let old = before.layer(l.id), case .group(let og) = old.content,
                  og.repeater == s, og.children.map(\.id) == g.children.map(\.id), !g.children.isEmpty,
                  resized || Set(l.allIDs.dropFirst()).isDisjoint(with: d.selectedLayerIDs),
                  let t = relativeTransform(old, l, before, d.state), let k = axisScale(t),
                  abs(k.kx - 1) > 1e-3 || abs(k.ky - 1) > 1e-3 else { continue }
            var ns = s
            ns.follow(kx: k.kx, ky: k.ky)
            update(&st, l.id, ns)
            changed = true
        }
        if changed { d.state = st }
    }

    /// A copy of the document in which every repeater is an ordinary group of real layers (for formats that know no repeaters).
    static func expandedForExport(_ st: DocumentState) -> DocumentState {
        guard st.allLayers.contains(where: { settings($0) != nil }) else { return st }
        func walk(_ layers: [Layer]) -> [Layer] {
            layers.map { layer in
                guard case .group(var g) = layer.content else { return layer }
                var l = layer
                g.children = walk(g.children)
                l.content = .group(g)
                if g.repeater != nil {
                    l.content = .group(GroupContent(children: expandedLayers(l, state: st), isExpanded: g.isExpanded, artboard: g.artboard))
                }
                return l
            }
        }
        var out = st
        out.layers = walk(st.layers)
        return out
    }

    /// Converts the instances into real, independent layers inside an ordinary group.
    static func expand(_ d: Document, _ id: UUID) {
        guard let l = d.state.layer(id), settings(l) != nil else { return }
        let layers = expandedLayers(l, state: d.state)
        d.updateLayer(id) { g in
            g.content = .group(GroupContent(children: layers, isExpanded: true))
            if g.name.hasPrefix("Repeater") { g.name = g.name.replacingOccurrences(of: "Repeater", with: "Repeated") }
        }
        d.activeLayerID = id
        d.selectedLayerIDs = [id]
        d.commit("Expand Repeater")
    }

    /// Removes the repeater and puts the source layers back where the group was.
    static func release(_ d: Document, _ id: UUID) {
        guard let l = d.state.layer(id), settings(l) != nil else { return }
        let children = l.children
        for c in children { d.state.insertLayer(c, below: id) }
        d.state.removeLayer(id)
        d.selectedLayerIDs = Set(children.map(\.id))
        d.activeLayerID = children.last?.id
        d.commit("Release Repeater")
    }

    static func expandActive() {
        guard let d = AppActions.doc, let id = activeRepeater(d) else { Beep.play(); return }
        expand(d, id)
    }

    static func releaseActive() {
        guard let d = AppActions.doc, let id = activeRepeater(d) else { Beep.play(); return }
        release(d, id)
    }
}
