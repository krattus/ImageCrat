import AppKit
import ImageCratCore

/// What goes into a bug report (Help ▸ Report a Bug…). Defaults: system info, crash reports, log and history on;
/// screenshot and document off.
struct BugReportOptions: Equatable {
    var systemInfo = true
    var crashReports = true
    var log = true
    var history = true
    var screenshot = false
    var document = false
}

/// The tester's own words.
struct BugReportText: Equatable {
    var what = ""
    var steps = ""
    var expected = ""
    var isEmpty: Bool { [what, steps, expected].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

/// Everything a report reads from the app and the Mac. `live` reads the real ones; self tests inject temporary folders,
/// fake crash reports, fixed key answers and so on.
struct BugReportSources {
    var home = NSHomeDirectory()
    var now = Date()
    var crashFolder = BugReport.defaultCrashFolder
    var crashLimit = 3
    var specs: [ModelSpec] = []
    var installed: (String) -> Bool = { _ in false }
    var installedBytes: (String) -> Int64 = { _ in 0 }
    var modelsFolder = "~/Library/Application Support/ImageCrat/Models"
    /// "yes" / "no" / "checking…" for each provider — whether a key is stored, never the key.
    var keyStatus: (ProviderID) -> String = { _ in "no" }
    var preferences: () -> [(String, String)] = { [] }
    var aiStatus: () -> [(String, String)] = { [] }
    var logLines: () -> [String] = { [] }
    var previousLogLines: () -> [String] = { [] }
    var historyNames: () -> [String] = { [] }
    var documentName: String?
    var documentBytes: Int64 = 0
    /// Writes the current document (as .imagecrat) to the URL.
    var saveDocument: ((URL) throws -> Void)?
    /// PNG of the ImageCrat window, captured when Report a Bug… was chosen.
    var windowPNG: Data?
    /// Writes the canvas composite as PNG (the Metal canvas is not part of window snapshots).
    var saveCanvas: ((URL) throws -> Void)?
    var systemLines: () -> [(String, String)] = { [] }
}

enum BugReport {
    static var defaultCrashFolder: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports") }

    /// File-name prefixes of the app's own crash reports: `ImageCrat-*.ips`, and `Lumen-*.ips` from builds made before
    /// the rename (kept for the transition, so a tester's earlier crashes still reach the report).
    static let crashReportPrefixes = [Brand.executableName + "-", Brand.Legacy.executableName + "-"]

    /// ImageCrat's own crash reports (`ImageCrat-*.ips`, and the older `Lumen-*.ips`), newest first.
    static func crashReports(in folder: URL, limit: Int = 3) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let mine = items.filter { u in
            u.pathExtension == "ips" && crashReportPrefixes.contains(where: { u.lastPathComponent.hasPrefix($0) }) && (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return Array(mine.sorted { date($0) != date($1) ? date($0) > date($1) : $0.lastPathComponent > $1.lastPathComponent }.prefix(max(0, limit)))
    }

    private static func stamp(_ d: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: d)
    }

    /// "ImageCrat Bug Report 2026-10-02 23.41.zip" (Finder names can't contain ":").
    static func defaultFileName(_ now: Date = Date()) -> String { "ImageCrat Bug Report \(stamp(now, "yyyy-MM-dd HH.mm")).zip" }

    // MARK: Text

    static func section(_ title: String) -> String { "\n\(title)\n" + String(repeating: "-", count: title.count) + "\n" }

    private static func block(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "(not filled in)\n" : t + "\n"
    }

    /// Attachment file names in the zip.
    enum File {
        static let report = "report.txt"
        static let log = "log.txt"
        static let crashFolder = "crash-reports"
        static let window = "screenshot-window.png"
        static let canvas = "screenshot-canvas.png"
        static let documentFolder = "document"
    }

    /// The system / models / providers / preferences part (also used by Copy Summary).
    static func systemText(_ src: BugReportSources) -> String {
        var s = section("System")
        for (k, v) in src.systemLines() { s += "\(k): \(v)\n" }
        s += section("On-device AI models (\(src.modelsFolder))")
        for spec in src.specs {
            if src.installed(spec.id) {
                s += "  [installed]     \(spec.id) — \(spec.name), \(ModelPack.bytes(src.installedBytes(spec.id))) on disk, version \(spec.version)\n"
            } else {
                s += "  [not installed] \(spec.id) — \(spec.name)\(spec.isDownloadable ? "" : " (not downloadable: needs a models pack)")\n"
            }
        }
        for (k, v) in src.aiStatus() { s += "\(k): \(v)\n" }
        s += section("Generative AI providers (is a key stored? — keys are never included)")
        for p in ProviderID.allCases { s += "  \(p.displayName): \(src.keyStatus(p))\n" }
        s += section("Preferences that affect behaviour")
        for (k, v) in src.preferences() { s += "  \(k): \(v)\n" }
        return s
    }

    /// report.txt: the tester's text, what is attached, and (when ticked) system info and recent actions.
    static func reportText(_ text: BugReportText, _ o: BugReportOptions, _ src: BugReportSources, attachments: [String]) -> String {
        var s = "ImageCrat bug report\n====================\n"
        s += "Created: \(stamp(src.now, "yyyy-MM-dd HH:mm ZZZZZ"))\n"
        s += "ImageCrat \(AppInfo.version) (\(AppInfo.build))\n"
        s += section("What happened") + block(Redactor.userText(text.what, home: src.home))
        s += section("Steps to reproduce") + block(Redactor.userText(text.steps, home: src.home))
        s += section("What was expected") + block(Redactor.userText(text.expected, home: src.home))
        s += section("Included in this report")
        s += "  System info: \(o.systemInfo ? "yes (below)" : "no")\n"
        s += "  Recent actions: \(o.history ? "yes (below)" : "no")\n"
        s += "  Files: " + (attachments.isEmpty ? "none\n" : attachments.joined(separator: ", ") + "\n")
        s += "  API keys, prompts and passwords are never included; the home folder is shown as ~.\n"
        if o.systemInfo { s += systemText(src) }
        if o.history {
            let names = src.historyNames()
            s += section("Recent actions (history step names of the active document, oldest first)")
            s += names.isEmpty ? "  (no document open)\n" : names.map { "  \(Redactor.logLine($0, home: src.home))\n" }.joined()
        }
        return s
    }

    /// Copy Summary: the tester's text plus the essentials, as plain text.
    static func summaryText(_ text: BugReportText, _ o: BugReportOptions, _ src: BugReportSources) -> String {
        var s = "ImageCrat bug report — ImageCrat \(AppInfo.version) (\(AppInfo.build))\n"
        if o.systemInfo {
            let sys = Dictionary(src.systemLines(), uniquingKeysWith: { a, _ in a })
            s += [sys["macOS"], sys["Mac"]].compactMap { $0 }.joined(separator: " · ") + "\n"
        }
        s += "\nWhat happened:\n" + block(Redactor.userText(text.what, home: src.home))
        s += "\nSteps to reproduce:\n" + block(Redactor.userText(text.steps, home: src.home))
        s += "\nExpected:\n" + block(Redactor.userText(text.expected, home: src.home))
        return s
    }

    // MARK: Writing

    /// Writes the report files into `folder` (report.txt at the top). Returns the file names written.
    @discardableResult
    static func writeFolder(_ text: BugReportText, _ o: BugReportOptions, _ src: BugReportSources, to folder: URL) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var attachments: [String] = []
        if o.log {
            var lines = src.logLines()
            let prev = src.previousLogLines()
            var body = "ImageCrat log (status messages, warnings and errors; redacted: no keys, prompts, quoted names or full paths)\n\n"
            if !prev.isEmpty { body += "— previous run (last \(prev.count) lines) —\n" + prev.map { Redactor.logLine($0, home: src.home) }.joined(separator: "\n") + "\n\n— this run —\n" }
            if lines.isEmpty { lines = ["(no messages yet)"] }
            body += lines.map { Redactor.logLine($0, home: src.home) }.joined(separator: "\n") + "\n"
            try body.write(to: folder.appendingPathComponent(File.log), atomically: true, encoding: .utf8)
            attachments.append(File.log)
        }
        if o.crashReports {
            let reports = crashReports(in: src.crashFolder, limit: src.crashLimit)
            if !reports.isEmpty {
                let dir = folder.appendingPathComponent(File.crashFolder)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for r in reports {
                    // crash reports carry the app's path: keep them readable JSON, with the home folder as ~
                    let data = try Data(contentsOf: r)
                    let out = String(data: data, encoding: .utf8).map { Data(Redactor.homeFolder($0, home: src.home).utf8) } ?? data
                    try out.write(to: dir.appendingPathComponent(r.lastPathComponent))
                    attachments.append(File.crashFolder + "/" + r.lastPathComponent)
                }
            }
        }
        if o.screenshot {
            if let png = src.windowPNG {
                try png.write(to: folder.appendingPathComponent(File.window))
                attachments.append(File.window)
            }
            if let save = src.saveCanvas {
                try save(folder.appendingPathComponent(File.canvas))
                attachments.append(File.canvas)
            }
        }
        if o.document, let save = src.saveDocument {
            let dir = folder.appendingPathComponent(File.documentFolder)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let base = ((src.documentName ?? "Untitled") as NSString).deletingPathExtension
            let safe = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let name = (safe.isEmpty ? "Untitled" : safe) + "." + Brand.documentExtension
            try save(dir.appendingPathComponent(name))
            attachments.append(File.documentFolder + "/" + name)
        }
        let report = reportText(text, o, src, attachments: attachments)
        try report.write(to: folder.appendingPathComponent(File.report), atomically: true, encoding: .utf8)
        return [File.report] + attachments
    }

    /// Writes the report as one zip (report.txt at the top level of the archive). Returns the entries written.
    @discardableResult
    static func writeZip(_ text: BugReportText, _ o: BugReportOptions, _ src: BugReportSources, to zip: URL) throws -> [String] {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ImageCratBugReport-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let entries = try writeFolder(text, o, src, to: work)
        try? fm.removeItem(at: zip)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", work.path, zip.path]   // no --keepParent: the files sit at the top
        let err = Pipe()
        p.standardError = err
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, fm.fileExists(atPath: zip.path) else {
            throw NSError(domain: Brand.name, code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not write the zip file: "
                + (String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")])
        }
        DiagLog.shared.info("Bug report written (\(entries.count) files)")
        return entries
    }
}

// MARK: - Live sources

extension BugReportSources {
    /// The real app and Mac. `windowPNG` is the snapshot taken when the dialog opened.
    static func live(windowPNG: Data?, document d: Document?) -> BugReportSources {
        var s = BugReportSources()
        // automated runs (self tests, menu fuzzing, scripts) never read the person's real crash reports
        if GenAIKeyOverrides.realKeysBlocked { s.crashFolder = FileManager.default.temporaryDirectory.appendingPathComponent("imagecrat-no-crash-reports") }
        let mm = ModelManager.shared
        s.specs = mm.specs
        s.installed = { mm.isInstalled($0) }
        s.installedBytes = { mm.installedBytes($0) }
        s.modelsFolder = Redactor.paths(Redactor.homeFolder(ModelManager.root.path))
        let kc = GenAIKeychain.shared
        s.keyStatus = { p in kc.hasKey(p) ? "yes" : (kc.presenceKnown ? "no" : "no (still checking)") }
        s.preferences = { BugReportSources.livePreferences() }
        s.aiStatus = {
            [("SAM 3.1 engine", SAM3Engine.isAvailable ? "available" : (SAM3Engine.unavailableReason ?? "unavailable")),
             ("MLX Metal kernels", SAM3Engine.metalKernelsPresent ? "present" : "missing"),
             ("SAM 3.1 tokenizer", SAM3Resources.bundleURL.map { Redactor.paths(Redactor.homeFolder($0.path)) } ?? "missing")]
        }
        s.logLines = { DiagLog.shared.lines }
        s.previousLogLines = { DiagLog.shared.previousSession }
        s.systemLines = { BugReportSources.liveSystem() }
        if let d {
            s.historyNames = {
                d.history.map(\.name).suffix(40).map { Redactor.logLine($0) }
            }
            s.documentName = d.name
            s.documentBytes = BugReportSources.estimate(d)
            s.saveDocument = { url in try DocumentIO.saveNative(d, to: url) }
            let st = d.state
            s.saveCanvas = { url in
                let scale = min(1, 2048 / Double(max(1, max(st.width, st.height))))
                try DocumentIO.export(st, to: url, format: .png, quality: 1, scale: scale)
            }
        }
        s.windowPNG = windowPNG
        return s
    }

    static func estimate(_ d: Document) -> Int64 {
        let px = Int64(d.state.width) * Int64(d.state.height) * 4
        return px * Int64(max(1, d.state.allLayers.count))
    }

    static func liveSystem() -> [(String, String)] {
        var out: [(String, String)] = [
            (Brand.name, AppInfo.isAppBundle ? "\(AppInfo.version) (build \(AppInfo.build))" : "\(AppInfo.version) — development binary (not ImageCrat.app)"),
            ("macOS", AppInfo.macOS.replacingOccurrences(of: "Version ", with: "")),
            ("Mac", "\(AppInfo.modelIdentifier) · \(AppInfo.chip) · \(AppInfo.memoryGB) GB memory"),
            ("Displays", AppInfo.displays.isEmpty ? "none" : AppInfo.displays.joined(separator: ", ")),
            ("Language", Locale.preferredLanguages.prefix(2).joined(separator: ", ")),
        ]
        if let free = ModelPack.freeSpace(at: URL(fileURLWithPath: NSHomeDirectory())) { out.append(("Free disk space", ModelPack.bytes(free))) }
        out.append(("Documents open", "\(AppModel.shared.documents.count)"))
        return out
    }

    static func livePreferences() -> [(String, String)] {
        let p = AppModel.shared.prefs
        let g = GenAISettings.shared.data
        var out: [(String, String)] = [
            ("History states", "\(p.historyStates)"),
            ("Theme", p.theme.rawValue),
            ("Cache composite for large documents", p.cacheLargeDocuments ? "on (over \(Int(p.largeDocumentThreshold)) MP)" : "off"),
            ("Ruler / type units", "\(p.rulerUnits.rawValue) / \(p.typeUnits.rawValue)"),
            ("Fit documents on open", p.autoFitOnOpen ? "on" : "off"),
            ("Workspace", WorkspaceManager.shared.current.name),
            ("Move tool auto-select", AppModel.shared.moveAutoSelect ? "on" : "off"),
            ("Remove tool mode", NeuralRemove.shared.mode.rawValue + (NeuralRemove.shared.modeOverride == nil ? " (automatic)" : "")),
            ("Generative quality / variations", "\(g.quality) / \(g.variations)"),
            ("Remove tool uses cloud", g.removeUsesCloud ? "on" : "off"),
            ("Crop: generative expand", g.cropGenerativeExpand ? "on" : "off"),
            ("Ask before uploading", g.confirmUploads ? "on" : "off"),
        ]
        if !g.routing.isEmpty {
            out.append(("Generative model choices", g.routing.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }.joined(separator: ", ")))
        }
        return out
    }

    /// Snapshot of the main window's views (no Screen Recording permission needed). The Metal canvas isn't included.
    static func captureWindowPNG() -> Data? {
        let w = NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true && $0.isVisible }
            ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
        guard let v = w?.contentView, v.bounds.width > 1, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
