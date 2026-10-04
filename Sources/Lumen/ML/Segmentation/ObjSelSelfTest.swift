import AppKit
import SwiftUI
import CoreImage
import ImageIO
import ImageCratCore

/// `LUMEN_SELFTEST_ONLY=objsel Lumen --selftest <out>`: segmentation stack tests (writes PNG overlays + timings).
enum ObjSelSelfTest {
    static func log(_ s: String) { print("[objsel] " + s) }

    static func ms(_ f: () throws -> Void) rethrows -> Double {
        let t0 = CFAbsoluteTimeGetCurrent(); try f(); return (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }

    /// Runs an async body to completion on the main thread (spins the run loop so MainActor hops work).
    static func wait<T>(_ body: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task.detached { do { result = .success(try await body()) } catch { result = .failure(error) } }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return try result!.get()
    }

    static func loadImage(_ path: String, maxSide: Int? = nil) -> PixelBuffer? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        var opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true]
        if let m = maxSide { opts[kCGImageSourceThumbnailMaxPixelSize] = m }
        guard let cg = (maxSide != nil ? CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) : CGImageSourceCreateImageAtIndex(src, 0, nil)) else { return nil }
        return PixelBuffer(cgImage: cg)
    }

    /// Image with a tinted mask overlay, outline and optional prompt marks.
    static func overlay(_ img: PixelBuffer, _ mask: PixelBuffer?, color: NSColor = NSColor(calibratedRed: 0.1, green: 0.45, blue: 1, alpha: 1),
                        boxes: [CGRect] = [], points: [(CGPoint, Bool)] = [], outlines: [CGPath] = [], lasso: [CGPoint] = []) -> PixelBuffer {
        let out = img.copy()
        let ctx = out.context
        if let m = mask {
            ctx.saveGState()
            out.clip(toMask: m.makeMaskImage(), in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            ctx.setFillColor(color.withAlphaComponent(0.45).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(SelectionOps.outline(m))
            ctx.setStrokeColor(NSColor.yellow.cgColor)
            ctx.setLineWidth(max(1, CGFloat(img.width) / 600))
            ctx.strokePath()
            ctx.restoreGState()
        }
        let lw = max(2, CGFloat(img.width) / 300)
        for (i, o) in outlines.enumerated() {
            let hue = CGFloat(i) * 0.137
            ctx.addPath(o)
            ctx.setStrokeColor(NSColor(calibratedHue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.9, brightness: 1, alpha: 1).cgColor)
            ctx.setLineWidth(lw)
            ctx.strokePath()
        }
        for b in boxes {
            ctx.setStrokeColor(NSColor.magenta.cgColor); ctx.setLineWidth(lw); ctx.stroke(b)
        }
        if lasso.count > 2 {
            ctx.addLines(between: lasso); ctx.closePath()
            ctx.setStrokeColor(NSColor.orange.cgColor); ctx.setLineWidth(lw); ctx.strokePath()
        }
        for (p, pos) in points {
            let r = lw * 3
            ctx.setFillColor(pos ? NSColor.green.cgColor : NSColor.red.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        out.markDirty()
        return out
    }

    static func write(_ b: PixelBuffer, _ name: String, _ out: URL) {
        let url = out.appendingPathComponent(name + ".png")
        try? b.pngData()?.write(to: url)
        log("wrote \(name).png")
    }

    // MARK: Synthetic scene

    /// 1600×1000: sky gradient, ground, sun, a red ball, a blue box, a green triangle, a small yellow star, a tree.
    static func syntheticScene() -> PixelBuffer {
        let W = 1600, H = 1000
        let b = PixelBuffer(width: W, height: H)
        let c = b.context
        let sky = CGGradient(colorsSpace: sRGBSpace, colors: [NSColor(calibratedRed: 0.35, green: 0.6, blue: 0.95, alpha: 1).cgColor, NSColor(calibratedRed: 0.8, green: 0.9, blue: 1, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 620), options: [])
        let ground = CGGradient(colorsSpace: sRGBSpace, colors: [NSColor(calibratedRed: 0.55, green: 0.5, blue: 0.35, alpha: 1).cgColor, NSColor(calibratedRed: 0.35, green: 0.3, blue: 0.2, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
        c.saveGState(); c.clip(to: CGRect(x: 0, y: 620, width: W, height: H - 620))
        c.drawLinearGradient(ground, start: CGPoint(x: 0, y: 620), end: CGPoint(x: 0, y: CGFloat(H)), options: [])
        c.restoreGState()
        // noise texture on ground
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            let x = CGFloat.random(in: 0..<CGFloat(W), using: &rng), y = CGFloat.random(in: 622..<CGFloat(H), using: &rng)
            c.setFillColor(NSColor(white: CGFloat.random(in: 0.2...0.6, using: &rng), alpha: 0.25).cgColor)
            c.fill(CGRect(x: x, y: y, width: 3, height: 2))
        }
        func shadow(_ r: CGRect) {
            c.setFillColor(NSColor(white: 0, alpha: 0.25).cgColor)
            c.fillEllipse(in: CGRect(x: r.minX + 10, y: r.maxY - 14, width: r.width, height: 26))
        }
        // red ball (radial shading)
        let ball = CGRect(x: 180, y: 520, width: 260, height: 260)
        shadow(ball)
        let rg = CGGradient(colorsSpace: sRGBSpace, colors: [NSColor(calibratedRed: 1, green: 0.55, blue: 0.5, alpha: 1).cgColor, NSColor(calibratedRed: 0.75, green: 0.05, blue: 0.08, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
        c.saveGState(); c.addEllipse(in: ball); c.clip()
        c.drawRadialGradient(rg, startCenter: CGPoint(x: ball.midX - 50, y: ball.midY - 60), startRadius: 5, endCenter: CGPoint(x: ball.midX, y: ball.midY), endRadius: 140, options: [.drawsAfterEndLocation])
        c.restoreGState()
        // blue box
        let box = CGRect(x: 560, y: 470, width: 300, height: 320)
        shadow(box)
        c.setFillColor(NSColor(calibratedRed: 0.1, green: 0.25, blue: 0.7, alpha: 1).cgColor)
        c.fill(box)
        c.setFillColor(NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.9, alpha: 1).cgColor)
        c.fill(CGRect(x: box.minX, y: box.minY, width: box.width, height: 60))
        // green triangle
        c.setFillColor(NSColor(calibratedRed: 0.1, green: 0.65, blue: 0.25, alpha: 1).cgColor)
        c.move(to: CGPoint(x: 1000, y: 800)); c.addLine(to: CGPoint(x: 1300, y: 800)); c.addLine(to: CGPoint(x: 1150, y: 520)); c.closePath(); c.fillPath()
        // small yellow star
        c.setFillColor(NSColor(calibratedRed: 1, green: 0.85, blue: 0.1, alpha: 1).cgColor)
        let sc = CGPoint(x: 1450, y: 860)
        for i in 0..<10 {
            let r: CGFloat = i % 2 == 0 ? 45 : 18
            let a = CGFloat(i) * .pi / 5 - .pi / 2
            let p = CGPoint(x: sc.x + cos(a) * r, y: sc.y + sin(a) * r)
            if i == 0 { c.move(to: p) } else { c.addLine(to: p) }
        }
        c.closePath(); c.fillPath()
        // sun
        c.setFillColor(NSColor(calibratedRed: 1, green: 0.95, blue: 0.6, alpha: 1).cgColor)
        c.fillEllipse(in: CGRect(x: 1300, y: 90, width: 150, height: 150))
        // tree
        c.setFillColor(NSColor(calibratedRed: 0.4, green: 0.25, blue: 0.12, alpha: 1).cgColor)
        c.fill(CGRect(x: 1470, y: 400, width: 40, height: 240))
        c.setFillColor(NSColor(calibratedRed: 0.15, green: 0.45, blue: 0.15, alpha: 1).cgColor)
        c.fillEllipse(in: CGRect(x: 1380, y: 260, width: 220, height: 200))
        b.markDirty()
        return b
    }

    // MARK: Tests

    static func run(_ out: URL) {
        let only = ProcessInfo.processInfo.environment["LUMEN_OBJSEL_ONLY"]
        func want(_ n: String) -> Bool { only == nil || only!.split(separator: ",").contains { n.hasPrefix($0) } }
        log("models: sam=\(SegModels.samInstalled) florence=\(SegModels.florenceInstalled) lite=\(ModelManager.shared.isInstalled(SegModels.birefnetLite)) full=\(ModelManager.shared.isInstalled(SegModels.birefnet)) sam3=\(SegModels.sam3Installed)")
        if want("orient") { testOrientation(out) }
        if want("sam") { testSAM(out) }
        if want("tool") { testToolPrompts(out) }
        if want("amg") { testMaskAll(out) }
        if want("subject") { testSubject(out) }
        if want("hair") { testHair(out) }
        if want("text") { testText(out) }
        if want("sky") { testSky(out) }
        if want("people") { testPeople(out) }
        if want("sam3") { testSAM3(out) }
        if want("app") { testAppIntegration(out) }
        if want("ui") { testUISnapshots(out) }
        // opt-in (re-downloads 94 MB): exercise ModelManager.ensure for the SAM 2.1 spec
        if only?.contains("download") == true { testDownload(out) }
    }

    static let zebraPath = "/Library/User Pictures/Animals/Zebra.heic"
    static let dandelionPath = "/Library/User Pictures/Flowers/Dandelion.heic"
    static let sonomaPath = "/System/Library/Desktop Pictures/Sonoma.heic"

    static func timed<T>(_ label: String, _ f: () throws -> T) rethrows -> T {
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = try f()
        log(String(format: "%@: %.0f ms", label, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        return r
    }

    /// Box on a small object (crop re-encode), point click, lasso, subtract.
    static func testToolPrompts(_ out: URL) {
        let scene = syntheticScene()
        let img = SegImage(buffer: scene)
        do {
            if SegModels.samInstalled { _ = try SAMSegmenter.shared.embedding(img) }
            var o = SegmentationService.Options()
            // small star with crop re-encode
            let starBox = CGRect(x: 1395, y: 805, width: 110, height: 105)
            let star = try timed("box small object (crop encode + decode + refine)") { try SegmentationService.boxSync(img, box: starBox, points: [], options: o) }
            write(overlay(scene, star, boxes: [starBox]), "objsel_box_small_star", out)
            o.cropSmallObjects = false
            let star2 = try SegmentationService.boxSync(img, box: starBox, points: [], options: o)
            write(overlay(scene, star2, boxes: [starBox]), "objsel_box_small_star_nocrop", out)
            o.cropSmallObjects = true
            // click (point)
            let p = CGPoint(x: 1150, y: 700)
            let tri = try timed("point click (decode + refine)") { try SegmentationService.pointSync(img, point: p, options: o) }
            write(overlay(scene, tri, points: [(p, true)]), "objsel_point_triangle", out)
            // lasso around the tree (rough)
            var lasso: [CGPoint] = []
            for i in 0..<40 {
                let a = CGFloat(i) / 40 * 2 * .pi
                lasso.append(CGPoint(x: 1490 + cos(a) * 150, y: 450 + sin(a) * 215))
            }
            let tree = try timed("lasso (tree)") { try SegmentationService.lassoSync(img, lasso: lasso, options: o) }
            write(overlay(scene, tree, lasso: lasso), "objsel_lasso_tree", out)
            // add + subtract: ball+box then subtract box
            let ball = try SegmentationService.pointSync(img, point: CGPoint(x: 300, y: 650), options: o)!
            let box = try SegmentationService.boxSync(img, box: CGRect(x: 540, y: 450, width: 340, height: 360), points: [], options: o)!
            let both = SelectionOps.combine(ball, box, mode: .add)
            let sub = SelectionOps.combine(both, box, mode: .subtract)
            log(String(format: "add/subtract: ball %.0f px, ball+box %.0f px, minus box %.0f px", SegMask.area(ball), SegMask.area(both), SegMask.area(sub)))
            write(overlay(scene, both), "objsel_add_ball_box", out)
            write(overlay(scene, sub), "objsel_subtract_box", out)
            // hard edge
            o.hardEdge = true
            let hard = try SegmentationService.pointSync(img, point: CGPoint(x: 300, y: 650), options: o)!
            write(overlay(scene, hard), "objsel_point_ball_hardedge", out)
            // real photo: click on the zebra head, box around the zebra
            if let z = loadImage(zebraPath) {
                let zi = SegImage(buffer: z)
                let zp = CGPoint(x: 330, y: 250)
                let zm = try timed("zebra encode+point") { try SegmentationService.pointSync(zi, point: zp, options: SegmentationService.Options()) }
                write(overlay(z, zm, points: [(zp, true)]), "objsel_point_zebra", out)
                let zb = CGRect(x: 5, y: 40, width: 440, height: 470)
                let zbm = try SegmentationService.boxSync(zi, box: zb, points: [], options: SegmentationService.Options())
                write(overlay(z, zbm, boxes: [zb]), "objsel_box_zebra", out)
            }
        } catch { log("tool prompt test failed: \(error)") }
    }

    static func testMaskAll(_ out: URL) {
        let scene = syntheticScene()
        let img = SegImage(buffer: scene)
        do {
            for grid in [16, 32] {
                let t0 = CFAbsoluteTimeGetCurrent()
                let objs = try SAMSegmenter.shared.automaticMasks(emb: try SAMSegmenter.shared.embedding(img), grid: grid)
                log(String(format: "mask all objects (grid %d): %d objects, decode %.0f ms", grid, objs.count, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
                if grid == 32 {
                    let t1 = CFAbsoluteTimeGetCurrent()
                    let bufs = try objs.map { try SegmentationService.finish($0.mask, img: img, options: SegmentationService.Options()) }
                    log(String(format: "full-res masks for %d objects: %.0f ms", bufs.count, (CFAbsoluteTimeGetCurrent() - t1) * 1000))
                    write(overlay(scene, nil, outlines: bufs.map { SelectionOps.outline($0) }), "objsel_mask_all_synthetic", out)
                }
            }
            if let z = loadImage(zebraPath) {
                let zi = SegImage(buffer: z)
                let res = try timed("mask all objects (zebra, total)") { try SegmentationService.allObjectsSync(zi, grid: 32) }
                log("zebra objects: \(res.count)")
                write(overlay(z, nil, outlines: res.map { SelectionOps.outline($0.1) }), "objsel_mask_all_zebra", out)
            }
        } catch { log("mask all failed: \(error)") }
    }

    static func testSubject(_ out: URL) {
        for (name, path) in [("zebra", zebraPath), ("dandelion", dandelionPath)] {
            guard let z = loadImage(path) else { continue }
            let zi = SegImage(buffer: z)
            do {
                let fast = try timed("subject fast (\(name))") { try SegmentationService.subjectSync(zi, quality: .fast, hair: false) }
                write(overlay(z, fast), "objsel_subject_fast_\(name)", out)
                let hq = try timed("subject high quality (\(name))") { try SegmentationService.subjectSync(zi, quality: .high, hair: true) }
                write(overlay(z, hq), "objsel_subject_hq_\(name)", out)
                if let hq { write(hq, "objsel_subject_hq_\(name)_mask", out) }
            } catch { log("subject failed: \(error)") }
        }
    }

    static func testHair(_ out: URL) {
        // Zebra mane: SAM box mask, then hair refinement with BiRefNet Lite / full in the edge band.
        guard let z = loadImage(zebraPath) else { return }
        let zi = SegImage(buffer: z)
        do {
            let box = CGRect(x: 5, y: 40, width: 440, height: 470)
            let base = try SegmentationService.boxSync(zi, box: box, points: [], options: SegmentationService.Options())!
            let crop = IRect(x: 150, y: 20, width: 260, height: 180)   // ears + mane
            func zoom(_ m: PixelBuffer, _ name: String) {
                let o = overlay(z, m, color: .magenta).cropped(to: crop)
                write(o, name, out)
                write(m.cropped(to: crop), name + "_mask", out)
            }
            zoom(base, "objsel_hair_zebra_sam")
            for q in SegMatting.Quality.allCases {
                _ = try SegMatting.refine(mask: base, image: zi, quality: q)   // warm-up (first run compiles GPU kernels)
                let r = try timed("hair refine \(q.rawValue) (zebra 512², warm)") { try SegMatting.refine(mask: base, image: zi, quality: q) }
                zoom(r, "objsel_hair_zebra_\(q == .fast ? "lite" : "full")")
            }
            log(String(format: "matting model latency (1024² inference): lite %.0f ms, full %.0f ms", SegLog.value("matting.birefnet-lite") ?? -1, SegLog.value("matting.birefnet") ?? -1))
        } catch { log("hair failed: \(error)") }
    }

    static func testText(_ out: URL) {
        let scene = syntheticScene()
        let img = SegImage(buffer: scene)
        let cases: [(PixelBuffer, SegImage, String, String)] = {
            var c: [(PixelBuffer, SegImage, String, String)] = [(scene, img, "red ball", "synthetic"), (scene, img, "tree", "synthetic"), (scene, img, "sky", "synthetic")]
            if let z = loadImage(zebraPath) { c.append((z, SegImage(buffer: z), "zebra", "zebra")); c.append((z, SegImage(buffer: z), "grass", "zebra")) }
            return c
        }()
        for (buf, si, prompt, name) in cases {
            do {
                let t0 = CFAbsoluteTimeGetCurrent()
                let m = try wait { try await SegmentationService.textMatches(prompt, in: si, engine: .fast) }
                log(String(format: "text '%@' (%@, Florence+SAM): %d match(es) %.0f ms [vision %.0f, text %.0f, decode %.0f ms / %.0f tokens]", prompt, name, m.count,
                           (CFAbsoluteTimeGetCurrent() - t0) * 1000, SegLog.value("florence.vision") ?? -1, SegLog.value("florence.text") ?? -1, SegLog.value("florence.decode") ?? -1, SegLog.value("florence.tokens") ?? -1))
                for x in m { log("   \(x.label) \(Int(x.box.minX)),\(Int(x.box.minY)) \(Int(x.box.width))x\(Int(x.box.height)) score \(String(format: "%.2f", x.score))") }
                write(overlay(buf, SegMask.union(m.map(\.mask)), boxes: m.map(\.box)), "objsel_text_\(name)_\(prompt.replacingOccurrences(of: " ", with: "_"))", out)
            } catch { log("text '\(prompt)' failed: \(error)") }
        }
    }

    static func testSky(_ out: URL) {
        for (name, b) in [("synthetic", syntheticScene()), ("zebra", loadImage(zebraPath))].compactMap({ n, b in b.map { (n, $0) } }) {
            do {
                let m = try timed("sky (\(name))") { try SegmentationService.skySync(SegImage(buffer: b)) }
                write(overlay(b, m, color: .orange), "objsel_sky_\(name)", out)
            } catch { log("sky failed: \(error)") }
        }
    }

    /// Spins the main run loop until `cond` holds (or timeout).
    static func spin(timeout: Double = 120, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return cond()
    }

    /// Document-level integration: engine prepare/embedding, Object Finder hover (latency), routed Select Subject,
    /// text Find, Mask All Objects groups, Refine Hair.
    static func testAppIntegration(_ out: URL) {
        let scene = syntheticScene()
        var st = DocumentState(width: scene.width, height: scene.height)
        st.layers = [Layer.raster(name: "Background", buffer: scene)]
        let d = Document(state: st, name: "objsel-test")
        AppModel.shared.add(d)
        let engine = ObjectSelectionEngine.shared
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let img = engine.prepare(d) else { log("prepare failed"); return }
        let ready = spin(timeout: SegModels.samInstalled ? 120 : 0) { engine.embeddingReady }
        log(String(format: "engine prepare → embedding ready: %@ in %.0f ms", ready ? "yes" : "NO", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        // prepare again with same content (e.g. after a selection change) must be a no-op
        d.setSelection(SelectionOps.rectMask(CGRect(x: 0, y: 0, width: 10, height: 10), width: d.state.width, height: d.state.height), commitName: "t")
        let t1 = CFAbsoluteTimeGetCurrent()
        let img2 = engine.prepare(d)
        log(String(format: "re-prepare after selection-only change: %.1f ms, same image: %@", (CFAbsoluteTimeGetCurrent() - t1) * 1000, img2?.id == img.id ? "yes" : "NO"))
        // Hover latency
        var lat: [Double] = []
        var last: HoverMask?
        for i in 0..<30 {
            let p = CGPoint(x: 150 + Double(i) * 45, y: 600 + Double(i % 5) * 30)
            let ts = CFAbsoluteTimeGetCurrent()
            last = (try? ObjectSelectionEngine.hoverMask(img, at: p)) ?? last
            lat.append((CFAbsoluteTimeGetCurrent() - ts) * 1000)
        }
        let sorted = lat.sorted()
        log(String(format: "hover (point decode + preview) median %.1f ms, p90 %.1f ms [last: decode %.1f (clean %.1f, sam.decode %.1f), preview %.1f]", sorted[15], sorted[27],
                       SegLog.value("hover.decode") ?? -1, SegLog.value("sam.clean") ?? -1, SegLog.value("sam.decode") ?? -1, SegLog.value("hover.preview") ?? -1))
        if let h = try? ObjectSelectionEngine.hoverMask(img, at: CGPoint(x: 700, y: 650)) {
            let o = scene.copy()
            o.drawImage(h.image, in: h.docRect)
            o.context.addPath(h.outline); o.context.setStrokeColor(ObjectSelectionEngine.hoverColor.cgColor); o.context.setLineWidth(3); o.context.strokePath()
            o.markDirty()
            write(o, "objsel_hover_box", out)
        }
        // Routed Select Subject (async through the engine)
        d.setSelection(nil, commitName: "clear")
        let ts = CFAbsoluteTimeGetCurrent()
        AppActions.selectSubject()
        _ = spin { ObjectSelectionSettings.shared.busy == nil && d.state.selection != nil }
        log(String(format: "Select ▸ Subject (routed): selection %@ in %.0f ms", d.state.selection != nil ? "set" : "EMPTY", (CFAbsoluteTimeGetCurrent() - ts) * 1000))
        write(overlay(scene, d.state.selection), "objsel_app_select_subject", out)
        // Find field (text prompt) — add mode
        d.setSelection(nil, commitName: "clear")
        ObjectSelectionModule.find("red ball", mode: .new)
        _ = spin { ObjectSelectionSettings.shared.busy == nil }
        ObjectSelectionModule.find("triangle", mode: .add)
        _ = spin { ObjectSelectionSettings.shared.busy == nil }
        write(overlay(scene, d.state.selection), "objsel_app_find_ball_plus_triangle", out)
        // Mask All Objects → groups
        let before = Compositor.shared.composite(d)
        let tm = CFAbsoluteTimeGetCurrent()
        let masks = (try? SegmentationService.allObjectsSync(img, grid: 32).map(\.1)) ?? []
        let n = ObjectSelectionModule.createObjectGroups(d, masks: masks)
        let groups = d.state.layers.last?.children ?? []
        log(String(format: "Mask All Objects: %d groups under “%@” (%.0f ms); masks on groups: %d", n, d.state.layers.last?.name ?? "?", (CFAbsoluteTimeGetCurrent() - tm) * 1000, groups.filter { $0.mask != nil }.count))
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        let a = RenderEngine.renderBuffer(before, docRect: d.state.canvasRect, space: sp), b = RenderEngine.renderBuffer(Compositor.shared.composite(d), docRect: d.state.canvasRect, space: sp)
        var diff = 0
        for y in stride(from: 0, to: a.height, by: 7) { for x in stride(from: 0, to: a.width, by: 7) { let p = a.pixel(x, y), q = b.pixel(x, y); diff = max(diff, abs(Int(p.0) - Int(q.0)) + abs(Int(p.1) - Int(q.1)) + abs(Int(p.2) - Int(q.2))) } }
        log("Mask All Objects leaves the composite unchanged: max diff \(diff)")
        write(overlay(scene, nil, outlines: groups.compactMap { $0.mask.map { SelectionOps.outline($0.buffer) } }), "objsel_app_mask_all_groups", out)
        AppModel.shared.close(d)
    }

    /// Offscreen snapshots of the options bar, Select by Description and Select and Mask (Refine Hair).
    static func testUISnapshots(_ out: URL) {
        var st = DocumentState(width: 400, height: 300)
        st.layers = [Layer.raster(name: "Background", buffer: syntheticScene())]
        let d = Document(state: st, name: "ui")
        d.setSelection(SelectionOps.rectMask(CGRect(x: 10, y: 10, width: 100, height: 100), width: 400, height: 300), commitName: "sel")
        AppModel.shared.add(d)
        defer { AppModel.shared.close(d) }
        func snap<V: View>(_ v: V, _ name: String, _ size: CGSize) {
            let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height).background(Theme.panelBG).environment(\.colorScheme, .dark))
            host.frame = CGRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
            log("wrote \(name).png")
        }
        snap(HStack(spacing: 10) { ObjectSelectOptionsBar() }.padding(.horizontal, 8).font(Theme.font).foregroundStyle(Theme.text), "objsel_ui_options_bar", CGSize(width: 1500, height: 34))
        snap(DraggableCard { SelectByDescriptionDialog() }, "objsel_ui_describe_dialog", CGSize(width: 440, height: 330))
        snap(DraggableCard { SelectAndMaskDialog() }, "objsel_ui_select_and_mask", CGSize(width: 380, height: 640))
    }

    static func testDownload(_ out: URL) {
        let mm = ModelManager.shared
        let id = SegModels.sam2
        SegModels.unload(id)
        SAMSegmenter.shared.clearCache()
        mm.delete(id)
        log("deleted \(id); installed=\(mm.isInstalled(id))")
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let dir = try wait { try await mm.ensure(id) }
            let size = (try? FileManager.default.subpathsOfDirectory(atPath: dir.path).reduce(0) { acc, f in
                acc + ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(f).path)[.size] as? Int) ?? 0) }) ?? 0
            log(String(format: "ModelManager.ensure(%@): installed=%@ in %.1f s, folder %.0f MB (incl. compiled .mlmodelc)", id, mm.isInstalled(id) ? "yes" : "NO", CFAbsoluteTimeGetCurrent() - t0, Double(size) / 1e6))
            let img = SegImage(buffer: syntheticScene())
            let m = try SAMSegmenter.shared.predict(.point(CGPoint(x: 300, y: 650)), emb: try SAMSegmenter.shared.embedding(img))
            log(String(format: "re-downloaded SAM works: score %.3f coverage %.3f", m.score, m.coverage))
        } catch { log("download failed: \(error)") }
    }

    static func testPeople(_ out: URL) {
        // No generic people photo ships in macOS system folders; run the path on the zebra (expects 0 people).
        guard let z = loadImage(zebraPath) else { return }
        do {
            let p = try timed("people (zebra, expect 0)") { try SegmentationService.peopleSync(SegImage(buffer: z), hair: true) }
            log("people found: \(p.count)")
        } catch { log("people failed: \(error)") }
    }

    static func testSAM3(_ out: URL) {
        guard SAM3Engine.isAvailable else { log("SAM 3.1 unavailable: \(SAM3Engine.unavailableReason ?? "?")"); return }
        let scene = syntheticScene()
        var cases: [(PixelBuffer, String, String)] = [(scene, "red ball", "synthetic"), (scene, "tree", "synthetic")]
        if let z = loadImage(zebraPath) { cases += [(z, "zebra", "zebra"), (z, "sky", "zebra"), (z, "grass", "zebra")] }
        for (buf, prompt, name) in cases {
            do {
                let si = SegImage(buffer: buf)
                let t0 = CFAbsoluteTimeGetCurrent()
                let m = try wait { try await SegmentationService.textMatches(prompt, in: si, engine: .highQuality) }
                log(String(format: "SAM3 '%@' (%@): %d match(es) %.0f ms [load %.0f, encode %.0f, detect %.0f ms]", prompt, name, m.count, (CFAbsoluteTimeGetCurrent() - t0) * 1000,
                           SegLog.value("sam3.load") ?? -1, SegLog.value("sam3.encode") ?? -1, SegLog.value("sam3.detect") ?? -1))
                write(overlay(buf, SegMask.union(m.map(\.mask)), color: .systemPink, boxes: m.map(\.box)), "objsel_sam3_\(name)_\(prompt.replacingOccurrences(of: " ", with: "_"))", out)
            } catch { log("SAM3 '\(prompt)' failed: \(error)") }
        }
    }

    static func testOrientation(_ out: URL) {
        // top-left quadrant high, rest low → mask must be at top-left in doc space
        let n = 8
        var v = [Float](repeating: -5, count: n * n)
        for y in 0..<(n / 2) { for x in 0..<(n / 2) { v[y * n + x] = 5 } }
        let m = SegMask.buffer(SegMask.fullMask(v, w: n, h: n, rect: CGRect(x: 0, y: 0, width: 80, height: 80), canvasW: 80, canvasH: 80, guide: nil, hard: true), width: 80, height: 80)
        let tl = m.alpha(10, 10), br = m.alpha(70, 70)
        log("orientation: top-left=\(tl) bottom-right=\(br) → \(tl > 128 && br < 128 ? "OK" : "FLIPPED")")
        // crop placement: logits over doc rect (20,20,40,40) of a 100×100 canvas; outside must stay 0
        let g = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        for (lbl, guide, hard) in [("hard", nil as CIImage?, true), ("soft", nil, false), ("guided", g, false)] {
            let mm = SegMask.buffer(SegMask.fullMask(v, w: n, h: n, rect: CGRect(x: 20, y: 20, width: 40, height: 40), canvasW: 100, canvasH: 100, guide: guide, hard: hard), width: 100, height: 100)
            log("crop placement \(lbl): outside(5,5)=\(mm.alpha(5, 5)) outside(90,90)=\(mm.alpha(90, 90)) inside-tl(25,25)=\(mm.alpha(25, 25)) inside-br(55,55)=\(mm.alpha(55, 55))")
        }
    }

    static func testSAM(_ out: URL) {
        let scene = syntheticScene()
        let img = SegImage(buffer: scene)
        let sam = SAMSegmenter.shared
        do {
            var t = ms { try? sam.warmUp() }
            log(String(format: "sam load: %.0f ms", t))
            var emb: SAMEmbedding!
            t = try ms { emb = try sam.embedding(img) }
            log(String(format: "sam encode (cold): %.0f ms", t))
            sam.clearCache()
            t = try ms { emb = try sam.embedding(img) }
            log(String(format: "sam encode (warm): %.0f ms", t))
            // point on the red ball
            var m: SAMMask!
            t = try ms { m = try sam.predict(.point(CGPoint(x: 300, y: 650)), emb: emb) }
            log(String(format: "sam point decode: %.1f ms score %.3f cover %.3f", t, m.score, m.coverage))
            var times: [Double] = []
            for i in 0..<20 { times.append(try ms { _ = try sam.predict(.point(CGPoint(x: 300 + i * 20, y: 650)), emb: emb) }) }
            log(String(format: "sam decode avg (20): %.1f ms", times.reduce(0, +) / Double(times.count)))
            let guide = img.image
            var buf: PixelBuffer!
            t = ms { buf = m.buffer(guide: guide, hard: false) }
            log(String(format: "full-res mask + guided refine: %.1f ms", t))
            write(overlay(scene, buf, points: [(CGPoint(x: 300, y: 650), true)]), "objsel_sam_point_ball", out)
            // box on the blue box
            let bb = CGRect(x: 540, y: 450, width: 340, height: 360)
            let mb = try sam.predict(.box(bb), emb: emb)
            write(overlay(scene, mb.buffer(guide: guide, hard: false), boxes: [bb]), "objsel_sam_box_bluebox", out)
        } catch {
            log("SAM test failed: \(error)")
        }
    }
}
