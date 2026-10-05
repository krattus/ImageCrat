import AppKit
import SwiftUI
import ImageCratCore

/// Preferences ▸ Tablet.
struct TabletPreferencesSection: View {
    @Bindable var tablet = TabletSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pressure response").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                HStack(alignment: .top, spacing: 10) {
                    PressureCurveEditor(curve: $tablet.prefs.curve).frame(width: 128, height: 128)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text("Firm").font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                            Slider(value: Binding(get: { tablet.prefs.curve.softness },
                                                  set: { tablet.prefs.curve = .preset(softness: $0, minOutput: tablet.prefs.curve.minOutput, maxOutput: tablet.prefs.curve.maxOutput) }),
                                   in: -1...1)
                            Text("Soft").font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                        }
                        ValueSlider(label: "Minimum", value: Binding(get: { tablet.prefs.curve.minOutput * 100 }, set: { tablet.prefs.curve.minOutput = min($0 / 100, tablet.prefs.curve.maxOutput) }),
                                    range: 0...100, unit: "%", labelWidth: 60)
                        ValueSlider(label: "Maximum", value: Binding(get: { tablet.prefs.curve.maxOutput * 100 }, set: { tablet.prefs.curve.maxOutput = max($0 / 100, tablet.prefs.curve.minOutput) }),
                                    range: 0...100, unit: "%", labelWidth: 60)
                        Button("Linear") { tablet.prefs.curve = PressureCurve() }.buttonStyle(PanelButtonStyle())
                    }
                }
                Text("Drag the points to shape the curve: a soft curve paints strongly with a light touch.")
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
                Text("Test area (double-click to clear)").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                TabletTestArea().frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 4))
                ValueSlider(label: "Tilt Sensitivity", value: Binding(get: { tablet.prefs.tiltSensitivity * 100 }, set: { tablet.prefs.tiltSensitivity = $0 / 100 }),
                            range: 0...200, unit: "%", labelWidth: 100)
                Toggle2(label: "Use pen eraser (flip the pen to erase)", on: $tablet.prefs.usePenEraser)
                Toggle2(label: "Smooth tablet input", on: $tablet.prefs.smoothInput)
                Toggle2(label: "Pressure controls size by default", on: $tablet.prefs.pressureSizeDefault)
                Toggle2(label: "Pressure controls opacity by default", on: $tablet.prefs.pressureOpacityDefault)
                Toggle2(label: "Force Touch trackpad pressure", on: $tablet.prefs.forceTouchPressure)
                Toggle2(label: "Sync brush across tools", on: $tablet.prefs.syncBrushAcrossTools)
                    .help("The brush tip and its preset travel from tool to tool; off, every painting tool keeps its own")
                Divider()
                Text("Smoothing").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                Toggle2(label: "Pulled string mode", on: $tablet.prefs.smoothing.pulledString)
                Toggle2(label: "Stroke catch-up", on: $tablet.prefs.smoothing.strokeCatchUp)
                Toggle2(label: "Catch-up on stroke end", on: $tablet.prefs.smoothing.catchUpOnEnd)
                Toggle2(label: "Adjust for zoom", on: $tablet.prefs.smoothing.adjustForZoom)
                Text("A mouse paints at full pressure. ⌃⌥-drag: size ↔, hardness ↕ · [ ] size · ⇧[ ] hardness · 1…0 opacity · ⇧1…0 flow · right-click: brushes")
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, 8)
        }
        .frame(height: 430)
    }
}

/// The pressure curve: input (raw pen pressure) along x, output up; drag the three points.
struct PressureCurveEditor: View {
    @Binding var curve: PressureCurve
    @State private var dragIndex: Int?

    private static let defaults: [CGPoint] = [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.75, y: 0.75)]
    private var handles: [CGPoint] { curve.points.isEmpty ? PressureCurveEditor.defaults : curve.points }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Canvas { ctx, _ in
                ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(Color.black.opacity(0.35)))
                var grid = Path()
                for i in 1..<4 {
                    let f = CGFloat(i) / 4
                    grid.move(to: CGPoint(x: f * w, y: 0)); grid.addLine(to: CGPoint(x: f * w, y: h))
                    grid.move(to: CGPoint(x: 0, y: f * h)); grid.addLine(to: CGPoint(x: w, y: f * h))
                }
                ctx.stroke(grid, with: .color(.white.opacity(0.08)))
                var diag = Path(); diag.move(to: CGPoint(x: 0, y: h)); diag.addLine(to: CGPoint(x: w, y: 0))
                ctx.stroke(diag, with: .color(.white.opacity(0.18)), style: SwiftUI.StrokeStyle(lineWidth: 1, dash: [3, 3]))
                var p = Path()
                for i in 0...64 {
                    let x = Double(i) / 64
                    let pt = CGPoint(x: CGFloat(x) * w, y: (1 - CGFloat(curve.map(x))) * h)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                ctx.stroke(p, with: .color(Color(red: 0.35, green: 0.7, blue: 1)), lineWidth: 2)
                for q in handles {
                    let c = CGPoint(x: q.x * w, y: (1 - q.y) * h)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.white))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let pts = handles
                    if dragIndex == nil {
                        let hit = pts.enumerated().min { a, b in
                            hypot(a.element.x * w - g.startLocation.x, (1 - a.element.y) * h - g.startLocation.y)
                                < hypot(b.element.x * w - g.startLocation.x, (1 - b.element.y) * h - g.startLocation.y)
                        }
                        dragIndex = hit?.offset
                    }
                    guard let i = dragIndex else { return }
                    var np = pts
                    let lo = i > 0 ? np[i - 1].x + 0.03 : 0.03, hi = i < np.count - 1 ? np[i + 1].x - 0.03 : 0.97
                    np[i] = CGPoint(x: min(hi, max(lo, g.location.x / w)), y: min(1, max(0, 1 - g.location.y / h)))
                    curve.points = PressureCurve.sanitized(np)
                }
                .onEnded { _ in dragIndex = nil })
        }
    }
}

/// Scribble pad: strokes are drawn as wide as the (curved) pressure, with a live readout of everything the pen sends.
struct TabletTestArea: NSViewRepresentable {
    func makeNSView(context: Context) -> TabletTestAreaView { TabletTestAreaView() }
    func updateNSView(_ v: TabletTestAreaView, context: Context) { v.needsDisplay = true }
}

final class TabletTestAreaView: NSView {
    struct Sample { var p: CGPoint; var pressure: Double }
    private(set) var strokes: [[Sample]] = []
    private(set) var readout = "Scribble here with the pen"

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor)
        ctx.fill(bounds)
        ctx.setStrokeColor(NSColor(calibratedRed: 0.35, green: 0.7, blue: 1, alpha: 1).cgColor)
        ctx.setLineCap(.round)
        for s in strokes {
            for i in 1..<max(1, s.count) {
                ctx.setLineWidth(CGFloat(1 + 16 * (s[i - 1].pressure + s[i].pressure) / 2))
                ctx.move(to: s[i - 1].p); ctx.addLine(to: s[i].p); ctx.strokePath()
            }
            if s.count == 1, let f = s.first {
                let r = CGFloat(0.5 + 8 * f.pressure)
                ctx.setFillColor(NSColor(calibratedRed: 0.35, green: 0.7, blue: 1, alpha: 1).cgColor)
                ctx.fillEllipse(in: CGRect(x: f.p.x - r, y: f.p.y - r, width: 2 * r, height: 2 * r))
            }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        NSAttributedString(string: readout, attributes: attrs).draw(at: CGPoint(x: 6, y: 4))
    }

    func add(_ e: NSEvent, phase: TabletInput.Phase) {
        let r = TabletInput.shared.reading(e, phase: phase)
        let p = convert(e.locationInWindow, from: nil)
        if phase == .down { strokes.append([]) }
        if strokes.isEmpty { strokes.append([]) }
        strokes[strokes.count - 1].append(Sample(p: p, pressure: r.pressure))
        readout = TabletTestAreaView.describe(r)
        needsDisplay = true
    }

    static func describe(_ r: TabletInput.Reading) -> String {
        guard r.isTablet else { return String(format: "Mouse · pressure %.2f (full)", r.pressure) }
        let tiltDeg = atan2(-Double(r.tilt.y), Double(r.tilt.x)) * 180 / .pi
        return String(format: "%@ · pressure %.2f → %.2f · tilt %.0f%% at %.0f° · rotation %.0f° · wheel %.2f",
                      r.pointer.rawValue.capitalized, r.rawPressure, r.pressure, Double(r.tilt.length) * 100, tiltDeg, r.rotation, r.tangential)
    }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { strokes = []; needsDisplay = true; return }
        TabletInput.shared.beginStroke(painting: true)
        add(e, phase: .down)
    }
    override func mouseDragged(with e: NSEvent) { add(e, phase: .drag) }
    override func mouseUp(with e: NSEvent) { add(e, phase: .up); TabletInput.shared.endStroke() }
    override func tabletProximity(with e: NSEvent) { TabletInput.shared.handleProximity(e) }
}
