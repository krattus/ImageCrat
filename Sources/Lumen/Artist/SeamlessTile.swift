import AppKit
import SwiftUI
import ImageCratCore

/// Seamless tile tools: Make Seamless (offset + seam healing) and Define Pattern from Canvas.
/// (Wrap-around painting lives in `BrushAssist.wrapCopies`.)
enum SeamlessMethod: String, CaseIterable, Identifiable {
    case heal, blend
    var id: String { rawValue }
    var title: String { self == .heal ? "Content-Aware Heal" : "Blend (fast)" }
}

enum SeamlessTile {
    /// Copy of `buf` shifted by (dx, dy) with wrap-around.
    static func offsetWrapped(_ buf: PixelBuffer, dx: Int, dy: Int) -> PixelBuffer {
        let w = buf.width, h = buf.height
        let out = PixelBuffer(width: w, height: h, format: buf.format)
        guard w > 0, h > 0 else { return out }
        let bpp = buf.bytesPerPixel
        let src = buf.data.assumingMemoryBound(to: UInt8.self), dst = out.data.assumingMemoryBound(to: UInt8.self)
        let ox = ((dx % w) + w) % w, oy = ((dy % h) + h) % h
        for y in 0..<h {
            let ty = (y + oy) % h
            let srow = src + y * buf.bytesPerRow, drow = dst + ty * out.bytesPerRow
            // two runs per row: [0, w-ox) → ox…, and [w-ox, w) → 0…
            memcpy(drow + ox * bpp, srow, (w - ox) * bpp)
            if ox > 0 { memcpy(drow, srow + (w - ox) * bpp, ox * bpp) }
        }
        out.markDirty()
        return out
    }

    /// Mean absolute difference (0…255 per channel) between the two sides of the wrap seam (left↔right and
    /// top↔bottom edges), and the same measure between neighbouring interior columns / rows for reference.
    static func seamError(_ buf: PixelBuffer) -> (seam: Double, interior: Double) {
        let w = buf.width, h = buf.height
        guard buf.format == .rgba, w > 8, h > 8 else { return (0, 0) }
        let p = buf.data.assumingMemoryBound(to: UInt8.self)
        func diff(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Double {
            let a = y0 * buf.bytesPerRow + x0 * 4, b = y1 * buf.bytesPerRow + x1 * 4
            return (abs(Double(p[a]) - Double(p[b])) + abs(Double(p[a + 1]) - Double(p[b + 1])) + abs(Double(p[a + 2]) - Double(p[b + 2]))) / 3
        }
        var seam = 0.0, inner = 0.0, ns = 0.0, ni = 0.0
        for y in 0..<h {
            seam += diff(0, y, w - 1, y); ns += 1
            for x in [w / 4, w / 2, 3 * w / 4] { inner += diff(x, y, x + 1, y); ni += 1 }
        }
        for x in 0..<w {
            seam += diff(x, 0, x, h - 1); ns += 1
            for y in [h / 4, h / 2, 3 * h / 4] { inner += diff(x, y, x, y + 1); ni += 1 }
        }
        return (seam / ns, inner / max(1, ni))
    }

    /// Gray mask (255 = hole) of a band around the vertical line x = `x` and/or the horizontal line y = `y`.
    private static func bandMask(_ w: Int, _ h: Int, vertical x: Int?, horizontal y: Int?, half b: Int, clip: IRect? = nil) -> PixelBuffer {
        let m = PixelBuffer(width: w, height: h, gray: 0)
        let ctx = m.context
        ctx.setFillColor(gray: 1, alpha: 1)
        // PixelBuffer contexts are y-down (row 0 is the top row)
        ctx.saveGState()
        if let c = clip { ctx.clip(to: c.cgRect) }
        if let x { ctx.fill(CGRect(x: x - b, y: 0, width: 2 * b, height: h)) }
        if let y { ctx.fill(CGRect(x: 0, y: y - b, width: w, height: 2 * b)) }
        ctx.restoreGState()
        m.markDirty()
        return m
    }

    /// out = a·(1−w) + b·w with w falling linearly from 1 on the seam lines to 0 at distance `half`.
    private static func feather(_ a: PixelBuffer, _ b: PixelBuffer, x sx: Int?, y sy: Int?, half: Int, within r: IRect? = nil) -> PixelBuffer {
        let out = a.copy()
        let w = a.width, h = a.height
        let pa = a.data.assumingMemoryBound(to: UInt8.self), pb = b.data.assumingMemoryBound(to: UInt8.self), po = out.data.assumingMemoryBound(to: UInt8.self)
        let rect = r ?? IRect(x: 0, y: 0, width: w, height: h)
        for y in max(0, rect.minY)..<min(h, rect.maxY) {
            for x in max(0, rect.minX)..<min(w, rect.maxX) {
                var wt = 0.0
                if let sx { wt = max(wt, 1 - abs(Double(x) + 0.5 - Double(sx)) / Double(half)) }
                if let sy { wt = max(wt, 1 - abs(Double(y) + 0.5 - Double(sy)) / Double(half)) }
                if wt <= 0 { continue }
                let k = min(1, wt * 1.6)      // full replacement near the seam, feathered towards the band edge
                let i = y * a.bytesPerRow + x * 4
                for c in 0..<4 { po[i + c] = UInt8((Double(pa[i + c]) * (1 - k) + Double(pb[i + c]) * k).rounded()) }
            }
        }
        out.markDirty()
        return out
    }

    /// Low-frequency equalisation: measures the broad colour / brightness step across the seam lines (box means on
    /// either side, smoothed along the seam with wrap-around) and removes it with a wide cosine ramp that reaches zero
    /// at the image borders. Texture detail is untouched; only the large-scale mismatch that makes a tile edge visible
    /// goes away.
    static func equalise(_ buf: PixelBuffer, x sx: Int?, y sy: Int?) -> PixelBuffer {
        let out = buf.copy()
        let w = buf.width, h = buf.height
        let p = out.data.assumingMemoryBound(to: UInt8.self)
        let bpr = out.bytesPerRow
        /// One seam: `along` = length of the seam, `across` = extent perpendicular to it, `at(i, j)` = byte offset of
        /// the pixel at position i along and j across.
        func pass(seam: Int, along: Int, across: Int, at: (Int, Int) -> Int) {
            guard seam > 1, seam < across - 1 else { return }
            let m = max(3, min(across / 12, seam, across - seam))
            var jump = [Double](repeating: 0, count: along * 4)
            for i in 0..<along {
                for c in 0..<4 {
                    var l = 0.0, r = 0.0
                    for k in 0..<m { l += Double(p[at(i, seam - 1 - k) + c]); r += Double(p[at(i, seam + k) + c]) }
                    jump[i * 4 + c] = (r - l) / Double(m)
                }
            }
            // smooth along the seam (the image already wraps in this direction)
            let rad = max(2, min(along / 2 - 1, m * 2))
            var smooth = [Double](repeating: 0, count: along * 4)
            for c in 0..<4 {
                var acc = 0.0
                for k in -rad...rad { acc += jump[(((k % along) + along) % along) * 4 + c] }
                for i in 0..<along {
                    smooth[i * 4 + c] = acc / Double(2 * rad + 1)
                    acc += jump[((i + rad + 1) % along) * 4 + c] - jump[(((i - rad) % along + along) % along) * 4 + c]
                }
            }
            let reach = Double(min(seam, across - seam))
            for i in 0..<along {
                for j in 0..<across {
                    let d = Double(j) + 0.5 - Double(seam)
                    let t = abs(d) / reach
                    if t >= 1 { continue }
                    let wgt = 0.5 * (1 + cos(.pi * t)) * 0.5 * (d < 0 ? 1 : -1)
                    let o = at(i, j)
                    for c in 0..<4 { p[o + c] = UInt8(clamp(Double(p[o + c]) + smooth[i * 4 + c] * wgt, 0, 255).rounded()) }
                    let a = p[o + 3]
                    for c in 0..<3 where p[o + c] > a { p[o + c] = a }     // keep premultiplied pixels valid
                }
            }
        }
        if let sx { pass(seam: sx, along: h, across: w) { i, j in i * bpr + j * 4 } }
        if let sy { pass(seam: sy, along: w, across: h) { i, j in j * bpr + i * 4 } }
        out.markDirty()
        return out
    }

    /// Cross-dissolves each pixel near a seam with its mirror image on the other side (strongest on the seam, fading
    /// out at distance `half`), so the two sides meet in their average: fast, streak-free, exactly continuous.
    static func mirrorBlend(_ buf: PixelBuffer, x sx: Int?, y sy: Int?, half b: Int) -> PixelBuffer {
        let out = buf.copy()
        let w = buf.width, h = buf.height
        let p = out.data.assumingMemoryBound(to: UInt8.self)
        let bpr = out.bytesPerRow
        func pass(seam: Int, along: Int, across: Int, at: (Int, Int) -> Int) {
            let n = min(b, seam, across - seam)
            guard n > 0 else { return }
            for i in 0..<along {
                for d in 0..<n {
                    var k = 1 - (Double(d) + 0.5) / Double(n)
                    k = 0.5 * k * k * (3 - 2 * k)
                    let o0 = at(i, seam - 1 - d), o1 = at(i, seam + d)
                    for c in 0..<4 {
                        let a = Double(p[o0 + c]), z = Double(p[o1 + c])
                        p[o0 + c] = UInt8((a + (z - a) * k).rounded())
                        p[o1 + c] = UInt8((z + (a - z) * k).rounded())
                    }
                }
            }
        }
        if let sx { pass(seam: sx, along: h, across: w) { i, j in i * bpr + j * 4 } }
        if let sy { pass(seam: sy, along: w, across: h) { i, j in j * bpr + i * 4 } }
        out.markDirty()
        return out
    }

    /// Makes an image tile seamlessly while keeping its alignment.
    ///
    /// The image is offset by half its size so the wrap seam becomes a cross through the middle. The broad colour step
    /// across the cross is equalised, then the texture break on it is repaired — by PatchMatch inpainting feathered
    /// into the original (`.heal`) or by a mirrored cross-dissolve (`.blend`). For `.heal` the image is offset by a
    /// further quarter so the two places where the healed strips met the image border can be repaired as well.
    /// Finally the image is shifted back. `band` is the half-width of the repaired strip (default ≈ 6 % of the
    /// shorter side).
    static func makeSeamless(_ src: PixelBuffer, method: SeamlessMethod = .heal, band: Int? = nil, progress: ((Double) -> Void)? = nil) -> PixelBuffer {
        let w = src.width, h = src.height
        guard src.format == .rgba, w >= 16, h >= 16 else { return src.copy() }
        let b = clamp(band ?? max(4, min(w, h) / 16), 2, max(2, min(w, h) / 5))
        let cx = w / 2, cy = h / 2
        var a = equalise(offsetWrapped(src, dx: cx, dy: cy), x: cx, y: cy)
        progress?(0.05)
        switch method {
        case .blend:
            a = mirrorBlend(a, x: cx, y: cy, half: b)
        case .heal:
            // vertical seam, then horizontal seam (two thin holes keep PatchMatch local)
            // The inpainted strip stays narrow (PatchMatch cost grows with its area); the broad mismatch is already gone.
            let hole = clamp(b / 2, 2, 8)
            let hv = Inpainter.inpaint(a, hole: bandMask(w, h, vertical: cx, horizontal: nil, half: hole), patchSize: 7) { progress?(0.05 + 0.35 * $0) }
            a = feather(a, hv, x: cx, y: nil, half: b)
            let hh = Inpainter.inpaint(a, hole: bandMask(w, h, vertical: nil, horizontal: cy, half: hole), patchSize: 7) { progress?(0.4 + 0.35 * $0) }
            a = feather(a, hh, x: nil, y: cy, half: b)
            // The healed strips cross the image border at (cx, 0|h) and (0|w, cy): repair those two joints away from the border.
            let qx = w / 4, qy = h / 4
            var q = offsetWrapped(a, dx: qx, dy: qy)
            // joint 1: horizontal wrap seam at y = qy around x = cx + qx; joint 2: vertical wrap seam at x = qx around y = cy + qy
            let r1 = IRect(x: (cx + qx) % w - 2 * b, y: qy - 2 * b, width: 4 * b, height: 4 * b).intersection(q.bounds)
            let r2 = IRect(x: qx - 2 * b, y: (cy + qy) % h - 2 * b, width: 4 * b, height: 4 * b).intersection(q.bounds)
            if !r1.isEmpty {
                let m = bandMask(w, h, vertical: nil, horizontal: qy, half: hole, clip: r1)
                q = feather(q, Inpainter.inpaint(q, hole: m, patchSize: 7), x: nil, y: qy, half: b, within: r1)
            }
            progress?(0.88)
            if !r2.isEmpty {
                let m = bandMask(w, h, vertical: qx, horizontal: nil, half: hole, clip: r2)
                q = feather(q, Inpainter.inpaint(q, hole: m, patchSize: 7), x: qx, y: nil, half: b, within: r2)
            }
            a = offsetWrapped(q, dx: -qx, dy: -qy)
        }
        progress?(1)
        return offsetWrapped(a, dx: -cx, dy: -cy)
    }

    // MARK: Document actions

    /// Make Seamless on the active pixel layer (its canvas area), or on a merged copy added as a new layer.
    static func makeSeamlessAction(method: SeamlessMethod, band: Int?) {
        guard let d = AppActions.doc else { return }
        let st = d.state
        let sp = CanvasSpace(width: st.width, height: st.height)
        let app = AppModel.shared
        if let l = d.activeLayer, l.isRaster, !l.locks.pixelsLocked, d.editTarget == .content {
            let img = Compositor.shared.contentImage(l, space: sp) ?? CIImage.clearImage
            let buf = RenderEngine.renderBuffer(img.cropped(to: sp.ciCanvas), docRect: st.canvasRect, space: sp)
            let out = makeSeamless(buf, method: method, band: band)
            d.updateLayer(l.id) { $0.raster = RasterContent(buffer: out, origin: .zero) }
            d.commit("Make Seamless")
        } else {
            let buf = RenderEngine.renderBuffer(Compositor.shared.composite(d), docRect: st.canvasRect, space: sp)
            let out = makeSeamless(buf, method: method, band: band)
            d.addLayer(Layer.raster(name: d.nextLayerName("Seamless"), buffer: out), commitName: "Make Seamless")
        }
        app.setStatus("Made seamless — View ▸ Pattern Preview shows the repeat")
    }

    @discardableResult
    static func definePatternFromCanvas() -> String? {
        guard let d = AppActions.doc else { return nil }
        let app = AppModel.shared
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        let buf = RenderEngine.renderBuffer(Compositor.shared.composite(d), docRect: d.state.canvasRect, space: sp)
        let id = "custom-\(UUID().uuidString.prefix(8))"
        let base = (d.name as NSString).deletingPathExtension
        app.customPatterns.append(PatternDef(id: id, name: "\(base) \(d.state.width)×\(d.state.height)", image: buf))
        app.bucket.patternID = id
        app.setStatus("Pattern defined from the canvas (\(d.state.width)×\(d.state.height)) — see the Patterns panel")
        return id
    }
}

struct MakeSeamlessDialog: View {
    /// Content-aware healing is the default up to ~2 MP; larger canvases start with the fast blend.
    @State private var method: SeamlessMethod = (AppActions.doc.map { $0.state.width * $0.state.height } ?? 0) > 2_000_000 ? .blend : .heal
    @State private var band: Double = Double(max(4, min(AppActions.doc?.state.width ?? 256, AppActions.doc?.state.height ?? 256) / 16))

    var body: some View {
        let side = Double(min(AppActions.doc?.state.width ?? 256, AppActions.doc?.state.height ?? 256))
        DialogFrame(title: "Make Seamless", width: 340, okTitle: "Make Seamless", onOK: {
            SeamlessTile.makeSeamlessAction(method: method, band: Int(band))
        }) {
            Picker("Method", selection: $method) { ForEach(SeamlessMethod.allCases) { Text(tr($0.title)).tag($0) } }
            ValueSlider(label: "Seam Width", value: $band, range: 2...max(4, side / 5), step: 1, unit: "px")
            Text("The layer is offset by half its size, the broad colour step and the texture break on the seam are repaired, and the layer is shifted back, so the edges match when the canvas repeats. Works on the active pixel layer, or on a merged copy when another kind of layer is active. Content-aware healing can take a while on large canvases.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
    }
}
