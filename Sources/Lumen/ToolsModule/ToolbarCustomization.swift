import AppKit
import SwiftUI
import Observation

// MARK: - Spring-loaded tool shortcuts

/// Holding a tool's shortcut key switches to the tool temporarily; releasing it (after ~0.3 s) returns to the
/// previous tool. A quick tap switches permanently, as in Photoshop.
enum SpringLoadedTools {
    static var holdThreshold: TimeInterval = 0.3
    private static var pending: (key: String, previous: ToolKind, time: TimeInterval)?

    static func isHolding(_ key: String) -> Bool { pending?.key == key }

    static func keyDown(_ e: NSEvent, key: String, previous: ToolKind) {
        guard !e.isARepeat else { return }
        pending = (key, previous, e.timestamp)
    }

    /// Returns true when the key-up restored the previous tool.
    static func keyUp(_ e: NSEvent) -> Bool {
        guard let p = pending, let ch = e.charactersIgnoringModifiers?.lowercased(), ch == p.key else { return false }
        pending = nil
        return release(heldFor: e.timestamp - p.time, previous: p.previous)
    }

    /// Decision helper (also used by the self test).
    @discardableResult
    static func release(heldFor t: TimeInterval, previous: ToolKind) -> Bool {
        let app = AppModel.shared
        guard t > holdThreshold, app.tool != previous else { return false }
        app.tool = previous
        return true
    }

    /// Tools whose shortcut isn't the shortcut of their group's first tool (e.g. Frame = K).
    static func selectLooseTool(_ upper: String) -> Bool {
        let visible = ToolKind.groups.flatMap { $0 } + ToolbarConfig.shared.hiddenTools
        let matches = visible.filter { $0.shortcut == upper }
        guard !matches.isEmpty else { return false }
        let app = AppModel.shared
        if let i = matches.firstIndex(of: app.tool) { app.tool = matches[(i + 1) % matches.count] } else { app.tool = matches[0] }
        return true
    }
}

// MARK: - Toolbar customisation (Edit ▸ Toolbar…)

@Observable
final class ToolbarConfig {
    static let shared = ToolbarConfig()

    struct Saved: Codable, Equatable {
        /// Group keys (raw value of the default group's first tool) in display order.
        var order: [String] = []
        /// Hidden tools (raw values); they appear in the "…" extra tools slot.
        var hidden: [String] = []

        init() {}
        private enum K: String, CodingKey { case order, hidden }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            order = c.tdValue(.order, []); hidden = c.tdValue(.hidden, [])
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            try c.encode(order, forKey: .order); try c.encode(hidden, forKey: .hidden)
        }
    }

    private static let key = "Lumen.Toolbar"

    var saved: Saved = {
        if let d = UserDefaults.standard.data(forKey: ToolbarConfig.key), let s = try? JSONDecoder().decode(Saved.self, from: d) { return s }
        return Saved()
    }() {
        didSet {
            if let d = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(d, forKey: ToolbarConfig.key) }
            cache = nil
            AppModel.shared.groupSelection = [:]
        }
    }

    @ObservationIgnored private var cache: [[ToolKind]]?

    static func groups(_ defaults: [[ToolKind]]) -> [[ToolKind]] { shared.apply(defaults) }

    static func groupKey(_ g: [ToolKind]) -> String { g.first?.rawValue ?? "" }

    /// Default groups ordered by the saved order, with hidden tools removed (empty groups dropped).
    func apply(_ defaults: [[ToolKind]]) -> [[ToolKind]] {
        let s = saved   // observation dependency
        if let c = cache { return c }
        var ordered: [[ToolKind]] = []
        for k in s.order { if let g = defaults.first(where: { ToolbarConfig.groupKey($0) == k }) { ordered.append(g) } }
        for g in defaults where !ordered.contains(where: { ToolbarConfig.groupKey($0) == ToolbarConfig.groupKey(g) }) { ordered.append(g) }
        let hidden = Set(s.hidden)
        let out = ordered.map { $0.filter { !hidden.contains($0.rawValue) } }.filter { !$0.isEmpty }
        cache = out
        return out
    }

    var hiddenTools: [ToolKind] { ToolKind.defaultGroups.flatMap { $0 }.filter { saved.hidden.contains($0.rawValue) } }

    /// Palette separators after the move, eyedropper, dodge and shape groups (Photoshop's sections).
    static func dividerAfter(_ group: [ToolKind]) -> Bool {
        guard let def = ToolKind.defaultGroups.first(where: { g in group.contains { g.contains($0) } }) else { return false }
        return [.move, .eyedropper, .dodge, .rectangle].contains(def[0])
    }

    func reset() { saved = Saved() }
}

/// "…" slot at the bottom of the tools palette listing hidden tools.
struct ExtraToolsSlot: View {
    @Bindable var config = ToolbarConfig.shared
    @Bindable var app = AppModel.shared
    @State private var open = false
    @State private var hover = false

    var body: some View {
        let hidden = config.hiddenTools
        let active = hidden.contains(app.tool)
        Image(systemName: active ? app.tool.symbol : "ellipsis")
            .font(.system(size: 14))
            .frame(width: 32, height: 28)
            .foregroundStyle(active ? Color.white : Theme.text)
            .background(RoundedRectangle(cornerRadius: 5).fill(active ? Theme.toolActive : (hover ? Theme.hover : .clear)))
            .contentShape(Rectangle())
            .onTapGesture { open = true }
            .onHover { hover = $0 }
            .help("Edit Toolbar / extra tools")
            .popover(isPresented: $open, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 1) {
                    if hidden.isEmpty {
                        Text("No extra tools").font(Theme.font).foregroundStyle(Theme.textFaint).padding(6)
                    }
                    ForEach(hidden) { t in
                        ToolFlyoutRow(tool: t, selected: t == app.tool) { app.tool = t; open = false }
                    }
                    Divider().padding(.vertical, 3)
                    Button("Edit Toolbar…") { open = false; DialogRegistry.show("toolbar") }
                        .buttonStyle(.plain).font(Theme.font).padding(.horizontal, 6).padding(.vertical, 3)
                }
                .padding(5)
                .frame(minWidth: 230)
            }
    }
}

struct ToolbarCustomizeDialog: View {
    @State private var order: [[ToolKind]] = ToolbarCustomizeDialog.currentOrder()
    @State private var hidden: Set<String> = Set(ToolbarConfig.shared.saved.hidden)

    static func currentOrder() -> [[ToolKind]] {
        let s = ToolbarConfig.shared.saved
        var ordered: [[ToolKind]] = []
        for k in s.order { if let g = ToolKind.defaultGroups.first(where: { ToolbarConfig.groupKey($0) == k }) { ordered.append(g) } }
        for g in ToolKind.defaultGroups where !ordered.contains(where: { $0 == g }) { ordered.append(g) }
        return ordered
    }

    var body: some View {
        DialogFrame(title: "Customize Toolbar", width: 460, okTitle: "Done", onOK: {
            var s = ToolbarConfig.Saved()
            s.order = order.map(ToolbarConfig.groupKey)
            s.hidden = Array(hidden).sorted()
            ToolbarConfig.shared.saved = s
        }, extraButtons: AnyView(Button("Restore Defaults") {
            order = ToolKind.defaultGroups
            hidden = []
        }.buttonStyle(PanelButtonStyle()))) {
            Text("Uncheck tools to move them to the Extra Tools slot (…). Use the arrows to reorder tool groups.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textDim)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(order.enumerated()), id: \.offset) { gi, group in
                        HStack(alignment: .top, spacing: 6) {
                            VStack(spacing: 2) {
                                IconButton(symbol: "chevron.up", help: "Move Up", size: 18) { move(gi, -1) }.disabled(gi == 0)
                                IconButton(symbol: "chevron.down", help: "Move Down", size: 18) { move(gi, 1) }.disabled(gi == order.count - 1)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(group) { t in
                                    Toggle(isOn: Binding(get: { !hidden.contains(t.rawValue) }, set: { on in
                                        if on { hidden.remove(t.rawValue) } else { hidden.insert(t.rawValue) }
                                    })) {
                                        HStack(spacing: 6) {
                                            Image(systemName: t.symbol).frame(width: 16)
                                            Text(tr(t.displayName))
                                            if !t.shortcut.isEmpty { Text(tr(t.shortcut)).foregroundStyle(Theme.textFaint) }
                                        }.font(Theme.font)
                                    }.toggleStyle(.checkbox)
                                }
                            }
                            Spacer()
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.fieldBG))
                    }
                }
            }
            .frame(height: 380)
        }
    }

    private func move(_ i: Int, _ d: Int) {
        let j = i + d
        guard order.indices.contains(j) else { return }
        order.swapAt(i, j)
    }
}
