import AppKit
import CoreImage
import ImageCratCore

/// Exact per-tool expectations: what one gesture records in the history, what it changes and what it must leave alone.
enum QAToolChecks {
    typealias R = ToolRobot
    static let W = QAFixtures.W, H = QAFixtures.H
    static var fixtures: [String: QAFixture] = [:]

    static func fx(_ name: String) -> QAFixture { fixtures[name]! }

    /// Opens a fixture with a tool selected and runs `body`; afterwards the generic "idle" invariants and exact undo / redo
    /// are checked.
    static func with(_ name: String, _ fxName: String, tool: ToolKind, view: QAView = .identity, selection: PixelBuffer? = nil,
                     checkIdle: Bool = true, _ body: (R, Document, QAFixture) -> Void) {
        QA.scenario(name) {
            QAScenarios.resetToolSettings()
            let r = R()
            let f = fx(fxName)
            var st = f.state
            if let s = selection { st.selection = s }
            let d = r.open(st, name: fxName, view: view)
            f.apply(to: d)
            r.select(.hand); r.select(tool)
            if tool == .hand { r.select(.zoom); r.select(.hand) }
            let start = QASnapshot(d)
            QA.modalLog.removeAll()
            body(r, d, f)
            if checkIdle, r.doc === d {
                r.select(tool == .hand ? .zoom : .hand)
                QAInvariant.idle(r, "after")
                QAInvariant.undoRedo(r, from: start, "after")
            }
            r.closeAll()
        }
    }

    /// Names of the history steps recorded since `start`.
    static func steps(_ d: Document, _ start: QASnapshot) -> [String] {
        guard d.historyIndex >= start.historyIndex, d.history.count > start.historyIndex else { return ["<history rewound>"] }
        return d.history[(start.historyIndex + 1)...].prefix(d.historyIndex - start.historyIndex).map(\.name)
    }

    static func expectSteps(_ d: Document, _ start: QASnapshot, _ names: [String], _ what: String) {
        let got = steps(d, start)
        QA.check(got == names, "\(what): history records exactly \(names)", "got \(got)")
    }

    static func bounds(_ d: Document, _ id: UUID?) -> CGRect? {
        guard let l = d.state.layer(id) else { return nil }
        return Compositor.shared.contentBounds(l, state: d.state)
    }

    static func near(_ a: CGRect?, _ b: CGRect?, _ tol: CGFloat = 1.5) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol && abs(a.maxX - b.maxX) <= tol && abs(a.maxY - b.maxY) <= tol
    }

    static func selBounds(_ d: Document) -> CGRect? { d.state.selection?.opaqueBounds(threshold: 127)?.cgRect }

    static func pixel(_ d: Document, _ id: UUID, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        guard let r = d.state.layer(id)?.raster else { return (0, 0, 0, 0) }
        return r.buffer.pixel(x - r.origin.x, y - r.origin.y)
    }

    static func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x + 0.37, y: y + 0.41) }

    static func run() {
        for f in QAFixtures.all(QA.out) { fixtures[f.name] = f }
        moveTool()
        selectionTools()
        cropTools()
        paintTools()
        retouchTools()
        fillTools()
        vectorTools()
        textTools()
        shapeTools()
        viewTools()
        extraTools()
        canvasInput()
        everyTool()
    }

    // MARK: Every tool: no document, context menu, view changes in the middle of its work

    static func everyTool() {
        QA.scenario("tool/all/no-document") {
            QAScenarios.resetToolSettings()
            let r = R()
            // a canvas that never had a document, then one whose document was closed
            for round in 0..<2 {
                if round == 1 { r.open(QAFixtures.base(), name: "gone"); r.closeAll() }
                for k in ToolKind.allCases {
                    r.select(k)
                    let p = CGPoint(x: 300, y: 200)
                    r.canvas.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: 0, windowNumber: r.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
                    r.downView(p); r.dragView(CGPoint(x: 340, y: 230)); r.upView(CGPoint(x: 340, y: 230))
                    r.key(R.kReturn, "\r"); r.key(R.kEsc, "\u{1b}"); r.key(R.kDelete, "\u{7f}"); r.key(R.kLeft, "")
                    r.setMods([.shift]); r.setMods([])
                    r.canvas.currentTool.commit(); r.canvas.currentTool.cancel()
                    r.drawOverlay()
                    QA.check(!r.canvas.currentTool.isBusy, "\(k.rawValue): idle without a document")
                }
            }
            r.select(.hand)
        }
        for name in ["raster", "text", "shape", "no-layer"] {
            with("tool/all/context-menu+view-change/\(name)", name, tool: .hand) { r, d, f in
                let s = QASnapshot(d)
                for k in ToolKind.allCases where k != .objectSelect {
                    r.select(k)
                    _ = r.rightDown(P(100, 70))
                    // the view changes while the tool is in the middle of something (scroll-wheel zoom, pan, rotate view)
                    r.down(P(90, 60)); r.drag(P(110, 75))
                    r.canvas.setZoom(d.zoom * 1.7, anchorView: CGPoint(x: 200, y: 150)); r.canvas.pan(by: CGPoint(x: -33, y: 21)); r.canvas.setRotation(0.4)
                    r.drawOverlay()
                    r.drag(P(130, 90)); r.up(P(130, 90))
                    QAScenarios.typeIfEditing(r)
                    r.drawOverlay()
                    r.key(R.kReturn, "\r"); r.key(R.kEsc, "\u{1b}")
                    r.setView(.identity)
                }
                r.select(.hand)
                _ = s
            }
        }
    }

    // MARK: Move

    static func moveTool() {
        for v in QAView.all {
            for kind in ["raster", "text", "shape", "smart", "linked", "group", "effects", "vector-mask", "offset", "clipped"] {
                with("tool/move/drag/\(kind)/\(v.name)", kind, tool: .move, view: v) { r, d, f in
                    AppModel.shared.moveShowTransform = false      // plain drags: no handles to hit by accident
                    let s = QASnapshot(d)
                    let b0 = bounds(d, f.active)
                    let others = d.state.allLayers.filter { $0.id != f.active && !(d.state.layer(f.active)?.allIDs.contains($0.id) ?? false) }.map { ($0.id, QAMeasure.layerPrint($0)) }
                    r.click(P(100, 70))
                    expectSteps(d, s, [], "click without drag")
                    r.dragLine(P(100, 70), P(123, 58), steps: 5)
                    expectSteps(d, s, ["Move"], "drag")
                    QA.check(near(bounds(d, f.active), b0?.offsetBy(dx: 23, dy: -12)), "drag moves the layer by exactly the drag distance",
                             "\(QAMeasure.describe(b0)) → \(QAMeasure.describe(bounds(d, f.active)))")
                    for (id, p) in others { if let l = d.state.layer(id) { QA.check(QAMeasure.layerPrint(l) == p, "drag leaves the other layers alone (\(l.name))") } }
                    if let a = f.active { QAInvariant.handlesMatchContent(d, a, "after move") }
                    // 1-px drag is a move of one pixel, a sub-pixel drag nothing
                    r.dragLine(P(110, 70), P(111, 70), steps: 1)
                    expectSteps(d, s, ["Move", "Move"], "1-px drag")
                    r.dragLine(P(110, 70), CGPoint(x: 110.6, y: 70.5), steps: 1)
                    expectSteps(d, s, ["Move", "Move"], "sub-pixel drag")
                    // arrow keys nudge
                    let b1 = bounds(d, f.active)
                    r.key(R.kRight); r.mods = [.shift]; r.key(R.kDown); r.mods = []
                    expectSteps(d, s, ["Move", "Move", "Nudge", "Nudge"], "arrow keys")
                    QA.check(near(bounds(d, f.active), b1?.offsetBy(dx: 1, dy: 10)), "arrow keys nudge by 1 px / 10 px with Shift")
                }
            }
        }
        with("tool/move/auto-select", "multi", tool: .move) { r, d, f in
            AppModel.shared.moveShowTransform = false
            AppModel.shared.moveAutoSelect = true
            let a = d.state.allLayers.first { $0.name == "A" }!, shape = d.state.allLayers.first { $0.name == "Shape" }!
            let b0 = bounds(d, a.id), s0 = bounds(d, shape.id)
            r.dragLine(P(50, 50), P(70, 60), steps: 3)                 // on layer A (the shape is the active layer)
            QA.check(d.activeLayerID == a.id && near(bounds(d, a.id), b0?.offsetBy(dx: 20, dy: 10)) && near(bounds(d, shape.id), s0), "auto-select picks and moves the layer under the cursor",
                     "active \(d.state.layer(d.activeLayerID)?.name ?? "nil")")
            r.click(CGPoint(x: 5, y: 150))                                // on the background only
            QA.check(d.state.layer(d.activeLayerID)?.name == "Background", "auto-select follows the click")
        }
        with("tool/move/linked-layers", "linked-layers", tool: .move) { r, d, f in
            AppModel.shared.moveShowTransform = false
            let ids = d.state.allLayers.map(\.id)
            let b0 = ids.map { bounds(d, $0) }
            r.dragLine(P(50, 50), P(70, 80), steps: 4)
            let names = d.state.allLayers.map(\.name)
            for (i, id) in ids.enumerated() {
                let linked = d.state.layer(id)?.linkID != nil
                QA.check(near(bounds(d, id), linked ? b0[i]?.offsetBy(dx: 20, dy: 30) : b0[i]), "linked layers move together, others stay (\(names[i]))",
                         "\(QAMeasure.describe(b0[i])) → \(QAMeasure.describe(bounds(d, id)))")
            }
        }
        for (name, linked) in [("mask-content", true), ("mask-unlinked", false)] {
            with("tool/move/\(name)", name, tool: .move) { r, d, f in
                AppModel.shared.moveShowTransform = false
                let m0 = d.state.layer(f.active)!.mask!
                r.dragLine(P(120, 70), P(135, 95), steps: 4)
                let m1 = d.state.layer(f.active)!.mask!
                QA.check(m1.origin.x - m0.origin.x == (linked ? 15 : 0) && m1.origin.y - m0.origin.y == (linked ? 25 : 0),
                         linked ? "linked mask moves with the content" : "unlinked mask stays in place", "mask origin \(m0.origin) → \(m1.origin)")
            }
        }
        with("tool/move/vector-mask", "vector-mask", tool: .move) { r, d, f in
            AppModel.shared.moveShowTransform = false
            let v0 = d.state.layer(f.active)!.vectorMask!.bounds
            r.dragLine(P(100, 70), P(110, 90), steps: 3)
            QA.check(near(d.state.layer(f.active)!.vectorMask!.bounds, v0.offsetBy(dx: 10, dy: 20)), "vector mask moves with the content")
        }
        for name in ["locked-position", "locked-all", "hidden"] {
            with("tool/move/\(name)", name, tool: .move) { r, d, f in
                let s = QASnapshot(d)
                r.dragLine(P(100, 70), P(130, 90), steps: 4)
                r.key(R.kRight)
                QA.check(QAMeasure.fingerprint(d.state) == s.print, "a \(name) layer is not moved by dragging or nudging")
                expectSteps(d, s, [], name)
            }
        }
        with("tool/move/artboard-child-clipped", "artboard-child", tool: .move) { r, d, f in
            AppModel.shared.moveShowTransform = false
            r.dragLine(P(100, 70), P(60, 40), steps: 4)
            let comp = QAMeasure.composite(d.state), bg = QAMeasure.composite(QAFixtures.base())
            // everything left of the artboard (x < 40) must still be the background
            var n = 0
            for y in 0..<H { for x in 0..<38 where comp.pixel(x, y) != bg.pixel(x, y) { n += 1 } }
            QA.check(n == 0, "a moved artboard child stays clipped to its artboard", "\(n) px outside")
        }
        with("tool/move/selection-float", "raster", tool: .move, selection: QAFixtures.rectSelection(CGRect(x: 80, y: 50, width: 40, height: 30))) { r, d, f in
            let s = QASnapshot(d)
            let before = QAScenarios.rasterOnCanvas(d.state, f.active!)!
            r.dragLine(P(100, 65), P(150, 95), steps: 5)
            expectSteps(d, s, ["Free Transform"], "moving selected pixels")
            QA.check(near(selBounds(d), CGRect(x: 130, y: 80, width: 40, height: 30), 1), "the selection follows the moved pixels", QAMeasure.describe(selBounds(d)))
            let after = QAScenarios.rasterOnCanvas(d.state, f.active!)!
            QA.check(after.alpha(90, 60) == 0 && after.alpha(140, 90) == 255, "selected pixels are cut and moved")
            // pixels outside both the old and new selection rect are untouched
            let keep = SelectionOps.combine(QAFixtures.rectSelection(CGRect(x: 79, y: 49, width: 42, height: 32)), QAFixtures.rectSelection(CGRect(x: 129, y: 79, width: 42, height: 32)), mode: .add)
            let n = QAMeasure.changed(before, after, mask: keep, inside: false, tol: 1)
            QA.check(n == 0, "pixels outside the selection are unchanged", "\(n) px")
        }
        with("tool/move/option-duplicates", "raster", tool: .move) { r, d, f in
            AppModel.shared.moveShowTransform = false
            let s = QASnapshot(d)
            let n0 = d.state.allLayers.count
            r.mods = [.option]; r.dragLine(P(100, 70), P(140, 90), steps: 4); r.mods = []
            expectSteps(d, s, ["Duplicate & Move"], "option-drag")
            QA.check(d.state.allLayers.count == n0 + 1 && near(bounds(d, f.active), QAFixtures.box), "option-drag moves a copy and leaves the original")
        }
        // Transform through the bounding-box handles (the "resize with the handles" path of the reported bug)
        for v in QAView.all {
            for kind in ["raster", "text", "shape", "smart"] {
                with("tool/move/handle-scale/\(kind)/\(v.name)", kind, tool: .move, view: v) { r, d, f in
                    guard let l = d.state.layer(f.active), let q0 = (l.smart?.quad ?? l.text.map { TextRenderer.docQuad($0) } ?? bounds(d, l.id).map { Quad(rect: $0) }) else { return }
                    let s = QASnapshot(d)
                    let mt = r.toolOf(.move, MoveTool.self)!
                    // drag the bottom-right corner handle outwards by 40 %
                    let target = q0.tl + (q0.br - q0.tl) * 1.4
                    r.down(q0.br); r.drag(q0.br.lerp(target, 0.5)); r.drag(target); r.up(target)
                    QA.check(mt.session != nil, "dragging a box handle starts a transform session")
                    r.drawOverlay()
                    QA.check(near(mt.session?.quad.bounds, Quad(tl: q0.tl, tr: q0.tl + (q0.tr - q0.tl) * 1.4, br: target, bl: q0.tl + (q0.bl - q0.tl) * 1.4).bounds, 1.5),
                             "the handle follows the cursor in a \(v.name) view", QAMeasure.describe(mt.session?.quad.bounds))
                    expectSteps(d, s, [], "pending transform")
                    r.key(R.kReturn, "\r")
                    expectSteps(d, s, ["Free Transform"], "Return")
                    QA.check(mt.session == nil, "Return confirms the transform")
                    let l1 = d.state.layer(f.active)!
                    let box = QAMeasure.handleBox(l1, in: d.state)
                    QA.check(abs((box?.width ?? 0) - q0.bounds.width * 1.4) < 3 && abs((box?.height ?? 0) - q0.bounds.height * 1.4) < 3, "the layer is scaled to the dragged size",
                             "\(QAMeasure.describe(q0.bounds)) → \(QAMeasure.describe(box))")
                    QAInvariant.handlesMatchContent(d, l1.id, "after scale")
                    // and Esc discards a second one completely
                    let s2 = QASnapshot(d)
                    if let q1 = (l1.smart?.quad ?? l1.text.map { TextRenderer.docQuad($0) } ?? bounds(d, l1.id).map { Quad(rect: $0) }) {
                        r.down(q1.tl); r.drag(q1.tl + CGPoint(x: -15, y: -11)); r.up(q1.tl + CGPoint(x: -15, y: -11))
                        r.key(R.kEsc, "\u{1b}")
                        expectSteps(d, s2, [], "Esc")
                        QA.check(QAMeasure.fingerprint(d.state) == s2.print && mt.session == nil && d.contentOverrides.isEmpty, "Esc cancels the transform without a trace")
                    }
                }
            }
        }
    }

    // MARK: Selection tools

    static func selectionTools() {
        for v in QAView.all {
            with("tool/marquee/basic/\(v.name)", "raster", tool: .marqueeRect, view: v) { r, d, f in
                let s = QASnapshot(d)
                r.dragLine(CGPoint(x: 40, y: 30), CGPoint(x: 120, y: 90), steps: 4)
                expectSteps(d, s, ["Rectangular Marquee"], "drag")
                QA.check(near(selBounds(d), CGRect(x: 40, y: 30, width: 80, height: 60), 1), "marquee selects the dragged rectangle", QAMeasure.describe(selBounds(d)))
                // drag inside the selection moves it
                r.dragLine(CGPoint(x: 80, y: 60), CGPoint(x: 100, y: 75), steps: 3)
                expectSteps(d, s, ["Rectangular Marquee", "Move Selection"], "drag inside")
                QA.check(near(selBounds(d), CGRect(x: 60, y: 45, width: 80, height: 60), 1), "dragging inside moves the selection", QAMeasure.describe(selBounds(d)))
                // shift adds, option subtracts
                r.mods = [.shift]; r.dragLine(CGPoint(x: 150, y: 100), CGPoint(x: 200, y: 140), steps: 3); r.mods = []
                QA.check(near(selBounds(d), CGRect(x: 60, y: 45, width: 140, height: 95), 1), "Shift adds to the selection", QAMeasure.describe(selBounds(d)))
                r.mods = [.option]; r.dragLine(CGPoint(x: 140, y: 90), CGPoint(x: 230, y: 150), steps: 3); r.mods = []
                QA.check(near(selBounds(d), CGRect(x: 60, y: 45, width: 80, height: 60), 1), "Option subtracts from the selection", QAMeasure.describe(selBounds(d)))
                // click outside deselects
                r.click(CGPoint(x: 20, y: 140))
                QA.check(d.state.selection == nil && steps(d, s).last == "Deselect", "click outside deselects", "\(steps(d, s))")
            }
        }
        with("tool/marquee/modifiers-mid-drag", "raster", tool: .marqueeRect) { r, d, f in
            r.down(CGPoint(x: 100, y: 80)); r.drag(CGPoint(x: 140, y: 100)); r.setMods([.shift]); r.drag(CGPoint(x: 150, y: 100)); r.up(CGPoint(x: 150, y: 100)); r.setMods([])
            QA.check(near(selBounds(d), CGRect(x: 100, y: 80, width: 50, height: 50), 1), "Shift pressed during the drag makes a square", QAMeasure.describe(selBounds(d)))
            AppActions.deselect()
            r.down(CGPoint(x: 100, y: 80)); r.drag(CGPoint(x: 120, y: 90)); r.setMods([.option]); r.drag(CGPoint(x: 130, y: 100)); r.up(CGPoint(x: 130, y: 100)); r.setMods([])
            QA.check(near(selBounds(d), CGRect(x: 70, y: 60, width: 60, height: 40), 1), "Option pressed during the drag draws from the centre", QAMeasure.describe(selBounds(d)))
        }
        with("tool/marquee/click-inside", "raster", tool: .marqueeRect, selection: QAFixtures.rectSelection(CGRect(x: 60, y: 40, width: 80, height: 60))) { r, d, f in
            let s = QASnapshot(d)
            r.click(CGPoint(x: 90, y: 70))
            let st = steps(d, s)
            QA.check(st.isEmpty || st == ["Deselect"], "a click inside the selection records no empty 'Move Selection' step", "\(st)")
        }
        with("tool/marquee/outside-canvas", "raster", tool: .marqueeRect) { r, d, f in
            let s = QASnapshot(d)
            r.dragLine(CGPoint(x: -60, y: -50), CGPoint(x: -10, y: -8), steps: 3)
            QA.check(d.state.selection == nil, "a marquee completely outside the canvas selects nothing")
            expectSteps(d, s, [], "outside drag")
            r.dragLine(CGPoint(x: -30, y: -20), CGPoint(x: 50, y: 40), steps: 3)
            QA.check(near(selBounds(d), CGRect(x: 0, y: 0, width: 50, height: 40), 1), "a marquee from outside is clipped to the canvas", QAMeasure.describe(selBounds(d)))
        }
        with("tool/marquee/ellipse-row-column", "raster", tool: .marqueeEllipse) { r, d, f in
            let s = QASnapshot(d)
            r.dragLine(CGPoint(x: 40, y: 30), CGPoint(x: 120, y: 90), steps: 4)
            expectSteps(d, s, ["Elliptical Marquee"], "ellipse")
            QA.check(d.state.selection!.alpha(80, 60) > 250 && d.state.selection!.alpha(42, 32) == 0, "ellipse selects an ellipse")
            AppActions.deselect()
            r.select(.marqueeRow); r.click(CGPoint(x: 70, y: 55.5))
            QA.check(near(selBounds(d), CGRect(x: 0, y: 55, width: CGFloat(W), height: 1), 0.1), "single row selects one row", QAMeasure.describe(selBounds(d)))
            AppActions.deselect()
            r.select(.marqueeColumn); r.click(CGPoint(x: 70.5, y: 55))
            QA.check(near(selBounds(d), CGRect(x: 70, y: 0, width: 1, height: CGFloat(H)), 0.1), "single column selects one column", QAMeasure.describe(selBounds(d)))
        }
        for v in QAView.all {
            with("tool/lasso/\(v.name)", "raster", tool: .lasso, view: v) { r, d, f in
                let s = QASnapshot(d)
                r.click(CGPoint(x: 100, y: 80))
                expectSteps(d, s, [], "click")
                r.dragPath([CGPoint(x: 40, y: 30), CGPoint(x: 140, y: 30), CGPoint(x: 140, y: 110), CGPoint(x: 40, y: 110), CGPoint(x: 40, y: 32)])
                expectSteps(d, s, ["Lasso"], "lasso")
                QA.check(near(selBounds(d), CGRect(x: 40, y: 30, width: 100, height: 80), 2), "lasso selects the drawn outline", QAMeasure.describe(selBounds(d)))
            }
            with("tool/polygonLasso/\(v.name)", "raster", tool: .polygonLasso, view: v) { r, d, f in
                let s = QASnapshot(d)
                let tool = r.tool
                r.click(CGPoint(x: 40, y: 30)); r.move(CGPoint(x: 90, y: 31)); r.click(CGPoint(x: 140, y: 30)); r.click(CGPoint(x: 140, y: 110))
                r.drawOverlay()
                expectSteps(d, s, [], "pending polygon")
                r.click(CGPoint(x: 40, y: 110)); r.click(CGPoint(x: 40, y: 110), clicks: 2)
                expectSteps(d, s, ["Polygonal Lasso"], "double-click")
                QA.check(near(selBounds(d), CGRect(x: 40, y: 30, width: 100, height: 80), 2), "polygonal lasso selects the polygon", QAMeasure.describe(selBounds(d)))
                // Esc cancels, Return closes, Delete removes the last point
                r.click(CGPoint(x: 10, y: 10)); r.click(CGPoint(x: 60, y: 10)); r.key(R.kEsc, "\u{1b}")
                expectSteps(d, s, ["Polygonal Lasso"], "Esc")
                r.mods = [.shift]
                r.click(CGPoint(x: 150, y: 120)); r.mods = []; r.click(CGPoint(x: 220, y: 120)); r.click(CGPoint(x: 220, y: 150)); r.click(CGPoint(x: 100, y: 100))
                r.key(R.kDelete, "\u{7f}"); r.click(CGPoint(x: 150, y: 150)); r.key(R.kReturn, "\r")
                expectSteps(d, s, ["Polygonal Lasso", "Polygonal Lasso"], "Return")
                QA.check(near(selBounds(d), CGRect(x: 40, y: 30, width: 180, height: 120), 2), "Shift-start adds; Delete drops the last point; Return closes", QAMeasure.describe(selBounds(d)))
                // leaving the tool with an unfinished outline drops it
                r.click(CGPoint(x: 10, y: 10)); r.click(CGPoint(x: 60, y: 10))
                r.select(.hand); r.select(.polygonLasso)
                let before = d.historyIndex
                r.key(R.kReturn, "\r")
                r.click(CGPoint(x: 200, y: 20)); r.click(CGPoint(x: 230, y: 20)); r.click(CGPoint(x: 230, y: 50)); r.key(R.kReturn, "\r")
                QA.check(d.historyIndex == before + 1 && (selBounds(d)?.minX ?? 0) >= 199, "an unfinished outline does not survive a tool switch", QAMeasure.describe(selBounds(d)))
                _ = tool
            }
        }
        with("tool/polygonLasso/shift-constrains", "raster", tool: .polygonLasso) { r, d, f in
            r.click(CGPoint(x: 40, y: 40))
            r.mods = [.shift]; r.move(CGPoint(x: 140, y: 47)); r.click(CGPoint(x: 140, y: 47)); r.mods = []
            r.click(CGPoint(x: 140, y: 100)); r.key(R.kReturn, "\r")
            // the second point was constrained to the horizontal: the top edge is flat at y = 40
            let sel = d.state.selection
            QA.check((sel?.alpha(130, 42) ?? 0) > 200, "Shift constrains polygon segments to 45° steps (the clicked point, not just the preview)",
                     "alpha at (130,42) = \(sel?.alpha(130, 42) ?? 0)")
        }
        with("tool/magneticLasso", "raster", tool: .magneticLasso) { r, d, f in
            let s = QASnapshot(d)
            let b = QAFixtures.box
            r.click(CGPoint(x: b.minX, y: b.minY))
            for p in [CGPoint(x: b.midX, y: b.minY), CGPoint(x: b.maxX, y: b.minY)] { r.move(p) }
            r.click(CGPoint(x: b.maxX, y: b.minY)); r.move(CGPoint(x: b.maxX, y: b.midY)); r.click(CGPoint(x: b.maxX, y: b.maxY))
            r.move(CGPoint(x: b.midX, y: b.maxY)); r.click(CGPoint(x: b.minX, y: b.maxY)); r.drawOverlay()
            expectSteps(d, s, [], "pending")
            r.click(CGPoint(x: b.minX, y: b.minY))
            expectSteps(d, s, ["Magnetic Lasso"], "closing click")
            QA.check(near(selBounds(d), b, 4), "magnetic lasso follows the block's edges", QAMeasure.describe(selBounds(d)))
            // one anchor, then leave the tool: nothing may be left behind
            r.click(CGPoint(x: 20, y: 20)); r.select(.hand); r.select(.magneticLasso)
            let h = d.historyIndex
            r.move(CGPoint(x: 100, y: 100)); r.key(R.kReturn, "\r")
            QA.check(d.historyIndex == h, "a single anchor does not survive a tool switch")
        }
        with("tool/magicWand", "raster", tool: .magicWand) { r, d, f in
            let s = QASnapshot(d)
            r.click(CGPoint(x: 70, y: 100))
            expectSteps(d, s, ["Magic Wand"], "click")
            QA.check(selBounds(d).map { QAFixtures.box.insetBy(dx: -1, dy: -1).contains($0) } ?? false, "magic wand selects inside the block", QAMeasure.describe(selBounds(d)))
            r.click(CGPoint(x: -20, y: 40)); r.click(CGPoint(x: 500, y: 40))
            expectSteps(d, s, ["Magic Wand"], "clicks outside the canvas")
        }
        for v in [QAView.identity, QAView.rotated] {
            with("tool/quickSelect/\(v.name)", "raster", tool: .quickSelect, view: v) { r, d, f in
                let s = QASnapshot(d)
                r.dragLine(CGPoint(x: 70, y: 60), CGPoint(x: 100, y: 95), steps: 4)
                expectSteps(d, s, ["Quick Selection"], "drag")
                QA.check(d.state.selection != nil, "quick selection selects something")
                r.dragLine(CGPoint(x: -40, y: -30), CGPoint(x: 20, y: 20), steps: 4)
                r.dragLine(CGPoint(x: 230, y: 150), CGPoint(x: 300, y: 220), steps: 4)
                expectSteps(d, s, ["Quick Selection", "Quick Selection", "Quick Selection"], "drags from / to outside")
            }
        }
        with("tool/objectSelect", "raster", tool: .objectSelect) { r, d, f in
            let s = QASnapshot(d)
            r.dragLine(CGPoint(x: 50, y: 30), CGPoint(x: 170, y: 120), steps: 4)
            QAScenarios.settle(r, .objectSelect)
            let st = steps(d, s)
            QA.check(st.isEmpty || st == ["Object Selection"], "object selection records at most one step", "\(st)")
            r.down(CGPoint(x: 50, y: 30)); r.drag(CGPoint(x: 120, y: 80)); r.key(R.kEsc, "\u{1b}"); r.up(CGPoint(x: 120, y: 80))
            QAScenarios.settle(r, .objectSelect)
            QA.check(steps(d, s) == st, "Esc during an object-selection drag cancels it", "\(steps(d, s))")
        }
        with("tool/selectionBrush", "raster", tool: .selectionBrush) { r, d, f in
            let s = QASnapshot(d)
            r.dragLine(CGPoint(x: 60, y: 60), CGPoint(x: 120, y: 60), steps: 4)
            expectSteps(d, s, ["Selection Brush"], "stroke")
            let b = selBounds(d)
            QA.check(b != nil && b!.minX < 60 && b!.maxX > 120, "selection brush paints the selection", QAMeasure.describe(b))
            r.mods = [.option]; r.dragLine(CGPoint(x: 40, y: 60), CGPoint(x: 140, y: 60), steps: 4); r.mods = []
            QA.check(d.state.selection == nil || (d.state.selection?.alpha(90, 60) ?? 0) < 30, "Option erases the selection")
            // Esc in the middle of a stroke must not leave a half-painted, uncommitted selection
            r.down(CGPoint(x: 60, y: 100)); r.drag(CGPoint(x: 90, y: 100)); r.select(.hand); r.up(CGPoint(x: 90, y: 100))
        }
    }

    // MARK: Crop

    static func cropTools() {
        for v in QAView.all {
            with("tool/crop/drag-return/\(v.name)", "raster", tool: .crop, view: v) { r, d, f in
                let s = QASnapshot(d)
                r.drawOverlay()
                // draw a new crop box from outside the current one is not possible (it covers the canvas): drag the corners
                r.down(CGPoint(x: 0, y: 0)); r.drag(CGPoint(x: 20, y: 15)); r.drag(CGPoint(x: 40, y: 30)); r.up(CGPoint(x: 40, y: 30))
                r.down(CGPoint(x: 240, y: 160)); r.drag(CGPoint(x: 200, y: 140)); r.up(CGPoint(x: 200, y: 140))
                r.drawOverlay()
                expectSteps(d, s, [], "pending crop")
                r.key(R.kReturn, "\r")
                expectSteps(d, s, ["Crop"], "Return")
                QA.check(d.state.width == 160 && d.state.height == 110, "crop applies the dragged box in a \(v.name) view", "\(d.state.width)×\(d.state.height)")
                let cw = d.state.width
                // Undo must work while the Crop tool is still active
                AppActions.undo()
                QA.check(d.state.width == W && d.state.height == H, "Undo right after a crop undoes it (Crop tool still active)", "\(d.state.width)×\(d.state.height), index \(d.historyIndex)")
                AppActions.redo()
                QA.check(d.state.width == cw, "Redo re-applies the crop")
                // Esc resets a modified box
                r.down(CGPoint(x: 0, y: 0)); r.drag(CGPoint(x: 30, y: 30)); r.up(CGPoint(x: 30, y: 30)); r.key(R.kEsc, "\u{1b}"); r.key(R.kReturn, "\r")
                expectSteps(d, s, ["Crop"], "Esc then Return")
            }
        }
        with("tool/crop/double-click-and-move", "raster", tool: .crop) { r, d, f in
            let s = QASnapshot(d)
            r.down(CGPoint(x: 240, y: 160)); r.drag(CGPoint(x: 140, y: 100)); r.up(CGPoint(x: 140, y: 100))
            r.dragLine(CGPoint(x: 70, y: 50), CGPoint(x: 120, y: 80), steps: 3)           // move the box
            r.doubleClick(CGPoint(x: 150, y: 90))
            expectSteps(d, s, ["Crop"], "double-click")
            QA.check(d.state.width == 140 && d.state.height == 100, "double-click inside commits the moved box", "\(d.state.width)×\(d.state.height)")
        }
        with("tool/crop/stale-after-resize", "raster", tool: .crop) { r, d, f in
            // the box covers the canvas; another command changes the canvas: Return must not crop back to the old size
            AppActions.canvasSize(width: 300, height: 200, anchorX: 1, anchorY: 1, extension: nil)
            let s = QASnapshot(d)
            r.drawOverlay()
            r.key(R.kReturn, "\r")
            expectSteps(d, s, [], "Return after Canvas Size")
            QA.check(d.state.width == 300 && d.state.height == 200, "the crop box follows a canvas size change instead of cropping back", "\(d.state.width)×\(d.state.height)")
            d.undo()
            r.key(R.kReturn, "\r")
            QA.check(d.state.width == W && d.state.height == H && d.historyIndex == s.historyIndex - 1, "…and an undo of it", "\(d.state.width)×\(d.state.height)")
        }
        with("tool/crop/pending-box-then-image-size", "raster", tool: .crop) { r, d, f in
            // reference: crop, then Image Size
            let ref = Document(state: f.state, name: "ref")
            AppModel.shared.documents.append(ref); AppModel.shared.activeDocumentID = ref.id
            AppActions.crop(to: IRect(x: 0, y: 0, width: 200, height: 130), deletePixels: false)
            AppActions.imageSize(width: 100, height: 65, resolution: 72, scaleStyles: true)
            AppModel.shared.documents.removeAll { $0 === ref }
            AppModel.shared.activeDocumentID = d.id
            // the same with the crop box still unconfirmed when Image Size runs
            r.down(CGPoint(x: 240, y: 160)); r.drag(CGPoint(x: 200, y: 130)); r.up(CGPoint(x: 200, y: 130))
            PendingEdits.willRunMenuCommand(topLevel: "Image")
            AppActions.imageSize(width: 100, height: 65, resolution: 72, scaleStyles: true)
            QA.check(d.state.width == 100 && d.state.height == 65 && QAMeasure.diff(d.state, ref.state) < 0.6, "Image Size with a pending crop box scales the cropped image correctly",
                     "\(d.state.width)×\(d.state.height), diff \(String(format: "%.2f", QAMeasure.diff(d.state, ref.state))) \(d.history.map(\.name))")
        }
        with("tool/crop/straighten", "raster", tool: .crop) { r, d, f in
            let s = QASnapshot(d)
            r.mods = [.command]; r.dragLine(CGPoint(x: 40, y: 80), CGPoint(x: 200, y: 92), steps: 4); r.mods = []
            let st = steps(d, s)
            QA.check(st.count == 1, "straightening is one undo step", "\(st)")
            QA.check(d.state.width < W && d.state.height < H, "straighten rotates and crops", "\(d.state.width)×\(d.state.height)")
        }
        for v in [QAView.identity, QAView.rotated] {
            with("tool/perspectiveCrop/\(v.name)", "raster", tool: .perspectiveCrop, view: v) { r, d, f in
                let s = QASnapshot(d)
                let pc = r.toolOf(.perspectiveCrop, PerspectiveCropTool.self)!
                r.click(CGPoint(x: 50, y: 50))
                QA.check(pc.quad == nil, "a click does not start a perspective crop")
                r.dragLine(CGPoint(x: 40, y: 30), CGPoint(x: 200, y: 130), steps: 4)
                QA.check(pc.quad != nil, "dragging draws the crop quad")
                r.down(CGPoint(x: 200, y: 30)); r.drag(CGPoint(x: 180, y: 45)); r.up(CGPoint(x: 180, y: 45))
                r.drawOverlay()
                QA.check(pc.quad.map { $0.tr.distance(to: CGPoint(x: 180, y: 45)) < 0.01 } ?? false, "a corner follows the cursor", "\(String(describing: pc.quad?.tr))")
                expectSteps(d, s, [], "pending")
                r.key(R.kReturn, "\r")
                let st = steps(d, s)
                QA.check(st.count == 1, "perspective crop is one undo step", "\(st)")
                QA.check(d.state.width != W && pc.quad == nil, "Return applies the perspective crop", "\(d.state.width)×\(d.state.height)")
                // Esc cancels, tool switch cancels
                r.dragLine(CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 60), steps: 3); r.key(R.kEsc, "\u{1b}")
                QA.check(pc.quad == nil, "Esc cancels the quad")
                r.dragLine(CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 60), steps: 3); r.select(.hand); r.select(.perspectiveCrop)
                QA.check(pc.quad == nil && steps(d, s) == st, "switching tools cancels the quad")
            }
        }
    }

    // MARK: Painting

    static let strokeTools: [(ToolKind, String)] = [
        (.brush, "Brush"), (.pencil, "Pencil"), (.eraser, "Eraser"), (.mixerBrush, "Mixer Brush"), (.colorReplacement, "Color Replacement"),
        (.patternStamp, "Pattern Stamp"), (.backgroundEraser, "Background Eraser"), (.blur, "Blur"), (.sharpen, "Sharpen"), (.smudge, "Smudge"),
        (.dodge, "Dodge"), (.burn, "Burn"), (.sponge, "Sponge"), (.spotHealing, "Spot Healing Brush"), (.removeTool, "Remove")]

    static func paintTools() {
        for (k, stepName) in strokeTools {
            for v in (k == .brush || k == .eraser ? QAView.all : [QAView.identity]) {
                with("tool/\(k.rawValue)/stroke/\(v.name)", "raster", tool: k, view: v) { r, d, f in
                    let s = QASnapshot(d)
                    let before = QAScenarios.rasterOnCanvas(d.state, f.active!)!
                    r.dragLine(P(80, 60), P(130, 90), steps: 5) { i in if i == 2 { r.drawOverlay() } }
                    expectSteps(d, s, [stepName], "one stroke")
                    let after = QAScenarios.rasterOnCanvas(d.state, f.active!)!
                    // changes stay near the stroke
                    let area = SelectionOps.mask(fromPath: CGPath(rect: CGRect(x: 80, y: 60, width: 50, height: 30).insetBy(dx: -40, dy: -40), transform: nil), width: W, height: H, antialias: false)
                    let far = QAMeasure.changed(before, after, mask: area, inside: false, tol: 2)
                    QA.check(far == 0, "\(stepName): pixels away from the stroke are untouched", "\(far) px")
                    if ![.sharpen, .sponge, .dodge, .burn, .colorReplacement].contains(k) || true {
                        let n = QAMeasure.changed(before, after, mask: nil, inside: false, tol: 0)
                        QA.check(n > 0, "\(stepName): the stroke changes pixels", "0 px")
                    }
                    // a click is a single dab and a single step
                    r.click(P(140, 50))
                    expectSteps(d, s, [stepName, stepName], "click")
                }
            }
            // target checks: refused on locked / hidden layers, rasterize offered for text, mask painting
            for name in ["locked-all", "locked-pixels", "hidden"] {
                with("tool/\(k.rawValue)/refuses/\(name)", name, tool: k) { r, d, f in
                    let s = QASnapshot(d)
                    r.dragLine(P(80, 60), P(130, 90), steps: 4)
                    expectSteps(d, s, [], "\(name) layer")
                    QA.check(QAMeasure.fingerprint(d.state) == s.print, "\(stepName) does not touch a \(name) layer")
                }
            }
            with("tool/\(k.rawValue)/text-layer", "text", tool: k) { r, d, f in
                let s = QASnapshot(d)
                QA.modalAnswer = false
                r.dragLine(P(80, 60), P(130, 90), steps: 4)
                QA.check(QA.modalLog.count == 1, "\(stepName) on a type layer offers to rasterize (once)", "\(QA.modalLog)")
                QA.check(QAMeasure.fingerprint(d.state) == s.print && d.historyIndex == s.historyIndex, "declining leaves the type layer alone")
            }
            with("tool/\(k.rawValue)/selection", "raster", tool: k, selection: QAFixtures.rectSelection(CGRect(x: 90, y: 55, width: 30, height: 40))) { r, d, f in
                let before = QAScenarios.rasterOnCanvas(d.state, f.active!)!
                r.dragLine(P(70, 60), P(140, 90), steps: 5)
                let after = QAScenarios.rasterOnCanvas(d.state, f.active!)!
                let sel = QAFixtures.rectSelection(CGRect(x: 90, y: 55, width: 30, height: 40))
                // the Remove / Spot Healing fill blends over a 1–2 px feather at the hole edge
                let grow = [.removeTool, .spotHealing].contains(k) ? SelectionOps.expand(sel, by: 4) : sel
                let n = QAMeasure.changed(before, after, mask: grow, inside: false, tol: 2)
                QA.check(n == 0, "\(stepName): pixels outside the selection are unchanged", "\(n) px")
            }
            with("tool/\(k.rawValue)/alpha-lock", "locked-transparency", tool: k) { r, d, f in
                let a0 = QAScenarios.alphaMap(d.state, f.active!)!
                r.dragLine(P(40, 50), P(150, 95), steps: 6)
                let n = QAMeasure.changed(a0, QAScenarios.alphaMap(d.state, f.active!)!, mask: nil, inside: false, tol: 1)
                // Photoshop: the Background Eraser overrides the transparency lock
                if k != .backgroundEraser { QA.check(n == 0, "\(stepName) keeps the alpha of a transparency-locked layer", "\(n) px changed") }
            }
        }
        for fxn in ["text", "shape", "smart", "fill"] {
            with("tool/brush/rasterize-accepted/\(fxn)", fxn, tool: .brush) { r, d, f in
                let s = QASnapshot(d)
                QA.modalAnswer = true
                defer { QA.modalAnswer = false }
                r.dragLine(P(80, 60), P(130, 90), steps: 4)
                expectSteps(d, s, ["Rasterize Layer"], "accepting the offer")
                QA.check(d.state.layer(f.active)?.isRaster == true && QA.modalLog.count == 1, "the layer is rasterized after confirming (asked once)", "\(QA.modalLog)")
                QA.check(QAMeasure.diff(QAMeasure.composite(d.state), QAMeasure.composite(s.state)) < 0.8, "rasterizing keeps the layer's appearance",
                         String(format: "diff %.2f", QAMeasure.diff(QAMeasure.composite(d.state), QAMeasure.composite(s.state))))
                r.dragLine(P(80, 60), P(130, 90), steps: 4)
                expectSteps(d, s, ["Rasterize Layer", "Brush"], "painting afterwards")
            }
        }
        with("tool/brush/mask-target", "mask-target", tool: .brush) { r, d, f in
            let s = QASnapshot(d)
            let content0 = QAMeasure.layerPrint({ var l = d.state.layer(f.active)!; l.mask = nil; return l }())
            AppModel.shared.foreground = .black
            r.dragLine(P(100, 60), P(140, 90), steps: 4)
            expectSteps(d, s, ["Brush"], "mask stroke")
            let l = d.state.layer(f.active)!
            QA.check(l.mask!.buffer.alpha(120 - l.mask!.origin.x, 75 - l.mask!.origin.y) < 60, "painting with the mask targeted paints the mask")
            QA.check(QAMeasure.layerPrint({ var x = l; x.mask = nil; return x }()) == content0, "…and leaves the layer pixels alone")
        }
        for k in [ToolKind.brush, .eraser, .gradient, .paintBucket, .blur, .rectangle] {
            for how in ["locked", "hidden"] {
                with("tool/\(k.rawValue)/mask-of-\(how)-layer", "mask-target", tool: k) { r, d, f in
                    AppModel.shared.shapeTool.mode = .pixels
                    d.updateLayer(f.active!) { if how == "locked" { $0.locks.all = true } else { $0.isVisible = false } }
                    d.commit("setup")
                    d.editTarget = .mask
                    let p0 = QAMeasure.layerPrint(d.state.layer(f.active)!)
                    r.dragLine(P(80, 60), P(130, 90), steps: 4)
                    QA.check(QAMeasure.layerPrint(d.state.layer(f.active)!) == p0, "\(k.rawValue) does not paint the mask of a \(how) layer")
                }
            }
        }
        with("tool/brush/shift-click-line", "raster", tool: .brush) { r, d, f in
            r.click(P(40, 130))
            r.mods = [.shift]; r.click(P(200, 130)); r.mods = []
            QA.check(pixel(d, f.active!, 120, 130).3 > 200, "Shift-click connects to the end of the previous stroke")
        }
        with("tool/brush/option-samples", "raster", tool: .brush) { r, d, f in
            let s = QASnapshot(d)
            r.mods = [.option]; r.click(P(70, 50)); r.mods = []
            expectSteps(d, s, [], "option-click")
            let c = AppModel.shared.foreground
            QA.check(abs(c.r - 0x2E / 255.0) < 0.03 && abs(c.b - 0xAB / 255.0) < 0.03, "Option-click samples the colour under the cursor", "\(c)")
        }
        with("tool/eraser/alpha-lock-paints-background", "locked-transparency", tool: .eraser) { r, d, f in
            AppModel.shared.background = RGBA(r: 0, g: 1, b: 0)
            r.dragLine(P(70, 60), P(100, 60), steps: 3)
            let p = pixel(d, f.active!, 85, 60)
            QA.check(p.3 == 255 && p.1 > 200 && p.0 < 60, "the eraser paints the background colour on a transparency-locked layer", "\(p)")
        }
        with("tool/historyBrush", "raster", tool: .brush) { r, d, f in
            let orig = pixel(d, f.active!, 100, 70)
            r.dragLine(P(80, 70), P(120, 70), steps: 4)
            QA.check(pixel(d, f.active!, 100, 70) != orig, "brush stroke changed the pixel")
            let s = QASnapshot(d)
            r.select(.historyBrush)
            r.dragLine(P(80, 70), P(120, 70), steps: 4)
            expectSteps(d, s, ["History Brush"], "history brush")
            let p = pixel(d, f.active!, 100, 70)
            QA.check(abs(Int(p.0) - Int(orig.0)) < 12 && abs(Int(p.2) - Int(orig.2)) < 12, "the history brush paints the first history state back", "\(p) vs \(orig)")
        }
        with("tool/artHistoryBrush", "raster", tool: .artHistoryBrush) { r, d, f in
            let s = QASnapshot(d)
            r.dragLine(P(80, 60), P(130, 90), steps: 4)
            expectSteps(d, s, ["Art History Brush"], "stroke")
        }
        for k in [ToolKind.cloneStamp, .healing] {
            for v in [QAView.identity, QAView.rotated] {
                with("tool/\(k.rawValue)/\(v.name)", "raster", tool: k, view: v) { r, d, f in
                    let s = QASnapshot(d)
                    r.dragLine(P(30, 40), P(50, 40), steps: 3)
                    expectSteps(d, s, [], "painting without a source")
                    r.mods = [.option]; r.click(P(120, 70)); r.mods = []            // source: the orange block
                    expectSteps(d, s, [], "option-click")
                    r.dragLine(P(75, 100), P(95, 100), steps: 4)                   // onto the blue part
                    expectSteps(d, s, [k == .cloneStamp ? "Clone Stamp" : "Healing Brush"], "stroke")
                    QA.check(d.contentOverrides.isEmpty, "the stroke preview is removed when the stroke ends", "\(d.contentOverrides.count) left")
                    if k == .cloneStamp {
                        let p = pixel(d, f.active!, 85, 100)
                        QA.check(p.0 > 200 && p.2 < 120, "clone stamp copies the source pixels", "\(p)")
                    }
                    // what is shown is what is stored (no stale preview on top)
                    QA.check(QAMeasure.diff(r.liveComposite(), QAMeasure.composite(d.state)) < 0.01, "canvas shows exactly the stored pixels after the stroke")
                }
            }
        }
        with("tool/cloneStamp/then-move-no-ghost", "raster", tool: .cloneStamp) { r, d, f in
            AppModel.shared.clone.opacity = 0.5
            r.mods = [.option]; r.click(P(140, 70)); r.mods = []
            r.dragLine(P(75, 100), P(95, 100), steps: 4)
            AppModel.shared.moveShowTransform = false
            r.select(.move)
            r.dragLine(P(100, 70), P(130, 100), steps: 3)
            QA.check(QAMeasure.diff(r.liveComposite(), QAMeasure.composite(d.state)) < 0.01, "no ghost of the clone stroke stays behind when the layer is moved",
                     String(format: "diff %.3f", QAMeasure.diff(r.liveComposite(), QAMeasure.composite(d.state))))
        }
    }

    // MARK: Retouch (selection-driven)

    static func retouchTools() {
        for k in [ToolKind.patch, .contentAwareMove] {
            with("tool/\(k.rawValue)", "raster", tool: k) { r, d, f in
                let s = QASnapshot(d)
                r.dragPath([P(65, 45), P(100, 45), P(100, 80), P(65, 80), P(65, 47)])
                let name1 = k == .patch ? "Patch Selection" : "Content-Aware Move Selection"
                expectSteps(d, s, [name1], "lasso")
                r.click(P(80, 60))
                expectSteps(d, s, [name1], "click inside the selection")
                r.dragLine(P(80, 60), P(120, 85), steps: 4) { i in if i == 2 { r.drawOverlay() } }
                expectSteps(d, s, [name1, k == .patch ? "Patch" : "Content-Aware Move"], "drag")
                QA.check(d.displayOverride == nil, "the drag preview is removed")
            }
            for name in ["locked-all", "locked-pixels", "hidden"] {
                with("tool/\(k.rawValue)/refuses/\(name)", name, tool: k, selection: QAFixtures.rectSelection(CGRect(x: 65, y: 45, width: 35, height: 35))) { r, d, f in
                    let p0 = QAMeasure.layerPrint(d.state.layer(f.active)!)
                    r.dragLine(P(80, 60), P(120, 85), steps: 4)
                    QA.check(QAMeasure.layerPrint(d.state.layer(f.active)!) == p0, "\(k.rawValue) does not touch a \(name) layer")
                }
            }
        }
        with("tool/redEye", "no-layer", tool: .redEye) { r, d, f in
            d.selectLayer(d.state.layers[0].id)             // the background has a red disc
            let s = QASnapshot(d)
            r.click(P(38, 118))
            expectSteps(d, s, ["Red Eye"], "click on red")
            r.click(P(200, 140))
            expectSteps(d, s, ["Red Eye"], "click where nothing is red")
            QA.check(QAMeasure.fingerprint(d.state) == QAMeasure.fingerprint(d.committedState), "a miss leaves nothing uncommitted")
        }
        with("tool/redEye/mask-target", "mask-target", tool: .redEye) { r, d, f in
            let p0 = QAMeasure.layerPrint(d.state.layer(f.active)!)
            r.click(P(100, 70)); r.dragLine(P(70, 50), P(150, 100), steps: 3)
            QA.check(QAMeasure.layerPrint(d.state.layer(f.active)!) == p0, "red eye with the mask targeted leaves the layer alone (it works on pixels)")
        }
    }

    // MARK: Fills

    static func fillTools() {
        for v in QAView.all {
            with("tool/gradient/\(v.name)", "raster", tool: .gradient, view: v) { r, d, f in
                let s = QASnapshot(d)
                r.click(P(100, 70))
                r.dragLine(P(100, 70), CGPoint(x: 100.9, y: 70.4), steps: 1)
                expectSteps(d, s, [], "click and sub-pixel drag")
                QA.check(d.contentOverrides.isEmpty, "no gradient preview is left after a click")
                r.dragLine(P(60, 80), P(180, 80), steps: 5) { i in if i == 3 { QA.check(!d.contentOverrides.isEmpty, "the gradient previews while dragging"); r.drawOverlay() } }
                expectSteps(d, s, ["Gradient"], "drag")
                let a = pixel(d, f.active!, 62, 80), b = pixel(d, f.active!, 178, 80)
                QA.check(a.3 == 255 && b.3 == 255 && abs(Int(a.0) - Int(b.0)) + abs(Int(a.1) - Int(b.1)) + abs(Int(a.2) - Int(b.2)) > 150, "the gradient runs along the drag", "\(a) … \(b)")
            }
        }
        with("tool/gradient/selection+mask", "mask-target", tool: .gradient, selection: QAFixtures.rectSelection(CGRect(x: 100, y: 50, width: 60, height: 50))) { r, d, f in
            let m0 = d.state.layer(f.active)!.mask!
            let before = PixelBuffer(width: W, height: H, format: .gray); before.copyPixels(from: m0.buffer, at: m0.origin)
            r.dragLine(P(60, 80), P(180, 80), steps: 4)
            let m1 = d.state.layer(f.active)!.mask!
            let after = PixelBuffer(width: W, height: H, format: .gray); after.copyPixels(from: m1.buffer, at: m1.origin)
            let n = QAMeasure.changed(before, after, mask: d.state.selection, inside: false, tol: 2)
            QA.check(n == 0, "a gradient on the mask stays inside the selection", "\(n) px")
            QA.check(QAMeasure.changed(before, after, mask: nil, inside: false, tol: 2) > 0, "a gradient on the mask changes the mask")
        }
        for (k, name) in [(ToolKind.paintBucket, "Paint Bucket"), (.magicEraser, "Magic Eraser")] {
            with("tool/\(k.rawValue)", "raster", tool: k) { r, d, f in
                let s = QASnapshot(d)
                r.click(P(70, 100))
                expectSteps(d, s, [name], "click")
                r.click(CGPoint(x: -10, y: 20)); r.click(CGPoint(x: 100, y: 400))
                expectSteps(d, s, [name], "clicks outside the canvas")
                r.dragLine(P(150, 60), P(90, 100), steps: 3)
                expectSteps(d, s, [name, name], "a drag acts at the press point only")
            }
            for fxn in ["locked-all", "locked-pixels", "hidden"] {
                with("tool/\(k.rawValue)/refuses/\(fxn)", fxn, tool: k) { r, d, f in
                    let s = QASnapshot(d)
                    r.click(P(70, 100))
                    QA.check(QAMeasure.fingerprint(d.state) == s.print && d.historyIndex == s.historyIndex, "\(name) does not touch a \(fxn) layer")
                }
            }
        }
        with("tool/magicEraser/alpha-lock", "locked-transparency", tool: .magicEraser) { r, d, f in
            AppModel.shared.background = RGBA(r: 0, g: 1, b: 0)
            let a0 = QAScenarios.alphaMap(d.state, f.active!)!
            r.click(P(70, 100))
            let n = QAMeasure.changed(a0, QAScenarios.alphaMap(d.state, f.active!)!, mask: nil, inside: false, tol: 1)
            let p = pixel(d, f.active!, 70, 100)
            QA.check(n == 0 && p.1 > 200 && p.0 < 60, "the magic eraser fills with the background colour on a transparency-locked layer", "\(n) alpha px changed, pixel \(p)")
        }
        with("tool/eyedropper", "raster", tool: .eyedropper) { r, d, f in
            let s = QASnapshot(d)
            r.click(P(70, 50))
            let c = AppModel.shared.foreground
            QA.check(abs(c.r - 0x2E / 255.0) < 0.03 && abs(c.g - 0x86 / 255.0) < 0.03, "the eyedropper picks the colour under the cursor", "\(c)")
            r.dragLine(CGPoint(x: -20, y: -20), CGPoint(x: 300, y: 200), steps: 6)
            expectSteps(d, s, [], "eyedropper")
        }
    }

    // MARK: Vector tools

    static func shapePointCount(_ d: Document, _ id: UUID?) -> Int { d.state.layer(id)?.shape?.path.subpaths.reduce(0) { $0 + $1.points.count } ?? -1 }

    static func vectorTools() {
        for v in QAView.all {
            with("tool/pen/shape/\(v.name)", "raster", tool: .pen, view: v) { r, d, f in
                let s = QASnapshot(d)
                let n0 = d.state.allLayers.count
                r.click(P(40, 30)); r.move(P(90, 32)); r.drawOverlay()
                r.down(P(140, 30)); r.drag(P(150, 40)); r.up(P(150, 40))            // smooth point
                r.click(P(140, 110)); r.drawOverlay()
                expectSteps(d, s, ["Add Anchor Point", "Add Anchor Point", "Add Anchor Point"], "three anchors")
                QA.check(d.state.allLayers.count == n0 + 1 && shapePointCount(d, d.activeLayerID) == 3, "the pen builds one shape layer with three anchors",
                         "\(d.state.allLayers.count - n0) new layers, \(shapePointCount(d, d.activeLayerID)) points")
                // undo in the middle of the path, then continue: the path continues from the remaining anchors
                d.undo()
                QA.check(shapePointCount(d, d.activeLayerID) == 2, "undo removes the last anchor")
                r.click(P(100, 120))
                QA.check(d.state.allLayers.count == n0 + 1 && shapePointCount(d, d.activeLayerID) == 3, "the pen continues the same path after an undo",
                         "\(d.state.allLayers.count - n0) new layers, \(shapePointCount(d, d.activeLayerID)) points")
                r.click(P(40, 30))                                                   // close
                QA.check(steps(d, s).last == "Close Path" && d.state.layer(d.activeLayerID)?.shape?.path.subpaths.first?.closed == true, "clicking the first anchor closes the path", "\(steps(d, s))")
                // next click starts a new layer
                r.click(P(200, 140)); r.key(R.kReturn, "\r")
                QA.check(d.state.allLayers.count == n0 + 2, "after closing, the next click starts a new shape")
            }
        }
        with("tool/pen/path-mode", "raster", tool: .pen) { r, d, f in
            AppModel.shared.penMode = .path
            let s = QASnapshot(d)
            r.click(P(40, 30)); r.click(P(140, 30)); r.click(P(140, 110)); r.mods = [.command]; r.click(P(10, 10)); r.mods = []
            expectSteps(d, s, ["Add Anchor Point", "Add Anchor Point", "Add Anchor Point"], "work path")
            QA.check(d.state.paths.count == 1 && d.state.paths[0].path.subpaths.first?.points.count == 3 && d.state.allLayers.count == 2, "path mode draws a work path, no layer")
            // undo everything, then click again: a fresh path, no crash
            d.undo(); d.undo(); d.undo()
            r.click(P(60, 60)); r.click(P(80, 80))
            QA.check(d.state.paths.first?.path.subpaths.first?.points.count == 2, "pen continues cleanly after undoing the whole path", "\(String(describing: d.state.paths.first?.path.subpaths.map { $0.points.count }))")
        }
        for v in [QAView.identity, QAView.half] {
            with("tool/freeformPen/\(v.name)", "raster", tool: .freeformPen, view: v) { r, d, f in
                let s = QASnapshot(d)
                r.click(P(50, 50))
                expectSteps(d, s, [], "click")
                r.dragPath([P(40, 30), P(80, 25), P(140, 40), P(150, 90), P(90, 110), P(45, 80), P(41, 32)])
                expectSteps(d, s, ["Freeform Pen"], "drag")
                QA.check(d.state.layer(d.activeLayerID)?.shape?.path.subpaths.first?.closed == true, "ending near the start closes the freeform path")
            }
        }
        for v in QAView.all {
            with("tool/curvaturePen/\(v.name)", "raster", tool: .curvaturePen, view: v) { r, d, f in
                let s = QASnapshot(d)
                let n0 = d.state.allLayers.count
                let cp = r.toolOf(.curvaturePen, CurvaturePenTool.self)!
                r.click(P(40, 30)); r.click(P(140, 30)); r.click(P(140, 110)); r.move(P(90, 120)); r.drawOverlay()
                expectSteps(d, s, ["Curvature Pen", "Add Anchor Point", "Add Anchor Point"], "three points")
                // undo in the middle (History panel / Cmd-Z): the undone point must not come back with the next click
                d.undo()
                QA.check(shapePointCount(d, d.activeLayerID) == 2, "undo removes the last point")
                r.click(P(60, 120))
                QA.check(shapePointCount(d, d.activeLayerID) == 3, "after an undo the next click adds one point (the undone one stays gone)",
                         "\(shapePointCount(d, d.activeLayerID)) points, tool has \(cp.points.count)")
                let pts = d.state.layer(d.activeLayerID)?.shape?.path.subpaths.first?.points.map(\.anchor) ?? []
                QA.check(pts.count == 3 && pts[2].distance(to: P(60, 120)) < 0.01 && !pts.contains { $0.distance(to: P(140, 110)) < 0.01 }, "…at the clicked position", "\(pts)")
                // drag an anchor: one "Edit Path" step
                let h = d.historyIndex
                r.down(P(140, 30)); r.drag(P(150, 20)); r.up(P(150, 20))
                QA.check(d.historyIndex == h + 1 && d.history[d.historyIndex].name == "Edit Path", "dragging an anchor is one step", "\(d.history.suffix(2).map(\.name))")
                // Esc while dragging an anchor must not leave an uncommitted edit behind
                r.down(P(150, 20)); r.drag(P(160, 40)); r.key(R.kEsc, "\u{1b}"); r.up(P(160, 40))
                QA.check(QAMeasure.fingerprint(d.state) == QAMeasure.fingerprint(d.committedState), "Esc during an anchor drag leaves nothing uncommitted")
                QA.check(d.state.allLayers.count == n0 + 1, "one shape layer")
            }
        }
        with("tool/curvaturePen/undo-to-start", "raster", tool: .curvaturePen) { r, d, f in
            let n0 = d.state.allLayers.count
            r.click(P(40, 30))
            d.undo()                                  // the new shape layer is gone again
            QA.check(d.state.allLayers.count == n0, "undo removes the new shape layer")
            r.click(P(80, 60)); r.click(P(120, 90))
            QA.check(d.state.allLayers.count == n0 + 1 && shapePointCount(d, d.activeLayerID) == 2, "the curvature pen starts a new path when its layer was undone (not stuck)",
                     "\(d.state.allLayers.count - n0) new layers, \(shapePointCount(d, d.activeLayerID)) points")
        }
        for k in [ToolKind.pathSelect, .directSelect] {
            for v in [QAView.identity, QAView.rotated] {
                with("tool/\(k.rawValue)/drag/\(v.name)", "shape", tool: k, view: v) { r, d, f in
                    let s = QASnapshot(d)
                    let b0 = bounds(d, f.active)
                    r.click(P(100, 70))
                    expectSteps(d, s, [], "click")
                    r.dragLine(P(100, 70), P(120, 95), steps: 4); r.drawOverlay()
                    expectSteps(d, s, [k == .pathSelect ? "Move Path" : "Edit Path"], "drag inside the shape")
                    QA.check(near(bounds(d, f.active), b0?.offsetBy(dx: 20, dy: 25), 2), "dragging the shape moves it", "\(QAMeasure.describe(b0)) → \(QAMeasure.describe(bounds(d, f.active)))")
                    if k == .directSelect {
                        // drag one anchor: the top-left corner of the rectangle
                        let tl = CGPoint(x: QAFixtures.box.minX + 20, y: QAFixtures.box.minY + 25)
                        r.down(tl); r.drag(tl + CGPoint(x: -10, y: -10)); r.up(tl + CGPoint(x: -10, y: -10))
                        QA.check(steps(d, s).count == 2 && near(bounds(d, f.active), b0?.offsetBy(dx: 20, dy: 25).union(CGRect(origin: tl + CGPoint(x: -10, y: -10), size: .zero)), 3),
                                 "direct selection drags a single anchor", "\(steps(d, s)) \(QAMeasure.describe(bounds(d, f.active)))")
                    }
                }
            }
        }
        for k in [ToolKind.pathSelect, .directSelect, .addAnchor, .deleteAnchor, .convertPoint] {
            for lock in ["all", "position"] {
                with("tool/\(k.rawValue)/locked-\(lock)", "shape", tool: k) { r, d, f in
                    d.updateLayer(f.active!) { if lock == "all" { $0.locks.all = true } else { $0.locks.position = true } }
                    d.commit("lock")
                    let p0 = QAMeasure.layerPrint(d.state.layer(f.active)!)
                    let b = QAFixtures.box
                    r.dragLine(P(100, 70), P(120, 95), steps: 3)                                         // body
                    r.down(CGPoint(x: b.minX, y: b.minY)); r.drag(CGPoint(x: b.minX - 12, y: b.minY - 9)); r.up(CGPoint(x: b.minX - 12, y: b.minY - 9))   // corner anchor
                    r.click(CGPoint(x: b.midX, y: b.minY))                                                 // segment
                    // a position lock still allows reshaping anchors; a full lock allows nothing
                    if lock == "all" || k == .pathSelect {
                        QA.check(QAMeasure.layerPrint(d.state.layer(f.active)!) == p0, "\(k.rawValue) does not change a \(lock)-locked shape layer")
                    }
                }
            }
        }
        with("tool/directSelect/delete-every-anchor", "shape", tool: .directSelect) { r, d, f in
            let b = QAFixtures.box
            let corners = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
            r.click(corners[0]); r.mods = [.shift]; for c in corners.dropFirst() { r.click(c) }; r.mods = []
            r.key(R.kDelete, "\u{7f}")
            QA.check(shapePointCount(d, f.active) == 0 && d.state.allLayers.count == 2, "Delete removes the selected anchors (not the layer)", "\(shapePointCount(d, f.active)) points, \(d.state.allLayers.count) layers")
            // an empty shape layer must not upset the other tools
            r.drawOverlay()
            r.select(.move); r.move(P(100, 70)); r.drawOverlay(); r.dragLine(P(100, 70), P(120, 80), steps: 2)
            AppActions.freeTransform(); r.key(R.kEsc, "\u{1b}")
            r.select(.pathSelect); r.click(P(100, 70)); r.drawOverlay()
            r.select(.text); r.move(P(100, 70)); r.click(P(100, 70)); r.key(R.kEsc, "\u{1b}")
            QAInvariant.roundTrip(d, "empty shape layer")
        }
        with("tool/anchors", "shape", tool: .addAnchor) { r, d, f in
            let s = QASnapshot(d)
            let b = QAFixtures.box
            let n0 = shapePointCount(d, f.active)
            r.click(CGPoint(x: b.midX, y: b.minY)); r.drawOverlay()
            expectSteps(d, s, ["Add Anchor Point"], "click on a segment")
            QA.check(shapePointCount(d, f.active) == n0 + 1, "add anchor inserts a point")
            r.click(P(10, 10))
            expectSteps(d, s, ["Add Anchor Point"], "click away from the path")
            r.select(.deleteAnchor)
            r.click(CGPoint(x: b.midX, y: b.minY))
            QA.check(shapePointCount(d, f.active) == n0 && steps(d, s).last == "Delete Anchor Point", "delete anchor removes it again", "\(steps(d, s))")
            r.select(.convertPoint)
            r.down(CGPoint(x: b.minX, y: b.minY)); r.drag(CGPoint(x: b.minX + 20, y: b.minY - 10)); r.up(CGPoint(x: b.minX + 20, y: b.minY - 10)); r.drawOverlay()
            QA.check(steps(d, s).last == "Convert Point" && d.state.layer(f.active)!.shape!.path.subpaths[0].points.contains { $0.hasHandles }, "convert point pulls out handles", "\(steps(d, s))")
            r.click(CGPoint(x: b.minX, y: b.minY))
            QA.check(!d.state.layer(f.active)!.shape!.path.subpaths[0].points.contains { $0.hasHandles } && steps(d, s).count == 4, "clicking a smooth point makes it a corner", "\(steps(d, s))")
        }
    }

    // MARK: Text

    static func editing(_ r: R) -> NSTextView? { r.window.firstResponder as? NSTextView }
    static func typedText(_ r: R, _ s: String) { if let tv = editing(r) { tv.insertText(s, replacementRange: tv.selectedRange()) } }

    static func textTools() {
        for v in QAView.all {
            with("tool/text/point/\(v.name)", "raster", tool: .text, view: v) { r, d, f in
                let s = QASnapshot(d)
                let n0 = d.state.allLayers.count
                r.click(P(30, 140))
                QA.check(r.tool.isBusy && editing(r) != nil, "a click opens the on-canvas editor")
                r.drawOverlay()
                expectSteps(d, s, [], "while typing")
                editing(r)?.insertText("Hey", replacementRange: NSRange(location: 0, length: 0))
                r.key(R.kEsc, "\u{1b}")
                expectSteps(d, s, ["Type Layer"], "commit")
                let l = d.state.layer(d.activeLayerID)
                QA.check(d.state.allLayers.count == n0 + 1 && l?.text?.text == "Hey" && l?.name == "Hey" && l?.text?.boxSize == nil, "typing creates a point-type layer named after its text",
                         "\(String(describing: l?.name)) box \(String(describing: l?.text?.boxSize))")
                if let l { QAInvariant.handlesMatchContent(d, l.id, "new type layer") }
                // an empty editor leaves no trace
                let s2 = QASnapshot(d)
                r.click(P(150, 30)); r.key(R.kEsc, "\u{1b}")
                QA.check(QAMeasure.fingerprint(d.state) == s2.print && d.historyIndex == s2.historyIndex, "committing an empty editor leaves no layer and no history step", "\(steps(d, s2)) \(QAMeasure.tree(d.state))")
                // re-edit without changes: nothing recorded, nothing left uncommitted; with changes: one step
                if let l, let q = l.text.map({ TextRenderer.docQuad($0) }) {
                    r.click(q.center); QA.check(r.tool.isBusy, "clicking a type layer edits it")
                    r.key(R.kEsc, "\u{1b}")
                    QA.check(QAMeasure.fingerprint(d.state) == s2.print && d.historyIndex == s2.historyIndex, "re-editing without a change records nothing")
                    r.click(q.center); editing(r)?.insertText("Yo", replacementRange: NSRange(location: 0, length: 3))
                    r.click(P(200, 20))                       // clicking away commits
                    QA.check(steps(d, s2) == ["Edit Type Layer"] && d.state.layer(l.id)?.text?.text == "Yo" && !r.tool.isBusy, "editing text is one step; clicking away commits", "\(steps(d, s2))")
                }
            }
        }
        with("tool/text/cancel-keeps-layer-selection", "multi", tool: .text) { r, d, f in
            // two layers selected, the middle one active: an abandoned click with the Type tool must not select the top layer
            let active = d.activeLayerID, selected = d.selectedLayerIDs
            r.click(P(200, 140)); r.key(R.kEsc, "\u{1b}")
            QA.check(d.activeLayerID == active && d.selectedLayerIDs == selected, "an empty type edit gives the previous layer selection back",
                     "active \(d.state.layer(d.activeLayerID)?.name ?? "nil"), \(d.selectedLayerIDs.count) selected")
            r.click(P(200, 140)); typedText(r, "x"); (r.tool as? TextTool)?.endEditing(commit: false)
            QA.check(d.activeLayerID == active && d.selectedLayerIDs == selected, "a cancelled type edit gives the previous layer selection back")
        }
        with("tool/text/unchanged-default-name", "text", tool: .text) { r, d, f in
            // fixture layer is named "Text": opening and closing the editor must not rename it behind the history's back
            let s = QASnapshot(d)
            let q = TextRenderer.docQuad(d.state.layer(f.active)!.text!)
            r.click(q.center); r.key(R.kEsc, "\u{1b}")
            QA.check(QAMeasure.fingerprint(d.state) == QAMeasure.fingerprint(d.committedState), "closing the editor without changes leaves nothing uncommitted",
                     "name '\(d.state.layer(f.active)?.name ?? "")' vs committed '\(d.committedState.layer(f.active)?.name ?? "")'")
            expectSteps(d, s, [], "no change")
        }
        for (z, name) in [(0.25, "z0.25"), (1.0, "z1"), (8.0, "z8")] {
            with("tool/text/click-jitter/\(name)", "raster", tool: .text, view: QAView(name: name, zoom: z, offset: CGPoint(x: 80, y: 60))) { r, d, f in
                // a click whose mouse-up lands 3 screen pixels away is still a click (point type), at every zoom
                let a = r.canvas.docToView(P(60, 100))
                r.downView(a); r.dragView(CGPoint(x: a.x + 3, y: a.y + 1)); r.upView(CGPoint(x: a.x + 3, y: a.y + 1))
                editing(r)?.insertText("Ab", replacementRange: NSRange(location: 0, length: 0))
                r.key(R.kEsc, "\u{1b}")
                QA.check(d.state.layer(d.activeLayerID)?.text?.boxSize == nil, "a 3-px mouse jitter at \(name) makes point type, not a tiny paragraph box",
                         "box \(String(describing: d.state.layer(d.activeLayerID)?.text?.boxSize))")
                // a real 60-px screen drag is a paragraph box
                let b = r.canvas.docToView(P(20, 20))
                r.downView(b); r.dragView(CGPoint(x: b.x + 60, y: b.y + 40)); r.upView(CGPoint(x: b.x + 60, y: b.y + 40))
                editing(r)?.insertText("Cd", replacementRange: NSRange(location: 0, length: 0))
                r.drawOverlay()
                r.key(R.kEsc, "\u{1b}")
                let box = d.state.layer(d.activeLayerID)?.text?.boxSize
                QA.check(box != nil && abs(box!.width - 60 / z) < 1.5, "a 60-px drag at \(name) makes a paragraph box of that size", "\(String(describing: box))")
            }
        }
        with("tool/text/locked-layer", "text", tool: .text) { r, d, f in
            d.updateLayer(f.active!) { $0.locks.all = true }
            d.commit("lock")
            let s = QASnapshot(d)
            r.click(TextRenderer.docQuad(d.state.layer(f.active)!.text!).center)
            QA.check(!r.tool.isBusy && editing(r) == nil, "a fully locked type layer is not opened for editing")
            typedText(r, "x"); r.key(R.kEsc, "\u{1b}")
            QA.check(QAMeasure.fingerprint(d.state) == s.print && d.historyIndex == s.historyIndex, "…and stays unchanged")
        }
        with("tool/text/vertical", "raster", tool: .verticalText) { r, d, f in
            let s = QASnapshot(d)
            r.click(P(200, 20)); editing(r)?.insertText("Tate", replacementRange: NSRange(location: 0, length: 0)); r.drawOverlay()
            r.key(R.kEsc, "\u{1b}")
            expectSteps(d, s, ["Type Layer"], "vertical type")
            QA.check(d.state.layer(d.activeLayerID)?.text?.orientation == .vertical, "vertical type tool makes vertical type")
        }
        with("tool/text/on-path+area", "shape", tool: .text) { r, d, f in
            let s = QASnapshot(d)
            let b = QAFixtures.box
            r.move(CGPoint(x: b.midX, y: b.minY)); r.click(CGPoint(x: b.midX, y: b.minY))            // on the outline
            editing(r)?.insertText("Along", replacementRange: NSRange(location: 0, length: 0)); r.drawOverlay()
            r.key(R.kEsc, "\u{1b}")
            QA.check(d.state.layer(d.activeLayerID)?.text?.pathText != nil && steps(d, s) == ["Type Layer"], "clicking a shape outline makes type on a path", "\(steps(d, s))")
            d.selectLayer(f.active!)
            r.click(CGPoint(x: b.midX, y: b.midY))                                                   // inside the closed shape
            editing(r)?.insertText("Inside", replacementRange: NSRange(location: 0, length: 0)); r.drawOverlay()
            r.key(R.kEsc, "\u{1b}")
            QA.check(d.state.layer(d.activeLayerID)?.text?.area != nil && steps(d, s) == ["Type Layer", "Type Layer"], "clicking inside a closed shape makes area type", "\(steps(d, s))")
        }
        with("tool/text/box-resize", "raster", tool: .text) { r, d, f in
            r.dragLine(P(20, 20), P(120, 80), steps: 3)
            editing(r)?.insertText("Paragraph text", replacementRange: NSRange(location: 0, length: 0))
            let id = d.activeLayerID!
            r.drawOverlay()
            r.down(P(120, 80)); r.drag(P(150, 100)); r.up(P(150, 100))            // bottom-right box handle
            QA.check(r.tool.isBusy && editing(r) != nil, "dragging a box handle keeps the editor open and focused (typing continues)")
            QA.check(abs((d.state.layer(id)?.text?.boxSize?.width ?? 0) - 130) < 2, "the box handle resizes the paragraph box", "\(String(describing: d.state.layer(id)?.text?.boxSize))")
            r.key(R.kEsc, "\u{1b}")
            QA.check(abs((d.state.layer(id)?.text?.boxSize?.width ?? 0) - 130) < 2 && d.state.layer(id)?.text?.text == "Paragraph text", "commit keeps the resized box and the text",
                     "box \(String(describing: d.state.layer(id)?.text?.boxSize)) text '\(d.state.layer(id)?.text?.text ?? "<no layer>")' \(QAMeasure.tree(d.state)) history \(d.history.map(\.name))")
        }
        with("tool/text/tool-switch-commits", "raster", tool: .text) { r, d, f in
            let s = QASnapshot(d)
            r.click(P(30, 140)); editing(r)?.insertText("Go", replacementRange: NSRange(location: 0, length: 0))
            r.select(.brush)
            expectSteps(d, s, ["Type Layer"], "switching tools")
            QA.check(editing(r) == nil && !AppModel.shared.textEditingActive, "the editor is closed")
        }
        with("tool/text/switch-tool-mid-box-drag", "raster", tool: .text) { r, d, f in
            r.down(P(20, 20)); r.drag(P(80, 60))
            r.key(0, "b")                              // a tool shortcut while the mouse is down
            r.drag(P(120, 90)); r.up(P(120, 90))
            QA.check(!(r.canvas.tool(for: .text).isBusy && AppModel.shared.tool != .text), "no text editor is opened behind another tool's back",
                     "current tool \(AppModel.shared.tool.rawValue), text busy \(r.canvas.tool(for: .text).isBusy)")
            r.select(.text); r.key(R.kEsc, "\u{1b}"); r.select(.hand)
        }
        with("tool/text/document-switch", "raster", tool: .text, checkIdle: false) { r, d, f in
            let s = QASnapshot(d)
            r.click(P(30, 140)); editing(r)?.insertText("Doc A", replacementRange: NSRange(location: 0, length: 0))
            // another document becomes active (tab click) while typing
            let other = r.open(QAFixtures.base(), name: "other")
            let so = QASnapshot(other)
            QA.check(editing(r) == nil && !r.canvas.tool(for: .text).isBusy, "switching documents closes the editor")
            QA.check(steps(d, s) == ["Type Layer"] && d.state.allLayers.contains { $0.text?.text == "Doc A" }, "the typed text is committed to the document it was typed in", "\(steps(d, s)) \(QAMeasure.tree(d.state))")
            QA.check(d.hiddenLayers.isEmpty, "the type layer is not left hidden in its document")
            QA.check(other.historyIndex == so.historyIndex && QAMeasure.fingerprint(other.state) == so.print, "the other document is not touched", "\(steps(other, so))")
            r.activate(d)
            QAInvariant.idle(r, "back in the first document")
        }
        with("tool/text/document-close", "raster", tool: .text, checkIdle: false) { r, d, f in
            r.click(P(30, 140)); editing(r)?.insertText("Bye", replacementRange: NSRange(location: 0, length: 0))
            r.closeAll()
            QA.check(editing(r) == nil && !r.canvas.tool(for: .text).isBusy && !AppModel.shared.textEditingActive, "closing the document closes the editor",
                     "busy \(r.canvas.tool(for: .text).isBusy)")
            QA.check(r.canvas.subviews.filter { $0 is NSTextView }.isEmpty, "no editor view is left on the canvas")
        }
        for k in [ToolKind.typeMaskHorizontal, .typeMaskVertical] {
            with("tool/\(k.rawValue)", "raster", tool: k) { r, d, f in
                let s = QASnapshot(d)
                let n0 = d.state.allLayers.count
                r.click(P(40, 120)); editing(r)?.insertText("MASK", replacementRange: NSRange(location: 0, length: 0)); r.drawOverlay()
                r.key(R.kEsc, "\u{1b}"); r.pump(0.02)
                expectSteps(d, s, ["Type Mask"], "type mask")
                QA.check(d.state.selection != nil && d.state.allLayers.count == n0, "the type mask becomes a selection, not a layer", "\(QAMeasure.tree(d.state))")
                // empty mask: nothing
                r.click(P(100, 40)); r.key(R.kEsc, "\u{1b}"); r.pump(0.02)
                expectSteps(d, s, ["Type Mask"], "empty type mask")
                // tool switch while typing commits the mask
                r.mods = [.shift]; r.click(P(40, 60)); r.mods = []
                editing(r)?.insertText("X", replacementRange: NSRange(location: 0, length: 0))
                r.select(.hand); r.pump(0.02)
                expectSteps(d, s, ["Type Mask", "Type Mask"], "tool switch")
                QA.check(d.state.allLayers.count == n0, "no stray type layer")
                r.select(k)
            }
        }
    }

    // MARK: Shapes

    static func shapeTools() {
        let kinds: [ToolKind] = [.rectangle, .roundedRect, .ellipse, .polygon, .line, .customShape, .libraryShape, .triangle]
        for k in kinds {
            for v in (k == .rectangle || k == .triangle ? QAView.all : [QAView.identity]) {
                with("tool/\(k.rawValue)/\(v.name)", "raster", tool: k, view: v) { r, d, f in
                    let s = QASnapshot(d)
                    let n0 = d.state.allLayers.count
                    r.click(P(50, 50)); r.dragLine(P(50, 50), CGPoint(x: 51.2, y: 50.9), steps: 1)
                    expectSteps(d, s, [], "click / tiny drag")
                    r.dragLine(P(40, 30), P(140, 110), steps: 4) { i in if i == 2 { r.drawOverlay() } }
                    expectSteps(d, s, ["New Shape Layer"], "drag")
                    QA.check(d.state.allLayers.count == n0 + 1 && d.state.layer(d.activeLayerID)?.isShape == true, "a drag creates one shape layer")
                    if k != .line && k != .polygon && k != .customShape && k != .libraryShape {
                        QA.check(near(d.state.layer(d.activeLayerID)?.shape?.path.bounds, CGRect(x: 40.37, y: 30.41, width: 100, height: 80), 1.5), "the shape fills the dragged rectangle in a \(v.name) view",
                                 QAMeasure.describe(d.state.layer(d.activeLayerID)?.shape?.path.bounds))
                    }
                    // Shift constrains, Option draws from the centre
                    r.down(P(150, 20)); r.drag(P(170, 60)); r.setMods([.shift]); r.drag(P(200, 60)); r.up(P(200, 60)); r.setMods([])
                    if k == .rectangle || k == .ellipse {
                        let b = d.state.layer(d.activeLayerID)?.shape?.path.bounds ?? .zero
                        QA.check(abs(b.width - b.height) < 0.5, "Shift makes it square", QAMeasure.describe(b))
                    }
                }
            }
        }
        with("tool/rectangle/path+pixels", "raster", tool: .rectangle) { r, d, f in
            let s = QASnapshot(d)
            AppModel.shared.shapeTool.mode = .path
            r.dragLine(P(40, 30), P(140, 110), steps: 3)
            expectSteps(d, s, ["Work Path"], "path mode")
            QA.check(d.state.paths.count == 1 && d.state.allLayers.count == 2, "path mode makes a work path")
            AppModel.shared.shapeTool.mode = .pixels
            d.selectLayer(f.active!)
            r.dragLine(P(10, 120), P(60, 150), steps: 3)
            expectSteps(d, s, ["Work Path", "Rectangle"], "pixels mode")
            QA.check(pixel(d, f.active!, 30, 135).3 == 255, "pixels mode fills the active pixel layer")
        }
        with("tool/rectangle/pixels-locked", "locked-all", tool: .rectangle) { r, d, f in
            AppModel.shared.shapeTool.mode = .pixels
            let s = QASnapshot(d)
            r.dragLine(P(10, 120), P(60, 150), steps: 3)
            QA.check(QAMeasure.fingerprint(d.state) == s.print, "pixels mode does not fill a locked layer")
        }
    }

    // MARK: View tools

    static func viewTools() {
        for v in QAView.all {
            with("tool/hand+zoom+rotate/\(v.name)", "raster", tool: .hand, view: v) { r, d, f in
                let s = QASnapshot(d)
                let o0 = d.viewOffset
                let a = r.canvas.docToView(P(100, 70))
                r.downView(a); r.dragView(CGPoint(x: a.x + 30, y: a.y - 20)); r.upView(CGPoint(x: a.x + 30, y: a.y - 20))
                QA.check(abs(d.viewOffset.x - o0.x - 30) < 0.01 && abs(d.viewOffset.y - o0.y + 20) < 0.01, "the hand pans by the drag distance")
                r.select(.zoom)
                let p = P(100, 70), vp = r.canvas.docToView(p)
                let z0 = d.zoom
                r.downView(vp); r.upView(vp)
                QA.check(d.zoom > z0 && r.canvas.docToView(p).distance(to: vp) < 0.5, "zoom in keeps the clicked point under the cursor", "zoom \(z0) → \(d.zoom)")
                r.mods = [.option]; r.downView(vp); r.upView(vp); r.mods = []
                QA.check(d.zoom <= z0 + 1e-6 && r.canvas.docToView(p).distance(to: vp) < 0.5, "Option-click zooms back out around the cursor", "zoom \(d.zoom)")
                r.select(.rotateView)
                let c = CGPoint(x: r.canvas.bounds.midX, y: r.canvas.bounds.midY)
                let rot0 = d.viewRotation
                r.downView(CGPoint(x: c.x + 100, y: c.y)); r.dragView(CGPoint(x: c.x, y: c.y + 100)); r.upView(CGPoint(x: c.x, y: c.y + 100)); r.drawOverlay()
                QA.check(abs(d.viewRotation - rot0 - .pi / 2) < 1e-6, "rotate view follows the drag angle", "\(d.viewRotation - rot0)")
                r.key(R.kEsc, "\u{1b}")
                QA.check(d.viewRotation == 0, "Esc resets the view rotation")
                expectSteps(d, s, [], "view tools")
                QA.check(QAMeasure.fingerprint(d.state) == s.print, "view tools never change the document")
            }
        }
        for v in QAView.all {
            with("tool/zoom/drag-rect/\(v.name)", "raster", tool: .zoom, view: v) { r, d, f in
                // a 100 × 70 px box on screen around a known document point
                let centre = P(110, 75)
                let vc = r.canvas.docToView(centre)
                let z0 = d.zoom
                r.downView(CGPoint(x: vc.x - 50, y: vc.y - 35)); r.dragView(CGPoint(x: vc.x, y: vc.y)); r.dragView(CGPoint(x: vc.x + 50, y: vc.y + 35)); r.drawOverlay()
                r.upView(CGPoint(x: vc.x + 50, y: vc.y + 35))
                let c = r.canvas.docToView(centre)
                let expected = z0 * Double(min(r.canvas.bounds.width / 100, r.canvas.bounds.height / 70))
                QA.check(abs(d.zoom - min(64, expected)) < 0.01 && c.distance(to: CGPoint(x: r.canvas.bounds.midX, y: r.canvas.bounds.midY)) < 1,
                         "dragging with the zoom tool makes the dragged box fill the view, centred (\(v.name))", "zoom \(d.zoom) (expected \(expected)), centre at \(c)")
            }
        }
        with("tool/ruler", "raster", tool: .ruler) { r, d, f in
            let s = QASnapshot(d)
            r.dragLine(P(40, 40), P(140, 40), steps: 3); r.drawOverlay()
            let l = RulerTool.line(d)
            QA.check(l != nil && abs(RulerTool.measure(l!).length - 100) < 0.01, "the ruler measures the dragged distance")
            r.mods = [.shift]; r.dragLine(P(40, 100), P(140, 108), steps: 3); r.mods = []
            QA.check(abs(RulerTool.measure(RulerTool.line(d)!).dy) < 0.01, "Shift constrains the ruler")
            expectSteps(d, s, [], "ruler")
        }
    }

    // MARK: Tools module

    static func extraTools() {
        for v in [QAView.identity, QAView.half] {
            with("tool/artboard/\(v.name)", "raster", tool: .artboard, view: v) { r, d, f in
                let s = QASnapshot(d)
                r.click(P(30, 30)); r.dragLine(P(30, 30), P(32, 31), steps: 1)
                expectSteps(d, s, [], "click / tiny drag")
                r.dragLine(CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 100), steps: 3)
                expectSteps(d, s, ["New Artboard"], "drag")
                guard let ab = AppActions.artboards(d).first else { QA.check(false, "artboard created"); return }
                // Auto-size Canvas fits the canvas to the artboard (its corner becomes the canvas corner); positions are
                // checked in the document's own coordinates (what Properties shows), which the trim doesn't change
                func W(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x + d.state.artboardOrigin.x, y: y + d.state.artboardOrigin.y) }
                func rect(_ id: UUID) -> CGRect? {
                    d.state.layer(id)?.artboard.map { a in CGRect(origin: ArtboardCoords.artboardPosition(a.rect, d.state), size: a.rect.size) }
                }
                QA.check(rect(ab.id) == CGRect(x: 20, y: 20, width: 100, height: 80), "the artboard has the dragged rectangle", "\(String(describing: rect(ab.id)))")
                // move it by its body, resize by a handle (creating one refits the view, so convert through the canvas again)
                r.drawOverlay()
                r.dragLine(W(60, 60), W(90, 75), steps: 3)
                QA.check(steps(d, s) == ["New Artboard", "Move Artboard"] && rect(ab.id) == CGRect(x: 50, y: 35, width: 100, height: 80), "dragging the artboard moves it",
                         "\(steps(d, s)) \(String(describing: rect(ab.id)))")
                r.down(W(150, 115)); r.drag(W(170, 125)); r.up(W(170, 125))
                QA.check(steps(d, s).last == "Resize Artboard" && rect(ab.id) == CGRect(x: 50, y: 35, width: 120, height: 90), "dragging a handle resizes it",
                         "\(steps(d, s)) \(String(describing: rect(ab.id)))")
            }
        }
        with("tool/artboard/grow-canvas-keeps-guides", "artboard", tool: .artboard) { r, d, f in
            // a guide on the artboard's left edge, a path and a count mark on its corner
            d.state.guides = [Guide(isVertical: true, position: 40)]
            d.state.paths = [NamedPath(name: "p", path: VectorPath.rect(CGRect(x: 40, y: 20, width: 160, height: 120)))]
            d.state.toolData.countGroups = [CountGroup(name: "g", color: .black)]
            d.state.toolData.countGroups[0].points = [CGPoint(x: 40, y: 20)]
            d.commit("setup")
            r.dragLine(P(100, 70), P(30, 40), steps: 3)          // moves the artboard past the left / top canvas edge: the canvas grows
            guard let ab = d.state.layer(f.active)?.artboard?.rect else { return }
            QA.check(abs((d.state.guides.first?.position ?? -1) - Double(ab.minX) - 70) < 0.5 || abs((d.state.guides.first?.position ?? -1) - 40 - Double(d.state.width - 240)) < 0.5,
                     "guides keep their place on the image when the canvas grows to the left", "guide \(d.state.guides.first?.position ?? -1), artboard \(ab), canvas \(d.state.width)×\(d.state.height)")
            let grown = CGFloat(d.state.width - 240), grownY = CGFloat(d.state.height - 160)
            QA.check(abs((d.state.paths.first?.path.bounds.minX ?? -1) - 40 - grown) < 0.5 && abs((d.state.toolData.countGroups.first?.points.first?.y ?? -1) - 20 - grownY) < 0.5,
                     "paths and count marks keep their place too", "path \(QAMeasure.describe(d.state.paths.first?.path.bounds)) mark \(String(describing: d.state.toolData.countGroups.first?.points.first))")
        }
        with("tool/artboard/plus-button", "artboard", tool: .artboard) { r, d, f in
            let s = QASnapshot(d)
            let ab = d.state.layer(f.active)!.artboard!.rect
            r.drawOverlay()
            // the "+" to the right of the active artboard (24 px outside its edge, in view space)
            let v = r.canvas.docToView(CGPoint(x: ab.maxX, y: ab.midY))
            r.downView(CGPoint(x: v.x + 24, y: v.y)); r.upView(CGPoint(x: v.x + 24, y: v.y))
            expectSteps(d, s, ["New Artboard"], "+ button")
            let boards = AppActions.artboards(d)
            QA.check(boards.count == 2 && boards.last?.artboard?.rect.size == ab.size && !(boards.last?.artboard?.rect.intersects(boards.first!.artboard!.rect) ?? true),
                     "the + button adds an artboard of the same size beside the active one", "\(boards.map { $0.artboard!.rect })")
        }
        with("tool/artboard/locked", "artboard", tool: .artboard) { r, d, f in
            d.updateLayer(f.active!) { $0.locks.position = true }
            d.commit("lock")
            let s = QASnapshot(d)
            r.dragLine(P(100, 70), P(130, 90), steps: 3)                                         // body
            r.down(CGPoint(x: 200, y: 140)); r.drag(CGPoint(x: 220, y: 150)); r.up(CGPoint(x: 220, y: 150))   // corner handle
            QA.check(QAMeasure.fingerprint(d.state) == s.print && d.historyIndex == s.historyIndex, "a position-locked artboard is not moved or resized", "\(steps(d, s))")
        }
        with("tool/artboard/children-follow", "artboard", tool: .artboard) { r, d, f in
            let child = d.state.layer(f.active)!.children[0].id
            let b0 = bounds(d, child)
            r.dragLine(P(100, 70), P(110, 85), steps: 3)
            QA.check(near(bounds(d, child), b0?.offsetBy(dx: 10, dy: 15)), "artboard children move with the artboard")
        }
        for v in [QAView.identity, QAView.rotated] {
            with("tool/frame/\(v.name)", "empty", tool: .frame, view: v) { r, d, f in
                let s = QASnapshot(d)
                r.click(P(30, 30))
                expectSteps(d, s, [], "click")
                r.dragLine(CGPoint(x: 40, y: 30), CGPoint(x: 140, y: 110), steps: 3) { i in if i == 2 { r.drawOverlay() } }
                expectSteps(d, s, ["New Frame"], "drag")
                let fr = d.state.layer(d.activeLayerID)
                QA.check(fr?.isGroup == true && near(fr?.vectorMask?.bounds, CGRect(x: 40, y: 30, width: 100, height: 80), 1.1), "the frame has the dragged rectangle", QAMeasure.describe(fr?.vectorMask?.bounds))
                d.selectLayer(d.state.layers[0].id)
                r.click(CGPoint(x: 90, y: 70))
                QA.check(d.activeLayerID == fr?.id && steps(d, s) == ["New Frame"], "clicking a frame selects it")
                r.drawOverlay()
            }
        }
        with("tool/frame/wraps-image", "smart", tool: .frame) { r, d, f in
            let s = QASnapshot(d)
            r.dragLine(CGPoint(x: 80, y: 50), CGPoint(x: 140, y: 100), steps: 3)
            expectSteps(d, s, ["New Frame"], "frame over an image")
            let fr = d.state.layer(d.activeLayerID)
            QA.check(fr?.children.count == 1 && fr?.children.first?.id == f.active && d.state.layers.count == 2, "drawing a frame over the selected image puts the image into the frame")
            let comp = QAMeasure.composite(d.state), bg = QAMeasure.composite(QAFixtures.base())
            QA.check(comp.pixel(70, 60) == bg.pixel(70, 60) && comp.pixel(110, 75) != bg.pixel(110, 75), "the image is clipped to the frame")
        }
        for v in [QAView.identity, QAView.double] {
            with("tool/slice/\(v.name)", "raster", tool: .slice, view: v) { r, d, f in
                let s = QASnapshot(d)
                r.click(P(30, 30))
                expectSteps(d, s, [], "click")
                r.dragLine(CGPoint(x: 40, y: 30), CGPoint(x: 140, y: 110), steps: 3)
                expectSteps(d, s, ["Slice"], "drag")
                QA.check(d.state.toolData.slices.first?.rect == CGRect(x: 40, y: 30, width: 100, height: 80), "the slice has the dragged rectangle", "\(String(describing: d.state.toolData.slices.first?.rect))")
                r.select(.sliceSelect)
                r.click(CGPoint(x: 90, y: 70))
                expectSteps(d, s, ["Slice"], "selecting a slice")
                r.dragLine(CGPoint(x: 90, y: 70), CGPoint(x: 100, y: 90), steps: 3); r.drawOverlay()
                QA.check(steps(d, s) == ["Slice", "Edit Slice"] && d.state.toolData.slices.first?.rect == CGRect(x: 50, y: 50, width: 100, height: 80), "slice select moves the slice", "\(steps(d, s))")
                r.key(R.kDelete, "\u{7f}")
                QA.check(steps(d, s).last == "Delete Slice" && d.state.toolData.slices.isEmpty && d.state.allLayers.count == 2, "Delete removes the selected slice (not the layer)", "\(steps(d, s))")
            }
        }
        with("tool/colorSampler", "raster", tool: .colorSampler) { r, d, f in
            let s = QASnapshot(d)
            r.click(P(70, 50)); r.drawOverlay()
            expectSteps(d, s, ["Color Sampler"], "click")
            r.click(CGPoint(x: -30, y: 10))
            expectSteps(d, s, ["Color Sampler"], "click outside the canvas")
            r.dragLine(P(70, 50), P(90, 60), steps: 3)
            expectSteps(d, s, ["Color Sampler", "Move Color Sampler"], "drag")
            r.click(P(90, 60))
            expectSteps(d, s, ["Color Sampler", "Move Color Sampler"], "click on a sampler")
            r.dragLine(P(90, 60), CGPoint(x: -40, y: 60), steps: 3)
            QA.check(steps(d, s).last == "Delete Color Sampler" && d.state.toolData.colorSamplers.isEmpty, "dragging a sampler off the canvas deletes it", "\(steps(d, s))")
        }
        with("tool/note", "raster", tool: .note) { r, d, f in
            let s = QASnapshot(d)
            r.click(P(70, 50)); r.drawOverlay()
            expectSteps(d, s, ["New Note"], "click")
            r.click(CGPoint(x: 75, y: 55))
            expectSteps(d, s, ["New Note"], "click on the note")
            r.dragLine(CGPoint(x: 75, y: 55), CGPoint(x: 120, y: 90), steps: 3)
            expectSteps(d, s, ["New Note", "Move Note"], "drag")
            r.mods = [.option]; r.click(CGPoint(x: 120, y: 90)); r.mods = []
            QA.check(steps(d, s).last == "Delete Note" && d.state.toolData.notes.isEmpty, "Option-click deletes the note", "\(steps(d, s))")
        }
        with("tool/count", "raster", tool: .count) { r, d, f in
            let s = QASnapshot(d)
            r.click(P(70, 50)); r.click(P(120, 80)); r.drawOverlay()
            expectSteps(d, s, ["Count", "Count"], "two marks")
            r.click(CGPoint(x: 70, y: 50))
            expectSteps(d, s, ["Count", "Count"], "click on a mark without dragging")
            r.dragLine(CGPoint(x: 70, y: 50), CGPoint(x: 60, y: 120), steps: 3)
            expectSteps(d, s, ["Count", "Count", "Move Count"], "drag")
            r.click(CGPoint(x: 300, y: 50))
            QA.check(CountTool.total(d) == 2, "clicks outside the canvas add nothing")
        }
    }

    // MARK: Canvas-level input (guides from the rulers, space bar, keys)

    static func canvasInput() {
        var rulers = QAView.identity
        rulers.rulers = true; rulers.name = "rulers"
        with("canvas/guides", "raster", tool: .move, view: rulers) { r, d, f in
            AppModel.shared.moveShowTransform = false
            let s = QASnapshot(d)
            let b0 = bounds(d, f.active)
            // drag out of the left ruler: a vertical guide; the Move tool must not move anything
            r.downView(CGPoint(x: 8, y: 200)); r.dragView(CGPoint(x: 100, y: 200)); r.drawOverlay(); r.upView(r.canvas.docToView(CGPoint(x: 80, y: 100)))
            expectSteps(d, s, ["New Guide"], "drag from the ruler")
            QA.check(d.state.guides.count == 1 && d.state.guides[0].isVertical && d.state.guides[0].position == 80 && near(bounds(d, f.active), b0), "a guide is created, the layer stays")
            // drag the guide, then drag it off the canvas
            r.dragLine(CGPoint(x: 80, y: 140), CGPoint(x: 120, y: 140), steps: 3)
            QA.check(steps(d, s) == ["New Guide", "Move Guide"] && d.state.guides.first?.position == 120 && near(bounds(d, f.active), b0), "the Move tool drags guides", "\(steps(d, s))")
            r.dragLine(CGPoint(x: 120, y: 140), CGPoint(x: -30, y: 140), steps: 3)
            QA.check(steps(d, s).last == "Delete Guide" && d.state.guides.isEmpty, "dragging a guide off the canvas deletes it", "\(steps(d, s))")
        }
        with("canvas/space-bar-hand", "raster", tool: .brush) { r, d, f in
            let s = QASnapshot(d)
            let o0 = d.viewOffset
            r.key(R.kSpace, " ")
            QA.check(r.canvas.effectiveToolKind == .hand, "holding Space switches to the hand")
            let a = r.canvas.docToView(P(100, 70))
            r.downView(a); r.dragView(CGPoint(x: a.x + 25, y: a.y + 10)); r.upView(CGPoint(x: a.x + 25, y: a.y + 10))
            let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: r.window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: R.kSpace)!
            _ = KeyRouter.handle(up)
            QA.check(r.canvas.effectiveToolKind == .brush && abs(d.viewOffset.x - o0.x - 25) < 0.01, "Space-drag pans and releasing returns to the brush")
            expectSteps(d, s, [], "space-drag")
        }
        with("canvas/delete-key", "raster", tool: .marqueeRect, selection: QAFixtures.rectSelection(CGRect(x: 80, y: 50, width: 40, height: 30))) { r, d, f in
            let s = QASnapshot(d)
            r.key(R.kDelete, "\u{7f}")
            expectSteps(d, s, ["Clear"], "Delete with a selection")
            QA.check(pixel(d, f.active!, 100, 65).3 == 0 && pixel(d, f.active!, 70, 45).3 == 255, "Delete clears the selected pixels only")
        }
        for name in ["locked-all", "locked-pixels", "hidden"] {
            with("canvas/delete-key/\(name)", name, tool: .marqueeRect, selection: QAFixtures.rectSelection(CGRect(x: 80, y: 50, width: 40, height: 30))) { r, d, f in
                let p0 = QAMeasure.layerPrint(d.state.layer(f.active)!)
                r.key(R.kDelete, "\u{7f}")
                QA.check(d.state.layer(f.active).map { QAMeasure.layerPrint($0) == p0 } ?? false, "Delete does not clear pixels of a \(name) layer")
            }
        }
        with("canvas/tool-shortcuts", "raster", tool: .brush) { r, d, f in
            r.key(9, "v")
            QA.check(AppModel.shared.tool == .move, "V selects the Move tool", AppModel.shared.tool.rawValue)
            r.key(11, "b")
            QA.check(AppModel.shared.tool == .brush, "B selects the Brush", AppModel.shared.tool.rawValue)
            let size = AppModel.shared.brush.size
            r.key(30, "]")
            QA.check(AppModel.shared.brush.size > size, "] grows the brush")
            // shortcuts are typed, not executed, while the text editor is open
            r.select(.text); r.click(P(30, 140)); r.key(9, "v")
            QA.check(AppModel.shared.tool == .text, "tool shortcuts do not fire while typing", AppModel.shared.tool.rawValue)
            r.key(R.kEsc, "\u{1b}")
        }
    }
}
