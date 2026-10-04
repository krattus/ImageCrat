import Foundation
import CoreImage
import AppKit
import ImageCratCore

/// Synthetic-input tests for Photomerge, Auto-Align, focus stacking and HDR merging.
enum MergeSelfTest {
    typealias T = ImagingSelfTest

    /// Wide textured landscape (sky, clouds, ridges, trees, rocks, fine grain).
    static func landscape(_ w: Int, _ h: Int, seed: UInt64 = 5) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        let c = b.context
        let sky = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "3A6EA5")!.cgColor, RGBA(hex: "BFD7EA")!.cgColor] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: Double(h) * 0.55), options: [.drawsAfterEndLocation])
        var rng = ImgRNG(seed: seed)
        for _ in 0..<(w / 20) {
            c.setFillColor(RGBA(gray: 1, a: 0.25 + rng.next01() * 0.3).cgColor)
            let cw = 30 + rng.next01() * 120
            c.fillEllipse(in: CGRect(x: rng.next01() * Double(w), y: rng.next01() * Double(h) * 0.35, width: cw, height: cw * 0.35))
        }
        let ridges = ["6B7A99", "4F6B5A", "3E5A3A", "5C7F3B"]
        for (i, col) in ridges.enumerated() {
            c.setFillColor(RGBA(hex: col)!.cgColor)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: h))
            let base = Double(h) * (0.35 + 0.13 * Double(i))
            let ph = rng.next01() * 10
            for x in stride(from: 0, through: w, by: 4) {
                let xx = Double(x)
                let y = base - 40 * sin(xx / (90 + 30 * Double(i)) + ph) - 22 * sin(xx / 23.0 + ph * 2) - 9 * sin(xx / 7.3 + ph)
                p.addLine(to: CGPoint(x: xx, y: y))
            }
            p.addLine(to: CGPoint(x: w, y: h)); p.closeSubpath()
            c.addPath(p); c.fillPath()
        }
        for _ in 0..<(w * h / 900) {
            let x = rng.next01() * Double(w), y = Double(h) * (0.5 + rng.next01() * 0.5)
            let s = 3 + rng.next01() * 14
            if rng.next01() < 0.6 {
                c.setFillColor(RGBA(h: 0.22 + rng.next01() * 0.15, s: 0.5 + rng.next01() * 0.4, v: 0.2 + rng.next01() * 0.5).cgColor)
                c.move(to: CGPoint(x: x, y: y - s * 1.6)); c.addLine(to: CGPoint(x: x + s * 0.6, y: y)); c.addLine(to: CGPoint(x: x - s * 0.6, y: y)); c.fillPath()
            } else {
                c.setFillColor(RGBA(h: 0.08, s: 0.2 + rng.next01() * 0.3, v: 0.4 + rng.next01() * 0.5).cgColor)
                c.fillEllipse(in: CGRect(x: x, y: y, width: s, height: s * 0.6))
            }
        }
        // houses: sharp man-made corners
        for i in 0..<(w / 160) {
            let x = Double(i) * 160 + rng.next01() * 100, y = Double(h) * (0.62 + rng.next01() * 0.2)
            c.setFillColor(RGBA(hex: ["C94C4C", "E8D8B0", "8FA3B8"][i % 3])!.cgColor)
            c.fill(CGRect(x: x, y: y, width: 26, height: 18))
            c.setFillColor(RGBA(hex: "5A3A2A")!.cgColor)
            c.move(to: CGPoint(x: x - 3, y: y)); c.addLine(to: CGPoint(x: x + 13, y: y - 12)); c.addLine(to: CGPoint(x: x + 29, y: y)); c.fillPath()
            c.setFillColor(RGBA(hex: "2A3A5A")!.cgColor)
            c.fill(CGRect(x: x + 5, y: y + 5, width: 5, height: 5)); c.fill(CGRect(x: x + 16, y: y + 5, width: 5, height: 5))
        }
        b.markDirty()
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w {
            let o = y * b.bytesPerRow + x * 4
            let n = Int((rng.next01() - 0.5) * 14)
            for k in 0..<3 { p[o + k] = UInt8(clamp(Int(p[o + k]) + n, 0, 255)) }
        } }
        b.markDirty()
        return b
    }

    /// A tile of `big` (CI image of the scene) centred at doc point `c`, rotated, perspective-skewed, gain / vignette applied.
    static func tile(_ big: CIImage, bigH: Int, center c: CGPoint, w: Int, h: Int, angle: Double = 0, persp: Double = 0, gain: Double = 1, vignette: Double = 0) -> CIImage {
        let cc = CGPoint(x: c.x, y: CGFloat(bigH) - c.y)   // CI space
        var img = big.clampedToExtent()
        if persp != 0 {
            let r = CGRect(x: cc.x - CGFloat(w), y: cc.y - CGFloat(h), width: CGFloat(2 * w), height: CGFloat(2 * h))
            let d = CGFloat(persp)
            img = img.cropped(to: r).applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": CIVector(x: r.minX, y: r.maxY - d), "inputTopRight": CIVector(x: r.maxX, y: r.maxY),
                "inputBottomRight": CIVector(x: r.maxX, y: r.minY), "inputBottomLeft": CIVector(x: r.minX, y: r.minY + d)]).clampedToExtent()
        }
        let t = CGAffineTransform(translationX: -cc.x, y: -cc.y).concatenating(CGAffineTransform(rotationAngle: CGFloat(angle))).concatenating(CGAffineTransform(translationX: CGFloat(w) / 2, y: CGFloat(h) / 2))
        var out = img.transformed(by: t).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        if gain != 1 || vignette != 0, let k = Panorama.photoKernel {
            out = k.apply(extent: out.extent, arguments: [out, CIVector(x: CGFloat(gain), y: CGFloat(gain), z: CGFloat(gain)),
                                                          CIVector(x: CGFloat(vignette), y: CGFloat(w) / 2, z: CGFloat(h) / 2, w: CGFloat(w * w + h * h) / 4)]) ?? out
        }
        return MergeActions.materialize(out, CGRect(x: 0, y: 0, width: w, height: h))
    }

    static func saveState(_ st: DocumentState, _ name: String, _ out: URL) { _ = T.save(st, name, out) }

    // MARK: Photomerge

    static func panorama(_ out: URL) {
        let W = 1500, H = 620
        let big = landscape(W, H)
        let bigCI = big.ciImage
        _ = T.save(T.state(big), "imaging_pano_groundtruth", out)
        // 3 overlapping tiles (~35 % overlap), slightly rotated / perspective-shifted, different exposure + vignetting
        let tiles: [(CGPoint, Double, Double, Double)] = [(CGPoint(x: 330, y: 300), 0.02, 0, 1.0), (CGPoint(x: 750, y: 318), -0.015, 10, 1.25), (CGPoint(x: 1170, y: 305), 0.01, -8, 0.82)]
        let sources = tiles.enumerated().map { i, t in
            PanoSource(name: "Tile \(i + 1)", image: tile(bigCI, bigH: H, center: t.0, w: 560, h: 420, angle: t.1, persp: t.2, gain: t.3, vignette: 0.35))
        }
        for (i, s) in sources.enumerated() { T.saveImage(s.image, s.image.extent, "imaging_pano_input_\(i + 1)", out) }
        func run(_ name: String, _ o: PanoOptions, order: [Int] = [0, 1, 2]) {
            let t0 = CFAbsoluteTimeGetCurrent()
            guard let r = Panorama.build(order.map { sources[$0] }, options: o) else { T.check(false, "\(name): photomerge failed"); return }
            let st = MergeActions.panoramaState(r, options: o, resolution: 72)
            saveState(st, "imaging_pano_\(name)", out)
            T.check(r.layers.count == 3, "\(name): \(r.layout.rawValue) \(r.width)×\(r.height), \(st.layers.count) layers, \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - t0))s")
            if o.asLayers && o.blend {
                T.check(st.layers.allSatisfy { $0.mask != nil }, "\(name): layers carry seam masks")
            }
        }
        var o = PanoOptions(); o.layout = .perspective; o.vignette = true
        run("perspective_layers", o, order: [2, 0, 1])
        o.asLayers = false; o.contentAwareFill = true
        run("perspective_flat_cafill", o)
        o = PanoOptions(); o.layout = .auto; o.asLayers = false
        run("auto_flat", o)
        o.layout = .cylindrical; o.vignette = true
        run("cylindrical_flat", o)
        o.layout = .spherical
        run("spherical_flat", o)
        o.blend = false; o.layout = .perspective; o.asLayers = false; o.vignette = false
        run("perspective_noblend", o)
        o = PanoOptions(); o.layout = .reposition; o.asLayers = false
        run("reposition_flat", o)
        // collage with a strongly rotated tile
        let rot = [PanoSource(name: "L", image: tile(bigCI, bigH: H, center: CGPoint(x: 360, y: 300), w: 560, h: 420)),
                   PanoSource(name: "Rot", image: tile(bigCI, bigH: H, center: CGPoint(x: 720, y: 310), w: 520, h: 400, angle: 0.35, gain: 1.1)),
                   PanoSource(name: "R", image: tile(bigCI, bigH: H, center: CGPoint(x: 1080, y: 305), w: 560, h: 420))]
        o.layout = .collage
        if let r = Panorama.build(rot, options: o) {
            saveState(MergeActions.panoramaState(r, options: o, resolution: 72), "imaging_pano_collage_rotated", out)
            T.check(r.layers.count == 3, "collage aligned rotated tile (\(r.width)×\(r.height))")
        } else { T.check(false, "collage failed") }
        rotatingCamera(out)
    }

    static let viewKernel = CIKernel(source: """
    kernel vec4 lumenTestView(sampler eq, vec4 p, vec4 q) {
        vec2 d = destCoord();
        float x = d.x - 0.5;
        float y = p.w - d.y - 0.5;
        vec3 r = vec3((x - p.y) / p.x, (y - p.z) / p.x, 1.0);
        float cp = cos(q.y), sp = sin(q.y);
        r = vec3(r.x, cp * r.y - sp * r.z, sp * r.y + cp * r.z);
        float cy = cos(q.x), sy = sin(q.x);
        r = vec3(cy * r.x + sy * r.z, r.y, -sy * r.x + cy * r.z);
        float th = atan(r.x, r.z);
        float ph = atan(r.y, length(r.xz));
        float u = (th / 6.2831853 + 0.5) * q.z;
        float v = (ph / 3.14159265 + 0.5) * q.w;
        return sample(eq, samplerTransform(eq, vec2(u + q.z, q.w - v)));
    }
    """)

    /// Perspective view (focal f px) of an equirectangular scene at yaw / pitch (radians).
    static func view(_ eq: CIImage, eqW: Int, eqH: Int, yaw: Double, pitch: Double, f: Double, w: Int, h: Int) -> CIImage {
        let tripled = eq.translated(CGFloat(eqW), 0).composited(over: eq).composited(over: eq.translated(CGFloat(2 * eqW), 0))
        let ext = tripled.extent
        let img = viewKernel?.apply(extent: CGRect(x: 0, y: 0, width: w, height: h), roiCallback: { _, _ in ext }, arguments: [
            tripled, CIVector(x: CGFloat(f), y: CGFloat(w - 1) / 2, z: CGFloat(h - 1) / 2, w: CGFloat(h)),
            CIVector(x: CGFloat(yaw), y: CGFloat(pitch), z: CGFloat(eqW), w: CGFloat(eqH))]) ?? eq
        return MergeActions.materialize(img, CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// Views from a camera rotating about its centre: tests focal estimation, cylindrical and full 360° spherical output.
    static func rotatingCamera(_ out: URL) {
        let EW = 2400, EH = 1200
        let eq = landscape(EW, EH, seed: 13)
        _ = T.save(T.state(eq), "imaging_pano360_source_equirect", out)
        let f = 430.0
        let views = (0..<8).map { k in PanoSource(name: "Yaw \(k * 45)°", image: view(eq.ciImage, eqW: EW, eqH: EH, yaw: Double(k) * .pi / 4, pitch: k % 2 == 0 ? 0.03 : -0.02, f: f, w: 640, h: 480)) }
        for i in [0, 1] { T.saveImage(views[i].image, views[i].image.extent, "imaging_pano360_view_\(i)", out) }
        var o = PanoOptions(); o.layout = .cylindrical; o.asLayers = false
        if let r = Panorama.build(Array(views[0..<4]), options: o) {
            _ = T.save(MergeActions.panoramaState(r, options: o, resolution: 72), "imaging_pano360_cylindrical_4views", out)
            T.check(true, "cylindrical 4 views → \(r.width)×\(r.height) (\(r.log.first { $0.hasPrefix("focal") } ?? ""))")
        } else { T.check(false, "cylindrical 4 views failed") }
        o = PanoOptions(); o.layout = .spherical; o.full360 = true; o.asLayers = false
        if let r = Panorama.build(views, options: o) {
            T.check(r.width == 2 * r.height, "360 equirectangular output is 2:1 (\(r.width)×\(r.height), \(r.log.first { $0.hasPrefix("focal") } ?? ""))")
            let st = MergeActions.panoramaState(r, options: o, resolution: 72)
            _ = T.save(st, "imaging_pano360_spherical_full", out)
            let url = out.appendingPathComponent("imaging_pano_360.jpg")
            do { try Pano360.export(st, to: url, mode: .asIs); T.check(Pano360.hasGPano(url), "equirectangular JPEG carries GPano XMP") } catch { T.check(false, "360 export \(error)") }
        } else { T.check(false, "360 spherical failed") }
        o.layout = .auto; o.full360 = false
        if let r = Panorama.build(Array(views[0..<5]), options: o) {
            T.check(r.layout != .perspective, "auto layout picks \(r.layout.rawValue) for a 180° sweep")
        }
    }

    // MARK: Auto-Align

    static func autoAlign(_ out: URL) {
        let big = landscape(900, 600, seed: 9)
        let ci = big.ciImage
        let W = 640, H = 440
        let a = tile(ci, bigH: 600, center: CGPoint(x: 450, y: 300), w: W, h: H)
        let b = tile(ci, bigH: 600, center: CGPoint(x: 485, y: 280), w: W, h: H, angle: 0.04, persp: 6)
        let c = tile(ci, bigH: 600, center: CGPoint(x: 420, y: 318), w: W, h: H, angle: -0.03)
        var st = DocumentState(width: W, height: H)
        let sp = CanvasSpace(width: W, height: H)
        st.layers = [a, b, c].enumerated().map { Layer.raster(name: "Shot \($0.offset + 1)", buffer: RenderEngine.renderBuffer($0.element, docRect: st.canvasRect, space: sp)) }
        let d = Document(state: st, name: "align")
        func diffImage(_ s: DocumentState) -> (DocumentState, Double) {
            var t = s
            t.layers[1].blendMode = .difference
            t.layers[2].isVisible = false
            // mean abs difference in the central area
            let img = Compositor.shared.composite(t)
            let r = CGRect(x: 120, y: 100, width: 400, height: 240)
            var px = [UInt8](repeating: 0, count: 400 * 240 * 4)
            RenderEngine.readbackContext.render(img, toBitmap: &px, rowBytes: 1600, bounds: r, format: .RGBA8, colorSpace: sRGBSpace)
            var sum = 0.0
            for i in stride(from: 0, to: px.count, by: 4) { sum += Double(px[i]) + Double(px[i + 1]) + Double(px[i + 2]) }
            return (t, sum / Double(px.count / 4 * 3))
        }
        let (before, e0) = diffImage(d.state)
        saveState(before, "imaging_align_before_difference", out)
        let ok = MergeActions.autoAlign(d, ids: d.state.layers.map(\.id), layout: .auto, vignette: false, distortion: false)
        let (after, e1) = diffImage(d.state)
        saveState(after, "imaging_align_after_difference", out)
        saveState(d.state, "imaging_align_after", out)
        T.check(ok && e1 < e0 * 0.35 && e1 < 12, "auto-align: mean |diff| \(String(format: "%.1f", e0)) → \(String(format: "%.1f", e1))")
        d.undo()
        T.check(d.state.layers[1].raster?.origin == .zero, "auto-align is undoable")
    }

    // MARK: Focus stacking

    static func focusStack(_ out: URL) {
        let W = 480, H = 320
        let sharp = landscape(W, H, seed: 21)
        let ci = sharp.ciImage
        _ = T.save(T.state(sharp), "imaging_focus_groundtruth", out)
        let rect = CGRect(x: 0, y: 0, width: W, height: H)
        // three "focus slices": left / centre / right in focus
        var layers: [Layer] = []
        let sp = CanvasSpace(width: W, height: H)
        for i in 0..<3 {
            let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: 4).cropped(to: rect)
            let x0 = CGFloat(i) * CGFloat(W) / 3
            let band = CIImage.color(.white, CGRect(x: x0 - 20, y: 0, width: CGFloat(W) / 3 + 40, height: CGFloat(H))).composited(over: CIImage.color(.black, rect))
                .applyingGaussianBlur(sigma: 12).cropped(to: rect)
            let img = ci.mixed(with: blurred, mask: band)
            layers.append(Layer.raster(name: "Focus \(i + 1)", buffer: RenderEngine.renderBuffer(img, docRect: IRect(x: 0, y: 0, width: W, height: H), space: sp)))
        }
        var st = DocumentState(width: W, height: H)
        st.layers = layers
        for (i, l) in layers.enumerated() { var s1 = st; s1.layers = [l]; if i == 0 { saveState(s1, "imaging_focus_input_1", out) } }
        let d = Document(state: st, name: "focus")
        MergeActions.autoBlend(d, ids: d.state.layers.map(\.id), method: .stack, seamless: true)
        saveState(d.state, "imaging_focus_stacked", out)
        func err(_ s: DocumentState) -> Double {
            let img = Compositor.shared.composite(s).applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: ci])
            var px = [UInt8](repeating: 0, count: W * H * 4)
            RenderEngine.readbackContext.render(img, toBitmap: &px, rowBytes: W * 4, bounds: rect, format: .RGBA8, colorSpace: sRGBSpace)
            var sum = 0.0
            for i in stride(from: 0, to: px.count, by: 4) { sum += Double(px[i]) + Double(px[i + 1]) + Double(px[i + 2]) }
            return sum / Double(W * H * 3)
        }
        var single = st; single.layers = [layers[0]]
        let e0 = err(single), e1 = err(d.state)
        T.check(e1 < e0 * 0.5, "focus stack: error vs. all-sharp \(String(format: "%.2f", e0)) (single) → \(String(format: "%.2f", e1)) (stacked)")
        T.check(d.state.layers.allSatisfy { $0.mask != nil }, "focus stack: layer masks created")
    }

    // MARK: Load Files into Stack + Stack Mode

    static func loadStack(_ out: URL) {
        let W = 360, H = 240
        let big = landscape(460, 320, seed: 41)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-stack-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var urls: [URL] = []
        for i in 0..<5 {
            var img = tile(big.ciImage, bigH: 320, center: CGPoint(x: 230 + (i % 3) * 7 - 7, y: 160 + (i % 2) * 6 - 3), w: W, h: H, angle: Double(i - 2) * 0.006)
            // a passer-by in a different place on every frame
            img = CIImage.color(RGBA(hex: "E03C8A")!, CGRect(x: 30 + i * 62, y: 60, width: 26, height: 70)).composited(over: img).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
            var st = DocumentState(width: W, height: H)
            st.layers = [Layer.raster(name: "f", buffer: RenderEngine.renderBuffer(img, docRect: st.canvasRect, space: CanvasSpace(width: W, height: H)))]
            let u = tmp.appendingPathComponent("frame\(i + 1).png")
            try? DocumentIO.export(st, to: u, format: .png, quality: 1, scale: 1)
            urls.append(u)
        }
        let sources = urls.compactMap { MergeActions.source(url: $0) }
        guard let d = MergeActions.loadStack(sources, align: true, smartObject: true, name: "Stack") else { T.check(false, "load stack failed"); return }
        T.check(d.state.layers.count == 1 && d.state.layers[0].isSmartObject, "Load Files into Stack → aligned smart object (\(sources.count) files)")
        let id = d.state.layers[0].id
        d.updateLayer(id) { l in var so = l.smart!; so.stack = .median; so.sourceRevision += 1; l.smart = so }
        d.commit("Stack Mode")
        Compositor.shared.clearCaches()
        let url = T.save(d.state, "imaging_loadstack_median", out)
        if let cg = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let pb = PixelBuffer(cgImage: cg)
            var pink = 0
            for y in stride(from: 90, to: 170, by: 3) { for x in stride(from: 20, to: 340, by: 3) { let p = pb.pixel(x, y); if p.0 > 180 && p.1 < 110 && p.2 > 100 { pink += 1 } } }
            T.check(pink < 20, "median stack of aligned frames removes moving subject (\(pink) pink samples)")
        }
        d.updateLayer(id) { l in var so = l.smart!; so.stack = .mean; so.sourceRevision += 1; l.smart = so }
        Compositor.shared.clearCaches()
        _ = T.save(d.state, "imaging_loadstack_mean", out)
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: HDR

    static func hdr(_ out: URL) {
        HDRSelfTest.run(out)
    }
}
