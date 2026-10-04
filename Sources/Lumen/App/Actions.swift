import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageCratCore

/// One recorded, replayable command (Actions panel).
enum ActionStep: Codable, Equatable {
    case filter(FilterInstance)
    case adjustment(AdjustmentSettings)
    case adjustmentLayer(AdjustmentKind)
    case imageSize(width: Int, height: Int, resolution: Double, scaleStyles: Bool)
    case imageSizePercent(Double)
    /// `ext`: canvas extension colour as [r, g, b, a]; [] = transparent; nil = recorded before the colour was stored
    /// (replays with the current background colour).
    case canvasSize(width: Int, height: Int, anchorX: Int, anchorY: Int, ext: [Double]? = nil)
    case rotateCanvas(Int)
    case flipCanvas(horizontal: Bool)
    case flatten, mergeVisible, duplicateLayer, newLayer
    case invert, autoLevels(perChannel: Bool), autoColor, equalize, grayscale
    case selectAll, deselect, inverseSelection
    case layerStyle(LayerEffects)
    case colorMode(ColorMode)
    case stop(String)

    var title: String {
        switch self {
        case .filter(let f): return f.kind.displayName
        case .adjustment(let a): return a.kind.displayName
        case .adjustmentLayer(let k): return "Make \(k.displayName) Layer"
        case .imageSize(let w, let h, _, _): return "Image Size \(w)×\(h)"
        case .imageSizePercent(let p): return "Image Size \(Int(p))%"
        case .canvasSize(let w, let h, _, _, _): return "Canvas Size \(w)×\(h)"
        case .rotateCanvas(let d): return "Rotate Canvas \(d)°"
        case .flipCanvas(let h): return h ? "Flip Canvas Horizontal" : "Flip Canvas Vertical"
        case .flatten: return "Flatten Image"
        case .mergeVisible: return "Merge Visible"
        case .duplicateLayer: return "Duplicate Layer"
        case .newLayer: return "Make Layer"
        case .invert: return "Invert"
        case .autoLevels(let pc): return pc ? "Auto Color" : "Auto Tone"
        case .autoColor: return "Auto Color"
        case .equalize: return "Equalize"
        case .grayscale: return "Convert to Grayscale"
        case .selectAll: return "Select All"
        case .deselect: return "Deselect"
        case .inverseSelection: return "Inverse Selection"
        case .layerStyle: return "Set Layer Style"
        case .colorMode(let m): return "Convert Mode: \(m.short)"
        case .stop(let m): return "Stop: \(m)"
        }
    }

    var detail: String? {
        switch self {
        case .filter(let f):
            let v = f.values.sorted { $0.key < $1.key }.prefix(4).map { "\($0.key): \(String(format: "%.3g", $0.value))" }
            return v.isEmpty ? nil : v.joined(separator: ", ")
        default: return nil
        }
    }
}

struct RecordedAction: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var steps: [ActionStep] = []
    var enabled: [Bool] = []
    var shortcut: String? = nil

    func isEnabled(_ i: Int) -> Bool { i < enabled.count ? enabled[i] : true }
}

struct ActionSet: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var actions: [RecordedAction] = []
}

@Observable
final class ActionRecorder {
    static let shared = ActionRecorder()

    var sets: [ActionSet] { didSet { save() } }
    var recordingActionID: UUID?
    var selectedActionID: UUID?
    var playing = false

    private let key = "Lumen.Actions"

    private init() {
        if let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode([ActionSet].self, from: d), !s.isEmpty {
            sets = s
        } else {
            sets = [ActionSet(name: "Default Actions", actions: ActionRecorder.defaults)]
        }
    }

    static let defaults: [RecordedAction] = [
        RecordedAction(name: "Vignette (selection)", steps: [.inverseSelection, .filter(FilterInstance(kind: .gaussianBlur)), .deselect]),
        RecordedAction(name: "Sepia Toning", steps: [.newLayer, .flatten, .grayscale, .adjustment(AdjustmentSettings(kind: .photoFilter))]),
        RecordedAction(name: "Web Size (50%)", steps: [.imageSizePercent(50)]),
        RecordedAction(name: "Auto Fix", steps: [.autoLevels(perChannel: false), .autoColor]),
        RecordedAction(name: "Quadrant Colors", steps: [.duplicateLayer, .invert]),
    ]

    private func save() {
        if let d = try? JSONEncoder().encode(sets) { UserDefaults.standard.set(d, forKey: key) }
    }

    var isRecording: Bool { recordingActionID != nil }

    /// Called by commands as they run; appends to the action being recorded.
    private var suppress = false

    /// Workflow2 (Repeat Last Command, history → action): sees every recordable command, recording or not.
    static var observer: ((ActionStep) -> Void)?

    static func record(_ step: ActionStep) {
        observer?(step)
        let r = shared
        guard let id = r.recordingActionID, !r.playing, !r.suppress else { return }
        // commands invoked by this one (same run-loop turn) are not recorded separately
        r.suppress = true
        DispatchQueue.main.async { r.suppress = false }
        for si in r.sets.indices {
            if let ai = r.sets[si].actions.firstIndex(where: { $0.id == id }) {
                r.sets[si].actions[ai].steps.append(step)
                r.sets[si].actions[ai].enabled.append(true)
            }
        }
    }

    func action(_ id: UUID?) -> RecordedAction? {
        guard let id else { return nil }
        for s in sets { if let a = s.actions.first(where: { $0.id == id }) { return a } }
        return nil
    }

    func update(_ id: UUID, _ f: (inout RecordedAction) -> Void) {
        for si in sets.indices {
            if let ai = sets[si].actions.firstIndex(where: { $0.id == id }) { f(&sets[si].actions[ai]) }
        }
    }

    func newAction(name: String, inSet setID: UUID? = nil) -> UUID {
        let a = RecordedAction(name: name)
        let si = sets.firstIndex { $0.id == setID } ?? 0
        if sets.isEmpty { sets = [ActionSet(name: "Set 1")] }
        sets[si].actions.append(a)
        selectedActionID = a.id
        return a.id
    }

    func delete(_ id: UUID) {
        for si in sets.indices { sets[si].actions.removeAll { $0.id == id } }
    }

    /// Runs an action on the active document. Returns false if it was stopped.
    @discardableResult
    func play(_ id: UUID, fromStep start: Int = 0, interactive: Bool = true) -> Bool {
        guard let a = action(id) else { return false }
        playing = true
        defer { playing = false }
        for (i, step) in a.steps.enumerated() where i >= start && a.isEnabled(i) {
            if case .stop(let msg) = step {
                if !interactive { continue }
                let al = NSAlert()
                al.messageText = msg
                al.addButton(withTitle: "Continue"); al.addButton(withTitle: "Stop")
                if UIBlock.run(al) != .alertFirstButtonReturn { return false }
                continue
            }
            ActionRecorder.perform(step)
        }
        return true
    }

    static func perform(_ step: ActionStep) {
        switch step {
        case .filter(let f): AppActions.applyFilter(f)
        case .adjustment(let a): AppActions.applyAdjustment(a)
        case .adjustmentLayer(let k): AppActions.newAdjustmentLayer(k)
        case .imageSize(let w, let h, let r, let s): AppActions.imageSize(width: w, height: h, resolution: r, scaleStyles: s)
        case .imageSizePercent(let p):
            guard let d = AppActions.doc else { return }
            AppActions.imageSize(width: max(1, Int(Double(d.state.width) * p / 100)), height: max(1, Int(Double(d.state.height) * p / 100)),
                                 resolution: d.state.resolution, scaleStyles: true)
        case .canvasSize(let w, let h, let ax, let ay, let ext):
            var color: RGBA? = AppModel.shared.background
            if let e = ext { color = e.count == 4 ? RGBA(r: e[0], g: e[1], b: e[2], a: e[3]) : nil }
            AppActions.canvasSize(width: w, height: h, anchorX: ax, anchorY: ay, extension: color)
        case .rotateCanvas(let deg): AppActions.rotateCanvas(deg)
        case .flipCanvas(let h): AppActions.flipCanvas(horizontal: h)
        case .flatten: AppActions.flattenImage()
        case .mergeVisible: AppActions.mergeVisible()
        case .duplicateLayer: AppActions.duplicateLayers()
        case .newLayer: AppActions.newLayer()
        case .invert: AppActions.invertActive()
        case .autoLevels(let pc): AppActions.autoLevels(perChannel: pc)
        case .autoColor: AppActions.autoColor()
        case .equalize: AppActions.equalize()
        case .grayscale: AppActions.convertToGrayscale()
        case .selectAll: AppActions.selectAll()
        case .deselect: AppActions.deselect()
        case .inverseSelection: AppActions.inverseSelection()
        case .layerStyle(let fx):
            guard let d = AppActions.doc, let id = d.activeLayerID else { return }
            d.updateLayer(id) { $0.effects = fx }
            d.commit("Set Layer Style")
        case .colorMode(let m): AppActions.convertMode(m)
        case .stop: break
        }
    }

    // MARK: Files

    func exportSet(_ set: ActionSet) {
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: Brand.actionsExtension) ?? .json]
        p.nameFieldStringValue = set.name + "." + Brand.actionsExtension
        guard UIBlock.run(p) == .OK, let url = p.url, let data = try? JSONEncoder().encode(set) else { return }
        try? data.write(to: url)
    }

    func importSet() {
        let p = NSOpenPanel()
        // .icactions, and .lumenactions exported before the rename
        p.allowedContentTypes = Brand.actionsExtensions.sorted().compactMap { UTType(filenameExtension: $0) } + [.json]
        guard UIBlock.run(p) == .OK, let url = p.url, let data = try? Data(contentsOf: url),
              var set = try? JSONDecoder().decode(ActionSet.self, from: data) else { return }
        set.id = UUID()
        sets.append(set)
    }
}

// MARK: - Batch

struct BatchSettings {
    var actionID: UUID?
    var source: URL?
    var destination: URL?
    var includeSubfolders = false
    var format: ExportFormat = .png
    var quality: Double = 0.9
    var suffix = ""
    var overrideStops = true
}

enum BatchRunner {
    static let imageExts: Set<String> = Set(["png", "jpg", "jpeg", "tif", "tiff", "heic", "webp", "gif", "bmp", "psd"]).union(Brand.nativeExtensions)

    static func files(in dir: URL, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        if recursive {
            let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil)
            return (e?.allObjects as? [URL] ?? []).filter { imageExts.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        }
        return ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { imageExts.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
    }

    /// Opens every file, plays the action, exports into `destination`, and closes it. Returns (processed, failed).
    static func run(_ s: BatchSettings, progress: (Int, Int, String) -> Void) -> (Int, Int) {
        guard let aid = s.actionID, let src = s.source, let dst = s.destination else { return (0, 0) }
        let app = AppModel.shared
        let list = files(in: src, recursive: s.includeSubfolders)
        var ok = 0, failed = 0
        let previous = app.activeDocumentID
        for (i, url) in list.enumerated() {
            progress(i, list.count, url.lastPathComponent)
            guard let d = try? DocumentIO.load(url: url) else { failed += 1; continue }
            app.documents.append(d)
            app.activeDocumentID = d.id
            ActionRecorder.shared.play(aid, interactive: !s.overrideStops)
            let name = url.deletingPathExtension().lastPathComponent + s.suffix + "." + s.format.ext
            do {
                try DocumentIO.export(d.state, to: dst.appendingPathComponent(name), format: s.format, quality: s.quality, scale: 1)
                ok += 1
            } catch { failed += 1 }
            app.documents.removeAll { $0.id == d.id }
        }
        app.activeDocumentID = previous ?? app.documents.last?.id
        return (ok, failed)
    }
}

// MARK: - Panel

struct ActionsPanel: View {
    @Bindable var rec = ActionRecorder.shared
    @State private var expanded: Set<UUID> = []
    @State private var renaming: UUID?
    @State private var nameText = ""
    @State private var selectedStep: (UUID, Int)?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rec.sets) { set in
                        HStack(spacing: 4) {
                            Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                            Text(set.name).font(Theme.fontBold)
                            Spacer()
                            Menu {
                                Button("Save Set…") { rec.exportSet(set) }
                                Button("Delete Set") { rec.sets.removeAll { $0.id == set.id } }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                        }
                        .padding(.horizontal, 6).frame(height: 24)
                        ForEach(set.actions) { a in actionRow(a) }
                    }
                }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 4) {
                IconButton(symbol: "stop.fill", help: "Stop recording", size: 22) { rec.recordingActionID = nil }
                    .disabled(!rec.isRecording)
                IconButton(symbol: "record.circle", help: "Begin recording", active: rec.isRecording, size: 22) {
                    if let id = rec.selectedActionID { rec.recordingActionID = id }
                }
                .foregroundStyle(rec.isRecording ? Color.red : Theme.text)
                IconButton(symbol: "play.fill", help: "Play selection", size: 22) {
                    if let id = rec.selectedActionID { rec.play(id, fromStep: selectedStep?.0 == id ? selectedStep!.1 : 0) }
                }
                .disabled(rec.selectedActionID == nil || AppModel.shared.activeDocument == nil)
                Spacer()
                Menu {
                    Button("Batch…") { AppModel.shared.dialog = .batch }
                    Button("Insert Stop…") { insertStop() }.disabled(rec.selectedActionID == nil)
                    Divider()
                    Button("Load Actions…") { rec.importSet() }
                    Button("New Set") { rec.sets.append(ActionSet(name: "Set \(rec.sets.count + 1)")) }
                    Button("Reset Actions") { rec.sets = [ActionSet(name: "Default Actions", actions: ActionRecorder.defaults)] }
                } label: { Image(systemName: "line.3.horizontal") }.menuStyle(.borderlessButton).fixedSize()
                IconButton(symbol: "plus.square", help: "Create new action (starts recording)", size: 22) {
                    let id = rec.newAction(name: "Action \(rec.sets.flatMap(\.actions).count + 1)")
                    rec.recordingActionID = id
                    expanded.insert(id)
                }
                IconButton(symbol: "trash", help: "Delete", size: 22) {
                    if let (aid, si) = selectedStep {
                        rec.update(aid) { a in if si < a.steps.count { a.steps.remove(at: si); if si < a.enabled.count { a.enabled.remove(at: si) } } }
                        selectedStep = nil
                    } else if let id = rec.selectedActionID { rec.delete(id); rec.selectedActionID = nil }
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .background(Theme.panelHeader)
        }
        .font(Theme.font)
    }

    @ViewBuilder func actionRow(_ a: RecordedAction) -> some View {
        let sel = rec.selectedActionID == a.id && selectedStep == nil
        HStack(spacing: 4) {
            Image(systemName: expanded.contains(a.id) ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                .frame(width: 12).onTapGesture { if expanded.contains(a.id) { expanded.remove(a.id) } else { expanded.insert(a.id) } }
            if rec.recordingActionID == a.id { Circle().fill(Color.red).frame(width: 7, height: 7) }
            if renaming == a.id {
                TextField("", text: $nameText).textFieldStyle(.plain).onSubmit {
                    if !nameText.isEmpty { rec.update(a.id) { $0.name = nameText } }
                    renaming = nil
                }
            } else {
                Text(a.name).lineLimit(1)
            }
            Spacer()
            Text("\(a.steps.count)").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
        .padding(.leading, 14).padding(.trailing, 6).frame(height: 22)
        .background(sel ? Theme.selection : Color.clear)
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { renaming = a.id; nameText = a.name })
        .simultaneousGesture(TapGesture().onEnded { rec.selectedActionID = a.id; selectedStep = nil })
        if expanded.contains(a.id) {
            ForEach(Array(a.steps.enumerated()), id: \.offset) { i, step in
                let ssel = selectedStep?.0 == a.id && selectedStep?.1 == i
                HStack(spacing: 4) {
                    Image(systemName: a.isEnabled(i) ? "checkmark.square" : "square").font(.system(size: 10))
                        .onTapGesture {
                            rec.update(a.id) { x in
                                while x.enabled.count < x.steps.count { x.enabled.append(true) }
                                x.enabled[i].toggle()
                            }
                        }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(step.title).lineLimit(1)
                        if let d = step.detail { Text(d).font(Theme.fontSmall).foregroundStyle(Theme.textFaint).lineLimit(1) }
                    }
                    Spacer()
                }
                .padding(.leading, 34).padding(.trailing, 6).padding(.vertical, 2)
                .background(ssel ? Theme.selection : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { rec.selectedActionID = a.id; selectedStep = (a.id, i) }
            }
        }
    }

    func insertStop() {
        guard let id = rec.selectedActionID else { return }
        let al = NSAlert()
        al.messageText = "Record Stop"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        f.placeholderString = "Message"
        al.accessoryView = f
        al.addButton(withTitle: "OK"); al.addButton(withTitle: "Cancel")
        guard UIBlock.run(al) == .alertFirstButtonReturn else { return }
        rec.update(id) { a in
            let at = selectedStep?.0 == id ? selectedStep!.1 + 1 : a.steps.count
            a.steps.insert(.stop(f.stringValue.isEmpty ? "Continue?" : f.stringValue), at: min(at, a.steps.count))
            a.enabled.insert(true, at: min(at, a.enabled.count))
        }
    }
}

struct BatchDialog: View {
    @State private var s = BatchSettings(actionID: ActionRecorder.shared.selectedActionID)
    @State private var running = false
    @State private var progressText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Batch").font(.system(size: 13, weight: .semibold))
            Picker("Action", selection: $s.actionID) {
                ForEach(ActionRecorder.shared.sets.flatMap(\.actions)) { a in Text(a.name).tag(Optional(a.id)) }
            }
            HStack {
                Text("Source").frame(width: 80, alignment: .leading)
                Text(s.source?.path ?? "—").lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.textDim)
                Spacer()
                Button("Choose…") { s.source = chooseFolder() }.buttonStyle(PanelButtonStyle())
            }
            Toggle2(label: "Include All Subfolders", on: $s.includeSubfolders)
            Toggle2(label: "Suppress Stops", on: $s.overrideStops)
            HStack {
                Text("Destination").frame(width: 80, alignment: .leading)
                Text(s.destination?.path ?? "—").lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.textDim)
                Spacer()
                Button("Choose…") { s.destination = chooseFolder() }.buttonStyle(PanelButtonStyle())
            }
            HStack {
                Picker("Format", selection: $s.format) { ForEach(ExportFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 200)
                TextField("File name suffix", text: $s.suffix).frame(width: 120)
            }
            if s.format.supportsQuality { ValueSlider(label: "Quality", value: $s.quality, range: 0.1...1, format: "%.2f", labelWidth: 80) }
            if s.source != nil { Text("\(BatchRunner.files(in: s.source!, recursive: s.includeSubfolders).count) files").foregroundStyle(Theme.textFaint) }
            if !progressText.isEmpty { Text(progressText).foregroundStyle(Theme.textDim) }
            HStack {
                Spacer()
                Button("Cancel") { AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button("OK") { FieldEdits.commit(); run() }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(s.actionID == nil || s.source == nil || s.destination == nil || running)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(width: 440)
    }

    func chooseFolder() -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        return UIBlock.run(p) == .OK ? p.url : nil
    }

    func run() {
        running = true
        let (ok, failed) = BatchRunner.run(s) { i, n, name in progressText = "Processing \(i + 1) of \(n): \(name)" }
        running = false
        AppModel.shared.dialog = nil
        AppModel.shared.setStatus("Batch finished: \(ok) processed" + (failed > 0 ? ", \(failed) failed" : "") + ".")
    }
}
