import Foundation

// MARK: - Warp styles (Edit ▸ Transform ▸ Warp presets and Warp Text)

package enum WarpStyle: String, Codable, CaseIterable, Identifiable {
    case none, arc, arcLower, arcUpper, arch, bulge, shellLower, shellUpper, flag, wave, fish, rise, fisheye, inflate, squeeze, twist
    @inlinable package var id: String { rawValue }
    @inlinable package var displayName: String {
        switch self {
        case .none: return "None"
        case .arc: return "Arc"
        case .arcLower: return "Arc Lower"
        case .arcUpper: return "Arc Upper"
        case .arch: return "Arch"
        case .bulge: return "Bulge"
        case .shellLower: return "Shell Lower"
        case .shellUpper: return "Shell Upper"
        case .flag: return "Flag"
        case .wave: return "Wave"
        case .fish: return "Fish"
        case .rise: return "Rise"
        case .fisheye: return "Fisheye"
        case .inflate: return "Inflate"
        case .squeeze: return "Squeeze"
        case .twist: return "Twist"
        }
    }

    /// Maps a normalized point (0…1, y down) of the warp box. `bend`, `h`, `v` in -1…1.
    @inlinable package func map(_ u: Double, _ v: Double, bend b: Double, h: Double, vd: Double) -> (Double, Double) {
        var x = u, y = v
        let hump = 4 * u * (1 - u)          // 0 at the sides, 1 in the middle
        switch self {
        case .none: break
        case .arc: y -= b * 0.5 * hump
        case .arcLower: y -= b * 0.5 * hump * v
        case .arcUpper: y -= b * 0.5 * hump * (1 - v)
        case .arch:
            y -= b * 0.5 * hump
            x = 0.5 + (x - 0.5) * (1 + b * 0.25 * (1 - v) - b * 0.1)
        case .bulge: y = 0.5 + (y - 0.5) * (1 + b * 0.6 * hump)
        case .shellLower: y += b * 0.45 * v * (hump - 0.5)
        case .shellUpper: y -= b * 0.45 * (1 - v) * (hump - 0.5)
        case .flag: y += b * 0.12 * sin(2 * .pi * u)
        case .wave: y += b * 0.12 * sin(2 * .pi * u + (v - 0.5) * 1.5)
        case .fish: y = 0.5 + (y - 0.5) * (1 + b * 0.5 * sin(.pi * u)) - b * 0.1 * sin(2 * .pi * u) * (y - 0.5)
        case .rise: y -= b * 0.35 * (u - 0.5) * 2 * (0.5 + 0.5 * hump)
        case .fisheye:
            let dx = u - 0.5, dy = v - 0.5
            let r = sqrt(dx * dx + dy * dy) / 0.7071
            let k = 1 + b * 0.5 * (1 - r * r)
            x = 0.5 + dx * k; y = 0.5 + dy * k
        case .inflate:
            let hv = 4 * v * (1 - v)
            x = 0.5 + (x - 0.5) * (1 + b * 0.35 * hv)
            y = 0.5 + (y - 0.5) * (1 + b * 0.35 * hump)
        case .squeeze:
            let hv = 4 * v * (1 - v)
            x = 0.5 + (x - 0.5) * (1 - b * 0.35 * hv)
            y = 0.5 + (y - 0.5) * (1 + b * 0.35 * hump)
        case .twist:
            let dx = u - 0.5, dy = v - 0.5
            let r = sqrt(dx * dx + dy * dy)
            let a = b * .pi * 0.6 * max(0, 1 - r / 0.7071)
            x = 0.5 + dx * cos(a) - dy * sin(a); y = 0.5 + dx * sin(a) + dy * cos(a)
        }
        // horizontal / vertical perspective distortion
        if h != 0 { y = 0.5 + (y - 0.5) * (1 + h * (x - 0.5) * 1.2) }
        if vd != 0 { x = 0.5 + (x - 0.5) * (1 + vd * (y - 0.5) * 1.2) }
        return (x, y)
    }

    /// Dense destination mesh for a style over `rect`.
    @inlinable package func mesh(_ rect: CGRect, bend: Double, h: Double, v: Double, cols: Int = 40, rows: Int = 40) -> MeshGrid {
        var pts: [CGPoint] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let u = Double(c) / Double(cols - 1), vv = Double(r) / Double(rows - 1)
                let (x, y) = map(u, vv, bend: bend, h: h, vd: v)
                pts.append(CGPoint(x: rect.minX + CGFloat(x) * rect.width, y: rect.minY + CGFloat(y) * rect.height))
            }
        }
        return MeshGrid(cols: cols, rows: rows, positions: pts)
    }
}

/// A non-destructive mesh warp (smart objects): texture at `from` is drawn at `to`. `from` is a regular grid.
package struct MeshWarpData: Codable, Equatable {
    package var from: MeshGrid
    package var to: MeshGrid

    /// Forward-maps a doc point through the warp (bilinear inside the source grid). The source grid is regular but
    /// not necessarily axis-aligned: transforming a warped layer rotates / scales both grids.
    /// `clamped`: points outside the source grid map like its nearest edge (the mesh draws nothing outside itself).
    @inlinable package func map(_ p: CGPoint, clamped: Bool) -> CGPoint {
        guard from.isValid, to.isValid, from.cols == to.cols, from.rows == to.rows else { return p }
        let corners = Quad(tl: from.point(0, 0), tr: from.point(from.cols - 1, 0), br: from.point(from.cols - 1, from.rows - 1), bl: from.point(0, from.rows - 1))
        guard let toUnit = Homography(from: corners, to: Quad(rect: CGRect(x: 0, y: 0, width: 1, height: 1))) else { return p }
        let g = toUnit.apply(p)
        var gu = Double(g.x), gv = Double(g.y)
        guard gu.isFinite, gv.isFinite else { return p }
        if clamped { gu = min(max(gu, 0), 1); gv = min(max(gv, 0), 1) }
        let fu = gu * Double(from.cols - 1)
        let fv = gv * Double(from.rows - 1)
        let c0 = clamp(Int(floor(fu)), 0, from.cols - 2), r0 = clamp(Int(floor(fv)), 0, from.rows - 2)
        let tu = CGFloat(fu - Double(c0)), tv = CGFloat(fv - Double(r0))
        let a = to.point(c0, r0), bb = to.point(c0 + 1, r0), c = to.point(c0, r0 + 1), d = to.point(c0 + 1, r0 + 1)
        let top = a.lerp(bb, tu), bot = c.lerp(d, tu)
        return top.lerp(bot, tv)
    }

    @inlinable package func map(_ p: CGPoint) -> CGPoint { map(p, clamped: false) }

    /// Doc-space bounds of what an object placed on `q` draws after the warp.
    @inlinable package func mappedBounds(of q: Quad) -> CGRect {
        let n = 24
        var pts: [CGPoint] = []
        pts.reserveCapacity((n + 1) * (n + 1))
        for j in 0...n {
            for i in 0...n {
                let u = CGFloat(i) / CGFloat(n), v = CGFloat(j) / CGFloat(n)
                pts.append(map(q.tl.lerp(q.tr, u).lerp(q.bl.lerp(q.br, u), v), clamped: true))
            }
        }
        return CGRect.bounding(pts)
    }

    @inlinable package func mapped(_ f: (CGPoint) -> CGPoint) -> MeshWarpData {
        MeshWarpData(from: MeshGrid(cols: from.cols, rows: from.rows, positions: from.positions.map(f)),
                     to: MeshGrid(cols: to.cols, rows: to.rows, positions: to.positions.map(f)))
    }
    @inlinable package init(from: MeshGrid, to: MeshGrid) {
        self.from = from; self.to = to
    }
}

// MARK: - Mesh grid

/// A regular grid of vertices in document coordinates (top-left origin, y down).
/// `positions[r * cols + c]` for r in 0..<rows, c in 0..<cols (rows, cols >= 2).
package struct MeshGrid: Equatable, Codable {
    package var cols: Int
    package var rows: Int
    package var positions: [CGPoint]

    @inlinable package init(cols: Int, rows: Int, positions: [CGPoint]) {
        self.cols = cols
        self.rows = rows
        self.positions = positions
    }

    /// Evenly spaced grid covering `rect` (corners included).
    @inlinable package static func regular(_ rect: CGRect, cols: Int, rows: Int) -> MeshGrid {
        let c = max(2, cols), r = max(2, rows)
        var pts: [CGPoint] = []
        pts.reserveCapacity(c * r)
        for j in 0..<r {
            let y = rect.minY + rect.height * CGFloat(j) / CGFloat(r - 1)
            for i in 0..<c {
                let x = rect.minX + rect.width * CGFloat(i) / CGFloat(c - 1)
                pts.append(CGPoint(x: x, y: y))
            }
        }
        return MeshGrid(cols: c, rows: r, positions: pts)
    }

    @inlinable package func point(_ c: Int, _ r: Int) -> CGPoint { positions[r * cols + c] }

    @inlinable package var isValid: Bool { cols >= 2 && rows >= 2 && positions.count == cols * rows }

    /// Bounding box of all vertices.
    @inlinable package var bounds: CGRect {
        guard let f = positions.first else { return .null }
        var x0 = f.x, y0 = f.y, x1 = f.x, y1 = f.y
        for p in positions {
            x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y)
        }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Evaluates the smooth surface through the grid at normalized (u,v) in 0...1
    /// (bicubic Catmull-Rom across control points, linear extrapolation at the borders
    /// so a regular grid reproduces an exact affine surface).
    @inlinable package func evaluate(u: Double, v: Double) -> CGPoint {
        guard isValid else { return positions.first ?? .zero }
        let uu = min(max(u, 0), 1), vv = min(max(v, 0), 1)

        let fx = uu * Double(cols - 1)
        let ci = min(max(Int(floor(fx)), 0), cols - 2)
        let tu = fx - Double(ci)

        let fy = vv * Double(rows - 1)
        let ri = min(max(Int(floor(fy)), 0), rows - 2)
        let tv = fy - Double(ri)

        // Control point with linear extrapolation outside the grid (column direction).
        func ctrl(_ c: Int, _ r: Int) -> CGPoint {
            if c < 0 { return point(0, r) * 2 - point(1, r) }
            if c >= cols { return point(cols - 1, r) * 2 - point(cols - 2, r) }
            return point(c, r)
        }
        // Row r evaluated along u.
        func rowValue(_ r: Int) -> CGPoint {
            MeshGrid.catmullRom(ctrl(ci - 1, r), ctrl(ci, r), ctrl(ci + 1, r), ctrl(ci + 2, r), tu)
        }
        var cache: [Int: CGPoint] = [:]
        func rowAt(_ r: Int) -> CGPoint {
            if let p = cache[r] { return p }
            let p: CGPoint
            if r < 0 { p = rowAt(0) * 2 - rowAt(1) }
            else if r >= rows { p = rowAt(rows - 1) * 2 - rowAt(rows - 2) }
            else { p = rowValue(r) }
            cache[r] = p
            return p
        }
        return MeshGrid.catmullRom(rowAt(ri - 1), rowAt(ri), rowAt(ri + 1), rowAt(ri + 2), tv)
    }

    /// Returns a dense grid (e.g. 48×48) sampled from `evaluate` for smooth rendering.
    @inlinable package func densified(cols: Int, rows: Int) -> MeshGrid {
        let c = max(2, cols), r = max(2, rows)
        var pts: [CGPoint] = []
        pts.reserveCapacity(c * r)
        for j in 0..<r {
            let v = Double(j) / Double(r - 1)
            for i in 0..<c {
                pts.append(evaluate(u: Double(i) / Double(c - 1), v: v))
            }
        }
        return MeshGrid(cols: c, rows: r, positions: pts)
    }

    private static func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: Double) -> CGPoint {
        let t2 = t * t, t3 = t2 * t
        func f(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            let a = Double(a), b = Double(b), c = Double(c), d = Double(d)
            return CGFloat(0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (3 * b - a - 3 * c + d) * t3))
        }
        return CGPoint(x: f(p0.x, p1.x, p2.x, p3.x), y: f(p0.y, p1.y, p2.y, p3.y))
    }
}
