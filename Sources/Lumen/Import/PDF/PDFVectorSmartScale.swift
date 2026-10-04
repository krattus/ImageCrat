import Foundation
import CoreGraphics
import ImageCratCore

/// Smart objects whose source is a document with vector layers (a placed PDF / Illustrator file, or shape and type
/// layers converted to a smart object): when the object is shown larger than its source, the source is rendered
/// at that size instead of being rendered small and enlarged as pixels.
enum PDFVectorSmartScale {
    static let maxDimension = 8192.0
    static let maxPixels = 48_000_000.0

    private static func hasVector(_ layers: [Layer]) -> Bool {
        layers.contains { l in
            switch l.content {
            case .shape, .text: return l.isVisible
            case .group(let g): return l.isVisible && hasVector(g.children)
            case .smartObject(let so): if case .document(let d) = so.source { return hasVector(d.layers) }; return false
            default: return false
            }
        }
    }

    /// `st` scaled up to the size `quad` shows it at (unchanged when it is not enlarged, not affine, or all pixels).
    static func forDisplay(_ st: DocumentState, quad: Quad) -> DocumentState {
        let w = Double(st.width), h = Double(st.height)
        guard quad.isAffine, w >= 1, h >= 1 else { return st }
        let sx = Double(quad.tl.distance(to: quad.tr)) / w, sy = Double(quad.tl.distance(to: quad.bl)) / h
        var k = max(sx, sy)
        guard k.isFinite, k > 1.05 else { return st }
        k = min(k, maxDimension / max(w, h), (maxPixels / (w * h)).squareRoot())
        guard k > 1.05, hasVector(st.layers) else { return st }
        let space = CanvasSpace(width: st.width, height: st.height)
        let t = Homography(affine: CGAffineTransform(scaleX: CGFloat(k), y: CGFloat(k)))
        var out = st
        out.layers = st.layers.map { LayerTransformer.apply(t, to: $0, space: space, scaleEffects: k, nearest: false, document: true, strokeScale: k) }
        out.width = max(1, Int((w * k).rounded()))
        out.height = max(1, Int((h * k).rounded()))
        out.selection = nil
        return out
    }
}
