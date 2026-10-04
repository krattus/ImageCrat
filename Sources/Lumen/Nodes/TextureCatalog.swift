import Foundation
import ImageCratCore

/// All procedural texture generators (Filter ▸ Render ▸ Textures and the Recipe "Generate" nodes).
enum TextureCatalog {
    static let all: [TextureGen] = noise + patterns + natural + tech
    private static let index: [String: TextureGen] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func gen(_ id: String) -> TextureGen? { index[id] }
    static func byCategory(_ c: TextureCategory) -> [TextureGen] { all.filter { $0.category == c } }

    /// Parameters every generator has (scale / rotation / offset / seed / contrast / tiling).
    static func commonParams(_ g: TextureGen) -> [TexParam] {
        var p: [TexParam] = [
            .s("scale", "Scale", 1...1024, g.scale), .s("rotation", "Rotation", -180...180, 0),
            .s("offsetX", "Offset X", -2000...2000, 0), .s("offsetY", "Offset Y", -2000...2000, 0),
            .i("seed", "Seed", 0...9999, 1),
            .s("contrast", "Contrast", -100...100, 0), .s("brightness", "Brightness", -100...100, 0),
            .t("invert", "Invert", false), .t("tileable", "Tileable", false),
            .i("tileW", "Tile Width", 0...8192, 0), .i("tileH", "Tile Height", 0...8192, 0),
        ]
        if g.direct { p.append(.t("mapRamp", "Map to Gradient", false)) }
        return p
    }

    static func ramp(_ name: String, _ stops: [(Double, String)]) -> ColorGradient {
        ColorGradient(name: name, stops: stops.map { GradientStop(location: $0.0, color: RGBA(hex: $0.1) ?? .black) })
    }

    private static let loop3x3Open = "for (float gy = -1.0; gy <= 1.0; gy += 1.0) { for (float gx = -1.0; gx <= 1.0; gx += 1.0) { vec2 g = vec2(gx, gy);"
    private static let loop3x3Close = "} }"

    // MARK: Noise

    static let noise: [TextureGen] = [
        TextureGen(id: "perlin", name: "Perlin Noise", category: .noise, scale: 64, keywords: ["gradient noise"], body: """
            return lxG(0.5 + 0.5 * lxPerlin(q, per, seed));
        """),
        TextureGen(id: "simplex", name: "Simplex Noise", category: .noise, scale: 64, nativeTile: { _ in false }, body: """
            return lxG(0.5 + 0.5 * lxSimplex(q, seed));
        """),
        TextureGen(id: "value", name: "Value Noise", category: .noise, scale: 48,
                   params: [.t("blocky", "Blocky (no smoothing)", false)], body: """
            float v = blocky > 0.5 ? lxC1(floor(q), per, seed) : lxValue(q, per, seed);
            return lxG(v);
        """),
        TextureGen(id: "worley", name: "Worley / Voronoi", category: .noise, scale: 64,
                   params: [.c("mode", "Output", ["F1 (distance)", "F2", "F2 − F1 (cell edges)", "Cell Value", "Crackle"], 0),
                            .c("metric", "Distance Metric", ["Euclidean", "Manhattan", "Chebyshev", "Minkowski"], 0),
                            .s("jitter", "Jitter", 0...1, 1)],
                   keywords: ["voronoi", "cellular", "cells"], body: """
            vec3 w = lxWorley(q, per, seed, metric, jitter);
            float v = mode < 0.5 ? w.x : (mode < 1.5 ? w.y * 0.75 : (mode < 2.5 ? (w.y - w.x) * 1.4 : (mode < 3.5 ? w.z : 1.0 - smoothstep(0.0, 0.12, w.y - w.x))));
            return lxG(v);
        """),
        TextureGen(id: "cells", name: "Voronoi Cell Colors", category: .noise, scale: 64,
                   params: [.c("metric", "Distance Metric", ["Euclidean", "Manhattan", "Chebyshev", "Minkowski"], 0),
                            .s("jitter", "Jitter", 0...1, 1), .s("border", "Border", 0...0.3, 0.04), .t("palette", "Use Palette Colors", false)],
                   colors: [("c0", "Color A", RGBA(hex: "E94F37")!), ("c1", "Color B", RGBA(hex: "F6AE2D")!), ("c2", "Color C", RGBA(hex: "2E86AB")!)],
                   direct: true, keywords: ["voronoi", "stained glass", "mosaic"], body: """
            vec2 ci = floor(q); vec2 f = q - ci;
            float f1 = 8.0; float f2 = 8.0; vec2 best = vec2(0.0);
            \(loop3x3Open)
                vec2 o = 0.5 + (lxC2(ci + g, per, seed) - 0.5) * jitter;
                float d = lxMetric(g + o - f, metric);
                if (d < f1) { f2 = f1; f1 = d; best = lxWrap(ci + g, per); }
                else if (d < f2) { f2 = d; }
            \(loop3x3Close)
            vec3 rnd = lxH3(best + lxSeedOff(seed + 9.0));
            vec3 col = rnd;
            if (palette > 0.5) {
                col = rnd.x < 0.333 ? k0.rgb : (rnd.x < 0.666 ? k1.rgb : k2.rgb);
                col *= 0.85 + 0.3 * rnd.y;
            }
            float edge = border > 0.001 ? smoothstep(border - aa, border + aa + 0.0001, f2 - f1) : 1.0;
            return vec4(col * mix(0.12, 1.0, edge), 1.0);
        """),
        TextureGen(id: "fbm", name: "fBm (Fractal Noise)", category: .noise, scale: 160,
                   params: [.c("basis", "Basis", ["Perlin", "Value", "Simplex"], 0), .i("octaves", "Octaves", 1...8, 5), .s("gain", "Roughness", 0.2...0.85, 0.5)],
                   nativeTile: { ($0["basis"] ?? 0) < 1.5 }, keywords: ["fractal", "brownian"], body: """
            float n = 0.0; float amp = 0.5; float norm = 0.0; float fr = 1.0;
            for (float i = 0.0; i < 8.0; i += 1.0) {
                if (i < octaves) {
                    float b = basis < 0.5 ? lxPerlin(q * fr, per * fr, seed + i * 7.0)
                        : (basis < 1.5 ? lxValue(q * fr, per * fr, seed + i * 7.0) * 2.0 - 1.0 : lxSimplex(q * fr, seed + i * 7.0));
                    n += amp * b; norm += amp; amp *= gain; fr *= 2.0;
                }
            }
            return lxG(0.5 + 0.95 * n / norm);
        """),
        TextureGen(id: "ridged", name: "Ridged Multifractal", category: .noise, scale: 200,
                   params: [.i("octaves", "Octaves", 1...8, 6), .s("gain", "Roughness", 0.2...0.85, 0.5), .s("sharp", "Sharpness", 0.5...4, 2)],
                   keywords: ["ridge", "mountain"], body: """
            float n = 0.0; float amp = 0.5; float norm = 0.0; float fr = 1.0; float prev = 1.0;
            for (float i = 0.0; i < 8.0; i += 1.0) {
                if (i < octaves) {
                    float r = pow(1.0 - abs(lxPerlin(q * fr, per * fr, seed + i * 7.0)), sharp);
                    n += amp * r * prev; prev = clamp(r * 1.5, 0.0, 1.0);
                    norm += amp; amp *= gain; fr *= 2.0;
                }
            }
            return lxG(n / norm * 1.25);
        """),
        TextureGen(id: "turbulence", name: "Turbulence", category: .noise, scale: 160,
                   params: [.i("octaves", "Octaves", 1...8, 5), .s("gain", "Roughness", 0.2...0.85, 0.5)], body: """
            return lxG(lxTurb(q, per, seed, octaves, gain) * 2.4);
        """),
        TextureGen(id: "billow", name: "Billow", category: .noise, scale: 160,
                   params: [.i("octaves", "Octaves", 1...8, 5), .s("gain", "Roughness", 0.2...0.85, 0.5)], keywords: ["puffy", "cloud"], body: """
            float n = 0.0; float amp = 0.5; float norm = 0.0; float fr = 1.0;
            for (float i = 0.0; i < 8.0; i += 1.0) {
                if (i < octaves) {
                    n += amp * (abs(lxPerlin(q * fr, per * fr, seed + i * 7.0)) * 2.0 - 1.0);
                    norm += amp; amp *= gain; fr *= 2.0;
                }
            }
            return lxG(0.5 + 0.5 * (n / norm + 0.45) * 1.6);
        """),
        TextureGen(id: "warp", name: "Domain-Warped Noise", category: .noise, scale: 220,
                   params: [.s("strength", "Warp", 0...4, 1.6), .i("octaves", "Octaves", 1...8, 5), .s("gain", "Roughness", 0.2...0.85, 0.5), .t("twice", "Warp Twice", true)],
                   keywords: ["warp", "swirl", "marbling"], body: """
            vec2 o1 = vec2(lxFbm(q, per, seed, octaves, gain), lxFbm(q + vec2(5.2, 1.3), per, seed + 3.0, octaves, gain));
            vec2 p2 = q + strength * o1;
            if (twice > 0.5) {
                vec2 o2 = vec2(lxFbm(p2 + vec2(1.7, 9.2), per, seed + 5.0, octaves, gain), lxFbm(p2 + vec2(8.3, 2.8), per, seed + 8.0, octaves, gain));
                p2 = q + strength * o2;
            }
            float n = lxFbm(p2, per, seed + 11.0, octaves, gain);
            return lxG(0.5 + 0.8 * n + 0.25 * (length(o1) - 0.3));
        """),
        TextureGen(id: "curl", name: "Curl / Flow Noise", category: .noise, scale: 260,
                   params: [.c("mode", "Output", ["Flow Lines", "Direction", "Speed"], 0), .i("steps", "Streak Length", 2...12, 8),
                            .i("detail", "Detail", 4...48, 24), .i("swirl", "Swirl Octaves", 1...4, 2)],
                   keywords: ["flow", "lic", "fluid", "smoke"], body: """
            float e = 0.02;
            float a1 = lxFbm(q + vec2(0.0, e), per, seed, swirl, 0.5); float a2 = lxFbm(q - vec2(0.0, e), per, seed, swirl, 0.5);
            float b1 = lxFbm(q + vec2(e, 0.0), per, seed, swirl, 0.5); float b2 = lxFbm(q - vec2(e, 0.0), per, seed, swirl, 0.5);
            vec2 v0 = vec2(a1 - a2, -(b1 - b2)) / (2.0 * e);
            if (mode > 1.5) { return lxG(length(v0) * 0.45); }
            if (mode > 0.5) { return lxG(atan(v0.y, v0.x) / 6.2831853 + 0.5); }
            float acc = 0.0; float wsum = 0.0;
            for (float dir = -1.0; dir <= 1.0; dir += 2.0) {
                vec2 pos = q;
                for (float i = 0.0; i < 12.0; i += 1.0) {
                    if (i < steps) {
                        float c1 = lxFbm(pos + vec2(0.0, e), per, seed, swirl, 0.5); float c2 = lxFbm(pos - vec2(0.0, e), per, seed, swirl, 0.5);
                        float d1 = lxFbm(pos + vec2(e, 0.0), per, seed, swirl, 0.5); float d2 = lxFbm(pos - vec2(e, 0.0), per, seed, swirl, 0.5);
                        vec2 vel = vec2(c1 - c2, -(d1 - d2));
                        pos += dir * vel / max(length(vel), 0.00001) * 0.025;
                        float wgt = 1.0 - i / steps;
                        acc += wgt * lxValue(pos * detail, per * detail, seed + 31.0); wsum += wgt;
                    }
                }
            }
            return lxG(0.5 + (acc / wsum - 0.5) * 3.2);
        """),
    ]

    // MARK: Patterns

    static let patterns: [TextureGen] = [
        TextureGen(id: "stripes", name: "Stripes", category: .pattern, scale: 40,
                   params: [.s("duty", "Stripe Width", 0.05...0.95, 0.5), .s("soft", "Softness", 0...0.5, 0)], keywords: ["lines", "bars"], body: """
            return lxG(lxBand(q.x, duty, soft, aa));
        """),
        TextureGen(id: "checker", name: "Checkerboard", category: .pattern, scale: 48, period: { _ in (2, 2) }, keywords: ["check", "chess"], body: """
            vec2 c = floor(q);
            float v = lxMod(c.x + c.y, 2.0);
            vec2 g = abs(fract(q) - 0.5);
            float de = 0.5 - max(g.x, g.y);
            v = mix(0.5, v, smoothstep(0.0, aa + 0.0001, de));
            return lxG(v);
        """),
        TextureGen(id: "dots", name: "Dots / Halftone Grid", category: .pattern, scale: 24,
                   params: [.s("radius", "Radius", 0.05...0.75, 0.3), .s("soft", "Softness", 0...1, 0.05), .t("stagger", "Stagger Rows", false),
                            .c("shape", "Shape", ["Circle", "Square", "Diamond", "Halftone Screen"], 0)],
                   period: { _ in (1, 2) }, keywords: ["halftone", "screen", "grid"], body: """
            vec2 p = q;
            if (stagger > 0.5) { p.x += 0.5 * lxMod(floor(p.y), 2.0); }
            if (shape > 2.5) { return lxG(0.5 + 0.25 * (cos(6.2831853 * p.x) + cos(6.2831853 * p.y))); }
            vec2 f = fract(p) - 0.5;
            float d = shape < 0.5 ? length(f) : (shape < 1.5 ? max(abs(f.x), abs(f.y)) : abs(f.x) + abs(f.y));
            float e = max(soft * 0.5, aa) + 0.0001;
            return lxG(1.0 - smoothstep(radius - e, radius + e, d));
        """),
        TextureGen(id: "hexgrid", name: "Hex Grid", category: .pattern, scale: 48,
                   params: [.s("width", "Line Width", 0.01...0.5, 0.08), .c("mode", "Style", ["Outline", "Random Shade", "Gradient"], 0)],
                   period: { _ in (1, 1.7320508) }, keywords: ["honeycomb", "hexagon"], body: """
            vec2 s = vec2(1.0, 1.7320508);
            vec4 hC = floor(vec4(q, q - vec2(0.5, 1.0)) / s.xyxy) + 0.5;
            vec4 h = vec4(q - hC.xy * s, q - (hC.zw + 0.5) * s);
            float first = step(dot(h.xy, h.xy), dot(h.zw, h.zw));
            vec2 loc = mix(h.zw, h.xy, first);
            vec2 cid = mix(hC.zw + 0.5, hC.xy, first);
            vec2 al = abs(loc);
            float hd = max(dot(al, s * 0.5), al.x);
            float edge = 0.5 - hd;
            float line = 1.0 - smoothstep(width * 0.5 - aa, width * 0.5 + aa + 0.0001, edge);
            vec2 wp = vec2(per.x * 2.0, floor(per.y * 2.0 / 1.7320508 + 0.5));
            float rnd = lxH1(lxWrap(floor(cid * 2.0 + 0.5), wp) + lxSeedOff(seed));
            float v = mode < 0.5 ? line : (mode < 1.5 ? mix(0.25 + 0.75 * rnd, 0.0, line) : mix(1.0 - hd * 2.0, 0.0, line));
            return lxG(v);
        """),
        TextureGen(id: "bricks", name: "Bricks", category: .pattern, scale: 40,
                   params: [.c("bond", "Bond", ["Running", "Stack", "Third"], 0), .s("aspect", "Brick Aspect", 1...5, 2.2), .s("mortar", "Mortar", 0...0.4, 0.1),
                            .s("bevel", "Bevel", 0...0.5, 0.08), .s("variation", "Color Variation", 0...1, 0.6), .s("rough", "Roughness", 0...1, 0.4)],
                   ramp: ramp("Bricks", [(0, "CFC6B8"), (0.3, "6E2A1C"), (0.7, "A8432D"), (1, "C86A4A")]),
                   period: { v in (v["aspect"] ?? 2.2, (v["bond"] ?? 0) > 1.5 ? 3 : 2) }, keywords: ["wall", "masonry"], body: """
            float row = floor(q.y);
            float sh = bond < 0.5 ? 0.5 * lxMod(row, 2.0) : (bond < 1.5 ? 0.0 : lxMod(row, 3.0) / 3.0);
            float bx = q.x / aspect + sh;
            float colI = floor(bx);
            vec2 f = vec2(bx - colI, q.y - row);
            float dx = min(f.x, 1.0 - f.x) * aspect; float dy = min(f.y, 1.0 - f.y);
            float d = min(dx, dy);
            float m = smoothstep(mortar * 0.5 - aa, mortar * 0.5 + aa + 0.0001, d);
            float bv = smoothstep(mortar * 0.5, mortar * 0.5 + bevel + 0.0001, d);
            float nbx = per.x > 0.5 ? floor(per.x / aspect + 0.5) : 0.0;
            float rnd = lxH1(lxWrap(vec2(colI, row), vec2(nbx, per.y)) + lxSeedOff(seed));
            float grain = lxValue(vec2(bx * 6.0, q.y * 9.0), vec2(nbx * 6.0, per.y * 9.0), seed + 3.0);
            float v = 0.7 + variation * (rnd - 0.5) * 0.6 + rough * (grain - 0.5) * 0.3;
            v = clamp(v * (0.78 + 0.22 * bv), 0.32, 1.0);
            return lxG(mix(0.0, v, m));
        """),
        TextureGen(id: "tiles", name: "Tiles", category: .pattern, scale: 56,
                   params: [.s("grout", "Grout", 0...0.4, 0.07), .s("bevel", "Bevel", 0...0.5, 0.12), .s("corner", "Corner Radius", 0...0.45, 0.06),
                            .s("variation", "Shade Variation", 0...1, 0.4)],
                   ramp: ramp("Tiles", [(0, "3C3A38"), (0.35, "7FA7B8"), (0.75, "B9D4DE"), (1, "EAF4F7")]), keywords: ["grid", "floor", "ceramic"], body: """
            vec2 c = floor(q); vec2 f = q - c - 0.5;
            vec2 dd = abs(f) - (0.5 - grout * 0.5 - corner);
            float sd = length(max(dd, 0.0)) + min(max(dd.x, dd.y), 0.0) - corner;
            float m = 1.0 - smoothstep(-aa, aa + 0.0001, sd);
            float bv = smoothstep(0.0, bevel + 0.0001, -sd);
            float rnd = lxC1(c, per, seed);
            float v = (0.72 + variation * (rnd - 0.5) * 0.55) * (0.7 + 0.3 * bv);
            return lxG(mix(0.0, clamp(v, 0.3, 1.0), m));
        """),
        TextureGen(id: "weave", name: "Weave / Fabric", category: .pattern, scale: 20,
                   params: [.s("width", "Thread Width", 0.3...1, 0.82), .c("style", "Weave", ["Plain", "Twill", "Basket"], 0), .s("depth", "Shading", 0...1, 0.75)],
                   period: { _ in (4, 4) }, keywords: ["fabric", "cloth", "textile", "basket"], body: """
            vec2 c = floor(q); vec2 f = q - c;
            float par = style < 0.5 ? lxMod(c.x + c.y, 2.0) : (style < 1.5 ? step(1.5, lxMod(c.x + c.y, 4.0)) : lxMod(floor(c.x * 0.5) + floor(c.y * 0.5), 2.0));
            return lxG(lxWeave(f, par, width * 0.5, depth, aa));
        """),
        TextureGen(id: "herringbone", name: "Herringbone", category: .pattern, scale: 22,
                   params: [.i("aspect", "Brick Length", 2...6, 3), .s("mortar", "Gap", 0...0.4, 0.08), .s("bevel", "Bevel", 0...0.5, 0.1),
                            .s("variation", "Shade Variation", 0...1, 0.5)],
                   ramp: ramp("Parquet", [(0, "2B1A10"), (0.35, "7A4E2A"), (0.75, "B07C45"), (1, "D8AE74")]),
                   period: { v in (2 * (v["aspect"] ?? 3).rounded(), 2 * (v["aspect"] ?? 3).rounded()) }, keywords: ["parquet", "floor"], body: """
            float n = floor(aspect + 0.5);
            vec2 c = floor(q); vec2 f = q - c;
            float m = lxMod(c.x - c.y, 2.0 * n);
            vec2 uv = vec2(0.0); vec2 bid = vec2(0.0); vec2 dims = vec2(1.0); float vert = 0.0;
            if (m < n) { uv = vec2((m + f.x) / n, f.y); bid = vec2(c.x - m, c.y); dims = vec2(n, 1.0); }
            else { float r = 2.0 * n - 1.0 - m; uv = vec2(f.x, (r + f.y) / n); bid = vec2(c.x, c.y - r); dims = vec2(1.0, n); vert = 1.0; }
            float dx = min(uv.x, 1.0 - uv.x) * dims.x; float dy = min(uv.y, 1.0 - uv.y) * dims.y;
            float d = min(dx, dy);
            float mk = smoothstep(mortar * 0.5 - aa, mortar * 0.5 + aa + 0.0001, d);
            float bv = smoothstep(mortar * 0.5, mortar * 0.5 + bevel + 0.0001, d);
            float rnd = lxH1(lxWrap(bid, per) + lxSeedOff(seed + vert * 31.0));
            float v = (0.72 + variation * (rnd - 0.5) * 0.6 - vert * 0.06) * (0.75 + 0.25 * bv);
            return lxG(mix(0.0, clamp(v, 0.3, 1.0), mk));
        """),
        TextureGen(id: "chevron", name: "Chevron", category: .pattern, scale: 60,
                   params: [.s("amp", "Slope", 0...3, 1), .s("duty", "Stripe Width", 0.05...0.95, 0.5), .s("soft", "Softness", 0...0.5, 0)],
                   keywords: ["zigzag"], body: """
            float y = q.y + abs(fract(q.x) - 0.5) * 2.0 * amp;
            return lxG(lxBand(y, duty, soft, aa * (1.0 + amp)));
        """),
        TextureGen(id: "plaid", name: "Plaid / Tartan", category: .pattern, scale: 160,
                   params: [.s("bandw", "Band Width", 0.1...0.6, 0.3), .i("threads", "Thread Density", 2...24, 10), .s("twill", "Twill Texture", 0...1, 0.85)],
                   colors: [("c0", "Base", RGBA(hex: "1F3A5F")!), ("c1", "Band", RGBA(hex: "B22234")!), ("c2", "Lines", RGBA(hex: "F2E9D0")!)],
                   direct: true, keywords: ["tartan", "scottish", "check"],
                   helpers: """
                   vec3 lxTartan(float t, vec3 c0, vec3 c1, vec3 c2, float w) {
                       float u = fract(t);
                       vec3 col = mix(c0, c1, step(abs(u - 0.25), w * 0.5));
                       float ln = step(abs(u - 0.62), 0.022) + step(abs(u - 0.75), 0.022) + step(abs(u - 0.25), 0.015);
                       return mix(col, c2, clamp(ln, 0.0, 1.0));
                   }
                   """, body: """
            vec3 cx = lxTartan(q.x, k0.rgb, k1.rgb, k2.rgb, bandw);
            vec3 cy = lxTartan(q.y, k0.rgb, k1.rgb, k2.rgb, bandw);
            float th = floor(threads + 0.5) * 4.0;
            float tw = step(1.5, lxMod(floor(q.x * th) + floor(q.y * th), 4.0));
            vec3 col = mix(mix(cx, cy, 0.5), mix(cx, cy, tw), twill);
            return vec4(col, 1.0);
        """),
        TextureGen(id: "truchet", name: "Truchet", category: .pattern, scale: 48,
                   params: [.c("style", "Style", ["Arcs", "Maze Lines", "Triangles"], 0), .s("width", "Line Width", 0.02...0.5, 0.16)],
                   keywords: ["maze", "arcs", "tiles"], body: """
            vec2 c = floor(q); vec2 f = q - c;
            if (lxC1(c, per, seed) > 0.5) { f.x = 1.0 - f.x; }
            float v = 0.0;
            if (style < 0.5) {
                float d = min(abs(length(f) - 0.5), abs(length(f - 1.0) - 0.5));
                v = 1.0 - smoothstep(width * 0.5 - aa, width * 0.5 + aa + 0.0001, d);
            } else if (style < 1.5) {
                float d = abs(f.x + f.y - 1.0) * 0.7071;
                v = 1.0 - smoothstep(width * 0.5 - aa, width * 0.5 + aa + 0.0001, d);
            } else {
                v = smoothstep(-aa, aa + 0.0001, (1.0 - f.x - f.y) * 0.7071);
            }
            return lxG(v);
        """),
        TextureGen(id: "polka", name: "Polka Dots", category: .pattern, scale: 56,
                   params: [.s("radius", "Radius", 0.05...0.45, 0.22), .s("sizevar", "Size Variation", 0...1, 0), .s("jitter", "Jitter", 0...0.6, 0),
                            .s("density", "Density", 0...1, 1), .s("soft", "Softness", 0...0.3, 0.01)],
                   keywords: ["dots", "spots"], body: """
            float v = 0.0;
            float e = max(soft, aa) + 0.0001;
            for (float gi = 0.0; gi < 2.0; gi += 1.0) {
                vec2 p = q + gi * 0.5;
                vec2 c = floor(p); vec2 f = p - c;
                \(loop3x3Open)
                    vec3 rnd = lxC3(c + g, per, seed + gi * 13.0);
                    float on = step(lxC1(c + g, per, seed + gi * 13.0 + 40.0), density);
                    vec2 ctr = g + 0.5 + (rnd.xy - 0.5) * jitter;
                    float rr = radius * (1.0 - sizevar * rnd.z);
                    v = max(v, on * (1.0 - smoothstep(rr - e, rr + e, length(f - ctr))));
                \(loop3x3Close)
            }
            return lxG(v);
        """),
        TextureGen(id: "waves", name: "Waves", category: .pattern, scale: 80,
                   params: [.s("amp", "Amplitude", 0...2, 0.3), .i("freq", "Frequency", 1...8, 1), .s("duty", "Line Width", 0.05...0.95, 0.5),
                            .s("soft", "Softness", 0...0.5, 0.05), .s("phase", "Phase", 0...1, 0)],
                   keywords: ["sine", "ripple", "wavy"], body: """
            float fq = floor(freq + 0.5);
            float y = q.y + amp * sin(6.2831853 * (q.x * fq + phase));
            return lxG(lxBand(y, duty, soft, aa * (1.0 + 3.0 * amp * fq)));
        """),
        TextureGen(id: "spirals", name: "Spirals", category: .pattern, scale: 120,
                   params: [.i("arms", "Arms", 1...12, 3), .s("twist", "Twist", 0.1...5, 1), .s("duty", "Arm Width", 0.05...0.95, 0.5),
                            .s("soft", "Softness", 0...0.5, 0.02), .c("kind", "Type", ["Archimedean", "Logarithmic"], 0)],
                   nativeTile: { _ in false }, keywords: ["swirl", "vortex"], body: """
            float r = length(q); float th = atan(q.y, q.x);
            float n = floor(arms + 0.5);
            float t = th * n / 6.2831853 + (kind < 0.5 ? r * twist : log(max(r, 0.0001)) * twist * 2.0);
            float w = aa * (twist + n / (6.2831853 * max(r, 0.05)));
            return lxG(lxBand(t, duty, soft, w));
        """),
        TextureGen(id: "stars", name: "Stars", category: .pattern, scale: 72,
                   params: [.i("points", "Points", 3...12, 5), .s("inner", "Inner Radius", 0.1...0.95, 0.42), .s("size", "Size", 0.1...0.7, 0.42),
                            .s("spin", "Random Rotation", 0...1, 0), .t("stagger", "Stagger Rows", true), .s("soft", "Softness", 0...0.3, 0)],
                   period: { _ in (1, 2) }, keywords: ["star", "flag"], body: """
            vec2 p = q;
            if (stagger > 0.5) { p.x += 0.5 * lxMod(floor(p.y), 2.0); }
            vec2 c = floor(p); vec2 f = p - c - 0.5;
            float n = floor(points + 0.5);
            float k = 3.14159265 / n;
            float rot = spin * 6.2831853 * lxC1(c, per, seed) - 1.5707963;
            float an = atan(f.y, f.x) - rot;
            float phi = abs(lxMod(an + k, 2.0 * k) - k);
            float rho = length(f) / size;
            vec2 P = rho * vec2(cos(phi), sin(phi));
            vec2 B = inner * vec2(cos(k), sin(k));
            vec2 E = B - vec2(1.0, 0.0);
            vec2 PA = P - vec2(1.0, 0.0);
            float sd = (E.x * PA.y - E.y * PA.x) / length(E) * size;
            float e = max(soft, aa) + 0.0001;
            return lxG(smoothstep(-e, e, sd));
        """),
        TextureGen(id: "concentric", name: "Concentric Rings", category: .pattern, scale: 40,
                   params: [.c("shape", "Shape", ["Circle", "Square", "Diamond", "Hexagon"], 0), .s("duty", "Ring Width", 0.05...0.95, 0.5),
                            .s("soft", "Softness", 0...0.5, 0.02), .s("phase", "Phase", 0...1, 0)],
                   nativeTile: { _ in false }, keywords: ["rings", "target", "radial"], body: """
            vec2 al = abs(q);
            float d = shape < 0.5 ? length(q) : (shape < 1.5 ? max(al.x, al.y) : (shape < 2.5 ? al.x + al.y : max(al.x * 0.8660254 + al.y * 0.5, al.y)));
            return lxG(lxBand(d - phase, duty, soft, aa));
        """),
        TextureGen(id: "guilloche", name: "Guilloché", category: .pattern, scale: 200,
                   params: [.i("petals", "Petals", 3...24, 9), .s("amp", "Wave Amplitude", 0...2, 0.7), .s("rings", "Rings", 1...20, 7),
                            .s("width", "Line Width", 0.02...0.5, 0.1), .i("layers", "Layers", 1...3, 3)],
                   nativeTile: { _ in false }, keywords: ["rosette", "banknote", "engraving", "spirograph"], body: """
            float r = length(q); float th = atan(q.y, q.x);
            float n = floor(petals + 0.5);
            float v = 0.0;
            for (float i = 0.0; i < 3.0; i += 1.0) {
                if (i < layers) {
                    float t = r * rings + amp * sin(n * th + i * 2.0943951) + i * 0.3333;
                    float d = abs(fract(t) - 0.5) * 2.0;
                    float e = aa * rings * 2.5 + 0.0001;
                    v = max(v, smoothstep(1.0 - width - e, 1.0 - width + e, d));
                }
            }
            return lxG(v);
        """),
    ]
}
