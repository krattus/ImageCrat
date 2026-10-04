import Foundation

// MARK: - Raster

package struct RasterContent: Codable {
    package var buffer: PixelBuffer
    package var origin: IPoint

    package var frame: IRect { IRect(x: origin.x, y: origin.y, width: buffer.width, height: buffer.height) }
    package init(buffer: PixelBuffer, origin: IPoint) {
        self.buffer = buffer; self.origin = origin
    }
}

// MARK: - Text

package enum TextAlign: String, Codable, CaseIterable {
    /// `justify` = justify, last line left (Photoshop "Justify Last Left").
    case left, center, right, justify, justifyCenter, justifyRight, justifyAll

    /// The basic four (options bar); `paragraphCases` has all seven Photoshop variants.
    package static var allCases: [TextAlign] { [.left, .center, .right, .justify] }
    package static var paragraphCases: [TextAlign] { [.left, .center, .right, .justify, .justifyCenter, .justifyRight, .justifyAll] }

    package var isJustified: Bool { self == .justify || self == .justifyCenter || self == .justifyRight || self == .justifyAll }
    package var symbol: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        case .justify: return "text.justify.left"
        case .justifyCenter: return "text.justify"
        case .justifyRight: return "text.justify.right"
        case .justifyAll: return "text.justify"
        }
    }
    package var displayName: String {
        switch self {
        case .left: return "Left Align Text"
        case .center: return "Center Text"
        case .right: return "Right Align Text"
        case .justify: return "Justify Last Left"
        case .justifyCenter: return "Justify Last Centered"
        case .justifyRight: return "Justify Last Right"
        case .justifyAll: return "Justify All"
        }
    }
}

package enum TextOrientation: String, Codable, CaseIterable { case horizontal, vertical }

/// OpenType feature toggles (applied through CTFontDescriptor feature settings).
package struct OpenTypeFeatures: Codable, Equatable, Hashable {
    package var standardLigatures = true
    package var discretionaryLigatures = false
    package var oldStyleFigures = false
    package var smallCaps = false
    package var fractions = false
    package var ordinals = false
    package var swash = false
    package var stylisticAlternates = false
    /// Extra per-glyph feature settings (Glyphs panel alternates): OpenType tag → value (e.g. "ss02": 1, "aalt": 3),
    /// or "aat:<type>:<selector>" → 1 for AAT-only fonts.
    package var extra: [String: Int] = [:]

    /// (OpenType tag, value) pairs that differ from the font's defaults.
    package var tagSettings: [(String, Int)] {
        var s: [(String, Int)] = []
        if !standardLigatures { s.append(("liga", 0)); s.append(("clig", 0)) }
        if discretionaryLigatures { s.append(("dlig", 1)) }
        if oldStyleFigures { s.append(("onum", 1)) }
        if smallCaps { s.append(("smcp", 1)) }
        if fractions { s.append(("frac", 1)) }
        if ordinals { s.append(("ordn", 1)) }
        if swash { s.append(("swsh", 1)) }
        if stylisticAlternates { s.append(("salt", 1)) }
        for (k, v) in extra.sorted(by: { $0.key < $1.key }) where !k.hasPrefix("aat:") { s.append((k, v)) }
        return s
    }
    package init(standardLigatures: Bool = true, discretionaryLigatures: Bool = false, oldStyleFigures: Bool = false, smallCaps: Bool = false, fractions: Bool = false, ordinals: Bool = false, swash: Bool = false, stylisticAlternates: Bool = false, extra: [String: Int] = [:]) {
        self.standardLigatures = standardLigatures; self.discretionaryLigatures = discretionaryLigatures; self.oldStyleFigures = oldStyleFigures; self.smallCaps = smallCaps; self.fractions = fractions; self.ordinals = ordinals; self.swash = swash; self.stylisticAlternates = stylisticAlternates; self.extra = extra
    }
}

extension OpenTypeFeatures {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OpenTypeFeatures()
        standardLigatures = try c.decodeIfPresent(Bool.self, forKey: .standardLigatures) ?? d.standardLigatures
        discretionaryLigatures = try c.decodeIfPresent(Bool.self, forKey: .discretionaryLigatures) ?? d.discretionaryLigatures
        oldStyleFigures = try c.decodeIfPresent(Bool.self, forKey: .oldStyleFigures) ?? d.oldStyleFigures
        smallCaps = try c.decodeIfPresent(Bool.self, forKey: .smallCaps) ?? d.smallCaps
        fractions = try c.decodeIfPresent(Bool.self, forKey: .fractions) ?? d.fractions
        ordinals = try c.decodeIfPresent(Bool.self, forKey: .ordinals) ?? d.ordinals
        swash = try c.decodeIfPresent(Bool.self, forKey: .swash) ?? d.swash
        stylisticAlternates = try c.decodeIfPresent(Bool.self, forKey: .stylisticAlternates) ?? d.stylisticAlternates
        extra = (try? c.decodeIfPresent([String: Int].self, forKey: .extra)) ?? [:]
    }
}

/// Per-range character overrides (nil = use the layer-level value).
package struct CharacterStyle: Codable, Equatable {
    package var fontName: String?
    package var fontSize: Double?
    package var color: RGBA?
    package var tracking: Double?
    package var baselineShift: Double?
    package var fauxBold: Bool?
    package var fauxItalic: Bool?
    package var underline: Bool?
    package var strikethrough: Bool?
    package var horizontalScale: Double?
    package var verticalScale: Double?
    package var features: OpenTypeFeatures?
    /// Variable-font axis values (axis tag such as "wght" → value).
    package var variations: [String: Double]?

    package var isEmpty: Bool { self == CharacterStyle() }

    /// `o`'s non-nil fields win.
    package func merging(_ o: CharacterStyle) -> CharacterStyle {
        var r = self
        if let v = o.fontName { r.fontName = v }
        if let v = o.fontSize { r.fontSize = v }
        if let v = o.color { r.color = v }
        if let v = o.tracking { r.tracking = v }
        if let v = o.baselineShift { r.baselineShift = v }
        if let v = o.fauxBold { r.fauxBold = v }
        if let v = o.fauxItalic { r.fauxItalic = v }
        if let v = o.underline { r.underline = v }
        if let v = o.strikethrough { r.strikethrough = v }
        if let v = o.horizontalScale { r.horizontalScale = v }
        if let v = o.verticalScale { r.verticalScale = v }
        if let v = o.features { r.features = v }
        if let v = o.variations { r.variations = v }
        return r
    }

    /// Drops fields that are set in `o` (used when a layer-wide change resets overrides).
    package func removingFields(of o: CharacterStyle) -> CharacterStyle {
        var r = self
        if o.fontName != nil { r.fontName = nil }
        if o.fontSize != nil { r.fontSize = nil }
        if o.color != nil { r.color = nil }
        if o.tracking != nil { r.tracking = nil }
        if o.baselineShift != nil { r.baselineShift = nil }
        if o.fauxBold != nil { r.fauxBold = nil }
        if o.fauxItalic != nil { r.fauxItalic = nil }
        if o.underline != nil { r.underline = nil }
        if o.strikethrough != nil { r.strikethrough = nil }
        if o.horizontalScale != nil { r.horizontalScale = nil }
        if o.verticalScale != nil { r.verticalScale = nil }
        if o.features != nil { r.features = nil }
        if o.variations != nil { r.variations = nil }
        return r
    }

    /// Removes overrides equal to the layer defaults.
    package func normalized(against t: TextContent) -> CharacterStyle {
        var r = self
        if r.fontName == t.fontName { r.fontName = nil }
        if let v = r.fontSize, abs(v - t.fontSize) < 1e-6 { r.fontSize = nil }
        if r.color == t.color { r.color = nil }
        if let v = r.tracking, abs(v - t.tracking) < 1e-6 { r.tracking = nil }
        if let v = r.baselineShift, abs(v - t.baselineShift) < 1e-6 { r.baselineShift = nil }
        if r.fauxBold == t.fauxBold { r.fauxBold = nil }
        if r.fauxItalic == t.fauxItalic { r.fauxItalic = nil }
        if r.underline == t.underline { r.underline = nil }
        if r.strikethrough == t.strikethrough { r.strikethrough = nil }
        if let v = r.horizontalScale, abs(v - t.horizontalScale) < 1e-6 { r.horizontalScale = nil }
        if let v = r.verticalScale, abs(v - t.verticalScale) < 1e-6 { r.verticalScale = nil }
        if r.features == t.features { r.features = nil }
        if r.variations == t.variations { r.variations = nil }
        return r
    }

    /// The character fields that differ between `a` and `b` (values from `b`).
    package static func diff(_ a: TextContent, _ b: TextContent) -> CharacterStyle {
        var r = CharacterStyle()
        if a.fontName != b.fontName { r.fontName = b.fontName }
        if a.fontSize != b.fontSize { r.fontSize = b.fontSize }
        if a.color != b.color { r.color = b.color }
        if a.tracking != b.tracking { r.tracking = b.tracking }
        if a.baselineShift != b.baselineShift { r.baselineShift = b.baselineShift }
        if a.fauxBold != b.fauxBold { r.fauxBold = b.fauxBold }
        if a.fauxItalic != b.fauxItalic { r.fauxItalic = b.fauxItalic }
        if a.underline != b.underline { r.underline = b.underline }
        if a.strikethrough != b.strikethrough { r.strikethrough = b.strikethrough }
        if a.horizontalScale != b.horizontalScale { r.horizontalScale = b.horizontalScale }
        if a.verticalScale != b.verticalScale { r.verticalScale = b.verticalScale }
        if a.features != b.features { r.features = b.features }
        if a.variations != b.variations { r.variations = b.variations }
        return r
    }
    package init(fontName: String? = nil, fontSize: Double? = nil, color: RGBA? = nil, tracking: Double? = nil, baselineShift: Double? = nil, fauxBold: Bool? = nil, fauxItalic: Bool? = nil, underline: Bool? = nil, strikethrough: Bool? = nil, horizontalScale: Double? = nil, verticalScale: Double? = nil, features: OpenTypeFeatures? = nil, variations: [String: Double]? = nil) {
        self.fontName = fontName; self.fontSize = fontSize; self.color = color; self.tracking = tracking; self.baselineShift = baselineShift; self.fauxBold = fauxBold; self.fauxItalic = fauxItalic; self.underline = underline; self.strikethrough = strikethrough; self.horizontalScale = horizontalScale; self.verticalScale = verticalScale; self.features = features; self.variations = variations
    }
}

/// A styled range of a text layer. `location`/`length` are UTF-16 offsets into `TextContent.text`.
package struct TextStyleRun: Codable, Equatable {
    package var location: Int
    package var length: Int
    package var style: CharacterStyle

    package var range: NSRange { NSRange(location: location, length: length) }
    package var end: Int { location + length }
    package init(location: Int, length: Int, style: CharacterStyle) {
        self.location = location; self.length = length; self.style = style
    }
}

/// Warp Text (reuses the Edit ▸ Transform ▸ Warp presets). Values in -100…100.
package struct TextWarp: Codable, Equatable {
    package var style: WarpStyle = .arc
    package var bend: Double = 50
    package var horizontalDistortion: Double = 0
    package var verticalDistortion: Double = 0

    package var isIdentity: Bool { style == .none || (bend == 0 && horizontalDistortion == 0 && verticalDistortion == 0) }
    package init(style: WarpStyle = .arc, bend: Double = 50, horizontalDistortion: Double = 0, verticalDistortion: Double = 0) {
        self.style = style; self.bend = bend; self.horizontalDistortion = horizontalDistortion; self.verticalDistortion = verticalDistortion
    }
}

extension TextWarp {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TextWarp()
        style = try c.decodeIfPresent(WarpStyle.self, forKey: .style) ?? d.style
        bend = try c.decodeIfPresent(Double.self, forKey: .bend) ?? d.bend
        horizontalDistortion = try c.decodeIfPresent(Double.self, forKey: .horizontalDistortion) ?? d.horizontalDistortion
        verticalDistortion = try c.decodeIfPresent(Double.self, forKey: .verticalDistortion) ?? d.verticalDistortion
    }
}

/// Type on a path: glyphs flow along `path` (local coordinates, i.e. doc coordinates before `TextContent.transform`).
package struct TextOnPath: Codable, Equatable {
    package var path: VectorPath
    /// Arc-length offset (px) of the text anchor along the path.
    package var startOffset: Double = 0
    /// Text runs along the reversed path (on the other side).
    package var flipped = false
    /// The path or shape the type was made from: while linked, editing it re-flows the text (`TypePathLink`).
    /// nil = the type owns its path (old documents, edited type path, deleted source).
    package var source: TextPathSource? = nil
    package init(path: VectorPath, startOffset: Double = 0, flipped: Bool = false, source: TextPathSource? = nil) {
        self.path = path; self.startOffset = startOffset; self.flipped = flipped; self.source = source
    }
}

extension TextOnPath {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(VectorPath.self, forKey: .path) ?? VectorPath()
        startOffset = try c.decodeIfPresent(Double.self, forKey: .startOffset) ?? 0
        flipped = try c.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        source = (try? c.decodeIfPresent(TextPathSource.self, forKey: .source)) ?? nil
    }
}

/// Link from type on a path to the subpath it follows: a path in the Paths panel (`pathID`) or a shape layer's outline
/// (`layerID`; a Line shape: its centre line). `synced` is that subpath (document coordinates) as the text last took
/// it: a source that no longer matches it changed (the text follows), a text path that no longer matches it was edited
/// or moved on the type side (the link breaks).
package struct TextPathSource: Codable, Equatable {
    package var pathID: UUID? = nil
    package var layerID: UUID? = nil
    /// Index of the subpath in the source, and the source's subpath count when last synced (a component removed before
    /// it shifts the index: the subpath is looked up again).
    package var subpath: Int = 0
    package var subpathCount: Int = 1
    package var synced: Subpath
    package init(pathID: UUID? = nil, layerID: UUID? = nil, subpath: Int = 0, subpathCount: Int = 1, synced: Subpath) {
        self.pathID = pathID; self.layerID = layerID; self.subpath = subpath; self.subpathCount = subpathCount; self.synced = synced
    }
}

package struct TextContent: Codable, Equatable {
    package var text: String = "Lorem Ipsum"
    package var fontName: String = "Helvetica"
    package var fontSize: Double = 48
    package var color: RGBA = .black
    package var tracking: Double = 0          // 1/1000 em
    package var leading: Double? = nil        // px, nil = auto (120%)
    package var alignment: TextAlign = .left
    package var position: CGPoint = .zero     // top-left of text box (vertical point text: top-right), doc coords (before transform)
    package var boxSize: CGSize? = nil        // paragraph text box
    package var transform: CGAffineTransform = .identity  // applied in doc space around origin
    package var fauxBold = false
    package var fauxItalic = false
    package var underline = false
    package var strikethrough = false
    package var allCaps = false
    package var horizontalScale: Double = 1
    package var verticalScale: Double = 1
    package var baselineShift: Double = 0
    package var antialias = true

    // Mixed styling: per-range overrides of the character fields above (which act as defaults).
    package var runs: [TextStyleRun] = []
    // Paragraph
    package var leftIndent: Double = 0        // px
    package var rightIndent: Double = 0
    package var firstLineIndent: Double = 0
    package var spaceBefore: Double = 0
    package var spaceAfter: Double = 0
    package var hyphenate = false
    // OpenType
    package var features = OpenTypeFeatures()
    // Layout variants
    package var orientation: TextOrientation = .horizontal
    package var warp: TextWarp? = nil
    package var pathText: TextOnPath? = nil
    // Variable fonts (layer default; runs may override)
    package var variations: [String: Double] = [:]
    // Lists (bullets / numbering), applied to every paragraph of the layer
    package var list: TextListStyle? = nil
    // Area type: text flows inside a closed path (local coordinates; the box is its bounds)
    package var area: AreaTextShape? = nil
    // Dynamic Text: font size (and optionally tracking) follow the box / shape size
    package var fitToBox: TextFit? = nil
    // World-ready layout
    package var composer: TextComposer = .latin
    package var direction: TextDirection = .auto
    // Photoshop import: fonts the file asks for that are not installed, and Photoshop's rendering of the layer, shown
    // until the type is edited (TextStoredPixels)
    package var missingFonts: [String] = []
    package var storedPixels: TextStoredPixels? = nil

    /// Layer defaults with a run's overrides applied.
    package func applying(_ s: CharacterStyle) -> TextContent {
        var r = self
        if let v = s.fontName { r.fontName = v }
        if let v = s.fontSize { r.fontSize = v }
        if let v = s.color { r.color = v }
        if let v = s.tracking { r.tracking = v }
        if let v = s.baselineShift { r.baselineShift = v }
        if let v = s.fauxBold { r.fauxBold = v }
        if let v = s.fauxItalic { r.fauxItalic = v }
        if let v = s.underline { r.underline = v }
        if let v = s.strikethrough { r.strikethrough = v }
        if let v = s.horizontalScale { r.horizontalScale = v }
        if let v = s.verticalScale { r.verticalScale = v }
        if let v = s.features { r.features = v }
        if let v = s.variations { r.variations = v }
        return r
    }

    package var utf16Count: Int { (text as NSString).length }

    /// Effective override style at a UTF-16 index (later runs win).
    package func style(at index: Int) -> CharacterStyle {
        var s = CharacterStyle()
        for r in runs where index >= r.location && index < r.end { s = s.merging(r.style) }
        return s
    }

    /// Applies `change` to the overrides of `range` (splitting runs as needed) and normalizes.
    package mutating func applyStyle(_ change: CharacterStyle, to range: NSRange) {
        let n = utf16Count
        let lo = max(0, min(n, range.location)), hi = max(lo, min(n, range.location + range.length))
        guard hi > lo else { return }
        var segs = styleSegments()
        var out: [TextStyleRun] = []
        for s in segs {
            let a = s.location, b = s.end
            if b <= lo || a >= hi { out.append(s); continue }
            if a < lo { out.append(TextStyleRun(location: a, length: lo - a, style: s.style)) }
            let ia = max(a, lo), ib = min(b, hi)
            out.append(TextStyleRun(location: ia, length: ib - ia, style: s.style.merging(change)))
            if b > hi { out.append(TextStyleRun(location: hi, length: b - hi, style: s.style)) }
        }
        segs = out
        runs = segs
        normalizeRuns()
    }

    /// Makes a layer-wide change: fields in `change` become the new defaults and are removed from all runs.
    package mutating func applyLayerWide(_ change: CharacterStyle) {
        self = applying(change)
        runs = runs.map { TextStyleRun(location: $0.location, length: $0.length, style: $0.style.removingFields(of: change)) }
        normalizeRuns()
    }

    /// Flattens overlapping runs into disjoint segments covering the whole text.
    package func styleSegments() -> [TextStyleRun] {
        let n = utf16Count
        guard n > 0 else { return [] }
        var cuts = Set<Int>([0, n])
        for r in runs {
            cuts.insert(max(0, min(n, r.location)))
            cuts.insert(max(0, min(n, r.end)))
        }
        let sorted = cuts.sorted()
        var out: [TextStyleRun] = []
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            guard b > a else { continue }
            out.append(TextStyleRun(location: a, length: b - a, style: style(at: a)))
        }
        return out
    }

    /// Clamps runs to the text, drops overrides equal to the defaults, removes empty runs and
    /// coalesces adjacent identical runs.
    package mutating func normalizeRuns() {
        guard !runs.isEmpty else { return }
        let segs = styleSegments()
        var out: [TextStyleRun] = []
        for s in segs {
            let st = s.style.normalized(against: self)
            if st.isEmpty { continue }
            if var last = out.last, last.end == s.location, last.style == st {
                last.length += s.length
                out[out.count - 1] = last
            } else {
                out.append(TextStyleRun(location: s.location, length: s.length, style: st))
            }
        }
        runs = out
    }
    package init(text: String = "Lorem Ipsum", fontName: String = "Helvetica", fontSize: Double = 48, color: RGBA = .black, tracking: Double = 0, leading: Double? = nil, alignment: TextAlign = .left, position: CGPoint = .zero, boxSize: CGSize? = nil, transform: CGAffineTransform = .identity, fauxBold: Bool = false, fauxItalic: Bool = false, underline: Bool = false, strikethrough: Bool = false, allCaps: Bool = false, horizontalScale: Double = 1, verticalScale: Double = 1, baselineShift: Double = 0, antialias: Bool = true, runs: [TextStyleRun] = [], leftIndent: Double = 0, rightIndent: Double = 0, firstLineIndent: Double = 0, spaceBefore: Double = 0, spaceAfter: Double = 0, hyphenate: Bool = false, features: OpenTypeFeatures = OpenTypeFeatures(), orientation: TextOrientation = .horizontal, warp: TextWarp? = nil, pathText: TextOnPath? = nil, variations: [String: Double] = [:], list: TextListStyle? = nil, area: AreaTextShape? = nil, fitToBox: TextFit? = nil, composer: TextComposer = .latin, direction: TextDirection = .auto, missingFonts: [String] = [], storedPixels: TextStoredPixels? = nil) {
        self.text = text; self.fontName = fontName; self.fontSize = fontSize; self.color = color; self.tracking = tracking; self.leading = leading; self.alignment = alignment; self.position = position; self.boxSize = boxSize; self.transform = transform; self.fauxBold = fauxBold; self.fauxItalic = fauxItalic; self.underline = underline; self.strikethrough = strikethrough; self.allCaps = allCaps; self.horizontalScale = horizontalScale; self.verticalScale = verticalScale; self.baselineShift = baselineShift; self.antialias = antialias; self.runs = runs; self.leftIndent = leftIndent; self.rightIndent = rightIndent; self.firstLineIndent = firstLineIndent; self.spaceBefore = spaceBefore; self.spaceAfter = spaceAfter; self.hyphenate = hyphenate; self.features = features; self.orientation = orientation; self.warp = warp; self.pathText = pathText; self.variations = variations; self.list = list; self.area = area; self.fitToBox = fitToBox; self.composer = composer; self.direction = direction; self.missingFonts = missingFonts; self.storedPixels = storedPixels
    }
}

// tolerant-decoding:TextContent (missing keys fall back to defaults)
extension TextContent {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TextContent()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? d.text
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? d.fontName
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? d.color
        tracking = try c.decodeIfPresent(Double.self, forKey: .tracking) ?? d.tracking
        leading = try c.decodeIfPresent(Double.self, forKey: .leading) ?? d.leading
        alignment = (try? c.decodeIfPresent(TextAlign.self, forKey: .alignment)) ?? d.alignment
        position = try c.decodeIfPresent(CGPoint.self, forKey: .position) ?? d.position
        boxSize = try c.decodeIfPresent(CGSize.self, forKey: .boxSize) ?? d.boxSize
        transform = try c.decodeIfPresent(CGAffineTransform.self, forKey: .transform) ?? d.transform
        fauxBold = try c.decodeIfPresent(Bool.self, forKey: .fauxBold) ?? d.fauxBold
        fauxItalic = try c.decodeIfPresent(Bool.self, forKey: .fauxItalic) ?? d.fauxItalic
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? d.underline
        strikethrough = try c.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? d.strikethrough
        allCaps = try c.decodeIfPresent(Bool.self, forKey: .allCaps) ?? d.allCaps
        horizontalScale = try c.decodeIfPresent(Double.self, forKey: .horizontalScale) ?? d.horizontalScale
        verticalScale = try c.decodeIfPresent(Double.self, forKey: .verticalScale) ?? d.verticalScale
        baselineShift = try c.decodeIfPresent(Double.self, forKey: .baselineShift) ?? d.baselineShift
        antialias = try c.decodeIfPresent(Bool.self, forKey: .antialias) ?? d.antialias
        runs = (try? c.decodeIfPresent([TextStyleRun].self, forKey: .runs)) ?? d.runs
        leftIndent = try c.decodeIfPresent(Double.self, forKey: .leftIndent) ?? d.leftIndent
        rightIndent = try c.decodeIfPresent(Double.self, forKey: .rightIndent) ?? d.rightIndent
        firstLineIndent = try c.decodeIfPresent(Double.self, forKey: .firstLineIndent) ?? d.firstLineIndent
        spaceBefore = try c.decodeIfPresent(Double.self, forKey: .spaceBefore) ?? d.spaceBefore
        spaceAfter = try c.decodeIfPresent(Double.self, forKey: .spaceAfter) ?? d.spaceAfter
        hyphenate = try c.decodeIfPresent(Bool.self, forKey: .hyphenate) ?? d.hyphenate
        features = (try? c.decodeIfPresent(OpenTypeFeatures.self, forKey: .features)) ?? d.features
        orientation = (try? c.decodeIfPresent(TextOrientation.self, forKey: .orientation)) ?? d.orientation
        warp = try? c.decodeIfPresent(TextWarp.self, forKey: .warp)
        pathText = try? c.decodeIfPresent(TextOnPath.self, forKey: .pathText)
        variations = (try? c.decodeIfPresent([String: Double].self, forKey: .variations)) ?? [:]
        list = try? c.decodeIfPresent(TextListStyle.self, forKey: .list)
        area = try? c.decodeIfPresent(AreaTextShape.self, forKey: .area)
        fitToBox = try? c.decodeIfPresent(TextFit.self, forKey: .fitToBox)
        composer = (try? c.decodeIfPresent(TextComposer.self, forKey: .composer)) ?? d.composer
        direction = (try? c.decodeIfPresent(TextDirection.self, forKey: .direction)) ?? d.direction
        missingFonts = (try? c.decodeIfPresent([String].self, forKey: .missingFonts)) ?? []
        storedPixels = try? c.decodeIfPresent(TextStoredPixels.self, forKey: .storedPixels)
    }
}
// end-tolerant

// MARK: - Shape

package enum ShapeGeometry: Codable, Equatable {
    case rectangle(CGRect, cornerRadius: Double)
    case ellipse(CGRect)
    case polygon(CGRect, sides: Int, starRatio: Double)
    case line(CGPoint, CGPoint, weight: Double)
    case path(VectorPath)
    case library(String, CGRect)

    package var vectorPath: VectorPath {
        switch self {
        case .rectangle(let r, let rad): return .rect(r, radius: rad)
        case .ellipse(let r): return .ellipse(r)
        case .polygon(let r, let s, let star): return .polygon(in: r, sides: s, starRatio: star)
        case .line(let a, let b, let w): return .line(from: a, to: b, weight: w)
        case .path(let p): return p
        case .library(let id, let r): return ShapeLibrary.shape(id)?.path(in: r) ?? .rect(r)
        }
    }

    package var kindName: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .polygon: return "Polygon"
        case .line: return "Line"
        case .path: return "Path"
        case .library(let id, _): return ShapeLibrary.shape(id)?.name ?? "Shape"
        }
    }
}

package enum StrokeAlignment: String, Codable, CaseIterable { case inside, center, outside }
package enum LineCapStyle: String, Codable, CaseIterable { case butt, round, square }
package enum LineJoinStyle: String, Codable, CaseIterable { case miter, round, bevel }

package struct StrokeStyle: Codable, Equatable {
    package var paint: PaintStyle = .none
    package var width: Double = 3
    package var alignment: StrokeAlignment = .center
    package var cap: LineCapStyle = .butt
    package var join: LineJoinStyle = .miter
    package var dash: [Double] = []
    /// Miter limit (nil = Core Graphics' default of 10) and dash start offset in stroke widths, like `dash` (imported artwork).
    package var miterLimit: Double? = nil
    package var dashPhase: Double? = nil
    /// Dash layout: nil / `.exact` repeats `dash` as is; `.corners` stretches it so a dash sits centred on every corner
    /// and ends at the path ends (Illustrator's "align dashes to corners and path ends"). See `StrokeGeometry`.
    package var dashAlignment: DashAlignment? = nil
    /// Unit the dash editor shows and takes lengths in (`dash` itself is always in stroke widths); nil = stroke widths.
    package var dashUnit: DashUnit? = nil
    package init(paint: PaintStyle = .none, width: Double = 3, alignment: StrokeAlignment = .center, cap: LineCapStyle = .butt, join: LineJoinStyle = .miter, dash: [Double] = [], miterLimit: Double? = nil, dashPhase: Double? = nil, dashAlignment: DashAlignment? = nil, dashUnit: DashUnit? = nil) {
        self.paint = paint; self.width = width; self.alignment = alignment; self.cap = cap; self.join = join; self.dash = dash; self.miterLimit = miterLimit; self.dashPhase = dashPhase; self.dashAlignment = dashAlignment; self.dashUnit = dashUnit
    }
}

package enum DashAlignment: String, Codable, CaseIterable { case exact, corners }
package enum DashUnit: String, Codable, CaseIterable { case widths, pixels }

package struct ShapeContent: Codable, Equatable {
    package var geometry: ShapeGeometry
    /// Transform applied to the geometry (keeps live shape params editable).
    package var transform: CGAffineTransform = .identity
    package var fill: PaintStyle = .color(RGBA(hex: "4A90E2")!)
    package var stroke = StrokeStyle()
    /// Non-affine (perspective/distort) transform applied after `transform`, keeping the geometry live.
    package var perspective: Homography? = nil

    package var path: VectorPath {
        let p = geometry.vectorPath.applying(transform)
        guard let h = perspective else { return p }
        return p.mapped(h.apply)
    }
    package init(geometry: ShapeGeometry, transform: CGAffineTransform = .identity, fill: PaintStyle = .color(RGBA(hex: "4A90E2")!), stroke: StrokeStyle = StrokeStyle(), perspective: Homography? = nil) {
        self.geometry = geometry; self.transform = transform; self.fill = fill; self.stroke = stroke; self.perspective = perspective
    }
}

// MARK: - Fill layers

package struct FillContent: Codable, Equatable {
    package var paint: PaintStyle
    /// Recipe layer: the pixels come from this node graph instead of `paint` (Nodes module). nil in older documents.
    package var recipe: RecipeGraph? = nil
    /// Pattern Fill placement (angle, offset, Link with Layer); nil = tiled from the canvas origin as in older documents.
    package var patternPlacement: PatternPlacement? = nil
    package init(paint: PaintStyle, recipe: RecipeGraph? = nil, patternPlacement: PatternPlacement? = nil) {
        self.paint = paint; self.recipe = recipe; self.patternPlacement = patternPlacement
    }
}

/// Where a Pattern Fill layer's tiles sit: rotated by `angle` (degrees, counter-clockwise) about the document's top-left
/// corner, then moved by `offset` (px). `linked` moves the pattern with the layer (Photoshop "Link with Layer").
package struct PatternPlacement: Codable, Equatable {
    package var angle: Double = 0
    package var offset: CGPoint = .zero
    package var linked = true
    package init(angle: Double = 0, offset: CGPoint = .zero, linked: Bool = true) {
        self.angle = angle; self.offset = offset; self.linked = linked
    }
}

// MARK: - Smart object

package indirect enum SmartSource: Codable {
    case image(PixelBuffer)
    case document(DocumentState)

    package var size: CGSize {
        switch self {
        case .image(let b): return CGSize(width: b.width, height: b.height)
        case .document(let d): return CGSize(width: d.width, height: d.height)
        }
    }
}

package struct SmartObjectContent: Codable {
    package var source: SmartSource
    /// Where the source's corners land in the document.
    package var quad: Quad
    package var filters: [FilterInstance] = []
    package var filtersEnabled = true
    /// Incremented when the embedded source changes (render caching).
    package var sourceRevision = 0
    package var sourceName: String = "Embedded"
    /// Non-destructive mesh warp applied after the quad transform (Warp / Puppet / Perspective Warp).
    package var warp: MeshWarpData? = nil
    /// Linked (external) source file; reloaded when it changes.
    package var linkedURL: URL? = nil
    package var linkedModified: Date? = nil
    /// Stack Mode (raw value of `StackMode`; optional so older files decode). Applied to `.document` sources.
    package var stackMode: String? = nil
    /// Component instance record (Components module): when set, `source` is a cache resolved from `DocumentState.components`.
    package var component: ComponentInstance? = nil
    /// How new contents of another size are placed (Replace Contents, Relink, Update Modified Content); nil = `.fit`.
    package var contentFit: SmartContentFit? = nil
    package init(source: SmartSource, quad: Quad, filters: [FilterInstance] = [], filtersEnabled: Bool = true, sourceRevision: Int = 0, sourceName: String = "Embedded", warp: MeshWarpData? = nil, linkedURL: URL? = nil, linkedModified: Date? = nil, stackMode: String? = nil, component: ComponentInstance? = nil, contentFit: SmartContentFit? = nil) {
        self.source = source; self.quad = quad; self.filters = filters; self.filtersEnabled = filtersEnabled; self.sourceRevision = sourceRevision; self.sourceName = sourceName; self.warp = warp; self.linkedURL = linkedURL; self.linkedModified = linkedModified; self.stackMode = stackMode; self.component = component; self.contentFit = contentFit
    }
}

/// Placement of smart-object contents that change size.
package enum SmartContentFit: String, Codable, CaseIterable {
    /// The new contents fill the current box: aspect ratio kept, centred, rotation / skew / perspective kept.
    case fit
    /// The object's scale is kept, so the box grows or shrinks with the new pixel size (Photoshop's behaviour).
    case keepScale

    package var label: String {
        switch self {
        case .fit: return "Fit to current bounds"
        case .keepScale: return "Keep scale (like Photoshop)"
        }
    }
}

extension SmartObjectContent {
    /// Swaps the source. Content of a different size keeps the object's scale, rotation, perspective and top-left
    /// corner (the box grows or shrinks with it) instead of being stretched into the old box.
    package mutating func setSource(_ new: SmartSource) {
        let old = source.size, now = new.size
        if old.width > 0, old.height > 0, now.width > 0, now.height > 0, old != now,
           let place = Homography(from: Quad(rect: CGRect(origin: .zero, size: old)), to: quad) {
            // the placement (affine or perspective) maps source pixels to the document: extend it to the new size
            quad = Quad(rect: CGRect(origin: .zero, size: now)).mapped(place.apply)
        }
        source = new
        sourceRevision += 1
    }

    /// New contents from a file (Replace Contents, Relink, Update Modified Content), placed by `fit` or else the
    /// layer's `contentFit` setting.
    package mutating func replaceSource(_ new: SmartSource, fit: SmartContentFit? = nil) {
        switch fit ?? contentFit ?? .fit {
        case .keepScale: setSource(new)
        case .fit: fitSource(new)
        }
    }

    /// Swaps the source and fits content of a different size into the current box: the largest size with its own
    /// aspect ratio, centred, mapped through the box's placement (rotation, skew and perspective included). The box
    /// is measured along its edges, so a box that was stretched does not stretch the new contents.
    package mutating func fitSource(_ new: SmartSource) {
        let old = source.size, now = new.size
        if old.width > 0, old.height > 0, now.width > 0, now.height > 0, old != now {
            let w = (quad.tl.distance(to: quad.tr) + quad.bl.distance(to: quad.br)) / 2
            let h = (quad.tl.distance(to: quad.bl) + quad.tr.distance(to: quad.br)) / 2
            if w > 0, h > 0, w.isFinite, h.isFinite, let place = Homography(from: Quad(rect: CGRect(x: 0, y: 0, width: w, height: h)), to: quad) {
                let k = min(w / now.width, h / now.height)
                let fw = now.width * k, fh = now.height * k
                quad = Quad(rect: CGRect(x: (w - fw) / 2, y: (h - fh) / 2, width: fw, height: fh)).mapped(place.apply)
            }
        }
        source = new
        sourceRevision += 1
    }
}

// MARK: - Group

package struct GroupContent: Codable {
    package var children: [Layer] = []   // bottom-first
    package var isExpanded = true
    /// Artboard groups clip their children to `rect` and draw a background.
    package var artboard: Artboard? = nil
    /// Live Repeater (Layout module): the group renders N transformed instances of its children.
    package var repeater: RepeaterSettings? = nil
    package init(children: [Layer] = [], isExpanded: Bool = true, artboard: Artboard? = nil, repeater: RepeaterSettings? = nil) {
        self.children = children; self.isExpanded = isExpanded; self.artboard = artboard; self.repeater = repeater
    }
}

package struct Artboard: Codable, Equatable {
    package var rect: CGRect
    package var background: RGBA? = .white
    /// Size preset the artboard was made from (Photoshop's `artboardPresetName`); nil = custom size.
    package var presetName: String? = nil

    /// Photoshop-style size presets, grouped as in the Artboard tool's Size menu (pixels; paper sizes at 72 ppi).
    /// Device sizes are the devices' native pixels as Apple / the makers list them (checked October 2026; the
    /// iPhone 16–18 Pro Max share 1320 × 2868, the 16 Pro / 17 / 17 Pro / 18 Pro 1206 × 2622); "@1x" entries are
    /// the point sizes designers lay screens out at.
    package static let presetGroups: [(String, [(String, CGSize)])] = [
        ("Phone", [("iPhone 18 Pro Max", CGSize(width: 1320, height: 2868)), ("iPhone 18 Pro / 17", CGSize(width: 1206, height: 2622)),
                   ("iPhone Air", CGSize(width: 1260, height: 2736)), ("iPhone 16e", CGSize(width: 1170, height: 2532)),
                   ("iPhone SE", CGSize(width: 750, height: 1334)), ("iPhone @1x", CGSize(width: 402, height: 874)),
                   ("Android 1080p", CGSize(width: 1080, height: 1920)), ("Android FHD+", CGSize(width: 1080, height: 2400)),
                   ("Android QHD+", CGSize(width: 1440, height: 3120))]),
        ("Tablet", [("iPad Pro 13\u{2033}", CGSize(width: 2064, height: 2752)), ("iPad Pro 11\u{2033}", CGSize(width: 1668, height: 2420)),
                    ("iPad Air 13\u{2033}", CGSize(width: 2048, height: 2732)), ("iPad Air 11\u{2033} / iPad", CGSize(width: 1640, height: 2360)),
                    ("iPad mini", CGSize(width: 1488, height: 2266)), ("iPad @1x", CGSize(width: 820, height: 1180)),
                    ("Surface Pro", CGSize(width: 2880, height: 1920))]),
        ("Watch", [("Apple Watch Ultra", CGSize(width: 422, height: 514)), ("Apple Watch 46mm", CGSize(width: 416, height: 496)),
                   ("Apple Watch 42mm", CGSize(width: 374, height: 446))]),
        ("Web", [("Web Small", CGSize(width: 1024, height: 768)), ("Web Medium", CGSize(width: 1280, height: 800)),
                 ("Web 1440", CGSize(width: 1440, height: 900)), ("MacBook Air 13\u{2033}", CGSize(width: 1470, height: 956)),
                 ("Full HD", CGSize(width: 1920, height: 1080))]),
        ("Social", [("Instagram Post", CGSize(width: 1080, height: 1080)), ("Instagram Portrait", CGSize(width: 1080, height: 1350)),
                    ("Instagram Grid 3:4", CGSize(width: 1080, height: 1440)), ("Story / Reel", CGSize(width: 1080, height: 1920)),
                    ("YouTube Thumbnail", CGSize(width: 1280, height: 720))]),
        ("Paper", [("Letter @72 ppi", CGSize(width: 612, height: 792)), ("Legal @72 ppi", CGSize(width: 612, height: 1008)),
                   ("Tabloid @72 ppi", CGSize(width: 792, height: 1224)), ("A3 @72 ppi", CGSize(width: 842, height: 1191)),
                   ("A4 @72 ppi", CGSize(width: 595, height: 842)), ("A5 @72 ppi", CGSize(width: 420, height: 595))]),
    ]
    /// Menu text for a preset: its name and size.
    package static func menuTitle(_ name: String, _ size: CGSize) -> String { "\(name)   \(Int(size.width)) × \(Int(size.height))" }
    package static let presets: [(String, CGSize)] = presetGroups.flatMap { $0.1 }
    package static func preset(named n: String?) -> CGSize? { presets.first { $0.0 == n }?.1 }
    package init(rect: CGRect, background: RGBA? = .white, presetName: String? = nil) {
        self.rect = rect; self.background = background; self.presetName = presetName
    }
}
