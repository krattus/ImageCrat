import SwiftUI
import AppKit
import ImageCratCore

// MARK: - Variation logic

/// Switching between the variations of a generative layer. Every entry point (Contextual Task Bar, Properties panel,
/// Layers badge, Layer ▸ Generative menu, ⌥←/⌥→) ends up in `select` / `step`.
enum GenVariations {
    /// Consecutive switches on the same layer within this many seconds share one history step.
    nonisolated(unsafe) static var coalesceWindow: TimeInterval = 3
    nonisolated(unsafe) private static var lastSwitch: (doc: ObjectIdentifier, layer: UUID, entry: UUID, at: Date)?

    static func isGenerative(_ d: Document?, _ id: UUID?) -> Bool {
        guard let d, let id else { return false }
        return d.state.generative[id] != nil
    }

    /// The active document's active layer, when it is a generative layer.
    static var active: (doc: Document, layerID: UUID, info: GenerativeLayerInfo)? {
        guard let d = AppActions.doc, let id = d.activeLayerID, let inf = d.state.generative[id] else { return nil }
        return (d, id, inf)
    }

    /// Where a variation goes: the layer's current position if the user moved it (same-size raster), else the generated region.
    static func origin(_ layer: Layer?, info: GenerativeLayerInfo, variation: PixelBuffer) -> IPoint {
        if let r = layer?.raster, r.buffer.width == variation.width, r.buffer.height == variation.height { return r.origin }
        return info.rect.origin
    }

    /// Shows variation `index`. Undoable; rapid consecutive switches on the same layer collapse into one "Select Variation"
    /// history step (undo returns to the variation shown before the run of switches). Only the layer's pixels change:
    /// mask, position, opacity, blend mode and effects stay as they are.
    static func select(_ d: Document, layerID: UUID, index: Int) {
        guard var inf = d.state.generative[layerID], let v = inf.variations[genSafe: index], let layer = d.state.layer(layerID), layer.isRaster else { return }
        if inf.selected == index, layer.raster?.buffer === v { return }
        let o = origin(layer, info: inf, variation: v)
        inf.selected = index
        d.state.generative[layerID] = inf
        d.updateLayer(layerID) { $0.raster = RasterContent(buffer: v, origin: o) }
        let now = Date()
        let top = d.history.indices.contains(d.historyIndex) ? d.history[d.historyIndex].id : nil
        if let l = lastSwitch, l.doc == ObjectIdentifier(d), l.layer == layerID, l.entry == top, d.historyIndex == d.history.count - 1,
           now.timeIntervalSince(l.at) <= coalesceWindow {
            d.commitReplacingLast("Select Variation")
        } else {
            d.commit("Select Variation")
        }
        if d.history.indices.contains(d.historyIndex) { lastSwitch = (ObjectIdentifier(d), layerID, d.history[d.historyIndex].id, now) }
        d.setNeedsRender()
        AppModel.shared.setStatus("Variation \(index + 1) of \(inf.variations.count)")
    }

    /// Next (+1) / previous (−1) variation, wrapping around.
    static func step(_ d: Document, layerID: UUID, by delta: Int) {
        guard let inf = d.state.generative[layerID], inf.variations.count > 1 else { return }
        let n = inf.variations.count
        select(d, layerID: layerID, index: ((inf.selected + delta) % n + n) % n)
    }

    static func next() { if let a = active { step(a.doc, layerID: a.layerID, by: 1) } else { Beep.play() } }
    static func previous() { if let a = active { step(a.doc, layerID: a.layerID, by: -1) } else { Beep.play() } }

    static func delete(_ d: Document, layerID: UUID, index: Int) {
        guard var inf = d.state.generative[layerID], inf.variations.count > 1, inf.variations.indices.contains(index) else { return }
        inf.variations.remove(at: index)
        if inf.seeds.indices.contains(index) { inf.seeds.remove(at: index) }
        if index < inf.selected { inf.selected -= 1 }
        inf.selected = min(max(0, inf.selected), inf.variations.count - 1)
        let v = inf.variations[inf.selected]
        let o = origin(d.state.layer(layerID), info: inf, variation: v)
        d.state.generative[layerID] = inf
        d.updateLayer(layerID) { $0.raster = RasterContent(buffer: v, origin: o) }
        d.commit("Delete Variation")
        d.setNeedsRender()
    }

    static func deleteCurrent(_ d: Document, layerID: UUID) {
        if let inf = d.state.generative[layerID] { delete(d, layerID: layerID, index: inf.selected) }
    }

    /// Drops every variation except the one shown (smaller documents; the pixels are released once the undo steps that
    /// still reference them expire).
    static func keepOnlyCurrent(_ d: Document, layerID: UUID) {
        guard var inf = d.state.generative[layerID], inf.variations.count > 1, let v = inf.variations[genSafe: inf.selected] else { return }
        let seed = inf.seeds[genSafe: inf.selected] ?? nil
        inf.variations = [v]
        inf.seeds = [seed]
        inf.selected = 0
        d.state.generative[layerID] = inf
        d.commit("Keep Variation")
    }

    /// Turns the generative layer into an ordinary pixel layer (drops prompt, variations and mask metadata).
    static func flatten(_ d: Document, layerID: UUID) {
        guard d.state.generative[layerID] != nil else { return }
        d.state.generative[layerID] = nil
        d.commit("Flatten Generative Layer")
    }

    /// Generates more variations for the layer (same feature, model and region), optionally with an edited prompt.
    static func generateMore(_ d: Document, layerID: UUID, prompt: String? = nil) {
        guard d.state.generative[layerID] != nil else { return }
        GenPipeline.regenerate(d, layerID: layerID, prompt: prompt)
    }

    static func generateMoreActive() {
        if let a = active { generateMore(a.doc, layerID: a.layerID) }
        else { GenJobs.shared.report(.unsupported("Select a generative layer first."), title: "Generate More") }
    }

    /// Estimated cost of "Generate" on this layer, e.g. "≈ $0.15 for 3 variations with fal.ai FLUX.1 Pro Fill".
    static func estimateText(_ inf: GenerativeLayerInfo) -> String? {
        let override = inf.providerID.isEmpty ? nil : "\(inf.providerID):\(inf.modelID)"
        guard let m = (try? ProviderRouter.shared.resolve(inf.featureKind, override: override))?.1 else { return nil }
        return GenBudget.estimateText(m, count: GenBudget.count(for: inf.featureKind))
    }

    /// Bytes held by a layer's variations.
    static func memory(_ inf: GenerativeLayerInfo) -> Int {
        inf.variations.reduce(0) { $0 + $1.width * $1.height * ($1.format == .gray ? 1 : 4) }
    }

    /// A generation just added a layer: make the variation controls easy to find (not in headless runs).
    static func generationAdded(_ d: Document, layerID: UUID) {
        guard !GenJobs.shared.headless, AppModel.shared.activeDocument === d else { return }
        if GenAISettings.shared.data.revealPropertiesAfterGenerate { WorkspaceManager.shared.reveal("properties") }
        if let n = d.state.generative[layerID]?.variations.count, n > 1 {
            AppModel.shared.setStatus("\(n) variations — compare them with ‹ › in the task bar or ⌥← / ⌥→")
        }
    }

    /// ⌥← / ⌥→ (called from KeyRouter, which has already ruled out text fields and dialogs): previous / next variation
    /// while a generative layer with more than one variation is active. Anything else falls through to the canvas.
    static func handleKey(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown, e.keyCode == 123 || e.keyCode == 124 else { return false }
        guard e.modifierFlags.intersection([.command, .control, .option, .shift]) == [.option] else { return false }
        guard !AppModel.shared.textEditingActive, AppActions.canvas?.currentTool.isBusy != true else { return false }
        guard let a = active, a.info.variations.count > 1 else { return false }
        step(a.doc, layerID: a.layerID, by: e.keyCode == 124 ? 1 : -1)
        return true
    }
}

// MARK: - Thumbnails

/// Variation thumbnails, cached per pixel buffer (entries go away with the buffer).
enum GenThumbs {
    private final class Box { var images: [Int: CGImage] = [:] }
    nonisolated(unsafe) private static let cache = NSMapTable<PixelBuffer, Box>.weakToStrongObjects()

    static func image(_ b: PixelBuffer, maxEdge: Int) -> CGImage {
        let box: Box
        if let existing = cache.object(forKey: b) { box = existing } else { box = Box(); cache.setObject(box, forKey: b) }
        if let i = box.images[maxEdge] { return i }
        let i = GenImaging.thumbnail(b, maxEdge: maxEdge)
        box.images[maxEdge] = i
        return i
    }
}

// MARK: - Shared controls

/// "‹ 2/3 ›"
struct GenVariationStepper: View {
    @Bindable var doc: Document
    let layerID: UUID
    var spelledOut = false

    var body: some View {
        if let inf = doc.state.generative[layerID] {
            let n = inf.variations.count
            HStack(spacing: 2) {
                arrow("chevron.left", "Previous Variation (⌥←)", -1, n)
                Text(spelledOut ? "Variation \(inf.selected + 1) of \(n)" : "\(inf.selected + 1)/\(n)")
                    .font(Theme.mono).foregroundStyle(Theme.text)
                    .frame(minWidth: spelledOut ? 96 : 30)
                    .help("Variation \(inf.selected + 1) of \(n)")
                arrow("chevron.right", "Next Variation (⌥→)", 1, n)
            }
        }
    }

    private func arrow(_ symbol: String, _ help: String, _ delta: Int, _ n: Int) -> some View {
        Button { GenVariations.step(doc, layerID: layerID, by: delta) } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(n > 1 ? Theme.text : Theme.textFaint)
        .disabled(n < 2)
        .help(help)
    }
}

/// Numbered thumbnails; the shown variation has an accent frame and a check mark. Click to switch.
struct GenVariationGrid: View {
    @Bindable var doc: Document
    let layerID: UUID
    var columns = 2
    var cell = CGSize(width: 128, height: 96)

    var body: some View {
        if let inf = doc.state.generative[layerID] {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell.width), spacing: 6), count: columns), alignment: .leading, spacing: 6) {
                ForEach(Array(inf.variations.enumerated()), id: \.offset) { i, v in
                    let on = i == inf.selected
                    ZStack {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG)
                        Image(decorative: GenThumbs.image(v, maxEdge: Int(max(cell.width, cell.height)) * 2), scale: 2)
                            .resizable().aspectRatio(contentMode: .fit).padding(2)
                    }
                    .frame(width: cell.width, height: cell.height)
                    .overlay(alignment: .topLeading) {
                        Text("\(i + 1)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(on ? Theme.accent : Color.black.opacity(0.6)))
                            .padding(4)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if on {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 13))
                                .foregroundStyle(.white, Theme.accent).padding(4)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(on ? Theme.accent : Theme.border, lineWidth: on ? 2.5 : 1))
                    .contentShape(Rectangle())
                    .onTapGesture { GenVariations.select(doc, layerID: layerID, index: i) }
                    .contextMenu {
                        Button("Show Variation \(i + 1)") { GenVariations.select(doc, layerID: layerID, index: i) }
                        Button("Delete Variation \(i + 1)") { GenVariations.delete(doc, layerID: layerID, index: i) }.disabled(inf.variations.count < 2)
                    }
                    .help(on ? "Variation \(i + 1) (shown)" : "Show variation \(i + 1)")
                    .accessibilityLabel("Variation \(i + 1)\(on ? ", selected" : "")")
                }
            }
        }
    }
}

// MARK: - Contextual Task Bar

/// Task bar shown while a generative layer is active: prompt, ‹ 2/3 ›, thumbnails, Generate.
struct GenTaskBarControls: View {
    @Bindable var doc: Document
    @Bindable private var jobs = GenJobs.shared
    @State private var draft: String?
    @State private var showGrid = false

    var body: some View {
        if let id = doc.activeLayerID, let inf = doc.state.generative[id] {
            let busy = !jobs.active.isEmpty
            Image(systemName: "sparkles").foregroundStyle(Theme.accent).help("\(inf.featureKind.displayName) layer")
            TextField(inf.featureKind == .remove ? "Remove (no prompt)" : "Describe what to generate", text: Binding(get: { draft ?? inf.prompt }, set: { draft = $0 }))
                .textFieldStyle(.plain).font(Theme.font)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(width: 170)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.fieldBG))
                .onSubmit { generate(id) }
                .onChange(of: id) { _, _ in draft = nil }
                .help("Prompt — press Return to generate more variations")
            GenVariationStepper(doc: doc, layerID: id)
            Button { showGrid.toggle() } label: {
                Image(systemName: "square.grid.2x2").font(.system(size: 11))
                    .frame(width: 24, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(showGrid ? Theme.accent.opacity(0.6) : Color.white.opacity(0.08)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show all variations")
            .popover(isPresented: $showGrid, arrowEdge: .bottom) { GenVariationPopover(doc: doc, layerID: id) }
            Button { generate(id) } label: {
                HStack(spacing: 4) {
                    if busy { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles").font(.system(size: 10)) }
                    Text(busy ? "Generating…" : "Generate").lineLimit(1)
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(busy ? Color.white.opacity(0.08) : Theme.accent))
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help("Generate more variations" + (GenVariations.estimateText(inf).map { " (\($0))" } ?? ""))
            if doc.state.selection != nil {
                Rectangle().fill(Theme.border).frame(width: 1, height: 18)
                chip("Fill Selection…", "sparkles.rectangle.stack") { NotificationCenter.default.post(name: Notification.Name("LumenGenerativeFill"), object: nil) }
                    .help("Generative Fill for the current selection (new layer)")
                chip("Deselect", "xmark") { AppActions.deselect() }
            }
        }
    }

    private func chip(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).lineLimit(1)
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private func generate(_ id: UUID) {
        guard jobs.active.isEmpty else { return }
        GenVariations.generateMore(doc, layerID: id, prompt: draft)
        draft = nil
    }
}

/// Popover with every variation (task bar button and Layers badge).
struct GenVariationPopover: View {
    @Bindable var doc: Document
    let layerID: UUID
    @Bindable private var jobs = GenJobs.shared

    var body: some View {
        if let inf = doc.state.generative[layerID] {
            let cols = inf.variations.count > 6 ? 4 : (inf.variations.count > 4 ? 3 : min(3, max(2, inf.variations.count)))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    Text("Variations").font(Theme.fontBold)
                    Spacer(minLength: 12)
                    GenVariationStepper(doc: doc, layerID: layerID)
                }
                if !inf.prompt.isEmpty { Text("“\(inf.prompt)”").font(Theme.fontSmall).foregroundStyle(Theme.textDim).lineLimit(2) }
                GenVariationGrid(doc: doc, layerID: layerID, columns: cols, cell: CGSize(width: 104, height: 78))
                HStack {
                    Button("Generate More") { GenVariations.generateMore(doc, layerID: layerID) }
                        .buttonStyle(PanelButtonStyle(prominent: true)).disabled(!jobs.active.isEmpty)
                    Spacer()
                    Text("⌥← / ⌥→ switch").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                }
            }
            .padding(10)
            .font(Theme.font)
            .foregroundStyle(Theme.text)
            .frame(width: CGFloat(cols) * 110 + 14)
            .background(Theme.panelBG)
            .environment(\.colorScheme, Theme.colorScheme)
        }
    }
}

// MARK: - Properties panel section

/// Top of the Properties panel for a generative layer (also while its mask is targeted): prompt, ←/→, numbered
/// thumbnails, Generate / Similar / Enhance, and variation housekeeping.
struct GenerativeLayerProperties: View {
    @Bindable var doc: Document
    let layerID: UUID
    @State private var draft: String?
    @Bindable private var jobs = GenJobs.shared
    @Environment(\.panelWidth) private var panelWidth
    var prompt: String { draft ?? doc.state.generative[layerID]?.prompt ?? "" }

    /// Variation thumbnails: 2 (3 when there are more than 4) per row, smaller in a narrow column.
    func cell(_ n: Int) -> CGSize {
        let cols: CGFloat = n > 4 ? 3 : 2
        let full = n > 4 ? CGSize(width: 86, height: 66) : CGSize(width: 134, height: 100)
        let room = panelWidth.isFinite ? panelWidth - 20 : .infinity   // (the Properties panel's padding)
        let w = min(full.width, ((room - (cols - 1) * 6) / cols).rounded(.down))
        return CGSize(width: w, height: (w * full.height / full.width).rounded())
    }

    var body: some View {
        if let inf = doc.state.generative[layerID] {
            let n = inf.variations.count
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Caption("Generative Layer")
                Spacer()
                Text(GenMoney.string(inf.cost)).font(Theme.fontSmall).foregroundStyle(Theme.textFaint).help("Spent on this layer so far")
            }
            Text("\(inf.featureKind.displayName) · \(ProviderID(rawValue: inf.providerID)?.displayName ?? inf.providerID) · \(inf.modelID)")
                .font(Theme.fontSmall).foregroundStyle(Theme.textDim).lineLimit(2)
            TextField("Prompt", text: Binding(get: { draft ?? inf.prompt }, set: { draft = $0 }), axis: .vertical).lineLimit(1...4).genField()
                .onChange(of: layerID) { _, _ in draft = nil }
            WrappingHStack {
                GenVariationStepper(doc: doc, layerID: layerID, spelledOut: true)
                Spacer()
                Text("⌥← ⌥→").font(Theme.fontSmall).foregroundStyle(Theme.textFaint).help("Previous / next variation")
            }
            GenVariationGrid(doc: doc, layerID: layerID, columns: n > 4 ? 3 : 2, cell: cell(n))
            WrappingHStack {
                Button("Generate") { GenVariations.generateMore(doc, layerID: layerID, prompt: prompt); draft = nil }
                    .buttonStyle(PanelButtonStyle(prominent: true))
                    .help("Add more variations" + (GenVariations.estimateText(inf).map { " (\($0))" } ?? ""))
                Button("Similar") { GenPipeline.regenerate(doc, layerID: layerID, prompt: prompt, similar: true) }.buttonStyle(PanelButtonStyle())
                    .help("Generate variations similar to the selected one")
                if inf.featureKind != .upscale && inf.featureKind != .denoise && inf.featureKind != .sharpen {
                    Button("Enhance Detail") { GenPipeline.regenerate(doc, layerID: layerID, enhance: true) }.buttonStyle(PanelButtonStyle())
                        .help("Re-render the selected variation with a detail-adding upscaler")
                }
            }
            .disabled(!jobs.active.isEmpty)
            if !jobs.active.isEmpty {
                Text("Generating…").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            } else if let est = GenVariations.estimateText(inf) {
                Text(est).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
            WrappingHStack {
                Button("Delete Variation") { GenVariations.deleteCurrent(doc, layerID: layerID) }.buttonStyle(PanelButtonStyle())
                    .disabled(n < 2).help("Remove the variation that is shown")
                Button("Keep Only This One") { GenVariations.keepOnlyCurrent(doc, layerID: layerID) }.buttonStyle(PanelButtonStyle())
                    .disabled(n < 2).help("Discard the other \(max(0, n - 1)) variations (\(ByteCountFormatter.string(fromByteCount: Int64(GenVariations.memory(inf)), countStyle: .memory)) held now)")
            }
            Button("Flatten to Normal Layer") { GenVariations.flatten(doc, layerID: layerID) }.buttonStyle(PanelButtonStyle())
                .help("Keep the pixels shown and drop the prompt, variations and generative metadata")
            Divider()
        }
    }
}

// MARK: - Layers panel

/// Sparkles badge on generative layer rows; click for the variations popover.
struct GenLayerBadge: View {
    @Bindable var doc: Document
    let layerID: UUID
    @State private var show = false

    var body: some View {
        if let inf = doc.state.generative[layerID] {
            Button {
                doc.selectLayer(layerID)
                show.toggle()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "sparkles").font(.system(size: 9, weight: .semibold))
                    if inf.variations.count > 1 { Text("\(inf.selected + 1)/\(inf.variations.count)").font(.system(size: 9, weight: .semibold)).monospacedDigit() }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(Capsule().fill(Theme.accent))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Generative layer — variation \(inf.selected + 1) of \(inf.variations.count). Click to switch.")
            .popover(isPresented: $show, arrowEdge: .leading) { GenVariationPopover(doc: doc, layerID: layerID) }
        }
    }
}

/// Generative items of a layer row's context menu.
struct GenLayerContextMenu: View {
    let doc: Document
    let layerID: UUID

    var body: some View {
        if let inf = doc.state.generative[layerID] {
            let many = inf.variations.count > 1
            Button("Next Variation (⌥→)") { doc.selectLayer(layerID); GenVariations.step(doc, layerID: layerID, by: 1) }.disabled(!many)
            Button("Previous Variation (⌥←)") { doc.selectLayer(layerID); GenVariations.step(doc, layerID: layerID, by: -1) }.disabled(!many)
            Button("Generate More Variations") { doc.selectLayer(layerID); GenVariations.generateMore(doc, layerID: layerID) }
            Button("Keep Only Current Variation") { GenVariations.keepOnlyCurrent(doc, layerID: layerID) }.disabled(!many)
            Button("Flatten to Normal Layer") { GenVariations.flatten(doc, layerID: layerID) }
            Divider()
        }
    }
}
