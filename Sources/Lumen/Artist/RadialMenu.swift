import AppKit
import SwiftUI
import ImageCratCore

// Radial quick menu (pie menu): hold the trigger key to pop it up at the cursor, move to a slice, release to choose.
//  · middle ring: 8 favourite tools (Preferences ▸ Radial Menu)
//  · inner ring: recent colours
//  · outer ring: Undo / Flip View / Redo (top), Swap Colours / Fit / Assist (bottom)
//  · left and right of the ring: brush size and opacity scrubbers — move outward to raise the value

enum PieAction: String, CaseIterable {
    case undo, flipView, redo, swapColors, fit, assist

    var title: String {
        switch self {
        case .undo: return "Undo"
        case .flipView: return "Flip View"
        case .redo: return "Redo"
        case .swapColors: return "Swap Colours"
        case .fit: return "Fit on Screen"
        case .assist: return "Assisted Drawing"
        }
    }
    var symbol: String {
        switch self {
        case .undo: return "arrow.uturn.backward"
        case .flipView: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .redo: return "arrow.uturn.forward"
        case .swapColors: return "arrow.left.arrow.right"
        case .fit: return "arrow.up.left.and.arrow.down.right"
        case .assist: return "ruler"
        }
    }
}

enum PieHit: Equatable {
    /// Centre dead zone: releasing here changes nothing.
    case cancel
    case tool(Int)
    case color(Int)
    case action(PieAction)
    /// Scrubbers, 0…1 along the gauge.
    case size(Double)
    case opacity(Double)
    case outside
}

/// Geometry and hit testing. Points are relative to the menu centre with y pointing up; angles are degrees
/// counter-clockwise from the positive x axis.
struct PieGeometry: Equatable {
    var dead: CGFloat = 24
    var colorOuter: CGFloat = 58
    var toolOuter: CGFloat = 138
    var ringOuter: CGFloat = 172
    var scrubLength: CGFloat = 150
    var colorCount = 8
    var showColors = true
    var showScrubbers = true
    var showActions = true

    static let topActions: [PieAction] = [.undo, .flipView, .redo]
    static let bottomActions: [PieAction] = [.swapColors, .fit, .assist]
    static let minSize = 1.0, maxSize = 500.0

    /// Half size of the square that contains the whole menu.
    var extent: CGFloat { toolOuter + scrubLength + 28 }

    static func angle(_ v: CGPoint) -> Double {
        var a = Double(atan2(v.y, v.x)) * 180 / .pi
        if a < 0 { a += 360 }
        return a
    }

    /// Centre angle of tool slice `i` (slice 0 is at the top, then clockwise).
    static func toolAngle(_ i: Int) -> Double { ColorHarmony.normHue(90 - Double(i) * 45) }

    func colorAngle(_ i: Int) -> Double { ColorHarmony.normHue(90 - Double(i) * 360 / Double(max(1, colorCount))) }

    static func size(forT t: Double) -> Double {
        let v = minSize * pow(maxSize / minSize, clamp(t, 0, 1))
        return v < 20 ? v.rounded() : (v / 5).rounded() * 5
    }
    static func t(forSize s: Double) -> Double { clamp(log(max(minSize, s) / minSize) / log(maxSize / minSize), 0, 1) }
    static func opacity(forT t: Double) -> Double { max(0.01, (clamp(t, 0, 1) * 100).rounded() / 100) }

    func hit(_ v: CGPoint) -> PieHit {
        let r = v.length
        let a = PieGeometry.angle(v)
        if r < dead { return .cancel }
        if r < colorOuter {
            guard showColors, colorCount > 0 else { return .cancel }
            let step = 360 / Double(colorCount)
            return .color(Int(ColorHarmony.normHue(90 - a + step / 2) / step) % colorCount)
        }
        if r <= toolOuter { return .tool(Int(ColorHarmony.normHue(90 - a + 22.5) / 45) % 8) }
        // outer zone
        if a > 45 && a < 135 {
            guard showActions, r <= ringOuter + 26 else { return .outside }
            return .action(PieGeometry.topActions[min(2, Int((135 - a) / 30))])
        }
        if a > 225 && a < 315 {
            guard showActions, r <= ringOuter + 26 else { return .outside }
            return .action(PieGeometry.bottomActions[min(2, Int((a - 225) / 30))])
        }
        guard showScrubbers else { return .outside }
        let t = Double(clamp((r - toolOuter) / scrubLength, 0, 1))
        return (a >= 135 && a <= 225) ? .size(t) : .opacity(t)
    }
}

/// What the menu shows.
struct PieDisplay {
    var geometry = PieGeometry()
    var tools: [ToolKind] = PieConfig().toolKinds
    var colors: [RGBA] = []
    var hover: PieHit = .cancel
    var currentTool: ToolKind = .brush
    var brushSize: Double = 30
    var brushOpacity: Double = 1
    var foreground: RGBA = .black
    var assistOn = true
}

enum PieRenderer {
    private static func wedge(_ r0: CGFloat, _ r1: CGFloat, _ a0: Double, _ a1: Double) -> CGPath {
        let p = CGMutablePath()
        let s = CGFloat(a0 * .pi / 180), e = CGFloat(a1 * .pi / 180)
        p.addArc(center: .zero, radius: r1, startAngle: s, endAngle: e, clockwise: false)
        p.addArc(center: .zero, radius: r0, startAngle: e, endAngle: s, clockwise: true)
        p.closeSubpath()
        return p
    }

    private static func polar(_ r: CGFloat, _ deg: Double) -> CGPoint {
        CGPoint(x: r * CGFloat(cos(deg * .pi / 180)), y: r * CGFloat(sin(deg * .pi / 180)))
    }

    private static func symbol(_ name: String, at p: CGPoint, size: CGFloat, color: NSColor) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium).applying(.init(paletteColors: [color]))
        guard let img = (NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil))?
            .withSymbolConfiguration(cfg) else { return }
        let s = img.size
        img.draw(in: CGRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height))
    }

    private static func text(_ t: String, at p: CGPoint, size: CGFloat = 10, weight: NSFont.Weight = .medium, color: NSColor = .white) {
        let s = NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        let sz = s.size()
        s.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
    }

    static func shortName(_ k: ToolKind) -> String {
        k.displayName.replacingOccurrences(of: " Tool", with: "").replacingOccurrences(of: "Rectangular ", with: "").replacingOccurrences(of: "Elliptical ", with: "")
    }

    /// Draws the menu centred on the origin of `ctx` (y up). `NSGraphicsContext.current` must wrap `ctx`.
    static func draw(_ ctx: CGContext, _ d: PieDisplay) {
        let g = d.geometry
        let accent = NSColor(calibratedRed: 0.12, green: 0.5, blue: 0.95, alpha: 0.95)
        let base = NSColor(white: 0.13, alpha: 0.9)
        let line = NSColor(white: 1, alpha: 0.16)

        // tool ring
        for i in 0..<8 {
            let c = PieGeometry.toolAngle(i)
            let w = wedge(g.colorOuter + 2, g.toolOuter, c - 22.5, c + 22.5)
            let hovered = d.hover == .tool(i)
            ctx.addPath(w)
            ctx.setFillColor((hovered ? accent : base).cgColor)
            ctx.fillPath()
            ctx.addPath(w)
            ctx.setStrokeColor(line.cgColor); ctx.setLineWidth(1)
            ctx.strokePath()
            let k = i < d.tools.count ? d.tools[i] : .brush
            let mid = (g.colorOuter + g.toolOuter) / 2
            let active = k == d.currentTool
            // icon above its label, both upright whatever the slice direction
            let at = polar(mid + 2, c)
            symbol(k.symbol, at: CGPoint(x: at.x, y: at.y + 9), size: 17, color: hovered || active ? .white : NSColor(white: 0.85, alpha: 1))
            text(shortName(k), at: CGPoint(x: at.x, y: at.y - 12), size: 9, weight: active ? .bold : .regular, color: NSColor(white: 1, alpha: hovered || active ? 1 : 0.7))
            if active && !hovered {
                ctx.addPath(wedge(g.toolOuter - 3, g.toolOuter, c - 22.5, c + 22.5))
                ctx.setFillColor(accent.cgColor); ctx.fillPath()
            }
        }

        // colour ring
        if g.showColors && g.colorCount > 0 {
            let step = 360 / Double(g.colorCount)
            for i in 0..<g.colorCount {
                let c = g.colorAngle(i)
                let hovered = d.hover == .color(i)
                let w = wedge(g.dead + 2, g.colorOuter + (hovered ? 5 : 0), c - step / 2 + 1, c + step / 2 - 1)
                ctx.addPath(w)
                ctx.setFillColor((i < d.colors.count ? d.colors[i] : RGBA(gray: 0.3)).withAlpha(1).cgColor)
                ctx.fillPath()
                ctx.addPath(w)
                ctx.setStrokeColor((hovered ? NSColor.white : NSColor(white: 0, alpha: 0.5)).cgColor)
                ctx.setLineWidth(hovered ? 2 : 1)
                ctx.strokePath()
            }
        }

        // centre: current foreground, or a cancel cross
        let cr = g.dead - 2
        ctx.setFillColor(d.foreground.withAlpha(1).cgColor)
        ctx.fillEllipse(in: CGRect(x: -cr, y: -cr, width: 2 * cr, height: 2 * cr))
        ctx.setStrokeColor(NSColor(white: d.hover == .cancel ? 1 : 0, alpha: 0.8).cgColor)
        ctx.setLineWidth(d.hover == .cancel ? 2 : 1)
        ctx.strokeEllipse(in: CGRect(x: -cr, y: -cr, width: 2 * cr, height: 2 * cr))

        // outer actions
        if g.showActions {
            func row(_ acts: [PieAction], _ start: Double, _ dir: Double) {
                for (i, a) in acts.enumerated() {
                    let a0 = start + dir * Double(i) * 30, a1 = a0 + dir * 30
                    let lo = min(a0, a1) + 1, hi = max(a0, a1) - 1
                    let hovered = d.hover == .action(a)
                    let on = a == .assist && d.assistOn
                    let w = wedge(g.toolOuter + 4, g.ringOuter, lo, hi)
                    ctx.addPath(w)
                    ctx.setFillColor((hovered ? accent : (on ? NSColor(calibratedRed: 0.1, green: 0.32, blue: 0.55, alpha: 0.92) : base)).cgColor)
                    ctx.fillPath()
                    ctx.addPath(w)
                    ctx.setStrokeColor(line.cgColor); ctx.setLineWidth(1); ctx.strokePath()
                    symbol(a.symbol, at: polar((g.toolOuter + 4 + g.ringOuter) / 2, (lo + hi) / 2), size: 13, color: .white)
                    if hovered { text(a.title, at: polar(g.ringOuter + 16, (lo + hi) / 2), size: 11, weight: .semibold) }
                }
            }
            row(PieGeometry.topActions, 135, -1)
            row(PieGeometry.bottomActions, 225, 1)
        }

        // scrubbers
        if g.showScrubbers {
            func gauge(_ center: Double, _ t: Double, _ hovered: Bool, _ label: String) {
                let r0 = g.toolOuter + 4, r1 = g.toolOuter + g.scrubLength
                let bg = wedge(r0, r1, center - 17, center + 17)
                ctx.addPath(bg)
                ctx.setFillColor(NSColor(white: 0.13, alpha: hovered ? 0.92 : 0.7).cgColor)
                ctx.fillPath()
                ctx.addPath(wedge(r0, r0 + (r1 - r0) * CGFloat(clamp(t, 0, 1)), center - 17, center + 17))
                ctx.setFillColor((hovered ? accent : NSColor(white: 0.55, alpha: 0.85)).cgColor)
                ctx.fillPath()
                ctx.addPath(bg)
                ctx.setStrokeColor(line.cgColor); ctx.setLineWidth(1); ctx.strokePath()
                // ticks at quarters
                for q in 1...3 {
                    let r = r0 + (r1 - r0) * CGFloat(q) / 4
                    ctx.addPath(wedge(r, r + 0.5, center - 17, center + 17))
                }
                ctx.setFillColor(NSColor(white: 1, alpha: 0.25).cgColor); ctx.fillPath()
                text(label, at: polar(r1 + 14, center), size: 11, weight: .semibold)
            }
            let sizeHover: Bool, opHover: Bool
            if case .size = d.hover { sizeHover = true } else { sizeHover = false }
            if case .opacity = d.hover { opHover = true } else { opHover = false }
            gauge(180, PieGeometry.t(forSize: d.brushSize), sizeHover, "")
            gauge(0, d.brushOpacity, opHover, "")
            // labels sit above the gauges so they never clip at the window edge
            let ly = (g.toolOuter + g.scrubLength) * CGFloat(sin(17 * Double.pi / 180)) + 12
            text("Size \(Int(d.brushSize.rounded())) px", at: CGPoint(x: -(g.toolOuter + g.scrubLength / 2), y: ly), size: 11, weight: .semibold)
            text("Opacity \(Int((d.brushOpacity * 100).rounded()))%", at: CGPoint(x: g.toolOuter + g.scrubLength / 2, y: ly), size: 11, weight: .semibold)
        }
    }

    /// Offscreen render (tests, previews).
    static func image(_ d: PieDisplay) -> NSBitmapImageRep? {
        let side = Int(d.geometry.extent * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        let ctx = g.cgContext
        ctx.setFillColor(NSColor(white: 0.32, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.translateBy(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        draw(ctx, d)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

final class PieView: NSView {
    var display = PieDisplay() { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        PieRenderer.draw(ctx, display)
    }
}

final class RadialMenuController {
    static let shared = RadialMenuController()

    private(set) var isOpen = false
    private var panel: NSPanel?
    private var view: PieView?
    private var timer: Timer?
    private var monitor: Any?
    private var center: CGPoint = .zero
    private var hover: PieHit = .cancel
    private var original: (size: Double, opacity: Double) = (30, 1)
    private var clickedAction = false
    private var openedAt: TimeInterval = 0

    /// Colours of the inner ring: recent colours, padded with foreground / background.
    static func colors(_ app: AppModel) -> [RGBA] {
        var c = Array(app.recentColors.prefix(8))
        for extra in [app.foreground, app.background] where c.count < 2 && !c.contains(extra) { c.append(extra) }
        return c
    }

    static func display(_ app: AppModel, hover: PieHit) -> PieDisplay {
        let cfg = ArtistSettings.shared.pie
        var d = PieDisplay()
        d.colors = colors(app)
        d.geometry.colorCount = d.colors.count
        d.geometry.showColors = cfg.showColors
        d.geometry.showScrubbers = cfg.showScrubbers
        d.geometry.showActions = cfg.showActions
        d.tools = cfg.toolKinds
        d.hover = hover
        d.currentTool = app.tool
        d.brushSize = app.activeBrushSettings.size
        d.brushOpacity = app.activeBrushSettings.opacity
        d.foreground = app.foreground
        d.assistOn = ArtistSettings.shared.assist
        return d
    }

    /// Applies a released / clicked slice. Scrubbers are applied live and need nothing here.
    static func perform(_ hit: PieHit, app: AppModel = .shared) {
        switch hit {
        case .tool(let i):
            let tools = ArtistSettings.shared.pie.toolKinds
            if tools.indices.contains(i) { app.tool = tools[i] }
        case .color(let i):
            let c = colors(app)
            if c.indices.contains(i) { app.foreground = c[i] }
        case .action(let a):
            switch a {
            case .undo: AppActions.undo()
            case .redo: AppActions.redo()
            case .flipView: ArtistView.toggleFlip()
            case .swapColors: app.swapColors()
            case .fit: AppActions.fitOnScreen()
            case .assist:
                ArtistSettings.shared.assist.toggle()
                ArtistModule.status("Assisted drawing", ArtistSettings.shared.assist)
            }
        case .size, .opacity, .cancel, .outside:
            break
        }
    }

    /// Live scrubbing: sets the brush size / opacity for a hit, restoring the values the menu opened with otherwise.
    static func applyScrub(_ hit: PieHit, original: (size: Double, opacity: Double), app: AppModel = .shared) {
        var s = app.activeBrushSettings
        switch hit {
        case .size(let t): s.size = PieGeometry.size(forT: t); s.opacity = original.opacity
        case .opacity(let t): s.opacity = PieGeometry.opacity(forT: t); s.size = original.size
        default: s.size = original.size; s.opacity = original.opacity
        }
        if s != app.activeBrushSettings { app.activeBrushSettings = s }
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown]) { [weak self] e in
            guard let self else { return e }
            return self.handle(e) ? nil : e
        }
    }

    private var canOpen: Bool {
        let app = AppModel.shared
        guard ArtistSettings.shared.pie.enabled, app.dialog == nil, !app.textEditingActive,
              let canvas = AppActions.canvas, canvas.document != nil, let win = canvas.window, win.isKeyWindow else { return false }
        if win.firstResponder is NSText { return false }
        return true
    }

    private func handle(_ e: NSEvent) -> Bool {
        let code = ArtistSettings.shared.pie.trigger.keyCode
        switch e.type {
        case .keyDown:
            if isOpen {
                if e.keyCode == 53 { close(commit: false) }       // Esc cancels
                return true                                        // swallow every key while the menu is up
            }
            guard e.keyCode == code, e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty, !e.isARepeat, canOpen else { return false }
            open()
            return true
        case .keyUp:
            guard isOpen, e.keyCode == code else { return false }
            close(commit: true)
            return true
        case .leftMouseDown, .rightMouseDown:
            guard isOpen else { return false }
            if case .action = hover { RadialMenuController.perform(hover); clickedAction = true; refresh() }
            return true
        case .leftMouseUp:
            return isOpen
        default:
            return false
        }
    }

    func open() {
        guard !isOpen else { return }
        let app = AppModel.shared
        isOpen = true
        clickedAction = false
        hover = .cancel
        center = NSEvent.mouseLocation
        openedAt = ProcessInfo.processInfo.systemUptime
        original = (app.activeBrushSettings.size, app.activeBrushSettings.opacity)
        let disp = RadialMenuController.display(app, hover: .cancel)
        let side = disp.geometry.extent * 2
        let frame = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        let v = PieView(frame: CGRect(origin: .zero, size: frame.size))
        v.display = disp
        p.contentView = v
        p.orderFrontRegardless()
        panel = p
        view = v
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        view?.display = RadialMenuController.display(AppModel.shared, hover: hover)
    }

    private func tick() {
        guard isOpen else { return }
        let m = NSEvent.mouseLocation
        let disp = RadialMenuController.display(AppModel.shared, hover: hover)
        let h = disp.geometry.hit(CGPoint(x: m.x - center.x, y: m.y - center.y))
        if h != hover {
            if case .action = h {} else { clickedAction = false }
            hover = h
            RadialMenuController.applyScrub(h, original: original)
            refresh()
            AppActions.canvas?.overlay.needsDisplay = true
        }
        // Fail-safe: the key-up can be swallowed by another key handler, so also watch the physical key.
        let code = CGKeyCode(ArtistSettings.shared.pie.trigger.keyCode)
        if ProcessInfo.processInfo.systemUptime - openedAt > 0.15, !CGEventSource.keyState(.combinedSessionState, key: code) {
            close(commit: true)
        }
    }

    func close(commit: Bool) {
        guard isOpen else { return }
        isOpen = false
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); panel = nil; view = nil
        if commit {
            if case .action = hover, clickedAction {} else { RadialMenuController.perform(hover) }
        } else {
            RadialMenuController.applyScrub(.cancel, original: original)
        }
        AppActions.canvas?.overlay.needsDisplay = true
    }
}

// MARK: - Preferences ▸ Radial Menu

struct RadialMenuPreferencesSection: View {
    @Bindable var settings = ArtistSettings.shared
    private let directions = ["Top", "Top right", "Right", "Bottom right", "Bottom", "Bottom left", "Left", "Top left"]
    private static let allTools: [ToolKind] = ToolKind.allCases.sorted { $0.displayName < $1.displayName }

    var body: some View {
        Toggle2(label: "Enable the radial quick menu", on: $settings.prefs.pie.enabled)
        Picker("Hold key", selection: $settings.prefs.pie.trigger) { ForEach(PieTriggerKey.allCases) { Text($0.title).tag($0) } }
        Caption("Favourite tools")
        ForEach(0..<8, id: \.self) { i in
            Picker(directions[i], selection: Binding(get: { settings.prefs.pie.tools[i] }, set: { settings.prefs.pie.tools[i] = $0 })) {
                ForEach(RadialMenuPreferencesSection.allTools) { k in Text(PieRenderer.shortName(k)).tag(k.rawValue) }
            }
        }
        HStack(spacing: 12) {
            Toggle2(label: "Recent colours", on: $settings.prefs.pie.showColors)
            Toggle2(label: "Size / opacity", on: $settings.prefs.pie.showScrubbers)
            Toggle2(label: "Actions", on: $settings.prefs.pie.showActions)
        }
        HStack {
            Button("Reset Radial Menu") { settings.prefs.pie = PieConfig() }.buttonStyle(PanelButtonStyle())
            Text("Hold the key, move to a slice, release.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
    }
}
