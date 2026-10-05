import AppKit
import SwiftUI
import ImageCratCore

/// Right-click (or ⌃-click, or the pen's side button) on the canvas with a brush tool: a small picker at the pointer
/// with Size, Hardness and grids of the brush library's favourites, recent brushes and every brush.
///
/// The brush library is the single source of truth: the presets, thumbnails, favourites and recent brushes are the
/// library's, choosing goes through `BrushLibrary.choose(_:into:tool:)` (Recent, the tool's active preset, the
/// modified mark) and ★ toggles the library favourite — the Brushes panel and the options-bar picker show the same.
enum QuickBrushPicker {
    /// Shows the picker (replaceable by tests: headless runs never put a window on screen).
    static var presenter: (CGPoint, CanvasView, ToolKind) -> Void = { p, canvas, kind in present(at: p, canvas: canvas, kind: kind) }
    private static var popover: NSPopover?
    /// The last request (tests).
    private(set) static var lastOpened: (point: CGPoint, tool: ToolKind)?

    static var library: BrushLibrary { BrushLibrary.shared }

    static func open(at p: CGPoint, canvas: CanvasView) {
        let k = canvas.effectiveToolKind
        guard AppModel.hasBrush(k) else { return }
        lastOpened = (p, k)
        presenter(p, canvas, k)
    }

    private static func present(at p: CGPoint, canvas: CanvasView, kind: ToolKind) {
        guard canvas.window != nil else { return }
        popover?.close()
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        let host = NSHostingController(rootView: QuickBrushPickerView(tool: kind, onPick: { [weak pop] in pop?.close() }))
        pop.contentViewController = host
        pop.show(relativeTo: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2), of: canvas, preferredEdge: .maxY)
        popover = pop
    }

    static var isShown: Bool { popover?.isShown ?? false }

    /// What the picker lists: favourites, recent brushes (without the favourites, at most 8) and every brush in
    /// library order.
    static func sections() -> (favorites: [BrushRecord], recent: [BrushRecord], all: [BrushRecord]) {
        let lib = library
        let favs = lib.favoriteBrushes
        let recent = lib.recentBrushes.filter { r in !favs.contains { $0.id == r.id } }
        return (favs, Array(recent.prefix(8)), lib.orderedBrushes)
    }

    /// Applies a library preset to a tool's brush (size / tool settings / colour as the preset includes them); the
    /// library notes it as recent and as that tool's active preset.
    static func choose(_ id: String, for k: ToolKind) {
        let app = AppModel.shared
        var s = app.brushSettings(for: k)
        library.choose(id, into: &s, tool: k)
        app.setBrushSettings(s, for: k)
    }

    /// ★: the library favourite (one undo step in the Brushes panel's history).
    static func toggleFavorite(_ id: String) {
        library.setFavorite(id, !library.isFavorite(id))
    }
}

struct QuickBrushPickerView: View {
    let tool: ToolKind
    var onPick: () -> Void = {}
    @Bindable var app = AppModel.shared
    @Bindable var lib = BrushLibrary.shared

    private var settings: Binding<BrushSettings> {
        Binding(get: { app.brushSettings(for: tool) }, set: { app.setBrushSettings($0, for: tool) })
    }

    var body: some View {
        let (favs, recents, all) = QuickBrushPicker.sections()
        let active = lib.activePresetID(for: tool)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                BrushTipPreview(settings: settings.wrappedValue).frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.35)))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Size").foregroundStyle(Theme.textDim).frame(width: 56, alignment: .leading)
                        Slider(value: Binding(get: { QuickBrushPickerView.sliderFromSize(settings.wrappedValue.size) },
                                              set: { settings.wrappedValue.size = QuickBrushPickerView.sizeFromSlider($0) }), in: 0...1000)
                        Text("\(Int(settings.wrappedValue.size)) px").font(Theme.mono).foregroundStyle(Theme.textDim).frame(width: 52, alignment: .trailing)
                    }
                    ValueSlider(label: "Hardness", value: Binding(get: { settings.wrappedValue.hardness * 100 }, set: { settings.wrappedValue.hardness = $0 / 100 }),
                                range: 0...100, unit: "%", labelWidth: 56)
                }
            }
            if let a = active.flatMap({ lib.record($0) }) {
                Text(a.name).font(Theme.fontSmall).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
            }
            if !favs.isEmpty { section("Favourites", favs, active: active) }
            if !recents.isEmpty { section("Recent", recents, active: active) }
            Text("Brushes").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            ScrollView {
                grid(all, active: active)
            }.frame(height: 150)
            Text("Click a brush to use it · ★ on hover marks a favourite").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
        .padding(10)
        .frame(width: 280)
        .font(Theme.font)
        .foregroundStyle(Theme.text)
    }

    @ViewBuilder private func section(_ title: String, _ brushes: [BrushRecord], active: String?) -> some View {
        Text(title).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        grid(brushes, active: active)
    }

    private func grid(_ brushes: [BrushRecord], active: String?) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 4), count: 6), spacing: 4) {
            ForEach(brushes, id: \.id) { r in QuickBrushCell(record: r, tool: tool, active: r.id == active, onPick: onPick) }
        }
    }

    /// The size slider is logarithmic-ish: fine control for small brushes, still reaching 5000 px.
    static func sizeFromSlider(_ v: Double) -> Double { max(1, (pow(5000, v / 1000)).rounded()) }
    static func sliderFromSize(_ s: Double) -> Double { log(max(1, s)) / log(5000) * 1000 }
}

private struct QuickBrushCell: View {
    let record: BrushRecord
    let tool: ToolKind
    let active: Bool
    var onPick: () -> Void
    @State private var hover = false
    @Bindable var lib = BrushLibrary.shared
    @Bindable var app = AppModel.shared

    var body: some View {
        let fav = lib.isFavorite(record.id)
        let ink = app.prefs.theme.isLight ? RGBA(gray: 0.12) : RGBA(gray: 0.88)
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 1) {
                if let img = lib.thumbnail(record.id, size: 48, color: ink) {
                    Image(decorative: img, scale: 2).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 24, height: 24)
                } else {
                    Color.clear.frame(width: 24, height: 24)
                }
                Text("\(Int(record.params.size))").font(.system(size: 8)).foregroundStyle(Theme.textDim)
            }
            .frame(width: 40, height: 38)
            .background(RoundedRectangle(cornerRadius: 4).fill(active || hover ? Theme.selection : Theme.fieldBG))
            .contentShape(Rectangle())
            .onTapGesture { QuickBrushPicker.choose(record.id, for: tool); onPick() }
            if hover || fav {
                Image(systemName: fav ? "star.fill" : "star").font(.system(size: 8)).foregroundStyle(fav ? Color.yellow : Theme.textDim)
                    .padding(2).contentShape(Rectangle())
                    .onTapGesture { QuickBrushPicker.toggleFavorite(record.id) }
            }
        }
        .onHover { hover = $0 }
        .help(record.name)
    }
}
