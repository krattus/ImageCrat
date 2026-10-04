import AppKit
import SwiftUI
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Observation
import ImageCratCore

// MARK: - Export options

struct TimelapseExportOptions: Equatable {
    enum Codec: String, CaseIterable, Identifiable { case h264 = "H.264", hevc = "HEVC"
        var id: String { rawValue }
        var av: AVVideoCodecType { self == .h264 ? .h264 : .hevc } }
    enum Length: String, CaseIterable, Identifiable { case s15 = "15 seconds", s30 = "30 seconds", s60 = "60 seconds", full = "Full length"
        var id: String { rawValue }
        var seconds: Double? { switch self { case .s15: return 15; case .s30: return 30; case .s60: return 60; case .full: return nil } } }
    enum Resolution: String, CaseIterable, Identifiable { case source = "As recorded", p720 = "720p", p1080 = "1080p", p2160 = "4K"
        var id: String { rawValue }
        /// Bounding box (long side, short side); nil = frame size.
        var box: (CGFloat, CGFloat)? { switch self { case .source: return nil; case .p720: return (1280, 720); case .p1080: return (1920, 1080); case .p2160: return (3840, 2160) } } }

    var codec: Codec = .h264
    var length: Length = .s30
    var resolution: Resolution = .p1080
    var fps = 30
    /// Seconds the finished image stays on screen at the end.
    var holdFinal: Double = 2
    /// Fade the held final image to black.
    var fadeOut = false
    /// Output frames per recorded frame for "Full length".
    var fullRepeat = 3
}

struct TimelapseExportResult: Equatable {
    var frames: Int
    var duration: Double
    var width: Int
    var height: Int
}

enum TimelapseError: LocalizedError {
    case noFrames, writer(String), cancelled
    var errorDescription: String? {
        switch self {
        case .noFrames: return "No timelapse frames have been recorded for this document yet."
        case .writer(let m): return "The video could not be written. \(m)"
        case .cancelled: return "Export cancelled."
        }
    }
}

// MARK: - Recorder

/// Procreate-style process recording: a downscaled composite is stored at history commits (rate limited, rendered and
/// written on a background queue) under `Timelapse/<document key>/`. The key is saved in the .lumen file so the recording
/// continues across sessions.
@Observable
final class Timelapse {
    static let shared = Timelapse()
    static let extrasKey = "workflow2.timelapse"

    /// Documents being recorded.
    private(set) var recording: Set<UUID> = []
    /// Frames on disk per document (for the status chip).
    private(set) var frameCounts: [UUID: Int] = [:]

    @ObservationIgnored private var keys: [UUID: String] = [:]
    @ObservationIgnored private var seen: Set<UUID> = []
    @ObservationIgnored private var lastCapture: [UUID: TimeInterval] = [:]
    @ObservationIgnored private var lastEntry: [UUID: UUID] = [:]
    @ObservationIgnored private var trailing: Set<UUID> = []
    @ObservationIgnored private let queue = DispatchQueue(label: "lumen.workflow2.timelapse", qos: .utility)
    @ObservationIgnored private lazy var context: CIContext = CIContext(mtlDevice: RenderEngine.device, options: [
        .workingColorSpace: sRGBSpace, .outputColorSpace: sRGBSpace, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false, .name: "LumenTimelapse"])

    // MARK: Keys & folders

    func key(_ d: Document) -> String {
        if let k = keys[d.id] { return k }
        keys[d.id] = d.id.uuidString
        return d.id.uuidString
    }

    static func folder(_ key: String) -> URL { Workflow2Paths.root.appendingPathComponent("Timelapse", isDirectory: true).appendingPathComponent(key, isDirectory: true) }
    func folder(_ d: Document) -> URL { Timelapse.folder(key(d)) }

    /// Frame files of a recording, oldest first (the folder listing is the index).
    static func frames(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func bytes(_ files: [URL]) -> Int {
        files.reduce(0) { $0 + (((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0) }
    }

    func frames(_ d: Document) -> [URL] { Timelapse.frames(in: folder(d)) }

    // MARK: Recording state

    func isRecording(_ d: Document?) -> Bool { d.map { recording.contains($0.id) } ?? false }

    func setRecording(_ d: Document, _ on: Bool, sync: Bool = false) {
        seen.insert(d.id)
        if on {
            guard !recording.contains(d.id) else { return }
            recording.insert(d.id)
            let dir = folder(d)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            writeMeta(d, saved: nil)
            frameCounts[d.id] = Timelapse.frames(in: dir).count
            capture(d, force: true, sync: sync)
        } else {
            recording.remove(d.id)
        }
    }

    func toggle(_ d: Document) {
        setRecording(d, !recording.contains(d.id))
        AppModel.shared.setStatus(recording.contains(d.id) ? "Recording a timelapse of “\(d.name)”." : "Timelapse recording paused.")
    }

    private struct Meta: Codable { var name = ""; var saved = false; var created = Date()
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
            saved = (try? c.decodeIfPresent(Bool.self, forKey: .saved)) ?? false
            created = (try? c.decodeIfPresent(Date.self, forKey: .created)) ?? Date()
        }
    }

    private func writeMeta(_ d: Document, saved: Bool?) {
        let url = folder(d).appendingPathComponent("meta.json")
        guard FileManager.default.fileExists(atPath: folder(d).path) else { return }
        var m = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) } ?? Meta()
        m.name = d.name
        if let s = saved { m.saved = m.saved || s }
        if let data = try? JSONEncoder().encode(m) { try? data.write(to: url, options: .atomic) }
    }

    /// Hook: a history step was recorded.
    func didCommit(_ d: Document) {
        if !seen.contains(d.id) {
            seen.insert(d.id)
            if Workflow2Settings.shared.prefs.timelapseAuto, d.smartParent == nil { setRecording(d, true) }
        }
        capture(d)
    }

    // MARK: Capture

    /// Stores a frame of the committed state. Skips when nothing changed, or (unless `force`) when the last frame is
    /// younger than the minimum interval. The composite graph is built here; rendering and writing happen on the queue.
    func capture(_ d: Document, force: Bool = false, sync: Bool = false) {
        guard recording.contains(d.id), d.history.indices.contains(d.historyIndex) else { return }
        let entry = d.history[d.historyIndex].id
        if lastEntry[d.id] == entry { return }
        let prefs = Workflow2Settings.shared.prefs
        let now = ProcessInfo.processInfo.systemUptime
        if !force, let t = lastCapture[d.id], now - t < prefs.timelapseMinInterval {
            // too soon: make sure the state the user stops on is still recorded once the interval has passed
            if !trailing.contains(d.id) {
                trailing.insert(d.id)
                let id = d.id
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0.2, prefs.timelapseMinInterval - (now - t)) + 0.05) { [weak self, weak d] in
                    self?.trailing.remove(id)
                    if let d { self?.capture(d) }
                }
            }
            return
        }
        lastCapture[d.id] = now
        lastEntry[d.id] = entry

        let st = d.committedState
        let sp = CanvasSpace(width: st.width, height: st.height)
        let maxDim = CGFloat(max(160, prefs.timelapseMaxDimension))
        let s = min(1, maxDim / CGFloat(max(st.width, st.height)))
        let w = max(2, Int((CGFloat(st.width) * s).rounded())), h = max(2, Int((CGFloat(st.height) * s).rounded()))
        let img = ImagingDisplay.inks(Compositor.shared.composite(st), state: st).composited(over: CIImage.color(.white, sp.ciCanvas)).cropped(to: sp.ciCanvas)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / CGFloat(st.width), y: CGFloat(h) / CGFloat(st.height)), highQualityDownsample: true)
        let dir = folder(d)
        let cap = max(1, prefs.timelapseCapMB) * 1_000_000
        let docID = d.id
        let ctx = context

        let work = { [weak self] in
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let cg = ctx.createCGImage(img, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: sRGBSpace) else { return }
            var files = Timelapse.frames(in: dir)
            let last = files.last.flatMap { Int($0.deletingPathExtension().lastPathComponent.dropFirst()) } ?? 0
            let url = dir.appendingPathComponent(String(format: "f%07d.jpg", last + 1))
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return }
            do { try (data as Data).write(to: url, options: .atomic) } catch { return }
            files.append(url)
            // size cap: thin the recording (drop every other frame, keep first and last) until it fits
            var guardN = 0
            while Timelapse.bytes(files) > cap, files.count > 2, guardN < 8 {
                var keep: [URL] = []
                for (i, f) in files.enumerated() {
                    if i == 0 || i == files.count - 1 || i % 2 == 0 { keep.append(f) } else { try? fm.removeItem(at: f) }
                }
                files = keep
                guardN += 1
            }
            let n = files.count
            let update: () -> Void = { self?.frameCounts[docID] = n }
            if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
        }
        if sync { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    /// Waits for frames still being written.
    func flush() { queue.sync {} }

    func deleteFrames(_ d: Document) {
        let dir = folder(d)
        queue.sync { try? FileManager.default.removeItem(at: dir) }
        frameCounts[d.id] = 0
        lastEntry[d.id] = nil
        if recording.contains(d.id) { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); writeMeta(d, saved: nil) }
    }

    func forget(_ docID: UUID) {
        recording.remove(docID); frameCounts[docID] = nil; keys[docID] = nil; seen.remove(docID); lastCapture[docID] = nil; lastEntry[docID] = nil; trailing.remove(docID)
    }

    var trackedDocuments: [UUID] { Array(Set(keys.keys).union(seen)) }

    /// Removes recordings of documents that were never saved (their key exists nowhere else) and are older than a week.
    static func pruneOrphans(olderThan days: Double = 7) {
        let root = Workflow2Paths.root.appendingPathComponent("Timelapse", isDirectory: true)
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let meta = (try? Data(contentsOf: dir.appendingPathComponent("meta.json"))).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
            guard meta?.saved != true else { continue }
            let newest = frames(in: dir).last.flatMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
                ?? ((try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date())
            if Date().timeIntervalSince(newest) > days * 86400 { try? fm.removeItem(at: dir) }
        }
    }

    // MARK: File side data

    private struct Extras: Codable { var key = ""; var recording = false
        init(key: String, recording: Bool) { self.key = key; self.recording = recording }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? ""
            recording = (try? c.decodeIfPresent(Bool.self, forKey: .recording)) ?? false
        }
    }

    /// Side data for the .lumen file: only documents that have a recording carry it.
    func encode(_ d: Document, markSaved: Bool) -> Data? {
        guard recording.contains(d.id) || (keys[d.id] != nil && FileManager.default.fileExists(atPath: folder(d).path)) else { return nil }
        if markSaved { writeMeta(d, saved: true) }
        return try? JSONEncoder().encode(Extras(key: key(d), recording: recording.contains(d.id)))
    }

    func decode(_ d: Document, _ data: Data) {
        guard let e = try? JSONDecoder().decode(Extras.self, from: data), !e.key.isEmpty, UUID(uuidString: e.key) != nil else { return }
        keys[d.id] = e.key
        seen.insert(d.id)
        frameCounts[d.id] = Timelapse.frames(in: Timelapse.folder(e.key)).count
        if e.recording { recording.insert(d.id) }
    }

    // MARK: Export

    /// Even output size for a frame of `size` under `resolution`.
    static func outputSize(for size: CGSize, _ resolution: TimelapseExportOptions.Resolution) -> (Int, Int) {
        var w = size.width, h = size.height
        if let (long, short) = resolution.box {
            let landscape = w >= h
            let s = min((landscape ? long : short) / w, (landscape ? short : long) / h)
            w *= s; h *= s
        }
        func even(_ v: CGFloat) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return (even(w), even(h))
    }

    /// Which recorded frame each output frame shows, plus the opacity of the fade (1 = fully visible).
    static func schedule(frameCount n: Int, options o: TimelapseExportOptions) -> [(source: Int, alpha: Double)] {
        guard n > 0 else { return [] }
        let content = o.length.seconds.map { max(1, Int(($0 * Double(o.fps)).rounded())) } ?? n * max(1, o.fullRepeat)
        var out: [(Int, Double)] = (0..<content).map { (min(n - 1, $0 * n / content), 1) }
        let hold = max(0, Int((o.holdFinal * Double(o.fps)).rounded()))
        let fade = o.fadeOut ? min(hold, max(1, o.fps / 2)) : 0
        for i in 0..<hold {
            let left = hold - i            // frames remaining including this one
            out.append((n - 1, left <= fade ? Double(left - 1) / Double(fade) : 1))
        }
        return out
    }

    /// Encodes `frames` into an MP4. Thread-safe; blocks until the file is complete. `progress` returns false to cancel.
    @discardableResult
    static func export(frames: [URL], to url: URL, options o: TimelapseExportOptions, progress: ((Double) -> Bool)? = nil) throws -> TimelapseExportResult {
        guard let lastURL = frames.last, let lastImg = loadFrame(lastURL) else { throw TimelapseError.noFrames }
        let (w, h) = outputSize(for: CGSize(width: lastImg.width, height: lastImg.height), o.resolution)
        let plan = schedule(frameCount: frames.count, options: o)
        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) } catch { throw TimelapseError.writer(error.localizedDescription) }
        let bitrate = Int(Double(w * h) * Double(o.fps) * (o.codec == .hevc ? 0.07 : 0.12))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: o.codec.av, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(400_000, bitrate)],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { throw TimelapseError.writer("Unsupported video settings.") }
        writer.add(input)
        guard writer.startWriting() else { throw TimelapseError.writer(writer.error?.localizedDescription ?? "") }
        writer.startSession(atSourceTime: .zero)

        var cachedIndex = -1
        var cached: CGImage? = nil
        let scale = CMTimeScale(o.fps)
        for (i, item) in plan.enumerated() {
            if let p = progress, i % 8 == 0, !p(Double(i) / Double(max(1, plan.count))) {
                input.markAsFinished(); writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                throw TimelapseError.cancelled
            }
            if item.source != cachedIndex { cached = loadFrame(frames[item.source]) ?? cached; cachedIndex = item.source }
            var waited = 0
            while !input.isReadyForMoreMediaData, waited < 4000 { Thread.sleep(forTimeInterval: 0.002); waited += 1 }
            guard let pool = adaptor.pixelBufferPool else { throw TimelapseError.writer("No pixel buffer pool.") }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut else { throw TimelapseError.writer("Out of memory.") }
            draw(cached, into: pb, width: w, height: h, alpha: item.alpha)
            if !adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: scale)) {
                throw TimelapseError.writer(writer.error?.localizedDescription ?? "append failed")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(plan.count), timescale: scale))
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { throw TimelapseError.writer(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)") }
        _ = progress?(1)
        return TimelapseExportResult(frames: plan.count, duration: Double(plan.count) / Double(o.fps), width: w, height: h)
    }

    static func loadFrame(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func draw(_ img: CGImage?, into pb: CVPixelBuffer, width w: Int, height h: Int, alpha: Double) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: sRGBSpace, bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img, alpha > 0 else { return }
        let s = min(CGFloat(w) / CGFloat(img.width), CGFloat(h) / CGFloat(img.height))
        let dw = CGFloat(img.width) * s, dh = CGFloat(img.height) * s
        ctx.interpolationQuality = .high
        ctx.setAlpha(CGFloat(min(1, alpha)))
        ctx.draw(img, in: CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh))
    }

    /// Exports the recording of `d` (captures the current state first so the video ends on the finished image).
    func export(_ d: Document, to url: URL, options: TimelapseExportOptions, progress: ((Double) -> Bool)? = nil) throws -> TimelapseExportResult {
        capture(d, force: true, sync: true)
        flush()
        return try Timelapse.export(frames: frames(d), to: url, options: options, progress: progress)
    }

    /// Reads a movie back: (number of video frames, duration in seconds). Used by the self test and the export summary.
    static func inspect(_ url: URL) -> (frames: Int, duration: Double)? {
        final class Box: @unchecked Sendable { var value: (Int, Double)? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            defer { sem.signal() }
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first, let duration = try? await asset.load(.duration),
                  let reader = try? AVAssetReader(asset: asset) else { return }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(out)
            guard reader.startReading() else { return }
            var n = 0
            while let s = out.copyNextSampleBuffer() { n += CMSampleBufferGetNumSamples(s) }
            box.value = (n, CMTimeGetSeconds(duration))
        }
        sem.wait()
        return box.value.map { (frames: $0.0, duration: $0.1) }
    }
}

// MARK: - UI

/// Status bar: recording indicator for the active document.
struct Workflow2StatusChip: View {
    @Bindable var app = AppModel.shared
    @Bindable var tl = Timelapse.shared
    /// Snapshot tests pass the document.
    var docOverride: Document? = nil

    var body: some View {
        if let d = docOverride ?? app.activeDocument, tl.recording.contains(d.id) {
            HStack(spacing: 4) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Menu {
                    Button("Pause Timelapse Recording") { tl.setRecording(d, false) }
                    Button("Export Timelapse Video…") { DialogRegistry.show("w2.timelapseExport") }
                    Divider()
                    Button("Delete Recorded Frames") { tl.deleteFrames(d) }
                } label: {
                    Text("REC \(tl.frameCounts[d.id] ?? 0)").font(Theme.fontSmall).monospacedDigit().foregroundStyle(Theme.text)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.red.opacity(0.14)))
            .overlay(Capsule().stroke(Color.red.opacity(0.6), lineWidth: 0.5))
            .help("Recording a process timelapse of this document (\(tl.frameCounts[d.id] ?? 0) frames)")
        }
    }
}

struct TimelapseExportDialog: View {
    @State private var o = TimelapseExportOptions()
    @State private var running = false
    @State private var progress = 0.0
    @State private var message = ""
    @Bindable var tl = Timelapse.shared
    var docOverride: Document? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export Timelapse Video").font(.system(size: 13, weight: .semibold))
            if let d = docOverride ?? AppActions.doc {
                let files = tl.frames(d)
                let n = max(tl.frameCounts[d.id] ?? 0, files.count)
                HStack(spacing: 8) {
                    Image(systemName: tl.isRecording(d) ? "record.circle.fill" : "record.circle").foregroundStyle(tl.isRecording(d) ? Color.red : Theme.textDim)
                    Text("\(n) frame\(n == 1 ? "" : "s") recorded · \(Workflow2Util.byteString(Timelapse.bytes(files)))").foregroundStyle(Theme.textDim)
                    Spacer()
                    Button(tl.isRecording(d) ? "Pause Recording" : "Start Recording") { tl.toggle(d) }.buttonStyle(PanelButtonStyle())
                }
                Picker("Length", selection: $o.length) { ForEach(TimelapseExportOptions.Length.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Resolution", selection: $o.resolution) { ForEach(TimelapseExportOptions.Resolution.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Format", selection: $o.codec) { ForEach(TimelapseExportOptions.Codec.allCases) { Text("MP4 (\($0.rawValue))").tag($0) } }
                ValueSlider(label: "Hold Final Image", value: $o.holdFinal, range: 0...10, step: 0.5, unit: " s", format: "%.1f", labelWidth: 110)
                Toggle2(label: "Fade out at the end", on: $o.fadeOut).disabled(o.holdFinal <= 0)
                let plan = Timelapse.schedule(frameCount: max(1, n), options: o)
                Text(n == 0 ? "Turn on recording (File ▸ Toggle Timelapse Recording) and keep working — a frame is stored as you edit."
                     : String(format: "Video: %.1f s at %d fps", Double(plan.count) / Double(o.fps), o.fps))
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
                if running { ProgressView(value: progress).controlSize(.small) }
                if !message.isEmpty { Text(message).font(Theme.fontSmall).foregroundStyle(Color.orange) }
                HStack {
                    Spacer()
                    Button("Close") { AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("Export…") { run(d) }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(n == 0 || running)
                }
            } else {
                Text("No document").foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(width: 380)
    }

    func run(_ d: Document) {
        let p = NSSavePanel()
        p.allowedContentTypes = [.mpeg4Movie]
        p.nameFieldStringValue = (d.name as NSString).deletingPathExtension + " timelapse.mp4"
        guard p.runModal() == .OK, let url = p.url else { return }
        AppActions.canvas?.commitCurrentTool()
        tl.capture(d, force: true, sync: true)
        tl.flush()
        let files = tl.frames(d), opts = o
        running = true; message = ""; progress = 0
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Timelapse.export(frames: files, to: url, options: opts) { v in DispatchQueue.main.async { progress = v }; return true } }
            DispatchQueue.main.async {
                running = false
                switch result {
                case .success(let r):
                    AppModel.shared.dialog = nil
                    AppModel.shared.setStatus(String(format: "Timelapse exported: %.1f s, %d×%d.", r.duration, r.width, r.height))
                case .failure(let e): message = e.localizedDescription
                }
            }
        }
    }
}
