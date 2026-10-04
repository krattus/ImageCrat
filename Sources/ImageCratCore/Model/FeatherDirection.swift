import Foundation

/// Which side of the edge a feather softens.
package enum FeatherDirection: String, Codable, CaseIterable, Identifiable {
    case centered = "Centered", inside = "Inside", outside = "Outside"
    package var id: String { rawValue }
    package var symbol: String {
        switch self { case .centered: return "circle.dotted.circle"; case .inside: return "circle.circle.fill"; case .outside: return "circle.dotted" }
    }
    package var help: String {
        switch self {
        case .centered: return "Soften across the edge (half inside, half outside)"
        case .inside: return "Keep the outline, fade inward only"
        case .outside: return "Keep the whole area, fade outward only"
        }
    }
}
