import Foundation
import CoreImage
import ImageCratCore

enum FilterExtras {
    static let thresholdMixKernel = CIColorKernel(source: """
    kernel vec4 thrMix(__sample orig, __sample med, float t) {
        vec3 d = abs(orig.rgb - med.rgb);
        float m = max(d.r, max(d.g, d.b));
        return m > t ? med : orig;
    }
    """)

    /// Sparse bilateral filter (Surface Blur): blurs within `radius`, ignoring neighbours differing by more than `threshold`.
    static let bilateralKernel = CIKernel(source: """
    kernel vec4 bilateral(sampler src, float radius, float stepSize, float thr) {
        vec2 dc = destCoord();
        vec4 c0 = sample(src, samplerTransform(src, dc));
        vec3 C = c0.a > 0.0 ? c0.rgb / c0.a : vec3(0.0);
        vec3 acc = vec3(0.0); float wsum = 0.0; float asum = 0.0;
        for (float y = -radius; y <= radius; y += stepSize) {
            for (float x = -radius; x <= radius; x += stepSize) {
                if (x * x + y * y > radius * radius) { continue; }
                vec4 s = sample(src, samplerTransform(src, dc + vec2(x, y)));
                vec3 S = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
                vec3 d = abs(S - C);
                float diff = max(d.r, max(d.g, d.b));
                float w = max(0.0, 1.0 - diff / (thr * 2.5));
                acc += S * w; wsum += w; asum += s.a * w;
            }
        }
        vec3 r = wsum > 0.0 ? acc / wsum : C;
        return vec4(r * c0.a, c0.a);
    }
    """)

    // MARK: Lens correction

    static let lensWarp = CIWarpKernel(source: """
    kernel vec2 lensWarp(vec2 c, float r0, float k, float s, vec2 persp, float ang) {
        vec2 d = destCoord() - c;
        // rotation
        float ca = cos(ang); float sa = sin(ang);
        d = vec2(d.x * ca - d.y * sa, d.x * sa + d.y * ca);
        // perspective (keystone): scale x by y offset and y by x offset
        d.x = d.x * (1.0 + persp.y * d.y / r0);
        d.y = d.y * (1.0 + persp.x * d.x / r0);
        float rr = length(d) / r0;
        float f = 1.0 + k * rr * rr;
        return c + d * f / s;
    }
    """)

    static let caKernel = CIKernel(source: """
    kernel vec4 chroma(sampler src, vec2 c, float kr, float kb) {
        vec2 dc = destCoord();
        vec2 d = dc - c;
        vec4 g = sample(src, samplerTransform(src, dc));
        vec4 r = sample(src, samplerTransform(src, c + d * (1.0 + kr)));
        vec4 b = sample(src, samplerTransform(src, c + d * (1.0 + kb)));
        return vec4(r.r, g.g, b.b, g.a);
    }
    """)

    static func lensCorrection(_ input: CIImage, v: (String) -> Double, ext: CGRect, canvas: CGRect) -> CIImage {
        var img = LensProfiles.apply(input, v: v, ext: ext, canvas: canvas).clampedToExtent()   // lens profile first (Edits/LensProfiles.swift)
        let c = CIVector(x: canvas.midX, y: canvas.midY)
        let r0 = Double(max(canvas.width, canvas.height)) * 0.5
        let k = -v("distortion") / 100 * 0.35
        let persp = CIVector(x: CGFloat(v("vertical") / 100 * 0.5), y: CGFloat(-v("horizontal") / 100 * 0.5))
        if k != 0 || v("vertical") != 0 || v("horizontal") != 0 || v("angle") != 0 || v("scale") != 100, let wk = lensWarp {
            img = wk.apply(extent: ext, roiCallback: { _, _ in input.extent }, image: input,
                           arguments: [c, Float(r0), Float(k), Float(v("scale") / 100), persp, Float(v("angle") * .pi / 180)]) ?? img
        }
        if (v("caRed") != 0 || v("caBlue") != 0), let ck = caKernel {
            let src = img.clampedToExtent()
            img = ck.apply(extent: ext, roiCallback: { _, r in r.insetBy(dx: -40, dy: -40) }, arguments: [src, c, Float(v("caRed") / 100 * 0.01), Float(v("caBlue") / 100 * 0.01)]) ?? img
        }
        if v("vignette") != 0 {
            img = img.clampedToExtent().applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: c, kCIInputRadiusKey: r0 * (0.6 + v("vigMid") / 100 * 0.8),
                kCIInputIntensityKey: -v("vignette") / 100, "inputFalloff": 0.5])
        }
        return img.cropped(to: ext)
    }

    // MARK: Smart sharpen

    static func smartSharpen(_ input: CIImage, v: (String) -> Double, ext: CGRect) -> CIImage {
        var src = input
        if v("noise") > 0 { src = src.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": v("noise") / 100 * 0.04, "inputSharpness": 0.4]) }
        let amount = v("amount") / 100, radius = v("radius")
        var blurred: CIImage
        switch Int(v("remove")) {
        case 1: blurred = src.applyingFilter("CIDiscBlur", parameters: [kCIInputRadiusKey: radius * 1.2])
        case 2: blurred = src.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius * 2, kCIInputAngleKey: v("angle") * .pi / 180])
        default: blurred = src.applyingGaussianBlur(sigma: radius)
        }
        // unsharp: result = src + amount × (src − blurred), with shadow/highlight fades
        guard let k = sharpenKernel else { return input }
        let out = k.apply(extent: ext, arguments: [src.cropped(to: ext), blurred.cropped(to: ext), Float(amount), Float(v("shadowFade") / 100), Float(v("highlightFade") / 100)]) ?? input
        return out
    }

    static let sharpenKernel = CIColorKernel(source: """
    kernel vec4 smartSharp(__sample s, __sample b, float amt, float sf, float hf) {
        vec3 S = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        vec3 B = b.a > 0.0 ? b.rgb / b.a : vec3(0.0);
        float l = dot(S, vec3(0.299, 0.587, 0.114));
        float fade = 1.0 - sf * (1.0 - smoothstep(0.0, 0.35, l)) - hf * smoothstep(0.65, 1.0, l);
        vec3 r = clamp(S + (S - B) * amt * max(fade, 0.0), 0.0, 1.0);
        return vec4(r * s.a, s.a);
    }
    """)

    // MARK: Pin-based filters

    static func apply(_ f: FilterInstance, _ input: CIImage, canvas: CGRect) -> CIImage {
        let ext = input.extent
        if ext.isEmpty || ext.isInfinite { return input }
        switch f.kind {
        case .fieldBlur: return fieldBlur(f, input, canvas: canvas)
        case .irisBlur: return irisBlur(f, input, canvas: canvas)
        case .pathBlur: return pathBlur(f, input, canvas: canvas)
        case .displace: return displace(f, input, canvas: canvas)
        default: return input
        }
    }

    /// Builds a low-res CI map (0…1) from a per-pixel function over the canvas (normalized coords, y down).
    static func map(canvas: CGRect, _ fn: (Double, Double) -> Double) -> CIImage {
        let n = 160
        let aspect = canvas.width / max(1, canvas.height)
        let w = aspect >= 1 ? n : max(8, Int(Double(n) * aspect)), h = aspect >= 1 ? max(8, Int(Double(n) / aspect)) : n
        var floats = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = Float(clamp(fn((Double(x) + 0.5) / Double(w), (Double(y) + 0.5) / Double(h)), 0, 1))
                let i = (y * w + x) * 4
                floats[i] = v; floats[i + 1] = v; floats[i + 2] = v; floats[i + 3] = 1
            }
        }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        let img = CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
        return img.transformed(by: CGAffineTransform(scaleX: canvas.width / CGFloat(w), y: canvas.height / CGFloat(h)).translatedBy(x: canvas.minX, y: canvas.minY))
            .clampedToExtent().applyingGaussianBlur(sigma: Double(canvas.width) / Double(w) * 0.7).cropped(to: canvas)
    }

    static func fieldBlur(_ f: FilterInstance, _ input: CIImage, canvas: CGRect) -> CIImage {
        let pins = f.points.isEmpty ? [FilterPin(x: 0.5, y: 0.5, value: f.value("blur"))] : f.points
        let maxR = max(0.5, pins.map(\.value).max() ?? 1)
        let m = map(canvas: canvas) { u, v in
            var num = 0.0, den = 0.0
            for p in pins {
                let d2 = (u - p.x) * (u - p.x) + (v - p.y) * (v - p.y) + 1e-5
                let w = 1 / (d2 * d2)
                num += p.value / maxR * w; den += w
            }
            return num / den
        }
        return input.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: ["inputMask": m, kCIInputRadiusKey: maxR]).cropped(to: input.extent)
    }

    static func irisBlur(_ f: FilterInstance, _ input: CIImage, canvas: CGRect) -> CIImage {
        let c = f.points.first ?? FilterPin(x: 0.5, y: 0.5, value: 0)
        let rx = f.value("rx"), ry = f.value("ry"), rot = f.value("rotation") * .pi / 180
        let feather = f.value("feather"), focus = f.value("focus") / 100
        let aspect = Double(canvas.width / max(1, canvas.height))
        let m = map(canvas: canvas) { u, v in
            var dx = (u - c.x) * aspect, dy = v - c.y
            let x = dx * cos(-rot) - dy * sin(-rot), y = dx * sin(-rot) + dy * cos(-rot)
            dx = x / max(0.001, rx * aspect * 0.5); dy = y / max(0.001, ry * 0.5)
            let r = sqrt(dx * dx + dy * dy)
            let inner = 1 - feather
            let t = clamp((r - inner) / max(0.001, 1 - inner), 0, 1)
            return (1 - focus) + focus * t * t * (3 - 2 * t)
        }
        return input.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: ["inputMask": m, kCIInputRadiusKey: f.value("blur")]).cropped(to: input.extent)
    }

    static func pathBlur(_ f: FilterInstance, _ input: CIImage, canvas: CGRect) -> CIImage {
        let pts = f.points.count >= 2 ? f.points : [FilterPin(x: 0.3, y: 0.5, value: 0), FilterPin(x: 0.7, y: 0.5, value: 0)]
        let a = pts[0], b = pts[1]
        let dx = (b.x - a.x) * Double(canvas.width), dy = (b.y - a.y) * Double(canvas.height)
        let len = sqrt(dx * dx + dy * dy)
        let angle = atan2(-dy, dx)     // CI y is up
        let dist = len * f.value("speed") / 100 * 0.5
        var out = input.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: dist, kCIInputAngleKey: angle]).cropped(to: input.extent)
        let taper = f.value("taper") / 100
        if taper > 0 {
            // fade the effect away from the path's end point
            let m = map(canvas: canvas) { u, v in
                let t = ((u - a.x) * (b.x - a.x) + (v - a.y) * (b.y - a.y)) / max(1e-6, (b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y))
                return 1 - taper * clamp(1 - t, 0, 1)
            }
            out = out.mixed(with: input, mask: m)
        }
        return out
    }

    static let displaceKernel = CIKernel(source: """
    kernel vec4 displaceK(sampler src, sampler map, float hs, float vs) {
        vec2 dc = destCoord();
        vec4 m = sample(map, samplerTransform(map, dc));
        vec2 off = vec2((m.r - 0.5) * 2.0 * hs, -(m.g - 0.5) * 2.0 * vs);
        return sample(src, samplerTransform(src, dc + off));
    }
    """)

    static func displace(_ f: FilterInstance, _ input: CIImage, canvas: CGRect) -> CIImage {
        guard let mp = f.payload, let k = displaceKernel else { return input }
        var mapImg = mp.ciImage
        if f.value("tile") > 0.5 {
            mapImg = mapImg.applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: NSAffineTransform()]).cropped(to: canvas)
        } else {
            mapImg = mapImg.transformed(by: CGAffineTransform(scaleX: canvas.width / mapImg.extent.width, y: canvas.height / mapImg.extent.height))
        }
        mapImg = mapImg.clampedToExtent()
        let hs = Float(f.value("h") / 100 * 128), vs = Float(f.value("v") / 100 * 128)
        let ext = input.extent
        return k.apply(extent: ext, roiCallback: { i, r in i == 0 ? r.insetBy(dx: -CGFloat(abs(hs)) - 2, dy: -CGFloat(abs(vs)) - 2) : r },
                       arguments: [input.clampedToExtent(), mapImg, hs, vs])?.cropped(to: ext) ?? input
    }
}
