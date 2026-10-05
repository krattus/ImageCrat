import AppKit
import ImageCratCore

/// On-canvas brush ergonomics (Photoshop): ⌃⌥-drag resizes the brush (horizontal) and changes its hardness
/// (vertical: up = softer) with a live circle; `[` `]`, `{` `}` and the number keys flash the new value there too.
final class BrushHUD {
    static let shared = BrushHUD()

    private(set) var isActive = false
    /// Gesture anchor (view coordinates): the circle stays here while you drag.
    private(set) var center: CGPoint = .zero
    private(set) var kind: ToolKind = .brush
    private var startSize = 0.0
    private var startHardness = 0.0
    /// A short-lived readout after a key changed the brush.
    private var flashText: String?
    private var flashUntil: CFTimeInterval = 0
    var now: () -> CFTimeInterval = CACurrentMediaTime

    /// Horizontal drag: diameter changes by twice the distance (the circle edge follows the pointer).
    static let hardnessPerPoint = 1.0 / 200

    // MARK: Gesture

    func beginGesture(_ te: ToolEvent, canvas: CanvasView) -> Bool {
        guard te.control, te.option, !te.command else { return false }
        let k = canvas.effectiveToolKind
        guard AppModel.hasBrush(k) || k == .quickSelect else { return false }
        kind = k
        center = te.view
        let (size, hardness) = BrushHUD.values(k)
        startSize = size; startHardness = hardness
        isActive = true
        return true
    }

    func update(_ te: ToolEvent, canvas: CanvasView) {
        guard isActive else { return }
        let dx = Double(te.view.x - center.x), dy = Double(te.view.y - center.y)
        let z = max(0.01, Double(canvas.zoom))
        let size = clamp((startSize + 2 * dx / z).rounded(), 1, 5000)
        let hardness = clamp(startHardness + dy * BrushHUD.hardnessPerPoint, 0, 1)
        BrushHUD.set(kind, size: size, hardness: hardness)
    }

    func endGesture() { isActive = false }

    // MARK: Values

    static func values(_ k: ToolKind) -> (size: Double, hardness: Double) {
        if k == .quickSelect { return (AppModel.shared.quickSelectSize, 1) }
        let s = AppModel.shared.brushSettings(for: k)
        return (s.size, s.hardness)
    }

    static func set(_ k: ToolKind, size: Double, hardness: Double) {
        let app = AppModel.shared
        if k == .quickSelect { app.quickSelectSize = clamp(size, 2, 500); return }
        var s = app.brushSettings(for: k)
        guard s.size != size || s.hardness != hardness else { return }
        s.size = size
        s.hardness = hardness
        app.setBrushSettings(s, for: k)
    }

    /// Shows `text` near the brush for a moment.
    func flash(_ text: String) {
        flashText = text
        flashUntil = now() + 0.9
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { AppActions.canvas?.overlay.needsDisplay = true }
        AppActions.canvas?.overlay.needsDisplay = true
    }

    var currentFlash: String? { now() < flashUntil ? flashText : nil }

    // MARK: Drawing

    func draw(_ ctx: CGContext, canvas: CanvasView) {
        if isActive {
            let (size, hardness) = BrushHUD.values(kind)
            let s = kind == .quickSelect ? nil : AppModel.shared.brushSettings(for: kind)
            BrushHUD.drawCircle(ctx, canvas: canvas, at: center, size: size, hardness: hardness, settings: s)
            let label = kind == .quickSelect ? "Ø \(Int(size)) px" : "Ø \(Int(size)) px   Hardness \(Int((hardness * 100).rounded()))%"
            BrushHUD.drawLabel(label, below: center, radius: CGFloat(size) * canvas.zoom / 2)
        } else if let t = currentFlash, let m = canvas.lastMouseView {
            BrushHUD.drawLabel(t, below: m, radius: CGFloat(BrushHUD.values(canvas.effectiveToolKind).size) * canvas.zoom / 2)
        }
    }

    /// The brush as a translucent red dab: solid core up to the hardness, soft falloff to the edge (Photoshop's
    /// resize preview), outlined with the tip shape.
    static func drawCircle(_ ctx: CGContext, canvas: CanvasView, at c: CGPoint, size: Double, hardness: Double, settings: BrushSettings?) {
        let r = max(1, CGFloat(size) * canvas.zoom / 2)
        ctx.saveGState()
        let h = CGFloat(clamp(hardness, 0, 1))
        let red = NSColor(calibratedRed: 1, green: 0.12, blue: 0.12, alpha: 1)
        let colors = [red.withAlphaComponent(0.5).cgColor, red.withAlphaComponent(0.5).cgColor, red.withAlphaComponent(0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, max(0.001, min(0.999, h)), 1]) {
            ctx.saveGState()
            if let s = settings, s.roundness < 0.999 || s.tipID != "round" {
                ctx.addPath(BrushCursor.outline(s, size: size, hardness: 1, full: true, canvas: canvas, at: c))
                ctx.clip()
            }
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
            ctx.restoreGState()
        }
        let outline = settings.map { BrushCursor.outline($0, size: size, hardness: 1, full: true, canvas: canvas, at: c) }
            ?? CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
        OverlayStyle.contrastStroke(ctx, outline)
        if h < 0.999 {   // where the hardness ends
            let hr = max(0.5, r * h)
            OverlayStyle.contrastStroke(ctx, CGPath(ellipseIn: CGRect(x: c.x - hr, y: c.y - hr, width: 2 * hr, height: 2 * hr), transform: nil), dashed: true)
        }
        ctx.restoreGState()
    }

    static func drawLabel(_ text: String, below c: CGPoint, radius: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        let r = CGRect(x: c.x - sz.width / 2 - 7, y: c.y + min(radius, 400) + 10, width: sz.width + 14, height: sz.height + 6)
        NSColor(white: 0.08, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        s.draw(at: CGPoint(x: r.minX + 7, y: r.minY + 3))
    }
}

/// Keyboard shortcuts for brushes (routed by `KeyRouter`).
enum BrushKeys {
    /// The first digit of a possible two-digit value (Photoshop: type 4 5 quickly for 45%).
    private static var pending: (digit: Int, at: CFTimeInterval, flow: Bool)?
    static var now: () -> CFTimeInterval = CACurrentMediaTime
    static let twoDigitWindow: CFTimeInterval = 0.8

    static func digit(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 29, 82: return 0
        case 18, 83: return 1
        case 19, 84: return 2
        case 20, 85: return 3
        case 21, 86: return 4
        case 23, 87: return 5
        case 22, 88: return 6
        case 26, 89: return 7
        case 28, 91: return 8
        case 25, 92: return 9
        default: return nil
        }
    }

    /// Number keys set the opacity (1 = 10% … 0 = 100%, two quick digits = that exact value, 0 0 = 0%), with Shift the
    /// flow. Returns false when the key isn't a digit or the tool has no brush.
    static func handleDigit(_ e: NSEvent) -> Bool {
        guard let n = digit(e.keyCode) else { return false }
        let app = AppModel.shared
        let k = app.tool
        guard AppModel.hasBrush(k) || k.isPainting || k == .gradient else { return false }
        let flow = e.modifierFlags.contains(.shift) && k != .gradient
        let t = now()
        var value: Double
        if let p = pending, p.flow == flow, t - p.at < twoDigitWindow {
            value = Double(p.digit * 10 + n) / 100
            pending = nil
        } else {
            value = n == 0 ? 1 : Double(n) / 10
            pending = (n, t, flow)
        }
        if k == .gradient {
            app.gradientTool.opacity = value
            BrushHUD.shared.flash("Opacity \(Int((value * 100).rounded()))%")
            return true
        }
        var s = app.activeBrushSettings
        if flow { s.flow = max(0.01, value) } else { s.opacity = value }
        app.activeBrushSettings = s
        BrushHUD.shared.flash(flow ? "Flow \(Int((s.flow * 100).rounded()))%" : "Opacity \(Int((value * 100).rounded()))%")
        return true
    }

    /// Forgets a half-typed two-digit value (tests).
    static func reset() { pending = nil }

    /// `[` `]` size, `{` `}` (Shift) hardness in 25% steps.
    static func handleBrackets(_ e: NSEvent) -> Bool {
        guard let ch = e.charactersIgnoringModifiers else { return false }
        let app = AppModel.shared
        var s = app.activeBrushSettings
        switch ch {
        case "]": s.size = nextSize(s.size, up: true)
        case "[": s.size = nextSize(s.size, up: false)
        case "}": s.hardness = min(1, ((s.hardness + 0.25) * 4).rounded(.down) / 4)
        case "{": s.hardness = max(0, ((s.hardness - 0.25) * 4).rounded(.up) / 4)
        default: return false
        }
        app.activeBrushSettings = s
        BrushHUD.shared.flash(ch == "[" || ch == "]" ? "Ø \(Int(s.size.rounded())) px" : "Hardness \(Int((s.hardness * 100).rounded()))%")
        return true
    }

    /// Photoshop-like steps: 1 px below 10, 5 px to 100, then 15% per press.
    static func nextSize(_ v: Double, up: Bool) -> Double {
        if up { return min(5000, v < 10 ? v + 1 : v < 100 ? v + 5 : v * 1.15) }
        return max(1, v <= 10 ? v - 1 : v <= 100 ? v - 5 : v / 1.15)
    }
}
