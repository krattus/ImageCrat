import AppKit
import SwiftUI
import Observation
import ImageCratCore

// MARK: - Artboard preferences

/// Edit ▸ Preferences ▸ Interface ▸ Appearance ▸ Artboards ▸ Border in Photoshop.
enum ArtboardBorderStyle: String, Codable, CaseIterable, Identifiable {
    case dropShadow = "Drop Shadow", line = "Line", none = "None"
    var id: String { rawValue }
}

/// Edit ▸ Preferences ▸ Interface ▸ Appearance ▸ Artboards ▸ Color in Photoshop: the pasteboard around the artboards.
enum ArtboardMatte: String, Codable, CaseIterable, Identifiable {
    case standard = "Default", black = "Black", darkGray = "Dark Gray", mediumGray = "Medium Gray", lightGray = "Light Gray", custom = "Custom"
    var id: String { rawValue }
}

/// Artboard appearance and behaviour (remembered per user, not per document).
struct ArtboardPrefs: Codable, Equatable {
    /// View ▸ Show ▸ Artboard Names.
    var showNames = true
    var matte: ArtboardMatte = .standard
    var customMatte = RGBA(gray: 0.3)
    var border: ArtboardBorderStyle = .dropShadow
    /// The canvas grows and shrinks on every side to fit the artboards and the layers outside them.
    var autoSizeCanvas = true
    /// Layers moved onto an artboard go into it; layers moved off every artboard leave it.
    var autoNest = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ArtboardPrefs()
        showNames = (try? c.decodeIfPresent(Bool.self, forKey: .showNames)) ?? d.showNames
        matte = (try? c.decodeIfPresent(ArtboardMatte.self, forKey: .matte)) ?? d.matte
        customMatte = (try? c.decodeIfPresent(RGBA.self, forKey: .customMatte)) ?? d.customMatte
        border = (try? c.decodeIfPresent(ArtboardBorderStyle.self, forKey: .border)) ?? d.border
        autoSizeCanvas = (try? c.decodeIfPresent(Bool.self, forKey: .autoSizeCanvas)) ?? d.autoSizeCanvas
        autoNest = (try? c.decodeIfPresent(Bool.self, forKey: .autoNest)) ?? d.autoNest
    }

    /// The pasteboard colour around artboards; nil: the standard workspace grey.
    var matteColor: RGBA? {
        switch matte {
        case .standard: return nil
        case .black: return RGBA(gray: 0)
        case .darkGray: return RGBA(gray: 0.235)
        case .mediumGray: return RGBA(gray: 0.5)
        case .lightGray: return RGBA(gray: 0.75)
        case .custom: return customMatte
        }
    }
}

@Observable
final class ArtboardSettings {
    static let shared = ArtboardSettings()
    static let key = "LumenArtboardPrefs"

    @ObservationIgnored private(set) var defaults: UserDefaults = .standard
    @ObservationIgnored private var loading = false

    var prefs: ArtboardPrefs {
        didSet {
            guard prefs != oldValue else { return }
            if !loading { save() }
            AppActions.canvas?.setNeedsRender()
            AppActions.canvas?.overlay.needsDisplay = true
        }
    }

    private init() { prefs = ArtboardSettings.read(.standard) }

    static func read(_ ud: UserDefaults) -> ArtboardPrefs {
        guard let d = ud.data(forKey: key), let p = try? JSONDecoder().decode(ArtboardPrefs.self, from: d) else { return ArtboardPrefs() }
        return p
    }

    private func save() {
        if let d = try? JSONEncoder().encode(prefs) { defaults.set(d, forKey: ArtboardSettings.key) }
    }

    private func load(_ p: ArtboardPrefs) {
        loading = true
        prefs = p
        loading = false
    }

    /// Tests: reads and writes `ud` instead of the user's defaults while `body` runs (the user's settings are never
    /// written; the previous settings come back afterwards).
    func using(_ ud: UserDefaults, _ body: () -> Void) {
        let (d0, p0) = (defaults, prefs)
        defaults = ud
        load(ArtboardSettings.read(ud))
        body()
        defaults = d0
        load(p0)
    }

    /// Tests: a throw-away defaults suite (emptied before and after).
    func usingTemporaryDefaults(_ suite: String, _ body: () -> Void) {
        guard let ud = UserDefaults(suiteName: suite) else { body(); return }
        ud.removePersistentDomain(forName: suite)
        using(ud, body)
        ud.removePersistentDomain(forName: suite)
    }
}

// MARK: - Coordinates (rulers, Info panel, status bar, Properties, transform read-outs)

/// Photoshop measures from the top-left corner of the artboard you're working in: the rulers' zero point, the Info
/// panel and the X / Y of layers inside an artboard follow it. Artboards themselves are placed in the document's own
/// coordinates, whose origin stays where it was when the document became an artboard document (`artboardOrigin`),
/// even after the canvas grew or shrank on the left / top. Guides and every stored position stay in document pixels.
enum ArtboardCoords {
    /// Zero point of the rulers in document pixels: the top-left corner of the active artboard (the selected artboard,
    /// or the one holding the active layer); the canvas corner otherwise.
    static func rulerOrigin(_ d: Document) -> CGPoint {
        guard let r = activeRect(d) else { return .zero }
        return r.origin
    }

    /// The active artboard's rectangle (nil: none).
    static func activeRect(_ d: Document) -> CGRect? {
        ArtboardTool.activeArtboard(d)?.artboard?.rect
    }

    /// Size a percentage on the rulers refers to: the active artboard, or the canvas.
    static func rulerSpan(_ d: Document) -> CGSize {
        activeRect(d)?.size ?? CGSize(width: d.state.width, height: d.state.height)
    }

    /// A document point as the rulers / Info panel / status bar show it.
    static func display(_ p: CGPoint, _ d: Document) -> CGPoint {
        let o = rulerOrigin(d)
        return CGPoint(x: p.x - o.x, y: p.y - o.y)
    }

    /// Origin the X / Y of layer `id` are measured from: the top-left corner of the artboard that holds it (a layer
    /// outside the artboards, or in a normal document: the canvas corner).
    static func layerOrigin(_ id: UUID, _ st: DocumentState) -> CGPoint {
        guard let p = st.parentID(of: id), let a = ArtboardOps.artboard(containing: p, st), let r = a.artboard?.rect else { return .zero }
        return r.origin
    }

    /// An artboard's position as Properties shows it (stable when the canvas is auto-sized on the left / top).
    static func artboardPosition(_ r: CGRect, _ st: DocumentState) -> CGPoint {
        CGPoint(x: r.minX - st.artboardOrigin.x, y: r.minY - st.artboardOrigin.y)
    }

    /// Document point for an artboard position typed into Properties.
    static func documentPoint(artboardPosition p: CGPoint, _ st: DocumentState) -> CGPoint {
        CGPoint(x: p.x + st.artboardOrigin.x, y: p.y + st.artboardOrigin.y)
    }
}

// MARK: - Preferences ▸ Artboards

struct ArtboardPreferencesSection: View {
    @Bindable var s = ArtboardSettings.shared

    var body: some View {
        Caption("Appearance")
        HStack {
            Text("Color").foregroundStyle(Theme.textDim).frame(width: 110, alignment: .leading)
            Picker("", selection: $s.prefs.matte) { ForEach(ArtboardMatte.allCases) { Text($0.rawValue).tag($0) } }
                .labelsHidden().frame(width: 140)
            if s.prefs.matte == .custom { ColorWell(color: $s.prefs.customMatte) }
        }
        .help("The pasteboard around the artboards")
        HStack {
            Text("Border").foregroundStyle(Theme.textDim).frame(width: 110, alignment: .leading)
            Picker("", selection: $s.prefs.border) { ForEach(ArtboardBorderStyle.allCases) { Text($0.rawValue).tag($0) } }
                .labelsHidden().frame(width: 140)
        }
        Toggle2(label: "Show Artboard Names", on: $s.prefs.showNames)
            .help("Also View ▸ Show ▸ Artboard Names")
        Divider()
        Caption("Behavior")
        Toggle2(label: "Auto-size Canvas", on: $s.prefs.autoSizeCanvas)
            .help("The canvas grows and shrinks to fit the artboards and the layers outside them (also in the Artboard tool's options)")
        Toggle2(label: "Auto-nest Layers in Artboards", on: $s.prefs.autoNest)
            .help("Layers moved onto an artboard go into it; layers moved off every artboard leave it")
        Text("With Auto-size Canvas off, the canvas only grows to hold the artboards and keeps its left and top edges.")
            .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
    }
}

/// The Artboard tool's gear menu (Photoshop puts Auto-size Canvas there).
struct ArtboardSettingsMenu: View {
    @Bindable var s = ArtboardSettings.shared
    var body: some View {
        Menu {
            Toggle("Auto-size Canvas", isOn: $s.prefs.autoSizeCanvas)
            Toggle("Auto-nest Layers", isOn: $s.prefs.autoNest)
            Toggle("Show Artboard Names", isOn: $s.prefs.showNames)
            Divider()
            Button("Artboard Preferences…") { Workflow2PrefsState.open("Artboards") }
        } label: { Image(systemName: "gearshape") }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Artboard options")
    }
}
