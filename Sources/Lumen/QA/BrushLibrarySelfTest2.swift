import AppKit
import SwiftUI
import ImageCratCore

extension BrushLibrarySelfTest {
    // MARK: - ABR export → import

    static func abrRoundTrip() {
        let l = lib("abrexport")
        // A mix: computed round, procedural tip with dynamics, a defined (sampled) tip with texture + dual brush.
        let general = l.index.root.folders.first { $0.name == "General" }!.id
        let round = l.index.brushIDs(inFolder: general)[2]
        let leaves = l.orderedBrushes.first { $0.id == "dyn-leaves" }!.id
        let tip = ABRImporter.renderRound(diameter: 40, hardness: 0.2, roundness: 0.6, angle: 20)
        let custom = l.defineBrush(tip: tip, name: "Sampled Oval", in: general)!
        var s = l.standaloneSettings(l.record(custom)!)
        s.spacing = 0.37; s.angle = 15
        s.dynamics.shapeEnabled = true; s.sizeJitter = 0.4; s.dynamics.sizeControl = ControlSetting(source: .pressure)
        s.dynamics.textureEnabled = true; s.dynamics.texturePatternID = "canvas"; s.dynamics.textureDepth = 0.6; s.dynamics.textureMode = .subtract
        s.dynamics.dualEnabled = true; s.dynamics.dualTipID = "charcoal"; s.dynamics.dualSize = 33
        s.dynamics.transferEnabled = true; s.dynamics.opacityControl = ControlSetting(source: .pressure); s.dynamics.minOpacity = 0.2
        s.dynamics.colorEnabled = true; s.dynamics.hueJitter = 0.1
        s.dynamics.wetEdges = true; s.dynamics.noise = true
        l.saveSettings(s, to: custom)
        let ids = [round, leaves, custom]
        let (data, notes) = l.abrData(ids, name: "Round Trip")
        check(notes.isEmpty, "ABR export without notes", notes.joined(separator: "; "))
        let url = tmp.appendingPathComponent("Round Trip.abr")
        try? data.write(to: url)
        let back = lib("abrimport", defaults: false)
        let res = back.importFiles([url])
        let added = res.first?.added ?? []
        check(added.count == 3, "re-import gives the same number of brushes", "\(added.count) \(res.first?.error ?? "")")
        check(res.first?.folderID.flatMap { back.index.folder($0)?.name } == "Round Trip", "re-imported into a folder named after the file")
        for (a, b) in zip(ids, added) {
            guard let ra = l.record(a), let rb = back.record(b) else { check(false, "records"); continue }
            check(ra.name == rb.name, "name kept: \(ra.name)")
            var pa = ra.params.presetPart(includesSize: true, includesToolSettings: false), pb = rb.params.presetPart(includesSize: true, includesToolSettings: false)
            pa.sanitize(); pb.sanitize()
            // tip / pattern ids are local to each library
            pb.dualTipID = pa.dualTipID; pb.texturePatternID = pa.texturePatternID; pb.texturePatternName = pa.texturePatternName
            pa.smoothing = 0; pb.smoothing = 0      // (ABR stores smoothing as on/off)
            pa.pressureSize = pb.pressureSize
            check(pa == pb, "main settings kept: \(ra.name)", diff(pa, pb))
            // tip pixels
            if ra.tipID == "round" {
                check(rb.tipID == "round", "computed round stays computed: \(ra.name)")
            } else {
                let ta = l.tipBuffer(ra.tipID) ?? BrushTips.texture(ra.tipID).map { PixelBuffer(cgImage: $0, format: .gray) }
                let tb = back.tipBuffer(rb.tipID)
                if let ta, let tb {
                    var same = ta.width == tb.width && ta.height == tb.height
                    if same { outer: for y in 0..<ta.height { for x in 0..<ta.width where gray(ta, x, y) != gray(tb, x, y) { same = false; break outer } } }
                    check(same, "tip pixels identical after the round trip: \(ra.name)", "\(ta.width)×\(ta.height) vs \(tb.width)×\(tb.height)")
                } else { check(false, "tip pixels after the round trip: \(ra.name)") }
            }
        }
        if let rb = back.record(added[2]) {
            check(back.tipBuffer(rb.params.dualTipID) != nil, "dual tip travels with the file")
            check(AppModel.shared.customPatterns.contains { $0.id == rb.params.texturePatternID }, "texture pattern travels with the file")
            savePNG(back.strokePreview(rb.id, width: 300, height: 80, fg: .black), "abr_roundtrip_stroke")
        }
    }

    static func diff(_ a: BrushParams, _ b: BrushParams) -> String {
        guard let da = try? JSONEncoder().encode(a), let db = try? JSONEncoder().encode(b),
              let ja = try? JSONSerialization.jsonObject(with: da) as? [String: Any], let jb = try? JSONSerialization.jsonObject(with: db) as? [String: Any] else { return "" }
        return ja.keys.sorted().filter { "\(ja[$0]!)" != "\(jb[$0] ?? "nil")" }.map { "\($0): \(ja[$0]!) → \(jb[$0] ?? "nil")" }.joined(separator: ", ")
    }

    // MARK: - Define Brush

    static func makeDoc(_ w: Int = 300, _ h: Int = 200) -> Document {
        var st = DocumentState(width: w, height: h)
        let bg = PixelBuffer(width: w, height: h)
        bg.context.setFillColor(RGBA.white.cgColor); bg.context.fill(CGRect(x: 0, y: 0, width: w, height: h)); bg.markDirty()
        let ink = PixelBuffer(width: w, height: h)
        ink.context.setFillColor(RGBA.black.cgColor); ink.context.fillEllipse(in: CGRect(x: 100, y: 50, width: 100, height: 100))
        ink.context.setFillColor(RGBA(gray: 0.5).cgColor); ink.context.fill(CGRect(x: 20, y: 20, width: 40, height: 40))
        ink.markDirty()
        let star = PixelBuffer(width: w, height: h)
        star.context.setFillColor(RGBA.white.cgColor)
        star.context.addPath(VectorPath.polygon(in: CGRect(x: 210, y: 40, width: 80, height: 80), sides: 5, starRatio: 0.45).cgPath)
        star.context.fillPath(); star.markDirty()
        st.layers = [Layer.raster(name: "Background", buffer: bg), Layer.raster(name: "Ink", buffer: ink), Layer.raster(name: "White Star", buffer: star)]
        let d = Document(state: st, name: "define")
        d.needsFitOnScreen = false
        return d
    }

    static func defineBrush() {
        let d = makeDoc()
        // whole visible image: dark = paint, white = none, trimmed to content
        guard let all = DefineBrush.tip(d, source: .visible) else { return check(false, "Define Brush from the whole image") }
        check(all.width == all.height, "tip is square")
        savePNG(all, "define_visible")
        // elliptical selection around the black disc, soft edge: any selection shape
        let sel = PixelBuffer(width: 300, height: 200, format: .gray)
        sel.context.setFillColor(gray: 1, alpha: 1)
        sel.context.fillEllipse(in: CGRect(x: 90, y: 40, width: 120, height: 120))
        sel.markDirty()
        d.state.selection = sel
        guard let t = DefineBrush.tip(d, source: .visible) else { return check(false, "Define Brush from an elliptical selection") }
        savePNG(t, "define_selection")
        check(abs(t.width - 100) <= 2, "selection tip is trimmed to the disc (\(t.width) px)")
        check(gray(t, t.width / 2, t.height / 2) > 245, "black paints fully", "\(gray(t, t.width / 2, t.height / 2))")
        check(gray(t, 1, 1) < 5, "white / outside the selection doesn't paint")
        // grey square only: 50% grey paints half
        let sq = PixelBuffer(width: 300, height: 200, format: .gray)
        sq.context.setFillColor(gray: 1, alpha: 1); sq.context.fill(CGRect(x: 15, y: 15, width: 50, height: 50)); sq.markDirty()
        d.state.selection = sq
        if let g = DefineBrush.tip(d, source: .visible) {
            let v = gray(g, g.width / 2, g.height / 2)
            check(abs(v - 128) < 12, "50% grey → half coverage", "\(v)")
        } else { check(false, "grey square tip") }
        // from a layer: a white shape on transparency paints with its alpha
        d.state.selection = nil
        d.activeLayerID = d.state.layers[2].id
        if let s = DefineBrush.tip(d, source: .activeLayer) {
            savePNG(s, "define_layer_white_star")
            check(gray(s, s.width / 2, s.height / 2) > 240 && gray(s, 0, 0) < 5, "a white shape on a transparent layer becomes a solid tip")
        } else { check(false, "Define Brush from Layer") }
        // empty selection → nothing
        let empty = PixelBuffer(width: 300, height: 200, format: .gray)
        d.state.selection = empty
        check(DefineBrush.tip(d, source: .visible) == nil, "an empty selection defines nothing")
        // the menu command (headless dialog: default name, default folder), into the shared library, selected at once
        d.state.selection = sel
        let app = AppModel.shared
        app.add(d)
        app.activeDocumentID = d.id
        app.tool = .brush
        let before = Set(BrushLibrary.shared.index.orderedBrushIDs)
        AppActions.defineBrush()
        let new = BrushLibrary.shared.index.orderedBrushIDs.filter { !before.contains($0) }
        check(new.count == 1, "Edit ▸ Define Brush Preset adds one brush")
        if let id = new.first, let r = BrushLibrary.shared.record(id) {
            check(app.brush.tipID == r.tipID, "the defined brush is selected for the Brush tool")
            check(r.name.hasPrefix("Sampled Brush"), "default name", r.name)
            BrushLibrary.shared.delete([id], confirm: false)
        }
        app.close(d)
    }

    // MARK: - Editor live preview

    static func editorPreview() {
        var base = BrushSettings(size: 30, hardness: 0.8, spacing: 0.12)
        base.pressureSize = false
        func png(_ s: BrushSettings) -> Data? {
            NSBitmapImageRep(cgImage: BrushStrokePreview.render(s, width: 220, height: 64)).representation(using: .png, properties: [:])
        }
        let b0 = png(base)
        var changed: [String] = []
        var same: [String] = []
        let variants: [(String, (inout BrushSettings) -> Void)] = [
            ("size", { $0.size = 12 }), ("hardness", { $0.hardness = 0 }), ("spacing", { $0.spacing = 0.9 }), ("angle+roundness", { $0.roundness = 0.2; $0.angle = 60 }),
            ("flip", { $0.tipID = "leaf"; $0.dynamics.flipY = true }),
            ("shape dynamics", { $0.dynamics.shapeEnabled = true; $0.dynamics.sizeControl = ControlSetting(source: .pressure) }),
            ("scattering", { $0.dynamics.scatterEnabled = true; $0.scatter = 2 }),
            ("texture", { $0.dynamics.textureEnabled = true; $0.dynamics.textureDepth = 1 }),
            ("dual brush", { $0.dynamics.dualEnabled = true; $0.dynamics.dualTipID = "spray" }),
            ("color dynamics", { $0.dynamics.colorEnabled = true; $0.dynamics.fgBgJitter = 1 }),
            ("transfer", { $0.dynamics.transferEnabled = true; $0.dynamics.opacityControl = ControlSetting(source: .pressure) }),
            ("brush pose", { $0.dynamics.shapeEnabled = true; $0.dynamics.sizeControl = ControlSetting(source: .pressure)
                $0.dynamics.poseEnabled = true; $0.dynamics.poseOverridePressure = true; $0.dynamics.posePressure = 0.2 }),
            ("noise", { $0.dynamics.noise = true }), ("wet edges", { $0.dynamics.wetEdges = true; $0.hardness = 0.2 }),
        ]
        for (name, f) in variants {
            var s = base
            f(&s)
            if png(s) != b0 { changed.append(name) } else { same.append(name) }
        }
        check(same.isEmpty, "the stroke preview changes with every Brush Settings section (\(changed.count) checked)", "unchanged: \(same.joined(separator: ", "))")
        // the panel itself: preview area re-renders when the settings change
        var s2 = base
        s2.dynamics.scatterEnabled = true; s2.scatter = 2.5; s2.spacing = 0.6
        let u1 = dir.appendingPathComponent("editor_preview_a.png"), u2 = dir.appendingPathComponent("editor_preview_b.png")
        snapshot(BrushSettingsEditor(settings: .constant(base)).padding(10).environment(\.panelWidth, 300), size: CGSize(width: 300, height: 640), to: u1)
        snapshot(BrushSettingsEditor(settings: .constant(s2)).padding(10).environment(\.panelWidth, 300), size: CGSize(width: 300, height: 640), to: u2)
        let d1 = try? Data(contentsOf: u1), d2 = try? Data(contentsOf: u2)
        check(d1 != nil && d2 != nil && d1 != d2, "the Brush Settings editor shows the new preview after a change")
        for sec in [BrushSettingsSection.pose, .protectTexture, .shape, .dual] {
            snapshot(BrushSettingsEditor(settings: .constant(s2), section: sec).padding(10).environment(\.panelWidth, 220),
                                    size: CGSize(width: 220, height: 700), to: dir.appendingPathComponent("editor_\(sec.rawValue.replacingOccurrences(of: " ", with: "_")).png"))
        }
    }

    // MARK: - Animated tips (image pipes)

    static func animatedTip() {
        let shapes: [PixelBuffer] = [
            ABRImporter.renderRound(diameter: 48, hardness: 1, roundness: 1, angle: 0),
            ABRImporter.renderRound(diameter: 48, hardness: 1, roundness: 0.2, angle: 0),
            ABRImporter.renderRound(diameter: 48, hardness: 1, roundness: 0.2, angle: 90),
        ]
        let lib = BrushLibrary.shared
        guard let tid = lib.addTip(frames: shapes, selection: .incremental) else { return check(false, "animated tip stored") }
        TipSource.invalidate(tid)
        let t = TipSource.get(tid)
        check(t.frames.count == 3, "an animated tip has its frames in the rasterizer", "\(t.frames.count)")
        check(t.frame(dab: 4, angle: 0, pressure: 1, random: 0) === t.frames[1], "incremental selection cycles frames")
        let (d, layer) = BrushSelfTest.makeDoc(400, 120)
        var s = BrushSelfTest.brush(size: 40, spacing: 1.1, tip: tid)
        s.pressureSize = false
        BrushSelfTest.stroke(d, layer, s, BrushSelfTest.path(y: 60, x0: 30, x1: 370, wave: 0, steps: 40))
        let img = Compositor.shared.flatten(d.state)
        savePNG(img, "animated_tip_stroke")
        if let img {
            let pb = PixelBuffer(cgImage: img, format: .gray)
            // Frames 2 and 3 are thin ellipses: some dab columns are narrow, some rows wide — the stroke isn't one shape repeated.
            var widths = Set<Int>()
            for x in stride(from: 40, to: 360, by: 4) {
                var n = 0
                for y in 30..<90 where gray(pb, x, y) < 128 { n += 1 }
                widths.insert(n / 10)
            }
            check(widths.count >= 3, "the stroke uses several frames", "\(widths.sorted())")
        }
        TipSource.invalidate(tid)
    }

    // MARK: - Routing: Finder / Dock / File menu / canvas drops

    static func waitForImport(_ seconds: Double = 8) {
        let end = Date().addingTimeInterval(seconds)
        while BrushLibrary.shared.importProgress != nil && Date() < end { UIFixesSelfTest.spin(0.05) }
        UIFixesSelfTest.spin(0.1)
    }

    static func fileRouting() {
        for e in ["abr", "ABR", "tpl", "gbr", "gih", "brush", "brushset", "kpp", "icbrushes"] {
            check(BrushLibrary.isBrushFile(URL(fileURLWithPath: "/x/y.\(e)")), "“.\(e)” is routed to the brush library")
        }
        check(!BrushLibrary.isBrushFile(URL(fileURLWithPath: "/x/y.png")) && !BrushLibrary.isBrushFile(URL(fileURLWithPath: "/x/y.psd")), "pictures still open as documents")
        let app = AppModel.shared
        let url = tmp.appendingPathComponent("Routed Leaf.abr")
        try? BrushSelfTest.syntheticABR().write(to: url)
        let docs = app.documents.count
        let before = Set(BrushLibrary.shared.index.orderedBrushIDs)
        AppActions.open(url: url)           // Finder double-click, File ▸ Open, Dock icon (application(_:open:) routes here too)
        waitForImport()
        let new = BrushLibrary.shared.index.orderedBrushIDs.filter { !before.contains($0) }
        check(app.documents.count == docs, "opening an .abr doesn't open a document")
        check(new.count == 1, "opening an .abr imports it into the Brushes panel", "\(new.count)")
        check(BrushLibrary.shared.lastImportSummary?.contains("Imported 1 brush into “Routed Leaf”") == true, "import summary", BrushLibrary.shared.lastImportSummary ?? "nil")
        // dropped on the canvas
        let d = makeDoc()
        let env = EmojiSelfTest.setUp(d)
        let pb = NSPasteboard(name: NSPasteboard.Name("imagecrat.brushlib.\(UUID().uuidString)"))
        pb.clearContents()
        let url2 = tmp.appendingPathComponent("Dropped Leaf.abr")
        try? BrushSelfTest.syntheticABR().write(to: url2)
        pb.writeObjects([url2 as NSURL])
        let layers = d.state.layers.count
        let before2 = Set(BrushLibrary.shared.index.orderedBrushIDs)
        let ok = env.canvas.performDragOperation(EmojiSelfTest.FakeDrag(pb, at: EmojiSelfTest.windowPoint(env, CGPoint(x: 150, y: 100)), window: env.window))
        waitForImport()
        let new2 = BrushLibrary.shared.index.orderedBrushIDs.filter { !before2.contains($0) }
        check(ok && new2.count == 1 && d.state.layers.count == layers, "a brush file dropped on the canvas is imported, not placed")
        pb.releaseGlobally()
        EmojiSelfTest.tearDown(env)
        // clean the shared library
        for f in BrushLibrary.shared.index.root.folders where ["Routed Leaf", "Dropped Leaf"].contains(f.name) { BrushLibrary.shared.deleteFolder(f.id, confirm: false) }
    }

    // MARK: - Panels offscreen

    /// Renders a view into a PNG through an offscreen window far outside every display, then lets the window and its
    /// view graph go (a long self-test run must not keep every snapshot's graph alive).
    static func snapshot<V: View>(_ view: V, size: CGSize, to url: URL) {
        autoreleasepool {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).font(Theme.font).foregroundStyle(Theme.text)
                .frame(width: size.width, height: size.height).background(Theme.panelBG))
            let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            win.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            UIFixesSelfTest.spin(0.4)
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            win.orderOut(nil)
            win.contentView = nil
        }
    }

    static func fits<V: View>(_ v: V, width: CGFloat, height: CGFloat = 2000) -> CGFloat {
        // (in a pool: the measuring controller and its view graph go away at once)
        autoreleasepool {
            let h = NSHostingController(rootView: v.environment(\.panelWidth, width).environment(\.colorScheme, Theme.colorScheme).font(Theme.font))
            h.sizingOptions = []
            return h.sizeThatFits(in: CGSize(width: width, height: height)).width
        }
    }

    static func panels() {
        let lib = BrushLibrary.shared
        let savedPrefs = lib.prefs
        defer { lib.prefs = savedPrefs }
        // something in Favourites and Recent
        if let a = lib.orderedBrushes.first?.id, lib.orderedBrushes.count > 5 {
            if !lib.isFavorite(a) { lib.setFavorite(a, true) }
            for r in lib.orderedBrushes.prefix(5) { lib.select(r.id) }
        }
        for mode in BrushLibrary.Prefs.ViewMode.allCases {
            lib.prefs.viewMode = mode
            for w in [DockMetrics.minColumnWidth, 300] {
                let need = fits(BrushesPanel(), width: w, height: 600)
                check(need <= w + 0.5, "Brushes panel (\(mode.rawValue)) fits \(Int(w)) pt", "needs \(Int(need))")
                snapshot(BrushesPanel().environment(\.panelWidth, w), size: CGSize(width: w, height: 620),
                                        to: dir.appendingPathComponent("panel_\(mode.rawValue)_\(Int(w)).png"))
            }
        }
        lib.prefs.viewMode = .tips
        var s = AppModel.shared.brush
        let pickerNeed = fits(BrushPresetPicker(settings: Binding(get: { s }, set: { s = $0 })), width: 300)
        check(pickerNeed <= 300.5, "options-bar Brush Preset picker fits its 300 pt pop-over", "needs \(Int(pickerNeed))")
        snapshot(BrushPresetPicker(settings: .constant(s)).padding(10), size: CGSize(width: 320, height: 520), to: dir.appendingPathComponent("options_bar_picker.png"))
        for w in [DockMetrics.minColumnWidth, 300] {
            let need = fits(BrushSettingsPanel(), width: w)
            check(need <= w + 0.5, "Brush Settings panel with the preset header fits \(Int(w)) pt", "needs \(Int(need))")
            snapshot(BrushSettingsPanel().environment(\.panelWidth, w), size: CGSize(width: w, height: 760), to: dir.appendingPathComponent("brush_settings_\(Int(w)).png"))
        }
        let headerNeed = fits(BrushPresetHeader(), width: DockMetrics.minColumnWidth - 20)
        check(headerNeed <= DockMetrics.minColumnWidth - 19.5, "preset header (name, Save / Reset / New) wraps to the narrow column", "needs \(Int(headerNeed))")
    }
}
