import AppKit
import CoreImage
import SwiftUI
import ImageCratCore

/// Regression checks for bugs found by the menu / dialog / panel / shortcut fuzz (`LUMEN_SELFTEST_ONLY=qamenus`).
enum QAMenusSelfTest {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") qamenus: \(name)\(detail.isEmpty ? "" : " — " + detail)")
    }

    /// Opens a document with a canvas attached (as the running app has), runs `body`, then closes it.
    static func withDoc(_ st: DocumentState, tool: ToolKind = .move, _ body: (Document, CanvasView) -> Void) {
        let app = AppModel.shared
        let d = Document(state: st, name: "qamenus")
        app.documents.append(d); app.activeDocumentID = d.id
        let c = CanvasView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let oldCanvas = AppActions.canvas
        AppActions.canvas = c
        c.document = d; d.zoom = 1; d.viewOffset = .zero
        app.tool = tool
        body(d, c)
        c.currentTool.cancel()
        app.tool = .move
        c.document = nil
        AppActions.canvas = oldCanvas
        app.documents.removeAll { $0.id == d.id }
        app.activeDocumentID = app.documents.last?.id
        app.dialog = nil
    }

    static func state(_ w: Int = 200, _ h: Int = 150) -> DocumentState {
        var st = SelfTest.baseState(w, h)
        st.layers.append(FuzzScenarios.painted(w: w, h: h))
        return st
    }

    static func key(_ chars: String, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
        Fuzz.keyEvent(chars, mods)!
    }

    static func run(_ out: URL) {
        failures = 0
        PendingEdits.install()
        automation()
        numericInput()
        commands()
        noOpSteps()
        dialogPreviews()
        quantizerSpeed()
        shortcuts()
        cropUndo()
        print("qamenus: \(failures) failed")
    }

    // MARK: Headless automation (UIBlock)

    static func automation() {
        let dir = out("automation")
        Automation.withHeadless(.cancel) {
            Automation.reset()
            UIBlock.alert("Message", "Info")
            check(Automation.requests.last?.kind == "alert", "headless alert returns immediately and is recorded")
            check(UIBlock.confirm("Rasterize?", "", ok: "Rasterize") == false, "headless confirm answers Cancel by default")
            let sp = NSSavePanel()
            sp.nameFieldStringValue = "x.png"
            check(UIBlock.run(sp) == .cancel && sp.url == nil, "headless save panel: cancel, no URL")
            var called = false
            UIBlock.begin(NSOpenPanel()) { r in called = r == .cancel }
            let until = Date().addingTimeInterval(1)
            while !called, Date() < until { CFRunLoopRunInMode(.defaultMode, 0.02, false) }
            check(called, "headless open panel (begin): handler called with cancel")
        }
        Automation.withHeadless(.ok) {
            Automation.saveDir = dir
            Automation.fixtureDir = dir
            try? Data([0x89, 0x50]).write(to: dir.appendingPathComponent("a.png"))
            check(UIBlock.confirm("Rasterize?", "", ok: "Rasterize"), "scripted OK: confirm answers the first button")
            let sp = NSSavePanel()
            sp.nameFieldStringValue = "x.png"
            check(UIBlock.run(sp) == .OK && sp.url?.lastPathComponent.hasSuffix("x.png") == true, "scripted OK: save panel reports a file in the save folder", "\(sp.url?.path ?? "nil")")
            let op = NSOpenPanel()
            op.allowedContentTypes = [.png]
            check(UIBlock.run(op) == .OK && op.urls.first?.lastPathComponent == "a.png" && op.url != nil, "scripted OK: open panel reports a fixture file")
            Automation.saveDir = nil; Automation.fixtureDir = nil
        }
        check(!Automation.isHeadless || Automation.isProcessWide, "headless mode is scoped to the test")
        // automated runs must never see (or spend) the user's real provider keys
        let real = ProviderID.allCases.filter { GenAIKeychain.shared.get($0.rawValue) != nil || (GenAIKeyOverrides.value($0) == nil && GenAIKeychain.shared.hasKey($0)) }
        check(GenAIKeychain.automatedRun && real.isEmpty, "self tests cannot read real API keys from the keychain", real.map(\.rawValue).joined(separator: ","))
    }

    static func out(_ name: String) -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lumen-qamenus-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: Typed numbers that used to trap

    static func numericInput() {
        check(NumberField.parse("nan") == nil && NumberField.parse("inf") == nil && NumberField.parse("-inf") == nil, "NumberField rejects nan / inf")
        check(NumberField.parse("99999999999999999999") == NumberField.limit && NumberField.parse("-1e30") == -NumberField.limit, "NumberField bounds huge values")
        check(NumberField.parse(" 12.5 ") == 12.5 && NumberField.parse("abc") == nil, "NumberField still parses ordinary input")
        check(clamp(Double.nan, 1, 5) == 1 && clamp(CGFloat.nan, 2, 5) == 2 && clamp(7.0, 1, 5) == 5 && clamp(3, 1, 5) == 3, "clamp maps NaN to the lower bound")
        let r1 = IRect(enclosing: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10))
        let r2 = IRect(enclosing: CGRect(x: -1e30, y: -1e30, width: 2e30, height: 2e30))
        let r3 = IRect(enclosing: CGRect(x: 1.2, y: 2.7, width: 3, height: 4))
        check(r1.isEmpty && r2.width > 0 && r3 == IRect(x: 1, y: 2, width: 4, height: 5), "IRect(enclosing:) survives NaN / huge rects", "\(r3)")
        var l = FuzzScenarios.painted()
        l.translate(dx: .nan, dy: .infinity)
        l.translate(dx: 1e30, dy: 3)
        check(l.raster?.origin.y == 3, "Layer.translate survives non-finite / huge offsets", "\(String(describing: l.raster?.origin))")
        check(FilterInstance.count(-3) == 0 && FilterInstance.count(.nan) == 0 && FilterInstance.count(4) == 4 && FilterInstance.count(1e9) == 50, "filter pass counts are bounded")
        check(VideoRenderer.validFrameRate(0) == 1 && VideoRenderer.validFrameRate(.nan) == 30 && VideoRenderer.validFrameRate(1e12) == 240 && VideoRenderer.validFrameRate(24) == 24, "render frame rate is bounded")
        check(validResolution(0) == 1 && validResolution(.nan) == 72 && validResolution(300) == 300, "document resolution is bounded")

        // Canvas Size / Image Size with absurd sizes: clamped instead of failing to allocate
        withDoc(state(40, 30)) { d, _ in
            AppActions.canvasSize(width: 400_000, height: 30, anchorX: 0, anchorY: 0, extension: nil)
            check(d.state.width == maxCanvasDimension && d.state.height == 30, "Canvas Size clamps the width", "\(d.state.width)×\(d.state.height)")
            d.undo()
            AppActions.imageSize(width: 50, height: 40, resolution: 0, scaleStyles: true)
            check(d.state.resolution >= 1, "Image Size never stores resolution 0", "\(d.state.resolution)")
        }
        AppActions.newDocument(width: 20, height: 20, resolution: .nan, background: .white, name: "res")
        if let d = AppModel.shared.activeDocument {
            check(d.state.resolution == 72, "New Document never stores a NaN resolution", "\(d.state.resolution)")
            AppModel.shared.close(d)
        }

        // Marquee with Fixed Ratio W = 0 (height became infinite → Int trap while dragging)
        withDoc(state(), tool: .marqueeRect) { d, c in
            let app = AppModel.shared
            let old = app.selection
            app.selection.fixedRatio = true; app.selection.ratioW = 0; app.selection.ratioH = 1
            let t = c.tool(for: .marqueeRect)
            func ev(_ p: CGPoint) -> ToolEvent { ToolEvent(doc: p, view: c.docToView(p), pressure: 1, modifiers: [], clickCount: 1, isTablet: false) }
            t.mouseDown(ev(CGPoint(x: 20, y: 20))); t.mouseDragged(ev(CGPoint(x: 90, y: 25))); t.mouseUp(ev(CGPoint(x: 90, y: 25)))
            check(Fuzz.validate(d).isEmpty, "marquee with fixed ratio W = 0 does not trap")
            app.selection = old
        }

        // Pixel grid with a rotated view (range lower > upper)
        withDoc(state()) { d, c in
            d.showPixelGrid = true; d.showRulers = true
            c.setZoom(16)
            for a in [0.7, 1.6, 3.1, -2.0] {
                c.setRotation(a)
                if let rep = c.overlay.bitmapImageRepForCachingDisplay(in: c.overlay.bounds) { c.overlay.cacheDisplay(in: c.overlay.bounds, to: rep) }
            }
            check(true, "pixel grid draws with a rotated view")
            c.setRotation(0)
            // rulers with a broken resolution and inch units (looped forever)
            let prefs = AppModel.shared.prefs
            AppModel.shared.prefs.rulerUnits = .inches
            d.state.resolution = 0
            if let rep = c.overlay.bitmapImageRepForCachingDisplay(in: c.overlay.bounds) { c.overlay.cacheDisplay(in: c.overlay.bounds, to: rep) }
            check(true, "rulers draw with resolution 0")
            d.state.resolution = 72
            AppModel.shared.prefs = prefs
        }
    }

    // MARK: Commands

    static func commands() {
        // Merge to HDR Pro ▸ Add Open Files with no document open (index out of range on the empty list)
        HDRProDialog().add([])
        check(true, "HDR Pro: adding no files does not trap")

        // Layer ▸ New ▸ Artboard from Layers (exclusivity violation: read the document inside its own mutation)
        withDoc(state()) { d, _ in
            AppActions.artboardFromLayers()
            check(d.activeLayer?.isArtboard == true && d.activeLayer?.name == "Artboard 1", "Artboard from Layers creates “Artboard 1”", d.activeLayer?.name ?? "nil")
            check(Fuzz.validate(d).isEmpty, "document valid after Artboard from Layers")
        }
    }

    /// Commands with nothing to do must not record a history step.
    static func noOpSteps() {
        withDoc(state()) { d, _ in
            let n = d.history.count
            AppActions.deleteMask()
            AppActions.clearGuides()
            AppActions.clearLayerStyle()
            AppActions.toggleLinkLayers()
            AppActions.revealAll()
            MeasurementActions.setDefaultScale()
            check(d.history.count == n, "no-op commands (delete mask, clear guides, clear style, link one layer, reveal all, default scale) add no history step", d.history.suffix(d.history.count - n).map(\.name).joined(separator: ", "))
            d.state.guides = [Guide(isVertical: true, position: 10)]
            d.commit("Guide")
            AppActions.clearGuides()
            check(d.state.guides.isEmpty && d.history.last?.name == "Clear Guides", "Clear Guides still works when there are guides")
        }
    }

    /// Save for Web: the palette search used to take minutes on every control change.
    static func quantizerSpeed() {
        var rng = FuzzRNG("quantizer")
        let samples = (0..<65536).map { _ in (rng.int(256), rng.int(256), rng.int(256)) }
        let t = Date()
        let pal = WebQuantizer.medianCut(samples, 256)
        let dt = Date().timeIntervalSince(t)
        check(pal.count == 256 && dt < 5, "median cut of 65536 colours to 256 is fast", String(format: "%.2f s, %d colours", dt, pal.count))
        let few = WebQuantizer.medianCut([(1, 2, 3), (1, 2, 3), (200, 100, 50)], 16)
        check(few.count == 2, "median cut keeps an exact palette for few colours")
    }

    // MARK: Dialog previews

    static func dialogPreviews() {
        let app = AppModel.shared
        var st = state()
        let second = FuzzScenarios.painted("Second")
        st.layers.append(second)
        withDoc(st) { d, _ in
            let first = d.state.layers[1].id
            // preview set on one layer, then the active layer changes under the dialog (floating panel, script)
            d.selectLayer(first)
            app.dialog = .filter(.gaussianBlur, smartLayer: nil, editingFilter: nil)
            AppActions.setPreview { $0 }
            d.selectLayer(second.id)
            AppActions.setPreview(nil)
            check(d.contentOverrides.isEmpty, "dialog Cancel removes its preview even after the active layer changed")
            app.dialog = nil
            // a dialog replaced by another one (no OK / Cancel ran)
            d.selectLayer(first)
            app.dialog = .adjustment(.levels)
            AppActions.setPreview { $0 }
            d.updateLayer(first) { $0.opacity = 0.3 }          // uncommitted live edit
            app.dialog = .about
            check(d.contentOverrides.isEmpty, "a dialog replaced by another leaves no preview behind")
            check(d.state.layer(first)?.opacity == 1, "a dialog replaced by another drops its uncommitted live edits")
            app.dialog = nil
            // display-only preview on a document that is no longer the active one when the dialog closes
            app.dialog = .selectAndMask
            d.displayOverride = { $0 }
            d.showSelectionEdges = false
            let other = Document(state: state(60, 40), name: "other")
            app.documents.append(other); app.activeDocumentID = other.id
            app.dialog = nil
            check(d.displayOverride == nil && d.showSelectionEdges, "Select and Mask preview is removed from the document it was shown on")
            app.documents.removeAll { $0.id == other.id }
            app.activeDocumentID = d.id
            // a pending transform's own preview must survive an unrelated dialog opening and closing
            if let mt = AppActions.canvas?.tool(for: .move) as? MoveTool {
                d.selectLayer(first)
                mt.startTransform()
                if let s = mt.session { s.quad = s.quad.mapped { CGPoint(x: $0.x + 5, y: $0.y) }; s.updatePreview() }
                let n = d.contentOverrides.count
                app.dialog = .about
                app.dialog = .shortcuts
                app.dialog = nil
                check(mt.isBusy && d.contentOverrides.count == n && n > 0, "a pending transform's preview survives dialogs opening and closing", "\(n) → \(d.contentOverrides.count)")
                mt.cancel()
            }
        }
    }

    // MARK: Shortcuts

    static func shortcuts() {
        withDoc(state()) { d, c in
            let before = d.history.count
            let swallowed = KeyRouter.handle(key("\u{7f}", [.shift]))
            check(!swallowed && d.history.count == before && d.state.layers.count == 2, "⇧⌫ is left to the menu (Edit ▸ Fill…), nothing is deleted")
            let plain = KeyRouter.handle(key("\u{7f}"))
            check(plain, "plain ⌫ still goes to the canvas")
        }
        // every tool with a shortcut must be reachable with its key (+ ⇧ to cycle)
        withDoc(state()) { _, _ in
            let app = AppModel.shared
            var unreachable: [String] = []
            for t in ToolKind.groups.flatMap({ $0 }) where !t.shortcut.isEmpty {
                app.tool = t == .move ? .brush : .move
                let k = t.shortcut.lowercased()
                _ = KeyRouter.handle(key(k)); _ = KeyRouter.handle(Fuzz.keyEvent(k, [], up: true)!)
                var n = 0
                while app.tool != t && n < 16 {
                    _ = KeyRouter.handle(key(k, [.shift])); _ = KeyRouter.handle(Fuzz.keyEvent(k, [.shift], up: true)!)
                    n += 1
                }
                if app.tool != t { unreachable.append("\(t)(\(t.shortcut))") }
            }
            check(unreachable.isEmpty, "every toolbar tool is reachable with its shortcut key", unreachable.joined(separator: ", "))
            app.tool = .move
        }
    }

    // MARK: Crop tool and Undo

    static func cropUndo() {
        withDoc(state(), tool: .crop) { d, c in
            let tool = c.tool(for: .crop)
            tool.activate()
            d.updateLayer(d.state.layers[1].id) { $0.opacity = 0.5 }
            d.commit("Opacity")
            let n = d.historyIndex
            check(!tool.isBusy, "untouched crop box is not a pending edit")
            AppActions.undo()
            check(d.historyIndex == n - 1, "⌘Z undoes while the Crop tool is selected", "index \(n) → \(d.historyIndex)")
            func ev(_ p: CGPoint) -> ToolEvent { ToolEvent(doc: p, view: c.docToView(p), pressure: 1, modifiers: [], clickCount: 1, isTablet: false) }
            tool.mouseDown(ev(CGPoint(x: 200, y: 150))); tool.mouseDragged(ev(CGPoint(x: 120, y: 100))); tool.mouseUp(ev(CGPoint(x: 120, y: 100)))
            check(tool.isBusy, "dragged crop box is a pending edit")
            let i = d.historyIndex
            AppActions.undo()
            check(!tool.isBusy && d.historyIndex == i, "⌘Z with a dragged crop box cancels the box first")
            tool.mouseDown(ev(CGPoint(x: 200, y: 150))); tool.mouseDragged(ev(CGPoint(x: 120, y: 100))); tool.mouseUp(ev(CGPoint(x: 120, y: 100)))
            tool.commit()
            check(d.state.width == 120 && d.state.height == 100, "Return commits the crop", "\(d.state.width)×\(d.state.height)")
            // a command chosen while a crop box is pending works on the cropped canvas (as with a pending transform)
            tool.mouseDown(ev(CGPoint(x: 120, y: 100))); tool.mouseDragged(ev(CGPoint(x: 80, y: 60))); tool.mouseUp(ev(CGPoint(x: 80, y: 60)))
            let steps = d.history.count
            PendingEdits.applyPendingCrop()
            check(d.state.width == 80 && d.state.height == 60 && !tool.isBusy && d.history.count == steps + 1, "a pending crop is applied before a menu command runs", "\(d.state.width)×\(d.state.height)")
            PendingEdits.applyPendingCrop()
            check(d.history.count == steps + 1, "no pending crop → nothing applied")
        }
    }
}
