import AppKit
import CoreImage
import Metal
import UniformTypeIdentifiers
import ImageCratCore

/// End-to-end File ▸ Open of Photoshop files, as the user sees it: `AppActions.open` (load, add, status line) → a real
/// `CanvasView` in an offscreen window at fit zoom → frames rendered the way `CanvasRenderer.draw` renders them, at
/// several zooms, before and after the large-document cache settles. Each frame is compared with the same view of the
/// document's 100 % composite (and, at fit zoom, with that composite scaled by Core Graphics). Real PSDs from installed
/// app bundles when present, plus synthetic large / 16- / 32-bit / CMYK / Lab / grayscale / many-layer / PSB files.
/// `LUMEN_SELFTEST_ONLY=psdopen Lumen --selftest <dir>`; `LUMEN_PSDOPEN_FILES=<a.psd:b.psb:folder>` adds files,
/// `LUMEN_PSDOPEN_ONLY=<substring>` picks files, `LUMEN_PSDOPEN_SAVE=1` writes every frame, `LUMEN_PSDOPEN_VERBOSE=1`.
enum PSDOpenModule {
    static func register() {
        FeatureModules.selfTests.append(("psdopen", { out in PSDOpenSelfTest.run(out) }))
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count,
           let only = ProcessInfo.processInfo.environment["LUMEN_SELFTEST_ONLY"], only.hasPrefix("psdopen") {
            _ = NSApplication.shared
            let out = URL(fileURLWithPath: args[i + 1])
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            setlinebuf(stdout)
            PSDOpenSelfTest.run(out)
            print("done (psdopen only)")
            exit(PSDOpenSelfTest.failures == 0 ? 0 : 1)
        }
    }
}

enum PSDOpenSelfTest {
    static var passes = 0, failures = 0

    static func check(_ c: Bool, _ msg: @autoclosure () -> String) {
        if c { passes += 1; print("PASS psdopen: \(msg())") } else { failures += 1; print("FAIL psdopen: \(msg())") }
    }

    static func run(_ out: URL) {
        passes = 0; failures = 0; openTimes = []; frameTimes = []
        let dir = out.appendingPathComponent("psdopen")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prefs = AppModel.shared.prefs
        defer { AppModel.shared.prefs = prefs; CanvasRenderer.forget(nil) }
        AppModel.shared.prefs.cacheLargeDocuments = true
        AppModel.shared.prefs.largeDocumentThreshold = 4
        entryPoints()
        systemPreview(dir)
        var files: [(String, URL)] = []
        for (tag, path) in PSDImportSelfTest.realFiles where FileManager.default.fileExists(atPath: path) { files.append((tag, URL(fileURLWithPath: path))) }
        for f in extraFiles() { files.append((f.deletingPathExtension().lastPathComponent, f)) }
        files += synthetic(dir)
        let only = ProcessInfo.processInfo.environment["LUMEN_PSDOPEN_ONLY"]
        for (tag, url) in files where only.map({ tag.contains($0) }) ?? true { openAndShow(tag, url, dir) }
        if let o = openTimes.max(by: { $0.1 < $1.1 }), let f = frameTimes.max(by: { $0.1 < $1.1 }) {
            print(String(format: "INFO psdopen: slowest open %@ %.0f ms; slowest frame %@ %.0f ms", o.0, o.1, f.0, f.1))
        }
        print("psdopen: \(passes) passed, \(failures) failed")
    }

    static func extraFiles() -> [URL] {
        let paths = (ProcessInfo.processInfo.environment["LUMEN_PSDOPEN_FILES"] ?? "").split(separator: ":").map(String.init)
        var out: [URL] = []
        for p in paths.sorted() {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []
                for n in items.sorted() where ["psd", "psb"].contains((n as NSString).pathExtension.lowercased()) { out.append(URL(fileURLWithPath: p).appendingPathComponent(n)) }
            } else { out.append(URL(fileURLWithPath: p)) }
        }
        return out
    }

    // MARK: Entry points

    static func entryPoints() {
        let types = AppActions.openTypes + DocumentIO.extraOpenTypes
        for ext in ["psd", "psb"] {
            let t = UTType(filenameExtension: ext)
            check(t.map { tt in types.contains { tt.conforms(to: $0) } } == true, "File ▸ Open offers .\(ext) files (\(t?.identifier ?? "no type"))")
        }
    }

    /// What Finder, Quick Look, Preview and the Open panel show of a PSD Lumen wrote: the system decoder's reading of
    /// the stored composite must be the document.
    static func systemPreview(_ dir: URL) {
        for (bits, depth) in [("8-bit", BitDepth.eight), ("16-bit", BitDepth.sixteen)] {
            var st = SelfTest.baseState(320, 200)
            st.bitDepth = depth
            st.layers.append(SelfTest.shapeLayer(CGRect(x: 40, y: 30, width: 200, height: 120), RGBA(hex: "2E86DE")!, radius: 20))
            let u = dir.appendingPathComponent("preview-\(bits).psd")
            guard (try? PSDWriter.write(st, to: u)) != nil, let mine = PSDImportSelfTest.flatten(st) else { check(false, "preview: \(bits) PSD written"); continue }
            guard let (sys, _) = PSDImportSelfTest.systemOracle(u) else { check(false, "preview: the system decoder reads Lumen's \(bits) PSD"); continue }
            let e = compare(sys, bounds(sys), mine, bounds(mine))
            check(e.mean < 2, String(format: "the system decoder (Finder, Quick Look, Open panel) shows Lumen's %@ PSD as the document (mean %.2f)", bits, e.mean))
        }
    }

    // MARK: Open and display

    /// A frame as `CanvasRenderer.draw` puts it on screen (RGBA, row 0 at the top), the canvas rectangle in it, and the
    /// time it took on the calling (main) thread.
    struct Frame { var buffer: PixelBuffer; var canvas: IRect; var ms: Double }

    /// `CanvasRenderer.frame` over the pasteboard, rendered by a GPU task into a BGRA texture like the drawable.
    static func drawn(_ d: Document, _ c: CanvasView, scale s: CGFloat = 2) -> Frame {
        let size = CGSize(width: c.bounds.width * s, height: c.bounds.height * s)
        let w = Int(size.width), h = Int(size.height), full = CGRect(origin: .zero, size: size)
        let t0 = Date()
        let frame = CanvasRenderer.frame(d, docToView: c.docToViewTransform, viewHeight: c.bounds.height, scale: s, size: size)
        let img = frame.composited(over: CIImage(color: CIColor(red: 0.157, green: 0.157, blue: 0.157)).cropped(to: full))
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.shaderRead, .shaderWrite, .renderTarget]
        td.storageMode = .shared
        let b = PixelBuffer(width: w, height: h)
        guard let tex = RenderEngine.device.makeTexture(descriptor: td), let cb = RenderEngine.commandQueue.makeCommandBuffer() else { return Frame(buffer: b, canvas: .zero, ms: 0) }
        let dest = CIRenderDestination(width: w, height: h, pixelFormat: .bgra8Unorm, commandBuffer: cb) { tex }
        dest.colorSpace = sRGBSpace
        let task = try? RenderEngine.context.startTask(toRender: img, from: full, to: dest, at: .zero)
        cb.commit()
        _ = try? task?.waitUntilCompleted()
        cb.waitUntilCompleted()
        let elapsed = ms(t0)
        tex.getBytes(b.data, bytesPerRow: b.bytesPerRow, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        b.data.withMemoryRebound(to: UInt32.self, capacity: b.bytesPerRow / 4 * h) { p in
            for i in 0..<(b.bytesPerRow / 4 * h) { let v = p[i]; p[i] = (v & 0xFF00_FF00) | ((v & 0xFF) << 16) | ((v >> 16) & 0xFF) }   // BGRA → RGBA
        }
        let ciToDoc = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(d.state.height))
        let viewToDrawable = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: 0, ty: s * c.bounds.height)
        let r = CGRect(x: 0, y: 0, width: d.state.width, height: d.state.height).applying(ciToDoc.concatenating(c.docToViewTransform).concatenating(viewToDrawable))
        // drawable y-up → buffer rows, one pixel in from the antialiased edge
        let x0 = Int(r.minX.rounded(.up)) + 1, y0 = Int((size.height - r.maxY).rounded(.up)) + 1
        let rect = IRect(x: x0, y: y0, width: Int(r.maxX.rounded(.down)) - 1 - x0, height: Int((size.height - r.minY).rounded(.down)) - 1 - y0)
        return Frame(buffer: b, canvas: rect.intersection(IRect(x: 0, y: 0, width: w, height: h)), ms: elapsed)
    }

    /// The display image at 100 %, rendered straight from the composite graph (no cache, no settling, no resampling).
    static func fullDisplay(_ d: Document) -> CGImage? {
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        let img = CanvasRenderer.applyViewMode(Compositor.shared.composite(d), doc: d).cropped(to: sp.ciCanvas)
        return RenderEngine.readbackContext.createCGImage(img, from: sp.ciCanvas, format: .RGBA8, colorSpace: sRGBSpace)
    }

    /// `cg` scaled to w × h by Core Graphics over white (independent of the canvas' own resampling).
    static func scaled(_ cg: CGImage, _ w: Int, _ h: Int) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        b.context.setFillColor(RGBA.white.cgColor)
        b.context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        b.drawImage(cg, in: CGRect(x: 0, y: 0, width: w, height: h), interpolation: .high)
        return b
    }

    struct Diff { var mean = 255.0, max = 255, bad = 1.0 }

    /// Region `ra` of `a` against region `rb` of `b` (same size): mean / max channel difference, share of pixels off by more than 40.
    static func compare(_ a: PixelBuffer, _ ra: IRect, _ b: PixelBuffer, _ rb: IRect) -> Diff {
        guard ra.width == rb.width, ra.height == rb.height, ra.width > 0, ra.height > 0 else { return Diff() }
        var sum = 0, mx = 0, bad = 0
        let pa = a.data.assumingMemoryBound(to: UInt8.self), pb = b.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<ra.height {
            let rowA = pa + (ra.y + y) * a.bytesPerRow + ra.x * 4, rowB = pb + (rb.y + y) * b.bytesPerRow + rb.x * 4
            for x in 0..<ra.width {
                let i = x * 4
                let d0 = abs(Int(rowA[i]) - Int(rowB[i])), d1 = abs(Int(rowA[i + 1]) - Int(rowB[i + 1])), d2 = abs(Int(rowA[i + 2]) - Int(rowB[i + 2]))
                sum += d0 + d1 + d2
                let worst = Swift.max(d0, d1, d2)
                if worst > mx { mx = worst }
                if worst > 40 { bad += 1 }
            }
        }
        let n = ra.width * ra.height
        return Diff(mean: Double(sum) / Double(n * 3), max: mx, bad: Double(bad) / Double(n))
    }

    static func bounds(_ b: PixelBuffer) -> IRect { IRect(x: 0, y: 0, width: b.width, height: b.height) }

    /// Spread of the values in `r` (0: a uniform, blank frame).
    static func spread(_ a: PixelBuffer, _ r: IRect) -> Int {
        var lo = 255, hi = 0
        let p = a.data.assumingMemoryBound(to: UInt8.self)
        for y in stride(from: r.y, to: r.maxY, by: Swift.max(1, r.height / 64)) {
            for x in stride(from: r.x, to: r.maxX, by: Swift.max(1, r.width / 64)) {
                for k in 0..<3 { let v = Int(p[y * a.bytesPerRow + x * 4 + k]); lo = min(lo, v); hi = Swift.max(hi, v) }
            }
        }
        return Swift.max(0, hi - lo)
    }

    static func save(_ b: PixelBuffer, _ url: URL) {
        let rep = NSBitmapImageRep(cgImage: b.makeCGImage())
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func ms(_ t: Date) -> Double { Date().timeIntervalSince(t) * 1000 }

    static func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    static func openAndShow(_ tag: String, _ url: URL, _ dir: URL) {
        let app = AppModel.shared
        let before = app.documents.count
        var alerts: [String] = []
        let hook = AppActions.modalHook
        AppActions.modalHook = { t, i in alerts.append("\(t) \(i)"); return false }
        defer { AppActions.modalHook = hook }
        let t0 = Date()
        AppActions.open(url: url)
        let openMS = ms(t0)
        guard app.documents.count == before + 1, let d = app.activeDocument, d.fileURL == url else {
            check(false, "\(tag): File ▸ Open adds the document (alerts: \(alerts))"); return
        }
        defer { app.close(d) }
        let st = d.state
        let kinds = Dictionary(grouping: st.allLayers, by: \.kindName).map { "\($0.value.count) \($0.key)" }.sorted().joined(separator: ", ")
        print(String(format: "INFO psdopen: %@ — %d×%d %@ %@, %d layers (%@); File ▸ Open %.0f ms; status “%@”", tag, st.width, st.height, "\(st.colorMode)", "\(st.bitDepth)", st.allLayers.count, kinds, openMS, String(app.statusMessage.prefix(80))))
        check(alerts.isEmpty && app.dialog == nil, "\(tag): opens without an alert or dialog \(alerts)")
        check(!st.layers.isEmpty, "\(tag): has layers")
        openTimes.append((tag, openMS))
        check(openMS < slow * 1000, String(format: "\(tag): File ▸ Open blocks the main thread for %.2f s", openMS / 1000))

        // the window: a canvas the size of a laptop's canvas area, given the document like CanvasRepresentable does
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        let c = CanvasView(frame: CGRect(x: 0, y: 0, width: 1180, height: 760))
        win.contentView = c
        let oldCanvas = AppActions.canvas
        AppActions.canvas = c
        defer { c.document = nil; AppActions.canvas = oldCanvas; win.contentView = nil; win.close() }
        c.document = d
        c.layout()
        let fit = d.zoom
        check(!d.needsFitOnScreen && CGFloat(st.width) * CGFloat(fit) <= 1180 && CGFloat(st.height) * CGFloat(fit) <= 760, String(format: "\(tag): fits on screen at %.2f %%", fit * 100))

        guard let full = fullDisplay(d) else { check(false, "\(tag): composite renders"); return }
        // reference document: the 100 % display image as one flat layer, shown by the same canvas code without the cache
        var fs = DocumentState(width: st.width, height: st.height)
        fs.layers = [Layer.raster(name: "flat", buffer: PixelBuffer(cgImage: full))]
        let flat = Document(state: fs, name: "reference")
        flat.needsFitOnScreen = false
        let opaque = isOpaque(full)
        let large = Double(st.width * st.height) / 1_000_000 >= AppModel.shared.prefs.largeDocumentThreshold
        var zooms: [Double] = [fit, 1, 0.5]
        if fit < 0.2 { zooms.append(0.25) }
        zooms.append(2)
        let safe = tag.replacingOccurrences(of: "/", with: "_")
        for (zi, z) in zooms.enumerated() {
            if zi > 0 { c.setZoom(z); c.centerCanvas() }
            let label = zi == 0 ? String(format: "fit %.1f%%", z * 100) : String(format: "%.0f%%", z * 100)
            // first frames show the live graph; after a pause (the canvas schedules a redraw) the cache takes over
            var frames: [Frame] = []
            for i in 0..<4 { frames.append(drawn(d, c)); if i == 1 { pump(0.3) } }
            let cached = !large || CanvasRenderer.cachedComposite(d) === CanvasRenderer.cachedComposite(d)   // (the live graph is new each time)
            flat.zoom = d.zoom; flat.viewOffset = d.viewOffset
            let saved = AppModel.shared.prefs.cacheLargeDocuments
            AppModel.shared.prefs.cacheLargeDocuments = false
            let c2 = CanvasView(frame: c.frame)
            c2.document = flat
            let ref = drawn(flat, c2)
            c2.document = nil
            AppModel.shared.prefs.cacheLargeDocuments = saved
            let a = compare(frames[0].buffer, bounds(frames[0].buffer), ref.buffer, bounds(ref.buffer))
            let b = compare(frames[3].buffer, bounds(frames[3].buffer), ref.buffer, bounds(ref.buffer))
            let canvas = frames[3].canvas
            let sp = spread(frames[3].buffer, canvas), refSpread = spread(ref.buffer, canvas)
            var indep = ""
            var indepOK = true
            if zi == 0, opaque, fit >= 0.1, canvas.width > 200, canvas.height > 200 {   // (tiny canvases: the two resamplers blur fine detail differently)
                // independent of the canvas code: the composite scaled by Core Graphics into the visible canvas rectangle
                let r = CGRect(x: 0, y: 0, width: CGFloat(st.width) * CGFloat(fit) * 2, height: CGFloat(st.height) * CGFloat(fit) * 2)
                let big = scaled(full, Int(r.width.rounded()), Int(r.height.rounded()))
                let off = IRect(x: 1, y: 1, width: canvas.width, height: canvas.height).intersection(bounds(big))
                let e = compare(frames[3].buffer, IRect(x: canvas.x, y: canvas.y, width: off.width, height: off.height), big, off)
                indep = String(format: " | vs CG-scaled composite mean %.2f", e.mean)
                indepOK = e.mean < 6
            }
            let times = frames.map(\.ms)
            if ProcessInfo.processInfo.environment["LUMEN_PSDOPEN_VERBOSE"] != nil {
                print("INFO psdopen:      per frame: " + frames.map { String(format: "%.2f", compare($0.buffer, bounds($0.buffer), ref.buffer, bounds(ref.buffer)).mean) }.joined(separator: " / "))
            }
            print(String(format: "INFO psdopen:    %@ %@: first frame mean %.2f max %d | %@ mean %.2f max %d bad %.2f%%%@ | frames %@ ms", tag, label, a.mean, a.max,
                         cached ? "settled" : "NOT CACHED", b.mean, b.max, b.bad * 100, indep, times.map { String(format: "%.0f", $0) }.joined(separator: "/")))
            let ok = a.mean < 1.5 && b.mean < 1.5 && a.bad < 0.01 && b.bad < 0.01 && (refSpread < 8 || sp >= 8) && indepOK
            if !ok || ProcessInfo.processInfo.environment["LUMEN_PSDOPEN_SAVE"] != nil {
                save(frames[0].buffer, dir.appendingPathComponent("\(safe)_\(zi)_first.png"))
                save(frames[3].buffer, dir.appendingPathComponent("\(safe)_\(zi)_settled.png"))
                save(ref.buffer, dir.appendingPathComponent("\(safe)_\(zi)_reference.png"))
            }
            check(ok, String(format: "\(tag) \(label): the canvas shows the document (first %.2f, settled %.2f, spread %d)", a.mean, b.mean, sp))
            if large && zi == 0 { check(cached, "\(tag): the settled large document is cached") }
            frameTimes.append((tag + " " + label, times.max() ?? 0))
            check((times.max() ?? 0) < slow * 250, String(format: "\(tag) \(label): frames render in %.0f ms at most", times.max() ?? 0))
        }
        // beyond the GPU's texture size the settled composite is a bitmap Core Image tiles: pan across all of it
        if st.width > 16384 || st.height > 16384 {
            var bad: [String] = []
            for z in [1.0, 0.5, 0.37] {
                c.setZoom(z)
                for i in 0..<7 {
                    let fx = (Double(i) + 0.5) / 7
                    d.viewOffset = CGPoint(x: c.bounds.midX - CGFloat(Double(st.width) * fx * z), y: c.bounds.midY - CGFloat(Double(st.height) * fx * z))
                    flat.zoom = d.zoom; flat.viewOffset = d.viewOffset
                    let shown = drawn(d, c)
                    let saved = AppModel.shared.prefs.cacheLargeDocuments
                    AppModel.shared.prefs.cacheLargeDocuments = false
                    let c2 = CanvasView(frame: c.frame)
                    c2.document = flat
                    let ref = drawn(flat, c2)
                    c2.document = nil
                    AppModel.shared.prefs.cacheLargeDocuments = saved
                    let e = compare(shown.buffer, bounds(shown.buffer), ref.buffer, bounds(ref.buffer))
                    if e.mean > 1.5 || e.bad > 0.01 {
                        bad.append(String(format: "%.0f%% at %.0f%%: mean %.1f", z * 100, fx * 100, e.mean))
                        save(shown.buffer, dir.appendingPathComponent("\(safe)_pan_\(Int(z * 100))_\(i).png"))
                    }
                }
            }
            let held = CanvasRenderer.cachedComposite(d) === CanvasRenderer.cachedComposite(d)
            check(held && CanvasRenderer.cachedTexture == nil && bad.isEmpty, "\(tag): panning across the cached composite (beyond the texture limit) shows every part of it \(bad)")
        }
        // the Layers panel's thumbnails (main thread)
        let tt = Date()
        for l in st.allLayers.prefix(200) { _ = Thumbnails.shared.layer(l, doc: d, size: 18); _ = Thumbnails.shared.mask(l, doc: d, size: 18) }
        _ = Thumbnails.shared.composite(d, size: 110)
        let thumbMS = ms(tt)
        print(String(format: "INFO psdopen:    %@ thumbnails for %d layers %.0f ms", tag, min(200, st.allLayers.count), thumbMS))
    }

    /// Main-thread budget in seconds for opening the largest test files (debug builds are ~50× slower at decoding).
    static var slow: Double {
        #if DEBUG
        return 30
        #else
        return 2
        #endif
    }

    static var openTimes: [(String, Double)] = []
    static var frameTimes: [(String, Double)] = []

    static func isOpaque(_ cg: CGImage) -> Bool {
        let b = PixelBuffer(cgImage: cg)
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        for y in stride(from: 0, to: b.height, by: max(1, b.height / 128)) { for x in stride(from: 0, to: b.width, by: max(1, b.width / 128)) where p[y * b.bytesPerRow + x * 4 + 3] < 255 { return false } }
        return true
    }

    // MARK: Synthetic files

    static func planes(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [[UInt8]] {
        // vertical bands × horizontal bands: cheap to build, compresses well, and any flip / offset shows
        var r = [UInt8](repeating: 0, count: w * h), g = r, b = r
        for y in 0..<h {
            for x in 0..<w { let (cr, cg, cb) = f(x, y); let i = y * w + x; r[i] = cr; g[i] = cg; b[i] = cb }
        }
        return [r, g, b]
    }

    static func synthetic(_ dir: URL) -> [(String, URL)] {
        var out: [(String, URL)] = []
        let only = ProcessInfo.processInfo.environment["LUMEN_PSDOPEN_ONLY"]
        func want(_ n: String) -> Bool { only.map { n.contains($0) } ?? true }
        func write(_ name: String, _ f: PSDTestFile) {
            let u = dir.appendingPathComponent(name)
            do { try f.data().write(to: u); out.append((name, u)) } catch { check(false, "synthetic \(name) written (\(error))") }
        }
        func banded(_ w: Int, _ h: Int) -> [[UInt8]] {
            planes(w, h) { x, y in (UInt8(40 + (x * 7 / w) * 30), UInt8(y < h / 3 ? 200 : (y < 2 * h / 3 ? 120 : 30)), UInt8((x / 64 + y / 64) % 2 == 0 ? 60 : 180)) }
        }
        func layer(_ name: String, _ rect: IRect, _ rgb: (UInt8, UInt8, UInt8), alpha: UInt8 = 255) -> PSDTestLayer {
            var l = PSDTestLayer(name: name)
            l.rect = rect
            let n = rect.width * rect.height
            l.planes = [0: [UInt8](repeating: rgb.0, count: n), 1: [UInt8](repeating: rgb.1, count: n), 2: [UInt8](repeating: rgb.2, count: n), -1: [UInt8](repeating: alpha, count: n)]
            return l
        }
        func background(_ w: Int, _ h: Int) -> PSDTestLayer {
            var l = PSDTestLayer(name: "Background")
            l.rect = IRect(x: 0, y: 0, width: w, height: h)
            let p = banded(w, h)
            l.planes = [0: p[0], 1: p[1], 2: p[2], -1: [UInt8](repeating: 255, count: w * h)]
            return l
        }
        // 16-bit RGB, 17.5 MP, a few layers
        if want("big-16bit-rgb.psd") {
            let w = 5000, h = 3500
            var f = PSDTestFile(width: w, height: h); f.depth = 16; f.layersInBlock = true
            f.layers = [background(w, h), layer("Red block", IRect(x: 400, y: 300, width: 1800, height: 1200), (220, 40, 40)), layer("Half blue", IRect(x: 2600, y: 1800, width: 2000, height: 1400), (30, 60, 220), alpha: 128)]
            f.merged = banded(w, h)
            write("big-16bit-rgb.psd", f)
        }
        // 8-bit CMYK, 6 MP
        if want("cmyk-8bit.psd") {
            let w = 3000, h = 2000, n = w * h
            var f = PSDTestFile(width: w, height: h); f.mode = 4
            var l = PSDTestLayer(name: "Background"); l.rect = IRect(x: 0, y: 0, width: w, height: h)
            var cyan = [UInt8](repeating: 255, count: n), mag = cyan, yel = cyan, k = cyan
            for y in 0..<h { for x in 0..<w { let i = y * w + x; if x < w / 2 { cyan[i] = 55 } ; if y < h / 2 { mag[i] = 75 }; if (x / 100) % 3 == 0 { yel[i] = 0 }; if x > w * 3 / 4 && y > h * 3 / 4 { k[i] = 60 } } }
            // CMYK samples are stored inverted (255 = no ink)
            l.planes = [0: cyan, 1: mag, 2: yel, 3: k, -1: [UInt8](repeating: 255, count: n)]
            f.layers = [l]
            f.merged = [cyan, mag, yel, k]
            write("cmyk-8bit.psd", f)
        }
        // 16-bit Lab, 4.7 MP
        if want("lab-16bit.psd") {
            let w = 2600, h = 1800, n = w * h
            var f = PSDTestFile(width: w, height: h); f.mode = 9; f.depth = 16; f.layersInBlock = true
            var L = [UInt8](repeating: 0, count: n), A = L, B = L
            for y in 0..<h { for x in 0..<w { let i = y * w + x; L[i] = UInt8(60 + x * 180 / w); A[i] = y < h / 2 ? 180 : 128; B[i] = (x / 200) % 2 == 0 ? 70 : 128 } }
            var l = PSDTestLayer(name: "Background"); l.rect = IRect(x: 0, y: 0, width: w, height: h)
            l.planes = [0: L, 1: A, 2: B, -1: [UInt8](repeating: 255, count: n)]
            f.layers = [l, layer("Patch", IRect(x: 200, y: 200, width: 600, height: 400), (200, 128, 128))]
            f.merged = [L, A, B]
            write("lab-16bit.psd", f)
        }
        // 8-bit RGB, 140 layers, 4.3 MP
        if want("many-layers.psd") {
            let w = 2400, h = 1800
            var f = PSDTestFile(width: w, height: h)
            f.layers = [background(w, h)]
            for i in 0..<140 {
                let x = (i % 14) * 170, y = (i / 14) * 175
                f.layers.append(layer("Tile \(i)", IRect(x: x + 10, y: y + 10, width: 140, height: 140), (UInt8(i * 37 % 256), UInt8(i * 91 % 256), UInt8(255 - i))))
            }
            f.merged = banded(w, h)
            write("many-layers.psd", f)
        }
        // PSB wider than a GPU texture: the CPU fallback of the canvas cache
        if want("wide.psb") {
            let w = 17000, h = 700
            var f = PSDTestFile(width: w, height: h); f.large = true
            f.layers = [background(w, h), layer("Mark", IRect(x: 8000, y: 100, width: 900, height: 400), (250, 200, 0))]
            f.merged = banded(w, h)
            write("wide.psb", f)
        }
        if want("rgb-32bit.psd") {
            let w = 2400, h = 1800
            var f = PSDTestFile(width: w, height: h); f.depth = 32; f.layersInBlock = true
            f.layers = [background(w, h), layer("Half red", IRect(x: 300, y: 300, width: 900, height: 700), (230, 30, 30), alpha: 128)]
            f.merged = banded(w, h)
            write("rgb-32bit.psd", f)
        }
        if want("gray-16bit.psd") {
            let w = 2400, h = 1800, n = w * h
            var f = PSDTestFile(width: w, height: h); f.mode = 1; f.depth = 16; f.layersInBlock = true
            let g = banded(w, h)[0]
            var l = PSDTestLayer(name: "Background"); l.rect = IRect(x: 0, y: 0, width: w, height: h)
            l.planes = [0: g, -1: [UInt8](repeating: 255, count: n)]
            var m = PSDTestLayer(name: "Dark"); m.rect = IRect(x: 200, y: 200, width: 500, height: 500)
            m.planes = [0: [UInt8](repeating: 20, count: 250_000), -1: [UInt8](repeating: 255, count: 250_000)]
            f.layers = [l, m]
            f.merged = [g]
            write("gray-16bit.psd", f)
        }
        if want("tall.psb") {
            let w = 500, h = 16800
            var f = PSDTestFile(width: w, height: h); f.large = true; f.depth = 16; f.layersInBlock = true
            f.layers = [background(w, h), layer("Mark", IRect(x: 100, y: 12000, width: 300, height: 900), (250, 200, 0))]
            f.merged = banded(w, h)
            write("tall.psb", f)
        }
        // a Lumen-written PSD (exporter + its private resource), 24 MP 16-bit, live type / shape layers
        if want("lumen-written-16bit.psd") {
            var st = SelfTest.baseState(3000, 2000)
            st.bitDepth = .sixteen
            st.layers.append(SelfTest.shapeLayer(CGRect(x: 300, y: 250, width: 1200, height: 800), RGBA(hex: "2E86DE")!, radius: 60))
            var t = TextContent(); t.text = "Lumen"; t.fontName = "Helvetica-Bold"; t.fontSize = 300; t.color = .black; t.position = CGPoint(x: 1600, y: 1100)
            st.layers.append(Layer(name: "Title", content: .text(t)))
            let u = dir.appendingPathComponent("lumen-written-16bit.psd")
            do { try PSDWriter.write(st, to: u); out.append(("lumen-written-16bit.psd", u)) } catch { check(false, "Lumen-written PSD (\(error))") }
        }
        return out
    }
}
