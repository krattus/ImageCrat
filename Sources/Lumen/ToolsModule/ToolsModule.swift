import AppKit
import SwiftUI
import Observation
import ImageCratCore

/// Additional Photoshop tools and workspace features (artboard, selection brush, perspective crop, slices, frames,
/// measuring tools, pattern stamp, art history brush, background eraser, curvature pen & anchor tools, triangle,
/// type masks, symmetry painting, smart guides, spring-loaded shortcuts, toolbar customisation, contextual task bar,
/// history snapshots, measurement log and window matching).
enum ToolsModule {
    static func register() {
        registerMenus()
        registerPanels()
        registerDialogs()
        FrameSupport.installCommitHook()
        SymmetryControls.install()
        ToolsSelfTest.register()
    }

    private static func registerMenus() {
        // File
        MenuRegistry.add("File", "Export Slices…", submenu: "Export") { SliceExport.exportWithPanel() }
        // Edit
        MenuRegistry.add("Edit", "Toolbar…", dividerBefore: true) { DialogRegistry.show("toolbar") }
        // Image ▸ Analysis
        MenuRegistry.add("Image", "Set Measurement Scale: Default (Pixels)", submenu: "Analysis") { MeasurementActions.setDefaultScale() }
        MenuRegistry.add("Image", "Set Measurement Scale: Custom…", submenu: "Analysis") { DialogRegistry.show("measurementScale") }
        MenuRegistry.add("Image", "Record Measurements", submenu: "Analysis", key: "m", modifiers: [.command, .shift]) { MeasurementActions.record() }
        MenuRegistry.add("Image", "Measurement Log", submenu: "Analysis") { WorkspaceManager.shared.showPanel("measurementLog") }
        MenuRegistry.add("Image", "Ruler Tool", submenu: "Analysis", dividerBefore: true) { AppModel.shared.tool = .ruler }
        MenuRegistry.add("Image", "Count Tool", submenu: "Analysis") { AppModel.shared.tool = .count }
        // View ▸ Show
        MenuRegistry.add("View", "Smart Guides", submenu: "Show") { SmartGuides.shared.toggle() }
        MenuRegistry.add("View", "Slices", submenu: "Show") { ToolsSettings.shared.showSlices.toggle(); refreshCanvas("Slices", ToolsSettings.shared.showSlices) }
        MenuRegistry.add("View", "Notes", submenu: "Show") { ToolsSettings.shared.showNotes.toggle(); refreshCanvas("Notes", ToolsSettings.shared.showNotes) }
        MenuRegistry.add("View", "Count", submenu: "Show") { ToolsSettings.shared.showCount.toggle(); refreshCanvas("Count", ToolsSettings.shared.showCount) }
        MenuRegistry.add("View", "Color Samplers", submenu: "Show") { ToolsSettings.shared.showSamplers.toggle(); refreshCanvas("Color Samplers", ToolsSettings.shared.showSamplers) }
        MenuRegistry.add("View", "Symmetry Axes", submenu: "Show") { ToolsSettings.shared.showSymmetryAxes.toggle(); refreshCanvas("Symmetry Axes", ToolsSettings.shared.showSymmetryAxes) }
        // Window
        MenuRegistry.add("Window", "Contextual Task Bar") { ToolsSettings.shared.taskBarVisible.toggle() }
        MenuRegistry.add("Window", "Match Zoom", submenu: "Arrange") { WindowSync.match(zoom: true) }
        MenuRegistry.add("Window", "Match Location", submenu: "Arrange") { WindowSync.match(location: true) }
        MenuRegistry.add("Window", "Match Rotation", submenu: "Arrange") { WindowSync.match(rotation: true) }
        MenuRegistry.add("Window", "Match All", submenu: "Arrange") { WindowSync.match(zoom: true, location: true, rotation: true) }
        MenuRegistry.add("Window", "Measurement Log") { WorkspaceManager.shared.showPanel("measurementLog") }
        MenuRegistry.add("Window", "Notes") { WorkspaceManager.shared.showPanel("notes") }
    }

    private static func registerPanels() {
        PanelRegistry.register(PanelRegistry.Def(id: "measurementLog", title: "Measurement Log") { AnyView(MeasurementLogPanel()) })
        PanelRegistry.register(PanelRegistry.Def(id: "notes", title: "Notes") { AnyView(NotesPanel()) })
    }

    private static func registerDialogs() {
        DialogRegistry.register("toolbar") { AnyView(ToolbarCustomizeDialog()) }
        DialogRegistry.register("measurementScale") { AnyView(MeasurementScaleDialog()) }
        DialogRegistry.register("exportSlices") { AnyView(ExportSlicesDialog()) }
        DialogRegistry.register("symmetryRadial") { AnyView(SymmetrySegmentsDialog()) }
    }

    static func refreshCanvas(_ what: String? = nil, _ on: Bool? = nil) {
        AppActions.canvas?.overlay.needsDisplay = true
        if let w = what, let o = on { AppModel.shared.setStatus("\(w): \(o ? "shown" : "hidden")") }
    }
}

extension WorkspaceManager {
    /// Shows a panel (docked or floating) if it isn't visible yet.
    func showPanel(_ id: String) {
        if !isVisible(id) { toggle(id) }
    }
}

// MARK: - Tool metadata and factory

enum ExtraToolInfo {
    static func displayName(_ k: ToolKind) -> String {
        switch k {
        case .artboard: return "Artboard Tool"
        case .selectionBrush: return "Selection Brush Tool"
        case .perspectiveCrop: return "Perspective Crop Tool"
        case .slice: return "Slice Tool"
        case .sliceSelect: return "Slice Select Tool"
        case .frame: return "Frame Tool"
        case .colorSampler: return "Color Sampler Tool"
        case .ruler: return "Ruler Tool"
        case .note: return "Note Tool"
        case .count: return "Count Tool"
        case .patternStamp: return "Pattern Stamp Tool"
        case .artHistoryBrush: return "Art History Brush Tool"
        case .backgroundEraser: return "Background Eraser Tool"
        case .curvaturePen: return "Curvature Pen Tool"
        case .addAnchor: return "Add Anchor Point Tool"
        case .deleteAnchor: return "Delete Anchor Point Tool"
        case .convertPoint: return "Convert Point Tool"
        case .triangle: return "Triangle Tool"
        case .typeMaskHorizontal: return "Horizontal Type Mask Tool"
        case .typeMaskVertical: return "Vertical Type Mask Tool"
        default: return k.rawValue
        }
    }

    static func symbol(_ k: ToolKind) -> String {
        switch k {
        case .artboard: return "rectangle.on.rectangle.angled"
        case .selectionBrush: return "scribble.variable"
        case .perspectiveCrop: return "perspective"
        case .slice: return "square.grid.3x3"
        case .sliceSelect: return "square.grid.3x3.topleft.filled"
        case .frame: return "photo.artframe"
        case .colorSampler: return "scope"
        case .ruler: return "ruler"
        case .note: return "note.text"
        case .count: return "number"
        case .patternStamp: return "seal.fill"
        case .artHistoryBrush: return "clock.arrow.2.circlepath"
        case .backgroundEraser: return "eraser.fill"
        case .curvaturePen: return "point.topleft.down.to.point.bottomright.curvepath"
        case .addAnchor: return "plus.circle"
        case .deleteAnchor: return "minus.circle"
        case .convertPoint: return "chevron.up"
        case .triangle: return "arrowtriangle.up"
        case .typeMaskHorizontal: return "t.square"
        case .typeMaskVertical: return "t.square.fill"
        default: return "questionmark"
        }
    }

    static func shortcut(_ k: ToolKind) -> String {
        switch k {
        case .artboard: return "V"
        case .selectionBrush: return "W"
        case .perspectiveCrop, .slice, .sliceSelect: return "C"
        case .frame: return "K"
        case .colorSampler, .ruler, .note, .count: return "I"
        case .patternStamp: return "S"
        case .artHistoryBrush: return "Y"
        case .backgroundEraser: return "E"
        case .curvaturePen: return "P"
        case .triangle: return "U"
        case .typeMaskHorizontal, .typeMaskVertical: return "T"
        default: return ""   // Add/Delete Anchor, Convert Point have no shortcut (as in Photoshop)
        }
    }

    static func makeTool(_ k: ToolKind, canvas: CanvasView) -> Tool {
        switch k {
        case .artboard: return ArtboardTool(kind: k, canvas: canvas)
        case .selectionBrush: return SelectionBrushTool(kind: k, canvas: canvas)
        case .perspectiveCrop: return PerspectiveCropTool(kind: k, canvas: canvas)
        case .slice, .sliceSelect: return SliceTool(kind: k, canvas: canvas)
        case .frame: return FrameTool(kind: k, canvas: canvas)
        case .colorSampler: return ColorSamplerTool(kind: k, canvas: canvas)
        case .ruler: return RulerTool(kind: k, canvas: canvas)
        case .note: return NoteTool(kind: k, canvas: canvas)
        case .count: return CountTool(kind: k, canvas: canvas)
        case .patternStamp, .artHistoryBrush: return StampBrushTool(kind: k, canvas: canvas)
        case .backgroundEraser: return BackgroundEraserTool(kind: k, canvas: canvas)
        case .curvaturePen: return CurvaturePenTool(kind: k, canvas: canvas)
        case .addAnchor, .deleteAnchor, .convertPoint: return AnchorEditTool(kind: k, canvas: canvas)
        case .triangle: return TriangleTool(kind: k, canvas: canvas)
        case .typeMaskHorizontal, .typeMaskVertical: return TypeMaskTool(kind: k, canvas: canvas)
        default: return HandTool(kind: k, canvas: canvas)
        }
    }
}

// MARK: - Settings

enum ArtHistoryStyle: String, CaseIterable, Codable {
    case tightShort = "Tight Short", tightMedium = "Tight Medium", tightLong = "Tight Long"
    case looseMedium = "Loose Medium", looseLong = "Loose Long", dab = "Dab"
    case tightCurl = "Tight Curl", tightCurlLong = "Tight Curl Long", looseCurl = "Loose Curl", looseCurlLong = "Loose Curl Long"
}

enum EraserLimits: String, CaseIterable { case contiguous = "Contiguous", discontiguous = "Discontiguous", findEdges = "Find Edges" }
enum FrameShape: String, CaseIterable { case rectangle = "Rectangle", ellipse = "Ellipse" }
enum FrameFit: String, CaseIterable { case fill = "Fill Frame", fit = "Fit Frame" }

@Observable
final class ToolsSettings {
    static let shared = ToolsSettings()

    // Brush-type tools
    var patternStampBrush = BrushSettings(size: 60, hardness: 0.5)
    var patternID = "checker"
    var patternAligned = true
    var patternImpressionist = false
    var artHistoryBrush = BrushSettings(size: 6, hardness: 0.8, spacing: 1.2, smoothing: 0)
    var artStyle: ArtHistoryStyle = .tightShort
    var artArea: Double = 50
    var artTolerance: Double = 0
    var bgEraserBrush = BrushSettings(size: 60, hardness: 0.9, spacing: 0.15, smoothing: 0)
    var bgSampling: ColorSampling = .continuous
    var bgLimits: EraserLimits = .contiguous
    var bgTolerance: Double = 50           // %
    var bgProtectForeground = false
    var selectionBrush = BrushSettings(size: 50, hardness: 0.8, spacing: 0.1, smoothing: 0)
    var selectionBrushSubtract = false
    var selectionOverlayColor = RGBA(r: 1, g: 0, b: 0, a: 1)
    var selectionOverlayOpacity: Double = 0.5

    // Crop family
    var cropStraighten = false
    var perspectiveShowGrid = true
    var frameShape: FrameShape = .rectangle
    var frameFit: FrameFit = .fill

    // Measuring
    var colorSamplerSize: Int = 1
    var rulerLines: [UUID: (CGPoint, CGPoint)] = [:]
    var noteAuthor = NSFullUserName()
    var noteColor = RGBA(r: 1, g: 0.85, b: 0.25, a: 1)
    var selectedNoteID: UUID?
    var activeCountGroup = 0
    var selectedSliceID: UUID?

    // Shapes
    var triangleRadius: Double = 0
    var arrowStart = false
    var arrowWidth: Double = 500      // % of line weight
    var arrowLength: Double = 1000    // % of line weight
    var arrowConcavity: Double = 0    // %

    // Visibility
    var showSlices = true
    var showNotes = true
    var showCount = true
    var showSamplers = true
    var showSymmetryAxes = true

    var symmetry = SymmetrySettings()

    /// Contextual Task Bar (Window menu), remembered.
    var taskBarVisible: Bool = UserDefaults.standard.object(forKey: "Lumen.TaskBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(taskBarVisible, forKey: "Lumen.TaskBar") }
    }

    func brush(for k: ToolKind) -> BrushSettings? {
        switch k {
        case .patternStamp: return patternStampBrush
        case .artHistoryBrush: return artHistoryBrush
        case .backgroundEraser: return bgEraserBrush
        case .selectionBrush: return selectionBrush
        default: return nil
        }
    }

    /// Stores settings for a tool that has its own brush; false when the tool uses the main brush.
    func setBrush(_ s: BrushSettings, for k: ToolKind) -> Bool {
        switch k {
        case .patternStamp: patternStampBrush = s
        case .artHistoryBrush: artHistoryBrush = s
        case .backgroundEraser: bgEraserBrush = s
        case .selectionBrush: selectionBrush = s
        default: return false
        }
        return true
    }

    var currentPattern: PatternDef? {
        PatternLibrary.pattern(id: patternID, custom: AppModel.shared.customPatterns) ?? PatternDef.builtIn.first
    }
}

// MARK: - Canvas overlays drawn for every tool

enum ExtraOverlays {
    static func draw(_ ctx: CGContext, canvas: CanvasView, doc: Document) {
        let s = ToolsSettings.shared
        FrameSupport.drawPlaceholders(ctx, canvas: canvas, doc: doc)
        if s.showSlices { SliceOverlay.draw(ctx, canvas: canvas, doc: doc, selected: s.selectedSliceID) }
        if s.showCount { CountTool.drawMarks(ctx, canvas: canvas, doc: doc) }
        if s.showSamplers { ColorSamplerTool.drawSamplers(ctx, canvas: canvas, doc: doc) }
        if s.showNotes { NoteTool.drawNotes(ctx, canvas: canvas, doc: doc) }
        if s.showSymmetryAxes { SymmetryControls.drawAxes(ctx, canvas: canvas, doc: doc) }
        SmartGuides.shared.draw(ctx, canvas: canvas)
    }

    /// Tints a canvas-size gray mask (white = tinted) on the overlay.
    static func tint(_ ctx: CGContext, canvas: CanvasView, doc: Document, mask: CGImage, color: NSColor, invert: Bool = false) {
        let W = CGFloat(doc.state.width), H = CGFloat(doc.state.height)
        ctx.saveGState()
        ctx.concatenate(canvas.docToViewTransform)
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)
        if invert {
            // tint where the mask is black: fill everything, then punch out the mask
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: H), mask: mask)
            ctx.setBlendMode(.destinationOut)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            ctx.endTransparencyLayer()
        } else {
            ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: H), mask: mask)
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }
        ctx.restoreGState()
    }

    /// Small rounded badge with a number/text at a view point.
    static func badge(_ text: String, at p: CGPoint, color: NSColor, fontSize: CGFloat = 10, textColor: NSColor = .white) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: textColor]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        let r = CGRect(x: p.x, y: p.y, width: sz.width + 6, height: sz.height + 2)
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        s.draw(at: CGPoint(x: r.minX + 3, y: r.minY + 1))
    }

    static func text(_ text: String, at p: CGPoint, color: NSColor, fontSize: CGFloat = 10) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: color]
        NSAttributedString(string: text, attributes: attrs).draw(at: p)
    }
}

// MARK: - Shared helpers

enum ToolGeometry {
    /// Distance from p to segment ab.
    static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { PenTool.distanceToSegment(p, a, b) }

    /// Composite color at a document point (averaged over `size`×`size`).
    static func compositeColor(_ d: Document, at p: CGPoint, size: Int = 1) -> RGBA? {
        let x = Int(floor(p.x)), y = Int(floor(p.y))
        guard x >= 0, y >= 0, x < d.state.width, y < d.state.height else { return nil }
        let r = max(0, size / 2)
        let rect = IRect(x: x - r, y: y - r, width: 2 * r + 1, height: 2 * r + 1).intersection(d.state.canvasRect)
        guard !rect.isEmpty else { return nil }
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        let img = Compositor.shared.composite(d)
        var px = [UInt8](repeating: 0, count: rect.width * rect.height * 4)
        RenderEngine.readbackContext.render(img, toBitmap: &px, rowBytes: rect.width * 4, bounds: sp.ciRect(rect), format: .RGBA8, colorSpace: sRGBSpace)
        var sr = 0.0, sg = 0.0, sb = 0.0, sa = 0.0
        for i in 0..<(rect.width * rect.height) {
            sr += Double(px[i * 4]); sg += Double(px[i * 4 + 1]); sb += Double(px[i * 4 + 2]); sa += Double(px[i * 4 + 3])
        }
        if sa == 0 { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        let n = Double(rect.width * rect.height)
        return RGBA(r: sr / sa, g: sg / sa, b: sb / sa, a: sa / n / 255)
    }

    static func fmt(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v) }
}
