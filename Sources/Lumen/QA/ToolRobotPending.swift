import AppKit
import CoreImage
import ImageCratCore

/// Pending sessions × commands that arrive in the middle of them.
///
/// Rule (Photoshop-like): a pending edit is applied first, stays open when the command has nothing to do with it, or is
/// cleanly cancelled when applying makes no sense — it is never silently lost with stale handles left behind, and the
/// document is never left with half of it recorded.
///
/// Every combination is run three times on fresh documents:
///   A  = confirm the session, then the command            ("applied first")
///   C  = the command, then the session, then confirm      ("kept / independent")
///   B  = the command alone                                ("cancelled")
///   T  = session pending → command (through the app's hook, or bypassing it) → confirm whatever is still pending
/// T must look like A (or C); B is only acceptable where listed.
enum QAPending {
    typealias R = ToolRobot

    struct Session {
        var name: String
        var fixture: String
        var tool: ToolKind
        var selection: (() -> PixelBuffer)? = nil
        /// Brings the tool into its pending state.
        var begin: (R, Document, QAFixture) -> Void
        /// What the user does to confirm it.
        var confirm: (R, Document) -> Void
        var pending: (R) -> Bool
        /// `.commit` policy sessions must be applied before hooked commands; others may stay open.
        var commits = true
        var midDrag = false
    }

    struct Command {
        var name: String
        /// Top-level menu the command lives in (the hook applies pending edits by menu); nil = no menu.
        var menu: String? = nil
        var panel = false
        /// The command destroys or replaces what the session works on: losing the edit is acceptable when the command
        /// bypasses the hooks.
        var destructive = false
        var run: (R, Document, QAFixture) -> Void
    }

    static func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x + 0.37, y: y + 0.41) }
    static func move(_ r: R) -> MoveTool { r.toolOf(.move, MoveTool.self)! }
    static let selRect = CGRect(x: 80, y: 50, width: 50, height: 40)

    static func typed(_ r: R, _ s: String) {
        if let tv = r.window.firstResponder as? NSTextView { tv.insertText(s, replacementRange: tv.selectedRange()) }
    }

    // MARK: Sessions

    static func sessions() -> [Session] {
        var out: [Session] = []
        func transform(_ name: String, _ fixture: String, selection: (() -> PixelBuffer)? = nil) {
            out.append(Session(name: name, fixture: fixture, tool: .move, selection: selection, begin: { r, d, f in
                AppActions.freeTransform()
                guard let s = move(r).session else { return }
                let q = s.quad
                let target = q.tl + (q.br - q.tl) * 1.3
                r.down(q.br); r.drag(q.br.lerp(target, 0.5)); r.drag(target); r.up(target)
            }, confirm: { r, d in move(r).commit() }, pending: { move($0).isBusy }))
        }
        transform("transform-raster", "raster")
        transform("transform-text", "text")
        transform("transform-smart", "smart")
        transform("transform-shape", "shape")
        transform("transform-multi", "multi")
        transform("transform-float", "raster", selection: { QAFixtures.rectSelection(selRect) })
        out.append(Session(name: "transform-selection", fixture: "raster", tool: .move, selection: { QAFixtures.rectSelection(selRect) }, begin: { r, d, f in
            AppActions.transformSelection()
            guard let s = move(r).session else { return }
            let q = s.quad
            r.down(q.br); r.drag(q.br + CGPoint(x: 20, y: 15)); r.up(q.br + CGPoint(x: 20, y: 15))
        }, confirm: { r, d in move(r).commit() }, pending: { move($0).isBusy }))
        out.append(Session(name: "warp", fixture: "raster", tool: .move, begin: { r, d, f in
            AppActions.warp()
            guard let s = move(r).interactive as? SplitWarpSession, let p = s.control.first else { return }
            r.down(p); r.drag(p + CGPoint(x: -12, y: -9)); r.up(p + CGPoint(x: -12, y: -9))
        }, confirm: { r, d in move(r).commit() }, pending: { move($0).isBusy }))
        out.append(Session(name: "puppet-warp", fixture: "raster", tool: .move, begin: { r, d, f in
            AppActions.puppetWarp()
            r.click(P(70, 50)); r.click(P(150, 50)); r.down(P(110, 100)); r.drag(P(115, 118)); r.up(P(115, 118))
        }, confirm: { r, d in move(r).commit() }, pending: { move($0).isBusy }))
        out.append(Session(name: "perspective-warp", fixture: "raster", tool: .move, begin: { r, d, f in
            AppActions.perspectiveWarp()
            guard let s = move(r).interactive as? PerspectiveWarpSession else { return }
            s.mode = .warp
            let p = s.warped[0]
            r.down(p); r.drag(p + CGPoint(x: 14, y: 10)); r.up(p + CGPoint(x: 14, y: 10))
        }, confirm: { r, d in move(r).commit() }, pending: { move($0).isBusy }))
        out.append(Session(name: "content-aware-scale", fixture: "raster", tool: .move, begin: { r, d, f in
            AppActions.contentAwareScale()
            guard let s = move(r).interactive as? ContentAwareScaleSession else { return }
            let p = CGPoint(x: s.target.maxX, y: s.target.midY)
            r.down(p); r.drag(p + CGPoint(x: -20, y: 0)); r.up(p + CGPoint(x: -20, y: 0))
        }, confirm: { r, d in move(r).commit() }, pending: { move($0).isBusy }))
        // crop family: the box stays open unless the canvas changes
        out.append(Session(name: "crop", fixture: "raster", tool: .crop, begin: { r, d, f in
            r.down(CGPoint(x: 240, y: 160)); r.drag(CGPoint(x: 200, y: 130)); r.up(CGPoint(x: 200, y: 130))
        }, confirm: { r, d in r.canvas.tool(for: .crop).commit() }, pending: { $0.canvas.tool(for: .crop).isBusy }, commits: false))
        out.append(Session(name: "perspective-crop", fixture: "raster", tool: .perspectiveCrop, begin: { r, d, f in
            r.dragLine(CGPoint(x: 30, y: 20), CGPoint(x: 200, y: 130), steps: 3)
            r.down(CGPoint(x: 200, y: 20)); r.drag(CGPoint(x: 185, y: 32)); r.up(CGPoint(x: 185, y: 32))
        }, confirm: { r, d in r.canvas.tool(for: .perspectiveCrop).commit() }, pending: { $0.canvas.tool(for: .perspectiveCrop).isBusy }, commits: false))
        // type
        out.append(Session(name: "text-new", fixture: "raster", tool: .text, begin: { r, d, f in
            r.click(P(30, 140)); typed(r, "New")
        }, confirm: { r, d in r.canvas.tool(for: .text).commit() }, pending: { $0.canvas.tool(for: .text).isBusy }))
        out.append(Session(name: "text-edit", fixture: "text", tool: .text, begin: { r, d, f in
            guard let t = d.state.layer(f.active)?.text else { return }
            r.click(TextRenderer.docQuad(t).center); typed(r, "Edit")
        }, confirm: { r, d in r.canvas.tool(for: .text).commit() }, pending: { $0.canvas.tool(for: .text).isBusy }))
        out.append(Session(name: "text-box", fixture: "raster", tool: .text, begin: { r, d, f in
            r.dragLine(P(20, 110), P(140, 150), steps: 3); typed(r, "Paragraph of text")
        }, confirm: { r, d in r.canvas.tool(for: .text).commit() }, pending: { $0.canvas.tool(for: .text).isBusy }))
        out.append(Session(name: "text-on-path", fixture: "shape", tool: .text, begin: { r, d, f in
            r.click(CGPoint(x: QAFixtures.box.midX, y: QAFixtures.box.minY)); typed(r, "Path")
        }, confirm: { r, d in r.canvas.tool(for: .text).commit() }, pending: { $0.canvas.tool(for: .text).isBusy }))
        out.append(Session(name: "type-mask", fixture: "raster", tool: .typeMaskHorizontal, begin: { r, d, f in
            r.click(P(30, 140)); typed(r, "MASK")
        }, confirm: { r, d in r.canvas.tool(for: .typeMaskHorizontal).commit(); r.pump(0.01) }, pending: { $0.canvas.tool(for: .typeMaskHorizontal).isBusy }))
        // multi-click tools: every click is recorded; the unfinished outline is the pending part
        out.append(Session(name: "pen", fixture: "raster", tool: .pen, begin: { r, d, f in
            r.click(P(30, 20)); r.click(P(120, 24))
        }, confirm: { r, d in r.click(P(130, 90)); r.key(R.kReturn, "\r") }, pending: { _ in false }, commits: false))
        out.append(Session(name: "curvature-pen", fixture: "raster", tool: .curvaturePen, begin: { r, d, f in
            r.click(P(30, 20)); r.click(P(120, 24))
        }, confirm: { r, d in r.click(P(130, 90)); r.key(R.kReturn, "\r") }, pending: { $0.canvas.tool(for: .curvaturePen).isBusy }, commits: false))
        out.append(Session(name: "polygon-lasso", fixture: "raster", tool: .polygonLasso, begin: { r, d, f in
            r.click(P(30, 20)); r.click(P(120, 24)); r.click(P(130, 90))
        }, confirm: { r, d in r.key(R.kReturn, "\r") }, pending: { $0.canvas.tool(for: .polygonLasso).isBusy }, commits: false))
        out.append(Session(name: "magnetic-lasso", fixture: "raster", tool: .magneticLasso, begin: { r, d, f in
            r.click(P(60, 40)); r.move(P(110, 40)); r.click(P(160, 40)); r.move(P(160, 80)); r.click(P(160, 110))
        }, confirm: { r, d in r.key(R.kReturn, "\r") }, pending: { $0.canvas.tool(for: .magneticLasso).isBusy }, commits: false))
        out.append(Session(name: "clone-source", fixture: "raster", tool: .cloneStamp, begin: { r, d, f in
            r.mods = [.option]; r.click(P(120, 70)); r.mods = []
        }, confirm: { r, d in r.dragLine(P(75, 100), P(95, 100), steps: 3) }, pending: { _ in false }, commits: false))
        // the mouse is still down
        func drag(_ name: String, _ fixture: String, _ tool: ToolKind, selection: (() -> PixelBuffer)? = nil, from a: CGPoint = P(80, 60), to b: CGPoint = P(140, 95)) {
            out.append(Session(name: "drag-\(name)", fixture: fixture, tool: tool, selection: selection, begin: { r, d, f in
                if tool == .move { AppModel.shared.moveShowTransform = false }
                r.down(a); r.drag(a.lerp(b, 0.4)); r.drag(a.lerp(b, 0.7))
            }, confirm: { r, d in r.drag(b); r.up(b) }, pending: { _ in false }, commits: false, midDrag: true))
        }
        drag("move", "raster", .move)
        drag("move-float", "raster", .move, selection: { QAFixtures.rectSelection(selRect) }, from: P(100, 65), to: P(150, 95))
        drag("brush", "raster", .brush)
        drag("eraser", "raster", .eraser)
        drag("gradient", "raster", .gradient)
        drag("smudge", "raster", .smudge)
        drag("marquee", "raster", .marqueeRect)
        drag("lasso", "raster", .lasso)
        drag("selection-brush", "raster", .selectionBrush)
        drag("quick-select", "raster", .quickSelect)
        drag("rectangle", "raster", .rectangle)
        drag("frame", "empty", .frame)
        drag("slice", "raster", .slice)
        drag("artboard-move", "artboard", .artboard, from: P(100, 70), to: P(130, 90))
        drag("path-select", "shape", .pathSelect, from: P(100, 70), to: P(130, 90))
        drag("text-box", "raster", .text)
        drag("remove", "raster", .removeTool)
        return out
    }

    // MARK: Commands

    static func commands() -> [Command] {
        var c: [Command] = []
        // (`destructive` also covers commands that restructure the layer stack: bypassing the hooks, they drop a session)
        c.append(Command(name: "duplicate", menu: "Layer", destructive: true) { _, _, _ in AppActions.duplicateLayers() })
        c.append(Command(name: "delete", menu: "Layer", destructive: true) { _, _, _ in AppActions.deleteLayers() })
        c.append(Command(name: "smart-object", menu: "Layer", destructive: true) { _, _, _ in AppActions.convertToSmartObject() })
        c.append(Command(name: "rasterize", menu: "Layer", destructive: true) { _, _, _ in AppActions.rasterizeLayer() })
        c.append(Command(name: "add-mask", menu: "Layer") { _, _, _ in AppActions.addMask(.revealAll) })
        c.append(Command(name: "group", menu: "Layer", destructive: true) { _, _, _ in AppActions.groupLayers() })
        c.append(Command(name: "new-layer", menu: "Layer", destructive: true) { _, _, _ in AppActions.newLayer() })
        c.append(Command(name: "blend-mode", panel: true) { _, d, _ in
            guard let id = d.activeLayerID else { return }
            d.updateLayer(id) { $0.blendMode = .multiply; $0.opacity = 0.8 }
            d.commit("Blend Mode")
        })
        c.append(Command(name: "reorder", panel: true, destructive: true) { _, d, _ in
            guard let id = d.activeLayerID, let bottom = d.state.layers.first?.id, id != bottom else { return }
            AppActions.moveLayer(id, relativeTo: bottom, above: false)
        })
        c.append(Command(name: "select-other-layer", panel: true) { _, d, _ in
            if let bottom = d.state.layers.first?.id { d.selectLayer(bottom) }
        })
        c.append(Command(name: "select-all", menu: "Select") { _, _, _ in AppActions.selectAll() })
        c.append(Command(name: "deselect", menu: "Select") { _, _, _ in AppActions.deselect() })
        c.append(Command(name: "inverse", menu: "Select") { _, _, _ in AppActions.inverseSelection() })
        c.append(Command(name: "undo", menu: "Edit") { _, _, _ in AppActions.undo() })
        c.append(Command(name: "redo", menu: "Edit") { _, _, _ in AppActions.redo() })
        c.append(Command(name: "history-back", panel: true, destructive: true) { _, d, _ in d.undo() })
        c.append(Command(name: "save", menu: "File") { _, d, _ in
            d.fileURL = QA.out.appendingPathComponent("qa_pending_save.imagecrat")
            AppActions.save()
        })
        c.append(Command(name: "tool-switch") { r, _, _ in r.select(AppModel.shared.tool == .hand ? .zoom : .hand) })
        c.append(Command(name: "image-size", menu: "Image", destructive: true) { _, _, _ in AppActions.imageSize(width: 180, height: 120, resolution: 72, scaleStyles: true) })
        c.append(Command(name: "canvas-size", menu: "Image", destructive: true) { _, _, _ in AppActions.canvasSize(width: 300, height: 200, anchorX: 1, anchorY: 1, extension: nil) })
        c.append(Command(name: "rotate-canvas", menu: "Image", destructive: true) { _, _, _ in AppActions.rotateCanvas(90) })
        c.append(Command(name: "crop-command", menu: "Image", destructive: true) { _, _, _ in AppActions.crop(to: IRect(x: 20, y: 10, width: 200, height: 140), deletePixels: false) })
        c.append(Command(name: "grayscale", menu: "Image") { _, _, _ in AppActions.convertMode(.grayscale) })
        c.append(Command(name: "new-guide", menu: "View") { _, d, _ in
            d.state.guides.append(Guide(isVertical: true, position: 100))
            d.commit("New Guide")
        })
        c.append(Command(name: "delete-key") { r, _, _ in r.key(R.kDelete, "\u{7f}") })
        c.append(Command(name: "arrow-key") { r, _, _ in r.key(R.kRight, "") })
        return c
    }

    // MARK: Running

    struct Outcome {
        var comp: PixelBuffer
        var tree: String
        var selection: CGRect?
        /// Fingerprint of the layer the session worked on (nil when it no longer exists).
        var target: Int?
    }

    static func outcome(_ d: Document, _ f: QAFixture? = nil) -> Outcome {
        Outcome(comp: QAMeasure.composite(d.state), tree: QAMeasure.tree(d.state), selection: d.state.selection?.opaqueBounds(threshold: 127)?.cgRect,
                target: f?.active.flatMap { d.state.layer($0) }.map { QAMeasure.layerPrint($0) })
    }

    static func same(_ a: Outcome, _ b: Outcome) -> Bool {
        guard QAMeasure.diff(a.comp, b.comp) < 0.6 else { return false }
        func layerCount(_ s: String) -> Int { s.filter { $0 == ":" }.count }
        guard layerCount(a.tree) == layerCount(b.tree) else { return false }
        switch (a.selection, b.selection) {
        case (nil, nil): return true
        case (let x?, let y?): return abs(x.minX - y.minX) < 2 && abs(x.minY - y.minY) < 2 && abs(x.maxX - y.maxX) < 2 && abs(x.maxY - y.maxY) < 2
        default: return false
        }
    }

    static func fresh(_ s: Session, _ fixtures: [String: QAFixture]) -> (R, Document, QAFixture) {
        QAScenarios.resetToolSettings()
        let r = R()
        let f = fixtures[s.fixture]!
        var st = f.state
        if let sel = s.selection { st.selection = sel() }
        let d = r.open(st, name: s.fixture, view: .identity)
        f.apply(to: d)
        r.select(.hand); r.select(s.tool)
        return (r, d, f)
    }

    static func hook(_ c: Command) {
        if let m = c.menu { PendingEdits.willRunMenuCommand(topLevel: m) } else if c.panel { PendingEdits.willClickPanel() }
    }

    static func run() {
        var fixtures: [String: QAFixture] = [:]
        for f in QAFixtures.all(QA.out) { fixtures[f.name] = f }
        let cmds = commands()
        for s in sessions() {
            if s.midDrag {
                // nothing but the mouse can act while the button is down
                QA.scenario("pending/\(s.name)/shortcuts-ignored") { shortcutsMidDrag(s, fixtures) }
            } else {
                for c in cmds {
                    for hooked in [true, false] {
                        if !hooked && c.menu == nil && !c.panel { continue }      // no hook exists for it: one run
                        // standard run: the hook-bypassing path for a representative set of commands
                        if !hooked && !QAScenarios.full && !["duplicate", "delete", "smart-object", "select-all", "history-back", "new-guide", "canvas-size", "save", "blend-mode", "select-other-layer"].contains(c.name) { continue }
                        if QAScenarios.quick {
                            if !hooked && !["duplicate", "delete", "new-guide", "history-back"].contains(c.name) { continue }
                            if hooked && !["duplicate", "delete", "smart-object", "rasterize", "add-mask", "select-all", "undo", "history-back", "save", "tool-switch",
                                           "image-size", "new-guide", "delete-key", "select-other-layer"].contains(c.name) { continue }
                        }
                        QA.scenario("pending/\(s.name)/\(c.name)/\(hooked ? "hooked" : "direct")") { combo(s, c, hooked: hooked, fixtures) }
                    }
                }
            }
            QA.scenario("pending/\(s.name)/document-switch") { documentSwitch(s, fixtures, close: false) }
            QA.scenario("pending/\(s.name)/document-close") { documentSwitch(s, fixtures, close: true) }
        }
        extras(fixtures)
    }

    /// Keys that belong to the session itself (typed into the editor, remove a pin / a point).
    static func keyIsSessionInput(_ s: Session, _ c: Command) -> Bool {
        guard c.name == "delete-key" || c.name == "arrow-key" else { return false }
        return s.tool == .text || s.name == "type-mask" || s.name == "puppet-warp" || s.name.hasSuffix("lasso") || s.name.hasSuffix("pen")
    }

    static func combo(_ s: Session, _ c: Command, hooked: Bool, _ fixtures: [String: QAFixture]) {
        if keyIsSessionInput(s, c) { return }
        // A: applied first
        var (r, d, f) = fresh(s, fixtures)
        s.begin(r, d, f); s.confirm(r, d)
        c.run(r, d, f)
        r.select(.hand)
        let A = outcome(d, f)
        r.closeAll()
        // B: the command alone
        (r, d, f) = fresh(s, fixtures)
        c.run(r, d, f)
        r.select(.hand)
        let B = outcome(d, f)
        r.closeAll()

        // T: the command arrives while the session is pending
        (r, d, f) = fresh(s, fixtures)
        let start = QASnapshot(d)
        s.begin(r, d, f)
        let wasPending = s.pending(r)
        if hooked { hook(c) }
        c.run(r, d, f)
        r.drawOverlay()
        let still = s.pending(r)
        if still {
            // whatever is still open must still sit on the document
            let mt = move(r)
            if AppModel.shared.tool == .move, let sess = mt.session { QA.check(sess.matchesDocument, "a transform left open still fits the document") }
            if AppModel.shared.tool == .move, let i = mt.interactive { QA.check(i.matchesDocument, "a warp left open still fits the document") }
        }
        if still || (!s.commits && AppModel.shared.tool == s.tool) { s.confirm(r, d) }
        r.drawOverlay()
        r.select(.hand)
        if s.name == "type-mask" { r.pump(0.01) }
        let T = outcome(d, f)
        // "lost": the document looks like the command alone and the layer the session worked on is untouched
        let asA = same(T, A), asB = same(T, B) && T.target == B.target && T.tree == B.tree
        let label = "\(s.name) + \(c.name) (\(hooked ? "through the app's hook" : "bypassing the hooks"))"
        let documentMenu = c.menu.map { !["Edit", "Type", "View", "Window", "Help"].contains($0) } ?? false
        if s.commits && hooked && wasPending && documentMenu {
            // Photoshop's "apply the transformation first"
            QA.check(asA, "\(label): the pending edit is applied first", "A \(A.tree) | T \(T.tree) | diffA \(String(format: "%.2f", QAMeasure.diff(T.comp, A.comp))) diffB \(String(format: "%.2f", QAMeasure.diff(T.comp, B.comp)))")
        } else if asB && !asA && wasPending {
            // The edit is gone. Fine when the command destroyed what it was about, undid it, or (crop boxes) the tool
            // was left; never otherwise.
            let cropLeft = (s.name == "crop" || s.name == "perspective-crop") && c.name == "tool-switch"
            QA.check(c.destructive || ["undo", "history-back", "delete-key"].contains(c.name) || cropLeft, "\(label): the pending edit is not silently lost",
                     "result equals the command alone: \(T.tree)")
        }
        QAInvariant.idle(r, label)
        QA.check(!d.state.allLayers.contains { $0.text.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false } || !hooked || !documentMenu,
                 "\(label): no empty type layer is left in the document", T.tree)
        if c.name == "save", let url = d.fileURL, let back = try? DocumentIO.load(url: url) {
            // what was saved is a consistent document; for "apply first" sessions it includes the pending edit
            let saved = outcome(back)
            QA.check(QAMeasure.diff(saved.comp, A.comp) < 0.6 || QAMeasure.diff(saved.comp, B.comp) < 0.6 || QAMeasure.diff(saved.comp, T.comp) < 0.6, "\(label): the saved file is a consistent document")
            if s.commits && wasPending { QA.check(QAMeasure.diff(saved.comp, A.comp) < 0.6, "\(label): saving includes the pending edit") }
            try? FileManager.default.removeItem(at: url)
        }
        QAInvariant.undoRedo(r, from: start, label)
        if let a = d.activeLayerID { QAInvariant.handlesMatchContent(d, a, label) }
        r.closeAll()
    }

    /// While the mouse button is down, shortcuts are ignored: the drag ends exactly as if nothing had been pressed.
    static func shortcutsMidDrag(_ s: Session, _ fixtures: [String: QAFixture]) {
        var (r, d, f) = fresh(s, fixtures)
        s.begin(r, d, f); s.confirm(r, d)
        r.select(.hand)
        let plain = outcome(d)
        let plainSteps = d.history.map(\.name)
        r.closeAll()
        (r, d, f) = fresh(s, fixtures)
        let start = QASnapshot(d)
        s.begin(r, d, f)
        QA.check(r.canvas.isTrackingMouse, "\(s.name): the canvas knows a drag is in progress")
        let tool = AppModel.shared.tool
        r.key(9, "v"); r.key(11, "b"); r.key(7, "x"); r.key(R.kDelete, "\u{7f}"); r.key(R.kRight, "")
        // ⌘Z / ⌘J / ⌘S must not reach the menus while the button is down
        for (code, ch) in [(UInt16(6), "z"), (38, "j"), (1, "s")] {
            QA.check(r.routerSwallows(code, ch, [.command]), "\(s.name): ⌘\(ch.uppercased()) is ignored while the mouse button is down")
        }
        QA.check(AppModel.shared.tool == tool, "\(s.name): tool shortcuts are ignored while the mouse button is down", AppModel.shared.tool.rawValue)
        s.confirm(r, d)
        r.select(.hand)
        QA.check(same(outcome(d), plain) && d.history.map(\.name) == plainSteps, "\(s.name): keys pressed during the drag change nothing",
                 "\(d.history.map(\.name)) vs \(plainSteps)")
        QAInvariant.idle(r, s.name)
        QAInvariant.undoRedo(r, from: start, s.name)
        r.closeAll()
    }

    static func documentSwitch(_ s: Session, _ fixtures: [String: QAFixture], close: Bool) {
        let (r, d, f) = fresh(s, fixtures)
        let start = QASnapshot(d)
        s.begin(r, d, f)
        if close {
            r.close(d)
            QA.check(!r.canvas.tool(for: s.tool).isBusy, "\(s.name): closing the document ends the session")
            QA.check(r.canvas.subviews.filter { $0 is NSTextView }.isEmpty, "\(s.name): no editor view left after closing")
            if s.midDrag { s.confirm(r, d) }        // the mouse-up still arrives
            r.select(.hand)
            return
        }
        let other = r.open(QAFixtures.base(), name: "other")
        let so = QASnapshot(other)
        QA.check(!r.canvas.tool(for: s.tool).isBusy, "\(s.name): switching documents ends the session")
        if s.midDrag { s.confirm(r, d) }
        r.drawOverlay()
        r.select(.hand)
        QA.check(QAMeasure.fingerprint(other.state) == so.print && other.historyIndex == so.historyIndex, "\(s.name): the other document is not touched by the session",
                 "\(other.history.map(\.name)) \(QAMeasure.tree(other.state))")
        QA.check(other.contentOverrides.isEmpty && other.displayOverride == nil && other.hiddenLayers.isEmpty, "\(s.name): no preview leaks into the other document")
        r.activate(d)
        r.drawOverlay()
        QAInvariant.idle(r, "\(s.name), back in its document")
        QAInvariant.undoRedo(r, from: start, "\(s.name), back in its document")
        r.closeAll()
    }

    // MARK: Special cases

    static func extras(_ fixtures: [String: QAFixture]) {
        // Guides pulled out of the ruler while a transform is pending (a very common Photoshop habit)
        for name in ["transform-raster", "transform-float", "transform-text", "warp"] {
            guard let s = sessions().first(where: { $0.name == name }) else { continue }
            QA.scenario("pending/\(name)/guide-from-ruler") {
                let (r, d, f) = fresh(s, fixtures)
                var v = QAView.identity; v.rulers = true
                r.setView(v)
                s.begin(r, d, f)
                let live = r.liveComposite()
                r.downView(CGPoint(x: 8, y: 200)); r.dragView(CGPoint(x: 100, y: 200)); r.upView(r.canvas.docToView(CGPoint(x: 30, y: 100)))
                QA.check(d.state.guides.count == 1, "the guide is created")
                if name == "transform-float" {
                    // the floating pixels are cut out of their layer: they are put back (the move is applied) before the
                    // guide step is recorded
                    QA.check(!s.pending(r), "\(name): a floating selection is applied before another step is recorded")
                } else {
                    QA.check(s.pending(r), "\(name): a guide dragged from the ruler does not end the pending edit")
                    QA.check(QAMeasure.diff(r.liveComposite(), live) < 0.05, "\(name): the preview is unchanged by the new guide", String(format: "%.3f", QAMeasure.diff(r.liveComposite(), live)))
                    s.confirm(r, d)
                }
                r.select(.hand)
                // (the preview of scaled type is a scaled bitmap, the result is re-set type: allow for that)
                QA.check(QAMeasure.diff(QAMeasure.composite(d.state), live) < (name == "transform-text" ? 1.6 : 0.8), "\(name): confirming afterwards applies what was previewed",
                         String(format: "%.3f", QAMeasure.diff(QAMeasure.composite(d.state), live)))
                QAInvariant.idle(r, name)
                // no history state may contain the hole of the floating pixels without them
                for (i, h) in d.history.enumerated() where i > 0 {
                    let c = QAMeasure.composite(h.state)
                    QA.check(QAMeasure.diff(c, QAMeasure.composite(d.history[0].state)) < 0.01 || QAMeasure.diff(c, QAMeasure.composite(d.state)) < 0.8,
                             "\(name): history step '\(h.name)' is a consistent document")
                }
                r.closeAll()
            }
        }
        // Space-bar hand while a transform is pending, then a menu command
        QA.scenario("pending/transform-text/space-then-command") {
            guard let s = sessions().first(where: { $0.name == "transform-text" }) else { return }
            let (r, d, f) = fresh(s, fixtures)
            s.begin(r, d, f)
            let scaled = r.liveComposite()
            r.key(R.kSpace, " ")
            PendingEdits.willRunMenuCommand(topLevel: "Layer")
            AppActions.convertToSmartObject()
            QA.check(QAMeasure.diff(QAMeasure.composite(d.state), scaled) < 1.6, "the pending resize is applied even while Space shows the hand tool",
                     String(format: "%.2f", QAMeasure.diff(QAMeasure.composite(d.state), scaled)))
            let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: r.window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: R.kSpace)!
            _ = KeyRouter.handle(up)
            QAInvariant.idle(r, "after")
            r.closeAll()
        }
        // Arrow keys while a mesh session is pending must not nudge the layer away from under it
        for name in ["puppet-warp", "perspective-warp", "content-aware-scale", "warp"] {
            guard let s = sessions().first(where: { $0.name == name }) else { continue }
            QA.scenario("pending/\(name)/arrow-keys") {
                let (r, d, f) = fresh(s, fixtures)
                s.begin(r, d, f)
                let h = d.historyIndex
                r.key(R.kRight, ""); r.key(R.kDown, "")
                QA.check(s.pending(r) && d.historyIndex == h, "\(name): arrow keys do not discard the pending warp", "pending \(s.pending(r)), history \(d.history.map(\.name))")
                s.confirm(r, d); r.select(.hand)
                QAInvariant.idle(r, name)
                r.closeAll()
            }
        }
        // Mesh sessions are refused on locked layers (like Free Transform)
        for fxName in ["locked-all", "locked-position", "locked-pixels"] {
            QA.scenario("pending/warp-refused/\(fxName)") {
                QAScenarios.resetToolSettings()
                let r = R()
                let f = fixtures[fxName]!
                let d = r.open(f.state, name: fxName)
                f.apply(to: d)
                let s = QASnapshot(d)
                for (name, start) in [("Warp", AppActions.warp), ("Puppet Warp", AppActions.puppetWarp), ("Perspective Warp", AppActions.perspectiveWarp), ("Content-Aware Scale", AppActions.contentAwareScale)] as [(String, () -> Void)] {
                    start()
                    QA.check(!move(r).isBusy, "\(name) does not start on a \(fxName) layer")
                    move(r).cancel()
                }
                AppActions.freeTransform()
                QA.check(!move(r).isBusy || fxName == "locked-pixels", "Free Transform does not start on a \(fxName) layer")
                move(r).cancel()
                QA.check(QAMeasure.fingerprint(d.state) == s.print && d.historyIndex == s.historyIndex, "the \(fxName) layer is unchanged")
                r.closeAll()
            }
        }
        // Blur Gallery pins: its dialog owns OK / Cancel; other commands leave it alone
        QA.scenario("pending/blur-gallery") {
            QAScenarios.resetToolSettings()
            let r = R()
            let f = fixtures["raster"]!
            let d = r.open(f.state, name: "blur")
            f.apply(to: d)
            let start = QASnapshot(d)
            AppActions.startBlurGallery(.fieldBlur)
            guard let st = AppActions.blurGallery else { QA.check(false, "blur gallery starts"); return }
            r.click(P(100, 70)); r.drawOverlay()
            QA.check(st.inst.points.count == 2, "a click adds a field-blur pin", "\(st.inst.points.count)")
            PendingEdits.willRunMenuCommand(topLevel: "Select")
            AppActions.selectAll()
            QA.check(AppActions.blurGallery != nil && move(r).isBusy, "a menu command leaves the Blur Gallery open")
            AppActions.finishBlurGallery(st, apply: true)
            AppModel.shared.dialog = nil
            QA.check(!move(r).isBusy && d.history.last?.name == "Field Blur", "OK applies the blur", "\(d.history.map(\.name))")
            QAInvariant.idle(r, "blur gallery")
            QAInvariant.undoRedo(r, from: start, "blur gallery")
            // Cancel
            AppActions.startBlurGallery(.irisBlur)
            if let st2 = AppActions.blurGallery { r.dragLine(P(100, 70), P(120, 80), steps: 2); AppActions.finishBlurGallery(st2, apply: false) }
            AppModel.shared.dialog = nil
            QAInvariant.idle(r, "blur gallery cancelled")
            r.closeAll()
        }
        // Tool data (slices, notes, counts, samplers) must follow the image through crop / image size / rotate
        QA.scenario("pending/tool-data-follows-geometry") {
            QAScenarios.resetToolSettings()
            for (name, run) in [("crop", { AppActions.crop(to: IRect(x: 40, y: 20, width: 160, height: 120), deletePixels: false) }),
                                ("image-size", { AppActions.imageSize(width: 480, height: 320, resolution: 72, scaleStyles: true) }),
                                ("canvas-size", { AppActions.canvasSize(width: 300, height: 200, anchorX: 1, anchorY: 1, extension: nil) }),
                                ("rotate-canvas", { AppActions.rotateCanvas(90) })] as [(String, () -> Void)] {
                let r = R()
                let f = fixtures["raster"]!
                let d = r.open(f.state, name: "tooldata")
                f.apply(to: d)
                // a mark on the block's top-left corner, a slice and a note on the block, a sampler in it
                let b = QAFixtures.box
                r.select(.count); r.click(CGPoint(x: b.minX, y: b.minY))
                r.select(.colorSampler); r.click(CGPoint(x: b.minX + 10, y: b.minY + 10))
                r.select(.note); r.click(CGPoint(x: b.maxX, y: b.maxY))
                r.select(.slice); r.dragLine(CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY), steps: 2)
                r.select(.hand)
                run()
                guard let nb = Compositor.shared.contentBounds(d.state.layer(f.active)!, state: d.state) else { continue }
                let td = d.state.toolData
                let count = td.countGroups.first?.points.first ?? .zero
                // each mark keeps its place on the image (rotate: the block's corners map onto its new corners)
                func onCorner(_ p: CGPoint) -> Bool { [CGPoint(x: nb.minX, y: nb.minY), CGPoint(x: nb.maxX, y: nb.minY), CGPoint(x: nb.minX, y: nb.maxY), CGPoint(x: nb.maxX, y: nb.maxY)].contains { $0.distance(to: p) < 2.5 } }
                QA.check(onCorner(count), "\(name): count marks follow the image", "mark \(count) block \(QAMeasure.describe(nb))")
                QA.check(td.notes.first.map { onCorner($0.position) } ?? false, "\(name): notes follow the image", "\(String(describing: td.notes.first?.position))")
                QA.check(td.colorSamplers.first.map { nb.contains($0) } ?? false, "\(name): color samplers follow the image", "\(String(describing: td.colorSamplers.first))")
                QA.check(td.slices.first.map { abs($0.rect.minX - nb.minX) < 2.5 && abs($0.rect.maxY - nb.maxY) < 2.5 && abs($0.rect.width - nb.width) < 3 } ?? false, "\(name): slices follow the image",
                         "\(String(describing: td.slices.first?.rect)) block \(QAMeasure.describe(nb))")
                r.drawOverlay()
                r.closeAll()
            }
        }
    }
}
