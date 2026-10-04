import AppKit
import SwiftUI
import ImageCratCore

/// Shapes and fill layers: Fill vs Opacity (with and without effects, blend modes, Blend Interior Effects as Group),
/// strokes that are never cropped (every shape kind × alignment, with and without vector masks, zoomed, transformed),
/// path operations and the shape × vector-mask routes, dash patterns (exact, aligned to corners, round dots, px units,
/// offset), stroke presets, the fill layer dialogs (live preview, OK / Cancel, undo, dragging, pending fields), PSD export
/// of dashes and Lumen files keeping everything. Snapshots of the stroke options and the dialogs go to <dir>/shapesfills.
/// `LUMEN_SELFTEST_ONLY=shapesfills Lumen --selftest <dir>`
enum ShapesFillsSelfTest {
    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") shapesfills: \(name)\(d.isEmpty ? "" : " — " + d)")
        fflush(stdout)
    }
    static func info(_ s: String) { print("INFO shapesfills: \(s)"); fflush(stdout) }

    static func run(_ out: URL) {
        passes = 0; failures = 0
        let dir = out.appendingPathComponent("shapesfills")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        outDir = dir
        let app = AppModel.shared
        let saved = (docs: app.documents, active: app.activeDocumentID, fg: app.foreground, bg: app.background, dialog: app.dialog,
                     tool: app.shapeTool, status: app.statusMessage, recents: app.recentColors)
        defer {
            FillLayerDialog.close()
            app.dialog = nil
            app.documents = saved.docs; app.activeDocumentID = saved.active
            app.foreground = saved.fg; app.background = saved.bg; app.shapeTool = saved.tool; app.statusMessage = saved.status
            app.recentColors = saved.recents
        }
        fillVersusOpacity()
        strokeCoverage(dir)
        strokeZoom(dir)
        pathOperations()
        dashes(dir)
        presets()
        fillRendering()
        fillDialogs(dir)
        fileFormats(dir)
        snapshots(dir)
        print("shapesfills: \(passes) passed, \(failures) failed")
    }

    // MARK: Helpers

    static func space(_ st: DocumentState) -> CanvasSpace { CanvasSpace(width: st.width, height: st.height) }

    static func flat(_ st: DocumentState, background: RGBA? = nil) -> PixelBuffer {
        PixelBuffer(cgImage: Compositor.shared.flatten(st, background: background)!)
    }

    /// One layer on transparency (content, effects, masks).
    static func appearance(_ l: Layer, _ st: DocumentState) -> PixelBuffer {
        let img = Compositor.shared.layerAppearance(l, state: st)
        return RenderEngine.renderBuffer(img, docRect: st.canvasRect, space: space(st))
    }

    static func shapeBuffer(_ s: ShapeContent, _ w: Int, _ h: Int) -> PixelBuffer {
        let sp = CanvasSpace(width: w, height: h)
        return RenderEngine.renderBuffer(ShapeRenderer.render(s, space: sp), docRect: IRect(x: 0, y: 0, width: w, height: h), space: sp)
    }

    static func maxDiff(_ a: PixelBuffer, _ b: PixelBuffer) -> Int {
        var m = 0
        for y in 0..<min(a.height, b.height) { for x in 0..<min(a.width, b.width) {
            let p = a.pixel(x, y), q = b.pixel(x, y)
            m = max(m, abs(Int(p.0) - Int(q.0)), abs(Int(p.1) - Int(q.1)), abs(Int(p.2) - Int(q.2)), abs(Int(p.3) - Int(q.3)))
        } }
        return m
    }

    static var outDir: URL?
    static func save(_ b: PixelBuffer, _ name: String) {
        guard let d = outDir else { return }
        try? NSBitmapImageRep(cgImage: b.makeCGImage()).representation(using: .png, properties: [:])?.write(to: d.appendingPathComponent(name + ".png"))
    }

    static func isRed(_ p: (UInt8, UInt8, UInt8, UInt8)) -> Bool { p.3 > 200 && p.0 > 200 && p.1 < 70 && p.2 < 70 }
    static func gray(_ v: Double) -> RGBA { RGBA(r: v, g: v, b: v) }
    static func solidBackground(_ w: Int, _ h: Int, _ c: RGBA) -> Layer {
        let b = PixelBuffer(width: w, height: h)
        b.context.setFillColor(c.cgColor); b.context.fill(CGRect(x: 0, y: 0, width: w, height: h)); b.markDirty()
        return Layer.raster(name: "Background", buffer: b)
    }
    static func activate(_ d: Document) {
        let app = AppModel.shared
        if !app.documents.contains(where: { $0.id == d.id }) { app.documents.append(d) }
        app.activeDocumentID = d.id
    }
    static func close(_ d: Document) {
        let app = AppModel.shared
        app.documents.removeAll { $0.id == d.id }
        if app.activeDocumentID == d.id { app.activeDocumentID = app.documents.last?.id }
    }

    // MARK: Fill vs Opacity

    static func fillVersusOpacity() {
        let W = 200, H = 150
        let rect = CGRect(x: 50, y: 40, width: 100, height: 70)
        func doc(_ edit: (inout Layer) -> Void) -> DocumentState {
            var st = DocumentState(width: W, height: H)
            var l = Layer(name: "Shape", content: .shape(ShapeContent(geometry: .rectangle(rect, cornerRadius: 0), fill: .color(RGBA(hex: "2060E0")!))))
            edit(&l)
            st.layers = [solidBackground(W, H, gray(0.5)), l]
            return st
        }
        // no effects: Fill and Opacity look the same (normal and multiply)
        for mode in [BlendMode.normal, .multiply, .screen] {
            let a = flat(doc { $0.fillOpacity = 0.4; $0.blendMode = mode }), b = flat(doc { $0.opacity = 0.4; $0.blendMode = mode })
            check(maxDiff(a, b) <= 1, "no effects, \(mode.displayName): Fill 40 % looks like Opacity 40 %", "max diff \(maxDiff(a, b))")
        }
        // a pattern fill layer (the bricks of 02_fill_layers): the same
        func pat(_ edit: (inout Layer) -> Void) -> DocumentState {
            var st = DocumentState(width: W, height: H)
            var l = Layer(name: "Pattern Fill", content: .fill(FillContent(paint: .pattern(id: "bricks", scale: 0.5))))
            l.mask = PSDExportSamples.ellipseMask(W, H, CGRect(x: 30, y: 20, width: 140, height: 110))
            edit(&l)
            st.layers = [solidBackground(W, H, gray(0.7)), l]
            return st
        }
        check(maxDiff(flat(pat { $0.fillOpacity = 0.5 }), flat(pat { $0.opacity = 0.5 })) <= 1, "pattern fill layer without effects: Fill and Opacity look the same (expected, as in Photoshop)")
        // with an outside Stroke effect: Fill leaves the effect, Opacity fades it
        func stroked(_ edit: (inout Layer) -> Void) -> DocumentState {
            doc { l in
                l.effects.stroke.enabled = true; l.effects.stroke.size = 8; l.effects.stroke.position = .outside; l.effects.stroke.paint = .color(RGBA(r: 1, g: 0, b: 0))
                edit(&l)
            }
        }
        let f0 = flat(stroked { $0.fillOpacity = 0 })
        check(isRed(f0.pixel(45, 75)), "Fill 0 %: the Stroke effect stays at full strength", "\(f0.pixel(45, 75))")
        let inside = f0.pixel(100, 75)
        check(abs(Int(inside.0) - 128) <= 2 && abs(Int(inside.2) - 128) <= 2, "Fill 0 %: the shape's own pixels are gone (backdrop shows)", "\(inside)")
        let o5 = flat(stroked { $0.opacity = 0.5 })
        let ring = o5.pixel(45, 75)
        check(abs(Int(ring.0) - 191) <= 4 && abs(Int(ring.1) - 64) <= 4, "Opacity 50 %: the Stroke effect fades too", "\(ring)")
        let f5 = flat(stroked { $0.fillOpacity = 0.5 })
        check(isRed(f5.pixel(45, 75)) && abs(Int(f5.pixel(100, 75).2) - Int((128.0 + 224) / 2)) <= 4, "Fill 50 %: content half, effect whole", "\(f5.pixel(100, 75))")
        // interior effects: Color Overlay with and without Blend Interior Effects as Group
        func overlay(_ group: Bool, _ fill: Double) -> PixelBuffer {
            flat(doc { l in
                l.effects.colorOverlay.enabled = true; l.effects.colorOverlay.color = RGBA(r: 0, g: 1, b: 0)
                l.blendInteriorEffectsAsGroup = group; l.fillOpacity = fill
            })
        }
        let g0 = overlay(false, 0).pixel(100, 75)
        check(g0.1 > 240 && g0.0 < 20, "Color Overlay, Fill 0 %: the overlay still shows (Blend Interior Effects as Group off)", "\(g0)")
        let g1 = overlay(true, 0).pixel(100, 75)
        check(abs(Int(g1.0) - 128) <= 2 && abs(Int(g1.1) - 128) <= 2, "Color Overlay, Fill 0 % with Blend Interior Effects as Group: Fill fades the overlay too", "\(g1)")
        let g2 = overlay(true, 0.5).pixel(100, 75)
        check(abs(Int(g2.1) - 191) <= 4 && abs(Int(g2.0) - 64) <= 4, "Blend Interior Effects as Group, Fill 50 %: overlay and content fade together", "\(g2)")
        let g3 = overlay(false, 0.5).pixel(100, 75)
        check(g3.1 > 240 && g3.0 < 20, "without the group option the overlay ignores Fill", "\(g3)")
    }

    // MARK: Strokes are never cropped

    /// Independent reference: the shape filled and its stroked outline filled (clipped for inside / outside), unbounded.
    static func reference(_ s: ShapeContent, _ w: Int, _ h: Int, clip: CGRect? = nil) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        let c = b.context
        c.saveGState()
        if let r = clip { c.clip(to: r) }
        let (path, eo) = s.path.resolved
        if case .color(let f) = s.fill {
            c.addPath(path); c.setFillColor(f.cgColor)
            if eo { c.fillPath(using: .evenOdd) } else { c.fillPath() }
        }
        if case .color(let sc) = s.stroke.paint, s.stroke.width > 0 {
            let w = CGFloat(s.stroke.width)
            let outline = path.copy(strokingWithWidth: s.stroke.alignment == .center ? w : w * 2, lineCap: s.stroke.cap.cg, lineJoin: s.stroke.join.cg,
                                    miterLimit: CGFloat(s.stroke.miterLimit ?? 10))
            c.saveGState()
            switch s.stroke.alignment {
            case .center: break
            case .inside: c.addPath(path); if eo { c.clip(using: .evenOdd) } else { c.clip() }
            case .outside: c.addRect(CGRect(x: -20000, y: -20000, width: 40000, height: 40000)); c.addPath(path); c.clip(using: .evenOdd)
            }
            c.addPath(outline); c.setFillColor(sc.cgColor); c.fillPath()
            c.restoreGState()
        }
        c.restoreGState()
        b.markDirty()
        return b
    }

    struct Coverage { var missing = 0, extra = 0, wrongColor = 0, strokePixels = 0 }
    static func compare(_ got: PixelBuffer, _ ref: PixelBuffer) -> Coverage {
        var c = Coverage()
        for y in 0..<ref.height { for x in 0..<ref.width {
            let r = ref.pixel(x, y), g = got.pixel(x, y)
            if r.3 >= 250 && g.3 < 128 { c.missing += 1 }
            if r.3 <= 4 && g.3 > 128 { c.extra += 1 }
            if r.3 >= 250 && r.0 > 250 && r.2 < 5 {
                c.strokePixels += 1
                // a fully covered stroke pixel whose neighbours are stroke too must be the stroke colour
                let n = [ref.pixel(x - 1, y), ref.pixel(x + 1, y), ref.pixel(x, y - 1), ref.pixel(x, y + 1)]
                if n.allSatisfy({ $0.3 >= 250 && $0.0 > 250 && $0.2 < 5 }) && !isRed(g) { c.wrongColor += 1 }
            }
        } }
        return c
    }

    static let W = 320, H = 260

    static func shapeCases() -> [(String, ShapeGeometry, CGAffineTransform)] {
        let zig = VectorPath(subpaths: [Subpath(points: [PathPoint(CGPoint(x: 50, y: 200)), PathPoint(CGPoint(x: 110, y: 60)),
                                                         PathPoint(CGPoint(x: 170, y: 200)), PathPoint(CGPoint(x: 250, y: 70))], closed: false)])
        let starR = CGRect(x: 75, y: 45, width: 170, height: 170)
        func about(_ r: CGRect, _ t: CGAffineTransform) -> CGAffineTransform {
            CGAffineTransform(translationX: -r.midX, y: -r.midY).concatenating(t).concatenating(CGAffineTransform(translationX: r.midX, y: r.midY))
        }
        let ell = CGRect(x: 80, y: 70, width: 160, height: 110)
        return [
            ("rectangle", .rectangle(CGRect(x: 80, y: 70, width: 150, height: 100), cornerRadius: 0), .identity),
            ("rounded rectangle", .rectangle(CGRect(x: 80, y: 70, width: 150, height: 100), cornerRadius: 26), .identity),
            ("ellipse", .ellipse(ell), .identity),
            ("triangle", .polygon(CGRect(x: 90, y: 50, width: 140, height: 150), sides: 3, starRatio: 1), .identity),
            ("star", .polygon(starR, sides: 5, starRatio: 0.45), .identity),
            ("line", .line(CGPoint(x: 70, y: 200), CGPoint(x: 250, y: 90), weight: 8), .identity),
            ("custom shape (heart)", .library("heart", CGRect(x: 90, y: 60, width: 140, height: 130)), .identity),
            ("open path", .path(zig), .identity),
            ("rotated, scaled star", .polygon(starR, sides: 5, starRatio: 0.45), about(starR, CGAffineTransform(rotationAngle: 0.5).scaledBy(x: 0.9, y: 0.8))),
            ("skewed ellipse", .ellipse(ell), about(ell, CGAffineTransform(a: 1.1, b: 0.15, c: 0.35, d: 0.9, tx: 0, ty: 0))),
        ]
    }

    static func strokeCoverage(_ dir: URL) {
        var st = DocumentState(width: W, height: H)
        var worst = Coverage()
        var savedOne = false
        for (name, g, t) in shapeCases() {
            for align in StrokeAlignment.allCases {
                for masked in [0, 1, 2] {
                    var s = ShapeContent(geometry: g, fill: .color(RGBA(hex: "2060E0")!))
                    s.transform = t
                    s.stroke = StrokeStyle(paint: .color(RGBA(r: 1, g: 0, b: 0)), width: 14, alignment: align)
                    var l = Layer(name: name, content: .shape(s))
                    var clip: CGRect? = nil
                    let pb = s.path.bounds
                    switch masked {
                    case 1:   // a straight cut through the middle, everything else uncovered
                        clip = CGRect(x: -1000, y: -1000, width: 3000, height: 1000 + pb.midY)
                    case 2:   // the user's case: the mask is the top part of the shape's own box
                        clip = CGRect(x: pb.minX, y: pb.minY, width: pb.width, height: pb.height * 0.55)
                    default: break
                    }
                    if let c = clip { l.vectorMask = VectorPath.rect(c) }
                    st.layers = [l]
                    let got = appearance(l, st)
                    let ref = reference(s, W, H, clip: clip)
                    let c = compare(got, ref)
                    let what = "\(name), \(align.rawValue) stroke\(masked == 0 ? "" : masked == 1 ? ", cut by a vector mask" : ", vector mask on the shape's box")"
                    // (an outside stroke of a rectangle masked to its own box is hidden entirely — nothing to see, nothing missing)
                    check(c.missing == 0 && c.extra <= 2 && c.wrongColor == 0 && (c.strokePixels > 50 || masked == 2), "stroke not cropped: \(what)",
                          "missing \(c.missing), extra \(c.extra), wrong colour \(c.wrongColor), stroke px \(c.strokePixels)")
                    worst.missing = max(worst.missing, c.missing)
                    if (c.missing > 0 || !savedOne) && name == "ellipse" && masked == 2 && align == .outside {
                        savedOne = true
                        if let cg = got.makeCGImage() as CGImage? { try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("ellipse_outside_stroke_box_mask.png")) }
                    }
                }
            }
        }
        // the cropping bug: miter joins reach well beyond path ± (width + 2) — the old rasterization box
        var star = ShapeContent(geometry: .polygon(CGRect(x: 75, y: 45, width: 170, height: 170), sides: 5, starRatio: 0.45), fill: .none)
        star.stroke = StrokeStyle(paint: .color(RGBA(r: 1, g: 0, b: 0)), width: 14, alignment: .outside)
        let old = star.path.bounds.insetBy(dx: -16, dy: -16)
        let ref = reference(star, W, H)
        var beyond = 0, beyondGot = 0
        let got = shapeBuffer(star, W, H)
        for y in 0..<H { for x in 0..<W where !old.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) && ref.pixel(x, y).3 > 250 {
            beyond += 1
            if got.pixel(x, y).3 > 128 { beyondGot += 1 }
        } }
        check(beyond > 20 && beyondGot == beyond, "star, outside stroke: the miter tips past the old raster box are drawn", "\(beyondGot) of \(beyond) px")
        check(ShapeRenderer.visualBounds(star).contains(StrokeGeometry.strokeBounds(star)), "visual bounds include the miter tips (transform box, rasterize)")
        // a stroke after a transform: still uncropped (the layer moved and scaled)
        var l = Layer(name: "moved", content: .shape(star))
        l.translate(dx: 23, dy: -9)
        if var sh = l.shape { sh.transform = sh.transform.concatenating(CGAffineTransform(translationX: -160, y: -130).scaledBy(x: 1.15, y: 1.15).translatedBy(x: 0, y: 0).concatenating(CGAffineTransform(translationX: 160, y: 130))); l.shape = sh }
        st.layers = [l]
        let c2 = compare(appearance(l, st), reference(l.shape!, W, H))
        check(c2.missing == 0 && c2.extra <= 2, "moved and scaled star: stroke still complete", "missing \(c2.missing)")
        // dashed strokes (exact and aligned) are inside the raster area too
        for align in StrokeAlignment.allCases {
            var d = star
            d.stroke.alignment = align; d.stroke.dash = [3, 1.5]; d.stroke.dashAlignment = .corners
            let r = IRect(enclosing: ShapeRenderer.rasterBounds(d))
            let b = StrokeGeometry.strokeBounds(d)
            check(r.cgRect.contains(b.insetBy(dx: 0.5, dy: 0.5)), "dashed star (\(align.rawValue)): raster area covers the whole stroke", "\(r.cgRect) ⊇ \(b)")
        }
    }

    /// The same strokes shown on the canvas at several zoom levels (the display path, not just the composite).
    static func strokeZoom(_ dir: URL) {
        var s = ShapeContent(geometry: .polygon(CGRect(x: 75, y: 45, width: 170, height: 170), sides: 5, starRatio: 0.45), fill: .color(RGBA(hex: "2060E0")!))
        s.stroke = StrokeStyle(paint: .color(RGBA(r: 1, g: 0, b: 0)), width: 14, alignment: .outside)
        var e = ShapeContent(geometry: .ellipse(CGRect(x: 20, y: 150, width: 120, height: 100)), fill: .color(RGBA(hex: "F2B33D")!))
        e.stroke = StrokeStyle(paint: .color(RGBA(r: 1, g: 0, b: 0)), width: 10, alignment: .center)
        var el = Layer(name: "Ellipse", content: .shape(e))
        el.vectorMask = VectorPath.rect(CGRect(x: 0, y: 0, width: 320, height: 210))
        var st = DocumentState(width: W, height: H)
        st.layers = [Layer(name: "Star", content: .shape(s)), el]
        let d = Document(state: st, name: "zoom")
        // reference: the doc composite
        let ref = flat(st)
        for z in [0.5, 1.0, 2.5] {
            let size = CGSize(width: CGFloat(W) * z + 20, height: CGFloat(H) * z + 20)
            d.zoom = z
            let t = CGAffineTransform(a: z, b: 0, c: 0, d: z, tx: 10, ty: 10)
            let img = CanvasRenderer.frame(d, docToView: t, viewHeight: size.height, scale: 1, size: size)
            guard let cg = RenderEngine.cgImage(img, rect: CGRect(origin: .zero, size: size)) else { check(false, "canvas frame renders at \(z)"); continue }
            let view = PixelBuffer(cgImage: cg)
            var total = 0, ok = 0
            for y in stride(from: 1, to: H - 1, by: 2) { for x in stride(from: 1, to: W - 1, by: 2) {
                // well inside the stroke in the document: every neighbour red
                var solid = true
                for dy in -1...1 { for dx in -1...1 where !isRed(ref.pixel(x + dx, y + dy)) { solid = false } }
                guard solid else { continue }
                total += 1
                let vx = Int((10 + (Double(x) + 0.5) * z).rounded(.down)), vy = Int((10 + (Double(y) + 0.5) * z).rounded(.down))
                if isRed(view.pixel(vx, vy)) || (z < 1 && view.pixel(vx, vy).0 > 180 && view.pixel(vx, vy).2 < 110) { ok += 1 }
            } }
            check(total > 100 && Double(ok) >= Double(total) * 0.97, "canvas at \(Int(z * 100)) %: strokes shown whole (miter tips, masked ellipse)", "\(ok) of \(total) samples")
            if z == 2.5 { try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("canvas_zoom_250.png")) }
        }
    }

    // MARK: Path operations and the vector mask routes

    static func pathOperations() {
        let a = VectorPath.rect(CGRect(x: 40, y: 40, width: 100, height: 80))
        let b = VectorPath.rect(CGRect(x: 100, y: 60, width: 100, height: 80))
        let pts = [("only A", CGPoint(x: 60, y: 60)), ("overlap", CGPoint(x: 120, y: 90)), ("only B", CGPoint(x: 180, y: 120))]
        let expect: [PathOperation: [Bool]] = [.combine: [true, true, true], .subtract: [true, false, false], .intersect: [false, true, false], .exclude: [true, false, true]]
        for op in PathOperation.allCases {
            let p = VectorPath(subpaths: a.subpaths + b.withOperation(op).subpaths)
            let buf = shapeBuffer(ShapeContent(geometry: .path(p), fill: .color(.black)), 240, 180)
            let got = pts.map { buf.pixel(Int($0.1.x), Int($0.1.y)).3 > 128 }
            check(got == expect[op]!, "path operation \(PathOperationMenu.name(op))", "\(zip(pts.map(\.0), got).map { "\($0): \($1)" }.joined(separator: ", "))")
            let merged = PathBoolean.merged(p)
            let mb = shapeBuffer(ShapeContent(geometry: .path(merged), fill: .color(.black)), 240, 180)
            check(merged.subpaths.allSatisfy { $0.operation == .combine } && pts.map({ mb.pixel(Int($0.1.x), Int($0.1.y)).3 > 128 }) == expect[op]!,
                  "Merge Shape Components keeps the \(PathOperationMenu.name(op)) result as plain outlines")
        }
        // the stroke follows the combined outline: subtracting B strokes along the cut
        var s = ShapeContent(geometry: .path(VectorPath(subpaths: a.subpaths + b.withOperation(.subtract).subpaths)), fill: .color(.black))
        s.stroke = StrokeStyle(paint: .color(RGBA(r: 1, g: 0, b: 0)), width: 6, alignment: .center)
        let sb = shapeBuffer(s, 240, 180)
        check(isRed(sb.pixel(100, 90)) && isRed(sb.pixel(120, 60)), "the stroke runs along the edges a path operation cuts", "\(sb.pixel(100, 90)) \(sb.pixel(120, 60))")

        // commands on the active document: component operation, intersect with the vector mask, Stroke effect route
        let W = 240, H = 240
        var st = DocumentState(width: W, height: H)
        var ell = ShapeContent(geometry: .ellipse(CGRect(x: 60, y: 40, width: 120, height: 160)), fill: .color(RGBA(hex: "F2B33D")!))
        ell.stroke = StrokeStyle(paint: .color(RGBA(r: 1, g: 0, b: 0)), width: 12, alignment: .outside)
        var el = Layer(name: "Ellipse with vector mask", content: .shape(ell))
        el.vectorMask = VectorPath.rect(CGRect(x: 60, y: 40, width: 120, height: 80))   // the box's top half, as in 03_shapes_and_vector_masks
        var two = Layer(name: "Two", content: .shape(ShapeContent(geometry: .path(VectorPath(subpaths: a.subpaths + b.subpaths)), fill: .color(.black))))
        two.isVisible = false
        st.layers = [two, el]
        let d = Document(state: st, name: "pathops")
        activate(d)
        defer { close(d) }
        d.selectLayer(two.id)
        VectorEditing.setComponentOperation(.intersect)
        check(d.state.layer(two.id)?.shape?.path.subpaths.last?.operation == .intersect && d.history.last?.name == "Path Operation",
              "Path Operations (options bar / Properties) set the component's operation as one history step", d.history.last?.name ?? "")
        VectorEditing.mergeComponents()
        check(d.state.layer(two.id)?.shape?.path.subpaths.allSatisfy { $0.operation == .combine } == true, "Merge Shape Components on the active shape")
        d.selectLayer(el.id)
        // before: a box-sized vector mask hides the outside stroke at the top and sides as well (as in Photoshop)
        let before = appearance(d.state.layer(el.id)!, d.state)
        check(before.pixel(120, 36).3 < 30 && before.pixel(120, 125).3 < 30, "vector mask the size of the shape's box: it also clips the stroke above and below (Photoshop does the same)",
              "\(before.pixel(120, 36)) \(before.pixel(120, 125))")
        let hist = d.history.count
        ShapeMaskOps.intersectWithVectorMask(d, el.id)
        let after = d.state.layer(el.id)!
        let ab = appearance(after, d.state)
        check(after.vectorMask == nil && d.history.count == hist + 1, "Intersect Shape with Vector Mask: one step, the mask becomes part of the shape")
        check(isRed(ab.pixel(120, 125)) && isRed(ab.pixel(54, 100)) && isRed(ab.pixel(120, 35)), "…and the stroke now runs round the cut edge, the sides and the top",
              "below cut \(ab.pixel(120, 125)), side \(ab.pixel(54, 100)), top \(ab.pixel(120, 35))")
        check(ab.pixel(120, 140).3 < 30, "…while nothing of the lower half comes back", "\(ab.pixel(120, 140))")
        d.undo()
        check(d.state.layer(el.id)?.vectorMask != nil, "undo brings the vector mask back")
        // the Stroke effect goes round the masked result
        d.updateLayer(el.id) { l in
            l.shape?.stroke.paint = .none
            l.effects.stroke.enabled = true; l.effects.stroke.size = 6; l.effects.stroke.position = .outside; l.effects.stroke.paint = .color(RGBA(r: 1, g: 0, b: 0))
        }
        let fx = appearance(d.state.layer(el.id)!, d.state)
        check(isRed(fx.pixel(120, 122)) && isRed(fx.pixel(57, 100)), "a Stroke layer effect outlines the masked shape (cut edge included)", "\(fx.pixel(120, 122)) \(fx.pixel(57, 100))")
        d.revertUncommitted()
        // the menu command is registered
        check(MenuRegistry.items(for: "Layer").contains { $0.title == "Intersect Shape with Vector Mask" }, "Layer ▸ Intersect Shape with Vector Mask is in the menu")
    }

    // MARK: Dashes

    static func dashes(_ dir: URL) {
        let red = PaintStyle.color(RGBA(r: 1, g: 0, b: 0))
        func line(_ a: CGPoint, _ b: CGPoint) -> ShapeGeometry { .path(VectorPath(subpaths: [Subpath(points: [PathPoint(a), PathPoint(b)], closed: false)])) }
        func a(_ b: PixelBuffer, _ x: Int, _ y: Int) -> Int { Int(b.pixel(x, y).3) }

        check(StrokeGeometry.dashLengths(StrokeStyle(paint: red, width: 2, dash: [3, 1, 1])) == [6, 2, 2, 6, 2, 2], "an odd dash list repeats (as in Core Graphics, SVG, PDF)")
        check(StrokeGeometry.dashLengths(StrokeStyle(paint: red, width: 2, dash: [0, 0])) == nil, "a dash list of zero length is a solid stroke")

        // exact dashes and the offset
        var s = ShapeContent(geometry: line(CGPoint(x: 20, y: 50), CGPoint(x: 220, y: 50)), fill: .none)
        s.stroke = StrokeStyle(paint: red, width: 4, dash: [4, 2])
        var b = shapeBuffer(s, 240, 100)
        check(a(b, 28, 50) > 200 && a(b, 40, 50) < 20 && a(b, 52, 50) > 200, "dash 4 / gap 2 (× width 4): 16 px dashes, 8 px gaps", "\(a(b, 28, 50)) \(a(b, 40, 50)) \(a(b, 52, 50))")
        s.stroke.dashPhase = 2
        b = shapeBuffer(s, 240, 100)
        check(a(b, 32, 50) < 20 && a(b, 44, 50) > 200, "dash offset 2 shifts the pattern by 8 px", "\(a(b, 32, 50)) \(a(b, 44, 50))")
        // any number of pairs
        s.stroke.dashPhase = nil
        s.stroke.setDashPairs([(4, 1), (1, 1), (0.5, 3)])
        check(s.stroke.dash == [4, 1, 1, 1, 0.5, 3] && s.stroke.dashPairs.count == 3, "three dash / gap pairs (and more) are kept")
        s.stroke.setDashPairs([(4, 1), (1, 1), (0.5, 3), (2, 2), (1, 0.5)])
        check(s.stroke.dashPairs.count == 5, "five pairs: no limit of three")
        // px units keep their pixel length when the width changes
        var px = StrokeStyle(paint: red, width: 4, dash: [4, 2]); px.dashUnit = .pixels
        px.setWidth(8)
        check(px.dash == [2, 1] && px.width == 8, "dashes in px keep 16 px / 8 px when the width doubles", "\(px.dash)")
        var wu = StrokeStyle(paint: red, width: 4, dash: [4, 2]); wu.setWidth(8)
        check(wu.dash == [4, 2], "dashes in stroke widths scale with the width")

        // round dots: zero-length dashes with round caps
        var dots = ShapeContent(geometry: line(CGPoint(x: 20, y: 60), CGPoint(x: 220, y: 60)), fill: .none)
        dots.stroke = StrokeStyle(paint: red, width: 10, cap: .round, dash: [0, 2])
        b = shapeBuffer(dots, 240, 120)
        check(a(b, 40, 60) > 240 && a(b, 40, 56) > 200 && a(b, 44, 60) > 200 && a(b, 43, 63) > 100, "dash 0 + round caps: a round dot of the stroke width", "\(a(b, 40, 60)) \(a(b, 40, 56)) \(a(b, 44, 60))")
        check(a(b, 44, 64) < 90 && a(b, 50, 60) < 10, "…round, not square, and apart", "corner \(a(b, 44, 64)) between \(a(b, 50, 60))")
        dots.stroke.cap = .square
        b = shapeBuffer(dots, 240, 120)
        check(a(b, 44, 64) > 200, "the same with square caps: squares")

        // dots on an inside-aligned stroke are whole discs along a contour half a width inside (not half dots)
        var ins = ShapeContent(geometry: .rectangle(CGRect(x: 40, y: 40, width: 160, height: 100), cornerRadius: 0), fill: .none)
        ins.stroke = StrokeStyle(paint: red, width: 10, alignment: .inside, cap: .round, dash: [0, 3])
        b = shapeBuffer(ins, 240, 180)
        save(b, "dots_inside")
        // the centre of the first dot along the top edge, right of x = 60
        func dotCentre(_ b: PixelBuffer, _ y: Int) -> Int {
            var x = 60
            while x < 200 && a(b, x, y) > 128 { x += 1 }   // leave a dot we may have started in
            while x < 200 && a(b, x, y) <= 128 { x += 1 }
            let x0 = x
            while x < 220 && a(b, x, y) > 128 { x += 1 }
            return (x0 + x - 1) / 2
        }
        var cx = dotCentre(b, 45)
        check(cx > 0 && a(b, cx, 41) > 150 && a(b, cx, 49) > 150 && a(b, cx, 38) < 10, "inside dotted: the dots sit inside the shape", "centre x \(cx)")
        check(cx > 0 && a(b, cx - 7, 45) < 40 && a(b, cx + 7, 45) < 40, "inside dotted: each dot is a disc one stroke width across (not a clipped double-width dot)", "\(a(b, cx - 7, 45)) \(a(b, cx + 7, 45))")
        var outs = ins
        outs.stroke.alignment = .outside
        b = shapeBuffer(outs, 240, 180)
        save(b, "dots_outside")
        cx = dotCentre(b, 35)
        check(cx > 0 && a(b, cx, 31) > 150 && a(b, cx, 39) > 150 && a(b, cx, 42) < 10 && a(b, cx - 7, 35) < 40, "outside dotted: whole dots just outside the shape", "centre x \(cx)")

        // dashes aligned to corners
        var rect = ShapeContent(geometry: .rectangle(CGRect(x: 40, y: 40, width: 200, height: 100), cornerRadius: 0), fill: .none)
        rect.stroke = StrokeStyle(paint: red, width: 4, dash: [4, 2])
        let corners = [(40, 40), (239, 40), (239, 139), (40, 139)]
        b = shapeBuffer(rect, 280, 180)
        let exactCovered = corners.filter { a(b, $0.0, $0.1) > 150 }.count
        rect.stroke.dashAlignment = .corners
        let ab = shapeBuffer(rect, 280, 180)
        let alignedCovered = corners.filter { a(ab, $0.0, $0.1) > 150 }.count
        check(exactCovered < 4 && alignedCovered == 4, "align to corners: every corner gets a dash (exact dashes leave \(4 - exactCovered) corner(s) bare)", "\(alignedCovered) of 4")
        var asym = 0
        for dx in 3...97 where abs(a(ab, 40 + dx, 40) - a(ab, 239 - dx, 40)) > 60 { asym += 1 }
        check(asym == 0, "align to corners: the dashes along an edge are symmetric", "\(asym) mismatches")
        // the arms of a corner dash are half dashes, together one dash bent round the corner
        var arm = 0
        while a(ab, 40 + arm, 40) > 128 && arm < 40 { arm += 1 }
        check(arm >= 6 && arm <= 11, "align to corners: half a dash (≈ 8 px) on each side of a corner", "\(arm) px")
        // open path: whole dashes at both ends
        var open = ShapeContent(geometry: line(CGPoint(x: 20, y: 160), CGPoint(x: 220, y: 160)), fill: .none)
        open.stroke = StrokeStyle(paint: red, width: 4, dash: [4, 2]); open.stroke.dashAlignment = .corners
        b = shapeBuffer(open, 240, 180)
        var run = 0
        while a(b, 20 + run, 160) > 128 && run < 40 { run += 1 }
        check(a(b, 20, 160) > 128 && a(b, 219, 160) > 128 && run >= 13 && run <= 19, "align to path ends: an open path starts and ends with a whole dash", "first dash \(run) px")
        // a closed curve: equal dashes all round, no short piece at the seam
        if let dp = StrokeGeometry.alignedDashes(VectorPath.ellipse(CGRect(x: 20, y: 20, width: 190, height: 120)).cgPath, lengths: [16, 8]) {
            let lens = StrokeGeometry.subpaths(dp).map(\.total)
            let mn = lens.min() ?? 0, mx = lens.max() ?? 1
            check(lens.count > 10 && mn / mx > 0.97, "align to corners on an ellipse: \(lens.count) equal dashes, no stub at the seam", String(format: "%.2f…%.2f", mn, mx))
        } else { check(false, "aligned dashes on an ellipse") }
        // star tips each get a dash
        var star = ShapeContent(geometry: .polygon(CGRect(x: 30, y: 20, width: 200, height: 200), sides: 5, starRatio: 0.5), fill: .none)
        star.stroke = StrokeStyle(paint: red, width: 4, join: .round, dash: [2, 2]); star.stroke.dashAlignment = .corners
        b = shapeBuffer(star, 260, 240)
        let tips = VectorPath.polygon(in: CGRect(x: 30, y: 20, width: 200, height: 200), sides: 5, starRatio: 0.5).subpaths[0].points.map(\.anchor)
        let tipHits = tips.filter { p in
            (-1...1).contains { dy in (-1...1).contains { dx in a(b, Int(p.x) + dx, Int(p.y) + dy) > 150 } }
        }.count
        check(tipHits == tips.count, "align to corners on a star: all \(tips.count) corners carry a dash", "\(tipHits)")
        // round dots aligned to corners: a dot on each corner
        var dotRect = rect
        dotRect.stroke = StrokeStyle(paint: red, width: 6, cap: .round, dash: [0, 2.5]); dotRect.stroke.dashAlignment = .corners
        b = shapeBuffer(dotRect, 280, 180)
        check(corners.allSatisfy { a(b, $0.0, $0.1) > 150 }, "round dots aligned to corners: a dot on every corner")
    }

    // MARK: Presets

    static func presets() {
        let defaultsBefore = UserDefaults.standard.data(forKey: StrokePresetStore.defaultsKey)
        let store = StrokePresetStore(persists: false)
        check(StrokePresetStore.automated && !StrokePresetStore.shared.persists, "self tests never write stroke presets to the user defaults")
        let dotted = StrokePresetStore.builtIn.first { $0.name == "Dotted" }
        check(dotted?.dash == [0, 2] && dotted?.cap == .round, "built-in Dotted preset: zero-length dashes with round caps (true dots)")
        check(["Solid", "Dashed", "Dotted"].allSatisfy { n in StrokePresetStore.builtIn.contains { $0.name == n } }, "Photoshop's Solid / Dashed / Dotted presets are there")
        var s = StrokeStyle(paint: .color(.black), width: 5, alignment: .outside, cap: .round, join: .bevel, dash: [3, 1, 0, 1])
        s.dashAlignment = .corners; s.miterLimit = 4; s.dashPhase = 0.5
        let p = store.save(name: "My Morse", from: s)
        check(store.all.contains { $0.id == p.id } && store.saved.count == 1, "Save adds a preset")
        let reloaded = StrokePresetStore(persists: false, data: store.encoded)
        check(reloaded.saved == store.saved, "saved presets load back")
        var t = StrokeStyle(paint: .color(RGBA(r: 1, g: 0, b: 0)), width: 9)
        reloaded.saved[0].apply(to: &t)
        check(t.dash == s.dash && t.cap == .round && t.join == .bevel && t.alignment == .outside && t.dashAlignment == .corners && t.miterLimit == 4 && t.dashPhase == 0.5,
              "applying a preset sets alignment, caps, corners, dashes, offset and alignment of dashes")
        check(t.width == 9 && t.paint == .color(RGBA(r: 1, g: 0, b: 0)), "…and keeps the stroke's colour and width")
        check(reloaded.saved[0].matches(t), "the applied preset is recognised as the current one")
        store.delete(p.id)
        check(store.saved.isEmpty, "Delete removes a saved preset")
        check(UserDefaults.standard.data(forKey: StrokePresetStore.defaultsKey) == defaultsBefore, "user defaults untouched")
        // the shape tools use the options-bar stroke options for new shapes
        let app = AppModel.shared
        var st = DocumentState(width: 100, height: 100)
        st.layers = [solidBackground(100, 100, .white)]
        let d = Document(state: st, name: "tool")
        activate(d)
        defer { close(d) }
        app.shapeTool.stroke = .color(.black); app.shapeTool.strokeWidth = 4
        var o = StrokeStyle(); o.dash = [0, 2]; o.cap = .round; o.dashAlignment = .corners
        app.shapeTool.strokeOptions = o
        let id = VectorEditing.newShapeLayer(d, geometry: .ellipse(CGRect(x: 10, y: 10, width: 60, height: 60)), name: "Ellipse")
        let ns = d.state.layer(id)?.shape?.stroke
        check(ns?.dash == [0, 2] && ns?.cap == .round && ns?.dashAlignment == .corners && ns?.width == 4, "new shapes get the options bar's Stroke Options")
    }

    // MARK: Fill layer rendering

    static func fillRendering() {
        let W = 200, H = 100
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        let sp = CanvasSpace(width: W, height: H)
        func render(_ f: FillContent, _ l: Layer? = nil) -> PixelBuffer {
            let layer = l ?? Layer(name: "f", content: .fill(f))
            return RenderEngine.renderBuffer(PaintRenderer.fillLayerImage(f, layer: layer, space: sp), docRect: IRect(x: 0, y: 0, width: W, height: H), space: sp)
        }
        // method: perceptual / linear / classic midpoints of red → green
        var g = GradientFill(gradient: .twoColor(RGBA(r: 1, g: 0, b: 0), RGBA(r: 0, g: 1, b: 0)), type: .linear, angle: 0)
        g.dither = false
        let classic = render(FillContent(paint: .gradient(g))).pixel(100, 50)
        g.method = .linear
        let linear = render(FillContent(paint: .gradient(g))).pixel(100, 50)
        g.method = .perceptual
        let perceptual = render(FillContent(paint: .gradient(g))).pixel(100, 50)
        check(Int(linear.0) > Int(classic.0) + 40 && Int(linear.1) > Int(classic.1) + 40, "Method Linear: brighter midpoint than Classic", "classic \(classic) linear \(linear)")
        check(perceptual != classic && perceptual != linear && Int(perceptual.0) + Int(perceptual.1) > Int(classic.0) + Int(classic.1), "Method Perceptual: its own (Oklab) midpoint", "\(perceptual)")
        // offset
        g.method = nil
        let base = render(FillContent(paint: .gradient(g)))
        g.offset = CGPoint(x: 20, y: 0)
        let moved = render(FillContent(paint: .gradient(g)))
        check(maxDiffColumn(base, moved, from: 60, shift: 40) <= 2, "Gradient offset 20 % moves the gradient 40 px (20 % of the width)")
        // align with layer: the gradient spans the mask, not the canvas
        g.offset = nil
        var l = Layer(name: "g", content: .fill(FillContent(paint: .gradient(g))))
        l.mask = PSDExportSamples.ellipseMask(W, H, CGRect(x: 100, y: 0, width: 100, height: 100))
        let free = render(l.fill!, l).pixel(110, 50)
        g.alignWithLayer = true
        l.fill = FillContent(paint: .gradient(g))
        let aligned = render(l.fill!, l).pixel(110, 50)
        check(aligned.0 > 200 && free.0 < 140, "Align with layer: the gradient starts at the mask's edge instead of the canvas edge", "aligned \(aligned) free \(free)")
        check(PaintRenderer.alignBounds(l, canvas: canvas).map { abs($0.minX - 100) <= 1 && abs($0.width - 100) <= 2 } == true, "align bounds = the mask's bounds")
        // dither: within a level, not identical
        g.alignWithLayer = nil
        g.gradient = .twoColor(gray(0.3), gray(0.36))
        g.dither = false
        let flatG = render(FillContent(paint: .gradient(g)))
        g.dither = true
        let dith = render(FillContent(paint: .gradient(g)))
        let md = maxDiff(flatG, dith)
        check(md >= 1 && md <= 1, "Dither adds ±1 level of noise (and no more)", "max diff \(md)")
        // pattern placement: angle, offset, link with layer, snap to origin
        let pid = "stripes"
        let tile = PatternLibrary.pattern(id: pid, custom: [])!.image
        var pl = PatternPlacement()
        let at0 = render(FillContent(paint: .pattern(id: pid, scale: 1), patternPlacement: pl))
        check(at0.pixel(0, 0) == tile.pixel(0, 0) && at0.pixel(5, 3) == tile.pixel(5, 3) && at0.pixel(16 + 5, 16 + 3) == tile.pixel(5, 3),
              "Snap to Origin: the tile's corner sits on the document's top-left corner")
        pl.offset = CGPoint(x: 6, y: 4)
        let off = render(FillContent(paint: .pattern(id: pid, scale: 1), patternPlacement: pl))
        check(off.pixel(6 + 5, 4 + 3) == tile.pixel(5, 3), "pattern offset moves the tiles")
        pl.offset = .zero; pl.angle = 90
        let rot = render(FillContent(paint: .pattern(id: "bricks", scale: 1), patternPlacement: pl))
        let unrot = render(FillContent(paint: .pattern(id: "bricks", scale: 1), patternPlacement: PatternPlacement()))
        save(rot, "pattern_bricks_90"); save(unrot, "pattern_bricks_0")
        // bricks have horizontal mortar lines every 16 px: turned 90° they run vertically
        func rowUniform(_ b: PixelBuffer, _ y: Int) -> Bool { (0..<60).allSatisfy { b.pixel($0, y) == b.pixel(0, y) } }
        func colUniform(_ b: PixelBuffer, _ x: Int) -> Bool { (0..<60).allSatisfy { b.pixel(x, $0) == b.pixel(x, 0) } }
        // (the bed joints make 12 uniform rows per 64 px; one head joint column happens to be uniform too)
        let rows0 = (0..<64).filter { rowUniform(unrot, $0) }.count, cols0 = (0..<64).filter { colUniform(unrot, $0) }.count
        let rows90 = (0..<64).filter { rowUniform(rot, $0) }.count, cols90 = (0..<64).filter { colUniform(rot, $0) }.count
        check(rows0 >= 10 && cols0 < 10, "bricks: horizontal mortar lines", "rows \(rows0) cols \(cols0)")
        check(cols90 >= 10 && rows90 < 10, "pattern angle 90°: the mortar lines run vertically", "rows \(rows90) cols \(cols90)")
        var linked = Layer(name: "p", content: .fill(FillContent(paint: .pattern(id: pid, scale: 1), patternPlacement: PatternPlacement())))
        linked.translate(dx: 13, dy: 7)
        check(linked.fill?.patternPlacement?.offset == CGPoint(x: 13, y: 7), "Link with Layer: moving the layer moves the pattern")
        var unlinked = Layer(name: "p", content: .fill(FillContent(paint: .pattern(id: pid, scale: 1), patternPlacement: PatternPlacement(angle: 0, offset: .zero, linked: false))))
        unlinked.translate(dx: 13, dy: 7)
        check(unlinked.fill?.patternPlacement?.offset == .zero, "…and stays put when unlinked")
    }

    /// Largest difference between column x of `b` and column x - shift of `a` (for x from `from` on).
    static func maxDiffColumn(_ a: PixelBuffer, _ b: PixelBuffer, from: Int, shift: Int) -> Int {
        var m = 0
        for x in from..<(a.width - 1) { for y in stride(from: 0, to: a.height, by: 10) {
            let p = a.pixel(x - shift, y), q = b.pixel(x, y)
            m = max(m, abs(Int(p.0) - Int(q.0)), abs(Int(p.1) - Int(q.1)), abs(Int(p.2) - Int(q.2)))
        } }
        return m
    }

    // MARK: Fill dialogs

    static func fillDialogs(_ dir: URL) {
        let app = AppModel.shared
        let W = 240, H = 160
        var st = DocumentState(width: W, height: H)
        st.layers = [solidBackground(W, H, RGBA(hex: "3366AA")!)]
        let d = Document(state: st, name: "fills")
        activate(d)
        defer { FillLayerDialog.close(); close(d) }
        app.foreground = RGBA(r: 1, g: 0, b: 0); app.background = RGBA(r: 0, g: 0, b: 1)
        let h0 = d.history.count, n0 = d.state.layers.count
        let before = flat(d.state)

        // new Gradient Fill: live layer, dialog open, canvas drag armed
        FillLayerDialog.newLayer(.gradient)
        check(d.state.layers.count == n0 + 1 && d.history.count == h0, "New Gradient Fill: the layer shows at once, not yet a history step")
        check(app.dialog?.id == ActiveDialog.custom(FillLayerDialog.dialogID).id && CanvasSampler.shared.isArmed, "the Gradient Fill dialog opens and the canvas takes drags")
        check(!(DialogRegistry.nonDimming.contains(FillLayerDialog.dialogID) == false), "the dialog leaves the canvas visible (not dimmed)")
        guard let gid = FillLayerDialog.session?.layerID else { check(false, "dialog session"); return }
        check(d.state.layer(gid)?.name == "Gradient Fill 1", "named like Photoshop", d.state.layer(gid)?.name ?? "")
        // edits preview live
        FillLayerDialog.edit { f in if case .gradient(var g) = f.paint { g.angle = 0; g.type = .radial; f.paint = .gradient(g) } }
        let live = flat(d.state)
        check(maxDiff(live, before) > 50, "changes preview on the canvas")
        // drag in the image moves the gradient (offset in % of the reference box)
        FillLayerDialog.beginDrag(at: CGPoint(x: 100, y: 80))
        FillLayerDialog.drag(to: CGPoint(x: 160, y: 96))
        FillLayerDialog.endDrag()
        if case .gradient(let g)? = d.state.layer(gid)?.fill?.paint, let o = g.offset {
            check(abs(o.x - 25) < 0.01 && abs(o.y - 10) < 0.01, "dragging 60 × 16 px moves the gradient by 25 % × 10 %", "\(o)")
        } else { check(false, "dragging sets the gradient offset") }
        check(d.history.count == h0, "dragging is part of the dialog's one step")
        FillLayerDialog.cancel()
        check(d.state.layers.count == n0 && d.history.count == h0 && maxDiff(flat(d.state), before) == 0 && app.dialog == nil,
              "Cancel on a new fill layer removes it and leaves no history")

        // OK makes one undoable step
        FillLayerDialog.newLayer(.pattern)
        guard let pid = FillLayerDialog.session?.layerID else { check(false, "pattern session"); return }
        FillLayerDialog.edit { f in f.paint = .pattern(id: "hex", scale: 0.5); f.patternPlacement?.angle = 30 }
        FillLayerDialog.ok()
        check(d.history.count == h0 + 1 && d.history.last?.name == "New Pattern Fill Layer" && d.state.layer(pid) != nil, "OK: one step “New Pattern Fill Layer”",
              d.history.last?.name ?? "")
        d.undo()
        check(d.state.layer(pid) == nil, "undo removes the new fill layer")
        d.redo()
        check(d.state.layer(pid)?.fill?.patternPlacement?.angle == 30, "redo brings it back with its settings")

        // editing an existing layer: Cancel restores exactly, OK is one step
        let committed = d.state.layer(pid)!.fill!
        FillLayerDialog.open(pid)
        FillLayerDialog.edit { f in f.paint = .pattern(id: "bricks", scale: 2); f.patternPlacement?.linked = false }
        FillLayerDialog.beginDrag(at: CGPoint(x: 10, y: 10)); FillLayerDialog.drag(to: CGPoint(x: 30, y: 15)); FillLayerDialog.endDrag()
        check(d.state.layer(pid)?.fill?.patternPlacement?.offset == CGPoint(x: (committed.patternPlacement?.offset.x ?? 0) + 20, y: (committed.patternPlacement?.offset.y ?? 0) + 5),
              "dragging moves the pattern by the drag distance")
        FillLayerDialog.cancel()
        check(d.state.layer(pid)?.fill == committed && d.history.count == h0 + 1, "Cancel on an existing fill layer restores it exactly")
        FillLayerDialog.open(pid)
        FillLayerDialog.change(to: .solid)
        FillLayerDialog.ok()
        check(d.state.layer(pid)?.fill?.paint.solidColor != nil && d.history.last?.name == "Edit Color Fill", "changing the contents to Solid Color and OK: one step", d.history.last?.name ?? "")
        d.undo()
        check(d.state.layer(pid)?.fill == committed, "undo restores the pattern fill")

        // Solid Color: a click in the image picks the colour below
        let under = flat(d.state).pixel(50, 50)
        FillLayerDialog.newLayer(.solid)
        FillLayerDialog.beginDrag(at: CGPoint(x: 50, y: 50))
        let picked = FillLayerDialog.current?.fill.paint.solidColor
        check(picked.map { abs($0.r8 - Int(under.0)) <= 1 && abs($0.g8 - Int(under.1)) <= 1 && abs($0.b8 - Int(under.2)) <= 1 } == true, "Solid Color: clicking the image picks the colour under the fill",
              "\(picked.map { "\($0.r8) \($0.g8) \($0.b8)" } ?? "nil") vs \(under)")
        FillLayerDialog.cancel()

        // a pattern fill from before placement existed: opening the dialog does not move it
        var legacy = Layer(name: "Pattern Fill 9", content: .fill(FillContent(paint: .pattern(id: "bricks", scale: 0.5))))
        legacy.mask = PSDExportSamples.ellipseMask(W, H, CGRect(x: 20, y: 20, width: 120, height: 120))
        d.addLayer(legacy, commitName: "legacy")
        let lb = flat(d.state)
        FillLayerDialog.open(legacy.id)
        check(d.state.layer(legacy.id)?.fill?.patternPlacement != nil && maxDiff(flat(d.state), lb) <= 1, "opening an older pattern fill keeps its tiles where they were")
        FillLayerDialog.cancel()
        check(d.state.layer(legacy.id)?.fill?.patternPlacement == nil, "…and Cancel leaves it untouched")

        // the real dialog view: a typed value still in its field is applied by OK (pending-field commit)
        FillLayerDialog.newLayer(.gradient)
        guard let g2 = FillLayerDialog.session?.layerID else { return }
        let w = UIFixesSelfTest.host(FillLayerDialog(), CGSize(width: 480, height: 760))
        let angleField = UIFixesSelfTest.fields(w).first { $0.stringValue == "90" }
        check(angleField != nil, "the dialog shows the angle field", UIFixesSelfTest.fields(w).map(\.stringValue).joined(separator: " | "))
        if let f = angleField {
            UIFixesSelfTest.type("45", into: f, w)
            if let okButton = UIFixesSelfTest.ax(w, "OK", role: "AXButton") { UIFixesSelfTest.clickButton(okButton, w) } else { check(false, "OK button found") }
            if case .gradient(let g)? = d.state.layer(g2)?.fill?.paint {
                check(g.angle == 45 && d.history.last?.name == "New Gradient Fill Layer", "typed angle without Return + OK: applied and committed", "angle \(g.angle), \(d.history.last?.name ?? "")")
            } else { check(false, "gradient layer after OK") }
        }
        UIFixesSelfTest.close(w)
        check(app.dialog == nil && !CanvasSampler.shared.isArmed, "after OK the dialog is closed and the canvas is back to normal")
        // the menu entry for existing layers
        if let item = MenuRegistry.items(for: "Layer").first(where: { $0.title == "Fill Layer Options…" }) {
            d.selectLayer(g2)
            check(item.enabled(), "Layer ▸ Fill Layer Options… is enabled for a fill layer")
            item.action()
            check(FillLayerDialog.session?.layerID == g2 && app.dialog != nil, "…and opens the dialog for it")
            FillLayerDialog.cancel()
        } else { check(false, "Layer ▸ Fill Layer Options… registered") }
    }

    // MARK: PSD export and Lumen files

    static func fileFormats(_ dir: URL) {
        var st = DocumentState(width: 220, height: 160)
        st.layers = [solidBackground(220, 160, .white)]
        func shape(_ name: String, _ r: CGRect, _ edit: (inout StrokeStyle) -> Void) -> Layer {
            var s = ShapeContent(geometry: .rectangle(r, cornerRadius: 0), fill: .color(RGBA(hex: "8ECAE6")!))
            s.stroke = StrokeStyle(paint: .color(RGBA(hex: "023047")!), width: 4)
            edit(&s.stroke)
            return Layer(name: name, content: .shape(s))
        }
        st.layers += [
            shape("Odd dashes", CGRect(x: 10, y: 10, width: 90, height: 60)) { $0.dash = [3, 1, 1] },
            shape("Dots", CGRect(x: 120, y: 10, width: 90, height: 60)) { $0.dash = [0, 2]; $0.cap = .round; $0.join = .round; $0.alignment = .outside },
            shape("Corner dashes", CGRect(x: 10, y: 90, width: 90, height: 60)) { $0.dash = [4, 2]; $0.dashAlignment = .corners; $0.dashUnit = .pixels; $0.miterLimit = 4 },
        ]
        var g = GradientFill(gradient: ColorGradient.presets[3], type: .radial, angle: 30)
        g.offset = CGPoint(x: 10, y: -5); g.alignWithLayer = true; g.method = .perceptual
        var gl = Layer(name: "Gradient Fill 1", content: .fill(FillContent(paint: .gradient(g))))
        gl.mask = PSDExportSamples.ellipseMask(220, 160, CGRect(x: 120, y: 90, width: 90, height: 60))
        var pl = Layer(name: "Pattern Fill 1", content: .fill(FillContent(paint: .pattern(id: "hex", scale: 0.5), patternPlacement: PatternPlacement(angle: 15, offset: CGPoint(x: 3, y: 4), linked: false))))
        pl.opacity = 0.3
        st.layers += [gl, pl]

        // PSD as Photoshop reads it (no Lumen data block)
        PSDExport.writeLumenData = false
        defer { PSDExport.writeLumenData = true }
        let url = dir.appendingPathComponent("dashes_native.psd")
        do {
            try PSDWriter.write(st, to: url)
            let notes = PSDExport.lastNotes
            let back = try PSDImporter.read(data: try Data(contentsOf: url), name: url.lastPathComponent, baseURL: dir).state
            func s(_ n: String) -> StrokeStyle? { back.allLayers.first { $0.name == n }?.shape?.stroke }
            check(s("Odd dashes")?.dash == [3, 1, 1, 3, 1, 1], "PSD (vstk): an odd dash list is written doubled, so Photoshop draws the same pattern", "\(s("Odd dashes")?.dash ?? [])")
            check(s("Dots")?.dash == [0, 2] && s("Dots")?.cap == .round && s("Dots")?.alignment == .outside, "PSD (vstk): round dots (dash 0, gap 2, round caps) and alignment")
            check(s("Corner dashes")?.dash == [4, 2], "PSD (vstk): dashes typed in px are written in stroke widths")
            check(notes.contains { $0.layer == "Corner dashes" && $0.detail.contains("aligned to corners") }, "PSD export notes that corner-aligned dashes are approximated")
        } catch { check(false, "PSD export of dashes", "\(error)") }
        // with the Lumen data block everything comes back
        PSDExport.writeLumenData = true
        let url2 = dir.appendingPathComponent("dashes_exact.psd")
        do {
            try PSDWriter.write(st, to: url2)
            let back = try PSDImporter.read(data: try Data(contentsOf: url2), name: url2.lastPathComponent, baseURL: dir).state
            let c = back.allLayers.first { $0.name == "Corner dashes" }?.shape?.stroke
            check(c?.dashAlignment == .corners && c?.dashUnit == .pixels && c?.miterLimit == 4, "PSD with Lumen data: corner alignment, units and miter limit come back")
        } catch { check(false, "PSD export (exact)", "\(error)") }
        // Lumen's own files keep everything
        let d = Document(state: st, name: "keep")
        let lurl = dir.appendingPathComponent("shapesfills.imagecrat")
        do {
            try DocumentIO.saveNative(d, to: lurl)
            let back = try DocumentIO.load(url: lurl).state
            func layer(_ n: String) -> Layer? { back.allLayers.first { $0.name == n } }
            let ok = st.layers.filter { $0.isShape }.allSatisfy { l in layer(l.name)?.shape == l.shape }
            check(ok, "Lumen file: every stroke option (dashes, units, corner alignment, miter) is kept")
            check(layer("Gradient Fill 1")?.fill == gl.fill, "Lumen file: gradient offset, Align with layer and Method are kept")
            check(layer("Pattern Fill 1")?.fill == pl.fill, "Lumen file: pattern angle, offset and Link with Layer are kept")
        } catch { check(false, "Lumen file round trip", "\(error)") }
    }

    // MARK: Snapshots

    static func snapshots(_ dir: URL) {
        var stroke = StrokeStyle(paint: .color(RGBA(hex: "E63946")!), width: 6, alignment: .inside, cap: .round, join: .round, dash: [0, 2, 3, 2])
        stroke.dashAlignment = .corners
        let editor = VStack(alignment: .leading) {
            StrokeOptionsEditor(stroke: .constant(stroke), onCommit: {})
        }.padding(10)
        let w = UIFixesSelfTest.host(editor, CGSize(width: 290, height: 640))
        UIFixesSelfTest.snapshot(w, "stroke_options_panel", dir)
        UIFixesSelfTest.close(w)
        // the Properties panel section for a shape
        var s = ShapeContent(geometry: .polygon(CGRect(x: 0, y: 0, width: 100, height: 100), sides: 5, starRatio: 0.5), fill: .color(RGBA(hex: "FFB703")!))
        s.stroke = stroke
        let props = ScrollView { VStack(alignment: .leading, spacing: 10) { ShapeProperties(s: .constant(s), onCommit: {}) }.padding(10) }
        let w2 = UIFixesSelfTest.host(props, CGSize(width: 290, height: 900))
        UIFixesSelfTest.snapshot(w2, "properties_shape", dir)
        UIFixesSelfTest.close(w2)
        // the shape tools' options bar with its Stroke Options button
        let app = AppModel.shared
        let hook = app.toolChanged, tool = app.tool
        app.toolChanged = nil
        app.tool = .ellipse
        app.shapeTool.stroke = .color(RGBA(hex: "E63946")!)
        app.shapeTool.strokeOptions = stroke
        let bar = HStack(spacing: 10) { ShapeOptions(); Spacer() }.padding(.horizontal, 8)
        let w3 = UIFixesSelfTest.host(bar, CGSize(width: 900, height: 36))
        UIFixesSelfTest.snapshot(w3, "options_bar_shape", dir)
        UIFixesSelfTest.close(w3)
        app.tool = tool
        app.toolChanged = hook
        // the fill dialogs
        var st = DocumentState(width: 240, height: 160)
        st.layers = [solidBackground(240, 160, .white)]
        let d = Document(state: st, name: "snap")
        activate(d)
        defer { FillLayerDialog.close(); close(d) }
        for (k, size) in [(FillKind.gradient, CGSize(width: 460, height: 720)), (.pattern, CGSize(width: 460, height: 640)), (.solid, CGSize(width: 500, height: 560))] {
            FillLayerDialog.newLayer(k)
            let w = UIFixesSelfTest.host(DraggableCard { FillLayerDialog() }, size)
            UIFixesSelfTest.spin(0.4)
            if k == .solid {
                // a colour picked from the image reaches the picker (its R G B fields; H S B and hex follow through onChange,
                // which SwiftUI does not run in this headless host)
                FillLayerDialog.edit { $0.paint = .color(RGBA(hex: "2A9D8F")!) }
                UIFixesSelfTest.spin(0.3)
                let texts = UIFixesSelfTest.fields(w).map(\.stringValue)
                check(texts.contains("42") && texts.contains("157") && texts.contains("143"), "Color Fill: the picker shows a colour set from the image", texts.joined(separator: " | "))
            }
            UIFixesSelfTest.snapshot(w, "fill_dialog_\(k.layerName.replacingOccurrences(of: " ", with: "_").lowercased())", dir)
            UIFixesSelfTest.close(w)
            FillLayerDialog.cancel()
        }
        _ = app
        info("snapshots written to \(dir.path)")
    }
}
