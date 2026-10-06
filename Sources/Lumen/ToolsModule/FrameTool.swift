import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageCratCore

// MARK: - Frame tool

/// Frame tool: draws rectangular or elliptical frames. A frame is a group whose vector mask clips its content;
/// an empty frame shows a placeholder. Placing or dropping an image while a frame (or its content) is selected
/// puts the image into the frame, scaled to fill (or fit) it, replacing previous content.
/// Drawing a frame over a selected pixel layer or smart object moves that layer into the frame.
final class FrameTool: Tool {
    private var start: CGPoint?
    private var current: CGPoint?
    private var constrain = false
    private var fromCenter = false

    override var cursor: NSCursor { .crosshair }

    private var rect: CGRect? {
        guard var s = start, var c = current else { return nil }
        if constrain {
            let m = max(abs(c.x - s.x), abs(c.y - s.y))
            c = CGPoint(x: s.x + (c.x >= s.x ? m : -m), y: s.y + (c.y >= s.y ? m : -m))
        }
        if fromCenter { s = s - (c - s) }
        return CGRect(p1: s, p2: c).integral
    }

    override func mouseDown(_ e: ToolEvent) { start = canvas.snap(e.doc); current = start }
    override func mouseDragged(_ e: ToolEvent) { current = canvas.snap(e.doc); constrain = e.shift; fromCenter = e.option }

    override func mouseUp(_ e: ToolEvent) {
        defer { start = nil; current = nil }
        guard let d = doc, let r = rect else { return }
        if r.width < 3 || r.height < 3 {
            // a click selects the frame under the cursor (frames are groups, which the Move tool can't pick)
            if let f = d.state.toolData.frames.reversed().first(where: { f in
                d.state.layer(f.id)?.vectorMask.map { $0.cgPath.contains(e.doc) } ?? false }) {
                d.selectLayer(f.id)
            }
            return
        }
        FrameSupport.createFrame(d, rect: r, ellipse: ToolsSettings.shared.frameShape == .ellipse, wrapActive: true)
    }

    override func drawOverlay(_ ctx: CGContext) {
        guard let r = rect else { return }
        let p = ToolsSettings.shared.frameShape == .ellipse ? VectorPath.ellipse(r) : VectorPath.rect(r)
        var t = canvas.docToViewTransform
        if let vp = p.cgPath.copy(using: &t) { OverlayStyle.accentStroke(ctx, vp, width: 1.5) }
        if let m = canvas.lastMouseView { OverlayStyle.label("W: \(Int(r.width))  H: \(Int(r.height))", at: m) }
    }
}

enum FrameSupport {
    static func info(_ st: DocumentState, _ id: UUID) -> FrameInfo? { st.toolData.frames.first { $0.id == id } }

    static func isFrame(_ st: DocumentState, _ id: UUID?) -> Bool {
        guard let id, st.layer(id)?.isGroup == true else { return false }
        return info(st, id) != nil
    }

    /// Frame containing (or being) the layer.
    static func frameID(for id: UUID?, in st: DocumentState) -> UUID? {
        guard let id else { return nil }
        if isFrame(st, id) { return id }
        if let p = st.parentID(of: id), isFrame(st, p) { return p }
        return nil
    }

    static func frameRect(_ l: Layer) -> CGRect? { l.vectorMask.map { $0.bounds } }

    @discardableResult
    static func createFrame(_ d: Document, rect r: CGRect, ellipse: Bool, wrapActive: Bool) -> UUID {
        let path = ellipse ? VectorPath.ellipse(r) : VectorPath.rect(r)
        let n = d.state.toolData.frames.filter { d.state.layer($0.id) != nil }.count + 1
        var frame = Layer(name: "Frame \(n)", content: .group(GroupContent(children: [], isExpanded: true)))
        frame.vectorMask = path
        var wrapped = false
        if wrapActive, let a = d.activeLayerID, let al = d.state.layer(a), !isFrame(d.state, a), frameID(for: a, in: d.state) == nil,
           al.isRaster || al.isSmartObject, al.name != "Background", !al.locks.positionLocked,
           let b = Compositor.shared.contentBounds(al, state: d.state), b.intersects(r), d.state.layers.first?.id != a {
            // Photoshop: drawing a frame over an image turns the image into the frame's content.
            var moved = al
            moved.isClipped = false
            frame.children = [moved]
            if let p = d.state.layers.indexPath(of: a) {
                d.state.layers.remove(at: p)
                d.state.layers.insert(frame, at: p)
                wrapped = true
            }
        }
        if !wrapped {
            if let a = d.activeLayerID, d.state.layer(a) != nil {
                d.state.insertLayer(frame, above: a, inside: false)
            } else {
                d.state.layers.append(frame)
            }
        }
        d.state.toolData.frames.append(FrameInfo(id: frame.id, ellipse: ellipse))
        d.activeLayerID = frame.id
        d.selectedLayerIDs = [frame.id]
        d.editTarget = .content
        d.commit("New Frame")
        return frame.id
    }

    /// Scales a smart object so it fills (or fits) the frame, centred.
    static func fit(_ d: Document, content id: UUID, in frameRect: CGRect, mode: FrameFit) {
        d.updateLayer(id) { l in
            guard var so = l.smart else { return }
            let q = so.quad
            let w = q.tl.distance(to: q.tr), h = q.tl.distance(to: q.bl)
            guard w > 0, h > 0 else { return }
            let s = mode == .fill ? max(frameRect.width / w, frameRect.height / h) : min(frameRect.width / w, frameRect.height / h)
            let nw = w * s, nh = h * s
            so.quad = Quad(rect: CGRect(x: frameRect.midX - nw / 2, y: frameRect.midY - nh / 2, width: nw, height: nh))
            so.warp = nil
            l.smart = so
        }
    }

    /// Commit hook: a smart object newly added inside a frame replaces the frame's content and is fitted to it.
    static func handleCommit(_ d: Document) {
        guard !d.state.toolData.frames.isEmpty else { return }
        let before = d.committedState
        for f in d.state.toolData.frames {
            guard let g = d.state.layer(f.id), g.isGroup, let fr = frameRect(g) else { continue }
            let fresh = g.children.filter { $0.isSmartObject && before.layer($0.id) == nil }
            guard let newest = fresh.last else { continue }
            d.updateLayer(f.id) { l in l.children = l.children.filter { $0.id == newest.id } }
            fit(d, content: newest.id, in: fr, mode: ToolsSettings.shared.frameFit)
            d.updateLayer(newest.id) { $0.isClipped = false }
        }
    }

    static func installCommitHook() {
        let previous = Document.willCommit
        Document.willCommit = { d in
            previous?(d)
            handleCommit(d)
            TypeMaskTool.handleCommit(d)
        }
    }

    /// Opens a file panel and places the chosen image into the selected frame.
    static func placeIntoSelectedFrame() {
        guard let d = AppActions.doc, let fid = frameID(for: d.activeLayerID, in: d.state) else {
            AppActions.alert("Select a frame first.", "Draw a frame with the Frame tool (K), then place an image into it.")
            return
        }
        let p = NSOpenPanel()
        p.allowedContentTypes = AppActions.openTypes
        p.prompt = tr("Place")
        guard UIBlock.run(p) == .OK, let u = p.url else { return }
        d.selectLayer(fid)
        AppActions.place([u], linked: false)
    }

    // MARK: Overlay

    static func drawPlaceholders(_ ctx: CGContext, canvas: CanvasView, doc: Document) {
        let frames = doc.state.toolData.frames
        guard !frames.isEmpty else { return }
        let activeFrame = frameID(for: doc.activeLayerID, in: doc.state)
        for f in frames {
            guard let g = doc.state.layer(f.id), g.isVisible, let vm = g.vectorMask else { continue }
            var t = canvas.docToViewTransform
            guard let vp = vm.cgPath.copy(using: &t) else { continue }
            if g.children.isEmpty {
                let b = vp.boundingBoxOfPath
                ctx.saveGState()
                ctx.addPath(vp)
                ctx.clip()
                ctx.setFillColor(NSColor(white: 0.5, alpha: 0.12).cgColor)
                ctx.fill(b)
                ctx.setStrokeColor(NSColor(white: 0.45, alpha: 0.8).cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: b.minX, y: b.minY)); ctx.addLine(to: CGPoint(x: b.maxX, y: b.maxY))
                ctx.move(to: CGPoint(x: b.maxX, y: b.minY)); ctx.addLine(to: CGPoint(x: b.minX, y: b.maxY))
                ctx.strokePath()
                ctx.restoreGState()
                OverlayStyle.contrastStroke(ctx, vp, dashed: activeFrame != f.id)
            } else if activeFrame == f.id {
                OverlayStyle.accentStroke(ctx, vp, width: 1.5)
            }
        }
    }
}

struct FrameOptions: View {
    @Bindable var ts = ToolsSettings.shared
    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "rectangle", help: "Create a new rectangular frame", active: ts.frameShape == .rectangle) { ts.frameShape = .rectangle }
            IconButton(symbol: "circle", help: "Create a new elliptical frame", active: ts.frameShape == .ellipse) { ts.frameShape = .ellipse }
        }
        Picker("Placed Content", selection: $ts.frameFit) {
            ForEach(FrameFit.allCases, id: \.self) { Text(tr($0.rawValue)).tag($0) }
        }.frame(width: 210)
        Button("Place Image in Frame…") { FrameSupport.placeIntoSelectedFrame() }.buttonStyle(PanelButtonStyle())
        Button("Fit Content") {
            guard let d = AppActions.doc, let fid = FrameSupport.frameID(for: d.activeLayerID, in: d.state), let g = d.state.layer(fid),
                  let r = FrameSupport.frameRect(g), let c = g.children.last(where: { $0.isSmartObject }) else { Beep.play(); return }
            FrameSupport.fit(d, content: c.id, in: r, mode: ts.frameFit)
            d.commit("Fit Frame Content")
        }.buttonStyle(PanelButtonStyle())
        Text("Drop an image onto a selected frame to fill it.").foregroundStyle(Theme.textFaint)
    }
}
