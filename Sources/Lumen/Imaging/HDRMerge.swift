import Foundation
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import ImageCratCore

struct HDRInput {
    var name: String
    var image: CIImage        // extent (0, 0, w, h), display-referred sRGB
    var ev: Double            // exposure in stops relative to the others (larger = brighter / longer)
    var url: URL? = nil
}

enum HDRMode: String, CaseIterable, Identifiable { case bits32 = "32 Bit", bits16 = "16 Bit", bits8 = "8 Bit"; var id: String { rawValue } }

/// Merge to HDR Pro: Debevec-style weighted radiance merge in float Core Image, optional ghost removal, tone mapping via HDR Toning.
enum HDRMerge {
    // MARK: Exposure values

    /// EV from EXIF (log2 of exposure time × ISO / f-number²), nil when missing.
    static func exifEV(_ url: URL) -> Double? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 else { return nil }
        let n = (exif[kCGImagePropertyExifFNumber] as? Double) ?? 1
        let iso = ((exif[kCGImagePropertyExifISOSpeedRatings] as? [Double])?.first) ?? 100
        return log2(t * iso / 100 / max(0.5, n * n))
    }

    /// Linear-light luminance samples (downsampled).
    static func samples(_ img: CIImage, side: Int = 160) -> [Float] {
        let e = img.extent
        let s = min(1, CGFloat(side) / max(e.width, e.height))
        let w = max(2, Int(e.width * s)), h = max(2, Int(e.height * s))
        let small = img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height), highQualityDownsample: true)
        var f = [Float](repeating: 0, count: w * h * 4)
        RenderEngine.readbackContext.render(small, toBitmap: &f, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: sRGBSpace)
        return stride(from: 0, to: f.count, by: 4).map { 0.2126 * f[$0] + 0.7152 * f[$0 + 1] + 0.0722 * f[$0 + 2] }
    }

    /// Relative EVs estimated from pixel ratios where both exposures are well exposed (for files without EXIF).
    static func estimateEVs(_ images: [CIImage]) -> [Double] {
        let s = images.map { samples($0) }
        let order = s.indices.sorted { mean(s[$0]) < mean(s[$1]) }
        var ev = [Double](repeating: 0, count: images.count)
        for k in 1..<max(1, order.count) {
            let a = s[order[k - 1]], b = s[order[k]]
            var ratios: [Double] = []
            for i in a.indices {
                let la = lin(a[i]), lb = lin(b[i])
                if a[i] > 0.08 && a[i] < 0.92 && b[i] > 0.08 && b[i] < 0.92 && la > 1e-4 { ratios.append(Double(lb / la)) }
            }
            ratios.sort()
            let r = ratios.isEmpty ? 2 : max(1.01, ratios[ratios.count / 2])
            ev[order[k]] = ev[order[k - 1]] + log2(r)
        }
        let mid = ev.sorted()[ev.count / 2]
        return ev.map { $0 - mid }
    }

    static func mean(_ a: [Float]) -> Double { a.isEmpty ? 0 : Double(a.reduce(0, +)) / Double(a.count) }
    static func lin(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4) }

    // MARK: Alignment

    static func align(_ inputs: [HDRInput]) -> [HDRInput] {
        guard inputs.count > 1 else { return inputs }
        let refIndex = inputs.indices.sorted { inputs[$0].ev < inputs[$1].ev }[inputs.count / 2]
        let sets = inputs.map { Registration.prepare($0.image, maxSide: 1000, upright: true) }
        let a = Registration.alignAll(sets, model: .homography, reference: refIndex)
        let ref = inputs[refIndex]
        let W = Int(ref.image.extent.width), H = Int(ref.image.extent.height)
        return inputs.enumerated().map { i, inp in
            guard i != refIndex, let Hm = a.H[i], let Hi = Hm.inverted else { return inp }
            let img = PanoImage(source: PanoSource(name: inp.name, image: inp.image), H: Hm, Hinv: Registration.normalized(Hi))
            var out = inp
            // fill uncovered border with the unaligned pixels so edges keep a value
            out.image = Panorama.warp(img, proj: PanoProjection(), outW: W, outH: H).composited(over: inp.image).cropped(to: ref.image.extent)
            return out
        }
    }

    // MARK: Radiance

    static let weightFn = """
    float lumenHat(float z) { float d = 2.0 * z - 1.0; float d2 = d * d; return max(1.0 - d2 * d2 * d2, 0.0); }
    float lumenLin(float c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }
    vec3 lumenLin3(vec3 c) { return vec3(lumenLin(c.r), lumenLin(c.g), lumenLin(c.b)); }
    // Hat weight + a tiny tie-breaker: where every exposure clips, trust the shortest (highlights) or longest (shadows).
    float lumenHatE(float z, float it) { float e = z > 0.5 ? it * it * it * it : 1.0 / max(it * it * it * it, 1e-12); return lumenHat(z) + 1e-7 * min(e, 1e7); }
    vec3 lumenW3(vec3 c, float it) { return vec3(lumenHatE(c.r, it), lumenHatE(c.g, it), lumenHatE(c.b, it)); }
    float lumenGhost(vec3 c, vec3 rf, vec4 p) {
        if (p.y <= 0.0 || p.z > 0.5) { return 1.0; }
        float cmax = max(max(c.r, c.g), c.b), rmax = max(max(rf.r, rf.g), rf.b);
        float cmin = min(min(c.r, c.g), c.b), rmin = min(min(rf.r, rf.g), rf.b);
        // only compare where neither exposure clips in any channel
        if (cmax > 0.97 || rmax > 0.97 || cmin < 0.02 || rmin < 0.01) { return 1.0; }
        // per-channel radiance disagreement with the reference exposure (colour changes count, not just luminance)
        vec3 ec = lumenLin3(c) * p.x, er = lumenLin3(rf) * p.w;
        float eps = 0.004 * max(p.x, p.w);
        vec3 d = abs(log((ec + eps) / (er + eps)));
        return max(max(d.r, d.g), d.b) > p.y ? 0.0 : 1.0;
    }
    """

    static let numKernel = CIColorKernel(source: weightFn + """
    kernel vec4 lumenHDRNum(__sample acc, __sample s, __sample rf, vec4 p) {
        vec3 c = s.a > 0.0 ? clamp(s.rgb / s.a, 0.0, 1.0) : vec3(0.0);
        vec3 r = rf.a > 0.0 ? clamp(rf.rgb / rf.a, 0.0, 1.0) : vec3(0.0);
        vec3 w = lumenW3(c, p.x) * lumenGhost(c, r, p);
        return vec4(acc.rgb + w * lumenLin3(c) * p.x, 1.0);
    }
    """)

    static let denKernel = CIColorKernel(source: weightFn + """
    kernel vec4 lumenHDRDen(__sample acc, __sample s, __sample rf, vec4 p) {
        vec3 c = s.a > 0.0 ? clamp(s.rgb / s.a, 0.0, 1.0) : vec3(0.0);
        vec3 r = rf.a > 0.0 ? clamp(rf.rgb / rf.a, 0.0, 1.0) : vec3(0.0);
        vec3 w = lumenW3(c, p.x) * lumenGhost(c, r, p);
        return vec4(acc.rgb + w, 1.0);
    }
    """)

    static let divKernel = CIColorKernel(source: "kernel vec4 lumenHDRDiv(__sample n, __sample d) { return vec4(n.rgb / max(d.rgb, vec3(0.000001)), 1.0); }")

    /// Scene-linear radiance (relative to the reference exposure = EV 0). Values may exceed 1.
    static func radiance(_ inputs: [HDRInput], removeGhosts: Bool) -> CIImage? {
        guard let nk = numKernel, let dk = denKernel, let div = divKernel, let first = inputs.first else { return nil }
        let rect = first.image.extent
        let refIndex = inputs.indices.sorted { inputs[$0].ev < inputs[$1].ev }[inputs.count / 2]
        let ref = inputs[refIndex]
        var num = CIImage.color(.black, rect), den = CIImage.color(.black, rect)
        for (i, inp) in inputs.enumerated() {
            let p = CIVector(x: CGFloat(pow(2, -inp.ev)), y: removeGhosts ? 0.6 : 0, z: i == refIndex ? 1 : 0, w: CGFloat(pow(2, -ref.ev)))
            num = nk.apply(extent: rect, arguments: [num, inp.image, ref.image, p]) ?? num
            den = dk.apply(extent: rect, arguments: [den, inp.image, ref.image, p]) ?? den
        }
        let r = div.apply(extent: rect, arguments: [num, den]) ?? num
        return MultiBand.materialize(r)
    }

    // MARK: Tone mapping

    static let compressKernel = CIColorKernel(source: """
    kernel vec4 lumenHDRCompress(__sample e, vec4 p) {
        vec3 c = max(e.rgb, vec3(0.0));
        float y = max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 1e-6);
        float yo = 0.18 * exp(p.x * (log(y) - p.y));
        vec3 o = c * (yo / y);
        float mx = max(max(o.r, o.g), o.b);
        if (mx > 1.0) { o = o / mx; }
        o = pow(clamp(o, 0.0, 1.0), vec3(1.0 / 2.2));
        return vec4(o, 1.0);
    }
    """)

    static let exposeKernel = CIColorKernel(source: """
    float lumenL2S(float c) { return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055; }
    kernel vec4 lumenHDRExpose(__sample e, float k) {
        vec3 c = clamp(max(e.rgb, vec3(0.0)) * k, 0.0, 1.0);
        return vec4(lumenL2S(c.r), lumenL2S(c.g), lumenL2S(c.b), 1.0);
    }
    """)

    /// Log-domain compression of the radiance into [0, 1] (keeps ratios), ready for the HDR Toning local adaptation.
    static func compress(_ rad: CIImage) -> CIImage {
        // radiance values are scene-linear already (stored raw in the working space)
        let ys = samples(rad, side: 200).map { Double(max(1e-6, $0)) }.sorted()
        let lo = max(1e-5, ys[Int(Double(ys.count - 1) * 0.01)]), hi = max(lo * 1.01, ys[Int(Double(ys.count - 1) * 0.995)])
        // log-average (key) maps to 0.18; the slope keeps the 1st…99.5th percentiles inside [0.003, 1]
        let key = exp(ys.reduce(0.0) { $0 + log($1) } / Double(ys.count))
        let up = log(hi / key), down = log(key / lo)
        let alpha = min(1.0, up > 0.01 ? log(1 / 0.18) / up : 1, down > 0.01 ? log(0.18 / 0.003) / down : 1)
        return compressKernel?.apply(extent: rad.extent, arguments: [rad, CIVector(x: CGFloat(alpha), y: CGFloat(log(key)), z: 0, w: 0)]) ?? rad
    }

    static func toneMap(_ rad: CIImage, settings: HDRToningSettings) -> CIImage {
        AdjustmentEngine.applyHDRToning(settings, compress(rad)).cropped(to: rad.extent)
    }

    /// Display image of a 32-bit merge (exposure only, clipped).
    static func exposed(_ rad: CIImage, ev: Double = 0) -> CIImage {
        exposeKernel?.apply(extent: rad.extent, arguments: [rad, Float(pow(2, ev))]) ?? rad
    }

    // MARK: Document

    static func document(_ inputs0: [HDRInput], align: Bool, removeGhosts: Bool, mode: HDRMode, toning: HDRToningSettings) -> (DocumentState, CIImage)? {
        var inputs = inputs0
        if align { inputs = self.align(inputs) }
        guard let rad = radiance(inputs, removeGhosts: removeGhosts) else { return nil }
        let out = mode == .bits32 ? exposed(rad) : toneMap(rad, settings: toning)
        let W = Int(rad.extent.width), H = Int(rad.extent.height)
        var st = DocumentState(width: W, height: H)
        st.bitDepth = mode == .bits32 ? .thirtyTwo : (mode == .bits16 ? .sixteen : .eight)
        st.layers = [Layer.raster(name: "Background", buffer: RenderEngine.renderBuffer(out, docRect: st.canvasRect, space: CanvasSpace(width: W, height: H)))]
        return (st, rad)
    }

    static func writeEXR(_ rad: CIImage, to url: URL) throws {
        let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        // radiance values are scene-linear already: tag without conversion
        var data = Data(count: Int(rad.extent.width * rad.extent.height) * 16)
        let w = Int(rad.extent.width), h = Int(rad.extent.height)
        data.withUnsafeMutableBytes { p in RenderEngine.readbackContext.render(rad, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: rad.extent, format: .RGBAf, colorSpace: nil) }
        guard let prov = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: w * 16, space: lin,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.ilm.openexr-image" as CFString, 1, nil) else { throw DocumentIOError.encodeFailed }
        CGImageDestinationAddImage(dest, cg, nil)
        if !CGImageDestinationFinalize(dest) { throw DocumentIOError.encodeFailed }
    }
}

// MARK: - Dialog

struct HDRProDialog: View {
    @State private var items: [HDRInput] = []
    @State private var align = true
    @State private var ghosts = false
    @State private var mode: HDRMode = .bits16
    @State private var adj = AdjustmentSettings(kind: .hdrToning)
    @State private var preview: CGImage?
    @State private var radiance: CIImage?
    @State private var busy = false

    var body: some View {
        ImagingDialogFrame(title: "Merge to HDR Pro", width: 560, okTitle: "OK", okDisabled: items.count < 2 || busy, onOK: merge) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Caption("Source Images")
                    ForEach(items.indices, id: \.self) { i in
                        HStack {
                            Text(items[i].name).lineLimit(1).frame(width: 130, alignment: .leading)
                            NumberField(label: "EV", value: Binding(get: { items.indices.contains(i) ? items[i].ev : 0 }, set: { if items.indices.contains(i) { items[i].ev = $0; radiance = nil; refresh() } }), width: 44, format: "%.2f")
                            Button { if items.indices.contains(i) { items.remove(at: i) }; radiance = nil; refresh() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Button("Browse…") { browse() }.buttonStyle(PanelButtonStyle())
                        Button("Add Open Files") { addOpen() }.buttonStyle(PanelButtonStyle())
                    }
                    Toggle2(label: "Attempt to Automatically Align Source Images", on: Binding(get: { align }, set: { align = $0; radiance = nil; refresh() }))
                    Toggle2(label: "Remove ghosts", on: Binding(get: { ghosts }, set: { ghosts = $0; radiance = nil; refresh() }))
                    Picker("Mode", selection: Binding(get: { mode }, set: { mode = $0; refresh() })) { ForEach(HDRMode.allCases) { Text($0.rawValue).tag($0) } }
                    if mode != .bits32 {
                        HDRToningControls(s: $adj, doc: nil, onCommit: { refresh() })
                    } else {
                        Button("Save Radiance (OpenEXR)…") { saveEXR() }.buttonStyle(PanelButtonStyle()).disabled(radiance == nil)
                    }
                }
                .frame(width: 290)
                VStack {
                    ZStack {
                        Color.black
                        if let p = preview { Image(decorative: p, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                        if busy { ProgressView().controlSize(.small) }
                    }
                    .frame(width: 230, height: 180)
                    Text(items.count < 2 ? "Add two or more bracketed exposures." : "Preview").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                }
            }
        }
        .onChange(of: adj) { _, _ in refresh() }
    }

    func add(_ new: [HDRInput]) {
        items += new
        // fill EVs: EXIF when every file has it, otherwise estimate from pixels
        let exif = items.map { $0.url.flatMap(HDRMerge.exifEV) }
        if !exif.isEmpty, exif.allSatisfy({ $0 != nil }) {   // (an empty list satisfies everything: "Add Open Files" with no document open)
            let m = exif.compactMap { $0 }.sorted()[exif.count / 2]
            for i in items.indices { items[i].ev = exif[i]! - m }
        } else if items.count > 1 {
            let ev = HDRMerge.estimateEVs(items.map(\.image))
            for i in items.indices { items[i].ev = (ev[i] * 100).rounded() / 100 }
        }
        radiance = nil
        refresh()
    }

    func browse() {
        let p = NSOpenPanel()
        p.allowedContentTypes = AppActions.openTypes
        p.allowsMultipleSelection = true
        UIBlock.begin(p) { r in
            guard r == .OK else { return }
            add(p.urls.compactMap { u in MergeActions.source(url: u).map { HDRInput(name: $0.name, image: $0.image, ev: 0, url: u) } })
        }
    }

    func addOpen() {
        add(AppModel.shared.documents.map { d in let s = MergeActions.source(state: d.state, name: d.name); return HDRInput(name: s.name, image: s.image, ev: 0, url: d.fileURL) })
    }

    func refresh() {
        guard items.count >= 2 else { preview = nil; return }
        busy = true
        let its = items, al = align, gh = ghosts, md = mode, tone = adj.hdr, cached = radiance
        DispatchQueue.global(qos: .userInitiated).async {
            let rad: CIImage? = cached ?? {
                // preview works on downsized inputs
                let small = its.map { inp -> HDRInput in
                    var x = inp
                    let e = inp.image.extent, s = min(1, 480 / max(e.width, e.height))
                    x.image = MergeActions.materialize(inp.image.transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: true),
                                                       CGRect(x: 0, y: 0, width: floor(e.width * s), height: floor(e.height * s)))
                    return x
                }
                return HDRMerge.radiance(al ? HDRMerge.align(small) : small, removeGhosts: gh)
            }()
            let img = rad.map { md == .bits32 ? HDRMerge.exposed($0) : HDRMerge.toneMap($0, settings: tone) }
            let cg = img.flatMap { RenderEngine.cgImage($0, rect: $0.extent) }
            DispatchQueue.main.async { radiance = rad; preview = cg; busy = false }
        }
    }

    func merge() {
        AppModel.shared.dialog = nil
        let its = items, al = align, gh = ghosts, md = mode, tone = adj.hdr
        AppModel.shared.setStatus("Merging to HDR…")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = HDRMerge.document(its, align: al, removeGhosts: gh, mode: md, toning: tone)
            DispatchQueue.main.async {
                guard let (st, _) = r else { AppActions.alert("Merge to HDR Pro failed."); return }
                AppModel.shared.add(Document(state: st, name: "Untitled_HDR"))
                AppModel.shared.setStatus("HDR merge complete")
            }
        }
    }

    func saveEXR() {
        let its = items, al = align, gh = ghosts
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: "exr") ?? .data]
        p.nameFieldStringValue = "HDR Radiance.exr"
        UIBlock.begin(p) { r in
            guard r == .OK, let u = p.url else { return }
            let rad = HDRMerge.radiance(al ? HDRMerge.align(its) : its, removeGhosts: gh)
            do { if let rad { try HDRMerge.writeEXR(rad, to: u) } } catch { AppActions.alert("Could not write the EXR file.", error.localizedDescription) }
        }
    }
}

// MARK: - Tests

enum HDRSelfTest {
    static func run(_ out: URL) {
        typealias T = ImagingSelfTest
        let W = 480, H = 320
        // Scene radiance: dark interior (0.01…0.05), mid-tones, bright window (4…20) — ~11 stops.
        let base = MergeSelfTest.landscape(W, H, seed: 31)
        let sp = CanvasSpace(width: W, height: H)
        let rect = sp.ciCanvas
        let sceneKernel = CIColorKernel(source: """
        float lumenS2L(float c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }
        kernel vec4 lumenScene(__sample s, vec4 box) {
            vec2 d = destCoord();
            vec3 l = vec3(lumenS2L(s.r), lumenS2L(s.g), lumenS2L(s.b));
            float k = 0.6;
            if (d.x > box.x && d.x < box.y && d.y > box.z && d.y < box.w) { k = 6.0; }
            if (d.x < box.x - 20.0) { k = 0.04; }
            return vec4(l * k, 1.0);
        }
        """)!
        let scene = MultiBand.materialize(sceneKernel.apply(extent: rect, arguments: [base.ciImage, CIVector(x: 300, y: 440, z: 150, w: 290)])!)
        func shot(_ ev: Double, ghostAt: CGFloat? = nil) -> CIImage {
            var img = HDRMerge.exposed(scene, ev: ev)
            if let gx = ghostAt { img = CIImage.color(RGBA(hex: "C03030")!, CGRect(x: gx, y: 30, width: 40, height: 90)).composited(over: img).cropped(to: rect) }
            return MergeActions.materialize(img, rect)
        }
        let evs: [Double] = [-3, 0, 3]
        var inputs = evs.map { HDRInput(name: "EV \($0)", image: shot($0), ev: 0) }
        for (i, inp) in inputs.enumerated() { T.saveImage(inp.image, rect, "imaging_hdr_input_\(i)_ev\(Int(evs[i]))", out) }
        let est = HDRMerge.estimateEVs(inputs.map(\.image))
        T.check(zip(est, evs).allSatisfy { abs($0 - $1) < 0.35 }, "HDR EV estimation from pixels: \(est.map { String(format: "%.2f", $0) })")
        for i in inputs.indices { inputs[i].ev = est[i] }
        guard let rad = HDRMerge.radiance(inputs, removeGhosts: false) else { T.check(false, "HDR radiance failed"); return }
        // radiance accuracy against the synthetic scene (window ≫ 1 is recovered from the short exposure)
        var a = [Float](repeating: 0, count: 4), b = a
        let pt = CGRect(x: 370, y: 220, width: 1, height: 1), dk = CGRect(x: 60, y: 40, width: 1, height: 1)
        RenderEngine.readbackContext.render(rad, toBitmap: &a, rowBytes: 16, bounds: pt, format: .RGBAf, colorSpace: nil)
        RenderEngine.readbackContext.render(scene, toBitmap: &b, rowBytes: 16, bounds: pt, format: .RGBAf, colorSpace: nil)
        T.check(abs(log(Double(max(1e-4, a[1])) / Double(max(1e-4, b[1])))) < 0.25 && b[1] > 1.0, "HDR radiance in highlights \(a[1]) vs scene \(b[1])")
        RenderEngine.readbackContext.render(rad, toBitmap: &a, rowBytes: 16, bounds: dk, format: .RGBAf, colorSpace: nil)
        RenderEngine.readbackContext.render(scene, toBitmap: &b, rowBytes: 16, bounds: dk, format: .RGBAf, colorSpace: nil)
        T.check(abs(log(Double(max(1e-5, a[1])) / Double(max(1e-5, b[1])))) < 0.3, "HDR radiance in shadows \(a[1]) vs scene \(b[1])")
        let toned = HDRMerge.toneMap(rad, settings: HDRToningSettings())
        T.saveImage(toned, rect, "imaging_hdr_tonemapped_local", out)
        var s2 = HDRToningSettings(); s2.method = .exposureGamma; s2.exposure = 0
        T.saveImage(HDRMerge.toneMap(rad, settings: s2), rect, "imaging_hdr_tonemapped_expgamma", out)
        T.saveImage(HDRMerge.exposed(rad), rect, "imaging_hdr_32bit_exposure0", out)
        do { try HDRMerge.writeEXR(rad, to: out.appendingPathComponent("imaging_hdr_radiance.exr")); T.check(true, "EXR radiance written") } catch { T.check(false, "EXR \(error)") }

        // misaligned + ghost: shifted brackets and a moving object in the long exposure
        let shifted: [HDRInput] = [
            HDRInput(name: "a", image: MergeActions.materialize(shot(-3).transformed(by: CGAffineTransform(translationX: 6, y: -4)).composited(over: shot(-3)).cropped(to: rect), rect), ev: -3),
            HDRInput(name: "b", image: shot(0), ev: 0),
            HDRInput(name: "c", image: shot(0.5, ghostAt: 330), ev: 0.5),
        ]
        let aligned = HDRMerge.align(shifted)
        if let r1 = HDRMerge.radiance(aligned, removeGhosts: false), let r2 = HDRMerge.radiance(aligned, removeGhosts: true) {
            T.saveImage(HDRMerge.toneMap(r1, settings: HDRToningSettings()), rect, "imaging_hdr_aligned_ghosted", out)
            T.saveImage(HDRMerge.toneMap(r2, settings: HDRToningSettings()), rect, "imaging_hdr_aligned_deghosted", out)
            var p1 = [Float](repeating: 0, count: 4), p2 = p1
            let g = CGRect(x: 350, y: 80, width: 1, height: 1)   // inside the ghost (CI coords)
            RenderEngine.readbackContext.render(r1, toBitmap: &p1, rowBytes: 16, bounds: g, format: .RGBAf, colorSpace: nil)
            RenderEngine.readbackContext.render(r2, toBitmap: &p2, rowBytes: 16, bounds: g, format: .RGBAf, colorSpace: nil)
            RenderEngine.readbackContext.render(scene, toBitmap: &b, rowBytes: 16, bounds: g, format: .RGBAf, colorSpace: nil)
            let e1 = abs(p1[1] - b[1]) + abs(p1[0] - b[0]), e2 = abs(p2[1] - b[1]) + abs(p2[0] - b[0])
            T.check(e2 < e1 * 0.5, "ghost removal: error at moving object \(e1) → \(e2)")
        }
        if let (st, _) = HDRMerge.document(inputs, align: false, removeGhosts: false, mode: .bits16, toning: HDRToningSettings()) {
            T.check(st.bitDepth == .sixteen && st.width == W, "HDR Pro document \(st.width)×\(st.height) \(st.bitDepth.displayName)")
        }
    }
}
