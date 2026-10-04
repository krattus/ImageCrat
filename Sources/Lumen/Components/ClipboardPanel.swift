import AppKit
import SwiftUI
import ImageCratCore

/// Thumbnail of a history item (image, colour swatch, text snippet or kind icon).
struct ClipThumb: View {
    let item: ClipItem
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.24))
            switch item.kind {
            case .color:
                RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: (item.color ?? .black).nsColor)).padding(5)
            case .text:
                Text(item.text ?? "").font(.system(size: 7)).foregroundStyle(Theme.textDim).lineLimit(5)
                    .multilineTextAlignment(.leading).padding(4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            default:
                if let cg = ClipboardHistory.shared.thumbnail(item) {
                    ZStack {
                        if item.kind != .style && item.kind != .path { CheckerBackground(size: 4).opacity(0.25) }
                        Image(decorative: cg, scale: 2).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    }.padding(3).clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: item.kind.symbol).foregroundStyle(Theme.textFaint)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: item.kind.symbol).font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                .padding(2).background(Circle().fill(Color.black.opacity(0.6))).padding(1)
        }
    }
}

func clipTimeAgo(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 5 { return "now" }
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

@Observable
final class ClipboardPanelState {
    static let shared = ClipboardPanelState()
    var selected: UUID?
    var pinnedOnly = false
}

/// Window ▸ Clipboard History.
struct ClipboardPanel: View {
    @Bindable var history = ClipboardHistory.shared
    @Bindable var ui = ClipboardPanelState.shared
    @Bindable var app = AppModel.shared

    var body: some View {
        let list = history.items.filter { !ui.pinnedOnly || $0.pinned }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("", selection: $ui.pinnedOnly) {
                    Text("All").tag(false)
                    Text("Pinned").tag(true)
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 120)
                Spacer(minLength: 0)
                Menu {
                    Picker("History Size", selection: $history.maxItems) {
                        ForEach([10, 25, 50, 100], id: \.self) { Text("\($0) items").tag($0) }
                    }
                    Toggle("Keep History Between Launches", isOn: $history.persistAll)
                    Toggle("Include Copies from Other Apps", isOn: $history.captureExternal)
                    Divider()
                    Button("Copy Foreground Colour as Hex") { history.copyColor(app.foreground) }
                    Divider()
                    Button("Clear History") { history.clear() }
                    Button("Clear History and Pinned Items") { history.clear(includingPinned: true) }
                } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Pinned items are always kept. Passwords (concealed pasteboard items) and secret-looking text are never recorded.")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 22)).foregroundStyle(Theme.textFaint)
                    Text(ui.pinnedOnly ? "No pinned items" : "Nothing copied yet").font(Theme.fontBold)
                    Text("Layers, selections, text, colours, styles and shapes you copy appear here. ⌃⌘V pastes from the history at the cursor.")
                        .font(Theme.fontSmall).foregroundStyle(Theme.textDim).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(list) { it in
                            ClipRow(item: it, selected: ui.selected == it.id)
                        }
                    }.padding(.horizontal, 4).padding(.bottom, 4)
                }
            }
            Divider().background(Theme.divider)
            HStack(spacing: 2) {
                let sel = ui.selected.flatMap { history.item($0) }
                IconButton(symbol: "plus.square.on.square", help: "Paste as New Layer") { act(.newLayer) }
                IconButton(symbol: "square.on.square.dashed", help: "Paste in Place") { act(.inPlace) }
                IconButton(symbol: "square.inset.filled", help: "Paste Into Selection") { act(.intoSelection) }
                IconButton(symbol: "paintbrush", help: "Paste Style onto the selected layers") { act(.style) }
                Spacer()
                Text("\(history.items.count)/\(history.maxItems)").font(Theme.fontSmall).foregroundStyle(Theme.textFaint).monospacedDigit()
                IconButton(symbol: sel?.pinned == true ? "pin.slash" : "pin", help: "Pin / unpin (pinned items are kept between launches)") {
                    if let id = ui.selected { history.togglePin(id) }
                }
                IconButton(symbol: "trash", help: "Delete the selected item") {
                    if let id = ui.selected { history.remove(id); ui.selected = nil }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
        }
        .font(Theme.font)
        .foregroundStyle(Theme.text)
    }

    func act(_ mode: ClipPasteMode) {
        guard let id = ui.selected, let d = app.activeDocument, let it = history.item(id) else { NSSound.beep(); return }
        guard ClipboardHistory.modes(for: it).contains(mode) || (mode == .newLayer) else { NSSound.beep(); return }
        if !history.paste(id, mode: mode, into: d) { NSSound.beep() }
    }
}

struct ClipRow: View {
    let item: ClipItem
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let history = ClipboardHistory.shared
        HStack(spacing: 8) {
            ClipThumb(item: item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1).truncationMode(.tail)
                Text(item.subtitle).font(Theme.fontSmall).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 3) {
                Button { history.togglePin(item.id) } label: {
                    Image(systemName: item.pinned ? "pin.fill" : "pin").font(.system(size: 10))
                        .foregroundStyle(item.pinned ? Color.orange : Theme.textFaint)
                }.buttonStyle(.plain).opacity(item.pinned || hovering || selected ? 1 : 0).help(item.pinned ? "Unpin" : "Pin")
                Text(clipTimeAgo(item.date)).font(.system(size: 9)).foregroundStyle(Theme.textFaint).monospacedDigit()
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.selection : (hovering ? Theme.hover.opacity(0.5) : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { paste(ClipboardHistory.modes(for: item)[0]) }
        .onTapGesture { ClipboardPanelState.shared.selected = item.id }
        .onDrag {
            ComponentCommands.beginCanvasDrag()
            return NSItemProvider(object: (ClipboardHistory.dragPrefix + item.id.uuidString) as NSString)
        }
        .help("Double-click to paste · drag onto the canvas")
        .contextMenu {
            ForEach(ClipboardHistory.modes(for: item), id: \.self) { m in
                Button(label(m)) { paste(m) }
            }
            if item.kind == .path, let s = item.shape {
                Button("Paste as Work Path") {
                    if let d = AppActions.doc { _ = VectorEditing.newWorkPath(d, s.path); d.commit("Paste Path") }
                }
            }
            Divider()
            Button("Copy Again") { history.copyAgain(item.id) }
            Button(item.pinned ? "Unpin" : "Pin") { history.togglePin(item.id) }
            Button("Delete") { history.remove(item.id) }
        }
    }

    func label(_ m: ClipPasteMode) -> String {
        switch (item.kind, m) {
        case (.color, _): return "Set as Foreground Colour"
        case (.text, _): return "Paste as Text Layer"
        case (.path, _): return "Paste as Shape Layer"
        default: return m.rawValue
        }
    }

    func paste(_ m: ClipPasteMode) {
        guard let d = AppActions.doc else { NSSound.beep(); return }
        if !ClipboardHistory.shared.paste(item.id, mode: m, into: d) { NSSound.beep() }
    }
}

// MARK: - "Paste from History…" popup at the cursor (⌃⌘V)

@Observable
final class ClipboardPopupState {
    var index = 0
    var items: [ClipItem] = []
}

struct ClipboardPopupView: View {
    @Bindable var state: ClipboardPopupState
    var choose: (ClipItem, ClipPasteMode?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Paste from History").font(Theme.fontBold)
                Spacer()
                Text("↑↓ choose · ↩ paste · ⇧↩ in place · 1–9").font(.system(size: 9)).foregroundStyle(Theme.textFaint)
            }.padding(.horizontal, 10).padding(.vertical, 7)
            Divider().background(Theme.divider)
            if state.items.isEmpty {
                Text("The clipboard history is empty.").foregroundStyle(Theme.textDim).padding(16).frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(state.items.enumerated()), id: \.element.id) { i, it in
                                HStack(spacing: 8) {
                                    Text(i < 9 ? "\(i + 1)" : "").font(.system(size: 9, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.textFaint).frame(width: 10)
                                    ClipThumb(item: it, size: 34)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(it.title).lineLimit(1)
                                        Text(it.subtitle).font(Theme.fontSmall).foregroundStyle(Theme.textDim).lineLimit(1)
                                    }
                                    Spacer()
                                    if it.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                                }
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(i == state.index ? Theme.accent.opacity(0.85) : Color.clear))
                                .contentShape(Rectangle())
                                .onTapGesture { choose(it, nil) }
                                .id(it.id)
                            }
                        }.padding(4)
                    }
                    .frame(maxHeight: 330)
                    .onChange(of: state.index) { _, i in if state.items.indices.contains(i) { proxy.scrollTo(state.items[i].id) } }
                }
            }
        }
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panelBG))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(white: 0.32), lineWidth: 0.5))
        .font(Theme.font)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .dark)
    }
}

final class ClipboardPopupPanel: NSPanel {
    var state = ClipboardPopupState()
    var onChoose: ((ClipItem, ClipPasteMode?) -> Void)?
    override var canBecomeKey: Bool { true }

    override func keyDown(with e: NSEvent) {
        let n = state.items.count
        switch e.keyCode {
        case 53: close()                                                            // esc
        case 125: if n > 0 { state.index = (state.index + 1) % n }                   // ↓
        case 126: if n > 0 { state.index = (state.index - 1 + n) % n }               // ↑
        case 36, 76:                                                                // return / enter
            if state.items.indices.contains(state.index) {
                onChoose?(state.items[state.index], e.modifierFlags.contains(.shift) ? .inPlace : nil)
            }
        default:
            if let ch = e.charactersIgnoringModifiers, let k = Int(ch), k >= 1, k <= min(9, n) { onChoose?(state.items[k - 1], nil) } else { NSSound.beep() }
        }
    }

    override func resignKey() {
        super.resignKey()
        close()
    }
}

enum ClipboardPopup {
    private static var panel: ClipboardPopupPanel?

    /// Shows the history list at the mouse cursor; the chosen item is pasted at that point of the canvas.
    static func show() {
        panel?.close()
        let history = ClipboardHistory.shared
        history.poll(external: false)
        let mouse = NSEvent.mouseLocation
        // the doc point under the cursor (if the cursor is over the canvas)
        var docPoint: CGPoint? = nil
        if let cv = AppActions.canvas, let win = cv.window {
            let inWin = win.convertPoint(fromScreen: mouse)
            let local = cv.convert(inWin, from: nil)
            if cv.bounds.contains(local) { docPoint = cv.viewToDoc(local) }
        }
        let p = ClipboardPopupPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 380), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.identifier = NSUserInterfaceItemIdentifier("clipboard-popup")     // keeps KeyRouter's single-key shortcuts out
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.state.items = history.items
        p.onChoose = { [weak p] item, mode in
            p?.close()
            guard let d = AppActions.doc else { NSSound.beep(); return }
            let m = mode ?? ClipboardHistory.modes(for: item)[0]
            let at = (m == .inPlace || item.kind == .style || item.kind == .color) ? nil : docPoint
            if !history.paste(item.id, mode: m, into: d, at: at) { NSSound.beep() }
        }
        let host = NSHostingView(rootView: ClipboardPopupView(state: p.state, choose: { p.onChoose?($0, $1) }))
        p.contentView = host
        let size = host.fittingSize
        var origin = NSPoint(x: mouse.x - 20, y: mouse.y - size.height + 10)
        if let vis = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.visibleFrame {
            origin.x = min(max(vis.minX + 4, origin.x), vis.maxX - size.width - 4)
            origin.y = min(max(vis.minY + 4, origin.y), vis.maxY - size.height - 4)
        }
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        p.isReleasedWhenClosed = false
        p.makeKeyAndOrderFront(nil)
        panel = p
    }
}
