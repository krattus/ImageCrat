import SwiftUI
import AppKit
import ImageCratCore

// MARK: - Commands

/// Every zoom command: the View menu, the status-bar preset menu, the command palette and the shortcuts run these.
enum ZoomCommand: String, CaseIterable, Identifiable {
    case zoomIn, zoomOut, fitOnScreen, fillScreen, fitWidth, fitHeight, fitArtboard, actualPixels, zoom200, printSize, devicePixels
    case zoomToSelection, zoomToLayer, resetRotation
    var id: String { rawValue }

    var title: String {
        switch self {
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .fitOnScreen: return "Fit on Screen"
        case .fillScreen: return "Fill Screen"
        case .fitWidth: return "Fit Width"
        case .fitHeight: return "Fit Height"
        case .fitArtboard: return "Fit Artboard on Screen"
        case .actualPixels: return "100%"
        case .zoom200: return "200%"
        case .printSize: return "Print Size"
        case .devicePixels: return "Device Pixels (\(ZoomMath.format(ZoomController.devicePixelZoom)))"
        case .zoomToSelection: return "Zoom to Selection"
        case .zoomToLayer: return "Zoom to Layer"
        case .resetRotation: return "Reset View Rotation"
        }
    }

    /// Menu shortcuts (⌘+ / keypad and ⌥⌘0 are extra keys handled by `ZoomController.handleKey`).
    var shortcut: (key: KeyEquivalent, modifiers: EventModifiers)? {
        switch self {
        case .zoomIn: return ("=", .command)
        case .zoomOut: return ("-", .command)
        case .fitOnScreen: return ("0", .command)
        case .actualPixels: return ("1", .command)
        default: return nil
        }
    }

    /// View menu order; nil entries are dividers. (Device Pixels only shows in the status-bar menu, on Retina screens.)
    static let viewMenu: [ZoomCommand?] = [.zoomIn, .zoomOut, nil, .fitOnScreen, .fillScreen, .fitWidth, .fitHeight, .fitArtboard, nil,
                                           .actualPixels, .zoom200, .printSize, nil, .zoomToSelection, .zoomToLayer, .resetRotation]
}

enum ZoomController {
    static var canvas: CanvasView? { AppActions.canvas }
    static var doc: Document? { canvas?.document }

    /// Zoom at which one document pixel covers one device pixel of the canvas's screen.
    static var devicePixelZoom: Double { 1 / Double(canvas?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1) }

    static func activeArtboard(_ d: Document) -> Layer? {
        var id = d.activeLayerID
        while let i = id {
            if let l = d.state.layer(i), l.isArtboard { return l }
            id = d.state.parentID(of: i)
        }
        return nil
    }

    /// Doc-space bounds of the selected layers' content (an artboard: its rectangle).
    static func selectedLayersBounds(_ d: Document) -> CGRect? {
        let ids = d.withoutDescendants(d.orderedSelection.isEmpty ? (d.activeLayerID.map { [$0] } ?? []) : d.orderedSelection)
        var u: CGRect?
        for id in ids {
            guard let l = d.state.layer(id), let b = Compositor.shared.contentBounds(l, state: d.state), !b.isNull, b.width > 0, b.height > 0 else { continue }
            u = u.map { $0.union(b) } ?? b
        }
        return u
    }

    static func isEnabled(_ c: ZoomCommand) -> Bool {
        guard let d = doc else { return false }
        switch c {
        case .fitArtboard: return activeArtboard(d) != nil
        case .zoomToSelection: return d.state.selection != nil
        case .zoomToLayer: return !d.selectedLayerIDs.isEmpty || d.activeLayerID != nil
        case .resetRotation: return abs(d.viewRotation) > 1e-9
        case .zoomIn: return d.zoom < ZoomMath.maxZoom * 0.999
        case .zoomOut: return d.zoom > ZoomMath.minZoom * 1.001
        default: return true
        }
    }

    /// Runs a zoom command on the active canvas (preset jumps animate unless `animated` is false).
    static func run(_ cmd: ZoomCommand, animated: Bool = true) {
        guard let c = canvas, let d = c.document else { return }
        ZoomAnimator.finish()
        switch cmd {
        case .zoomIn: c.zoom(to: ZoomMath.stepIn(d.zoom), animated: animated)
        case .zoomOut: c.zoom(to: ZoomMath.stepOut(d.zoom), animated: animated)
        case .fitOnScreen: c.fitOnScreen(animated: animated)
        case .fillScreen: c.fit(c.fitTarget(d), mode: .fill, animated: animated)
        case .fitWidth: c.fit(c.fitTarget(d), mode: .width, animated: animated)
        case .fitHeight: c.fit(c.fitTarget(d), mode: .height, animated: animated)
        case .fitArtboard:
            guard let r = activeArtboard(d)?.artboard?.rect else { return refuse("Select an artboard (or a layer in one) first.") }
            c.fit(r, animated: animated)
        case .actualPixels: c.zoom(to: 1, animated: animated)
        case .zoom200: c.zoom(to: 2, animated: animated)
        case .printSize: c.zoom(to: ZoomMath.printSizeZoom(resolution: d.state.resolution, screenPPI: ZoomMath.screenPointsPerInch(c.window?.screen)), animated: animated)
        case .devicePixels: c.zoom(to: devicePixelZoom, animated: animated)
        case .zoomToSelection:
            guard let b = d.state.selectionBounds, b.width > 0, b.height > 0 else { return refuse("There is no selection to zoom to.") }
            c.fit(b.cgRect, animated: animated)
        case .zoomToLayer:
            guard let b = selectedLayersBounds(d) else { return refuse("The selected layers have no visible content.") }
            c.fit(b, animated: animated)
        case .resetRotation: c.setRotation(0)
        }
    }

    private static func refuse(_ msg: String) {
        AppModel.shared.statusMessage = msg
        Beep.play()
    }

    /// A ladder entry or any zoom, about the view centre.
    static func zoom(to z: Double, animated: Bool = true) {
        canvas?.zoom(to: z, animated: animated)
    }

    /// Applies text typed into the zoom field. False (nothing changes) when it doesn't parse.
    @discardableResult
    static func apply(text: String, animated: Bool = true) -> Bool {
        guard let input = ZoomMath.parse(text), let c = canvas, c.document != nil else { return false }
        switch input {
        case .zoom(let z): c.zoom(to: z, animated: animated)
        case .fit: run(.fitOnScreen, animated: animated)
        case .fill: run(.fillScreen, animated: animated)
        }
        return true
    }

    /// Scrubby zoom: each point dragged right zooms in by 2^(1/100) (⇧: 4× faster), about the view centre.
    static func scrub(by dx: CGFloat, fast: Bool) {
        guard let c = canvas, let d = c.document, dx != 0 else { return }
        c.setZoom(d.zoom * pow(2, Double(dx) / (fast ? 25 : 100)))
    }

    /// Slider position (0…1, logarithmic over the allowed range).
    static func sliderFraction(_ z: Double) -> Double {
        (log(ZoomMath.clamp(z)) - log(ZoomMath.minZoom)) / (log(ZoomMath.maxZoom) - log(ZoomMath.minZoom))
    }
    static func zoom(forSlider t: Double) -> Double {
        ZoomMath.clamp(exp(log(ZoomMath.minZoom) + min(max(t, 0), 1) * (log(ZoomMath.maxZoom) - log(ZoomMath.minZoom))))
    }

    /// Double-click on a tool button: Hand → Fit on Screen, Zoom → 100% (as in Photoshop).
    static func toolDoubleClicked(_ k: ToolKind) {
        switch k {
        case .hand: run(.fitOnScreen)
        case .zoom: run(.actualPixels)
        default: break
        }
    }

    /// Zoom keys the menu bar can't carry a second time: ⌘+ (⇧⌘=), keypad ⌘+ / ⌘−, and ⌥⌘0 (100%, Photoshop's older key).
    static func handleKey(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown, canvas?.document != nil else { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let ch = e.charactersIgnoringModifiers ?? ""
        if mods == [.command, .option] && (e.keyCode == 29 || e.keyCode == 82) { run(.actualPixels); return true }   // ⌥⌘0 (row / keypad)
        guard mods.subtracting(.shift) == [.command] else { return false }
        if ch == "+" || e.keyCode == 69 || (e.keyCode == 24 && mods.contains(.shift)) { run(.zoomIn); return true }   // ⌘+, keypad +
        if e.keyCode == 78 { run(.zoomOut); return true }                                                            // keypad −
        return false
    }

    // MARK: Preset menu

    final class MenuTarget: NSObject {
        static let shared = MenuTarget()
        @objc func runItem(_ item: NSMenuItem) { (item.representedObject as? () -> Void)?() }
    }

    /// The status bar's preset menu for the current view.
    static func presetMenu() -> NSMenu {
        let m = NSMenu(title: "Zoom")
        m.autoenablesItems = false
        func add(_ title: String, key: String = "", mods: NSEvent.ModifierFlags = .command, enabled: Bool = true, checked: Bool = false, _ action: @escaping () -> Void) {
            let it = NSMenuItem(title: title, action: #selector(MenuTarget.runItem(_:)), keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = MenuTarget.shared
            it.representedObject = action
            it.isEnabled = enabled
            it.state = checked ? .on : .off
            m.addItem(it)
        }
        func add(_ c: ZoomCommand, title: String? = nil) {
            add(title ?? c.title, key: c.shortcut.map { String($0.key.character) } ?? "", enabled: isEnabled(c)) { run(c) }
        }
        let d = doc
        add(.fitOnScreen); add(.fillScreen); add(.fitWidth); add(.fitHeight)
        if let d, !AppActions.artboards(d).isEmpty { add(.fitArtboard) }
        m.addItem(.separator())
        add(.actualPixels, title: "100% (Actual Pixels)"); add(.zoom200); add(.printSize)
        if devicePixelZoom < 0.999 { add(.devicePixels) }
        m.addItem(.separator())
        add(.zoomToSelection); add(.zoomToLayer)
        m.addItem(.separator())
        let z = d?.zoom ?? 0
        for (label, v) in ZoomMath.ladder {
            add(label, checked: abs(z / v - 1) < 0.005) { zoom(to: v) }
        }
        if let d, abs(d.viewRotation) > 1e-9 {
            m.addItem(.separator())
            add(.resetRotation, title: "Reset View Rotation (\(Int((d.viewRotation * 180 / .pi).rounded()))°)")
        }
        return m
    }

    /// Opens the preset menu under the mouse (or the window centre when pressed through accessibility).
    static func popUpPresetMenu() {
        if FilesModule.headless || Automation.isProcessWide { return }   // a pop-up menu's tracking loop would stall automation
        let w = NSApp.currentEvent?.window ?? NSApp.keyWindow
        guard let v = w?.contentView else { return }
        let p: NSPoint
        if let e = NSApp.currentEvent, e.window === w, e.type == .leftMouseUp || e.type == .leftMouseDown {
            p = v.convert(e.locationInWindow, from: nil)
        } else {
            p = NSPoint(x: v.bounds.midX, y: v.bounds.midY)
        }
        presetMenu().popUp(positioning: nil, at: p, in: v)
    }

    /// Palette entries for the zoom commands (same ids as the View menu items, so the two de-duplicate).
    static func paletteItems() -> [PaletteItem] {
        ZoomCommand.viewMenu.compactMap { $0 }.map { c in
            PaletteItem(id: "menu:View ▸ " + c.title, title: c.title, subtitle: "View", category: .menu,
                        shortcut: c.shortcut.map { PaletteIndex.shortcutString($0.key, $0.modifiers) } ?? "", enabled: isEnabled(c),
                        keywords: "zoom magnify view", run: { run(c) })
        }
    }
}

// MARK: - Field

/// The zoom percentage: shows the live zoom; click to type (Return applies, Esc cancels, focus goes back to the canvas);
/// drag sideways to scrub.
final class ZoomTextField: NSTextField, NSTextFieldDelegate {
    private enum Ending { case none, committed, cancelled }
    private var ending = Ending.none
    private var scrubX: CGFloat?
    private var scrubbing = false
    /// Editing began / ended (drives the control's focus ring).
    var onEditingChanged: (Bool) -> Void = { _ in }
    var zoom: Double = 1 { didSet { if currentEditor() == nil { stringValue = ZoomMath.format(zoom) } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        alignment = .center
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        textColor = NSColor(Theme.text)
        usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        lineBreakMode = .byClipping
        delegate = self
        toolTip = "Zoom — type a value (150, 33.3, 1:2, fit, fill) and press Return; drag sideways to scrub (⇧ faster)"
        setAccessibilityLabel("Zoom")
        stringValue = ZoomMath.format(zoom)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if currentEditor() == nil { addCursorRect(bounds, cursor: .resizeLeftRight) } else { super.resetCursorRects() }
    }

    // Scrubby label: a press that moves sideways scrubs; one that doesn't starts editing on release.
    override func mouseDown(with event: NSEvent) {
        guard currentEditor() == nil else { return super.mouseDown(with: event) }
        scrubX = event.locationInWindow.x
        scrubbing = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let x0 = scrubX else { return super.mouseDragged(with: event) }
        let dx = event.locationInWindow.x - x0
        if !scrubbing && abs(dx) < 3 { return }
        scrubbing = true
        NSCursor.resizeLeftRight.set()
        ZoomController.scrub(by: dx, fast: event.modifierFlags.contains(.shift))
        scrubX = event.locationInWindow.x
    }
    override func mouseUp(with event: NSEvent) {
        guard scrubX != nil else { return super.mouseUp(with: event) }
        let wasScrubbing = scrubbing
        scrubX = nil; scrubbing = false
        if !wasScrubbing { beginEditing() }
    }

    func beginEditing() {
        guard let w = window else { return }
        w.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    var isEditing: Bool { currentEditor() != nil }

    func controlTextDidBeginEditing(_ obj: Notification) {
        ending = .none
        window?.invalidateCursorRects(for: self)
        onEditingChanged(true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            commit(textView.string); return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel(); return true
        default: return false
        }
    }

    /// Focus left the field another way (a click on the canvas, Tab): a valid value still applies.
    func controlTextDidEndEditing(_ obj: Notification) {
        if ending == .none, stringValue != ZoomMath.format(zoom) { ZoomController.apply(text: stringValue) }
        ending = .none
        stringValue = ZoomMath.format(ZoomController.doc?.zoom ?? zoom)
        window?.invalidateCursorRects(for: self)
        onEditingChanged(false)
    }

    func commit(_ text: String) {
        ending = .committed
        ZoomController.apply(text: text)      // invalid text: nothing happens and the field reverts
        returnFocus()
    }

    func cancel() {
        ending = .cancelled
        abortEditing()
        returnFocus()
        stringValue = ZoomMath.format(ZoomController.doc?.zoom ?? zoom)
        onEditingChanged(false)
    }

    /// Back to the canvas so single-key tool shortcuts work again.
    private func returnFocus() {
        guard let w = window else { return }
        if let c = AppActions.canvas, c.window === w { w.makeFirstResponder(c) } else { w.makeFirstResponder(nil) }
        stringValue = ZoomMath.format(ZoomController.doc?.zoom ?? zoom)
    }
}

struct ZoomField: NSViewRepresentable {
    let zoom: Double
    @Binding var editing: Bool

    func makeNSView(context: Context) -> ZoomTextField {
        let f = ZoomTextField(frame: NSRect(x: 0, y: 0, width: 48, height: 16))
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    func updateNSView(_ f: ZoomTextField, context: Context) {
        f.onEditingChanged = { e in DispatchQueue.main.async { if editing != e { editing = e } } }
        f.textColor = NSColor(Theme.text)
        f.zoom = zoom
    }
}

// MARK: - Control

/// Status-bar zoom control: − [ 100% ⌄ ] +, a logarithmic slider, and a rotation chip while the view is rotated.
struct ZoomControl: View {
    let doc: Document
    var showSlider = true
    @State private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                ZoomStepButton(symbol: "minus", help: "Zoom Out (⌘−)", enabled: doc.zoom > ZoomMath.minZoom * 1.001) { ZoomController.run(.zoomOut) }
                Rectangle().fill(Theme.border).frame(width: 1, height: 12)
                ZoomField(zoom: doc.zoom, editing: $editing)
                    .frame(width: 44, height: 15)
                    .padding(.leading, 3)
                ZoomMenuButton()
                Rectangle().fill(Theme.border).frame(width: 1, height: 12)
                ZoomStepButton(symbol: "plus", help: "Zoom In (⌘+)", enabled: doc.zoom < ZoomMath.maxZoom * 0.999) { ZoomController.run(.zoomIn) }
            }
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(editing ? Theme.accent : Theme.border, lineWidth: 1))
            if showSlider { ZoomSlider(zoom: doc.zoom).frame(width: 78, height: 18) }
            if abs(doc.viewRotation) > 1e-9 { RotationChip(rotation: doc.viewRotation) }
        }
        .fixedSize()
    }
}

struct ZoomStepButton: View {
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(enabled ? (hover ? Theme.text : Theme.textDim) : Theme.textFaint)
                .frame(width: 18, height: 18)
                .background(Rectangle().fill(hover && enabled ? Theme.hover.opacity(0.6) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(symbol == "minus" ? "Zoom Out" : "Zoom In")
        .onHover { hover = $0 }
    }
}

struct ZoomMenuButton: View {
    @State private var hover = false
    var body: some View {
        Button { ZoomController.popUpPresetMenu() } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(hover ? Theme.text : Theme.textDim)
                .frame(width: 14, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Zoom presets")
        .accessibilityLabel("Zoom Presets")
        .onHover { hover = $0 }
    }
}

/// Logarithmic over the whole range, with a tick at 100 %. Drags are immediate (no animation).
struct ZoomSlider: View {
    let zoom: Double
    var body: some View {
        GeometryReader { g in
            let w = g.size.width - 8, t = ZoomController.sliderFraction(zoom)
            let x = 4 + w * t, tick = 4 + w * ZoomController.sliderFraction(1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fieldBG).frame(height: 3).padding(.horizontal, 4)
                Capsule().fill(Theme.textDim.opacity(0.55)).frame(width: max(0, x - 4), height: 3).offset(x: 4)
                Rectangle().fill(Theme.textFaint).frame(width: 1, height: 7).offset(x: tick - 0.5)
                Circle().fill(Theme.text).frame(width: 9, height: 9)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .offset(x: x - 4.5)
            }
            .frame(height: g.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                ZoomController.canvas?.setZoom(ZoomController.zoom(forSlider: Double((v.location.x - 4) / max(w, 1))))
            })
        }
        .help("Zoom")
        .accessibilityElement()
        .accessibilityLabel("Zoom slider")
        .accessibilityValue(ZoomMath.format(zoom))
    }
}

struct RotationChip: View {
    let rotation: Double
    @State private var hover = false
    var body: some View {
        Button { ZoomController.run(.resetRotation) } label: {
            HStack(spacing: 3) {
                Image(systemName: hover ? "arrow.uturn.backward" : "rotate.right").font(.system(size: 9, weight: .semibold))
                Text("\(Int((rotation * 180 / .pi).rounded()))°").font(Theme.mono)
            }
            .foregroundStyle(hover ? Theme.text : Theme.textDim)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(hover ? Theme.hover : Theme.fieldBG))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("View rotated — click to reset the view rotation")
        .accessibilityLabel("Reset View Rotation")
        .onHover { hover = $0 }
    }
}
