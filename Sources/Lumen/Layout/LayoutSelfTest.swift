import AppKit
import SwiftUI
import CoreImage
import ImageCratCore

/// Headless tests of the layout module. Run with `LUMEN_SELFTEST_ONLY=layout Lumen --selftest <dir>`.
enum LayoutSelfTest {
    static var failures = 0

    static func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") layout: \(name)\(detail.isEmpty ? "" : " — " + detail)")
    }

    static func run(_ out: URL) {
        failures = 0
        LayoutPrefs.persist = false
        // earlier modules may leave a dialog open or a tool armed; the canvas interactions below need a clean slate
        let savedZone = SafeZones.kind, savedTool = AppModel.shared.tool, savedDialog = AppModel.shared.dialog
        AppModel.shared.dialog = nil
        defer { SafeZones.kind = savedZone; AppModel.shared.tool = savedTool; AppModel.shared.dialog = savedDialog; LayoutPrefs.persist = true }
        func timed(_ name: String, _ f: () -> Void) {
            let t = CFAbsoluteTimeGetCurrent(); f()
            print(String(format: "layout: [%@] %.1f s", name, CFAbsoluteTimeGetCurrent() - t))
        }
        registration()
        timed("repeater") { repeater(out) }
        timed("tidy") { tidy(out) }
        timed("spacing") { spacing(out) }
        timed("packing") { packing(out) }
        timed("collage") { collage(out) }
        timed("select similar") { selectSimilar() }
        timed("replace") { replace(out) }
        timed("smart resize") { smartResize(out) }
        timed("constraints") { constraints(out) }
        if ProcessInfo.processInfo.environment["LUMEN_SELFTEST_UI"] != nil { ui(out) }
        print(failures == 0 ? "layout: all checks passed" : "layout: \(failures) FAILED")
    }

    // MARK: Helpers

    static func withDoc(_ st: DocumentState, _ body: (Document) -> Void) {
        let app = AppModel.shared
        let d = Document(state: st, name: "layout")
        app.documents.append(d); app.activeDocumentID = d.id
        body(d)
        app.documents.removeAll { $0.id == d.id }
    }

    static func rect(_ r: CGRect, _ hex: String, name: String = "Rect", radius: Double = 8) -> Layer {
        Layer(name: name, content: .shape(ShapeContent(geometry: .rectangle(r, cornerRadius: radius), fill: .color(RGBA(hex: hex)!))))
    }

    static func ellipse(_ r: CGRect, _ hex: String, name: String = "Ellipse") -> Layer {
        Layer(name: name, content: .shape(ShapeContent(geometry: .ellipse(r), fill: .color(RGBA(hex: hex)!))))
    }

    static func text(_ s: String, at p: CGPoint, size: Double, hex: String = "111111", font: String = "Helvetica-Bold", name: String? = nil) -> Layer {
        var t = TextContent()
        t.text = s; t.fontName = font; t.fontSize = size; t.position = p; t.color = RGBA(hex: hex)!
        return Layer(name: name ?? s, content: .text(t))
    }

    /// A striped "photo" so crops are visible.
    static func photo(_ w: Int, _ h: Int, _ hex: String, name: String, at o: IPoint = .zero) -> Layer {
        let b = PixelBuffer(width: w, height: h)
        let c = b.context
        c.setFillColor(RGBA(hex: hex)!.cgColor); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setStrokeColor(RGBA(r: 1, g: 1, b: 1, a: 0.35).cgColor); c.setLineWidth(6)
        for k in stride(from: -h, to: w, by: 28) { c.move(to: CGPoint(x: k, y: 0)); c.addLine(to: CGPoint(x: k + h, y: h)) }
        c.strokePath()
        c.setStrokeColor(RGBA(r: 0, g: 0, b: 0, a: 0.5).cgColor); c.setLineWidth(4)
        c.stroke(CGRect(x: 2, y: 2, width: w - 4, height: h - 4))
        c.setFillColor(RGBA.white.cgColor); c.fillEllipse(in: CGRect(x: w / 2 - 12, y: h / 2 - 12, width: 24, height: 24))
        b.markDirty()
        return Layer.raster(name: name, buffer: b, origin: o)
    }

    static func bounds(_ id: UUID, _ st: DocumentState) -> CGRect { LayoutGeom.bounds(id, st) ?? .null }

    static func flat(_ st: DocumentState) -> PixelBuffer? { Compositor.shared.flatten(st, background: .white).map { PixelBuffer(cgImage: $0) } }

    static func rgb(_ b: PixelBuffer?, _ x: CGFloat, _ y: CGFloat) -> (r: Int, g: Int, b: Int) {
        guard let b else { return (-1, -1, -1) }
        let p = b.pixel(Int(x), Int(y))
        return (Int(p.0), Int(p.1), Int(p.2))
    }

    /// Same layer tree (ids, names, bounds) and identical pixels.
    static func same(_ a: DocumentState, _ b: DocumentState) -> Bool {
        let la = a.allLayers, lb = b.allLayers
        guard a.width == b.width, a.height == b.height, la.count == lb.count else { return false }
        for (x, y) in zip(la, lb) {
            if x.id != y.id || x.name != y.name { return false }
            let bx = Compositor.shared.contentBounds(x, state: a), by = Compositor.shared.contentBounds(y, state: b)
            if bx != by { return false }
        }
        return RegressionTests.diff(a, b) < 0.0001
    }

    /// Undo must bring back exactly the state before the command; redo returns to the result.
    static func undoRestores(_ d: Document, _ before: DocumentState, _ what: String) {
        let after = d.state
        d.undo()
        check(same(before, d.state), "undo restores the document after \(what)")
        d.redo()
        check(same(after, d.state), "redo re-applies \(what)")
    }

    static func save(_ st: DocumentState, _ name: String, _ out: URL, scale: Double = 1) {
        let url = out.appendingPathComponent(name + ".png")
        do { try DocumentIO.export(st, to: url, format: .png, quality: 1, scale: scale, background: .white) } catch { check(false, "export \(name)", "\(error)") }
    }

    static func gapsH(_ r: [CGRect]) -> [CGFloat] {
        let s = r.sorted { $0.minX < $1.minX }
        return (1..<s.count).map { s[$0].minX - s[$0 - 1].maxX }
    }
    static func gapsV(_ r: [CGRect]) -> [CGFloat] {
        let s = r.sorted { $0.minY < $1.minY }
        return (1..<s.count).map { s[$0].minY - s[$0 - 1].maxY }
    }

    // MARK: Registration

    static func registration() {
        let arrange = MenuRegistry.items(for: "Layer/Arrange").map(\.title)
        check(["Tidy Up", "Distribute with Spacing…", "Swap Positions", "Width", "Height", "Width and Height"].allSatisfy(arrange.contains), "Layer ▸ Arrange has the tidy / spacing / match-size items", "\(arrange)")
        let layer = MenuRegistry.items(for: "Layer").map(\.title)
        check(["Repeat…", "Expand Repeater", "Release Repeater", "Pack into Shape…", "Auto Collage…"].allSatisfy(layer.contains), "Layer menu has Repeater and Pack & Fill")
        check(MenuRegistry.items(for: "Select").filter { $0.submenu == "Similar Layers" }.count == SimilarCriterion.allCases.count, "Select ▸ Similar Layers has all criteria")
        check(MenuRegistry.items(for: "Edit").contains { $0.title == "Find and Replace in Document…" }, "Edit ▸ Find and Replace in Document…")
        check(MenuRegistry.items(for: "File").contains { $0.title == "Smart Resize…" }, "File ▸ Smart Resize…")
        check(MenuRegistry.items(for: "View").filter { $0.submenu == "Safe Zones" }.count == SafeZoneKind.allCases.count, "View ▸ Safe Zones")
        for id in ["layout.repeater", "layout.spacing", "layout.pack", "layout.collage", "layout.findReplace", "layout.smartResize"] {
            check(DialogRegistry.builders[id] != nil, "dialog \(id) registered")
        }
    }

    // MARK: 1. Repeater

    static func repeater(_ out: URL) {
        var st = SelfTest.baseState(600, 400)
        let tile = rect(CGRect(x: 40, y: 40, width: 40, height: 40), "E94F37", name: "Tile")
        let dot = ellipse(CGRect(x: 52, y: 52, width: 16, height: 16), "FFFFFF", name: "Dot")
        st.layers += [tile, dot]
        let src = CGRect(x: 40, y: 40, width: 40, height: 40)

        withDoc(st) { d in
            let before = d.state
            d.selectedLayerIDs = [tile.id, dot.id]; d.activeLayerID = dot.id
            var s = RepeaterSettings()
            s.mode = .grid; s.columns = 4; s.rows = 3; s.gapX = 20; s.gapY = 20
            guard let gid = RepeaterActions.make(d, ids: d.orderedSelection, settings: s) else { check(false, "repeater created"); return }
            d.commit("Repeat")
            let g = d.state.layer(gid)!
            check(RepeaterActions.settings(g) == s && g.children.map(\.id) == [tile.id, dot.id] && g.blendMode == .normal, "Repeat wraps the selection in a repeater group")
            check(d.state.layer(tile.id)?.isShape == true, "the source stays a normal editable layer inside the repeater")
            let gb = bounds(gid, d.state)
            check(gb == CGRect(x: 40, y: 40, width: 220, height: 160), "grid 4×3: group bounds cover every instance", "\(gb)")
            var px = flat(d.state)
            let last = rgb(px, 224, 180), gutter = rgb(px, 90, 60), centre = rgb(px, 240, 180)
            check(last.r > 200 && last.g < 120, "grid: the last instance is rendered", "\(last)")
            check(centre.r > 240 && centre.g > 240, "grid: instances contain every source layer (white dot)", "\(centre)")
            check(gutter.b > 200 && gutter.r < 235, "grid: gaps stay empty", "\(gutter)")
            save(d.state, "layout_repeater_grid", out)
            undoRestores(d, before, "Repeat")

            // editing the source updates every instance
            d.updateLayer(tile.id) { $0.shape?.fill = .color(RGBA(hex: "2E86DE")!) }
            d.commit("Edit Shape")
            px = flat(d.state)
            let edited = rgb(px, 224, 180)
            check(edited.b > 180 && edited.r < 100, "editing the source recolours every instance", "\(edited)")
            d.updateLayer(gid) { $0.translate(dx: 10, dy: 5) }
            check(bounds(gid, d.state) == CGRect(x: 50, y: 45, width: 220, height: 160), "moving the repeater moves all instances")
            d.revertUncommitted()

            // brick offset + pass-through must not switch the repeater off
            var brick = s; brick.stagger = 50
            RepeaterActions.update(&d.state, gid, brick)
            d.updateLayer(gid) { $0.blendMode = .passThrough }
            check(bounds(gid, d.state).width == 250, "brick offset shifts every other row by half a pitch", "\(bounds(gid, d.state))")
            let bp = rgb(flat(d.state), 40 + 30 + 60 + 4, 120)
            check(bp.b > 180 && bp.r < 100, "a pass-through repeater still renders its instances", "\(bp)")
            save(d.state, "layout_repeater_brick", out)
            d.revertUncommitted()

            // save / load round trip
            let url = out.appendingPathComponent("layout_repeater.imagecrat")
            do {
                try DocumentIO.saveNative(d, to: url)
                let d2 = try DocumentIO.load(url: url)
                let g2 = d2.state.layer(gid)
                check(RepeaterActions.settings(g2) == s, ".imagecrat round trip keeps the repeater settings")
                check(RegressionTests.diff(d.state, d2.state) < 0.01, ".imagecrat round trip renders identically", String(format: "%.3f", RegressionTests.diff(d.state, d2.state)))
            } catch { check(false, "save / load repeater", "\(error)") }
            // export
            let png = out.appendingPathComponent("layout_repeater_export.png")
            try? DocumentIO.export(d.state, to: png, format: .png, quality: 1, scale: 1)
            if let (cg, _) = DocumentIO.loadImage(url: png) {
                let p = PixelBuffer(cgImage: cg).pixel(224, 180)
                check(p.2 > 180 && p.0 < 100, "exported PNG contains the instances")
            } else { check(false, "exported PNG readable") }
            // PSD knows no repeaters: the instances are written as real layers
            let psd = out.appendingPathComponent("layout_repeater.psd")
            do {
                try DocumentIO.export(d.state, to: psd, format: .psd, quality: 1, scale: 1)
                let back = try DocumentIO.load(url: psd)
                let p = rgb(flat(back.state), 224, 180)
                check(p.b > 180 && p.r < 100 && back.state.allLayers.count >= 24, "PSD export writes the instances as layers", "\(back.state.allLayers.count) layers, \(p)")
            } catch { check(false, "PSD export of a repeater", "\(error)") }

            // expand → real layers, same picture
            let live = d.state
            RepeaterActions.expand(d, gid)
            let eg = d.state.layer(gid)!
            check(RepeaterActions.settings(eg) == nil && eg.children.count == 2 + 11 && d.state.layer(gid)!.allIDs.count == 1 + 2 + 11 * 3, "Expand Repeater makes 12 real instances",
                  "\(eg.children.count) children")
            check(RegressionTests.diff(live, d.state) < 0.3, "expanded layers look like the live repeater", String(format: "diff %.3f", RegressionTests.diff(live, d.state)))
            check(d.history.last?.name == "Expand Repeater", "Expand is one history step")
            undoRestores(d, live, "Expand Repeater")
            d.undo()
            // release → the source layers come back
            RepeaterActions.release(d, gid)
            check(d.state.layer(gid) == nil && d.state.layers.map(\.id).suffix(2) == [tile.id, dot.id], "Release Repeater restores the source layers")
            check(d.state.layers.map(\.id) == before.layers.map(\.id) && bounds(tile.id, d.state) == src, "after Release the layer stack is what it was before Repeat")
            undoRestores(d, live, "Release Repeater")
        }

        // geometry of the other modes
        let c = CGPoint(x: src.midX, y: src.midY)
        var r = RepeaterSettings()
        r.mode = .radial; r.count = 8; r.radius = 120
        var inst = RepeaterLayout.instances(r, source: src)
        let o = CGPoint(x: c.x, y: c.y + 120)
        check(inst.count == 8 && inst[0].isPlain && inst.allSatisfy { abs(c.applying($0.transform).distance(to: o) - 120) < 0.01 }, "radial: 8 instances on a circle of the radius")
        let a2 = c.applying(inst[2].transform)
        check(abs(a2.x - (o.x + 120)) < 0.01 && abs(a2.y - o.y) < 0.01, "radial: instances are spaced evenly (third one a quarter turn on)", "\(a2)")
        check(abs(inst[2].transform.rotationAngle - .pi / 2) < 0.001, "radial: instances rotate with the circle")
        r.arc = 180
        inst = RepeaterLayout.instances(r, source: src)
        check(abs(c.applying(inst[7].transform).y - (o.y + 120)) < 0.01, "radial: an arc of 180° ends opposite the source")

        var p = RepeaterSettings()
        p.mode = .path; p.shape = ArrangeSettings.Shape.star.rawValue; p.count = 10; p.sides = 5; p.shapeWidth = 300; p.shapeHeight = 300
        inst = RepeaterLayout.instances(p, source: src)
        let guide = RepeaterLayout.guide(p, source: src)
        let outline = guide.map { ArrangeOnShape.polylines($0) }?.first?.pts ?? []
        func distToOutline(_ q: CGPoint) -> CGFloat { (1..<max(1, outline.count)).map { ToolGeometry.segmentDistance(q, outline[$0 - 1], outline[$0]) }.min() ?? 999 }
        check(inst.count == 10 && inst[0].isPlain && inst.allSatisfy { distToOutline(c.applying($0.transform)) < 1 }, "along shape: every instance sits on the star outline")

        var m = RepeaterSettings()
        m.mode = .mirror; m.mirror = .horizontal; m.mirrorGap = 10
        inst = RepeaterLayout.instances(m, source: src)
        check(inst.count == 2 && src.applying(inst[1].transform) == CGRect(x: 100, y: 40, width: 40, height: 40), "mirror: 2-way copy is reflected across the axis", "\(src.applying(inst[1].transform))")
        check(CGPoint(x: 40, y: 40).applying(inst[1].transform) == CGPoint(x: 140, y: 40), "mirror: the copy is flipped, not just moved")
        m.mirror = .four
        inst = RepeaterLayout.instances(m, source: src)
        check(inst.count == 4 && src.applying(inst[3].transform) == CGRect(x: 100, y: 100, width: 40, height: 40), "mirror: 4-way")
        m.mirror = .kaleidoscope; m.segments = 6; m.mirrorGap = 60
        inst = RepeaterLayout.instances(m, source: src)
        let ko = CGPoint(x: c.x, y: src.maxY + 60)
        let angles = inst.map { (c.applying($0.transform) - ko).angle }.sorted()
        let steps = (1..<angles.count).map { angles[$0] - angles[$0 - 1] }
        check(inst.count == 12 && inst.allSatisfy { abs(c.applying($0.transform).distance(to: ko) - c.distance(to: ko)) < 0.01 } && steps.allSatisfy { abs($0 - .pi / 6) < 0.001 },
              "kaleidoscope: 12 alternating copies evenly around the centre")
        check(inst.filter { $0.transform.a * $0.transform.d - $0.transform.b * $0.transform.c < 0 }.count == 6, "kaleidoscope: half of the copies are mirrored")

        var sc = RepeaterSettings()
        sc.mode = .scatter; sc.count = 25; sc.region = .circle; sc.regionWidth = 360; sc.regionHeight = 360; sc.noOverlap = true; sc.seed = 7
        let big = CGRect(x: 280, y: 180, width: 40, height: 40)
        let bc = CGPoint(x: 300, y: 200)
        inst = RepeaterLayout.instances(sc, source: big)
        let pts = inst.map { bc.applying($0.transform) }
        var overlap = false
        for i in 0..<pts.count { for j in (i + 1)..<pts.count where abs(pts[i].x - pts[j].x) < 40 && abs(pts[i].y - pts[j].y) < 40 { overlap = true } }
        check(inst.count == 25 && !overlap, "scatter: 25 instances without overlaps", "\(inst.count)")
        check(pts.allSatisfy { $0.distance(to: bc) <= 180.01 }, "scatter: every instance is inside the region")
        check(RepeaterLayout.instances(sc, source: big) == inst, "scatter: the same seed gives the same layout")
        var sc2 = sc; sc2.seed = 8
        check(RepeaterLayout.instances(sc2, source: big) != inst, "scatter: another seed gives another layout")
        var sc3 = sc; sc3.noOverlap = false; sc3.minDistance = 70
        let p3 = RepeaterLayout.instances(sc3, source: big).map { bc.applying($0.transform) }
        var tooClose = false
        for i in 0..<p3.count { for j in (i + 1)..<p3.count where p3[i].distance(to: p3[j]) < 70 { tooClose = true } }
        check(p3.count > 8 && !tooClose, "scatter: minimum distance is respected", "\(p3.count) placed")
        var cap = RepeaterSettings(); cap.columns = 40; cap.rows = 40
        check(RepeaterLayout.instances(cap, source: src).count == RepeaterSettings.maxInstances, "instance count is capped")

        // progressive transform + random variation
        var pr = RepeaterSettings()
        pr.mode = .grid; pr.columns = 6; pr.rows = 1; pr.gapX = 30; pr.stepRotation = 12; pr.stepScale = 92; pr.stepOpacity = 12; pr.stepY = 6
        inst = RepeaterLayout.instances(pr, source: src)
        check(inst[0].isPlain && abs(inst[3].opacity - 0.64) < 1e-9 && abs(Double(inst[3].transform.scaleFactor) - pow(0.92, 3)) < 1e-6 && abs(Double(inst[3].transform.rotationAngle) - 36 * .pi / 180) < 1e-6,
              "progressive: opacity, scale and rotation step per instance")
        check(abs(c.applying(inst[3].transform).y - (c.y + 18)) < 0.01, "progressive: offset accumulates")
        pr.varyHue = 120; pr.varyScale = 30; pr.varyRotation = 40; pr.varyBrightness = 30
        let vi = RepeaterLayout.instances(pr, source: src)
        check(vi[0].isPlain && Set(vi.dropFirst().map { Int($0.hue) }).count >= 4 && vi.dropFirst().allSatisfy { abs($0.hue) <= 120 && abs($0.brightness) <= 30 },
              "variation: hue / brightness differ per instance within the range, the source is untouched")

        // renders of each mode (to look at) + expand with tint matches
        func render(_ s: RepeaterSettings, _ name: String, at origin: CGPoint, expandToo: Bool = false) {
            var st2 = SelfTest.baseState(600, 400)
            let t2 = rect(CGRect(origin: origin, size: CGSize(width: 44, height: 44)), "E94F37", name: "Tile")
            let tri = Layer(name: "Mark", content: .shape(ShapeContent(geometry: .polygon(CGRect(x: origin.x + 8, y: origin.y + 6, width: 20, height: 20), sides: 3, starRatio: 1), fill: .color(.white))))
            st2.layers += [t2, tri]
            withDoc(st2) { d in
                d.selectedLayerIDs = [t2.id, tri.id]
                guard let gid = RepeaterActions.make(d, ids: d.orderedSelection, settings: s) else { return }
                d.commit("Repeat")
                save(d.state, name, out)
                let ink = RegressionTests.diff(st2, d.state)
                check(ink > 0.3, "\(name): instances are visible", String(format: "%.2f", ink))
                if expandToo {
                    let live = d.state
                    RepeaterActions.expand(d, gid)
                    check(RegressionTests.diff(live, d.state) < 0.6, "\(name): expanding keeps the look (tints become adjustment layers)", String(format: "diff %.3f", RegressionTests.diff(live, d.state)))
                    save(d.state, name + "_expanded", out)
                    undoRestores(d, live, "Expand (\(name))")
                }
            }
        }
        var rr = RepeaterSettings(); rr.mode = .radial; rr.count = 10; rr.radius = 130
        render(rr, "layout_repeater_radial", at: CGPoint(x: 278, y: 48))
        var ps = p; ps.shapeWidth = 300; ps.shapeHeight = 300; ps.followPath = true; ps.count = 15
        render(ps, "layout_repeater_path", at: CGPoint(x: 278, y: 30))
        var ks = m; ks.mirrorGap = 90
        render(ks, "layout_repeater_kaleidoscope", at: CGPoint(x: 278, y: 40))
        var ss = sc; ss.regionWidth = 340; ss.regionHeight = 340; ss.count = 22; ss.varyRotation = 40; ss.varyScale = 25
        render(ss, "layout_repeater_scatter", at: CGPoint(x: 278, y: 178))
        var vs = pr; vs.gapX = 40
        render(vs, "layout_repeater_variation", at: CGPoint(x: 40, y: 150), expandToo: true)

        // the dialog flow: live preview from a saved base, one history step on OK, nothing left behind on Cancel
        var ds = SelfTest.baseState(600, 400)
        let one = rect(CGRect(x: 60, y: 60, width: 50, height: 50), "E94F37", name: "One")
        ds.layers.append(one)
        ds.selection = SelectionOps.rectMask(CGRect(x: 300, y: 100, width: 250, height: 250), width: 600, height: 400)
        withDoc(ds) { d in
            let before = d.state
            d.selectLayer(one.id)
            let session = LayoutPreviewSession()
            session.begin()
            let start = RepeaterActions.defaults(source: CGRect(x: 60, y: 60, width: 50, height: 50), doc: d)
            check(start.captured != nil, "Repeat… captures the selection outline for Scatter ▸ Selection")
            guard let gid = RepeaterActions.make(d, ids: d.orderedSelection, settings: start) else { check(false, "dialog: repeater made"); return }
            var live = start
            live.mode = .scatter; live.region = .captured; live.count = 12
            RepeaterActions.update(&d.state, gid, live)
            let sb = CGRect(x: 60, y: 60, width: 50, height: 50)
            let inst = RepeaterLayout.instances(live, source: sb)
            // the captured outline is stored relative to the source, so the region is the selection rectangle
            let region = CGRect(x: 300, y: 100, width: 250, height: 250).insetBy(dx: -1, dy: -1)
            check(inst.count > 4 && inst.dropFirst().allSatisfy { region.contains(CGPoint(x: sb.midX, y: sb.midY).applying($0.transform)) }, "scatter inside the captured selection", "\(inst.count) instances")
            check(!d.canUndo, "the live preview adds no history steps")
            session.finish(apply: false, name: "Repeat")
            check(same(before, d.state) && d.selectedLayerIDs == [one.id] && d.activeLayerID == one.id && !d.canUndo, "Cancel restores the document and the selection")
            // OK
            let s2 = LayoutPreviewSession()
            s2.begin()
            let g2 = RepeaterActions.make(d, ids: d.orderedSelection, settings: live)
            s2.finish(apply: true, name: "Repeat")
            check(d.history.count == 2 && d.history.last?.name == "Repeat" && g2 != nil && RepeaterActions.activeRepeater(d) == g2, "OK commits the repeater as one step")
            save(d.state, "layout_repeater_scatter_selection", out)
            undoRestores(d, before, "Repeat (dialog)")
            // editing an existing repeater from one of its source layers
            d.selectLayer(one.id)
            check(RepeaterActions.activeRepeater(d) == g2, "Repeat… on a source layer edits the repeater around it")
        }
        // a repeater transformed as a whole (Free Transform, Flip, Image Size…) keeps its look: spacing scales, flips mirror the pattern
        var ts = SelfTest.baseState(600, 400)
        let tt = rect(CGRect(x: 40, y: 40, width: 40, height: 40), "E94F37", name: "Tile")
        let mark = Layer(name: "Mark", content: .shape(ShapeContent(geometry: .polygon(CGRect(x: 44, y: 44, width: 14, height: 14), sides: 3, starRatio: 1), fill: .color(.white))))
        ts.layers += [tt, mark]
        LayoutConstraintEngine.installCommitHook()
        withDoc(ts) { d in
            d.selectedLayerIDs = [tt.id, mark.id]
            var gs = RepeaterSettings(); gs.columns = 4; gs.rows = 3; gs.gapX = 20; gs.gapY = 20
            guard let gid = RepeaterActions.make(d, ids: d.orderedSelection, settings: gs) else { return }
            d.commit("Repeat")
            let sp = CanvasSpace(width: 600, height: 400)
            let made = d.state
            // what Free Transform does on commit: the group's layers are transformed (here ×1.5 about the top-left of the box)
            let scale = CGAffineTransform(translationX: -40, y: -40).concatenating(CGAffineTransform(scaleX: 1.5, y: 1.5)).concatenating(CGAffineTransform(translationX: 40, y: 40))
            d.updateLayer(gid) { $0 = LayerTransformer.apply(Homography(affine: scale), to: $0, space: sp) }
            d.commit("Free Transform")
            check(bounds(gid, d.state) == CGRect(x: 40, y: 40, width: 330, height: 240) && RepeaterActions.settings(d.state.layer(gid))?.gapX == 30,
                  "scaling a repeater scales its spacing too (the whole pattern grows)", "\(bounds(gid, d.state))")
            undoRestores(d, made, "Free Transform of a repeater")
            d.undo()
            // Flip Horizontal about the middle of the whole pattern
            let picture = flat(d.state)
            let flipT = CGAffineTransform(translationX: -150, y: 0).concatenating(CGAffineTransform(scaleX: -1, y: 1)).concatenating(CGAffineTransform(translationX: 150, y: 0))
            d.updateLayer(gid) { $0 = LayerTransformer.apply(Homography(affine: flipT), to: $0, space: sp) }
            d.commit("Flip Horizontal")
            let flipped = flat(d.state)
            let a = rgb(picture, 51, 51), b = rgb(flipped, 300 - 51, 51), c2 = rgb(picture, 231, 171), d2 = rgb(flipped, 300 - 231, 171)
            check(bounds(gid, d.state) == CGRect(x: 40, y: 40, width: 220, height: 160) && RepeaterActions.settings(d.state.layer(gid))?.flipX == true
                  && a.g > 200 && b.g > 200 && c2.g > 200 && d2.g > 200, "flipping a repeater mirrors the whole pattern in place", "\(bounds(gid, d.state)) \(a) \(b) \(c2) \(d2)")
            save(d.state, "layout_repeater_flipped", out)
            d.undo()
            // resizing only the source (a layer inside is selected) leaves the spacing alone
            d.selectLayer(tt.id)
            d.updateLayer(tt.id) { $0 = LayerTransformer.apply(Homography(affine: scale), to: $0, space: sp) }
            d.commit("Free Transform")
            check(RepeaterActions.settings(d.state.layer(gid))?.gapX == 20, "resizing the source layer itself keeps the gaps")
            d.undo()
            // the module's own commands (here Match Size against a bigger layer) keep the pattern intact as well
            let big = rect(CGRect(x: 300, y: 250, width: 330, height: 100), "2E86AB", name: "Key")
            d.state.layers.append(big)
            d.selectedLayerIDs = [gid, big.id]; d.activeLayerID = big.id
            TidyUp.matchSize(width: true, height: false)
            check(abs(bounds(gid, d.state).width - 330) < 0.5 && abs((RepeaterActions.settings(d.state.layer(gid))?.gapX ?? 0) - 30) < 0.01, "Match Width on a repeater resizes the whole pattern", "\(bounds(gid, d.state))")
        }

        // degenerate sources never crash the compositor
        var es = SelfTest.baseState(200, 120)
        var empty = Layer(name: "Empty Repeater", content: .group(GroupContent(children: [], isExpanded: true, repeater: RepeaterSettings())))
        empty.blendMode = .normal
        var nested = Layer(name: "Nested", content: .group(GroupContent(children: [
            Layer(name: "Inner", content: .group(GroupContent(children: [rect(CGRect(x: 10, y: 10, width: 12, height: 12), "111111")], isExpanded: true, repeater: {
                var s = RepeaterSettings(); s.columns = 2; s.rows = 1; s.gapX = 4; return s }())))], isExpanded: true, repeater: {
                var s = RepeaterSettings(); s.columns = 1; s.rows = 3; s.gapY = 6; return s }())))
        nested.blendMode = .normal
        es.layers += [empty, nested]
        check(Compositor.shared.flatten(es) != nil && Compositor.shared.contentBounds(es.layers[1], state: es) == nil, "an empty repeater renders nothing and has no bounds")
        check(Compositor.shared.contentBounds(es.layers[2], state: es) == CGRect(x: 10, y: 10, width: 28, height: 48), "repeaters can be nested", "\(String(describing: Compositor.shared.contentBounds(es.layers[2], state: es)))")
        let np = rgb(flat(es), 30, 50)
        check(np.r < 60, "nested repeater: the inner copies are repeated by the outer one", "\(np)")

        // tolerant decoding
        let partial = #"{"mode":"Radial","count":5,"futureField":1}"#.data(using: .utf8)!
        let dec = try? JSONDecoder().decode(RepeaterSettings.self, from: partial)
        check(dec?.mode == .radial && dec?.count == 5 && dec?.columns == 3 && dec?.stepScale == 100, "repeater settings decode with missing / unknown keys")
        let oldGroup = #"{"children":[],"isExpanded":true}"#.data(using: .utf8)!
        let og = try? JSONDecoder().decode(GroupContent.self, from: oldGroup)
        check(og != nil && og?.repeater == nil, "groups saved before the repeater existed still decode")
    }

    // MARK: 2. Tidy up & spacing

    static func tidy(_ out: URL) {
        // jittered 3×3 grid
        var st = SelfTest.baseState(600, 400)
        var rng = SeededGenerator(seed: 42)
        var ids: [UUID] = []
        let colors = ["E94F37", "F6AE2D", "2E86AB", "33658A", "86BBD8", "758E4F", "F26419", "6A4C93", "1982C4"]
        for i in 0..<9 {
            let jx = CGFloat(Int.random(in: -12...12, using: &rng)), jy = CGFloat(Int.random(in: -12...12, using: &rng))
            let l = rect(CGRect(x: 120 + CGFloat(i % 3) * 110 + jx, y: 60 + CGFloat(i / 3) * 100 + jy, width: 60, height: 50), colors[i], name: "Cell \(i + 1)")
            st.layers.append(l); ids.append(l.id)
        }
        withDoc(st) { d in
            let before = d.state
            save(d.state, "layout_tidy_before", out)
            d.selectedLayerIDs = Set(ids); d.activeLayerID = ids[0]
            let res = TidyUp.tidied(d.state, ids: ids)
            check(res?.structure == .grid(rows: 3, columns: 3), "Tidy Up detects the 3 × 3 grid", "\(String(describing: res?.structure))")
            TidyUp.run()
            let r = ids.map { bounds($0, d.state) }
            let xs = Set(r.map(\.minX)), ys = Set(r.map(\.minY))
            check(xs.count == 3 && ys.count == 3, "tidy grid: three exact columns and rows", "\(xs.sorted()) \(ys.sorted())")
            let sx = xs.sorted(), sy = ys.sorted()
            check(abs((sx[1] - sx[0]) - (sx[2] - sx[1])) <= 1 && abs((sy[1] - sy[0]) - (sy[2] - sy[1])) <= 1, "tidy grid: equal gaps between columns and between rows")
            let u0 = LayoutGeom.union(ids.map { bounds($0, before) })!, u1 = LayoutGeom.union(r)!
            check(abs(u0.minX - u1.minX) <= 1 && abs(u0.minY - u1.minY) <= 1 && abs(u0.maxX - u1.maxX) <= 2 && abs(u0.maxY - u1.maxY) <= 2, "tidy grid: keeps the overall extent", "\(u0) → \(u1)")
            check(d.history.last?.name == "Tidy Up", "Tidy Up is one history step")
            save(d.state, "layout_tidy_after", out)
            undoRestores(d, before, "Tidy Up")
        }

        // uneven row with different sizes
        var row = SelfTest.baseState(600, 200)
        let specs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(30, 60, 50, 50), (110, 72, 80, 30), (230, 55, 40, 70), (300, 66, 90, 44), (470, 58, 60, 60)]
        var rowIDs: [UUID] = []
        for (i, s) in specs.enumerated() { let l = rect(CGRect(x: s.0, y: s.1, width: s.2, height: s.3), colors[i], name: "R\(i)"); row.layers.append(l); rowIDs.append(l.id) }
        let tr = TidyUp.tidied(row, ids: rowIDs)!
        let rr = rowIDs.map { bounds($0, tr.state) }
        let g = gapsH(rr)
        check(tr.structure == .row && g.allSatisfy { abs($0 - g[0]) < 0.5 }, "tidy row: equal gaps between layers of different widths", "\(g)")
        check(rr.map(\.minX).min() == 30 && abs(rr.map(\.maxX).max()! - 530) <= 2 && Set(rr.map { $0.midY.rounded() }).count == 1, "tidy row: ends stay put, centres line up")
        // column
        var col = SelfTest.baseState(200, 500)
        var colIDs: [UUID] = []
        for (i, y) in [20, 95, 210, 330].enumerated() { let l = rect(CGRect(x: 60 + CGFloat(i * 7), y: CGFloat(y), width: 70, height: 50), colors[i]); col.layers.append(l); colIDs.append(l.id) }
        let tc = TidyUp.tidied(col, ids: colIDs)!
        let gv = gapsV(colIDs.map { bounds($0, tc.state) })
        check(tc.structure == .column && gv.allSatisfy { abs($0 - gv[0]) < 0.5 }, "tidy column: equal gaps", "\(gv)")

        // exact spacing, swap, match size
        let ds = TidyUp.distributed(row, ids: rowIDs, gap: 24, horizontal: true)
        check(gapsH(rowIDs.map { bounds($0, ds) }).allSatisfy { $0 == 24 } && bounds(rowIDs[0], ds).minX == 30, "Distribute with Spacing: exact 24 px gaps, first layer fixed")
        let dv = TidyUp.distributed(col, ids: colIDs, gap: 0, horizontal: false)
        check(gapsV(colIDs.map { bounds($0, dv) }).allSatisfy { $0 == 0 }, "Distribute with Spacing: vertical, gap 0")
        withDoc(row) { d in
            // Distribute with Spacing… through its live-preview session
            let before0 = d.state
            d.selectedLayerIDs = Set(rowIDs); d.activeLayerID = rowIDs[0]
            let session = LayoutPreviewSession()
            session.begin()
            for gap in [60.0, 12.0, 24.0] { session.preview { base, ids, _ in TidyUp.distributed(base, ids: ids, gap: CGFloat(gap), horizontal: true) } }
            check(gapsH(rowIDs.map { bounds($0, d.state) }).allSatisfy { $0 == 24 } && !d.canUndo, "spacing dialog: previews always start from the original positions")
            session.finish(apply: true, name: "Distribute with Spacing")
            check(d.history.last?.name == "Distribute with Spacing" && d.history.count == 2, "spacing dialog: one history step")
            undoRestores(d, before0, "Distribute with Spacing")
            d.undo()
        }
        withDoc(row) { d in
            let before = d.state
            d.selectedLayerIDs = [rowIDs[0], rowIDs[3]]; d.activeLayerID = rowIDs[3]
            let c0 = bounds(rowIDs[0], d.state).center, c3 = bounds(rowIDs[3], d.state).center
            TidyUp.swapPositions()
            check(bounds(rowIDs[0], d.state).center == c3 && bounds(rowIDs[3], d.state).center == c0, "Swap Positions trades the two centres")
            undoRestores(d, before, "Swap Positions")
            d.undo()
            d.selectedLayerIDs = Set(rowIDs); d.activeLayerID = rowIDs[1]      // key layer = 80 × 30
            TidyUp.matchSize(width: true, height: false)
            let w = rowIDs.map { bounds($0, d.state) }
            check(w.allSatisfy { abs($0.width - 80) < 0.01 } && abs(w[2].height - 70) < 0.01 && abs(w[2].midX - 250) <= 0.5, "Match Width: all as wide as the key layer, around their centres", "\(w.map(\.width))")
            undoRestores(d, before, "Match Width")
            d.undo()
            TidyUp.matchSize(width: true, height: true)
            check(rowIDs.map { bounds($0, d.state).size }.allSatisfy { abs($0.width - 80) < 0.01 && abs($0.height - 30) < 0.01 }, "Match Size: width and height")
            save(d.state, "layout_match_size", out)
        }
    }

    static func spacing(_ out: URL) {
        let rects = [CGRect(x: 40, y: 80, width: 60, height: 60), CGRect(x: 130, y: 90, width: 80, height: 40), CGRect(x: 240, y: 70, width: 50, height: 80), CGRect(x: 320, y: 85, width: 70, height: 50)]
        let ids = rects.map { _ in UUID() }
        let items = Array(zip(ids, rects)).map { (id: $0.0, rect: $0.1) }
        let run = SpacingHandles.detect(items.shuffled())
        check(run?.horizontal == true && run?.gap == 30 && run?.ids == ids, "spacing handles: detects an evenly spaced row")
        var uneven = items; uneven[2].rect.origin.x += 9
        check(SpacingHandles.detect(uneven) == nil, "spacing handles: none when the gaps differ")
        check(SpacingHandles.detect(Array(items.prefix(2))) == nil, "spacing handles: need at least three layers")
        let col = (0..<3).map { (id: UUID(), rect: CGRect(x: 50 + CGFloat($0) * 4, y: 20 + CGFloat($0) * 70, width: 80, height: 50)) }
        check(SpacingHandles.detect(col)?.horizontal == false && SpacingHandles.detect(col)?.gap == 20, "spacing handles: detects a column")
        if let run {
            let h = SpacingHandles.handles(run)
            check(h.count == 3 && h[0].x == 115 && h[1].x == 225 && h[2].x == 305, "spacing handles: one handle in the middle of each gap", "\(h)")
            check(SpacingHandles.gap(for: run, handle: 0, delta: 10) == 50 && SpacingHandles.gap(for: run, handle: 1, delta: 15) == 40 && SpacingHandles.gap(for: run, handle: 2, delta: -500) == 0,
                  "spacing handles: the dragged handle follows the cursor ((i + ½) px per px of gap), never below 0")
        }

        var st = SelfTest.baseState(520, 240)
        var lids: [UUID] = []
        for (i, r) in rects.enumerated() { let l = rect(r, ["E94F37", "F6AE2D", "2E86AB", "6A4C93"][i], name: "Item \(i)"); st.layers.append(l); lids.append(l.id) }
        withDoc(st) { d in
            let before = d.state
            let c = CanvasView(frame: CGRect(x: 0, y: 0, width: 520, height: 240))
            c.document = d; d.zoom = 1; d.viewOffset = .zero; d.showRulers = false
            let old = AppActions.canvas
            AppActions.canvas = c
            defer { AppActions.canvas = old }
            AppModel.shared.tool = .move
            d.selectedLayerIDs = Set(lids); d.activeLayerID = lids[0]
            guard let mt = c.tool(for: .move) as? MoveTool, let live = SpacingHandles.shared.current(d) else { check(false, "spacing handles available in the Move tool"); return }
            check(AppModel.shared.dialog == nil && !mt.isBusy, "no dialog or transform in the way", "dialog \(String(describing: AppModel.shared.dialog))")
            ToolsSelfTest.snapOverlay(c, "layout_spacing_handles", out)
            let h0 = SpacingHandles.handles(live)[0]
            func ev(_ p: CGPoint) -> ToolEvent { ToolEvent(doc: p, view: c.docToView(p), pressure: 1, modifiers: [], clickCount: 1, isTablet: false) }
            mt.mouseDown(ev(h0))
            mt.mouseDragged(ev(CGPoint(x: h0.x + 10, y: h0.y + 3)))
            ToolsSelfTest.snapOverlay(c, "layout_spacing_handles_drag", out)
            mt.mouseUp(ev(CGPoint(x: h0.x + 10, y: h0.y + 3)))
            let after = lids.map { bounds($0, d.state) }
            check(gapsH(after).allSatisfy { $0 == 50 } && after[0] == rects[0] && after.map(\.minY) == rects.map(\.minY), "dragging a spacing handle changes every gap at once (30 → 50 px)", "\(gapsH(after))")
            check(d.history.last?.name == "Change Spacing", "spacing drag is one history step", d.history.last?.name ?? "")
            undoRestores(d, before, "Change Spacing")
            d.undo()
            // a click elsewhere still moves layers as usual
            mt.mouseDown(ev(CGPoint(x: 60, y: 100))); mt.mouseDragged(ev(CGPoint(x: 70, y: 100))); mt.mouseUp(ev(CGPoint(x: 70, y: 100)))
            check(d.history.last?.name == "Move", "the Move tool still moves layers when no handle is hit", d.history.last?.name ?? "")
        }
    }

    // MARK: 3. Pack & collage

    static func packing(_ out: URL) {
        var rng = SeededGenerator(seed: 11)
        let sizes = (0..<14).map { _ in CGSize(width: CGFloat(Int.random(in: 30...110, using: &rng)), height: CGFloat(Int.random(in: 30...90, using: &rng))) }
        let circle = CGPath(ellipseIn: CGRect(x: 100, y: 50, width: 400, height: 400), transform: nil)
        let t0 = CFAbsoluteTimeGetCurrent()
        let res = Packing.pack(sizes: sizes, in: circle, mode: .boxes, padding: 6, scaleToFit: true)
        print(String(format: "layout: pack 14 boxes %.0f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        let fr = res.frames.compactMap { $0 }
        func overlaps(_ f: [CGRect], gap: CGFloat) -> Bool {
            for i in 0..<f.count { for j in (i + 1)..<f.count where f[i].insetBy(dx: -gap / 2, dy: -gap / 2).intersects(f[j].insetBy(dx: -gap / 2, dy: -gap / 2)) { return true } }
            return false
        }
        check(fr.count == 14 && !overlaps(fr, gap: 5.9), "pack boxes: all placed, no overlaps, padding kept", "scale \(res.scale)")
        let ctr = CGPoint(x: 300, y: 250)
        check(fr.allSatisfy { $0.corners.allSatisfy { $0.distance(to: ctr) <= 200.01 } }, "pack boxes: every corner is inside the circle")
        let usedArea: CGFloat = fr.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        let used: CGFloat = usedArea / (CGFloat.pi * 200 * 200)
        check(used > 0.4, "pack boxes: scale-to-fit fills the shape", String(format: "%.0f%% of the area at %.0f%%", used * 100, res.scale * 100))
        check(zip(fr, sizes).allSatisfy { abs($0.width / $1.width - res.scale) < 0.001 && abs($0.height / $1.height - res.scale) < 0.001 }, "pack boxes: one scale for all layers")

        let rounds: [CGSize] = (0..<12).map { (i: Int) -> CGSize in
            let side = CGFloat(40 + (i * 9) % 50)
            return CGSize(width: side, height: side)
        }
        let rc = Packing.pack(sizes: rounds, in: circle, mode: .circles, padding: 8, scaleToFit: true)
        let cf = rc.frames.compactMap { $0 }
        var touching = false
        for i in 0..<cf.count { for j in (i + 1)..<cf.count where cf[i].center.distance(to: cf[j].center) < cf[i].width / 2 + cf[j].width / 2 + 7.9 { touching = true } }
        check(cf.count == 12 && !touching && cf.allSatisfy { $0.center.distance(to: ctr) + $0.width / 2 <= 200.01 }, "pack circles: no overlaps, inside the circle", "scale \(rc.scale)")

        let heartShape = ShapeLibrary.shape("heart")!.path(in: CGRect(x: 100, y: 50, width: 400, height: 400)).resolved
        let rh = Packing.pack(sizes: sizes, in: heartShape.path, evenOdd: heartShape.evenOdd, mode: .boxes, padding: 4, scaleToFit: true)
        let hf = rh.frames.compactMap { $0 }
        check(hf.count == 14 && !overlaps(hf, gap: 3.9) && hf.allSatisfy { $0.corners.allSatisfy { heartShape.path.contains($0) } }, "pack into a custom shape (heart): inside, no overlaps")

        let tiny = CGPath(rect: CGRect(x: 0, y: 0, width: 150, height: 150), transform: nil)
        let nofit = Packing.pack(sizes: sizes, in: tiny, mode: .boxes, padding: 4, scaleToFit: false)
        let nf = nofit.frames.compactMap { $0 }
        check(nofit.scale == 1 && nf.count < 14 && nf.count >= 1 && !overlaps(nf, gap: 3.9) && nf.allSatisfy { CGRect(x: 0, y: 0, width: 150, height: 150).contains($0) },
              "pack without scaling: places what fits, leaves the rest", "\(nf.count) of 14")

        // a selection as the shape: its marching-ants outline is chained into fillable loops (here a ring, i.e. with a hole)
        let ringPath = CGMutablePath()
        ringPath.addEllipse(in: CGRect(x: 60, y: 40, width: 480, height: 420))
        ringPath.addEllipse(in: CGRect(x: 220, y: 170, width: 160, height: 160))
        let ring = SelectionOps.mask(fromPath: ringPath, width: 600, height: 500, antialias: false, evenOdd: true)
        let region = LayoutGeom.regionPath(fromMask: ring)
        check(region.contains(CGPoint(x: 120, y: 250), using: .evenOdd) && !region.contains(CGPoint(x: 300, y: 250), using: .evenOdd) && !region.contains(CGPoint(x: 20, y: 20), using: .evenOdd),
              "selection outline becomes a fillable region (holes stay holes)")
        let rs = Packing.pack(sizes: sizes, in: region, evenOdd: true, mode: .boxes, padding: 4, scaleToFit: true)
        let rf = rs.frames.compactMap { $0 }
        func inRing(_ p: CGPoint) -> Bool { ringPath.contains(p, using: .evenOdd) }
        check(rf.count == 14 && !overlaps(rf, gap: 3.9) && rf.allSatisfy { $0.corners.allSatisfy(inRing) && inRing($0.center) }, "pack into a selection with a hole: nothing lands in the hole")

        // document level
        var st = SelfTest.baseState(600, 500)
        var ids: [UUID] = []
        let cols = ["E94F37", "F6AE2D", "2E86AB", "33658A", "86BBD8", "758E4F", "F26419", "6A4C93", "1982C4", "FF595E", "8AC926", "FFCA3A"]
        for (i, c) in cols.enumerated() {
            let sz = 36 + CGFloat(i * 17 % 60)
            let l = ellipse(CGRect(x: 20 + CGFloat(i % 6) * 95, y: 30 + CGFloat(i / 6) * 240, width: sz, height: sz), c, name: "Dot \(i + 1)")
            st.layers.append(l); ids.append(l.id)
        }
        withDoc(st) { d in
            let before = d.state
            d.selectedLayerIDs = Set(ids); d.activeLayerID = ids[0]
            var s = PackSettings()
            s.shape = .custom; s.customID = "heart"; s.mode = .circles; s.width = 440; s.height = 440; s.centerX = 300; s.centerY = 250; s.padding = 6
            let r = Packing.packed(s, base: d.state, ids: ids, doc: d)
            d.state = r.state
            d.commit("Pack into Custom Shape")
            let b = ids.map { bounds($0, d.state) }
            var hit = false
            for i in 0..<b.count { for j in (i + 1)..<b.count where b[i].center.distance(to: b[j].center) < b[i].width / 2 + b[j].width / 2 + 3 { hit = true } }
            check(r.placed == 12 && !hit, "Pack into Shape: 12 layers packed into the heart without overlaps", String(format: "scale %.2f", r.scale))
            check(b.allSatisfy { r.outline?.contains($0.center) == true }, "Pack into Shape: layers sit inside the outline")
            save(d.state, "layout_pack_heart", out)
            undoRestores(d, before, "Pack into Shape")
            d.undo()
            var s2 = PackSettings(); s2.shape = .rectangle; s2.mode = .boxes; s2.width = 420; s2.height = 260; s2.centerX = 300; s2.centerY = 250; s2.padding = 10
            d.state = Packing.packed(s2, base: d.state, ids: ids, doc: d).state
            let b2 = ids.map { bounds($0, d.state) }
            check(!overlaps(b2, gap: 9) && b2.allSatisfy { CGRect(x: 90, y: 120, width: 420, height: 260).insetBy(dx: -1, dy: -1).contains($0) }, "Pack into a rectangle: boxes inside with 10 px padding")
            save(d.state, "layout_pack_rect", out)
            d.revertUncommitted()
            d.state.selection = ring
            var s3 = PackSettings(); s3.shape = .selection; s3.mode = .circles; s3.padding = 6
            let r3 = Packing.packed(s3, base: d.state, ids: ids, doc: d)
            d.state = r3.state
            let b3 = ids.map { bounds($0, d.state) }
            check(r3.placed == 12 && b3.allSatisfy { inRing($0.center) && inRing(CGPoint(x: $0.minX + 2, y: $0.midY)) && inRing(CGPoint(x: $0.maxX - 2, y: $0.midY)) }, "Pack into Shape ▸ Selection")
            save(d.state, "layout_pack_selection", out)
        }
    }

    static func collage(_ out: URL) {
        let aspects: [CGFloat] = [1.5, 0.67, 1, 2, 0.77, 1.33, 1.78]
        let area = CGRect(x: 0, y: 0, width: 800, height: 600)
        func disjoint(_ c: [CGRect], gutter: CGFloat) -> Bool {
            for i in 0..<c.count { for j in (i + 1)..<c.count where c[i].insetBy(dx: -(gutter - 1) / 2, dy: -(gutter - 1) / 2).intersects(c[j].insetBy(dx: -(gutter - 1) / 2, dy: -(gutter - 1) / 2)) { return false } }
            return true
        }
        for style in CollageSettings.Style.allCases {
            var s = CollageSettings(); s.style = style; s.gutter = 10; s.margin = 10
            let cells = Collage.layout(aspects: aspects, in: area, s)
            let u = LayoutGeom.union(cells) ?? .zero
            let filled = cells.reduce(CGFloat(0)) { $0 + $1.width * $1.height } / (780 * 580)
            check(cells.count == 7 && disjoint(cells, gutter: 10) && u == CGRect(x: 10, y: 10, width: 780, height: 580), "collage \(style.rawValue): cells fill the area exactly, separated by the gutter", "\(u)")
            check(filled > 0.9, "collage \(style.rawValue): no holes", String(format: "%.0f%% covered", filled * 100))
            if style != .mosaic {
                s.keepAspect = true
                let k = Collage.layout(aspects: aspects, in: area, s)
                let ok = zip(k, aspects).allSatisfy { abs($0.width / $0.height / $1 - 1) < 0.04 }
                check(k.count == 7 && ok && disjoint(k, gutter: 10) && k.allSatisfy { area.insetBy(dx: 9, dy: 9).contains($0) }, "collage \(style.rawValue): keep proportions never crops")
            }
        }

        var st = SelfTest.baseState(800, 600)
        let photos = [photo(300, 200, "E94F37", name: "Beach"), photo(200, 300, "2E86AB", name: "Tower"), photo(250, 250, "F6AE2D", name: "Sun"),
                      photo(400, 200, "758E4F", name: "Field"), photo(200, 260, "6A4C93", name: "Door"), photo(320, 240, "1982C4", name: "Lake")]
        for (i, p) in photos.enumerated() { var l = p; l.translate(dx: Double(20 + i * 90), dy: Double(30 + i * 40)); st.layers.append(l) }
        let ids = photos.map(\.id)
        for style in CollageSettings.Style.allCases {
            withDoc(st) { d in
                let before = d.state
                d.selectedLayerIDs = Set(ids); d.activeLayerID = ids[0]
                var s = CollageSettings(); s.style = style; s.gutter = 12; s.margin = 16; s.cornerRadius = style == .masonry ? 18 : 0
                var map: [UUID: UUID] = [:]
                let b = Collage.build(s, base: d.state, ids: d.orderedSelection, area: d.state.canvasCGRect, idMap: &map)
                d.state = b.state
                if let g = b.group { d.activeLayerID = g; d.selectedLayerIDs = [g] }
                d.commit("Auto Collage")
                let frames = b.frames.compactMap { d.state.layer($0) }
                let good = frames.allSatisfy { f in
                    guard let vm = f.vectorMask, f.children.count == 1, let kid = f.children.first, let kb = Compositor.shared.contentBounds(kid, state: d.state) else { return false }
                    return kid.isSmartObject && kb.insetBy(dx: -0.6, dy: -0.6).contains(vm.bounds) && FrameSupport.isFrame(d.state, f.id)
                }
                check(frames.count == 6 && good, "Auto Collage (\(style.rawValue)): each cell is a frame whose picture covers it")
                check(zip(frames, b.cells).allSatisfy { abs($0.vectorMask!.bounds.width - $1.width) < 0.5 && abs($0.vectorMask!.bounds.minX - $1.minX) < 0.5 }, "collage frames match the computed cells")
                // pictures keep their proportions (cover, not stretch)
                let prop = frames.allSatisfy { f in
                    guard let so = f.children.first?.smart else { return false }
                    let q = so.quad.bounds, sz = so.source.size
                    return abs(q.width / q.height - sz.width / sz.height) < 0.02
                }
                check(prop, "collage pictures are scaled uniformly")
                let px = flat(d.state)
                let corner = rgb(px, 5, 5)
                check(corner.b > 200, "collage: the margin shows the background", "\(corner)")
                save(d.state, "layout_collage_\(style == .justified ? "justified" : style == .masonry ? "masonry" : "mosaic")", out)
                // a picture can be moved inside its frame afterwards
                if let f = frames.first, let kid = f.children.first {
                    let mask = f.vectorMask!.bounds
                    d.updateLayer(kid.id) { $0.translate(dx: 15, dy: 0) }
                    check(d.state.layer(f.id)?.vectorMask?.bounds == mask, "moving the picture leaves its frame where it is")
                    d.revertUncommitted()
                }
                undoRestores(d, before, "Auto Collage (\(style.rawValue))")
            }
        }
        // extra image files (not yet in the document) + stable ids across preview rebuilds
        withDoc(SelfTest.baseState(500, 400)) { d in
            let extra = [Collage.imageLayer(photos[0].raster!.buffer, name: "A"), Collage.imageLayer(photos[1].raster!.buffer, name: "B"), Collage.imageLayer(photos[2].raster!.buffer, name: "C")]
            var map: [UUID: UUID] = [:]
            var s = CollageSettings(); s.style = .mosaic
            let b1 = Collage.build(s, base: d.state, ids: [], extra: extra, area: d.state.canvasCGRect, idMap: &map)
            s.gutter = 30
            let b2 = Collage.build(s, base: d.state, ids: [], extra: extra, area: d.state.canvasCGRect, idMap: &map)
            check(b1.frames.count == 3 && b1.frames == b2.frames && b1.group == b2.group && b1.cells != b2.cells, "collage from image files; preview rebuilds reuse the same layer ids")
        }
    }

    // MARK: 4. Select similar

    static func selectSimilar() {
        var st = SelfTest.baseState(600, 400)
        var a = rect(CGRect(x: 20, y: 20, width: 80, height: 50), "E94F37", name: "Card 1")
        var b = rect(CGRect(x: 120, y: 20, width: 80, height: 50), "E94F37", name: "Card 2")
        var c = rect(CGRect(x: 220, y: 20, width: 120, height: 50), "2E86AB", name: "Card copy 3")
        let e1 = ellipse(CGRect(x: 20, y: 100, width: 80, height: 50), "E94F37", name: "Badge")
        var e2 = ellipse(CGRect(x: 120, y: 100, width: 60, height: 60), "2E86AB", name: "Dot")
        let t1 = text("Title", at: CGPoint(x: 20, y: 200), size: 32, hex: "E94F37", font: "Helvetica-Bold", name: "Title")
        let t2 = text("Body", at: CGPoint(x: 20, y: 250), size: 18, font: "Helvetica", name: "Body")
        var t3 = text("Other", at: CGPoint(x: 20, y: 300), size: 32, font: "Georgia", name: "Other")
        a.effects.dropShadow.enabled = true
        b.effects.dropShadow.enabled = true
        c.blendMode = .multiply; e2.blendMode = .multiply
        a.colorLabel = .red; e2.colorLabel = .red
        a.shape?.stroke.paint = .color(.black); a.shape?.stroke.width = 4
        c.shape?.stroke.paint = .color(.black); c.shape?.stroke.width = 4
        if var tt = t3.text { tt.applyStyle(CharacterStyle(fontName: "Helvetica-Bold"), to: NSRange(location: 0, length: 2)); t3.content = .text(tt) }
        let group = Layer(name: "Group 1", content: .group(GroupContent(children: [e1, e2], isExpanded: false)))
        st.layers += [a, b, c, group, t1, t2, t3]
        func ids(_ crit: SimilarCriterion, _ ref: Layer) -> Set<UUID> { Set(SelectSimilar.find(crit, ref: st.layer(ref.id)!, in: st)) }
        check(ids(.kind, a) == [a.id, b.id, c.id, e1.id, e2.id], "Same Kind: all shape layers, also inside groups")
        check(ids(.kind, t1) == [t1.id, t2.id, t3.id], "Same Kind: type layers")
        check(ids(.fill, a) == [a.id, b.id, e1.id, t1.id], "Same Fill Colour: shapes and type in the same colour")
        check(ids(.stroke, a) == [a.id, c.id] && ids(.stroke, b) == [b.id], "Same Stroke")
        check(ids(.font, t1) == [t1.id, t3.id], "Same Font: includes layers that use the font in a range")
        check(ids(.fontSize, t1) == [t1.id, t3.id] && ids(.fontSize, t2) == [t2.id], "Same Font Size")
        check(ids(.effects, a) == [a.id, b.id], "Same Effects")
        check(ids(.blendMode, c) == [c.id, e2.id], "Same Blend Mode")
        check(ids(.size, b) == [b.id, e1.id] && ids(.size, a) == [a.id], "Same Size (within 1 px; a stroke counts)")
        check(ids(.namePattern, a) == [a.id, b.id, c.id], "Same Name Pattern: Card 1 / Card 2 / Card copy 3")
        check(ids(.colorLabel, a) == [a.id, e2.id], "Same Colour Label")
        check(SelectSimilar.namePattern("Layer 12 copy 3") == "layer" && SelectSimilar.namePattern("Hero") == "hero", "name pattern strips numbers and “copy”")
        withDoc(st) { d in
            d.selectLayer(b.id)
            SelectSimilar.run(.size)
            check(d.selectedLayerIDs == [b.id, e1.id] && d.activeLayerID == b.id, "Select ▸ Similar Layers selects the matches and keeps the active layer")
            check(d.state.layer(group.id)?.isExpanded == true, "matches inside collapsed groups are revealed")
            check(!d.canUndo, "selecting is not a history step")
        }
    }

    // MARK: 5. Find & replace

    static func replace(_ out: URL) {
        var st = SelfTest.baseState(640, 360)
        let t1 = text("Summer Sale 2025", at: CGPoint(x: 30, y: 30), size: 40, hex: "E94F37", name: "Headline")
        var t2 = text("Big SALE — sale ends soon", at: CGPoint(x: 30, y: 100), size: 28, font: "Georgia", name: "Sub")
        let t3 = text("No match here", at: CGPoint(x: 30, y: 160), size: 22, font: "NoSuchFont-Regular", name: "Note")
        if var tt = t2.text {
            tt.applyStyle(CharacterStyle(fontName: "Helvetica-Bold", color: RGBA(hex: "2E86AB")), to: NSRange(location: 4, length: 4))   // "SALE"
            t2.content = .text(tt)
        }
        var card = rect(CGRect(x: 30, y: 220, width: 160, height: 100), "E94F37", name: "Card")
        card.shape?.stroke.paint = .color(RGBA(hex: "111111")!); card.shape?.stroke.width = 3
        var near = rect(CGRect(x: 210, y: 220, width: 160, height: 100), "E95038", name: "Near")
        near.effects.dropShadow.enabled = true; near.effects.dropShadow.color = RGBA(hex: "E94F37")!
        var grad = Layer(name: "Gradient", content: .shape(ShapeContent(geometry: .ellipse(CGRect(x: 400, y: 220, width: 100, height: 100)),
                                                                          fill: .gradient(GradientFill(gradient: .twoColor(RGBA(hex: "E94F37")!, RGBA(r: 1, g: 1, b: 1, a: 0.5)))))))
        grad.effects.colorOverlay.color = RGBA(hex: "00FF00")!     // disabled effect: must not be listed
        let inner = Layer(name: "Group", content: .group(GroupContent(children: [rect(CGRect(x: 520, y: 220, width: 80, height: 100), "E94F37", name: "Nested")])))
        st.layers += [card, near, grad, inner, t1, t2, t3]

        // text
        var q = TextQuery(find: "sale", replace: "Deal")
        var m = DocReplace.textMatches(q, in: st)
        check(m.count == 3 && Set(m.map(\.layerID)) == [t1.id, t2.id] && m.first?.layerID == t2.id, "find text: 3 matches in 2 layers, listed top layer first", "\(m.map(\.match))")
        check(m.first(where: { $0.layerID == t1.id }).map { $0.before == "Summer " && $0.match == "Sale" && $0.after == " 2025" } == true, "find text: results carry their context")
        q.caseSensitive = true
        check(DocReplace.textMatches(q, in: st).count == 1, "find text: match case")
        q.caseSensitive = false; q.find = "sal"; q.wholeWord = true
        check(DocReplace.textMatches(q, in: st).isEmpty, "find text: whole word")
        q = TextQuery(find: #"s[ae]le\b"#, replace: "", regex: true)
        check(DocReplace.textMatches(q, in: st).count == 3, "find text: regular expression")
        check(DocReplace.regex(TextQuery(find: "(", regex: true)) == nil && DocReplace.textMatches(TextQuery(find: "(", regex: false), in: st).isEmpty, "find text: invalid regex is rejected, literal search escapes it")

        withDoc(st) { d in
            let before = d.state
            save(d.state, "layout_replace_before", out)
            var work = d.state
            let n = DocReplace.replaceText(TextQuery(find: "sale", replace: "Deal"), in: &work)
            d.state = work
            d.commit("Replace Text (\(n))")
            let s2 = d.state.layer(t2.id)!.text!
            check(n == 3 && d.state.layer(t1.id)?.text?.text == "Summer Deal 2025" && s2.text == "Big Deal — Deal ends soon", "Replace All changes every type layer", s2.text)
            check(s2.runs.count == 1 && s2.runs[0].range == NSRange(location: 4, length: 4) && s2.runs[0].style.color == RGBA(hex: "2E86AB") && s2.runs[0].style.fontName == "Helvetica-Bold",
                  "replaced text keeps the styling of the range it replaced", "\(s2.runs)")
            undoRestores(d, before, "Replace Text")
            // one match only
            m = DocReplace.textMatches(TextQuery(find: "deal", replace: "X"), in: d.state)
            var one = d.state
            let k = DocReplace.replaceText(TextQuery(find: "deal", replace: "Offer!"), in: &one, only: [m.last!.id])
            check(k == 1 && one.layer(t1.id)?.text?.text == "Summer Offer! 2025" && one.layer(t2.id)?.text?.text == "Big Deal — Deal ends soon", "Replace (single result) only touches that match")
            // regex with a capture group, different length, runs after it shift
            var rx = d.state
            DocReplace.replaceText(TextQuery(find: #"(B)ig"#, replace: "$1IGGER", regex: true, caseSensitive: true), in: &rx)
            let r2 = rx.layer(t2.id)!.text!
            check(r2.text == "BIGGER Deal — Deal ends soon" && r2.runs.first?.range == NSRange(location: 7, length: 4), "regex replace with a capture group; later styled ranges shift", "\(r2.text) \(r2.runs.map(\.range))")
            var lit = d.state
            DocReplace.replaceText(TextQuery(find: "2025", replace: "$1 (new)"), in: &lit)
            check(lit.layer(t1.id)?.text?.text == "Summer Deal $1 (new)", "literal replace does not treat $ as a template")

            // colours
            let cu = DocReplace.colors(in: d.state)
            let red = cu.first { $0.hex == "E94F37" }
            check(red?.count == 5 && Set(red?.kinds ?? []) == ["Fill", "Effect", "Gradient", "Type"] && red?.layers.count == 5, "colour list: #E94F37 is used 5× (fills, type, effect, gradient stop)", "\(String(describing: red))")
            check(cu.first?.hex == "E94F37" && cu.contains { $0.hex == "111111" && $0.kinds.contains("Stroke") } && !cu.contains { $0.hex == "00FF00" }, "colour list: most used first, strokes listed, disabled effects ignored")
            let beforeColor = d.state
            var cs = d.state
            let cn = DocReplace.replaceColor(RGBA(hex: "E94F37")!, with: RGBA(hex: "2E86AB")!, tolerance: 0, in: &cs)
            d.state = cs; d.commit("Replace Colour")
            let g2 = d.state.layer(grad.id)!.shape!.fill
            var stops: [RGBA] = []
            if case .gradient(let gf) = g2 { stops = gf.gradient.stops.map(\.color) }
            check(cn == 5 && d.state.layer(card.id)?.shape?.fill.solidColor == RGBA(hex: "2E86AB") && d.state.layer(t1.id)?.text?.color == RGBA(hex: "2E86AB")
                  && d.state.layer(near.id)?.effects.dropShadow.color == RGBA(hex: "2E86AB") && d.state.layer(near.id)?.shape?.fill.solidColor == RGBA(hex: "E95038")
                  && stops.first == RGBA(hex: "2E86AB") && abs((stops.last?.a ?? 0) - 0.5) < 1e-9,
                  "Replace Colour: exact matches everywhere, near shade and other stops untouched", "\(cn)")
            check(d.state.layer(d.state.layer(inner.id)!.children[0].id)?.shape?.fill.solidColor == RGBA(hex: "2E86AB"), "Replace Colour reaches layers inside groups")
            save(d.state, "layout_replace_after", out)
            undoRestores(d, beforeColor, "Replace Colour")
            d.undo()
            var tol = d.state
            let tn = DocReplace.replaceColor(RGBA(hex: "E94F37")!, with: RGBA(r: 0, g: 0.5, b: 0, a: 1), tolerance: 5, in: &tol)
            check(tn == 6 && tol.layer(near.id)?.shape?.fill.solidColor == RGBA(r: 0, g: 0.5, b: 0), "Replace Colour with tolerance also catches the near shade")

            // fonts
            let fu = DocReplace.fonts(in: d.state)
            check(fu.first?.name == "NoSuchFont-Regular" && fu.first?.missing == true && fu.filter(\.missing).count == 1, "font list: missing fonts are reported first", "\(fu.map(\.name))")
            check(fu.first { $0.name == "Helvetica-Bold" }?.count == 2 && fu.first { $0.name == "Georgia" }?.count == 1, "font list: usage counts include styled ranges")
            let beforeFont = d.state
            var fs = d.state
            let fn = DocReplace.replaceFont("NoSuchFont-Regular", with: "Helvetica", in: &fs) + DocReplace.replaceFont("Helvetica-Bold", with: "Georgia-Bold", in: &fs)
            d.state = fs; d.commit("Replace Font")
            let after = DocReplace.fonts(in: d.state)
            check(fn == 3 && !after.contains { $0.missing } && d.state.layer(t1.id)?.text?.fontName == "Georgia-Bold" && d.state.layer(t2.id)?.text?.runs.first?.style.fontName == "Georgia-Bold"
                  && d.state.layer(t3.id)?.text?.fontName == "Helvetica", "Replace Font: layer fonts and styled ranges, no font missing afterwards", "\(after.map(\.name))")
            save(d.state, "layout_replace_fonts", out)
            undoRestores(d, beforeFont, "Replace Font")
        }
    }

    // MARK: 6. Smart resize + safe zones

    static func sampleDesign() -> (state: DocumentState, bg: UUID, subject: UUID, headline: UUID, cta: UUID, logo: UUID) {
        var st = DocumentState(width: 1080, height: 1080)
        let buf = PixelBuffer(width: 1080, height: 1080)
        let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "1B2A49")!.cgColor, RGBA(hex: "C84B31")!.cgColor, RGBA(hex: "F6AE2D")!.cgColor] as CFArray, locations: [0, 0.6, 1])!
        buf.context.drawLinearGradient(g, start: .zero, end: CGPoint(x: 1080, y: 1080), options: [])
        buf.context.setFillColor(RGBA(r: 1, g: 1, b: 1, a: 0.08).cgColor)
        for i in 0..<9 { buf.context.fillEllipse(in: CGRect(x: 80 + i * 110, y: 760 + (i % 3) * 60, width: 150, height: 150)) }
        buf.markDirty()
        let bg = Layer.raster(name: "Photo", buffer: buf)
        var subject = ellipse(CGRect(x: 330, y: 400, width: 420, height: 420), "FFFFFF", name: "Product")
        subject.effects.dropShadow.enabled = true; subject.effects.dropShadow.size = 30; subject.effects.dropShadow.distance = 20
        let headline = text("SUMMER\nSALE", at: CGPoint(x: 70, y: 70), size: 110, hex: "FFFFFF", name: "Headline")
        let cta = text("Shop now →", at: CGPoint(x: 770, y: 970), size: 44, hex: "FFFFFF", font: "Helvetica", name: "CTA")
        let logo = rect(CGRect(x: 900, y: 70, width: 110, height: 60), "F6AE2D", name: "Logo", radius: 12)
        st.layers = [bg, subject, headline, cta, logo]
        return (st, bg.id, subject.id, headline.id, cta.id, logo.id)
    }

    static func smartResize(_ out: URL) {
        let s = sampleDesign()
        let src = CGRect(x: 0, y: 0, width: 1080, height: 1080)
        let roles = SmartResize.roles(s.state.layers, source: src, state: s.state)
        check(roles[s.bg] == .background && roles[s.subject] == .subject && roles[s.headline] == .text && roles[s.cta] == .text && roles[s.logo] == .element, "smart resize: layer roles (background, subject, type, element)")

        let formats = ["igPortrait", "story", "ytThumb", "xPost"].compactMap { id in SocialFormat.all.first { $0.id == id } }
        withDoc(s.state) { d in
            let before = d.state
            let t0 = CFAbsoluteTimeGetCurrent()
            let ids = SmartResize.run(d, formats: formats)
            print(String(format: "layout: smart resize to 4 formats %.0f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
            let boards = AppActions.artboards(d)
            check(ids.count == 4 && boards.count == 5 && boards.first?.name == "Original" && boards.first?.artboard?.rect == src, "Smart Resize: one artboard per format next to the original")
            check(d.history.last?.name == "Smart Resize (4 formats)" && d.history.count == 2, "Smart Resize is a single history step")
            check(d.state.width >= 1080 + 4 * 100 + 1080 + 1080 + 1280 + 1600 && d.state.height == 1920, "the canvas grows to hold the artboards", "\(d.state.width) × \(d.state.height)")
            for (f, id) in zip(formats, ids) {
                guard let ab = d.state.layer(id), let r = ab.artboard?.rect else { check(false, "\(f.name): artboard exists"); continue }
                check(r.size == f.size && ab.children.count == 5, "\(f.name): artboard is \(f.width) × \(f.height) with all five layers")
                let kids = ab.children
                let kb = kids.map { Compositor.shared.contentBounds($0, state: d.state) ?? .null }
                // order is preserved: photo, product, headline, cta, logo
                check(kb[0].insetBy(dx: -1, dy: -1).contains(r), "\(f.name): the background fills the artboard", "\(kb[0].integral) vs \(r)")
                check(r.contains(kb[2]) && r.contains(kb[3]), "\(f.name): type stays inside the artboard", "\(kb[2].integral) \(kb[3].integral)")
                check(r.contains(kb[1]) && kb[1].width * kb[1].height >= 0.05 * r.width * r.height && abs(kb[1].width / kb[1].height - 1) < 0.01, "\(f.name): the subject is fully visible, large and undistorted",
                      "\(kb[1].integral)")
                check(!kb[2].intersects(kb[1]) && !kb[3].intersects(kb[1]), "\(f.name): type does not run into the subject")
                check(r.contains(kb[4]) && abs(kb[4].width / kb[4].height - 110.0 / 60) < 0.02, "\(f.name): the logo stays inside and keeps its proportions")
                // anchors: headline top-left, CTA bottom-right, logo top-right
                check(kb[2].midX < r.midX && kb[2].midY < r.midY && kb[3].midX > r.midX && kb[3].midY > r.midY && kb[4].midX > r.midX && kb[4].midY < r.midY, "\(f.name): elements keep their corner")
                if f.id == "story" {
                    let safe = SafeZones.safeRect(.story, in: r)
                    check(safe.contains(kb[2]) && safe.contains(kb[3]) && safe.contains(kb[4]), "\(f.name): type and logo stay clear of the story interface bars", "\(kb[2].integral) in \(safe.integral)")
                }
                let sizes = [kids[2], kids[3]].compactMap { $0.text.map { SelectSimilar.fontSize($0) } }
                check(sizes.allSatisfy { $0 >= 23.9 }, "\(f.name): type stays readable", "\(sizes.map { Int($0) }) px")
                if let one = AppActions.artboardState(d.state, ab) { save(one, "layout_smartresize_\(f.id)", out, scale: 0.5) }
            }
            save(d.state, "layout_smartresize_all", out, scale: 0.2)
            // (pixel comparison of the 6520 px wide document is slow in debug builds: compare the layer trees on redo)
            let after = d.state
            d.undo()
            check(same(before, d.state), "undo restores the document after Smart Resize")
            d.redo()
            check(d.state.width == after.width && d.state.allLayers.map(\.id) == after.allLayers.map(\.id), "redo re-applies Smart Resize")
        }

        // constraints win over the automatic placement; a second run uses the active artboard as the source
        var cs = s.state
        cs.updateLayer(s.logo) { $0.constraints = LayoutConstraints(horizontal: .end, vertical: .end) }
        let tg = SmartResize.targets(cs.layers, from: src, to: CGRect(x: 0, y: 0, width: 1080, height: 1920), state: cs, options: SmartResizeOptions())
        check(tg[s.logo] == CGRect(x: 900, y: 1920 - 1010, width: 110, height: 60), "Smart Resize honours layer constraints", "\(String(describing: tg[s.logo]))")

        // content-aware extension of a photo background (small gap only)
        var small = DocumentState(width: 300, height: 300)
        SmartResize.fillSize = 120          // keeps the (debug-build) test quick; also exercises the reduced-size path
        defer { SmartResize.fillSize = 640 }
        let ph = photo(300, 300, "2E86AB", name: "Photo")
        small.layers = [ph, text("Hi", at: CGPoint(x: 20, y: 20), size: 40, hex: "FFFFFF")]
        var o = SmartResizeOptions(); o.extendBackground = true
        let t1 = CFAbsoluteTimeGetCurrent()
        let ext = SmartResize.adapt(small.layers, from: small.canvasCGRect, to: CGRect(x: 0, y: 0, width: 300, height: 360), state: DocumentState(width: 300, height: 360), options: o)
        print(String(format: "layout: content-aware background extension %.0f ms", (CFAbsoluteTimeGetCurrent() - t1) * 1000))
        if let r = ext.first?.raster {
            let a = r.buffer.pixel(150, 5).3, b = r.buffer.pixel(150, 355).3, mid = r.buffer.pixel(150, 180)
            check(r.buffer.width == 300 && r.buffer.height == 360 && a == 255 && b == 255 && mid.3 == 255, "extend background: the missing bands are filled, nothing is cropped", "\(a) \(b)")
            var es = DocumentState(width: 300, height: 360); es.layers = ext
            save(es, "layout_smartresize_extend", out)
        } else { check(false, "extend background produced a pixel layer") }
        let far = SmartResize.extendedBackground(ph, bounds: small.canvasCGRect, from: small.canvasCGRect, to: CGRect(x: 0, y: 0, width: 300, height: 900), state: DocumentState(width: 300, height: 900), options: o)
        check(far == nil, "extend background: large gaps fall back to scale-to-fill")

        // safe zones
        check(SafeZones.resolve(.auto, size: CGSize(width: 1080, height: 1920)) == .story && SafeZones.resolve(.auto, size: CGSize(width: 1280, height: 720)) == .youtube
              && SafeZones.resolve(.auto, size: CGSize(width: 1080, height: 1350)) == .feed && SafeZones.resolve(.auto, size: CGSize(width: 1080, height: 1080)) == .title, "safe zones: Auto picks the zone by format")
        let sr = SafeZones.safeRect(.story, in: CGRect(x: 0, y: 0, width: 1080, height: 1920))
        check(abs(sr.minY - 249.6) < 0.1 && abs(sr.maxY - 1574.4) < 0.1 && sr.width == 1080, "safe zones: story keeps the top and bottom UI bars clear", "\(sr)")
        withDoc(s.state) { d in
            let ids = SmartResize.run(d, formats: [formats[1]])
            let c = CanvasView(frame: CGRect(x: 0, y: 0, width: 1000, height: 560))
            c.document = d; d.showRulers = false
            c.fitOnScreen()
            SafeZones.kind = .auto
            check(SafeZones.frames(d.state).count == 2, "safe zones are drawn per artboard")
            let unchanged = d.state.allLayers.map(\.id)
            ToolsSelfTest.snapOverlay(c, "layout_safe_zones", out)
            check(d.state.allLayers.map(\.id) == unchanged && !d.canRedo && d.history.count == 2, "safe zones are an overlay only (nothing is added to the document)")
            SafeZones.kind = .off
            _ = ids
        }
    }

    // MARK: 7. Constraints

    static func constraints(_ out: URL) {
        typealias C = LayoutConstraints
        check(C.resolve(.start, pos: 30, len: 50, from: 0, 400, to: 0, 600) == (30, 50), "constraint maths: pin start")
        check(C.resolve(.end, pos: 330, len: 50, from: 0, 400, to: 0, 600) == (530, 50), "constraint maths: pin end")
        check(C.resolve(.both, pos: 30, len: 340, from: 0, 400, to: 0, 600) == (30, 540), "constraint maths: pin both (stretch)")
        check(C.resolve(.center, pos: 210, len: 40, from: 0, 400, to: 0, 600) == (310, 40), "constraint maths: centre keeps its offset")
        check(C.resolve(.scale, pos: 100, len: 40, from: 0, 400, to: 0, 600) == (150, 60), "constraint maths: scale")
        check(C.resolve(.end, pos: 130, len: 50, from: 100, 200, to: 300, 500) == (630, 50), "constraint maths: moved container")

        var st = SelfTest.baseState(400, 300)
        var a = rect(CGRect(x: 20, y: 20, width: 60, height: 40), "E94F37", name: "Left Top"); a.constraints = C(horizontal: .start, vertical: .start)
        var b = rect(CGRect(x: 320, y: 240, width: 60, height: 40), "2E86AB", name: "Right Bottom"); b.constraints = C(horizontal: .end, vertical: .end)
        var c = rect(CGRect(x: 180, y: 130, width: 40, height: 40), "F6AE2D", name: "Centre"); c.constraints = C(horizontal: .center, vertical: .center)
        var s = rect(CGRect(x: 20, y: 80, width: 360, height: 24), "6A4C93", name: "Stretch"); s.constraints = C(horizontal: .both, vertical: .start)
        var k = rect(CGRect(x: 100, y: 200, width: 80, height: 60), "758E4F", name: "Scale"); k.constraints = C(horizontal: .scale, vertical: .scale)
        let free = rect(CGRect(x: 250, y: 30, width: 50, height: 30), "111111", name: "Free")
        var label = text("Footer", at: CGPoint(x: 20, y: 262), size: 20, name: "Footer"); label.constraints = C(horizontal: .start, vertical: .end)
        st.layers += [a, b, c, s, k, free, label]
        withDoc(st) { d in
            let before = d.state
            save(d.state, "layout_constraints_before", out)
            let lb0 = bounds(label.id, d.state)
            AppActions.canvasSize(width: 600, height: 400, anchorX: 1, anchorY: 1, extension: nil)
            func bb(_ l: Layer) -> CGRect { bounds(l.id, d.state) }
            check(d.state.width == 600 && d.state.height == 400, "canvas resized")
            check(bb(a) == CGRect(x: 20, y: 20, width: 60, height: 40), "Canvas Size: left / top pin stays put", "\(bb(a))")
            check(bb(b) == CGRect(x: 520, y: 340, width: 60, height: 40), "Canvas Size: right / bottom pin keeps its margins", "\(bb(b))")
            check(bb(c) == CGRect(x: 280, y: 180, width: 40, height: 40), "Canvas Size: centre stays centred", "\(bb(c))")
            check(bb(s) == CGRect(x: 20, y: 80, width: 560, height: 24), "Canvas Size: left & right stretches", "\(bb(s))")
            check(bb(k) == CGRect(x: 150, y: 267, width: 120, height: 80), "Canvas Size: scale follows proportionally", "\(bb(k))")
            check(bb(free) == CGRect(x: 350, y: 80, width: 50, height: 30), "Canvas Size: layers without constraints move with the anchor as before", "\(bb(free))")
            let lb1 = bb(label)
            check(abs(lb1.minX - lb0.minX) < 0.5 && abs((400 - lb1.maxY) - (300 - lb0.maxY)) < 0.5 && lb1.size == lb0.size, "Canvas Size: type pinned bottom-left", "\(lb1)")
            check(d.history.last?.name == "Canvas Size", "constraints are applied inside the Canvas Size step")
            save(d.state, "layout_constraints_after", out)
            undoRestores(d, before, "Canvas Size with constraints")
        }

        // artboard resize (any way of changing the artboard rectangle, picked up when the step is committed)
        var ast = DocumentState(width: 700, height: 400)
        var pinned = rect(CGRect(x: 250, y: 160, width: 40, height: 30), "E94F37", name: "Pinned"); pinned.constraints = C(horizontal: .end, vertical: .end)
        let loose = rect(CGRect(x: 40, y: 30, width: 40, height: 30), "2E86AB", name: "Loose")
        var board = Layer(name: "Artboard 1", content: .group(GroupContent(children: [loose, pinned], isExpanded: true, artboard: Artboard(rect: CGRect(x: 10, y: 10, width: 300, height: 200)))))
        board.blendMode = .normal
        ast.layers = [board]
        LayoutConstraintEngine.installCommitHook()
        withDoc(ast) { d in
            let before = d.state
            ArtboardTool.setRect(d, board.id, CGRect(x: 10, y: 10, width: 500, height: 320))
            d.commit("Resize Artboard")
            // (Auto-size Canvas trims the canvas to the artboard: positions are compared in the document's own coordinates)
            var o = d.state.artboardOrigin
            check(bounds(pinned.id, d.state) == CGRect(x: 450 + o.x, y: 280 + o.y, width: 40, height: 30) && bounds(loose.id, d.state) == CGRect(x: 40 + o.x, y: 30 + o.y, width: 40, height: 30),
                  "resizing an artboard moves its constrained layers", "\(bounds(pinned.id, d.state))")
            save(d.state, "layout_constraints_artboard", out)
            undoRestores(d, before, "Resize Artboard")
            d.undo()
            // moving an artboard is not a resize
            d.updateLayer(board.id) { $0.translate(dx: 30, dy: 0) }
            d.commit("Move Artboard")
            o = d.state.artboardOrigin
            check(bounds(pinned.id, d.state) == CGRect(x: 280 + o.x, y: 160 + o.y, width: 40, height: 30), "moving an artboard just moves its layers", "\(bounds(pinned.id, d.state))")
        }

        // persistence
        let data = try? JSONEncoder().encode(b)
        let back = data.flatMap { try? JSONDecoder().decode(Layer.self, from: $0) }
        check(back?.constraints == C(horizontal: .end, vertical: .end), "constraints round-trip with the layer")
        var plain = free
        plain.constraints = nil
        let pd = try? JSONEncoder().encode(plain)
        let hasKey = pd.flatMap { String(data: $0, encoding: .utf8) }?.contains("constraints") ?? true
        check(!hasKey && pd.flatMap { try? JSONDecoder().decode(Layer.self, from: $0) }?.constraints == nil, "layers without constraints are stored as before (older documents open unchanged)")
        let odd = #"{"horizontal":"sideways"}"#.data(using: .utf8)!
        check((try? JSONDecoder().decode(C.self, from: odd)) == C(), "unknown constraint values fall back to the default")
    }

    // MARK: UI snapshots (LUMEN_SELFTEST_UI=1)

    static func ui(_ out: URL) {
        var st = SelfTest.baseState(600, 400)
        var tile = rect(CGRect(x: 60, y: 60, width: 50, height: 50), "E94F37", name: "Tile")
        tile.constraints = LayoutConstraints(horizontal: .end, vertical: .center)
        st.layers += [tile, text("Hello world", at: CGPoint(x: 60, y: 200), size: 30), text("Missing", at: CGPoint(x: 60, y: 260), size: 30, font: "NoSuchFont-Regular")]
        let d = Document(state: st, name: "ui")
        AppModel.shared.add(d)
        defer { AppModel.shared.close(d) }
        d.selectLayer(tile.id)
        var s = RepeaterSettings(); s.mode = .scatter
        let box = { (v: AnyView) in AnyView(VStack(alignment: .leading, spacing: 8) { v }.padding(12).font(Theme.font).foregroundStyle(Theme.text)) }
        ToolsSelfTest.snapView(box(AnyView(RepeaterControls(s: .constant(s)))), "layout_ui_repeater_controls", CGSize(width: 360, height: 420), out)
        ToolsSelfTest.snapView(box(AnyView(ConstraintProperties(doc: d, layer: d.state.layer(tile.id)!))), "layout_ui_constraints", CGSize(width: 280, height: 140), out)
        ToolsSelfTest.snapView(SmartResizeDialog(), "layout_ui_smart_resize", CGSize(width: 400, height: 560), out)
        ToolsSelfTest.snapView(FindReplaceDialog(), "layout_ui_find_replace", CGSize(width: 430, height: 420), out)
        d.selectedLayerIDs = Set(d.state.layers.dropFirst().map(\.id))
        ToolsSelfTest.snapView(PackDialog(), "layout_ui_pack", CGSize(width: 340, height: 380), out)
        d.revertUncommitted(); ArrangeGuide.path = nil
        ToolsSelfTest.snapView(CollageDialog(), "layout_ui_collage", CGSize(width: 340, height: 340), out)
        d.revertUncommitted()
        ToolsSelfTest.snapView(DistributeSpacingDialog(), "layout_ui_spacing", CGSize(width: 320, height: 170), out)
        d.revertUncommitted()
        d.selectLayer(tile.id)
        ToolsSelfTest.snapView(RepeaterDialog(), "layout_ui_repeater_dialog", CGSize(width: 360, height: 430), out)
        ArrangeGuide.path = nil
        print("layout: wrote UI snapshots")
    }
}
