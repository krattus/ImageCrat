import Foundation
import CoreGraphics
import CoreImage
import ImageCratCore

extension TextContent {
    /// The stored pixels placed in CI space (nil when the layer no longer shows them).
    func storedPixelsImage(space: CanvasSpace) -> CIImage? {
        guard let p = storedPixels, showsStoredPixels, let m = storedPixelsTransform else { return nil }
        if m.a == 1, m.b == 0, m.c == 0, m.d == 1, m.tx == m.tx.rounded(), m.ty == m.ty.rounded(), abs(m.tx) < 1e7, abs(m.ty) < 1e7 {
            return space.place(p.buffer, at: IPoint(x: p.origin.x + Int(m.tx), y: p.origin.y + Int(m.ty)))
        }
        return space.place(p.buffer, at: p.origin).transformed(by: space.ciTransform(m), highQualityDownsample: true)
    }
}
