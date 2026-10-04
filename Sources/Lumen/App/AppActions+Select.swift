import AppKit
import CoreImage
import Vision
import ImageCratCore

extension AppActions {
    static var lastSelection: PixelBuffer?

    static func selectAll() {
        // ⌘A while typing (a text field, the on-canvas type editor) selects the text, as Cut / Copy / Paste / Undo do
        if isTextEditing { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil); return }
        ActionRecorder.record(.selectAll)
        guard let d = doc else { return }
        d.setSelection(SelectionOps.all(width: d.state.width, height: d.state.height), commitName: "Select All")
    }

    static func deselect() {
        ActionRecorder.record(.deselect)
        guard let d = doc, d.state.selection != nil else { return }
        lastSelection = d.state.selection
        d.setSelection(nil, commitName: "Deselect")
    }

    static func reselect() {
        guard let d = doc, let s = lastSelection, s.width == d.state.width, s.height == d.state.height else { NSSound.beep(); return }
        d.setSelection(s, commitName: "Reselect")
    }

    static func inverseSelection() {
        ActionRecorder.record(.inverseSelection)
        guard let d = doc, let s = d.state.selection else { return }
        d.setSelection(SelectionOps.invert(s), commitName: "Inverse")
    }

    static func modifySelection(_ kind: ModifySelectionKind, amount: Double, direction: FeatherDirection? = nil) {
        guard let d = doc, let s = d.state.selection else { NSSound.beep(); return }
        let r: PixelBuffer
        switch kind {
        case .expand: r = SelectionOps.expand(s, by: amount)
        case .contract: r = SelectionOps.contract(s, by: amount)
        case .border: r = SelectionOps.border(s, width: amount)
        case .smooth: r = SelectionOps.smooth(s, radius: amount)
        case .feather: r = SelectionOps.feather(s, radius: amount, direction: direction ?? app.featherDirection)
        }
        d.setSelection(r, commitName: kind.rawValue)
    }

    static func growSelection() {
        guard let d = doc, let s = d.state.selection, let src = sampleSource(allLayers: true), let b = s.opaqueBounds() else { return }
        let seed = IPoint(x: b.x + b.width / 2, y: b.y + b.height / 2)
        let m = SelectionOps.floodMask(src: src, seed: seed, tolerance: app.selection.tolerance, contiguous: true, antialias: true)
        d.setSelection(SelectionOps.combine(s, m, mode: .add), commitName: "Grow")
    }

    static func colorRange(color: RGBA, fuzziness: Double, invert: Bool) {
        guard let d = doc, let src = sampleSource(allLayers: true) else { return }
        var m = SelectionOps.colorRange(src: src, color: color, fuzziness: fuzziness)
        if invert { m = SelectionOps.invert(m) }
        d.setSelection(m, commitName: "Color Range")
    }

    // MARK: Subject (Vision)

    static func subjectMask() -> PixelBuffer? {
        guard let d = doc else { return nil }
        let sp = space(d)
        let comp = Compositor.shared.composite(d).composited(over: CIImage.color(.white, sp.ciCanvas))
        guard let cg = RenderEngine.cgImage(comp, rect: sp.ciCanvas) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg)
        let req = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([req])
            guard let obs = req.results?.first else { return nil }
            let pb = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
            let ci = CIImage(cvPixelBuffer: pb)
            let scaled = ci.transformed(by: CGAffineTransform(scaleX: CGFloat(d.state.width) / ci.extent.width, y: CGFloat(d.state.height) / ci.extent.height))
            return RenderEngine.renderBuffer(scaled.cropped(to: sp.ciCanvas), docRect: d.state.canvasRect, space: sp, format: .gray)
        } catch {
            return nil
        }
    }

    static func selectSubject() {
        if ObjectSelectionModule.selectSubject() { return }   // SAM 2.1 path when installed
        guard let d = doc else { return }
        app.setStatus("Selecting subject…")
        guard let m = subjectMask() else {
            alert("No subject was found.", "Try a photo with a clear foreground subject.")
            return
        }
        d.setSelection(m, commitName: "Select Subject")
        app.setStatus("Subject selected.")
    }

    static func removeBackground() {
        if ObjectSelectionModule.removeBackground() { return }   // SAM 2.1 path when installed
        guard let d = doc, let id = d.activeLayerID else { return }
        guard let m = subjectMask() else {
            alert("No subject was found.")
            return
        }
        if d.state.layer(id)?.mask != nil { d.updateLayer(id) { $0.mask = nil } }
        d.updateLayer(id) { $0.mask = LayerMask(buffer: m, origin: .zero, outsideValue: 0) }
        d.commit("Remove Background")
    }

    // MARK: Channels

    static func saveSelection() {
        guard let d = doc, let s = d.state.selection else { NSSound.beep(); return }
        let n = d.state.alphaChannels.count + 1
        d.state.alphaChannels.append(AlphaChannel(name: "Alpha \(n)", buffer: s.copy()))
        d.commit("Save Selection")
    }

    static func loadSelection(_ id: UUID, mode: SelectionCombine = .new) {
        guard let d = doc, let ch = d.state.alphaChannels.first(where: { $0.id == id }) else { return }
        d.setSelection(SelectionOps.combine(d.state.selection, ch.buffer.copy(), mode: mode), commitName: "Load Selection")
    }

    static func deleteChannel(_ id: UUID) {
        guard let d = doc else { return }
        d.state.alphaChannels.removeAll { $0.id == id }
        if d.viewChannel == .alpha(id) { d.viewChannel = .composite }
        d.commit("Delete Channel")
    }

    /// Q: the selection is shown (and painted, see `EditTarget.quickMask`) as a red-tinted mask. Leaving turns the
    /// painted mask back into the selection (white = selected, grey = partly, black = not); a fully black mask is none.
    static func toggleQuickMask() {
        guard let d = doc else { return }
        d.quickMask.toggle()
        if !d.quickMask, let s = d.state.selection, s.opaqueBounds() == nil { d.setSelection(nil, commitName: "Deselect") }
        d.setNeedsRender()
        d.setNeedsOverlay()
    }

    // MARK: Paths

    static func selectionFromPath(_ pid: UUID? = nil, feather: Double = 0) {
        guard let d = doc else { return }
        PathOps.makeSelection(d, pid, PathOps.SelectionOptions(feather: feather))   // (Tools/PathsWorkflow.swift)
    }

    /// Make Work Path from the selection: traced, simplified by `tolerance` px; replaces the Work Path.
    static func workPathFromSelection(tolerance: Double = 1.2) {
        guard let d = doc, let s = d.state.selection else { return }
        // Trace polygons around the selection using contour lines, then simplify.
        let outline = SelectionOps.outline(s)
        let vp = VectorPath.from(cgPath: outline)
        // Merge touching segments into polylines
        var polylines: [[CGPoint]] = []
        var segments: [(CGPoint, CGPoint)] = []
        for sp in vp.subpaths where sp.points.count >= 2 { segments.append((sp.points[0].anchor, sp.points[1].anchor)) }
        var adjacency: [String: [Int]] = [:]
        func key(_ p: CGPoint) -> String { "\(Int(p.x)),\(Int(p.y))" }
        for (i, s) in segments.enumerated() { adjacency[key(s.0), default: []].append(i); adjacency[key(s.1), default: []].append(i) }
        var used = [Bool](repeating: false, count: segments.count)
        for i in segments.indices where !used[i] {
            used[i] = true
            var line = [segments[i].0, segments[i].1]
            var extended = true
            while extended {
                extended = false
                let end = line.last!
                for j in adjacency[key(end)] ?? [] where !used[j] {
                    used[j] = true
                    line.append(key(segments[j].0) == key(end) ? segments[j].1 : segments[j].0)
                    extended = true
                    break
                }
            }
            if line.count > 3 { polylines.append(line) }
        }
        var out = VectorPath()
        for pl in polylines {
            let simp = PenTool.simplify(pl, epsilon: max(0.1, tolerance))
            out.subpaths.append(Subpath(points: simp.map { PathPoint($0) }, closed: true))
        }
        _ = VectorEditing.newWorkPath(d, out, addToActive: false)
        d.commit("Make Work Path")
    }

    /// Fill Path (foreground color) / Stroke Path (current brush): see `PathOps` (Tools/PathsWorkflow.swift).
    static func fillPath(_ pid: UUID? = nil) {
        guard let d = doc else { return }
        PathOps.fill(d, pid)
    }

    static func strokePath(_ pid: UUID? = nil) {
        guard let d = doc else { return }
        PathOps.stroke(d, pid)
    }

    static func deletePath(_ id: UUID) {
        guard let d = doc else { return }
        d.state.paths.removeAll { $0.id == id }
        if d.activePathID == id { d.activePathID = nil }
        d.commit("Delete Path")
    }

    static func shapeFromPath(_ pid: UUID? = nil) {
        guard let d = doc, let id = pid ?? d.activePathID, d.state.paths.contains(where: { $0.id == id }) else { return }
        PathOps.makeShape(d, id)
    }

    // MARK: View

    static func zoomIn() { ZoomController.run(.zoomIn) }
    static func zoomOut() { ZoomController.run(.zoomOut) }
    static func fitOnScreen() { ZoomController.run(.fitOnScreen) }
    static func actualPixels() { ZoomController.run(.actualPixels) }

    static func clearGuides() {
        guard let d = doc, !d.state.guides.isEmpty else { return }   // nothing to clear: no empty history step
        d.state.guides = []
        d.commit("Clear Guides")
    }
}
