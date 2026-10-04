import Foundation
import CoreImage
import ImageCratCore


// MARK: - Kernels

enum AdjustmentKernels {
    /// Shared helper functions (CI kernel language). Identifiers avoid Metal reserved words.
    static let helpers = """
    vec3 lumenRgbToHsl(vec3 c) {
        float mx = max(max(c.r, c.g), c.b);
        float mn = min(min(c.r, c.g), c.b);
        float li = (mx + mn) * 0.5;
        float dd = mx - mn;
        float hu = 0.0;
        float sa = 0.0;
        if (dd > 0.00001) {
            sa = li > 0.5 ? dd / (2.0 - mx - mn) : dd / (mx + mn);
            if (mx == c.r) { hu = (c.g - c.b) / dd + (c.g < c.b ? 6.0 : 0.0); }
            else if (mx == c.g) { hu = (c.b - c.r) / dd + 2.0; }
            else { hu = (c.r - c.g) / dd + 4.0; }
            hu = hu / 6.0;
        }
        return vec3(hu, sa, li);
    }
    float lumenHueToRgb(float p, float q, float tIn) {
        float t = tIn - floor(tIn);
        if (t < 1.0 / 6.0) { return p + (q - p) * 6.0 * t; }
        if (t < 0.5) { return q; }
        if (t < 2.0 / 3.0) { return p + (q - p) * (2.0 / 3.0 - t) * 6.0; }
        return p;
    }
    vec3 lumenHslToRgb(vec3 hsl) {
        if (hsl.y <= 0.0) { return vec3(hsl.z); }
        float q = hsl.z < 0.5 ? hsl.z * (1.0 + hsl.y) : hsl.z + hsl.y - hsl.z * hsl.y;
        float p = 2.0 * hsl.z - q;
        return vec3(lumenHueToRgb(p, q, hsl.x + 1.0 / 3.0), lumenHueToRgb(p, q, hsl.x), lumenHueToRgb(p, q, hsl.x - 1.0 / 3.0));
    }
    float lumenSatAdj(float sa, float sv) { return sv >= 0.0 ? sa + (1.0 - sa) * sv * sqrt(max(sa, 0.0)) : sa * (1.0 + sv); }
    float lumenLightAdj(float li, float lv) { return lv >= 0.0 ? li + (1.0 - li) * lv : li * (1.0 + lv); }
    float lumenRangeW(float hdeg, vec4 r) {
        float x = mod(hdeg - r.x + 720.0, 360.0);
        if (x < r.y) { return x / max(r.y, 0.001); }
        if (x <= r.z) { return 1.0; }
        if (x < r.w) { return (r.w - x) / max(r.w - r.z, 0.001); }
        return 0.0;
    }
    vec3 lumenRgbToLab(vec3 c) {
        vec3 lin = mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
        vec3 v = vec3(dot(lin, vec3(0.4124, 0.3576, 0.1805)) / 0.95047,
                      dot(lin, vec3(0.2126, 0.7152, 0.0722)),
                      dot(lin, vec3(0.0193, 0.1192, 0.9505)) / 1.08883);
        vec3 f = mix(7.787 * v + 16.0 / 116.0, pow(max(v, vec3(0.0)), vec3(1.0 / 3.0)), step(0.008856, v));
        return vec3(116.0 * f.y - 16.0, 500.0 * (f.x - f.y), 200.0 * (f.y - f.z));
    }
    vec3 lumenLabToRgb(vec3 lab) {
        float fy = (lab.x + 16.0) / 116.0;
        vec3 f = vec3(fy + lab.y / 500.0, fy, fy - lab.z / 200.0);
        vec3 f3 = f * f * f;
        vec3 v = mix((f - 16.0 / 116.0) / 7.787, f3, step(0.008856, f3));
        v.x = v.x * 0.95047;
        v.z = v.z * 1.08883;
        vec3 lin = vec3(3.2406 * v.x - 1.5372 * v.y - 0.4986 * v.z,
                        -0.9689 * v.x + 1.8758 * v.y + 0.0415 * v.z,
                        0.0557 * v.x - 0.2040 * v.y + 1.0570 * v.z);
        lin = clamp(lin, 0.0, 1.0);
        return mix(lin * 12.92, 1.055 * pow(lin, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, lin));
    }
    """

    private static func make(_ src: String) -> CIColorKernel? {
        let k = CIColorKernel(source: helpers + "\n" + src)
        if k == nil { print("ImageCrat: failed to compile adjustment kernel") }
        return k
    }

    static let hueSat = make("""
    kernel vec4 lumenHueSat(__sample s, vec4 m, vec4 r0, vec4 r1, vec4 r2, vec4 r3, vec4 r4, vec4 r5,
                            vec3 a0, vec3 a1, vec3 a2, vec3 a3, vec3 a4, vec3 a5) {
        if (s.a <= 0.0) { return s; }
        vec3 c = clamp(s.rgb / s.a, 0.0, 1.0);
        vec3 hsl = lumenRgbToHsl(c);
        float hu = hsl.x;
        float sa = hsl.y;
        float li = hsl.z;
        if (m.w > 0.5) {
            hu = mod(m.x / 360.0 + 1.0, 1.0);
            sa = (m.y + 1.0) * 0.25;
            li = lumenLightAdj(li, m.z);
        } else {
            float hd = hu * 360.0;
            float chroma = max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b);
            float gate = clamp(chroma * 12.0, 0.0, 1.0);
            float w0 = lumenRangeW(hd, r0) * gate;
            float w1 = lumenRangeW(hd, r1) * gate;
            float w2 = lumenRangeW(hd, r2) * gate;
            float w3 = lumenRangeW(hd, r3) * gate;
            float w4 = lumenRangeW(hd, r4) * gate;
            float w5 = lumenRangeW(hd, r5) * gate;
            float dh = w0 * a0.x + w1 * a1.x + w2 * a2.x + w3 * a3.x + w4 * a4.x + w5 * a5.x;
            sa = lumenSatAdj(sa, w0 * a0.y); sa = lumenSatAdj(sa, w1 * a1.y); sa = lumenSatAdj(sa, w2 * a2.y);
            sa = lumenSatAdj(sa, w3 * a3.y); sa = lumenSatAdj(sa, w4 * a4.y); sa = lumenSatAdj(sa, w5 * a5.y);
            li = lumenLightAdj(li, w0 * a0.z); li = lumenLightAdj(li, w1 * a1.z); li = lumenLightAdj(li, w2 * a2.z);
            li = lumenLightAdj(li, w3 * a3.z); li = lumenLightAdj(li, w4 * a4.z); li = lumenLightAdj(li, w5 * a5.z);
            hu = hu + (m.x + dh) / 360.0;
            sa = lumenSatAdj(clamp(sa, 0.0, 1.0), m.y);
            li = lumenLightAdj(clamp(li, 0.0, 1.0), m.z);
        }
        vec3 o = lumenHslToRgb(vec3(hu - floor(hu), clamp(sa, 0.0, 1.0), clamp(li, 0.0, 1.0)));
        return vec4(o * s.a, s.a);
    }
    """)

    /// Color-distance mask. mode 0 = union (max), 1 = subtract.
    static let rcMask = make("""
    kernel vec4 lumenRCMask(__sample s, __sample prev, vec3 lab, float fuzz, float mode) {
        vec3 c = s.a > 0.0 ? clamp(s.rgb / s.a, 0.0, 1.0) : vec3(0.0);
        vec3 dl = lumenRgbToLab(c) - lab;
        float d = sqrt(dl.x * dl.x * 0.5 + dl.y * dl.y + dl.z * dl.z);
        float f = max(fuzz, 0.5);
        float m = 1.0 - smoothstep(f * 0.3, f, d);
        m = m * step(0.001, s.a);
        float o = mode < 0.5 ? max(prev.r, m) : min(prev.r, 1.0 - m);
        return vec4(o, o, o, 1.0);
    }
    """)

    static let rcApply = make("""
    kernel vec4 lumenRCApply(__sample s, __sample m, vec3 adj) {
        if (s.a <= 0.0) { return s; }
        vec3 c = clamp(s.rgb / s.a, 0.0, 1.0);
        vec3 hsl = lumenRgbToHsl(c);
        float hu = hsl.x + adj.x / 360.0;
        float sa = lumenSatAdj(hsl.y, adj.y);
        float li = lumenLightAdj(hsl.z, adj.z);
        vec3 o = lumenHslToRgb(vec3(hu - floor(hu), clamp(sa, 0.0, 1.0), clamp(li, 0.0, 1.0)));
        o = mix(c, o, clamp(m.r, 0.0, 1.0));
        return vec4(o * s.a, s.a);
    }
    """)

    /// Reinhard mean/std transfer in Lab. k = source std / target std; p = (luminance, intensity, fade, unused).
    static let matchColor = make("""
    kernel vec4 lumenMatch(__sample s, vec3 tm, vec3 k, vec3 sm, vec4 p) {
        if (s.a <= 0.0) { return s; }
        vec3 c = clamp(s.rgb / s.a, 0.0, 1.0);
        vec3 lab = lumenRgbToLab(c);
        vec3 o = (lab - tm) * k + sm;
        o.x = clamp(o.x * p.x, 0.0, 100.0);
        o.y = o.y * p.y;
        o.z = o.z * p.y;
        vec3 rgb = lumenLabToRgb(o);
        rgb = mix(rgb, c, p.z);
        return vec4(rgb * s.a, s.a);
    }
    """)

    /// Log luminance (r) and its square (g) of linearized color.
    static let hdrLog = make("""
    kernel vec4 lumenHDRLog(__sample s) {
        vec3 c = s.a > 0.0 ? clamp(s.rgb / s.a, 0.0, 1.0) : vec3(0.46);
        vec3 lin = pow(c, vec3(2.2));
        float y = dot(lin, vec3(0.2126, 0.7152, 0.0722));
        float lg = log(max(y, 0.0005));
        return vec4(lg, lg * lg, 0.0, 1.0);
    }
    """)

    /// Guided filter coefficients from (mean I, mean I²).
    static let guidedAB = make("""
    kernel vec4 lumenGuidedAB(__sample m, float eps) {
        float v = max(m.g - m.r * m.r, 0.0);
        float a = v / (v + eps);
        return vec4(a, m.r - a * m.r, 0.0, 1.0);
    }
    """)

    /// p = (compress | 1/gamma, detail gain, exposure (ln), anchor (ln)); q = (shadow, highlight, saturation factor, method).
    static let hdrFinal = make("""
    kernel vec4 lumenHDRFinal(__sample s, __sample li, __sample ab, vec4 p, vec4 q) {
        if (s.a <= 0.0) { return s; }
        vec3 c = clamp(s.rgb / s.a, 0.0, 1.0);
        vec3 lin = pow(c, vec3(2.2));
        float y = max(dot(lin, vec3(0.2126, 0.7152, 0.0722)), 0.0005);
        float ly = li.r;
        float yo = y;
        if (q.w < 0.5) {
            float base = ab.r * ly + ab.g;
            float det = ly - base;
            float outLog = (base - p.w) * p.x + p.w + det * p.y + p.z;
            yo = exp(outLog);
        } else if (q.w < 1.5) {
            yo = pow(y * exp(p.z), p.x);
        } else {
            float ye = y * exp(p.z);
            yo = ye * 2.0 / (1.0 + ye);
        }
        float g = pow(clamp(yo, 0.0, 1.0), 1.0 / 2.2);
        float om = 1.0 - g;
        g = g + q.x * 1.5 * g * om * om + q.y * 1.5 * g * g * om;
        g = clamp(g, 0.0, 1.0);
        float y2 = pow(g, 2.2);
        vec3 o = lin * (y2 / y);
        o = y2 + (o - y2) * q.z;
        float mx = max(max(o.r, o.g), o.b);
        if (mx > 1.0) { o = y2 + (o - y2) * clamp((1.0 - y2) / max(mx - y2, 0.0001), 0.0, 1.0); }
        o = pow(clamp(o, 0.0, 1.0), vec3(1.0 / 2.2));
        return vec4(o * s.a, s.a);
    }
    """)
}

// MARK: - Engine

extension AdjustmentEngine {
    /// Kernel implementation of Hue/Saturation with master + six editable ranges.
    static func applyHueSaturation(_ s: AdjustmentSettings, _ img: CIImage) -> CIImage? {
        guard let k = AdjustmentKernels.hueSat else { return nil }
        var args: [Any] = [img, CIVector(x: CGFloat(s.hue), y: CGFloat(s.hsSaturation / 100), z: CGFloat(s.lightness / 100), w: s.colorize ? 1 : 0)]
        let ranges = s.hsRanges.count == 6 ? s.hsRanges : HueRange.defaults
        for r in ranges { let n = r.normalized; args.append(CIVector(x: CGFloat(n.0), y: CGFloat(n.1), z: CGFloat(n.2), w: CGFloat(n.3))) }
        for r in ranges { args.append(CIVector(x: CGFloat(r.hue), y: CGFloat(r.saturation / 100), z: CGFloat(r.lightness / 100))) }
        return k.apply(extent: img.extent, arguments: args)
    }

    // MARK: Replace Color

    /// Grayscale (opaque) selection mask for Replace Color.
    static func replaceColorMask(_ r: ReplaceColorSettings, _ img: CIImage) -> CIImage {
        let ext = img.extent
        var mask = CIImage(color: .black).cropped(to: ext)
        guard let k = AdjustmentKernels.rcMask, !r.colors.isEmpty else { return mask }
        func pass(_ c: RGBA, _ mode: Float) {
            let lab = c.lab
            mask = k.apply(extent: ext, arguments: [img, mask, CIVector(x: CGFloat(lab.l), y: CGFloat(lab.a), z: CGFloat(lab.b)), Float(r.fuzziness), mode]) ?? mask
        }
        for c in r.colors { pass(c, 0) }
        if r.localized, !r.points.isEmpty {
            let R = max(4, r.rangePercent / 100 * r.canvasSize)
            var spatial: CIImage?
            for p in r.points {
                let g = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(x: p.x, y: p.y), "inputRadius0": R * 0.35, "inputRadius1": R,
                    "inputColor0": CIColor.white, "inputColor1": CIColor.black,
                ])!.outputImage!.cropped(to: ext)
                spatial = spatial.map { g.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? g
            }
            if let sp = spatial { mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: sp]).cropped(to: ext) }
        }
        for c in r.subtract { pass(c, 1) }
        return mask
    }

    static func applyReplaceColor(_ r: ReplaceColorSettings, _ img: CIImage) -> CIImage {
        guard !r.isIdentity, let k = AdjustmentKernels.rcApply else { return img }
        let m = replaceColorMask(r, img)
        return k.apply(extent: img.extent, arguments: [img, m, CIVector(x: CGFloat(r.hue), y: CGFloat(r.saturation / 100), z: CGFloat(r.lightness / 100))]) ?? img
    }

    /// CPU mirror of the HSL shift (result swatches).
    static func hslShift(_ c: RGBA, hue: Double, saturation: Double, lightness: Double) -> RGBA {
        var (h, s, l) = c.hsl
        h += hue / 360
        let sv = saturation / 100, lv = lightness / 100
        s = sv >= 0 ? s + (1 - s) * sv * s.squareRoot() : s * (1 + sv)
        l = lv >= 0 ? l + (1 - l) * lv : l * (1 + lv)
        return RGBA(h: h - floor(h), s: clamp(s, 0, 1), l: clamp(l, 0, 1))
    }

    // MARK: Match Color

    static func applyMatchColor(_ m: MatchColorSettings, _ img: CIImage) -> CIImage {
        guard let k = AdjustmentKernels.matchColor, let t = m.target else { return img }
        var src = m.source ?? t
        if m.neutralize { src.mean[1] = 0; src.mean[2] = 0 }
        let identity = m.source == nil && !m.neutralize && m.luminance == 100 && m.intensity == 100
        if identity || m.fade >= 100 { return img }
        func ratio(_ i: Int) -> CGFloat { CGFloat(clamp(src.std[i] / max(0.5, t.std[i]), 0.2, 5)) }
        return k.apply(extent: img.extent, arguments: [
            img,
            CIVector(x: CGFloat(t.mean[0]), y: CGFloat(t.mean[1]), z: CGFloat(t.mean[2])),
            CIVector(x: ratio(0), y: ratio(1), z: ratio(2)),
            CIVector(x: CGFloat(src.mean[0]), y: CGFloat(src.mean[1]), z: CGFloat(src.mean[2])),
            CIVector(x: CGFloat(m.luminance / 100), y: CGFloat(m.intensity / 100), z: CGFloat(m.fade / 100), w: 0),
        ]) ?? img
    }

    // MARK: HDR Toning

    static func applyHDRToning(_ h: HDRToningSettings, _ img: CIImage) -> CIImage {
        guard let logK = AdjustmentKernels.hdrLog, let abK = AdjustmentKernels.guidedAB, let fin = AdjustmentKernels.hdrFinal else { return img }
        let ext = img.extent
        let li = logK.apply(extent: ext, arguments: [img]) ?? img
        let method: Float
        var ab = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: ext)
        var p = CIVector(x: 1, y: 1, z: 0, w: 0)
        switch h.method {
        case .localAdaptation:
            method = 0
            // Guided filter on log luminance (self-guided) → edge-aware base layer.
            let sigma = max(0.5, h.radius / 2)
            let mean = li.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: ext)
            let eps = pow(max(0.02, h.strength) * 0.35, 2)
            let coeff = abK.apply(extent: ext, arguments: [mean, Float(eps)]) ?? mean
            ab = coeff.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: ext)
            let compress = pow(0.55, h.gamma)
            p = CIVector(x: CGFloat(compress), y: CGFloat(1 + h.detail / 100), z: CGFloat(h.exposure * log(2.0)), w: CGFloat(log(0.55)))
        case .exposureGamma:
            method = 1
            p = CIVector(x: CGFloat(1 / max(0.1, h.gamma)), y: 1, z: CGFloat(h.exposure * log(2.0)), w: 0)
        case .highlightCompression:
            method = 2
            p = CIVector(x: 1, y: 1, z: 0, w: 0)
        }
        let local = h.method == .localAdaptation
        let q = CIVector(x: CGFloat(local ? h.shadow / 100 : 0), y: CGFloat(local ? h.highlight / 100 : 0),
                         z: CGFloat(local ? 1 + h.saturation / 100 : 1), w: CGFloat(method))
        var out = fin.apply(extent: ext, arguments: [img, li, ab, p, q]) ?? img
        if local && h.useCurve && !h.curve.isIdentity {
            let lut = h.curve.lut(256)
            var floats = [Float](repeating: 0, count: 256 * 3)
            for i in 0..<256 { for c in 0..<3 { floats[i * 3 + c] = Float(lut[i]) } }
            out = out.applyingFilter("CIColorCurves", parameters: [
                "inputCurvesData": floats.withUnsafeBufferPointer { Data(buffer: $0) },
                "inputCurvesDomain": CIVector(x: 0, y: 1), "inputColorSpace": sRGBSpace,
            ])
        }
        if local && h.vibrance != 0 { out = out.applyingFilter("CIVibrance", parameters: ["inputAmount": h.vibrance / 100]) }
        return out.cropped(to: ext)
    }
}

// MARK: - Statistics

enum ColorStats {
    /// Lab mean / std of an image (downsampled CPU pass over pixels with alpha ≥ 50%).
    static func lab(_ img: CIImage, maxSide: CGFloat = 200) -> LabStats? {
        let ext = img.extent
        guard !ext.isEmpty, !ext.isInfinite else { return nil }
        let sc = min(1, maxSide / max(ext.width, ext.height))
        let small = img.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY).scaledBy(x: sc, y: sc))
        let w = max(1, Int(ext.width * sc)), h = max(1, Int(ext.height * sc))
        let buf = PixelBuffer(width: w, height: h)
        RenderEngine.readbackContext.render(small.composited(over: CIImage.clearImage.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))),
                                            toBitmap: buf.data, rowBytes: buf.bytesPerRow, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                            format: .RGBA8, colorSpace: sRGBSpace)
        let px = buf.data.assumingMemoryBound(to: UInt8.self)
        var sum = [0.0, 0.0, 0.0], sq = [0.0, 0.0, 0.0], n = 0.0
        for y in 0..<h {
            let row = px + y * buf.bytesPerRow
            for x in 0..<w {
                let a = Double(row[x * 4 + 3])
                guard a >= 128 else { continue }
                let c = RGBA(r: Double(row[x * 4]) / a, g: Double(row[x * 4 + 1]) / a, b: Double(row[x * 4 + 2]) / a).lab
                let v = [c.l, c.a, c.b]
                for i in 0..<3 { sum[i] += v[i]; sq[i] += v[i] * v[i] }
                n += 1
            }
        }
        guard n > 0 else { return nil }
        let mean = sum.map { $0 / n }
        let std = (0..<3).map { sqrt(max(0, sq[$0] / n - mean[$0] * mean[$0])) }
        return LabStats(mean: mean, std: std)
    }
}

// MARK: - Levels / Curves eyedroppers

enum DropperKind: String, CaseIterable { case black, gray, white }

enum AdjustmentDroppers {
    /// Photoshop-style Levels eyedropper: black/white set per-channel input points, gray neutralizes via per-channel gamma.
    static func applyLevels(_ k: DropperKind, color c: RGBA, to s: inout AdjustmentSettings) {
        let comps = [c.r, c.g, c.b].map { s.levels[0].apply(clamp($0, 0, 1)) }   // after master
        switch k {
        case .black:
            for i in 0..<3 {
                var ch = s.levels[i + 1]
                ch.inBlack = clamp((comps[i] * 255).rounded(), 0, 253)
                if ch.inWhite < ch.inBlack + 2 { ch.inWhite = min(255, ch.inBlack + 2) }
                s.levels[i + 1] = ch
            }
        case .white:
            for i in 0..<3 {
                var ch = s.levels[i + 1]
                ch.inWhite = clamp((comps[i] * 255).rounded(), 2, 255)
                if ch.inBlack > ch.inWhite - 2 { ch.inBlack = max(0, ch.inWhite - 2) }
                s.levels[i + 1] = ch
            }
        case .gray:
            // Reset channel gammas, then solve for gammas that map every channel onto the sample's luminance.
            for i in 0..<3 { s.levels[i + 1].gamma = 1 }
            let outs = (0..<3).map { s.levels[$0 + 1].apply(comps[$0]) }
            let target = AdjustmentEngine.lum(outs[0], outs[1], outs[2])
            for i in 0..<3 {
                let ch = s.levels[i + 1]
                let t = clamp((comps[i] * 255 - ch.inBlack) / max(1, ch.inWhite - ch.inBlack), 0.001, 0.999)
                let u = clamp((target * 255 - ch.outBlack) / max(1, ch.outWhite - ch.outBlack), 0.001, 0.999)
                s.levels[i + 1].gamma = clamp(log(t) / log(u), 0.1, 9.99)
            }
        }
    }

    /// Curves eyedropper: moves the per-channel end points (black/white) or adds a neutralizing point (gray).
    static func applyCurves(_ k: DropperKind, color c: RGBA, to s: inout AdjustmentSettings) {
        let master = s.curves[0].lut(256)
        func m(_ v: Double) -> Double { master[Int((clamp(v, 0, 1) * 255).rounded())] }
        let comps = [m(c.r), m(c.g), m(c.b)]
        switch k {
        case .black:
            for i in 0..<3 {
                let x = min(comps[i], 0.98)
                var pts = s.curves[i + 1].points.filter { $0.x > x + 0.01 }
                pts.insert(CGPoint(x: x, y: 0), at: 0)
                if pts.count < 2 { pts.append(CGPoint(x: 1, y: 1)) }
                s.curves[i + 1].points = pts
            }
        case .white:
            for i in 0..<3 {
                let x = max(comps[i], 0.02)
                var pts = s.curves[i + 1].points.filter { $0.x < x - 0.01 }
                pts.append(CGPoint(x: x, y: 1))
                if pts.count < 2 { pts.insert(CGPoint(x: 0, y: 0), at: 0) }
                s.curves[i + 1].points = pts
            }
        case .gray:
            let outs = (0..<3).map { i -> Double in
                let l = s.curves[i + 1].lut(256)
                return l[Int((clamp(comps[i], 0, 1) * 255).rounded())]
            }
            let target = AdjustmentEngine.lum(outs[0], outs[1], outs[2])
            for i in 0..<3 {
                let x = comps[i]
                var pts = s.curves[i + 1].points
                let first = pts.map(\.x).min() ?? 0, last = pts.map(\.x).max() ?? 1
                guard x > first + 0.01, x < last - 0.01 else { continue }
                pts.removeAll { abs($0.x - x) < 0.03 && $0.x > first && $0.x < last }
                pts.append(CGPoint(x: x, y: clamp(target, 0.01, 0.99)))
                pts.sort { $0.x < $1.x }
                s.curves[i + 1].points = pts
            }
        }
    }

    /// Auto (per-channel clip) for Curves.
    static func autoCurves(_ hist: [[Int]], _ s: inout AdjustmentSettings) {
        guard hist.count >= 3 else { return }
        for c in 0..<3 {
            let (lo, hi) = Histogram.clipPoints(hist[c], clip: 0.001)
            s.curves[c + 1].points = [CGPoint(x: Double(lo) / 255, y: 0), CGPoint(x: Double(hi) / 255, y: 1)]
        }
    }
}

// MARK: - Canvas sampling helpers

enum AdjustmentSampling {
    /// Average color of a (2r+1)² patch of `img` (CI space) around doc point `p`. Unpremultiplied.
    static func read(_ img: CIImage, space sp: CanvasSpace, at p: CGPoint, radius: Int = 1) -> RGBA? {
        let x = Int(floor(p.x)), y = Int(floor(p.y))
        guard x >= 0, y >= 0, x < sp.width, y < sp.height else { return nil }
        let r = IRect(x: x - radius, y: y - radius, width: radius * 2 + 1, height: radius * 2 + 1)
        let buf = PixelBuffer(width: r.width, height: r.height)
        RenderEngine.render(img, into: buf, docOrigin: r.origin, space: sp)
        var sum = [0.0, 0.0, 0.0, 0.0]
        for yy in 0..<r.height {
            for xx in 0..<r.width {
                let px = buf.pixel(xx, yy)
                sum[0] += Double(px.0); sum[1] += Double(px.1); sum[2] += Double(px.2); sum[3] += Double(px.3)
            }
        }
        guard sum[3] > 0 else { return nil }
        return RGBA(r: min(1, sum[0] / sum[3]), g: min(1, sum[1] / sum[3]), b: min(1, sum[2] / sum[3]), a: sum[3] / Double(r.width * r.height) / 255)
    }

    /// Composite without live previews; an active adjustment layer is excluded (samples what lies beneath it).
    static func compositeColor(_ d: Document, at p: CGPoint, radius: Int = 1) -> RGBA? {
        var hidden = d.hiddenLayers
        if let l = d.activeLayer, l.isAdjustment { hidden.insert(l.id) }
        let img = Compositor.shared.composite(d.state, options: Compositor.Options(hidden: hidden))
        return read(img, space: AppActions.space(d), at: p, radius: radius)
    }

    /// Active layer content (no previews).
    static func layerColor(_ d: Document, at p: CGPoint, radius: Int = 1) -> RGBA? {
        guard let l = d.activeLayer else { return nil }
        let sp = AppActions.space(d)
        guard let img = Compositor.shared.contentImage(l, space: sp) else { return nil }
        return read(img, space: sp, at: p, radius: radius)
    }

    /// Active layer content image (no previews), or the composite for non-pixel layers.
    static func activeContent(_ d: Document) -> CIImage {
        let sp = AppActions.space(d)
        if let l = d.activeLayer, !l.isAdjustment, !l.isGroup, let img = Compositor.shared.contentImage(l, space: sp) { return img }
        return Compositor.shared.composite(d.state, options: Compositor.Options(hidden: d.hiddenLayers))
    }
}
