import AppKit
import SwiftUI
import CoreImage
import Observation
import ImageCratCore

/// Select ▸ Text in Image…: Vision OCR with the lines shown as boxes on the canvas. Click a box to copy its text,
/// or convert lines into live type layers: each new layer matches the original's position, size, angle, colour and
/// (roughly) typeface, and the original lettering is painted out on a separate layer with the on-device inpainter
/// (LaMa, else PatchMatch) — so text in a flattened image becomes editable without touching the source pixels.
enum AssistOCR {
    struct Line: Identifiable {
        let id = UUID()
        var text: String
        var quad: Quad          // doc coordinates
        var confidence: Float
        var angle: Double { Double(atan2(quad.tr.y - quad.tl.y, quad.tr.x - quad.tl.x)) }
        var center: CGPoint { quad.center }
        var width: CGFloat { (quad.tr - quad.tl).length }
        var height: CGFloat { (quad.bl - quad.tl).length }
        func contains(_ p: CGPoint) -> Bool { quad.path.contains(p) }
    }

    /// Text lines of a (possibly downscaled) composite, mapped to doc coordinates.
    static func detect(_ cg: CGImage, docSize: CGSize) -> [Line] {
        let sx = docSize.width / CGFloat(cg.width), sy = docSize.height / CGFloat(cg.height)
        return AssistVision.ocr(cg).map { l in
            var line = refineAngle(Line(text: l.text, quad: l.quad, confidence: l.confidence), image: cg)
            line.quad = line.quad.mapped { CGPoint(x: $0.x * sx, y: $0.y * sy) }
            return line
        }
    }

    /// Vision often reports an axis-aligned box for slightly rotated text. Finds the rotation that makes the
    /// line's ink lowest (classic projection deskew) and returns the line with a quad that follows the baseline.
    static func refineAngle(_ line: Line, image: CGImage) -> Line {
        guard abs(line.angle) < 0.01, line.width > 24, line.height > 10 else { return line }
        let st = analyze(line, image: image, matchFont: false)
        guard let m = st.mask, st.contrast > 28 else { return line }
        // ink points (patch coordinates relative to the patch centre), subsampled
        var pts: [(Float, Float)] = []
        let mp = m.data.assumingMemoryBound(to: UInt8.self)
        let step = max(1, Int((Double(m.width * m.height) / 60000).squareRoot()))
        let cx = Float(m.width) / 2, cy = Float(m.height) / 2
        for y in stride(from: 0, to: m.height, by: step) {
            for x in stride(from: 0, to: m.width, by: step) where mp[y * m.bytesPerRow + x] > 127 { pts.append((Float(x) - cx, Float(y) - cy)) }
        }
        guard pts.count > 40 else { return line }
        func extent(_ deg: Double) -> (h: Float, lo: Float, hi: Float) {
            let a = Float(deg * .pi / 180), s = sin(a), c = cos(a)
            var ys = pts.map { -$0.0 * s + $0.1 * c }
            ys.sort()
            let lo = ys[Int(Float(ys.count - 1) * 0.01)], hi = ys[Int(Float(ys.count - 1) * 0.99)]
            return (hi - lo, lo, hi)
        }
        var best = 0.0, bestH = extent(0).h
        let h0 = bestH
        for d in stride(from: -20.0, through: 20.0, by: 0.5) { let e = extent(d).h; if e < bestH { bestH = e; best = d } }
        for d in stride(from: best - 0.5, through: best + 0.5, by: 0.1) { let e = extent(d).h; if e < bestH { bestH = e; best = d } }
        guard abs(best) >= 1, bestH <= h0 * 0.94 else { return line }
        let a = Float(best * .pi / 180), s = sin(a), c = cos(a)
        let e = extent(best)
        var xs = pts.map { $0.0 * c + $0.1 * s }
        xs.sort()
        let pad = (e.hi - e.lo) * 0.08
        let x0 = xs[0] - pad, x1 = xs[xs.count - 1] + pad, y0 = e.lo - pad, y1 = e.hi + pad
        func back(_ x: Float, _ y: Float) -> CGPoint {
            // rotated frame → patch → doc (the patch is only translated for an axis-aligned line)
            CGPoint(x: line.center.x + CGFloat(x * c - y * s), y: line.center.y + CGFloat(x * s + y * c))
        }
        var out = line
        out.quad = Quad(tl: back(x0, y0), tr: back(x1, y0), br: back(x1, y1), bl: back(x0, y1))
        return out
    }

    // MARK: Line analysis

    struct LineStyle {
        var color: RGBA = .black
        var background: RGBA = .white
        var contrast: Double = 0
        /// Robust spread (8-bit levels) of the colours around the line: small = flat / smooth backdrop (paper, UI).
        var backgroundSpread: Double = 0
        /// Ink bounds in the upright (un-rotated about the line centre) doc frame.
        var ink: CGRect = .zero
        var fontName = "Helvetica-Bold"
        var fontScore: Double? = nil
        var fontRanking: [(String, Double)] = []
        /// The cleaned-up rendition of the lettering the typeface match ran on (dark ink on white).
        var fontTarget: CGImage? = nil
        /// Deskewed glyph mask patch (gray, white = ink) and the doc → patch transform.
        var mask: PixelBuffer? = nil
        var toPatch: CGAffineTransform = .identity
    }

    static let fontCandidates = ["Helvetica", "Helvetica-Bold", "HelveticaNeue-Light", "HelveticaNeue-Medium", "Arial-BoldMT", "Arial-Black", "ArialRoundedMTBold",
                                 "TimesNewRomanPSMT", "TimesNewRomanPS-BoldMT", "Georgia", "Georgia-Bold", "Futura-Medium", "Futura-Bold", "Impact",
                                 "Courier", "Courier-Bold", "Menlo-Regular", "Menlo-Bold", "AvenirNext-Regular", "AvenirNext-DemiBold", "AvenirNext-Heavy",
                                 "GillSans", "GillSans-Bold", "Verdana", "Verdana-Bold", "Optima-Regular", "Didot", "Baskerville", "Palatino-Roman",
                                 "AmericanTypewriter", "AmericanTypewriter-Bold", "DINCondensed-Bold", "Rockwell-Regular", "Rockwell-Bold", "TrebuchetMS", "TrebuchetMS-Bold"]

    /// Measures colour, ink bounds, glyph mask and the closest typeface of a line. `image` is the canvas composite.
    static func analyze(_ line: Line, image: CGImage, matchFont: Bool = true) -> LineStyle {
        var st = LineStyle()
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let pad = max(6, line.height * 0.35)
        let pw = Int((line.width + 2 * pad).rounded(.up)), ph = Int((line.height + 2 * pad).rounded(.up))
        guard pw > 4, ph > 4 else { return st }
        // doc (y-down) → upright patch (y-down): rotate by −angle about the line centre
        let c = line.center
        let toPatch = CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(-line.angle)))
            .concatenating(CGAffineTransform(translationX: CGFloat(pw) / 2, y: CGFloat(ph) / 2))
        st.toPatch = toPatch
        let patch = PixelBuffer(width: pw, height: ph)
        let ctx = patch.context
        ctx.saveGState()
        ctx.concatenate(toPatch)
        patch.drawImage(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        ctx.restoreGState()
        patch.markDirty()
        let p = patch.data.assumingMemoryBound(to: UInt8.self)
        func px(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let o = y * patch.bytesPerRow + x * 4
            return (Double(p[o]), Double(p[o + 1]), Double(p[o + 2]))
        }
        // background = median of the padding ring
        var rs: [Double] = [], gs: [Double] = [], bs: [Double] = []
        let ring = max(2, Int(pad * 0.6))
        for y in 0..<ph {
            for x in 0..<pw where x < ring || y < ring || x >= pw - ring || y >= ph - ring {
                let v = px(x, y); rs.append(v.0); gs.append(v.1); bs.append(v.2)
            }
        }
        func median(_ a: inout [Double]) -> Double { a.sort(); return a.isEmpty ? 0 : a[a.count / 2] }
        let bg = (median(&rs), median(&gs), median(&bs))
        st.background = RGBA(r: bg.0 / 255, g: bg.1 / 255, b: bg.2 / 255)
        // 97th percentile of the ring's distance from its median colour: thin lines or texture around the text count
        var ringDist = (0..<rs.count).map { abs(rs[$0] - bg.0) + abs(gs[$0] - bg.1) + abs(bs[$0] - bg.2) }
        ringDist.sort()
        st.backgroundSpread = ringDist.isEmpty ? 0 : ringDist[Int(Double(ringDist.count - 1) * 0.97)] / 3
        // distance from the background inside the text box (a little slack for ascenders / descenders)
        let slack = Int(pad * 0.45)
        let x0 = max(0, Int(pad) - slack), x1 = min(pw, pw - Int(pad) + slack), y0 = max(0, Int(pad) - slack), y1 = min(ph, ph - Int(pad) + slack)
        var dist = [Double](repeating: 0, count: pw * ph)
        var maxD = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let v = px(x, y)
                let d = ((v.0 - bg.0) * (v.0 - bg.0) + (v.1 - bg.1) * (v.1 - bg.1) + (v.2 - bg.2) * (v.2 - bg.2)).squareRoot()
                dist[y * pw + x] = d
                maxD = max(maxD, d)
            }
        }
        st.contrast = maxD
        let mask = PixelBuffer(width: pw, height: ph, format: .gray)
        let mp = mask.data.assumingMemoryBound(to: UInt8.self)
        guard maxD > 28 else {
            // no usable contrast: treat the whole box as ink
            for y in y0..<y1 { for x in x0..<x1 { mp[y * mask.bytesPerRow + x] = 255 } }
            mask.markDirty()
            st.mask = mask
            st.ink = CGRect(x: c.x - line.width / 2, y: c.y - line.height / 2, width: line.width, height: line.height)
            return st
        }
        // Otsu on the distances
        var hist = [Int](repeating: 0, count: 64)
        var count = 0
        for y in y0..<y1 { for x in x0..<x1 { hist[min(63, Int(dist[y * pw + x] / maxD * 63))] += 1; count += 1 } }
        var sum = 0.0
        for i in 0..<64 { sum += Double(i * hist[i]) }
        var sumB = 0.0, wB = 0, best = 0.0, thr = 32
        for i in 0..<64 {
            wB += hist[i]
            if wB == 0 { continue }
            let wF = count - wB
            if wF == 0 { break }
            sumB += Double(i * hist[i])
            let mB = sumB / Double(wB), mF = (sum - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; thr = i }
        }
        let t = max(0.3, (Double(thr) + 0.5) / 63) * maxD
        // text colour = median of the pixels that stand out; ink = pixels nearer to it than half-way to the background.
        // (On photographs other things stand out from the median backdrop too — bright rocks, shadows — but they are
        // not the text colour, so they drop out here.)
        var tr: [Double] = [], tg: [Double] = [], tb: [Double] = []
        let sub = max(1, ((x1 - x0) * (y1 - y0)) / 40000)
        var k = 0
        for y in y0..<y1 { for x in x0..<x1 where dist[y * pw + x] >= t {
            k += 1
            if k % sub == 0 { let v = px(x, y); tr.append(v.0); tg.append(v.1); tb.append(v.2) }
        } }
        let tc = (median(&tr), median(&tg), median(&tb))
        let D = max(1, ((tc.0 - bg.0) * (tc.0 - bg.0) + (tc.1 - bg.1) * (tc.1 - bg.1) + (tc.2 - bg.2) * (tc.2 - bg.2)).squareRoot())
        var ix0 = pw, iy0 = ph, ix1 = -1, iy1 = -1
        var cr = 0.0, cg = 0.0, cb = 0.0, cn = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let v = px(x, y)
                let dt = ((v.0 - tc.0) * (v.0 - tc.0) + (v.1 - tc.1) * (v.1 - tc.1) + (v.2 - tc.2) * (v.2 - tc.2)).squareRoot() / D
                // reuse `dist` as "inkness" 0…maxD for the soft rendition used by the font matcher
                dist[y * pw + x] = max(0, 1 - dt) * maxD
                guard dt <= 0.5 else { continue }
                mp[y * mask.bytesPerRow + x] = 255
                ix0 = min(ix0, x); ix1 = max(ix1, x); iy0 = min(iy0, y); iy1 = max(iy1, y)
                if dt <= 0.2 { cr += v.0; cg += v.1; cb += v.2; cn += 1 }
            }
        }
        mask.markDirty()
        st.mask = mask
        if cn > 0 { st.color = RGBA(r: cr / cn / 255, g: cg / cn / 255, b: cb / cn / 255) }
        if ix1 >= ix0, iy1 >= iy0 {
            // patch → upright doc frame (the patch is only translated relative to it)
            let ox = c.x - CGFloat(pw) / 2, oy = c.y - CGFloat(ph) / 2
            st.ink = CGRect(x: ox + CGFloat(ix0), y: oy + CGFloat(iy0), width: CGFloat(ix1 - ix0 + 1), height: CGFloat(iy1 - iy0 + 1))
        } else {
            st.ink = CGRect(x: c.x - line.width / 2, y: c.y - line.height / 2, width: line.width, height: line.height)
        }
        // closest typeface among common faces (shape similarity of the binarised line)
        if matchFont, ix1 > ix0, iy1 > iy0 {
            // MatchFontEngine expects dark ink on light paper
            let bx0 = max(0, ix0 - 2), by0 = max(0, iy0 - 2), bx1 = min(pw, ix1 + 3), by1 = min(ph, iy1 + 3)
            // wide white margins: the matcher takes the minority class as ink, and heavy capitals can cover
            // more than half of a tight crop
            let margin = max(12, (by1 - by0) * 2 / 3)
            let inv = PixelBuffer(width: bx1 - bx0 + 2 * margin, height: by1 - by0 + 2 * margin, gray: 255)
            let ip = inv.data.assumingMemoryBound(to: UInt8.self)
            // soft (anti-aliased) rendition from the colour distance, like a scan of the lettering
            for y in by0..<by1 { for x in bx0..<bx1 {
                ip[(y - by0 + margin) * inv.bytesPerRow + (x - bx0 + margin)] = UInt8(255 - min(255, dist[y * pw + x] / maxD * 255))
            } }
            inv.markDirty()
            st.fontTarget = inv.makeCGImage()
            if let target = MatchFontEngine.target(inv.makeCGImage()) {
                var scored: [(String, Double)] = []
                for f in fontCandidates {
                    if let s = MatchFontEngine.score(target, text: line.text, fontName: f) { scored.append((f, s)) }
                }
                scored.sort { $0.1 < $1.1 }
                st.fontRanking = Array(scored.prefix(4))
                if let b = scored.first { st.fontName = b.0; st.fontScore = b.1 }
            }
        }
        return st
    }

    // MARK: Type layer

    /// Ink bounds of a text layer placed at `position` (no transform), measured by rendering it.
    static func inkBounds(_ t: TextContent) -> CGRect? {
        var m = t
        m.transform = .identity
        let size = TextRenderer.layoutSize(m)
        let margin = CGFloat(m.fontSize) + 40
        m.position = CGPoint(x: margin, y: margin)
        let sp = CanvasSpace(width: Int(size.width + 2 * margin) + 8, height: Int(size.height + 2 * margin) + 8)
        let buf = RenderEngine.renderBuffer(TextRenderer.render(m, space: sp), docRect: IRect(x: 0, y: 0, width: sp.width, height: sp.height), space: sp)
        guard let b = buf.opaqueBounds(threshold: 40) else { return nil }
        return b.cgRect.offsetBy(dx: t.position.x - margin, dy: t.position.y - margin)
    }

    /// A live text layer whose ink covers the same pixels as the recognised line. Main thread.
    static func textContent(for line: Line, style st: LineStyle) -> TextContent {
        var t = TextContent()
        t.text = line.text
        t.fontName = st.fontName
        t.color = st.color
        t.alignment = .left
        t.fontSize = max(4, MatchFontEngine.matchingSize(line.text, fontName: st.fontName, inkHeight: st.ink.height))
        t.position = st.ink.origin
        for _ in 0..<2 {
            guard let ink = inkBounds(t), ink.height > 1, ink.width > 1 else { break }
            let k = st.ink.height / ink.height
            if abs(k - 1) > 0.01 { t.fontSize = max(4, t.fontSize * Double(k)); continue }
            break
        }
        if let ink = inkBounds(t), ink.width > 1 {
            // same width as the original lettering (condensed / extended faces, tracking differences)
            let k = Double(st.ink.width / ink.width)
            if abs(k - 1) > 0.015 { t.horizontalScale = max(0.7, min(1.4, k)) }
        }
        if let ink = inkBounds(t) {
            t.position.x += st.ink.minX - ink.minX
            t.position.y += st.ink.minY - ink.minY
        }
        if abs(line.angle) > 0.006 {
            let c = line.center
            t.transform = CGAffineTransform(translationX: -c.x, y: -c.y).concatenating(CGAffineTransform(rotationAngle: CGFloat(line.angle)))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
        }
        return t
    }

    // MARK: Convert

    struct Conversion {
        var textLayerIDs: [UUID] = []
        var patchLayerID: UUID?
        var engine = ""
        var seconds = 0.0
        /// Seconds spent measuring the lines (colour, size, typeface) and painting the originals out.
        var analysisSeconds = 0.0
        var inpaintSeconds = 0.0
        var styles: [LineStyle] = []
    }

    /// Canvas-size hole mask covering the lettering of `lines` (glyph masks grown a little).
    static func holeMask(_ lines: [Line], styles: [LineStyle], width: Int, height: Int) -> PixelBuffer {
        let hole = PixelBuffer(width: width, height: height, format: .gray)
        let ctx = hole.context
        for (l, st) in zip(lines, styles) {
            guard let m = st.mask else { continue }
            ctx.saveGState()
            ctx.concatenate(st.toPatch.inverted())
            ctx.setBlendMode(.lighten)
            hole.drawImage(m.makeCGImage(), in: CGRect(x: 0, y: 0, width: m.width, height: m.height), blend: .lighten)
            ctx.restoreGState()
            _ = l
        }
        hole.markDirty()
        // enough to swallow anti-aliased edges and compression ringing, small enough to keep the real pixels between letters
        let grow = min(9, max(3, (lines.map { Double($0.height) }.max() ?? 20) * 0.07))
        return SelectionOps.expand(hole, by: grow)
    }

    /// Fills `hole` inside `rect` of an opaque RGBA buffer by smooth interpolation from the surrounding pixels
    /// (pull-push pyramid): exact on flat colours and gentle gradients, no invented texture.
    static func smoothFill(_ buf: PixelBuffer, hole: PixelBuffer, rect: IRect) {
        let w = rect.width, h = rect.height
        guard w > 2, h > 2 else { return }
        struct Level { var w: Int; var h: Int; var c: [Float]; var a: [Float] }
        var base = Level(w: w, h: h, c: [Float](repeating: 0, count: w * h * 3), a: [Float](repeating: 0, count: w * h))
        let p = buf.data.assumingMemoryBound(to: UInt8.self), hp = hole.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let sx = rect.x + x, sy = rect.y + y
                let valid: Float = hp[sy * hole.bytesPerRow + sx] > 8 ? 0 : 1
                let o = sy * buf.bytesPerRow + sx * 4
                let i = y * w + x
                base.a[i] = valid
                base.c[i * 3] = Float(p[o]) * valid; base.c[i * 3 + 1] = Float(p[o + 1]) * valid; base.c[i * 3 + 2] = Float(p[o + 2]) * valid
            }
        }
        // pull: average the valid pixels into ever coarser levels
        var levels = [base]
        while levels.last!.w > 1 || levels.last!.h > 1 {
            let f = levels.last!
            let cw = (f.w + 1) / 2, ch = (f.h + 1) / 2
            var c = Level(w: cw, h: ch, c: [Float](repeating: 0, count: cw * ch * 3), a: [Float](repeating: 0, count: cw * ch))
            for y in 0..<ch {
                for x in 0..<cw {
                    var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
                    for dy in 0..<2 { for dx in 0..<2 {
                        let fx = min(f.w - 1, x * 2 + dx), fy = min(f.h - 1, y * 2 + dy)
                        let i = fy * f.w + fx
                        r += f.c[i * 3]; g += f.c[i * 3 + 1]; b += f.c[i * 3 + 2]; a += f.a[i]
                    } }
                    let i = y * cw + x
                    if a > 0 { c.c[i * 3] = r / a; c.c[i * 3 + 1] = g / a; c.c[i * 3 + 2] = b / a; c.a[i] = min(1, a) } 
                }
            }
            // store premultiplied by the clamped weight, like the base level
            for i in 0..<(cw * ch) { let a = c.a[i]; c.c[i * 3] *= a; c.c[i * 3 + 1] *= a; c.c[i * 3 + 2] *= a }
            levels.append(c)
            if levels.count > 14 { break }
        }
        // push: fill what is missing at each level from the (bilinearly upsampled) coarser one
        for k in stride(from: levels.count - 2, through: 0, by: -1) {
            let c = levels[k + 1]
            var f = levels[k]
            for y in 0..<f.h {
                for x in 0..<f.w {
                    let i = y * f.w + x
                    let a = f.a[i]
                    if a >= 1 { continue }
                    let gx = (Float(x) + 0.5) / 2 - 0.5, gy = (Float(y) + 0.5) / 2 - 0.5
                    let x0 = max(0, min(c.w - 1, Int(gx.rounded(.down)))), y0 = max(0, min(c.h - 1, Int(gy.rounded(.down))))
                    let x1 = min(c.w - 1, x0 + 1), y1 = min(c.h - 1, y0 + 1)
                    let tx = max(0, min(1, gx - Float(x0))), ty = max(0, min(1, gy - Float(y0)))
                    var col: (Float, Float, Float) = (0, 0, 0)
                    var wsum: Float = 0
                    for (cx, cy, wgt) in [(x0, y0, (1 - tx) * (1 - ty)), (x1, y0, tx * (1 - ty)), (x0, y1, (1 - tx) * ty), (x1, y1, tx * ty)] {
                        let j = cy * c.w + cx
                        let cw = wgt * c.a[j]
                        if cw <= 0 { continue }
                        // coarse colours are premultiplied by their weight
                        col.0 += wgt * c.c[j * 3]; col.1 += wgt * c.c[j * 3 + 1]; col.2 += wgt * c.c[j * 3 + 2]; wsum += cw
                    }
                    if wsum > 0 {
                        f.c[i * 3] += (1 - a) * col.0 / wsum; f.c[i * 3 + 1] += (1 - a) * col.1 / wsum; f.c[i * 3 + 2] += (1 - a) * col.2 / wsum
                        f.a[i] = 1
                    }
                }
            }
            levels[k] = f
        }
        let out = levels[0]
        for y in 0..<h {
            for x in 0..<w {
                let sx = rect.x + x, sy = rect.y + y
                guard hp[sy * hole.bytesPerRow + sx] > 8 else { continue }
                let o = sy * buf.bytesPerRow + sx * 4
                let i = y * w + x
                p[o] = UInt8(max(0, min(255, out.c[i * 3].rounded()))); p[o + 1] = UInt8(max(0, min(255, out.c[i * 3 + 1].rounded())))
                p[o + 2] = UInt8(max(0, min(255, out.c[i * 3 + 2].rounded()))); p[o + 3] = 255
            }
        }
        buf.markDirty()
    }

    /// Converts recognised lines into type layers and paints the original lettering out on a new layer above the
    /// image. One undo step; nothing below is modified.
    static func convert(_ lines: [Line], in d: Document, removeOriginal: Bool = true, matchFont: Bool = true) async throws -> Conversion {
        let t0 = CFAbsoluteTimeGetCurrent()
        var conv = Conversion()
        guard !lines.isEmpty else { return conv }
        let (cg, W, H): (CGImage?, Int, Int) = await Assist.onMain { (Assist.compositeCG(d.state), d.state.width, d.state.height) }
        guard let image = cg else { return conv }
        let styles = lines.map { analyze($0, image: image, matchFont: matchFont) }
        conv.styles = styles
        conv.analysisSeconds = CFAbsoluteTimeGetCurrent() - t0
        let t1 = CFAbsoluteTimeGetCurrent()
        defer { _ = t1 }
        var patch: (PixelBuffer, IRect)?
        if removeOriginal {
            let hole = holeMask(lines, styles: styles, width: W, height: H)
            if let hb = hole.opaqueBounds(threshold: 8) {
                // lettering on a flat / smoothly shaded surface (signs, posters, screenshots): a smooth membrane fill is
                // cleaner than a generative one; everything else goes to LaMa (PatchMatch when it is not installed)
                let smooth = zip(lines, styles).filter { $0.1.backgroundSpread < 6 && $0.1.contrast > 28 }
                let textured = zip(lines, styles).filter { !($0.1.backgroundSpread < 6 && $0.1.contrast > 28) }
                var work = PixelBuffer(cgImage: image)
                var engines: [String] = []
                if !textured.isEmpty {
                    let th = holeMask(textured.map(\.0), styles: textured.map(\.1), width: W, height: H)
                    var filled: CGImage?
                    if LamaInpainter.isAvailable, let out = try? await LamaInpainter.inpaint(image, hole: PlanarImage.gray(th.makeCGImage())) {
                        filled = out
                        engines.append("LaMa")
                    }
                    if filled == nil {
                        filled = Inpainter.inpaint(PixelBuffer(cgImage: image), hole: th).makeCGImage()
                        engines.append("PatchMatch")
                    }
                    if let f = filled { work = PixelBuffer(cgImage: f) }
                }
                if !smooth.isEmpty {
                    for (l, st) in smooth {
                        let lh = holeMask([l], styles: [st], width: W, height: H)
                        if let r = lh.opaqueBounds(threshold: 8) { smoothFill(work, hole: lh, rect: r.insetBy(-10).intersection(work.bounds)) }
                    }
                    engines.append("smooth fill")
                }
                conv.engine = engines.joined(separator: " + ")
                // keep only the repaired pixels (soft edge), cropped to the hole
                let r = hb.insetBy(-6).intersection(IRect(x: 0, y: 0, width: W, height: H))
                let soft = SelectionOps.feather(SelectionOps.expand(hole, by: 1.5), radius: 1.5)
                let out = PixelBuffer(width: r.width, height: r.height)
                let ctx = out.context
                ctx.saveGState()
                out.clip(toMask: soft.makeCGImage(), in: CGRect(x: -r.x, y: -r.y, width: W, height: H))
                out.drawImage(work.makeCGImage(), in: CGRect(x: -r.x, y: -r.y, width: W, height: H))
                ctx.restoreGState()
                out.markDirty()
                patch = (out, r)
            }
        }
        conv.inpaintSeconds = CFAbsoluteTimeGetCurrent() - t1
        let result: Conversion = await Assist.onMain { [conv] in
            var c = conv
            var newLayers: [Layer] = []
            if let (buf, r) = patch {
                let l = Layer.raster(name: lines.count == 1 ? "Text Removed — “\(Assist.truncate(lines[0].text, 18))”" : "Text Removed (\(lines.count) lines)", buffer: buf, origin: r.origin)
                c.patchLayerID = l.id
                newLayers.append(l)
            }
            for (line, st) in zip(lines, styles) {
                let l = Layer(name: Assist.truncate(line.text, 32), content: .text(textContent(for: line, style: st)))
                c.textLayerIDs.append(l.id)
                newLayers.append(l)
            }
            d.state.layers.append(contentsOf: newLayers)
            d.activeLayerID = c.textLayerIDs.last
            d.selectedLayerIDs = Set(c.textLayerIDs)
            d.commit(lines.count == 1 ? "Convert to Editable Text" : "Convert \(lines.count) Lines to Editable Text")
            d.setNeedsRender()
            return c
        }
        var r = result
        r.seconds = CFAbsoluteTimeGetCurrent() - t0
        return r
    }
}

// MARK: - Canvas overlay + dialog

@Observable
final class AssistOCRModel {
    static let shared = AssistOCRModel()
    static let samplerToken = "assist.ocr"
    var lines: [AssistOCR.Line] = []
    var selected: Set<UUID> = []
    var running = false
    var message = ""
    var active = false
    var removeOriginal = true
    @ObservationIgnored var docID: UUID?

    func start() {
        guard let d = AppActions.doc, let cg = Assist.compositeCG(d.state, maxSide: 3000) else { return }
        active = true
        docID = d.id
        running = true
        message = "Reading text…"
        let size = CGSize(width: d.state.width, height: d.state.height)
        Task.detached(priority: .userInitiated) {
            let lines = AssistOCR.detect(cg, docSize: size)
            await MainActor.run {
                self.lines = lines
                self.selected = []
                self.running = false
                self.message = lines.isEmpty ? "No text found." : "\(lines.count) line\(lines.count == 1 ? "" : "s") — click a box on the canvas to copy its text."
                d.setNeedsOverlay()
            }
        }
        CanvasSampler.shared.arm(Self.samplerToken) { [weak self] p, mods in self?.click(p, extend: mods.contains(.shift) || mods.contains(.command)) }
        AppModel.shared.setStatus("Text in Image: click a text box to copy it.")
    }

    func stop() {
        active = false
        lines = []
        selected = []
        CanvasSampler.shared.disarm(Self.samplerToken)
        AppActions.doc?.setNeedsOverlay()
    }

    func click(_ p: CGPoint, extend: Bool) {
        guard let l = lines.first(where: { $0.contains(p) }) else { if !extend { selected = [] }; AppActions.doc?.setNeedsOverlay(); return }
        if extend { if selected.contains(l.id) { selected.remove(l.id) } else { selected.insert(l.id) } } else { selected = [l.id] }
        let text = lines.filter { selected.contains($0.id) }.map(\.text).joined(separator: "\n")
        Assist.copyToClipboard(text)
        message = "Copied “\(Assist.truncate(text.replacingOccurrences(of: "\n", with: " "), 40))”"
        AppModel.shared.setStatus(message)
        AppActions.doc?.setNeedsOverlay()
    }

    func convert(all: Bool) {
        guard let d = AppActions.doc else { return }
        let target = all || selected.isEmpty ? lines : lines.filter { selected.contains($0.id) }
        guard !target.isEmpty else { return }
        running = true
        message = "Converting \(target.count) line\(target.count == 1 ? "" : "s")…"
        let remove = removeOriginal
        Task.detached(priority: .userInitiated) {
            let r = try? await AssistOCR.convert(target, in: d, removeOriginal: remove)
            await MainActor.run {
                self.running = false
                let ids = Set(target.map(\.id))
                self.lines.removeAll { ids.contains($0.id) }
                self.selected = []
                if let r {
                    self.message = String(format: "Created %d type layer%@%@ (%.1f s).", r.textLayerIDs.count, r.textLayerIDs.count == 1 ? "" : "s",
                                          r.patchLayerID != nil ? "; original text painted out with \(r.engine)" : "", r.seconds)
                } else { self.message = "Conversion failed." }
                AppModel.shared.setStatus(self.message)
                d.setNeedsOverlay()
            }
        }
    }
}

/// Drawn by the canvas overlay (one call in `OverlayView.draw`).
enum AssistOverlay {
    static func draw(_ ctx: CGContext, canvas: CanvasView, doc: Document) {
        let m = AssistOCRModel.shared
        guard m.active, m.docID == doc.id, !m.lines.isEmpty else { return }
        for l in m.lines {
            let on = m.selected.contains(l.id)
            let path = l.quad.mapped { canvas.docToView($0) }.path
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setFillColor(OverlayStyle.accent.withAlphaComponent(on ? 0.32 : 0.10).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor((on ? NSColor.white : OverlayStyle.accent).cgColor)
            ctx.setLineWidth(on ? 2 : 1.2)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
}

struct AssistOCRDialog: View {
    @Bindable var m = AssistOCRModel.shared

    var body: some View {
        DialogFrame(title: "Text in Image", width: 340, okTitle: "Done", onOK: { m.stop() }, onCancel: { m.stop() }) {
            HStack {
                if m.running { ProgressView().controlSize(.small) }
                Text(m.message).font(Theme.font).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
            if !m.lines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(m.lines) { l in
                            let on = m.selected.contains(l.id)
                            HStack(spacing: 6) {
                                Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? Theme.accent : Theme.textFaint)
                                Text(l.text).font(Theme.font).lineLimit(1)
                                Spacer()
                                Text("\(Int(l.confidence * 100))%").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                            }
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 3).fill(on ? Theme.selection : Color.clear))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if on { m.selected.remove(l.id) } else { m.selected.insert(l.id) }
                                AppActions.doc?.setNeedsOverlay()
                            }
                        }
                    }
                }
                .frame(maxHeight: 190)
                HStack(spacing: 6) {
                    Button(m.selected.isEmpty ? "Copy All" : "Copy") {
                        let t = (m.selected.isEmpty ? m.lines : m.lines.filter { m.selected.contains($0.id) }).map(\.text).joined(separator: "\n")
                        Assist.copyToClipboard(t)
                        m.message = "Copied \(t.count) characters."
                    }.buttonStyle(PanelButtonStyle())
                    Button(m.selected.isEmpty ? "Convert All to Editable Text" : "Convert to Editable Text") { m.convert(all: m.selected.isEmpty) }
                        .buttonStyle(PanelButtonStyle(prominent: true)).disabled(m.running)
                }
                Toggle2(label: "Paint out the original text (on its own layer)", on: $m.removeOriginal)
                    .help("Flat backgrounds are filled smoothly; textured ones with \(LamaInpainter.isAvailable ? "LaMa" : "PatchMatch")")
            }
        }
        .onAppear { if !m.active { m.start() } }
        .onDisappear { m.stop() }
    }
}
