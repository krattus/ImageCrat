import CoreImage
import Foundation
import ImageCratCore

/// View ▸ Pattern Preview: the document is shown tiled 3×3 around the canvas so edits can be judged for seamless repeats.
enum PatternPreview {
    private(set) static var enabled: Set<UUID> = []

    static func isOn(_ d: Document) -> Bool { enabled.contains(d.id) }

    static func toggle(_ d: Document) {
        if enabled.contains(d.id) { enabled.remove(d.id) } else { enabled.insert(d.id) }
        AppModel.shared.setStatus(isOn(d) ? "Pattern Preview on" : "Pattern Preview off")
        d.setNeedsRender()
    }

    /// The 8 neighbouring copies of the (display-ready) composite, already transformed to drawable space.
    static func tiles(_ comp: CIImage, doc: Document, transform t: CGAffineTransform, bounds: CGRect) -> CIImage? {
        guard isOn(doc) else { return nil }
        let W = CGFloat(doc.state.width), H = CGFloat(doc.state.height)
        let rect = CGRect(x: 0, y: 0, width: W, height: H)
        let base = comp.cropped(to: rect).composited(over: CIImage.color(.white, rect))
        var out = CIImage.clearImage.cropped(to: .zero)
        for dy in -1...1 { for dx in -1...1 where !(dx == 0 && dy == 0) {
            out = base.translated(CGFloat(dx) * W, CGFloat(dy) * H).composited(over: out)
        } }
        return out.transformed(by: t).cropped(to: bounds)
    }

    /// Doc-space image of the 3×3 tiling (for tests / snapshots).
    static func tiledImage(_ st: DocumentState) -> CIImage {
        let W = CGFloat(st.width), H = CGFloat(st.height)
        let rect = CGRect(x: 0, y: 0, width: W, height: H)
        let base = ImagingDisplay.inks(Compositor.shared.composite(st), state: st).cropped(to: rect).composited(over: CIImage.color(.white, rect))
        var out = CIImage.clearImage.cropped(to: .zero)
        for dy in 0..<3 { for dx in 0..<3 { out = base.translated(CGFloat(dx) * W, CGFloat(dy) * H).composited(over: out) } }
        return out
    }
}
