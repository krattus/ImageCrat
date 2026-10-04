import AppKit
import CoreImage
import SwiftUI
import ImageCratCore

/// Headless tests for the ToolsModule (`LUMEN_SELFTEST_ONLY=tools .build/debug/Lumen --selftest <dir>`).
enum ToolsSelfTest {
    static func register() {
        FeatureModules.selfTests.append(("tools", { out in run(out) }))
    }

    static func check(_ ok: Bool, _ msg: String) { print(ok ? "ok   tools: \(msg)" : "FAIL tools: \(msg)") }

    static func run(_ out: URL) {
        let app = AppModel.shared
        let savedTool = app.tool
        defer { app.tool = savedTool; ToolsSettings.shared.symmetry = SymmetrySettings() }
        symmetry(out)
        perspectiveCrop(out)
        straighten(out)
        backgroundEraser(out)
        patternStamp(out)
        artHistory(out)
        curvature(out)
        shapes(out)
        typeMask(out)
        slices(out)
        snapshots(out)
        frames(out)
        measurements(out)
        windowSync()
        selectionBrush(out)
        smartGuides()
        artboards(out)
        toolbarAndKeys()
        persistence()
        taskBar()
        if ProcessInfo.processInfo.environment["LUMEN_SELFTEST_UI"] == "1" { uiSnapshots(out) }
    }

    // MARK: Helpers

    static func whiteDoc(_ w: Int = 480, _ h: Int = 320, name: String = "t") -> (Document, UUID) {
        var st = DocumentState(width: w, height: h)
        let bg = PixelBuffer(width: w, height: h)
        bg.context.setFillColor(RGBA.white.cgColor)
        bg.context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        bg.markDirty()
        let paint = Layer.raster(name: "Paint", width: w, height: h)
        st.layers = [Layer.raster(name: "Background", buffer: bg), paint]
        return (Document(state: st, name: name), paint.id)
    }

    static func checker(_ w: Int, _ h: Int, cell: Int, _ a: RGBA = RGBA(hex: "2E4057")!, _ b: RGBA = RGBA(hex: "F6AE2D")!) -> PixelBuffer {
        let buf = PixelBuffer(width: w, height: h)
        for y in stride(from: 0, to: h, by: cell) {
            for x in stride(from: 0, to: w, by: cell) {
                buf.context.setFillColor(((x / cell + y / cell) % 2 == 0 ? a : b).cgColor)
                buf.context.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        buf.markDirty()
        return buf
    }

    static func composite(_ st: DocumentState) -> PixelBuffer {
        RenderEngine.renderBuffer(Compositor.shared.composite(st), docRect: st.canvasRect, space: CanvasSpace(width: st.width, height: st.height))
    }

    static func canvas(for d: Document) -> CanvasView {
        let c = CanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        c.document = d
        d.zoom = 1
        d.viewOffset = .zero
        return c
    }

    static func event(_ p: CGPoint, _ mods: NSEvent.ModifierFlags = []) -> ToolEvent {
        ToolEvent(doc: p, view: p, pressure: 1, modifiers: mods, clickCount: 1, isTablet: false)
    }

    static func countAlpha(_ b: PixelBuffer, _ r: IRect, below: UInt8) -> Int {
        var n = 0
        for y in r.minY..<r.maxY { for x in r.minX..<r.maxX where b.alpha(x, y) < below { n += 1 } }
        return n
    }

    // MARK: Symmetry

    static func symmetry(_ out: URL) {
        let app = AppModel.shared
        app.tool = .brush
        let ts = ToolsSettings.shared
        let cases: [(String, SymmetryType, Int)] = [("vertical", .vertical, 0), ("dual", .dualAxis, 0), ("diagonal", .diagonal, 0), ("radial6", .radial, 6), ("mandala5", .mandala, 5)]
        for (name, type, seg) in cases {
            let (d, id) = whiteDoc(420, 420, name: "sym")
            SymmetryControls.activeTestDoc = d
            ts.symmetry = SymmetrySettings(enabled: true, type: type, segments: max(2, seg))
            let s = BrushSelfTest.brush(size: 14, hardness: 0.9, spacing: 0.08)
            let pts = (0...60).map { i -> PenSample in
                let t = Double(i) / 60
                return PenSample(p: CGPoint(x: 230 + 150 * t, y: 60 + 120 * t + 30 * sin(t * 9)))
            }
            BrushSelfTest.stroke(d, id, s, pts, fg: RGBA(hex: "8E24AA")!)
            SelfTest.save(d.state, "tools_symmetry_\(name)", out)
            if type == .vertical, let buf = d.state.layer(id)?.raster?.buffer {
                // mirrored across x = 210: the first dab (≈ 230,60) has a twin at ≈ 190,60
                check(buf.alpha(190, 60) > 128 && buf.alpha(230, 60) > 128, "vertical symmetry mirrors dabs")
            }
            if type == .radial, let buf = d.state.layer(id)?.raster?.buffer {
                // 6-fold: rotate the start point (230,60) by 60° around (210,210)
                let p = CGPoint(x: 230, y: 60).rotated(by: .pi / 3, around: CGPoint(x: 210, y: 210))
                check(buf.alpha(Int(p.x), Int(p.y)) > 128, "radial symmetry places rotated dabs")
            }
        }
        ts.symmetry.enabled = false
        let m = SymmetrySettings(enabled: true, type: .mandala, segments: 4).mirrors(of: CGPoint(x: 60, y: 50), width: 100, height: 100)
        check(m.count == 7, "mandala 4 gives 7 extra dabs (\(m.count))")
        SymmetryControls.activeTestDoc = nil
    }

    // MARK: Perspective crop / straighten

    static func perspectiveCrop(_ out: URL) {
        let W = 480, H = 360
        var st = DocumentState(width: W, height: H)
        let bg = PixelBuffer(width: W, height: H)
        bg.context.setFillColor(RGBA(hex: "DDDDDD")!.cgColor); bg.context.fill(CGRect(x: 0, y: 0, width: W, height: H)); bg.markDirty()
        let q = Quad(tl: CGPoint(x: 140, y: 60), tr: CGPoint(x: 360, y: 90), br: CGPoint(x: 420, y: 300), bl: CGPoint(x: 70, y: 280))
        let so = SmartObjectContent(source: .image(checker(240, 180, cell: 30)), quad: q, sourceName: "checker")
        st.layers = [Layer.raster(name: "Background", buffer: bg), Layer(name: "plane", content: .smartObject(so))]
        // flatten into pixels so the crop warps real pixels
        let flat = composite(st)
        st.layers = [Layer.raster(name: "Background", buffer: flat)]
        let d = Document(state: st, name: "persp")
        SelfTest.save(d.state, "tools_perspective_before", out)
        PerspectiveCropTool.apply(d, quad: q)
        SelfTest.save(d.state, "tools_perspective_after", out)
        let (w, h) = PerspectiveCropTool.outputSize(q)
        check(d.state.width == w && d.state.height == h, "perspective crop output size \(d.state.width)×\(d.state.height)")
        let res = composite(d.state)
        // cells should now be axis-aligned: the centre of the first cell (≈ w/16, h/12) is dark, the second light
        let c1 = res.pixel(w / 16, h / 12), c2 = res.pixel(w / 16 + w / 8, h / 12)
        check(Int(c1.0) + Int(c1.1) + Int(c1.2) < 300 && Int(c2.0) + Int(c2.1) + Int(c2.2) > 400, "perspective crop rectifies the plane (\(c1) / \(c2))")
    }

    static func straighten(_ out: URL) {
        let corr = StraightenCropTool.correction(for: CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 10))
        check(abs(corr + atan2(10, 100)) < 1e-6, "straighten correction for a line tilted down-right")
        let corrV = StraightenCropTool.correction(for: CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 100))
        check(abs(corrV - atan2(5, 100)) < 1e-6, "straighten snaps near-vertical lines to vertical")
        let s = StraightenCropTool.inscribedSize(400, 300, angle: 0.1)
        check(s.width < 400 && s.height < 300 && s.width > 300, "inscribed rect \(Int(s.width))×\(Int(s.height))")
        // a sea horizon rising to the right by 6° (textured so Vision can find it)
        let W = 640, H = 420
        let buf = PixelBuffer(width: W, height: H)
        let ctx = buf.context
        let sky = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "4D8CE6")!.cgColor, RGBA(hex: "CCE6FF")!.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: H / 2), options: [.drawsAfterEndLocation])
        var rng = SeededRandom(seed: 7)
        for _ in 0..<30 {
            ctx.setFillColor(RGBA(r: 1, g: 1, b: 1, a: 0.35).cgColor)
            ctx.fillEllipse(in: CGRect(x: rng.next() * Double(W), y: rng.next() * Double(H) * 0.3, width: 40 + rng.next() * 80, height: 12 + rng.next() * 20))
        }
        let a = -6.0 * .pi / 180
        let c = CGPoint(x: W / 2, y: H / 2)
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y); ctx.rotate(by: a)
        ctx.setFillColor(RGBA(hex: "0D3359")!.cgColor); ctx.fill(CGRect(x: -2000, y: 0, width: 4000, height: 2000))
        for _ in 0..<200 {
            ctx.setFillColor(RGBA(r: 0.2, g: 0.4, b: 0.55, a: 0.5).cgColor)
            ctx.fill(CGRect(x: -800 + rng.next() * 1600, y: rng.next() * 400, width: 12 + rng.next() * 40, height: 2))
        }
        ctx.restoreGState()
        buf.markDirty()
        var st = DocumentState(width: W, height: H)
        st.layers = [Layer.raster(name: "Background", buffer: buf)]
        let app = AppModel.shared
        let d = Document(state: st, name: "horizon")
        app.add(d)
        defer { app.close(d) }
        SelfTest.save(d.state, "tools_straighten_before", out)
        func horizonRow(_ r: PixelBuffer, _ x: Int) -> Int { (0..<r.height).first { let p = r.pixel(x, $0); return p.3 > 200 && p.0 < 40 && p.1 < 80 } ?? -1 }
        let sp = CanvasSpace(width: W, height: H)
        if let cg = RenderEngine.cgImage(Compositor.shared.composite(d), rect: sp.ciCanvas), let ang = StraightenCropTool.detectHorizon(cg) {
            print("     tools: Vision horizon angle \(String(format: "%.2f", ang * 180 / .pi))° (drawn: rising 6° to the right)")
            StraightenCropTool.autoStraighten(d)
            SelfTest.save(d.state, "tools_straighten_auto", out)
            let r = composite(d.state)
            let hl = horizonRow(r, 10), hr = horizonRow(r, r.width - 10)
            check(hl > 0 && abs(hl - hr) <= 4 && r.width < W, "auto straighten levels and crops (rows \(hl) / \(hr), \(r.width)×\(r.height))")
        } else {
            check(false, "Vision found no horizon")
        }
        let d2 = Document(state: st, name: "horizon2")
        app.add(d2)
        defer { app.close(d2) }
        let dx = cos(a) * 300, dy = sin(a) * 300
        StraightenCropTool.straighten(d2, radians: StraightenCropTool.correction(for: CGPoint(x: c.x - dx, y: c.y - dy), CGPoint(x: c.x + dx, y: c.y + dy)))
        SelfTest.save(d2.state, "tools_straighten_line", out)
        let r = composite(d2.state)
        let hl = horizonRow(r, 10), hr = horizonRow(r, r.width - 10)
        check(hl > 0 && abs(hl - hr) <= 3 && r.alpha(0, 0) == 255 && r.alpha(r.width - 1, r.height - 1) == 255,
              "straighten levels the horizon and crops the empty corners (rows \(hl) / \(hr))")
    }

    // MARK: Painting tools

    static func backgroundEraser(_ out: URL) {
        let app = AppModel.shared
        app.tool = .backgroundEraser
        let W = 400, H = 240
        var st = DocumentState(width: W, height: H)
        let buf = PixelBuffer(width: W, height: H)
        buf.context.setFillColor(RGBA(hex: "3A7BD5")!.cgColor); buf.context.fill(CGRect(x: 0, y: 0, width: W, height: H))
        buf.context.setFillColor(RGBA(hex: "E53935")!.cgColor); buf.context.fillEllipse(in: CGRect(x: 150, y: 70, width: 100, height: 100))
        buf.markDirty()
        let layer = Layer.raster(name: "Photo", buffer: buf)
        st.layers = [layer]
        let d = Document(state: st, name: "bgerase")
        let c = canvas(for: d)
        let t = BackgroundEraserTool(kind: .backgroundEraser, canvas: c)
        let ts = ToolsSettings.shared
        let saved = (ts.bgEraserBrush, ts.bgSampling, ts.bgLimits, ts.bgTolerance)
        defer { (ts.bgEraserBrush, ts.bgSampling, ts.bgLimits, ts.bgTolerance) = saved }
        ts.bgEraserBrush = BrushSettings(size: 70, hardness: 1, spacing: 0.1, smoothing: 0)
        ts.bgEraserBrush.pressureSize = false
        ts.bgSampling = .once
        ts.bgLimits = .discontiguous
        ts.bgTolerance = 30
        d.selectLayer(layer.id)
        t.begin(d, layerID: layer.id)
        var placer = DabPlacer(spacing: 6, smoothing: 0)
        var dabs = placer.begin(CGPoint(x: 40, y: 120), pressure: 1)
        dabs += placer.move(CGPoint(x: 360, y: 120), pressure: 1, final: true)
        t.dabs(dabs)
        t.end()
        SelfTest.save(d.state, "tools_bg_eraser", out)
        let r = d.state.layer(layer.id)!.raster!.buffer
        check(r.alpha(60, 120) < 10, "background eraser removes the sampled blue")
        check(r.alpha(200, 120) > 250, "background eraser keeps the red circle")
        check(r.alpha(60, 20) > 250, "background eraser only erases inside the brush")
    }

    static func patternStamp(_ out: URL) {
        let app = AppModel.shared
        app.tool = .patternStamp
        let (d, id) = whiteDoc(420, 260)
        let c = canvas(for: d)
        let t = StampBrushTool(kind: .patternStamp, canvas: c)
        let ts = ToolsSettings.shared
        let saved = (ts.patternStampBrush, ts.patternID)
        defer { (ts.patternStampBrush, ts.patternID) = saved }
        ts.patternStampBrush = BrushSettings(size: 70, hardness: 0.7, spacing: 0.1, smoothing: 0)
        ts.patternStampBrush.pressureSize = false
        ts.patternID = "dots"
        d.selectLayer(id)
        t.begin(d, layerID: id, target: .content, at: CGPoint(x: 40, y: 130))
        t.paint((0...40).map { i in CGPoint(x: 40 + Double(i) * 8.5, y: 130 + sin(Double(i) / 4) * 50) })
        SelfTest.save(d.state, "tools_pattern_stamp", out)
        let r = d.state.layer(id)!.raster!.buffer
        check(r.alpha(40, 130) > 200 && r.alpha(40, 20) == 0, "pattern stamp paints the pattern along the stroke")
    }

    static func artHistory(_ out: URL) {
        let app = AppModel.shared
        app.tool = .artHistoryBrush
        let W = 420, H = 280
        let img = PixelBuffer(width: W, height: H)
        let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "FF7E5F")!.cgColor, RGBA(hex: "2E4057")!.cgColor] as CFArray, locations: [0, 1])!
        img.context.drawLinearGradient(g, start: .zero, end: CGPoint(x: W, y: H), options: [])
        img.context.setFillColor(RGBA(hex: "F6E27A")!.cgColor); img.context.fillEllipse(in: CGRect(x: 250, y: 40, width: 110, height: 110))
        img.context.setFillColor(RGBA(hex: "1E6F3A")!.cgColor); img.context.fill(CGRect(x: 0, y: 190, width: W, height: 90))
        img.markDirty()
        var st = DocumentState(width: W, height: H)
        let layer = Layer.raster(name: "Photo", buffer: img)
        st.layers = [layer]
        let d = Document(state: st, name: "arthistory")
        // wipe the layer to white (history step 1), then paint back with the art history brush from step 0
        let white = PixelBuffer(width: W, height: H)
        white.context.setFillColor(RGBA.white.cgColor); white.context.fill(CGRect(x: 0, y: 0, width: W, height: H)); white.markDirty()
        d.updateLayer(layer.id) { $0.raster = RasterContent(buffer: white, origin: .zero) }
        d.commit("Fill")
        app.historyBrushSource = 0
        let ts = ToolsSettings.shared
        let saved = (ts.artHistoryBrush, ts.artStyle, ts.artArea)
        defer { (ts.artHistoryBrush, ts.artStyle, ts.artArea) = saved; app.historyBrushSource = nil }
        let c = canvas(for: d)
        for (row, style) in [(0, ArtHistoryStyle.tightShort), (1, .looseLong), (2, .tightCurl)] {
            ts.artHistoryBrush = BrushSettings(size: 5, hardness: 1, spacing: 1.5, smoothing: 0)
            ts.artHistoryBrush.pressureSize = false
            ts.artStyle = style
            ts.artArea = 60
            let t = StampBrushTool(kind: .artHistoryBrush, canvas: c)
            let y = 50 + Double(row) * 90
            t.begin(d, layerID: layer.id, target: .content, at: CGPoint(x: 20, y: y))
            var pts: [CGPoint] = []
            for pass in 0..<3 { for i in 0...50 { pts.append(CGPoint(x: 20 + Double(i) * 7.6, y: y - 20 + Double(pass) * 20)) } }
            t.paint(pts)
        }
        SelfTest.save(d.state, "tools_art_history", out)
        let r = d.state.layer(layer.id)!.raster!.buffer
        var changed = 0
        for y in stride(from: 0, to: H, by: 4) { for x in stride(from: 0, to: W, by: 4) { let p = r.pixel(x, y); if p.0 < 240 || p.1 < 240 || p.2 < 240 { changed += 1 } } }
        check(changed > 2000, "art history brush paints strokes from the history source (\(changed) samples)")
    }

    static func selectionBrush(_ out: URL) {
        let st = SelfTest.baseState(400, 260)
        let d = Document(state: st, name: "selbrush")
        let m = PixelBuffer(width: 400, height: 260, format: .gray)
        var s = BrushSettings(size: 40, hardness: 0.5, spacing: 0.1, smoothing: 0)
        s.pressureSize = false
        for i in 0...60 { SelectionBrushTool.dab(m, at: CGPoint(x: 50 + Double(i) * 5, y: 130 + sin(Double(i) / 6) * 60), settings: s, subtract: false) }
        for i in 0...20 { SelectionBrushTool.dab(m, at: CGPoint(x: 150 + Double(i) * 5, y: 130), settings: s, subtract: true) }
        m.markDirty()
        d.setSelection(m, commitName: "Selection Brush")
        var vis = d.state
        let tint = PixelBuffer(width: 400, height: 260)
        tint.context.saveGState()
        tint.clip(toMask: m.makeCGImage(), in: CGRect(x: 0, y: 0, width: 400, height: 260))
        tint.context.setFillColor(RGBA(r: 1, g: 0, b: 0, a: 0.5).cgColor)
        tint.context.fill(CGRect(x: 0, y: 0, width: 400, height: 260))
        tint.context.restoreGState()
        tint.markDirty()
        vis.layers.append(Layer.raster(name: "overlay", buffer: tint))
        SelfTest.save(vis, "tools_selection_brush", out)
        let sel = d.state.selection!
        check(sel.alpha(50, 130) > 200 && sel.alpha(200, 130) < 60 && sel.alpha(50, 20) == 0, "selection brush adds and subtracts")
    }

    // MARK: Vectors

    static func curvature(_ out: URL) {
        let pts = [CGPoint(x: 40, y: 200), CGPoint(x: 120, y: 60), CGPoint(x: 220, y: 180), CGPoint(x: 320, y: 50), CGPoint(x: 400, y: 190)]
        let anchors = CurvatureMath.anchors(pts, corners: [3])
        check(zip(anchors, pts).allSatisfy { $0.anchor == $1 }, "curvature path passes through the clicked points")
        check(anchors[1].hasHandles && !anchors[3].hasHandles && !anchors[0].hasHandles, "curvature smooth/corner points")
        let a = anchors[1]
        let colinear = abs((a.outControl - a.anchor).normalized.dot((a.anchor - a.inControl).normalized) - 1) < 1e-6
        check(colinear, "curvature handles are colinear (smooth)")
        // add anchor: splitting must not change the curve
        let sub = Subpath(points: anchors)
        let split = CurvatureMath.split(sub, segment: 1, t: 0.4)
        check(split.points.count == 6, "add anchor point inserts one anchor")
        var maxErr: CGFloat = 0
        let original = VectorPath(subpaths: [sub])
        for k in 0...40 {
            let t = CGFloat(k) / 40
            let s0 = split.points[1], s1 = split.points[2], s2 = split.points[3]
            let q = t < 0.5 ? CurvatureMath.bezier(s0.anchor, s0.outControl, s1.inControl, s1.anchor, t * 2)
                            : CurvatureMath.bezier(s1.anchor, s1.outControl, s2.inControl, s2.anchor, (t - 0.5) * 2)
            if let (_, _, _, dist) = CurvatureMath.nearestSegment(original, to: q) { maxErr = max(maxErr, dist) }
        }
        check(maxErr < 0.05, "split curve matches the original (max err \(String(format: "%.4f", maxErr)))")
        let del = AnchorEditTool.deleting(VectorPath(subpaths: [split]), 0, 2)
        check(del.subpaths[0].points.count == 5, "delete anchor point removes one anchor")
        // headless tool run through a document
        let (d, _) = whiteDoc(440, 260, name: "curv")
        let c = canvas(for: d)
        AppModel.shared.penMode = .shape
        let tool = CurvaturePenTool(kind: .curvaturePen, canvas: c)
        tool.start(d, at: pts[0])
        for p in pts.dropFirst() { tool.add(p, d: d) }
        tool.commit()
        var st = d.state
        for p in pts {
            st.layers.append(Layer(name: "dot", content: .shape(ShapeContent(geometry: .ellipse(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), fill: .color(RGBA(hex: "E53935")!)))))
        }
        if let i = st.layers.firstIndex(where: { $0.isShape }) {
            st.layers[i].shape?.fill = .none
            st.layers[i].shape?.stroke = StrokeStyle(paint: .color(RGBA(hex: "1E88E5")!), width: 4, alignment: .center)
        }
        SelfTest.save(st, "tools_curvature_pen", out)
        check(d.state.layers.contains { $0.shape?.path.subpaths.first?.points.count == pts.count }, "curvature pen creates a shape layer with \(pts.count) anchors")
    }

    static func shapes(_ out: URL) {
        var st = SelfTest.baseState(520, 300)
        func shape(_ p: VectorPath, _ hex: String) -> Layer { Layer(name: "s", content: .shape(ShapeContent(geometry: .path(p), fill: .color(RGBA(hex: hex)!)))) }
        st.layers.append(shape(TriangleShape.path(CGRect(x: 20, y: 30, width: 140, height: 120), radius: 0), "E53935"))
        st.layers.append(shape(TriangleShape.path(CGRect(x: 180, y: 30, width: 140, height: 120), radius: 18), "1E88E5"))
        st.layers.append(shape(TriangleShape.path(CGRect(x: 340, y: 30, width: 160, height: 120), radius: 40), "43A047"))
        st.layers.append(shape(LineArrows.path(from: CGPoint(x: 30, y: 200), to: CGPoint(x: 240, y: 200), weight: 6, start: false, end: true), "2E4057"))
        st.layers.append(shape(LineArrows.path(from: CGPoint(x: 30, y: 260), to: CGPoint(x: 240, y: 240), weight: 5, start: true, end: true, concavityPct: 30), "8E24AA"))
        st.layers.append(shape(LineArrows.path(from: CGPoint(x: 280, y: 270), to: CGPoint(x: 490, y: 190), weight: 8, start: true, end: true, widthPct: 300, lengthPct: 400, concavityPct: -30), "FB8C00"))
        SelfTest.save(st, "tools_shapes_triangle_arrows", out)
        let tri = TriangleShape.path(CGRect(x: 0, y: 0, width: 100, height: 100), radius: 10).cgPath
        check(tri.contains(CGPoint(x: 50, y: 60)) && !tri.contains(CGPoint(x: 5, y: 5)), "rounded triangle geometry")
        let ar = LineArrows.path(from: .zero, to: CGPoint(x: 200, y: 0), weight: 4, start: false, end: true).cgPath
        check(ar.contains(CGPoint(x: 165, y: 8)) && !ar.contains(CGPoint(x: 100, y: 8)) && ar.contains(CGPoint(x: 199, y: 0)), "arrowhead is wider than the line")
    }

    static func typeMask(_ out: URL) {
        let app = AppModel.shared
        let st = SelfTest.baseState(480, 220)
        let d = Document(state: st, name: "typemask")
        app.add(d)
        defer { app.close(d) }
        let c = canvas(for: d)
        app.tool = .typeMaskHorizontal
        let saved = app.textTool
        defer { app.textTool = saved }
        app.textTool.fontName = "Helvetica-Bold"
        app.textTool.fontSize = 120
        let tool = TypeMaskTool(kind: .typeMaskHorizontal, canvas: c)
        let layersBefore = d.state.allLayers.count
        tool.mouseDown(event(CGPoint(x: 30, y: 150)))
        tool.mouseUp(event(CGPoint(x: 30, y: 150)))
        tool.inner.testType("LUMEN")
        tool.commit()
        check(d.state.allLayers.count == layersBefore, "type mask does not leave a type layer")
        check(d.state.selection != nil && d.history.last?.name == "Type Mask", "type mask creates a selection (\(d.history.last?.name ?? "-"))")
        if let sel = d.state.selection {
            // fill the selection to visualise it
            var vis = d.state
            let fill = PixelBuffer(width: 480, height: 220)
            fill.context.saveGState()
            fill.clip(toMask: sel.makeCGImage(), in: CGRect(x: 0, y: 0, width: 480, height: 220))
            fill.context.setFillColor(RGBA(hex: "1B1F3A")!.cgColor)
            fill.context.fill(CGRect(x: 0, y: 0, width: 480, height: 220))
            fill.context.restoreGState()
            fill.markDirty()
            vis.layers.append(Layer.raster(name: "fill", buffer: fill))
            vis.selection = nil
            SelfTest.save(vis, "tools_type_mask", out)
            let b = sel.opaqueBounds() ?? .zero
            check(b.width > 250 && b.height > 60, "type mask selection bounds \(b.width)×\(b.height)")
        }
    }

    // MARK: Slices, snapshots, frames

    static func slices(_ out: URL) {
        var st = SelfTest.baseState(400, 300)
        st.layers.append(SelfTest.shapeLayer(CGRect(x: 40, y: 40, width: 120, height: 90)))
        st.toolData.slices = [DocSlice(rect: CGRect(x: 40, y: 40, width: 120, height: 90)), DocSlice(rect: CGRect(x: 220, y: 150, width: 140, height: 120), name: "button")]
        let items = SliceLayout.items(st)
        check(items.filter(\.user).count == 2 && items.count > 2, "slice layout: \(items.count) slices (2 user + auto)")
        let area = items.reduce(0) { $0 + $1.rect.width * $1.rect.height }
        check(abs(area - 400 * 300) < 1, "slices cover the canvas exactly")
        let dir = out.appendingPathComponent("tools_slices")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = (try? SliceExport.export(st, to: dir, baseName: "doc", includeAuto: false)) ?? []
        check(urls.count == 2 && urls.contains { $0.lastPathComponent == "button.png" }, "export slices wrote \(urls.map(\.lastPathComponent))")
        if let first = urls.first, let src = CGImageSourceCreateWithURL(first as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            check(img.width == 120 && img.height == 90, "slice PNG size \(img.width)×\(img.height)")
        }
        let all = (try? SliceExport.export(st, to: dir, baseName: "all", includeAuto: true)) ?? []
        check(all.count == items.count, "export with auto slices wrote \(all.count) files")
    }

    static func snapshots(_ out: URL) {
        let (d, id) = whiteDoc(300, 200, name: "snap")
        let store = SnapshotStore.shared
        store.ensureInitial(d)
        d.updateLayer(id) { $0.name = "Edited" }
        d.commit("Rename")
        let snap = store.newSnapshot(d, name: "After rename")
        d.state.layers.append(SelfTest.shapeLayer(CGRect(x: 20, y: 20, width: 100, height: 80)))
        d.commit("Add shape")
        let before = d.history.count
        store.revert(d, to: snap)
        check(d.state.layers.count == 2 && d.state.layers[1].name == "Edited", "revert to snapshot restores its state")
        check(d.history.count == before + 1 && d.history.last?.name == "Snapshot: After rename", "revert is a new history step (non-destructive)")
        d.undo()
        check(d.state.layers.count == 3, "undo after snapshot revert returns to the later state")
        check(store.snapshots(d).count == 2, "initial + new snapshot listed")
        let n = AppModel.shared.documents.count
        let nd = store.newDocument(from: snap, of: d)
        check(AppModel.shared.documents.count == n + 1 && nd.state.layers.count == 2, "new document from snapshot")
        AppModel.shared.close(nd)
    }

    static func frames(_ out: URL) {
        let app = AppModel.shared
        var st = SelfTest.baseState(480, 320)
        st.layers.append(SelfTest.shapeLayer(CGRect(x: 10, y: 10, width: 60, height: 60)))
        let d = Document(state: st, name: "frames")
        app.add(d)
        defer { app.close(d) }
        let saved = ToolsSettings.shared.frameFit
        defer { ToolsSettings.shared.frameFit = saved }
        ToolsSettings.shared.frameFit = .fill
        let f1 = FrameSupport.createFrame(d, rect: CGRect(x: 40, y: 60, width: 180, height: 200), ellipse: true, wrapActive: false)
        let f2 = FrameSupport.createFrame(d, rect: CGRect(x: 260, y: 60, width: 190, height: 140), ellipse: false, wrapActive: false)
        SelfTest.save(d.state, "tools_frames_empty", out)
        // place an image into the ellipse frame
        d.selectLayer(f1)
        AppActions.placeBuffer(checker(300, 200, cell: 25), name: "Photo")
        let g1 = d.state.layer(f1)!
        check(g1.children.count == 1 && g1.children[0].isSmartObject, "placing with a frame selected puts the image into the frame")
        if let q = g1.children.first?.smart?.quad {
            let b = q.bounds
            check(abs(b.height - 200) < 0.5 && b.width >= 180, "placed image fills the frame (\(Int(b.width))×\(Int(b.height)))")
        }
        // replace: a second placement replaces the content
        d.selectLayer(g1.children[0].id)
        AppActions.placeBuffer(checker(200, 200, cell: 40, RGBA(hex: "8E24AA")!, .white), name: "Photo 2")
        check(d.state.layer(f1)!.children.count == 1 && d.state.layer(f1)!.children[0].name == "Photo 2", "placing again replaces the frame content")
        d.selectLayer(f2)
        ToolsSettings.shared.frameFit = .fit
        AppActions.placeBuffer(checker(300, 100, cell: 20, RGBA(hex: "1E88E5")!, RGBA(hex: "FFEB3B")!), name: "Wide")
        SelfTest.save(d.state, "tools_frames_filled", out)
        let res = composite(d.state)
        // outside the ellipse (corner of its bounding box) shows the background, inside shows the image
        let corner = res.pixel(44, 256), inside = res.pixel(130, 160)
        let bgc = composite(SelfTest.baseState(480, 320)).pixel(44, 256)
        check(abs(Int(corner.0) - Int(bgc.0)) < 6 && abs(Int(corner.2) - Int(bgc.2)) < 6, "frame clips content to the ellipse")
        check(inside != bgc, "frame shows the content inside")
        // persistence of the frame registry
        if let data = try? JSONEncoder().encode(d.state), let back = try? JSONDecoder().decode(DocumentState.self, from: data) {
            check(back.toolData.frames.count == 2 && back.toolData.frames[0].ellipse, "frames persist in the document")
        }
    }

    // MARK: Measurements

    static func measurements(_ out: URL) {
        let (d, _) = whiteDoc(300, 300, name: "measure")
        let log = MeasurementLog.shared
        let savedRecords = log.records
        defer { log.records = savedRecords }
        log.records = []
        let circle = SelectionOps.mask(fromPath: CGPath(ellipseIn: CGRect(x: 50, y: 50, width: 100, height: 100), transform: nil), width: 300, height: 300)
        d.setSelection(circle, commitName: "Select")
        let s = MeasurementActions.selectionStats(circle, composite: nil)
        check(abs(s.area - .pi * 2500) / (.pi * 2500) < 0.02, "selection area \(Int(s.area)) ≈ 7854")
        check(s.width == 100 && s.height == 100, "selection width/height")
        check(s.circularity > 0.7 && s.circularity <= 1, "selection circularity \(String(format: "%.3f", s.circularity))")
        d.state.toolData.measurementScale = MeasurementScale(pixels: 100, length: 2.54, units: "cm")
        let recs = MeasurementActions.record(d)
        check(recs.count == 1 && abs((recs[0].area ?? 0) - s.area * 0.0254 * 0.0254) < 0.01, "recorded area in scaled units (\(recs.first?.area ?? 0) cm²)")
        d.setSelection(nil)
        AppModel.shared.tool = .count
        ToolsSettings.shared.rulerLines[d.id] = (CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 10))
        d.state.toolData.countGroups = [CountGroup(name: "G", color: .black)]
        d.state.toolData.countGroups[0].points = [CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 5), CGPoint(x: 9, y: 9)]
        let r2 = MeasurementActions.record(d)
        check(r2.contains { $0.source == "Ruler Tool" && abs(($0.length ?? 0) - 2.54) < 1e-6 }, "ruler length recorded with the scale")
        check(r2.contains { $0.source == "Count Tool" && $0.count == 3 }, "count recorded")
        let csv = log.csv()
        try? csv.write(to: out.appendingPathComponent("tools_measurements.csv"), atomically: true, encoding: .utf8)
        check(csv.split(separator: "\n").count == log.records.count + 1 && csv.hasPrefix("Label,"), "measurement log CSV")
        ToolsSettings.shared.rulerLines[d.id] = nil
        let m = RulerTool.measure((CGPoint(x: 0, y: 0), CGPoint(x: 100, y: -100)))
        check(abs(m.angle - 45) < 1e-6 && abs(m.length - 141.421) < 0.01, "ruler angle/length")
    }

    static func windowSync() {
        let a = Document(state: DocumentState(width: 1000, height: 800), name: "a")
        let b = Document(state: DocumentState(width: 500, height: 400), name: "b")
        a.zoom = 2; a.viewRotation = 0.3
        let size = CGSize(width: 1200, height: 800)
        // put a's doc point (250, 200) (fraction .25/.25) at the view centre
        let vc = CGPoint(x: 600, y: 400)
        let lin = CGPoint(x: 250 * cos(0.3) * 2 - 200 * sin(0.3) * 2, y: 250 * sin(0.3) * 2 + 200 * cos(0.3) * 2)
        a.viewOffset = vc - lin
        WindowSync.match(from: a, to: [b], viewSize: size, zoom: true, location: true, rotation: true)
        let centre = vc.applying(WindowSync.docToView(b).inverted())
        check(b.zoom == 2 && abs(b.viewRotation - 0.3) < 1e-9, "match zoom / rotation")
        check(abs(centre.x - 125) < 0.01 && abs(centre.y - 100) < 0.01, "match location (relative centre \(centre))")
    }

    static func smartGuides() {
        var st = SelfTest.baseState(600, 400)
        st.layers.append(SelfTest.shapeLayer(CGRect(x: 100, y: 100, width: 100, height: 100), radius: 0))
        let moving = SelfTest.shapeLayer(CGRect(x: 300, y: 250, width: 80, height: 60), radius: 0)
        st.layers.append(moving)
        let d = Document(state: st, name: "guides")
        let sg = SmartGuides.shared
        let wasEnabled = sg.enabled
        sg.enabled = true
        defer { sg.enabled = wasEnabled; sg.clear() }
        let b = Compositor.shared.contentBounds(moving, state: st)!
        // move so the top edge is 3 px below the other shape's top edge (y = 100) → snaps to it
        let delta = sg.adjust(CGPoint(x: -20, y: 100 + 3 - b.minY), moving: b, doc: d, movedIDs: [moving.id], zoom: 1, snap: true)
        check(abs(b.minY + delta.y - 100) < 0.01, "smart guides snap to another layer's edge (Δy \(delta.y))")
        check(!sg.lines.isEmpty, "smart guides produce alignment lines")
        check(sg.gaps.contains { $0.2.hasSuffix("px") }, "smart guides show distances")
        sg.enabled = false
        let d2 = sg.adjust(CGPoint(x: 0, y: 1), moving: b, doc: d, movedIDs: [moving.id], zoom: 1, snap: true)
        check(d2 == CGPoint(x: 0, y: 1) && sg.lines.isEmpty, "smart guides off: no snapping")
    }

    static func artboards(_ out: URL) {
        let d = Document(state: DocumentState(width: 400, height: 300), name: "ab")
        let id = ArtboardTool.create(d, rect: CGRect(x: 0, y: 0, width: 200, height: 150))
        let right = ArtboardTool.addAdjacent(d, to: id, side: .right)
        let right2 = ArtboardTool.addAdjacent(d, to: id, side: .right)
        let below = ArtboardTool.addAdjacent(d, to: id, side: .bottom)
        let rects = [id, right, right2, below].compactMap { $0.flatMap { d.state.layer($0)?.artboard?.rect } }
        check(rects.count == 4 && rects[1] == CGRect(x: 300, y: 0, width: 200, height: 150) && rects[2].minX == 600 && rects[3].minY == 250,
              "artboard + buttons add artboards beside (\(rects.map { "\(Int($0.minX)),\(Int($0.minY))" }))")
        check(d.state.width >= 800 && d.state.height >= 400, "canvas grows to include new artboards (\(d.state.width)×\(d.state.height))")
        ArtboardTool.setRect(d, id, CGRect(x: 0, y: 0, width: 250, height: 150))
        d.commit("Resize")
        check(d.state.layer(id)?.artboard?.rect.width == 250, "artboard resize")
        SelfTest.save(d.state, "tools_artboards", out)
    }

    static func toolbarAndKeys() {
        let cfg = ToolbarConfig.shared
        let saved = cfg.saved
        defer {
            cfg.saved = saved
            if saved == ToolbarConfig.Saved() { UserDefaults.standard.removeObject(forKey: "Lumen.Toolbar") }   // leave no trace
        }
        var s = ToolbarConfig.Saved()
        s.hidden = ["ruler", "note", "zoom"]
        s.order = ["zoom", "brush"]
        cfg.saved = s
        let g = ToolKind.groups
        check(g.first?.first == .brush, "toolbar reorder puts the brush group first")
        check(!g.flatMap { $0 }.contains(.ruler) && !g.contains { $0.contains(.zoom) }, "hidden tools removed from the toolbar")
        check(cfg.hiddenTools.contains(.ruler) && cfg.hiddenTools.contains(.zoom), "hidden tools listed in the extra slot")
        cfg.saved = ToolbarConfig.Saved()
        check(ToolKind.groups == ToolKind.defaultGroups, "restore default toolbar")
        // spring-loaded: a long hold returns to the previous tool, a tap doesn't
        let app = AppModel.shared
        app.tool = .eraser
        SpringLoadedTools.release(heldFor: 0.6, previous: .brush)
        check(app.tool == .brush, "spring-loaded key returns to the previous tool after a hold")
        app.tool = .eraser
        SpringLoadedTools.release(heldFor: 0.1, previous: .brush)
        check(app.tool == .eraser, "a quick tap switches tools permanently")
        check(SpringLoadedTools.selectLooseTool("K") && app.tool == .frame, "K selects the Frame tool")
        let extra = ToolKind.allCases.filter { ExtraToolInfo.displayName($0) != $0.rawValue }
        check(extra.count == 20 && extra.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil && ToolKind.defaultGroups.joined().contains($0) },
              "20 new tools with valid SF Symbols, all in toolbar groups")
    }

    static func persistence() {
        var st = DocumentState(width: 100, height: 80)
        st.toolData.slices = [DocSlice(rect: CGRect(x: 1, y: 2, width: 30, height: 40), name: "a")]
        st.toolData.notes = [DocNote(position: CGPoint(x: 5, y: 6), author: "me", color: .black)]
        st.toolData.colorSamplers = [CGPoint(x: 3, y: 4)]
        st.toolData.measurementScale = MeasurementScale(pixels: 10, length: 1, units: "mm")
        let data = try? JSONEncoder().encode(st)
        let back = data.flatMap { try? JSONDecoder().decode(DocumentState.self, from: $0) }
        check(back?.toolData.slices.first?.name == "a" && back?.toolData.notes.first?.author == "me" && back?.toolData.colorSamplers.count == 1
              && back?.toolData.measurementScale.units == "mm", "tool data round-trips through DocumentState coding")
        // old documents without toolData, and partial / malformed toolData
        let plain = try? JSONEncoder().encode(DocumentState(width: 10, height: 10))
        check(plain.flatMap { try? JSONDecoder().decode(DocumentState.self, from: $0) }?.toolData.isEmpty == true, "documents without tool data decode")
        let json = #"{"width":10,"height":10,"toolData":{"slices":[{"rect":[[1,1],[2,2]]}],"notes":"garbage","countGroups":[{"name":"X"}]}}"#
        let partial = try? JSONDecoder().decode(DocumentState.self, from: Data(json.utf8))
        check(partial?.toolData.slices.count == 1 && partial?.toolData.notes.isEmpty == true && partial?.toolData.countGroups.first?.name == "X",
              "tolerant decoding of partial tool data")
    }

    static func taskBar() {
        let (d, id) = whiteDoc(200, 100, name: "tb")
        d.selectLayer(id)
        check(TaskBarContext.of(d) == .pixelLayer, "task bar: pixel layer context")
        d.setSelection(SelectionOps.rectMask(CGRect(x: 10, y: 10, width: 50, height: 50), width: 200, height: 100))
        check(TaskBarContext.of(d) == .selection && TaskBarContext.selection.actions.contains("Generative Fill…"), "task bar: selection context")
        var got = false
        let obs = NotificationCenter.default.addObserver(forName: Notification.Name("LumenGenerativeFill"), object: nil, queue: nil) { _ in got = true }
        TaskBarContext.perform("Generative Fill…")
        NotificationCenter.default.removeObserver(obs)
        check(got, "Generative Fill posts LumenGenerativeFill")
    }

    // MARK: UI snapshots (LUMEN_SELFTEST_UI=1)

    static func snapView<V: View>(_ v: V, _ name: String, _ size: CGSize, _ out: URL) {
        let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height).background(Theme.panelBG).environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
    }

    /// Renders the canvas overlay (slices, notes, count, samplers, frames, symmetry, tool overlay) over the composite.
    static func snapOverlay(_ c: CanvasView, _ name: String, _ out: URL) {
        guard let d = c.document else { return }
        let size = c.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let g = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = g
        let ctx = g.cgContext
        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)   // flipped like the overlay view
        ctx.setFillColor(NSColor(white: 0.16, alpha: 1).cgColor); ctx.fill(CGRect(origin: .zero, size: size))
        if let cg = RenderEngine.cgImage(Compositor.shared.composite(d), rect: CanvasSpace(width: d.state.width, height: d.state.height).ciCanvas) {
            ctx.saveGState()
            let r = c.docToView(d.state.canvasCGRect)
            ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: CGRect(origin: .zero, size: r.size))
            ctx.restoreGState()
        }
        let flippedCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current = flippedCtx
        c.overlay.frame = CGRect(origin: .zero, size: size)
        c.overlay.draw(CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
    }

    static func uiSnapshots(_ out: URL) {
        let app = AppModel.shared
        var st = SelfTest.baseState(600, 380)
        st.layers.append(SelfTest.shapeLayer(CGRect(x: 60, y: 60, width: 140, height: 100)))
        st.toolData.slices = [DocSlice(rect: CGRect(x: 60, y: 60, width: 140, height: 100)), DocSlice(rect: CGRect(x: 330, y: 200, width: 200, height: 120), name: "hero")]
        st.toolData.notes = [DocNote(position: CGPoint(x: 250, y: 40), author: "Kris", color: RGBA(r: 1, g: 0.85, b: 0.25, a: 1))]
        st.toolData.colorSamplers = [CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 300)]
        var cg = CountGroup(name: "Count Group 1", color: RGBA(hex: "E53935")!)
        cg.points = [CGPoint(x: 300, y: 120), CGPoint(x: 340, y: 150), CGPoint(x: 380, y: 110)]
        st.toolData.countGroups = [cg]
        let d = Document(state: st, name: "ui")
        app.add(d)
        defer { app.close(d) }
        let c = CanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        c.document = d
        d.zoom = 1.2
        d.viewOffset = CGPoint(x: 40, y: 30)
        _ = FrameSupport.createFrame(d, rect: CGRect(x: 420, y: 40, width: 140, height: 110), ellipse: true, wrapActive: false)
        ToolsSettings.shared.rulerLines[d.id] = (CGPoint(x: 40, y: 340), CGPoint(x: 280, y: 300))
        let prevTool = app.tool
        defer { app.tool = prevTool; ToolsSettings.shared.symmetry = SymmetrySettings(); ToolsSettings.shared.rulerLines[d.id] = nil }
        app.tool = .slice
        snapOverlay(c, "ui_tools_overlay_slices", out)
        app.tool = .ruler
        snapOverlay(c, "ui_tools_overlay_ruler", out)
        app.tool = .brush
        ToolsSettings.shared.symmetry = SymmetrySettings(enabled: true, type: .mandala, segments: 6)
        snapOverlay(c, "ui_tools_overlay_symmetry", out)
        ToolsSettings.shared.symmetry = SymmetrySettings()
        // artboard tool overlay
        let abID = ArtboardTool.create(d, rect: CGRect(x: 20, y: 20, width: 200, height: 150))
        d.selectLayer(abID)
        app.tool = .artboard
        c.fitOnScreen()
        snapOverlay(c, "ui_tools_overlay_artboard", out)
        // perspective crop overlay
        app.tool = .perspectiveCrop
        if let t = c.tool(for: .perspectiveCrop) as? PerspectiveCropTool {
            let p0 = c.docToView(CGPoint(x: 100, y: 80)), p1 = c.docToView(CGPoint(x: 500, y: 330))
            t.mouseDown(event(p0).withDoc(c.viewToDoc(p0)))
            t.mouseDragged(event(p1).withDoc(c.viewToDoc(p1)))
            t.mouseUp(event(p1).withDoc(c.viewToDoc(p1)))
            snapOverlay(c, "ui_tools_overlay_perspective", out)
            t.cancel()
        }
        // smart guides while moving
        SmartGuides.shared.enabled = true
        let mv = d.state.layers.first { $0.isShape }!
        let b = Compositor.shared.contentBounds(mv, state: d.state)!
        _ = SmartGuides.shared.adjust(CGPoint(x: 280 - b.minX, y: 22 - b.minY), moving: b, doc: d, movedIDs: [mv.id], zoom: 1, snap: true)
        app.tool = .move
        snapOverlay(c, "ui_tools_overlay_smartguides", out)
        SmartGuides.shared.clear()
        // SwiftUI pieces
        for (k, name) in [(ToolKind.patternStamp, "pattern"), (.backgroundEraser, "bgeraser"), (.artHistoryBrush, "arthistory"), (.count, "count"),
                          (.slice, "slice"), (.frame, "frame"), (.ruler, "ruler"), (.artboard, "artboard"), (.line, "line"), (.crop, "crop"), (.brush, "brush")] {
            app.tool = k
            snapView(OptionsBar(), "ui_tools_options_\(name)", CGSize(width: 1500, height: 36), out)
        }
        snapView(ToolsPalette(), "ui_tools_palette", CGSize(width: 46, height: 900), out)
        SnapshotStore.shared.ensureInitial(d)
        SnapshotStore.shared.newSnapshot(d, name: "Before artboard")
        snapView(HistoryPanel(), "ui_tools_history", CGSize(width: 280, height: 320), out)
        snapView(InfoPanel(), "ui_tools_info", CGSize(width: 280, height: 320), out)
        _ = MeasurementActions.record(d)
        snapView(MeasurementLogPanel(), "ui_tools_measurement_log", CGSize(width: 520, height: 200), out)
        snapView(DraggableCard { ToolbarCustomizeDialog() }, "ui_tools_toolbar_dialog", CGSize(width: 480, height: 520), out)
        d.setSelection(SelectionOps.rectMask(CGRect(x: 100, y: 100, width: 200, height: 120), width: 600, height: 380))
        snapView(ContextualTaskBar(doc: d, context: .selection), "ui_tools_taskbar_selection", CGSize(width: 820, height: 44), out)
        snapView(ContextualTaskBar(doc: d, context: .pixelLayer), "ui_tools_taskbar_layer", CGSize(width: 420, height: 44), out)
        ToolsSettings.shared.selectedNoteID = d.state.toolData.notes.first?.id
        snapView(NotesPanel(), "ui_tools_notes", CGSize(width: 280, height: 260), out)
        print("wrote ui_tools_* snapshots")
    }
}

extension ToolEvent {
    func withDoc(_ p: CGPoint) -> ToolEvent { var e = self; e.doc = p; return e }
}
