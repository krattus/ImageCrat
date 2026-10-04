import Foundation
import CoreImage
import ImageCratCore

/// Core Image kernels used by Recipe nodes (kernel language; every identifier is prefixed to stay clear of Metal keywords).
enum RecipeKernels {
    private static func color(_ s: String) -> CIColorKernel? {
        let k = CIColorKernel(source: s)
        if k == nil { print("RecipeKernels: color kernel failed: \(s.prefix(60))") }
        return k
    }
    private static func general(_ s: String) -> CIKernel? {
        let k = CIKernel(source: s)
        if k == nil { print("RecipeKernels: kernel failed: \(s.prefix(60))") }
        return k
    }
    private static func warp(_ s: String) -> CIWarpKernel? {
        let k = CIWarpKernel(source: s)
        if k == nil { print("RecipeKernels: warp kernel failed: \(s.prefix(60))") }
        return k
    }

    // MARK: Conversions / channels

    /// Image → opaque gray mask. sel: 0 luminance × alpha, 1 R, 2 G, 3 B, 4 alpha, 5 luminance (ignoring alpha).
    static let toMask = color("""
    kernel vec4 rkToMask(__sample s, float sel) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        float l = dot(c, vec3(0.299, 0.587, 0.114));
        float v = sel < 0.5 ? l * s.a : (sel < 1.5 ? c.r * s.a : (sel < 2.5 ? c.g * s.a : (sel < 3.5 ? c.b * s.a : (sel < 4.5 ? s.a : l))));
        return vec4(vec3(v), 1.0);
    }
    """)

    static let merge = color("""
    kernel vec4 rkMerge(__sample r, __sample g, __sample b, __sample a) {
        return vec4(vec3(r.r, g.r, b.r) * a.r, a.r);
    }
    """)

    /// sel components: 0 R, 1 G, 2 B, 3 A, 4 zero, 5 one, 6 luminance.
    static let shuffle = color("""
    float rkPick(vec4 c, float l, float sel) {
        return sel < 0.5 ? c.r : (sel < 1.5 ? c.g : (sel < 2.5 ? c.b : (sel < 3.5 ? c.a : (sel < 4.5 ? 0.0 : (sel < 5.5 ? 1.0 : l)))));
    }
    kernel vec4 rkShuffle(__sample s, vec4 sel) {
        vec4 c = vec4(s.a > 0.0 ? s.rgb / s.a : vec3(0.0), s.a);
        float l = dot(c.rgb, vec3(0.299, 0.587, 0.114));
        float a = rkPick(c, l, sel.w);
        return vec4(vec3(rkPick(c, l, sel.x), rkPick(c, l, sel.y), rkPick(c, l, sel.z)) * a, a);
    }
    """)

    /// mode: 0 set alpha from mask, 1 multiply alpha by mask, 2 invert alpha, 3 make opaque (matte over colour m), 4 unpremultiply (rgb as-is, opaque), 5 premultiply.
    static let alphaOp = color("""
    kernel vec4 rkAlpha(__sample s, __sample m, float mode, vec4 matte) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        if (mode < 0.5) { return vec4(c * m.r, m.r); }
        if (mode < 1.5) { return s * m.r; }
        if (mode < 2.5) { float a = 1.0 - s.a; return vec4(c * a, a); }
        if (mode < 3.5) { return vec4(s.rgb + matte.rgb * (1.0 - s.a), 1.0); }
        if (mode < 4.5) { return vec4(c, 1.0); }
        return vec4(s.rgb * s.a, s.a);
    }
    """)

    // MARK: Maths

    /// op: 0 add, 1 subtract, 2 multiply, 3 divide, 4 min, 5 max, 6 difference, 7 screen, 8 power, 9 average.
    static let math = color("""
    kernel vec4 rkMath(__sample a, __sample b, float op, float clampOut) {
        vec3 A = a.a > 0.0 ? a.rgb / a.a : vec3(0.0);
        vec3 B = b.a > 0.0 ? b.rgb / b.a : vec3(0.0);
        vec3 r = A + B;
        if (op > 0.5) { r = A - B; }
        if (op > 1.5) { r = A * B; }
        if (op > 2.5) { r = A / max(B, vec3(0.0001)); }
        if (op > 3.5) { r = min(A, B); }
        if (op > 4.5) { r = max(A, B); }
        if (op > 5.5) { r = abs(A - B); }
        if (op > 6.5) { r = 1.0 - (1.0 - A) * (1.0 - B); }
        if (op > 7.5) { r = pow(max(A, vec3(0.0)), B); }
        if (op > 8.5) { r = (A + B) * 0.5; }
        if (clampOut > 0.5) { r = clamp(r, 0.0, 1.0); }
        return vec4(r * a.a, a.a);
    }
    """)

    static let mix = color("""
    kernel vec4 rkMix(__sample a, __sample b, __sample f, float amount) {
        return mix(a, b, clamp(f.r * amount, 0.0, 1.0));
    }
    """)

    static let clampK = color("""
    kernel vec4 rkClamp(__sample s, float lo, float hi) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        return vec4(clamp(c, lo, hi) * s.a, s.a);
    }
    """)

    static let remap = color("""
    kernel vec4 rkRemap(__sample s, vec4 r, float clampOut) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        vec3 t = (c - r.x) / max(r.y - r.x, 0.00001);
        if (clampOut > 0.5) { t = clamp(t, 0.0, 1.0); }
        return vec4((r.z + t * (r.w - r.z)) * s.a, s.a);
    }
    """)

    static let invert = color("""
    kernel vec4 rkInvert(__sample s) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        return vec4((1.0 - c) * s.a, s.a);
    }
    """)

    /// op: 0 A > B, 1 A < B, 2 |A − B| < soft (equal). Output: opaque mask.
    static let compare = color("""
    kernel vec4 rkCompare(__sample a, __sample b, float op, float soft) {
        float la = dot(a.rgb, vec3(0.299, 0.587, 0.114));
        float lb = dot(b.rgb, vec3(0.299, 0.587, 0.114));
        float e = max(soft, 0.0005);
        float v = smoothstep(-e, e, la - lb);
        if (op > 0.5) { v = 1.0 - v; }
        if (op > 1.5) { v = 1.0 - smoothstep(0.0, e * 2.0, abs(la - lb)); }
        return vec4(vec3(v), 1.0);
    }
    """)

    /// op: 0 multiply, 1 add, 2 subtract, 3 max, 4 min, 5 difference.
    static let maskCombine = color("""
    kernel vec4 rkMaskCombine(__sample a, __sample b, float op) {
        float v = a.r * b.r;
        if (op > 0.5) { v = a.r + b.r; }
        if (op > 1.5) { v = a.r - b.r; }
        if (op > 2.5) { v = max(a.r, b.r); }
        if (op > 3.5) { v = min(a.r, b.r); }
        if (op > 4.5) { v = abs(a.r - b.r); }
        return vec4(vec3(clamp(v, 0.0, 1.0)), 1.0);
    }
    """)

    /// p = (black, white, gamma, invert); q = (threshold on/off, level, softness, 0)
    static let maskAdjust = color("""
    kernel vec4 rkMaskAdjust(__sample s, vec4 p, vec4 q) {
        float v = s.r;
        v = clamp((v - p.x) / max(p.y - p.x, 0.0001), 0.0, 1.0);
        v = pow(v, 1.0 / max(p.z, 0.01));
        if (q.x > 0.5) { float e = max(q.z * 0.5, 0.0005); v = smoothstep(q.y - e, q.y + e, v); }
        if (p.w > 0.5) { v = 1.0 - v; }
        return vec4(vec3(v), 1.0);
    }
    """)

    // MARK: Coordinates / transforms

    /// Canvas coordinates. cv = (width, height, originX, originY) in CI px; mode 0 normalized (u right, v down), 1 centered (−1…1), 2 polar (angle, radius).
    static let uv = general("""
    kernel vec4 rkUV(vec4 cv, float mode) {
        vec2 d = destCoord();
        vec2 n = vec2((d.x - cv.z) / cv.x, 1.0 - (d.y - cv.w) / cv.y);
        if (mode > 1.5) {
            vec2 c = (n - 0.5) * vec2(cv.x / min(cv.x, cv.y), cv.y / min(cv.x, cv.y)) * 2.0;
            return vec4(fract(atan(c.y, c.x) / 6.2831853 + 0.5), clamp(length(c), 0.0, 1.0), 0.0, 1.0);
        }
        if (mode > 0.5) { return vec4(clamp(abs(n - 0.5) * 2.0, 0.0, 1.0), 0.0, 1.0); }
        return vec4(clamp(n, 0.0, 1.0), 0.0, 1.0);
    }
    """)

    /// Affine resample with an edge mode. r = source rect; m, t = dest → source matrix; edge: 0 transparent, 1 clamp, 2 wrap, 3 mirror.
    static let affine = warp("""
    kernel vec2 rkAffine(vec4 r, vec4 m, vec2 t, float edge) {
        vec2 d = destCoord();
        vec2 p = vec2(m.x * d.x + m.y * d.y + t.x, m.z * d.x + m.w * d.y + t.y);
        if (edge < 0.5) { return p; }
        vec2 u = (p - r.xy) / r.zw;
        if (edge > 2.5) { u = 1.0 - abs(u - 2.0 * floor(u * 0.5) - 1.0); }
        else if (edge > 1.5) { u = u - floor(u); }
        vec2 px = 0.5 / r.zw;
        u = clamp(u, px, 1.0 - px);
        return r.xy + u * r.zw;
    }
    """)

    /// mode: 0 left → right, 1 right → left, 2 top → bottom, 3 bottom → top, 4 quad. c = mirror centre (CI px).
    static let mirror = warp("""
    kernel vec2 rkMirror(vec2 c, float mode) {
        vec2 d = destCoord();
        if (mode < 0.5) { return vec2(d.x > c.x ? 2.0 * c.x - d.x : d.x, d.y); }
        if (mode < 1.5) { return vec2(d.x < c.x ? 2.0 * c.x - d.x : d.x, d.y); }
        if (mode < 2.5) { return vec2(d.x, d.y < c.y ? 2.0 * c.y - d.y : d.y); }
        if (mode < 3.5) { return vec2(d.x, d.y > c.y ? 2.0 * c.y - d.y : d.y); }
        return vec2(d.x > c.x ? 2.0 * c.x - d.x : d.x, d.y < c.y ? 2.0 * c.y - d.y : d.y);
    }
    """)

    /// Displace by a map: (r, g) − 0.5 scaled by strength (px). CI y is up, so +g moves content down in the document.
    static let displace = general("""
    kernel vec4 rkDisplace(sampler src, sampler map, vec2 strength) {
        vec2 dc = destCoord();
        vec4 m = sample(map, samplerTransform(map, dc));
        vec2 off = vec2((m.r - 0.5) * 2.0 * strength.x, -(m.g - 0.5) * 2.0 * strength.y);
        return sample(src, samplerTransform(src, dc + off));
    }
    """)

    // MARK: Utility

    static let sobel = general("""
    float rkLum(vec4 c) { return dot(c.rgb, vec3(0.299, 0.587, 0.114)); }
    kernel vec4 rkSobel(sampler src, float strength, float radius) {
        vec2 d = destCoord();
        float tl = rkLum(sample(src, samplerTransform(src, d + vec2(-radius, radius))));
        float tc = rkLum(sample(src, samplerTransform(src, d + vec2(0.0, radius))));
        float tr = rkLum(sample(src, samplerTransform(src, d + vec2(radius, radius))));
        float ml = rkLum(sample(src, samplerTransform(src, d + vec2(-radius, 0.0))));
        float mr = rkLum(sample(src, samplerTransform(src, d + vec2(radius, 0.0))));
        float bl = rkLum(sample(src, samplerTransform(src, d + vec2(-radius, -radius))));
        float bc = rkLum(sample(src, samplerTransform(src, d + vec2(0.0, -radius))));
        float br = rkLum(sample(src, samplerTransform(src, d + vec2(radius, -radius))));
        float gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
        float gy = (tl + 2.0 * tc + tr) - (bl + 2.0 * bc + br);
        return vec4(vec3(clamp(length(vec2(gx, gy)) * strength, 0.0, 1.0)), 1.0);
    }
    """)

    /// Tangent-space normal map from a height image (luminance).
    static let normalMap = general("""
    float rkLumN(vec4 c) { return dot(c.rgb, vec3(0.299, 0.587, 0.114)); }
    kernel vec4 rkNormal(sampler src, float strength, float flipY) {
        vec2 d = destCoord();
        float l = rkLumN(sample(src, samplerTransform(src, d + vec2(-1.0, 0.0))));
        float r = rkLumN(sample(src, samplerTransform(src, d + vec2(1.0, 0.0))));
        float b = rkLumN(sample(src, samplerTransform(src, d + vec2(0.0, -1.0))));
        float t = rkLumN(sample(src, samplerTransform(src, d + vec2(0.0, 1.0))));
        vec3 n = normalize(vec3((l - r) * strength, (b - t) * strength * (flipY > 0.5 ? -1.0 : 1.0), 1.0));
        return vec4(n * 0.5 + 0.5, 1.0);
    }
    """)

    /// Simple relight: n = normal map, a = albedo. L = light direction, col = light colour, p = (ambient, diffuse, specular, shininess).
    static let light = color("""
    kernel vec4 rkLight(__sample n, __sample a, vec3 L, vec4 col, vec4 p) {
        vec3 N = normalize(n.rgb * 2.0 - 1.0);
        vec3 Ln = normalize(L);
        float dif = max(dot(N, Ln), 0.0);
        vec3 Hv = normalize(Ln + vec3(0.0, 0.0, 1.0));
        float sp = pow(max(dot(N, Hv), 0.0), max(p.w, 1.0));
        vec3 alb = a.a > 0.0 ? a.rgb / a.a : vec3(0.0);
        vec3 c = alb * (p.x + p.y * dif * col.rgb) + p.z * sp * col.rgb;
        return vec4(clamp(c, 0.0, 1.0) * a.a, a.a);
    }
    """)

    /// Ambient occlusion approximation from a height image: darkens pixels lower than their surroundings.
    static let ambientOcclusion = general("""
    float rkLumA(vec4 c) { return dot(c.rgb, vec3(0.299, 0.587, 0.114)); }
    kernel vec4 rkAO(sampler src, float radius, float strength) {
        vec2 d = destCoord();
        float h = rkLumA(sample(src, samplerTransform(src, d)));
        float occ = 0.0;
        for (float i = 0.0; i < 12.0; i += 1.0) {
            float an = i * 0.5235988;
            vec2 dir = vec2(cos(an), sin(an));
            float h1 = rkLumA(sample(src, samplerTransform(src, d + dir * radius)));
            float h2 = rkLumA(sample(src, samplerTransform(src, d + dir * radius * 0.4)));
            occ += max(h1 - h, 0.0) + 0.6 * max(h2 - h, 0.0);
        }
        float ao = clamp(1.0 - occ / 12.0 * strength * 4.0, 0.0, 1.0);
        return vec4(vec3(ao), 1.0);
    }
    """)

    /// Gradient map through a 256 px LUT.
    static let ramp = general("""
    kernel vec4 rkRamp(sampler src, sampler lut, float amount) {
        vec4 s = sample(src, samplerTransform(src, destCoord()));
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        float t = clamp(dot(c, vec3(0.299, 0.587, 0.114)), 0.0, 1.0);
        vec4 L = sample(lut, samplerTransform(lut, vec2(t * 255.0 + 0.5, 0.5)));
        vec3 lc = L.a > 0.0 ? L.rgb / L.a : vec3(0.0);
        vec3 r = mix(c, lc, amount);
        float a = s.a * mix(1.0, L.a, amount);
        return vec4(r * a, a);
    }
    """)

    /// Dither to `levels` per channel. mode: 0 Bayer 4×4, 1 Bayer 8×8, 2 noise, 3 none (posterize). cell = pattern pixel size.
    static let dither = color("""
    float rkBayer2(vec2 a) { a = floor(a); return fract(a.x / 2.0 + a.y * a.y * 0.75); }
    float rkBayer4(vec2 a) { return rkBayer2(0.5 * a) * 0.25 + rkBayer2(a); }
    float rkBayer8(vec2 a) { return rkBayer4(0.5 * a) * 0.25 + rkBayer2(a); }
    float rkHashD(vec2 p) {
        vec3 p3 = fract(vec3(p.x, p.y, p.x) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }
    kernel vec4 rkDither(__sample s, float levels, float mode, float mono, float cell) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        vec2 p = floor(destCoord() / max(cell, 1.0));
        float th = 0.5;
        if (mode < 0.5) { th = rkBayer4(p); } else if (mode < 1.5) { th = rkBayer8(p); } else if (mode < 2.5) { th = rkHashD(p); }
        float n = max(levels - 1.0, 1.0);
        if (mono > 0.5) { c = vec3(dot(c, vec3(0.299, 0.587, 0.114))); }
        vec3 q = floor(c * n + th) / n;
        return vec4(clamp(q, 0.0, 1.0) * s.a, s.a);
    }
    """)

    // MARK: Distance field (jump flooding)

    /// Seeds: pixels where the mask is set store a zero offset (rg = vector to the nearest seed, b = valid).
    static let jfaInit = general("""
    kernel vec4 rkJfaInit(sampler m, float invertMask) {
        float v = sample(m, samplerTransform(m, destCoord())).r;
        if (invertMask > 0.5) { v = 1.0 - v; }
        return v > 0.5 ? vec4(0.0, 0.0, 1.0, 1.0) : vec4(0.0, 0.0, 0.0, 1.0);
    }
    """)

    static let jfaStep = general("""
    kernel vec4 rkJfaStep(sampler s, float stepSize) {
        vec2 d = destCoord();
        vec4 best = vec4(0.0, 0.0, 0.0, 1.0);
        float bd = 1.0e12;
        for (float y = -1.0; y <= 1.0; y += 1.0) {
            for (float x = -1.0; x <= 1.0; x += 1.0) {
                vec2 o = vec2(x, y) * stepSize;
                vec4 c = sample(s, samplerTransform(s, d + o));
                if (c.b > 0.5) {
                    vec2 cand = o + c.rg;
                    float dd = dot(cand, cand);
                    if (dd < bd) { bd = dd; best = vec4(cand, 1.0, 1.0); }
                }
            }
        }
        return best;
    }
    """)

    static let jfaFinal = general("""
    kernel vec4 rkJfaFinal(sampler s, float spread) {
        vec4 c = sample(s, samplerTransform(s, destCoord()));
        float dist = c.b > 0.5 ? length(c.rg) : spread;
        return vec4(vec3(clamp(dist / spread, 0.0, 1.0)), 1.0);
    }
    """)

    /// Distance (0…1 over `spread` px) to the nearest pixel where `mask` is set (or clear, when `inverted`).
    static func distance(toSet mask: CIImage, inverted: Bool, spread: Double, extent: CGRect) -> CIImage {
        guard let ki = jfaInit, let ks = jfaStep, let kf = jfaFinal else { return mask }
        let sp = max(1, min(spread, 2048))
        let src = mask.clampedToExtent()
        guard var img = ki.apply(extent: extent, roiCallback: { _, r in r }, arguments: [src, inverted ? 1 : 0]) else { return mask }
        var step = pow(2, ceil(log2(sp)))
        while step >= 1 {
            let st = CGFloat(step)
            // (unclamped on purpose: samples outside the canvas are "no seed")
            guard let next = ks.apply(extent: extent, roiCallback: { _, r in r.insetBy(dx: -st - 1, dy: -st - 1) }, arguments: [img, Float(step)]) else { break }
            img = next
            step /= 2
        }
        return kf.apply(extent: extent, roiCallback: { _, r in r }, arguments: [img, Float(sp)]) ?? mask
    }

    // MARK: Helpers

    /// Constant image from unpremultiplied components (values may exceed 0…1 for maths).
    static func constant(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1, _ rect: CGRect) -> CIImage {
        // CIColor components are unpremultiplied; Core Image premultiplies when it makes the image.
        return CIImage(color: CIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))).cropped(to: rect)
    }

    static func allCompiled() -> [(String, Bool)] {
        [("toMask", toMask != nil), ("merge", merge != nil), ("shuffle", shuffle != nil), ("alphaOp", alphaOp != nil), ("math", math != nil),
         ("mix", mix != nil), ("clamp", clampK != nil), ("remap", remap != nil), ("invert", invert != nil), ("compare", compare != nil),
         ("maskCombine", maskCombine != nil), ("maskAdjust", maskAdjust != nil), ("uv", uv != nil), ("affine", affine != nil), ("mirror", mirror != nil),
         ("displace", displace != nil), ("sobel", sobel != nil), ("normalMap", normalMap != nil), ("light", light != nil),
         ("ambientOcclusion", ambientOcclusion != nil), ("ramp", ramp != nil), ("dither", dither != nil),
         ("jfaInit", jfaInit != nil), ("jfaStep", jfaStep != nil), ("jfaFinal", jfaFinal != nil), ("seamless", TextureEngine.seamlessKernel != nil)]
    }
}
