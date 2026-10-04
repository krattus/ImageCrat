import Foundation

// Type model additions: lists, area type, dynamic text (fit to box), world-ready composer.
// All types decode tolerantly so older documents keep opening.

// MARK: - Lists

package enum ListKind: String, Codable, CaseIterable { case bullet, numbered }

package enum BulletGlyph: String, Codable, CaseIterable {
    case disc, dash, circle, square, arrow, check, custom
    package var glyph: String {
        switch self {
        case .disc: return "•"
        case .dash: return "–"
        case .circle: return "◦"
        case .square: return "▪"
        case .arrow: return "➤"
        case .check: return "✓"
        case .custom: return "★"
        }
    }
    package var displayName: String {
        switch self {
        case .disc: return "• Bullet"
        case .dash: return "– Dash"
        case .circle: return "◦ Circle"
        case .square: return "▪ Square"
        case .arrow: return "➤ Arrow"
        case .check: return "✓ Check"
        case .custom: return "Custom Glyph"
        }
    }
}

package enum NumberingStyle: String, Codable, CaseIterable {
    case decimal, lowerAlpha, upperAlpha, lowerRoman, upperRoman
    package var displayName: String {
        switch self {
        case .decimal: return "1, 2, 3"
        case .lowerAlpha: return "a, b, c"
        case .upperAlpha: return "A, B, C"
        case .lowerRoman: return "i, ii, iii"
        case .upperRoman: return "I, II, III"
        }
    }

    package func format(_ n: Int) -> String {
        switch self {
        case .decimal: return String(n)
        case .lowerAlpha: return NumberingStyle.alpha(n).lowercased()
        case .upperAlpha: return NumberingStyle.alpha(n)
        case .lowerRoman: return NumberingStyle.roman(n).lowercased()
        case .upperRoman: return NumberingStyle.roman(n)
        }
    }

    /// 1 → A, 26 → Z, 27 → AA …
    package static func alpha(_ n: Int) -> String {
        guard n > 0 else { return String(n) }
        var n = n, s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(65 + r)!) + s
            n = (n - 1) / 26
        }
        return s
    }

    package static func roman(_ n: Int) -> String {
        guard n > 0, n < 4000 else { return String(n) }
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = n, s = ""
        for (v, r) in table { while n >= v { s += r; n -= v } }
        return s
    }
}

/// Bulleted / numbered list settings (applied to every non-empty paragraph of the layer).
package struct TextListStyle: Codable, Equatable {
    package var kind: ListKind = .bullet
    package var bullet: BulletGlyph = .disc
    package var customGlyph: String = "★"
    package var numbering: NumberingStyle = .decimal
    package var start: Int = 1
    package var suffix: String = "."
    /// Hanging indent (px) between the marker position and the text; nil = automatic (fits the widest marker).
    package var hangingIndent: Double? = nil
    package var markerColor: RGBA? = nil

    /// Marker text of the `index`-th (0-based) list item.
    package func marker(_ index: Int) -> String {
        switch kind {
        case .bullet: return bullet == .custom ? (customGlyph.isEmpty ? "•" : customGlyph) : bullet.glyph
        case .numbered: return numbering.format(start + index) + suffix
        }
    }
    package init(kind: ListKind = .bullet, bullet: BulletGlyph = .disc, customGlyph: String = "★", numbering: NumberingStyle = .decimal, start: Int = 1, suffix: String = ".", hangingIndent: Double? = nil, markerColor: RGBA? = nil) {
        self.kind = kind; self.bullet = bullet; self.customGlyph = customGlyph; self.numbering = numbering; self.start = start; self.suffix = suffix; self.hangingIndent = hangingIndent; self.markerColor = markerColor
    }
}

extension TextListStyle {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TextListStyle()
        kind = (try? c.decodeIfPresent(ListKind.self, forKey: .kind)) ?? d.kind
        bullet = (try? c.decodeIfPresent(BulletGlyph.self, forKey: .bullet)) ?? d.bullet
        customGlyph = (try? c.decodeIfPresent(String.self, forKey: .customGlyph)) ?? d.customGlyph
        numbering = (try? c.decodeIfPresent(NumberingStyle.self, forKey: .numbering)) ?? d.numbering
        start = (try? c.decodeIfPresent(Int.self, forKey: .start)) ?? d.start
        suffix = (try? c.decodeIfPresent(String.self, forKey: .suffix)) ?? d.suffix
        hangingIndent = try? c.decodeIfPresent(Double.self, forKey: .hangingIndent)
        markerColor = try? c.decodeIfPresent(RGBA.self, forKey: .markerColor)
    }
}

// MARK: - Area type

/// Text that flows inside a closed path. `path` is in local text coordinates (origin = `TextContent.position`);
/// `TextContent.boxSize` is kept equal to the path's bounds size.
package struct AreaTextShape: Codable, Equatable {
    package var path: VectorPath
    /// Inset spacing (px) between the path and the text.
    package var inset: Double = 4
    package init(path: VectorPath, inset: Double = 4) {
        self.path = path; self.inset = inset
    }
}

extension AreaTextShape {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? c.decodeIfPresent(VectorPath.self, forKey: .path)) ?? VectorPath()
        inset = (try? c.decodeIfPresent(Double.self, forKey: .inset)) ?? 4
    }
}

// MARK: - Dynamic Text

/// Dynamic Text: sizes scale uniformly (and tracking optionally grows) so the text fills its box or shape.
package struct TextFit: Codable, Equatable {
    package var adjustTracking = false
    package var minSize: Double = 2
    package var maxSize: Double = 2000
    package init(adjustTracking: Bool = false, minSize: Double = 2, maxSize: Double = 2000) {
        self.adjustTracking = adjustTracking; self.minSize = minSize; self.maxSize = maxSize
    }
}

extension TextFit {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        adjustTracking = (try? c.decodeIfPresent(Bool.self, forKey: .adjustTracking)) ?? false
        minSize = (try? c.decodeIfPresent(Double.self, forKey: .minSize)) ?? 2
        maxSize = (try? c.decodeIfPresent(Double.self, forKey: .maxSize)) ?? 2000
    }
}

// MARK: - World-ready

package enum TextComposer: String, Codable, CaseIterable {
    case latin, worldReady
    package var displayName: String { self == .latin ? "Latin Composer" : "World-Ready Composer" }
}

package enum TextDirection: String, Codable, CaseIterable {
    case auto, ltr, rtl
    package var displayName: String {
        switch self {
        case .auto: return "Auto (first strong character)"
        case .ltr: return "Left-to-Right"
        case .rtl: return "Right-to-Left"
        }
    }
}

package enum ScriptDirection {
    /// Direction of the first strong character (Unicode bidi classes R / AL approximated by script ranges).
    package static func isRTL(_ s: String) -> Bool? {
        for u in s.unicodeScalars {
            let v = u.value
            if (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v)
                || (0x10800...0x10FFF).contains(v) || (0x1E800...0x1EFFF).contains(v) { return true }
            if u.properties.isAlphabetic { return false }
        }
        return nil
    }
}

extension TextContent {
    /// Layout options that make the on-canvas editor float beside the (live) layer.
    package var usesExtendedLayout: Bool { list != nil || area != nil || fitToBox != nil }

    /// Inserts `s` at UTF-16 `index`, shifting style runs (inserted text takes the style of the preceding character).
    package mutating func insertText(_ s: String, at index: Int) {
        let ns = text as NSString
        let i = max(0, min(ns.length, index))
        let len = (s as NSString).length
        text = ns.replacingCharacters(in: NSRange(location: i, length: 0), with: s)
        runs = runs.map { r in
            var r = r
            if r.location >= i {
                r.location += len
            } else if r.end >= i {
                r.length += len
            }
            return r
        }
        normalizeRuns()
    }
}
