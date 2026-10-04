import Foundation

/// Lightweight auto-layout: how a layer follows its container (canvas or artboard) when the container is resized.
package struct LayoutConstraints: Codable, Equatable {
    package enum Axis: String, Codable, CaseIterable, Identifiable {
        case start, end, both, center, scale
        package var id: String { rawValue }

        package func title(horizontal: Bool) -> String {
            switch self {
            case .start: return horizontal ? "Left" : "Top"
            case .end: return horizontal ? "Right" : "Bottom"
            case .both: return horizontal ? "Left & Right" : "Top & Bottom"
            case .center: return "Centre"
            case .scale: return "Scale"
            }
        }
    }

    package var horizontal: Axis = .start
    package var vertical: Axis = .start

    package init(horizontal: Axis = .start, vertical: Axis = .start) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    private enum K: String, CodingKey { case horizontal, vertical }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        horizontal = c.tdValue(.horizontal, .start)
        vertical = c.tdValue(.vertical, .start)
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(horizontal, forKey: .horizontal)
        try c.encode(vertical, forKey: .vertical)
    }

    /// New (origin, length) of a span inside a container that changed from `o0…o0+l0` to `o1…o1+l1`.
    package static func resolve(_ axis: Axis, pos: CGFloat, len: CGFloat, from o0: CGFloat, _ l0: CGFloat, to o1: CGFloat, _ l1: CGFloat) -> (CGFloat, CGFloat) {
        let lead = pos - o0, trail = (o0 + l0) - (pos + len)
        switch axis {
        case .start: return (o1 + lead, len)
        case .end: return (o1 + l1 - trail - len, len)
        case .both: return (o1 + lead, max(1, l1 - lead - trail))
        case .center: return (o1 + l1 / 2 + (pos + len / 2 - (o0 + l0 / 2)) - len / 2, len)
        case .scale:
            let k = l0 > 0 ? l1 / l0 : 1
            return (o1 + lead * k, max(1, len * k))
        }
    }

    /// Where `rect` goes when its container changes from `old` to `new`.
    package func frame(for rect: CGRect, from old: CGRect, to new: CGRect) -> CGRect {
        let (x, w) = LayoutConstraints.resolve(horizontal, pos: rect.minX, len: rect.width, from: old.minX, old.width, to: new.minX, new.width)
        let (y, h) = LayoutConstraints.resolve(vertical, pos: rect.minY, len: rect.height, from: old.minY, old.height, to: new.minY, new.height)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
