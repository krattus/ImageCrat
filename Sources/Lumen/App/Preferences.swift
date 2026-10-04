import SwiftUI
import ImageCratCore

enum RulerUnit: String, Codable, CaseIterable, Identifiable {
    case pixels = "Pixels", inches = "Inches", centimeters = "Centimeters", millimeters = "Millimeters", points = "Points", percent = "Percent"
    var id: String { rawValue }
    var short: String {
        switch self { case .pixels: return "px"; case .inches: return "in"; case .centimeters: return "cm"; case .millimeters: return "mm"; case .points: return "pt"; case .percent: return "%" }
    }
    /// Converts pixels to this unit at `ppi` (percent is relative to `total`).
    func fromPixels(_ px: Double, ppi: Double, total: Double = 1) -> Double {
        switch self {
        case .pixels: return px
        case .inches: return px / ppi
        case .centimeters: return px / ppi * 2.54
        case .millimeters: return px / ppi * 25.4
        case .points: return px / ppi * 72
        case .percent: return px / max(1, total) * 100
        }
    }
    func toPixels(_ v: Double, ppi: Double, total: Double = 1) -> Double {
        switch self {
        case .pixels: return v
        case .inches: return v * ppi
        case .centimeters: return v / 2.54 * ppi
        case .millimeters: return v / 25.4 * ppi
        case .points: return v / 72 * ppi
        case .percent: return v / 100 * total
        }
    }
}

enum BrushCursorStyle: String, Codable, CaseIterable, Identifiable {
    case normal = "Normal Brush Tip", fullSize = "Full Size Brush Tip", precise = "Precise", standard = "Standard"
    var id: String { rawValue }
}

enum InterfaceTheme: String, Codable, CaseIterable, Identifiable {
    case darkest = "Darkest", dark = "Dark", medium = "Medium Gray", light = "Light Gray"
    var id: String { rawValue }
    /// Base panel brightness.
    var panel: Double { switch self { case .darkest: return 0.13; case .dark: return 0.196; case .medium: return 0.29; case .light: return 0.72 } }
    var isLight: Bool { self == .light }
}

struct Preferences: Codable, Equatable {
    // General
    var historyStates: Int = 60
    var autoFitOnOpen = true
    // Interface
    var theme: InterfaceTheme = .dark
    var showToolTips = true
    // Cursors
    var brushCursor: BrushCursorStyle = .normal
    var showCrosshairInBrushTip = true
    // Transparency & guides
    var checkerSize: Double = 8
    var guideColor: RGBA = RGBA(r: 0, g: 0.85, b: 1)
    var gridColor: RGBA = RGBA(gray: 0.55)
    var gridSpacing: Double = 50
    var gridSubdivisions: Int = 4
    var selectionColor: RGBA = RGBA(r: 1, g: 1, b: 1)
    // Units
    var rulerUnits: RulerUnit = .pixels
    var typeUnits: RulerUnit = .pixels
    // Performance
    var cacheLargeDocuments = true
    var largeDocumentThreshold: Double = 4   // megapixels

    static let key = "LumenPreferences"

    static func load() -> Preferences {
        guard let d = UserDefaults.standard.data(forKey: key), let p = try? JSONDecoder().decode(Preferences.self, from: d) else { return Preferences() }
        return p
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Preferences.key) }
    }
}
// tolerant-decoding:Preferences (generated: missing keys fall back to defaults)
extension Preferences {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        historyStates = try c.decodeIfPresent(Int.self, forKey: .historyStates) ?? d.historyStates
        autoFitOnOpen = try c.decodeIfPresent(Bool.self, forKey: .autoFitOnOpen) ?? d.autoFitOnOpen
        theme = try c.decodeIfPresent(InterfaceTheme.self, forKey: .theme) ?? d.theme
        showToolTips = try c.decodeIfPresent(Bool.self, forKey: .showToolTips) ?? d.showToolTips
        brushCursor = try c.decodeIfPresent(BrushCursorStyle.self, forKey: .brushCursor) ?? d.brushCursor
        showCrosshairInBrushTip = try c.decodeIfPresent(Bool.self, forKey: .showCrosshairInBrushTip) ?? d.showCrosshairInBrushTip
        checkerSize = try c.decodeIfPresent(Double.self, forKey: .checkerSize) ?? d.checkerSize
        guideColor = try c.decodeIfPresent(RGBA.self, forKey: .guideColor) ?? d.guideColor
        gridColor = try c.decodeIfPresent(RGBA.self, forKey: .gridColor) ?? d.gridColor
        gridSpacing = try c.decodeIfPresent(Double.self, forKey: .gridSpacing) ?? d.gridSpacing
        gridSubdivisions = try c.decodeIfPresent(Int.self, forKey: .gridSubdivisions) ?? d.gridSubdivisions
        selectionColor = try c.decodeIfPresent(RGBA.self, forKey: .selectionColor) ?? d.selectionColor
        rulerUnits = try c.decodeIfPresent(RulerUnit.self, forKey: .rulerUnits) ?? d.rulerUnits
        typeUnits = try c.decodeIfPresent(RulerUnit.self, forKey: .typeUnits) ?? d.typeUnits
        cacheLargeDocuments = try c.decodeIfPresent(Bool.self, forKey: .cacheLargeDocuments) ?? d.cacheLargeDocuments
        largeDocumentThreshold = try c.decodeIfPresent(Double.self, forKey: .largeDocumentThreshold) ?? d.largeDocumentThreshold
    }
}
// end-tolerant
