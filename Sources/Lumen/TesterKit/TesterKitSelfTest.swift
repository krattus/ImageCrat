import AppKit
import CryptoKit
import SwiftUI
import ImageCratCore

/// Bug reports (contents, redaction, zip layout, attachment toggles, crash-report selection), the diagnostic log, model
/// packs (export / import round trip, checksums, corrupted files), placeholder download URLs, SAM 3.1's tokenizer lookup
/// from an app bundle, and a fresh Mac's first-launch state. Everything works in temporary folders: the real crash
/// reports, models folder, preferences, Desktop and clipboard are never read or written (a private pasteboard is used).
/// Views are rendered in offscreen windows. `LUMEN_SELFTEST_ONLY=testerkit Lumen --selftest <dir>`
/// With `TESTERKIT_FRESH=1` (run with an empty `CFFIXED_USER_HOME`, `LUMEN_SUPPORT_DIR` and `LUMEN_MODELS_DIR`) it also
/// checks the process-wide first-launch state.
enum TesterKitSelfTest {
    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") testerkit: \(name)\(d.isEmpty ? "" : " — " + d)")
        fflush(stdout)
    }
    static func info(_ s: String) { print("INFO testerkit: \(s)"); fflush(stdout) }
    /// One spelling per folder (/tmp vs /private/tmp, "..").
    static func canon(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path }

    static let fm = FileManager.default
    static let home = NSHomeDirectory()
    // fake secrets and prompts that must never reach a report
    static let fakeKeys = ["sk-proj-T3sterKitAbc123Def456Ghi789", "r8_T3sterKitReplicate0123456789", "AIzaSyT3sterKit-0123456789abcdefghij",
                           "1a2b3c4d-1234-5678-9abc-def012345678:0123456789abcdef0123456789abcdef", "Bearer tk_live_9f8e7d6c5b4a"]
    static let fakePrompts = ["a red fox sleeping in fresh snow", "castle at dusk with dragons", "secret layer caption"]

    static func run(_ out: URL) {
        passes = 0; failures = 0
        let dir = out.appendingPathComponent("testerkit")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = fm.temporaryDirectory.appendingPathComponent("lumen-testerkit-\(UUID().uuidString.prefix(8))")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let savedRoot = ModelManager.rootOverride
        defer { ModelManager.rootOverride = savedRoot }

        redaction(tmp)
        diagLog(tmp)
        crashSelection(tmp)
        report(tmp, dir)
        modelPacks(tmp)
        placeholders(tmp)
        samTokenizer(tmp)
        freshMac(tmp)
        menusAndAbout()
        snapshots(tmp, dir)
        print("testerkit: \(passes) passed, \(failures) failed")
    }

    // MARK: - Redaction

    static func noSecrets(_ s: String, _ what: String) {
        check(!s.contains(home) && !s.contains("/Users/"), "\(what): no home folder path", s.contains(home) ? "contains \(home)" : "")
        let leakedKeys = fakeKeys.filter { k in s.contains(k) || s.contains(String(k.dropFirst(7).prefix(14))) }
        check(leakedKeys.isEmpty, "\(what): no API keys or key-like strings", leakedKeys.joined(separator: ", "))
        let leakedPrompts = fakePrompts.filter { s.contains($0) || s.contains(String($0.prefix(12))) }
        check(leakedPrompts.isEmpty, "\(what): no prompts", leakedPrompts.joined(separator: ", "))
    }

    static func redaction(_ tmp: URL) {
        let h = "/Users/tester"
        let p = Redactor.logLine("Saved /Users/tester/Desktop/Client Work/poster final.png and /Volumes/Card/DCIM/IMG_0042.JPG", home: h)
        check(!p.contains("/Users/tester") && !p.contains("Client Work") && !p.contains("DCIM") && p.contains("~/…/poster") && p.contains("…/IMG_0042.JPG"),
              "paths: home shown as ~, folders dropped, file name kept", p)
        check(Redactor.logLine("Opened “holiday.psd” (3 layers)", home: h) == "Opened “….psd” (3 layers)", "quoted file name keeps only its extension",
              Redactor.logLine("Opened “holiday.psd” (3 layers)", home: h))
        let q = Redactor.logLine("Generating “\(fakePrompts[0])”…", home: h)
        check(!q.contains("red fox") && q.contains("“…”"), "quoted prompt removed", q)
        let j = Redactor.logLine(#"HTTP 400: {"error":"bad","prompt":"castle at dusk with dragons","seed":3}"#, home: h)
        check(!j.contains("castle") && j.contains(#""prompt":"#) && j.contains(#""error":"#), "prompt in a JSON error body removed (keys stay readable)", j)
        let f = Redactor.logLine("request failed, prompt: castle at dusk with dragons", home: h)
        check(!f.contains("castle"), "prompt: field removed", f)
        for k in fakeKeys {
            let r = Redactor.logLine("auth failed for key \(k) (401)", home: h)
            check(!r.contains(k) && r.contains("redacted"), "key-like string removed: \(k.prefix(6))…", r)
        }
        let twice = Redactor.logLine(Redactor.logLine("Authorization: \(fakeKeys[4]) and key=\(fakeKeys[0])", home: h), home: h)
        check(twice == Redactor.logLine("Authorization: \(fakeKeys[4]) and key=\(fakeKeys[0])", home: h) && !twice.contains("] key]"), "redacting twice changes nothing", twice)
        let kf = Redactor.logLine("x-key=abcdef12 token: zzzzzzzzzz", home: h)
        check(!kf.contains("abcdef12") && !kf.contains("zzzzzzzzzz"), "key= / token: fields removed", kf)
        let url = Redactor.logLine("Model download failed: HTTP 404 for https://huggingface.co/apple/coreml-sam2.1-small/resolve/main/x.zip", home: h)
        check(url.contains("https://huggingface.co/apple/coreml-sam2.1-small/resolve/main/x.zip"), "URLs are kept", url)
        check(Redactor.logLine("Merged 3 layers — 1/2 done, A / B", home: h) == "Merged 3 layers — 1/2 done, A / B", "ordinary text unchanged")
        check(Redactor.homeFolder("file://\(home)/Pictures/a.png and \(home)/b", home: home) == "~/Pictures/a.png and ~/b", "the real home folder → ~")
        let u = Redactor.userText("It broke in \(home)/Desktop/test.psd after I pasted \(fakeKeys[0])", home: home)
        check(!u.contains(home) && !u.contains(fakeKeys[0]) && u.contains("~/Desktop/test.psd"), "tester's own text: home → ~, keys removed, rest kept", u)
    }

    // MARK: - Diagnostic log

    static func diagLog(_ tmp: URL) {
        let d = tmp.appendingPathComponent("log1")
        let log = DiagLog(directory: d, capacity: 10)
        check(log.previousSession.isEmpty && log.entries.isEmpty, "a new log starts empty")
        for i in 0..<25 { log.record(.info, "message \(i)") }
        check(log.entries.count == 10 && log.entries.first?.message == "message 15" && log.entries.last?.message == "message 24", "ring buffer keeps the newest \(log.capacity)",
              "\(log.entries.count): \(log.entries.first?.message ?? "")")
        log.record(.warning, "same warning"); log.record(.warning, "same warning"); log.record(.warning, "same warning")
        check(log.entries.last?.repeats == 3 && log.lines.last?.hasSuffix("same warning (×3)") == true, "repeated lines are counted, not duplicated", log.lines.last ?? "")
        let t0 = Date()
        log.record(.status, "Exporting image… 10%", date: t0)
        log.record(.status, "Exporting image… 55%", date: t0.addingTimeInterval(0.4))
        log.record(.status, "Exporting image… 90%", date: t0.addingTimeInterval(0.8))
        check(log.entries.filter { $0.message.hasPrefix("Exporting image") }.count == 1 && log.entries.last?.message.hasSuffix("90%") == true,
              "a progress status updating in place keeps one line")
        log.record(.error, "Upload of \(home)/Desktop/x.png with key \(fakeKeys[0]) for “\(fakePrompts[1])” failed")
        log.record(.status, String(repeating: "long ", count: 200))
        log.flush()
        noSecrets(log.lines.joined(separator: "\n"), "log buffer")
        check(log.entries.allSatisfy { $0.message.count <= DiagLog.maxMessage }, "log lines are capped at \(DiagLog.maxMessage) characters")
        let file = d.appendingPathComponent("ImageCrat.log")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let perms = (try? fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0
        check(text.contains("message 24") && text.contains("WARN") && perms == 0o600, "persisted to Logs/ImageCrat.log (0600)", "perms \(String(perms, radix: 8))")
        noSecrets(text, "log file")
        // next run: the old log becomes the previous session
        let log2 = DiagLog(directory: d)
        check(log2.previousSession.contains { $0.contains("message 24") } && fm.fileExists(atPath: d.appendingPathComponent("ImageCrat.previous.log").path) && log2.entries.isEmpty,
              "on the next launch the last run's lines are kept as the previous session")
        let mem = DiagLog(directory: nil)
        mem.info("memory only")
        check(mem.fileURL == nil && mem.lines.count == 1, "automated runs: memory only (no file)")
        check(DiagLog.defaultDirectory == nil || ProcessInfo.processInfo.environment["LUMEN_SUPPORT_DIR"] != nil, "self tests never write the real Logs folder")

        // the app's status line and alerts feed the shared log
        let app = AppModel.shared
        let before = app.statusMessage
        app.setStatus("TesterKit status probe “\(fakePrompts[2])”")
        let hook = AppActions.modalHook
        AppActions.modalHook = { _, _ in true }
        AppActions.alert("TesterKit alert probe", "details")
        AppActions.modalHook = hook
        app.statusMessage = before
        let shared = DiagLog.shared.lines.suffix(5).joined(separator: "\n")
        check(shared.contains("STATUS TesterKit status probe “…”") && shared.contains("WARN   Alert: TesterKit alert probe details"), "status messages and alerts are logged (redacted)", shared)
        noSecrets(shared, "shared log")
    }

    // MARK: - Crash reports

    static func makeCrashFolder(_ tmp: URL) -> URL {
        let c = tmp.appendingPathComponent("DiagnosticReports-\(UUID().uuidString.prefix(4))")
        try? fm.createDirectory(at: c, withIntermediateDirectories: true)
        let now = Date()
        let files: [(String, Double)] = [
            // ImageCrat's reports, and two from before the rename (Lumen-*.ips, still collected during the transition)
            ("Lumen-2026-09-28-101010.ips", -4 * 86400), ("Lumen-2026-09-30-101010.ips", -2 * 86400), ("ImageCrat-2026-10-01-101010.ips", -86400),
            ("ImageCrat-2026-10-02-111111.ips", -60), ("ImageCratHelper-2026-10-02-111111.ips", -10), ("LumenHelper-2026-10-02-111111.ips", -10),
            ("Safari-2026-10-02-111111.ips", -5), ("ImageCrat-2026-10-02-111111.crash", -5), ("imagecrat-2026-10-02.ips", -5), ("ImageCrat.ips.txt", -5),
        ]
        for (name, age) in files {
            let u = c.appendingPathComponent(name)
            let body = #"{"app_name":"ImageCrat","procPath":"\#(home)/Applications/ImageCrat.app/Contents/MacOS/ImageCrat","name":"\#(name)"}"# + "\n{}\n"
            try? body.write(to: u, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.modificationDate: now.addingTimeInterval(age)], ofItemAtPath: u.path)
        }
        try? fm.createDirectory(at: c.appendingPathComponent("ImageCrat-folder.ips"), withIntermediateDirectories: true)
        return c
    }

    static func crashSelection(_ tmp: URL) {
        let c = makeCrashFolder(tmp)
        let picked = BugReport.crashReports(in: c, limit: 3).map(\.lastPathComponent)
        check(picked == ["ImageCrat-2026-10-02-111111.ips", "ImageCrat-2026-10-01-101010.ips", "Lumen-2026-09-30-101010.ips"],
              "the newest three ImageCrat-*.ips / Lumen-*.ips, newest first (other apps, helpers, .crash, folders left out)", picked.joined(separator: ", "))
        check(BugReport.crashReports(in: c, limit: 10).map(\.lastPathComponent) == ["ImageCrat-2026-10-02-111111.ips", "ImageCrat-2026-10-01-101010.ips",
                                                                                   "Lumen-2026-09-30-101010.ips", "Lumen-2026-09-28-101010.ips"],
              "all four of the app's reports when the limit allows, the pre-rename Lumen-*.ips included")
        check(BugReport.crashReports(in: c, limit: 0).isEmpty && BugReport.crashReports(in: tmp.appendingPathComponent("missing"), limit: 3).isEmpty,
              "no folder or limit 0: none")
        check(BugReport.defaultCrashFolder.path.hasSuffix("Library/Logs/DiagnosticReports"), "default folder: ~/Library/Logs/DiagnosticReports (not read by this test)")
    }

    // MARK: - Report

    static func fakeSources(_ tmp: URL, crash: URL) -> BugReportSources {
        var s = BugReportSources()
        s.home = home
        s.crashFolder = crash
        s.specs = ModelManager.shared.specs
        s.installed = { $0 == NeuralModelID.lama || $0 == SegModels.sam2 }
        s.installedBytes = { $0 == NeuralModelID.lama ? 98_500_000 : 96_000_000 }
        s.keyStatus = { $0 == .fal ? "yes" : "no" }
        s.preferences = { [("History states", "60"), ("Theme", "Dark"), ("Workspace", "Essentials")] }
        s.aiStatus = { [("SAM 3.1 engine", "SAM 3.1 weights are not installed (Preferences ▸ AI Models).")] }
        s.systemLines = { BugReportSources.liveSystem() }
        s.logLines = { [
            "2026-10-02 23:40:01.000 INFO   ImageCrat dev (development build) on macOS 15.6",
            "2026-10-02 23:40:05.120 STATUS Opened \(home)/Pictures/Client/portrait.psd",
            "2026-10-02 23:41:02.500 ERROR  fal.ai: HTTP 401 with key \(fakeKeys[3]) for prompt: \(fakePrompts[0])",
            "2026-10-02 23:41:09.000 WARN   Alert: Generative Fill failed {\"prompt\":\"\(fakePrompts[1])\"}",
        ] }
        s.previousLogLines = { ["2026-10-02 22:10:00.000 ERROR  last thing before the crash: Authorization: \(fakeKeys[4])"] }
        s.historyNames = { ["Open", "Brush Tool", "New Type Layer “\(fakePrompts[2])”", "Generative Fill", "Gaussian Blur"] }
        s.documentName = "Poster draft.imagecrat"
        s.documentBytes = 24_000_000
        return s
    }

    static func listZip(_ zip: URL, into dir: URL) -> [String] {
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        try? p.run(); p.waitUntilExit()
        return ModelPack.files(in: dir).map(\.path)
    }

    static func report(_ tmp: URL, _ dir: URL) {
        let crash = makeCrashFolder(tmp)
        var src = fakeSources(tmp, crash: crash)
        let text = BugReportText(what: "The brush stopped painting after I opened \(home)/Desktop/QA/brush test.psd.\nI had pasted \(fakeKeys[0]) into the prompt field.",
                                 steps: "1. Open the file\n2. Choose the Brush tool\n3. Paint", expected: "Paint appears on the layer.")
        let opts = BugReportOptions()
        check(opts == BugReportOptions(systemInfo: true, crashReports: true, log: true, history: true, screenshot: false, document: false),
              "defaults: system info, crash reports, log and history on; screenshot and document off")

        // default zip
        let zip = tmp.appendingPathComponent("report-default.zip")
        let entries = (try? BugReport.writeZip(text, opts, src, to: zip)) ?? []
        let unz = tmp.appendingPathComponent("unzipped-default")
        let listed = listZip(zip, into: unz)
        check(fm.fileExists(atPath: zip.path) && listed.contains("report.txt") && Set(listed) == Set(entries),
              "zip written; report.txt at the top level; entries as reported", listed.joined(separator: ", "))
        check(Set(listed) == ["report.txt", "log.txt", "crash-reports/ImageCrat-2026-10-02-111111.ips", "crash-reports/ImageCrat-2026-10-01-101010.ips",
                              "crash-reports/Lumen-2026-09-30-101010.ips"], "default attachments: log + the app's three newest crash reports, no screenshot or document")
        let reportTxt = (try? String(contentsOf: unz.appendingPathComponent("report.txt"), encoding: .utf8)) ?? ""
        let logTxt = (try? String(contentsOf: unz.appendingPathComponent("log.txt"), encoding: .utf8)) ?? ""
        try? reportTxt.write(to: dir.appendingPathComponent("example-report.txt"), atomically: true, encoding: .utf8)
        try? logTxt.write(to: dir.appendingPathComponent("example-log.txt"), atomically: true, encoding: .utf8)
        for (name, body) in [("report.txt", reportTxt), ("log.txt", logTxt)] {
            noSecrets(body, name)
            check(Redactor.keys(body) == body, "\(name): nothing key-like left to redact")
        }
        for f in listed where f.hasPrefix("crash-reports/") {
            let body = (try? String(contentsOf: unz.appendingPathComponent(f), encoding: .utf8)) ?? ""
            check(!body.contains(home) && body.contains("~/Applications/ImageCrat.app") && body.hasPrefix("{"), "\(f): home folder → ~, still JSON")
        }
        for section in ["What happened", "Steps to reproduce", "What was expected", "Included in this report", "System", "On-device AI models",
                        "Generative AI providers", "Preferences that affect behaviour", "Recent actions"] {
            check(reportTxt.contains("\n\(section)"), "report.txt has “\(section)”")
        }
        check(reportTxt.contains("1. Open the file\n2. Choose the Brush tool") && reportTxt.contains("~/Desktop/QA/brush test.psd"), "the tester's text is kept (home → ~)")
        check(reportTxt.contains("macOS: ") && reportTxt.contains("Mac: ") && reportTxt.contains("GB memory") && reportTxt.contains("Displays: "), "system: macOS, Mac model, chip, memory, displays")
        check(reportTxt.contains("[installed]     big-lama") && reportTxt.contains("98.5 MB on disk") && reportTxt.contains("gfpgan-v1.4 — GFPGAN v1.4 (not downloadable: needs a models pack)"),
              "models: installed with size, placeholders marked")
        check(reportTxt.contains("fal.ai: yes") && reportTxt.contains("OpenAI: no") && reportTxt.contains("keys are never included"), "providers: key stored yes / no only")
        check(reportTxt.contains("  Open\n  Brush Tool\n  New Type Layer “…”\n"), "recent actions: names only, quoted text removed")
        check(logTxt.contains("previous run") && logTxt.contains("this run") && logTxt.contains("~/…/portrait.psd"), "log.txt: previous run + this run, paths shortened")

        // toggles: everything off → report.txt only
        let off = BugReportOptions(systemInfo: false, crashReports: false, log: false, history: false, screenshot: false, document: false)
        let offZip = tmp.appendingPathComponent("report-off.zip")
        _ = try? BugReport.writeZip(text, off, src, to: offZip)
        let offList = listZip(offZip, into: tmp.appendingPathComponent("unzipped-off"))
        let offTxt = (try? String(contentsOf: tmp.appendingPathComponent("unzipped-off/report.txt"), encoding: .utf8)) ?? ""
        check(offList == ["report.txt"] && !offTxt.contains("On-device AI models") && !offTxt.contains("Recent actions (") && offTxt.contains("System info: no")
              && !offTxt.contains("macOS: "), "all toggles off: only report.txt, without system info or actions", offList.joined(separator: ", "))

        // screenshot + document on
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])
        let doc = Document(state: SelfTest.baseState(64, 40), name: "Poster draft.imagecrat")
        src.windowPNG = png
        src.saveCanvas = { url in try DocumentIO.export(doc.state, to: url, format: .png, quality: 1, scale: 1) }
        src.saveDocument = { url in try DocumentIO.saveNative(doc, to: url) }
        var all = BugReportOptions(); all.screenshot = true; all.document = true
        let allZip = tmp.appendingPathComponent("report-all.zip")
        _ = try? BugReport.writeZip(text, all, src, to: allZip)
        let allDir = tmp.appendingPathComponent("unzipped-all")
        let allList = listZip(allZip, into: allDir)
        check(allList.contains("screenshot-window.png") && allList.contains("screenshot-canvas.png") && allList.contains("document/Poster draft.imagecrat"),
              "screenshot on: window + canvas images; document on: the .imagecrat", allList.joined(separator: ", "))
        let reopened = (try? DocumentIO.load(url: allDir.appendingPathComponent("document/Poster draft.imagecrat")))
        check(reopened != nil, "the attached document opens again")
        let noDoc = { () -> [String] in
            var s2 = src; s2.saveDocument = nil; s2.windowPNG = nil; s2.saveCanvas = nil
            let z = tmp.appendingPathComponent("report-nodoc.zip")
            _ = try? BugReport.writeZip(text, all, s2, to: z)
            return listZip(z, into: tmp.appendingPathComponent("unzipped-nodoc"))
        }()
        check(!noDoc.contains { $0.hasPrefix("document/") || $0.hasPrefix("screenshot") }, "no document / no snapshot available: toggles add nothing")

        check(BugReport.defaultFileName(Date(timeIntervalSince1970: 0)).range(of: #"^ImageCrat Bug Report \d{4}-\d\d-\d\d \d\d\.\d\d\.zip$"#, options: .regularExpression) != nil,
              "default name “ImageCrat Bug Report <date> <time>.zip”", BugReport.defaultFileName())

        // Copy Summary → a private pasteboard (never the real clipboard)
        let m = BugReportModel.shared
        let saved = (text: m.text, options: m.options, sources: m.sources, pb: m.pasteboard)
        let pb = NSPasteboard(name: NSPasteboard.Name("app.lumen.selftest.testerkit.\(UUID().uuidString)"))
        m.pasteboard = pb; m.text = text; m.options = opts; m.sources = src
        m.copySummary()
        let summary = pb.string(forType: .string) ?? ""
        check(summary.contains("What happened:") && summary.contains("Steps to reproduce:\n1. Open the file") && summary.contains("ImageCrat \(AppInfo.version)"),
              "Copy Summary: plain text with the tester's text and version", String(summary.prefix(80)))
        noSecrets(summary, "summary")
        pb.releaseGlobally()
        m.text = saved.text; m.options = saved.options; m.sources = saved.sources; m.pasteboard = saved.pb
        check(m.pasteboard === NSPasteboard.general, "pasteboard restored")
    }

    // MARK: - Model packs

    static func sha(_ d: Data) -> String { ModelPack.hex(SHA256.hash(data: d)) }

    static func fakeSpecs(alphaSHA: String) -> [ModelSpec] {
        [ModelSpec(id: "tk-alpha", name: "Alpha", purpose: "test", license: "MIT", approxMB: 1,
                   files: [.init(url: ModelManager.hf("someone/alpha", "alpha.bin", revision: "0123456789abcdef"), path: "alpha.bin", sha256: alphaSHA)]),
         ModelSpec(id: "tk-beta", name: "Beta", purpose: "test", license: "MIT", approxMB: 1,
                   files: [.init(url: ModelManager.hf("someone/beta", "Beta.mlpackage/Manifest.json"), path: "Beta.mlpackage/Manifest.json")]),
         ModelSpec(id: "tk-gamma", name: "Gamma", purpose: "test", license: "MIT", approxMB: 1,
                   files: [.init(url: ModelManager.hf(NeuralModelID.lumenModelsRepo, "Gamma.zip"), path: "Gamma.zip")])]
    }

    static func makeInstalled(_ root: URL) -> (alpha: Data, specs: [ModelSpec]) {
        let alpha = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        func put(_ rel: String, _ d: Data) {
            let u = root.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: u)
        }
        put("tk-alpha/alpha.bin", alpha)
        put("tk-beta/Beta.mlpackage/Manifest.json", Data(#"{"fileFormatVersion":"1.0.0"}"#.utf8))
        put("tk-beta/Beta.mlpackage/Data/com.apple.CoreML/weights/weight.bin", Data(repeating: 7, count: 9_000_000))
        put("tk-gamma/Gamma.mlmodelc/coremldata.bin", Data(repeating: 3, count: 1000))
        put("tk-gamma/Gamma.zip.txt", Data("note".utf8))
        for id in ["tk-alpha", "tk-beta", "tk-gamma"] { put("\(id)/.complete", Data()); put("\(id)/.DS_Store", Data([0])) }
        return (alpha, fakeSpecs(alphaSHA: sha(alpha)))
    }

    /// Runs async work to completion while the main run loop keeps turning.
    static func wait<T>(_ f: @escaping () async throws -> T) -> Result<T, Error> {
        var r: Result<T, Error>?
        Task.detached { let v: Result<T, Error>; do { v = .success(try await f()) } catch { v = .failure(error) }; await MainActor.run { r = v } }
        let end = Date().addingTimeInterval(60)
        while r == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return r ?? .failure(ModelPack.PackError.cancelled)
    }

    static func importR(_ src: URL, _ specs: [ModelSpec], _ root: URL) -> Result<ModelPack.ImportResult, Error> {
        wait { try await ModelPack.importModels(from: src, specs: specs, root: root) }
    }

    static func modelPacks(_ tmp: URL) {
        let base = tmp.appendingPathComponent("packs")
        let rootA = base.appendingPathComponent("A/Models")
        let (alpha, specs) = makeInstalled(rootA)
        let pack = base.appendingPathComponent("Lumen Models test")

        // export
        let job = ModelPack.Job()
        var fractions: [Double] = []
        job.onProgress = { f, _ in fractions.append(f) }
        let manifest = try? ModelPack.export(ids: ["tk-alpha", "tk-beta", "tk-gamma", "tk-missing"], specs: specs, root: rootA, to: pack, job: job)
        check(manifest?.models.map(\.id) == ["tk-alpha", "tk-beta", "tk-gamma"], "export: installed models only (unknown / missing ids ignored)")
        check(fractions.last.map { abs($0 - 1) < 0.0001 } == true && fractions == fractions.sorted(), "export: progress rises to 1")
        let onDisk = ModelPackManifest.read(pack.appendingPathComponent("manifest.json"))
        check(onDisk == manifest && fm.fileExists(atPath: pack.appendingPathComponent("README.txt").path) && !fm.fileExists(atPath: pack.path + ".partial"),
              "export: manifest.json + README.txt written, no .partial left")
        let a = manifest?.models.first
        check(a?.files == [.init(path: "alpha.bin", size: Int64(alpha.count), sha256: sha(alpha))] && a?.size == Int64(alpha.count)
              && a?.version == "0123456789ab" && a?.sha256 == ModelPackManifest.digest(a?.files ?? []), "manifest: id, version, size, per-file and per-model sha256")
        check(manifest?.models[1].files.map(\.path) == ["Beta.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "Beta.mlpackage/Manifest.json"]
              && manifest?.models[1].version == "main" && manifest?.models[2].version == "main", "manifest: nested files, markers (.complete, .DS_Store) left out")
        check(ModelPackManifest.read(pack.appendingPathComponent("tk-beta/imagecrat-model.json"))?.models.map(\.id) == ["tk-beta"]
              && !fm.fileExists(atPath: pack.appendingPathComponent("tk-beta/.complete").path), "each model folder carries its own imagecrat-model.json")
        check((try? ModelPack.export(ids: ["tk-alpha"], specs: specs, root: rootA, to: pack)) == nil, "export refuses to overwrite an existing folder")
        let cj = ModelPack.Job(); cj.cancel()
        let cancelled = Result { try ModelPack.export(ids: ["tk-beta"], specs: specs, root: rootA, to: base.appendingPathComponent("cancelled"), job: cj) }
        check({ if case .failure(ModelPack.PackError.cancelled) = cancelled { return true }; return false }()
              && !fm.fileExists(atPath: base.appendingPathComponent("cancelled").path) && !fm.fileExists(atPath: base.appendingPathComponent("cancelled.partial").path),
              "export: Cancel stops it and removes the partial folder")

        // import into an empty Models folder
        let rootB = base.appendingPathComponent("B/Models")
        let r1 = try? importR(pack, specs, rootB).get()
        check(r1?.installed.sorted() == ["tk-alpha", "tk-beta", "tk-gamma"] && r1?.rejected.isEmpty == true, "import: all three installed", r1?.summary ?? "failed")
        let same = ["tk-alpha", "tk-beta", "tk-gamma"].allSatisfy { id in
            fm.fileExists(atPath: rootB.appendingPathComponent("\(id)/.complete").path)
                && ModelPack.files(in: rootB.appendingPathComponent(id)).map(\.path) == ModelPack.files(in: rootA.appendingPathComponent(id)).map(\.path)
        }
        check(same && (try? Data(contentsOf: rootB.appendingPathComponent("tk-alpha/alpha.bin"))) == alpha, "import: identical files, marked installed (.complete)")
        let leftovers = ((try? fm.contentsOfDirectory(atPath: rootB.path)) ?? []).filter { $0.hasPrefix(".import") }
        check(leftovers.isEmpty, "import: no staging folders left")
        // again: skipped
        let r2 = try? importR(pack, specs, rootB).get()
        check(r2?.installed.isEmpty == true && r2?.skipped.count == 3 && r2?.skipped["tk-alpha"] == "already installed, identical", "import again: identical models skipped", r2?.summary ?? "")
        // the manifest itself, and one model folder of the pack
        let r3 = try? importR(pack.appendingPathComponent("manifest.json"), specs, base.appendingPathComponent("C/Models")).get()
        check(r3?.installed.count == 3, "import from manifest.json")
        let r4 = try? importR(pack.appendingPathComponent("tk-beta"), specs, base.appendingPathComponent("D/Models")).get()
        check(r4?.installed == ["tk-beta"], "import a single model folder from a pack", r4?.summary ?? "")
        // a zip of the pack (as Finder's Compress makes it)
        let zip = base.appendingPathComponent("pack.zip")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-c", "-k", "--keepParent", pack.path, zip.path]
        try? p.run(); p.waitUntilExit()
        let rootE = base.appendingPathComponent("E/Models")
        let r5 = try? importR(zip, specs, rootE).get()
        let tempLeft = ((try? fm.contentsOfDirectory(atPath: rootE.deletingLastPathComponent().path)) ?? []).filter { $0.hasPrefix(".imagecrat-import") }
        check(r5?.installed.count == 3 && tempLeft.isEmpty, "import from a zip (unzipped to a temporary folder, removed afterwards)", r5?.summary ?? "")
        // a bare model folder copied from another Mac's Models folder
        let r6 = try? importR(rootA.appendingPathComponent("tk-alpha"), specs, base.appendingPathComponent("F/Models")).get()
        check(r6?.installed == ["tk-alpha"] && r6?.notes.first?.contains("no pack checksums") == true, "import a plain model folder: built-in checksums only, says so", r6?.summary ?? "")

        // corrupted packs
        func corrupt(_ name: String, _ change: (URL) -> Void) -> ModelPack.ImportResult? {
            let c = base.appendingPathComponent(name)
            try? fm.copyItem(at: pack, to: c)
            change(c)
            let root = base.appendingPathComponent(name + "-root/Models")
            let r = try? importR(c, specs, root).get()
            let staged = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix(".import") }
            check(staged.isEmpty, "\(name): nothing half-installed left behind")
            return r
        }
        let flipped = corrupt("flipped") { c in
            let u = c.appendingPathComponent("tk-beta/Beta.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
            var d = (try? Data(contentsOf: u)) ?? Data(); if !d.isEmpty { d[d.count / 2] ^= 0xFF }; try? d.write(to: u)
        }
        check(flipped?.rejected["tk-beta"]?.hasPrefix("checksum mismatch") == true && flipped?.installed.sorted() == ["tk-alpha", "tk-gamma"]
              && !fm.fileExists(atPath: base.appendingPathComponent("flipped-root/Models/tk-beta").path), "a changed byte: that model rejected, the others installed", flipped?.summary ?? "")
        let truncated = corrupt("truncated") { c in try? Data([1, 2, 3]).write(to: c.appendingPathComponent("tk-alpha/alpha.bin")) }
        check(truncated?.rejected["tk-alpha"]?.hasPrefix("wrong size") == true, "a truncated file: rejected", truncated?.summary ?? "")
        let missing = corrupt("missing") { c in try? fm.removeItem(at: c.appendingPathComponent("tk-beta/Beta.mlpackage/Manifest.json")) }
        check(missing?.rejected["tk-beta"]?.hasPrefix("missing file") == true, "a missing file: rejected", missing?.summary ?? "")
        let unknown = corrupt("unknown") { c in
            guard var m = ModelPackManifest.read(c.appendingPathComponent("manifest.json")) else { return }
            m.models[0].id = "tk-unknown"
            try? m.encoded().write(to: c.appendingPathComponent("manifest.json"))
        }
        check(unknown?.rejected["tk-unknown"] != nil, "an unknown model id: rejected")
        // a bare folder whose file doesn't match Lumen's built-in checksum
        let bare = base.appendingPathComponent("bare/tk-alpha")
        try? fm.createDirectory(at: bare, withIntermediateDirectories: true)
        try? Data(repeating: 9, count: alpha.count).write(to: bare.appendingPathComponent("alpha.bin"))
        let r7 = try? importR(bare, specs, base.appendingPathComponent("G/Models")).get()
        check(r7?.rejected["tk-alpha"]?.contains("ImageCrat's checksum") == true, "a plain folder that fails ImageCrat's built-in checksum: rejected", r7?.summary ?? "")
        // not a pack
        let junk = base.appendingPathComponent("junk"); try? fm.createDirectory(at: junk.appendingPathComponent("x"), withIntermediateDirectories: true)
        let r8 = importR(junk, specs, base.appendingPathComponent("H/Models"))
        check({ if case .failure(ModelPack.PackError.notAPack) = r8 { return true }; return false }(), "a folder that isn't a pack: a clear error")

        // the Preferences controller: off the main thread, Cancel-able, refreshes the list
        let ctl = ModelPackController.shared
        let rev = ModelManager.shared.revision
        var done: Result<ModelPack.ImportResult, Error>?
        let savedSpecs = ModelManager.shared.specs
        for s in specs { ModelManager.shared.register(s) }
        ctl.startImport(from: pack, root: base.appendingPathComponent("I/Models")) { done = $0 }
        check(ctl.isRunning, "controller: import runs in the background")
        let end = Date().addingTimeInterval(30)
        while done == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check((try? done?.get())?.installed.count == 3 && !ctl.isRunning && ModelManager.shared.revision > rev && ctl.result?.hasPrefix("Installed 3") == true,
              "controller: finishes, reports, refreshes the models list", ctl.result ?? "")
        var exported: Result<ModelPackManifest, Error>?
        ctl.startExport(ids: ["tk-alpha"], to: base.appendingPathComponent("ctl-export"), root: rootA) { exported = $0 }
        while exported == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check((try? exported?.get())?.models.count == 1, "controller: export completes", ctl.result ?? "")
        ctl.result = nil
        ModelManager.shared.unregisterForTests(Set(specs.map(\.id)), keeping: savedSpecs)
    }

    // MARK: - Placeholder URLs

    static func placeholders(_ tmp: URL) {
        let mm = ModelManager.shared
        let placeholderIDs = mm.specs.filter { !$0.isDownloadable }.map(\.id).sorted()
        check(placeholderIDs == ["gfpgan-v1.4", "nafnet-gopro-w32", "nafnet-sidd-w32"], "placeholder models: the two NAFNets and GFPGAN", placeholderIDs.joined(separator: ", "))
        var bad: [String] = []
        for s in mm.specs where s.isDownloadable {
            for f in s.files {
                let u = f.url
                let hf = u.host == "huggingface.co" && u.pathComponents.count >= 6 && u.pathComponents[3] == "resolve"
                let gh = u.host == "github.com" && u.path.contains("/releases/download/")
                if !(hf || gh) || u.scheme != "https" { bad.append(u.absoluteString) }
                info("URL \(s.id): \(u.absoluteString)\(f.sha256 == nil ? "" : "  sha256 \(f.sha256!.prefix(12))…")")
            }
        }
        check(bad.isEmpty, "every downloadable model: https Hugging Face resolve (or GitHub release) URLs", bad.joined(separator: ", "))
        // ensure() on a placeholder: a clear message, no network
        let root = tmp.appendingPathComponent("ph-models")
        ModelManager.rootOverride = root
        let savedErr = mm.errors[NeuralModelID.gfpgan]
        let r = wait { try await mm.ensure(NeuralModelID.gfpgan) }
        let msg: String = { if case .failure(let e) = r { return e.localizedDescription }; return "" }()
        check(msg.contains("can't be downloaded yet") && msg.contains("Import Models…") && !fm.fileExists(atPath: root.appendingPathComponent(NeuralModelID.gfpgan).path),
              "Download of a placeholder model: refused with “import it from a models pack”, nothing fetched", msg)
        check(ModelError.notInstalled("GFPGAN v1.4").errorDescription?.contains("models pack") == true, "“not installed” for a placeholder model points to a models pack")
        check(mm.missingMessage(NeuralModelID.lama).contains("Preferences ▸ AI Models") && mm.missingMessage(NeuralModelID.lama).contains("95 MB"),
              "a downloadable model: says what to download and where", mm.missingMessage(NeuralModelID.lama))
        check(!mm.canObtain(NeuralModelID.gfpgan) && mm.canObtain(NeuralModelID.lama), "optional extras are only fetched when obtainable (Super Zoom skips GFPGAN)")
        mm.errors[NeuralModelID.gfpgan] = savedErr
        check(SegModels.florence.isEmpty == false && mm.spec(SegModels.sam3)?.purpose.contains("scripts/") == false, "no developer instructions in model descriptions")
    }

    // MARK: - SAM 3.1 tokenizer

    static func samTokenizer(_ tmp: URL) {
        let app = tmp.appendingPathComponent("Elsewhere/ImageCrat.app")
        let res = app.appendingPathComponent("Contents/Resources"), exe = app.appendingPathComponent("Contents/MacOS")
        let bundle = res.appendingPathComponent(SAM3Resources.bundleName)
        try? fm.createDirectory(at: bundle.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: exe, withIntermediateDirectories: true)
        try? #"{"a</w>":320}"#.write(to: bundle.appendingPathComponent("Resources/clip-vocab.json"), atomically: true, encoding: .utf8)
        let cands = SAM3Resources.candidates(bundleURL: app, resourceURL: res, executableDir: exe)
        check(cands.map(\.path) == [bundle.path, exe.appendingPathComponent(SAM3Resources.bundleName).path, app.appendingPathComponent(SAM3Resources.bundleName).path],
              "lookup order: Contents/Resources, next to the executable, the bundle root", cands.map(\.lastPathComponent).joined(separator: ", "))
        check(SAM3Resources.locate(cands) == nil, "an incomplete tokenizer bundle (no merges file) is not used")
        try? "#version: 0.2\na b\n".write(to: bundle.appendingPathComponent("Resources/clip-merges.txt"), atomically: true, encoding: .utf8)
        check(SAM3Resources.locate(cands)?.path == bundle.path, "found in the app bundle's Contents/Resources")
        // the package asks for <app>/sam31-swift_SAM31.bundle, then the build folder; both missing here
        let real = SAM3Resources.bundleURL
        SAM3Resources.installLookup(bundle)
        let askedRoot = Bundle(path: app.appendingPathComponent(SAM3Resources.bundleName).path)
        let askedBuild = Bundle(path: "/nonexistent/build/arm64-apple-macosx/release/" + SAM3Resources.bundleName)
        check(askedRoot?.bundleURL.standardizedFileURL == bundle.standardizedFileURL && askedBuild?.bundleURL.standardizedFileURL == bundle.standardizedFileURL,
              "Bundle(path:) for the package's missing locations → the copy in Contents/Resources", askedRoot?.bundlePath ?? "nil")
        let vocab = askedRoot?.url(forResource: "Resources/clip-vocab", withExtension: "json")
        check(vocab?.standardizedFileURL == bundle.appendingPathComponent("Resources/clip-vocab.json").standardizedFileURL,
              "the package's own call (url(forResource: \"Resources/clip-vocab\", withExtension: \"json\")) resolves")
        check(Bundle(path: "/nonexistent/Other.bundle") == nil && Bundle(path: Bundle.main.bundlePath)?.bundleURL == Bundle.main.bundleURL,
              "other bundles are unaffected")
        SAM3Resources.installLookup(real)
        info("this binary's tokenizer bundle: \(real.map { Redactor.homeFolder($0.path) } ?? "missing") (app bundle: \(AppInfo.isAppBundle))")
        check(real != nil && SAM3Engine.tokenizerResourcesPresent, "this copy of ImageCrat finds its tokenizer files (no #filePath / .build lookup)")
        let reasons = [SAM3Engine.unavailableReason ?? ""]
        check(!reasons.joined().contains(".build"), "unavailable reasons don't point at a build folder", reasons.joined())
        // the real tokenizer files decode as the package reads them (vocab JSON → [String: Int32], merges "a b" lines)
        if let real {
            let vocab = (try? Data(contentsOf: real.appendingPathComponent("Resources/clip-vocab.json"))).flatMap { try? JSONDecoder().decode([String: Int32].self, from: $0) }
            let merges = (try? String(contentsOf: real.appendingPathComponent("Resources/clip-merges.txt"), encoding: .utf8))?
                .split(separator: "\n").filter { !$0.hasPrefix("#version") } ?? []
            check(vocab?.count == 49408 && merges.count > 48000 && merges.allSatisfy { $0.split(separator: " ").count == 2 },
                  "the tokenizer files are complete (CLIP vocab and merges)", "\(vocab?.count ?? 0) tokens, \(merges.count) merges")
        }
        if ProcessInfo.processInfo.environment["TESTERKIT_EXPECT_APP_BUNDLE"] != nil, let res = Bundle.main.resourceURL {
            check(AppInfo.isAppBundle && real.map { canon($0.path).hasPrefix(canon(res.path)) } == true, "bundled app: tokenizer found in Contents/Resources", real?.path ?? "nil")
            // exactly what the package's generated Bundle.module does: Bundle(path: <app>/sam31-swift_SAM31.bundle), then the build folder
            let mainPath = Bundle.main.bundleURL.appendingPathComponent(SAM3Resources.bundleName).path
            check(!fm.fileExists(atPath: mainPath), "bundled app: nothing in the app's root folder (keeps the signature valid)")
            SAM3Resources.installLookup()
            let module = Bundle(path: mainPath)
            let url = module?.url(forResource: "Resources/clip-vocab", withExtension: "json")
            check(url.map { canon($0.path).hasPrefix(canon(res.path)) } == true, "bundled app: the package's lookup resolves to Contents/Resources", url?.path ?? "nil")
            info("bundled app: Bundle.module → \(module?.bundlePath ?? "nil"); version \(AppInfo.versionLine)")
        }
    }

    // MARK: - Fresh Mac

    static func freshMac(_ tmp: URL) {
        let support = tmp.appendingPathComponent("fresh-support")
        ScriptLibrary.installSamplesIfNeeded(into: support)
        let scripts = (try? fm.contentsOfDirectory(atPath: support.appendingPathComponent("Scripts").path)) ?? []
        let plugins = (try? fm.contentsOfDirectory(atPath: support.appendingPathComponent("Plugins").path)) ?? []
        check(!scripts.isEmpty && !plugins.isEmpty && fm.fileExists(atPath: support.appendingPathComponent(".samples-installed").path),
              "first launch: sample scripts and plugins installed into an empty support folder", "\(scripts.count) scripts, \(plugins.count) plugins")
        if let first = scripts.sorted().first {
            let u = support.appendingPathComponent("Scripts/\(first)")
            try? "// edited by the tester".write(to: u, atomically: true, encoding: .utf8)
            ScriptLibrary.installSamplesIfNeeded(into: support)
            check((try? String(contentsOf: u, encoding: .utf8)) == "// edited by the tester", "second launch: the tester's edits are kept")
        }
        check((try? JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))) == Preferences(), "empty preferences decode to the defaults")
        check(WorkspaceManager(store: MemoryWorkspaceStore(), managesWindows: false).current == .essentials, "no saved layout: the Essentials workspace")
        // empty models folder: every model says what to get
        let models = tmp.appendingPathComponent("fresh-models")
        ModelManager.rootOverride = models
        let mm = ModelManager.shared
        let savedErrors = mm.errors
        mm.errors = [:]
        check(mm.specs.allSatisfy { !mm.isInstalled($0.id) }, "empty models folder: nothing installed")
        let vague = mm.specs.filter { s in let m = mm.missingMessage(s.id); return !(m.contains("Preferences ▸ AI Models") || m.contains("models pack")) }
        check(vague.isEmpty, "every model's missing-message says where to get it", vague.map(\.id).joined(separator: ", "))
        check(SAM3Engine.unavailableReason?.contains("Preferences ▸ AI Models") == true, "SAM 3.1 without weights: says to install them", SAM3Engine.unavailableReason ?? "")
        check(mm.missingMessage(SegModels.sam2).contains("SAM 2.1"), "Select Subject (High Quality) without SAM: names the model to download", mm.missingMessage(SegModels.sam2))
        mm.errors = savedErrors
        ModelManager.rootOverride = nil
        // no API keys (automated runs can't see the real Keychain at all)
        check(ProviderID.allCases.allSatisfy { !GenAIKeychain.shared.hasKey($0) || GenAIKeyOverrides.value($0) != nil }, "no API keys visible to a test run")
        let noKey = GenError.noProvider(.fill).errorDescription ?? ""
        check(noKey.contains("Preferences ▸ Generative AI"), "no key: generative commands say where to add one", noKey)
        check(GenAIKeychain.readsBlocked && GenAIKeychain.shared.key(.fal) == nil, "the Keychain is never read by automated runs (no prompt)")
        let live = BugReportSources.live(windowPNG: nil, document: nil)
        check(ProviderID.allCases.allSatisfy { live.keyStatus($0).hasPrefix("no") }, "bug report key status: presence only (no)")

        // process-wide first launch (run with an empty CFFIXED_USER_HOME / LUMEN_SUPPORT_DIR / LUMEN_MODELS_DIR)
        guard ProcessInfo.processInfo.environment["TESTERKIT_FRESH"] != nil else { return }
        let env = ProcessInfo.processInfo.environment
        check(env["CFFIXED_USER_HOME"].map { canon(NSHomeDirectory()) == canon($0) } == true, "fresh run: home folder is the empty temporary one", NSHomeDirectory())
        check(Preferences.load() == Preferences(), "fresh run: preferences are the defaults")
        check(canon(ModelManager.root.path) == canon(env["LUMEN_MODELS_DIR"] ?? "-") && ModelManager.shared.specs.allSatisfy { !ModelManager.shared.isInstalled($0.id) }, "fresh run: no models installed")
        check(BugReport.crashReports(in: BugReport.defaultCrashFolder).isEmpty, "fresh run: no crash reports")
        check(DiagLog.shared.previousSession.isEmpty && DiagLog.shared.fileURL.map { canon($0.path).hasPrefix(canon(env["LUMEN_SUPPORT_DIR"] ?? "-")) } == true, "fresh run: log in the support folder, no previous run")
        check(AppModel.shared.documents.isEmpty, "fresh run: no documents open (welcome screen)")
    }

    // MARK: - Menus / About

    static func menusAndAbout() {
        let help = MenuRegistry.items(for: "Help").map(\.title)
        check(help.contains("Report a Bug…") && help.contains("Open Crash Reports Folder"), "Help menu: Report a Bug…, Open Crash Reports Folder", help.joined(separator: ", "))
        let item = MenuRegistry.items(for: "Help").first { $0.title == "Report a Bug…" }
        let app = AppModel.shared
        let saved = app.dialog
        app.dialog = .about
        check(item?.enabled() == false, "Report a Bug… waits while another dialog is open")
        app.dialog = saved
        check(item?.enabled() == true || saved != nil, "Report a Bug… available otherwise")
        check(DialogRegistry.builders[TesterKitModule.bugReportDialog] != nil, "the dialog is registered")
        check(AppInfo.versionLine.hasPrefix("Version ") && !AppInfo.build.isEmpty, "About: version and build", AppInfo.versionLine)
        check(AppInfo.modelIdentifier != "unknown" && AppInfo.chip != "unknown" && AppInfo.memoryGB > 0, "system facts: model, chip, memory",
              "\(AppInfo.modelIdentifier) · \(AppInfo.chip) · \(AppInfo.memoryGB) GB")
    }

    // MARK: - Snapshots (offscreen windows)

    static func snapshots(_ tmp: URL, _ dir: URL) {
        let m = BugReportModel.shared
        let saved = (text: m.text, options: m.options, sources: m.sources)
        var src = fakeSources(tmp, crash: makeCrashFolder(tmp))
        src.windowPNG = Data([1])
        src.saveCanvas = { _ in }
        src.saveDocument = { _ in }
        m.sources = src
        m.text = BugReportText(what: "The brush stopped painting after switching documents.", steps: "1. Open two photos\n2. Paint in the first\n3. Switch with ⌃`",
                               expected: "")
        m.options = BugReportOptions()
        m.message = ""
        let w1 = UIFixesSelfTest.host(DraggableCard { BugReportDialog() }, CGSize(width: 560, height: 640))
        UIFixesSelfTest.snapshot(w1, "bug_report_dialog", dir)
        m.options.document = true; m.options.screenshot = true
        UIFixesSelfTest.spin(0.3)
        UIFixesSelfTest.snapshot(w1, "bug_report_dialog_document", dir)
        UIFixesSelfTest.close(w1)
        m.text = saved.text; m.options = saved.options; m.sources = saved.sources

        let w2 = UIFixesSelfTest.host(DraggableCard { AboutDialog() }, CGSize(width: 420, height: 300))
        UIFixesSelfTest.snapshot(w2, "about_panel", dir)
        UIFixesSelfTest.close(w2)

        // AI Models with a temporary models folder: LaMa and SAM 2.1 "installed"
        let models = tmp.appendingPathComponent("snap-models")
        for id in [NeuralModelID.lama, SegModels.sam2] {
            try? fm.createDirectory(at: models.appendingPathComponent(id), withIntermediateDirectories: true)
            fm.createFile(atPath: models.appendingPathComponent("\(id)/.complete").path, contents: Data())
        }
        ModelManager.rootOverride = models
        ModelManager.shared.revision += 1
        let ctl = ModelPackController.shared
        ctl.result = "Installed 2: nafnet-sidd-w32, gfpgan-v1.4. Skipped 1: big-lama (already installed, identical)."
        let prefs = VStack(alignment: .leading) { ModelsPreferencesView() }.frame(width: 340, alignment: .topLeading).padding(16)
        let w3 = UIFixesSelfTest.host(prefs, CGSize(width: 380, height: 420))
        UIFixesSelfTest.snapshot(w3, "ai_models_preferences", dir)
        // scroll to the NAFNet / GFPGAN rows, then to the end
        if let sv = w3.contentView.flatMap(findScroll) {
            let maxY = max(0, (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height)
            for (name, y) in [("ai_models_preferences_placeholders", min(maxY, 330)), ("ai_models_preferences_bottom", maxY)] {
                sv.contentView.scroll(to: NSPoint(x: 0, y: y))
                sv.reflectScrolledClipView(sv.contentView)
                UIFixesSelfTest.spin(0.2)
                UIFixesSelfTest.snapshot(w3, name, dir)
            }
        }
        UIFixesSelfTest.close(w3)
        ctl.result = nil
        ModelManager.rootOverride = nil
        ModelManager.shared.revision += 1
        for n in ["bug_report_dialog", "bug_report_dialog_document", "about_panel", "ai_models_preferences"] {
            check(fm.fileExists(atPath: dir.appendingPathComponent(n + ".png").path), "snapshot \(n).png")
        }
    }

    static func findScroll(_ v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView, s.documentView != nil, s.frame.height > 100 { return s }
        for c in v.subviews { if let s = findScroll(c) { return s } }
        return nil
    }
}

extension ModelManager {
    /// Self tests: removes temporary specs again (and puts back any real spec they shadowed).
    func unregisterForTests(_ ids: Set<String>, keeping original: [ModelSpec]) {
        for s in original where ids.contains(s.id) { register(s) }
        let keep = Set(original.map(\.id))
        let extra = ids.subtracting(keep)
        if !extra.isEmpty { removeSpecs(extra) }
    }
}
