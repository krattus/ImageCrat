import SwiftUI

/// A saved tool + its options (Tool Presets panel / options-bar preset picker).
struct ToolPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var tool: ToolKind
    var payload: Data
}

@Observable
final class ToolPresetStore {
    static let shared = ToolPresetStore()
    var presets: [ToolPreset] { didSet { save() } }
    var currentToolOnly = true
    private let key = "Lumen.ToolPresets"

    private init() {
        presets = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([ToolPreset].self, from: $0) } ?? []
    }

    private func save() {
        if let d = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(d, forKey: key) }
    }

    /// Encodes the options of `tool` from the app model.
    static func capture(_ tool: ToolKind) -> Data? {
        let a = AppModel.shared
        let enc = JSONEncoder()
        switch tool {
        case .brush: return try? enc.encode(a.brush)
        case .pencil: return try? enc.encode(a.pencil)
        case .eraser: return try? enc.encode(a.eraser)
        case .cloneStamp: return try? enc.encode(a.clone)
        case .healing, .spotHealing: return try? enc.encode(a.healing)
        case .removeTool: return try? enc.encode(a.removeBrush)
        case .colorReplacement: return try? enc.encode(a.colorReplaceBrush)
        case .mixerBrush: return try? enc.encode(a.mixerBrushSettings)
        case .blur, .sharpen, .smudge, .dodge, .burn, .sponge: return try? enc.encode(RetouchPresetPayload(brush: a.retouchBrush, retouch: a.retouch))
        case .marqueeRect, .marqueeEllipse, .lasso, .polygonLasso, .magneticLasso, .magicWand, .quickSelect: return try? enc.encode(a.selection)
        case .rectangle, .roundedRect, .ellipse, .polygon, .line, .customShape, .libraryShape: return try? enc.encode(a.shapeTool)
        case .text, .verticalText: return try? enc.encode(a.textTool)
        case .gradient: return try? enc.encode(a.gradientTool)
        default: return nil
        }
    }

    static func apply(_ p: ToolPreset) {
        let a = AppModel.shared
        let dec = JSONDecoder()
        a.tool = p.tool
        switch p.tool {
        case .brush: if let v = try? dec.decode(BrushSettings.self, from: p.payload) { a.brush = v }
        case .pencil: if let v = try? dec.decode(BrushSettings.self, from: p.payload) { a.pencil = v }
        case .eraser: if let v = try? dec.decode(BrushSettings.self, from: p.payload) { a.eraser = v }
        case .cloneStamp: if let v = try? dec.decode(BrushSettings.self, from: p.payload) { a.clone = v }
        case .healing, .spotHealing: if let v = try? dec.decode(BrushSettings.self, from: p.payload) { a.healing = v }
        case .removeTool: if let v = try? dec.decode(BrushSettings.self, from: p.payload) { a.removeBrush = v }
        case .colorReplacement: if let v = try? dec.decode(BrushSettings.self, from: p.payload) { a.colorReplaceBrush = v }
        case .mixerBrush: if let v = try? dec.decode(BrushSettings.self, from: p.payload) { a.mixerBrushSettings = v }
        case .blur, .sharpen, .smudge, .dodge, .burn, .sponge:
            if let v = try? dec.decode(RetouchPresetPayload.self, from: p.payload) { a.retouchBrush = v.brush; a.retouch = v.retouch }
        case .marqueeRect, .marqueeEllipse, .lasso, .polygonLasso, .magneticLasso, .magicWand, .quickSelect:
            if let v = try? dec.decode(SelectionToolSettings.self, from: p.payload) { a.selection = v }
        case .rectangle, .roundedRect, .ellipse, .polygon, .line, .customShape, .libraryShape:
            if let v = try? dec.decode(ShapeToolSettings.self, from: p.payload) { a.shapeTool = v }
        case .text, .verticalText: if let v = try? dec.decode(TextToolSettings.self, from: p.payload) { a.textTool = v }
        case .gradient: if let v = try? dec.decode(GradientToolSettings.self, from: p.payload) { a.gradientTool = v }
        default: break
        }
    }

    func newPreset(name: String? = nil) {
        let tool = AppModel.shared.tool
        guard let data = ToolPresetStore.capture(tool) else { NSSound.beep(); return }
        presets.append(ToolPreset(name: name ?? "\(tool.displayName.replacingOccurrences(of: " Tool", with: "")) \(presets.filter { $0.tool == tool }.count + 1)", tool: tool, payload: data))
    }
}

struct RetouchPresetPayload: Codable {
    var brush: BrushSettings
    var retouch: RetouchSettings
}

struct ToolPresetsPanel: View {
    @Bindable var store = ToolPresetStore.shared
    @Bindable var app = AppModel.shared
    @State private var renaming: UUID?
    @State private var nameText = ""
    @State private var selected: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    let list = store.presets.filter { !store.currentToolOnly || $0.tool == app.tool }
                    if list.isEmpty {
                        Text(store.currentToolOnly ? "No presets for this tool" : "No tool presets").foregroundStyle(Theme.textFaint).padding(12)
                    }
                    ForEach(list) { p in
                        HStack(spacing: 6) {
                            Image(systemName: p.tool.symbol).frame(width: 18)
                            if renaming == p.id {
                                TextField("", text: $nameText).textFieldStyle(.plain).onSubmit {
                                    if let i = store.presets.firstIndex(where: { $0.id == p.id }), !nameText.isEmpty { store.presets[i].name = nameText }
                                    renaming = nil
                                }
                            } else {
                                Text(p.name).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(selected == p.id ? Theme.selection : Color.clear)
                        .contentShape(Rectangle())
                        .gesture(TapGesture(count: 2).onEnded { renaming = p.id; nameText = p.name })
                        .simultaneousGesture(TapGesture().onEnded { selected = p.id; ToolPresetStore.apply(p) })
                    }
                }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 4) {
                Toggle2(label: "Current Tool Only", on: $store.currentToolOnly)
                Spacer()
                IconButton(symbol: "plus.square", help: "Create new tool preset from current options", size: 22) { store.newPreset() }
                IconButton(symbol: "trash", help: "Delete tool preset", size: 22) {
                    store.presets.removeAll { $0.id == selected }
                    selected = nil
                }.disabled(selected == nil)
            }
            .padding(.horizontal, 6).frame(height: 30).background(Theme.panelHeader)
        }
        .font(Theme.font)
    }
}

/// Options-bar preset picker (left end of the options bar, like Photoshop).
struct ToolPresetPicker: View {
    @Bindable var store = ToolPresetStore.shared
    @Bindable var app = AppModel.shared
    var body: some View {
        Menu {
            let list = store.presets.filter { $0.tool == app.tool }
            ForEach(list) { p in Button(p.name) { ToolPresetStore.apply(p) } }
            if !list.isEmpty { Divider() }
            Button("New Tool Preset…") {
                let a = NSAlert()
                a.messageText = "New Tool Preset"
                let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
                f.stringValue = "\(app.tool.displayName.replacingOccurrences(of: " Tool", with: "")) \(list.count + 1)"
                a.accessoryView = f
                a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
                if UIBlock.run(a) == .alertFirstButtonReturn { store.newPreset(name: f.stringValue) }
            }
            .disabled(ToolPresetStore.capture(app.tool) == nil)
        } label: {
            Image(systemName: app.tool.symbol)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Tool presets")
    }
}
