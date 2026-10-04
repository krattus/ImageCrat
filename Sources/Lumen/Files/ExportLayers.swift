import AppKit
import SwiftUI
import CoreImage
import UniformTypeIdentifiers
import ImageCratCore

// MARK: - Layers to Files

enum LayersToFiles {
    enum Format: String, CaseIterable, Identifiable {
        case png = "PNG-24", jpeg = "JPEG", tiff = "TIFF", psd = "PSD", pdf = "PDF", bmp = "BMP"
        var id: String { rawValue }
        var ext: String { ["png", "jpg", "tif", "psd", "pdf", "bmp"][Format.allCases.firstIndex(of: self)!] }
    }

    struct Options {
        var folder: URL
        var prefix = "Layer"
        var format: Format = .png
        var visibleOnly = true
        var trim = false
        var quality = 0.9
        /// Top-level groups export as one flattened file instead of one file per child layer.
        var groupsAsFiles = false
    }

    /// Layers that become files (bottom → top).
    static func targets(_ st: DocumentState, options o: Options) -> [Layer] {
        var out: [Layer] = []
        func walk(_ ls: [Layer], parentVisible: Bool) {
            for l in ls {
                let vis = parentVisible && l.isVisible
                if o.visibleOnly && !vis { continue }
                if l.isGroup && !o.groupsAsFiles { walk(l.children, parentVisible: vis); continue }
                if l.isAdjustment { continue }
                out.append(l)
            }
        }
        walk(st.layers, parentVisible: true)
        return out
    }

    /// A state holding only `layer` (made visible), optionally trimmed to its visible pixels.
    static func singleLayerState(_ st: DocumentState, _ layer: Layer, trim: Bool) -> DocumentState? {
        var s = st
        var l = layer
        l.isVisible = true
        l.isClipped = false
        s.layers = [l]
        s.selection = nil
        s.alphaChannels = []
        s.frames = []
        s.videoTimeline = nil
        if trim {
            let sp = CanvasSpace(width: st.width, height: st.height)
            let img = Compositor.shared.layerAppearance(l, state: st)
            let buf = RenderEngine.renderBuffer(img, docRect: st.canvasRect, space: sp)
            guard let b = buf.opaqueBounds() else { return nil }
            s.layers[0].translate(dx: -Double(b.x), dy: -Double(b.y), document: true)
            s.width = b.width
            s.height = b.height
        }
        return s
    }

    @discardableResult
    static func export(_ st: DocumentState, options o: Options) throws -> [URL] {
        try FileManager.default.createDirectory(at: o.folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (i, l) in targets(st, options: o).reversed().enumerated() {
            guard let s = singleLayerState(st, l, trim: o.trim) else { continue }
            let name = String(format: "%@_%04d_%@.%@", o.prefix, i, FilesUI.safeName(l.name), o.format.ext)
            let url = o.folder.appendingPathComponent(name)
            switch o.format {
            case .png: try DocumentIO.export(s, to: url, format: .png, quality: 1, scale: 1)
            case .jpeg: try DocumentIO.export(s, to: url, format: .jpeg, quality: o.quality, scale: 1)
            case .tiff: try DocumentIO.export(s, to: url, format: .tiff, quality: 1, scale: 1)
            case .bmp: try DocumentIO.export(s, to: url, format: .bmp, quality: 1, scale: 1)
            case .psd: try PSDWriter.write(s, to: url)
            case .pdf: try PDFExport.write(s, to: url)
            }
            urls.append(url)
        }
        return urls
    }
}

struct LayersToFilesDialog: View {
    @State private var folder: URL? = AppModel.shared.activeDocument?.fileURL?.deletingLastPathComponent()
    @State private var prefix = (AppModel.shared.activeDocument.map { ($0.name as NSString).deletingPathExtension }) ?? "Layer"
    @State private var format: LayersToFiles.Format = .png
    @State private var visibleOnly = true
    @State private var trim = false
    @State private var groups = false
    @State private var quality = 0.9

    var body: some View {
        DialogFrame(title: "Export Layers to Files", width: 440, okTitle: "Run", onOK: run) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Destination").frame(width: 80, alignment: .leading)
                    Text(folder?.path ?? "—").lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.textDim)
                    Spacer()
                    Button("Browse…") { folder = FilesUI.chooseFolder() ?? folder }.buttonStyle(PanelButtonStyle())
                }
                HStack {
                    Text("File Prefix").frame(width: 80, alignment: .leading)
                    TextField("", text: $prefix).frame(width: 200)
                }
                Picker("File Type", selection: $format) { ForEach(LayersToFiles.Format.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 220)
                if format == .jpeg { ValueSlider(label: "Quality", value: $quality, range: 0.1...1, format: "%.2f") }
                Toggle2(label: "Visible Layers Only", on: $visibleOnly)
                Toggle2(label: "Trim Layers", on: $trim)
                Toggle2(label: "Export Groups as Single Files", on: $groups)
                if let d = AppModel.shared.activeDocument, let f = folder {
                    let n = LayersToFiles.targets(d.state, options: .init(folder: f, visibleOnly: visibleOnly, groupsAsFiles: groups)).count
                    Text("\(n) file(s) will be written.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                }
            }
        }
    }

    func run() {
        guard let d = AppModel.shared.activeDocument, let f = folder ?? FilesUI.chooseFolder() else { return }
        let o = LayersToFiles.Options(folder: f, prefix: prefix, format: format, visibleOnly: visibleOnly, trim: trim, quality: quality, groupsAsFiles: groups)
        do {
            let urls = try LayersToFiles.export(d.state, options: o)
            AppModel.shared.setStatus("Exported \(urls.count) layer file(s).")
        } catch { AppActions.alert("Export failed.", error.localizedDescription) }
    }
}

// MARK: - Save for Web (Legacy)

enum WebFormat: String, CaseIterable, Identifiable {
    case gif = "GIF", png8 = "PNG-8", png24 = "PNG-24", jpeg = "JPEG", webp = "WebP"
    var id: String { rawValue }
    var ext: String { ["gif", "png", "png", "jpg", "webp"][WebFormat.allCases.firstIndex(of: self)!] }
    var indexed: Bool { self == .gif || self == .png8 }
    var lossy: Bool { self == .jpeg || self == .webp }
    static let webpType = "org.webmproject.webp"
    static var available: [WebFormat] {
        let types = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return allCases.filter { $0 != .webp || types.contains(webpType) }
    }
}

enum WebMetadata: String, CaseIterable { case none = "None", copyright = "Copyright", copyrightContact = "Copyright and Contact Info", all = "All" }

struct WebSettings: Equatable {
    var format: WebFormat = .jpeg
    var quality: Double = 60          // 0…100
    var colors: Int = 128             // 2…256 (GIF / PNG-8)
    var dither = true
    var transparency = true
    var matte: RGBA = .white
    var progressive = false
}

enum WebEncoder {
    struct Result { var data: Data; var preview: CGImage? }

    static func encode(_ cg: CGImage, _ s: WebSettings, metadata: WebMetadata = .none, copyright: String = "", contact: String = "") -> Result? {
        var props: [CFString: Any] = [:]
        if metadata != .none && !copyright.isEmpty {
            props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCopyright: copyright, kCGImagePropertyTIFFArtist: metadata == .copyright ? "" : contact]
            props[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCCopyrightNotice: copyright]
            props[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGCopyright: copyright] as [CFString: Any]
        }
        if metadata == .all { props[kCGImagePropertyDPIWidth] = 72; props[kCGImagePropertyDPIHeight] = 72 }
        let data: Data?
        switch s.format {
        case .jpeg, .webp:
            let flat = flattened(cg, matte: s.matte)
            props[kCGImageDestinationLossyCompressionQuality] = max(0.01, s.quality / 100)
            if s.progressive && s.format == .jpeg { props[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true] }
            data = imageIO(flat, type: s.format == .jpeg ? UTType.jpeg.identifier : WebFormat.webpType, props: props)
        case .png24:
            data = imageIO(s.transparency ? cg : flattened(cg, matte: s.matte), type: UTType.png.identifier, props: props)
        case .png8:
            let q = WebQuantizer.quantize(cg, colors: s.colors, dither: s.dither, transparency: s.transparency, matte: s.matte)
            data = PNG8Writer.write(q)
        case .gif:
            let q = WebQuantizer.quantize(cg, colors: s.colors, dither: s.dither, transparency: s.transparency, matte: s.matte)
            data = imageIO(q.makeImage(), type: UTType.gif.identifier, props: [:])
        }
        guard let d = data else { return nil }
        let preview = CGImageSourceCreateWithData(d as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        return Result(data: d, preview: preview)
    }

    static func imageIO(_ cg: CGImage, type: String, props: [CFString: Any]) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func flattened(_ cg: CGImage, matte: RGBA) -> CGImage {
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return cg }
        ctx.setFillColor(matte.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage() ?? cg
    }

    /// Seconds to download `bytes` at `bitsPerSecond`.
    static func downloadTime(_ bytes: Int, bitsPerSecond: Double) -> Double { Double(bytes) * 8 / bitsPerSecond }

    static func sizeLabel(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B" : (bytes < 1024 * 1024 ? String(format: "%.1fK", Double(bytes) / 1024) : String(format: "%.2fM", Double(bytes) / 1048576))
    }
}

/// Indexed image: palette (RGBA) + one index per pixel.
struct IndexedImage {
    var width: Int
    var height: Int
    var palette: [(UInt8, UInt8, UInt8, UInt8)]
    var indices: [UInt8]

    func makeImage() -> CGImage {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let c = palette[Int(indices[i])]
            // premultiplied
            let a = Int(c.3)
            px[i * 4] = UInt8(Int(c.0) * a / 255); px[i * 4 + 1] = UInt8(Int(c.1) * a / 255); px[i * 4 + 2] = UInt8(Int(c.2) * a / 255); px[i * 4 + 3] = c.3
        }
        let prov = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: sRGBSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: prov, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }
}

/// Median-cut colour reduction with optional Floyd–Steinberg dithering and 1-bit transparency.
enum WebQuantizer {
    static func pixels(_ cg: CGImage) -> (Int, Int, [UInt8]) {
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { p in
            let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGBSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // un-premultiply
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Int(px[i + 3])
            if a > 0 && a < 255 { for k in 0..<3 { px[i + k] = UInt8(min(255, Int(px[i + k]) * 255 / a)) } }
        }
        return (w, h, px)
    }

    static func quantize(_ cg: CGImage, colors: Int, dither: Bool, transparency: Bool, matte: RGBA) -> IndexedImage {
        let (w, h, px0) = pixels(cg)
        var px = px0
        let mr = Int(matte.r * 255), mg = Int(matte.g * 255), mb = Int(matte.b * 255)
        var hasTransparent = false
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Int(px[i + 3])
            if transparency && a < 128 { hasTransparent = true; continue }
            if a < 255 {   // blend onto the matte
                px[i] = UInt8((Int(px[i]) * a + mr * (255 - a)) / 255)
                px[i + 1] = UInt8((Int(px[i + 1]) * a + mg * (255 - a)) / 255)
                px[i + 2] = UInt8((Int(px[i + 2]) * a + mb * (255 - a)) / 255)
            }
            px[i + 3] = 255
        }
        let n = max(2, min(256, colors)) - (hasTransparent ? 1 : 0)
        // collect a sample of opaque colours
        var samples: [(Int, Int, Int)] = []
        let total = w * h
        let stride = max(1, total / 65536)
        var i = 0
        while i < total {
            let o = i * 4
            if px[o + 3] == 255 { samples.append((Int(px[o]), Int(px[o + 1]), Int(px[o + 2]))) }
            i += stride
        }
        var palette = medianCut(samples, n)
        if palette.isEmpty { palette = [(0, 0, 0)] }
        var pal: [(UInt8, UInt8, UInt8, UInt8)] = palette.map { (UInt8($0.0), UInt8($0.1), UInt8($0.2), 255) }
        let transparentIndex = hasTransparent ? pal.count : -1
        if hasTransparent { pal.append((0, 0, 0, 0)) }
        var cache: [Int: UInt8] = [:]
        func nearest(_ r: Int, _ g: Int, _ b: Int) -> UInt8 {
            let key = (r >> 2) << 12 | (g >> 2) << 6 | (b >> 2)
            if let c = cache[key] { return c }
            var best = 0, bd = Int.max
            for (k, p) in palette.enumerated() {
                let dr = r - p.0, dg = g - p.1, db = b - p.2
                let d = dr * dr * 3 + dg * dg * 4 + db * db * 2
                if d < bd { bd = d; best = k }
            }
            cache[key] = UInt8(best)
            return UInt8(best)
        }
        var idx = [UInt8](repeating: 0, count: total)
        var err = dither ? [Int](repeating: 0, count: (w + 2) * 3 * 2) : []
        for y in 0..<h {
            if dither {   // rotate error rows
                for k in 0..<((w + 2) * 3) { err[k] = err[(w + 2) * 3 + k]; err[(w + 2) * 3 + k] = 0 }
            }
            for x in 0..<w {
                let o = (y * w + x) * 4
                if px[o + 3] == 0 && hasTransparent { idx[y * w + x] = UInt8(transparentIndex); continue }
                var r = Int(px[o]), g = Int(px[o + 1]), b = Int(px[o + 2])
                if dither {
                    let e = (x + 1) * 3
                    r = min(255, max(0, r + err[e] / 16)); g = min(255, max(0, g + err[e + 1] / 16)); b = min(255, max(0, b + err[e + 2] / 16))
                }
                let k = nearest(r, g, b)
                idx[y * w + x] = k
                if dither {
                    let p = palette[Int(k)]
                    let er = r - p.0, eg = g - p.1, eb = b - p.2
                    let cur = (x + 1) * 3, next = (w + 2) * 3
                    for (dx, row, f) in [(1, 0, 7), (-1, 1, 3), (0, 1, 5), (1, 1, 1)] {
                        let j = (row == 0 ? 0 : next) + cur + dx * 3
                        err[j] += er * f; err[j + 1] += eg * f; err[j + 2] += eb * f
                    }
                }
            }
        }
        return IndexedImage(width: w, height: h, palette: pal, indices: idx)
    }

    /// Median cut: repeatedly split the box with the largest range at its median.
    static func medianCut(_ px: [(Int, Int, Int)], _ n: Int) -> [(Int, Int, Int)] {
        guard !px.isEmpty else { return [] }
        // exact palette when there are few distinct colours
        var distinct = Set<Int>()
        for p in px { distinct.insert(p.0 << 16 | p.1 << 8 | p.2); if distinct.count > n { break } }
        if distinct.count <= n { return distinct.map { ($0 >> 16 & 255, $0 >> 8 & 255, $0 & 255) } }
        var boxes: [[(Int, Int, Int)]] = [px]
        // Largest channel range of a box and its axis, measured once per box. (Re-measuring every box on every split —
        // with a temporary array per pixel — froze the Save for Web dialog for many seconds on each control change.)
        func measure(_ b: [(Int, Int, Int)]) -> (range: Int, axis: Int) {
            guard b.count > 1 else { return (-1, 0) }
            var l0 = 255, l1 = 255, l2 = 255, h0 = 0, h1 = 0, h2 = 0
            for p in b {
                if p.0 < l0 { l0 = p.0 }; if p.0 > h0 { h0 = p.0 }
                if p.1 < l1 { l1 = p.1 }; if p.1 > h1 { h1 = p.1 }
                if p.2 < l2 { l2 = p.2 }; if p.2 > h2 { h2 = p.2 }
            }
            var best = (range: h0 - l0, axis: 0)
            if h1 - l1 > best.range { best = (h1 - l1, 1) }
            if h2 - l2 > best.range { best = (h2 - l2, 2) }
            return best
        }
        var measures = [measure(px)]
        while boxes.count < n {
            var bi = -1, bestRange = -1, bestAxis = 0
            for (i, m) in measures.enumerated() where m.range > bestRange { bestRange = m.range; bi = i; bestAxis = m.axis }
            if bi < 0 || bestRange <= 0 { break }
            let axis = bestAxis
            let sorted = boxes[bi].sorted { axis == 0 ? $0.0 < $1.0 : (axis == 1 ? $0.1 < $1.1 : $0.2 < $1.2) }
            let mid = sorted.count / 2
            boxes[bi] = Array(sorted[..<mid])
            boxes.append(Array(sorted[mid...]))
            measures[bi] = measure(boxes[bi])
            measures.append(measure(boxes[boxes.count - 1]))
        }
        return boxes.filter { !$0.isEmpty }.map { b in
            var r = 0, g = 0, bl = 0
            for p in b { r += p.0; g += p.1; bl += p.2 }
            return (r / b.count, g / b.count, bl / b.count)
        }
    }
}

/// Palette PNG (colour type 3) with tRNS, written natively (zlib stream around Foundation's raw deflate).
enum PNG8Writer {
    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ bytes: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
    static func adler32(_ d: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for x in d { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
        return b << 16 | a
    }
    private static func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]) }
    private static func chunk(_ type: String, _ body: Data) -> Data {
        var d = be32(UInt32(body.count))
        var tb = Data(type.utf8); tb.append(body)
        d.append(tb); d.append(be32(crc32(tb)))
        return d
    }

    static func write(_ img: IndexedImage) -> Data? {
        var raw = Data(capacity: (img.width + 1) * img.height)
        for y in 0..<img.height {
            raw.append(0)
            raw.append(contentsOf: img.indices[(y * img.width)..<(y * img.width + img.width)])
        }
        guard let deflated = try? (raw as NSData).compressed(using: .zlib) as Data else { return nil }
        var z = Data([0x78, 0x9C]); z.append(deflated); z.append(be32(adler32(raw)))
        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = be32(UInt32(img.width)); ihdr.append(be32(UInt32(img.height))); ihdr.append(contentsOf: [8, 3, 0, 0, 0])
        out.append(chunk("IHDR", ihdr))
        var plte = Data(); var trns = Data()
        for c in img.palette { plte.append(contentsOf: [c.0, c.1, c.2]); trns.append(c.3) }
        out.append(chunk("PLTE", plte))
        if img.palette.contains(where: { $0.3 < 255 }) {
            while trns.last == 255 { trns.removeLast() }
            out.append(chunk("tRNS", trns))
        }
        out.append(chunk("IDAT", z))
        out.append(chunk("IEND", Data()))
        return out
    }
}

struct SaveForWebDialog: View {
    @State private var layout = 1                // 0 original, 1 2-up, 2 4-up
    @State private var panes: [WebSettings] = [WebSettings(format: .jpeg, quality: 60), WebSettings(format: .png8, colors: 128),
                                               WebSettings(format: .gif, colors: 64), WebSettings(format: .png24)]
    @State private var selected = 0
    @State private var percent: Double = 100
    @State private var metadata: WebMetadata = .copyright
    @State private var copyright = ""
    @State private var speedIndex = 2
    @State private var results: [Int: WebEncoder.Result] = [:]
    @State private var source: CGImage?

    static let speeds: [(String, Double)] = [("56.6 Kbps Modem", 56_600), ("512 Kbps DSL", 512_000), ("2 Mbps", 2_000_000), ("8 Mbps", 8_000_000), ("50 Mbps", 50_000_000)]

    var body: some View {
        DialogFrame(title: "Save for Web (Legacy)", width: 900, okTitle: "Save…", onOK: save) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $layout) { Text("Original").tag(0); Text("2-Up").tag(1); Text("4-Up").tag(2) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                HStack(alignment: .top, spacing: 10) {
                    previews.frame(width: 600, height: 420)
                    settingsColumn.frame(width: 250)
                }
                HStack(spacing: 12) {
                    Text("Image Size").font(Theme.fontBold)
                    NumberFieldPct(value: $percent)
                    if let s = source { Text("\(Int(Double(s.width) * pct / 100)) × \(Int(Double(s.height) * pct / 100)) px").foregroundStyle(Theme.textDim) }
                    Spacer()
                    Picker("Metadata", selection: $metadata) { ForEach(WebMetadata.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 250)
                    Picker("", selection: $speedIndex) { ForEach(Array(Self.speeds.enumerated()), id: \.offset) { Text($1.0).tag($0) } }.labelsHidden().frame(width: 150)
                }
                if metadata != .none {
                    HStack { Text("Copyright").frame(width: 70, alignment: .leading); TextField("© Your Name", text: $copyright).frame(width: 260) }
                }
            }
        }
        .onAppear { loadSource(); encodeAll() }
        .onChange(of: panes) { _, _ in encodeAll() }
        .onChange(of: percent) { _, _ in loadSource(); encodeAll() }
        .onChange(of: metadata) { _, _ in encodeAll() }
    }

    private var visiblePanes: [Int] { layout == 0 ? [] : (layout == 1 ? [0] : [0, 1, 2]) }
    /// The typed percentage, bounded like its stepper (the text field itself accepts any number).
    private var pct: Double { percent.isFinite ? min(max(percent, 1), 400) : 100 }

    @ViewBuilder private var previews: some View {
        let cols = layout == 2 ? 2 : (layout == 1 ? 2 : 1)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: cols), spacing: 6) {
            paneView(nil)
            ForEach(visiblePanes, id: \.self) { i in paneView(i) }
        }
    }

    @ViewBuilder private func paneView(_ i: Int?) -> some View {
        let h: CGFloat = layout == 2 ? 190 : 380
        VStack(spacing: 2) {
            ZStack {
                Color(white: 0.2)
                if let img = i.flatMap({ results[$0]?.preview }) ?? (i == nil ? source : nil) {
                    Image(decorative: img, scale: 1).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                }
            }
            .frame(height: h)
            .clipped()
            HStack {
                if let i {
                    let r = results[i]
                    Text(panes[i].format.rawValue).font(Theme.fontBold)
                    Text(r.map { WebEncoder.sizeLabel($0.data.count) } ?? "…")
                    Text(r.map { String(format: "%.1f sec @ %@", WebEncoder.downloadTime($0.data.count, bitsPerSecond: Self.speeds[speedIndex].1), Self.speeds[speedIndex].0) } ?? "")
                        .foregroundStyle(Theme.textFaint)
                } else {
                    Text("Original").font(Theme.fontBold)
                    if let s = source { Text("\(s.width) × \(s.height)").foregroundStyle(Theme.textFaint) }
                }
                Spacer()
            }.font(Theme.fontSmall)
        }
        .padding(3)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(i == selected ? Theme.accent : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { if let i { selected = i } }
    }

    @ViewBuilder private var settingsColumn: some View {
        let i = visiblePanes.contains(selected) ? selected : 0
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings (pane \(i + 1))").font(Theme.fontBold)
            Picker("Format", selection: $panes[i].format) { ForEach(WebFormat.available) { Text($0.rawValue).tag($0) } }
            if panes[i].format.lossy {
                ValueSlider(label: "Quality", value: $panes[i].quality, range: 0...100, labelWidth: 60)
                if panes[i].format == .jpeg { Toggle2(label: "Progressive", on: $panes[i].progressive) }
            }
            if panes[i].format.indexed {
                ValueSlider(label: "Colors", value: Binding(get: { Double(panes[i].colors) }, set: { panes[i].colors = Int($0) }), range: 2...256, labelWidth: 60)
                Toggle2(label: "Dither", on: $panes[i].dither)
            }
            if panes[i].format != .jpeg { Toggle2(label: "Transparency", on: $panes[i].transparency) }
            HStack {
                Text("Matte")
                Picker("", selection: Binding(get: { panes[i].matte == .white ? 0 : (panes[i].matte == .black ? 1 : 2) },
                                              set: { panes[i].matte = [RGBA.white, RGBA.black, RGBA(gray: 0.5)][$0] })) {
                    Text("White").tag(0); Text("Black").tag(1); Text("Gray").tag(2)
                }.labelsHidden().frame(width: 100)
            }
            Spacer()
        }
    }

    func loadSource() {
        guard let d = AppModel.shared.activeDocument, let cg = Compositor.shared.flatten(d.state) else { return }
        let k = pct / 100
        source = abs(k - 1) < 0.001 ? cg : VideoRenderer.scaled(cg, max(1, Int(Double(cg.width) * k)), max(1, Int(Double(cg.height) * k)))
    }

    func encodeAll() {
        guard let s = source else { return }
        for i in 0..<panes.count {
            results[i] = WebEncoder.encode(s, panes[i], metadata: metadata, copyright: copyright, contact: copyright)
        }
    }

    func save() {
        guard let d = AppModel.shared.activeDocument else { return }
        let i = visiblePanes.contains(selected) ? selected : 0
        guard let r = results[i] else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = (d.name as NSString).deletingPathExtension + "." + panes[i].format.ext
        guard UIBlock.run(p) == .OK, let url = p.url else { return }
        do { try r.data.write(to: url); AppModel.shared.setStatus("Saved \(url.lastPathComponent) (\(WebEncoder.sizeLabel(r.data.count)))") }
        catch { AppActions.alert("Could not save.", error.localizedDescription) }
    }
}

/// Percent field with a stepper.
struct NumberFieldPct: View {
    @Binding var value: Double
    var body: some View {
        HStack(spacing: 2) {
            TextField("", value: $value, format: .number).frame(width: 50)
            Text("%")
            Stepper("", value: $value, in: 1...400, step: 5).labelsHidden()
        }
    }
}
