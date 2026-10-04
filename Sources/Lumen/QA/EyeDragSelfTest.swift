import AppKit
import SwiftUI
import ImageCratCore

/// Layers panel eyes (UI/Panels/LayersPanelEyeDrag.swift): drag across eyes, ⌥-click solo / restore, the eye's menu.
/// The real Layers panel is hosted offscreen; drags are driven through its eye column (`EyeColumnView`) with window
/// positions taken from the row frames the panel reports, and also with synthetic mouse events sent through NSApp.
/// `LUMEN_SELFTEST_ONLY=eyedrag Lumen --selftest <dir>`
enum EyeDragSelfTest {
    static func register() { FeatureModules.selfTests.append(("eyedrag", { run($0) })) }

    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") eyedrag: \(name)\(d.isEmpty ? "" : " — " + d)")
        fflush(stdout)
    }

    // MARK: Fixture

    struct Panel {
        let d: Document
        let w: NSWindow
        let eye: EyeColumnView
        var ids: [String: UUID] = [:]
        var drag: EyeDragCoordinator { eye.drag! }
        func id(_ n: String) -> UUID { ids[n]! }
        func vis(_ n: String) -> Bool { d.state.layer(id(n))?.isVisible ?? false }
        func name(_ id: UUID) -> String { d.state.layer(id)?.name ?? "?" }
        /// Window point on the eye of `t` (nil when its row isn't loaded).
        func point(_ t: EyeTarget, dy: CGFloat = 0) -> NSPoint? {
            guard let f = drag.frame(of: t) else { return nil }
            return eye.convert(CGPoint(x: 11, y: f.midY + dy), to: nil)
        }
        func layer(_ n: String) -> EyeTarget { .layer(id(n)) }
        /// A drag from row to row (window positions, as the mouse would).
        func dragAcross(_ path: [EyeTarget], modifiers: NSEvent.ModifierFlags = []) {
            guard let first = path.first, let p0 = point(first) else { return }
            eye.simulate(.leftMouseDown, window: p0, modifiers: modifiers)
            for t in path.dropFirst() { if let p = point(t) { eye.simulate(.leftMouseDragged, window: p) } }
            eye.simulate(.leftMouseUp, window: point(path.last!) ?? p0)
            UIFixesSelfTest.spin(0.1)
        }
    }

    static func findEye(_ w: NSWindow) -> EyeColumnView? {
        func walk(_ v: NSView) -> EyeColumnView? {
            if let e = v as? EyeColumnView { return e }
            for s in v.subviews { if let e = walk(s) { return e } }
            return nil
        }
        return w.contentView.flatMap(walk)
    }

    /// Bottom → top: Background, A, Locked (Lock All), B, G [G1, Inner [Deep]], T (type with three effects), AB (artboard [Chip]).
    static func fixture(height: CGFloat = 820) -> Panel? {
        let L = LayersPanel2SelfTest.self
        let bg = L.rect("Background", CGRect(x: 0, y: 0, width: 300, height: 300), RGBA(r: 1, g: 1, b: 1))
        let a = L.rect("A", CGRect(x: 10, y: 10, width: 40, height: 40))
        var locked = L.rect("Locked", CGRect(x: 60, y: 10, width: 40, height: 40)); locked.locks.all = true
        let b = L.rect("B", CGRect(x: 110, y: 10, width: 40, height: 40))
        let g = L.group("G", [L.rect("G1", CGRect(x: 10, y: 60, width: 30, height: 30)), L.group("Inner", [L.rect("Deep", CGRect(x: 50, y: 60, width: 30, height: 30))])])
        let t = L.styledText("T")
        let ab = L.group("AB", [L.rect("Chip", CGRect(x: 200, y: 200, width: 40, height: 40))], artboard: Artboard(rect: CGRect(x: 180, y: 180, width: 100, height: 100), background: nil))
        let d = L.doc([bg, a, locked, b, g, t, ab])
        L.activate(d)
        LayersPanelUI.shared.fxCollapsed.remove(t.id)
        d.selectLayer(a.id)
        FuzzAX.enable()   // (SwiftUI builds its accessibility tree once a client asked for it)
        let w = UIFixesSelfTest.host(LayersPanelContent(doc: d), CGSize(width: 300, height: height))
        guard let eye = findEye(w), eye.drag != nil else { UIFixesSelfTest.close(w); return nil }
        var p = Panel(d: d, w: w, eye: eye)
        for l in d.state.allLayers { p.ids[l.name] = l.id }
        return p
    }

    static func close(_ p: Panel) {
        UIFixesSelfTest.close(p.w)
        AppModel.shared.documents.removeAll { $0 === p.d }
    }

    // MARK: Run

    static func run(_ out: URL) {
        passes = 0; failures = 0
        let dir = out.appendingPathComponent("eyedrag")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppModel.shared
        let saved = (docs: app.documents, active: app.activeDocumentID, dialog: app.dialog, collapsed: LayersPanelUI.shared.fxCollapsed, solo: EyeVisibility.solo)
        defer {
            app.dialog = saved.dialog
            app.documents = saved.docs; app.activeDocumentID = saved.active
            LayersPanelUI.shared.fxCollapsed = saved.collapsed
            EyeVisibility.solo = saved.solo
        }
        app.dialog = nil
        guard let p = fixture() else { check(false, "Layers panel hosted with its eye column"); return }
        layout(p)
        multiRow(p)
        reverse(p)
        groups(p)
        effects(p)
        artboards(p)
        undo(p)
        solo(p)
        menu(p)
        plainClick(p)
        mouseEvents(p)
        reorder(p)
        snapshot(p, dir)
        close(p)
        autoscroll()
        performance()
        print("eyedrag: \(passes) passed, \(failures) failed")
    }

    // MARK: Row frames ↔ window

    static func layout(_ p: Panel) {
        let rows = p.d.state.layers.flattenedForDisplay().map { $0.0.id }
        let layerFrames = p.drag.frames.filter(\.target.isLayer).map(\.target.layerID)
        check(layerFrames == rows, "every layer row reports its eye frame, in panel order", "\(layerFrames.map(p.name)) vs \(rows.map(p.name))")
        let fx = p.drag.frames.filter { !$0.target.isLayer }
        check(fx.count == 4, "the Effects row and each effect row report theirs", "\(fx.count)")
        // the column's own coordinates are the list's coordinate space: the row under a window point is that row
        var ok = true
        for f in p.drag.frames {
            let wp = p.eye.convert(CGPoint(x: 11, y: f.frame.midY), to: nil)
            let hit = p.w.contentView?.superview?.hitTest(wp) ?? p.w.contentView?.hitTest(wp)
            if hit !== p.eye || p.drag.target(at: p.eye.convert(wp, from: nil)) != f.target { ok = false }
        }
        check(ok, "a window point on any eye hits the eye column and maps back to that row")
        let artRow = p.drag.frame(of: p.layer("AB"))?.height ?? 0, layerRow = p.drag.frame(of: p.layer("B"))?.height ?? 0
        check(abs(artRow - ArtboardLayerRow.height) < 1 && abs(layerRow - 38) < 1, "row heights: artboard 30, layer 38", "\(artRow), \(layerRow)")
        if let r = p.drag.frame(of: p.layer("B")) {
            let off = p.eye.convert(CGPoint(x: 120, y: r.midY), to: nil)
            check((p.w.contentView?.superview?.hitTest(off) ?? p.w.contentView?.hitTest(off)) !== p.eye, "the rest of the row (name, thumbnail) is not the eye column")
        }
    }

    // MARK: Multi-row hide / show

    static func multiRow(_ p: Panel) {
        let d = p.d
        let n0 = d.historyIndex
        guard let pb = p.point(p.layer("B")), let pl = p.point(p.layer("Locked")), let pa = p.point(p.layer("A")) else { check(false, "rows B / Locked / A loaded"); return }
        p.eye.simulate(.leftMouseDown, window: pb)
        check(!p.vis("B") && p.vis("Locked") && d.historyIndex == n0, "press: the first eye toggles at once (no step yet)")
        p.eye.simulate(.leftMouseDragged, window: pl)
        check(!p.vis("Locked") && p.vis("A"), "drag over Locked: hidden live (locked layers too, as in Photoshop)")
        p.eye.simulate(.leftMouseDragged, window: pa)
        check(!p.vis("A") && d.historyIndex == n0 && p.drag.isDragging, "drag over A: hidden live, still no history step")
        p.eye.simulate(.leftMouseUp, window: pa)
        check(d.historyIndex == n0 + 1 && d.history[d.historyIndex].name == "Hide Layers", "release: one step “Hide Layers”", d.history[d.historyIndex].name ?? "")
        check(p.vis("Background") && p.vis("G") && p.vis("T"), "rows not passed are untouched")
        check(d.activeLayerID == p.id("A") && d.selectedLayerIDs == [p.id("A")], "the selection is unchanged")
        // show: starting on a hidden eye shows every row passed
        p.dragAcross([p.layer("A"), p.layer("Locked"), p.layer("B")])
        check(p.vis("A") && p.vis("Locked") && p.vis("B") && d.history[d.historyIndex].name == "Show Layers" && d.historyIndex == n0 + 2, "drag from a hidden eye: all shown, “Show Layers”")
        // a row that already has the state stays as it is (all hidden or all shown, not toggled one by one)
        d.updateLayer(p.id("Locked")) { $0.isVisible = false }; d.commit("Hide Layer")
        p.dragAcross([p.layer("B"), p.layer("Locked"), p.layer("A")])
        check(!p.vis("B") && !p.vis("Locked") && !p.vis("A"), "a row already hidden stays hidden (not toggled)")
        p.dragAcross([p.layer("B"), p.layer("A")])
        check(p.vis("B") && p.vis("Locked") && p.vis("A"), "fast drag (B straight to A): the row in between gets the state too")
        // drag from B up past the layers above
        if let pb = p.point(p.layer("B")), let pg = p.point(p.layer("G1")), let pq = p.point(p.layer("Deep")) {
            p.eye.simulate(.leftMouseDown, window: pb); p.eye.simulate(.leftMouseDragged, window: pg); p.eye.simulate(.leftMouseDragged, window: pq); p.eye.simulate(.leftMouseUp, window: pq)
            check(!p.vis("B") && !p.vis("G1") && !p.vis("Deep") && p.vis("Inner") && p.vis("G"), "dragging upwards works too (and passes the rows in between)")
            d.undo()
        }
    }

    // MARK: Reversing direction

    static func reverse(_ p: Panel) {
        let d = p.d
        let n0 = d.historyIndex
        guard let pa = p.point(p.layer("A")), let pb = p.point(p.layer("B")), let pbg = p.point(p.layer("Background")) else { check(false, "rows loaded"); return }
        p.eye.simulate(.leftMouseDown, window: pa)
        p.eye.simulate(.leftMouseDragged, window: pb)          // up over Locked to B
        check(!p.vis("A") && !p.vis("Locked") && !p.vis("B"), "up from A to B: all three hidden")
        p.eye.simulate(.leftMouseDragged, window: pa)          // back down over Locked and A
        check(!p.vis("A") && !p.vis("Locked") && !p.vis("B"), "back down over rows already passed: they stay hidden (no toggling back)")
        p.eye.simulate(.leftMouseDragged, window: pbg)         // on past the start
        p.eye.simulate(.leftMouseDragged, window: pb)          // and up again
        p.eye.simulate(.leftMouseUp, window: pb)
        check(!p.vis("Background") && !p.vis("B") && !p.vis("A"), "on past the start and back: every row passed hidden")
        check(d.historyIndex == n0 + 1 && d.history[d.historyIndex].name == "Hide Layers", "still one step for the whole drag", "\(d.historyIndex - n0) steps")
        d.undo()
        check(p.vis("Background") && p.vis("A") && p.vis("Locked") && p.vis("B"), "undo brings them all back")
    }

    // MARK: Groups and nested rows

    static func groups(_ p: Panel) {
        let d = p.d
        p.dragAcross([p.layer("T"), p.layer("G"), p.layer("Inner"), p.layer("Deep"), p.layer("G1")])
        check(!p.vis("T") && !p.vis("G") && !p.vis("Inner") && !p.vis("Deep") && !p.vis("G1") && p.vis("B"),
              "from a layer across a group and its nested rows: all hidden")
        let fx = d.state.layer(p.id("T"))!.effects
        check(fx.enabled && fx.listedSlots.allSatisfy(fx.isShown), "a layer drag passing effect rows leaves the effects alone")
        d.undo()
        // starting inside the group and leaving it
        p.dragAcross([p.layer("Deep"), p.layer("G1"), p.layer("B")])
        check(!p.vis("Deep") && !p.vis("G1") && !p.vis("B") && p.vis("G") && p.vis("Inner"), "from a nested row out of the group: rows passed only")
        d.undo()
        // a collapsed group: its rows are gone from the column (also before they report having gone)
        LayerGroups.toggle(d, p.id("G"), recursive: false)
        UIFixesSelfTest.spin(0.3)
        let rows = d.state.layers.flattenedForDisplay().map { p.name($0.0.id) }
        let col = p.drag.frames.filter(\.target.isLayer).map { p.name($0.target.layerID) }
        check(col == rows, "group collapsed: the eye column has just the rows shown", "\(col)")
        p.dragAcross([p.layer("G"), p.layer("B")])
        check(!p.vis("G") && !p.vis("B") && p.vis("G1") && p.vis("Deep") && p.vis("Inner"), "drag over a collapsed group: the group, not the layers folded in it")
        d.undo()
        LayerGroups.toggle(d, p.id("G"), recursive: false)
        UIFixesSelfTest.spin(0.3)
    }

    // MARK: Effect rows

    static func effects(_ p: Panel) {
        let d = p.d, tid = p.id("T")
        let ds = EyeTarget.effect(tid, EffectSlot(kind: .dropShadow)), ds2 = EyeTarget.effect(tid, EffectSlot(kind: .dropShadow, index: 1))
        let stroke = EyeTarget.effect(tid, EffectSlot(kind: .stroke)), master = EyeTarget.effects(tid)
        guard p.point(ds) != nil, p.point(ds2) != nil, p.point(stroke) != nil else { check(false, "effect rows loaded"); return }
        let n0 = d.historyIndex
        p.dragAcross([ds, ds2, stroke])
        var fx = d.state.layer(tid)!.effects
        check(!fx.isShown(ds.slot!) && !fx.isShown(ds2.slot!) && !fx.isShown(stroke.slot!) && fx.listedSlots.count == 3 && fx.enabled,
              "drag across effect eyes: each effect hidden (still listed), the Effects switch untouched")
        check(d.historyIndex == n0 + 1 && d.history[d.historyIndex].name == "Hide Effects", "one step “Hide Effects”", d.history[d.historyIndex].name ?? "")
        check(p.vis("T"), "the layer itself stays visible")
        p.dragAcross([stroke, ds, ds2])
        fx = d.state.layer(tid)!.effects
        check(fx.listedSlots.allSatisfy(fx.isShown) && d.history[d.historyIndex].name == "Show Effects", "and back: all shown, “Show Effects”")
        // an effect drag skips layer rows; it may continue to the Effects row
        p.dragAcross([ds2, p.layer("G"), p.layer("Inner")])
        check(!d.state.layer(tid)!.effects.isShown(ds2.slot!) && p.vis("G") && p.vis("Inner"), "an effect drag doesn't touch layer rows")
        d.undo()
        p.dragAcross([stroke, master])
        fx = d.state.layer(tid)!.effects
        check(!fx.enabled && !fx.isShown(stroke.slot!), "the Effects row (master switch) is an effect row too")
        d.undo()
        // a single click on an effect eye keeps its old step name
        p.dragAcross([ds])
        check(d.history[d.historyIndex].name == "Hide Drop Shadow", "one effect eye clicked: “Hide Drop Shadow”", d.history[d.historyIndex].name ?? "")
        d.undo()
        p.dragAcross([master])
        check(d.history[d.historyIndex].name == "Hide Layer Effects", "the Effects eye clicked: “Hide Layer Effects”", d.history[d.historyIndex].name ?? "")
        d.undo()
    }

    // MARK: Artboard rows

    static func artboards(_ p: Panel) {
        let d = p.d
        p.dragAcross([p.layer("AB"), p.layer("Chip"), p.layer("T")])
        check(!p.vis("AB") && !p.vis("Chip") && !p.vis("T") && d.history[d.historyIndex].name == "Hide Layers", "from an artboard's eye over its layer and the next: all hidden")
        d.undo()
        p.dragAcross([p.layer("T"), p.layer("Chip"), p.layer("AB")])
        check(!p.vis("AB") && !p.vis("Chip") && !p.vis("T"), "upwards onto the artboard row")
        d.undo()
        p.dragAcross([p.layer("AB")])
        check(!p.vis("AB") && d.history[d.historyIndex].name == "Hide Artboard", "a click on the artboard's eye: “Hide Artboard”", d.history[d.historyIndex].name ?? "")
        d.undo()
        UIFixesSelfTest.spin(0.2)
        check(UIFixesSelfTest.ax(p.w, "Hide AB") != nil, "artboard eye has an accessibility label (“Hide AB”)")
    }

    // MARK: One undo step

    static func undo(_ p: Panel) {
        let d = p.d
        let before = EyeVisibility.visibility(d.state), n0 = d.historyIndex
        p.dragAcross([p.layer("AB"), p.layer("Chip"), p.layer("T"), p.layer("G"), p.layer("Inner"), p.layer("Deep"), p.layer("G1"), p.layer("B"), p.layer("Locked"), p.layer("A"), p.layer("Background")])
        check(EyeVisibility.visibility(d.state).values.allSatisfy { !$0 } && d.historyIndex == n0 + 1, "drag over every row: everything hidden in one step")
        d.undo()
        check(EyeVisibility.visibility(d.state) == before, "one Undo restores every eye")
        d.redo()
        check(EyeVisibility.visibility(d.state).values.allSatisfy { !$0 }, "Redo hides them again")
        d.undo()
        // no step for a press that changes nothing (an eye with no row any more)
        let n1 = d.historyIndex
        p.eye.simulate(.leftMouseDown, window: NSPoint(x: -500, y: -500)); p.eye.simulate(.leftMouseUp, window: NSPoint(x: -500, y: -500))
        check(d.historyIndex == n1, "a press outside every row does nothing")
    }

    // MARK: ⌥-click: show only this layer, and back

    static func solo(_ p: Panel) {
        let d = p.d
        let idx0 = d.historyIndex
        defer { while d.historyIndex > idx0 { d.undo() } }
        d.updateLayer(p.id("Locked")) { $0.isVisible = false }; d.commit("Hide Layer")   // a hidden layer, to see it restored
        let before = EyeVisibility.visibility(d.state), n0 = d.historyIndex
        guard let pb = p.point(p.layer("B")), let pd = p.point(p.layer("Deep")) else { check(false, "rows loaded"); return }
        func optionClick(_ pt: NSPoint) { p.eye.simulate(.leftMouseDown, window: pt, modifiers: .option); p.eye.simulate(.leftMouseUp, window: pt) }
        optionClick(pb)
        let shown = d.state.allLayers.filter(\.isVisible).map(\.name)
        check(shown == ["B"] && d.historyIndex == n0 + 1 && d.history[d.historyIndex].name == "Show/Hide Layers", "⌥-click: only this layer shown, one step", "\(shown)")
        check(!p.drag.isDragging, "⌥-click doesn't start a drag")
        optionClick(pb)
        check(EyeVisibility.visibility(d.state) == before && d.historyIndex == n0 + 2, "⌥-click again: the visibility from before comes back (hidden Locked stays hidden)")
        // nested: the groups around it stay shown
        optionClick(pd)
        let s = Set(d.state.allLayers.filter(\.isVisible).map(\.name))
        check(s == ["G", "Inner", "Deep"], "⌥-click on a nested layer: it and the groups around it", "\(s.sorted())")
        // a change in between: the next ⌥-click shows only this layer again instead of restoring
        d.updateLayer(p.id("A")) { $0.isVisible = true }; d.commit("Show Layer")
        optionClick(pd)
        check(!p.vis("A") && p.vis("Deep") && !p.vis("G1"), "after another change ⌥-click solos again (stale memory not used)")
        optionClick(pd)
        check(p.vis("A") && p.vis("Deep") && !p.vis("G1") && !p.vis("B"), "…and the next one restores what was there before it")
        // with only it shown and nothing remembered (another document soloed since), ⌥-click shows every other layer
        optionClick(pd)
        EyeVisibility.solo = nil
        optionClick(pd)
        check(d.state.allLayers.allSatisfy(\.isVisible), "⌥-click on the only visible layer with nothing to restore: all shown")
        // through accessibility, with ⌥ (the button's action) — the same command
        EyeVisibility.press(d, .layer(p.id("A")), option: true)
        check(d.state.allLayers.filter(\.isVisible).map(\.name) == ["A"], "the eye button's action with ⌥ solos as well")
        EyeVisibility.press(d, .layer(p.id("A")), option: true)
        check(d.state.allLayers.allSatisfy(\.isVisible), "…and restores")
    }

    // MARK: Right-click menu

    static func menu(_ p: Panel) {
        let d = p.d
        func titles(_ n: String) -> [String] { EyeVisibility.menuItems(d, p.id(n)).map { $0.title + ($0.enabled ? "" : " (disabled)") } }
        check(titles("B") == ["Hide This Layer", "Hide All Other Layers", "Show All Layers (disabled)"], "eye menu of a visible layer", "\(titles("B"))")
        check(titles("AB").first == "Hide This Artboard", "eye menu of an artboard", "\(titles("AB"))")
        // what a right-click on the eye column shows
        if let pb = p.point(p.layer("B")),
           let e = NSEvent.mouseEvent(with: .rightMouseDown, location: pb, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: p.w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            let m = p.eye.menu(for: e)
            check(m?.items.map(\.title) == ["Hide This Layer", "Hide All Other Layers", "Show All Layers"], "right-click on B's eye: the eye menu", "\(m?.items.map(\.title) ?? [])")
            let ctl = NSEvent.mouseEvent(with: .rightMouseDown, location: p.point(EyeTarget.effects(p.id("T"))) ?? pb, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: p.w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            check(ctl.map { p.eye.menu(for: $0) == nil } ?? false, "no eye menu on effect rows")
            // run "Hide All Other Layers" from the NSMenu itself
            if let m, let i = m.items.firstIndex(where: { $0.title == "Hide All Other Layers" }) {
                m.performActionForItem(at: i)
                let shown = d.state.allLayers.filter(\.isVisible).map(\.name)
                check(shown == ["B"] && d.history[d.historyIndex].name == "Hide All Other Layers", "Hide All Other Layers: only B left", "\(shown)")
            }
        }
        check(titles("B") == ["Hide This Layer", "Show All Other Layers", "Show All Layers"], "menu follows: Show All Other Layers, Show All Layers enabled", "\(titles("B"))")
        EyeVisibility.menuItems(d, p.id("Deep"))[0].action()
        check(p.vis("Deep") && !p.vis("Inner") && d.history[d.historyIndex].name == "Show Layer", "Show This Layer", d.history[d.historyIndex].name ?? "")
        check(titles("Deep")[1] == "Hide All Other Layers", "B is still shown: Hide All Other Layers", "\(titles("Deep"))")
        EyeVisibility.menuItems(d, p.id("Deep"))[1].action()
        check(p.vis("Deep") && !p.vis("B"), "Hide All Other Layers from a nested layer")
        EyeVisibility.menuItems(d, p.id("Deep"))[1].action()
        check(p.vis("G") && p.vis("Inner") && p.vis("B") && p.vis("A") && p.vis("Deep") && p.vis("G1") && d.history[d.historyIndex].name == "Show All Other Layers",
              "Show All Other Layers (also the groups around the layer)")
        EyeVisibility.menuItems(d, p.id("Deep"))[1].action()
        check(p.vis("Deep") && p.vis("G") && p.vis("Inner") && !p.vis("G1") && !p.vis("B") && !p.vis("AB"),
              "Hide All Other Layers keeps the groups around it shown")
        EyeVisibility.menuItems(d, p.id("Deep"))[2].action()
        check(d.state.allLayers.allSatisfy(\.isVisible) && d.history[d.historyIndex].name == "Show All Layers", "Show All Layers")
    }

    // MARK: Plain click

    static func plainClick(_ p: Panel) {
        let d = p.d
        d.selectLayer(p.id("A"))
        let n0 = d.historyIndex
        guard let pb = p.point(p.layer("B")) else { return }
        p.eye.simulate(.leftMouseDown, window: pb); p.eye.simulate(.leftMouseUp, window: pb)
        check(!p.vis("B") && p.vis("Locked") && p.vis("G1") && d.historyIndex == n0 + 1 && d.history[d.historyIndex].name == "Hide Layer", "a click toggles just that layer, “Hide Layer”")
        // a jitter inside the row is still one layer
        p.eye.simulate(.leftMouseDown, window: pb); p.eye.simulate(.leftMouseDragged, window: NSPoint(x: pb.x + 2, y: pb.y + 5)); p.eye.simulate(.leftMouseUp, window: pb)
        check(p.vis("B") && p.vis("Locked") && d.history[d.historyIndex].name == "Show Layer", "a click with a small wobble still toggles one layer")
        check(d.activeLayerID == p.id("A") && d.selectedLayerIDs == [p.id("A")], "clicking an eye doesn't change the selection")
        // the accessible eye
        UIFixesSelfTest.spin(0.2)
        check(UIFixesSelfTest.ax(p.w, "Hide B") != nil && UIFixesSelfTest.ax(p.w, "Hide Deep") != nil, "eye buttons are labelled “Hide <layer name>”")
        if let b = UIFixesSelfTest.ax(p.w, "Hide B") {
            _ = FuzzAX.press(b); UIFixesSelfTest.spin(0.2)
            check(!p.vis("B") && p.vis("Locked") && UIFixesSelfTest.ax(p.w, "Show B") != nil && d.activeLayerID == p.id("A"),
                  "pressing it (accessibility) hides B, label becomes “Show B”, selection unchanged")
            if let s = UIFixesSelfTest.ax(p.w, "Show B") { _ = FuzzAX.press(s); UIFixesSelfTest.spin(0.2) }
            check(p.vis("B"), "…and “Show B” shows it")
        }
    }

    // MARK: Real mouse events through the window

    static func mouseEvents(_ p: Panel) {
        let d = p.d
        func ev(_ type: NSEvent.EventType, _ pt: NSPoint, _ m: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: pt, modifierFlags: m, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: p.w.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        d.selectLayer(p.id("A"))
        let n0 = d.historyIndex
        guard let pb = p.point(p.layer("B")), let pl = p.point(p.layer("Locked")), let pa = p.point(p.layer("A")) else { return }
        for (t, pt) in [(NSEvent.EventType.leftMouseDown, pb), (.leftMouseDragged, pl), (.leftMouseDragged, pa), (.leftMouseUp, pa)] {
            if let e = ev(t, pt) { NSApp.sendEvent(e); UIFixesSelfTest.spin(0.05) }
        }
        UIFixesSelfTest.spin(0.1)
        check(!p.vis("B") && !p.vis("Locked") && !p.vis("A") && d.historyIndex == n0 + 1 && d.history[d.historyIndex].name == "Hide Layers",
              "mouse down / dragged / up events sent through NSApp: B, Locked and A hidden in one step",
              "B \(p.vis("B")) Locked \(p.vis("Locked")) A \(p.vis("A")), \(d.historyIndex - n0) step(s) \(d.history[d.historyIndex].name ?? "")")
        check(d.activeLayerID == p.id("A") && d.selectedLayerIDs == [p.id("A")] && !p.drag.isDragging, "…selection unchanged, drag over")
        d.undo()
        if let down = ev(.leftMouseDown, pb, .option), let up = ev(.leftMouseUp, pb, .option) {
            NSApp.sendEvent(down); UIFixesSelfTest.spin(0.05); NSApp.sendEvent(up); UIFixesSelfTest.spin(0.1)
            check(d.state.allLayers.filter(\.isVisible).map(\.name) == ["B"], "⌥-click event: only B shown")
            NSApp.sendEvent(down); UIFixesSelfTest.spin(0.05); NSApp.sendEvent(up); UIFixesSelfTest.spin(0.1)
            check(d.state.allLayers.allSatisfy(\.isVisible), "second ⌥-click event: restored")
        }
        // while a dialog is open the column lets the click through (the dialog owns the window)
        AppModel.shared.dialog = .newDocument
        check(p.eye.hitTest(p.eye.superview!.convert(pb, from: nil)) == nil, "no eye column while a dialog is open")
        AppModel.shared.dialog = nil
    }

    // MARK: Reordering rows

    static func reorder(_ p: Panel) {
        let d = p.d
        // the row outside the eye column is still the row's (its .onDrag / LayerDropDelegate); the move command and the
        // eye frames afterwards
        AppActions.moveLayer(p.id("A"), relativeTo: p.id("B"), above: true)
        UIFixesSelfTest.spin(0.3)
        let order = p.d.state.layers.flattenedForDisplay().map { p.name($0.0.id) }
        let frames = p.drag.frames.filter(\.target.isLayer).map { p.name($0.target.layerID) }
        check(order.firstIndex(of: "A")! < order.firstIndex(of: "B")! && frames == order && d.history[d.historyIndex].name == "Move Layer",
              "a layer moved (what the row drop does): the eye column follows the new order", "\(frames)")
        p.dragAcross([p.layer("A"), p.layer("B")])
        check(!p.vis("A") && !p.vis("B") && p.vis("Locked"), "dragging across eyes after the move uses the new rows")
        d.undo(); d.undo()
        UIFixesSelfTest.spin(0.3)
        let back = p.d.state.layers.flattenedForDisplay().map { p.name($0.0.id) }
        let framesBack = p.drag.frames.filter(\.target.isLayer).map { p.name($0.target.layerID) }
        check(back.firstIndex(of: "A")! > back.firstIndex(of: "B")! && framesBack == back && p.vis("A") && p.vis("B"), "undo puts it back, and the eye column follows", "\(framesBack)")
    }

    // MARK: Snapshot mid-drag

    static func snapshot(_ p: Panel, _ dir: URL) {
        guard let pb = p.point(p.layer("G")), let pa = p.point(p.layer("Locked")) else { return }
        p.eye.simulate(.leftMouseDown, window: pb)
        p.eye.simulate(.leftMouseDragged, window: pa)
        UIFixesSelfTest.spin(0.3)
        UIFixesSelfTest.snapshot(p.w, "eyedrag_middrag", dir)
        check(p.drag.isDragging && !p.vis("G") && !p.vis("B") && !p.vis("Locked") && p.vis("A") && p.vis("T"), "mid-drag snapshot: G … Locked hidden while the mouse is still down")
        p.eye.simulate(.leftMouseUp, window: pa)
        p.d.undo()
        print("eyedrag: wrote snapshot to \(dir.path)")
    }

    // MARK: Autoscroll

    static func autoscroll() {
        let L = LayersPanel2SelfTest.self
        let layers = (0..<40).map { L.rect("L\($0)", CGRect(x: $0 * 5, y: 0, width: 20, height: 20)) }
        let d = L.doc(layers)
        L.activate(d)
        let w = UIFixesSelfTest.host(LayersPanelContent(doc: d), CGSize(width: 300, height: 420))
        defer { UIFixesSelfTest.close(w); AppModel.shared.documents.removeAll { $0 === d } }
        guard let eye = findEye(w), let drag = eye.drag else { check(false, "autoscroll: panel hosted"); return }
        let top = d.state.layers.last!.id
        guard let f = drag.frame(of: .layer(top)) else { check(false, "autoscroll: top row loaded"); return }
        let vis0 = eye.visibleRect
        check(vis0.height < eye.bounds.height - 100, "fixture: the list is taller than the panel", "\(vis0) in \(eye.bounds)")
        let n0 = d.historyIndex
        eye.simulate(.leftMouseDown, window: eye.convert(CGPoint(x: 11, y: f.midY), to: nil))
        // pointer below the list (on the footer) and held there: the list scrolls and the rows coming in are hidden
        let below = eye.convert(CGPoint(x: 11, y: vis0.maxY + 30), to: nil)
        eye.simulate(.leftMouseDragged, window: below)
        var scrolled: CGFloat = 0
        for _ in 0..<200 {
            scrolled += eye.autoscrollTick()
            UIFixesSelfTest.spin(0.02)
            if eye.visibleRect.maxY >= eye.bounds.maxY - 1 { break }
        }
        _ = eye.autoscrollTick()
        let hidden = d.state.layers.filter { !$0.isVisible }.count
        check(scrolled > 200 && eye.visibleRect.minY > vis0.minY + 200, "pointer held past the bottom edge: the list scrolls down", "scrolled \(scrolled), visible \(eye.visibleRect)")
        check(hidden == 40, "…and every row scrolled past is hidden", "\(hidden) of 40")
        // and back up past the top edge
        let above = eye.convert(CGPoint(x: 11, y: eye.visibleRect.minY - 30), to: nil)
        eye.simulate(.leftMouseDragged, window: above)
        var up: CGFloat = 0
        for _ in 0..<200 {
            up += eye.autoscrollTick()
            UIFixesSelfTest.spin(0.02)
            if eye.visibleRect.minY <= 1 { break }
        }
        check(up < -200 && eye.visibleRect.minY <= 1, "past the top edge: scrolls back up", "\(up)")
        eye.simulate(.leftMouseUp, window: above)
        check(d.historyIndex == n0 + 1 && d.history[d.historyIndex].name == "Hide Layers", "one step for the scrolling drag")
        check(eye.autoscrollTick() == 0, "no scrolling once the mouse is up")
    }

    // MARK: Performance

    static func performance() {
        let L = LayersPanel2SelfTest.self
        var layers: [Layer] = [L.rect("Background", CGRect(x: 0, y: 0, width: 300, height: 300), RGBA(r: 1, g: 1, b: 1))]
        for i in 0..<120 { layers.append(L.rect("R\(i)", CGRect(x: i % 280, y: i % 280, width: 20, height: 20))) }
        for g in 0..<10 { layers.append(L.group("G\(g)", (0..<3).map { L.rect("G\(g)c\($0)", CGRect(x: $0 * 10, y: g * 10, width: 10, height: 10)) })) }
        let d = L.doc(layers)
        L.activate(d)
        check(d.state.allLayers.count >= 150, "fixture: \(d.state.allLayers.count) layers")
        let w = UIFixesSelfTest.host(LayersPanelContent(doc: d), CGSize(width: 300, height: 900))
        defer { UIFixesSelfTest.close(w); AppModel.shared.documents.removeAll { $0 === d } }
        guard let eye = findEye(w), let drag = eye.drag, let first = drag.frames.first else { check(false, "perf: panel hosted"); return }
        let loaded = drag.frames.count
        // a drag down the whole visible column in 3 pt steps, with the panel updating between steps
        let t0 = Date()
        eye.simulate(.leftMouseDown, window: eye.convert(CGPoint(x: 11, y: first.frame.midY), to: nil))
        var times: [Double] = []
        var y = first.frame.midY
        while y < eye.visibleRect.maxY - 2 {
            y += 3
            let s = Date()
            eye.simulate(.leftMouseDragged, window: eye.convert(CGPoint(x: 11, y: y), to: nil))
            times.append(Date().timeIntervalSince(s) * 1000)
            if times.count % 8 == 0 { UIFixesSelfTest.spin(0.01) }
        }
        eye.simulate(.leftMouseUp, window: eye.convert(CGPoint(x: 11, y: y), to: nil))
        UIFixesSelfTest.spin(0.2)
        let total = Date().timeIntervalSince(t0)
        times.sort()
        let avg = times.reduce(0, +) / Double(max(1, times.count)), mx = times.last ?? 0
        let hidden = d.state.allLayers.filter { !$0.isVisible }.count
        print(String(format: "eyedrag: perf %d layers, %d rows loaded: %d moves, avg %.3f ms, max %.3f ms, total %.2f s (with panel updates), %d hidden",
                     d.state.allLayers.count, loaded, times.count, avg, mx, total, hidden))
        check(hidden >= loaded - 1 && d.history[d.historyIndex].name == "Hide Layers", "drag over every loaded row hid them", "\(hidden) hidden, \(loaded) rows")
        check(avg < 2 && mx < 20, "a drag step stays fast with 150+ layers", String(format: "avg %.3f ms, max %.3f ms", avg, mx))
        // the coordinator alone over 160 row frames (every row of a long list loaded)
        let c = EyeDragCoordinator()
        c.doc = d
        let ids = d.state.layers.flattenedForDisplay(includeCollapsed: true).map { $0.0.id }
        c.setFrames(ids.enumerated().map { EyeRowFrame(target: .layer($1), frame: CGRect(x: 0, y: CGFloat($0) * 38, width: 300, height: 38)) })
        d.undo()
        let s = Date()
        c.begin(at: CGPoint(x: 5, y: 5))
        for k in 1..<(ids.count * 38 / 4) { c.move(to: CGPoint(x: 5, y: CGFloat(k) * 4)) }
        c.end()
        let sweep = Date().timeIntervalSince(s) * 1000
        print(String(format: "eyedrag: perf coordinator sweep over %d rows: %.1f ms", ids.count, sweep))
        check(d.state.allLayers.allSatisfy { !$0.isVisible } && sweep < 500, "coordinator sweep over \(ids.count) rows", String(format: "%.1f ms", sweep))
        d.undo()
    }
}

private extension EyeTarget {
    var slot: EffectSlot? { if case .effect(_, let s) = self { return s }; return nil }
}
