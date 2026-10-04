import AppKit
import SwiftUI
import PDFKit
import ImageCratCore

/// Artboards (Photoshop model): pages on a pasteboard, the Artboard tool, Layers-panel rows and context menu,
/// Properties, export, PSD round trip and undo. `LUMEN_SELFTEST_ONLY=artboards2 Lumen --selftest <dir>`
enum ArtboardsSelfTest {
    static func register() { FeatureModules.selfTests.append(("artboards2", { run($0) })) }

    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") artboards2: \(name)\(d.isEmpty ? "" : " — " + d)")
        fflush(stdout)
    }

    /// Stand-in for the user's 07_artboards.psd (two artboards made in Photoshop, a 700 × 400 canvas): the same layout,
    /// written by the PSD exporter into the test's own folder, so the test needs no file from outside the repository.
    static func userFixture(_ dir: URL) -> URL? {
        var st = DocumentState(width: 700, height: 400)
        st.layers = [
            ArtboardOps.makeLayer("Artboard 1", rect: CGRect(x: 20, y: 20, width: 300, height: 360), background: .white,
                                  children: [shape("Square", CGRect(x: 60, y: 60, width: 120, height: 120), "3A86FF")]),
            ArtboardOps.makeLayer("Artboard 2", rect: CGRect(x: 360, y: 20, width: 320, height: 360), background: RGBA(hex: "FFD6A5")!,
                                  children: [shape("Bar", CGRect(x: 400, y: 60, width: 160, height: 40), "F72585")]),
        ]
        let url = dir.appendingPathComponent("07_artboards.psd")
        do { try DocumentIO.export(st, to: url, format: .psd, quality: 1, scale: 1) } catch { check(false, "07_artboards.psd fixture written", "\(error)"); return nil }
        return url
    }
    static let pasteboard: (UInt8, UInt8, UInt8) = (40, 40, 40)

    static func run(_ out: URL) {
        passes = 0; failures = 0
        let dir = out.appendingPathComponent("artboards2")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppModel.shared
        let saved = (canvas: AppActions.canvas, hook: app.toolChanged, tool: app.tool, docs: app.documents, active: app.activeDocumentID,
                     anim: ZoomAnimator.enabled, dialog: app.dialog, status: app.statusMessage)
        defer {
            ArtboardCanvas.renaming?.finish(commit: false)
            ZoomAnimator.enabled = saved.anim
            AppActions.canvas = saved.canvas; app.toolChanged = saved.hook; app.tool = saved.tool
            app.documents = saved.docs; app.activeDocumentID = saved.active; app.dialog = saved.dialog; app.statusMessage = saved.status
        }
        ZoomAnimator.enabled = false
        // artboard preferences at their defaults, in a throw-away defaults suite (the user's settings are never touched)
        ArtboardSettings.shared.usingTemporaryDefaults("LumenArtboards2SelfTest") {
            openUserFile(dir)
            creation()
            contextMenuActions(dir)
            duplicateWithContents()
            reparenting()
            pasteboardRendering(dir)
            backgroundsAndClipping()
            exportPerArtboard(dir)
            psdRoundTrip(dir)
            nativeAndLegacy(dir)
            htmlAndZoom()
            undoRedo()
            newDocumentAndRules()
            snapshots(dir)
        }
        print("artboards2: \(passes) passed, \(failures) failed")
    }

    // MARK: Helpers

    static func use(_ d: Document) {
        let app = AppModel.shared
        if !app.documents.contains(where: { $0 === d }) { app.documents.append(d) }
        app.activeDocumentID = d.id
    }

    static func shape(_ name: String, _ r: CGRect, _ hex: String) -> Layer {
        var l = SelfTest.shapeLayer(r, RGBA(hex: hex)!, radius: 0)
        l.name = name
        return l
    }

    /// Document with two artboards (white "A" with a blue shape, yellow "B" with a pink shape) and a loose green
    /// shape on the pasteboard below them.
    static func twoBoards() -> Document {
        var st = DocumentState(width: 900, height: 500)
        let a = ArtboardOps.makeLayer("A", rect: CGRect(x: 0, y: 0, width: 300, height: 400), background: .white,
                                      children: [shape("Blue", CGRect(x: 40, y: 40, width: 120, height: 80), "3A86FF")])
        let b = ArtboardOps.makeLayer("B", rect: CGRect(x: 400, y: 0, width: 300, height: 400), background: RGBA(hex: "FFF3B0")!,
                                      children: [shape("Pink", CGRect(x: 460, y: 60, width: 100, height: 100), "F72585")])
        st.layers = [a, b, shape("Loose", CGRect(x: 760, y: 420, width: 100, height: 60), "2DC653")]
        let d = Document(state: st, name: "artboards2")
        use(d)
        return d
    }

    static func id(_ d: Document, _ name: String) -> UUID? { d.state.allLayers.first { $0.name == name }?.id }
    static func parentName(_ d: Document, _ name: String) -> String? { id(d, name).flatMap { d.state.parentID(of: $0) }.flatMap { d.state.layer($0)?.name } }
    static func rect(_ d: Document, _ name: String) -> CGRect? { id(d, name).flatMap { d.state.layer($0)?.artboard?.rect } }
    static func bounds(_ d: Document, _ name: String) -> CGRect? { id(d, name).flatMap { d.state.layer($0) }.flatMap { Compositor.shared.contentBounds($0, state: d.state) } }

    /// Layer tree + canvas size, for comparing states.
    static func fingerprint(_ st: DocumentState) -> String {
        func walk(_ ls: [Layer]) -> String {
            ls.map { l in "\(l.id.uuidString.prefix(6)):\(l.name)\(l.artboard.map { "@\(Int($0.rect.minX)),\(Int($0.rect.minY)),\(Int($0.rect.width)),\(Int($0.rect.height))/\($0.background.map { "\($0.r),\($0.g),\($0.b),\($0.a)" } ?? "clear")" } ?? "")[\(walk(l.children))]" }.joined(separator: ",")
        }
        return "\(st.width)x\(st.height) " + walk(st.layers)
    }

    static func composite(_ st: DocumentState) -> PixelBuffer {
        let sp = CanvasSpace(width: st.width, height: st.height)
        return RenderEngine.renderBuffer(Compositor.shared.composite(st), docRect: st.canvasRect, space: sp)
    }

    static func near(_ p: (UInt8, UInt8, UInt8, UInt8), _ q: (UInt8, UInt8, UInt8), _ tol: Int = 6) -> Bool {
        abs(Int(p.0) - Int(q.0)) <= tol && abs(Int(p.1) - Int(q.1)) <= tol && abs(Int(p.2) - Int(q.2)) <= tol
    }
    static func rgb(_ c: RGBA) -> (UInt8, UInt8, UInt8) { (UInt8((c.r * 255).rounded()), UInt8((c.g * 255).rounded()), UInt8((c.b * 255).rounded())) }
    static func fmt(_ p: (UInt8, UInt8, UInt8, UInt8)) -> String { "(\(p.0),\(p.1),\(p.2),\(p.3))" }

    /// A bare canvas (not in a window) showing `d`, as `AppActions.canvas`.
    static func canvas(_ d: Document, size: CGSize = CGSize(width: 900, height: 600)) -> CanvasView {
        let c = CanvasView(frame: CGRect(origin: .zero, size: size))
        AppActions.canvas = c
        c.document = d
        c.fitOnScreen()
        return c
    }

    /// The canvas as drawn on screen: Metal frame (pasteboard, pages, document) with the overlay (names, highlight,
    /// tool handles) on top, at 2×.
    static func shot(_ c: CanvasView) -> (PixelBuffer, CGImage?) {
        guard let d = c.document else { return (PixelBuffer(width: 1, height: 1), nil) }
        let f = PSDOpenSelfTest.drawn(d, c)
        c.overlay.frame = c.bounds
        let w = f.buffer.width, h = f.buffer.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (f.buffer, nil) }
        ctx.draw(f.buffer.makeCGImage(), in: CGRect(x: 0, y: 0, width: w, height: h))
        if let rep = c.overlay.bitmapImageRepForCachingDisplay(in: c.overlay.bounds) {
            c.overlay.cacheDisplay(in: c.overlay.bounds, to: rep)
            if let o = rep.cgImage { ctx.draw(o, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        }
        return (f.buffer, ctx.makeImage())
    }

    /// Frame pixel at doc point `p` (2× drawable, row 0 at the top).
    static func framePixel(_ b: PixelBuffer, _ c: CanvasView, _ p: CGPoint) -> (UInt8, UInt8, UInt8, UInt8) {
        let v = c.docToView(p)
        return b.pixel(Int(v.x * 2), Int(v.y * 2))
    }

    static func writePNG(_ cg: CGImage?, _ url: URL) {
        guard let cg else { return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
    }

    static func toolEvent(_ c: CanvasView, doc p: CGPoint, _ mods: NSEvent.ModifierFlags = [], clicks: Int = 1) -> ToolEvent {
        ToolEvent(doc: p, view: c.docToView(p), pressure: 1, modifiers: mods, clickCount: clicks, isTablet: false)
    }
    static func toolEvent(_ c: CanvasView, view v: CGPoint, _ mods: NSEvent.ModifierFlags = [], clicks: Int = 1) -> ToolEvent {
        ToolEvent(doc: c.viewToDoc(v), view: v, pressure: 1, modifiers: mods, clickCount: clicks, isTablet: false)
    }

    /// Drags with `tool` from doc point `a` to `b`.
    static func drag(_ t: Tool, _ c: CanvasView, _ a: CGPoint, _ b: CGPoint, _ mods: NSEvent.ModifierFlags = []) {
        t.mouseDown(toolEvent(c, doc: a, mods))
        for i in 1...4 {
            let k = CGFloat(i) / 4
            t.mouseDragged(toolEvent(c, doc: CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k), mods))
        }
        t.mouseUp(toolEvent(c, doc: b, mods))
    }

    // MARK: 1. A Photoshop-style two-artboard file

    static func openUserFile(_ dir: URL) {
        guard let url = userFixture(dir) else { return }
        guard let d = try? DocumentIO.load(url: url) else { check(false, "07_artboards.psd opens"); return }
        use(d)
        let boards = ArtboardOps.boards(d.state)
        check(boards.count == 2 && d.state.layers.allSatisfy(\.isArtboard), "07_artboards.psd opens with two top-level artboards", boards.map(\.name).joined(separator: ", "))
        check(rect(d, "Artboard 1") == CGRect(x: 20, y: 20, width: 300, height: 360) && rect(d, "Artboard 2") == CGRect(x: 360, y: 20, width: 320, height: 360),
              "artboard rectangles come from 'artb'", "\(String(describing: rect(d, "Artboard 1"))) \(String(describing: rect(d, "Artboard 2")))")
        let bg2 = id(d, "Artboard 2").flatMap { d.state.layer($0)?.artboard?.background }
        check(d.state.layer(id(d, "Artboard 1"))?.artboard?.background == .white && bg2 != nil && bg2 != .white, "artboard backgrounds: white and a custom colour", "\(String(describing: bg2))")
        let c = canvas(d)
        let (f, img) = shot(c)
        writePNG(img, dir.appendingPathComponent("01_user_psd_canvas.png"))
        // the canvas margin around / between the artboards is pasteboard, not a checkerboard page
        let gap = framePixel(f, c, CGPoint(x: 340, y: 200)), corner = framePixel(f, c, CGPoint(x: 8, y: 8))
        check(near(gap, pasteboard) && near(corner, pasteboard), "the canvas outside the artboards is pasteboard grey", "between \(fmt(gap)), corner \(fmt(corner))")
        check(near(framePixel(f, c, CGPoint(x: 300, y: 360)), (255, 255, 255)), "Artboard 1 is a white page")
        if let bg2 { check(near(framePixel(f, c, CGPoint(x: 650, y: 360)), rgb(bg2)), "Artboard 2 shows its own background") }
        let l1 = d.state.layer(id(d, "Artboard 1")!)!, lr = ArtboardCanvas.labelRect(l1, canvas: c)
        let tl = c.docToView(CGPoint(x: 20, y: 20))
        check(lr.map { abs($0.minX - tl.x) < 1 && $0.maxY < tl.y && $0.maxY > tl.y - 8 } ?? false, "the name sits just above the artboard's top-left corner", "\(String(describing: lr)) vs \(tl)")
        if let lr { check(ArtboardCanvas.labelHit(CGPoint(x: lr.midX, y: lr.midY), canvas: c)?.id == l1.id, "the name is hit-testable") }
        c.document = nil
    }

    // MARK: 2. Creation, the first artboard, auto-size canvas

    static func creation() {
        let d = Document.newBlank(width: 800, height: 600, background: .white, name: "create")
        use(d)
        let bgID = d.state.layers[0].id
        AppActions.newArtboard(size: CGSize(width: 400, height: 300))
        let a1 = ArtboardOps.boards(d.state).first
        check(a1?.name == "Artboard 1" && a1?.children.map(\.id) == [bgID], "the first artboard in a normal document takes the layers it covers", "\(String(describing: a1?.children.map(\.name)))")
        check(d.state.width == 400 && d.state.height == 300, "the canvas shrinks to the artboard", "\(d.state.width)×\(d.state.height)")
        check(d.history.last?.name == "New Artboard" && d.history.count == 2, "New Artboard is one history step")
        guard let a1id = a1?.id else { return }
        let a2 = ArtboardTool.addAdjacent(d, to: a1id, side: .right)
        check(a2.flatMap { d.state.layer($0)?.artboard?.rect } == CGRect(x: 500, y: 0, width: 400, height: 300), "+ adds an artboard of the same size to the right, 100 px apart")
        check(d.state.width == 900 && d.state.height == 300, "the canvas grows to the right", "\(d.state.width)×\(d.state.height)")
        let a3 = ArtboardTool.addAdjacent(d, to: a1id, side: .right)
        check(a3.flatMap { d.state.layer($0)?.artboard?.rect } == CGRect(x: 1000, y: 0, width: 400, height: 300), "a second + to the right skips the artboard already there")
        let a4 = ArtboardTool.addAdjacent(d, to: a1id, side: .left)
        check(a4.flatMap { d.state.layer($0)?.artboard?.rect } == CGRect(x: 0, y: 0, width: 400, height: 300) && rect(d, "Artboard 1") == CGRect(x: 500, y: 0, width: 400, height: 300),
              "+ on the left grows the canvas to the left and shifts everything", "\(String(describing: rect(d, "Artboard 1")))")
        check(d.state.width == 1900, "canvas 1900 wide after four artboards", "\(d.state.width)")
        // deleting the rightmost one gives the room back
        if let a3 { ArtboardOps.delete(d, [a3], keepContents: false) }
        check(d.state.width == 1400 && d.history.last?.name == "Delete Artboard", "deleting the rightmost artboard shrinks the canvas", "\(d.state.width)")
        // Artboard tool: drag to create, select, move, resize, ⌥+ duplicates
        let c = canvas(d)
        AppModel.shared.tool = .artboard
        let t = c.tool(for: .artboard)
        drag(t, c, CGPoint(x: 100, y: 400), CGPoint(x: 300, y: 550))
        let made = ArtboardOps.boards(d.state).last
        check(made?.artboard?.rect == CGRect(x: 100, y: 400, width: 200, height: 150) && d.state.height == 550, "dragging on the pasteboard creates an artboard (canvas grows down)", "\(String(describing: made?.artboard?.rect)) canvas \(d.state.height)")
        guard let mid = made?.id else { return }
        drag(t, c, CGPoint(x: 200, y: 450), CGPoint(x: 250, y: 470))
        check(d.state.layer(mid)?.artboard?.rect == CGRect(x: 150, y: 420, width: 200, height: 150) && d.history.last?.name == "Move Artboard", "dragging an artboard moves it")
        drag(t, c, CGPoint(x: 350, y: 570), CGPoint(x: 380, y: 600))
        check(d.state.layer(mid)?.artboard?.rect == CGRect(x: 150, y: 420, width: 230, height: 180) && d.history.last?.name == "Resize Artboard", "dragging a handle resizes it",
              "\(String(describing: d.state.layer(mid)?.artboard?.rect))")
        // label: click selects, drag moves (with the Move tool too)
        AppModel.shared.tool = .move
        d.selectLayer(a1id)
        if let l = d.state.layer(mid), let lr = ArtboardCanvas.labelRect(l, canvas: c) {
            let p = CGPoint(x: lr.minX + 6, y: lr.midY)
            let ev = toolEvent(c, view: p)
            let lt = ArtboardCanvas.toolForLabelClick(ev, canvas: c)
            check(lt === c.tool(for: .artboard), "a click on a name with the Move tool goes to the artboard")
            lt?.mouseDown(ev); lt?.mouseUp(ev)
            check(d.activeLayerID == mid && d.selectedLayerIDs == [mid], "clicking an artboard's name selects the artboard")
            let r0 = d.state.layer(mid)!.artboard!.rect
            lt?.mouseDown(ev); lt?.mouseDragged(toolEvent(c, view: CGPoint(x: p.x + 20 * CGFloat(d.zoom), y: p.y))); lt?.mouseUp(toolEvent(c, view: CGPoint(x: p.x + 20 * CGFloat(d.zoom), y: p.y)))
            check(d.state.layer(mid)?.artboard?.rect == r0.offsetBy(dx: 20, dy: 0), "dragging a name moves the artboard", "\(String(describing: d.state.layer(mid)?.artboard?.rect))")
            // double-click: rename in place
            lt?.mouseDown(toolEvent(c, view: CGPoint(x: (ArtboardCanvas.labelRect(d.state.layer(mid)!, canvas: c)?.minX ?? 0) + 6, y: p.y), clicks: 2))
            if let f = ArtboardCanvas.renaming {
                f.stringValue = "Hero"
                f.commitAction()
                check(d.state.layer(mid)?.name == "Hero" && d.history.last?.name == "Rename Artboard" && ArtboardCanvas.renaming == nil, "double-clicking a name renames the artboard in place")
            } else { check(false, "double-clicking a name opens a rename field") }
        }
        AppModel.shared.tool = .artboard
        d.selectLayer(mid)
        let n0 = ArtboardOps.boards(d.state).count
        if let ab = d.state.layer(mid)?.artboard?.rect {
            let v = c.docToView(CGPoint(x: ab.maxX, y: ab.midY))
            let e = toolEvent(c, view: CGPoint(x: v.x + 24, y: v.y), .option)
            t.mouseDown(e); t.mouseUp(e)
            let copy = ArtboardOps.boards(d.state).last
            check(ArtboardOps.boards(d.state).count == n0 + 1 && copy?.name == "Hero copy" && copy?.artboard?.rect.size == ab.size, "⌥-click on + duplicates the artboard", "\(String(describing: copy?.name))")
        }
        // align & spacing
        let sel = [a1id, mid]
        d.selectedLayerIDs = Set(sel)
        ArtboardOps.align(d, sel, .top)
        check(rect(d, "Artboard 1")?.minY == d.state.layer(mid)?.artboard?.rect.minY, "Align top edges lines the artboards up")
        ArtboardOps.distribute(d, sel, horizontal: true, spacing: 60)
        if let r1 = d.state.layer(sel[0])?.artboard?.rect, let r2 = d.state.layer(sel[1])?.artboard?.rect {
            let (lft, rgt) = r1.minX < r2.minX ? (r1, r2) : (r2, r1)
            check(rgt.minX - lft.maxX == 60, "spacing lays the artboards out 60 px apart", "\(lft) \(rgt)")
        }
        c.document = nil
    }

    // MARK: 3. Context menu

    static func contextMenuActions(_ dir: URL) {
        let d = twoBoards()
        guard let a = id(d, "A"), let b = id(d, "B") else { return }
        d.selectLayer(a)
        var renamed = false
        let items = ArtboardMenu.items(d, a, rename: { renamed = true })
        let titles = items.compactMap(\.title)
        let want = ["Duplicate Artboard", "Rename Artboard", "Delete Artboard", "Delete Artboard Only (Keep Contents)", "Artboard from Group", "Artboard from Layers…",
                    "Ungroup Artboards", "Convert to Group", "Background Color", "Fit Artboard on Screen", "Export Artboard As…", "Artboards to Files…", "Artboards to PDF…"]
        check(want.allSatisfy(titles.contains), "the artboard menu has every command", "missing \(want.filter { !titles.contains($0) })")
        let text = ArtboardMenu.describe(items)
        try? text.joined(separator: "\n").write(to: dir.appendingPathComponent("context_menu.txt"), atomically: true, encoding: .utf8)
        check(text.contains("  ✓ White") || text.contains { $0.hasSuffix("✓ White") }, "Background Color shows the current choice", text.filter { $0.contains("White") }.joined())
        let ns = ArtboardMenu.nsMenu(items)
        check(ns.items.count == items.count && ns.item(withTitle: "Background Color")?.submenu?.items.count == 4, "the canvas menu (NSMenu) has the same items")
        func run(_ title: String, in list: [ArtboardMenu.Item]) {
            for it in list {
                if case .action(let t, _, _, let f) = it, t == title { f(); return }
                if case .submenu(_, let sub) = it { run(title, in: sub) }
            }
        }
        run("Rename Artboard", in: items)
        check(renamed, "Rename Artboard starts renaming")
        run("Black", in: items)
        check(d.state.layer(a)?.artboard?.background == .black && d.history.last?.name == "Artboard Background", "Background Color ▸ Black")
        run("Transparent", in: ArtboardMenu.items(d, a, rename: {}))
        check(d.state.layer(a)?.artboard?.background == nil, "Background Color ▸ Transparent")
        run("White", in: ArtboardMenu.items(d, a, rename: {}))
        check(d.state.layer(a)?.artboard?.background == .white, "Background Color ▸ White")
        AppModel.shared.dialog = nil
        run("Other…", in: ArtboardMenu.items(d, a, rename: {}))
        if case .custom(let s) = AppModel.shared.dialog { check(s == "artboardBackground", "Background Color ▸ Other… opens the colour dialog") } else { check(false, "Other… opens a dialog") }
        AppModel.shared.dialog = nil
        run("Duplicate Artboard", in: ArtboardMenu.items(d, a, rename: {}))
        check(id(d, "A copy") != nil && d.history.last?.name == "Duplicate Artboard", "Duplicate Artboard")
        run("Delete Artboard", in: ArtboardMenu.items(d, id(d, "A copy")!, rename: {}))
        check(id(d, "A copy") == nil && id(d, "Blue copy") == nil, "Delete Artboard removes it with its contents")
        run("Delete Artboard Only (Keep Contents)", in: ArtboardMenu.items(d, b, rename: {}))
        check(id(d, "B") == nil && parentName(d, "Pink") == nil && bounds(d, "Pink") == CGRect(x: 460, y: 60, width: 100, height: 100), "Delete Artboard Only keeps the contents where they were")
        d.undo()
        check(id(d, "B") != nil && parentName(d, "Pink") == "B", "undo brings the artboard back around its contents")
        run("Ungroup Artboards", in: ArtboardMenu.items(d, b, rename: {}))
        check(id(d, "B") == nil && parentName(d, "Pink") == nil && d.history.last?.name == "Ungroup Artboards", "Ungroup Artboards")
        d.undo()
        // Artboard from Group: a group of the loose layer and Pink? (a normal group on the pasteboard)
        d.selectLayer(id(d, "Loose")!)
        AppActions.groupLayers()
        let gid = d.activeLayerID!
        let gItems = ArtboardMenu.items(d, a, rename: {})
        if case .action(_, let enabled, _, _)? = gItems.first(where: { $0.title == "Artboard from Group" }) { check(enabled, "Artboard from Group is offered for a selected group") }
        run("Artboard from Group", in: gItems)
        check(d.state.layer(gid)?.artboard?.rect == CGRect(x: 760, y: 420, width: 100, height: 60) && d.history.last?.name == "Artboard from Group", "Artboard from Group fits the group's contents",
              "\(String(describing: d.state.layer(gid)?.artboard?.rect))")
        // Artboard from Layers (in the panel's menu for an ordinary layer too)
        d.undo(); d.undo()
        d.selectLayer(id(d, "Loose")!)
        AppActions.artboardFromLayers()
        check(d.activeLayer?.isArtboard == true && d.activeLayer?.children.map(\.name) == ["Loose"] && d.state.parentID(of: d.activeLayerID!) == nil, "Artboard from Layers")
        d.undo()
        // Convert to Group
        run("Convert to Group", in: ArtboardMenu.items(d, b, rename: {}))
        check(d.state.layer(b)?.isArtboard == false && d.state.layer(b)?.isGroup == true, "Convert to Group")
        d.undo()
        // Export Artboard As (the panel itself is AppKit; the export it runs:)
        let ex = dir.appendingPathComponent("menu_export")
        try? FileManager.default.removeItem(at: ex)
        let files = (try? ArtboardExport.export(d.state, ids: [b], to: ex, options: ArtboardExport.Options())) ?? []
        check(files.map(\.lastPathComponent) == ["B.png"], "Export Artboard As writes the artboard", files.map(\.lastPathComponent).joined())
        // Fit Artboard on Screen
        let c = canvas(d)
        run("Fit Artboard on Screen", in: ArtboardMenu.items(d, b, rename: {}))
        let v = c.docToView(CGRect(x: 400, y: 0, width: 300, height: 400))
        check(abs(v.midX - c.contentArea.midX) < 1 && abs(v.midY - c.contentArea.midY) < 1 && (abs(v.height - (c.contentArea.height - 40)) < 1 || abs(v.width - (c.contentArea.width - 40)) < 1),
              "Fit Artboard on Screen fits the artboard", "\(v)")
        // Layer menu
        let layerItems = ArtboardsModule.menuItems().filter { $0.1 == "Layer" }.map(\.0)
        check(["Duplicate Artboard", "Rename Artboard…", "Delete Artboard", "Artboard from Group", "Artboard from Layers", "Ungroup Artboards", "Export Artboard As…"].allSatisfy(layerItems.contains),
              "Layer ▸ Artboards has the same commands", layerItems.joined(separator: ", "))
        check(MenuRegistry.items(for: "File").contains { $0.title == "Artboards to PDF…" && $0.submenu == "Export" } && MenuRegistry.items(for: "File").contains { $0.title == "Artboards to Files…" },
              "File ▸ Export has Artboards to Files and Artboards to PDF")
        c.document = nil
    }

    // MARK: 4. Duplicate with contents

    static func duplicateWithContents() {
        let d = twoBoards()
        guard let a = id(d, "A") else { return }
        let before = d.state.layer(a)!
        let ids = ArtboardOps.duplicate(d, [a])
        guard let cid = ids.first, let copy = d.state.layer(cid), let r = copy.artboard?.rect else { check(false, "duplicate made"); return }
        let others = ArtboardOps.boards(d.state).filter { $0.id != cid }.compactMap { $0.artboard?.rect }
        check(r.size == before.artboard!.rect.size && !others.contains { $0.intersects(r) } && r.minY == 0, "the duplicate goes to free space beside the others", "\(r)")
        check(copy.children.count == before.children.count && Set(copy.allIDs).isDisjoint(with: Set(before.allIDs)), "the duplicate has its own copies of the contents")
        let dx = r.minX - before.artboard!.rect.minX
        let b0 = Compositor.shared.contentBounds(before.children[0], state: d.state), b1 = Compositor.shared.contentBounds(copy.children[0], state: d.state)
        check(b0.map { $0.offsetBy(dx: dx, dy: 0) } == b1, "its contents keep their place on the artboard", "\(String(describing: b0)) → \(String(describing: b1))")
        check(copy.name == "A copy" && copy.artboard?.background == before.artboard?.background, "name “A copy”, same background")
        check(d.state.width >= Int(r.maxX), "the canvas grows to hold the duplicate", "\(d.state.width)")
        // the copy renders like the original
        let img = composite(d.state)
        check(near(img.pixel(Int(dx) + 100, 80), (0x3A, 0x86, 0xFF)), "the duplicated contents are drawn on the copy", fmt(img.pixel(Int(dx) + 100, 80)))
    }

    // MARK: 5. Re-parenting by dragging on the canvas

    static func reparenting() {
        let d = twoBoards()
        let c = canvas(d)
        AppModel.shared.tool = .move
        let mv = c.tool(for: .move)
        d.selectLayer(id(d, "Blue")!)
        // Blue (centre 100,80) onto B
        drag(mv, c, CGPoint(x: 100, y: 80), CGPoint(x: 560, y: 260))
        check(parentName(d, "Blue") == "B" && d.history.last?.name == "Move", "a layer dragged onto another artboard moves into it", "parent \(String(describing: parentName(d, "Blue"))), step \(d.history.last?.name ?? "")")
        check(bounds(d, "Blue") == CGRect(x: 500, y: 220, width: 120, height: 80), "and keeps the position it was dropped at", "\(String(describing: bounds(d, "Blue")))")
        d.undo()
        check(parentName(d, "Blue") == "A", "undo puts it back in its artboard")
        d.redo()
        check(parentName(d, "Blue") == "B", "redo moves it in again")
        // off every artboard: onto the pasteboard (top level, above its old artboard)
        d.selectLayer(id(d, "Blue")!)
        drag(mv, c, CGPoint(x: 560, y: 260), CGPoint(x: 560, y: 460))
        check(parentName(d, "Blue") == nil && d.state.layers.firstIndex { $0.name == "Blue" } == (d.state.layers.firstIndex { $0.name == "B" } ?? -9) + 1,
              "dragged off its artboard onto the pasteboard it leaves the artboard", "\(d.state.layers.map(\.name))")
        // a loose layer dragged onto an artboard
        d.selectLayer(id(d, "Loose")!)
        drag(mv, c, CGPoint(x: 810, y: 450), CGPoint(x: 150, y: 300))
        check(parentName(d, "Loose") == "A", "a layer from the pasteboard dragged onto an artboard goes into it")
        // a small move inside the same artboard changes nothing in the tree
        let tree = fingerprint(d.state)
        d.selectLayer(id(d, "Pink")!)
        drag(mv, c, CGPoint(x: 510, y: 110), CGPoint(x: 520, y: 120))
        check(parentName(d, "Pink") == "B" && fingerprint(d.state) == tree, "moving inside its artboard keeps the layer there")
        // half off its artboard (still overlapping, centre on the pasteboard): stays (Photoshop keeps it until it leaves)
        drag(mv, c, CGPoint(x: 520, y: 120), CGPoint(x: 400, y: 120))
        check(parentName(d, "Pink") == "B", "a layer still overlapping its artboard stays in it")
        // the Panel: dragging an artboard into a group lifts it back to the top level
        d.selectLayer(id(d, "Blue")!)
        AppActions.groupLayers()
        let g = d.activeLayerID!
        AppActions.moveLayer(id(d, "B")!, relativeTo: g, above: false, into: true)
        check(d.state.parentID(of: id(d, "B")!) == nil, "an artboard can't be nested: it stays at the top level")
        ArtboardOps.autoNest = false
        d.selectLayer(id(d, "Pink")!)
        drag(mv, c, CGPoint(x: 410, y: 120), CGPoint(x: 160, y: 200))
        check(parentName(d, "Pink") == "B", "auto-nesting can be switched off")
        ArtboardOps.autoNest = true
        c.document = nil
    }

    // MARK: 6. Pasteboard rendering

    static func pasteboardRendering(_ dir: URL) {
        let d = twoBoards()
        // B transparent, Blue pokes out of A (must stay clipped)
        ArtboardOps.setBackground(d, [id(d, "B")!], nil)
        d.updateLayer(id(d, "Blue")!) { $0.translate(dx: 200, dy: 0) }   // 240…360: past A's right edge (300)
        d.commit("setup")
        let c = canvas(d)
        let (f, img) = shot(c)
        writePNG(img, dir.appendingPathComponent("02_pasteboard.png"))
        check(near(framePixel(f, c, CGPoint(x: 350, y: 200)), pasteboard), "between the artboards: pasteboard", fmt(framePixel(f, c, CGPoint(x: 350, y: 200))))
        check(near(framePixel(f, c, CGPoint(x: 330, y: 80)), pasteboard), "a layer poking out of its artboard is clipped at the page edge", fmt(framePixel(f, c, CGPoint(x: 330, y: 80))))
        check(near(framePixel(f, c, CGPoint(x: 280, y: 80)), (0x3A, 0x86, 0xFF)), "…and drawn inside it")
        check(near(framePixel(f, c, CGPoint(x: 150, y: 300)), (255, 255, 255)), "white artboard: white page")
        let tp = framePixel(f, c, CGPoint(x: 650, y: 350))
        check(near(tp, (255, 255, 255)) || near(tp, (204, 204, 204)), "transparent artboard: checkerboard inside the page", fmt(tp))
        check(near(framePixel(f, c, CGPoint(x: 810, y: 450)), (0x2D, 0xC6, 0x53)), "a layer outside the artboards is drawn on the pasteboard")
        check(near(framePixel(f, c, CGPoint(x: 740, y: 300)), pasteboard), "the canvas outside the artboards (no layer there) is pasteboard")
        // a hidden artboard isn't shown at all
        d.updateLayer(id(d, "B")!) { $0.isVisible = false }
        d.commit("hide")
        let (f2, _) = shot(c)
        check(near(framePixel(f2, c, CGPoint(x: 650, y: 350)), pasteboard), "a hidden artboard disappears from the pasteboard")
        // a normal document still shows its canvas as one checkerboard page
        let n = Document.newBlank(width: 400, height: 300, background: nil, name: "plain")
        use(n)
        let c2 = canvas(n)
        let (f3, _) = shot(c2)
        let px = framePixel(f3, c2, CGPoint(x: 200, y: 150))
        check(near(px, (255, 255, 255)) || near(px, (204, 204, 204)), "documents without artboards keep the checkerboard canvas", fmt(px))
        c2.document = nil
        c.document = nil
    }

    // MARK: 7. Backgrounds and clipping (composite / export)

    static func backgroundsAndClipping() {
        let d = twoBoards()
        let a = id(d, "A")!, b = id(d, "B")!
        for (bg, name) in [(RGBA.white, "white"), (RGBA.black, "black"), (RGBA(hex: "7B2CBF")!, "custom")] {
            ArtboardOps.setBackground(d, [a], bg)
            let img = composite(d.state)
            check(near(img.pixel(250, 300), rgb(bg)), "artboard background \(name)", fmt(img.pixel(250, 300)))
        }
        ArtboardOps.setBackground(d, [a], nil)
        check(composite(d.state).pixel(250, 300).3 == 0, "artboard background transparent")
        // clipping: Pink grown past B's edges
        d.updateLayer(id(d, "Pink")!) { l in if var s = l.shape { s.geometry = .rectangle(CGRect(x: 360, y: -50, width: 400, height: 600), cornerRadius: 0); l.shape = s } }
        d.commit("grow")
        let img = composite(d.state)
        check(img.pixel(380, 200).3 == 0 && img.pixel(720, 200).3 == 0 && near(img.pixel(420, 10), (0xF7, 0x25, 0x85)), "artboard contents are clipped to the artboard",
              "\(fmt(img.pixel(380, 200))) \(fmt(img.pixel(720, 200)))")
        // each artboard exported alone keeps its own background and clip
        if let st = ArtboardExport.state(d.state, b) {
            let e = composite(st)
            check(st.width == 300 && st.height == 400 && near(e.pixel(150, 200), (0xF7, 0x25, 0x85)) && near(e.pixel(5, 395), (0xF7, 0x25, 0x85)), "artboard state is the artboard alone")
        }
    }

    // MARK: 8. Export

    static func exportPerArtboard(_ dir: URL) {
        let d = twoBoards()
        let ex = dir.appendingPathComponent("export")
        try? FileManager.default.removeItem(at: ex)
        var o = ArtboardExport.Options()
        o.prefix = "shot_"
        let files = (try? ArtboardExport.export(d.state, ids: nil, to: ex, options: o)) ?? []
        check(files.map(\.lastPathComponent).sorted() == ["shot_A.png", "shot_B.png"], "Artboards to Files: one PNG per artboard, with the prefix", files.map(\.lastPathComponent).joined(separator: ","))
        if let u = files.first(where: { $0.lastPathComponent == "shot_B.png" }), let img = NSImage(contentsOf: u)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let b = PixelBuffer(cgImage: img)
            check(img.width == 300 && img.height == 400 && near(b.pixel(250, 380), (0xFF, 0xF3, 0xB0)) && near(b.pixel(100, 100), (0xF7, 0x25, 0x85)), "the PNG is the artboard with its background and contents",
                  "\(img.width)×\(img.height) \(fmt(b.pixel(250, 380)))")
        }
        // background off, overlapping areas on (the loose layer overlapping B is moved over it)
        d.updateLayer(id(d, "Loose")!) { $0.translate(dx: -200, dy: -100) }   // 560…660 × 320…380: on B
        d.selectedLayerIDs = []; d.activeLayerID = nil   // (a selected layer moved onto B would go into it)
        d.commit("setup")
        o.prefix = ""; o.includeBackground = false
        let f2 = (try? ArtboardExport.export(d.state, ids: [id(d, "B")!], to: ex.appendingPathComponent("nobg"), options: o)) ?? []
        if let u = f2.first, let img = NSImage(contentsOf: u)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let b = PixelBuffer(cgImage: img)
            check(b.pixel(5, 395).3 == 0 && b.pixel(200, 350).3 == 0, "Include Background off: transparent outside the contents, content only (no overlapping layer)")
        } else { check(false, "background-less export written") }
        o.overlapping = true
        let f3 = (try? ArtboardExport.export(d.state, ids: [id(d, "B")!], to: ex.appendingPathComponent("overlap"), options: o)) ?? []
        if let u = f3.first, let img = NSImage(contentsOf: u)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            check(near(PixelBuffer(cgImage: img).pixel(200, 350), (0x2D, 0xC6, 0x53)), "Include Overlapping Areas: the loose layer over the artboard is exported too")
        }
        // JPEG with scale, PSD, TIFF
        o = ArtboardExport.Options(); o.format = .jpeg; o.scale = 2
        let fj = (try? ArtboardExport.export(d.state, ids: [id(d, "A")!], to: ex.appendingPathComponent("jpg"), options: o)) ?? []
        let ji = fj.first.flatMap { NSImage(contentsOf: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        check(ji?.width == 600 && ji?.height == 800, "JPEG at 2×", "\(ji?.width ?? 0)×\(ji?.height ?? 0)")
        o.format = .psd; o.scale = 1
        let fp = (try? ArtboardExport.export(d.state, ids: [id(d, "A")!], to: ex.appendingPathComponent("psd"), options: o)) ?? []
        if let u = fp.first, let back = try? DocumentIO.load(url: u) {
            check(back.state.width == 300 && back.state.height == 400 && back.state.layers.first?.artboard?.rect == CGRect(x: 0, y: 0, width: 300, height: 400), "PSD per artboard: an artboard document of its own")
        } else { check(false, "PSD per artboard written") }
        // PDF: one multi-page file, or one per artboard
        o = ArtboardExport.Options(); o.format = .pdf
        let pdfs = (try? ArtboardExport.export(d.state, ids: nil, to: ex.appendingPathComponent("pdf"), options: o)) ?? []
        let doc = pdfs.first.flatMap { PDFDocument(url: $0) }
        check(pdfs.count == 1 && doc?.pageCount == 2, "Artboards to PDF: one page per artboard", "\(pdfs.count) files, \(doc?.pageCount ?? 0) pages")
        if let p = doc?.page(at: 1) { check(abs(p.bounds(for: .mediaBox).width - 300) < 1 && abs(p.bounds(for: .mediaBox).height - 400) < 1, "PDF pages have the artboard's size") }
        o.multiPage = false
        let each = (try? ArtboardExport.export(d.state, ids: nil, to: ex.appendingPathComponent("pdf_each"), options: o)) ?? []
        check(each.count == 2 && each.allSatisfy { PDFDocument(url: $0)?.pageCount == 1 }, "Document per Artboard: one PDF each")
        // the dialogs are registered
        check(DialogRegistry.builders["artboardsToFiles"] != nil && DialogRegistry.builders["artboardsToPDF"] != nil, "Artboards to Files / PDF dialogs are registered")
        // whole-document export: the full canvas, transparent outside the artboards (PNG) / white (JPEG)
        let whole = ex.appendingPathComponent("whole.png")
        try? DocumentIO.export(d.state, to: whole, format: .png, quality: 1, scale: 1)
        if let img = NSImage(contentsOf: whole)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let b = PixelBuffer(cgImage: img)
            check(img.width == d.state.width && b.pixel(350, 200).3 == 0 && near(b.pixel(150, 300), (255, 255, 255)), "whole-document PNG: the canvas with the artboards, pasteboard transparent")
        }
    }

    // MARK: 9. PSD round trip

    static func psdRoundTrip(_ dir: URL) {
        let d = twoBoards()
        var c = ArtboardOps.makeLayer("Clear", rect: CGRect(x: 0, y: 450, width: 200, height: 40), background: nil)
        c.children = [shape("Bar", CGRect(x: 10, y: 455, width: 100, height: 20), "000000")]
        d.state.layers.append(c)
        d.state.layers.append(ArtboardOps.makeLayer("Dark", rect: CGRect(x: 250, y: 450, width: 100, height: 40), background: .black, preset: "iPhone SE"))
        d.commit("setup")
        let url = dir.appendingPathComponent("roundtrip.psd")
        do { try DocumentIO.export(d.state, to: url, format: .psd, quality: 1, scale: 1) } catch { check(false, "PSD written", "\(error)"); return }
        guard let back = try? DocumentIO.load(url: url) else { check(false, "PSD read back"); return }
        for name in ["A", "B", "Clear", "Dark"] {
            let x = d.state.allLayers.first { $0.name == name }?.artboard, y = back.state.allLayers.first { $0.name == name }?.artboard
            check(x?.rect == y?.rect && x?.background.map(rgb).map { "\($0)" } == y?.background.map(rgb).map { "\($0)" }, "PSD round trip keeps artboard “\(name)” (rect, background)",
                  "\(String(describing: y))")
        }
        check(back.state.allLayers.first { $0.name == "Dark" }?.artboard?.presetName == "iPhone SE", "the preset name survives (artboardPresetName)")
        check(back.state.layers.filter(\.isArtboard).count == 4 && back.state.allLayers.first { $0.name == "Bar" }.map { back.state.parentID(of: $0.id) == back.state.allLayers.first { $0.name == "Clear" }?.id } == true,
              "artboards come back at the top level with their layers")
        // the 'artb' descriptor matches Photoshop's keys
        if let data = try? Data(contentsOf: url) {
            let s = String(decoding: data, as: UTF8.self)
            check(["artboardRect", "artboardPresetName", "artboardBackgroundType", "guideIndeces"].allSatisfy { s.contains($0) } && s.contains("8BIMartb"), "the PSD stores 'artb' with Photoshop's keys")
        }
    }

    // MARK: 10. .lumen and older files

    static func nativeAndLegacy(_ dir: URL) {
        let d = twoBoards()
        ArtboardOps.setRect(d, id(d, "A")!, CGRect(x: 0, y: 0, width: 750, height: 1334), preset: "iPhone SE")
        let url = dir.appendingPathComponent("artboards.imagecrat")
        do {
            try DocumentIO.saveNative(d, to: url)
            let back = try DocumentIO.load(url: url)
            check(fingerprint(back.state) == fingerprint(d.state) && back.state.allLayers.first { $0.name == "A" }?.artboard?.presetName == "iPhone SE", ".imagecrat keeps artboards and their presets")
        } catch { check(false, ".imagecrat round trip", "\(error)") }
        // a file from before `presetName` existed
        struct OldArtboard: Codable { var rect: CGRect; var background: RGBA? }
        do {
            let old = try PropertyListEncoder().encode(OldArtboard(rect: CGRect(x: 1, y: 2, width: 3, height: 4), background: nil))
            let ab = try PropertyListDecoder().decode(Artboard.self, from: old)
            check(ab.rect == CGRect(x: 1, y: 2, width: 3, height: 4) && ab.background == nil && ab.presetName == nil, "artboards saved by older versions still open")
        } catch { check(false, "old artboard decodes", "\(error)") }
    }

    // MARK: 11. HTML export of an artboard, Fit Artboard

    static func htmlAndZoom() {
        let d = twoBoards()
        var o = HTMLExportOptions()
        o.artboardID = id(d, "B")
        let r = HTMLExporter.export(d.state, options: o)
        check(r.pageSize == CGSize(width: 300, height: 400) && r.css.contains("left: 60px"), "HTML export of an artboard: the page is the artboard", "\(r.pageSize)")
        let c = canvas(d)
        d.selectLayer(id(d, "Pink")!)
        check(ZoomController.isEnabled(.fitArtboard), "Fit Artboard on Screen is enabled for a layer in an artboard")
        ZoomController.run(.fitArtboard, animated: false)
        let v = c.docToView(CGRect(x: 400, y: 0, width: 300, height: 400))
        check(abs(v.midX - c.contentArea.midX) < 1 && abs(v.midY - c.contentArea.midY) < 1, "Fit Artboard on Screen centres the artboard", "\(v)")
        c.document = nil
    }

    // MARK: 12. Undo / redo of every command

    static func undoRedo() {
        let d = twoBoards()
        let a = id(d, "A")!, b = id(d, "B")!
        let steps: [(String, () -> Void)] = [
            ("New Artboard", { ArtboardOps.create(d, rect: CGRect(x: 0, y: 600, width: 200, height: 100)) }),
            ("Duplicate Artboard", { ArtboardOps.duplicate(d, [a]) }),
            ("Rename Artboard", { ArtboardOps.rename(d, b, "Renamed") }),
            ("Artboard Background", { ArtboardOps.setBackground(d, [a], .black) }),
            ("Resize Artboard", { ArtboardOps.setRect(d, b, CGRect(x: 400, y: 0, width: 900, height: 400)) }),
            ("Move Artboard", { ArtboardOps.move(d, a, to: CGPoint(x: -200, y: 0)) }),
            ("Align Artboards", { ArtboardOps.align(d, [a, b], .left) }),
            ("Delete Artboard", { ArtboardOps.delete(d, [b], keepContents: false) }),
            ("Ungroup Artboards", { ArtboardOps.ungroup(d, [a]) }),
            // (Auto-size Canvas keeps the canvas fitted; Canvas Size makes room for Fit Canvas to trim)
            ("Canvas Size", { AppActions.canvasSize(width: d.state.width + 200, height: d.state.height + 100, anchorX: 1, anchorY: 1, extension: nil) }),
            ("Fit Canvas to Artboards", { ArtboardActions.fitCanvas(d) }),
        ]
        for (name, f) in steps {
            let before = fingerprint(d.state), h = d.history.count
            f()
            let after = fingerprint(d.state)
            check(d.history.count == h + 1 && d.history.last?.name == name && after != before, "\(name): one history step", "\(d.history.count - h) steps, last \(d.history.last?.name ?? "")")
            d.undo()
            check(fingerprint(d.state) == before, "\(name): undo restores the document")
            d.redo()
            check(fingerprint(d.state) == after, "\(name): redo applies it again")
        }
    }

    // MARK: 13. New Document ▸ Artboards, conversion rules

    static func newDocumentAndRules() {
        let d = ArtboardActions.newDocument(width: 1080, height: 1920, resolution: 72, background: .white, name: "Phone")
        use(d)
        check(d.state.layers.count == 1 && d.state.layers[0].isArtboard && d.state.layers[0].name == "Artboard 1" && d.state.layers[0].children.map(\.name) == ["Layer 1"]
              && d.state.layers[0].artboard?.background == .white && d.activeLayer?.name == "Layer 1", "New Document with Artboards: “Artboard 1” holding “Layer 1”, no Background layer")
        let t = ArtboardActions.newDocument(width: 500, height: 400, resolution: 72, background: nil, name: "Clear")
        check(t.state.layers[0].artboard?.background == nil, "a transparent New Document gives a transparent artboard")
        // a normal document with layers outside the drawn artboard: they stay on the pasteboard
        let n = Document.newBlank(width: 1000, height: 600, background: nil, name: "loose")
        use(n)
        n.state.layers.append(shape("Far", CGRect(x: 800, y: 400, width: 100, height: 100), "FF0000"))
        n.state.layers.append(shape("Near", CGRect(x: 50, y: 50, width: 100, height: 100), "00FF00"))
        n.commit("setup")
        ArtboardTool.create(n, rect: CGRect(x: 0, y: 0, width: 300, height: 300))
        let ab = ArtboardOps.boards(n.state).first
        check(ab?.children.map(\.name) == ["Layer 1", "Near"] && n.state.layers.map(\.name) == ["Far", "Artboard 1"], "the first artboard takes the layers it covers; others stay on the pasteboard",
              "\(n.state.layers.map(\.name)) / \(ab?.children.map(\.name) ?? [])")
        check(n.state.width == 900 && n.state.height == 500, "the canvas keeps the room a layer on the pasteboard uses (and gives up the rest)", "\(n.state.width)×\(n.state.height)")
        // ungrouping the last artboard leaves artboard mode
        ArtboardOps.ungroup(n, [ab!.id])
        check(!ArtboardOps.isArtboardDocument(n.state) && n.state.layers.map(\.name) == ["Far", "Layer 1", "Near"], "ungrouping the last artboard turns it back into a normal document")
        // Fit Canvas to Artboards trims every side
        let f = twoBoards()
        f.state.layers.removeLast()   // no loose layer
        f.commit("drop loose")
        // (positions as typed into Properties: the document's own coordinates, which the canvas trim doesn't change)
        ArtboardOps.move(f, id(f, "A")!, to: ArtboardCoords.documentPoint(artboardPosition: CGPoint(x: 100, y: 50), f.state))
        ArtboardOps.move(f, id(f, "B")!, to: ArtboardCoords.documentPoint(artboardPosition: CGPoint(x: 500, y: 50), f.state))
        // Auto-size Canvas (default): the canvas follows on all four sides; artboard X / Y (Properties) stay 100, 50
        check(f.state.width == 700 && f.state.height == 400 && rect(f, "A")?.origin == .zero
              && ArtboardCoords.artboardPosition(rect(f, "A")!, f.state) == CGPoint(x: 100, y: 50) && ArtboardCoords.artboardPosition(rect(f, "B")!, f.state) == CGPoint(x: 500, y: 50),
              "Auto-size Canvas: moving artboards trims the canvas on every side, their X / Y stay put", "\(f.state.width)×\(f.state.height)")
        // Auto-size Canvas off: the old behaviour (the top-left margin stays)
        ArtboardSettings.shared.prefs.autoSizeCanvas = false
        defer { ArtboardSettings.shared.prefs.autoSizeCanvas = true }
        ArtboardOps.move(f, id(f, "A")!, to: CGPoint(x: 100, y: 50))
        ArtboardOps.move(f, id(f, "B")!, to: CGPoint(x: 500, y: 50))
        check(f.state.width == 800 && f.state.height == 450, "Auto-size Canvas off: moving artboards keeps the top-left margin (coordinates don't jump)", "\(f.state.width)×\(f.state.height)")
        ArtboardActions.fitCanvas(f)
        check(f.state.width == 700 && f.state.height == 400 && rect(f, "A")?.origin == .zero, "Fit Canvas to Artboards trims the canvas to the artboards", "\(f.state.width)×\(f.state.height) \(String(describing: rect(f, "A")))")
    }

    // MARK: 14. Snapshots (canvas, Layers panel, context menu, Properties, options bar)

    static func snapshots(_ dir: URL) {
        let d = twoBoards()
        ArtboardOps.setBackground(d, [id(d, "B")!], RGBA(hex: "FFF3B0")!)
        var t = TextContent(); t.text = "Artboard one"; t.fontSize = 28; t.position = CGPoint(x: 40, y: 200)
        d.state.updateLayer(id(d, "A")!) { $0.children.append(Layer(name: "Title", content: .text(t))) }
        d.commit("text")
        d.selectLayer(id(d, "B")!)
        let c = canvas(d, size: CGSize(width: 1000, height: 640))
        AppModel.shared.tool = .move
        writePNG(shot(c).1, dir.appendingPathComponent("03_canvas_move_tool.png"))
        AppModel.shared.tool = .artboard
        writePNG(shot(c).1, dir.appendingPathComponent("04_canvas_artboard_tool.png"))
        if let fixture = userFixture(dir), let ud = try? DocumentIO.load(url: fixture) {   // (the canvas holds its document weakly)
            use(ud)
            let u = canvas(ud, size: CGSize(width: 1000, height: 640))
            ud.selectLayer(ArtboardOps.boards(ud.state)[0].id)
            AppModel.shared.tool = .move
            writePNG(shot(u).1, dir.appendingPathComponent("05_user_psd_selected.png"))
            u.document = nil
        }
        use(d)
        AppModel.shared.tool = .move
        // Layers panel
        d.selectLayer(id(d, "Pink")!)
        let wp = UIFixesSelfTest.host(LayersPanelContent(doc: d), CGSize(width: 300, height: 360))
        UIFixesSelfTest.snapshot(wp, "06_layers_panel", dir)
        UIFixesSelfTest.close(wp)
        // context menu (drawn as a list: AppKit menus can't be captured offscreen)
        let items = ArtboardMenu.items(d, id(d, "B")!, rename: {})
        let wm = UIFixesSelfTest.host(MenuPreview(lines: ArtboardMenu.describe(items)), CGSize(width: 300, height: 470))
        UIFixesSelfTest.snapshot(wm, "07_context_menu", dir)
        UIFixesSelfTest.close(wm)
        // Properties
        d.selectLayer(id(d, "B")!)
        if let l = d.state.layer(id(d, "B")!), let ab = l.artboard {
            let wpr = UIFixesSelfTest.host(VStack(alignment: .leading, spacing: 8) { ArtboardProperties(doc: d, layerID: l.id, ab: ab) }.padding(10), CGSize(width: 280, height: 260))
            UIFixesSelfTest.snapshot(wpr, "08_properties", dir)
            UIFixesSelfTest.close(wpr)
        }
        // options bar (two artboards selected: alignment and spacing)
        d.selectedLayerIDs = [id(d, "A")!, id(d, "B")!]
        d.activeLayerID = id(d, "B")
        AppModel.shared.tool = .artboard
        let wo = UIFixesSelfTest.host(HStack(spacing: 8) { ArtboardOptions() }.padding(.horizontal, 8), CGSize(width: 1100, height: 34))
        UIFixesSelfTest.snapshot(wo, "09_options_bar", dir)
        UIFixesSelfTest.close(wo)
        // New Document dialog
        let wn = UIFixesSelfTest.host(NewDocumentDialog(), CGSize(width: 540, height: 420))
        UIFixesSelfTest.snapshot(wn, "10_new_document", dir)
        UIFixesSelfTest.close(wn)
        AppModel.shared.tool = .move
        c.document = nil
        print("artboards2: wrote snapshots to \(dir.path)")
    }

    struct MenuPreview: View {
        let lines: [String]
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    if l.trimmingCharacters(in: .whitespaces) == "—" {
                        Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 4)
                    } else {
                        Text(l).font(.system(size: 13)).foregroundStyle(l.contains("(disabled)") ? Theme.textFaint : Theme.text).frame(height: 20)
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.2)))
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
