import Foundation
import CoreML
import CoreImage
import Accelerate
import ImageCratCore

/// Image helpers shared by the neural features. CGImages are sRGB, 8-bit, top-left origin.
enum NImg {
    static var ctx: CIContext { RenderEngine.readbackContext }

    /// Renders a CI image (extent origin anywhere) to an 8-bit RGBA CGImage of its extent.
    static func cg(_ img: CIImage, rect: CGRect? = nil) -> CGImage? {
        let r = (rect ?? img.extent).integral
        guard !r.isEmpty, !r.isInfinite else { return nil }
        return ctx.createCGImage(img, from: r, format: .RGBA8, colorSpace: sRGBSpace)
    }

    /// Gray 8-bit CGImage of a CI image's red channel.
    static func grayCG(_ img: CIImage, rect: CGRect? = nil) -> CGImage? {
        let r = (rect ?? img.extent).integral
        let w = Int(r.width), h = Int(r.height)
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h)
        ctx.render(img, toBitmap: &bytes, rowBytes: w, bounds: r, format: .L8, colorSpace: graySpace)
        let prov = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: graySpace,
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func ci(_ cg: CGImage) -> CIImage { CIImage(cgImage: cg) }

    /// Resized copy (Lanczos for downscale, bicubic otherwise).
    static func resized(_ cg: CGImage, _ w: Int, _ h: Int) -> CGImage {
        if cg.width == w && cg.height == h { return cg }
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Fits inside maxSide (keeps aspect). Returns the image unchanged when already small enough.
    static func fitted(_ cg: CGImage, maxSide: Int) -> CGImage {
        let m = max(cg.width, cg.height)
        if m <= maxSide { return cg }
        let s = Double(maxSide) / Double(m)
        return resized(cg, max(1, Int((Double(cg.width) * s).rounded())), max(1, Int((Double(cg.height) * s).rounded())))
    }

    /// Crops (top-left coordinates).
    static func crop(_ cg: CGImage, _ r: CGRect) -> CGImage? { cg.cropping(to: r.integral) }

    /// Unpremultiplied alpha channel (0…1) of an RGBA image, or nil if opaque.
    static func alpha(_ cg: CGImage) -> PlanarImage? {
        if cg.alphaInfo == .none || cg.alphaInfo == .noneSkipLast || cg.alphaInfo == .noneSkipFirst { return nil }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let c = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGBSpace,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var p = PlanarImage(width: w, height: h, channels: 1)
        var opaque = true
        for i in 0..<(w * h) { let a = bytes[i * 4 + 3]; if a != 255 { opaque = false }; p.data[i] = Float(a) / 255 }
        return opaque ? nil : p
    }

    /// Re-applies an alpha channel to an opaque RGB image.
    static func withAlpha(_ cg: CGImage, _ alpha: PlanarImage?) -> CGImage {
        guard let a = alpha else { return cg }
        let aimg = a.cgImage()
        let img = CIImage(cgImage: cg)
        let m = CIImage(cgImage: aimg).transformed(by: CGAffineTransform(scaleX: CGFloat(cg.width) / CGFloat(aimg.width), y: CGFloat(cg.height) / CGFloat(aimg.height)))
        return self.cg(img.masked(byGray: m), rect: img.extent) ?? cg
    }

    /// PSNR (dB) between two same-size images (RGB).
    static func psnr(_ a: CGImage, _ b: CGImage) -> Double {
        let pa = PlanarImage.rgb(a), pb = PlanarImage.rgb(b, width: a.width, height: a.height)
        var mse = 0.0
        for i in pa.data.indices { let d = Double(pa.data[i] - pb.data[i]); mse += d * d }
        mse /= Double(pa.data.count)
        return mse <= 1e-12 ? 99 : 10 * log10(1 / mse)
    }

    /// Mean absolute difference (0…1) between two images (resampled to a's size).
    static func meanDiff(_ a: CGImage, _ b: CGImage) -> Double {
        let pa = PlanarImage.rgb(a, width: min(a.width, 256), height: min(a.height, 256))
        let pb = PlanarImage.rgb(b, width: pa.width, height: pa.height)
        var s = 0.0
        for i in pa.data.indices { s += Double(abs(pa.data[i] - pb.data[i])) }
        return s / Double(pa.data.count)
    }

    static func loadCG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 8192]
        guard let raw = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        // normalise to sRGB RGBA8
        let c = CGContext(data: nil, width: raw.width, height: raw.height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(raw, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
        return c.makeImage()
    }
}

// MARK: - Lab (D65, sRGB companding — matches OpenCV's float conversion)

enum LabMath {
    @inline(__always) static func lin(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4) }
    @inline(__always) static func gam(_ c: Float) -> Float { c <= 0.0031308 ? 12.92 * c : 1.055 * powf(max(0, c), 1 / 2.4) - 0.055 }
    @inline(__always) static func f(_ t: Float) -> Float { t > 0.008856 ? cbrtf(t) : 7.787 * t + 16 / 116 }
    @inline(__always) static func fi(_ t: Float) -> Float { let t3 = t * t * t; return t3 > 0.008856 ? t3 : (t - 16 / 116) / 7.787 }

    static func toLab(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let R = lin(r), G = lin(g), B = lin(b)
        let x = (0.412453 * R + 0.357580 * G + 0.180423 * B) / 0.950456
        let y = 0.212671 * R + 0.715160 * G + 0.072169 * B
        let z = (0.019334 * R + 0.119193 * G + 0.950227 * B) / 1.088754
        let fx = f(x), fy = f(y), fz = f(z)
        return (y > 0.008856 ? 116 * fy - 16 : 903.3 * y, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func toRGB(_ L: Float, _ a: Float, _ b: Float) -> (Float, Float, Float) {
        let fy = (L + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        let x = fi(fx) * 0.950456, y = L > 7.9996 ? fy * fy * fy : L / 903.3, z = fi(fz) * 1.088754
        let R = 3.240479 * x - 1.537150 * y - 0.498535 * z
        let G = -0.969256 * x + 1.875992 * y + 0.041556 * z
        let B = 0.055648 * x - 0.204043 * y + 1.057311 * z
        return (max(0, min(1, gam(R))), max(0, min(1, gam(G))), max(0, min(1, gam(B))))
    }

    /// Planar RGB → planar Lab.
    static func lab(_ p: PlanarImage) -> PlanarImage {
        var o = PlanarImage(width: p.width, height: p.height, channels: 3)
        let n = p.width * p.height
        p.data.withUnsafeBufferPointer { s in
            o.data.withUnsafeMutableBufferPointer { d in
                DispatchQueue.concurrentPerform(iterations: 16) { chunk in
                    let a = chunk * n / 16, e = (chunk + 1) * n / 16
                    for i in a..<e {
                        let (L, A, B) = toLab(s[i], s[n + i], s[2 * n + i])
                        d[i] = L; d[n + i] = A; d[2 * n + i] = B
                    }
                }
            }
        }
        return o
    }

    static func rgb(_ p: PlanarImage) -> PlanarImage {
        var o = PlanarImage(width: p.width, height: p.height, channels: 3)
        let n = p.width * p.height
        p.data.withUnsafeBufferPointer { s in
            o.data.withUnsafeMutableBufferPointer { d in
                DispatchQueue.concurrentPerform(iterations: 16) { chunk in
                    let a = chunk * n / 16, e = (chunk + 1) * n / 16
                    for i in a..<e {
                        let (R, G, B) = toRGB(s[i], s[n + i], s[2 * n + i])
                        d[i] = R; d[n + i] = G; d[2 * n + i] = B
                    }
                }
            }
        }
        return o
    }
}

// MARK: - Tiled inference

enum TiledRunner {
    /// Runs a fixed-size image→image model (tile×tile in, tile*scale out) over `img` with overlapping, feathered tiles.
    /// `predict` gets an RGB planar tile and returns the processed tile. `progress` reports 0…1.
    static func run(_ img: PlanarImage, tile: Int, overlap: Int, scale: Int = 1,
                    progress: ((Double) -> Void)? = nil,
                    predict: (PlanarImage) throws -> PlanarImage) throws -> PlanarImage {
        let W = img.width, H = img.height, C = img.channels
        let step = max(1, tile - overlap)
        func starts(_ n: Int) -> [Int] {
            if n <= tile { return [0] }
            var s: [Int] = []
            var p = 0
            while p + tile < n { s.append(p); p += step }
            s.append(n - tile)
            return s
        }
        let xs = starts(W), ys = starts(H)
        let OW = W * scale, OH = H * scale, OT = tile * scale, OO = overlap * scale
        var acc = [Float](repeating: 0, count: OW * OH * C)
        var wsum = [Float](repeating: 0, count: OW * OH)
        // feather ramp along each axis (1 inside, linear ramp over the overlap at interior edges)
        func ramp(_ i: Int, _ lowEdge: Bool, _ highEdge: Bool) -> Float {
            var w: Float = 1
            if !lowEdge && OO > 0 { w = min(w, Float(i + 1) / Float(OO + 1)) }
            if !highEdge && OO > 0 { w = min(w, Float(OT - i) / Float(OO + 1)) }
            return max(0.001, w)
        }
        let total = xs.count * ys.count
        var done = 0
        for y0 in ys {
            for x0 in xs {
                try Task.checkCancellation()
                let t = img.crop(x0: x0, y0: y0, w: tile, h: tile)
                let out = try predict(t)
                guard out.width == OT, out.height == OT else { throw ModelError.compile("unexpected tile size \(out.width)x\(out.height)") }
                let lowX = x0 == 0, highX = x0 + tile >= W, lowY = y0 == 0, highY = y0 + tile >= H
                let ox = x0 * scale, oy = y0 * scale
                let vw = min(OT, OW - ox), vh = min(OT, OH - oy)
                out.data.withUnsafeBufferPointer { o in
                    acc.withUnsafeMutableBufferPointer { a in
                        wsum.withUnsafeMutableBufferPointer { ws in
                            for yy in 0..<vh {
                                let wy = ramp(yy, lowY, highY)
                                for xx in 0..<vw {
                                    let w = wy * ramp(xx, lowX, highX)
                                    let di = (oy + yy) * OW + ox + xx
                                    ws[di] += w
                                    for c in 0..<C { a[c * OW * OH + di] += o[c * OT * OT + yy * OT + xx] * w }
                                }
                            }
                        }
                    }
                }
                done += 1
                progress?(Double(done) / Double(total))
            }
        }
        var res = PlanarImage(width: OW, height: OH, channels: C)
        let n = OW * OH
        res.data.withUnsafeMutableBufferPointer { r in
            acc.withUnsafeBufferPointer { a in
                wsum.withUnsafeBufferPointer { ws in
                    for i in 0..<n {
                        let inv = ws[i] > 0 ? 1 / ws[i] : 0
                        for c in 0..<C { r[c * n + i] = a[c * n + i] * inv }
                    }
                }
            }
        }
        return res
    }

    /// Convenience: runs a single-input / single-output Core ML model with multi-array I/O over tiles.
    static func runModel(_ model: MLModel, _ img: PlanarImage, tile: Int, overlap: Int, scale: Int,
                         inScale: Float = 1, inBias: Float = 0, outScale: Float = 1, outBias: Float = 0,
                         progress: ((Double) -> Void)? = nil) throws -> PlanarImage {
        guard let inName = model.modelDescription.inputDescriptionsByName.keys.first,
              let inDesc = model.modelDescription.inputDescriptionsByName[inName],
              let outName = model.modelDescription.outputDescriptionsByName.keys.first else { throw ModelError.compile("model I/O") }
        let dt = inDesc.multiArrayConstraint?.dataType ?? .float32
        let opts = MLPredictionOptions()
        return try run(img, tile: tile, overlap: overlap, scale: scale, progress: progress) { t in
            let arr = try NeuralTensor.multiArray(t, dataType: dt == .float16 ? .float16 : .float32, scale: inScale, bias: inBias)
            let fp = try MLDictionaryFeatureProvider(dictionary: [inName: MLFeatureValue(multiArray: arr)])
            let out = try model.prediction(from: fp, options: opts)
            guard let v = out.featureValue(for: outName), let p = NeuralTensor.planar(v, scale: outScale, bias: outBias) else { throw ModelError.compile("no output") }
            return p
        }
    }
}

// MARK: - Gray mask helpers (PlanarImage with 1 channel)

enum MaskMath {
    /// Box blur (separable, radius r) of a single-channel planar image.
    static func boxBlur(_ m: PlanarImage, _ r: Int) -> PlanarImage {
        if r <= 0 { return m }
        let w = m.width, h = m.height
        var tmp = [Float](repeating: 0, count: w * h)
        var out = m
        m.data.withUnsafeBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { t in
                for y in 0..<h {
                    var acc: Float = 0
                    let row = y * w
                    for x in -r...r { acc += s[row + max(0, min(w - 1, x))] }
                    for x in 0..<w {
                        t[row + x] = acc / Float(2 * r + 1)
                        acc += s[row + min(w - 1, x + r + 1)] - s[row + max(0, x - r)]
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { t in
            out.data.withUnsafeMutableBufferPointer { o in
                for x in 0..<w {
                    var acc: Float = 0
                    for y in -r...r { acc += t[max(0, min(h - 1, y)) * w + x] }
                    for y in 0..<h {
                        o[y * w + x] = acc / Float(2 * r + 1)
                        acc += t[min(h - 1, y + r + 1) * w + x] - t[max(0, y - r) * w + x]
                    }
                }
            }
        }
        return out
    }

    /// Dilation (max) with a square of radius r (separable).
    static func dilate(_ m: PlanarImage, _ r: Int) -> PlanarImage { morph(m, r, true) }
    static func erode(_ m: PlanarImage, _ r: Int) -> PlanarImage { morph(m, r, false) }

    private static func morph(_ m: PlanarImage, _ r: Int, _ isMax: Bool) -> PlanarImage {
        if r <= 0 { return m }
        let w = m.width, h = m.height
        var tmp = m.data
        var out = m
        m.data.withUnsafeBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { t in
                for y in 0..<h {
                    for x in 0..<w {
                        var v = s[y * w + x]
                        for k in max(0, x - r)...min(w - 1, x + r) { let q = s[y * w + k]; v = isMax ? max(v, q) : min(v, q) }
                        t[y * w + x] = v
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { t in
            out.data.withUnsafeMutableBufferPointer { o in
                for y in 0..<h {
                    for x in 0..<w {
                        var v = t[y * w + x]
                        for k in max(0, y - r)...min(h - 1, y + r) { let q = t[k * w + x]; v = isMax ? max(v, q) : min(v, q) }
                        o[y * w + x] = v
                    }
                }
            }
        }
        return out
    }

    /// Bounding boxes of connected regions (value > thr), 8-connected, after merging boxes within `mergeDistance`.
    static func regions(_ m: PlanarImage, thr: Float = 0.5, mergeDistance: Int = 0) -> [IRect] {
        let w = m.width, h = m.height
        var label = [Int32](repeating: 0, count: w * h)
        var boxes: [IRect] = []
        var stack: [Int] = []
        var next: Int32 = 1
        for i in 0..<(w * h) where m.data[i] > thr && label[i] == 0 {
            var x0 = w, y0 = h, x1 = 0, y1 = 0
            stack.append(i); label[i] = next
            while let j = stack.popLast() {
                let x = j % w, y = j / w
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                for dy in -1...1 { for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                    let k = ny * w + nx
                    if label[k] == 0 && m.data[k] > thr { label[k] = next; stack.append(k) }
                } }
            }
            boxes.append(IRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1))
            next += 1
        }
        if mergeDistance <= 0 { return boxes }
        var merged = true
        while merged {
            merged = false
            outer: for i in boxes.indices {
                for j in boxes.indices where j > i {
                    let a = boxes[i], b = boxes[j]
                    let g = mergeDistance
                    if a.x - g <= b.x + b.width && b.x - g <= a.x + a.width && a.y - g <= b.y + b.height && b.y - g <= a.y + a.height {
                        let x0 = min(a.x, b.x), y0 = min(a.y, b.y)
                        boxes[i] = IRect(x: x0, y: y0, width: max(a.x + a.width, b.x + b.width) - x0, height: max(a.y + a.height, b.y + b.height) - y0)
                        boxes.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }
        return boxes
    }
}

extension PlanarImage {
    /// Resizes (bilinear via Core Image for speed).
    func resized(_ w: Int, _ h: Int) -> PlanarImage {
        if w == width && h == height { return self }
        let cg = cgImage()
        return channels == 1 ? PlanarImage.gray(cg, width: w, height: h) : PlanarImage.rgb(cg, width: w, height: h)
    }

    /// Float-precision bilinear resize (keeps values outside 0…1, e.g. Lab ab or depth).
    func resizedFloat(_ w: Int, _ h: Int) -> PlanarImage {
        if w == width && h == height { return self }
        var o = PlanarImage(width: w, height: h, channels: channels)
        let sx = Float(width) / Float(w), sy = Float(height) / Float(h)
        data.withUnsafeBufferPointer { s in
            o.data.withUnsafeMutableBufferPointer { d in
                for c in 0..<channels {
                    let sb = c * width * height, db = c * w * h
                    for y in 0..<h {
                        let fy = max(0, min(Float(height - 1), (Float(y) + 0.5) * sy - 0.5))
                        let y0 = Int(fy), y1 = min(height - 1, y0 + 1), ty = fy - Float(y0)
                        for x in 0..<w {
                            let fx = max(0, min(Float(width - 1), (Float(x) + 0.5) * sx - 0.5))
                            let x0 = Int(fx), x1 = min(width - 1, x0 + 1), tx = fx - Float(x0)
                            let a = s[sb + y0 * width + x0] * (1 - tx) + s[sb + y0 * width + x1] * tx
                            let b = s[sb + y1 * width + x0] * (1 - tx) + s[sb + y1 * width + x1] * tx
                            d[db + y * w + x] = a * (1 - ty) + b * ty
                        }
                    }
                }
            }
        }
        return o
    }

    /// 90° clockwise rotation.
    func rotatedCW() -> PlanarImage {
        var o = PlanarImage(width: height, height: width, channels: channels)
        for c in 0..<channels { for y in 0..<o.height { for x in 0..<o.width {
            // o(x, y) = self(y, H-1-x)
            o.data[c * o.width * o.height + y * o.width + x] = data[c * width * height + (height - 1 - x) * width + y]
        } } }
        return o
    }

    /// 90° counter-clockwise rotation (inverse of `rotatedCW`).
    func rotatedCCW() -> PlanarImage {
        var o = PlanarImage(width: height, height: width, channels: channels)
        for c in 0..<channels { for y in 0..<o.height { for x in 0..<o.width {
            // o(x, y) = self(W-1-y, x)
            o.data[c * o.width * o.height + y * o.width + x] = data[c * width * height + x * width + (width - 1 - y)]
        } } }
        return o
    }

    /// Channel as its own planar image.
    func channel(_ c: Int) -> PlanarImage {
        var o = PlanarImage(width: width, height: height, channels: 1)
        let n = width * height
        o.data = Array(data[(c * n)..<((c + 1) * n)])
        return o
    }
}
