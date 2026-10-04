import ImageCratCore
import AppKit

/// Type on a path stays linked to its source path / shape, and its own type path is editable: Direct Selection, Path
/// Selection and the anchor tools on a source work path, on a source shape (geometry, Free Transform, Move, anchors)
/// and on the type path itself (the link breaks), deleting the source, replacing the Work Path, components removed,
/// undo / redo, duplicate, `.imagecrat` and old documents, PSD. Driven through the real tools where it can be.
/// `LUMEN_SELFTEST_ONLY=typelink Lumen --selftest <dir>`
enum TypePathLinkSelfTest {
    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") typelink: \(name)\(d.isEmpty ? "" : " — " + d)")
        fflush(stdout)
    }
    static func info(_ s: String) { print("INFO typelink: \(s)"); fflush(stdout) }

    typealias R = ToolRobot
    typealias TP = TypePathSelfTest

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
        app.textTool.fontSize = 24
        app.textTool.color = RGBA(hex: "1B1F3A")!
        workPathSource(out)
        shapeSource()
        typePathEditing()
        sourcesGoingAway()
        persistence(out)
        print("typelink: \(passes) checks passed, \(failures) failed")
    }

    // MARK: - Helpers

    static func steps(_ d: Document, _ s: QASnapshot) -> [String] { TP.steps(d, s) }

    static func pathText(_ d: Document, _ id: UUID) -> TextOnPath? { d.state.layer(id)?.text?.pathText }

    /// The text layer's path in document coordinates.
    static func docPath(_ d: Document, _ id: UUID) -> VectorPath? {
        guard let t = d.state.layer(id)?.text, let p = t.pathText else { return nil }
        return p.path.applying(t.transform)
    }

    static func same(_ a: VectorPath?, _ b: Subpath?) -> Bool {
        guard let a, let b, a.subpaths.count == 1 else { return false }
        return TypePathLink.close(a.subpaths[0], b, eps: 0.01)
    }

    static func anchors(_ p: VectorPath?) -> String {
        (p?.subpaths.first?.points ?? []).map { String(format: "(%.1f,%.1f)", $0.anchor.x, $0.anchor.y) }.joined(separator: " ")
    }

    /// Types `text` on the path under `p` with the Type tool; returns the new layer.
    static func typeOn(_ r: R, _ d: Document, at p: CGPoint, _ text: String) -> UUID? {
        r.select(.text)
        guard let tt = r.toolOf(.text, TextTool.self) else { return nil }
        r.click(p)
        guard tt.editingID != nil else { return nil }
        tt.testType(text)
        r.key(R.kEsc, "\u{1b}")
        guard let id = d.activeLayerID, d.state.layer(id)?.text?.pathText != nil else { return nil }
        return id
    }

    // MARK: - A work path as the source

    static func workPathSource(_ out: URL) {
        let r = R()
        let app = AppModel.shared
        let d = r.open(SelfTest.baseState(520, 320), name: "link-workpath")
        app.penMode = .path
        r.select(.hand); r.select(.pen)
        let a = CGPoint(x: 60, y: 240), b = CGPoint(x: 460, y: 140)
        r.click(a); r.click(b); r.key(R.kReturn, "\r")
        guard let wp = d.state.paths.first, wp.path.subpaths.first?.points.count == 2 else { check(false, "pen work path"); r.closeAll(); return }
        guard let id = typeOn(r, d, at: a.lerp(b, 0.1), "Linked to the work path") else { check(false, "type on the work path"); r.closeAll(); return }
        let p0 = pathText(d, id)!
        check(p0.source?.pathID == wp.id && p0.source?.layerID == nil && p0.source?.subpath == 0 && p0.source?.subpathCount == 1,
              "type made on a work path is linked to it", "\(String(describing: p0.source))")
        check(same(docPath(d, id), wp.path.subpaths[0]) && p0.source?.synced == wp.path.subpaths[0], "the text path starts as the work path")
        // nothing to do: no assignment, no history step, no loop
        let rev = d.renderVersion, hc = d.history.count
        d.state = d.state
        check(pathText(d, id) == p0 && d.renderVersion == rev + 1 && d.history.count == hc, "an unrelated state change leaves the link alone (one render, no extra change)",
              "render \(rev) → \(d.renderVersion)")
        // the type layer's own path is the path tools' target while no other path is selected
        check(VectorEditing.currentTarget(d) == .typePath(id), "with the type layer selected, its type path is the target")
        let name = d.state.layer(id)!.name
        check(PathOps.actionPath(d)?.name == "\(name) Type Path", "the Paths panel / path commands see \"<layer> Type Path\"", PathOps.actionPath(d)?.name ?? "nil")

        // Direct Selection on the selected work path: drag its end anchor, the text re-flows live, one step
        PathOps.selectPath(d, wp.id)
        r.select(.directSelect)
        let b2 = CGPoint(x: 460, y: 60)
        let s0 = QASnapshot(d)
        var liveOK = true
        r.dragLine(b, b2, steps: 5) { _ in
            let w = d.state.paths.first { $0.id == wp.id }?.path.subpaths.first
            if !same(docPath(d, id), w) { liveOK = false }
        }
        let w1 = d.state.paths.first { $0.id == wp.id }!.path.subpaths[0]
        check(w1.points[1].anchor.distance(to: b2) < 0.6, "Direct Selection moved the work path's anchor", anchors(VectorPath(subpaths: [w1])))
        check(liveOK, "the text path follows live while dragging")
        check(same(docPath(d, id), w1) && pathText(d, id)?.source?.synced == w1, "the text path follows the edited work path", anchors(docPath(d, id)))
        check(steps(d, s0) == ["Edit Path"], "path edit + text re-flow are one history step", "\(steps(d, s0))")
        let t1 = d.state.layer(id)!.text!
        let gs = TP.glyphChecks(t1)
        check(gs.count >= 15 && gs.allSatisfy { abs($0.dist - TP.centreHeight(t1)) < 2 && $0.cross < 0 }, "the glyphs sit on the new path", "\(gs.count) glyphs")
        let len0 = a.distance(to: b), len1 = a.distance(to: b2)
        check(abs(pathText(d, id)!.startOffset - p0.startOffset) < 0.01 && len1 > len0, "an open path keeps the start offset", "\(p0.startOffset) → \(pathText(d, id)!.startOffset)")
        d.undo()
        check(pathText(d, id) == p0 && d.state.paths[0].path == wp.path, "undo: work path and text back together")
        d.redo()
        check(same(docPath(d, id), w1) && pathText(d, id)?.source != nil, "redo: both edited again")

        // Add Anchor Point on the work path: the text path gets the anchor too
        r.select(.addAnchor)
        let mid = a.lerp(b2, 0.5)
        let s1 = QASnapshot(d)
        r.click(mid)
        let w2 = d.state.paths.first { $0.id == wp.id }!.path.subpaths[0]
        check(w2.points.count == 3 && same(docPath(d, id), w2) && steps(d, s1) == ["Add Anchor Point"], "Add Anchor Point on the source: the text follows, one step",
              "\(w2.points.count) points, \(steps(d, s1))")
        // drag the new anchor with Direct Selection: a curve
        r.select(.directSelect)
        let s2 = QASnapshot(d)
        r.dragLine(w2.points[1].anchor, w2.points[1].anchor + CGPoint(x: 0, y: -50), steps: 4)
        let w3 = d.state.paths.first { $0.id == wp.id }!.path.subpaths[0]
        check(same(docPath(d, id), w3) && steps(d, s2) == ["Edit Path"], "dragging the added anchor bends the text with it", "\(steps(d, s2))")
        // Path Selection drags the whole work path (clicked away from the type): the text moves with it
        r.select(.pathSelect)
        let grab = CGPoint(x: 300, y: 290), delta = CGPoint(x: -20, y: 15)
        let s3 = QASnapshot(d)
        r.dragLine(grab, grab + delta, steps: 4)
        let w4 = d.state.paths.first { $0.id == wp.id }!.path.subpaths[0]
        check(w4.points[0].anchor.distance(to: a + delta) < 0.6 && same(docPath(d, id), w4) && steps(d, s3) == ["Move Path"],
              "Path Selection moves the work path; the text moves with it, one step", "\(anchors(VectorPath(subpaths: [w4]))) \(steps(d, s3))")
        // the text dragged along its path keeps the link
        let tm = d.state.layer(id)!.text!
        let g0 = TextRenderer.layout(tm).lines[3].bounds
        PathOps.deselectPath(d)
        let gc = CGPoint(x: g0.midX, y: g0.midY)
        let tan = (w4.points[1].anchor - w4.points[0].anchor).normalized
        r.dragLine(gc, gc + tan * 30, steps: 3)
        check(pathText(d, id)?.source != nil && pathText(d, id)!.startOffset > tm.pathText!.startOffset + 10, "moving the type along its path keeps the link",
              "\(tm.pathText!.startOffset) → \(pathText(d, id)!.startOffset)")
        // a component added to the work path: still linked to the same subpath
        PathOps.selectPath(d, wp.id)
        r.select(.pen)
        r.click(CGPoint(x: 80, y: 40)); r.click(CGPoint(x: 200, y: 30)); r.key(R.kReturn, "\r")
        check(d.state.paths[0].path.subpaths.count == 2 && pathText(d, id)?.source?.subpath == 0 && pathText(d, id)?.source?.subpathCount == 2
              && same(docPath(d, id), d.state.paths[0].path.subpaths[0]), "a component added to the source keeps the link on its subpath",
              "\(String(describing: pathText(d, id)?.source.map { ($0.subpath, $0.subpathCount) }))")
        // the other component removed: the subpath is found again
        d.state.paths[0].path.subpaths.remove(at: 1)
        d.commit("Delete Component")
        var src = pathText(d, id)?.source
        check(src?.subpath == 0 && src?.subpathCount == 1, "a component removed after it: still linked", "\(String(describing: src.map { ($0.subpath, $0.subpathCount) }))")
        // a component inserted before it: the index moves up
        d.state.paths[0].path.subpaths.insert(Subpath(points: [PathPoint(CGPoint(x: 20, y: 20)), PathPoint(CGPoint(x: 90, y: 30))]), at: 0)
        d.commit("Add Component")
        src = pathText(d, id)?.source
        check(src?.subpath == 1 && src?.subpathCount == 2, "a component inserted before it: still linked (index looked up again)",
              "\(String(describing: src.map { ($0.subpath, $0.subpathCount) }))")
        d.state.paths[0].path.subpaths[1].points[0].anchor.y += 10
        d.commit("Edit Path")
        check(same(docPath(d, id), d.state.paths[0].path.subpaths[1]), "…and keeps following it there")
        // its own component deleted: the link breaks, the text stays
        let kept = pathText(d, id)!.path
        d.state.paths[0].path.subpaths.remove(at: 1)
        d.commit("Delete Component")
        check(pathText(d, id)?.source == nil && pathText(d, id)?.path == kept, "its subpath deleted: the link breaks, the text stays")
        d.undo()
        check(pathText(d, id)?.source?.subpath == 1, "undo: linked again")
        // overlay: the type layer's own path shows with any tool once the work path is deselected
        PathOps.deselectPath(d)
        r.select(.brush)
        let onPath = PathSampler(docPath(d, id)!).sample(PathSampler(docPath(d, id)!).total * 0.9)!.0
        check(TP.inkAt(r, onPath) > 0, "the selected type layer's path is drawn on the canvas (Brush tool)")
        SelfTest.save(d.state, "typelink_workpath", out)
        r.select(.hand)
        QAInvariant.idle(r, "typelink work path")
        r.closeAll()
    }

    // MARK: - A shape layer as the source

    static func shapeSource() {
        let r = R()
        var st = SelfTest.baseState(520, 360)
        let ell = Layer(name: "Ellipse", content: .shape(ShapeContent(geometry: .ellipse(CGRect(x: 60, y: 60, width: 240, height: 160)), fill: .color(RGBA(hex: "2E86AB")!))))
        st.layers.append(ell)
        let d = r.open(st, name: "link-shape")
        r.select(.hand)
        let top = CGPoint(x: 180, y: 60)
        guard let id = typeOn(r, d, at: top, "Round and round") else { check(false, "type on the ellipse"); r.closeAll(); return }
        let p0 = pathText(d, id)!
        check(p0.source?.layerID == ell.id && p0.source?.pathID == nil, "type made on a shape outline is linked to the shape layer", "\(String(describing: p0.source))")
        func shapeSub() -> Subpath? { d.state.layer(ell.id)?.shape.map { TypeOnPath.subpaths(of: $0)[p0.source?.subpath ?? 0] } }
        // live geometry change (Properties panel: the ellipse's rectangle)
        let total0 = PathSampler(p0.path).total
        let frac0 = CGFloat(p0.startOffset) / total0
        let s0 = QASnapshot(d)
        d.updateLayer(ell.id) { $0.shape?.geometry = .ellipse(CGRect(x: 40, y: 40, width: 400, height: 260)) }
        check(same(docPath(d, id), shapeSub()), "changing the ellipse's size re-flows the text right away (before the step is recorded)")
        d.commit("Edit Shape")
        check(steps(d, s0) == ["Edit Shape"], "one history step", "\(steps(d, s0))")
        let p1 = pathText(d, id)!
        let total1 = PathSampler(p1.path).total
        check(abs(CGFloat(p1.startOffset) / total1 - frac0) < 0.001 && p1.startOffset <= Double(total1), "a closed path keeps the start point's share of the perimeter",
              "\(p0.startOffset)/\(total0) → \(p1.startOffset)/\(total1)")
        // Free Transform of the shape
        d.selectLayer(ell.id)
        if let ts = TransformSession(doc: d, layerIDs: [ell.id]) {
            let s1 = QASnapshot(d)
            ts.quad = ts.quad.mapped { CGPoint(x: $0.x * 0.8 + 30, y: $0.y * 0.9 + 10) }
            ts.updatePreview()
            ts.commit()
            check(steps(d, s1) == ["Free Transform"] && same(docPath(d, id), shapeSub()), "Free Transform of the shape: the text follows in the same step",
                  "\(steps(d, s1)) \(anchors(docPath(d, id)))")
        } else { check(false, "free transform session") }
        // Move tool on the shape
        r.select(.move)
        let c = d.state.layer(ell.id)!.shape!.path.bounds
        let from = CGPoint(x: c.midX, y: c.midY)
        let s2 = QASnapshot(d)
        r.dragLine(from, from + CGPoint(x: 25, y: 30), steps: 4)
        let moved = steps(d, s2)
        check(moved.count == 1 && same(docPath(d, id), shapeSub()) && pathText(d, id)?.source != nil, "moving the shape (Move tool) moves the text with it",
              "\(moved) \(anchors(docPath(d, id)))")
        // Direct Selection on the shape's anchor: the shape becomes a path, the text follows
        r.select(.directSelect)
        guard let sp = shapeSub() else { check(false, "shape subpath"); r.closeAll(); return }
        let anchor = sp.points[0].anchor
        let s3 = QASnapshot(d)
        r.dragLine(anchor, anchor + CGPoint(x: 30, y: 0), steps: 4)
        check(steps(d, s3) == ["Edit Path"] && same(docPath(d, id), shapeSub()) && pathText(d, id)?.source != nil, "Direct Selection on the shape's anchor reshapes the text too",
              "\(steps(d, s3))")
        d.undo()
        check(same(docPath(d, id), shapeSub()), "undo: shape and text back together")
        d.redo()
        // Duplicate Layer: the copy keeps the link, both follow the shape
        d.selectLayer(id)
        AppActions.duplicateLayers()
        guard let dup = d.activeLayerID, dup != id, pathText(d, dup)?.source == pathText(d, id)?.source else { check(false, "the duplicated type keeps the link"); r.closeAll(); return }
        check(true, "the duplicated type keeps the link")
        d.updateLayer(ell.id) { $0.translate(dx: 0, dy: 20) }
        d.commit("Move")
        check(same(docPath(d, id), shapeSub()) && same(docPath(d, dup), shapeSub()), "both type layers follow the shape")
        // Move the type layer itself: its path moves along, the link breaks (the shape stays)
        d.selectLayer(dup)
        let before = docPath(d, dup)!
        let shapeBefore = d.state.layer(ell.id)!.shape
        r.select(.move)
        let gl = TextRenderer.layout(d.state.layer(dup)!.text!).lines[2].bounds.applying(d.state.layer(dup)!.text!.transform)
        let g = CGPoint(x: gl.midX, y: gl.midY)
        let s4 = QASnapshot(d)
        r.dragLine(g, g + CGPoint(x: 40, y: 0), steps: 4)   // (auto-select is off in automated runs: the active layer moves)
        let after = docPath(d, dup)
        check(steps(d, s4).count == 1 && after?.subpaths.first?.points.first.map { $0.anchor.distance(to: before.subpaths[0].points[0].anchor + CGPoint(x: 40, y: 0)) < 0.6 } == true,
              "the Move tool moves the type with its path", "\(steps(d, s4)) \(anchors(before)) → \(anchors(after))")
        check(pathText(d, dup)?.source == nil && d.state.layer(ell.id)?.shape == shapeBefore, "moving the type breaks its link; the shape is untouched")
        check(pathText(d, id)?.source != nil, "the other type layer is still linked")
        d.updateLayer(ell.id) { $0.translate(dx: -15, dy: 0) }
        d.commit("Move")
        check(docPath(d, dup) == after && same(docPath(d, id), shapeSub()), "after the break the moved type ignores the shape; the linked one follows")
        d.undo(); d.undo()
        check(pathText(d, dup)?.source != nil && same(docPath(d, dup), shapeSub()), "undo the type move: linked again, back on the shape")
        r.select(.hand)
        QAInvariant.idle(r, "typelink shape")
        r.closeAll()
    }

    // MARK: - Editing the type path itself

    static func typePathEditing() {
        let r = R()
        let app = AppModel.shared
        let d = r.open(SelfTest.baseState(520, 320), name: "link-typepath")
        app.penMode = .path
        r.select(.hand); r.select(.pen)
        let a = CGPoint(x: 60, y: 220), b = CGPoint(x: 260, y: 120), c = CGPoint(x: 460, y: 220)
        r.click(a); r.click(b); r.click(c); r.key(R.kReturn, "\r")
        guard let wp = d.state.paths.first else { check(false, "pen path"); r.closeAll(); return }
        guard let id = typeOn(r, d, at: a.lerp(b, 0.2), "The type owns its path") else { check(false, "type on the path"); r.closeAll(); return }
        check(d.activePathID == nil && VectorEditing.currentTarget(d) == .typePath(id), "after typing, the type path is the path tools' target")
        // the type path's anchors show with Direct Selection
        r.select(.directSelect)
        check(TP.inkAt(r, b) > 0, "Direct Selection shows the type path's anchors")
        // drag the middle anchor of the type path: the text re-flows, the work path is untouched, the link breaks
        let b2 = b + CGPoint(x: 0, y: -60)
        let s0 = QASnapshot(d)
        var live = false
        r.dragLine(b, b2, steps: 4) { i in if i == 2, let p = docPath(d, id), p.subpaths[0].points[1].anchor.y < b.y - 20 { live = true } }
        let tp = docPath(d, id)
        check(tp?.subpaths.first?.points[1].anchor.distance(to: b2) ?? 99 < 0.6 && live, "Direct Selection drags the type path's anchor (live)", anchors(tp))
        check(d.state.paths[0].path == wp.path, "the work path it was made from is untouched")
        check(pathText(d, id)?.source == nil, "editing the type path directly breaks the link")
        check(steps(d, s0) == ["Edit Path"], "one history step", "\(steps(d, s0))")
        d.undo()
        check(pathText(d, id)?.source?.pathID == wp.id && same(docPath(d, id), wp.path.subpaths[0]), "undo: the type path and its link are back")
        d.redo()
        // the source edited after the break: the type no longer follows
        let owned = pathText(d, id)
        d.state.paths[0].path.subpaths[0].points[0] = PathPoint(CGPoint(x: 40, y: 280))
        d.commit("Edit Path")
        check(pathText(d, id) == owned, "after the break, editing the old source leaves the type alone")
        // Path Selection drags the type path (away from the type): path and text move, the work path doesn't
        r.select(.pathSelect)
        let grab = CGPoint(x: 260, y: 300), delta = CGPoint(x: 10, y: -12)
        let before = docPath(d, id)!
        let s1 = QASnapshot(d)
        r.dragLine(grab, grab + delta, steps: 3)
        let moved = docPath(d, id)
        check(moved?.subpaths.first?.points[0].anchor.distance(to: before.subpaths[0].points[0].anchor + delta) ?? 99 < 0.6 && steps(d, s1) == ["Move Path"],
              "Path Selection moves the type path", "\(anchors(before)) → \(anchors(moved)) \(steps(d, s1))")
        // anchor tools on the type path
        r.select(.addAnchor)
        let m = moved!.subpaths[0]
        let seg = PathSampler(VectorPath(subpaths: [Subpath(points: [m.points[0], m.points[1]])]))
        let onSeg = seg.sample(seg.total / 2)!.0
        let s2 = QASnapshot(d)
        r.click(onSeg)
        check(docPath(d, id)?.subpaths.first?.points.count == 4 && steps(d, s2) == ["Add Anchor Point"], "Add Anchor Point works on the type path",
              "\(docPath(d, id)?.subpaths.first?.points.count ?? 0) \(steps(d, s2))")
        r.select(.deleteAnchor)
        let s3 = QASnapshot(d)
        r.click(docPath(d, id)!.subpaths[0].points[1].anchor)
        check(docPath(d, id)?.subpaths.first?.points.count == 3 && steps(d, s3) == ["Delete Anchor Point"], "Delete Anchor Point works on the type path",
              "\(docPath(d, id)?.subpaths.first?.points.count ?? 0) \(steps(d, s3))")
        // never below two anchors
        r.click(docPath(d, id)!.subpaths[0].points[0].anchor)
        let s4 = QASnapshot(d)
        r.click(docPath(d, id)!.subpaths[0].points[0].anchor)
        check(docPath(d, id)?.subpaths.first?.points.count == 2 && d.state.layer(id)?.text?.pathText != nil && steps(d, s4).isEmpty,
              "deleting anchors keeps at least a 2-anchor type path (no empty step)", "\(docPath(d, id)?.subpaths.first?.points.count ?? 0) \(steps(d, s4))")
        // start offset stays on the shorter path
        let pt = pathText(d, id)!
        check(pt.startOffset >= 0 && pt.startOffset <= Double(PathSampler(pt.path).total) + 0.01, "the start offset is clamped to the path", "\(pt.startOffset) / \(PathSampler(pt.path).total)")
        // a locked type layer: the type path can't be edited
        d.updateLayer(id) { $0.locks.all = true }
        d.commit("Lock")
        let lockedPath = docPath(d, id)
        r.select(.directSelect)
        let q = lockedPath!.subpaths[0].points[0].anchor
        r.dragLine(q, q + CGPoint(x: 20, y: 20), steps: 3)
        check(docPath(d, id) == lockedPath, "a locked type layer's path is not edited")
        r.select(.hand)
        QAInvariant.idle(r, "typelink type path")
        r.closeAll()
    }

    // MARK: - Sources going away

    static func sourcesGoingAway() {
        let r = R()
        let app = AppModel.shared
        var st = SelfTest.baseState(520, 360)
        let rect = Layer(name: "Rect", content: .shape(ShapeContent(geometry: .rectangle(CGRect(x: 280, y: 200, width: 200, height: 120), cornerRadius: 0), fill: .color(.black))))
        st.layers.append(rect)
        let d = r.open(st, name: "link-gone")
        app.penMode = .path
        r.select(.hand); r.select(.pen)
        let a = CGPoint(x: 40, y: 120), b = CGPoint(x: 440, y: 60)
        r.click(a); r.click(b); r.key(R.kReturn, "\r")
        guard let wp = d.state.paths.first, let id = typeOn(r, d, at: a.lerp(b, 0.1), "Deleted source") else { check(false, "type on the work path"); r.closeAll(); return }
        // the Work Path replaced by a new path: the type keeps its path
        let p0 = pathText(d, id)!
        r.select(.pen)
        let sp = QASnapshot(d)
        r.click(CGPoint(x: 40, y: 300)); r.click(CGPoint(x: 200, y: 330)); r.key(R.kReturn, "\r")
        let penSteps = steps(d, sp).count
        check(d.state.paths.count == 1 && d.state.paths[0].id == wp.id && d.state.paths[0].path != wp.path, "a new pen path replaced the deselected Work Path")
        check(pathText(d, id)?.path == p0.path && pathText(d, id)?.source == nil, "replacing the Work Path unlinks the type; it keeps its path")
        for _ in 0..<penSteps { d.undo() }
        check(pathText(d, id) == p0 && d.state.paths[0].path == wp.path, "undo: linked again", "\(penSteps) steps")
        // deleting the source path: the type stays put, unlinked, same step
        let s0 = QASnapshot(d)
        AppActions.deletePath(wp.id)
        check(d.state.paths.isEmpty && pathText(d, id)?.path == p0.path && pathText(d, id)?.source == nil && steps(d, s0) == ["Delete Path"],
              "deleting the source path: the type stays where it is, unlinked in the same step", "\(steps(d, s0))")
        d.undo()
        check(pathText(d, id) == p0 && d.state.paths.count == 1, "undo the delete: path and link back")
        d.redo()
        check(pathText(d, id)?.source == nil, "redo: unlinked again")
        // a shape source deleted
        let top = CGPoint(x: 380, y: 200)
        guard let sid = typeOn(r, d, at: top, "On the rectangle") else { check(false, "type on the rectangle"); r.closeAll(); return }
        let q0 = pathText(d, sid)!
        check(q0.source?.layerID == rect.id && q0.path.subpaths.first?.closed == true, "type on the rectangle is linked to it")
        d.selectLayer(rect.id)
        AppActions.deleteLayers()
        check(d.state.layer(rect.id) == nil && pathText(d, sid)?.path == q0.path && pathText(d, sid)?.source == nil, "deleting the source shape layer: the type stays put, unlinked")
        d.undo()
        check(pathText(d, sid) == q0, "undo: shape and link back")
        // the shape rasterized: no longer a shape, the link breaks
        d.updateLayer(rect.id) { $0.content = .raster(RasterContent(buffer: PixelBuffer(width: 4, height: 4), origin: IPoint(x: 0, y: 0))) }
        d.commit("Rasterize")
        check(pathText(d, sid)?.source == nil && pathText(d, sid)?.path == q0.path, "a rasterized source breaks the link")
        r.select(.hand)
        QAInvariant.idle(r, "typelink gone")
        r.closeAll()
    }

    // MARK: - Save / load, old documents, PSD

    static func persistence(_ out: URL) {
        var st = SelfTest.baseState(400, 260)
        let curve = Subpath(points: [
            PathPoint(anchor: CGPoint(x: 30, y: 200), inControl: CGPoint(x: 30, y: 200), outControl: CGPoint(x: 120, y: 40)),
            PathPoint(anchor: CGPoint(x: 370, y: 200), inControl: CGPoint(x: 280, y: 40), outControl: CGPoint(x: 370, y: 200))])
        let np = NamedPath(name: "Path 1", path: VectorPath(subpaths: [curve]))
        var t = TextContent()
        t.text = "Saved and linked"; t.fontName = "Helvetica-Bold"; t.fontSize = 26
        t.pathText = TextOnPath(path: VectorPath(subpaths: [curve]), startOffset: 30,
                                source: TextPathSource(pathID: np.id, subpath: 0, subpathCount: 1, synced: curve))
        let tl = Layer(name: "linked", content: .text(t))
        st.layers.append(tl)
        st.paths = [np]
        let d = Document(state: st, name: "link-persist")
        let url = out.appendingPathComponent("typelink_roundtrip.imagecrat")
        do {
            try DocumentIO.saveNative(d, to: url)
            let back = try DocumentIO.load(url: url)
            let bt = back.state.layer(tl.id)?.text?.pathText
            check(bt == t.pathText && bt?.source?.pathID == np.id, ".imagecrat keeps the link", "\(String(describing: bt?.source))")
            check(QAMeasure.fingerprint(back.state) == QAMeasure.fingerprint(d.state), ".imagecrat round trip is identical")
            // the loaded document still follows its source
            back.state.paths[0].path.subpaths[0].points[1].anchor = CGPoint(x: 380, y: 150)
            back.commit("Edit Path")
            check(same(back.state.layer(tl.id)?.text?.pathText?.path, back.state.paths[0].path.subpaths[0]), "after loading, editing the source re-flows the text")
        } catch { check(false, ".imagecrat round trip", "\(error)") }
        // an old document: type on a path without the link field
        do {
            let data = try JSONEncoder().encode(t)
            var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var ptObj = obj["pathText"] as! [String: Any]
            check(ptObj["source"] != nil, "the link is written with the type")
            ptObj.removeValue(forKey: "source")
            obj["pathText"] = ptObj
            let old = try JSONDecoder().decode(TextContent.self, from: try JSONSerialization.data(withJSONObject: obj))
            check(old.pathText?.path == t.pathText?.path && old.pathText?.startOffset == 30 && old.pathText?.source == nil, "an old document (no link field) loads: unlinked type on a path")
            // a broken link field doesn't stop the document from loading
            ptObj["source"] = ["subpath": "x"]
            obj["pathText"] = ptObj
            let bad = try JSONDecoder().decode(TextContent.self, from: try JSONSerialization.data(withJSONObject: obj))
            check(bad.pathText?.path == t.pathText?.path && bad.pathText?.source == nil, "an unreadable link field is dropped, the type loads")
            // a whole old document: no layer gets linked by loading
            var ost = SelfTest.baseState(200, 100)
            var ot = t; ot.pathText?.source = nil
            ost.layers.append(Layer(name: "old", content: .text(ot)))
            ost.paths = [np]
            let od = Document(state: ost, name: "old")
            let ourl = out.appendingPathComponent("typelink_old.imagecrat")
            try DocumentIO.saveNative(od, to: ourl)
            let ob = try DocumentIO.load(url: ourl)
            ob.state.paths[0].path.subpaths[0].points[1].anchor = CGPoint(x: 100, y: 20)
            ob.commit("Edit Path")
            check(ob.state.allLayers.compactMap(\.text).first?.pathText?.path == ot.pathText?.path, "unlinked type ignores path edits")
        } catch { check(false, "old document decode", "\(error)") }
        // PSD export / import still works with a linked type layer
        let psd = out.appendingPathComponent("typelink_export.psd")
        do {
            try PSDWriter.write(d.state, to: psd)
            let res = try PSDImporter.read(data: try Data(contentsOf: psd), name: "typelink_export.psd", baseURL: out)
            check(res.state.allLayers.contains { $0.name == "linked" } && res.state.paths.contains { $0.name == "Path 1" }, "PSD export → import keeps the type layer and the path")
        } catch { check(false, "PSD export of linked type", "\(error)") }
    }
}
