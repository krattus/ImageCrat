import SwiftUI
import CoreImage
import ImageCratCore

// MARK: - Filter ▸ Adaptive Wide Angle
//
// Content-preserving projection in the spirit of Carroll et al. 2009 ("Optimizing content-preserving projections for
// wide-angle images"): every source pixel is a viewing direction on the sphere (from the lens model); a mesh over the
// source is projected with a shape-preserving base projection (stereographic / Mercator / rectilinear) and then solved
// (sparse least squares) so that user constraint lines — great circles in 3-D — come out straight, optionally level
// or plumb, while the rest of the mesh keeps the base projection's local shape.

enum AWACorrection: String, CaseIterable, Identifiable {
    case auto = "Auto", fisheye = "Fisheye", perspective = "Perspective", fullSpherical = "Full Spherical"
    var id: String { rawValue }
}

struct AWAConstraint: Equatable, Identifiable {
    enum Kind: String { case straight, horizontal, vertical }
    var id = UUID()
    var a: CGPoint      // source doc coordinates
    var b: CGPoint
    var kind: Kind = .straight
}

struct AWASettings: Equatable {
    var correction: AWACorrection = .auto
    var focalLength: Double = 24       // mm (35 mm equivalent when crop factor 1); Auto treats < 18 mm as fisheye
    var cropFactor: Double = 1
    var scale: Double = 100            // %
    var constraints: [AWAConstraint] = []
}

struct AWAModel {
    let size: CGSize
    let s: AWASettings

    enum Lens { case fisheye, rectilinear, equirect }

    var lens: Lens {
        switch s.correction {
        case .fisheye: return .fisheye
        case .perspective: return .rectilinear
        case .fullSpherical: return .equirect
        case .auto:
            if abs(size.width / max(1, size.height) - 2) < 0.08 { return .equirect }
            return s.focalLength * s.cropFactor < 18 ? .fisheye : .rectilinear
        }
    }

    var f: Double { s.focalLength * s.cropFactor * Double(hypot(size.width, size.height)) / 43.27 }
    var c: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }

    func direction(_ p: CGPoint) -> SIMD3<Double> {
        let dx = Double(p.x - c.x), dy = Double(p.y - c.y)
        switch lens {
        case .fisheye:
            let r = (dx * dx + dy * dy).squareRoot()
            if r < 1e-9 { return SIMD3(0, 0, 1) }
            let th = min(r / f, .pi * 0.98)
            return SIMD3(sin(th) * dx / r, sin(th) * dy / r, cos(th))
        case .rectilinear:
            let v = SIMD3(dx, dy, f)
            return v / (v * v).sum().squareRoot()
        case .equirect:
            let lon = (Double(p.x) / Double(size.width) - 0.5) * 2 * .pi, lat = (Double(p.y) / Double(size.height) - 0.5) * .pi
            return SIMD3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
        }
    }

    func sourcePoint(_ d: SIMD3<Double>) -> CGPoint {
        switch lens {
        case .fisheye:
            let th = acos(max(-1, min(1, d.z))), phi = atan2(d.y, d.x)
            return CGPoint(x: c.x + CGFloat(f * th * cos(phi)), y: c.y + CGFloat(f * th * sin(phi)))
        case .rectilinear:
            let z = max(0.05, d.z)
            return CGPoint(x: c.x + CGFloat(f * d.x / z), y: c.y + CGFloat(f * d.y / z))
        case .equirect:
            let lon = atan2(d.x, d.z), lat = asin(max(-1, min(1, d.y)))
            return CGPoint(x: CGFloat((lon / (2 * .pi) + 0.5)) * size.width, y: CGFloat((lat / .pi + 0.5)) * size.height)
        }
    }

    /// Base (shape-preserving) projection of a direction, in output units centred at 0.
    func base(_ d: SIMD3<Double>) -> CGPoint {
        switch lens {
        case .fisheye:
            let th = min(acos(max(-1, min(1, d.z))), 2.6), phi = atan2(d.y, d.x)
            let r = 2 * f * tan(th / 2)
            return CGPoint(x: CGFloat(r * cos(phi)), y: CGFloat(r * sin(phi)))
        case .rectilinear:
            let z = max(0.05, d.z)
            return CGPoint(x: CGFloat(f * d.x / z), y: CGFloat(f * d.y / z))
        case .equirect:
            let lon = atan2(d.x, d.z), lat = max(-1.4, min(1.4, asin(max(-1, min(1, d.y)))))
            return CGPoint(x: CGFloat(f * lon), y: CGFloat(f * log(tan(.pi / 4 + lat / 2))))
        }
    }

    /// Points along the 3-D straight line (great circle) between two source points, in source coordinates.
    func greatCircle(_ a: CGPoint, _ b: CGPoint, samples n: Int = 24) -> [CGPoint] {
        let da = direction(a), db = direction(b)
        let om = acos(max(-1, min(1, (da * db).sum())))
        return (0...n).map { k in
            let t = Double(k) / Double(n)
            if om < 1e-6 { return a.lerp(b, CGFloat(t)) }
            let d = (sin((1 - t) * om) * da + sin(t * om) * db) / sin(om)
            return sourcePoint(d)
        }
    }
}

/// Solved warp: a regular source grid and its output positions (doc coordinates).
struct AWAMesh {
    var cols: Int, rows: Int
    var source: MeshGrid
    var output: MeshGrid

    /// Output position of a source point (bilinear inside the source grid).
    func map(_ p: CGPoint) -> CGPoint {
        MeshWarpData(from: source, to: output).map(p)
    }

    /// Source position of an output point (inverse bilinear in the containing output quad).
    func inverse(_ q: CGPoint) -> CGPoint? {
        for r in 0..<(rows - 1) { for c in 0..<(cols - 1) {
            let p00 = output.point(c, r), p10 = output.point(c + 1, r), p01 = output.point(c, r + 1), p11 = output.point(c + 1, r + 1)
            let path = CGMutablePath(); path.addLines(between: [p00, p10, p11, p01]); path.closeSubpath()
            guard path.contains(q) else { continue }
            // Newton on the bilinear map
            var u: CGFloat = 0.5, v: CGFloat = 0.5
            for _ in 0..<12 {
                let P = p00 * ((1 - u) * (1 - v)) + p10 * (u * (1 - v)) + p01 * ((1 - u) * v) + p11 * (u * v)
                let du = (p10 - p00) * (1 - v) + (p11 - p01) * v, dv = (p01 - p00) * (1 - u) + (p11 - p10) * u
                let det = du.x * dv.y - du.y * dv.x
                if abs(det) < 1e-9 { break }
                let e = q - P
                u += (e.x * dv.y - e.y * dv.x) / det
                v += (du.x * e.y - du.y * e.x) / det
            }
            let s00 = source.point(c, r), s11 = source.point(c + 1, r + 1)
            return CGPoint(x: s00.x + (s11.x - s00.x) * u, y: s00.y + (s11.y - s00.y) * v)
        } }
        return nil
    }
}

enum AWASolver {
    /// Sparse least squares ‖A x − b‖² accumulated as normal equations and solved with Jacobi-preconditioned CG.
    final class LSQ {
        let n: Int
        var ata: [[Int: Double]]
        var atb: [Double]
        init(_ n: Int) { self.n = n; ata = Array(repeating: [:], count: n); atb = Array(repeating: 0, count: n) }
        func add(_ terms: [(Int, Double)], _ rhs: Double, _ w: Double) {
            for (i, a) in terms {
                atb[i] += w * a * rhs
                for (j, b) in terms { ata[i][j, default: 0] += w * a * b }
            }
        }
        func solve(initial x0: [Double], iterations: Int = 800) -> [Double] {
            let rowsIdx = ata.map { Array($0.keys) }, rowsVal = ata.map { Array($0.values) }
            func mul(_ x: [Double]) -> [Double] {
                var y = [Double](repeating: 0, count: n)
                for i in 0..<n { var s = 0.0; let ks = rowsIdx[i], vs = rowsVal[i]; for k in 0..<ks.count { s += vs[k] * x[ks[k]] }; y[i] = s }
                return y
            }
            let diag = (0..<n).map { max(1e-12, ata[$0][$0] ?? 1) }
            var x = x0
            var r = zip(atb, mul(x)).map { $0 - $1 }
            var z = zip(r, diag).map { $0 / $1 }
            var p = z
            var rz = zip(r, z).map(*).reduce(0, +)
            for _ in 0..<iterations {
                let ap = mul(p)
                let pap = zip(p, ap).map(*).reduce(0, +)
                if abs(pap) < 1e-18 { break }
                let alpha = rz / pap
                for i in 0..<n { x[i] += alpha * p[i]; r[i] -= alpha * ap[i] }
                if r.map({ $0 * $0 }).reduce(0, +) < 1e-10 { break }
                z = zip(r, diag).map { $0 / $1 }
                let rz2 = zip(r, z).map(*).reduce(0, +)
                let beta = rz2 / rz
                rz = rz2
                for i in 0..<n { p[i] = z[i] + beta * p[i] }
            }
            return x
        }
    }

    static func solve(_ s: AWASettings, size: CGSize, cols: Int = 48, rows: Int = 32) -> AWAMesh {
        let m = AWAModel(size: size, s: s)
        let src = MeshGrid.regular(CGRect(origin: .zero, size: size), cols: cols, rows: rows)
        let N = cols * rows
        let B = src.positions.map { m.base(m.direction($0)) }
        var X = B.map { Double($0.x) }, Y = B.map { Double($0.y) }
        if !s.constraints.isEmpty {
            let lx = LSQ(N), ly = LSQ(N)
            // shape: keep the base projection's local edge vectors
            let wS = 1.0
            for r in 0..<rows { for c in 0..<cols {
                let i = r * cols + c
                for (dc, dr) in [(1, 0), (0, 1)] where c + dc < cols && r + dr < rows {
                    let j = (r + dr) * cols + (c + dc)
                    lx.add([(i, 1), (j, -1)], Double(B[i].x - B[j].x), wS)
                    ly.add([(i, 1), (j, -1)], Double(B[i].y - B[j].y), wS)
                }
                // weak anchor (fixes the gauge)
                lx.add([(i, 1)], Double(B[i].x), 0.002); ly.add([(i, 1)], Double(B[i].y), 0.002)
            } }
            // bilinear weights of a source point on the grid
            let cw = size.width / CGFloat(cols - 1), ch = size.height / CGFloat(rows - 1)
            func weights(_ p: CGPoint) -> [(Int, Double)] {
                let fx = min(max(Double(p.x / cw), 0), Double(cols - 1) - 1e-6), fy = min(max(Double(p.y / ch), 0), Double(rows - 1) - 1e-6)
                let c0 = Int(fx), r0 = Int(fy), tx = fx - Double(c0), ty = fy - Double(r0)
                return [(r0 * cols + c0, (1 - tx) * (1 - ty)), (r0 * cols + c0 + 1, tx * (1 - ty)),
                        ((r0 + 1) * cols + c0, (1 - tx) * ty), ((r0 + 1) * cols + c0 + 1, tx * ty)]
            }
            func baseAt(_ w: [(Int, Double)]) -> CGPoint { w.reduce(CGPoint.zero) { $0 + B[$1.0] * CGFloat($1.1) } }
            let wL = 60.0
            for con in s.constraints {
                let pts = m.greatCircle(con.a, con.b)
                let ws = pts.map(weights)
                let pa = baseAt(ws.first!), pb = baseAt(ws.last!)
                let chord = pb - pa, len2 = max(1e-9, chord.dot(chord))
                for k in 1..<(ws.count - 1) {
                    let t = Double(max(0, min(1, (baseAt(ws[k]) - pa).dot(chord) / len2)))
                    // P_k − (1−t)·P_a − t·P_b = 0 (per coordinate)
                    var terms = ws[k]
                    terms += ws.first!.map { ($0.0, -(1 - t) * $0.1) }
                    terms += ws.last!.map { ($0.0, -t * $0.1) }
                    lx.add(terms, 0, wL); ly.add(terms, 0, wL)
                }
                if con.kind == .horizontal { ly.add(ws.first! + ws.last!.map { ($0.0, -$0.1) }, 0, wL * 4) }
                if con.kind == .vertical { lx.add(ws.first! + ws.last!.map { ($0.0, -$0.1) }, 0, wL * 4) }
            }
            X = lx.solve(initial: X); Y = ly.solve(initial: Y)
        }
        // fit: fill the canvas (edge midpoints of the base projection reach the canvas edges), then user scale
        let mids = [CGPoint(x: 0, y: size.height / 2), CGPoint(x: size.width, y: size.height / 2), CGPoint(x: size.width / 2, y: 0), CGPoint(x: size.width / 2, y: size.height)]
            .map { m.base(m.direction($0)) }
        let hx = min(abs(mids[0].x), abs(mids[1].x)), hy = min(abs(mids[2].y), abs(mids[3].y))
        let fit = max(size.width / 2 / max(1, hx), size.height / 2 / max(1, hy)) * CGFloat(s.scale / 100)
        let c = m.c
        let out = (0..<N).map { CGPoint(x: c.x + CGFloat(X[$0]) * fit, y: c.y + CGFloat(Y[$0]) * fit) }
        return AWAMesh(cols: cols, rows: rows, source: src, output: MeshGrid(cols: cols, rows: rows, positions: out))
    }

    /// Renders the corrected image (CI space, canvas extent).
    static func render(_ img: CIImage, mesh: AWAMesh, space: CanvasSpace) -> CIImage {
        MeshWarp.warp(img, from: mesh.source, to: mesh.output, space: space).cropped(to: space.ciCanvas)
    }
}

// MARK: - Dialog

final class AWAViewModel: ObservableObject {
    let source: CIImage
    let space: CanvasSpace
    @Published var s = AWASettings()
    @Published var mesh: AWAMesh
    @Published var preview: CGImage?
    @Published var showConstraints = true
    @Published var showMesh = false
    let previewScale: CGFloat

    init?(doc: Document) {
        guard let l = doc.activeLayer, l.isRaster else { return nil }
        let sp = AppActions.space(doc)
        space = sp
        let img = Compositor.shared.contentImage(l, space: sp)?.cropped(to: sp.ciCanvas) ?? CIImage.clearImage.cropped(to: sp.ciCanvas)
        source = RenderEngine.cgImage(img, rect: sp.ciCanvas).map { CIImage(cgImage: $0) } ?? img
        previewScale = min(1, 760 / CGFloat(max(sp.width, sp.height)))
        mesh = AWASolver.solve(AWASettings(), size: CGSize(width: sp.width, height: sp.height))
        update()
    }

    func update() {
        mesh = AWASolver.solve(s, size: CGSize(width: space.width, height: space.height))
        let out = AWASolver.render(source, mesh: mesh, space: space)
        let small = out.transformed(by: CGAffineTransform(scaleX: previewScale, y: previewScale))
        preview = RenderEngine.cgImage(small.composited(over: CIImage.color(RGBA(gray: 0.15), small.extent)), rect: small.extent)
    }
}

final class AWABox: ObservableObject {
    let model: AWAViewModel?
    init() { model = AppActions.doc.flatMap { AWAViewModel(doc: $0) } }
}

struct AdaptiveWideAngleDialog: View {
    @StateObject private var box = AWABox()
    var body: some View {
        if let m = box.model { AdaptiveWideAngleWorkspace(m: m) } else {
            DialogFrame(title: "Adaptive Wide Angle", onOK: {}) { Text("Select a pixel layer first.") }
        }
    }
}

struct AdaptiveWideAngleWorkspace: View {
    @ObservedObject var m: AWAViewModel
    @State private var dragA: CGPoint?       // output (doc) coords
    @State private var dragB: CGPoint?
    @State private var moving: (Int, Bool)?  // constraint index, endpoint a?
    let frame = CGSize(width: 780, height: 520)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Adaptive Wide Angle").font(.system(size: 13, weight: .semibold))
            HStack(alignment: .top, spacing: 12) {
                preview
                side.frame(width: 230)
            }
            HStack {
                Text("Drag along an edge that should be straight · ⇧ makes it horizontal/vertical · drag an end point to adjust · ⌥-click deletes")
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                Spacer()
                Button("Cancel") { AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button("OK") { apply() }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    func fit() -> (CGFloat, CGPoint) {
        let W = CGFloat(m.space.width), H = CGFloat(m.space.height)
        let s = min(frame.width / W, frame.height / H)
        return (s, CGPoint(x: (frame.width - W * s) / 2, y: (frame.height - H * s) / 2))
    }

    var preview: some View {
        let (s, o) = fit()
        let t = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: o.x, ty: o.y)
        return Canvas { ctx, _ in
            if let p = m.preview {
                ctx.draw(Image(decorative: p, scale: 1), in: CGRect(x: o.x, y: o.y, width: CGFloat(m.space.width) * s, height: CGFloat(m.space.height) * s))
            }
            ctx.withCGContext { cg in
                if m.showMesh {
                    cg.setStrokeColor(CGColor(gray: 1, alpha: 0.35)); cg.setLineWidth(0.5)
                    let g = m.mesh.output
                    for r in 0..<g.rows { for c in 0..<g.cols { let p = g.point(c, r).applying(t); if c == 0 { cg.move(to: p) } else { cg.addLine(to: p) } } }
                    for c in 0..<g.cols { for r in 0..<g.rows { let p = g.point(c, r).applying(t); if r == 0 { cg.move(to: p) } else { cg.addLine(to: p) } } }
                    cg.strokePath()
                }
                guard m.showConstraints else { return }
                let model = AWAModel(size: CGSize(width: m.space.width, height: m.space.height), s: m.s)
                for con in m.s.constraints {
                    let pts = model.greatCircle(con.a, con.b, samples: 40).map { m.mesh.map($0).applying(t) }
                    let col: CGColor = con.kind == .straight ? CGColor(red: 0.2, green: 0.8, blue: 1, alpha: 1) : con.kind == .horizontal ? CGColor(red: 1, green: 0.85, blue: 0.1, alpha: 1) : CGColor(red: 1, green: 0.35, blue: 0.9, alpha: 1)
                    cg.setStrokeColor(col); cg.setLineWidth(2); cg.addLines(between: pts); cg.strokePath()
                    for e in [pts.first!, pts.last!] { cg.setFillColor(.white); cg.fillEllipse(in: CGRect(x: e.x - 4, y: e.y - 4, width: 8, height: 8)) }
                }
                if let a = dragA, let b = dragB {
                    cg.setStrokeColor(.white); cg.setLineDash(phase: 0, lengths: [4, 3]); cg.setLineWidth(1)
                    cg.move(to: a.applying(t)); cg.addLine(to: b.applying(t)); cg.strokePath()
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            let p = CGPoint(x: (v.location.x - o.x) / s, y: (v.location.y - o.y) / s)
            if dragA == nil && moving == nil {
                // endpoint hit?
                for (i, con) in m.s.constraints.enumerated() {
                    if m.mesh.map(con.a).distance(to: p) * s < 8 { moving = (i, true) }
                    else if m.mesh.map(con.b).distance(to: p) * s < 8 { moving = (i, false) }
                    if moving != nil { break }
                }
                if NSEvent.modifierFlags.contains(.option) {
                    if let mv = moving { m.s.constraints.remove(at: mv.0); m.update() }
                    moving = (-1, true)
                    return
                }
                if moving == nil { dragA = p }
            }
            if let mv = moving, mv.0 >= 0, let sp = m.mesh.inverse(p) {
                if mv.1 { m.s.constraints[mv.0].a = sp } else { m.s.constraints[mv.0].b = sp }
            }
            dragB = dragA == nil ? nil : p
        }.onEnded { _ in
            if let mv = moving, mv.0 >= 0 { m.update() }
            if let a = dragA, let b = dragB, a.distance(to: b) * s > 6, let sa = m.mesh.inverse(a), let sb = m.mesh.inverse(b) {
                var kind = AWAConstraint.Kind.straight
                if NSEvent.modifierFlags.contains(.shift) { kind = abs(b.x - a.x) >= abs(b.y - a.y) ? .horizontal : .vertical }
                m.s.constraints.append(AWAConstraint(a: sa, b: sb, kind: kind))
                m.update()
            }
            dragA = nil; dragB = nil; moving = nil
        })
    }

    var side: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Correction", selection: Binding(get: { m.s.correction }, set: { m.s.correction = $0; m.update() })) {
                ForEach(AWACorrection.allCases) { Text($0.rawValue).tag($0) }
            }
            ValueSlider(label: "Scale", value: Binding(get: { m.s.scale }, set: { m.s.scale = $0 }), range: 50...150, unit: "%", labelWidth: 76, onCommit: m.update)
            ValueSlider(label: "Focal Length", value: Binding(get: { m.s.focalLength }, set: { m.s.focalLength = $0 }), range: 4...100, step: 0.1, unit: " mm", format: "%.1f", labelWidth: 76, onCommit: m.update)
            ValueSlider(label: "Crop Factor", value: Binding(get: { m.s.cropFactor }, set: { m.s.cropFactor = $0 }), range: 0.5...6, step: 0.01, format: "%.2f", labelWidth: 76, onCommit: m.update)
            Toggle2(label: "Show Constraints", on: $m.showConstraints)
            Toggle2(label: "Show Mesh", on: $m.showMesh)
            Divider()
            Caption("Constraints")
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(m.s.constraints.enumerated()), id: \.element.id) { i, con in
                        HStack {
                            Text("\(i + 1). \(con.kind.rawValue.capitalized)")
                            Spacer()
                            Button { m.s.constraints.remove(at: i); m.update() } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                        }
                    }
                }
            }.frame(maxHeight: 200)
            if !m.s.constraints.isEmpty {
                Button("Remove All") { m.s.constraints = []; m.update() }.buttonStyle(PanelButtonStyle())
            }
            Spacer()
        }
    }

    func apply() {
        let mesh = m.mesh, sp = m.space
        AppModel.shared.dialog = nil
        AppActions.applyToActiveLayer(name: "Adaptive Wide Angle") { AWASolver.render($0, mesh: mesh, space: sp) }
    }
}

enum AdaptiveWideAngleModule {
    static func register() {
        // (no smart-filter version: a smart object, like type or a shape, is rasterized first after asking)
        MenuRegistry.add("Filter", "Adaptive Wide Angle…", key: "a", modifiers: [.command, .option, .shift],
                         enabled: { FilterLauncher.canRun(smartFilter: false, layerPixels: true) }) {
            if FilterLauncher.prepare(smartFilter: false, layerPixels: true) { DialogRegistry.show("edits.awa") }
        }
        DialogRegistry.register("edits.awa") { AnyView(AdaptiveWideAngleDialog()) }
    }
}
