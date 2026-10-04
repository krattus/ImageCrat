import Foundation
import CoreGraphics
import ImageCratCore

extension Quad {
    var path: CGPath {
        let p = CGMutablePath()
        p.addLines(between: points)
        p.closeSubpath()
        return p
    }
}
