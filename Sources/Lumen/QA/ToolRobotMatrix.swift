import AppKit
import CoreImage
import ImageCratCore

/// The generic matrix: every tool × active-layer kind × view transform × selection runs the same "poke" script
/// (click, 1-px drag, drags that start / end outside the canvas, a fast long drag, modifiers, double-click, multi-click +
/// Return, Esc mid-drag, tool switch) and must leave the document in a consistent, exactly undoable state.
enum QAScenarios {
    static var full: Bool { QA.tier == .full }
    static var quick: Bool { QA.tier == .quick }

    static func runAll() {
        let savedHistory = Document.maxHistory
        Document.maxHistory = 400
        let savedRemove = NeuralRemove.shared.modeOverride
        NeuralRemove.shared.modeOverride = .contentAware            // synchronous and model-free
        let savedFinder = ObjectSelectionSettings.shared.objectFinder
        ObjectSelectionSettings.shared.objectFinder = false
        let gen = GenAISettings.shared.data
        if gen.removeUsesCloud { GenAISettings.shared.data.removeUsesCloud = false }           // never touch the network
        if gen.cropGenerativeExpand { GenAISettings.shared.data.cropGenerativeExpand = false }
        defer {
            Document.maxHistory = savedHistory
            if NeuralRemove.shared.modeOverride != savedRemove { NeuralRemove.shared.modeOverride = savedRemove }
            if ObjectSelectionSettings.shared.objectFinder != savedFinder { ObjectSelectionSettings.shared.objectFinder = savedFinder }
            if gen.removeUsesCloud { GenAISettings.shared.data.removeUsesCloud = true }
            if gen.cropGenerativeExpand { GenAISettings.shared.data.cropGenerativeExpand = true }
        }
        for (name, section) in [("tool checks", QAToolChecks.run), ("pending sessions", QAPending.run), ("regressions", QARegressions.run),
                                ("tool matrix", matrix), ("tool options", options), ("selections", selections), ("tiny documents", tinyDocuments)] as [(String, () -> Void)] {
            let t0 = Date(), f0 = QA.failures, p0 = QA.passes
            section()
            print(String(format: "qatools: %@ — %d checks, %d failed (%.1fs)", name, QA.passes + QA.failures - p0 - f0, QA.failures - f0, Date().timeIntervalSince(t0)))
        }
    }

    // MARK: Tool classes

    /// Tools that run heavy synthesis (inpainting, ML): poked on fewer combinations.
    static let heavy: Set<ToolKind> = [.removeTool, .spotHealing, .healing, .contentAwareMove, .patch, .objectSelect, .magneticLasso, .artHistoryBrush]
    /// Tools that change the whole document (every layer, locked or not).
    static let documentLevel: Set<ToolKind> = [.crop, .perspectiveCrop, .artboard]
    /// Tools that only change the view.
    static let viewOnly: Set<ToolKind> = [.hand, .zoom, .rotateView, .eyedropper, .ruler]
    /// Tools that move / reshape layers (position lock applies).
    static let movers: Set<ToolKind> = [.move, .pathSelect, .directSelect, .addAnchor, .deleteAnchor, .convertPoint]

    static func resetToolSettings() {
        let app = AppModel.shared
        app.foreground = RGBA(hex: "D81B60")!; app.background = .white
        app.brush = BrushSettings(size: 18, hardness: 0.8)
        app.pencil = BrushSettings(size: 3, hardness: 1, spacing: 0.05, smoothing: 0)
        app.eraser = BrushSettings(size: 18, hardness: 0.7)
        app.clone = BrushSettings(size: 18, hardness: 0.6)
        app.healing = BrushSettings(size: 14, hardness: 0.6)
        app.historyBrush = BrushSettings(size: 18, hardness: 0.6)
        app.retouchBrush = BrushSettings(size: 18, hardness: 0.4)
        app.removeBrush = BrushSettings(size: 14, hardness: 0.8)
        app.colorReplaceBrush = BrushSettings(size: 18, hardness: 0.6)
        app.mixerBrushSettings = BrushSettings(size: 16, hardness: 0.5, spacing: 0.1)
        app.quickSelectSize = 12
        app.selection = SelectionToolSettings()
        app.shapeTool = ShapeToolSettings()
        app.textTool = TextToolSettings()
        app.textTool.fontSize = 22
        app.gradientTool = GradientToolSettings()
        app.bucket = BucketSettings()
        app.crop = CropSettings()
        app.penMode = .shape
        app.moveAutoSelect = false
        app.moveShowTransform = true
        app.eraserMode = .brush
        app.historyBrushSource = nil
        app.objectSelectMode = .rectangle
        let ts = ToolsSettings.shared
        ts.patternStampBrush = BrushSettings(size: 18, hardness: 0.6)
        ts.artHistoryBrush = BrushSettings(size: 5, hardness: 0.8, spacing: 1.2, smoothing: 0)
        ts.bgEraserBrush = BrushSettings(size: 18, hardness: 0.9, spacing: 0.15, smoothing: 0)
        ts.selectionBrush = BrushSettings(size: 16, hardness: 0.8, spacing: 0.1, smoothing: 0)
        ts.selectionBrushSubtract = false
        ts.cropStraighten = false
        ts.frameShape = .rectangle
        ts.symmetry = SymmetrySettings()
        ts.rulerLines = [:]
        CloneSources.shared.slots = Array(repeating: CloneSourceSlot(), count: 5)
        CloneSources.shared.active = 0
    }

    /// Types into the on-canvas text editor when one is open.
    static func typeIfEditing(_ r: ToolRobot, _ s: String = "Hi") {
        if let tv = r.window.firstResponder as? NSTextView { tv.insertText(s, replacementRange: tv.selectedRange()) }
    }

    /// Waits for asynchronous tool work (object selection, type-mask conversion).
    static func settle(_ r: ToolRobot, _ k: ToolKind) {
        if k == .objectSelect {
            var n = 0
            r.pump(0.02)
            while ObjectSelectionSettings.shared.busy != nil && n < 600 { r.pump(0.05); n += 1 }
            r.pump(0.02)
        } else if k == .typeMaskHorizontal || k == .typeMaskVertical {
            r.pump(0.01)
        }
    }

    // MARK: The poke script

    static func poke(_ r: ToolRobot, _ k: ToolKind, short: Bool = false) {
        guard let d = r.doc else { return }
        let W = CGFloat(d.state.width), H = CGFloat(d.state.height)
        // fractional coordinates: floor() of a point must not flip when it goes through the view transform and back
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (x + 0.37) * W / 240, y: (y + 0.41) * H / 160) }
        let A = P(95, 70), B = P(150, 100), C = P(200, 60)
        let out1 = CGPoint(x: -25, y: -18), out2 = CGPoint(x: W + 30, y: H + 22)
        r.mods = []
        r.select(k)
        r.move(A)
        if !short { r.drawOverlay() }
        // click without drag
        r.click(A); typeIfEditing(r); settle(r, k)
        // 1-px drag
        r.dragLine(A, CGPoint(x: A.x + 1, y: A.y), steps: 1); typeIfEditing(r); settle(r, k)
        // option-click (sets clone sources / samples colours / subtracts), then a normal drag
        r.mods = [.option]; r.click(C); r.mods = []; typeIfEditing(r); settle(r, k)
        r.dragLine(A, B, steps: 6) { i in if i == 3 { r.drawOverlay() } }
        typeIfEditing(r); settle(r, k)
        r.move(B)
        if !short { r.drawOverlay() }
        if !short {
            // start outside the canvas, end outside the canvas
            r.dragLine(out1, B, steps: 5); typeIfEditing(r); settle(r, k)
            r.dragLine(B, out2, steps: 5); typeIfEditing(r); settle(r, k)
            // very fast long drag: one move only
            r.down(P(12, 12)); r.drag(P(228, 148)); r.up(P(228, 148)); typeIfEditing(r); settle(r, k)
            // modifiers: shift-drag, modifier changing mid-drag, command-click
            r.mods = [.shift]; r.dragLine(P(40, 30), P(120, 110), steps: 4); r.mods = []; typeIfEditing(r); settle(r, k)
            r.down(P(50, 120)); r.drag(P(80, 110)); r.setMods([.shift]); r.drag(P(110, 100)); r.setMods([.option]); r.drag(P(140, 90))
            r.setMods([.command]); r.drag(P(160, 80)); r.setMods([]); r.up(P(170, 70)); typeIfEditing(r); settle(r, k)
            r.mods = [.command]; r.click(B); r.mods = []; typeIfEditing(r); settle(r, k)
            // double-click
            r.doubleClick(C); typeIfEditing(r); settle(r, k)
        }
        // multi-click then Return
        r.click(P(30, 20)); r.move(P(60, 25)); r.click(P(120, 24)); r.move(P(125, 60)); r.click(P(130, 90)); r.drawOverlay()
        typeIfEditing(r)
        r.key(ToolRobot.kReturn, "\r"); settle(r, k)
        // two clicks then Esc
        r.click(P(180, 120)); r.click(P(210, 140)); typeIfEditing(r); r.key(ToolRobot.kEsc, "\u{1b}"); settle(r, k)
        // Esc in the middle of a drag
        r.down(A); r.drag(B); r.key(ToolRobot.kEsc, "\u{1b}"); r.drag(C); r.up(C); typeIfEditing(r); settle(r, k)
        if !short {
            // arrow key (Delete is covered by its own checks: without a selection it deletes the layer)
            r.key(ToolRobot.kRight, "")
            // the same drag twice
            r.dragLine(P(70, 50), P(140, 95), steps: 3); typeIfEditing(r); settle(r, k)
            r.dragLine(P(70, 50), P(140, 95), steps: 3); typeIfEditing(r); settle(r, k)
            r.drawOverlay()
        }
        // confirm whatever is pending, then leave the tool
        r.key(ToolRobot.kReturn, "\r"); settle(r, k)
        r.key(ToolRobot.kEsc, "\u{1b}"); settle(r, k)
        r.select(k == .hand ? .zoom : .hand)
        settle(r, k)
        r.mods = []
    }

    /// Runs the poke script on a fixture and checks the generic invariants. Returns the resulting composite.
    @discardableResult
    static func run(_ r: ToolRobot, _ k: ToolKind, _ fx: QAFixture, view: QAView, selection: PixelBuffer? = nil, short: Bool = false, roundTrip: Bool = false,
                    configure: (() -> Void)? = nil) -> PixelBuffer? {
        resetToolSettings()
        configure?()
        var st = fx.state
        st.selection = selection
        let d = r.open(st, name: fx.name, view: view)
        fx.apply(to: d)
        defer { r.close(d) }
        let start = QASnapshot(d)
        let frozen = fx.frozen.compactMap { id in d.state.layer(id).map { (id, QAMeasure.layerPrint($0)) } }
        let pinned = fx.pinned.compactMap { id in d.state.layer(id).map { (id, QAMeasure.layerPrint($0)) } }
        let alpha0: [(UUID, PixelBuffer)] = fx.alphaLocked.compactMap { id in alphaMap(d.state, id).map { (id, $0) } }
        let selInside: PixelBuffer? = selection
        let activeRaster0: PixelBuffer? = selection != nil ? fx.active.flatMap { rasterOnCanvas(d.state, $0) } : nil
        QA.modalLog.removeAll()

        poke(r, k, short: short)

        let label = "\(k.rawValue)"
        QAInvariant.idle(r, label)
        if !documentLevel.contains(k) {
            for (id, p) in frozen {
                guard let l = d.state.layer(id) else { QA.check(false, "\(label): locked / hidden layer still exists"); continue }
                QA.check(QAMeasure.layerPrint(l) == p, "\(label): locked / hidden layer is not modified")
            }
        }
        if movers.contains(k) {
            for (id, p) in pinned {
                guard let l = d.state.layer(id) else { continue }
                QA.check(QAMeasure.layerPrint(l) == p, "\(label): position-locked layer is not moved")
            }
        }
        // (Photoshop: the Background Eraser overrides the transparency lock)
        if !documentLevel.contains(k), k != .move, k != .backgroundEraser {
            for (id, a0) in alpha0 {
                guard let a1 = alphaMap(d.state, id) else { continue }
                let n = QAMeasure.changed(a0, a1, mask: nil, inside: false, tol: 1)
                QA.check(n == 0, "\(label): transparency-locked layer keeps its alpha", "\(n) px changed")
            }
        }
        // pixels outside the selection are untouched by painting tools (the selection itself may have been changed by
        // selection tools, so this is only checked while it is still the original one)
        if let sel = selInside, let before = activeRaster0, let id = fx.active, k.isPainting || [.gradient, .paintBucket, .magicEraser].contains(k),
           let after = rasterOnCanvas(d.state, id), d.state.width == st.width, d.state.height == st.height {
            let n = QAMeasure.changed(before, after, mask: sel, inside: false, tol: 2)
            QA.check(n == 0, "\(label): pixels outside the selection are unchanged", "\(n) px changed")
        }
        if viewOnly.contains(k) {
            QA.check(d.historyIndex == start.historyIndex && QAMeasure.fingerprint(d.state) == start.print, "\(label): a view tool leaves the document alone",
                     "history \(d.history.map(\.name).suffix(3))")
        }
        let result = QAMeasure.composite(d.state)
        if let a = d.activeLayerID, !documentLevel.contains(k) { QAInvariant.handlesMatchContent(d, a, label) }
        if roundTrip { QAInvariant.roundTrip(d, label) }
        QAInvariant.undoRedo(r, from: start, label)
        return result
    }

    /// Alpha of a raster layer over the canvas (gray).
    static func alphaMap(_ st: DocumentState, _ id: UUID) -> PixelBuffer? {
        guard let rc = st.layer(id)?.raster else { return nil }
        let out = PixelBuffer(width: st.width, height: st.height, format: .gray)
        let o = out.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<st.height { for x in 0..<st.width { o[y * out.bytesPerRow + x] = rc.buffer.alpha(x - rc.origin.x, y - rc.origin.y) } }
        return out
    }

    /// A raster layer's pixels over the canvas.
    static func rasterOnCanvas(_ st: DocumentState, _ id: UUID) -> PixelBuffer? {
        guard let rc = st.layer(id)?.raster else { return nil }
        let out = PixelBuffer(width: st.width, height: st.height)
        out.copyPixels(from: rc.buffer, at: rc.origin)
        return out
    }

    // MARK: Matrices

    /// Quick pass: every tool with the long script on a pixel layer, the short one on the main layer kinds, and once in a
    /// rotated view. Standard: every tool on every distinct layer kind at 100 % and in a rotated, zoomed, offset view on a
    /// subset. Full (`LUMEN_QA_FULL=1`): the long script everywhere, every fixture, all four views.
    static func matrix() {
        let fixtures = QAFixtures.all(QA.out)
        let everything = Set(fixtures.map(\.name))
        // (near-duplicates of other kinds — linked ≈ smart, pixel lock ≈ full lock … — are left to the full pass and to
        // their dedicated tool checks)
        let standardKinds: Set<String> = ["raster", "text", "shape", "smart", "fill", "adjustment", "group", "artboard", "frame", "hidden", "locked-all",
                                          "locked-transparency", "mask-target", "mask-content", "offset", "empty", "no-layer", "multi"]
        let quickKinds: Set<String> = ["raster", "text", "shape", "smart", "locked-all", "hidden", "mask-target", "no-layer"]
        let kinds = full ? everything : (quick ? quickKinds : standardKinds)
        let viewFixtures: Set<String> = full ? everything : (quick ? ["raster"] : ["raster", "text", "smart", "mask-target", "offset"])
        let longFixtures: Set<String> = full ? everything : (quick ? ["raster"] : ["raster", "text"])
        let heavyFixtures: Set<String> = ["raster", "text", "locked-all", "hidden", "mask-target", "offset", "no-layer"]
        let shortRef = QAView(name: "z1s", zoom: 1, offset: QAView.identity.offset)
        let otherViews: [QAView] = full ? Array(QAView.all.dropFirst()) : [.rotated]
        for k in ToolKind.allCases {
            let r = ToolRobot()
            var reference: [String: PixelBuffer] = [:]
            let t0 = Date()
            // long script
            for fx in fixtures where longFixtures.contains(fx.name) {
                if heavy.contains(k) && !full && fx.name != "raster" { continue }
                QA.scenario("matrix/\(k.rawValue)/\(fx.name)/z1") { run(r, k, fx, view: .identity, short: false, roundTrip: fx.name == "raster") }
            }
            // short script at 100 %: the layer kinds; the results are the reference for the other views
            for fx in fixtures where kinds.contains(fx.name) || viewFixtures.contains(fx.name) {
                if heavy.contains(k) && !full && !(heavyFixtures.contains(fx.name) && !quick) && fx.name != "raster" { continue }
                if k == .objectSelect && fx.name != "raster" { continue }
                QA.scenario("matrix/\(k.rawValue)/\(fx.name)/z1s") { reference[fx.name] = run(r, k, fx, view: shortRef, short: true) }
            }
            for v in otherViews {
                for fx in fixtures where viewFixtures.contains(fx.name) {
                    if heavy.contains(k) && !full && fx.name != "raster" { continue }
                    if k == .objectSelect && fx.name != "raster" { continue }
                    QA.scenario("matrix/\(k.rawValue)/\(fx.name)/\(v.name)") {
                        // The same document-space gestures must give the same document at every zoom / rotation.
                        guard let res = run(r, k, fx, view: v, short: true), let ref = reference[fx.name], !viewDependent.contains(k) else { return }
                        let dd = QAMeasure.diff(res, ref)
                        QA.check(dd < 1.0, "\(k.rawValue): result does not depend on the view transform", String(format: "diff %.2f vs zoom 100%%", dd))
                    }
                }
            }
            if QA.verbose { QA.info(String(format: "matrix %@: %.1fs", k.rawValue, Date().timeIntervalSince(t0))) }
            r.closeAll()
        }
    }

    /// Tools whose result legitimately depends on the zoom (screen-space hit radii, screen-sized tips, new canvas fit…).
    /// (Move: whether a click lands on a bounding-box handle depends on the zoom; its exact behaviour at every view is
    /// covered by the tool checks.)
    /// Red Eye: a click searches a screen-sized region. Anchor tools: hit radii are in screen pixels.
    static let viewDependent: Set<ToolKind> = [.hand, .zoom, .rotateView, .objectSelect, .move, .redEye, .addAnchor, .deleteAnchor, .convertPoint, .pathSelect, .directSelect]

    static func selections() {
        let all = QAFixtures.all(QA.out)
        let variants = QAFixtures.selections()
        for k in ToolKind.allCases {
            let inpainting = heavy.contains(k)
            if inpainting && k != .spotHealing && k != .patch && k != .contentAwareMove { continue }
            let pixelTool = k.isPainting || [.move, .gradient, .paintBucket, .magicEraser, .crop].contains(k)
            let r = ToolRobot()
            for fx0 in all where ["raster", "mask-target", "locked-transparency", "text", "offset"].contains(fx0.name) {
                if fx0.name != "raster" && (!pixelTool || inpainting) { continue }
                for (sname, make, quick) in variants {
                    // quick: every tool with a plain selection. Standard: also quick mask; pixel tools also feathered /
                    // inverted / outside the layer, and on a mask and a transparency-locked layer. Full: everything.
                    if !full {
                        if QAScenarios.quick && (sname != "rect" || fx0.name != "raster") { continue }
                        if (!pixelTool || inpainting) && !["rect", "quickmask"].contains(sname) { continue }
                        if fx0.name != "raster" && sname != "rect" { continue }
                        if ["text", "offset"].contains(fx0.name) { continue }
                    }
                    var fx = fx0
                    fx.quickMask = quick
                    QA.scenario("selection/\(k.rawValue)/\(fx.name)/\(sname)") {
                        run(r, k, fx, view: .identity, selection: make(fx.state), short: true)
                    }
                }
            }
            r.closeAll()
        }
    }

    /// Every tool option that changes what a gesture does: the poke script with the option set.
    static func options() {
        if quick { return }
        let app = AppModel.shared, ts = ToolsSettings.shared
        var list: [(ToolKind, String, String, () -> Void)] = []       // tool, variant, fixture, configure
        func add(_ k: ToolKind, _ name: String, _ fixture: String = "raster", _ c: @escaping () -> Void) { list.append((k, name, fixture, c)) }
        add(.brush, "airbrush") { app.brush.airbrush = true }
        add(.brush, "multiply-half") { app.brush.blendMode = .multiply; app.brush.opacity = 0.5; app.brush.flow = 0.5 }
        add(.brush, "wide-spacing-soft") { app.brush.spacing = 1.5; app.brush.hardness = 0; app.brush.pressureSize = false; app.brush.smoothing = 0.8 }
        add(.brush, "huge") { app.brush.size = 900 }
        add(.brush, "one-pixel") { app.brush.size = 1 }
        for t in SymmetryType.allCases { add(.brush, "symmetry-\(t.rawValue)") { ts.symmetry = SymmetrySettings(enabled: true, type: t, segments: 5) } }
        add(.eraser, "symmetry") { ts.symmetry = SymmetrySettings(enabled: true, type: .dualAxis, segments: 4) }
        for m in EraserMode.allCases { add(.eraser, "mode-\(m.rawValue)") { app.eraserMode = m } }
        add(.eraser, "mode-Block-mask", "mask-target") { app.eraserMode = .block }
        add(.cloneStamp, "sample-all-unaligned") { app.cloneSampleAll = true; app.cloneAligned = false }
        add(.cloneStamp, "transformed-source") { CloneSources.shared.slots[0].scaleW = 150; CloneSources.shared.slots[0].rotation = 30; CloneSources.shared.slots[0].flipH = true }
        add(.marqueeRect, "feather-ratio") { app.selection.feather = 6; app.selection.fixedRatio = true; app.selection.ratioW = 2 }
        add(.marqueeEllipse, "no-antialias-add") { app.selection.antialias = false; app.selection.combine = .add }
        add(.lasso, "intersect-feather") { app.selection.combine = .intersect; app.selection.feather = 3 }
        add(.magicWand, "all-layers-noncontiguous") { app.selection.contiguous = false; app.selection.sampleAllLayers = true; app.selection.tolerance = 80 }
        add(.magicWand, "subtract") { app.selection.combine = .subtract }
        add(.quickSelect, "large") { app.quickSelectSize = 120 }
        add(.paintBucket, "pattern-all-layers") { app.bucket.usePattern = true; app.bucket.sampleAllLayers = true; app.bucket.contiguous = false }
        add(.paintBucket, "multiply", "locked-transparency") { app.bucket.blendMode = .multiply; app.bucket.opacity = 0.5 }
        for t in GradientType.allCases { add(.gradient, "type-\(t.rawValue)") { app.gradientTool.type = t; app.gradientTool.reverse = true; app.gradientTool.opacity = 0.7 } }
        add(.gradient, "difference-mask", "mask-target") { app.gradientTool.blendMode = .difference }
        add(.smudge, "finger-painting") { app.retouch.fingerPainting = true; app.retouch.strength = 1 }
        for rg in RetouchRange.allCases { add(.dodge, "range-\(rg.rawValue)") { app.retouch.range = rg; app.retouch.exposure = 1 }; add(.burn, "range-\(rg.rawValue)") { app.retouch.range = rg } }
        add(.sponge, "saturate") { app.retouch.spongeSaturate = true }
        add(.blur, "on-mask", "mask-target") { app.retouch.strength = 1 }
        for op in PathOperation.allCases {
            add(.rectangle, "op-\(op.rawValue)", "shape") { app.shapeTool.operation = op }
            add(.ellipse, "path-op-\(op.rawValue)") { app.shapeTool.mode = .path; app.shapeTool.operation = op }
        }
        add(.rectangle, "stroke-only") { app.shapeTool.fill = .none; app.shapeTool.stroke = .color(.black); app.shapeTool.strokeWidth = 5 }
        add(.rectangle, "pixels-on-mask", "mask-target") { app.shapeTool.mode = .pixels }
        add(.polygon, "triangle-sides") { app.shapeTool.sides = 3 }
        add(.customShape, "star") { app.shapeTool.sides = 7; app.shapeTool.starRatio = 0.3 }
        add(.line, "arrows-pixels") { app.shapeTool.arrowEnd = true; ts.arrowStart = true; app.shapeTool.mode = .pixels; app.shapeTool.lineWeight = 9 }
        add(.triangle, "rounded-path") { ts.triangleRadius = 12; app.shapeTool.mode = .path }
        add(.triangle, "pixels") { app.shapeTool.mode = .pixels }
        add(.pen, "path-mode") { app.penMode = .path }
        add(.pen, "on-shape", "shape") { }
        add(.freeformPen, "path-mode") { app.penMode = .path }
        add(.curvaturePen, "path-mode") { app.penMode = .path }
        add(.text, "centered-large") { app.textTool.alignment = .center; app.textTool.fontSize = 90 }
        add(.text, "on-shape", "shape") { app.textTool.alignment = .right }
        add(.verticalText, "on-shape", "shape") { }
        add(.crop, "ratio-delete") { app.crop.ratioW = 1; app.crop.ratioH = 1; app.crop.deleteCropped = true }
        add(.crop, "straighten-mode") { ts.cropStraighten = true }
        add(.perspectiveCrop, "delete-cropped") { app.crop.deleteCropped = true }
        for lim in EraserLimits.allCases { for smp in ColorSampling.allCases {
            add(.backgroundEraser, "\(lim.rawValue)-\(smp.rawValue)") { ts.bgLimits = lim; ts.bgSampling = smp; ts.bgProtectForeground = true; ts.bgTolerance = 80 }
        } }
        add(.patternStamp, "impressionist-unaligned") { ts.patternImpressionist = true; ts.patternAligned = false }
        for st in ArtHistoryStyle.allCases { add(.artHistoryBrush, "style-\(st.rawValue)") { ts.artStyle = st; ts.artTolerance = 20 } }
        for m in [BlendMode.hue, .saturation, .color, .luminosity] { for smp in ColorSampling.allCases {
            add(.colorReplacement, "\(m.rawValue)-\(smp.rawValue)") { app.colorReplace.mode = m; app.colorReplace.sampling = smp; app.colorReplace.tolerance = 90 }
        } }
        add(.mixerBrush, "sample-all-dry") { app.mixer.sampleAll = true; app.mixer.wet = 0; app.mixer.loadEachStroke = false; app.mixer.cleanEachStroke = false }
        add(.selectionBrush, "subtract") { ts.selectionBrushSubtract = true }
        add(.frame, "ellipse-over-smart", "smart") { ts.frameShape = .ellipse }
        add(.frame, "over-raster") { }
        add(.move, "auto-select", "multi") { app.moveAutoSelect = true; app.moveShowTransform = false }
        add(.redEye, "on-background", "no-layer") { app.redEyePupil = 100; app.redEyeDarken = 100 }
        add(.patch, "destination") { app.patchMode = .destination }
        add(.contentAwareMove, "extend") { app.contentAwareMoveMode = .extend }
        add(.historyBrush, "after-edits") { app.historyBrushSource = 0 }
        let fixtures = QAFixtures.all(QA.out)
        let r = ToolRobot()
        for (k, name, fxName, configure) in list {
            guard let fx = fixtures.first(where: { $0.name == fxName }) else { continue }
            QA.scenario("options/\(k.rawValue)/\(name)") {
                run(r, k, fx, view: .rotated, short: !full, configure: configure)
            }
        }
        r.closeAll()
    }

    /// 1×1, 3×2 and a wide non-square document with a layer far off the canvas.
    static func tinyDocuments() {
        func doc(_ w: Int, _ h: Int, _ name: String) -> QAFixture {
            var st = DocumentState(width: w, height: h)
            let bg = PixelBuffer(width: w, height: h)
            bg.context.setFillColor(RGBA(hex: "DDDDDD")!.cgColor); bg.context.fill(CGRect(x: 0, y: 0, width: w, height: h)); bg.markDirty()
            let top = PixelBuffer(width: w, height: h)
            top.context.setFillColor(RGBA(hex: "2E86AB")!.cgColor); top.context.fill(CGRect(x: 0, y: 0, width: max(1, w / 2), height: h)); top.markDirty()
            let l = Layer.raster(name: "Layer 1", buffer: top)
            st.layers = [Layer.raster(name: "Background", buffer: bg), l]
            return QAFixture(name: name, state: st, active: l.id)
        }
        // a wide document whose layer sits far outside the canvas
        var far = doc(300, 40, "wide-far")
        far.state.updateLayer(far.active!) { $0.translate(dx: full ? 5000 : 700, dy: full ? -3000 : -500) }
        let list = quick ? [doc(1, 1, "1x1")] : [doc(1, 1, "1x1"), doc(3, 2, "3x2"), far]
        let views = [QAView(name: "z16", zoom: 16, offset: CGPoint(x: 300, y: 200)), QAView(name: "z1", zoom: 1, offset: CGPoint(x: 300, y: 200))]
        for k in ToolKind.allCases {
            if k == .objectSelect { continue }
            let r = ToolRobot()
            for fx in list {
                QA.scenario("tiny/\(k.rawValue)/\(fx.name)") {
                    run(r, k, fx, view: fx.name == "wide-far" ? views[1] : views[0], short: true)
                }
            }
            r.closeAll()
        }
    }
}
