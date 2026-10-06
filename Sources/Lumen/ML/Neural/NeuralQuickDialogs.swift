import SwiftUI
import CoreImage
import ImageCratCore

/// Filter ▸ Noise ▸ AI Denoise…, Filter ▸ Sharpen ▸ AI Sharpen / Deblur…, Image ▸ AI Upscale…
enum NeuralQuickKind: String {
    case denoise, sharpen, upscale
    var title: String {
        switch self {
        case .denoise: return "AI Denoise"
        case .sharpen: return "AI Sharpen"
        case .upscale: return "AI Upscale"
        }
    }
    var model: String {
        switch self {
        case .denoise: return NeuralModelID.nafnetDenoise
        case .sharpen: return NeuralModelID.nafnetDeblur
        case .upscale: return NeuralModelID.esrgan
        }
    }
}

@Observable
final class NeuralQuickModel {
    let kind: NeuralQuickKind
    var strength: Double = 100
    var sharpenMode = 0            // 0 motion (NAFNet), 1 soft focus (Real-ESRGAN restore)
    var factor = 1                 // upscale: 0 ×2, 1 ×4
    var before: CGImage? = nil
    var after: CGImage? = nil
    var busy = false
    var error: String? = nil
    var progress: Double = 0
    @ObservationIgnored var full: CGImage? = nil
    @ObservationIgnored var task: Task<Void, Never>? = nil
    @ObservationIgnored var loaded = false

    init(kind: NeuralQuickKind) { self.kind = kind }

    var modelID: String { kind == .sharpen && sharpenMode == 1 ? NeuralModelID.esrgan : kind.model }

    func load() {
        guard !loaded, let d = AppActions.doc else { return }
        loaded = true
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        let img: CIImage
        if kind == .upscale {
            img = Compositor.shared.composite(d.committedState)
        } else {
            guard let l = d.activeLayer else { return }
            img = Compositor.shared.contentImage(l, space: space) ?? CIImage.clearImage
        }
        full = NImg.cg(img.cropped(to: space.ciCanvas).composited(over: CIImage.clearImage.cropped(to: space.ciCanvas)), rect: space.ciCanvas)
        // preview: 100% crop from the centre
        if let f = full {
            let s = min(kind == .upscale ? 96 : 320, min(f.width, f.height))
            before = f.cropping(to: CGRect(x: (f.width - s) / 2, y: (f.height - s) / 2, width: s, height: s))
        }
        run()
    }

    func process(_ cg: CGImage, progress: ((Double) -> Void)? = nil) async throws -> CGImage {
        switch kind {
        case .denoise: return try await Restoration.run(cg, .denoise, strength: strength / 100, progress: progress)
        case .sharpen:
            return sharpenMode == 0 ? try await Restoration.run(cg, .deblur, strength: strength / 100, progress: progress)
                                    : try await Restoration.restoreViaSR(cg, strength: strength / 100, progress: progress)
        case .upscale: return try await SuperResolution.upscale(cg, factor: factor == 0 ? 2 : 4, progress: progress)
        }
    }

    func run() {
        task?.cancel()
        guard let b = before else { return }
        busy = true; error = nil
        let id = modelID
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try await ModelManager.shared.ensure(id)
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
                let r = try await self.process(b)
                await MainActor.run { self.after = r; self.busy = false }
            } catch is CancellationError {
            } catch {
                await MainActor.run { self.busy = false; self.error = error.localizedDescription }
            }
        }
    }

    @MainActor
    func apply(done: @escaping () -> Void) {
        guard let d = AppActions.doc, let f = full else { return }
        busy = true
        let id = d.activeLayerID
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let t0 = CFAbsoluteTimeGetCurrent()
                let r = try await self.process(f) { p in Task { @MainActor in self.progress = p } }
                let dt = CFAbsoluteTimeGetCurrent() - t0
                await MainActor.run {
                    if self.kind == .upscale {
                        NeuralFiltersModel.write(r, to: d, layerID: id ?? UUID(), output: .newDocument, name: self.kind.title, settings: [:])
                    } else if let id {
                        NeuralFiltersModel.write(r, to: d, layerID: id, output: d.state.layer(id)?.isRaster == true ? .currentLayer : .newLayer,
                                                 name: self.kind.title, settings: [:])
                    }
                    AppModel.shared.setStatus(String(format: "%@ done in %.1f s", self.kind.title, dt))
                    self.busy = false
                    done()
                }
            } catch {
                await MainActor.run { self.busy = false; self.error = error.localizedDescription }
            }
        }
    }
}

struct NeuralQuickDialog: View {
    @State private var m: NeuralQuickModel
    @Bindable private var mm = ModelManager.shared

    init(kind: NeuralQuickKind) { _m = State(initialValue: NeuralQuickModel(kind: kind)) }
    init(model: NeuralQuickModel) { _m = State(initialValue: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr(m.kind.title + (m.kind == .sharpen ? " / Deblur" : ""))).font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                previewBox(m.before, "Before")
                previewBox(m.after, "After")
            }
            if let p = mm.progress[m.modelID] {
                HStack { Text("Downloading \(mm.spec(m.modelID)?.name ?? "model")…").font(Theme.fontSmall); ProgressView(value: p) }
            }
            switch m.kind {
            case .denoise:
                ValueSlider(label: "Strength", value: $m.strength, range: 0...100, unit: "%", onCommit: { m.run() })
            case .sharpen:
                Picker("Blur Type", selection: $m.sharpenMode) { Text("Motion / Shake (NAFNet)").tag(0); Text("Soft Focus (Real-ESRGAN)").tag(1) }
                    .onChange(of: m.sharpenMode) { _, _ in m.run() }
                ValueSlider(label: "Strength", value: $m.strength, range: 0...100, unit: "%", onCommit: { m.run() })
            case .upscale:
                Picker("Scale", selection: $m.factor) { Text("×2").tag(0); Text("×4").tag(1) }.pickerStyle(.segmented)
                Text("Real-ESRGAN (on-device). The result opens as a new document.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
            if let e = m.error { Text(tr(e)).font(Theme.fontSmall).foregroundStyle(.orange) }
            HStack {
                if m.busy { ProgressView(value: m.progress).frame(width: 120) }
                Spacer()
                Button("Cancel") { m.task?.cancel(); AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button("OK") { FieldEdits.commit(); m.apply { AppModel.shared.dialog = nil } }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(m.busy)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(width: 560)
        .onAppear { m.load() }
    }

    func previewBox(_ img: CGImage?, _ label: String) -> some View {
        VStack(spacing: 2) {
            ZStack {
                CheckerBackground()
                if let img { Image(decorative: img, scale: 1).resizable().interpolation(.none).aspectRatio(contentMode: .fit) }
                if img == nil || (label == "After" && m.busy) { ProgressView().controlSize(.small) }
            }.frame(width: 260, height: 260).clipped()
            Text(tr(label)).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
    }
}
