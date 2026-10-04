import AppKit
@testable import LumenUltra
import SwiftUI
import UniformTypeIdentifiers
import ImageCratCore

// File ▸ Export ▸ Ultra PNG… — lossless or "Perceptual Ultra" export with a live preview, a difference heat-map,
// the importance map, "Protect" brush / rectangle, a live size estimate and background encoding with progress + cancel.

final class UltraPNGSession: ObservableObject {
    enum ViewMode: String, CaseIterable, Identifiable { case original = "Original", optimised = "Optimised", split = "Split", difference = "Difference"; var id: String { rawValue } }
    enum ProtectTool: String, CaseIterable, Identifiable { case none = "Off", rect = "Rectangle", brush = "Brush"; var id: String { rawValue } }

    let document: Document
    // settings
    @Published var lossy = true { didSet { schedule() } }
    /// 0…3 = presets (visually lossless, high, medium, small), 4 = custom.
    @Published var preset = 1 { didSet { schedule() } }
    @Published var customQ = 0.995 { didSet { if preset == 4 { schedule() } } }
    @Published var autoColors = true { didSet { schedule() } }
    @Published var maxColors = 256.0 { didSet { if !autoColors { schedule() } } }
    @Published var effort: UPEffort = .thorough { didSet { schedule() } }
    @Published var dithering = true { didSet { schedule() } }
    @Published var useSaliency = true { didSet { reloadMaps() } }
    @Published var keepProfile = true { didSet { schedule() } }
    @Published var convertToSRGB = true { didSet { reload() } }
    @Published var keepDPI = false { didSet { schedule() } }
    @Published var keepHiddenRGB = false { didSet { schedule() } }
    @Published var copyright = ""
    @Published var scalePercent = 100.0 { didSet { if scalePercent != oldValue { reload() } } }
    // preview
    @Published var zoom = 1.0
    @Published var view: ViewMode = .split
    @Published var split = 0.5
    @Published var showImportance = false
    @Published var protectTool: ProtectTool = .none
    @Published var brushSize = 28.0
    @Published var originalCG: CGImage?
    @Published var optimisedCG: CGImage?
    @Published var differenceCG: CGImage?
    @Published var importanceCG: CGImage?
    // status
    @Published var busy = false
    @Published var progress = 0.0
    @Published var stage = ""
    @Published var estimate: Int?
    @Published var exact: Int?
    @Published var normalPNG: Int?
    @Published var quality: UPQuality?
    @Published var info = ""
    @Published var targetMet = true
    @Published var protectedPixels = 0

    private(set) var source: UPImage?
    private var baseMaps: UPPerceptualMaps?
    private var protectMask: [Float] = []
    private(set) var resultData: Data?
    private var work: UPProgress?
    private var generation = 0
    private var pending: DispatchWorkItem?
    private var afterFull: ((Data) -> Void)?
    /// Offscreen tests drive the session synchronously.
    var synchronous = false

    var imageWidth: Int { source?.width ?? 1 }
    var imageHeight: Int { source?.height ?? 1 }

    init(document: Document, synchronous: Bool = false) {
        self.document = document
        self.synchronous = synchronous
        let last = synchronous ? [:] : WebExportPrefs.lastSettings
        if let v = last["lossy"] { lossy = v > 0 }
        if let v = last["preset"] { preset = max(0, min(4, Int(v))) }
        if let v = last["effort"], let e = UPEffort(rawValue: Int(v)) { effort = e }
        if let v = last["customQ"] { customQ = v }
        reload()
    }

    var target: UPQualityTarget {
        if preset < 4 { return UPQualityTarget.presets[preset] }
        // custom: one slider moves all three limits together between "small" and "visually lossless"
        let t = max(0, min(1, (customQ - 0.97) / (0.999 - 0.97)))
        return UPQualityTarget(q: customQ, smoothDE: 5 - 3.8 * t, banding: 2.3 - 1.95 * t, edgeDE: 6.5 - 5 * t, label: String(format: "custom Q %.3f", customQ))
    }

    func remember() {
        WebExportPrefs.lastSettings = ["lossy": lossy ? 1 : 0, "preset": Double(preset), "effort": Double(effort.rawValue), "customQ": customQ]
    }

    // MARK: source

    func reload() {
        cancelWork()
        guard let img = WXDoc.image(document.state, scale: scalePercent / 100, convertToSRGB: convertToSRGB) else { return }
        source = img
        protectMask = [Float](repeating: 0, count: img.width * img.height)
        protectedPixels = 0
        originalCG = WXDoc.cgImage(img)
        optimisedCG = originalCG
        differenceCG = nil
        normalPNG = nil
        baseMaps = nil
        let gen = generation
        let job = { [weak self] in
            let size = UPBridge.imageIOPNG(img)?.count
            self?.onMain { guard let s = self, s.generation == gen else { return }; s.normalPNG = size }
        }
        if synchronous { job() } else { DispatchQueue.global(qos: .utility).async(execute: job) }
        reloadMaps()
    }

    func reloadMaps() {
        guard let img = source else { return }
        let gen = generation
        var o = UPImportanceOptions()
        o.useVision = useSaliency; o.detectFaces = useSaliency; o.detectText = useSaliency
        let job = { [weak self] in
            let m = UPImportance.maps(img, options: o)
            self?.onMain {
                guard let s = self, s.generation == gen else { return }
                s.baseMaps = m
                s.updateImportanceOverlay()
                s.schedule()
            }
        }
        if synchronous { job() } else { DispatchQueue.global(qos: .userInitiated).async(execute: job) }
    }

    private func onMain(_ f: @escaping () -> Void) { if synchronous || Thread.isMainThread { f() } else { DispatchQueue.main.async(execute: f) } }

    var maps: UPPerceptualMaps? { baseMaps.map { UPImportance.applying(protect: protectMask, to: $0) } }

    // MARK: protect

    func protect(rect r: CGRect) {
        guard let img = source else { return }
        let x0 = max(0, Int(r.minX)), x1 = min(img.width, Int(r.maxX.rounded(.up))), y0 = max(0, Int(r.minY)), y1 = min(img.height, Int(r.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return }
        for y in y0..<y1 { for x in x0..<x1 { protectMask[y * img.width + x] = 1 } }
        protectChanged()
    }

    func protect(brushAt p: CGPoint, commit: Bool) {
        guard let img = source else { return }
        let r = brushSize / 2
        let x0 = max(0, Int(p.x - r)), x1 = min(img.width - 1, Int(p.x + r)), y0 = max(0, Int(p.y - r)), y1 = min(img.height - 1, Int(p.y + r))
        if x1 >= x0 && y1 >= y0 {
            for y in y0...y1 { for x in x0...x1 where (Double(x) - p.x) * (Double(x) - p.x) + (Double(y) - p.y) * (Double(y) - p.y) <= r * r { protectMask[y * img.width + x] = 1 } }
        }
        if commit { protectChanged() } else { updateImportanceOverlay() }
    }

    func clearProtect() {
        for i in 0..<protectMask.count { protectMask[i] = 0 }
        protectChanged()
    }

    private func protectChanged() {
        protectedPixels = protectMask.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        updateImportanceOverlay()
        schedule()
    }

    /// Red = importance, cyan = protected (premultiplied overlay).
    private func updateImportanceOverlay() {
        guard let img = source else { return }
        let n = img.width * img.height
        var px = [UInt8](repeating: 0, count: n * 4)
        let imp = baseMaps?.importance
        for i in 0..<n {
            if protectMask[i] > 0 { px[i * 4] = 0; px[i * 4 + 1] = 150; px[i * 4 + 2] = 170; px[i * 4 + 3] = 170 } else if let v = imp?[i] {
                let a = UInt8(max(0, min(150, v * 150)))
                px[i * 4] = a; px[i * 4 + 1] = UInt8(Int(a) / 6); px[i * 4 + 2] = 0; px[i * 4 + 3] = a
            }
        }
        guard let prov = CGDataProvider(data: Data(px) as CFData) else { return }
        importanceCG = CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4, space: UPBridge.srgb,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: encoding

    var ancillary: UPAncillary {
        var a = UPAncillary()
        if keepProfile { if let icc = source?.iccProfile { a.icc = icc } else { a.srgbIntent = 0 } }
        if keepDPI, let dpi = source?.dpi { a.dpi = dpi }
        if !copyright.isEmpty { a.text = [("Copyright", copyright)] }
        return a
    }

    func cancelWork() {
        pending?.cancel(); pending = nil
        work?.cancel(); work = nil
        generation += 1
        busy = false
        afterFull = nil
    }

    /// Debounced preview + encode after a settings change.
    func schedule() {
        guard source != nil, baseMaps != nil else { return }
        pending?.cancel()
        work?.cancel()
        generation += 1
        resultData = nil
        exact = nil
        if synchronous { run(); return }
        let item = DispatchWorkItem { [weak self] in self?.run() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func lossyOptions(previewOnly: Bool) -> UPLossyOptions {
        var o = UPLossyOptions()
        o.target = target
        o.maxColors = autoColors ? 256 : Int(maxColors)
        o.effort = effort
        o.dithering = dithering
        o.ancillary = ancillary
        o.maps = maps
        o.previewOnly = previewOnly
        return o
    }

    private func run() {
        guard let img = source else { return }
        let gen = generation
        let p = UPProgress()
        work = p
        busy = true; progress = 0; stage = "Analysing…"
        p.onUpdate = { [weak self] f, s in self?.onMain { guard let me = self, me.generation == gen else { return }; me.progress = f; me.stage = s } }
        let isLossy = lossy
        let lo = lossyOptions(previewOnly: false)
        var ll = UPLosslessOptions()
        ll.effort = effort; ll.ancillary = ancillary; ll.reduce.keepHiddenRGB = keepHiddenRGB
        if ll.ancillary.hasRGBProfile { ll.reduce.allowGray = false }
        let maps = self.maps
        let job = { [weak self] in
            if isLossy {
                // the search result is shown as soon as it exists; the exact size follows when the packing is done
                var lo = lo
                lo.onPreview = { image, q, est, mode, colors, met in
                    let ref = UPMetricReference(img, importance: maps?.importance)
                    var emap: [Float] = []
                    _ = ref.compare(image, errorMap: &emap)
                    let cg = WXDoc.cgImage(image)
                    let diff = emap.isEmpty ? nil : WXDoc.cgImage(WXSelfTestCore.heatMap(emap, img.width, img.height))
                    self?.onMain {
                        guard let me = self, me.generation == gen else { return }
                        me.optimisedCG = cg; me.differenceCG = diff; me.quality = q
                        me.estimate = est
                        me.info = mode == "palette" ? "palette, \(colors) colours" : mode
                        me.targetMet = met
                    }
                }
                guard let r = UPLossy.encode(img, options: lo, progress: p), !p.cancelled else { return }
                let ref = UPMetricReference(img, importance: maps?.importance)
                var emap: [Float] = []
                let q = r.mode == "lossless" ? UPQuality() : ref.compare(r.image, errorMap: &emap)
                let cg = WXDoc.cgImage(r.image)
                let diff = emap.isEmpty ? nil : WXDoc.cgImage(WXSelfTestCore.heatMap(emap, img.width, img.height))
                self?.onMain {
                    guard let me = self, me.generation == gen else { return }
                    me.optimisedCG = cg; me.differenceCG = diff; me.quality = q
                    me.info = (r.mode == "palette" ? "palette, \(r.colors) colours" : r.mode) + (r.encoder.map { " · \($0.deflater)" } ?? "")
                    me.targetMet = r.targetMet
                    me.finish(r.data)
                }
            } else {
                guard let r = UPLossless.encode(img, options: ll, progress: p), !p.cancelled else { return }
                self?.onMain {
                    guard let me = self, me.generation == gen else { return }
                    me.optimisedCG = me.originalCG; me.differenceCG = nil; me.quality = nil; me.estimate = nil
                    me.info = "\(r.representation) · \(r.filter) · \(r.deflater)" + (r.verified ? " · verified bit-identical" : " · FALLBACK")
                    me.targetMet = true
                    me.finish(r.data)
                }
            }
        }
        if synchronous { job() } else { DispatchQueue.global(qos: .userInitiated).async(execute: job) }
    }

    private func finish(_ data: Data) {
        resultData = data
        exact = data.count
        busy = false
        progress = 1
        stage = ""
        if let f = afterFull { afterFull = nil; f(data) }
    }

    /// Runs `then` with the finished file (now, or as soon as the running encode completes).
    func whenReady(_ then: @escaping (Data) -> Void) {
        if let d = resultData { then(d); return }
        afterFull = then
        if !busy { schedule() }
    }

    var sizeLine: String {
        let n = exact ?? estimate
        guard let n else { return busy ? "Working…" : "—" }
        var s = (exact == nil ? "≈ " : "") + WXTransfer.bytes(n)
        if let base = normalPNG, base > 0 { s += String(format: "  (%.0f%% smaller than the normal PNG, %@)", (1 - Double(n) / Double(base)) * 100, WXTransfer.bytes(base)) }
        return s
    }
}

struct UltraPNGDialog: View {
    @StateObject var session: UltraPNGSession

    init(session: UltraPNGSession) { _session = StateObject(wrappedValue: session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ultra PNG").font(.system(size: 13, weight: .semibold))
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    previewBar
                    UltraPNGPreview(s: session).frame(width: 620, height: 440)
                        .background(Color(white: 0.12)).clipShape(RoundedRectangle(cornerRadius: 4))
                    if session.view == .split { ValueSlider(label: "Split", value: $session.split, range: 0...1, format: "%.2f", labelWidth: 40).frame(width: 300) }
                    protectBar
                }
                settings.frame(width: 300)
            }
            bottomBar
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(width: 968)
        .onDisappear { session.remember(); session.cancelWork() }
    }

    private var previewBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $session.view) { ForEach(UltraPNGSession.ViewMode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            Picker("", selection: $session.zoom) { Text("100%").tag(1.0); Text("200%").tag(2.0); Text("300%").tag(3.0); Text("400%").tag(4.0) }
                .labelsHidden().frame(width: 80)
            Toggle2(label: "Importance map", on: $session.showImportance)
            Spacer()
            Text("\(session.imageWidth) × \(session.imageHeight) px").foregroundStyle(Theme.textFaint)
        }
    }

    private var protectBar: some View {
        HStack(spacing: 8) {
            Text("Protect").foregroundStyle(Theme.textDim)
            Picker("", selection: $session.protectTool) { ForEach(UltraPNGSession.ProtectTool.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            if session.protectTool == .brush { ValueSlider(label: "Size", value: $session.brushSize, range: 4...120, unit: "px", labelWidth: 30).frame(width: 190) }
            Button("Clear") { session.clearProtect() }.buttonStyle(PanelButtonStyle()).disabled(session.protectedPixels == 0)
            Spacer()
            Text(session.protectedPixels > 0 ? "\(session.protectedPixels) px stay pristine" : "Drag on the preview to mark regions that must stay pristine")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Mode")
            Picker("", selection: $session.lossy) { Text("Lossless").tag(false); Text("Perceptual Ultra").tag(true) }.pickerStyle(.segmented).labelsHidden()
            if session.lossy {
                Caption("Quality target")
                Picker("", selection: $session.preset) {
                    Text("Visually lossless").tag(0); Text("High").tag(1); Text("Medium").tag(2); Text("Small").tag(3); Text("Custom").tag(4)
                }.labelsHidden()
                if session.preset == 4 { ValueSlider(label: "Min. quality", value: $session.customQ, range: 0.97...0.999, format: "%.3f") }
                Toggle2(label: "Colours: automatic (fewest that meet the target)", on: $session.autoColors)
                if !session.autoColors { ValueSlider(label: "Max colours", value: $session.maxColors, range: 2...256, step: 1) }
                Toggle2(label: "Dithering (masked, rate-aware)", on: $session.dithering)
                Toggle2(label: "Saliency, face and text detection", on: $session.useSaliency)
            } else {
                Toggle2(label: "Keep colour hidden under transparency", on: $session.keepHiddenRGB)
            }
            Caption("Effort")
            Picker("", selection: $session.effort) { ForEach(UPEffort.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            HStack {
                Text("Size").foregroundStyle(Theme.textDim)
                Picker("", selection: $session.scalePercent) { Text("25%").tag(25.0); Text("50%").tag(50.0); Text("75%").tag(75.0); Text("100%").tag(100.0); Text("200%").tag(200.0) }
                    .labelsHidden().frame(width: 80)
            }
            Caption("Metadata")
            Toggle2(label: "Convert to sRGB", on: $session.convertToSRGB)
            Toggle2(label: session.convertToSRGB ? "Tag as sRGB (13 bytes)" : "Embed colour profile", on: $session.keepProfile)
            Toggle2(label: "Keep resolution (pHYs)", on: $session.keepDPI)
            HStack { Text("Copyright").foregroundStyle(Theme.textDim); TextField("none", text: $session.copyright, onCommit: { session.schedule() }).frame(width: 190) }
            Divider()
            Caption("Result")
            Text(session.sizeLine).font(Theme.fontBold).fixedSize(horizontal: false, vertical: true)
            if !session.info.isEmpty { Text(session.info).font(Theme.fontSmall).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true) }
            if let q = session.quality, session.lossy {
                Text(String(format: "SSIM %.4f · perceptual Q %.4f · edge ΔE %.1f · banding %.2f", q.ssim, q.q, q.edgeDE, q.banding))
                    .font(Theme.fontSmall).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                if !session.targetMet { Text("The target cannot be reached with these limits — best effort shown.").font(Theme.fontSmall).foregroundStyle(.orange) }
            }
            Spacer(minLength: 0)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if session.busy {
                ProgressView(value: session.progress).frame(width: 220)
                Text(session.stage).font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                Button("Stop") { session.cancelWork() }.buttonStyle(PanelButtonStyle())
            }
            Spacer()
            Button("Cancel") { session.cancelWork(); AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
            Button("Copy") { copy() }.buttonStyle(PanelButtonStyle())
            Button("Save…") { save() }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
        }
    }

    func copy() {
        session.whenReady { data in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(data, forType: .png)
            AppModel.shared.setStatus("Copied Ultra PNG (\(WXTransfer.bytes(data.count)))")
        }
    }

    func save() {
        let name = WXDoc.baseName(session.document) + ".png"
        session.whenReady { data in
            WebExportActions.save(data, suggested: name, type: .png) { url in
                AppModel.shared.setStatus("Saved \(url.lastPathComponent) (\(WXTransfer.bytes(data.count)))")
                AppModel.shared.dialog = nil
            }
        }
    }
}

/// Scrollable, zoomable preview with the before / after wipe, the heat-map, the importance overlay and the Protect tools.
struct UltraPNGPreview: View {
    @ObservedObject var s: UltraPNGSession
    @State private var dragStart: CGPoint?
    @State private var dragRect: CGRect?

    static let checker: CGImage? = {
        let c = WXCorpus.context(16, 16)
        c.setFillColor(WXCorpus.color(0x3A3A3A)); c.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        c.setFillColor(WXCorpus.color(0x4A4A4A)); c.fill(CGRect(x: 0, y: 0, width: 8, height: 8)); c.fill(CGRect(x: 8, y: 8, width: 8, height: 8))
        return c.makeImage()
    }()

    var body: some View {
        let z = CGFloat(s.zoom)
        let w = CGFloat(s.imageWidth) * z, h = CGFloat(s.imageHeight) * z
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                if let c = Self.checker { Image(decorative: c, scale: 1).resizable(resizingMode: .tile).frame(width: w, height: h) }
                layer(base).frame(width: w, height: h)
                if s.view == .split, let o = s.originalCG {
                    layer(o).frame(width: w, height: h)
                        .mask(alignment: .leading) { Rectangle().frame(width: w * CGFloat(s.split)) }
                    Rectangle().fill(Color.white.opacity(0.9)).frame(width: 1, height: h).offset(x: w * CGFloat(s.split))
                }
                if s.showImportance || s.protectTool != .none, let m = s.importanceCG { layer(m).frame(width: w, height: h).allowsHitTesting(false) }
                if let r = dragRect {
                    Rectangle().stroke(Color.cyan, lineWidth: 1).background(Color.cyan.opacity(0.2))
                        .frame(width: r.width * z, height: r.height * z).offset(x: r.minX * z, y: r.minY * z)
                }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard s.protectTool != .none else { return }
                let p = CGPoint(x: v.location.x / z, y: v.location.y / z)
                if s.protectTool == .brush { s.protect(brushAt: p, commit: false) } else {
                    if dragStart == nil { dragStart = p }
                    let a = dragStart!
                    dragRect = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y))
                }
            }.onEnded { v in
                guard s.protectTool != .none else { return }
                if s.protectTool == .brush { s.protect(brushAt: CGPoint(x: v.location.x / z, y: v.location.y / z), commit: true) } else if let r = dragRect { s.protect(rect: r) }
                dragStart = nil; dragRect = nil
            }, including: s.protectTool == .none ? .subviews : .all)
        }
    }

    private var base: CGImage? {
        switch s.view {
        case .original: return s.originalCG
        case .difference: return s.differenceCG ?? s.optimisedCG
        default: return s.optimisedCG
        }
    }

    @ViewBuilder private func layer(_ cg: CGImage?) -> some View {
        if let cg { Image(decorative: cg, scale: 1).resizable().interpolation(.none) }
    }
}
