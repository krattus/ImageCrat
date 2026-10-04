import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageCratCore

// MARK: - Shared bits

/// "Automatic" + models whose provider has a key.
struct GenModelPicker: View {
    let feature: GenFeature
    @Binding var selection: String
    @Bindable private var settings = GenAISettings.shared

    var body: some View {
        let _ = settings.keysRevision
        let avail = ProviderRouter.shared.available(for: feature)
        let auto = (try? ProviderRouter.shared.resolve(feature))?.1.name
        Picker("Model", selection: $selection) {
            Text("Automatic" + (auto.map { " (\($0))" } ?? " — no key")).tag("")
            ForEach(avail) { m in Text("\(m.provider.displayName): \(m.name)").tag(m.id) }
        }
        .font(Theme.font)
        if avail.isEmpty && !GenAIKeychain.shared.presenceKnown {
            HStack(spacing: 4) { ProgressView().controlSize(.small); Text("Checking the Keychain for provider keys…") }
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        } else if avail.isEmpty {
            HStack(spacing: 4) {
                Text("No provider key for this feature.").foregroundStyle(.orange)
                Button("Preferences…") { GenAIActions.openPreferences() }.buttonStyle(.link)
            }.font(Theme.fontSmall)
        }
    }
}

struct GenReferencePicker: View {
    @Binding var image: CGImage?
    var body: some View {
        HStack {
            if let i = image {
                Image(decorative: i, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(width: 40, height: 40)
                    .background(Theme.fieldBG)
                Button("Remove") { image = nil }.buttonStyle(PanelButtonStyle())
            } else {
                Button("Reference Image…") {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.image]
                    if UIBlock.run(p) == .OK, let u = p.url, let src = CGImageSourceCreateWithURL(u as CFURL, nil) {
                        image = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1536,
                                                                             kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                    }
                }.buttonStyle(PanelButtonStyle())
                Text("optional").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
        }
    }
}

/// "≈ $0.15 for 3 variations with fal.ai FLUX.1 Pro Fill · $18.30 left" under a generative dialog's model picker.
struct GenCostHint: View {
    let feature: GenFeature
    let model: String
    @Bindable private var settings = GenAISettings.shared
    @Bindable private var usage = GenUsageStore.shared

    static func text(feature: GenFeature, model: String) -> (String, GenBudgetDecision)? {
        let m = model.isEmpty ? (try? ProviderRouter.shared.resolve(feature))?.1 : ProviderRouter.shared.model(model)
        guard let m else { return nil }
        let n = GenBudget.count(for: feature)
        var t = GenBudget.estimateText(m, count: n)
        if let r = GenUsageStore.shared.remaining(for: m.provider) {
            t += " · \(GenMoney.string(r.amount)) left" + (r.kind == .estimated ? " (est.)" : "")
        } else if let b = GenUsageStore.shared.budgetRemaining() {
            t += " · \(GenMoney.string(b)) of budget left"
        }
        return (t, GenBudget.evaluate(estimate: GenBudget.estimate(m, count: n), provider: m.provider, settings: GenAISettings.shared.data, store: GenUsageStore.shared))
    }

    var body: some View {
        let _ = settings.data.variations
        let _ = settings.keysRevision
        let _ = usage.records.count
        if let (t, decision) = Self.text(feature: feature, model: model) {
            Text(t).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            switch decision {
            case .allow: EmptyView()
            case .warn(let msg): Label(msg, systemImage: "exclamationmark.triangle.fill").font(Theme.fontSmall).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            case .block(let msg): Label(msg, systemImage: "xmark.octagon.fill").font(Theme.fontSmall).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Dialogs

enum GenDialogKind: String {
    case fill, generateImage, promptEdit, expand, background, harmonize, upscale, sky, reference
}

struct GenDialog: View {
    let kind: GenDialogKind
    @State private var prompt = ""
    @State private var negative = ""
    @State private var model = ""
    @State private var reference: CGImage?
    @State private var style = "None"
    @State private var content: ContentType = .photo
    @State private var aspect = "1:1"
    @State private var scope = 0
    @State private var left: Double = 0
    @State private var right: Double = 0
    @State private var top: Double = 0
    @State private var bottom: Double = 0
    @State private var light = "above"
    @State private var factor: Double = 2

    init(kind: GenDialogKind) {
        self.kind = kind
        if kind == .fill || kind == .reference, let p = GenAIDialogs.pendingPrompt {
            _prompt = State(initialValue: p)
            GenAIDialogs.pendingPrompt = nil
        }
    }

    static let styles = ["None", "Photographic", "Cinematic", "Digital Art", "Anime", "Fantasy Art", "Line Art", "Comic Book", "3D Model", "Analog Film", "Neon Punk", "Pixel Art", "Isometric", "Low Poly"]

    var feature: GenFeature {
        switch kind {
        case .fill: return reference == nil ? .fill : .referenceFill
        case .reference: return .referenceFill
        case .generateImage: return .generateImage
        case .promptEdit: return .promptEdit
        case .expand: return .expand
        case .background: return .background
        case .harmonize: return .harmonize
        case .upscale: return .upscale
        case .sky: return .sky
        }
    }

    var title: String {
        switch kind {
        case .fill: return "Generative Fill"
        case .reference: return "Generative Fill with Reference Image"
        case .generateImage: return "Generate Image"
        case .promptEdit: return "Edit with Prompt"
        case .expand: return "Generative Expand"
        case .background: return "Generate Background"
        case .harmonize: return "Harmonize"
        case .upscale: return "Generative Upscale"
        case .sky: return "Sky Replacement (Generative)"
        }
    }

    var body: some View {
        DialogFrame(title: title, width: 400, okTitle: "Generate", onOK: run) {
            switch kind {
            case .fill, .reference:
                TextField("Describe what to generate (leave empty to fill with the surroundings)", text: $prompt, axis: .vertical).lineLimit(2...4).genField()
                GenReferencePicker(image: $reference)
                if AppActions.doc?.state.selection == nil { Text("Make a selection first.").foregroundStyle(.orange) }
            case .generateImage:
                TextField("Prompt", text: $prompt, axis: .vertical).lineLimit(2...5).genField()
                TextField("Avoid (negative prompt, where supported)", text: $negative).genField()
                Picker("Content Type", selection: $content) { ForEach(ContentType.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Picker("Style", selection: $style) { ForEach(Self.styles, id: \.self) { Text($0).tag($0) } }
                Picker("Aspect Ratio", selection: $aspect) { ForEach(["1:1", "4:3", "3:4", "3:2", "2:3", "16:9", "9:16", "21:9"], id: \.self) { Text($0).tag($0) } }
                GenReferencePicker(image: $reference)
            case .promptEdit:
                TextField("e.g. make it golden hour, turn the car red", text: $prompt, axis: .vertical).lineLimit(2...4).genField()
                Picker("Apply to", selection: $scope) { Text("Whole Image").tag(0); Text("Active Layer").tag(1); Text("Selection").tag(2) }.pickerStyle(.segmented)
            case .expand:
                HStack { NumberField(label: "Left", value: $left, width: 50); NumberField(label: "Right", value: $right, width: 50) }
                HStack { NumberField(label: "Top", value: $top, width: 50); NumberField(label: "Bottom", value: $bottom, width: 50) }
                TextField("Optional prompt for the new area", text: $prompt).genField()
                Text("Or drag the Crop tool beyond the canvas with “Generative Expand” on.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            case .background:
                TextField("Describe the new background", text: $prompt, axis: .vertical).lineLimit(2...4).genField()
                Text("The subject is found automatically (Select Subject).").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            case .harmonize:
                TextField("Optional guidance (e.g. warm sunset light)", text: $prompt).genField()
                Picker("Light From", selection: $light) { ForEach(["above", "left", "right", "below"], id: \.self) { Text($0.capitalized).tag($0) } }.pickerStyle(.segmented)
                Text("Relights the active layer to match the layers below and adds a contact shadow. The original layer is hidden, not changed.")
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            case .upscale:
                Picker("Scale", selection: $factor) { Text("2×").tag(2.0); Text("4×").tag(4.0) }.pickerStyle(.segmented)
                Picker("Content", selection: $content) { ForEach(ContentType.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Text("Opens the upscaled image as a new document.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            case .sky:
                TextField("Describe the sky (e.g. dramatic sunset clouds)", text: $prompt).genField()
            }
            GenModelPicker(feature: feature, selection: $model)
            GenCostHint(feature: feature, model: model)
        }
    }

    func run() {
        let ov: String? = model.isEmpty ? nil : model
        DispatchQueue.main.async {
            switch kind {
            case .fill, .reference: GenAIActions.generativeFill(prompt: prompt, reference: reference, modelOverride: ov)
            case .generateImage:
                GenPipeline.generateImage(prompt: prompt, negative: negative, style: style == "None" ? nil : style, contentType: content, aspect: aspect, reference: reference, modelOverride: ov)
            case .promptEdit: GenAIActions.promptEdit(prompt: prompt, scope: scope, modelOverride: ov)
            case .expand: GenAIActions.expandCanvas(left: Int(left), right: Int(right), top: Int(top), bottom: Int(bottom), prompt: prompt)
            case .background: GenAIActions.generateBackground(prompt: prompt, modelOverride: ov)
            case .harmonize: GenAIActions.harmonize(prompt: prompt, light: light, modelOverride: ov)
            case .upscale: if let d = AppActions.doc { GenPipeline.enhance(d, feature: .upscale, factor: factor, modelOverride: ov) }
            case .sky: GenAIActions.skyReplacement(prompt: prompt)
            }
        }
    }
}

enum GenAIDialogs {
    static var pendingPrompt: String?
    static func show(_ k: GenDialogKind) { DialogRegistry.show("genai." + k.rawValue) }
    static func register() {
        for k in [GenDialogKind.fill, .generateImage, .promptEdit, .expand, .background, .harmonize, .upscale, .sky, .reference] {
            DialogRegistry.register("genai." + k.rawValue, dims: k != .fill) { AnyView(GenDialog(kind: k)) }
        }
    }
}

// MARK: - Options bar additions

struct GenAIRemoveModeOption: View {
    @Bindable var s = GenAISettings.shared
    var body: some View {
        Picker("Engine", selection: $s.data.removeUsesCloud) {
            Text("On this Mac").tag(false)
            Text("Generative AI (cloud)").tag(true)
        }
        .frame(width: 230)
        .help("Generative AI sends the painted area (plus context) to your Remove provider and adds the result as a new layer.")
    }
}

struct GenAICropExpandOption: View {
    @Bindable var s = GenAISettings.shared
    var body: some View {
        Toggle2(label: "Generative Expand", on: $s.data.cropGenerativeExpand)
            .help("When the crop extends beyond the canvas, fill the new area with generative AI")
        if s.data.cropGenerativeExpand {
            TextField("Prompt (optional)", text: $s.data.cropExpandPrompt).genField().frame(width: 150)
        }
    }
}

/// Hooks called from shared tools (Crop, Remove).
enum GenAIToolHooks {
    /// Remove tool: returns true when the cloud mode handled the stroke.
    static func removeTool(_ d: Document, hole: PixelBuffer) -> Bool {
        guard GenAISettings.shared.data.removeUsesCloud else { return false }
        GenAIActions.remove(d, hole: hole)
        return true
    }

    /// Crop tool: when Generative Expand is on and the crop grows the canvas, returns the follow-up to run after cropping.
    static func cropExpansion(crop r: IRect, canvas c: IRect, doc d: Document) -> (() -> Void)? {
        guard GenAISettings.shared.data.cropGenerativeExpand, r.union(c) != c else { return nil }
        let original = IRect(x: c.x - r.x, y: c.y - r.y, width: c.width, height: c.height)
        let prompt = GenAISettings.shared.data.cropExpandPrompt
        return { GenAIActions.expandAfterCrop(d, originalInNew: original, prompt: prompt) }
    }
}

extension View {
    /// Text field look matching the panels (plain field on the field background).
    func genField() -> some View {
        textFieldStyle(.plain).font(Theme.font).padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 0.5))
    }
}
