import Foundation
import CoreGraphics
import ImageCratCore

extension Subpath {
    func appendTo(_ p: CGMutablePath) {
        guard let first = points.first else { return }
        p.move(to: first.anchor)
        for i in 1..<max(1, points.count) where points.count > 1 {
            let a = points[i - 1], b = points[i]
            addSegment(p, a, b)
        }
        if closed && points.count > 1 {
            addSegment(p, points[points.count - 1], first)
            p.closeSubpath()
        }
    }
    fileprivate func addSegment(_ p: CGMutablePath, _ a: PathPoint, _ b: PathPoint) {
        if a.outControl == a.anchor && b.inControl == b.anchor {
            p.addLine(to: b.anchor)
        } else {
            p.addCurve(to: b.anchor, control1: a.outControl, control2: b.inControl)
        }
    }
    var cgPath: CGPath {
        let p = CGMutablePath()
        appendTo(p)
        return p
    }
}

extension VectorPath {
    var cgPath: CGPath {
        let p = CGMutablePath()
        for s in subpaths { s.appendTo(p) }
        return p
    }
    var bounds: CGRect {
        let b = cgPath.boundingBoxOfPath
        return b.isNull ? .zero : b
    }
    /// Converts a CGPath (e.g. glyph outlines) into a VectorPath.
    static func from(cgPath: CGPath) -> VectorPath {
        var b = VectorPathBuilder()
        cgPath.applyWithBlock { elPtr in
            let el = elPtr.pointee
            switch el.type {
            case .moveToPoint: b.move(to: el.points[0])
            case .addLineToPoint: b.addLine(to: el.points[0])
            case .addQuadCurveToPoint: b.addQuadCurve(to: el.points[1], control: el.points[0])
            case .addCurveToPoint: b.addCurve(to: el.points[2], control1: el.points[0], control2: el.points[1])
            case .closeSubpath: b.closeSubpath()
            @unknown default: break
            }
        }
        return b.path
    }
}
