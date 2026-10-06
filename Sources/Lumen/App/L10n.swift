import AppKit
import SwiftUI
import Observation
import ObjectiveC

// MARK: - Localization (English / Estonian)
//
// Strings are keyed by their English source text. The Estonian table is `Resources/et.lproj/Localizable.strings`
// (copied into the app bundle by scripts/build_app.sh; a bare `swift build` binary reads it from the source tree).
//
// - SwiftUI literals (`Text("Layers")`, `Button("OK")`, `.help("…")`, `Toggle("…")`, `Picker("…")`, …) are looked up
//   through the main bundle, which `L10n.install()` routes to `L10n.shared` (`L10nBundle`). The environment locale set by
//   `.l10nRoot()` changes with the language, so SwiftUI resolves them again when it switches.
// - Everything else goes through `tr(_:)`: strings built at runtime, AppKit (`NSAlert`, menus, tool tips), catalogue
//   names (filters, blend modes, tools, panels…). Model values stay English (identifiers, history step names, layer
//   names, recorded actions, scripting names); only what is displayed is translated.
// - `LUMEN_PSEUDO_L10N=1` replaces every translated string with a longer, accented pseudo-translation (⟦…⟧): text that
//   shows up without the brackets did not go through the localization layer.
// - Self tests and other automated runs always use English (nothing read from or written to the real preferences).

/// The interface language the user picked.
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system, en, et
    var id: String { rawValue }
    /// Language names are shown in their own language (as macOS does).
    var title: String {
        switch self {
        case .system: return tr("System Default")
        case .en: return "English"
        case .et: return "Eesti"
        }
    }
}

@Observable
final class L10n {
    static let shared = L10n()

    /// Languages that have a table (besides the English source).
    static let supported = ["en", "et"]
    static let defaultsKey = "ImageCrat.Language"
    /// Posted (main thread) after the language changed and the tables were swapped.
    static let didChange = Notification.Name("ImageCrat.L10n.didChange")

    /// What the user picked (Preferences ▸ General ▸ Language, ImageCrat ▸ Language).
    private(set) var choice: AppLanguage = .system
    /// The language in effect: "en" or "et".
    private(set) var code: String = "en"
    /// Bumped on every switch (views and menus that cache titles compare it).
    private(set) var revision = 0

    /// Pseudo-localization (`LUMEN_PSEUDO_L10N=1`, or a test).
    @ObservationIgnored var pseudo: Bool = ProcessInfo.processInfo.environment["LUMEN_PSEUDO_L10N"] == "1"
    /// Automated runs (self test, fuzz, automation): English, nothing persisted.
    @ObservationIgnored let automated: Bool
    @ObservationIgnored private var store: UserDefaults?

    // Tables of the current language (empty for English).
    @ObservationIgnored private var table: [String: String] = [:]
    @ObservationIgnored private var normalizedTable: [String: String] = [:]
    @ObservationIgnored private var reverseTable: [String: String] = [:]
    @ObservationIgnored private var templates: [Template] = []
    @ObservationIgnored private var templatesBuilt = false
    @ObservationIgnored private var cache: [String: String] = [:]
    @ObservationIgnored private let lock = NSLock()
    /// Where the Estonian table was read from (diagnostics).
    @ObservationIgnored private(set) var tableURL: URL?
    /// Whether some part of the window needs a restart to show the new language (see `restartRecommended`).
    @ObservationIgnored private(set) var launchCode = "en"

    private init() {
        let args = CommandLine.arguments
        let env = ProcessInfo.processInfo.environment
        automated = args.contains("--selftest") || args.contains("--perftest") || env["LUMEN_AUTOMATION"] == "1" || env["LUMEN_FUZZ"] != nil
        store = automated ? nil : UserDefaults.standard
        if let forced = env["LUMEN_LANGUAGE"].flatMap(AppLanguage.init(rawValue:)) {
            choice = forced
        } else if let s = store?.string(forKey: L10n.defaultsKey), let c = AppLanguage(rawValue: s) {
            choice = c
        } else {
            choice = .system
        }
        // automated runs are English whatever the Mac's language list says (string checks expect English)
        code = automated && env["LUMEN_LANGUAGE"] == nil ? "en" : L10n.resolve(choice)
        launchCode = code
        loadTables()
    }

    /// "en" or "et" for a choice; `.system` follows the macOS language list (first of English / Estonian in it).
    static func resolve(_ c: AppLanguage, preferred: [String] = Locale.preferredLanguages) -> String {
        switch c {
        case .en: return "en"
        case .et: return "et"
        case .system:
            for p in preferred {
                let lang = String(p.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
                if supported.contains(lang) { return lang }
            }
            return "en"
        }
    }

    var isEnglish: Bool { code == "en" }

    /// The language AppKit picked at launch for its own strings (system panels, standard menu items).
    static let appKitLanguage: String = Bundle(for: NSApplication.self).preferredLocalizations.first ?? "en"

    /// Some of macOS's own interface (Open / Save panels, text-field context menus) only follows a language picked
    /// here after a restart: true when it currently shows another language than the one it will use then.
    var restartRecommended: Bool {
        guard choice != .system, !automated else { return false }
        return !L10n.appKitLanguage.lowercased().hasPrefix("en")
    }

    /// Switches the interface language (live). Persisted unless this is an automated run.
    func set(_ c: AppLanguage, persist: Bool = true) {
        let newCode = L10n.resolve(c)
        choice = c
        if persist, let store {
            store.set(c.rawValue, forKey: L10n.defaultsKey)
            // macOS's own parts (Open / Save panels, text-field menus) follow the app's language list from the next
            // launch on: English for both (macOS has no Estonian). "System Default" leaves the Mac's list alone.
            if c == .system { store.removeObject(forKey: "AppleLanguages") } else { store.set([newCode, "en"], forKey: "AppleLanguages") }
        }
        guard newCode != code else { return }
        code = newCode
        loadTables()
        revision += 1
        L10nMenus.retitle()
        L10nAppKit.refreshAll()
        NotificationCenter.default.post(name: L10n.didChange, object: self)
    }

    /// Tests: switch without touching the preferences (and optionally turn pseudo-localization on or off).
    func setForTesting(_ c: AppLanguage, pseudo p: Bool? = nil) {
        if let p, p != pseudo {
            pseudo = p
            lock.lock(); cache = [:]; lock.unlock()
            revision += 1
        }
        let before = revision
        set(c, persist: false)
        if revision == before, p != nil { L10nMenus.retitle(); NotificationCenter.default.post(name: L10n.didChange, object: self) }
    }

    /// The locale SwiftUI views get (`.l10nRoot()`): the Mac's formats (numbers, dates) as before, but a different
    /// value per language, so SwiftUI looks its literal strings up again when the language changes.
    var swiftUILocale: Locale {
        let base = Locale.current.identifier
        if code == "en" && !pseudo { return .autoupdatingCurrent }   // (what SwiftUI uses anyway: English is unchanged)
        return Locale(identifier: base + (base.contains("@") ? ";" : "@") + "imagecrat=\(code)\(pseudo ? "x" : "")")
    }

    // MARK: Tables

    private func loadTables() {
        lock.lock(); defer { lock.unlock() }
        cache = [:]
        templates = []
        templatesBuilt = false
        if code == "en" {
            table = [:]; normalizedTable = [:]; reverseTable = [:]
            return
        }
        let (t, url) = L10n.loadTable(code)
        tableURL = url
        table = t
        var n: [String: String] = [:]
        var r: [String: String] = [:]
        for (k, v) in t {
            // "menu::Edit" = "Redigeerimine": a context-specific translation; its reverse is the English part
            if let sep = k.range(of: "::") {
                let english = String(k[sep.upperBound...])
                if r[v] == nil { r[v] = english }
                continue
            }
            let nk = L10nFormat.normalize(k)
            if n[nk] == nil { n[nk] = v }
            if r[v] == nil || k.count < (r[v]?.count ?? 0) { r[v] = k }
        }
        normalizedTable = n
        reverseTable = r
    }

    /// Reads `<lang>.lproj/Localizable.strings`: `LUMEN_L10N_DIR`, then the app bundle, then (a bare `swift build`
    /// binary) the source tree's `Resources/` above the executable.
    static func loadTable(_ lang: String) -> ([String: String], URL?) {
        for url in tableCandidates(lang) {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let d = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: String] { return (d, url) }
        }
        return ([:], nil)
    }

    static func tableCandidates(_ lang: String) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        if let dir = ProcessInfo.processInfo.environment["LUMEN_L10N_DIR"], !dir.isEmpty {
            out.append(URL(fileURLWithPath: dir).appendingPathComponent("\(lang).lproj/Localizable.strings"))
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(lang).lproj/Localizable.strings")
        if fm.fileExists(atPath: bundled.path) { out.append(bundled) }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<7 {
                let u = dir.appendingPathComponent("Resources/\(lang).lproj/Localizable.strings")
                if fm.fileExists(atPath: u.path) { out.append(u); break }
                dir = dir.deletingLastPathComponent()
            }
        }
        return out
    }

    /// Number of Estonian entries loaded (0 in English).
    var entryCount: Int { lock.lock(); defer { lock.unlock() }; return table.count }

    /// The translation of an English key, nil when there is none (no pseudo-localization, no fallback).
    func translation(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return table[key] ?? normalizedTable[L10nFormat.normalize(key)]
    }

    /// Whether the current language has an entry for `s` (also with an ending: "Plasma…", "Opacity:"), or a template
    /// that explains it.
    func hasTranslation(_ s: String) -> Bool {
        if isEnglish { return false }
        if translation(s) != nil { return true }
        let (_, core) = L10nMenus.splitMark(s)
        if translation(core) != nil { return true }
        return peeled(core) != nil || templateMatch(core) != nil
    }

    /// The English key a displayed (current-language) string came from, or the string itself.
    func english(_ shown: String) -> String {
        if pseudo, let e = L10nPseudo.unwrap(shown) { return english(e) }
        guard code != "en" else { return shown }
        lock.lock(); defer { lock.unlock() }
        return reverseTable[shown] ?? shown
    }

    // MARK: Lookup

    /// A key as SwiftUI hands it over (`"Opacity %lld%%"`, format specifiers of the interpolated values): the
    /// translation with the same specifiers, for SwiftUI to format.
    func swiftUIString(_ key: String) -> String {
        if code == "en" && !pseudo { return key }
        var out = key
        if code != "en" {
            lock.lock()
            let hit = table[key] ?? normalizedTable[L10nFormat.normalize(key)]
            lock.unlock()
            if let hit { out = L10nFormat.restoreSpecifiers(translation: hit, key: key) }
        }
        return pseudo ? L10nPseudo.transform(out) : out
    }

    /// A plain string (no format arguments): exact match, then a template match for strings built at runtime
    /// ("New Curves Layer" ← "New %@ Layer"), else the string itself.
    func string(_ s: String) -> String {
        if code == "en" && !pseudo { return s }
        if s.isEmpty { return s }
        lock.lock()
        if let c = cache[s] { lock.unlock(); return c }
        lock.unlock()
        var out = s
        if code != "en" {
            if let hit = translation(s) {
                out = L10nFormat.format(hit, args: [])
            } else if let t = templateMatch(s) {
                out = t
            } else if let p = peeled(s) {
                out = p
            }
        }
        if pseudo, !L10nFormat.looksLikeNoText(s) { out = L10nPseudo.transform(out) }
        lock.lock()
        if cache.count > 20000 { cache = [:] }
        cache[s] = out
        lock.unlock()
        return out
    }

    /// A string with interpolated arguments (`tr("Opacity \(x)%")`): key "Opacity %@%%", args ["50"].
    func format(_ key: String, args: [String]) -> String {
        var t = key
        if code != "en", let hit = translation(key) { t = hit }
        let out = L10nFormat.format(t, args: args)
        if pseudo { return L10nPseudo.transform(out, alreadyFormatted: true) }
        return out
    }

    /// "Gaussian Blur…", "Opacity:", "Layer Comps *": the translation of the stem with the same ending.
    private func peeled(_ s: String) -> String? {
        for suffix in ["…", "...", ":", " *", " ▸"] where s.hasSuffix(suffix) && s.count > suffix.count {
            let stem = String(s.dropLast(suffix.count))
            if let hit = translation(stem) { return L10nFormat.format(hit, args: []) + suffix }
            if let hit = translation(stem + "…") , suffix == "..." { return L10nFormat.format(hit, args: []) }
        }
        for prefix in ["✓ ", "• ", "— "] where s.hasPrefix(prefix) && s.count > prefix.count {
            let stem = String(s.dropFirst(prefix.count))
            if let hit = translation(stem) { return prefix + L10nFormat.format(hit, args: []) }
        }
        return nil
    }

    // MARK: Templates (runtime-built strings)

    private struct Template {
        let key: String
        let translation: String
        let prefix: String
        let suffix: String
        let regex: NSRegularExpression
        let weight: Int
        /// Slots written between quotes in the English (“%@”): any text may stand there (a name, a file).
        let quoted: [Bool]
    }

    private func buildTemplates() {
        guard !templatesBuilt else { return }
        templatesBuilt = true
        var out: [Template] = []
        for (k, v) in table where k.contains("%") && !k.contains("::") {
            let parts = L10nFormat.split(k)
            guard parts.slots > 0 else { continue }
            let literal = parts.literals.joined()
            // too little fixed text matches anything ("%@ %@", "%@:", "%@s")
            guard literal.filter(\.isLetter).count >= 3 else { continue }
            let quotes: Set<Character> = ["“", "”", "\"", "„", "'", "‘", "’", "«", "»"]
            var quoted: [Bool] = []
            for i in 0..<parts.slots {
                let before = parts.literals[i].last, after = parts.literals[i + 1].first
                quoted.append(before.map { quotes.contains($0) } == true && after.map { quotes.contains($0) } == true)
            }
            var pattern = "^"
            for (i, lit) in parts.literals.enumerated() {
                pattern += NSRegularExpression.escapedPattern(for: lit)
                if i < parts.literals.count - 1 { pattern += "(.+?)" }
            }
            pattern += "$"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { continue }
            out.append(Template(key: k, translation: v, prefix: parts.literals.first ?? "", suffix: parts.literals.last ?? "", regex: re, weight: literal.count, quoted: quoted))
        }
        templates = out.sorted { $0.weight > $1.weight }
    }

    private func templateMatch(_ s: String) -> String? {
        lock.lock()
        buildTemplates()
        let list = templates
        lock.unlock()
        let ns = s as NSString
        for t in list where s.hasPrefix(t.prefix) && s.hasSuffix(t.suffix) && s.count > t.prefix.count + t.suffix.count {
            guard let m = t.regex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else { continue }
            // A template only explains a string when its values look like values: numbers, quoted names, file
            // paths, or names the table knows ("Add %@" ← "Add Ellipse Ruler"). Otherwise "%@ Preset %@" would
            // claim "New Brush Preset from Current Settings…".
            let ratio = Double(t.weight) / Double(max(1, s.count))
            var plausible = true
            for i in 1..<m.numberOfRanges where ratio < 0.5 {
                let a = ns.substring(with: m.range(at: i))
                let isQuoted = i - 1 < t.quoted.count && t.quoted[i - 1]
                let valueLike = !a.contains(where: \.isLetter) || isQuoted || a.contains("/") || a.range(of: #"\.[A-Za-z0-9]{2,5}$"#, options: .regularExpression) != nil
                let known = translation(a) != nil || (a.first?.isLowercase == true && translation(a.prefix(1).uppercased() + a.dropFirst()) != nil)
                if !(valueLike || known || (ratio >= 0.34 && !a.contains(" "))) { plausible = false; break }
            }
            guard plausible else { continue }
            var args: [String] = []
            for i in 1..<m.numberOfRanges {
                let a = ns.substring(with: m.range(at: i))
                // arguments that are themselves catalogue names ("Curves", "Gaussian Blur") are translated too
                // (also lower-cased ones: "people" ← "People")
                if let hit = translation(a) {
                    args.append(L10nFormat.format(hit, args: []))
                } else if let f = a.first, f.isLowercase, let hit = translation(f.uppercased() + a.dropFirst()) {
                    let t = L10nFormat.format(hit, args: [])
                    args.append((t.first.map { String($0).lowercased() } ?? "") + t.dropFirst())
                } else {
                    args.append(a)
                }
            }
            return L10nFormat.format(t.translation, args: args)
        }
        return nil
    }

    /// Clears per-string caches (tests that swap tables).
    func reload() {
        loadTables()
        revision += 1
        NotificationCenter.default.post(name: L10n.didChange, object: self)
    }
}

// MARK: - tr()

/// A string literal with interpolations kept apart: `tr("Opacity \(v)%")` looks up "Opacity %@%%".
struct L10nString: ExpressibleByStringInterpolation {
    var key: String
    var args: [String]
    var hasFormat: Bool

    init(stringLiteral value: String) { key = value; args = []; hasFormat = false }
    init(verbatim value: String) { key = value; args = []; hasFormat = false }

    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var args: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity + interpolationCount * 2) }
        mutating func appendLiteral(_ literal: String) { key += literal.replacingOccurrences(of: "%", with: "%%") }
        mutating func appendInterpolation<T>(_ value: T) { key += "%@"; args.append("\(value)") }
        mutating func appendInterpolation<T: CVarArg>(_ value: T, specifier: String) { key += "%@"; args.append(String(format: specifier, value)) }
        mutating func appendInterpolation(_ value: String) { key += "%@"; args.append(value) }
    }

    init(stringInterpolation i: StringInterpolation) { key = i.key; args = i.args; hasFormat = true }

    /// The English text (no lookup).
    var english: String { hasFormat ? L10nFormat.format(key, args: args) : key }
}

/// The current-language text of a string literal (interpolations allowed).
func tr(_ s: L10nString) -> String {
    s.hasFormat ? L10n.shared.format(s.key, args: s.args) : L10n.shared.string(s.key)
}

/// The current-language text of a runtime string (catalogue names, registry titles, stored English names). Strings
/// without a translation come back unchanged.
/// (Generic and disfavoured, so that a literal — also one with interpolations — picks `tr(_: L10nString)`.)
@_disfavoredOverload
func tr<S: StringProtocol>(_ s: S) -> String { L10n.shared.string(String(s)) }

/// A literal that has a context-specific translation (`"ctx::English"` in the table), else the plain one.
func tr(_ s: String, context: String) -> String {
    let l = L10n.shared
    if !l.isEnglish, let hit = l.translation(context + "::" + s) { return l.pseudo ? L10nPseudo.transform(hit) : hit }
    return l.string(s)
}

// MARK: - Format helpers

enum L10nFormat {
    /// printf specifiers as SwiftUI and Foundation write them (`%@`, `%lld`, `%1$@`, `%.1f` …).
    static let specifier = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?[-+0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGaAcCsSp]|%%"#)

    struct Parts { var literals: [String]; var slots: Int }

    /// Splits a key at its specifiers ("%%" stays text, as "%").
    static func split(_ s: String) -> Parts {
        let ns = s as NSString
        var lits: [String] = []
        var cur = ""
        var last = 0
        var slots = 0
        for m in specifier.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            cur += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let tok = ns.substring(with: m.range)
            if tok == "%%" { cur += "%" } else { lits.append(cur); cur = ""; slots += 1 }
            last = m.range.location + m.range.length
        }
        cur += ns.substring(from: last)
        lits.append(cur)
        return Parts(literals: lits, slots: slots)
    }

    /// Every specifier as "%@" (positions dropped): SwiftUI's "%lld" and the extractor's "%@" meet here.
    static func normalize(_ s: String) -> String {
        guard s.contains("%") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in specifier.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let tok = ns.substring(with: m.range)
            out += tok == "%%" ? "%%" : "%@"
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// The specifiers of `key` (in order), "%%" excluded.
    static func specifiers(_ s: String) -> [String] {
        let ns = s as NSString
        return specifier.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }.filter { $0 != "%%" }
    }

    /// The type part of a specifier ("%1$lld" → "lld", "%@" → "@", "%.1f" → ".1f").
    static func typePart(_ spec: String) -> String {
        var t = Substring(spec.dropFirst())
        if let d = t.firstIndex(of: "$") { t = t[t.index(after: d)...] }
        return String(t)
    }

    /// The translation with the key's own specifiers (by position): SwiftUI formats it with the original arguments.
    static func restoreSpecifiers(translation: String, key: String) -> String {
        let keySpecs = specifiers(key)
        guard !keySpecs.isEmpty else {
            // a key without arguments: a "%" in it is plain text
            return translation.replacingOccurrences(of: "%%", with: "%")
        }
        let ns = translation as NSString
        let matches = specifier.matches(in: translation, range: NSRange(location: 0, length: ns.length))
        let trSpecs = matches.map { ns.substring(with: $0.range) }.filter { $0 != "%%" }
        let positional = trSpecs.contains { $0.contains("$") } || trSpecs.count != keySpecs.count
        var out = ""
        var last = 0
        var seq = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let tok = ns.substring(with: m.range)
            last = m.range.location + m.range.length
            if tok == "%%" { out += "%%"; continue }
            var index = seq
            if m.range(at: 1).location != NSNotFound, let n = Int(ns.substring(with: m.range(at: 1))) { index = n - 1 } else { seq += 1 }
            guard index >= 0, index < keySpecs.count else { continue }
            let type = typePart(keySpecs[index])
            out += positional ? "%\(index + 1)$\(type)" : "%\(type)"
        }
        out += ns.substring(from: last)
        return out
    }

    /// Fills "%@" / "%1$@" (any specifier) with `args`; "%%" becomes "%". Without args the text is returned as is
    /// (a key without interpolation keeps its "%" signs).
    static func format(_ t: String, args: [String]) -> String {
        guard t.contains("%") else { return t }
        if args.isEmpty && !t.contains("%%") { return t }
        let ns = t as NSString
        var out = ""
        var last = 0
        var seq = 0
        for m in specifier.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let tok = ns.substring(with: m.range)
            last = m.range.location + m.range.length
            if tok == "%%" { out += "%"; continue }
            var index = seq
            if m.range(at: 1).location != NSNotFound, let n = Int(ns.substring(with: m.range(at: 1))) { index = n - 1 } else { seq += 1 }
            out += index >= 0 && index < args.count ? args[index] : ""
        }
        out += ns.substring(from: last)
        return out
    }

    /// Numbers, units, symbols: nothing to translate (pseudo-localization leaves them alone).
    static func looksLikeNoText(_ s: String) -> Bool { !s.contains(where: \.isLetter) }
}

// MARK: - Pseudo-localization

enum L10nPseudo {
    static let open = "⟦", close = "⟧"
    private static let map: [Character: Character] = [
        "a": "á", "b": "ƀ", "c": "ç", "d": "đ", "e": "é", "f": "ƒ", "g": "ĝ", "h": "ĥ", "i": "í", "j": "ĵ", "k": "ķ", "l": "ļ", "m": "ɱ",
        "n": "ñ", "o": "ö", "p": "þ", "r": "ŕ", "s": "š", "t": "ŧ", "u": "ü", "w": "ŵ", "y": "ý", "z": "ž",
        "A": "Á", "C": "Ç", "D": "Đ", "E": "É", "G": "Ĝ", "H": "Ĥ", "I": "Í", "J": "Ĵ", "K": "Ķ", "L": "Ļ", "N": "Ñ", "O": "Ö", "R": "Ŕ",
        "S": "Š", "T": "Ŧ", "U": "Ü", "W": "Ŵ", "Y": "Ý", "Z": "Ž",
    ]

    /// "Layers" → "⟦Ļáýéŕš··⟧": accented letters, ~35 % longer, specifiers kept.
    static func transform(_ s: String, alreadyFormatted: Bool = false) -> String {
        if s.hasPrefix(open) || s.isEmpty { return s }
        var out = ""
        let ns = s as NSString
        var last = 0
        let matches = alreadyFormatted ? [] : L10nFormat.specifier.matches(in: s, range: NSRange(location: 0, length: ns.length))
        func accent(_ t: String) -> String { String(t.map { map[$0] ?? $0 }) }
        for m in matches {
            out += accent(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            out += ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += accent(ns.substring(from: last))
        let pad = String(repeating: "·", count: max(1, s.count * 35 / 100))
        return open + out + pad + close
    }

    /// The accented text inside ⟦…⟧ with the padding removed and the accents mapped back, nil for other strings.
    static func unwrap(_ s: String) -> String? {
        guard s.hasPrefix(open), s.hasSuffix(close) else { return nil }
        var inner = String(s.dropFirst().dropLast())
        while inner.hasSuffix("·") { inner.removeLast() }
        let back = Dictionary(map.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        return String(inner.map { back[$0] ?? $0 })
    }

    static func isPseudo(_ s: String) -> Bool { s.contains(open) }
}

// MARK: - Bundle hook (SwiftUI literals, NSLocalizedString)

/// The main bundle's class is swapped for this one (`L10n.install()`): string lookups of the default table come from
/// `L10n.shared` in the language picked in ImageCrat, not the one macOS chose at launch.
final class L10nBundle: Bundle, @unchecked Sendable {
    private static func ours(_ table: String?) -> Bool { table == nil || table == "" || table == "Localizable" }

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        guard L10nBundle.ours(tableName) else { return super.localizedString(forKey: key, value: value, table: tableName) }
        let k = key.isEmpty ? (value ?? "") : key
        return L10n.shared.swiftUIString(k)
    }

    override func __localizedAttributedString(forKey key: String, value: String?, table tableName: String?) -> NSAttributedString {
        guard L10nBundle.ours(tableName) else { return super.__localizedAttributedString(forKey: key, value: value, table: tableName) }
        return NSAttributedString(string: L10n.shared.swiftUIString(key))
    }

    // SwiftUI asks with the environment locale's localization; the language is ImageCrat's, whatever that says.
    @objc(localizedAttributedStringForKey:value:table:localization:)
    func l10nAttributed(_ key: String, value: String?, table tableName: String?, localization: String?) -> NSAttributedString {
        __localizedAttributedString(forKey: key, value: value, table: tableName)
    }

    @objc(localizedStringForKey:value:table:localization:)
    func l10nString(_ key: String, value: String?, table tableName: String?, localization: String?) -> String {
        localizedString(forKey: key, value: value, table: tableName)
    }
}

extension L10n {
    private static var installed = false
    /// Routes the main bundle's string lookups through `L10n` (once, at launch, before any view is built).
    static func install() {
        guard !installed else { return }
        installed = true
        if type(of: Bundle.main) == Bundle.self { object_setClass(Bundle.main, L10nBundle.self) }
        _ = shared
        L10nMenus.installTracking()
    }
}

// MARK: - SwiftUI

/// Applies the interface language to a SwiftUI hierarchy (every hosting view's root).
struct L10nRoot: ViewModifier {
    func body(content: Content) -> some View {
        let l = L10n.shared
        _ = l.revision   // observed: a switch re-renders the hierarchy
        return content.environment(\.locale, l.swiftUILocale)
    }
}

extension View {
    /// The interface language for this hierarchy (literal `Text`s are looked up again when it changes).
    func l10nRoot() -> some View { modifier(L10nRoot()) }
}

// MARK: - AppKit menus

/// Menu titles in the current language. SwiftUI builds the menu bar from the same lookups; AppKit's own items (Hide,
/// Quit, Services, Enter Full Screen…) and items SwiftUI keeps from before a switch are retitled here — after every
/// switch and whenever a menu opens. Each item remembers its English title, so switching back is exact.
enum L10nMenus {
    private static var englishKey: UInt8 = 0
    private static var shownKey: UInt8 = 0

    /// AppKit's standard items (AppKit has no Estonian; the app adds these).
    static let l10nKeys: [String] = [
        "Services", "Hide %@", "Hide Others", "Show All", "Quit %@", "About %@", "Settings…", "Preferences…",
        "Start Dictation…", "Emoji & Symbols", "AutoFill", "Enter Full Screen", "Exit Full Screen", "Bring All to Front",
        "Minimize", "Zoom", "Window", "Help", "Edit", "View", "File", "Show Tab Bar", "Hide Tab Bar", "Show All Tabs",
        "Move & Resize", "Fill", "Center", "Return to Previous Size", "Full Screen Tile", "Remove Window from Set",
        "Tile Window to Left of Screen", "Tile Window to Right of Screen", "Replace Tiled Window", "Merge All Windows",
        "Search", "Writing Tools", "Spelling and Grammar", "Substitutions", "Transformations", "Speech", "Format",
        "Show Spelling and Grammar", "Check Document Now", "Check Spelling While Typing", "Check Grammar With Spelling",
        "Correct Spelling Automatically", "Smart Copy/Paste", "Smart Quotes", "Smart Dashes", "Smart Links", "Data Detectors",
        "Text Replacement", "Make Upper Case", "Make Lower Case", "Capitalize", "Start Speaking", "Stop Speaking",
        "Show Toolbar", "Hide Toolbar", "Customize Toolbar…", "Show Sidebar", "Hide Sidebar", "Select All", "Delete",
        "Undo", "Redo", "Cut", "Copy", "Paste", "Paste and Match Style", "Close", "Close All", "Find", "Find…",
    ]

    static func installTracking() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            guard let m = note.object as? NSMenu else { return }
            retitle(m)
        }
        // SwiftUI builds (and later rebuilds) the menu bar after launch, with AppKit's English titles for the standard
        // menus (File, Edit, View, Window, Help). Retitle the bar whenever it changes, coalesced, and once the app is up.
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification, NSMenu.didRemoveItemNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let m = note.object as? NSMenu, m === NSApp?.mainMenu else { return }
                scheduleMenuBarRetitle()
            }
        }
        for name in [NSApplication.didFinishLaunchingNotification, NSApplication.didBecomeActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in scheduleMenuBarRetitle() }
        }
        scheduleMenuBarRetitle()
    }

    nonisolated(unsafe) private static var menuBarRetitlePending = false
    nonisolated(unsafe) private static var retitlingMenuBar = false

    /// One retitle of the whole menu bar on the next run-loop turn, however many menu changes arrive before it.
    /// Our own title changes post didChangeItem too; the flag keeps them from scheduling another pass.
    static func scheduleMenuBarRetitle() {
        guard !menuBarRetitlePending, !retitlingMenuBar else { return }
        menuBarRetitlePending = true
        DispatchQueue.main.async {
            menuBarRetitlePending = false
            retitlingMenuBar = true
            retitle()
            retitlingMenuBar = false
        }
    }

    /// Retitles the menu bar (or one menu) for the current language.
    static func retitle(_ root: NSMenu? = nil) {
        guard let menu = root ?? NSApp?.mainMenu else { return }
        walk(menu, depth: 0)
    }

    private static func walk(_ menu: NSMenu, depth: Int) {
        guard depth < 12 else { return }
        for item in menu.items where !item.isSeparatorItem {
            retitle(item)
            if let sub = item.submenu {
                if !sub.title.isEmpty, sub.title != item.title, !isAppMenu(item) { sub.title = display(english(of: sub.title, item: nil)) }
                else if sub.title == item.title || sub.title.isEmpty { if !isAppMenu(item) { sub.title = item.title } }
                walk(sub, depth: depth + 1)
            }
        }
    }

    private static func isAppMenu(_ item: NSMenuItem) -> Bool {
        guard let main = NSApp?.mainMenu, item.menu === main else { return false }
        return main.items.first === item
    }

    private static func retitle(_ item: NSMenuItem) {
        if isAppMenu(item) { return }   // the application menu is named after the app
        let title = item.title
        guard !title.isEmpty else { return }
        let e = english(of: title, item: item)
        let shown = display(e)
        objc_setAssociatedObject(item, &englishKey, e, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(item, &shownKey, shown, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if shown != title { item.title = shown }
    }

    /// The English title of an item: what we put there last time (unless someone changed the title since), else the
    /// reverse lookup of the current title.
    static func english(of title: String, item: NSMenuItem?) -> String {
        if let item, let shown = objc_getAssociatedObject(item, &shownKey) as? String, shown == title,
           let e = objc_getAssociatedObject(item, &englishKey) as? String { return e }
        let (prefix, core) = splitMark(title)
        var e = L10n.shared.english(core)
        if e == core, let p = L10nPseudo.unwrap(core) { e = L10n.shared.english(p) }
        return prefix + e
    }

    /// The current-language title of an English one (check-mark prefixes kept; app-name items translated by template).
    static func display(_ english: String) -> String {
        let (prefix, core) = splitMark(english)
        return prefix + tr(core, context: "menu")   // ("menu::Edit" = the Edit menu's own name, if the table has one)
    }

    /// "✓ RGB Color" / "    RGB Color" → ("✓ ", "RGB Color").
    static func splitMark(_ s: String) -> (String, String) {
        if s.hasPrefix("✓ ") { return ("✓ ", String(s.dropFirst(2))) }
        let lead = s.prefix { $0 == " " }
        if !lead.isEmpty { return (String(lead), String(s.dropFirst(lead.count))) }
        return ("", s)
    }

    /// Menu items whose title is not translated in the current language (for the l10n self test).
    static func untranslated(_ root: NSMenu? = nil, allow: (String) -> Bool) -> [String] {
        guard let menu = root ?? NSApp?.mainMenu else { return [] }
        var out: [String] = []
        func walk(_ m: NSMenu, _ path: [String], _ depth: Int) {
            guard depth < 12 else { return }
            for item in m.items where !item.isSeparatorItem && !item.isHidden {
                if isAppMenu(item) { if let s = item.submenu { walk(s, path + ["App"], depth + 1) }; continue }
                let (_, core) = splitMark(item.title)
                let english = splitMark(L10nMenus.english(of: item.title, item: item)).1
                let translated: Bool
                if L10n.shared.pseudo {
                    translated = L10nPseudo.isPseudo(core) || allow(core)
                } else {
                    // shown differently from its English name, or a name that is the same in Estonian ("Filter")
                    translated = core != english || tr(english, context: "menu") != english || L10n.shared.hasTranslation(english) || allow(english)
                }
                if !translated { out.append((path + [core]).joined(separator: " ▸ ")) }
                if let s = item.submenu { walk(s, path + [core], depth + 1) }
            }
        }
        walk(menu, [], 0)
        return out
    }
}

// MARK: - Preferences ▸ General ▸ Language

struct LanguagePreference: View {
    var body: some View {
        let l = L10n.shared
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Language").foregroundStyle(Theme.textDim).frame(width: 110, alignment: .leading)
                Picker("", selection: Binding(get: { l.choice }, set: { l.set($0) })) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .labelsHidden().frame(width: 170)
                .accessibilityLabel(Text("Language"))
            }
            Text("Changes apply right away. System Default follows the language list in macOS System Settings.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            if l.restartRecommended {
                HStack(spacing: 8) {
                    Text("Some parts update after restarting ImageCrat.").font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                    Button("Restart Now") { L10nRestart.restart() }.buttonStyle(PanelButtonStyle())
                }
            }
        }
    }
}

// MARK: - AppKit views

/// AppKit text that was set once (tool tips, button titles, labels, window titles) follows a language switch: each
/// string is mapped back to its English source (remembered per view, or by reverse lookup) and translated again.
/// SwiftUI hierarchies are left to SwiftUI; custom-drawn chrome just redraws (it asks `tr()` while drawing).
enum L10nAppKit {
    private static var memo: UInt8 = 0
    private final class Memo: NSObject {
        var english: [String: String] = [:]   // slot → English
        var shown: [String: String] = [:]     // slot → what we set last
    }

    static func refreshAll() {
        guard let app = NSApp else { return }
        for w in app.windows {
            retitle(window: w)
            if let v = w.contentView { walk(v, depth: 0) }
        }
    }

    static func retitle(window w: NSWindow) {
        guard !w.title.isEmpty, w.title != Brand.name else { return }
        if let s = translate(w, slot: "title", w.title) { w.title = s }
    }

    private static func walk(_ v: NSView, depth: Int, inSwiftUI: Bool = false) {
        guard depth < 60 else { return }
        let swiftUI = inSwiftUI || String(describing: type(of: v)).contains("HostingView")
        // SwiftUI redraws its own text; the AppKit controls it bridges to (segmented pickers, pop-up menus) keep the
        // titles they were made with, so those are retitled here too
        if swiftUI {
            if !inSwiftUI, let a = v.accessibilityLabel(), !a.isEmpty, let s = translate(v, slot: "ax", a) { v.setAccessibilityLabel(s) }
            if let seg = v as? NSSegmentedControl {
                for i in 0..<seg.segmentCount { if let l = seg.label(forSegment: i), !l.isEmpty, let s = translate(seg, slot: "seg\(i)", l) { seg.setLabel(s, forSegment: i) } }
            }
            if let p = v as? NSPopUpButton, let m = p.menu { L10nMenus.retitle(m); p.synchronizeTitleAndSelectedItem() }
            v.needsDisplay = true
            for s in v.subviews { walk(s, depth: depth + 1, inSwiftUI: true) }
            return
        }
        if let t = v.toolTip, !t.isEmpty, let s = translate(v, slot: "toolTip", t) { v.toolTip = s }
        if let a = v.accessibilityLabel(), !a.isEmpty, let s = translate(v, slot: "ax", a) { v.setAccessibilityLabel(s) }
        if let b = v as? NSButton, !b.title.isEmpty, b.imagePosition != .imageOnly, let s = translate(v, slot: "title", b.title) { b.title = s }
        if let f = v as? NSTextField, !f.isEditable, !f.stringValue.isEmpty, let s = translate(v, slot: "stringValue", f.stringValue) { f.stringValue = s }
        if let p = v as? NSPopUpButton { for m in [p.menu].compactMap({ $0 }) { L10nMenus.retitle(m) } }
        v.needsLayout = true
        v.needsDisplay = true
        for s in v.subviews { walk(s, depth: depth + 1) }
    }

    /// The text for `slot` in the current language, nil when it stays as it is.
    private static func translate(_ o: NSObject, slot: String, _ current: String) -> String? {
        let m = (objc_getAssociatedObject(o, &memo) as? Memo) ?? {
            let m = Memo()
            objc_setAssociatedObject(o, &memo, m, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return m
        }()
        let english: String
        if let shown = m.shown[slot], shown == current, let e = m.english[slot] {
            english = e
        } else {
            english = L10n.shared.english(current)
        }
        let out = tr(english)
        m.english[slot] = english
        m.shown[slot] = out
        return out == current ? nil : out
    }
}

// MARK: - Restart

/// Relaunches ImageCrat (Preferences ▸ General ▸ Language ▸ Restart Now). Saved documents are reopened; unsaved ones
/// are written to the autosave session first and offered by the recovery dialog at the next launch.
enum L10nRestart {
    static let reopenKey = "ImageCrat.L10n.ReopenAfterRestart"
    /// Set while quitting for a restart: no "unsaved changes" question, the autosave session is kept.
    static var restarting = false

    static func restart() {
        guard !L10n.shared.automated else { return }
        let docs = AppModel.shared.documents.filter { $0.smartParent == nil }
        let dirty = docs.filter { Autosave.needsAutosave($0) }
        if !dirty.isEmpty {
            let a = NSAlert()
            a.messageText = tr("Restart ImageCrat now?")
            a.informativeText = tr("Unsaved changes are kept: after the restart ImageCrat offers to recover them.")
            a.addButton(withTitle: tr("Restart Now"))
            a.addButton(withTitle: tr("Cancel"))
            guard UIBlock.run(a) == .alertFirstButtonReturn else { return }
            for d in dirty { Autosave.shared.save(d, sync: true, force: true) }
            Autosave.shared.flush()
        }
        let paths = docs.filter { !Autosave.needsAutosave($0) }.compactMap { $0.fileURL?.path }
        UserDefaults.standard.set(paths, forKey: reopenKey)
        let bundle = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // wait for this process to end, then open the app again
        p.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", bundle]
        try? p.run()
        restarting = true
        Autosave.shared.keepSessionOnQuit = !dirty.isEmpty
        NSApp.terminate(nil)
    }

    /// At launch: documents that were open when ImageCrat restarted itself.
    static func reopenAfterRestart() {
        guard !L10n.shared.automated, let paths = UserDefaults.standard.stringArray(forKey: reopenKey) else { return }
        UserDefaults.standard.removeObject(forKey: reopenKey)
        for p in paths where FileManager.default.fileExists(atPath: p) { AppActions.open(url: URL(fileURLWithPath: p)) }
    }
}
