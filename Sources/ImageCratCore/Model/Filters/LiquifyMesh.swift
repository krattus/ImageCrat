import Foundation

/// The displacement mesh of a Liquify smart filter, like Photoshop's: Liquify on a smart object is kept as a smart
/// filter, so its result can reach anywhere on the canvas (not just the object's own bounds) and the source stays intact.
///
/// The mesh is the canvas-wide displacement painted in the Liquify dialog (doc pixels, y down; result(p) = source(p + d(p)))
/// sampled on a grid: cell (gx, gy) sits at doc (gx·step, gy·step) of the canvas it was painted on (`width` × `height`).
/// `reference` is where the smart object was when the mesh was painted. When the object is moved, scaled or rotated
/// afterwards, the mesh is carried along by the same (affine) transform, so the effect stays on the object.
package struct LiquifyMesh: Codable, Equatable {
    package var width: Int
    package var height: Int
    package var step: Int
    package var gw: Int
    package var gh: Int
    package var dx: [Float]
    package var dy: [Float]
    package var reference: Quad

    package init(width: Int, height: Int, step: Int, gw: Int, gh: Int, dx: [Float], dy: [Float], reference: Quad) {
        self.width = width; self.height = height; self.step = step; self.gw = gw; self.gh = gh
        self.dx = dx; self.dy = dy; self.reference = reference
    }

    package var isValid: Bool { width > 0 && height > 0 && step > 0 && gw > 0 && gh > 0 && dx.count == gw * gh && dy.count == gw * gh }
    package var isIdentity: Bool { !dx.contains { $0 != 0 } && !dy.contains { $0 != 0 } }

    /// The doc-space transform that carries the mesh from `reference` to where the object is now (`quad`): the affine
    /// map of the reference's top-left / top-right / bottom-left corners onto the current ones. Identity when either
    /// quad is degenerate.
    package func placement(to quad: Quad) -> CGAffineTransform {
        LiquifyMesh.affine(from: reference, to: quad)
    }

    package static func affine(from a: Quad, to b: Quad) -> CGAffineTransform {
        let u = CGPoint(x: a.tr.x - a.tl.x, y: a.tr.y - a.tl.y), v = CGPoint(x: a.bl.x - a.tl.x, y: a.bl.y - a.tl.y)
        let u2 = CGPoint(x: b.tr.x - b.tl.x, y: b.tr.y - b.tl.y), v2 = CGPoint(x: b.bl.x - b.tl.x, y: b.bl.y - b.tl.y)
        let det = u.x * v.y - v.x * u.y
        guard abs(det) > 1e-9 else { return .identity }
        // M maps u → u2 and v → v2 (column vectors): M = [u2 v2] · [u v]⁻¹
        let ia = v.y / det, ib = -u.y / det, ic = -v.x / det, id = u.x / det   // inverse of [u.x v.x; u.y v.y]
        let a11 = u2.x * ia + v2.x * ib, a12 = u2.x * ic + v2.x * id
        let a21 = u2.y * ia + v2.y * ib, a22 = u2.y * ic + v2.y * id
        // CGAffineTransform: x' = a·x + c·y + tx, y' = b·x + d·y + ty
        let tx = b.tl.x - (a11 * a.tl.x + a12 * a.tl.y), ty = b.tl.y - (a21 * a.tl.x + a22 * a.tl.y)
        return CGAffineTransform(a: a11, b: a21, c: a12, d: a22, tx: tx, ty: ty)
    }

    /// Bilinear displacement at a point of the painting canvas (doc pixels); zero outside that canvas, so pixels
    /// beyond it (off-canvas parts of the layer) are never moved.
    package func sample(_ x: Double, _ y: Double) -> (Double, Double) {
        guard isValid, x >= 0, y >= 0, x <= Double(width), y <= Double(height) else { return (0, 0) }
        let fx = min(Double(gw - 1), x / Double(step)), fy = min(Double(gh - 1), y / Double(step))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(gw - 1, x0 + 1), y1 = min(gh - 1, y0 + 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        func at(_ arr: [Float], _ gx: Int, _ gy: Int) -> Double { Double(arr[gy * gw + gx]) }
        func lerp(_ arr: [Float]) -> Double {
            (at(arr, x0, y0) * (1 - tx) + at(arr, x1, y0) * tx) * (1 - ty) + (at(arr, x0, y1) * (1 - tx) + at(arr, x1, y1) * tx) * ty
        }
        return (lerp(dx), lerp(dy))
    }

    /// The displacement this mesh produces at doc point `p` once carried by `placement` (see `placement(to:)`):
    /// d'(p) = L · d(A⁻¹ p), with L the linear part of A.
    package func displacement(at p: CGPoint, placement t: CGAffineTransform) -> (Double, Double) {
        let q = p.applying(t.inverted())
        let (ux, uy) = sample(Double(q.x), Double(q.y))
        return (Double(t.a) * ux + Double(t.c) * uy, Double(t.b) * ux + Double(t.d) * uy)
    }
}
