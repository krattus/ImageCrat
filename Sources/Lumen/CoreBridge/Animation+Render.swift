import Foundation
import CoreGraphics
import ImageCratCore

extension Animation {
    /// Flattened image of every frame with its delay (the current state when there are no frames).
    static func renderFrames(_ st: DocumentState, background: RGBA? = nil) -> [(image: CGImage, delay: Double)] {
        if st.frames.isEmpty {
            guard let cg = Compositor.shared.flatten(st, background: background) else { return [] }
            return [(cg, 0)]
        }
        var out: [(CGImage, Double)] = []
        for f in st.frames {
            let s = applied(f, to: st)
            if let cg = Compositor.shared.flatten(s, background: background) { out.append((cg, f.delay)) }
        }
        return out
    }
}
