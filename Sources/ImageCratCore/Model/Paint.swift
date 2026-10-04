import Foundation

// MARK: - Gradients

package struct GradientStop: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var location: Double   // 0...1
    package var color: RGBA        // includes opacity
    package init(id: UUID = UUID(), location: Double, color: RGBA) {
        self.id = id; self.location = location; self.color = color
    }
}

package struct ColorGradient: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var name: String
    package var stops: [GradientStop]

    package var sortedStops: [GradientStop] { stops.sorted { $0.location < $1.location } }

    package func color(at t: Double) -> RGBA {
        let s = sortedStops
        guard let first = s.first, let last = s.last else { return .clear }
        if t <= first.location { return first.color }
        if t >= last.location { return last.color }
        for i in 0..<(s.count - 1) {
            let a = s[i], b = s[i + 1]
            if t >= a.location && t <= b.location {
                let span = max(1e-9, b.location - a.location)
                return a.color.mix(b.color, (t - a.location) / span)
            }
        }
        return last.color
    }

    package func reversed() -> ColorGradient {
        var g = self
        g.stops = stops.map { GradientStop(id: $0.id, location: 1 - $0.location, color: $0.color) }
        return g
    }

    package static func twoColor(_ a: RGBA, _ b: RGBA, name: String = "Custom") -> ColorGradient {
        ColorGradient(name: name, stops: [GradientStop(location: 0, color: a), GradientStop(location: 1, color: b)])
    }

    package static let presets: [ColorGradient] = [
        .twoColor(.black, .white, name: "Black, White"),
        .twoColor(.black, .clear, name: "Foreground to Transparent"),
        ColorGradient(name: "Spectrum", stops: [
            GradientStop(location: 0, color: RGBA(r: 1, g: 0, b: 0)),
            GradientStop(location: 0.17, color: RGBA(r: 1, g: 1, b: 0)),
            GradientStop(location: 0.33, color: RGBA(r: 0, g: 1, b: 0)),
            GradientStop(location: 0.5, color: RGBA(r: 0, g: 1, b: 1)),
            GradientStop(location: 0.67, color: RGBA(r: 0, g: 0, b: 1)),
            GradientStop(location: 0.83, color: RGBA(r: 1, g: 0, b: 1)),
            GradientStop(location: 1, color: RGBA(r: 1, g: 0, b: 0)),
        ]),
        ColorGradient(name: "Sunset", stops: [
            GradientStop(location: 0, color: RGBA(hex: "2B1055")!),
            GradientStop(location: 0.5, color: RGBA(hex: "D53369")!),
            GradientStop(location: 1, color: RGBA(hex: "FFC371")!),
        ]),
        ColorGradient(name: "Ocean", stops: [
            GradientStop(location: 0, color: RGBA(hex: "0F2027")!),
            GradientStop(location: 0.5, color: RGBA(hex: "2C5364")!),
            GradientStop(location: 1, color: RGBA(hex: "7FD8E8")!),
        ]),
        ColorGradient(name: "Copper", stops: [
            GradientStop(location: 0, color: RGBA(hex: "3B1F0E")!),
            GradientStop(location: 0.4, color: RGBA(hex: "B87333")!),
            GradientStop(location: 0.7, color: RGBA(hex: "F4C095")!),
            GradientStop(location: 1, color: RGBA(hex: "6B3A1E")!),
        ]),
        ColorGradient(name: "Chrome", stops: [
            GradientStop(location: 0, color: RGBA(hex: "2E3440")!),
            GradientStop(location: 0.3, color: RGBA(hex: "F5F7FA")!),
            GradientStop(location: 0.5, color: RGBA(hex: "6B7280")!),
            GradientStop(location: 0.7, color: RGBA(hex: "E5E7EB")!),
            GradientStop(location: 1, color: RGBA(hex: "374151")!),
        ]),
        ColorGradient(name: "Violet, Orange", stops: [
            GradientStop(location: 0, color: RGBA(hex: "7F00FF")!),
            GradientStop(location: 1, color: RGBA(hex: "FF8C00")!),
        ]),
        ColorGradient(name: "Neon", stops: [
            GradientStop(location: 0, color: RGBA(hex: "00F5A0")!),
            GradientStop(location: 1, color: RGBA(hex: "00D9F5")!),
        ]),
        ColorGradient(name: "Transparent Stripes", stops: [
            GradientStop(location: 0, color: .black),
            GradientStop(location: 0.2, color: .clear),
            GradientStop(location: 0.4, color: .black),
            GradientStop(location: 0.6, color: .clear),
            GradientStop(location: 0.8, color: .black),
            GradientStop(location: 1, color: .clear),
        ]),
    ]
    package init(id: UUID = UUID(), name: String, stops: [GradientStop]) {
        self.id = id; self.name = name; self.stops = stops
    }
}

/// Interpolation between gradient stops (Photoshop's gradient Method).
package enum GradientMethod: String, Codable, CaseIterable, Identifiable {
    /// Oklab: even perceived steps, no muddy midpoints.
    case perceptual
    /// Linear light: physically even blending, brighter midpoints.
    case linear
    /// Gamma-encoded sRGB (Lumen's and Photoshop's original blending).
    case classic
    package var id: String { rawValue }
    package var displayName: String { rawValue.capitalized }
}

extension ColorGradient {
    /// The gradient with extra stops so that the renderer's sRGB blending between neighbouring stops follows `method`.
    package func interpolated(_ method: GradientMethod) -> ColorGradient {
        guard method != .classic else { return self }
        let s = sortedStops
        guard s.count > 1 else { return self }
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func enc(_ v: Double) -> Double { let c = max(0, min(1, v)); return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        func toOklab(_ c: RGBA) -> (Double, Double, Double) {
            let r = lin(c.r), g = lin(c.g), b = lin(c.b)
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let q = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * q,
                    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * q,
                    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * q)
        }
        func fromOklab(_ L: Double, _ A: Double, _ B: Double) -> (Double, Double, Double) {
            let l = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
            let m = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
            let q = pow(L - 0.0894841775 * A - 1.2914855480 * B, 3)
            return (enc(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * q),
                    enc(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * q),
                    enc(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * q))
        }
        func mix(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
            let al = a.a + (b.a - a.a) * t
            switch method {
            case .classic: return a.mix(b, t)
            case .linear:
                return RGBA(r: enc(lin(a.r) + (lin(b.r) - lin(a.r)) * t), g: enc(lin(a.g) + (lin(b.g) - lin(a.g)) * t), b: enc(lin(a.b) + (lin(b.b) - lin(a.b)) * t), a: al)
            case .perceptual:
                let p = toOklab(a), q = toOklab(b)
                let c = fromOklab(p.0 + (q.0 - p.0) * t, p.1 + (q.1 - p.1) * t, p.2 + (q.2 - p.2) * t)
                return RGBA(r: c.0, g: c.1, b: c.2, a: al)
            }
        }
        var out: [GradientStop] = []
        let steps = 16
        for i in 0..<(s.count - 1) {
            let a = s[i], b = s[i + 1]
            out.append(GradientStop(location: a.location, color: a.color))
            guard b.location - a.location > 1e-6 else { continue }
            for k in 1..<steps {
                let t = Double(k) / Double(steps)
                out.append(GradientStop(location: a.location + (b.location - a.location) * t, color: mix(a.color, b.color, t)))
            }
        }
        out.append(GradientStop(location: s[s.count - 1].location, color: s[s.count - 1].color))
        var g = self
        g.stops = out
        return g
    }
}

package enum GradientType: String, Codable, CaseIterable, Identifiable {
    case linear, radial, angle, reflected, diamond
    package var id: String { rawValue }
    package var displayName: String { rawValue.capitalized }
    package var index: Int { GradientType.allCases.firstIndex(of: self)! }
}

/// A gradient placed in document space.
package struct GradientFill: Codable, Equatable {
    package var gradient: ColorGradient
    package var type: GradientType = .linear
    package var angle: Double = 90     // degrees, used when start/end are relative
    package var scale: Double = 1
    package var reverse = false
    package var dither = true
    /// Explicit start/end in doc coords (from gradient tool). If nil, derived from bounds + angle.
    package var start: CGPoint?
    package var end: CGPoint?
    /// Geometry that angle / scale cannot express (imported vector artwork); nil in ordinary gradients and older files.
    package var shape: GradientShape? = nil
    /// Gradient Fill layers: the gradient moved by this much, in percent of the reference bounds (dragged on the canvas
    /// while the Gradient Fill dialog is open; Photoshop's "Ofst"). nil = centred.
    package var offset: CGPoint? = nil
    /// Gradient Fill layers: span the layer's mask bounds instead of the canvas (Photoshop "Align with layer").
    package var alignWithLayer: Bool? = nil
    /// How colours blend between stops; nil = `.classic` (sRGB), as in older documents.
    package var method: GradientMethod? = nil

    package func endpoints(in bounds: CGRect) -> (CGPoint, CGPoint) {
        let (s, e) = baseEndpoints(in: bounds)
        guard let o = offset, o != .zero else { return (s, e) }
        let d = CGPoint(x: o.x / 100 * bounds.width, y: o.y / 100 * bounds.height)
        return (s + d, e + d)
    }

    private func baseEndpoints(in bounds: CGRect) -> (CGPoint, CGPoint) {
        if let s = start, let e = end { return (s, e) }
        let c = bounds.center
        let rad = angle * .pi / 180
        let dir = CGPoint(x: cos(rad), y: -sin(rad))
        // half-length: projection of bounds onto direction
        let half = (abs(dir.x) * bounds.width + abs(dir.y) * bounds.height) / 2 * scale
        if type == .linear { return (c - dir * half, c + dir * half) }
        return (c, c + dir * half)
    }
    package init(gradient: ColorGradient, type: GradientType = .linear, angle: Double = 90, scale: Double = 1, reverse: Bool = false, dither: Bool = true, start: CGPoint? = nil, end: CGPoint? = nil, shape: GradientShape? = nil, offset: CGPoint? = nil, alignWithLayer: Bool? = nil, method: GradientMethod? = nil) {
        self.gradient = gradient; self.type = type; self.angle = angle; self.scale = scale; self.reverse = reverse; self.dither = dither; self.start = start; self.end = end; self.shape = shape; self.offset = offset; self.alignWithLayer = alignWithLayer; self.method = method
    }
}

/// Exact placement of an imported gradient: elliptical / skewed / off-centre, with a focal point or a repeating ramp.
/// Honoured by the renderer only while the ordinary geometry settings still equal `key` — once the angle, scale,
/// style or end points are edited in the UI, those take over again (the colour stops stay editable throughout).
package struct GradientShape: Codable, Equatable {
    package enum Spread: String, Codable { case pad, reflect, `repeat` }
    /// Maps the unit gradient (linear: t runs 0…1 along x; radial: the unit circle around the origin) into the unit
    /// square of the painted bounds, so the gradient follows the shape when it is moved or resized.
    package var matrix: CGAffineTransform
    /// Radial only: focal point and focal radius in unit-gradient space.
    package var focal: CGPoint? = nil
    package var focalRadius: Double = 0
    package var spread: Spread = .pad
    /// `GradientFill.geometryKey` at the time the shape was stored.
    package var key: [Double] = []
    package init(matrix: CGAffineTransform, focal: CGPoint? = nil, focalRadius: Double = 0, spread: Spread = .pad, key: [Double] = []) {
        self.matrix = matrix; self.focal = focal; self.focalRadius = focalRadius; self.spread = spread; self.key = key
    }
}

extension GradientFill {
    /// The user-editable geometry settings, as numbers.
    package var geometryKey: [Double] {
        [Double(type.index), angle, scale, reverse ? 1 : 0, Double(start?.x ?? -1e9), Double(start?.y ?? -1e9), Double(end?.x ?? -1e9), Double(end?.y ?? -1e9)]
    }
    /// The imported geometry, while it is still in force.
    package var activeShape: GradientShape? {
        guard let s = shape, type == .linear || type == .radial, s.key == geometryKey, offset == nil || offset == .zero else { return nil }
        return s
    }
}

// MARK: - Patterns

package struct PatternDef: Codable, Identifiable {
    package var id: String
    package var name: String
    package var image: PixelBuffer

    package init(id: String, name: String, image: PixelBuffer) {
        self.id = id; self.name = name; self.image = image
    }
}

// MARK: - Paint style for shapes / fill layers

package enum PaintStyle: Codable, Equatable {
    case none
    case color(RGBA)
    case gradient(GradientFill)
    case pattern(id: String, scale: Double)

    package var isNone: Bool { if case .none = self { return true }; return false }
    package var solidColor: RGBA? { if case .color(let c) = self { return c }; return nil }
}
