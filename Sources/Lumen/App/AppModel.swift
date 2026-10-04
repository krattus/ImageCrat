import SwiftUI
import Observation
import ImageCratCore

enum ModifySelectionKind: String { case expand = "Expand", contract = "Contract", border = "Border", smooth = "Smooth", feather = "Feather" }

enum ActiveDialog: Identifiable, Equatable {
    case newDocument
    case imageSize
    case canvasSize
    case filter(FilterKind, smartLayer: UUID?, editingFilter: UUID?)
    case adjustment(AdjustmentKind)
    case layerStyle(UUID)
    case export
    case fill
    case stroke
    case modifySelection(ModifySelectionKind)
    case colorRange
    case gradientEditor
    case about
    case shortcuts
    case liquify
    case blurGallery
    case selectAndMask
    case focusArea
    case globalLight
    case batch
    case preferences
    case colorProfile(convert: Bool)
    case proofSetup
    case warpText
    /// Dialog registered in `DialogRegistry` by a feature module.
    case custom(String)

    var id: String {
        switch self {
        case .newDocument: return "new"
        case .imageSize: return "imageSize"
        case .canvasSize: return "canvasSize"
        case .filter(let k, _, _): return "filter-\(k.rawValue)"
        case .adjustment(let k): return "adj-\(k.rawValue)"
        case .layerStyle(let id): return "style-\(id)"
        case .export: return "export"
        case .fill: return "fill"
        case .stroke: return "stroke"
        case .modifySelection(let k): return "modsel-\(k.rawValue)"
        case .colorRange: return "colorRange"
        case .gradientEditor: return "gradientEditor"
        case .about: return "about"
        case .shortcuts: return "shortcuts"
        case .liquify: return "liquify"
        case .blurGallery: return "blurGallery"
        case .selectAndMask: return "selectAndMask"
        case .focusArea: return "focusArea"
        case .globalLight: return "globalLight"
        case .batch: return "batch"
        case .preferences: return "preferences"
        case .colorProfile(let c): return "profile-\(c)"
        case .proofSetup: return "proofSetup"
        case .warpText: return "warpText"
        case .custom(let id): return "custom-\(id)"
        }
    }
}

@Observable
final class AppModel {
    static let shared = AppModel()

    // Documents
    var documents: [Document] = []
    var activeDocumentID: UUID?

    var activeDocument: Document? {
        guard let id = activeDocumentID else { return nil }
        return documents.first { $0.id == id }
    }

    // Tools
    var tool: ToolKind = .brush {
        didSet {
            if oldValue != tool {
                previousTool = oldValue
                toolChanged?(oldValue, tool)
                if let g = ToolKind.groups.firstIndex(where: { $0.contains(tool) }) { groupSelection[g] = tool }
            }
        }
    }
    @ObservationIgnored var previousTool: ToolKind = .move
    @ObservationIgnored var toolChanged: ((ToolKind, ToolKind) -> Void)?
    var groupSelection: [Int: ToolKind] = [:]

    // Colors
    var foreground: RGBA = .black
    var background: RGBA = .white
    var recentColors: [RGBA] = []
    var swatches: [RGBA] = AppModel.defaultSwatches

    // Tool settings
    var brush = BrushSettings()
    var pencil = BrushSettings(size: 1, hardness: 1, spacing: 0.05, smoothing: 0)
    var eraser = BrushSettings(size: 40, hardness: 0.6)
    var clone = BrushSettings(size: 60, hardness: 0.5)
    var healing = BrushSettings(size: 40, hardness: 0.6)
    var historyBrush = BrushSettings(size: 50, hardness: 0.5)
    var retouchBrush = BrushSettings(size: 50, hardness: 0.3)
    var removeBrush = BrushSettings(size: 60, hardness: 0.8)
    var colorReplaceBrush = BrushSettings(size: 40, hardness: 0.6)
    var mixerBrushSettings = BrushSettings(size: 45, hardness: 0.5, spacing: 0.08)
    var magneticContrast: Double = 10
    var magneticWidth: Double = 10
    var magneticFrequency: Double = 57
    var objectSelectMode: ObjectSelectMode = .rectangle
    var patchMode: PatchMode = .source
    var contentAwareMoveMode: ContentAwareMoveMode = .move
    var removeSampleAll = true
    var redEyePupil: Double = 50
    var redEyeDarken: Double = 50
    var colorReplace = ColorReplaceSettings()
    var mixer = MixerSettings()
    var retouch = RetouchSettings()
    var selection = SelectionToolSettings()
    var shapeTool = ShapeToolSettings()
    var textTool = TextToolSettings()
    var gradientTool = GradientToolSettings()
    var bucket = BucketSettings()
    var crop = CropSettings()
    /// Move tool ▸ Auto-Select (remembered; on for new users, see AutoSelectPrefs) and its Layer / Group choice.
    var moveAutoSelect = AutoSelectPrefs.initialOn { didSet { AutoSelectPrefs.save(moveAutoSelect) } }
    var moveAutoSelectMode = AutoSelectPrefs.initialMode { didSet { AutoSelectPrefs.save(moveAutoSelectMode) } }
    var moveShowTransform = true
    var cloneAligned = true
    var cloneSampleAll = false
    var eraserMode: EraserMode = .brush
    var magicEraserTolerance: Double = 32
    /// Pen tools start in Path mode (a pen draws a path; the shape tools start in Shape mode). Remembered per tool once
    /// changed, see `ToolModes`.
    var penMode: ShapeMode = .path
    var quickSelectSize: Double = 25
    var eyedropperSample: Int = 1   // 1, 3, 5
    var eyedropperAllLayers = true
    var historyBrushSource: Int? = nil   // history index; nil = first

    var customPatterns: [PatternDef] = []
    var customBrushTips: [String: PixelBuffer] = [:]
    var customBrushPresets: [BrushPreset] = []
    var gradients: [ColorGradient] = ColorGradient.presets

    // Preferences (persisted)
    var prefs = Preferences.load() {
        didSet { prefs.save(); Document.maxHistory = max(5, prefs.historyStates) }
    }

    var proof: ProofSettings = {
        if let d = UserDefaults.standard.data(forKey: "Lumen.Proof"), let p = try? JSONDecoder().decode(ProofSettings.self, from: d) { return p }
        return ProofSettings()
    }() {
        didSet { if let d = try? JSONEncoder().encode(proof) { UserDefaults.standard.set(d, forKey: "Lumen.Proof") } }
    }

    /// Feather direction used by selection tools and Select ▸ Modify ▸ Feather.
    var featherDirection: FeatherDirection = FeatherDirection(rawValue: UserDefaults.standard.string(forKey: "Lumen.FeatherDirection") ?? "") ?? .centered {
        didSet { UserDefaults.standard.set(featherDirection.rawValue, forKey: "Lumen.FeatherDirection") }
    }

    // UI state
    /// Bumped when an interactive canvas session changes (refreshes the options bar).
    var sessionTick = 0
    var dialog: ActiveDialog? {
        didSet {
            // a filter / adjustment dialog over a selected layer mask: ask whether the image or the mask is meant
            if case .adjustment(let k) = dialog, oldValue?.id != dialog?.id, !MaskTargetPrompt.resolve(k.displayName) { dialog = nil; return }
            DialogGuard.dialogChanged(from: oldValue, to: dialog)
        }
    }
    var statusMessage: String = "" {
        didSet { if statusMessage != oldValue { DiagLog.shared.record(.status, statusMessage) } }   // for Help ▸ Report a Bug… (redacted)
    }
    var showSecondaryPanels = true
    var showPanels = true
    var cursorDocPoint: CGPoint? = nil
    var cursorColor: RGBA? = nil
    /// Bumped to request the canvas fit on screen.
    var fitRequest = 0

    @ObservationIgnored var textEditingActive = false

    init() {}

    // MARK: Helpers

    var activeBrushSettings: BrushSettings {
        get {
            switch tool {
            case .pencil: return pencil
            case .eraser: return eraser
            case .cloneStamp: return clone
            case .healing, .spotHealing: return healing
            case .historyBrush: return historyBrush
            case .removeTool: return removeBrush
            case .colorReplacement: return colorReplaceBrush
            case .mixerBrush: return mixerBrushSettings
            case .blur, .sharpen, .smudge, .dodge, .burn, .sponge: return retouchBrush
            default: return ToolsSettings.shared.brush(for: tool) ?? brush
            }
        }
        set {
            switch tool {
            case .pencil: pencil = newValue
            case .eraser: eraser = newValue
            case .cloneStamp: clone = newValue
            case .healing, .spotHealing: healing = newValue
            case .historyBrush: historyBrush = newValue
            case .removeTool: removeBrush = newValue
            case .colorReplacement: colorReplaceBrush = newValue
            case .mixerBrush: mixerBrushSettings = newValue
            case .blur, .sharpen, .smudge, .dodge, .burn, .sponge: retouchBrush = newValue
            default: if !ToolsSettings.shared.setBrush(newValue, for: tool) { brush = newValue }
            }
        }
    }

    func swapColors() { swap(&foreground, &background) }
    func resetColors() { foreground = .black; background = .white }

    func pushRecent(_ c: RGBA) {
        recentColors.removeAll { $0 == c }
        recentColors.insert(c, at: 0)
        if recentColors.count > 16 { recentColors.removeLast() }
    }

    func setStatus(_ s: String) { statusMessage = s }

    func add(_ doc: Document) {
        documents.append(doc)
        activeDocumentID = doc.id
    }

    func close(_ doc: Document) {
        guard let i = documents.firstIndex(where: { $0.id == doc.id }) else { return }
        documents.remove(at: i)
        if activeDocumentID == doc.id {
            activeDocumentID = documents.isEmpty ? nil : documents[min(i, documents.count - 1)].id
        }
        MemoryHygiene.documentClosed(doc)
    }

    static let defaultSwatches: [RGBA] = {
        var s: [RGBA] = []
        let hexes = ["000000", "3A3A3A", "6B6B6B", "9C9C9C", "CFCFCF", "FFFFFF",
                     "FF0000", "FF7F00", "FFFF00", "7FFF00", "00FF00", "00FF7F", "00FFFF", "007FFF", "0000FF", "7F00FF", "FF00FF", "FF007F",
                     "8B0000", "8B4500", "8B8B00", "458B00", "008B00", "008B45", "008B8B", "00458B", "00008B", "45008B", "8B008B", "8B0045",
                     "F4C2C2", "FFE0B2", "FFF9C4", "DCEDC8", "C8E6C9", "B2DFDB", "B3E5FC", "C5CAE9", "E1BEE7", "F8BBD0",
                     "5D4037", "8D6E63", "BCAAA4", "D7CCC8", "C19A6B", "E3C16F", "2E4057", "4A90E2", "E94F37", "F6AE2D"]
        for h in hexes { if let c = RGBA(hex: h) { s.append(c) } }
        return s
    }()
}

enum EraserMode: String, CaseIterable { case brush = "Brush", pencil = "Pencil", block = "Block" }
enum PatchMode: String, CaseIterable { case source = "Source", destination = "Destination" }
enum ContentAwareMoveMode: String, CaseIterable { case move = "Move", extend = "Extend" }
enum ColorSampling: String, CaseIterable { case continuous = "Continuous", once = "Once", backgroundSwatch = "Background Swatch" }

struct ColorReplaceSettings: Equatable {
    var mode: BlendMode = .color      // .hue, .saturation, .color, .luminosity
    var tolerance: Double = 30        // %
    var sampling: ColorSampling = .continuous
}

struct MixerSettings: Equatable {
    var wet: Double = 50
    var load: Double = 50
    var mix: Double = 50
    var loadEachStroke = true
    var cleanEachStroke = true
    var sampleAll = false
}
