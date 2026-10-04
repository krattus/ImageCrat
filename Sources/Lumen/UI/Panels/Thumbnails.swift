import AppKit
import CoreImage
import ImageCratCore

/// Renders and caches small previews of layers, masks and documents.
final class Thumbnails {
    static let shared = Thumbnails()
    private var cache: [String: CGImage] = [:]
    private var order: [String] = []

    private func store(_ k: String, _ img: CGImage) {
        cache[k] = img
        order.append(k)
        if order.count > 600 {
            let r = order.removeFirst()
            cache.removeValue(forKey: r)
        }
    }

    /// Scales CI-space content of the canvas to fit a square box of `size` points (2x pixels).
    private func renderFit(_ img: CIImage, space: CanvasSpace, size: CGFloat, background: RGBA? = nil) -> CGImage? {
        let px = size * 2
        let s = min(px / CGFloat(space.width), px / CGFloat(space.height))
        let w = max(1, CGFloat(space.width) * s), h = max(1, CGFloat(space.height) * s)
        var i = img.cropped(to: space.ciCanvas)
        if let bg = background { i = i.composited(over: CIImage.color(bg, space.ciCanvas)) }
        let scaled = i.transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: true)
        return RenderEngine.readbackContext.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: sRGBSpace)
    }

    func layer(_ l: Layer, doc: Document, size: CGFloat) -> CGImage? {
        let key = "L\(l.id)-\(doc.revision)-\(Int(size))"
        if let c = cache[key] { return c }
        let space = CanvasSpace(width: doc.state.width, height: doc.state.height)
        guard let img = Compositor.shared.contentImage(l, space: space) else { return nil }
        guard let cg = renderFit(img, space: space, size: size) else { return nil }
        store(key, cg)
        return cg
    }

    func mask(_ l: Layer, doc: Document, size: CGFloat) -> CGImage? {
        guard let m = l.mask else { return nil }
        let key = "M\(l.id)-\(doc.revision)-\(Int(size))"
        if let c = cache[key] { return c }
        let space = CanvasSpace(width: doc.state.width, height: doc.state.height)
        let img = space.place(m.buffer, at: m.origin).composited(over: CIImage.color(RGBA(gray: Double(m.outsideValue) / 255), space.ciCanvas))
        guard let cg = renderFit(img, space: space, size: size) else { return nil }
        store(key, cg)
        return cg
    }

    func channel(_ buf: PixelBuffer, doc: Document, key: String, size: CGFloat) -> CGImage? {
        let k = "C\(key)-\(doc.revision)-\(buf.version)-\(Int(size))"
        if let c = cache[k] { return c }
        let space = CanvasSpace(width: doc.state.width, height: doc.state.height)
        guard let cg = renderFit(buf.ciImage, space: space, size: size) else { return nil }
        store(k, cg)
        return cg
    }

    func composite(_ doc: Document, size: CGFloat, channel: Int? = nil) -> CGImage? {
        let key = "D\(doc.id)-\(doc.revision)-\(Int(size))-\(channel ?? -1)"
        if let c = cache[key] { return c }
        let space = CanvasSpace(width: doc.state.width, height: doc.state.height)
        var img = Compositor.shared.composite(doc.state)
        if let ch = channel {
            let v = [CIVector(x: 1, y: 0, z: 0, w: 0), CIVector(x: 0, y: 1, z: 0, w: 0), CIVector(x: 0, y: 0, z: 1, w: 0)][ch]
            img = img.composited(over: CIImage.color(.white, space.ciCanvas)).applyingFilter("CIColorMatrix", parameters: ["inputRVector": v, "inputGVector": v, "inputBVector": v])
        }
        guard let cg = renderFit(img, space: space, size: size, background: channel == nil ? nil : .white) else { return nil }
        store(key, cg)
        return cg
    }
}
