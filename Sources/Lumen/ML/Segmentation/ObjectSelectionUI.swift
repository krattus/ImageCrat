import SwiftUI
import ImageCratCore

/// "Download model (94 MB)" button with progress, for a registered ModelSpec.
struct ModelDownloadButton: View {
    let id: String
    var label: String? = nil
    @Bindable var mm = ModelManager.shared

    var body: some View {
        if let p = mm.progress[id] {
            HStack(spacing: 4) {
                ProgressView(value: p).frame(width: 60)
                Text("Downloading…").foregroundStyle(Theme.textFaint)
            }
        } else if !mm.isInstalled(id), let s = mm.spec(id) {
            Button(tr(label ?? "Download model (\(s.approxMB) MB)")) {
                Task {
                    do {
                        try await mm.ensure(id)
                        await MainActor.run {
                            AppModel.shared.setStatus("\(s.name) installed.")
                            if let d = AppActions.doc { ObjectSelectionEngine.shared.prepare(d, force: true) }
                        }
                    } catch {
                        await MainActor.run { AppModel.shared.setStatus(error.localizedDescription) }
                    }
                }
            }
            .buttonStyle(PanelButtonStyle(prominent: true))
            .help("\(s.name) — \(s.purpose). \(s.license).")
            if let e = mm.errors[id] { Text(tr(e)).foregroundStyle(.red).lineLimit(1) }
        }
    }
}

/// Options bar of the Object Selection tool.
struct ObjectSelectOptionsBar: View {
    @Bindable var app = AppModel.shared
    @Bindable var s = ObjectSelectionSettings.shared
    @Bindable var mm = ModelManager.shared

    var body: some View {
        CombineModeButtons(mode: $app.selection.combine)
        Picker("Mode", selection: $app.objectSelectMode) { ForEach(ObjectSelectMode.allCases, id: \.self) { Text(tr($0.rawValue)).tag($0) } }
            .frame(width: 140)
        if mm.isInstalled(SegModels.sam2) {
            Toggle2(label: "Object Finder", on: $s.objectFinder)
            IconButton(symbol: "arrow.clockwise", help: "Refresh object detection") {
                if let d = AppActions.doc { ObjectSelectionEngine.shared.prepare(d, force: true) }
            }
            Toggle2(label: "Show All Objects", on: $s.showAllObjects)
        } else {
            ModelDownloadButton(id: SegModels.sam2)
        }
        Toggle2(label: "Sample All Layers", on: $s.sampleAllLayers)
        Toggle2(label: "Hard Edge", on: $s.hardEdge)
        Toggle2(label: "Hair Edges", on: $s.hairEdges)
            .help("Refine hair and fine edges with BiRefNet matting (Preferences ▸ AI Models)")
        if s.hairEdges, !SegMatting.isAvailable { ModelDownloadButton(id: SegModels.birefnetLite, label: "Get matting model (92 MB)") }
        Button("Select Subject") { ObjectSelectionModule.selectSubjectOrExplain(quality: s.subjectQuality) }.buttonStyle(PanelButtonStyle())
        HStack(spacing: 4) {
            Text("Find:").foregroundStyle(Theme.textDim).fixedSize()
            TextField("e.g. sky, red car", text: $s.findText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .onSubmit { ObjectSelectionModule.find(s.findText, mode: app.selection.combine) }
            if !mm.isInstalled(SegModels.florence) && !SAM3Engine.isAvailable {
                ModelDownloadButton(id: SegModels.florence, label: "Get text model (260 MB)")
            }
        }
        Button("Select and Mask…") { AppModel.shared.dialog = .selectAndMask }.buttonStyle(PanelButtonStyle())
        if let b = s.busy {
            ProgressView().controlSize(.small)
            Text(tr(b)).foregroundStyle(Theme.textFaint)
        } else if s.analyzing {
            ProgressView().controlSize(.small)
            Text("Analyzing image…").foregroundStyle(Theme.textFaint)
        } else if s.showAllObjects, let n = s.objectCount {
            Text("\(n) objects").foregroundStyle(Theme.textFaint)
        }
    }
}

/// Select ▸ Select by Description… — text prompt → Florence-2 grounding / SAM 3.1 → masks.
struct SelectByDescriptionDialog: View {
    @Bindable var s = ObjectSelectionSettings.shared
    @State private var prompt = ObjectSelectionSettings.shared.findText
    @State private var matches: [SegmentationService.TextMatch] = []
    @State private var chosen: Set<Int> = []
    @State private var running = false
    @State private var message = ""
    @State private var mode: SelectionCombine = .new
    @State private var showLicenses = false

    var body: some View {
        DialogFrame(title: "Select by Description", width: 420, onOK: apply, onCancel: cleanup) {
            HStack {
                TextField("Describe what to select (e.g. “the red car”, “sky”, “person on the left”)", text: $prompt)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(run)
                Button(tr(running ? "Finding…" : "Find"), action: run).buttonStyle(PanelButtonStyle(prominent: true)).disabled(running || prompt.isEmpty)
            }
            Picker("Engine", selection: $s.textEngine) { ForEach(SegmentationService.TextEngine.allCases) { Text(tr($0.rawValue)).tag($0) } }
            if s.textEngine == .highQuality, let why = SAM3Engine.unavailableReason {
                HStack {
                    Text(tr(why) + tr(" Falls back to Fast.")).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                    if !SegModels.sam3Installed { ModelDownloadButton(id: SegModels.sam3, label: "Get SAM 3.1 (3.3 GB)") }
                }
            }
            if !SegModels.florenceInstalled && !SAM3Engine.isAvailable {
                HStack {
                    Text("Text prompts need Florence-2.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                    ModelDownloadButton(id: SegModels.florence)
                }
            }
            if !SegModels.samInstalled { HStack { Text("Masks need SAM 2.1.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint); ModelDownloadButton(id: SegModels.sam2) } }
            HStack {
                Toggle2(label: "Hair Edges", on: $s.hairEdges)
                Toggle2(label: "Hard Edge", on: $s.hardEdge)
                Spacer()
                Picker("", selection: $mode) {
                    Text("New").tag(SelectionCombine.new); Text("Add").tag(SelectionCombine.add)
                    Text("Subtract").tag(SelectionCombine.subtract); Text("Intersect").tag(SelectionCombine.intersect)
                }.labelsHidden().frame(width: 110)
            }
            if !message.isEmpty { Text(tr(message)).font(Theme.fontSmall).foregroundStyle(Theme.textDim) }
            if !matches.isEmpty {
                Caption("Matches")
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(matches.indices, id: \.self) { i in
                            Toggle(isOn: Binding(get: { chosen.contains(i) }, set: { if $0 { chosen.insert(i) } else { chosen.remove(i) }; preview() })) {
                                Text("\(i + 1). \(tr(matches[i].label)) — \(Int(matches[i].box.width))×\(Int(matches[i].box.height)) px, score \(String(format: "%.2f", matches[i].score))")
                                    .font(Theme.font)
                            }.toggleStyle(.checkbox)
                        }
                    }
                }.frame(maxHeight: 120)
            }
            DisclosureGroup("Licenses", isExpanded: $showLicenses) {
                ScrollView {
                    Text(SAMLicenseText.notices + "\n\n" + SAMLicenseText.text).font(Theme.fontSmall).foregroundStyle(Theme.textDim).textSelection(.enabled)
                }.frame(height: 140)
            }.font(Theme.fontSmall)
        }
        .onDisappear(perform: cleanup)
    }

    private func run() {
        guard let d = AppActions.doc, !prompt.isEmpty else { return }
        s.findText = prompt
        running = true
        message = "Searching…"
        guard let img = ObjectSelectionEngine.shared.prepare(d) else { return }
        let text = prompt, engine = s.textEngine, opts = s.options
        let t0 = CFAbsoluteTimeGetCurrent()
        Task {
            do {
                let m = try await SegmentationService.textMatches(text, in: img, engine: engine, options: opts)
                await MainActor.run {
                    matches = m
                    chosen = Set(m.indices)
                    running = false
                    message = m.isEmpty ? "Nothing matching “\(text)” was found." :
                        String(format: "%d match(es) via %@ in %.1f s.", m.count, SegmentationService.resolvedEngine(engine) == .highQuality ? "SAM 3.1" : "Florence-2 + SAM 2.1", CFAbsoluteTimeGetCurrent() - t0)
                    preview()
                }
            } catch {
                await MainActor.run { running = false; message = error.localizedDescription }
            }
        }
    }

    private var union: PixelBuffer? { SegMask.union(chosen.sorted().map { matches[$0].mask }) }

    private func preview() {
        guard let d = AppActions.doc else { return }
        guard let u = union else { d.displayOverride = nil; d.setNeedsRender(); return }
        let canvas = CGRect(x: 0, y: 0, width: d.state.width, height: d.state.height)
        let tint = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.45)).cropped(to: canvas)
        let m = u.ciImage
        d.displayOverride = { comp in
            tint.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.clearImage.cropped(to: canvas), kCIInputMaskImageKey: m]).composited(over: comp)
        }
        d.setNeedsRender()
    }

    private func cleanup() {
        guard let d = AppActions.doc else { return }
        d.displayOverride = nil
        d.setNeedsRender()
    }

    private func apply() {
        cleanup()
        guard let d = AppActions.doc, let u = union else { return }
        d.setSelection(SelectionOps.combine(d.state.selection, u, mode: mode), commitName: "Select by Description")
    }
}

/// Select and Mask ▸ “Refine Hair”: BiRefNet matting in a band around the selection edge.
struct RefineHairButton: View {
    @Binding var hairMask: PixelBuffer?
    var onChange: () -> Void
    @Bindable var s = ObjectSelectionSettings.shared
    @State private var running = false

    var body: some View {
        HStack(spacing: 6) {
            Button(tr(running ? "Refining…" : "Refine Hair")) {
                running = true
                ObjectSelectionModule.refineHair(mask: AppActions.doc?.state.selection, quality: s.hairQuality) { m in
                    running = false
                    if let m { hairMask = m; onChange() }
                }
            }
            .buttonStyle(PanelButtonStyle())
            .disabled(running || AppActions.doc?.state.selection == nil)
            .help("Refines hair and fine edges of the selection with an on-device matting model (BiRefNet)")
            Picker("", selection: $s.hairQuality) { ForEach(SegMatting.Quality.allCases) { Text(tr($0.rawValue)).tag($0) } }
                .labelsHidden().frame(width: 110)
            if hairMask != nil {
                Button("Reset") { hairMask = nil; onChange() }.buttonStyle(PanelButtonStyle())
            }
        }
        if !SegMatting.isAvailable { ModelDownloadButton(id: SegModels.birefnetLite, label: "Get matting model (92 MB)") }
    }
}
