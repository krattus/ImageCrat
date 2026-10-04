import AppKit
import ImageCratCore

/// Type on a path, end to end: the Line tool's Path mode (a visible 2-anchor open work path), Pen paths, the Type tool's
/// path hit and cursor, glyph placement along lines and curves, moving / flipping along the path, editing, undo,
/// `.imagecrat` and PSD. `LUMEN_SELFTEST_ONLY=typepath Lumen --selftest <dir>`
enum TypePathSelfTest {
    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") typepath: \(name)\(d.isEmpty ? "" : " — " + d)")
        fflush(stdout)
    }
    static func info(_ s: String) { print("INFO typepath: \(s)"); fflush(stdout) }

    typealias R = ToolRobot

    /// Opaque overlay pixels inside a view-space rect of the robot's overlay bitmap.
    static func overlayInk(_ rep: NSBitmapImageRep?, _ r: CGRect, canvas: CanvasView) -> Int {
        guard let rep else { return -1 }
        let sx = CGFloat(rep.pixelsWide) / max(1, canvas.bounds.width), sy = CGFloat(rep.pixelsHigh) / max(1, canvas.bounds.height)
        var n = 0
        let x0 = max(0, Int(r.minX * sx)), x1 = min(rep.pixelsWide - 1, Int(r.maxX * sx))
        let y0 = max(0, Int(r.minY * sy)), y1 = min(rep.pixelsHigh - 1, Int(r.maxY * sy))
        guard x0 <= x1, y0 <= y1 else { return 0 }
        for y in y0...y1 { for x in x0...x1 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 { n += 1 } }
        return n
    }

    /// Overlay ink in a small box around a doc point.
    static func inkAt(_ r: R, _ p: CGPoint) -> Int {
        let v = r.v(p)
        return overlayInk(r.drawOverlay(), CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8), canvas: r.canvas)
    }

    static func steps(_ d: Document, _ s: QASnapshot) -> [String] {
        guard d.historyIndex > s.historyIndex else { return [] }
        return d.history[(s.historyIndex + 1)...d.historyIndex].map(\.name)
    }

    static func run(_ out: URL) {
        passes = 0; failures = 0
        QA.out = out
        setvbuf(stdout, nil, _IONBF, 0)
        let app = AppModel.shared
        let saved = (tool: app.tool, shape: app.shapeTool, pen: app.penMode, text: app.textTool, canvas: AppActions.canvas,
                     docs: app.documents, active: app.activeDocumentID, dialog: app.dialog, fg: app.foreground)
        app.dialog = nil
        app.documents = []; app.activeDocumentID = nil
        let savedButton = CanvasView.primaryButtonDown
        CanvasView.primaryButtonDown = { ToolRobot.buttonDown }
        let savedModes = ToolModes.memory
        ToolModes.memory = [:]
        defer {
            CanvasView.primaryButtonDown = savedButton
            ToolModes.memory = savedModes
            app.tool = saved.tool; app.shapeTool = saved.shape; app.penMode = saved.pen; app.textTool = saved.text; app.foreground = saved.fg
            app.documents = saved.docs; app.activeDocumentID = saved.active; app.dialog = saved.dialog
            AppActions.canvas = saved.canvas
        }
        app.textTool = TextToolSettings()
        app.textTool.fontSize = 28
        app.textTool.color = RGBA(hex: "1B1F3A")!
        lineInPathMode(out)
        penPaths()
        typeOnLineAndCurve(out)
        typeOnShapesAndClosedPaths()
        layoutOptions()
        persistence(out)
        print("typepath: \(passes) checks passed, \(failures) failed")
    }

    // MARK: - Line tool in Path mode, Pen paths

    static func lineInPathMode(_ out: URL) {
        let r = R()
        let d = r.open(SelfTest.baseState(400, 300), name: "line-path")
        let app = AppModel.shared
        app.shapeTool = ShapeToolSettings()
        app.shapeTool.mode = .path
        app.shapeTool.lineWeight = 9          // the weight must not matter in Path mode
        r.select(.hand); r.select(.line)
        let a = CGPoint(x: 60, y: 200), b = CGPoint(x: 320, y: 120)
        let s0 = QASnapshot(d)
        r.dragLine(a, b, steps: 6)
        let wp = d.state.paths.first { $0.name == "Work Path" }
        let sub = wp?.path.subpaths.first
        info("line path: \(d.state.paths.count) paths, \(wp?.path.subpaths.count ?? 0) subpaths, \(sub?.points.count ?? 0) points, closed \(sub?.closed ?? false)")
        check(wp != nil && d.activePathID == wp?.id, "the Line tool in Path mode makes the active Work Path")
        check(wp?.path.subpaths.count == 1 && sub?.points.count == 2 && sub?.closed == false, "the line is a 2-anchor open path",
              "\(wp?.path.subpaths.map { "\($0.points.count) pts closed \($0.closed)" } ?? [])")
        if let s = sub, s.points.count == 2 {
            check(s.points[0].anchor.distance(to: a) < 0.6 && s.points[1].anchor.distance(to: b) < 0.6, "anchors at the drag ends",
                  "\(s.points.map(\.anchor))")
        }
        check(d.state.allLayers.count == 1 && steps(d, s0) == ["Work Path"], "Path mode adds no layer, one history step",
              "\(d.state.allLayers.count) layers, \(steps(d, s0))")
        // the outline stays visible on the canvas after the drag (Line tool still active, then the Type tool)
        let mid = a.lerp(b, 0.5)
        check(inkAt(r, mid) > 0, "the line path is drawn on the canvas after the drag (Line tool)", "ink \(inkAt(r, mid))")
        r.select(.text)
        check(inkAt(r, mid) > 0, "the line path stays visible with the Type tool", "ink \(inkAt(r, mid))")
        r.select(.pathSelect)
        check(inkAt(r, mid) > 0, "the line path is visible with the Path Selection tool", "ink \(inkAt(r, mid))")
        r.select(.brush)
        check(inkAt(r, mid) > 0, "the active path stays visible with another tool (Brush)")
        r.saveOverlayPNG("typepath_line_overlay")
        // shift constrains to 45°
        r.select(.line)
        PathOps.deselectPath(d)
        r.down(CGPoint(x: 50, y: 50)); r.mods = [.shift]; r.drag(CGPoint(x: 150, y: 58)); r.up(CGPoint(x: 150, y: 58)); r.mods = []
        let last = d.state.paths.first { $0.name == "Work Path" }?.path.subpaths.last?.points.map(\.anchor) ?? []
        check(last.count == 2 && abs(last[1].y - 50) < 0.5, "⇧ constrains the line path", "\(last)")
        r.closeAll()
    }

    static func penPaths() {
        let r = R()
        let app = AppModel.shared
        // straight open path: two clicks, Return
        do {
            let d = r.open(SelfTest.baseState(400, 300), name: "pen-straight")
            app.penMode = .path
            r.select(.hand); r.select(.pen)
            r.click(CGPoint(x: 60, y: 220)); r.click(CGPoint(x: 340, y: 90)); r.key(R.kReturn, "\r")
            let sp = d.state.paths.first?.path.subpaths.first
            check(d.state.allLayers.count == 1 && sp?.points.count == 2 && sp?.closed == false, "Pen: straight open path (2 anchors), no layer",
                  "\(d.state.allLayers.count) layers, \(sp?.points.count ?? 0) points")
            r.select(.text)
            check(inkAt(r, CGPoint(x: 200, y: 155)) > 0, "Pen path visible with the Type tool")
            r.closeAll()
        }
        // curved open path: click, click-drag (smooth point), click
        do {
            let d = r.open(SelfTest.baseState(400, 300), name: "pen-curve")
            r.select(.hand); r.select(.pen)
            r.click(CGPoint(x: 40, y: 220))
            r.down(CGPoint(x: 200, y: 80)); r.drag(CGPoint(x: 260, y: 80)); r.drag(CGPoint(x: 280, y: 80)); r.up(CGPoint(x: 280, y: 80))
            r.click(CGPoint(x: 360, y: 220)); r.key(R.kReturn, "\r")
            let sp = d.state.paths.first?.path.subpaths.first
            check(sp?.points.count == 3 && sp?.closed == false && sp?.points[1].hasHandles == true, "Pen: curved open path with a smooth anchor",
                  "\(sp?.points.count ?? 0) points")
            r.select(.text)
            check(inkAt(r, CGPoint(x: 200, y: 80)) > 0, "curved Pen path visible with the Type tool")
            r.closeAll()
        }
        // freeform pen
        do {
            let d = r.open(SelfTest.baseState(400, 300), name: "pen-freeform")
            r.select(.hand); r.select(.freeformPen)
            r.dragPath([CGPoint(x: 40, y: 200), CGPoint(x: 120, y: 150), CGPoint(x: 200, y: 140), CGPoint(x: 280, y: 160), CGPoint(x: 360, y: 210)])
            let sp = d.state.paths.first?.path.subpaths.first
            check(d.state.allLayers.count == 1 && (sp?.points.count ?? 0) >= 2 && sp?.closed == false, "Freeform Pen: open path, no layer")
            r.select(.text)
            check(inkAt(r, CGPoint(x: 200, y: 140)) > 0, "Freeform Pen path visible with the Type tool")
            r.closeAll()
        }
    }

    // MARK: - Type on a line and on a curve

    /// Glyph clusters of a path text layer: arc length of the path point nearest the glyph box centre, its distance,
    /// the side (cross product sign, < 0 = the unflipped text side) and the glyph's angle error against the tangent.
    struct GlyphCheck { var s: CGFloat; var dist: CGFloat; var cross: CGFloat; var angleError: CGFloat }

    static func glyphChecks(_ t: TextContent) -> [GlyphCheck] {
        guard let p = t.pathText else { return [] }
        let sampler = PathSampler(p.path)
        var out: [GlyphCheck] = []
        for pl in TextRenderer.layout(t).lines {
            let c = CGPoint(x: pl.bounds.midX, y: pl.bounds.midY)
            let (s, dist) = sampler.nearest(c)
            guard let (q, ang) = sampler.sample(s) else { continue }
            let v = c - q
            let cross = cos(ang) * v.y - sin(ang) * v.x
            var glyphAng = atan2(pl.transform.b, pl.transform.a)
            if p.flipped { glyphAng += .pi }
            var e = abs(glyphAng - ang).truncatingRemainder(dividingBy: 2 * .pi)
            if e > .pi { e = 2 * .pi - e }
            out.append(GlyphCheck(s: s, dist: dist, cross: cross, angleError: e))
        }
        return out
    }

    /// Half the ascent-minus-descent: how far a glyph box centre sits from the baseline.
    static func centreHeight(_ t: TextContent) -> CGFloat {
        let f = TextRenderer.font(t)
        return (f.ascender + f.descender) / 2
    }

    static func typeOnLineAndCurve(_ out: URL) {
        let r = R()
        let app = AppModel.shared
        app.shapeTool = ShapeToolSettings()
        app.shapeTool.mode = .path
        let d = r.open(SelfTest.baseState(520, 320), name: "type-on-line")
        r.select(.hand); r.select(.line)
        let a = CGPoint(x: 40, y: 250), b = CGPoint(x: 480, y: 150)
        r.dragLine(a, b, steps: 5)
        // hover: the type-on-a-path cursor and hint
        r.select(.text)
        guard let tt = r.toolOf(.text, TextTool.self) else { check(false, "text tool"); return }
        r.move(CGPoint(x: 260, y: 40))
        check(tt.cursor === NSCursor.iBeam, "I-beam away from paths")
        let hp = a.lerp(b, 0.1)
        r.move(hp)
        check(tt.cursor === TypePathCursors.typeOnPath, "type-on-a-path cursor over the line path")
        check(app.statusMessage.contains("type on the path"), "status hint over the path", app.statusMessage)
        let s0 = QASnapshot(d)
        r.click(hp)
        check(TextTool.editing === tt && tt.editingID != nil, "clicking the path starts typing")
        tt.testType("Type flows along the line")
        r.key(R.kEsc, "\u{1b}")
        check(steps(d, s0) == ["Type Layer"], "one history step for the new type", "\(steps(d, s0))")
        guard let id = d.activeLayerID, let t = d.state.layer(id)?.text, let p = t.pathText else { check(false, "type on the line was made"); r.closeAll(); return }
        let len = a.distance(to: b)
        check(p.path.subpaths.count == 1 && p.path.subpaths[0].points.count == 2 && !p.path.subpaths[0].closed, "the text path is the open line")
        check(abs(CGFloat(p.startOffset) - len * 0.1) < 2, "the text starts where it was clicked", "offset \(p.startOffset), want \(len * 0.1)")
        check(d.activePathID == nil, "the work path is deselected once the type takes over its outline")
        check(d.state.paths.count == 1, "the work path is kept in the Paths panel")
        let gs = glyphChecks(t)
        let h = centreHeight(t)
        check(gs.count >= 20, "glyphs placed", "\(gs.count)")
        check(zip(gs, gs.dropFirst()).allSatisfy { $1.s > $0.s }, "glyphs follow the path direction in text order")
        check(gs.allSatisfy { abs($0.dist - h) < 2 && $0.cross < 0 }, "glyph centres sit on the line, on one side",
              "h \(h): \(gs.map { String(format: "%.1f/%.0f", $0.dist, $0.cross) }.prefix(6))")
        check(gs.allSatisfy { $0.angleError < 0.02 }, "glyphs are rotated to the line", "\(gs.map(\.angleError).max() ?? 0)")
        // move along the path with the Path Selection tool
        r.select(.pathSelect)
        let g0 = TextRenderer.layout(t).lines[3].bounds
        let gc = CGPoint(x: g0.midX, y: g0.midY)
        let dir = (b - a).normalized
        let s1 = QASnapshot(d)
        r.dragLine(gc, gc + dir * 40, steps: 4)
        let p1 = d.state.layer(id)?.text?.pathText
        check(abs(CGFloat((p1?.startOffset ?? 0) - p.startOffset) - 40) < 1.5 && p1?.flipped == false, "Path Selection: dragging along the path moves the type",
              "\(p.startOffset) → \(p1?.startOffset ?? -1)")
        check(steps(d, s1) == ["Move Type on Path"], "moving is one history step", "\(steps(d, s1))")
        // across the path: flips to the other side
        guard let t1 = d.state.layer(id)?.text else { return }
        let g1 = TextRenderer.layout(t1).lines[3].bounds
        let gc1 = CGPoint(x: g1.midX, y: g1.midY)
        let nrm = CGPoint(x: -dir.y, y: dir.x)            // (the text side is -nrm)
        let (sNear, _) = PathSampler(p.path).nearest(gc1)
        let across = (PathSampler(p.path).sample(sNear)?.0 ?? gc1) + nrm * 14
        let s2 = QASnapshot(d)
        r.dragLine(gc1, across, steps: 4)
        guard let t2 = d.state.layer(id)?.text, let p2 = t2.pathText else { return }
        check(p2.flipped, "dragging across the path flips the type")
        let anchorBefore = CGFloat(p1?.startOffset ?? 0), total = PathSampler(p.path).total
        check(abs((total - CGFloat(p2.startOffset)) - anchorBefore) < 2, "the flipped type keeps its start point", "\(p2.startOffset) total \(total) anchor \(anchorBefore)")
        let gs2 = glyphChecks(t2)
        check(!gs2.isEmpty && gs2.allSatisfy { $0.cross > 0 && abs($0.dist - h) < 2 && $0.angleError < 0.02 }, "flipped glyphs sit on the other side, reversed",
              "\(gs2.map { String(format: "%.1f/%.0f", $0.dist, $0.cross) }.prefix(5))")
        check(steps(d, s2) == ["Flip Type"], "flipping is one history step", "\(steps(d, s2))")
        // undo: one step each
        d.undo()
        check(d.state.layer(id)?.text?.pathText == p1, "undo the flip")
        d.undo()
        check(d.state.layer(id)?.text?.pathText == p, "undo the move")
        d.redo(); d.redo()
        check(d.state.layer(id)?.text?.pathText == p2, "redo both")
        // ⌘-drag with the Type tool moves it back (and over the type the cursor says so)
        r.select(.text)
        let g3 = TextRenderer.layout(t2).lines[2].bounds
        let gc3 = CGPoint(x: g3.midX, y: g3.midY)
        r.setMods([.command]); r.move(gc3)
        check(tt.cursor === TypePathCursors.moveAlong, "⌘ over type on a path: move cursor")
        let s3 = QASnapshot(d)
        r.dragLine(gc3, gc3 - nrm * 28, steps: 4)
        r.setMods([])
        let p3 = d.state.layer(id)?.text?.pathText
        check(p3?.flipped == false && tt.editingID == nil && steps(d, s3) == ["Flip Type"], "Type tool + ⌘: dragging across flips back, no editor opened",
              "\(String(describing: p3?.flipped)) \(steps(d, s3))")
        // editing: click the type, add text, ⌘-drag while editing, commit = one step
        let t3 = d.state.layer(id)!.text!
        let g4 = TextRenderer.layout(t3).lines[1].bounds
        let s4 = QASnapshot(d)
        r.click(CGPoint(x: g4.midX, y: g4.midY))
        check(tt.isEditing(id), "clicking the type edits it")
        tt.testSelect(NSRange(location: (t3.text as NSString).length, length: 0))
        tt.testType(" and on")
        let g5 = TextRenderer.layout(d.state.layer(id)!.text!).lines[5].bounds
        let gc5 = CGPoint(x: g5.midX, y: g5.midY)
        r.mods = [.command]; r.dragLine(gc5, gc5 + dir * 25, steps: 3); r.mods = []
        check(tt.isEditing(id), "⌘-drag while typing keeps the editor open")
        let movedWhileEditing = d.state.layer(id)?.text?.pathText?.startOffset ?? 0
        r.key(R.kEsc, "\u{1b}")
        let t4 = d.state.layer(id)?.text
        check(t4?.text == "Type flows along the line and on" && abs((t4?.pathText?.startOffset ?? 0) - (p3?.startOffset ?? 0) - 25) < 1.5 && movedWhileEditing == t4?.pathText?.startOffset,
              "edit + move while typing commit together", "\(t4?.text ?? "") \(t4?.pathText?.startOffset ?? -1)")
        check(steps(d, s4) == ["Edit Type Layer"], "editing is one history step", "\(steps(d, s4))")
        d.undo()
        check(d.state.layer(id)?.text == t3, "undo restores text and placement")
        d.redo()
        // moving / transforming the layer carries the path
        let tBefore = d.state.layer(id)!.text!
        let bb = TextRenderer.docBounds(tBefore)
        d.updateLayer(id) { $0.translate(dx: 30, dy: -20) }
        d.commit("Move")
        let ba = TextRenderer.docBounds(d.state.layer(id)!.text!)
        let pm = d.state.layer(id)?.text?.pathText
        check(abs(ba.minX - bb.minX - 30) < 0.5 && abs(ba.minY - bb.minY + 20) < 0.5 && pm?.path == tBefore.pathText?.path
              && pm?.startOffset == tBefore.pathText?.startOffset && pm?.flipped == tBefore.pathText?.flipped,
              "moving the layer moves type and path together")
        check(tBefore.pathText?.source != nil && pm?.source == nil, "moving the layer unlinks the type from the path it was made on (typelink)")
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        let moved = d.state.layer(id)!.text!
        let scaled = LayerTransformer.apply(Homography(affine: CGAffineTransform(scaleX: 1.2, y: 1.2)), to: d.state.layer(id)!, space: sp)
        let tsc = scaled.text!
        let q = PathSampler(tsc.pathText!.path).sample(CGFloat(tsc.pathText!.startOffset))!.0.applying(tsc.transform)
        let q0 = PathSampler(moved.pathText!.path).sample(CGFloat(moved.pathText!.startOffset))!.0.applying(moved.transform)
        check(q.distance(to: q0.applying(CGAffineTransform(scaleX: 1.2, y: 1.2))) < 0.5 && tsc.pathText != nil, "transforming the layer keeps the text on its path")
        d.undo()
        // the start marker shows with the Path Selection tool
        r.select(.pathSelect)
        r.saveOverlayPNG("typepath_line_marker_overlay")

        // a curve (Pen) in the same document: the baseline follows it
        PathOps.deselectPath(d)
        r.select(.pen)
        app.penMode = .path
        r.click(CGPoint(x: 40, y: 110))
        r.down(CGPoint(x: 260, y: 20)); r.drag(CGPoint(x: 340, y: 20)); r.up(CGPoint(x: 340, y: 20))
        r.click(CGPoint(x: 480, y: 110)); r.key(R.kReturn, "\r")
        r.select(.text)
        guard let curve = d.state.paths.first(where: { $0.name == "Work Path" })?.path.subpaths.first, curve.points.count == 3 else {
            check(false, "the curve replaced the deselected Work Path", "\(d.state.paths.map { "\($0.name) \($0.path.subpaths.count)" })"); r.closeAll(); return
        }
        check(d.state.paths.count == 1, "the new path replaced the deselected Work Path")
        let cs = PathSampler(VectorPath(subpaths: [curve]))
        let hc = cs.sample(cs.total * 0.08)!.0
        r.move(hc)
        check(tt.cursor === TypePathCursors.typeOnPath, "type-on-a-path cursor over the curve")
        r.click(hc)
        tt.testType("And bends with every curve of the path")
        r.key(R.kEsc, "\u{1b}")
        if let ct = d.activeLayer?.text, ct.pathText != nil {
            let cg = glyphChecks(ct)
            let ch = centreHeight(ct)
            check(cg.count >= 25 && zip(cg, cg.dropFirst()).allSatisfy { $1.s > $0.s }, "curve: glyphs in order along the path", "\(cg.count)")
            check(cg.allSatisfy { abs($0.dist - ch) < ch * 0.35 && $0.cross < 0 }, "curve: glyph centres follow the curve on one side",
                  "h \(ch): \(cg.map { String(format: "%.1f", $0.dist) })")
            check(cg.allSatisfy { $0.angleError < 0.08 }, "curve: glyphs rotate with the tangent", "\(cg.map(\.angleError).max() ?? 0)")
        } else {
            check(false, "type on the curve was made")
        }
        // snapshot: both type layers with their paths stroked (for looking at)
        var st = d.state
        for l in d.state.allLayers { if let tx = l.text, let pp = tx.pathText {
            var sc = ShapeContent(geometry: .path(pp.path.applying(tx.transform)), fill: .none)
            sc.stroke = StrokeStyle(paint: .color(RGBA(hex: "C0392B")!), width: 1, alignment: .center)
            st.layers.insert(Layer(name: "guide", content: .shape(sc)), at: 1)
        } }
        SelfTest.save(st, "typepath_line_and_curve", out)
        r.select(.hand)
        QAInvariant.idle(r, "type on path")
        r.closeAll()
    }

    // MARK: - Shapes, closed paths, area type

    static func typeOnShapesAndClosedPaths() {
        let r = R()
        let app = AppModel.shared
        var st = SelfTest.baseState(500, 320)
        let ell = Layer(name: "Ellipse", content: .shape(ShapeContent(geometry: .ellipse(CGRect(x: 40, y: 40, width: 180, height: 120)), fill: .color(RGBA(hex: "2E86AB")!))))
        let line = Layer(name: "Line", content: .shape(ShapeContent(geometry: .line(CGPoint(x: 260, y: 280), CGPoint(x: 470, y: 200), weight: 6), fill: .color(.black))))
        st.layers += [ell, line]
        let d = r.open(st, name: "shapes")
        r.select(.hand); r.select(.text)
        guard let tt = r.toolOf(.text, TextTool.self) else { return }
        // shape outline
        let top = CGPoint(x: 130, y: 40)
        r.move(top)
        check(tt.cursor === TypePathCursors.typeOnPath, "type-on-a-path cursor over a shape layer's outline")
        r.click(top); tt.testType("Round"); r.key(R.kEsc, "\u{1b}")
        check(d.activeLayer?.text?.pathText?.path.subpaths.first?.closed == true, "type on the ellipse's outline (closed path)")
        check(d.state.layer(ell.id)?.shape == ell.shape, "the shape layer is unchanged")
        // a Line shape offers its centre line (open), not the outline of its weight
        let lm = CGPoint(x: 260, y: 280).lerp(CGPoint(x: 470, y: 200), 0.2)
        r.move(lm)
        check(tt.cursor === TypePathCursors.typeOnPath, "type-on-a-path cursor over a Line shape")
        r.click(lm); tt.testType("Line"); r.key(R.kEsc, "\u{1b}")
        let lp = d.activeLayer?.text?.pathText?.path.subpaths.first
        check(lp?.points.count == 2 && lp?.closed == false, "type on a Line shape follows its centre line", "\(lp?.points.count ?? 0) points")
        check(d.state.layer(line.id)?.shape == line.shape, "the Line shape is unchanged")
        // a closed work path: outline → type on the path, inside → area type
        app.shapeTool = ShapeToolSettings(); app.shapeTool.mode = .path
        r.select(.ellipse)
        r.dragLine(CGPoint(x: 280, y: 30), CGPoint(x: 460, y: 170), steps: 4)
        r.select(.text)
        r.move(CGPoint(x: 280, y: 100))
        check(tt.cursor === TypePathCursors.typeOnPath, "type-on-a-path cursor over a closed path's outline")
        r.move(CGPoint(x: 370, y: 100))
        check(tt.cursor === TypePathCursors.areaType, "area type cursor inside a closed path")
        let n0 = d.state.allLayers.count
        r.click(CGPoint(x: 370, y: 100)); tt.testType("Area type inside the ellipse path keeps working as before."); r.key(R.kEsc, "\u{1b}")
        check(d.state.allLayers.count == n0 + 1 && d.activeLayer?.text?.area != nil, "clicking inside a closed path makes area type")
        // Type ▸ Type on Path with an active path
        let n1 = d.state.allLayers.count
        if let pid = d.state.paths.first?.id { PathOps.selectPath(d, pid) }
        TypeOnPath.startFromMenu()
        check(tt.editingID != nil && d.state.layer(tt.editingID!)?.text?.pathText != nil, "Type ▸ Type on Path starts type on the active path")
        tt.testType("Menu"); r.key(R.kEsc, "\u{1b}")
        check(d.state.allLayers.count == n1 + 1, "menu type committed")
        r.select(.hand)
        QAInvariant.idle(r, "shapes")
        r.closeAll()
    }

    // MARK: - Alignment, tracking, baseline shift

    static func layoutOptions() {
        let line = VectorPath(subpaths: [Subpath(points: [PathPoint(CGPoint(x: 20, y: 200)), PathPoint(CGPoint(x: 620, y: 200))])])
        var t = TextContent()
        t.text = "Alignment"; t.fontName = "Helvetica"; t.fontSize = 30
        t.pathText = TextOnPath(path: line, startOffset: 300)
        func firstLast(_ x: TextContent) -> (CGFloat, CGFloat) {
            let g = glyphChecks(x)
            return (g.first?.s ?? 0, g.last?.s ?? 0)
        }
        let (l0, l1) = firstLast(t)
        var c = t; c.alignment = .center
        var rr = t; rr.alignment = .right
        let (c0, c1) = firstLast(c), (r0, r1) = firstLast(rr)
        let w = l1 - l0
        check(abs(l0 - 300) < 15 && abs((c0 + c1) / 2 - 300) < 3 && abs(r1 - 300) < 15, "left / centre / right alignment around the start point",
              "left \(l0)…\(l1) centre \(c0)…\(c1) right \(r0)…\(r1)")
        check(abs((c1 - c0) - w) < 1 && abs((r1 - r0) - w) < 1, "alignment keeps the glyph spacing")
        var tr = t; tr.tracking = 200
        let (t0, t1) = firstLast(tr)
        check((t1 - t0) - w > 0.15 * 30 * 7, "tracking spreads the glyphs along the path", "\(w) → \(t1 - t0)")
        // baseline shift: the glyph ink moves off the path (measured on the outlines, the layout boxes don't move)
        var bs = t; bs.baselineShift = 10
        let h0 = inkHeights(t), h1 = inkHeights(bs)
        let shift = zip(h0, h1).map { $1 - $0 }
        check(shift.count == 9 && shift.allSatisfy { abs($0 - 10) < 1 }, "baseline shift lifts the glyphs off the path", "\(shift.prefix(4))")
        var mixed = t
        mixed.applyStyle(CharacterStyle(baselineShift: -8), to: NSRange(location: 0, length: 3))
        let hm = inkHeights(mixed)
        check(hm.count == h0.count && abs((h0[0] - hm[0]) - 8) < 1 && abs(hm[5] - h0[5]) < 0.5, "per-character baseline shift on a path",
              "\(hm.prefix(6)) vs \(h0.prefix(6))")
        // on a curve too
        var cv = t
        cv.pathText = TextOnPath(path: VectorPath(subpaths: [Subpath(points: [
            PathPoint(anchor: CGPoint(x: 20, y: 300), inControl: CGPoint(x: 20, y: 300), outControl: CGPoint(x: 200, y: 0)),
            PathPoint(anchor: CGPoint(x: 600, y: 300), inControl: CGPoint(x: 420, y: 0), outControl: CGPoint(x: 600, y: 300))])]), startOffset: 120)
        var cvs = cv; cvs.baselineShift = 10
        let cshift = zip(inkHeights(cv), inkHeights(cvs)).map { $1 - $0 }
        check(cshift.count == 9 && cshift.allSatisfy { abs($0 - 10) < 2 }, "baseline shift on a curve", "\(cshift.prefix(5))")
    }

    /// Height of each glyph's ink centre above the path (layer space; positive = the text side).
    static func inkHeights(_ t: TextContent) -> [CGFloat] {
        guard let p = t.pathText else { return [] }
        let sampler = PathSampler(p.path, flipped: p.flipped)
        var out: [CGFloat] = []
        for pl in TextRenderer.layout(t).lines {
            let path = CGMutablePath()
            for sl in pl.drawnRuns {
                let attrs = CTRunGetAttributes(sl.run) as NSDictionary
                guard let fo = attrs[kCTFontAttributeName as String] else { continue }
                let font = fo as! CTFont
                let n = CTRunGetGlyphCount(sl.run)
                var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
                CTRunGetGlyphs(sl.run, CFRange(location: 0, length: n), &glyphs)
                CTRunGetPositions(sl.run, CFRange(location: 0, length: n), &pos)
                for g in sl.range.location..<min(n, sl.range.location + max(1, sl.range.length)) {
                    if let gp = CTFontCreatePathForGlyph(font, glyphs[g], nil) {
                        path.addPath(gp, transform: CGAffineTransform(translationX: pos[g].x, y: pos[g].y).concatenating(pl.transform))
                    }
                }
            }
            let b = path.boundingBoxOfPath
            guard !b.isNull else { continue }
            let c = CGPoint(x: b.midX, y: b.midY)
            let (s, _) = sampler.nearest(c)
            guard let (q, ang) = sampler.sample(s) else { continue }
            let v = c - q
            out.append(-(cos(ang) * v.y - sin(ang) * v.x))
        }
        return out
    }

    // MARK: - Save / load, PSD

    static func persistence(_ out: URL) {
        var st = SelfTest.baseState(400, 260)
        let curve = VectorPath(subpaths: [Subpath(points: [
            PathPoint(anchor: CGPoint(x: 30, y: 200), inControl: CGPoint(x: 30, y: 200), outControl: CGPoint(x: 120, y: 40)),
            PathPoint(anchor: CGPoint(x: 370, y: 200), inControl: CGPoint(x: 280, y: 40), outControl: CGPoint(x: 370, y: 200))])])
        var t = TextContent()
        t.text = "Saved on a path"; t.fontName = "Helvetica-Bold"; t.fontSize = 30; t.color = RGBA(hex: "8E44AD")!
        t.pathText = TextOnPath(path: curve, startOffset: 40, flipped: false)
        t.transform = CGAffineTransform(translationX: 5, y: 8)
        var t2 = t; t2.text = "Flipped"; t2.pathText?.flipped = true; t2.pathText?.startOffset = 200
        st.layers += [Layer(name: "on path", content: .text(t)), Layer(name: "flipped", content: .text(t2))]
        st.paths = [NamedPath(name: "Path 1", path: curve)]
        let d = Document(state: st, name: "persist")
        let url = out.appendingPathComponent("typepath_roundtrip.imagecrat")
        do {
            try DocumentIO.saveNative(d, to: url)
            let back = try DocumentIO.load(url: url)
            let texts = back.state.allLayers.compactMap(\.text)
            check(texts.count == 2 && texts[0].pathText == t.pathText && texts[1].pathText == t2.pathText && texts[0].transform == t.transform,
                  ".imagecrat keeps type on a path (path, start, flip, transform)")
            check(QAMeasure.fingerprint(back.state) == QAMeasure.fingerprint(d.state), ".imagecrat round trip is identical")
        } catch { check(false, ".imagecrat round trip", "\(error)") }
        let psd = out.appendingPathComponent("typepath_export.psd")
        do {
            try PSDWriter.write(d.state, to: psd)
            let notes = PSDExport.lastNotes
            check(notes.contains { $0.detail.contains("Type on a path") }, "PSD export notes the point-text approximation",
                  notes.map(\.detail).joined(separator: " | "))
            let res = try PSDImporter.read(data: try Data(contentsOf: psd), name: "typepath_export.psd", baseURL: out)
            let names = res.state.allLayers.map(\.name)
            check(names.contains("on path") && names.contains("flipped"), "PSD export → import keeps the type layers", "\(names)")
            check(res.state.paths.contains { $0.name == "Path 1" }, "PSD keeps the saved path")
        } catch { check(false, "PSD export of type on a path", "\(error)") }
    }
}
