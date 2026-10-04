import AppKit
import SwiftUI
import CoreImage
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

/// `LUMEN_SELFTEST_ONLY=assist Lumen --selftest <dir>`: headless tests of the smart assists (writes PNGs + timings).
/// Sub-filter with LUMEN_ASSIST_ONLY=names,search,crop,alt,ocr,quality,subject (comma separated).
/// Uses synthetic scenes and generic macOS system pictures only.
enum AssistSelfTest {
    static var failures = 0

    static func log(_ s: String) { print("[assist] " + s) }

    static func check(_ ok: Bool, _ what: String) {
        if ok { print("[assist] ok   \(what)") } else { failures += 1; print("FAIL [assist] \(what)") }
    }

    static func want(_ n: String) -> Bool {
        guard let only = ProcessInfo.processInfo.environment["LUMEN_ASSIST_ONLY"], !only.isEmpty else { return true }
        return only.split(separator: ",").contains { n.hasPrefix($0) }
    }

    /// Runs an async body to completion from the main thread, pumping the run loop (MainActor hops keep working).
    static func sync<T>(_ body: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task.detached { do { result = .success(try await body()) } catch { result = .failure(error) } }
        while result == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        return try result!.get()
    }

    @discardableResult
    static func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = try body()
        print(String(format: "[assist] ⏱ %@: %.2f s", label, CFAbsoluteTimeGetCurrent() - t0))
        return r
    }

    static func save(_ cg: CGImage?, _ name: String, _ out: URL) {
        guard let cg else { return }
        Assist.writePNG(cg, out.appendingPathComponent("assist_" + name + ".png"))
        print("wrote assist_\(name)")
    }

    static func save(_ st: DocumentState, _ name: String, _ out: URL) { save(Assist.compositeCG(st), name, out) }

    // MARK: Pictures

    static let aerialURL = URL(fileURLWithPath: "/System/Library/Wallpapers/.default/DefaultAerial.jpg")
    static func userPicture(_ name: String) -> URL { URL(fileURLWithPath: "/Library/User Pictures/\(name).heic") }

    static func picture(_ url: URL, maxSide: Int) -> CGImage? {
        guard let cg = Assist.loadCG(url, maxSide: maxSide) else { return nil }
        return PixelBuffer(cgImage: cg).makeCGImage()      // normalise to sRGB RGBA8
    }

    /// Lake shore with a level horizon (or a synthetic landscape when the wallpaper is missing).
    static func landscape(_ maxSide: Int = 1600) -> CGImage {
        picture(aerialURL, maxSide: maxSide) ?? NeuralSelfTest.synthLandscape(maxSide, maxSide * 9 / 16)
    }

    static func animal(_ name: String, side: Int = 512) -> CGImage {
        if let cg = picture(userPicture("Animals/\(name)"), maxSide: side) { return cg }
        // fallback: a bird-ish blob on a dark backdrop
        let b = PixelBuffer(width: side, height: side)
        let c = b.context
        c.setFillColor(RGBA(hex: "10141A")!.cgColor); c.fill(CGRect(x: 0, y: 0, width: side, height: side))
        c.setFillColor(RGBA(hex: "E8E2D0")!.cgColor); c.fillEllipse(in: CGRect(x: side / 4, y: side / 6, width: side / 2, height: side * 2 / 3))
        c.setFillColor(RGBA(hex: "E5A91A")!.cgColor); c.fillEllipse(in: CGRect(x: side / 5, y: side / 3, width: side / 6, height: side / 10))
        b.markDirty()
        return b.makeCGImage()
    }

    static func draw(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        body(b.context)
        b.markDirty()
        return b
    }

    static func transformed(_ cg: CGImage, _ f: (CIImage) -> CIImage) -> CGImage {
        let r = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let img = f(CIImage(cgImage: cg)).cropped(to: r)
        return RenderEngine.readbackContext.createCGImage(img, from: r, format: .RGBA8, colorSpace: sRGBSpace) ?? cg
    }

    static func blurred(_ cg: CGImage, _ radius: Double) -> CGImage { transformed(cg) { $0.clampedToExtent().applyingGaussianBlur(sigma: radius) } }

    /// Per-pixel byte edit (RGBA, unpremultiplied for opaque pictures).
    static func edit(_ cg: CGImage, _ f: (inout [UInt8], Int) -> Void) -> CGImage {
        let w = cg.width, h = cg.height
        var px = Assist.rgba(cg, w, h)
        for i in 0..<(w * h) { f(&px, i * 4) }
        let prov = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: sRGBSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    struct LCG { var s: UInt64
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let v: UInt64 = (s >> 33) & 0xFFFFFF
            return Double(v) / 16777215.0
        }
        mutating func gauss() -> Double {
            let u: Double = max(1e-9, next())
            let v: Double = next()
            let mag: Double = (-2.0 * Foundation.log(u)).squareRoot()
            return mag * cos(2.0 * Double.pi * v)
        }
    }

    static func noisy(_ cg: CGImage, sigma: Double) -> CGImage {
        var rng = LCG(s: 42)
        return edit(cg) { px, i in
            for c in 0..<3 { px[i + c] = UInt8(max(0, min(255, Double(px[i + c]) + rng.gauss() * sigma))) }
        }
    }

    static func cast(_ cg: CGImage, r: Double, g: Double, b: Double) -> CGImage {
        edit(cg) { px, i in
            px[i] = UInt8(min(255, Double(px[i]) * r)); px[i + 1] = UInt8(min(255, Double(px[i + 1]) * g)); px[i + 2] = UInt8(min(255, Double(px[i + 2]) * b))
        }
    }

    /// Rotates about the centre (degrees, clockwise on screen) and crops to the inscribed rectangle.
    static func rotated(_ cg: CGImage, degrees: Double) -> CGImage {
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let a = CGFloat(degrees * .pi / 180)
        let s = StraightenCropTool.inscribedSize(W, H, angle: a)
        let w = Int(s.width.rounded(.down)), h = Int(s.height.rounded(.down))
        let b = PixelBuffer(width: w, height: h)
        let c = b.context
        c.saveGState()
        c.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        c.rotate(by: a)
        c.translateBy(x: -W / 2, y: -H / 2)
        b.drawImage(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        c.restoreGState()
        b.markDirty()
        return b.makeCGImage()
    }

    static func jpegRoundTrip(_ cg: CGImage, quality: Double) -> CGImage {
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, UTType.jpeg.identifier as CFString, 1, nil) else { return cg }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        guard let src = CGImageSourceCreateWithData(d, nil), let out = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return cg }
        return PixelBuffer(cgImage: out).makeCGImage()
    }

    static func meanDiff(_ a: CGImage, _ b: CGImage, in r: CGRect? = nil, mask: ((Int, Int) -> Bool)? = nil) -> Double {
        let w = a.width, h = a.height
        let pa = Assist.rgba(a, w, h), pb = Assist.rgba(b, w, h)
        let rr = (r ?? CGRect(x: 0, y: 0, width: w, height: h)).integral
        var s = 0.0, n = 0.0
        for y in max(0, Int(rr.minY))..<min(h, Int(rr.maxY)) {
            for x in max(0, Int(rr.minX))..<min(w, Int(rr.maxX)) {
                if let m = mask, !m(x, y) { continue }
                let i = (y * w + x) * 4
                s += abs(Double(pa[i]) - Double(pb[i])) + abs(Double(pa[i + 1]) - Double(pb[i + 1])) + abs(Double(pa[i + 2]) - Double(pb[i + 2]))
                n += 3
            }
        }
        return n > 0 ? s / n : 0
    }

    static func doc(_ cg: CGImage, name: String = "Layer 1") -> Document {
        var st = DocumentState(width: cg.width, height: cg.height)
        st.layers = [Layer.raster(name: name, buffer: PixelBuffer(cgImage: cg))]
        return Document(state: st, name: "assist-test")
    }

    // MARK: Entry

    static func run(_ out: URL) {
        print("== assist self test")
        log("models: florence=\(AssistCaptioner.shared.isAvailable) sam=\(SegModels.samInstalled) matting=\(SegModels.mattingInstalled) lama=\(LamaInpainter.isAvailable) depth=\(DepthEstimator.isAvailable) nafnet=\(Restoration.isAvailable(.denoise)); text embedding: \(AssistEmbedding.engine)")
        failures = 0
        // Apple Vision stops answering while the machine is saturated (seen with many parallel test runs):
        // wait for it instead of reporting dozens of misleading failures
        var waited = 0
        while !AssistVision.isResponsive() && waited < 600 { if waited == 0 { log("waiting for Apple Vision to respond…") }; Thread.sleep(forTimeInterval: 5); waited += 5 }
        if waited > 0 { log("Vision \(AssistVision.isResponsive() ? "responded after" : "still not responding after") \(waited) s") }
        if ProcessInfo.processInfo.environment["LUMEN_ASSIST_ONLY"] == "bench" { bench(); return }
        if want("names") { names(out) }
        if want("search") { search(out) }
        if want("crop") { crop(out) }
        if want("alt") { altText(out) }
        if want("ocr") { ocr(out) }
        if want("quality") { quality(out) }
        if want("subject") { subject(out) }
        if want("ui") { ui(out) }
        // leave the app model as we found it
        for d in AppModel.shared.documents where d.name.hasPrefix("assist-test") { AppModel.shared.close(d) }
        log(failures == 0 ? "all assist checks passed" : "\(failures) assist check(s) FAILED")
    }

    /// LUMEN_ASSIST_ONLY=bench: Florence-2 timings (optionally with LUMEN_ASSIST_FLORENCE_UNITS=gpu|all|ane).
    static func bench() {
        if ProcessInfo.processInfo.environment["LUMEN_ASSIST_BENCH"] == "lama" {
            let img = landscape(1100)
            let hole = PixelBuffer(width: img.width, height: img.height, format: .gray)
            hole.context.setFillColor(gray: 1, alpha: 1)
            hole.context.fill(CGRect(x: 300, y: 200, width: 260, height: 70))
            hole.markDirty()
            let hp = PlanarImage.gray(hole.makeCGImage())
            for i in 0..<3 { _ = try? time("LaMa inpaint #\(i + 1) (one 260×70 hole)") { try sync { try await LamaInpainter.inpaint(img, hole: hp) } } }
            let noisyImg = noisy(NImg.fitted(img, maxSide: 800), sigma: 10)
            for i in 0..<2 { _ = try? time("NAFNet denoise #\(i + 1) (800 px)") { try sync { try await Restoration.run(noisyImg, .denoise) } } }
            for i in 0..<2 { _ = try? time("Depth Anything #\(i + 1)") { try sync { try await DepthEstimator.depth(img) } } }
            // font matching
            let b = draw(500, 120) { c in c.setFillColor(gray: 1, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: 500, height: 120)) }
            var t = TextContent(); t.text = "Open daily"; t.fontName = "Georgia"; t.fontSize = 60; t.position = CGPoint(x: 20, y: 20)
            var st = DocumentState(width: 500, height: 120); st.layers = [Layer.raster(name: "b", buffer: b), Layer(name: "t", content: .text(t))]
            let cg = Assist.compositeCG(st)!
            let target = MatchFontEngine.target(cg)
            log("font target: \(target != nil)")
            if let target { for f in ["Georgia", "Helvetica", "Helvetica-Bold", "Futura-Bold", "TimesNewRomanPSMT"] { log("  \(f): \(MatchFontEngine.score(target, text: "Open daily", fontName: f).map { String(format: "%.2f", $0) } ?? "nil")") } }
            let line = AssistOCR.detect(cg, docSize: CGSize(width: 500, height: 120)).first
            if let line { let s = AssistOCR.analyze(line, image: cg); log("analyze: \(s.fontName) ranking \(s.fontRanking) ink \(s.ink) contrast \(s.contrast)") }
            return
        }
        guard AssistCaptioner.shared.isAvailable else { log("Florence-2 not installed"); return }
        for (label, cg) in [("eagle", animal("Eagle")), ("landscape", landscape(1024)), ("parrot", animal("Parrot"))] {
            for task in [AssistCaptioner.Task.caption, .detailed] {
                let t0 = CFAbsoluteTimeGetCurrent()
                let s = (try? AssistCaptioner.shared.generate(cg, task: task)) ?? "ERROR"
                let t = AssistCaptioner.shared.lastTiming
                log(String(format: "bench %@ %@: %.2f s (load %.1f s; vision %.0f ms, text %.0f ms, decode %.0f ms, %d tokens) → %@", label, "\(task)", CFAbsoluteTimeGetCurrent() - t0,
                           AssistCaptioner.shared.loadSeconds, t.vision, t.text, t.decode, t.tokens, s))
            }
        }
    }

    // MARK: 1. Auto names (+ shared scene)

    struct Scene {
        var doc: Document
        var ids: [String: UUID] = [:]
    }

    static func makeScene() -> Scene {
        let W = 1200, H = 800
        var st = DocumentState(width: W, height: H)
        var ids: [String: UUID] = [:]
        func add(_ key: String, _ l: Layer) { st.layers.append(l); ids[key] = l.id }

        // 1. full-canvas photo
        let photo = PixelBuffer(cgImage: NImg.resized(landscape(1600), W, H))
        add("photo", Layer.raster(name: "Layer 1", buffer: photo))
        // 2. yellow sun, top right
        let sun = draw(220, 220) { c in
            c.setFillColor(RGBA(hex: "FFC81E")!.cgColor)
            for i in 0..<12 {
                let a = CGFloat(i) * .pi / 6
                c.saveGState(); c.translateBy(x: 110, y: 110); c.rotate(by: a)
                c.fill(CGRect(x: -7, y: 70, width: 14, height: 36)); c.restoreGState()
            }
            c.fillEllipse(in: CGRect(x: 50, y: 50, width: 120, height: 120))
        }
        add("sun", Layer.raster(name: "Layer 2", buffer: sun, origin: IPoint(x: 930, y: 40)))
        // 3. red car, bottom left
        let car = draw(360, 170) { c in
            c.setFillColor(RGBA(hex: "D32222")!.cgColor)
            c.addPath(CGPath(roundedRect: CGRect(x: 10, y: 70, width: 340, height: 60), cornerWidth: 18, cornerHeight: 18, transform: nil)); c.fillPath()
            let roof = CGMutablePath(); roof.move(to: CGPoint(x: 80, y: 74)); roof.addLine(to: CGPoint(x: 120, y: 22)); roof.addLine(to: CGPoint(x: 240, y: 22)); roof.addLine(to: CGPoint(x: 290, y: 74)); roof.closeSubpath()
            c.addPath(roof); c.fillPath()
            c.setFillColor(RGBA(hex: "BFE3F5")!.cgColor)
            c.fill(CGRect(x: 126, y: 32, width: 50, height: 36)); c.fill(CGRect(x: 186, y: 32, width: 58, height: 36))
            c.setFillColor(RGBA(hex: "151515")!.cgColor)
            c.fillEllipse(in: CGRect(x: 52, y: 100, width: 62, height: 62)); c.fillEllipse(in: CGRect(x: 246, y: 100, width: 62, height: 62))
            c.setFillColor(RGBA(hex: "B9B9B9")!.cgColor)
            c.fillEllipse(in: CGRect(x: 70, y: 118, width: 26, height: 26)); c.fillEllipse(in: CGRect(x: 264, y: 118, width: 26, height: 26))
            c.setFillColor(RGBA(hex: "FFE37A")!.cgColor); c.fillEllipse(in: CGRect(x: 328, y: 82, width: 16, height: 14))
        }
        add("car", Layer.raster(name: "Layer 3", buffer: car, origin: IPoint(x: 60, y: 580)))
        // 4. blue rounded rectangle with a drop shadow
        var rect = Layer(name: "Rectangle 1", content: .shape(ShapeContent(geometry: .rectangle(CGRect(x: 470, y: 300, width: 300, height: 150), cornerRadius: 28), fill: .color(RGBA(hex: "2F6FE0")!))))
        rect.effects.dropShadow.enabled = true; rect.effects.dropShadow.distance = 10; rect.effects.dropShadow.size = 14
        add("rect", rect)
        // 5. green circle
        add("circle", Layer(name: "Ellipse 1", content: .shape(ShapeContent(geometry: .ellipse(CGRect(x: 80, y: 90, width: 120, height: 120)), fill: .color(RGBA(hex: "2FA84F")!)))))
        // 6. headline text
        var t = TextContent()
        t.text = "SUMMER SALE 50% OFF"; t.fontName = "Helvetica-Bold"; t.fontSize = 44; t.color = .white; t.position = CGPoint(x: 480, y: 348)
        t.fontSize = 24
        add("text", Layer(name: "Text", content: .text(t)))
        // 7–8. adjustments
        var lv = AdjustmentSettings(kind: .levels); lv.levels[0].inBlack = 12; lv.levels[0].inWhite = 240
        add("levels", Layer(name: "Levels 1", content: .adjustment(lv)))
        var hs = AdjustmentSettings(kind: .hueSaturation); hs.hsSaturation = -20
        add("huesat", Layer(name: "Hue/Saturation 1", content: .adjustment(hs)))
        // 9. hidden solid fill
        var fill = Layer(name: "Color Fill 1", content: .fill(FillContent(paint: .color(RGBA(hex: "F08A1C")!))))
        fill.isVisible = false
        add("fill", fill)
        // 10. button group
        var bt = TextContent(); bt.text = "Buy now"; bt.fontName = "Helvetica"; bt.fontSize = 26; bt.color = .white; bt.position = CGPoint(x: 905, y: 676)
        let pill = Layer(name: "Rectangle 2", content: .shape(ShapeContent(geometry: .rectangle(CGRect(x: 870, y: 660, width: 170, height: 64), cornerRadius: 32), fill: .color(RGBA(hex: "8E2BD0")!))))
        let btText = Layer(name: "Text", content: .text(bt))
        let group = Layer(name: "Group 1", content: .group(GroupContent(children: [pill, btText], isExpanded: true)))
        add("group", group)
        ids["pill"] = pill.id; ids["buttonText"] = btText.id
        // 11. smart object: parrot
        let parrot = PixelBuffer(cgImage: animal("Parrot", side: 512))
        add("parrot", Layer(name: "Layer 4", content: .smartObject(SmartObjectContent(source: .image(parrot), quad: Quad(rect: CGRect(x: 880, y: 330, width: 260, height: 260)), sourceName: "Parrot"))))
        // 12. blurred picture, left middle
        let soft = PixelBuffer(cgImage: blurred(animal("Eagle", side: 300), 7))
        add("blurry", Layer.raster(name: "Layer 5", buffer: soft, origin: IPoint(x: 70, y: 250)))
        // 13. custom name stays
        let custom = draw(90, 90) { c in c.setFillColor(RGBA(hex: "111111")!.cgColor); c.fill(CGRect(x: 0, y: 0, width: 90, height: 90)) }
        add("custom", Layer.raster(name: "Logo plate", buffer: custom, origin: IPoint(x: 560, y: 60)))
        return Scene(doc: Document(state: st, name: "assist-test-scene"), ids: ids)
    }

    static func names(_ out: URL) {
        log("— auto names")
        let sc = makeScene()
        let d = sc.doc
        save(d.state, "names_scene", out)
        let before = d.state
        let targets = AssistNaming.targets(d)
        check(!targets.contains(sc.ids["custom"]!) && targets.contains(sc.ids["sun"]!) && targets.contains(sc.ids["group"]!), "targets are the default-named layers only (\(targets.count) of \(d.state.allLayers.count))")
        guard let r = try? time("name \(targets.count) layers", { try sync { await AssistNaming.computeNames(state: before, ids: targets) } }) else { check(false, "computeNames"); return }
        let changed = AssistNaming.apply(d, r)
        func name(_ k: String) -> String { d.state.layer(sc.ids[k]!)?.name ?? "?" }
        for l in d.state.allLayers.reversed() {
            let old = before.layer(l.id)?.name ?? ""
            log("  name: \(old.padding(toLength: 18, withPad: " ", startingAt: 0)) → \(l.name)  [\(r.sources[l.id] ?? "kept")]" + (r.captions[l.id].map { "  caption: \($0)" } ?? ""))
        }
        check(name("text") == "SUMMER SALE 50% OFF", "text layer named after its text (\(name("text")))")
        check(name("rect") == "Blue Rounded Rectangle", "shape → colour + kind (\(name("rect")))")
        check(name("circle") == "Green Circle", "ellipse with equal sides → circle (\(name("circle")))")
        check(name("levels") == "Levels 12–240", "adjustment → kind + key value (\(name("levels")))")
        check(name("huesat") == "Saturation −20", "hue/saturation → changed value (\(name("huesat")))")
        check(name("fill") == "Orange Fill", "fill layer → colour (\(name("fill")))")
        check(name("custom") == "Logo plate", "custom names are left alone")
        check(name("buttonText") == "Buy now" && name("pill") == "Purple Pill", "group children named (\(name("pill")) / \(name("buttonText")))")
        check(name("group") == "Buy now + Purple Pill", "group summarises its children (\(name("group")))")
        let sun = name("sun").lowercased(), car = name("car").lowercased(), parrot = name("parrot").lowercased(), photo = name("photo").lowercased(), soft = name("blurry").lowercased()
        check((sun.contains("sun") || sun.contains("yellow")) && sun.hasSuffix("top right"), "pixel layer: yellow sun, top right (\(name("sun")))")
        check((car.contains("car") || car.contains("red")) && car.hasSuffix("bottom left"), "pixel layer: red car, bottom left (\(name("car")))")
        check(parrot.contains("parrot") || parrot.contains("bird") || parrot.contains("macaw"), "smart object described from its pixels (\(name("parrot")))")
        check(!AssistNaming.isDefaultName(name("photo")) && !photo.contains("—"), "full-canvas photo gets a description without a position (\(name("photo")))")
        check(!AssistNaming.isDefaultName(name("blurry")) && soft.hasSuffix("left"), "blurred picture still gets a name + position (\(name("blurry")))")
        let all = d.state.allLayers.map(\.name)
        check(Set(all).count == all.count, "names are unique")
        check(all.allSatisfy { $0.count <= 48 && !$0.isEmpty }, "names are short (longest \(all.map(\.count).max() ?? 0) characters)")
        check(changed == targets.count, "one undo step renames \(changed) layers")
        d.undo()
        check(d.state.layer(sc.ids["sun"]!)?.name == "Layer 2" && d.state.layer(sc.ids["text"]!)?.name == "Text", "undo restores the old names")
        d.redo()
        // {auto} token in the batch rename dialog
        AssistNameCache.shared.clear()
        var s = BatchRenameSettings(); s.template = "{auto}"
        let layers = [before.layer(sc.ids["rect"]!)!, before.layer(sc.ids["text"]!)!, before.layer(sc.ids["levels"]!)!]
        let tok = BatchRename.names(for: layers, s, state: before)
        check(tok == ["Blue Rounded Rectangle", "SUMMER SALE 50% OFF", "Levels 12–240"], "{auto} token in Rename Layers (\(tok))")
        s.template = "{n} {auto}"
        check(BatchRename.names(for: [layers[0]], s, state: before) == ["01 Blue Rounded Rectangle"], "{auto} combines with other tokens")
        for (id, n) in r.names { AssistNameCache.shared.store(id, n) }
        s.template = "{auto}"
        check(BatchRename.names(for: [before.layer(sc.ids["sun"]!)!], s, state: before).first == name("sun"), "{auto} uses the computed description for pixel layers")
        // default-name detection
        check(AssistNaming.isDefaultName("Layer 12") && AssistNaming.isDefaultName("Rectangle 1 copy 2") && AssistNaming.isDefaultName("Hue/Saturation 3")
              && !AssistNaming.isDefaultName("Background") && !AssistNaming.isDefaultName("Hero shot"), "default-name detection")
        // caption → head phrase
        let heads = [("A yellow sun in a blue sky.", "Yellow Sun"), ("The image shows a red car parked on a street.", "Red Car"),
                     ("A close up of a parrot with a yellow beak", "Parrot"), ("two dogs playing in the grass", "Two Dogs")]
        for (c, want) in heads { check(AssistText.headPhrase(c) == want, "head phrase “\(c)” → \(AssistText.headPhrase(c) ?? "nil")") }

        // a single photo layer
        let pd = doc(animal("Eagle"))
        if let pr = try? time("name a photo layer", { try sync { await AssistNaming.computeNames(state: pd.state, ids: AssistNaming.targets(pd)) } }) {
            AssistNaming.apply(pd, pr)
            let n = pd.state.layers[0].name
            log("  photo layer: “\(n)” [\(pr.sources.values.first ?? "")] caption: \(pr.captions.values.first ?? "—")")
            check(n.lowercased().contains("eagle") || n.lowercased().contains("bird"), "photo layer named from its content (\(n))")
        }
        if AssistCaptioner.shared.isAvailable {
            let t = AssistCaptioner.shared.lastTiming
            log(String(format: "  Florence-2: one-time model load %.1f s; last caption: vision %.0f ms, text %.0f ms, decode %.0f ms for %d tokens", AssistCaptioner.shared.loadSeconds, t.vision, t.text, t.decode, t.tokens))
            // fallback path without Florence
            if let fr = try? time("name layers without Florence (Vision only)", { try sync { await AssistNaming.computeNames(state: before, ids: targets, useFlorence: false) } }) {
                let n = fr.names[sc.ids["parrot"]!] ?? ""
                log("  Vision-only names: sun “\(fr.names[sc.ids["sun"]!] ?? "")”, car “\(fr.names[sc.ids["car"]!] ?? "")”, parrot “\(n)”, photo “\(fr.names[sc.ids["photo"]!] ?? "")”")
                check(!n.isEmpty && !AssistNaming.isDefaultName(n), "Vision fallback still names pixel layers (\(n))")
            }
        }
    }

    // MARK: 2. Semantic search

    static func search(_ out: URL) {
        log("— semantic layer search")
        var sc = makeScene()
        let d = sc.doc
        // two more suns for "similar looking"
        if let sun = d.state.layer(sc.ids["sun"]!) {
            var a = sun.duplicated(newName: "Layer 6"); a.translate(dx: -700, dy: 20)
            var b = sun.duplicated(newName: "Layer 7"); b.translate(dx: -350, dy: 60)
            d.state.layers.append(a); d.state.layers.append(b)
            sc.ids["sun2"] = a.id; sc.ids["sun3"] = b.id
        }
        let st = d.state
        let n = (try? time("index \(st.allLayers.count) layers (captions, labels, OCR, colours, sharpness, feature prints)", { try sync { await AssistIndex.shared.ensure(st) } })) ?? 0
        check(n == st.allLayers.count, "every layer indexed once (\(n))")
        let again = (try? sync { await AssistIndex.shared.ensure(st) }) ?? -1
        check(again == 0, "second pass uses the cache")
        for (desc, _) in AssistIndex.shared.descriptors(st) {
            log("  descriptor \(desc.name): \(desc.summary) | labels \(desc.visual.labels.prefix(3)) | colours \(desc.visual.colors.prefix(3)) | blur \(desc.visual.blur.map { String(format: "%.2f", $0) } ?? "—") | area \(String(format: "%.2f", desc.areaFraction)) | fx \(desc.effects)")
        }
        func top(_ q: String) -> [AssistSearch.Hit] {
            let t0 = CFAbsoluteTimeGetCurrent()
            let hits = AssistSearch.search(q, in: st)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            log(String(format: "  query “%@” (%.0f ms): %@", q, ms, hits.prefix(4).map { "\(st.layer($0.id)?.name ?? "?") \(Int($0.score * 100))% [\($0.reasons.joined(separator: ","))]" }.joined(separator: " · ")))
            return hits
        }
        func first(_ q: String, _ key: String, _ what: String) {
            let h = top(q)
            check(h.first?.id == sc.ids[key], "“\(q)” → \(what)")
        }
        first("the red car", "car", "the car layer ranks first")
        first("text that says sale", "text", "the SALE headline ranks first")
        let sale = AssistSearch.search("text that says sale", in: st)
        check(sale.count == 1, "“says sale” returns only layers containing that text (\(sale.count))")
        first("blurry layers", "blurry", "the blurred picture ranks first")
        let shadow = top("layers with drop shadow")
        check(shadow.count == 1 && shadow.first?.id == sc.ids["rect"], "“layers with drop shadow” → exactly the layer with that effect")
        first("big images", "photo", "the full-canvas photo ranks first")
        let suns = top("yellow sun")
        let sunIDs = Set([sc.ids["sun"]!, sc.ids["sun2"]!, sc.ids["sun3"]!])
        check(suns.count >= 3 && Set(suns.prefix(3).map(\.id)) == sunIDs, "“yellow sun” → the three sun layers lead")
        first("hidden layers", "fill", "the hidden fill layer")
        first("purple button shape", "pill", "the purple pill shape")
        let bird = top("a bird")
        check(bird.first?.id == sc.ids["parrot"] || bird.first?.id == sc.ids["blurry"], "“a bird” → one of the bird pictures (synonym match)")
        check(top("zebra crossing").isEmpty || top("zebra crossing").first!.score < 0.5, "unrelated query has no strong match")
        // similar looking
        let sim = time("similar-looking layers") { AssistSearch.similar(to: sc.ids["sun"]!, in: st) }
        log("  similar to the sun: " + sim.map { "\(st.layer($0.id)?.name ?? "?") \(String(format: "%.2f", $0.distance))" }.joined(separator: ", "))
        check(Set(sim.prefix(2).map(\.id)) == Set([sc.ids["sun2"]!, sc.ids["sun3"]!]), "Select Similar finds the other two suns first")
        check(!sim.contains { $0.id == sc.ids["text"] || $0.id == sc.ids["photo"] }, "… and not the text or the photo")
        // reveal expands the parent group
        d.state.updateLayer(sc.ids["group"]!) { $0.isExpanded = false }
        AssistSearch.reveal(d, ids: [sc.ids["pill"]!])
        check(d.state.layer(sc.ids["group"]!)?.isExpanded == true, "clicking a result reveals it inside a collapsed group")
    }

    // MARK: 3. Crops

    static func overlay(_ cg: CGImage, _ cands: [AssistCrop.Candidate], extra: [CGRect] = []) -> CGImage {
        let b = PixelBuffer(cgImage: cg)
        let c = b.context
        let colours = ["FF3B30", "34C759", "0A84FF", "FFD60A", "BF5AF2", "FF9F0A"]
        let lw = max(2, CGFloat(cg.width) / 300)
        for (i, k) in cands.enumerated() {
            c.setStrokeColor(RGBA(hex: colours[i % colours.count])!.cgColor)
            c.setLineWidth(lw)
            c.stroke(k.rect.insetBy(dx: lw / 2 + CGFloat(i), dy: lw / 2 + CGFloat(i)))
        }
        c.setStrokeColor(NSColor.white.cgColor); c.setLineDash(phase: 0, lengths: [6, 4]); c.setLineWidth(lw * 0.7)
        for r in extra { c.stroke(r) }
        b.markDirty()
        return b.makeCGImage()
    }

    static func crop(_ out: URL) {
        log("— crop suggestions")
        // (a) a clear subject
        let bird = animal("Eagle")
        let subject: CGRect? = (try? sync { try await AssistSubject.subjectMask(PixelBuffer(cgImage: bird), hair: false) }).flatMap { $0.opaqueBounds(threshold: 127)?.cgRect }
        let ca = (try? time("suggest crops, 5 ratios × 3 (512 px)", { try sync { await AssistCrop.suggest(bird) } })) ?? []
        check(ca.count == 15, "three candidates for each of five ratios (\(ca.count))")
        var best: [AssistCrop.Candidate] = []
        for r in AssistCrop.Ratio.standard {
            let list = ca.filter { $0.ratio == r }
            guard let b = list.first else { continue }
            best.append(b)
            let ratioOK = abs(Double(b.rect.width / b.rect.height) - r.value) < 0.02
            var inside = 1.0
            if let s = subject { let i = s.intersection(b.rect); inside = i.isNull ? 0 : Double(i.width * i.height) / Double(s.width * s.height) }
            log(String(format: "  %@: %@ score %.0f aesthetics %@ subject inside %.0f%% [%@]", r.label, "\(b.rect.integral)", b.score, b.aesthetics.map { String(format: "%.2f", $0) } ?? "—", inside * 100, b.notes.joined(separator: ", ")))
            check(ratioOK, "\(r.label) candidate has the right aspect ratio")
            // the eagle's head (top of the subject box) must stay in frame even for the narrow ratios
            if let s = subject {
                let head = CGRect(x: s.minX + s.width * 0.1, y: s.minY, width: s.width * 0.55, height: s.height * 0.45)
                let hi = head.intersection(b.rect)
                let headIn = hi.isNull ? 0 : Double(hi.width * hi.height) / Double(head.width * head.height)
                check(headIn > 0.8, "\(r.label) keeps the subject's head in frame (\(Int(headIn * 100))%)")
            }
            check(list.count == 3 && list[0].score >= list[1].score && list[1].score >= list[2].score, "\(r.label) candidates are ranked")
        }
        save(overlay(bird, best, extra: subject.map { [$0] } ?? []), "crop_subject", out)

        // (b) faces are never cut: scene with two (injected) face boxes near the edges
        let W = 1200, H = 800
        let portrait = draw(W, H) { c in
            let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "6C8FB3")!.cgColor, RGBA(hex: "D9C7A8")!.cgColor] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: H), options: [])
            for (x, y, col) in [(250.0, 330.0, "E0B090"), (930.0, 300.0, "C99572")] {
                c.setFillColor(RGBA(hex: "2B3A55")!.cgColor); c.fillEllipse(in: CGRect(x: x - 150, y: y + 90, width: 300, height: 520))
                c.setFillColor(RGBA(hex: col)!.cgColor); c.fillEllipse(in: CGRect(x: x - 80, y: y - 100, width: 160, height: 200))
                c.setFillColor(RGBA(hex: "3A2A20")!.cgColor); c.fillEllipse(in: CGRect(x: x - 86, y: y - 118, width: 172, height: 90))
            }
        }.makeCGImage()
        var ctx = AssistCrop.context(portrait)
        let faces = [CGRect(x: 170, y: 230, width: 160, height: 200), CGRect(x: 850, y: 200, width: 160, height: 200)]
        log("  Vision found \(ctx.faces.count) faces in the drawn scene; injecting \(faces.count) face boxes")
        ctx.faces = faces
        ctx.protected = faces.map { f in CGRect(x: f.minX - f.width * 0.35, y: f.minY - f.height * 0.55, width: f.width * 1.7, height: f.height * 2.0).intersection(CGRect(x: 0, y: 0, width: W, height: H)) }
        let cb = (try? sync { await AssistCrop.suggest(portrait, context: ctx, useAesthetics: false) }) ?? []
        var bestB: [AssistCrop.Candidate] = []
        for r in AssistCrop.Ratio.standard {
            guard let b = cb.first(where: { $0.ratio == r }) else { continue }
            bestB.append(b)
            let cut = faces.filter { f in let i = f.intersection(b.rect); let frac = i.isNull ? 0 : Double(i.width * i.height) / Double(f.width * f.height); return frac > 0.02 && frac < 0.98 }.count
            let kept = faces.filter { b.rect.contains($0) }.count
            log("  \(r.label): \(b.rect.integral) keeps \(kept) face(s), cuts \(cut) [\(b.notes.joined(separator: ", "))]")
            check(cut == 0 && kept >= 1, "\(r.label): no face is cut, at least one is fully inside")
        }
        if let wide = cb.first(where: { $0.ratio.label == "16:9" }) { check(faces.allSatisfy { wide.rect.contains($0) }, "16:9 keeps both faces") }
        save(overlay(portrait, bestB, extra: faces), "crop_faces", out)

        // (c) tilted horizon → straighten + crop, then reframe
        let level = landscape(1400)
        let tilted = rotated(level, degrees: 4)
        let d = doc(tilted)
        AppModel.shared.add(d)
        let t0 = AssistVision.horizon(tilted).map { $0 * 180 / .pi }
        log("  horizon of the level picture: \(AssistVision.horizon(level).map { String(format: "%.2f°", $0 * 180 / .pi) } ?? "none"); rotated 4° → detected \(t0.map { String(format: "%.2f°", $0) } ?? "none")")
        check(t0.map { abs(abs($0) - 4) < 1.2 } ?? false, "tilt of a 4° rotated horizon is measured")
        save(tilted, "crop_tilted_before", out)
        let applied = time("auto-straighten + crop") { AssistCrop.autoStraightenAndCrop(d) }
        check(applied != nil, "Auto-Straighten + Crop ran")
        let after = Assist.compositeCG(d.state)!
        let t1 = AssistVision.horizon(after).map { $0 * 180 / .pi } ?? 0
        check(abs(t1) < 0.8, String(format: "horizon is level afterwards (%.2f°)", t1))
        check(d.state.width < tilted.width && d.state.height < tilted.height, "cropped to the clean rectangle (\(d.state.width)×\(d.state.height) from \(tilted.width)×\(tilted.height))")
        let corners = [after.cropping(to: CGRect(x: 0, y: 0, width: 4, height: 4)), after.cropping(to: CGRect(x: after.width - 4, y: after.height - 4, width: 4, height: 4))].compactMap { $0 }
        check(corners.allSatisfy { Assist.rgba($0, 4, 4).enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 255 } }, "no empty corners after the crop")
        save(after, "crop_tilted_after", out)
        let cc = (try? time("suggest crops (1400 px landscape)", { try sync { await AssistCrop.suggest(after) } })) ?? []
        save(overlay(after, AssistCrop.Ratio.standard.compactMap { r in cc.first { $0.ratio == r } }), "crop_landscape", out)
        // non-destructive apply + artboards + custom ratio
        if let sq = cc.first(where: { $0.ratio.label == "1:1" }) {
            let (w0, h0) = (d.state.width, d.state.height)
            let steps = d.history.count
            AssistCrop.apply(sq, to: d)
            check(d.state.width == Int(sq.rect.width) && d.state.height == Int(sq.rect.height) && d.history.count == steps + 1, "Apply Crop: canvas is \(d.state.width)×\(d.state.height), one undo step")
            let buf = d.state.layers[0].raster?.buffer
            check((buf?.width ?? 0) >= w0 && (buf?.height ?? 0) >= h0, "pixels outside the crop are kept (layer still \(buf?.width ?? 0)×\(buf?.height ?? 0))")
            d.undo()
            check(d.state.width == w0 && d.state.height == h0, "undo restores the canvas")
            let picks = [sq] + cc.filter { $0.ratio.label == "9:16" }.prefix(1)
            let ids = AssistCrop.createArtboards(picks, in: d)
            check(ids.count == 2 && d.state.layers.filter(\.isArtboard).count == 2 && d.state.width > w0, "two artboards added beside the image (canvas \(d.state.width)×\(d.state.height))")
            save(d.state, "crop_artboards", out)
            d.undo()
            check(d.state.width == w0 && d.state.layers.count == 1, "artboards are one undo step")
        }
        let custom = AssistCrop.Ratio.parse("2.35:1")
        check(custom != nil && AssistCrop.Ratio.parse("5x7")?.value == 5.0 / 7 && AssistCrop.Ratio.parse("abc") == nil, "custom ratios parse (2.35:1, 5x7)")
        if let c = custom, let k = (try? sync { await AssistCrop.suggest(after, ratios: [c], perRatio: 1, useAesthetics: false) })?.first {
            check(abs(Double(k.rect.width / k.rect.height) - 2.35) < 0.02, "custom 2.35:1 candidate")
        }
        AppModel.shared.close(d)
    }

    // MARK: 4. Alt text & metadata

    static func altText(_ out: URL) {
        log("— describe image / alt text")
        let sc = makeScene()
        for (label, cg) in [("eagle", animal("Eagle")), ("landscape", landscape(1400)), ("scene", Assist.compositeCG(sc.doc.state)!)] {
            let d = time("describe \(label)") { AssistDescribe.describe(cg) }
            log("  [\(label)] \(d.engine)\n" + d.report.split(separator: "\n").map { "      " + $0 }.joined(separator: "\n"))
            log("      alt: \(d.altText)")
            check(d.caption.count > 8 && !d.caption.lowercased().hasPrefix("the image"), "[\(label)] caption without boilerplate (\(d.caption.count) chars)")
            check(d.altText.count >= d.caption.count - 1 && d.altText.count <= 300, "[\(label)] alt text length \(d.altText.count)")
            check(!d.colors.isEmpty && !d.keywords.isEmpty, "[\(label)] colours (\(d.colors.map(\.name).joined(separator: ", "))) and \(d.keywords.count) keywords")
            if label == "scene" { check(d.text.contains { $0.uppercased().contains("SALE") }, "[scene] OCR text found (\(d.text.joined(separator: " | ")))") }
            if label == "eagle" {
                let all = (d.caption + " " + d.detailed + " " + d.keywords.joined(separator: " ")).lowercased()
                check(all.contains("eagle") || all.contains("bird"), "[eagle] the description mentions the bird")
                // export as JPEG with the description embedded
                let doc = self.doc(cg)
                let alt = d.altText + " \"Quoted\" & <tagged> ünïcode."
                let kw = Array(d.keywords.prefix(6))
                for (fmt, ext) in [(ExportFormat.jpeg, "jpg"), (.png, "png"), (.tiff, "tiff"), (.heic, "heic")] {
                    let url = out.appendingPathComponent("assist_alt_export.\(ext)")
                    do {
                        let html = try time("export \(ext) + metadata") { try AssistMetadata.export(doc.state, to: url, format: fmt, quality: 0.9, altText: alt, keywords: kw) }
                        let back = AssistMetadata.read(url)
                        log("    \(ext): IPTC caption \(back.iptcCaption == alt) · XMP dc:description \(back.xmpDescription == alt) · AltTextAccessibility \(back.altTextAccessibility == alt) · TIFF \(back.tiffDescription == alt) · keywords \(back.keywords)")
                        let described = back.xmpDescription == alt || back.iptcCaption == alt
                        check(described, "\(ext): description written and read back from the file")
                        if fmt == .jpeg {
                            check(back.iptcCaption == alt && back.xmpDescription == alt, "jpg: both IPTC Caption-Abstract and XMP dc:description carry the alt text")
                            check(back.altTextAccessibility == alt, "jpg: IPTC Alt Text (Accessibility) written")
                            check(back.keywords == kw, "jpg: keywords round-trip (\(back.keywords.count))")
                            check(html == "<img src=\"assist_alt_export.jpg\" alt=\"\(AssistMetadata.htmlEscape(alt))\" width=\"\(cg.width)\" height=\"\(cg.height)\">" && html.contains("&quot;") && html.contains("&lt;tagged&gt;"), "HTML snippet is escaped")
                        }
                        let re = Assist.loadCG(url)
                        check(re?.width == cg.width && re?.height == cg.height, "\(ext): image still decodes at \(cg.width)×\(cg.height)")
                        if fmt == .png, let re { check(meanDiff(PixelBuffer(cgImage: re).makeCGImage(), cg) < 0.5, "png: pixels untouched by the metadata rewrite") }
                    } catch { check(false, "\(ext) export: \(error.localizedDescription)") }
                }
            }
        }
        // Vision-only fallback
        let v = time("describe eagle without Florence") { AssistDescribe.describe(animal("Eagle"), useFlorence: false) }
        log("  Vision-only: \(v.caption) | keywords \(v.keywords.prefix(6))")
        check(v.engine == "Vision" && v.caption.count > 5 && !v.keywords.isEmpty, "fallback description without Florence-2")
    }

    // MARK: 5. OCR → editable text

    static func ocr(_ out: URL) {
        log("— text in image → editable text")
        let W = 1100, H = 700
        struct Truth { var text: String; var font: String; var size: Double; var color: RGBA; var pos: CGPoint; var angle: Double }
        let truths = [Truth(text: "FRESH COFFEE", font: "Helvetica-Bold", size: 76, color: RGBA(hex: "4A2A12")!, pos: CGPoint(x: 262, y: 186), angle: 0),
                      Truth(text: "Open daily 8 to 18", font: "Georgia", size: 44, color: RGBA(hex: "7A1E1E")!, pos: CGPoint(x: 350, y: 300), angle: 0),
                      Truth(text: "SALE", font: "Futura-Bold", size: 96, color: RGBA(hex: "FFFFFF")!, pos: CGPoint(x: 120, y: 500), angle: -8)]
        var st = DocumentState(width: W, height: H)
        let bg = draw(W, H) { c in
            // wall with soft shading and planks
            let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "3F6E8C")!.cgColor, RGBA(hex: "24445C")!.cgColor] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: W, y: H), options: [])
            c.setStrokeColor(RGBA(hex: "1D3648")!.withAlpha(0.55).cgColor); c.setLineWidth(3)
            for i in 1..<8 { c.move(to: CGPoint(x: 0, y: i * 90)); c.addLine(to: CGPoint(x: W, y: i * 90 + 14)) }
            c.strokePath()
            // sign board
            c.setFillColor(RGBA(hex: "EFE3C8")!.cgColor)
            c.addPath(CGPath(roundedRect: CGRect(x: 190, y: 130, width: 720, height: 270), cornerWidth: 26, cornerHeight: 26, transform: nil)); c.fillPath()
            c.setStrokeColor(RGBA(hex: "B89A62")!.cgColor); c.setLineWidth(8)
            c.addPath(CGPath(roundedRect: CGRect(x: 204, y: 144, width: 692, height: 242), cornerWidth: 18, cornerHeight: 18, transform: nil)); c.strokePath()
        }
        st.layers = [Layer.raster(name: "Background", buffer: bg)]
        for t in truths {
            var tc = TextContent()
            tc.text = t.text; tc.fontName = t.font; tc.fontSize = t.size; tc.color = t.color; tc.position = t.pos
            if t.angle != 0 {
                let b = TextRenderer.docBounds(tc)
                tc.transform = CGAffineTransform(translationX: -b.midX, y: -b.midY).concatenating(CGAffineTransform(rotationAngle: CGFloat(t.angle * .pi / 180))).concatenating(CGAffineTransform(translationX: b.midX, y: b.midY))
            }
            st.layers.append(Layer(name: "t", content: .text(tc)))
        }
        // flatten: the test document is a single pixel layer
        let flat = Assist.compositeCG(st)!
        save(flat, "ocr_1_original", out)
        let d = doc(flat, name: "Background")
        let lines = time("OCR (Vision, accurate)") { AssistOCR.detect(flat, docSize: CGSize(width: W, height: H)) }
        for l in lines { log(String(format: "  line “%@” conf %.2f box %@ angle %.1f°", l.text, l.confidence, "\(l.quad.bounds.integral)", l.angle * 180 / .pi)) }
        check(lines.count == truths.count, "three text lines detected (\(lines.count))")
        for t in truths { check(lines.contains { $0.text.caseInsensitiveCompare(t.text) == .orderedSame }, "recognised “\(t.text)”") }
        guard lines.count >= 1 else { return }
        // click-to-copy hit test
        if let sale = lines.first(where: { $0.text == "SALE" }) {
            check(sale.contains(sale.center) && !sale.contains(CGPoint(x: 1000, y: 650)), "clicking inside a box hits that line")
            check(abs(sale.angle * 180 / .pi - (-8)) < 1.5, String(format: "rotated line: angle %.1f° (truth −8°)", sale.angle * 180 / .pi))
        }
        if LamaInpainter.isAvailable { _ = try? time("load LaMa (one time)") { try sync { try await NeuralModels.load(NeuralModelID.lama) } } }
        guard let conv = try? time("convert \(lines.count) lines (analysis + inpaint + type layers)", { try sync { try await AssistOCR.convert(lines, in: d) } }) else { check(false, "convert"); return }
        log(String(format: "  line analysis + font match %.2f s, inpaint (%@) %.2f s, total %.2f s; background spread %@", conv.analysisSeconds, conv.engine, conv.inpaintSeconds, conv.seconds,
                   conv.styles.map { String(format: "%.1f", $0.backgroundSpread) }.joined(separator: " / ")))
        check(conv.textLayerIDs.count == lines.count && conv.patchLayerID != nil, "one type layer per line + one “Text Removed” layer")
        check(d.state.layers.count == 1 + 1 + lines.count && d.history.count == 2, "layers added above the image in one undo step")
        check(meanDiff(PixelBuffer(cgImage: Assist.compositeCG(DocumentState.only(d.state.layers[0], like: d.state))!).makeCGImage(), flat) < 0.01, "the original pixel layer is untouched")
        // type layers match the truth
        for (l, id) in zip(lines, conv.textLayerIDs) {
            guard let t = d.state.layer(id)?.text, let truth = truths.first(where: { $0.text.caseInsensitiveCompare(l.text) == .orderedSame }) else { continue }
            let dc = abs(t.color.r - truth.color.r) + abs(t.color.g - truth.color.g) + abs(t.color.b - truth.color.b)
            let ang = Double(atan2(t.transform.b, t.transform.a)) * 180 / .pi
            // compare visual size via ink bounds of the truth vs. the new layer
            var tt = TextContent(); tt.text = truth.text; tt.fontName = truth.font; tt.fontSize = truth.size; tt.position = truth.pos
            let inkT = AssistOCR.inkBounds(tt) ?? .zero
            var noT = t; noT.transform = .identity
            let inkN = AssistOCR.inkBounds(noT) ?? .zero
            log(String(format: "  “%@”: font %@ %.0f pt ×%.2f (truth %@ %.0f) colour #%@ (truth #%@) angle %.1f° ink %.0f×%.0f (truth %.0f×%.0f)",
                       t.text, t.fontName, t.fontSize, t.horizontalScale, truth.font, truth.size, t.color.hex, truth.color.hex, ang, inkN.width, inkN.height, inkT.width, inkT.height))
            if let stl = zip(lines, conv.styles).first(where: { $0.0.id == l.id })?.1 {
                log("    font ranking: " + stl.fontRanking.map { "\($0.0) \(String(format: "%.2f", $0.1))" }.joined(separator: ", "))
            }
            check(t.text.caseInsensitiveCompare(truth.text) == .orderedSame, "“\(truth.text)”: live text content")
            check(dc < 0.25, "“\(truth.text)”: colour matches (Δ \(String(format: "%.2f", dc)))")
            check(abs(inkN.height - inkT.height) <= max(3, inkT.height * 0.08) && abs(inkN.width - inkT.width) <= max(4, inkT.width * 0.05), "“\(truth.text)”: same size on screen")
            check(abs(ang - truth.angle) < 1.5, "“\(truth.text)”: angle \(String(format: "%.1f", ang))°")
            if truth.angle == 0 {
                let b = AssistOCR.inkBounds(t) ?? .zero
                check(abs(b.minX - inkT.minX) <= 4 && abs(b.minY - inkT.minY) <= 4, "“\(truth.text)”: same position (Δ \(Int(b.minX - inkT.minX)), \(Int(b.minY - inkT.minY)) px)")
            }
        }
        let converted = Assist.compositeCG(d.state)!
        save(converted, "ocr_3_converted", out)
        // text removed cleanly: hide the type layers and look again
        var removed = d.state
        for id in conv.textLayerIDs { removed.updateLayer(id) { $0.isVisible = false } }
        let clean = Assist.compositeCG(removed)!
        save(clean, "ocr_2_text_removed", out)
        let left = AssistOCR.detect(clean, docSize: CGSize(width: W, height: H))
        check(left.isEmpty, "no text is readable after the originals are painted out (\(left.map(\.text)))")
        // the repaired areas look like their surroundings (sign paper / wall), and nothing else changed
        var bgOnly = st; bgOnly.layers = [st.layers[0]]
        let truthBG = Assist.compositeCG(bgOnly)!
        for l in lines {
            let r = l.quad.bounds.insetBy(dx: -4, dy: -4)
            let e = meanDiff(clean, truthBG, in: r)
            check(e < 9, String(format: "“%@” area matches the text-free scene (mean error %.1f / 255)", l.text, e))
        }
        check(meanDiff(clean, flat, in: CGRect(x: 0, y: 0, width: W, height: 110)) < 0.3, "areas without text are unchanged")
        // the re-set type lands on the original lettering
        let e2 = meanDiff(converted, flat)
        check(e2 < 2.5, String(format: "converted document looks like the original (mean error %.2f / 255)", e2))
        // edit the text: it is live
        if let id = conv.textLayerIDs.first {
            d.updateLayer(id) { $0.text?.text = "FRESH BREAD" }
            d.commit("Edit Text")
            save(d.state, "ocr_4_edited", out)
            let again = AssistOCR.detect(Assist.compositeCG(d.state)!, docSize: CGSize(width: W, height: H))
            check(again.contains { $0.text.uppercased().contains("BREAD") } && !again.contains { $0.text.uppercased().contains("COFFEE") }, "editing the new type layer changes the sign (now reads \(again.map(\.text)))")
            d.undo()
        }
        d.undo()
        check(d.state.layers.count == 1, "undo removes the conversion")
        // lettering over a photograph: the textured background goes to the generative inpainter
        do {
            let photo = landscape(1100)
            var ps = DocumentState(width: photo.width, height: photo.height)
            var pt = TextContent()
            pt.text = "LAKE TAHOE"; pt.fontName = "AvenirNext-Heavy"; pt.fontSize = 110; pt.color = RGBA(hex: "FFD21F")!; pt.position = CGPoint(x: 190, y: Double(photo.height) * 0.55)
            ps.layers = [Layer.raster(name: "Background", buffer: PixelBuffer(cgImage: photo)), Layer(name: "t", content: .text(pt))]
            let titled = Assist.compositeCG(ps)!
            save(titled, "ocr_5_photo_original", out)
            let pd = doc(titled, name: "Background")
            let pl = AssistOCR.detect(titled, docSize: CGSize(width: titled.width, height: titled.height)).filter { $0.text.uppercased().contains("TAHOE") }
            check(pl.count == 1, "title over a photo is recognised (\(pl.map(\.text)))")
            if let pc = try? time("convert a title on a photo", { try sync { try await AssistOCR.convert(pl, in: pd) } }) {
                log(String(format: "  photo title: %@, analysis %.2f s, inpaint %.2f s; font %@", pc.engine, pc.analysisSeconds, pc.inpaintSeconds, pd.state.layer(pc.textLayerIDs.first ?? UUID())?.text?.fontName ?? "?"))
                check(pc.engine == (LamaInpainter.isAvailable ? "LaMa" : "PatchMatch"), "textured background uses the generative inpainter (\(pc.engine))")
                if let stl = pc.styles.first {
                    save(stl.fontTarget, "ocr_8_photo_glyphs", out)
                    log("    font ranking: " + stl.fontRanking.map { "\($0.0) \(String(format: "%.2f", $0.1))" }.joined(separator: ", ") + String(format: "; colour #%@, ink %.0f×%.0f", stl.color.hex, stl.ink.width, stl.ink.height))
                }
                var hidden = pd.state
                for id in pc.textLayerIDs { hidden.updateLayer(id) { $0.isVisible = false } }
                let cleaned = Assist.compositeCG(hidden)!
                save(cleaned, "ocr_6_photo_text_removed", out)
                save(pd.state, "ocr_7_photo_converted", out)
                check(AssistOCR.detect(cleaned, docSize: CGSize(width: titled.width, height: titled.height)).isEmpty, "the title is gone from the photo")
                let e = meanDiff(cleaned, photo, in: pl[0].quad.bounds)
                check(e < 22, String(format: "repaired area is plausible water / rock (mean error vs the real scene %.1f / 255)", e))
                let e3 = meanDiff(Assist.compositeCG(pd.state)!, titled)
                check(e3 < 3, String(format: "re-set title matches the original picture (mean error %.2f)", e3))
            } else { check(false, "convert on photo") }
        }
        // PatchMatch fallback on a single line
        let d2 = doc(flat, name: "Background")
        if let one = lines.first(where: { $0.text.uppercased().contains("OPEN") }) {
            let hole = AssistOCR.holeMask([one], styles: [AssistOCR.analyze(one, image: flat, matchFont: false)], width: W, height: H)
            let pm = time("PatchMatch fallback for one line") { Inpainter.inpaint(PixelBuffer(cgImage: flat), hole: hole).makeCGImage() }
            let e = meanDiff(pm, truthBG, in: one.quad.bounds)
            check(e < 9, String(format: "PatchMatch fallback also clears the line (mean error %.1f)", e))
            _ = d2
        }
    }

    // MARK: 6. Quality

    static func quality(_ out: URL) {
        log("— analyze / fixes / auto enhance")
        let clean = landscape(1600)
        func rep(_ label: String, _ cg: CGImage, use: AssistQuality.Use = .screen) -> AssistQuality.Report {
            let r = AssistQuality.analyze(cg, use: use)
            let m = r.metrics
            log(String(format: "  %@: blur %@ noise %.1f median %.0f range %.0f–%.0f clip %.1f/%.1f%% cast %.1f/%.1f (T %.0f, tint %.0f) blocks %.2f tilt %@ faces %d → %@ (%.2f s)",
                       label.padding(toLength: 12, withPad: " ", startingAt: 0), m.blur.map { String(format: "%.2f", $0) } ?? "—", m.noise, m.median, m.p1, m.p99, m.clipHigh * 100, m.clipLow * 100, m.cast, m.highlightChroma, m.wbTemperature, m.wbTint,
                       m.blockiness, m.tiltDegrees.map { String(format: "%.1f°", $0) } ?? "—", m.faces, r.issues.isEmpty ? "no issues" : r.issues.map { $0.title }.joined(separator: ", "), r.seconds))
            return r
        }
        let r0 = time("analyze 1600×900") { rep("clean", clean) }
        for k in [AssistQuality.Kind.blur, .noise, .colorCast, .jpegBlocks, .underexposed, .overexposed, .tilted, .lowResolution] {
            check(!r0.has(k), "clean picture: no false “\(k.rawValue)”")
        }
        let soft = blurred(clean, 4)
        let rBlur = rep("blur σ4", soft)
        check(rBlur.has(.blur) && (rBlur.metrics.blur ?? 0) > (r0.metrics.blur ?? 1) + 0.15, "seeded blur detected")
        check(rep("blur σ1.5", blurred(clean, 1.5)).metrics.blur ?? 0 > r0.metrics.blur ?? 1, "blur score grows with blur")
        let grainy = noisy(clean, sigma: 12)
        let rNoise = rep("noise σ12", grainy)
        check(rNoise.has(.noise) && abs(rNoise.metrics.noise - 12) < 5, String(format: "seeded noise detected (σ estimated %.1f, seeded 12)", rNoise.metrics.noise))
        check(!rNoise.has(.blur), "noise is not mistaken for blur")
        let warm = cast(clean, r: 1.12, g: 1.0, b: 0.82)
        let rCast = rep("warm cast", warm)
        check(rCast.has(.colorCast) && rCast.metrics.wbTemperature < -8, "seeded warm cast detected, fix cools the picture")
        let green = cast(clean, r: 0.88, g: 1.05, b: 0.9)
        let rGreen = rep("green cast", green)
        check(rGreen.has(.colorCast) && rGreen.metrics.wbTint > 5, "seeded green cast detected, fix adds magenta")
        let tilt = rotated(clean, degrees: -5)
        let rTilt = rep("tilt 5°", tilt)
        check(rTilt.has(.tilted) && abs(abs(rTilt.metrics.tiltDegrees ?? 0) - 5) < 1.2, "seeded 5° tilt detected")
        let dark = edit(clean) { px, i in for c in 0..<3 { px[i + c] = UInt8(Double(px[i + c]) * 0.3) } }
        check(rep("dark ×0.3", dark).has(.underexposed), "underexposure detected")
        let flat = edit(clean) { px, i in for c in 0..<3 { px[i + c] = UInt8(90 + Double(px[i + c]) * 0.3) } }
        check(rep("flat", flat).has(.lowContrast), "low contrast detected")
        let blown = edit(clean) { px, i in for c in 0..<3 { px[i + c] = UInt8(min(255, Double(px[i + c]) * 1.9 + 30)) } }
        check(rep("blown", blown).has(.clippedHighlights), "clipped highlights detected")
        let blocky = jpegRoundTrip(clean, quality: 0.04)
        check(rep("jpeg q4", blocky).has(.jpegBlocks), "JPEG blockiness detected")
        check(!rep("jpeg q85", jpegRoundTrip(clean, quality: 0.85)).has(.jpegBlocks), "good JPEG is not flagged")
        let small = NImg.fitted(clean, maxSide: 640)
        check(rep("640 px/A4", small, use: .printA4).has(.lowResolution) && !rep("1600/screen", clean, use: .screen).has(.lowResolution), "low resolution for the intended use")
        // faces cut at the edge (synthetic check of the rule through the public struct)
        let f = AssistVision.Face(box: CGRect(x: -4, y: 100, width: 120, height: 150), roll: nil, leftEye: 0.08, rightEye: 0.1, captureQuality: nil)
        check(f.eyesClosed && !AssistVision.Face(box: .zero, roll: nil, leftEye: 0.3, rightEye: 0.28, captureQuality: nil).eyesClosed, "closed-eyes rule (eye openness < 0.17)")

        // fixes: each is non-destructive and a single undo step
        func fixIssue(_ cg: CGImage, _ kind: AssistQuality.Kind, _ label: String, _ verify: (AssistQuality.Report, AssistQuality.Report, Document) -> Bool) {
            let d = doc(cg)
            AppModel.shared.add(d)
            let before = AssistQuality.analyze(cg)
            guard let issue = before.issues.first(where: { $0.kind == kind }), let fix = issue.fix else { check(false, "\(label): issue with a fix"); AppModel.shared.close(d); return }
            let original = d.state.layers[0].raster?.buffer
            let steps = d.history.count
            var name: String?
            if fix == .denoise {
                name = try? time("fix: \(fix.title)") { try sync { await AssistQuality.applyDenoise(to: d, metrics: before.metrics) } }
            } else {
                name = time("fix: \(fix.title)") { AssistQuality.apply(fix, to: d, metrics: before.metrics) }
            }
            let afterCG = Assist.compositeCG(d.state)!
            let after = AssistQuality.analyze(afterCG)
            save(afterCG, "quality_fix_\(label)", out)
            let undoSteps = d.history.count - steps
            check(name != nil && verify(before, after, d), "\(label): “\(fix.title)” → \(name ?? "nil")")
            // non-destructive: original pixels still exist unchanged (as the layer or inside the smart object)
            var kept = false
            for l in d.state.allLayers {
                if let r = l.raster, r.buffer === original { kept = true }
                if case .smartObject(let so) = l.content, case .document(let inner) = so.source, inner.layers.first?.raster?.buffer === original { kept = true }
            }
            if kind == .tilted {
                // rotation resamples, but nothing is thrown away: the layer still extends beyond the cropped canvas
                let b = d.state.layers[0].raster?.buffer
                check((b?.width ?? 0) > d.state.width && (b?.height ?? 0) > d.state.height, "\(label): pixels outside the crop are kept (layer \(b?.width ?? 0)×\(b?.height ?? 0), canvas \(d.state.width)×\(d.state.height))")
            } else {
                check(kept, "\(label): original pixels are kept")
            }
            check(undoSteps == 1, "\(label): \(undoSteps) undo step(s)")   // Straighten coalesces rotate + crop into one step
            while d.canUndo { d.undo() }
            check(d.state.layers.count == 1 && d.state.layers[0].isRaster && d.state.width == cg.width, "\(label): undo restores the document")
            AppModel.shared.close(d)
        }
        save(warm, "quality_seed_cast", out)
        fixIssue(warm, .colorCast, "cast") { b, a, d in
            log(String(format: "    highlight chroma %.1f → %.1f", b.metrics.highlightChroma, a.metrics.highlightChroma))
            return a.metrics.highlightChroma < b.metrics.highlightChroma * 0.4 && !a.has(.colorCast) && d.state.layers.last?.adjustment?.kind == .colorWB
        }
        fixIssue(flat, .lowContrast, "levels") { b, a, d in
            log(String(format: "    range %.0f–%.0f → %.0f–%.0f", b.metrics.p1, b.metrics.p99, a.metrics.p1, a.metrics.p99))
            return (a.metrics.p99 - a.metrics.p1) > (b.metrics.p99 - b.metrics.p1) * 1.8 && d.state.layers.last?.adjustment?.kind == .levels
        }
        fixIssue(dark, .underexposed, "brighten") { b, a, d in
            log(String(format: "    median %.0f → %.0f", b.metrics.median, a.metrics.median))
            return a.metrics.median > b.metrics.median * 2 && !a.has(.underexposed) && d.state.layers.last?.adjustment?.kind == .levels
        }
        fixIssue(blown, .clippedHighlights, "highlights") { b, a, d in
            log(String(format: "    clipped %.1f%% → %.1f%%", b.metrics.clipHigh * 100, a.metrics.clipHigh * 100))
            return a.metrics.clipHigh < b.metrics.clipHigh && d.state.layers.last?.adjustment?.kind == .light
        }
        save(soft, "quality_seed_blur", out)
        fixIssue(soft, .blur, "sharpen") { b, a, d in
            log(String(format: "    blur %.2f → %.2f", b.metrics.blur ?? 0, a.metrics.blur ?? 0))
            return (a.metrics.blur ?? 1) < (b.metrics.blur ?? 0) - 0.03 && d.state.layers[0].smart?.filters.first?.kind == .unsharpMask
        }
        save(grainy, "quality_seed_noise", out)
        fixIssue(grainy, .noise, "denoise") { b, a, d in
            log(String(format: "    noise σ %.1f → %.1f", b.metrics.noise, a.metrics.noise))
            return a.metrics.noise < b.metrics.noise * 0.6 && d.state.layers[0].smart?.filters.count == 1
        }
        save(tilt, "quality_seed_tilt", out)
        fixIssue(tilt, .tilted, "straighten") { b, a, _ in
            log(String(format: "    tilt %.1f° → %.1f°", b.metrics.tiltDegrees ?? 0, a.metrics.tiltDegrees ?? 0))
            return abs(a.metrics.tiltDegrees ?? 0) < 0.8
        }

        // Auto Enhance: dull, slightly warm, dark picture
        let dull = cast(edit(clean) { px, i in for c in 0..<3 { px[i + c] = UInt8(30 + Double(px[i + c]) * 0.55) } }, r: 1.1, g: 1.0, b: 0.85)
        save(dull, "quality_enhance_before", out)
        let d = doc(dull)
        let rb = AssistQuality.analyze(dull)
        let notes = time("auto enhance (apply)") { AssistQuality.autoEnhance(d, report: rb) }
        log("  auto enhance: " + notes.joined(separator: "; "))
        let enhanced = Assist.compositeCG(d.state)!
        save(enhanced, "quality_enhance_after", out)
        let ra = rep("enhanced", enhanced)
        let g = d.state.layers.last
        check(g?.isGroup == true && g?.children.count == 3 && g!.children.allSatisfy { $0.isAdjustment && $0.mask != nil }, "Auto Enhance adds a group of three adjustment layers")
        check((ra.metrics.p99 - ra.metrics.p1) > (rb.metrics.p99 - rb.metrics.p1) * 1.3 && ra.metrics.highlightChroma < rb.metrics.highlightChroma * 0.6 && ra.metrics.saturation > rb.metrics.saturation,
              String(format: "enhanced: range %.0f → %.0f, highlight chroma %.1f → %.1f, saturation %.2f → %.2f", rb.metrics.p99 - rb.metrics.p1, ra.metrics.p99 - ra.metrics.p1, rb.metrics.highlightChroma, ra.metrics.highlightChroma, rb.metrics.saturation, ra.metrics.saturation))
        check(ra.metrics.clipHigh < 0.03 && ra.metrics.clipLow < 0.06, "enhanced picture is not clipped")
        d.undo()
        check(d.state.layers.count == 1, "Auto Enhance is one undo step")
        // a good picture is left almost alone
        let dg = doc(clean)
        AssistQuality.autoEnhance(dg, report: r0)
        let e = meanDiff(Assist.compositeCG(dg.state)!, clean)
        check(e < 18 && !AssistQuality.analyze(Assist.compositeCG(dg.state)!).has(.clippedHighlights), String(format: "Auto Enhance is gentle on a good picture (mean change %.1f / 255, no clipping)", e))
        save(dg.state, "quality_enhance_clean", out)
    }

    // MARK: 7. Subject helpers

    static func countVideoFrames(_ url: URL) -> (frames: Int, seconds: Double, size: CGSize) {
        let asset = AVURLAsset(url: url)
        var result = (0, 0.0, CGSize.zero)
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            defer { sem.signal() }
            guard let track = try? await asset.loadTracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else { return }
            let size = (try? await track.load(.naturalSize)) ?? .zero
            let dur = (try? await asset.load(.duration))?.seconds ?? 0
            let outp = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(outp)
            reader.startReading()
            var n = 0
            while let s = outp.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(s) > 0 { n += 1 } }
            result = (n, dur, size)
        }
        while sem.wait(timeout: .now() + 0.01) == .timedOut { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        return result
    }

    static func subject(_ out: URL) {
        log("— subject helpers")
        let eagle = animal("Eagle")
        let W = eagle.width, H = eagle.height

        // Text Behind Subject
        do {
            let d = doc(eagle, name: "Eagle")
            var t = TextContent()
            t.text = "EAGLE"; t.fontName = "Helvetica-Bold"; t.fontSize = Double(W) * 0.34; t.color = RGBA(hex: "FFD21F")!
            t.position = CGPoint(x: Double(W) * 0.02, y: Double(H) * 0.30)
            let text = Layer(name: "Text", content: .text(t))
            d.addLayer(text, commitName: "Type")
            let before = Assist.compositeCG(d.state)!
            save(before, "subject_text_before", out)
            let r = try time("text behind subject (\(W) px)") { try sync { try await AssistSubject.textBehindSubject(d, textID: text.id) } }
            let after = Assist.compositeCG(d.state)!
            save(after, "subject_text_behind", out)
            let top = d.state.layers.last!
            check(d.state.layers.count == 3 && top.id == r.subjectLayerID && top.mask != nil && d.state.layers[1].id == text.id, "masked subject copy sits directly above the text")
            check(r.duplicatedLayer && top.isRaster, "the single picture layer was duplicated (not flattened)")
            check(d.state.layer(text.id)?.text?.text == "EAGLE" && d.history.count == 3, "text stays live; one undo step")
            log(String(format: "  subject covers %.0f%% of the text box", r.overlap * 100))
            // inside the subject the photo shows, outside the text shows
            let mask = top.mask!.buffer
            let textInk = RenderEngine.renderBuffer(TextRenderer.render(t, space: CanvasSpace(width: W, height: H)), docRect: IRect(x: 0, y: 0, width: W, height: H), space: CanvasSpace(width: W, height: H))
            let mp = mask.data.assumingMemoryBound(to: UInt8.self)
            func m(_ x: Int, _ y: Int) -> UInt8 { mp[y * mask.bytesPerRow + x] }
            let inSubject = meanDiff(after, eagle, mask: { x, y in textInk.alpha(x, y) > 200 && m(x, y) > 250 })
            let outSubject = meanDiff(after, before, mask: { x, y in textInk.alpha(x, y) > 200 && m(x, y) < 5 })
            let hiddenBefore = meanDiff(before, eagle, mask: { x, y in textInk.alpha(x, y) > 200 && m(x, y) > 250 })
            check(r.overlap > 0.15 && inSubject < 1.5 && hiddenBefore > 40, String(format: "subject hides the text where they overlap (error vs photo %.1f, was %.1f)", inSubject, hiddenBefore))
            check(outSubject < 1.5, String(format: "text is unchanged beside the subject (%.1f)", outSubject))
            // still editable: move the text, the occlusion follows
            d.updateLayer(text.id) { $0.translate(dx: 0, dy: Double(H) * 0.25) }
            d.commit("Move")
            save(d.state, "subject_text_behind_moved", out)
            d.undo(); d.undo()
            check(d.state.layers.count == 2, "undo removes the subject copy")
        } catch { check(false, "text behind subject: \(error.localizedDescription)") }

        // Pop Subject
        do {
            let d = doc(animal("Parrot"), name: "Parrot")
            let before = Assist.compositeCG(d.state)!
            let gid = try time("pop subject (512 px)") { try sync { try await AssistSubject.popSubject(d) } }
            let after = Assist.compositeCG(d.state)!
            save(before, "subject_pop_before", out)
            save(after, "subject_pop_after", out)
            let g = d.state.layer(gid)!
            check(g.isGroup && g.children.count == 3 && g.children[0].isSmartObject && g.children[0].smart?.filters.first?.kind == .gaussianBlur
                  && g.children[1].adjustment?.kind == .hueSaturation && g.children[2].adjustment?.kind == .brightnessContrast && g.children.allSatisfy { $0.mask != nil },
                  "Pop Subject group: blur smart filter + desaturate + darken, each masked")
            let bgMask = g.children[1].mask!.buffer
            let bp = bgMask.data.assumingMemoryBound(to: UInt8.self)
            func isBG(_ x: Int, _ y: Int) -> Bool { bp[y * bgMask.bytesPerRow + x] > 250 }
            func isSubj(_ x: Int, _ y: Int) -> Bool { bp[y * bgMask.bytesPerRow + x] < 5 }
            func stats(_ cg: CGImage, _ sel: (Int, Int) -> Bool) -> (lum: Double, sat: Double) {
                let px = Assist.rgba(cg, cg.width, cg.height)
                var l = 0.0, s = 0.0, n = 0.0
                for y in 0..<cg.height { for x in 0..<cg.width where sel(x, y) {
                    let i = (y * cg.width + x) * 4
                    let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
                    l += 0.299 * r + 0.587 * g + 0.114 * b
                    s += max(r, g, b) - min(r, g, b); n += 1
                } }
                return n > 0 ? (l / n, s / n) : (0, 0)
            }
            let b0 = stats(before, isBG), b1 = stats(after, isBG)
            let subjDiff = meanDiff(after, before, mask: isSubj)
            log(String(format: "  background: luminance %.0f → %.0f, chroma %.0f → %.0f; subject change %.2f", b0.lum, b1.lum, b0.sat, b1.sat, subjDiff))
            check(b1.lum < b0.lum * 0.9 && b1.sat < b0.sat * 0.7, "background is darker and less saturated")
            check(subjDiff < 1.0, "the subject is untouched")
            // no halo: background next to the subject must not pick up the parrot's red
            let ring = SelectionOps.combine(SelectionOps.expand(SelectionOps.invert(bgMask), by: 10), bgMask, mode: .intersect)
            let rp = ring.data.assumingMemoryBound(to: UInt8.self)
            let ringBefore = stats(before, { x, y in rp[y * ring.bytesPerRow + x] > 250 }), ringAfter = stats(after, { x, y in rp[y * ring.bytesPerRow + x] > 250 })
            check(ringAfter.sat <= ringBefore.sat, String(format: "no colour halo around the subject (edge chroma %.0f → %.0f)", ringBefore.sat, ringAfter.sat))
            d.updateLayer(g.children[1].id) { $0.isVisible = false }
            check(stats(Assist.compositeCG(d.state)!, isBG).sat > b1.sat * 1.2, "each effect can be switched off on its own")
            d.undo()
            check(d.state.layers.count == 1, "Pop Subject is one undo step")
        } catch { check(false, "pop subject: \(error.localizedDescription)") }

        // Depth parallax
        do {
            let scene = landscape(1000)
            let d = doc(scene, name: "Lake")
            var o = AssistSubject.ParallaxOptions()
            o.layers = 3; o.seconds = 2; o.fps = 24
            let r = try time("depth parallax: 3 layers (\(scene.width)×\(scene.height))") { try sync { try await AssistSubject.parallax(d, options: o, animate: true) } }
            log("  engine: \(r.engine); build \(String(format: "%.2f s", r.seconds)); \(r.frames) frames")
            let g = d.state.layer(r.groupID)!
            check(g.children.count == 3 && r.layerIDs == g.children.map(\.id), "three depth layers in a group (far → near)")
            let far = g.children[0].raster!
            check(far.buffer.width == scene.width && far.buffer.height == scene.height && far.buffer.opaqueBounds(threshold: 254) == far.buffer.bounds, "the far layer is complete (nothing missing behind nearer layers)")
            let still = Assist.compositeCG(DocumentState.only(g, like: d.state))!
            let e = meanDiff(still, scene)
            check(e < 1.5, String(format: "stacked layers reproduce the picture (mean error %.2f / 255)", e))
            for (i, l) in g.children.enumerated() { save(Assist.compositeCG(DocumentState.only(l, like: d.state), background: RGBA(hex: "FF00FF")), "parallax_layer\(i + 1)", out) }
            // what the far layer invented behind the foreground must look like background, not like the foreground
            let nearMask = g.children[g.children.count - 1].raster!   // (without the depth model the fallback may make fewer layers)
            let farCG = Assist.compositeCG(DocumentState.only(g.children[0], like: d.state))!
            let nb = nearMask.buffer, no = nearMask.origin
            let hidden = meanDiff(farCG, scene, mask: { x, y in nb.alpha(x - no.x, y - no.y) > 250 })
            check(hidden > 4, String(format: "far layer was painted in behind the foreground (differs from the original there by %.1f)", hidden))
            check(d.state.frames.count == 48 && r.frames == 48, "2 s at 24 fps → 48 animation frames")
            let f12 = Animation.applied(d.state.frames[12], to: d.state)
            let shifts = r.layerIDs.map { id in (Animation.anchor(f12.layer(id)!)!.x - Animation.anchor(d.state.layer(id)!)!.x) }
            log("  frame 12 horizontal shifts far → near: \(shifts.map { Int($0) })")
            check(shifts.count >= 2 && shifts[0] == 0 && zip(shifts.dropFirst(), shifts.dropFirst(2)).allSatisfy { abs($1) > abs($0) } && abs(shifts[1]) > 0, "near layers travel further than far ones")
            let mid = Assist.compositeCG(f12)!
            save(mid, "parallax_frame12", out)
            let px = Assist.rgba(mid, mid.width, mid.height)
            check(stride(from: 3, to: px.count, by: 4).allSatisfy { px[$0] == 255 }, "no holes open up when the layers move")
            check(meanDiff(mid, scene) > 0.5, "the frame really moved")
            // video + GIF through the app's exporters
            let mp4 = out.appendingPathComponent("assist_parallax.mp4")
            let n = try time("export parallax MP4 (48 frames)") { try AssistSubject.exportParallax(d.state, ids: r.layerIDs, to: mp4, options: o) }
            let v = countVideoFrames(mp4)
            log(String(format: "  mp4: %d frames, %.2f s, %.0f×%.0f, %d KB", v.frames, v.seconds, v.size.width, v.size.height, ((try? FileManager.default.attributesOfItem(atPath: mp4.path)[.size] as? Int) ?? 0) / 1024))
            check(n == 48 && v.frames == 48 && abs(v.seconds - 2) < 0.1, "MP4 has 48 frames over 2 s")
            var og = o; og.seconds = 1; og.fps = 12
            let small = doc(NImg.fitted(scene, maxSide: 400), name: "Lake")
            let rs = try time("depth parallax + GIF (400 px, 12 frames)") { () -> Int in
                let pr = try sync { try await AssistSubject.parallax(small, options: og, animate: false) }
                return try AssistSubject.exportParallax(small.state, ids: pr.layerIDs, to: out.appendingPathComponent("assist_parallax.gif"), options: og)
            }
            let gifFrames = CGImageSourceCreateWithURL(out.appendingPathComponent("assist_parallax.gif") as CFURL, nil).map { CGImageSourceGetCount($0) } ?? 0
            check(rs == 12 && gifFrames == 12 && small.state.frames.isEmpty, "GIF has 12 frames; exporting does not add frames to the document")
            check(AssistSubject.existingParallax(d.state) == r.layerIDs, "existing parallax layers are found again for export")
            d.undo()
            check(d.state.layers.count == 1 && d.state.frames.isEmpty, "parallax layers + animation are one undo step")
        } catch { check(false, "parallax: \(error.localizedDescription)") }

        // Batch background removal
        do {
            var st = DocumentState(width: 1100, height: 560)
            let names = ["Eagle", "Owl", "Zebra"]
            for (i, n) in names.enumerated() {
                st.layers.append(Layer.raster(name: "Layer \(i + 1)", buffer: PixelBuffer(cgImage: NImg.resized(animal(n), 340, 340)), origin: IPoint(x: 20 + i * 360, y: 110)))
            }
            st.layers.append(Layer(name: "Shape", content: .shape(ShapeContent(geometry: .ellipse(CGRect(x: 10, y: 10, width: 60, height: 60)), fill: .color(.white)))))
            let d = Document(state: st, name: "assist-test-batch")
            d.selectedLayerIDs = Set(st.layers.map(\.id))
            save(d.state, "subject_batch_before", out)
            let ids = d.orderedSelection.filter { d.state.layer($0)?.isRaster == true }
            let done = try time("remove backgrounds of 3 layers") { try sync { await AssistSubject.removeBackgrounds(d, ids: ids) } }
            save(Assist.compositeCG(d.state, background: RGBA(hex: "2E7D5B")), "subject_batch_after", out)
            check(done.count == 3 && d.history.count == 2, "three layers masked in one undo step")
            for id in done {
                guard let l = d.state.layer(id), let m = l.mask, let r = l.raster else { continue }
                let cover = SegMask.area(m.buffer) / Double(r.buffer.width * r.buffer.height)
                let inside = m.buffer.opaqueBounds(threshold: 127).map { r.frame.insetBy(-2).intersection($0) == $0 } ?? false
                check(cover > 0.15 && cover < 0.95 && inside, String(format: "%@: mask covers %.0f%% of the layer, inside its frame", l.name, cover * 100))
                check(r.buffer.opaqueBounds() == r.buffer.bounds, "\(l.name): pixels untouched (mask only)")
            }
            check(d.state.layers.last?.mask == nil, "non-image layers are skipped")
            d.undo()
            check(d.state.layers.allSatisfy { $0.mask == nil }, "undo removes all masks")
        } catch { check(false, "batch background removal: \(error.localizedDescription)") }
    }
}

extension AssistSelfTest {
    /// Offscreen windows stay alive until the process exits: the app quits when its last window closes
    /// (`applicationShouldTerminateAfterLastWindowClosed`), which would silently cut the rest of a test run short.
    nonisolated(unsafe) static var snapshotWindows: [NSWindow] = []

    /// Renders a view into a PNG through an offscreen window far outside every display (not a screen capture).
    static func snapshot<V: View>(_ view: V, size: CGSize, to url: URL) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).font(Theme.font).foregroundStyle(Theme.text)
            .frame(width: size.width, height: size.height).background(Theme.panelBG))
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        win.orderFrontRegardless()
        snapshotWindows.append(win)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Offscreen renders of the dialogs and the panel (no screen capture) for visual checks.
    static func ui(_ out: URL) {
        log("— UI snapshots")
        func shot<V: View>(_ v: V, _ name: String, _ size: CGSize) {
            snapshot(v.padding(.top, 14), size: size, to: out.appendingPathComponent("assist_ui_\(name).png"))
            print("wrote assist_ui_\(name)")
        }
        let sc = makeScene()
        let d = sc.doc
        AppModel.shared.add(d)
        // all analysis first: once offscreen windows exist, the run loop must not be pumped for long
        // (AppKit would see "last window closed" and quit the app)
        _ = try? sync { await AssistIndex.shared.ensure(d.state, useFlorence: false) }
        let cm = AssistCropModel()
        let cg = Assist.compositeCG(doc(landscape(1200)).state)!
        _ = try? sync { await cm.compute(rotated(cg, degrees: 3)) }
        let qm = AssistQualityModel()
        qm.report = AssistQuality.analyze(noisy(cast(rotated(landscape(900), degrees: 4), r: 1.12, g: 1, b: 0.82), sigma: 9), use: .printA4)
        qm.use = .printA4
        let dm = AssistDescribeModel()
        dm.set(AssistDescribe.describe(Assist.compositeCG(d.state)!))
        let lines = AssistOCR.detect(Assist.compositeCG(d.state)!, docSize: CGSize(width: d.state.width, height: d.state.height))

        // Find Layers panel with results
        let sm = AssistSearchModel.shared
        sm.query = "blue shape with drop shadow"
        sm.hits = AssistSearch.search(sm.query, in: d.state)
        shot(AssistFindLayersPanel(), "find_layers", CGSize(width: 300, height: 330))
        sm.query = ""; sm.hits = []
        shot(AssistFindLayersPanel(), "find_layers_empty", CGSize(width: 300, height: 250))
        // Rename Layers with the {auto} token
        d.selectedLayerIDs = Set([sc.ids["rect"]!, sc.ids["text"]!, sc.ids["levels"]!, sc.ids["circle"]!])
        shot(BatchRenameDialog(), "rename_auto", CGSize(width: 492, height: 420))
        shot(AssistCropDialog(model: cm), "crop", CGSize(width: 592, height: 560))
        shot(AssistAnalyzeDialog(model: qm), "analyze", CGSize(width: 472, height: 560))
        shot(AssistDescribeDialog(model: dm), "describe", CGSize(width: 492, height: 430))
        shot(AssistAltExportDialog(model: dm), "alt_export", CGSize(width: 492, height: 400))
        // Text in Image
        let om = AssistOCRModel.shared
        om.lines = lines
        om.selected = Set(om.lines.prefix(1).map(\.id)); om.active = true; om.docID = d.id
        om.message = "\(om.lines.count) lines — click a box on the canvas to copy its text."
        shot(AssistOCRDialog(), "ocr", CGSize(width: 372, height: 330))
        om.stop()
        shot(AssistParallaxDialog(), "parallax", CGSize(width: 432, height: 300))
        check(FileManager.default.fileExists(atPath: out.appendingPathComponent("assist_ui_crop.png").path), "UI snapshots written")
        check(MenuRegistry.items(for: "Image").contains { $0.title == "Suggest Crops…" } && MenuRegistry.items(for: "Layer").contains { $0.title == "Name Layers Automatically" }
              && MenuRegistry.items(for: "Select").contains { $0.title == "Text in Image…" } && MenuRegistry.items(for: "File").contains { $0.title == "Export with Alt Text…" && $0.submenu == "Export" }
              && PanelRegistry.def(AssistModule.findLayersPanelID) != nil && DialogRegistry.builders["assistAnalyze"] != nil, "menus, dialogs and the Find Layers panel are registered")
        AppModel.shared.close(d)
    }
}

extension DocumentState {
    /// A copy of `like` that contains only `layer` (for rendering one layer / group by itself).
    static func only(_ layer: Layer, like: DocumentState) -> DocumentState {
        var s = DocumentState(width: like.width, height: like.height, resolution: like.resolution)
        var l = layer
        l.isVisible = true
        s.layers = [l]
        return s
    }
}
