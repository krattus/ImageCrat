import CoreImage
import ImageCratCore

/// Custom Core Image kernels (CI kernel language, compiled at runtime).
enum Kernels {
    private static func color(_ src: String) -> CIColorKernel? { CIColorKernel(source: src) }
    private static func general(_ src: String) -> CIKernel? { CIKernel(source: src) }
    private static func warp(_ src: String) -> CIWarpKernel? { CIWarpKernel(source: src) }

    private static let blendTail = """
        return vec4(s.rgb * (1.0 - d.a) + d.rgb * (1.0 - s.a) + s.a * d.a * B, s.a + d.a - s.a * d.a);
    """

    static let hardMix = color("""
    kernel vec4 hardMix(__sample s, __sample d) {
        vec3 S = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        vec3 D = d.a > 0.0 ? d.rgb / d.a : vec3(0.0);
        vec3 B = step(1.0, S + D);
        \(blendTail)
    }
    """)

    static let darkerColor = color("""
    kernel vec4 darkerColor(__sample s, __sample d) {
        vec3 S = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        vec3 D = d.a > 0.0 ? d.rgb / d.a : vec3(0.0);
        float ls = dot(S, vec3(0.299, 0.587, 0.114));
        float ld = dot(D, vec3(0.299, 0.587, 0.114));
        vec3 B = ls < ld ? S : D;
        \(blendTail)
    }
    """)

    static let lighterColor = color("""
    kernel vec4 lighterColor(__sample s, __sample d) {
        vec3 S = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        vec3 D = d.a > 0.0 ? d.rgb / d.a : vec3(0.0);
        float ls = dot(S, vec3(0.299, 0.587, 0.114));
        float ld = dot(D, vec3(0.299, 0.587, 0.114));
        vec3 B = ls > ld ? S : D;
        \(blendTail)
    }
    """)

    static let dissolveKernel = color("""
    kernel vec4 dissolve(__sample s, __sample d, __sample n) {
        if (s.a > 0.0 && n.r < s.a) {
            return vec4(s.rgb / s.a, 1.0);
        }
        return d;
    }
    """)

    static let solarizeKernel = color("""
    kernel vec4 solarize(__sample s) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        c = mix(c, 1.0 - c, step(0.5, c));
        return vec4(c * s.a, s.a);
    }
    """)

    static let addNoiseKernel = color("""
    kernel vec4 addNoise(__sample s, __sample n, float amount, float mono) {
        vec3 nn = mono > 0.5 ? vec3(n.r) : n.rgb;
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        c = clamp(c + (nn - 0.5) * amount, 0.0, 1.0);
        return vec4(c * s.a, s.a);
    }
    """)

    static let highPassKernel = color("""
    kernel vec4 highPass(__sample s, __sample b) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        vec3 bl = b.a > 0.0 ? b.rgb / b.a : vec3(0.0);
        vec3 r = clamp(c - bl + 0.5, 0.0, 1.0);
        return vec4(r * s.a, s.a);
    }
    """)

    static let thresholdKernel = color("""
    kernel vec4 thresholdK(__sample s, float level) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        float l = dot(c, vec3(0.299, 0.587, 0.114));
        float v = l >= level ? 1.0 : 0.0;
        return vec4(vec3(v) * s.a, s.a);
    }
    """)

    static let powKernel = color("""
    kernel vec4 powK(__sample s, float e) {
        return vec4(pow(clamp(s.rgb, 0.0, 1.0), vec3(e)), s.a);
    }
    """)

    static let alphaMultiplyKernel = color("""
    kernel vec4 alphaMul(__sample s, __sample m) {
        return s * m.r;
    }
    """)

    /// Bevel shading: height map gradient against light → signed shade in r (highlight) and g (shadow).
    static let bevelKernel = general("""
    kernel vec4 bevelShade(sampler h, vec2 light, float depth, float up) {
        vec2 dc = destCoord();
        float l = sample(h, samplerTransform(h, dc + vec2(-1.0, 0.0))).r;
        float r = sample(h, samplerTransform(h, dc + vec2(1.0, 0.0))).r;
        float b = sample(h, samplerTransform(h, dc + vec2(0.0, -1.0))).r;
        float t = sample(h, samplerTransform(h, dc + vec2(0.0, 1.0))).r;
        vec2 g = vec2(r - l, t - b) * depth * up;
        float shade = dot(normalize(vec3(-g, 1.0)), normalize(vec3(light, 1.0)));
        float flatL = 1.0 / length(vec3(light, 1.0));
        float v = shade - flatL;
        return vec4(max(v, 0.0) * 1.8, max(-v, 0.0) * 1.5, 0.0, 1.0);
    }
    """)

    static let gradientKernel = general("""
    kernel vec4 gradientFill(sampler lut, vec2 p0, vec2 p1, float gtype, float lutW) {
        vec2 p = destCoord();
        vec2 d = p1 - p0;
        float len = max(length(d), 0.0001);
        float t = 0.0;
        if (gtype < 0.5) {
            t = dot(p - p0, d) / (len * len);
        } else if (gtype < 1.5) {
            t = length(p - p0) / len;
        } else if (gtype < 2.5) {
            float a = atan(p.y - p0.y, p.x - p0.x) - atan(d.y, d.x);
            t = fract(-a / 6.28318530718);
        } else if (gtype < 3.5) {
            t = abs(dot(p - p0, d) / (len * len));
        } else {
            vec2 dir = d / len;
            vec2 q = p - p0;
            float u = abs(dot(q, dir));
            float v = abs(dot(q, vec2(-dir.y, dir.x)));
            t = max(u, v) / len;
        }
        t = clamp(t, 0.0, 1.0);
        return sample(lut, samplerTransform(lut, vec2(t * (lutW - 1.0) + 0.5, 0.5)));
    }
    """)

    static let kuwaharaKernel = general("""
    kernel vec4 kuwahara(sampler src, float radius) {
        vec2 dc = destCoord();
        float n = (radius + 1.0) * (radius + 1.0);
        vec3 m0 = vec3(0.0); vec3 m1 = vec3(0.0); vec3 m2 = vec3(0.0); vec3 m3 = vec3(0.0);
        vec3 s0 = vec3(0.0); vec3 s1 = vec3(0.0); vec3 s2 = vec3(0.0); vec3 s3 = vec3(0.0);
        float a = sample(src, samplerTransform(src, dc)).a;
        for (float j = 0.0; j <= radius; j += 1.0) {
            for (float i = 0.0; i <= radius; i += 1.0) {
                vec3 c;
                c = sample(src, samplerTransform(src, dc + vec2(-i, -j))).rgb; m0 += c; s0 += c * c;
                c = sample(src, samplerTransform(src, dc + vec2(i, -j))).rgb; m1 += c; s1 += c * c;
                c = sample(src, samplerTransform(src, dc + vec2(i, j))).rgb; m2 += c; s2 += c * c;
                c = sample(src, samplerTransform(src, dc + vec2(-i, j))).rgb; m3 += c; s3 += c * c;
            }
        }
        m0 /= n; m1 /= n; m2 /= n; m3 /= n;
        vec3 v0 = abs(s0 / n - m0 * m0); vec3 v1 = abs(s1 / n - m1 * m1);
        vec3 v2 = abs(s2 / n - m2 * m2); vec3 v3 = abs(s3 / n - m3 * m3);
        float q0 = v0.r + v0.g + v0.b; float q1 = v1.r + v1.g + v1.b;
        float q2 = v2.r + v2.g + v2.b; float q3 = v3.r + v3.g + v3.b;
        vec3 res = m0; float best = q0;
        if (q1 < best) { best = q1; res = m1; }
        if (q2 < best) { best = q2; res = m2; }
        if (q3 < best) { best = q3; res = m3; }
        return vec4(res, a);
    }
    """)

    static let rippleWarp = warp("""
    kernel vec2 ripple(float amp, float wavelength) {
        vec2 d = destCoord();
        return vec2(d.x + amp * sin(d.y / wavelength * 6.28318), d.y + amp * sin(d.x / wavelength * 6.28318));
    }
    """)

    static let polarWarp = warp("""
    kernel vec2 polar(vec2 c, vec4 ext, float toPolar) {
        vec2 d = destCoord();
        float w = ext.z; float h = ext.w;
        if (toPolar > 0.5) {
            vec2 q = d - c;
            float r = length(q) / (min(w, h) * 0.5);
            float a = atan(q.x, q.y);
            float u = fract(a / 6.28318530718 + 0.5);
            return vec2(ext.x + u * w, ext.y + h - r * h);
        } else {
            float u = (d.x - ext.x) / w;
            float v = (ext.y + h - d.y) / h;
            float a = (u - 0.5) * 6.28318530718;
            float r = v * min(w, h) * 0.5;
            return c + vec2(sin(a), cos(a)) * r;
        }
    }
    """)

    static let waveWarp = warp("""
    kernel vec2 wave(float amp, float wavelength, float horizontal) {
        vec2 d = destCoord();
        if (horizontal > 0.5) { return vec2(d.x, d.y + amp * sin(d.x / wavelength * 6.28318)); }
        return vec2(d.x + amp * sin(d.y / wavelength * 6.28318), d.y);
    }
    """)

    // MARK: Helpers

    static func customBlend(_ s: CIImage, _ d: CIImage, kernel: CIColorKernel?) -> CIImage {
        guard let k = kernel else { return s.composited(over: d) }
        let ext = s.extent.union(d.extent)
        let S = s.composited(over: CIImage.clearImage.cropped(to: ext))
        let D = d.composited(over: CIImage.clearImage.cropped(to: ext))
        return k.apply(extent: ext, arguments: [S, D]) ?? s.composited(over: d)
    }

    static func dissolve(_ s: CIImage, _ d: CIImage) -> CIImage {
        guard let k = dissolveKernel else { return s.composited(over: d) }
        let ext = s.extent.union(d.extent)
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: ext)
        let S = s.composited(over: CIImage.clearImage.cropped(to: ext))
        let D = d.composited(over: CIImage.clearImage.cropped(to: ext))
        return k.apply(extent: ext, arguments: [S, D, noise]) ?? s.composited(over: d)
    }

    /// 256-px wide LUT image for a gradient (premultiplied).
    static func gradientLUT(_ g: ColorGradient, reverse: Bool = false) -> CIImage {
        let grad = reverse ? g.reversed() : g
        let w = 256
        let buf = PixelBuffer(width: w, height: 1)
        let p = buf.data.assumingMemoryBound(to: UInt8.self)
        for x in 0..<w {
            let c = grad.color(at: Double(x) / Double(w - 1))
            let a = clamp(c.a, 0, 1)
            p[x * 4] = UInt8(clamp(c.r * a, 0, 1) * 255)
            p[x * 4 + 1] = UInt8(clamp(c.g * a, 0, 1) * 255)
            p[x * 4 + 2] = UInt8(clamp(c.b * a, 0, 1) * 255)
            p[x * 4 + 3] = UInt8(a * 255)
        }
        buf.markDirty()
        return buf.ciImage
    }

    /// Gradient image in CI space. p0/p1 are CI-space points.
    static func gradientImage(_ g: ColorGradient, type: GradientType, p0: CGPoint, p1: CGPoint, reverse: Bool, extent: CGRect) -> CIImage {
        let lut = gradientLUT(g, reverse: reverse)
        guard let k = gradientKernel else { return CIImage.clearImage.cropped(to: extent) }
        let lutExt = lut.extent
        let out = k.apply(extent: extent, roiCallback: { _, _ in lutExt }, arguments: [
            lut, CIVector(x: p0.x, y: p0.y), CIVector(x: p1.x, y: p1.y), Float(type.index), Float(256),
        ])
        return out ?? CIImage.clearImage.cropped(to: extent)
    }
}
