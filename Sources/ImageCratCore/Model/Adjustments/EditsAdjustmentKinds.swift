import Foundation

extension AdjustmentKind {
    package static let editsLayerKinds: [AdjustmentKind] = [.colorWB, .light, .clarity, .dehaze, .grain]

    package var editsDisplayName: String {
        switch self {
        case .colorWB: return "Color"
        case .clarity: return "Clarity"
        case .dehaze: return "Dehaze"
        case .grain: return "Grain"
        case .light: return "Light"
        default: return rawValue
        }
    }

    package var editsSymbol: String {
        switch self {
        case .colorWB: return "thermometer.sun"
        case .clarity: return "sparkle.magnifyingglass"
        case .dehaze: return "cloud.sun"
        case .grain: return "circle.grid.3x3"
        case .light: return "sun.and.horizon"
        default: return "slider.horizontal.3"
        }
    }
}
