import Foundation
import CoreGraphics
import ImageCratCore

// The display list a page is turned into before layers are built: painted objects in stacking order, each with
// the chain of containers (optional-content layers, form XObjects, clipping paths) it was drawn in.

/// A container an object is drawn inside of. Equal elements of consecutive objects share one group layer.
enum PDFVectorContext: Equatable {
    case ocg(Int)
    case form(Int)
    case clip(Int)

    var isClip: Bool { if case .clip = self { return true }; return false }
}

struct PDFVectorClip {
    /// Document space (pixels, y down).
    var path: CGPath
    var bounds: CGRect
    /// Set when the clip is an axis-aligned rectangle.
    var rect: CGRect?
}

struct PDFVectorFormInstance {
    var name: String
    var opacity = 1.0
    var blend = "Normal"
    /// A transparency group composited as a unit (false: the form's objects are painted straight onto the page).
    var isGroup = false
    var isolated = false
    /// The `Do` that drew the form (to render the whole group from the PDF when its layers cannot match it).
    var slice: PDFVectorSlice? = nil
    /// Soft mask the group was drawn through (becomes the group's layer mask).
    var softMask: Int? = nil
    /// The rebuilt layers must be compared with the PDF's rendering of the group (blending Lumen does differently).
    var needsCheck = false
    var checkReason = ""
}

struct PDFVectorOCG {
    var name: String
    var visible: Bool
}

/// A soft mask set through an ExtGState. Its values are obtained by filling the page through the mask with the PDF
/// engine, so alpha and luminosity masks, backdrop colours and transfer functions all come out as the engine applies them.
struct PDFVectorSoftMask {
    var state: CGPDFDictionaryRef
    /// CTM in force when the mask was set (it positions the mask's group).
    var ctm: CGAffineTransform
}

/// A colour as the content stream set it; resolved to sRGB by rendering a swatch through the PDF engine.
struct PDFVectorColorState {
    /// DeviceGray / DeviceRGB / DeviceCMYK / Pattern, or "" when `space` holds a colour-space resource.
    var spaceName = "DeviceGray"
    var space: CGPDFObjectRef? = nil
    var components: [Double] = [0]
    var pattern: CGPDFDictionaryRef? = nil
    var patternObject: CGPDFObjectRef? = nil
    /// Transparency-group chain the colour is painted in (set for palette entries; see `PDFVectorInterpreter.chains`).
    var chain = 0

    var key: String {
        var k = "\(chain)|" + (space.map { "o\(unsafeBitCast($0, to: Int.self))" } ?? spaceName)
        for c in components { k += " " + PDFVectorWriter.number(c) }
        return k
    }
}

struct PDFVectorGState {
    /// User space → document pixels.
    var ctm: CGAffineTransform
    var fill = PDFVectorColorState()
    var stroke = PDFVectorColorState()
    var lineWidth = 1.0
    var lineCap = 0
    var lineJoin = 0
    var miterLimit = 10.0
    var dash: [Double] = []
    var dashPhase = 0.0
    var fillAlpha = 1.0
    var strokeAlpha = 1.0
    var blend = "Normal"
    var softMask = false
    /// Index into the interpreter's `softMasks` when the active soft mask can become a layer mask.
    var softMaskIndex: Int? = nil
    /// ExtGState dictionaries applied so far, with the CTM in force at the time (a soft mask is positioned by it).
    var extStates: [(dict: CGPDFDictionaryRef, ctm: CGAffineTransform)] = []
    var clips: [Int] = []
    /// `W` (false) or `W*` (true) waiting for the next path-painting operator. Core Graphics keeps this with the
    /// graphics state: `q` saves it and `Q` brings it back.
    var pendingClip: Bool? = nil
    var font: PDFVectorFont? = nil
    var fontSize = 0.0
    var charSpace = 0.0
    var wordSpace = 0.0
    var hScale = 1.0
    var leading = 0.0
    var rise = 0.0
    var renderMode = 0
}

/// A run of content-stream bytes that can be replayed on its own: the graphics state at its start is rebuilt by a
/// generated preamble, so Core Graphics renders exactly what the source page shows for these operators.
struct PDFVectorSlice {
    var stream: Int
    var range: Range<Int>
    var state: PDFVectorGState
    /// Saved states below `state` (only for slices that may pop them with unbalanced `Q`s).
    var stack: [PDFVectorGState] = []
    var inText = false
    var textMatrix = CGAffineTransform.identity
    var lineMatrix = CGAffineTransform.identity
    /// Render with alpha 1 and the Normal blend mode: the layer carries opacity and blend mode instead.
    var opaque = true
    /// Transparency-group chain the bytes are drawn in (their blending colour spaces decide how colours convert).
    var chain = 0
    /// Operators to replay instead of `range` (a path written out again, when its bytes are not one clean run).
    var synthetic: [UInt8]? = nil
}

enum PDFVectorPaint: Equatable {
    case empty
    case color(Int)
    case gradient(Int)
}

struct PDFVectorStroke: Equatable {
    var width: Double
    var cap: Int
    var join: Int
    /// Dash lengths in document pixels.
    var dash: [Double] = []
}

/// One or more paths painted alike (consecutive paths with the same paint are collected into one shape).
final class PDFVectorShape {
    struct Part {
        var path: CGPath
        var bounds: CGRect
        /// Already rewritten so that overlapping parts fill as a union under the non-zero rule.
        var normalized = false
    }
    var parts: [Part] = []
    var fill: PDFVectorPaint = .empty
    var strokePaint: PDFVectorPaint = .empty
    var stroke: PDFVectorStroke? = nil
    var pointCount = 0
    var closedSubpaths = 0
    var unionBounds = CGRect.null
    /// Name hint ("Path", "Rectangle", "Gradient"…).
    var label = "Path"

    var path: CGPath {
        if parts.count == 1 { return parts[0].path }
        let p = CGMutablePath()
        for part in parts { p.addPath(part.path) }
        return p
    }
}

struct PDFVectorGlyph {
    var code: Int32
    /// Glyph origin in document space.
    var origin: CGPoint
    /// Origin after this glyph's advance (document space).
    var end: CGPoint
}

/// Text shown by one Tj / TJ with one font and paint.
struct PDFVectorTextRun {
    var font: PDFVectorFont
    /// Text space (one unit = 1 em, y up) → document pixels, without translation.
    var basis: CGAffineTransform
    var glyphs: [PDFVectorGlyph]
    var fill: PDFVectorPaint
    var strokePaint: PDFVectorPaint
    var stroke: PDFVectorStroke?
    var mode: Int
    /// Character spacing in thousandths of an em (Tc relative to the font size).
    var tracking: Double
    /// Word spacing was in force (no layer equivalent; the layout check decides whether it matters).
    var wordSpaced: Bool
}

final class PDFVectorText {
    var runs: [PDFVectorTextRun] = []
    var slice: PDFVectorSlice
    /// False when glyph positions could not be followed (unknown widths / encoding): pixels only.
    var positioned = true
    var glyphCount = 0
    var lineCount = 1
    /// Distance between baselines once the block has a second line, and where the current line starts.
    var pitch: CGFloat = 0
    var lineOrigin = CGPoint.zero
    /// Saved-state depth when the block started; a `Q` below it ends the block.
    var depth = 0
    var closed = false
    var reason = ""
    init(slice: PDFVectorSlice) { self.slice = slice }
}

struct PDFVectorRaster {
    var slice: PDFVectorSlice
    var isImage = false
    var reason = ""
    var name = ""
}

struct PDFVectorItem {
    enum Kind {
        case shape(PDFVectorShape)
        case text(PDFVectorText)
        case raster(PDFVectorRaster)
    }
    var kind: Kind
    var context: [PDFVectorContext]
    var opacity = 1.0
    var blend = "Normal"
    /// Document-space extent (generous for anything that gets rendered from the PDF).
    var bounds: CGRect
    /// Soft mask the object was painted through (becomes its layer mask).
    var softMask: Int? = nil
}

/// A gradient found on the page: an axial or radial shading with the matrix that places it in the document.
struct PDFVectorGradient {
    var shading: CGPDFDictionaryRef
    var radial: Bool
    /// Document space. Axial: start / end of the axis. Radial: centre and a point on the outer circle.
    var start: CGPoint
    var end: CGPoint
    /// Stop positions are remapped to `innerFraction…1` for a radial shading that starts on a circle.
    var innerFraction = 0.0
    var extendStart = true
    var extendEnd = true
    var chain = 0
}

struct PDFVectorLimits {
    /// Objects kept as layers before the rest of the page is rasterized in bands.
    var maxItems = 1200
    var maxOperators = 30_000_000
    var maxContentBytes = 256 << 20
    var maxFormDepth = 24
    var maxShapePoints = 12_000
    var maxShapeParts = 400
    var maxTextGlyphs = 700
    var maxTextLines = 14
}

/// What happened to the page's content (shown to the user as the import report).
struct PDFVectorReport {
    var file = ""
    var page = 1
    var shapes = 0
    var mergedPaths = 0
    var textLayers = 0
    var outlinedText = 0
    var images = 0
    var groups = 0
    var masks = 0
    var softMasks = 0
    /// reason → number of objects rasterized for it
    var rasterized: [String: Int] = [:]
    /// font name → what happened ("not installed — outlined", "substituted with …")
    var fonts: [String: String] = [:]
    var layerNames: [String] = []
    var notes: [String] = []
    var flattened = false
    var seconds = 0.0

    mutating func raster(_ reason: String) { rasterized[reason, default: 0] += 1 }
    mutating func note(_ s: String) { if !notes.contains(s) && notes.count < 40 { notes.append(s) } }

    var rasterCount: Int { rasterized.values.reduce(0, +) }

    var summary: String {
        if flattened { return "Page \(page): imported as a flattened image" + (notes.first.map { " (\($0))" } ?? "") }
        var parts: [String] = []
        if shapes > 0 { parts.append("\(shapes) shape layer\(shapes == 1 ? "" : "s")") }
        if textLayers > 0 { parts.append("\(textLayers) text layer\(textLayers == 1 ? "" : "s")") }
        if outlinedText > 0 { parts.append("\(outlinedText) outlined text block\(outlinedText == 1 ? "" : "s")") }
        if images > 0 { parts.append("\(images) image\(images == 1 ? "" : "s")") }
        if rasterCount > 0 { parts.append("\(rasterCount) rasterized") }
        return parts.isEmpty ? "Page \(page): empty" : "Page \(page): " + parts.joined(separator: ", ")
    }

    var text: String {
        var out = [summary]
        if mergedPaths > shapes, shapes > 0 { out.append("• \(mergedPaths) paths were combined into \(shapes) shape layer\(shapes == 1 ? "" : "s") (same paint, adjacent in stacking order).") }
        if groups > 0 || masks > 0 { out.append("• \(groups) group\(groups == 1 ? "" : "s"), \(masks) clipping path\(masks == 1 ? "" : "s") kept as vector masks.") }
        if softMasks > 0 { out.append("• \(softMasks) soft mask\(softMasks == 1 ? "" : "s") became layer masks.") }
        if !layerNames.isEmpty { out.append("• Layers: " + layerNames.prefix(12).joined(separator: ", ") + (layerNames.count > 12 ? "…" : "")) }
        for (r, n) in rasterized.sorted(by: { $0.key < $1.key }) { out.append("• Rasterized: \(r) (\(n))") }
        for (f, what) in fonts.sorted(by: { $0.key < $1.key }) { out.append("• Font \(f): \(what)") }
        for n in notes { out.append("• " + n) }
        if !flattened, rasterized.isEmpty, fonts.isEmpty { out.append("• Nothing had to be rasterized.") }
        return out.joined(separator: "\n")
    }
}
