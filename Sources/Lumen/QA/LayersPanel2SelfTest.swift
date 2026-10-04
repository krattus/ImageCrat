import AppKit
import SwiftUI
import ImageCratCore

/// Layers panel effects / group disclosure / Move tool auto-select (see UI/Panels/LayersPanelEffects.swift and
/// Tools/AutoSelect.swift). The panel is the real SwiftUI view hosted offscreen and driven through accessibility; the Move
/// tool runs on a bare canvas with synthetic tool events.
/// `LUMEN_SELFTEST_ONLY=layerspanel2 Lumen --selftest <dir>`
enum LayersPanel2SelfTest {
    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") layerspanel2: \(name)\(d.isEmpty ? "" : " — " + d)")
        fflush(stdout)
    }

    static func run(_ out: URL) {
        passes = 0; failures = 0
        let dir = out.appendingPathComponent("layerspanel2")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppModel.shared
        let saved = (docs: app.documents, active: app.activeDocumentID, tool: app.tool, canvas: AppActions.canvas, hook: app.toolChanged,
                     auto: app.moveAutoSelect, mode: app.moveAutoSelectMode, show: app.moveShowTransform, copied: AppActions.copiedEffects,
                     collapsed: LayersPanelUI.shared.fxCollapsed, dialog: app.dialog, status: app.statusMessage)
        let prefsBefore = (UserDefaults.standard.object(forKey: AutoSelectPrefs.onKey) as? Bool, UserDefaults.standard.string(forKey: AutoSelectPrefs.modeKey))
        defer {
            app.dialog = nil
            app.documents = saved.docs; app.activeDocumentID = saved.active
            AppActions.canvas = saved.canvas; app.toolChanged = saved.hook; app.tool = saved.tool
            app.moveAutoSelect = saved.auto; app.moveAutoSelectMode = saved.mode; app.moveShowTransform = saved.show
            AppActions.copiedEffects = saved.copied
            LayersPanelUI.shared.fxCollapsed = saved.collapsed
            app.statusMessage = saved.status
            LayerHitTester.shared.clear()
        }
        effectsModel()
        effectsCommands()
        effectsPersistence(dir)
        effectsPanel()
        groups(dir)
        autoSelectHits()
        autoSelectTool()
        prefs(before: prefsBefore)
        performance()
        snapshots(dir)
        print("layerspanel2: \(passes) passed, \(failures) failed")
    }

    // MARK: Fixtures

    static func doc(_ layers: [Layer], w: Int = 300, h: Int = 300) -> Document {
        var st = DocumentState(width: w, height: h)
        st.layers = layers
        let d = Document(state: st, name: "layerspanel2")
        d.needsFitOnScreen = false
        return d
    }

    static func activate(_ d: Document) {
        let app = AppModel.shared
        if !app.documents.contains(where: { $0 === d }) { app.documents.append(d) }
        app.activeDocumentID = d.id
    }

    static func rect(_ name: String, _ r: CGRect, _ c: RGBA = RGBA(r: 0.2, g: 0.4, b: 0.9), canvas: (Int, Int) = (300, 300)) -> Layer {
        let b = PixelBuffer(width: canvas.0, height: canvas.1)
        b.context.setFillColor(c.cgColor)
        b.context.fill(r)
        b.markDirty()
        return Layer.raster(name: name, buffer: b)
    }

    static func group(_ name: String, _ children: [Layer], expanded: Bool = true, artboard: Artboard? = nil) -> Layer {
        Layer(name: name, content: .group(GroupContent(children: children, isExpanded: expanded, artboard: artboard)))
    }

    /// A type layer with a drop shadow, a second drop shadow and a stroke.
    static func styledText(_ name: String = "Title", at p: CGPoint = CGPoint(x: 30, y: 40)) -> Layer {
        var t = TextContent()
        t.text = "Lumen"; t.fontName = "Helvetica-Bold"; t.fontSize = 60; t.color = RGBA(r: 0.9, g: 0.3, b: 0.2); t.position = p
        var l = Layer(name: name, content: .text(t))
        l.effects.dropShadow = ShadowEffect(enabled: true, opacity: 1, angle: 90, distance: 30, size: 0)
        l.effects.extraDropShadows = [ShadowEffect(enabled: true, color: RGBA(r: 0, g: 0, b: 1), opacity: 1, angle: 0, distance: 25, size: 0)]
        l.effects.stroke = StrokeEffect(enabled: true, size: 3, position: .outside, paint: .color(RGBA(r: 0, g: 0.6, b: 0)))
        return l
    }

    static func flatten(_ d: Document) -> PixelBuffer {
        PixelBuffer(cgImage: Compositor.shared.flatten(d.state)!)
    }

    /// Alpha buffer (canvas) of one layer's own appearance, with or without its effects.
    static func appearance(_ l: Layer, _ d: Document, effects: Bool) -> PixelBuffer {
        var x = l
        if !effects { x.effects.enabled = false }
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        return RenderEngine.renderBuffer(Compositor.shared.layerAppearance(x, state: d.state).cropped(to: sp.ciCanvas), docRect: d.state.canvasRect, space: sp)
    }

    /// First point (scanning rows) where `pred(alphaWithEffects, alphaWithout)` holds.
    static func findPoint(_ l: Layer, _ d: Document, in r: CGRect? = nil, _ pred: (UInt8, UInt8) -> Bool) -> CGPoint? {
        let a = appearance(l, d, effects: true), b = appearance(l, d, effects: false)
        let box = (r ?? d.state.canvasCGRect).intersection(d.state.canvasCGRect)
        for y in Int(box.minY)..<Int(box.maxY) { for x in Int(box.minX)..<Int(box.maxX) where pred(a.alpha(x, y), b.alpha(x, y)) {
            return CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
        } }
        return nil
    }

    // MARK: Effects: model

    static func effectsModel() {
        var fx = styledText().effects
        let original = fx
        check(fx.hasStyle && fx.listedSlots.map { "\($0.kind.rawValue)\($0.index)" } == ["stroke0", "dropShadow0", "dropShadow1"],
              "listed effects in panel order, both drop shadow instances", "\(fx.listedSlots)")
        fx.setShown(EffectSlot(kind: .dropShadow, index: 1), false)
        check(fx.extraDropShadows[0].enabled == false && fx.extraDropShadows[0].isHidden && fx.dropShadow.enabled,
              "hiding the second drop shadow hides only that instance")
        check(fx.listedSlots.count == 3 && fx.hasStyle && fx.hasAny, "a hidden effect stays listed (nothing deleted)")
        var settingsKept = fx.extraDropShadows[0]; settingsKept.enabled = true; settingsKept.isHidden = false
        check(settingsKept == original.extraDropShadows[0], "a hidden effect keeps every setting")
        fx.setShown(EffectSlot(kind: .dropShadow, index: 1), true)
        check(fx == original, "showing it again restores the identical effect")
        fx.setAllShown(false)
        check(!fx.hasAny && fx.hasStyle && fx.listedSlots.count == 3, "all three hidden: nothing drawn, all still listed")
        fx.setAllShown(true)
        check(fx == original, "all shown again: identical style")
        fx.setShown(EffectSlot(kind: .bevel), true)
        check(!fx.bevel.enabled && fx.listedSlots.count == 3, "the eye can't add an effect that isn't in the style")
        // the dialog checkbox removes an effect from the list (settings stay) — not the eye
        var g = original
        g.modify(EffectSlot(kind: .stroke)) { $0.setInStyle(false) }
        check(!g.stroke.enabled && !g.stroke.isHidden && g.listedSlots.count == 2 && g.stroke.size == 3, "unchecking in Layer Style removes it from the list, settings kept")
        // old documents (no isHidden key) still open
        let old = #"{"enabled":true,"distance":7}"#.data(using: .utf8)!
        let dec = try? JSONDecoder().decode(ShadowEffect.self, from: old)
        check(dec?.enabled == true && dec?.isHidden == false && dec?.distance == 7, "effects saved before per-effect visibility decode (isHidden false)")
    }

    // MARK: Effects: commands, rendering, undo

    static func effectsCommands() {
        let bg = rect("Background", CGRect(x: 0, y: 0, width: 300, height: 300), RGBA(r: 1, g: 1, b: 1))
        let t = styledText()
        let other = { var l = rect("Badge", CGRect(x: 200, y: 200, width: 40, height: 40)); l.effects.outerGlow.enabled = true; return l }()
        let d = doc([bg, other, t])
        activate(d)
        let id = t.id
        // points only drawn by the primary drop shadow / the second one / the stroke
        let lt = d.state.layer(id)!
        func onlyBy(_ slot: EffectSlot) -> CGPoint? {
            var solo = lt, others = lt
            solo.effects.setAllShown(false)
            solo.effects.setShown(slot, true)
            others.effects.setShown(slot, false)
            let a = appearance(solo, d, effects: true), o = appearance(others, d, effects: true)
            for y in 0..<d.state.height { for x in 0..<d.state.width where a.alpha(x, y) > 250 && o.alpha(x, y) == 0 {
                return CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
            } }
            return nil
        }
        let pShadow = onlyBy(EffectSlot(kind: .dropShadow, index: 0)), pShadow2 = onlyBy(EffectSlot(kind: .dropShadow, index: 1))
        check(pShadow != nil && pShadow2 != nil, "fixture: points drawn only by each drop shadow")
        func px(_ p: CGPoint?) -> (UInt8, UInt8, UInt8, UInt8) { guard let p else { return (0, 0, 0, 0) }; return flatten(d).pixel(Int(p.x), Int(p.y)) }
        let shadowOn = px(pShadow)
        check(shadowOn.0 < 60 && shadowOn.1 < 60, "drop shadow drawn", "\(shadowOn)")

        let steps0 = d.history.count
        LayerFX.setShown(d, id, EffectSlot(kind: .dropShadow), false)
        let l1 = d.state.layer(id)!
        check(d.history.count == steps0 + 1 && d.history.last?.name == "Hide Drop Shadow", "hiding an effect is one history step", d.history.last?.name ?? "")
        check(l1.effects.dropShadow.isHidden && l1.effects.dropShadow.distance == 30 && l1.effects.listedSlots.count == 3, "hidden drop shadow kept with its settings")
        let shadowOff = px(pShadow), shadow2 = px(pShadow2)
        check(shadowOff.0 > 200 && shadowOff.1 > 200 && shadowOff.2 > 200, "hidden drop shadow not drawn", "\(shadowOff)")
        check(shadow2.2 > 150 && shadow2.0 < 60, "the second drop shadow is still drawn", "\(shadow2)")
        d.undo()
        check(d.state.layer(id)!.effects == t.effects && px(pShadow).0 < 60, "undo shows it again")
        d.redo()
        check(d.state.layer(id)!.effects.dropShadow.isHidden, "redo hides it again")

        // master switch ("Effects" eye)
        LayerFX.toggleMaster(d, id)
        let l2 = d.state.layer(id)!
        check(!l2.effects.enabled && l2.effects.hasStyle && l2.effects.listedSlots.count == 3 && d.history.last?.name == "Hide Layer Effects",
              "Effects eye off: master switch only, style and individual eyes kept")
        check(px(pShadow2).2 > 200 && px(pShadow2).0 > 200, "master off: no effect drawn")
        // showing one effect while the master is off switches the master on; the others keep their own eyes
        LayerFX.setShown(d, id, EffectSlot(kind: .dropShadow, index: 1), true)
        let l3 = d.state.layer(id)!
        check(l3.effects.enabled && l3.effects.dropShadow.isHidden && l3.effects.extraDropShadows[0].enabled, "showing an effect turns the master on, hidden ones stay hidden")
        d.undo()
        check(!d.state.layer(id)!.effects.enabled, "…as one undo step")
        LayerFX.toggleMaster(d, id)
        check(d.state.layer(id)!.effects.enabled, "Effects eye on again")

        // Hide All / Show All Effects: document-wide master switches, one step each
        let n0 = d.history.count
        LayerFX.setAllEffects(d, shown: false)
        check(d.history.count == n0 + 1 && LayerFX.styled(d).allSatisfy { !$0.effects.enabled } && LayerFX.styled(d).count == 2,
              "Hide All Effects: every styled layer, one step", "\(LayerFX.styled(d).map(\.effects.enabled))")
        check(!LayerFX.anyEffectsShown(d) && LayerFX.anyEffectsHidden(d), "menu state: Show All Effects enabled, Hide All disabled")
        LayerFX.setAllEffects(d, shown: true)
        check(LayerFX.styled(d).allSatisfy { $0.effects.enabled } && d.state.layer(id)!.effects.dropShadow.isHidden,
              "Show All Effects: masters on, an individually hidden effect stays hidden")
        let items = MenuRegistry.items(for: "Layer/Layer Style").map(\.title)
        check(["Hide All Effects", "Show All Effects", "Scale Effects…"].allSatisfy(items.contains), "Layer ▸ Layer Style menu items registered", "\(items)")

        // Layer Style dialog: checkbox semantics, double-click opens the right instance without switching it on
        let dlg = LayerStyleDialog(layerID: id)
        let box = dlg.enabledBinding(.dropShadow, 0, dlg.fxBinding())
        check(box.wrappedValue == false, "a hidden effect shows unchecked in Layer Style")
        box.wrappedValue = true
        let l4 = d.state.layer(id)!
        check(l4.effects.dropShadow.enabled && !l4.effects.dropShadow.isHidden, "checking it shows it")
        d.revertUncommitted()
        LayerFX.openStyle(EffectSlot(kind: .dropShadow, index: 1), layer: id, doc: d)
        var opened = false
        if case .layerStyle(let x)? = AppModel.shared.dialog, x == id { opened = true }
        check(opened && LayerStyleDialog.openingSection?.section == .dropShadow && LayerStyleDialog.openingInstance == 1,
              "double-click on an effect row opens Layer Style on that effect instance")
        check(d.state.layer(id)!.effects.dropShadow.isHidden, "opening it doesn't show a hidden effect")
        AppModel.shared.dialog = nil

        // Copy / Paste Layer Style keep hidden effects and the master switch; Clear is the only delete
        d.selectLayer(id)
        LayerFX.toggleMaster(d, id)
        AppActions.copyLayerStyle()
        d.selectLayer(bg.id)
        AppActions.pasteLayerStyle()
        let pasted = d.state.layer(bg.id)!.effects
        check(pasted == d.state.layer(id)!.effects && pasted.dropShadow.isHidden && !pasted.enabled, "Paste Layer Style carries hidden effects and the master switch")
        AppActions.clearLayerStyle()
        check(!d.state.layer(bg.id)!.effects.hasStyle && d.history.last?.name == "Clear Layer Style", "Clear Layer Style works on a style whose effects are all hidden")

        // Scale Effects
        d.selectLayer(id)
        let before = d.state.layer(id)!.effects
        LayerFX.scaleEffects(d, base: [id: before], factor: 2)
        d.commit("Scale Effects")
        let sc = d.state.layer(id)!.effects
        check(sc.dropShadow.distance == 60 && sc.extraDropShadows[0].distance == 50 && sc.stroke.size == 6 && sc.dropShadow.isHidden && !sc.enabled,
              "Scale Effects doubles sizes / distances, keeps visibility")
        d.undo()
        check(d.state.layer(id)!.effects == before, "Scale Effects undoes in one step")
        AppModel.shared.documents.removeAll { $0 === d }
    }

    // MARK: Effects: .lumen and PSD

    static func effectsPersistence(_ dir: URL) {
        var t = styledText()
        t.effects.setShown(EffectSlot(kind: .dropShadow, index: 1), false)
        var u = styledText("Off")
        u.effects.enabled = false
        u.effects.setShown(EffectSlot(kind: .stroke), false)
        let d = doc([rect("Background", CGRect(x: 0, y: 0, width: 300, height: 300), RGBA(r: 1, g: 1, b: 1)), t, u])
        let url = dir.appendingPathComponent("effects.imagecrat")
        do {
            try DocumentIO.saveNative(d, to: url)
            let back = try DocumentIO.load(url: url)
            check(back.state.layer(t.id)?.effects == t.effects && back.state.layer(u.id)?.effects == u.effects, ".imagecrat keeps hidden effects and the master switch")
        } catch { check(false, ".imagecrat round trip", "\(error)") }

        // lfx2: every effect of the style is written ('present'), hidden ones with 'enab' false, the master as masterFXSwitch
        let root = PSDLayerStyle.descriptor(t.effects)
        let drops = root.list("dropShadowMulti")?.compactMap(\.objectValue) ?? []
        check(drops.count == 2 && drops[0].bool("enab") == true && drops[1].bool("enab") == false && drops.allSatisfy { $0.bool("present") == true },
              "lfx2: both drop shadows written, the hidden one with enab false", "\(drops.map { $0.bool("enab") as Any })")
        check(root.bool("masterFXSwitch") == true && root.object("FrFX")?.bool("enab") == true, "lfx2: master switch and stroke")
        let rootU = PSDLayerStyle.descriptor(u.effects)
        check(rootU.bool("masterFXSwitch") == false && rootU.object("FrFX")?.bool("enab") == false && rootU.list("dropShadowMulti")?.count == 2,
              "lfx2: master off and a hidden stroke still written")
        check(PSDLayerStyle.decode(PSDLayerStyle.encode(t.effects)).map { $0.listedSlots == t.effects.listedSlots && $0.extraDropShadows.first?.isHidden == true } ?? false,
              "lfx2 decodes hidden effects as hidden (listed)")
        var onlyHidden = Layer.raster(name: "x", width: 4, height: 4)
        onlyHidden.effects.dropShadow.enabled = true
        onlyHidden.effects.setAllShown(false)
        check(PSDLayerStyle.shouldEncode(onlyHidden.effects), "a style whose effects are all hidden is still exported")

        let psd = dir.appendingPathComponent("effects.psd")
        do {
            try PSDExport.write(d.state, to: psd)
            let back = try DocumentIO.load(url: psd)
            let bt = back.state.allLayers.first { $0.name == "Title" }, bu = back.state.allLayers.first { $0.name == "Off" }
            check(bt?.effects.listedSlots == t.effects.listedSlots && bt?.effects.extraDropShadows.first?.isHidden == true && bt?.effects.dropShadow.enabled == true,
                  "PSD export → import keeps a hidden drop shadow listed and hidden", "\(String(describing: bt?.effects.listedSlots))")
            check(bu?.effects.enabled == false && bu?.effects.stroke.isHidden == true && bu?.effects.listedSlots.count == 3,
                  "PSD export → import keeps the master switch off and a hidden stroke")
        } catch { check(false, "PSD export round trip", "\(error)") }
    }

    // MARK: Effects: the panel itself

    static func effectsPanel() {
        let t = styledText()
        let d = doc([rect("Background", CGRect(x: 0, y: 0, width: 300, height: 300), RGBA(r: 1, g: 1, b: 1)), t])
        activate(d)
        LayersPanelUI.shared.fxCollapsed.remove(t.id)
        let w = UIFixesSelfTest.host(LayersPanelContent(doc: d), CGSize(width: 300, height: 420))
        defer { UIFixesSelfTest.close(w); AppModel.shared.documents.removeAll { $0 === d } }
        func press(_ label: String) -> Bool {
            guard let b = UIFixesSelfTest.ax(w, label) else { return false }
            let ok = FuzzAX.press(b)
            UIFixesSelfTest.spin(0.25)
            return ok
        }
        func has(_ label: String) -> Bool { UIFixesSelfTest.ax(w, label) != nil }
        check(has("Hide Effects") && has("Hide Stroke") && has("Hide Drop Shadow") && has("Hide Drop Shadow 2"), "panel lists Effects and each effect with an eye")
        check(press("Hide Drop Shadow 2"), "press the second drop shadow's eye")
        check(d.state.layer(t.id)!.effects.extraDropShadows[0].isHidden && has("Show Drop Shadow 2") && has("Hide Drop Shadow"),
              "its row stays, with a closed eye; the first drop shadow is untouched")
        // the reported bug: hiding the effects removed them from the panel with no way back
        check(press("Hide Effects"), "press the Effects eye")
        check(!d.state.layer(t.id)!.effects.enabled && has("Show Effects") && has("Hide Stroke"), "with the master off every row is still there")
        check(press("Show Effects") && d.state.layer(t.id)!.effects.enabled, "…and the Effects eye brings them back")
        check(press("Show Drop Shadow 2") && d.state.layer(t.id)!.effects == t.effects, "the second drop shadow is shown again, identical to before")
        check(press("Collapse Effects") && LayersPanelUI.shared.fxCollapsed.contains(t.id) && !has("Hide Stroke"), "the fx triangle folds the effect list away")
        check(press("Expand Effects") && has("Hide Stroke"), "…and opens it again")
    }

    // MARK: Groups

    static func groups(_ dir: URL) {
        let deep = rect("Deep", CGRect(x: 10, y: 60, width: 40, height: 40))
        let inner = group("Inner", [deep], expanded: false)
        let b = rect("B", CGRect(x: 100, y: 100, width: 20, height: 20))
        let outer = group("Outer", [inner, b], expanded: false)
        let d = doc([rect("Background", CGRect(x: 0, y: 0, width: 300, height: 300), RGBA(r: 1, g: 1, b: 1)), outer])
        activate(d)
        d.selectLayer(b.id)
        func exp(_ id: UUID) -> Bool { d.state.layer(id)?.isExpanded ?? false }
        let steps = d.history.count, rv = d.renderVersion
        LayerGroups.toggle(d, outer.id, recursive: false)
        check(exp(outer.id) && !exp(inner.id), "triangle opens the group (nested group unchanged)")
        check(d.history.count == steps && !d.isDirty && d.renderVersion == rv, "no history step, not dirty, no re-render")
        check(d.activeLayerID == b.id, "selection doesn't jump")
        d.revertUncommitted()
        check(exp(outer.id), "survives Cancel / Esc (revertUncommitted) — was reset before")
        d.updateLayer(b.id) { $0.opacity = 0.5 }
        d.commit("Opacity Change")
        d.undo()
        check(exp(outer.id), "survives Undo of an unrelated step")
        d.redo()
        LayerGroups.toggle(d, outer.id, recursive: false)
        d.undo()
        check(!exp(outer.id), "Undo doesn't reopen a group closed afterwards")
        LayerGroups.toggle(d, outer.id, recursive: true)
        check(exp(outer.id) && exp(inner.id), "⌥-click opens the group and every group inside")
        LayerGroups.toggle(d, outer.id, recursive: true)
        check(!exp(outer.id) && !exp(inner.id), "⌥-click again closes them all")
        LayerGroups.expandAll(d)
        check(exp(outer.id) && exp(inner.id), "Expand All Groups")
        LayerGroups.collapseAll(d)
        check(!exp(outer.id) && !exp(inner.id), "Collapse All Groups")
        let rows: [String] = d.state.layers.flattenedForDisplay().map { $0.0.name }
        check(rows == ["Outer", "Background"], "collapsed groups hide their rows", "\(rows)")
        // auto-reveal
        LayerGroups.reveal(d, deep.id)
        check(exp(outer.id) && exp(inner.id) && LayersPanelUI.shared.reveal?.id == deep.id, "auto-reveal opens the groups around a layer and scrolls to it")
        // persistence, per document
        LayerGroups.toggle(d, inner.id, recursive: false)
        let url = dir.appendingPathComponent("groups.imagecrat")
        do {
            try DocumentIO.saveNative(d, to: url)
            let back = try DocumentIO.load(url: url)
            check(back.state.layer(outer.id)?.isExpanded == true && back.state.layer(inner.id)?.isExpanded == false, "disclosure state is saved per group in the document")
            LayerGroups.collapseAll(back)
            check(exp(outer.id) && back.state.layer(outer.id)?.isExpanded == false, "two documents with the same layers don't share disclosure state")
        } catch { check(false, "groups .imagecrat round trip", "\(error)") }

        // the panel: the triangle is pressed through accessibility; whole row height; doesn't select
        d.selectLayer(b.id)
        LayerGroups.collapseAll(d)
        let w = UIFixesSelfTest.host(LayersPanelContent(doc: d), CGSize(width: 300, height: 360))
        defer { UIFixesSelfTest.close(w); AppModel.shared.documents.removeAll { $0 === d } }
        let tri = UIFixesSelfTest.ax(w, "Expand Group")
        let frame = tri.flatMap { UIFixesSelfTest.windowRect($0, w) } ?? .zero
        check(frame.height >= 30 && frame.width >= 14, "disclosure triangle target covers the row height", "\(frame)")
        if let tri { _ = FuzzAX.press(tri); UIFixesSelfTest.spin(0.3) }
        check(exp(outer.id) && d.activeLayerID == b.id && UIFixesSelfTest.axTexts(w).contains("Inner"), "pressing it opens the group in the panel, selection unchanged")
        // row clicks next to the triangle don't count as selecting: the row's own hit test
        func ctl(_ x: CGFloat) -> Bool { LayerRow.inControl(x, isGroup: true, depth: 1) }
        check(ctl(10) && ctl(31 + 14 + 8) && !ctl(31 + 14 + LayerRow.disclosureWidth + 10) && !LayerRow.inControl(40, isGroup: false, depth: 0),
              "eye and triangle areas don't select the row")
    }

    // MARK: Auto-select: hit testing across layer kinds

    struct Scene {
        let d: Document
        var ids: [String: UUID] = [:]
        func id(_ n: String) -> UUID { ids[n]! }
        func name(_ id: UUID?) -> String { id.flatMap { i in d.state.layer(i)?.name } ?? "nil" }
    }

    static func scene() -> Scene {
        let bg = rect("Background", CGRect(x: 0, y: 0, width: 300, height: 300), RGBA(r: 1, g: 1, b: 1))
        var locked = rect("Locked", CGRect(x: 10, y: 250, width: 40, height: 40)); locked.locks.all = true
        var masked = rect("Masked", CGRect(x: 60, y: 10, width: 80, height: 40))
        let mb = PixelBuffer(width: 300, height: 300, format: .gray)
        mb.context.setFillColor(gray: 1, alpha: 1); mb.context.fill(CGRect(x: 0, y: 0, width: 100, height: 300)); mb.markDirty()
        masked.mask = LayerMask(buffer: mb, origin: .zero, outsideValue: 0)
        var hidden = rect("Hidden", CGRect(x: 150, y: 10, width: 40, height: 40)); hidden.isVisible = false
        let adjust = Layer(name: "Adjust", content: .adjustment(AdjustmentSettings(kind: .invert)))
        var shape = Layer(name: "Shape", content: .shape(ShapeContent(geometry: .ellipse(CGRect(x: 60, y: 60, width: 40, height: 40)), fill: .color(RGBA(r: 0.1, g: 0.6, b: 0.2)))))
        shape.effects.dropShadow = ShadowEffect(enabled: true, opacity: 1, angle: 90, distance: 22, size: 0)
        let base = rect("Clip Base", CGRect(x: 110, y: 110, width: 40, height: 40))
        var clipped = rect("Clipped", CGRect(x: 100, y: 100, width: 90, height: 90), RGBA(r: 0.8, g: 0.1, b: 0.1)); clipped.isClipped = true
        let deep = rect("Deep", CGRect(x: 10, y: 60, width: 40, height: 40))
        let g = group("G", [group("Inner", [deep], expanded: false)], expanded: false)
        let chip = rect("Chip", CGRect(x: 200, y: 60, width: 100, height: 80))
        let ab = group("AB", [group("Card", [chip])], artboard: Artboard(rect: CGRect(x: 200, y: 60, width: 100, height: 40), background: nil))
        var tc = TextContent()
        tc.text = "I    I"; tc.fontName = "Helvetica-Bold"; tc.fontSize = 60; tc.position = CGPoint(x: 10, y: 160)
        let text = Layer(name: "T", content: .text(tc))
        let disk = PixelBuffer(width: 40, height: 40)
        disk.context.setFillColor(RGBA(r: 0.9, g: 0.7, b: 0.1).cgColor); disk.context.fillEllipse(in: CGRect(x: 0, y: 0, width: 40, height: 40)); disk.markDirty()
        let so = Layer(name: "SO", content: .smartObject(SmartObjectContent(source: .image(disk), quad: Quad(rect: CGRect(x: 200, y: 160, width: 40, height: 40)))))
        var fill = Layer(name: "Fill", content: .fill(FillContent(paint: .color(RGBA(r: 0.5, g: 0.2, b: 0.7)))))
        let fb = PixelBuffer(width: 300, height: 300, format: .gray)
        fb.context.setFillColor(gray: 1, alpha: 1); fb.context.fill(CGRect(x: 250, y: 250, width: 40, height: 40)); fb.markDirty()
        fill.mask = LayerMask(buffer: fb, origin: .zero, outsideValue: 0)
        let layers = [bg, locked, masked, hidden, adjust, shape, base, clipped, g, ab, text, so, fill]
        var s = Scene(d: doc(layers))
        for l in s.d.state.allLayers { s.ids[l.name] = l.id }
        return s
    }

    static func autoSelectHits() {
        let s = scene(), d = s.d
        let h = LayerHitTester.shared
        h.clear()
        func pick(_ x: Double, _ y: Double, _ mode: AutoSelectMode = .layer) -> String { s.name(h.target(at: CGPoint(x: x, y: y), in: d, mode: mode)) }
        check(pick(80, 30) == "Masked" && pick(120, 30) == "Background", "layer mask: picked where it shows, clicked through where it hides", "\(pick(80, 30)) / \(pick(120, 30))")
        check(pick(170, 30) == "Background", "hidden layers are skipped")
        check(pick(5, 5) == "Background", "adjustment layers have no pixels of their own")
        check(pick(30, 270) == "Background", "locked layers are clicked through")
        check(h.layers(at: CGPoint(x: 30, y: 270), in: d).map { s.name($0) } == ["Locked", "Background"], "…but listed under the cursor (context menu), topmost first")
        check(pick(80, 80) == "Shape", "shape picked on its fill")
        let shapeLayer = d.state.layer(s.id("Shape"))!
        let shadowPt = findPoint(shapeLayer, d) { a, b in a > 250 && b == 0 }
        check(shadowPt.map { pick($0.x, $0.y) } == "Shape", "a drop shadow picks its layer (as in Photoshop)", "\(String(describing: shadowPt))")
        LayerFX.setShown(d, s.id("Shape"), EffectSlot(kind: .dropShadow), false)
        check(shadowPt.map { pick($0.x, $0.y) } == "Background", "…not once the drop shadow is hidden")
        LayerFX.setShown(d, s.id("Shape"), EffectSlot(kind: .dropShadow), true)
        LayerFX.toggleMaster(d, s.id("Shape"))
        check(shadowPt.map { pick($0.x, $0.y) } == "Background", "…nor with the layer's effects switched off")
        LayerFX.toggleMaster(d, s.id("Shape"))
        check(shadowPt.map { pick($0.x, $0.y) } == "Shape", "…and again once they're back on (cache follows the change)")
        check(pick(130, 130) == "Clipped" && pick(170, 170) == "Background", "clipped layer: only where its base has pixels", "\(pick(130, 130)) / \(pick(170, 170))")
        check(pick(30, 80) == "Deep" && pick(30, 80, .group) == "G", "layer mode picks the layer, group mode its outermost group")
        check(pick(80, 30, .group) == "Masked", "group mode: a layer outside groups is picked itself")
        check(pick(250, 80) == "Chip" && pick(250, 80, .group) == "Card", "artboard acts as a group: group mode picks the top-level group inside it")
        check(pick(250, 120) == "Background", "artboard clips its children: nothing picked outside its rectangle")
        let tl = d.state.layer(s.id("T"))!
        let glyph = findPoint(tl, d) { a, _ in a > 250 }
        let tb = TextRenderer.docBounds(tl.text!)
        let gap = findPoint(tl, d, in: tb.insetBy(dx: 4, dy: 8)) { a, _ in a == 0 }
        check(glyph.map { pick($0.x, $0.y) } == "T", "type: picked on its glyphs", "\(String(describing: glyph))")
        check(gap.map { pick($0.x, $0.y) } == "Background", "type: not between its glyphs (Photoshop picks pixels, not the box)", "\(String(describing: gap)) in \(tb)")
        check(pick(220, 180) == "SO" && pick(201, 161) == "Background", "smart object: its rendered pixels, not its box")
        check(pick(270, 270) == "Fill" && pick(240, 270) == "Background", "fill layer: where its mask shows it")
        check(h.target(at: CGPoint(x: -5, y: 10), in: d, mode: .layer) == nil, "nothing outside the canvas")
        var gHidden = d.state.layer(s.id("G"))!; gHidden.isVisible = false
        d.updateLayer(s.id("G")) { $0 = gHidden }
        check(pick(30, 80) == "Background", "children of a hidden group are skipped")
        d.revertUncommitted()
        d.updateLayer(s.id("G")) { $0.locks.position = true }
        check(pick(30, 80, .group) == "Background" && pick(30, 80) == "Deep", "group mode: a locked group is clicked through")
        d.revertUncommitted()
        let marq = h.layers(in: CGRect(x: 55, y: 5, width: 240, height: 40), of: d, mode: .layer).map { s.name($0) }
        check(Set(marq) == ["Masked", "Background"], "marquee: visible, unlocked layers whose content meets the rectangle", "\(marq)")
    }

    // MARK: Auto-select: the Move tool (modifiers, hover, context menu, reveal)

    static func autoSelectTool() {
        let app = AppModel.shared
        let s = scene()
        let d = s.d
        activate(d)
        let hook = app.toolChanged, prev = AppActions.canvas
        let c = CanvasView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        AppActions.canvas = c
        c.document = d
        app.tool = .move
        app.moveShowTransform = false
        app.moveAutoSelectMode = .layer
        defer { c.document = nil; AppActions.canvas = prev; app.toolChanged = hook; AppModel.shared.documents.removeAll { $0 === d } }
        let mt = c.tool(for: .move) as! MoveTool
        func ev(_ x: Double, _ y: Double, _ m: NSEvent.ModifierFlags = []) -> ToolEvent {
            let p = CGPoint(x: x, y: y)
            return ToolEvent(doc: p, view: c.docToView(p), pressure: 1, modifiers: m, clickCount: 1, isTablet: false)
        }
        func click(_ x: Double, _ y: Double, _ m: NSEvent.ModifierFlags = []) { mt.mouseDown(ev(x, y, m)); mt.mouseUp(ev(x, y, m)) }
        func active() -> String { s.name(d.activeLayerID) }
        func selected() -> Set<String> { Set(d.selectedLayerIDs.map { s.name($0) }) }

        app.moveAutoSelect = true
        click(80, 30)
        check(active() == "Masked" && selected() == ["Masked"], "auto-select on: click picks the layer under the cursor", active())
        click(130, 130, .command)
        check(active() == "Masked", "auto-select on: ⌘-click doesn't auto-select", active())
        click(130, 130, .shift)
        check(selected() == ["Masked", "Clipped"] && active() == "Clipped", "⇧-click adds to the layer selection", "\(selected())")
        let steps = d.history.count
        click(130, 130)
        check(selected() == ["Clipped"], "plain click on one of several selected layers selects just it (like Photoshop)", "\(selected())")
        click(80, 80)
        check(selected() == ["Shape"] && d.history.count == steps, "plain click selects only that layer; a click is no history step", "\(selected())")
        app.moveAutoSelect = false
        click(130, 130)
        check(active() == "Shape", "auto-select off: click keeps the selection", active())
        click(130, 130, .command)
        check(active() == "Clipped", "auto-select off: ⌘-click auto-selects", active())
        app.moveAutoSelect = true
        // reveal: a layer deep in collapsed groups
        click(30, 80)
        check(active() == "Deep" && d.state.layer(s.id("G"))?.isExpanded == true && d.state.layer(s.id("Inner"))?.isExpanded == true,
              "picking a layer inside collapsed groups reveals it in the Layers panel")
        app.moveAutoSelectMode = .group
        click(30, 80)
        check(active() == "G", "group mode on the canvas picks the group", active())
        app.moveAutoSelectMode = .layer
        // dragging moves the picked layer
        let before = Compositor.shared.contentBounds(d.state.layer(s.id("Masked"))!, state: d.state)
        mt.mouseDown(ev(70, 20)); mt.mouseDragged(ev(75, 23)); mt.mouseDragged(ev(80, 25)); mt.mouseUp(ev(80, 25))
        let after = Compositor.shared.contentBounds(d.state.layer(s.id("Masked"))!, state: d.state)
        check(active() == "Masked" && after?.minX == (before?.minX ?? 0) + 10 && d.history.last?.name == "Move", "click-drag picks and moves the layer in one step",
              "\(String(describing: before)) → \(String(describing: after))")
        d.undo()
        // hover highlight
        d.selectLayer(s.id("Background"))
        mt.mouseMoved(ev(130, 130))
        check(mt.hoverTarget == s.id("Clipped") && LayerHitTester.shared.outline(s.id("Clipped"), in: d) != nil, "hover: the layer a click would pick is outlined")
        mt.mouseMoved(ev(130, 130, .command))
        check(mt.hoverTarget == nil, "hover: no outline while ⌘ turns auto-select off")
        app.moveAutoSelect = false
        mt.mouseMoved(ev(130, 130))
        check(mt.hoverTarget == nil, "hover: none with auto-select off")
        mt.mouseMoved(ev(130, 130, .command))
        check(mt.hoverTarget == s.id("Clipped"), "hover: ⌘ with auto-select off shows it")
        app.moveAutoSelect = true
        mt.mouseMoved(ev(170, 30))
        check(mt.hoverTarget == s.id("Background") || mt.hoverTarget == nil, "hover over a hidden layer shows what's below")
        // overlay draws without trouble with a hover target
        mt.mouseMoved(ev(80, 80))
        let ov = PixelBuffer(width: 600, height: 600)          // (y-down, like the overlay view)
        mt.drawOverlay(ov.context)
        ov.markDirty()
        var drawn = 0
        let sp = c.docToView(CGPoint(x: 60, y: 80))            // left edge of the ellipse's box
        for dx in -2...2 where ov.alpha(Int(sp.x) + dx, Int(sp.y)) > 100 { drawn += 1 }
        check(mt.hoverTarget == s.id("Shape") && drawn > 0, "hover outline drawn on the overlay", "at \(sp): \(drawn)")
        // ⇧-drag on empty canvas: layer marquee
        d.updateLayer(s.id("Background")) { $0.isVisible = false }
        d.commit("Hide Layer")
        d.selectLayer(s.id("Shape"))
        mt.mouseDown(ev(295, 2, .shift)); mt.mouseDragged(ev(200, 30, .shift)); mt.mouseDragged(ev(55, 45, .shift))
        check(mt.marqueeRect != nil, "⇧-drag from an empty spot draws a layer marquee")
        mt.mouseUp(ev(55, 45, .shift))
        check(selected() == ["Shape", "Masked"] && mt.marqueeRect == nil, "…and adds the layers it touches to the selection", "\(selected())")
        d.undo()
        // context menu: layers under the cursor
        let menu = mt.contextMenu(ev(30, 270))
        let titles = menu?.items.prefix(2).map(\.title) ?? []
        check(titles == ["Locked", "Background"], "right-click lists the layers under the cursor", "\(titles)")
        if let item = menu?.items.first(where: { $0.title == "Locked" }) { AutoSelectMenuTarget.shared.pick(item) }
        check(active() == "Locked", "choosing one selects it (locked layers too)")
    }

    // MARK: Preferences

    static func prefs(before: (Bool?, String?)) {
        let now = (UserDefaults.standard.object(forKey: AutoSelectPrefs.onKey) as? Bool, UserDefaults.standard.string(forKey: AutoSelectPrefs.modeKey))
        check(AutoSelectPrefs.automated && now.0 == before.0 && now.1 == before.1, "automated runs never write the user's auto-select preference")
        check(AutoSelectPrefs.resolveOn(nil) == true && AutoSelectPrefs.resolveOn(false) == false && AutoSelectPrefs.resolveMode(nil) == .layer && AutoSelectPrefs.resolveMode("Group") == .group,
              "auto-select is on for new users and remembers the user's choice")
    }

    // MARK: Performance

    static func performance() {
        var rng = SystemRandomNumberGenerator()
        var layers: [Layer] = [rect("Background", CGRect(x: 0, y: 0, width: 1200, height: 1200), RGBA(r: 1, g: 1, b: 1), canvas: (1200, 1200))]
        for i in 0..<110 {
            let w = Double.random(in: 30...220, using: &rng), h = Double.random(in: 30...220, using: &rng)
            let b = PixelBuffer(width: Int(w), height: Int(h))
            b.context.setFillColor(RGBA(r: 0.3, g: 0.5, b: 0.7).cgColor); b.context.fillEllipse(in: CGRect(x: 0, y: 0, width: w, height: h)); b.markDirty()
            layers.append(Layer.raster(name: "R\(i)", buffer: b, origin: IPoint(x: Int.random(in: 0...1000, using: &rng), y: Int.random(in: 0...1000, using: &rng))))
        }
        for i in 0..<25 {
            var t = TextContent(); t.text = "Text \(i)"; t.fontSize = Double.random(in: 20...60, using: &rng)
            t.position = CGPoint(x: Double.random(in: 0...1000, using: &rng), y: Double.random(in: 0...1100, using: &rng))
            layers.append(Layer(name: "T\(i)", content: .text(t)))
        }
        for i in 0..<15 {
            let r = CGRect(x: Double.random(in: 0...1000, using: &rng), y: Double.random(in: 0...1000, using: &rng), width: 120, height: 80)
            var s = Layer(name: "S\(i)", content: .shape(ShapeContent(geometry: .rectangle(r, cornerRadius: 12))))
            s.effects.dropShadow.enabled = true
            layers.append(s)
        }
        let d = doc(layers, w: 1200, h: 1200)
        check(d.state.allLayers.count == 151, "fixture: 150 layers over a background")
        let h = LayerHitTester.shared
        h.clear()
        let pts = (0..<300).map { _ in CGPoint(x: Double.random(in: 0..<1200, using: &rng), y: Double.random(in: 0..<1200, using: &rng)) }
        let t0 = Date()
        var hits = 0
        for p in pts where h.target(at: p, in: d, mode: .layer) != nil { hits += 1 }
        let cold = Date().timeIntervalSince(t0)
        var times: [Double] = []
        for p in pts {
            let s = Date()
            _ = h.target(at: p, in: d, mode: .layer)
            times.append(Date().timeIntervalSince(s) * 1000)
        }
        times.sort()
        let avg = times.reduce(0, +) / Double(times.count), p95 = times[Int(Double(times.count) * 0.95)]
        print(String(format: "layerspanel2: perf 151 layers: cold %.0f ms for 300 clicks (%d masks rendered), warm avg %.3f ms, p95 %.3f ms, max %.3f ms",
                     cold * 1000, h.cachedLayerCount, avg, p95, times.last ?? 0))
        check(hits == pts.count, "every click on the background-backed canvas picks a layer")
        check(avg < 1.0 && p95 < 3.0, "warm hit test (hover rate) is fast on 150 layers", String(format: "avg %.3f ms, p95 %.3f ms", avg, p95))
        check(cold < 4.0, "cold hit tests (masks rendered on demand) stay within budget", String(format: "%.2f s", cold))
        // a move invalidates only the moved layer's mask
        let id = d.state.layers[120].id
        let r0 = h.renders
        d.updateLayer(id) { $0.translate(dx: 5, dy: 0) }
        for p in pts { _ = h.target(at: p, in: d, mode: .layer) }
        check(h.renders - r0 <= 1, "after moving one layer at most its own mask is rebuilt", "\(h.renders - r0) renders")
    }

    // MARK: Snapshots

    static func snapshots(_ dir: URL) {
        let app = AppModel.shared
        var t = styledText()
        t.effects.setShown(EffectSlot(kind: .dropShadow, index: 1), false)
        var off = styledText("Muted")
        off.effects.enabled = false
        let deep = rect("Deep layer", CGRect(x: 10, y: 60, width: 40, height: 40))
        let inner = group("Inner group", [deep, off])
        let closed = group("Closed group", [rect("Hidden inside", CGRect(x: 0, y: 0, width: 10, height: 10))], expanded: false)
        let outer = group("Outer group", [closed, inner])
        let d = doc([rect("Background", CGRect(x: 0, y: 0, width: 300, height: 300), RGBA(r: 1, g: 1, b: 1)), outer, t])
        activate(d)
        d.selectLayer(t.id)
        LayersPanelUI.shared.fxCollapsed.subtract([t.id, off.id])
        let w = UIFixesSelfTest.host(LayersPanelContent(doc: d), CGSize(width: 320, height: 620))
        UIFixesSelfTest.snapshot(w, "layers_panel_effects_groups", dir)
        UIFixesSelfTest.close(w)
        // options bar with the Move tool
        let prevTool = app.tool, prevAuto = app.moveAutoSelect, prevMode = app.moveAutoSelectMode
        app.tool = .move; app.moveAutoSelect = true; app.moveAutoSelectMode = .group
        let ob = UIFixesSelfTest.host(OptionsBar(), CGSize(width: 1100, height: 36))
        UIFixesSelfTest.snapshot(ob, "options_bar_move", dir)
        UIFixesSelfTest.close(ob)
        app.tool = prevTool; app.moveAutoSelect = prevAuto; app.moveAutoSelectMode = prevMode
        AppModel.shared.documents.removeAll { $0 === d }
        print("layerspanel2: wrote snapshots to \(dir.path)")
    }
}
