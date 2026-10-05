import AppKit
import ImageCratCore

/// What is pointing at the canvas (from tablet proximity events; a mouse or trackpad otherwise).
enum PointerKind: String {
    case mouse, pen, eraser, cursor
}

/// Turns AppKit mouse / tablet events into pen samples for the tools (Wacom, XP-Pen, Huion and Apple Pencil through
/// Sidecar all arrive as AppKit tablet events):
///  · pressure through the Preferences ▸ Tablet curve and clamp, tilt scaled by the tilt sensitivity, barrel
///    rotation, tangential pressure (airbrush wheel) and the pointing device;
///  · the pen lifting keeps its last pressure (the stroke tail tapers instead of jumping to full pressure);
///  · mouse coalescing is switched off during strokes so every tablet report (200+ per second) reaches the brush;
///  · flipping the pen to its eraser end switches to the Eraser and back;
///  · mouse fallback: full pressure, or Force Touch trackpad pressure when enabled.
final class TabletInput {
    static let shared = TabletInput()

    enum Phase { case down, drag, up, hover }

    struct Reading {
        var pressure: Double = 1
        var rawPressure: Double = 1
        var isTablet = false
        var tilt: CGPoint = .zero
        var rotation: Double = 0
        var tangential: Double = 0
        var pointer: PointerKind = .mouse
    }

    /// The device last reported by a proximity event.
    private(set) var device: PointerKind = .pen
    private(set) var inProximity = false
    /// Tool to restore when the pen tip comes back (set while the eraser end has switched tools).
    private(set) var penTool: ToolKind?
    /// Tool used by the eraser end (the user may pick another one while erasing; it is remembered).
    var eraserTool: ToolKind = .eraser
    private(set) var erasingByPen = false

    /// Zoom of the view being painted (string length of the smoothing is in screen pixels).
    var viewZoom: Double = 1
    /// Caps Lock state (replaceable by tests): precise cursor.
    var capsLock: () -> Bool = { NSEvent.modifierFlags.contains(.capsLock) }

    // Per stroke
    private var lastRaw: Double = 1
    private var filtered: (p: Double, tilt: CGPoint)?
    private var savedCoalescing: Bool?
    /// Force Touch trackpad pressure (stage 1: 0…1, stage 2 counts as 1).
    private(set) var forcePressure: Double?
    /// Force Touch pressure as a trackpad would report it (tests).
    func setForcePressure(_ p: Double?) { forcePressure = p }
    /// Samples delivered to the tools during the current / last stroke (tests, perf, the test area).
    private(set) var strokeSamples = 0
    private(set) var strokePressures: [Double] = []
    /// The latest reading (Preferences ▸ Tablet test area, status).
    private(set) var latest = Reading()

    private var monitors: [Any] = []

    private var prefs: TabletPrefs { TabletSettings.shared.prefs }

    // MARK: Events → readings

    static func isMouseEvent(_ e: NSEvent) -> Bool {
        switch e.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved: return true
        default: return false
        }
    }

    /// Whether the event carries tablet point data (a tablet-subtype mouse event or a native tablet point event).
    static func isTabletPoint(_ e: NSEvent) -> Bool {
        if e.type == .tabletPoint { return true }
        return isMouseEvent(e) && e.subtype == .tabletPoint
    }

    func reading(_ e: NSEvent, phase: Phase) -> Reading {
        var r = Reading()
        if TabletInput.isMouseEvent(e), e.subtype == .tabletProximity { handleProximity(e) }
        let tablet = TabletInput.isTabletPoint(e) || (TabletInput.isMouseEvent(e) && e.subtype == .tabletProximity)
        if tablet {
            r.isTablet = true
            r.pointer = device == .mouse ? .pen : device
            var raw = Double(e.pressure)
            switch phase {
            case .hover:
                r.pressure = 1; r.rawPressure = 0
                latest = r
                return r
            case .up:
                raw = lastRaw   // the pen left the surface: the stroke ends at the last pressure, not at 0 or 1
            case .down:
                filtered = nil
            case .drag:
                break
            }
            raw = raw.isFinite ? min(1, max(0, raw)) : 0
            var tilt = CGPoint.zero
            if TabletInput.isTabletPoint(e) {
                let k = CGFloat(max(0, prefs.tiltSensitivity))
                tilt = CGPoint(x: e.tilt.x * k, y: e.tilt.y * k)
                let len = tilt.length
                if len > 1 { tilt = tilt / len }
                r.rotation = Double(e.rotation)
                r.tangential = Double(e.tangentialPressure)
            }
            if prefs.smoothInput, phase == .drag, let f = filtered {
                raw = f.p + (raw - f.p) * 0.45
                tilt = f.tilt.lerp(tilt, 0.45)
            }
            if phase != .up { filtered = (raw, tilt); lastRaw = raw }
            r.rawPressure = raw
            r.pressure = prefs.curve.map(raw)
            r.tilt = tilt
        } else if prefs.forceTouchPressure, phase != .hover, let f = forcePressure {
            // Force Touch trackpad: click force as pressure (off by default — a click is full pressure otherwise)
            let raw = phase == .up ? lastRaw : f
            if phase != .up { lastRaw = raw }
            r.rawPressure = raw
            r.pressure = prefs.curve.map(raw)
        } else {
            r.pressure = 1; r.rawPressure = 1   // a mouse is a pen at full pressure
        }
        if phase != .hover { record(r) }
        latest = r
        return r
    }

    private func record(_ r: Reading) {
        strokeSamples += 1
        if strokePressures.count < 8192 { strokePressures.append(r.pressure) }
    }

    /// NSView.pressureChange(with:) of a Force Touch trackpad.
    func forceTouch(_ e: NSEvent) {
        guard e.type == .pressure else { return }
        forcePressure = e.stage >= 2 ? 1 : (e.stage <= 0 ? nil : Double(e.pressure))
    }

    // MARK: Strokes

    /// A stroke starts: mouse coalescing is turned off so no tablet sample is merged away (AppKit otherwise delivers
    /// only the newest drag position per run-loop pass, which drops the pressure ramps of fast strokes).
    func beginStroke(painting: Bool) {
        strokeSamples = 0
        strokePressures.removeAll(keepingCapacity: true)
        filtered = nil
        if painting, savedCoalescing == nil {
            savedCoalescing = NSEvent.isMouseCoalescingEnabled
            NSEvent.isMouseCoalescingEnabled = false
        }
    }

    func endStroke() {
        if let s = savedCoalescing { NSEvent.isMouseCoalescingEnabled = s; savedCoalescing = nil }
        forcePressure = nil
    }

    var isCoalescingSuspended: Bool { savedCoalescing != nil }

    // MARK: Proximity: pen ↔ eraser

    /// A tablet proximity event (the pen or its eraser end comes near the tablet or leaves it).
    func handleProximity(_ e: NSEvent) {
        let entering = e.isEnteringProximity
        inProximity = entering
        guard entering else { return }
        let kind: PointerKind
        switch e.pointingDeviceType {
        case .eraser: kind = .eraser
        case .cursor: kind = .cursor
        default: kind = .pen
        }
        device = kind
        pointerArrived(kind)
    }

    /// Switches to the eraser end's tool and back (Preferences ▸ Tablet ▸ Use pen eraser).
    func pointerArrived(_ kind: PointerKind) {
        let app = AppModel.shared
        if app.dialog != nil { return }
        if kind == .eraser {
            guard prefs.usePenEraser, !erasingByPen else { return }
            penTool = app.tool
            erasingByPen = true
            if app.tool != eraserTool { app.tool = eraserTool }
            app.setStatus("Pen eraser: \(eraserTool.displayName.replacingOccurrences(of: " Tool", with: ""))")
        } else if erasingByPen {
            // the user may have picked another tool for the eraser end meanwhile: it is remembered for next time
            if app.tool != .hand && app.tool != .zoom { eraserTool = app.tool }
            erasingByPen = false
            if let t = penTool, app.tool != t { app.tool = t }
            penTool = nil
        }
    }

    /// Back to the plain state (tests).
    func reset() {
        device = .pen; inProximity = false; penTool = nil; eraserTool = .eraser; erasingByPen = false
        lastRaw = 1; filtered = nil; forcePressure = nil; viewZoom = 1
        strokeSamples = 0; strokePressures = []
        if let s = savedCoalescing { NSEvent.isMouseCoalescingEnabled = s; savedCoalescing = nil }
    }

    /// App-wide proximity monitor: proximity events are delivered to whichever view is under the pen (or none), so
    /// the canvas also hears about the eraser end coming near over panels.
    func installMonitors() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.tabletProximity], handler: { e in
            TabletInput.shared.handleProximity(e)
            return e
        }) { monitors.append(m) }
    }
}
