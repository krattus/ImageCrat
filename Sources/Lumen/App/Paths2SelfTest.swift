import AppKit
import ImageCratCore

/// Paths handled apart from shapes (Photoshop's model): Path mode makes only an outline for every pen and shape tool,
/// modes remembered per tool, the active path shown until deselected (Esc / Return / Paths panel), never printed, the
/// temporary Work Path replaced unless saved, conversions (selection, fill, stroke, vector mask, shape, work path from a
/// selection) as single undo steps, path tools on work paths next to shape layers, `.imagecrat` and PSD.
/// `LUMEN_SELFTEST_ONLY=paths2 Lumen --selftest <dir>`
enum Paths2SelfTest {
    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") paths2: \(name)\(d.isEmpty ? "" : " — " + d)")
        fflush(stdout)
    }

    typealias R = ToolRobot
    typealias TP = TypePathSelfTest

    static func run(_ out: URL) {
        passes = 0; failures = 0
        QA.out = out
        setvbuf(stdout, nil, _IONBF, 0)
        let app = AppModel.shared
        let saved = (tool: app.tool, shape: app.shapeTool, pen: app.penMode, canvas: AppActions.canvas, docs: app.documents,
                     active: app.activeDocumentID, dialog: app.dialog, fg: app.foreground, brush: app.brush, show: PathOverlay.showTargetPath)
        app.dialog = nil
        app.documents = []; app.activeDocumentID = nil
        let savedButton = CanvasView.primaryButtonDown
        CanvasView.primaryButtonDown = { ToolRobot.buttonDown }
        let savedModes = ToolModes.memory
        ToolModes.memory = [:]
        defer {
            CanvasView.primaryButtonDown = savedButton
            ToolModes.memory = savedModes
            PathOverlay.showTargetPath = saved.show
            app.tool = saved.tool; app.shapeTool = saved.shape; app.penMode = saved.pen; app.foreground = saved.fg; app.brush = saved.brush
            app.documents = saved.docs; app.activeDocumentID = saved.active; app.dialog = saved.dialog
            AppActions.canvas = saved.canvas
        }
        pathModeEveryTool()
        modesPerTool()
        visibilityAndDeselect()
        workPathLifecycle()
        conversions()
        pathToolsOnWorkPaths()
        persistence(out)
        print("paths2: \(passes) checks passed, \(failures) failed")
    }

    static func composite(_ d: Document) -> PixelBuffer { QAMeasure.composite(d.state) }

    // MARK: - Path mode: only a path, for every pen and shape tool

    static func pathModeEveryTool() {
        let r = R()
        let app = AppModel.shared
        let tools: [ToolKind] = [.pen, .freeformPen, .curvaturePen, .rectangle, .roundedRect, .ellipse, .polygon, .line, .customShape, .libraryShape, .triangle]
        for k in tools {
            let d = r.open(SelfTest.baseState(320, 240), name: "pathmode-\(k.rawValue)")
            app.shapeTool = ShapeToolSettings()
            app.shapeTool.stroke = .color(RGBA(hex: "FF0000")!)      // a stroke and fill that must not appear
            r.select(.hand); r.select(k)
            ToolModes.set(.path, for: k)
            let before = composite(d), layers = d.state.allLayers.count
            switch k {
            case .pen: r.click(CGPoint(x: 40, y: 40)); r.click(CGPoint(x: 200, y: 60)); r.click(CGPoint(x: 120, y: 180)); r.click(CGPoint(x: 40, y: 40))
            case .curvaturePen: r.click(CGPoint(x: 40, y: 40)); r.click(CGPoint(x: 200, y: 60)); r.click(CGPoint(x: 120, y: 180)); r.key(R.kReturn, "\r")
            case .freeformPen: r.dragPath([CGPoint(x: 40, y: 40), CGPoint(x: 120, y: 30), CGPoint(x: 220, y: 90), CGPoint(x: 160, y: 190), CGPoint(x: 60, y: 160), CGPoint(x: 41, y: 42)])
            default: r.dragLine(CGPoint(x: 50, y: 40), CGPoint(x: 250, y: 190), steps: 5)
            }
            r.select(.hand)
            let after = composite(d)
            let np = d.state.paths.first
            check(d.state.allLayers.count == layers && (np?.path.isEmpty == false) && np?.name == "Work Path" && QAMeasure.diff(before, after) == 0,
                  "\(k.displayName) in Path mode: a Work Path only — no layer, no fill, no stroke, no pixels",
                  "\(d.state.allLayers.count - layers) layers, path \(np?.path.subpaths.map(\.points.count) ?? []), diff \(QAMeasure.diff(before, after))")
            r.closeAll()
        }
    }

    // MARK: - Modes remembered per tool

    static func modesPerTool() {
        let r = R()
        let app = AppModel.shared
        _ = r.open(SelfTest.baseState(200, 150), name: "modes")
        let storedBefore = UserDefaults.standard.dictionary(forKey: ToolModes.key) as? [String: String]
        ToolModes.memory = [:]
        check(ToolModes.modes(for: .pen) == [.shape, .path] && ToolModes.modes(for: .curvaturePen) == [.shape, .path], "pens offer Shape and Path only")
        check(ToolModes.modes(for: .rectangle) == ShapeMode.allCases && ToolModes.modes(for: .triangle) == ShapeMode.allCases, "shape tools offer Shape, Path and Pixels")
        check(ShapeToolSettings().mode == .shape, "shape tools start in Shape mode")
        r.select(.rectangle); ToolModes.set(.path, for: .rectangle)
        r.select(.ellipse); ToolModes.set(.pixels, for: .ellipse)
        r.select(.pen); ToolModes.set(.shape, for: .pen)
        r.select(.freeformPen); ToolModes.set(.path, for: .freeformPen)
        r.select(.rectangle)
        check(app.shapeTool.mode == .path, "the Rectangle tool comes back in its Path mode")
        r.select(.ellipse)
        check(app.shapeTool.mode == .pixels, "the Ellipse tool comes back in its Pixels mode")
        r.select(.pen)
        check(app.penMode == .shape, "the Pen comes back in Shape mode")
        r.select(.freeformPen)
        check(app.penMode == .path, "the Freeform Pen keeps its own mode (Path)")
        app.penMode = .pixels
        r.select(.hand); r.select(.curvaturePen)
        check(ToolModes.current(.curvaturePen) == .path && app.penMode == .path, "a pen never runs in Pixels mode")
        check(ToolModes.automated && (UserDefaults.standard.dictionary(forKey: ToolModes.key) as? [String: String]) == storedBefore,
              "automated runs keep the modes in memory only (preferences untouched)")
        ToolModes.memory = [:]
        r.closeAll()
    }

    // MARK: - Shown while active, never printed, Esc / Return / panel deselect

    static func visibilityAndDeselect() {
        let r = R()
        let app = AppModel.shared
        let d = r.open(SelfTest.baseState(320, 240), name: "visible")
        app.shapeTool = ShapeToolSettings(); app.shapeTool.mode = .path
        let before = composite(d)
        r.select(.hand); r.select(.rectangle)
        r.dragLine(CGPoint(x: 60, y: 60), CGPoint(x: 260, y: 180), steps: 4)
        let edge = CGPoint(x: 160, y: 60)
        check(TP.inkAt(r, edge) > 0, "the active path is outlined on the canvas")
        check(QAMeasure.diff(before, composite(d)) == 0, "the path is not in the composite")
        // export (flattened PNG) has no trace of the path
        let png1 = QA.out.appendingPathComponent("paths2_export_with_path.png"), png0 = QA.out.appendingPathComponent("paths2_export_without.png")
        var noPath = d.state; noPath.paths = []
        try? DocumentIO.export(d.state, to: png1, format: .png, quality: 1, scale: 1)
        try? DocumentIO.export(noPath, to: png0, format: .png, quality: 1, scale: 1)
        let e1 = (try? Data(contentsOf: png1)) ?? Data(), e0 = (try? Data(contentsOf: png0)) ?? Data([1])
        check(!e1.isEmpty && e1 == e0, "path outlines are not in exports")
        // View ▸ Show Target Path off hides it
        PathOverlay.showTargetPath = false
        check(TP.inkAt(r, edge) == 0, "Show Target Path off hides the outline")
        PathOverlay.showTargetPath = true
        // Esc with the shape tool (Path mode), the Pen, the Path Selection tool
        r.key(R.kEsc, "\u{1b}")
        check(d.activePathID == nil && TP.inkAt(r, edge) == 0, "Esc deselects the path: outline hidden (shape tool)")
        check(d.state.paths.count == 1, "deselecting keeps the path")
        PathOps.selectPath(d, d.state.paths[0].id)
        r.select(.pen)
        r.key(R.kReturn, "\r")
        check(d.activePathID == nil, "Return with the Pen (nothing being drawn) deselects the path")
        PathOps.selectPath(d, d.state.paths[0].id)
        r.select(.pathSelect)
        r.key(R.kEsc, "\u{1b}")
        check(d.activePathID == nil, "Esc with the Path Selection tool deselects the path")
        PathOps.selectPath(d, d.state.paths[0].id)
        r.select(.curvaturePen)
        r.key(R.kEsc, "\u{1b}")
        check(d.activePathID == nil, "Esc with the Curvature Pen deselects the path")
        // Paths panel: a click on a row shows it, on empty space hides it (PathOps used by the panel)
        PathOps.selectPath(d, d.state.paths[0].id)
        check(TP.inkAt(r, edge) > 0, "selecting the path in the Paths panel shows it")
        PathOps.deselectPath(d)
        check(TP.inkAt(r, edge) == 0, "clicking empty space in the Paths panel hides it")
        r.select(.hand)
        QAInvariant.idle(r, "visibility")
        r.closeAll()
    }

    // MARK: - Work Path: replaced unless saved; save, rename, duplicate, delete

    static func workPathLifecycle() {
        let r = R()
        let app = AppModel.shared
        let d = r.open(SelfTest.baseState(320, 240), name: "lifecycle")
        app.shapeTool = ShapeToolSettings(); app.shapeTool.mode = .path
        r.select(.hand); r.select(.ellipse)
        r.dragLine(CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 100), steps: 3)
        // with the Work Path active, a second shape is added to it
        r.dragLine(CGPoint(x: 150, y: 20), CGPoint(x: 250, y: 100), steps: 3)
        check(d.state.paths.count == 1 && d.state.paths[0].path.subpaths.count == 2, "the active Work Path takes the next shape as a component")
        // deselected: the next path replaces the Work Path
        r.key(R.kEsc, "\u{1b}")
        r.dragLine(CGPoint(x: 60, y: 130), CGPoint(x: 200, y: 220), steps: 3)
        check(d.state.paths.count == 1 && d.state.paths[0].path.subpaths.count == 1 && d.state.paths[0].name == "Work Path",
              "a new path replaces the unsaved Work Path", "\(d.state.paths.map { "\($0.name) \($0.path.subpaths.count)" })")
        // save it (double-click in the panel)
        var s = QASnapshot(d)
        let pid = PathOps.saveWorkPath(d)
        check(d.state.paths.first?.name == "Path 1" && pid == d.state.paths.first?.id && TP.steps(d, s) == ["Save Path"], "Save Path: the Work Path becomes \"Path 1\", one step")
        // a saved path is not replaced: a new path while nothing is active makes a new Work Path
        PathOps.deselectPath(d)
        r.dragLine(CGPoint(x: 220, y: 140), CGPoint(x: 300, y: 220), steps: 3)
        check(d.state.paths.map(\.name) == ["Path 1", "Work Path"], "the saved path is kept; a new Work Path is made", "\(d.state.paths.map(\.name))")
        // while a saved path is active, new shapes are added to it
        PathOps.selectPath(d, pid!)
        r.dragLine(CGPoint(x: 10, y: 200), CGPoint(x: 50, y: 230), steps: 2)
        check(d.state.paths[0].path.subpaths.count == 2 && d.state.paths.count == 2, "the active saved path takes new components")
        s = QASnapshot(d)
        PathOps.rename(d, pid!, to: "Outline")
        check(d.state.paths[0].name == "Outline" && TP.steps(d, s) == ["Rename Path"], "rename, one step")
        s = QASnapshot(d)
        let dup = PathOps.duplicate(d, pid)
        check(d.state.paths.count == 3 && d.state.paths.last?.name == "Outline copy" && d.state.paths.last?.path == d.state.paths[0].path && d.activePathID == dup,
              "Duplicate Path", "\(d.state.paths.map(\.name))")
        let np = PathOps.newPath(d)
        check(d.state.paths.last?.name == "Path 1" && d.state.paths.last?.path.isEmpty == true && d.activePathID == np, "New Path (empty, next free name)",
              "\(d.state.paths.map(\.name))")
        PathOps.delete(d, np)
        PathOps.delete(d, dup!)
        check(d.state.paths.count == 2 && TP.steps(d, s) == ["Duplicate Path", "New Path", "Delete Path", "Delete Path"], "each panel command is one step", "\(TP.steps(d, s))")
        for _ in 0..<4 { d.undo() }
        check(QAMeasure.fingerprint(d.state) == s.print, "undo restores the paths exactly")
        // a shape layer's outline: shown in the panel, duplicated into a saved path
        let shape = Layer(name: "Shape 1", content: .shape(ShapeContent(geometry: .polygon(CGRect(x: 40, y: 40, width: 120, height: 120), sides: 5, starRatio: 1))))
        d.addLayer(shape); d.commit("Add")
        PathOps.deselectPath(d)
        check(PathOps.actionPath(d)?.name == "Shape 1 Shape Path", "the active shape layer's outline is the panel's \"Shape 1 Shape Path\"")
        let sdup = PathOps.duplicate(d, nil)
        check(d.state.paths.first { $0.id == sdup }?.name == "Shape 1 Shape Path copy" && d.state.paths.first { $0.id == sdup }?.path == shape.shape?.path
              && d.state.layer(shape.id)?.shape == shape.shape, "a shape's outline copied into a path; the shape is unchanged")
        r.select(.hand)
        QAInvariant.idle(r, "lifecycle")
        r.closeAll()
    }

    // MARK: - Conversions, one undo step each

    static func conversions() {
        let r = R()
        let app = AppModel.shared
        var st = SelfTest.baseState(320, 240)
        let px = PixelBuffer(width: 320, height: 240)
        st.layers.append(Layer.raster(name: "Pixels", buffer: px))
        let d = r.open(st, name: "conversions", active: st.layers.last?.id)
        let pixID = st.layers.last!.id
        app.shapeTool = ShapeToolSettings(); app.shapeTool.mode = .path
        app.foreground = RGBA(hex: "C0392B")!
        r.select(.hand); r.select(.ellipse)
        r.dragLine(CGPoint(x: 60, y: 50), CGPoint(x: 260, y: 190), steps: 3)
        guard let pid = d.state.paths.first?.id else { check(false, "path"); return }
        d.selectLayer(pixID)
        func oneStep(_ name: String, _ want: String, _ body: () -> Bool, _ verify: () -> Bool) {
            let s = QASnapshot(d)
            let ok = body()
            let st = TP.steps(d, s)
            check(ok && st == [want] && verify(), "\(name): one step \"\(want)\"", "ok \(ok), steps \(st)")
            d.undo()
            check(QAMeasure.fingerprint(d.state) == s.print, "\(name): undo restores the document")
            PathOps.selectPath(d, pid)
            d.selectLayer(pixID)
        }
        func alphaAt(_ x: Int, _ y: Int) -> UInt8 {
            guard let b = d.state.layer(pixID)?.raster?.buffer else { return 0 }
            return b.data.assumingMemoryBound(to: UInt8.self)[b.offset(x, y) + 3]
        }
        oneStep("Make Selection (feather, anti-alias)", "Make Selection", { PathOps.makeSelection(d, nil, .init(feather: 4, antialias: true, mode: .new)) }) {
            guard let s = d.state.selection else { return false }
            let p = s.data.assumingMemoryBound(to: UInt8.self)
            return p[s.offset(160, 120)] == 255 && p[s.offset(5, 5)] == 0 && p[s.offset(60, 120)] > 40 && p[s.offset(60, 120)] < 215
        }
        oneStep("Fill Path (50% opacity)", "Fill Path", { PathOps.fill(d, nil, .init(contents: .foreground, opacity: 50, feather: 0, antialias: true)) }) {
            let a = alphaAt(160, 120)
            return a > 118 && a < 138 && alphaAt(5, 5) == 0
        }
        app.brush = BrushSettings(size: 9, hardness: 1)
        oneStep("Stroke Path (Brush)", "Stroke Path", { PathOps.stroke(d, nil, .init(tool: .brush, simulatePressure: false)) }) {
            alphaAt(160, 50) > 200 && alphaAt(160, 120) == 0
        }
        oneStep("Stroke Path (Pencil, Simulate Pressure)", "Stroke Path", { PathOps.stroke(d, nil, .init(tool: .pencil, simulatePressure: true)) }) {
            alphaAt(160, 190) > 0 || alphaAt(160, 189) > 0 || alphaAt(160, 191) > 0
        }
        oneStep("Add Vector Mask", "Add Vector Mask", { PathOps.addVectorMask(d) }) { d.state.layer(pixID)?.vectorMask == d.state.paths.first?.path }
        oneStep("Make Shape", "New Shape Layer", { PathOps.makeShape(d) }) {
            d.state.allLayers.count == 3 && d.activeLayer?.shape?.path == d.state.paths.first?.path && d.state.paths.count == 1
        }
        // Make Work Path from a selection (tolerance), replacing the Work Path
        d.setSelection(SelectionOps.rectMask(CGRect(x: 40, y: 40, width: 100, height: 80), width: 320, height: 240), commitName: "Rect")
        oneStep("Make Work Path (tolerance 2)", "Make Work Path", { PathOps.makeWorkPath(d, tolerance: 2) }) {
            let wp = d.state.paths.first { $0.name == "Work Path" }?.path
            return d.state.paths.count == 1 && wp?.subpaths.count == 1 && (wp?.subpaths.first?.points.count ?? 0) <= 6
                && abs((wp?.bounds.width ?? 0) - 100) < 2
        }
        // the old AppActions entry points go through the same commands
        let s = QASnapshot(d)
        AppActions.fillPath(pid)
        check(TP.steps(d, s) == ["Fill Path"], "AppActions.fillPath → one Fill Path step")
        d.undo()
        // nothing to paint on: refused without a step
        let shapeL = Layer(name: "S", content: .shape(ShapeContent(geometry: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 10), cornerRadius: 0))))
        d.addLayer(shapeL); d.commit("Add Shape")
        let s2 = QASnapshot(d)
        PathOps.selectPath(d, pid)
        let ok = PathOps.fill(d) || PathOps.stroke(d)
        check(!ok && TP.steps(d, s2) == [] && QAMeasure.fingerprint(d.state) == s2.print, "Fill / Stroke Path on a shape layer are refused (no step, no change)")
        r.select(.hand)
        QAInvariant.idle(r, "conversions")
        r.closeAll()
    }

    // MARK: - Path Selection / Direct Selection / anchor tools on a work path next to a shape layer

    static func pathToolsOnWorkPaths() {
        let r = R()
        let app = AppModel.shared
        var st = SelfTest.baseState(400, 300)
        let shape = Layer(name: "Box", content: .shape(ShapeContent(geometry: .rectangle(CGRect(x: 220, y: 60, width: 140, height: 140), cornerRadius: 0))))
        st.layers.append(shape)
        let d = r.open(st, name: "pathtools", active: shape.id)
        app.shapeTool = ShapeToolSettings(); app.shapeTool.mode = .path
        r.select(.hand); r.select(.line)
        r.dragLine(CGPoint(x: 30, y: 250), CGPoint(x: 180, y: 120), steps: 3)
        d.selectLayer(shape.id)
        let wp0 = d.state.paths[0].path
        // Path Selection on the line path while the shape layer is active: the path is picked and moved
        r.select(.pathSelect)
        let s = QASnapshot(d)
        let m = CGPoint(x: 30, y: 250).lerp(CGPoint(x: 180, y: 120), 0.5)
        r.dragLine(m, m + CGPoint(x: 10, y: 15), steps: 3)
        let wp1 = d.state.paths[0].path
        check(wp1 == wp0.mapped { $0 + CGPoint(x: 10, y: 15) } && d.state.layer(shape.id)?.shape == shape.shape && TP.steps(d, s) == ["Move Path"],
              "Path Selection moves the work path (shape layer active and untouched)", "\(TP.steps(d, s))")
        check(VectorEditing.currentTarget(d) == .workPath(d.state.paths[0].id), "the picked work path is the path tools' target")
        // Direct Selection: drag one anchor
        r.select(.directSelect)
        let a0 = wp1.subpaths[0].points[0].anchor
        r.click(a0)
        r.dragLine(a0, a0 + CGPoint(x: 0, y: -20), steps: 2)
        check(d.state.paths[0].path.subpaths[0].points[0].anchor.distance(to: a0 + CGPoint(x: 0, y: -20)) < 0.5, "Direct Selection reshapes the work path")
        // Add Anchor Point on the work path
        r.select(.addAnchor)
        let p0 = d.state.paths[0].path.subpaths[0].points
        let mid = p0[0].anchor.lerp(p0[1].anchor, 0.5)
        r.click(mid)
        check(d.state.paths[0].path.subpaths[0].points.count == 3, "Add Anchor Point works on the work path")
        r.select(.deleteAnchor)
        r.click(d.state.paths[0].path.subpaths[0].points[1].anchor)
        check(d.state.paths[0].path.subpaths[0].points.count == 2, "Delete Anchor Point works on the work path")
        // selecting another layer gives the shape back to the path tools
        let bg = d.state.layers[0].id
        d.selectLayer(bg)
        _ = r.drawOverlay()                     // (the canvas redraws after a selection change in the Layers panel)
        d.selectLayer(shape.id)
        check(VectorEditing.currentTarget(d) == .layer(shape.id), "after selecting another layer and the shape again, the shape is the target")
        // shapes: Path Selection still moves a shape layer
        r.select(.pathSelect)
        PathOps.deselectPath(d)
        let s2 = QASnapshot(d)
        r.dragLine(CGPoint(x: 290, y: 130), CGPoint(x: 300, y: 140), steps: 2)
        check(TP.steps(d, s2) == ["Move Path"] && d.state.layer(shape.id)?.shape != shape.shape, "Path Selection still moves a shape layer")
        // path operations on the work path's components
        PathOps.selectPath(d, d.state.paths[0].id)
        VectorEditing.pickWorkPath(d, d.state.paths[0].id)
        app.shapeTool.mode = .path
        r.select(.rectangle)
        r.dragLine(CGPoint(x: 40, y: 40), CGPoint(x: 120, y: 100), steps: 2)
        check(d.state.paths[0].path.subpaths.count == 2, "a shape drawn in Path mode joins the active work path")
        VectorEditing.pickWorkPath(d, d.state.paths[0].id)
        PathSelectTool.selectedComponent = 1
        VectorEditing.setComponentOperation(.subtract)
        check(d.state.paths[0].path.subpaths[1].operation == .subtract && d.state.layer(shape.id) != nil, "path operations apply to the work path's components")
        PathSelectTool.selectedComponent = nil
        r.select(.hand)
        QAInvariant.idle(r, "path tools")
        r.closeAll()
    }

    // MARK: - .imagecrat and PSD

    static func persistence(_ out: URL) {
        var st = SelfTest.baseState(300, 200)
        let a = VectorPath.ellipse(CGRect(x: 20, y: 20, width: 120, height: 90))
        let b = VectorPath(subpaths: [Subpath(points: [PathPoint(CGPoint(x: 10, y: 180)), PathPoint(CGPoint(x: 290, y: 120))])])
        st.paths = [NamedPath(name: "Work Path", path: b), NamedPath(name: "Outline", path: a)]
        let d = Document(state: st, name: "paths-persist")
        let url = out.appendingPathComponent("paths2_roundtrip.imagecrat")
        do {
            try DocumentIO.saveNative(d, to: url)
            let back = try DocumentIO.load(url: url)
            check(back.state.paths == st.paths, ".imagecrat keeps paths (names, open and closed)")
        } catch { check(false, ".imagecrat round trip", "\(error)") }
        let psd = out.appendingPathComponent("paths2_export.psd")
        do {
            try PSDWriter.write(st, to: psd)
            let res = try PSDImporter.read(data: try Data(contentsOf: psd), name: "paths2_export.psd", baseURL: out)
            let names = res.state.paths.map(\.name)
            check(names.contains("Work Path") && names.contains("Outline"), "PSD export → import keeps the paths", "\(names)")
            if let o = res.state.paths.first(where: { $0.name == "Outline" }), let w = res.state.paths.first(where: { $0.name == "Work Path" }) {
                check(abs(o.path.bounds.width - 120) < 1 && abs(o.path.bounds.height - 90) < 1 && o.path.subpaths.first?.closed == true, "PSD: closed path geometry", "\(o.path.bounds)")
                check(w.path.subpaths.first?.closed == false && w.path.subpaths.first?.points.count == 2, "PSD: open path stays open with 2 anchors")
            }
            check(QAMeasure.diff(QAMeasure.composite(res.state), QAMeasure.composite(st)) < 0.5, "PSD composite has no path outlines")
        } catch { check(false, "PSD export of paths", "\(error)") }
    }
}
