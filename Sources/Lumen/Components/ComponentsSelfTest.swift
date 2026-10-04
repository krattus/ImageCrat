import AppKit
import CoreImage
import ImageCratCore

/// `LUMEN_SELFTEST_ONLY=components .build/debug/Lumen --selftest <dir>` — sub-filter with
/// `LUMEN_COMPONENTS_ONLY=core,clip,html,ui` (comma separated prefixes).
enum ComponentsSelfTest {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
        if ok { passed += 1; print("PASS components: \(msg())") } else { failed += 1; print("FAIL components: \(msg())") }
    }

    static func run(_ out: URL) {
        let dir = out.appendingPathComponent("components")
        if ProcessInfo.processInfo.environment["LUMEN_COMPONENTS_TRACE_EXIT"] != nil {
            atexit { print("components: process exiting — stack:\n" + Thread.callStackSymbols.prefix(30).joined(separator: "\n")) }
        }
        // The WebKit snapshot tests spin the run loop. AppKit then runs its "terminate after the last window closed"
        // check (the app delegate answers yes) for windows closed by earlier offscreen snapshots, which would quit
        // the test run half-way. An ordinary window kept open off screen for the duration prevents that.
        let anchor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        anchor.orderFrontRegardless()
        defer { anchor.orderOut(nil) }
        // Debug aid: run other modules' tests first (comma-separated name prefixes) to reproduce order-dependent issues.
        if let pre = ProcessInfo.processInfo.environment["LUMEN_COMPONENTS_PRE"] {
            let wanted = pre.split(separator: ",").map(String.init)
            for (name, t) in FeatureModules.selfTests where name != "components" && wanted.contains(where: { name.hasPrefix($0) }) { t(out) }
        }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Runtime files go to a scratch folder inside the output directory, never the real support folder.
        let support = dir.appendingPathComponent("support")
        if ProcessInfo.processInfo.environment["LUMEN_SUPPORT_DIR"] == nil { ComponentsSupport.directory = support }
        let only = ProcessInfo.processInfo.environment["LUMEN_COMPONENTS_ONLY"]
        func want(_ n: String) -> Bool { only == nil || only!.split(separator: ",").contains { n.hasPrefix($0) } }
        if want("core") { testCore(dir) }
        if want("clip") { ClipboardSelfTest.run(dir) }
        if want("html") { HTMLExportSelfTest.run(dir) }
        if want("ui"), ProcessInfo.processInfo.environment["LUMEN_SELFTEST_UI"] == "1" || only?.contains("ui") == true { ComponentsUISelfTest.run(dir) }
        print("components: \(passed) passed, \(failed) failed")
    }

    // MARK: Helpers

    static func save(_ st: DocumentState, _ name: String, _ dir: URL) {
        do { try DocumentIO.export(st, to: dir.appendingPathComponent(name + ".png"), format: .png, quality: 1, scale: 1) }
        catch { print("FAIL components: write \(name): \(error)") }
    }

    static func pixels(_ st: DocumentState) -> PixelBuffer? {
        Compositor.shared.flatten(st, background: .white).map { PixelBuffer(cgImage: $0) }
    }

    /// Mean absolute difference per channel (0…255) between the composites of two states.
    static func diff(_ a: DocumentState, _ b: DocumentState) -> Double {
        guard let pa = pixels(a), let pb = pixels(b), pa.width == pb.width, pa.height == pb.height else { return 999 }
        return diff(pa, pb)
    }

    static func diff(_ pa: PixelBuffer, _ pb: PixelBuffer) -> Double {
        guard pa.width == pb.width, pa.height == pb.height else { return 999 }
        var total = 0.0
        let x = pa.data.assumingMemoryBound(to: UInt8.self), y = pb.data.assumingMemoryBound(to: UInt8.self)
        for r in 0..<pa.height { for c in 0..<(pa.width * 4) { total += abs(Double(x[r * pa.bytesPerRow + c]) - Double(y[r * pb.bytesPerRow + c])) } }
        return total / Double(pa.width * pa.height * 4)
    }

    /// Composite colour at a doc point (over white).
    static func color(_ st: DocumentState, _ x: Int, _ y: Int) -> RGBA {
        guard let p = pixels(st) else { return .clear }
        let (r, g, b, _) = p.pixel(x, y)
        return RGBA(r8: r, g8: g, b8: b)
    }

    static func near(_ a: RGBA, _ b: RGBA, _ tol: Double = 0.08) -> Bool {
        abs(a.r - b.r) < tol && abs(a.g - b.g) < tol && abs(a.b - b.b) < tol
    }

    static func photo(_ w: Int, _ h: Int, _ c1: String, _ c2: String) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: c1)!.cgColor, RGBA(hex: c2)!.cgColor] as CFArray, locations: [0, 1])!
        b.context.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        b.context.setFillColor(RGBA.white.withAlpha(0.85).cgColor)
        b.context.fillEllipse(in: CGRect(x: Double(w) * 0.3, y: Double(h) * 0.2, width: Double(w) * 0.4, height: Double(h) * 0.4))
        b.markDirty()
        return b
    }

    /// Background + the three layers of a "Button" (rounded rect, label, round avatar raster). Returns ids.
    static func buttonDoc(_ w: Int = 640, _ h: Int = 440) -> (Document, shape: UUID, label: UUID, icon: UUID) {
        var st = SelfTest.baseState(w, h)
        var shape = SelfTest.shapeLayer(CGRect(x: 40, y: 40, width: 220, height: 64), RGBA(hex: "2E6FE0")!, radius: 16)
        shape.name = "Plate"
        shape.effects.dropShadow.enabled = true; shape.effects.dropShadow.distance = 4; shape.effects.dropShadow.size = 6; shape.effects.dropShadow.opacity = 0.4
        var t = TextContent()
        t.text = "Buy now"; t.fontName = "Helvetica-Bold"; t.fontSize = 24; t.color = .white; t.position = CGPoint(x: 112, y: 58)
        let label = Layer(name: "Label", content: .text(t))
        let av = PixelBuffer(width: 44, height: 44)
        av.context.setFillColor(RGBA(hex: "FFD34E")!.cgColor)
        av.context.fillEllipse(in: CGRect(x: 0, y: 0, width: 44, height: 44))
        av.markDirty()
        let icon = Layer.raster(name: "Avatar", buffer: av, origin: IPoint(x: 54, y: 50))
        st.layers += [shape, label, icon]
        let d = Document(state: st, name: "components-test")
        return (d, shape.id, label.id, icon.id)
    }

    static func rotated(_ l: Layer, degrees: Double, scale: CGFloat, st: DocumentState) -> Layer {
        guard let q = l.smart?.quad else { return l }
        let c = q.center
        let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: CGFloat(degrees * .pi / 180)).scaledBy(x: scale, y: scale).translatedBy(x: -c.x, y: -c.y)
        return LayerTransformer.apply(Homography(affine: t), to: l, space: CanvasSpace(width: st.width, height: st.height))
    }

    static func innerText(_ l: Layer?, named: String = "Label") -> String? {
        guard case .document(let st)? = l?.smart?.source else { return nil }
        return st.allLayers.first { $0.name == named }?.text?.text
    }

    // MARK: Core component tests

    static func testCore(_ dir: URL) {
        let app = AppModel.shared
        let (d, shapeID, labelID, iconID) = buttonDoc()
        app.add(d)
        let before = d.state

        // 1. Create component from three layers
        d.selectedLayerIDs = [shapeID, labelID, iconID]
        d.activeLayerID = iconID
        guard let cid = ComponentActions.createComponent(d, name: "Button") else { check(false, "create component"); return }
        let inst1 = d.activeLayerID!
        check(d.state.components.count == 1 && d.state.components[cid]?.layers.count == 3, "create: main component stored in the document table (3 inner layers)")
        check(d.state.layers.count == 2 && d.state.layer(inst1)?.componentInstance?.componentID == cid, "create: selection replaced by one instance layer")
        check(d.state.layer(inst1)?.isSmartObject == true, "instance is a smart object (all smart-object code applies)")
        let dCreate = diff(before, d.state)
        check(dCreate < 0.6, "create: the document looks the same afterwards (mean diff \(String(format: "%.3f", dCreate)))")
        let m0 = d.state.components[cid]!
        check(m0.layers.map(\.id) == [shapeID, labelID, iconID], "create: inner layer ids are stable (override keys)")

        // 2. Three instances, scaled and rotated
        let i2 = ComponentActions.insertInstance(d, component: cid, center: CGPoint(x: 440, y: 120))!
        let i3 = ComponentActions.insertInstance(d, component: cid, center: CGPoint(x: 200, y: 300))!
        let stNow = d.state
        d.updateLayer(i2) { $0 = rotated($0, degrees: -18, scale: 1.0, st: stNow) }
        d.updateLayer(i3) { $0 = rotated($0, degrees: 0, scale: 1.5, st: stNow) }
        d.commit("Transform Instances")
        check(ComponentEngine.usageCount(cid, in: d.state) == 3, "three instances of the component")
        save(d.state, "c01_three_instances", dir)
        check(near(color(d.state, 245, 92), RGBA(hex: "2E6FE0")!, 0.12), "instance 1 renders the blue plate")
        check(near(color(d.state, 330, 332), RGBA(hex: "2E6FE0")!, 0.12), "scaled instance renders (150%)")

        // 3. Edit main component → all instances update
        app.activeDocumentID = d.id
        AppActions.editSmartContents(inst1)          // double-click path: the hook opens the main component
        guard let child = app.activeDocument, child !== d, ComponentActions.editing[child.id] != nil else { check(false, "edit main: double-click opens the main component document"); return }
        check(child.state.width == m0.width && child.state.layers.count == 3, "edit main: opens like Edit Contents (\(child.state.width)×\(child.state.height), 3 layers)")
        child.updateLayer(shapeID) { l in if var s = l.shape { s.fill = .color(RGBA(hex: "D6336C")!); l.shape = s } }
        child.updateLayer(labelID) { l in if var t = l.text { t.text = "Order"; l.text = t } }
        child.commit("Edit")
        let histBefore = d.history.count
        AppActions.save()                              // ⌘S in the child document
        check(d.history.count == histBefore + 1 && d.history.last?.name == "Edit Main Component", "edit main: saving records one history step in the parent")
        let texts = [inst1, i2, i3].map { innerText(d.state.layer($0)) }
        check(texts.allSatisfy { $0 == "Order" }, "edit main: ALL instances updated (\(texts.map { $0 ?? "nil" }))")
        check(near(color(d.state, 245, 92), RGBA(hex: "D6336C")!, 0.12) && near(color(d.state, 330, 332), RGBA(hex: "D6336C")!, 0.12), "edit main: every instance renders the new plate colour")
        save(d.state, "c02_master_edited", dir)
        app.close(child)
        app.activeDocumentID = d.id

        // 4. Overrides: text, fill, stroke n/a, image, visibility, tint
        let m = d.state.components[cid]!
        let plate = m.layers[0], label = m.layers[1], avatar = m.layers[2]
        ComponentActions.setText(d, layer: i2, inner: label, "Cancel")
        ComponentActions.setColor(d, layer: i2, inner: plate, kind: .fill, RGBA(hex: "444B59")!)
        ComponentActions.setColor(d, layer: i3, inner: label, kind: .fill, RGBA(hex: "FFE066")!)
        ComponentActions.setImage(d, layer: i3, inner: avatar, photo(120, 90, "12B886", "0B7285"), name: "photo.png")
        ComponentActions.setVisible(d, layer: inst1, inner: avatar, false)
        check(innerText(d.state.layer(i2)) == "Cancel" && innerText(d.state.layer(inst1)) == "Order", "override text: only that instance changes")
        check(near(color(d.state, 500, 110), RGBA(hex: "444B59")!, 0.12), "override fill: shape colour of one instance (\(color(d.state, 500, 110).hex))")
        check(d.state.components[cid]!.layers[1].text?.text == "Order", "overrides do not touch the main component")
        if case .document(let r3)? = d.state.layer(i3)?.smart?.source, let av = r3.layers.find(iconID)?.raster {
            let (_, g, _, a) = av.buffer.pixel(8, 22)
            let corner = av.buffer.alpha(0, 0)
            check(av.buffer.width == 44 && a > 200 && g > 100 && corner == 0, "override image: replaces the raster, keeps the placeholder's round silhouette")
        } else { check(false, "override image: resolved raster") }
        if case .document(let r1)? = d.state.layer(inst1)?.smart?.source { check(r1.layers.find(iconID)?.isVisible == false, "override visibility: inner layer hidden in one instance") }
        ComponentActions.setTint(d, layer: inst1, ComponentTint(color: RGBA(hex: "00A8E8")!, amount: 0.6))
        check(d.state.layer(inst1)?.componentInstance?.tint != nil && !near(color(d.state, 245, 92), RGBA(hex: "D6336C")!, 0.1), "override tint: whole-instance tint changes the render (\(color(d.state, 245, 92).hex))")
        save(d.state, "c03_overrides", dir)
        check(d.state.layer(i2)?.componentInstance?.overrideCount == 2 && d.state.layer(i3)?.componentInstance?.overrideCount == 2, "override table lists each override")

        // master edit keeps overrides
        var edited = DocumentState(width: m.width, height: m.height)
        edited.layers = d.state.components[cid]!.layers
        edited.layers.update(labelID) { l in if var t = l.text { t.text = "Submit"; l.text = t } }
        ComponentActions.commitMain(parent: d, component: cid, variant: nil, edited: edited)
        check(innerText(d.state.layer(i2)) == "Cancel" && innerText(d.state.layer(inst1)) == "Submit", "main edit: overridden text survives, others follow the main component")

        // reset per override / reset all
        ComponentActions.resetOverride(d, layer: i2, inner: labelID, kind: .text)
        check(innerText(d.state.layer(i2)) == "Submit" && d.state.layer(i2)?.componentInstance?.overrideCount == 1, "reset one override: text follows the main component again, fill override kept")
        ComponentActions.resetAll(d, layer: inst1)
        check(d.state.layer(inst1)?.componentInstance?.hasOverrides == false && near(color(d.state, 245, 92), RGBA(hex: "D6336C")!, 0.12), "reset all: instance equals the main component")

        // push overrides to main
        let ok = ComponentActions.pushOverrides(d, layer: i2)
        check(ok && d.state.layer(i2)?.componentInstance?.overrides.isEmpty == true, "push: instance overrides cleared")
        check(d.state.components[cid]!.layers[0].shape?.fill.solidColor == RGBA(hex: "444B59")!, "push: main component now has the pushed fill")
        check(near(color(d.state, 245, 92), RGBA(hex: "444B59")!, 0.12), "push: other instances pick up the pushed override")
        save(d.state, "c04_pushed", dir)

        // 5. Variants
        let hover = ComponentActions.addVariant(d, component: cid, name: "Hover")!
        var hv = DocumentState(width: m.width, height: m.height)
        hv.layers = d.state.components[cid]!.tree(hover).layers
        hv.layers.update(shapeID) { l in if var s = l.shape { s.fill = .color(RGBA(hex: "F59F00")!); l.shape = s } }
        ComponentActions.commitMain(parent: d, component: cid, variant: hover, edited: hv)
        check(near(color(d.state, 245, 92), RGBA(hex: "444B59")!, 0.12), "variant edit does not change instances on the default variant")
        ComponentActions.setVariant(d, layer: inst1, hover)
        check(near(color(d.state, 245, 92), RGBA(hex: "F59F00")!, 0.12), "variant: instance switched to Hover (\(color(d.state, 245, 92).hex))")
        ComponentActions.setText(d, layer: i3, inner: label, "Disabled")
        ComponentActions.setColor(d, layer: i3, inner: plate, kind: .fill, RGBA(hex: "ADB5BD")!)
        let dis = ComponentActions.saveOverridesAsVariant(d, layer: i3, name: "Disabled")
        let mm = d.state.components[cid]!
        check(dis != nil && mm.variants.count == 2 && mm.variantChoices.map(\.name) == ["Default", "Hover", "Disabled"], "variants: Default / Hover / Disabled (\(mm.variantChoices.map(\.name)))")
        check(d.state.layer(i3)?.componentInstance?.variantID == dis && innerText(d.state.layer(i3)) == "Disabled", "save overrides as variant: instance uses the new variant")
        ComponentActions.setText(d, layer: inst1, inner: label, "Hover me")
        ComponentActions.setVariant(d, layer: inst1, dis)
        check(innerText(d.state.layer(inst1)) == "Hover me", "variant switch keeps overrides (shared inner ids)")
        ComponentActions.setVariant(d, layer: inst1, hover)
        save(d.state, "c05_variants", dir)

        // 6. Duplicate / group keep instances live
        app.activeDocumentID = d.id
        d.selectLayer(i2)
        AppActions.duplicateLayers()
        let dup = d.activeLayerID!
        check(dup != i2 && d.state.layer(dup)?.componentInstance?.componentID == cid, "duplicate: the copy is an instance")
        d.updateLayer(dup) { $0.translate(dx: -20, dy: 150) }
        d.selectedLayerIDs = [i2, dup]; d.activeLayerID = dup
        AppActions.groupLayers()
        check(ComponentEngine.usageCount(cid, in: d.state) == 4, "group: instances inside a group are still counted (4)")
        var e2 = DocumentState(width: m.width, height: m.height)
        e2.layers = d.state.components[cid]!.layers
        e2.layers.update(labelID) { l in if var t = l.text { t.text = "Send"; l.text = t } }
        ComponentActions.commitMain(parent: d, component: cid, variant: nil, edited: e2)
        check(innerText(d.state.layer(dup)) == "Send" && innerText(d.state.layer(i2)) == "Send", "main edit reaches instances inside groups and duplicates")
        save(d.state, "c06_duplicate_group", dir)

        // 7. Undo / redo exactness
        let snapshot = pixels(d.state)!
        let steps = d.history.count - 1
        var undoOK = true
        for _ in 0..<steps { d.undo() }
        check(d.state.components.isEmpty && diff(d.state, before) == 0, "undo to the start: component table empty, pixels identical to the original")
        for _ in 0..<steps { d.redo() }
        if let again = pixels(d.state) { undoOK = diff(snapshot, again) == 0 } else { undoOK = false }
        check(undoOK && d.state.components[cid]?.variants.count == 2, "redo to the end: pixel-exact, table restored")
        d.undo()
        check(innerText(d.state.layer(i2)) == "Submit", "one undo restores the previous main component and its instances")
        d.redo()

        // 8. Save / load .lumen
        let url = dir.appendingPathComponent("components.imagecrat")
        do {
            try DocumentIO.saveNative(d, to: url)
            let loaded = try DocumentIO.load(url: url)
            let dd = diff(d.state, loaded.state)
            check(loaded.state.components.count == 1 && loaded.state.components[cid]?.variants.count == 2, "save/load: component table round-trips (variants included)")
            check(ComponentEngine.usageCount(cid, in: loaded.state) == 4 && dd < 0.01, "save/load: instances rebuilt from the table, identical render (diff \(String(format: "%.4f", dd)))")
            check(loaded.state.layer(inst1)?.componentInstance?.override(labelID, .text)?.text == "Hover me", "save/load: override table round-trips")
            // instances are lightweight on disk
            let enc = PropertyListEncoder(); enc.outputFormat = .binary
            let one = (try? enc.encode(ComponentCodec.stripped([d.state.layer(inst1)!], d.state.components)))?.count ?? 0
            let full = (try? enc.encode([d.state.layer(inst1)!]))?.count ?? 0
            check(one > 0 && one < full / 2 && one < 6000, "save: an instance is stored without its resolved copy (\(one) B vs \(full) B embedded)")
            // edit the loaded document's main component: still live
            var e3 = DocumentState(width: m.width, height: m.height)
            e3.layers = loaded.state.components[cid]!.layers
            e3.layers.update(labelID) { l in if var t = l.text { t.text = "Loaded"; l.text = t } }
            ComponentActions.commitMain(parent: loaded, component: cid, variant: nil, edited: e3)
            check(innerText(loaded.state.layer(i2)) == "Loaded", "save/load: instances stay linked after reopening")
        } catch { check(false, "save/load: \(error)") }
        // old documents (no component table, no instance field) still decode
        do {
            let enc = PropertyListEncoder(); enc.outputFormat = .binary
            let data = try enc.encode(LumenFile(name: "old", state: before))
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            let hasKey = ((plist as? [String: Any])?["state"] as? [String: Any])?["components"] != nil
            let back = try PropertyListDecoder().decode(LumenFile.self, from: data)
            check(!hasKey && back.state.components.isEmpty && back.state.layers.count == 4, "tolerant decoding: documents without components open unchanged (no key written)")
        } catch { check(false, "tolerant decoding: \(error)") }

        // 9. Detach
        let preDetach = d.state
        d.selectLayer(inst1)
        let n = ComponentActions.detach(d)
        let g = d.state.layer(inst1)
        check(n == 1 && g?.isGroup == true && g?.isComponentInstance == false && (g?.children.count ?? 0) == 3, "detach: instance became a group of normal layers")
        let dDetach = diff(preDetach, d.state)
        check(dDetach < 1.0, "detach: looks the same (mean diff \(String(format: "%.3f", dDetach)))")
        check(g?.children.contains { $0.text?.text == "Hover me" } == true, "detach: overrides are baked into the detached layers")
        check(ComponentEngine.usageCount(cid, in: d.state) == 3, "detach: usage count drops to 3")
        save(d.state, "c07_detached", dir)

        // detach of a rotated instance keeps the placement
        d.selectLayer(i3)
        let stRot = d.state
        d.updateLayer(i3) { $0 = rotated($0, degrees: 25, scale: 1, st: stRot) }
        d.commit("Rotate")
        let preRot = d.state
        ComponentActions.detach(d, layers: [i3])
        let dRot = diff(preRot, d.state)
        check(dRot < 1.5, "detach rotated + scaled instance: layers land in the same place (mean diff \(String(format: "%.3f", dRot)))")
        save(d.state, "c08_detached_rotated", dir)
        d.undo()

        // 10. Swap component (overrides that still match are kept)
        var badgeState = d.state
        var bp = SelfTest.shapeLayer(CGRect(x: 0, y: 0, width: 150, height: 44), RGBA(hex: "0CA678")!, radius: 22); bp.name = "Plate"
        var bt = TextContent(); bt.text = "Badge"; bt.fontName = "Helvetica"; bt.fontSize = 18; bt.color = .white; bt.position = CGPoint(x: 46, y: 11)
        let bl = Layer(name: "Label", content: .text(bt))
        var bm = ComponentMaster(name: "Badge", width: 150, height: 44, layers: [bp, bl])
        bm.variants = [ComponentVariant(name: "Disabled", width: 150, height: 44, layers: [bp, bl])]
        badgeState.components[bm.id] = bm
        d.state = badgeState
        d.commit("Add Badge")
        ComponentActions.setText(d, layer: i3, inner: label, "Kept")
        ComponentActions.setVisible(d, layer: i3, inner: avatar, false)
        let centerBefore = d.state.layer(i3)!.smart!.quad.center
        check(ComponentActions.swap(d, layer: i3, to: bm.id), "swap: instance now uses the other component")
        let sw = d.state.layer(i3)?.componentInstance
        check(sw?.componentID == bm.id && innerText(d.state.layer(i3)) == "Kept", "swap: text override kept by matching layer name")
        check(sw?.overrides.count == 1, "swap: overrides without a matching layer are dropped (avatar visibility)")
        check(sw?.variantID == bm.variants[0].id, "swap: variant matched by name (Disabled)")
        let centerAfter = d.state.layer(i3)!.smart!.quad.center
        check(centerBefore.distance(to: centerAfter) < 0.5, "swap: keeps the instance centre")
        save(d.state, "c09_swapped", dir)

        // 11. Copy / paste across documents: the main component travels with the instance
        let d2 = Document.newBlank(width: 400, height: 260, background: RGBA(hex: "F1F3F5"), name: "other")
        app.add(d2)
        var pasted = d.state.layer(i2)!.duplicated()
        pasted = { var l = $0; if var so = l.smart { so.quad = Quad(rect: CGRect(x: 60, y: 90, width: 252, height: 96)); l.smart = so }; return l }(pasted)
        d2.addLayer(pasted)
        d2.commit("Paste")
        check(d2.state.components[cid] != nil, "cross-document paste: the main component was copied into the other document")
        check(d2.state.components.count == 1, "cross-document paste: only the used component is copied")
        var e4 = DocumentState(width: m.width, height: m.height)
        e4.layers = d2.state.components[cid]!.layers
        e4.layers.update(labelID) { l in if var t = l.text { t.text = "Other"; l.text = t } }
        ComponentActions.commitMain(parent: d2, component: cid, variant: nil, edited: e4)
        check(innerText(d2.state.layer(pasted.id)) == "Other" && innerText(d.state.layer(i2)) == "Send", "cross-document: each document owns its copy of the main component")
        save(d2.state, "c10_pasted_other_doc", dir)
        // dragging a component from the panel onto another document's canvas
        let d4 = Document.newBlank(width: 300, height: 200, background: .white, name: "drop")
        app.add(d4)
        let dropped = ComponentCommands.handleDrop(string: ComponentCommands.dragPrefix + cid.uuidString, doc: d4, at: CGPoint(x: 150, y: 100))
        let dl = d4.activeLayer
        check(dropped && dl?.isComponentInstance == true && d4.state.components[cid] != nil && abs((dl?.smart?.quad.center.x ?? 0) - 150) < 1, "drag from the Components panel: instance created at the drop point (main component copied)")
        check(!ComponentCommands.handleDrop(string: "some other text", doc: d4, at: .zero), "unrelated text drags are left to the canvas")
        app.close(d4)
        // same-document paste keeps the link without duplicating the table entry
        let again = d.state.layer(i2)!.duplicated()
        d.addLayer(again); d.commit("Paste")
        check(d.state.components.count == 2 && d.state.layer(again.id)?.isComponentInstance == true, "paste within the document: instance stays linked, table unchanged")

        // 12. Nested components
        d.selectedLayerIDs = [again.id]; d.activeLayerID = again.id
        var cardBG = SelfTest.shapeLayer(CGRect(x: 330, y: 250, width: 290, height: 170), RGBA(hex: "FFFFFF")!, radius: 12); cardBG.name = "Card"
        var stn = d.state
        stn.insertLayer(cardBG, below: again.id)
        stn.updateLayer(again.id) { l in if var so = l.smart { so.quad = Quad(rect: CGRect(x: 350, y: 300, width: 252, height: 96)); l.smart = so } }
        d.state = stn
        d.selectedLayerIDs = [cardBG.id, again.id]
        let cardID = ComponentActions.createComponent(d, name: "Card")
        check(cardID != nil && ComponentEngine.usedComponentIDs(d.state.components[cardID!]!).contains(cid), "nested: a component can contain an instance of another component")
        var e5 = DocumentState(width: m.width, height: m.height)
        e5.layers = d.state.components[cid]!.layers
        e5.layers.update(labelID) { l in if var t = l.text { t.text = "Nested"; l.text = t } }
        ComponentActions.commitMain(parent: d, component: cid, variant: nil, edited: e5)
        var nestedText: String? = nil
        if case .document(let cs)? = d.state.allLayers.first(where: { $0.componentInstance?.componentID == cardID })?.smart?.source {
            nestedText = innerText(cs.allLayers.first { $0.isComponentInstance })
        }
        check(nestedText == "Nested", "nested: editing the inner main component updates instances of the outer one (\(nestedText ?? "nil"))")
        var cyc = DocumentState(width: 100, height: 100)
        cyc.layers = [ComponentEngine.instanceLayer(of: cardID!, table: d.state.components)!]
        check(ComponentEngine.wouldCycle(cyc.layers, component: cid, table: d.state.components), "nested: a component containing itself is detected")
        save(d.state, "c11_nested", dir)

        // 13. Rename / duplicate / delete / select instances
        ComponentActions.rename(d, component: cid, to: "CTA Button")
        check(d.state.components[cid]?.name == "CTA Button", "rename component")
        let copyID = ComponentActions.duplicate(d, component: cid)
        check(copyID != nil && d.state.components[copyID!]?.name == "CTA Button copy" && d.state.components.count == 4, "duplicate component")
        let sel = ComponentActions.selectInstances(d, component: cid)
        check(sel == ComponentEngine.usageCount(cid, in: d.state) && d.selectedLayerIDs.count == sel, "select all instances (\(sel))")
        let usage = ComponentEngine.usageCount(bm.id, in: d.state)
        let preDelete = d.state
        ComponentActions.delete(d, component: bm.id)
        check(usage == 1 && d.state.components[bm.id] == nil && d.state.layer(i3)?.isSmartObject == true && d.state.layer(i3)?.isComponentInstance == false,
              "delete component: its \(usage) instance becomes a plain smart object")
        check(diff(preDelete, d.state) == 0, "delete component: nothing changes visually")

        // 14. Library: save → place into another document → update from library
        do {
            let lib = try ComponentLibraries.create(named: "Test Kit")
            var st = d.state
            let v1 = try ComponentLibraries.publish(cid, from: &st, to: lib)
            d.state = st; d.commit("Save to Library")
            check(v1 == 1 && FileManager.default.fileExists(atPath: lib.path) && lib.pathExtension == "iclib", "library: component saved to \(lib.lastPathComponent) (v\(v1))")
            check(lib.path.hasPrefix(ComponentsSupport.directory.path) && !lib.path.contains("Library/Application Support"), "library: written under the (test) support folder")
            let d3 = Document.newBlank(width: 420, height: 240, background: RGBA(hex: "212529"), name: "third")
            app.add(d3)
            guard let file = ComponentLibraries.load(lib) else { check(false, "library: load"); return }
            var st3 = d3.state
            check(ComponentLibraries.place(cid, from: file, into: &st3), "library: place copies the component into the document table")
            d3.state = st3
            let li = ComponentActions.insertInstance(d3, component: cid, center: CGPoint(x: 210, y: 120))
            check(li != nil && innerText(d3.state.layer(li!)) == "Nested" && d3.state.components[cid]?.library?.version == 1, "library: placed instance renders, linked to library v1")
            check(ComponentLibraries.newerVersion(of: d3.state.components[cid]!) == nil, "library: no update offered while versions match")
            // publish a newer version from the first document
            var e6 = DocumentState(width: m.width, height: m.height)
            e6.layers = d.state.components[cid]!.layers
            e6.layers.update(labelID) { l in if var t = l.text { t.text = "v2"; l.text = t } }
            ComponentActions.commitMain(parent: d, component: cid, variant: nil, edited: e6)
            st = d.state
            let v2 = try ComponentLibraries.publish(cid, from: &st, to: lib)
            d.state = st; d.commit("Save to Library")
            check(v2 == 2 && ComponentLibraries.newerVersion(of: d3.state.components[cid]!) != nil, "library: newer version detected in the other document")
            st3 = d3.state
            let upd = ComponentLibraries.update(cid, in: &st3)
            d3.state = st3; d3.commit("Update from Library")
            check(upd && innerText(d3.state.layer(li!)) == "v2" && d3.state.components[cid]?.library?.version == 2, "library: Update from library rebuilds the instances")
            check(ComponentLibraries.list().count == 1, "library: listed in the library browser")
            let d5 = Document.newBlank(width: 300, height: 200, background: .white, name: "libdrop")
            app.add(d5)
            let okDrop = ComponentCommands.handleDrop(string: ComponentCommands.libraryDragPrefix + cid.uuidString + "|" + lib.path, doc: d5, at: CGPoint(x: 150, y: 100))
            check(okDrop && d5.activeLayer?.isComponentInstance == true && d5.state.components[cid]?.library?.version == 2, "library: drag from the library onto a canvas places the latest version")
            app.close(d5)
            save(d3.state, "c12_library_placed", dir)
            app.close(d3)
        } catch { check(false, "library: \(error)") }

        // 15. PSD export fallback: instances are flattened like smart objects
        do {
            let psd = dir.appendingPathComponent("components.psd")
            try PSDWriter.write(d.state, to: psd)
            let back = try PSDReader.read(url: psd)
            let dp = diff(d.state, back)
            check(!back.layers.isEmpty && back.allLayers.allSatisfy { !$0.isComponentInstance } && dp < 3.0, "PSD export: instances written as raster layers, same look (mean diff \(String(format: "%.3f", dp)))")
        } catch { check(false, "PSD export: \(error)") }

        save(d.state, "c13_final", dir)
        app.close(d2)
        app.close(d)
    }
}
