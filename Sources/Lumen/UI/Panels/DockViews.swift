import AppKit
import SwiftUI
import ImageCratCore

// The docked panel columns, drawn and driven by AppKit: columns with resizable widths, tab groups with draggable tabs and
// draggable dividers, icon columns with pop-over panels, and the same tab group inside floating windows. The panels' own
// SwiftUI views are hosted unchanged (one `NSHostingView` per open panel, see `WorkspaceManager.host`).

/// Dock chrome (tab bars, column headers, dividers, panel icons): clicks there arrange panels, they are not clicks in a
/// panel's content (see `PendingEdits.clickIsInPanel`).
protocol DockChrome: AnyObject {}

enum DockColors {
    static var gap: NSColor { NSColor(Theme.appBG) }
    static var panel: NSColor { NSColor(Theme.panelBG) }
    static var header: NSColor { NSColor(Theme.panelHeader) }
    static var border: NSColor { NSColor(Theme.border) }
    static var text: NSColor { NSColor(Theme.text) }
    static var textDim: NSColor { NSColor(Theme.textDim) }
    static var textFaint: NSColor { NSColor(Theme.textFaint) }
    static var hover: NSColor { NSColor(Theme.hover) }
    static var accent: NSColor { NSColor(Theme.accent) }
}

extension PanelRegistry {
    /// SF Symbol shown for a panel in an icon column.
    static func symbol(_ id: String) -> String {
        let table: [String: String] = [
            "color": "paintpalette", "swatches": "square.grid.3x3.fill", "gradients": "circle.lefthalf.filled", "patterns": "checkerboard.rectangle",
            "properties": "slider.horizontal.3", "adjustments": "circle.righthalf.filled", "character": "textformat", "paragraph": "text.alignleft",
            "layers": "square.3.layers.3d", "channels": "camera.filters", "paths": "point.topleft.down.to.point.bottomright.curvepath",
            "layerComps": "square.stack.3d.down.right", "navigator": "map", "histogram": "chart.bar.xaxis", "info": "info.circle",
            "history": "clock.arrow.circlepath", "brushes": "paintbrush", "brushSettings": "paintbrush.pointed", "actions": "play.rectangle",
            "toolPresets": "wrench.and.screwdriver", "glyphs": "textformat.abc", "genUsage": "sparkles", "genHistory": "photo.stack",
            "components": "puzzlepiece", "clipboardHistory": "doc.on.clipboard", "historyTree": "arrow.triangle.branch", "versions": "square.stack",
            "preflight": "checklist", "recipes": "list.bullet.rectangle", "notes": "note.text", "measurementLog": "ruler", "cloneSource": "seal",
            "contentCredentials": "checkmark.seal", "colorHarmony": "circle.hexagongrid", "contrastChecker": "circle.lefthalf.striped.horizontal",
            "drawingAssist": "pencil.and.ruler", "brushTestPad": "scribble", "scriptConsole": "terminal",
        ]
        return table[id] ?? (id.lowercased().contains("find") ? "magnifyingglass" : "square.on.square")
    }

    /// The panel's title in the interface language (`def.title` is the English name).
    static func title(_ id: String) -> String { tr(def(id)?.title ?? id) }
}

/// An `NSMenuItem` that runs a closure.
final class DockMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// A small borderless symbol button for the chrome (labelled for VoiceOver, with a tooltip).
final class DockChromeButton: NSButton, DockChrome {
    var onPress: (() -> Void)?
    init(symbol: String, label: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        setSymbol(symbol, label: label)
        target = self
        action = #selector(pressed)
        refusesFirstResponder = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ s: String, label: String) {
        image = NSImage(systemSymbolName: s, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        toolTip = tr(label)
        setAccessibilityLabel(tr(label))
        contentTintColor = DockColors.textDim
    }
    @objc private func pressed() {
        onPress?()
        WorkspaceManager.shared.returnFocusToCanvas()
    }
}

/// Screen location of a mouse event (from the event itself, so synthetic events in tests work too).
func dockScreenPoint(_ e: NSEvent) -> CGPoint {
    e.window.map { $0.convertPoint(toScreen: e.locationInWindow) } ?? NSEvent.mouseLocation
}

// MARK: - Dock area

/// All docked columns of the main window, right of the canvas.
final class DockAreaView: NSView {
    override var isFlipped: Bool { true }
    var showSecondary = true { didSet { if showSecondary != oldValue { reload() } } }
    private var columnViews: [String: DockColumnView] = [:]
    private var dividers: [String: DockDividerView] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true   // nothing in the dock may paint over the canvas, tools or options bar beside it
        setAccessibilityRole(.group)
        setAccessibilityLabel(tr("Panels"))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            WorkspaceManager.shared.register(self)
            reload()
        } else {
            teardown()
        }
    }

    /// Out of the window (panels hidden, window closed): let go of the panels' views so the dock that replaces it gets them.
    func teardown() {
        teardownColumns()
        WorkspaceManager.shared.unregister(self)
    }

    func teardownColumns() {
        columnViews.values.forEach { $0.removeFromSuperview() }
        dividers.values.forEach { $0.removeFromSuperview() }
        columnViews = [:]
        dividers = [:]
    }

    /// The columns shown here, with their index in `Workspace.columns`.
    var visibleColumns: [(index: Int, column: DockColumn)] {
        let all = WorkspaceManager.shared.current.columns.enumerated().map { (index: $0.offset, column: $0.element) }
        return showSecondary ? all : Array(all.suffix(1))
    }

    func reload() {
        guard window != nil, WorkspaceManager.shared.activeDock === self else { return }
        let vis = visibleColumns
        let ids = vis.map(\.column.id)
        for (id, v) in columnViews where !ids.contains(id) {
            v.removeFromSuperview(); columnViews[id] = nil
            dividers[id]?.removeFromSuperview(); dividers[id] = nil
        }
        var added = false
        for (_, c) in vis {
            let v: DockColumnView
            if let x = columnViews[c.id] { v = x } else {
                v = DockColumnView(columnID: c.id)
                addSubview(v)
                columnViews[c.id] = v
                added = true
            }
            v.update(c)
            let d: DockDividerView
            if let x = dividers[c.id] { d = x } else {
                d = DockDividerView(kind: .column(c.id))
                dividers[c.id] = d
                added = true
            }
            d.resizable = !c.iconic
        }
        if added { for (_, c) in vis { if let d = dividers[c.id] { addSubview(d, positioned: .above, relativeTo: nil) } } }
        needsLayout = true
        needsDisplay = true
    }

    func columnView(_ id: String) -> DockColumnView? { columnViews[id] }
    func groupView(_ gid: String) -> DockGroupView? { columnViews.values.lazy.compactMap { $0.groupView(gid) }.first }
    func iconButton(for id: String) -> DockIconButton? { columnViews.values.lazy.compactMap { $0.iconButton(for: id) }.first }
    func divider(column id: String) -> DockDividerView? { dividers[id] }

    /// Column widths as laid out (scaled down when the window leaves less room than the columns would like).
    func layoutWidths() -> [(DockColumn, CGFloat)] {
        let vis = visibleColumns
        let natural = vis.reduce(0) { $0 + $1.column.displayWidth + DockMetrics.columnGap }
        let flexible = vis.filter { !$0.column.iconic }.reduce(0) { $0 + $1.column.width }
        var scale: CGFloat = 1
        if natural > bounds.width + 0.5, flexible > 0 { scale = max(0.3, (flexible - (natural - bounds.width)) / flexible) }
        return vis.map { ($0.column, $0.column.iconic ? $0.column.displayWidth : ($0.column.width * scale).rounded()) }
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for (c, w) in layoutWidths() {
            dividers[c.id]?.frame = CGRect(x: x - 2, y: 0, width: DockMetrics.columnGap + 4, height: bounds.height)
            x += DockMetrics.columnGap
            columnViews[c.id]?.frame = CGRect(x: x, y: 0, width: w, height: bounds.height)
            x += w
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        DockColors.gap.setFill()
        bounds.intersection(dirtyRect).fill()   // (since macOS 14 views don't clip to their bounds: a dirty rect can reach far outside)
    }

    func refreshTheme() { DockAreaView.redraw(self) }

    static func redraw(_ v: NSView) {
        v.needsDisplay = true
        for s in v.subviews where !(s is NSHostingView<PanelContentRoot>) { redraw(s) }
        if let b = v as? DockChromeButton { b.contentTintColor = DockColors.textDim }
    }

    // MARK: Drop targets

    func dropResolution(at p: CGPoint, for s: DockDragSession) -> DockDragSession.Resolution? {
        guard let win = window, !isHiddenOrHasHiddenAncestor else { return nil }
        let wp = win.convertPoint(fromScreen: p)
        let me = convert(bounds, to: nil)
        let ws = WorkspaceManager.shared
        let vis = visibleColumns
        func bar(_ x: CGFloat) -> CGRect { CGRect(x: x - 3, y: me.minY, width: 6, height: me.height) }
        if vis.isEmpty {
            // no docked columns: the right edge of the window docks into a new column
            let zone = CGRect(x: me.maxX - 56, y: me.minY, width: 56 + me.width, height: me.height)
            guard zone.contains(wp) else { return nil }
            return .target(DockDropHit(.column(index: ws.current.columns.count), window: win, rect: bar(me.maxX - 3), style: .bar))
        }
        // just left of the dock: a new column on the left
        if CGRect(x: me.minX - 14, y: me.minY, width: 14 + DockMetrics.columnGap, height: me.height).contains(wp) {
            return .target(DockDropHit(.column(index: vis[0].index), window: win, rect: bar(me.minX + 2), style: .bar))
        }
        // just past the right edge of the window: a new column on the right
        if wp.x >= me.maxX - 3 && wp.x < me.maxX + 30 && wp.y >= me.minY && wp.y <= me.maxY, let last = vis.last {
            return .target(DockDropHit(.column(index: last.index + 1), window: win, rect: bar(me.maxX - 3), style: .bar))
        }
        guard me.contains(wp) else { return nil }
        let lp = convert(wp, from: nil)
        for (k, (index, col)) in vis.enumerated() {
            guard let cv = columnViews[col.id] else { continue }
            let cf = cv.frame
            // the strip left of a column (and a sliver of the column): a new column there
            if lp.x >= cf.minX - DockMetrics.columnGap - 2 && lp.x < cf.minX + 3 {
                return .target(DockDropHit(.column(index: index), window: win, rect: bar(convert(CGPoint(x: cf.minX - 2, y: 0), to: nil).x), style: .bar))
            }
            if k == vis.count - 1 && lp.x > cf.maxX - 3 {
                return .target(DockDropHit(.column(index: index + 1), window: win, rect: bar(convert(CGPoint(x: cf.maxX - 3, y: 0), to: nil).x), style: .bar))
            }
            if lp.x >= cf.minX && lp.x <= cf.maxX { return cv.dropResolution(at: convert(lp, to: cv), for: s) }
        }
        return nil
    }
}

// MARK: - Column

final class DockColumnView: NSView {
    override var isFlipped: Bool { true }
    let columnID: String
    private(set) var column: DockColumn?
    let header: DockColumnHeader
    private var groupViews: [String: DockGroupView] = [:]
    private var groupDividers: [DockDividerView] = []
    private var iconStrip: DockIconStrip?
    /// Heights of the groups as last laid out (what a divider drag starts from).
    private(set) var laidOutHeights: [CGFloat] = []

    init(columnID: String) {
        self.columnID = columnID
        header = DockColumnHeader(columnID: columnID)
        super.init(frame: .zero)
        addSubview(header)
        setAccessibilityRole(.group)
        setAccessibilityLabel(tr("Panel column"))
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ c: DockColumn) {
        column = c
        header.update(iconic: c.iconic)
        if c.iconic {
            groupViews.values.forEach { $0.removeFromSuperview() }
            groupViews = [:]
            groupDividers.forEach { $0.removeFromSuperview() }
            groupDividers = []
            let s: DockIconStrip
            if let x = iconStrip { s = x } else { s = DockIconStrip(); addSubview(s); iconStrip = s }
            s.update(c)
        } else {
            iconStrip?.removeFromSuperview()
            iconStrip = nil
            let ids = c.groups.map(\.id)
            for (id, v) in groupViews where !ids.contains(id) { v.removeFromSuperview(); groupViews[id] = nil }
            for g in c.groups {
                let v: DockGroupView
                if let x = groupViews[g.id] { v = x } else { v = DockGroupView(floating: false); addSubview(v, positioned: .below, relativeTo: header); groupViews[g.id] = v }
                v.update(g)
            }
            let n = max(0, c.groups.count - 1)
            while groupDividers.count < n { let d = DockDividerView(kind: .group(column: c.id, index: groupDividers.count)); addSubview(d, positioned: .above, relativeTo: nil); groupDividers.append(d) }
            while groupDividers.count > n { groupDividers.removeLast().removeFromSuperview() }
            for (i, d) in groupDividers.enumerated() { d.kind = .group(column: c.id, index: i) }
        }
        needsLayout = true
        needsDisplay = true
    }

    func groupView(_ gid: String) -> DockGroupView? { groupViews[gid] }
    func iconButton(for id: String) -> DockIconButton? { iconStrip?.button(for: id) }
    func groupDivider(_ i: Int) -> DockDividerView? { groupDividers.indices.contains(i) ? groupDividers[i] : nil }

    override func layout() {
        super.layout()
        let top = DockMetrics.columnHeaderHeight
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: top)
        let body = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        if let s = iconStrip { s.frame = body; laidOutHeights = []; return }
        guard let c = column else { return }
        let hs = WorkspaceGeometry.groupHeights(c.groups, available: body.height)
        laidOutHeights = hs
        var y = top
        for (i, g) in c.groups.enumerated() {
            groupViews[g.id]?.frame = CGRect(x: 0, y: y, width: bounds.width, height: hs[i])
            y += hs[i]
            if i < groupDividers.count {
                groupDividers[i].frame = CGRect(x: 0, y: y - 2, width: bounds.width, height: DockMetrics.groupGap + 4)
                y += DockMetrics.groupGap
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        DockColors.gap.setFill()
        bounds.intersection(dirtyRect).fill()   // (since macOS 14 views don't clip to their bounds: a dirty rect can reach far outside)
    }

    func dropResolution(at lp: CGPoint, for s: DockDragSession) -> DockDragSession.Resolution {
        guard let c = column, let win = window else { return .nothing }
        func hit(_ t: DockDropTarget, _ r: CGRect, _ style: DockDropHit.Style, caret: CGRect? = nil) -> DockDragSession.Resolution {
            .target(DockDropHit(t, window: win, rect: convert(r, to: nil), style: style, caret: caret.map { convert($0, to: nil) }))
        }
        if c.iconic { return hit(.columnEnd(column: c.id), bounds.insetBy(dx: 1, dy: 1), .outline) }
        let frames = c.groups.compactMap { g in groupViews[g.id].map { (g, $0.frame) } }
        guard let first = frames.first, let last = frames.last else { return hit(.columnEnd(column: c.id), bounds.insetBy(dx: 1, dy: 1), .outline) }
        if lp.y < first.1.minY { return hit(.split(group: first.0.id, below: false), bar(first.1.minY), .bar) }
        if lp.y > last.1.maxY + 1 { return hit(.columnEnd(column: c.id), bar(last.1.maxY + 1), .bar) }
        for (g, f) in frames where lp.y >= f.minY && lp.y <= f.maxY + DockMetrics.groupGap {
            let own = g.id == s.sourceGroup
            if own && s.wholeGroup { return .source }
            let tabZone = CGRect(x: f.minX, y: f.minY, width: f.width, height: DockMetrics.tabBarHeight)
            if g.collapsed {
                if !own && lp.y < f.minY + 7 { return hit(.split(group: g.id, below: false), bar(f.minY), .bar) }
                if !own && lp.y > f.maxY - 7 { return hit(.split(group: g.id, below: true), bar(f.maxY + 1), .bar) }
            }
            if tabZone.contains(lp) || g.collapsed, let gv = groupViews[g.id] {
                let x = convert(lp, to: gv.tabBar).x
                let (i, cx) = gv.tabBar.insertion(atX: x)
                let caret = gv.tabBar.convert(CGRect(x: cx - 1, y: 3, width: 2, height: DockMetrics.tabBarHeight - 6), to: self)
                return hit(.tab(group: g.id, index: i), f.insetBy(dx: 1, dy: 1), .outline, caret: caret)
            }
            let rel = (lp.y - tabZone.maxY) / max(1, f.maxY - tabZone.maxY)
            if rel < 0.3 { return hit(.split(group: g.id, below: false), bar(f.minY), .bar) }
            if rel > 0.7 { return hit(.split(group: g.id, below: true), bar(f.maxY + 1), .bar) }
            if own { return .source }
            return hit(.tab(group: g.id, index: g.panels.count), f.insetBy(dx: 1, dy: 1), .outline)
        }
        return .nothing
    }

    private func bar(_ y: CGFloat) -> CGRect { CGRect(x: 0, y: y - 3, width: bounds.width, height: 5) }
}

/// The strip at the top of a column: collapse to icons / expand.
final class DockColumnHeader: NSView, DockChrome {
    override var isFlipped: Bool { true }
    let columnID: String
    let button = DockChromeButton(symbol: "chevron.right.2", label: "Collapse to Icons")
    private(set) var iconic = false

    init(columnID: String) {
        self.columnID = columnID
        super.init(frame: .zero)
        addSubview(button)
        button.onPress = { [weak self] in self?.toggle() }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(iconic: Bool) {
        self.iconic = iconic
        button.setSymbol(iconic ? "chevron.left.2" : "chevron.right.2", label: iconic ? "Expand Panels" : "Collapse to Icons")
        needsLayout = true
    }

    func toggle() { WorkspaceManager.shared.setIconic(column: columnID, !iconic) }

    override func layout() {
        super.layout()
        let s: CGFloat = 16
        button.frame = iconic ? CGRect(x: (bounds.width - s) / 2, y: 0, width: s, height: s) : CGRect(x: bounds.width - s - 4, y: 0, width: s, height: s)
    }

    override func draw(_ dirtyRect: NSRect) {
        DockColors.header.blended(withFraction: 0.35, of: DockColors.gap)?.setFill()
        bounds.fill()
    }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { toggle() }
    }
    override func mouseUp(with e: NSEvent) { WorkspaceManager.shared.returnFocusToCanvas() }
}

// MARK: - Tab group

/// A tab bar over the selected panel's content. Used in docked columns and in floating windows.
final class DockGroupView: NSView {
    override var isFlipped: Bool { true }
    let floating: Bool
    let tabBar: DockTabBar
    let content = DockContentView()
    private(set) var group: DockGroup?

    init(floating: Bool) {
        self.floating = floating
        tabBar = DockTabBar(floating: floating)
        super.init(frame: .zero)
        addSubview(content)
        addSubview(tabBar)
        tabBar.groupView = self
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ g: DockGroup) {
        group = g
        tabBar.update(g)
        content.isHidden = g.collapsed
        if !g.collapsed, let sel = g.selected { content.show(WorkspaceManager.shared.host(sel)) } else { content.show(nil) }
        setAccessibilityLabel(tr("Panel group: \(g.panels.map(PanelRegistry.title).joined(separator: ", "))"))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        tabBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: DockMetrics.tabBarHeight)
        content.frame = CGRect(x: 0, y: DockMetrics.tabBarHeight, width: bounds.width, height: max(0, bounds.height - DockMetrics.tabBarHeight))
    }
}

/// Holds the selected panel's hosting view.
final class DockContentView: NSView {
    override var isFlipped: Bool { true }
    private(set) weak var hosted: NSView?

    func show(_ v: NSView?) {
        if let v, hosted === v, v.superview === self { return }
        if let h = hosted, h.superview === self, h !== v { h.removeFromSuperview() }
        hosted = v
        guard let v else { return }
        if v.superview !== self {
            v.removeFromSuperview()
            addSubview(v)
        }
        v.frame = bounds
        v.autoresizingMask = [.width, .height]
    }

    override func layout() {
        super.layout()
        hosted?.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        DockColors.panel.setFill()
        bounds.intersection(dirtyRect).fill()   // (since macOS 14 views don't clip to their bounds: a dirty rect can reach far outside)
    }
}

/// A tab group's tab bar: click selects, double-click collapses the group, dragging a tab moves that panel (dragging the
/// empty part moves the whole group), right-click / the ≡ button offer Float, Dock, Close and Collapse.
final class DockTabBar: NSView, DockChrome {
    override var isFlipped: Bool { true }
    weak var groupView: DockGroupView?
    let floating: Bool
    private(set) var group: DockGroup?
    let menuButton = DockChromeButton(symbol: "line.3.horizontal", label: "Panel Options")
    let overflowButton = DockChromeButton(symbol: "chevron.right.2", label: "More Tabs")
    /// Visible tabs and where they are drawn.
    private(set) var tabRects: [(id: String, rect: CGRect)] = []
    /// Tabs that don't fit (reached through the » button).
    private(set) var overflow: [String] = []
    private var hoverID: String?
    private var press: (point: CGPoint, id: String?, started: Bool)?
    private var trackingArea: NSTrackingArea?
    private var tabElements: [DockTabElement] = []

    init(floating: Bool) {
        self.floating = floating
        super.init(frame: .zero)
        addSubview(menuButton)
        addSubview(overflowButton)
        menuButton.onPress = { [weak self] in self?.popUpMenu(for: self?.group?.selected, from: self?.menuButton) }
        overflowButton.onPress = { [weak self] in self?.popUpOverflow() }
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(tr("Panel tabs"))
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ g: DockGroup) {
        group = g
        needsLayout = true
        needsDisplay = true
    }

    private static let font = NSFont.systemFont(ofSize: 11)
    private static let boldFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let minTab: CGFloat = 52

    override func layout() {
        super.layout()
        let h = DockMetrics.tabBarHeight
        menuButton.frame = CGRect(x: bounds.width - 22, y: (h - 18) / 2, width: 18, height: 18)
        computeTabs()
        overflowButton.isHidden = overflow.isEmpty
        overflowButton.frame = CGRect(x: bounds.width - 40, y: (h - 18) / 2, width: 18, height: 18)
        rebuildToolTips()
        updateAccessibilityChildren()
    }

    private func computeTabs() {
        guard let g = group, !g.panels.isEmpty else { tabRects = []; overflow = []; return }
        let titles = g.panels.map(PanelRegistry.title)
        let natural = titles.map { ceil(($0 as NSString).size(withAttributes: [.font: Self.boldFont]).width) + 20 }
        var avail = max(0, bounds.width - 24)
        var visible = Array(g.panels.indices)
        var widths = natural
        if natural.reduce(0, +) > avail {
            // shrink proportionally (titles truncate), then move what still doesn't fit to the » menu
            if CGFloat(visible.count) * Self.minTab > avail {
                avail -= 18
                let fit = max(1, Int(avail / Self.minTab))
                visible = Array(visible.prefix(fit))
                if let sel = g.selected, let si = g.panels.firstIndex(of: sel), !visible.contains(si) { visible[visible.count - 1] = si }
            }
            let sum = visible.map { natural[$0] }.reduce(0, +)
            let f = min(1, avail / max(1, sum))
            widths = natural.map { max(Self.minTab, ($0 * f).rounded(.down)) }
        }
        var x: CGFloat = 0
        tabRects = visible.map { i in
            defer { x += widths[i] }
            return (g.panels[i], CGRect(x: x, y: 0, width: min(widths[i], max(Self.minTab, avail - x)), height: DockMetrics.tabBarHeight))
        }
        overflow = g.panels.indices.filter { !visible.contains($0) }.map { g.panels[$0] }
    }

    func tabID(at p: CGPoint) -> String? { tabRects.first { $0.rect.contains(p) }?.id }
    func rect(of id: String) -> CGRect? { tabRects.first { $0.id == id }?.rect }

    /// Where a tab dropped at `x` goes: its index in the group, and the x of the insertion caret.
    func insertion(atX x: CGFloat) -> (index: Int, caretX: CGFloat) {
        guard let g = group else { return (0, 0) }
        for (id, r) in tabRects where x < r.midX { return (g.panels.firstIndex(of: id) ?? 0, r.minX + 1) }
        return (g.panels.count, (tabRects.last?.rect.maxX ?? 0) + 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = group else { return }
        DockColors.header.setFill()
        bounds.fill()
        let h = DockMetrics.tabBarHeight
        let expanded = !g.collapsed
        DockColors.border.setFill()
        CGRect(x: 0, y: h - 1, width: bounds.width, height: 1).fill()
        for (id, r) in tabRects {
            let active = id == g.selected
            if active && expanded {
                DockColors.panel.setFill(); r.fill()
                DockColors.accent.setFill(); CGRect(x: r.minX, y: 0, width: r.width, height: 2).fill()
            } else if id == hoverID {
                DockColors.hover.setFill(); r.insetBy(dx: 0, dy: 0).fill()
            }
            if !(active && expanded) {
                DockColors.border.setFill()
                CGRect(x: r.maxX - 1, y: 6, width: 1, height: h - 12).fill()
            }
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: active ? Self.boldFont : Self.font,
                                                        .foregroundColor: active ? DockColors.text : DockColors.textDim, .paragraphStyle: para]
            let title = PanelRegistry.title(id) as NSString
            let th = title.size(withAttributes: attrs).height
            title.draw(with: CGRect(x: r.minX + 8, y: (h - th) / 2, width: r.width - 16, height: th), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }
    override func mouseMoved(with e: NSEvent) {
        let id = tabID(at: convert(e.locationInWindow, from: nil))
        if id != hoverID { hoverID = id; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { if hoverID != nil { hoverID = nil; needsDisplay = true } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        guard let g = group else { return }
        let p = convert(e.locationInWindow, from: nil)
        let id = tabID(at: p)
        if e.clickCount == 2 {
            press = nil
            if floating, let win = window as? FloatingPanel { WorkspaceManager.shared.toggleCollapsed(group: win.groupID) }
            else { WorkspaceManager.shared.toggleCollapsed(group: g.id) }
            return
        }
        if let id, id != g.selected || g.collapsed { WorkspaceManager.shared.select(id) }
        press = (dockScreenPoint(e), id, false)
    }

    override func mouseDragged(with e: NSEvent) {
        guard var pr = press else { return }
        let m = dockScreenPoint(e)
        if !pr.started {
            guard hypot(m.x - pr.point.x, m.y - pr.point.y) >= 4 else { return }
            pr.started = true
            press = pr
            beginDrag(tab: pr.id, at: pr.point)
        }
        WorkspaceManager.shared.drag?.update(m, suppressDocking: e.modifierFlags.contains(.command))   // ⌘ as of this event, not the live keyboard
    }

    override func mouseUp(with e: NSEvent) {
        let pr = press
        press = nil
        if pr?.started == true, let s = WorkspaceManager.shared.drag {
            WorkspaceManager.shared.drag = nil
            s.finish(dockScreenPoint(e), suppressDocking: e.modifierFlags.contains(.command))
        }
        WorkspaceManager.shared.returnFocusToCanvas()
    }

    /// Starts moving a tab (or, from the empty part of the bar or a single-tab group, the whole group).
    func beginDrag(tab id: String?, at start: CGPoint) {
        guard let g = group, let gv = groupView else { return }
        let whole = id == nil || g.panels.count == 1
        let panels = whole ? g.panels : [id!]
        let win = window as? FloatingPanel
        let size = win?.frame.size ?? CGSize(width: gv.bounds.width, height: max(gv.bounds.height, 300))
        WorkspaceManager.shared.drag?.cancel()
        WorkspaceManager.shared.drag = DockDragSession(panels: panels, sourceGroup: g.id, wholeGroup: whole, active: whole ? g.selected : id,
                                                       movingWindow: whole && floating ? win : nil, start: start, size: size)
    }

    // MARK: Menus

    override func menu(for event: NSEvent) -> NSMenu? {
        let id = tabID(at: convert(event.locationInWindow, from: nil)) ?? group?.selected
        return id.map { optionsMenu(for: $0) }
    }

    func optionsMenu(for id: String) -> NSMenu {
        let ws = WorkspaceManager.shared
        let m = NSMenu()
        m.autoenablesItems = false
        guard let g = group else { return m }
        let title = PanelRegistry.title(id)
        let docked = !floating
        m.addItem(DockMenuItem("Close \(title)") { ws.close(id) })
        if g.panels.count > 1 { m.addItem(DockMenuItem("Close Tab Group") { ws.closeGroup(g.id) }) }
        m.addItem(.separator())
        if docked || g.panels.count > 1 { m.addItem(DockMenuItem("Float \(title) in Window") { ws.float(id) }) }
        if docked { m.addItem(DockMenuItem("Float Tab Group in Window") { ws.floatPanels(g.panels, active: g.selected) }) }
        if floating {
            m.addItem(DockMenuItem("Dock \(title)") { ws.dock(id) })
            if g.panels.count > 1 {
                m.addItem(DockMenuItem("Dock Tab Group") {
                    if let c = ws.current.columns.last { ws.perform(g.panels, to: .columnEnd(column: c.id), active: g.selected) }
                    else { ws.perform(g.panels, to: .column(index: 0), active: g.selected) }
                })
            }
        }
        if docked { m.addItem(DockMenuItem("Move \(title) to New Column") { ws.perform([id], to: .column(index: 0)) }) }
        m.addItem(.separator())
        m.addItem(DockMenuItem(g.collapsed ? "Expand Tab Group" : "Collapse Tab Group") { ws.toggleCollapsed(group: g.id) })
        return m
    }

    private func popUpMenu(for id: String?, from v: NSView?) {
        guard let id, let v else { return }
        optionsMenu(for: id).popUp(positioning: nil, at: CGPoint(x: 0, y: v.bounds.maxY + 2), in: v)
    }

    private func popUpOverflow() {
        let m = NSMenu()
        for id in overflow { m.addItem(DockMenuItem(PanelRegistry.title(id)) { WorkspaceManager.shared.select(id) }) }
        m.popUp(positioning: nil, at: CGPoint(x: 0, y: overflowButton.bounds.maxY + 2), in: overflowButton)
    }

    // MARK: Tooltips / accessibility

    private func rebuildToolTips() {
        removeAllToolTips()
        for (id, r) in tabRects {
            addToolTip(r, owner: tr("\(PanelRegistry.title(id)) — drag to move, drag out to float, double-click to collapse") as NSString, userData: nil)
        }
    }

    private func updateAccessibilityChildren() {
        tabElements = tabRects.map { t in
            let el = DockTabElement(panelID: t.id, bar: self)
            el.setAccessibilityFrameInParentSpace(t.rect)
            return el
        }
    }

    override func accessibilityChildren() -> [Any]? {
        var out: [Any] = tabElements
        out.append(menuButton)
        if !overflowButton.isHidden { out.append(overflowButton) }
        return out
    }

    override func accessibilityTabs() -> [Any]? { tabElements }
}

/// One tab, for VoiceOver.
final class DockTabElement: NSAccessibilityElement {
    let panelID: String
    weak var bar: DockTabBar?
    init(panelID: String, bar: DockTabBar) {
        self.panelID = panelID
        self.bar = bar
        super.init()
        setAccessibilityRole(.radioButton)
        setAccessibilityParent(bar)
        setAccessibilityLabel(PanelRegistry.title(panelID))
    }
    override func accessibilityLabel() -> String? { PanelRegistry.title(panelID) }   // (in the current interface language)
    override func accessibilityValue() -> Any? { NSNumber(value: bar?.group?.selected == panelID) }
    override func accessibilityPerformPress() -> Bool {
        WorkspaceManager.shared.select(panelID)
        return true
    }
}

// MARK: - Dividers

/// Drag to resize a column (the strip left of it) or to share height between two groups (the strip between them).
final class DockDividerView: NSView, DockChrome {
    enum Kind: Equatable {
        case column(String)
        case group(column: String, index: Int)
    }
    var kind: Kind { didSet { window?.invalidateCursorRects(for: self) } }
    var resizable = true { didSet { window?.invalidateCursorRects(for: self) } }
    private var start: (point: CGPoint, width: CGFloat, heights: [CGFloat], maxWidth: CGFloat)?
    private var hover = false
    private var trackingArea: NSTrackingArea?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        if case .column = kind { setAccessibilityLabel(tr("Resize panel column")) } else { setAccessibilityLabel(tr("Resize panel groups")) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var isColumn: Bool { if case .column = kind { return true }; return false }

    override func resetCursorRects() {
        guard resizable else { return }
        addCursorRect(bounds, cursor: isColumn ? .resizeLeftRight : .resizeUpDown)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard resizable, hover || start != nil else { return }
        DockColors.accent.withAlphaComponent(0.55).setFill()
        (isColumn ? CGRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height) : CGRect(x: 0, y: bounds.midY - 1, width: bounds.width, height: 2)).fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        guard resizable else { return }
        let ws = WorkspaceManager.shared
        switch kind {
        case .column(let cid):
            guard let c = ws.current.columns.first(where: { $0.id == cid }) else { return }
            let dockWidth = enclosingDock?.bounds.width ?? c.width
            let windowWidth = window?.contentView?.bounds.width ?? .infinity
            let maxW = windowWidth - DockMetrics.toolsWidth - DockMetrics.minCanvasWidth - (dockWidth - c.width)
            start = (dockScreenPoint(e), c.width, [], max(DockMetrics.minColumnWidth, maxW))
        case .group(let cid, _):
            guard let cv = superview as? DockColumnView, cv.columnID == cid else { return }
            start = (dockScreenPoint(e), 0, cv.laidOutHeights, 0)
        }
        ws.beginLive()
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard let s = start else { return }
        let p = dockScreenPoint(e)
        let ws = WorkspaceManager.shared
        switch kind {
        case .column(let cid):
            // the strip is left of its column: dragging left widens the column (the canvas gives up the room)
            ws.setColumnWidth(column: cid, min(s.width - (p.x - s.point.x), s.maxWidth))
        case .group(let cid, let i):
            // screen y grows upwards; dragging down gives the group above more room
            ws.resizeGroups(column: cid, divider: i, delta: s.point.y - p.y, actual: s.heights)
        }
    }

    override func mouseUp(with e: NSEvent) {
        guard start != nil else { return }
        start = nil
        needsDisplay = true
        WorkspaceManager.shared.endLive()
        WorkspaceManager.shared.returnFocusToCanvas()
    }

    private var enclosingDock: DockAreaView? {
        var v = superview
        while let x = v { if let d = x as? DockAreaView { return d }; v = x.superview }
        return nil
    }
}

// MARK: - Icon column

/// A column collapsed to icons: one button per panel (click shows the panel in a pop-over; drag moves it).
final class DockIconStrip: NSView {
    override var isFlipped: Bool { true }
    private var buttons: [DockIconButton] = []
    private var groupBreaks: [Int] = []
    private var column: DockColumn?

    func update(_ c: DockColumn) {
        let ids = c.groups.flatMap(\.panels)
        if column?.groups.map(\.panels) != c.groups.map(\.panels) {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = ids.map { DockIconButton(panelID: $0) }
            buttons.forEach { addSubview($0) }
            var n = 0
            groupBreaks = c.groups.dropLast().map { n += $0.panels.count; return n }
        }
        column = c
        buttons.forEach { $0.needsDisplay = true }
        needsLayout = true
    }

    func button(for id: String) -> DockIconButton? { buttons.first { $0.panelID == id } }

    override func layout() {
        super.layout()
        var y: CGFloat = 4
        for (i, b) in buttons.enumerated() {
            if groupBreaks.contains(i) { y += 9 }
            b.frame = CGRect(x: 3, y: y, width: bounds.width - 6, height: 30)
            y += 32
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        DockColors.panel.setFill()
        bounds.intersection(dirtyRect).fill()   // (since macOS 14 views don't clip to their bounds: a dirty rect can reach far outside)
        DockColors.border.setFill()
        var y: CGFloat = 4
        for i in buttons.indices {
            if groupBreaks.contains(i) { CGRect(x: 6, y: y + 3, width: bounds.width - 12, height: 1).fill(); y += 9 }
            y += 32
        }
    }
}

final class DockIconButton: NSView, DockChrome {
    override var isFlipped: Bool { true }
    let panelID: String
    private var hover = false
    private var press: (point: CGPoint, started: Bool)?
    private var trackingArea: NSTrackingArea?

    private let icon = NSImageView()

    init(panelID: String) {
        self.panelID = panelID
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: PanelRegistry.symbol(panelID), accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            ?? NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil)
        icon.imageScaling = .scaleNone
        icon.contentTintColor = DockColors.textDim
        icon.setAccessibilityElement(false)
        addSubview(icon)
        toolTip = PanelRegistry.title(panelID)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(PanelRegistry.title(panelID))
        setAccessibilityHelp(tr("Shows the \(PanelRegistry.title(panelID)) panel. Drag to move it."))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityPerformPress() -> Bool {
        DockFlyout.show(panelID, from: self)
        return true
    }

    private var isOpen: Bool { WorkspaceManager.shared.flyout?.panelID == panelID }

    override func draw(_ dirtyRect: NSRect) {
        if isOpen || hover {
            (isOpen ? DockColors.accent.withAlphaComponent(0.8) : DockColors.hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        icon.contentTintColor = isOpen ? .white : DockColors.textDim
    }

    override func layout() {
        super.layout()
        icon.frame = bounds
    }

    /// The symbol is a subview (drawn like a button image, tinted) that never takes the click.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) { press = (dockScreenPoint(e), false) }

    override func mouseDragged(with e: NSEvent) {
        guard var pr = press else { return }
        let m = dockScreenPoint(e)
        let ws = WorkspaceManager.shared
        if !pr.started {
            guard hypot(m.x - pr.point.x, m.y - pr.point.y) >= 4, let g = ws.current.group(containing: panelID) else { return }
            pr.started = true
            press = pr
            ws.closeFlyout()
            ws.drag?.cancel()
            ws.drag = DockDragSession(panels: [panelID], sourceGroup: g.id, wholeGroup: g.panels.count == 1, active: panelID, movingWindow: nil,
                                      start: pr.point, size: DockMetrics.defaultFloatSize)
        }
        ws.drag?.update(m, suppressDocking: e.modifierFlags.contains(.command))
    }

    override func mouseUp(with e: NSEvent) {
        let pr = press
        press = nil
        let ws = WorkspaceManager.shared
        if pr?.started == true, let s = ws.drag {
            ws.drag = nil
            s.finish(dockScreenPoint(e), suppressDocking: e.modifierFlags.contains(.command))
        } else if pr != nil {
            DockFlyout.show(panelID, from: self)
        }
        needsDisplay = true
    }
}

/// The pop-over that shows a panel of an icon column.
final class DockFlyout: NSObject, NSPopoverDelegate {
    let panelID: String
    let popover = NSPopover()
    private weak var button: NSView?
    var window: NSWindow? { popover.contentViewController?.view.window }

    init(panelID: String) { self.panelID = panelID }

    static func show(_ id: String, from button: NSView) {
        let ws = WorkspaceManager.shared
        if ws.flyout?.panelID == id { ws.closeFlyout(); button.needsDisplay = true; return }
        ws.closeFlyout()
        let f = DockFlyout(panelID: id)
        f.button = button
        let vc = NSViewController()
        let size = contentSize(for: id, screen: button.window?.screen?.visibleFrame)
        let container = DockGroupView(floating: true)
        container.frame = CGRect(origin: .zero, size: size)
        vc.view = container
        vc.preferredContentSize = size
        f.popover.contentViewController = vc
        f.popover.behavior = .transient
        f.popover.animates = false
        f.popover.delegate = f
        ws.flyout = f
        container.update(DockGroup([id], id: "flyout"))
        f.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minX)
        button.needsDisplay = true
    }

    /// The pop-over's size: 300 pt wide (more if the panel needs it), as tall as the panel's content (460 pt for panels
    /// that scroll their own lists), never taller than the screen leaves room for.
    static func contentSize(for id: String, screen: CGRect?) -> CGSize {
        let maxHeight = max(DockMetrics.minFloatSize.height, (screen?.height ?? 900) - 60)
        return PanelSizing.windowSize(id, base: CGSize(width: 300, height: 460), minHeight: DockMetrics.minFloatSize.height, maxHeight: min(720, maxHeight))
    }

    func close() { if popover.isShown { popover.performClose(nil) } }

    func popoverDidClose(_ notification: Notification) {
        let ws = WorkspaceManager.shared
        if ws.flyout === self { ws.flyout = nil }
        (popover.contentViewController?.view as? DockGroupView)?.content.show(nil)
        button?.needsDisplay = true
        ws.returnFocusToCanvas()
    }
}

// MARK: - SwiftUI bridge

/// The docked columns in the main window.
struct DockArea: NSViewRepresentable {
    var showSecondary: Bool
    var theme: InterfaceTheme

    func makeNSView(context: Context) -> DockAreaView {
        let v = DockAreaView(frame: .zero)
        v.showSecondary = showSecondary
        return v
    }

    static func dismantleNSView(_ v: DockAreaView, coordinator: Coordinator) { v.teardown() }

    func updateNSView(_ v: DockAreaView, context: Context) {
        v.showSecondary = showSecondary
        if context.coordinator.theme != theme {
            context.coordinator.theme = theme
            v.refreshTheme()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(theme: theme) }
    final class Coordinator {
        var theme: InterfaceTheme
        init(theme: InterfaceTheme) { self.theme = theme }
    }
}
