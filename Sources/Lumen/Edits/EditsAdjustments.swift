import SwiftUI
import CoreImage
import ImageCratCore

// MARK: - Camera Raw style adjustment kinds: Color (white balance), Clarity, Dehaze, Grain, Light
//
// Their settings are stored in `AdjustmentSettings.params` (a [String: Double] dictionary), so old documents
// decode unchanged and new sliders can be added without touching the shared settings struct.


struct EditsParam {
    let key: String
    let label: String
    let range: ClosedRange<Double>
    var def: Double = 0
    var step: Double? = nil
    var format: String = "%.0f"
    var unit: String = ""
}

enum EditsAdjustments {
    static func params(_ k: AdjustmentKind) -> [EditsParam] {
        switch k {
        case .colorWB: return [
            EditsParam(key: "temperature", label: "Temperature", range: -100...100),
            EditsParam(key: "tint", label: "Tint", range: -100...100),
            EditsParam(key: "vibrance", label: "Vibrance", range: -100...100),
            EditsParam(key: "saturation", label: "Saturation", range: -100...100)]
        case .clarity: return [
            EditsParam(key: "amount", label: "Clarity", range: -100...100),
            EditsParam(key: "radius", label: "Radius", range: 2...200, def: 24, unit: " px")]
        case .dehaze: return [
            EditsParam(key: "amount", label: "Dehaze", range: -100...100),
            EditsParam(key: "radius", label: "Radius", range: 1...60, def: 8, unit: " px")]
        case .grain: return [
            EditsParam(key: "amount", label: "Amount", range: 0...100, def: 25),
            EditsParam(key: "size", label: "Size", range: 0...100, def: 25),
            EditsParam(key: "roughness", label: "Roughness", range: 0...100, def: 50),
            EditsParam(key: "seed", label: "Seed", range: 0...99, def: 0)]
        case .light: return [
            EditsParam(key: "exposure", label: "Exposure", range: -5...5, step: 0.01, format: "%.2f"),
            EditsParam(key: "contrast", label: "Contrast", range: -100...100),
            EditsParam(key: "highlights", label: "Highlights", range: -100...100),
            EditsParam(key: "shadows", label: "Shadows", range: -100...100),
            EditsParam(key: "whites", label: "Whites", range: -100...100),
            EditsParam(key: "blacks", label: "Blacks", range: -100...100)]
        default: return []
        }
    }

    static func value(_ s: AdjustmentSettings, _ key: String) -> Double {
        s.params[key] ?? params(s.kind).first { $0.key == key }?.def ?? 0
    }

    // MARK: Engine

    static func apply(_ s: AdjustmentSettings, _ img: CIImage) -> CIImage {
        let ext = img.extent
        guard !ext.isEmpty, !ext.isInfinite else { return img }
        func v(_ k: String) -> Double { value(s, k) }
        switch s.kind {
        case .colorWB: return color(img, temperature: v("temperature"), tint: v("tint"), vibrance: v("vibrance"), saturation: v("saturation"))
        case .clarity: return clarity(img, amount: v("amount"), radius: v("radius"))
        case .dehaze: return dehaze(img, amount: v("amount"), radius: v("radius"))
        case .grain: return grain(img, amount: v("amount"), size: v("size"), roughness: v("roughness"), seed: v("seed"))
        case .light: return light(img, exposure: v("exposure"), contrast: v("contrast"), highlights: v("highlights"), shadows: v("shadows"),
                                  whites: v("whites"), blacks: v("blacks"))
        default: return img
        }
    }

    /// White-balance channel gains (linear light) for Temperature / Tint in −100…100, normalized to keep white's luminance.
    static func wbGains(temperature t: Double, tint m: Double) -> (Double, Double, Double) {
        let tt = t / 100, mm = m / 100
        var r = pow(2, 0.55 * tt), b = pow(2, -0.55 * tt)
        var g = pow(2, -0.35 * mm)
        r *= pow(2, 0.08 * mm); b *= pow(2, 0.08 * mm)
        let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
        r /= l; g /= l; b /= l
        return (r, g, b)
    }

    static let wbKernel = CIColorKernel(source: """
    kernel vec4 editsWB(__sample s, vec3 gain) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        vec3 lin = pow(max(c, vec3(0.0)), vec3(2.2)) * gain;
        vec3 o = pow(lin, vec3(1.0 / 2.2));
        return vec4(clamp(o, 0.0, 1.0) * s.a, s.a);
    }
    """)

    static func color(_ img: CIImage, temperature: Double, tint: Double, vibrance: Double, saturation: Double) -> CIImage {
        var out = img
        if temperature != 0 || tint != 0, let k = wbKernel {
            let g = wbGains(temperature: temperature, tint: tint)
            out = k.apply(extent: img.extent, arguments: [out, CIVector(x: CGFloat(g.0), y: CGFloat(g.1), z: CGFloat(g.2))]) ?? out
        }
        if vibrance != 0 { out = out.applyingFilter("CIVibrance", parameters: ["inputAmount": vibrance / 100]) }
        if saturation != 0 { out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + saturation / 100]) }
        return out.cropped(to: img.extent)
    }

    // Self-guided filter (He et al. 2010) on luminance: an edge-preserving base layer, so local-contrast tools don't halo.
    static let lumaMomentsKernel = CIColorKernel(source: """
    kernel vec4 editsLumaMoments(__sample s) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        float l = dot(c, vec3(0.299, 0.587, 0.114));
        return vec4(l, l * l, 0.0, 1.0);
    }
    """)
    static let guidedABKernel = CIColorKernel(source: """
    kernel vec4 editsGuidedAB(__sample m, float eps) {
        float v = max(m.g - m.r * m.r, 0.0);
        float a = v / (v + eps);
        return vec4(a, m.r - a * m.r, 0.0, 1.0);
    }
    """)
    static let guidedOutKernel = CIColorKernel(source: """
    kernel vec4 editsGuidedOut(__sample s, __sample ab) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        float l = dot(c, vec3(0.299, 0.587, 0.114));
        float q = ab.r * l + ab.g;
        return vec4(q, q, q, 1.0);
    }
    """)

    /// Edge-preserving smoothed luminance (gray image) of `img`.
    static func guidedLuma(_ img: CIImage, radius: Double, eps: Double) -> CIImage {
        let ext = img.extent
        guard let mk = lumaMomentsKernel, let abk = guidedABKernel, let ok = guidedOutKernel else {
            return img.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: ext)
        }
        let m = (mk.apply(extent: ext, arguments: [img]) ?? img).clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: ext)
        let ab = (abk.apply(extent: ext, arguments: [m, Float(eps)]) ?? m).clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: ext)
        return ok.apply(extent: ext, arguments: [img, ab]) ?? m
    }

    // Clarity: local (mid-frequency) luminance contrast, weighted to the midtones.
    static let clarityKernel = CIColorKernel(source: """
    kernel vec4 editsClarityB(__sample s, __sample b, float amt) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        vec3 wts = vec3(0.299, 0.587, 0.114);
        float lum = dot(c, wts);
        float lumB = b.r;
        float t = 2.0 * lum - 1.0;
        float mid = clamp(1.0 - t * t, 0.0, 1.0);
        float detail = lum - lumB;
        // Strong edges are rolled off so they don't halo; texture-scale detail gets the full boost.
        float e = detail / 0.2;
        detail = detail / (1.0 + e * e);
        float d = amt >= 0.0 ? detail * amt * mid : detail * amt * (0.35 + 0.65 * mid);
        vec3 o = c + vec3(d);
        return vec4(clamp(o, 0.0, 1.0) * s.a, s.a);
    }
    """)

    static func clarity(_ img: CIImage, amount: Double, radius: Double) -> CIImage {
        guard amount != 0, let k = clarityKernel else { return img }
        let ext = img.extent
        let blur = guidedLuma(img, radius: max(1, radius), eps: amount >= 0 ? 0.004 : 0.03)
        let amt = amount >= 0 ? amount / 100 * 2.2 : amount / 100
        return k.apply(extent: ext, arguments: [img, blur, Float(amt)]) ?? img
    }

    // Dehaze: dark channel prior (He et al. 2009) with a blurred min-filter transmission estimate.
    static let darkChannelKernel = CIColorKernel(source: """
    kernel vec4 editsDark(__sample s) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(1.0);
        float d = min(c.r, min(c.g, c.b));
        return vec4(d, d, d, 1.0);
    }
    """)

    static let dehazeKernel = CIColorKernel(source: """
    kernel vec4 editsDehaze(__sample s, __sample dk, __sample am, float amt) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        float A = clamp(am.r, 0.55, 1.0);
        vec3 o;
        if (amt >= 0.0) {
            float t = max(1.0 - amt * 0.95 * dk.r / A, 0.12);
            o = (c - vec3(A)) / t + vec3(A);
        } else {
            float h = -amt;
            float depth = 0.45 + 0.55 * clamp(dk.r / A, 0.0, 1.0);
            o = mix(c, vec3(A), h * 0.75 * depth);
        }
        return vec4(clamp(o, 0.0, 1.0) * s.a, s.a);
    }
    """)

    static func dehaze(_ img: CIImage, amount: Double, radius: Double) -> CIImage {
        guard amount != 0, let dk = darkChannelKernel, let hk = dehazeKernel else { return img }
        let ext = img.extent
        let dark = dk.apply(extent: ext, arguments: [img]) ?? img
        let r = max(1, radius)
        let minF = dark.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r])
            .applyingGaussianBlur(sigma: r * 1.5).cropped(to: ext)
        // Atmospheric light: brightest value of the (filtered) dark channel.
        let amax = minF.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: ext)]).clampedToExtent()
        return hk.apply(extent: ext, arguments: [img, minF, amax, Float(amount / 100)]) ?? img
    }

    // Grain: deterministic (canvas-anchored) monochrome noise, strongest in the midtones.
    static let grainKernel = CIColorKernel(source: """
    kernel vec4 editsGrain(__sample s, __sample n, float amt) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        float lum = dot(c, vec3(0.299, 0.587, 0.114));
        float w = 0.3 + 0.7 * 4.0 * lum * (1.0 - lum);
        float g = (n.r - 0.5) * 2.0 * amt * w;
        return vec4(clamp(c + vec3(g), 0.0, 1.0) * s.a, s.a);
    }
    """)

    /// Noise field (R channel ≈ uniform 0…1 around 0.5) for grain of `size` 0…100, `roughness` 0…100.
    static func grainNoise(size: Double, roughness: Double, seed: Double, extent: CGRect) -> CIImage {
        let base = CIFilter(name: "CIRandomGenerator")!.outputImage!
        let sd = Int(seed.rounded())
        let seeded = base.transformed(by: CGAffineTransform(translationX: CGFloat((sd * 7919) % 4096), y: CGFloat((sd * 104729) % 4096)))
        let k = 1 + size / 100 * 2.2
        // Two octaves: coarse grains of size k and fine grit; roughness mixes in the fine octave.
        let coarse = seeded.transformed(by: CGAffineTransform(scaleX: CGFloat(k), y: CGFloat(k)))
            .applyingGaussianBlur(sigma: 0.35 * k)
        let fine = seeded.transformed(by: CGAffineTransform(translationX: 1731, y: 911))
        let rough = roughness / 100
        // Blurred noise loses contrast: re-expand around 0.5.
        let gainC = min(4, 0.7 + 0.55 * k)
        let c2 = coarse.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(gainC * (1 - rough * 0.6)), y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: CGFloat(0.5 - 0.5 * gainC * (1 - rough * 0.6)), y: 0, z: 0, w: 0)])
        let f2 = fine.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(rough * 0.6), y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: CGFloat(-0.5 * rough * 0.6), y: 0, z: 0, w: 0)])
        return f2.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: c2]).cropped(to: extent)
    }

    static func grain(_ img: CIImage, amount: Double, size: Double, roughness: Double, seed: Double) -> CIImage {
        guard amount > 0, let k = grainKernel else { return img }
        let ext = img.extent
        let n = grainNoise(size: size, roughness: roughness, seed: seed, extent: ext)
        return k.apply(extent: ext, arguments: [img, n, Float(amount / 100 * 0.22)]) ?? img
    }

    // Light: Camera Raw's Light panel. Highlights / Shadows use a blurred luminance so they act locally.
    static let lightKernel = CIColorKernel(source: """
    kernel vec4 editsLightB(__sample s, __sample bl, float ev, float con, float hi, float sh, float wh, float bk) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        float gainE = exp2(ev);
        c = pow(pow(max(c, vec3(0.0)), vec3(2.2)) * gainE, vec3(1.0 / 2.2));
        vec3 wts = vec3(0.299, 0.587, 0.114);
        float lum = dot(c, wts);
        float lumB = clamp(bl.r * exp2(ev / 2.2), 0.0, 1.0);
        float n = clamp(lum, 0.0, 1.0);
        if (con >= 0.0) { n = mix(n, n * n * (3.0 - 2.0 * n), con); } else { n = mix(n, 0.5 + (n - 0.5) * 0.45, -con); }
        // Mix local and pixel luminance for the tonal masks: local enough to recover detail, without big halos.
        float lw = mix(lum, lumB, 0.7);
        float wH = smoothstep(0.35, 0.95, lw);
        float bellH = clamp((n - 0.3) / 0.6, 0.0, 1.0) * (1.0 - 0.7 * smoothstep(0.75, 1.0, n));
        n += hi * (hi >= 0.0 ? 0.3 : 0.24) * wH * bellH * (hi >= 0.0 ? (1.0 - n) * 1.6 : 1.0);
        float wS = 1.0 - smoothstep(0.05, 0.65, lw);
        float bellS = clamp((0.7 - n) / 0.7, 0.0, 1.0) * (0.5 + 0.5 * smoothstep(0.0, 0.15, n));
        n += sh * (sh >= 0.0 ? 0.3 : 0.3) * wS * bellS * (sh >= 0.0 ? 1.0 : n * 2.0);
        n += wh * 0.2 * smoothstep(0.5, 1.0, n);
        n += bk * 0.15 * (1.0 - smoothstep(0.0, 0.5, n));
        n = clamp(n, 0.0, 1.0);
        vec3 o = lum > 0.002 ? c * (n / lum) : c + vec3(n - lum);
        float mx = max(o.r, max(o.g, o.b));
        if (mx > 1.0) { o = vec3(n) + (o - vec3(n)) * clamp((1.0 - n) / max(mx - n, 0.0001), 0.0, 1.0); }
        return vec4(clamp(o, 0.0, 1.0) * s.a, s.a);
    }
    """)

    static func light(_ img: CIImage, exposure: Double, contrast: Double, highlights: Double, shadows: Double, whites: Double, blacks: Double) -> CIImage {
        guard exposure != 0 || contrast != 0 || highlights != 0 || shadows != 0 || whites != 0 || blacks != 0, let k = lightKernel else { return img }
        let ext = img.extent
        let radius = max(4, Double(max(ext.width, ext.height)) * 0.03)
        let blur = guidedLuma(img, radius: radius, eps: 0.05)
        return k.apply(extent: ext, arguments: [img, blur, Float(exposure), Float(contrast / 100), Float(highlights / 100), Float(shadows / 100),
                                                Float(whites / 100), Float(blacks / 100)]) ?? img
    }
}

// MARK: - Properties controls

struct EditsAdjustmentControls: View {
    @Binding var s: AdjustmentSettings
    var onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if s.kind == .colorWB {
                HStack {
                    Menu("White Balance") {
                        Button("As Shot") { set(["temperature": 0, "tint": 0]) }
                        Button("Daylight") { set(["temperature": 12, "tint": 4]) }
                        Button("Cloudy") { set(["temperature": 28, "tint": 6]) }
                        Button("Shade") { set(["temperature": 42, "tint": 8]) }
                        Button("Tungsten") { set(["temperature": -55, "tint": 4]) }
                        Button("Fluorescent") { set(["temperature": -25, "tint": 30]) }
                        Button("Flash") { set(["temperature": 20, "tint": 3]) }
                    }.frame(width: 130)
                    Button("Auto") { autoWB() }.buttonStyle(PanelButtonStyle()).help("Gray-world white balance of the image")
                }
                LinearGradient(colors: [Color(red: 0.25, green: 0.45, blue: 1), Color(red: 1, green: 0.85, blue: 0.3)], startPoint: .leading, endPoint: .trailing).frame(height: 4)
            }
            ForEach(EditsAdjustments.params(s.kind), id: \.key) { p in
                ValueSlider(label: p.label, value: Binding(get: { EditsAdjustments.value(s, p.key) }, set: { s.params[p.key] = $0 }),
                            range: p.range, step: p.step, unit: p.unit, format: p.format, onCommit: onCommit)
                if s.kind == .colorWB && p.key == "temperature" {
                    LinearGradient(colors: [Color(red: 0.2, green: 0.85, blue: 0.3), Color(red: 0.9, green: 0.3, blue: 0.9)], startPoint: .leading, endPoint: .trailing).frame(height: 4)
                }
            }
            HStack {
                Spacer()
                Button("Reset") { s.params = [:]; onCommit() }.buttonStyle(PanelButtonStyle())
            }
        }
    }

    func set(_ d: [String: Double]) { for (k, v) in d { s.params[k] = v }; onCommit() }

    /// Gray-world estimate of the image below → temperature / tint that neutralize it.
    func autoWB() {
        guard let d = AppActions.doc else { return }
        let sp = AppActions.space(d)
        let img = Compositor.shared.composite(d.committedState)
        let avg = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: sp.ciCanvas)])
        var px = [Float](repeating: 0, count: 4)
        RenderEngine.readbackContext.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        let r = pow(Double(max(px[0], 1e-4)), 2.2), g = pow(Double(max(px[1], 1e-4)), 2.2), b = pow(Double(max(px[2], 1e-4)), 2.2)
        // gains we want: r·gr = g·gg = b·gb. Temperature controls r/b, tint controls g vs (r,b).
        let t = clamp(log2(b / r) / (2 * 0.55) * 100, -100, 100)
        let m = clamp(log2(g / sqrt(r * b)) / (0.35 + 0.08) * 100, -100, 100)
        set(["temperature": t.rounded(), "tint": m.rounded()])
    }
}
