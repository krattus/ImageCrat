import AppKit
import CoreImage
import ImageCratCore

/// Headless "tool robot": drives every tool with real NSEvents sent to an off-screen `CanvasView` and asserts
/// invariants (no stale sessions / overlays, exact undo & redo, locks respected, history steps, save round trip…).
///
///     LUMEN_SELFTEST_ONLY=qatools .build/debug/Lumen --selftest <outdir>
///
/// Filters: `LUMEN_QA_ONLY=a,b` runs only scenarios whose name contains one of the substrings,
/// `LUMEN_QA_SKIP=a,b` skips them, `LUMEN_QA_VERBOSE=1` also prints passing checks.
///
/// Depth: as part of the whole self test a quick pass runs (every tool, the per-tool checks, the pending-session matrix
/// through the app's hooks); `LUMEN_SELFTEST_ONLY=qatools` runs the standard matrix (every tool × every layer kind, a
/// rotated / zoomed view, selections, tiny documents); `LUMEN_QA_FULL=1` runs everything × everything (≈ 20 min).
/// `LUMEN_QA_TIER=quick|standard|full` picks a depth explicitly.
enum QAToolsModule {
    static func register() {
        FeatureModules.selfTests.append(("qatools", { out in QA.run(out) }))
    }
}

enum QA {
    static var failures = 0
    static var passes = 0
    static var current = ""
    static var out = URL(fileURLWithPath: NSTemporaryDirectory())
    static let env = ProcessInfo.processInfo.environment
    static let verbose = env["LUMEN_QA_VERBOSE"] == "1"
    enum Tier: Int { case quick, standard, full }
    static let tier: Tier = {
        switch env["LUMEN_QA_TIER"] {                      // explicit: quick | standard | full
        case "quick": return .quick
        case "standard": return .standard
        case "full": return .full
        default: return env["LUMEN_QA_FULL"] == "1" ? .full : ((env["LUMEN_SELFTEST_ONLY"] ?? "").hasPrefix("qatools") ? .standard : .quick)
        }
    }()
    static let only: [String] = (env["LUMEN_QA_ONLY"] ?? "").split(separator: ",").map(String.init)
    static let skip: [String] = (env["LUMEN_QA_SKIP"] ?? "").split(separator: ",").map(String.init)
    /// Titles of the alerts / confirmations the tools asked for (answered by `modalAnswer`).
    static var modalLog: [String] = []
    static var modalAnswer = false
    static var failed: [String] = []

    static func wants(_ name: String) -> Bool {
        if skip.contains(where: { name.contains($0) }) { return false }
        return only.isEmpty || only.contains(where: { name.contains($0) })
    }

    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok {
            passes += 1
            if verbose { print("PASS qatools: [\(current)] \(name)") }
        } else {
            failures += 1
            let d = detail()
            let line = "[\(current)] \(name)\(d.isEmpty ? "" : " — " + d)"
            failed.append(line)
            print("FAIL qatools: \(line)")
        }
    }

    static func info(_ s: String) { print("INFO qatools: [\(current)] \(s)") }

    /// Runs one named scenario (the name is printed first, so a trap can be attributed to it).
    static func scenario(_ name: String, _ body: () -> Void) {
        guard wants(name) else { return }
        current = name
        if verbose { print("BEGIN qatools: \(name)") }
        lastBegun = name
        autoreleasepool { body() }
    }
    static var lastBegun = ""

    static func run(_ out: URL) {
        self.out = out
        setvbuf(stdout, nil, _IONBF, 0)
        failures = 0; passes = 0
        let app = AppModel.shared
        let saved = (tool: app.tool, fg: app.foreground, bg: app.background, brush: app.brush, shape: app.shapeTool, sel: app.selection,
                     pen: app.penMode, text: app.textTool, workspace: WorkspaceManager.shared.current, hook: AppActions.modalHook,
                     canvas: AppActions.canvas, docs: app.documents, active: app.activeDocumentID, crop: app.crop, dialog: app.dialog)
        // a clean slate, whatever ran before: no dialog open (the key router steps aside for dialogs), no documents
        app.dialog = nil
        app.documents = []; app.activeDocumentID = nil
        AppActions.modalHook = { title, _ in modalLog.append(title); return modalAnswer }
        let savedButton = CanvasView.primaryButtonDown
        CanvasView.primaryButtonDown = { ToolRobot.buttonDown }
        defer { CanvasView.primaryButtonDown = savedButton }
        PendingEdits.install()
        atexit { if !QA.lastBegun.isEmpty && QA.lastBegun != "done" { print("qatools: last scenario begun: \(QA.lastBegun)") } }
        let t0 = Date()
        QAScenarios.runAll()
        lastBegun = "done"
        // restore shared state for whatever runs next
        AppActions.modalHook = saved.hook
        app.documents = saved.docs; app.activeDocumentID = saved.active
        app.dialog = saved.dialog
        AppActions.canvas = saved.canvas
        app.tool = saved.tool; app.foreground = saved.fg; app.background = saved.bg; app.brush = saved.brush
        app.shapeTool = saved.shape; app.selection = saved.sel; app.penMode = saved.pen; app.textTool = saved.text; app.crop = saved.crop
        if WorkspaceManager.shared.current != saved.workspace { WorkspaceManager.shared.current = saved.workspace }
        print(String(format: "qatools: %d checks passed, %d failed (%.1fs, %@ pass)", passes, failures, Date().timeIntervalSince(t0), "\(tier)"))
    }
}

// MARK: - View configurations

struct QAView {
    var name: String
    var zoom: Double
    var offset: CGPoint
    var rotation: Double = 0       // radians (Rotate View)
    var rulers = false

    static let identity = QAView(name: "z1", zoom: 1, offset: CGPoint(x: 60, y: 50))
    static let half = QAView(name: "z0.5", zoom: 0.5, offset: CGPoint(x: 210.5, y: 133.25))
    static let double = QAView(name: "z2", zoom: 2, offset: CGPoint(x: 95, y: 71))
    static let rotated = QAView(name: "rot30", zoom: 1.5, offset: CGPoint(x: 170, y: 90), rotation: .pi / 6)
    static let all: [QAView] = [.identity, .half, .double, .rotated]
}

// MARK: - Robot

final class ToolRobot {
    nonisolated(unsafe) static var keepAlive: [ToolRobot] = []
    let window: NSWindow
    let canvas: CanvasView
    private(set) var doc: Document!
    let app = AppModel.shared
    private var eventNumber = 0
    private let toolHook: ((ToolKind, ToolKind) -> Void)?
    var mods: NSEvent.ModifierFlags = []
    var view = QAView.identity

    init(size: CGSize = CGSize(width: 900, height: 640)) {
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        canvas = CanvasView(frame: CGRect(origin: .zero, size: size))
        toolHook = AppModel.shared.toolChanged          // installed by CanvasView.init for this canvas
        window.contentView = canvas
        ToolRobot.keepAlive.append(self)
        makeCurrent()
    }

    /// Routes tool switches and `AppActions.canvas` to this robot's canvas.
    func makeCurrent() {
        AppActions.canvas = canvas
        app.toolChanged = toolHook
    }

    // MARK: Documents

    @discardableResult
    func open(_ st: DocumentState, name: String = "qa", view v: QAView = .identity, active: UUID? = nil, snap: Bool = false) -> Document {
        makeCurrent()
        let d = Document(state: st, name: name)
        d.needsFitOnScreen = false
        d.snapEnabled = snap
        if let a = active { d.selectLayer(a) }
        app.documents.append(d)
        app.activeDocumentID = d.id
        doc = d
        canvas.document = d
        setView(v)
        return d
    }

    /// Makes an already open document the active one (like clicking its tab).
    func activate(_ d: Document) {
        app.activeDocumentID = d.id
        doc = d
        canvas.document = d
    }

    func close(_ d: Document? = nil) {
        guard let d = d ?? doc else { return }
        app.close(d)
        if canvas.document === d || canvas.document == nil {
            let next = app.activeDocument
            canvas.document = next
            doc = next
        }
    }

    func closeAll() {
        canvas.document = nil
        app.documents.removeAll()
        app.activeDocumentID = nil
        doc = nil
    }

    func setView(_ v: QAView) {
        guard let d = doc else { return }
        view = v
        d.showRulers = v.rulers
        d.zoom = v.zoom
        d.viewRotation = 0
        d.viewOffset = v.offset
        if v.rotation != 0 { canvas.setRotation(v.rotation) }
        d.needsFitOnScreen = false
    }

    // MARK: Tools

    var tool: Tool { canvas.currentTool }
    func select(_ k: ToolKind) { app.tool = k }
    func toolOf<T: Tool>(_ k: ToolKind, _ t: T.Type = T.self) -> T? { canvas.tool(for: k) as? T }

    // MARK: Events (doc coordinates are converted with the canvas' current view transform)

    private func mouseEvent(_ type: NSEvent.EventType, view v: CGPoint, clicks: Int) -> NSEvent {
        eventNumber += 1
        let w = canvas.convert(v, to: nil)
        return NSEvent.mouseEvent(with: type, location: w, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: clicks,
                                  pressure: type == .leftMouseUp ? 0 : 1)!
    }

    func v(_ docPoint: CGPoint) -> CGPoint { canvas.docToView(docPoint) }

    /// The robot's mouse button (the canvas asks for the physical button state while a drag is tracked).
    nonisolated(unsafe) static var buttonDown = false

    func down(_ p: CGPoint, clicks: Int = 1) { downView(v(p), clicks: clicks) }
    func drag(_ p: CGPoint) { dragView(v(p)) }
    func up(_ p: CGPoint, clicks: Int = 1) { upView(v(p), clicks: clicks) }
    func move(_ p: CGPoint) { canvas.mouseMoved(with: mouseEvent(.mouseMoved, view: v(p), clicks: 0)) }
    func downView(_ p: CGPoint, clicks: Int = 1) { ToolRobot.buttonDown = true; canvas.mouseDown(with: mouseEvent(.leftMouseDown, view: p, clicks: clicks)) }
    func dragView(_ p: CGPoint) { canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, view: p, clicks: 1)) }
    func upView(_ p: CGPoint, clicks: Int = 1) { canvas.mouseUp(with: mouseEvent(.leftMouseUp, view: p, clicks: clicks)); ToolRobot.buttonDown = false }
    func rightDown(_ p: CGPoint) -> NSMenu? {
        // the real handler pops the menu up (modal); ask the tool directly instead
        let vp = v(p)
        return canvas.currentTool.contextMenu(ToolEvent(doc: canvas.viewToDoc(vp), view: vp, pressure: 1, modifiers: mods, clickCount: 1, isTablet: false))
    }

    func click(_ p: CGPoint, clicks: Int = 1) { down(p, clicks: clicks); up(p, clicks: clicks) }
    func doubleClick(_ p: CGPoint) { click(p); click(p, clicks: 2) }

    /// Press at `a`, drag to `b` in `steps` moves, release.
    func dragLine(_ a: CGPoint, _ b: CGPoint, steps: Int = 6, mid: ((Int) -> Void)? = nil) {
        down(a)
        for i in 1...max(1, steps) {
            drag(a.lerp(b, CGFloat(i) / CGFloat(max(1, steps))))
            mid?(i)
        }
        up(b)
    }

    func dragPath(_ pts: [CGPoint]) {
        guard let f = pts.first, let l = pts.last else { return }
        down(f)
        for p in pts.dropFirst() { drag(p) }
        up(l)
    }

    static let kReturn: UInt16 = 36, kEnter: UInt16 = 76, kEsc: UInt16 = 53, kDelete: UInt16 = 51, kFwdDelete: UInt16 = 117
    static let kLeft: UInt16 = 123, kRight: UInt16 = 124, kDown: UInt16 = 125, kUp: UInt16 = 126, kSpace: UInt16 = 49

    private func keyEvent(_ type: NSEvent.EventType, _ code: UInt16, _ chars: String) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    /// A key press, routed like the app does: the text editor gets it while typing, otherwise `KeyRouter`
    /// (tool shortcuts, canvas keys) and finally the first responder.
    func key(_ code: UInt16, _ chars: String = "") {
        let e = keyEvent(.keyDown, code, chars)
        if let r = window.firstResponder, r is NSText { r.keyDown(with: e); return }
        if KeyRouter.handle(e) { return }
        // not a shortcut: the event goes to the first responder; ⌘-combinations would go to the menus, which are
        // represented by the explicit command calls of the scenarios
        if mods.contains(.command) { return }
        if let r = window.firstResponder, r !== window { r.keyDown(with: e) }
    }

    /// Whether the app's key router swallows this key press (true = it never reaches the menus / first responder).
    func routerSwallows(_ code: UInt16, _ chars: String, _ m: NSEvent.ModifierFlags) -> Bool {
        let old = mods
        mods = m
        defer { mods = old }
        return KeyRouter.handle(keyEvent(.keyDown, code, chars))
    }

    func setMods(_ m: NSEvent.ModifierFlags) {
        mods = m
        canvas.flagsChanged(with: keyEvent(.flagsChanged, 56, ""))
    }

    /// Runs the main run loop briefly (main-queue async work, timers).
    func pump(_ seconds: Double = 0.02) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    // MARK: Rendering

    /// Draws the overlay (selection ants, handles, tool overlay) into a bitmap: exercises every drawOverlay path.
    @discardableResult
    func drawOverlay() -> NSBitmapImageRep? {
        let ov = canvas.overlay
        guard let rep = ov.bitmapImageRepForCachingDisplay(in: ov.bounds) else { return nil }
        ov.cacheDisplay(in: ov.bounds, to: rep)
        return rep
    }

    /// What the user sees (live previews and hidden layers included), canvas-size.
    func liveComposite() -> PixelBuffer {
        let sp = CanvasSpace(width: doc.state.width, height: doc.state.height)
        return RenderEngine.renderBuffer(Compositor.shared.composite(doc).cropped(to: sp.ciCanvas), docRect: doc.state.canvasRect, space: sp)
    }

    func saveOverlayPNG(_ name: String) {
        guard let rep = drawOverlay(), let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: QA.out.appendingPathComponent(name + ".png"))
    }
}

// MARK: - Measuring

enum QAMeasure {
    static func composite(_ st: DocumentState) -> PixelBuffer {
        let sp = CanvasSpace(width: st.width, height: st.height)
        return RenderEngine.renderBuffer(Compositor.shared.composite(st).cropped(to: sp.ciCanvas), docRect: st.canvasRect, space: sp)
    }

    /// Mean absolute difference per byte (0…255); 999 when the sizes differ.
    static func diff(_ a: PixelBuffer, _ b: PixelBuffer) -> Double {
        guard a.width == b.width, a.height == b.height, a.format == b.format else { return 999 }
        let rb = a.width * a.bytesPerPixel
        let x = a.data.assumingMemoryBound(to: UInt8.self), y = b.data.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        for r in 0..<a.height {
            let pa = x + r * a.bytesPerRow, pb = y + r * b.bytesPerRow
            for i in 0..<rb { sum += abs(Int(pa[i]) - Int(pb[i])) }
        }
        return Double(sum) / Double(max(1, rb * a.height))
    }

    static func diff(_ a: DocumentState, _ b: DocumentState) -> Double { diff(composite(a), composite(b)) }

    /// Number of bytes that differ by more than `tol` outside / inside a gray mask (canvas-size, white = inside).
    static func changed(_ a: PixelBuffer, _ b: PixelBuffer, mask: PixelBuffer?, inside: Bool, tol: Int = 2) -> Int {
        guard a.width == b.width, a.height == b.height, a.format == b.format else { return -1 }
        var n = 0
        let bpp = a.bytesPerPixel
        let x = a.data.assumingMemoryBound(to: UInt8.self), y = b.data.assumingMemoryBound(to: UInt8.self)
        for r in 0..<a.height {
            for c in 0..<a.width {
                if let m = mask {
                    let v = m.alpha(c, r)
                    if inside ? v < 250 : v > 0 { continue }        // "outside" = not selected at all (feathered edges count as inside)
                }
                for k in 0..<bpp where abs(Int(x[r * a.bytesPerRow + c * bpp + k]) - Int(y[r * b.bytesPerRow + c * bpp + k])) > tol { n += 1; break }
            }
        }
        return n
    }

    private static func hashBytes(_ b: PixelBuffer, into h: inout Hasher) {
        h.combine(b.width); h.combine(b.height); h.combine(b.format.rawValue)
        let rb = b.width * b.bytesPerPixel
        for r in 0..<b.height { h.combine(bytes: UnsafeRawBufferPointer(start: b.data + r * b.bytesPerRow, count: rb)) }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
    private static let negativeZero = try! NSRegularExpression(pattern: "(?<![0-9.eE])-0(?:\\.0+)?(?![0-9.eE])")
    private static func json<T: Encodable>(_ v: T, into h: inout Hasher) {
        guard let data = try? encoder.encode(v), var s = String(data: data, encoding: .utf8) else { h.combine(0); return }
        // -0.0 == 0.0 for every purpose of the app, but not as text
        if s.contains("-0") { s = negativeZero.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "0") }
        h.combine(s)
    }

    static func hash(_ l: Layer, into h: inout Hasher) {
        var light = l
        light.mask = nil
        switch l.content {
        case .raster(let r):
            light.content = .fill(FillContent(paint: .none))
            h.combine(r.origin.x); h.combine(r.origin.y)
            hashBytes(r.buffer, into: &h)
        case .group(let g):
            light.content = .fill(FillContent(paint: .none))
            h.combine(g.isExpanded)
            if let a = g.artboard { json(a, into: &h) }
            h.combine(g.children.count)
            for c in g.children { hash(c, into: &h) }
        default: break
        }
        json(light, into: &h)
        if let m = l.mask {
            h.combine(m.origin.x); h.combine(m.origin.y); h.combine(m.outsideValue); h.combine(m.isEnabled); h.combine(m.isLinked)
            h.combine(m.density); h.combine(m.feather)
            hashBytes(m.buffer, into: &h)
        }
    }

    static func layerPrint(_ l: Layer) -> Int { var h = Hasher(); hash(l, into: &h); return h.finalize() }

    /// Exact fingerprint of an undoable state (pixels, layer tree and every other persisted field).
    static func fingerprint(_ st: DocumentState) -> Int {
        var h = Hasher()
        var light = st
        light.layers = []; light.selection = nil; light.alphaChannels = []
        json(light, into: &h)
        h.combine(st.layers.count)
        for l in st.layers { hash(l, into: &h) }
        if let s = st.selection { hashBytes(s, into: &h) } else { h.combine(0) }
        for c in st.alphaChannels { h.combine(c.id); h.combine(c.name); hashBytes(c.buffer, into: &h) }
        return h.finalize()
    }

    /// Human readable layer tree (for failure messages).
    static func tree(_ st: DocumentState) -> String {
        func d(_ l: Layer) -> String {
            let k: String
            switch l.content {
            case .raster(let r): k = "R\(r.frame.x),\(r.frame.y),\(r.frame.width)x\(r.frame.height)"
            case .text(let t): k = "T'\(t.text.prefix(8))'"
            case .shape: k = "S"
            case .smartObject: k = "SO"
            case .adjustment: k = "A"
            case .fill: k = "F"
            case .group(let g): k = (g.artboard != nil ? "AB" : "G") + "[" + g.children.map(d).joined(separator: " ") + "]"
            }
            return "\(l.name):\(k)\(l.mask != nil ? "+m" : "")\(l.isVisible ? "" : "(hidden)")"
        }
        return "\(st.width)x\(st.height) " + st.layers.map(d).joined(separator: " | ")
    }

    /// Doc-space bounds of the pixels a layer really renders (content only: no mask, no effects).
    static func inkBounds(_ l: Layer, in st: DocumentState, threshold: UInt8 = 24) -> CGRect? {
        let sp = CanvasSpace(width: st.width, height: st.height)
        guard let img = Compositor.shared.contentImage(l, space: sp) else { return nil }
        let r = IRect(x: -st.width, y: -st.height, width: st.width * 3, height: st.height * 3)
        let buf = RenderEngine.renderBuffer(img.cropped(to: sp.ciRect(r)), docRect: r, space: sp)
        guard let b = buf.opaqueBounds(threshold: threshold) else { return nil }
        return b.offsetBy(dx: r.x, dy: r.y).cgRect
    }

    /// The box the Move tool draws its handles on for a layer.
    static func handleBox(_ l: Layer, in st: DocumentState) -> CGRect? {
        if let so = l.smart { return so.quad.bounds }
        if let t = l.text { return TextRenderer.docQuad(t).bounds }
        return Compositor.shared.contentBounds(l, state: st)
    }

    static func describe(_ r: CGRect?) -> String {
        guard let r else { return "nil" }
        return String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
    }
}

// MARK: - Invariants

struct QASnapshot {
    let print: Int
    let historyCount: Int
    let historyIndex: Int
    let state: DocumentState

    init(_ d: Document) {
        state = d.state
        print = QAMeasure.fingerprint(d.state)
        historyCount = d.history.count
        historyIndex = d.historyIndex
    }
}

enum QAInvariant {
    /// No live preview, hidden layer or uncommitted change is left behind and the tool is idle.
    static func idle(_ r: ToolRobot, _ label: String, allowBusy: Bool = false) {
        guard let d = r.doc else { return }
        if !allowBusy { QA.check(!r.tool.isBusy, "\(label): tool idle (isBusy false)") }
        QA.check(d.contentOverrides.isEmpty, "\(label): no content overrides left", "\(d.contentOverrides.count)")
        QA.check(d.displayOverride == nil, "\(label): no display override left")
        QA.check(d.hiddenLayers.isEmpty, "\(label): no layer left hidden by a tool")
        QA.check(d.showSelectionEdges, "\(label): selection edges visible again")
        let live = QAMeasure.fingerprint(d.state), committed = QAMeasure.fingerprint(d.committedState)
        QA.check(live == committed, "\(label): no uncommitted change left in the document",
                 "state \(QAMeasure.tree(d.state)) vs committed \(QAMeasure.tree(d.committedState)) (history: \(d.history.map(\.name).suffix(4)))")
        QA.check(!d.history.contains { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }, "\(label): history steps are named")
        if let a = d.activeLayerID { QA.check(d.state.layer(a) != nil, "\(label): active layer exists") }
        QA.check(d.selectedLayerIDs.allSatisfy { d.state.layer($0) != nil }, "\(label): selected layers exist")
    }

    /// Undo back to `start` restores it exactly; redo reproduces the current state exactly.
    static func undoRedo(_ r: ToolRobot, from start: QASnapshot, _ label: String) {
        guard let d = r.doc else { return }
        let end = QASnapshot(d)
        let steps = end.historyIndex - start.historyIndex
        guard steps >= 0, end.historyCount <= Document.maxHistory else { return }
        if steps == 0 {
            QA.check(end.print == start.print, "\(label): nothing recorded → document unchanged")
            return
        }
        for _ in 0..<steps { d.undo() }
        let back = QAMeasure.fingerprint(d.state)
        QA.check(back == start.print, "\(label): undo ×\(steps) restores the document exactly",
                 "diff \(String(format: "%.3f", QAMeasure.diff(d.state, start.state))) \(QAMeasure.tree(d.state)) vs \(QAMeasure.tree(start.state)); steps \(d.history.map(\.name).suffix(steps + 1))")
        for _ in 0..<steps { d.redo() }
        QA.check(QAMeasure.fingerprint(d.state) == end.print, "\(label): redo ×\(steps) reproduces the result exactly",
                 "diff \(String(format: "%.3f", QAMeasure.diff(d.state, end.state)))")
    }

    /// Transform handles (the Move tool's bounding box) sit on the rendered content of the layer — the "handles detached
    /// from the element" class. Checked inside the canvas for layers whose box is computed, not measured (text, shape,
    /// smart object).
    static func handlesMatchContent(_ d: Document, _ id: UUID, _ label: String, tol: CGFloat = 4) {
        guard let l = d.state.layer(id), l.isText || l.isShape || l.isSmartObject, l.smart?.warp == nil else { return }
        let canvas = d.state.canvasCGRect
        guard let full = QAMeasure.handleBox(l, in: d.state) else { return }
        let box = full.intersection(canvas)
        guard !box.isNull, box.width > 8, box.height > 8 else { return }
        guard let ink = QAMeasure.inkBounds(l, in: d.state)?.intersection(canvas), !ink.isNull else {
            // degenerate vector paths (a single segment) and empty text render nothing
            if l.isSmartObject { QA.check(false, "\(label): smart object renders inside its handle box", "box \(QAMeasure.describe(full)) ink nil") }
            return
        }
        var ok = box.insetBy(dx: -tol, dy: -tol).contains(ink.insetBy(dx: 0.5, dy: 0.5))
        if l.isText {
            // Text boxes are layout boxes: the ink must lie inside (with room for overshoot), not match on every side.
            let slack = max(12, CGFloat(l.text?.fontSize ?? 12) * 1.4)
            ok = box.insetBy(dx: -slack, dy: -slack).contains(ink)
        } else if l.isSmartObject {
            // the content may have transparent margins (a converted type layer keeps its layout box), but it must fill
            // most of the box: a box that sits somewhere else or has another size is "detached"
            ok = ok && ink.width * ink.height >= box.width * box.height * 0.4
        }
        QA.check(ok, "\(label): transform handles sit on the rendered content", "box \(QAMeasure.describe(full)) ink \(QAMeasure.describe(ink))")
    }

    /// The document survives a native save / reload unchanged.
    static func roundTrip(_ d: Document, _ label: String) {
        let url = QA.out.appendingPathComponent("qa_roundtrip_\(abs(label.hashValue) % 100000).imagecrat")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try DocumentIO.saveNative(d, to: url)
            let back = try DocumentIO.load(url: url)
            QA.check(QAMeasure.fingerprint(back.state) == QAMeasure.fingerprint(d.state), "\(label): .imagecrat round trip is identical",
                     "diff \(String(format: "%.3f", QAMeasure.diff(back.state, d.state))) \(QAMeasure.tree(back.state))")
        } catch {
            QA.check(false, "\(label): .imagecrat round trip", "\(error)")
        }
    }
}
