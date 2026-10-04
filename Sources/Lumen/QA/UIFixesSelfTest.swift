import AppKit
import SwiftUI
import ImageCratCore

/// Regression checks for the dialog / numeric-field / keyboard-focus / menu-wiring findings of the QA pass of
/// 30 Sept 2026 (B01, B03, B05, B07, B10, B11, U02). The views are the real ones, hosted in an offscreen window; text is
/// typed through the field editor and buttons are clicked with synthetic mouse events or pressed through accessibility.
/// `LUMEN_SELFTEST_ONLY=uifixes Lumen --selftest <dir>`
enum UIFixesSelfTest {
    static func register() { FeatureModules.selfTests.append(("uifixes", { run($0) })) }

    static var failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") uifixes: \(name)\(detail.isEmpty ? "" : " — " + detail)")
    }

    // MARK: Harness

    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    /// Pumps events and lets SwiftUI push its state into the AppKit views (an offscreen window is never displayed by itself).
    static func spin(_ s: Double = 0.15) {
        let end = Date().addingTimeInterval(s)
        repeat {
            Fuzz.spin(0.02)
            for w in NSApp.windows where w.isVisible { w.contentView?.layoutSubtreeIfNeeded(); w.displayIfNeeded() }
        } while Date() < end
    }

    static func host<V: View>(_ v: V, _ size: CGSize) -> NSWindow {
        let hv = NSHostingView(rootView: v.environment(\.colorScheme, .dark).font(Theme.font).foregroundStyle(Theme.text)
            .frame(width: size.width, height: size.height).background(Theme.panelBG))
        let w = KeyableWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        hv.layoutSubtreeIfNeeded()
        spin(0.4)
        return w
    }

    static func close(_ w: NSWindow) {
        w.makeFirstResponder(nil)
        spin(0.1)
        w.orderOut(nil)
        w.contentView = nil
    }

    /// The window's content snapshotted to a PNG (for looking at layouts).
    static func snapshot(_ w: NSWindow, _ name: String, _ out: URL) {
        guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
    }

    /// Editable text fields, top to bottom, left to right.
    static func fields(_ w: NSWindow) -> [NSTextField] {
        var out: [NSTextField] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTextField, t.isEditable, !t.isHiddenOrHasHiddenAncestor { out.append(t) }
            for s in v.subviews { walk(s) }
        }
        if let c = w.contentView { walk(c) }
        func f(_ t: NSTextField) -> NSRect { t.convert(t.bounds, to: nil) }
        return out.sorted { abs(f($0).maxY - f($1).maxY) > 3 ? f($0).maxY > f($1).maxY : f($0).minX < f($1).minX }
    }

    /// Fields left of the Properties panel of `Scene` (the dialog's).
    static func dialogFields(_ w: NSWindow) -> [NSTextField] { fields(w).filter { $0.convert($0.bounds, to: nil).maxX < 800 } }

    /// The text field being edited (the field editor's delegate).
    static func editedField(_ w: NSWindow) -> NSTextField? {
        guard let fe = w.firstResponder as? NSTextView, fe.isFieldEditor else { return nil }
        return fe.delegate as? NSTextField
    }

    /// Clicks into `f` and replaces its text by typing `s` (no Return / Tab).
    static func type(_ s: String, into f: NSTextField, _ w: NSWindow) {
        if editedField(w) !== f { w.makeFirstResponder(f); spin(0.1) }
        guard let fe = w.firstResponder as? NSTextView else { return }
        fe.selectAll(nil)
        fe.insertText(s, replacementRange: fe.selectedRange())
        spin(0.1)
    }

    static func key(_ chars: String, code: UInt16, _ w: NSWindow, _ mods: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
    }

    /// Tab (⇧Tab with `back`), delivered the way the app does: the app's key monitor first, then the window.
    static func tab(_ w: NSWindow, back: Bool = false) {
        guard let e = key("\t", code: 48, w, back ? [.shift] : []) else { return }
        if !KeyRouter.handle(e) { w.sendEvent(e) }
        spin(0.15)
    }

    /// A mouse click on a button: mouse down / up go through NSApplication.sendEvent (so the app's event monitors see them,
    /// in order), then the button's action runs through accessibility — before the app has finished launching (when self
    /// tests run) SwiftUI doesn't turn synthetic mouse events into button actions.
    static func clickButton(_ b: NSObject, _ w: NSWindow) {
        guard let r = windowRect(b, w) else { return }
        click(r, w)
        FuzzAX.press(b)
        spin(0.2)
    }

    /// Mouse down / up at the centre of `r` (window coordinates) through NSApplication.sendEvent.
    static func click(_ r: NSRect, _ w: NSWindow) {
        let p = NSPoint(x: r.midX, y: r.midY)
        guard let down = Fuzz.mouse(.leftMouseDown, p, w), let up = Fuzz.mouse(.leftMouseUp, p, w) else { return }
        NSApp.sendEvent(down)
        spin(0.05)
        NSApp.sendEvent(up)
        spin(0.2)
    }

    /// Accessibility element of the window with this label (and role, e.g. "AXButton").
    static func ax(_ w: NSWindow, _ label: String, role: String? = nil) -> NSObject? {
        FuzzAX.enable()
        guard let root = w.contentView else { return nil }
        return FuzzAX.tree(root).first { $0.label == label && (role == nil || $0.role == role!) }?.element
    }

    static func axTexts(_ w: NSWindow) -> [String] {
        FuzzAX.enable()
        guard let root = w.contentView else { return [] }
        return FuzzAX.tree(root).map(\.label)
    }

    /// Window-coordinate frame of an accessibility element.
    static func windowRect(_ o: NSObject, _ w: NSWindow) -> NSRect? {
        guard let r = FuzzAX.frame(o) else { return nil }
        return w.convertFromScreen(r)
    }

    static func withDoc(_ st: DocumentState, _ body: (Document) -> Void) {
        let app = AppModel.shared
        let d = Document(state: st, name: "uifixes")
        let prevDocs = app.documents, prevActive = app.activeDocumentID
        app.documents.append(d); app.activeDocumentID = d.id
        body(d)
        app.dialog = nil
        app.documents = prevDocs.filter { p in app.documents.contains { $0 === p } }
        app.activeDocumentID = prevActive
    }

    static func rasterState() -> (DocumentState, UUID) {
        var st = SelfTest.baseState(320, 200)
        let buf = PixelBuffer(width: 160, height: 100)
        buf.context.setFillColor(RGBA(hex: "3A7BD5")!.cgColor)
        buf.context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        buf.markDirty()
        var l = Layer.raster(name: "Sonoma copy", buffer: buf)
        l.name = "Sonoma copy"
        st.layers.append(l)
        return (st, l.id)
    }

    /// A stand-in for the workspace: a Properties panel on the right (like the real panel column) under the dialog layer.
    struct Scene: View {
        var body: some View {
            ZStack {
                HStack(spacing: 0) {
                    Color.clear
                    PropertiesPanel().frame(width: 300)
                }
                DialogOverlay()
            }
        }
    }

    // MARK: Run

    static func run(_ out: URL) {
        failures = 0
        let app = AppModel.shared
        let savedTool = app.tool, savedHook = AppActions.modalHook, savedCanvas = AppActions.canvas
        AppActions.canvas = nil       // no canvas in these scenes (focus goes back to the window)
        defer { app.tool = savedTool; AppActions.modalHook = savedHook; AppActions.canvas = savedCanvas; app.dialog = nil }
        b01NewDocument(out)
        b01Adjustment(out)
        b10LayerStyleCancel(out)
        b11AutoLeading(out)
        fieldHistory(out)
        b03DialogFocus(out)
        b05FxMenu(out)
        b07RasterizeWording()
        u02Flyout(out)
        print("uifixes: \(failures) failure(s)")
    }

    // MARK: B01 — OK / Create ignores the last typed value

    static func b01NewDocument(_ out: URL) {
        let app = AppModel.shared
        let (st, _) = rasterState()
        withDoc(st) { _ in
            let before = Set(app.documents.map(\.id))
            app.dialog = .newDocument
            let w = host(Scene(), CGSize(width: 1100, height: 700))
            defer { close(w) }
            let fs = fields(w)
            // (by position: Name, Width, Height, Resolution)
            let num = dialogFields(w).filter { $0.stringValue != "Untitled-1" }
            guard num.count == 3, let wf = num.first, let hf = num.dropFirst().first else {
                check(false, "B01 New Document: width / height fields found", fs.map(\.stringValue).joined(separator: ",")); return
            }
            type("800", into: wf, w)
            type("600", into: hf, w)          // no Tab / Return: straight to Create
            guard let create = ax(w, "Create", role: "AXButton") else { check(false, "B01 Create button found"); return }
            snapshot(w, "uifixes_b01_newdoc", out)
            clickButton(create, w)
            let made = app.documents.filter { !before.contains($0.id) }
            check(made.count == 1 && made.first.map { $0.state.width == 800 && $0.state.height == 600 } == true,
                  "B01 New Document: clicking Create right after typing Height uses the typed value",
                  made.first.map { "\($0.state.width) × \($0.state.height)" } ?? "no document")
            check(app.dialog == nil, "B01 dialog closed after Create")
            app.documents.removeAll { !before.contains($0.id) }
        }
    }

    static func b01Adjustment(_ out: URL) {
        let app = AppModel.shared
        let (st, id) = rasterState()
        for viaMouse in [true, false] {
            withDoc(st) { d in
                d.selectLayer(id)
                let h0 = d.historyIndex
                let px0 = d.state.layer(id)?.raster?.buffer.pixel(10, 10).0
                app.dialog = .adjustment(.brightnessContrast)
                let w = host(Scene(), CGSize(width: 1100, height: 700))
                defer { close(w) }
                guard let bf = dialogFields(w).first else { check(false, "B01 Brightness field found"); return }
                type("80", into: bf, w)
                guard let ok = ax(w, "OK", role: "AXButton") else { check(false, "B01 OK button found"); return }
                if viaMouse { clickButton(ok, w) } else { FuzzAX.press(ok); spin(0.2) }
                let px1 = d.state.layer(id)?.raster?.buffer.pixel(10, 10).0
                check(d.historyIndex == h0 + 1 && px0 != nil && px1 != nil && Int(px1!) > Int(px0!) + 12,
                      "B01 Brightness/Contrast: OK right after typing Brightness 80 applies it (\(viaMouse ? "mouse click" : "accessibility press"))",
                      "history \(h0)→\(d.historyIndex), red \(px0.map { "\($0)" } ?? "-")→\(px1.map { "\($0)" } ?? "-")")
            }
        }
    }

    // MARK: B10 — Layer Style Cancel keeps Bevel after Shadow Opacity boundary inputs

    static func b10LayerStyleCancel(_ out: URL) {
        let app = AppModel.shared
        let (st, id) = rasterState()
        withDoc(st) { d in
            d.selectLayer(id)
            let h0 = d.historyIndex, count0 = d.history.count
            app.dialog = .layerStyle(id)
            let w = host(Scene(), CGSize(width: 1100, height: 700))
            defer { close(w) }
            guard let bevel = ax(w, "Bevel & Emboss", role: "AXButton") else { check(false, "B10 Bevel & Emboss row found"); return }
            FuzzAX.press(bevel)
            spin(0.3)
            // Shadow Opacity: the lower of the two 75 % fields of the Bevel section
            func shadowOpacity() -> NSTextField? {
                dialogFields(w).last      // Depth, Size, Soften, Angle, Altitude, Highlight / Shadow Opacity
            }
            for v in ["-100000", "100000", "75"] {
                guard let f = shadowOpacity() else { check(false, "B10 Shadow Opacity field found"); return }
                type(v, into: f, w)
                tab(w)
            }
            snapshot(w, "uifixes_b10_before_cancel", out)
            guard let cancel = ax(w, "Cancel", role: "AXButton") else { check(false, "B10 Cancel found"); return }
            clickButton(cancel, w)
            w.makeFirstResponder(nil)       // focus leaves whatever field it was in (the tester then clicked the canvas)
            spin(0.2)
            let l = d.state.layer(id)
            check(l?.effects.bevel.enabled == false && d.historyIndex == h0 && d.history.count == count0,
                  "B10 Layer Style Cancel after Shadow Opacity -100000 / 100000 / 75 + Tab leaves Bevel off and adds no history",
                  "bevel \(l?.effects.bevel.enabled == true ? "on" : "off"), history \(count0)→\(d.history.count) [\(d.history.map(\.name).joined(separator: ", "))]")
            d.commit("probe")
            check(d.state.layer(id)?.effects.bevel.enabled == false, "B10 no uncommitted Bevel left to be baked into the next history step")
        }
        // Typing into an effect field and clicking Cancel without Tab must not reach the document either.
        withDoc(st) { d in
            d.selectLayer(id)
            app.dialog = .layerStyle(id)
            let w = host(Scene(), CGSize(width: 1100, height: 700))
            defer { close(w) }
            guard let row = ax(w, "Drop Shadow", role: "AXButton") else { check(false, "B10 Drop Shadow row found"); return }
            FuzzAX.press(row)
            spin(0.3)
            guard let f = dialogFields(w).first else { check(false, "B10 Drop Shadow field found"); return }
            type("33", into: f, w)
            guard let cancel = ax(w, "Cancel", role: "AXButton") else { check(false, "B10 Cancel found"); return }
            clickButton(cancel, w)
            w.makeFirstResponder(nil)
            spin(0.2)
            let fx = d.state.layer(id)?.effects
            let orig = st.layers.last?.effects
            check(fx?.dropShadow.enabled == false && fx == orig, "B10 an effect value typed without Tab is dropped by Cancel",
                  "drop shadow \(fx?.dropShadow.enabled == true ? "on" : "off"), opacity \(fx.map { "\($0.dropShadow.opacity)" } ?? "-") vs \(orig.map { "\($0.dropShadow.opacity)" } ?? "-"), fx equal \(fx == orig), typed into [\(f.stringValue)]")
        }
    }

    // MARK: B11 — changing Size through Tab turns Auto leading off

    static func b11AutoLeading(_ out: URL) {
        var st = SelfTest.baseState(400, 200)
        var t = TextContent()
        t.text = "LUMEN QA"; t.fontName = "Helvetica"; t.fontSize = 48; t.position = CGPoint(x: 20, y: 40); t.color = .black
        let l = Layer(name: "LUMEN QA", content: .text(t))
        st.layers.append(l)
        withDoc(st) { d in
            d.selectLayer(l.id)
            let w = host(ScrollView { VStack(alignment: .leading) { TextProperties(t: .constant(t), onCommit: {}) }.padding(10) }, CGSize(width: 300, height: 700))
            defer { close(w) }
            let fs0 = fields(w)         // Size, Leading, Tracking, …
            guard fs0.count > 2, fs0[0].stringValue == "48.0" || fs0[0].stringValue.isEmpty else {
                check(false, "B11 Size / Leading fields found", fields(w).map(\.stringValue).joined(separator: ",")); return
            }
            let size = fs0[0], lead = fs0[1]
            type("96", into: size, w)
            tab(w)
            let shown = lead.stringValue
            let focusedLeading = editedField(w) === lead
            w.makeFirstResponder(nil)       // click away
            spin(0.2)
            let tt = d.state.layer(l.id)?.text
            check(shown == "115.2", "B11 after Size 96 + Tab the Leading field shows the auto value", "field \(shown)\(focusedLeading ? " (focused)" : "")")
            check(tt?.fontSize == 96 && tt?.leading == nil, "B11 Auto leading stays on after the size change and focus leaving",
                  "size \(tt.map { "\($0.fontSize)" } ?? "-"), leading \(tt?.leading.map { "\($0)" } ?? "auto")")
            check(d.history.last?.name == "Edit Type" && d.history.count == 2, "B11 one history step for the size change", d.history.map(\.name).joined(separator: ", "))
            // Hanging indent (derived from the size too) in the Paragraph controls: same rule.
            let fs = fields(w).map(\.stringValue)
            check(fs.contains("115.2") && !fs.contains("57.6"), "B11 no field still shows a value derived from the old size", fs.joined(separator: ","))
        }
    }

    // MARK: Shared field: one history step per typed value, none for focus passing through

    static func fieldHistory(_ out: URL) {
        let (st, id) = rasterState()
        withDoc(st) { d in
            d.selectLayer(id)
            let w = host(Scene(), CGSize(width: 1100, height: 700))
            defer { close(w) }
            guard let x = fields(w).first, let y = fields(w).dropFirst().first else { check(false, "fields: Properties X / Y found"); return }
            let n0 = d.history.count
            w.makeFirstResponder(x); spin(0.1)
            tab(w)                                  // focus passes through X and Y without typing
            w.makeFirstResponder(nil); spin(0.1)
            check(d.history.count == n0, "fields: focus passing through a field commits nothing", d.history.map(\.name).joined(separator: ", "))
            type("40", into: x, w)
            if let e = key("\r", code: 36, w) { w.sendEvent(e) }       // Return
            spin(0.1)
            click(y.convert(y.bounds, to: nil).offsetBy(dx: 0, dy: 60), w)   // a click elsewhere…
            w.makeFirstResponder(nil); spin(0.1)                             // …and focus leaving
            let l = d.state.layer(id)
            check(l?.raster?.origin.x == 40 && d.history.count == n0 + 1 && d.history.last?.name == "Move",
                  "fields: a typed X + Return moves the layer in one history step", "x \(l?.raster?.origin.x ?? -1), history \(d.history.map(\.name).joined(separator: ", "))")
            type("25", into: y, w)
            click(NSRect(x: 300, y: 300, width: 4, height: 4), w)            // straight to a click, no Return / Tab
            w.makeFirstResponder(nil); spin(0.1)
            check(d.state.layer(id)?.raster?.origin.y == 25 && d.history.count == n0 + 2, "fields: a typed Y committed by a click is one history step",
                  "y \(d.state.layer(id)?.raster?.origin.y ?? -1), history \(d.history.map(\.name).joined(separator: ", "))")
        }
    }

    // MARK: B03 — Tab escapes the dialog; Undo swallowed after OK

    static func b03DialogFocus(_ out: URL) {
        let app = AppModel.shared
        let (st, id) = rasterState()
        withDoc(st) { d in
            d.selectLayer(id)
            let w = host(Scene(), CGSize(width: 1100, height: 700))
            defer { close(w) }
            let panelFields = Set(fields(w).map { ObjectIdentifier($0) })
            app.dialog = .filter(.gaussianBlur, smartLayer: nil, editingFilter: nil)
            spin(0.4)
            let dialogFields = fields(w).filter { !panelFields.contains(ObjectIdentifier($0)) }
            guard let radius = dialogFields.first else { check(false, "B03 Gaussian Blur radius field found"); return }
            type("15", into: radius, w)
            var escaped: [String] = []
            for i in 0..<4 {
                tab(w, back: i == 3)
                if let f = editedField(w), panelFields.contains(ObjectIdentifier(f)) { escaped.append(f.stringValue) }
                else if editedField(w) == nil { escaped.append("<no field>") }
            }
            check(escaped.isEmpty, "B03 Tab / ⇧Tab stay inside the open dialog", escaped.isEmpty ? "" : "focus went to panel field(s) \(escaped)")
            // Focus that did land in a panel (a click there) must not keep ⌘Z away from the document after OK.
            if let p = fields(w).first(where: { panelFields.contains(ObjectIdentifier($0)) }) { w.makeFirstResponder(p); spin(0.1) }
            let h0 = d.historyIndex
            guard let ok = ax(w, "OK", role: "AXButton") else { check(false, "B03 OK found"); return }
            clickButton(ok, w)
            check(d.historyIndex == h0 + 1 && app.dialog == nil, "B03 Gaussian Blur applied")
            let textFocus = w.firstResponder is NSText
            check(!textFocus, "B03 after the dialog closes no text field keeps keyboard focus (⌘Z goes to the document)",
                  "first responder \(w.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil")")
            // what Edit ▸ Undo does, with this window as the key window
            let wasKey = NSApp.keyWindow
            if NSApp.keyWindow === w || !textFocus {
                AppActions.undo()
                check(d.historyIndex == h0, "B03 Undo right after OK reverts the filter", "history \(h0 + 1)→\(d.historyIndex)")
            } else {
                check(false, "B03 Undo right after OK reverts the filter", "a text field is first responder (key window \(wasKey == nil ? "nil" : "set"))")
            }
            // ⌘Z inside a focused text field still edits that field's text (the text-editing path is kept).
            if let p = fields(w).first {
                w.makeFirstResponder(p); spin(0.1)
                check(w.firstResponder is NSText, "B03 a field clicked after the dialog closed still takes text focus")
            }
        }
    }

    // MARK: B05 — fx menu opens Blending Options for every effect

    static func b05FxMenu(_ out: URL) {
        let app = AppModel.shared
        let (st, id) = rasterState()
        let cases: [(StyleSection, String, (LayerEffects) -> Bool)] = [
            (.dropShadow, "DROP SHADOW — STRUCTURE", { $0.dropShadow.enabled }),
            (.bevel, "STRUCTURE", { $0.bevel.enabled }),
            (.stroke, "FILL TYPE", { $0.stroke.enabled }),
            (.innerGlow, "INNER GLOW — STRUCTURE", { $0.innerGlow.enabled }),
            (.colorOverlay, "COLOR OVERLAY", { $0.colorOverlay.enabled }),
        ]
        withDoc(st) { d in
            d.selectLayer(id)
            let w = host(LayersPanel(), CGSize(width: 300, height: 500))
            defer { close(w) }
            var menu: NSMenu?
            func walk(_ v: NSView) {
                if let b = v as? NSPopUpButton, b.menu?.items.contains(where: { $0.title == "Drop Shadow…" }) == true { menu = b.menu }
                for s in v.subviews { walk(s) }
            }
            if let c = w.contentView { walk(c) }
            for (section, caption, enabled) in cases {
                app.dialog = nil
                d.revertUncommitted()
                spin(0.05)
                if let m = menu, let i = m.items.firstIndex(where: { $0.title == section.rawValue + "…" }) {
                    m.performActionForItem(at: i)
                } else {
                    LayerStyleDialog.open(section, layer: id, doc: d)     // what the fx menu item calls
                }
                spin(0.2)
                let dw = host(DialogOverlay(), CGSize(width: 1100, height: 700))
                let texts = axTexts(dw)
                let fx = d.state.layer(id)?.effects ?? LayerEffects()
                check(app.dialog == .layerStyle(id) && texts.contains(caption) && !texts.contains("GENERAL BLENDING") && enabled(fx) && fx.enabled,
                      "B05 fx ▸ \(section.rawValue)… opens Layer Style on \(section.rawValue) with the effect switched on",
                      "\(menu == nil ? "menu not found, " : "")dialog \(app.dialog?.id ?? "nil"), showing \(texts.contains("GENERAL BLENDING") ? "Blending Options" : texts.contains(caption) ? section.rawValue : "?"), enabled \(enabled(fx))")
                // Cancel undoes the enabling
                if let c = ax(dw, "Cancel", role: "AXButton") { FuzzAX.press(c); spin(0.1) }
                check(!enabled(d.state.layer(id)?.effects ?? LayerEffects()), "B05 Cancel switches \(section.rawValue) off again")
                close(dw)
            }
        }
    }

    // MARK: B07 — rasterize warning wording

    static func b07RasterizeWording() {
        var st = SelfTest.baseState(300, 200)
        var t = TextContent(); t.text = "T"; t.fontSize = 30
        let text = Layer(name: "Text", content: .text(t))
        let shape = SelfTest.shapeLayer(CGRect(x: 10, y: 10, width: 50, height: 50))
        let fill = Layer(name: "Gradient Fill 1", content: .fill(FillContent(paint: .gradient(GradientFill(gradient: .twoColor(.black, .white))))))
        let group = Layer(name: "Group 1", content: .group(GroupContent(children: [SelfTest.shapeLayer(CGRect(x: 80, y: 10, width: 50, height: 50))])))
        st.layers += [text, shape, fill, group]
        withDoc(st) { d in
            var info = ""
            AppActions.modalHook = { _, i in info = i; return false }
            for (l, want) in [(text, "live text"), (shape, "a vector shape"), (fill, "a fill layer"), (group, "a group")] {
                AppActions.offerRasterize(layer: l.id)
                check(!info.contains("smart object") && info.contains(want), "B07 rasterize warning for a \(l.kindName.lowercased()) names what is lost", info)
            }
            AppActions.modalHook = nil
        }
    }

    // MARK: U02 — tool flyout rows

    static func u02Flyout(_ out: URL) {
        let app = AppModel.shared
        let before = app.tool
        let w = host(VStack { ToolFlyoutRow(tool: .pencil, selected: false) { app.tool = .pencil } }.padding(5), CGSize(width: 240, height: 40))
        defer { close(w); app.tool = before }
        app.tool = .brush
        let nodes = FuzzAX.tree(w.contentView!)
        if let row = nodes.first(where: { $0.role == "AXButton" && $0.label.contains("Pencil") })?.element {
            FuzzAX.press(row); spin(0.1)
            check(app.tool == .pencil, "U02 a flyout row is a button whose press selects its tool")
        } else {
            check(false, "U02 a flyout row is a button whose press selects its tool", nodes.map { "\($0.role) [\($0.label)]" }.joined(separator: ", "))
        }
    }
}
