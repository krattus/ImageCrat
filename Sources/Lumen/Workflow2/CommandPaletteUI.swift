import AppKit
import SwiftUI
import Observation
import ImageCratCore

/// State of the open palette.
@Observable
final class PaletteModel {
    var query = "" { didSet { if query != oldValue { refresh() } } }
    private(set) var results: [PaletteResult] = []
    var selection = 0
    @ObservationIgnored var items: [PaletteItem] = []
    @ObservationIgnored var frecency: PaletteFrecency?
    /// Closes the palette (set by the controller).
    @ObservationIgnored var onClose: () -> Void = {}
    /// Rebuilds the index after a command ran with the palette kept open.
    @ObservationIgnored var rebuild: (() -> [PaletteItem])?

    init(items: [PaletteItem] = [], frecency: PaletteFrecency? = nil) {
        self.items = items
        self.frecency = frecency
        refresh()
    }

    /// Re-runs the search. A new query selects the first runnable result; otherwise the selection is only clamped.
    func refresh(resetSelection: Bool = true) {
        results = PaletteSearch.search(query, items: items, frecency: frecency)
        if resetSelection { selection = results.firstIndex { $0.item.enabled } ?? 0 }
        else { selection = min(selection, max(0, results.count - 1)) }
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(0, selection + delta), results.count - 1)
    }

    var selected: PaletteResult? { results.indices.contains(selection) ? results[selection] : nil }

    /// Runs the selected entry. `keepOpen` (⌘↩) leaves the palette up for the next command.
    /// Returns what happened (tests drive this directly).
    enum Outcome: Equatable { case nothing, inserted, ran(keptOpen: Bool), disabled }

    @discardableResult
    func runSelected(keepOpen: Bool = false) -> Outcome {
        guard let r = selected else { return .nothing }
        if let text = r.item.insertText {
            query = text
            return .inserted
        }
        guard r.item.enabled else { Beep.play(); return .disabled }
        if FilesModule.headless, PaletteIndex.isGenerative(r.item) { return .disabled }     // never from automated runs
        if r.item.category != .calc { frecency?.bump(r.item.id) }
        let action = r.item.run
        if keepOpen {
            action()
            if let rb = rebuild { items = rb() }
            refresh(resetSelection: false)
            return .ran(keptOpen: true)
        }
        onClose()
        // run after the palette is gone so the main window is key again (menu validation, first responder)
        if FilesModule.headless { action() } else { DispatchQueue.main.async(execute: action) }
        return .ran(keptOpen: false)
    }
}

// MARK: - Window

/// Borderless panel that can take the keyboard.
final class PalettePanel: NSPanel {
    var model: PaletteModel?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘↩ = run and keep the palette open
        if event.type == .keyDown, event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            model?.runSelected(keepOpen: true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { model?.onClose() }
}

/// Edit ▸ Command Palette… (⇧⌘P).
final class CommandPalette: NSObject, NSWindowDelegate {
    static let shared = CommandPalette()

    private var panel: PalettePanel?
    private(set) var model: PaletteModel?
    private lazy var frecency = PaletteFrecency()

    var isOpen: Bool { panel != nil }

    func toggle() { if isOpen { close() } else { open() } }

    func open() {
        guard panel == nil else { return }
        if AppModel.shared.dialog != nil { Beep.play(); return }     // a dialog owns the keyboard
        if AppModel.shared.textEditingActive { AppActions.canvas?.commitCurrentTool() }
        let m = PaletteModel(items: PaletteIndex.build(), frecency: frecency)
        m.onClose = { [weak self] in self?.close() }
        m.rebuild = { PaletteIndex.build() }
        let size = CGSize(width: 640, height: 430)
        let p = PalettePanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.identifier = NSUserInterfaceItemIdentifier("lumen.palette")
        p.model = m
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.appearance = NSAppearance(named: .darkAqua)
        p.delegate = self
        p.contentView = NSHostingView(rootView: CommandPaletteView(model: m).environment(\.colorScheme, .dark).l10nRoot())
        let host = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible }
        if let f = host?.frame {
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - max(90, f.height * 0.16)))
        } else { p.center() }
        panel = p
        model = m
        p.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { p.invalidateShadow() }
    }

    func close() {
        guard let p = panel else { return }
        panel = nil
        model = nil
        p.delegate = nil
        p.orderOut(nil)
        (NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey })?.makeKey()
    }

    // clicking elsewhere dismisses it
    func windowDidResignKey(_ notification: Notification) { close() }
}

// MARK: - Search field

/// NSTextField that forwards ↑ ↓ ↩ ⎋ to the palette while it keeps the focus.
struct PaletteField: NSViewRepresentable {
    @Bindable var model: PaletteModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 19, weight: .regular)
        f.textColor = .white
        f.placeholderAttributedString = NSAttributedString(string: "Search commands, tools, layers… or type “opacity 50”",
                                                           attributes: [.foregroundColor: NSColor(white: 1, alpha: 0.32), .font: NSFont.systemFont(ofSize: 19)])
        f.delegate = context.coordinator
        f.cell?.usesSingleLineMode = true
        f.cell?.lineBreakMode = .byTruncatingTail
        DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        if f.stringValue != model.query {
            f.stringValue = model.query
            f.currentEditor()?.selectedRange = NSRange(location: (model.query as NSString).length, length: 0)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: PaletteModel
        init(_ m: PaletteModel) { model = m }

        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSTextField { model.query = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            Coordinator.handle(selector, model: model, commandDown: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
        }

        /// Key commands of the search field (static so the self test can drive it).
        static func handle(_ selector: Selector, model: PaletteModel, commandDown: Bool) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): model.move(-1); return true
            case #selector(NSResponder.moveDown(_:)): model.move(1); return true
            case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): model.move(-8); return true
            case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): model.move(8); return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                model.runSelected(keepOpen: commandDown)
                return true
            case #selector(NSResponder.insertTab(_:)):
                if let r = model.selected, let t = r.item.insertText { model.query = t }
                return true
            case #selector(NSResponder.cancelOperation(_:)): model.onClose(); return true
            default: return false
            }
        }
    }
}

// MARK: - View

struct CommandPaletteView: View {
    @Bindable var model: PaletteModel
    /// Snapshot tests use a plain text line instead of the AppKit field.
    var staticField = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(Color(white: 0.6))
                if staticField {
                    Text(tr(model.query.isEmpty ? "Search commands, tools, layers… or type “opacity 50”" : model.query))
                        .font(.system(size: 19)).foregroundStyle(model.query.isEmpty ? Color(white: 1, opacity: 0.32) : .white).lineLimit(1)
                    Spacer()
                } else {
                    PaletteField(model: model).frame(height: 26)
                }
                Text("⇧⌘P").font(.system(size: 10, weight: .medium)).foregroundStyle(Color(white: 0.5))
                    .padding(.horizontal, 5).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
            }
            .padding(.horizontal, 16).frame(height: 52)
            Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { i, r in
                            PaletteRow(result: r, selected: i == model.selection)
                                .id(r.id)
                                .contentShape(Rectangle())
                                .onTapGesture { model.selection = i; model.runSelected(keepOpen: NSEvent.modifierFlags.contains(.command)) }
                        }
                        if model.results.isEmpty {
                            Text("No matching commands").font(.system(size: 12)).foregroundStyle(Color(white: 0.5)).padding(.vertical, 28)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selection) { _, s in
                    if model.results.indices.contains(s) { proxy.scrollTo(model.results[s].id) }
                }
            }
            Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1)
            HStack(spacing: 14) {
                hint("↑↓", "navigate"); hint("↩", "run"); hint("⌘↩", "run & keep open"); hint("⇥", "complete"); hint("esc", "close")
                Spacer()
                Text("\(model.results.count) result\(model.results.count == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(Color(white: 0.45))
            }
            .padding(.horizontal, 14).frame(height: 26)
        }
        .frame(width: 640, height: 430)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.12, green: 0.125, blue: 0.14).opacity(0.98)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.14), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(tr(key)).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(white: 0.75))
                .padding(.horizontal, 4).padding(.vertical, 1).background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.1)))
            Text(tr(text)).font(.system(size: 10)).foregroundStyle(Color(white: 0.5))
        }
    }
}

struct PaletteRow: View {
    let result: PaletteResult
    let selected: Bool

    var body: some View {
        let it = result.item
        HStack(spacing: 10) {
            Image(systemName: it.symbol ?? it.category.symbol).font(.system(size: 12))
                .foregroundStyle(it.enabled ? (selected ? Color.white : Color(white: 0.7)) : Color(white: 0.35))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                highlighted(it.title, result.matched, enabled: it.enabled).font(.system(size: 13)).lineLimit(1)
                if !it.subtitle.isEmpty {
                    Text(tr(it.subtitle)).font(.system(size: 10)).foregroundStyle(selected && it.enabled ? Color(white: 1, opacity: 0.78) : Color(white: it.enabled ? 0.52 : 0.33)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !it.enabled { Text("unavailable").font(.system(size: 9)).foregroundStyle(Color(white: 0.4)) }
            if !it.shortcut.isEmpty {
                Text(tr(it.shortcut)).font(.system(size: 11, weight: .medium)).foregroundStyle(selected && it.enabled ? Color.white : Color(white: it.enabled ? 0.72 : 0.38))
                    .padding(.horizontal, 6).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(selected ? 0.18 : 0.08)))
            }
            Text(tr(it.category.rawValue)).font(.system(size: 9, weight: .medium)).foregroundStyle(selected && it.enabled ? Color(white: 1, opacity: 0.75) : Color(white: 0.45))
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.horizontal, 10).frame(height: it.subtitle.isEmpty ? 30 : 38)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.accent.opacity(it.enabled ? 0.85 : 0.3) : Color.clear))
    }

    func highlighted(_ s: String, _ positions: [Int], enabled: Bool) -> Text {
        let base = enabled ? Color(white: 0.9) : Color(white: 0.42)
        guard !positions.isEmpty else { return Text(tr(s)).foregroundColor(base) }
        let set = Set(positions)
        var out = Text("")
        var run = "", runHit = false
        for (i, ch) in s.enumerated() {
            let hit = set.contains(i)
            if hit != runHit, !run.isEmpty {
                out = out + (runHit ? Text(run).foregroundColor(enabled ? .white : base).fontWeight(.bold) : Text(run).foregroundColor(base))
                run = ""
            }
            runHit = hit
            run.append(ch)
        }
        if !run.isEmpty { out = out + (runHit ? Text(run).foregroundColor(enabled ? .white : base).fontWeight(.bold) : Text(run).foregroundColor(base)) }
        return out
    }
}
