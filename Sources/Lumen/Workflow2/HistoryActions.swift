import AppKit
import SwiftUI
import Observation
import ImageCratCore

/// Remembers the payload of every recordable command (whether or not an action is being recorded) and which history
/// step it produced. Feeds "Repeat Last Command" and "Create Action from Steps…".
@Observable
final class CommandLog {
    static let shared = CommandLog()

    /// The most recent recordable command run by the user.
    private(set) var lastStep: ActionStep?
    /// History entry id → the command that produced it.
    private(set) var stepsByEntry: [UUID: ActionStep] = [:]
    @ObservationIgnored private var pending: (step: ActionStep, time: TimeInterval)?
    /// True while Workflow2 replays a command itself (so the replay doesn't become "the last command").
    @ObservationIgnored var replaying = false

    /// `ActionRecorder.observer`: commands call this as they start. Nested commands (Invert → Adjustment) keep the outermost.
    func observe(_ step: ActionStep) {
        let now = ProcessInfo.processInfo.systemUptime
        if let p = pending, now - p.time < 0.5 { return }
        pending = (step, now)
        if !replaying, !ActionRecorder.shared.playing { lastStep = step }
        DispatchQueue.main.async { [weak self] in
            if let p = self?.pending, p.time == now { self?.pending = nil }   // the command did not commit anything
        }
    }

    /// `Document.didCommit`: the step just recorded belongs to the pending command.
    func didCommit(_ d: Document) {
        guard let p = pending, d.history.indices.contains(d.historyIndex) else { return }
        pending = nil
        stepsByEntry[d.history[d.historyIndex].id] = p.step
        if stepsByEntry.count > 4000 { stepsByEntry.removeAll() }
    }

    func note(_ step: ActionStep, for entry: UUID) { stepsByEntry[entry] = step }
    func clearPending() { pending = nil }
}

enum HistoryActions {
    /// Result of mapping one history step.
    struct Mapped {
        var index: Int
        var name: String
        var step: ActionStep?
        /// How the step was obtained ("recorded", "inferred") or why it can't be recorded.
        var detail: String
        /// A bookmark in the history (saved version, recovery) — nothing to replay and nothing lost by leaving it out.
        var marker = false
    }

    // MARK: History → ActionStep

    /// Maps the history step at `index` to a replayable `ActionStep`: first the recorded payload, then what can be
    /// inferred exactly from the state change, then parameter-less commands by name.
    static func map(_ d: Document, index: Int) -> Mapped {
        let h = d.history[index]
        if let s = CommandLog.shared.stepsByEntry[h.id] { return Mapped(index: index, name: h.name, step: s, detail: "recorded") }
        guard index > 0 else { return Mapped(index: index, name: h.name, step: nil, detail: "the starting state is not a command", marker: true) }
        if h.name.hasPrefix("Save Version “") || h.name == "Recovered" { return Mapped(index: index, name: h.name, step: nil, detail: "marker — nothing to replay", marker: true) }
        let before = d.history[index - 1].state, after = h.state
        if let s = infer(name: h.name, before: before, after: after) { return Mapped(index: index, name: h.name, step: s, detail: "inferred") }
        return Mapped(index: index, name: h.name, step: nil, detail: reason(h.name))
    }

    static func mapRange(_ d: Document, _ range: ClosedRange<Int>) -> [Mapped] {
        range.clamped(to: 0...max(0, d.history.count - 1)).map { map(d, index: $0) }
    }

    private static func reason(_ name: String) -> String {
        let l = name.lowercased()
        if ["brush", "pencil", "eraser", "stamp", "heal", "smudge", "dodge", "burn", "sponge", "stroke", "paint", "gradient", "bucket"].contains(where: l.contains) {
            return "hand-painted strokes can't be replayed"
        }
        if ["marquee", "lasso", "wand", "selection", "select "].contains(where: l.contains) { return "the selection shape was not recorded" }
        if ["move", "transform", "nudge", "warp", "arrange", "align"].contains(where: l.contains) { return "depends on the layers of this document" }
        if ["type", "text"].contains(where: l.contains) { return "text edits can't be recorded" }
        if FilterKind.allCases.contains(where: { $0.displayName == name }) || AdjustmentKind.allCases.contains(where: { $0.displayName == name }) {
            return "its settings were not captured (run before this session)"
        }
        return "no matching action step"
    }

    static func infer(name: String, before: DocumentState, after: DocumentState) -> ActionStep? {
        switch name {
        case "Flatten Image": return .flatten
        case "Merge Visible": return .mergeVisible
        case "Select All": return .selectAll
        case "Deselect": return .deselect
        case "Inverse": return .inverseSelection
        case "Duplicate Layer": return .duplicateLayer
        case "New Layer": return .newLayer
        case "Invert": return .invert
        case "Auto Tone": return .autoLevels(perChannel: true)
        case "Auto Contrast": return .autoLevels(perChannel: false)
        case "Auto Color": return .autoColor
        case "Equalize": return .equalize
        case "Grayscale": return after.colorMode == .grayscale && before.colorMode != .grayscale ? .colorMode(.grayscale) : .grayscale
        case "Flip Canvas Horizontal": return .flipCanvas(horizontal: true)
        case "Flip Canvas Vertical": return .flipCanvas(horizontal: false)
        case "Image Size":
            return .imageSize(width: after.width, height: after.height, resolution: after.resolution, scaleStyles: true)
        case "Canvas Size":
            // anchor from how far an unchanged layer moved
            let dw = after.width - before.width, dh = after.height - before.height
            var ax = 1, ay = 1
            let pairs = before.allLayers.compactMap { b -> (RasterContent, RasterContent)? in
                guard b.name != "Background", let rb = b.raster, let ra = after.layer(b.id)?.raster else { return nil }
                return (rb, ra)
            }
            if let (rb, ra) = pairs.first {
                if dw != 0 { ax = Int((2 * Double(ra.origin.x - rb.origin.x) / Double(dw)).rounded()) }
                if dh != 0 { ay = Int((2 * Double(ra.origin.y - rb.origin.y) / Double(dh)).rounded()) }
            } else if dw != 0 || dh != 0, let gb = before.guides.first, let ga = after.guides.first(where: { $0.id == gb.id }) {
                if gb.isVertical, dw != 0 { ax = Int((2 * (ga.position - gb.position) / Double(dw)).rounded()) }
                if !gb.isVertical, dh != 0 { ay = Int((2 * (ga.position - gb.position) / Double(dh)).rounded()) }
            } else { return nil }
            guard (0...2).contains(ax), (0...2).contains(ay) else { return nil }
            return .canvasSize(width: after.width, height: after.height, anchorX: ax, anchorY: ay)
        default: break
        }
        if name == "Rotate Canvas", before.width == after.width, before.height == after.height, before.width != before.height { return .rotateCanvas(180) }
        if name.hasPrefix("Convert to "), after.colorMode != before.colorMode { return .colorMode(after.colorMode) }
        // a smart filter was added: the settings are in the layer
        let beforeIDs = Set(before.allLayers.map(\.id))
        for l in after.allLayers {
            if let so = l.smart, let old = before.layer(l.id)?.smart, so.filters.count == old.filters.count + 1, let f = so.filters.last, f.kind.displayName == name {
                return .filter(f)
            }
        }
        // a new adjustment layer
        let added = after.allLayers.filter { !beforeIDs.contains($0.id) }
        if added.count == 1, let a = added[0].adjustment, after.allLayers.count == before.allLayers.count + 1 { return .adjustmentLayer(a.kind) }
        // only the effects of one layer changed
        if name.contains("Layer Style") || name == "Set Layer Style" {
            let changed = after.allLayers.filter { l in before.layer(l.id).map { $0.effects != l.effects } ?? false }
            if changed.count == 1 { return .layerStyle(changed[0].effects) }
        }
        // filters without parameters replay exactly
        if let k = FilterKind.allCases.first(where: { $0.displayName == name }), k.isImmediate { return .filter(FilterInstance(kind: k, colors: [.black, .white])) }
        return nil
    }

    /// Builds an action from a range of history steps. Steps that can't be recorded are returned in `skipped`.
    static func makeAction(name: String, from d: Document, range: ClosedRange<Int>, only: Set<Int>? = nil) -> (action: RecordedAction, skipped: [Mapped]) {
        let mapped = mapRange(d, range).filter { only?.contains($0.index) ?? true }
        let steps = mapped.compactMap(\.step)
        var a = RecordedAction(name: name)
        a.steps = steps
        a.enabled = Array(repeating: true, count: steps.count)
        return (a, mapped.filter { $0.step == nil && !$0.marker })
    }

    /// Adds the action to the Actions panel (first set) and selects it.
    @discardableResult
    static func install(_ a: RecordedAction) -> UUID {
        let rec = ActionRecorder.shared
        if rec.sets.isEmpty { rec.sets = [ActionSet(name: "Set 1")] }
        rec.sets[0].actions.append(a)
        rec.selectedActionID = a.id
        return a.id
    }

    // MARK: Repeat / apply to many

    static var canRepeat: Bool { CommandLog.shared.lastStep != nil && AppActions.doc != nil }

    /// Edit ▸ Repeat Last Command: like "Last Filter", for any recordable command.
    static func repeatLast() {
        guard let s = CommandLog.shared.lastStep, AppActions.doc != nil else { Beep.play(); return }
        AppActions.canvas?.commitCurrentTool()
        CommandLog.shared.clearPending()
        ActionRecorder.perform(s)
        AppModel.shared.setStatus("Repeated “\(s.title)”.")
    }

    /// Commands that act on the active layer (the others are document-wide and make no sense per layer).
    static func isPerLayer(_ s: ActionStep) -> Bool {
        switch s {
        case .filter, .adjustment, .invert, .autoLevels, .autoColor, .equalize, .layerStyle: return true
        default: return false
        }
    }

    /// Whether `step` can run on `layer` without asking to rasterize it.
    static func applies(_ s: ActionStep, to l: Layer) -> Bool {
        if l.locks.pixelsLocked { if case .layerStyle = s {} else { return false } }
        switch s {
        case .layerStyle: return !l.isAdjustment
        case .filter: return l.isRaster || l.isSmartObject
        case .adjustment, .invert, .autoLevels, .autoColor, .equalize: return l.isRaster
        default: return false
        }
    }

    static func sameKind(_ a: Layer, _ b: Layer) -> Bool {
        switch (a.content, b.content) {
        case (.raster, .raster), (.text, .text), (.shape, .shape), (.smartObject, .smartObject), (.fill, .fill), (.group, .group): return true
        case (.adjustment(let x), .adjustment(let y)): return x.kind == y.kind
        default: return false
        }
    }

    /// Runs the last command on each of `ids` and folds the result into ONE history step. Returns (applied, skipped).
    @discardableResult
    static func applyLast(to ids: [UUID], in d: Document) -> (applied: Int, skipped: Int) {
        guard let s = CommandLog.shared.lastStep, isPerLayer(s) else { Beep.play(); return (0, ids.count) }
        AppActions.canvas?.commitCurrentTool()
        let startID = d.history[d.historyIndex].id
        let active = d.activeLayerID, selection = d.selectedLayerIDs, target = d.editTarget
        var applied = 0, skipped = 0
        CommandLog.shared.replaying = true
        defer { CommandLog.shared.replaying = false }
        for id in ids {
            guard let l = d.state.layer(id), applies(s, to: l) else { skipped += 1; continue }
            d.activeLayerID = id
            d.selectedLayerIDs = [id]
            d.editTarget = .content
            let before = d.historyIndex
            CommandLog.shared.clearPending()
            ActionRecorder.perform(s)
            if d.historyIndex > before { applied += 1 } else { skipped += 1 }
        }
        if let a = active, d.state.layer(a) != nil { d.activeLayerID = a }
        d.selectedLayerIDs = selection.filter { d.state.layer($0) != nil }
        d.editTarget = target
        d.validateActiveLayer()
        if let start = d.history.firstIndex(where: { $0.id == startID }), d.historyIndex > start + 1 {
            // fold the per-layer steps into one undo step
            let final = d.history[d.historyIndex].state
            let entry = HistoryEntry(name: "\(s.title) × \(applied) Layers", state: final)
            d.replaceHistoryTail(after: start, with: [entry], select: start + 1)
            CommandLog.shared.clearPending()
            d.activeLayerID = active.flatMap { d.state.layer($0) != nil ? $0 : nil } ?? d.activeLayerID
            d.selectedLayerIDs = selection.filter { d.state.layer($0) != nil }
            d.validateActiveLayer()
        }
        AppModel.shared.setStatus("“\(s.title)” applied to \(applied) layer\(applied == 1 ? "" : "s")" + (skipped > 0 ? ", \(skipped) skipped." : "."))
        return (applied, skipped)
    }

    static func applyLastToSelected() {
        guard let d = AppActions.doc else { return }
        applyLast(to: d.orderedSelection, in: d)
    }

    static func applyLastToSameKind() {
        guard let d = AppActions.doc, let a = d.activeLayer else { Beep.play(); return }
        applyLast(to: d.state.allLayers.filter { sameKind($0, a) && $0.isVisible }.map(\.id), in: d)
    }
}

// MARK: - Create Action from Steps…

struct HistoryActionDialog: View {
    @State private var name = "Action from History"
    @State private var fromPick: Int? = nil
    @State private var toPick: Int? = nil
    @State private var off: Set<Int> = []
    /// Snapshot tests pass a document.
    var docOverride: Document? = nil

    var doc: Document? { docOverride ?? AppActions.doc }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create Action from History Steps").font(.system(size: 13, weight: .semibold))
            if let d = doc {
                let last = max(1, d.history.count - 1)
                let from = Binding(get: { fromPick ?? 1 }, set: { fromPick = $0 })
                let to = Binding(get: { toPick ?? max(1, d.historyIndex) }, set: { toPick = $0 })
                let lo = min(max(1, from.wrappedValue), last), hi = min(max(lo, to.wrappedValue), last)
                let mapped = d.history.count > 1 ? HistoryActions.mapRange(d, lo...hi) : []
                HStack {
                    Text("Name").foregroundStyle(Theme.textDim).frame(width: 44, alignment: .leading)
                    TextField("", text: $name).w2Field()
                }
                HStack(spacing: 8) {
                    Text("Steps").foregroundStyle(Theme.textDim).frame(width: 44, alignment: .leading)
                    Picker("", selection: from) { ForEach(1...last, id: \.self) { i in Text("\(i). \(d.history[i].name)").tag(i) } }.labelsHidden().frame(width: 170)
                    Text("to").foregroundStyle(Theme.textDim)
                    Picker("", selection: to) { ForEach(1...last, id: \.self) { i in Text("\(i). \(d.history[i].name)").tag(i) } }.labelsHidden().frame(width: 170)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(mapped, id: \.index) { m in
                            HStack(spacing: 7) {
                                if m.step != nil {
                                    Image(systemName: off.contains(m.index) ? "square" : "checkmark.square.fill").font(.system(size: 11))
                                        .foregroundStyle(off.contains(m.index) ? Theme.textDim : Theme.accent)
                                        .onTapGesture { if off.contains(m.index) { off.remove(m.index) } else { off.insert(m.index) } }
                                } else if m.marker {
                                    Image(systemName: "bookmark").font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                                } else {
                                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Color.orange)
                                }
                                Text("\(m.index).").font(Theme.mono).foregroundStyle(Theme.textFaint).frame(width: 24, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(m.step?.title ?? m.name).foregroundStyle(m.step == nil ? Theme.textDim : Theme.text).lineLimit(1)
                                    Text(m.marker ? m.detail : (m.step == nil ? "Can't be recorded — \(m.detail)" : (m.step?.detail ?? m.detail)))
                                        .font(Theme.fontSmall).foregroundStyle(m.step == nil && !m.marker ? Color.orange.opacity(0.85) : Theme.textFaint).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                        }
                    }
                }
                .frame(width: 430, height: 210)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.fieldBG))
                let ok = mapped.filter { $0.step != nil && !off.contains($0.index) }.count
                let bad = mapped.filter { $0.step == nil && !$0.marker }.count
                Text("\(ok) step\(ok == 1 ? "" : "s") will be recorded" + (bad > 0 ? " · \(bad) can't be recorded and will be left out" : ""))
                    .font(Theme.fontSmall).foregroundStyle(bad > 0 ? Color.orange : Theme.textFaint)
                HStack {
                    Spacer()
                    Button("Cancel") { AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("Create Action") {
                        let keep = Set(mapped.map(\.index)).subtracting(off)
                        let (a, _) = HistoryActions.makeAction(name: name.isEmpty ? "Action from History" : name, from: d, range: lo...hi, only: keep)
                        HistoryActions.install(a)
                        AppModel.shared.dialog = nil
                        WorkspaceManager.shared.reveal("actions")
                        AppModel.shared.setStatus("Created action “\(a.name)” with \(a.steps.count) step\(a.steps.count == 1 ? "" : "s").")
                    }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(ok == 0)
                }
            } else {
                Text("No document").foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
    }
}
