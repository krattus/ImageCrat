import AppKit
import SwiftUI
import ImageCratCore

/// Artboards, round 3: rulers / read-outs measured from the active artboard, View ▸ Show ▸ Artboard Names, Fit on
/// Screen in artboard documents, Auto-size Canvas on all four sides (no on-screen jump, one undo step, stored
/// geometry), nesting rules (clipped layers, ⌥-drag copies, Group Layers, auto-nest preference), Preferences ▸
/// Artboards and the grouped Layer ▸ New ▸ Artboard menu. `LUMEN_SELFTEST_ONLY=artboards3 Lumen --selftest <dir>`
///
/// Every preference change goes to a throw-away defaults suite (the user's settings are never read or written).
enum ArtboardsSelfTest3 {
    static func register() { FeatureModules.selfTests.append(("artboards3", { run($0) })) }

    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") artboards3: \(name)\(d.isEmpty ? "" : " — " + d)")
        fflush(stdout)
    }

    static let suite = "LumenArtboards3SelfTest"

    static func run(_ out: URL) {
        passes = 0; failures = 0
        let dir = out.appendingPathComponent("artboards3")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppModel.shared
        let saved = (canvas: AppActions.canvas, hook: app.toolChanged, tool: app.tool, docs: app.documents, active: app.activeDocumentID,
                     anim: ZoomAnimator.enabled, dialog: app.dialog, status: app.statusMessage, cursor: app.cursorDocPoint)
        let userPrefs = UserDefaults.standard.data(forKey: ArtboardSettings.key)
        defer {
            ArtboardCanvas.renaming?.finish(commit: false)
            ZoomAnimator.enabled = saved.anim
            AppActions.canvas = saved.canvas; app.toolChanged = saved.hook; app.tool = saved.tool
            app.documents = saved.docs; app.activeDocumentID = saved.active; app.dialog = saved.dialog; app.statusMessage = saved.status
            app.cursorDocPoint = saved.cursor
        }
        ZoomAnimator.enabled = false
        ArtboardSettings.shared.usingTemporaryDefaults(suite) {
            preferences()
            rulersAndReadouts(dir)
            namesAndAppearance(dir)
            fitOnScreen()
            autoSizeCanvas()
            storedGeometry()
            autoSizeOff()
            nesting()
            groupRules()
            newArtboardMenu(dir)
            presets()
            snapshots(dir)
        }
        check(UserDefaults.standard.data(forKey: ArtboardSettings.key) == userPrefs, "the user's own artboard preferences were not touched")
        print("artboards3: \(passes) passed, \(failures) failed")
    }

    // MARK: Helpers

    static var prefs: ArtboardPrefs {
        get { ArtboardSettings.shared.prefs }
        set { ArtboardSettings.shared.prefs = newValue }
    }

    static func use(_ d: Document) { ArtboardsSelfTest.use(d) }
    static func shape(_ name: String, _ r: CGRect, _ hex: String) -> Layer { ArtboardsSelfTest.shape(name, r, hex) }
    static func id(_ d: Document, _ name: String) -> UUID { ArtboardsSelfTest.id(d, name)! }
    static func parentName(_ d: Document, _ name: String) -> String? { ArtboardsSelfTest.parentName(d, name) }
    static func rect(_ d: Document, _ name: String) -> CGRect? { ArtboardsSelfTest.rect(d, name) }
    static func bounds(_ d: Document, _ name: String) -> CGRect? { ArtboardsSelfTest.bounds(d, name) }
    static func near(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = 0.51) -> Bool { abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol }

    /// Artboard "A" (100,50 300×400) with a blue shape, "B" (500,50 300×400) with a pink one, a loose green shape
    /// below them; canvas 1000 × 600 (margins left as they are: the state is built, not committed).
    static func doc() -> Document {
        var st = DocumentState(width: 1000, height: 600)
        let a = ArtboardOps.makeLayer("A", rect: CGRect(x: 100, y: 50, width: 300, height: 400), background: .white,
                                      children: [shape("Blue", CGRect(x: 140, y: 90, width: 120, height: 80), "3A86FF")])
        let b = ArtboardOps.makeLayer("B", rect: CGRect(x: 500, y: 50, width: 300, height: 400), background: RGBA(hex: "FFF3B0")!,
                                      children: [shape("Pink", CGRect(x: 560, y: 110, width: 100, height: 100), "F72585")])
        st.layers = [a, b, shape("Loose", CGRect(x: 600, y: 480, width: 100, height: 60), "2DC653")]
        let d = Document(state: st, name: "artboards3")
        use(d)
        return d
    }

    static func canvas(_ d: Document, size: CGSize = CGSize(width: 900, height: 600)) -> CanvasView { ArtboardsSelfTest.canvas(d, size: size) }

    /// Is doc rect `r` fitted (centred, touching the margin on one axis) in the canvas' content area?
    static func fitted(_ c: CanvasView, _ r: CGRect) -> (Bool, String) {
        let v = c.docToView(r), a = c.contentArea, m = CanvasView.fitMargin
        let centred = abs(v.midX - a.midX) < 1 && abs(v.midY - a.midY) < 1
        let touches = abs(v.width - (a.width - 2 * m)) < 1.5 || abs(v.height - (a.height - 2 * m)) < 1.5
        let inside = v.width <= a.width - 2 * m + 1.5 && v.height <= a.height - 2 * m + 1.5
        return (centred && touches && inside, "view \(v) in \(a)")
    }

    // MARK: 1. Preferences (temporary defaults domain)

    static func preferences() {
        guard let ud = UserDefaults(suiteName: suite) else { check(false, "temporary defaults suite"); return }
        check(prefs == ArtboardPrefs() && prefs.showNames && prefs.autoSizeCanvas && prefs.autoNest && prefs.border == .dropShadow && prefs.matte == .standard,
              "defaults: names shown, Auto-size Canvas on, auto-nest on, drop-shadow border, default pasteboard colour")
        var p = ArtboardPrefs()
        p.showNames = false; p.border = .line; p.matte = .custom; p.customMatte = RGBA(hex: "335577")!; p.autoSizeCanvas = false; p.autoNest = false
        prefs = p
        check(ArtboardSettings.read(ud) == p, "every artboard preference is saved (in the temporary domain)")
        // a fresh read (as at the next launch) gets them back
        var back = ArtboardPrefs()
        ArtboardSettings.shared.using(ud) { back = ArtboardSettings.shared.prefs }
        check(back == p, "and read back as at the next launch")
        // a file written before some keys existed
        let old = #"{"showNames":false}"#.data(using: .utf8)!
        let dec = try? JSONDecoder().decode(ArtboardPrefs.self, from: old)
        check(dec?.showNames == false && dec?.autoSizeCanvas == true && dec?.border == .dropShadow, "missing keys fall back to the defaults")
        check(p.matteColor == RGBA(hex: "335577")! && ArtboardPrefs().matteColor == nil, "pasteboard colour: Custom gives its colour, Default the workspace grey")
        prefs = ArtboardPrefs()
        check(ArtboardSettings.read(ud) == ArtboardPrefs(), "back to the defaults")
        check(Workflow2PrefsState.sections.contains("Artboards"), "Preferences has an Artboards section")
    }

    // MARK: 2. Rulers, Info panel, status bar, Properties, transform read-outs

    static func rulersAndReadouts(_ dir: URL) {
        // a normal document: everything from the canvas corner
        let n = Document.newBlank(width: 400, height: 300, background: .white, name: "plain")
        use(n)
        check(ArtboardCoords.rulerOrigin(n) == .zero && ArtboardCoords.display(CGPoint(x: 50, y: 60), n) == CGPoint(x: 50, y: 60), "normal document: rulers start at the canvas corner")
        check(StatusChips.cursor(ArtboardCoords.display(CGPoint(x: 50, y: 60), n)).full == "X 50  Y 60 px", "normal document: status bar shows document pixels")

        let d = doc()
        let pink = id(d, "Pink"), a = id(d, "A"), b = id(d, "B"), loose = id(d, "Loose")
        // a layer inside B: zero point at B's top-left corner
        d.selectLayer(pink)
        check(ArtboardCoords.rulerOrigin(d) == CGPoint(x: 500, y: 50), "a layer in an artboard: the rulers' zero point is that artboard's corner", "\(ArtboardCoords.rulerOrigin(d))")
        check(ArtboardCoords.rulerSpan(d) == CGSize(width: 300, height: 400), "percentages refer to the artboard")
        let p = CGPoint(x: 550, y: 80)
        check(ArtboardCoords.display(p, d) == CGPoint(x: 50, y: 30), "Info / status position is measured from the artboard", "\(ArtboardCoords.display(p, d))")
        check(StatusChips.cursor(ArtboardCoords.display(p, d)).full == "X 50  Y 30 px", "status bar: X 50  Y 30 inside B")
        // Info panel (rendered, read through accessibility)
        AppModel.shared.cursorDocPoint = p
        let w = UIFixesSelfTest.host(InfoPanel(), CGSize(width: 280, height: 220))
        FuzzAX.enable()
        let labels = FuzzAX.tree(w.contentView!).map(\.label)
        check(labels.contains("X: 50") && labels.contains("Y: 30"), "Info panel: X: 50  Y: 30 inside B", labels.filter { $0.hasPrefix("X:") || $0.hasPrefix("Y:") }.joined(separator: ", "))
        UIFixesSelfTest.snapshot(w, "01_info_panel_artboard", dir)
        UIFixesSelfTest.close(w)
        // the artboard itself selected: its own corner
        d.selectLayer(a)
        check(ArtboardCoords.rulerOrigin(d) == CGPoint(x: 100, y: 50), "the selected artboard's corner when an artboard is selected")
        // a layer outside the artboards, or nothing selected: the canvas corner
        d.selectLayer(loose)
        check(ArtboardCoords.rulerOrigin(d) == .zero && ArtboardCoords.display(p, d) == p, "a layer outside the artboards: the canvas corner")
        d.activeLayerID = nil; d.selectedLayerIDs = []
        check(ArtboardCoords.rulerOrigin(d) == .zero, "nothing selected: the canvas corner")
        AppModel.shared.cursorDocPoint = nil
        // Properties: layer X / Y from its artboard; artboard X / Y in document coordinates
        check(ArtboardCoords.layerOrigin(pink, d.state) == CGPoint(x: 500, y: 50) && ArtboardCoords.layerOrigin(loose, d.state) == .zero && ArtboardCoords.layerOrigin(b, d.state) == .zero,
              "Properties: a layer's X / Y are measured from its artboard (loose layers and artboards: the document)")
        d.selectLayer(pink)
        var shown: Double = -1
        if let s = d.state.layer(pink)?.shape {
            let o = ArtboardCoords.layerOrigin(pink, d.state)
            shown = Double(s.path.bounds.minX - o.x)
            // typing X = 10 (the field's setter) moves the shape to the artboard's left edge + 10
            var t = s
            t.transform = t.transform.concatenating(CGAffineTransform(translationX: 10 + o.x - s.path.bounds.minX, y: 0))
            check(abs(t.path.bounds.minX - 510) < 0.01, "Properties X = 10 on a shape in B puts it 10 px from B's left edge", "\(t.path.bounds.minX)")
        }
        check(shown == 60, "Properties shows the shape at X 60 in B (document X 560)", "\(shown)")
        // Transform (options bar read-out) and the Ruler tool: from the active artboard
        if let ts = TransformSession(doc: d, layerIDs: [pink], useSelection: false) {
            check(ts.info.hasPrefix("X: 110  Y: 110"), "Free Transform read-out (centre) is measured from the artboard", ts.info)
        } else { check(false, "transform session") }
        ToolsSettings.shared.rulerLines[d.id] = (CGPoint(x: 520, y: 70), CGPoint(x: 620, y: 70))
        check(RulerTool.info(d).hasPrefix("X: 20  Y: 20"), "Ruler tool X / Y are measured from the artboard", RulerTool.info(d))
        ToolsSettings.shared.rulerLines[d.id] = nil
        // rulers as drawn
        let c = canvas(d)
        d.showRulers = true
        c.fitOnScreen()
        d.selectLayer(pink)
        ArtboardsSelfTest.writePNG(ArtboardsSelfTest.shot(c).1, dir.appendingPathComponent("02_rulers_origin_artboard_B.png"))
        d.selectLayer(loose)
        ArtboardsSelfTest.writePNG(ArtboardsSelfTest.shot(c).1, dir.appendingPathComponent("03_rulers_origin_canvas.png"))
        // a guide dragged out is stored in document pixels (not artboard coordinates)
        d.selectLayer(pink)
        d.state.guides.append(Guide(isVertical: true, position: 550))
        d.commit("New Guide")
        check(d.state.guides.last?.position == 550 + Double(ArtboardsSelfTest3.lastShift(d).x), "guides stay in document pixels (moved only by the canvas trim)", "\(d.state.guides.map(\.position))")
        c.document = nil
    }

    /// The canvas shift the last step made (auto-size), x / y.
    static func lastShift(_ d: Document) -> CGPoint { d.history.last.flatMap { ArtboardOps.stepShift[$0.id] } ?? .zero }

    // MARK: 3. View ▸ Show ▸ Artboard Names, border, pasteboard colour

    static func namesAndAppearance(_ dir: URL) {
        let item = MenuRegistry.items(for: "View").first { $0.title == "Artboard Names" }
        check(item?.submenu == "Show" && item?.checked?() == true, "View ▸ Show ▸ Artboard Names, checked by default")
        let d = doc()
        let c = canvas(d)
        d.selectLayer(id(d, "Pink"))
        guard let lb = d.state.layer(id(d, "B")), let lr = ArtboardCanvas.labelRect(lb, canvas: c) else { check(false, "label rect"); return }
        let hit = CGPoint(x: lr.minX + 6, y: lr.midY)
        check(ArtboardCanvas.labelHit(hit, canvas: c)?.id == lb.id, "names shown: a name can be clicked")
        let img1 = ArtboardsSelfTest.shot(c).1
        item?.action()
        check(!prefs.showNames && item?.checked?() == false, "the menu item turns the names off")
        check(ArtboardSettings.read(UserDefaults(suiteName: suite)!).showNames == false, "the choice is remembered (per user)")
        check(ArtboardCanvas.labelHit(hit, canvas: c) == nil, "hidden names can't be clicked or dragged")
        AppModel.shared.tool = .move
        check(ArtboardCanvas.toolForLabelClick(ArtboardsSelfTest.toolEvent(c, view: hit), canvas: c) == nil, "a click where the name was goes to the Move tool")
        let (_, img2) = ArtboardsSelfTest.shot(c)
        ArtboardsSelfTest.writePNG(img1, dir.appendingPathComponent("04_names_on.png"))
        ArtboardsSelfTest.writePNG(img2, dir.appendingPathComponent("05_names_off.png"))
        if let i1 = img1, let i2 = img2 {
            let b1 = PixelBuffer(cgImage: i1), b2 = PixelBuffer(cgImage: i2)
            var diff = 0
            for y in stride(from: Int(lr.minY * 2), to: Int(lr.maxY * 2), by: 1) { for x in stride(from: Int(lr.minX * 2), to: Int(min(lr.maxX, lr.minX + 60) * 2), by: 1) {
                let p = b1.pixel(x, y), q = b2.pixel(x, y)
                if abs(Int(p.0) - Int(q.0)) > 40 { diff += 1 }
            } }
            check(diff > 20, "the name is drawn with names on and gone with names off", "\(diff) differing pixels")
        }
        item?.action()
        check(prefs.showNames, "and back on")
        // border: drop shadow / line / none; pasteboard colour
        let edge = CGPoint(x: 803, y: 250)   // just right of B
        func px(_ p: CGPoint) -> (UInt8, UInt8, UInt8, UInt8) { ArtboardsSelfTest.framePixel(ArtboardsSelfTest.shot(c).0, c, p) }
        let shadow = px(edge)
        prefs.border = .none
        let plain = px(edge)
        check(Int(shadow.0) < Int(plain.0) - 3 && ArtboardsSelfTest.near(plain, ArtboardsSelfTest.pasteboard), "Border: Drop Shadow darkens the pasteboard next to the page, None doesn't",
              "\(ArtboardsSelfTest.fmt(shadow)) vs \(ArtboardsSelfTest.fmt(plain))")
        prefs.border = .line
        ArtboardsSelfTest.writePNG(ArtboardsSelfTest.shot(c).1, dir.appendingPathComponent("06_border_line.png"))
        prefs.border = .dropShadow
        prefs.matte = .custom; prefs.customMatte = RGBA(hex: "406080")!
        let gap = px(CGPoint(x: 450, y: 250))
        check(ArtboardsSelfTest.near(gap, (0x40, 0x60, 0x80)), "Color: the pasteboard around the artboards takes the chosen colour", ArtboardsSelfTest.fmt(gap))
        check(ArtboardsSelfTest.near(px(CGPoint(x: 650, y: 300)), (0xFF, 0xF3, 0xB0)), "the pages keep their own backgrounds")
        ArtboardsSelfTest.writePNG(ArtboardsSelfTest.shot(c).1, dir.appendingPathComponent("07_pasteboard_custom.png"))
        prefs.matte = .lightGray
        check(ArtboardsSelfTest.near(px(CGPoint(x: 450, y: 250)), (191, 191, 191)), "Light Gray pasteboard")
        prefs = ArtboardPrefs()
        // a normal document keeps its own look
        let n = Document.newBlank(width: 300, height: 200, background: nil, name: "plain")
        use(n)
        let c2 = canvas(n)
        c2.setZoom(0.5)
        prefs.matte = .black
        let outside = ArtboardsSelfTest.framePixel(PSDOpenSelfTest.drawn(n, c2).buffer, c2, CGPoint(x: -100, y: 100))
        check(ArtboardsSelfTest.near(outside, ArtboardsSelfTest.pasteboard), "documents without artboards ignore the artboard pasteboard colour", ArtboardsSelfTest.fmt(outside))
        prefs = ArtboardPrefs()
        c2.document = nil
        c.document = nil
    }

    // MARK: 4. ⌘0 in both document kinds

    static func fitOnScreen() {
        // normal document: the whole canvas
        let n = Document.newBlank(width: 1600, height: 900, background: .white, name: "plain")
        use(n)
        let c = canvas(n)
        c.setZoom(3)
        ZoomController.run(.fitOnScreen, animated: false)
        let (ok1, d1) = fitted(c, n.state.canvasCGRect)
        check(ok1, "⌘0 in a normal document fits the whole canvas", d1)
        // artboard document with leftover canvas margins: the artboards and the loose layers
        let d = doc()
        d.state.width = 2400; d.state.height = 1600   // (margins right and below, as with Auto-size Canvas off)
        c.document = d
        c.setZoom(2)
        let want = CGRect(x: 100, y: 50, width: 700, height: 490)   // A ∪ B ∪ Loose (600…700 × 480…540)
        check(ArtboardOps.screenFitRect(d.state) == want, "the fit rectangle is the artboards plus the layers outside them", "\(String(describing: ArtboardOps.screenFitRect(d.state)))")
        ZoomController.run(.fitOnScreen, animated: false)
        let (ok2, d2) = fitted(c, want)
        check(ok2, "⌘0 in an artboard document fits the artboards and loose layers, not the canvas margins", d2)
        AppActions.fitOnScreen()
        check(fitted(c, want).0, "View ▸ Fit on Screen (AppActions) does the same")
        // hidden loose layer: not part of the view
        d.updateLayer(id(d, "Loose")) { $0.isVisible = false }
        check(ArtboardOps.screenFitRect(d.state) == CGRect(x: 100, y: 50, width: 700, height: 400), "a hidden layer outside the artboards is left out")
        // Fit Artboard on Screen: still the selected artboard
        d.selectLayer(id(d, "Pink"))
        ZoomController.run(.fitArtboard, animated: false)
        check(fitted(c, CGRect(x: 500, y: 50, width: 300, height: 400)).0, "Fit Artboard on Screen still fits the selected artboard")
        c.document = nil
    }

    // MARK: 5. Auto-size Canvas: all four sides, no jump, one undo step

    /// View position of a document point (the "nothing jumps" probe follows the content).
    static func viewOf(_ c: CanvasView, _ d: Document, _ name: String) -> CGPoint? {
        bounds(d, name).map { c.docToView(CGPoint(x: $0.minX, y: $0.minY)) }
    }

    static func autoSizeCanvas() {
        let d = doc()
        let c = canvas(d)
        c.setZoom(0.5)
        let h0 = d.history.count
        let v0 = viewOf(c, d, "Pink")!, z0 = d.zoom
        // any layer change in an artboard document fits the canvas (margins on all four sides go)
        d.updateLayer(id(d, "Blue")) { $0.opacity = 0.9 }
        d.commit("Opacity")
        check(d.state.width == 700 && d.state.height == 490, "after a layer change the canvas is the artboards plus the loose layer", "\(d.state.width)×\(d.state.height)")
        check(rect(d, "A")?.origin == .zero && d.history.count == h0 + 1 && d.history.last?.name == "Opacity", "left / top margins trimmed (A moves to 0,0) in the same history step",
              "\(String(describing: rect(d, "A"))) steps \(d.history.count - h0)")
        check(near(viewOf(c, d, "Pink")!, v0) && d.zoom == z0, "nothing jumps on screen when the left / top edge moves", "\(viewOf(c, d, "Pink")!) vs \(v0)")
        check(d.state.artboardOrigin == CGPoint(x: -100, y: -50) && ArtboardCoords.artboardPosition(rect(d, "A")!, d.state) == CGPoint(x: 100, y: 50),
              "artboard X / Y (Properties) stay 100, 50: the document origin moved with the canvas", "\(d.state.artboardOrigin)")
        // undo / redo: the canvas comes back, and the view with it
        d.undo()
        check(d.state.width == 1000 && rect(d, "A")?.origin == CGPoint(x: 100, y: 50) && near(viewOf(c, d, "Pink")!, v0), "undo restores the canvas without a jump", "\(viewOf(c, d, "Pink")!)")
        d.redo()
        check(d.state.width == 700 && near(viewOf(c, d, "Pink")!, v0), "redo too")
        // grow left: an artboard moved past the left edge
        let a = id(d, "A")
        ArtboardOps.move(d, a, to: CGPoint(x: -150, y: 0))
        check(d.state.width == 850 && rect(d, "A")?.origin == .zero && rect(d, "B")?.minX == 550, "moving an artboard past the left edge grows the canvas to the left", "\(d.state.width) \(String(describing: rect(d, "B")))")
        check(near(viewOf(c, d, "Pink")!, v0), "…and B stays where it was on screen")
        check(ArtboardCoords.artboardPosition(rect(d, "A")!, d.state) == CGPoint(x: -50, y: 50), "A's X / Y read −50, 50 (Photoshop allows negative artboard positions)",
              "\(ArtboardCoords.artboardPosition(rect(d, "A")!, d.state))")
        // typing a position in Properties goes through the same origin
        ArtboardOps.move(d, a, to: ArtboardCoords.documentPoint(artboardPosition: CGPoint(x: 100, y: 50), d.state))
        check(ArtboardCoords.artboardPosition(rect(d, "A")!, d.state) == CGPoint(x: 100, y: 50) && rect(d, "A")?.origin == .zero && d.state.width == 700,
              "typing X 100 puts it back (canvas shrinks on the left again)", "\(d.state.width)")
        // grow up / shrink top
        ArtboardOps.move(d, a, to: CGPoint(x: 0, y: -100))
        check(d.state.height == 590 && rect(d, "A")?.minY == 0 && rect(d, "B")?.minY == 100, "an artboard moved above the top edge grows the canvas upwards", "\(d.state.height)")
        check(near(viewOf(c, d, "Pink")!, v0), "…without a jump")
        ArtboardOps.move(d, a, to: CGPoint(x: 0, y: 100))
        check(d.state.height == 490 && rect(d, "A")?.minY == 0, "moving it back down shrinks the top again", "\(d.state.height)")
        // right / bottom: a loose layer moved out and back
        let loose = id(d, "Loose")
        let lb = bounds(d, "Loose")!
        d.selectLayer(loose)
        d.updateLayer(loose) { $0.translate(dx: 300, dy: 200) }
        d.commit("Move")
        check(d.state.width == Int(lb.maxX) + 300 && d.state.height == Int(lb.maxY) + 200, "a loose layer moved past the right / bottom edges grows the canvas", "\(d.state.width)×\(d.state.height)")
        d.updateLayer(loose) { $0.translate(dx: -300, dy: -200) }
        d.commit("Move")
        check(d.state.width == 700 && d.state.height == 490, "moved back: the canvas shrinks on the right / bottom", "\(d.state.width)×\(d.state.height)")
        check(near(viewOf(c, d, "Pink")!, v0), "after all that, B's contents are still where they were on screen")
        // a step that sets the canvas itself keeps it (Canvas Size)
        let h1 = d.history.count
        AppActions.canvasSize(width: 900, height: 700, anchorX: 0, anchorY: 0, extension: nil)
        check(d.state.width == 900 && d.history.count == h1 + 1, "Canvas Size keeps the canvas it sets", "\(d.state.width)")
        c.document = nil
    }

    // MARK: 6. Stored geometry follows the canvas

    static func storedGeometry() {
        let d = doc()
        let c = canvas(d)
        let pink = id(d, "Pink")
        d.selectLayer(pink)
        d.state.guides = [Guide(isVertical: true, position: 550), Guide(isVertical: false, position: 75)]
        d.state.toolData.notes = [DocNote(position: CGPoint(x: 520, y: 70), author: "", color: .white)]
        d.state.toolData.slices = [DocSlice(rect: CGRect(x: 500, y: 50, width: 100, height: 100))]
        d.state.paths = [NamedPath(name: "P", path: VectorPath.rect(CGRect(x: 520, y: 80, width: 40, height: 40)))]
        d.state.layerComps = [AppActions.captureComp(name: "Comp")]
        var f = AnimationFrame(); f.positions[pink] = Animation.anchor(d.state.layer(pink)!)!
        d.state.frames = [f]
        let comp0 = d.state.layerComps[0].entries[pink]?.position
        prefs.autoSizeCanvas = false
        d.commit("setup")   // (recorded with the margins)
        prefs.autoSizeCanvas = true
        check(d.state.width == 1000, "setup kept its margins")
        d.updateLayer(id(d, "Blue")) { $0.opacity = 0.8 }
        d.commit("Opacity")   // trims 100 px left, 50 px top
        let dx: CGFloat = -100, dy: CGFloat = -50
        check(d.state.guides.map(\.position) == [450, 25], "guides move with the content (still document pixels)", "\(d.state.guides.map(\.position))")
        check(d.state.toolData.notes.first?.position == CGPoint(x: 420, y: 20), "notes move with the content")
        check(d.state.toolData.slices.first?.rect == CGRect(x: 400, y: 0, width: 100, height: 100), "slices move with the content", "\(String(describing: d.state.toolData.slices.first?.rect))")
        check(d.state.paths.first.map { $0.path.bounds } == CGRect(x: 420, y: 30, width: 40, height: 40), "paths move with the content", "\(String(describing: d.state.paths.first?.path.bounds))")
        check(d.state.layerComps[0].entries[pink]?.position == comp0.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }, "layer comp positions follow (syncStoredGeometry)",
              "\(String(describing: d.state.layerComps[0].entries[pink]?.position)) from \(String(describing: comp0))")
        check(d.state.frames.first?.positions[pink] == Animation.anchor(d.state.layer(pink)!), "animation frame positions follow", "\(String(describing: d.state.frames.first?.positions[pink]))")
        d.undo()
        check(d.state.guides.map(\.position) == [550, 75] && d.state.toolData.notes.first?.position == CGPoint(x: 520, y: 70), "undo puts them back")
        c.document = nil
    }

    // MARK: 7. Auto-size Canvas off

    static func autoSizeOff() {
        prefs.autoSizeCanvas = false
        defer { prefs.autoSizeCanvas = true }
        let d = doc()
        d.updateLayer(id(d, "Blue")) { $0.opacity = 0.9 }
        d.commit("Opacity")
        check(d.state.width == 1000 && d.state.height == 600 && rect(d, "A")?.origin == CGPoint(x: 100, y: 50), "off: a layer change leaves the canvas alone")
        ArtboardOps.move(d, id(d, "A"), to: CGPoint(x: 120, y: 60))
        check(d.state.width == 800 && rect(d, "A")?.origin == CGPoint(x: 120, y: 60), "off: artboard commands keep the left / top margin and trim the right (as before)", "\(d.state.width)×\(d.state.height)")
        ArtboardOps.move(d, id(d, "A"), to: CGPoint(x: -50, y: 60))
        check(rect(d, "A")?.minX == 0 && d.state.width >= 850, "off: the canvas still grows to hold an artboard moved past the edge")
    }

    // MARK: 8. Auto-nesting: clipped layers, ⌥-drag copies, the preference

    static func nesting() {
        let d = doc()
        // a base in A with a layer clipped to it (covering only the base's left half)
        var clip = shape("Clip", CGRect(x: 130, y: 280, width: 70, height: 80), "FFBE0B")
        clip.isClipped = true
        d.state.updateLayer(id(d, "A")) { $0.children += [shape("Base", CGRect(x: 140, y: 290, width: 120, height: 60), "8338EC"), clip] }
        d.commit("setup")
        let c = canvas(d)
        AppModel.shared.tool = .move
        let mv = c.tool(for: .move)
        d.selectLayer(id(d, "Base"))
        let o = d.state.artboardOrigin   // (the setup step trimmed the canvas)
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x + o.x, y: y + o.y) }
        ArtboardsSelfTest.drag(mv, c, P(240, 320), P(640, 320))
        check(parentName(d, "Base") == "B" && parentName(d, "Clip") == "B", "a layer moved onto another artboard takes the layers clipped to it", "\(String(describing: parentName(d, "Clip")))")
        let sib = d.state.siblings(of: id(d, "Base"))
        let bi = sib.firstIndex { $0.name == "Base" }!
        check(bi + 1 < sib.count && sib[bi + 1].name == "Clip" && sib[bi + 1].isClipped && !sib[bi].isClipped, "…still clipped, right above its base", sib.map(\.name).joined(separator: ","))
        check(d.history.last?.name == "Move", "one history step")
        d.undo()
        check(parentName(d, "Base") == "A" && parentName(d, "Clip") == "A", "undo brings both back")
        d.redo()
        // off every artboard: both to the top level
        d.selectLayer(id(d, "Base"))
        ArtboardsSelfTest.drag(mv, c, P(640, 320), P(640, 600))
        check(parentName(d, "Base") == nil && parentName(d, "Clip") == nil && d.state.layer(id(d, "Clip"))?.isClipped == true, "moved onto the pasteboard, the clipped layer leaves the artboard with it",
              "\(d.state.layers.map(\.name))")
        d.undo()
        // ⌥-drag: the copy lands on A, the original stays in B
        d.selectLayer(id(d, "Pink"))
        let n0 = d.state.allLayers.count
        let o3 = d.state.artboardOrigin
        func Q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x + o3.x, y: y + o3.y) }
        ArtboardsSelfTest.drag(mv, c, Q(650, 200), Q(250, 200), .option)
        let copy = d.state.allLayers.first { $0.name.hasPrefix("Pink copy") }
        check(d.state.allLayers.count == n0 + 1 && copy.map { l in d.state.parentID(of: l.id) == id(d, "A") } == true && parentName(d, "Pink") == "B",
              "⌥-drag: the copy is nested in the artboard it lands on, the original stays", "\(copy.flatMap { d.state.parentID(of: $0.id) }.flatMap { d.state.layer($0)?.name } ?? "nil")")
        check(d.history.last?.name == "Duplicate & Move", "Duplicate & Move is one step", d.history.last?.name ?? "")
        // ⌥-drag onto the pasteboard: a loose copy
        d.selectLayer(id(d, "Pink"))
        let o4 = d.state.artboardOrigin
        ArtboardsSelfTest.drag(mv, c, CGPoint(x: 650 + o4.x, y: 200 + o4.y), CGPoint(x: 650 + o4.x, y: 560 + o4.y), .option)
        let loose = d.state.layers.filter { $0.name.hasPrefix("Pink copy") }
        check(loose.count == 1, "⌥-drag onto the pasteboard: the copy is a loose layer", d.state.layers.map(\.name).joined(separator: ","))
        // auto-nest off: nothing moves in the tree
        prefs.autoNest = false
        d.selectLayer(id(d, "Blue"))
        let o5 = d.state.artboardOrigin
        ArtboardsSelfTest.drag(mv, c, CGPoint(x: 200 + o5.x, y: 130 + o5.y), CGPoint(x: 600 + o5.x, y: 130 + o5.y))
        check(parentName(d, "Blue") == "A", "Auto-nest Layers off: a layer dragged onto another artboard stays where it was in the Layers panel")
        prefs.autoNest = true
        c.document = nil
    }

    /// Sum of the canvas shifts of the steps up to the current one.
    static func totalShift(_ d: Document) -> CGPoint {
        var s = CGPoint.zero
        for e in d.history.prefix(d.historyIndex + 1) { if let p = ArtboardOps.stepShift[e.id] { s.x += p.x; s.y += p.y } }
        return s
    }

    // MARK: 9. Artboards stay top-level: Group Layers, the Layers panel, any other path

    static func groupRules() {
        let d = doc()
        let a = id(d, "A"), b = id(d, "B")
        // Group Layers with an artboard selected: refused (Photoshop disables it)
        d.selectLayer(a)
        check(!AppActions.canGroupLayers, "Group Layers is disabled with an artboard selected")
        let h = d.history.count
        AppActions.groupLayers()
        check(d.history.count == h && d.state.parentID(of: a) == nil && d.state.layers.contains { $0.id == a }, "Group Layers on an artboard does nothing (no group, no step)")
        check(AppModel.shared.statusMessage.contains("Artboards can't be grouped"), "and says why", AppModel.shared.statusMessage)
        d.selectLayer(id(d, "Loose")); d.selectLayer(b, extend: true)
        check(!AppActions.canGroupLayers, "…also with an artboard among other selected layers")
        AppActions.groupLayers()
        check(d.history.count == h && d.state.parentID(of: b) == nil, "a mixed selection is not grouped either")
        // layers inside or outside artboards still group
        d.selectLayer(id(d, "Pink"))
        check(AppActions.canGroupLayers, "Group Layers is available for ordinary layers")
        AppActions.groupLayers()
        check(d.activeLayer?.isGroup == true && parentName(d, "Pink") == d.activeLayer?.name && d.state.parentID(of: d.activeLayerID!) == b, "grouping layers inside an artboard works")
        let g = d.activeLayerID!
        // Layers panel: an artboard dropped into a group or another artboard goes back to the top level
        AppActions.moveLayer(a, relativeTo: g, above: false, into: true)
        check(d.state.parentID(of: a) == nil, "an artboard dropped into a group inside an artboard stays top-level")
        AppActions.moveLayer(a, relativeTo: b, above: false, into: true)
        check(d.state.parentID(of: a) == nil, "an artboard dropped into another artboard stays top-level")
        // any other path: a state with a nested artboard is fixed when it is committed
        if let l = d.state.removeLayer(a) { d.state.insertLayer(l, above: g, inside: true) }
        d.commit("Nest")
        check(d.state.parentID(of: a) == nil && d.state.layers.contains { $0.id == a }, "an artboard put into a group by any command is lifted out in the same step")
        // Artboard from Group refuses a group holding an artboard
        var st = d.state
        let inner = ArtboardOps.makeLayer("Inner", rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        let grp = Layer(name: "G", content: .group(GroupContent(children: [inner])))
        st.layers.append(grp)
        d.state = st
        check(!ArtboardOps.fromGroup(d, grp.id), "Artboard from Group refuses a group that holds an artboard")
        d.revertUncommitted()
    }

    // MARK: 10. Layer ▸ New ▸ Artboard

    static func newArtboardMenu(_ dir: URL) {
        let items = ArtboardMenu.newArtboardItems()
        let text = ArtboardMenu.describe(items)
        try? text.joined(separator: "\n").write(to: dir.appendingPathComponent("new_artboard_menu.txt"), atomically: true, encoding: .utf8)
        let groups = items.compactMap { it -> String? in if case .submenu(let t, _) = it { return t } else { return nil } }
        check(items.first?.title == "Canvas Size" && groups == ["Phone", "Tablet", "Watch", "Web", "Social", "Paper"], "Layer ▸ New ▸ Artboard: Canvas Size, then Phone ▸ Tablet ▸ Watch ▸ Web ▸ Social ▸ Paper ▸",
              groups.joined(separator: ", "))
        check(groups == Artboard.presetGroups.map(\.0), "the same groups as the options bar's Size menu")
        let count = items.reduce(0) { n, it in if case .submenu(_, let s) = it { return n + s.count } else { return n } }
        check(count == Artboard.presets.count && items.count == 2 + 6, "every preset is in its group (no flat list of \(count))")
        check(text.contains { $0.contains("iPhone 18 Pro Max   1320 × 2868") }, "entries show name and size")
        // picking one creates the artboard with that preset's name (sizes shared by two presets keep the right name)
        let d = Document.newBlank(width: 400, height: 300, background: .white, name: "menu")
        use(d)
        func run(_ title: String, in list: [ArtboardMenu.Item]) {
            for it in list {
                if case .action(let t, _, _, let f) = it, t.hasPrefix(title) { f(); return }
                if case .submenu(_, let sub) = it { run(title, in: sub) }
            }
        }
        run("Story / Reel", in: items)
        let ab = ArtboardOps.boards(d.state).first?.artboard
        check(ab?.rect.size == CGSize(width: 1080, height: 1920) && ab?.presetName == "Story / Reel", "Social ▸ Story / Reel makes a 1080 × 1920 artboard named after that preset",
              "\(String(describing: ab?.presetName))")
    }

    // MARK: 11. Preset sizes

    static func presets() {
        let all = Artboard.presets
        check(Set(all.map(\.0)).count == all.count, "preset names are unique")
        check(all.allSatisfy { $0.1.width >= 100 && $0.1.height >= 100 && $0.1.width == $0.1.width.rounded() && $0.1.height == $0.1.height.rounded() }, "preset sizes are whole pixels")
        let want: [(String, CGFloat, CGFloat)] = [
            ("iPhone 18 Pro Max", 1320, 2868), ("iPhone 18 Pro / 17", 1206, 2622), ("iPhone Air", 1260, 2736), ("iPhone 16e", 1170, 2532), ("iPhone SE", 750, 1334),
            ("iPad Pro 13\u{2033}", 2064, 2752), ("iPad Pro 11\u{2033}", 1668, 2420), ("iPad Air 13\u{2033}", 2048, 2732), ("iPad mini", 1488, 2266),
            ("Apple Watch Ultra", 422, 514), ("Apple Watch 46mm", 416, 496), ("Apple Watch 42mm", 374, 446),
            ("Android 1080p", 1080, 1920), ("A4 @72 ppi", 595, 842), ("Letter @72 ppi", 612, 792),
        ]
        let bad = want.filter { w in Artboard.preset(named: w.0) != CGSize(width: w.1, height: w.2) }.map(\.0)
        check(bad.isEmpty, "device and paper sizes match the makers' specifications", bad.joined(separator: ", "))
    }

    // MARK: 12. Snapshots: Preferences ▸ Artboards, options bar, View menu as text

    static func snapshots(_ dir: URL) {
        Workflow2PrefsState.pendingSection = "Artboards"
        let wp = UIFixesSelfTest.host(PreferencesDialog(), CGSize(width: 580, height: 420))
        UIFixesSelfTest.snapshot(wp, "08_preferences_artboards", dir)
        FuzzAX.enable()
        let labels = FuzzAX.tree(wp.contentView!).map(\.label)
        check(["Auto-size Canvas", "Show Artboard Names", "Auto-nest Layers in Artboards"].allSatisfy { l in labels.contains { $0.contains(l) } },
              "Preferences ▸ Artboards shows the options", labels.filter { $0.contains("Artboard") || $0.contains("Auto") }.joined(separator: " | "))
        UIFixesSelfTest.close(wp)
        Workflow2PrefsState.pendingSection = nil
        // the Artboard tool's options bar with its gear menu
        let d = doc()
        d.selectLayer(id(d, "B"))
        AppModel.shared.tool = .artboard
        let wo = UIFixesSelfTest.host(HStack(spacing: 8) { ArtboardOptions() }.padding(.horizontal, 8), CGSize(width: 1100, height: 34))
        UIFixesSelfTest.snapshot(wo, "09_options_bar_gear", dir)
        UIFixesSelfTest.close(wo)
        AppModel.shared.tool = .move
        // the View menu (zoom commands + module items), as text
        var lines = ["View"]
        for c in ZoomCommand.viewMenu { lines.append(c.map { "  " + $0.title + ($0 == .fitOnScreen ? "   ⌘0" : "") } ?? "  —") }
        lines += ["  …", "  Show ▸"]
        for it in MenuRegistry.items(for: "View") where it.submenu == "Show" {
            lines.append("      " + (it.checked?() == true ? "✓ " : "  ") + it.title)
        }
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("view_menu.txt"), atomically: true, encoding: .utf8)
        check(lines.contains("      ✓ Artboard Names"), "View menu text lists Show ▸ ✓ Artboard Names")
        print("artboards3: wrote snapshots to \(dir.path)")
    }
}
