import AppKit
import SwiftUI
import ImageCratCore

/// Synthetic tablet events: real `NSEvent`s built from `CGEvent`s with the tablet fields set (subtype tablet point,
/// pressure, tilt, rotation, tangential pressure; proximity events with a pointing device type), as a Wacom / XP-Pen /
/// Huion driver or Sidecar would send them.
enum TabletEvents {
    nonisolated(unsafe) static var eventNumber = 0

    static func mouse(_ type: NSEvent.EventType, view p: CGPoint, canvas: NSView, pressure: Double, tilt: CGPoint = .zero,
                      rotation: Double = 0, tangential: Double = 0, mods: NSEvent.ModifierFlags = [], tablet: Bool = true,
                      clicks: Int = 1) -> NSEvent {
        eventNumber += 1
        let w = canvas.convert(p, to: nil)
        let base = NSEvent.mouseEvent(with: type, location: w, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: eventNumber,
                                      clickCount: clicks, pressure: Float(tablet ? pressure : (type == .leftMouseUp ? 0 : 1)))!
        guard tablet, let cg = base.cgEvent?.copy() else { return base }
        cg.setIntegerValueField(.mouseEventSubtype, value: 1)   // NX_SUBTYPE_TABLET_POINT
        cg.setDoubleValueField(.mouseEventPressure, value: pressure)
        cg.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        cg.setDoubleValueField(.tabletEventTiltX, value: Double(tilt.x))
        cg.setDoubleValueField(.tabletEventTiltY, value: Double(tilt.y))
        cg.setDoubleValueField(.tabletEventRotation, value: rotation)
        cg.setDoubleValueField(.tabletEventTangentialPressure, value: tangential)
        return NSEvent(cgEvent: cg) ?? base
    }

    /// A tablet proximity event (`.pen` / `.eraser` / `.cursor` coming near or leaving).
    static func proximity(_ device: NSEvent.PointingDeviceType, entering: Bool) -> NSEvent? {
        guard let cg = CGEvent(source: nil) else { return nil }
        cg.type = CGEventType(rawValue: 24)!   // kCGEventTabletProximity
        cg.setIntegerValueField(.tabletProximityEventPointerType, value: Int64(device.rawValue))
        cg.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        cg.setIntegerValueField(.tabletProximityEventDeviceID, value: 7)
        return NSEvent(cgEvent: cg)
    }
}

/// `LUMEN_SELFTEST_ONLY=tablet .build/debug/Lumen --selftest <dir>`: drawing-tablet input and brush ergonomics through
/// the real canvas event path (pressure, tilt, rotation, wheel, eraser end, curve, smoothing, coalescing, keys, HUD,
/// quick picker, per-tool brushes). PNGs of the strokes go to `<dir>`.
enum TabletSelfTest {
    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
        if ok { passes += 1; print("PASS tablet: \(msg())") } else { failures += 1; print("FAIL tablet: \(msg())") }
    }

    static func register() {
        FeatureModules.selfTests.append(("tablet", { out in run(out) }))
    }

    // MARK: Harness

    final class Rig {
        let robot = ToolRobot(size: CGSize(width: 900, height: 640))
        var doc: Document!
        var paintID = UUID()
        var canvas: CanvasView { robot.canvas }
        /// Every rig of the run (their documents are let go when the suite ends: `ToolRobot` keeps its canvas alive
        /// for the rest of the process, and a long full run must not keep every test document's pixels with it).
        nonisolated(unsafe) static var all: [Rig] = []

        static func releaseAll() {
            for r in all {
                if r.canvas.document === r.doc { r.canvas.document = nil }
                if let d = r.doc { MemoryHygiene.documentClosed(d) }
                r.doc = nil
            }
            all.removeAll()
        }

        init(width: Int = 760, height: Int = 520, background: RGBA = .white) {
            defer { Rig.all.append(self) }
            var st = DocumentState(width: width, height: height)
            let bg = PixelBuffer(width: width, height: height)
            bg.context.setFillColor(background.cgColor)
            bg.context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            bg.markDirty()
            let paint = Layer.raster(name: "Paint", width: width, height: height)
            paintID = paint.id
            st.layers = [Layer.raster(name: "Background", buffer: bg), paint]
            doc = robot.open(st, name: "tablet", view: QAView(name: "z1", zoom: 1, offset: CGPoint(x: 60, y: 50)), active: paint.id)
        }

        func v(_ p: CGPoint) -> CGPoint { canvas.docToView(p) }

        func down(_ p: CGPoint, _ pr: Double, tilt: CGPoint = .zero, rot: Double = 0, wheel: Double = 0, mods: NSEvent.ModifierFlags = [], tablet: Bool = true) {
            ToolRobot.buttonDown = true
            canvas.mouseDown(with: TabletEvents.mouse(.leftMouseDown, view: v(p), canvas: canvas, pressure: pr, tilt: tilt, rotation: rot, tangential: wheel, mods: mods, tablet: tablet))
        }
        func drag(_ p: CGPoint, _ pr: Double, tilt: CGPoint = .zero, rot: Double = 0, wheel: Double = 0, mods: NSEvent.ModifierFlags = [], tablet: Bool = true) {
            canvas.mouseDragged(with: TabletEvents.mouse(.leftMouseDragged, view: v(p), canvas: canvas, pressure: pr, tilt: tilt, rotation: rot, tangential: wheel, mods: mods, tablet: tablet))
        }
        func up(_ p: CGPoint, _ pr: Double = 0, tilt: CGPoint = .zero, rot: Double = 0, wheel: Double = 0, mods: NSEvent.ModifierFlags = [], tablet: Bool = true) {
            canvas.mouseUp(with: TabletEvents.mouse(.leftMouseUp, view: v(p), canvas: canvas, pressure: pr, tilt: tilt, rotation: rot, tangential: wheel, mods: mods, tablet: tablet))
            ToolRobot.buttonDown = false
        }

        /// A stroke from a to b in `steps` drags with pressure from p0 to p1 (the pen lifts with pressure 0).
        func stroke(_ a: CGPoint, _ b: CGPoint, steps: Int = 40, p0: Double, p1: Double, tilt: CGPoint = .zero, rot: Double = 0, wheel: Double = 0,
                    mods: NSEvent.ModifierFlags = [], tablet: Bool = true) {
            down(a, p0, tilt: tilt, rot: rot, wheel: wheel, mods: mods, tablet: tablet)
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                drag(a.lerp(b, CGFloat(t)), p0 + (p1 - p0) * t, tilt: tilt, rot: rot, wheel: wheel, tablet: tablet)
            }
            up(b, 0, tilt: tilt, rot: rot, wheel: wheel, tablet: tablet)
        }

        func dab(_ p: CGPoint, _ pr: Double = 1, tilt: CGPoint = .zero, rot: Double = 0, wheel: Double = 0, tablet: Bool = true) {
            down(p, pr, tilt: tilt, rot: rot, wheel: wheel, tablet: tablet)
            up(p, pr, tilt: tilt, rot: rot, wheel: wheel, tablet: tablet)
        }

        /// Paint layer pixels (document coordinates).
        var paint: (buf: PixelBuffer, origin: IPoint) {
            let r = doc.state.layer(paintID)!.raster!
            return (r.buffer, r.origin)
        }
        func alpha(_ x: Int, _ y: Int) -> Int {
            let (b, o) = paint
            return Int(b.pixel(x - o.x, y - o.y).3)
        }
        /// Painted pixels (alpha ≥ `thr`) in column `x` between rows y0..<y1.
        func thickness(x: Int, y0: Int, y1: Int, thr: Int = 100) -> Int {
            (y0..<y1).reduce(0) { $0 + (alpha(x, $1) >= thr ? 1 : 0) }
        }
        func maxAlpha(x: Int, y0: Int, y1: Int) -> Int { (y0..<y1).map { alpha(x, $0) }.max() ?? 0 }
        /// Rightmost painted column in rows y0..<y1 of what the user sees (the live stroke preview included).
        func extentX(y0: Int, y1: Int) -> Int {
            let b = robot.liveComposite()
            var best = -1
            for y in y0..<y1 { for x in 0..<b.width where Int(b.pixel(x, y).0) < 128 { best = max(best, x) } }
            return best
        }
        /// Orientation (degrees, counter-clockwise on screen, 0…180) and elongation of the paint in a box.
        func orientation(_ r: CGRect, thr: Int = 64) -> (angle: Double, ratio: Double) {
            var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
            for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) where alpha(x, y) >= thr {
                let fx = Double(x), fy = -Double(y)
                n += 1; sx += fx; sy += fy; sxx += fx * fx; syy += fy * fy; sxy += fx * fy
            } }
            guard n > 4 else { return (0, 1) }
            let mx = sx / n, my = sy / n
            let cxx = sxx / n - mx * mx, cyy = syy / n - my * my, cxy = sxy / n - mx * my
            let a = 0.5 * atan2(2 * cxy, cxx - cyy) * 180 / .pi
            let tr = cxx + cyy, det = cxx * cyy - cxy * cxy
            let l1 = tr / 2 + sqrt(max(0, tr * tr / 4 - det)), l2 = tr / 2 - sqrt(max(0, tr * tr / 4 - det))
            return ((a + 180).truncatingRemainder(dividingBy: 180), sqrt(l1 / max(1e-6, l2)))
        }
        func save(_ name: String, _ out: URL) { SelfTest.save(doc.state, name, out) }
    }

    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs((a - b).truncatingRemainder(dividingBy: 180))
        return min(d, 180 - d)
    }

    // MARK: Run

    static func run(_ out: URL) {
        passes = 0; failures = 0
        let app = AppModel.shared
        let savedTool = app.tool, savedBrush = app.brush, savedEraser = app.eraser, savedFG = app.foreground
        let savedSlots = app.toolBrushes, savedClone = app.clone, savedMixer = app.mixerBrushSettings
        let savedPrefs = TabletSettings.shared.prefs, savedCanvas = AppActions.canvas
        let savedDocs = app.documents, savedActive = app.activeDocumentID, savedDialog = app.dialog
        let savedPresenter = QuickBrushPicker.presenter, savedNow = BrushKeys.now, savedCaps = TabletInput.shared.capsLock
        let savedSel = ToolsSettings.shared.selectionBrush, savedCursorPref = app.prefs.brushCursor
        let savedButton = CanvasView.primaryButtonDown
        let savedLibChoices = BrushLibrary.shared.choiceState, savedPencil = app.pencil
        CanvasView.primaryButtonDown = { ToolRobot.buttonDown }
        let savedQAOut = QA.out
        QA.out = out   // overlay PNGs (HUD, cursors)
        app.dialog = nil
        TabletSettings.shared.prefs = TabletPrefs()
        TabletInput.shared.reset()
        BrushKeys.reset()
        app.foreground = RGBA(hex: "1B1F3A")!
        defer {
            app.tool = savedTool; app.brush = savedBrush; app.eraser = savedEraser; app.foreground = savedFG
            app.toolBrushes = savedSlots; app.clone = savedClone; app.mixerBrushSettings = savedMixer
            TabletSettings.shared.prefs = savedPrefs
            TabletInput.shared.reset()
            BrushKeys.reset(); BrushKeys.now = savedNow
            QuickBrushPicker.presenter = savedPresenter
            TabletInput.shared.capsLock = savedCaps
            ToolsSettings.shared.selectionBrush = savedSel
            app.prefs.brushCursor = savedCursorPref
            app.documents = savedDocs; app.activeDocumentID = savedActive; app.dialog = savedDialog
            Rig.releaseAll()
            AppActions.canvas = savedCanvas
            CanvasView.primaryButtonDown = savedButton
            BrushLibrary.shared.restore(savedLibChoices); app.pencil = savedPencil
            QA.out = savedQAOut
            print("tablet: \(passes) passed, \(failures) failed")
        }
        curveMath()
        controls()
        pressureSizeAndOpacity(out)
        optionsBarOverride()
        tiltRotationWheel(out)
        mouseFallback()
        penEraser(out)
        curveThroughCanvas()
        coalescing(out)
        fastStrokeTaper(out)
        smoothingCatchUp(out)
        resizeGesture(out)
        keys()
        quickPicker(out)
        perToolMemory()
        shiftLines(out)
        cursor(out)
        everyPaintTool(out)
        liquifyStylus()
        perf(quick: true)
    }

    // MARK: Pressure curve

    static func curveMath() {
        let lin = PressureCurve()
        check((0...10).allSatisfy { abs(lin.map(Double($0) / 10) - Double($0) / 10) < 1e-9 }, "linear curve passes pressure through")
        let soft = PressureCurve.preset(softness: 1), firm = PressureCurve.preset(softness: -1)
        check(soft.map(0.25) > 0.5 && firm.map(0.25) < 0.1, "soft curve lifts a light touch (\(f(soft.map(0.25)))), firm lowers it (\(f(firm.map(0.25))))")
        check(abs(soft.softness - 1) < 0.15 && abs(firm.softness + 1) < 0.15 && abs(PressureCurve.preset(softness: 0.4).softness - 0.4) < 0.1,
              "the soft…firm slider round-trips (\(f(soft.softness)), \(f(firm.softness)))")
        var mono = true
        for c in [soft, firm, PressureCurve(points: [CGPoint(x: 0.2, y: 0.6), CGPoint(x: 0.4, y: 0.62), CGPoint(x: 0.8, y: 0.95)])] {
            var prev = -1.0
            for i in 0...200 { let v = c.map(Double(i) / 200); if v < prev - 1e-9 { mono = false }; prev = v }
        }
        check(mono, "curves through user points stay monotone (no overshoot)")
        let clamped = PressureCurve(minOutput: 0.2, maxOutput: 0.8)
        check(abs(clamped.map(0) - 0.2) < 1e-9 && abs(clamped.map(1) - 0.8) < 1e-9 && abs(clamped.map(0.5) - 0.5) < 1e-9, "min / max clamp the output range")
        let data = try? JSONEncoder().encode(TabletPrefs())
        let back = data.flatMap { try? JSONDecoder().decode(TabletPrefs.self, from: $0) }
        check(back == TabletPrefs(), "tablet preferences round-trip through JSON")
        let partial = try? JSONDecoder().decode(TabletPrefs.self, from: Data("{\"tiltSensitivity\":1.5,\"curve\":{\"minOutput\":0.1}}".utf8))
        check(partial?.tiltSensitivity == 1.5 && partial?.curve.minOutput == 0.1 && partial?.usePenEraser == true, "old / partial preference files still load")
    }

    static func f(_ v: Double) -> String { String(format: "%.2f", v) }

    // MARK: Controls

    static func controls() {
        let all = BrushControl.allCases
        check(Set(BrushControl.shapeControls) == Set(all) && Set(BrushControl.angleControls) == Set(all) && Set(BrushControl.transferControls) == Set(all),
              "every dynamic offers every control (Off, Fade, Pen Pressure, Pen Tilt, Stylus Wheel, Rotation, Initial Direction, Direction)")
        var s = PenSample(p: .zero, pressure: 0.3, tilt: CGPoint(x: 0.6, y: 0), rotation: 90, wheel: 0.25)
        func c(_ src: BrushControl) -> Double { DynamicsMath.control(ControlSetting(source: src), s, dabIndex: 5, direction: 270, initialDirection: 45) }
        check(abs(c(.pressure) - 0.3) < 1e-9 && abs(c(.tilt) - 0.4) < 1e-9 && abs(c(.wheel) - 0.25) < 1e-9 && abs(c(.rotation) - 0.25) < 1e-9
              && abs(c(.direction) - 0.75) < 1e-9 && abs(c(.initialDirection) - 0.125) < 1e-9 && abs(c(.fade) - 0.8) < 1e-9 && c(.off) == 1,
              "control values: pressure, tilt, wheel, rotation, direction, initial direction, fade")
        s.mouse = true
        check(c(.tilt) == 1 && c(.rotation) == 1 && c(.wheel) == 1 && c(.pressure) == 0.3, "a mouse reads full tilt / rotation / wheel controls")
        // every option × every control drives the engine without trouble
        var ok = true
        let target = PixelBuffer(width: 200, height: 120)
        for src in all {
            var st = BrushSettings(size: 30, hardness: 0.7)
            let cs = ControlSetting(source: src, fadeSteps: 10)
            st.dynamics.shapeEnabled = true; st.dynamics.sizeControl = cs; st.dynamics.angleControl = cs; st.dynamics.roundnessControl = cs
            st.dynamics.scatterEnabled = true; st.scatter = 0.5; st.dynamics.scatterControl = cs; st.dynamics.countControl = cs
            st.dynamics.colorEnabled = true; st.dynamics.fgBgControl = cs; st.dynamics.hueJitter = 0.3; st.dynamics.colorJitterControl = cs
            st.dynamics.transferEnabled = true; st.dynamics.opacityControl = cs; st.dynamics.flowControl = cs
            st.dynamics.textureEnabled = true; st.dynamics.textureDepthControl = cs
            st.pressureSize = false
            let e = BrushDynamicsEngine(settings: st, target: target, origin: .zero, paint: .dynamic(fg: .red, bg: RGBA(r: 0, g: 0, b: 1)), seed: 3)
            e.begin(PenSample(p: CGPoint(x: 20, y: 60), pressure: 0.2, tilt: CGPoint(x: 0.3, y: 0.4), rotation: 30, wheel: 0.5))
            for i in 1...20 { e.move(PenSample(p: CGPoint(x: 20 + i * 8, y: 40 + i * 3), pressure: Double(i) / 20, tilt: CGPoint(x: 0.3, y: -0.2), rotation: Double(i) * 10, wheel: 0.5)) }
            if e.takeDirty().isEmpty { ok = false }
        }
        check(ok, "size, angle, roundness, scatter, count, colour, opacity, flow and texture accept every control")
        // pressure-driven size / opacity / flow / roundness really vary
        func dabArea(_ configure: (inout BrushSettings) -> Void, pressure: Double) -> (area: Int, alpha: Int) {
            var st = BrushSettings(size: 40, hardness: 1); st.pressureSize = false
            configure(&st)
            let b = PixelBuffer(width: 80, height: 80)
            let e = BrushDynamicsEngine(settings: st, target: b, origin: .zero, paint: .fixed(.black), seed: 1)
            e.begin(PenSample(p: CGPoint(x: 40, y: 40), pressure: pressure))
            var area = 0, amax = 0
            for y in 0..<80 { for x in 0..<80 { let a = Int(b.pixel(x, y).3); if a > 20 { area += 1 }; amax = max(amax, a) } }
            return (area, amax)
        }
        let sizeLo = dabArea({ $0.dynamics.shapeEnabled = true; $0.dynamics.sizeControl.source = .pressure }, pressure: 0.3).area
        let sizeHi = dabArea({ $0.dynamics.shapeEnabled = true; $0.dynamics.sizeControl.source = .pressure }, pressure: 1).area
        let rndLo = dabArea({ $0.dynamics.shapeEnabled = true; $0.dynamics.roundnessControl.source = .pressure; $0.dynamics.minRoundness = 0.1 }, pressure: 0.2).area
        let rndHi = dabArea({ $0.dynamics.shapeEnabled = true; $0.dynamics.roundnessControl.source = .pressure; $0.dynamics.minRoundness = 0.1 }, pressure: 1).area
        let opLo = dabArea({ $0.dynamics.transferEnabled = true; $0.dynamics.opacityControl.source = .pressure }, pressure: 0.3).alpha
        let flLo = dabArea({ $0.dynamics.transferEnabled = true; $0.dynamics.flowControl.source = .pressure }, pressure: 0.3).alpha
        let opHi = dabArea({ $0.dynamics.transferEnabled = true; $0.dynamics.opacityControl.source = .pressure }, pressure: 1).alpha
        check(sizeLo * 4 < sizeHi && rndLo * 2 < rndHi && opLo < opHi / 2 && flLo < opHi / 2,
              "pen pressure drives size (\(sizeLo)→\(sizeHi) px²), roundness (\(rndLo)→\(rndHi)), opacity / flow (\(opLo), \(flLo) → \(opHi))")
    }

    // MARK: Pressure → size / opacity through the canvas

    static func pressureSizeAndOpacity(_ out: URL) {
        let app = AppModel.shared
        let rig = Rig()
        app.tool = .brush
        app.brush = BrushSettings(size: 40, hardness: 0.9, spacing: 0.05, smoothing: 0)
        app.brush.pressureSize = true; app.brush.pressureOpacity = false
        rig.stroke(CGPoint(x: 60, y: 120), CGPoint(x: 700, y: 120), steps: 64, p0: 0.05, p1: 1)
        let t = [100, 250, 400, 550, 680].map { rig.thickness(x: $0, y0: 60, y1: 180) }
        check(t[0] < 12 && zip(t, t.dropFirst()).allSatisfy { $0.0 <= $0.1 + 1 } && t[4] >= 34,
              "pressure ramp 0.05→1 tapers the stroke thin → thick (thickness \(t))")
        // opacity
        app.brush.pressureSize = false; app.brush.pressureOpacity = true
        rig.stroke(CGPoint(x: 60, y: 260), CGPoint(x: 700, y: 260), steps: 64, p0: 0.1, p1: 1)
        let a = [100, 400, 680].map { rig.maxAlpha(x: $0, y0: 230, y1: 290) }
        let th = [100, 680].map { rig.thickness(x: $0, y0: 230, y1: 290, thr: 10) }
        check(a[0] < 90 && a[1] < a[2] && a[2] > 230 && abs(th[0] - th[1]) <= 4, "pressure → opacity: faint → solid at constant width (alpha \(a), width \(th))")
        // both, plus a mouse stroke for reference (full pressure)
        app.brush.pressureSize = true
        rig.stroke(CGPoint(x: 60, y: 400), CGPoint(x: 700, y: 400), steps: 64, p0: 0.05, p1: 1)
        rig.stroke(CGPoint(x: 60, y: 480), CGPoint(x: 700, y: 480), steps: 64, p0: 1, p1: 1, tablet: false)
        let m = [100, 680].map { rig.thickness(x: $0, y0: 450, y1: 510) }
        check(abs(m[0] - m[1]) <= 2 && m[0] >= 34, "a mouse paints at full pressure: constant width (\(m))")
        rig.save("tablet_pressure_ramp", out)
    }

    /// Options-bar pressure buttons override the Brush Settings panel's controls (Photoshop).
    static func optionsBarOverride() {
        func area(_ st: BrushSettings, pressure: Double, tilt: CGPoint) -> Int {
            let b = PixelBuffer(width: 80, height: 80)
            let e = BrushDynamicsEngine(settings: st, target: b, origin: .zero, paint: .fixed(.black), seed: 1)
            e.begin(PenSample(p: CGPoint(x: 40, y: 40), pressure: pressure, tilt: tilt))
            var n = 0
            for y in 0..<80 { for x in 0..<80 where b.pixel(x, y).3 > 20 { n += 1 } }
            return n
        }
        var st = BrushSettings(size: 50, hardness: 1)
        st.dynamics.shapeEnabled = true; st.dynamics.sizeControl.source = .tilt; st.dynamics.minDiameter = 0
        st.pressureSize = true
        let upright = area(st, pressure: 0.4, tilt: .zero), tilted = area(st, pressure: 0.4, tilt: CGPoint(x: 0.9, y: 0))
        let full = area(st, pressure: 1, tilt: CGPoint(x: 0.9, y: 0))
        check(abs(upright - tilted) < 10 && full > tilted * 3, "options-bar pressure button on: pressure drives size, the panel's Pen Tilt is overridden (\(upright), \(tilted), \(full))")
        st.pressureSize = false
        let u2 = area(st, pressure: 0.4, tilt: .zero), t2 = area(st, pressure: 0.4, tilt: CGPoint(x: 0.9, y: 0))
        check(u2 > t2 * 3, "button off: the panel's control applies (tilt shrinks the tip \(u2) → \(t2))")
    }

    // MARK: Tilt / rotation / wheel

    static func tiltRotationWheel(_ out: URL) {
        let app = AppModel.shared
        let rig = Rig()
        app.tool = .brush
        var s = BrushSettings(size: 60, hardness: 1, spacing: 0.05, smoothing: 0)
        s.roundness = 0.22; s.pressureSize = false
        s.dynamics.shapeEnabled = true; s.dynamics.angleControl.source = .tilt
        app.brush = s
        rig.dab(CGPoint(x: 100, y: 100), tilt: CGPoint(x: 0.8, y: 0))        // leaning right: 0°
        rig.dab(CGPoint(x: 220, y: 100), tilt: CGPoint(x: 0, y: -0.8))       // leaning up: 90°
        rig.dab(CGPoint(x: 340, y: 100), tilt: CGPoint(x: 0.6, y: -0.6))     // up-right: 45°
        let o = [100, 220, 340].map { rig.orientation(CGRect(x: $0 - 40, y: 60, width: 80, height: 80)) }
        check(angleDiff(o[0].angle, 0) < 8 && angleDiff(o[1].angle, 90) < 8 && angleDiff(o[2].angle, 45) < 8 && o.allSatisfy { $0.ratio > 2.5 },
              "pen tilt → tip angle: \(o.map { Int($0.angle.rounded()) })° for tilt →, ↑, ↗")
        s.dynamics.angleControl.source = .rotation
        app.brush = s
        rig.dab(CGPoint(x: 100, y: 230), rot: 0)
        rig.dab(CGPoint(x: 220, y: 230), rot: 90)
        rig.dab(CGPoint(x: 340, y: 230), rot: 135)
        let r = [100, 220, 340].map { rig.orientation(CGRect(x: $0 - 40, y: 190, width: 80, height: 80)) }
        check(angleDiff(r[0].angle, 0) < 8 && angleDiff(r[1].angle, 90) < 8 && angleDiff(r[2].angle, 135) < 8,
              "barrel rotation → tip angle: \(r.map { Int($0.angle.rounded()) })° for 0°, 90°, 135°")
        // stroke with the rotation turning along it (a calligraphy twist)
        rig.down(CGPoint(x: 440, y: 230), 1, rot: 0)
        for i in 1...60 { rig.drag(CGPoint(x: 440 + Double(i) * 4.5, y: 230), 1, rot: Double(i) * 3) }
        rig.up(CGPoint(x: 710, y: 230), 0, rot: 180)
        // stylus wheel → size
        s = BrushSettings(size: 60, hardness: 1, spacing: 0.05, smoothing: 0); s.pressureSize = false
        s.dynamics.shapeEnabled = true; s.dynamics.sizeControl.source = .wheel
        app.brush = s
        rig.dab(CGPoint(x: 100, y: 380), wheel: 0.25)
        rig.dab(CGPoint(x: 220, y: 380), wheel: 1)
        let w0 = rig.thickness(x: 100, y0: 330, y1: 430), w1 = rig.thickness(x: 220, y0: 330, y1: 430)
        check(w0 > 8 && w0 < 22 && w1 > 55, "stylus wheel (tangential pressure) → size: \(w0) px at 25%, \(w1) px at 100%")
        // tilt sensitivity: a slight lean counts as more
        TabletSettings.shared.prefs.tiltSensitivity = 2
        rig.down(CGPoint(x: 500, y: 380), 1, tilt: CGPoint(x: 0.3, y: 0))
        let t2 = TabletInput.shared.latest.tilt
        rig.up(CGPoint(x: 500, y: 380), 1, tilt: CGPoint(x: 0.3, y: 0))
        TabletSettings.shared.prefs.tiltSensitivity = 1
        check(abs(t2.x - 0.6) < 0.02, "tilt sensitivity 200% doubles the reported tilt (0.3 → \(f(Double(t2.x))))")
        rig.save("tablet_tilt_rotation_wheel", out)
    }

    // MARK: Mouse fallback / Force Touch

    static func mouseFallback() {
        let app = AppModel.shared
        let rig = Rig()
        app.tool = .brush
        var s = BrushSettings(size: 50, hardness: 1, spacing: 0.05, smoothing: 0)
        s.dynamics.shapeEnabled = true; s.dynamics.sizeControl.source = .rotation
        s.dynamics.transferEnabled = true; s.dynamics.opacityControl.source = .tilt; s.dynamics.flowControl.source = .wheel
        app.brush = s
        rig.dab(CGPoint(x: 100, y: 100), tablet: false)
        check(rig.thickness(x: 100, y0: 50, y1: 150) >= 46 && rig.maxAlpha(x: 100, y0: 50, y1: 150) > 240,
              "mouse: rotation / tilt / wheel controls read full (size \(rig.thickness(x: 100, y0: 50, y1: 150)), alpha \(rig.maxAlpha(x: 100, y0: 50, y1: 150)))")
        // Force Touch: off by default — full pressure; on — the click force
        app.brush = BrushSettings(size: 50, hardness: 1, spacing: 0.05, smoothing: 0)
        TabletInput.shared.setForcePressure(0.3)
        rig.down(CGPoint(x: 250, y: 100), 1, tablet: false)
        let off = TabletInput.shared.latest.pressure
        rig.up(CGPoint(x: 250, y: 100), 1, tablet: false)
        TabletSettings.shared.prefs.forceTouchPressure = true
        TabletInput.shared.setForcePressure(0.3)
        rig.down(CGPoint(x: 400, y: 100), 1, tablet: false)
        let on = TabletInput.shared.latest.pressure
        rig.up(CGPoint(x: 400, y: 100), 1, tablet: false)
        TabletSettings.shared.prefs.forceTouchPressure = false
        let w = rig.thickness(x: 400, y0: 50, y1: 150)
        check(off == 1 && abs(on - 0.3) < 1e-6 && w < 22, "Force Touch pressure: ignored by default (\(f(off))), used when enabled (\(f(on)), dab \(w) px)")
    }

    // MARK: Pen eraser

    static func penEraser(_ out: URL) {
        let app = AppModel.shared
        let rig = Rig()
        TabletInput.shared.reset()
        app.tool = .brush
        app.brush = BrushSettings(size: 30, hardness: 1, spacing: 0.05, smoothing: 0)
        app.eraser = BrushSettings(size: 70, hardness: 1, spacing: 0.05, smoothing: 0)
        rig.stroke(CGPoint(x: 80, y: 200), CGPoint(x: 680, y: 200), p0: 1, p1: 1)
        let before = rig.thickness(x: 380, y0: 150, y1: 250)
        guard let ein = TabletEvents.proximity(.eraser, entering: true), let pin = TabletEvents.proximity(.pen, entering: true),
              let eout = TabletEvents.proximity(.eraser, entering: false) else { check(false, "proximity events"); return }
        check(ein.type == .tabletProximity && ein.pointingDeviceType == .eraser && ein.isEnteringProximity, "synthetic proximity event carries the eraser device")
        rig.canvas.tabletProximity(with: ein)
        check(app.tool == .eraser && TabletInput.shared.device == .eraser, "flipping the pen to its eraser end switches to the Eraser")
        check(app.activeBrushSettings.size == 70, "the eraser end uses the Eraser's own size (\(Int(app.activeBrushSettings.size)) px)")
        rig.down(CGPoint(x: 380, y: 200), 1)
        rig.up(CGPoint(x: 380, y: 200), 1)
        check(rig.alpha(380, 200) == 0 && before >= 28, "the eraser end erases the stroke")
        rig.canvas.tabletProximity(with: eout)
        check(app.tool == .eraser, "leaving proximity keeps the tool")
        rig.canvas.tabletProximity(with: pin)
        check(app.tool == .brush && app.activeBrushSettings.size == 30, "flipping back to the tip restores the Brush and its size")
        // the eraser end remembers a tool picked while erasing
        rig.canvas.tabletProximity(with: ein)
        app.tool = .backgroundEraser
        rig.canvas.tabletProximity(with: pin)
        check(app.tool == .brush, "tip again: back to the Brush")
        rig.canvas.tabletProximity(with: ein)
        check(app.tool == .backgroundEraser, "the eraser end remembers the tool chosen for it (Background Eraser)")
        rig.canvas.tabletProximity(with: pin)
        // repeated proximity (local monitor + responder) is idempotent
        rig.canvas.tabletProximity(with: pin)
        check(app.tool == .brush, "repeated pen proximity events change nothing")
        // preference off: no switching
        TabletSettings.shared.prefs.usePenEraser = false
        TabletInput.shared.reset()
        rig.canvas.tabletProximity(with: ein)
        check(app.tool == .brush, "Use pen eraser off: the eraser end paints with the current tool")
        TabletSettings.shared.prefs.usePenEraser = true
        rig.canvas.tabletProximity(with: pin)
        // proximity carried on a mouse event (some drivers) is handled too
        TabletInput.shared.reset()
        let w = rig.canvas.convert(rig.v(CGPoint(x: 10, y: 10)), to: nil)
        if let base = NSEvent.mouseEvent(with: .mouseMoved, location: w, modifierFlags: [], timestamp: 0, windowNumber: rig.robot.window.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 0, pressure: 0), let cg = base.cgEvent?.copy() {
            cg.setIntegerValueField(.mouseEventSubtype, value: 2)
            cg.setIntegerValueField(.tabletProximityEventPointerType, value: Int64(NSEvent.PointingDeviceType.eraser.rawValue))
            cg.setIntegerValueField(.tabletProximityEventEnterProximity, value: 1)
            if let e = NSEvent(cgEvent: cg) { rig.canvas.mouseMoved(with: e) }
        }
        check(app.tool == .eraser, "proximity embedded in a mouse event (subtype) switches as well")
        rig.canvas.tabletProximity(with: pin)
        check(app.tool == .brush, "and back")
        rig.save("tablet_pen_eraser", out)
    }

    // MARK: Curve through the canvas

    static func curveThroughCanvas() {
        let app = AppModel.shared
        let rig = Rig()
        app.tool = .brush
        app.brush = BrushSettings(size: 40, hardness: 1, spacing: 0.05, smoothing: 0)
        TabletSettings.shared.prefs.curve = .preset(softness: 1)
        rig.down(CGPoint(x: 100, y: 100), 0.3)
        let soft = TabletInput.shared.latest
        rig.up(CGPoint(x: 100, y: 100), 0.3)
        TabletSettings.shared.prefs.curve = PressureCurve(minOutput: 0.5, maxOutput: 0.9)
        rig.down(CGPoint(x: 200, y: 100), 0.0)
        let lo = TabletInput.shared.latest.pressure
        rig.up(CGPoint(x: 200, y: 100), 0.0)
        TabletSettings.shared.prefs.curve = PressureCurve()
        let expect = PressureCurve.preset(softness: 1).map(soft.rawPressure)
        check(abs(soft.rawPressure - 0.3) < 0.01 && abs(soft.pressure - expect) < 1e-6 && soft.pressure > 0.55,
              "canvas events go through the pressure curve (raw \(f(soft.rawPressure)) → \(f(soft.pressure)))")
        check(abs(lo - 0.5) < 1e-6, "the minimum clamp applies to the lightest touch (\(f(lo)))")
        let w = rig.thickness(x: 100, y0: 50, y1: 150)
        check(w > 24, "a soft curve paints a light touch large (\(w) px of 40)")
    }

    // MARK: Coalescing / every sample

    static func coalescing(_ out: URL) {
        let app = AppModel.shared
        let rig = Rig()
        app.tool = .brush
        app.brush = BrushSettings(size: 30, hardness: 1, spacing: 0.02, smoothing: 0)
        app.brush.pressureSize = true
        let before = NSEvent.isMouseCoalescingEnabled
        let n = 400
        var sent: [Double] = []
        func pr(_ i: Int) -> Double { 0.5 + 0.45 * sin(Double(i) / 6) }
        rig.down(CGPoint(x: 60, y: 300), pr(0)); sent.append(pr(0))
        let during = NSEvent.isMouseCoalescingEnabled
        for i in 1...n { rig.drag(CGPoint(x: 60 + Double(i) * 1.6, y: 300), pr(i)); sent.append(pr(i)) }
        rig.up(CGPoint(x: 60 + Double(n) * 1.6, y: 300), 0)
        let after = NSEvent.isMouseCoalescingEnabled
        check(!during && after == before, "mouse coalescing is off during a stroke (every tablet report is delivered) and restored after")
        let got = TabletInput.shared.strokePressures
        let quant = zip(sent, got.prefix(sent.count)).allSatisfy { abs($0.0 - $0.1) < 0.006 }
        check(TabletInput.shared.strokeSamples == n + 2 && quant, "all \(n + 2) samples of a 400-report stroke reached the brush with their pressure (\(TabletInput.shared.strokeSamples))")
        // the high-frequency pressure wave is visible in the stroke (not averaged away)
        let widths = stride(from: 70, to: 690, by: 2).map { rig.thickness(x: $0, y0: 270, y1: 330) }
        var peaks = 0
        for i in 1..<(widths.count - 1) where widths[i] > widths[i - 1] && widths[i] >= widths[i + 1] && widths[i] > 22 { peaks += 1 }
        check(peaks >= 9 && (widths.min() ?? 0) < 6, "the pressure wave shows in the stroke (\(peaks) swells, min width \(widths.min() ?? -1))")
        rig.save("tablet_coalesced_wave", out)
    }

    /// Few, far-apart samples (a fast flick): pressure is interpolated per dab, and the lift does not blob.
    static func fastStrokeTaper(_ out: URL) {
        let app = AppModel.shared
        let rig = Rig()
        app.tool = .brush
        app.brush = BrushSettings(size: 50, hardness: 0.9, spacing: 0.04, smoothing: 0)
        app.brush.pressureSize = true
        rig.down(CGPoint(x: 60, y: 150), 0.05)
        for (i, p) in [0.3, 0.6, 0.85, 1.0].enumerated() { rig.drag(CGPoint(x: 60 + Double(i + 1) * 150, y: 150), p) }
        rig.up(CGPoint(x: 660, y: 150), 0)
        let w = stride(from: 70, through: 640, by: 30).map { rig.thickness(x: $0, y0: 100, y1: 200) }
        let monotone = zip(w, w.dropFirst()).allSatisfy { $0.0 <= $0.1 + 1 }
        check(monotone && Set(w).count >= 10 && w.first! < 10, "fast 5-sample stroke tapers smoothly (interpolated pressure): \(w)")
        // lifting the pen (pressure 0) ends at the last pressure — no full-size blob, no gap
        app.brush.size = 40
        rig.down(CGPoint(x: 60, y: 330), 0.3)
        for i in 1...20 { rig.drag(CGPoint(x: 60 + Double(i) * 20, y: 330), 0.3) }
        rig.up(CGPoint(x: 480, y: 330), 0)
        let mid = rig.thickness(x: 300, y0: 280, y1: 380), end = rig.thickness(x: 478, y0: 280, y1: 380)
        check(abs(mid - end) <= 3 && mid < 18, "the stroke ends at the last pressure when the pen lifts (\(mid) px mid, \(end) px at the end)")
        rig.save("tablet_fast_taper", out)
    }

    // MARK: Smoothing

    static func smoothingCatchUp(_ out: URL) {
        let app = AppModel.shared
        // the smoother itself
        var sm = StrokeSmoother(radius: 30, pulledString: true)
        sm.begin(.zero)
        var p = CGPoint.zero
        for i in 1...10 { p = sm.step(CGPoint(x: Double(i) * 2, y: 0)) }
        check(p == .zero, "pulled string: small moves inside the string don't move the paint")
        p = sm.step(CGPoint(x: 100, y: 0))
        check(abs(p.x - 70) < 1e-6, "pulled string: the paint trails the pen by the string length (\(f(Double(p.x))))")
        for _ in 0..<20 { p = sm.step(CGPoint(x: 100, y: 0), catchUp: true) }
        check(abs(p.x - 100) < 1e-6, "stroke catch-up: the paint glides onto the resting pen")
        check(abs(StrokeSmoother.radius(smoothing: 0.5, zoom: 2) - StrokeSmoother.radius(smoothing: 0.5, zoom: 1) / 2) < 1e-9
              && StrokeSmoother.radius(smoothing: 0.5, zoom: 2, adjustForZoom: false) == StrokeSmoother.radius(smoothing: 0.5, zoom: 1),
              "adjust for zoom: the string is in screen pixels")

        // through the canvas: a stroke that pauses, catches up, ends exactly at the pen
        let rig = Rig()
        app.tool = .brush
        app.brush = BrushSettings(size: 16, hardness: 1, spacing: 0.05, smoothing: 0.6)
        app.brush.pressureSize = false
        TabletSettings.shared.prefs.smoothing.pulledString = true
        let L = StrokeSmoother.radius(smoothing: 0.6, zoom: 1)
        rig.down(CGPoint(x: 80, y: 120), 1)
        for i in 1...50 { rig.drag(CGPoint(x: 80 + Double(i) * 10, y: 120), 1) }
        let lag = 588 - rig.extentX(y0: 100, y1: 140)
        for _ in 0..<40 { rig.canvas.catchUpTick(force: true) }
        let caught = 588 - rig.extentX(y0: 100, y1: 140)
        rig.up(CGPoint(x: 580, y: 120), 0)
        check(abs(Double(lag) - L) < 4, "while drawing the paint trails the pen by the string (\(lag) px, string \(Int(L.rounded())) px)")
        check(abs(caught) <= 2, "resting the pen: stroke catch-up brings the paint to the pen (\(caught) px left)")
        // no catch-up at the end: the stroke stops a string's length short
        TabletSettings.shared.prefs.smoothing.catchUpOnEnd = false
        rig.down(CGPoint(x: 80, y: 260), 1)
        for i in 1...50 { rig.drag(CGPoint(x: 80 + Double(i) * 10, y: 260), 1) }
        rig.up(CGPoint(x: 580, y: 260), 0)
        let short = 588 - rig.extentX(y0: 240, y1: 280)
        TabletSettings.shared.prefs.smoothing.catchUpOnEnd = true
        rig.down(CGPoint(x: 80, y: 400), 1)
        for i in 1...50 { rig.drag(CGPoint(x: 80 + Double(i) * 10, y: 400), 1) }
        rig.up(CGPoint(x: 580, y: 400), 0)
        let ends = 588 - rig.extentX(y0: 380, y1: 420)
        check(abs(Double(short) - L) < 4 && abs(ends) <= 2, "catch-up on stroke end: off stops \(short) px short, on ends at the pen (\(ends) px)")
        // a wobbly line through pulled-string smoothing comes out straight
        rig.down(CGPoint(x: 80, y: 480), 1)
        for i in 1...100 { rig.drag(CGPoint(x: 80 + Double(i) * 5, y: 480 + (i % 2 == 0 ? 6 : -6)), 1) }
        rig.up(CGPoint(x: 580, y: 480), 0)
        let spread = (200...500).filter { rig.thickness(x: $0, y0: 455, y1: 505) > 0 }.map { rig.thickness(x: $0, y0: 455, y1: 505) }.max() ?? 99
        TabletSettings.shared.prefs.smoothing.pulledString = false
        check(spread <= 18, "pulled-string smoothing removes a ±6 px wobble (stroke \(spread) px for a 16 px brush)")
        // high-rate input stays cheap with smoothing on
        let e = BrushDynamicsEngine(settings: app.brush, target: PixelBuffer(width: 600, height: 200), origin: .zero, paint: .fixed(.black))
        e.begin(PenSample(p: CGPoint(x: 10, y: 100)))
        let t0 = CFAbsoluteTimeGetCurrent()
        var worst = 0.0
        for i in 1...2000 {
            let s0 = CFAbsoluteTimeGetCurrent()
            e.move(PenSample(p: CGPoint(x: 10 + Double(i) * 0.25, y: 100 + sin(Double(i) / 9) * 30), pressure: 0.7))
            worst = max(worst, CFAbsoluteTimeGetCurrent() - s0)
        }
        let avg = (CFAbsoluteTimeGetCurrent() - t0) / 2000
        check(worst < 0.02, String(format: "smoothing has no lag spikes: 2000 samples, %.3f ms average, %.2f ms worst", avg * 1000, worst * 1000))
        rig.save("tablet_smoothing", out)
    }

    // MARK: ⌃⌥-drag

    static func resizeGesture(_ out: URL) {
        let app = AppModel.shared
        let rig = Rig()
        app.tool = .brush
        app.brush = BrushSettings(size: 50, hardness: 0.5, spacing: 0.05, smoothing: 0)
        let h0 = rig.doc.history.count
        let c = CGPoint(x: 380, y: 260)
        rig.down(c, 1, mods: [.control, .option])
        check(BrushHUD.shared.isActive, "⌃⌥-drag starts the brush resize gesture")
        rig.drag(c + CGPoint(x: 40, y: 0), 1, mods: [.control, .option])
        check(app.brush.size == 130 && abs(app.brush.hardness - 0.5) < 1e-9, "dragging right enlarges the brush (50 → \(Int(app.brush.size)) px)")
        rig.drag(c + CGPoint(x: 40, y: -60), 1, mods: [.control, .option])
        check(abs(app.brush.hardness - 0.2) < 1e-6, "dragging up softens it (hardness \(Int(app.brush.hardness * 100))%)")
        rig.robot.saveOverlayPNG("tablet_hud_resize")
        if let rep = rig.robot.drawOverlay() {
            let p = rig.v(c) + CGPoint(x: 40, y: 0)   // inside the 130 px circle, outside the old 50 px one
            let col = rep.colorAt(x: Int(p.x * CGFloat(rep.pixelsWide) / rig.canvas.bounds.width), y: Int(p.y * CGFloat(rep.pixelsHigh) / rig.canvas.bounds.height))
            check((col?.alphaComponent ?? 0) > 0.1 && (col?.redComponent ?? 0) > (col?.blueComponent ?? 1), "the HUD shows the new size as a red brush circle")
        }
        rig.drag(c + CGPoint(x: -20, y: 400), 1, mods: [])   // modifiers released mid-drag: still the gesture
        rig.up(c + CGPoint(x: -20, y: 400), 0)
        check(!BrushHUD.shared.isActive && app.brush.size == 10 && app.brush.hardness == 1, "release ends it (size \(Int(app.brush.size)), hardness \(Int(app.brush.hardness * 100))%)")
        check(rig.doc.history.count == h0 && rig.thickness(x: 380, y0: 0, y1: 520, thr: 1) == 0, "the gesture paints nothing and adds no history step")
        // at 200% zoom the circle follows the pointer in screen pixels
        rig.robot.setView(QAView(name: "z2", zoom: 2, offset: CGPoint(x: -100, y: -100)))
        app.brush.size = 50
        rig.down(c, 1, mods: [.control, .option])
        rig.drag(c + CGPoint(x: 20, y: 0), 1, mods: [.control, .option])   // 20 document px = 40 screen px
        rig.up(c + CGPoint(x: 20, y: 0), 0)
        check(app.brush.size == 90, "at 200% zoom 40 screen px add 40 document px: the circle edge follows the pointer (\(Int(app.brush.size)))")
        // other brush tools: the eraser's own brush
        app.tool = .eraser
        let e0 = app.eraser.size
        rig.down(c, 1, mods: [.control, .option]); rig.drag(c + CGPoint(x: 5, y: 0), 1, mods: [.control, .option]); rig.up(c + CGPoint(x: 5, y: 0), 0)
        check(app.eraser.size == e0 + 10 && app.brush.size == 90, "the eraser resizes its own brush")
        app.tool = .move
        rig.down(c, 1, mods: [.control, .option])
        check(!BrushHUD.shared.isActive, "tools without a brush don't start the gesture")
        rig.up(c, 0)
        app.tool = .brush
    }

    // MARK: Keys

    static func keys() {
        let app = AppModel.shared
        let rig = Rig()
        let r = rig.robot
        app.tool = .brush
        app.brush = BrushSettings(size: 50, hardness: 0.6, spacing: 0.05, smoothing: 0)
        r.key(30, "]")
        check(app.brush.size == 55, "] enlarges the brush (\(Int(app.brush.size)))")
        r.key(33, "["); r.key(33, "[")
        check(app.brush.size == 45, "[ shrinks it (\(Int(app.brush.size)))")
        r.mods = [.shift]
        r.key(30, "}")
        check(app.brush.hardness == 0.75, "⇧] hardens in 25% steps (\(Int(app.brush.hardness * 100))%)")
        r.key(33, "{"); r.key(33, "{")
        check(app.brush.hardness == 0.25, "⇧[ softens (\(Int(app.brush.hardness * 100))%)")
        r.mods = []
        check(BrushHUD.shared.currentFlash != nil, "the new value flashes near the brush")
        var clock: CFTimeInterval = 1000
        BrushKeys.now = { clock }
        BrushKeys.reset()
        r.key(21, "4")
        check(abs(app.brush.opacity - 0.4) < 1e-9, "4 sets 40% opacity")
        clock += 0.3
        r.key(23, "5")
        check(abs(app.brush.opacity - 0.45) < 1e-9, "4 then 5 quickly sets exactly 45%")
        clock += 2
        r.key(29, "0")
        check(app.brush.opacity == 1, "0 sets 100%")
        clock += 0.2
        r.key(29, "0")
        check(app.brush.opacity == 0, "0 0 sets 0%")
        clock += 2
        r.mods = [.shift]
        r.key(26, "&")
        check(abs(app.brush.flow - 0.7) < 1e-9 && app.brush.opacity == 0, "⇧7 sets 70% flow, opacity untouched")
        clock += 0.2
        r.key(23, "%")
        check(abs(app.brush.flow - 0.75) < 1e-9, "⇧7 ⇧5 quickly → exactly 75% flow (\(Int((app.brush.flow * 100).rounded()))%)")
        r.mods = []
        clock += 2
        r.key(18, "1")
        check(abs(app.brush.opacity - 0.1) < 1e-9, "1 sets 10%")
        app.tool = .dodge
        clock += 2
        r.key(23, "5")
        check(abs(app.activeBrushSettings.opacity - 0.5) < 1e-9, "number keys work on every brush tool (Dodge 50%)")
        let d0 = app.activeBrushSettings.size
        r.key(30, "]")
        check(app.activeBrushSettings.size > d0, "so do the brackets (Dodge \(Int(d0)) → \(Int(app.activeBrushSettings.size)) px)")
        app.tool = .selectionBrush
        let s0 = ToolsSettings.shared.selectionBrush.size
        r.key(30, "]")
        check(ToolsSettings.shared.selectionBrush.size > s0, "and on the Selection Brush")
        app.tool = .brush
        BrushKeys.now = CACurrentMediaTime
        BrushKeys.reset()
    }

    // MARK: Quick picker

    static func quickPicker(_ out: URL) {
        let app = AppModel.shared
        let rig = Rig()
        var opened: [(CGPoint, ToolKind)] = []
        QuickBrushPicker.presenter = { p, _, k in opened.append((p, k)) }
        app.tool = .brush
        app.brush = BrushSettings(size: 20, hardness: 1)
        let h0 = rig.doc.history.count
        let p = CGPoint(x: 300, y: 200)
        rig.canvas.rightMouseDown(with: TabletEvents.mouse(.rightMouseDown, view: rig.v(p), canvas: rig.canvas, pressure: 1, tablet: false))
        check(opened.count == 1 && opened.first?.1 == .brush && opened.first.map { $0.0.distance(to: rig.v(p)) < 0.5 } == true,
              "right-click on the canvas with a brush tool opens the quick brush picker at the pointer")
        rig.down(p, 1, mods: [.control], tablet: false); rig.up(p, 0, tablet: false)
        check(opened.count == 2 && rig.doc.history.count == h0, "⌃-click opens it too (and paints nothing)")
        rig.canvas.rightMouseDown(with: TabletEvents.mouse(.rightMouseDown, view: rig.v(p), canvas: rig.canvas, pressure: 0.5))
        check(opened.count == 3, "the pen's side button (right-click) opens it")
        app.tool = .cloneStamp
        rig.canvas.rightMouseDown(with: TabletEvents.mouse(.rightMouseDown, view: rig.v(p), canvas: rig.canvas, pressure: 1, tablet: false))
        check(opened.last?.1 == .cloneStamp, "…for every brush tool (Clone Stamp)")
        app.tool = .eyedropper   // (no context menu of its own: a menu would pop up modally)
        rig.canvas.rightMouseDown(with: TabletEvents.mouse(.rightMouseDown, view: rig.v(p), canvas: rig.canvas, pressure: 1, tablet: false))
        check(opened.count == 4, "not for tools without a brush")
        app.tool = .brush
        // The brush library is the picker's only source: presets, favourites, recent brushes, the active preset.
        let lib = BrushLibrary.shared
        let fresh = lib.choiceState
        lib.restore(fresh)   // (start from the library as it is)
        var sec = QuickBrushPicker.sections()
        check(sec.all.map(\.id) == lib.orderedBrushes.map(\.id) && sec.all.count >= BrushDefaults.records().count,
              "the picker lists the brush library (\(sec.all.count) brushes, library order)")
        check(BrushPreset.builtIn.allSatisfy { lib.contains($0.id) } && BrushPreset.dynamicPresets.allSatisfy { lib.contains($0.id) },
              "the presets it offered before are library brushes under the same ids")
        if lib.contains("soft100"), lib.contains("chalk"), let chalk = lib.record("chalk") {
            app.brush.opacity = 0.6
            QuickBrushPicker.choose("soft100", for: .brush)
            QuickBrushPicker.choose("chalk", for: .brush)
            check(app.brush.size == chalk.params.size && app.brush.tipID == chalk.tipID && app.brush.opacity == 0.6,
                  "picking a brush applies the library preset (tool opacity kept)")
            check(lib.recentBrushes.prefix(2).map(\.id) == ["chalk", "soft100"], "…and lists it first in the library's Recent")
            check(lib.activePresetID(for: .brush) == "chalk" && lib.activePresetID == "chalk" && !lib.isActivePresetModified,
                  "…and it is the Brush tool's active preset: the Brushes panel and Brush Settings header select it, unmodified")
            sec = QuickBrushPicker.sections()
            check(sec.recent.first?.id == "chalk", "the picker's Recent row is the library's")
            // a picker opened for another tool than the current one (the pen's eraser end) chooses for that tool
            QuickBrushPicker.choose("hard30", for: .pencil)
            check(app.pencil.size == 30 && lib.activePresetID(for: .pencil) == "hard30" && lib.activePresetID(for: .brush) == "chalk",
                  "choosing for another tool sets that tool's brush and active preset only")
            // ★ in the picker is the library favourite
            let wasFav = lib.isFavorite("soft100")
            QuickBrushPicker.toggleFavorite("soft100")
            check(lib.isFavorite("soft100") != wasFav && QuickBrushPicker.sections().favorites.contains { $0.id == "soft100" } != wasFav,
                  "★ toggles the library favourite")
            if !lib.isFavorite("soft100") { QuickBrushPicker.toggleFavorite("soft100") }
            // a favourite set in the Brushes panel shows in the picker (and leaves its Recent row)
            lib.setFavorite("chalk", true)
            sec = QuickBrushPicker.sections()
            check(sec.favorites.contains { $0.id == "chalk" } && !sec.recent.contains { $0.id == "chalk" },
                  "a favourite set in the Brushes panel is in the picker's Favourites (not repeated under Recent)")
            lib.setFavorite("chalk", false)
            check(!QuickBrushPicker.sections().favorites.contains { $0.id == "chalk" }, "…and leaves when it is removed there")
        } else {
            check(false, "the default library has Soft Round 100 and Chalk")
        }
        // tablet preferences no longer keep lists of their own
        if let d = try? JSONEncoder().encode(TabletSettings.shared.prefs), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            check(o["favoriteBrushes"] == nil && o["recentBrushes"] == nil, "Tablet preferences don't store favourite / recent brushes")
        }
        legacyBrushLists()
        // render the picker offscreen (no window; the view graph goes away with the pool)
        autoreleasepool {
            let host = NSHostingView(rootView: QuickBrushPickerView(tool: .brush).environment(\.colorScheme, .dark).background(Color(white: 0.17)))
            host.frame = CGRect(x: 0, y: 0, width: 280, height: 420)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: out.appendingPathComponent("tablet_quick_picker.png")) }
                check(rep.pixelsWide > 0, "the quick picker renders (tablet_quick_picker.png)")
            }
        }
        lib.restore(fresh)
    }

    /// Favourites / recent ids an earlier version kept in the tablet preferences move into the library once.
    static func legacyBrushLists() {
        let json = #"{"tiltSensitivity": 1.5, "favoriteBrushes": ["soft45", "gone-brush"], "recentBrushes": ["hard5", "chalk", "nope"]}"#
        guard let old = try? JSONDecoder().decode(TabletPrefs.self, from: Data(json.utf8)) else { check(false, "old tablet preferences decode"); return }
        check(old.tiltSensitivity == 1.5 && old.legacyFavoriteBrushes == ["soft45", "gone-brush"] && old.legacyRecentBrushes.count == 3,
              "old tablet preferences still decode (favourite / recent keys kept for the migration)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imagecrat-tablet-migrate-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = BrushLibrary(directory: dir)
        lib.setFavorite("hard13", true)
        lib.choose("soft13", into: &AppModel.shared.pencil, tool: .pencil)
        let saved = TabletSettings.shared.prefs
        TabletSettings.shared.prefs = old
        let n = TabletSettings.shared.migrateBrushLists(into: lib)
        check(n == 3 && lib.favoriteBrushes.map(\.id) == ["hard13", "soft45"] && lib.recentBrushes.map(\.id) == ["soft13", "hard5", "chalk"],
              "migration merges the ids that are library brushes (favourites appended, recent after the library's own)")
        check(TabletSettings.shared.prefs.legacyFavoriteBrushes.isEmpty && TabletSettings.shared.prefs.legacyRecentBrushes.isEmpty
              && TabletSettings.shared.prefs.tiltSensitivity == 1.5, "…drops unknown ids and clears the old lists (other preferences kept)")
        check(TabletSettings.shared.migrateBrushLists(into: lib) == 0 && lib.favoriteBrushes.count == 2, "…once")
        if let d = try? JSONEncoder().encode(TabletSettings.shared.prefs), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            check(o["favoriteBrushes"] == nil && o["recentBrushes"] == nil, "…and the old keys are not written again")
        }
        TabletSettings.shared.prefs = saved
    }

    // MARK: Per-tool brushes

    static func perToolMemory() {
        let app = AppModel.shared
        _ = Rig()
        TabletSettings.shared.prefs.syncBrushAcrossTools = false
        app.tool = .blur; var s = app.activeBrushSettings; s.size = 21; app.activeBrushSettings = s
        app.tool = .smudge; s = app.activeBrushSettings; s.size = 77; app.activeBrushSettings = s
        app.tool = .dodge; s = app.activeBrushSettings; s.size = 33; s.tipID = "chalk"; app.activeBrushSettings = s
        app.tool = .blur
        check(app.activeBrushSettings.size == 21, "Blur remembers its brush (\(Int(app.activeBrushSettings.size)))")
        app.tool = .smudge
        check(app.activeBrushSettings.size == 77 && app.retouchBrush.size == 77, "Smudge remembers its own (\(Int(app.activeBrushSettings.size)))")
        app.tool = .dodge
        check(app.activeBrushSettings.tipID == "chalk", "Dodge keeps its tip")
        app.tool = .brush; app.brush.size = 12
        app.tool = .eraser; app.eraser.size = 99
        app.tool = .mixerBrush; app.mixerBrushSettings.size = 44
        app.tool = .brush
        check(app.activeBrushSettings.size == 12 && app.eraser.size == 99 && app.mixerBrushSettings.size == 44, "Brush, Eraser and Mixer each keep their size")
        app.tool = .healing; s = app.activeBrushSettings; s.size = 15; app.activeBrushSettings = s
        app.tool = .spotHealing; s = app.activeBrushSettings; s.size = 65; app.activeBrushSettings = s
        app.tool = .healing
        check(app.activeBrushSettings.size == 15, "Healing and Spot Healing are separate")
        app.healing = BrushSettings(size: 14, hardness: 0.6)
        check(app.brushSettings(for: .spotHealing).size == 14, "assigning the group (tool presets, resets) still sets both")
        app.retouchBrush = BrushSettings(size: 18, hardness: 0.4)
        check(AppModel.retouchKinds.allSatisfy { app.brushSettings(for: $0).size == 18 }, "…and all six retouch tools")
        // sync
        TabletSettings.shared.prefs.syncBrushAcrossTools = true
        app.tool = .brush; s = app.brush; s.size = 37; s.tipID = "charcoal"; s.opacity = 0.5; app.brush = s
        app.eraser.opacity = 1
        app.tool = .eraser
        check(app.eraser.size == 37 && app.eraser.tipID == "charcoal" && app.eraser.opacity == 1, "sync on: the tip travels to the Eraser (opacity stays the tool's)")
        app.eraser.size = 61
        app.tool = .smudge
        check(app.activeBrushSettings.size == 61, "…and on to Smudge")
        app.tool = .move
        app.tool = .brush
        check(app.brush.size == 37, "passing through a tool without a brush changes nothing")
        TabletSettings.shared.prefs.syncBrushAcrossTools = false
        app.tool = .eraser
        check(app.eraser.size == 61, "sync off: tools are independent again")
        libraryPresetsPerTool()
        // the pressure defaults preference sets every tool's buttons
        TabletSettings.shared.prefs.pressureOpacityDefault = true
        check(AppModel.brushTools.allSatisfy { app.brushSettings(for: $0).pressureOpacity }, "\"Pressure controls opacity by default\" turns the button on for every brush tool")
        TabletSettings.shared.prefs.pressureOpacityDefault = false
        check(AppModel.brushTools.allSatisfy { !app.brushSettings(for: $0).pressureOpacity }, "…and off again")
        app.tool = .brush
    }

    /// Per-tool brush memory and the brush library's per-tool active presets agree, with and without sync.
    static func libraryPresetsPerTool() {
        let app = AppModel.shared
        let lib = BrushLibrary.shared
        let saved = lib.choiceState
        defer { lib.restore(saved); TabletSettings.shared.prefs.syncBrushAcrossTools = false; app.tool = .brush }
        guard ["hard13", "soft45", "hard30"].allSatisfy(lib.contains) else { check(false, "the default library has Hard Round 13 / 30 and Soft Round 45"); return }
        /// The tool's brush is what its active preset gives (nothing changed since it was chosen).
        func agrees(_ k: ToolKind, _ id: String) -> Bool {
            guard lib.activePresetID(for: k) == id, let r = lib.record(id) else { return false }
            return lib.settings(for: r, base: app.brushSettings(for: k)) == app.brushSettings(for: k)
        }
        TabletSettings.shared.prefs.syncBrushAcrossTools = false
        app.tool = .brush; lib.select("hard13")
        app.tool = .eraser; lib.select("soft45")
        app.tool = .brush
        check(lib.activePresetID == "hard13" && app.brush.size == 13 && !lib.isActivePresetModified && agrees(.brush, "hard13"),
              "sync off: the Brush keeps its brush and its preset (Hard Round 13)…")
        app.tool = .eraser
        check(lib.activePresetID == "soft45" && app.eraser.size == 45 && !lib.isActivePresetModified && agrees(.eraser, "soft45"),
              "…and the Eraser its own (Soft Round 45)")
        // sync on: the preset travels with the tip, modified mark included
        TabletSettings.shared.prefs.syncBrushAcrossTools = true
        app.tool = .brush
        check(app.brush.size == 45 && lib.activePresetID == "soft45" && !lib.isActivePresetModified && agrees(.brush, "soft45"),
              "sync on: the Eraser's preset comes along to the Brush with its tip (unmodified)")
        app.brush.size = 80
        check(lib.isActivePresetModified, "changing the size marks it modified")
        app.tool = .smudge
        check(app.activeBrushSettings.size == 80 && lib.activePresetID == "soft45" && lib.isActivePresetModified,
              "…and the modified preset travels on to Smudge")
        lib.select("hard30")
        app.tool = .move
        app.tool = .brush
        check(app.brush.size == 80 && lib.activePresetID == "soft45", "passing through a tool without a brush keeps the Brush's preset")
        TabletSettings.shared.prefs.syncBrushAcrossTools = false
        app.tool = .smudge
        check(lib.activePresetID == "hard30" && agrees(.smudge, "hard30") && lib.activePresetID(for: .brush) == "soft45",
              "sync off again: each tool keeps the preset it had")
    }

    // MARK: Shift-click lines

    static func shiftLines(_ out: URL) {
        let app = AppModel.shared
        let rig = Rig()
        app.tool = .brush
        app.brush = BrushSettings(size: 12, hardness: 1, spacing: 0.05, smoothing: 0.5)
        rig.dab(CGPoint(x: 100, y: 100))
        rig.down(CGPoint(x: 600, y: 400), 1, mods: [.shift]); rig.up(CGPoint(x: 600, y: 400), 1, mods: [.shift])
        check(rig.alpha(350, 250) > 200 && rig.alpha(225, 175) > 200, "Shift-click draws a straight line from the last point (Brush, smoothing on)")
        // generic painting tools: the selection brush
        app.tool = .selectionBrush
        ToolsSettings.shared.selectionBrush = BrushSettings(size: 10, hardness: 1, spacing: 0.1, smoothing: 0)
        rig.doc.state.selection = nil
        rig.dab(CGPoint(x: 100, y: 450), tablet: false)
        rig.down(CGPoint(x: 500, y: 450), 1, mods: [.shift], tablet: false); rig.up(CGPoint(x: 500, y: 450), 1, mods: [.shift], tablet: false)
        let sel = rig.doc.state.selection
        check((sel?.pixel(300, 450).0 ?? 0) > 200 && (sel?.pixel(300, 470).0 ?? 255) < 50, "Shift-click lines work for the Selection Brush too")
        // Dodge on the paint: a straight line of effect
        app.tool = .brush
        rig.save("tablet_shift_line", out)
    }

    // MARK: Cursor

    static func cursor(_ out: URL) {
        let app = AppModel.shared
        let rig = Rig()
        app.tool = .brush
        var s = BrushSettings(size: 60, hardness: 1); s.roundness = 0.3; s.angle = 30
        app.brush = s
        app.prefs.brushCursor = .normal
        let path = BrushCursor.outline(s, size: 60, hardness: 1, full: false, canvas: rig.canvas, at: CGPoint(x: 400, y: 300))
        let bb = path.boundingBoxOfPath
        check(abs(bb.midX - 400) < 1 && bb.width > 50 && bb.width < 60 && bb.height > 30 && bb.height < 45,
              "cursor outline: 60 px tip, 30% round at 30° (\(Int(bb.width))×\(Int(bb.height)))")
        rig.robot.setView(QAView(name: "rot", zoom: 2, offset: CGPoint(x: 100, y: -50), rotation: .pi / 4))
        let p2 = BrushCursor.outline(s, size: 60, hardness: 1, full: false, canvas: rig.canvas, at: CGPoint(x: 400, y: 300))
        let b2 = p2.boundingBoxOfPath
        check(b2.width > 100 && b2.width < 125, "zoomed 200% and view rotated 45°: the outline scales and turns with the canvas (\(Int(b2.width))×\(Int(b2.height)))")
        rig.canvas.lastMouseView = CGPoint(x: 400, y: 300)
        rig.robot.saveOverlayPNG("tablet_cursor_flat_rotated")
        var chalk = BrushSettings(size: 80, hardness: 1); chalk.tipID = "chalk"
        let cp = BrushCursor.tipPath(chalk, hardness: 1, full: true)
        check(!cp.path.isEmpty && cp.path.boundingBoxOfPath.width > 40, "sampled tips (Chalk) show their real outline")
        app.brush = chalk
        rig.robot.setView(QAView(name: "z1", zoom: 1, offset: CGPoint(x: 60, y: 50)))
        rig.canvas.lastMouseView = CGPoint(x: 400, y: 300)
        rig.robot.saveOverlayPNG("tablet_cursor_chalk")
        TabletInput.shared.capsLock = { true }
        check(BrushCursor.isPrecise, "Caps Lock switches to the precise crosshair")
        rig.robot.saveOverlayPNG("tablet_cursor_capslock")
        TabletInput.shared.capsLock = { false }
        check(!BrushCursor.isPrecise, "Caps Lock off: the tip outline again")
        // the cursor follows a hovering pen (tablet-subtype mouseMoved)
        rig.canvas.mouseMoved(with: TabletEvents.mouse(.mouseMoved, view: CGPoint(x: 222, y: 111), canvas: rig.canvas, pressure: 0))
        check(rig.canvas.lastMouseView == CGPoint(x: 222, y: 111) && TabletInput.shared.latest.isTablet, "a hovering pen moves the brush cursor")
    }

    // MARK: Every paint-like tool takes tablet strokes

    static func everyPaintTool(_ out: URL) {
        let app = AppModel.shared
        for k in AppModel.brushTools where k != .selectionBrush {
            let rig = Rig(width: 400, height: 260, background: RGBA(hex: "7A8FA6")!)
            // something to clone / smudge / erase: a dark band on the paint layer
            if let r = rig.doc.state.layer(rig.paintID)?.raster {
                r.buffer.context.setFillColor(RGBA(hex: "C0392B")!.cgColor)
                r.buffer.context.fill(CGRect(x: 0, y: 100, width: 400, height: 60))
                r.buffer.context.setFillColor(RGBA(hex: "F5B041")!.cgColor)   // stripes: detail for sharpen / blur / smudge
                for x in stride(from: 0, to: 400, by: 10) { r.buffer.context.fill(CGRect(x: x, y: 100, width: 4, height: 60)) }
                r.buffer.markDirty()
                rig.doc.commit("Band")
            }
            app.tool = k
            var s = app.activeBrushSettings
            s.size = 24; s.smoothing = 0.2
            s.dynamics.shapeEnabled = true; s.dynamics.angleControl.source = .tilt
            app.activeBrushSettings = s
            app.historyBrushSource = 0
            // clone source above the band: the stroke below it copies the band down
            if k == .cloneStamp || k == .healing { rig.down(CGPoint(x: 50, y: 30), 1, mods: [.option]); rig.up(CGPoint(x: 50, y: 30), 1, mods: [.option]) }
            let before = rig.doc.state.layer(rig.paintID)?.raster?.buffer.copy()
            let h0 = rig.doc.history.count
            rig.stroke(CGPoint(x: 60, y: 130), CGPoint(x: 330, y: 230), steps: 30, p0: 0.2, p1: 1, tilt: CGPoint(x: 0.4, y: -0.3), rot: 45, wheel: 0.6)
            let after = rig.doc.state.layer(rig.paintID)?.raster?.buffer
            let changed = before.flatMap { b in after.map { QAMeasure.diff(b, $0) > 0 } } ?? false
            let steps = rig.doc.history.count - h0
            if k == .artHistoryBrush || k == .removeTool {   // (stylized from history / content-aware or generative fill)
                check(steps <= 1, "\(k.displayName): tablet stroke runs")
            } else {
                check(changed && steps == 1, "\(k.displayName): tablet stroke (pressure, tilt, rotation, wheel) paints one step (changed \(changed), \(steps) steps)")
            }
            AppActions.canvas = rig.canvas
            rig.doc.undo()
        }
        // selection brush and Quick Mask
        let rig = Rig(width: 400, height: 260)
        app.tool = .selectionBrush
        ToolsSettings.shared.selectionBrush = BrushSettings(size: 30, hardness: 1, spacing: 0.1, smoothing: 0)
        ToolsSettings.shared.selectionBrush.pressureSize = true
        rig.stroke(CGPoint(x: 40, y: 130), CGPoint(x: 360, y: 130), steps: 40, p0: 0.1, p1: 1)
        let sel = rig.doc.state.selection
        let w0 = (100..<160).filter { (sel?.pixel(60, $0).0 ?? 0) > 128 }.count, w1 = (100..<160).filter { (sel?.pixel(340, $0).0 ?? 0) > 128 }.count
        check(w0 < w1 / 2 && w1 >= 26, "Selection Brush: pressure → size (\(w0) → \(w1) px)")
        rig.doc.state.selection = nil
        rig.doc.quickMask = true
        app.tool = .brush
        app.brush = BrushSettings(size: 30, hardness: 1, spacing: 0.05, smoothing: 0)
        rig.stroke(CGPoint(x: 40, y: 60), CGPoint(x: 360, y: 60), steps: 30, p0: 0.1, p1: 1)
        check(rig.doc.state.selection != nil, "Quick Mask: a tablet stroke paints the mask")
        rig.doc.quickMask = false
    }

    // MARK: Liquify

    static func liquifyStylus() {
        let space = CanvasSpace(width: 400, height: 300)
        func displacement(_ pressure: Double, stylus: Bool) -> Double {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let v = LiquifyPreviewView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            window.contentView = v
            v.space = space
            let field = DisplacementField(width: 400, height: 300)
            v.field = field
            v.brushSize = 80; v.pressure = 0.5; v.useStylus = stylus
            v.mouseDown(with: TabletEvents.mouse(.leftMouseDown, view: CGPoint(x: 100, y: 150), canvas: v, pressure: pressure))
            for i in 1...10 { v.mouseDragged(with: TabletEvents.mouse(.leftMouseDragged, view: CGPoint(x: 100 + i * 10, y: 150), canvas: v, pressure: pressure)) }
            v.mouseUp(with: TabletEvents.mouse(.leftMouseUp, view: CGPoint(x: 200, y: 150), canvas: v, pressure: 0))
            return field.d.reduce(0) { $0 + Double(abs($1.x) + abs($1.y)) }
        }
        let lo = displacement(0.2, stylus: true), hi = displacement(1, stylus: true), off = displacement(0.2, stylus: false)
        check(lo > 0 && lo < hi * 0.5 && abs(off - hi) < hi * 0.05, String(format: "Liquify: stylus pressure scales the warp (%.0f at 20%%, %.0f at 100%%, %.0f with Stylus Pressure off)", lo, hi, off))
    }

    // MARK: Performance

    /// A 300 px soft brush at 200+ tablet reports per second through the canvas event path.
    static func perf(quick: Bool) {
        let app = AppModel.shared
        let rig = Rig(width: 4000, height: 3000)
        rig.robot.setView(QAView(name: "z0.25", zoom: 0.25, offset: CGPoint(x: 20, y: 20)))
        app.tool = .brush
        app.brush = BrushSettings(size: 300, hardness: 0, spacing: 0.1, smoothing: 0.1)
        app.brush.pressureSize = true
        let n = quick ? 240 : 1200
        rig.down(CGPoint(x: 300, y: 1500), 0.4)
        var times: [Double] = []
        for i in 1...n {
            // 200 Hz pen moving ~1500 px/s on the document: 7.5 px per report, pressure swelling
            let p = CGPoint(x: 300 + Double(i) * 7.5, y: 1500 + sin(Double(i) / 40) * 500)
            let t0 = CFAbsoluteTimeGetCurrent()
            rig.drag(p, 0.5 + 0.4 * sin(Double(i) / 25))
            times.append(CFAbsoluteTimeGetCurrent() - t0)
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        rig.up(CGPoint(x: 300 + Double(n) * 7.5, y: 1500), 0)
        let finish = CFAbsoluteTimeGetCurrent() - t0
        let sorted = times.sorted()
        let avg = times.reduce(0, +) / Double(times.count)
        let p95 = sorted[Int(Double(sorted.count) * 0.95)], worst = sorted.last ?? 0
        let line = String(format: "tablet stroke 300px soft, %d reports: %.2f ms avg, %.2f ms p95, %.2f ms max per report (%.0f reports/s), finish %.0f ms",
                          n, avg * 1000, p95 * 1000, worst * 1000, 1 / max(1e-9, avg), finish * 1000)
        print(line)
        // breakdown: dab rasterizing alone, and with the stroke compositing (flush) but without the canvas
        if let st = PaintStroke(doc: rig.doc, layerID: rig.paintID, target: .content, opacity: 1, blend: .normal) {
            let eng = BrushDynamicsEngine(settings: app.brush, target: st.strokeBuf, origin: st.origin, paint: .fixed(.black), seed: 1)
            st.dynamics = eng
            eng.begin(PenSample(p: CGPoint(x: 300, y: 2400), pressure: 0.4))
            var engT = 0.0, flushT = 0.0
            for i in 1...n {
                let a = CFAbsoluteTimeGetCurrent()
                eng.move(PenSample(p: CGPoint(x: 300 + Double(i) * 7.5, y: 2400 + sin(Double(i) / 40) * 300), pressure: 0.5 + 0.4 * sin(Double(i) / 25)))
                let b = CFAbsoluteTimeGetCurrent()
                st.flush()
                engT += b - a; flushT += CFAbsoluteTimeGetCurrent() - b
            }
            st.finish(name: "perf")
            print(String(format: "  breakdown per report: dabs %.2f ms, stroke compositing %.2f ms, canvas / event path %.2f ms",
                         engT / Double(n) * 1000, flushT / Double(n) * 1000, max(0, avg - (engT + flushT) / Double(n)) * 1000))
        }
        check(1 / avg >= 200, "300 px soft brush keeps up with 200+ tablet reports per second (\(line))")
    }
}


