import ImageCratCore
import CoreImage
import Foundation
@testable import LumenUltra

/// Height map of Bevel & Emboss, built from the layer's alpha in 32-bit float on the CPU.
///
/// The shading is the derivative of this map, so the map must be smooth to well below one 8-bit level per pixel. Core
/// Image's own Gaussian and box blurs work on a downsampled pyramid for large radii and are stored in half floats; their
/// bilinearly upsampled, quantised result has a piecewise-constant derivative that shows as concentric terraces and a
/// faint grid in the shading. Here the map comes from a sub-pixel signed distance to the layer's edge (exact Euclidean
/// feature transform + the edge's tangent, see `BevelHeightField`), shaped by the style's band and the technique's
/// profile, then smoothed with a float Gaussian (three box passes).
///
/// Bands (signed distance `s`, positive inside the layer, `size` = Size):
/// - Inner Bevel: `0…size` inside (nothing outside the layer).
/// - Outer Bevel: `size…0` outside.
/// - Emboss / Pillow Emboss: `size/2` either side of the edge.
///
/// Profiles: Chisel Hard is linear in the distance (crisp ridges), Chisel Soft the same slightly softened, Smooth a
/// rounded profile (steepest at the layer's edge, flat at the far end of the band) with its creases rounded.
enum BevelHeightMap {
    struct Params: Equatable {
        var style: BevelStyle
        var technique: BevelTechnique
        var size: Double
        var soften: Double
        /// Profile contour (with its Range applied), nil when off / linear.
        var contour: [Float]?

        /// Standard deviation of the final smoothing (px).
        var sigma: Double {
            let aa = 0.5    // last trace of pixel-level faceting
            let tech: Double
            switch technique {
            case .chiselHard: tech = 0
            case .chiselSoft: tech = 0.5 + size * 0.04
            case .smooth: tech = size * 0.1
            }
            let soft = soften / 2
            return (aa * aa + tech * tech + soft * soft).squareRoot()
        }

        /// How far outside the requested rect the alpha is read (px).
        var margin: Int { Int((size + 3 * sigma + 8).rounded(.up)) }

        /// As Core Image kernel arguments: plain property-list values, so they are part of the image's digest (Core Image
        /// caches intermediates by digest; an opaque object could let a different Size reuse a cached map).
        var arguments: [String: Any] {
            var a: [String: Any] = ["style": BevelStyle.allCases.firstIndex(of: style) ?? 0,
                                    "technique": BevelTechnique.allCases.firstIndex(of: technique) ?? 0,
                                    "size": size, "soften": soften]
            if let c = contour { a["contour"] = c.withUnsafeBufferPointer { Data(buffer: $0) } }
            return a
        }

        init(style: BevelStyle, technique: BevelTechnique, size: Double, soften: Double, contour: [Float]?) {
            self.style = style; self.technique = technique; self.size = size; self.soften = soften; self.contour = contour
        }

        init?(arguments a: [String: Any]?) {
            guard let a, let st = a["style"] as? Int, let te = a["technique"] as? Int, let size = a["size"] as? Double,
                  let soften = a["soften"] as? Double,
                  BevelStyle.allCases.indices.contains(st), BevelTechnique.allCases.indices.contains(te) else { return nil }
            let contour = (a["contour"] as? Data).map { d in d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
            self.init(style: BevelStyle.allCases[st], technique: BevelTechnique.allCases[te], size: size, soften: soften, contour: contour)
        }
    }

    /// Height (0…1 inside the band) of the layer whose opaque gray alpha is `alphaGray` (white = inside), over `work`.
    static func image(alphaGray: CIImage, work: CGRect, params p: Params) -> CIImage {
        let input = alphaGray.cropped(to: work).composited(over: CIImage(color: .black))   // outside the work rect: transparent
        if let out = try? BevelHeightKernel.apply(withExtent: work, inputs: [input], arguments: p.arguments) { return out }
        return CIImage(color: .black).cropped(to: work)
    }

    /// Fills `out` (w × h floats, any row order) from `alpha` (same layout). The work itself runs in the always-optimised
    /// LumenUltra target (`BevelHeightField`): it is a tight per-pixel loop that is ~50× slower unoptimised.
    static func compute(alpha: UnsafePointer<Float>, out: UnsafeMutablePointer<Float>, w: Int, h: Int, params p: Params) {
        let style: Int
        switch p.style {
        case .innerBevel: style = 0
        case .outerBevel: style = 1
        case .emboss, .pillowEmboss: style = 2
        }
        BevelHeightField.compute(alpha: alpha, out: out, w: w, h: h, style: style, smooth: p.technique == .smooth,
                                 size: Float(max(1, p.size)), cap: Float(p.margin), sigma: p.sigma, contour: p.contour)
    }
}

/// Runs `BevelHeightMap.compute` for Core Image: float in, float out, the alpha read `margin` px beyond each tile.
final class BevelHeightKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .Rf }
    override class func formatForInput(at input: Int32) -> CIFormat { .Rf }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        guard let p = BevelHeightMap.Params(arguments: arguments) else { return outputRect }
        let m = CGFloat(p.margin)
        return outputRect.integral.insetBy(dx: -m, dy: -m)
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let p = BevelHeightMap.Params(arguments: arguments) else { return }
        let ir = input.region, or = output.region
        let iw = Int(ir.width.rounded()), ih = Int(ir.height.rounded())
        let ow = Int(or.width.rounded()), oh = Int(or.height.rounded())
        guard iw > 0, ih > 0, ow > 0, oh > 0 else { return }
        // compact copies (rows may be padded)
        let a = UnsafeMutablePointer<Float>.allocate(capacity: iw * ih), hgt = UnsafeMutablePointer<Float>.allocate(capacity: iw * ih)
        defer { a.deallocate(); hgt.deallocate() }
        let ib = input.baseAddress, ibpr = input.bytesPerRow
        for y in 0..<ih {
            let row = (ib + y * ibpr).assumingMemoryBound(to: Float.self)
            (a + y * iw).update(from: row, count: iw)
        }
        BevelHeightMap.compute(alpha: a, out: hgt, w: iw, h: ih, params: p)
        // The input region is the output region grown by the same margin on every side, so the offset is the same
        // whichever way the rows run.
        let dx = Int((or.minX - ir.minX).rounded()), dy = Int((ir.maxY - or.maxY).rounded())
        let ob = output.baseAddress, obpr = output.bytesPerRow
        for y in 0..<oh {
            let dst = (ob + y * obpr).assumingMemoryBound(to: Float.self)
            let sy = min(max(y + dy, 0), ih - 1)
            for x in 0..<ow {
                let sx = min(max(x + dx, 0), iw - 1)
                dst[x] = hgt[sy * iw + sx]
            }
        }
    }
}
