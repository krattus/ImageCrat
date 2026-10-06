import AppKit
import SwiftUI
import CoreText
import ImageCratCore

// MARK: - Glyph catalog

/// One glyph of a font with the Unicode scalars that map to it (empty = unencoded, e.g. an alternate).
struct GlyphInfo: Identifiable, Hashable {
    let glyph: CGGlyph
    let scalars: [UInt32]
    var id: CGGlyph { glyph }
    var text: String? { scalars.first.flatMap { UnicodeScalar($0) }.map { String(Character($0)) } }
}

enum GlyphCategory: String, CaseIterable, Identifiable {
    case all = "Entire Font"
    case recent = "Recently Used"
    case alternates = "Alternates for Selection"
    case letters = "Letters"
    case marks = "Marks"
    case numbers = "Numbers"
    case punctuation = "Punctuation"
    case symbols = "Symbols"
    case emoji = "Emoji"
    case other = "Separators & Other"
    case unencoded = "Unencoded Glyphs"
    var id: String { rawValue }

    static func of(_ v: UInt32) -> GlyphCategory {
        guard let u = UnicodeScalar(v) else { return .other }
        if u.properties.isEmojiPresentation { return .emoji }
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return .letters
        case .nonspacingMark, .spacingMark, .enclosingMark: return .marks
        case .decimalNumber, .letterNumber, .otherNumber: return .numbers
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation: return .punctuation
        case .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: return u.properties.isEmoji && v > 0x2000 ? .emoji : .symbols
        default: return .other
        }
    }
}

final class GlyphCatalog: @unchecked Sendable {
    static let shared = GlyphCatalog()
    private let lock = NSLock()
    private var cache: [String: [GlyphInfo]] = [:]
    private var reverse: [String: [UInt32: CGGlyph]] = [:]

    /// All glyphs of the font, in glyph-id order.
    func glyphs(_ fontName: String) -> [GlyphInfo] {
        lock.lock()
        if let c = cache[fontName] { lock.unlock(); return c }
        lock.unlock()
        let f = CTFontCreateWithName(fontName as CFString, 12, nil)
        let count = CTFontGetGlyphCount(f)
        var map: [CGGlyph: [UInt32]] = [:]
        var rev: [UInt32: CGGlyph] = [:]
        let cs = CTFontCopyCharacterSet(f)
        for plane in 0...16 where CFCharacterSetHasMemberInPlane(cs, CFIndex(plane)) {
            let lo = UInt32(plane) << 16
            for v in lo..<(lo + 0x10000) where CFCharacterSetIsLongCharacterMember(cs, v) {
                guard let u = UnicodeScalar(v) else { continue }
                let utf16 = Array(String(Character(u)).utf16)
                var gl = [CGGlyph](repeating: 0, count: utf16.count)
                if CTFontGetGlyphsForCharacters(f, utf16, &gl, utf16.count), gl[0] != 0 {
                    map[gl[0], default: []].append(v)
                    rev[v] = gl[0]
                }
            }
        }
        var out: [GlyphInfo] = []
        out.reserveCapacity(count)
        for g in 0..<count {
            let gg = CGGlyph(g)
            if gg == 0 && map[gg] == nil { continue }  // .notdef
            out.append(GlyphInfo(glyph: gg, scalars: map[gg] ?? []))
        }
        lock.lock(); cache[fontName] = out; reverse[fontName] = rev; lock.unlock()
        return out
    }

    func glyph(for scalar: UInt32, fontName: String) -> CGGlyph? {
        _ = glyphs(fontName)
        lock.lock(); defer { lock.unlock() }
        return reverse[fontName]?[scalar]
    }

    static func glyphName(_ g: CGGlyph, fontName: String) -> String? {
        let f = CTFontCreateWithName(fontName as CFString, 12, nil)
        let cg = CTFontCopyGraphicsFont(f, nil)
        return cg.name(for: g) as String?
    }

    /// Glyphs matching a filter and a search string (character, U+hex, Unicode name or glyph name).
    func filtered(_ fontName: String, category: GlyphCategory, search: String) -> [GlyphInfo] {
        var list = glyphs(fontName)
        switch category {
        case .all, .recent, .alternates: break
        case .unencoded: list = list.filter { $0.scalars.isEmpty }
        default: list = list.filter { g in g.scalars.contains { GlyphCategory.of($0) == category } }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        var hex: UInt32? = nil
        let up = q.uppercased()
        if up.hasPrefix("U+") { hex = UInt32(up.dropFirst(2), radix: 16) } else if q.count >= 4, let h = UInt32(q, radix: 16) { hex = h }
        let scalarsOfQuery = q.count <= 2 ? Set(q.unicodeScalars.map(\.value)) : []
        return list.filter { g in
            if let h = hex, g.scalars.contains(h) { return true }
            if !scalarsOfQuery.isEmpty, g.scalars.contains(where: { scalarsOfQuery.contains($0) }) { return true }
            if q.count >= 2 {
                for v in g.scalars {
                    if let n = UnicodeScalar(v)?.properties.name, n.localizedCaseInsensitiveContains(q) { return true }
                }
                if let n = GlyphCatalog.glyphName(g.glyph, fontName: fontName), n.localizedCaseInsensitiveContains(q) { return true }
            }
            return false
        }
    }
}

// MARK: - Alternates (OpenType / AAT feature selectors)

struct GlyphAlternate: Hashable, Identifiable {
    let glyph: CGGlyph
    /// Feature key for `OpenTypeFeatures.extra`: OpenType tag ("ss01", "salt", "swsh") or "aat:<type>:<selector>".
    let key: String
    let value: Int
    let label: String
    var id: String { "\(key)=\(value)" }
    var extra: [String: Int] { [key: value] }
}

enum GlyphAlternates {
    /// Features that never produce a user-selectable alternate.
    private static let skipped: Set<String> = ["kern", "liga", "clig", "calt", "ccmp", "locl", "mark", "mkmk", "rlig", "rvrn", "REQD", "dpng",
                                               "case", "curs", "dist", "abvm", "blwm", "init", "medi", "fina", "isol"]
    private nonisolated(unsafe) static var featureCache: [String: [(String, Int, String)]] = [:]
    private nonisolated(unsafe) static var altCache: [String: [GlyphAlternate]] = [:]
    private static let lock = NSLock()

    /// (key, value, label) feature settings offered by the font (OpenType tags when exposed, else AAT selectors).
    static func features(_ fontName: String) -> [(String, Int, String)] {
        lock.lock()
        if let c = featureCache[fontName] { lock.unlock(); return c }
        lock.unlock()
        let f = CTFontCreateWithName(fontName as CFString, 12, nil)
        var out: [(String, Int, String)] = []
        var aat: [(String, Int, String)] = []
        var seen = Set<String>()
        for feat in (CTFontCopyFeatures(f) as? [[String: Any]]) ?? [] {
            let ty = (feat[kCTFontFeatureTypeIdentifierKey as String] as? NSNumber)?.intValue ?? -1
            let tname = feat[kCTFontFeatureTypeNameKey as String] as? String ?? "Feature \(ty)"
            if ty == 0 || ty == 1 || ty == 2 { continue }   // all typographic features, ligatures, cursive connection
            for sel in (feat[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]]) ?? [] {
                let sname = sel[kCTFontFeatureSelectorNameKey as String] as? String ?? ""
                if let tag = sel[kCTFontOpenTypeFeatureTag as String] as? String {
                    let v = (sel[kCTFontOpenTypeFeatureValue as String] as? NSNumber)?.intValue ?? 1
                    guard v != 0, !skipped.contains(tag), seen.insert("\(tag)=\(v)").inserted else { continue }
                    out.append((tag, v, sname.isEmpty ? tag : "\(sname) (\(tag))"))
                } else if let se = (sel[kCTFontFeatureSelectorIdentifierKey as String] as? NSNumber)?.intValue {
                    let key = "aat:\(ty):\(se)"
                    guard seen.insert(key).inserted else { continue }
                    aat.append((key, 1, sname.isEmpty ? tname : "\(tname): \(sname)"))
                }
            }
        }
        // Common OpenType tags Core Text may not list for some fonts.
        for tag in ["salt", "swsh", "ss01", "ss02", "ss03", "ss04", "ss05", "ss06", "ss07", "ss08", "cv01", "cv02", "titl", "hist", "nalt", "ornm"] where !seen.contains("\(tag)=1") {
            seen.insert("\(tag)=1")
            out.append((tag, 1, tag))
        }
        for v in 1...6 { out.append(("aalt", v, "Access All Alternates #\(v)")) }
        // AAT selectors last: OpenType tags are preferred when both reach the same glyph.
        out += aat
        lock.lock(); featureCache[fontName] = out; lock.unlock()
        return out
    }

    /// First glyph produced by shaping `s` with `font`.
    static func shapedGlyph(_ s: String, _ font: CTFont) -> CGGlyph? {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
        guard let r = (CTLineGetGlyphRuns(line) as! [CTRun]).first, CTRunGetGlyphCount(r) > 0 else { return nil }
        let f = (CTRunGetAttributes(r) as NSDictionary)[kCTFontAttributeName as String]
        if let f, CTFontCopyPostScriptName(f as! CTFont) != CTFontCopyPostScriptName(font) { return nil }   // fallback font
        var g: CGGlyph = 0
        CTRunGetGlyphs(r, CFRange(location: 0, length: 1), &g)
        return g
    }

    /// Alternate glyphs for `s` (a character or ligature) in the font, excluding the default glyph.
    static func alternates(for s: String, fontName: String) -> [GlyphAlternate] {
        let key = "\(fontName)|\(s)"
        lock.lock()
        if let c = altCache[key] { lock.unlock(); return c }
        lock.unlock()
        let base = TextRenderer.makeFont(name: fontName, size: 40)
        var out: [GlyphAlternate] = []
        if let g0 = shapedGlyph(s, base) {
            var seen: Set<CGGlyph> = [g0]
            for (k, v, label) in features(fontName) {
                var of = OpenTypeFeatures()
                of.extra = [k: v]
                let f = TextRenderer.makeFont(name: fontName, size: 40, features: of)
                if let g = shapedGlyph(s, f), g != 0, seen.insert(g).inserted {
                    out.append(GlyphAlternate(glyph: g, key: k, value: v, label: label))
                }
            }
        }
        lock.lock(); altCache[key] = out; lock.unlock()
        return out
    }

    /// For an unencoded glyph: a string and feature setting that produce it (via its glyph name, e.g. "a.ss01", "f_f_i").
    static func resolveUnencoded(_ glyph: CGGlyph, fontName: String) -> (String, GlyphAlternate?)? {
        if let s = EmojiText.sequence(for: glyph, fontName: fontName) { return (s, nil) }   // flags, skin tones, ZWJ sequences
        var candidates: [String] = []
        if let name = GlyphCatalog.glyphName(glyph, fontName: fontName) {
            let baseName = String(name.split(separator: ".").first ?? Substring(name))
            let f = CTFontCreateWithName(fontName as CFString, 12, nil)
            let cg = CTFontCopyGraphicsFont(f, nil)
            var str = ""
            for comp in baseName.split(separator: "_") {
                let c = String(comp)
                if c.hasPrefix("uni"), c.count == 7, let v = UInt32(c.dropFirst(3), radix: 16), let u = UnicodeScalar(v) { str.append(Character(u)); continue }
                if c.hasPrefix("u"), c.count >= 5, let v = UInt32(c.dropFirst(1), radix: 16), let u = UnicodeScalar(v) { str.append(Character(u)); continue }
                let g = cg.getGlyphWithGlyphName(name: c as CFString)
                if g != 0, let info = GlyphCatalog.shared.glyphs(fontName).first(where: { $0.glyph == g }), let t = info.text { str += t } else { str = ""; break }
            }
            if !str.isEmpty { candidates.append(str) }
        }
        // fallback: ASCII letters, digits, punctuation
        candidates += (33...126).compactMap { UnicodeScalar($0).map { String(Character($0)) } }
        for s in candidates {
            if let a = alternates(for: s, fontName: fontName).first(where: { $0.glyph == glyph }) { return (s, a) }
        }
        return nil
    }
}

// MARK: - Glyph images

enum GlyphImage {
    private nonisolated(unsafe) static var cache: [String: NSImage] = [:]

    /// Glyph drawn centered in a `side`×`side` image (colour glyphs keep their colours).
    static func image(fontName: String, glyph: CGGlyph, side: CGFloat, color: NSColor, extra: [String: Int] = [:]) -> NSImage {
        let key = "\(fontName)|\(glyph)|\(side)|\(color.description)"
        if let c = cache[key] { return c }
        let probe = CTFontCreateWithName(fontName as CFString, 100, nil)
        let h = CTFontGetAscent(probe) + CTFontGetDescent(probe)
        let size = max(4, side * 0.72 * 100 / max(1, h))
        let f = CTFontCreateWithName(fontName as CFString, size, nil)
        var g = glyph
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(f, .horizontal, &g, &adv, 1)
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(color.cgColor)
            let asc = CTFontGetAscent(f), desc = CTFontGetDescent(f)
            var bounds = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(f, .horizontal, &g, &bounds, 1)
            let w = adv.width > 0.5 ? adv.width : bounds.width
            let x = (side - w) / 2 - (adv.width > 0.5 ? 0 : bounds.minX)
            let y = (side - (asc + desc)) / 2 + desc
            var p = CGPoint(x: x, y: y)
            CTFontDrawGlyphs(f, &g, &p, 1, ctx)
            return true
        }
        if cache.count > 4000 { cache.removeAll() }
        cache[key] = img
        return img
    }
}

// MARK: - Recently used

struct RecentGlyph: Codable, Hashable {
    var fontName: String
    var glyph: Int
    var text: String
    var extra: [String: Int]
}

enum RecentGlyphs {
    static let key = "Lumen.RecentGlyphs"
    static var all: [RecentGlyph] {
        guard let d = UserDefaults.standard.data(forKey: key), let v = try? JSONDecoder().decode([RecentGlyph].self, from: d) else { return [] }
        return v
    }
    static func add(_ r: RecentGlyph) {
        var list = all.filter { $0 != r }
        list.insert(r, at: 0)
        if list.count > 40 { list.removeLast(list.count - 40) }
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: key) }
    }
}

// MARK: - Insertion

enum GlyphInsert {
    /// Inserts a glyph into the active type editor (starting one on the active type layer if needed).
    @discardableResult
    static func insert(fontName: String, glyph: CGGlyph, text: String?, extra: [String: Int] = [:]) -> Bool {
        var s = text
        var ex = extra
        if s == nil, let (str, alt) = GlyphAlternates.resolveUnencoded(glyph, fontName: fontName) {
            s = str; ex = alt?.extra ?? [:]
        }
        guard let str = s else { AppModel.shared.setStatus("This glyph has no Unicode value or known feature and can't be inserted."); return false }
        if TextTool.editing == nil, let d = AppActions.doc, let id = d.activeLayerID, d.state.layer(id)?.text != nil, let c = AppActions.canvas {
            AppModel.shared.tool = .text
            if let tool = c.tool(for: .text) as? TextTool {
                tool.beginEditing(id, isNew: false)
                if let tv = tool.editorTextView { tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0)) }
            }
        }
        guard let tool = TextTool.editing else {
            // nothing to type into: the glyph becomes a new type layer (like a character from the Character Viewer)
            if let c = AppActions.canvas, TypeInput.insert(str, canvas: c, typed: true, fontName: fontName, features: ex) {
                RecentGlyphs.add(RecentGlyph(fontName: fontName, glyph: Int(glyph), text: str, extra: ex))
                return true
            }
            AppModel.shared.setStatus("Click with the Type tool to insert glyphs.")
            return false
        }
        let shownFont = tool.shownContent?.fontName
        // (a colour emoji font is left to font fallback: as a run it would also catch the characters typed after it)
        tool.insertGlyphText(str, extra: ex, fontName: shownFont == fontName || EmojiText.isColorFont(fontName) ? nil : fontName)
        RecentGlyphs.add(RecentGlyph(fontName: fontName, glyph: Int(glyph), text: str, extra: ex))
        return true
    }
}

// MARK: - Glyphs panel

@Observable
final class GlyphsPanelModel {
    static let shared = GlyphsPanelModel()
    var fontOverride: String? = nil
    var category: GlyphCategory = .all
    var search = ""
    var selected: CGGlyph? = nil
    var cellSize: CGFloat = 34
    var recentTick = 0

    /// Font of the type selection, the active type layer, or the Type tool default.
    var contextFont: String {
        _ = TypeEditState.shared.tick
        if let t = TextTool.editing?.shownContent { return t.fontName }
        if let t = AppModel.shared.activeDocument?.activeLayer?.text { return TypeEdit.shown(t).fontName }
        return AppModel.shared.textTool.fontName
    }
    var fontName: String { fontOverride ?? contextFont }
}

struct GlyphsPanel: View {
    @Bindable var m = GlyphsPanelModel.shared

    var body: some View {
        let _ = TypeEditState.shared.tick
        let font = m.fontName
        let shown = GlyphsPanel.catalogFont(font, m.category)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                FontPicker(fontName: Binding(get: { font }, set: { m.fontOverride = $0 }), wraps: true)
                if m.fontOverride != nil {
                    IconButton(symbol: "arrow.uturn.backward", help: "Follow the type selection's font") { m.fontOverride = nil }
                }
            }
            HStack(spacing: 4) {
                Picker("", selection: $m.category) {
                    ForEach(GlyphCategory.allCases) { Text(tr($0.rawValue)).tag($0) }
                }
                .labelsHidden()
                .frame(minWidth: 80, idealWidth: 150, maxWidth: 150)
                TextField("Search (a, U+0041, name)", text: $m.search)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
            grid(shown)
            footer(shown)
        }
        .padding(8)
        .font(Theme.font)
    }

    /// Font whose glyphs are listed: the Emoji category of a font without emoji shows Apple Color Emoji.
    static func catalogFont(_ font: String, _ category: GlyphCategory) -> String {
        guard category == .emoji, FontLookup.installed("AppleColorEmoji"),
              !GlyphCatalog.shared.filtered(font, category: .emoji, search: "").contains(where: { $0.scalars.contains { UnicodeScalar($0)?.properties.isEmojiPresentation == true } })
        else { return font }
        return "AppleColorEmoji"
    }

    private struct Cell: Identifiable, Hashable {
        let id: String
        let fontName: String
        let glyph: CGGlyph
        let text: String?
        let extra: [String: Int]
        let label: String
    }

    private func cells(_ font: String) -> [Cell] {
        _ = m.recentTick
        switch m.category {
        case .recent:
            return RecentGlyphs.all.map { r in Cell(id: "r\(r.fontName)\(r.glyph)\(r.extra)", fontName: r.fontName, glyph: CGGlyph(r.glyph), text: r.text, extra: r.extra, label: r.text) }
        case .alternates:
            guard let tool = TextTool.editing, let tv = tool.editorTextView, let shown = tool.shownContent else { return [] }
            let sel = tv.selectedRange()
            let ns = tv.string as NSString
            guard sel.location < ns.length else { return [] }
            let r = sel.length > 0 ? sel : ns.rangeOfComposedCharacterSequence(at: max(0, sel.location - 1))
            let ch = ns.substring(with: r)
            guard (ch as NSString).length <= 8 else { return [] }
            var out: [Cell] = []
            if let g0 = GlyphAlternates.shapedGlyph(ch, TextRenderer.makeFont(name: shown.fontName, size: 40)) {
                out.append(Cell(id: "a-default", fontName: shown.fontName, glyph: g0, text: ch, extra: [:], label: "Default"))
            }
            out += GlyphAlternates.alternates(for: ch, fontName: shown.fontName).map { a in
                Cell(id: "a\(a.id)", fontName: shown.fontName, glyph: a.glyph, text: ch, extra: a.extra, label: a.label)
            }
            return out
        default:
            return GlyphCatalog.shared.filtered(font, category: m.category, search: m.search).map { g in
                Cell(id: "g\(g.glyph)", fontName: font, glyph: g.glyph, text: g.text, extra: [:], label: g.text ?? "")
            }
        }
    }

    @ViewBuilder private func grid(_ font: String) -> some View {
        let list = cells(font)
        let side = m.cellSize
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: side, maximum: side), spacing: 2)], spacing: 2) {
                ForEach(list) { c in
                    Image(nsImage: GlyphImage.image(fontName: c.fontName, glyph: c.glyph, side: side, color: NSColor(Theme.text)))
                        .frame(width: side, height: side)
                        .background(RoundedRectangle(cornerRadius: 3).fill(m.selected == c.glyph ? Theme.selection : Theme.fieldBG))
                        .help(tr(helpText(c)))
                        .onTapGesture(count: 2) { activate(c) }
                        .onTapGesture { m.selected = c.glyph }
                        .onDrag { GlyphInsert.dragProvider(fontName: c.fontName, glyph: c.glyph, text: c.text) }
                }
            }
        }
        .frame(minHeight: 120)
        if list.isEmpty {
            Text(tr(m.category == .alternates ? "Select a character in the type editor to see its alternates." : "No glyphs")).foregroundStyle(Theme.textFaint)
        }
    }

    private func helpText(_ c: Cell) -> String {
        var parts: [String] = []
        if let t = c.text, let u = t.unicodeScalars.first {
            parts.append(String(format: "U+%04X", u.value) + (u.properties.name.map { " " + $0 } ?? ""))
        }
        if let n = GlyphCatalog.glyphName(c.glyph, fontName: c.fontName) { parts.append("glyph \(c.glyph) “\(n)”") }
        if !c.extra.isEmpty { parts.append(c.label) }
        return parts.joined(separator: "\n") + "\nDouble-click to insert, or drag onto the canvas"
    }

    private func activate(_ c: Cell) {
        if m.category == .alternates, let tool = TextTool.editing {
            tool.applyAlternate(c.extra)
        } else {
            GlyphInsert.insert(fontName: c.fontName, glyph: c.glyph, text: c.text, extra: c.extra)
        }
        m.recentTick += 1
    }

    @ViewBuilder private func footer(_ font: String) -> some View {
        HStack {
            if let g = m.selected, let info = GlyphCatalog.shared.glyphs(font).first(where: { $0.glyph == g }) {
                let code = info.scalars.first.map { String(format: "U+%04X", $0) } ?? "unencoded"
                Text("\(code)  ·  \(GlyphCatalog.glyphName(g, fontName: font) ?? "#\(g)")").foregroundStyle(Theme.textDim).lineLimit(1)
            } else {
                Text("\(GlyphCatalog.shared.glyphs(font).count) glyphs").foregroundStyle(Theme.textFaint)
            }
            Spacer()
            Slider(value: $m.cellSize, in: 24...64).controlSize(.mini).frame(width: 70)
        }
    }
}

// MARK: - On-canvas alternates popup

/// Small strip of alternates shown under a single selected character in the type editor.
final class GlyphAlternatesPopup {
    static let shared = GlyphAlternatesPopup()
    private var host: NSHostingView<AnyView>?
    private(set) var shownAlternates: [GlyphAlternate] = []

    var isVisible: Bool { host?.superview != nil }

    func hide() {
        host?.removeFromSuperview()
        host = nil
        shownAlternates = []
    }

    func update(for tool: TextTool) {
        guard let tv = tool.editorTextView, let shown = tool.shownContent else { hide(); return }
        let sel = tv.selectedRange()
        let ns = tv.string as NSString
        guard sel.length > 0, sel.location + sel.length <= ns.length,
              NSEqualRanges(ns.rangeOfComposedCharacterSequence(at: sel.location), sel) else { hide(); return }
        let ch = ns.substring(with: sel)
        let alts = Array(GlyphAlternates.alternates(for: ch, fontName: shown.fontName).prefix(10))
        guard !alts.isEmpty, let lm = tv.layoutManager, let tc = tv.textContainer else { hide(); return }
        shownAlternates = alts
        let gr = lm.glyphRange(forCharacterRange: sel, actualCharacterRange: nil)
        var r = lm.boundingRect(forGlyphRange: gr, in: tc)
        r = r.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
        let canvas = tool.canvas
        let rc = tv.convert(r, to: canvas)
        let fontName = shown.fontName
        let current = shown.features.extra
        let side: CGFloat = 30
        let view = AnyView(
            HStack(spacing: 2) {
                ForEach(alts) { a in
                    Button { [weak tool] in
                        tool?.applyAlternate(current == a.extra ? [:] : a.extra)
                        if let tv = tool?.editorTextView { tv.window?.makeFirstResponder(tv) }
                    } label: {
                        Image(nsImage: GlyphImage.image(fontName: fontName, glyph: a.glyph, side: side, color: .white))
                            .frame(width: side, height: side)
                            .background(RoundedRectangle(cornerRadius: 3).fill(current == a.extra ? Color.accentColor.opacity(0.7) : Color(white: 0.25)))
                    }
                    .buttonStyle(.plain)
                    .help(tr(a.label))
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.13)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(white: 0.35), lineWidth: 0.5))
        )
        let h = host ?? NSHostingView(rootView: view)
        h.rootView = view
        let size = CGSize(width: CGFloat(alts.count) * (side + 2) + 6, height: side + 6)
        var origin = CGPoint(x: rc.minX, y: rc.maxY + 6)
        if origin.y + size.height > canvas.bounds.maxY { origin.y = rc.minY - size.height - 6 }
        origin.x = min(max(0, origin.x), max(0, canvas.bounds.maxX - size.width))
        h.frame = CGRect(origin: origin, size: size)
        if h.superview !== canvas { canvas.addSubview(h) }
        host = h
    }
}
