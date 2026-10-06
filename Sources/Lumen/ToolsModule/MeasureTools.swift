import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageCratCore

// MARK: - Color Sampler

/// Up to 10 persistent sample points; their values are listed in the Info panel.
final class ColorSamplerTool: Tool {
    static let maxSamplers = 10
    private var dragging: Int?

    override var cursor: NSCursor { .crosshair }

    private func hit(_ d: Document, _ v: CGPoint) -> Int? {
        d.state.toolData.colorSamplers.firstIndex { canvas.docToView($0).distance(to: v) < 8 }
    }

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        if let i = hit(d, e.view) {
            if e.option {
                d.state.toolData.colorSamplers.remove(at: i)
                d.commit("Delete Color Sampler")
                return
            }
            dragging = i
            return
        }
        guard d.state.canvasCGRect.contains(e.doc) else { return }
        guard d.state.toolData.colorSamplers.count < ColorSamplerTool.maxSamplers else {
            status("You can place up to \(ColorSamplerTool.maxSamplers) color samplers.")
            Beep.play()
            return
        }
        d.state.toolData.colorSamplers.append(CGPoint(x: floor(e.doc.x) + 0.5, y: floor(e.doc.y) + 0.5))
        dragging = d.state.toolData.colorSamplers.count - 1
        d.commit("Color Sampler")
    }

    override func mouseDragged(_ e: ToolEvent) {
        guard let d = doc, let i = dragging, i < d.state.toolData.colorSamplers.count else { return }
        d.state.toolData.colorSamplers[i] = CGPoint(x: floor(e.doc.x) + 0.5, y: floor(e.doc.y) + 0.5)
        d.setNeedsOverlay()
    }

    override func mouseUp(_ e: ToolEvent) {
        guard let d = doc, let i = dragging else { return }
        dragging = nil
        guard i < d.state.toolData.colorSamplers.count else { return }
        if !d.state.canvasCGRect.contains(e.doc) {   // dragged off the canvas: delete
            d.state.toolData.colorSamplers.remove(at: i)
            d.commit("Delete Color Sampler")
        } else if d.committedState.toolData.colorSamplers != d.state.toolData.colorSamplers {
            d.commit("Move Color Sampler")
        }
    }

    static func drawSamplers(_ ctx: CGContext, canvas: CanvasView, doc: Document) {
        let pts = doc.state.toolData.colorSamplers
        guard !pts.isEmpty else { return }
        for (i, p) in pts.enumerated() {
            let v = canvas.docToView(p)
            let r = CGRect(x: v.x - 6, y: v.y - 6, width: 12, height: 12)
            let path = CGMutablePath()
            path.addEllipse(in: r)
            path.move(to: CGPoint(x: v.x - 10, y: v.y)); path.addLine(to: CGPoint(x: v.x - 3, y: v.y))
            path.move(to: CGPoint(x: v.x + 3, y: v.y)); path.addLine(to: CGPoint(x: v.x + 10, y: v.y))
            path.move(to: CGPoint(x: v.x, y: v.y - 10)); path.addLine(to: CGPoint(x: v.x, y: v.y - 3))
            path.move(to: CGPoint(x: v.x, y: v.y + 3)); path.addLine(to: CGPoint(x: v.x, y: v.y + 10))
            OverlayStyle.contrastStroke(ctx, path)
            NSGraphicsContext.saveGraphicsState()
            ExtraOverlays.text("\(i + 1)", at: CGPoint(x: v.x + 7, y: v.y + 4), color: .white, fontSize: 10)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// Info panel section listing the color sampler values.
struct ColorSamplerInfo: View {
    let doc: Document
    @Bindable var ts = ToolsSettings.shared
    var body: some View {
        let pts = doc.state.toolData.colorSamplers
        if !pts.isEmpty {
            Divider()
            let _ = doc.renderVersionObserved
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(Array(pts.enumerated()), id: \.offset) { i, p in
                    let c = ToolGeometry.compositeColor(doc, at: p, size: ts.colorSamplerSize)
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "scope").font(.system(size: 9))
                        Text("#\(i + 1)").frame(width: 22, alignment: .leading)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("R: \(c.map { "\($0.r8)" } ?? "")")
                            Text("G: \(c.map { "\($0.g8)" } ?? "")")
                            Text("B: \(c.map { "\($0.b8)" } ?? "")")
                        }
                    }
                }
            }
        }
    }
}

extension Document {
    /// Reads the (observed) revision so SwiftUI views refresh after edits.
    var renderVersionObserved: Int { revision }
}

// MARK: - Ruler

/// Ruler: drag to measure distance and angle; "Straighten Layer" rotates the active layer so the line is level.
final class RulerTool: Tool {
    private var dragging: Int?   // 0 = start, 1 = end, 2 = new line

    override var cursor: NSCursor { .crosshair }

    static func line(_ d: Document?) -> (CGPoint, CGPoint)? {
        guard let d else { return nil }
        return ToolsSettings.shared.rulerLines[d.id]
    }

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        if let l = RulerTool.line(d) {
            if canvas.docToView(l.0).distance(to: e.view) < 7 { dragging = 0; return }
            if canvas.docToView(l.1).distance(to: e.view) < 7 { dragging = 1; return }
        }
        ToolsSettings.shared.rulerLines[d.id] = (e.doc, e.doc)
        dragging = 2
        app.sessionTick += 1
    }

    override func mouseDragged(_ e: ToolEvent) {
        guard let d = doc, let i = dragging, var l = RulerTool.line(d) else { return }
        var p = e.doc
        let anchor = i == 0 ? l.1 : l.0
        if e.shift {
            let dd = p - anchor
            let a = (atan2(dd.y, dd.x) / (.pi / 4)).rounded() * (.pi / 4)
            p = anchor + CGPoint(x: cos(a), y: sin(a)) * dd.length
        }
        if i == 0 { l.0 = p } else { l.1 = p }
        ToolsSettings.shared.rulerLines[d.id] = l
        app.sessionTick += 1
        status(RulerTool.info(d))
    }

    override func mouseUp(_ e: ToolEvent) { dragging = nil }

    static func measure(_ l: (CGPoint, CGPoint)) -> (dx: CGFloat, dy: CGFloat, length: CGFloat, angle: CGFloat) {
        let d = l.1 - l.0
        // Photoshop reports the angle counter-clockwise from the +x axis (y up)
        return (d.x, d.y, d.length, atan2(-d.y, d.x) * 180 / .pi)
    }

    static func info(_ d: Document) -> String {
        guard let l = line(d) else { return "" }
        let m = measure(l)
        let sc = d.state.toolData.measurementScale
        let u = sc.isDefault ? "px" : sc.units
        let o = ArtboardCoords.rulerOrigin(d)   // (from the active artboard's corner, like the rulers and the Info panel)
        return String(format: "X: %.0f  Y: %.0f  W: %.1f  H: %.1f  A: %.1f°  L1: %.2f %@", l.0.x - o.x, l.0.y - o.y, m.dx * sc.unitsPerPixel, m.dy * sc.unitsPerPixel, m.angle, m.length * sc.unitsPerPixel, u)
    }

    /// Rotates the selected layers so the ruler line becomes horizontal (or vertical if closer).
    static func straightenLayer(_ d: Document) {
        guard let l = line(d), l.0.distance(to: l.1) > 1 else { Beep.play(); return }
        let a = StraightenCropTool.correction(for: l.0, l.1)
        let ids = d.orderedSelection.isEmpty ? (d.activeLayerID.map { [$0] } ?? []) : d.orderedSelection
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        let c = (l.0 + l.1) / 2
        let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: a).translatedBy(x: -c.x, y: -c.y)
        var changed = false
        for id in ids {
            guard let layer = d.state.layer(id), !layer.locks.positionLocked, !layer.isAdjustment else { continue }
            d.updateLayer(id) { $0 = LayerTransformer.apply(Homography(affine: t), to: layer, space: sp) }
            changed = true
        }
        guard changed else { Beep.play(); return }
        ToolsSettings.shared.rulerLines[d.id] = nil
        d.commit("Straighten Layer")
    }

    override func drawOverlay(_ ctx: CGContext) {
        guard let d = doc, let l = RulerTool.line(d) else { return }
        let a = canvas.docToView(l.0), b = canvas.docToView(l.1)
        let p = CGMutablePath()
        p.move(to: a); p.addLine(to: b)
        for v in [a, b] {
            p.move(to: CGPoint(x: v.x - 5, y: v.y)); p.addLine(to: CGPoint(x: v.x + 5, y: v.y))
            p.move(to: CGPoint(x: v.x, y: v.y - 5)); p.addLine(to: CGPoint(x: v.x, y: v.y + 5))
        }
        OverlayStyle.contrastStroke(ctx, p)
        let m = RulerTool.measure(l)
        OverlayStyle.label(String(format: "%.1f px  %.1f°", m.length, m.angle), at: b)
    }
}

// MARK: - Note

/// Note tool: click to pin a text note; click a note to select it (edit it in the Notes panel); drag to move;
/// Option-click deletes.
final class NoteTool: Tool {
    private var dragging: (UUID, CGPoint, CGPoint)?

    override var cursor: NSCursor { .crosshair }

    static func hit(_ d: Document, _ v: CGPoint, canvas: CanvasView) -> DocNote? {
        d.state.toolData.notes.last { n in
            let c = canvas.docToView(n.position)
            return CGRect(x: c.x - 2, y: c.y - 2, width: 20, height: 20).contains(v)
        }
    }

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        if let n = NoteTool.hit(d, e.view, canvas: canvas) {
            if e.option {
                d.state.toolData.notes.removeAll { $0.id == n.id }
                d.commit("Delete Note")
                return
            }
            ToolsSettings.shared.selectedNoteID = n.id
            dragging = (n.id, e.doc, n.position)
            WorkspaceManager.shared.showPanel("notes")
            return
        }
        let ts = ToolsSettings.shared
        let n = DocNote(position: e.doc.rounded, author: ts.noteAuthor, color: ts.noteColor)
        d.state.toolData.notes.append(n)
        ts.selectedNoteID = n.id
        d.commit("New Note")
        WorkspaceManager.shared.showPanel("notes")
    }

    override func mouseDragged(_ e: ToolEvent) {
        guard let d = doc, let (id, s, p0) = dragging, let i = d.state.toolData.notes.firstIndex(where: { $0.id == id }) else { return }
        d.state.toolData.notes[i].position = (p0 + (e.doc - s)).rounded
        d.setNeedsOverlay()
    }

    override func mouseUp(_ e: ToolEvent) {
        guard let d = doc, let (id, _, p0) = dragging else { return }
        dragging = nil
        if d.state.toolData.notes.first(where: { $0.id == id })?.position != p0 { d.commit("Move Note") }
    }

    static func drawNotes(_ ctx: CGContext, canvas: CanvasView, doc: Document) {
        let sel = ToolsSettings.shared.selectedNoteID
        for n in doc.state.toolData.notes {
            let c = canvas.docToView(n.position)
            let r = CGRect(x: c.x, y: c.y, width: 16, height: 16)
            let fold: CGFloat = 5
            let p = CGMutablePath()
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
            ctx.saveGState()
            ctx.addPath(p)
            ctx.setFillColor(NSColor(calibratedRed: n.color.r, green: n.color.g, blue: n.color.b, alpha: 1).cgColor)
            ctx.fillPath()
            ctx.addPath(p)
            ctx.setStrokeColor((n.id == sel ? OverlayStyle.accent : NSColor(white: 0.1, alpha: 0.8)).cgColor)
            ctx.setLineWidth(n.id == sel ? 2 : 1)
            ctx.strokePath()
            ctx.setStrokeColor(NSColor(white: 0.2, alpha: 0.6).cgColor)
            ctx.setLineWidth(1)
            for k in 0..<3 {
                let y = r.minY + 6 + CGFloat(k) * 3
                ctx.move(to: CGPoint(x: r.minX + 3, y: y)); ctx.addLine(to: CGPoint(x: r.maxX - 3, y: y))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
}

struct NotesPanel: View {
    @Bindable var app = AppModel.shared
    @Bindable var ts = ToolsSettings.shared
    @State private var draft = ""

    var body: some View {
        if let d = app.activeDocument {
            let notes = d.state.toolData.notes
            VStack(alignment: .leading, spacing: 6) {
                if let id = ts.selectedNoteID, let n = notes.first(where: { $0.id == id }) {
                    HStack {
                        Text(tr(n.author.isEmpty ? "Note" : n.author)).font(Theme.fontBold)
                        Spacer()
                        Text(n.date, style: .date).font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                    }
                    TextEditor(text: $draft)
                        .font(Theme.font)
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
                        .onAppear { draft = n.text }
                        .onChange(of: ts.selectedNoteID) { _, _ in draft = notes.first { $0.id == ts.selectedNoteID }?.text ?? "" }
                    HStack {
                        Button("Save") { save(d, id) }.buttonStyle(PanelButtonStyle(prominent: true))
                        Button("Delete") {
                            d.state.toolData.notes.removeAll { $0.id == id }
                            ts.selectedNoteID = nil
                            d.commit("Delete Note")
                        }.buttonStyle(PanelButtonStyle())
                    }
                } else {
                    Text("Click on the canvas with the Note tool (I) to add a note.").font(Theme.font).foregroundStyle(Theme.textFaint)
                }
                if !notes.isEmpty {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(notes.enumerated()), id: \.element.id) { i, n in
                                HStack {
                                    Image(systemName: "note.text").foregroundStyle(Color(nsColor: n.color.nsColor))
                                    Text(tr("\(i + 1). " + (n.text.isEmpty ? "(empty)" : n.text.replacingOccurrences(of: "\n", with: " ")))).lineLimit(1)
                                    Spacer()
                                }
                                .font(Theme.font)
                                .padding(3)
                                .background(n.id == ts.selectedNoteID ? Theme.selection : .clear)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let id = ts.selectedNoteID, id != n.id { save(d, id) }
                                    ts.selectedNoteID = n.id
                                    draft = n.text
                                    d.setNeedsOverlay()
                                }
                            }
                        }
                    }
                    Button("Clear All Notes") {
                        d.state.toolData.notes = []
                        ts.selectedNoteID = nil
                        d.commit("Clear Notes")
                    }.buttonStyle(PanelButtonStyle())
                }
            }
            .padding(8)
        } else {
            Text("No document").foregroundStyle(Theme.textFaint).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func save(_ d: Document, _ id: UUID) {
        guard let i = d.state.toolData.notes.firstIndex(where: { $0.id == id }), d.state.toolData.notes[i].text != draft else { return }
        d.state.toolData.notes[i].text = draft
        d.commit("Edit Note")
    }
}

// MARK: - Count

/// Count tool: click to add numbered marks to the current count group; drag a mark to move it; Option-click removes.
final class CountTool: Tool {
    private var dragging: (Int, Int)?
    private var dragOrigin = CGPoint.zero

    override var cursor: NSCursor { .crosshair }

    static func ensureGroup(_ d: Document) -> Int {
        if d.state.toolData.countGroups.isEmpty {
            d.state.toolData.countGroups = [CountGroup(name: "Count Group 1", color: RGBA(hex: CountGroup.palette[0])!)]
        }
        let i = ToolsSettings.shared.activeCountGroup
        return min(max(0, i), d.state.toolData.countGroups.count - 1)
    }

    private func hit(_ d: Document, _ v: CGPoint) -> (Int, Int)? {
        for (gi, g) in d.state.toolData.countGroups.enumerated() where g.visible {
            if let pi = g.points.firstIndex(where: { canvas.docToView($0).distance(to: v) < max(6, CGFloat(g.markerSize) + 3) }) { return (gi, pi) }
        }
        return nil
    }

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        if let (gi, pi) = hit(d, e.view) {
            if e.option {
                d.state.toolData.countGroups[gi].points.remove(at: pi)
                d.commit("Delete Count")
            } else {
                dragging = (gi, pi)
                dragOrigin = d.state.toolData.countGroups[gi].points[pi]
            }
            return
        }
        guard d.state.canvasCGRect.contains(e.doc) else { return }
        let gi = CountTool.ensureGroup(d)
        d.state.toolData.countGroups[gi].points.append(e.doc.rounded)
        d.commit("Count")
        app.sessionTick += 1
    }

    override func mouseDragged(_ e: ToolEvent) {
        // the mark may be gone (undo, another document) by the time the drag continues
        guard let d = doc, let (gi, pi) = dragging, gi < d.state.toolData.countGroups.count, pi < d.state.toolData.countGroups[gi].points.count else { return }
        d.state.toolData.countGroups[gi].points[pi] = e.doc.rounded
        d.setNeedsOverlay()
    }

    override func mouseUp(_ e: ToolEvent) {
        guard let d = doc, let (gi, pi) = dragging else { return }
        dragging = nil
        guard gi < d.state.toolData.countGroups.count, pi < d.state.toolData.countGroups[gi].points.count else { return }
        if d.state.toolData.countGroups[gi].points[pi] != dragOrigin { d.commit("Move Count") }     // a click is not a move
    }

    override func documentWillChange(_ old: Document) { dragging = nil }

    static func total(_ d: Document) -> Int { d.state.toolData.countGroups.reduce(0) { $0 + $1.points.count } }

    static func drawMarks(_ ctx: CGContext, canvas: CanvasView, doc: Document) {
        for g in doc.state.toolData.countGroups where g.visible && !g.points.isEmpty {
            let col = NSColor(calibratedRed: g.color.r, green: g.color.g, blue: g.color.b, alpha: 1)
            for (i, p) in g.points.enumerated() {
                let v = canvas.docToView(p)
                let s = CGFloat(g.markerSize)
                ctx.saveGState()
                ctx.setStrokeColor(col.cgColor)
                ctx.setLineWidth(2)
                ctx.move(to: CGPoint(x: v.x - s, y: v.y - s)); ctx.addLine(to: CGPoint(x: v.x + s, y: v.y + s))
                ctx.move(to: CGPoint(x: v.x + s, y: v.y - s)); ctx.addLine(to: CGPoint(x: v.x - s, y: v.y + s))
                ctx.strokePath()
                ctx.restoreGState()
                NSGraphicsContext.saveGraphicsState()
                ExtraOverlays.text("\(i + 1)", at: CGPoint(x: v.x + s + 2, y: v.y - CGFloat(g.labelSize) - 2), color: col, fontSize: CGFloat(g.labelSize))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}

struct CountOptions: View {
    @Bindable var app = AppModel.shared
    @Bindable var ts = ToolsSettings.shared
    var body: some View {
        let _ = app.sessionTick
        if let d = app.activeDocument {
            let groups = d.state.toolData.countGroups
            Text("Count: \(CountTool.total(d))").font(Theme.mono)
            if !groups.isEmpty {
                let gi = min(ts.activeCountGroup, groups.count - 1)
                Picker("", selection: Binding(get: { gi }, set: { ts.activeCountGroup = $0 })) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { i, g in Text("\(g.name) (\(g.points.count))").tag(i) }
                }.labelsHidden().frame(width: 160)
                IconButton(symbol: groups[gi].visible ? "eye" : "eye.slash", help: "Toggle Count Group Visibility") {
                    d.state.toolData.countGroups[gi].visible.toggle(); d.commit("Count Group Visibility")
                }
                ColorWell(color: Binding(get: { groups[gi].color }, set: { d.state.toolData.countGroups[gi].color = $0; d.setNeedsOverlay() }),
                          onCommit: { d.commit("Count Group Color") })
                CompactSlider(label: "Marker", value: Binding(get: { groups[gi].markerSize }, set: { d.state.toolData.countGroups[gi].markerSize = $0; d.setNeedsOverlay() }), range: 1...10)
                CompactSlider(label: "Label", value: Binding(get: { groups[gi].labelSize }, set: { d.state.toolData.countGroups[gi].labelSize = $0; d.setNeedsOverlay() }), range: 8...72)
            }
            IconButton(symbol: "folder.badge.plus", help: "Create a new count group") {
                let n = d.state.toolData.countGroups.count
                let hex = CountGroup.palette[n % CountGroup.palette.count]
                d.state.toolData.countGroups.append(CountGroup(name: "Count Group \(n + 1)", color: RGBA(hex: hex)!))
                ts.activeCountGroup = n
                d.commit("New Count Group")
            }
            Button("Clear") {
                let gi = CountTool.ensureGroup(d)
                d.state.toolData.countGroups[gi].points = []
                d.commit("Clear Count")
            }.buttonStyle(PanelButtonStyle())
            Button("Record Measurements") { MeasurementActions.record() }.buttonStyle(PanelButtonStyle())
        }
    }
}

// MARK: - Measurement scale & log

struct MeasurementRecord: Identifiable {
    let id = UUID()
    var label: String
    var date = Date()
    var document: String
    var source: String
    var scale: String
    var units: String
    var count: Int?
    var area: Double?
    var perimeter: Double?
    var circularity: Double?
    var width: Double?
    var height: Double?
    var length: Double?
    var angle: Double?
    var grayMean: Double?

    static let columns = ["Label", "Date and Time", "Document", "Source", "Scale", "Scale Units", "Count", "Area", "Perimeter", "Circularity",
                          "Width", "Height", "Length", "Angle", "Gray Value (Mean)"]

    var values: [String] {
        func f(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "" }
        let df = ISO8601DateFormatter()
        return [label, df.string(from: date), document, source, scale, units, count.map { "\($0)" } ?? "", f(area), f(perimeter), f(circularity),
                f(width), f(height), f(length), f(angle), f(grayMean)]
    }
}

@Observable
final class MeasurementLog {
    static let shared = MeasurementLog()
    var records: [MeasurementRecord] = []

    func csv() -> String {
        func esc(_ s: String) -> String { s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        var lines = [MeasurementRecord.columns.map(esc).joined(separator: ",")]
        for r in records { lines.append(r.values.map(esc).joined(separator: ",")) }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum MeasurementActions {
    static func setDefaultScale() {
        guard let d = AppActions.doc, !d.state.toolData.measurementScale.isDefault else { return }   // already the default: no empty history step
        d.state.toolData.measurementScale = MeasurementScale()
        d.commit("Measurement Scale")
    }

    /// Measurements of a canvas-size gray selection mask (area in px², perimeter from the outline, bounds, circularity).
    static func selectionStats(_ m: PixelBuffer, composite: PixelBuffer?) -> (area: Double, perimeter: Double, width: Double, height: Double, circularity: Double, gray: Double?) {
        let p = m.data.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0, graySum = 0.0
        let cp = composite?.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<m.height {
            for x in 0..<m.width {
                let v = Double(p[y * m.bytesPerRow + x]) / 255
                guard v > 0 else { continue }
                sum += v
                if let c = cp, let cb = composite {
                    let i = y * cb.bytesPerRow + x * 4
                    let a = Double(c[i + 3])
                    let lum = a > 0 ? (0.299 * Double(c[i]) + 0.587 * Double(c[i + 1]) + 0.114 * Double(c[i + 2])) * 255 / a : 0
                    graySum += lum * v
                }
            }
        }
        let per = contourLength(m)
        let b = m.opaqueBounds() ?? .zero
        let circ = per > 0 ? min(1, 4 * .pi * sum / (per * per)) : 0
        return (sum, per, Double(b.width), Double(b.height), circ, composite != nil && sum > 0 ? graySum / sum : nil)
    }

    /// Length of the 50% iso-contour of a gray mask (marching squares with linear interpolation), so
    /// anti-aliased curves measure like curves rather than pixel staircases.
    static func contourLength(_ m: PixelBuffer) -> Double {
        let w = m.width, h = m.height
        let p = m.data.assumingMemoryBound(to: UInt8.self)
        let bpr = m.bytesPerRow
        @inline(__always) func v(_ x: Int, _ y: Int) -> Double {
            if x < 0 || y < 0 || x >= w || y >= h { return 0 }
            return Double(p[y * bpr + x]) / 255
        }
        let t = 0.5
        var total = 0.0
        guard let b = m.opaqueBounds() else { return 0 }
        for y in (b.minY - 1)..<(b.maxY) {
            for x in (b.minX - 1)..<(b.maxX) {
                let a = v(x, y), bb = v(x + 1, y), c = v(x + 1, y + 1), d = v(x, y + 1)
                let idx = (a >= t ? 1 : 0) | (bb >= t ? 2 : 0) | (c >= t ? 4 : 0) | (d >= t ? 8 : 0)
                if idx == 0 || idx == 15 { continue }
                func lerp(_ p0: (Double, Double), _ p1: (Double, Double), _ v0: Double, _ v1: Double) -> (Double, Double) {
                    let k = abs(v1 - v0) < 1e-9 ? 0.5 : (t - v0) / (v1 - v0)
                    return (p0.0 + (p1.0 - p0.0) * k, p0.1 + (p1.1 - p0.1) * k)
                }
                let top = lerp((0, 0), (1, 0), a, bb), right = lerp((1, 0), (1, 1), bb, c)
                let bottom = lerp((0, 1), (1, 1), d, c), left = lerp((0, 0), (0, 1), a, d)
                func len(_ p: (Double, Double), _ q: (Double, Double)) -> Double { hypot(p.0 - q.0, p.1 - q.1) }
                switch idx {
                case 1, 14: total += len(left, top)
                case 2, 13: total += len(top, right)
                case 3, 12: total += len(left, right)
                case 4, 11: total += len(right, bottom)
                case 6, 9: total += len(top, bottom)
                case 7, 8: total += len(left, bottom)
                case 5, 10: total += len(left, top) + len(right, bottom)
                default: break
                }
            }
        }
        return total
    }

    /// Records measurements for the current selection, ruler line and/or count marks.
    @discardableResult
    static func record(_ doc: Document? = nil) -> [MeasurementRecord] {
        guard let d = doc ?? AppActions.doc else { Beep.play(); return [] }
        let sc = d.state.toolData.measurementScale
        let k = sc.unitsPerPixel
        let scaleText = sc.isDefault ? "1 pixel = 1.0000 pixels" : String(format: "%.0f pixels = %.4f %@", sc.pixels, sc.length, sc.units)
        var out: [MeasurementRecord] = []
        let log = MeasurementLog.shared
        func label(_ i: Int) -> String { String(format: "Measurement %d", log.records.count + i + 1) }
        let tool = AppModel.shared.tool
        if let sel = d.state.selection {
            let comp = RenderEngine.renderBuffer(Compositor.shared.composite(d), docRect: d.state.canvasRect, space: CanvasSpace(width: d.state.width, height: d.state.height))
            let s = selectionStats(sel, composite: comp)
            out.append(MeasurementRecord(label: label(out.count), document: d.name, source: "Selection", scale: scaleText, units: sc.units, count: 1,
                                         area: s.area * k * k, perimeter: s.perimeter * k, circularity: s.circularity,
                                         width: s.width * k, height: s.height * k, grayMean: s.gray))
        }
        if let l = RulerTool.line(d), l.0.distance(to: l.1) > 0, tool == .ruler || d.state.selection == nil {
            let m = RulerTool.measure(l)
            out.append(MeasurementRecord(label: label(out.count), document: d.name, source: "Ruler Tool", scale: scaleText, units: sc.units,
                                         width: Double(abs(m.dx)) * k, height: Double(abs(m.dy)) * k, length: Double(m.length) * k, angle: Double(m.angle)))
        }
        let total = CountTool.total(d)
        if total > 0, tool == .count || out.isEmpty || (d.state.selection == nil && tool != .ruler) {
            out.append(MeasurementRecord(label: label(out.count), document: d.name, source: "Count Tool", scale: scaleText, units: sc.units, count: total))
        }
        if out.isEmpty {
            AppModel.shared.setStatus("Nothing to measure: make a selection, draw a ruler line or place count marks.")
            Beep.play()
            return []
        }
        log.records += out
        if AppActions.doc != nil { WorkspaceManager.shared.showPanel("measurementLog") }
        return out
    }

    static func exportCSV() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "Measurements.csv"
        p.allowedContentTypes = [.commaSeparatedText]
        guard UIBlock.run(p) == .OK, let u = p.url else { return }
        do { try MeasurementLog.shared.csv().write(to: u, atomically: true, encoding: .utf8) } catch { AppActions.alert("Could not export the log.", error.localizedDescription) }
    }
}

struct MeasurementLogPanel: View {
    @Bindable var log = MeasurementLog.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Record Measurements") { MeasurementActions.record() }.buttonStyle(PanelButtonStyle(prominent: true))
                Button("Export…") { MeasurementActions.exportCSV() }.buttonStyle(PanelButtonStyle()).disabled(log.records.isEmpty)
                Button("Clear") { log.records = [] }.buttonStyle(PanelButtonStyle()).disabled(log.records.isEmpty)
            }
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        ForEach(MeasurementRecord.columns, id: \.self) { Text(tr($0)).font(Theme.fontBold).foregroundStyle(Theme.textDim) }
                    }
                    ForEach(log.records) { r in
                        GridRow { ForEach(Array(r.values.enumerated()), id: \.offset) { _, v in Text(tr(v)).font(Theme.mono).lineLimit(1) } }
                    }
                }
                .padding(4)
            }
            .defaultScrollAnchor(.topLeading)
            if log.records.isEmpty {
                Text("Measurements from selections, the Ruler tool and the Count tool appear here.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(8)
    }
}

struct MeasurementScaleDialog: View {
    @State private var pixels: Double = AppActions.doc?.state.toolData.measurementScale.pixels ?? 1
    @State private var length: Double = AppActions.doc?.state.toolData.measurementScale.length ?? 1
    @State private var units: String = AppActions.doc?.state.toolData.measurementScale.units ?? "pixels"

    var body: some View {
        DialogFrame(title: "Measurement Scale", width: 340, onOK: {
            guard let d = AppActions.doc, pixels > 0, length > 0 else { return }
            d.state.toolData.measurementScale = MeasurementScale(pixels: pixels, length: length, units: units.isEmpty ? "units" : units)
            d.commit("Measurement Scale")
        }) {
            HStack {
                NumberField(label: "Pixel Length", value: $pixels, width: 70, format: "%.2f")
                Button("Use Ruler") {
                    if let l = RulerTool.line(AppActions.doc) { pixels = Double(l.0.distance(to: l.1)) }
                }.buttonStyle(PanelButtonStyle()).help("Take the pixel length from the current Ruler tool line")
            }
            NumberField(label: "Logical Length", value: $length, width: 70, format: "%.3f")
            HStack {
                Text("Logical Units").font(Theme.font).foregroundStyle(Theme.textDim)
                TextField("", text: $units).textFieldStyle(.roundedBorder).frame(width: 110)
            }
            Text(tr(String(format: "1 pixel = %.4f %@", pixels > 0 ? length / pixels : 0, units))).font(Theme.fontSmall).foregroundStyle(Theme.textDim)
        }
    }
}
