import Foundation

/// ImageCrat's own recent status messages, warnings and errors (for Help ▸ Report a Bug…): a small ring buffer in memory,
/// also appended to `~/Library/Application Support/ImageCrat/Logs/ImageCrat.log` (or `$LUMEN_SUPPORT_DIR/Logs`) so the lines
/// before a crash survive it. Automated runs (self tests, fuzzing, scripts) keep it in memory only.
///
/// Every message is redacted on the way in (`Redactor.logLine`): no API keys or key-like strings, no prompts or other
/// quoted text, no full file paths (home folder shown as `~`). File contents are never logged.
final class DiagLog: @unchecked Sendable {
    enum Level: String { case info = "INFO", status = "STATUS", warning = "WARN", error = "ERROR" }
    struct Entry: Equatable {
        var date: Date
        var level: Level
        var message: String
        var repeats = 1
    }

    static let shared = DiagLog(directory: DiagLog.defaultDirectory)
    static let defaultCapacity = 400
    static let maxMessage = 300
    static let maxFileBytes = 256 * 1024

    let capacity: Int
    let directory: URL?
    private let lock = NSLock()
    private var buffer: [Entry] = []
    /// The last lines of the previous run's log (read once at start), e.g. what happened just before a crash.
    private(set) var previousSession: [String] = []
    private let queue = DispatchQueue(label: "app.lumen.diaglog", qos: .utility)

    var fileURL: URL? { directory?.appendingPathComponent(Brand.name + ".log") }
    var previousFileURL: URL? { directory?.appendingPathComponent(Brand.name + ".previous.log") }

    static var defaultDirectory: URL? {
        if let o = ProcessInfo.processInfo.environment["LUMEN_SUPPORT_DIR"], !o.isEmpty { return URL(fileURLWithPath: o).appendingPathComponent("Logs") }
        if GenAIKeyOverrides.realKeysBlocked { return nil }   // automated run: memory only
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Brand.supportFolderName).appendingPathComponent("Logs")
    }

    init(directory: URL?, capacity: Int = DiagLog.defaultCapacity) {
        self.directory = directory
        self.capacity = max(10, capacity)
        guard let directory, let file = fileURL, let prev = previousFileURL else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // the previous run's log becomes ImageCrat.previous.log; this run starts a new file
        if fm.fileExists(atPath: file.path) {
            if let s = try? String(contentsOf: file, encoding: .utf8) {
                previousSession = s.split(separator: "\n", omittingEmptySubsequences: true).suffix(150).map(String.init)
            }
            try? fm.removeItem(at: prev)
            try? fm.moveItem(at: file, to: prev)
        }
    }

    // MARK: Recording

    func info(_ m: String) { record(.info, m) }
    func warning(_ m: String) { record(.warning, m) }
    func error(_ m: String) { record(.error, m) }

    func record(_ level: Level, _ message: String, date: Date = Date()) {
        var clean = Redactor.logLine(message)
        guard !clean.isEmpty else { return }
        if clean.count > DiagLog.maxMessage { clean = String(clean.prefix(DiagLog.maxMessage - 1)) + "…" }
        var appended: Entry?
        lock.lock()
        if var last = buffer.last, last.level == level, last.message == clean {
            last.repeats += 1; last.date = date
            buffer[buffer.count - 1] = last
        } else if level == .status, let last = buffer.last, last.level == .status, date.timeIntervalSince(last.date) < 1.5,
                  clean.prefix(16) == last.message.prefix(16) {
            // a progress message updating in place ("Exporting 12%…", "Exporting 13%…") keeps one line
            buffer[buffer.count - 1] = Entry(date: date, level: level, message: clean)
        } else {
            let e = Entry(date: date, level: level, message: clean)
            buffer.append(e)
            if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
            appended = e
        }
        lock.unlock()
        if let e = appended, let file = fileURL { queue.async { DiagLog.append(DiagLog.format(e), to: file) } }
    }

    var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return buffer }
    /// Formatted lines of this run, oldest first.
    var lines: [String] { entries.map(DiagLog.format) }

    func clear() { lock.lock(); buffer.removeAll(); lock.unlock() }
    /// Waits for pending file writes (tests).
    func flush() { queue.sync {} }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func format(_ e: Entry) -> String {
        let lvl = e.level.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)
        return "\(stamp.string(from: e.date)) \(lvl) \(e.message)\(e.repeats > 1 ? " (×\(e.repeats))" : "")"
    }

    private static func append(_ line: String, to file: URL) {
        let data = Data((line + "\n").utf8)
        let fm = FileManager.default
        if let h = try? FileHandle(forWritingTo: file) {
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            if size > UInt64(maxFileBytes) {
                // keep the newer half
                try? h.close()
                if let s = try? String(contentsOf: file, encoding: .utf8) {
                    let keep = s.split(separator: "\n").suffix(s.split(separator: "\n").count / 2).joined(separator: "\n") + "\n"
                    try? keep.write(to: file, atomically: true, encoding: .utf8)
                }
                if let h2 = try? FileHandle(forWritingTo: file) { _ = try? h2.seekToEnd(); try? h2.write(contentsOf: data); try? h2.close() }
                return
            }
            try? h.write(contentsOf: data)
        } else {
            fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}

/// Removes what must never leave the Mac in a bug report: API keys and key-like strings, prompts and other quoted text,
/// full file paths and the home folder (shown as `~`).
enum Redactor {
    /// Everything: for log lines and history step names.
    static func logLine(_ s: String, home: String = NSHomeDirectory()) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        t = homeFolder(t, home: home)
        t = prompts(t)
        t = quoted(t)
        t = keys(t)
        t = paths(t)
        return t
    }

    /// The tester's own text: keeps what they wrote, but no home folder and no key-like strings.
    static func userText(_ s: String, home: String = NSHomeDirectory()) -> String { keys(homeFolder(s, home: home)) }

    static func homeFolder(_ s: String, home: String = NSHomeDirectory()) -> String {
        guard home.count > 1 else { return s }
        var t = s.replacingOccurrences(of: "file://" + home, with: "~")
        t = t.replacingOccurrences(of: home, with: "~")
        // the same folder through /private or with a trailing slash variant
        if home.hasPrefix("/Users/") { t = t.replacingOccurrences(of: "/private" + home, with: "~") }
        return t
    }

    private static func regex(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: opts) }

    private static func replace(_ s: String, _ re: NSRegularExpression, _ f: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += f(m, ns)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static let promptJSON = regex(#"("(?:prompt|negative_prompt|text)"\s*:\s*)"(?:[^"\\]|\\.)*""#, [.caseInsensitive])
    private static let promptField = regex(#"\b((?:negative[ _])?prompt)\s*[:=]\s*.+$"#, [.caseInsensitive])
    static func prompts(_ s: String) -> String {
        var t = replace(s, promptJSON) { m, ns in ns.substring(with: m.range(at: 1)) + "\"[redacted]\"" }
        t = replace(t, promptField) { m, ns in ns.substring(with: m.range(at: 1)) + ": [redacted]" }
        return t
    }

    private static let quotes = regex(#"“[^”\n]*”|‘[^’\n]*’|(?<![^\s{\[,:(=])"[^"\n]{1,300}"(?!\s*:)"#)   // (JSON keys stay readable)
    private static let fileName = regex(#"^[^/\\]{0,200}\.([A-Za-z0-9]{2,5})$"#)
    /// Quoted text (layer and file names, prompts, typed text, JSON values) becomes “…”; a file name keeps its extension (“….psd”).
    static func quoted(_ s: String) -> String {
        replace(s, quotes) { m, ns in
            let whole = ns.substring(with: m.range)
            let open = String(whole.prefix(1)), close = String(whole.suffix(1))
            let inner = String(whole.dropFirst().dropLast()) as NSString
            if let f = fileName.firstMatch(in: inner as String, range: NSRange(location: 0, length: inner.length)) {
                return open + "…." + inner.substring(with: f.range(at: 1)) + close
            }
            return open + "…" + close
        }
    }

    private static let keyPatterns: [NSRegularExpression] = [
        regex(#"(?i)\bbearer\s+[A-Za-z0-9._\-:+/=]{6,}"#),
        regex(#"\b(?:sk|pk|rk)[-_][A-Za-z0-9_\-]{10,}"#),
        regex(#"\br8_[A-Za-z0-9]{10,}"#),
        regex(#"\bAIza[0-9A-Za-z_\-]{20,}"#),
    ]
    private static let keyField = regex(#"(?i)\b(api[_ -]?key|x-key|key|token|secret|authorization|password)(\s*[:=]\s*)(?!\[redacted)["']?[^\s"',;]{6,}["']?"#)
    private static let longToken = regex(#"[A-Za-z0-9_\-:+=]{32,}"#)
    static func keys(_ s: String) -> String {
        var t = s
        for re in keyPatterns { t = replace(t, re) { _, _ in "[redacted key]" } }
        t = replace(t, keyField) { m, ns in ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 2)) + "[redacted]" }
        // long letter + digit runs (tokens, keys, ids)
        t = replace(t, longToken) { m, ns in
            let v = ns.substring(with: m.range)
            let letters = v.contains { $0.isLetter }, digits = v.contains { $0.isNumber }
            return letters && digits ? "[redacted]" : v
        }
        return t
    }

    /// `~/a/b/c.png` → `~/…/c.png`, `/Volumes/X/y.png` → `…/y.png`. URLs (`https://…`) are left alone.
    private static let path = regex(#"(?<![^\s(\[“"'=,])(~/|/)(?:[^/\s“”"](?:[^/\n“”"]*[^/\s“”"])?/)+[^/\s“”"),;]+"#)   // (folder names may contain spaces, not end in one)
    static func paths(_ s: String) -> String {
        replace(s, path) { m, ns in
            let whole = ns.substring(with: m.range)
            let last = (whole as NSString).lastPathComponent
            return (whole.hasPrefix("~/") ? "~/…/" : "…/") + last
        }
    }
}
