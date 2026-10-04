import CoreGraphics
import ImageCratCore

extension BlendMode {
    /// Core Graphics equivalent for brush painting.
    var cgBlendMode: CGBlendMode {
        switch self {
        case .normal, .passThrough, .dissolve: return .normal
        case .darken, .darkerColor: return .darken
        case .multiply: return .multiply
        case .colorBurn, .linearBurn: return .colorBurn
        case .lighten, .lighterColor: return .lighten
        case .screen: return .screen
        case .colorDodge: return .colorDodge
        case .linearDodge: return .plusLighter
        case .overlay: return .overlay
        case .softLight: return .softLight
        case .hardLight, .vividLight, .linearLight, .pinLight, .hardMix: return .hardLight
        case .difference: return .difference
        case .exclusion: return .exclusion
        case .subtract, .divide: return .difference
        case .hue: return .hue
        case .saturation: return .saturation
        case .color: return .color
        case .luminosity: return .luminosity
        }
    }
    /// Core Image filter name (nil = custom kernel or normal).
    var ciFilterName: String? {
        switch self {
        case .normal, .passThrough, .dissolve, .darkerColor, .lighterColor, .hardMix: return nil
        case .darken: return "CIDarkenBlendMode"
        case .multiply: return "CIMultiplyBlendMode"
        case .colorBurn: return "CIColorBurnBlendMode"
        case .linearBurn: return "CILinearBurnBlendMode"
        case .lighten: return "CILightenBlendMode"
        case .screen: return "CIScreenBlendMode"
        case .colorDodge: return "CIColorDodgeBlendMode"
        case .linearDodge: return "CILinearDodgeBlendMode"
        case .overlay: return "CIOverlayBlendMode"
        case .softLight: return "CISoftLightBlendMode"
        case .hardLight: return "CIHardLightBlendMode"
        case .vividLight: return "CIVividLightBlendMode"
        case .linearLight: return "CILinearLightBlendMode"
        case .pinLight: return "CIPinLightBlendMode"
        case .difference: return "CIDifferenceBlendMode"
        case .exclusion: return "CIExclusionBlendMode"
        case .subtract: return "CISubtractBlendMode"
        case .divide: return "CIDivideBlendMode"
        case .hue: return "CIHueBlendMode"
        case .saturation: return "CISaturationBlendMode"
        case .color: return "CIColorBlendMode"
        case .luminosity: return "CILuminosityBlendMode"
        }
    }
}
