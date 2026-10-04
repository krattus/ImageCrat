import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

// MARK: - Engine

/// Pure keyframe evaluation and application on `DocumentState`.
enum VideoTimelineEngine {

    // MARK: Interpolation

    static func ease(_ u: Double) -> Double { u * u * (3 - 2 * u) }

    /// Value of a keyed property at time `t` (nil when there are no keys).
    static func value(_ keys: [Keyframe], at t: Double) -> KeyValue? {
        guard let first = keys.first else { return nil }
        if t <= first.time || keys.count == 1 { return first.value }
        guard let last = keys.last, t < last.time else { return keys.last!.value }
        for i in 0..<(keys.count - 1) where t >= keys[i].time && t < keys[i + 1].time {
            let a = keys[i], b = keys[i + 1]
            let span = b.time - a.time
            var u = span > 0 ? (t - a.time) / span : 1
            switch a.interpolation {
            case .hold: return a.value
            case .ease: u = ease(u)
            case .linear: break
            }
            return lerp(a.value, b.value, u)
        }
        return last.value
    }

    static func lerp(_ a: KeyValue, _ b: KeyValue, _ u: Double) -> KeyValue {
        switch (a, b) {
        case (.point(let p), .point(let q)):
            return .point(CGPoint(x: p.x + (q.x - p.x) * u, y: p.y + (q.y - p.y) * u))
        case (.number(let x), .number(let y)):
            return .number(x + (y - x) * u)
        case (.transform(let s0, let r0), .transform(let s1, let r1)):
            return .transform(scale: s0 + (s1 - s0) * u, rotation: r0 + (r1 - r0) * u)
        case (.style(let e0), .style(let e1)):
            return .style(lerpEffects(e0, e1, u))
        default:
            return u < 1 ? a : b
        }
    }

    /// Interpolates every numeric field of two layer styles (colours, sizes, opacities, angles…);
    /// switches and names hold the first style's value.
    static func lerpEffects(_ a: LayerEffects, _ b: LayerEffects, _ u: Double) -> LayerEffects {
        if u <= 0 || a == b { return a }
        if u >= 1 { return b }
        let enc = JSONEncoder()
        guard let da = try? enc.encode(a), let db = try? enc.encode(b),
              let ja = try? JSONSerialization.jsonObject(with: da), let jb = try? JSONSerialization.jsonObject(with: db) else { return a }
        let mixed = lerpJSON(ja, jb, u)
        guard let dm = try? JSONSerialization.data(withJSONObject: mixed), let r = try? JSONDecoder().decode(LayerEffects.self, from: dm) else { return a }
        return r
    }

    private static func lerpJSON(_ a: Any, _ b: Any, _ u: Double) -> Any {
        if let na = a as? NSNumber, let nb = b as? NSNumber {
            if CFGetTypeID(na) == CFBooleanGetTypeID() || CFGetTypeID(nb) == CFBooleanGetTypeID() { return na }
            return na.doubleValue + (nb.doubleValue - na.doubleValue) * u
        }
        if let da = a as? [String: Any], let db = b as? [String: Any] {
            var out = da
            for (k, v) in da { if let w = db[k] { out[k] = lerpJSON(v, w, u) } }
            return out
        }
        if let aa = a as? [Any], let ab = b as? [Any], aa.count == ab.count {
            return zip(aa, ab).map { lerpJSON($0, $1, u) }
        }
        return a
    }

    // MARK: Layer geometry

    /// Layer centre used by the Position property (invariant under the Transform property).
    static func center(_ l: Layer, state: DocumentState) -> CGPoint? {
        switch l.content {
        case .raster(let r): return CGPoint(x: Double(r.origin.x) + Double(r.buffer.width) / 2, y: Double(r.origin.y) + Double(r.buffer.height) / 2)
        case .text(let t): return Quad(rect: TextRenderer.localRect(t)).applying(TextRenderer.docTransform(t)).center
        case .shape(let s):
            let b = s.geometry.vectorPath.bounds
            let c = CGPoint(x: b.midX, y: b.midY).applying(s.transform)
            return s.perspective.map { $0.apply(c) } ?? c
        case .smartObject(let s): return s.quad.center
        case .group, .fill:
            guard let b = Compositor.shared.contentBounds(l, state: state), !b.isEmpty, l.isGroup else { return nil }
            return CGPoint(x: b.midX, y: b.midY)
        case .adjustment: return nil
        }
    }

    /// Current (scale, rotation°) of text, shape and smart object layers.
    static func transformValue(_ l: Layer) -> (Double, Double)? {
        func decompose(_ m: CGAffineTransform) -> (Double, Double) {
            (Double(hypot(m.a, m.b)), Double(atan2(m.b, m.a)) * 180 / .pi)
        }
        switch l.content {
        case .text(let t): return decompose(t.transform)
        case .shape(let s) where s.perspective == nil: return decompose(s.transform)
        case .smartObject(let s):
            let w = Double(s.source.size.width)
            let v = s.quad.tr - s.quad.tl
            guard w > 0 else { return nil }
            return (Double(hypot(v.x, v.y)) / w, Double(atan2(v.y, v.x)) * 180 / .pi)
        default: return nil
        }
    }

    static func currentValue(_ p: TrackProperty, _ l: Layer, state: DocumentState) -> KeyValue? {
        switch p {
        case .position: return center(l, state: state).map { .point($0) }
        case .opacity: return .number(l.opacity)
        case .style: return .style(l.effects)
        case .transform: return transformValue(l).map { .transform(scale: $0.0, rotation: $0.1) }
        }
    }

    static func supports(_ p: TrackProperty, _ l: Layer) -> Bool {
        switch p {
        case .position: return !l.isAdjustment && !l.isFill
        case .opacity: return true
        case .style: return !l.isAdjustment
        case .transform: return transformValue(l) != nil
        }
    }

    /// Sets a property on a layer (Transform acts about the layer centre, before Position).
    static func apply(_ p: TrackProperty, _ v: KeyValue, to l: inout Layer, state: DocumentState) {
        switch (p, v) {
        case (.opacity, .number(let o)): l.opacity = min(1, max(0, o))
        case (.style, .style(let fx)): l.effects = fx
        case (.position, .point(let target)):
            guard let c = center(l, state: state) else { return }
            let dx = Double(target.x - c.x), dy = Double(target.y - c.y)
            if abs(dx) > 0.001 || abs(dy) > 0.001 { l.translate(dx: dx, dy: dy) }
        case (.transform, .transform(let s1, let r1)):
            guard let (s0, r0) = transformValue(l), s0 > 1e-6, let c = center(l, state: state) else { return }
            let ds = max(1e-4, s1) / s0, dr = (r1 - r0) * .pi / 180
            if abs(ds - 1) < 1e-6 && abs(dr) < 1e-9 { return }
            let m = CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(scaleX: ds, y: ds))
                .concatenating(CGAffineTransform(rotationAngle: dr))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
            switch l.content {
            case .text(var t): t.transform = t.transform.concatenating(m); l.content = .text(t)
            case .shape(var s): s.transform = s.transform.concatenating(m); l.content = .shape(s)
            case .smartObject(var s):
                s.quad = s.quad.applying(m)
                s.warp = s.warp?.mapped { $0.applying(m) }
                l.content = .smartObject(s)
            default: break
            }
        default: break
        }
    }

    // MARK: Evaluation

    /// Applies every keyed property, duration-bar visibility and (optionally) video frames at time `t`.
    static func apply(at t: Double, to st: inout DocumentState, decodeVideo: Bool) {
        RecipeClock.time = t   // Time node of Recipe layers (Nodes module)
        guard let tl = st.videoTimeline else { return }
        let order: [TrackProperty] = [.transform, .position, .opacity, .style]
        for tr in tl.tracks {
            guard var l = st.layer(tr.layerID) else { continue }
            let before = l
            // duration bar: only enforced when the bar is trimmed / moved
            if tr.start > 0.0001 || tr.end < tl.duration - 0.0001 {
                l.isVisible = t >= tr.start - 1e-9 && t < tr.end - 1e-9
            }
            for p in order {
                if let v = value(tr.keys(p), at: t) { apply(p, v, to: &l, state: st) }
            }
            if decodeVideo, let clip = tr.video, case .smartObject(var so) = l.content {
                let local = min(max(0, t - tr.start), max(0, clip.length - 0.5 / max(1, clip.frameRate)))
                if let buf = VideoFrameCache.shared.frame(clip, at: clip.inPoint + local) {
                    if case .image(let old) = so.source, old === buf {} else {
                        so.source = .image(buf)
                        so.sourceRevision = SourceRevision.next()
                        l.content = .smartObject(so)
                    }
                }
            }
            if !same(before, l) { st.updateLayer(tr.layerID) { $0 = l } }
        }
    }

    private static func same(_ a: Layer, _ b: Layer) -> Bool {
        guard a.isVisible == b.isVisible, a.opacity == b.opacity, a.effects == b.effects else { return false }
        switch (a.content, b.content) {
        case (.raster(let x), .raster(let y)): return x.origin == y.origin && x.buffer === y.buffer
        case (.text(let x), .text(let y)): return x == y
        case (.shape(let x), .shape(let y)): return x == y
        case (.smartObject(let x), .smartObject(let y)):
            return x.quad == y.quad && x.sourceRevision == y.sourceRevision && x.warp == y.warp
        default: return false
        }
    }

    static func evaluated(_ st: DocumentState, at t: Double, decodeVideo: Bool = true) -> DocumentState {
        var s = st
        apply(at: t, to: &s, decodeVideo: decodeVideo)
        return s
    }

    // MARK: Conversion

    /// Frame animation → keyframes (hold interpolation keeps the frame-by-frame look).
    static func timeline(fromFrames st: DocumentState, frameRate: Double = 30) -> VideoTimeline {
        var tl = VideoTimeline()
        tl.frameRate = frameRate
        let frames = st.frames
        guard !frames.isEmpty else {
            tl.tracks = st.allLayers.map { LayerTrack(layerID: $0.id, duration: tl.duration) }
            return tl
        }
        var times: [Double] = []
        var t = 0.0
        for f in frames { times.append(t); t += max(1 / frameRate, f.delay) }
        tl.duration = max(1 / frameRate, t)
        let states = frames.map { Animation.applied($0, to: st) }
        for l in st.allLayers {
            var tr = LayerTrack(layerID: l.id, duration: tl.duration)
            var pos: [Keyframe] = [], op: [Keyframe] = []
            for (i, s) in states.enumerated() {
                guard let fl = s.layer(l.id) else { continue }
                if let c = center(fl, state: s) { pos.append(Keyframe(time: times[i], interpolation: .hold, value: .point(c))) }
                op.append(Keyframe(time: times[i], interpolation: .hold, value: .number(fl.isVisible ? fl.opacity : 0)))
            }
            if Set(pos.map { "\($0.value)" }).count > 1 { tr.setKeys(.position, pos) }
            if Set(op.map { "\($0.value)" }).count > 1 { tr.setKeys(.opacity, op) }
            tl.tracks.append(tr)
        }
        return tl
    }

    /// Video timeline → frame animation sampled at the timeline frame rate (at most `maxFrames`).
    static func frames(fromTimeline st: DocumentState, maxFrames: Int = 100) -> [AnimationFrame] {
        guard let tl = st.videoTimeline else { return [] }
        let n = tl.frameCount
        let step = max(1, Int(ceil(Double(n) / Double(maxFrames))))
        var out: [AnimationFrame] = []
        var i = 0
        while i < n {
            var s = evaluated(st, at: Double(i) / tl.frameRate, decodeVideo: false)
            s.frames = []
            var f = Animation.capture(s)
            f.delay = Double(step) / tl.frameRate
            out.append(f)
            i += step
        }
        return out
    }
}

// MARK: - Video frames

/// Decoded video frames (AVAssetImageGenerator), cached per clip and frame index.
final class VideoFrameCache {
    static let shared = VideoFrameCache()
    private var generators: [URL: AVAssetImageGenerator] = [:]
    private var cache: [String: PixelBuffer] = [:]
    private var order: [String] = []
    private let lock = NSLock()
    var limit = 90

    func frame(_ clip: VideoClip, at seconds: Double) -> PixelBuffer? {
        let fps = max(1, clip.frameRate)
        let idx = max(0, Int((seconds * fps).rounded(.down)))
        let key = "\(clip.url.path)#\(idx)"
        lock.lock()
        if let b = cache[key] { lock.unlock(); return b }
        let gen: AVAssetImageGenerator
        if let g = generators[clip.url] { gen = g } else {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
            g.appliesPreferredTrackTransform = true
            let tol = CMTime(seconds: 0.5 / fps, preferredTimescale: 60000)
            g.requestedTimeToleranceBefore = tol
            g.requestedTimeToleranceAfter = tol
            generators[clip.url] = g
            gen = g
        }
        lock.unlock()
        let time = CMTime(seconds: (Double(idx) + 0.5) / fps, preferredTimescale: 60000)
        let sem = DispatchSemaphore(value: 0)
        var result: CGImage?
        gen.generateCGImageAsynchronously(for: time) { img, _, _ in result = img; sem.signal() }
        _ = sem.wait(timeout: .now() + 10)
        guard let cg = result else { return nil }
        let buf = PixelBuffer(cgImage: cg)
        lock.lock()
        cache[key] = buf
        order.append(key)
        if order.count > limit { let k = order.removeFirst(); cache[k] = nil }
        lock.unlock()
        return buf
    }

    func clear() { lock.lock(); cache = [:]; order = []; generators = [:]; lock.unlock() }

    /// Duration, frame rate and display size of the first video track.
    static func probe(_ url: URL) async throws -> (duration: Double, fps: Double, size: CGSize) {
        let asset = AVURLAsset(url: url)
        let d = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoImportError.noVideoTrack }
        var fps = Double(try await track.load(.nominalFrameRate))
        if !(fps > 0) { fps = 30 }
        let size = try await track.load(.naturalSize)
        let t = try await track.load(.preferredTransform)
        let r = CGRect(origin: .zero, size: size).applying(t)
        return (d.seconds, fps, CGSize(width: abs(r.width), height: abs(r.height)))
    }

    /// Synchronous probe (blocks; used by the importer and tests).
    static func probeSync(_ url: URL) throws -> (duration: Double, fps: Double, size: CGSize) {
        let sem = DispatchSemaphore(value: 0)
        var out: Result<(duration: Double, fps: Double, size: CGSize), Error> = .failure(VideoImportError.noFrames)
        Task.detached {
            do { out = .success(try await probe(url)) } catch { out = .failure(error) }
            sem.signal()
        }
        while sem.wait(timeout: .now() + 0.01) == .timedOut {
            if Thread.isMainThread { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        }
        return try out.get()
    }
}

// MARK: - Render video / image sequence

enum VideoCodecChoice: String, CaseIterable, Identifiable {
    case h264 = "H.264", hevc = "HEVC (H.265)", prores = "Apple ProRes 422"
    case png = "PNG Sequence", jpeg = "JPEG Sequence", tiff = "TIFF Sequence"
    var id: String { rawValue }
    var isSequence: Bool { self == .png || self == .jpeg || self == .tiff }
    var fileExtension: String {
        switch self {
        case .h264, .hevc: return "mp4"
        case .prores: return "mov"
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tif"
        }
    }
    var avCodec: AVVideoCodecType {
        switch self { case .hevc: return .hevc; case .prores: return .proRes422; default: return .h264 }
    }
    var utType: UTType {
        switch self { case .png: return .png; case .jpeg: return .jpeg; case .tiff: return .tiff; default: return .mpeg4Movie }
    }
}

struct VideoRenderSettings {
    var codec: VideoCodecChoice = .h264
    var width: Int? = nil        // nil = document size
    var height: Int? = nil
    var frameRate: Double? = nil // nil = timeline rate
    var quality: Double = 0.8    // bit-rate scale / JPEG quality
    var startFrame = 0
    var endFrame: Int? = nil
    var background: RGBA = .black
}

enum VideoRenderer {
    /// Timeline used for rendering: the document's video timeline, or one converted from frame animation.
    static func timeline(for st: DocumentState) -> DocumentState {
        if st.videoTimeline != nil { return st }
        var s = st
        s.videoTimeline = VideoTimelineEngine.timeline(fromFrames: st)
        if let f = st.frames.first { Animation.apply(f, to: &s) }
        s.frames = []
        return s
    }

    /// A frame rate that is safe to divide by and to turn into a time scale (the Render Video field accepts any number).
    static func validFrameRate(_ fps: Double) -> Double { fps.isFinite ? min(max(fps, 1), 240) : 30 }

    static func frameImages(_ st0: DocumentState, settings: VideoRenderSettings, each: (Int, CGImage) throws -> Void) throws {
        let st = timeline(for: st0)
        guard let tl = st.videoTimeline else { return }
        let fps = VideoRenderer.validFrameRate(settings.frameRate ?? tl.frameRate)
        let n = max(1, Int((tl.duration * fps).rounded()))
        let end = min(n, settings.endFrame ?? n)
        for i in settings.startFrame..<max(settings.startFrame + 1, end) {
            let s = VideoTimelineEngine.evaluated(st, at: Double(i) / fps, decodeVideo: true)
            guard let cg = Compositor.shared.flatten(s, background: settings.background) else { continue }
            try each(i, cg)
        }
    }

    /// Numbered image files `<base>_0000.<ext>` in `folder`. Returns the written URLs.
    @discardableResult
    static func writeSequence(_ st: DocumentState, folder: URL, baseName: String, settings: VideoRenderSettings) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        try frameImages(st, settings: settings) { i, cg0 in
            var cg = cg0
            if let w = settings.width, let h = settings.height, w != cg.width || h != cg.height { cg = scaled(cg, w, h) ?? cg }
            let url = folder.appendingPathComponent(String(format: "%@_%04d.%@", baseName, i, settings.codec.fileExtension))
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, settings.codec.utType.identifier as CFString, 1, nil) else { throw DocumentIOError.encodeFailed }
            var props: [CFString: Any] = [:]
            if settings.codec == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = settings.quality }
            CGImageDestinationAddImage(dest, cg, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw DocumentIOError.encodeFailed }
            urls.append(url)
        }
        return urls
    }

    static func scaled(_ cg: CGImage, _ w: Int, _ h: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// H.264 / HEVC / ProRes movie through AVAssetWriter. Blocks until finished.
    static func writeMovie(_ st: DocumentState, to url: URL, settings: VideoRenderSettings, progress: ((Int, Int) -> Void)? = nil) throws {
        let s0 = timeline(for: st)
        guard let tl = s0.videoTimeline else { throw AnimationExportError.noFrames }
        let fps = VideoRenderer.validFrameRate(settings.frameRate ?? tl.frameRate)
        var W = settings.width ?? st.width, H = settings.height ?? st.height
        let cap = settings.codec == .h264 ? 4096 : 8192
        if max(W, H) > cap { let k = Double(cap) / Double(max(W, H)); W = Int(Double(W) * k); H = Int(Double(H) * k) }
        W += W % 2; H += H % 2
        W = max(2, W); H = max(2, H)
        try? FileManager.default.removeItem(at: url)
        let type: AVFileType = settings.codec == .prores || url.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: type) } catch { throw AnimationExportError.videoFailed(error.localizedDescription) }
        var out: [String: Any] = [AVVideoCodecKey: settings.codec.avCodec, AVVideoWidthKey: W, AVVideoHeightKey: H]
        if settings.codec != .prores {
            out[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: max(1_000_000, Int(Double(W * H) * fps * 0.25 * max(0.1, settings.quality)))]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: out)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
        ])
        guard writer.canAdd(input) else { throw AnimationExportError.videoFailed("Unsupported codec settings.") }
        writer.add(input)
        guard writer.startWriting() else { throw AnimationExportError.videoFailed(writer.error?.localizedDescription ?? "") }
        writer.startSession(atSourceTime: .zero)
        let timescale = CMTimeScale(max(600, Int(fps * 100)))
        var count = 0
        let total = max(1, Int((tl.duration * fps).rounded()))
        try frameImages(s0, settings: settings) { i, cg in
            guard let pb = pixelBuffer(cg, W, H, adaptor.pixelBufferPool, settings.background) else { throw AnimationExportError.videoFailed("Pixel buffer allocation failed.") }
            var waited = 0
            while !input.isReadyForMoreMediaData && waited < 10000 { usleep(1000); waited += 1 }
            let pts = CMTime(value: CMTimeValue((Double(i - settings.startFrame) / fps * Double(timescale)).rounded()), timescale: timescale)
            if !adaptor.append(pb, withPresentationTime: pts) { throw AnimationExportError.videoFailed(writer.error?.localizedDescription ?? "append failed") }
            count += 1
            progress?(count, total)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue((Double(count) / fps * Double(timescale)).rounded()), timescale: timescale))
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        while sem.wait(timeout: .now() + 0.01) == .timedOut {
            if Thread.isMainThread { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        }
        if writer.status != .completed { throw AnimationExportError.videoFailed(writer.error?.localizedDescription ?? "") }
    }

    private static func pixelBuffer(_ img: CGImage, _ w: Int, _ h: Int, _ pool: CVPixelBufferPool?, _ bg: RGBA) -> CVPixelBuffer? {
        var pbOut: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) }
        if pbOut == nil { CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pbOut) }
        guard let pb = pbOut else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: sRGBSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(bg.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pb
    }
}
