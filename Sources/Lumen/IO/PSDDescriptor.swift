import Foundation
import ImageCratCore

// MARK: - Self test

/// `PSDLayerStyleSelfTest.run()` → list of failures (empty = pass).
enum PSDLayerStyleSelfTest {
    static func sampleEffects() -> [(String, LayerEffects)] {
        var out: [(String, LayerEffects)] = []
        var all = LayerEffects()
        all.dropShadow.enabled = true; all.innerShadow.enabled = true; all.outerGlow.enabled = true; all.innerGlow.enabled = true
        all.bevel.enabled = true; all.satin.enabled = true; all.colorOverlay.enabled = true; all.gradientOverlay.enabled = true
        all.patternOverlay.enabled = true; all.stroke.enabled = true
        out.append(("all-defaults", all))

        var c = LayerEffects()
        c.dropShadow = ShadowEffect(enabled: true, blendMode: .linearBurn, color: RGBA(r: 0.2, g: 0.4, b: 0.6), opacity: 0.33, angle: -45, distance: 17, spread: 12, size: 23)
        c.innerShadow = ShadowEffect(enabled: true, blendMode: .colorDodge, color: RGBA(r: 1, g: 0.5, b: 0), opacity: 0.9, angle: 90, distance: 3, spread: 50, size: 7)
        c.outerGlow = GlowEffect(enabled: true, blendMode: .linearDodge, color: RGBA(r: 0, g: 1, b: 0.5), opacity: 0.4, spread: 20, size: 30, source: .edge)
        c.innerGlow = GlowEffect(enabled: true, blendMode: .softLight, color: RGBA(r: 0.1, g: 0.2, b: 0.3), opacity: 0.6, spread: 5, size: 9, source: .center)
        c.bevel = BevelEffect(enabled: true, style: .pillowEmboss, technique: .chiselSoft, depth: 250, directionUp: false, size: 14, soften: 3,
                              angle: 45, altitude: 60, highlightMode: .overlay, highlightColor: RGBA(r: 1, g: 1, b: 0.8), highlightOpacity: 0.5,
                              shadowMode: .hardLight, shadowColor: RGBA(r: 0.3, g: 0, b: 0.3), shadowOpacity: 0.25)
        c.satin = SatinEffect(enabled: true, blendMode: .exclusion, color: RGBA(r: 0.5, g: 0.5, b: 1), opacity: 0.7, angle: 33, distance: 21, size: 8, invert: false)
        c.colorOverlay = ColorOverlayEffect(enabled: true, blendMode: .hue, color: RGBA(r: 0.8, g: 0.1, b: 0.3), opacity: 0.45)
        var gf = GradientFill(gradient: ColorGradient.presets[3], type: .radial, angle: 30, scale: 1.5, reverse: true, dither: false)
        c.gradientOverlay = GradientOverlayEffect(enabled: true, blendMode: .vividLight, opacity: 0.8, fill: gf)
        c.patternOverlay = PatternOverlayEffect(enabled: true, blendMode: .multiply, opacity: 0.5, patternID: "dots", scale: 2)
        c.stroke = StrokeEffect(enabled: true, size: 5, position: .center, blendMode: .subtract, opacity: 0.7, paint: .color(RGBA(r: 0.25, g: 0.5, b: 0.75)))
        c.enabled = false
        out.append(("custom-all-masterOff", c))

        var m = LayerEffects()
        m.dropShadow.enabled = true; m.dropShadow.distance = 8
        var d2 = m.dropShadow; d2.distance = 25; d2.size = 20; d2.color = RGBA(r: 0.55, g: 0.27, b: 0.68); d2.opacity = 0.6
        m.extraDropShadows = [d2]
        m.innerShadow.enabled = true
        var i2 = m.innerShadow; i2.blendMode = .screen; i2.color = .white; m.extraInnerShadows = [i2, i2]
        m.colorOverlay.enabled = true; m.colorOverlay.color = RGBA(r: 0.95, g: 0.77, b: 0.06)
        var c2 = m.colorOverlay; c2.color = RGBA(r: 0.9, g: 0.3, b: 0.23); c2.blendMode = .multiply; c2.opacity = 0.5; m.extraColorOverlays = [c2]
        m.gradientOverlay.enabled = true
        var g2 = m.gradientOverlay; g2.fill = GradientFill(gradient: ColorGradient.presets[9], type: .diamond, angle: -120); m.extraGradientOverlays = [g2]
        m.stroke.enabled = true; m.stroke.size = 4; m.stroke.paint = .color(.white)
        gf = GradientFill(gradient: ColorGradient.presets[2], type: .angle, angle: 12, scale: 0.5)
        m.extraStrokes = [StrokeEffect(enabled: true, size: 10, position: .inside, blendMode: .normal, opacity: 1, paint: .gradient(gf)),
                          StrokeEffect(enabled: true, size: 2, position: .outside, blendMode: .darken, opacity: 0.5, paint: .pattern(id: "bricks", scale: 0.75))]
        out.append(("multi", m))

        var t = LayerEffects()
        t.gradientOverlay.enabled = true
        t.gradientOverlay.fill = GradientFill(gradient: ColorGradient.presets[1], type: .reflected, angle: 180, scale: 0.8)
        t.stroke.enabled = true; t.stroke.paint = .pattern(id: "hex", scale: 1.25); t.stroke.position = .inside
        out.append(("transparent-gradient+pattern-stroke", t))
        return out
    }

    /// Canonical form: disabled effects dropped/reset, gradient stops sorted, ids stripped.
    static func canonical(_ fx: LayerEffects) -> Any {
        let d = LayerEffects()
        var n = LayerEffects()
        n.enabled = fx.enabled
        func pick<T>(_ list: [T], _ enabled: (T) -> Bool, _ def: T) -> (T, [T]) {
            let on = list.filter(enabled)
            return (on.first ?? def, Array(on.dropFirst()))
        }
        (n.dropShadow, n.extraDropShadows) = pick(fx.dropShadows, \.enabled, d.dropShadow)
        (n.innerShadow, n.extraInnerShadows) = pick(fx.innerShadows, \.enabled, d.innerShadow)
        (n.colorOverlay, n.extraColorOverlays) = pick(fx.colorOverlays, \.enabled, d.colorOverlay)
        (n.gradientOverlay, n.extraGradientOverlays) = pick(fx.gradientOverlays, \.enabled, d.gradientOverlay)
        (n.stroke, n.extraStrokes) = pick(fx.strokes, { $0.enabled && !$0.paint.isNone }, d.stroke)
        n.outerGlow = fx.outerGlow.enabled ? fx.outerGlow : d.outerGlow
        n.innerGlow = fx.innerGlow.enabled ? fx.innerGlow : d.innerGlow
        n.bevel = fx.bevel.enabled ? fx.bevel : d.bevel
        n.satin = fx.satin.enabled ? fx.satin : d.satin
        n.patternOverlay = fx.patternOverlay.enabled ? fx.patternOverlay : d.patternOverlay
        func fixFill(_ f: inout GradientFill) { f.start = nil; f.end = nil; f.gradient.stops = f.gradient.sortedStops }
        fixFill(&n.gradientOverlay.fill)
        for i in n.extraGradientOverlays.indices { fixFill(&n.extraGradientOverlays[i].fill) }
        func fixStroke(_ s: inout StrokeEffect) { if case .gradient(var f) = s.paint { fixFill(&f); s.paint = .gradient(f) } }
        fixStroke(&n.stroke)
        for i in n.extraStrokes.indices { fixStroke(&n.extraStrokes[i]) }
        let json = (try? JSONEncoder().encode(n)) ?? Data()
        return strip((try? JSONSerialization.jsonObject(with: json)) ?? [:])
    }

    private static func strip(_ v: Any) -> Any {
        if let d = v as? [String: Any] { return d.filter { $0.key != "id" }.mapValues(strip) }
        if let a = v as? [Any] { return a.map(strip) }
        return v
    }

    /// Returns human-readable differences (numeric tolerance `tol`).
    static func diff(_ a: Any, _ b: Any, path: String = "", tol: Double = 1e-3) -> [String] {
        if let x = a as? [String: Any], let y = b as? [String: Any] {
            return Set(x.keys).union(y.keys).sorted().flatMap { k -> [String] in
                guard let xv = x[k], let yv = y[k] else { return ["\(path).\(k): missing"] }
                return diff(xv, yv, path: path + "." + k, tol: tol)
            }
        }
        if let x = a as? [Any], let y = b as? [Any] {
            guard x.count == y.count else { return ["\(path): count \(x.count) vs \(y.count)"] }
            return zip(x, y).enumerated().flatMap { diff($0.element.0, $0.element.1, path: "\(path)[\($0.offset)]", tol: tol) }
        }
        if let x = a as? NSNumber, let y = b as? NSNumber, !(a is String) {
            return abs(x.doubleValue - y.doubleValue) <= tol ? [] : ["\(path): \(x) vs \(y)"]
        }
        if let x = a as? String, let y = b as? String { return x == y ? [] : ["\(path): \(x) vs \(y)"] }
        return "\(a)" == "\(b)" ? [] : ["\(path): \(a) vs \(b)"]
    }

    static func run() -> [String] {
        var failures: [String] = []
        for (name, fx) in sampleEffects() {
            let payload = PSDLayerStyle.encode(fx)
            // Generic descriptor round trip must be byte-identical.
            do {
                let root = try PSDLayerStyle.rootDescriptor(payload)
                var w = PSDDescriptorWriter(); w.u32(0); w.u32(16); w.descriptor(root)
                if w.data != payload { failures.append("\(name): descriptor re-serialization differs") }
            } catch { failures.append("\(name): descriptor parse failed: \(error)") }

            guard let back = PSDLayerStyle.decode(payload) else { failures.append("\(name): decode returned nil"); continue }
            failures += diff(canonical(fx), canonical(back)).map { "\(name): \($0)" }

            // Robustness: every truncation and random corruption must not crash.
            for n in stride(from: 0, to: payload.count, by: max(1, payload.count / 400)) { _ = PSDLayerStyle.decode(payload.prefix(n)) }
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<2000 {
                var bad = [UInt8](payload)
                for _ in 0..<Int.random(in: 1...6, using: &rng) {
                    bad[Int.random(in: 0..<bad.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                }
                _ = PSDLayerStyle.decode(Data(bad))
            }
        }
        // Hostile inputs.
        var w = PSDDescriptorWriter(); w.u32(0); w.u32(16); w.unicode(""); w.id("null"); w.u32(0xFFFF_FFFF)
        if PSDLayerStyle.decode(w.data) != nil { failures.append("huge count accepted") }
        var deep = PSDDescriptorWriter(); deep.u32(0); deep.u32(16)
        for _ in 0..<200 { deep.unicode(""); deep.id("null"); deep.u32(1); deep.id("Objc"); deep.fourCC("Objc") }
        if PSDLayerStyle.decode(deep.data) != nil { failures.append("deep nesting accepted") }
        if PSDLayerStyle.decode(Data()) != nil { failures.append("empty accepted") }
        return failures
    }
}
