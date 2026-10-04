import AppKit
import SwiftUI
import Observation
import ImageCratCore

/// "Artist & colour" features Photoshop lacks: reference boards, a radial quick menu, drawing guides with assisted
/// strokes and rulers, colour harmony / palette / global colours / recolour / accessibility tools, brush stabilisers,
/// palette colour jitter, a brush test pad and seamless tile painting.
enum ArtistModule {
    static func register() {
        registerMenus()
        registerPanels()
        registerDialogs()
        BrushAssist.install()
        ArtistSelfTest.register()
        if !ArtistSupport.isSelfTest {
            DispatchQueue.main.async {
                RadialMenuController.shared.install()
                GuideEditor.shared.install()
            }
        }
    }

    static func status(_ what: String, _ on: Bool) { AppModel.shared.setStatus("\(what): \(on ? "on" : "off")") }

    static func refreshCanvas() {
        AppActions.canvas?.setNeedsRender()
        AppActions.canvas?.overlay.needsDisplay = true
    }

    private static func registerMenus() {
        let hasDoc = { AppActions.doc != nil }
        let s = ArtistSettings.shared

        // Window ▸ Reference Board
        MenuRegistry.add("Window", "Reference Board", key: "r", modifiers: [.command, .control], dividerBefore: true) { ReferenceBoardController.toggleMain() }
        MenuRegistry.add("Window", "New Reference Window", submenu: "Reference Board Options") { ReferenceBoardController.openNew() }
        MenuRegistry.add("Window", "Toggle Click-Through", submenu: "Reference Board Options") { ReferenceBoardController.toggleClickThrough() }
        MenuRegistry.add("Window", "Paste Clipboard into Board", submenu: "Reference Board Options") { ReferenceBoardController.pasteIntoFront() }
        MenuRegistry.add("Window", "Colour Harmony") { WorkspaceManager.shared.reveal("colorHarmony") }
        MenuRegistry.add("Window", "Contrast Checker") { WorkspaceManager.shared.reveal("contrastChecker") }
        MenuRegistry.add("Window", "Drawing Assist") { WorkspaceManager.shared.reveal("drawingAssist") }
        MenuRegistry.add("Window", "Brush Test Pad") { WorkspaceManager.shared.reveal("brushTestPad") }

        // View ▸ Drawing Guides
        for k in DrawingGuideKind.allCases {
            MenuRegistry.add("View", k == .none ? "No Guide" : k.title, submenu: "Drawing Guides", enabled: hasDoc) { DrawingGuides.setKind(k) }
        }
        MenuRegistry.add("View", "Show / Hide Guide", submenu: "Drawing Guides", dividerBefore: true, enabled: hasDoc) { DrawingGuides.toggleVisible() }
        MenuRegistry.add("View", "Edit Guides and Rulers", submenu: "Drawing Guides", enabled: hasDoc) {
            s.editGuides.toggle(); status("Edit drawing guides", s.editGuides); refreshCanvas()
        }
        MenuRegistry.add("View", "Assisted Drawing", submenu: "Drawing Guides", enabled: hasDoc) {
            s.assist.toggle(); status("Assisted drawing", s.assist)
        }
        for k in AssistRulerKind.allCases {
            MenuRegistry.add("View", "Add \(k.title)", submenu: "Drawing Guides", dividerBefore: k == .straight, enabled: hasDoc) { DrawingGuides.addRuler(k) }
        }
        MenuRegistry.add("View", "Remove All Rulers", submenu: "Drawing Guides", enabled: { !(AppActions.doc?.state.artist.rulers.isEmpty ?? true) }) { DrawingGuides.removeRulers() }

        // View ▸ Simulate
        for m in VisionSimulation.allCases {
            MenuRegistry.add("View", m.title, submenu: "Simulate", dividerBefore: m == .lowContrast) {
                s.simulation = m
                AppModel.shared.setStatus(m == .none ? "Vision simulation off" : "Simulating \(m.title) (view only)")
                refreshCanvas()
            }
        }
        MenuRegistry.add("View", "Flip Canvas View", key: "h", modifiers: [.command, .shift], enabled: hasDoc) { ArtistView.toggleFlip() }

        // View ▸ Pattern Preview (the Imaging module's toggle lives in the same submenu)
        MenuRegistry.add("View", "Wrap Painting", submenu: "Pattern Preview", enabled: hasDoc) {
            s.wrapPainting.toggle(); status("Wrap painting around the canvas edges", s.wrapPainting)
        }
        MenuRegistry.add("View", "Make Seamless…", submenu: "Pattern Preview", dividerBefore: true, enabled: hasDoc) { DialogRegistry.show("artist.seamless") }
        MenuRegistry.add("View", "Define Pattern from Canvas", submenu: "Pattern Preview", enabled: hasDoc) { SeamlessTile.definePatternFromCanvas() }

        // Edit
        MenuRegistry.add("Edit", "Define Pattern from Canvas", enabled: hasDoc) { SeamlessTile.definePatternFromCanvas() }
        MenuRegistry.add("Edit", "Make Seamless…", enabled: hasDoc) { DialogRegistry.show("artist.seamless") }

        // Image ▸ Colour Tools
        MenuRegistry.add("Image", "Palette from Image…", submenu: "Colour Tools", enabled: hasDoc) { DialogRegistry.show("artist.palette") }
        MenuRegistry.add("Image", "Recolour Artwork…", submenu: "Colour Tools", enabled: hasDoc) { DialogRegistry.show("artist.recolor") }
        MenuRegistry.add("Image", "New Global Colour from Foreground", submenu: "Colour Tools", dividerBefore: true, enabled: hasDoc) {
            if let d = AppActions.doc { _ = GlobalColors.add(d, color: AppModel.shared.foreground) }
        }
    }

    private static func registerPanels() {
        PanelRegistry.register(PanelRegistry.Def(id: "colorHarmony", title: "Colour Harmony") { AnyView(ColorHarmonyPanel()) })
        PanelRegistry.register(PanelRegistry.Def(id: "contrastChecker", title: "Contrast Checker") { AnyView(ContrastCheckerPanel()) })
        PanelRegistry.register(PanelRegistry.Def(id: "drawingAssist", title: "Drawing Assist") { AnyView(DrawingAssistPanel()) })
        PanelRegistry.register(PanelRegistry.Def(id: "brushTestPad", title: "Brush Test Pad") { AnyView(BrushTestPadPanel()) })
    }

    private static func registerDialogs() {
        DialogRegistry.register("artist.palette") { AnyView(PaletteFromImageDialog()) }
        DialogRegistry.register("artist.recolor", dims: false) { AnyView(RecolorDialog()) }
        DialogRegistry.register("artist.seamless") { AnyView(MakeSeamlessDialog()) }
    }
}

// MARK: - Support directory

enum ArtistSupport {
    static let isSelfTest = CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--perftest")
    /// Set by tests to redirect every file of this module.
    static var overrideDirectory: URL?

    /// `~/Library/Application Support/ImageCrat` (or `$LUMEN_SUPPORT_DIR`). nil during self tests unless redirected, so tests
    /// never read or write the user's real folder.
    static var directory: URL? {
        if let o = overrideDirectory { return o }
        if let o = ProcessInfo.processInfo.environment["LUMEN_SUPPORT_DIR"], !o.isEmpty { return URL(fileURLWithPath: o) }
        if isSelfTest { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Brand.supportFolderName)
    }

    static func read<T: Decodable>(_ type: T.Type, _ file: String) -> T? {
        guard let u = directory?.appendingPathComponent(file), let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    @discardableResult
    static func write<T: Encodable>(_ value: T, _ file: String) -> Bool {
        guard let dir = directory else { return false }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: dir.appendingPathComponent(file), options: .atomic)
            return true
        } catch { return false }
    }
}

// MARK: - Settings

enum StabilizerMode: String, Codable, CaseIterable, Identifiable {
    case off, rope, average
    var id: String { rawValue }
    var title: String {
        switch self { case .off: return "Off"; case .rope: return "Lazy Rope"; case .average: return "Weighted Average" }
    }
}

enum PaletteJitterMode: String, Codable, CaseIterable, Identifiable {
    case off, perStroke, perDab
    var id: String { rawValue }
    var title: String {
        switch self { case .off: return "Off"; case .perStroke: return "Per Stroke"; case .perDab: return "Per Dab" }
    }
}

enum PieTriggerKey: String, Codable, CaseIterable, Identifiable {
    case grave, backslash
    var id: String { rawValue }
    var keyCode: UInt16 { self == .grave ? 50 : 42 }
    var title: String { self == .grave ? "`  (backtick)" : "\\  (backslash)" }
}

struct PieConfig: Codable, Equatable {
    /// Raw values of the eight favourite tools, clockwise from the top.
    var tools: [String] = PieConfig.defaultTools
    var trigger: PieTriggerKey = .grave
    var enabled = true
    var showColors = true
    var showScrubbers = true
    var showActions = true

    static let defaultTools: [String] = [ToolKind.brush, .eraser, .eyedropper, .move, .lasso, .paintBucket, .smudge, .hand].map(\.rawValue)

    init() {}

    var toolKinds: [ToolKind] {
        (0..<8).map { i in (i < tools.count ? ToolKind(rawValue: tools[i]) : nil) ?? ToolKind(rawValue: PieConfig.defaultTools[i]) ?? .brush }
    }

    private enum K: String, CodingKey { case tools, trigger, enabled, showColors, showScrubbers, showActions }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let d = PieConfig()
        tools = c.art(.tools, d.tools); trigger = c.art(.trigger, d.trigger); enabled = c.art(.enabled, d.enabled)
        showColors = c.art(.showColors, d.showColors); showScrubbers = c.art(.showScrubbers, d.showScrubbers); showActions = c.art(.showActions, d.showActions)
        if tools.count != 8 { tools = (0..<8).map { $0 < tools.count ? tools[$0] : d.tools[$0] } }
    }
}

/// Everything of the module that is remembered between launches (not per document).
struct ArtistPrefs: Codable, Equatable {
    var assist = true
    var editGuides = true
    /// Distance (screen px) within which a stroke start attaches to a ruler.
    var rulerSnapRange: Double = 28
    var stabilizer: StabilizerMode = .off
    /// Leash length of the lazy rope (screen px).
    var ropeLength: Double = 40
    var averageWindow: Int = 12
    var catchUp = true
    var paletteJitter: PaletteJitterMode = .off
    /// Swatch group used by the palette jitter (nil = the Swatches panel colours).
    var paletteGroup: UUID? = nil
    var wrapPainting = false
    var eyedropperRing = true
    var pie = PieConfig()

    init() {}

    private enum K: String, CodingKey {
        case assist, editGuides, rulerSnapRange, stabilizer, ropeLength, averageWindow, catchUp, paletteJitter, paletteGroup, wrapPainting, eyedropperRing, pie
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let d = ArtistPrefs()
        assist = c.art(.assist, d.assist); editGuides = c.art(.editGuides, d.editGuides)
        rulerSnapRange = c.art(.rulerSnapRange, d.rulerSnapRange); stabilizer = c.art(.stabilizer, d.stabilizer)
        ropeLength = clamp(c.art(.ropeLength, d.ropeLength), 2, 400); averageWindow = clamp(c.art(.averageWindow, d.averageWindow), 2, 64)
        catchUp = c.art(.catchUp, d.catchUp); paletteJitter = c.art(.paletteJitter, d.paletteJitter)
        paletteGroup = c.art(.paletteGroup, nil as UUID?); wrapPainting = c.art(.wrapPainting, d.wrapPainting)
        eyedropperRing = c.art(.eyedropperRing, d.eyedropperRing); pie = c.art(.pie, d.pie)
    }
}

@Observable
final class ArtistSettings {
    static let shared = ArtistSettings()
    static let key = "Lumen.Artist"

    var prefs: ArtistPrefs {
        didSet {
            guard prefs != oldValue, !ArtistSupport.isSelfTest else { return }
            if let d = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(d, forKey: ArtistSettings.key) }
        }
    }
    /// View ▸ Simulate (view only, not remembered).
    var simulation: VisionSimulation = .none

    private init() {
        if !ArtistSupport.isSelfTest, let d = UserDefaults.standard.data(forKey: ArtistSettings.key), let p = try? JSONDecoder().decode(ArtistPrefs.self, from: d) {
            prefs = p
        } else {
            prefs = ArtistPrefs()
        }
    }

    // Convenience accessors
    var assist: Bool { get { prefs.assist } set { prefs.assist = newValue } }
    var editGuides: Bool { get { prefs.editGuides } set { prefs.editGuides = newValue } }
    var wrapPainting: Bool { get { prefs.wrapPainting } set { prefs.wrapPainting = newValue } }
    var pie: PieConfig { get { prefs.pie } set { prefs.pie = newValue } }
}

/// Shared context of the brush hooks (active document for headless tests, test-pad mode).
enum ArtistContext {
    /// Document used by the hooks when there is no active app document (self tests).
    static weak var testDoc: Document?
    /// True while the Brush Test Pad paints: guides, wrap-around and symmetry are ignored there.
    static var padActive = false
    static var doc: Document? { testDoc ?? AppActions.doc }
    /// Zoom of the canvas (screen px per document px) for thresholds given in screen pixels.
    static var zoom: CGFloat { testDoc != nil ? 1 : (AppActions.canvas?.zoom ?? 1) }
}

// MARK: - Swatch groups

struct SwatchGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var colors: [RGBA]

    init(name: String, colors: [RGBA]) { self.name = name; self.colors = colors }

    private enum K: String, CodingKey { case id, name, colors }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.art(.id, UUID()); name = c.art(.name, "Group"); colors = c.art(.colors, [])
    }
}

/// Named swatch groups (Colour Harmony "Save as swatch group", palettes from images). Saved in `swatch-groups.json`.
@Observable
final class SwatchGroupStore {
    static let shared = SwatchGroupStore()
    static let file = "swatch-groups.json"

    var groups: [SwatchGroup] = [] { didSet { if groups != oldValue && loaded { save() } } }
    @ObservationIgnored private var loaded = false

    private init() { reload() }

    func reload() {
        loaded = false
        groups = ArtistSupport.read(LossyArray<SwatchGroup>.self, SwatchGroupStore.file)?.items ?? []
        loaded = true
    }

    func save() { ArtistSupport.write(LossyArray(groups), SwatchGroupStore.file) }

    @discardableResult
    func add(name: String, colors: [RGBA]) -> SwatchGroup {
        var n = name, i = 2
        while groups.contains(where: { $0.name == n }) { n = "\(name) \(i)"; i += 1 }
        let g = SwatchGroup(name: n, colors: colors)
        groups.append(g)
        return g
    }

    func group(_ id: UUID?) -> SwatchGroup? { groups.first { $0.id == id } }
}
