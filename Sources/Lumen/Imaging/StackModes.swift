import Foundation
import CoreImage
import Metal
import ImageCratCore

/// Smart object Stack Modes: per-pixel statistics across the smart object's layers (Metal reduction).
enum StackModes {
    /// Called from `Compositor.smartSourceImage` for `.document` sources with a stack mode set.
    static func image(_ st: DocumentState, mode raw: String) -> CIImage? {
        guard let mode = StackMode(rawValue: raw), mode != .none else { return nil }
        let layers = st.layers.filter { $0.isVisible && !$0.isAdjustment }
        guard layers.count >= 1 else { return nil }
        let sp = CanvasSpace(width: st.width, height: st.height)
        let images = layers.map { Compositor.shared.composite(layers: [$0], backdrop: CIImage.clearImage.cropped(to: sp.ciCanvas), space: sp, options: .init()) }
        return reduce(images, width: st.width, height: st.height, mode: mode)
    }

    /// Reduces canvas-size CI images (extent 0,0,w,h) with `mode`. Returns an image of the same extent.
    static func reduce(_ images: [CIImage], width w: Int, height h: Int, mode: StackMode) -> CIImage? {
        let n = min(64, images.count)
        guard n > 0, w > 0, h > 0 else { return nil }
        let plane = w * h * 4
        let dev = RenderEngine.device
        guard let src = dev.makeBuffer(length: plane * n, options: .storageModeShared),
              let dst = dev.makeBuffer(length: plane, options: .storageModeShared) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        for i in 0..<n {
            let img = images[i].composited(over: CIImage.clearImage.cropped(to: rect))
            RenderEngine.readbackContext.render(img, toBitmap: src.contents() + i * plane, rowBytes: w * 4, bounds: rect, format: .RGBA8, colorSpace: sRGBSpace)
        }
        struct P { var width: UInt32; var height: UInt32; var count: UInt32; var mode: Int32 }
        var p = P(width: UInt32(w), height: UInt32(h), count: UInt32(n), mode: mode.shaderIndex)
        let ok = ImagingMetal.dispatch("lumenStackStats", width: w, height: h) { enc in
            enc.setBuffer(src, offset: 0, index: 0); enc.setBuffer(dst, offset: 0, index: 1)
            enc.setBytes(&p, length: MemoryLayout<P>.stride, index: 2)
        }
        guard ok else { return nil }
        let data = Data(bytes: dst.contents(), count: plane)
        guard let prov = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: sRGBSpace,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: prov, decode: nil,
                               shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return CIImage(cgImage: cg)
    }

    // MARK: Actions

    static func setStackMode(_ mode: StackMode) {
        guard let d = AppActions.doc, let id = d.activeLayerID, let l = d.state.layer(id), var so = l.smart else {
            AppActions.alert("Stack Mode requires a smart object layer.", "Select a smart object (for example one made by Load Files into Stack).")
            return
        }
        guard case .document = so.source else {
            AppActions.alert("Stack Mode needs a smart object that contains layers.")
            return
        }
        so.stack = mode
        so.sourceRevision += 1
        d.updateLayer(id) { $0.smart = so }
        d.commit("Stack Mode: \(mode.rawValue)")
        Compositor.shared.clearCaches()
        d.setNeedsRender()
    }
}
