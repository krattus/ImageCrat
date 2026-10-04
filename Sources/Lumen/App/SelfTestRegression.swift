import AppKit
import CoreImage
import ImageCratCore

/// Regression tests for reported bugs. Run with LUMEN_SELFTEST_ONLY=regress.
enum RegressionTests {
    static func register() {
        FeatureModules.selfTests.append(("regress", { out in run(out) }))
    }

    static var failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") regress: \(name)\(detail.isEmpty ? "" : " — " + detail)")
    }

    /// Mean absolute difference per channel (0…255) between two states' composites.
    static func diff(_ a: DocumentState, _ b: DocumentState) -> Double {
        guard let ia = Compositor.shared.flatten(a, background: .white), let ib = Compositor.shared.flatten(b, background: .white),
              ia.width == ib.width, ia.height == ib.height else { return 999 }
        let pa = PixelBuffer(cgImage: ia), pb = PixelBuffer(cgImage: ib)
        let n = pa.bytesPerRow * pa.height
        let x = pa.data.assumingMemoryBound(to: UInt8.self), y = pb.data.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        for i in 0..<n { sum += abs(Int(x[i]) - Int(y[i])) }
        return Double(sum) / Double(n)
    }

    static func withDoc(_ st: DocumentState, _ body: (Document) -> Void) {
        let app = AppModel.shared
        let d = Document(state: st, name: "regress")
        app.documents.append(d); app.activeDocumentID = d.id
        body(d)
        app.documents.removeAll { $0.id == d.id }
    }

    static func run(_ out: URL) {
        failures = 0
        // Bug: converting a resized text layer to a smart object reset it to its original size.
        var st = SelfTest.baseState(600, 400)
        var t = TextContent()
        t.text = "Resize me"; t.fontSize = 40; t.position = CGPoint(x: 60, y: 60); t.color = .black
        var layer = Layer(name: "T", content: .text(t))
        let sp = CanvasSpace(width: st.width, height: st.height)
        let q = TextRenderer.docQuad(t)
        let scale = CGAffineTransform(translationX: -q.tl.x, y: -q.tl.y).scaledBy(x: 1, y: 1)
            .concatenating(CGAffineTransform(scaleX: 2.2, y: 2.2)).concatenating(CGAffineTransform(translationX: q.tl.x, y: q.tl.y))
        layer = LayerTransformer.apply(Homography(affine: scale), to: layer, space: sp)
        st.layers.append(layer)
        withDoc(st) { d in
            let before = d.state
            let boundsBefore = Compositor.shared.contentBounds(d.state.layer(layer.id)!, state: d.state)!
            d.selectLayer(layer.id)
            AppActions.convertToSmartObject()
            let so = d.activeLayer
            let boundsAfter = so.flatMap { Compositor.shared.contentBounds($0, state: d.state) } ?? .zero
            SelfTest.save(before, "regress_text_so_before", out)
            SelfTest.save(d.state, "regress_text_so_after", out)
            check(diff(before, d.state) < 0.6, "scaled text → smart object keeps its appearance", String(format: "diff %.2f", diff(before, d.state)))
            check(abs(boundsAfter.width - boundsBefore.width) < 12 && abs(boundsAfter.height - boundsBefore.height) < 12,
                  "smart object bounds match the scaled text", "\(boundsBefore.integral) vs \(boundsAfter.integral)")
        }
        // Same with Warp Text applied (the reported case: Type Layer → Move → Warp Text → Convert to Smart Object).
        for (name, prep) in [("warped", { (l: inout Layer) in
                                 if var tt = l.text { tt.warp = TextWarp(style: .arc, bend: 40); l.content = .text(tt) } }),
                             ("warped_moved", { (l: inout Layer) in
                                 if var tt = l.text { tt.warp = TextWarp(style: .arc, bend: 40); l.content = .text(tt) }
                                 l.translate(dx: 90, dy: 140) })] as [(String, (inout Layer) -> Void)] {
            var st2 = SelfTest.baseState(600, 400)
            var l2 = layer
            prep(&l2)
            st2.layers.append(l2)
            withDoc(st2) { d in
                let before = d.state
                let bb = Compositor.shared.contentBounds(d.state.layer(l2.id)!, state: d.state)!
                d.selectLayer(l2.id)
                AppActions.convertToSmartObject()
                let ba = d.activeLayer.flatMap { Compositor.shared.contentBounds($0, state: d.state) } ?? .zero
                SelfTest.save(before, "regress_text_so_\(name)_before", out)
                SelfTest.save(d.state, "regress_text_so_\(name)_after", out)
                check(diff(before, d.state) < 0.6, "\(name) text → smart object keeps its appearance", String(format: "diff %.2f", diff(before, d.state)))
                check(abs(ba.width - bb.width) < 12 && abs(ba.height - bb.height) < 12, "\(name): smart object bounds match", "\(bb.integral) vs \(ba.integral)")
            }
        }
        // Reported bug: resize with the transform handles, then Convert to Smart Object before confirming.
        do {
            var st3 = SelfTest.baseState(600, 400)
            var t3 = TextContent()
            t3.text = "Pending"; t3.fontSize = 40; t3.position = CGPoint(x: 60, y: 60); t3.color = .black
            let l3 = Layer(name: "T", content: .text(t3))
            st3.layers.append(l3)
            withDoc(st3) { d in
                PendingEdits.install()
                let c = CanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
                c.document = d; d.zoom = 1; d.viewOffset = .zero
                let oldCanvas = AppActions.canvas
                AppActions.canvas = c
                defer { AppActions.canvas = oldCanvas }
                AppModel.shared.tool = .move
                d.selectLayer(l3.id)
                guard let mt = c.tool(for: .move) as? MoveTool else { check(false, "move tool"); return }
                func scaleSession() {
                    mt.startTransform()
                    guard let s = mt.session else { return }
                    let o = s.quad.tl
                    s.quad = s.quad.mapped { CGPoint(x: o.x + ($0.x - o.x) * 2, y: o.y + ($0.y - o.y) * 2) }
                    s.updatePreview()
                }
                // expected result: commit the transform normally, then convert
                scaleSession()
                mt.commit()
                let scaledBounds = Compositor.shared.contentBounds(d.state.layer(l3.id)!, state: d.state)!
                let expected = d.state
                d.undo()
                // (a) what a menu command does now: the pending transform is applied first
                scaleSession()
                check(mt.isBusy, "transform session pending")
                PendingEdits.applyPendingTransform()
                AppActions.convertToSmartObject()
                let ba = d.activeLayer.flatMap { Compositor.shared.contentBounds($0, state: d.state) } ?? .zero
                SelfTest.save(d.state, "regress_pending_transform_then_smart_object", out)
                check(!mt.isBusy, "no transform box left behind after the command")
                check(d.activeLayer?.isSmartObject == true && abs(ba.width - scaledBounds.width) < 12, "pending resize is kept by Convert to Smart Object",
                      "\(scaledBounds.integral) vs \(ba.integral)")
                check(diff(expected, d.state) < 0.6, "result looks like the resized text", String(format: "diff %.2f", diff(expected, d.state)))
                // (b) safety net: a command that bypasses the hooks must not leave a detached transform box
                d.undo(); d.undo()
                d.selectLayer(l3.id)
                scaleSession()
                AppActions.duplicateLayers()
                check(!mt.isBusy && d.contentOverrides.isEmpty, "safety net drops a stale session when another command commits")
            }
        }
        // Feather direction: inside never grows the selection, outside never shrinks it.
        do {
            let W = 300, H = 200
            let base = SelectionOps.mask(fromPath: CGPath(ellipseIn: CGRect(x: 90, y: 50, width: 120, height: 100), transform: nil), width: W, height: H)
            func px(_ b: PixelBuffer, _ x: Int, _ y: Int) -> Int { Int(b.data.assumingMemoryBound(to: UInt8.self)[y * b.bytesPerRow + x]) }
            let inside = SelectionOps.feather(base, radius: 20, direction: .inside)
            let outside = SelectionOps.feather(base, radius: 20, direction: .outside)
            let centered = SelectionOps.feather(base, radius: 20, direction: .centered)
            var insideGrew = 0, outsideShrank = 0
            for y in 0..<H { for x in 0..<W {
                if px(inside, x, y) > px(base, x, y) + 2 { insideGrew += 1 }
                if px(outside, x, y) < px(base, x, y) - 2 { outsideShrank += 1 }
            } }
            check(insideGrew == 0, "feather inside stays within the selection", "\(insideGrew) px grew")
            check(outsideShrank == 0, "feather outside keeps the whole selection", "\(outsideShrank) px shrank")
            // just outside the edge (x=84): inside = 0, outside > 0, centered in between; just inside (x=97): inside < 255, outside = 255
            check(px(inside, 84, 100) == 0 && px(outside, 84, 100) > 60 && px(centered, 84, 100) > 0, "outside of edge: only outside/centered fade there",
                  "in \(px(inside, 84, 100)) out \(px(outside, 84, 100)) mid \(px(centered, 84, 100))")
            check(px(inside, 97, 100) < 200 && px(outside, 97, 100) >= 253, "inside of edge: only inside/centered fade there",
                  "in \(px(inside, 97, 100)) out \(px(outside, 97, 100)) mid \(px(centered, 97, 100))")
            check(px(inside, 150, 100) >= 253, "feather inside reaches full strength in the middle")
            for (n, m) in [("inside", inside), ("outside", outside), ("centered", centered)] {
                var st = DocumentState(width: W, height: H)
                st.layers = [Layer.raster(name: "m", buffer: RenderEngine.renderBuffer(m.ciImage, docRect: IRect(x: 0, y: 0, width: W, height: H), space: CanvasSpace(width: W, height: H)))]
                SelfTest.save(st, "regress_feather_\(n)", out)
            }
        }
        newFeatureTests(out)
        print("regress: \(failures) failed")
    }

    static func newFeatureTests(_ out: URL) {
        // Smart object: reset to original size keeps centre and rotation
        do {
            var st = SelfTest.baseState(600, 400)
            let src = PixelBuffer(width: 120, height: 80)
            src.context.setFillColor(RGBA(hex: "E94F37")!.cgColor); src.context.fill(CGRect(x: 0, y: 0, width: 120, height: 80)); src.markDirty()
            let so = SmartObjectContent(source: .image(src), quad: Quad(rect: CGRect(x: 100, y: 100, width: 120, height: 80)), sourceName: "src")
            var l = Layer(name: "SO", content: .smartObject(so))
            let sp = CanvasSpace(width: 600, height: 400)
            let c = CGPoint(x: 160, y: 140)
            let t = CGAffineTransform(translationX: -c.x, y: -c.y).concatenating(CGAffineTransform(scaleX: 2.5, y: 1.7))
                .concatenating(CGAffineTransform(rotationAngle: 0.5)).concatenating(CGAffineTransform(translationX: c.x + 80, y: c.y + 40))
            l = LayerTransformer.apply(Homography(affine: t), to: l, space: sp)
            st.layers.append(l)
            withDoc(st) { d in
                d.selectLayer(l.id)
                let before = AppActions.smartObjectScale(d.activeLayer!.smart!)
                let centre = d.activeLayer!.smart!.quad.center
                AppActions.resetSmartObject(keepRotation: true)
                let q = d.activeLayer!.smart!.quad
                let sc = AppActions.smartObjectScale(d.activeLayer!.smart!)
                let ang = atan2(q.tr.y - q.tl.y, q.tr.x - q.tl.x)
                check(abs(before.x - 2.5) < 0.01 && abs(sc.x - 1) < 0.001 && abs(sc.y - 1) < 0.001, "smart object reset → 100%", "was \(before), now \(sc)")
                check(q.center.distance(to: centre) < 0.5 && abs(ang - 0.5) < 0.001, "reset keeps centre and rotation")
                SelfTest.save(d.state, "regress_so_reset_100", out)
                AppActions.resetSmartObject(keepRotation: false)
                let q2 = d.activeLayer!.smart!.quad
                check(abs(q2.tr.y - q2.tl.y) < 0.001 && abs(q2.tl.distance(to: q2.tr) - 120) < 0.01, "Reset Transform removes rotation")
                d.undo(); d.undo()
                check(abs(AppActions.smartObjectScale(d.activeLayer!.smart!).x - 2.5) < 0.01, "reset is undoable")
            }
        }
        // Batch rename
        do {
            var st = SelfTest.baseState(300, 200)
            let names = ["Rectangle 1 copy", "Rectangle 1 copy 2", "logo", "Shape"]
            var ids: [UUID] = []
            for n in names { var l = SelfTest.shapeLayer(CGRect(x: 10, y: 10, width: 40, height: 40)); l.name = n; st.layers.append(l); ids.append(l.id) }
            withDoc(st) { d in
                d.selectedLayerIDs = Set(ids); d.activeLayerID = ids.last
                var s = BatchRenameSettings()
                s.template = "Icon {n}"; s.start = 1; s.padding = 2
                BatchRename.apply(s)
                let got = ids.reversed().map { d.state.layer($0)!.name }
                check(got == ["Icon 01", "Icon 02", "Icon 03", "Icon 04"], "batch rename: numbered template, top to bottom", "\(got)")
                d.undo()
                s = BatchRenameSettings(); s.mode = .replace; s.find = "Rectangle"; s.replace = "Card"; s.stripCopy = true
                let preview = BatchRename.names(for: BatchRename.targets(d, topToBottom: false), s)
                check(preview == ["Card 1", "Card 1", "logo", "Shape"], "batch rename: find & replace + remove copy", "\(preview)")
                s = BatchRenameSettings(); s.mode = .affix; s.prefix = "btn/"; s.suffix = "@{n}"; s.padding = 1
                check(BatchRename.names(for: BatchRename.targets(d, topToBottom: false), s).first == "btn/Rectangle 1 copy@1", "batch rename: prefix/suffix")
                check(BatchRename.letters(0, upper: true) == "A" && BatchRename.letters(27, upper: false) == "ab", "batch rename: letter tokens")
            }
        }
        // Arrange on shape
        do {
            var st = SelfTest.baseState(600, 600)
            var ids: [UUID] = []
            let colors = ["E94F37", "F6BD60", "3BB273", "2E86AB", "7768AE", "E15554", "4D9078", "F2C14E"]
            for (i, c) in colors.enumerated() {
                let l = SelfTest.shapeLayer(CGRect(x: 20 + i * 12, y: 20 + i * 9, width: 50, height: 36), RGBA(hex: c)!, radius: 6)
                st.layers.append(l); ids.append(l.id)
            }
            withDoc(st) { d in
                d.selectedLayerIDs = Set(ids); d.activeLayerID = ids.last
                var s = ArrangeOnShape.defaults(d)
                s.centerX = 300; s.centerY = 300; s.width = 400; s.height = 400
                for (name, shape, facing) in [("circle", ArrangeSettings.Shape.circle, ArrangeSettings.Facing.outward), ("square", .square, .upright),
                                              ("triangle", .triangle, .tangent), ("star", .star, .upright), ("spiral", .spiral, .tangent),
                                              ("heart", .custom, .upright), ("grid", .grid, .upright)] {
                    s.shape = shape; s.facing = facing; s.columns = 3
                    let arranged = ArrangeOnShape.arranged(s, base: st, ids: d.orderedSelection, doc: d)
                    SelfTest.save(arranged, "regress_arrange_\(name)", out)
                    if shape == .circle {
                        let centres = ids.map { id -> CGPoint in let b = Compositor.shared.contentBounds(arranged.layer(id)!, state: arranged)!; return CGPoint(x: b.midX, y: b.midY) }
                        let radii = centres.map { $0.distance(to: CGPoint(x: 300, y: 300)) }
                        let ok = radii.allSatisfy { abs($0 - 200) < 3 }
                        var angles = centres.map { atan2($0.y - 300, $0.x - 300) }.sorted()
                        angles.append(angles[0] + 2 * .pi)
                        let gaps = zip(angles.dropFirst(), angles).map { $0 - $1 }
                        check(ok && gaps.allSatisfy { abs($0 - 2 * .pi / 8) < 0.03 }, "arrange on circle: all on the circle, evenly spaced",
                              "radii \(radii.map { Int($0) })")
                        check(arranged.layers.count == st.layers.count && ids.allSatisfy { arranged.layer($0)?.isShape == true }, "arranged layers stay separate, editable shapes")
                    }
                }
            }
        }
        // ⌥-drag during a pending transform duplicates (instead of only moving the pending layer)
        do {
            var st = SelfTest.baseState(600, 400)
            let l = SelfTest.shapeLayer(CGRect(x: 100, y: 100, width: 120, height: 80))
            st.layers.append(l)
            withDoc(st) { d in
                let c = CanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
                c.document = d; d.zoom = 1; d.viewOffset = .zero
                let old = AppActions.canvas; AppActions.canvas = c; defer { AppActions.canvas = old }
                AppModel.shared.tool = .move
                d.selectLayer(l.id)
                guard let mt = c.tool(for: .move) as? MoveTool else { return }
                func ev(_ p: CGPoint, _ m: NSEvent.ModifierFlags = []) -> ToolEvent {
                    ToolEvent(doc: p, view: c.docToView(p), pressure: 1, modifiers: m, clickCount: 1, isTablet: false)
                }
                let count = d.state.allLayers.count
                // plain ⌥-drag
                mt.mouseDown(ev(CGPoint(x: 150, y: 140), .option)); mt.mouseDragged(ev(CGPoint(x: 350, y: 240), .option)); mt.mouseUp(ev(CGPoint(x: 350, y: 240), .option))
                check(d.state.allLayers.count == count + 1, "⌥-drag duplicates the layer", "\(d.state.allLayers.count) layers")
                let orig = Compositor.shared.contentBounds(d.state.layer(l.id)!, state: d.state)!
                check(abs(orig.minX - 100) < 3, "the original stays where it was", "\(orig.integral)")
                // ⌥-drag while a transform is pending
                d.selectLayer(l.id)
                mt.startTransform()
                if let s = mt.session { let o = s.quad.tl; s.quad = s.quad.mapped { CGPoint(x: o.x + ($0.x - o.x) * 1.5, y: o.y + ($0.y - o.y) * 1.5) }; s.updatePreview() }
                let n2 = d.state.allLayers.count
                mt.mouseDown(ev(CGPoint(x: 150, y: 140), .option)); mt.mouseDragged(ev(CGPoint(x: 150, y: 300), .option)); mt.mouseUp(ev(CGPoint(x: 150, y: 300), .option))
                check(d.state.allLayers.count == n2 + 1 && !mt.isBusy, "⌥-drag during a pending transform applies it and duplicates", "\(d.state.allLayers.count) vs \(n2)")
                let scaled = Compositor.shared.contentBounds(d.state.layer(l.id)!, state: d.state)!
                check(abs(scaled.width - 184) < 8, "the pending resize was kept", "\(scaled.integral)")
            }
        }
    }
}
