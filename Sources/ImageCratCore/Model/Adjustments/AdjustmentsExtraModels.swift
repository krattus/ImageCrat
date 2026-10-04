import Foundation

// MARK: - Models

/// One Hue/Saturation color range (Photoshop's Reds … Magentas).
package struct HueRange: Codable, Equatable {
    package var hue: Double = 0            // -180...180
    package var saturation: Double = 0     // -100...100
    package var lightness: Double = 0      // -100...100
    /// Degrees: falloff start, range start, range end, falloff end (may wrap past 360).
    package var range: [Double] = [315, 345, 15, 45]

    package static let names = ["Reds", "Yellows", "Greens", "Cyans", "Blues", "Magentas"]
    package static let defaultRanges: [[Double]] = [[315, 345, 15, 45], [15, 45, 75, 105], [75, 105, 135, 165],
                                            [135, 165, 195, 225], [195, 225, 255, 285], [255, 285, 315, 345]]
    package static var defaults: [HueRange] { defaultRanges.map { HueRange(range: $0) } }

    package var isIdentity: Bool { hue == 0 && saturation == 0 && lightness == 0 }

    package static func wrap(_ d: Double) -> Double { let m = d.truncatingRemainder(dividingBy: 360); return m < 0 ? m + 360 : m }

    /// (falloff start in 0..<360, range start, range end, falloff end) as offsets from falloff start, monotone in 0...360.
    package var normalized: (Double, Double, Double, Double) {
        let r = range.count == 4 ? range : HueRange.defaultRanges[0]
        let fs = HueRange.wrap(r[0])
        let b = HueRange.wrap(r[1] - r[0])
        let c = min(360, b + HueRange.wrap(r[2] - r[1]))
        let e = min(360, c + HueRange.wrap(r[3] - r[2]))
        return (fs, b, c, e)
    }

    /// Range membership 0...1 for a hue in degrees (same math as the kernel).
    package func weight(_ hueDeg: Double) -> Double {
        let (fs, b, c, e) = normalized
        let x = HueRange.wrap(hueDeg - fs)
        if x < b { return x / max(b, 0.001) }
        if x <= c { return 1 }
        if x < e { return (e - x) / max(e - c, 0.001) }
        return 0
    }

    /// Center of the solid range in degrees.
    package var center: Double { let n = normalized; return HueRange.wrap(n.0 + (n.1 + n.2) / 2) }
    package init(hue: Double = 0, saturation: Double = 0, lightness: Double = 0, range: [Double] = [315, 345, 15, 45]) {
        self.hue = hue; self.saturation = saturation; self.lightness = lightness; self.range = range
    }
}

// tolerant-decoding:HueRange (missing keys fall back to defaults)
extension HueRange {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HueRange()
        hue = (try? c.decodeIfPresent(Double.self, forKey: .hue)) ?? nil ?? d.hue
        saturation = (try? c.decodeIfPresent(Double.self, forKey: .saturation)) ?? nil ?? d.saturation
        lightness = (try? c.decodeIfPresent(Double.self, forKey: .lightness)) ?? nil ?? d.lightness
        let r = (try? c.decodeIfPresent([Double].self, forKey: .range)) ?? nil ?? d.range
        range = r.count == 4 ? r : d.range
    }
}
// end-tolerant

package struct ReplaceColorSettings: Codable, Equatable {
    /// Sampled colors (eyedropper / "+").
    package var colors: [RGBA] = []
    /// Colors removed with the "-" eyedropper.
    package var subtract: [RGBA] = []
    /// Sample locations in CI (bottom-left origin, canvas) coordinates — used by Localized Color Clusters.
    package var points: [CGPoint] = []
    package var fuzziness: Double = 40     // 0...200
    package var localized = false
    package var rangePercent: Double = 35  // localized range, % of the canvas' larger side
    package var canvasSize: Double = 1000  // larger canvas side when sampled (for rangePercent)
    package var hue: Double = 0            // -180...180
    package var saturation: Double = 0     // -100...100
    package var lightness: Double = 0      // -100...100

    package var isIdentity: Bool { colors.isEmpty || (hue == 0 && saturation == 0 && lightness == 0) }
    package init(colors: [RGBA] = [], subtract: [RGBA] = [], points: [CGPoint] = [], fuzziness: Double = 40, localized: Bool = false, rangePercent: Double = 35, canvasSize: Double = 1000, hue: Double = 0, saturation: Double = 0, lightness: Double = 0) {
        self.colors = colors; self.subtract = subtract; self.points = points; self.fuzziness = fuzziness; self.localized = localized; self.rangePercent = rangePercent; self.canvasSize = canvasSize; self.hue = hue; self.saturation = saturation; self.lightness = lightness
    }
}

// tolerant-decoding:ReplaceColorSettings (missing keys fall back to defaults)
extension ReplaceColorSettings {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReplaceColorSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        colors = v(.colors, d.colors); subtract = v(.subtract, d.subtract); points = v(.points, d.points)
        fuzziness = v(.fuzziness, d.fuzziness); localized = v(.localized, d.localized)
        rangePercent = v(.rangePercent, d.rangePercent); canvasSize = v(.canvasSize, d.canvasSize)
        hue = v(.hue, d.hue); saturation = v(.saturation, d.saturation); lightness = v(.lightness, d.lightness)
    }
}
// end-tolerant

/// Mean / standard deviation of L*, a*, b*.
package struct LabStats: Codable, Equatable {
    package var mean: [Double] = [50, 0, 0]
    package var std: [Double] = [20, 10, 10]
    package init(mean: [Double] = [50, 0, 0], std: [Double] = [20, 10, 10]) {
        self.mean = mean; self.std = std
    }
}

// tolerant-decoding:LabStats
extension LabStats {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LabStats()
        let m = (try? c.decodeIfPresent([Double].self, forKey: .mean)) ?? nil ?? d.mean
        let s = (try? c.decodeIfPresent([Double].self, forKey: .std)) ?? nil ?? d.std
        mean = m.count == 3 ? m : d.mean
        std = s.count == 3 ? s : d.std
    }
}
// end-tolerant

package struct MatchColorSettings: Codable, Equatable {
    package var luminance: Double = 100    // 1...200
    package var intensity: Double = 100    // 1...200 (color intensity)
    package var fade: Double = 0           // 0...100
    package var neutralize = false
    /// Statistics of the source image (nil = no source: target is matched to itself).
    package var source: LabStats? = nil
    /// Statistics of the target (layer being edited).
    package var target: LabStats? = nil
    package var sourceName: String = ""
    package init(luminance: Double = 100, intensity: Double = 100, fade: Double = 0, neutralize: Bool = false, source: LabStats? = nil, target: LabStats? = nil, sourceName: String = "") {
        self.luminance = luminance; self.intensity = intensity; self.fade = fade; self.neutralize = neutralize; self.source = source; self.target = target; self.sourceName = sourceName
    }
}

// tolerant-decoding:MatchColorSettings
extension MatchColorSettings {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MatchColorSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        luminance = v(.luminance, d.luminance); intensity = v(.intensity, d.intensity); fade = v(.fade, d.fade)
        neutralize = v(.neutralize, d.neutralize)
        source = (try? c.decodeIfPresent(LabStats.self, forKey: .source)) ?? nil
        target = (try? c.decodeIfPresent(LabStats.self, forKey: .target)) ?? nil
        sourceName = v(.sourceName, d.sourceName)
    }
}
// end-tolerant

package enum HDRMethod: String, Codable, CaseIterable, Identifiable {
    case localAdaptation = "Local Adaptation"
    case exposureGamma = "Exposure and Gamma"
    case highlightCompression = "Highlight Compression"
    package var id: String { rawValue }
}

package struct HDRToningSettings: Codable, Equatable {
    package var method: HDRMethod = .localAdaptation
    // Edge glow
    package var radius: Double = 30        // px 1...500
    package var strength: Double = 0.52    // 0.1...4
    // Tone and detail
    package var gamma: Double = 1          // 0.1...2
    package var exposure: Double = 0       // -5...5 stops
    package var detail: Double = 30        // -100...300 %
    // Advanced
    package var shadow: Double = 0         // -100...100
    package var highlight: Double = 0      // -100...100
    package var vibrance: Double = 0       // -100...100
    package var saturation: Double = 20    // -100...100
    // Toning curve (optional)
    package var useCurve = false
    package var curve = CurvePoints()
    package init(method: HDRMethod = .localAdaptation, radius: Double = 30, strength: Double = 0.52, gamma: Double = 1, exposure: Double = 0, detail: Double = 30, shadow: Double = 0, highlight: Double = 0, vibrance: Double = 0, saturation: Double = 20, useCurve: Bool = false, curve: CurvePoints = CurvePoints()) {
        self.method = method; self.radius = radius; self.strength = strength; self.gamma = gamma; self.exposure = exposure; self.detail = detail; self.shadow = shadow; self.highlight = highlight; self.vibrance = vibrance; self.saturation = saturation; self.useCurve = useCurve; self.curve = curve
    }
}

// tolerant-decoding:HDRToningSettings
extension HDRToningSettings {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HDRToningSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        method = v(.method, d.method); radius = v(.radius, d.radius); strength = v(.strength, d.strength)
        gamma = v(.gamma, d.gamma); exposure = v(.exposure, d.exposure); detail = v(.detail, d.detail)
        shadow = v(.shadow, d.shadow); highlight = v(.highlight, d.highlight)
        vibrance = v(.vibrance, d.vibrance); saturation = v(.saturation, d.saturation)
        useCurve = v(.useCurve, d.useCurve); curve = v(.curve, d.curve)
    }
}
// end-tolerant
