import SwiftUI
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

// MARK: - Sky mask

enum SkyEstimator {
    /// Sky matte (0…1, image size). Order: HEIC semantic sky matte → SkyMaskProvider hook → built-in estimator.
    static func mask(_ cg: CGImage, fileURL: URL? = nil) async -> (PlanarImage, String) {
        if let url = fileURL, let m = heicSkyMatte(url, width: cg.width, height: cg.height) { return (m, "HEIC sky matte") }
        if let p = SkyMaskProvider.provider, let r = try? await p(cg) {
            return (PlanarImage.gray(r, width: cg.width, height: cg.height), "segmentation service")
        }
        let depth = DepthEstimator.isAvailable ? try? await DepthEstimator.depth(NImg.fitted(cg, maxSide: 1024)) : nil
        return (estimate(cg, depth: depth), depth != nil ? "built-in (colour + texture + depth)" : "built-in (colour + texture)")
    }

    static func heicSkyMatte(_ url: URL, width: Int, height: Int) -> PlanarImage? {
        guard let img = CIImage(contentsOf: url, options: [.auxiliarySemanticSegmentationSkyMatte: true]) else { return nil }
        let sc = img.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / img.extent.width, y: CGFloat(height) / img.extent.height))
        guard let g = NImg.grayCG(sc, rect: CGRect(x: 0, y: 0, width: width, height: height)) else { return nil }
        return PlanarImage.gray(g)
    }

    /// Top-connected region of bright / blue / low-texture pixels (optionally: far in the depth map), refined with a
    /// guided filter at full resolution.
    static func estimate(_ cg: CGImage, depth: PlanarImage?) -> PlanarImage {
        let W = cg.width, H = cg.height
        let sc = min(1, 480 / Double(max(W, H)))
        let w = max(8, Int(Double(W) * sc)), h = max(8, Int(Double(H) * sc))
        let p = PlanarImage.rgb(cg, width: w, height: h)
        let n = w * h
        let d = depth?.resizedFloat(w, h)
        @inline(__always) func c(_ i: Int) -> (Float, Float, Float) { (p.data[i], p.data[n + i], p.data[2 * n + i]) }
        var grad = [Float](repeating: 0, count: n)
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let i = y * w + x
            var g: Float = 0
            for ch in 0..<3 {
                let b = ch * n
                g += abs(p.data[b + i - 1] - p.data[b + i + 1]) + abs(p.data[b + i - w] - p.data[b + i + w])
            }
            grad[i] = g
        } }
        // sky model from the top band (bright or blue-ish, smooth)
        var sr: Float = 0, sg: Float = 0, sb: Float = 0, cnt: Float = 0
        for y in 0..<max(1, h / 12) { for x in 0..<w { let (r, g, b) = c(y * w + x); sr += r; sg += g; sb += b; cnt += 1 } }
        sr /= cnt; sg /= cnt; sb /= cnt
        var mask = [Float](repeating: 0, count: n)
        var queue: [Int] = []
        for x in 0..<w { queue.append(x) }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            if mask[i] > 0 { continue }
            let x = i % w, y = i / w
            let (r, g, b) = c(i)
            // top row: no pixel above — only the global sky model applies (corners are often vignetted)
            let ref: (Float, Float, Float) = y > 0 ? c(i - w) : (r, g, b)
            let dLocal = abs(r - ref.0) + abs(g - ref.1) + abs(b - ref.2)
            let dGlobal = abs(r - sr) + abs(g - sg) + abs(b - sb)
            let far = d.map { $0.data[i] < 0.12 } ?? true
            let skyish = b >= r * 0.85 || (r + g + b) / 3 > 0.55
            if grad[i] > 0.3 || dLocal > 0.1 || dGlobal > 0.85 || !far || !skyish { continue }
            mask[i] = 1
            if x > 0 { queue.append(i - 1) }
            if x < w - 1 { queue.append(i + 1) }
            if y < h - 1 { queue.append(i + w) }
            if y > 0 { queue.append(i - w) }
        }
        // sky seen through foliage: disconnected pixels that match the sky colour closely and are far away
        var horizon = 0
        for y in 0..<h { for x in 0..<w where mask[y * w + x] > 0 { horizon = max(horizon, y) } }
        if let d {
            for y in 0..<horizon { for x in 0..<w {
                let i = y * w + x
                if mask[i] > 0 { continue }
                let (r, g, b) = c(i)
                if abs(r - sr) + abs(g - sg) + abs(b - sb) < 0.12 && d.data[i] < 0.06 { mask[i] = 1 }
            } }
        }
        var m = PlanarImage(width: w, height: h, channels: 1)
        m.data = mask
        // refine at full resolution with a guided filter (edges follow the image)
        let space = CanvasSpace(width: W, height: H)
        let mImg = CIImage(cgImage: m.cgImage()).transformed(by: CGAffineTransform(scaleX: CGFloat(W) / CGFloat(w), y: CGFloat(H) / CGFloat(h)))
            .clampedToExtent().applyingGaussianBlur(sigma: 0.7 / sc).cropped(to: space.ciCanvas)
        let guide = CIImage(cgImage: cg)
        let refined = mImg.applyingFilter("CIGuidedFilter", parameters: ["inputGuideImage": guide, kCIInputRadiusKey: max(4, 2 / sc), "inputEpsilon": 0.0004])
            .cropped(to: space.ciCanvas)
        guard let g = NImg.grayCG(refined, rect: space.ciCanvas) else { return m.resizedFloat(W, H) }
        var full = PlanarImage.gray(g)
        // borders: the guided filter under-estimates the outermost rows / columns
        let bw = max(2, Int(2 / sc))
        full.data.withUnsafeMutableBufferPointer { d in
            for y in 0..<H {
                let xs: [Int] = y < bw ? Array(0..<W) : Array(0..<bw) + Array((W - bw)..<W)
                for x in xs {
                    let sy = min(H - 1, max(y, bw)), sx = min(W - 1 - bw, max(x, bw))
                    d[y * W + x] = max(d[y * W + x], d[sy * W + sx])
                }
            }
        }
        return full
    }
}

// MARK: - Sky presets

enum SkyPresets {
    struct Preset: Identifiable { let id: String; let name: String; let make: (Int, Int) -> CIImage }

    static func gradient(_ w: Int, _ h: Int, _ stops: [(Double, String)]) -> CIImage {
        let b = PixelBuffer(width: w, height: h)
        let g = CGGradient(colorsSpace: sRGBSpace, colors: stops.map { RGBA(hex: $0.1)!.cgColor } as CFArray, locations: stops.map { CGFloat($0.0) })!
        b.context.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: h), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        b.markDirty()
        return b.ciImage
    }

    /// Cloud layer with perspective (flattened toward the horizon at the bottom). Returns premultiplied colour with alpha.
    static func cloudLayer(_ w: Int, _ h: Int, seed: Double, cover: Double, softness: Double, color: RGBA, shadow: RGBA, scale: Double = 1) -> CIImage {
        // noise on a wide plane, then perspective: the far (bottom, near the horizon) part is squashed
        let big = CGRect(x: 0, y: 0, width: w * 2, height: h * 2)
        var n = FilterKind.clouds(extent: big, scale: Double(max(w, h)) / 3 * scale, seed: seed, fg: .black, bg: .white)
        n = n.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(x: -CGFloat(w) * 0.6, y: CGFloat(h) * 1.05), "inputTopRight": CIVector(x: CGFloat(w) * 1.6, y: CGFloat(h) * 1.05),
            "inputBottomLeft": CIVector(x: -CGFloat(w) * 0.1, y: -CGFloat(h) * 0.02), "inputBottomRight": CIVector(x: CGFloat(w) * 1.1, y: -CGFloat(h) * 0.02)]).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        // coverage threshold with soft edge → alpha
        let lo = CGFloat(1 - cover), k = CGFloat(1 / max(0.05, softness))
        let a = n.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: k, y: 0, z: 0, w: 0),
                                                                "inputBVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: -lo * k, y: -lo * k, z: -lo * k, w: 0)])
            .applyingFilter("CIColorClamp")
        // shading: darker undersides from the noise itself
        let shade = n.applyingFilter("CIFalseColor", parameters: ["inputColor0": shadow.ciColor, "inputColor1": color.ciColor])
        return shade.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.clearImage.cropped(to: shade.extent), kCIInputMaskImageKey: a])
    }

    static let presets: [Preset] = [
        Preset(id: "blue", name: "Blue Sky") { w, h in
            cloudLayer(w, h, seed: 2, cover: 0.35, softness: 0.25, color: RGBA(hex: "FFFFFF")!, shadow: RGBA(hex: "B9C7D8")!)
                .composited(over: gradient(w, h, [(0, "1F5FAE"), (0.6, "5C9BDB"), (1, "BFDDF2")]))
        },
        Preset(id: "sunset", name: "Sunset") { w, h in
            let base = gradient(w, h, [(0, "2B2D6E"), (0.45, "B04A6D"), (0.75, "F08A4B"), (1, "FFD27A")])
            let sun = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: CGFloat(w) * 0.62, y: CGFloat(h) * 0.08), "inputRadius0": CGFloat(h) * 0.03,
                                                                      "inputRadius1": CGFloat(h) * 0.55, "inputColor0": CIColor(red: 1, green: 0.93, blue: 0.7, alpha: 0.95),
                                                                      "inputColor1": CIColor(red: 1, green: 0.6, blue: 0.3, alpha: 0)])!.outputImage!.cropped(to: base.extent)
            return cloudLayer(w, h, seed: 5, cover: 0.4, softness: 0.3, color: RGBA(hex: "FFB38A")!, shadow: RGBA(hex: "6B3A5E")!)
                .composited(over: sun.composited(over: base))
        },
        Preset(id: "dramatic", name: "Dramatic Clouds") { w, h in
            cloudLayer(w, h, seed: 8, cover: 0.75, softness: 0.45, color: RGBA(hex: "E8ECF0")!, shadow: RGBA(hex: "2E3440")!, scale: 1.3)
                .composited(over: gradient(w, h, [(0, "1C2533"), (0.7, "4A5A70"), (1, "9AA8B8")]))
        },
        Preset(id: "golden", name: "Golden Hour") { w, h in
            cloudLayer(w, h, seed: 13, cover: 0.3, softness: 0.3, color: RGBA(hex: "FFE2B0")!, shadow: RGBA(hex: "C98B5A")!)
                .composited(over: gradient(w, h, [(0, "5B83B8"), (0.6, "E8B67A"), (1, "FFE0A3")]))
        },
        Preset(id: "overcast", name: "Overcast") { w, h in
            cloudLayer(w, h, seed: 21, cover: 0.9, softness: 0.6, color: RGBA(hex: "E4E7EA")!, shadow: RGBA(hex: "8C939B")!, scale: 1.6)
                .composited(over: gradient(w, h, [(0, "9BA3AC"), (1, "D5D9DD")]))
        },
        Preset(id: "night", name: "Starry Night") { w, h in
            let r = CGRect(x: 0, y: 0, width: w, height: h)
            let stars = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: r)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 40, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 40, z: 0, w: 0),
                                                              "inputBVector": CIVector(x: 0, y: 0, z: 40, w: 0), "inputBiasVector": CIVector(x: -39.2, y: -39.2, z: -39.2, w: 0)])
                .applyingFilter("CIColorClamp")
            return stars.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: gradient(w, h, [(0, "050A1F"), (0.8, "1B2A55"), (1, "3E4E7A")])]).cropped(to: r)
        },
    ]
}

// MARK: - Engine

struct SkySettings: Equatable {
    var presetIndex = 0
    var customSky: CGImage? = nil
    var shiftEdge: Double = 0        // -100…100
    var fadeEdge: Double = 10        // 0…100
    var brightness: Double = 0       // -100…100
    var temperature: Double = 0      // -100…100
    var scale: Double = 100          // 50…300 %
    var flip = false
    var moveX: Double = 0            // -50…50 %
    var moveY: Double = 0
    var lightingMultiply = true
    var lighting: Double = 50        // 0…100
    var edgeLighting: Double = 20
    var colorAdjust: Double = 50

    static func == (a: SkySettings, b: SkySettings) -> Bool {
        a.presetIndex == b.presetIndex && a.customSky === b.customSky && a.shiftEdge == b.shiftEdge && a.fadeEdge == b.fadeEdge && a.brightness == b.brightness &&
            a.temperature == b.temperature && a.scale == b.scale && a.flip == b.flip && a.moveX == b.moveX && a.moveY == b.moveY &&
            a.lightingMultiply == b.lightingMultiply && a.lighting == b.lighting && a.edgeLighting == b.edgeLighting && a.colorAdjust == b.colorAdjust
    }
}

enum SkyReplacement {
    /// Result parts in CI space (extent 0,0,W,H).
    struct Parts {
        var sky: CIImage            // adjusted sky, full canvas
        var skyMask: CIImage        // gray
        var fgMask: CIImage         // gray (inverse of sky, feathered)
        var edgeMask: CIImage       // gray band inside the foreground edge
        var skyColor: RGBA          // mean sky colour (lighting)
        var edgeLight: CIImage      // sky spill for edge lighting
    }

    static func skyImage(_ s: SkySettings, width W: Int, height H: Int, horizon: Int) -> CIImage {
        let cover = CGRect(x: 0, y: 0, width: W, height: H)
        let targetH = max(Int(Double(H) * 0.35), Int(Double(horizon) * 1.1))
        var sky: CIImage
        if let c = s.customSky {
            sky = CIImage(cgImage: c)
        } else {
            sky = SkyPresets.presets[max(0, min(SkyPresets.presets.count - 1, s.presetIndex))].make(W, max(16, targetH))
        }
        // aspect-fill the band [0, targetH] (doc coords), then scale / flip / move around its centre
        let e = sky.extent
        let fill = max(CGFloat(W) / e.width, CGFloat(targetH) / e.height) * CGFloat(s.scale / 100)
        var t = CGAffineTransform(translationX: -e.midX, y: -e.midY).concatenating(CGAffineTransform(scaleX: s.flip ? -fill : fill, y: fill))
        // CI y-up: band centre at H - targetH/2
        t = t.concatenating(CGAffineTransform(translationX: CGFloat(W) / 2 + CGFloat(s.moveX / 100) * CGFloat(W),
                                              y: CGFloat(H) - CGFloat(targetH) / 2 - CGFloat(s.moveY / 100) * CGFloat(H)))
        sky = sky.clampedToExtent().transformed(by: t).cropped(to: cover)
        if s.brightness != 0 { sky = sky.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: s.brightness / 100 * 1.2]) }
        if s.temperature != 0 {
            sky = sky.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - CGFloat(s.temperature) * 30, y: 0)])
        }
        return sky.cropped(to: cover)
    }

    static func parts(photo: CIImage, mask: PlanarImage, _ s: SkySettings) -> Parts {
        let W = mask.width, H = mask.height
        let r = CGRect(x: 0, y: 0, width: W, height: H)
        var horizon = 0
        let step = max(1, W / 256)
        for y in stride(from: 0, to: H, by: 2) { for x in stride(from: 0, to: W, by: step) where mask.data[y * W + x] > 0.5 { horizon = max(horizon, y); break } }
        let diag = Double(max(W, H))
        var m = CIImage(cgImage: mask.cgImage())
        // shift edge: grow (+) / shrink (−)
        let shift = s.shiftEdge / 100 * diag * 0.01
        if shift > 0.5 { m = m.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: shift]).cropped(to: r) }
        if shift < -0.5 { m = m.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: -shift]).cropped(to: r) }
        let fade = s.fadeEdge / 100 * diag * 0.006
        if fade > 0.3 { m = m.clampedToExtent().applyingGaussianBlur(sigma: fade).cropped(to: r) }
        let sky = skyImage(s, width: W, height: H, horizon: horizon)
        let fg = m.inverted().cropped(to: r)
        // edge band: foreground within ~1.5% of the sky boundary
        let band = diag * 0.015
        let grown = m.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: band]).cropped(to: r)
            .clampedToExtent().applyingGaussianBlur(sigma: band / 2).cropped(to: r)
        let edge = grown.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: fg])
        // mean sky colour where the sky shows
        let avg = sky.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(x: 0, y: H - max(1, horizon), width: W, height: max(1, horizon)))])
        var px = [Float](repeating: 0, count: 4)
        NImg.ctx.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(origin: avg.extent.origin, size: CGSize(width: 1, height: 1)), format: .RGBAf, colorSpace: nil)
        let col = RGBA(r: Double(px[0]), g: Double(px[1]), b: Double(px[2]))
        let spill = sky.clampedToExtent().applyingGaussianBlur(sigma: band).cropped(to: r)
        _ = photo
        return Parts(sky: sky, skyMask: m.cropped(to: r), fgMask: fg, edgeMask: edge, skyColor: col, edgeLight: spill)
    }

    /// Lighting colour for the foreground (multiply keeps it light, screen keeps it dark).
    static func lightColor(_ c: RGBA, multiply: Bool) -> RGBA {
        if multiply {
            let m = max(c.r, max(c.g, c.b), 0.001)
            return RGBA(r: 0.55 + 0.45 * c.r / m, g: 0.55 + 0.45 * c.g / m, b: 0.55 + 0.45 * c.b / m)
        }
        return RGBA(r: c.r * 0.5, g: c.g * 0.5, b: c.b * 0.5)
    }

    /// Flattened preview / duplicate-layer output.
    static func composite(photo: CIImage, parts p: Parts, _ s: SkySettings) -> CIImage {
        let r = photo.extent
        var out = photo
        // foreground colour adjustment (photo filter toward the sky colour)
        if s.colorAdjust > 0 {
            var a = AdjustmentSettings(kind: .photoFilter)
            a.filterColor = p.skyColor; a.density = s.colorAdjust * 0.6; a.preserveLuminosity = true
            let adj = AdjustmentEngine.apply(a, to: out)
            out = adj.mixed(with: out, mask: p.fgMask).cropped(to: r)
        }
        if s.lighting > 0 {
            let lc = CIImage.color(lightColor(p.skyColor, multiply: s.lightingMultiply), r)
            let lit = s.lightingMultiply ? lc.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: out])
                                         : lc.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: out])
            let k = CGFloat(s.lighting / 100)
            let m = p.fgMask.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0)])
            out = lit.mixed(with: out, mask: m).cropped(to: r)
        }
        if s.edgeLighting > 0 {
            let k = CGFloat(s.edgeLighting / 100 * 0.8)
            let m = p.edgeMask.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0)])
            out = p.edgeLight.mixed(with: out, mask: m).cropped(to: r)
        }
        return p.sky.mixed(with: out, mask: p.skyMask).cropped(to: r)
    }

    /// Adds the Photoshop-style layer stack above the active layer.
    @MainActor
    static func applyAsLayers(_ d: Document, parts p: Parts, _ s: SkySettings) {
        let W = d.state.width, H = d.state.height
        let space = CanvasSpace(width: W, height: H)
        func gray(_ img: CIImage) -> PixelBuffer { RenderEngine.renderBuffer(img, docRect: d.state.canvasRect, space: space, format: .gray) }
        func rgba(_ img: CIImage) -> PixelBuffer { RenderEngine.renderBuffer(img, docRect: d.state.canvasRect, space: space) }
        var children: [Layer] = []
        // Foreground colour (Photo Filter adjustment masked to the foreground)
        var fgColor = AdjustmentSettings(kind: .photoFilter)
        fgColor.filterColor = p.skyColor; fgColor.density = s.colorAdjust * 0.6; fgColor.preserveLuminosity = true
        var colorLayer = Layer(name: "Foreground Color", content: .adjustment(fgColor))
        colorLayer.mask = LayerMask(buffer: gray(p.fgMask), origin: .zero, outsideValue: 0)
        colorLayer.isVisible = s.colorAdjust > 0
        // Foreground lighting (solid colour, multiply / screen)
        let lbuf = rgba(CIImage.color(lightColor(p.skyColor, multiply: s.lightingMultiply), space.ciCanvas))
        var light = Layer.raster(name: "Foreground Lighting", buffer: lbuf)
        light.blendMode = s.lightingMultiply ? .multiply : .screen
        light.opacity = s.lighting / 100
        light.mask = LayerMask(buffer: gray(p.fgMask), origin: .zero, outsideValue: 0)
        // Edge lighting (sky spill)
        var edge = Layer.raster(name: "Edge Lighting", buffer: rgba(p.edgeLight))
        edge.opacity = s.edgeLighting / 100 * 0.8
        edge.mask = LayerMask(buffer: gray(p.edgeMask), origin: .zero, outsideValue: 0)
        // Sky
        var sky = Layer.raster(name: "Sky", buffer: rgba(p.sky))
        sky.mask = LayerMask(buffer: gray(p.skyMask), origin: .zero, outsideValue: 0)
        children = [colorLayer, light, edge, sky]
        var group = Layer(name: "Sky Replacement Group", content: .group(GroupContent(children: children, isExpanded: true)))
        group.blendMode = .passThrough
        d.addLayer(group, commitName: "Sky Replacement")
    }
}

// MARK: - Dialog

@Observable
final class SkyReplacementModel {
    var s = SkySettings()
    var mask: PlanarImage? = nil
    var maskSource = ""
    var preview: CGImage? = nil
    var photoPreview: CIImage? = nil
    var busy = true
    var showMask = false
    var duplicateOutput = false
    var fullPhoto: CGImage? = nil
    var thumbs: [CGImage] = []
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var previewMask: PlanarImage?
    @ObservationIgnored var loaded = false

    func load() {
        guard !loaded, let d = AppActions.doc else { return }
        loaded = true
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        let comp = Compositor.shared.composite(d.committedState).composited(over: CIImage.color(.white, space.ciCanvas))
        guard let cg = NImg.cg(comp, rect: space.ciCanvas) else { return }
        fullPhoto = cg
        let url = d.fileURL
        thumbs = SkyPresets.presets.compactMap { NImg.cg($0.make(96, 64), rect: CGRect(x: 0, y: 0, width: 96, height: 64)) }
        Task.detached {
            let (m, src) = await SkyEstimator.mask(cg, fileURL: url)
            await MainActor.run {
                self.mask = m; self.maskSource = src; self.busy = false
                self.update()
            }
        }
    }

    func update() {
        guard let full = fullPhoto, let m = mask else { return }
        task?.cancel()
        let s = self.s, showMask = self.showMask
        task = Task.detached(priority: .userInitiated) {
            let small = NImg.fitted(full, maxSide: 900)
            let pm = m.resized(small.width, small.height)
            let photo = CIImage(cgImage: small)
            let parts = SkyReplacement.parts(photo: photo, mask: pm, s)
            let img = showMask ? parts.skyMask : SkyReplacement.composite(photo: photo, parts: parts, s)
            let cg = NImg.cg(img, rect: photo.extent)
            if Task.isCancelled { return }
            await MainActor.run { self.preview = cg }
        }
    }

    @MainActor
    func apply() {
        guard let d = AppActions.doc, let full = fullPhoto, let m = mask else { return }
        let photo = CIImage(cgImage: full)
        let parts = SkyReplacement.parts(photo: photo, mask: m, s)
        if duplicateOutput {
            let space = CanvasSpace(width: d.state.width, height: d.state.height)
            let img = SkyReplacement.composite(photo: photo, parts: parts, s)
            let buf = RenderEngine.renderBuffer(img, docRect: d.state.canvasRect, space: space)
            d.addLayer(Layer.raster(name: "Sky Replacement", buffer: buf), commitName: "Sky Replacement")
        } else {
            SkyReplacement.applyAsLayers(d, parts: parts, s)
        }
    }
}

struct SkyReplacementDialog: View {
    @State private var m: SkyReplacementModel

    init(model: SkyReplacementModel = SkyReplacementModel()) { _m = State(initialValue: model) }

    var body: some View {
        DialogFrame(title: "Sky Replacement", width: 820, onOK: { m.apply() }) {
            HStack(alignment: .top, spacing: 14) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Caption("Sky")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6)], spacing: 6) {
                            ForEach(Array(m.thumbs.enumerated()), id: \.offset) { i, t in
                                Button { m.s.presetIndex = i; m.s.customSky = nil } label: {
                                    VStack(spacing: 2) {
                                        Image(decorative: t, scale: 1).resizable().frame(width: 70, height: 46).clipShape(RoundedRectangle(cornerRadius: 3))
                                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(m.s.customSky == nil && m.s.presetIndex == i ? Theme.accent : .clear, lineWidth: 2))
                                        Text(tr(SkyPresets.presets[i].name)).font(Theme.fontSmall).lineLimit(1)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                        Button("Add Sky Image…") { pickSky() }.buttonStyle(PanelButtonStyle())
                        Divider()
                        ValueSlider(label: "Shift Edge", value: $m.s.shiftEdge, range: -100...100)
                        ValueSlider(label: "Fade Edge", value: $m.s.fadeEdge, range: 0...100)
                        Caption("Sky Adjustments")
                        ValueSlider(label: "Brightness", value: $m.s.brightness, range: -100...100)
                        ValueSlider(label: "Temperature", value: $m.s.temperature, range: -100...100)
                        ValueSlider(label: "Scale", value: $m.s.scale, range: 50...300, unit: "%")
                        ValueSlider(label: "Move X", value: $m.s.moveX, range: -50...50, unit: "%")
                        ValueSlider(label: "Move Y", value: $m.s.moveY, range: -50...50, unit: "%")
                        Toggle2(label: "Flip", on: $m.s.flip)
                        Caption("Foreground Adjustments")
                        Picker("Lighting Mode", selection: $m.s.lightingMultiply) { Text("Multiply").tag(true); Text("Screen").tag(false) }.pickerStyle(.segmented)
                        ValueSlider(label: "Lighting", value: $m.s.lighting, range: 0...100)
                        ValueSlider(label: "Edge Lighting", value: $m.s.edgeLighting, range: 0...100)
                        ValueSlider(label: "Color Adjust", value: $m.s.colorAdjust, range: 0...100)
                        Caption("Output")
                        Picker("", selection: $m.duplicateOutput) { Text("New Layers").tag(false); Text("Duplicate Layer").tag(true) }.pickerStyle(.segmented).labelsHidden()
                    }.padding(.trailing, 6)
                }.frame(width: 280, height: 520)
                VStack(alignment: .leading, spacing: 6) {
                    ZStack {
                        CheckerBackground()
                        if let p = m.preview { Image(decorative: p, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                        if m.busy { ProgressView("Finding sky…").padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelBG.opacity(0.9))) }
                    }.frame(width: 500, height: 480).clipped()
                    HStack {
                        Toggle2(label: "Show Sky Mask", on: $m.showMask)
                        Spacer()
                        Text(tr(m.maskSource.isEmpty ? "" : "Mask: \(m.maskSource)")).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                    }
                }
            }
        }
        .onAppear { m.load() }
        .onChange(of: m.s) { _, _ in m.update() }
        .onChange(of: m.showMask) { _, _ in m.update() }
    }

    func pickSky() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        UIBlock.begin(p) { r in
            guard r == .OK, let url = p.url, let cg = NImg.loadCG(url) else { return }
            m.s.customSky = cg
        }
    }
}
