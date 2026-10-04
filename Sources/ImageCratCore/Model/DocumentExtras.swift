import Foundation

package enum ColorMode: String, Codable, CaseIterable, Identifiable {
    // Declaration order = Image ▸ Mode menu order (raw values are what documents store).
    case bitmap = "Bitmap", grayscale = "Grayscale", duotone = "Duotone", indexed = "Indexed Color"
    case rgb = "RGB Color", cmyk = "CMYK Color", lab = "Lab Color", multichannel = "Multichannel"
    package var id: String { rawValue }
    package var short: String {
        switch self {
        case .rgb: return "RGB"; case .grayscale: return "Gray"; case .cmyk: return "CMYK"; case .lab: return "Lab"
        case .bitmap: return "Bitmap"; case .duotone: return "Duotone"; case .indexed: return "Index"; case .multichannel: return "Multichannel"
        }
    }
}

/// Largest canvas side the app creates (same limit as File ▸ New…); larger pixel buffers cannot be allocated.
package let maxCanvasDimension = 30000
/// A usable document resolution (ppi): typed values of 0, negative numbers or NaN break unit conversions (rulers, type sizes).
package func validResolution(_ r: Double) -> Double { r.isFinite ? min(max(r, 1), 9999) : 72 }

package enum BitDepth: Int, Codable, CaseIterable, Identifiable {
    case eight = 8, sixteen = 16, thirtyTwo = 32
    package var id: Int { rawValue }
    package var displayName: String { "\(rawValue) Bits/Channel" }
}

/// Per-layer state captured by a layer comp.
package struct LayerCompEntry: Codable, Equatable {
    package var visible: Bool
    package var position: CGPoint?          // content bounds origin
    package var opacity: Double
    package var fillOpacity: Double
    package var blendMode: BlendMode
    package var effects: LayerEffects
    package init(visible: Bool, position: CGPoint? = nil, opacity: Double, fillOpacity: Double, blendMode: BlendMode, effects: LayerEffects) {
        self.visible = visible; self.position = position; self.opacity = opacity; self.fillOpacity = fillOpacity; self.blendMode = blendMode; self.effects = effects
    }
}

package struct LayerComp: Codable, Identifiable, Equatable {
    package var id = UUID()
    package var name: String
    package var comment: String = ""
    package var useVisibility = true
    package var usePosition = true
    package var useAppearance = true
    package var entries: [UUID: LayerCompEntry] = [:]
    package init(id: UUID = UUID(), name: String, comment: String = "", useVisibility: Bool = true, usePosition: Bool = true, useAppearance: Bool = true, entries: [UUID: LayerCompEntry] = [:]) {
        self.id = id; self.name = name; self.comment = comment; self.useVisibility = useVisibility; self.usePosition = usePosition; self.useAppearance = useAppearance; self.entries = entries
    }
}

/// Frame of a frame animation (Timeline panel).
package struct AnimationFrame: Codable, Identifiable, Equatable {
    package var id = UUID()
    package var delay: Double = 0.2          // seconds
    package var visibility: [UUID: Bool] = [:]
    package var positions: [UUID: CGPoint] = [:]
    package var opacities: [UUID: Double] = [:]
    package init(id: UUID = UUID(), delay: Double = 0.2, visibility: [UUID: Bool] = [:], positions: [UUID: CGPoint] = [:], opacities: [UUID: Double] = [:]) {
        self.id = id; self.delay = delay; self.visibility = visibility; self.positions = positions; self.opacities = opacities
    }
}

package enum AnimationLoop: String, Codable, CaseIterable { case once = "Once", three = "3 times", forever = "Forever" }
