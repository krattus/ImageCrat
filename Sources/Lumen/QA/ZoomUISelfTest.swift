import AppKit
import SwiftUI
import ImageCratCore

/// Status-bar zoom control, zoom presets, fit modes, shortcuts and the field's keyboard isolation.
/// Geometry runs on a bare CanvasView; the field runs in the real StatusBar + canvas, hosted in an offscreen window and
/// typed into through the field editor with key events delivered the way the app does (KeyRouter first, then the window).
/// `LUMEN_SELFTEST_ONLY=zoomui Lumen --selftest <dir>`
enum ZoomUISelfTest {
    static func register() { FeatureModules.selfTests.append(("zoomui", { run($0) })) }

    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") zoomui: \(name)\(d.isEmpty ? "" : " — " + d)")
        fflush(stdout)
    }
    static func near(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) <= eps * max(1, abs(b)) }
    static func near(_ a: CGPoint, _ b: CGPoint, _ eps: CGFloat = 0.01) -> Bool { a.distance(to: b) <= eps }
    static func fmt(_ p: CGPoint) -> String { String(format: "(%.2f, %.2f)", p.x, p.y) }

    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    static func run(_ out: URL) {
        passes = 0; failures = 0
        let app = AppModel.shared
        let dir = out.appendingPathComponent("zoomui")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = (canvas: AppActions.canvas, hook: app.toolChanged, tool: app.tool, docs: app.documents, active: app.activeDocumentID,
                     anim: ZoomAnimator.enabled, fg: app.foreground, bg: app.background, status: app.statusMessage)
        defer {
            ZoomAnimator.stop()
            ZoomAnimator.enabled = saved.anim
            ZoomMath.screenPPIOverride = nil
            AppActions.canvas = saved.canvas; app.toolChanged = saved.hook; app.tool = saved.tool
            app.documents = saved.docs; app.activeDocumentID = saved.active
            app.foreground = saved.fg; app.background = saved.bg; app.statusMessage = saved.status
        }
        ZoomAnimator.enabled = false
        parsing()
        ladder()
        presets()
        fitModes()
        selectionAndLayer()
        anchors()
        perDocument()
        animation()
        commandsAndShortcuts()
        fieldInWindow(dir)
        snapshots(dir)
        print("zoomui: \(passes) passed, \(failures) failed")
    }

    // MARK: Harness

    /// A bare canvas (not in a window) that is `AppActions.canvas` for the duration of `body`.
    static func withCanvas(_ size: CGSize = CGSize(width: 800, height: 600), _ body: (CanvasView) -> Void) {
        let app = AppModel.shared
        let hook = app.toolChanged, prev = AppActions.canvas
        let c = CanvasView(frame: CGRect(origin: .zero, size: size))
        AppActions.canvas = c
        body(c)
        ZoomAnimator.stop()
        c.document = nil
        AppActions.canvas = prev; app.toolChanged = hook
    }

    /// Pumps the run loop. (Laying out the app's own SwiftUI window can make its canvas `AppActions.canvas`.)
    static func spin(_ c: CanvasView, _ s: Double) {
        UIFixesSelfTest.spin(s)
        AppActions.canvas = c
    }

    static func doc(_ w: Int, _ h: Int, rulers: Bool = false, layers: [Layer] = []) -> Document {
        var st = DocumentState(width: w, height: h)
        st.layers = layers
        let d = Document(state: st, name: "zoomui")
        d.needsFitOnScreen = false
        d.showRulers = rulers
        return d
    }

    /// View-space bounding box of a doc rect.
    static func viewBox(_ c: CanvasView, _ r: CGRect) -> CGRect {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)].map { c.docToView($0) }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// `r` fitted: inside the content area with the margin, touching it on at least one axis, centred.
    static func checkFitted(_ c: CanvasView, _ r: CGRect, _ name: String, expectClamp: Bool = false) {
        let a = c.contentArea, b = viewBox(c, r), m = CanvasView.fitMargin
        let centred = near(CGPoint(x: b.midX, y: b.midY), CGPoint(x: a.midX, y: a.midY), 0.05)
        if expectClamp {
            check(centred, "\(name): centred", "box \(b) area \(a)")
            return
        }
        let inside = b.minX >= a.minX + m - 0.05 && b.maxX <= a.maxX - m + 0.05 && b.minY >= a.minY + m - 0.05 && b.maxY <= a.maxY - m + 0.05
        let touches = abs(b.width - (a.width - 2 * m)) < 0.05 || abs(b.height - (a.height - 2 * m)) < 0.05
        check(inside && touches && centred, "\(name): fits with a \(Int(m)) pt margin, centred", "box \(b) area \(a) zoom \(c.document?.zoom ?? 0)")
    }

    // MARK: Parsing / formatting

    static func parsing() {
        let good: [(String, ZoomMath.Input)] = [
            ("150", .zoom(1.5)), ("150%", .zoom(1.5)), (" 150 % ", .zoom(1.5)), ("33.3", .zoom(0.333)), ("33,3", .zoom(0.333)),
            ("1:2", .zoom(0.5)), ("2:1", .zoom(2)), ("1 : 3", .zoom(1.0 / 3)), ("2x", .zoom(2)), ("0.5×", .zoom(0.5)), ("6.25", .zoom(0.0625)),
            ("fit", .fit), ("FIT", .fit), ("Fit on Screen", .fit), ("fill", .fill), ("Fill screen", .fill),
            ("100000", .zoom(ZoomMath.maxZoom)), ("0.5", .zoom(ZoomMath.minZoom)), ("1:1000", .zoom(ZoomMath.minZoom)), ("6400%", .zoom(64)),
        ]
        var bad: [String] = []
        for (s, want) in good {
            let got = ZoomMath.parse(s)
            let ok: Bool
            switch (got, want) {
            case (.zoom(let a)?, .zoom(let b)): ok = near(a, b, 1e-9)
            case (.fit?, .fit), (.fill?, .fill): ok = true
            default: ok = false
            }
            if !ok { bad.append("\(s) → \(String(describing: got))") }
        }
        check(bad.isEmpty, "field parses \(good.count) valid inputs (percent, decimals, ratios, multipliers, fit / fill, clamped)", bad.joined(separator: "; "))
        let invalid = ["", "   ", "abc", "0", "0%", "-50", "-1:2", "1:0", "0:5", ":2", "1:", "1:2:3", "nan", "inf", "infinity", "1e3", "50%%", "%", "fitt", "12abc", "1..5", "0x10"]
        let accepted = invalid.filter { ZoomMath.parse($0) != nil }
        check(accepted.isEmpty, "field rejects \(invalid.count) invalid inputs", "accepted \(accepted)")
        let fmts: [(Double, String)] = [(1, "100%"), (0.5, "50%"), (1.0 / 3, "33%"), (2.0 / 3, "67%"), (0.0625, "6.3%"), (0.05, "5.0%"), (0.01, "1.0%"),
                                       (0.0999, "10%"), (0.12, "12%"), (64, "6400%"), (1.505, "151%"), (0.0833, "8.3%")]
        let wrong = fmts.filter { ZoomMath.format($0.0) != $0.1 }.map { "\($0.0) → \(ZoomMath.format($0.0)) (want \($0.1))" }
        check(wrong.isEmpty, "zoom display: one decimal below 10 %, none above", wrong.joined(separator: "; "))
    }

    // MARK: Step ladder

    static func ladder() {
        var z = 1.0, ups: [Double] = []
        while z < ZoomMath.maxZoom { z = ZoomMath.stepIn(z); ups.append(z) }
        let expectUp = CanvasView.zoomSteps.filter { $0 > 1.01 }
        check(ups == expectUp, "⌘+ from 100 % walks the ladder up to 6400 %", "\(ups)")
        z = 1; var downs: [Double] = []
        while z > ZoomMath.minZoom { z = ZoomMath.stepOut(z); downs.append(z) }
        check(downs == CanvasView.zoomSteps.filter { $0 < 0.99 }.reversed(), "⌘− from 100 % walks the ladder down to 1 %", "\(downs)")
        check(ZoomMath.stepIn(64) == 64 && ZoomMath.stepOut(0.01) == 0.01, "the ladder stops at the range ends")
        check(ZoomMath.stepIn(1.5) == 2 && ZoomMath.stepOut(1.5) == 1 && ZoomMath.stepIn(0.333) == 0.5 && ZoomMath.stepOut(1.0 / 3) == 0.25,
              "off-ladder zooms step to the neighbouring ladder entries")
        withCanvas { c in
            let d = doc(1200, 900)
            c.document = d
            c.setZoom(1)
            let centre = CGPoint(x: c.bounds.midX, y: c.bounds.midY), p = c.viewToDoc(centre)
            ZoomController.run(.zoomIn)
            check(d.zoom == 2 && near(c.docToView(p), centre), "Zoom In button / ⌘+ steps to 200 % about the view centre", "zoom \(d.zoom) \(fmt(c.docToView(p)))")
            ZoomController.run(.zoomOut); ZoomController.run(.zoomOut)
            check(near(d.zoom, 0.6667) && near(c.docToView(p), centre), "Zoom Out button / ⌘− steps down about the view centre", "zoom \(d.zoom)")
            c.setZoom(64)
            check(!ZoomController.isEnabled(.zoomIn) && ZoomController.isEnabled(.zoomOut), "Zoom In is disabled at 6400 %")
        }
    }

    // MARK: Presets

    static func presets() {
        withCanvas { c in
            let d = doc(1600, 1000)
            c.document = d
            c.setZoom(0.3)
            let A = c.contentArea
            check(A == CGRect(x: 0, y: 0, width: 800, height: 600), "content area without rulers is the whole canvas", "\(A)")
            let docCentre = CGPoint(x: 800, y: 500), viewCentre = CGPoint(x: 400, y: 300)
            func preset(_ cmd: ZoomCommand, _ want: Double, centred: Bool) {
                c.setZoom(0.3, anchorView: CGPoint(x: 100, y: 80))
                let keep = c.viewToDoc(viewCentre)
                ZoomController.run(cmd)
                let at = centred ? docCentre : keep
                check(near(d.zoom, want, 1e-9) && near(c.docToView(at), viewCentre, 0.01),
                      "\(cmd.title) → \(ZoomMath.format(want)), \(centred ? "document centred" : "view centre kept")", "zoom \(d.zoom) \(fmt(c.docToView(at)))")
            }
            preset(.fitOnScreen, min(760.0 / 1600, 560.0 / 1000), centred: true)
            preset(.fillScreen, max(800.0 / 1600, 600.0 / 1000), centred: true)
            preset(.fitWidth, 760.0 / 1600, centred: true)
            preset(.fitHeight, 560.0 / 1000, centred: true)
            preset(.actualPixels, 1, centred: false)
            preset(.zoom200, 2, centred: false)
            ZoomMath.screenPPIOverride = 110
            d.state.resolution = 300
            preset(.printSize, 110.0 / 300, centred: false)
            d.state.resolution = 72
            preset(.printSize, 110.0 / 72, centred: false)
            ZoomMath.screenPPIOverride = nil
            check(ZoomMath.printSizeZoom(resolution: 72, screenPPI: 72) == 1 && ZoomMath.printSizeZoom(resolution: 0, screenPPI: 72) == 64,
                  "Print Size: 72 ppi on a 72 pt/in screen is 100 %; a zero resolution clamps")
            let ppi = ZoomMath.screenPointsPerInch(nil)
            check(ppi > 20 && ppi < 400, "this screen reports a plausible points-per-inch", String(format: "%.1f pt/in", ppi))
            preset(.devicePixels, ZoomController.devicePixelZoom, centred: false)

            // rulers shrink the content area; Fit centres in what's left
            d.showRulers = true
            let R = CanvasView.rulerSize
            check(c.contentArea == CGRect(x: R, y: R, width: 800 - R, height: 600 - R), "rulers are excluded from the content area", "\(c.contentArea)")
            ZoomController.run(.fitOnScreen)
            check(near(d.zoom, min((800 - R - 40) / 1600, (600 - R - 40) / 1000)), "Fit on Screen accounts for the rulers", "zoom \(d.zoom)")
            checkFitted(c, d.state.canvasCGRect, "Fit on Screen with rulers")
            d.showRulers = false

            // the preset menu: structure, and every ladder entry
            let m = ZoomController.presetMenu()
            let titles = m.items.filter { !$0.isSeparatorItem }.map(\.title)
            let wantTitles = ["Fit on Screen", "Fill Screen", "Fit Width", "Fit Height", "100% (Actual Pixels)", "200%", "Print Size", "Zoom to Selection", "Zoom to Layer"]
                + ZoomMath.ladder.map(\.label)
            check(wantTitles.allSatisfy(titles.contains), "preset menu lists fit modes, 100 / 200 %, Print Size, zoom to selection / layer and the ladder", "\(titles)")
            check(!titles.contains("Fit Artboard on Screen") && !titles.contains { $0.hasPrefix("Reset View Rotation") },
                  "no artboard / rotation items when there is nothing to fit or reset")
            check(m.items.first { $0.title == "Zoom to Selection" }?.isEnabled == false, "Zoom to Selection is disabled without a selection")
            check(m.items.first { $0.title == "Fit on Screen" }?.keyEquivalent == "0", "menu shows ⌘0 next to Fit on Screen")
            var ladderBad: [String] = []
            for (label, v) in ZoomMath.ladder {
                c.setZoom(0.2, anchorView: CGPoint(x: 90, y: 444))
                let keep = c.viewToDoc(viewCentre)
                let menu = ZoomController.presetMenu()
                // (the last match: 100 % and 200 % also have entries of their own above the ladder)
                guard let i = menu.items.lastIndex(where: { $0.title == label }) else { ladderBad.append("\(label) missing"); continue }
                menu.performActionForItem(at: i)
                if !near(d.zoom, v, 1e-9) || !near(c.docToView(keep), viewCentre, 0.01) { ladderBad.append("\(label): \(d.zoom)") }
                if ZoomController.presetMenu().items.last(where: { $0.title == label })?.state != .on { ladderBad.append("\(label) not checked") }
            }
            check(ladderBad.isEmpty, "each of the \(ZoomMath.ladder.count) ladder entries zooms about the view centre and is checked afterwards", ladderBad.joined(separator: "; "))
            c.setRotation(0.5)
            let mr = ZoomController.presetMenu()
            check(mr.items.contains { $0.title == "Reset View Rotation (29°)" }, "rotated view: Reset View Rotation shows the angle", "\(mr.items.map(\.title).suffix(2))")
            let keep = c.viewToDoc(viewCentre)
            if let i = mr.items.firstIndex(where: { $0.title.hasPrefix("Reset View Rotation") }) { mr.performActionForItem(at: i) }
            check(d.viewRotation == 0 && near(c.docToView(keep), viewCentre, 0.01), "Reset View Rotation keeps the view centre")
        }
    }

    // MARK: Fit modes

    static func fitModes() {
        withCanvas { c in
            for (name, w, h) in [("landscape", 3000, 2000), ("portrait", 1200, 4000), ("square", 900, 900)] {
                let d = doc(w, h)
                c.document = d
                for rot in [0.0, 0.3, .pi / 2, -2.2] {
                    c.setZoom(1); c.setRotation(rot)
                    ZoomController.run(.fitOnScreen)
                    checkFitted(c, d.state.canvasCGRect, "Fit on Screen, \(name) \(w)×\(h), view rotated \(Int((rot * 180 / .pi).rounded()))°")
                    ZoomController.run(.fillScreen)
                    let b = viewBox(c, d.state.canvasCGRect), a = c.contentArea
                    let covers = b.width >= a.width - 0.05 && b.height >= a.height - 0.05 && (abs(b.width - a.width) < 0.05 || abs(b.height - a.height) < 0.05)
                    check(covers && near(CGPoint(x: b.midX, y: b.midY), CGPoint(x: a.midX, y: a.midY), 0.05),
                          "Fill Screen, \(name), rotated \(Int((rot * 180 / .pi).rounded()))°: covers the area exactly on one axis, centred", "box \(b)")
                }
                c.setRotation(0)
                ZoomController.run(.fitWidth)
                let bw = viewBox(c, d.state.canvasCGRect)
                check(abs(bw.width - (c.contentArea.width - 40)) < 0.05, "Fit Width, \(name)", "box \(bw)")
                ZoomController.run(.fitHeight)
                let bh = viewBox(c, d.state.canvasCGRect)
                check(abs(bh.height - (c.contentArea.height - 40)) < 0.05, "Fit Height, \(name)", "box \(bh)")
            }
            // flipped view (View ▸ Flip Canvas View) fits the same way
            let tiny = doc(4, 3)
            c.document = tiny
            ZoomController.run(.fitOnScreen)
            check(d(tiny.zoom, 64), "Fit on Screen, tiny 4×3 document: clamped to 6400 %", "zoom \(tiny.zoom)")
            checkFitted(c, tiny.state.canvasCGRect, "tiny document", expectClamp: true)
            let huge = doc(200_000, 120_000)
            c.document = huge
            ZoomController.run(.fitOnScreen)
            check(d(huge.zoom, ZoomMath.minZoom), "Fit on Screen, huge 200000×120000 document: clamped to 1 %", "zoom \(huge.zoom)")
            checkFitted(c, huge.state.canvasCGRect, "huge document", expectClamp: true)
            let mid = doc(70_000, 400)      // fits only at 1.09 %: just inside the range
            c.document = mid
            ZoomController.run(.fitOnScreen)
            checkFitted(c, mid.state.canvasCGRect, "70000×400 panorama")
            // a canvas the window has squeezed to nothing doesn't produce a broken zoom
            let z0 = mid.zoom
            c.setFrameSize(NSSize(width: 6, height: 6))
            ZoomController.run(.fitOnScreen)
            check(mid.zoom == z0 && mid.zoom.isFinite, "Fit on Screen is ignored while the canvas has no room")
            c.setFrameSize(NSSize(width: 800, height: 600))
        }
        func d(_ a: Double, _ b: Double) -> Bool { near(a, b, 1e-9) }
    }

    // MARK: Zoom to selection / layer / artboard

    static func selectionAndLayer() {
        withCanvas { c in
            let shapeA = SelfTest.shapeLayer(CGRect(x: 600, y: 100, width: 300, height: 120), radius: 0)
            let shapeB = SelfTest.shapeLayer(CGRect(x: 100, y: 500, width: 80, height: 60), radius: 0)
            let d = doc(1000, 800, layers: [shapeA, shapeB])
            c.document = d
            c.setZoom(0.4)
            d.state.selection = SelectionOps.rectMask(CGRect(x: 100, y: 200, width: 50, height: 40), width: 1000, height: 800)
            let sb = d.state.selectionBounds?.cgRect
            check(ZoomController.isEnabled(.zoomToSelection), "Zoom to Selection is enabled with a selection")
            ZoomController.run(.zoomToSelection)
            if let sb {
                checkFitted(c, sb, "Zoom to Selection (\(Int(sb.width))×\(Int(sb.height)) at \(Int(sb.minX)),\(Int(sb.minY)))")
                check(near(d.zoom, min(760 / sb.width, 560 / sb.height)), "Zoom to Selection zoom", "zoom \(d.zoom)")
            } else { check(false, "selection bounds") }
            // a 1-pixel selection: clamped at 6400 %, still centred
            d.state.selection = SelectionOps.rectMask(CGRect(x: 10, y: 10, width: 1, height: 1), width: 1000, height: 800)
            ZoomController.run(.zoomToSelection)
            check(d.zoom == 64, "Zoom to Selection of one pixel clamps to 6400 %")
            checkFitted(c, CGRect(x: 10, y: 10, width: 1, height: 1), "one-pixel selection", expectClamp: true)
            d.state.selection = nil
            let z0 = d.zoom
            ZoomController.run(.zoomToSelection)
            check(d.zoom == z0 && !ZoomController.isEnabled(.zoomToSelection), "Zoom to Selection without a selection does nothing")

            d.selectLayer(shapeA.id)
            let ba = Compositor.shared.contentBounds(shapeA, state: d.state)!
            ZoomController.run(.zoomToLayer)
            checkFitted(c, ba, "Zoom to Layer (one layer)")
            d.selectLayer(shapeB.id, extend: true)
            let bu = ba.union(Compositor.shared.contentBounds(shapeB, state: d.state)!)
            check(ZoomController.selectedLayersBounds(d) == bu, "Zoom to Layer uses the union of the selected layers", "\(String(describing: ZoomController.selectedLayersBounds(d))) vs \(bu)")
            ZoomController.run(.zoomToLayer)
            checkFitted(c, bu, "Zoom to Layer (two layers)")
            c.setRotation(0.6)
            ZoomController.run(.zoomToLayer)
            checkFitted(c, bu, "Zoom to Layer in a rotated view")
            c.setRotation(0)
            // an empty layer: refused, view unchanged
            let empty = Layer.raster(name: "Empty", width: 1000, height: 800)
            d.state.layers.append(empty)
            d.selectLayer(empty.id)
            let zBefore = d.zoom, oBefore = d.viewOffset
            ZoomController.run(.zoomToLayer)
            check(d.zoom == zBefore && d.viewOffset == oBefore && AppModel.shared.statusMessage.contains("no visible content"), "Zoom to Layer on an empty layer is refused with a message")

            // artboards: Fit Artboard fits the active layer's artboard
            var child = SelfTest.shapeLayer(CGRect(x: 1250, y: 120, width: 100, height: 100))
            child.name = "In artboard"
            let ab = Layer(name: "Artboard 1", content: .group(GroupContent(children: [child], isExpanded: true, artboard: Artboard(rect: CGRect(x: 1200, y: 0, width: 390, height: 844)))))
            let d2 = doc(1600, 900, layers: [ab])
            c.document = d2
            d2.selectLayer(child.id)
            check(ZoomController.activeArtboard(d2)?.id == ab.id && ZoomController.isEnabled(.fitArtboard), "a layer inside an artboard finds its artboard")
            check(ZoomController.presetMenu().items.contains { $0.title == "Fit Artboard on Screen" }, "the preset menu offers Fit Artboard when the document has artboards")
            ZoomController.run(.fitArtboard)
            checkFitted(c, CGRect(x: 1200, y: 0, width: 390, height: 844), "Fit Artboard on Screen")
            // ⌘0 in an artboard document fits the artboards (and layers outside them), not the leftover canvas margins
            // (Photoshop's canvas is auto-sized to them); in a normal document it fits the whole canvas
            ZoomController.run(.fitOnScreen)
            checkFitted(c, CGRect(x: 1200, y: 0, width: 390, height: 844), "Fit on Screen in an artboard document fits the artboards, not the canvas margins")
            let plain = doc(1600, 900)
            c.document = plain
            ZoomController.run(.fitOnScreen)
            checkFitted(c, plain.state.canvasCGRect, "Fit on Screen in a normal document fits the whole canvas")
            c.document = d2
            d2.activeLayerID = nil; d2.selectedLayerIDs = []
            check(!ZoomController.isEnabled(.fitArtboard), "Fit Artboard is disabled with no artboard selected")
        }
    }

    // MARK: Anchors

    static func anchors() {
        withCanvas { c in
            let d = doc(1000, 700)
            c.document = d
            c.setZoom(0.8)
            var bad: [String] = []
            for rot in [0.0, 0.7] {
                c.setRotation(rot)
                for (a, k) in [(CGPoint(x: 123, y: 77), 1.7), (CGPoint(x: 700, y: 520), 0.37), (CGPoint(x: 5, y: 590), 3.1)] {
                    let p = c.viewToDoc(a)
                    c.setZoom(d.zoom * k, anchorView: a)          // the path pinch and ⌥/⌘-scroll take
                    if !near(c.docToView(p), a, 0.01) { bad.append("rot \(rot) anchor \(fmt(a)) → \(fmt(c.docToView(p)))") }
                }
            }
            check(bad.isEmpty, "pinch / scroll zoom keeps the point under the cursor fixed (also rotated)", bad.joined(separator: "; "))
            c.setRotation(0)
            let centre = CGPoint(x: c.bounds.midX, y: c.bounds.midY), p = c.viewToDoc(centre)
            let z0 = d.zoom
            ZoomController.scrub(by: 50, fast: false)
            check(near(d.zoom, z0 * pow(2, 0.5)) && near(c.docToView(p), centre), "scrubbing 50 pt right zooms in by √2 about the view centre", "zoom \(z0) → \(d.zoom)")
            ZoomController.scrub(by: -50, fast: true)
            check(near(d.zoom, z0 * pow(2, 0.5) / 4) && near(c.docToView(p), centre), "⇧-scrubbing is four times faster")
            ZoomController.apply(text: "250")
            check(d.zoom == 2.5 && near(c.docToView(p), centre), "a typed zoom applies about the view centre")
            let t = ZoomController.sliderFraction(1)
            check(near(ZoomController.zoom(forSlider: t), 1) && near(ZoomController.zoom(forSlider: 0), 0.01) && near(ZoomController.zoom(forSlider: 1), 64)
                  && near(ZoomController.zoom(forSlider: 2), 64), "slider maps 0…1 logarithmically onto 1 %…6400 % (round trip at 100 %)")
        }
    }

    // MARK: Per-document zoom

    static func perDocument() {
        withCanvas { c in
            let a = doc(1000, 700), b = doc(400, 3000)
            c.document = a
            ZoomController.run(.zoom200)
            let oa = a.viewOffset
            c.document = b
            ZoomController.run(.fitOnScreen)
            let zb = b.zoom
            check(a.zoom == 2 && a.viewOffset == oa, "zooming document B leaves document A's zoom and position alone")
            c.document = a
            check(c.zoom == 2 && c.offset == oa, "switching back shows A at its own zoom")
            ZoomController.run(.zoomOut)
            check(b.zoom == zb, "and B keeps its own")
        }
    }

    // MARK: Animation

    static func animation() {
        ZoomAnimator.enabled = true
        defer { ZoomAnimator.enabled = false; ZoomAnimator.stop() }
        guard ZoomAnimator.allowed else { check(true, "animation: Reduce Motion is on here, preset jumps are immediate"); return }
        withCanvas { c in
            let d = doc(2000, 1500)
            c.document = d
            c.setZoom(3)
            ZoomController.run(.fitOnScreen)
            let target = min(760.0 / 2000, 560.0 / 1500)
            check(ZoomAnimator.isRunning && d.zoom > target * 1.5, "Fit on Screen animates (still near the old zoom right after the command)", "zoom \(d.zoom)")
            spin(c, ZoomAnimator.duration + 0.2)
            check(!ZoomAnimator.isRunning && near(d.zoom, target), "the animation lands exactly on the fit zoom", "zoom \(d.zoom)")
            checkFitted(c, d.state.canvasCGRect, "after the animated fit")
            // a pinch / scroll during the transition takes over at once
            ZoomController.run(.actualPixels)
            c.setZoom(0.9, anchorView: CGPoint(x: 10, y: 10))
            let o = d.viewOffset
            spin(c, ZoomAnimator.duration + 0.1)
            check(!ZoomAnimator.isRunning && d.zoom == 0.9 && d.viewOffset == o, "a pinch / scroll zoom stops a running transition")
            // repeated ⌘+ finishes the previous step first: two presses are exactly two ladder steps
            c.setZoom(1)
            ZoomController.run(.zoomIn)
            ZoomController.run(.zoomIn)
            spin(c, ZoomAnimator.duration + 0.1)
            check(d.zoom == 3, "two quick ⌘+ presses land on 300 %", "zoom \(d.zoom)")
            // the document closing / switching mid-transition leaves the other document alone
            ZoomController.run(.fitOnScreen)
            let other = doc(500, 500)
            other.zoom = 1.25
            c.document = other
            spin(c, ZoomAnimator.duration + 0.1)
            check(other.zoom == 1.25, "a transition never moves the document switched to")
        }
    }

    // MARK: Commands, palette, shortcuts

    static func commandsAndShortcuts() {
        withCanvas { c in
            let d = doc(1600, 1000)
            c.document = d
            c.setZoom(0.5)
            let items = PaletteIndex.build(menu: nil)
            let wanted = ZoomCommand.viewMenu.compactMap { $0 }
            let missing = wanted.filter { cmd in !items.contains { $0.id == "menu:View ▸ " + cmd.title } }
            check(missing.isEmpty, "command palette has every View ▸ zoom command", "missing \(missing.map(\.title))")
            if let fit = items.first(where: { $0.id == "menu:View ▸ Fit on Screen" }) {
                check(fit.shortcut == "⌘0", "palette shows ⌘0 for Fit on Screen", fit.shortcut)
                fit.run()
                check(near(d.zoom, 0.475), "running Fit on Screen from the palette fits")
            }
            let hits = PaletteSearch.search("zoom to sel", items: items, frecency: nil).map(\.item.title)
            check(hits.first == "Zoom to Selection", "searching “zoom to sel” finds Zoom to Selection first", "\(hits.prefix(3))")

            // extra keys go through KeyRouter (the menu bar carries ⌘= / ⌘− / ⌘0 / ⌘1)
            let w = KeyableWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
            w.isReleasedWhenClosed = false
            func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            }
            c.setZoom(1)
            check(KeyRouter.handle(key("+", 24, [.command, .shift])) && d.zoom == 2, "⌘+ (⇧⌘=) zooms in", "zoom \(d.zoom)")
            check(KeyRouter.handle(key("+", 69, [.command, .numericPad])) && d.zoom == 3, "keypad ⌘+ zooms in")
            check(KeyRouter.handle(key("-", 78, [.command, .numericPad])) && d.zoom == 2, "keypad ⌘− zooms out")
            check(KeyRouter.handle(key("0", 29, [.command, .option])) && d.zoom == 1, "⌥⌘0 is 100 %")
            check(!KeyRouter.handle(key("=", 24, [.command])) && !KeyRouter.handle(key("0", 29, [.command])) && !KeyRouter.handle(key("1", 18, [.command]))
                  && !KeyRouter.handle(key("-", 27, [.command])), "⌘= / ⌘0 / ⌘1 / ⌘− are left to the View menu")
            check(!KeyRouter.handle(key("0", 29, [.command, .shift, .option])), "⇧⌥⌘0 is not taken")
            // no other command claims the zoom keys
            let zoomKeys: Set<String> = ["=", "+", "-", "0", "1"]
            let clash = MenuRegistry.items.filter { $0.key.map { zoomKeys.contains(String($0.character)) } ?? false }.map { "\($0.menu) ▸ \($0.title)" }
            check(clash.isEmpty, "no registered menu item uses ⌘= / + / − / 0 / 1", "\(clash)")

            // double-clicking the tool buttons
            c.setZoom(3)
            ZoomController.toolDoubleClicked(.hand)
            check(near(d.zoom, 0.475), "double-clicking the Hand tool fits on screen")
            ZoomController.toolDoubleClicked(.zoom)
            check(d.zoom == 1, "double-clicking the Zoom tool zooms to 100 %")
            ZoomController.toolDoubleClicked(.brush)
            check(d.zoom == 1, "other tools ignore the double-click")
            // the AppActions the Navigator, the options bar and the radial menu use go through the same commands
            AppActions.zoomIn(); check(d.zoom == 2, "AppActions.zoomIn")
            AppActions.fitOnScreen(); check(near(d.zoom, 0.475), "AppActions.fitOnScreen")
            AppActions.actualPixels(); check(d.zoom == 1, "AppActions.actualPixels")
            w.orderOut(nil)
        }
        // no canvas / no document: commands are disabled and do nothing
        let prev = AppActions.canvas
        AppActions.canvas = nil
        check(ZoomCommand.allCases.allSatisfy { !ZoomController.isEnabled($0) } && !ZoomController.apply(text: "200"), "without a document every zoom command is disabled")
        ZoomCommand.allCases.forEach { ZoomController.run($0) }
        AppActions.canvas = prev
    }

    // MARK: The field in the real status bar

    struct Scene: View {
        var body: some View {
            VStack(spacing: 0) {
                CanvasRepresentable()
                StatusBar()
            }
        }
    }

    static func zoomField(_ w: NSWindow) -> ZoomTextField? {
        func walk(_ v: NSView) -> ZoomTextField? {
            if let f = v as? ZoomTextField { return f }
            for s in v.subviews { if let f = walk(s) { return f } }
            return nil
        }
        return w.contentView.flatMap(walk)
    }

    static func fieldInWindow(_ out: URL) {
        let app = AppModel.shared
        let hook = app.toolChanged, prevCanvas = AppActions.canvas
        let d = doc(1600, 1000, layers: [Layer.raster(name: "Layer 1", width: 1600, height: 1000)])
        let prevDocs = app.documents, prevActive = app.activeDocumentID
        app.documents = [d]; app.activeDocumentID = d.id
        defer {
            app.documents = prevDocs; app.activeDocumentID = prevActive
            AppActions.canvas = prevCanvas; app.toolChanged = hook
        }
        let size = CGSize(width: 1000, height: 400)
        let hv = NSHostingView(rootView: Scene().environment(\.colorScheme, .dark).frame(width: size.width, height: size.height).background(Theme.appBG))
        let w = KeyableWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        UIFixesSelfTest.spin(0.5)
        defer { w.makeFirstResponder(nil); UIFixesSelfTest.spin(0.1); w.orderOut(nil); w.contentView = nil }
        func findCanvas(_ v: NSView) -> CanvasView? { (v as? CanvasView) ?? v.subviews.lazy.compactMap(findCanvas).first }
        guard let c = w.contentView.flatMap(findCanvas), c.document === d else { check(false, "real canvas hosted with the document"); return }
        AppActions.canvas = c
        guard let f = zoomField(w) else { check(false, "zoom field found in the status bar"); return }
        c.setZoom(1)
        spin(c, 0.15)
        check(f.stringValue == "100%", "status bar shows the zoom", f.stringValue)
        c.setZoom(2.5, anchorView: CGPoint(x: 30, y: 40))                 // a pinch
        spin(c, 0.15)
        check(f.stringValue == "250%", "the field follows pinch / scroll zooms live", f.stringValue)
        c.setZoom(0.0625)
        spin(c, 0.15)
        check(f.stringValue == "6.3%", "and shows one decimal below 10 %", f.stringValue)
        c.setZoom(1)
        spin(c, 0.1)

        func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
            if !KeyRouter.handle(e) { w.sendEvent(e) }       // the app's key monitor first, then the window
            spin(c, 0.03)
        }
        func editorText() -> String? { (w.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0.string : nil } }
        let codes: [Character: UInt16] = ["b": 11, "x": 7, "q": 12, "v": 9, "1": 18, "5": 23, "0": 29, "a": 0, "c": 8, "f": 3, "i": 34, "t": 17, ":": 41, "2": 19, "3": 20]
        func typeKeys(_ s: String) { for ch in s { key(String(ch), codes[ch] ?? 0) } }

        // click (no drag) on the label starts editing with everything selected
        func clickField() {
            let p = f.convert(NSPoint(x: f.bounds.midX, y: f.bounds.midY), to: nil)
            if let down = Fuzz.mouse(.leftMouseDown, p, w), let up = Fuzz.mouse(.leftMouseUp, p, w) { f.mouseDown(with: down); f.mouseUp(with: up) }
            spin(c, 0.1)
        }
        app.tool = .move
        let fg = app.foreground, bg = app.background
        clickField()
        check(f.isEditing && editorText() == "100%", "a click on the zoom label starts editing", "editing \(f.isEditing) text \(editorText() ?? "nil")")
        if let fe = w.firstResponder as? NSTextView {
            check(fe.selectedRange() == NSRange(location: 0, length: (fe.string as NSString).length), "the whole value is selected")
        }
        typeKeys("bxqv105")
        check(app.tool == .move && app.foreground == fg && app.background == bg && !d.quickMask,
              "typing tool / colour / quick-mask keys in the field doesn't reach the tools", "tool \(app.tool)")
        check(editorText() == "bxqv105", "the keys went into the field instead", editorText() ?? "nil")
        check(d.zoom == 1, "nothing applies before Return")
        if let fe = w.firstResponder as? NSTextView { fe.selectAll(nil) }
        typeKeys("150")
        key("\r", 36)
        check(d.zoom == 1.5, "Return applies the typed zoom", "zoom \(d.zoom)")
        check(w.firstResponder === c, "after Return the canvas has keyboard focus again", "\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
        spin(c, 0.1)
        check(f.stringValue == "150%" && !f.isEditing, "the field shows the applied zoom", f.stringValue)
        key("b", 11)
        // (B picks whichever brush-group tool was used last: Brush, Pencil…)
        check(app.tool != .move && app.tool.shortcut == "B", "single-key tool shortcuts work again after Return", "tool \(app.tool)")
        app.tool = .move

        clickField()
        typeKeys("300")
        key("\u{1b}", 53)
        check(d.zoom == 1.5 && f.stringValue == "150%" && w.firstResponder === c, "Esc cancels: zoom and text unchanged, focus back on the canvas",
              "zoom \(d.zoom) text \(f.stringValue)")
        key("v", 9)
        check(app.tool == .move && w.firstResponder === c, "shortcuts work after Esc")

        clickField()
        typeKeys("abc")
        key("\r", 36)
        check(d.zoom == 1.5 && f.stringValue == "150%", "invalid input reverts", f.stringValue)
        clickField()
        typeKeys("1:2")
        key("\r", 36)
        check(d.zoom == 0.5, "1:2 typed → 50 %", "zoom \(d.zoom)")
        clickField()
        typeKeys("fit")
        key("\r", 36)
        check(near(d.zoom, c.fitZoom(d.state.canvasCGRect)), "“fit” typed → Fit on Screen", "zoom \(d.zoom)")
        clickField()
        typeKeys("50")
        w.makeFirstResponder(c)                     // a click on the canvas ends editing
        spin(c, 0.1)
        check(d.zoom == 0.5 && f.stringValue == "50%", "focus leaving the field applies a valid typed value", "zoom \(d.zoom)")
        clickField()
        w.makeFirstResponder(c)
        spin(c, 0.1)
        check(d.zoom == 0.5, "clicking in and out without typing changes nothing")

        // scrubbing: press, drag sideways, release — zooms, doesn't start editing
        let centre = CGPoint(x: c.bounds.midX, y: c.bounds.midY), p = c.viewToDoc(centre)
        let o = f.convert(NSPoint(x: f.bounds.midX, y: f.bounds.midY), to: nil)
        if let down = Fuzz.mouse(.leftMouseDown, o, w), let d1 = Fuzz.mouse(.leftMouseDragged, NSPoint(x: o.x + 2, y: o.y), w),
           let d2 = Fuzz.mouse(.leftMouseDragged, NSPoint(x: o.x + 30, y: o.y), w), let d3 = Fuzz.mouse(.leftMouseDragged, NSPoint(x: o.x + 100, y: o.y + 4), w),
           let up = Fuzz.mouse(.leftMouseUp, NSPoint(x: o.x + 100, y: o.y + 4), w) {
            f.mouseDown(with: down)
            f.mouseDragged(with: d1)
            check(d.zoom == 0.5, "a 2 pt wobble doesn't scrub")
            f.mouseDragged(with: d2); f.mouseDragged(with: d3)
            f.mouseUp(with: up)
        }
        spin(c, 0.1)
        check(near(d.zoom, 1.0) && !f.isEditing && near(c.docToView(p), centre, 0.01), "dragging the label 100 pt right scrubs 50 % → 100 % about the view centre, without editing",
              "zoom \(d.zoom) editing \(f.isEditing)")
        check(f.stringValue == "100%" || { spin(c, 0.1); return f.stringValue == "100%" }(), "the label follows the scrub", f.stringValue)

        // − / + buttons (pressed through accessibility, as a click would)
        if let plus = UIFixesSelfTest.ax(w, "Zoom In", role: "AXButton"), let minus = UIFixesSelfTest.ax(w, "Zoom Out", role: "AXButton") {
            FuzzAX.press(plus); spin(c, 0.1)
            check(d.zoom == 2 && near(c.docToView(p), centre, 0.01), "the + button steps to 200 % about the view centre", "zoom \(d.zoom)")
            FuzzAX.press(minus); FuzzAX.press(minus); spin(c, 0.1)
            check(near(d.zoom, 0.6667), "the − button steps down the same ladder", "zoom \(d.zoom)")
        } else { check(false, "− / + buttons found") }
        check(UIFixesSelfTest.ax(w, "Zoom Presets", role: "AXButton") != nil, "the preset menu button is there")
        check(UIFixesSelfTest.ax(w, "Zoom slider") != nil, "the slider shows on a wide status bar")

        // switching documents: the field shows the active document's zoom
        let d2 = doc(500, 500)
        d2.zoom = 3
        app.documents.append(d2); app.activeDocumentID = d2.id
        spin(c, 0.2)
        check(c.document === d2 && f.stringValue == "300%", "the field shows the active document's zoom after switching", f.stringValue)
        app.activeDocumentID = d.id
        spin(c, 0.2)
        check(f.stringValue == ZoomMath.format(d.zoom), "and the first document's again on switching back", f.stringValue)
        app.tool = .move
    }

    // MARK: Snapshots

    static func snapshots(_ out: URL) {
        let app = AppModel.shared
        let hook = app.toolChanged, prevCanvas = AppActions.canvas
        let prevDocs = app.documents, prevActive = app.activeDocumentID, prevCursor = app.cursorDocPoint
        defer { app.documents = prevDocs; app.activeDocumentID = prevActive; AppActions.canvas = prevCanvas; app.toolChanged = hook; app.cursorDocPoint = prevCursor }
        let c = CanvasView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        AppActions.canvas = c
        let d = doc(3840, 2160)
        d.state.resolution = 300
        app.documents = [d]; app.activeDocumentID = d.id
        c.document = d
        app.cursorDocPoint = CGPoint(x: 1204, y: 388)
        func shoot(_ name: String, width: CGFloat, _ prepare: (NSWindow) -> Void = { _ in }) {
            let hv = NSHostingView(rootView: StatusBar().environment(\.colorScheme, .dark).frame(width: width, height: 24))
            let w = KeyableWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 24), styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = hv
            w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            w.orderFrontRegardless(); w.makeKey()
            spin(c, 0.3)
            prepare(w)
            spin(c, 0.2)
            UIFixesSelfTest.snapshot(w, name, out)
            w.makeFirstResponder(nil); UIFixesSelfTest.spin(0.05)
            w.orderOut(nil); w.contentView = nil
        }
        c.setZoom(0.25)
        shoot("statusbar_normal", width: 1000)
        shoot("statusbar_editing", width: 1000) { w in
            if let f = zoomField(w) { f.beginEditing(); UIFixesSelfTest.spin(0.1); (w.firstResponder as? NSTextView)?.insertText("1:2", replacementRange: NSRange(location: 0, length: f.stringValue.count + 10)) }
        }
        c.setZoom(0.0625)
        d.state.selection = SelectionOps.rectMask(CGRect(x: 100, y: 100, width: 640, height: 480), width: 3840, height: 2160)
        c.setRotation(-0.5236)
        shoot("statusbar_rotated", width: 1000)
        c.setRotation(0)
        c.setZoom(16)
        shoot("statusbar_narrow", width: 560)
        d.state.selection = nil
        // the preset menu can't be drawn offscreen: its items go to a text file instead
        c.setRotation(0.4)
        let lines = ZoomController.presetMenu().items.map { $0.isSeparatorItem ? "—" : "\($0.state == .on ? "✓ " : "  ")\($0.title)\($0.keyEquivalent.isEmpty ? "" : "   ⌘" + $0.keyEquivalent.uppercased())\($0.isEnabled ? "" : "   (disabled)")" }
        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("preset_menu.txt"), atomically: true, encoding: .utf8)
        c.setRotation(0)
        c.document = nil
        print("zoomui: wrote status bar snapshots and preset_menu.txt to \(out.path)")
    }
}
