import Foundation
import CoreGraphics
import CoreText
import AppKit
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

/// Gray float map (0…1) covering the whole canvas at reduced resolution (emission / collision / depth maps).
struct PMap {
    let w: Int, h: Int
    var data: [Float]

    init(w: Int, h: Int, fill: Float = 0) {
        self.w = max(1, w); self.h = max(1, h)
        data = [Float](repeating: fill, count: self.w * self.h)
    }

    /// Downsamples a canvas-size gray (or RGBA → alpha / luminance) buffer.
    init(buffer: PixelBuffer, maxDim: Int = 512, useAlpha: Bool = false) {
        let gray = buffer.format == .gray ? buffer : buffer.toGray(useAlpha: useAlpha)
        let s = min(1, Double(maxDim) / Double(max(gray.width, gray.height)))
        let W = max(1, Int((Double(gray.width) * s).rounded())), H = max(1, Int((Double(gray.height) * s).rounded()))
        self.init(w: W, h: H)
        var bytes = [UInt8](repeating: 0, count: W * H)
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W, space: graySpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(gray.makeCGImage(), in: CGRect(x: 0, y: 0, width: W, height: H))
        }
        for i in 0..<(W * H) { data[i] = Float(bytes[i]) / 255 }
    }

    init?(pngBase64: String) {
        guard let d = Data(base64Encoded: pngBase64), let src = CGImageSourceCreateWithData(d as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let W = img.width, H = img.height
        self.init(w: W, h: H)
        var bytes = [UInt8](repeating: 0, count: W * H)
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W, space: graySpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        }
        for i in 0..<(W * H) { data[i] = Float(bytes[i]) / 255 }
    }

    func pngBase64(maxDim: Int = 256) -> String? {
        let s = min(1, Double(maxDim) / Double(max(w, h)))
        let W = max(1, Int(Double(w) * s)), H = max(1, Int(Double(h) * s))
        var bytes = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { bytes[i] = UInt8(max(0, min(255, (data[i] * 255).rounded()))) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: graySpace, bitmapInfo: CGBitmapInfo(rawValue: 0),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: graySpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        guard let small = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, small, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data).base64EncodedString()
    }

    /// Bilinear sample at normalized canvas coordinates.
    @inline(__always) func sample(_ u: Double, _ v: Double) -> Double {
        let fx = min(max(u * Double(w) - 0.5, 0), Double(w - 1)), fy = min(max(v * Double(h) - 0.5, 0), Double(h - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(w - 1, x0 + 1), y1 = min(h - 1, y0 + 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        return data.withUnsafeBufferPointer { d in
            let a = Double(d[y0 * w + x0]), b = Double(d[y0 * w + x1]), c = Double(d[y1 * w + x0]), e = Double(d[y1 * w + x1])
            return (a + (b - a) * tx) * (1 - ty) + (c + (e - c) * tx) * ty
        }
    }

    /// Gradient (per normalized unit) at normalized coordinates.
    func gradient(_ u: Double, _ v: Double) -> (Double, Double) {
        let du = 1.5 / Double(w), dv = 1.5 / Double(h)
        return ((sample(u + du, v) - sample(u - du, v)) / (2 * du), (sample(u, v + dv) - sample(u, v - dv)) / (2 * dv))
    }

    /// Edge strength (gradient magnitude) map.
    var edges: PMap {
        var e = PMap(w: w, h: h)
        for y in 0..<h {
            for x in 0..<w {
                let l = data[y * w + max(0, x - 1)], r = data[y * w + min(w - 1, x + 1)]
                let t = data[max(0, y - 1) * w + x], b = data[min(h - 1, y + 1) * w + x]
                e.data[y * w + x] = min(1, sqrt((r - l) * (r - l) + (b - t) * (b - t)) * 1.5)
            }
        }
        return e
    }

    var isEmpty: Bool { !data.contains { $0 > 0.02 } }

    /// Gray canvas-size buffer (for masks / previews).
    func buffer(width: Int, height: Int) -> PixelBuffer {
        var bytes = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { bytes[i] = UInt8(max(0, min(255, (data[i] * 255).rounded()))) }
        let out = PixelBuffer(width: width, height: height, format: .gray)
        if let provider = CGDataProvider(data: Data(bytes) as CFData),
           let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: graySpace, bitmapInfo: CGBitmapInfo(rawValue: 0),
                             provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            out.drawImage(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            out.markDirty()
        }
        return out
    }
}

/// Canvas-space colour map (premultiplied RGBA bytes) used to colour particles from the source layer.
struct PColorMap {
    let w: Int, h: Int
    var data: [UInt8]

    init?(cgImage img: CGImage, maxDim: Int = 1024) {
        let s = min(1, Double(maxDim) / Double(max(img.width, img.height)))
        w = max(1, Int((Double(img.width) * s).rounded())); h = max(1, Int((Double(img.height) * s).rounded()))
        data = [UInt8](repeating: 0, count: w * h * 4)
        let W = w, H = h
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: sRGBSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        if !ok { return nil }
    }

    init?(pngBase64: String) {
        guard let d = Data(base64Encoded: pngBase64), let src = CGImageSourceCreateWithData(d as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        self.init(cgImage: img, maxDim: 4096)
    }

    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: sRGBSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    func pngBase64(maxDim: Int = 512) -> String? {
        guard let img = cgImage else { return nil }
        let s = min(1, Double(maxDim) / Double(max(w, h)))
        let W = max(1, Int(Double(w) * s)), H = max(1, Int(Double(h) * s))
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        guard let small = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, small, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data).base64EncodedString()
    }

    /// Un-premultiplied colour at normalized canvas coordinates.
    @inline(__always) func sample(_ u: Double, _ v: Double) -> (Double, Double, Double, Double) {
        let x = min(w - 1, max(0, Int(u * Double(w)))), y = min(h - 1, max(0, Int(v * Double(h))))
        return data.withUnsafeBufferPointer { d in
            let i = (y * w + x) * 4
            let a = Double(d[i + 3]) / 255
            if a <= 0.004 { return (0, 0, 0, 0) }
            return (min(1, Double(d[i]) / 255 / a), min(1, Double(d[i + 1]) / 255 / a), min(1, Double(d[i + 2]) / 255 / a), a)
        }
    }
}

/// Everything a simulation can sample from the document (captured once when the editor opens).
final class ParticleContext {
    let width: Int
    let height: Int
    var selection: PMap?
    var layerAlpha: PMap?
    var layerColor: PColorMap?
    var brightness: PMap?
    /// Relative depth of the scene (0 far … 1 near), when a depth model is installed.
    var depth: PMap?

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }

    /// Length unit: the canvas' short side is 1000 units.
    var unit: Double { Double(min(width, height)) / 1000 }

    /// Captures selection, active layer and composite of a document (main thread).
    static func capture(_ d: Document, layerID: UUID?) -> ParticleContext {
        let st = d.state
        let ctx = ParticleContext(width: st.width, height: st.height)
        let sp = CanvasSpace(width: st.width, height: st.height)
        if let sel = st.selection { ctx.selection = PMap(buffer: sel) }
        if let id = layerID ?? d.activeLayerID, let l = st.layer(id), !l.isAdjustment,
           let content = Compositor.shared.contentImage(l, space: sp),
           let cg = RenderEngine.cgImage(content.cropped(to: sp.ciCanvas).composited(over: CIImage.clearImage.cropped(to: sp.ciCanvas)), rect: sp.ciCanvas) {
            ctx.layerColor = PColorMap(cgImage: cg)
            let buf = PixelBuffer(cgImage: cg)
            let alpha = PMap(buffer: buf, useAlpha: true)
            if !alpha.isEmpty { ctx.layerAlpha = alpha }
        }
        if let cg = Compositor.shared.flatten(st, background: .black) {
            ctx.brightness = PMap(buffer: PixelBuffer(cgImage: cg))
        }
        return ctx
    }

    /// Context from baked data only (smart objects whose source layer / selection no longer exists).
    func applyBaked(_ e: ParticleEffect) {
        if layerColor == nil, let png = e.imagePNG { layerColor = PColorMap(pngBase64: png) }
    }
}

// MARK: - Emitter samplers

/// Samples positions proportionally to a weight map.
final class PAreaSampler {
    let map: PMap
    private var cdf: [Float]
    let total: Double

    init?(_ m: PMap, threshold: Float = 0.03) {
        map = m
        cdf = [Float](repeating: 0, count: m.w * m.h)
        var acc: Double = 0
        for i in 0..<(m.w * m.h) {
            let v = m.data[i]
            if v > threshold { acc += Double(v) }
            cdf[i] = Float(acc)
        }
        total = acc
        if acc <= 0 { return nil }
    }

    /// Normalized canvas position for three uniform randoms.
    func sample(_ r0: Double, _ r1: Double, _ r2: Double) -> (Double, Double) {
        let target = Float(r0 * total)
        var lo = 0, hi = cdf.count - 1
        cdf.withUnsafeBufferPointer { c in
            while lo < hi {
                let mid = (lo + hi) / 2
                if c[mid] > target { hi = mid } else { lo = mid + 1 }
            }
        }
        let x = lo % map.w, y = lo / map.w
        return ((Double(x) + r1) / Double(map.w), (Double(y) + r2) / Double(map.h))
    }
}

/// Polyline sampled uniformly by arc length (pixel coordinates).
final class PPathSampler {
    let pts: [CGPoint]
    private var cum: [Double] = [0]
    let length: Double
    let closed: Bool

    init?(_ points: [CGPoint], closed: Bool) {
        var p = points
        if closed, let f = p.first, p.count > 2 { p.append(f) }
        guard p.count >= 2 else { return nil }
        pts = p
        self.closed = closed
        var acc = 0.0
        for i in 1..<p.count { acc += Double(p[i].distance(to: p[i - 1])); cum.append(acc) }
        length = acc
        if acc <= 0 { return nil }
    }

    /// Position and unit tangent at parameter t (0…1; wraps when closed, clamps otherwise).
    func at(_ t0: Double) -> (x: Double, y: Double, tx: Double, ty: Double) {
        var t = t0
        if closed { t -= floor(t) } else { t = min(1, max(0, t)) }
        let target = t * length
        var lo = 1, hi = cum.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cum[mid] >= target { hi = mid } else { lo = mid + 1 }
        }
        let a = pts[lo - 1], b = pts[lo]
        let segLen = max(1e-9, cum[lo] - cum[lo - 1])
        let f = (target - cum[lo - 1]) / segLen
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        return (Double(a.x) + dx * f, Double(a.y) + dy * f, dx / segLen, dy / segLen)
    }
}

enum ParticleMaps {
    /// Text rendered as a canvas-space coverage map, centred on `pos` and fitted to `size` (fractions of the canvas).
    static func text(_ s: String, font: String, pos: CGPoint, size: CGSize, rotation: Double, canvas: CGSize, maxDim: Int = 512) -> PMap {
        let sc = min(1, Double(maxDim) / Double(max(canvas.width, canvas.height)))
        let W = max(1, Int(Double(canvas.width) * sc)), H = max(1, Int(Double(canvas.height) * sc))
        var m = PMap(w: W, h: H)
        var bytes = [UInt8](repeating: 0, count: W * H)
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W, space: graySpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            let f = CTFontCreateWithName((font.isEmpty ? "Helvetica-Bold" : font) as CFString, 200, nil)
            let attr = NSAttributedString(string: s.isEmpty ? " " : s, attributes: [.font: f as Any, .foregroundColor: NSColor.white])
            let line = CTLineCreateWithAttributedString(attr)
            var b = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            if b.isNull || b.isEmpty { b = CGRect(x: 0, y: 0, width: 1, height: 1) }
            let tw = Double(size.width) * Double(W), th = Double(size.height) * Double(H)
            let k = min(tw / Double(b.width), th / Double(b.height))
            ctx.translateBy(x: CGFloat(Double(pos.x) * Double(W)), y: CGFloat((1 - Double(pos.y)) * Double(H)))
            ctx.rotate(by: CGFloat(rotation * .pi / 180))
            ctx.scaleBy(x: CGFloat(k), y: CGFloat(k))
            ctx.textPosition = CGPoint(x: -b.midX, y: -b.midY)
            CTLineDraw(line, ctx)
        }
        for i in 0..<(W * H) { m.data[i] = Float(bytes[i]) / 255 }
        return m
    }

    /// Flattens a CGPath into polyline points.
    static func flatten(_ path: CGPath, step: CGFloat = 4) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        var cur: [CGPoint] = []
        var last = CGPoint.zero, start = CGPoint.zero
        func curve(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint) {
            let est = p0.distance(to: c1) + c1.distance(to: c2) + c2.distance(to: p1)
            let n = max(2, min(200, Int(est / step)))
            for i in 1...n {
                let t = CGFloat(i) / CGFloat(n), mt = 1 - t
                let x = mt * mt * mt * p0.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * p1.x
                let y = mt * mt * mt * p0.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * p1.y
                cur.append(CGPoint(x: x, y: y))
            }
        }
        path.applyWithBlock { el in
            let p = el.pointee.points
            switch el.pointee.type {
            case .moveToPoint:
                if cur.count > 1 { out.append(cur) }
                cur = [p[0]]; last = p[0]; start = p[0]
            case .addLineToPoint:
                cur.append(p[0]); last = p[0]
            case .addQuadCurveToPoint:
                let c1 = CGPoint(x: last.x + 2 / 3 * (p[0].x - last.x), y: last.y + 2 / 3 * (p[0].y - last.y))
                let c2 = CGPoint(x: p[1].x + 2 / 3 * (p[0].x - p[1].x), y: p[1].y + 2 / 3 * (p[0].y - p[1].y))
                curve(last, c1, c2, p[1]); last = p[1]
            case .addCurveToPoint:
                curve(last, p[0], p[1], p[2]); last = p[2]
            case .closeSubpath:
                cur.append(start); last = start
            @unknown default: break
            }
        }
        if cur.count > 1 { out.append(cur) }
        return out
    }
}
