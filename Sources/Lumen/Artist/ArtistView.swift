import AppKit
import CoreImage
import ImageCratCore

/// View-only canvas modes: vision simulation (View ▸ Simulate) and the mirrored canvas view (View ▸ Flip Canvas View).
/// Neither touches pixels, exports or the document state.
enum ArtistView {
    /// Documents shown mirrored (by document id).
    private(set) static var flipped: Set<UUID> = []

    static func isFlipped(_ d: Document?) -> Bool {
        guard let d, !flipped.isEmpty else { return false }
        return flipped.contains(d.id)
    }

    /// Mirrors the canvas view horizontally around the centre of the viewport.
    static func toggleFlip() {
        guard let d = AppActions.doc else { return }
        setFlipped(d, !flipped.contains(d.id), canvas: AppActions.canvas)
        AppModel.shared.setStatus(flipped.contains(d.id) ? "Canvas view flipped (view only — the image is unchanged)" : "Canvas view restored")
    }

    static func setFlipped(_ d: Document, _ on: Bool, canvas: CanvasView?) {
        guard on != flipped.contains(d.id) else { return }
        if let c = canvas, c.document === d {
            let ins = c.contentInsets     // pivot = centre of the canvas area inside the rulers, so a fitted canvas stays put
            let center = CGPoint(x: ins.left + (c.bounds.width - ins.left) / 2, y: ins.top + (c.bounds.height - ins.top) / 2)
            let docPt = c.viewToDoc(center)
            if on { flipped.insert(d.id) } else { flipped.remove(d.id) }
            let moved = c.docToView(docPt)
            d.viewOffset = d.viewOffset + (center - moved)
            c.setNeedsRender()
        } else {
            if on { flipped.insert(d.id) } else { flipped.remove(d.id) }
            d.setNeedsRender()
        }
    }

    /// Canvas hook (`CanvasRenderer.applyViewMode`): applies the active simulation to the display image.
    static func apply(_ img: CIImage, doc: Document) -> CIImage {
        let sim = ArtistSettings.shared.simulation
        guard sim != .none else { return img }
        let rect = CGRect(x: 0, y: 0, width: doc.state.width, height: doc.state.height)
        return sim.apply(img, extent: rect)
    }
}
