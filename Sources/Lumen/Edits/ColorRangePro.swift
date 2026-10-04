import SwiftUI
import Vision
import CoreImage
import ImageCratCore

/// Select ▸ Color Range with Photoshop's "Select" modes: sampled colours, colour families, tonal ranges, skin tones
/// (optionally guided by detected faces) and out-of-gamut colours.
enum ColorRangeMode: String, CaseIterable, Identifiable {
    case sampled = "Sampled Colors"
    case reds = "Reds", yellows = "Yellows", greens = "Greens", cyans = "Cyans", blues = "Blues", magentas = "Magentas"
    case highlights = "Highlights", midtones = "Midtones", shadows = "Shadows"
    case skinTones = "Skin Tones"
    case outOfGamut = "Out of Gamut"
    var id: String { rawValue }

    var isTonal: Bool { self == .highlights || self == .midtones || self == .shadows }
    var hueIndex: Int? { [.reds, .yellows, .greens, .cyans, .blues, .magentas].firstIndex(of: self) }
    var usesFuzziness: Bool { self == .sampled || isTonal || self == .skinTones }

    /// Photoshop's defaults: (fuzziness %, range low, range high) in 0…255.
    var toneDefaults: (Double, Double, Double) {
        switch self {
        case .highlights: return (20, 190, 255)
        case .shadows: return (20, 0, 65)
        case .midtones: return (20, 105, 150)
        default: return (40, 0, 255)
        }
    }
}

struct ColorRangeOptions: Equatable {
    var mode: ColorRangeMode = .sampled
    var color: RGBA = .white
    var fuzziness: Double = 40        // sampled / skin: 0…200; tones: 0…100 %
    var rangeLow: Double = 0          // tones, 0…255
    var rangeHigh: Double = 255
    var detectFaces = false
    var invert = false
}

enum ColorRangeEngine {
    @inline(__always) static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clamp((x - a) / max(1e-9, b - a), 0, 1)
        return t * t * (3 - 2 * t)
    }

    /// YCbCr (0…255) of 8-bit RGB.
    @inline(__always) static func ycc(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        (0.299 * r + 0.587 * g + 0.114 * b, 128 - 0.168736 * r - 0.331264 * g + 0.5 * b, 128 + 0.5 * r - 0.418688 * g - 0.081312 * b)
    }

    /// Skin-colour model: an ellipse in CbCr (mean, radii).
    struct SkinModel { var cb = 102.0, cr = 153.0, rcb = 25.0, rcr = 20.0 }

    static func skinWeight(_ r: Double, _ g: Double, _ b: Double, model m: SkinModel, fuzz: Double) -> Double {
        let (y, cb, cr) = ycc(r, g, b)
        let d = sqrt(pow((cb - m.cb) / m.rcb, 2) + pow((cr - m.cr) / m.rcr, 2))
        let f = 0.08 + fuzz / 200 * 0.7
        var w = 1 - smooth(1 - f, 1 + f, d)
        w *= smooth(25, 60, y) * (1 - smooth(245, 255, y) * 0.8)
        return w
    }

    /// Adaptive skin model from pixels inside detected faces (doc rects).
    static func skinModel(src: PixelBuffer, faces: [CGRect]) -> SkinModel {
        var n = 0.0, scb = 0.0, scr = 0.0, scb2 = 0.0, scr2 = 0.0
        let generic = SkinModel()
        for f in faces {
            let c = CGPoint(x: f.midX, y: f.midY)
            let rx = f.width * 0.32, ry = f.height * 0.36
            let x0 = max(0, Int(c.x - rx)), x1 = min(src.width - 1, Int(c.x + rx))
            let y0 = max(0, Int(c.y - ry)), y1 = min(src.height - 1, Int(c.y + ry))
            guard x0 <= x1, y0 <= y1 else { continue }
            let step = max(1, Int(max(rx, ry) / 40))
            for y in stride(from: y0, through: y1, by: step) { for x in stride(from: x0, through: x1, by: step) {
                let dx = (CGFloat(x) - c.x) / rx, dy = (CGFloat(y) - c.y) / ry
                if dx * dx + dy * dy > 1 { continue }
                let (r, g, b, a) = src.pixel(x, y)
                if a < 128 { continue }
                let rr = Double(r), gg = Double(g), bb = Double(b)
                if skinWeight(rr, gg, bb, model: generic, fuzz: 60) < 0.5 { continue }
                let (_, cb, cr) = ycc(rr, gg, bb)
                n += 1; scb += cb; scr += cr; scb2 += cb * cb; scr2 += cr * cr
            } }
        }
        guard n >= 20 else { return generic }
        let mcb = scb / n, mcr = scr / n
        let sdcb = sqrt(max(0, scb2 / n - mcb * mcb)), sdcr = sqrt(max(0, scr2 / n - mcr * mcr))
        return SkinModel(cb: mcb, cr: mcr, rcb: max(7, 2.8 * sdcb), rcr: max(6, 2.8 * sdcr))
    }

    /// Vision face rectangles in doc coordinates (y down).
    static func detectFaces(_ src: PixelBuffer) -> [CGRect] {
        let img = src.makeCGImage()
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        let W = CGFloat(src.width), H = CGFloat(src.height)
        return (req.results ?? []).map { o in
            let b = o.boundingBox
            return CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H)
        }
    }

    /// Selection mask (gray, same size as `src`).
    static func mask(src: PixelBuffer, options o: ColorRangeOptions, faces: [CGRect] = []) -> PixelBuffer {
        var m: PixelBuffer
        switch o.mode {
        case .sampled:
            m = SelectionOps.colorRange(src: src, color: o.color, fuzziness: o.fuzziness)
        case .outOfGamut:
            m = gamutMask(src)
        default:
            m = PixelBuffer(width: src.width, height: src.height, format: .gray)
            let model = o.mode == .skinTones && o.detectFaces && !faces.isEmpty ? skinModel(src: src, faces: faces) : SkinModel()
            let useFaces = o.mode == .skinTones && o.detectFaces && !faces.isEmpty
            let fz = o.fuzziness / 100 * 64      // tonal fuzziness in levels
            let p = src.data.assumingMemoryBound(to: UInt8.self)
            let q = m.data.assumingMemoryBound(to: UInt8.self)
            DispatchQueue.concurrentPerform(iterations: src.height) { y in
                for x in 0..<src.width {
                    let s = p + y * src.bytesPerRow + x * 4
                    let a = Double(s[3])
                    if a == 0 { continue }
                    let k = 255 / a
                    let r = Double(s[0]) * k, g = Double(s[1]) * k, b = Double(s[2]) * k
                    var w = 0.0
                    if let hi = o.mode.hueIndex {
                        let c = RGBA(r: r / 255, g: g / 255, b: b / 255)
                        let (h, sat, v) = c.hsb
                        var d = abs(h - Double(hi) / 6); d = min(d, 1 - d)
                        w = (1 - smooth(1.0 / 24, 1.0 / 8, d)) * smooth(0.12, 0.35, sat) * smooth(0.06, 0.18, v)
                    } else if o.mode.isTonal {
                        let l = 0.299 * r + 0.587 * g + 0.114 * b
                        let lo = o.rangeLow, hi = o.rangeHigh
                        let up = lo <= 0 ? 1 : smooth(lo - fz, lo + fz, l)
                        let dn = hi >= 255 ? 1 : 1 - smooth(hi - fz, hi + fz, l)
                        w = up * dn
                    } else if o.mode == .skinTones {
                        w = skinWeight(r, g, b, model: model, fuzz: o.fuzziness)
                        if useFaces {
                            // Emphasize skin on and around the detected faces (face, neck, ears).
                            var prox = 0.0
                            for f in faces {
                                let dx = (Double(x) - Double(f.midX)) / Double(f.width), dy = (Double(y) - Double(f.midY) - Double(f.height) * 0.3) / Double(f.height)
                                let d = sqrt(dx * dx + dy * dy * 0.6)
                                prox = max(prox, 1 - smooth(0.8, 2.2, d))
                            }
                            w *= 0.3 + 0.7 * prox
                        }
                    }
                    q[y * m.bytesPerRow + x] = UInt8(clamp(w, 0, 1) * 255 * (a / 255))
                }
            }
            m.markDirty()
        }
        if o.invert { m = SelectionOps.invert(m) }
        return m
    }

    /// Colours that do not survive the proof (CMYK) profile.
    static func gamutMask(_ src: PixelBuffer) -> PixelBuffer {
        let proof = AppModel.shared.proof
        let cs = ColorProfiles.space(named: proof.profileName)
        let sp = CanvasSpace(width: src.width, height: src.height)
        guard let (_, g) = ColorConvert.proofCubes(cs, key: proof.profileName, intent: proof.intent) else {
            return PixelBuffer(width: src.width, height: src.height, format: .gray)
        }
        let img = src.ciImage.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": ColorConvert.cubeSize, "inputCubeData": g, "inputColorSpace": sRGBSpace])
        return RenderEngine.renderBuffer(img.cropped(to: sp.ciCanvas), docRect: IRect(x: 0, y: 0, width: src.width, height: src.height), space: sp, format: .gray)
    }

    /// Downscaled copy (max side `maxSide`) for previews.
    static func downscaled(_ b: PixelBuffer, maxSide: Int) -> PixelBuffer {
        let s = min(1, Double(maxSide) / Double(max(b.width, b.height)))
        if s >= 1 { return b }
        let o = PixelBuffer(width: max(1, Int(Double(b.width) * s)), height: max(1, Int(Double(b.height) * s)))
        o.drawImage(b.makeCGImage(), in: CGRect(x: 0, y: 0, width: o.width, height: o.height))
        o.markDirty()
        return o
    }
}

struct ColorRangeProDialog: View {
    @State private var o = ColorRangeOptions(color: AppModel.shared.foreground)
    @State private var preview: CGImage?
    @State private var small: PixelBuffer?
    @State private var smallFaces: [CGRect] = []
    @State private var fullFaces: [CGRect]?
    @State private var showOnCanvas = false

    var body: some View {
        DialogFrame(title: "Color Range", width: 340, onOK: apply, onCancel: { AppActions.doc?.revertUncommitted() }) {
            Picker("Select", selection: Binding(get: { o.mode }, set: { setMode($0) })) {
                ForEach(ColorRangeMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                    if m == .sampled || m == .magentas || m == .shadows || m == .skinTones { Divider() }
                }
            }
            if o.mode == .sampled {
                HStack {
                    Text("Sampled Color").foregroundStyle(Theme.textDim)
                    ColorWell(color: $o.color)
                    Button { NSColorSampler().show { c in if let c { o.color = RGBA(nsColor: c) } } } label: { Image(systemName: "eyedropper") }.buttonStyle(.plain)
                }
            }
            if o.mode == .skinTones {
                Toggle2(label: "Detect Faces", on: $o.detectFaces)
                if o.detectFaces { Text(smallFaces.isEmpty ? "No faces detected." : "\(smallFaces.count) face\(smallFaces.count == 1 ? "" : "s") detected.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
            }
            if o.mode.usesFuzziness {
                ValueSlider(label: "Fuzziness", value: $o.fuzziness, range: o.mode.isTonal ? 0...100 : 0...200, unit: o.mode.isTonal ? "%" : "")
            }
            if o.mode.isTonal {
                if o.mode != .shadows { ValueSlider(label: "Range Low", value: $o.rangeLow, range: 0...255) }
                if o.mode != .highlights { ValueSlider(label: "Range High", value: $o.rangeHigh, range: 0...255) }
            }
            Toggle2(label: "Invert", on: $o.invert)
            Toggle2(label: "Show Selection on Canvas", on: $showOnCanvas)
            ZStack {
                Color.black
                if let p = preview { Image(decorative: p, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit) }
            }
            .frame(width: 308, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            Text("Selection preview").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
        .onAppear(perform: setup)
        .onChange(of: o) { _, _ in refresh() }
        .onChange(of: showOnCanvas) { _, _ in refresh() }
    }

    func setMode(_ m: ColorRangeMode) {
        o.mode = m
        if m.isTonal { let d = m.toneDefaults; o.fuzziness = d.0; o.rangeLow = d.1; o.rangeHigh = d.2 }
        else if m == .skinTones || m == .sampled { o.fuzziness = 40 }
    }

    func setup() {
        guard let src = AppActions.sampleSource(allLayers: true) else { return }
        let s = ColorRangeEngine.downscaled(src, maxSide: 420)
        small = s
        smallFaces = ColorRangeEngine.detectFaces(s)
        refresh()
    }

    func refresh() {
        guard let s = small else { return }
        let m = ColorRangeEngine.mask(src: s, options: o, faces: smallFaces)
        preview = m.makeCGImage()
        guard let d = AppActions.doc else { return }
        if showOnCanvas, let full = AppActions.sampleSource(allLayers: true) {
            d.state.selection = ColorRangeEngine.mask(src: full, options: o, faces: faces(for: full))
            d.setNeedsOverlay()
        } else if d.state.selection !== d.committedState.selection {
            d.revertUncommitted()
        }
    }

    func faces(for full: PixelBuffer) -> [CGRect] {
        guard o.mode == .skinTones, o.detectFaces else { return [] }
        if let f = fullFaces { return f }
        let f = ColorRangeEngine.detectFaces(full)
        fullFaces = f
        return f
    }

    func apply() {
        guard let d = AppActions.doc else { return }
        d.revertUncommitted()
        guard let src = AppActions.sampleSource(allLayers: true) else { return }
        d.setSelection(ColorRangeEngine.mask(src: src, options: o, faces: faces(for: src)), commitName: "Color Range")
    }
}
