import AppKit
import SwiftUI
import CoreImage
import ImageCratCore

/// Headless tests for Workflow2 (`LUMEN_SELFTEST_ONLY=workflow2 .build/debug/Lumen --selftest <dir>`).
/// Everything written to disk goes to a temp directory; nothing touches Application Support or UserDefaults.
enum Workflow2SelfTest {
    static func check(_ ok: Bool, _ msg: String, _ detail: String = "") {
        print(ok ? "ok   workflow2: \(msg)" : "FAIL workflow2: \(msg)\(detail.isEmpty ? "" : " — " + detail)")
    }

    static var tmp = URL(fileURLWithPath: NSTemporaryDirectory())

    static func run(_ out: URL) {
        let fm = FileManager.default
        tmp = fm.temporaryDirectory.appendingPathComponent("lumen-w2-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let app = AppModel.shared
        let savedTool = app.tool, savedDocs = app.documents, savedActive = app.activeDocumentID, savedCanvas = AppActions.canvas
        let savedRoot = Workflow2Paths.overrideRoot, savedRecents = PaletteIndex.recentURLs
        let started = Date()
        AppActions.canvas = nil
        app.dialog = nil            // earlier modules may have left a dialog up; several checks here assume none
        Workflow2Paths.overrideRoot = tmp.appendingPathComponent("support")
        Workflow2Settings.shared.reload()
        Workflow2Module.installHooks()
        defer {
            CompareController.shared.exit(); QuickCompare.end(); IsolateMode.shared.exit()
            for d in app.documents where !savedDocs.contains(where: { $0.id == d.id }) { Workflow2Module.forget(d.id) }
            app.documents = savedDocs; app.activeDocumentID = savedActive; app.tool = savedTool; app.dialog = nil
            AppActions.canvas = savedCanvas
            PaletteIndex.recentURLs = savedRecents
            Timelapse.shared.flush(); Autosave.shared.flush()
            Workflow2Paths.overrideRoot = savedRoot
            Workflow2Settings.shared.reload()
            try? fm.removeItem(at: tmp)
            Workflow2Paths.removeHeadlessRoot()
            let real = Brand.supportFolder
            let leaked = ["Recovery", "Timelapse", "workflow2-prefs.json", "palette-frecency.json"].filter { name in
                guard let a = try? fm.attributesOfItem(atPath: real.appendingPathComponent(name).path), let m = a[.modificationDate] as? Date else { return false }
                return m >= started
            }
            check(leaked.isEmpty, "nothing written to the real Application Support folder", leaked.joined(separator: ", "))
            check(!fm.fileExists(atPath: tmp.path), "temp directory removed")
        }
        palette(out)
        branches(out)
        versions(out)
        compareAndIsolate(out)
        autosave(out)
        incrementalAndRevert(out)
        historyActions(out)
        timelapse(out)
        preflight(out)
        if ProcessInfo.processInfo.environment["LUMEN_SELFTEST_UI"] == "1" { uiSnapshots(out) }
    }

    // MARK: Helpers

    static func solid(_ w: Int, _ h: Int, _ c: RGBA) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        b.context.setFillColor(c.cgColor)
        b.context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        b.markDirty()
        return b
    }

    static func noise(_ w: Int, _ h: Int, seed: UInt64 = 7) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        var s = seed
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let o = y * b.bytesPerRow + x * 4
                for k in 0..<3 { s = s &* 6364136223846793005 &+ 1442695040888963407; p[o + k] = UInt8(truncatingIfNeeded: s >> 33) }
                p[o + 3] = 255
            }
        }
        b.markDirty()
        return b
    }

    /// Gradient background plus a red card and a blue pixel layer.
    static func makeDoc(_ name: String = "w2", w: Int = 480, h: Int = 300) -> Document {
        var st = SelfTest.baseState(w, h)
        var card = SelfTest.shapeLayer(CGRect(x: 60, y: 50, width: 150, height: 110)); card.name = "Card"
        st.layers.append(card)
        st.layers.append(Layer.raster(name: "Paint", buffer: solid(120, 90, RGBA(hex: "2E86DE")!), origin: IPoint(x: 300, y: 150)))
        return Document(state: st, name: name)
    }

    static func diff(_ a: DocumentState, _ b: DocumentState) -> Double { Workflow2Util.compositeDifference(a, b) }

    /// What the canvas shows for a document (composite + view modes / display override).
    static func viewBuffer(_ d: Document) -> PixelBuffer {
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        let img = CanvasRenderer.applyViewMode(Compositor.shared.composite(d), doc: d).cropped(to: sp.ciCanvas)
        return RenderEngine.renderBuffer(img, docRect: d.state.canvasRect, space: sp)
    }

    static func buffer(_ st: DocumentState) -> PixelBuffer {
        RenderEngine.renderBuffer(Compositor.shared.composite(st), docRect: st.canvasRect, space: CanvasSpace(width: st.width, height: st.height))
    }

    static func near(_ a: (UInt8, UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8, UInt8), _ tol: Int = 3) -> Bool {
        abs(Int(a.0) - Int(b.0)) <= tol && abs(Int(a.1) - Int(b.1)) <= tol && abs(Int(a.2) - Int(b.2)) <= tol
    }

    static func savePNG(_ b: PixelBuffer, _ name: String, _ out: URL) {
        try? b.pngData()?.write(to: out.appendingPathComponent(name + ".png"))
        print("wrote \(name)")
    }

    final class MenuTarget: NSObject {
        var fired: [String] = []
        @objc func fire(_ sender: NSMenuItem) { fired.append(sender.title) }
    }

    /// A small menu bar: File / Layer / Filter with submenus, a disabled item, a hidden one, separators and a "✓" title.
    static func fakeMenu(_ target: MenuTarget) -> NSMenu {
        func item(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], enabled: Bool = true) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(MenuTarget.fire(_:)), keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            i.isEnabled = enabled
            return i
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            m.autoenablesItems = false
            for i in items { m.addItem(i) }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = m
            return holder
        }
        let main = NSMenu(title: "Main")
        main.autoenablesItems = false
        let hidden = item("Secret Debug Item"); hidden.isHidden = true
        main.addItem(menu("File", [item("New…", "n"), item("Open…", "o"), menu("Open Recent", [item("old.imagecrat")]), .separator(),
                                   menu("Export", [item("Quick Export as PNG", "'", [.command, .option, .shift]), item("Timelapse Video…")]), hidden]))
        main.addItem(menu("Layer", [menu("New", [item("Layer…", "N", [.command, .shift]), item("Group")]), item("Merge Down", "e", enabled: false),
                                    item("Flatten Image"), item("Flip Canvas Horizontal"), .separator(), item("✓ RGB Color")]))
        main.addItem(menu("Filter", [menu("Blur", [item("Gaussian Blur…"), item("Motion Blur…")]), item("Last Filter", "f", [.command, .control])]))
        return main
    }

    // MARK: 1. Command palette

    static func palette(_ out: URL) {
        let app = AppModel.shared
        // fuzzy scoring
        check(Fuzzy.score("xyz", "Brush Tool") == nil, "fuzzy: non-subsequence does not match")
        if let r = Fuzzy.score("gb", "Gaussian Blur") { check(r.positions == [0, 9], "fuzzy: initials land on word starts", "\(r.positions)") } else { check(false, "fuzzy: gb matches Gaussian Blur") }
        let a = Fuzzy.score("blur", "Gaussian Blur…")?.score ?? -99, b = Fuzzy.score("blur", "Blend Luminosity Raster")?.score ?? -99
        check(a > b, "fuzzy: a consecutive word match beats scattered letters", "\(a) vs \(b)")
        check((Fuzzy.score("brush", "Brush Tool")?.score ?? 0) > (Fuzzy.score("brush", "Healing Brush Tool")?.score ?? 0), "fuzzy: prefix match ranks first")
        check(Fuzzy.match("blur gauss", title: "Gaussian Blur…", secondary: "Filter ▸ Blur") != nil, "fuzzy: words match in any order")
        check(Fuzzy.match("new layer", title: "Layer…", secondary: "Layer ▸ New") != nil, "fuzzy: words may match the menu path")
        check(Fuzzy.match("zzz blur", title: "Gaussian Blur…", secondary: "Filter") == nil, "fuzzy: every word must match")

        // verb parsing
        let fams = ["Avenir", "Avenir Next", "Helvetica", "Times New Roman"]
        func one(_ q: String) -> PaletteVerb? { let v = PaletteVerbs.parse(q, fontFamilies: fams); return v.count >= 1 ? v[0] : nil }
        check(one("opacity 50") == .opacity(50), "verb: opacity 50")
        check(one("size 1080x1350") == .imageSize(1080, 1350), "verb: size 1080x1350")
        check(one("size 50%") == .imageScale(50), "verb: size 50%")
        check(one("fill #ff8800") == .fillColor(RGBA(hex: "ff8800")!), "verb: fill #ff8800")
        check(one("fill 50") == .fillOpacity(50), "verb: fill 50 is the layer fill opacity")
        check(one("fill red") == .fillColor(RGBA(hex: "FF0000")!), "verb: fill with a colour name")
        check(one("fill #f80") == .fillColor(RGBA(hex: "ff8800")!) && one("fill bad") == nil && one("color balance") == nil && one("new layer") == nil, "verb: ordinary words are not mistaken for arguments")
        check(one("rename Hero") == .rename("Hero"), "verb: rename Hero")
        check(one("zoom 200") == .zoom(200), "verb: zoom 200")
        check(one("zoom fit") == .zoomFit, "verb: zoom fit")
        check(one("font Avenir") == .font("Avenir"), "verb: font Avenir", "\(PaletteVerbs.parse("font Avenir", fontFamilies: fams))")
        check(one("feather 12 inside") == .feather(12, .inside), "verb: feather 12 inside")
        check(one("feather 3") == .feather(3, nil), "verb: feather without direction")
        check(one("export png") == .export(.png), "verb: export png")
        check(one("new 1920x1080") == .newDocument(1920, 1080, nil), "verb: new 1920x1080")
        check(one("new 800 600 Poster") == .newDocument(800, 600, "Poster"), "verb: new with a name")
        check(one("blend mult") == .blend(.multiply), "verb: blend mult → Multiply")
        check(one("rotate 90") == .rotateCanvas(90) && one("flip h") == .flipCanvas(horizontal: true), "verb: rotate / flip")
        check(one("canvas 2000x1500") == .canvasSize(2000, 1500), "verb: canvas size")
        check(one("opacity 150") == nil && one("size abc") == nil && one("opacity") == nil && one("export docx") == nil, "verb: invalid arguments are rejected")

        // calculator
        check(PaletteCalc.evaluate("1920/3") == 640 && PaletteCalc.evaluate("2^10") == 1024 && PaletteCalc.evaluate("(1080*4)/5") == 864, "calc: arithmetic")
        check(abs((PaletteCalc.evaluate("15% of 240") ?? 0) - 36) < 1e-9 && PaletteCalc.evaluate("-3+5") == 2, "calc: percent and unary minus")
        check(PaletteCalc.evaluate("abc") == nil && PaletteCalc.evaluate("12") == nil && PaletteCalc.evaluate("1/0") == nil && PaletteCalc.evaluate("2+") == nil, "calc: rejects non-expressions")
        check(PaletteCalc.format(640) == "640" && PaletteCalc.format(2.5) == "2.5", "calc: formatting")

        // menu indexing on a fake menu bar (NSApp.mainMenu is not built headless)
        let target = MenuTarget()
        let menu = fakeMenu(target)
        let menuItems = PaletteIndex.menuItems(menu)
        let titles = menuItems.map(\.title)
        check(menuItems.count == 13, "menu index: every leaf item incl. submenus", "\(menuItems.count): \(titles)")
        check(!titles.contains("Secret Debug Item") && !titles.contains("old.imagecrat") && !titles.contains(""), "menu index: hidden items, separators and Open Recent are skipped")
        let layerItem = menuItems.first { $0.id == "menu:Layer ▸ New ▸ Layer…" }
        check(layerItem?.subtitle == "Layer ▸ New" && layerItem?.shortcut == "⇧⌘N", "menu index: submenu path and shortcut", "\(layerItem?.subtitle ?? "-") \(layerItem?.shortcut ?? "-")")
        check(menuItems.first { $0.title == "Quick Export as PNG" }?.shortcut == "⌥⇧⌘'", "menu index: multi-modifier shortcut")
        check(menuItems.first { $0.title == "Last Filter" }?.shortcut == "⌃⌘F", "menu index: control shortcut")
        let merge = menuItems.first { $0.title == "Merge Down" }
        check(merge != nil && merge?.enabled == false && merge?.shortcut == "⌘E", "menu index: disabled items are kept (greyed)")
        check(titles.contains("RGB Color"), "menu index: check-mark prefix stripped")
        menuItems.first { $0.title == "Group" }?.run()
        check(target.fired == ["Group"], "menu index: running an entry performs the menu item", "\(target.fired)")

        // the real menu bar (SwiftUI has built it by the time the self test runs)
        if let real = NSApp?.mainMenu, real.items.count > 5 {
            let realItems = PaletteIndex.menuItems(real)
            check(realItems.count > 200, "real menu: indexed", "\(realItems.count) items")
            // every key equivalent in the menu bar, including the palette's own item
            var shortcuts: [String: [String]] = [:]
            func walk(_ m: NSMenu) {
                for i in m.items where !i.isSeparatorItem && !i.isHidden {
                    if let sub = i.submenu { walk(sub) } else if !i.keyEquivalent.isEmpty {
                        shortcuts[PaletteIndex.shortcutString(key: i.keyEquivalent, modifiers: i.keyEquivalentModifierMask), default: []].append(PaletteIndex.cleanTitle(i.title))
                    }
                }
            }
            walk(real)
            let mine = ["⇧⌘P": "Command Palette…", "⌃⌘R": "Repeat Last Command", "⌃⌘I": "Isolate Selected Layers", "⌥⌘S": "Save Incremental", "F12": "Revert to Saved"]
            for (k, title) in mine.sorted(by: { $0.key < $1.key }) { check(shortcuts[k] == [title], "real menu: \(k) belongs to “\(title)” only", "\(shortcuts[k] ?? [])") }
            // other modules' clashes are reported, not failed here (only Workflow2's own shortcuts are this test's business)
            let dupes = shortcuts.filter { $0.value.count > 1 && mine[$0.key] == nil }
            print(dupes.isEmpty ? "ok   workflow2: real menu: no key equivalent is used twice anywhere" : "note workflow2: key equivalents used twice elsewhere: \(dupes)")
            check(realItems.first { $0.title == "Page Setup…" }?.shortcut == "", "real menu: Page Setup no longer claims ⇧⌘P")
            for id in ["menu:Filter ▸ Blur ▸ Gaussian Blur…", "menu:View ▸ Compare ▸ with Original", "menu:File ▸ Export ▸ Timelapse Video…", "menu:Edit ▸ Create Action from History Steps…",
                       "menu:Window ▸ History Tree", "menu:File ▸ Clean Up Document…"] {
                check(realItems.contains { $0.id == id }, "real menu: \(id.dropFirst(5))")
            }
            // registry items take their state from the registry, not from a stale NSMenuItem
            let probe = makeDoc("probe")
            let none = PaletteIndex.build(menu: real)
            check(none.first { $0.id == "menu:File ▸ Save Incremental" }?.enabled == false, "real menu: document commands greyed without a document")
            AppModel.shared.add(probe)
            let full = PaletteIndex.build(menu: real)
            check(full.first { $0.id == "menu:File ▸ Save Incremental" }?.enabled == true && full.first { $0.id == "menu:File ▸ Save Incremental" }?.shortcut == "⌥⌘S",
                  "real menu: enabled as soon as a document is open")
            check(full.filter { PaletteIndex.normalized($0.title) == "gaussian blur" }.map(\.id) == ["menu:Filter ▸ Blur ▸ Gaussian Blur…"],
                  "real menu: catalogue entries don't duplicate menu items")
            full.first { $0.id == "menu:Select ▸ All" }?.run()
            check(probe.state.selection != nil && probe.history.last?.name == "Select All", "real menu: running an entry performs the SwiftUI menu command")
            // generative commands are never executed from automated runs, whatever gets selected
            let gen = full.filter(PaletteIndex.isGenerative)
            let gm = PaletteModel(items: gen, frecency: nil)
            gm.query = "generative fill"
            let dialogBefore = AppModel.shared.dialog
            let picked = gm.selected
            let outcome = gm.runSelected()
            check(gen.count >= 4 && picked.map { PaletteIndex.isGenerative($0.item) } == true && outcome == .disabled && AppModel.shared.dialog == dialogBefore,
                  "real menu: generative commands are refused in automated runs",
                  "\(gen.count) generative entries, picked \(picked?.item.id ?? "nil"), outcome \(outcome), dialog \(String(describing: AppModel.shared.dialog?.id))")
            check(GenAIKeychain.shared.keyedProviders.isEmpty && GenAIKeychain.shared.key(.fal) == nil, "automated runs never see real provider keys")
            full.first { $0.id == "menu:View ▸ Compare ▸ with Original" }?.run()
            check(CompareController.shared.isActive(for: probe), "real menu: registry entry runs its action")
            CompareController.shared.exit()
            AppModel.shared.close(probe)
        } else { print("workflow2: NSApp.mainMenu is not available in this run; real-menu checks skipped") }

        // registry items (module menus)
        let reg = PaletteIndex.registryItems()
        check(reg.first { $0.title == "Save Incremental" }?.shortcut == "⌥⌘S", "registry index: shortcut of registered items")
        check(reg.first { $0.title == "Timelapse Video…" }?.subtitle == "File ▸ Export", "registry index: submenu path")
        check(!reg.contains { $0.title == "Command Palette…" }, "registry index: the palette does not list itself")

        // full index
        let d = makeDoc("palette")
        app.add(d)
        defer { app.close(d) }
        d.updateLayer(d.state.layers[1].id) { $0.name = "Hero Card" }
        PaletteIndex.recentURLs = { [URL(fileURLWithPath: "/tmp/poster_final.imagecrat")] }
        let items = PaletteIndex.build(menu: menu)
        let ids = items.map(\.id)
        check(Set(ids).count == ids.count, "index: ids are unique")
        func has(_ id: String) -> Bool { ids.contains(id) }
        check(ToolKind.allCases.allSatisfy { has("tool:" + $0.rawValue) }, "index: every tool")
        check(has("filter:motionBlur") == false && has("filter:twirl") && items.filter { PaletteIndex.normalized($0.title) == "gaussian blur" }.count == 1,
              "index: filters (no duplicate of a menu item)")
        check(has("adjust:levels") && has("adjlayer:curves"), "index: adjustments and adjustment layers")
        check(has("panel:layers") && has("panel:historyTree") && has("panel:preflight"), "index: panels")
        check(items.contains { $0.category == .layer && $0.title == "Hero Card" }, "index: layers by name")
        check(has("recent:/tmp/poster_final.imagecrat"), "index: recent files")
        check(items.contains { $0.category == .action }, "index: actions")
        check(has("brush:soft45") && items.contains { $0.id.hasPrefix("gradient:") } && items.contains { $0.id.hasPrefix("docpreset:") } && has("workspace:Painting"), "index: presets")
        check(has("prefs:Workflow") && has("prefs:Units"), "index: preferences sections")
        check(has("hint:opacity"), "index: verb syntax hints")
        check(items.count > 250, "index: size", "\(items.count)")

        // ranking
        func top(_ q: String, _ f: PaletteFrecency? = nil) -> PaletteResult? { PaletteSearch.search(q, items: items, frecency: f, fontFamilies: fams).first }
        check(top("brush")?.item.id == "tool:brush", "rank: “brush” → Brush Tool", top("brush")?.item.title ?? "-")
        check(top("gaus")?.item.title == "Gaussian Blur…", "rank: “gaus” → Gaussian Blur…", top("gaus")?.item.title ?? "-")
        check(top("hero")?.item.category == .layer, "rank: layer name", top("hero")?.item.title ?? "-")
        check(top("final")?.item.category == .recent, "rank: recent file", top("final")?.item.title ?? "-")
        check(top("1920/3")?.item.title == "= 640" && top("1920/3")?.item.category == .calc, "rank: calculator result first")
        let ov = top("opacity 50")
        check(ov?.item.category == .verb && ov?.item.title == "Set layer opacity to 50%" && ov?.item.enabled == true, "rank: verb first", ov?.item.title ?? "-")
        check(top("feather 4")?.item.enabled == false, "rank: verb without a selection is greyed")
        let mergeResult = PaletteSearch.search("merge down", items: items, frecency: nil).first { $0.item.title == "Merge Down" }
        check(mergeResult != nil && mergeResult?.item.enabled == false, "rank: disabled menu item is listed but not runnable")
        check(PaletteSearch.search("merge", items: items, frecency: nil).first?.item.enabled == true, "rank: disabled entries sort below runnable ones")
        check(!(top("")?.item.title.isEmpty ?? true), "rank: empty query shows suggestions")

        // frecency (persisted)
        let fURL = tmp.appendingPathComponent("frecency.json")
        let fr = PaletteFrecency(url: fURL)
        let before = PaletteSearch.search("fl", items: items, frecency: fr).map(\.item.title)
        let iFlat = before.firstIndex(of: "Flatten Image") ?? 99, iFlip = before.firstIndex(of: "Flip Canvas Horizontal") ?? 99
        check(iFlat < iFlip, "frecency: baseline order", "\(before.prefix(4))")
        for _ in 0..<6 { fr.bump("menu:Layer ▸ Flip Canvas Horizontal") }
        let after = PaletteSearch.search("fl", items: items, frecency: fr).map(\.item.title)
        check((after.firstIndex(of: "Flip Canvas Horizontal") ?? 99) < (after.firstIndex(of: "Flatten Image") ?? 99), "frecency: frequently used entry moves up", "\(after.prefix(4))")
        let fr2 = PaletteFrecency(url: fURL)
        check(fr2.entries["menu:Layer ▸ Flip Canvas Horizontal"]?.count == 6, "frecency: persisted to disk and reloaded")
        let old = fr2.boost("menu:Layer ▸ Flip Canvas Horizontal", now: Date().addingTimeInterval(90 * 86400))
        check(old < fr2.boost("menu:Layer ▸ Flip Canvas Horizontal") && old > 0, "frecency: fades with time")
        check(PaletteSearch.search("", items: items, frecency: fr2).first?.item.title == "Flip Canvas Horizontal", "frecency: empty query lists most used first")

        // model + keys
        var ran = 0, closed = 0
        var mini = [PaletteItem(id: "t1", title: "Alpha One", category: .menu) { ran += 1 },
                    PaletteItem(id: "t2", title: "Alpha Two", category: .menu) { ran += 10 },
                    PaletteItem(id: "t3", title: "Alpha Off", category: .menu, enabled: false) { ran += 100 }]
        mini.append(PaletteItem(id: "hint:opacity", title: "opacity 50", subtitle: "Layer opacity", category: .hint, keywords: "opacity", insertText: "opacity "))
        let model = PaletteModel(items: mini, frecency: PaletteFrecency(url: tmp.appendingPathComponent("frecency2.json")))
        model.onClose = { closed += 1 }
        model.query = "alpha"
        check(model.results.count == 3 && model.selection == 0 && model.results.last?.item.id == "t3", "model: results, disabled last")
        _ = PaletteField.Coordinator.handle(#selector(NSResponder.moveDown(_:)), model: model, commandDown: false)
        check(model.selection == 1, "keys: ↓ moves the selection")
        _ = PaletteField.Coordinator.handle(#selector(NSResponder.moveUp(_:)), model: model, commandDown: false)
        _ = PaletteField.Coordinator.handle(#selector(NSResponder.moveUp(_:)), model: model, commandDown: false)
        check(model.selection == 0, "keys: ↑ stops at the top")
        _ = PaletteField.Coordinator.handle(#selector(NSResponder.insertNewline(_:)), model: model, commandDown: false)
        check(ran == 1 && closed == 1, "keys: ↩ runs and closes", "ran \(ran) closed \(closed)")
        model.selection = 1
        let kept = PaletteField.Coordinator.handle(#selector(NSResponder.insertNewline(_:)), model: model, commandDown: true)
        check(kept && ran == 11 && closed == 1 && model.query == "alpha", "keys: ⌘↩ runs and keeps the palette open")
        model.selection = 2
        check(model.runSelected() == .disabled && ran == 11, "model: disabled entries do not run")
        _ = PaletteField.Coordinator.handle(#selector(NSResponder.cancelOperation(_:)), model: model, commandDown: false)
        check(closed == 2, "keys: esc closes")
        check(!PaletteField.Coordinator.handle(#selector(NSResponder.moveLeft(_:)), model: model, commandDown: false), "keys: text editing keys stay with the field")
        model.query = "opac"
        check(model.runSelected() == .inserted && model.query == "opacity ", "model: a syntax hint completes the query")
        model.query = "alpha"
        let panel = PalettePanel(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
        panel.model = model
        let before2 = ran
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
                                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
            let handled = panel.performKeyEquivalent(with: e)
            check(handled && ran > before2 && closed == 2, "keys: panel handles ⌘↩ as a key equivalent", "handled \(handled) ran \(ran - before2) closed \(closed)")
        }
        check(panel.canBecomeKey, "panel: can take the keyboard")

        // verbs on a document
        d.selectLayer(d.state.layers[2].id)
        let h0 = d.history.count
        check(PaletteVerbs.perform(.opacity(50)) && d.activeLayer?.opacity == 0.5 && d.history.count == h0 + 1, "verb run: opacity")
        check(PaletteVerbs.perform(.rename("Hero")) && d.activeLayer?.name == "Hero", "verb run: rename")
        check(PaletteVerbs.perform(.blend(.multiply)) && d.activeLayer?.blendMode == .multiply, "verb run: blend mode")
        _ = PaletteVerbs.perform(.fillColor(RGBA(hex: "ff8800")!))
        let px = d.activeLayer?.raster.map { $0.buffer.pixel(310 - $0.origin.x, 160 - $0.origin.y) } ?? (0, 0, 0, 0)
        check(near(px, (255, 136, 0, 255), 2), "verb run: fill #ff8800", "\(px)")
        d.setSelection(SelectionOps.rectMask(CGRect(x: 100, y: 80, width: 200, height: 120), width: d.state.width, height: d.state.height))
        check(PaletteVerbs.isAvailable(.feather(8, nil)) && PaletteVerbs.perform(.feather(8, .inside)), "verb run: feather available with a selection")
        let edge = d.state.selection?.pixel(101, 140).0 ?? 0, mid = d.state.selection?.pixel(200, 140).0 ?? 0
        check(edge < 200 && mid > 250, "verb run: feather softened the edge inward", "edge \(edge) mid \(mid)")
        check(PaletteVerbs.perform(.zoom(200)) && d.zoom == 2, "verb run: zoom")
        check(PaletteVerbs.perform(.imageSize(240, 150)) && d.state.width == 240 && d.state.height == 150, "verb run: image size")
        let nDocs = app.documents.count
        check(PaletteVerbs.perform(.newDocument(320, 200, "Poster")) && app.documents.count == nDocs + 1 && app.activeDocument?.name == "Poster"
              && app.activeDocument?.state.width == 320, "verb run: new document")
        if let nd = app.activeDocument, nd.id != d.id { app.close(nd) }
        app.activeDocumentID = d.id

        // the "\" key: only through KeyRouter, never while a dialog / text field owns the keyboard
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        canvas.document = d
        AppActions.canvas = canvas
        func key(_ type: NSEvent.EventType, _ ch: String, _ code: UInt16) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                             isARepeat: false, keyCode: code)
        }
        if let down = key(.keyDown, "\\", 42), let up = key(.keyUp, "\\", 42) {
            app.dialog = .about
            check(!KeyRouter.handle(down) && !QuickCompare.isActive, "keys: “\\” is ignored while a dialog is open")
            app.dialog = nil
            let handled = KeyRouter.handle(down)
            check(handled && QuickCompare.isActive && d.displayOverride != nil, "keys: holding “\\” shows the original (through KeyRouter)")
            check(KeyRouter.handle(up) && !QuickCompare.isActive && d.displayOverride == nil, "keys: releasing “\\” restores the view")
        }
        if let b = key(.keyDown, "b", 11) { check(!Workflow2Keys.handle(b), "keys: other keys pass through") }
        AppActions.canvas = nil
    }

    // MARK: 2. Branching history

    static func branches(_ out: URL) {
        let tree = HistoryTree.shared
        let d = makeDoc("branches")
        let id = d.state.layers[1].id
        func step(_ name: String, _ opacity: Double) { d.updateLayer(id) { $0.opacity = opacity }; d.commit(name) }
        step("A", 0.9); step("B", 0.7); step("C", 0.5)
        let stateC = d.state
        d.undo(); d.undo()
        check(tree.branches(d).isEmpty, "branch: undo alone creates no branch")
        step("D", 0.2)
        var list = tree.branches(d)
        check(list.count == 1 && list[0].entries.map(\.name) == ["B", "C"] && list[0].forkName == "A", "branch: discarded redo steps are kept as a branch",
              "\(list.map { $0.entries.map(\.name) })")
        check(d.history.map(\.name) == ["Open", "A", "D"] && list[0].name == "Branch 1" && tree.currentLineName(d) == "Main", "branch: active line and names")
        check(tree.branchesByFork(d)[d.history[1].id]?.count == 1, "branch: hangs off its fork step")
        check(list[0].entries[1].state.layers[0].raster?.buffer === d.state.layers[0].raster?.buffer, "branch: states share unchanged pixel buffers")

        // switch
        let b1 = list[0].id
        check(tree.switchTo(b1, in: d), "branch: switch")
        list = tree.branches(d)
        check(d.history.map(\.name) == ["Open", "A", "B", "C"] && d.historyIndex == 3 && diff(d.state, stateC) < 0.01, "branch: switching restores the branch's steps and state",
              "\(d.history.map(\.name)) idx \(d.historyIndex)")
        check(list.count == 1 && list[0].entries.map(\.name) == ["D"] && list[0].name == "Main" && tree.currentLineName(d) == "Branch 1", "branch: replaced steps become a branch, names follow")
        d.undo()
        check(d.state.layer(id)?.opacity == 0.7 && d.canRedo, "branch: undo / redo work on the switched line")
        d.redo()
        // switch back to a specific step
        check(tree.switchTo(list[0].id, in: d, step: 0) && d.history.map(\.name) == ["Open", "A", "D"] && d.state.layer(id)?.opacity == 0.2, "branch: switch back")
        list = tree.branches(d)
        check(list.count == 1 && list[0].name == "Branch 1" && list[0].entries.count == 2, "branch: round trip keeps the other line intact")
        check(tree.switchTo(list[0].id, in: d, step: 0) && d.historyIndex == 2 && d.history[d.historyIndex].name == "B", "branch: switch to a step inside the branch")

        // nested: from B make E (C becomes Branch 2 inside the current line), then go to Main and back into the nested branch
        step("E", 0.33)
        check(d.history.map(\.name) == ["Open", "A", "B", "E"], "branch: nested setup")
        let main = tree.branches(d).first { $0.name == "Main" }
        check(main != nil && tree.switchTo(main!.id, in: d), "branch: to main")
        list = tree.branches(d)
        let parent = list.first { $0.entries.map(\.name) == ["B", "E"] }
        let nested = list.first { $0.entries.map(\.name) == ["C"] }
        check(parent != nil && nested != nil && tree.children(of: parent!, in: d).map(\.id) == [nested!.id], "branch: nested branch hangs off its parent branch",
              "\(list.map { $0.entries.map(\.name) })")
        check(tree.switchTo(nested!.id, in: d) && d.history.map(\.name) == ["Open", "A", "B", "C"] && diff(d.state, stateC) < 0.01, "branch: switching into a nested branch rebuilds the path")
        list = tree.branches(d)
        check(Set(list.map { $0.entries.map(\.name).joined() }) == ["D", "E"] && list.first { $0.entries.first?.name == "E" }?.forkName == "B", "branch: leftovers stay reachable",
              "\(list.map { ($0.name, $0.entries.map(\.name), $0.forkName) })")

        // management
        let nd = tree.openAsDocument(list[0].id, in: d)
        check(nd != nil && AppModel.shared.documents.contains { $0.id == nd!.id }, "branch: open as a new document")
        if let nd { AppModel.shared.close(nd) }
        tree.rename(list[0].id, in: d, to: "Warm look")
        check(tree.branches(d).first?.name == "Warm look", "branch: rename")
        tree.delete(list[0].id, in: d)
        check(tree.branches(d).count == 1, "branch: delete")
        let savedMax = Workflow2Settings.shared.prefs.maxBranches
        Workflow2Settings.shared.prefs.maxBranches = 2
        for i in 0..<4 { d.undo(); step("X\(i)", 0.1 + Double(i) * 0.1) }
        check(tree.branches(d).count == 2, "branch: count capped by the preference", "\(tree.branches(d).count)")
        Workflow2Settings.shared.prefs.maxBranches = savedMax
        tree.suppress = true
        d.undo(); step("quiet", 0.6)
        tree.suppress = false
        check(tree.branches(d).count == 2, "branch: internal rewrites don't create branches")
        tree.forget(d.id)

        // memory budget: branches may only keep a bounded amount of pixels alive
        let m = makeDoc("memory", w: 512, h: 512)
        let paint = m.state.layers[2].id
        func stroke(_ i: Int) {     // every step replaces the layer's pixels, like a paint stroke does
            m.updateLayer(paint) { $0.raster = RasterContent(buffer: solid(512, 512, RGBA(gray: Double(i) / 20)), origin: .zero) }
            m.commit("Stroke \(i)")
        }
        for i in 0..<6 { stroke(i) }
        for _ in 0..<5 { m.undo() }
        stroke(10)
        let oneMB = 512 * 512 * 4
        check(tree.branches(m).first?.entries.count == 5 && tree.memory(m) == 5 * oneMB, "branch: memory of a kept branch is accounted", "\(tree.memory(m))")
        let savedBudget = Workflow2Settings.shared.prefs.branchMemoryMB
        Workflow2Settings.shared.prefs.branchMemoryMB = 16
        for i in 0..<4 { stroke(20 + i) }
        for _ in 0..<4 { m.undo() }
        stroke(30)                      // second branch of 4 MB: 5 + 4 MB fit in 16 MB
        check(tree.branches(m).count == 2 && tree.memory(m) == 9 * oneMB, "branch: within the memory budget both branches stay")
        for i in 0..<10 { stroke(40 + i) }
        for _ in 0..<10 { m.undo() }
        stroke(60)                      // third branch of 10 MB: oldest goes
        check(tree.branches(m).count == 2 && tree.memory(m) <= 16 * oneMB && !tree.branches(m).contains { $0.name == "Branch 1" }, "branch: over budget the oldest branch is released",
              "\(tree.branches(m).map(\.name)) \(tree.memory(m) / oneMB) MB")
        for i in 0..<30 { stroke(70 + i) }
        for _ in 0..<30 { m.undo() }
        stroke(110)                     // a single 30 MB branch: truncated to what fits
        let only = tree.branches(m)
        check(only.count == 1 && only[0].entries.count == 16 && tree.memory(m) <= 16 * oneMB, "branch: an oversized branch keeps the steps that fit", "\(only.map { $0.entries.count })")
        Workflow2Settings.shared.prefs.branchMemoryMB = savedBudget
        tree.forget(m.id)
    }

    // MARK: 3. Versions

    static func versions(_ out: URL) {
        let store = VersionStore.shared
        let d = makeDoc("versions")
        let s1 = d.state
        let v1 = store.save(d, name: "First pass", note: "client review")
        check(d.isDirty && d.history.last?.name == "Save Version “First pass”", "version: saving marks the document as changed")
        check(store.state(of: v1.id)?.layers[0].raster?.buffer === s1.layers[0].raster?.buffer, "version: shares pixel buffers with history in memory")
        var extra = SelfTest.shapeLayer(CGRect(x: 250, y: 30, width: 180, height: 90), RGBA(hex: "27AE60")!); extra.name = "Green"
        d.addLayer(extra, commitName: "New Shape")
        let s2 = d.state
        let v2 = store.save(d, name: "", note: "")
        check(v2.name == "Version 2" && store.versions(d).count == 2 && v2.thumbnail != nil && v2.layerCount == 4, "version: default name, thumbnail, metadata")
        d.updateLayer(d.state.layers[1].id) { $0.opacity = 0.3 }; d.commit("Opacity")

        // file round trip
        let url = tmp.appendingPathComponent("versions.imagecrat")
        do {
            try DocumentIO.saveNative(d, to: url)
            let back = try DocumentIO.load(url: url)
            let list = store.versions(back)
            check(list.count == 2 && list[0].name == "First pass" && list[0].note == "client review" && list[1].name == "Version 2", "version: stored inside the .imagecrat file",
                  "\(list.map(\.name))")
            check(list[0].thumbnail != nil && store.thumbnail(list[0]) != nil && abs(list[0].date.timeIntervalSince(v1.date)) < 1, "version: thumbnail and timestamp survive")
            check(diff(back.state, d.state) < 0.01, "version: the document itself is unchanged by the side data")
            let h = back.history.count
            check(store.restore(list[0].id, in: back) && diff(back.state, s1) < 0.01 && back.history.count == h + 1, "version: restore from file gives the identical composite")
            back.undo()
            check(diff(back.state, d.state) < 0.01, "version: restore is undoable")
            let nd = store.openAsDocument(list[1].id, in: back)
            check(nd != nil && diff(nd!.state, s2) < 0.01 && nd!.name.contains("Version 2"), "version: open as a new document")
            if let nd { AppModel.shared.close(nd) }
            store.delete(list[0].id, in: back)
            check(store.versions(back).count == 1, "version: delete")
            // save again: remaining version written from its packed form
            let url2 = tmp.appendingPathComponent("versions2.imagecrat")
            try DocumentIO.saveNative(back, to: url2)
            let back2 = try DocumentIO.load(url: url2)
            check(store.versions(back2).map(\.name) == ["Version 2"] && store.state(of: store.versions(back2)[0].id).map { diff($0, s2) < 0.01 } == true, "version: re-save keeps packed versions")
            check(store.estimatedBytes(d) > 0, "version: size estimate")
            Workflow2Module.forget(back.id); Workflow2Module.forget(back2.id)
        } catch { check(false, "version: file round trip", "\(error)") }

        // tolerant decoding
        let enc = PropertyListEncoder(); enc.outputFormat = .binary
        let plain = tmp.appendingPathComponent("old.imagecrat")
        if let data = try? enc.encode(LumenFile(name: "old", state: s1)) {
            try? data.write(to: plain)
            let old = try? DocumentIO.load(url: plain)
            check(old != nil && store.versions(old!).isEmpty, "version: files without side data open normally")
            if let old { Workflow2Module.forget(old.id) }
        }
        let junk = tmp.appendingPathComponent("junk.imagecrat")
        if let data = try? enc.encode(LumenFile(name: "junk", state: s1, extras: [VersionStore.extrasKey: Data([1, 2, 3, 4]), "someone.else": Data([9])])) {
            try? data.write(to: junk)
            let j = try? DocumentIO.load(url: junk)
            check(j != nil && store.versions(j!).isEmpty && diff(j!.state, s1) < 0.01, "version: damaged or unknown side data is ignored")
            if let j { Workflow2Module.forget(j.id) }
        }
        if let payload = VersionStore.pack(s2), let partial = try? PropertyListSerialization.data(fromPropertyList: ["items": [["name": "Bare", "payload": payload] as [String: Any], ["name": "no payload"] as [String: Any]]] as [String: Any],
                                                                                              format: .binary, options: 0) {
            let host = Document(state: s1, name: "host")
            store.decode(host, partial)
            let list = store.versions(host)
            check(list.count == 1 && list[0].name == "Bare" && list[0].note.isEmpty && store.state(of: list[0].id).map { diff($0, s2) < 0.01 } == true,
                  "version: missing fields fall back to defaults", "\(list.map(\.name))")
            store.forget(host.id)
        }
        check(VersionStore.unpack(Data()) == nil && VersionStore.unpack(Data([1, 0, 0])) == nil, "version: unreadable payloads return nil")
        store.forget(d.id)
    }

    static var fm: FileManager { FileManager.default }

    // MARK: 4. Compare, quick compare, isolate

    static func compareAndIsolate(_ out: URL) {
        let app = AppModel.shared
        let cmp = CompareController.shared
        let d = makeDoc("compare")
        let other = makeDoc("other")
        app.add(other); app.add(d)
        defer { app.close(d); app.close(other) }
        let original = buffer(d.state)
        var block = SelfTest.shapeLayer(CGRect(x: 20, y: 180, width: 440, height: 100), RGBA(hex: "111111")!, radius: 0); block.name = "Block"
        d.addLayer(block, commitName: "Add Block")
        let current = buffer(d.state)
        let historyCount = d.history.count, dirty = d.isDirty

        check(cmp.start(d, source: .original, layout: .split) && cmp.isActive(for: d) && d.displayOverride != nil && cmp.label == "Original", "compare: start with Original")
        cmp.split = 0.5
        var v = viewBuffer(d)
        check(near(v.pixel(100, 230), original.pixel(100, 230)) && near(v.pixel(380, 230), current.pixel(380, 230)) && !near(v.pixel(100, 230), v.pixel(380, 230), 20),
              "compare: split shows before on the left, after on the right")
        cmp.split = 0.9
        v = viewBuffer(d)
        check(near(v.pixel(380, 230), original.pixel(380, 230)), "compare: moving the divider reveals more of the reference")
        savePNG(v, "w2_compare_split", out)
        cmp.layout = .difference
        v = viewBuffer(d)
        check(near(v.pixel(100, 60), (0, 0, 0, 255), 2) && Int(v.pixel(100, 230).0) + Int(v.pixel(100, 230).1) > 100, "compare: difference is black where nothing changed")
        savePNG(v, "w2_compare_difference", out)
        cmp.layout = .onion; cmp.split = 1
        check(near(viewBuffer(d).pixel(100, 230), original.pixel(100, 230)), "compare: onion skin at 100% shows the reference")
        cmp.split = 0
        check(near(viewBuffer(d).pixel(100, 230), current.pixel(100, 230)), "compare: onion skin at 0% shows the current state")
        cmp.layout = .sideBySide
        v = viewBuffer(d)
        // block spans y 180…280 → in the half-size right copy it is around y 75+115=190…; left copy has no block there
        check(near(v.pixel(360, 190), (17, 17, 17, 255), 6) && !near(v.pixel(120, 190), (17, 17, 17, 255), 20) && v.pixel(240, 20).3 == 0, "compare: side by side")
        savePNG(v, "w2_compare_side_by_side", out)
        check(d.history.count == historyCount && d.isDirty == dirty, "compare: nothing is recorded in history")

        cmp.exit()
        check(!cmp.isActive && d.displayOverride == nil && Workflow2Util.bufferDifference(viewBuffer(d), current) < 0.01, "compare: exit restores the normal view")
        // an override that was there before is put back
        var marker = 0
        d.displayOverride = { marker += 1; return $0 }
        cmp.start(d, source: .previous, layout: .split)
        _ = viewBuffer(d)
        cmp.exit()
        marker = 0
        _ = viewBuffer(d)
        check(d.displayOverride != nil && marker == 1, "compare: a previous display override is preserved")
        d.displayOverride = nil
        // tool switch and document switch leave compare mode
        cmp.start(d, source: .original)
        app.tool = app.tool == .zoom ? .hand : .zoom
        check(!cmp.isActive && d.displayOverride == nil, "compare: switching tools cleans up")
        cmp.start(d, source: .original)
        app.activeDocumentID = other.id
        check(!cmp.isActive && d.displayOverride == nil, "compare: switching documents cleans up")
        app.activeDocumentID = d.id
        // other sources
        let ver = VersionStore.shared.save(d, name: "cmp", state: d.history[0].state)
        check(cmp.start(d, source: .version(ver.id)) && cmp.label == "Version: cmp", "compare: with a version")
        check(cmp.start(d, source: .historyEntry(d.history[0].id)) && cmp.label.hasPrefix("History:"), "compare: with a history state")
        let snap = SnapshotStore.shared.newSnapshot(d, name: "snap")
        check(cmp.start(d, source: .snapshot(snap.id)) && cmp.label == "Snapshot: snap", "compare: with a snapshot")
        d.undo(); d.updateLayer(d.state.layers[1].id) { $0.opacity = 0.4 }; d.commit("Fade")
        if let b = HistoryTree.shared.branches(d).first { check(cmp.start(d, source: .branch(b.id)) && cmp.label.hasPrefix("Branch:"), "compare: with a history branch") }
        else { check(false, "compare: branch source available") }
        cmp.exit()
        check(!cmp.start(d, source: .version(UUID())) && !cmp.isActive, "compare: unknown source is refused")
        // different canvas size: reference is fitted
        AppActions.canvas = nil
        let big = SelfTest.baseState(960, 600)
        check(cmp.start(d, reference: big, label: "big") && viewBuffer(d).width == d.state.width, "compare: reference of another size is fitted")
        cmp.exit()
        cmp.start(d, source: .original)
        d.displayOverride = nil         // e.g. a dialog's preview cleared it
        cmp.validate()
        check(!cmp.isActive, "compare: notices when something else cleared the view override")
        VersionStore.shared.delete(ver.id, in: d)

        // quick compare
        QuickCompare.begin(d)
        check(QuickCompare.isActive && near(viewBuffer(d).pixel(100, 230), original.pixel(100, 230)), "quick compare: shows the first state")
        QuickCompare.end()
        check(!QuickCompare.isActive && d.displayOverride == nil, "quick compare: ends cleanly")

        // isolate
        let iso = IsolateMode.shared
        var st = SelfTest.baseState(480, 300)
        var a = SelfTest.shapeLayer(CGRect(x: 30, y: 30, width: 120, height: 90), RGBA(hex: "E94F37")!); a.name = "A"
        var bL = SelfTest.shapeLayer(CGRect(x: 180, y: 30, width: 120, height: 90), RGBA(hex: "27AE60")!); bL.name = "B"
        var inner = SelfTest.shapeLayer(CGRect(x: 330, y: 160, width: 120, height: 90), RGBA(hex: "2E86DE")!); inner.name = "Inner"
        var sibling = SelfTest.shapeLayer(CGRect(x: 330, y: 30, width: 120, height: 90), RGBA(hex: "F1C40F")!); sibling.name = "Sibling"
        let group = Layer(name: "Group", content: .group(GroupContent(children: [inner, sibling])))
        var clip = Layer(name: "Clip", content: .fill(FillContent(paint: .color(RGBA(hex: "8E44AD")!)))); clip.isClipped = true
        st.layers += [a, clip, bL, group]
        let idoc = Document(state: st, name: "isolate")
        app.add(idoc)
        defer { app.close(idoc) }
        check(IsolateMode.keepSet(st, selection: [inner.id]) == [inner.id, group.id], "isolate: keeps the layer and its ancestors")
        check(IsolateMode.keepSet(st, selection: [group.id]) == [group.id, inner.id, sibling.id], "isolate: a group keeps its children")
        check(IsolateMode.keepSet(st, selection: [clip.id]) == [clip.id, a.id], "isolate: a clipped layer keeps its base")
        idoc.selectLayer(inner.id)
        let h = idoc.history.count
        check(iso.enter(idoc) && iso.isActive(for: idoc), "isolate: enter")
        var expect = st
        expect.layers = [group]
        expect.updateLayer(sibling.id) { $0.isVisible = false }
        check(Workflow2Util.bufferDifference(RenderEngine.renderBuffer(Compositor.shared.composite(idoc), docRect: st.canvasRect, space: CanvasSpace(width: 480, height: 300)), buffer(expect)) < 0.01,
              "isolate: only the selected layer is composited")
        check(idoc.history.count == h && !idoc.isDirty && idoc.state.allLayers.allSatisfy(\.isVisible), "isolate: view-only, the document is untouched")
        idoc.updateLayer(bL.id) { $0.opacity = 0.5 }; idoc.commit("Edit while isolated")
        idoc.undo()            // undo resets the document's live-preview state
        iso.refresh()
        check(idoc.hiddenLayers.contains(a.id) && idoc.hiddenLayers.contains(bL.id) && !idoc.hiddenLayers.contains(inner.id), "isolate: survives undo")
        iso.dim = true
        check(idoc.hiddenLayers.isEmpty && idoc.contentOverrides[a.id] != nil && idoc.contentOverrides[inner.id] == nil, "isolate: dim mode uses content overrides")
        savePNG(RenderEngine.renderBuffer(Compositor.shared.composite(idoc), docRect: st.canvasRect, space: CanvasSpace(width: 480, height: 300)), "w2_isolate_dim", out)
        iso.dim = false
        iso.toggle(idoc)
        check(!iso.isActive && idoc.hiddenLayers.isEmpty && idoc.contentOverrides.isEmpty, "isolate: exit removes every override")
        check(Workflow2Util.bufferDifference(RenderEngine.renderBuffer(Compositor.shared.composite(idoc), docRect: st.canvasRect, space: CanvasSpace(width: 480, height: 300)), buffer(idoc.state)) < 0.01,
              "isolate: composite back to normal")
        HistoryTree.shared.forget(d.id); HistoryTree.shared.forget(idoc.id)
    }

    // MARK: 5. Autosave & recovery

    static func autosave(_ out: URL) {
        let app = AppModel.shared
        let root = tmp.appendingPathComponent("support/Recovery")
        let deadPid: Int32 = 999_999, livePid: Int32 = 424_242
        let savedAlive = Autosave.isSessionAlive
        Autosave.isSessionAlive = { $0 == livePid }          // stands in for a second running copy of Lumen
        defer { Autosave.isSessionAlive = savedAlive }
        check(!savedAlive(deadPid) && !savedAlive(ProcessInfo.processInfo.processIdentifier) && !savedAlive(getppid()), "recovery: dead, own and foreign processes are not live Lumen sessions")
        let a = Autosave(root: root, sessionID: "session-A", pid: deadPid)

        let saved = makeDoc("saved.imagecrat")
        let savedURL = tmp.appendingPathComponent("saved.imagecrat")
        try? DocumentIO.saveNative(saved, to: savedURL)
        saved.fileURL = savedURL; saved.markSaved()
        let unsaved = makeDoc("Untitled-7")
        let clean = makeDoc("clean")
        for d in [saved, unsaved, clean] { app.add(d) }
        defer { for d in [saved, unsaved, clean] { app.close(d) } }
        saved.updateLayer(saved.state.layers[1].id) { $0.opacity = 0.35 }; saved.commit("Fade")
        var star = SelfTest.shapeLayer(CGRect(x: 200, y: 40, width: 200, height: 200), RGBA(hex: "F1C40F")!, radius: 100); star.name = "Sun"
        unsaved.addLayer(star, commitName: "Add Sun")
        VersionStore.shared.save(unsaved, name: "With sun")
        check(Autosave.needsAutosave(saved) && Autosave.needsAutosave(unsaved) && !Autosave.needsAutosave(clean), "autosave: only documents with unsaved changes")

        a.saveAll(sync: true)
        var entries = Autosave.entries(in: a.sessionDir)
        check(entries.count == 2 && Set(entries.map(\.name)) == ["saved.imagecrat", "Untitled-7"], "autosave: recovery copies written", "\(entries.map(\.name))")
        let eSaved = entries.first { $0.name == "saved.imagecrat" }
        check(eSaved?.originalPath == savedURL.path && eSaved?.thumb != nil && eSaved?.files.count == 1 && eSaved?.width == 480, "autosave: manifest (path, thumbnail, size)")
        check(a.sessionDir.path.hasPrefix(tmp.path) && fm.fileExists(atPath: a.sessionDir.appendingPathComponent("session.json").path), "autosave: session folder under the support directory")
        let count1 = ((try? fm.contentsOfDirectory(atPath: a.sessionDir.path)) ?? []).count
        a.saveAll(sync: true)
        check(((try? fm.contentsOfDirectory(atPath: a.sessionDir.path)) ?? []).count == count1, "autosave: unchanged documents are not written again")
        // rolling copies
        for i in 0..<3 { saved.updateLayer(saved.state.layers[1].id) { $0.opacity = 0.5 + Double(i) * 0.1 }; saved.commit("Tweak \(i)"); a.saveAll(sync: true) }
        entries = Autosave.entries(in: a.sessionDir)
        let files = entries.first { $0.name == "saved.imagecrat" }?.files ?? []
        let onDisk = ((try? fm.contentsOfDirectory(atPath: a.sessionDir.path)) ?? []).filter { $0.hasPrefix(saved.id.uuidString) && $0.hasSuffix(".imagecrat") }
        check(files.count == 2 && Set(onDisk) == Set(files), "autosave: keeps the configured number of copies", "\(files) / \(onDisk)")
        // background path
        unsaved.updateLayer(unsaved.state.layers[1].id) { $0.opacity = 0.8 }; unsaved.commit("More")
        a.save(unsaved)                 // asynchronous: encoded and written on the autosave queue
        a.flush()
        let latest = Autosave.entries(in: a.sessionDir).first { $0.name == "Untitled-7" }
        check(latest?.files.count == 2, "autosave: background write completes (atomic file + manifest)")
        let stray = ((try? fm.contentsOfDirectory(atPath: a.sessionDir.path)) ?? []).filter { !$0.hasSuffix(".imagecrat") && !$0.hasSuffix(".json") }
        check(stray.isEmpty, "autosave: no partial files left behind", "\(stray)")

        // a second live session (this process) is not offered for recovery
        let live = Autosave(root: root, sessionID: "session-live", pid: livePid)
        live.save(unsaved, sync: true, force: true)

        // simulated unclean exit of session A: a new session finds its documents
        let b = Autosave(root: root, sessionID: "session-B")
        let items = b.recoverable()
        check(items.count == 2 && items.allSatisfy { $0.session.lastPathComponent == "session-A" }, "recovery: documents of the crashed session are listed", "\(items.map { $0.id })")
        check(items.allSatisfy { $0.entry.thumb != nil && $0.bytes > 0 && $0.newestFile != nil } && items[0].entry.date >= items[1].entry.date, "recovery: list has thumbnails, sizes, newest first")
        let docs = b.recover(items, addToApp: false)
        let rSaved = docs.first { $0.name == "saved.imagecrat" }, rUnsaved = docs.first { $0.name == "Untitled-7" }
        check(docs.count == 2 && rSaved != nil && rUnsaved != nil, "recovery: documents load")
        if let rSaved, let rUnsaved {
            check(diff(rSaved.state, saved.state) < 0.01 && diff(rUnsaved.state, unsaved.state) < 0.01, "recovery: content identical to the last autosave")
            check(rSaved.fileURL == savedURL && rUnsaved.fileURL == nil && rSaved.isDirty && rUnsaved.isDirty, "recovery: original file kept, documents are unsaved")
            check(VersionStore.shared.versions(rUnsaved).map(\.name) == ["With sun"], "recovery: versions come back too")
            check(!fm.fileExists(atPath: a.sessionDir.path) && b.recoverable().isEmpty, "recovery: recovered copies are removed from the old session")
            check(Autosave.entries(in: b.sessionDir).count == 2, "recovery: the new session protects the recovered documents immediately")
            // damaged newest copy falls back to the older one
            let c = Autosave(root: root, sessionID: "session-C", pid: deadPid)
            c.save(unsaved, sync: true, force: true)
            unsaved.updateLayer(unsaved.state.layers[1].id) { $0.opacity = 0.6 }; unsaved.commit("Again")
            c.save(unsaved, sync: true)
            if let e = Autosave.entries(in: c.sessionDir).first, let newest = e.files.first {
                try? Data([0, 1, 2]).write(to: c.sessionDir.appendingPathComponent(newest))
                let it = RecoveryItem(session: c.sessionDir, entry: e)
                let fallback = b.load(it)
                check(fallback != nil, "recovery: falls back to an older copy when the newest is damaged")
                if let fallback { Workflow2Module.forget(fallback.id) }
                b.discard([it])
                check(!fm.fileExists(atPath: c.sessionDir.path), "recovery: discard removes the files")
            }
            // cleanup on save / close
            app.add(rSaved); app.add(rUnsaved)
            rSaved.markSaved()
            b.reconcile(); b.flush()
            check(Autosave.entries(in: b.sessionDir).map(\.name) == ["Untitled-7"], "autosave: saving a document removes its recovery copy")
            app.close(rUnsaved)
            b.reconcile(); b.flush()
            check(Autosave.entries(in: b.sessionDir).isEmpty, "autosave: closing a document removes its recovery copy")
            app.close(rSaved)
            Workflow2Module.forget(rSaved.id); Workflow2Module.forget(rUnsaved.id)
        }
        // normal quit
        b.save(unsaved, sync: true, force: true)
        b.endSession()
        check(!fm.fileExists(atPath: b.sessionDir.path), "autosave: a normal quit leaves nothing of the session")
        check(Autosave(root: root, sessionID: "session-D").recoverable().isEmpty, "recovery: nothing offered after clean exits (live sessions are skipped)")
        live.endSession()
        check(!fm.fileExists(atPath: root.path), "autosave: empty recovery folder is removed")
        // tolerant manifest
        let e = try? JSONDecoder().decode(RecoveryEntry.self, from: Data(#"{"id":"x","files":["a.imagecrat"],"future":1}"#.utf8))
        check(e?.name == "Untitled" && e?.files == ["a.imagecrat"], "recovery: manifest decoding tolerates missing / unknown fields")
        VersionStore.shared.forget(unsaved.id)
    }

    // MARK: 6. Save Incremental / Revert

    static func incrementalAndRevert(_ out: URL) {
        let dir = tmp.appendingPathComponent("inc")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func next(_ name: String, _ existing: [String]) -> String { FileVersions.nextIncrementalURL(for: dir.appendingPathComponent(name), existing: existing).lastPathComponent }
        check(next("poster.imagecrat", ["poster.imagecrat"]) == "poster_v002.imagecrat", "incremental: first version number")
        check(next("poster_v002.imagecrat", ["poster.imagecrat", "poster_v002.imagecrat", "poster_v003.imagecrat"]) == "poster_v004.imagecrat", "incremental: skips numbers already on disk")
        check(next("a_v09.imagecrat", []) == "a_v010.imagecrat" && next("shot_v0012.imagecrat", []) == "shot_v0013.imagecrat", "incremental: padding")
        check(next("poster.imagecrat", ["poster_v007.psd", "posterx_v009.imagecrat"]) == "poster_v002.imagecrat", "incremental: other files are ignored")

        let d = makeDoc("inc.imagecrat")
        let url = dir.appendingPathComponent("inc.imagecrat")
        try? DocumentIO.saveNative(d, to: url)
        d.fileURL = url; d.markSaved()
        d.updateLayer(d.state.layers[1].id) { $0.opacity = 0.4 }; d.commit("Fade")
        let u2 = FileVersions.saveIncremental(d)
        check(u2?.lastPathComponent == "inc_v002.imagecrat" && fm.fileExists(atPath: u2?.path ?? "") && d.fileURL == u2 && d.name == "inc_v002.imagecrat" && !d.isDirty, "incremental: saves the next file and continues there")
        d.updateLayer(d.state.layers[1].id) { $0.opacity = 0.8 }; d.commit("Fade 2")
        let u3 = FileVersions.saveIncremental(d)
        check(u3?.lastPathComponent == "inc_v003.imagecrat" && fm.fileExists(atPath: url.path) && fm.fileExists(atPath: u2?.path ?? ""), "incremental: earlier files are untouched")
        if let u2, let first = try? DocumentIO.load(url: u2) {
            check(first.state.layers[1].opacity == 0.4, "incremental: each file holds its own state")
            Workflow2Module.forget(first.id)
        }

        // revert
        let savedState = d.state
        d.state.layers.removeLast(); d.commit("Delete Layer")
        let edited = d.state
        check(d.isDirty && FileVersions.canRevert(d), "revert: available for a saved, changed document")
        let h = d.history.count
        check(FileVersions.revertToSaved(d, confirm: false) && diff(d.state, savedState) < 0.01 && !d.isDirty && d.history.count == h + 1 && d.history.last?.name == "Revert", "revert: back to the file on disk")
        d.undo()
        check(diff(d.state, edited) < 0.01 && d.isDirty, "revert: can be undone")
        check(!FileVersions.canRevert(makeDoc("never saved")), "revert: unavailable without a file")
        HistoryTree.shared.forget(d.id)
    }

    // MARK: 7. History → action, repeat, apply to many

    static func historyActions(_ out: URL) {
        let app = AppModel.shared
        let log = CommandLog.shared
        func photo(_ name: String) -> Document {
            var st = DocumentState(width: 240, height: 160)
            let b = PixelBuffer(width: 240, height: 160)
            let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "F6AE2D")!.cgColor, RGBA(hex: "2E4057")!.cgColor] as CFArray, locations: [0, 1])!
            b.context.drawLinearGradient(g, start: .zero, end: CGPoint(x: 240, y: 160), options: [])
            b.context.setFillColor(RGBA(hex: "E94F37")!.cgColor); b.context.fill(CGRect(x: 30, y: 30, width: 60, height: 50))
            b.markDirty()
            st.layers = [Layer.raster(name: "Photo", buffer: b)]
            return Document(state: st, name: name)
        }
        let d = photo("actions")
        let initial = d.state
        app.add(d)
        defer { app.close(d) }
        log.clearPending()
        var blur = FilterInstance(kind: .gaussianBlur, colors: [.black, .white]); blur.values["radius"] = 6
        AppActions.applyFilter(blur)                                   // 1
        AppActions.invertActive()                                      // 2
        AppActions.flipCanvas(horizontal: true)                        // 3
        let afterThree = d.state
        d.updateLayer(d.state.layers[0].id) { $0.opacity = 0.5 }; d.commit("Opacity Change")   // 4 (not recordable)
        AppActions.imageSize(width: 120, height: 80, resolution: 72, scaleStyles: true)         // 5
        check(d.history.map(\.name) == ["Open", "Gaussian Blur", "Invert", "Flip Canvas Horizontal", "Opacity Change", "Image Size"], "history→action: history as expected", "\(d.history.map(\.name))")

        let mapped = HistoryActions.mapRange(d, 1...5)
        if case .filter(let f)? = mapped[0].step { check(f.kind == .gaussianBlur && f.values["radius"] == 6 && mapped[0].detail == "recorded", "history→action: filter with its real settings") }
        else { check(false, "history→action: filter step mapped") }
        check(mapped[1].step == .invert, "history→action: outermost command wins for nested commands", "\(String(describing: mapped[1].step))")
        check(mapped[2].step == .flipCanvas(horizontal: true), "history→action: canvas flip")
        check(mapped[3].step == nil && !mapped[3].detail.isEmpty, "history→action: unrecordable step is reported", mapped[3].detail)
        check(mapped[4].step == .imageSize(width: 120, height: 80, resolution: 72, scaleStyles: true), "history→action: image size payload")
        let (action, skipped) = HistoryActions.makeAction(name: "From history", from: d, range: 1...5)
        check(action.steps.count == 4 && action.enabled.count == 4 && skipped.map(\.name) == ["Opacity Change"], "history→action: action built, skipped steps listed")
        let (partial, _) = HistoryActions.makeAction(name: "Partial", from: d, range: 1...5, only: [1, 3])
        check(partial.steps.count == 2, "history→action: step selection")

        // replay equivalence on a fresh copy
        var copy = initial
        copy.layers = copy.layers.map { $0.duplicated() }
        let d2 = Document(state: copy, name: "replay")
        app.add(d2)
        let (first3, _) = HistoryActions.makeAction(name: "First three", from: d, range: 1...3)
        log.clearPending()
        for s in first3.steps { ActionRecorder.perform(s) }
        check(d2.history.count == 4 && diff(d2.state, afterThree) < 0.5, "history→action: replaying the action reproduces the result", String(format: "diff %.3f", diff(d2.state, afterThree)))
        app.close(d2)
        app.activeDocumentID = d.id

        // inference without a recorded payload
        let plain = photo("infer")
        var flat = plain.state
        flat.layers.append(SelfTest.shapeLayer(CGRect(x: 10, y: 10, width: 50, height: 50)))
        check(HistoryActions.infer(name: "Flatten Image", before: flat, after: plain.state) == .flatten, "infer: parameter-less command by name")
        var withAdj = plain.state
        withAdj.layers.append(Layer(name: "Levels 1", content: .adjustment(AdjustmentSettings(kind: .levels))))
        check(HistoryActions.infer(name: "Levels 1", before: plain.state, after: withAdj) == .adjustmentLayer(.levels), "infer: new adjustment layer from the state change")
        var so0 = DocumentState(width: 240, height: 160)
        let soLayer = Layer(name: "SO", content: .smartObject(SmartObjectContent(source: .image(solid(40, 40, .red)), quad: Quad(rect: CGRect(x: 10, y: 10, width: 40, height: 40)))))
        so0.layers = [soLayer]
        var so1 = so0
        var twirl = FilterInstance(kind: .twirl, colors: [.black, .white]); twirl.values["angle"] = 77
        so1.updateLayer(soLayer.id) { l in if var s = l.smart { s.filters.append(twirl); l.smart = s } }
        if case .filter(let f)? = HistoryActions.infer(name: "Twirl", before: so0, after: so1) { check(f.values["angle"] == 77, "infer: smart filter settings from the layer") }
        else { check(false, "infer: smart filter") }
        var afterCS = plain.state
        afterCS.width += 40; afterCS.height += 20
        afterCS.layers[0].translate(dx: 0, dy: 20, document: true)      // anchor: left / bottom
        check(HistoryActions.infer(name: "Canvas Size", before: plain.state, after: afterCS) == .canvasSize(width: 280, height: 180, anchorX: 0, anchorY: 2), "infer: canvas size anchor from layer movement")
        check(HistoryActions.infer(name: "Brush", before: plain.state, after: plain.state) == nil && HistoryActions.map(d, index: 0).step == nil, "infer: strokes and the opening state are not commands")
        check(HistoryActions.infer(name: "Gaussian Blur", before: plain.state, after: plain.state) == nil, "infer: a filter without captured settings is not guessed")

        // repeat last command
        let r = photo("repeat")
        app.add(r)
        log.clearPending()
        AppActions.applyFilter(blur)
        if case .filter(let f)? = log.lastStep { check(f.kind == .gaussianBlur, "repeat: last command remembered") } else { check(false, "repeat: last command remembered") }
        let h = r.history.count
        HistoryActions.repeatLast()
        check(r.history.count == h + 1 && r.history.last?.name == "Gaussian Blur" && HistoryActions.canRepeat, "repeat: runs the command again with the same settings")
        app.close(r)

        // apply last command to many layers, one undo step
        var st = DocumentState(width: 200, height: 120)
        let l1 = Layer.raster(name: "One", buffer: solid(60, 60, RGBA(hex: "FF0000")!), origin: IPoint(x: 5, y: 5))
        let l2 = Layer.raster(name: "Two", buffer: solid(60, 60, RGBA(hex: "00FF00")!), origin: IPoint(x: 70, y: 5))
        let l3 = Layer.raster(name: "Three", buffer: solid(60, 60, RGBA(hex: "0000FF")!), origin: IPoint(x: 135, y: 5))
        var shape = SelfTest.shapeLayer(CGRect(x: 5, y: 70, width: 60, height: 40), RGBA(hex: "FFFFFF")!); shape.name = "Vector"
        st.layers = [l1, l2, l3, shape]
        let many = Document(state: st, name: "many")
        app.add(many)
        defer { app.close(many) }
        many.selectLayer(l1.id)
        log.clearPending()
        AppActions.invertActive()                  // sets the last command and inverts layer One
        many.undo()
        let beforeMany = many.state
        many.selectedLayerIDs = [l1.id, l2.id, l3.id]
        let hm = many.historyIndex
        let res = HistoryActions.applyLast(to: many.orderedSelection, in: many)
        let px: [(UInt8, UInt8, UInt8, UInt8)] = [l1, l2, l3].map { many.state.layer($0.id)?.raster?.buffer.pixel(10, 10) ?? (9, 9, 9, 9) }
        check(res.applied == 3 && res.skipped == 0 && near(px[0], (0, 255, 255, 255)) && near(px[1], (255, 0, 255, 255)) && near(px[2], (255, 255, 0, 255)),
              "apply to selected: every selected layer got the command", "\(px)")
        check(many.historyIndex == hm + 1 && many.history.count == hm + 2 && many.history.last?.name == "Invert × 3 Layers", "apply to selected: folded into one history step",
              "\(many.history.map(\.name))")
        check(many.selectedLayerIDs == [l1.id, l2.id, l3.id] && many.activeLayerID == l1.id, "apply to selected: selection restored")
        many.undo()
        check(diff(many.state, beforeMany) < 0.01, "apply to selected: one undo reverts all layers")
        many.redo()
        many.selectLayer(l2.id)
        let kind = HistoryActions.applyLast(to: many.state.allLayers.filter { HistoryActions.sameKind($0, l2) }.map(\.id), in: many)
        check(kind.applied == 3 && many.state.layer(shape.id)?.isShape == true, "apply to this kind: pixel layers only, vector layer untouched")
        let mixed = HistoryActions.applyLast(to: [l1.id, shape.id], in: many)
        check(mixed.applied == 1 && mixed.skipped == 1, "apply: layers the command can't run on are skipped (no rasterize prompt)")
        check(!HistoryActions.isPerLayer(.flatten) && HistoryActions.isPerLayer(.invert), "apply: document-wide commands are not applied per layer")
        HistoryTree.shared.forget(many.id); HistoryTree.shared.forget(d.id)
    }

    // MARK: 8. Timelapse

    static func timelapse(_ out: URL) {
        let tl = Timelapse.shared
        let saved = Workflow2Settings.shared.prefs
        defer { Workflow2Settings.shared.prefs = saved }
        Workflow2Settings.shared.prefs.timelapseMinInterval = 0
        Workflow2Settings.shared.prefs.timelapseMaxDimension = 320
        let d = makeDoc("timelapse", w: 640, h: 400)
        check(!tl.isRecording(d), "timelapse: off by default")
        tl.setRecording(d, true, sync: true)
        check(tl.isRecording(d) && tl.frames(d).count == 1 && tl.frameCounts[d.id] == 1, "timelapse: starting records the first frame")
        check(tl.folder(d).path.hasPrefix(tmp.appendingPathComponent("support/Timelapse").path), "timelapse: frames stored under the support directory")
        let id = d.state.layers[1].id
        for i in 0..<7 {
            d.updateLayer(id) { $0.translate(dx: 30, dy: Double(i % 2 == 0 ? 12 : -12)) }
            d.commit("Move \(i)")          // the commit hook captures (background queue)
        }
        tl.flush()
        var frames = tl.frames(d)
        check(frames.count == 8, "timelapse: one frame per history step", "\(frames.count)")
        if let f = frames.last.flatMap(Timelapse.loadFrame) { check(f.width == 320 && f.height == 200, "timelapse: frames are downscaled", "\(f.width)x\(f.height)") }
        tl.capture(d, force: true, sync: true)
        check(tl.frames(d).count == 8, "timelapse: no frame when nothing changed")
        Workflow2Settings.shared.prefs.timelapseMinInterval = 600
        d.updateLayer(id) { $0.opacity = 0.9 }; d.commit("Rate limited")
        tl.flush()
        check(tl.frames(d).count == 8, "timelapse: rate limit skips frames")
        Workflow2Settings.shared.prefs.timelapseMinInterval = 0

        // schedule
        var o = TimelapseExportOptions()
        o.length = .s15; o.holdFinal = 2; o.fadeOut = true
        let plan = Timelapse.schedule(frameCount: 10, options: o)
        check(plan.count == 450 + 60 && plan.first?.source == 0 && plan[449].source == 9 && plan.last?.alpha == 0 && plan[450].alpha == 1
              && zip(plan, plan.dropFirst()).allSatisfy { $0.source <= $1.source }, "timelapse: frame schedule (target length, hold, fade)")
        check(Timelapse.outputSize(for: CGSize(width: 320, height: 200), .p720) == (1152, 720) && Timelapse.outputSize(for: CGSize(width: 201, height: 301), .source) == (202, 302)
              && Timelapse.outputSize(for: CGSize(width: 300, height: 600), .p1080) == (960, 1920), "timelapse: output sizes are even and fit the box")

        // export: full length, 3 video frames per recorded frame + 1 s hold. The export captures the pending state first (9 frames).
        var full = TimelapseExportOptions()
        full.length = .full; full.holdFinal = 1; full.resolution = .source; full.codec = .h264
        let mp4 = tmp.appendingPathComponent("timelapse.mp4")
        do {
            let r = try tl.export(d, to: mp4, options: full)
            frames = tl.frames(d)
            let expected = frames.count * 3 + 30
            check(frames.count == 9 && r.frames == expected && r.width == 320 && r.height == 200, "timelapse: export plan", "\(r)")
            if let info = Timelapse.inspect(mp4) {
                check(info.frames == expected, "timelapse: MP4 frame count", "\(info.frames) vs \(expected)")
                check(abs(info.duration - Double(expected) / 30) < 0.05, "timelapse: MP4 duration", String(format: "%.3f s", info.duration))
            } else { check(false, "timelapse: exported MP4 is readable") }
            try? fm.removeItem(at: out.appendingPathComponent("w2_timelapse.mp4"))
            try? fm.copyItem(at: mp4, to: out.appendingPathComponent("w2_timelapse.mp4"))
        } catch { check(false, "timelapse: export", "\(error)") }
        var hevc = TimelapseExportOptions()
        hevc.length = .s15; hevc.holdFinal = 0; hevc.resolution = .p720; hevc.codec = .hevc
        let mp4b = tmp.appendingPathComponent("timelapse-hevc.mp4")
        do {
            let r = try Timelapse.export(frames: tl.frames(d), to: mp4b, options: hevc)
            let info = Timelapse.inspect(mp4b)
            check(r.frames == 450 && r.width == 1152 && r.height == 720 && info?.frames == 450 && abs((info?.duration ?? 0) - 15) < 0.05, "timelapse: 15 s HEVC at 720p",
                  "\(r) \(String(describing: info))")
        } catch { check(false, "timelapse: HEVC export", "\(error)") }
        check((try? Timelapse.export(frames: [], to: tmp.appendingPathComponent("none.mp4"), options: full)) == nil, "timelapse: exporting without frames fails cleanly")
        var cancelled = false
        do { _ = try Timelapse.export(frames: tl.frames(d), to: tmp.appendingPathComponent("cancel.mp4"), options: hevc) { _ in false } } catch { cancelled = true }
        check(cancelled && !fm.fileExists(atPath: tmp.appendingPathComponent("cancel.mp4").path), "timelapse: cancelling removes the partial file")

        // the recording follows the document through save / open
        let url = tmp.appendingPathComponent("timelapse.imagecrat")
        if (try? DocumentIO.saveNative(d, to: url)) != nil, let back = try? DocumentIO.load(url: url) {
            check(tl.isRecording(back) && tl.frames(back).count == frames.count && tl.key(back) == tl.key(d), "timelapse: recording continues after reopening the file")
            Workflow2Module.forget(back.id)
        } else { check(false, "timelapse: file round trip") }
        tl.setRecording(d, false)
        d.updateLayer(id) { $0.opacity = 0.2 }; d.commit("Paused")
        tl.flush()
        check(!tl.isRecording(d) && tl.frames(d).count == frames.count, "timelapse: paused recording stores nothing")
        // storage cap: thinning keeps first and last
        tl.setRecording(d, true, sync: true)
        Workflow2Settings.shared.prefs.timelapseCapMB = 0          // clamps to 1 MB
        let bytesBefore = Timelapse.bytes(tl.frames(d))
        let big = makeDoc("cap", w: 900, h: 600)
        Workflow2Settings.shared.prefs.timelapseMaxDimension = 900
        big.state.layers[0] = Layer.raster(name: "Noise", buffer: noise(900, 600))
        big.commit("Noise")
        tl.setRecording(big, true, sync: true)
        for i in 0..<5 {
            big.state.layers[0] = Layer.raster(name: "Noise", buffer: noise(900, 600, seed: UInt64(100 + i)))
            big.commit("Noise \(i)")
            tl.capture(big, force: true, sync: true)
        }
        tl.flush()
        let capFrames = tl.frames(big)
        check(capFrames.count < 6 && capFrames.count >= 2 && Timelapse.bytes(capFrames) <= 1_600_000, "timelapse: storage cap thins the recording",
              "\(capFrames.count) frames, \(Timelapse.bytes(capFrames)) bytes (\(bytesBefore))")
        tl.deleteFrames(big)
        check(tl.frames(big).isEmpty && tl.frameCounts[big.id] == 0, "timelapse: delete frames")
        // automatic recording preference
        Workflow2Settings.shared.prefs.timelapseAuto = true
        let auto = makeDoc("auto")
        auto.updateLayer(auto.state.layers[1].id) { $0.opacity = 0.5 }; auto.commit("First edit")
        tl.flush()
        check(tl.isRecording(auto) && tl.frames(auto).count >= 1, "timelapse: records automatically when the preference is on")
        Workflow2Settings.shared.prefs.timelapseAuto = false
        // orphan pruning only touches unsaved, old recordings
        Timelapse.pruneOrphans(olderThan: -1)
        check(!fm.fileExists(atPath: tl.folder(auto).path) && fm.fileExists(atPath: tl.folder(d).path), "timelapse: pruning removes never-saved recordings, keeps saved ones")
        for x in [d, big, auto] { tl.forget(x.id) }
    }

    // MARK: 9. Preflight

    static func preflight(_ out: URL) {
        var prefs = Workflow2Prefs()
        prefs.preflightLargeEmbedMB = 1
        let W = 600, H = 400
        var st = SelfTest.baseState(W, H)
        func named(_ l: Layer, _ n: String) -> Layer { var x = l; x.name = n; return x }
        func text(_ s: String, font: String, size: Double, at p: CGPoint, name: String) -> Layer {
            var t = TextContent(); t.text = s; t.fontName = font; t.fontSize = size; t.position = p; t.color = .black
            return Layer(name: name, content: .text(t))
        }
        let neon = named(SelfTest.shapeLayer(CGRect(x: 300, y: 20, width: 280, height: 160), RGBA(r: 0, g: 1, b: 0), radius: 0), "Neon")
        let logo = Layer(name: "Logo", content: .smartObject(SmartObjectContent(source: .image(solid(50, 50, RGBA(hex: "8E44AD")!)), quad: Quad(rect: CGRect(x: 20, y: 20, width: 200, height: 200)), sourceName: "logo.png")))
        var missingSO = SmartObjectContent(source: .image(solid(40, 40, .red)), quad: Quad(rect: CGRect(x: 240, y: 200, width: 40, height: 40)), sourceName: "gone.png")
        missingSO.linkedURL = tmp.appendingPathComponent("gone.png")
        let linkedMissing = Layer(name: "Gone", content: .smartObject(missingSO))
        let linkFile = tmp.appendingPathComponent("linked.png")
        try? solid(40, 40, RGBA(hex: "00AAFF")!).pngData()?.write(to: linkFile)
        var staleSO = SmartObjectContent(source: .image(solid(40, 40, .black)), quad: Quad(rect: CGRect(x: 290, y: 200, width: 40, height: 40)), sourceName: "linked.png")
        staleSO.linkedURL = linkFile; staleSO.linkedModified = Date(timeIntervalSince1970: 1000)
        let linkedStale = Layer(name: "Stale", content: .smartObject(staleSO))
        let noFont = text("Headline", font: "NoSuchFont-Regular", size: 30, at: CGPoint(x: 30, y: 240), name: "Headline")
        let tiny = text("fine print", font: "Helvetica", size: 5, at: CGPoint(x: 30, y: 290), name: "Fine print")
        let empty = Layer.raster(name: "Layer 5", width: W, height: H)
        var hiddenCard = named(SelfTest.shapeLayer(CGRect(x: 350, y: 220, width: 100, height: 60)), "Hidden Card"); hiddenCard.isVisible = false
        let stray = Layer.raster(name: "Stray", buffer: solid(80, 80, .red), origin: IPoint(x: 2000, y: 2000))
        let def1 = named(SelfTest.shapeLayer(CGRect(x: 470, y: 220, width: 50, height: 40), RGBA(hex: "444444")!), "Layer 12")
        let def2 = named(SelfTest.shapeLayer(CGRect(x: 530, y: 220, width: 50, height: 40), RGBA(hex: "555555")!), "Rectangle 3 copy 4")
        let dupBuf = solid(30, 30, RGBA(hex: "FF00AA")!)
        let dupA = Layer.raster(name: "Dup A", buffer: dupBuf, origin: IPoint(x: 350, y: 300))
        let dupB = Layer.raster(name: "Dup B", buffer: dupBuf.copy(), origin: IPoint(x: 350, y: 300))
        var masked = named(SelfTest.shapeLayer(CGRect(x: 400, y: 300, width: 60, height: 60), .white), "Masked"); masked.mask = LayerMask.hide(width: W, height: H)
        var ghost = named(SelfTest.shapeLayer(CGRect(x: 470, y: 300, width: 60, height: 60), .white), "Ghost"); ghost.opacity = 0
        var fx = named(SelfTest.shapeLayer(CGRect(x: 240, y: 260, width: 80, height: 60), RGBA(hex: "F39C12")!), "FX")
        fx.effects.dropShadow.distance = 30; fx.effects.dropShadow.enabled = false
        var offStroke = fx.effects.stroke; offStroke.size = 9; offStroke.enabled = false
        fx.effects.extraStrokes = [offStroke]
        let huge = Layer.raster(name: "Huge", buffer: solid(1600, 1200, RGBA(hex: "1B4F72")!), origin: IPoint(x: -500, y: -400))
        let embed = Layer(name: "Texture", content: .smartObject(SmartObjectContent(source: .image(noise(900, 700)), quad: Quad(rect: CGRect(x: 120, y: 330, width: 90, height: 70)), sourceName: "texture.tif")))
        st.layers.insert(huge, at: 1)      // above the background, below everything else
        st.layers += [neon, logo, linkedMissing, linkedStale, noFont, tiny, empty, hiddenCard, stray, def1, def2, dupA, dupB, masked, ghost, fx, embed]

        let rep = Preflight.scan(st, prefs: prefs, proof: ProofSettings())
        for k in PreflightKind.allCases { check(!rep.issues(k).isEmpty, "preflight: detects \(k.rawValue)") }
        func issue(_ k: PreflightKind, _ id: UUID) -> PreflightIssue? { rep.issues(k).first { $0.layerIDs.contains(id) } }
        check(issue(.smartUpscaled, logo.id)?.title.contains("400%") == true && issue(.smartUpscaled, logo.id)?.detail.contains("18 ppi") == true, "preflight: effective ppi of an upscaled smart object",
              issue(.smartUpscaled, logo.id)?.detail ?? "-")
        check(issue(.smartUpscaled, embed.id) == nil && issue(.linkedMissing, linkedMissing.id) != nil && issue(.linkedModified, linkedStale.id) != nil, "preflight: linked file states")
        check(issue(.missingFont, noFont.id)?.detail == "NoSuchFont-Regular" && issue(.missingFont, tiny.id) == nil, "preflight: missing font named")
        check(issue(.tinyText, tiny.id) != nil && issue(.tinyText, noFont.id) == nil, "preflight: text below the minimum size")
        check(issue(.emptyLayer, empty.id) != nil && issue(.offCanvas, stray.id) != nil && issue(.maskHidesAll, masked.id) != nil && issue(.zeroOpacity, ghost.id) != nil, "preflight: invisible layers by cause")
        check(rep.issues(.hiddenLayer).first?.layerIDs == [hiddenCard.id], "preflight: hidden layers")
        let namedIDs = Set(rep.issues(.defaultName).first?.layerIDs ?? [])
        check(namedIDs == [empty.id, def1.id, def2.id], "preflight: default names (Layer 12, Rectangle 3 copy 4) but not real names", "\(namedIDs.compactMap { st.layer($0)?.name })")
        check(Preflight.isDefaultName("Layer 12") && Preflight.isDefaultName("Rectangle 3 copy 4") && Preflight.isDefaultName("Hue/Saturation 2") && Preflight.isDefaultName("Logo copy")
              && !Preflight.isDefaultName("Hero") && !Preflight.isDefaultName("Background") && !Preflight.isDefaultName("Layer cake"), "preflight: default-name pattern")
        check(rep.issues(.duplicateLayer).first?.layerIDs == [dupA.id, dupB.id], "preflight: identical layers grouped")
        check(issue(.hiddenEffects, fx.id)?.detail.contains("Drop Shadow") == true && issue(.hiddenEffects, fx.id)?.detail.contains("1 extra effect") == true, "preflight: switched-off effects listed",
              issue(.hiddenEffects, fx.id)?.detail ?? "-")
        check(issue(.oversizedRaster, huge.id).map { $0.saves > 0 && $0.detail.contains("%") } == true, "preflight: pixels outside the canvas with savings")
        check(issue(.largeEmbedded, embed.id) != nil && issue(.largeEmbedded, logo.id) == nil, "preflight: large embedded smart object")
        let g1 = Preflight.outOfGamutFraction(st, proof: ProofSettings()), g0 = Preflight.outOfGamutFraction({ var s = DocumentState(width: 200, height: 120); s.layers = [Layer.raster(name: "Gray", buffer: solid(200, 120, RGBA(hex: "8A7F72")!))]; return s }(), proof: ProofSettings())
        check(g1 > 0.05 && g0 < 0.005, "preflight: out-of-gamut share for the proof profile", String(format: "%.3f / %.3f", g1, g0))
        check(rep.issues.first.map { $0.kind.severity == 2 } == true, "preflight: most serious issues first")

        // size breakdown
        check(rep.sizes.first?.layerID == embed.id && rep.sizes.map(\.bytes) == rep.sizes.map(\.bytes).sorted(by: >), "preflight: size rows sorted, biggest layer first",
              rep.sizes.prefix(3).map { "\($0.name) \($0.bytes)" }.joined(separator: ", "))
        let doc = Document(state: st, name: "health")
        let file = tmp.appendingPathComponent("health.imagecrat")
        try? DocumentIO.saveNative(doc, to: file)
        let actual = ((try? fm.attributesOfItem(atPath: file.path)[.size]) as? Int) ?? 0
        check(actual > 0 && abs(Double(rep.totalBytes - actual)) / Double(max(1, actual)) < 0.3, "preflight: size estimate close to the real file", "estimate \(rep.totalBytes) vs file \(actual)")

        // individual fixes
        func fixed(_ k: PreflightKind) -> DocumentState { var s = st; for i in rep.issues(k) { Preflight.applyFix(i, to: &s, prefs: prefs) }; return s }
        func rescan(_ s: DocumentState, _ k: PreflightKind) -> Int { Preflight.scan(s, prefs: prefs, checkGamut: false).issues(k).count }
        for k in [PreflightKind.emptyLayer, .maskHidesAll, .zeroOpacity, .offCanvas, .hiddenLayer, .hiddenEffects, .oversizedRaster] {
            let s = fixed(k)
            check(rescan(s, k) == 0 && diff(s, st) < 0.01, "preflight fix: \(k.rawValue) without changing the image", String(format: "left %d diff %.3f", rescan(s, k), diff(s, st)))
        }
        var s = fixed(.oversizedRaster)
        check(s.layer(huge.id)?.raster?.frame == IRect(x: 0, y: 0, width: W, height: H) && Preflight.encodedSize(s) < Preflight.encodedSize(st), "preflight fix: trim hidden pixels shrinks the layer")
        s = fixed(.smartUpscaled)
        check(s.layer(logo.id)?.smart.map { Preflight.smartScale($0) <= 1.001 && abs($0.quad.bounds.midX - 120) < 0.5 } == true, "preflight fix: smart object back to 100% around its centre")
        s = fixed(.linkedMissing)
        check(s.layer(linkedMissing.id)?.smart?.linkedURL == nil, "preflight fix: embed a missing link")
        s = fixed(.linkedModified)
        check(s.layer(linkedStale.id)?.smart.map { $0.linkedModified == AppActions.modificationDate(linkFile) && $0.source.size.width == 40 } == true && rescan(s, .linkedModified) == 0, "preflight fix: update a changed link")
        s = fixed(.missingFont)
        check(s.layer(noFont.id)?.text?.fontName == "Helvetica" && rescan(s, .missingFont) == 0, "preflight fix: replace a missing font")
        s = fixed(.tinyText)
        check(s.layer(tiny.id)?.text.map { Preflight.smallestTextSize($0) >= prefs.preflightMinTextPx } == true, "preflight fix: enlarge tiny text")
        s = fixed(.duplicateLayer)
        check(s.layer(dupA.id) != nil && s.layer(dupB.id) == nil, "preflight fix: duplicate copies removed, first kept")
        s = fixed(.defaultName)
        let newNames = [empty.id, def1.id, def2.id].compactMap { s.layer($0)?.name }
        check(newNames.allSatisfy { !Preflight.isDefaultName($0) } && Set(newNames).count == 3 && newNames[1] == "Rectangle 50×40", "preflight fix: content-based names through BatchRename", "\(newNames)")
        var lonely = DocumentState(width: 100, height: 100)
        lonely.layers = [Layer.raster(name: "Layer 1", width: 100, height: 100)]
        let lrep = Preflight.scan(lonely, prefs: prefs, checkGamut: false)
        var lcopy = lonely
        check(lrep.issues(.emptyLayer).count == 1 && !Preflight.applyFix(lrep.issues(.emptyLayer)[0], to: &lcopy) && lcopy.layers.count == 1, "preflight fix: never deletes the last layer")

        // Clean Up Document: one undo step
        let before = doc.state
        let h = doc.history.count
        let kinds = Set(PreflightKind.allCases.filter(\.cleanupDefault))
        let n = Preflight.cleanUp(doc, kinds: kinds, report: rep)
        let after = Preflight.scan(doc.state, prefs: prefs, checkGamut: false)
        check(n >= 5 && doc.history.count == h + 1 && doc.history.last?.name == "Clean Up Document", "clean up: applied as a single history step", "\(n) fixes")
        check(kinds.allSatisfy { after.issues($0).isEmpty } && diff(doc.state, before) < 0.01, "clean up: issues gone, image unchanged")
        check(after.totalBytes < rep.totalBytes && !after.issues(.missingFont).isEmpty, "clean up: smaller file, unselected issues untouched", "\(rep.totalBytes) → \(after.totalBytes)")
        doc.undo()
        let undone = Preflight.scan(doc.state, prefs: prefs, checkGamut: false)
        check(kinds.allSatisfy { !undone.issues($0).isEmpty } && doc.state.allLayers.count == st.allLayers.count, "clean up: one undo brings everything back")
        doc.redo()
        // convert to linked
        let linkURL = tmp.appendingPathComponent("texture.imagecrat")
        let hh = doc.history.count
        check(Preflight.convertToLinked(embed.id, in: doc, url: linkURL) && fm.fileExists(atPath: linkURL.path) && doc.state.layer(embed.id)?.smart?.linkedURL == linkURL && doc.history.count == hh + 1,
              "preflight: convert an embedded smart object to a linked file")
        check(Preflight.scan(doc.state, prefs: prefs, checkGamut: false).issues(.largeEmbedded).isEmpty, "preflight: linked object no longer counts as embedded")
        // model
        AppModel.shared.add(doc)
        let m = PreflightModel.shared.scan(doc)
        check(PreflightModel.shared.report(doc) != nil && !m.issues.isEmpty, "preflight: panel model caches the report")
        AppModel.shared.close(doc)
        PreflightModel.shared.forget(doc.id)
    }

    // MARK: UI snapshots (LUMEN_SELFTEST_UI=1)

    static func uiSnapshots(_ out: URL) {
        let app = AppModel.shared
        func snap<V: View>(_ v: V, _ name: String, _ size: CGSize) {
            ToolsSelfTest.snapView(v, name, size, out)
            print("wrote \(name)")
        }
        // document with history branches, versions and issues
        let d = makeDoc("Poster.imagecrat", w: 720, h: 460)
        app.add(d)
        defer { app.close(d); Workflow2Module.forget(d.id) }
        let card = d.state.layers[1].id
        func step(_ name: String, _ f: (inout Layer) -> Void) { d.updateLayer(card, f); d.commit(name) }
        step("Move Card") { $0.translate(dx: 40, dy: 20) }
        VersionStore.shared.save(d, name: "First layout", note: "Sent to client for review")
        step("Warm colours") { l in if var s = l.shape { s.fill = .color(RGBA(hex: "F39C12")!); l.shape = s } }
        step("Drop Shadow") { $0.effects.dropShadow.enabled = true }
        step("Opacity Change") { $0.opacity = 0.8 }
        d.undo(); d.undo(); d.undo()
        step("Cool colours") { l in if var s = l.shape { s.fill = .color(RGBA(hex: "1ABC9C")!); l.shape = s } }
        step("Stroke") { $0.effects.stroke.enabled = true; $0.effects.stroke.size = 5 }
        d.undo()
        step("Inner Glow") { $0.effects.innerGlow.enabled = true }
        var title = TextContent(); title.text = "Summer Sale"; title.fontName = "Helvetica-Bold"; title.fontSize = 54; title.position = CGPoint(x: 300, y: 60); title.color = .white
        d.addLayer(Layer(name: "Layer 12", content: .text(title)), commitName: "Add Type")
        VersionStore.shared.save(d, name: "Cool variant", note: "")
        d.addLayer(Layer.raster(name: "Layer 13", width: 720, height: 460), commitName: "New Layer")
        var ghost = SelfTest.shapeLayer(CGRect(x: 500, y: 300, width: 120, height: 90)); ghost.name = "Rectangle 3 copy 4"; ghost.opacity = 0
        d.addLayer(ghost, commitName: "Add Shape")
        d.addLayer(Layer(name: "Logo", content: .smartObject(SmartObjectContent(source: .image(solid(60, 60, RGBA(hex: "8E44AD")!)), quad: Quad(rect: CGRect(x: 40, y: 250, width: 240, height: 180)),
                                                                                  sourceName: "logo.png"))), commitName: "Place Embedded")
        d.addLayer(Layer.raster(name: "Backdrop", buffer: noise(1500, 1000), origin: IPoint(x: -400, y: -300)), commitName: "Paste")
        d.updateLayer(d.state.layers.last!.id) { $0.opacity = 0.15 }; d.commit("Opacity Change")

        // palette
        let target = MenuTarget()
        let items = PaletteIndex.build(menu: fakeMenu(target))
        let fr = PaletteFrecency(url: tmp.appendingPathComponent("frecency-ui.json"))
        for q in ["bl", "opacity 50", "1920/3", "", "lay"] {
            let m = PaletteModel(items: items, frecency: fr)
            m.query = q
            if q == "bl" { m.selection = 1 }
            snap(CommandPaletteView(model: m, staticField: true).padding(20).background(Color(white: 0.2)), "w2_ui_palette_\(q.isEmpty ? "empty" : q.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "div"))",
                 CGSize(width: 680, height: 470))
        }
        let live = PaletteModel(items: items, frecency: fr)
        live.query = "merge"
        snap(CommandPaletteView(model: live).padding(20).background(Color(white: 0.2)), "w2_ui_palette_field", CGSize(width: 680, height: 470))

        snap(HistoryTreePanel(docOverride: d), "w2_ui_history_tree", CGSize(width: 300, height: 420))
        snap(VersionsPanel(docOverride: d), "w2_ui_versions", CGSize(width: 300, height: 260))
        snap(DraggableCard { SaveVersionDialog() }, "w2_ui_save_version", CGSize(width: 400, height: 250))
        PreflightModel.shared.scan(d, force: true)
        snap(PreflightPanel(docOverride: d), "w2_ui_preflight", CGSize(width: 320, height: 640))
        snap(DraggableCard { CleanUpDialog(docOverride: d) }, "w2_ui_cleanup", CGSize(width: 460, height: 330))
        snap(DraggableCard { HistoryActionDialog(docOverride: d) }, "w2_ui_history_action", CGSize(width: 480, height: 400))
        snap(DraggableCard { CompareSourceDialog() }, "w2_ui_compare_source", CGSize(width: 400, height: 440))
        snap(VStack(alignment: .leading, spacing: 10) { Workflow2PrefsSection() }.padding(14), "w2_ui_prefs", CGSize(width: 370, height: 430))

        // recovery dialog
        var e1 = RecoveryEntry(); e1.id = "a"; e1.name = "Poster.imagecrat"; e1.originalPath = "/Users/kris/Work/Poster.imagecrat"; e1.width = 720; e1.height = 460
        e1.thumb = Workflow2Util.thumbnail(d.state, maxSide: 160).flatMap(Workflow2Util.pngData); e1.files = ["a-0001.imagecrat"]
        var e2 = RecoveryEntry(); e2.id = "b"; e2.name = "Untitled-3"; e2.width = 1920; e2.height = 1080; e2.date = Date().addingTimeInterval(-1800)
        e2.thumb = Workflow2Util.thumbnail(SelfTest.baseState(320, 180), maxSide: 160).flatMap(Workflow2Util.pngData); e2.files = ["b-0003.imagecrat"]
        let session = tmp.appendingPathComponent("fake-session")
        snap(DraggableCard { RecoveryDialog(preview: [RecoveryItem(session: session, entry: e1), RecoveryItem(session: session, entry: e2)]) }, "w2_ui_recovery", CGSize(width: 480, height: 280))

        // timelapse
        let savedPrefs = Workflow2Settings.shared.prefs
        Workflow2Settings.shared.prefs.timelapseMinInterval = 0
        Timelapse.shared.setRecording(d, true, sync: true)
        step("Nudge") { $0.translate(dx: 6, dy: 0) }; Timelapse.shared.flush(); Timelapse.shared.capture(d, force: true, sync: true)
        snap(DraggableCard { TimelapseExportDialog(docOverride: d) }, "w2_ui_timelapse_export", CGSize(width: 420, height: 330))
        snap(HStack { Text("100%").font(Theme.mono); Spacer(); Workflow2StatusChip(docOverride: d) }.padding(.horizontal, 10).background(Theme.panelHeader), "w2_ui_status_chip", CGSize(width: 260, height: 24))
        Timelapse.shared.setRecording(d, false)
        Workflow2Settings.shared.prefs = savedPrefs

        // canvas overlay: compare split + isolate pill over the rendered canvas
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 860, height: 560))
        canvas.document = d
        AppActions.canvas = canvas
        d.showRulers = false
        canvas.fitOnScreen()
        func canvasShot(_ name: String) {
            let sp = CanvasSpace(width: d.state.width, height: d.state.height)
            let img = CanvasRenderer.applyViewMode(Compositor.shared.composite(d), doc: d).cropped(to: sp.ciCanvas)
            guard let cg = RenderEngine.cgImage(img.composited(over: CIImage.color(RGBA(gray: 0.85), sp.ciCanvas)), rect: sp.ciCanvas) else { return }
            let r = canvas.docToView(d.state.canvasCGRect)
            snap(ZStack {
                Color(white: 0.16)
                Image(decorative: cg, scale: 1).resizable().frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                Workflow2CanvasOverlay()
            }, name, CGSize(width: 860, height: 560))
        }
        CompareController.shared.start(d, source: .version(VersionStore.shared.versions(d)[0].id), layout: .split)
        CompareController.shared.split = 0.45
        canvasShot("w2_ui_compare_split")
        CompareController.shared.layout = .sideBySide
        canvasShot("w2_ui_compare_side_by_side")
        CompareController.shared.layout = .onion
        canvasShot("w2_ui_compare_onion")
        CompareController.shared.exit()
        d.selectLayer(card)
        IsolateMode.shared.enter(d)
        canvasShot("w2_ui_isolate")
        IsolateMode.shared.exit()
        AppActions.canvas = nil
    }
}
