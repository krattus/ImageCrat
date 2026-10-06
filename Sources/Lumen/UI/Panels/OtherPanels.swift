import SwiftUI
import ImageCratCore

// MARK: - Color

struct ColorPanel: View {
    @Bindable var app = AppModel.shared
    @State private var editingBG = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color(nsColor: app.background.nsColor)).frame(width: 26, height: 26)
                        .overlay(Rectangle().stroke(editingBG ? Theme.accent : Color(white: 0.5), lineWidth: editingBG ? 2 : 1))
                        .offset(x: 12, y: 12)
                        .onTapGesture { editingBG = true }
                    Rectangle().fill(Color(nsColor: app.foreground.nsColor)).frame(width: 26, height: 26)
                        .overlay(Rectangle().stroke(!editingBG ? Theme.accent : Color(white: 0.5), lineWidth: !editingBG ? 2 : 1))
                        .onTapGesture { editingBG = false }
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    let c = editingBG ? app.background : app.foreground
                    Text("#\(c.hex)").font(Theme.mono)
                    Text("R \(c.r8)  G \(c.g8)  B \(c.b8)").font(Theme.mono).foregroundStyle(Theme.textDim)
                    let hsb = c.hsb
                    Text("H \(Int(hsb.h * 360))°  S \(Int(hsb.s * 100))%  B \(Int(hsb.b * 100))%").font(Theme.mono).foregroundStyle(Theme.textDim)
                }
            }
            let binding = editingBG ? $app.background : $app.foreground
            HueSatBrightSliders(color: binding)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)   // (fits Essentials' colour group without scrolling)
    }
}

struct HueSatBrightSliders: View {
    @Binding var color: RGBA
    var body: some View {
        let hsb = color.hsb
        VStack(spacing: 6) {
            GradientTrack(colors: stride(from: 0.0, through: 1, by: 1.0 / 12).map { RGBA(h: $0, s: 1, v: 1) }, value: hsb.h) { color = RGBA(h: $0, s: max(0.001, hsb.s), v: hsb.b, a: color.a) }
            GradientTrack(colors: [RGBA(h: hsb.h, s: 0, v: hsb.b), RGBA(h: hsb.h, s: 1, v: hsb.b)], value: hsb.s) { color = RGBA(h: hsb.h, s: $0, v: hsb.b, a: color.a) }
            GradientTrack(colors: [RGBA.black, RGBA(h: hsb.h, s: hsb.s, v: 1)], value: hsb.b) { color = RGBA(h: hsb.h, s: hsb.s, v: $0, a: color.a) }
            GradientTrack(colors: [RGBA(r: 0, g: color.g, b: color.b), RGBA(r: 1, g: color.g, b: color.b)], value: color.r) { color.r = $0 }
            GradientTrack(colors: [RGBA(r: color.r, g: 0, b: color.b), RGBA(r: color.r, g: 1, b: color.b)], value: color.g) { color.g = $0 }
            GradientTrack(colors: [RGBA(r: color.r, g: color.g, b: 0), RGBA(r: color.r, g: color.g, b: 1)], value: color.b) { color.b = $0 }
        }
    }
}

struct GradientTrack: View {
    let colors: [RGBA]
    let value: Double
    let onChange: (Double) -> Void
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                LinearGradient(colors: colors.map { Color(nsColor: $0.nsColor) }, startPoint: .leading, endPoint: .trailing)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                Path { p in p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 5, y: 6)); p.addLine(to: CGPoint(x: -5, y: 6)); p.closeSubpath() }
                    .fill(Color.white)
                    .frame(width: 1, height: 6)
                    .offset(x: CGFloat(value) * g.size.width, y: 6)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in onChange(clamp(Double(v.location.x / g.size.width), 0, 1)) })
        }
        .frame(height: 10)
    }
}

// MARK: - Swatches

struct SwatchesPanel: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if !app.recentColors.isEmpty {
                    Caption("Recent")
                    swatchGrid(app.recentColors, removable: false)
                }
                Caption("Swatches")
                swatchGrid(app.swatches, removable: true)
                Button { app.swatches.append(app.foreground) } label: { Label("Add Foreground", systemImage: "plus") }.buttonStyle(PanelButtonStyle())
                SwatchLibraryControls()   // libraries, .aco / .ase import (Imaging module)
                ArtistSwatchSections()    // global colours and swatch groups (Artist module)
            }.padding(10)
        }
    }

    func swatchGrid(_ colors: [RGBA], removable: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 18, maximum: 18), spacing: 3)], alignment: .leading, spacing: 3) {   // (as many columns as fit)
            ForEach(Array(colors.enumerated()), id: \.offset) { i, c in
                Rectangle().fill(Color(nsColor: c.nsColor))
                    .frame(width: 18, height: 18)
                    .overlay(Rectangle().stroke(Color(white: 0.25), lineWidth: 0.5))
                    .onTapGesture {
                        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.option) { app.background = c } else { app.foreground = c }
                    }
                    .contextMenu { if removable { Button("Delete Swatch") { app.swatches.remove(at: i) } } }
                    .help("#\(c.hex)")
            }
        }
    }
}

struct GradientsPanel: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                GradientPresetGrid(selected: $app.gradientTool.gradient)
                Button("Edit Gradient…") { app.dialog = .gradientEditor }.buttonStyle(PanelButtonStyle())
                Text("Click a preset to use it with the Gradient Tool (G).").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }.padding(10)
        }
    }
}

struct PatternsPanel: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 40), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(PatternDef.builtIn + app.customPatterns) { p in
                        PatternThumb(pattern: p).frame(width: 40, height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(app.bucket.patternID == p.id ? Theme.accent : .clear, lineWidth: 2))
                            .onTapGesture { app.bucket.patternID = p.id }
                            .help(tr(p.name))
                    }
                }
                Button("Define Pattern from Selection") { AppActions.definePattern() }.buttonStyle(PanelButtonStyle())
            }.padding(10)
        }
    }
}

// MARK: - History

struct HistoryPanel: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        if let d = app.activeDocument {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        HistorySnapshotsSection(doc: d)
                        ForEach(Array(d.history.enumerated()), id: \.element.id) { i, h in
                            HStack(spacing: 6) {
                                Button { app.historyBrushSource = i } label: {
                                    Image(systemName: (app.historyBrushSource ?? 0) == i ? "paintbrush.fill" : "paintbrush")
                                        .font(.system(size: 9)).foregroundStyle((app.historyBrushSource ?? 0) == i ? Theme.text : Theme.textFaint)
                                }.buttonStyle(.plain).help("Set the source for the History Brush")
                                Image(systemName: icon(h.name)).font(.system(size: 10)).foregroundStyle(Theme.textDim).frame(width: 16)
                                Text(tr(h.name)).font(Theme.font).foregroundStyle(i > d.historyIndex ? Theme.textFaint : Theme.text)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(i == d.historyIndex ? Theme.selection : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { d.jumpToHistory(i) }
                            .id(h.id)
                        }
                    }
                }
                .onChange(of: d.historyIndex) { _, _ in
                    if d.history.indices.contains(d.historyIndex) { proxy.scrollTo(d.history[d.historyIndex].id) }
                }
            }
        } else {
            Text("No document").foregroundStyle(Theme.textFaint).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func icon(_ n: String) -> String {
        let l = n.lowercased()
        if l.contains("brush") || l.contains("pencil") { return "paintbrush" }
        if l.contains("erase") { return "eraser" }
        if l.contains("select") || l.contains("marquee") || l.contains("lasso") || l.contains("wand") { return "rectangle.dashed" }
        if l.contains("layer") { return "square.3.layers.3d" }
        if l.contains("transform") || l.contains("move") { return "arrow.up.and.down.and.arrow.left.and.right" }
        if l.contains("type") || l.contains("text") { return "textformat" }
        if l.contains("fill") || l.contains("gradient") { return "drop.fill" }
        if l.contains("crop") { return "crop" }
        if l.contains("open") || l.contains("new") { return "doc" }
        return "circle.dotted"
    }
}

// MARK: - Navigator

struct NavigatorPanel: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        if let d = app.activeDocument {
            VStack(spacing: 6) {
                GeometryReader { g in
                    let img = Thumbnails.shared.composite(d, size: 110)
                    let W = CGFloat(d.state.width), H = CGFloat(d.state.height)
                    let s = min(g.size.width / W, g.size.height / H)
                    let tw = W * s, th = H * s
                    let ox = (g.size.width - tw) / 2, oy = (g.size.height - th) / 2
                    ZStack(alignment: .topLeading) {
                        CheckerBackground(size: 4).frame(width: tw, height: th).offset(x: ox, y: oy)
                        if let img { Image(decorative: img, scale: 2).resizable().frame(width: tw, height: th).offset(x: ox, y: oy) }
                        if let c = AppActions.canvas {
                            let r0 = c.viewToDoc(.zero), r1 = c.viewToDoc(CGPoint(x: c.bounds.width, y: c.bounds.height))
                            let vr = CGRect(x: ox + r0.x * s, y: oy + r0.y * s, width: (r1.x - r0.x) * s, height: (r1.y - r0.y) * s)
                            Rectangle().stroke(Color.red, lineWidth: 1.5).frame(width: vr.width, height: vr.height).offset(x: vr.minX, y: vr.minY)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        guard let c = AppActions.canvas else { return }
                        let dp = CGPoint(x: (v.location.x - ox) / s, y: (v.location.y - oy) / s)
                        let z = CGFloat(d.zoom)
                        d.viewOffset = CGPoint(x: c.bounds.midX - dp.x * z, y: c.bounds.midY - dp.y * z)
                        c.setNeedsRender()
                    })
                }
                .clipped()
                HStack(spacing: 6) {
                    Button { AppActions.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(.plain)
                    Slider(value: Binding(get: { log2(d.zoom) }, set: { AppActions.canvas?.setZoom(pow(2, $0)) }), in: -6...6).controlSize(.mini)
                    Button { AppActions.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(.plain)
                    Text(tr(ZoomMath.format(d.zoom))).font(Theme.mono).frame(width: 44)
                }
                .font(Theme.font)
            }
            .padding(8)
            .id("\(d.viewOffset.x)-\(d.viewOffset.y)-\(d.zoom)-\(d.revision)")
        } else {
            Text("No document").foregroundStyle(Theme.textFaint).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Histogram

struct HistogramPanel: View {
    @Bindable var app = AppModel.shared
    @State private var channel = 4
    var body: some View {
        if let d = app.activeDocument {
            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: $channel) {
                    Text("Colors").tag(4); Text("RGB").tag(3); Text("Red").tag(0); Text("Green").tag(1); Text("Blue").tag(2)
                }.labelsHidden().segmentedOrMenu()
                let h = HistogramCache.get(d)
                HistogramView(hist: h, channel: channel).frame(height: 100)
                let stats = statistics(h[channel == 4 ? 3 : channel])
                HStack {
                    VStack(alignment: .leading) {
                        Text("Mean: \(String(format: "%.2f", stats.0))")
                        Text("Std Dev: \(String(format: "%.2f", stats.1))")
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("Median: \(stats.2)")
                        Text("Pixels: \(stats.3)")
                    }
                }.font(Theme.fontSmall).foregroundStyle(Theme.textDim)
            }.padding(8)
        } else {
            Text("No document").foregroundStyle(Theme.textFaint).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func statistics(_ h: [Int]) -> (Double, Double, Int, Int) {
        let n = h.reduce(0, +)
        guard n > 0 else { return (0, 0, 0, 0) }
        var sum = 0.0
        for i in 0..<256 { sum += Double(i * h[i]) }
        let mean = sum / Double(n)
        var v = 0.0
        for i in 0..<256 { v += Double(h[i]) * pow(Double(i) - mean, 2) }
        var acc = 0, med = 0
        for i in 0..<256 { acc += h[i]; if acc >= n / 2 { med = i; break } }
        return (mean, sqrt(v / Double(n)), med, n)
    }
}

// MARK: - Info

struct InfoPanel: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let d = app.activeDocument {
                let p = app.cursorDocPoint
                let c = p.flatMap { pixelColor(d, $0) }
                WrappingHStack(alignment: .top) {   // (Lab and the swatch go under RGB / CMYK in a narrow column)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("R: \(c.map { "\($0.r8)" } ?? "")")
                        Text("G: \(c.map { "\($0.g8)" } ?? "")")
                        Text("B: \(c.map { "\($0.b8)" } ?? "")")
                        Text("A: \(c.map { "\($0.a8)" } ?? "")")
                    }.frame(width: 70, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        if let c {
                            let k = ColorConvert.cmyk(c, profile: app.proof.profileName)
                            Text("C: \(Int(k.0 * 100))%"); Text("M: \(Int(k.1 * 100))%"); Text("Y: \(Int(k.2 * 100))%"); Text("K: \(Int(k.3 * 100))%")
                        }
                    }.frame(width: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        if let c {
                            let l = ColorConvert.lab(c)
                            Text("L: \(Int(l.0.rounded()))"); Text("a: \(Int(l.1.rounded()))"); Text("b: \(Int(l.2.rounded()))")
                        }
                    }
                    if let c { Rectangle().fill(Color(nsColor: c.nsColor)).frame(width: 30, height: 30).overlay(Rectangle().stroke(Color.gray, lineWidth: 0.5)) }
                }
                Divider()
                // (measured from the active artboard's top-left corner, like the rulers)
                let q = p.map { ArtboardCoords.display($0, d) }
                HStack {
                    Text("X: \(q.map { "\(Int($0.x))" } ?? "")").frame(width: 70, alignment: .leading)
                    Text("Y: \(q.map { "\(Int($0.y))" } ?? "")")
                }
                if let b = d.state.selectionBounds {
                    Text("Selection W: \(b.width)  H: \(b.height)")
                }
                ColorSamplerInfo(doc: d)
                Text("Doc: \(d.state.width) × \(d.state.height) px, \(d.state.allLayers.count) layers").foregroundStyle(Theme.textDim)
                Text("\(tr(d.state.colorMode.short))/\(d.state.bitDepth.rawValue) · \(ColorProfiles.isSRGB(d.state.profileName) ? ColorProfiles.sRGBName : d.state.profileName)").foregroundStyle(Theme.textDim).lineLimit(1)
                Text("History: \(d.history.count) states").foregroundStyle(Theme.textDim)
            }
        }
        .font(Theme.mono)
        .foregroundStyle(Theme.text)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func pixelColor(_ d: Document, _ p: CGPoint) -> RGBA? {
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        let img = Compositor.shared.composite(d)
        var px = [UInt8](repeating: 0, count: 4)
        let r = sp.ciRect(IRect(x: Int(p.x), y: Int(p.y), width: 1, height: 1))
        RenderEngine.readbackContext.render(img, toBitmap: &px, rowBytes: 4, bounds: r, format: .RGBA8, colorSpace: sRGBSpace)
        let a = Double(px[3])
        if a == 0 { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        return RGBA(r: Double(px[0]) / a, g: Double(px[1]) / a, b: Double(px[2]) / a, a: a / 255)
    }
}

// MARK: - Channels

struct ChannelsPanel: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        if let d = app.activeDocument {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        switch d.state.colorMode {
                        case .cmyk:
                            channelRow(d, name: "CMYK", shortcut: "⌘2", channel: .composite, img: Thumbnails.shared.composite(d, size: 30))
                            ForEach(Array(["Cyan", "Magenta", "Yellow", "Black"].enumerated()), id: \.offset) { i, n in
                                channelRow(d, name: n, shortcut: "⌘\(i + 3)", channel: .ink(i), img: Thumbnails.shared.composite(d, size: 30))
                            }
                        case .lab:
                            channelRow(d, name: "Lab", shortcut: "⌘2", channel: .composite, img: Thumbnails.shared.composite(d, size: 30))
                            ForEach(Array(["Lightness", "a", "b"].enumerated()), id: \.offset) { i, n in
                                channelRow(d, name: n, shortcut: "⌘\(i + 3)", channel: .lab(i), img: Thumbnails.shared.composite(d, size: 30))
                            }
                        case .grayscale:
                            channelRow(d, name: "Gray", shortcut: "⌘2", channel: .composite, img: Thumbnails.shared.composite(d, size: 30))
                        case .rgb:
                            channelRow(d, name: "RGB", shortcut: "⌘2", channel: .composite, img: Thumbnails.shared.composite(d, size: 30))
                            channelRow(d, name: "Red", shortcut: "⌘3", channel: .red, img: Thumbnails.shared.composite(d, size: 30, channel: 0))
                            channelRow(d, name: "Green", shortcut: "⌘4", channel: .green, img: Thumbnails.shared.composite(d, size: 30, channel: 1))
                            channelRow(d, name: "Blue", shortcut: "⌘5", channel: .blue, img: Thumbnails.shared.composite(d, size: 30, channel: 2))
                        case .bitmap, .indexed, .duotone, .multichannel:
                            if let n = ImagingChannelRows.compositeName(d) { channelRow(d, name: n, shortcut: "⌘2", channel: .composite, img: Thumbnails.shared.composite(d, size: 30)) }
                        }
                        ImagingChannelRows(doc: d)   // spot channels (Imaging module)
                        if let sel = d.state.selection, d.quickMask {
                            channelRow(d, name: "Quick Mask", shortcut: "", channel: .composite, img: Thumbnails.shared.channel(sel, doc: d, key: "qm", size: 30))
                        }
                        ForEach(d.state.alphaChannels.filter { !d.state.isSpotChannel($0.id) }) { ch in
                            channelRow(d, name: ch.name, shortcut: "", channel: .alpha(ch.id), img: Thumbnails.shared.channel(ch.buffer, doc: d, key: ch.id.uuidString, size: 30))
                                .contextMenu {
                                    Button("Load as Selection") { AppActions.loadSelection(ch.id) }
                                    Button("Add to Selection") { AppActions.loadSelection(ch.id, mode: .add) }
                                    Button("Delete Channel") { AppActions.deleteChannel(ch.id) }
                                }
                        }
                    }
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 4) {
                    Spacer()
                    IconButton(symbol: "circle.dashed", help: "Load channel as selection") { if case .alpha(let id) = d.viewChannel { AppActions.loadSelection(id) } }
                    IconButton(symbol: "square.and.arrow.down", help: "Save selection as channel") { AppActions.saveSelection() }
                    IconButton(symbol: "drop", help: "New Spot Channel…") { DialogRegistry.show("imaging.spot") }
                    IconButton(symbol: "trash", help: "Delete channel") { if case .alpha(let id) = d.viewChannel { AppActions.deleteChannel(id) } }
                }.frame(height: 30).background(Theme.panelHeader)
            }
        } else {
            Text("No document").foregroundStyle(Theme.textFaint).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func channelRow(_ d: Document, name: String, shortcut: String, channel: ViewChannel, img: CGImage?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "eye").font(.system(size: 10)).foregroundStyle(d.viewChannel == channel || (d.viewChannel == .composite && channel != .composite && !isAlpha(channel)) ? Theme.text : Theme.textFaint).frame(width: 18)
            ZStack {
                Color.black
                if let img { Image(decorative: img, scale: 2).resizable().aspectRatio(contentMode: .fit) }
            }.frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 2))
            Text(tr(name)).font(Theme.font)
            Spacer()
            Text(tr(shortcut)).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(d.viewChannel == channel ? Theme.selection : Color.clear)
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { if case .alpha(let id) = channel { AppActions.loadSelection(id) } })
        .simultaneousGesture(TapGesture().onEnded { d.viewChannel = channel; d.setNeedsRender() })
    }

    func isAlpha(_ c: ViewChannel) -> Bool { if case .alpha = c { return true }; return false }
}

// MARK: - Paths

/// The Paths panel: rows with thumbnails, Work Path / saved paths, conversions (Tools/PathsWorkflow.swift).
struct PathsPanel: View {
    var body: some View { PathsPanelView() }
}

struct PathThumb: View {
    let path: VectorPath
    let w: Int, h: Int
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.9)))
            let s = min(size.width / CGFloat(w), size.height / CGFloat(h))
            var t = CGAffineTransform(scaleX: s, y: s).translatedBy(x: (size.width / s - CGFloat(w)) / 2, y: (size.height / s - CGFloat(h)) / 2)
            let rp = path.resolved; if let p = rp.path.copy(using: &t) { ctx.fill(Path(p), with: .color(Color(white: 0.3)), style: FillStyle(eoFill: rp.evenOdd)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}
