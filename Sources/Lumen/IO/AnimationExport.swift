import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

enum AnimationExportError: LocalizedError {
    case noFrames, gifFailed, videoFailed(String)
    var errorDescription: String? {
        switch self {
        case .noFrames: return "There is nothing to export."
        case .gifFailed: return "The GIF could not be written."
        case .videoFailed(let s): return "The video could not be written. \(s)"
        }
    }
}

/// Animated GIF and H.264 video export of the Timeline's frames.
enum AnimationExport {

    // MARK: GIF

    /// Writes an animated GIF. ImageIO's loop count is the total number of plays (it stores n-1 repeats in the
    /// NETSCAPE block): once → no loop block, 3 times → 3 (block value 2), forever → 0.
    static func writeGIF(_ st: DocumentState, to url: URL, background: RGBA? = nil) throws {
        let frames = Animation.renderFrames(st, background: background)
        guard !frames.isEmpty else { throw AnimationExportError.noFrames }
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw AnimationExportError.gifFailed
        }
        var gif: [CFString: Any] = [:]
        switch st.animationLoop {
        case .once: break
        case .three: gif[kCGImagePropertyGIFLoopCount] = 3
        case .forever: gif[kCGImagePropertyGIFLoopCount] = 0
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: gif] as CFDictionary)
        for (img, delay) in frames {
            let props: [CFString: Any] = [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ] as [CFString: Any]]
            CGImageDestinationAddImage(dest, img, props as CFDictionary)
        }
        if !CGImageDestinationFinalize(dest) { throw AnimationExportError.gifFailed }
    }

    // MARK: Video

    /// Writes an H.264 MP4 (or .mov by extension). Each frame lasts its delay (min 1/60 s; 0-delay frames get 1/30 s).
    /// Transparency is composited over `background` (white). Dimensions are rounded up to even numbers and capped at 4096.
    /// Blocks until the file is finished.
    static func writeVideo(_ st: DocumentState, to url: URL, background: RGBA = .white) throws {
        let frames = Animation.renderFrames(st, background: background)
        guard let first = frames.first else { throw AnimationExportError.noFrames }
        try? FileManager.default.removeItem(at: url)

        var w = Double(first.image.width), h = Double(first.image.height)
        let cap = 4096.0
        if max(w, h) > cap { let s = cap / max(w, h); w *= s; h *= s }
        let W = max(2, Int(w.rounded()) + Int(w.rounded()) % 2), H = max(2, Int(h.rounded()) + Int(h.rounded()) % 2)

        let fileType: AVFileType = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: fileType) } catch { throw AnimationExportError.videoFailed(error.localizedDescription) }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: W,
            AVVideoHeightKey: H,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, W * H * 8),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: W,
            kCVPixelBufferHeightKey as String: H,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        guard writer.canAdd(input) else { throw AnimationExportError.videoFailed("Unsupported settings.") }
        writer.add(input)
        guard writer.startWriting() else { throw AnimationExportError.videoFailed(writer.error?.localizedDescription ?? "") }
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 6000
        var t: Int64 = 0
        for (img, delay) in frames {
            guard let pb = makePixelBuffer(img, width: W, height: H, pool: adaptor.pixelBufferPool, background: background) else {
                writer.cancelWriting(); throw AnimationExportError.videoFailed("Pixel buffer allocation failed.")
            }
            var waited = 0
            while !input.isReadyForMoreMediaData && waited < 5000 { usleep(1000); waited += 1 }
            if !adaptor.append(pb, withPresentationTime: CMTime(value: t, timescale: timescale)) {
                let e = writer.error?.localizedDescription ?? ""
                writer.cancelWriting(); throw AnimationExportError.videoFailed(e)
            }
            let d = delay <= 0 ? 1.0 / 30 : max(1.0 / 60, delay)
            t += Int64((d * Double(timescale)).rounded())
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: t, timescale: timescale))
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        // Pump the main run loop while waiting in case the completion is delivered there.
        while sem.wait(timeout: .now() + 0.01) == .timedOut {
            if Thread.isMainThread { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        }
        if writer.status != .completed { throw AnimationExportError.videoFailed(writer.error?.localizedDescription ?? "") }
    }

    private static func makePixelBuffer(_ img: CGImage, width: Int, height: Int, pool: CVPixelBufferPool?, background: RGBA) -> CVPixelBuffer? {
        var pbOut: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) }
        if pbOut == nil {
            let attrs: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pbOut)
        }
        guard let pb = pbOut else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: sRGBSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pb
    }

    // MARK: UI

    static func exportGIFPanel() {
        guard let d = AppActions.doc else { return }
        TimelineController.shared.stop()
        let p = NSSavePanel()
        p.allowedContentTypes = [.gif]
        p.nameFieldStringValue = (d.name as NSString).deletingPathExtension + ".gif"
        p.canSelectHiddenExtension = true
        UIBlock.begin(p) { r in
            guard r == .OK, let url = p.url else { return }
            do { try writeGIF(d.state, to: url) } catch { AppActions.alert("Export failed.", error.localizedDescription) }
        }
    }

    static func exportVideoPanel() {
        guard let d = AppActions.doc else { return }
        TimelineController.shared.stop()
        let p = NSSavePanel()
        p.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        p.nameFieldStringValue = (d.name as NSString).deletingPathExtension + ".mp4"
        p.canSelectHiddenExtension = true
        UIBlock.begin(p) { r in
            guard r == .OK, let url = p.url else { return }
            AppModel.shared.setStatus("Rendering video…")
            do {
                try writeVideo(d.state, to: url)
                AppModel.shared.setStatus("Exported \(url.lastPathComponent)")
            } catch { AppModel.shared.setStatus(""); AppActions.alert("Export failed.", error.localizedDescription) }
        }
    }
}
