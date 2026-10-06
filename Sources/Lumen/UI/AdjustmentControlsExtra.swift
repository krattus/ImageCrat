import SwiftUI
import ImageCratCore

// MARK: - Eyedropper buttons (Levels / Curves)

struct DropperButtons: View {
    let prefix: String
    var doc: Document?
    let onSample: (DropperKind, RGBA) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(DropperKind.allCases, id: \.self) { k in
                let token = "\(prefix).\(k.rawValue)"
                let armed = CanvasSampler.shared.token == token
                Button {
                    CanvasSampler.shared.toggle(token) { p, _ in
                        guard let d = doc ?? AppActions.doc, let c = AdjustmentSampling.compositeColor(d, at: p) else { Beep.play(); return }
                        onSample(k, c)
                    }
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "eyedropper").font(.system(size: 11)).foregroundStyle(Theme.text)
                            .frame(width: 24, height: 20)
                        Circle().fill(k == .black ? Color.black : k == .gray ? Color(white: 0.5) : .white)
                            .overlay(Circle().stroke(Color(white: 0.6), lineWidth: 0.5))
                            .frame(width: 7, height: 7).offset(x: -2, y: -2)
                    }
                    .background(RoundedRectangle(cornerRadius: 4).fill(armed ? Theme.accent : Color(white: 0.24)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Sample in image to set \(k == .black ? "black point" : k == .gray ? "gray point" : "white point")")
            }
        }
        .onDisappear { if CanvasSampler.shared.token?.hasPrefix(prefix + ".") == true { CanvasSampler.shared.disarm() } }
    }
}

// MARK: - Hue / Saturation

private func signedDiff(_ a: Double, _ b: Double) -> Double { HueRange.wrap(a - b + 180) - 180 }

struct HueSatControls: View {
    @Binding var s: AdjustmentSettings
    var doc: Document?
    var onCommit: () -> Void
    @State private var sel = 0   // 0 = master, 1...6 = ranges

    var body: some View {
        let editingRange = sel > 0 && !s.colorize
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $sel) {
                    Text("Master").tag(0)
                    ForEach(1...6, id: \.self) { i in Text(tr(HueRange.names[i - 1])).tag(i) }
                }
                .labelsHidden().frame(width: 120).disabled(s.colorize)
                Spacer()
                rangeDroppers
            }
            if editingRange {
                let rb = $s.hsRanges[sel - 1]
                ValueSlider(label: "Hue", value: rb.hue, range: -180...180, onCommit: onCommit)
                ValueSlider(label: "Saturation", value: rb.saturation, range: -100...100, onCommit: onCommit)
                ValueSlider(label: "Lightness", value: rb.lightness, range: -100...100, onCommit: onCommit)
                HueRangeBar(range: rb.range, masterHue: s.hue, rangeHue: s.hsRanges[sel - 1].hue, onCommit: onCommit)
            } else {
                ValueSlider(label: "Hue", value: $s.hue, range: -180...180, onCommit: onCommit)
                ValueSlider(label: "Saturation", value: $s.hsSaturation, range: -100...100, onCommit: onCommit)
                ValueSlider(label: "Lightness", value: $s.lightness, range: -100...100, onCommit: onCommit)
                LinearGradient(colors: stride(from: 0.0, through: 1, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 1) }, startPoint: .leading, endPoint: .trailing).frame(height: 8)
                LinearGradient(colors: stride(from: 0.0, through: 1, by: 1.0 / 12).map { h in
                    let d = h * 360
                    var shifted = d + s.hue
                    if !s.colorize { for r in s.hsRanges where !r.isIdentity { shifted += r.weight(d) * r.hue } }
                    return Color(hue: HueRange.wrap(s.colorize ? s.hue : shifted) / 360, saturation: 1, brightness: 1)
                }, startPoint: .leading, endPoint: .trailing).frame(height: 8)
                if s.hsRanges.contains(where: { !$0.isIdentity }) && !s.colorize {
                    Text(tr("Edited ranges: " + s.hsRanges.enumerated().filter { !$0.element.isIdentity }.map { HueRange.names[$0.offset] }.joined(separator: ", ")))
                        .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                }
            }
            Toggle2(label: "Colorize", on: Binding(get: { s.colorize }, set: { s.colorize = $0; if $0 { sel = 0 }; onCommit() }))
        }
        .onDisappear { if CanvasSampler.shared.token?.hasPrefix("hs.") == true { CanvasSampler.shared.disarm() } }
    }

    /// Eyedropper (pick range at a color), add to range, subtract from range.
    var rangeDroppers: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { m in
                let token = "hs.\(m)"
                Button {
                    CanvasSampler.shared.toggle(token) { p, mods in
                        guard let d = doc ?? AppActions.doc, let c = AdjustmentSampling.compositeColor(d, at: p) else { Beep.play(); return }
                        let mode = mods.contains(.shift) ? 1 : mods.contains(.option) ? 2 : m
                        sampleRange(c, mode: mode)
                    }
                } label: {
                    HStack(spacing: 0) {
                        Image(systemName: "eyedropper").font(.system(size: 11))
                        if m > 0 { Text(tr(m == 1 ? "+" : "−")).font(.system(size: 10, weight: .bold)) }
                    }
                    .foregroundStyle(Theme.text)
                    .frame(width: 26, height: 20)
                    .background(RoundedRectangle(cornerRadius: 4).fill(CanvasSampler.shared.token == token ? Theme.accent : Color(white: 0.24)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(s.colorize || (m > 0 && sel == 0))
                .help(tr(m == 0 ? "Pick a color range from the image" : m == 1 ? "Add to the range" : "Subtract from the range"))
            }
        }
    }

    func sampleRange(_ c: RGBA, mode: Int) {
        let (hh, sat, _) = c.hsb
        guard sat > 0.02 else { Beep.play(); return }
        let h = hh * 360
        var cur = s
        if let a = doc?.activeLayer?.adjustment, a.kind == s.kind { cur = a }
        var idx = sel - 1
        if mode == 0 || idx < 0 {
            // Photoshop picks the range closest to the sampled hue and centers it there.
            if idx < 0 || mode == 0 {
                idx = (0..<6).min { abs(signedDiff(h, HueRange.defaults[$0].center)) < abs(signedDiff(h, HueRange.defaults[$1].center)) } ?? 0
            }
            let r = cur.hsRanges[idx]
            let delta = signedDiff(h, r.center)
            cur.hsRanges[idx].range = r.range.map { HueRange.wrap($0 + delta) }
        } else {
            let r = cur.hsRanges[idx]
            let C = r.center
            var rel = r.range.map { signedDiff($0, C) }
            let rh = signedDiff(h, C)
            if mode == 1 {
                if rh < rel[1] { let d = rh - rel[1]; rel[0] += d; rel[1] += d }
                if rh > rel[2] { let d = rh - rel[2]; rel[2] += d; rel[3] += d }
                if rel[3] - rel[0] > 360 { rel[0] = rel[3] - 360 }
                rel[1] = max(rel[1], rel[0]); rel[2] = min(rel[2], rel[3])
            } else {
                if rh >= rel[1] && rh <= 0 { let d = rh + 1 - rel[1]; rel[1] += d; rel[0] = min(rel[0] + d, rel[1]) }
                if rh <= rel[2] && rh > 0 { let d = rh - 1 - rel[2]; rel[2] += d; rel[3] = max(rel[3] + d, rel[2]) }
                if rel[1] > rel[2] { let m = (rel[1] + rel[2]) / 2; rel[1] = m; rel[2] = m }
            }
            cur.hsRanges[idx].range = rel.map { HueRange.wrap(C + $0) }
        }
        s = cur
        sel = idx + 1
        onCommit()
    }
}

/// Photoshop-style range bar: spectrum, draggable falloff triangles / range bars, and the adjusted spectrum.
struct HueRangeBar: View {
    @Binding var range: [Double]
    var masterHue: Double
    var rangeHue: Double
    var onCommit: () -> Void
    @State private var dragAxis: Double?
    @State private var dragStart: [Double]?
    @State private var dragWhat: [Int] = []

    var body: some View {
        let hr = HueRange(range: range)
        let axis = dragAxis ?? hr.center
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { g in
                let w = g.size.width
                Canvas { ctx, size in
                    func x(_ deg: Double) -> CGFloat { CGFloat((signedDiff(deg, axis) + 180) / 360) * size.width }
                    let n = 90
                    let segW = size.width / CGFloat(n)
                    for i in 0..<n {
                        let deg = axis - 180 + (Double(i) + 0.5) * 360 / Double(n)
                        let out = deg + masterHue + hr.weight(deg) * rangeHue
                        ctx.fill(Path(CGRect(x: CGFloat(i) * segW, y: 0, width: segW + 0.5, height: 9)), with: .color(Color(hue: HueRange.wrap(deg) / 360, saturation: 1, brightness: 1)))
                        ctx.fill(Path(CGRect(x: CGFloat(i) * segW, y: 25, width: segW + 0.5, height: 9)), with: .color(Color(hue: HueRange.wrap(out) / 360, saturation: 1, brightness: 1)))
                    }
                    let xs = range.map(x)
                    var band = Path()
                    band.move(to: CGPoint(x: xs[0], y: 22)); band.addLine(to: CGPoint(x: xs[1], y: 12))
                    band.addLine(to: CGPoint(x: xs[2], y: 12)); band.addLine(to: CGPoint(x: xs[3], y: 22)); band.closeSubpath()
                    ctx.fill(band, with: .color(Color(white: 0.45)))
                    ctx.fill(Path(CGRect(x: xs[1], y: 12, width: max(0, xs[2] - xs[1]), height: 10)), with: .color(Color(white: 0.7)))
                    for i in [1, 2] { ctx.fill(Path(CGRect(x: xs[i] - 1.5, y: 10, width: 3, height: 13)), with: .color(.white)) }
                    for i in [0, 3] {
                        var t = Path()
                        t.move(to: CGPoint(x: xs[i], y: 16)); t.addLine(to: CGPoint(x: xs[i] + 4, y: 23)); t.addLine(to: CGPoint(x: xs[i] - 4, y: 23)); t.closeSubpath()
                        ctx.fill(t, with: .color(.white))
                        ctx.stroke(t, with: .color(Color(white: 0.3)), lineWidth: 0.5)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    if dragStart == nil {
                        dragStart = range
                        dragAxis = axis
                        let px = range.map { CGFloat((signedDiff($0, axis) + 180) / 360) * w }
                        let lx = v.startLocation.x
                        if let i = (0..<4).min(by: { abs(px[$0] - lx) < abs(px[$1] - lx) }), abs(px[i] - lx) < 6 {
                            dragWhat = [i]
                        } else if lx > px[0] && lx < px[1] { dragWhat = [0, 1] }
                        else if lx > px[2] && lx < px[3] { dragWhat = [2, 3] }
                        else if lx >= px[1] && lx <= px[2] { dragWhat = [0, 1, 2, 3] }
                        else { dragWhat = [] }
                    }
                    guard let st = dragStart, let ax = dragAxis, !dragWhat.isEmpty else { return }
                    var rel = st.map { signedDiff($0, ax) }
                    var delta = Double((v.location.x - v.startLocation.x) / max(1, w)) * 360
                    // keep ordering fs ≤ rs ≤ re ≤ fe within one turn
                    let lo = dragWhat.first!, hi = dragWhat.last!
                    let lower = lo > 0 ? rel[lo - 1] : max(-180, rel[3] - 360)
                    let upper = hi < 3 ? rel[hi + 1] : min(180, rel[0] + 360)
                    delta = clamp(delta, lower - rel[lo], upper - rel[hi])
                    for i in dragWhat { rel[i] += delta }
                    range = rel.map { HueRange.wrap(ax + $0).rounded() }
                }.onEnded { _ in
                    dragStart = nil; dragAxis = nil; dragWhat = []
                    onCommit()
                })
            }
            .frame(height: 34)
            Text("\(Int(range[0]))° / \(Int(range[1]))° \\ \(Int(range[2]))° / \(Int(range[3]))°")
                .font(Theme.mono).foregroundStyle(Theme.textDim)
        }
    }
}

// MARK: - Replace Color

struct ReplaceColorControls: View {
    @Binding var s: AdjustmentSettings
    var doc: Document?
    var onCommit: () -> Void
    @State private var mode = 0          // 0 sample, 1 add, 2 subtract
    @State private var showImage = false
    @State private var thumb: CGImage?

    static let token = "replaceColor"

    var body: some View {
        let r = s.replace
        VStack(alignment: .leading, spacing: 8) {
            Caption("Selection")
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { m in
                    Button { mode = m; arm() } label: {
                        HStack(spacing: 0) {
                            Image(systemName: "eyedropper").font(.system(size: 11))
                            if m > 0 { Text(tr(m == 1 ? "+" : "−")).font(.system(size: 10, weight: .bold)) }
                        }
                        .foregroundStyle(Theme.text)
                        .frame(width: 28, height: 20)
                        .background(RoundedRectangle(cornerRadius: 4).fill(mode == m && CanvasSampler.shared.token == Self.token ? Theme.accent : Color(white: 0.24)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tr(m == 0 ? "Sample color (click in image)" : m == 1 ? "Add to sample (Shift-click)" : "Subtract from sample (Option-click)"))
                }
                Spacer()
                Text("Color:").foregroundStyle(Theme.textDim)
                swatch(r.colors.first)
            }
            Toggle2(label: "Localized Color Clusters", on: Binding(get: { s.replace.localized }, set: { s.replace.localized = $0; onCommit() }))
            ValueSlider(label: "Fuzziness", value: $s.replace.fuzziness, range: 0...200, onCommit: onCommit)
            if r.localized {
                ValueSlider(label: "Range", value: $s.replace.rangePercent, range: 1...100, unit: "%", onCommit: onCommit)
            }
            ZStack {
                Color.black
                if let t = thumb { Image(decorative: t, scale: 1).interpolation(.medium) }
                if r.colors.isEmpty { Text("Click in the image to sample a color").font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
            }
            .frame(width: 220, height: 150)
            .frame(maxWidth: .infinity)
            Picker("", selection: $showImage) { Text("Selection").tag(false); Text("Image").tag(true) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180).frame(maxWidth: .infinity)
            Caption("Replacement")
            ValueSlider(label: "Hue", value: $s.replace.hue, range: -180...180, onCommit: onCommit)
            ValueSlider(label: "Saturation", value: $s.replace.saturation, range: -100...100, onCommit: onCommit)
            ValueSlider(label: "Lightness", value: $s.replace.lightness, range: -100...100, onCommit: onCommit)
            HStack {
                Text("Result:").foregroundStyle(Theme.textDim)
                swatch(r.colors.first.map { AdjustmentEngine.hslShift($0, hue: r.hue, saturation: r.saturation, lightness: r.lightness) })
                Spacer()
                Button("Clear Samples") {
                    s.replace.colors = []; s.replace.subtract = []; s.replace.points = []
                    onCommit()
                }.buttonStyle(PanelButtonStyle())
            }
        }
        .onAppear { arm(); refreshThumb() }
        .onDisappear { CanvasSampler.shared.disarm(Self.token) }
        .onChange(of: s.replace) { _, _ in refreshThumb() }
        .onChange(of: showImage) { _, _ in refreshThumb() }
    }

    func swatch(_ c: RGBA?) -> some View {
        ZStack {
            CheckerBackground(size: 4)
            if let c { Rectangle().fill(Color(nsColor: c.withAlpha(1).nsColor)) }
        }
        .frame(width: 34, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(white: 0.45), lineWidth: 0.5))
    }

    func arm() {
        CanvasSampler.shared.arm(Self.token) { p, mods in sample(p, mods) }
    }

    func sample(_ p: CGPoint, _ mods: NSEvent.ModifierFlags) {
        guard let d = doc ?? AppActions.doc, let c = AdjustmentSampling.layerColor(d, at: p) else { Beep.play(); return }
        let m = mods.contains(.shift) ? 1 : mods.contains(.option) ? 2 : mode
        let sp = AppActions.space(d)
        var r = s.replace
        r.canvasSize = Double(max(sp.width, sp.height))
        let ci = sp.ciPoint(CGPoint(x: floor(p.x) + 0.5, y: floor(p.y) + 0.5))
        let col = c.withAlpha(1)
        switch m {
        case 1: r.colors.append(col); r.points.append(ci)
        case 2: r.subtract.append(col)
        default: r.colors = [col]; r.subtract = []; r.points = [ci]
        }
        s.replace = r
        onCommit()
    }

    func refreshThumb() {
        guard let d = doc ?? AppActions.doc else { thumb = nil; return }
        let sp = AppActions.space(d)
        let content = AdjustmentSampling.activeContent(d)
        let canvas = sp.ciCanvas
        let img: CIImage = showImage
            ? content.composited(over: CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: canvas))
            : AdjustmentEngine.replaceColorMask(s.replace, content)
        let sc = min(220 / canvas.width, 150 / canvas.height)
        let scaled = img.cropped(to: canvas).composited(over: CIImage(color: .black).cropped(to: canvas))
            .transformed(by: CGAffineTransform(scaleX: sc, y: sc))
        thumb = RenderEngine.readbackContext.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: floor(canvas.width * sc), height: floor(canvas.height * sc)),
                                                           format: .RGBA8, colorSpace: sRGBSpace)
    }
}

// MARK: - Match Color

struct MatchColorControls: View {
    @Binding var s: AdjustmentSettings
    var doc: Document?
    var onCommit: () -> Void
    @State private var sourceDoc: UUID?
    @State private var sourceLayer: UUID?   // nil = merged

    var body: some View {
        let app = AppModel.shared
        let target = doc ?? AppActions.doc
        VStack(alignment: .leading, spacing: 8) {
            Caption("Destination Image")
            Text("Target: \(target?.name ?? "—") (\(target?.activeLayer?.name ?? "—"))").foregroundStyle(Theme.textDim).lineLimit(1)
            Caption("Image Options")
            ValueSlider(label: "Luminance", value: $s.match.luminance, range: 1...200, labelWidth: 96, onCommit: onCommit)
            ValueSlider(label: "Color Intensity", value: $s.match.intensity, range: 1...200, labelWidth: 96, onCommit: onCommit)
            ValueSlider(label: "Fade", value: $s.match.fade, range: 0...100, labelWidth: 96, onCommit: onCommit)
            Toggle2(label: "Neutralize", on: Binding(get: { s.match.neutralize }, set: { s.match.neutralize = $0; onCommit() }))
            Caption("Image Statistics")
            Picker("Source", selection: $sourceDoc) {
                Text("None").tag(UUID?.none)
                ForEach(app.documents, id: \.id) { d in Text(d.name).tag(UUID?.some(d.id)) }
            }
            if let sd = app.documents.first(where: { $0.id == sourceDoc }) {
                Picker("Layer", selection: $sourceLayer) {
                    Text("Merged").tag(UUID?.none)
                    ForEach(sd.state.allLayers.filter { !$0.isGroup && !$0.isAdjustment }.reversed(), id: \.id) { l in Text(l.name).tag(UUID?.some(l.id)) }
                }
            }
            HStack(spacing: 10) {
                statSwatch("Source", s.match.source ?? s.match.target)
                statSwatch("Target", s.match.target)
                Spacer()
            }
        }
        .onAppear { computeTarget(); computeSource() }
        .onChange(of: sourceDoc) { _, _ in sourceLayer = nil; computeSource() }
        .onChange(of: sourceLayer) { _, _ in computeSource() }
    }

    func statSwatch(_ label: String, _ st: LabStats?) -> some View {
        HStack(spacing: 4) {
            Text(tr(label)).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            if let st {
                let c = MatchColorControls.labToRGB(st.mean)
                Rectangle().fill(Color(nsColor: c.nsColor)).frame(width: 26, height: 14)
                    .overlay(Rectangle().stroke(Color(white: 0.45), lineWidth: 0.5))
            }
        }
    }

    static func labToRGB(_ m: [Double]) -> RGBA {
        let fy = (m[0] + 16) / 116, fx = fy + m[1] / 500, fz = fy - m[2] / 200
        func inv(_ f: Double) -> Double { let f3 = f * f * f; return f3 > 0.008856 ? f3 : (f - 16.0 / 116) / 7.787 }
        let X = inv(fx) * 0.95047, Y = inv(fy), Z = inv(fz) * 1.08883
        func g(_ v: Double) -> Double { let c = clamp(v, 0, 1); return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        return RGBA(r: g(3.2406 * X - 1.5372 * Y - 0.4986 * Z), g: g(-0.9689 * X + 1.8758 * Y + 0.0415 * Z), b: g(0.0557 * X - 0.2040 * Y + 1.0570 * Z))
    }

    func computeTarget() {
        guard let d = doc ?? AppActions.doc else { return }
        s.match.target = ColorStats.lab(AdjustmentSampling.activeContent(d))
    }

    func computeSource() {
        guard let sid = sourceDoc, let sd = AppModel.shared.documents.first(where: { $0.id == sid }) else {
            if s.match.source != nil { s.match.source = nil; s.match.sourceName = "" }
            return
        }
        let sp = AppActions.space(sd)
        let img: CIImage
        var name = sd.name
        if let lid = sourceLayer, let l = sd.state.layer(lid), let c = Compositor.shared.contentImage(l, space: sp) {
            img = c; name += " / " + l.name
        } else {
            img = Compositor.shared.composite(sd.state, options: Compositor.Options(hidden: sd.hiddenLayers))
        }
        s.match.source = ColorStats.lab(img.cropped(to: sp.ciCanvas))
        s.match.sourceName = name
    }
}

// MARK: - HDR Toning

struct HDRToningControls: View {
    @Binding var s: AdjustmentSettings
    var doc: Document?
    var onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("Method", selection: Binding(get: { s.hdr.method }, set: { s.hdr.method = $0; onCommit() })) {
                ForEach(HDRMethod.allCases) { Text(tr($0.rawValue)).tag($0) }
            }
            switch s.hdr.method {
            case .localAdaptation:
                Caption("Edge Glow")
                ValueSlider(label: "Radius", value: $s.hdr.radius, range: 1...500, unit: "px", onCommit: onCommit)
                ValueSlider(label: "Strength", value: $s.hdr.strength, range: 0.1...4, step: 0.01, format: "%.2f", onCommit: onCommit)
                Caption("Tone and Detail")
                ValueSlider(label: "Gamma", value: $s.hdr.gamma, range: 0.1...2, step: 0.01, format: "%.2f", onCommit: onCommit)
                ValueSlider(label: "Exposure", value: $s.hdr.exposure, range: -5...5, step: 0.01, format: "%.2f", onCommit: onCommit)
                ValueSlider(label: "Detail", value: $s.hdr.detail, range: -100...300, unit: "%", onCommit: onCommit)
                Caption("Advanced")
                ValueSlider(label: "Shadow", value: $s.hdr.shadow, range: -100...100, unit: "%", onCommit: onCommit)
                ValueSlider(label: "Highlight", value: $s.hdr.highlight, range: -100...100, unit: "%", onCommit: onCommit)
                ValueSlider(label: "Vibrance", value: $s.hdr.vibrance, range: -100...100, unit: "%", onCommit: onCommit)
                ValueSlider(label: "Saturation", value: $s.hdr.saturation, range: -100...100, unit: "%", onCommit: onCommit)
                Toggle2(label: "Toning Curve", on: Binding(get: { s.hdr.useCurve }, set: { s.hdr.useCurve = $0; onCommit() }))
                if s.hdr.useCurve {
                    CurveEditor(curve: $s.hdr.curve, hist: doc.map { HistogramCache.get($0) }, channel: 0, color: .white, onCommit: onCommit)
                        .frame(width: 150, height: 150).frame(maxWidth: .infinity)
                }
            case .exposureGamma:
                ValueSlider(label: "Exposure", value: $s.hdr.exposure, range: -5...5, step: 0.01, format: "%.2f", onCommit: onCommit)
                ValueSlider(label: "Gamma", value: $s.hdr.gamma, range: 0.1...2, step: 0.01, format: "%.2f", onCommit: onCommit)
            case .highlightCompression:
                Text("Compresses highlight values so they fall within the displayable range.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
            Text("Applies to the active layer.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
    }
}
