import SwiftUI
import Observation
import ImageCratCore

// Stroke Options for shape layers and the shape tools: presets (built-in and saved), alignment, caps, corners, miter
// limit, and a dash editor with any number of dash / gap pairs (in stroke widths or px), a dash offset and dashes
// aligned to corners — with a live preview drawn by the real shape renderer.

// MARK: - Presets

struct StrokePreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Dash / gap lengths in stroke widths (empty = solid).
    var dash: [Double] = []
    var cap: LineCapStyle = .butt
    var join: LineJoinStyle = .miter
    var alignment: StrokeAlignment? = nil
    var dashAlignment: DashAlignment? = nil
    var miterLimit: Double? = nil
    var dashPhase: Double? = nil

    init(id: UUID = UUID(), name: String, dash: [Double] = [], cap: LineCapStyle = .butt, join: LineJoinStyle = .miter, alignment: StrokeAlignment? = nil,
         dashAlignment: DashAlignment? = nil, miterLimit: Double? = nil, dashPhase: Double? = nil) {
        self.id = id; self.name = name; self.dash = dash; self.cap = cap; self.join = join; self.alignment = alignment
        self.dashAlignment = dashAlignment; self.miterLimit = miterLimit; self.dashPhase = dashPhase
    }

    /// A preset holding everything about `s` except its paint and width.
    init(name: String, from s: StrokeStyle) {
        self.init(name: name, dash: s.dash, cap: s.cap, join: s.join, alignment: s.alignment, dashAlignment: s.dashAlignment, miterLimit: s.miterLimit, dashPhase: s.dashPhase)
    }

    func apply(to s: inout StrokeStyle) {
        s.dash = dash; s.cap = cap; s.join = join
        if let a = alignment { s.alignment = a }
        s.dashAlignment = dashAlignment; s.miterLimit = miterLimit; s.dashPhase = dashPhase
    }

    func matches(_ s: StrokeStyle) -> Bool {
        var t = s
        apply(to: &t)
        return t == s
    }
}

@Observable
final class StrokePresetStore {
    static let shared = StrokePresetStore()
    static let defaultsKey = "Lumen.StrokePresets"

    private static func fixed(_ n: Int) -> UUID { UUID(uuidString: String(format: "5A0E5F11-0000-4000-8000-%012d", n))! }
    /// Photoshop's three (solid, dashed, dotted) and a few more.
    static let builtIn: [StrokePreset] = [
        StrokePreset(id: fixed(1), name: "Solid"),
        StrokePreset(id: fixed(2), name: "Dashed", dash: [4, 2]),
        StrokePreset(id: fixed(3), name: "Dotted", dash: [0, 2], cap: .round, join: .round),
        StrokePreset(id: fixed(4), name: "Long Dash", dash: [8, 3]),
        StrokePreset(id: fixed(5), name: "Dash Dot", dash: [4, 2, 0, 2], cap: .round, join: .round),
        StrokePreset(id: fixed(6), name: "Fine Dots", dash: [0, 1.5], cap: .round, join: .round),
        StrokePreset(id: fixed(7), name: "Corner Dashes", dash: [3, 2], dashAlignment: .corners),
        StrokePreset(id: fixed(8), name: "Stitches", dash: [2, 1.5], cap: .round, join: .round, dashAlignment: .corners),
    ]

    private(set) var saved: [StrokePreset] = []
    /// Saved presets go to the user defaults; automated runs (self tests, fuzzing, scripted runs) keep them in memory.
    @ObservationIgnored let persists: Bool

    init(persists: Bool = !StrokePresetStore.automated, data: Data? = nil) {
        self.persists = persists
        if let d = data ?? (persists ? UserDefaults.standard.data(forKey: Self.defaultsKey) : nil),
           let list = try? JSONDecoder().decode([StrokePreset].self, from: d) {
            saved = list
        }
    }

    static var automated: Bool {
        let a = CommandLine.arguments
        return a.contains { $0 == "--selftest" || $0 == "--perftest" || $0 == "--menu-fuzz" || $0.hasPrefix("--run-") }
            || ProcessInfo.processInfo.environment["LUMEN_AUTOMATION"] != nil
    }

    var all: [StrokePreset] { Self.builtIn + saved }
    func isBuiltIn(_ p: StrokePreset) -> Bool { Self.builtIn.contains { $0.id == p.id } }

    /// The saved presets as stored.
    var encoded: Data { (try? JSONEncoder().encode(saved)) ?? Data() }

    @discardableResult
    func save(name: String, from s: StrokeStyle) -> StrokePreset {
        let n = name.trimmingCharacters(in: .whitespaces)
        let p = StrokePreset(name: n.isEmpty ? "Stroke \(saved.count + 1)" : n, from: s)
        saved.append(p)
        persist()
        return p
    }

    func delete(_ id: UUID) {
        saved.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard persists else { return }
        UserDefaults.standard.set(encoded, forKey: Self.defaultsKey)
    }
}

// MARK: - Helpers

extension StrokeStyle {
    /// Sets the width; dashes typed in px keep their pixel lengths (they are stored in stroke widths).
    mutating func setWidth(_ w: Double) {
        guard w.isFinite else { return }
        let nw = max(0, w)
        if dashUnit == .pixels, width > 0, nw > 0 {
            let f = width / nw
            dash = dash.map { $0 * f }
            dashPhase = dashPhase.map { $0 * f }
        }
        width = nw
    }

    /// Dash / gap pairs (an odd-length pattern repeats, so it is shown doubled).
    var dashPairs: [(Double, Double)] {
        let d = dash.count % 2 == 1 ? dash + dash : dash
        return stride(from: 0, to: d.count, by: 2).map { (d[$0], d[$0 + 1]) }
    }

    mutating func setDashPairs(_ pairs: [(Double, Double)]) {
        dash = pairs.flatMap { [max(0, $0.0.isFinite ? $0.0 : 0), max(0, $0.1.isFinite ? $0.1 : 0)] }
    }
}

/// Renders stroke previews with the shape renderer (so the preview is exactly what the canvas draws).
enum StrokePreviewRenderer {
    enum Sample { case line, shapes }

    static func image(_ stroke: StrokeStyle, size: CGSize, sample: Sample, color: RGBA, scale: CGFloat = 2) -> CGImage? {
        let W = Int(size.width * scale), H = Int(size.height * scale)
        guard W > 0, H > 0, let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: scale, y: -scale)
        var st = stroke
        if case .color = st.paint {} else { st.paint = .color(color) }
        if case .color(let c) = st.paint, c.a < 0.2 { st.paint = .color(color) }
        let space = CanvasSpace(width: Int(size.width), height: Int(size.height))
        switch sample {
        case .line:
            st.width = Double(min(max(size.height * 0.28, 2), 6))
            st.alignment = .center
            let y = size.height / 2
            let p = VectorPath(subpaths: [Subpath(points: [PathPoint(CGPoint(x: 6, y: y)), PathPoint(CGPoint(x: size.width - 6, y: y))], closed: false)])
            ShapeRenderer.draw(ShapeContent(geometry: .path(p), fill: .none, stroke: st), in: ctx, space: space)
        case .shapes:
            // a rectangle (corners, alignment against its light fill), a triangle (sharp miters) and an open zigzag (caps)
            st.width = Double(min(max(stroke.width, 3), 8))
            let pad: CGFloat = 12
            let h = size.height - pad * 2
            let rect = ShapeContent(geometry: .rectangle(CGRect(x: pad, y: pad, width: h * 1.3, height: h), cornerRadius: 0),
                                    fill: .color(RGBA(gray: 0.82)), stroke: st)
            ShapeRenderer.draw(rect, in: ctx, space: space)
            let x0 = pad * 2 + h * 1.3
            let tri = ShapeContent(geometry: .polygon(CGRect(x: x0, y: pad, width: h * 0.9, height: h), sides: 3, starRatio: 1),
                                   fill: .color(RGBA(gray: 0.82)), stroke: st)
            ShapeRenderer.draw(tri, in: ctx, space: space)
            let x1 = x0 + h * 0.9 + pad
            let zig = VectorPath(subpaths: [Subpath(points: [
                PathPoint(CGPoint(x: x1, y: pad + h)), PathPoint(CGPoint(x: x1 + (size.width - pad - x1) * 0.33, y: pad)),
                PathPoint(CGPoint(x: x1 + (size.width - pad - x1) * 0.66, y: pad + h)), PathPoint(CGPoint(x: size.width - pad, y: pad)),
            ], closed: false)])
            var zs = st
            zs.alignment = .center
            ShapeRenderer.draw(ShapeContent(geometry: .path(zig), fill: .none, stroke: zs), in: ctx, space: space)
        }
        return ctx.makeImage()
    }
}

struct StrokePreviewImage: View {
    let stroke: StrokeStyle
    let sample: StrokePreviewRenderer.Sample
    var body: some View {
        GeometryReader { g in
            if let img = StrokePreviewRenderer.image(stroke, size: g.size, sample: sample, color: RGBA(gray: 0.92)) {
                Image(decorative: img, scale: 2).resizable().frame(width: g.size.width, height: g.size.height)
            }
        }
    }
}

// MARK: - Editor

/// Stroke Options: presets, alignment, caps, corners, miter limit, dashes. Used by the shape Properties and by the
/// shape tools' options bar.
struct StrokeOptionsEditor: View {
    @Binding var stroke: StrokeStyle
    var onCommit: () -> Void
    @Bindable private var store = StrokePresetStore.shared
    @State private var naming = false
    @State private var newName = ""
    @Environment(\.panelWidth) private var panelWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StrokePreviewImage(stroke: stroke, sample: .shapes)
                .frame(height: 64)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
                .help("Preview: rectangle and triangle show the alignment and corners, the zigzag the caps")
            presets
            HStack(spacing: 6) {
                Text("Align").foregroundStyle(Theme.textDim).frame(width: 52, alignment: .leading)
                ForEach(StrokeAlignment.allCases, id: \.self) { a in
                    IconButton(symbol: Self.symbol(a), help: "\(a.rawValue.capitalized): the stroke runs \(a == .center ? "centred on" : a.rawValue) the path",
                               active: stroke.alignment == a, size: 22) { stroke.alignment = a; onCommit() }
                }
            }
            HStack(spacing: 6) {
                Text("Caps").foregroundStyle(Theme.textDim).frame(width: 52, alignment: .leading)
                ForEach(LineCapStyle.allCases, id: \.self) { c in
                    capButton(c)
                }
            }
            HStack(spacing: 6) {
                Text("Corners").foregroundStyle(Theme.textDim).frame(width: 52, alignment: .leading)
                ForEach(LineJoinStyle.allCases, id: \.self) { j in
                    joinButton(j)
                }
            }
            if stroke.join == .miter {
                ValueSlider(label: "Miter Limit", value: Binding(get: { stroke.miterLimit ?? Double(StrokeGeometry.defaultMiterLimit) }, set: { stroke.miterLimit = max(1, min(500, $0)) }),
                            range: 1...100, format: "%.1f", labelWidth: 64, onCommit: onCommit)
                    .help("How far a sharp corner may stick out (in stroke widths) before it is bevelled")
            }
            Divider()
            Toggle(isOn: Binding(get: { !stroke.dash.isEmpty }, set: { on in
                stroke.dash = on ? (stroke.dash.isEmpty ? [4, 2] : stroke.dash) : []
                onCommit()
            })) { Text("Dashed Line") }.toggleStyle(.checkbox)
            if !stroke.dash.isEmpty { dashEditor }
        }
    }

    // MARK: Presets

    @ViewBuilder var presets: some View {
        let list = store.all
        HStack {
            Caption("Presets")
            Spacer()
            if let cur = list.first(where: { $0.matches(stroke) }), !store.isBuiltIn(cur) {
                Button { store.delete(cur.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Theme.textDim)
                    .help("Delete the saved preset “\(cur.name)”")
            }
            Button(naming ? "Cancel" : "Save…") { naming.toggle(); newName = "" }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .help("Save the current alignment, caps, corners and dashes as a preset")
        }
        if naming {
            HStack(spacing: 4) {
                TextField("Preset name", text: $newName).textFieldStyle(.roundedBorder).controlSize(.small)
                    .onSubmit { savePreset() }
                Button("Save") { savePreset() }.buttonStyle(PanelButtonStyle())
            }
        }
        // (three columns in a narrow panel column: four need 212 pt)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 50), spacing: 4), count: panelWidth < 240 ? 3 : 4), spacing: 4) {
            ForEach(list) { p in
                let on = p.matches(stroke)
                Button {
                    p.apply(to: &stroke)
                    onCommit()
                } label: {
                    VStack(spacing: 1) {
                        StrokePreviewImage(stroke: Self.sample(p), sample: .line).frame(height: 12)
                        Text(p.name).font(.system(size: 8)).foregroundStyle(Theme.textDim).lineLimit(1)
                    }
                    .padding(.vertical, 3).padding(.horizontal, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(on ? Theme.selection : Theme.fieldBG))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(p.name + (store.isBuiltIn(p) ? "" : " (saved)"))
            }
        }
    }

    static func sample(_ p: StrokePreset) -> StrokeStyle {
        var s = StrokeStyle(paint: .color(RGBA(gray: 0.92)), width: 3)
        p.apply(to: &s)
        return s
    }

    func savePreset() {
        store.save(name: newName, from: stroke)
        naming = false
        newName = ""
    }

    // MARK: Dashes

    @ViewBuilder var dashEditor: some View {
        let px = stroke.dashUnit == .pixels
        let k = px ? max(stroke.width, 0.0001) : 1
        let pairs = stroke.dashPairs
        WrappingHStack(spacing: 6) {
            Text("Units").foregroundStyle(Theme.textDim).frame(width: 52, alignment: .leading)
            Picker("", selection: Binding(get: { stroke.dashUnit ?? .widths }, set: { stroke.dashUnit = $0 == .widths ? nil : $0; onCommit() })) {
                Text("× Width").tag(DashUnit.widths)
                Text("px").tag(DashUnit.pixels)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 120)
            .help("Dash and gap lengths as multiples of the stroke width (they scale with it), or in pixels")
        }
        ForEach(Array(pairs.enumerated()), id: \.offset) { i, pr in
            WrappingHStack(spacing: 4) {
                NumberField(label: "Dash", value: Binding(get: { pr.0 * k }, set: { v in
                    var ps = stroke.dashPairs
                    if i < ps.count { ps[i].0 = max(0, v / k); stroke.setDashPairs(ps) }
                }), width: 38, format: "%.2g", onCommit: onCommit)
                NumberField(label: "Gap", value: Binding(get: { pr.1 * k }, set: { v in
                    var ps = stroke.dashPairs
                    if i < ps.count { ps[i].1 = max(0, v / k); stroke.setDashPairs(ps) }
                }), width: 38, format: "%.2g", onCommit: onCommit)
                Text(px ? "px" : "×").foregroundStyle(Theme.textFaint)
                Spacer(minLength: 0)
                if pairs.count > 1 {
                    Button {
                        var ps = stroke.dashPairs
                        if i < ps.count { ps.remove(at: i); stroke.setDashPairs(ps); onCommit() }
                    } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(Theme.textDim).help("Remove this dash / gap pair")
                }
            }
        }
        WrappingHStack(spacing: 6) {
            Button {
                var ps = stroke.dashPairs
                ps.append(ps.last ?? (2, 2))
                stroke.setDashPairs(ps)
                onCommit()
            } label: { Label("Add Pair", systemImage: "plus") }.buttonStyle(PanelButtonStyle())
            Spacer()
            NumberField(label: "Offset", value: Binding(get: { (stroke.dashPhase ?? 0) * k }, set: { v in
                stroke.dashPhase = abs(v) < 1e-9 ? nil : v / k
            }), width: 38, format: "%.2g", onCommit: onCommit)
            .help("Shifts the dash pattern along the path")
            .disabled(stroke.dashAlignment == .corners)
        }
        Toggle(isOn: Binding(get: { stroke.dashAlignment == .corners }, set: { stroke.dashAlignment = $0 ? .corners : nil; onCommit() })) {
            Text("Align dashes to corners and path ends")
        }
        .toggleStyle(.checkbox)
        .help("Adjusts the dash lengths a little so a dash sits centred on every corner and the path ends with whole dashes")
        Text("A dash of 0 with Round caps draws round dots.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
    }

    // MARK: Icons

    static func symbol(_ a: StrokeAlignment) -> String {
        switch a {
        case .inside: return "square.inset.filled"
        case .center: return "square"
        case .outside: return "square.dashed"
        }
    }

    func capButton(_ c: LineCapStyle) -> some View {
        Button { stroke.cap = c; onCommit() } label: {
            Canvas { ctx, size in
                let y = size.height / 2
                var p = Path(); p.move(to: CGPoint(x: 4, y: y)); p.addLine(to: CGPoint(x: size.width - 9, y: y))
                ctx.stroke(p, with: .color(Theme.text), style: SwiftUI.StrokeStyle(lineWidth: 8, lineCap: c == .butt ? .butt : c == .round ? .round : .square))
                var guide = Path(); guide.move(to: CGPoint(x: size.width - 9, y: 3)); guide.addLine(to: CGPoint(x: size.width - 9, y: size.height - 3))
                ctx.stroke(guide, with: .color(Theme.accent), lineWidth: 1)
            }
            .frame(width: 30, height: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(stroke.cap == c ? Theme.selection : Theme.fieldBG))
        }
        .buttonStyle(.plain)
        .help("\(c.rawValue.capitalized) cap")
    }

    func joinButton(_ j: LineJoinStyle) -> some View {
        Button { stroke.join = j; onCommit() } label: {
            Canvas { ctx, size in
                var p = Path(); p.move(to: CGPoint(x: 6, y: size.height - 2)); p.addLine(to: CGPoint(x: 6, y: 7)); p.addLine(to: CGPoint(x: size.width - 2, y: 7))
                ctx.stroke(p, with: .color(Theme.text), style: SwiftUI.StrokeStyle(lineWidth: 6, lineJoin: j == .miter ? .miter : j == .round ? .round : .bevel))
            }
            .frame(width: 30, height: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(stroke.join == j ? Theme.selection : Theme.fieldBG))
        }
        .buttonStyle(.plain)
        .help("\(j.rawValue.capitalized) corners")
    }
}

/// Options-bar button for the shape tools: Stroke Options for new shapes and, like Photoshop, for the selected shape layer.
struct ShapeStrokeOptionsButton: View {
    @Bindable var app = AppModel.shared
    @State private var open = false
    @State private var changed = false

    /// The tool's stroke settings as one style (paint, width and alignment live in their own tool fields).
    static func toolStroke(_ t: ShapeToolSettings) -> StrokeStyle {
        var s = t.strokeOptions ?? StrokeStyle()
        s.paint = t.stroke; s.width = t.strokeWidth; s.alignment = t.strokeAlignment
        return s
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 2) {
                StrokePreviewImage(stroke: { var s = Self.toolStroke(app.shapeTool); s.paint = .color(RGBA(gray: 0.9)); return s }(), sample: .line)
                    .frame(width: 34, height: 14)
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
        }
        .buttonStyle(.plain)
        .help("Stroke Options: alignment, caps, corners, dashes and presets")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Stroke Options").font(Theme.fontBold)
                Text(activeShapeID != nil ? "Applies to new shapes and the selected shape layer." : "Applies to new shapes.")
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                StrokeOptionsEditor(stroke: binding, onCommit: { changed = true })
            }
            .padding(10).frame(width: 290)
            .onDisappear { commit() }
        }
    }

    var activeShapeID: UUID? {
        guard let d = app.activeDocument, let l = d.activeLayer, l.isShape else { return nil }
        return l.id
    }

    var binding: Binding<StrokeStyle> {
        Binding(get: { Self.toolStroke(app.shapeTool) }, set: { v in
            var o = v
            o.paint = .none
            app.shapeTool.strokeOptions = o
            app.shapeTool.strokeAlignment = v.alignment
            if let id = activeShapeID, let d = app.activeDocument {
                d.updateLayer(id) { l in
                    guard var s = l.shape else { return }
                    let paint = s.stroke.paint, width = s.stroke.width
                    s.stroke = v
                    s.stroke.paint = paint; s.stroke.width = width
                    l.shape = s
                }
                changed = true
            }
        })
    }

    func commit() {
        guard changed else { return }
        changed = false
        FieldEdits.commit()
        if activeShapeID != nil, let d = app.activeDocument { d.commit("Stroke Options") }
    }
}
