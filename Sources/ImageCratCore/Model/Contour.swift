import Foundation

/// Photoshop-style contour: remaps an effect's 0…1 falloff ramp (shadows, glows, satin, bevel gloss).
package enum ContourPreset: String, Codable, CaseIterable, Identifiable {
    case linear, gaussian, halfRound, cone, coneInverted, cove, ring, ringDouble, rollingSlope, sawtooth, roundedSteps, custom
    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .gaussian: return "Gaussian"
        case .halfRound: return "Half Round"
        case .cone: return "Cone"
        case .coneInverted: return "Cone - Inverted"
        case .cove: return "Cove - Deep"
        case .ring: return "Ring"
        case .ringDouble: return "Ring - Double"
        case .rollingSlope: return "Rolling Slope - Descending"
        case .sawtooth: return "Sawtooth 1"
        case .roundedSteps: return "Rounded Steps"
        case .custom: return "Custom"
        }
    }

    package func value(_ t: Double) -> Double {
        let x = clamp(t, 0, 1)
        switch self {
        case .linear, .custom: return x
        case .gaussian: return x * x * (3 - 2 * x)
        case .halfRound: return sqrt(max(0, 1 - (1 - x) * (1 - x)))
        case .cone: return 1 - abs(2 * x - 1)
        case .coneInverted: return abs(2 * x - 1)
        case .cove: return x * x * x
        case .ring: return 0.5 - 0.5 * cos(x * 2 * .pi)
        case .ringDouble: return 0.5 - 0.5 * cos(x * 4 * .pi)
        case .rollingSlope: return x + 0.18 * sin(x * 3 * .pi)
        case .sawtooth: return (x * 3).truncatingRemainder(dividingBy: 1)
        case .roundedSteps:
            let n = 4.0, s = floor(x * n), f = x * n - s
            return (s + f * f * (3 - 2 * f)) / n
        }
    }
}

package struct Contour: Codable, Equatable {
    package var preset: ContourPreset = .linear
    package var custom = CurvePoints()
    package var antialias = false

    package static let linear = Contour()

    package var isLinear: Bool { preset == .linear || (preset == .custom && custom.isIdentity) }

    package func value(_ t: Double) -> Double {
        if preset == .custom {
            let l = custom.lut(256)
            return l[Int((clamp(t, 0, 1) * 255).rounded())]
        }
        return clamp(preset.value(t), 0, 1)
    }

    /// 256-entry table.
    package func table() -> [Float] { (0..<256).map { Float(value(Double($0) / 255)) } }

    package init(preset: ContourPreset = .linear, custom: CurvePoints = CurvePoints(), antialias: Bool = false) {
        self.preset = preset; self.custom = custom; self.antialias = antialias
    }
}
// tolerant-decoding:Contour (generated: missing keys fall back to defaults)
extension Contour {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Contour()
        preset = try c.decodeIfPresent(ContourPreset.self, forKey: .preset) ?? d.preset
        custom = try c.decodeIfPresent(CurvePoints.self, forKey: .custom) ?? d.custom
        antialias = try c.decodeIfPresent(Bool.self, forKey: .antialias) ?? d.antialias
    }
}
// end-tolerant

/// Document-wide lighting shared by effects that "Use Global Light".
package struct GlobalLight: Codable, Equatable {
    package var angle: Double = 120
    package var altitude: Double = 30

    package init(angle: Double = 120, altitude: Double = 30) {
        self.angle = angle; self.altitude = altitude
    }
}
// tolerant-decoding:GlobalLight (generated: missing keys fall back to defaults)
extension GlobalLight {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GlobalLight()
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? d.angle
        altitude = try c.decodeIfPresent(Double.self, forKey: .altitude) ?? d.altitude
    }
}
// end-tolerant
