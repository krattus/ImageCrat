import CoreGraphics
import ImageCratCore

extension LineCapStyle {
    var cg: CGLineCap { switch self { case .butt: return .butt; case .round: return .round; case .square: return .square } }
}

extension LineJoinStyle {
    var cg: CGLineJoin { switch self { case .miter: return .miter; case .round: return .round; case .bevel: return .bevel } }
}
