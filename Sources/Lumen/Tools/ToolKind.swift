import Foundation
import CoreGraphics
import ImageCratCore

enum ToolKind: String, CaseIterable, Identifiable, Codable {
    case move, marqueeRect, marqueeEllipse, marqueeRow, marqueeColumn
    case lasso, polygonLasso, magneticLasso, magicWand, quickSelect, objectSelect
    case crop, eyedropper
    case spotHealing, healing, patch, contentAwareMove, removeTool, redEye
    case brush, pencil, colorReplacement, mixerBrush, cloneStamp, historyBrush, eraser, magicEraser
    case gradient, paintBucket
    case blur, sharpen, smudge, dodge, burn, sponge
    case pen, freeformPen, directSelect, pathSelect
    case text, verticalText
    case rectangle, roundedRect, ellipse, polygon, line, customShape
    case libraryShape
    case hand, rotateView, zoom
    // ToolsModule (Tools/Extra): additional Photoshop tools
    case artboard, selectionBrush, perspectiveCrop, slice, sliceSelect, frame
    case colorSampler, ruler, note, count
    case patternStamp, artHistoryBrush, backgroundEraser
    case curvaturePen, addAnchor, deleteAnchor, convertPoint
    case triangle, typeMaskHorizontal, typeMaskVertical

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .move: return "Move Tool"
        case .marqueeRect: return "Rectangular Marquee Tool"
        case .marqueeEllipse: return "Elliptical Marquee Tool"
        case .marqueeRow: return "Single Row Marquee Tool"
        case .marqueeColumn: return "Single Column Marquee Tool"
        case .lasso: return "Lasso Tool"
        case .polygonLasso: return "Polygonal Lasso Tool"
        case .magneticLasso: return "Magnetic Lasso Tool"
        case .objectSelect: return "Object Selection Tool"
        case .patch: return "Patch Tool"
        case .contentAwareMove: return "Content-Aware Move Tool"
        case .removeTool: return "Remove Tool"
        case .redEye: return "Red Eye Tool"
        case .colorReplacement: return "Color Replacement Tool"
        case .mixerBrush: return "Mixer Brush Tool"
        case .verticalText: return "Vertical Type Tool"
        case .libraryShape: return "Custom Shape Tool"
        case .rotateView: return "Rotate View Tool"
        case .magicWand: return "Magic Wand Tool"
        case .quickSelect: return "Quick Selection Tool"
        case .crop: return "Crop Tool"
        case .eyedropper: return "Eyedropper Tool"
        case .spotHealing: return "Spot Healing Brush Tool"
        case .healing: return "Healing Brush Tool"
        case .brush: return "Brush Tool"
        case .pencil: return "Pencil Tool"
        case .cloneStamp: return "Clone Stamp Tool"
        case .historyBrush: return "History Brush Tool"
        case .eraser: return "Eraser Tool"
        case .magicEraser: return "Magic Eraser Tool"
        case .gradient: return "Gradient Tool"
        case .paintBucket: return "Paint Bucket Tool"
        case .blur: return "Blur Tool"
        case .sharpen: return "Sharpen Tool"
        case .smudge: return "Smudge Tool"
        case .dodge: return "Dodge Tool"
        case .burn: return "Burn Tool"
        case .sponge: return "Sponge Tool"
        case .pen: return "Pen Tool"
        case .freeformPen: return "Freeform Pen Tool"
        case .directSelect: return "Direct Selection Tool"
        case .pathSelect: return "Path Selection Tool"
        case .text: return "Horizontal Type Tool"
        case .rectangle: return "Rectangle Tool"
        case .roundedRect: return "Rounded Rectangle Tool"
        case .ellipse: return "Ellipse Tool"
        case .polygon: return "Polygon Tool"
        case .line: return "Line Tool"
        case .customShape: return "Star Tool"
        case .hand: return "Hand Tool"
        case .zoom: return "Zoom Tool"
        default: return ExtraToolInfo.displayName(self)
        }
    }

    var symbol: String {
        switch self {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .marqueeRect: return "rectangle.dashed"
        case .marqueeEllipse: return "circle.dashed"
        case .marqueeRow: return "arrow.left.and.right"
        case .marqueeColumn: return "arrow.up.and.down"
        case .lasso: return "lasso"
        case .polygonLasso: return "skew"
        case .magneticLasso: return "lasso.badge.sparkles"
        case .objectSelect: return "rectangle.and.hand.point.up.left"
        case .patch: return "square.on.square.dashed"
        case .contentAwareMove: return "arrow.up.and.down.and.arrow.left.and.right.circle"
        case .removeTool: return "wand.and.rays"
        case .redEye: return "eye.trianglebadge.exclamationmark"
        case .colorReplacement: return "paintbrush.pointed.fill"
        case .mixerBrush: return "paintpalette"
        case .verticalText: return "character.textbox"
        case .libraryShape: return "heart"
        case .rotateView: return "rotate.3d"
        case .magicWand: return "wand.and.stars"
        case .quickSelect: return "paintbrush.pointed"
        case .crop: return "crop"
        case .eyedropper: return "eyedropper"
        case .spotHealing: return "bandage"
        case .healing: return "cross.case"
        case .brush: return "paintbrush"
        case .pencil: return "pencil"
        case .cloneStamp: return "seal"
        case .historyBrush: return "clock.arrow.circlepath"
        case .eraser: return "eraser"
        case .magicEraser: return "eraser.line.dashed"
        case .gradient: return "square.fill.and.line.vertical.and.square"
        case .paintBucket: return "drop.fill"
        case .blur: return "drop"
        case .sharpen: return "triangle"
        case .smudge: return "hand.point.up.left"
        case .dodge: return "circle.lefthalf.filled"
        case .burn: return "flame"
        case .sponge: return "cloud"
        case .pen: return "pencil.tip"
        case .freeformPen: return "scribble"
        case .directSelect: return "cursorarrow"
        case .pathSelect: return "cursorarrow.rays"
        case .text: return "textformat"
        case .rectangle: return "rectangle"
        case .roundedRect: return "app"
        case .ellipse: return "circle"
        case .polygon: return "hexagon"
        case .line: return "line.diagonal"
        case .customShape: return "star"
        case .hand: return "hand.raised"
        case .zoom: return "magnifyingglass"
        default: return ExtraToolInfo.symbol(self)
        }
    }

    var shortcut: String {
        switch self {
        case .move: return "V"
        case .marqueeRect, .marqueeEllipse, .marqueeRow, .marqueeColumn: return "M"
        case .lasso, .polygonLasso, .magneticLasso: return "L"
        case .magicWand, .quickSelect, .objectSelect: return "W"
        case .crop: return "C"
        case .eyedropper: return "I"
        case .spotHealing, .healing, .patch, .contentAwareMove, .removeTool, .redEye: return "J"
        case .brush, .pencil, .colorReplacement, .mixerBrush: return "B"
        case .cloneStamp: return "S"
        case .historyBrush: return "Y"
        case .eraser, .magicEraser: return "E"
        case .gradient, .paintBucket: return "G"
        case .blur, .sharpen, .smudge: return "R"
        case .dodge, .burn, .sponge: return "O"
        case .pen, .freeformPen: return "P"
        case .directSelect, .pathSelect: return "A"
        case .text, .verticalText: return "T"
        case .rectangle, .roundedRect, .ellipse, .polygon, .line, .customShape, .libraryShape: return "U"
        case .hand: return "H"
        case .rotateView: return "R"
        case .zoom: return "Z"
        default: return ExtraToolInfo.shortcut(self)
        }
    }

    /// Toolbar groups as customised in Edit ▸ Toolbar… (hidden tools removed, groups reordered).
    static var groups: [[ToolKind]] { ToolbarConfig.groups(defaultGroups) }

    /// Default toolbar groups (first item is the default shown).
    static let defaultGroups: [[ToolKind]] = [
        [.move, .artboard],
        [.marqueeRect, .marqueeEllipse, .marqueeRow, .marqueeColumn],
        [.lasso, .polygonLasso, .magneticLasso],
        [.objectSelect, .quickSelect, .magicWand, .selectionBrush],
        [.crop, .perspectiveCrop, .slice, .sliceSelect, .frame],
        [.eyedropper, .colorSampler, .ruler, .note, .count],
        [.spotHealing, .removeTool, .healing, .patch, .contentAwareMove, .redEye],
        [.brush, .pencil, .colorReplacement, .mixerBrush],
        [.cloneStamp, .patternStamp],
        [.historyBrush, .artHistoryBrush],
        [.eraser, .backgroundEraser, .magicEraser],
        [.gradient, .paintBucket],
        [.blur, .sharpen, .smudge],
        [.dodge, .burn, .sponge],
        [.pen, .freeformPen, .curvaturePen, .addAnchor, .deleteAnchor, .convertPoint],
        [.text, .verticalText, .typeMaskVertical, .typeMaskHorizontal],
        [.pathSelect, .directSelect],
        [.rectangle, .roundedRect, .ellipse, .triangle, .polygon, .line, .customShape, .libraryShape],
        [.hand, .rotateView],
        [.zoom],
    ]

    var isShape: Bool { [.rectangle, .roundedRect, .ellipse, .polygon, .line, .customShape, .libraryShape, .triangle].contains(self) }
    var isMarquee: Bool { [.marqueeRect, .marqueeEllipse, .marqueeRow, .marqueeColumn, .lasso, .polygonLasso, .magneticLasso].contains(self) }
    var isRetouch: Bool { [.blur, .sharpen, .smudge, .dodge, .burn, .sponge].contains(self) }
    /// Tools that paint into the Quick Mask while it is on (Photoshop paints the Quick Mask channel, never the layer).
    var editsQuickMask: Bool { [.brush, .pencil, .eraser, .cloneStamp, .patternStamp, .gradient, .paintBucket].contains(self) || isRetouch || isShape }
    /// Tools that change layer pixels on a click or drag (in Quick Mask mode those without `editsQuickMask` are refused).
    var writesPixels: Bool { isPainting || [.gradient, .paintBucket, .magicEraser, .patch, .contentAwareMove, .redEye].contains(self) }
    var isPainting: Bool { [.brush, .pencil, .eraser, .cloneStamp, .historyBrush, .healing, .spotHealing, .colorReplacement, .mixerBrush, .removeTool,
                                .patternStamp, .artHistoryBrush, .backgroundEraser].contains(self) || isRetouch }
}

// MARK: - Tool settings

enum SelectionCombine: String, CaseIterable, Codable { case new, add, subtract, intersect }

struct BrushSettings: Equatable, Codable {
    var size: Double = 30
    var hardness: Double = 0.8
    var opacity: Double = 1
    var flow: Double = 1
    var spacing: Double = 0.12
    var angle: Double = 0
    var roundness: Double = 1
    var smoothing: Double = 0.1
    var blendMode: BlendMode = .normal
    var pressureSize = true
    var pressureOpacity = false
    var sizeJitter: Double = 0
    var opacityJitter: Double = 0
    var scatter: Double = 0
    var tipID: String = "round"
    var airbrush = false
    /// Brush Settings panel options (shape dynamics, scattering, texture, dual brush, color dynamics, transfer, …).
    @DefaultIfMissing var dynamics = BrushDynamics()
}

struct BrushPreset: Identifiable, Equatable {
    var id: String
    var name: String
    var size: Double
    var hardness: Double
    var spacing: Double = 0.12
    var roundness: Double = 1
    var angle: Double = 0
    var scatter: Double = 0
    var sizeJitter: Double = 0
    var tipID: String = "round"
    /// Full dynamics captured by the preset (nil: derived from the legacy fields).
    var dynamics: BrushDynamics? = nil

    static let builtIn: [BrushPreset] = [
        BrushPreset(id: "hard5", name: "Hard Round 5", size: 5, hardness: 1),
        BrushPreset(id: "hard13", name: "Hard Round 13", size: 13, hardness: 1),
        BrushPreset(id: "hard30", name: "Hard Round 30", size: 30, hardness: 1),
        BrushPreset(id: "hard100", name: "Hard Round 100", size: 100, hardness: 1),
        BrushPreset(id: "soft13", name: "Soft Round 13", size: 13, hardness: 0),
        BrushPreset(id: "soft45", name: "Soft Round 45", size: 45, hardness: 0),
        BrushPreset(id: "soft100", name: "Soft Round 100", size: 100, hardness: 0),
        BrushPreset(id: "soft300", name: "Soft Round 300", size: 300, hardness: 0),
        BrushPreset(id: "airbrush", name: "Soft Airbrush", size: 65, hardness: 0, spacing: 0.05),
        BrushPreset(id: "flat", name: "Flat Calligraphy", size: 40, hardness: 0.9, spacing: 0.05, roundness: 0.25, angle: 45),
        BrushPreset(id: "spatter", name: "Spatter", size: 45, hardness: 0.5, spacing: 0.5, scatter: 1.2, sizeJitter: 0.7),
        BrushPreset(id: "chalk", name: "Chalk", size: 36, hardness: 0.8, spacing: 0.15, tipID: "chalk"),
        BrushPreset(id: "charcoal", name: "Charcoal", size: 50, hardness: 0.7, spacing: 0.1, tipID: "charcoal"),
        BrushPreset(id: "dry", name: "Dry Brush", size: 60, hardness: 0.9, spacing: 0.08, tipID: "bristle"),
        BrushPreset(id: "grass", name: "Grass", size: 80, hardness: 1, spacing: 0.4, scatter: 0.6, sizeJitter: 0.5, tipID: "grass"),
        BrushPreset(id: "star", name: "Stars", size: 40, hardness: 1, spacing: 1.2, scatter: 1.5, sizeJitter: 0.8, tipID: "star"),
    ]
}

enum RetouchRange: String, CaseIterable, Codable { case shadows, midtones, highlights }

struct RetouchSettings: Equatable, Codable {
    var strength: Double = 0.5
    var exposure: Double = 0.5
    var range: RetouchRange = .midtones
    var spongeSaturate = false
    var sampleAllLayers = false
    var fingerPainting = false
}

struct SelectionToolSettings: Equatable, Codable {
    var combine: SelectionCombine = .new
    var feather: Double = 0
    var antialias = true
    var fixedRatio = false
    var ratioW: Double = 1
    var ratioH: Double = 1
    var tolerance: Double = 32
    var contiguous = true
    var sampleAllLayers = false
}

enum ShapeMode: String, CaseIterable, Codable { case shape = "Shape", path = "Path", pixels = "Pixels" }

struct ShapeToolSettings: Equatable, Codable {
    var mode: ShapeMode = .shape
    var fill: PaintStyle = .color(RGBA(hex: "4A90E2")!)
    var stroke: PaintStyle = .none
    var strokeWidth: Double = 3
    var strokeAlignment: StrokeAlignment = .center
    var cornerRadius: Double = 20
    var sides: Int = 6
    var starRatio: Double = 0.5
    var lineWeight: Double = 4
    var arrowEnd = false
    /// nil = new layer / new path; otherwise the new component joins the active shape with this operation.
    var operation: PathOperation? = nil
    var libraryID = "heart"
    /// Stroke Options for new shapes: caps, corners, miter limit, dashes (paint, width and alignment are the fields above).
    var strokeOptions: StrokeStyle? = nil
    /// Pixels mode (Photoshop: Mode / Opacity / Anti-alias): how the foreground colour is painted onto the layer.
    var pixelBlendMode: BlendMode = .normal
    var pixelOpacity: Double = 1
    var pixelAntiAlias = true
    /// Path options (the gear): draw from the centre / keep the proportions (square, circle) without holding ⌥ / ⇧.
    var fromCenter = false
    var constrainProportions = false
}

extension ShapeToolSettings {
    /// Older settings and tool presets have no Pixels-mode or path-option fields: missing keys keep their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShapeToolSettings()
        mode = try c.decodeIfPresent(ShapeMode.self, forKey: .mode) ?? d.mode
        fill = try c.decodeIfPresent(PaintStyle.self, forKey: .fill) ?? d.fill
        stroke = try c.decodeIfPresent(PaintStyle.self, forKey: .stroke) ?? d.stroke
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? d.strokeWidth
        strokeAlignment = try c.decodeIfPresent(StrokeAlignment.self, forKey: .strokeAlignment) ?? d.strokeAlignment
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        sides = try c.decodeIfPresent(Int.self, forKey: .sides) ?? d.sides
        starRatio = try c.decodeIfPresent(Double.self, forKey: .starRatio) ?? d.starRatio
        lineWeight = try c.decodeIfPresent(Double.self, forKey: .lineWeight) ?? d.lineWeight
        arrowEnd = try c.decodeIfPresent(Bool.self, forKey: .arrowEnd) ?? d.arrowEnd
        operation = try c.decodeIfPresent(PathOperation.self, forKey: .operation)
        libraryID = try c.decodeIfPresent(String.self, forKey: .libraryID) ?? d.libraryID
        strokeOptions = try c.decodeIfPresent(StrokeStyle.self, forKey: .strokeOptions)
        pixelBlendMode = try c.decodeIfPresent(BlendMode.self, forKey: .pixelBlendMode) ?? d.pixelBlendMode
        pixelOpacity = try c.decodeIfPresent(Double.self, forKey: .pixelOpacity) ?? d.pixelOpacity
        pixelAntiAlias = try c.decodeIfPresent(Bool.self, forKey: .pixelAntiAlias) ?? d.pixelAntiAlias
        fromCenter = try c.decodeIfPresent(Bool.self, forKey: .fromCenter) ?? d.fromCenter
        constrainProportions = try c.decodeIfPresent(Bool.self, forKey: .constrainProportions) ?? d.constrainProportions
    }
}

struct TextToolSettings: Equatable, Codable {
    var fontName = "Helvetica"
    var fontSize: Double = 48
    var alignment: TextAlign = .left
    var color: RGBA? = nil   // nil: foreground color
}

struct GradientToolSettings: Equatable, Codable {
    var gradient: ColorGradient = ColorGradient.presets[0]
    var type: GradientType = .linear
    var reverse = false
    var opacity: Double = 1
    var blendMode: BlendMode = .normal
    var useForegroundBackground = true
}

struct BucketSettings: Equatable {
    var tolerance: Double = 32
    var contiguous = true
    var antialias = true
    var sampleAllLayers = false
    var usePattern = false
    var patternID = "checker"
    var opacity: Double = 1
    var blendMode: BlendMode = .normal
}

struct CropSettings: Equatable {
    var ratioW: Double = 0
    var ratioH: Double = 0
    var deleteCropped = false
    var showThirds = true
}
