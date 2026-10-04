import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Compression
import Accelerate

// "Smallest for Web": every format this Mac can encode is tuned (by binary search on its quality knob) to the same
// perceptual target, so their sizes are comparable, plus helpers for responsive sets, transfer-size estimates,
// colour + alpha-mask splitting and a detector for images that CSS could draw without any file at all.

enum WXFormatKind: String, CaseIterable, Identifiable {
    case ultraPNG = "PNG · Perceptual Ultra"
    case ultraPNGLossless = "PNG · Ultra lossless"
    case avif = "AVIF"
    case webp = "WebP"
    case jpeg = "JPEG"
    case jpegMask = "JPEG + alpha mask"
    case gif = "GIF"
    case heic = "HEIC"
    var id: String { rawValue }

    var ext: String {
        switch self {
        case .ultraPNG, .ultraPNGLossless: return "png"
        case .avif: return "avif"
        case .webp: return "webp"
        case .jpeg, .jpegMask: return "jpg"
        case .gif: return "gif"
        case .heic: return "heic"
        }
    }
    var mime: String {
        switch self {
        case .ultraPNG, .ultraPNGLossless: return "image/png"
        case .avif: return "image/avif"
        case .webp: return "image/webp"
        case .jpeg, .jpegMask: return "image/jpeg"
        case .gif: return "image/gif"
        case .heic: return "image/heic"
        }
    }
    /// Browser-support note shown in the table.
    var support: String {
        switch self {
        case .ultraPNG, .ultraPNGLossless: return "every browser"
        case .avif: return "Chrome 85+, Firefox 93+, Safari 16.4+ (≈95 %); keep a fallback"
        case .webp: return "all current browsers (since 2020)"
        case .jpeg: return "every browser; no transparency"
        case .jpegMask: return "every browser with CSS mask-image (≈97 %)"
        case .gif: return "every browser; 256 colours, 1-bit alpha"
        case .heic: return "Safari only — not for the open web"
        }
    }
    /// Safe to pick automatically as "the" web file.
    var webSafe: Bool { self != .heic }
    var supportsAlpha: Bool { self != .jpeg }
}

struct WXCandidate: Identifiable {
    let id = UUID()
    var kind: WXFormatKind
    var data: Data
    /// Companion files (e.g. the alpha mask of a colour + mask pair): suffix → data.
    var extra: [(suffix: String, data: Data)] = []
    var quality = UPQuality()
    var setting = ""
    var seconds = 0.0
    var targetMet = true
    var lossless = false
    var decoded: UPImage? = nil
    var totalBytes: Int { data.count + extra.reduce(0) { $0 + $1.data.count } }
}

enum WXEncoders {
    static let imageIOTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    static let webpType = "org.webmproject.webp"

    /// A `cwebp` binary installed by the user (Homebrew / MacPorts); ImageIO itself cannot write WebP.
    static let cwebpPath: String? = {
        for p in ["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp", "/opt/local/bin/cwebp"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }()

    static func available(_ k: WXFormatKind) -> Bool {
        switch k {
        case .ultraPNG, .ultraPNGLossless, .jpeg, .jpegMask: return true
        case .avif: return imageIOTypes.contains("public.avif")
        case .heic: return imageIOTypes.contains("public.heic")
        case .gif: return imageIOTypes.contains("com.compuserve.gif")
        case .webp: return imageIOTypes.contains(webpType) || cwebpPath != nil
        }
    }

    static var unavailableNotes: [String] {
        var n: [String] = []
        if !available(.webp) { n.append("WebP: macOS cannot encode it (install `cwebp`, e.g. `brew install webp`, and it appears here)") }
        if !imageIOTypes.contains("public.jxl") { n.append("JPEG XL: no encoder on this system (Safari 17+ only so far)") }
        if !available(.avif) { n.append("AVIF: no encoder on this macOS version") }
        return n
    }

    static func flatten(_ img: UPImage, matte: (UInt8, UInt8, UInt8) = (255, 255, 255)) -> UPImage {
        guard img.hasAlpha else { return img }
        var out = img
        let n = img.px.count
        out.px.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < n {
                let a = Int(p[i + 3])
                if a != 255 {
                    p[i] = UInt8((Int(p[i]) * a + Int(matte.0) * (255 - a) + 127) / 255)
                    p[i + 1] = UInt8((Int(p[i + 1]) * a + Int(matte.1) * (255 - a) + 127) / 255)
                    p[i + 2] = UInt8((Int(p[i + 2]) * a + Int(matte.2) * (255 - a) + 127) / 255)
                    p[i + 3] = 255
                }
                i += 4
            }
        }
        return out
    }

    /// ImageIO lossy encode (`q` 0…1).
    static func imageIO(_ img: UPImage, type: String, q: Double, extra: [CFString: Any] = [:]) -> Data? {
        guard let cg = UPBridge.cgImage(img) else { return nil }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: q]
        for (k, v) in extra { props[k] = v }
        return UPBridge.encode(cg, type: type, props: props)
    }

    static func cwebp(_ img: UPImage, q: Double, lossless: Bool = false) -> Data? {
        guard let tool = cwebpPath, let png = UPLossless.safeEncode(img) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-webp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inURL = dir.appendingPathComponent("in.png"), outURL = dir.appendingPathComponent("out.webp")
        do { try png.write(to: inURL) } catch { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = lossless ? ["-quiet", "-lossless", "-z", "9", "-exact", inURL.path, "-o", outURL.path]
            : ["-quiet", "-q", String(format: "%.1f", q * 100), "-m", "6", "-sharp_yuv", "-alpha_q", "95", inURL.path, "-o", outURL.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? try? Data(contentsOf: outURL) : nil
    }

    static func decode(_ data: Data) -> UPImage? { UPBridge.decode(data)?.image }
}

struct WXAssistantOptions {
    var target: UPQualityTarget = .high
    var effort: UPEffort = .thorough
    var formats: [WXFormatKind] = WXFormatKind.allCases
    var matte: (UInt8, UInt8, UInt8) = (255, 255, 255)
    var importance = UPImportanceOptions()
    /// Soften non-salient background slightly before JPEG / AVIF / WebP coding ("smart blur background to save bytes").
    var smartBlur = false
    var maps: UPPerceptualMaps? = nil
}

enum WXAssistant {
    /// Smallest setting of a monotone quality knob that meets the target (7 probes).
    static func searchQuality(_ target: UPQualityTarget, ref: UPMetricReference, encode: (Double) -> Data?, progress: UPProgress? = nil) -> (data: Data, q: Double, quality: UPQuality, met: Bool, image: UPImage)? {
        var lo = 0.02, hi = 1.0
        var best: (Data, Double, UPQuality, UPImage)? = nil
        var top: (Data, Double, UPQuality, UPImage)? = nil
        for step in 0..<8 {
            if progress?.cancelled == true { return nil }
            let q = step == 0 ? 0.6 : (lo + hi) / 2
            guard let d = encode(q), let im = WXEncoders.decode(d), im.width == ref.w, im.height == ref.h else { lo = q; continue }
            let m = ref.compare(im)
            if top == nil || q > top!.1 { top = (d, q, m, im) }
            if target.met(by: m) { hi = q; if best == nil || d.count < best!.0.count { best = (d, q, m, im) } } else { lo = q }
            if hi - lo < 0.025 { break }
        }
        if let b = best { return (b.0, b.1, b.2, true, b.3) }
        // nothing met the target: report the best quality the format can do
        if let d = encode(1.0), let im = WXEncoders.decode(d) {
            let m = ref.compare(im)
            return (d, 1.0, m, target.met(by: m), im)
        }
        if let t = top { return (t.0, t.1, t.2, false, t.3) }
        return nil
    }

    /// Encodes `source` in every requested format at the same perceptual target. Smallest web-safe candidate first.
    static func run(_ source: UPImage, options o: WXAssistantOptions, progress: UPProgress? = nil) -> [WXCandidate] {
        let img = UPReduce.canonical(source.px16 == nil ? source : UPImage(width: source.width, height: source.height, px: source.px), keepHiddenRGB: false)
        let maps = o.maps ?? UPImportance.maps(img, options: o.importance)
        let ref = UPMetricReference(img, importance: maps.importance)
        let hasAlpha = img.hasAlpha
        let flat = WXEncoders.flatten(img, matte: o.matte)
        let refFlat = hasAlpha ? UPMetricReference(flat, importance: maps.importance) : ref
        let kinds = o.formats.filter { WXEncoders.available($0) && !($0 == .jpegMask && !hasAlpha) }
        let soft = o.smartBlur ? WXSmartBlur.apply(img, maps: maps, amount: 1) : img
        let softFlat = o.smartBlur ? WXEncoders.flatten(soft, matte: o.matte) : flat
        let out = UnsafeMutablePointer<WXCandidate?>.allocate(capacity: kinds.count)
        out.initialize(repeating: nil, count: kinds.count)
        defer { out.deinitialize(count: kinds.count); out.deallocate() }
        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: kinds.count) { i in
            if progress?.cancelled == true { return }
            let t0 = Date()
            let k = kinds[i]
            var c: WXCandidate? = nil
            switch k {
            case .ultraPNG:
                var lo = UPLossyOptions(); lo.target = o.target; lo.effort = o.effort; lo.maps = maps
                if let r = UPLossy.encode(img, options: lo, progress: progress?.child { _, _ in }) {
                    c = WXCandidate(kind: k, data: r.data, quality: r.mode == "lossless" ? UPQuality() : ref.compare(r.image),
                                    setting: r.mode == "palette" ? "\(r.colors) colours" : r.mode, targetMet: r.targetMet, lossless: r.mode == "lossless", decoded: r.image)
                }
            case .ultraPNGLossless:
                var lo = UPLosslessOptions(); lo.effort = o.effort
                if let r = UPLossless.encode(img, options: lo, progress: progress?.child { _, _ in }) {
                    c = WXCandidate(kind: k, data: r.data, setting: r.representation, lossless: true, decoded: img)
                }
            case .avif, .heic:
                let type = k == .avif ? "public.avif" : "public.heic"
                if let r = searchQuality(o.target, ref: ref, encode: { WXEncoders.imageIO(soft, type: type, q: $0) }, progress: progress) {
                    c = WXCandidate(kind: k, data: r.data, quality: r.quality, setting: String(format: "quality %.0f", r.q * 100), targetMet: r.met, decoded: r.image)
                }
            case .webp:
                let enc: (Double) -> Data? = WXEncoders.cwebpPath != nil ? { WXEncoders.cwebp(soft, q: $0) } : { WXEncoders.imageIO(soft, type: WXEncoders.webpType, q: $0) }
                if let r = searchQuality(o.target, ref: ref, encode: enc, progress: progress) {
                    c = WXCandidate(kind: k, data: r.data, quality: r.quality, setting: String(format: "quality %.0f%@", r.q * 100, WXEncoders.cwebpPath != nil ? " (cwebp)" : ""), targetMet: r.met, decoded: r.image)
                }
                // lossless WebP: for flat artwork it is often smaller than any lossy setting that keeps the edges clean
                if WXEncoders.cwebpPath != nil, let d = WXEncoders.cwebp(img, q: 1, lossless: true), let dec = WXEncoders.decode(d),
                   UPReduce.canonical(dec, keepHiddenRGB: false).visuallyIdentical(to: img), c == nil || !c!.targetMet || d.count < c!.data.count {
                    c = WXCandidate(kind: k, data: d, setting: "lossless (cwebp)", targetMet: true, lossless: true, decoded: img)
                }
            case .jpeg:
                if let r = WXJPEGSearch.best(softFlat, target: o.target, ref: refFlat, maps: maps, progress: progress) {
                    c = WXCandidate(kind: k, data: r.data, quality: r.quality, setting: r.setting + (hasAlpha ? ", flattened on matte" : ""), targetMet: r.met, decoded: r.image)
                }
            case .jpegMask:
                if let r = WXAlphaSplit.encode(img, target: o.target, ref: ref, maps: maps, effort: o.effort, progress: progress) { c = r }
            case .gif:
                if let r = WXGIF.encode(img, target: o.target, ref: ref, maps: maps) { c = r }
            }
            c?.seconds = Date().timeIntervalSince(t0)
            out[i] = c
            lock.lock(); done += 1; let d = done; lock.unlock()
            progress?.report(Double(d) / Double(kinds.count), "Encoding \(k.rawValue)")
        }
        var list = (0..<kinds.count).compactMap { out[$0] }
        list.sort { a, b in
            if a.targetMet != b.targetMet { return a.targetMet }
            return a.totalBytes < b.totalBytes
        }
        return list
    }

    /// The candidate to preselect: smallest that meets the target, is web-safe and keeps transparency when the image has any.
    static func winner(_ list: [WXCandidate], hasAlpha: Bool) -> WXCandidate? {
        list.first { $0.targetMet && $0.kind.webSafe && (!hasAlpha || $0.kind.supportsAlpha) } ?? list.first
    }
}

// MARK: - GIF

enum WXGIF {
    /// GIF through ImageIO from an Ultra-quantised image (binary alpha); colour count searched like PNG-8.
    static func encode(_ img: UPImage, target: UPQualityTarget, ref: UPMetricReference, maps: UPPerceptualMaps) -> WXCandidate? {
        // GIF has 1-bit alpha: threshold first
        var hard = img
        for i in stride(from: 3, to: hard.px.count, by: 4) { hard.px[i] = hard.px[i] >= 128 ? 255 : 0 }
        hard = UPReduce.canonical(hard, keepHiddenRGB: false)
        let ctx = UPQuantContext(hard, maps: maps)
        var best: (Data, UPQuality, Int, UPImage)? = nil
        var last: (Data, UPQuality, Int, UPImage)? = nil
        for k in [256, 128, 64, 32, 16] {
            let pal = ctx.cachedPalette(k)
            let ix = UPRemap.compact(UPRemap.remap(ctx, pal, UPDitherParams(strength: 0.7, lambda: 0, baseTolerance: 1)))
            let out = ix.image()
            guard let cg = UPBridge.cgImage(out), let d = UPBridge.encode(cg, type: "com.compuserve.gif", props: [:]), let dec = WXEncoders.decode(d) else { continue }
            let q = ref.compare(dec)
            if last == nil { last = (d, q, ix.palette.count, dec) }
            if target.met(by: q) { best = (d, q, ix.palette.count, dec) } else { break }
        }
        guard let r = best ?? last else { return nil }
        return WXCandidate(kind: .gif, data: r.0, quality: r.1, setting: "\(r.2) colours", targetMet: best != nil, decoded: r.3)
    }
}

// MARK: - smart background blur

enum WXSmartBlur {
    /// Blends a softened copy into the areas nobody looks at (importance → 0) and that are not edges of text / faces.
    /// `amount` 1 = up to σ 1.2 px in completely unimportant areas.
    static func apply(_ img: UPImage, maps: UPPerceptualMaps, amount: Float) -> UPImage {
        let w = img.width, h = img.height, n = w * h
        var ch = [[Float]](repeating: [Float](repeating: 0, count: n), count: 3)
        for i in 0..<n { for c in 0..<3 { ch[c][i] = Float(img.px[i * 4 + c]) } }
        let blurred = ch.map { UPFloatImage.blur($0, w, h, sigma: 1.2) }
        // smooth the blend mask so there is no visible seam
        var mask = [Float](repeating: 0, count: n)
        for i in 0..<n { mask[i] = maps.protect[i] > 0 ? 0 : max(0, 1 - maps.importance[i] * 2.2) }
        mask = UPFloatImage.blur(mask, w, h, sigma: 3)
        var out = img
        for i in 0..<n where img.px[i * 4 + 3] != 0 {
            let t = min(1, mask[i] * amount)
            if t <= 0.01 { continue }
            for c in 0..<3 { out.px[i * 4 + c] = UInt8(max(0, min(255, (ch[c][i] * (1 - t) + blurred[c][i] * t).rounded()))) }
        }
        return out
    }
}

// MARK: - colour + alpha mask

enum WXAlphaSplit {
    /// Colour as JPEG (edge colours bled under the transparent area so there is no halo and nothing to encode there)
    /// plus the alpha channel as a tiny grayscale PNG, to be recombined with CSS `mask-image` or an SVG `<mask>`.
    static func encode(_ img: UPImage, target: UPQualityTarget, ref: UPMetricReference, maps: UPPerceptualMaps, effort: UPEffort, progress: UPProgress? = nil) -> WXCandidate? {
        let w = img.width, h = img.height, n = w * h
        let color = bleed(img)
        // alpha mask: gray image, quantised perceptually (soft edges keep enough levels), lossless-packed
        var mask = UPImage(width: w, height: h, px: [UInt8](repeating: 255, count: n * 4))
        for i in 0..<n { let a = img.px[i * 4 + 3]; mask.px[i * 4] = a; mask.px[i * 4 + 1] = a; mask.px[i * 4 + 2] = a }
        var lo = UPLosslessOptions(); lo.effort = effort == .maximum ? .thorough : effort
        guard let maskPNG = UPLossless.encode(mask, options: lo) else { return nil }
        // quality is judged on the recombined image
        func recombine(_ rgb: UPImage) -> UPImage {
            var out = rgb
            for i in 0..<n { out.px[i * 4 + 3] = img.px[i * 4 + 3] }
            return UPReduce.canonical(out, keepHiddenRGB: false)
        }
        var best: (Data, Double, UPQuality, UPImage, String)? = nil
        var lowQ = 0.05, hiQ = 1.0
        for step in 0..<7 {
            if progress?.cancelled == true { return nil }
            let q = step == 0 ? 0.6 : (lowQ + hiQ) / 2
            guard let d = WXJPEG.encode(color, quality: Int((q * 100).rounded()), subsampling: .s420, progressive: true), let dec = WXEncoders.decode(d) else { lowQ = q; continue }
            let im = recombine(dec)
            let m = ref.compare(im)
            if target.met(by: m) { hiQ = q; if best == nil || d.count < best!.0.count { best = (d, q, m, im, String(format: "quality %.0f + %d B mask", q * 100, maskPNG.data.count)) } } else { lowQ = q }
            if hiQ - lowQ < 0.03 { break }
        }
        guard let b = best else { return nil }
        return WXCandidate(kind: .jpegMask, data: b.0, extra: [("-mask.png", maskPNG.data)], quality: b.2, setting: b.4, targetMet: true, decoded: b.3)
    }

    /// Spreads the colour of visible pixels into the transparent area (a few dilate-and-average passes).
    static func bleed(_ img: UPImage) -> UPImage {
        let w = img.width, h = img.height, n = w * h
        var out = img
        var known = [Bool](repeating: false, count: n)
        for i in 0..<n { known[i] = img.px[i * 4 + 3] > 8 }
        var frontier = true
        var pass = 0
        while frontier && pass < 64 {
            frontier = false
            pass += 1
            var next = known
            for y in 0..<h {
                for x in 0..<w where !known[y * w + x] {
                    var r = 0, g = 0, b = 0, c = 0
                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, yy >= 0, xx < w, yy < h, known[yy * w + xx] else { continue }
                        let o = (yy * w + xx) * 4
                        r += Int(out.px[o]); g += Int(out.px[o + 1]); b += Int(out.px[o + 2]); c += 1
                    }
                    if c > 0 {
                        let o = (y * w + x) * 4
                        out.px[o] = UInt8(r / c); out.px[o + 1] = UInt8(g / c); out.px[o + 2] = UInt8(b / c)
                        next[y * w + x] = true
                        frontier = true
                    }
                }
            }
            known = next
        }
        // whatever is still unknown (far from any pixel) takes the average colour; everything becomes opaque
        var sr = 0, sg = 0, sb = 0, sc = 0
        for i in 0..<n where known[i] { sr += Int(out.px[i * 4]); sg += Int(out.px[i * 4 + 1]); sb += Int(out.px[i * 4 + 2]); sc += 1 }
        let avg = sc > 0 ? (UInt8(sr / sc), UInt8(sg / sc), UInt8(sb / sc)) : (UInt8(255), UInt8(255), UInt8(255))
        for i in 0..<n {
            if !known[i] { out.px[i * 4] = avg.0; out.px[i * 4 + 1] = avg.1; out.px[i * 4 + 2] = avg.2 }
            out.px[i * 4 + 3] = 255
        }
        return out
    }

    static func cssSnippet(name: String, width: Int, height: Int) -> String {
        """
        <!-- colour (JPEG) + alpha (PNG mask): transparency without PNG-24 weight -->
        <img src="\(name).jpg" width="\(width)" height="\(height)" alt=""
             style="-webkit-mask-image:url(\(name)-mask.png);mask-image:url(\(name)-mask.png);-webkit-mask-size:100% 100%;mask-size:100% 100%;mask-mode:luminance">

        <!-- the same as inline SVG (works where CSS masks do not) -->
        <svg viewBox="0 0 \(width) \(height)" width="\(width)" height="\(height)">
          <mask id="m-\(name)"><image href="\(name)-mask.png" width="\(width)" height="\(height)"/></mask>
          <image href="\(name).jpg" width="\(width)" height="\(height)" mask="url(#m-\(name))"/>
        </svg>
        """
    }
}

// MARK: - transfer size

struct WXTransferEstimate {
    var raw: Int
    /// `data:` URI length when inlined in HTML / CSS.
    var dataURI: Int
    /// What the server sends for the file itself with gzip / Brotli content-encoding (binary image formats barely shrink).
    var gzip: Int
    var brotli: Int
    /// What the inlined base64 text costs once the surrounding HTML / CSS is gzip'ed / Brotli'ed.
    var dataURIGzip: Int
    var dataURIBrotli: Int
}

enum WXTransfer {
    static func brotliSize(_ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        let cap = data.count + data.count / 8 + 1024
        var dst = [UInt8](repeating: 0, count: cap)
        let n = data.withUnsafeBytes { src -> Int in
            compression_encode_buffer(&dst, cap, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_BROTLI)
        }
        return n > 0 ? n : data.count
    }

    static func estimate(_ data: Data, mime: String) -> WXTransferEstimate {
        let b64 = data.base64EncodedData()
        let prefix = "data:\(mime);base64,".utf8.count
        return WXTransferEstimate(raw: data.count, dataURI: prefix + b64.count, gzip: min(data.count, UPZlib.gzipSize(data)), brotli: min(data.count, brotliSize(data)),
                                  dataURIGzip: UPZlib.gzipSize(b64) + prefix, dataURIBrotli: brotliSize(b64) + prefix)
    }

    static func bytes(_ n: Int) -> String {
        n < 1024 ? "\(n) B" : (n < 1024 * 1024 ? String(format: "%.1f KB", Double(n) / 1024) : String(format: "%.2f MB", Double(n) / 1048576))
    }
}

// MARK: - resampling and responsive sets

enum WXResample {
    /// High-quality downscale (Lanczos, premultiplied) to `width` × proportional height.
    static func scaled(_ img: UPImage, width: Int) -> UPImage {
        let w = max(1, min(img.width, width))
        if w == img.width { return img }
        let h = max(1, Int((Double(img.height) * Double(w) / Double(img.width)).rounded()))
        // premultiply
        var src = img.px
        let n = img.width * img.height
        for i in 0..<n {
            let a = Int(src[i * 4 + 3])
            if a != 255 { for c in 0..<3 { src[i * 4 + c] = UInt8((Int(src[i * 4 + c]) * a + 127) / 255) } }
        }
        var dst = [UInt8](repeating: 0, count: w * h * 4)
        src.withUnsafeMutableBufferPointer { sp in
            dst.withUnsafeMutableBufferPointer { dp in
                var sb = vImage_Buffer(data: sp.baseAddress, height: vImagePixelCount(img.height), width: vImagePixelCount(img.width), rowBytes: img.width * 4)
                var db = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                vImageScale_ARGB8888(&sb, &db, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        UPBridge.unpremultiply(&dst)
        return UPImage(width: w, height: h, px: dst)
    }
}

struct WXResponsiveOptions {
    /// CSS width the image is displayed at (the 1× width); nil = the document width is the largest variant.
    var displayWidth: Int? = nil
    var densities: [Int] = [1, 2]
    /// Extra width variants for `srcset` with `w` descriptors (fluid layouts).
    var widths: [Int] = []
    var formats: [WXFormatKind] = [.avif, .ultraPNG]
    var baseName = "image"
    var alt = ""
    var target: UPQualityTarget = .high
    var effort: UPEffort = .fast
}

struct WXResponsiveSet {
    var files: [(name: String, data: Data, width: Int, kind: WXFormatKind)]
    var html: String
    var totalBytes: Int { files.reduce(0) { $0 + $1.data.count } }
}

enum WXResponsive {
    /// Suggests a pixel width when the document is larger than it will ever be shown.
    static func downscaleSuggestion(sourceWidth: Int, displayWidth: Int, maxDensity: Int = 2) -> Int? {
        let need = displayWidth * maxDensity
        return sourceWidth > need + need / 10 ? need : nil
    }

    static func variantWidths(sourceWidth: Int, options o: WXResponsiveOptions) -> [Int] {
        var ws = Set<Int>()
        if let d = o.displayWidth { for k in o.densities { ws.insert(min(sourceWidth, d * k)) } }
        for w in o.widths { ws.insert(min(sourceWidth, w)) }
        if ws.isEmpty { ws.insert(sourceWidth) }
        return ws.sorted()
    }

    static func build(_ img: UPImage, options o: WXResponsiveOptions, progress: UPProgress? = nil) -> WXResponsiveSet {
        let widths = variantWidths(sourceWidth: img.width, options: o)
        var files: [(name: String, data: Data, width: Int, kind: WXFormatKind)] = []
        let kinds = o.formats.filter { WXEncoders.available($0) }
        for (wi, w) in widths.enumerated() {
            if progress?.cancelled == true { break }
            let scaled = WXResample.scaled(img, width: w)
            var ao = WXAssistantOptions()
            ao.target = o.target; ao.effort = o.effort; ao.formats = kinds
            let cands = WXAssistant.run(scaled, options: ao, progress: progress?.child { _, _ in })
            for k in kinds {
                guard let c = cands.first(where: { $0.kind == k }) else { continue }
                files.append(("\(o.baseName)-\(w).\(k.ext)", c.data, w, k))
                for e in c.extra { files.append(("\(o.baseName)-\(w)\(e.suffix)", e.data, w, k)) }
            }
            progress?.report(Double(wi + 1) / Double(widths.count), "Responsive set")
        }
        return WXResponsiveSet(files: files, html: pictureHTML(files: files.filter { !$0.name.hasSuffix("-mask.png") }, kinds: kinds, options: o, sourceWidth: img.width, sourceHeight: img.height))
    }

    /// `<picture>` with one `<source>` per modern format (best first) and an `<img>` fallback that every browser understands.
    static func pictureHTML(files: [(name: String, data: Data, width: Int, kind: WXFormatKind)], kinds: [WXFormatKind], options o: WXResponsiveOptions,
                            sourceWidth: Int, sourceHeight: Int) -> String {
        func srcset(_ k: WXFormatKind) -> String {
            let fs = files.filter { $0.kind == k }.sorted { $0.width < $1.width }
            if let d = o.displayWidth, o.widths.isEmpty {
                return fs.map { f in "\(f.name) \(max(1, Int((Double(f.width) / Double(d)).rounded())))x" }.joined(separator: ", ")
            }
            return fs.map { "\($0.name) \($0.width)w" }.joined(separator: ", ")
        }
        // modern formats first; the fallback is the most compatible one
        let order: [WXFormatKind] = [.avif, .webp, .ultraPNG, .ultraPNGLossless, .jpeg, .gif, .heic]
        let present = order.filter { k in kinds.contains(k) && files.contains { $0.kind == k } }
        let fallback = present.last { [.jpeg, .ultraPNG, .ultraPNGLossless, .gif].contains($0) } ?? present.last
        let dispW = o.displayWidth ?? sourceWidth
        let dispH = Int((Double(sourceHeight) * Double(dispW) / Double(sourceWidth)).rounded())
        let sizes = o.displayWidth == nil || !o.widths.isEmpty ? " sizes=\"(max-width: \(dispW)px) 100vw, \(dispW)px\"" : ""
        var s = "<picture>\n"
        for k in present where k != fallback { s += "  <source type=\"\(k.mime)\" srcset=\"\(srcset(k))\"\(sizes)>\n" }
        if let f = fallback {
            let fs = files.filter { $0.kind == f }.sorted { $0.width < $1.width }
            let src = fs.first { $0.width >= dispW }?.name ?? fs.last?.name ?? ""
            s += "  <img src=\"\(src)\" srcset=\"\(srcset(f))\"\(sizes) width=\"\(dispW)\" height=\"\(dispH)\" alt=\"\(o.alt)\" loading=\"lazy\" decoding=\"async\">\n"
        }
        s += "</picture>"
        return s
    }
}

// MARK: - "this image is a gradient"

struct WXGradientSuggestion {
    var css: String
    var description: String
    /// Largest per-channel deviation (8-bit levels) between the image and what the CSS would draw.
    var maxError: Double
}

enum WXGradientDetector {
    static func hex(_ c: SIMD3<Double>) -> String {
        String(format: "#%02x%02x%02x", Int(max(0, min(255, c.x.rounded()))), Int(max(0, min(255, c.y.rounded()))), Int(max(0, min(255, c.z.rounded()))))
    }

    /// Detects flat colour and (multi-stop) linear gradients in opaque images. Returns nil for everything else.
    static func detect(_ img: UPImage, tolerance: Double = 3.0) -> WXGradientSuggestion? {
        let w = img.width, h = img.height, n = w * h
        guard n >= 16, !img.hasAlpha else { return nil }
        // flat?
        var mean = SIMD3<Double>.zero
        for i in 0..<n { mean += SIMD3(Double(img.px[i * 4]), Double(img.px[i * 4 + 1]), Double(img.px[i * 4 + 2])) }
        mean /= Double(n)
        var maxDev = 0.0
        for i in 0..<n { for c in 0..<3 { maxDev = max(maxDev, abs(Double(img.px[i * 4 + c]) - mean[c])) } }
        if maxDev <= 1.5 {
            return WXGradientSuggestion(css: "background: \(hex(mean));", description: "The image is a single flat colour — no file needed.", maxError: maxDev)
        }
        guard w >= 8, h >= 8 else { return nil }
        // direction: least-squares plane per channel, combined (sign-aligned) over the channels
        let step = max(1, n / 40_000)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        var sxc = SIMD3<Double>.zero, syc = SIMD3<Double>.zero
        let cx = Double(w - 1) / 2, cy = Double(h - 1) / 2
        var i = 0
        while i < n {
            let x = Double(i % w) - cx, y = Double(i / w) - cy
            let c = SIMD3(Double(img.px[i * 4]), Double(img.px[i * 4 + 1]), Double(img.px[i * 4 + 2])) - mean
            sxx += x * x; syy += y * y; sxy += x * y
            sxc += c * x; syc += c * y
            i += step
        }
        let det = sxx * syy - sxy * sxy
        guard abs(det) > 1e-9 else { return nil }
        var gx = 0.0, gy = 0.0
        var strongest = 0.0
        var refDir = (0.0, 0.0)
        for c in 0..<3 {
            let bx = (sxc[c] * syy - syc[c] * sxy) / det, by = (syc[c] * sxx - sxc[c] * sxy) / det
            let m = bx * bx + by * by
            if m > strongest { strongest = m; refDir = (bx, by) }
        }
        for c in 0..<3 {
            let bx = (sxc[c] * syy - syc[c] * sxy) / det, by = (syc[c] * sxx - sxc[c] * sxy) / det
            let sgn = bx * refDir.0 + by * refDir.1 >= 0 ? 1.0 : -1.0
            gx += sgn * bx; gy += sgn * by
        }
        let len = (gx * gx + gy * gy).squareRoot()
        guard len > 1e-6 else { return nil }
        var dx = gx / len, dy = gy / len
        // snap to the common directions when close (CSS keywords compress the declaration too)
        let ang0 = atan2(dx, -dy) * 180 / .pi
        var ang = ang0 < 0 ? ang0 + 360 : ang0
        for snap in stride(from: 0.0, through: 360.0, by: 45.0) where abs(ang - snap) < 1.2 { ang = snap == 360 ? 0 : snap }
        dx = sin(ang * .pi / 180); dy = -cos(ang * .pi / 180)
        // CSS gradient line length for this box
        let L = abs(Double(w) * dx) + abs(Double(h) * dy)
        guard L > 1 else { return nil }
        let bins = min(512, max(16, Int(L)))
        var sum = [SIMD3<Double>](repeating: .zero, count: bins), cnt = [Double](repeating: 0, count: bins)
        func tOf(_ x: Int, _ y: Int) -> Double { ((Double(x) + 0.5 - Double(w) / 2) * dx + (Double(y) + 0.5 - Double(h) / 2) * dy) / L + 0.5 }
        for y in 0..<h {
            for x in 0..<w {
                let b = min(bins - 1, max(0, Int(tOf(x, y) * Double(bins))))
                let o = (y * w + x) * 4
                sum[b] += SIMD3(Double(img.px[o]), Double(img.px[o + 1]), Double(img.px[o + 2])); cnt[b] += 1
            }
        }
        var profile = [SIMD3<Double>](repeating: .zero, count: bins)
        var lastValid = -1
        for b in 0..<bins where cnt[b] > 0 {
            profile[b] = sum[b] / cnt[b]
            if lastValid < b - 1 { for k in (lastValid + 1)..<b { profile[k] = lastValid >= 0 ? profile[lastValid] : profile[b] } }
            lastValid = b
        }
        if lastValid < 0 { return nil }
        if lastValid < bins - 1 { for k in (lastValid + 1)..<bins { profile[k] = profile[lastValid] } }
        // simplify the profile into colour stops (Douglas–Peucker on the 3-channel curve)
        var keep = [Bool](repeating: false, count: bins)
        keep[0] = true; keep[bins - 1] = true
        func simplify(_ a: Int, _ b: Int) {
            guard b > a + 1 else { return }
            var worst = 0.0, wi = -1
            for k in (a + 1)..<b {
                let t = Double(k - a) / Double(b - a)
                let lin = profile[a] + (profile[b] - profile[a]) * t
                let d = profile[k] - lin
                let e = max(abs(d.x), abs(d.y), abs(d.z))
                if e > worst { worst = e; wi = k }
            }
            if worst > tolerance * 0.6, wi > 0 { keep[wi] = true; simplify(a, wi); simplify(wi, b) }
        }
        simplify(0, bins - 1)
        let stops = (0..<bins).filter { keep[$0] }
        guard stops.count <= 8 else { return nil }
        // verify: every pixel against the piecewise-linear gradient CSS would draw
        func colour(at t: Double) -> SIMD3<Double> {
            let p = max(0, min(Double(bins - 1), t * Double(bins) - 0.5))
            var k = 0
            while k + 1 < stops.count - 1 && Double(stops[k + 1]) < p { k += 1 }
            let a = stops[k], b = stops[min(stops.count - 1, k + 1)]
            if b == a { return profile[a] }
            let u = max(0, min(1, (p - Double(a)) / Double(b - a)))
            return profile[a] + (profile[b] - profile[a]) * u
        }
        var worst = 0.0
        var bad = 0
        for y in stride(from: 0, to: h, by: max(1, h / 300)) {
            for x in stride(from: 0, to: w, by: max(1, w / 300)) {
                let c = colour(at: tOf(x, y))
                let o = (y * w + x) * 4
                let e = max(abs(Double(img.px[o]) - c.x), abs(Double(img.px[o + 1]) - c.y), abs(Double(img.px[o + 2]) - c.z))
                worst = max(worst, e)
                if e > tolerance { bad += 1 }
            }
        }
        let samples = ((h + max(1, h / 300) - 1) / max(1, h / 300)) * ((w + max(1, w / 300) - 1) / max(1, w / 300))
        guard Double(bad) <= Double(samples) * 0.002, worst <= tolerance * 3 else { return nil }
        let dirText: String
        switch Int(ang.rounded()) {
        case 0: dirText = "to top"
        case 90: dirText = "to right"
        case 180: dirText = "to bottom"
        case 270: dirText = "to left"
        default: dirText = String(format: "%.0fdeg", ang)
        }
        let stopText = stops.map { s -> String in
            let pos = (Double(s) + 0.5) / Double(bins) * 100
            let edge = s == 0 || s == bins - 1
            return edge ? hex(profile[s]) : String(format: "%@ %.1f%%", hex(profile[s]), pos)
        }.joined(separator: ", ")
        let css = "background: linear-gradient(\(dirText), \(stopText));"
        return WXGradientSuggestion(css: css, description: "The image is a \(stops.count)-stop linear gradient — CSS can draw it in \(css.utf8.count) bytes instead of a file.", maxError: worst)
    }
}
