import Foundation
import CoreImage
import ImageCratCore

// MARK: - Model

enum TextureCategory: String, CaseIterable {
    case noise = "Noise", pattern = "Patterns", natural = "Natural", tech = "Tech"
}

enum TexParamKind: Equatable {
    case slider(ClosedRange<Double>)
    case int(ClosedRange<Double>)
    case toggle
    case choice([String])
}

struct TexParam {
    let key: String
    let label: String
    let kind: TexParamKind
    let def: Double

    static func s(_ key: String, _ label: String, _ r: ClosedRange<Double>, _ def: Double) -> TexParam { TexParam(key: key, label: label, kind: .slider(r), def: def) }
    static func i(_ key: String, _ label: String, _ r: ClosedRange<Double>, _ def: Double) -> TexParam { TexParam(key: key, label: label, kind: .int(r), def: def) }
    static func t(_ key: String, _ label: String, _ def: Bool) -> TexParam { TexParam(key: key, label: label, kind: .toggle, def: def ? 1 : 0) }
    static func c(_ key: String, _ label: String, _ opts: [String], _ def: Int) -> TexParam { TexParam(key: key, label: label, kind: .choice(opts), def: Double(def)) }

    var range: ClosedRange<Double> {
        switch kind {
        case .slider(let r), .int(let r): return r
        case .toggle: return 0...1
        case .choice(let o): return 0...Double(max(0, o.count - 1))
        }
    }

    func sanitized(_ v: Double) -> Double {
        switch kind {
        case .slider(let r): return min(max(v, r.lowerBound), r.upperBound)
        case .int(let r): return min(max(v.rounded(), r.lowerBound), r.upperBound)
        case .toggle: return v > 0.5 ? 1 : 0
        case .choice(let o): return min(max(v.rounded(), 0), Double(max(0, o.count - 1)))
        }
    }
}

/// A procedural generator: a CI-kernel-language function evaluated per pixel in "cell" coordinates.
struct TextureGen {
    let id: String
    let name: String
    let category: TextureCategory
    /// Default size of one cell in pixels.
    var scale: Double = 64
    var params: [TexParam] = []
    /// Up to three colour uniforms (k0…k2) for generators that output colour directly.
    var colors: [(key: String, label: String, def: RGBA)] = []
    /// Default colour ramp (value 0…1 → colour).
    var ramp: ColorGradient = .twoColor(.black, .white, name: "Black, White")
    /// The kernel returns final colours (the ramp is only used when "Map to Gradient" is on).
    var direct = false
    /// Natural repeat of the pattern in cell units (used to pick integer repeat counts when tileable).
    var period: ([String: Double]) -> (Double, Double) = { _ in (1, 1) }
    /// False: the function is not periodic; "Tileable" cross-blends the edges instead.
    var nativeTile: ([String: Double]) -> Bool = { _ in true }
    var keywords: [String] = []
    /// Extra kernel-language helper functions used by `body`.
    var helpers = ""
    /// Body of `vec4 lxGen(vec2 q, vec2 per, float seed, float aa, vec2 nuv, vec4 k0, vec4 k1, vec4 k2)`;
    /// parameters are available as floats named after their keys. rgb = value / colour, a = shade multiplier (1 = none).
    let body: String
}

/// One configured texture (a generator + its values). Used by the dialog and by Recipe generator nodes.
struct TextureSettings: Codable, Equatable {
    var gen: String
    var values: [String: Double] = [:]
    var colors: [String: RGBA] = [:]
    var ramp: ColorGradient? = nil

    init(gen: String) {
        self.gen = gen
        if let g = TextureCatalog.gen(gen) { self = TextureSettings.defaults(g) }
    }

    private init(raw gen: String) { self.gen = gen }

    static func defaults(_ g: TextureGen) -> TextureSettings {
        var s = TextureSettings(raw: g.id)
        for p in TextureCatalog.commonParams(g) { s.values[p.key] = p.def }
        for p in g.params { s.values[p.key] = p.def }
        for c in g.colors { s.colors[c.key] = c.def }
        s.ramp = g.ramp
        return s
    }

    func value(_ k: String, _ def: Double = 0) -> Double { values[k] ?? def }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gen = try c.decodeIfPresent(String.self, forKey: .gen) ?? "perlin"
        values = (try? c.decodeIfPresent([String: Double].self, forKey: .values)) ?? [:]
        colors = (try? c.decodeIfPresent([String: RGBA].self, forKey: .colors)) ?? [:]
        ramp = try? c.decodeIfPresent(ColorGradient.self, forKey: .ramp)
    }
}

// MARK: - Engine

enum TextureEngine {
    /// Shared kernel-language helpers (hashes, lattice noises, Worley, fBm). Everything is prefixed `lx`.
    static let prelude = """
    float lxMod(float x, float y) { return x - y * floor(x / y); }
    vec2 lxWrap(vec2 c, vec2 per) {
        return vec2(per.x > 0.5 ? lxMod(c.x, per.x) : c.x, per.y > 0.5 ? lxMod(c.y, per.y) : c.y);
    }
    float lxH1(vec2 p) {
        vec3 p3 = fract(vec3(p.x, p.y, p.x) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }
    vec2 lxH2(vec2 p) {
        vec3 p3 = fract(vec3(p.x, p.y, p.x) * vec3(0.1031, 0.1030, 0.0973));
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.xx + p3.yz) * p3.zy);
    }
    vec3 lxH3(vec2 p) {
        vec3 p3 = fract(vec3(p.x, p.y, p.x) * vec3(0.1031, 0.1030, 0.0973));
        p3 += dot(p3, p3.yxz + 33.33);
        return fract((p3.xxy + p3.yzz) * p3.zyx);
    }
    vec2 lxSeedOff(float seed) { return vec2(lxMod(seed * 12.9898, 289.0), lxMod(seed * 78.233, 289.0)) + 0.5; }
    float lxC1(vec2 c, vec2 per, float seed) { return lxH1(lxWrap(c, per) + lxSeedOff(seed)); }
    vec2 lxC2(vec2 c, vec2 per, float seed) { return lxH2(lxWrap(c, per) + lxSeedOff(seed)); }
    vec3 lxC3(vec2 c, vec2 per, float seed) { return lxH3(lxWrap(c, per) + lxSeedOff(seed)); }
    vec4 lxG(float v) { return vec4(vec3(clamp(v, 0.0, 1.0)), 1.0); }
    float lxValue(vec2 p, vec2 per, float seed) {
        vec2 i = floor(p); vec2 f = p - i;
        vec2 u = f * f * (3.0 - 2.0 * f);
        float v00 = lxC1(i, per, seed);
        float v10 = lxC1(i + vec2(1.0, 0.0), per, seed);
        float v01 = lxC1(i + vec2(0.0, 1.0), per, seed);
        float v11 = lxC1(i + vec2(1.0, 1.0), per, seed);
        return mix(mix(v00, v10, u.x), mix(v01, v11, u.x), u.y);
    }
    float lxGradDot(vec2 c, vec2 f, vec2 per, float seed) {
        float an = 6.2831853 * lxC1(c, per, seed);
        return dot(vec2(cos(an), sin(an)), f);
    }
    float lxPerlin(vec2 p, vec2 per, float seed) {
        vec2 i = floor(p); vec2 f = p - i;
        vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
        float n00 = lxGradDot(i, f, per, seed);
        float n10 = lxGradDot(i + vec2(1.0, 0.0), f - vec2(1.0, 0.0), per, seed);
        float n01 = lxGradDot(i + vec2(0.0, 1.0), f - vec2(0.0, 1.0), per, seed);
        float n11 = lxGradDot(i + vec2(1.0, 1.0), f - vec2(1.0, 1.0), per, seed);
        return mix(mix(n00, n10, u.x), mix(n01, n11, u.x), u.y) * 1.4142;
    }
    vec2 lxSGrad(vec2 c, float seed) {
        float an = 6.2831853 * lxH1(c + lxSeedOff(seed));
        return vec2(cos(an), sin(an));
    }
    float lxSimplex(vec2 p, float seed) {
        float K1 = 0.366025404; float K2 = 0.211324865;
        vec2 i = floor(p + (p.x + p.y) * K1);
        vec2 x0 = p - i + (i.x + i.y) * K2;
        float m = step(x0.y, x0.x);
        vec2 o = vec2(m, 1.0 - m);
        vec2 x1 = x0 - o + K2;
        vec2 x2 = x0 - 1.0 + 2.0 * K2;
        vec3 h = max(0.5 - vec3(dot(x0, x0), dot(x1, x1), dot(x2, x2)), 0.0);
        vec3 h4 = h * h * h * h;
        vec3 n = h4 * vec3(dot(x0, lxSGrad(i, seed)), dot(x1, lxSGrad(i + o, seed)), dot(x2, lxSGrad(i + 1.0, seed)));
        return dot(n, vec3(70.0));
    }
    float lxMetric(vec2 d, float metric) {
        vec2 a = abs(d);
        return metric < 0.5 ? length(d) : (metric < 1.5 ? (a.x + a.y) * 0.7 : (metric < 2.5 ? max(a.x, a.y) : pow(a.x * a.x * a.x + a.y * a.y * a.y, 0.33333)));
    }
    vec3 lxWorley(vec2 p, vec2 per, float seed, float metric, float jit) {
        vec2 i = floor(p); vec2 f = p - i;
        float f1 = 8.0; float f2 = 8.0; float cid = 0.0;
        for (float y = -1.0; y <= 1.0; y += 1.0) {
            for (float x = -1.0; x <= 1.0; x += 1.0) {
                vec2 g = vec2(x, y);
                vec2 o = 0.5 + (lxC2(i + g, per, seed) - 0.5) * jit;
                float d = lxMetric(g + o - f, metric);
                if (d < f1) { f2 = f1; f1 = d; cid = lxC1(i + g, per, seed + 5.0); }
                else if (d < f2) { f2 = d; }
            }
        }
        return vec3(f1, f2, cid);
    }
    float lxFbm(vec2 p, vec2 per, float seed, float oct, float gain) {
        float s = 0.0; float amp = 0.5; float norm = 0.0; float fr = 1.0;
        for (float i = 0.0; i < 8.0; i += 1.0) {
            if (i < oct) {
                s += amp * lxPerlin(p * fr, per * fr, seed + i * 7.0);
                norm += amp; amp *= gain; fr *= 2.0;
            }
        }
        return s / max(norm, 0.0001);
    }
    float lxTurb(vec2 p, vec2 per, float seed, float oct, float gain) {
        float s = 0.0; float amp = 0.5; float norm = 0.0; float fr = 1.0;
        for (float i = 0.0; i < 8.0; i += 1.0) {
            if (i < oct) {
                s += amp * abs(lxPerlin(p * fr, per * fr, seed + i * 7.0));
                norm += amp; amp *= gain; fr *= 2.0;
            }
        }
        return s / max(norm, 0.0001);
    }
    float lxBand(float t, float duty, float soft, float aa) {
        float d = abs(fract(t) - 0.5) * 2.0;
        float e = max(soft, aa * 2.0) + 0.0001;
        return 1.0 - smoothstep(duty - e, duty + e, d);
    }
    float lxWeave(vec2 f, float par, float hw, float depth, float aa) {
        float inH = 1.0 - smoothstep(hw - aa, hw + aa + 0.0001, abs(f.y - 0.5));
        float inV = 1.0 - smoothstep(hw - aa, hw + aa + 0.0001, abs(f.x - 0.5));
        float ph = sqrt(max(0.0, 1.0 - (f.y - 0.5) * (f.y - 0.5) / (hw * hw)));
        float pv = sqrt(max(0.0, 1.0 - (f.x - 0.5) * (f.x - 0.5) / (hw * hw)));
        float th = 0.55 + 0.45 * cos((f.x - 0.5) * 3.14159265);
        float tv = 0.55 + 0.45 * cos((f.y - 0.5) * 3.14159265);
        float hTop = mix(1.0, ph * th, depth); float vTop = mix(1.0, pv * tv, depth);
        float hUnd = mix(0.6, 0.35 * ph, depth); float vUnd = mix(0.6, 0.35 * pv, depth);
        float v = 0.0;
        if (par > 0.5) { v = mix(v, vUnd, inV); v = mix(v, hTop, inH); }
        else { v = mix(v, hUnd, inH); v = mix(v, vTop, inV); }
        return v;
    }
    float lxSeg(vec2 p, vec2 s0, vec2 s1) {
        vec2 pa = p - s0; vec2 ba = s1 - s0;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 0.00001), 0.0, 1.0);
        return length(pa - ba * h);
    }
    """

    private static var kernels: [String: CIKernel] = [:]
    private static var failed: Set<String> = []
    private static let lock = NSLock()

    /// Full kernel source for a generator (exposed for tests).
    static func source(_ g: TextureGen) -> String {
        var decl = ""
        let slots = ["pa.y", "pa.z", "pa.w", "pb.x", "pb.y", "pb.z", "pb.w", "pc.x", "pc.y", "pc.z", "pc.w"]
        for (i, p) in g.params.enumerated() where i < slots.count { decl += "    float \(p.key) = \(slots[i]);\n" }
        return prelude + "\n" + g.helpers + """

        vec4 lxGen(vec2 q, vec2 per, float seed, float aa, vec2 nuv, vec4 pa, vec4 pb, vec4 pc, vec4 k0, vec4 k1, vec4 k2) {
        \(decl)
        \(g.body)
        }
        kernel vec4 lxMain(sampler lut, vec4 xf, vec4 tp, vec4 nv, vec4 cv, vec4 post, vec4 pa, vec4 pb, vec4 pc, vec4 k0, vec4 k1, vec4 k2) {
            vec2 d = destCoord();
            vec2 q = vec2(xf.x * d.x + xf.y * d.y + tp.x, xf.z * d.x + xf.w * d.y + tp.y);
            vec2 nuv = vec2(d.x * nv.x + nv.z, d.y * nv.y + nv.w);
            if (cv.y > 0.5) { nuv = fract(nuv); }
            vec4 g = lxGen(q, tp.zw, pa.x, cv.x, nuv, pa, pb, pc, k0, k1, k2);
            if (post.w > 0.5) {
                float t = dot(g.rgb, vec3(0.299, 0.587, 0.114));
                t = clamp((t - 0.5) * post.x + 0.5 + post.y, 0.0, 1.0);
                if (post.z > 0.5) { t = 1.0 - t; }
                vec4 L = sample(lut, samplerTransform(lut, vec2(t * 255.0 + 0.5, 0.5)));
                return vec4(clamp(L.rgb * g.a, 0.0, 1.0), L.a);
            }
            vec3 col = clamp((g.rgb - 0.5) * post.x + 0.5 + post.y, 0.0, 1.0);
            if (post.z > 0.5) { col = 1.0 - col; }
            return vec4(clamp(col * g.a, 0.0, 1.0), 1.0);
        }
        """
    }

    static func kernel(_ g: TextureGen) -> CIKernel? {
        lock.lock()
        if let k = kernels[g.id] { lock.unlock(); return k }
        let bad = failed.contains(g.id)
        lock.unlock()
        if bad { return nil }
        // compile outside the lock (a background prewarm must not stall the main thread asking for another kernel)
        let k = CIKernel(source: source(g))
        lock.lock(); defer { lock.unlock() }
        if let existing = kernels[g.id] { return existing }
        guard let k else {
            failed.insert(g.id)
            print("TextureEngine: kernel for '\(g.id)' failed to compile")
            return nil
        }
        kernels[g.id] = k
        return k
    }

    private static var prewarmed = false
    /// Compiles every generator kernel on a background queue (called when the texture dialog or the Recipe Editor opens).
    static func prewarm() {
        lock.lock()
        let done = prewarmed
        prewarmed = true
        lock.unlock()
        if done { return }
        DispatchQueue.global(qos: .utility).async { for g in TextureCatalog.all { _ = kernel(g) } }
    }

    // Gradient LUT images are cached so an unchanged ramp keeps the same CIImage (and GPU texture).
    private static var lutCache: [(ColorGradient, CIImage)] = []
    static func lut(_ g: ColorGradient) -> CIImage {
        lock.lock(); defer { lock.unlock() }
        if let c = lutCache.first(where: { $0.0 == g }) { return c.1 }
        let img = Kernels.gradientLUT(g)
        lutCache.insert((g, img), at: 0)
        if lutCache.count > 64 { lutCache.removeLast() }
        return img
    }

    static let seamlessKernel = CIKernel(source: """
    kernel vec4 lxSeamless(sampler src, vec4 r, float blend) {
        vec2 d = destCoord();
        vec2 uv = (d - r.xy) / r.zw;
        vec2 sh = vec2(uv.x < 0.5 ? 0.5 : -0.5, uv.y < 0.5 ? 0.5 : -0.5);
        vec2 w = smoothstep(0.0, blend, 0.5 - abs(uv - 0.5));
        vec4 c00 = sample(src, samplerTransform(src, d));
        vec4 c10 = sample(src, samplerTransform(src, d + vec2(sh.x * r.z, 0.0)));
        vec4 c01 = sample(src, samplerTransform(src, d + vec2(0.0, sh.y * r.w)));
        vec4 c11 = sample(src, samplerTransform(src, d + sh * r.zw));
        return mix(mix(c11, c01, w.x), mix(c10, c00, w.x), w.y);
    }
    """)

    /// Cross-blends the borders of `img` (finite extent) so it repeats seamlessly.
    static func makeSeamless(_ img: CIImage, blend: Double = 0.25) -> CIImage {
        let r = img.extent
        guard let k = seamlessKernel, !r.isInfinite, !r.isEmpty else { return img }
        let b = Float(min(max(blend, 0.02), 0.5))
        return k.apply(extent: r, roiCallback: { _, _ in r }, arguments: [img, CIVector(cgRect: r), b]) ?? img
    }

    /// Repeats a finite image across the plane.
    static func tiled(_ img: CIImage) -> CIImage {
        img.applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: NSAffineTransform()])
    }

    /// Renders a texture. `space` is the canvas; `extent` is the CI-space rect to cover (default: the canvas).
    /// `origin` shifts the pattern (document px, y down).
    static func render(_ s: TextureSettings, space: CanvasSpace, extent: CGRect? = nil, origin: CGPoint = .zero) -> CIImage {
        let ext = extent ?? space.ciCanvas
        guard let g = TextureCatalog.gen(s.gen), let k = kernel(g) else { return CIImage.clearImage.cropped(to: ext) }
        let W = Double(space.width), H = Double(space.height)
        var vals: [String: Double] = [:]
        for p in TextureCatalog.commonParams(g) + g.params { vals[p.key] = p.sanitized(s.values[p.key] ?? p.def) }
        let scale = max(0.05, vals["scale"] ?? g.scale)
        let rot = (vals["rotation"] ?? 0) * .pi / 180
        let offX = (vals["offsetX"] ?? 0) + Double(origin.x), offY = (vals["offsetY"] ?? 0) + Double(origin.y)
        let seed = vals["seed"] ?? 0
        let tile = (vals["tileable"] ?? 0) > 0.5
        let tw = (vals["tileW"] ?? 0) >= 1 ? vals["tileW"]! : W
        let th = (vals["tileH"] ?? 0) >= 1 ? vals["tileH"]! : H
        let native = g.nativeTile(vals)

        var xf = CIVector(x: 0, y: 0, z: 0, w: 0), tp = CIVector(x: 0, y: 0, z: 0, w: 0)
        var nv = CIVector(x: CGFloat(1 / W), y: CGFloat(-1 / H), z: 0, w: 1)
        var aa = 1 / scale
        var tileFlag = 0.0
        if tile && native {
            // Integer repeat counts per axis; rotation snaps to quarter turns.
            let (px0, py0) = g.period(vals)
            let px = px0 > 0 ? px0 : 1, py = py0 > 0 ? py0 : 1
            let rdeg = vals["rotation"] ?? 0
            let kq = ((Int((rdeg / 90).rounded()) % 4) + 4) % 4
            let odd = kq % 2 == 1
            let dimX = odd ? th : tw, dimY = odd ? tw : th
            let nx = max(1, (dimX / (scale * px)).rounded()), ny = max(1, (dimY / (scale * py)).rounded())
            let Px = nx * px, Py = ny * py
            // u = (d.x - offX) / tw ; v = (H - d.y - offY) / th
            let ux = 1 / tw, u0 = -offX / tw
            let vy = -1 / th, v0 = (H - offY) / th
            switch kq {
            case 0: xf = CIVector(x: CGFloat(ux * Px), y: 0, z: 0, w: CGFloat(vy * Py)); tp = CIVector(x: CGFloat(u0 * Px), y: CGFloat(v0 * Py), z: CGFloat(Px), w: CGFloat(Py))
            case 1: xf = CIVector(x: 0, y: CGFloat(vy * Px), z: CGFloat(-ux * Py), w: 0); tp = CIVector(x: CGFloat(v0 * Px), y: CGFloat(-u0 * Py), z: CGFloat(Px), w: CGFloat(Py))
            case 2: xf = CIVector(x: CGFloat(-ux * Px), y: 0, z: 0, w: CGFloat(-vy * Py)); tp = CIVector(x: CGFloat(-u0 * Px), y: CGFloat(-v0 * Py), z: CGFloat(Px), w: CGFloat(Py))
            default: xf = CIVector(x: 0, y: CGFloat(-vy * Px), z: CGFloat(ux * Py), w: 0); tp = CIVector(x: CGFloat(-v0 * Px), y: CGFloat(u0 * Py), z: CGFloat(Px), w: CGFloat(Py))
            }
            aa = max(Px / dimX, Py / dimY)
            nv = CIVector(x: CGFloat(1 / tw), y: CGFloat(-1 / th), z: 0, w: CGFloat(H / th))
            tileFlag = 1
        } else {
            let cw = tile ? tw : W, ch = tile ? th : H
            let cx = cw / 2 + offX, cyDoc = ch / 2 + offY
            let c = cos(rot), sn = sin(rot)
            // q = R(-rot) * ((d.x - cx), (H - d.y - cyDoc)) / scale
            let ty0 = H - cyDoc
            xf = CIVector(x: CGFloat(c / scale), y: CGFloat(-sn / scale), z: CGFloat(-sn / scale), w: CGFloat(-c / scale))
            tp = CIVector(x: CGFloat((-c * cx + sn * ty0) / scale), y: CGFloat((sn * cx + c * ty0) / scale), z: 0, w: 0)
            if tile { nv = CIVector(x: CGFloat(1 / tw), y: CGFloat(-1 / th), z: 0, w: CGFloat(H / th)) }
        }

        let contrast = vals["contrast"] ?? 0
        let slope = contrast >= 0 ? 1 + contrast / 100 * 3 : 1 + contrast / 100
        let useRamp = !g.direct || (vals["mapRamp"] ?? 0) > 0.5
        let post = CIVector(x: CGFloat(slope), y: CGFloat((vals["brightness"] ?? 0) / 100), z: CGFloat(vals["invert"] ?? 0), w: useRamp ? 1 : 0)
        let cv = CIVector(x: CGFloat(aa), y: CGFloat(tileFlag), z: 0, w: 0)

        var p = [Double](repeating: 0, count: 12)
        p[0] = seed
        for (i, prm) in g.params.enumerated() where i < 11 { p[i + 1] = vals[prm.key] ?? prm.def }
        func v4(_ i: Int) -> CIVector { CIVector(x: CGFloat(p[i]), y: CGFloat(p[i + 1]), z: CGFloat(p[i + 2]), w: CGFloat(p[i + 3])) }
        func col(_ i: Int) -> CIVector {
            guard i < g.colors.count else { return CIVector(x: 0, y: 0, z: 0, w: 1) }
            let c = s.colors[g.colors[i].key] ?? g.colors[i].def
            return CIVector(x: CGFloat(c.r), y: CGFloat(c.g), z: CGFloat(c.b), w: CGFloat(c.a))
        }
        let lutImg = lut(s.ramp ?? g.ramp)
        let lutExt = lutImg.extent
        let args: [Any] = [lutImg, xf, tp, nv, cv, post, v4(0), v4(4), v4(8), col(0), col(1), col(2)]

        if tile && !native {
            // Render one tile, cross-blend its borders, then repeat it.
            let tileRect = CGRect(x: 0, y: H - th, width: tw, height: th)
            guard let one = k.apply(extent: tileRect, roiCallback: { _, _ in lutExt }, arguments: args) else { return CIImage.clearImage.cropped(to: ext) }
            return tiled(makeSeamless(one)).cropped(to: ext)
        }
        return k.apply(extent: ext, roiCallback: { _, _ in lutExt }, arguments: args) ?? CIImage.clearImage.cropped(to: ext)
    }

    /// One repeat of a tileable texture as a pixel buffer (for the Patterns library).
    static func tileBuffer(_ s: TextureSettings, width: Int, height: Int) -> PixelBuffer {
        var t = s
        t.values["tileable"] = 1
        t.values["tileW"] = Double(width); t.values["tileH"] = Double(height)
        t.values["offsetX"] = 0; t.values["offsetY"] = 0
        let sp = CanvasSpace(width: width, height: height)
        return RenderEngine.renderBuffer(render(t, space: sp), docRect: IRect(x: 0, y: 0, width: width, height: height), space: sp)
    }
}
