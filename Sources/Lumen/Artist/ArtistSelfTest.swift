import AppKit
import SwiftUI
import CoreImage
import ImageCratCore

/// Headless tests of the Artist module (`LUMEN_SELFTEST_ONLY=artist .build/debug/Lumen --selftest <dir>`).
/// Writes `artist_*.png` renders; `LUMEN_SELFTEST_UI=1` adds `ui_artist_*.png` panel snapshots.
enum ArtistSelfTest {
    static func register() {
        FeatureModules.selfTests.append(("artist", { out in run(out) }))
    }

    static func check(_ ok: Bool, _ msg: String) { print(ok ? "ok   artist: \(msg)" : "FAIL artist: \(msg)") }

    static func run(_ out: URL) {
        let app = AppModel.shared
        let savedTool = app.tool, savedBrush = app.brush, savedFG = app.foreground, savedBG = app.background
        let savedPrefs = ArtistSettings.shared.prefs, savedSwatches = app.swatches, savedRecent = app.recentColors
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-artist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        ArtistSupport.overrideDirectory = tmp
        defer {
            app.tool = savedTool; app.brush = savedBrush; app.foreground = savedFG; app.background = savedBG
            app.swatches = savedSwatches; app.recentColors = savedRecent
            ArtistSettings.shared.prefs = savedPrefs
            ArtistSettings.shared.simulation = .none
            ArtistContext.testDoc = nil
            ArtistSupport.overrideDirectory = nil
            SwatchGroupStore.shared.reload()
            ReferenceBoardStore.shared.reloadGlobal()
            try? FileManager.default.removeItem(at: tmp)
        }
        ArtistSettings.shared.prefs = ArtistPrefs()
        SwatchGroupStore.shared.reload()
        ReferenceBoardStore.shared.reloadGlobal()

        docData(tmp)
        referenceBoard(out, tmp)
        pieMenu(out)
        guides(out)
        rulers(out)
        stabiliser(out)
        paletteJitter(out)
        harmony(out)
        paletteExtraction(out)
        globalColours(out, tmp)
        recolour(out)
        contrast(out)
        simulation(out)
        viewFlip()
        wrapAround(out)
        seamless(out)
        extras(out)
        if ProcessInfo.processInfo.environment["LUMEN_SELFTEST_UI"] == "1" { uiSnapshots(out) }
    }

    // MARK: Helpers

    static func savePNG(_ cg: CGImage?, _ name: String, _ out: URL) {
        guard let cg else { print("FAIL artist: no image for \(name)"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        print("wrote \(name)")
    }

    static func composite(_ st: DocumentState) -> PixelBuffer { ToolsSelfTest.composite(st) }

    /// Draws into a y-down bitmap of `size` with an NSGraphicsContext installed (text and handles work).
    static func drawImage(_ size: CGSize, _ body: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// The document composite with the drawing guides / rulers overlaid, with a margin so off-canvas handles show.
    static func guideImage(_ st: DocumentState, margin: CGFloat = 0, editing: Bool = true, extra: ((CGContext, (CGPoint) -> CGPoint) -> Void)? = nil) -> CGImage? {
        let size = CGSize(width: CGFloat(st.width) + 2 * margin, height: CGFloat(st.height) + 2 * margin)
        let comp = composite(st).makeCGImage()
        return drawImage(size) { ctx in
            ctx.setFillColor(NSColor(white: 0.2, alpha: 1).cgColor); ctx.fill(CGRect(origin: .zero, size: size))
            ctx.saveGState()
            ctx.translateBy(x: margin, y: margin + CGFloat(st.height)); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(comp, in: CGRect(x: 0, y: 0, width: st.width, height: st.height))
            ctx.restoreGState()
            let toView: (CGPoint) -> CGPoint = { CGPoint(x: $0.x + margin, y: $0.y + margin) }
            GuideRenderer.draw(ctx, data: st.artist, canvas: st.canvasCGRect, toView: toView, editing: editing)
            extra?(ctx, toView)
        }
    }

    static func tiled(_ buf: PixelBuffer, _ n: Int = 2) -> CGImage? {
        let img = buf.makeCGImage()
        let w = CGFloat(buf.width), h = CGFloat(buf.height)
        return drawImage(CGSize(width: w * CGFloat(n), height: h * CGFloat(n))) { ctx in
            for y in 0..<n { for x in 0..<n {
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(x) * w, y: CGFloat(y + 1) * h); ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                ctx.restoreGState()
            } }
        }
    }

    static func solidImage(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let b = PixelBuffer(width: w, height: h)
        draw(b.context)
        b.markDirty()
        return b.makeCGImage()
    }

    /// Opaque-ish pixels of a layer (doc coordinates).
    static func painted(_ d: Document, _ id: UUID, threshold: UInt8 = 128) -> [CGPoint] {
        guard let r = d.state.layer(id)?.raster else { return [] }
        var out: [CGPoint] = []
        for y in 0..<r.buffer.height { for x in 0..<r.buffer.width where r.buffer.alpha(x, y) > threshold {
            out.append(CGPoint(x: CGFloat(x + r.origin.x) + 0.5, y: CGFloat(y + r.origin.y) + 0.5))
        } }
        return out
    }

    static func lineDistance(_ p: CGPoint, _ a: CGPoint, _ dir: CGPoint) -> CGFloat {
        let v = p - a
        return abs(v.x * dir.y - v.y * dir.x)
    }

    static func near(_ a: RGBA, _ b: RGBA, _ tol: Int = 3) -> Bool { abs(a.r8 - b.r8) <= tol && abs(a.g8 - b.g8) <= tol && abs(a.b8 - b.b8) <= tol }

    static func pixel(_ b: PixelBuffer, _ x: Int, _ y: Int) -> RGBA {
        let (r, g, bl, a) = b.pixel(x, y)
        return RGBA(r8: r, g8: g, b8: bl, a8: a)
    }

    // MARK: Document data

    static func docData(_ tmp: URL) {
        var st = SelfTest.baseState(320, 200)
        st.layers.append(SelfTest.shapeLayer(CGRect(x: 40, y: 40, width: 100, height: 80)))
        var a = ArtistDocData()
        a.guide = DrawingGuide.standard(.perspective2, width: 320, height: 200)
        a.guide.opacity = 0.8
        a.rulers = [AssistRuler.standard(.straight, width: 320, height: 200), AssistRuler.standard(.ellipse, width: 320, height: 200), AssistRuler.standard(.curve, width: 320, height: 200)]
        a.globals = [GlobalColor(name: "Brand", color: RGBA(hex: "E94F37")!)]
        a.links = [ColorLink(layerID: st.layers[1].id, slot: .shapeFill, globalID: a.globals[0].id)]
        if let item = ReferenceImages.makeItem(solidImage(64, 48) { c in c.setFillColor(RGBA(hex: "2E86DE")!.cgColor); c.fill(CGRect(x: 0, y: 0, width: 64, height: 48)) }) { a.board.items = [item] }
        st.artist = a
        let d = Document(state: st, name: "artist.imagecrat")
        let url = tmp.appendingPathComponent("artist.imagecrat")
        do {
            try DocumentIO.saveNative(d, to: url)
            let back = try DocumentIO.load(url: url)
            check(back.state.artist == a, "guides, rulers, globals, links and the document board survive save / load")
        } catch { check(false, "save / load with artist data: \(error)") }

        // tolerant decoding: unknown kinds, wrong types, missing fields, bad entries
        let messy = """
        {"guide": {"kind": "hologram", "spacing": "wide", "vps": [[1, 2]]},
         "rulers": [{"kind": "straight", "points": [[0, 0]]}, {"kind": "straight", "points": [[0, 0], [10, 10]]}, {"kind": "banana"}, 7],
         "globals": [{"name": "Only a name"}, {"color": 12}],
         "links": [{"slot": "nope", "layerID": "x"}, {"layerID": "\(UUID().uuidString)", "slot": "textColor", "globalID": "\(UUID().uuidString)"}],
         "board": {"items": [{"pixelWidth": 4}, {"imageData": "AAEC", "scale": -3, "opacity": 9}], "viewZoom": 0},
         "futureField": {"x": 1}}
        """
        if let data = messy.data(using: .utf8), let m = try? JSONDecoder().decode(ArtistDocData.self, from: data) {
            check(m.guide.kind == .none && m.rulers.count == 1 && m.globals.count == 2 && m.links.count == 1 && m.board.items.count == 1,
                  "malformed artist data decodes tolerantly (guide \(m.guide.kind), \(m.rulers.count) ruler, \(m.globals.count) globals, \(m.links.count) link, \(m.board.items.count) item)")
            check(m.board.items[0].scale > 0 && m.board.items[0].opacity <= 1 && m.board.viewZoom > 0, "out-of-range board values are clamped")
        } else { check(false, "malformed artist data should still decode") }
        // a document written before this module has no `artist` key
        var plain = SelfTest.baseState(64, 64)
        plain.artist = ArtistDocData()
        if let data = try? JSONEncoder().encode(plain), let json = String(data: data, encoding: .utf8) {
            check(!json.contains("\"artist\""), "empty artist data is not written to the file")
            check((try? JSONDecoder().decode(DocumentState.self, from: data))?.artist.isEmpty == true, "documents without artist data open with defaults")
        }
        check((try? JSONDecoder().decode(ArtistPrefs.self, from: Data("{\"stabilizer\":\"warp\",\"pie\":{\"tools\":[\"brush\"]}}".utf8)))?.pie.tools.count == 8,
              "preferences decode tolerantly (unknown stabiliser, short tool list)")
    }

    // MARK: Reference board

    static func referenceBoard(_ out: URL, _ tmp: URL) {
        let store = ReferenceBoardStore.shared
        check(store.global.items.isEmpty, "the test board starts empty (temp support folder)")
        // a large photo-like image, a quadrant image and a transparent one
        let big = solidImage(3000, 2000) { c in
            let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "FF8A00")!.cgColor, RGBA(hex: "7A00FF")!.cgColor] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 3000, y: 2000), options: [])
        }
        let quad = solidImage(200, 200) { c in
            for (i, hex) in ["FF0000", "00FF00", "0000FF", "FFFF00"].enumerated() {
                c.setFillColor(RGBA(hex: hex)!.cgColor)
                c.fill(CGRect(x: (i % 2) * 100, y: (i / 2) * 100, width: 100, height: 100))   // y-down: red TL, green TR, blue BL, yellow BR
            }
        }
        let alpha = solidImage(120, 120) { c in c.setFillColor(RGBA(hex: "00C2A8")!.cgColor); c.fillEllipse(in: CGRect(x: 10, y: 10, width: 100, height: 100)) }
        let ids = store.add([(big, "big"), (quad, "quad"), (alpha, "alpha")], to: .global, doc: nil, at: CGPoint(x: -300, y: 0), fitSide: 240)
        check(ids.count == 3 && store.global.items.count == 3, "three images added to the global board")
        let b0 = store.global.items[0]
        check(max(b0.pixelWidth, b0.pixelHeight) == RefBoard.maxPixelSide && b0.pixelHeight == 1067, "stored copy is capped at \(RefBoard.maxPixelSide) px (\(b0.pixelWidth)×\(b0.pixelHeight))")
        check(b0.imageData.count < 600_000, "large reference stored compactly (\(b0.imageData.count / 1024) KB)")
        let png = store.global.items[2].imageData.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
        let jpg = store.global.items[0].imageData.prefix(2) == Data([0xFF, 0xD8])
        check(png && jpg, "transparent references are stored as PNG, opaque ones as JPEG")

        // view: fit everything into a 640×360 window
        let size = CGSize(width: 640, height: 360)
        store.update(.global, doc: nil, name: nil) { RefBoardRenderer.fit(&$0, size: size) }
        var board = store.global
        let t = RefBoardRenderer.transform(board, size: size)
        let qFrame = board.items[1].frame.applying(t)
        let tl = CGPoint(x: qFrame.minX + qFrame.width * 0.25, y: qFrame.minY + qFrame.height * 0.25)
        let c1 = RefBoardRenderer.color(at: tl, board: board, size: size)
        check(c1.map { near($0, .red, 40) } ?? false, "eyedropper reads the reference pixel (top-left quadrant is red: \(c1?.hex ?? "nil"))")
        store.update(.global, doc: nil, name: "Flip Reference") { $0.items[1].flipH = true }
        board = store.global
        let c2 = RefBoardRenderer.color(at: tl, board: board, size: size)
        check(c2.map { near($0, RGBA(hex: "00FF00")!, 40) } ?? false, "flip horizontal mirrors the image (now green: \(c2?.hex ?? "nil"))")
        store.update(.global, doc: nil, name: "Reference Grayscale") { $0.items[1].grayscale = true; $0.items[0].opacity = 0.5 }
        board = store.global
        let c3 = RefBoardRenderer.color(at: tl, board: board, size: size)
        check(c3.map { abs($0.r8 - $0.g8) <= 3 && abs($0.g8 - $0.b8) <= 3 } ?? false, "grayscale display (sampled \(c3?.hex ?? "nil"))")
        check(RefBoardRenderer.color(at: CGPoint(x: 2, y: 2), board: board, size: size) == nil, "no colour over the empty board")
        check(RefBoardRenderer.item(at: tl, board: board, size: size)?.id == ids[1], "hit testing finds the image under the cursor")
        savePNG(RefBoardRenderer.render(board, size: size, selection: ids[1]), "artist_refboard", out)
        // picking sets the foreground
        let v = RefBoardView(ui: RefBoardUIState())
        v.frame = CGRect(origin: .zero, size: size)
        store.update(.global, doc: nil, name: "Reference Grayscale") { $0.items[1].grayscale = false }
        v.sample(tl, background: false)
        check(near(AppModel.shared.foreground, RGBA(hex: "00FF00")!, 40), "eyedropper from the board sets the foreground colour")

        // persistence
        store.saveGlobalNow()
        let file = tmp.appendingPathComponent(ReferenceBoardStore.file)
        check(FileManager.default.fileExists(atPath: file.path), "global board written to the support folder")
        let saved = store.global
        store.reloadGlobal()
        check(store.global == saved && store.global.items[1].flipH && store.global.items[0].opacity == 0.5, "global board reloads identically")
        // tolerant decoding of the board file
        try? Data("{\"items\":[{\"imageData\":\"\(saved.items[2].imageData.base64EncodedString())\"},{\"nope\":1}],\"viewCenter\":\"bad\"}".utf8).write(to: file)
        store.reloadGlobal()
        check(store.global.items.count == 1 && store.global.viewZoom == 1, "board file with missing / bad fields still loads")

        // per-document board: saved with the document, undoable
        let (d, _) = ToolsSelfTest.whiteDoc(200, 150, name: "board")
        let h0 = d.history.count
        store.add([(quad, "quad")], to: .document, doc: d, at: .zero)
        check(d.state.artist.board.items.count == 1 && d.history.count == h0 + 1 && d.isDirty, "document board edit is a history step")
        let itemID = d.state.artist.board.items[0].id
        for k in 1...5 { store.update(.document, doc: d, name: "Move Reference") { $0.items[0].center = CGPoint(x: k * 10, y: 0) } }
        check(d.history.count == h0 + 2, "dragging a reference is coalesced into one history step (\(d.history.count - h0))")
        store.update(.document, doc: d, name: nil) { $0.viewZoom = 2 }
        check(d.history.count == h0 + 2 && d.state.artist.board.viewZoom == 2, "panning / zooming the board records no history")
        let url = tmp.appendingPathComponent("board.imagecrat")
        try? DocumentIO.saveNative(d, to: url)
        let back = try? DocumentIO.load(url: url)
        check(back?.state.artist.board.items.first?.id == itemID && back?.state.artist.board.items.first?.center.x == 50, "document board is saved inside the .imagecrat file")
        d.undo(); d.undo()
        check(d.state.artist.board.items.isEmpty, "undo removes the reference again")
        check(store.global.items.count == 1, "document board edits leave the global board alone")
    }

    // MARK: Radial menu

    static func pieMenu(_ out: URL) {
        let app = AppModel.shared
        var g = PieGeometry()
        g.colorCount = 6
        func polar(_ r: CGFloat, _ deg: Double) -> CGPoint { CGPoint(x: r * CGFloat(cos(deg * .pi / 180)), y: r * CGFloat(sin(deg * .pi / 180))) }
        check(g.hit(CGPoint(x: 3, y: -4)) == .cancel, "centre is the cancel zone")
        let expected: [(Double, Int)] = [(90, 0), (45, 1), (0, 2), (315, 3), (270, 4), (225, 5), (180, 6), (135, 7), (70, 0), (112, 0), (113, 7), (23, 1), (22, 2)]
        check(expected.allSatisfy { g.hit(polar(100, $0.0)) == .tool($0.1) }, "8 tool slices, clockwise from the top (\(expected.map { g.hit(polar(100, $0.0)) }))")
        check(g.hit(polar(40, 90)) == .color(0) && g.hit(polar(40, 30)) == .color(1) && g.hit(polar(40, 270)) == .color(3) && g.hit(polar(40, 150)) == .color(5), "inner ring maps to the recent colours")
        check(g.hit(polar(155, 120)) == .action(.undo) && g.hit(polar(155, 90)) == .action(.flipView) && g.hit(polar(155, 60)) == .action(.redo), "top of the outer ring: undo / flip view / redo")
        check(g.hit(polar(155, 240)) == .action(.swapColors) && g.hit(polar(155, 270)) == .action(.fit) && g.hit(polar(155, 300)) == .action(.assist), "bottom of the outer ring: swap / fit / assist")
        check(g.hit(polar(400, 90)) == .outside, "far beyond the ring selects nothing")
        if case .size(let t) = g.hit(polar(g.toolOuter + 75, 180)) { check(abs(t - 0.5) < 0.001, "left scrubber: halfway out = 0.5") } else { check(false, "left of the ring is the size scrubber") }
        if case .opacity(let t) = g.hit(polar(g.toolOuter + 120, 10)) { check(abs(t - 0.8) < 0.001, "right scrubber: opacity follows the distance (\(t))") } else { check(false, "right of the ring is the opacity scrubber") }
        if case .size(let t) = g.hit(polar(900, 200)) { check(t == 1, "scrubbers clamp at the end of the gauge") } else { check(false, "size scrubber reaches outward") }
        var off = g; off.showScrubbers = false; off.showActions = false; off.showColors = false
        check(off.hit(polar(200, 180)) == .outside && off.hit(polar(155, 90)) == .outside && off.hit(polar(40, 90)) == .cancel, "hidden rings do not react")
        // size mapping: logarithmic, monotonic, invertible
        let sizes = stride(from: 0.0, through: 1.0, by: 0.1).map { PieGeometry.size(forT: $0) }
        check(sizes.first == 1 && sizes.last == 500 && zip(sizes, sizes.dropFirst()).allSatisfy { $0 < $1 }, "size gauge runs 1 → 500 px monotonically (\(sizes.map { Int($0) }))")
        check(abs(PieGeometry.t(forSize: PieGeometry.size(forT: 0.6)) - 0.6) < 0.02, "size gauge position matches the value")

        // applying hits
        let prefs = ArtistSettings.shared
        prefs.prefs.pie = PieConfig()
        app.tool = .move
        RadialMenuController.perform(.tool(0))
        check(app.tool == .brush, "releasing on the top slice selects the first favourite tool")
        prefs.prefs.pie.tools[2] = ToolKind.gradient.rawValue
        RadialMenuController.perform(.tool(2))
        check(app.tool == .gradient, "slices follow the configured tools")
        app.tool = .brush
        app.recentColors = [RGBA(hex: "112233")!, RGBA(hex: "AA5500")!, RGBA(hex: "00AA55")!]
        RadialMenuController.perform(.color(1))
        check(app.foreground.hex == "AA5500", "releasing on a colour sets the foreground")
        var s = app.brush; s.size = 30; s.opacity = 1; app.brush = s
        RadialMenuController.applyScrub(.size(0.75), original: (30, 1))
        check(app.brush.size == PieGeometry.size(forT: 0.75) && app.brush.opacity == 1, "size scrubber changes the brush size live (\(app.brush.size))")
        RadialMenuController.applyScrub(.opacity(0.4), original: (30, 1))
        check(app.brush.size == 30 && abs(app.brush.opacity - 0.4) < 0.001, "opacity scrubber changes opacity and leaves the size alone")
        RadialMenuController.applyScrub(.tool(3), original: (30, 1))
        check(app.brush.size == 30 && app.brush.opacity == 1, "leaving the scrubber restores the original values")
        let was = prefs.assist
        RadialMenuController.perform(.action(.assist))
        check(prefs.assist != was, "assist action toggles assisted drawing")
        prefs.assist = was
        let before = app.foreground, bg = app.background
        RadialMenuController.perform(.action(.swapColors))
        check(app.foreground == bg && app.background == before, "swap colours action")
        RadialMenuController.perform(.cancel); RadialMenuController.perform(.outside)
        check(app.tool == .brush, "cancel / outside change nothing")
        check(PieConfig().toolKinds.count == 8 && Set(PieConfig().toolKinds).count == 8, "default favourites are 8 distinct tools")
        check(PieTriggerKey.grave.keyCode == 50 && PieTriggerKey.backslash.keyCode == 42, "trigger keys: ` (50) or \\ (42)")

        var disp = RadialMenuController.display(app, hover: .tool(1))
        if let rep = PieRenderer.image(disp) { try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("artist_pie.png")); print("wrote artist_pie") }
        disp.hover = .size(0.7); disp.brushSize = PieGeometry.size(forT: 0.7)
        if let rep = PieRenderer.image(disp) { try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("artist_pie_scrub.png")); print("wrote artist_pie_scrub") }
        prefs.prefs.pie = PieConfig()
    }

    // MARK: Drawing guides and assisted strokes

    /// A wobbly stroke from `a` towards `b` (the wobble starts with zero slope, like a hand settling into a line).
    static func wobbly(_ a: CGPoint, _ b: CGPoint, amplitude: CGFloat = 12, n: Int = 90) -> [PenSample] {
        let dir = (b - a).normalized, perp = CGPoint(x: -dir.y, y: dir.x)
        let len = a.distance(to: b)
        return (0...n).map { i in
            let t = CGFloat(i) / CGFloat(n)
            let w = amplitude * sin(t * 9) * sin(t * 9) * (i % 2 == 0 ? 1 : 0.8)
            return PenSample(p: a + dir * (len * t) + perp * (w - amplitude * 0.35 * t))
        }
    }

    static func guides(_ out: URL) {
        let app = AppModel.shared
        app.tool = .brush
        let settings = ArtistSettings.shared
        settings.prefs = ArtistPrefs()
        let W = 520, H = 360
        let brush = BrushSelfTest.brush(size: 6, hardness: 1, spacing: 0.1)

        // --- 1-point perspective: a wobbly stroke becomes a straight line into the vanishing point
        do {
            let (d, id) = ToolsSelfTest.whiteDoc(W, H, name: "p1")
            ArtistContext.testDoc = d
            d.state.artist.guide = DrawingGuide.standard(.perspective1, width: W, height: H)
            let vp = d.state.artist.guide.vps[0]
            let start = CGPoint(x: 60, y: 320)
            let pts = wobbly(start, vp.lerp(start, 0.25))
            // raw (assist off) for comparison, on a second layer
            settings.assist = false
            let raw = Layer.raster(name: "raw", width: W, height: H)
            d.addLayer(raw)
            BrushSelfTest.stroke(d, raw.id, brush, pts, fg: RGBA(hex: "C0392B")!)
            settings.assist = true
            BrushSelfTest.stroke(d, id, brush, pts, fg: RGBA(hex: "1F3A93")!)
            let dir = (vp - start).normalized
            let rawDev = painted(d, raw.id).map { lineDistance($0, start, dir) }.max() ?? 0
            let snapped = painted(d, id)
            let dev = snapped.map { lineDistance($0, start, dir) }.max() ?? 99
            check(rawDev > 9, "unassisted stroke wobbles (max \(String(format: "%.1f", rawDev)) px from the line)")
            check(!snapped.isEmpty && dev <= 4.2, "assisted stroke is straight towards the vanishing point (max \(String(format: "%.2f", dev)) px incl. brush radius)")
            let far = snapped.map { $0.distance(to: start) }.max() ?? 0
            check(far > 150, "assisted stroke keeps its length (\(Int(far)) px)")
            savePNG(guideImage(d.state, margin: 30), "artist_assist_perspective1", out)

            // direction choice: a mostly horizontal stroke locks to the horizon direction, a vertical one to the vertical
            var s = AssistSnapper(start: start, guide: d.state.artist.guide, rulers: [], rulerRange: 0, threshold: 5)
            _ = s.snap(start + CGPoint(x: 3, y: 0.4))
            check(s.lock == nil, "direction is undecided until the pen has moved a few pixels")
            let h = s.snap(start + CGPoint(x: 40, y: 5))
            check(abs(h.y - start.y) < 0.001 && abs(h.x - (start.x + 40)) < 0.001, "horizontal movement locks to the horizon direction")
            var v = AssistSnapper(start: start, guide: d.state.artist.guide, rulers: [], rulerRange: 0, threshold: 5)
            let vv = v.snap(start + CGPoint(x: 4, y: -50))
            check(abs(vv.x - start.x) < 0.001, "vertical movement locks to the vertical")
        }

        // --- 2- and 3-point: the stroke heads for the vanishing point it started towards
        do {
            var g = DrawingGuide.standard(.perspective3, width: W, height: H)
            let start = CGPoint(x: 260, y: 200)
            for (i, vp) in g.vps.enumerated() {
                var s = AssistSnapper(start: start, guide: g, rulers: [], rulerRange: 0, threshold: 5)
                let dir = (vp - start).normalized
                var maxDev: CGFloat = 0
                for p in wobbly(start, start + dir * 200, amplitude: 9) { maxDev = max(maxDev, lineDistance(s.snap(p.p), start, dir)) }
                check(maxDev < 0.001, "3-point perspective: stroke towards VP\(i + 1) stays on its ray")
            }
            g = DrawingGuide.standard(.perspective2, width: W, height: H)
            var s = AssistSnapper(start: start, guide: g, rulers: [], rulerRange: 0, threshold: 5)
            let p = s.snap(start + CGPoint(x: 3, y: 70))
            check(abs(p.x - start.x) < 0.001, "2-point perspective keeps verticals vertical")
        }

        // --- isometric
        do {
            let (d, id) = ToolsSelfTest.whiteDoc(W, H, name: "iso")
            ArtistContext.testDoc = d
            d.state.artist.guide = DrawingGuide.standard(.isometric, width: W, height: H)
            let start = CGPoint(x: 120, y: 260)
            // roughly 24° above the horizontal → snaps to the 30° axis
            BrushSelfTest.stroke(d, id, brush, wobbly(start, start + AssistGeometry.unit(-24) * 260, amplitude: 8), fg: RGBA(hex: "1F3A93")!)
            let axis = AssistGeometry.unit(-30)
            let pts = painted(d, id)
            let dev = pts.map { lineDistance($0, start, axis) }.max() ?? 99
            check(!pts.isEmpty && dev <= 4.2, "isometric: stroke snaps to the 30° axis (max \(String(format: "%.2f", dev)) px)")
            BrushSelfTest.stroke(d, id, brush, wobbly(CGPoint(x: 380, y: 300), CGPoint(x: 372, y: 80), amplitude: 8), fg: RGBA(hex: "16A085")!)
            BrushSelfTest.stroke(d, id, brush, wobbly(CGPoint(x: 400, y: 300), CGPoint(x: 180, y: 190), amplitude: 8), fg: RGBA(hex: "8E44AD")!)
            let col = painted(d, id).filter { $0.x > 360 && $0.y < 250 && $0.y > 100 }
            check(!col.isEmpty && col.allSatisfy { abs($0.x - 380) <= 4.2 }, "isometric: near-vertical stroke becomes vertical")
            savePNG(guideImage(d.state), "artist_assist_isometric", out)
        }

        // --- 2D grid (rotated) and radial / concentric
        do {
            var g = DrawingGuide.standard(.grid, width: W, height: H)
            g.gridAngle = 15
            let start = CGPoint(x: 100, y: 100)
            var s = AssistSnapper(start: start, guide: g, rulers: [], rulerRange: 0, threshold: 5)
            let axis = AssistGeometry.unit(15)
            var maxDev: CGFloat = 0
            for p in wobbly(start, start + AssistGeometry.unit(9) * 200, amplitude: 6) { maxDev = max(maxDev, lineDistance(s.snap(p.p), start, axis)) }
            check(maxDev < 0.001, "2D grid: stroke follows the rotated grid axis")

            let (d, id) = ToolsSelfTest.whiteDoc(W, H, name: "radial")
            ArtistContext.testDoc = d
            d.state.artist.guide = DrawingGuide.standard(.radial, width: W, height: H)
            let c = d.state.artist.guide.center
            // tangential movement → concentric arc
            let r0: CGFloat = 120
            let arc = (0...80).map { i -> PenSample in
                let a = CGFloat(i) / 80 * 2.4 - 0.4
                return PenSample(p: c + CGPoint(x: cos(a), y: sin(a)) * (r0 + 10 * sin(a * 7) * (i < 3 ? 0 : 1)))
            }
            BrushSelfTest.stroke(d, id, brush, arc, fg: RGBA(hex: "1F3A93")!)
            let ring = painted(d, id)
            let rdev = ring.map { abs($0.distance(to: c) - r0) }.max() ?? 99
            check(!ring.isEmpty && rdev <= 4.2, "radial guide: tangential stroke becomes a concentric arc (max \(String(format: "%.2f", rdev)) px off the circle)")
            // radial movement → spoke through the centre
            let s0 = c + AssistGeometry.unit(200) * 40
            var sp = AssistSnapper(start: s0, guide: d.state.artist.guide, rulers: [], rulerRange: 0, threshold: 5)
            let q = sp.snap(s0 + AssistGeometry.unit(207) * 90)
            check(lineDistance(q, c, AssistGeometry.unit(200)) < 0.001, "radial guide: outward stroke stays on the spoke through the centre")
            BrushSelfTest.stroke(d, id, brush, wobbly(s0, s0 + AssistGeometry.unit(205) * 110, amplitude: 7), fg: RGBA(hex: "C0392B")!)
            savePNG(guideImage(d.state), "artist_assist_radial", out)
        }

        // --- guide images of every kind + handle editing
        for k in DrawingGuideKind.allCases where k != .none {
            var st = DocumentState(width: 360, height: 240)
            st.layers = [Layer.raster(name: "bg", buffer: PixelBuffer(cgImage: solidImage(360, 240) { c in c.setFillColor(RGBA.white.cgColor); c.fill(CGRect(x: 0, y: 0, width: 360, height: 240)) }))]
            st.artist.guide = DrawingGuide.standard(k, width: 360, height: 240)
            savePNG(guideImage(st, margin: k.vanishingPoints > 1 ? 120 : 20), "artist_guide_\(k.rawValue)", out)
        }
        do {
            var data = ArtistDocData()
            data.guide = DrawingGuide.standard(.perspective2, width: 400, height: 300)
            let toView: (CGPoint) -> CGPoint = { CGPoint(x: $0.x * 2 + 10, y: $0.y * 2 + 20) }
            let vp0 = data.guide.vps[0]
            check(GuideEditor.hit(data, view: toView(vp0) + CGPoint(x: 4, y: -3), toView: toView) == .vp(0), "vanishing point handle hit test (view space)")
            check(GuideEditor.hit(data, view: toView(vp0) + CGPoint(x: 30, y: 0), toView: toView) == nil, "clicks away from handles pass through to the tool")
            GuideEditor.move(.vp(0), to: CGPoint(x: -250, y: 90), delta: .zero, in: &data)
            check(data.guide.vps[0] == CGPoint(x: -250, y: 90), "dragging moves the vanishing point")
            data.guide = DrawingGuide.standard(.perspective1, width: 400, height: 300)
            let vp = data.guide.vps[0]
            GuideEditor.move(.angle, to: vp + CGPoint(x: 100, y: 100), delta: .zero, in: &data)
            check(abs(data.guide.horizonAngle - 45) < 0.001, "angle handle tilts the horizon")
            var hidden = data; hidden.guide.visible = false
            check(GuideEditor.handles(hidden).isEmpty, "a hidden guide has no handles")
        }

        // --- assist off / hidden guide: strokes are untouched; undo of the guide
        do {
            let (d, id) = ToolsSelfTest.whiteDoc(200, 200, name: "off")
            ArtistContext.testDoc = d
            d.state.artist.guide = DrawingGuide.standard(.grid, width: 200, height: 200)
            d.state.artist.guide.visible = false
            let eng = BrushDynamicsEngine(settings: brush, target: PixelBuffer(width: 200, height: 200), origin: .zero, paint: .fixed(.black))
            let inPts = wobbly(CGPoint(x: 20, y: 100), CGPoint(x: 180, y: 110)).map(\.p)
            check(BrushAssist.filter(inPts, engine: eng) == inPts, "a hidden guide does not snap strokes")
            d.state.artist.guide.visible = true
            settings.assist = false
            check(BrushAssist.filter(inPts, engine: eng) == inPts, "with Assisted Drawing off the input is untouched")
            settings.assist = true
            check(BrushAssist.filter(inPts, engine: eng) != inPts, "with Assisted Drawing on the input is snapped")
            _ = id
        }
        ArtistContext.testDoc = nil
    }

    static func rulers(_ out: URL) {
        let app = AppModel.shared
        app.tool = .brush
        ArtistSettings.shared.prefs = ArtistPrefs()
        let W = 520, H = 360
        let brush = BrushSelfTest.brush(size: 6, hardness: 1, spacing: 0.1)
        let (d, id) = ToolsSelfTest.whiteDoc(W, H, name: "rulers")
        ArtistContext.testDoc = d
        let straight = AssistRuler(kind: .straight, points: [CGPoint(x: 60, y: 300), CGPoint(x: 300, y: 250)])
        let ellipse = AssistRuler(kind: .ellipse, points: [CGPoint(x: 360, y: 130), CGPoint(x: 470, y: 150), CGPoint(x: 350, y: 185)])
        let curve = AssistRuler(kind: .curve, points: [CGPoint(x: 40, y: 200), CGPoint(x: 120, y: 20), CGPoint(x: 220, y: 230), CGPoint(x: 300, y: 60)])
        d.state.artist.rulers = [straight, ellipse, curve]
        let range = CGFloat(ArtistSettings.shared.prefs.rulerSnapRange)

        // straight edge: a stroke started 10 px off the ruler runs parallel to it
        let dir = (straight.points[1] - straight.points[0]).normalized
        let n = CGPoint(x: -dir.y, y: dir.x)
        let s0 = straight.points[0] + dir * 20 + n * 10
        var snap = AssistSnapper(start: s0, guide: DrawingGuide(), rulers: d.state.artist.rulers, rulerRange: range, threshold: 5)
        check(snap.rulerID == straight.id, "a stroke starting near the straight edge attaches to it")
        var dev: CGFloat = 0
        for p in wobbly(s0, s0 + dir * 200 + n * 25) { dev = max(dev, lineDistance(snap.snap(p.p), s0, dir)) }
        check(dev < 0.001, "straight edge: the stroke runs parallel to the ruler through its start point")
        BrushSelfTest.stroke(d, id, brush, wobbly(s0, s0 + dir * 200 + n * 25), fg: RGBA(hex: "1F3A93")!)

        // ellipse ruler: points stay on the (scaled) ellipse
        let (c, u, v) = ellipse.ellipseAxes
        let e0 = c + u * cos(0.3) * 1.08 + v * sin(0.3) * 1.08
        var es = AssistSnapper(start: e0, guide: DrawingGuide(), rulers: d.state.artist.rulers, rulerRange: range, threshold: 5)
        check(es.rulerID == ellipse.id, "a stroke starting near the ellipse attaches to it")
        var edev: CGFloat = 0
        var epts: [PenSample] = []
        for i in 0...90 {
            let a = 0.3 + CGFloat(i) / 90 * 4.5
            let wob = 1.08 + 0.12 * sin(a * 6)
            let raw = c + u * cos(a) * wob + v * sin(a) * wob
            epts.append(PenSample(p: raw))
            let q = es.snap(raw)
            let x = (q - c).dot(u) / (u.length * u.length), y = (q - c).dot(v) / (v.length * v.length)
            edev = max(edev, abs((x * x + y * y).squareRoot() - 1.08))
        }
        check(edev < 0.0001, "ellipse ruler: the stroke follows a concentric ellipse")
        BrushSelfTest.stroke(d, id, brush, epts, fg: RGBA(hex: "16A085")!)

        // French curve: constant offset from the curve
        let poly = curve.polyline(segments: 160)
        let mid = curve.bezier(0.2)
        let c0 = mid + CGPoint(x: 0, y: 8)
        var cs = AssistSnapper(start: c0, guide: DrawingGuide(), rulers: d.state.artist.rulers, rulerRange: range, threshold: 5)
        check(cs.rulerID == curve.id, "a stroke starting near the French curve attaches to it")
        let off0 = AssistGeometry.nearest(on: poly, to: c0).distance
        var cdev: CGFloat = 0
        var cpts: [PenSample] = []
        for i in 0...80 {
            let t = 0.2 + CGFloat(i) / 80 * 0.7
            let raw = curve.bezier(t) + CGPoint(x: 6 * sin(CGFloat(i) * 0.5), y: 8 + 9 * cos(CGFloat(i) * 0.4))
            cpts.append(PenSample(p: raw))
            cdev = max(cdev, abs(AssistGeometry.nearest(on: poly, to: cs.snap(raw)).distance - off0))
        }
        check(cdev < 1.5, "French curve: the stroke keeps its distance from the curve (max drift \(String(format: "%.2f", cdev)) px)")
        BrushSelfTest.stroke(d, id, brush, cpts, fg: RGBA(hex: "C0392B")!)

        // far from every ruler: no attachment; rulers win over a guide when near
        let farStart = CGPoint(x: 480, y: 330)
        let far = AssistSnapper(start: farStart, guide: DrawingGuide(), rulers: d.state.artist.rulers, rulerRange: range, threshold: 5)
        check(far.rulerID == nil && !far.isActive, "a stroke started away from the rulers is free")
        let both = AssistSnapper(start: s0, guide: DrawingGuide.standard(.grid, width: W, height: H), rulers: d.state.artist.rulers, rulerRange: range, threshold: 5)
        check(both.rulerID == straight.id, "rulers take precedence over the drawing guide near them")

        // handles: end points, move handle, ellipse axes stay perpendicular
        var data = d.state.artist
        GuideEditor.move(.rulerMove(straight.id), to: .zero, delta: CGPoint(x: 10, y: -5), in: &data)
        check(data.rulers[0].points[0] == CGPoint(x: 70, y: 295) && data.rulers[0].points[1] == CGPoint(x: 310, y: 245), "move handle shifts the whole ruler")
        GuideEditor.move(.ruler(ellipse.id, 1), to: CGPoint(x: 360, y: 30), delta: .zero, in: &data)
        let (_, u2, v2) = data.rulers[1].ellipseAxes
        check(abs(u2.dot(v2)) < 0.001 && abs(v2.length - v.length) < 0.001, "rotating the ellipse keeps its axes perpendicular and its size")
        check(GuideEditor.handles(for: curve).count == 5 && GuideEditor.handles(for: straight).count == 3, "ruler handles")
        savePNG(guideImage(d.state), "artist_assist_rulers", out)
        ArtistContext.testDoc = nil
    }

    // MARK: Stabiliser

    static func stabiliser(_ out: URL) {
        let app = AppModel.shared
        app.tool = .brush
        let settings = ArtistSettings.shared
        settings.prefs = ArtistPrefs()
        settings.assist = false
        let (d, id) = ToolsSelfTest.whiteDoc(560, 330, name: "stab")
        ArtistContext.testDoc = d
        let brush = BrushSelfTest.brush(size: 5, hardness: 1, spacing: 0.1)
        // a jittery hand: a slow arc with fast zig-zag noise
        func jitter(_ dy: CGFloat) -> [CGPoint] {
            (0...140).map { i in
                let t = CGFloat(i) / 140
                return CGPoint(x: 40 + 470 * t + 5 * sin(CGFloat(i) * 2.1), y: dy + 40 * sin(t * .pi) + 7 * cos(CGFloat(i) * 2.9))
            }
        }
        func length(_ p: [CGPoint]) -> CGFloat { zip(p, p.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) } }
        func turning(_ p: [CGPoint]) -> CGFloat {
            var sum: CGFloat = 0
            for i in 1..<max(1, p.count - 1) {
                let a = p[i] - p[i - 1], b = p[i + 1] - p[i]
                if a.length < 0.01 || b.length < 0.01 { continue }
                sum += abs(atan2(a.x * b.y - a.y * b.x, a.dot(b)))
            }
            return sum
        }
        let eng = BrushDynamicsEngine(settings: brush, target: PixelBuffer(width: 8, height: 8), origin: .zero, paint: .fixed(.black))
        let raw = jitter(50)

        settings.prefs.stabilizer = .off
        check(BrushAssist.filter(raw, engine: eng) == raw, "stabiliser off: input untouched")

        settings.prefs.stabilizer = .rope
        settings.prefs.ropeLength = 30
        settings.prefs.catchUp = true
        let rope = BrushAssist.filter(raw, engine: eng)
        check(length(rope) < length(raw) * 0.6 && turning(rope) < turning(raw) * 0.35, "lazy rope removes the jitter (path \(Int(length(raw))) → \(Int(length(rope))) px, turning \(Int(turning(raw))) → \(Int(turning(rope))) rad)")
        check(rope.last == raw.last, "catch-up: the stroke ends at the pen position")
        settings.prefs.catchUp = false
        let ropeNo = BrushAssist.filter(raw, engine: eng)
        let gap = ropeNo.last!.distance(to: raw.last!)
        check(abs(gap - 30) < 0.5, "without catch-up the stroke stops a rope length behind the pen (\(String(format: "%.1f", gap)) px)")
        // the rope never lets the brush get further than the leash, and never moves it while the pen stays inside
        var tip = raw[0], ok = true
        let e2 = BrushDynamicsEngine(settings: brush, target: PixelBuffer(width: 8, height: 8), origin: .zero, paint: .fixed(.black))
        _ = BrushAssist.process(e2, PenSample(p: raw[0]), .begin)
        for p in raw.dropFirst().dropLast() {
            let r = BrushAssist.process(e2, PenSample(p: p), .move) ?? []
            if let l = r.last { tip = l.p }
            if tip.distance(to: p) > 30.01 { ok = false }
            if r.isEmpty && tip.distance(to: p) > 30.01 { ok = false }
        }
        _ = BrushAssist.process(e2, PenSample(p: raw.last!), .end)
        check(ok, "the brush is always within one rope length of the pen")
        check(BrushAssist.leash == nil, "the leash overlay ends with the stroke")
        let e3 = BrushDynamicsEngine(settings: brush, target: PixelBuffer(width: 8, height: 8), origin: .zero, paint: .fixed(.black))
        _ = BrushAssist.process(e3, PenSample(p: raw[0]), .begin)
        _ = BrushAssist.process(e3, PenSample(p: raw[0] + CGPoint(x: 80, y: 0)), .move)
        check(BrushAssist.leash.map { abs($0.tip.distance(to: $0.pen) - 30) < 0.01 } ?? false, "leash overlay reports brush and pen positions")
        _ = BrushAssist.process(e3, PenSample(p: raw[0]), .end)

        settings.prefs.stabilizer = .average
        settings.prefs.averageWindow = 14
        settings.prefs.catchUp = true
        let avg = BrushAssist.filter(raw, engine: eng)
        check(turning(avg) < turning(raw) * 0.35 && avg.last!.distance(to: raw.last!) < 0.001, "weighted average smooths the stroke and catches up at the end")

        // render: raw, rope, average
        settings.prefs.stabilizer = .off
        BrushSelfTest.stroke(d, id, brush, jitter(50).map { PenSample(p: $0) }, fg: RGBA(hex: "C0392B")!)
        settings.prefs.stabilizer = .rope
        BrushSelfTest.stroke(d, id, brush, jitter(140).map { PenSample(p: $0) }, fg: RGBA(hex: "1F3A93")!)
        settings.prefs.stabilizer = .average
        BrushSelfTest.stroke(d, id, brush, jitter(230).map { PenSample(p: $0) }, fg: RGBA(hex: "16A085")!)
        savePNG(drawImage(CGSize(width: 560, height: 330)) { ctx in
            ctx.saveGState(); ctx.translateBy(x: 0, y: 330); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(composite(d.state).makeCGImage(), in: CGRect(x: 0, y: 0, width: 560, height: 330)); ctx.restoreGState()
            ArtistOverlays.drawLeash(ctx, tip: CGPoint(x: 300, y: 300), pen: CGPoint(x: 330, y: 288), length: 32)
        }, "artist_stabilizer", out)
        settings.prefs = ArtistPrefs()
        ArtistContext.testDoc = nil
    }

    // MARK: Palette colour jitter

    static func paletteJitter(_ out: URL) {
        let app = AppModel.shared
        app.tool = .brush
        let settings = ArtistSettings.shared
        settings.prefs = ArtistPrefs()
        let pal = [RGBA(hex: "E63946")!, RGBA(hex: "2A9D8F")!, RGBA(hex: "E9C46A")!, RGBA(hex: "264653")!]
        let g = SwatchGroupStore.shared.add(name: "Jitter Test", colors: pal)
        settings.prefs.paletteGroup = g.id
        let (d, id) = ToolsSelfTest.whiteDoc(420, 200, name: "jitter")
        ArtistContext.testDoc = d
        let brush = BrushSelfTest.brush(size: 22, hardness: 1, spacing: 1.15)
        /// Fully opaque pixels in `r`, named by the palette colour they match ("other" when none does).
        func colours(in r: IRect) -> Set<String> {
            guard let buf = d.state.layer(id)?.raster?.buffer else { return [] }
            var out = Set<String>()
            for y in r.minY..<r.maxY { for x in r.minX..<r.maxX where buf.alpha(x, y) == 255 {
                let c = pixel(buf, x, y)
                out.insert((pal + [.black]).first { near($0, c, 2) }?.hex ?? "other")
            } }
            return out
        }
        settings.prefs.paletteJitter = .perDab
        BrushAssist.reseed(7)
        BrushSelfTest.stroke(d, id, brush, [PenSample(p: CGPoint(x: 30, y: 50)), PenSample(p: CGPoint(x: 390, y: 50))], fg: .black)
        let perDab = colours(in: IRect(x: 0, y: 30, width: 420, height: 40))
        check(perDab.count >= 3 && perDab.isSubset(of: Set(pal.map(\.hex))), "per-dab jitter paints dabs in colours of the swatch group (\(perDab.sorted()))")
        settings.prefs.paletteJitter = .perStroke
        var strokeColours = Set<String>()
        for i in 0..<6 {
            let y = 100 + i * 16
            BrushSelfTest.stroke(d, id, BrushSelfTest.brush(size: 10, hardness: 1, spacing: 0.2), [PenSample(p: CGPoint(x: 30, y: y)), PenSample(p: CGPoint(x: 390, y: y))], fg: .black)
            let c = colours(in: IRect(x: 40, y: y - 2, width: 340, height: 4))
            check(c.count == 1 && c.isSubset(of: Set(pal.map(\.hex))), "per-stroke jitter uses one palette colour for the whole stroke (\(c.sorted()))")
            strokeColours.formUnion(c)
        }
        check(strokeColours.count >= 2, "different strokes pick different palette colours (\(strokeColours.count))")
        settings.prefs.paletteJitter = .off
        BrushSelfTest.stroke(d, id, BrushSelfTest.brush(size: 6, hardness: 1), [PenSample(p: CGPoint(x: 30, y: 12)), PenSample(p: CGPoint(x: 390, y: 12))], fg: .black)
        check(colours(in: IRect(x: 40, y: 11, width: 300, height: 2)) == ["000000"], "jitter off paints the foreground colour")
        settings.prefs.paletteGroup = nil
        check(BrushAssist.palette == app.swatches, "without a group the Swatches panel colours are used")
        SelfTest.save(d.state, "artist_palette_jitter", out)
        settings.prefs = ArtistPrefs()
        ArtistContext.testDoc = nil
    }

    // MARK: Harmony

    static func harmony(_ out: URL) {
        func hues(_ s: HarmonyScheme, _ h: Double) -> [Int] { ColorHarmony.hues(s, baseHue: h).map { Int($0.rounded()) } }
        check(hues(.complementary, 30) == [30, 210], "complementary: +180° (\(hues(.complementary, 30)))")
        check(hues(.analogous, 30) == [30, 0, 60], "analogous: ±30°")
        check(hues(.triadic, 30) == [30, 150, 270], "triadic: 120° apart")
        check(hues(.tetradic, 30) == [30, 90, 210, 270], "tetradic: rectangle 60° / 180° / 240°")
        check(hues(.square, 300) == [300, 30, 120, 210], "square: 90° apart, wrapping past 360°")
        check(hues(.split, 30) == [30, 180, 240], "split complementary: 180° ± 30°")
        check(hues(.analogous, 10) == [10, 340, 40], "hues wrap below 0°")
        let comp = ColorHarmony.colors(.complementary, base: .red)
        check(comp.count == 2 && comp[0] == .red && near(comp[1], RGBA(hex: "00FFFF")!, 1), "complement of red is cyan")
        let tri = ColorHarmony.colors(.triadic, base: RGBA(hex: "FF0000")!)
        check(near(tri[1], RGBA(hex: "00FF00")!, 1) && near(tri[2], RGBA(hex: "0000FF")!, 1), "triad of red is green and blue")
        let base = RGBA(hex: "3A7BD5")!
        let mono = ColorHarmony.colors(.monochrome, base: base)
        check(mono.count == 5 && mono.contains { $0.hex == base.hex } && mono.allSatisfy { abs($0.hsb.h - base.hsb.h) < 0.01 }, "monochrome keeps the hue and includes the base")
        check(zip(mono, mono.dropFirst()).allSatisfy { $0.hsb.b <= $1.hsb.b }, "monochrome runs dark → light")
        for s in HarmonyScheme.allCases {
            let set = ColorHarmony.swatchSet(s, base: base)
            let keys = ColorHarmony.colors(s, base: base)
            check(set.count <= 12 && set.count >= keys.count && Array(set.prefix(keys.count)) == keys && (s == .monochrome || keys[0].hex == base.hex), "\(s.title): swatch set of \(set.count) starts with the scheme colours")
        }
        let tet = ColorHarmony.colors(.tetradic, base: base)
        check(tet.allSatisfy { abs($0.hsb.s - base.hsb.s) < 0.02 && abs($0.hsb.b - base.hsb.b) < 0.02 }, "scheme colours keep the base saturation and brightness")
        let g = SwatchGroupStore.shared.add(name: "Triadic", colors: ColorHarmony.swatchSet(.triadic, base: base))
        SwatchGroupStore.shared.reload()
        check(SwatchGroupStore.shared.group(g.id)?.colors.count == 9, "“Save as swatch group” persists the set")
        // Oklab sanity
        let lab = Oklab(RGBA.white)
        check(abs(lab.L - 1) < 0.001 && abs(lab.a) < 0.001 && abs(lab.b) < 0.001, "Oklab: white is L=1, a=b=0")
        check([RGBA(hex: "E63946")!, RGBA(hex: "2A9D8F")!, RGBA(hex: "000000")!, RGBA(hex: "FFFFFF")!, RGBA(hex: "808080")!].allSatisfy { Oklab($0).rgba.hex == $0.hex }, "Oklab round-trips sRGB colours")
    }

    // MARK: Palette from image

    static func paletteExtraction(_ out: URL) {
        // known image: four flat colours covering 40 / 30 / 20 / 10 %
        let cols = [("1B2A49", 0.4), ("C8553D", 0.3), ("F2D0A9", 0.2), ("5FAD56", 0.1)]
        let W = 200, H = 100
        var st = DocumentState(width: W, height: H)
        let bg = PixelBuffer(width: W, height: H)
        var x = 0
        for (hex, f) in cols {
            let w = Int(Double(W) * f)
            bg.context.setFillColor(RGBA(hex: hex)!.cgColor); bg.context.fill(CGRect(x: x, y: 0, width: w, height: H))
            x += w
        }
        bg.markDirty()
        st.layers = [Layer.raster(name: "Background", buffer: bg)]
        let pal = PaletteTools.palette(st, source: .document, activeLayer: nil, count: 4)
        let expected = cols.map { RGBA(hex: $0.0)! }.sorted { Oklab($0).L < Oklab($1).L }
        check(pal.count == 4 && zip(pal, expected).allSatisfy { near($0.color, $1, 2) }, "k-means finds the four colours of the image, sorted dark → light (\(pal.map { $0.color.hex }))")
        let weights = Dictionary(pal.map { ($0.color.hex, $0.weight) }, uniquingKeysWith: { a, _ in a })
        check(cols.allSatisfy { c in pal.contains { near($0.color, RGBA(hex: c.0)!, 2) && abs($0.weight - c.1) < 0.03 } }, "palette weights match the areas (\(weights.values.map { String(format: "%.2f", $0) }.sorted()))")
        check(PaletteTools.palette(st, source: .document, activeLayer: nil, count: 9).count == 4, "asking for more colours than the image has returns only the distinct ones")
        let three = PaletteTools.palette(st, source: .document, activeLayer: nil, count: 3)
        check(three.count == 3 && abs(three.map(\.weight).reduce(0, +) - 1) < 0.001, "3-colour palette: weights sum to 1")
        // selection: only the right half (the last two colours and part of the second)
        st.selection = SelectionOps.rectMask(CGRect(x: 140, y: 0, width: 60, height: H), width: W, height: H)
        let sel = PaletteTools.palette(st, source: .selection, activeLayer: nil, count: 4)
        check(sel.count == 2 && sel.contains { near($0.color, RGBA(hex: "F2D0A9")!, 2) } && sel.contains { near($0.color, RGBA(hex: "5FAD56")!, 2) }, "palette from the selection only sees the selected pixels (\(sel.map { $0.color.hex }))")
        st.selection = nil
        // layer source
        var shape = SelfTest.shapeLayer(CGRect(x: 20, y: 20, width: 60, height: 60), RGBA(hex: "8E44AD")!, radius: 0)
        shape.name = "violet"
        st.layers.append(shape)
        let lay = PaletteTools.palette(st, source: .layer, activeLayer: shape.id, count: 3)
        check(lay.count == 1 && near(lay[0].color, RGBA(hex: "8E44AD")!, 2), "palette from the active layer ignores the other layers")
        st.layers.removeLast()

        // photo-like image: gradient + shapes; 3…12 colours
        var photo = SelfTest.baseState(320, 200)
        photo.layers.append(SelfTest.shapeLayer(CGRect(x: 30, y: 40, width: 110, height: 120), RGBA(hex: "E94F37")!))
        photo.layers.append(SelfTest.shapeLayer(CGRect(x: 180, y: 60, width: 110, height: 100), RGBA(hex: "1B1F3A")!, radius: 50))
        for n in [3, 6, 12] {
            let p = PaletteTools.palette(photo, source: .document, activeLayer: nil, count: n)
            check(p.count == n && zip(p, p.dropFirst()).allSatisfy { Oklab($0.color).L <= Oklab($1.color).L + 1e-9 }, "\(n)-colour palette of a photo-like image is sorted by lightness")
        }
        let p6 = PaletteTools.palette(photo, source: .document, activeLayer: nil, count: 6).map(\.color)
        check(p6.contains { near($0, RGBA(hex: "E94F37")!, 6) } && p6.contains { near($0, RGBA(hex: "1B1F3A")!, 6) }, "the dominant flat colours are found exactly")
        check(PaletteTools.palette(photo, source: .document, activeLayer: nil, count: 6).map(\.color) == p6, "palette extraction is deterministic")
        // gradient map from the palette
        let d = Document(state: photo, name: "pal")
        let before = d.history.count
        let id = PaletteTools.applyGradientMap(d, colors: p6)
        let adj = d.state.layer(id)?.adjustment
        check(adj?.kind == .gradientMap && adj?.gradient.stops.count == 6 && d.history.count == before + 1, "“Apply palette as gradient map” adds one Gradient Map layer")
        let mapped = composite(d.state)
        let allowed = p6
        var worst = 0.0
        for (px, py) in [(10, 10), (80, 100), (230, 110), (300, 190)] {
            let c = Oklab(pixel(mapped, px, py))
            // every mapped pixel lies on the palette gradient: between two neighbouring palette colours
            var best = Double.infinity
            for i in 0..<(allowed.count - 1) {
                for k in 0...20 { best = min(best, c.distance(Oklab(allowed[i].mix(allowed[i + 1], Double(k) / 20)))) }
            }
            worst = max(worst, best)
        }
        check(worst < 0.03, "gradient-mapped pixels lie on the palette gradient (max ΔOklab \(String(format: "%.3f", worst)))")
        SelfTest.save(d.state, "artist_palette_gradient_map", out)
        // add to swatches
        let app = AppModel.shared
        let n0 = app.swatches.count
        PaletteTools.addToSwatches(p6); PaletteTools.addToSwatches(p6)
        check(app.swatches.count == n0 + 6, "“Add to swatches” appends each colour once")
        // palette strip image
        savePNG(drawImage(CGSize(width: 320, height: 260)) { ctx in
            ctx.saveGState(); ctx.translateBy(x: 0, y: 200); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(composite(photo).makeCGImage(), in: CGRect(x: 0, y: 0, width: 320, height: 200)); ctx.restoreGState()
            for (i, c) in p6.enumerated() {
                ctx.setFillColor(c.cgColor)
                ctx.fill(CGRect(x: CGFloat(i) * 320 / 6, y: 204, width: 320 / 6, height: 56))
            }
        }, "artist_palette_from_image", out)
    }

    // MARK: Global colours

    static func globalColours(_ out: URL, _ tmp: URL) {
        var st = SelfTest.baseState(520, 320)
        let brand = RGBA(hex: "E94F37")!
        var a = SelfTest.shapeLayer(CGRect(x: 30, y: 30, width: 140, height: 110), RGBA(hex: "999999")!)
        a.name = "fill shape"
        var b = Layer(name: "stroke shape", content: .shape(ShapeContent(geometry: .rectangle(CGRect(x: 200, y: 30, width: 140, height: 110), cornerRadius: 55), fill: .color(.white),
                                                                         stroke: StrokeStyle(paint: .color(.black), width: 10))))
        b.effects.dropShadow.enabled = true; b.effects.dropShadow.opacity = 1; b.effects.dropShadow.distance = 10; b.effects.dropShadow.size = 2
        var t = TextContent()
        t.text = "Global"; t.fontName = "Helvetica-Bold"; t.fontSize = 64; t.color = .black; t.position = CGPoint(x: 30, y: 170)
        let text = Layer(name: "text", content: .text(t))
        var fill = Layer(name: "fill", content: .fill(FillContent(paint: .color(RGBA(hex: "444444")!))))
        let m = PixelBuffer(width: 520, height: 320, format: .gray)
        m.context.setFillColor(gray: 1, alpha: 1); m.context.fill(CGRect(x: 370, y: 30, width: 120, height: 260)); m.markDirty()
        fill.mask = LayerMask(buffer: m, origin: .zero, outsideValue: 0)
        var overlay = Layer.raster(name: "pixels", buffer: PixelBuffer(cgImage: solidImage(520, 320) { c in
            c.setFillColor(RGBA(hex: "2E86DE")!.cgColor); c.fillEllipse(in: CGRect(x: 250, y: 190, width: 90, height: 90))
        }))
        overlay.effects.colorOverlay.enabled = true
        st.layers += [a, b, text, fill, overlay]
        let d = Document(state: st, name: "globals")
        let gid = GlobalColors.add(d, color: brand, name: "Brand")
        check(d.state.artist.globals.count == 1 && GlobalColors.usageCount(d.state, gid) == 0, "new global colour with no usages")
        SelfTest.save(d.state, "artist_globals_before", out)
        GlobalColors.assign(d, layer: a.id, slot: .shapeFill, global: gid)
        GlobalColors.assign(d, layer: b.id, slot: .shapeStroke, global: gid)
        GlobalColors.assign(d, layer: b.id, slot: .dropShadow, global: gid)
        GlobalColors.assign(d, layer: text.id, slot: .textColor, global: gid)
        GlobalColors.assign(d, layer: fill.id, slot: .fillLayer, global: gid)
        GlobalColors.assign(d, layer: overlay.id, slot: .colorOverlay, global: gid)
        check(GlobalColors.usageCount(d.state, gid) == 6, "usage count after assigning to fill, stroke, shadow, text, fill layer and colour overlay (\(GlobalColors.usageCount(d.state, gid)))")
        func colours(_ s: DocumentState) -> [String] {
            [GlobalColors.color(s.layer(a.id)!, .shapeFill), GlobalColors.color(s.layer(b.id)!, .shapeStroke), GlobalColors.color(s.layer(b.id)!, .dropShadow),
             GlobalColors.color(s.layer(text.id)!, .textColor), GlobalColors.color(s.layer(fill.id)!, .fillLayer), GlobalColors.color(s.layer(overlay.id)!, .colorOverlay)].map { $0?.hex ?? "nil" }
        }
        check(colours(d.state).allSatisfy { $0 == brand.hex }, "assigning applies the global colour to every property")
        check(GlobalColors.link(d.state, layer: text.id, slot: .textColor)?.name == "Brand", "a linked property reports its global")
        GlobalColors.assign(d, layer: a.id, slot: .textColor, global: gid)
        check(GlobalColors.usageCount(d.state, gid) == 6, "a layer without the property cannot be linked")
        SelfTest.save(d.state, "artist_globals_linked", out)

        // edit: one history step, everything follows, rendered pixels too
        let h = d.history.count
        let teal = RGBA(hex: "0FA3B1")!
        GlobalColors.setColor(d, gid, teal)
        check(d.history.count == h + 1, "editing a global colour is a single history step")
        check(colours(d.state).allSatisfy { $0 == teal.hex } && d.state.artist.globals[0].color.hex == teal.hex, "editing the global updates all six usages")
        let comp = composite(d.state)
        check(near(pixel(comp, 100, 85), teal, 2) && near(pixel(comp, 430, 160), teal, 2) && near(pixel(comp, 295, 235), teal, 2), "the rendered shape, fill layer and colour overlay show the new colour")
        SelfTest.save(d.state, "artist_globals_edited", out)
        d.undo()
        check(colours(d.state).allSatisfy { $0 == brand.hex } && d.state.artist.globals[0].color.hex == brand.hex, "one undo restores the global and every usage")
        d.redo()
        check(colours(d.state).allSatisfy { $0 == teal.hex }, "redo re-applies the edit")

        // live preview without history, then revert
        let h2 = d.history.count
        GlobalColors.setColor(d, gid, RGBA(hex: "FF00FF")!, commit: false)
        check(d.history.count == h2 && colours(d.state).allSatisfy { $0 == "FF00FF" }, "live preview updates usages without a history step")
        d.revertUncommitted()
        check(colours(d.state).allSatisfy { $0 == teal.hex }, "cancelling the preview restores the colours")
        // alpha of a usage is kept
        d.updateLayer(a.id) { $0.shape?.fill = .color(teal.withAlpha(0.5)) }
        d.commit("half")
        GlobalColors.setColor(d, gid, brand)
        check(d.state.layer(a.id)?.shape?.fill.solidColor?.a == 0.5 && GlobalColors.usageCount(d.state, gid) == 6, "a usage keeps its own opacity and stays linked")

        // manual override detaches; deleting a layer drops its links; disabling an effect keeps the link
        d.updateLayer(b.id) { $0.shape?.stroke.paint = .color(.black) }
        d.commit("manual")
        check(GlobalColors.usageCount(d.state, gid) == 5 && GlobalColors.link(d.state, layer: b.id, slot: .shapeStroke) == nil, "changing a property by hand detaches it from the global")
        d.updateLayer(b.id) { $0.effects.dropShadow.enabled = false }
        check(GlobalColors.usageCount(d.state, gid) == 5, "switching an effect off keeps its link")
        d.state.removeLayer(fill.id)
        d.commit("delete")
        check(GlobalColors.usageCount(d.state, gid) == 4, "deleting a layer removes its usages")
        GlobalColors.setColor(d, gid, RGBA(hex: "6A4C93")!)
        check(d.state.layer(b.id)?.shape?.stroke.paint.solidColor?.hex == "000000" && d.state.layer(a.id)?.shape?.fill.solidColor?.hex == "6A4C93", "detached properties no longer follow the global")
        check(d.state.artist.links.count == 4, "stale links are pruned from the table")

        // persistence
        let url = tmp.appendingPathComponent("globals.imagecrat")
        try? DocumentIO.saveNative(d, to: url)
        if let back = try? DocumentIO.load(url: url) {
            check(back.state.artist.globals == d.state.artist.globals && back.state.artist.links == d.state.artist.links, "globals and links are saved with the document")
            GlobalColors.setColor(back, gid, .red)
            check(back.state.layer(text.id)?.text?.color.hex == "FF0000", "links keep working after reopening")
        } else { check(false, "document with globals reloads") }
        GlobalColors.rename(d, gid, "Accent")
        check(d.state.artist.globals[0].name == "Accent", "rename")
        GlobalColors.unlink(d, layer: text.id, slot: .textColor)
        check(GlobalColors.usageCount(d.state, gid) == 3, "unlink")
        GlobalColors.delete(d, gid)
        check(d.state.artist.globals.isEmpty && d.state.artist.links.isEmpty && d.state.layer(a.id)?.shape?.fill.solidColor?.hex == "6A4C93", "deleting a global keeps the colours but removes the links")
    }

    // MARK: Recolour

    static func recolour(_ out: URL) {
        let from = [RGBA(hex: "E94F37")!, RGBA(hex: "1B1F3A")!, RGBA(hex: "F6AE2D")!]
        let to = [RGBA(hex: "2A9D8F")!, RGBA(hex: "3D0066")!, RGBA(hex: "FFB4A2")!]
        let map = RecolorMap(from: from, to: to)
        check(zip(from, to).allSatisfy { map.map($0).hex == $1.hex }, "source colours map exactly onto their targets")
        let between = map.map(from[0].mix(from[2], 0.5))
        let mid = Oklab(between)
        check(mid.distance(Oklab(to[0])) < mid.distance(Oklab(to[1])) && mid.distance(Oklab(to[2])) < mid.distance(Oklab(to[1])), "colours in between move smoothly between the targets")
        let keep = RecolorMap(from: from, to: to, preserveLuminance: true)
        check(from.allSatisfy { abs(Oklab(keep.map($0)).L - Oklab($0).L) < 0.02 } && keep.map(from[0]).hex != from[0].hex, "preserve luminance keeps the lightness and changes the hue")
        check(RecolorMap(lookName: map.lookName) == map && RecolorMap(lookName: keep.lookName) == keep && RecolorMap(lookName: "Warm Film") == nil, "mapping round-trips through the Colour Lookup name")
        check(RecolorMap(from: from, to: from).isIdentity && !map.isIdentity, "identity detection")
        let alpha = map.map(from[0].withAlpha(0.4))
        check(alpha.a == 0.4 && alpha.withAlpha(1).hex == to[0].hex, "alpha is preserved")

        // artwork: two shapes, text, a fill layer and a pixel layer painted with the same colours
        var st = DocumentState(width: 520, height: 300)
        let bg = PixelBuffer(width: 520, height: 300)
        bg.context.setFillColor(RGBA.white.cgColor); bg.context.fill(CGRect(x: 0, y: 0, width: 520, height: 300)); bg.markDirty()
        let px = PixelBuffer(width: 520, height: 300)
        px.context.setFillColor(from[0].cgColor); px.context.fill(CGRect(x: 300, y: 30, width: 90, height: 90))
        px.context.setFillColor(from[1].cgColor); px.context.fillEllipse(in: CGRect(x: 400, y: 30, width: 90, height: 90))
        px.context.setFillColor(from[2].cgColor); px.context.fill(CGRect(x: 300, y: 150, width: 190, height: 50))
        px.markDirty()
        let pixels = Layer.raster(name: "pixels", buffer: px)
        var s1 = SelfTest.shapeLayer(CGRect(x: 30, y: 30, width: 110, height: 90), from[0]); s1.name = "red"
        var s2 = Layer(name: "navy", content: .shape(ShapeContent(geometry: .rectangle(CGRect(x: 160, y: 30, width: 110, height: 90), cornerRadius: 45), fill: .color(from[1]),
                                                                  stroke: StrokeStyle(paint: .color(from[2]), width: 8))))
        s2.effects.colorOverlay.enabled = false
        var t = TextContent()
        t.text = "Recolour"; t.fontName = "Helvetica-Bold"; t.fontSize = 44; t.color = from[1]; t.position = CGPoint(x: 30, y: 150)
        t.runs = [TextStyleRun(location: 0, length: 2, style: CharacterStyle(color: from[0]))]
        let text = Layer(name: "text", content: .text(t))
        st.layers = [Layer.raster(name: "Background", buffer: bg), pixels, s1, s2, text]
        SelfTest.save(st, "artist_recolor_before", out)

        let src = Recolor.sourcePalette(st, scope: .document, selected: [], count: 6)
        check(from.allSatisfy { f in src.contains { $0.hex == f.hex } }, "the artwork palette contains the vector colours exactly (\(src.map(\.hex)))")
        check(src.contains { near($0, .white, 3) }, "…and the dominant raster colours (white background)")
        check(src.count <= 6 && Set(src.map(\.hex)).count == src.count, "palette entries are unique and capped")

        // the dialog maps the whole extracted palette: the three artwork colours change, white stays
        let full = RecolorMap(from: src, to: src.map { c in from.firstIndex { $0.hex == c.hex }.map { to[$0] } ?? c })
        var after = st
        Recolor.apply(full, to: &after, scope: .document, selected: [])
        check(after.layer(s1.id)?.shape?.fill.solidColor?.hex == to[0].hex && after.layer(s2.id)?.shape?.fill.solidColor?.hex == to[1].hex
              && after.layer(s2.id)?.shape?.stroke.paint.solidColor?.hex == to[2].hex, "shape fills and strokes are recoloured in place (still live shapes)")
        check(after.layer(text.id)?.text?.color.hex == to[1].hex && after.layer(text.id)?.text?.runs.first?.style.color?.hex == to[0].hex && after.layer(text.id)?.isText == true,
              "type stays editable: layer colour and styled runs are remapped")
        let sib = after.layers
        let pi = sib.firstIndex { $0.id == pixels.id }!
        let adj = sib[pi + 1]
        check(adj.isClipped && adj.adjustment?.kind == .colorLookup && (adj.adjustment?.lookName.hasPrefix(RecolorMap.lookPrefix) ?? false) && after.layer(pixels.id)?.raster?.buffer === px,
              "pixel layers get a clipped Colour Lookup adjustment; the pixels are untouched")
        let comp = composite(after)
        let got = [pixel(comp, 345, 75), pixel(comp, 445, 75), pixel(comp, 395, 175)]
        check(zip(got, to).allSatisfy { near($0, $1, 10) }, "the adjustment recolours the raster artwork (\(got.map(\.hex)) ≈ \(to.map(\.hex)))")
        check(near(pixel(comp, 5, 5), .white, 3), "colours mapped onto themselves (the white background) stay put")
        SelfTest.save(after, "artist_recolor_after", out)
        // re-applying updates the existing adjustment instead of stacking another one
        var again = after
        let map2 = RecolorMap(from: to, to: [RGBA(hex: "FF006E")!, to[1], to[2]])
        Recolor.apply(map2, to: &again, scope: .document, selected: [])
        check(again.layers.count == after.layers.count, "recolouring again reuses the Recolour adjustment")
        // scope: selected layers only
        var part = st
        Recolor.apply(map, to: &part, scope: .selectedLayers, selected: [s1.id])
        check(part.layer(s1.id)?.shape?.fill.solidColor?.hex == to[0].hex && part.layer(s2.id)?.shape?.fill.solidColor?.hex == from[1].hex && part.layers.count == st.layers.count,
              "“Selected layers” leaves the rest of the document alone")
        var vecOnly = st
        Recolor.apply(map, to: &vecOnly, scope: .document, selected: [], vector: true, raster: false)
        check(vecOnly.layers.count == st.layers.count, "raster recolouring can be switched off")
        // harmony targets keep saturation / brightness and spread the hues over the scheme
        let targets = Recolor.harmonyTargets(from, scheme: .triadic, base: RGBA(hex: "0077FF")!)
        let schemeHues = ColorHarmony.colors(.triadic, base: RGBA(hex: "0077FF")!).map { Int(($0.hsb.h * 360).rounded()) }
        check(targets.count == 3 && targets.allSatisfy { schemeHues.contains(Int(($0.hsb.h * 360).rounded())) } && Set(targets.map { Int(($0.hsb.h * 360).rounded()) }).count == 3,
              "harmony rule assigns each colour a hue of the scheme")
        check(zip(from, targets).allSatisfy { abs($0.hsb.b - $1.hsb.b) < 0.01 && abs($0.hsb.s - $1.hsb.s) < 0.01 }, "harmony targets keep saturation and brightness")
        // recolouring with preserved luminance
        var lum = st
        Recolor.apply(keep, to: &lum, scope: .document, selected: [])
        SelfTest.save(lum, "artist_recolor_preserve_luminance", out)
        // undo: a document-level recolour is one step
        let d = Document(state: st, name: "recolor")
        var applied = d.committedState
        Recolor.apply(map, to: &applied, scope: .document, selected: [])
        d.state = applied
        d.commit("Recolour Artwork")
        d.undo()
        check(d.state.layers.count == st.layers.count && d.state.layer(s1.id)?.shape?.fill.solidColor?.hex == from[0].hex, "recolour is a single undoable step")
    }

    // MARK: Contrast

    static func contrast(_ out: URL) {
        func c(_ a: String, _ b: String) -> Double { WCAG.contrast(RGBA(hex: a)!, RGBA(hex: b)!) }
        check(abs(c("777777", "FFFFFF") - 4.48) < 0.005, "#777 on #fff = \(String(format: "%.2f", c("777777", "FFFFFF"))) : 1 (expected 4.48)")
        check(abs(c("000000", "FFFFFF") - 21) < 0.001, "black on white = 21 : 1")
        check(abs(c("767676", "FFFFFF") - 4.54) < 0.005, "#767676 on #fff = \(String(format: "%.2f", c("767676", "FFFFFF"))) (the lightest grey that passes AA)")
        check(abs(c("FF0000", "FFFFFF") - 4.0) < 0.005 && abs(c("0000FF", "FFFFFF") - 8.59) < 0.005, "red / blue on white = 4.00 / 8.59")
        check(abs(c("FFFF00", "0000FF") - 8.0) < 0.005 && c("123456", "123456") == 1, "yellow on blue = 8.00; identical colours = 1")
        check(abs(c("FFFFFF", "777777") - c("777777", "FFFFFF")) < 1e-12, "contrast is symmetric")
        check(WCAG.level(4.48, largeText: false) == .aaLarge && WCAG.level(4.5, largeText: false) == .aa && WCAG.level(7, largeText: false) == .aaa && WCAG.level(2.9, largeText: false) == .fail,
              "badges for normal text: <3 fail, ≥3 AA Large, ≥4.5 AA, ≥7 AAA")
        check(WCAG.level(4.496, largeText: false) == .aaLarge, "4.496 is not rounded up to a pass")
        check(WCAG.level(3.1, largeText: true) == .aa && WCAG.level(4.6, largeText: true) == .aaa && WCAG.isLarge(fontSize: 24, bold: false) && WCAG.isLarge(fontSize: 19, bold: true) && !WCAG.isLarge(fontSize: 19, bold: false),
              "large text (≥ 24 px, or ≥ 18.66 px bold) uses 3 / 4.5")
        // nearest passing colour
        let grey = RGBA(hex: "777777")!
        if let s = WCAG.nearestPassing(grey, on: [.white], target: 4.5) {
            check(WCAG.contrast(s, .white) >= 4.5 && WCAG.contrast(s, .white) < 4.6 && abs(s.r8 - grey.r8) <= 3, "nearest AA colour for #777 on white is a hair darker (#\(s.hex), \(String(format: "%.2f", WCAG.contrast(s, .white))))")
        } else { check(false, "nearest passing colour exists for #777 on white") }
        let orange = RGBA(hex: "FF8C42")!
        if let s = WCAG.nearestPassing(orange, on: [.white], target: 7) {
            let o = Oklab(orange), n = Oklab(s)
            var dh = abs(o.hue - n.hue); dh = min(dh, 360 - dh)
            check(WCAG.contrast(s, .white) >= 7 && dh < 12 && n.L < o.L, "AAA suggestion keeps the hue and darkens (#\(s.hex), Δhue \(Int(dh))°)")
        } else { check(false, "AAA suggestion for orange on white") }
        let onDark = WCAG.nearestPassing(RGBA(hex: "444466")!, on: [RGBA(hex: "222233")!], target: 4.5)
        check(onDark.map { WCAG.contrast($0, RGBA(hex: "222233")!) >= 4.5 && Oklab($0).L > Oklab(RGBA(hex: "444466")!).L } ?? false, "on a dark background the suggestion goes lighter (#\(onDark?.hex ?? "nil"))")
        check(WCAG.nearestPassing(.black, on: [.white], target: 4.5) == .black, "a passing colour is returned unchanged")
        let both = WCAG.nearestPassing(RGBA(hex: "808080")!, on: [.black, .white], target: 7)
        check(both == nil, "no colour reaches 7 : 1 against both black and white")

        // text layer against what is beneath it
        var st = DocumentState(width: 520, height: 260)
        let bg = PixelBuffer(width: 520, height: 260)
        bg.context.setFillColor(RGBA.white.cgColor); bg.context.fill(CGRect(x: 0, y: 0, width: 520, height: 260)); bg.markDirty()
        let panel = SelfTest.shapeLayer(CGRect(x: 0, y: 130, width: 520, height: 130), RGBA(hex: "1B2A49")!, radius: 0)
        var t = TextContent()
        t.text = "Readable?"; t.fontName = "Helvetica"; t.fontSize = 20; t.color = grey; t.position = CGPoint(x: 30, y: 40)
        let onWhite = Layer(name: "on white", content: .text(t))
        var t2 = t
        t2.position = CGPoint(x: 30, y: 170); t2.color = RGBA(hex: "33415C")!; t2.fontSize = 40; t2.fontName = "Helvetica-Bold"
        let onNavy = Layer(name: "on navy", content: .text(t2))
        // something above the text must not count as "beneath"
        let above = SelfTest.shapeLayer(CGRect(x: 400, y: 20, width: 100, height: 60), RGBA(hex: "00FF00")!, radius: 0)
        st.layers = [Layer.raster(name: "Background", buffer: bg), panel, onWhite, onNavy, above]
        if let r = ContrastChecker.report(st, layerID: onWhite.id) {
            check(abs(r.ratio - 4.48) < 0.02 && abs(r.worstRatio - 4.48) < 0.02 && near(r.background, .white, 1), "type layer: #777 text over white measures \(String(format: "%.2f", r.worstRatio)) : 1")
            check(r.level == .aaLarge && !r.largeText && r.suggestionAA != nil && r.suggestionAAA != nil, "badge for 20 px #777 text on white: \(r.level.rawValue)")
            if let s = r.suggestionAA { check(WCAG.contrast(s, .white) >= 4.5, "suggested AA colour passes (#\(s.hex))") }
        } else { check(false, "contrast report for the text on white") }
        if let r = ContrastChecker.report(st, layerID: onNavy.id) {
            check(near(r.background, RGBA(hex: "1B2A49")!, 2) && r.largeText && r.level == .fail, "text over the navy panel is measured against the panel (\(String(format: "%.2f", r.worstRatio)) : 1, \(r.level.rawValue))")
            if let s = r.suggestionAA {
                check(WCAG.contrast(s, RGBA(hex: "1B2A49")!) >= 3, "suggestion for large text passes 3 : 1 against the panel (#\(s.hex))")
                let d = Document(state: st, name: "contrast")
                let h = d.history.count
                ContrastChecker.apply(d, layerID: onNavy.id, color: s)
                check(d.history.count == h + 1 && ContrastChecker.report(d.state, layerID: onNavy.id).map { $0.level != .fail } == true, "applying the suggestion fixes the badge in one step")
                SelfTest.save(d.state, "artist_contrast_fixed", out)
            }
        } else { check(false, "contrast report for the text on navy") }
        check(ContrastChecker.report(st, layerID: panel.id) == nil, "no report for layers that are not type")
        check(ContrastChecker.beneath(st.layers, onWhite.id)?.count == 2, "only the layers beneath the text are considered")
        // inside a group
        var inner = t; inner.color = .white
        let innerText = Layer(name: "inner", content: .text(inner))
        var grouped = st
        grouped.layers = [Layer.raster(name: "Background", buffer: bg), Layer(name: "G", content: .group(GroupContent(children: [panel, innerText])))]
        check(ContrastChecker.beneath(grouped.layers, innerText.id).map { $0.count == 2 && $0[1].children.count == 1 } == true, "text inside a group: siblings beneath it are kept")
        SelfTest.save(st, "artist_contrast", out)
    }

    // MARK: Vision simulation

    static func simulation(_ out: URL) {
        for m in [VisionSimulation.protanopia, .deuteranopia, .tritanopia, .achromatopsia] {
            let mat = m.matrix!
            let sums: [Double] = (0..<3).map { (r: Int) -> Double in
                let a: Double = mat[r * 3], b: Double = mat[r * 3 + 1], c: Double = mat[r * 3 + 2]
                return a + b + c
            }
            check(sums.allSatisfy { abs($0 - 1) < 0.0002 }, "\(m.title): matrix rows sum to 1 (white and greys are unchanged)")
            check(near(m.simulate(.white), .white, 1) && near(m.simulate(RGBA(gray: 0.5)), RGBA(gray: 0.5), 1) && m.simulate(.black) == .black, "\(m.title): neutral colours stay put")
        }
        let red = RGBA(hex: "FF0000")!, green = RGBA(hex: "00FF00")!, blue = RGBA(hex: "0000FF")!
        // Machado 2009 (severity 1), linear RGB → sRGB
        let pr = VisionSimulation.protanopia.simulate(red), pg = VisionSimulation.protanopia.simulate(green)
        check(near(pr, RGBA(r8: 109, g8: 95, b8: 0), 2), "protanopia: pure red → dark olive (#\(pr.hex), expected ≈ #6D5F00)")
        check(near(pg, RGBA(r8: 255, g8: 229, b8: 0), 2), "protanopia: pure green → yellow (#\(pg.hex), expected ≈ #FFE500)")
        let dr = VisionSimulation.deuteranopia.simulate(red), dg = VisionSimulation.deuteranopia.simulate(green)
        check(near(dr, RGBA(r8: 163, g8: 144, b8: 0), 2) && near(dg, RGBA(r8: 238, g8: 213, b8: 58), 2), "deuteranopia: red → #\(dr.hex), green → #\(dg.hex) (expected ≈ #A39000 / #EED53A)")
        let tb = VisionSimulation.tritanopia.simulate(blue)
        check(near(tb, RGBA(r8: 0, g8: 107, b8: 150), 2), "tritanopia: pure blue → teal (#\(tb.hex), expected ≈ #006B96)")
        func hueGap(_ a: RGBA, _ b: RGBA) -> Double { let d = abs(a.hsb.h - b.hsb.h); return min(d, 1 - d) * 360 }
        check(hueGap(red, green) > 100 && hueGap(pr, pg) < 12 && hueGap(dr, dg) < 12, "red and green collapse to nearly the same hue for protan / deutan viewers")
        let ar = VisionSimulation.achromatopsia.simulate(red)
        check(ar.r8 == ar.g8 && ar.g8 == ar.b8 && abs(ar.r8 - 127) <= 2, "achromatopsia: red → grey of the same luminance (#\(ar.hex))")
        let lc = VisionSimulation.lowContrast
        check(WCAG.contrast(lc.simulate(.black), lc.simulate(.white)) < 5.5 && abs(lc.simulate(RGBA(gray: 0.5)).r - 0.5) < 0.001, "low contrast compresses tones around mid grey")

        // Core Image path (canvas view pipeline) agrees with the reference maths
        let cols = ["FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF", "E94F37", "2A9D8F", "F6AE2D", "6A4C93", "FFFFFF", "404040"].map { RGBA(hex: $0)! }
        let cell = 40
        var st = DocumentState(width: cell * 6, height: cell * 2)
        let buf = PixelBuffer(width: st.width, height: st.height)
        for (i, c) in cols.enumerated() { buf.context.setFillColor(c.cgColor); buf.context.fill(CGRect(x: (i % 6) * cell, y: (i / 6) * cell, width: cell, height: cell)) }
        buf.markDirty()
        st.layers = [Layer.raster(name: "swatches", buffer: buf)]
        let sp = CanvasSpace(width: st.width, height: st.height)
        let d = Document(state: st, name: "sim")
        let settings = ArtistSettings.shared
        var sheet: [(String, CGImage)] = [("Normal", buf.makeCGImage())]
        for m in VisionSimulation.allCases where m != .none {
            settings.simulation = m
            let shown = RenderEngine.renderBuffer(CanvasRenderer.applyViewMode(Compositor.shared.composite(d), doc: d), docRect: st.canvasRect, space: sp)
            sheet.append((m.title, shown.makeCGImage()))
            if m == .blur {
                let edge = pixel(shown, cell, cell / 2), inside = pixel(shown, cell / 2, cell / 2)
                check(!near(edge, cols[0], 8) && !near(edge, cols[1], 8) && near(inside, cols[0], 40), "squint test blurs the view (edge between red and green is #\(edge.hex))")
                continue
            }
            var worst = 0
            for (i, c) in cols.enumerated() {
                let got = pixel(shown, (i % 6) * cell + cell / 2, (i / 6) * cell + cell / 2), want = m.simulate(c)
                worst = max(worst, abs(got.r8 - want.r8), abs(got.g8 - want.g8), abs(got.b8 - want.b8))
            }
            check(worst <= 3, "\(m.title): canvas view matches the reference matrix (max Δ \(worst) / 255)")
        }
        settings.simulation = .none
        let plain = RenderEngine.renderBuffer(CanvasRenderer.applyViewMode(Compositor.shared.composite(d), doc: d), docRect: st.canvasRect, space: sp)
        check(near(pixel(plain, cell / 2, cell / 2), cols[0], 1), "simulation off shows the true colours")
        check(near(pixel(composite(d.state), cell / 2, cell / 2), cols[0], 1) && d.history.count == 1, "simulation is view-only: pixels and history are untouched")
        savePNG(drawImage(CGSize(width: st.width * 2 + 30, height: (st.height + 22) * 4 + 8)) { ctx in
            ctx.setFillColor(NSColor(white: 0.15, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
            for (i, (name, img)) in sheet.enumerated() {
                let x = CGFloat(10 + (i % 2) * (st.width + 10)), y = CGFloat(8 + (i / 2) * (st.height + 22))
                NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]).draw(at: CGPoint(x: x, y: y))
                ctx.saveGState(); ctx.translateBy(x: x, y: y + 16 + CGFloat(st.height)); ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: st.width, height: st.height)); ctx.restoreGState()
            }
        }, "artist_simulate", out)
    }

    // MARK: View flip

    static func viewFlip() {
        let (d, _) = ToolsSelfTest.whiteDoc(400, 300, name: "flip")
        let c = ToolsSelfTest.canvas(for: d)
        c.fitOnScreen()
        let ins = c.contentInsets
        let centre = CGPoint(x: ins.left + (c.bounds.width - ins.left) / 2, y: ins.top + (c.bounds.height - ins.top) / 2)
        let docAtCentre = c.viewToDoc(centre)
        let left = c.docToView(CGPoint(x: 0, y: 100)), right = c.docToView(CGPoint(x: 400, y: 100))
        check(left.x < right.x, "normal view: x grows to the right")
        let offset0 = d.viewOffset
        ArtistView.setFlipped(d, true, canvas: c)
        let fl = c.docToView(CGPoint(x: 0, y: 100)), fr = c.docToView(CGPoint(x: 400, y: 100))
        check(ArtistView.isFlipped(d) && fl.x > fr.x && abs(fl.y - left.y) < 0.001, "flipped view mirrors the canvas horizontally")
        check(c.viewToDoc(centre).distance(to: docAtCentre) < 0.001, "the point under the viewport centre stays put")
        let p = CGPoint(x: 123.5, y: 45.25)
        check(c.viewToDoc(c.docToView(p)).distance(to: p) < 1e-6, "painting coordinates stay consistent while flipped (view ↔ doc round trip)")
        check(abs(fl.x - right.x) < 0.001 && abs(fr.x - left.x) < 0.001, "the canvas occupies the same screen area")
        // zooming around a point keeps that point fixed (the anchor maths uses the flipped transform)
        let anchor = CGPoint(x: 300, y: 260)
        let before = c.viewToDoc(anchor)
        c.setZoom(d.zoom * 2, anchorView: anchor)
        check(c.viewToDoc(anchor).distance(to: before) < 0.001, "zooming at the cursor works in the flipped view")
        c.setZoom(d.zoom / 2, anchorView: anchor)
        ArtistView.setFlipped(d, false, canvas: c)
        check(!ArtistView.isFlipped(d) && d.viewOffset.distance(to: offset0) < 0.001 && c.docToView(CGPoint(x: 0, y: 100)).distance(to: left) < 0.001, "flipping back restores the view exactly")
        check(d.history.count == 1, "flip view does not touch the document")
    }

    // MARK: Wrap-around painting

    static func wrapAround(_ out: URL) {
        let app = AppModel.shared
        app.tool = .brush
        let settings = ArtistSettings.shared
        settings.prefs = ArtistPrefs()
        let W = 240, H = 200
        // unit: wrapped copies
        let c1 = BrushAssist.wrapCopies(CGPoint(x: 235, y: 100), width: W, height: H, radius: 10)
        check(c1 == [CGPoint(x: -5, y: 100)], "a dab overlapping the right edge gets a copy at the left edge (\(c1))")
        check(BrushAssist.wrapCopies(CGPoint(x: 120, y: 100), width: W, height: H, radius: 10).isEmpty, "dabs away from the edges get no copies")
        let corner = BrushAssist.wrapCopies(CGPoint(x: 236, y: 196), width: W, height: H, radius: 10)
        check(Set(corner.map { "\(Int($0.x)),\(Int($0.y))" }) == ["-4,196", "236,-4", "-4,-4"], "a dab on a corner appears on all four corners (\(corner.count) copies)")
        let outside = BrushAssist.wrapCopies(CGPoint(x: 260, y: 100), width: W, height: H, radius: 10)
        check(outside == [CGPoint(x: 20, y: 100)], "painting on a neighbouring tile of the pattern preview lands on the canvas")

        var s = BrushSelfTest.brush(size: 26, hardness: 0.85, spacing: 0.08)
        s.opacity = 1
        app.brush = s                     // the wrap radius follows the active brush
        func seam(_ d: Document, _ id: UUID) -> (Double, Int) {
            guard let b = d.state.layer(id)?.raster?.buffer else { return (999, 0) }
            var sum = 0.0, edgePainted = 0
            for y in 0..<H { sum += abs(Double(b.alpha(0, y)) - Double(b.alpha(W - 1, y))); if b.alpha(W - 1, y) > 128 { edgePainted += 1 } }
            for x in 0..<W { sum += abs(Double(b.alpha(x, 0)) - Double(b.alpha(x, H - 1))) }
            return (sum / Double(W + H), edgePainted)
        }
        let pts = (0...40).map { i -> PenSample in
            let t = CGFloat(i) / 40
            return PenSample(p: CGPoint(x: 150 + 170 * t, y: 60 + 50 * t + 12 * sin(t * 8)))   // leaves through the right edge
        }
        let down = (0...40).map { i -> PenSample in
            let t = CGFloat(i) / 40
            return PenSample(p: CGPoint(x: 60 + 40 * t, y: 150 + 110 * t))                     // leaves through the bottom edge
        }
        // without wrap: the stroke is cut at the edge
        settings.wrapPainting = false
        let (plain, pid) = ToolsSelfTest.whiteDoc(W, H, name: "nowrap")
        ArtistContext.testDoc = plain
        BrushSelfTest.stroke(plain, pid, s, pts, fg: RGBA(hex: "1F3A93")!)
        BrushSelfTest.stroke(plain, pid, s, down, fg: RGBA(hex: "C0392B")!)
        let (e0, n0) = seam(plain, pid)
        // with wrap
        settings.wrapPainting = true
        let (d, id) = ToolsSelfTest.whiteDoc(W, H, name: "wrap")
        ArtistContext.testDoc = d
        BrushSelfTest.stroke(d, id, s, pts, fg: RGBA(hex: "1F3A93")!)
        BrushSelfTest.stroke(d, id, s, down, fg: RGBA(hex: "C0392B")!)
        let (e1, n1) = seam(d, id)
        check(n0 > 10 && n1 > 10, "the stroke crosses the right edge (\(n1) edge pixels)")
        check(e0 > 8 && e1 < 2.5, "with Wrap Painting the left / right and top / bottom edges match (edge mismatch \(String(format: "%.1f", e0)) → \(String(format: "%.2f", e1)) of 255)")
        if let b = d.state.layer(id)?.raster?.buffer, let pb = plain.state.layer(pid)?.raster?.buffer {
            check(b.alpha(20, 82) > 200 && pb.alpha(20, 82) == 0, "the part that left through the right edge continues from the left edge")
            check(b.alpha(90, 32) > 200 && pb.alpha(90, 32) == 0, "the part that left through the bottom continues from the top")
            check(b.alpha(150, 60) > 200 && b.alpha(120, 150) == 0, "the rest of the canvas is painted normally")
        }
        // symmetry and wrap combine
        ToolsSettings.shared.symmetry = SymmetrySettings(enabled: true, type: .vertical)
        SymmetryControls.activeTestDoc = d
        let (sym, sid) = ToolsSelfTest.whiteDoc(W, H, name: "symwrap")
        ArtistContext.testDoc = sym
        SymmetryControls.activeTestDoc = sym
        BrushSelfTest.stroke(sym, sid, s, [PenSample(p: CGPoint(x: 150, y: 190)), PenSample(p: CGPoint(x: 150, y: 215))], fg: .black)
        if let b = sym.state.layer(sid)?.raster?.buffer {
            check(b.alpha(150, 8) > 200 && b.alpha(90, 8) > 200 && b.alpha(90, 195) > 200, "wrap-around also wraps the symmetry copies")
        }
        ToolsSettings.shared.symmetry = SymmetrySettings()
        SymmetryControls.activeTestDoc = nil
        // the test pad ignores wrap
        ArtistContext.padActive = true
        check(BrushDynamicsEngine.symmetryPoints?(CGPoint(x: 239, y: 100)).isEmpty ?? true, "the Brush Test Pad ignores wrap-around and symmetry")
        ArtistContext.padActive = false
        SelfTest.save(d.state, "artist_wrap", out)
        savePNG(tiled(composite(d.state), 2), "artist_wrap_tiled", out)
        savePNG(tiled(composite(plain.state), 2), "artist_nowrap_tiled", out)
        settings.prefs = ArtistPrefs()
        ArtistContext.testDoc = nil
    }

    // MARK: Make seamless

    static func texture(_ W: Int, _ H: Int) -> PixelBuffer {
        let b = PixelBuffer(width: W, height: H)
        let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "3B5B2A")!.cgColor, RGBA(hex: "B5C99A")!.cgColor, RGBA(hex: "8A5A44")!.cgColor] as CFArray, locations: [0, 0.6, 1])!
        b.context.drawLinearGradient(g, start: .zero, end: CGPoint(x: W, y: H), options: [])
        var rng = SeededRandom(seed: 99)
        for _ in 0..<170 {
            let x = CGFloat(rng.next()) * CGFloat(W), y = CGFloat(rng.next()) * CGFloat(H), r = 3 + CGFloat(rng.next()) * 9
            let v = rng.next()
            b.context.setFillColor(RGBA(r: 0.2 + 0.5 * v, g: 0.35 + 0.4 * rng.next(), b: 0.15 + 0.3 * v, a: 0.55).cgColor)
            b.context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        b.markDirty()
        return b
    }

    static func seamless(_ out: URL) {
        let W = 144, H = 120
        let src = texture(W, H)
        // offset with wrap-around
        let off = SeamlessTile.offsetWrapped(src, dx: 50, dy: 30)
        check(pixel(off, 50, 30) == pixel(src, 0, 0) && pixel(off, 10, 5) == pixel(src, W - 40, H - 25), "offset wraps pixels around the edges")
        let backAgain = SeamlessTile.offsetWrapped(off, dx: -50, dy: -30)
        check(memcmp(backAgain.data, src.data, src.bytesPerRow * H) == 0, "offsetting back restores the image exactly")

        let e0 = SeamlessTile.seamError(src)
        check(e0.seam > e0.interior * 4 && e0.seam > 25, "the test texture does not tile (edge step \(String(format: "%.1f", e0.seam)) vs \(String(format: "%.1f", e0.interior)) between neighbouring pixels)")
        for method in SeamlessMethod.allCases {
            let t0 = Date()
            let res = SeamlessTile.makeSeamless(src, method: method)
            let e = SeamlessTile.seamError(res)
            check(res.width == W && res.height == H, "\(method.title): size unchanged")
            check(e.seam <= e.interior * 1.6 + 2.5 && e.seam < e0.seam / 5, "\(method.title): edges now match (edge step \(String(format: "%.1f", e0.seam)) → \(String(format: "%.2f", e.seam)); neighbouring pixels differ by \(String(format: "%.2f", e.interior))) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            // the middle of the image is untouched (only the band at the edges changes)
            var diff = 0.0, n = 0.0
            for y in stride(from: H / 3, to: 2 * H / 3, by: 3) { for x in stride(from: W / 3, to: 2 * W / 3, by: 3) {
                let a = pixel(res, x, y), b = pixel(src, x, y)
                diff += Double(abs(a.r8 - b.r8) + abs(a.g8 - b.g8) + abs(a.b8 - b.b8)) / 3; n += 1
            } }
            check(diff / n < 6, "\(method.title): away from the edges only the broad tone is evened out (mean Δ \(String(format: "%.2f", diff / n)) of 255)")
            // …and the detail there is intact: the local contrast (difference to the pixel 2 px away) is unchanged
            var d0 = 0.0, d1 = 0.0
            for y in stride(from: H / 3, to: 2 * H / 3, by: 2) { for x in stride(from: W / 3, to: 2 * W / 3, by: 2) {
                d0 += Double(abs(pixel(src, x, y).g8 - pixel(src, x + 2, y).g8)); d1 += Double(abs(pixel(res, x, y).g8 - pixel(res, x + 2, y).g8))
            } }
            check(abs(d0 - d1) / max(1, d0) < 0.08, "\(method.title): texture detail is preserved (local contrast \(Int(d0)) → \(Int(d1)))")
            var opaque = true
            for y in stride(from: 0, to: H, by: 5) { for x in stride(from: 0, to: W, by: 5) where res.alpha(x, y) != 255 { opaque = false } }
            check(opaque, "\(method.title): result stays opaque")
            savePNG(tiled(res, 2), "artist_seamless_\(method.rawValue)_tiled", out)
        }
        savePNG(tiled(src, 2), "artist_seamless_before_tiled", out)

        // document commands
        let app = AppModel.shared
        var st = DocumentState(width: W, height: H)
        st.layers = [Layer.raster(name: "Texture", buffer: src)]
        let d = Document(state: st, name: "tile.png")
        app.add(d)
        defer { app.close(d) }
        let h = d.history.count
        SeamlessTile.makeSeamlessAction(method: .blend, band: nil)
        let after = d.state.layers[0].raster!.buffer
        check(d.history.count == h + 1 && SeamlessTile.seamError(after).seam < e0.seam / 5 && d.state.layers.count == 1, "Make Seamless edits the active pixel layer in one undoable step")
        d.undo()
        check(d.state.layers[0].raster!.buffer === src, "undo restores the original pixels")
        let n = app.customPatterns.count
        let pid = SeamlessTile.definePatternFromCanvas()
        let pat = app.customPatterns.last
        check(app.customPatterns.count == n + 1 && pat?.id == pid && pat?.image.width == W && pat?.image.height == H && app.bucket.patternID == pid, "Define Pattern from Canvas adds a \(W)×\(H) pattern and selects it")
        check(pat.map { near(pixel($0.image, 40, 40), pixel(src, 40, 40), 1) } ?? false, "the pattern holds the canvas pixels")
        if let pid { app.customPatterns.removeAll { $0.id == pid } }
    }

    // MARK: Eyedropper ring, test pad

    static func extras(_ out: URL) {
        let app = AppModel.shared
        // eyedropper average of N px
        var st = DocumentState(width: 200, height: 120)
        let b = PixelBuffer(width: 200, height: 120)
        for y in 0..<120 { for x in 0..<200 {
            b.context.setFillColor(((x / 4 + y / 4) % 2 == 0 ? RGBA(hex: "FF0000")! : RGBA(hex: "0000FF")!).cgColor)
            b.context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        b.markDirty()
        st.layers = [Layer.raster(name: "checks", buffer: b)]
        let d = Document(state: st, name: "ring")
        let one = ToolGeometry.compositeColor(d, at: CGPoint(x: 101, y: 61), size: 1)
        let avg = ToolGeometry.compositeColor(d, at: CGPoint(x: 101, y: 61), size: 33)
        check(one.map { $0.hex == "FF0000" || $0.hex == "0000FF" } ?? false, "point sample reads a single pixel (#\(one?.hex ?? "nil"))")
        check(avg.map { abs($0.r8 - 128) < 14 && abs($0.b8 - 128) < 14 && $0.g8 < 4 } ?? false, "33 px average mixes the checks to purple (#\(avg?.hex ?? "nil"))")
        savePNG(drawImage(CGSize(width: 200, height: 120)) { ctx in
            ctx.saveGState(); ctx.translateBy(x: 0, y: 120); ctx.scaleBy(x: 1, y: -1); ctx.draw(b.makeCGImage(), in: CGRect(x: 0, y: 0, width: 200, height: 120)); ctx.restoreGState()
            EyedropperRing.draw(ctx, at: CGPoint(x: 100, y: 60), sampled: avg ?? .black, current: RGBA(hex: "F6AE2D")!, sampleSize: 33, zoom: 1)
        }, "artist_eyedropper_ring", out)

        // Brush test pad: paints with the real engine, never touches a document
        let (real, rid) = ToolsSelfTest.whiteDoc(120, 80, name: "real")
        app.add(real)
        defer { app.close(real) }
        ArtistSettings.shared.prefs = ArtistPrefs()
        real.state.artist.guide = DrawingGuide.standard(.grid, width: 120, height: 80)   // must not snap pad strokes
        app.tool = .brush
        app.brush = BrushSelfTest.brush(size: 18, hardness: 0.7, spacing: 0.1)
        app.foreground = RGBA(hex: "8E24AA")!
        let pad = BrushTestPad(width: 320, height: 200)
        let h = real.history.count
        pad.begin(PenSample(p: CGPoint(x: 30, y: 150)))
        for i in 1...30 { pad.move(PenSample(p: CGPoint(x: 30 + CGFloat(i) * 8, y: 150 - 90 * sin(CGFloat(i) / 30 * .pi) + CGFloat(i % 3) * 3))) }
        pad.end(PenSample(p: CGPoint(x: 280, y: 150)))
        let padBuf = pad.doc.state.layer(pad.layerID)?.raster?.buffer
        check(padBuf.map { $0.alpha(30, 150) > 100 && $0.alpha(150, 62) > 100 } ?? false, "the test pad paints with the current brush (unsnapped curve)")
        check(real.history.count == h && real.state.layer(rid)?.raster?.buffer.isFullyTransparent == true && !real.isDirty, "the document is untouched by test-pad strokes")
        check(!ArtistContext.padActive, "pad mode ends with the stroke")
        app.foreground = RGBA(hex: "00897B")!
        pad.begin(PenSample(p: CGPoint(x: 40, y: 40))); pad.move(PenSample(p: CGPoint(x: 280, y: 60))); pad.end(PenSample(p: CGPoint(x: 280, y: 60)))
        savePNG(pad.image(), "artist_test_pad", out)
        pad.clear()
        check(pad.doc.state.layer(pad.layerID)?.raster?.buffer.isFullyTransparent == true, "Clear empties the pad")
    }

    // MARK: UI snapshots (LUMEN_SELFTEST_UI=1)

    static func uiSnapshots(_ out: URL) {
        let app = AppModel.shared
        func snap<V: View>(_ v: V, _ name: String, _ size: CGSize, _ o: URL) { ToolsSelfTest.snapView(v, name, size, o) }
        var st = SelfTest.baseState(560, 360)
        var shape = SelfTest.shapeLayer(CGRect(x: 60, y: 60, width: 150, height: 110), RGBA(hex: "E94F37")!)
        shape.name = "Card"
        var t = TextContent()
        t.text = "Headline"; t.fontName = "Helvetica-Bold"; t.fontSize = 40; t.color = RGBA(hex: "9AA7C7")!; t.position = CGPoint(x: 240, y: 90)
        let text = Layer(name: "Headline", content: .text(t))
        st.layers += [shape, text]
        st.artist.guide = DrawingGuide.standard(.perspective2, width: 560, height: 360)
        st.artist.guide.vps = [CGPoint(x: 40, y: 150), CGPoint(x: 520, y: 150)]
        st.artist.rulers = [AssistRuler.standard(.ellipse, width: 560, height: 360), AssistRuler.standard(.curve, width: 560, height: 360)]
        let d = Document(state: st, name: "Poster.imagecrat")
        app.add(d)
        defer { app.close(d) }
        let g1 = GlobalColors.add(d, color: RGBA(hex: "E94F37")!, name: "Brand Red")
        let g2 = GlobalColors.add(d, color: RGBA(hex: "9AA7C7")!, name: "Headline")
        _ = GlobalColors.add(d, color: RGBA(hex: "1B1F3A")!, name: "Ink")
        GlobalColors.assign(d, layer: shape.id, slot: .shapeFill, global: g1)
        GlobalColors.assign(d, layer: text.id, slot: .textColor, global: g2)
        SwatchGroupStore.shared.add(name: "Triadic #3A7BD5", colors: ColorHarmony.swatchSet(.triadic, base: RGBA(hex: "3A7BD5")!))
        app.foreground = RGBA(hex: "3A7BD5")!
        app.recentColors = ["3A7BD5", "E94F37", "F6AE2D", "1B1F3A", "2A9D8F"].map { RGBA(hex: $0)! }
        ArtistSettings.shared.prefs = ArtistPrefs()
        ArtistSettings.shared.prefs.stabilizer = .rope
        ArtistSettings.shared.prefs.paletteJitter = .perStroke
        ArtistSettings.shared.prefs.paletteGroup = SwatchGroupStore.shared.groups.last?.id

        snap(ColorHarmonyPanel(), "ui_artist_harmony", CGSize(width: 290, height: 330), out)
        snap(SwatchesPanel(), "ui_artist_swatches_globals", CGSize(width: 290, height: 470), out)
        d.selectLayer(text.id)
        snap(ContrastCheckerPanel(), "ui_artist_contrast", CGSize(width: 290, height: 330), out)
        snap(PropertiesPanel(), "ui_artist_properties_text", CGSize(width: 290, height: 520), out)
        d.selectLayer(shape.id)
        snap(PropertiesPanel(), "ui_artist_properties_shape", CGSize(width: 290, height: 420), out)
        snap(DrawingAssistPanel(), "ui_artist_drawing_assist", CGSize(width: 290, height: 640), out)
        snap(DraggableCard { PaletteFromImageDialog() }, "ui_artist_palette_dialog", CGSize(width: 440, height: 270), out)
        snap(DraggableCard { RecolorDialog() }, "ui_artist_recolor_dialog", CGSize(width: 440, height: 470), out)
        d.revertUncommitted()
        snap(DraggableCard { MakeSeamlessDialog() }, "ui_artist_seamless_dialog", CGSize(width: 380, height: 230), out)
        snap(VStack(alignment: .leading, spacing: 10) { RadialMenuPreferencesSection() }.padding(12), "ui_artist_prefs_radial", CGSize(width: 380, height: 420), out)
        app.tool = .brush
        snap(OptionsBar(), "ui_artist_options_brush", CGSize(width: 1100, height: 36), out)

        // test pad with a stroke
        let pad = BrushTestPad.shared
        app.brush = BrushSelfTest.brush(size: 16, hardness: 0.6, spacing: 0.08)
        pad.begin(PenSample(p: CGPoint(x: 60, y: 300)))
        for i in 1...40 { pad.move(PenSample(p: CGPoint(x: 60 + CGFloat(i) * 13, y: 200 + 120 * cos(CGFloat(i) / 6)))) }
        pad.end(PenSample(p: CGPoint(x: 580, y: 200)))
        snap(BrushTestPadPanel(), "ui_artist_test_pad", CGSize(width: 420, height: 300), out)
        pad.clear()

        // canvas overlay: guides, rulers and handles; eyedropper ring
        let c = CanvasView(frame: CGRect(x: 0, y: 0, width: 820, height: 520))
        c.document = d
        d.zoom = 1.1
        d.viewOffset = CGPoint(x: 100, y: 60)
        ToolsSelfTest.snapOverlay(c, "ui_artist_overlay_guides", out)
        app.tool = .eyedropper
        app.eyedropperSample = 11
        c.lastMouseView = CGPoint(x: 300, y: 200)
        ArtistSettings.shared.editGuides = false
        ToolsSelfTest.snapOverlay(c, "ui_artist_overlay_eyedropper", out)
        app.eyedropperSample = 1
        ArtistView.setFlipped(d, true, canvas: c)
        ArtistSettings.shared.editGuides = true
        app.tool = .brush
        ToolsSelfTest.snapOverlay(c, "ui_artist_overlay_flipped", out)
        ArtistView.setFlipped(d, false, canvas: c)

        // reference board window content
        let store = ReferenceBoardStore.shared
        store.update(.global, doc: nil, name: nil) { $0 = RefBoard() }
        let img1 = composite(d.state).makeCGImage()
        let img2 = solidImage(160, 220) { cx in
            let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "F6AE2D")!.cgColor, RGBA(hex: "6A4C93")!.cgColor] as CFArray, locations: [0, 1])!
            cx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 160, y: 220), options: [])
        }
        let ids = store.add([(img1, "poster"), (img2, "swatch")], to: .global, doc: nil, at: .zero, fitSide: 240)
        store.update(.global, doc: nil, name: nil) { b in b.items[1].grayscale = true; RefBoardRenderer.fit(&b, size: CGSize(width: 460, height: 320)) }
        let ui = RefBoardUIState()
        ui.selection = ids.first
        let view = RefBoardView(ui: ui)
        view.frame = CGRect(x: 0, y: 0, width: 460, height: 320)
        let ctl = ReferenceBoardController(scope: .global, index: 99)
        snap(RefBoardToolbar(ui: ui, view: view, controller: ctl), "ui_artist_refboard_toolbar", CGSize(width: 460, height: 28), out)
        savePNG(RefBoardRenderer.render(store.global, size: CGSize(width: 460, height: 320), selection: ids.first), "ui_artist_refboard", out)
        print("wrote ui_artist_* snapshots")
    }
}
