import Foundation
import CoreImage
import CoreVideo
import Accelerate
import ImageCratCore

/// An image to segment: an opaque CI image in canvas CI space (extent 0,0,W,H, y-up), plus its doc size.
/// Doc coordinates (y-down, top-left origin) are used for every prompt and result rectangle.
struct SegImage {
    let image: CIImage
    let width: Int
    let height: Int
    /// Stable identifier for caching (content fingerprint when built from a buffer).
    let id: String

    var canvas: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
    var space: CanvasSpace { CanvasSpace(width: width, height: height) }
    var docBounds: CGRect { canvas }

    /// From a canvas-size RGBA PixelBuffer (premultiplied); transparent areas are shown over white.
    init(buffer: PixelBuffer, id: String? = nil) {
        width = buffer.width; height = buffer.height
        let c = CGRect(x: 0, y: 0, width: buffer.width, height: buffer.height)
        image = CIImage(cgImage: buffer.makeCGImage()).composited(over: CIImage(color: .white).cropped(to: c)).cropped(to: c)
        self.id = id ?? SegImage.fingerprint(image, width: buffer.width, height: buffer.height)
    }

    init(image: CIImage, width: Int, height: Int, id: String? = nil) {
        self.width = width; self.height = height
        let c = CGRect(x: 0, y: 0, width: width, height: height)
        self.image = image.composited(over: CIImage(color: .white).cropped(to: c)).cropped(to: c)
        self.id = id ?? SegImage.fingerprint(self.image, width: width, height: height)
    }

    /// Doc rect (y-down) → CI rect (y-up).
    func ciRect(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height) }

    /// Renders the doc-space region `rect` stretched to `w`×`h` into a BGRA pixel buffer (model input).
    func pixelBuffer(rect: CGRect, w: Int, h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess, let out = pb else { return nil }
        let cr = ciRect(rect)
        let t = CGAffineTransform(translationX: -cr.minX, y: -cr.minY)
            .concatenating(CGAffineTransform(scaleX: CGFloat(w) / cr.width, y: CGFloat(h) / cr.height))
        let img = image.clampedToExtent().cropped(to: cr).transformed(by: t, highQualityDownsample: true)
        SegImage.ctx.render(img, to: out, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: sRGBSpace)
        return out
    }

    /// RGB bytes (RGBA8, row 0 = top) of a doc region stretched to w×h.
    func rgba(rect: CGRect, w: Int, h: Int) -> [UInt8] {
        let cr = ciRect(rect)
        let t = CGAffineTransform(translationX: -cr.minX, y: -cr.minY)
            .concatenating(CGAffineTransform(scaleX: CGFloat(w) / cr.width, y: CGFloat(h) / cr.height))
        let img = image.clampedToExtent().cropped(to: cr).transformed(by: t, highQualityDownsample: true)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        SegImage.ctx.render(img, toBitmap: &bytes, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: sRGBSpace)
        return bytes
    }

    /// Context without extra color management (sRGB in, sRGB out).
    static let ctx: CIContext = CIContext(mtlDevice: RenderEngine.device, options: [
        .workingColorSpace: sRGBSpace, .outputColorSpace: sRGBSpace, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false,
    ])

    /// Cheap content fingerprint: hash of a 128×128 rendition.
    static func fingerprint(_ img: CIImage, width: Int, height: Int) -> String {
        let n = 128
        let t = CGAffineTransform(scaleX: CGFloat(n) / CGFloat(width), y: CGFloat(n) / CGFloat(height))
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        ctx.render(img.transformed(by: t, highQualityDownsample: true), toBitmap: &bytes, rowBytes: n * 4, bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBA8, colorSpace: sRGBSpace)
        var h = Hasher()
        h.combine(width); h.combine(height)
        bytes.withUnsafeBytes { h.combine(bytes: $0) }
        return String(h.finalize(), radix: 36)
    }
}

// MARK: - Mask helpers (low-res logits ↔ full-res masks)

enum SegMask {
    /// Soft threshold of logits: m = clamp(logit·gain + 0.5). Output is multiplied by the input alpha: Core Image may
    /// evaluate color kernels outside their DOD on clear pixels, so clear must map to clear.
    static let sigmoidKernel = CIColorKernel(source: """
    kernel vec4 segSig(__sample s, float g) { float m = clamp(s.r * g + 0.5, 0.0, 1.0); return vec4(m, m, m, 1.0) * s.a; }
    """)
    static let thresholdKernel = CIColorKernel(source: """
    kernel vec4 segThr(__sample s, float t) { float m = s.r > t ? 1.0 : 0.0; return vec4(m, m, m, 1.0) * s.a; }
    """)

    /// A w×h float image of `values` (row 0 = top), extent (0,0,w,h) in CI space.
    static func floatImage(_ values: [Float], w: Int, h: Int) -> CIImage {
        // Like CGImage-backed images, the first bitmap row is the top of the image.
        let data = values.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: w * 4, size: CGSize(width: w, height: h), format: .Rf, colorSpace: nil)
    }

    /// Places a low-res logit map covering doc rect `rect` onto the canvas (bilinear upsample), CI space.
    static func placedLogits(_ logits: [Float], w: Int, h: Int, rect: CGRect, canvasW: Int, canvasH: Int) -> CIImage {
        let img = floatImage(logits, w: w, h: h)
        let ci = CGRect(x: rect.minX, y: CGFloat(canvasH) - rect.maxY, width: rect.width, height: rect.height)
        let t = CGAffineTransform(scaleX: rect.width / CGFloat(w), y: rect.height / CGFloat(h))
            .concatenating(CGAffineTransform(translationX: ci.minX, y: ci.minY))
        return img.clampedToExtent().transformed(by: t).cropped(to: ci)
    }

    /// Full-resolution gray mask (CI, canvas extent) from low-res logits.
    /// `guide` enables edge-aware refinement (guided filter inside an edge band); `hard` gives a binary edge.
    static func fullMask(_ logits: [Float], w: Int, h: Int, rect: CGRect, canvasW: Int, canvasH: Int, guide: CIImage?, hard: Bool) -> CIImage {
        let canvas = CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
        let placed = placedLogits(logits, w: w, h: h, rect: rect, canvasW: canvasW, canvasH: canvasH)
        let black = CIImage(color: .black).cropped(to: canvas)
        let scale = max(rect.width / CGFloat(w), rect.height / CGFloat(h))
        if hard {
            let m = thresholdKernel!.apply(extent: placed.extent, arguments: [placed, Float(0)])!.cropped(to: placed.extent)
            return m.composited(over: black).cropped(to: canvas)
        }
        // Logit slope per full-res pixel shrinks with the upscale factor; keep the soft edge ≈ 1–2 px wide.
        let gain = Float(max(0.5, min(4, scale / 3)))
        var m = sigmoidKernel!.apply(extent: placed.extent, arguments: [placed, gain])!.cropped(to: placed.extent).composited(over: black).cropped(to: canvas)
        if let g = guide {
            m = refineEdges(m, guide: g, canvas: canvas, radius: Double(max(2, min(12, scale * 0.8))))
        }
        return m
    }

    /// Edge-aware refinement: guided filter with the image, applied only inside a band around the edge.
    static func refineEdges(_ mask: CIImage, guide: CIImage, canvas: CGRect, radius r: Double, epsilon: Double = 0.0008) -> CIImage {
        let guided = mask.applyingFilter("CIGuidedFilter", parameters: [
            "inputGuideImage": guide.cropped(to: canvas), kCIInputRadiusKey: r, "inputEpsilon": epsilon,
        ]).cropped(to: canvas)
        let dil = mask.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: r]).cropped(to: canvas)
        let ero = mask.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r]).cropped(to: canvas)
        let band = dil.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: ero]).cropped(to: canvas)
            .clampedToExtent().applyingGaussianBlur(sigma: max(1, r / 3)).cropped(to: canvas)
        // keep the guided result within the dilated region (no halos far outside)
        let clamped = guided.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: dil]).cropped(to: canvas)
        return clamped.mixed(with: mask, mask: band).cropped(to: canvas)
    }

    /// Renders a CI gray mask to a canvas-size gray PixelBuffer.
    static func buffer(_ m: CIImage, width: Int, height: Int) -> PixelBuffer {
        let sp = CanvasSpace(width: width, height: height)
        let out = RenderEngine.renderBuffer(m.cropped(to: sp.ciCanvas), docRect: IRect(x: 0, y: 0, width: width, height: height), space: sp, format: .gray)
        out.markDirty()
        return out
    }

    // MARK: Low-res statistics (vDSP)

    /// Number of values > t.
    static func count(_ v: [Float], above t: Float) -> Int {
        var thr = t, one: Float = 1
        var tmp = [Float](repeating: 0, count: v.count)
        vDSP_vthrsc(v, 1, &thr, &one, &tmp, 1, vDSP_Length(v.count))   // ±1
        var s: Float = 0
        vDSP_sve(tmp, 1, &s, vDSP_Length(v.count))
        // vthrsc maps x >= t to +1 and x < t to -1
        return Int(((s + Float(v.count)) / 2).rounded())
    }

    /// 0/1 map of values > 0.
    static func binary(_ v: [Float]) -> [Float] {
        var thr: Float = 0.0000001, one: Float = 0.5
        var tmp = [Float](repeating: 0, count: v.count)
        vDSP_vthrsc(v, 1, &thr, &one, &tmp, 1, vDSP_Length(v.count))   // ±0.5
        var half: Float = 0.5
        vDSP_vsadd(tmp, 1, &half, &tmp, 1, vDSP_Length(v.count))
        return tmp
    }

    /// Bounding box (low-res pixel coords, y-down) of values > 0.
    static func bbox(_ bin: [Float], w: Int, h: Int) -> CGRect? {
        var rows = [Float](repeating: 0, count: h), cols = [Float](repeating: 0, count: w)
        bin.withUnsafeBufferPointer { p in
            for y in 0..<h { vDSP_sve(p.baseAddress! + y * w, 1, &rows[y], vDSP_Length(w)) }
            for x in 0..<w { vDSP_sve(p.baseAddress! + x, w, &cols[x], vDSP_Length(h)) }
        }
        guard let y0 = rows.firstIndex(where: { $0 > 0 }), let y1 = rows.lastIndex(where: { $0 > 0 }),
              let x0 = cols.firstIndex(where: { $0 > 0 }), let x1 = cols.lastIndex(where: { $0 > 0 }) else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(min(a.count, b.count)))
        return r
    }

    static func sum(_ a: [Float]) -> Float {
        var r: Float = 0
        vDSP_sve(a, 1, &r, vDSP_Length(a.count))
        return r
    }

    /// Mask IoU of two 0/1 maps.
    static func iou(_ a: [Float], _ b: [Float], areaA: Float? = nil, areaB: Float? = nil) -> Float {
        let i = dot(a, b)
        let u = (areaA ?? sum(a)) + (areaB ?? sum(b)) - i
        return u > 0 ? i / u : 0
    }

    // MARK: PixelBuffer helpers

    /// Bounding box of a gray mask (threshold) in doc coords.
    static func bounds(_ m: PixelBuffer, threshold: UInt8 = 127) -> CGRect? {
        m.opaqueBounds(threshold: threshold)?.cgRect
    }

    /// Downsampled float copy (0…1) of a gray PixelBuffer.
    static func floats(_ m: PixelBuffer, w: Int, h: Int) -> [Float] {
        let img = m.ciImage
        let t = CGAffineTransform(scaleX: CGFloat(w) / CGFloat(m.width), y: CGFloat(h) / CGFloat(m.height))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        SegImage.ctx.render(img.transformed(by: t, highQualityDownsample: true), toBitmap: &bytes, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: nil)
        var out = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { out[i] = Float(bytes[i * 4]) / 255 }
        return out
    }

    /// Area (in pixels, alpha-weighted) of a gray PixelBuffer.
    static func area(_ m: PixelBuffer) -> Double {
        let p = m.data.assumingMemoryBound(to: UInt8.self)
        var s = 0
        for y in 0..<m.height {
            let row = p + y * m.bytesPerRow
            for x in 0..<m.width { s += Int(row[x]) }
        }
        return Double(s) / 255
    }

    /// Union of gray masks (max).
    static func union(_ masks: [PixelBuffer]) -> PixelBuffer? {
        guard var acc = masks.first?.copy() else { return nil }
        for m in masks.dropFirst() { acc = SelectionOps.combine(acc, m, mode: .add) }
        acc.markDirty()
        return acc
    }
}
