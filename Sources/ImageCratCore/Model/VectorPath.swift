import Foundation

/// A bezier anchor. Control points are absolute doc coordinates.
package struct PathPoint: Codable, Equatable {
    package var anchor: CGPoint
    package var inControl: CGPoint
    package var outControl: CGPoint
    package var isSmooth: Bool

    package init(_ p: CGPoint) {
        anchor = p; inControl = p; outControl = p; isSmooth = false
    }
    package init(anchor: CGPoint, inControl: CGPoint, outControl: CGPoint, isSmooth: Bool = true) {
        self.anchor = anchor; self.inControl = inControl; self.outControl = outControl; self.isSmooth = isSmooth
    }

    package var hasHandles: Bool { inControl != anchor || outControl != anchor }

    package func mapped(_ f: (CGPoint) -> CGPoint) -> PathPoint {
        PathPoint(anchor: f(anchor), inControl: f(inControl), outControl: f(outControl), isSmooth: isSmooth)
    }
}

package enum PathOperation: String, Codable, CaseIterable {
    case combine, subtract, intersect, exclude
}

package struct Subpath: Codable, Equatable {
    package var points: [PathPoint] = []
    package var closed = false
    package var operation: PathOperation = .combine

    package init(points: [PathPoint] = [], closed: Bool = false, operation: PathOperation = .combine) {
        self.points = points; self.closed = closed; self.operation = operation
    }
}

package struct VectorPath: Codable, Equatable {
    package var subpaths: [Subpath] = []

    package var isEmpty: Bool { subpaths.allSatisfy { $0.points.isEmpty } }

    package func mapped(_ f: (CGPoint) -> CGPoint) -> VectorPath {
        VectorPath(subpaths: subpaths.map { s in
            Subpath(points: s.points.map { $0.mapped(f) }, closed: s.closed, operation: s.operation)
        })
    }

    package func applying(_ t: CGAffineTransform) -> VectorPath { mapped { $0.applying(t) } }

    // MARK: Constructors

    package static func rect(_ r: CGRect, radius: Double = 0) -> VectorPath {
        let rad = min(CGFloat(radius), min(r.width, r.height) / 2)
        if rad <= 0.01 {
            return VectorPath(subpaths: [Subpath(points: r.corners.map { PathPoint($0) }, closed: true)])
        }
        let k: CGFloat = 0.5523 * rad
        var pts: [PathPoint] = []
        // Top edge left->right starting at top-left arc end
        let tl = CGPoint(x: r.minX, y: r.minY), tr = CGPoint(x: r.maxX, y: r.minY)
        let br = CGPoint(x: r.maxX, y: r.maxY), bl = CGPoint(x: r.minX, y: r.maxY)
        pts.append(PathPoint(anchor: CGPoint(x: tl.x + rad, y: tl.y), inControl: CGPoint(x: tl.x + rad - k, y: tl.y), outControl: CGPoint(x: tl.x + rad, y: tl.y)))
        pts.append(PathPoint(anchor: CGPoint(x: tr.x - rad, y: tr.y), inControl: CGPoint(x: tr.x - rad, y: tr.y), outControl: CGPoint(x: tr.x - rad + k, y: tr.y)))
        pts.append(PathPoint(anchor: CGPoint(x: tr.x, y: tr.y + rad), inControl: CGPoint(x: tr.x, y: tr.y + rad - k), outControl: CGPoint(x: tr.x, y: tr.y + rad)))
        pts.append(PathPoint(anchor: CGPoint(x: br.x, y: br.y - rad), inControl: CGPoint(x: br.x, y: br.y - rad), outControl: CGPoint(x: br.x, y: br.y - rad + k)))
        pts.append(PathPoint(anchor: CGPoint(x: br.x - rad, y: br.y), inControl: CGPoint(x: br.x - rad + k, y: br.y), outControl: CGPoint(x: br.x - rad, y: br.y)))
        pts.append(PathPoint(anchor: CGPoint(x: bl.x + rad, y: bl.y), inControl: CGPoint(x: bl.x + rad, y: bl.y), outControl: CGPoint(x: bl.x + rad - k, y: bl.y)))
        pts.append(PathPoint(anchor: CGPoint(x: bl.x, y: bl.y - rad), inControl: CGPoint(x: bl.x, y: bl.y - rad + k), outControl: CGPoint(x: bl.x, y: bl.y - rad)))
        pts.append(PathPoint(anchor: CGPoint(x: tl.x, y: tl.y + rad), inControl: CGPoint(x: tl.x, y: tl.y + rad), outControl: CGPoint(x: tl.x, y: tl.y + rad - k)))
        return VectorPath(subpaths: [Subpath(points: pts, closed: true)])
    }

    package static func ellipse(_ r: CGRect) -> VectorPath {
        let k: CGFloat = 0.5523
        let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
        let pts = [
            PathPoint(anchor: CGPoint(x: cx, y: cy - ry), inControl: CGPoint(x: cx - rx * k, y: cy - ry), outControl: CGPoint(x: cx + rx * k, y: cy - ry)),
            PathPoint(anchor: CGPoint(x: cx + rx, y: cy), inControl: CGPoint(x: cx + rx, y: cy - ry * k), outControl: CGPoint(x: cx + rx, y: cy + ry * k)),
            PathPoint(anchor: CGPoint(x: cx, y: cy + ry), inControl: CGPoint(x: cx + rx * k, y: cy + ry), outControl: CGPoint(x: cx - rx * k, y: cy + ry)),
            PathPoint(anchor: CGPoint(x: cx - rx, y: cy), inControl: CGPoint(x: cx - rx, y: cy + ry * k), outControl: CGPoint(x: cx - rx, y: cy - ry * k)),
        ]
        return VectorPath(subpaths: [Subpath(points: pts, closed: true)])
    }

    package static func polygon(in r: CGRect, sides: Int, starRatio: Double, rotation: Double = 0, smoothCorners: Bool = false) -> VectorPath {
        let n = max(3, sides)
        let c = r.center
        let rx = r.width / 2, ry = r.height / 2
        var pts: [PathPoint] = []
        let isStar = starRatio < 0.999
        let count = isStar ? n * 2 : n
        for i in 0..<count {
            let a = -Double.pi / 2 + rotation * .pi / 180 + Double(i) * 2 * .pi / Double(count)
            let scale = isStar && i % 2 == 1 ? starRatio : 1
            pts.append(PathPoint(CGPoint(x: c.x + rx * CGFloat(cos(a) * scale), y: c.y + ry * CGFloat(sin(a) * scale))))
        }
        return VectorPath(subpaths: [Subpath(points: pts, closed: true)])
    }

    package static func line(from a: CGPoint, to b: CGPoint, weight: Double, arrowStart: Bool = false, arrowEnd: Bool = false) -> VectorPath {
        let d = (b - a).normalized
        let n = CGPoint(x: -d.y, y: d.x) * CGFloat(weight / 2)
        var pts: [PathPoint] = []
        let aw = CGFloat(weight * 3), al = CGFloat(weight * 4)
        if arrowStart {
            let base = a + d * al
            pts += [PathPoint(a), PathPoint(base + CGPoint(x: -d.y, y: d.x) * aw), PathPoint(base + n)]
        } else {
            pts += [PathPoint(a + n)]
        }
        if arrowEnd {
            let base = b - d * al
            pts += [PathPoint(base + n), PathPoint(base + CGPoint(x: -d.y, y: d.x) * aw), PathPoint(b), PathPoint(base - CGPoint(x: -d.y, y: d.x) * aw), PathPoint(base - n)]
        } else {
            pts += [PathPoint(b + n), PathPoint(b - n)]
        }
        if arrowStart {
            let base = a + d * al
            pts += [PathPoint(base - n), PathPoint(base - CGPoint(x: -d.y, y: d.x) * aw)]
        } else {
            pts += [PathPoint(a - n)]
        }
        return VectorPath(subpaths: [Subpath(points: pts, closed: true)])
    }

    package init(subpaths: [Subpath] = []) {
        self.subpaths = subpaths
    }
}

package struct NamedPath: Codable, Identifiable, Equatable {
    package var id = UUID()
    package var name: String
    package var path: VectorPath
    package init(id: UUID = UUID(), name: String, path: VectorPath) {
        self.id = id; self.name = name; self.path = path
    }
}

package struct Guide: Codable, Identifiable, Equatable {
    package var id = UUID()
    package var isVertical: Bool
    package var position: Double
    package init(id: UUID = UUID(), isVertical: Bool, position: Double) {
        self.id = id; self.isVertical = isVertical; self.position = position
    }
}

/// Builds a `VectorPath` from path elements (move / line / quad / cubic / close), exactly as `VectorPath.from(cgPath:)`
/// converts a CGPath. Platform path types feed their elements through this.
package struct VectorPathBuilder {
    private var result = VectorPath()
    private var current = Subpath()

    package init() {}

    package mutating func move(to p: CGPoint) {
        if !current.points.isEmpty { result.subpaths.append(current) }
        current = Subpath(points: [PathPoint(p)])
    }

    package mutating func addLine(to p: CGPoint) {
        current.points.append(PathPoint(p))
    }

    package mutating func addQuadCurve(to e: CGPoint, control c: CGPoint) {
        guard var last = current.points.popLast() else { return }
        let c1 = last.anchor + (c - last.anchor) * (2.0 / 3.0)
        let c2 = e + (c - e) * (2.0 / 3.0)
        last.outControl = c1
        current.points.append(last)
        var np = PathPoint(e); np.inControl = c2
        current.points.append(np)
    }

    package mutating func addCurve(to e: CGPoint, control1: CGPoint, control2: CGPoint) {
        guard var last = current.points.popLast() else { return }
        last.outControl = control1
        current.points.append(last)
        var np = PathPoint(e); np.inControl = control2
        current.points.append(np)
    }

    package mutating func closeSubpath() {
        if current.points.count > 1, let f = current.points.first, let l = current.points.last, f.anchor.distance(to: l.anchor) < 0.001 {
            var first = current.points.removeFirst()
            first.inControl = l.inControl
            current.points.removeLast()
            current.points.insert(first, at: 0)
        }
        current.closed = true
        result.subpaths.append(current)
        current = Subpath()
    }

    /// The finished path (an open trailing subpath is kept).
    package var path: VectorPath {
        var r = result
        if !current.points.isEmpty { r.subpaths.append(current) }
        return r
    }
}
