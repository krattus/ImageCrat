import AppKit
import SwiftUI
import ImageCratCore

// MARK: - Slice / Slice Select

/// Slice tool: drag to create user slices (stored in the document). Slice Select: click to select, drag to move,
/// drag handles to resize, Delete removes. Remaining areas are shown as numbered auto slices.
final class SliceTool: Tool {
    private enum Drag { case create(CGPoint), move(UUID, CGPoint, CGRect), resize(UUID, TransformHandle, CGPoint, CGRect) }
    private var drag: Drag?
    private var current: CGPoint?

    override var cursor: NSCursor { .crosshair }

    private var selectedID: UUID? {
        get { ToolsSettings.shared.selectedSliceID }
        set { ToolsSettings.shared.selectedSliceID = newValue; app.sessionTick += 1 }
    }

    private func handles(_ r: CGRect) -> [(TransformHandle, CGPoint)] {
        let q = Quad(rect: r).mapped { canvas.docToView($0) }.points
        var out: [(TransformHandle, CGPoint)] = []
        for i in 0..<4 { out.append((.corner(i), q[i])) }
        for i in 0..<4 { out.append((.edge(i), (q[i] + q[(i + 1) % 4]) / 2)) }
        return out
    }

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        let slices = d.state.toolData.slices
        let selecting = kind == .sliceSelect || e.command
        if selecting {
            if let id = selectedID, let s = slices.first(where: { $0.id == id }),
               let (h, _) = handles(s.rect).first(where: { $0.1.distance(to: e.view) < 7 }) {
                drag = .resize(id, h, e.doc, s.rect)
                return
            }
            if let s = slices.last(where: { $0.rect.contains(e.doc) }) {
                selectedID = s.id
                drag = .move(s.id, e.doc, s.rect)
            } else {
                selectedID = nil
            }
            return
        }
        drag = .create(canvas.snap(e.doc).rounded)
        current = canvas.snap(e.doc).rounded
    }

    override func mouseDragged(_ e: ToolEvent) {
        guard let d = doc, let dr = drag else { return }
        switch dr {
        case .create:
            current = canvas.snap(e.doc).rounded
        case .move(let id, let start, let r0):
            let delta = (e.doc - start).rounded
            SliceTool.update(d, id) { $0.rect = r0.offsetBy(dx: delta.x, dy: delta.y) }
        case .resize(let id, let h, let start, let r0):
            let dp = (canvas.snap(e.doc) - start).rounded
            var x0 = r0.minX, y0 = r0.minY, x1 = r0.maxX, y1 = r0.maxY
            switch h {
            case .corner(let i):
                if i == 0 || i == 3 { x0 += dp.x } else { x1 += dp.x }
                if i == 0 || i == 1 { y0 += dp.y } else { y1 += dp.y }
            case .edge(let i):
                switch i { case 0: y0 += dp.y; case 1: x1 += dp.x; case 2: y1 += dp.y; default: x0 += dp.x }
            default: break
            }
            SliceTool.update(d, id) { $0.rect = CGRect(p1: CGPoint(x: x0, y: y0), p2: CGPoint(x: x1, y: y1)).integral }
        }
        d.setNeedsOverlay()
    }

    override func mouseUp(_ e: ToolEvent) {
        guard let d = doc, let dr = drag else { return }
        defer { drag = nil; current = nil }
        switch dr {
        case .create(let s):
            guard let c = current else { return }
            let r = CGRect(p1: s, p2: c).intersection(d.state.canvasCGRect).integral
            guard r.width >= 2, r.height >= 2 else { return }
            let sl = DocSlice(rect: r)
            d.state.toolData.slices.append(sl)
            selectedID = sl.id
            d.commit("Slice")
        case .move(let id, _, let r0), .resize(let id, _, _, let r0):
            if d.state.toolData.slices.first(where: { $0.id == id })?.rect != r0 { d.commit("Edit Slice") }
        }
    }

    override func keyDown(_ e: NSEvent) -> Bool {
        guard e.keyCode == 51 || e.keyCode == 117, let d = doc, let id = selectedID else { return false }
        d.state.toolData.slices.removeAll { $0.id == id }
        selectedID = nil
        d.commit("Delete Slice")
        return true
    }

    static func update(_ d: Document, _ id: UUID, _ body: (inout DocSlice) -> Void) {
        guard let i = d.state.toolData.slices.firstIndex(where: { $0.id == id }) else { return }
        body(&d.state.toolData.slices[i])
    }

    override func drawOverlay(_ ctx: CGContext) {
        if case .create(let s) = drag, let c = current {
            OverlayStyle.contrastStroke(ctx, CGPath(rect: canvas.docToView(CGRect(p1: s, p2: c)), transform: nil), dashed: true)
            if let m = canvas.lastMouseView { OverlayStyle.label("W: \(Int(abs(c.x - s.x)))  H: \(Int(abs(c.y - s.y)))", at: m) }
        }
        if let d = doc, let id = selectedID, let s = d.state.toolData.slices.first(where: { $0.id == id }) {
            for (_, p) in handles(s.rect) { OverlayStyle.handle(ctx, at: p, size: 6) }
        }
    }

    /// Slices from guides: every cell between guides (and the canvas edges) becomes a user slice.
    static func slicesFromGuides(_ d: Document) {
        let W = Double(d.state.width), H = Double(d.state.height)
        var xs = Set([0.0, W]), ys = Set([0.0, H])
        for g in d.state.guides {
            if g.isVertical, g.position > 0, g.position < W { xs.insert(g.position.rounded()) }
            if !g.isVertical, g.position > 0, g.position < H { ys.insert(g.position.rounded()) }
        }
        guard xs.count > 2 || ys.count > 2 else { AppModel.shared.setStatus("There are no guides to create slices from."); NSSound.beep(); return }
        let sx = xs.sorted(), sy = ys.sorted()
        var out: [DocSlice] = []
        for j in 0..<(sy.count - 1) {
            for i in 0..<(sx.count - 1) {
                out.append(DocSlice(rect: CGRect(x: sx[i], y: sy[j], width: sx[i + 1] - sx[i], height: sy[j + 1] - sy[j])))
            }
        }
        d.state.toolData.slices = out
        d.commit("Slices From Guides")
    }
}

/// Slice numbering / auto slices.
enum SliceLayout {
    struct Item { var rect: CGRect; var user: Bool; var id: UUID?; var name: String; var number: Int }

    /// User slices plus auto slices covering the rest of the canvas, numbered left-to-right, top-to-bottom.
    static func items(_ st: DocumentState, includeAuto: Bool = true) -> [Item] {
        let canvas = st.canvasCGRect
        let user = st.toolData.slices.map { ($0, $0.rect.intersection(canvas)) }.filter { !$0.1.isNull && $0.1.width > 0 && $0.1.height > 0 }
        var items: [Item] = user.map { Item(rect: $0.1, user: true, id: $0.0.id, name: $0.0.name, number: 0) }
        if includeAuto {
            if user.isEmpty {
                items.append(Item(rect: canvas, user: false, id: nil, name: "", number: 0))
            } else {
                var xs = Set<CGFloat>([canvas.minX, canvas.maxX]), ys = Set<CGFloat>([canvas.minY, canvas.maxY])
                for (_, r) in user { xs.insert(r.minX); xs.insert(r.maxX); ys.insert(r.minY); ys.insert(r.maxY) }
                let sx = xs.sorted(), sy = ys.sorted()
                // grid cells not covered by a user slice, merged horizontally into runs
                for j in 0..<(sy.count - 1) {
                    var run: CGRect?
                    for i in 0..<(sx.count - 1) {
                        let cell = CGRect(x: sx[i], y: sy[j], width: sx[i + 1] - sx[i], height: sy[j + 1] - sy[j])
                        let covered = user.contains { $0.1.contains(CGPoint(x: cell.midX, y: cell.midY)) }
                        if covered {
                            if let r = run { items.append(Item(rect: r, user: false, id: nil, name: "", number: 0)); run = nil }
                        } else {
                            run = run.map { $0.union(cell) } ?? cell
                        }
                    }
                    if let r = run { items.append(Item(rect: r, user: false, id: nil, name: "", number: 0)) }
                }
            }
        }
        items.sort { a, b in a.rect.minY != b.rect.minY ? a.rect.minY < b.rect.minY : a.rect.minX < b.rect.minX }
        for i in items.indices { items[i].number = i + 1 }
        return items
    }
}

enum SliceOverlay {
    static func draw(_ ctx: CGContext, canvas: CanvasView, doc: Document, selected: UUID?) {
        let tool = AppModel.shared.tool
        let sliceTool = tool == .slice || tool == .sliceSelect
        guard sliceTool || !doc.state.toolData.slices.isEmpty else { return }
        let items = SliceLayout.items(doc.state, includeAuto: sliceTool)
        let userColor = NSColor(calibratedRed: 0.2, green: 0.55, blue: 1, alpha: 1)
        let autoColor = NSColor(white: 0.6, alpha: 0.9)
        ctx.saveGState()
        for it in items {
            let vr = canvas.docToView(it.rect)
            if !it.user && sliceTool {
                ctx.setFillColor(NSColor(white: 0, alpha: 0.18).cgColor)
                ctx.fill(vr)
            }
            let isSel = it.id != nil && it.id == selected
            ctx.setStrokeColor((it.user ? (isSel ? NSColor(calibratedRed: 1, green: 0.6, blue: 0.1, alpha: 1) : userColor) : autoColor).cgColor)
            ctx.setLineWidth(isSel ? 2 : 1)
            if !it.user { ctx.setLineDash(phase: 0, lengths: [3, 3]) } else { ctx.setLineDash(phase: 0, lengths: []) }
            ctx.stroke(vr.insetBy(dx: 0.5, dy: 0.5))
            NSGraphicsContext.saveGraphicsState()
            ExtraOverlays.badge(String(format: "%02d", it.number), at: CGPoint(x: vr.minX + 2, y: vr.minY + 2), color: it.user ? userColor : autoColor)
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.restoreGState()
    }
}

// MARK: - Export

enum SliceExport {
    /// Writes each slice as `<base>_NN.png` into `dir`; returns the written URLs.
    @discardableResult
    static func export(_ st: DocumentState, to dir: URL, baseName: String, includeAuto: Bool) throws -> [URL] {
        var urls: [URL] = []
        let flat = Compositor.shared.composite(st)
        let sp = CanvasSpace(width: st.width, height: st.height)
        for it in SliceLayout.items(st, includeAuto: includeAuto) {
            let ir = IRect(enclosing: it.rect).intersection(st.canvasRect)
            guard !ir.isEmpty else { continue }
            guard let cg = RenderEngine.cgImage(flat, rect: sp.ciRect(ir)) else { continue }
            let clean = it.name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
            let name = clean.isEmpty ? String(format: "%@_%02d", baseName, it.number) : clean
            let url = dir.appendingPathComponent(name).appendingPathExtension("png")
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, cg, nil)
            if !CGImageDestinationFinalize(dest) { throw NSError(domain: Brand.name, code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not write \(url.lastPathComponent)"]) }
            urls.append(url)
        }
        return urls
    }

    static func exportWithPanel() {
        guard AppActions.doc != nil else { NSSound.beep(); return }
        DialogRegistry.show("exportSlices")
    }
}

struct ExportSlicesDialog: View {
    @State private var includeAuto = true
    var body: some View {
        let d = AppActions.doc
        let count = d.map { SliceLayout.items($0.state, includeAuto: includeAuto).count } ?? 0
        DialogFrame(title: "Export Slices", width: 340, okTitle: "Export…", onOK: {
            guard let d = AppActions.doc else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            panel.message = "Choose a folder for the slice images"
            guard UIBlock.run(panel) == .OK, let dir = panel.url else { return }
            let base = (d.name as NSString).deletingPathExtension
            do {
                let urls = try SliceExport.export(d.state, to: dir, baseName: base, includeAuto: includeAuto)
                AppModel.shared.setStatus("Exported \(urls.count) slice\(urls.count == 1 ? "" : "s") to \(dir.lastPathComponent).")
            } catch { AppActions.alert("Could not export slices.", error.localizedDescription) }
        }) {
            Text("\(d?.state.toolData.slices.count ?? 0) user slice(s); \(count) image(s) will be written as PNG.")
                .font(Theme.font).foregroundStyle(Theme.textDim)
            Toggle2(label: "Include auto slices", on: $includeAuto)
        }
    }
}

struct SliceOptions: View {
    @Bindable var app = AppModel.shared
    @Bindable var ts = ToolsSettings.shared
    var body: some View {
        let _ = app.sessionTick
        let d = app.activeDocument
        if let d, let id = ts.selectedSliceID, let s = d.state.toolData.slices.first(where: { $0.id == id }) {
            let items = SliceLayout.items(d.state)
            Text("Slice \(String(format: "%02d", items.first { $0.id == id }?.number ?? 0))").foregroundStyle(Theme.textDim)
            TextField("Name", text: Binding(get: { s.name }, set: { v in SliceTool.update(d, id) { $0.name = v }; d.setNeedsOverlay() }))
                .textFieldStyle(.roundedBorder).frame(width: 110).onSubmit { d.commit("Slice Name") }
            NumberField(label: "X", value: Binding(get: { Double(s.rect.minX) }, set: { v in SliceTool.update(d, id) { $0.rect.origin.x = CGFloat(v) }; d.commit("Edit Slice") }), width: 44)
            NumberField(label: "Y", value: Binding(get: { Double(s.rect.minY) }, set: { v in SliceTool.update(d, id) { $0.rect.origin.y = CGFloat(v) }; d.commit("Edit Slice") }), width: 44)
            NumberField(label: "W", value: Binding(get: { Double(s.rect.width) }, set: { v in SliceTool.update(d, id) { $0.rect.size.width = CGFloat(max(1, v)) }; d.commit("Edit Slice") }), width: 44)
            NumberField(label: "H", value: Binding(get: { Double(s.rect.height) }, set: { v in SliceTool.update(d, id) { $0.rect.size.height = CGFloat(max(1, v)) }; d.commit("Edit Slice") }), width: 44)
            IconButton(symbol: "trash", help: "Delete Slice") {
                d.state.toolData.slices.removeAll { $0.id == id }
                ts.selectedSliceID = nil
                d.commit("Delete Slice")
            }
        } else {
            Text(app.tool == .slice ? "Drag to create a slice. ⌘-drag selects." : "Click a slice to select it.").foregroundStyle(Theme.textFaint)
        }
        Button("Slices From Guides") { if let d = app.activeDocument { SliceTool.slicesFromGuides(d) } }.buttonStyle(PanelButtonStyle())
        Button("Clear Slices") {
            if let d = app.activeDocument, !d.state.toolData.slices.isEmpty { d.state.toolData.slices = []; ts.selectedSliceID = nil; d.commit("Delete Slices") }
        }.buttonStyle(PanelButtonStyle())
        Button("Export Slices…") { SliceExport.exportWithPanel() }.buttonStyle(PanelButtonStyle())
    }
}
