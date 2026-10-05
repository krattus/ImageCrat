import AppKit
import SwiftUI
import Observation
import ImageCratCore

// MARK: - Items

enum PaletteCategory: String {
    case verb = "Quick", calc = "Calculator", menu = "Command", tool = "Tool", filter = "Filter", adjustment = "Adjustment", panel = "Panel",
         layer = "Layer", document = "Document", recent = "Recent File", action = "Action", preset = "Preset", preference = "Preferences",
         version = "Version", hint = "Syntax"

    var symbol: String {
        switch self {
        case .verb: return "bolt.fill"
        case .calc: return "equal.square"
        case .menu: return "command"
        case .tool: return "hammer"
        case .filter: return "camera.filters"
        case .adjustment: return "slider.horizontal.3"
        case .panel: return "sidebar.right"
        case .layer: return "square.3.layers.3d"
        case .document: return "doc"
        case .recent: return "clock"
        case .action: return "play.fill"
        case .preset: return "star"
        case .preference: return "gearshape"
        case .version: return "bookmark"
        case .hint: return "text.cursor"
        }
    }
}

struct PaletteItem: Identifiable {
    /// Stable key (frecency, de-duplication).
    let id: String
    var title: String
    var subtitle: String = ""
    var category: PaletteCategory
    var shortcut: String = ""
    var symbol: String? = nil
    var enabled = true
    /// Extra text the search also looks at.
    var keywords: String = ""
    /// Hints put text into the search field instead of running something.
    var insertText: String? = nil
    var run: () -> Void = {}
}

struct PaletteResult: Identifiable {
    var item: PaletteItem
    var score: Double
    /// Character offsets of the title that matched (for highlighting).
    var matched: [Int]
    var id: String { item.id }
}

// MARK: - Fuzzy matching

enum Fuzzy {
    private static let consecutive = 1.0, wordStart = 0.8, capital = 0.7, gapInner = -0.012, gapLeading = -0.004, gapTrailing = -0.003

    /// fzy-style score of `query` as a subsequence of `text` (case-insensitive). nil when it doesn't match.
    /// Higher is better; word starts and consecutive runs are rewarded, gaps penalised.
    static func score(_ query: String, _ text: String) -> (score: Double, positions: [Int])? {
        let q = Array(query.lowercased()), orig = Array(text), t = Array(text.lowercased())
        let n = q.count, m = t.count
        guard n > 0 else { return (0, []) }
        guard n <= m, orig.count == m else { return nil }
        // quick subsequence check
        var qi = 0
        for c in t where qi < n && c == q[qi] { qi += 1 }
        guard qi == n else { return nil }
        if n == m { return (Double(n) * 2 + 2, Array(0..<n)) }     // exact

        var bonus = [Double](repeating: 0, count: m)
        for j in 0..<m {
            if j == 0 { bonus[j] = wordStart + 0.15; continue }
            let p = orig[j - 1], c = orig[j]
            if p == " " || p == "/" || p == "-" || p == "_" || p == ":" || p == "." || p == "▸" || p == "(" { bonus[j] = wordStart }
            else if c.isUppercase, p.isLowercase { bonus[j] = capital }
        }
        let neg = -Double.infinity
        var D = [[Double]](repeating: [Double](repeating: neg, count: m), count: n)
        var M = [[Double]](repeating: [Double](repeating: neg, count: m), count: n)
        for i in 0..<n {
            var prev = neg
            let gap = i == n - 1 ? gapTrailing : gapInner
            for j in 0..<m {
                if q[i] == t[j] {
                    var s = neg
                    if i == 0 { s = Double(j) * gapLeading + bonus[j] }
                    else if j > 0 { s = max(M[i - 1][j - 1] + bonus[j], D[i - 1][j - 1] + consecutive) }
                    D[i][j] = s
                    prev = max(s, prev + gap)
                } else {
                    prev = prev + gap
                }
                M[i][j] = prev
            }
        }
        let best = M[n - 1][m - 1]
        guard best > neg else { return nil }
        // backtrack
        var pos = [Int](repeating: 0, count: n)
        var required = false
        var j = m - 1
        for i in stride(from: n - 1, through: 0, by: -1) {
            while j >= 0 {
                if D[i][j] != neg, required || D[i][j] == M[i][j] {
                    required = i > 0 && j > 0 && M[i][j] == D[i - 1][j - 1] + consecutive
                    pos[i] = j
                    j -= 1
                    break
                }
                j -= 1
            }
        }
        // prefix / whole-word boosts make "brush" prefer "Brush Tool" over "Healing Brush Tool"
        var s = best
        if t.starts(with: q) { s += 1.2 }
        return (s, pos)
    }

    /// A match only counts when it is reasonably tight (consecutive letters / word starts), so scattered letters
    /// across a long title don't flood the list.
    static func good(_ query: String, _ text: String, quality: Double) -> (score: Double, positions: [Int])? {
        guard let r = score(query, text) else { return nil }
        let n = Double(query.filter { $0 != " " }.count)
        return n <= 1 || r.score >= quality * n ? r : nil
    }

    /// Multi-word query: every word must match the title or the secondary text (path, keywords); order doesn't matter.
    static func match(_ query: String, title: String, secondary: String) -> (score: Double, positions: [Int])? {
        let words = query.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return (0, []) }
        if let r = good(query, title, quality: 0.55) { return r }
        if words.count == 1 {
            guard let r = good(query, secondary, quality: 0.7) else { return nil }
            return (r.score * 0.45 - 0.5, [])
        }
        var total = 0.0
        var positions: [Int] = []
        for w in words {
            if let r = good(w, title, quality: 0.55) { total += r.score; positions += r.positions }
            else if let r = good(w, secondary, quality: 0.7) { total += r.score * 0.45 - 0.5 }
            else { return nil }
        }
        return (total - 0.3, Array(Set(positions)).sorted())
    }
}

// MARK: - Frecency

/// How often and how recently each palette entry was used; persisted in the support folder.
final class PaletteFrecency {
    struct Entry: Codable { var count = 0; var last = Date(timeIntervalSince1970: 0)
        init(count: Int, last: Date) { self.count = count; self.last = last }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            count = (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0
            last = (try? c.decodeIfPresent(Date.self, forKey: .last)) ?? Date(timeIntervalSince1970: 0)
        }
    }

    private(set) var entries: [String: Entry] = [:]
    let url: URL

    init(url: URL = Workflow2Paths.root.appendingPathComponent("palette-frecency.json")) {
        self.url = url
        if let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([String: Entry].self, from: d) { entries = e }
    }

    func bump(_ id: String, now: Date = Date()) {
        var e = entries[id] ?? Entry(count: 0, last: now)
        e.count += 1
        e.last = now
        entries[id] = e
        if entries.count > 600 {
            let drop = entries.sorted { $0.value.last < $1.value.last }.prefix(entries.count - 500).map(\.key)
            for k in drop { entries[k] = nil }
        }
        save()
    }

    /// 0 … ~2.4: grows with use (log) and fades over weeks.
    func boost(_ id: String, now: Date = Date()) -> Double {
        guard let e = entries[id], e.count > 0 else { return 0 }
        let days = max(0, now.timeIntervalSince(e.last) / 86400)
        let recency = 0.35 + 0.65 * exp(-days / 10)
        return min(2.4, 0.8 * log2(1 + Double(e.count))) * recency
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: url, options: .atomic) }
    }
}

// MARK: - Calculator

/// Tiny arithmetic parser: + - * / ^ % ( ) and unary minus. "50%" is 0.5; "15% of 240" works too.
enum PaletteCalc {
    static func evaluate(_ s: String) -> Double? {
        let text = s.lowercased().replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " of ", with: "*")
        var chars = Array(text.filter { !$0.isWhitespace })
        guard !chars.isEmpty, chars.contains(where: { "+-*/^%(".contains($0) }), chars.contains(where: \.isNumber) else { return nil }
        if chars.first == "=" { chars.removeFirst() }
        var i = 0
        func peek() -> Character? { i < chars.count ? chars[i] : nil }
        func number() -> Double? {
            let start = i
            while let c = peek(), c.isNumber || c == "." { i += 1 }
            guard i > start, var v = Double(String(chars[start..<i])) else { return nil }
            if peek() == "%" { i += 1; v /= 100 }
            return v
        }
        func atom() -> Double? {
            guard let c = peek() else { return nil }
            if c == "(" {
                i += 1
                guard let v = expr(), peek() == ")" else { return nil }
                i += 1
                if peek() == "%" { i += 1; return v / 100 }
                return v
            }
            if c == "-" { i += 1; return atom().map { -$0 } }
            if c == "+" { i += 1; return atom() }
            return number()
        }
        func power() -> Double? {
            guard let base = atom() else { return nil }
            if peek() == "^" { i += 1; guard let e = power() else { return nil }; return pow(base, e) }
            return base
        }
        func term() -> Double? {
            guard var v = power() else { return nil }
            while let c = peek(), c == "*" || c == "/" {
                i += 1
                guard let r = power() else { return nil }
                if c == "*" { v *= r } else { guard r != 0 else { return nil }; v /= r }
            }
            return v
        }
        func expr() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let r = term() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }
        guard let v = expr(), i == chars.count, v.isFinite else { return nil }
        return v
    }

    static func format(_ v: Double) -> String {
        if abs(v - v.rounded()) < 1e-9, abs(v) < 1e15 { return String(Int64(v.rounded())) }
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

// MARK: - Quick verbs

enum PaletteVerb: Equatable {
    case opacity(Double)                    // percent
    case fillOpacity(Double)                // percent
    case fillColor(RGBA)
    case foreground(RGBA)
    case imageSize(Int, Int)
    case imageScale(Double)                 // percent
    case canvasSize(Int, Int)
    case newDocument(Int, Int, String?)
    case rename(String)
    case zoom(Double)                       // percent
    case zoomFit
    case font(String)                       // family or PostScript name
    case fontSize(Double)
    case feather(Double, FeatherDirection?)
    case expand(Double)
    case contract(Double)
    case export(ExportFormat)
    case blend(BlendMode)
    case rotateCanvas(Int)
    case flipCanvas(horizontal: Bool)
    case brushSize(Double)
    case brushHardness(Double)

    var title: String {
        switch self {
        case .opacity(let v): return "Set layer opacity to \(PaletteCalc.format(v))%"
        case .fillOpacity(let v): return "Set layer fill to \(PaletteCalc.format(v))%"
        case .fillColor(let c): return "Fill with #\(c.hex)"
        case .foreground(let c): return "Set foreground colour to #\(c.hex)"
        case .imageSize(let w, let h): return "Resize image to \(w) × \(h) px"
        case .imageScale(let p): return "Resize image to \(PaletteCalc.format(p))%"
        case .canvasSize(let w, let h): return "Set canvas size to \(w) × \(h) px"
        case .newDocument(let w, let h, let n): return "New document \(w) × \(h) px" + (n.map { " “\($0)”" } ?? "")
        case .rename(let n): return "Rename layer to “\(n)”"
        case .zoom(let z): return "Zoom to \(PaletteCalc.format(z))%"
        case .zoomFit: return "Zoom to fit on screen"
        case .font(let f): return "Set font to \(f)"
        case .fontSize(let s): return "Set font size to \(PaletteCalc.format(s)) px"
        case .feather(let r, let d): return "Feather selection \(PaletteCalc.format(r)) px" + (d.map { " (\($0.rawValue.lowercased()))" } ?? "")
        case .expand(let r): return "Expand selection by \(PaletteCalc.format(r)) px"
        case .contract(let r): return "Contract selection by \(PaletteCalc.format(r)) px"
        case .export(let f): return "Export as \(f.rawValue)…"
        case .blend(let m): return "Set blend mode to \(m.displayName)"
        case .rotateCanvas(let d): return "Rotate canvas \(d)°"
        case .flipCanvas(let h): return "Flip canvas \(h ? "horizontally" : "vertically")"
        case .brushSize(let s): return "Set brush size to \(PaletteCalc.format(s)) px"
        case .brushHardness(let s): return "Set brush hardness to \(PaletteCalc.format(s))%"
        }
    }

    var key: String {
        switch self {
        case .opacity: return "opacity"; case .fillOpacity, .fillColor: return "fill"; case .foreground: return "color"
        case .imageSize, .imageScale: return "size"; case .canvasSize: return "canvas"; case .newDocument: return "new"; case .rename: return "rename"
        case .zoom, .zoomFit: return "zoom"; case .font: return "font"; case .fontSize: return "fontsize"; case .feather: return "feather"
        case .expand: return "expand"; case .contract: return "contract"; case .export: return "export"; case .blend: return "blend"
        case .rotateCanvas: return "rotate"; case .flipCanvas: return "flip"; case .brushSize: return "brush"; case .brushHardness: return "hardness"
        }
    }
}

enum PaletteVerbs {
    /// Syntax hints shown while a verb is being typed.
    static let hints: [(verb: String, usage: String, help: String)] = [
        ("opacity", "opacity 50", "Layer opacity in percent"),
        ("fill", "fill #ff8800", "Fill with a colour — or “fill 50” for the layer's fill opacity"),
        ("color", "color #3366ff", "Foreground colour (hex or a name such as red)"),
        ("size", "size 1080x1350", "Resize the image (or “size 50%”)"),
        ("canvas", "canvas 2000x2000", "Canvas size, centred"),
        ("new", "new 1920x1080", "New document, optionally followed by a name"),
        ("rename", "rename Hero", "Rename the active layer"),
        ("zoom", "zoom 200", "Zoom in percent, or “zoom fit”"),
        ("font", "font Avenir", "Font of the selected type layers"),
        ("fontsize", "fontsize 48", "Font size of the selected type layers"),
        ("feather", "feather 12 inside", "Feather the selection (inside, outside or centered)"),
        ("expand", "expand 4", "Grow the selection"),
        ("contract", "contract 4", "Shrink the selection"),
        ("export", "export png", "Export the document (png, jpg, tiff, heic, gif, bmp, psd)"),
        ("blend", "blend multiply", "Blend mode of the selected layers"),
        ("rotate", "rotate 90", "Rotate the canvas (90, -90, 180)"),
        ("flip", "flip h", "Flip the canvas horizontally or vertically"),
        ("brush", "brush 40", "Brush size in pixels"),
        ("hardness", "hardness 80", "Brush hardness in percent"),
    ]

    static let colorNames: [String: String] = [
        "black": "000000", "white": "FFFFFF", "red": "FF0000", "green": "00B050", "blue": "0066FF", "yellow": "FFD400", "orange": "FF8800",
        "purple": "8E44AD", "violet": "8E44AD", "pink": "FF5CA8", "cyan": "00C8FF", "magenta": "FF00FF", "brown": "8B5A2B", "gray": "808080", "grey": "808080",
        "teal": "008080", "navy": "001F5B", "lime": "A4DE02", "gold": "D4AF37", "beige": "F5F0DC",
    ]

    static func color(_ s: String) -> RGBA? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = colorNames[t] { return RGBA(hex: n) }
        var h = t
        let hashed = h.hasPrefix("#")
        if hashed { h.removeFirst() }
        guard h.allSatisfy(\.isHexDigit) else { return nil }
        if h.count == 3, hashed { h = h.map { "\($0)\($0)" }.joined() }     // short form only with "#" ("fill bad" is not a colour)
        guard h.count == 6 || h.count == 8 else { return nil }
        return RGBA(hex: h)
    }

    static func number(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        for suffix in ["px", "%", "pt"] where t.hasSuffix(suffix) { t.removeLast(suffix.count) }
        return Double(t.replacingOccurrences(of: ",", with: "."))
    }

    /// "1080x1350", "1080 x 1350", "1080×1350", "1080 1350", "1080*1350"
    static func size(_ s: String) -> (Int, Int, rest: String)? {
        let pattern = #"^\s*(\d{1,5})\s*(?:px)?\s*(?:x|×|\*|\s|,|by)\s*(\d{1,5})\s*(?:px)?\s*(.*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)), m.numberOfRanges == 4,
              let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s), let r3 = Range(m.range(at: 3), in: s),
              let w = Int(s[r1]), let h = Int(s[r2]), w > 0, h > 0, w <= 30000, h <= 30000 else { return nil }
        return (w, h, String(s[r3]).trimmingCharacters(in: .whitespaces))
    }

    static let exportFormats: [String: ExportFormat] = ["png": .png, "jpg": .jpeg, "jpeg": .jpeg, "tif": .tiff, "tiff": .tiff, "heic": .heic, "bmp": .bmp, "gif": .gif, "psd": .psd]

    /// Best font families / faces for a typed name.
    static func fonts(_ q: String, families: [String] = FontCatalog.families, limit: Int = 3) -> [String] {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let scored = families.compactMap { f -> (String, Double)? in Fuzzy.score(query, f).map { (f, $0.score - Double(f.count) * 0.01) } }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Parses a typed query into quick verbs (usually zero or one; `font` may offer a few candidates).
    static func parse(_ raw: String, fontFamilies: [String]? = nil) -> [PaletteVerb] {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard let sp = q.firstIndex(where: { $0 == " " }) else { return [] }
        let verb = q[..<sp].lowercased()
        let arg = String(q[q.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
        guard !arg.isEmpty else { return [] }
        func pct(_ s: String) -> Double? { number(s).flatMap { (0...100).contains($0) ? $0 : nil } }
        switch verb {
        case "opacity", "op", "alpha":
            return pct(arg).map { [.opacity($0)] } ?? []
        case "fill":
            if !arg.hasPrefix("#"), let v = number(arg), (0...100).contains(v), arg.filter(\.isNumber).count <= 3 { return [.fillOpacity(v)] }
            return color(arg).map { [.fillColor($0)] } ?? []
        case "color", "colour", "fg", "foreground":
            return color(arg).map { [.foreground($0)] } ?? []
        case "size", "resize", "imagesize":
            if arg.hasSuffix("%"), let v = number(arg), v > 0, v <= 1000 { return [.imageScale(v)] }
            return size(arg).map { [.imageSize($0.0, $0.1)] } ?? []
        case "canvas", "canvassize":
            return size(arg).map { [.canvasSize($0.0, $0.1)] } ?? []
        case "new", "newdoc":
            return size(arg).map { [.newDocument($0.0, $0.1, $0.rest.isEmpty ? nil : $0.rest)] } ?? []
        case "rename", "name":
            return [.rename(arg)]
        case "zoom", "z":
            if ["fit", "all", "screen"].contains(arg.lowercased()) { return [.zoomFit] }
            return number(arg).flatMap { $0 >= 1 && $0 <= 6400 ? [.zoom($0)] : nil } ?? []
        case "font", "typeface":
            return fonts(arg, families: fontFamilies ?? FontCatalog.families).map { .font($0) }
        case "fontsize", "textsize", "pt":
            return number(arg).flatMap { $0 > 0 && $0 <= 5000 ? [.fontSize($0)] : nil } ?? []
        case "feather":
            let parts = arg.split(separator: " ").map(String.init)
            guard let r = number(parts[0]), r >= 0, r <= 1000 else { return [] }
            var dir: FeatherDirection? = nil
            if parts.count > 1 {
                let d = parts[1].lowercased()
                dir = d.hasPrefix("in") ? .inside : (d.hasPrefix("out") ? .outside : (d.hasPrefix("c") ? .centered : nil))
                if dir == nil { return [] }
            }
            return [.feather(r, dir)]
        case "expand", "grow":
            return number(arg).flatMap { $0 > 0 && $0 <= 1000 ? [.expand($0)] : nil } ?? []
        case "contract", "shrink":
            return number(arg).flatMap { $0 > 0 && $0 <= 1000 ? [.contract($0)] : nil } ?? []
        case "export", "save":
            return exportFormats[arg.lowercased()].map { [.export($0)] } ?? []
        case "blend", "mode", "blendmode":
            let modes = BlendMode.allCases.filter { $0 != .passThrough }
            let scored = modes.compactMap { m -> (BlendMode, Double)? in
                (Fuzzy.score(arg, m.displayName) ?? Fuzzy.score(arg, m.rawValue)).map { (m, $0.score - Double(m.displayName.count) * 0.01) }
            }
            return scored.sorted { $0.1 > $1.1 }.prefix(1).map { .blend($0.0) }
        case "rotate":
            guard let v = number(arg.replacingOccurrences(of: "°", with: "")), [90, -90, 180, 270, -270, -180].contains(v) else { return [] }
            let d = Int(v)
            return [.rotateCanvas(d == 270 ? -90 : (d == -270 ? 90 : (d == -180 ? 180 : d)))]
        case "flip":
            let a = arg.lowercased()
            if a.hasPrefix("h") { return [.flipCanvas(horizontal: true)] }
            if a.hasPrefix("v") { return [.flipCanvas(horizontal: false)] }
            return []
        case "brush", "brushsize":
            return number(arg).flatMap { $0 >= 1 && $0 <= 5000 ? [.brushSize($0)] : nil } ?? []
        case "hardness":
            return pct(arg).map { [.brushHardness($0)] } ?? []
        default:
            return []
        }
    }

    /// Whether the verb can run right now (greyed otherwise).
    static func isAvailable(_ v: PaletteVerb) -> Bool {
        let d = AppActions.doc
        switch v {
        case .newDocument, .foreground, .brushSize, .brushHardness: return true
        case .feather, .expand, .contract: return d?.state.selection != nil
        case .font, .fontSize: return d.map { doc in doc.orderedSelection.contains { doc.state.layer($0)?.isText == true } } ?? false
        default: return d != nil
        }
    }

    /// Runs a verb on the active document. Returns false when it could not apply.
    @discardableResult
    static func perform(_ v: PaletteVerb) -> Bool {
        let app = AppModel.shared
        let d = AppActions.doc
        func onSelection(_ name: String, _ body: (inout Layer) -> Void) -> Bool {
            guard let d, !d.orderedSelection.isEmpty else { return false }
            AppActions.canvas?.commitCurrentTool()
            for id in d.orderedSelection { d.updateLayer(id, body) }
            d.commit(name)
            return true
        }
        func onBlending(_ name: String, _ body: (inout Layer) -> Void) -> Bool {   // (Lock All keeps a layer out)
            guard let d else { return false }
            AppActions.canvas?.commitCurrentTool()
            guard AppActions.setBlending(d, body) else { return false }
            d.commit(name)
            return true
        }
        switch v {
        case .opacity(let p): return onBlending("Opacity Change") { $0.opacity = p / 100 }
        case .fillOpacity(let p): return onBlending("Fill Change") { $0.fillOpacity = p / 100 }
        case .blend(let m): return onBlending("Blend Mode") { $0.blendMode = m }
        case .fillColor(let c):
            guard let d, let l = d.activeLayer else { return false }
            if l.isRaster || (d.editTarget == .mask && l.mask != nil) {
                AppActions.fill(.color, color: c, opacity: 1, mode: .normal, preserveTransparency: false)
            } else if l.isShape {
                d.updateLayer(l.id) { x in if var s = x.shape { s.fill = .color(c); x.shape = s } }
                d.commit("Set Shape Fill")
            } else if l.isFill {
                d.updateLayer(l.id) { $0.fill = FillContent(paint: .color(c)) }
                d.commit("Set Fill Color")
            } else if l.isText {
                d.updateLayer(l.id) { x in if var t = x.text { t.applyLayerWide(CharacterStyle(color: c)); x.text = t } }
                d.commit("Set Text Color")
            } else { return false }
            return true
        case .foreground(let c):
            app.foreground = c
            app.pushRecent(c)
            return true
        case .imageSize(let w, let h):
            guard let d else { return false }
            AppActions.imageSize(width: w, height: h, resolution: d.state.resolution, scaleStyles: true)
            return true
        case .imageScale(let p):
            guard let d else { return false }
            AppActions.imageSize(width: max(1, Int((Double(d.state.width) * p / 100).rounded())), height: max(1, Int((Double(d.state.height) * p / 100).rounded())),
                                 resolution: d.state.resolution, scaleStyles: true)
            return true
        case .canvasSize(let w, let h):
            guard d != nil else { return false }
            AppActions.canvasSize(width: w, height: h, anchorX: 1, anchorY: 1, extension: app.background)
            return true
        case .newDocument(let w, let h, let name):
            AppActions.newDocument(width: w, height: h, resolution: 72, background: .white, name: name ?? "Untitled-\(app.documents.count + 1)")
            return true
        case .rename(let n):
            guard let d, let id = d.activeLayerID else { return false }
            d.updateLayer(id) { $0.name = n }
            d.commit("Rename Layer")
            return true
        case .zoom(let z):
            guard let d else { return false }
            if let c = AppActions.canvas { c.setZoom(z / 100) } else { d.zoom = z / 100 }
            return true
        case .zoomFit:
            guard let d else { return false }
            d.needsFitOnScreen = true
            AppActions.canvas?.fitOnScreen()
            return true
        case .font(let family):
            let ps = FontCatalog.members(family).first?.0 ?? family
            guard let d else { return false }
            let ids = d.orderedSelection.filter { d.state.layer($0)?.isText == true }
            guard !ids.isEmpty else { return false }
            AppActions.canvas?.commitCurrentTool()
            for id in ids { d.updateLayer(id) { x in if var t = x.text { t.applyLayerWide(CharacterStyle(fontName: ps)); x.text = t } } }
            d.commit("Set Font")
            return true
        case .fontSize(let s):
            guard let d else { return false }
            let ids = d.orderedSelection.filter { d.state.layer($0)?.isText == true }
            guard !ids.isEmpty else { return false }
            AppActions.canvas?.commitCurrentTool()
            for id in ids { d.updateLayer(id) { x in if var t = x.text { t.applyLayerWide(CharacterStyle(fontSize: s)); x.text = t } } }
            d.commit("Set Font Size")
            return true
        case .feather(let r, let dir):
            guard d?.state.selection != nil else { return false }
            AppActions.modifySelection(.feather, amount: r, direction: dir)
            return true
        case .expand(let r):
            guard d?.state.selection != nil else { return false }
            AppActions.modifySelection(.expand, amount: r)
            return true
        case .contract(let r):
            guard d?.state.selection != nil else { return false }
            AppActions.modifySelection(.contract, amount: r)
            return true
        case .export(let f):
            guard let d else { return false }
            let st = d.state
            let p = NSSavePanel()
            p.allowedContentTypes = [f.utType]
            p.nameFieldStringValue = (d.name as NSString).deletingPathExtension + "." + f.ext
            p.begin { r in
                guard r == .OK, let url = p.url else { return }
                do { try DocumentIO.export(st, to: url, format: f, quality: 0.9, scale: 1, background: f.supportsAlpha ? nil : .white) }
                catch { AppActions.alert("Export failed.", error.localizedDescription) }
            }
            return true
        case .rotateCanvas(let deg):
            guard d != nil else { return false }
            AppActions.rotateCanvas(deg)
            return true
        case .flipCanvas(let h):
            guard d != nil else { return false }
            AppActions.flipCanvas(horizontal: h)
            return true
        case .brushSize(let s):
            var b = app.activeBrushSettings; b.size = s; app.activeBrushSettings = b
            return true
        case .brushHardness(let p):
            var b = app.activeBrushSettings; b.hardness = p / 100; app.activeBrushSettings = b
            return true
        }
    }
}

// MARK: - Index

enum PaletteIndex {
    /// Replaced by tests (no recent-documents list headless).
    static var recentURLs: () -> [URL] = { FilesModule.headless ? [] : NSDocumentController.shared.recentDocumentURLs }

    static func cleanTitle(_ t: String) -> String {
        var s = t
        if s.hasPrefix("✓ ") { s.removeFirst(2) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Key used to de-duplicate the same command coming from the menu bar and from a catalogue.
    static func normalized(_ t: String) -> String {
        cleanTitle(t).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").lowercased()
    }

    /// "⇧⌘P" for a menu item's key equivalent.
    static func shortcutString(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        guard let ch = key.unicodeScalars.first else { return "" }
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) || (key != key.lowercased() && key.count == 1 && Character(key).isLetter) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch ch.value {
        case 0x08, 0x7F: s += "⌫"
        case 0x0D, 0x03: s += "↩"
        case 0x1B: s += "⎋"
        case 0x20: s += "Space"
        case 0x09: s += "⇥"
        case UInt32(NSUpArrowFunctionKey): s += "↑"
        case UInt32(NSDownArrowFunctionKey): s += "↓"
        case UInt32(NSLeftArrowFunctionKey): s += "←"
        case UInt32(NSRightArrowFunctionKey): s += "→"
        case UInt32(NSF1FunctionKey)...UInt32(NSF35FunctionKey): s += "F\(ch.value - UInt32(NSF1FunctionKey) + 1)"
        default: s += key.uppercased()
        }
        return s
    }

    static func shortcutString(_ k: KeyEquivalent, _ m: EventModifiers) -> String {
        var f: NSEvent.ModifierFlags = []
        if m.contains(.command) { f.insert(.command) }
        if m.contains(.shift) { f.insert(.shift) }
        if m.contains(.option) { f.insert(.option) }
        if m.contains(.control) { f.insert(.control) }
        return shortcutString(key: String(k.character), modifiers: f)
    }

    static let skippedMenus: Set<String> = ["Services", "Open Recent"]

    /// Commands that can reach a cloud provider. Automated runs (self test, command-line runners) never execute these
    /// from the palette, whatever a test selects.
    static func isGenerative(_ it: PaletteItem) -> Bool {
        let text = (it.id + " " + it.title + " " + it.subtitle).lowercased()
        return ["generat", "with ai", " ai ", "ai denoise", "ai sharpen", "prompt", "neural", "remove with", "upscale", "sky replacement", "smart portrait", "cloud"].contains { text.contains($0) }
    }

    /// Every leaf item of a menu tree (submenus included). Disabled items are returned with `enabled == false`.
    static func menuItems(_ menu: NSMenu, path: [String] = []) -> [PaletteItem] {
        var out: [PaletteItem] = []
        menu.update()      // validates the items so `isEnabled` is current
        for item in menu.items {
            if item.isSeparatorItem || item.isHidden { continue }
            let title = cleanTitle(item.title)
            if title.isEmpty { continue }
            if let sub = item.submenu {
                if skippedMenus.contains(title) { continue }
                // the application menu's title is the app name: present it as "Lumen"
                out += menuItems(sub, path: path + [title])
                continue
            }
            if title == "Command Palette…" { continue }
            let full = (path + [title]).joined(separator: " ▸ ")
            out.append(PaletteItem(id: "menu:" + full, title: title, subtitle: path.joined(separator: " ▸ "), category: .menu,
                                   shortcut: item.keyEquivalent.isEmpty ? "" : shortcutString(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask),
                                   enabled: item.isEnabled, run: { [weak item] in
                guard let it = item, let m = it.menu else { return }
                let i = m.index(of: it)
                if i >= 0 { m.performActionForItem(at: i) }
            }))
        }
        return out
    }

    /// Items registered by feature modules (covers menus SwiftUI has not materialised yet).
    static func registryItems() -> [PaletteItem] {
        MenuRegistry.items.compactMap { spec in
            if spec.title == "Command Palette…" { return nil }
            let parts = spec.menu.split(separator: "/").map(String.init) + (spec.submenu.map { [$0] } ?? [])
            let full = (parts + [spec.title]).joined(separator: " ▸ ")
            return PaletteItem(id: "menu:" + full, title: spec.title, subtitle: parts.joined(separator: " ▸ "), category: .menu,
                               shortcut: spec.key.map { shortcutString($0, spec.modifiers) } ?? "", enabled: spec.enabled(), run: spec.action)
        }
    }

    /// Everything the palette can search, built when it opens.
    static func build(menu: NSMenu? = NSApp?.mainMenu) -> [PaletteItem] {
        let app = AppModel.shared
        let doc = app.activeDocument
        let hasDoc = doc != nil
        var items: [PaletteItem] = []
        var seenIDs = Set<String>()
        var seenTitles = Set<String>()
        func add(_ it: PaletteItem, dedupeTitle: Bool = false) {
            guard !seenIDs.contains(it.id) else { return }
            if dedupeTitle, seenTitles.contains(normalized(it.title)) { return }
            seenIDs.insert(it.id)
            if it.category == .menu { seenTitles.insert(normalized(it.title)) }
            items.append(it)
        }

        // 1. menu bar (walked now). Items that come from MenuRegistry take their enabled state and action straight from
        //    the registry (SwiftUI only refreshes a menu item when its menu opens); then registry items not in the bar yet.
        let registry = registryItems()
        let byID = Dictionary(registry.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let menu {
            for var it in menuItems(menu) {
                if let r = byID[it.id] { it.enabled = r.enabled; it.run = r.run }
                add(it)
            }
        }
        for it in registry { add(it) }
        for it in ZoomController.paletteItems() { add(it) }   // (the View menu isn't there headless)

        // 2. tools
        for t in ToolKind.allCases {
            add(PaletteItem(id: "tool:" + t.rawValue, title: t.displayName, subtitle: "Switch tool", category: .tool, shortcut: t.shortcut, symbol: t.symbol,
                            keywords: t.rawValue) { app.tool = t })
        }
        // 3. filters & adjustments (skipped when the menu already has them)
        for k in FilterKind.allCases where k != .neuralFilter && k != .liquify {
            add(PaletteItem(id: "filter:" + k.rawValue, title: k.displayName + (k.isImmediate ? "" : "…"), subtitle: "Filter ▸ " + k.category.rawValue, category: .filter,
                            enabled: hasDoc, keywords: k.rawValue) { FilterLauncher.launch(k) }, dedupeTitle: true)
        }
        for k in AdjustmentKind.allCases {
            add(PaletteItem(id: "adjust:" + k.rawValue, title: k.displayName + "…", subtitle: "Image ▸ Adjustments", category: .adjustment, enabled: hasDoc,
                            keywords: k.rawValue) { app.dialog = .adjustment(k) }, dedupeTitle: true)
        }
        for k in AdjustmentKind.layerKinds {
            add(PaletteItem(id: "adjlayer:" + k.rawValue, title: "New \(k.displayName) Adjustment Layer", subtitle: "Layer ▸ New Adjustment Layer", category: .adjustment,
                            enabled: hasDoc, keywords: k.rawValue) { AppActions.newAdjustmentLayer(k) })
        }
        // 4. panels
        for p in PanelRegistry.defs {
            add(PaletteItem(id: "panel:" + p.id, title: "\(p.title) Panel", subtitle: "Show panel", category: .panel, keywords: p.id) { WorkspaceManager.shared.reveal(p.id) })
        }
        // 5. layers, documents, versions, branches
        if let d = doc {
            for (l, _) in d.state.layers.flattenedForDisplay(includeCollapsed: true) {
                add(PaletteItem(id: "layer:\(d.id):\(l.id)", title: l.name, subtitle: "Select layer · \(l.kindName)" + (l.isVisible ? "" : " · hidden"), category: .layer) {
                    d.selectLayer(l.id)
                    WorkspaceManager.shared.reveal("layers")
                })
            }
            for v in VersionStore.shared.versions(d) {
                add(PaletteItem(id: "version:\(v.id)", title: "Restore Version “\(v.name)”", subtitle: Workflow2Util.timeString(v.date), category: .version) {
                    VersionStore.shared.restore(v.id, in: d)
                })
            }
            for b in HistoryTree.shared.branches(d) {
                add(PaletteItem(id: "branch:\(b.id)", title: "Switch to History Branch “\(b.name)”", subtitle: "\(b.entries.count) steps, from “\(b.forkName)”", category: .version,
                                symbol: "arrow.triangle.branch") { HistoryTree.shared.switchTo(b.id, in: d) })
            }
        }
        for d in app.documents where d.id != app.activeDocumentID {
            add(PaletteItem(id: "doc:\(d.id)", title: d.name, subtitle: "Switch to document", category: .document) { app.activeDocumentID = d.id })
        }
        // 6. recent files
        for u in recentURLs().prefix(20) {
            add(PaletteItem(id: "recent:" + u.path, title: u.lastPathComponent, subtitle: "Open · " + (u.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                            category: .recent) { AppActions.open(url: u) })
        }
        // 7. actions
        for set in ActionRecorder.shared.sets {
            for a in set.actions {
                add(PaletteItem(id: "action:\(a.id)", title: "Play Action “\(a.name)”", subtitle: "\(set.name) · \(a.steps.count) step\(a.steps.count == 1 ? "" : "s")", category: .action,
                                enabled: hasDoc, keywords: a.steps.map(\.title).joined(separator: " ")) { ActionRecorder.shared.play(a.id) })
            }
        }
        // 8. presets
        let brushLib = BrushLibrary.shared
        for r in brushLib.orderedBrushes {
            let folder = brushLib.index.folderID(ofBrush: r.id).map { brushLib.index.path(ofFolder: $0).joined(separator: " ▸ ") } ?? ""
            add(PaletteItem(id: "brush:" + r.id, title: "Brush: \(r.name)", subtitle: "Brush preset · \(Int(r.params.size)) px" + (folder.isEmpty ? "" : " · " + folder),
                            category: .preset, symbol: "paintbrush.pointed", keywords: folder) {
                brushLib.select(r.id)
            })
        }
        for p in ToolPresetStore.shared.presets {
            add(PaletteItem(id: "toolpreset:\(p.id)", title: "Tool Preset: \(p.name)", subtitle: p.tool.displayName, category: .preset) { ToolPresetStore.apply(p) })
        }
        for (i, g) in app.gradients.enumerated() {
            add(PaletteItem(id: "gradient:\(i):\(g.name)", title: "Gradient: \(g.name)", subtitle: "Gradient preset", category: .preset, symbol: "square.fill.on.square.fill") {
                app.gradientTool.gradient = g
                app.gradientTool.useForegroundBackground = false
                app.tool = .gradient
            })
        }
        for p in NewDocumentDialog.presets {
            add(PaletteItem(id: "docpreset:" + p.name, title: "New Document: \(p.name)", subtitle: "\(p.w) × \(p.h) px, \(Int(p.res)) ppi", category: .preset, symbol: "doc.badge.plus") {
                AppActions.newDocument(width: p.w, height: p.h, resolution: p.res, background: .white, name: "Untitled-\(app.documents.count + 1)")
            })
        }
        for w in WorkspaceManager.shared.allWorkspaces {
            add(PaletteItem(id: "workspace:" + w.name, title: "Workspace: \(w.name)", subtitle: "Panel arrangement", category: .preset, symbol: "rectangle.3.group") {
                WorkspaceManager.shared.apply(w)
            })
        }
        // 9. preferences sections
        for s in Workflow2PrefsState.sections {
            add(PaletteItem(id: "prefs:" + s, title: "Preferences: \(s)", subtitle: "Open Preferences", category: .preference) { Workflow2PrefsState.open(s) })
        }
        // 10. verb syntax
        for h in PaletteVerbs.hints {
            add(PaletteItem(id: "hint:" + h.verb, title: h.usage, subtitle: h.help, category: .hint, keywords: h.verb, insertText: h.verb + " "))
        }
        return items
    }
}

// MARK: - Search

enum PaletteSearch {
    /// Ranked results for a query: verbs and calculator first, then fuzzy score + frecency.
    static func search(_ query: String, items: [PaletteItem], frecency: PaletteFrecency?, now: Date = Date(), limit: Int = 60,
                       fontFamilies: [String]? = nil) -> [PaletteResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [PaletteResult] = []
        if q.isEmpty {
            // most used first, then a few starting points
            let used = items.filter { (frecency?.boost($0.id, now: now) ?? 0) > 0 }.sorted { (frecency?.boost($0.id, now: now) ?? 0) > (frecency?.boost($1.id, now: now) ?? 0) }
            out = used.prefix(8).map { PaletteResult(item: $0, score: frecency?.boost($0.id, now: now) ?? 0, matched: []) }
            let shown = Set(out.map(\.id))
            out += items.filter { $0.category == .hint && !shown.contains($0.id) }.prefix(max(0, 14 - out.count)).map { PaletteResult(item: $0, score: 0, matched: []) }
            return out
        }
        // quick verbs
        for v in PaletteVerbs.parse(q, fontFamilies: fontFamilies) {
            let ok = PaletteVerbs.isAvailable(v)
            out.append(PaletteResult(item: PaletteItem(id: "verb:" + v.key, title: v.title, subtitle: ok ? "Press ↩ to apply" : "Not available right now", category: .verb,
                                                       enabled: ok, run: { PaletteVerbs.perform(v) }), score: 1000 - Double(out.count), matched: []))
        }
        // calculator
        if let v = PaletteCalc.evaluate(q) {
            let text = PaletteCalc.format(v)
            out.append(PaletteResult(item: PaletteItem(id: "calc", title: "= \(text)", subtitle: "Press ↩ to copy the result", category: .calc, run: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                AppModel.shared.setStatus("Copied \(text).")
            }), score: 900, matched: []))
        }
        var scored: [PaletteResult] = []
        for it in items {
            let secondary = it.subtitle + " " + it.keywords + " " + it.category.rawValue
            guard let m = Fuzzy.match(q, title: it.title, secondary: secondary) else { continue }
            var s = m.score + (frecency?.boost(it.id, now: now) ?? 0) - Double(it.title.count) * 0.004
            if !it.enabled { s -= 3 }
            if it.category == .hint { s -= 0.4 }
            scored.append(PaletteResult(item: it, score: s, matched: m.positions))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.item.title < $1.item.title }
        return out + scored.prefix(limit)
    }
}
