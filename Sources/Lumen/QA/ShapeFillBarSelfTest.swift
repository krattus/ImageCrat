import AppKit
import SwiftUI
import ImageCratCore

/// Shape tools' Fill / Stroke and the colour popovers (user reports: "a shape layer does not get the colour set in the
/// shape dialogue, but it is black" and "the colour fill menu gets cropped").
///
///     LUMEN_SELFTEST_ONLY=shapefill .build/debug/Lumen --selftest <outdir>
///
/// * the real shape tools driven with mouse events on an off-screen canvas, in Shape / Path / Pixels mode, after setting
///   the Fill and Stroke through the popover's own code paths (hex field, H S B fields typed in the real popover, the
///   bindings the picker writes) and after changing the foreground colour;
/// * the options bar per mode (Pixels: no Fill / Stroke, Mode / Opacity / Anti-alias instead);
/// * the selected shape layer edited from the bar in one undo step; ⌥⌫ on a shape layer;
/// * the popovers hosted at their content size: nothing outside the bounds, opaque background at every edge.
enum ShapeFillBarSelfTest {
    static func register() { FeatureModules.selfTests.append(("shapefill", { run($0) })) }

    static var failures = 0, passes = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = ok ? "" : detail()
        print("\(ok ? "PASS" : "FAIL") shapefill: \(name)\(d.isEmpty ? "" : " — " + d)")
    }

    static func run(_ out: URL) {
        failures = 0; passes = 0
        print("INFO shapefill: \(NSApp.windows.count) windows (\(NSApp.windows.filter(\.isVisible).count) visible) at start")
        let dir = out.appendingPathComponent("shapefill")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        popoverLayout(dir)
        settingsCoding()
        toolModes(dir)
        print("INFO shapefill: \(NSApp.windows.count) windows (\(NSApp.windows.filter(\.isVisible).count) visible) at end")
        print("shapefill: \(passes) passed, \(failures) failed")
    }

    // MARK: - Popover layout

    struct Bitmap {
        let rep: NSBitmapImageRep
        var w: Int { rep.pixelsWide }
        var h: Int { rep.pixelsHigh }
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
            var p = [Int](repeating: 0, count: 4)
            rep.getPixel(&p, atX: x, y: y)
            return (p[0], p[1], p[2], rep.samplesPerPixel > 3 ? p[3] : 255)
        }
    }

    /// The view hosted the way a popover hosts its content: the hosting view sized to its own fitting size
    /// (SwiftUI gives the popover that content size).
    static func hostAtFittingSize<V: View>(_ v: V) -> NSHostingView<AnyView> {
        let hv = NSHostingView(rootView: AnyView(v.environment(\.colorScheme, Theme.colorScheme).font(Theme.font).foregroundStyle(Theme.text)))
        hv.appearance = NSAppearance(named: Theme.colorScheme == .dark ? .darkAqua : .aqua)
        let s = hv.fittingSize
        hv.frame = CGRect(origin: .zero, size: CGSize(width: ceil(s.width), height: ceil(s.height)))
        hv.layoutSubtreeIfNeeded()
        return hv
    }

    static func render(_ v: NSView) -> Bitmap? {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return Bitmap(rep: rep)
    }

    static func save(_ b: Bitmap?, _ url: URL) {
        try? b?.rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// AppKit views inside the host (text fields, sliders…) that lie outside its bounds.
    static func outsideViews(_ hv: NSView) -> [String] {
        var bad: [String] = []
        func walk(_ v: NSView) {
            for s in v.subviews {
                let r = s.convert(s.bounds, to: hv)
                if !s.isHidden, r.width > 0, r.height > 0,
                   r.minX < -0.5 || r.minY < -0.5 || r.maxX > hv.bounds.width + 0.5 || r.maxY > hv.bounds.height + 0.5 {
                    bad.append("\(type(of: s)) \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))")
                }
                walk(s)
            }
        }
        walk(hv)
        return bad
    }

    /// Edge band (in points) that must be pure, opaque background: content cut off at a side would reach it.
    static func edgeProblems(_ b: Bitmap, band: Int) -> [String] {
        var issues: [String] = []
        let c = b.px(1, 1)
        if c.3 < 250 { issues.append("corner not opaque (alpha \(c.3))") }
        let scale = max(1, b.w / max(1, Int(b.rep.size.width)))
        let bw = band * scale
        func same(_ p: (Int, Int, Int, Int)) -> Bool { abs(p.0 - c.0) <= 3 && abs(p.1 - c.1) <= 3 && abs(p.2 - c.2) <= 3 && p.3 >= 250 }
        var counts = (left: 0, right: 0, top: 0, bottom: 0)
        for y in 0..<b.h {
            for x in 0..<bw where !same(b.px(x, y)) { counts.left += 1 }
            for x in (b.w - bw)..<b.w where !same(b.px(x, y)) { counts.right += 1 }
        }
        for x in 0..<b.w {
            for y in 0..<bw where !same(b.px(x, y)) { counts.top += 1 }
            for y in (b.h - bw)..<b.h where !same(b.px(x, y)) { counts.bottom += 1 }
        }
        if counts.left > 0 { issues.append("\(counts.left) non-background px at the left edge") }
        if counts.right > 0 { issues.append("\(counts.right) at the right edge") }
        if counts.top > 0 { issues.append("\(counts.top) at the top edge") }
        if counts.bottom > 0 { issues.append("\(counts.bottom) at the bottom edge") }
        return issues
    }

    static func popoverLayout(_ dir: URL) {
        let cyan = RGBA(hex: "00D9F5")!
        let grad = PaintStyle.gradient(GradientFill(gradient: .twoColor(.black, .white)))
        let variants: [(String, AnyView, AnyView)] = [
            ("fill-solid", AnyView(PaintStylePopoverContent(paint: .constant(.color(cyan)))), AnyView(PaintStyleEditor(paint: .constant(.color(cyan))))),
            ("fill-gradient", AnyView(PaintStylePopoverContent(paint: .constant(grad))), AnyView(PaintStyleEditor(paint: .constant(grad)))),
            ("fill-pattern", AnyView(PaintStylePopoverContent(paint: .constant(.pattern(id: "checker", scale: 1)))), AnyView(PaintStyleEditor(paint: .constant(.pattern(id: "checker", scale: 1))))),
            ("fill-none", AnyView(PaintStylePopoverContent(paint: .constant(.none))), AnyView(PaintStyleEditor(paint: .constant(.none)))),
            // opened from a narrow panel (Properties): the popover keeps its own layout
            ("fill-solid-from-panel", AnyView(PaintStylePopoverContent(paint: .constant(.color(cyan))).environment(\.panelWidth, 240)), AnyView(PaintStyleEditor(paint: .constant(.color(cyan))))),
            ("color-well", AnyView(ColorPickerView(color: .constant(cyan), showAlpha: true).colorPopoverContent()), AnyView(ColorPickerView(color: .constant(cyan), showAlpha: true))),
            ("foreground", AnyView(ColorPickerView(color: .constant(cyan), title: "Foreground Color").colorPopoverContent()), AnyView(ColorPickerView(color: .constant(cyan), title: "Foreground Color"))),
        ]
        for (name, popover, bare) in variants {
            let hv = hostAtFittingSize(popover)
            let size = hv.bounds.size
            // the content's own natural size, unconstrained
            let natural = hostAtFittingSize(bare.environment(\.panelWidth, .infinity).fixedSize()).bounds.size
            check(size.width > 100 && size.width < 700 && size.height > 30 && size.height < 1000, "\(name): popover size from the content's fitting size", "\(size)")
            check(natural.width + 24 <= size.width + 1 && natural.height + 24 <= size.height + 1,
                  "\(name): the content fits inside the popover at its natural size (no fixed width narrower than the content)",
                  "natural \(natural), popover \(size)")
            let outside = outsideViews(hv)
            check(outside.isEmpty, "\(name): nothing laid out at negative x / y or beyond the popover's width / height", outside.prefix(4).joined(separator: "; "))
            if let b = render(hv) {
                let issues = edgeProblems(b, band: 3)
                check(issues.isEmpty, "\(name): opaque background on every edge, no content cut off at a side", issues.joined(separator: "; "))
                if name == "fill-solid" { save(b, dir.appendingPathComponent("popover_fill_after.png")) }
                if name == "fill-gradient" { save(b, dir.appendingPathComponent("popover_gradient_after.png")) }
            } else {
                check(false, "\(name): rendered")
            }
        }
        // the layout the bug report showed (fixed 280 pt frame, no background): the same detectors must flag it
        let old = hostAtFittingSize(PaintStyleEditor(paint: .constant(.color(cyan))).padding(10).frame(width: 280))
        let natural = hostAtFittingSize(PaintStyleEditor(paint: .constant(.color(cyan))).fixedSize()).bounds.size
        if let b = render(old) {
            save(b, dir.appendingPathComponent("popover_fill_before.png"))
            let issues = edgeProblems(b, band: 6)
            check(natural.width + 20 > old.bounds.width && !issues.isEmpty,
                  "the old fixed-width layout is detected as cut off (the detectors catch the reported bug)",
                  "natural \(natural.width), old \(old.bounds.width), issues \(issues)")
            print("INFO shapefill: old popover \(old.bounds.size), content natural \(natural); \(issues.joined(separator: "; "))")
        }
        // dialogs embedding the colour picker: their content column is wide enough for it
        let pickerWidth = hostAtFittingSize(ColorPickerView(color: .constant(cyan)).fixedSize()).bounds.width
        check(pickerWidth <= ArtboardBackgroundDialog.width - 32 + 0.5, "Artboard Background Color dialog: the colour picker fits its column",
              "picker \(pickerWidth), column \(ArtboardBackgroundDialog.width - 32)")
    }

    // MARK: - Settings

    static func settingsCoding() {
        // tool presets saved before the Pixels-mode options existed still load
        let old = #"{"mode":"pixels","fill":{"color":{"_0":{"r":1,"g":0,"b":0,"a":1}}},"stroke":{"none":{}},"strokeWidth":7,"strokeAlignment":"center","cornerRadius":20,"sides":6,"starRatio":0.5,"lineWeight":4,"arrowEnd":false,"libraryID":"heart"}"#
        var s = ShapeToolSettings()
        s.mode = .pixels; s.strokeWidth = 7
        let enc = (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let decodedOld = try? JSONDecoder().decode(ShapeToolSettings.self, from: Data(old.utf8))
        if decodedOld == nil {
            // the PaintStyle encoding may differ from the literal above: strip the new keys from a real encoding instead
            var dict = (try? JSONSerialization.jsonObject(with: Data(enc.utf8))) as? [String: Any] ?? [:]
            for k in ["pixelBlendMode", "pixelOpacity", "pixelAntiAlias", "fromCenter", "constrainProportions"] { dict.removeValue(forKey: k) }
            let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
            let d2 = try? JSONDecoder().decode(ShapeToolSettings.self, from: data)
            check(d2?.mode == .pixels && d2?.strokeWidth == 7 && d2?.pixelOpacity == 1 && d2?.pixelBlendMode == .normal && d2?.pixelAntiAlias == true,
                  "settings saved without the Pixels-mode keys decode with their defaults")
        } else {
            check(decodedOld?.mode == .pixels && decodedOld?.strokeWidth == 7 && decodedOld?.pixelOpacity == 1 && decodedOld?.pixelAntiAlias == true,
                  "settings saved without the Pixels-mode keys decode with their defaults")
        }
        var n = ShapeToolSettings()
        n.pixelBlendMode = .multiply; n.pixelOpacity = 0.4; n.pixelAntiAlias = false; n.fromCenter = true; n.constrainProportions = true
        let back = (try? JSONEncoder().encode(n)).flatMap { try? JSONDecoder().decode(ShapeToolSettings.self, from: $0) }
        check(back == n, "Mode / Opacity / Anti-alias and the path options round-trip")
    }

    // MARK: - Tools on a canvas

    static let shapeTools: [ToolKind] = [.rectangle, .roundedRect, .ellipse, .polygon, .line, .customShape, .libraryShape, .triangle]

    static func near(_ p: (UInt8, UInt8, UInt8, UInt8), _ c: RGBA, _ tol: Int = 3) -> Bool {
        abs(Int(p.0) - c.r8) <= tol && abs(Int(p.1) - c.g8) <= tol && abs(Int(p.2) - c.b8) <= tol && p.3 >= 250
    }
    static func px(_ d: Document, _ id: UUID, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        guard let r = d.state.layer(id)?.raster else { return (0, 0, 0, 0) }
        return r.buffer.pixel(x - r.origin.x, y - r.origin.y)
    }
    static func hexOf(_ p: PaintStyle) -> String { p.solidColor.map { $0.hex + String(format: "@%.2f", $0.a) } ?? "\(p)" }

    /// The options bar's visible labels (accessibility texts of the hosted bar).
    static func barTexts(_ tool: ToolKind) -> [String] {
        let app = AppModel.shared
        let hook = app.toolChanged
        app.toolChanged = nil
        let prevTool = app.tool
        app.tool = tool
        defer { app.tool = prevTool; app.toolChanged = hook }
        let bar = OptionsBar()
        let w = UIFixesSelfTest.host(bar, CGSize(width: 1300, height: 36))
        defer { UIFixesSelfTest.close(w) }
        return UIFixesSelfTest.axTexts(w)
    }

    static func toolModes(_ dir: URL) {
        let app = AppModel.shared
        let saved = (tool: app.tool, fg: app.foreground, bg: app.background, shape: app.shapeTool, pen: app.penMode, docs: app.documents,
                     active: app.activeDocumentID, canvas: AppActions.canvas, hook: app.toolChanged, modal: AppActions.modalHook,
                     modes: ToolModes.memory, button: CanvasView.primaryButtonDown)
        var modalLog: [String] = []
        AppActions.modalHook = { title, _ in modalLog.append(title); return false }
        CanvasView.primaryButtonDown = { ToolRobot.buttonDown }
        app.documents = []; app.activeDocumentID = nil
        let r = ToolRobot(size: CGSize(width: 700, height: 500))
        defer {
            r.closeAll()
            // release the robot's off-screen window (nothing of this suite stays alive for the suites after it)
            ToolRobot.keepAlive.removeAll { $0 === r }
            r.window.contentView = nil
            r.window.orderOut(nil)
            ToolModes.memory = saved.modes
            app.tool = saved.tool; app.foreground = saved.fg; app.background = saved.bg; app.shapeTool = saved.shape; app.penMode = saved.pen
            app.documents = saved.docs; app.activeDocumentID = saved.active
            AppActions.canvas = saved.canvas; app.toolChanged = saved.hook; AppActions.modalHook = saved.modal
            CanvasView.primaryButtonDown = saved.button
        }
        func freshDoc() -> (Document, UUID) {
            r.closeAll()
            var st = DocumentState(width: 240, height: 160)
            st.layers = [ShapesFillsSelfTest.solidBackground(240, 160, .white)]
            let d = r.open(st, name: "shapefill")
            let bg = st.layers[0].id
            d.selectLayer(bg)
            return (d, bg)
        }
        let A = CGPoint(x: 40.37, y: 30.41), B = CGPoint(x: 140.37, y: 110.41)
        func drag(_ k: ToolKind) {
            if k == .line { r.dragLine(CGPoint(x: 40.37, y: 70.41), CGPoint(x: 140.37, y: 70.41), steps: 5) } else { r.dragLine(A, B, steps: 5) }
        }

        // 1. The fill typed into the real popover (hex field, then H) reaches the bar and the new shape layer
        do {
            app.shapeTool = ShapeToolSettings()
            app.foreground = .black
            var (d, _) = freshDoc()
            r.select(.rectangle); ToolModes.set(.shape, for: .rectangle)
            let w = UIFixesSelfTest.host(PaintStylePopoverContent(paint: ShapeBar.fillBinding), CGSize(width: 360, height: 520))
            // fields top to bottom: H S B R G B, hex, opacity (the headless host does not run onAppear, so they are matched by place)
            let fields = UIFixesSelfTest.fields(w)
            if fields.count >= 8, let hex = Optional(fields[6]) {
                UIFixesSelfTest.type("00D9F5", into: hex, w)
                if let e = UIFixesSelfTest.key("\r", code: 36, w) { w.sendEvent(e) }
                UIFixesSelfTest.spin(0.1)
                check(app.shapeTool.fill.solidColor?.hex == "00D9F5", "popover hex field: the bar's Fill becomes 00D9F5", hexOf(app.shapeTool.fill))
            } else {
                check(false, "popover hex field found", fields.map(\.stringValue).joined(separator: " | "))
            }
            w.makeFirstResponder(nil); UIFixesSelfTest.spin(0.1)
            r.makeCurrent()
            drag(.rectangle)
            let l1 = d.activeLayer
            check(l1?.shape?.fill.solidColor?.hex == "00D9F5", "Rectangle / Shape: the new layer is filled 00D9F5 (not the black foreground)", l1.map { hexOf($0.shape?.fill ?? .none) } ?? "no layer")
            // H typed in the popover (the selected shape is edited too — Photoshop's bar edits the selected shape)
            let fields2 = UIFixesSelfTest.fields(w)
            let hue = Int((RGBA(hex: "00D9F5")!.hsb.h * 360).rounded())
            if fields2.count >= 8, fields2[0].stringValue == "\(hue)", let h = Optional(fields2[0]) {
                UIFixesSelfTest.type("300", into: h, w)
                if let e = UIFixesSelfTest.key("\r", code: 36, w) { w.sendEvent(e) }
                UIFixesSelfTest.spin(0.1)
                let c = app.shapeTool.fill.solidColor
                check(c.map { abs($0.hsb.h * 360 - 300) < 1.5 } ?? false, "popover H field: the bar's Fill hue becomes 300°", hexOf(app.shapeTool.fill))
                check(d.activeLayer?.shape?.fill == app.shapeTool.fill, "…and the selected shape layer shows the same fill", hexOf(d.activeLayer?.shape?.fill ?? .none))
            } else {
                check(false, "popover H field found (\(hue))", fields2.map(\.stringValue).joined(separator: " | "))
            }
            UIFixesSelfTest.close(w)
            ShapeBar.commit("Shape Fill")
            (d, _) = freshDoc()
            r.select(.rectangle)
            let shown = ShapeBar.fillBinding.wrappedValue
            drag(.rectangle)
            check(d.activeLayer?.shape?.fill == shown && shown.solidColor.map { abs($0.hsb.h * 360 - 300) < 1.5 } == true,
                  "Rectangle / Shape: a new shape after the H edit gets exactly the bar's fill", "\(hexOf(d.activeLayer?.shape?.fill ?? .none)) vs \(hexOf(shown))")
        }

        // 2. Every shape tool × every mode, Fill / Stroke set through the picker's bindings, the foreground elsewhere
        let colors = ["E63946", "2A9D8F", "F4A261", "8338EC", "06D6A0", "FFB703", "3A86FF", "FB5607"]
        for (i, k) in shapeTools.enumerated() {
            app.shapeTool = ShapeToolSettings()
            app.shapeTool.lineWeight = 9
            app.foreground = .black
            let (d, bg) = freshDoc()
            r.select(k)
            ToolModes.set(.shape, for: k)
            // as the popover writes them: solid button, then the hex / H S B result (alpha kept), stroke colour and width
            let fillColor = RGBA(hex: colors[i])!
            ShapeBar.fillBinding.wrappedValue = .color(ShapeBar.fillBinding.wrappedValue.solidColor ?? .black)
            ShapeBar.fillBinding.wrappedValue = .color(fillColor.withAlpha(ShapeBar.fillBinding.wrappedValue.solidColor?.a ?? 1))
            let hsb = fillColor.hsb
            ShapeBar.fillBinding.wrappedValue = .color(RGBA(h: hsb.h, s: hsb.s, v: hsb.b, a: 1))
            ShapeBar.strokeBinding.wrappedValue = .color(RGBA(hex: "1D3557")!)
            ShapeBar.strokeWidthBinding.wrappedValue = 5
            ShapeBar.commit("x")
            let shownFill = ShapeBar.fillBinding.wrappedValue, shownStroke = ShapeBar.strokeBinding.wrappedValue
            let n0 = d.state.layers.count
            drag(k)
            let nl = d.activeLayer
            check(d.state.layers.count == n0 + 1 && nl?.isShape == true, "\(k.rawValue) / Shape: a new shape layer")
            check(nl?.shape?.fill == shownFill && shownFill.solidColor?.hex == fillColor.hex,
                  "\(k.rawValue) / Shape: fill is exactly the bar's Fill", "\(hexOf(nl?.shape?.fill ?? .none)) vs bar \(hexOf(shownFill))")
            check(nl?.shape?.stroke.paint == shownStroke && nl?.shape?.stroke.width == 5,
                  "\(k.rawValue) / Shape: stroke is exactly the bar's Stroke and width", "\(hexOf(nl?.shape?.stroke.paint ?? .none)) w \(nl?.shape?.stroke.width ?? -1)")
            // the foreground (Color panel) changes nothing in Shape mode
            app.foreground = RGBA(hex: "00FF00")!
            check(ShapeBar.fillBinding.wrappedValue == shownFill, "\(k.rawValue) / Shape: changing the foreground leaves the bar's Fill alone")
            d.selectLayer(bg)
            drag(k)
            check(d.activeLayer?.shape?.fill == shownFill, "\(k.rawValue) / Shape: after a foreground change the new shape still gets the bar's Fill",
                  hexOf(d.activeLayer?.shape?.fill ?? .none))
            // Path mode: a work path, no layer, no paint
            ToolModes.set(.path, for: k)
            d.selectLayer(bg)
            let n1 = d.state.layers.count, bgPrint = px(d, bg, 90, 70)
            drag(k)
            check(d.state.layers.count == n1 && !d.state.paths.isEmpty && px(d, bg, 90, 70) == bgPrint,
                  "\(k.rawValue) / Path: a work path only (no layer, nothing painted)")
            // Pixels mode: the foreground colour on the selected pixel layer, no new layer
            ToolModes.set(.pixels, for: k)
            check(app.shapeTool.mode == .pixels, "\(k.rawValue): Pixels mode set through the mode picker's path")
            d.selectLayer(bg)
            app.foreground = RGBA(hex: "C1121F")!
            let n2 = d.state.layers.count
            drag(k)
            check(d.state.layers.count == n2 && near(px(d, bg, 90, 70), app.foreground),
                  "\(k.rawValue) / Pixels: paints the foreground colour onto the selected layer (no new layer)", "\(px(d, bg, 90, 70))")
            check(!near(px(d, bg, 90, 70), fillColor), "\(k.rawValue) / Pixels: the (hidden) Fill colour is not used")
        }

        // 3. Pixels mode honours the bar's Mode, Opacity and Anti-alias
        do {
            app.shapeTool = ShapeToolSettings()
            let (d, bg) = freshDoc()
            r.select(.rectangle); ToolModes.set(.pixels, for: .rectangle)
            app.foreground = RGBA(r: 1, g: 0, b: 0)
            app.shapeTool.pixelOpacity = 0.5
            drag(.rectangle)
            let p = px(d, bg, 90, 70)
            check(abs(Int(p.0) - 255) <= 3 && abs(Int(p.1) - 128) <= 4 && abs(Int(p.2) - 128) <= 4, "Pixels: Opacity 50 % (red over white → 255,128,128)", "\(p)")
            app.shapeTool.pixelOpacity = 1
            app.foreground = RGBA(r: 0, g: 0, b: 1)
            drag(.rectangle)
            app.foreground = RGBA(r: 1, g: 0, b: 0)
            app.shapeTool.pixelBlendMode = .multiply
            drag(.rectangle)
            let m = px(d, bg, 90, 70)
            check(m.0 < 6 && m.1 < 6 && m.2 < 6, "Pixels: Mode Multiply (red × blue → black, Normal would give red)", "\(m)")
            app.shapeTool.pixelBlendMode = .normal
            // anti-alias: an ellipse edge has in-between values only with it on
            func edgeLevels(_ aa: Bool) -> Int {
                let (d2, bg2) = freshDoc()
                r.select(.ellipse); ToolModes.set(.pixels, for: .ellipse)
                app.foreground = .black
                app.shapeTool.pixelAntiAlias = aa
                r.dragLine(CGPoint(x: 30.5, y: 20.5), CGPoint(x: 197.3, y: 133.9), steps: 4)
                var partial = 0
                for y in 20..<136 { for x in 28..<200 { let v = Int(px(d2, bg2, x, y).0); if v > 8 && v < 247 { partial += 1 } } }
                return partial
            }
            let on = edgeLevels(true), off = edgeLevels(false)
            check(on > 20 && off == 0, "Pixels: Anti-alias on smooths the edge, off leaves hard pixels", "partial px on \(on), off \(off)")
            app.shapeTool.pixelAntiAlias = true
            // a shape layer is not painted over: the app asks to rasterize it, Cancel leaves it as it was
            let (d3, _) = freshDoc()
            r.select(.ellipse); ToolModes.set(.shape, for: .ellipse)
            drag(.ellipse)
            let sid = d3.activeLayerID!
            let before = d3.state.layer(sid)?.shape
            ToolModes.set(.pixels, for: .ellipse)
            modalLog = []
            drag(.ellipse)
            check(modalLog.contains { $0.contains("rasterized") } && d3.state.layer(sid)?.shape == before && d3.state.layer(sid)?.isShape == true,
                  "Pixels on a shape layer: asks to rasterize; Cancel keeps the shape untouched", modalLog.joined(separator: " | "))
        }

        // 4. Options bar contents per mode
        do {
            let (_, bg) = freshDoc()
            _ = bg
            r.select(.rectangle)
            ToolModes.set(.shape, for: .rectangle)
            let shape = barTexts(.rectangle)
            ToolModes.set(.path, for: .rectangle)
            let path = barTexts(.rectangle)
            ToolModes.set(.pixels, for: .rectangle)
            let pixels = barTexts(.rectangle)
            r.makeCurrent()
            check(shape.contains("Fill") && shape.contains("Stroke") && shape.contains("W") && shape.contains("H") && !shape.contains("Anti-alias"),
                  "bar / Shape: Fill, Stroke, W, H", shape.joined(separator: ","))
            check(!path.contains("Fill") && !path.contains("Stroke") && path.contains("Make:"), "bar / Path: Make: buttons, no Fill / Stroke", path.joined(separator: ","))
            check(!pixels.contains("Fill") && !pixels.contains("Stroke") && pixels.contains("Mode:") && pixels.contains("Anti-alias") && pixels.contains(where: { $0.hasPrefix("Opacity") }),
                  "bar / Pixels: no Fill / Stroke; Mode, Opacity, Anti-alias instead", pixels.joined(separator: ","))
            check([shape, path, pixels].allSatisfy { t in t.contains { ["Shape", "Path", "Pixels"].contains($0) } },
                  "the mode pop-up names the current mode", "\(shape.prefix(3)) \(path.prefix(3)) \(pixels.prefix(3))")
            ToolModes.set(.shape, for: .rectangle)
        }

        // 5. With a shape layer selected the bar shows and edits it, one undo step per change
        do {
            app.shapeTool = ShapeToolSettings()
            let (d, bg) = freshDoc()
            r.select(.ellipse); ToolModes.set(.shape, for: .ellipse)
            drag(.ellipse)
            let sid = d.activeLayerID!
            let orig = d.state.layer(sid)!.shape!.fill
            d.selectLayer(bg)
            app.shapeTool.fill = .color(RGBA(hex: "123456")!)
            d.selectLayer(sid)
            check(ShapeBar.fillBinding.wrappedValue == orig, "selected shape layer: the bar shows its Fill", hexOf(ShapeBar.fillBinding.wrappedValue))
            let h0 = d.history.count
            for v in ["FF0000", "FF4400", "FF8800"] { ShapeBar.fillBinding.wrappedValue = .color(RGBA(hex: v)!) }   // dragging in the picker
            ShapeBar.commit("Shape Fill")                                                                          // popover closed
            check(d.state.layer(sid)?.shape?.fill.solidColor?.hex == "FF8800" && d.history.count == h0 + 1 && d.history.last?.name == "Shape Fill",
                  "selected shape layer: Fill changed from the bar in one history step", d.history.suffix(3).map(\.name).joined(separator: ","))
            d.undo()
            check(d.state.layer(sid)?.shape?.fill == orig, "…one Undo restores the previous fill")
            d.redo()
            ShapeBar.strokeBinding.wrappedValue = .color(.black)
            ShapeBar.commit("Shape Stroke")
            ShapeBar.strokeWidthBinding.wrappedValue = 12
            ShapeBar.commit("Stroke Width")
            check(d.state.layer(sid)?.shape?.stroke.paint == .color(.black) && d.state.layer(sid)?.shape?.stroke.width == 12 && d.history.count == h0 + 3,
                  "selected shape layer: Stroke and width changed from the bar, one step each")
            let b0 = d.state.layer(sid)!.shape!.path.bounds
            ShapeBar.setSize(width: 50)
            ShapeBar.commit("Resize Shape")
            let b1 = d.state.layer(sid)!.shape!.path.bounds
            check(abs(b1.width - 50) < 0.01 && abs(b1.height - b0.height) < 0.01 && abs(b1.minX - b0.minX) < 0.01, "W field resizes the selected shape", "\(b0) → \(b1)")
            // a new shape drawn now gets what the bar shows (the selected shape's style)
            drag(.ellipse)
            check(d.activeLayer?.shape?.fill.solidColor?.hex == "FF8800" && d.activeLayer?.shape?.stroke.width == 12, "the next shape gets the style the bar shows")
            // ⌥⌫ sets a selected shape's fill to the foreground colour
            d.selectLayer(sid)
            app.foreground = RGBA(hex: "2B9348")!
            let h1 = d.history.count
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: r.window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51) {
                _ = KeyRouter.handle(e)
            }
            check(d.state.layer(sid)?.shape?.fill.solidColor?.hex == "2B9348" && d.state.layer(sid)?.isShape == true && d.history.count == h1 + 1,
                  "⌥⌫ on a shape layer: its fill becomes the foreground colour (one step, still a shape)", hexOf(d.state.layer(sid)?.shape?.fill ?? .none))
            check(modalLog.filter { $0.contains("rasterized") }.count <= 1, "⌥⌫ on a shape layer does not ask to rasterize")
            d.undo()
            check(d.state.layer(sid)?.shape?.fill.solidColor?.hex == "FF8800", "…Undo restores the previous fill")
            // on a pixel layer ⌥⌫ still fills pixels
            d.selectLayer(bg)
            app.foreground = RGBA(hex: "2B9348")!
            AppActions.fillForegroundShortcut()
            check(near(px(d, bg, 5, 5), app.foreground), "⌥⌫ on a pixel layer fills it with the foreground colour")
        }

        // 6. Pens in Shape mode: Fill / Stroke in the bar, used for the new shape
        do {
            app.shapeTool = ShapeToolSettings()
            app.foreground = .black
            let (d, _) = freshDoc()
            r.select(.freeformPen)
            ToolModes.set(.shape, for: .freeformPen)
            ShapeBar.fillBinding.wrappedValue = .color(RGBA(hex: "7209B7")!)
            let texts = barTexts(.freeformPen)
            r.makeCurrent()
            check(texts.contains("Fill") && texts.contains("Stroke"), "Freeform Pen / Shape: the bar shows Fill and Stroke", texts.joined(separator: ","))
            var pts: [CGPoint] = []
            for i in 0...24 { let a = Double(i) / 24 * 2 * .pi; pts.append(CGPoint(x: 120 + 50 * cos(a), y: 80 + 40 * sin(a))) }
            r.dragPath(pts)
            check(d.activeLayer?.shape?.fill.solidColor?.hex == "7209B7", "Freeform Pen / Shape: the new shape gets the bar's Fill", hexOf(d.activeLayer?.shape?.fill ?? .none))
            ToolModes.set(.path, for: .freeformPen)
            let tp = barTexts(.freeformPen)
            r.makeCurrent()
            check(!tp.contains("Fill"), "Freeform Pen / Path: no Fill in the bar")
        }
    }
}
