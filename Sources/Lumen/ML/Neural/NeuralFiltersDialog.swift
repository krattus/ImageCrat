import SwiftUI
import CoreImage
import UniformTypeIdentifiers
import ImageCratCore

enum NeuralOutput: String, CaseIterable, Identifiable {
    case currentLayer = "Current Layer", newLayer = "New Layer", smartFilter = "Smart Filter", newDocument = "New Document"
    var id: String { rawValue }
}

@Observable
final class NeuralFiltersModel {
    var enabled: Set<NeuralFilterKind> = []
    var selected: NeuralFilterKind = .skinSmoothing
    var values: [NeuralFilterKind: [String: Double]] = Dictionary(uniqueKeysWithValues: NeuralFilterKind.allCases.map { ($0, $0.defaults()) })
    var focalPoint: CGPoint? = nil
    var hints: [(CGPoint, RGBA)] = []
    var reference: CGImage? = nil
    var output: NeuralOutput = .newLayer
    var compare = 0          // 0 after, 1 before, 2 split
    var split: CGFloat = 0.5

    var previewInput: CGImage? = nil
    var previewResult: CGImage? = nil
    var status = ""
    var error: String? = nil
    var busy = false
    var applying = false
    var progress: Double = 0

    @ObservationIgnored var fullInput: CGImage? = nil
    @ObservationIgnored var belowFull: CGImage? = nil
    @ObservationIgnored var belowPreview: CGImage? = nil
    @ObservationIgnored var task: Task<Void, Never>? = nil
    @ObservationIgnored var generation = 0
    @ObservationIgnored var loaded = false

    static let previewSide = 768

    /// Captures the active layer (canvas-size, with alpha) and the composite of the layers below it.
    func load() {
        if loaded { return }
        loaded = true
        guard let d = AppActions.doc, let l = d.activeLayer else { status = "No active layer."; return }
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        let content = Compositor.shared.contentImage(l, space: space) ?? CIImage.clearImage
        fullInput = NImg.cg(content.cropped(to: space.ciCanvas).composited(over: CIImage.clearImage.cropped(to: space.ciCanvas)), rect: space.ciCanvas)
        // layers below: hide the active layer and everything above it (depth-first order)
        var st = d.committedState
        let order = st.allLayers.map(\.id)
        if let idx = order.firstIndex(of: l.id) {
            for id in order[idx...] where !(st.layer(id)?.isGroup ?? false) || id == l.id { st.updateLayer(id) { $0.isVisible = false } }
        }
        let below = Compositor.shared.composite(st)
        belowFull = NImg.cg(below.cropped(to: space.ciCanvas).composited(over: CIImage.clearImage.cropped(to: space.ciCanvas)), rect: space.ciCanvas)
        if let b = belowFull, NImg.alpha(b).map({ $0.data.max() ?? 0 }) == 0 { belowFull = nil }
        if let f = fullInput { previewInput = NImg.fitted(f, maxSide: Self.previewSide) }
        belowPreview = belowFull.map { NImg.fitted($0, maxSide: Self.previewSide) }
        output = l.isRaster ? .currentLayer : .newLayer
        if !(l.isRaster) && output == .currentLayer { output = .newLayer }
    }

    func needsModels(_ k: NeuralFilterKind) -> [String] { k.models.filter { !NeuralModels.isInstalled($0) } }

    func toggle(_ k: NeuralFilterKind) {
        if enabled.contains(k) { enabled.remove(k) } else {
            enabled.insert(k)
            selected = k
            for id in needsModels(k) {
                Task {
                    do { try await ModelManager.shared.ensure(id) }
                    catch { await MainActor.run { self.error = "\(k.title): \(ModelManager.shared.missingMessage(id))" } }
                    await MainActor.run { self.schedule() }
                }
            }
        }
        schedule()
    }

    var ctxPreview: NeuralContext {
        var c = NeuralContext()
        c.below = belowPreview
        c.reference = reference
        c.focalPoint = focalPoint
        c.hints = hints
        c.preview = true
        return c
    }

    /// Debounced preview run.
    func schedule() {
        task?.cancel()
        generation += 1
        let gen = generation
        guard let input = previewInput else { return }
        let kinds = NeuralFilterKind.allCases.filter { enabled.contains($0) && needsModels($0).isEmpty }
        if kinds.isEmpty { previewResult = nil; busy = false; error = nil; return }
        var ctx = ctxPreview
        let vals = values
        busy = true
        error = nil
        ctx.progress = { [weak self] name, p in Task { @MainActor in if self?.generation == gen { self?.status = "\(name)…"; self?.progress = p } } }
        // Style Transfer (neural): train in the background, preview with the fast look meanwhile
        var vv = vals
        if kinds.contains(.styleTransfer), (vals[.styleTransfer]?["mode"] ?? 0) < 0.5 {
            let p = StyleTransfer.preset(Int(vals[.styleTransfer]?["style"] ?? 0))
            if !StyleTransfer.isTrained(p.id) {
                vv[.styleTransfer]?["mode"] = 1
                let content = fullInput ?? input
                Task.detached { [weak self] in
                    _ = try? await StyleTransfer.Trainer.shared.train(p, content: content)
                    await MainActor.run { self?.schedule() }
                }
            }
        }
        let small = kinds.contains(.superZoom) ? NImg.fitted(input, maxSide: 384) : input
        task = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            do {
                let r = try await NeuralFilterEngine.runStack(kinds, values: vv, input: small, ctx: ctx)
                if Task.isCancelled { return }
                await MainActor.run { guard let self, self.generation == gen else { return }; self.previewResult = r; self.busy = false; self.status = "" }
            } catch is CancellationError {
            } catch {
                await MainActor.run { guard let self, self.generation == gen else { return }; self.busy = false; self.error = error.localizedDescription; self.status = "" }
            }
        }
    }

    /// Full-resolution run + output. Closes the dialog when done.
    @MainActor
    func apply() {
        guard let d = AppActions.doc, let id = d.activeLayerID, let input = fullInput else { return }
        let kinds = NeuralFilterKind.allCases.filter { enabled.contains($0) }
        guard !kinds.isEmpty else { AppModel.shared.dialog = nil; return }
        if let k = kinds.first(where: { !needsModels($0).isEmpty }), let id = needsModels(k).first {
            error = "\(k.title): \(ModelManager.shared.missingMessage(id))"; return
        }
        var ctx = ctxPreview
        ctx.preview = false
        ctx.below = belowFull
        ctx.progress = { [weak self] name, p in Task { @MainActor in self?.status = "Applying \(name)…"; self?.progress = p } }
        let vals = values
        let out = kinds.contains(where: \.resizes) ? NeuralOutput.newDocument : output
        applying = true
        task?.cancel()
        let settingsValues = flattenedValues(kinds)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let t0 = CFAbsoluteTimeGetCurrent()
                let r = try await NeuralFilterEngine.runStack(kinds, values: vals, input: input, ctx: ctx)
                let dt = CFAbsoluteTimeGetCurrent() - t0
                await MainActor.run {
                    NeuralFiltersModel.write(r, to: d, layerID: id, output: out, name: kinds.count == 1 ? kinds[0].title : "Neural Filters", settings: settingsValues)
                    AppModel.shared.setStatus(String(format: "Neural Filters applied in %.1f s", dt))
                    self?.applying = false
                    AppModel.shared.dialog = nil
                }
            } catch {
                await MainActor.run { self?.applying = false; self?.error = error.localizedDescription }
            }
        }
    }

    func flattenedValues(_ kinds: [NeuralFilterKind]) -> [String: Double] {
        var v: [String: Double] = [:]
        for k in kinds { v["enabled.\(k.rawValue)"] = 1; for (key, x) in values[k] ?? [:] { v["\(k.rawValue).\(key)"] = x } }
        return v
    }

    /// Wraps one layer into an embedded smart object (same logic as Layer ▸ Smart Objects ▸ Convert, for any document).
    @MainActor
    static func convertToSmartObject(_ d: Document, _ id: UUID) -> UUID? {
        guard let l = d.state.layer(id), let b0 = Compositor.shared.contentBounds(l, state: d.state) else { return nil }
        let fx = l.effects.extent
        let b = IRect(enclosing: b0.insetBy(dx: -CGFloat(fx), dy: -CGFloat(fx)))
        var inner = DocumentState(width: max(1, b.width), height: max(1, b.height), resolution: d.state.resolution)
        var moved = l; moved.translate(dx: Double(-b.x), dy: Double(-b.y)); moved.isClipped = false
        inner.layers = [moved]
        let so = SmartObjectContent(source: .document(inner), quad: Quad(rect: b.cgRect), sourceName: l.name)
        let nl = Layer(name: l.name, content: .smartObject(so))
        d.state.insertLayer(nl, above: id)
        d.state.removeLayer(id)
        d.activeLayerID = nl.id
        d.selectedLayerIDs = [nl.id]
        return nl.id
    }

    /// Writes a canvas-size result (or any size for New Document).
    @MainActor
    static func write(_ r: CGImage, to d: Document, layerID: UUID, output: NeuralOutput, name: String, settings: [String: Double]) {
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        let sameSize = r.width == d.state.width && r.height == d.state.height
        var result = CIImage(cgImage: r)
        if sameSize, let sel = d.state.selection, output != .newDocument, let l = d.state.layer(layerID), let orig = Compositor.shared.contentImage(l, space: space) {
            result = result.mixed(with: orig.cropped(to: space.ciCanvas).composited(over: CIImage.clearImage.cropped(to: space.ciCanvas)),
                                  mask: sel.ciImage.composited(over: CIImage.color(.black, space.ciCanvas)).cropped(to: space.ciCanvas))
        }
        switch output {
        case .newDocument:
            var st = DocumentState(width: r.width, height: r.height, resolution: d.state.resolution * (Double(r.width) / Double(d.state.width)))
            st.layers = [Layer.raster(name: "Background", buffer: PixelBuffer(cgImage: r))]
            AppModel.shared.add(Document(state: st, name: (d.name as NSString).deletingPathExtension + " – \(name)"))
        case .currentLayer where sameSize:
            if let l = d.state.layer(layerID), l.isRaster, let (w, o) = d.beginPixelEdit(layerID: layerID, target: .content) {
                RenderEngine.render(result, into: w, docOrigin: o, space: space)
                d.commit(name)
            } else {
                fallthrough
            }
        case .newLayer, .currentLayer:
            let buf = RenderEngine.renderBuffer(result, docRect: d.state.canvasRect, space: space)
            d.addLayer(Layer.raster(name: name, buffer: buf), commitName: name)
        case .smartFilter:
            let sid = d.state.layer(layerID)?.isSmartObject == true ? layerID : convertToSmartObject(d, layerID)
            guard let sid, d.state.layer(sid)?.isSmartObject == true else { return }
            var f = FilterInstance(kind: .neuralFilter)
            f.values = settings
            f.payload = RenderEngine.renderBuffer(result, docRect: d.state.canvasRect, space: space)
            d.updateLayer(sid) { l in l.smart?.filters.append(f) }
            d.commit(name)
        }
        d.setNeedsRender()
    }
}

struct NeuralFiltersDialog: View {
    @State private var m: NeuralFiltersModel

    /// `model`: a pre-loaded model (automation / tests); normally created and loaded on appear.
    init(model: NeuralFiltersModel = NeuralFiltersModel()) { _m = State(initialValue: model) }
    @Bindable private var mm = ModelManager.shared
    @Bindable private var trainer = StyleTransfer.Trainer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Neural Filters").font(.system(size: 13, weight: .semibold))
                Spacer()
                if m.busy || m.applying { ProgressView().controlSize(.small) }
                Text(m.status).font(Theme.fontSmall).foregroundStyle(Theme.textDim)
            }
            HStack(alignment: .top, spacing: 12) {
                filterList.frame(width: 210, height: 520)
                settings.frame(width: 270, height: 520)
                previewPane
            }
            HStack {
                Text("Output").foregroundStyle(Theme.textDim)
                Picker("", selection: $m.output) { ForEach(NeuralOutput.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 150)
                    .disabled(m.enabled.contains(where: \.resizes))
                if m.enabled.contains(where: \.resizes) { Text("Super Zoom opens a new document").font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
                if let e = m.error { Text(e).font(Theme.fontSmall).foregroundStyle(.orange).lineLimit(2) }
                Spacer()
                if m.applying { ProgressView(value: m.progress).frame(width: 100) }
                Button("Cancel") { m.task?.cancel(); AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button("OK") { FieldEdits.commit(); m.apply() }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(m.applying || m.enabled.isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(width: 1080)
        .onAppear { m.load() }
    }

    // MARK: List

    var filterList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(NeuralFilterKind.groups, id: \.self) { g in
                    Caption(g).padding(.top, 4)
                    ForEach(NeuralFilterKind.allCases.filter { $0.group == g }) { k in row(k) }
                }
            }
        }
    }

    func row(_ k: NeuralFilterKind) -> some View {
        HStack(spacing: 6) {
            Image(systemName: k.symbol).frame(width: 18).foregroundStyle(Theme.textDim)
            Text(k.title).lineLimit(1)
            Spacer()
            if k.isCloud { Image(systemName: "cloud").foregroundStyle(Theme.textFaint).help("Requires a Generative AI provider") }
            if let id = k.models.first(where: { mm.progress[$0] != nil }), let p = mm.progress[id] {
                ProgressView(value: p).frame(width: 36)
            } else if !m.needsModels(k).isEmpty {
                Image(systemName: "arrow.down.circle").foregroundStyle(Theme.textFaint).help("Downloads its model on first use")
            }
            Toggle("", isOn: Binding(get: { m.enabled.contains(k) }, set: { _ in m.toggle(k) })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(m.selected == k ? Theme.selection : .clear))
        .contentShape(Rectangle())
        .onTapGesture { m.selected = k }
    }

    // MARK: Settings

    var settings: some View {
        let k = m.selected
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(k.title).font(Theme.fontBold)
                Text(k.note).font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
                ForEach(k.models + k.optionalModels, id: \.self) { id in modelRow(id, optional: !k.models.contains(id)) }
                if k == .styleTransfer {
                    let p = StyleTransfer.preset(Int(m.values[k]?["style"] ?? 0))
                    if let img = StyleTransfer.styleImage(p, size: 96) {
                        HStack {
                            Image(decorative: img, scale: 1).resizable().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 4))
                            if let tp = trainer.progress[p.id] { VStack(alignment: .leading) { Text("Training style…").font(Theme.fontSmall); ProgressView(value: tp) } }
                            else if StyleTransfer.isTrained(p.id) { Text("Trained model cached").font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
                        }
                    }
                }
                Divider()
                ForEach(k.params) { p in paramControl(k, p) }
                if k == .smartPortrait && NeuralCloudHook.editPortrait == nil {
                    Text("☁︎ options require a Generative AI provider.").font(Theme.fontSmall).foregroundStyle(.orange)
                }
                if k == .landscapeMixer && NeuralCloudHook.mixLandscape == nil {
                    Text("Requires a Generative AI provider.").font(Theme.fontSmall).foregroundStyle(.orange)
                }
                if k == .colorize {
                    HStack {
                        Text("\(m.hints.count) colour hint(s)").font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                        Button("Clear") { m.hints = []; m.schedule() }.buttonStyle(PanelButtonStyle()).disabled(m.hints.isEmpty)
                    }
                }
                if k == .depthBlur, m.focalPoint != nil {
                    Button("Clear Focal Point") { m.focalPoint = nil; m.schedule() }.buttonStyle(PanelButtonStyle())
                }
                if k == .colorTransfer, m.reference != nil { Text("Custom reference loaded").font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
            }.padding(.trailing, 6)
        }
    }

    func modelRow(_ id: String, optional: Bool) -> some View {
        let spec = mm.spec(id)
        return HStack(spacing: 6) {
            Image(systemName: mm.isInstalled(id) ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(mm.isInstalled(id) ? .green : Theme.textFaint)
            Text((spec?.name ?? id) + (optional ? " (optional)" : "")).font(Theme.fontSmall).lineLimit(1)
            Spacer()
            if let p = mm.progress[id] { ProgressView(value: p).frame(width: 60) }
            else if !mm.isInstalled(id) {
                if spec?.isDownloadable == false {
                    Text("Import from a models pack").font(Theme.fontSmall).foregroundStyle(Theme.textDim).lineLimit(1)
                } else {
                    Button("Get \(spec?.approxMB ?? 0) MB") {
                        Task {
                            do { try await mm.ensure(id) } catch { await MainActor.run { m.error = mm.missingMessage(id) } }
                            await MainActor.run { m.schedule() }
                        }
                    }.buttonStyle(PanelButtonStyle())
                }
            }
        }
        .help(mm.isInstalled(id) ? (spec.map { "\($0.purpose) · \($0.license)" } ?? "") : mm.missingMessage(id))
    }

    @ViewBuilder func paramControl(_ k: NeuralFilterKind, _ p: FilterParam) -> some View {
        let b = Binding(get: { m.values[k]?[p.key] ?? p.defaultValue }, set: { m.values[k, default: k.defaults()][p.key] = $0; m.schedule() })
        switch p.kind {
        case .slider(let r):
            ValueSlider(label: p.label, value: b, range: r, unit: p.unit, labelWidth: 104)
        case .toggle:
            Toggle2(label: p.label, on: Binding(get: { b.wrappedValue > 0.5 }, set: { b.wrappedValue = $0 ? 1 : 0 }))
        case .choice(let opts):
            Picker(p.label, selection: Binding(get: { Int(b.wrappedValue) }, set: { v in
                if k == .colorTransfer && v == opts.count - 1 { pickReference() }
                b.wrappedValue = Double(v)
            })) {
                ForEach(Array(opts.enumerated()), id: \.offset) { i, o in Text(o).tag(i) }
            }
        default:
            EmptyView()
        }
    }

    func pickReference() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        UIBlock.begin(p) { r in
            guard r == .OK, let url = p.url, let cg = NImg.loadCG(url) else { return }
            m.reference = NImg.fitted(cg, maxSide: 1024)
            m.schedule()
        }
    }

    // MARK: Preview

    var previewPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack {
                    CheckerBackground()
                    if let before = m.previewInput {
                        let after = m.previewResult ?? before
                        let size = fitSize(CGSize(width: before.width, height: before.height), in: geo.size)
                        ZStack(alignment: .topLeading) {
                            Image(decorative: m.compare == 1 ? before : after, scale: 1).resizable().frame(width: size.width, height: size.height)
                            if m.compare == 2 {
                                Image(decorative: before, scale: 1).resizable().frame(width: size.width, height: size.height)
                                    .mask(Rectangle().frame(width: size.width * m.split).frame(maxWidth: .infinity, alignment: .leading))
                                Rectangle().fill(Color.white).frame(width: 1.5, height: size.height).offset(x: size.width * m.split)
                            }
                            if let f = m.focalPoint, m.selected == .depthBlur {
                                Circle().stroke(Color.white, lineWidth: 2).frame(width: 18, height: 18).offset(x: f.x * size.width - 9, y: f.y * size.height - 9)
                            }
                            ForEach(Array(m.hints.enumerated()), id: \.offset) { _, h in
                                Circle().fill(Color(cgColor: h.1.cgColor)).overlay(Circle().stroke(.white, lineWidth: 1.5)).frame(width: 12, height: 12)
                                    .offset(x: h.0.x * size.width - 6, y: h.0.y * size.height - 6)
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                            let p = CGPoint(x: min(1, max(0, v.location.x / size.width)), y: min(1, max(0, v.location.y / size.height)))
                            if m.compare == 2 && v.translation.width != 0 { return }
                            if m.selected == .depthBlur { m.focalPoint = p; m.schedule() }
                            else if m.selected == .colorize { m.hints.append((p, AppModel.shared.foreground)); m.schedule() }
                        }.onChanged { v in
                            if m.compare == 2 { m.split = min(1, max(0, v.location.x / size.width)) }
                        })
                    } else {
                        Text("No layer content").foregroundStyle(Theme.textFaint)
                    }
                    if m.busy && m.previewResult == nil && !m.enabled.isEmpty {
                        ProgressView().padding(10).background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelBG.opacity(0.85)))
                    }
                }
            }
            .frame(width: 540, height: 480)
            .clipped()
            HStack {
                Picker("", selection: $m.compare) { Text("After").tag(0); Text("Before").tag(1); Text("Split").tag(2) }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Spacer()
                Text(m.selected == .depthBlur ? "Click to set the focal point" : (m.selected == .colorize ? "Click to add a colour hint" : ""))
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
        }
    }

    func fitSize(_ s: CGSize, in box: CGSize) -> CGSize {
        let k = min(box.width / max(1, s.width), box.height / max(1, s.height))
        return CGSize(width: s.width * k, height: s.height * k)
    }
}
