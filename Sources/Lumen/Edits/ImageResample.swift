import SwiftUI
import CoreImage
import Metal
import MetalFX
import ImageCratCore

// MARK: - Upscaler hook (Preserve Details 2.0)

/// On-device / remote super-resolution upscalers used by Image Size ▸ Preserve Details 2.0.
/// `run(image, scale)` returns an image enlarged by roughly `scale` (Image Size resamples it to the exact size afterwards).
enum UpscalerRegistry {
    static var upscalers: [(name: String, run: (CGImage, Double) async throws -> CGImage)] = []

    static func register(name: String, run: @escaping (CGImage, Double) async throws -> CGImage) {
        upscalers.removeAll { $0.name == name }
        upscalers.append((name: name, run: run))
    }

    /// Built-in: MetalFX spatial upscaler (Apple GPU, runs on device).
    static func registerBuiltIns() {
        if MTLFXSpatialScalerDescriptor.supportsDevice(RenderEngine.device) {
            register(name: "MetalFX Spatial (on-device)") { img, scale in
                guard let out = MetalFXUpscale.upscale(img, scale: scale) else { throw NSError(domain: "ImageCrat.Upscale", code: 1) }
                return out
            }
        }
    }
}

enum MetalFXUpscale {
    /// Spatial (edge-adaptive) upscale by up to 2× per pass; larger factors use several passes.
    static func upscale(_ img: CGImage, scale: Double) -> CGImage? {
        var cur = CIImage(cgImage: img)
        var remaining = max(1, scale)
        while remaining > 1.001 {
            let s = min(2, remaining)
            guard let next = pass(cur, scale: s) else { return nil }
            cur = next
            remaining /= s
        }
        return RenderEngine.cgImage(cur, rect: cur.extent)
    }

    private static func pass(_ input: CIImage, scale: Double) -> CIImage? {
        let dev = RenderEngine.device
        let w = Int(input.extent.width), h = Int(input.extent.height)
        let ow = Int((Double(w) * scale).rounded()), oh = Int((Double(h) * scale).rounded())
        let d = MTLFXSpatialScalerDescriptor()
        d.inputWidth = w; d.inputHeight = h; d.outputWidth = ow; d.outputHeight = oh
        d.colorTextureFormat = .rgba16Float; d.outputTextureFormat = .rgba16Float
        d.colorProcessingMode = .perceptual
        guard let scaler = d.makeSpatialScaler(device: dev) else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        td.usage = scaler.colorTextureUsage.union([.shaderRead, .shaderWrite, .renderTarget]); td.storageMode = .private
        let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: ow, height: oh, mipmapped: false)
        od.usage = scaler.outputTextureUsage.union([.shaderRead]); od.storageMode = .private
        guard let inTex = dev.makeTexture(descriptor: td), let outTex = dev.makeTexture(descriptor: od),
              let cb = RenderEngine.commandQueue.makeCommandBuffer() else { return nil }
        let src = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        RenderEngine.context.render(src, to: inTex, commandBuffer: cb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: sRGBSpace)
        scaler.colorTexture = inTex
        scaler.outputTexture = outTex
        scaler.inputContentWidth = w; scaler.inputContentHeight = h
        scaler.encode(commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        guard let out = CIImage(mtlTexture: outTex, options: [.colorSpace: sRGBSpace]) else { return nil }
        return out
    }
}

// MARK: - Resample methods

enum ResampleMethod: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case preserveDetails = "Preserve Details (enlargement)"
    case preserveDetails2 = "Preserve Details 2.0"
    case bicubicSmoother = "Bicubic Smoother (enlargement)"
    case bicubicSharper = "Bicubic Sharper (reduction)"
    case bicubic = "Bicubic (smooth gradients)"
    case bilinear = "Bilinear"
    case nearest = "Nearest Neighbor (hard edges)"
    var id: String { rawValue }
}

enum ImageResampler {
    /// Resamples `img` (extent at 0,0, size w×h) to `size`. Returns an image with extent (0,0,size).
    static func resample(_ img: CIImage, to size: CGSize, method: ResampleMethod, noise: Double = 0) -> CIImage {
        let ext = img.extent
        guard ext.width > 0, ext.height > 0, size.width > 0, size.height > 0 else { return img }
        let sx = size.width / ext.width, sy = size.height / ext.height
        let target = CGRect(origin: .zero, size: size)
        let src = img.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
        var m = method
        if m == .automatic { m = max(sx, sy) > 1 ? .preserveDetails : .bicubicSharper }
        if m == .preserveDetails2 { m = .preserveDetails }   // async upscalers are handled by the caller
        let out: CIImage
        switch m {
        case .nearest:
            out = src.clampedToExtent().samplingNearest().transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        case .bilinear:
            out = src.clampedToExtent().samplingLinear().transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        case .bicubic, .bicubicSmoother, .bicubicSharper:
            let (b, c): (Double, Double) = m == .bicubicSmoother ? (0.55, 0.3) : m == .bicubicSharper ? (0, 0.9) : (0, 0.5)
            out = src.clampedToExtent().applyingFilter("CIBicubicScaleTransform", parameters: [
                kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy, "inputB": b, "inputC": c])
        default:
            out = preserveDetails(src, sx: sx, sy: sy, noise: noise)
        }
        // (sources are clamped to their extent, so borders don't fade; transparency inside is resampled like colour)
        return out.cropped(to: target)
    }

    /// Preserve Details: optional noise reduction, Lanczos, then sharpening weighted by local edge strength
    /// (edges and textures get crisper while flat areas and noise are not amplified).
    static func preserveDetails(_ src: CIImage, sx: CGFloat, sy: CGFloat, noise: Double) -> CIImage {
        var s = src.clampedToExtent()
        if noise > 0 {
            s = s.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": noise / 100 * 0.06, "inputSharpness": 0.3])
        }
        let up = s.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
        let k = Double(max(sx, sy))
        guard k > 1.05, let kern = detailKernel else { return up }
        let radius = min(4, 0.6 * k)
        let blur = up.applyingGaussianBlur(sigma: radius)
        let wide = up.applyingGaussianBlur(sigma: radius * 2.5)
        let amount = min(1.0, 0.3 + 0.18 * k) * (1 - noise / 200)
        return kern.apply(extent: up.extent, arguments: [up, blur, wide, Float(amount)]) ?? up
    }

    static let detailKernel = CIColorKernel(source: """
    kernel vec4 editsDetail(__sample s, __sample b, __sample w, float amt) {
        vec3 c = s.rgb, bc = b.rgb, wc = w.rgb;
        vec3 wts = vec3(0.299, 0.587, 0.114);
        float detail = dot(c - bc, wts);
        float edge = abs(dot(bc - wc, wts));
        float g = smoothstep(0.004, 0.05, edge);
        float d = detail * amt * g;
        d = d / (1.0 + 4.0 * abs(d));
        return vec4(clamp(c + vec3(d) * s.a, vec3(0.0), vec3(s.a)), s.a);
    }
    """)

    /// Resamples a premultiplied buffer.
    static func resample(_ b: PixelBuffer, to size: (Int, Int), method: ResampleMethod, noise: Double) -> PixelBuffer {
        let img = resample(b.ciImage, to: CGSize(width: size.0, height: size.1), method: method, noise: noise)
        let sp = CanvasSpace(width: size.0, height: size.1)
        return RenderEngine.renderBuffer(img, docRect: IRect(x: 0, y: 0, width: size.0, height: size.1), space: sp, format: b.format)
    }

    /// Upscaler (Preserve Details 2.0) followed by an exact Lanczos fit.
    static func upscaled(_ b: PixelBuffer, to size: (Int, Int), upscaler: (CGImage, Double) async throws -> CGImage) async -> PixelBuffer? {
        let scale = max(Double(size.0) / Double(b.width), Double(size.1) / Double(b.height))
        let big: CGImage
        do { big = try await upscaler(b.makeCGImage(), scale) } catch {
            // the caller falls back to plain resampling: say why instead of silently giving a different result
            let why = error.localizedDescription
            await MainActor.run { AppModel.shared.setStatus("Upscaler unavailable, used standard resampling instead: \(why)") }
            return nil
        }
        let img = CIImage(cgImage: big)
        let fit = resample(img, to: CGSize(width: size.0, height: size.1), method: .bicubic)
        let sp = CanvasSpace(width: size.0, height: size.1)
        return RenderEngine.renderBuffer(fit, docRect: IRect(x: 0, y: 0, width: size.0, height: size.1), space: sp)
    }
}

// MARK: - Document operation

enum EditsImageSize {
    /// Image ▸ Image Size with a resample method. Non-raster content is transformed exactly (vector / smart objects),
    /// raster layers are resampled with `method`.
    static func apply(width: Int, height: Int, resolution: Double, scaleStyles: Bool, method: ResampleMethod, noise: Double = 0, upscaler: Int? = nil) {
        guard let d = AppActions.doc, width > 0, height > 0 else { return }
        let width = min(width, maxCanvasDimension), height = min(height, maxCanvasDimension)
        ActionRecorder.record(.imageSize(width: width, height: height, resolution: resolution, scaleStyles: scaleStyles))
        if method == .preserveDetails2, let ui = upscaler, UpscalerRegistry.upscalers.indices.contains(ui),
           width > d.state.width || height > d.state.height {
            let run = UpscalerRegistry.upscalers[ui].run
            AppModel.shared.setStatus("Upscaling with \(UpscalerRegistry.upscalers[ui].name)…")
            let state = d.state
            Task { @MainActor in
                var buffers: [UUID: PixelBuffer] = [:]
                for l in state.allLayers {
                    guard let r = l.raster else { continue }
                    let sx = Double(width) / Double(state.width), sy = Double(height) / Double(state.height)
                    let size = (max(1, Int((Double(r.buffer.width) * sx).rounded())), max(1, Int((Double(r.buffer.height) * sy).rounded())))
                    buffers[l.id] = await ImageResampler.upscaled(r.buffer, to: size, upscaler: run)
                }
                AppModel.shared.setStatus("")
                perform(d, width: width, height: height, resolution: resolution, scaleStyles: scaleStyles, method: .preserveDetails, noise: noise, precomputed: buffers)
            }
            return
        }
        perform(d, width: width, height: height, resolution: resolution, scaleStyles: scaleStyles, method: method, noise: noise, precomputed: [:])
    }

    static func perform(_ d: Document, width: Int, height: Int, resolution: Double, scaleStyles: Bool, method: ResampleMethod, noise: Double,
                        precomputed: [UUID: PixelBuffer]) {
        AppActions.canvas?.commitCurrentTool()
        var st = d.state
        let sx = Double(width) / Double(st.width), sy = Double(height) / Double(st.height)
        let h = Homography(affine: CGAffineTransform(scaleX: CGFloat(sx), y: CGFloat(sy)))
        let sp = CanvasSpace(width: st.width, height: st.height)
        let styles = scaleStyles ? sqrt(sx * sy) : nil
        func map(_ l: Layer) -> Layer {
            if case .group = l.content {
                var n = LayerTransformer.apply(h, to: l.withChildren([]), space: sp, scaleEffects: styles, document: true, strokeScale: sqrt(sx * sy))
                n.children = l.children.map(map)
                return n
            }
            var n = LayerTransformer.apply(h, to: l.rasterStripped, space: sp, scaleEffects: styles, nearest: method == .nearest, document: true, strokeScale: sqrt(sx * sy))
            if let r = l.raster {
                let size = (max(1, Int((Double(r.buffer.width) * sx).rounded())), max(1, Int((Double(r.buffer.height) * sy).rounded())))
                let b = precomputed[l.id] ?? ImageResampler.resample(r.buffer, to: size, method: method, noise: noise)
                n.content = .raster(RasterContent(buffer: b, origin: IPoint(x: Int((Double(r.origin.x) * sx).rounded()), y: Int((Double(r.origin.y) * sy).rounded()))))
            }
            return n
        }
        st.layers = st.layers.map(map)
        AppActions.syncStoredGeometry(from: d.state, to: &st, h: h)   // frames, comps, keyframes, slices … follow the document
        func scaleMask(_ b: PixelBuffer) -> PixelBuffer {
            let img = LayerTransformer.warp(b.ciImage, docRect: b.bounds, h: h, space: sp, nearest: method == .nearest)
            let docR = IRect(enclosing: sp.docRect(img.extent))
            let buf = RenderEngine.renderBuffer(img, docRect: docR, space: sp, format: .gray)
            let out = PixelBuffer(width: width, height: height, format: .gray)
            out.copyPixels(from: buf, at: docR.origin)
            out.markDirty()
            return out
        }
        if let sel = st.selection { st.selection = scaleMask(sel) }
        st.alphaChannels = st.alphaChannels.map { var c = $0; c.buffer = scaleMask(c.buffer); return c }
        st.paths = st.paths.map { var p = $0; p.path = p.path.mapped(h.apply); return p }
        st.guides = st.guides.map { g in var n = g; n.position *= g.isVertical ? sx : sy; return n }
        st.toolData = st.toolData.mapped(h.apply)
        st.width = width
        st.height = height
        st.resolution = validResolution(resolution)
        d.state = st
        d.commit("Image Size")
        Compositor.shared.clearCaches()
        d.needsFitOnScreen = true
        AppActions.canvas?.fitOnScreen()
    }
}

private extension Layer {
    /// Copy without raster pixels (they are resampled separately); keeps masks / effects for LayerTransformer.
    var rasterStripped: Layer {
        guard case .raster(var r) = content else { return self }
        var l = self
        r.buffer = PixelBuffer(width: 1, height: 1)
        l.content = .raster(r)
        return l
    }
    func withChildren(_ c: [Layer]) -> Layer { var l = self; l.children = c; return l }
}

// MARK: - Dialog

struct ImageSizeProDialog: View {
    @State private var width: Double = 0
    @State private var height: Double = 0
    @State private var res: Double = 72
    @State private var constrain = true
    @State private var percent = false
    @State private var scaleStyles = true
    @State private var resample = true
    @State private var method: ResampleMethod = .automatic
    @State private var noise: Double = 0
    @State private var upscaler = 0
    @State private var ratio: Double = 1
    @State private var ow: Double = 1
    @State private var oh: Double = 1
    @State private var preview: CGImage?

    var body: some View {
        DialogFrame(title: "Image Size", width: 380, onOK: apply) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Color.black
                    if let p = preview { Image(decorative: p, scale: 1).interpolation(.none) }
                }
                .frame(width: 150, height: 150).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .help("Centre of the image at the new size (100%)")
                VStack(alignment: .leading, spacing: 6) {
                    if let d = AppActions.doc {
                        Text("Current: \(d.state.width) × \(d.state.height) px").font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                    }
                    Text("New: \(Int(newW.rounded())) × \(Int(newH.rounded())) px").font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                    Picker("", selection: $percent) { Text("Pixels").tag(false); Text("Percent").tag(true) }.pickerStyle(.segmented).labelsHidden()
                        .onChange(of: percent) { _, p in
                            if p { width = width / ow * 100; height = height / oh * 100 } else { width = (width / 100 * ow).rounded(); height = (height / 100 * oh).rounded() }
                        }
                    HStack {
                        NumberField(label: "Width", value: Binding(get: { width }, set: { v in width = v; if constrain { height = percent ? v : (v / ratio).rounded() }; refresh() }), width: 64)
                        Text(percent ? "%" : "px").foregroundStyle(Theme.textFaint)
                    }
                    HStack {
                        NumberField(label: "Height", value: Binding(get: { height }, set: { v in height = v; if constrain { width = percent ? v : (v * ratio).rounded() }; refresh() }), width: 64)
                        Text(percent ? "%" : "px").foregroundStyle(Theme.textFaint)
                    }
                    Toggle2(label: "Constrain Proportions", on: $constrain)
                }
            }
            HStack { NumberField(label: "Resolution", value: $res, width: 50); Text("ppi").foregroundStyle(Theme.textFaint) }
            Toggle2(label: "Scale Styles", on: $scaleStyles)
            Toggle2(label: "Resample", on: $resample)
            if resample {
                Picker("Resample", selection: $method) { ForEach(ResampleMethod.allCases) { Text($0.rawValue).tag($0) } }
                    .onChange(of: method) { _, _ in refresh() }
                if method == .preserveDetails || method == .preserveDetails2 || (method == .automatic && newW > ow) {
                    ValueSlider(label: "Reduce Noise", value: $noise, range: 0...100, unit: "%", labelWidth: 86, onCommit: refresh)
                }
                if method == .preserveDetails2 {
                    if UpscalerRegistry.upscalers.isEmpty {
                        Text("No upscaler registered — uses Preserve Details.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                    } else {
                        Picker("Upscaler", selection: $upscaler) {
                            ForEach(Array(UpscalerRegistry.upscalers.enumerated()), id: \.offset) { i, u in Text(u.name).tag(i) }
                        }
                        Text("Used when enlarging; reductions use Preserve Details.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                    }
                }
            } else {
                Text("Without resampling, only the resolution (print size) changes.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
        }
        .onAppear {
            guard let d = AppActions.doc else { return }
            ow = Double(d.state.width); oh = Double(d.state.height)
            width = ow; height = oh; res = d.state.resolution; ratio = ow / oh
            refresh()
        }
    }

    var newW: Double { percent ? ow * width / 100 : width }
    var newH: Double { percent ? oh * height / 100 : height }

    func refresh() {
        guard let d = AppActions.doc, ow > 0, oh > 0 else { return }
        let sp = AppActions.space(d)
        let sx = newW / ow, sy = newH / oh
        guard sx > 0, sy > 0 else { return }
        // centre crop of the source covering 150 px at the new size
        let cw = min(ow, 150 / sx + 4), ch = min(oh, 150 / sy + 4)
        let r = CGRect(x: (ow - cw) / 2, y: (oh - ch) / 2, width: cw, height: ch).integral
        let comp = Compositor.shared.composite(d.committedState).cropped(to: sp.ciRect(r))
        let crop = comp.transformed(by: CGAffineTransform(translationX: -comp.extent.minX, y: -comp.extent.minY))
        let size = CGSize(width: max(1, (crop.extent.width * sx).rounded()), height: max(1, (crop.extent.height * sy).rounded()))
        let out = ImageResampler.resample(crop, to: size, method: resample ? method : .bicubic, noise: noise)
        preview = RenderEngine.cgImage(out, rect: out.extent)
    }

    func apply() {
        guard newW.isFinite, newH.isFinite else { return }
        let w = Int(clamp(newW.rounded(), 1, Double(maxCanvasDimension))), h = Int(clamp(newH.rounded(), 1, Double(maxCanvasDimension)))
        if !resample {
            AppActions.doc?.state.resolution = validResolution(res)
            AppActions.doc?.commit("Image Size")
            return
        }
        EditsImageSize.apply(width: w, height: h, resolution: res, scaleStyles: scaleStyles, method: method, noise: noise,
                             upscaler: UpscalerRegistry.upscalers.isEmpty ? nil : upscaler)
    }
}
