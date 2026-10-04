import Foundation
import ImageCratCore

extension TextureCatalog {
    private static let loopOpen = "for (float gy = -1.0; gy <= 1.0; gy += 1.0) { for (float gx = -1.0; gx <= 1.0; gx += 1.0) { vec2 g = vec2(gx, gy);"
    private static let loopClose = "} }"

    // MARK: Natural

    static let natural: [TextureGen] = [
        TextureGen(id: "marble", name: "Marble", category: .natural, scale: 260,
                   params: [.i("veins", "Veins", 1...12, 3), .s("turb", "Turbulence", 0...4, 1.6), .i("octaves", "Detail", 1...8, 5),
                            .s("sharp", "Vein Sharpness", 0.1...3, 0.55), .s("fine", "Fine Veins", 0...1, 0.45)],
                   ramp: ramp("Marble", [(0, "2B2B33"), (0.35, "8D8D94"), (0.75, "DCDAD6"), (1, "F6F4F0")]), keywords: ["stone", "veins"], body: """
            float vn = floor(veins + 0.5);
            float tb = lxTurb(q, per, seed, octaves, 0.55);
            float t = q.x * vn + turb * tb * 2.0 + 0.6 * turb * lxFbm(q * 2.0 + 3.7, per * 2.0, seed + 17.0, 3.0, 0.5);
            float v = pow(abs(sin(3.14159265 * t)), sharp);
            float t2 = (q.x + q.y) * vn * 2.0 + turb * 3.0 * lxFbm(q * 3.0 + 9.1, per * 3.0, seed + 29.0, 4.0, 0.5);
            float s2 = pow(abs(sin(3.14159265 * t2)), sharp * 0.6);
            v = v * mix(1.0, s2, fine * 0.6);
            v = v * (0.9 + 0.2 * lxFbm(q * 4.0, per * 4.0, seed + 41.0, 3.0, 0.5));
            return lxG(v);
        """),
        TextureGen(id: "wood", name: "Wood Grain", category: .natural, scale: 220,
                   params: [.i("rings", "Rings", 1...24, 7), .s("wobble", "Ring Distortion", 0...2, 0.55), .s("fibre", "Fibres", 0...1, 0.6),
                            .c("cut", "Cut", ["Plank (long grain)", "End Grain (rings)"], 0)],
                   ramp: ramp("Wood", [(0, "4A2C17"), (0.4, "8A5A2B"), (0.75, "B98A4E"), (1, "D9B27C")]),
                   nativeTile: { ($0["cut"] ?? 0) < 0.5 }, keywords: ["timber", "plank", "oak", "grain"], body: """
            float rf = floor(rings + 0.5);
            float v = 0.0;
            if (cut < 0.5) {
                float wob = lxFbm(vec2(q.x * 2.0, q.y), vec2(per.x * 2.0, per.y), seed, 3.0, 0.5);
                float t = q.x * rf + wobble * 2.5 * wob;
                float saw = fract(t);
                float ring = smoothstep(0.0, 0.75, saw) * (1.0 - smoothstep(0.86, 1.0, saw));
                float fib = lxValue(vec2(q.x * 64.0, q.y * 2.0), vec2(per.x * 64.0, per.y * 2.0), seed + 5.0);
                float fib2 = lxValue(vec2(q.x * 160.0, q.y * 3.0), vec2(per.x * 160.0, per.y * 3.0), seed + 9.0);
                v = 0.32 + 0.48 * ring + fibre * 0.22 * (fib - 0.5) + fibre * 0.14 * (fib2 - 0.5) + 0.1 * wob;
            } else {
                vec2 w = q + wobble * 0.4 * vec2(lxFbm(q, per, seed, 3.0, 0.5), lxFbm(q + 4.3, per, seed + 2.0, 3.0, 0.5));
                float r = length(w * vec2(1.0, 1.15));
                float saw = fract(r * rf);
                float ring = smoothstep(0.0, 0.75, saw) * (1.0 - smoothstep(0.86, 1.0, saw));
                float ray = lxValue(vec2(atan(w.y, w.x) * 40.0, r * 5.0), vec2(0.0), seed + 5.0);
                v = 0.32 + 0.48 * ring + fibre * 0.2 * (ray - 0.5);
            }
            return lxG(v);
        """),
        TextureGen(id: "clouds", name: "Clouds", category: .natural, scale: 320,
                   params: [.s("coverage", "Coverage", 0...1, 0.5), .s("softness", "Softness", 0.02...1, 0.5), .i("octaves", "Detail", 1...8, 6),
                            .s("phase", "Evolution", 0...10, 0)],
                   ramp: ramp("Sky", [(0, "2F6FD0"), (0.55, "B7D3F4"), (1, "FFFFFF")]), keywords: ["sky", "fog", "smoke"], body: """
            float n = 0.0; float amp = 0.5; float norm = 0.0; float fr = 1.0;
            for (float i = 0.0; i < 8.0; i += 1.0) {
                if (i < octaves) {
                    n += amp * lxPerlin(q * fr + phase * vec2(0.13, 0.07) * (i + 1.0), per * fr, seed + i * 7.0);
                    norm += amp; amp *= 0.5; fr *= 2.0;
                }
            }
            float v = 0.5 + 0.75 * n / norm;
            return lxG(smoothstep(1.0 - coverage - softness * 0.5, 1.0 - coverage + softness * 0.5, v));
        """),
        TextureGen(id: "caustics", name: "Water Caustics", category: .natural, scale: 360,
                   params: [.i("iterations", "Complexity", 2...6, 5), .s("sharp", "Sharpness", 1...12, 6), .s("phase", "Time", 0...20, 0)],
                   ramp: ramp("Water", [(0, "00496B"), (0.35, "0F86A8"), (0.8, "9EE6F2"), (1, "FFFFFF")]), keywords: ["water", "pool", "ocean"], body: """
            float TAU = 6.28318530718;
            float tm = phase * 0.5 + 23.0 + lxMod(seed * 1.37, 97.0);
            vec2 p = vec2(lxMod(q.x * TAU, TAU), lxMod(q.y * TAU, TAU)) - 250.0;
            vec2 it = p; float c1 = 1.0; float inten = 0.005;
            for (float n = 0.0; n < 6.0; n += 1.0) {
                if (n < iterations) {
                    float t = tm * (1.0 - (3.5 / (n + 1.0)));
                    it = p + vec2(cos(t - it.x) + sin(t + it.y), sin(t - it.y) + cos(t + it.x));
                    c1 += 1.0 / length(vec2(p.x / (sin(it.x + t) / inten), p.y / (cos(it.y + t) / inten)));
                }
            }
            c1 /= iterations;
            c1 = 1.17 - pow(c1, 1.4);
            return lxG(pow(abs(c1), sharp));
        """),
        TextureGen(id: "plasma", name: "Plasma", category: .natural, scale: 300,
                   params: [.i("complexity", "Complexity", 1...6, 2), .s("strength", "Warp", 0...2, 0.8), .s("phase", "Time", 0...10, 0)],
                   ramp: ColorGradient.presets[2], keywords: ["psychedelic", "sine", "energy"], body: """
            float tau = 6.2831853;
            float k = floor(complexity + 0.5);
            vec2 w = q + strength * 0.15 * vec2(lxPerlin(q * 2.0, per * 2.0, seed), lxPerlin(q * 2.0 + 5.3, per * 2.0, seed + 4.0));
            float v = sin(tau * (w.x * k + phase * 0.31)) + sin(tau * (w.y * k - phase * 0.23))
                    + sin(tau * ((w.x + w.y) * k + phase * 0.17)) + sin(tau * ((w.x - w.y) * (k + 1.0) - phase * 0.11));
            return lxG(0.5 + v * 0.2);
        """),
        TextureGen(id: "fire", name: "Fire", category: .natural, scale: 200,
                   params: [.i("octaves", "Detail", 1...8, 5), .s("falloff", "Rise from Bottom", 0...1, 0.6), .s("intensity", "Intensity", 0.2...3, 1.2),
                            .s("phase", "Time", 0...20, 0)],
                   ramp: ramp("Fire", [(0, "000000"), (0.3, "7A0A00"), (0.55, "FF4A00"), (0.8, "FFC400"), (1, "FFFDE8")]),
                   nativeTile: { ($0["falloff"] ?? 0) < 0.01 }, keywords: ["flame", "burn"], body: """
            vec2 p = vec2(q.x * 2.0, q.y + phase);
            vec2 pp = vec2(per.x * 2.0, per.y);
            float n = lxTurb(p, pp, seed, octaves, 0.55);
            float n2 = lxFbm(p + vec2(3.1, phase * 0.7), pp, seed + 13.0, 3.0, 0.5);
            float base = n * 2.2 + 0.25 * n2;
            float h = mix(1.0, pow(clamp(nuv.y, 0.0, 1.0), 1.6) * 1.9, falloff);
            return lxG(base * h * intensity * 0.6);
        """),
        TextureGen(id: "lava", name: "Lava", category: .natural, scale: 150,
                   params: [.s("crack", "Crack Width", 0.02...0.6, 0.2), .s("heat", "Heat", 0...1, 0.5), .s("strength", "Warp", 0...1, 0.35),
                            .s("phase", "Time", 0...20, 0)],
                   ramp: ramp("Lava", [(0, "0B0605"), (0.25, "2A0C05"), (0.5, "B31B00"), (0.75, "FF7A00"), (1, "FFE98A")]), keywords: ["magma", "molten"], body: """
            vec2 w = q + strength * vec2(lxFbm(q + phase * 0.1, per, seed, 3.0, 0.5), lxFbm(q + 7.7 - phase * 0.1, per, seed + 3.0, 3.0, 0.5));
            vec3 wl = lxWorley(w, per, seed + 5.0, 0.0, 1.0);
            float glow = 1.0 - smoothstep(0.0, crack, wl.y - wl.x);
            float plate = 0.5 + 0.6 * lxFbm(w * 3.0, per * 3.0, seed + 11.0, 4.0, 0.55);
            float v = glow * glow * 0.95 + heat * 0.45 * plate * (1.0 - glow) + 0.05 * plate;
            return lxG(v);
        """),
        TextureGen(id: "rust", name: "Rust", category: .natural, scale: 240,
                   params: [.s("amount", "Amount", 0...1, 0.5), .s("grain", "Grain", 0...1, 0.6), .i("octaves", "Detail", 1...8, 5), .s("streak", "Streaks", 0...1, 0.3)],
                   ramp: ramp("Rust", [(0, "5C6268"), (0.2, "6E6A66"), (0.45, "5A2E17"), (0.7, "A24A1B"), (1, "D9853B")]), keywords: ["corrosion", "metal", "oxide"], body: """
            float n = 0.5 + 0.75 * lxFbm(q, per, seed, octaves, 0.55);
            float mask = smoothstep(1.0 - amount - 0.15, 1.0 - amount + 0.15, n);
            float fine = clamp(0.5 + 0.8 * lxFbm(q * 8.0, per * 8.0, seed + 9.0, 3.0, 0.6), 0.0, 1.0);
            float st = lxValue(vec2(q.x * 24.0, q.y), vec2(per.x * 24.0, per.y), seed + 21.0);
            float v = mask * (0.45 + 0.55 * mix(0.6, fine, grain)) + (1.0 - mask) * (0.1 + 0.1 * fine * grain);
            v += streak * 0.25 * (st - 0.5) * mask;
            return lxG(v);
        """),
        TextureGen(id: "granite", name: "Stone / Granite", category: .natural, scale: 120,
                   params: [.s("fleck", "Flecks", 0...1, 0.55), .s("grain", "Grain", 0...1, 0.6), .s("blotch", "Blotches", 0...1, 0.4)],
                   ramp: ramp("Granite", [(0, "2E2B2B"), (0.4, "8C8581"), (0.7, "C2B8B0"), (1, "EFE9E4")]), keywords: ["rock", "speckle"], body: """
            float base = 0.55 + 0.6 * blotch * lxFbm(q, per, seed, 4.0, 0.5);
            float g1 = lxValue(q * 24.0, per * 24.0, seed + 3.0);
            float g2 = lxValue(q * 60.0, per * 60.0, seed + 5.0);
            vec3 w1 = lxWorley(q * 10.0, per * 10.0, seed + 7.0, 0.0, 1.0);
            float dark = (1.0 - smoothstep(0.08, 0.28, w1.x)) * step(w1.z, fleck * 0.6);
            vec3 w2 = lxWorley(q * 16.0 + 3.3, per * 16.0, seed + 11.0, 2.0, 1.0);
            float light = (1.0 - smoothstep(0.05, 0.22, w2.x)) * step(w2.z, fleck * 0.45);
            float v = base + grain * 0.35 * (g1 - 0.5) + grain * 0.25 * (g2 - 0.5);
            v = mix(v, 0.08, dark * 0.85);
            v = mix(v, 0.98, light * 0.8);
            return lxG(v);
        """),
        TextureGen(id: "sand", name: "Sand", category: .natural, scale: 220,
                   params: [.i("ripples", "Ripples", 0...12, 5), .s("ripple", "Ripple Depth", 0...1, 0.6), .s("strength", "Warp", 0...2, 0.7), .s("grain", "Grain", 0...1, 0.6)],
                   ramp: ramp("Sand", [(0, "8A6B3F"), (0.5, "D2B27C"), (1, "F3E2B8")]), keywords: ["dune", "desert", "beach"], body: """
            float wv = lxFbm(q, per, seed, 3.0, 0.5);
            float t = q.y * floor(ripples + 0.5) + strength * 1.5 * wv + 0.3 * sin(6.2831853 * q.x);
            float rp = 0.5 + 0.5 * sin(6.2831853 * t);
            rp = rp * rp * (3.0 - 2.0 * rp);
            float g1 = lxValue(q * 90.0, per * 90.0, seed + 3.0);
            float g2 = lxC1(floor(q * 220.0), per * 220.0, seed + 5.0);
            float v = 0.55 + ripple * 0.32 * (rp - 0.5) + grain * 0.18 * (g1 - 0.5) + grain * 0.14 * (g2 - 0.5) + 0.12 * wv;
            return lxG(v);
        """),
        TextureGen(id: "terrain", name: "Terrain", category: .natural, scale: 400,
                   params: [.i("octaves", "Detail", 1...8, 7), .s("ridge", "Ridges", 0...1, 0.4), .s("sea", "Sea Level", 0...0.9, 0.42),
                            .s("shade", "Hillshade", 0...2, 1), .s("lightangle", "Light Angle", 0...360, 135)],
                   ramp: ramp("Terrain", [(0, "0B2A5B"), (0.3, "2F7FBF"), (0.35, "E6D7A3"), (0.42, "4F9A3C"), (0.62, "2F6B2F"), (0.78, "7A6A5A"), (0.9, "B8B2AA"), (1, "FFFFFF")]),
                   keywords: ["height", "map", "landscape", "mountain", "island"],
                   helpers: """
                   float lxTerrH(vec2 p, vec2 per, float seed, float oct, float ridge) {
                       float s = 0.0; float amp = 0.5; float norm = 0.0; float fr = 1.0;
                       for (float i = 0.0; i < 8.0; i += 1.0) {
                           if (i < oct) {
                               float n = lxPerlin(p * fr, per * fr, seed + i * 7.0);
                               float rg = 1.0 - abs(n); rg = rg * rg * 2.0 - 1.0;
                               s += amp * mix(n, rg, ridge); norm += amp; amp *= 0.5; fr *= 2.0;
                           }
                       }
                       return clamp(0.5 + 0.7 * s / norm, 0.0, 1.0);
                   }
                   """, body: """
            float h = lxTerrH(q, per, seed, octaves, ridge);
            float e = 0.004;
            float hx = lxTerrH(q + vec2(e, 0.0), per, seed, octaves, ridge) - h;
            float hy = lxTerrH(q + vec2(0.0, e), per, seed, octaves, ridge) - h;
            vec3 nrm = normalize(vec3(-hx / e * 0.35, -hy / e * 0.35, 1.0));
            float la = lightangle * 0.0174533;
            vec3 L = normalize(vec3(cos(la), -sin(la), 0.8));
            float lam = clamp(dot(nrm, L), 0.0, 1.0) / 0.6247;
            float land = step(sea, h);
            float t = land > 0.5 ? 0.35 + (h - sea) / max(1.0 - sea, 0.001) * 0.65 : h / max(sea, 0.001) * 0.35;
            float sh = mix(1.0, lam, clamp(shade, 0.0, 2.0) * 0.5 * land);
            return vec4(vec3(clamp(t, 0.0, 1.0)), clamp(sh, 0.0, 2.0));
        """),
        TextureGen(id: "frost", name: "Snow / Frost Crystals", category: .natural, scale: 110,
                   params: [.i("branches", "Branches", 4...12, 6), .s("barbs", "Side Branches", 0...1, 0.8), .s("fine", "Rime", 0...1, 0.5)],
                   ramp: ramp("Frost", [(0, "0A1E3C"), (0.4, "3E78B2"), (0.75, "BFE3F7"), (1, "FFFFFF")]), keywords: ["ice", "snowflake", "winter", "crystal"], body: """
            vec2 ci = floor(q); vec2 f = q - ci;
            float nb = floor(branches + 0.5);
            float v = 0.0;
            \(loopOpen)
                vec3 rnd = lxC3(ci + g, per, seed);
                vec2 d = f - (g + rnd.xy);
                float r = length(d);
                float an = atan(d.y, d.x) + rnd.z * 6.2831853;
                float delta = (fract(an * nb / 6.2831853 + 0.5) - 0.5) * 6.2831853 / nb;
                float along = r * cos(delta); float across = abs(r * sin(delta));
                float len = 0.5 + 0.4 * rnd.z;
                float taper = clamp(1.0 - along / len, 0.0, 1.0);
                float mw = 0.014 * taper + aa;
                float arm = (1.0 - smoothstep(mw, mw * 2.0 + 0.004, across)) * step(along, len);
                float fq = 10.0;
                float t = fract(along * fq);
                float bd = abs(across - t / fq * 1.732) * 0.5;
                float br = (1.0 - smoothstep(0.005 + aa, 0.012 + aa * 2.0, bd)) * step(across, taper * 0.24) * step(along, len);
                float glow = exp(-r * r * 14.0) * 0.45;
                v = max(v, max(arm, max(br * 0.85 * barbs, glow)));
            \(loopClose)
            float rid = 1.0 - abs(lxFbm(q * 4.0, per * 4.0, seed + 3.0, 4.0, 0.6));
            v += fine * 0.4 * pow(rid, 5.0);
            return lxG(v);
        """),
        TextureGen(id: "leather", name: "Leather", category: .natural, scale: 22,
                   params: [.s("bump", "Pebble Height", 0...1, 0.7), .s("crease", "Crease Width", 0.02...0.5, 0.16), .s("grain", "Grain", 0...1, 0.4)],
                   ramp: ramp("Leather", [(0, "1E0F08"), (0.5, "5A2F18"), (1, "8E5530")]), keywords: ["skin", "hide"], body: """
            vec2 w = q + 0.12 * vec2(lxPerlin(q * 3.0, per * 3.0, seed), lxPerlin(q * 3.0 + 4.1, per * 3.0, seed + 2.0));
            vec3 wl = lxWorley(w, per, seed + 5.0, 0.0, 0.9);
            float cr = smoothstep(0.0, crease, wl.y - wl.x);
            float dome = 1.0 - wl.x * 1.1;
            float fine = lxValue(q * 40.0, per * 40.0, seed + 7.0);
            float v = cr * mix(0.75, 0.5 + 0.5 * dome, bump) + grain * 0.12 * (fine - 0.5);
            return lxG(v);
        """),
        TextureGen(id: "paper", name: "Paper Fibre", category: .natural, scale: 90,
                   params: [.s("fibres", "Fibres", 0...1, 0.6), .s("grain", "Grain", 0...1, 0.5), .s("flen", "Fibre Length", 0.2...1, 0.7)],
                   ramp: ramp("Paper", [(0, "B9AE98"), (0.5, "E4DCCB"), (1, "FBF8F0")]), keywords: ["parchment", "fiber", "pulp"], body: """
            float v = 0.62 + grain * 0.22 * (lxValue(q * 24.0, per * 24.0, seed) - 0.5) + grain * 0.3 * lxFbm(q * 2.0, per * 2.0, seed + 2.0, 4.0, 0.55);
            for (float l = 0.0; l < 2.0; l += 1.0) {
                float k = 1.0 + l * 2.0;
                vec2 p = q * k; vec2 pp = per * k;
                vec2 ci = floor(p); vec2 f = p - ci;
                \(loopOpen)
                    vec3 rnd = lxC3(ci + g, pp, seed + 10.0 + l * 5.0);
                    vec2 rn2 = lxC2(ci + g, pp, seed + 20.0 + l * 5.0);
                    vec2 ctr = g + rnd.xy;
                    float an = rnd.z * 3.14159265;
                    vec2 dir = vec2(cos(an), sin(an)) * flen * 0.5;
                    float d = lxSeg(f, ctr - dir, ctr + dir);
                    float ln = 1.0 - smoothstep(0.0, 0.012 * k + aa * k, d);
                    v += fibres * ln * (rn2.x - 0.45) * 0.7 * step(rn2.y, 0.8);
                \(loopClose)
            }
            return lxG(v);
        """),
        TextureGen(id: "canvas", name: "Canvas", category: .natural, scale: 48,
                   params: [.s("threadw", "Thread Width", 0.4...1, 0.86), .s("irregular", "Irregularity", 0...1, 0.5), .s("depth", "Shading", 0...1, 0.8)],
                   ramp: ramp("Canvas", [(0, "7D7462"), (0.5, "CFC4AC"), (1, "F1EAD8")]), keywords: ["linen", "burlap", "cloth"], body: """
            vec2 t = q * 8.0 + irregular * 0.35 * vec2(lxPerlin(q * 2.0, per * 2.0, seed), lxPerlin(q * 2.0 + 3.3, per * 2.0, seed + 4.0));
            vec2 c = floor(t); vec2 f = t - c;
            float par = lxMod(c.x + c.y, 2.0);
            float hw = threadw * 0.5 * (0.9 + 0.2 * irregular * (lxC1(c, per * 8.0, seed + 8.0) - 0.5));
            float v = lxWeave(f, par, hw, depth, aa * 8.0);
            v = 0.3 + 0.7 * v + 0.1 * (lxValue(q * 64.0, per * 64.0, seed + 12.0) - 0.5);
            return lxG(v);
        """),
        TextureGen(id: "concrete", name: "Concrete", category: .natural, scale: 200,
                   params: [.s("blotch", "Blotches", 0...1, 0.5), .s("grain", "Grain", 0...1, 0.5), .s("pores", "Pores", 0...1, 0.4)],
                   ramp: ramp("Concrete", [(0, "4A4A48"), (0.6, "9C9A95"), (1, "CFCDC7")]), keywords: ["cement", "wall", "plaster"], body: """
            float b = lxFbm(q, per, seed, 5.0, 0.55);
            float g1 = lxValue(q * 40.0, per * 40.0, seed + 3.0);
            float g2 = lxC1(floor(q * 128.0), per * 128.0, seed + 5.0);
            vec3 w = lxWorley(q * 14.0, per * 14.0, seed + 7.0, 0.0, 1.0);
            float pore = (1.0 - smoothstep(0.03, 0.12 + 0.1 * w.z, w.x)) * step(w.z, pores * 0.5);
            float v = 0.58 + blotch * 0.7 * b + grain * 0.2 * (g1 - 0.5) + grain * 0.12 * (g2 - 0.5);
            v = mix(v, 0.15, pore * 0.8);
            return lxG(v);
        """),
        TextureGen(id: "fur", name: "Fur / Strands", category: .natural, scale: 110,
                   params: [.i("density", "Density", 8...64, 28), .s("curl", "Curl", 0...2, 0.6), .s("sheen", "Sheen", 0...1, 0.5)],
                   ramp: ramp("Fur", [(0, "1B0F08"), (0.5, "6B4423"), (1, "C9A06A")]), keywords: ["hair", "fibre", "grass"], body: """
            vec2 w = q + curl * 0.2 * vec2(lxPerlin(q, per, seed), lxPerlin(q + 5.7, per, seed + 2.0));
            float dn = floor(density + 0.5);
            float s1 = lxValue(vec2(w.x * dn, w.y), vec2(per.x * dn, per.y), seed + 3.0);
            float s2 = lxValue(vec2(w.x * dn * 2.0 + 3.1, w.y * 2.0), vec2(per.x * dn * 2.0, per.y * 2.0), seed + 5.0);
            float s3 = lxValue(vec2(w.x * dn * 4.0 + 1.7, w.y * 3.0), vec2(per.x * dn * 4.0, per.y * 3.0), seed + 7.0);
            float st = smoothstep(0.25, 0.8, s1 * 0.5 + s2 * 0.3 + s3 * 0.2);
            float sh = 0.75 + sheen * 0.5 * lxPerlin(w * vec2(1.0, 2.0), vec2(per.x, per.y * 2.0), seed + 9.0);
            return lxG(st * sh);
        """),
    ]

    // MARK: Tech

    static let tech: [TextureGen] = [
        TextureGen(id: "circuit", name: "Circuit Lines", category: .tech, scale: 36,
                   params: [.s("density", "Density", 0...1, 0.55), .s("width", "Trace Width", 0.04...0.4, 0.14), .s("pad", "Pad Size", 0.1...0.45, 0.26)],
                   ramp: ramp("PCB", [(0, "0B3D2A"), (0.35, "11573A"), (0.6, "3FA66B"), (1, "E8C75A")]), keywords: ["pcb", "electronics", "board", "traces"], body: """
            vec2 c = floor(q); vec2 f = q - c - 0.5;
            vec2 pp = per * 2.0;
            float eR = step(lxC1(c * 2.0 + vec2(1.0, 0.0), pp, seed), density);
            float eL = step(lxC1(c * 2.0 + vec2(-1.0, 0.0), pp, seed), density);
            float eD = step(lxC1(c * 2.0 + vec2(0.0, 1.0), pp, seed), density);
            float eU = step(lxC1(c * 2.0 + vec2(0.0, -1.0), pp, seed), density);
            float n = eR + eL + eD + eU;
            float d = 10.0;
            if (eR > 0.5) { d = min(d, lxSeg(f, vec2(0.0), vec2(0.5, 0.0))); }
            if (eL > 0.5) { d = min(d, lxSeg(f, vec2(0.0), vec2(-0.5, 0.0))); }
            if (eD > 0.5) { d = min(d, lxSeg(f, vec2(0.0), vec2(0.0, 0.5))); }
            if (eU > 0.5) { d = min(d, lxSeg(f, vec2(0.0), vec2(0.0, -0.5))); }
            float hw = width * 0.5;
            float v = (1.0 - smoothstep(hw - aa, hw + aa + 0.0001, d)) * 0.6;
            float r = length(f);
            float isEnd = step(abs(n - 1.0), 0.1);
            float isVia = step(2.5, n) * step(lxC1(c, per, seed + 9.0), 0.5);
            float padOn = max(isEnd, isVia);
            float outer = 1.0 - smoothstep(pad - aa, pad + aa + 0.0001, r);
            float hole = 1.0 - smoothstep(pad * 0.4 - aa, pad * 0.4 + aa + 0.0001, r);
            v = mix(v, 1.0, padOn * outer);
            v = mix(v, 0.0, padOn * hole);
            float chip = step(n, 0.5) * step(lxC1(c, per, seed + 17.0), 0.3);
            vec2 af = abs(f);
            float body = 1.0 - smoothstep(0.3 - aa, 0.3 + aa + 0.0001, max(af.x, af.y));
            v = max(v, chip * body * 0.35);
            return lxG(v);
        """),
        TextureGen(id: "scanlines", name: "Scanlines", category: .tech, scale: 4,
                   params: [.s("duty", "Line Width", 0.1...0.9, 0.5), .s("soft", "Softness", 0...0.5, 0.25),
                            .c("style", "Style", ["Lines", "RGB Triads", "Aperture Grille"], 0), .s("flicker", "Row Flicker", 0...1, 0), .s("phase", "Time", 0...100, 0)],
                   direct: true, period: { _ in (1, 2) }, keywords: ["crt", "tv", "monitor", "retro"], body: """
            float ln = lxBand(q.y, duty, soft, aa);
            float fl = 1.0 - flicker * lxC1(vec2(floor(q.y), floor(phase * 24.0)), vec2(per.y, 0.0), seed);
            vec3 col = vec3(ln * fl);
            if (style > 0.5) {
                float tx = style < 1.5 ? q.x + 0.5 * lxMod(floor(q.y), 2.0) : q.x;
                float ph = fract(tx) * 3.0;
                vec3 tri = clamp(vec3(1.0 - abs(ph - 0.5) * 1.6, 1.0 - abs(ph - 1.5) * 1.6, 1.0 - abs(ph - 2.5) * 1.6), 0.0, 1.0);
                col = (style < 1.5 ? ln * fl : fl) * tri * 1.25;
            }
            return vec4(col, 1.0);
        """),
        TextureGen(id: "glitch", name: "Glitch Blocks", category: .tech, scale: 320,
                   params: [.i("rows", "Rows", 2...64, 14), .s("density", "Density", 0...1, 0.45), .c("style", "Style", ["Gray Blocks", "RGB Blocks", "Shift Map"], 0),
                            .s("phase", "Time", 0...100, 0)],
                   direct: true, keywords: ["datamosh", "digital", "corrupt", "vhs"], body: """
            float tick = floor(phase);
            float rws = floor(rows + 0.5);
            float ry = floor(q.y * rws);
            vec2 rp = vec2(per.y * rws, 0.0);
            float rr = lxC1(vec2(ry, tick), rp, seed);
            float segs = pow(2.0, floor(rr * 4.0));
            float off = lxC1(vec2(ry, tick + 3.0), rp, seed + 1.0);
            float bx = floor(q.x * segs + floor(off * segs));
            vec3 rnd = lxC3(vec2(bx, ry), vec2(per.x * segs, per.y * rws), seed + tick * 3.0 + segs);
            float on = step(rnd.z, density);
            vec3 col = vec3(rnd.x);
            if (style > 1.5) { col = vec3(rnd.x, 0.5, 0.5); }
            else if (style > 0.5) { col = vec3(step(0.5, rnd.x), step(0.5, rnd.y), step(0.5, fract(rnd.x * 7.0 + rnd.y * 3.0))); }
            vec3 offc = style > 1.5 ? vec3(0.5) : vec3(0.0);
            return vec4(mix(offc, col, on), 1.0);
        """),
        TextureGen(id: "barcode", name: "Barcode / QR Noise", category: .tech, scale: 8,
                   params: [.c("style", "Style", ["Barcode", "QR-like"], 0), .s("density", "Density", 0...1, 0.5)],
                   period: { ($0["style"] ?? 0) > 0.5 ? (29, 29) : (1, 1) }, keywords: ["qr", "code", "data", "matrix"], body: """
            if (style < 0.5) {
                float on = step(lxC1(vec2(floor(q.x), 0.0), vec2(per.x, 0.0), seed), density);
                return lxG(1.0 - on);
            }
            vec2 m = floor(q);
            vec2 b = floor(m / 29.0);
            vec2 l = m - b * 29.0 - 2.0;
            float v = step(lxC1(m, per, seed), density);
            float fv = 2.0;
            vec2 f1 = l; vec2 f2 = vec2(24.0 - l.x, l.y); vec2 f3 = vec2(l.x, 24.0 - l.y);
            if (f1.x < 8.0 && f1.y < 8.0) { float rg = max(abs(f1.x - 3.0), abs(f1.y - 3.0)); fv = (rg < 1.5 || (rg > 2.5 && rg < 3.5)) ? 1.0 : 0.0; }
            if (f2.x < 8.0 && f2.y < 8.0) { float rg = max(abs(f2.x - 3.0), abs(f2.y - 3.0)); fv = (rg < 1.5 || (rg > 2.5 && rg < 3.5)) ? 1.0 : 0.0; }
            if (f3.x < 8.0 && f3.y < 8.0) { float rg = max(abs(f3.x - 3.0), abs(f3.y - 3.0)); fv = (rg < 1.5 || (rg > 2.5 && rg < 3.5)) ? 1.0 : 0.0; }
            if (fv < 1.5) { v = fv; }
            if (l.x < 0.0 || l.y < 0.0 || l.x > 24.0 || l.y > 24.0) { v = 0.0; }
            return lxG(1.0 - v);
        """),
        TextureGen(id: "banding", name: "Gradient Noise Banding", category: .tech, scale: 512,
                   params: [.i("bands", "Bands", 2...64, 8), .s("rough", "Noise", 0...1, 0.35), .i("nscale", "Noise Scale", 1...16, 3), .s("dither", "Dither", 0...1, 0)],
                   keywords: ["posterize", "steps", "contour", "topographic"], body: """
            float ns = floor(nscale + 0.5);
            float b = floor(bands + 0.5);
            float t = fract(q.x);
            float n = rough * lxPerlin(q * ns, per * ns, seed);
            float dth = dither * (lxC1(floor(q * 512.0), per * 512.0, seed + 3.0) - 0.5);
            float v = floor(clamp(t + n * 2.0 / b + dth / b, 0.0, 0.9999) * b) / max(b - 1.0, 1.0);
            return lxG(v);
        """),
        TextureGen(id: "filmgrain", name: "Film Grain", category: .tech, scale: 6,
                   params: [.c("stock", "Stock", ["Fine (ISO 100)", "Medium (ISO 400)", "Coarse (ISO 1600)", "B&W T-Grain", "Color Negative"], 1),
                            .s("amount", "Amount", 0...1, 0.5), .s("chroma", "Color", 0...1, 0.3), .s("clump", "Clumping", 0...1, 0.3)],
                   direct: true, keywords: ["noise", "analog", "iso", "photo"],
                   helpers: """
                   float lxGrain(vec2 p, vec2 pp, float seed) {
                       float g1 = lxValue(p, pp, seed);
                       float g2 = lxValue(p * 2.0 + 5.1, pp * 2.0, seed + 11.0);
                       float g3 = lxC1(floor(p * 2.0), pp * 2.0, seed + 23.0);
                       return (g1 + g2 + g3) / 3.0 - 0.5;
                   }
                   """, body: """
            float k = stock < 0.5 ? 4.0 : (stock < 1.5 ? 2.0 : (stock < 2.5 ? 1.0 : (stock < 3.5 ? 3.0 : 2.0)));
            vec2 p = q * k; vec2 pp = per * k;
            float gr = lxGrain(p, pp, seed);
            float gg = lxGrain(p + 31.7, pp, seed + 40.0);
            float gb = lxGrain(p + 67.1, pp, seed + 80.0);
            float tg = (stock > 2.5 && stock < 3.5) ? 1.0 : 0.0;
            float cm = stock > 3.5 ? max(chroma, 0.6) : chroma * (1.0 - tg);
            vec3 g = mix(vec3(gr), vec3(gr, gg, gb), cm);
            g *= 1.0 + clump * 1.5 * lxPerlin(q, per, seed + 7.0);
            if (tg > 0.5) { g = sign(g) * pow(abs(g) * 2.0, vec3(0.7)) * 0.5; }
            return vec4(clamp(0.5 + g * amount * 1.3, 0.0, 1.0), 1.0);
        """),
        TextureGen(id: "dust", name: "Dust & Scratches Overlay", category: .tech, scale: 320,
                   params: [.s("dust", "Dust", 0...1, 0.5), .s("scratches", "Scratches", 0...1, 0.45), .s("hairs", "Hairs", 0...1, 0.35), .s("size", "Size", 0.2...3, 1)],
                   keywords: ["film", "dirt", "old", "vintage", "damage"], body: """
            float v = 0.0;
            for (float l = 0.0; l < 2.0; l += 1.0) {
                float k = 3.0 + l * 5.0;
                vec2 p = q * k; vec2 pp = per * k;
                vec2 ci = floor(p); vec2 f = p - ci;
                \(loopOpen)
                    vec3 rnd = lxC3(ci + g, pp, seed + l * 9.0);
                    float on = step(rnd.z, dust * 0.35);
                    float rad = (0.03 + 0.10 * fract(rnd.z * 37.0)) * size;
                    float d = length(g + rnd.xy - f);
                    v = max(v, on * (1.0 - smoothstep(rad * 0.4, rad + aa * k, d)) * (0.5 + 0.5 * fract(rnd.z * 91.0)));
                \(loopClose)
            }
            vec2 hc = floor(q); vec2 hf = q - hc;
            \(loopOpen)
                vec3 rnd = lxC3(hc + g, per, seed + 31.0);
                float on = step(rnd.z, hairs * 0.4);
                float an = rnd.z * 40.0;
                vec2 dir = vec2(cos(an), sin(an));
                vec2 rel = hf - (g + rnd.xy);
                float along = dot(rel, dir); float across = dot(rel, vec2(-dir.y, dir.x));
                across -= 0.6 * (fract(rnd.z * 53.0) - 0.5) * (along * along - 0.16);
                float inside = 1.0 - smoothstep(0.38, 0.42, abs(along));
                float w = 0.006 * size + aa;
                v = max(v, on * inside * (1.0 - smoothstep(w * 0.5, w * 1.5, abs(across))) * 0.8);
            \(loopClose)
            float cols = 6.0;
            float cx = floor(q.x * cols);
            for (float dx = -1.0; dx <= 1.0; dx += 1.0) {
                float ci2 = cx + dx;
                vec3 rnd = lxC3(vec2(ci2, 0.0), vec2(per.x * cols, 0.0), seed + 57.0);
                float on = step(rnd.z, scratches * 0.5);
                float xline = (ci2 + rnd.x) / cols + 0.01 * sin(q.y * 6.2831853 + rnd.y * 6.28);
                float inter = smoothstep(0.35, 0.6, lxValue(vec2(q.y * 2.0, ci2), vec2(per.y * 2.0, per.x * cols), seed + 63.0));
                float w = 0.002 * size + aa * 0.7;
                v = max(v, on * inter * (1.0 - smoothstep(w * 0.5, w * 1.5, abs(q.x - xline))) * (0.5 + 0.5 * rnd.y));
            }
            return lxG(v);
        """),
        TextureGen(id: "lightleak", name: "Light Leaks", category: .tech, scale: 512,
                   params: [.i("count", "Leaks", 1...6, 3), .s("spread", "Spread", 0.2...1.5, 0.7), .s("intensity", "Intensity", 0...2, 1), .s("streak", "Streak", 0...1, 0.3)],
                   colors: [("c0", "Red", RGBA(hex: "FF3B1F")!), ("c1", "Orange", RGBA(hex: "FF9A1F")!), ("c2", "Yellow", RGBA(hex: "FFE27A")!)],
                   direct: true, nativeTile: { _ in false }, keywords: ["film", "flare", "burn", "lomo", "analog"], body: """
            vec3 col = vec3(0.0);
            float cn = floor(count + 0.5);
            for (float i = 0.0; i < 6.0; i += 1.0) {
                if (i < cn) {
                    vec3 r1 = lxH3(vec2(i * 7.3 + 1.0, 3.7) + lxSeedOff(seed));
                    vec3 r2 = lxH3(vec2(i * 3.1 + 5.0, 9.2) + lxSeedOff(seed + 4.0));
                    float side = floor(r1.x * 4.0);
                    vec2 ctr = side < 0.5 ? vec2(-0.05, r1.y) : (side < 1.5 ? vec2(1.05, r1.y) : (side < 2.5 ? vec2(r1.y, -0.05) : vec2(r1.y, 1.05)));
                    vec2 d = (nuv - ctr) / (spread * (0.35 + 0.65 * r2.x) * vec2(0.6 + r2.y, 0.6 + r2.z));
                    float fo = exp(-dot(d, d) * 1.2);
                    vec3 c = r1.z < 0.34 ? k0.rgb : (r1.z < 0.67 ? k1.rgb : k2.rgb);
                    c = mix(c, k1.rgb, 0.35 * r2.z);
                    col += c * fo * (0.6 + 0.6 * r2.y);
                }
            }
            vec3 rs = lxH3(vec2(91.0, 17.0) + lxSeedOff(seed + 8.0));
            float bd = (nuv.x * (0.6 + rs.x) + nuv.y * (rs.y - 0.5) - rs.z) * 5.0;
            col += streak * exp(-bd * bd) * mix(k1.rgb, k2.rgb, rs.x) * 0.6;
            col = 1.0 - exp(-col * intensity * 1.3);
            return vec4(col, 1.0);
        """),
        TextureGen(id: "bokeh", name: "Bokeh Field", category: .tech, scale: 140,
                   params: [.s("density", "Density", 0...1, 0.5), .s("radius", "Radius", 0.1...0.6, 0.36), .s("ring", "Edge Ring", 0...1, 0.45),
                            .s("soft", "Softness", 0.01...0.5, 0.08), .c("blades", "Aperture", ["Circle", "Hexagon", "Octagon"], 0), .i("layers", "Layers", 1...3, 3)],
                   colors: [("c0", "Warm", RGBA(hex: "FFD9A0")!), ("c1", "White", RGBA(hex: "FFFFFF")!), ("c2", "Cool", RGBA(hex: "9FD0FF")!)],
                   direct: true, keywords: ["lights", "defocus", "blur", "night"], body: """
            vec3 col = vec3(0.0);
            for (float l = 0.0; l < 3.0; l += 1.0) {
                if (l < layers) {
                    float k = 1.0 + l;
                    vec2 p = q * k + l * 0.37; vec2 pp = per * k;
                    vec2 ci = floor(p); vec2 f = p - ci;
                    \(loopOpen)
                        vec3 rnd = lxC3(ci + g, pp, seed + l * 11.0);
                        vec3 rn2 = lxC3(ci + g, pp, seed + 50.0 + l * 11.0);
                        float on = step(rn2.z, density);
                        vec2 rel = f - (g + rnd.xy);
                        float rad = radius * (0.5 + 0.5 * rnd.z);
                        float dd = length(rel);
                        if (blades > 0.5) {
                            float nb = blades < 1.5 ? 6.0 : 8.0;
                            float sec = 6.2831853 / nb;
                            float a2 = lxMod(atan(rel.y, rel.x) + rn2.x, sec) - sec * 0.5;
                            dd = dd * cos(a2) / cos(sec * 0.5);
                        }
                        float disc = 1.0 - smoothstep(rad * (1.0 - soft), rad + aa * k, dd);
                        float rg = smoothstep(rad * (0.75 - soft), rad * 0.95, dd) * ring;
                        vec3 tint = rn2.x < 0.4 ? k0.rgb : (rn2.x < 0.75 ? k1.rgb : k2.rgb);
                        col += on * disc * (0.35 + rg * 0.5) * tint * (0.3 + 0.7 * rn2.y) / (0.6 + 0.4 * k);
                    \(loopClose)
                }
            }
            col = 1.0 - exp(-col * 1.6);
            return vec4(col, 1.0);
        """),
    ]
}
