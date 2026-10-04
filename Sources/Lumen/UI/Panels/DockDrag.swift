import AppKit
import SwiftUI
import ImageCratCore

// Panel drags: a tab (or a whole group) dragged from a tab bar or an icon follows the pointer as a small ghost; over a
// docked group, column edge or floating window the place it would land is highlighted (blue bar = new group above /
// below / new column, blue outline + caret = add as a tab there), and releasing anywhere else tears it out into a
// floating window. A floating group dragged by its tab bar or title bar moves its window and docks the same way.

/// A drop location and how to show it.
struct DockDropHit: Equatable {
    enum Style: Equatable { case bar, outline }
    var target: DockDropTarget
    weak var window: NSWindow?
    /// Highlight rectangle, window coordinates.
    var rect: CGRect
    var style: Style
    /// Tab insertion caret, window coordinates.
    var caret: CGRect?

    init(_ target: DockDropTarget, window: NSWindow, rect: CGRect, style: Style, caret: CGRect? = nil) {
        self.target = target; self.window = window; self.rect = rect; self.style = style; self.caret = caret
    }

    static func == (a: DockDropHit, b: DockDropHit) -> Bool {
        a.target == b.target && a.window === b.window && a.rect == b.rect && a.style == b.style && a.caret == b.caret
    }
}

final class DockDragSession {
    enum Resolution: Equatable {
        /// Not over the dock or a panel window: releasing floats the panels (or leaves a moved window where it is).
        case nothing
        /// Over the dragged group itself: releasing changes nothing.
        case source
        case target(DockDropHit)
    }
    enum Outcome: Equatable { case docked(DockDropTarget), floated, moved, cancelled }

    let panels: [String]
    let sourceGroup: String
    let wholeGroup: Bool
    let active: String?
    /// The floating window being moved with the pointer (tab-bar or title-bar drag of a whole floating group).
    let movingWindow: FloatingPanel?
    /// The window server moves the window (title-bar drag); the session only watches the pointer.
    let systemMove: Bool
    let start: CGPoint
    let size: CGSize
    private var grab: CGPoint = .zero
    private(set) var resolution: Resolution = .nothing
    private(set) var ghost: DockGhostWindow?
    private(set) var overlay: DockHighlightView?
    private var timer: Timer?

    init(panels: [String], sourceGroup: String, wholeGroup: Bool, active: String?, movingWindow: FloatingPanel?, systemMove: Bool = false,
         start: CGPoint, size: CGSize) {
        self.panels = panels; self.sourceGroup = sourceGroup; self.wholeGroup = wholeGroup; self.active = active
        self.movingWindow = movingWindow; self.systemMove = systemMove; self.start = start; self.size = size
        if let w = movingWindow {
            grab = CGPoint(x: start.x - w.frame.minX, y: start.y - w.frame.minY)
            w.isUserMoving = true
        }
    }

    /// The pointer moved (screen coordinates). Holding ⌘ moves a floating window without docking it.
    func update(_ p: CGPoint, suppressDocking: Bool = NSEvent.modifierFlags.contains(.command)) {
        if let w = movingWindow, !systemMove { w.setFrameOrigin(CGPoint(x: p.x - grab.x, y: p.y - grab.y)) }
        if movingWindow == nil { showGhost(at: p) }
        resolution = suppressDocking ? .nothing : WorkspaceManager.shared.resolveDrop(at: p, for: self)
        showHighlight()
    }

    /// The button was released at `p`.
    @discardableResult
    func finish(_ p: CGPoint, suppressDocking: Bool = NSEvent.modifierFlags.contains(.command)) -> Outcome {
        update(p, suppressDocking: suppressDocking)
        let res = resolution
        cleanup()
        let ws = WorkspaceManager.shared
        switch res {
        case .target(let hit):
            ws.perform(panels, to: hit.target, active: active, height: wholeGroup ? ws.current.group(sourceGroup)?.height : nil)
            ws.returnFocusToCanvas()
            return .docked(hit.target)
        case .source:
            return .cancelled
        case .nothing:
            if let w = movingWindow {
                let others = ws.windows.values.filter { $0 !== w && $0.isVisible }.map(\.frame) + [AppActions.canvas?.window?.frame].compactMap { $0 }
                let snapped = WorkspaceGeometry.snap(w.frame, screens: ws.screens, windows: others)
                if snapped != w.frame { w.setFrame(snapped, display: true) }
                ws.floatingWindowChanged(sourceGroup, frame: w.frame)
                ws.saveNow()
                return .moved
            }
            if hypot(p.x - start.x, p.y - start.y) < 10 { return .cancelled }
            var f = CGRect(x: p.x - 40, y: p.y - size.height + 12, width: size.width, height: size.height)
            let scr = ws.screens
            if let s = scr.first(where: { $0.contains(p) }) ?? scr.first { f = WorkspaceGeometry.clamp(f, into: s) }
            ws.floatPanels(panels, frame: f, active: active)
            return .floated
        }
    }

    func cancel() { cleanup() }

    private func cleanup() {
        timer?.invalidate(); timer = nil
        ghost?.orderOut(nil); ghost = nil
        overlay?.removeFromSuperview(); overlay = nil
        movingWindow?.isUserMoving = false
    }

    /// Title-bar drags are run by the window server: follow the pointer until the button comes up.
    func watchSystemMove() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let ws = WorkspaceManager.shared
            if NSEvent.pressedMouseButtons & 1 == 0 {
                if ws.drag === self { ws.drag = nil }
                self.finish(NSEvent.mouseLocation)
            } else {
                self.update(NSEvent.mouseLocation)
            }
        }
    }

    private func showGhost(at p: CGPoint) {
        if ghost == nil { ghost = DockGhostWindow(title: panels.map(PanelRegistry.title).joined(separator: " · ")) }
        ghost?.setFrameOrigin(CGPoint(x: p.x + 10, y: p.y - 34))
        ghost?.orderFrontRegardless()
    }

    private func showHighlight() {
        guard case .target(let hit) = resolution, let win = hit.window, let host = win.contentView else {
            overlay?.removeFromSuperview(); overlay = nil
            return
        }
        if overlay?.superview !== host {
            overlay?.removeFromSuperview()
            let o = DockHighlightView(frame: host.bounds)
            o.autoresizingMask = [.width, .height]
            host.addSubview(o, positioned: .above, relativeTo: nil)
            overlay = o
        }
        overlay?.frame = host.bounds
        overlay?.show(hit)
    }
}

/// Draws the drop highlight over a window's content (never takes clicks).
final class DockHighlightView: NSView {
    private(set) var hit: DockDropHit?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ h: DockDropHit) {
        guard h != hit else { return }
        hit = h
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let h = hit else { return }
        let r = convert(h.rect, from: nil)
        let accent = DockColors.accent
        switch h.style {
        case .bar:
            accent.setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        case .outline:
            accent.withAlphaComponent(0.12).setFill()
            r.insetBy(dx: 1, dy: 1).fill()
            accent.setStroke()
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            p.lineWidth = 2
            p.stroke()
        }
        if let c = h.caret {
            accent.setFill()
            convert(c, from: nil).fill()
        }
    }
}

/// The small label that follows the pointer while a panel is dragged.
final class DockGhostWindow: NSPanel {
    init(title: String) {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let w = min(260, ceil((title as NSString).size(withAttributes: [.font: font]).width) + 34)
        super.init(contentRect: CGRect(x: 0, y: 0, width: w, height: 26), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        contentView = DockGhostView(title: title)
        if WorkspaceManager.isSelfTest { alphaValue = 0 }
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DockGhostView: NSView {
    let title: String
    init(title: String) { self.title = title; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        DockColors.header.withAlphaComponent(0.94).setFill()
        let p = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        p.fill()
        DockColors.accent.setStroke()
        p.lineWidth = 1.5
        p.stroke()
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail; para.alignment = .center
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: DockColors.text, .paragraphStyle: para]
        let h = (title as NSString).size(withAttributes: a).height
        (title as NSString).draw(with: CGRect(x: 10, y: (bounds.height - h) / 2, width: bounds.width - 20, height: h), options: [.usesLineFragmentOrigin], attributes: a)
    }
}

// MARK: - Floating windows

/// A floating tab group: a resizable utility window that stays above the main window, only becomes key when one of its
/// text fields is clicked (so the canvas keeps the keyboard), remembers its frame in the workspace, and snaps to screen
/// and window edges.
final class FloatingPanel: NSPanel, NSWindowDelegate {
    static let productionStyle: NSWindow.StyleMask = [.titled, .closable, .resizable, .utilityWindow]
    /// Self tests use borderless windows: AppKit moves a titled window that is off every screen onto the display when it
    /// is ordered in (`_positionWindowOnBestScreen`), and test windows must never appear there.
    static let style: NSWindow.StyleMask = WorkspaceManager.isSelfTest ? [.borderless, .resizable] : productionStyle
    let groupID: String
    private(set) var panelIDs: [String] = []
    private(set) var selectedPanel: String?
    /// The panel in front (old single-panel windows were identified by it).
    var panelID: String { selectedPanel ?? panelIDs.first ?? "" }
    let groupView = DockGroupView(floating: true)
    /// Set while a drag session moves the window (its frame then follows the pointer, not the model).
    var isUserMoving = false
    private var silent = false
    private var dismissed = false

    static func frameHeight(forContentHeight h: CGFloat) -> CGFloat {
        NSWindow.frameRect(forContentRect: CGRect(x: 0, y: 0, width: 100, height: h), styleMask: style).height
    }

    init(groupID: String) {
        self.groupID = groupID
        super.init(contentRect: CGRect(origin: .zero, size: DockMetrics.defaultFloatSize), styleMask: Self.style, backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = !WorkspaceManager.isSelfTest
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary]
        minSize = NSWindow.frameRect(forContentRect: CGRect(origin: .zero, size: DockMetrics.minFloatSize), styleMask: Self.style).size
        delegate = self
        if WorkspaceManager.isSelfTest { alphaValue = 0 }     // (and never visible, wherever it ends up)
        let container = FloatingContentView(frame: CGRect(origin: .zero, size: DockMetrics.defaultFloatSize))
        groupView.frame = container.bounds
        groupView.autoresizingMask = [.width, .height]
        container.addSubview(groupView)
        contentView = container
        refreshTheme()
    }

    func update(_ g: DockGroup) {
        panelIDs = g.panels
        selectedPanel = g.selected
        title = g.panels.map(PanelRegistry.title).joined(separator: " · ")
        setAccessibilityLabel(title + " (floating panel)")
        groupView.update(g)
        if g.collapsed { styleMask.remove(.resizable) } else { styleMask.insert(.resizable) }
    }

    func refreshTheme() {
        appearance = NSAppearance(named: AppModel.shared.prefs.theme.isLight ? .aqua : .darkAqua)
        backgroundColor = DockColors.panel
        if let c = contentView { DockAreaView.redraw(c) }
    }

    func setFrameSilently(_ f: CGRect) {
        silent = true
        setFrame(f, display: true)
        silent = false
        // AppKit keeps a titled window's title bar on screen: the workspace follows where it really is
        if !frame.equalTo(f, tolerance: 0.5) { WorkspaceManager.shared.floatingWindowChanged(groupID, frame: frame) }
    }

    /// Self tests place floating windows on a screen far off the real ones; AppKit must not pull them onto the display.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        WorkspaceManager.isSelfTest ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    /// Removed from the workspace (docked elsewhere, workspace switched): goes away without closing its panels.
    func dismiss() {
        dismissed = true
        groupView.content.show(nil)
        orderOut(nil)
        close()
    }

    /// The close button closes the panels in it.
    override func close() {
        if !dismissed {
            dismissed = true
            WorkspaceManager.shared.closeGroup(groupID)
        }
        super.close()
    }

    // MARK: NSWindowDelegate

    func windowWillMove(_ notification: Notification) {
        let ws = WorkspaceManager.shared
        guard !isUserMoving, ws.drag == nil, NSEvent.pressedMouseButtons & 1 != 0, let g = ws.current.group(groupID) else { return }
        let s = DockDragSession(panels: g.panels, sourceGroup: groupID, wholeGroup: true, active: g.selected, movingWindow: self, systemMove: true,
                                start: NSEvent.mouseLocation, size: frame.size)
        ws.drag = s
        s.watchSystemMove()
    }

    func windowDidMove(_ notification: Notification) {
        if WorkspaceManager.isSelfTest, NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
            print("FAIL workspace2: a floating test window reached a real screen at \(frame)")
        }
        if !silent { WorkspaceManager.shared.floatingWindowChanged(groupID, frame: frame) }
    }

    func windowDidResize(_ notification: Notification) {
        if !silent { WorkspaceManager.shared.floatingWindowChanged(groupID, frame: frame) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        WorkspaceManager.shared.saveNow()
        WorkspaceManager.shared.returnFocusToCanvas()
    }

    // MARK: Drops onto this window (add as a tab)

    func dropResolution(at p: CGPoint, for s: DockDragSession) -> DockDragSession.Resolution {
        guard let g = WorkspaceManager.shared.current.group(groupID) else { return .nothing }
        let own = s.sourceGroup == groupID
        if own && s.wholeGroup { return .source }
        let bar = groupView.tabBar
        let lp = bar.convert(convertPoint(fromScreen: p), from: nil)
        let whole = groupView.convert(groupView.bounds, to: nil)
        if lp.y >= 0 && lp.y <= bar.bounds.height || frame.maxY - p.y < 30 {
            let (i, cx) = bar.insertion(atX: lp.x)
            let caret = bar.convert(CGRect(x: cx - 1, y: 3, width: 2, height: DockMetrics.tabBarHeight - 6), to: nil)
            return .target(DockDropHit(.tab(group: groupID, index: i), window: self, rect: whole.insetBy(dx: 1, dy: 1), style: .outline, caret: caret))
        }
        if own { return .source }
        return .target(DockDropHit(.tab(group: groupID, index: g.panels.count), window: self, rect: whole.insetBy(dx: 1, dy: 1), style: .outline))
    }
}

final class FloatingContentView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        DockColors.panel.setFill()
        bounds.intersection(dirtyRect).fill()   // (since macOS 14 views don't clip to their bounds: a dirty rect can reach far outside)
    }
}

extension WorkspaceManager {
    /// What is under the pointer during a panel drag: floating windows first (front to back), then the docked columns.
    func resolveDrop(at p: CGPoint, for s: DockDragSession) -> DockDragSession.Resolution {
        // (NSApp.orderedWindows leaves panels out: order them by the window list instead)
        let order = (NSWindow.windowNumbers(options: []) ?? []).map(\.intValue)
        let panels = windows.values.sorted { (order.firstIndex(of: $0.windowNumber) ?? .max) < (order.firstIndex(of: $1.windowNumber) ?? .max) }
        for fp in panels where fp.isVisible && fp !== s.movingWindow && fp.frame.contains(p) {
            return fp.dropResolution(at: p, for: s)
        }
        for d in dockViews where d.window?.isVisible == true {
            if let r = d.dropResolution(at: p, for: s) { return r }
        }
        return .nothing
    }
}
