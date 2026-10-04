import AppKit
import JavaScriptCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import ImageCratCore

/// The Lumen → ImageCrat rename: nothing user-visible says "Lumen" any more (menus, dialogs, status and error messages,
/// file metadata, Info.plist from scripts/build_app.sh, every string literal in the app's sources), the document types
/// (`.imagecrat` saved and reopened, `.lumen` still opened and saved in place), the other legacy extensions, the first-
/// launch migration (support folder move / merge / idempotency / interruption, preferences, Keychain), crash-report
/// names and the icons. Everything runs in temporary folders, temporary defaults suites and test Keychain services; the
/// real support folder, preferences and Keychain items are never read or written.
/// `LUMEN_SELFTEST_ONLY=rename Lumen --selftest <dir>`
enum RenameSelfTest {
    static func register() { FeatureModules.selfTests.append(("rename", { run($0) })) }

    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") rename: \(name)\(d.isEmpty ? "" : " — " + d)")
        fflush(stdout)
    }
    static func info(_ s: String) { print("INFO rename: \(s)"); fflush(stdout) }
    static func mentionsLumen(_ s: String) -> Bool { s.range(of: "lumen", options: .caseInsensitive) != nil }

    static let fm = FileManager.default
    /// The repository (for scripts/build_app.sh, Resources and Sources): this file is Sources/Lumen/App/RenameSelfTest.swift.
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func run(_ out: URL) {
        passes = 0; failures = 0
        let dir = out.appendingPathComponent("rename")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = fm.temporaryDirectory.appendingPathComponent("imagecrat-rename-\(UUID().uuidString.prefix(8))")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        identity()
        sourceLiterals()
        menusAndPalette()
        dialogs(dir)
        messagesAndMetadata(tmp)
        infoPlist()
        icons()
        documentTypes(tmp)
        saveAndReopen(tmp)
        legacyExtensions(tmp)
        crashReports(tmp)
        supportFolderMigration(tmp)
        preferencesMigration(tmp)
        keychainMigration()
        print("rename: \(passes) passed, \(failures) failed")
    }

    // MARK: - Identity

    static func identity() {
        check(Brand.name == "ImageCrat" && Brand.bundleIdentifier == "app.imagecrat.editor" && Brand.executableName == "ImageCrat",
              "name ImageCrat, bundle id app.imagecrat.editor, executable ImageCrat")
        check(Brand.realSupportFolder.path.hasSuffix("Library/Application Support/ImageCrat") && !Brand.supportFolder.path.contains("Application Support") && Brand.keychainService == "app.imagecrat.editor.apikeys"
              && GenAIKeychain.defaultService == Brand.keychainService, "support folder Application Support/ImageCrat, Keychain service app.imagecrat.editor.apikeys")
        check(DiagLog(directory: URL(fileURLWithPath: "/nonexistent-imagecrat")).fileURL?.lastPathComponent == "ImageCrat.log"
              && (DiagLog.defaultDirectory == nil || ProcessInfo.processInfo.environment["LUMEN_SUPPORT_DIR"] != nil),   // (a test support folder gets its own Logs)
              "log file ImageCrat.log (automated runs keep it in memory)")
        check(Brand.documentExtension == "imagecrat" && Brand.documentTypeIdentifier == "app.imagecrat.document" && Brand.documentTypeName == "ImageCrat Document",
              "documents: .imagecrat, app.imagecrat.document, “ImageCrat Document”")
        check([Brand.recipeExtension, Brand.libraryExtension, Brand.actionsExtension] == ["icrecipe", "iclib", "icactions"]
              && Brand.recipeExtensions.contains("lumenrecipe") && Brand.libraryExtensions.contains("lumenlib") && Brand.actionsExtensions.contains("lumenactions"),
              "other files: .icrecipe / .iclib / .icactions, the .lumen… forms still read")
        check(!LegacyMigration.allowedInThisProcess, "the first-launch migration never runs in an automated process")
    }

    // MARK: - Every string literal in the app's sources

    /// Literals that keep the internal name: never shown to a user (keys, labels, kernels, environment variables), or
    /// about the old name on purpose. Anything else containing "lumen" fails.
    static let internalPatterns: [(String, String)] = [
        (#"^LUMEN_[A-Z0-9_]*$"#, "test / debug environment variables"),
        (#"^Lumen\.[A-Za-z0-9.]+(\\\(.*\))?$"#, "UserDefaults keys, window autosave names, Metal labels"),
        (#"^lumen\.[A-Za-z0-9.]+:?$"#, "dispatch-queue labels, accessibility ids, stored markers"),
        (#"^app\.lumen\.[A-Za-z0-9.-]+$"#, "queue labels, pasteboard types, defaults keys"),
        (#"^Lumen[A-Z][A-Za-z0-9]*(\.[A-Za-z0-9.]+|-)?$"#, "identifier-style keys and notification names"),
        (#"^lumen-(clip|component|library-component):$"#, "drag-and-drop payload prefixes"),
        (#"^lumen-(webp|estimate|style|droplet|workflow2|selftest-support)[-.]"#, "temporary file names"),
        (#"^__lumenCall$"#, "the scripting bridge's private function"),
        (#"lumen[A-Z][A-Za-z0-9]*\s*\("#, "Core Image / Metal kernel source"),
        (#"^lumen[A-Z][A-Za-z0-9]*$"#, "Metal function names"),
        (#"lumen_mesh_(vs|fs)"#, "Metal function names"),
        (#"_lumen\.png$"#, "debug dump file (environment-gated)"),
    ]
    /// One-off literals, by file.
    static let allowedLiterals: [String: Set<String>] = [
        "ModelPack.swift": ["lumen-model.json", "lumen-models-pack"],          // read from packs made before the rename
        "ScriptingUI.swift": ["lumen", "window.lumen = window.imagecrat;"],    // plugin bridge alias for older panels
        "RenderEngine.swift": ["Lumen"],                                        // Core Image context debug name (Instruments only)
    ]
    /// Files that are about the old name by design.
    static let legacyFiles: Set<String> = ["Brand.swift", "LegacyMigration.swift", "RenameSelfTest.swift"]

    static func sourceLiterals() {
        let src = repoRoot.appendingPathComponent("Sources/Lumen")
        guard let e = fm.enumerator(at: src, includingPropertiesForKeys: nil) else { check(false, "the app's sources are readable", src.path); return }
        var files = 0, literals = 0, internalCount: [String: Int] = [:], bad: [String] = []
        for case let u as URL in e where u.pathExtension == "swift" {
            let name = u.lastPathComponent
            // self tests, QA automation and test corpora hold test data, not UI
            if name.contains("SelfTest") || name.contains("Corpus") || u.path.contains("/QA/") || legacyFiles.contains(name) { continue }
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
            files += 1
            for (line, lit) in stringLiterals(text) where mentionsLumen(lit) {
                literals += 1
                let t = lit.trimmingCharacters(in: .whitespaces)
                if allowedLiterals[name]?.contains(t) == true { internalCount["one-off (\(name))", default: 0] += 1; continue }
                if let p = internalPatterns.first(where: { t.range(of: $0.0, options: .regularExpression) != nil }) { internalCount[p.1, default: 0] += 1; continue }
                bad.append("\(u.path.replacingOccurrences(of: src.path + "/", with: "")):\(line): \(t.prefix(90))")
            }
        }
        check(files > 150, "scanned the app's Swift sources", "\(files) files")
        check(bad.isEmpty, "no string literal in the app's sources says “Lumen” (except internal keys and legacy handling)",
              bad.prefix(12).joined(separator: " | ") + (bad.count > 12 ? " | … \(bad.count) in all" : ""))
        info("\(literals) literals with the internal name kept: " + internalCount.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "; "))
    }

    /// (line, contents) of every string literal, multi-line and raw strings included; comments are skipped.
    static func stringLiterals(_ s: String) -> [(Int, String)] {
        let c = Array(s.unicodeScalars)
        var out: [(Int, String)] = []
        var i = 0, line = 1
        func at(_ k: Int) -> Unicode.Scalar? { k < c.count ? c[k] : nil }
        func starts(_ k: Int, _ p: String) -> Bool {
            let ps = Array(p.unicodeScalars)
            guard k + ps.count <= c.count else { return false }
            for j in 0..<ps.count where c[k + j] != ps[j] { return false }
            return true
        }
        while i < c.count {
            let ch = c[i]
            if ch == "\n" { line += 1; i += 1; continue }
            if starts(i, "//") { while i < c.count && c[i] != "\n" { i += 1 }; continue }
            if starts(i, "/*") {
                i += 2
                while i < c.count && !starts(i, "*/") { if c[i] == "\n" { line += 1 }; i += 1 }
                i += 2; continue
            }
            // raw / multi-line / plain string
            var hashes = 0
            while at(i + hashes) == "#" { hashes += 1 }
            if at(i + hashes) == "\"" {
                let hashStr = String(repeating: "#", count: hashes)
                if starts(i + hashes, "\"\"\"") {
                    var k = i + hashes + 3
                    let end = "\"\"\"" + hashStr
                    var buf = "", startLine = line
                    while k < c.count && !starts(k, end) {
                        if c[k] == "\n" {
                            if !buf.isEmpty { out.append((startLine, buf)) }
                            buf = ""; line += 1; startLine = line
                        } else { buf.unicodeScalars.append(c[k]) }
                        k += 1
                    }
                    if !buf.isEmpty { out.append((startLine, buf)) }
                    i = k + end.unicodeScalars.count
                    continue
                }
                var k = i + hashes + 1
                var buf = ""
                let close = "\"" + hashStr
                while k < c.count {
                    if hashes == 0 && c[k] == "\\" {
                        if at(k + 1) == "(" {
                            // interpolation: skip to the matching parenthesis (nested strings included)
                            var depth = 0
                            k += 1
                            while k < c.count {
                                if c[k] == "(" { depth += 1 } else if c[k] == ")" { depth -= 1; if depth == 0 { break } } else if c[k] == "\"" {
                                    k += 1
                                    while k < c.count && c[k] != "\"" { if c[k] == "\\" { k += 1 }; k += 1 }
                                }
                                k += 1
                            }
                            buf += "\\(…)"; k += 1; continue
                        }
                        if let n = at(k + 1) { buf.unicodeScalars.append(n) }
                        k += 2; continue
                    }
                    if starts(k, close) { break }
                    if c[k] == "\n" { break }
                    buf.unicodeScalars.append(c[k]); k += 1
                }
                out.append((line, buf))
                i = k + close.unicodeScalars.count
                continue
            }
            i += 1
        }
        return out
    }

    // MARK: - Menus, command palette, panels

    static func menusAndPalette() {
        let items = MenuRegistry.items
        let badMenus = items.filter { mentionsLumen($0.menu) || mentionsLumen($0.title) || mentionsLumen($0.submenu ?? "") }
        check(items.count > 100 && badMenus.isEmpty, "registered menu items: none mentions Lumen", "\(items.count) items" + badMenus.map { " · \($0.menu) ▸ \($0.title)" }.joined())
        let palette = PaletteIndex.registryItems()
        let badPalette = palette.filter { mentionsLumen($0.title) || mentionsLumen($0.subtitle) }
        check(!palette.isEmpty && badPalette.isEmpty, "Command Palette entries: none mentions Lumen", "\(palette.count) entries" + badPalette.map { " · \($0.title)" }.joined())
        let panels = PanelRegistry.defs.map(\.title)
        check(!panels.isEmpty && !panels.contains(where: mentionsLumen), "panel titles: none mentions Lumen", "\(panels.count) panels")
        // the application menu's title (the app's name) as the menu helpers report it
        check(PendingEdits.appMenu == "ImageCrat", "the application menu is “ImageCrat” for the pending-edit and particle-preview guards")
        if let main = NSApp?.mainMenu, main.items.count > 3 {
            var titles: [String] = []
            func walk(_ m: NSMenu) { for it in m.items { titles.append(it.title); if let s = it.submenu { walk(s) } } }
            walk(main)
            // AppKit names "Hide …" / "Quit …" and the application menu after the process: "ImageCrat" in the app bundle,
            // the SwiftPM product name ("Lumen") in a bare `swift build` binary like this one
            let process = ProcessInfo.processInfo.processName
            let fromProcess = Set([process, "Hide \(process)", "Quit \(process)", "Services"])
            let leaks = titles.filter { mentionsLumen($0) && (process == Brand.executableName || !fromProcess.contains($0)) }
            check(!titles.isEmpty && leaks.isEmpty, "the real menu bar: no item mentions Lumen (AppKit's process-name items aside in a bare binary)",
                  "\(titles.count) items" + leaks.prefix(8).map { " · \($0)" }.joined())
            check(titles.contains("About ImageCrat"), "the application menu has “About ImageCrat”")
            let aside = titles.filter { mentionsLumen($0) && !leaks.contains($0) }
            if !aside.isEmpty { info("AppKit items named after this bare binary's process (“\(process)”; “ImageCrat” in the app): " + aside.joined(separator: ", ")) }
        } else {
            info("the menu bar is not built in a headless run; menu titles were checked in the registry and the sources")
        }
    }

    // MARK: - Dialogs (offscreen windows)

    static func axTexts<V: View>(_ v: V, _ size: CGSize, _ name: String, _ dir: URL) -> [String] {
        let w = UIFixesSelfTest.host(v, size)
        defer { UIFixesSelfTest.close(w) }
        UIFixesSelfTest.snapshot(w, name, dir)
        return UIFixesSelfTest.axTexts(w).filter { !$0.isEmpty }
    }

    static func dialogs(_ dir: URL) {
        let about = axTexts(DraggableCard { AboutDialog() }, CGSize(width: 420, height: 300), "about_panel", dir)
        check(about.contains("ImageCrat") && !about.contains(where: mentionsLumen), "About panel: “ImageCrat”, no Lumen", about.prefix(4).joined(separator: " · "))
        let welcome = axTexts(WelcomeView(), CGSize(width: 640, height: 420), "welcome_screen", dir)
        // (recent-document names from earlier suites may legitimately end in .lumen: only the screen's own text counts)
        let recentNames = Set(NSDocumentController.shared.recentDocumentURLs.flatMap { [$0.lastPathComponent, $0.deletingPathExtension().lastPathComponent] })
        let welcomeOwn = welcome.filter { t in !t.lowercased().hasSuffix(".lumen") && !recentNames.contains(where: { t.contains($0) }) }
        check(welcome.contains("ImageCrat") && !welcomeOwn.contains(where: mentionsLumen), "Welcome screen: “ImageCrat”, no Lumen",
              welcomeOwn.filter(mentionsLumen).joined(separator: " · "))
        let m = BugReportModel.shared
        let saved = (text: m.text, options: m.options, sources: m.sources)
        m.sources = BugReportSources()
        let bug = axTexts(DraggableCard { BugReportDialog() }, CGSize(width: 560, height: 640), "bug_report_dialog", dir)
        m.text = saved.text; m.options = saved.options; m.sources = saved.sources
        check(bug.contains { $0.contains("ImageCrat") } && !bug.contains(where: mentionsLumen), "Report a Bug dialog: says ImageCrat, no Lumen",
              bug.filter { $0.contains("ImageCrat") }.prefix(3).joined(separator: " · "))
        let prefs = axTexts(VStack(alignment: .leading) { ModelsPreferencesView() }.frame(width: 340, alignment: .topLeading).padding(16),
                            CGSize(width: 380, height: 420), "ai_models_preferences", dir)
        check(prefs.contains { $0.contains("Application Support/ImageCrat/Models") } && !prefs.contains(where: mentionsLumen),
              "Preferences ▸ AI Models: models folder Application Support/ImageCrat/Models")
        check(ScriptConsole.shared.lines.first?.hasPrefix("ImageCrat JavaScript console") == true, "Scripting Console greeting")
        check(PrintAccessoryController(settings: PrintSettings()).title == "ImageCrat", "print panel: the options tab is “ImageCrat”")
    }

    // MARK: - Status / error messages and file metadata

    static func messagesAndMetadata(_ tmp: URL) {
        var visible: [(String, String)] = [
            ("autosave chip", StatusChips.autosave(enabled: true, minutes: 5, onDeactivate: true).help),
            ("memory chip", StatusChips.memory(bytes: 1 << 30, documents: 2, historyStates: 9).help),
            ("AI usage chip", StatusChips.ai(today: 1, month: 2, session: 0.5, remaining: nil, level: .normal).help),
            ("bug report file name", BugReport.defaultFileName()),
            ("bug report text", BugReport.reportText(BugReportText(what: "x"), BugReportOptions(), BugReportSources(), attachments: [])),
            ("bug report summary", BugReport.summaryText(BugReportText(what: "x"), BugReportOptions(), BugReportSources())),
            ("bug report system lines", BugReportSources.liveSystem().map { "\($0.0): \($0.1)" }.joined(separator: "\n")),
            ("models pack README", ModelPack.readme(ModelPackManifest(createdBy: "\(Brand.name) 1.0 (1)", created: "today"))),
            ("fal difference note", GenBalanceService.differenceNote(billed: 2, local: 1) ?? ""),
            ("scripting context name", ScriptEngine(name: "test", interactive: false).context.name ?? ""),
            ("generative AI User-Agent", GenHTTP.session.configuration.httpAdditionalHeaders?["User-Agent"] as? String ?? ""),
            ("particle text default", ParticleSystemSettings().text),
            ("C2PA manifest", ContentCredentials.manifestJSON(title: "a.png", format: "image/png", generativeAI: true, neuralTools: ["Upscale"], newDocument: true)),
            ("plugin panel bridge", PluginPanelView.bridge),
        ]
        for spec in ModelManager.shared.specs { visible.append(("missing-model message \(spec.id)", ModelManager.shared.missingMessage(spec.id))) }
        if let r = SAM3Engine.unavailableReason { visible.append(("SAM 3.1 status", r)) }
        let bad = visible.filter { mentionsLumen($0.1) && $0.0 != "plugin panel bridge" }
        check(bad.isEmpty, "status, help and error messages, file names: no Lumen (\(visible.count) collected)", bad.map(\.0).joined(separator: ", "))
        check(visible.first { $0.0 == "bug report text" }?.1.hasPrefix("ImageCrat bug report") == true
              && visible.first { $0.0 == "generative AI User-Agent" }?.1 == "ImageCrat/1.0 (macOS)"
              && visible.first { $0.0 == "particle text default" }?.1 == "IMAGECRAT", "bug report header, User-Agent and particle text use the new name")
        let c2pa = visible.first { $0.0 == "C2PA manifest" }?.1 ?? ""
        check(c2pa.contains("\"claim_generator_info\"") && c2pa.contains("\"ImageCrat\"") && c2pa.contains("ImageCrat Generative AI"), "Content Credentials: claim generator and software agents are ImageCrat")
        // the old name stays only where it talks about Lumen on purpose
        info("legacy wording kept on purpose: “\(LegacyMigration.doneMessage)”, “\(LegacyMigration.keyNotCarriedMessage("fal.ai"))”")
        check(mentionsLumen(LegacyMigration.doneMessage) && LegacyMigration.doneMessage.contains("ImageCrat"), "the one-time note names both: “\(LegacyMigration.doneMessage)”")

        // exported files
        let st = SelfTest.baseState(120, 80)
        let html = HTMLExporter.export(st, options: HTMLExportOptions()).html
        check(html.contains("<meta name=\"generator\" content=\"ImageCrat\" />") && !mentionsLumen(html), "HTML export: generator ImageCrat")
        let pdf = tmp.appendingPathComponent("meta.pdf")
        try? PDFExport.write(st, to: pdf)
        let creator = PDFDocument(url: pdf)?.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String
        check(creator == "ImageCrat", "PDF export: Creator “ImageCrat”", creator ?? "nil")
        let dcm = tmp.appendingPathComponent("meta.dcm")
        try? DICOM.export(st, to: dcm)
        let dcmText = String(decoding: (try? Data(contentsOf: dcm)) ?? Data(), as: UTF8.self)
        check(dcmText.contains("IMAGECRAT_1") && !mentionsLumen(dcmText), "DICOM export: implementation version IMAGECRAT_1")
        let psd = tmp.appendingPathComponent("meta.psd")
        var t = TextContent(); t.text = "Title"; t.fontName = "Helvetica-Bold"; t.fontSize = 20; t.position = CGPoint(x: 10, y: 10)
        var pst = st; pst.layers.append(Layer(name: "Title", content: .text(t)))
        try? PSDWriter.write(pst, to: psd)
        let psdData = (try? Data(contentsOf: psd)) ?? Data()
        check(psdData.range(of: Data([9]) + Data("ImageCrat".utf8)) != nil && psdData.range(of: Data([5]) + Data("Lumen".utf8)) == nil,
              "PSD export: the private layer data resource is named “ImageCrat”")
    }

    // MARK: - Info.plist from scripts/build_app.sh

    static func buildScript() -> String? { try? String(contentsOf: repoRoot.appendingPathComponent("scripts/build_app.sh"), encoding: .utf8) }

    static func infoPlist() {
        guard let script = buildScript(), let start = script.range(of: "<<PLIST\n"), let end = script.range(of: "\nPLIST", range: start.upperBound..<script.endIndex) else {
            check(false, "scripts/build_app.sh has an Info.plist", repoRoot.path); return
        }
        var xml = String(script[start.upperBound..<end.lowerBound])
        func value(_ v: String) -> String? {
            script.split(separator: "\n").first { $0.hasPrefix(v + "=") }.map { String($0.dropFirst(v.count + 1).split(separator: " ").first ?? "") }
        }
        let name = value("NAME") ?? "", bid = value("BUNDLE_ID") ?? ""
        check(name == "ImageCrat" && bid == "app.imagecrat.editor", "build_app.sh: NAME=ImageCrat, BUNDLE_ID=app.imagecrat.editor")
        for (k, v) in [("$NAME", name), ("$BUNDLE_ID", bid), ("$VERSION", "1.0"), ("$BUILD", "1")] { xml = xml.replacingOccurrences(of: k, with: v) }
        guard let plist = (try? PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)) as? [String: Any] else {
            check(false, "the Info.plist in build_app.sh parses"); return
        }
        checkPlist(plist, "build_app.sh Info.plist")
        check(script.contains("APP=\"$ROOT/build/$NAME.app\"") && script.contains("\"$APP/Contents/MacOS/$NAME\"") && !script.contains("make_icon.swift")
              && script.contains("mlx-swift_Cmlx.bundle") && script.contains("sam31-swift_*.bundle"),
              "build_app.sh: build/ImageCrat.app, executable ImageCrat, no generated icon, MLX / SAM 3.1 bundle copies unchanged")
        // the app built in this tree (scripts/build_app.sh), when there is one
        let app = repoRoot.appendingPathComponent("build/ImageCrat.app")
        if let d = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
           let built = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] {
            checkPlist(built, "build/ImageCrat.app Info.plist")
            let res = app.appendingPathComponent("Contents/Resources")
            check(fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/ImageCrat").path)
                  && fm.fileExists(atPath: res.appendingPathComponent("AppIcon.icns").path) && fm.fileExists(atPath: res.appendingPathComponent("ImageCratDocument.icns").path),
                  "build/ImageCrat.app: executable ImageCrat, AppIcon.icns and ImageCratDocument.icns")
            check(fm.contentsEqual(atPath: res.appendingPathComponent("AppIcon.icns").path, andPath: repoRoot.appendingPathComponent("Resources/IconSource/ImageCrat.icns").path),
                  "build/ImageCrat.app: the app icon is the ImageCrat icon")
        } else {
            info("no build/ImageCrat.app in this tree; only the script's Info.plist was checked")
        }
    }

    static func checkPlist(_ p: [String: Any], _ what: String) {
        check(p["CFBundleName"] as? String == "ImageCrat" && p["CFBundleDisplayName"] as? String == "ImageCrat" && p["CFBundleIdentifier"] as? String == "app.imagecrat.editor"
              && p["CFBundleExecutable"] as? String == "ImageCrat" && p["CFBundleIconFile"] as? String == "AppIcon", "\(what): name, bundle id, executable, icon")
        let exported = (p["UTExportedTypeDeclarations"] as? [[String: Any]]) ?? []
        let imported = (p["UTImportedTypeDeclarations"] as? [[String: Any]]) ?? []
        let docTypes = (p["CFBundleDocumentTypes"] as? [[String: Any]]) ?? []
        func exts(_ d: [String: Any]) -> [String] { ((d["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"] as? [String]) ?? [] }
        let ic = exported.first { $0["UTTypeIdentifier"] as? String == "app.imagecrat.document" }
        check(ic.map { exts($0) == ["imagecrat"] && $0["UTTypeDescription"] as? String == "ImageCrat Document" && $0["UTTypeIconFile"] as? String == "ImageCratDocument" } == true,
              "\(what): exports app.imagecrat.document (.imagecrat, “ImageCrat Document”, document icon)")
        let legacy = imported.first { $0["UTTypeIdentifier"] as? String == "app.lumen.document" }
        check(legacy.map { exts($0) == ["lumen"] } == true && !exported.contains { $0["UTTypeIdentifier"] as? String == "app.lumen.document" },
              "\(what): imports (no longer exports) app.lumen.document for .lumen")
        let icDoc = docTypes.first { ($0["LSItemContentTypes"] as? [String]) == ["app.imagecrat.document"] }
        let lmDoc = docTypes.first { ($0["LSItemContentTypes"] as? [String]) == ["app.lumen.document"] }
        check(icDoc?["CFBundleTypeName"] as? String == "ImageCrat Document" && icDoc?["LSHandlerRank"] as? String == "Owner" && icDoc?["CFBundleTypeRole"] as? String == "Editor"
              && icDoc?["CFBundleTypeIconFile"] as? String == "ImageCratDocument", "\(what): ImageCrat Document — Editor, Owner, CFBundleTypeIconFile ImageCratDocument")
        check(lmDoc?["CFBundleTypeRole"] as? String == "Editor" && lmDoc?["LSHandlerRank"] as? String == "Default", "\(what): .lumen documents open (Editor, Default rank)")
        // every other value is free of the old name
        func strings(_ v: Any) -> [String] {
            switch v {
            case let s as String: return [s]
            case let a as [Any]: return a.flatMap(strings)
            case let d as [String: Any]:
                if d["UTTypeIdentifier"] as? String == "app.lumen.document" || (d["LSItemContentTypes"] as? [String]) == ["app.lumen.document"] { return [] }
                return d.values.flatMap(strings)
            default: return []
            }
        }
        let leaks = strings(p).filter(mentionsLumen)
        check(leaks.isEmpty, "\(what): no value mentions Lumen outside the legacy .lumen declarations", leaks.joined(separator: ", "))
    }

    // MARK: - Icons

    static func icons() {
        let res = repoRoot.appendingPathComponent("Resources")
        check(fm.contentsEqual(atPath: res.appendingPathComponent("AppIcon.icns").path, andPath: res.appendingPathComponent("IconSource/ImageCrat.icns").path),
              "Resources/AppIcon.icns is the ImageCrat icon (IconSource/ImageCrat.icns)")
        let doc = res.appendingPathComponent("ImageCratDocument.icns")
        let sizes = Set((NSImage(contentsOf: doc)?.representations ?? []).map(\.pixelsWide))
        check([16, 32, 64, 128, 256, 512, 1024].allSatisfy(sizes.contains), "document icon Resources/ImageCratDocument.icns at every size",
              sizes.sorted().map(String.init).joined(separator: ", "))
        check(fm.fileExists(atPath: repoRoot.appendingPathComponent("scripts/make_document_icon.py").path) && buildScript()?.contains("ImageCratDocument.icns") == true,
              "the build copies (and can regenerate) the document icon")
    }

    // MARK: - Document types

    static func documentTypes(_ tmp: URL) {
        func exts(_ types: [UTType]) -> Set<String> { Set(types.flatMap { $0.tags[.filenameExtension] ?? [] }) }
        check(Brand.documentType.preferredFilenameExtension == "imagecrat" && Brand.legacyDocumentType.preferredFilenameExtension == "lumen", "UTTypes for .imagecrat and .lumen")
        let open = exts(AppActions.openTypes)
        check(open.contains("imagecrat") && open.contains("lumen") && AppActions.openTypes.first == Brand.documentType, "File ▸ Open accepts .imagecrat (first) and .lumen")
        check(Brand.isNativeDocument(URL(fileURLWithPath: "/x/a.IMAGECRAT")) && Brand.isNativeDocument(URL(fileURLWithPath: "/x/a.lumen")) && !Brand.isNativeDocument(URL(fileURLWithPath: "/x/a.psd")),
              "native documents: .imagecrat and .lumen (any case)")
        check(BatchRunner.imageExts.isSuperset(of: ["imagecrat", "lumen"]), "Batch picks up .imagecrat and .lumen files")
        // Save As… proposes .imagecrat
        let d = Document(state: SelfTest.baseState(60, 40), name: "Poster.lumen")
        withActive(d) {
            let dir = tmp.appendingPathComponent("saveas")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            Automation.saveDir = dir
            defer { Automation.saveDir = nil }
            Automation.reset()
            Automation.withHeadless(.ok) { AppActions.saveAs() }
            UIFixesSelfTest.spin(0.2)     // the panel's completion runs on the next main-queue turn
            let req = Automation.requests.last { $0.kind == "savePanel" }
            check(req?.detail.contains("Poster.imagecrat") == true && req?.detail.contains("imagecrat") == true && !(req?.detail.contains(",lumen") ?? true),
                  "Save As… proposes “Poster.imagecrat” (ImageCrat Document first; .lumen is not offered)", req?.detail ?? "no panel")
            check(d.fileURL?.pathExtension == "imagecrat" && fm.fileExists(atPath: d.fileURL?.path ?? "") && !d.isDirty, "Save As… wrote an .imagecrat file", d.fileURL?.lastPathComponent ?? "nil")
        }
    }

    static func withActive(_ d: Document, _ body: () -> Void) {
        let app = AppModel.shared
        let prevDocs = app.documents, prevActive = app.activeDocumentID, prevCanvas = AppActions.canvas
        AppActions.canvas = nil
        app.documents.append(d); app.activeDocumentID = d.id
        body()
        app.documents = prevDocs.filter { p in app.documents.contains { $0 === p } }
        app.activeDocumentID = prevActive
        AppActions.canvas = prevCanvas
    }

    static func richState() -> DocumentState {
        var st = SelfTest.baseState(240, 160)
        st.layers.append(SelfTest.shapeLayer(CGRect(x: 30, y: 30, width: 100, height: 60)))
        var t = TextContent(); t.text = "ImageCrat"; t.fontName = "Helvetica-Bold"; t.fontSize = 24; t.color = .white; t.position = CGPoint(x: 20, y: 100)
        var tl = Layer(name: "Title", content: .text(t)); tl.effects.dropShadow.enabled = true
        st.layers.append(tl)
        return st
    }

    // MARK: - Save as .imagecrat and reopen; .lumen opens and saves in place

    static func saveAndReopen(_ tmp: URL) {
        let st = richState()
        let url = tmp.appendingPathComponent("Poster.imagecrat")
        let d = Document(state: st, name: "Poster.imagecrat")
        do {
            try DocumentIO.saveNative(d, to: url)
            let back = try DocumentIO.load(url: url)
            check(back.state.layers.map(\.name) == st.layers.map(\.name) && RegressionTests.diff(back.state, st) < 0.01 && back.fileURL == url,
                  ".imagecrat: saved and reopened identically (layers, composite)")
        } catch { check(false, ".imagecrat round trip", "\(error)") }
        // File ▸ Save on an .imagecrat file writes in place, no panel
        if let doc = try? DocumentIO.load(url: url) {
            withActive(doc) {
                doc.state.layers.append(SelfTest.shapeLayer(CGRect(x: 150, y: 20, width: 40, height: 40), RGBA(hex: "27AE60")!)); doc.commit("Add")
                Automation.reset()
                Automation.withHeadless(.cancel) { AppActions.save() }
                let again = try? DocumentIO.load(url: url)
                check(!doc.isDirty && Automation.requests.isEmpty && again?.state.layers.count == st.layers.count + 1, "File ▸ Save on an .imagecrat file saves in place")
            }
        }
        // a document saved by Lumen (same LumenFile format, .lumen extension)
        let legacy = tmp.appendingPathComponent("Old Poster.lumen")
        let enc = PropertyListEncoder(); enc.outputFormat = .binary
        try? enc.encode(LumenFile(name: "Old Poster.lumen", state: st)).write(to: legacy)
        guard let old = try? DocumentIO.load(url: legacy) else { check(false, ".lumen opens"); return }
        check(old.state.layers.map(\.name) == st.layers.map(\.name) && RegressionTests.diff(old.state, st) < 0.01 && old.fileURL == legacy, ".lumen (saved by Lumen) opens")
        let before = AppModel.shared.documents.count
        AppActions.open(url: legacy)
        if let opened = AppModel.shared.documents.last, AppModel.shared.documents.count == before + 1 {
            check(opened.fileURL == legacy, "File ▸ Open of a .lumen file adds the document")
            AppModel.shared.close(opened)
        } else { check(false, "File ▸ Open of a .lumen file adds the document") }
        withActive(old) {
            old.state.layers.removeLast(); old.commit("Delete Layer")
            Automation.reset()
            Automation.withHeadless(.cancel) { AppActions.save() }
            let again = try? DocumentIO.load(url: legacy)
            check(!old.isDirty && Automation.requests.isEmpty && again?.state.layers.count == st.layers.count - 1 && old.fileURL == legacy
                  && !fm.fileExists(atPath: tmp.appendingPathComponent("Old Poster.imagecrat").path),
                  "File ▸ Save on a .lumen file saves it in place as .lumen (no dialog, no second file)")
        }
        check(FileVersions.nextIncrementalURL(for: legacy, existing: []).lastPathComponent == "Old Poster_v002.lumen"
              && FileVersions.nextIncrementalURL(for: url, existing: []).lastPathComponent == "Poster_v002.imagecrat", "Save Incremental keeps the file's extension")
        // scripts: doc.save("….imagecrat") / ("….lumen") write the native format, not an export
        let sd = Document(state: st, name: "script")
        AppModel.shared.add(sd)
        for ext in ["imagecrat", "lumen"] {
            let p = tmp.appendingPathComponent("script.\(ext)").path
            _ = try? ScriptAPI.dispatch("doc.save", [sd.id.uuidString, p], engine: nil)
            check((try? DocumentIO.load(url: URL(fileURLWithPath: p)))?.state.layers.count == st.layers.count, "scripting: doc.save(\"….\(ext)\") writes a native document")
        }
        AppModel.shared.close(sd)
        // autosave / recovery copies are .imagecrat; a recovery copy left by Lumen (.lumen) still loads
        let root = tmp.appendingPathComponent("Recovery")
        let a = Autosave(root: root, sessionID: "rename-session", pid: 999_999)
        let ad = Document(state: st, name: "Unsaved")
        ad.state.layers.append(SelfTest.shapeLayer(CGRect(x: 5, y: 5, width: 10, height: 10))); ad.commit("x")
        a.save(ad, sync: true, force: true)
        let files = (try? fm.contentsOfDirectory(atPath: a.sessionDir.path)) ?? []
        check(files.contains { $0.hasSuffix(".imagecrat") } && !files.contains { $0.hasSuffix(".lumen") }, "autosave writes .imagecrat recovery copies", files.joined(separator: ", "))
        var e = RecoveryEntry(); e.id = "old"; e.name = "From Lumen"; e.files = ["old-0001.lumen"]
        let oldSession = root.appendingPathComponent("lumen-session")
        try? fm.createDirectory(at: oldSession, withIntermediateDirectories: true)
        try? fm.copyItem(at: legacy, to: oldSession.appendingPathComponent("old-0001.lumen"))
        let recovered = a.load(RecoveryItem(session: oldSession, entry: e))
        check(recovered?.state.layers.isEmpty == false && recovered?.name == "From Lumen", "a .lumen recovery copy from Lumen is recovered")
    }

    // MARK: - Other legacy extensions

    static func legacyExtensions(_ tmp: URL) {
        // recipes: a .lumenrecipe in the library folder is listed; importing one works; re-saving replaces it with .icrecipe
        let rdir = tmp.appendingPathComponent("Recipes")
        try? fm.createDirectory(at: rdir, withIntermediateDirectories: true)
        let g = RecipePresets.glitch.graph
        try? RecipePresetStore.data(name: "Old Glitch", graph: g).write(to: rdir.appendingPathComponent("Old Glitch.lumenrecipe"))
        let store = RecipePresetStore(directory: rdir)
        store.loadIfNeeded()
        check(store.user.map(\.name) == ["Old Glitch"], ".lumenrecipe in the recipe library is listed", store.user.map(\.name).joined(separator: ", "))
        let outside = tmp.appendingPathComponent("Shared Look.lumenrecipe")
        try? RecipePresetStore.data(name: "Shared Look", graph: g).write(to: outside)
        let imported = try? store.importFile(outside)
        check(imported?.url?.pathExtension == "icrecipe", "importing a .lumenrecipe saves it as .icrecipe", imported?.url?.lastPathComponent ?? "nil")
        _ = try? store.save(name: "Old Glitch", graph: g)
        let names = ((try? fm.contentsOfDirectory(atPath: rdir.path)) ?? []).sorted()
        check(names == ["Old Glitch.icrecipe", "Shared Look.icrecipe"] && store.user.filter { $0.name == "Old Glitch" }.count == 1,
              "re-saving an old recipe replaces its .lumenrecipe (no duplicate)", names.joined(separator: ", "))
        check(RecipePresetStore.readableExtensions == ["icrecipe", "lumenrecipe"], "Import Recipe accepts .icrecipe and .lumenrecipe")

        // component libraries: an old .lumenlib is listed, loads, and keeps being the library's file
        let lib = (try? ComponentLibraries.create(named: "Rename Kit")) ?? ComponentLibraries.url(named: "Rename Kit")
        check(lib.pathExtension == "iclib", "new libraries are .iclib files", lib.lastPathComponent)
        let oldLib = lib.deletingPathExtension().appendingPathExtension("lumenlib")
        try? fm.moveItem(at: lib, to: oldLib)
        let listed = ComponentLibraries.list().map(\.lastPathComponent)
        check(listed.contains("Rename Kit.lumenlib") && ComponentLibraries.load(oldLib) != nil && ComponentLibraries.url(named: "Rename Kit").lastPathComponent == "Rename Kit.lumenlib",
              "an old .lumenlib library is listed, opens, and is updated in place", "listed: \(listed.joined(separator: ", ")); load \(ComponentLibraries.load(oldLib) != nil)")
        try? fm.removeItem(at: oldLib)

        // actions: Import Actions… accepts an .icactions file and an old .lumenactions file
        let rec = ActionRecorder.shared
        let savedSets = rec.sets
        let fixtures = tmp.appendingPathComponent("action-fixtures")
        try? fm.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let set = ActionSet(name: "From Lumen", actions: [])
        try? JSONEncoder().encode(set).write(to: fixtures.appendingPathComponent("From Lumen.lumenactions"))
        Automation.fixtureDir = fixtures
        Automation.reset()
        Automation.withHeadless(.ok) { rec.importSet() }
        let panel = Automation.requests.last { $0.kind == "openPanel" }?.detail ?? ""
        check(rec.sets.contains { $0.name == "From Lumen" } && panel.contains("icactions") && panel.contains("lumenactions"),
              "Import Actions… offers .icactions and .lumenactions and reads an old .lumenactions file", panel)
        Automation.fixtureDir = nil
        rec.sets = savedSets
        let saveDir = tmp.appendingPathComponent("action-export")
        try? fm.createDirectory(at: saveDir, withIntermediateDirectories: true)
        Automation.saveDir = saveDir
        Automation.withHeadless(.ok) { rec.exportSet(set) }
        Automation.saveDir = nil
        let exported = (try? fm.contentsOfDirectory(atPath: saveDir.path)) ?? []
        check(exported.count == 1 && exported[0].hasSuffix("From Lumen.icactions"), "Export Actions… writes .icactions", exported.joined(separator: ", "))

        // models packs made before the rename (lumen-models-pack / lumen-model.json)
        let spec = ModelSpec(id: "rn-alpha", name: "Alpha", purpose: "test", license: "MIT", approxMB: 1,
                             files: [.init(url: URL(string: "https://example.invalid/a.bin")!, path: "a.bin")])
        let folder = tmp.appendingPathComponent("Old Pack/rn-alpha")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data([1, 2, 3]).write(to: folder.appendingPathComponent("a.bin"))
        let entry = ModelPackManifest.Model(id: "rn-alpha", name: "Alpha", version: "1", size: 3, sha256: "x", files: [.init(path: "a.bin", size: 3, sha256: "y")])
        var mf = ModelPackManifest(format: ModelPackManifest.legacyFormatName, createdBy: "Lumen 1.0 (1)", created: "2026-09-30", models: [entry])
        try? mf.encoded().write(to: folder.appendingPathComponent(ModelPackManifest.legacyModelFileName))
        mf.format = ModelPackManifest.legacyFormatName
        try? mf.encoded().write(to: folder.deletingLastPathComponent().appendingPathComponent("manifest.json"))
        let fromModel = ModelPack.sources(at: folder, specs: [spec]), fromPack = ModelPack.sources(at: folder.deletingLastPathComponent(), specs: [spec])
        let fromFile = ModelPack.sources(at: folder.appendingPathComponent("lumen-model.json"), specs: [spec])
        check(fromModel?.first?.entry?.id == "rn-alpha" && fromPack?.first?.entry?.id == "rn-alpha" && fromFile?.first?.entry?.id == "rn-alpha"
              && ModelPack.files(in: folder).map { $0.path } == ["a.bin"], "a models pack exported by Lumen is still recognised (manifest, model folder, lumen-model.json)")

        // PSDs exported by Lumen carry their private layer data under the name “Lumen”: still restored exactly
        var t = TextContent(); t.text = "Legacy"; t.fontName = "Helvetica-Bold"; t.fontSize = 30; t.position = CGPoint(x: 10, y: 20)
        var pst = SelfTest.baseState(200, 100); pst.layers.append(Layer(name: "Title", content: .text(t)))
        let psd = tmp.appendingPathComponent("from-lumen.psd")
        PSDExportLumen.resourceName = Brand.Legacy.name
        try? PSDWriter.write(pst, to: psd)
        PSDExportLumen.resourceName = Brand.name
        let psdData = (try? Data(contentsOf: psd)) ?? Data()
        let back = try? DocumentIO.load(url: psd)
        let rep = back.flatMap { PSDImportModule.report(for: $0) }
        check(psdData.range(of: Data([5]) + Data("Lumen".utf8)) != nil && back?.state.allLayers.first { $0.name == "Title" }?.text?.text == "Legacy"
              && rep?.items.contains { $0.detail.contains("restored exactly") } == true, "a PSD with Lumen's private data (old resource name) is restored exactly")

        // plugin panels: window.imagecrat, with window.lumen as an alias
        let ctx = JSContext()!
        ctx.evaluateScript("var posted = []; var window = { webkit: { messageHandlers: { imagecrat: { postMessage: function (m) { posted.push('imagecrat:' + m.method) } }, lumen: { postMessage: function (m) { posted.push('lumen:' + m.method) } } } } };")
        ctx.evaluateScript(PluginPanelView.bridge)
        ctx.evaluateScript("window.imagecrat.call('app.version'); window.lumen.call('app.foregroundColor'); window.lumen.invoke('swatches');")
        let posted = ctx.objectForKeyedSubscript("posted")?.toArray() as? [String] ?? []
        check(posted == ["imagecrat:app.version", "imagecrat:app.foregroundColor", "imagecrat:plugin.invoke"] && PluginPanelView.bridgeNames == ["imagecrat", "lumen"],
              "plugin panels: window.imagecrat is the API, window.lumen still works (same handler), the lumen message handler stays registered", posted.joined(separator: ", "))
        let sample = SampleScripts.plugins.flatMap { $0.1.map { $0.1 } }.joined()
        check(sample.contains("window.imagecrat.") && !sample.contains("window.lumen."), "the sample plugin uses window.imagecrat")
    }

    // MARK: - Crash reports

    static func crashReports(_ tmp: URL) {
        let c = tmp.appendingPathComponent("DiagnosticReports")
        try? fm.createDirectory(at: c, withIntermediateDirectories: true)
        let now = Date()
        for (n, age) in [("ImageCrat-2026-10-03-101010.ips", -10.0), ("Lumen-2026-10-01-101010.ips", -100.0), ("Photos-2026-10-03-101010.ips", -5.0), ("ImageCrat-x.crash", -1.0)] {
            let u = c.appendingPathComponent(n)
            try? "{}".write(to: u, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.modificationDate: now.addingTimeInterval(age)], ofItemAtPath: u.path)
        }
        let got = BugReport.crashReports(in: c, limit: 5).map(\.lastPathComponent)
        check(got == ["ImageCrat-2026-10-03-101010.ips", "Lumen-2026-10-01-101010.ips"] && BugReport.crashReportPrefixes == ["ImageCrat-", "Lumen-"],
              "bug reports collect ImageCrat-*.ips and, for the transition, Lumen-*.ips", got.joined(separator: ", "))
    }

    // MARK: - Migration: support folder

    static func write(_ s: String, _ u: URL, age: TimeInterval = 0) {
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? s.write(to: u, atomically: true, encoding: .utf8)
        if age != 0 { try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(age)], ofItemAtPath: u.path) }
    }
    static func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }

    /// Relative path → contents (or "<dir>") of everything under `root`.
    static func listing(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return out }
        for case let u as URL in e {
            let rel = String(u.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            out[rel] = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? "<dir>" : (read(u) ?? "<binary \((try? Data(contentsOf: u))?.count ?? 0)>")
        }
        return out
    }

    /// A Lumen support folder as a tester has it.
    static func makeLegacyFolder(_ old: URL) {
        write("weights", old.appendingPathComponent("Models/sam2.1-small/model.bin"))
        write("", old.appendingPathComponent("Models/sam2.1-small/.complete"))
        write("// my script", old.appendingPathComponent("Scripts/Mine.js"))
        write("{\"name\":\"Plug\"}", old.appendingPathComponent("Plugins/Plug/manifest.json"))
        write("{\"records\":[]}", old.appendingPathComponent("genai-usage.json"))
        write("old log line", old.appendingPathComponent("Logs/Lumen.log"))
        write("{}", old.appendingPathComponent("ParticlePresets/Mine.json"))
        write("{}", old.appendingPathComponent("Recipes/Look.lumenrecipe"))
        // a recovery manifest whose original file lives in the support folder (escaped slashes, as JSONEncoder writes them)
        let orig = old.appendingPathComponent("Scripts/poster.lumen").path.replacingOccurrences(of: "/", with: "\\/")
        write("{\"id\":\"a\",\"originalPath\":\"\(orig)\",\"files\":[\"a-0001.lumen\"]}", old.appendingPathComponent("Recovery/s1/a.json"))
        write("doc", old.appendingPathComponent("Recovery/s1/a-0001.lumen"))
        // binary data that happens to contain the old path is never edited as text
        var bin = Data([0x62, 0x6F, 0x6F, 0x6B, 0, 0, 0, 1]); bin.append(Data((old.path + "/x.png").utf8)); bin.append(Data([0, 0xFF, 0xFE]))
        try? fm.createDirectory(at: old.appendingPathComponent("Artist"), withIntermediateDirectories: true)
        try? bin.write(to: old.appendingPathComponent("Artist/bookmark.json"))
    }

    static func supportFolderMigration(_ tmp: URL) {
        // 1. only the old folder: one rename
        let a = tmp.appendingPathComponent("A/Application Support")
        let oldA = a.appendingPathComponent("Lumen"), newA = a.appendingPathComponent("ImageCrat")
        makeLegacyFolder(oldA)
        let inode = (try? fm.attributesOfItem(atPath: oldA.appendingPathComponent("Models/sam2.1-small/model.bin").path)[.systemFileNumber]) as? Int
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = LegacyMigration.migrateSupportFolder(from: oldA, to: newA)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let movedInode = (try? fm.attributesOfItem(atPath: newA.appendingPathComponent("Models/sam2.1-small/model.bin").path)[.systemFileNumber]) as? Int
        check(r.outcome == .moved && r.complete && !fm.fileExists(atPath: oldA.path) && inode != nil && inode == movedInode,
              "only Application Support/Lumen: renamed to ImageCrat (same files, not copied)", String(format: "%.1f ms", ms))
        check(read(newA.appendingPathComponent("Scripts/Mine.js")) == "// my script" && read(newA.appendingPathComponent("genai-usage.json")) != nil
              && fm.fileExists(atPath: newA.appendingPathComponent("Plugins/Plug/manifest.json").path) && fm.fileExists(atPath: newA.appendingPathComponent("Models/sam2.1-small/.complete").path),
              "models, scripts, plugins, usage history and presets are in the new folder")
        check(read(newA.appendingPathComponent("Logs/ImageCrat.log")) == "old log line" && !fm.fileExists(atPath: newA.appendingPathComponent("Logs/Lumen.log").path),
              "the log continues as Logs/ImageCrat.log")
        let manifest = read(newA.appendingPathComponent("Recovery/s1/a.json")) ?? ""
        let newOrig = newA.appendingPathComponent("Scripts/poster.lumen").path.replacingOccurrences(of: "/", with: "\\/")
        check(manifest.contains(newOrig) && !manifest.contains(oldA.path.replacingOccurrences(of: "/", with: "\\/") + "\\/"), "recovery entries that pointed into the old folder point into the new one")
        let decoded = (try? Data(contentsOf: newA.appendingPathComponent("Recovery/s1/a.json"))).flatMap { try? JSONDecoder().decode(RecoveryEntry.self, from: $0) }
        check(decoded?.originalPath == newA.appendingPathComponent("Scripts/poster.lumen").path && decoded?.files == ["a-0001.lumen"], "the rewritten recovery entry still decodes", decoded?.originalPath ?? "nil")
        check(((try? Data(contentsOf: newA.appendingPathComponent("Artist/bookmark.json"))) ?? Data()).range(of: Data(oldA.path.utf8)) != nil, "binary data is left untouched")
        // idempotent: running again changes nothing
        let snapshot = listing(newA)
        let r2 = LegacyMigration.migrateSupportFolder(from: oldA, to: newA)
        check(r2.outcome == .nothingToDo && r2.complete && listing(newA) == snapshot, "running again does nothing")

        // 2. both folders: merge, newer file wins, the older copy is kept aside, nothing overwritten
        func makeBoth(_ root: URL) -> (URL, URL) {
            let old = root.appendingPathComponent("Lumen"), new = root.appendingPathComponent("ImageCrat")
            write("only in Lumen", old.appendingPathComponent("a.txt"))
            write("Lumen newer", old.appendingPathComponent("b.json"), age: -10)
            write("ImageCrat older", new.appendingPathComponent("b.json"), age: -1000)
            write("Lumen older", old.appendingPathComponent("c.json"), age: -1000)
            write("ImageCrat newer", new.appendingPathComponent("c.json"), age: -10)
            write("d", old.appendingPathComponent("dir/d.txt"))
            write("e", new.appendingPathComponent("dir/e.txt"))
            write("weights", old.appendingPathComponent("Models/m1/w.bin"))
            write("weights2", new.appendingPathComponent("Models/m2/w.bin"))
            write("x", old.appendingPathComponent(".DS_Store"))
            return (old, new)
        }
        let (oldB, newB) = makeBoth(tmp.appendingPathComponent("B"))
        let rb = LegacyMigration.migrateSupportFolder(from: oldB, to: newB)
        let conflicts = newB.appendingPathComponent(LegacyMigration.conflictsFolderName)
        check(rb.outcome == .merged && rb.complete && rb.conflicts == 2 && !fm.fileExists(atPath: oldB.path), "both folders: merged, old folder removed", "\(rb.moved) moved, \(rb.conflicts) in both")
        check(read(newB.appendingPathComponent("a.txt")) == "only in Lumen" && read(newB.appendingPathComponent("dir/d.txt")) == "d" && read(newB.appendingPathComponent("dir/e.txt")) == "e"
              && fm.fileExists(atPath: newB.appendingPathComponent("Models/m1/w.bin").path) && fm.fileExists(atPath: newB.appendingPathComponent("Models/m2/w.bin").path),
              "missing items are moved in, folders are merged")
        check(read(newB.appendingPathComponent("b.json")) == "Lumen newer" && read(conflicts.appendingPathComponent("b.json")) == "ImageCrat older"
              && read(newB.appendingPathComponent("c.json")) == "ImageCrat newer" && read(conflicts.appendingPathComponent("c.json")) == "Lumen older",
              "a file in both: the newer copy is used, the older one is kept in “\(LegacyMigration.conflictsFolderName)”")
        let notes = LegacyMigration.takeNotes()
        check(notes.contains { $0.hasPrefix("Merged the Lumen support folder") } && notes.contains { $0.contains("b.json") }, "the merge is noted in the log", notes.first { $0.hasPrefix("Merged") } ?? "")
        let merged = listing(newB)
        check(LegacyMigration.migrateSupportFolder(from: oldB, to: newB).outcome == .nothingToDo && listing(newB) == merged, "merge: running again does nothing")

        // 3. interrupted mid-merge, then resumed: same result as an uninterrupted merge
        let (oldC, newC) = makeBoth(tmp.appendingPathComponent("C"))
        LegacyMigration.testInterruptAfter = 2
        let rc1 = LegacyMigration.migrateSupportFolder(from: oldC, to: newC)
        LegacyMigration.testInterruptAfter = nil
        let partial = fm.fileExists(atPath: oldC.path)
        let rc2 = LegacyMigration.migrateSupportFolder(from: oldC, to: newC)
        check(!rc1.complete && partial && rc2.complete && !fm.fileExists(atPath: oldC.path), "an interrupted merge is not marked done and finishes on the next launch")
        let strip: ([String: String]) -> [String: String] = { $0.filter { !$0.key.hasPrefix(".") } }
        check(strip(listing(newC)) == strip(merged), "interrupted + resumed gives the same folder as an uninterrupted merge",
              Set(listing(newC).keys).symmetricDifference(Set(merged.keys)).sorted().joined(separator: ", "))

        // 4. "ImageCrat" is a file: nothing moved, not marked done
        let d = tmp.appendingPathComponent("D")
        write("x", d.appendingPathComponent("Lumen/x.txt"))
        write("not a folder", d.appendingPathComponent("ImageCrat"))
        let rd = LegacyMigration.migrateSupportFolder(from: d.appendingPathComponent("Lumen"), to: d.appendingPathComponent("ImageCrat"))
        check(rd.outcome == .failed && !rd.complete && read(d.appendingPathComponent("Lumen/x.txt")) == "x", "an “ImageCrat” file in the way: nothing is moved, retried next launch")
        // 5. an ImageCrat folder with only empty folders in it (a development build created Models/): still one rename
        let f = tmp.appendingPathComponent("F")
        write("weights", f.appendingPathComponent("Lumen/Models/m/w.bin"))
        try? fm.createDirectory(at: f.appendingPathComponent("ImageCrat/Models"), withIntermediateDirectories: true)
        let rf = LegacyMigration.migrateSupportFolder(from: f.appendingPathComponent("Lumen"), to: f.appendingPathComponent("ImageCrat"))
        check(rf.outcome == .moved && rf.complete && read(f.appendingPathComponent("ImageCrat/Models/m/w.bin")) == "weights", "an ImageCrat folder holding only empty folders: the Lumen folder still moves with one rename")
        // 6. no old folder: done, nothing created
        let e = tmp.appendingPathComponent("E")
        let re = LegacyMigration.migrateSupportFolder(from: e.appendingPathComponent("Lumen"), to: e.appendingPathComponent("ImageCrat"))
        check(re.outcome == .nothingToDo && re.complete && !fm.fileExists(atPath: e.appendingPathComponent("ImageCrat").path), "a new tester (no Lumen folder): nothing to do")
        _ = LegacyMigration.takeNotes()
    }

    // MARK: - Migration: preferences

    static func preferencesMigration(_ tmp: URL) {
        let oldName = "app.imagecrat.selftest.rename-old-\(UUID().uuidString.prefix(8))", newName = "app.imagecrat.selftest.rename-new-\(UUID().uuidString.prefix(8))"
        guard let old = UserDefaults(suiteName: oldName), let new = UserDefaults(suiteName: newName) else { check(false, "temporary defaults suites"); return }
        defer {
            for n in [oldName, newName] {
                UserDefaults.standard.removePersistentDomain(forName: n)
                try? fm.removeItem(at: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences/\(n).plist"))
            }
        }
        let oldFolder = tmp.appendingPathComponent("P/Lumen"), newFolder = tmp.appendingPathComponent("P/ImageCrat")
        old.set(false, forKey: "Lumen.SmartGuides")
        old.set("Painting", forKey: "Lumen.Workspace")
        old.set(oldFolder.appendingPathComponent("Scripts/a.js").path, forKey: "Lumen.LastScript")
        old.set(Data("{\"folder\":\"\(oldFolder.path.replacingOccurrences(of: "/", with: "\\/"))\\/Brushes\"}".utf8), forKey: "LumenPreferences")
        old.set([oldFolder.path, "/elsewhere"], forKey: "Lumen.Folders")
        old.set(false, forKey: "Lumen.TaskBar")
        old.synchronize()
        new.set(true, forKey: "Lumen.TaskBar")     // already set in ImageCrat: kept
        new.synchronize()
        let n = LegacyMigration.migratePreferences(fromDomain: oldName, into: new, domain: newName, oldFolder: oldFolder, newFolder: newFolder)
        check(n == 5 && new.object(forKey: "Lumen.SmartGuides") as? Bool == false && new.string(forKey: "Lumen.Workspace") == "Painting",
              "preferences: the old domain's keys are copied", "\(n) copied")
        check(new.bool(forKey: "Lumen.TaskBar") == true, "preferences: a key the new domain already has is not overwritten")
        let prefsJSON = new.data(forKey: "LumenPreferences").map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(new.string(forKey: "Lumen.LastScript") == newFolder.appendingPathComponent("Scripts/a.js").path
              && prefsJSON.contains(newFolder.path.replacingOccurrences(of: "/", with: "\\/") + "\\/Brushes")
              && (new.array(forKey: "Lumen.Folders") as? [String]) == [newFolder.path, "/elsewhere"], "preferences: paths into the old support folder point into the new one")
        check(old.bool(forKey: "Lumen.TaskBar") == false && old.string(forKey: "Lumen.Workspace") == "Painting" && old.dictionaryRepresentation()["Lumen.SmartGuides"] != nil,
              "preferences: the old domain is left as it was")
        check(LegacyMigration.migratePreferences(fromDomain: oldName, into: new, domain: newName, oldFolder: oldFolder, newFolder: newFolder) == 0, "preferences: running again copies nothing")
        let none = LegacyMigration.migratePreferences(fromDomain: "app.imagecrat.selftest.rename-missing-\(UUID().uuidString.prefix(8))", into: new, domain: newName,
                                                      oldFolder: oldFolder, newFolder: newFolder)
        check(none == 0, "preferences: no old domain, nothing to do")
        _ = LegacyMigration.takeNotes()
    }

    // MARK: - Migration: Keychain (test services only)

    static func keychainMigration() {
        let base = "app.imagecrat.selftest.rename-\(UUID().uuidString.prefix(8))"
        let oldS = base + ".old", newS = base + ".new", newS2 = base + ".new2"
        let accounts = GenAIKeychain.accounts
        guard accounts.count >= 3 else { check(false, "provider accounts"); return }
        let (a0, a1, a2) = (accounts[0], accounts[1], accounts[2])
        let oldKC = GenAIKeychain(service: oldS), newKC = GenAIKeychain(service: newS), new2KC = GenAIKeychain(service: newS2)
        defer { for kc in [oldKC, newKC, new2KC] { for a in accounts { kc.delete(a) } }; GenAIKeychain.resetCaches() }
        let k0 = "test-\(UUID().uuidString)", k1 = "test-\(UUID().uuidString)", kNew = "test-\(UUID().uuidString)"
        guard oldKC.set(k0, for: a0) == errSecSuccess, oldKC.set(k1, for: a1) == errSecSuccess, newKC.set(kNew, for: a1) == errSecSuccess else {
            check(false, "test Keychain items could be created"); return
        }
        GenAIKeychain.resetCaches()
        // the real migration runs on a background queue; so does this one
        var r = LegacyMigration.KeychainResult()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { r = LegacyMigration.migrateKeychain(accounts: accounts, from: .init(service: oldS), to: newKC); done.signal() }
        done.wait()
        GenAIKeychain.resetCaches()
        check(r.finished && r.copied == [a0] && r.kept == [a1] && r.failed.isEmpty, "Keychain: a key only in the old service is copied; one already in the new service is kept",
              "copied \(r.copied), kept \(r.kept)")
        check(newKC.get(a0) == k0 && newKC.get(a1) == kNew && oldKC.get(a0) == k0, "Keychain: the new service has the old key, its own key is untouched, the old item stays")
        check(newKC.get(a2) == nil, "Keychain: accounts without an old key are not created")
        let again = LegacyMigration.migrateKeychain(accounts: accounts, from: .init(service: oldS), to: newKC)
        check(again.copied.isEmpty && Set(again.kept) == [a0, a1], "Keychain: running again copies nothing")
        // access denied (the macOS prompt answered with Deny): nothing written, a clear note without the key
        _ = LegacyMigration.takeNotes()
        let denied = LegacyMigration.migrateKeychain(accounts: accounts, from: .init(service: oldS, reader: { _ in nil }), to: new2KC)
        let notes = LegacyMigration.takeNotes()
        check(denied.finished && Set(denied.failed) == [a0, a1] && new2KC.get(a0) == nil && new2KC.get(a1) == nil, "Keychain: a denied read leaves things as they are")
        check(notes.count == 2 && notes.allSatisfy { $0.contains("Re-enter it in Preferences ▸ Generative AI") } && !notes.contains { $0.contains(k0) || $0.contains(k1) },
              "Keychain: the log says to re-enter the key, and never contains a key", notes.first ?? "")
        check(LegacyMigration.keyNotCarriedMessage("fal.ai").contains("Preferences ▸ Generative AI"), "Keychain: the status message points at Preferences ▸ Generative AI")
        // the guard: automated runs never touch the real services
        let real = LegacyMigration.migrateKeychain(accounts: accounts, from: .init(service: Brand.Legacy.keychainService), to: GenAIKeychain.shared)
        check(real.blocked && real.copied.isEmpty && !LegacyMigration.LegacyKeychain(service: Brand.Legacy.keychainService).exists(a0)
              && LegacyMigration.LegacyKeychain(service: Brand.Legacy.keychainService).read(a0) == nil, "Keychain: the real old and new services are refused in an automated run")
        check(GenAIKeychain.shared.set("x", for: a0) == errSecNotAvailable, "Keychain: the real new service is not writable in an automated run")
    }
}
