import AppKit
import SwiftUI
import ImageCratCore

/// Interface languages (App/L10n.swift, Localization/README.md):
/// - automated runs are English whatever the Mac's language list says (the other suites' string checks rely on it);
/// - the Estonian table: every extracted string (Localization/strings-en.json) and every runtime catalogue name
///   (filters, adjustments, blend modes, tools, panels, menu registry, effects, brushes…) has an entry;
/// - lookups: SwiftUI keys with format specifiers, `tr()` with interpolations, positional reordering, runtime-built
///   strings (templates), menu-only translations, user content left alone;
/// - live switching: a hosted SwiftUI view, an AppKit button and menus change language and come back exactly;
///   keyboard shortcuts stay; the real menu bar has no untranslated item;
/// - stable ids: recorded actions replay identically after a switch, the Command Palette finds “Gaussian Blur” and
///   “Gaussi hägustus”, menu ids stay English;
/// - layouts: every panel offscreen at the default and the minimum column width in Estonian (content reachable, text
///   that newly gets cut is listed), the main window and some dialogs as PNGs;
/// - pseudo-localization (`LUMEN_PSEUDO_L10N`): text on panels and menus that does not go through the localization
///   layer is listed in l10n/unlocalized.txt.
/// Views run in offscreen windows; the workspace store is temporary; nothing is written to the preferences.
/// `LUMEN_SELFTEST_ONLY=l10n Lumen --selftest <dir>`
enum L10nSelfTest {
    static func register() { FeatureModules.selfTests.append(("l10n", { run($0) })) }

    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") l10n: \(name)\(d.isEmpty ? "" : " — " + d)")
        fflush(stdout)
    }
    static func info(_ s: String) { print("info l10n: \(s)"); fflush(stdout) }

    static var l: L10n { L10n.shared }

    static func run(_ out: URL) {
        passes = 0; failures = 0
        let dir = out.appendingPathComponent("l10n")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppModel.shared
        let saved = (docs: app.documents, active: app.activeDocumentID, canvas: AppActions.canvas, dialog: app.dialog, panels: app.showPanels, secondary: app.showSecondaryPanels)
        defer {
            l.setForTesting(.en, pseudo: false)
            L10nMenus.retitle()
            app.dialog = nil
            app.documents = saved.docs; app.activeDocumentID = saved.active; AppActions.canvas = saved.canvas
            app.showPanels = saved.panels; app.showSecondaryPanels = saved.secondary
            PanelMetrics.resetProbes()
            UIFixesSelfTest.spin(0.1)
        }
        englishByDefault()
        tables()
        lookups()
        liveSwitch(dir)
        menus()
        palette()
        actions()
        WorkspaceManager.shared.withStore(MemoryWorkspaceStore()) {
            panels(dir)
            mainWindow(dir)
        }
        dialogs(dir)
        pseudo(dir)
        l.setForTesting(.en, pseudo: false)
        check(l.isEnglish && tr("Layers") == "Layers" && !l.pseudo, "back in English after the suite")
        print("l10n: \(passes) passed, \(failures) failed")
    }

    // MARK: - English for automated runs

    static func englishByDefault() {
        check(l.automated, "a self-test run is an automated run (no preferences read or written)")
        check(l.isEnglish && !l.pseudo || ProcessInfo.processInfo.environment["LUMEN_PSEUDO_L10N"] == "1",
              "self tests run in English whatever the Mac's language list says", "macOS languages \(Locale.preferredLanguages), in effect \(l.code)")
        check(tr("Layers") == "Layers" && tr("Gaussian Blur") == "Gaussian Blur", "English: tr() returns the English text")
        check(Bundle.main.localizedString(forKey: "Layers", value: nil, table: nil) == "Layers", "English: the main bundle (SwiftUI literals, NSLocalizedString) returns the English text")
        check(type(of: Bundle.main) == L10nBundle.self, "the main bundle's lookups go through L10n (installed at launch)")
        check(L10n.resolve(.system, preferred: ["et-EE", "en-US"]) == "et" && L10n.resolve(.system, preferred: ["et"]) == "et",
              "System Default: an Estonian Mac gets Estonian")
        check(L10n.resolve(.system, preferred: ["de-DE", "fr-FR"]) == "en" && L10n.resolve(.system, preferred: ["en-GB", "et-EE"]) == "en"
              && L10n.resolve(.system, preferred: ["fi-FI", "et-EE"]) == "et", "System Default: the first of English / Estonian in the macOS list, else English")
        check(L10n.resolve(.et, preferred: ["en"]) == "et" && L10n.resolve(.en, preferred: ["et"]) == "en", "an explicit choice wins over the macOS list")
    }

    // MARK: - Tables

    static var allow: (exact: Set<String>, patterns: [NSRegularExpression]) = ([], [])

    static func sourceRoot() -> URL? {
        guard let u = l.tableURL ?? L10n.loadTable("et").1 else { return nil }
        // <root>/Resources/et.lproj/Localizable.strings
        let root = u.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("Localization").path) ? root : nil
    }

    static func loadAllowlist(_ root: URL?) {
        guard let root, let text = try? String(contentsOf: root.appendingPathComponent("Localization/allowlist.txt"), encoding: .utf8) else { return }
        var exact = Set<String>(), pats: [NSRegularExpression] = []
        for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty && !line.hasPrefix("#") {
            if line.hasPrefix("re:") { if let re = try? NSRegularExpression(pattern: "^(?:" + line.dropFirst(3) + ")$") { pats.append(re) } }
            else { exact.insert(line.replacingOccurrences(of: "\\n", with: "\n")) }
        }
        allow = (exact, pats)
    }

    static func allowed(_ s: String) -> Bool {
        if allow.exact.contains(s) { return true }
        let r = NSRange(s.startIndex..., in: s)
        return allow.patterns.contains { $0.firstMatch(in: s, range: r) != nil }
    }

    /// Names the app shows from its catalogues at runtime (the extractor sees most of them as literals, this asks the
    /// running app).
    static func catalogueNames() -> [String: [String]] {
        var c: [String: [String]] = [:]
        c["filters"] = FilterKind.allCases.map(\.displayName) + FilterCategory.allCases.map(\.rawValue)
        c["adjustments"] = AdjustmentKind.allCases.map(\.displayName)
        c["blend modes"] = BlendMode.allCases.map(\.displayName)
        c["tools"] = ToolKind.allCases.map(\.displayName)
        c["panels"] = PanelRegistry.defs.map(\.title)
        var menu: [String] = []
        for it in MenuRegistry.items {
            menu.append(it.title)
            menu += it.menu.split(separator: "/").map(String.init)
            if let s = it.submenu { menu.append(s) }
        }
        c["menu registry"] = menu
        c["layer style"] = StyleSection.allCases.map(\.menuTitle) + StyleSection.allCases.map(\.rawValue) + EffectKind.allCases.map(\.displayName)
        c["brush library"] = BrushDefaults.folders + BrushDefaults.records().map(\.record.name) + ["Favorites", "Recent", "Custom"]
        c["preferences"] = RulerUnit.allCases.map(\.rawValue) + InterfaceTheme.allCases.map(\.rawValue) + BrushCursorStyle.allCases.map(\.rawValue)
            + Workflow2PrefsState.sections
        c["gradients"] = ColorGradient.presets.map(\.name)
        c["workspaces"] = Workspace.builtIn.map(\.name)
        c["color modes"] = ColorMode.allCases.map(\.rawValue)
        return c
    }

    /// An entry for the name, or for it without the ending the app adds ("Drop Shadow…", "Opacity:").
    static func hasEntry(_ n: String, _ table: [String: String]) -> Bool {
        if table[n] != nil || table[L10nFormat.normalize(n)] != nil { return true }
        for suffix in ["…", ":", " ▸"] where n.hasSuffix(suffix) { if table[String(n.dropLast(suffix.count))] != nil { return true } }
        if n.hasPrefix("✓ "), table[String(n.dropFirst(2))] != nil { return true }
        return false
    }

    static func tables() {
        let (table, url) = L10n.loadTable("et")
        check(table.count > 4000 && url != nil, "the Estonian table loads", "\(table.count) entries from \(url?.path ?? "nowhere")")
        let root = sourceRoot()
        loadAllowlist(root)
        // every catalogue name has an entry (an identical one counts: "Filter" is "Filter")
        var missing: [String] = []
        l.setForTesting(.et)
        for (group, names) in catalogueNames().sorted(by: { $0.key < $1.key }) {
            for n in Set(names) where !n.isEmpty && n.contains(where: \.isLetter) && !hasEntry(n, table) && !l.hasTranslation(n) && !allowed(n) {
                missing.append("\(group): \(n)")
            }
        }
        l.setForTesting(.en)
        check(missing.isEmpty, "every runtime catalogue name has an Estonian entry", "\(missing.count): " + missing.sorted().joined(separator: "; "))
        // the extracted strings (scripts/check_l10n.sh does the same, with the extraction)
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent("Localization/strings-en.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = obj["strings"] as? [[String: Any]] else {
            info("Localization/strings-en.json not found next to the table: the extracted-strings check is left to scripts/check_l10n.sh")
            return
        }
        let keys = list.compactMap { $0["key"] as? String }
        let untranslated = keys.filter { table[$0] == nil && !allowed($0) }
        check(keys.count > 4000 && untranslated.isEmpty, "every extracted user-facing string has an Estonian entry or is allow-listed",
              "\(keys.count) strings, \(untranslated.count) missing" + (untranslated.isEmpty ? "" : ": " + untranslated.prefix(20).joined(separator: " | ")))
        var badPlaceholders: [String] = []
        for k in keys {
            guard let v = table[k] else { continue }
            let ks = L10nFormat.specifiers(k).count, vs = L10nFormat.specifiers(v)
            let positional = vs.contains { $0.contains("$") }
            if !positional && vs.count != ks { badPlaceholders.append("\(k) → \(v)") }
            if v.contains("\\(") { badPlaceholders.append("\(k) → \(v) (Swift interpolation)") }
        }
        check(badPlaceholders.isEmpty, "translations keep the placeholders of the English", badPlaceholders.prefix(10).joined(separator: " | "))
    }

    // MARK: - Lookups

    static func lookups() {
        l.setForTesting(.et)
        defer { l.setForTesting(.en) }
        check(!l.isEnglish && l.entryCount > 4000, "switching to Estonian loads the table", "\(l.entryCount) entries")
        check(tr("Gaussian Blur") == "Gaussi hägustus" && tr("Layers") == "Kihid" && tr("Curves") == "Kõverad", "tr(): catalogue names",
              "\(tr("Gaussian Blur")), \(tr("Layers")), \(tr("Curves"))")
        check(Bundle.main.localizedString(forKey: "Layers", value: nil, table: nil) == "Kihid", "NSLocalizedString / the main bundle answer in the interface language")
        check(Bundle.main.localizedString(forKey: "Layers", value: nil, table: "InfoPlist") != "Kihid", "other tables of the bundle are not intercepted")
        // SwiftUI hands over the key with the specifiers of the interpolated values
        check(l.swiftUIString("Opacity %lld%%") == "Läbipaistmatus %lld%%", "SwiftUI keys: specifiers of the values are kept (\"Opacity %lld%%\")",
              l.swiftUIString("Opacity %lld%%"))
        check(l.swiftUIString("Assign to %@ of “%@”") == "Määra kihi „%2$@” osale: %1$@", "SwiftUI keys: a reordering translation gets positional specifiers",
              l.swiftUIString("Assign to %@ of “%@”"))
        let v = 50
        check(tr("Opacity \(v)%") == "Läbipaistmatus 50%", "tr() with an interpolation: \"Opacity %@%%\"", tr("Opacity \(v)%"))
        check(tr("Assign to \("Fill") of “\("Logo")”") == "Määra kihi „Logo” osale: Fill", "tr(): %1$@ / %2$@ reorder the values", tr("Assign to \("Fill") of “\("Logo")”"))
        check(tr("You have \(3) document\("s") with unsaved changes.") == "Salvestamata muudatustega dokumente: 3.", "tr(): an English plural ending can be left out",
              tr("You have \(3) document\("s") with unsaved changes."))
        // strings built at runtime (history step names, status messages) find their template; values that are names too
        check(tr("New Curves Layer") == "Uus kiht: Kõverad", "runtime string → template \"New %@ Layer\", the value translated too", tr("New Curves Layer"))
        check(tr("Gaussian Blur…") == "Gaussi hägustus…" && tr("Opacity:") == "Läbipaistmatus:", "endings (…, :) around a known name", "\(tr("Gaussian Blur…")) \(tr("Opacity:"))")
        check(tr("Edit", context: "menu") == "Redigeerimine" && tr("Edit") == "Muuda" && tr("Select", context: "menu") == "Valik",
              "menu-only translations (the Edit menu vs the verb)")
        check(l.english("Kihid") == "Layers" && l.english("Redigeerimine") == "Edit" && l.english("Something typed") == "Something typed",
              "reverse lookup: shown text → English key")
        check(tr("My Layer 7") == "My Layer 7" && tr("Background copy 2") == "Background copy 2", "text that is not in the table is left alone (user content)")
        check(tr("⌘K") == "⌘K" && tr("100%") == "100%", "symbols and numbers are left alone")
        check(L10nFormat.restoreSpecifiers(translation: "Kihte: %1$@", key: "%lld layer%@") == "Kihte: %1$lld", "restoreSpecifiers keeps the value's type")
    }

    // MARK: - Live switching

    struct Probe: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("Layers")
                Text(tr("Brush Tool"))
                Button("Undo") {}
                Toggle("Show Tool Tips", isOn: .constant(true))
                Text("Opacity \(42)%")
            }
            .padding(8)
        }
    }

    static func labels(_ v: NSView) -> [String] {
        FuzzAX.enable()
        // (images are left out: their labels are macOS's descriptions of SF Symbols)
        return FuzzAX.tree(v).filter { $0.role != "AXImage" }.map(\.label).filter { !$0.isEmpty }
    }

    /// Text the window shows as words: static texts, check boxes, tabs, pop-up and menu buttons (image-only buttons
    /// are labelled with macOS's descriptions of their SF Symbols, which are not the app's text).
    static func shownTexts(_ v: NSView) -> [String] {
        FuzzAX.enable()
        let roles: Set<String> = ["AXStaticText", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTab", "AXDisclosureTriangle"]
        return FuzzAX.tree(v).filter { roles.contains($0.role) }.map(\.label).filter { !$0.isEmpty }
    }

    static func liveSwitch(_ dir: URL) {
        let w = UIFixesSelfTest.host(Probe().l10nRoot(), CGSize(width: 260, height: 160))
        defer { UIFixesSelfTest.close(w) }
        // an AppKit window (as the dock's chrome and floating panels are)
        let aw = PanelSizeSelfTest.window(CGSize(width: 200, height: 60))
        let plain = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        aw.contentView = plain
        aw.orderFrontRegardless()
        defer { PanelSizeSelfTest.close(aw) }
        let button = NSButton(title: tr("Cancel"), target: nil, action: nil)
        button.frame = CGRect(x: 50, y: 10, width: 100, height: 24)
        button.toolTip = tr("Delete Layer")
        plain.addSubview(button)
        UIFixesSelfTest.spin(0.3)
        guard let v = w.contentView else { check(false, "probe window"); return }
        let en = labels(v)
        check(["Layers", "Brush Tool", "Undo", "Opacity 42%"].allSatisfy { s in en.contains { $0.contains(s) } }, "SwiftUI probe in English", en.joined(separator: " | "))
        l.setForTesting(.et)
        UIFixesSelfTest.spin(0.4)
        let et = labels(v)
        check(["Kihid", "Pintslitööriist", "Võta tagasi", "Läbipaistmatus 42%"].allSatisfy { s in et.contains { $0.contains(s) } },
              "live switch: literal Texts, tr() strings, Buttons and formatted literals re-render in Estonian", et.joined(separator: " | "))
        check(button.title == "Loobu" && button.toolTip == "Kustuta kiht", "live switch: AppKit button titles and tool tips follow", "\(button.title) / \(button.toolTip ?? "-")")
        UIFixesSelfTest.snapshot(w, "probe_et", dir)
        l.setForTesting(.en)
        UIFixesSelfTest.spin(0.4)
        let back = labels(v)
        check(["Layers", "Brush Tool", "Undo", "Opacity 42%"].allSatisfy { s in back.contains { $0.contains(s) } } && !back.contains { $0.contains("Kihid") },
              "live switch back: English again", back.joined(separator: " | "))
        check(button.title == "Cancel" && button.toolTip == "Delete Layer", "AppKit titles come back exactly", "\(button.title) / \(button.toolTip ?? "-")")
    }

    // MARK: - Menus

    static func menus() {
        // a menu built the AppKit way (as context menus are), retitled when it opens
        let m = NSMenu(title: "Edit")
        let titles = ["Undo", "Copy", "Gaussian Blur…", "✓ RGB Color", "    Lab Color", "Hide Lumen", "Something a user typed"]
        for t in titles { m.addItem(NSMenuItem(title: t, action: nil, keyEquivalent: t == "Copy" ? "c" : "")) }
        let top = NSMenu(title: "Main")
        let holder = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        holder.submenu = m
        top.addItem(holder)
        l.setForTesting(.et)
        L10nMenus.retitle(top)
        let et = m.items.map(\.title)
        check(et == ["Võta tagasi", "Kopeeri", "Gaussi hägustus…", "✓ RGB-värv", "    Lab-värv", "Peida Lumen", "Something a user typed"]
              && holder.title == "Redigeerimine", "an AppKit menu in Estonian (check marks, endings, app-name items, user text kept)", et.joined(separator: " | ") + " / " + holder.title)
        check(m.items[1].keyEquivalent == "c", "keyboard shortcuts stay")
        l.setForTesting(.en)
        L10nMenus.retitle(top)
        check(m.items.map(\.title) == titles && holder.title == "Edit", "switching back restores the exact English titles", m.items.map(\.title).joined(separator: " | "))
        check(L10nMenus.english(of: "Redigeerimine", item: nil) == "Edit" || l.isEnglish, "menu guards see the English name of a translated menu")
        l.setForTesting(.et)
        check(L10nMenus.english(of: "Redigeerimine", item: nil) == "Edit" && L10nMenus.english(of: "Filter", item: nil) == "Filter",
              "menu guards (pending edits, particle preview) see English top-level names in Estonian")

        // the real menu bar (built by SwiftUI when the app launched, if it did)
        guard let main = NSApp?.mainMenu, main.items.count > 5 else {
            l.setForTesting(.en)
            info("the menu bar is not built in this run; the real-menu checks are skipped")
            return
        }
        func shortcuts(_ menu: NSMenu) -> [String] {
            var out: [String] = []
            func walk(_ x: NSMenu) { for i in x.items where !i.isSeparatorItem { if !i.keyEquivalent.isEmpty { out.append(i.keyEquivalent + "\(i.keyEquivalentModifierMask.rawValue)") }; if let s = i.submenu { walk(s) } } }
            walk(menu)
            return out
        }
        l.setForTesting(.en)
        L10nMenus.retitle()
        let enShortcuts = shortcuts(main)
        let enTop = main.items.dropFirst().map(\.title)
        l.setForTesting(.et)
        L10nMenus.retitle()
        let docNames = Set(AppModel.shared.documents.map(\.name))
        let bad = L10nMenus.untranslated(main) { s in
            allowed(s) || docNames.contains(s) || !s.contains(where: \.isLetter) || s.hasSuffix(".png") || s.hasSuffix(".psd") || s.hasSuffix(".imagecrat")
                || s.hasPrefix("ImageCrat") || s.contains("Lumen")
        }
        check(bad.isEmpty, "the menu bar has no untranslated item in Estonian", "\(bad.count): " + bad.prefix(30).joined(separator: " | "))
        check(shortcuts(main) == enShortcuts, "the menu bar's keyboard shortcuts are the same in both languages")
        info("top-level menus: " + main.items.dropFirst().map(\.title).joined(separator: ", "))
        l.setForTesting(.en)
        L10nMenus.retitle()
        check(Array(main.items.dropFirst().map(\.title)) == Array(enTop), "the menu bar is English again after switching back", main.items.dropFirst().map(\.title).joined(separator: ", "))
    }

    // MARK: - Command Palette

    static func palette() {
        let menu = NSApp?.mainMenu.flatMap { $0.items.count > 5 ? $0 : nil }
        for lang in [AppLanguage.en, .et] {
            l.setForTesting(lang)
            L10nMenus.retitle()
            let items = PaletteIndex.build(menu: menu)
            func top(_ q: String) -> PaletteResult? { PaletteSearch.search(q, items: items, frecency: nil).first { $0.item.category != .verb && $0.item.category != .calc } }
            let a = top("Gaussian Blur"), b = top("Gaussi hägustus")
            let isBlur: (PaletteResult?) -> Bool = { r in
                guard let id = r?.item.id else { return false }
                return id == "filter:gaussianBlur" || id.hasSuffix("Gaussian Blur…")
            }
            if lang == .et {
                check(isBlur(a) && isBlur(b), "Command Palette in Estonian finds “Gaussian Blur” and “Gaussi hägustus”",
                      "\(a?.item.id ?? "nothing") / \(b?.item.id ?? "nothing") — titles \(a?.item.title ?? "") / \(b?.item.title ?? "")")
                check(b?.item.title.hasPrefix("Gaussi hägustus") == true, "the palette shows the Estonian title", b?.item.title ?? "")
                let ids = items.filter { $0.id.hasPrefix("menu:") }.map(\.id)
                check(!ids.contains { $0.contains("Redigeerimine") || $0.contains("Kihid") || $0.contains("Pilt ▸") }, "palette ids (frecency, menu paths) stay English in Estonian")
            } else {
                check(isBlur(a), "Command Palette in English finds “Gaussian Blur”", a?.item.id ?? "nothing")
            }
        }
        l.setForTesting(.en)
        L10nMenus.retitle()
    }

    // MARK: - Recorded actions

    static func actions() {
        let app = AppModel.shared
        let steps: [ActionStep] = [.invert, .filter(FilterInstance(kind: .gaussianBlur)), .duplicateLayer, .imageSizePercent(50)]
        let action = RecordedAction(name: "Vignette (selection)", steps: steps)
        func replay(_ lang: AppLanguage) -> Document {
            l.setForTesting(lang)
            var st = SelfTest.baseState(240, 160)
            st.layers.append(FuzzScenarios.painted("Paint", w: 240, h: 160))
            let d = Document(state: st, name: "l10n-actions")
            d.needsFitOnScreen = false
            d.activeLayerID = st.layers.last?.id
            app.documents = [d]; app.activeDocumentID = d.id
            for s in action.steps { ActionRecorder.perform(s) }
            UIFixesSelfTest.spin(0.05)
            return d
        }
        let en = replay(.en)
        let et = replay(.et)
        check(en.history.map(\.name) == et.history.map(\.name) && en.state.width == et.state.width && en.state.layers.count == et.state.layers.count,
              "a recorded action replays the same after switching to Estonian", "\(en.history.map(\.name)) vs \(et.history.map(\.name))")
        check(QAMeasure.diff(en.state, et.state) < 0.01, "…and gives the same pixels")
        let json = (try? JSONEncoder().encode(action)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check(!json.contains("Gaussi") && json.contains("gaussianBlur"), "recorded actions store ids, not shown names")
        check(tr(ActionStep.filter(FilterInstance(kind: .gaussianBlur)).title) == "Gaussi hägustus" && tr(action.name) == "Vinjett (valik)",
              "step titles and default action names are shown in Estonian")
        check(!et.history.map(\.name).contains { $0.contains("hägustus") }, "history step names are stored in English (shown through tr())")
        l.setForTesting(.en)
        app.documents = []; app.activeDocumentID = nil
    }

    // MARK: - Panels

    struct Clip { var panel: String; var config: String; var english: String; var shown: String }

    /// Single-line text elements whose text is wider than the room they got (SwiftUI cut it with "…" or clipped it).
    static func clipped(in host: NSView, panel: String, config: String) -> [Clip] {
        FuzzAX.enable()
        // (measured at the small panel size, 10 pt: what is reported is cut whatever size the label uses)
        let font = NSFont.systemFont(ofSize: 10)
        let line = font.ascender - font.descender + font.leading
        guard let win = host.window else { return [] }
        let hostScreen = win.convertToScreen(host.convert(host.bounds, to: nil))
        var out: [Clip] = []
        // (long texts are wrapping help text or a chart's accessibility summary, not labels)
        for n in FuzzAX.tree(host) where n.role == "AXStaticText" && !n.label.isEmpty && n.label.count <= 45 {
            guard let f = FuzzAX.frame(n.element), f.height < line * 1.7, f.width > 4 else { continue }
            guard hostScreen.insetBy(dx: -2, dy: -2).intersects(f) else { continue }
            let need = (n.label as NSString).size(withAttributes: [.font: font]).width
            if need > f.width + 3 {
                out.append(Clip(panel: panel, config: config, english: l.english(n.label), shown: n.label))
            }
        }
        return out
    }

    static func panels(_ dir: URL) {
        let ws = WorkspaceManager.shared
        let app = AppModel.shared
        app.showPanels = true; app.showSecondaryPanels = true
        let d = PanelSizeSelfTest.document()
        app.documents = [d]; app.activeDocumentID = d.id
        var all = Workspace.essentials
        for def in PanelRegistry.defs where !all.contains(def.id) { all.dockAtDefault(def.id) }
        ws.apply(all)
        let pdir = dir.appendingPathComponent("panels")
        try? FileManager.default.createDirectory(at: pdir, withIntermediateDirectories: true)
        let height = PanelSizeSelfTest.defaultDockArea.height + DockMetrics.tabBarHeight
        let configs: [(name: String, width: CGFloat)] = [("default", PanelSizeSelfTest.defaultDockArea.width), ("narrow", DockMetrics.minColumnWidth)]
        let w = PanelSizeSelfTest.window(CGSize(width: 300, height: height))
        let gv = DockGroupView(floating: false)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: height))
        root.addSubview(gv)
        w.contentView = root
        w.orderFrontRegardless()
        defer { gv.content.show(nil); PanelSizeSelfTest.close(w); ws.apply(.essentials); app.documents = []; app.activeDocumentID = nil }
        var clipsEN: [String: Set<String>] = [:]
        var report: [String] = []
        var cropped: [String] = []
        var newClips: [Clip] = []
        for lang in [AppLanguage.en, .et] {
            l.setForTesting(lang)
            for (name, width) in configs {
                let s = CGSize(width: width, height: height)
                w.setContentSize(s)
                root.frame = CGRect(origin: .zero, size: s)
                gv.frame = root.bounds
                for def in PanelRegistry.defs {
                    gv.update(DockGroup([def.id], id: "l10n"))
                    UIFixesSelfTest.spin(lang == .et ? 0.25 : 0.08)
                    gv.layoutSubtreeIfNeeded(); w.displayIfNeeded()
                    let host = ws.host(def.id)
                    let clips = clipped(in: host, panel: def.id, config: name)
                    let key = def.id + "/" + name
                    if lang == .en {
                        clipsEN[key] = Set(clips.map(\.english))
                    } else {
                        let r = PanelMetrics.measure(def.id, in: gv.content, context: "et \(name) \(Int(width))")
                        if !r.ok { cropped.append("\(def.id) (\(name)): \(r.verdict), needs \(Int(r.needed.width))×\(Int(r.needed.height)) in \(Int(r.given.width))×\(Int(r.given.height))") }
                        let fresh = clips.filter { !(clipsEN[key] ?? []).contains($0.english) }
                        newClips += fresh
                        for c in clips { report.append("\(def.id)\t\(name)\t\(fresh.contains { $0.shown == c.shown } ? "NEW" : "also in English")\t\(c.shown)\t(\(c.english))") }
                        PanelMetrics.snapshot(gv, to: pdir.appendingPathComponent("\(PanelMetrics.fileName(def.id))_\(name)_et.png"))
                    }
                }
            }
        }
        l.setForTesting(.en)
        try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("clipped.txt"), atomically: true, encoding: .utf8)
        check(cropped.isEmpty, "Estonian: every panel's content fits or scrolls at the default and the minimum column width (\(PanelRegistry.defs.count) panels)",
              cropped.joined(separator: "; "))
        let atDefault = newClips.filter { $0.config == "default" }
        check(atDefault.isEmpty, "Estonian: no text is cut at the default column width that English shows whole",
              atDefault.prefix(25).map { "\($0.panel): “\($0.shown)”" }.joined(separator: "; ") + (atDefault.count > 25 ? " … (\(atDefault.count))" : ""))
        let narrow = newClips.filter { $0.config == "narrow" }
        info("narrow column (\(Int(DockMetrics.minColumnWidth)) pt): \(narrow.count) Estonian labels cut that English shows whole (l10n/clipped.txt)"
             + (narrow.isEmpty ? "" : ": " + narrow.prefix(12).map { "\($0.panel): “\($0.shown)”" }.joined(separator: "; ")))
    }

    // MARK: - Main window and dialogs

    static func mainWindow(_ dir: URL) {
        let app = AppModel.shared
        let d = PanelSizeSelfTest.document()
        app.documents = [d]; app.activeDocumentID = d.id
        defer { app.documents = []; app.activeDocumentID = nil }
        WorkspaceManager.shared.apply(.essentials)
        for lang in [AppLanguage.et, .en] {
            l.setForTesting(lang)
            guard let (w, _, _) = PanelSizeSelfTest.mainWindow(CGSize(width: 1440, height: 900)) else { continue }
            UIFixesSelfTest.spin(0.4)
            if let v = w.contentView { PanelMetrics.capture(v, to: dir.appendingPathComponent("main_\(lang.rawValue).png")) }
            if lang == .et, let v = w.contentView {
                let shown = labels(v)
                check(shown.contains { $0 == "Kihid" } || shown.contains { $0.contains("Kihid") }, "main window in Estonian shows the Layers panel as “Kihid”",
                      shown.prefix(40).joined(separator: " | "))
            }
            PanelSizeSelfTest.close(w)
        }
        l.setForTesting(.en)
    }

    static func dialogs(_ dir: URL) {
        let app = AppModel.shared
        var st = SelfTest.baseState(800, 600)
        st.layers.append(SelfTest.shapeLayer(CGRect(x: 100, y: 100, width: 300, height: 200)))
        let d = Document(state: st, name: "l10n-dialogs")
        d.needsFitOnScreen = false
        d.activeLayerID = st.layers.last?.id
        app.documents = [d]; app.activeDocumentID = d.id
        defer { app.documents = []; app.activeDocumentID = nil; app.dialog = nil }
        l.setForTesting(.et)
        Workflow2PrefsState.pendingSection = "General"   // (another suite may have left a section to open)
        let shots: [(String, AnyView, CGSize)] = [
            ("dialog_preferences", AnyView(PreferencesDialog()), CGSize(width: 560, height: 420)),
            ("dialog_newdocument", AnyView(NewDocumentDialog()), CGSize(width: 520, height: 440)),
            ("dialog_imagesize", AnyView(ImageSizeDialog()), CGSize(width: 460, height: 360)),
            ("dialog_layerstyle", AnyView(LayerStyleDialog(layerID: d.activeLayerID ?? UUID())), CGSize(width: 820, height: 600)),
        ]
        for (name, view, size) in shots {
            let w = UIFixesSelfTest.host(view.l10nRoot(), size)
            UIFixesSelfTest.spin(0.3)
            UIFixesSelfTest.snapshot(w, name + "_et", dir)
            if name == "dialog_preferences", let v = w.contentView {
                let shown = labels(v)
                check(shown.contains("Eelistused") && shown.contains { $0.contains("Keel") }, "Preferences in Estonian, with the Language picker", shown.prefix(30).joined(separator: " | "))
            }
            UIFixesSelfTest.close(w)
        }
        l.setForTesting(.en)
    }

    // MARK: - Pseudo-localization

    static func pseudo(_ dir: URL) {
        let ws = WorkspaceManager.shared
        let app = AppModel.shared
        let d = PanelSizeSelfTest.document()
        app.documents = [d]; app.activeDocumentID = d.id
        // user content in the probe document (layer and document names) is not interface text
        var content = Set(d.state.allLayers.map(\.name) + [d.name])
        content.formUnion(["Background", "Paint", "Shape", "Panel sizes"])
        l.setForTesting(.en, pseudo: true)
        check(tr("Layers").hasPrefix(L10nPseudo.open) && tr("Layers").count > "Layers".count && tr("Opacity \(5)%").contains("5%"),
              "pseudo-localization wraps, accents and lengthens strings and keeps values", "\(tr("Layers")) \(tr("Opacity \(5)%"))")
        var found: [String] = []
        WorkspaceManager.shared.withStore(MemoryWorkspaceStore()) {
            var all = Workspace.essentials
            for def in PanelRegistry.defs where !all.contains(def.id) { all.dockAtDefault(def.id) }
            ws.apply(all)
            let height = PanelSizeSelfTest.defaultDockArea.height + DockMetrics.tabBarHeight
            let w = PanelSizeSelfTest.window(CGSize(width: 300, height: height))
            let gv = DockGroupView(floating: false)
            let root = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: height))
            root.addSubview(gv)
            gv.frame = root.bounds
            w.contentView = root
            w.orderFrontRegardless()
            for def in PanelRegistry.defs {
                gv.update(DockGroup([def.id], id: "l10n-pseudo"))
                UIFixesSelfTest.spin(0.06)
                for s in shownTexts(ws.host(def.id)) where isUnlocalized(s, content) { found.append("panel \(def.id)\t\(s)") }
            }
            gv.content.show(nil)
            PanelSizeSelfTest.close(w)
            ws.apply(.essentials)
            if let (mw, _, _) = PanelSizeSelfTest.mainWindow(CGSize(width: 1440, height: 900)) {
                UIFixesSelfTest.spin(0.3)
                if let v = mw.contentView {
                    for s in shownTexts(v) where isUnlocalized(s, content) { found.append("main window\t\(s)") }
                    PanelMetrics.capture(v, to: dir.appendingPathComponent("main_pseudo.png"))
                }
                PanelSizeSelfTest.close(mw)
            }
        }
        if let main = NSApp?.mainMenu, main.items.count > 5 {
            L10nMenus.retitle()
            for s in L10nMenus.untranslated(main, allow: { isUnlocalized($0, content) == false || allowed($0) }) { found.append("menu\t\(s)") }
        }
        let unique = Array(Set(found)).sorted()
        try? (["# Text shown without going through the localization layer (LUMEN_PSEUDO_L10N run of the l10n self test).",
               "# Each line: where, the text. User content (layer / document names), numbers and allow-listed names are left out."] + unique)
            .joined(separator: "\n").write(to: dir.appendingPathComponent("unlocalized.txt"), atomically: true, encoding: .utf8)
        info("pseudo-localization: \(unique.count) unlocalized texts on panels, the main window and menus (l10n/unlocalized.txt)"
             + (unique.isEmpty ? "" : ": " + unique.prefix(25).joined(separator: " | ")))
        check(true, "pseudo-localization report written (\(unique.count) entries)")
        l.setForTesting(.en, pseudo: false)
        app.documents = []; app.activeDocumentID = nil
    }

    /// macOS's accessibility descriptions of the SF Symbols the app uses ("Bin" for trash): image buttons get them
    /// as labels; they are not text the app shows.
    static let symbolDescriptions: Set<String> = {
        guard let root = sourceRoot() else { return [] }
        var names = Set<String>()
        let re = try! NSRegularExpression(pattern: #"(?:systemName|systemImage|symbol|systemSymbolName)\s*:\s*"([a-z0-9.]+)""#)
        if let e = FileManager.default.enumerator(at: root.appendingPathComponent("Sources/Lumen"), includingPropertiesForKeys: nil) {
            for case let u as URL in e where u.pathExtension == "swift" {
                guard let t = try? String(contentsOf: u, encoding: .utf8) else { continue }
                for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) { if let r = Range(m.range(at: 1), in: t) { names.insert(String(t[r])) } }
            }
        }
        var out = Set<String>()
        for n in names { if let d = NSImage(systemSymbolName: n, accessibilityDescription: nil)?.accessibilityDescription, !d.isEmpty { out.insert(d) } }
        return out
    }()

    /// Visible text that did not go through tr() / the bundle hook in a pseudo-localized run.
    static func isUnlocalized(_ s: String, _ content: Set<String>) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.contains(where: \.isLetter), !L10nPseudo.isPseudo(t) else { return false }
        if content.contains(t) || allowed(t) || symbolDescriptions.contains(t) { return false }
        if t.range(of: #"^[a-z0-9]+(\.[a-z0-9]+)+$"#, options: .regularExpression) != nil { return false }   // a symbol's name
        if t.range(of: #"^\d{1,2}:\d{2}( ?[ap]m)?$"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }   // times
        if t.count <= 2 { return false }                                        // W, H, fx, px
        if t.range(of: #"^[\d\s.,:%×x°#‰+\-–/()]*(px|pt|ppi|cm|mm|in|MB|GB|KB|fps|s|ms)?$"#, options: .regularExpression) != nil { return false }
        if t.hasPrefix("#") || t.range(of: #"^[0-9A-F]{6}$"#, options: .regularExpression) != nil { return false }
        return true
    }
}
