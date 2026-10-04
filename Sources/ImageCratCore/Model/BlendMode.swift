import Foundation

package enum BlendMode: String, Codable, CaseIterable, Identifiable {
    case passThrough, normal, dissolve
    case darken, multiply, colorBurn, linearBurn, darkerColor
    case lighten, screen, colorDodge, linearDodge, lighterColor
    case overlay, softLight, hardLight, vividLight, linearLight, pinLight, hardMix
    case difference, exclusion, subtract, divide
    case hue, saturation, color, luminosity

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .passThrough: return "Pass Through"
        case .normal: return "Normal"
        case .dissolve: return "Dissolve"
        case .darken: return "Darken"
        case .multiply: return "Multiply"
        case .colorBurn: return "Color Burn"
        case .linearBurn: return "Linear Burn"
        case .darkerColor: return "Darker Color"
        case .lighten: return "Lighten"
        case .screen: return "Screen"
        case .colorDodge: return "Color Dodge"
        case .linearDodge: return "Linear Dodge (Add)"
        case .lighterColor: return "Lighter Color"
        case .overlay: return "Overlay"
        case .softLight: return "Soft Light"
        case .hardLight: return "Hard Light"
        case .vividLight: return "Vivid Light"
        case .linearLight: return "Linear Light"
        case .pinLight: return "Pin Light"
        case .hardMix: return "Hard Mix"
        case .difference: return "Difference"
        case .exclusion: return "Exclusion"
        case .subtract: return "Subtract"
        case .divide: return "Divide"
        case .hue: return "Hue"
        case .saturation: return "Saturation"
        case .color: return "Color"
        case .luminosity: return "Luminosity"
        }
    }

    /// Grouping used for menu separators (as in Photoshop).
    package static let groups: [[BlendMode]] = [
        [.normal, .dissolve],
        [.darken, .multiply, .colorBurn, .linearBurn, .darkerColor],
        [.lighten, .screen, .colorDodge, .linearDodge, .lighterColor],
        [.overlay, .softLight, .hardLight, .vividLight, .linearLight, .pinLight, .hardMix],
        [.difference, .exclusion, .subtract, .divide],
        [.hue, .saturation, .color, .luminosity],
    ]

    package static let layerModes: [BlendMode] = groups.flatMap { $0 }
    package static let groupModes: [BlendMode] = [.passThrough] + layerModes
}
