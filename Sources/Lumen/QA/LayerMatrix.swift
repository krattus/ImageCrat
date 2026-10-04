import AppKit
import CoreImage
import Accelerate
import ImageCratCore

/// QA matrix: LAYER KINDS × LAYER / DOCUMENT COMMANDS, model level (no mouse input, no dialogs).
/// Run with `LUMEN_SELFTEST_ONLY=qalayers Lumen --selftest <dir>`.
///   LUMEN_QA_ONLY=<substring>      only check groups whose name contains the substring (e.g. "m2", "regress")
///   LUMEN_QA_SUBJECT=<substring>   only subjects whose name contains the substring
///   LUMEN_QA_CMD=<substring>       only commands whose name contains the substring
///   LUMEN_QA_DUMP=1                write before/after PNGs of failing appearance checks
///   LUMEN_QA_FULL=1                the complete matrix (every subject × every pre-transform × every command, ~10 min);
///                                  the default run covers every subject and every command once plus the key
///                                  conversions on transformed layers, and all regression checks
///   LUMEN_QA_TIMING=1              time spent per command
enum QALayersModule {
    static func register() {
        FeatureModules.selfTests.append(("qalayers", { out in LQA.run(out) }))
    }
}

enum LQA {
    static let W = 400, H = 300
    static var out = URL(fileURLWithPath: NSTemporaryDirectory())
    static var passes: [String: Int] = [:]
    static var fails: [String: Int] = [:]
    static var order: [String] = []
    static var failCount = 0
    static var noteCount = 0
    static let env = ProcessInfo.processInfo.environment
    static var only: String? { env["LUMEN_QA_ONLY"] }
    static var subjectFilter: String? { env["LUMEN_QA_SUBJECT"] }
    static var cmdFilter: String? { env["LUMEN_QA_CMD"] }
    static var dump: Bool { env["LUMEN_QA_DUMP"] == "1" }
    static var full: Bool { env["LUMEN_QA_FULL"] == "1" }
    static var dumpIndex = 0

    // MARK: Reporting

    static func check(_ ok: Bool, _ name: String, _ subject: String = "", _ detail: @autoclosure () -> String = "") {
        if passes[name] == nil && fails[name] == nil { order.append(name) }
        if ok {
            passes[name, default: 0] += 1
        } else {
            fails[name, default: 0] += 1
            failCount += 1
            let d = detail()
            print("FAIL qalayers: \(name)\(subject.isEmpty ? "" : " × " + subject)\(d.isEmpty ? "" : " — " + d)")
        }
    }

    /// A deliberately tolerated difference (expected-lossy case or an unclear behaviour): never counts as a failure.
    static var noted: Set<String> = []
    static func note(_ name: String, _ detail: String = "") {
        guard noted.insert(name).inserted else { return }
        noteCount += 1
        print("NOTE qalayers: \(name)\(detail.isEmpty ? "" : " — " + detail)")
    }

    static func summary() {
        for n in order where fails[n] == nil { print("PASS qalayers: \(n) (\(passes[n] ?? 0))") }
        for n in order where fails[n] != nil { print("qalayers: \(n): \(fails[n]!) failed, \(passes[n] ?? 0) passed") }
        print("qalayers: \(failCount) failed, \(passes.values.reduce(0, +)) passed, \(noteCount) notes")
    }

    static func wants(_ group: String) -> Bool { only.map { group.contains($0) } ?? true }

    // MARK: Rendering helpers

    static func space(_ st: DocumentState) -> CanvasSpace { CanvasSpace(width: st.width, height: st.height) }

    /// Premultiplied RGBA composite of the document (transparent where nothing is drawn).
    static func render(_ st: DocumentState, blur: Double = 0) -> PixelBuffer {
        let sp = space(st)
        var img = Compositor.shared.composite(st)
        if blur > 0 { img = img.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: sp.ciCanvas) }
        return RenderEngine.renderBuffer(img, docRect: st.canvasRect, space: sp)
    }

    /// One layer's full appearance (content, mask, effects, opacity) on transparency.
    static func renderLayer(_ l: Layer, _ st: DocumentState, blur: Double = 0) -> PixelBuffer {
        let sp = space(st)
        var img = Compositor.shared.layerAppearance(l, state: st)
        if blur > 0 { img = img.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: sp.ciCanvas) }
        return RenderEngine.renderBuffer(img, docRect: st.canvasRect, space: sp)
    }

    struct Diff: CustomStringConvertible {
        var mean = 0.0          // mean abs difference per channel (0…255)
        var maxv = 0            // largest channel difference
        var bad = 0.0           // fraction of pixels with a channel differing by more than the threshold
        var sizeMismatch = false
        var description: String { sizeMismatch ? "size mismatch" : String(format: "mean %.2f max %d bad %.2f%%", mean, maxv, bad * 100) }
        func within(mean m: Double, bad b: Double) -> Bool { !sizeMismatch && mean < m && bad <= b }
    }

    /// `bad` counts channel samples (not pixels) that differ by more than `threshold`.
    static func diff(_ a: PixelBuffer, _ b: PixelBuffer, threshold: Int = 48) -> Diff {
        guard a.width == b.width, a.height == b.height, a.format == b.format else { return Diff(sizeMismatch: true) }
        let n = a.width * a.bytesPerPixel
        let pa = a.data.assumingMemoryBound(to: UInt8.self), pb = b.data.assumingMemoryBound(to: UInt8.self)
        var fa = [Float](repeating: 0, count: n), fb = [Float](repeating: 0, count: n), fd = [Float](repeating: 0, count: n)
        var sum = 0.0, mx: Float = 0, bad = 0.0
        var thr = Float(threshold) + 0.5, lo: Float = 0, hi: Float = 1
        for y in 0..<a.height {
            vDSP_vfltu8(pa + y * a.bytesPerRow, 1, &fa, 1, vDSP_Length(n))
            vDSP_vfltu8(pb + y * b.bytesPerRow, 1, &fb, 1, vDSP_Length(n))
            vDSP_vsub(fa, 1, fb, 1, &fd, 1, vDSP_Length(n))
            vDSP_vabs(fd, 1, &fa, 1, vDSP_Length(n))
            var rs: Float = 0, rm: Float = 0
            vDSP_sve(fa, 1, &rs, vDSP_Length(n))
            vDSP_maxv(fa, 1, &rm, vDSP_Length(n))
            sum += Double(rs)
            if rm > mx { mx = rm }
            if rm > thr {
                vDSP_vthres(fa, 1, &thr, &fb, 1, vDSP_Length(n))
                vDSP_vclip(fb, 1, &lo, &hi, &fd, 1, vDSP_Length(n))
                var c: Float = 0
                vDSP_sve(fd, 1, &c, vDSP_Length(n))
                bad += Double(c)
            }
        }
        let total = Double(n * a.height)
        return Diff(mean: sum / total, maxv: Int(mx), bad: bad / total)
    }

    static func diff(_ a: DocumentState, _ b: DocumentState, blur: Double = 0) -> Diff { diff(render(a, blur: blur), render(b, blur: blur)) }

    static func writePNG(_ b: PixelBuffer, _ name: String) {
        guard let d = b.pngData() else { return }
        try? d.write(to: out.appendingPathComponent(name + ".png"))
    }

    /// Writes before/after images of a failing appearance check (LUMEN_QA_DUMP=1).
    static func dumpPair(_ a: PixelBuffer, _ b: PixelBuffer, _ label: String) {
        guard dump, dumpIndex < 120 else { return }
        dumpIndex += 1
        let safe = label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "×", with: "x")
        writePNG(a, String(format: "qa_%03d_%@_a", dumpIndex, safe))
        writePNG(b, String(format: "qa_%03d_%@_b", dumpIndex, safe))
    }

    /// Area the content renderers cover: text, shapes and smart objects are clipped about 64 px outside the canvas.
    static func contentArea(_ st: DocumentState) -> IRect { IRect(x: -72, y: -72, width: st.width + 144, height: st.height + 144) }

    /// Bounding box of pixels with alpha above `threshold` (vectorized; `PixelBuffer.opaqueBounds` is slow in debug builds).
    static func opaqueBounds(_ buf: PixelBuffer, threshold: UInt8 = 16) -> IRect? {
        let w = buf.width, h = buf.height
        let p = buf.data.assumingMemoryBound(to: UInt8.self)
        let stride = buf.bytesPerPixel, off = buf.format == .rgba ? 3 : 0
        var row = [Float](repeating: 0, count: w), acc = [Float](repeating: 0, count: w), tmp = [Float](repeating: 0, count: w)
        var y0 = h, y1 = -1
        let thr = Float(threshold)
        for y in 0..<h {
            vDSP_vfltu8(p + y * buf.bytesPerRow + off, vDSP_Stride(stride), &row, 1, vDSP_Length(w))
            var m: Float = 0
            vDSP_maxv(row, 1, &m, vDSP_Length(w))
            if m > thr {
                if y < y0 { y0 = y }
                y1 = y
                vDSP_vmax(row, 1, acc, 1, &tmp, 1, vDSP_Length(w))
                swap(&acc, &tmp)
            }
        }
        guard y1 >= 0 else { return nil }
        var x0 = w, x1 = -1
        for x in 0..<w where acc[x] > thr { if x < x0 { x0 = x }; x1 = x }
        guard x1 >= 0 else { return nil }
        return IRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    /// Doc-space bounds of the pixels a layer's content actually draws (no mask, no effects), within `contentArea`.
    static func alphaBounds(_ l: Layer, _ st: DocumentState, threshold: UInt8 = 8) -> CGRect? {
        let sp = space(st)
        guard let img = Compositor.shared.contentImage(l, space: sp) else { return nil }
        let r = contentArea(st)
        let buf = RenderEngine.renderBuffer(img, docRect: r, space: sp)
        return opaqueBounds(buf, threshold: threshold).map { $0.offsetBy(dx: r.x, dy: r.y).cgRect }
    }

    /// The part of the document that every renderer draws (text / shapes / smart objects are clipped a little outside the canvas).
    static func visibleArea(_ st: DocumentState) -> CGRect { st.canvasCGRect }

    static func close(_ a: CGRect, _ b: CGRect, _ tol: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol && abs(a.maxX - b.maxX) <= tol && abs(a.maxY - b.maxY) <= tol
    }

    static func encloses(_ outer: CGRect, _ inner: CGRect, _ tol: CGFloat) -> Bool {
        inner.minX >= outer.minX - tol && inner.minY >= outer.minY - tol && inner.maxX <= outer.maxX + tol && inner.maxY <= outer.maxY + tol
    }

    static func fmt(_ r: CGRect?) -> String {
        guard let r else { return "nil" }
        return String(format: "(%.1f,%.1f %.1f×%.1f)", r.minX, r.minY, r.width, r.height)
    }

    static func finite(_ r: CGRect) -> Bool {
        [r.minX, r.minY, r.width, r.height].allSatisfy { $0.isFinite }
    }

    // MARK: State comparison

    private static let tinyRGBA = PixelBuffer(width: 1, height: 1)
    private static let tinyGray = PixelBuffer(width: 1, height: 1, format: .gray)

    /// Replaces every pixel buffer by a 1×1 stand-in and feeds its bytes to the hasher (keeps the JSON small and fast).
    private static func strip(_ st: DocumentState, _ h: inout Hasher) -> DocumentState {
        func buf(_ b: PixelBuffer) -> PixelBuffer {
            h.combine(b.width); h.combine(b.height); h.combine(b.format.rawValue)
            let rb = b.width * b.bytesPerPixel
            for y in 0..<b.height { h.combine(bytes: UnsafeRawBufferPointer(start: b.data + y * b.bytesPerRow, count: rb)) }
            return b.format == .rgba ? tinyRGBA : tinyGray
        }
        func layer(_ l: Layer) -> Layer {
            var x = l
            if var m = l.mask { m.buffer = buf(m.buffer); x.mask = m }
            switch l.content {
            case .raster(var r): r.buffer = buf(r.buffer); x.content = .raster(r)
            case .smartObject(var so):
                switch so.source {
                case .image(let b): so.source = .image(buf(b))
                case .document(let inner): so.source = .document(strip(inner, &h))
                }
                so.filters = so.filters.map { f in var g = f; if let p = f.payload { g.payload = buf(p) }; return g }
                x.content = .smartObject(so)
            case .group(var g): g.children = g.children.map(layer); x.content = .group(g)
            default: break
            }
            return x
        }
        var s = st
        s.layers = st.layers.map(layer)
        if let sel = st.selection { s.selection = buf(sel) }
        s.alphaChannels = st.alphaChannels.map { var c = $0; c.buffer = buf(c.buffer); return c }
        s.frames = []; s.layerComps = []; s.generative = [:]     // UUID-keyed dictionaries: compared separately
        return s
    }

    /// Canonical encoding of a state (pixels hashed). nil when the state no longer encodes (NaN / infinite geometry).
    static func canon(_ st: DocumentState) -> Data? {
        var h = Hasher()
        let s = strip(st, &h)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        guard var d = try? e.encode(s) else { return nil }
        d.append(contentsOf: "\(h.finalize())".utf8)
        return d
    }

    struct Snapshot {
        var data: Data?
        var frames: [AnimationFrame]
        var comps: [LayerComp]
        var generative: Set<UUID>
        init(_ st: DocumentState) {
            data = LQA.canon(st); frames = st.frames; comps = st.layerComps; generative = Set(st.generative.keys)
        }
        func matches(_ o: Snapshot) -> Bool {
            data != nil && data == o.data && frames == o.frames && comps == o.comps && generative == o.generative
        }
    }

    // MARK: Documents

    @discardableResult
    static func withDoc<T>(_ st: DocumentState, select ids: [UUID] = [], name: String = "qa", _ body: (Document) -> T) -> T {
        let app = AppModel.shared
        let previous = app.activeDocumentID
        let d = Document(state: st, name: name)
        app.documents.append(d)
        app.activeDocumentID = d.id
        if let last = ids.last { d.selectedLayerIDs = Set(ids); d.activeLayerID = last }
        defer {
            app.documents.removeAll { $0.id == d.id }
            app.activeDocumentID = previous
        }
        return body(d)
    }

    // MARK: Layer attributes

    /// Everything Photoshop keeps on a layer when its geometry or contents change.
    static func attrs(_ l: Layer) -> [String: String] {
        var a: [String: String] = [:]
        a["name"] = l.name
        a["opacity"] = String(format: "%.4f", l.opacity)
        a["fill"] = String(format: "%.4f", l.fillOpacity)
        a["blend"] = "\(l.blendMode)"
        a["clipped"] = "\(l.isClipped)"
        a["locks"] = "\(l.locks.transparency)\(l.locks.pixels)\(l.locks.position)\(l.locks.all)"
        a["label"] = l.colorLabel.rawValue
        a["visible"] = "\(l.isVisible)"
        a["link"] = l.linkID?.uuidString ?? "-"
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        a["effects"] = (try? enc.encode(l.effects)).map { "\($0.hashValue)-\($0.count)" } ?? "?"
        a["blendIf"] = "\(l.blendIf)"
        a["knockout"] = l.knockout.rawValue
        a["channels"] = "\(l.channelR)\(l.channelG)\(l.channelB)"
        a["advanced"] = "\(l.blendInteriorEffectsAsGroup)\(l.blendClippedAsGroup)\(l.layerMaskHidesEffects)\(l.vectorMaskHidesEffects)"
        a["mask"] = l.mask.map { "linked=\($0.isLinked) enabled=\($0.isEnabled) feather=\($0.feather) density=\($0.density)" } ?? "-"
        a["vmask"] = l.vectorMask == nil ? "-" : "on=\(l.vectorMaskEnabled)"
        return a
    }

    static func attrDiff(_ a: [String: String], _ b: [String: String], ignoring: Set<String> = []) -> [String] {
        a.keys.sorted().filter { !ignoring.contains($0) && a[$0] != b[$0] }.map { "\($0): \(a[$0] ?? "") → \(b[$0] ?? "")" }
    }

    static func kind(_ l: Layer) -> String {
        switch l.content {
        case .raster: return "raster"
        case .text: return "text"
        case .shape: return "shape"
        case .smartObject: return "smart"
        case .adjustment: return "adjustment"
        case .fill: return "fill"
        case .group(let g): return g.artboard != nil ? "artboard" : "group"
        }
    }

    // MARK: Entry point

    static func run(_ dir: URL) {
        out = dir
        passes = [:]; fails = [:]; order = []; failCount = 0; noteCount = 0; noted = []
        let t0 = CFAbsoluteTimeGetCurrent()
        // Model-level run: no canvas (an earlier self test may have left one; Paste, fit-on-screen … consult it).
        let savedCanvas = AppActions.canvas
        AppActions.canvas = nil
        defer { AppActions.canvas = savedCanvas }
        let subjects = QASubjects.all().filter { s in subjectFilter.map { s.name.contains($0) } ?? true }
        print("qalayers: \(subjects.count) subjects")
        if wants("m1.transform") { QATransforms.runMatrix(subjects) }
        if wants("m2.layer") { QALayerCommands.runMatrix(subjects) }
        if wants("m3.document") { QADocumentCommands.run(subjects) }
        if wants("regress") { LQARegressions.run() }
        Compositor.shared.clearCaches()
        QALayerCommands.printTiming()
        summary()
        print(String(format: "qalayers: %.1f s", CFAbsoluteTimeGetCurrent() - t0))
    }
}
