import AppKit
import SwiftUI
import CoreImage
import Observation
import ImageCratCore

/// Image ▸ Analyze…: technical quality checks (sharpness, noise, exposure / clipping, colour cast, JPEG blockiness,
/// resolution for the intended use, tilted horizon, closed eyes / faces cut at the edge) with one-click,
/// non-destructive fixes (adjustment layers, smart filters), and Image ▸ Auto Enhance.
enum AssistQuality {
    enum Kind: String {
        case blur, noise, underexposed, overexposed, lowContrast, clippedHighlights, clippedShadows, colorCast, jpegBlocks
        case lowResolution, tilted, closedEyes, faceCut
    }

    enum Severity: Int { case info = 0, warning, problem }

    enum Fix: Equatable {
        case levels
        case brighten(Double)              // curve midpoint shift (−0.25…0.25)
        case recoverHighlights
        case liftShadows
        case whiteBalance(temperature: Double, tint: Double)
        case denoise
        case sharpen(amount: Double, radius: Double)
        case straighten(radians: Double)

        var title: String {
            switch self {
            case .levels: return "Add Levels"
            case .brighten(let v): return v > 0 ? "Brighten (Curves)" : "Darken (Curves)"
            case .recoverHighlights: return "Recover Highlights"
            case .liftShadows: return "Lift Shadows"
            case .whiteBalance: return "Correct White Balance"
            case .denoise: return Restoration.isAvailable(.denoise) ? "Denoise (NAFNet)" : "Reduce Noise"
            case .sharpen: return "Sharpen"
            case .straighten: return "Straighten"
            }
        }
    }

    struct Issue: Identifiable {
        let id = UUID()
        var kind: Kind
        var severity: Severity
        var title: String
        var detail: String
        var fix: Fix?
    }

    enum Use: String, CaseIterable, Identifiable {
        case screen = "Screen / Web", social = "Social Media", print10x15 = "Print 10×15 cm", printA4 = "Print A4", printA3 = "Print A3"
        var id: String { rawValue }
        /// Pixels needed on the long and short side.
        var need: (Int, Int) {
            switch self {
            case .screen: return (1280, 720)
            case .social: return (1080, 1080)
            case .print10x15: return (1772, 1181)      // 300 ppi
            case .printA4: return (3508, 2480)
            case .printA3: return (4961, 3508)
            }
        }
    }

    struct Metrics {
        var width = 0, height = 0
        var blur: Double? = nil            // 0 sharp … 1 blurry
        var noise: Double = 0              // sigma in 8-bit levels
        var mean: Double = 0               // luminance 0…255
        var median: Double = 0
        var p1: Double = 0, p99: Double = 255
        var clipHigh: Double = 0, clipLow: Double = 0
        var saturation: Double = 0         // mean HSB saturation 0…1
        var castA: Double = 0, castB: Double = 0, cast: Double = 0   // Lab a/b of the cast, strength (0 when no reliable reference)
        var highlightChroma: Double = 0    // Lab chroma of the brightest pixels, whether or not they qualify as a white reference
        var wbTemperature: Double = 0, wbTint: Double = 0
        var blockiness: Double = 0
        var tiltDegrees: Double? = nil     // Vision angle (counter-clockwise positive)
        var faces = 0, closedEyes = 0, cutFaces = 0
    }

    struct Report {
        var metrics: Metrics
        var issues: [Issue]
        var seconds: Double
        func has(_ k: Kind) -> Bool { issues.contains { $0.kind == k } }
    }

    // MARK: Metrics

    /// No-reference blur metric (Crete et al., "The blur effect"): how little neighbouring-pixel variation is lost
    /// when the image is low-pass filtered. Evaluated per tile; the sharpest textured tiles decide, so shallow
    /// depth-of-field photos with a sharp subject are not flagged. 0 = sharp … 1 = blurry; nil when featureless.
    static func blurMetric(_ cg: CGImage, maxSide: Int = 1536) -> Double? {
        let s = min(1, Double(maxSide) / Double(max(cg.width, cg.height)))
        let w = max(8, Int(Double(cg.width) * s)), h = max(8, Int(Double(cg.height) * s))
        return blurMetric(Assist.luma(cg, w, h), w, h)
    }

    static func blurMetric(_ l: [Float], _ w: Int, _ h: Int) -> Double? {
        let tile = max(48, min(192, min(w, h) / 4))
        var vals: [(blur: Double, energy: Double)] = []
        var ty = 0
        while ty + tile <= h {
            var tx = 0
            while tx + tile <= w {
                if let v = creteTile(l, w, x0: tx, y0: ty, n: tile) { vals.append(v) }
                tx += tile
            }
            ty += tile
        }
        if vals.isEmpty, let v = creteTile(l, w, x0: 0, y0: 0, n: min(w, h)) { vals.append(v) }
        // textured tiles only (flat sky says nothing about focus)
        let textured = vals.filter { $0.energy > 1.2 }
        guard !textured.isEmpty else { return nil }
        let sorted = textured.map(\.blur).sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.2))]
    }

    private static func creteTile(_ l: [Float], _ w: Int, x0: Int, y0: Int, n: Int) -> (blur: Double, energy: Double)? {
        guard n >= 16 else { return nil }
        let k = 4      // 9-tap box
        var sFh: Float = 0, sVh: Float = 0, sFv: Float = 0, sVv: Float = 0
        var line = [Float](repeating: 0, count: n + 2 * k), prefix = [Float](repeating: 0, count: n + 2 * k + 1)
        let inv = 1 / Float(2 * k + 1)
        l.withUnsafeBufferPointer { p in
            for pass in 0..<2 {
                for a in 0..<n {
                    // one row (pass 0) or column (pass 1), edge-padded
                    for i in 0..<n { line[i + k] = pass == 0 ? p[(y0 + a) * w + x0 + i] : p[(y0 + i) * w + x0 + a] }
                    for i in 0..<k { line[i] = line[k]; line[n + k + i] = line[n + k - 1] }
                    var acc: Float = 0
                    for i in 0..<(n + 2 * k) { prefix[i] = acc; acc += line[i] }
                    prefix[n + 2 * k] = acc
                    var prevB = (prefix[2 * k + 1] - prefix[0]) * inv
                    var sF: Float = 0, sV: Float = 0
                    for i in 1..<n {
                        let bl = (prefix[i + 2 * k + 1] - prefix[i]) * inv
                        let dF = abs(line[i + k] - line[i + k - 1]), dB = abs(bl - prevB)
                        sF += dF; sV += max(0, dF - dB)
                        prevB = bl
                    }
                    if pass == 0 { sFh += sF; sVh += sV } else { sFv += sF; sVv += sV }
                }
            }
        }
        let count = Float(n * (n - 1))
        let energy = Double((sFh + sFv) / (2 * count))
        guard sFh > 0, sFv > 0 else { return (1, energy) }
        return (Double(max((sFh - sVh) / sFh, (sFv - sVv) / sFv)), energy)
    }

    /// Noise sigma (8-bit levels) after Immerkær's fast estimator, evaluated on the smoothest tiles.
    static func noiseSigma(_ lum: [Float], _ w: Int, _ h: Int) -> Double {
        let tile = 32
        var sig: [Double] = []
        lum.withUnsafeBufferPointer { l in
            var ty = 0
            while ty + tile <= h {
                var tx = 0
                while tx + tile <= w {
                    var s: Float = 0
                    var lo: Float = 255, hi: Float = 0
                    for y in 1..<(tile - 1) {
                        var i = (ty + y) * w + tx + 1
                        for _ in 1..<(tile - 1) {
                            let c = l[i]
                            lo = min(lo, c); hi = max(hi, c)
                            let v = l[i - w - 1] - 2 * l[i - w] + l[i - w + 1] - 2 * l[i - 1] + 4 * c - 2 * l[i + 1] + l[i + w - 1] - 2 * l[i + w] + l[i + w + 1]
                            s += abs(v)
                            i += 1
                        }
                    }
                    // clipped tiles (pure black / white) hide their noise
                    if lo > 6 && hi < 249 { sig.append((Double.pi / 2).squareRoot() * Double(s) / (6 * Double((tile - 2) * (tile - 2)))) }
                    tx += tile
                }
                ty += tile
            }
        }
        guard !sig.isEmpty else { return 0 }
        sig.sort()
        return sig[min(sig.count - 1, Int(Double(sig.count) * 0.15))]
    }

    /// JPEG blocking: luminance steps across the 8×8 grid relative to steps inside blocks (0 = none).
    static func blockiness(_ lum: [Float], _ w: Int, _ h: Int) -> Double {
        guard w >= 32, h >= 32 else { return 0 }
        var edge = 0.0, inner = 0.0
        var en = 0, inn = 0
        lum.withUnsafeBufferPointer { l in
            for y in 0..<h {
                var rowEdge: Float = 0, rowInner: Float = 0
                let base = y * w
                for x in 0..<(w - 1) {
                    let d = abs(l[base + x + 1] - l[base + x])
                    if x & 7 == 7 { rowEdge += d; en += 1 } else { rowInner += d; inn += 1 }
                }
                edge += Double(rowEdge); inner += Double(rowInner)
            }
            for y in 0..<(h - 1) {
                var rowSum: Float = 0
                let base = y * w
                for x in 0..<w { rowSum += abs(l[base + w + x] - l[base + x]) }
                if y & 7 == 7 { edge += Double(rowSum); en += w } else { inner += Double(rowSum); inn += w }
            }
        }
        guard en > 0, inn > 0, inner > 0 else { return 0 }
        return max(0, (edge / Double(en)) / (inner / Double(inn)) - 1)
    }

    /// Centre crop at native resolution (origin on the 8-pixel grid) for noise / blockiness.
    private static func nativeCrop(_ cg: CGImage, side: Int = 1024) -> (l: [Float], w: Int, h: Int) {
        let w = min(side, cg.width) / 8 * 8, h = min(side, cg.height) / 8 * 8
        guard w >= 16, h >= 16 else { return (Assist.luma(cg, cg.width, cg.height), cg.width, cg.height) }
        let x = (cg.width - w) / 2 / 8 * 8, y = (cg.height - h) / 2 / 8 * 8
        guard let c = cg.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else { return (Assist.luma(cg, w, h), w, h) }
        return (Assist.luma(c, w, h), w, h)
    }

    static func analyze(_ cg: CGImage, use: Use = .screen) -> Report {
        let t0 = CFAbsoluteTimeGetCurrent()
        var m = Metrics()
        m.width = cg.width; m.height = cg.height
        var issues: [Issue] = []

        // --- tone & colour statistics on a reduced copy
        let s = min(1, 512.0 / Double(max(cg.width, cg.height)))
        let sw = max(8, Int(Double(cg.width) * s)), sh = max(8, Int(Double(cg.height) * s))
        let px = Assist.rgba(cg, sw, sh)
        let n = sw * sh
        var hist = [Int](repeating: 0, count: 256)
        var lum = [Double](repeating: 0, count: n)
        var satSum = 0.0
        for i in 0..<n {
            let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            lum[i] = y
            hist[min(255, Int(y.rounded()))] += 1
            let mx = max(r, g, b), mn = min(r, g, b)
            satSum += mx > 0 ? (mx - mn) / mx : 0
        }
        m.saturation = satSum / Double(n)
        func pct(_ p: Double) -> Double {
            var acc = 0
            let target = Int(Double(n) * p)
            for i in 0..<256 { acc += hist[i]; if acc >= target { return Double(i) } }
            return 255
        }
        m.mean = lum.reduce(0, +) / Double(n)
        m.median = pct(0.5); m.p1 = pct(0.01); m.p99 = pct(0.99)
        m.clipHigh = Double(hist[252...255].reduce(0, +)) / Double(n)
        m.clipLow = Double(hist[0...3].reduce(0, +)) / Double(n)

        // colour cast: the brightest unclipped pixels (white objects, speculars, snow, paper) should be neutral.
        // Used only when those highlights share one tint (a mix of coloured highlights is no white reference),
        // so a scene that is simply blue or green overall is not reported.
        var hiThreshold = max(pct(0.97), 90)
        // when the very brightest pixels are clipped, use the band below them
        let unclipped = Int(hiThreshold) <= 249 ? hist[Int(hiThreshold)...249].reduce(0, +) : 0
        if Double(unclipped) < Double(n) * 0.006 { hiThreshold = max(pct(0.88), 90) }
        var hr = 0.0, hg = 0.0, hb = 0.0, hn = 0.0
        var ha = 0.0, hbb = 0.0, haa = 0.0, hb2 = 0.0
        func lin(_ v: Double) -> Double { pow(v / 255, 2.2) }
        for i in 0..<n {
            let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
            if lum[i] >= hiThreshold, max(r, g, b) < 250 {
                hr += lin(r); hg += lin(g); hb += lin(b); hn += 1
                let lab = RGBA(r: r / 255, g: g / 255, b: b / 255).lab
                ha += lab.a; hbb += lab.b; haa += lab.a * lab.a; hb2 += lab.b * lab.b
            }
        }
        if hn > Double(n) * 0.004 {
            let ma = ha / hn, mb = hbb / hn
            let spread = (max(0, haa / hn - ma * ma) + max(0, hb2 / hn - mb * mb)).squareRoot()
            let hiC = (ma * ma + mb * mb).squareRoot()
            m.highlightChroma = hiC
            if spread < max(9, hiC * 0.8) {
                m.cast = hiC
                m.castA = ma; m.castB = mb
                // gains that neutralise the highlights, expressed as Color ▸ Temperature / Tint
                let avg = (hr + hg + hb) / 3
                let kr = avg / max(1e-6, hr), kg = avg / max(1e-6, hg), kb = avg / max(1e-6, hb)
                m.wbTemperature = max(-100, min(100, log2(kr / kb) / 1.1 * 100))
                m.wbTint = max(-100, min(100, log2(kr * kb / (kg * kg)) / 0.86 * 100))
            }
        }

        // --- sharpness (long side ≤ 1536), noise and blockiness (native centre crop)
        m.blur = blurMetric(cg)
        let nat = nativeCrop(cg)
        m.noise = noiseSigma(nat.l, nat.w, nat.h)
        m.blockiness = blockiness(nat.l, nat.w, nat.h)

        // --- horizon and faces (Vision)
        if let a = AssistVision.horizon(cg) { m.tiltDegrees = a * 180 / .pi }
        let faces = AssistVision.faces(cg)
        m.faces = faces.count
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let margin = max(2, min(W, H) * 0.012)
        for f in faces {
            if f.eyesClosed { m.closedEyes += 1 }
            if f.box.minX < margin || f.box.minY < margin || f.box.maxX > W - margin || f.box.maxY > H - margin { m.cutFaces += 1 }
        }

        // --- issues
        if let b = m.blur {
            if b > 0.62 { issues.append(Issue(kind: .blur, severity: .problem, title: "Blurry", detail: String(format: "Blur score %.2f — no sharp detail anywhere in the frame.", b), fix: .sharpen(amount: 140, radius: 2.2))) }
            else if b > 0.47 { issues.append(Issue(kind: .blur, severity: .warning, title: "Soft", detail: String(format: "Blur score %.2f — slightly out of focus or upscaled.", b), fix: .sharpen(amount: 90, radius: 1.4))) }
        }
        if m.noise > 7 { issues.append(Issue(kind: .noise, severity: .problem, title: "Heavy noise", detail: String(format: "Noise σ ≈ %.1f levels.", m.noise), fix: .denoise)) }
        else if m.noise > 3.2 { issues.append(Issue(kind: .noise, severity: .warning, title: "Visible noise", detail: String(format: "Noise σ ≈ %.1f levels.", m.noise), fix: .denoise)) }
        if m.median < 62 && m.p99 < 225 {
            issues.append(Issue(kind: .underexposed, severity: m.median < 38 ? .problem : .warning, title: "Underexposed",
                                detail: String(format: "Median brightness %.0f%%.", m.median / 2.55), fix: m.p99 < 200 ? .levels : .brighten(min(0.22, (110 - m.median) / 400))))
        } else if m.median > 196 && m.p1 > 30 {
            issues.append(Issue(kind: .overexposed, severity: .warning, title: "Overexposed", detail: String(format: "Median brightness %.0f%%.", m.median / 2.55), fix: .brighten(-min(0.2, (m.median - 150) / 400))))
        }
        if m.p99 - m.p1 < 125 {
            issues.append(Issue(kind: .lowContrast, severity: .warning, title: "Low contrast", detail: String(format: "Tones only span %.0f–%.0f of 0–255.", m.p1, m.p99), fix: .levels))
        }
        if m.clipHigh > 0.03 { issues.append(Issue(kind: .clippedHighlights, severity: m.clipHigh > 0.1 ? .problem : .warning, title: "Clipped highlights", detail: String(format: "%.1f%% of pixels are blown out.", m.clipHigh * 100), fix: .recoverHighlights)) }
        if m.clipLow > 0.06 { issues.append(Issue(kind: .clippedShadows, severity: .warning, title: "Blocked shadows", detail: String(format: "%.1f%% of pixels are pure black.", m.clipLow * 100), fix: .liftShadows)) }
        if m.cast > 9 {
            let dir = abs(m.castB) > abs(m.castA) ? (m.castB > 0 ? "yellow / warm" : "blue / cool") : (m.castA > 0 ? "magenta" : "green")
            issues.append(Issue(kind: .colorCast, severity: m.cast > 18 ? .problem : .warning, title: "Colour cast (\(dir))",
                                detail: String(format: "Whites and highlights lean %@ (Lab chroma %.0f).", dir, m.cast),
                                fix: .whiteBalance(temperature: m.wbTemperature, tint: m.wbTint)))
        }
        if m.blockiness > 0.22 { issues.append(Issue(kind: .jpegBlocks, severity: m.blockiness > 0.5 ? .problem : .warning, title: "JPEG compression blocks", detail: String(format: "8×8 block edges are %.0f%% stronger than image detail.", m.blockiness * 100), fix: .denoise)) }
        let (needL, needS) = use.need
        let long = max(cg.width, cg.height), short = min(cg.width, cg.height)
        if long < needL || short < needS {
            let cmW = Double(cg.width) / 300 * 2.54, cmH = Double(cg.height) / 300 * 2.54
            issues.append(Issue(kind: .lowResolution, severity: long < needL / 2 ? .problem : .warning, title: "Low resolution for \(use.rawValue)",
                                detail: String(format: "%d×%d px; %@ needs about %d×%d. Prints %.1f×%.1f cm at 300 ppi.", cg.width, cg.height, use.rawValue, needL, needS, cmW, cmH), fix: nil))
        }
        if let t = m.tiltDegrees, abs(t) >= 0.8, abs(t) <= 20 {
            issues.append(Issue(kind: .tilted, severity: abs(t) > 3 ? .problem : .warning, title: "Tilted horizon", detail: String(format: "About %.1f° off level.", abs(t)), fix: .straighten(radians: -t * .pi / 180)))
        }
        if m.closedEyes > 0 { issues.append(Issue(kind: .closedEyes, severity: .warning, title: "Closed eyes", detail: "\(m.closedEyes) of \(m.faces) face\(m.faces == 1 ? "" : "s") seem to have closed eyes.", fix: nil)) }
        if m.cutFaces > 0 { issues.append(Issue(kind: .faceCut, severity: .warning, title: "Face cut off at the edge", detail: "\(m.cutFaces) face\(m.cutFaces == 1 ? " touches" : "s touch") the image border.", fix: nil)) }
        issues.sort { $0.severity.rawValue > $1.severity.rawValue }
        return Report(metrics: m, issues: issues, seconds: CFAbsoluteTimeGetCurrent() - t0)
    }

    // MARK: Fixes (non-destructive)

    static func adjustmentLayer(_ s: AdjustmentSettings, name: String, state: DocumentState, mask: PixelBuffer? = nil) -> Layer {
        var l = Layer(name: name, content: .adjustment(s))
        l.mask = mask.map { LayerMask(buffer: $0, origin: .zero, outsideValue: 0) } ?? LayerMask.reveal(width: state.width, height: state.height)
        return l
    }

    static func levelsSettings(_ m: Metrics) -> AdjustmentSettings {
        var s = AdjustmentSettings(kind: .levels)
        let lo = min(115, max(0, m.p1 - 1)), hi = max(lo + 30, min(255, m.p99 + 1))
        s.levels[0].inBlack = lo.rounded(); s.levels[0].inWhite = hi.rounded()
        let mid = (m.median - lo) / max(1, hi - lo)
        if mid > 0.05 && mid < 0.95 { s.levels[0].gamma = ((max(0.8, min(1.35, log(mid) / log(0.47))) * 100).rounded()) / 100 }
        return s
    }

    static func curveSettings(shift v: Double) -> AdjustmentSettings {
        var s = AdjustmentSettings(kind: .curves)
        s.curves[0].points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5 + v), CGPoint(x: 1, y: 1)]
        return s
    }

    static func lightSettings(_ p: [String: Double]) -> AdjustmentSettings {
        var s = AdjustmentSettings(kind: .light)
        s.params = p
        return s
    }

    static func wbSettings(temperature: Double, tint: Double, vibrance: Double = 0) -> AdjustmentSettings {
        var s = AdjustmentSettings(kind: .colorWB)
        s.params = ["temperature": temperature.rounded(), "tint": tint.rounded(), "vibrance": vibrance.rounded(), "saturation": 0]
        return s
    }

    /// Wraps a layer in an embedded smart object (keeps name, position and stacking order).
    static func smartObject(_ d: Document, _ id: UUID) -> UUID? {
        guard let l = d.state.layer(id) else { return nil }
        if l.isSmartObject { return id }
        guard let b0 = Compositor.shared.contentBounds(l, state: d.state) else { return nil }
        let fx = l.effects.extent
        let b = IRect(enclosing: b0.insetBy(dx: -CGFloat(fx), dy: -CGFloat(fx)))
        var inner = DocumentState(width: max(1, b.width), height: max(1, b.height), resolution: d.state.resolution)
        var moved = l
        moved.translate(dx: Double(-b.x), dy: Double(-b.y))
        moved.isClipped = false
        inner.layers = [moved]
        let so = SmartObjectContent(source: .document(inner), quad: Quad(rect: b.cgRect), sourceName: l.name)
        var nl = Layer(name: l.name, content: .smartObject(so))
        nl.isClipped = l.isClipped
        d.state.insertLayer(nl, above: id)
        d.state.removeLayer(id)
        if d.activeLayerID == id { d.activeLayerID = nl.id }
        d.selectedLayerIDs = [nl.id]
        return nl.id
    }

    /// The layer that pixel fixes (sharpen / denoise) apply to: the active image layer, else the largest one.
    static func imageLayer(_ d: Document) -> UUID? {
        if let a = d.activeLayer, a.isRaster || a.isSmartObject { return a.id }
        let imgs = d.state.allLayers.filter { ($0.isRaster || $0.isSmartObject) && $0.isVisible }
        return imgs.max { a, b in
            let ba = Compositor.shared.contentBounds(a, state: d.state) ?? .zero, bb = Compositor.shared.contentBounds(b, state: d.state) ?? .zero
            return ba.width * ba.height < bb.width * bb.height
        }?.id
    }

    /// Applies one fix as a single undo step. Returns a short description, or nil when it could not be applied.
    /// (`denoise` with NAFNet is asynchronous: use `applyDenoise`.)
    @discardableResult
    static func apply(_ fix: Fix, to d: Document, metrics m: Metrics) -> String? {
        func add(_ s: AdjustmentSettings, _ name: String) -> String {
            if let top = d.state.layers.last?.id { d.activeLayerID = top }
            let l = adjustmentLayer(s, name: name, state: d.state)
            d.state.layers.append(l)
            d.activeLayerID = l.id; d.selectedLayerIDs = [l.id]
            d.commit(name)
            return name
        }
        switch fix {
        case .levels: return add(levelsSettings(m), "Auto Levels")
        case .brighten(let v): return add(curveSettings(shift: v), v > 0 ? "Brighten" : "Darken")
        case .recoverHighlights: return add(lightSettings(["highlights": -45, "whites": -15]), "Recover Highlights")
        case .liftShadows: return add(lightSettings(["shadows": 40, "blacks": 12]), "Lift Shadows")
        case .whiteBalance(let t, let ti): return add(wbSettings(temperature: t, tint: ti), "White Balance")
        case .sharpen(let amount, let radius):
            guard let id = imageLayer(d), let sid = smartObject(d, id) else { return nil }
            var f = FilterInstance(kind: .unsharpMask)
            f.values["amount"] = amount; f.values["radius"] = radius
            d.updateLayer(sid) { $0.smart?.filters.append(f) }
            d.commit("Sharpen (Smart Filter)")
            return "Sharpen (Smart Filter)"
        case .denoise:
            guard let id = imageLayer(d), let sid = smartObject(d, id) else { return nil }
            var f = FilterInstance(kind: .reduceNoise)
            f.values["level"] = min(0.1, max(0.015, m.noise / 120)); f.values["sharpness"] = 0.5
            d.updateLayer(sid) { $0.smart?.filters.append(f) }
            d.commit("Reduce Noise (Smart Filter)")
            return "Reduce Noise (Smart Filter)"
        case .straighten(let r):
            let wasActive = AppModel.shared.activeDocumentID
            if AppModel.shared.documents.contains(where: { $0.id == d.id }) { AppModel.shared.activeDocumentID = d.id }
            let old = AppModel.shared.crop.deleteCropped
            AppModel.shared.crop.deleteCropped = false       // keep the pixels: Image ▸ Reveal All restores them
            StraightenCropTool.straighten(d, radians: CGFloat(r))
            AppModel.shared.crop.deleteCropped = old
            if let w = wasActive, AppModel.shared.documents.contains(where: { $0.id == w }) { AppModel.shared.activeDocumentID = w }
            return "Straighten"
        }
    }

    /// NAFNet denoise as a baked neural smart filter (falls back to the Reduce Noise smart filter).
    static func applyDenoise(to d: Document, metrics m: Metrics) async -> String? {
        guard Restoration.isAvailable(.denoise) else { return await Assist.onMain { apply(.denoise, to: d, metrics: m) } }
        let prep: (UUID, CGImage)? = await Assist.onMain {
            guard let id = imageLayer(d), let sid = smartObject(d, id), let l = d.state.layer(sid) else { return nil }
            let sp = CanvasSpace(width: d.state.width, height: d.state.height)
            guard let content = Compositor.shared.contentImage(l, space: sp), let cg = RenderEngine.cgImage(content, rect: sp.ciCanvas) else { return nil }
            return (sid, cg)
        }
        guard let (sid, cg) = prep else { return nil }
        let strength = min(1, max(0.6, m.noise / 8))
        guard let out = try? await Restoration.run(cg, .denoise, strength: strength) else {
            return await Assist.onMain { d.revertUncommitted(); return apply(.denoise, to: d, metrics: m) }
        }
        return await Assist.onMain {
            var f = FilterInstance(kind: .neuralFilter)
            f.values = ["assist.denoise": 1, "assist.strength": strength]
            f.payload = PixelBuffer(cgImage: out)
            d.updateLayer(sid) { $0.smart?.filters.append(f) }
            d.commit("Denoise (NAFNet Smart Filter)")
            d.setNeedsRender()
            return "Denoise (NAFNet Smart Filter)"
        }
    }

    // MARK: Auto Enhance

    /// One click: a group of adjustment layers (Levels, Color, Light) tuned from the analysis. One undo step.
    @discardableResult
    static func autoEnhance(_ d: Document, report r: Report) -> [String] {
        let m = r.metrics
        var layers: [Layer] = []
        var notes: [String] = []
        // gentler than the Levels fix: go 70% of the way to a full stretch, never crush a deliberately dark or bright picture
        var lv = AdjustmentSettings(kind: .levels)
        lv.levels[0].inBlack = min(40, (m.p1 * 0.5).rounded())
        lv.levels[0].inWhite = max(195, (255 - (255 - m.p99) * 0.5).rounded())
        let span = max(1, lv.levels[0].inWhite - lv.levels[0].inBlack)
        let mid = (m.median - lv.levels[0].inBlack) / span
        if mid > 0.05 && mid < 0.95 { lv.levels[0].gamma = ((max(0.9, min(1.25, log(mid) / log(0.45))) * 100).rounded()) / 100 }
        layers.append(adjustmentLayer(lv, name: "Enhance · Levels", state: d.state))
        notes.append("Levels \(Int(lv.levels[0].inBlack))–\(Int(lv.levels[0].inWhite)) γ\(String(format: "%.2f", lv.levels[0].gamma))")
        let vib = max(5, min(25, (0.42 - m.saturation) * 60))
        let wb = wbSettings(temperature: m.cast > 9 ? m.wbTemperature * 0.8 : 0, tint: m.cast > 9 ? m.wbTint * 0.8 : 0, vibrance: vib)
        layers.append(adjustmentLayer(wb, name: "Enhance · Color", state: d.state))
        notes.append("Color temp \(Int(wb.params["temperature"] ?? 0)) tint \(Int(wb.params["tint"] ?? 0)) vibrance +\(Int(vib))")
        var lp: [String: Double] = [:]
        if m.clipHigh > 0.01 || m.p99 > 250 { lp["highlights"] = -25 }
        if m.p1 < 12 || m.clipLow > 0.02 { lp["shadows"] = 22 }
        if m.p99 - m.p1 < 150 { lp["contrast"] = 12 }
        layers.append(adjustmentLayer(lightSettings(lp), name: "Enhance · Light", state: d.state))
        notes.append("Light " + (lp.isEmpty ? "neutral" : lp.sorted { $0.key < $1.key }.map { "\($0.key) \(AssistNaming.signed($0.value))" }.joined(separator: ", ")))
        var g = Layer(name: "Auto Enhance", content: .group(GroupContent(children: layers, isExpanded: true)))
        g.blendMode = .passThrough
        d.state.layers.append(g)
        d.activeLayerID = g.id; d.selectedLayerIDs = [g.id]
        d.commit("Auto Enhance")
        return notes
    }

    static func autoEnhanceAction() {
        guard let d = AppActions.doc, let cg = Assist.compositeCG(d.state) else { return }
        Assist.run("Auto Enhance: analysing…", { analyze(cg) }) { r in
            let notes = autoEnhance(d, report: r)
            AppModel.shared.showPanels = true
            AppModel.shared.setStatus("Auto Enhance added 3 adjustment layers (" + notes.joined(separator: "; ") + ").")
        }
    }
}

// MARK: - Dialog

@Observable
final class AssistQualityModel {
    var report: AssistQuality.Report?
    var use: AssistQuality.Use = .screen
    var running = false
    var applied: Set<UUID> = []
    var log: [String] = []

    func analyze() {
        guard let d = AppActions.doc, let cg = Assist.compositeCG(d.state) else { return }
        running = true
        let use = self.use
        Task.detached(priority: .userInitiated) {
            let r = AssistQuality.analyze(cg, use: use)
            await MainActor.run { self.report = r; self.running = false; self.applied = [] }
        }
    }

    func fix(_ i: AssistQuality.Issue) {
        guard let d = AppActions.doc, let r = report, let f = i.fix else { return }
        applied.insert(i.id)
        if f == .denoise {
            running = true
            Task.detached {
                let name = await AssistQuality.applyDenoise(to: d, metrics: r.metrics)
                await MainActor.run { self.running = false; self.log.append(name ?? "Denoise could not be applied"); self.analyze() }
            }
            return
        }
        if let name = AssistQuality.apply(f, to: d, metrics: r.metrics) { log.append(name) }
        analyze()
    }
}

struct AssistAnalyzeDialog: View {
    @State private var m: AssistQualityModel
    init(model: AssistQualityModel = AssistQualityModel()) { _m = State(initialValue: model) }

    var body: some View {
        DialogFrame(title: "Analyze Image", width: 440, okTitle: "Done", onOK: {}) {
            HStack {
                Picker("Intended use", selection: $m.use) { ForEach(AssistQuality.Use.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 260)
                    .onChange(of: m.use) { _, _ in m.analyze() }
                Spacer()
                if m.running { ProgressView().controlSize(.small) }
            }
            if let r = m.report {
                let x = r.metrics
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow { metric("Sharpness", x.blur.map { String(format: "%.0f%%", (1 - $0) * 100) } ?? "—"); metric("Noise σ", String(format: "%.1f", x.noise)) }
                    GridRow { metric("Brightness", String(format: "%.0f%%", x.median / 2.55)); metric("Tonal range", String(format: "%.0f–%.0f", x.p1, x.p99)) }
                    GridRow { metric("Clipping", String(format: "%.1f%% hi · %.1f%% lo", x.clipHigh * 100, x.clipLow * 100)); metric("Colour cast", String(format: "%.0f", x.cast)) }
                    GridRow { metric("Size", "\(x.width)×\(x.height)"); metric("Horizon", x.tiltDegrees.map { String(format: "%.1f°", $0) } ?? "—") }
                }
                Divider()
                if r.issues.isEmpty {
                    Label("No problems found.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(r.issues) { i in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle().fill(i.severity == .problem ? Color.red : (i.severity == .warning ? Color.orange : Color.gray)).frame(width: 8, height: 8).padding(.top, 4)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(i.title).font(Theme.fontBold)
                                        Text(i.detail).font(Theme.fontSmall).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    if let f = i.fix { Button(f.title) { m.fix(i) }.buttonStyle(PanelButtonStyle()).disabled(m.running) }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 230)
                }
                if !m.log.isEmpty { Text("Added: " + m.log.joined(separator: ", ")).font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
                HStack {
                    Button("Auto Enhance") {
                        if let d = AppActions.doc { m.log += ["Auto Enhance"]; AssistQuality.autoEnhance(d, report: r); m.analyze() }
                    }.buttonStyle(PanelButtonStyle()).help("Adds a group of adjustment layers (Levels, Color, Light) you can tweak")
                    Button("Re-analyze") { m.analyze() }.buttonStyle(PanelButtonStyle())
                    Spacer()
                    Text(String(format: "%.2f s", r.seconds)).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                }
                Text("Fixes are non-destructive: adjustment layers and smart filters, each a single undo step.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            } else {
                Text("Analysing…").foregroundStyle(Theme.textDim)
            }
        }
        .onAppear { if m.report == nil { m.analyze() } }
    }

    @ViewBuilder func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Theme.textDim).frame(width: 78, alignment: .leading)
            Text(value).font(Theme.mono)
        }
    }
}
