import AppKit
import CoreGraphics
import ImageCratCore

/// Brush tip masks (gray, white = paint).
enum BrushTips {
    private static var textureCache: [String: CGImage] = [:]
    private static var dabCache: [String: CGImage] = [:]
    private static var dabCacheOrder: [String] = []

    static let textured = ["chalk", "charcoal", "bristle", "grass", "star"]

    /// Procedural 128px gray tip textures.
    static func texture(_ id: String) -> CGImage? {
        if let c = textureCache[id] { return c }
        if let custom = AppModel.shared.customBrushTips[id] ?? BrushLibrary.shared.tipBuffer(id) {
            let img = custom.makeCGImage()
            textureCache[id] = img
            return img
        }
        let n = 128
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: graySpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        var rng = SeededRandom(seed: UInt64(abs(id.hashValue) % 100000 + 7))
        let c = CGFloat(n) / 2
        switch id {
        case "chalk":
            for _ in 0..<900 {
                let a = rng.next() * 2 * .pi, r = sqrt(rng.next()) * 60
                let g = 0.5 + rng.next() * 0.5
                ctx.setFillColor(gray: CGFloat(g), alpha: 1)
                let s = CGFloat(1 + rng.next() * 3)
                ctx.fillEllipse(in: CGRect(x: c + CGFloat(cos(a) * r) - s / 2, y: c + CGFloat(sin(a) * r) - s / 2, width: s, height: s))
            }
        case "charcoal":
            for _ in 0..<500 {
                let x = CGFloat(rng.next()) * 110 + 9, y = CGFloat(rng.next()) * 110 + 9
                let d = CGPoint(x: x - c, y: y - c).length
                if d > 60 { continue }
                ctx.setFillColor(gray: CGFloat(0.4 + rng.next() * 0.6), alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: CGFloat(1 + rng.next() * 4), height: CGFloat(1 + rng.next() * 2)))
            }
        case "bristle":
            for _ in 0..<40 {
                let x = CGFloat(rng.next()) * 100 + 14
                let w = CGFloat(1 + rng.next() * 3)
                ctx.setFillColor(gray: CGFloat(0.5 + rng.next() * 0.5), alpha: 1)
                ctx.fill(CGRect(x: x, y: 20 + CGFloat(rng.next()) * 20, width: w, height: 60 + CGFloat(rng.next()) * 30))
            }
        case "grass":
            ctx.setStrokeColor(gray: 1, alpha: 1)
            for _ in 0..<9 {
                let x0 = c + CGFloat(rng.next() - 0.5) * 40
                let h = CGFloat(60 + rng.next() * 60)
                let bend = CGFloat(rng.next() - 0.5) * 50
                ctx.setLineWidth(CGFloat(2 + rng.next() * 4))
                ctx.move(to: CGPoint(x: x0, y: 4))
                ctx.addQuadCurve(to: CGPoint(x: x0 + bend, y: 4 + h), control: CGPoint(x: x0, y: 4 + h * 0.6))
                ctx.strokePath()
            }
        case "star":
            let p = VectorPath.polygon(in: CGRect(x: 4, y: 4, width: 120, height: 120), sides: 5, starRatio: 0.45).cgPath
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.addPath(p)
            ctx.fillPath()
        default:
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: n, height: n))
        }
        let img = ctx.makeImage()
        textureCache[id] = img
        return img
    }

    /// Gray dab mask.
    static func mask(diameter d: Double, hardness: Double, roundness: Double, angle: Double, tipID: String, aliased: Bool = false) -> CGImage? {
        let q = max(1, (d * 4).rounded() / 4)
        let key = "\(q)|\(Int(hardness * 100))|\(Int(roundness * 100))|\(Int(angle))|\(tipID)|\(aliased)"
        if let c = dabCache[key] { return c }
        let side = Int(ceil(q)) + 2
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: graySpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let c = CGFloat(side) / 2
        ctx.translateBy(x: c, y: c)
        ctx.rotate(by: CGFloat(angle * .pi / 180))
        ctx.scaleBy(x: 1, y: CGFloat(max(0.02, roundness)))
        let r = CGFloat(q) / 2
        if tipID != "round", let tex = texture(tipID) {
            ctx.interpolationQuality = .high
            ctx.draw(tex, in: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
        } else if aliased || q <= 1.01 {
            ctx.setShouldAntialias(!aliased)
            ctx.setFillColor(gray: 1, alpha: 1)
            if q <= 1.01 { ctx.fill(CGRect(x: -0.5, y: -0.5, width: 1, height: 1)) } else { ctx.fillEllipse(in: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)) }
        } else if hardness >= 0.99 {
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
        } else {
            // soft profile: flat core then smooth falloff
            let h = max(0, min(0.99, hardness))
            var comps: [CGFloat] = []
            var locs: [CGFloat] = []
            let steps = 16
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                var v: Double
                if t <= h { v = 1 } else {
                    let u = (t - h) / (1 - h)
                    v = 1 - u * u * (3 - 2 * u)
                    v = pow(v, 1.2)
                }
                comps += [CGFloat(v), 1]
                locs.append(CGFloat(t))
            }
            let grad = CGGradient(colorSpace: graySpace, colorComponents: comps, locations: locs, count: locs.count)!
            ctx.drawRadialGradient(grad, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r, options: [])
        }
        let img = ctx.makeImage()
        dabCache[key] = img
        dabCacheOrder.append(key)
        if dabCacheOrder.count > 400 {
            let k = dabCacheOrder.removeFirst()
            dabCache.removeValue(forKey: k)
        }
        return img
    }

    /// Colored RGBA dab.
    static func colored(_ mask: CGImage, color: RGBA) -> CGImage? {
        let w = mask.width, h = mask.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h), mask: mask)
        ctx.setFillColor(color.withAlpha(1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func invalidateTexture(_ id: String) {
        textureCache.removeValue(forKey: id)
        TipSource.invalidate(id)
        dabCache.removeAll(); dabCacheOrder.removeAll()
    }
}

struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}

// MARK: - Stroke interpolation

/// Places dabs along a path with spacing, smoothing and jitter.
struct DabPlacer {
    var spacing: Double
    var smoothing: Double
    private var last: CGPoint?
    private var lastPressure: Double = 1
    private var residual: Double = 0
    private var smoothed: CGPoint?

    init(spacing: Double, smoothing: Double) {
        self.spacing = max(0.5, spacing)
        self.smoothing = smoothing
    }

    mutating func begin(_ p: CGPoint, pressure: Double) -> [(CGPoint, Double)] {
        last = p; smoothed = p; lastPressure = pressure; residual = 0
        return [(p, pressure)]
    }

    mutating func move(_ raw: CGPoint, pressure: Double, final: Bool = false) -> [(CGPoint, Double)] {
        guard let l = last, let s0 = smoothed else { return begin(raw, pressure: pressure) }
        let k = final ? 0 : clamp(smoothing, 0, 0.95)
        let s = s0.lerp(raw, 1 - k)
        smoothed = s
        let d = l.distance(to: s)
        var out: [(CGPoint, Double)] = []
        var t = spacing - residual
        while t <= d {
            let f = t / d
            out.append((l.lerp(s, CGFloat(f)), lastPressure + (pressure - lastPressure) * f))
            t += spacing
        }
        residual = d - (t - spacing)
        if d > 0 { last = s; lastPressure = pressure }
        return out
    }
}

// MARK: - Paint stroke session

/// Accumulates dabs in a stroke buffer and composites them onto the working layer buffer.
final class PaintStroke {
    let doc: Document
    let layerID: UUID
    let target: EditTarget
    let working: PixelBuffer
    let origin: IPoint
    let base: PixelBuffer
    let strokeBuf: PixelBuffer
    let selectionMask: CGImage?
    let canvasRectInBuffer: CGRect
    var opacity: Double
    var blend: CGBlendMode
    /// Transparency lock with a non-Normal mode: alpha is restored from the base after compositing.
    private(set) var lockAlpha = false
    private(set) var dirty = IRect.zero
    private(set) var totalDirty = IRect.zero
    /// Brush dynamics engine whose stroke-level pass (dual brush, texture, wet edges, noise) runs on flush.
    var dynamics: BrushDynamicsEngine?
    /// Post-processed stroke (only allocated when the dynamics need a stroke-level pass).
    private var outBuf: PixelBuffer?
    /// The stroke pixels that get composited onto the layer.
    var outputBuffer: PixelBuffer { outBuf ?? strokeBuf }

    init?(doc: Document, layerID: UUID, target: EditTarget, opacity: Double, blend: CGBlendMode) {
        guard let (w, o) = doc.beginPixelEdit(layerID: layerID, target: target) else { return nil }
        self.doc = doc
        self.layerID = layerID
        self.target = target
        self.working = w
        self.origin = o
        self.base = w.copy()
        self.strokeBuf = PixelBuffer(width: w.width, height: w.height)
        self.opacity = opacity
        var b = blend
        var lock = false
        if target == .content, let l = doc.state.layer(layerID), l.locks.transparency {
            lock = true
            b = b == .destinationOut ? .destinationOut : (b == .normal ? .sourceAtop : b)
        }
        self.blend = b
        self.lockAlpha = lock
        self.selectionMask = target == .quickMask ? nil : doc.state.selection?.makeCGImage()   // (Quick Mask: the selection is the target)
        self.canvasRectInBuffer = CGRect(x: -o.x, y: -o.y, width: doc.state.width, height: doc.state.height)
    }

    func toBuffer(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - CGFloat(origin.x), y: p.y - CGFloat(origin.y)) }

    /// Adds a region written directly into `strokeBuf` (software rasterizer).
    func addDirty(_ r: IRect) { dirty = dirty.union(r) }

    /// Draws a colored dab image centered at doc point.
    func dab(_ img: CGImage, at p: CGPoint, alpha: Double, snap: Bool = false) {
        var c = toBuffer(p)
        if snap { c = CGPoint(x: floor(c.x) + 0.5, y: floor(c.y) + 0.5) }
        let w = CGFloat(img.width), h = CGFloat(img.height)
        var r = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        if snap { r.origin = CGPoint(x: round(r.minX), y: round(r.minY)) }
        strokeBuf.drawImage(img, in: r, alpha: CGFloat(alpha), interpolation: snap ? .none : .high)
        let ir = IRect(enclosing: r)
        dirty = dirty.union(ir)
    }

    /// Draws arbitrary source pixels through a dab mask (clone stamp / history brush).
    func maskedDab(mask: CGImage, at p: CGPoint, source: PixelBuffer, sourceOrigin: IPoint, offset: CGPoint, alpha: Double) {
        let c = toBuffer(p)
        let w = CGFloat(mask.width), h = CGFloat(mask.height)
        let r = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        // Region of source in its own buffer coords
        let srcDocRect = CGRect(x: r.minX + CGFloat(origin.x) + offset.x, y: r.minY + CGFloat(origin.y) + offset.y, width: w, height: h)
        let srcBufRect = IRect(enclosing: srcDocRect.offsetBy(dx: -CGFloat(sourceOrigin.x), dy: -CGFloat(sourceOrigin.y)))
        guard let sub = source.unsafeImage(rect: srcBufRect) else { return }
        let clipped = srcBufRect.intersection(source.bounds)
        let dstRect = CGRect(x: CGFloat(clipped.x + sourceOrigin.x - origin.x) - offset.x, y: CGFloat(clipped.y + sourceOrigin.y - origin.y) - offset.y,
                             width: CGFloat(clipped.width), height: CGFloat(clipped.height))
        let ctx = strokeBuf.context
        ctx.saveGState()
        strokeBuf.clip(toMask: mask, in: r)
        strokeBuf.drawImage(sub, in: dstRect, alpha: CGFloat(alpha))
        ctx.restoreGState()
        dirty = dirty.union(IRect(enclosing: r))
    }

    /// Uses a GPU preview (only the stroke region is uploaded) instead of recompositing the whole layer each dab.
    var livePreview: Bool { target == .content }
    private var applied = false
    private var previewBlend: BlendMode = .normal

    /// Sets the blend mode used for the live preview (matches the CG blend used at the end).
    func setPreviewBlend(_ m: BlendMode) { previewBlend = m }

    /// Composites the stroke onto the working buffer over the dirty area (or updates the live preview).
    func flush() {
        if let dy = dynamics { dirty = dirty.union(dy.takeDirty()) }
        if dirty.isEmpty { return }            // nothing new (an empty rect inset by -1 is not empty)
        var r = dirty.insetBy(-1).intersection(working.bounds)
        dirty = .zero
        if r.isEmpty { return }
        if let dy = dynamics, dy.needsPost {
            if outBuf == nil { outBuf = PixelBuffer(width: strokeBuf.width, height: strokeBuf.height) }
            r = dy.postProcess(r, source: strokeBuf, out: outBuf!)
        }
        totalDirty = totalDirty.union(r)
        if livePreview && !applied {            // once the stroke is baked, a preview would be drawn on top of it forever
            updatePreview()
            return
        }
        composite(r)
    }

    private func composite(_ r: IRect) {
        working.copyPixels(from: base, rect: r)
        guard let img = outputBuffer.unsafeImage(rect: r) else { return }
        let ctx = working.context
        ctx.saveGState()
        ctx.clip(to: r.cgRect)
        if let m = selectionMask { working.clip(toMask: m, in: canvasRectInBuffer) }
        working.drawImage(img, in: r.cgRect, alpha: CGFloat(opacity), blend: blend)
        ctx.restoreGState()
        if lockAlpha && blend != .sourceAtop && blend != .destinationOut { restoreAlpha(r) }
        working.markDirty(r)
        doc.setNeedsRender()
    }

    private func restoreAlpha(_ r: IRect) {
        let w = working.data.assumingMemoryBound(to: UInt8.self)
        let b = base.data.assumingMemoryBound(to: UInt8.self)
        for y in r.minY..<r.maxY {
            for x in r.minX..<r.maxX {
                let i = y * working.bytesPerRow + x * 4
                let ba = b[i + 3], na = w[i + 3]
                if ba == na { continue }
                if ba == 0 || na == 0 { w[i] = 0; w[i + 1] = 0; w[i + 2] = 0; w[i + 3] = ba == 0 ? 0 : 0; continue }
                let k = Double(ba) / Double(na)
                w[i] = UInt8(min(Double(ba), Double(w[i]) * k))
                w[i + 1] = UInt8(min(Double(ba), Double(w[i + 1]) * k))
                w[i + 2] = UInt8(min(Double(ba), Double(w[i + 2]) * k))
                w[i + 3] = ba
            }
        }
    }

    private func updatePreview() {
        let r = totalDirty
        guard !r.isEmpty else { return }
        let sub = outputBuffer.cropped(to: r)   // small copy of the stroke region
        let space = CanvasSpace(width: doc.state.width, height: doc.state.height)
        var stroke = space.place(sub, at: IPoint(x: r.x + origin.x, y: r.y + origin.y)).withOpacity(opacity)
        if let sel = doc.state.selection {
            stroke = stroke.masked(byGray: sel.ciImage.composited(over: CIImage.color(.black, stroke.extent.union(space.ciCanvas))))
        }
        let mode = blend
        let pb = previewBlend
        doc.contentOverrides[layerID] = { img in
            switch mode {
            case .destinationOut:
                return img.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: stroke])
            case .sourceAtop:
                return stroke.applyingFilter("CISourceAtopCompositing", parameters: [kCIInputBackgroundImageKey: img])
            default:
                let s2 = self.lockAlpha ? stroke.masked(byAlphaOf: img) : stroke
                return s2.blended(over: img, mode: pb).cropped(to: img.extent.union(stroke.extent))
            }
        }
        doc.setNeedsRender()
    }

    /// Writes the accumulated stroke into the layer pixels (once, at the end).
    func applyToWorking() {
        guard livePreview, !applied else { return }
        applied = true
        doc.contentOverrides.removeValue(forKey: layerID)
        if !totalDirty.isEmpty { composite(totalDirty) }
    }

    func finish(name: String) {
        flush()
        applyToWorking()
        doc.commit(name)
    }
}
