import SwiftUI
import ImageCratCore

/// Histogram of a doc's active layer or composite (cached per revision).
enum HistogramCache {
    private static var key = ""
    private static var value: [[Int]] = []
    static func get(_ doc: Document, composite: Bool = true) -> [[Int]] {
        let k = "\(doc.id)-\(doc.revision)-\(composite)"
        if k == key { return value }
        let sp = CanvasSpace(width: doc.state.width, height: doc.state.height)
        let img = composite ? Compositor.shared.composite(doc.state) : (doc.activeLayer.flatMap { Compositor.shared.contentImage($0, space: sp) } ?? CIImage.clearImage)
        // downsample for speed
        let s = min(1, 512 / CGFloat(max(doc.state.width, doc.state.height)))
        let small = img.cropped(to: sp.ciCanvas).transformed(by: CGAffineTransform(scaleX: s, y: s))
        let r = IRect(x: 0, y: 0, width: max(1, Int(CGFloat(doc.state.width) * s)), height: max(1, Int(CGFloat(doc.state.height) * s)))
        let buf = PixelBuffer(width: r.width, height: r.height)
        RenderEngine.readbackContext.render(small, toBitmap: buf.data, rowBytes: buf.bytesPerRow, bounds: CGRect(x: 0, y: 0, width: r.width, height: r.height), format: .RGBA8, colorSpace: sRGBSpace)
        buf.markDirty()
        value = Histogram.compute(buf)
        key = k
        return value
    }
}

struct HistogramView: View {
    let hist: [[Int]]
    var channel: Int = 3     // 0 r, 1 g, 2 b, 3 luminosity, 4 = RGB overlay
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.fieldBG))
            guard hist.count == 4 else { return }
            func draw(_ h: [Int], _ color: Color) {
                let mx = max(1, h.sorted()[250])   // robust max
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for i in 0..<256 {
                    let x = CGFloat(i) / 255 * size.width
                    let y = size.height - min(1, CGFloat(h[i]) / CGFloat(mx)) * size.height
                    p.addLine(to: CGPoint(x: x, y: y))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                ctx.fill(p, with: .color(color))
            }
            if channel == 4 {
                ctx.blendMode = .screen
                draw(hist[0], Color.red.opacity(0.7)); draw(hist[1], Color.green.opacity(0.7)); draw(hist[2], Color.blue.opacity(0.7))
            } else {
                let colors: [Color] = [.red.opacity(0.8), .green.opacity(0.8), .blue.opacity(0.8), Color(white: 0.75)]
                draw(hist[min(3, channel)], colors[min(3, channel)])
            }
        }
    }
}

struct AdjustmentControls: View {
    @Binding var s: AdjustmentSettings
    var doc: Document?
    var onCommit: () -> Void

    @State private var channel = 0
    @State private var tone = 1
    @State private var selColor = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AdjustmentPresetPicker(s: $s, onCommit: onCommit)
            switch s.kind {
            case .brightnessContrast:
                ValueSlider(label: "Brightness", value: $s.brightness, range: -150...150, onCommit: onCommit)
                ValueSlider(label: "Contrast", value: $s.contrast, range: -50...100, onCommit: onCommit)
            case .levels:
                levels
            case .curves:
                curves
            case .exposure:
                ValueSlider(label: "Exposure", value: $s.exposure, range: -5...5, step: 0.01, format: "%.2f", onCommit: onCommit)
                ValueSlider(label: "Offset", value: $s.offset, range: -0.5...0.5, step: 0.0001, format: "%.4f", onCommit: onCommit)
                ValueSlider(label: "Gamma", value: $s.gamma, range: 0.1...9.99, step: 0.01, format: "%.2f", onCommit: onCommit)
            case .vibrance:
                ValueSlider(label: "Vibrance", value: $s.vibrance, range: -100...100, onCommit: onCommit)
                ValueSlider(label: "Saturation", value: $s.saturation, range: -100...100, onCommit: onCommit)
            case .hueSaturation:
                HueSatControls(s: $s, doc: doc, onCommit: onCommit)
            case .colorBalance:
                Picker("Tone", selection: $tone) { Text("Shadows").tag(0); Text("Midtones").tag(1); Text("Highlights").tag(2) }.pickerStyle(.segmented)
                let tb = tone == 0 ? $s.shadows : tone == 1 ? $s.midtones : $s.highlights
                ValueSlider(label: "Cyan ↔ Red", value: tb.cyanRed, range: -100...100, onCommit: onCommit)
                ValueSlider(label: "Magenta ↔ Green", value: tb.magentaGreen, range: -100...100, labelWidth: 96, onCommit: onCommit)
                ValueSlider(label: "Yellow ↔ Blue", value: tb.yellowBlue, range: -100...100, onCommit: onCommit)
                Toggle2(label: "Preserve Luminosity", on: Binding(get: { s.preserveLuminosity }, set: { s.preserveLuminosity = $0; onCommit() }))
            case .blackWhite:
                ValueSlider(label: "Reds", value: $s.bwReds, range: -200...300, unit: "%", onCommit: onCommit)
                ValueSlider(label: "Yellows", value: $s.bwYellows, range: -200...300, unit: "%", onCommit: onCommit)
                ValueSlider(label: "Greens", value: $s.bwGreens, range: -200...300, unit: "%", onCommit: onCommit)
                ValueSlider(label: "Cyans", value: $s.bwCyans, range: -200...300, unit: "%", onCommit: onCommit)
                ValueSlider(label: "Blues", value: $s.bwBlues, range: -200...300, unit: "%", onCommit: onCommit)
                ValueSlider(label: "Magentas", value: $s.bwMagentas, range: -200...300, unit: "%", onCommit: onCommit)
                HStack {
                    Toggle2(label: "Tint", on: Binding(get: { s.bwTint }, set: { s.bwTint = $0; onCommit() }))
                    ColorWell(color: $s.bwTintColor, size: 18, onCommit: onCommit)
                }
            case .photoFilter:
                HStack {
                    Menu("Presets") {
                        Button("Warming Filter (85)") { s.filterColor = RGBA(hex: "EC8A00")!; onCommit() }
                        Button("Warming Filter (81)") { s.filterColor = RGBA(hex: "EBB113")!; onCommit() }
                        Button("Cooling Filter (80)") { s.filterColor = RGBA(hex: "006DFF")!; onCommit() }
                        Button("Cooling Filter (82)") { s.filterColor = RGBA(hex: "00B5FF")!; onCommit() }
                        Button("Sepia") { s.filterColor = RGBA(hex: "AC7A33")!; onCommit() }
                        Button("Underwater") { s.filterColor = RGBA(hex: "00C2B1")!; onCommit() }
                    }.frame(width: 100)
                    ColorWell(color: $s.filterColor, size: 18, onCommit: onCommit)
                }
                ValueSlider(label: "Density", value: $s.density, range: 1...100, unit: "%", onCommit: onCommit)
                Toggle2(label: "Preserve Luminosity", on: Binding(get: { s.preserveLuminosity }, set: { s.preserveLuminosity = $0; onCommit() }))
            case .channelMixer:
                Picker("Output", selection: $channel) { Text("Red").tag(0); Text("Green").tag(1); Text("Blue").tag(2) }.pickerStyle(.segmented)
                let row = channel == 0 ? $s.mixRed : channel == 1 ? $s.mixGreen : $s.mixBlue
                ValueSlider(label: "Red", value: row[0], range: -200...200, unit: "%", onCommit: onCommit)
                ValueSlider(label: "Green", value: row[1], range: -200...200, unit: "%", onCommit: onCommit)
                ValueSlider(label: "Blue", value: row[2], range: -200...200, unit: "%", onCommit: onCommit)
                ValueSlider(label: "Constant", value: row[3], range: -200...200, unit: "%", onCommit: onCommit)
                Toggle2(label: "Monochrome", on: Binding(get: { s.monochrome }, set: { s.monochrome = $0; onCommit() }))
            case .invert:
                Text("Inverts the colors below.").foregroundStyle(Theme.textDim)
            case .desaturate:
                Text("Removes color.").foregroundStyle(Theme.textDim)
            case .posterize:
                ValueSlider(label: "Levels", value: $s.posterizeLevels, range: 2...255, onCommit: onCommit)
            case .threshold:
                if let d = doc { HistogramView(hist: HistogramCache.get(d), channel: 3).frame(height: 70) }
                ValueSlider(label: "Threshold", value: $s.thresholdLevel, range: 1...255, onCommit: onCommit)
            case .gradientMap:
                GradientSwatch(gradient: s.gradient, reverse: s.gradientReverse).frame(height: 18)
                GradientPresetGrid(selected: Binding(get: { s.gradient }, set: { s.gradient = $0; onCommit() }))
                GradientStopsEditor(gradient: Binding(get: { s.gradient }, set: { s.gradient = $0 }), onCommit: onCommit)
                Toggle2(label: "Reverse", on: Binding(get: { s.gradientReverse }, set: { s.gradientReverse = $0; onCommit() }))
            case .selectiveColor:
                Picker("Colors", selection: $selColor) {
                    ForEach(Array(["Reds", "Yellows", "Greens", "Cyans", "Blues", "Magentas", "Whites", "Neutrals", "Blacks"].enumerated()), id: \.offset) { i, n in Text(tr(n)).tag(i) }
                }
                let e = $s.selective[selColor]
                ValueSlider(label: "Cyan", value: e.cyan, range: -100...100, unit: "%", onCommit: onCommit)
                ValueSlider(label: "Magenta", value: e.magenta, range: -100...100, unit: "%", onCommit: onCommit)
                ValueSlider(label: "Yellow", value: e.yellow, range: -100...100, unit: "%", onCommit: onCommit)
                ValueSlider(label: "Black", value: e.black, range: -100...100, unit: "%", onCommit: onCommit)
                Picker("", selection: Binding(get: { s.selectiveAbsolute }, set: { s.selectiveAbsolute = $0; onCommit() })) {
                    Text("Relative").tag(false); Text("Absolute").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
            case .shadowsHighlights:
                ValueSlider(label: "Shadows", value: $s.shAmountShadows, range: 0...100, unit: "%", onCommit: onCommit)
                ValueSlider(label: "Highlights", value: $s.shAmountHighlights, range: 0...100, unit: "%", onCommit: onCommit)
                ValueSlider(label: "Radius", value: $s.shRadius, range: 1...100, unit: "px", onCommit: onCommit)
            case .colorLookup:
                Picker("Look", selection: Binding(get: { s.lookName }, set: { s.lookName = $0; onCommit() })) {
                    ForEach(AdjustmentSettings.lookNames, id: \.self) { Text(tr($0)).tag($0) }
                }
            case .replaceColor:
                ReplaceColorControls(s: $s, doc: doc, onCommit: onCommit)
            case .matchColor:
                MatchColorControls(s: $s, doc: doc, onCommit: onCommit)
            case .hdrToning:
                HDRToningControls(s: $s, doc: doc, onCommit: onCommit)
            case .colorWB, .clarity, .dehaze, .grain, .light:
                EditsAdjustmentControls(s: $s, onCommit: onCommit)
            }
        }
        .font(Theme.font)
    }

    /// Latest settings (the Properties panel binding may hold a stale snapshot when an eyedropper fires later).
    var currentSettings: AdjustmentSettings {
        if let a = doc?.activeLayer?.adjustment, a.kind == s.kind { return a }
        return s
    }

    // MARK: Levels

    var levels: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Channel", selection: $channel) { Text("RGB").tag(0); Text("Red").tag(1); Text("Green").tag(2); Text("Blue").tag(3) }.pickerStyle(.segmented)
            let lc = $s.levels[channel]
            ZStack(alignment: .bottom) {
                if let d = doc { HistogramView(hist: HistogramCache.get(d), channel: channel == 0 ? 3 : channel - 1) }
            }
            .frame(height: 90)
            LevelsInputSlider(ch: lc, onCommit: onCommit).frame(height: 14)
            HStack {
                NumberField(label: "", value: lc.inBlack, width: 36, onCommit: onCommit)
                Spacer()
                NumberField(label: "", value: lc.gamma, width: 40, format: "%.2f", onCommit: onCommit)
                Spacer()
                NumberField(label: "", value: lc.inWhite, width: 36, onCommit: onCommit)
            }
            Caption("Output Levels")
            LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing).frame(height: 8)
            HStack {
                NumberField(label: "", value: lc.outBlack, width: 36, onCommit: onCommit)
                Spacer()
                NumberField(label: "", value: lc.outWhite, width: 36, onCommit: onCommit)
            }
            HStack {
                Button("Auto") {
                    guard let d = doc else { return }
                    let h = HistogramCache.get(d)
                    for c in 0..<3 {
                        let (lo, hi) = Histogram.clipPoints(h[c])
                        s.levels[c + 1].inBlack = Double(lo); s.levels[c + 1].inWhite = Double(hi)
                    }
                    onCommit()
                }.buttonStyle(PanelButtonStyle())
                Button("Reset") { s.levels = Array(repeating: LevelsChannel(), count: 4); onCommit() }.buttonStyle(PanelButtonStyle())
                Spacer()
                DropperButtons(prefix: "levels", doc: doc) { k, c in
                    var cur = currentSettings
                    AdjustmentDroppers.applyLevels(k, color: c, to: &cur)
                    s = cur
                    onCommit()
                }
            }
        }
    }

    // MARK: Curves

    var curves: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Channel", selection: $channel) { Text("RGB").tag(0); Text("Red").tag(1); Text("Green").tag(2); Text("Blue").tag(3) }.pickerStyle(.segmented)
            CurveEditor(curve: $s.curves[channel], hist: doc.map { HistogramCache.get($0) }, channel: channel,
                        color: [Color.white, .red, .green, .blue][channel], onCommit: onCommit)
                .aspectRatio(1, contentMode: .fit)
            HStack {
                Menu("Preset") {
                    Button("Default") { s.curves = Array(repeating: CurvePoints(), count: 4); onCommit() }
                    Button("Increase Contrast") { s.curves[0].points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.2), CGPoint(x: 0.75, y: 0.8), CGPoint(x: 1, y: 1)]; onCommit() }
                    Button("Strong Contrast") { s.curves[0].points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.15), CGPoint(x: 0.75, y: 0.87), CGPoint(x: 1, y: 1)]; onCommit() }
                    Button("Lighter") { s.curves[0].points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.45, y: 0.6), CGPoint(x: 1, y: 1)]; onCommit() }
                    Button("Darker") { s.curves[0].points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.55, y: 0.4), CGPoint(x: 1, y: 1)]; onCommit() }
                    Button("Negative") { s.curves[0].points = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0)]; onCommit() }
                    Button("Cross Process") {
                        s.curves[1].points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.3, y: 0.2), CGPoint(x: 0.7, y: 0.85), CGPoint(x: 1, y: 1)]
                        s.curves[2].points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.3, y: 0.25), CGPoint(x: 0.7, y: 0.8), CGPoint(x: 1, y: 1)]
                        s.curves[3].points = [CGPoint(x: 0, y: 0.12), CGPoint(x: 1, y: 0.88)]
                        onCommit()
                    }
                }.frame(width: 90)
                Button("Auto") {
                    guard let d = doc else { return }
                    AdjustmentDroppers.autoCurves(HistogramCache.get(d), &s)
                    onCommit()
                }.buttonStyle(PanelButtonStyle())
                Spacer()
                DropperButtons(prefix: "curves", doc: doc) { k, c in
                    var cur = currentSettings
                    AdjustmentDroppers.applyCurves(k, color: c, to: &cur)
                    s = cur
                    onCommit()
                }
            }
            Text("Click to add points, drag off to remove").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
    }
}

struct LevelsInputSlider: View {
    @Binding var ch: LevelsChannel
    var onCommit: () -> Void

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let bx = ch.inBlack / 255 * w, wx = ch.inWhite / 255 * w
            // gamma position: midpoint shifted
            let gt = pow(0.5, ch.gamma)
            let gx = bx + (wx - bx) * gt
            ZStack(alignment: .topLeading) {
                triangle(.black).position(x: bx, y: 7)
                    .gesture(DragGesture().onChanged { v in ch.inBlack = clamp(Double(v.location.x / w * 255).rounded(), 0, ch.inWhite - 2) }.onEnded { _ in onCommit() })
                triangle(Color(white: 0.5)).position(x: gx, y: 7)
                    .gesture(DragGesture().onChanged { v in
                        let t = clamp(Double((v.location.x - bx) / max(1, wx - bx)), 0.01, 0.99)
                        ch.gamma = clamp(log(t) / log(0.5), 0.1, 9.99)
                    }.onEnded { _ in onCommit() })
                triangle(.white).position(x: wx, y: 7)
                    .gesture(DragGesture().onChanged { v in ch.inWhite = clamp(Double(v.location.x / w * 255).rounded(), ch.inBlack + 2, 255) }.onEnded { _ in onCommit() })
            }
        }
    }

    func triangle(_ c: Color) -> some View {
        Path { p in p.move(to: CGPoint(x: 6, y: 0)); p.addLine(to: CGPoint(x: 12, y: 12)); p.addLine(to: CGPoint(x: 0, y: 12)); p.closeSubpath() }
            .fill(c)
            .overlay(Path { p in p.move(to: CGPoint(x: 6, y: 0)); p.addLine(to: CGPoint(x: 12, y: 12)); p.addLine(to: CGPoint(x: 0, y: 12)); p.closeSubpath() }.stroke(Color(white: 0.6), lineWidth: 0.5))
            .frame(width: 12, height: 12)
            .contentShape(Rectangle().inset(by: -4))
    }
}

struct CurveEditor: View {
    @Binding var curve: CurvePoints
    var hist: [[Int]]?
    var channel: Int
    var color: Color
    var onCommit: () -> Void
    @State private var dragIndex: Int?
    @State private var local: [CGPoint]?

    var body: some View {
        GeometryReader { g in
            let sz = g.size
            ZStack {
                if let h = hist { HistogramView(hist: h, channel: channel == 0 ? 3 : channel - 1).opacity(0.5) } else { Theme.fieldBG }
                Path { p in
                    for i in 1..<4 {
                        let x = sz.width * CGFloat(i) / 4, y = sz.height * CGFloat(i) / 4
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: sz.height))
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: sz.width, y: y))
                    }
                }.stroke(Color(white: 0.3), lineWidth: 0.5)
                Path { p in p.move(to: CGPoint(x: 0, y: sz.height)); p.addLine(to: CGPoint(x: sz.width, y: 0)) }.stroke(Color(white: 0.35), lineWidth: 0.5)
                let lut = CurvePoints(points: local ?? curve.points).lut(128)
                Path { p in
                    for (i, v) in lut.enumerated() {
                        let pt = CGPoint(x: CGFloat(i) / 127 * sz.width, y: (1 - v) * sz.height)
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }.stroke(color, lineWidth: 1.5)
                ForEach(Array((local ?? curve.points).enumerated()), id: \.offset) { i, pt in
                    Rectangle().fill(dragIndex == i ? color : Color.clear)
                        .overlay(Rectangle().stroke(color, lineWidth: 1))
                        .frame(width: 7, height: 7)
                        .position(x: pt.x * sz.width, y: (1 - pt.y) * sz.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let p = CGPoint(x: clamp(v.location.x / sz.width, 0, 1), y: clamp(1 - v.location.y / sz.height, 0, 1))
                var pts = local ?? curve.points
                if dragIndex == nil {
                    if let i = pts.firstIndex(where: { abs($0.x - p.x) * sz.width < 10 && abs($0.y - p.y) * sz.height < 10 }) {
                        dragIndex = i
                    } else {
                        pts.append(p)
                        pts.sort { $0.x < $1.x }
                        dragIndex = pts.firstIndex(of: p)
                    }
                }
                guard let i = dragIndex, i >= 0, i < pts.count else { return }
                if (v.location.x < -20 || v.location.x > sz.width + 20 || v.location.y < -20 || v.location.y > sz.height + 20) && pts.count > 2 {
                    pts.remove(at: i)
                    dragIndex = -1
                } else {
                    var np = p
                    let lo = i > 0 ? pts[i - 1].x + 0.01 : 0
                    let hi = i < pts.count - 1 ? pts[i + 1].x - 0.01 : 1
                    np.x = clamp(np.x, lo, hi)
                    pts[i] = np
                }
                local = pts
                curve.points = pts
            }.onEnded { _ in dragIndex = nil; local = nil; onCommit() })
        }
    }
}
