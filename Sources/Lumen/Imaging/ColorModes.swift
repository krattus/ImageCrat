import AppKit
import CoreImage
import ImageCratCore

enum BitmapMethod: String, CaseIterable, Identifiable {
    case threshold = "50% Threshold", pattern = "Pattern Dither", diffusion = "Diffusion Dither", halftone = "Halftone Screen", custom = "Custom Pattern"
    var id: String { rawValue }
}

enum HalftoneShape: String, CaseIterable, Identifiable {
    case round = "Round", ellipse = "Ellipse", line = "Line", square = "Square", cross = "Cross", diamond = "Diamond"
    var id: String { rawValue }
}

struct BitmapOptions: Equatable {
    var outputResolution: Double = 72
    var method: BitmapMethod = .diffusion
    var frequency: Double = 53         // lines per inch
    var angle: Double = 45             // degrees
    var shape: HalftoneShape = .round
    var patternID: String = "hex"
}

/// Bitmap / Indexed / Duotone / Multichannel conversions (Image ▸ Mode).
enum ColorModes {
    static var extraModes: Set<ColorMode> { [.bitmap, .duotone, .indexed, .multichannel] }

    /// Called first by `AppActions.convertMode`. Returns true when the request was fully handled here.
    static func intercept(_ m: ColorMode) -> Bool {
        guard let d = AppActions.doc else { return false }
        let cur = d.state.colorMode
        if extraModes.contains(m) {
            switch m {
            case .bitmap: DialogRegistry.show("imaging.bitmap")
            case .indexed: DialogRegistry.show("imaging.indexed")
            case .duotone: DialogRegistry.show("imaging.duotone")
            default: if cur != .multichannel { convertToMultichannel(d) }
            }
            return true
        }
        guard extraModes.contains(cur) else { return false }
        // Leaving an extra mode: bake its appearance into ordinary pixels first.
        var st = d.state
        leave(&st)
        if m == .grayscale {
            grayLayers(&st)
            st.colorMode = .grayscale
            d.state = st
            d.commit("Grayscale")
            Compositor.shared.clearCaches(); d.setNeedsRender()
            return true
        }
        st.colorMode = .rgb
        d.state = st
        if m == .rgb {
            d.commit("RGB Color")
            Compositor.shared.clearCaches(); d.setNeedsRender()
            return true
        }
        return false   // continue with the ordinary RGB → CMYK / Lab path
    }

    /// Converts the state to plain RGB pixels (keeps spot channels unless leaving Multichannel).
    static func leave(_ st: inout DocumentState) {
        switch st.colorMode {
        case .duotone:
            if let duo = st.imaging?.duotone {
                AppActions.mapAllRasters(&st) { buf in
                    let img = ImagingDisplay.duotone(buf.ciImage, duo)
                    return RenderEngine.renderBuffer(img, docRect: IRect(x: 0, y: 0, width: buf.width, height: buf.height), space: CanvasSpace(width: buf.width, height: buf.height))
                }
            }
            st.imaging?.duotone = nil
        case .indexed:
            st.imaging?.colorTable = nil
            st.imaging?.transparentIndex = nil
        case .multichannel:
            let img = ImagingDisplay.inks(Compositor.shared.composite(st), state: st)
            let sp = CanvasSpace(width: st.width, height: st.height)
            let buf = RenderEngine.renderBuffer(img.cropped(to: sp.ciCanvas), docRect: st.canvasRect, space: sp)
            var bg = Layer.raster(name: "Background", buffer: buf)
            bg.locks.position = false
            st.layers = [bg]
            let spotIDs = Set(st.imaging?.spots.map(\.id) ?? [])
            st.alphaChannels.removeAll { spotIDs.contains($0.id) }
            st.imaging?.spots = []
        default: break
        }
    }

    // MARK: Helpers

    /// Flattened composite over `matte` (or keeping transparency) as a canvas-size buffer.
    static func flattened(_ st: DocumentState, over matte: RGBA? = .white, withInks: Bool = true) -> PixelBuffer {
        let sp = CanvasSpace(width: st.width, height: st.height)
        var img = Compositor.shared.composite(st)
        if withInks { img = ImagingDisplay.inks(img, state: st) }
        if let m = matte { img = img.composited(over: CIImage.color(m, sp.ciCanvas)) }
        return RenderEngine.renderBuffer(img.cropped(to: sp.ciCanvas), docRect: st.canvasRect, space: sp)
    }

    /// Desaturates every raster layer (luminosity) in place.
    static func grayLayers(_ st: inout DocumentState) {
        AppActions.mapAllRasters(&st) { buf in
            let sp = CanvasSpace(width: buf.width, height: buf.height)
            let img = AdjustmentEngine.apply(AdjustmentSettings(kind: .desaturate), to: buf.ciImage)
            return RenderEngine.renderBuffer(img, docRect: IRect(x: 0, y: 0, width: buf.width, height: buf.height), space: sp)
        }
    }

    static func singleLayer(_ st: inout DocumentState, _ buf: PixelBuffer, name: String) {
        var l = Layer.raster(name: name, buffer: buf)
        l.locks.position = false
        st.layers = [l]
    }

    static func finish(_ d: Document, _ st: DocumentState, _ name: String) {
        d.state = st
        d.activeLayerID = st.layers.last?.id
        d.selectedLayerIDs = Set([st.layers.last?.id].compactMap { $0 })
        d.commit(name)
        Compositor.shared.clearCaches()
        d.needsFitOnScreen = true
        d.setNeedsRender()
    }

    // MARK: Bitmap

    static func bitmap(_ st0: DocumentState, _ o: BitmapOptions) -> DocumentState {
        var st = st0
        let gray = flattened(st, over: .white)
        let scale = max(0.01, o.outputResolution / max(1, st.resolution))
        let W = min(maxCanvasDimension, max(1, Int((Double(st.width) * scale).rounded()))), H = min(maxCanvasDimension, max(1, Int((Double(st.height) * scale).rounded())))
        var img = AdjustmentEngine.apply(AdjustmentSettings(kind: .desaturate), to: gray.ciImage)
        if abs(scale - 1) > 0.001 {
            img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: Double(W) / Double(H) / (Double(st.width) / Double(st.height))])
        }
        let rect = CGRect(x: 0, y: 0, width: W, height: H)
        img = img.clampedToExtent().cropped(to: rect)
        let out: PixelBuffer
        switch o.method {
        case .diffusion:
            let g = PixelBuffer(width: W, height: H)
            RenderEngine.readbackContext.render(img, toBitmap: g.data, rowBytes: g.bytesPerRow, bounds: rect, format: .RGBA8, colorSpace: sRGBSpace)
            out = floydSteinbergBW(g)
        default:
            let tile: CIImage
            var cell = 8.0, angle = 0.0
            switch o.method {
            case .threshold: tile = CIImage.color(RGBA(gray: 0.5), CGRect(x: 0, y: 0, width: 1, height: 1)); cell = 1
            case .pattern: tile = bayerTile(); cell = 8
            case .halftone:
                tile = spotTile(o.shape)
                cell = max(1, o.outputResolution / max(1, o.frequency))
                angle = o.angle
            default:
                let pat = PatternLibrary.pattern(id: o.patternID, custom: AppModel.shared.customPatterns) ?? PatternDef.builtIn[0]
                tile = rankTile(pat.image)
                cell = Double(pat.image.width)
            }
            let screened = screen(img, tile: tile, cell: cell, angle: angle)
            out = RenderEngine.renderBuffer(screened.cropped(to: rect), docRect: IRect(x: 0, y: 0, width: W, height: H), space: CanvasSpace(width: W, height: H))
        }
        st = resized(st, width: W, height: H)
        singleLayer(&st, out, name: "Bitmap")
        st.resolution = o.outputResolution
        st.colorMode = .bitmap
        var data = st.imagingData
        data.colorTable = nil; data.duotone = nil
        st.imaging = data
        return st
    }

    /// Canvas resize helper for mode conversions that change resolution (alpha channels are resampled).
    static func resized(_ st0: DocumentState, width W: Int, height H: Int) -> DocumentState {
        guard W != st0.width || H != st0.height else { return st0 }
        var st = st0
        st.alphaChannels = st.alphaChannels.map { ch in
            var c = ch
            let img = ch.buffer.ciImage.transformed(by: CGAffineTransform(scaleX: CGFloat(W) / CGFloat(st0.width), y: CGFloat(H) / CGFloat(st0.height)))
            c.buffer = RenderEngine.renderBuffer(img, docRect: IRect(x: 0, y: 0, width: W, height: H), space: CanvasSpace(width: W, height: H), format: .gray)
            return c
        }
        st.width = W; st.height = H
        st.selection = nil
        st.guides = []
        return st
    }

    static let screenKernel = CIKernel(source: """
    kernel vec4 lumenScreen(sampler img, sampler tile, vec4 p) {
        vec2 d = destCoord();
        vec4 s = sample(img, samplerCoord(img));
        float g = s.a > 0.0 ? dot(s.rgb / s.a, vec3(0.299, 0.587, 0.114)) : 1.0;
        float u = (d.x * p.y + d.y * p.z) / p.x;
        float v = (-d.x * p.z + d.y * p.y) / p.x;
        vec2 f = vec2(u - floor(u), v - floor(v)) * p.w;
        vec2 tc = floor(f) + vec2(0.5);
        float t = sample(tile, samplerTransform(tile, tc)).r;
        float o = g < t ? 0.0 : 1.0;
        return vec4(o, o, o, 1.0);
    }
    """)

    /// Threshold-array screening: pixel is black where gray < tile threshold. The tile repeats every `cell` px at `angle`.
    static func screen(_ img: CIImage, tile: CIImage, cell: Double, angle: Double) -> CIImage {
        let t = tile.samplingNearest()
        let tw = t.extent.width
        let a = angle * .pi / 180
        guard let k = screenKernel else { return img }
        let e = img.extent
        return k.apply(extent: e, roiCallback: { i, r in i == 0 ? r : t.extent }, arguments: [img, t, CIVector(x: CGFloat(cell), y: CGFloat(cos(a)), z: CGFloat(sin(a)), w: tw)]) ?? img
    }

    static func bayerTile() -> CIImage {
        var v = [Float](repeating: 0, count: 64)
        for y in 0..<8 { for x in 0..<8 {
            var m = 0
            for i in 0..<3 { let xb = (x >> i) & 1, yb = (y >> i) & 1; m += (2 * (xb ^ yb) + yb) << (2 * (2 - i)) }
            v[y * 8 + x] = (Float(m) + 0.5) / 64
        } }
        return grayTile(v, 8)
    }

    /// Threshold tile from a halftone spot function: pixels are ranked by the spot value so dot area tracks tone.
    static func spotTile(_ shape: HalftoneShape, size n: Int = 48) -> CIImage {
        var vals: [(Double, Int)] = []
        for y in 0..<n { for x in 0..<n {
            let u = (Double(x) + 0.5) / Double(n) * 2 - 1, v = (Double(y) + 0.5) / Double(n) * 2 - 1
            let s: Double
            switch shape {
            case .round: s = 1 - (u * u + v * v)
            case .ellipse: s = 1 - (u * u + v * v * 1.8)
            case .line: s = 1 - abs(v)
            case .square: s = 1 - max(abs(u), abs(v))
            case .cross: s = 1 - min(abs(u), abs(v))
            case .diamond: s = 1 - (abs(u) + abs(v))
            }
            vals.append((s, y * n + x))
        } }
        // A pixel is black when gray < threshold, so the highest spot values get the highest thresholds (dots grow from the centre).
        let sorted = vals.sorted { $0.0 < $1.0 }
        var t = [Float](repeating: 0, count: n * n)
        for (r, e) in sorted.enumerated() { t[e.1] = (Float(r) + 0.5) / Float(n * n) }
        return grayTile(t, n)
    }

    /// Custom Pattern: the pattern's luminance, rank-equalised so it works as a dither threshold array.
    static func rankTile(_ pat: PixelBuffer) -> CIImage {
        let n = min(pat.width, pat.height)
        var vals: [(Double, Int)] = []
        for y in 0..<n { for x in 0..<n {
            let p = pat.pixel(x, y)
            vals.append((0.299 * Double(p.0) + 0.587 * Double(p.1) + 0.114 * Double(p.2) + Double((x * 7 + y * 13) % 17) * 0.001, y * n + x))
        } }
        var t = [Float](repeating: 0.5, count: n * n)
        for (r, e) in vals.sorted(by: { $0.0 < $1.0 }).enumerated() { t[e.1] = (Float(r) + 0.5) / Float(n * n) }
        return grayTile(t, n)
    }

    static func grayTile(_ v: [Float], _ n: Int) -> CIImage {
        var rgba = [Float](repeating: 1, count: n * n * 4)
        for i in 0..<(n * n) { rgba[i * 4] = v[i]; rgba[i * 4 + 1] = v[i]; rgba[i * 4 + 2] = v[i] }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        // first row = top of the tile
        return CIImage(bitmapData: data, bytesPerRow: n * 16, size: CGSize(width: n, height: n), format: .RGBAf, colorSpace: nil)
    }

    static func floydSteinbergBW(_ g: PixelBuffer) -> PixelBuffer {
        let w = g.width, h = g.height
        let out = PixelBuffer(width: w, height: h)
        var cur = [Float](repeating: 0, count: w + 2), nxt = [Float](repeating: 0, count: w + 2)
        let src = g.data.assumingMemoryBound(to: UInt8.self)
        let dst = out.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let sr = src + y * g.bytesPerRow, dr = dst + y * out.bytesPerRow
            for i in 0..<(w + 2) { nxt[i] = 0 }
            let serp = y & 1 == 1
            for k in 0..<w {
                let x = serp ? w - 1 - k : k
                let v = Float(sr[x * 4]) + cur[x + 1]
                let o: Float = v < 128 ? 0 : 255
                let e = v - o
                let b = UInt8(o)
                dr[x * 4] = b; dr[x * 4 + 1] = b; dr[x * 4 + 2] = b; dr[x * 4 + 3] = 255
                if serp {
                    cur[x] += e * 7 / 16; nxt[x + 2] += e * 3 / 16; nxt[x + 1] += e * 5 / 16; nxt[x] += e / 16
                } else {
                    cur[x + 2] += e * 7 / 16; nxt[x] += e * 3 / 16; nxt[x + 1] += e * 5 / 16; nxt[x + 2] += e / 16
                }
            }
            swap(&cur, &nxt)
        }
        out.markDirty()
        return out
    }

    static func convertToBitmap(_ d: Document, _ o: BitmapOptions) {
        finish(d, bitmap(d.state, o), "Bitmap")
    }

    // MARK: Indexed

    static func indexed(_ st0: DocumentState, _ o: IndexedOptions) -> DocumentState {
        var st = st0
        if st.colorMode == .duotone || st.colorMode == .multichannel { leave(&st) }
        let flat = flattened(st, over: nil)
        let (pal, ti) = Quantizer.palette(for: flat, options: o)
        let idx = Quantizer.indices(flat, palette: pal, transparentIndex: ti, dither: o.dither, amount: o.amount, preserveExact: o.preserveExact, matte: o.matte)
        let buf = Quantizer.render(indices: idx, width: flat.width, height: flat.height, palette: pal, transparentIndex: ti)
        singleLayer(&st, buf, name: "Index")
        st.colorMode = .indexed
        var data = st.imagingData
        data.colorTable = pal
        data.transparentIndex = ti
        data.duotone = nil
        st.imaging = data
        return st
    }

    static func convertToIndexed(_ d: Document, _ o: IndexedOptions) {
        finish(d, indexed(d.state, o), "Indexed Color")
    }

    /// Replaces colour table entries: every pixel of an old entry takes the new colour (Color Table editor).
    static func applyColorTable(_ d: Document, _ table: [RGBA], transparentIndex: Int?) {
        guard let old = d.state.imaging?.colorTable, let l = d.state.layers.last, let r = l.raster else { return }
        let oldTi = d.state.imaging?.transparentIndex
        let idx = Quantizer.indices(r.buffer, palette: old, transparentIndex: oldTi, dither: .none, amount: 0, preserveExact: true, matte: .white)
        let buf = Quantizer.render(indices: idx, width: r.buffer.width, height: r.buffer.height, palette: table, transparentIndex: transparentIndex)
        var st = d.state
        st.updateLayer(l.id) { $0.raster = RasterContent(buffer: buf, origin: r.origin) }
        var data = st.imagingData
        data.colorTable = table
        data.transparentIndex = transparentIndex
        st.imaging = data
        d.state = st
        d.commit("Color Table")
    }

    // MARK: Duotone

    static func duotone(_ st0: DocumentState, _ s: DuotoneSettings) -> DocumentState {
        var st = st0
        if st.colorMode != .duotone {
            if st.colorMode == .indexed || st.colorMode == .multichannel || st.colorMode == .bitmap { leave(&st) }
            grayLayers(&st)
        }
        st.colorMode = .duotone
        var data = st.imagingData
        data.duotone = s
        data.colorTable = nil
        st.imaging = data
        return st
    }

    static func convertToDuotone(_ d: Document, _ s: DuotoneSettings) {
        let was = d.state.colorMode
        let st = duotone(d.state, s)
        d.state = st
        d.commit(was == .duotone ? "Duotone Options" : s.type.name)
        Compositor.shared.clearCaches()
        d.setNeedsRender()
    }

    // MARK: Multichannel

    static let inkKernel = CIColorKernel(source: """
    kernel vec4 lumenInkSplit(__sample s, vec4 w) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(1.0);
        float v = w.x < 0.5 ? 1.0 - c.r : (w.x < 1.5 ? 1.0 - c.g : (w.x < 2.5 ? 1.0 - c.b : 0.0));
        return vec4(v, v, v, 1.0);
    }
    """)

    static func multichannel(_ st0: DocumentState) -> DocumentState {
        var st = st0
        let sp = CanvasSpace(width: st.width, height: st.height)
        let flat = Compositor.shared.composite(st).composited(over: CIImage.color(.white, sp.ciCanvas)).cropped(to: sp.ciCanvas)
        var channels: [(String, RGBA, CIImage)] = []
        switch st.colorMode {
        case .cmyk:
            let names = ["Cyan", "Magenta", "Yellow", "Black"]
            let inks = [RGBA(r: 0, g: 0.68, b: 0.94), RGBA(r: 0.93, g: 0, b: 0.55), RGBA(r: 1, g: 0.95, b: 0), RGBA.black]
            for i in 0..<4 {
                if let img = ColorConvert.cmykChannelKernel?.apply(extent: sp.ciCanvas, arguments: [flat, Float(i)]) {
                    channels.append((names[i], inks[i], img.inverted()))
                }
            }
        case .grayscale, .bitmap:
            channels.append(("Black", .black, AdjustmentEngine.apply(AdjustmentSettings(kind: .desaturate), to: flat).inverted()))
        case .duotone:
            let gray = AdjustmentEngine.apply(AdjustmentSettings(kind: .desaturate), to: flat)
            for ink in st.imaging?.duotone?.inks ?? [] {
                let lut = ink.curve.lut(256)
                var floats = [Float](repeating: 0, count: 256 * 3)
                for i in 0..<256 { let v = Float(lut[255 - i]); floats[i * 3] = v; floats[i * 3 + 1] = v; floats[i * 3 + 2] = v }
                let cov = gray.applyingFilter("CIColorCurves", parameters: ["inputCurvesData": floats.withUnsafeBufferPointer { Data(buffer: $0) },
                                                                            "inputCurvesDomain": CIVector(x: 0, y: 1), "inputColorSpace": sRGBSpace])
                channels.append((ink.name, ink.color, cov))
            }
        default:
            let names = ["Cyan", "Magenta", "Yellow"]
            let inks = [RGBA(r: 0, g: 1, b: 1), RGBA(r: 1, g: 0, b: 1), RGBA(r: 1, g: 1, b: 0)]
            for i in 0..<3 {
                if let img = inkKernel?.apply(extent: sp.ciCanvas, arguments: [flat, CIVector(x: CGFloat(i), y: 0, z: 0, w: 0)]) {
                    channels.append((names[i], inks[i], img))
                }
            }
        }
        var data = st.imagingData
        let oldSpots = Set(data.spots.map(\.id))
        let keep = st.alphaChannels.filter { oldSpots.contains($0.id) }
        st.alphaChannels.removeAll { oldSpots.contains($0.id) }
        var newSpots: [SpotInfo] = []
        var newChannels: [AlphaChannel] = []
        for (name, ink, img) in channels {
            let buf = RenderEngine.renderBuffer(img, docRect: st.canvasRect, space: sp, format: .gray)
            let ch = AlphaChannel(name: name, buffer: buf)
            newChannels.append(ch)
            newSpots.append(SpotInfo(id: ch.id, ink: ink, solidity: 0))
        }
        // existing spot channels stay after the process inks
        st.alphaChannels = newChannels + keep + st.alphaChannels
        data.spots = newSpots + data.spots
        data.colorTable = nil; data.duotone = nil; data.transparentIndex = nil
        st.imaging = data
        let white = PixelBuffer(width: st.width, height: st.height)
        white.context.setFillColor(RGBA.white.cgColor); white.context.fill(CGRect(x: 0, y: 0, width: st.width, height: st.height)); white.markDirty()
        singleLayer(&st, white, name: "Background")
        st.colorMode = .multichannel
        return st
    }

    static func convertToMultichannel(_ d: Document) {
        finish(d, multichannel(d.state), "Multichannel")
    }

    // MARK: Spot channels

    static func addSpotChannel(_ d: Document, name: String, ink: RGBA, solidity: Double) {
        var st = d.state
        let buf = st.selection?.copy() ?? PixelBuffer(width: st.width, height: st.height, gray: 0)
        let ch = AlphaChannel(name: name, buffer: buf)
        st.alphaChannels.append(ch)
        var data = st.imagingData
        data.spots.append(SpotInfo(id: ch.id, ink: ink, solidity: solidity))
        st.imaging = data
        st.selection = nil
        d.state = st
        d.commit("New Spot Channel")
    }

    static func updateSpot(_ d: Document, _ info: SpotInfo, name: String? = nil, commit: Bool = true) {
        var st = d.state
        var data = st.imagingData
        if let i = data.spots.firstIndex(where: { $0.id == info.id }) { data.spots[i] = info }
        st.imaging = data
        if let name, let i = st.alphaChannels.firstIndex(where: { $0.id == info.id }) { st.alphaChannels[i].name = name }
        d.state = st
        if commit { d.commit("Spot Channel Options") }
    }

    static func deleteSpot(_ d: Document, _ id: UUID) {
        var st = d.state
        st.alphaChannels.removeAll { $0.id == id }
        st.imaging?.spots.removeAll { $0.id == id }
        d.state = st
        if case .alpha(let v) = d.viewChannel, v == id { d.viewChannel = .composite }
        d.commit("Delete Channel")
    }

    /// Merges a spot channel into the layer pixels (Merge Spot Channel).
    static func mergeSpot(_ d: Document, _ id: UUID) {
        guard let info = d.state.spotInfo(id), let ch = d.state.alphaChannels.first(where: { $0.id == id }) else { return }
        var st = d.state
        let sp = CanvasSpace(width: st.width, height: st.height)
        let img = ImagingDisplay.overlay(Compositor.shared.composite(st), coverage: ch.buffer.ciImage, info: info, rect: sp.ciCanvas)
        let buf = RenderEngine.renderBuffer(img.cropped(to: sp.ciCanvas), docRect: st.canvasRect, space: sp)
        singleLayer(&st, buf, name: "Background")
        st.alphaChannels.removeAll { $0.id == id }
        st.imaging?.spots.removeAll { $0.id == id }
        d.state = st
        d.commit("Merge Spot Channel")
    }
}

// MARK: - Display / export appearance

enum ImagingDisplay {
    static let spotKernel = CIColorKernel(source: """
    kernel vec4 lumenSpotInk(__sample base, __sample cov, vec4 ink, float solidity) {
        float c = clamp(cov.r, 0.0, 1.0);
        vec3 b = base.a > 0.0 ? base.rgb / base.a : vec3(1.0);
        vec3 inked = mix(b * ink.rgb, ink.rgb, solidity);
        vec3 o = mix(b, inked, c);
        float a = base.a + c * (1.0 - base.a);
        return vec4(o * a, a);
    }
    """)

    static func overlay(_ img: CIImage, coverage: CIImage, info: SpotInfo, rect: CGRect) -> CIImage {
        guard let k = spotKernel else { return img }
        let base = img.composited(over: CIImage.clearImage.cropped(to: rect))
        return k.apply(extent: rect, arguments: [base, coverage.composited(over: CIImage.color(.black, rect)),
                                                CIVector(x: CGFloat(info.ink.r), y: CGFloat(info.ink.g), z: CGFloat(info.ink.b), w: 1), Float(info.solidity)]) ?? img
    }

    /// Duotone and spot-ink appearance of a document composite (used for display and export).
    static func inks(_ img: CIImage, state st: DocumentState) -> CIImage {
        guard let data = st.imaging else { return img }
        var out = img
        if st.colorMode == .duotone, let duo = data.duotone { out = duotone(out, duo) }
        let spots = st.spotChannels
        if !spots.isEmpty {
            let rect = CGRect(x: 0, y: 0, width: st.width, height: st.height)
            for (ch, info) in spots where info.visible {
                out = overlay(out, coverage: ch.buffer.ciImage, info: info, rect: rect)
            }
        }
        return out
    }

    /// Canvas hook (CanvasRenderer.applyViewMode).
    static func apply(_ img: CIImage, doc: Document) -> CIImage { inks(img, state: doc.state) }

    private static var cubeCache: (DuotoneSettings, Data)?

    static func duotone(_ img: CIImage, _ s: DuotoneSettings) -> CIImage {
        let n = 32
        let data: Data
        if let c = cubeCache, c.0 == s { data = c.1 } else {
            let luts = s.inks.map { $0.curve.lut(256).map { clamp($0, 0, 1) } }
            var cube = [Float](repeating: 1, count: n * n * n * 4)
            for b in 0..<n { for g in 0..<n { for r in 0..<n {
                let gray = 0.299 * Double(r) / Double(n - 1) + 0.587 * Double(g) / Double(n - 1) + 0.114 * Double(b) / Double(n - 1)
                let c = s.color(forGray: gray, luts: luts)
                let i = ((b * n + g) * n + r) * 4
                cube[i] = Float(c.0); cube[i + 1] = Float(c.1); cube[i + 2] = Float(c.2); cube[i + 3] = 1
            } } }
            data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
            cubeCache = (s, data)
        }
        return img.unpremultiplyingAlpha()
            .applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": n, "inputCubeData": data, "inputColorSpace": sRGBSpace])
            .premultiplyingAlpha()
    }
}
