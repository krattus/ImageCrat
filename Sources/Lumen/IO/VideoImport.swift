import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageCratCore

enum VideoImportError: LocalizedError {
    case noVideoTrack, noFrames
    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The file has no video track."
        case .noFrames: return "No frames could be read from the video."
        }
    }
}

/// File > Import > Video Frames to Layers…
enum VideoImport {
    struct Result {
        var images: [CGImage]
        /// Seconds between imported frames (source frame duration × N).
        var frameDelay: Double
    }

    /// Reads every `everyNth` frame (up to `maxFrames`) of the first video track.
    static func extractFrames(url: URL, everyNth: Int, maxFrames: Int) async throws -> Result {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoImportError.noVideoTrack }
        var fps = Double(try await track.load(.nominalFrameRate))
        if !(fps > 0) { fps = 30 }
        let step = max(1, everyNth)
        let total = max(1, Int((duration.seconds * fps).rounded(.down)))
        var times: [CMTime] = []
        var i = 0
        while i < total && times.count < max(1, maxFrames) {
            // sample in the middle of the frame interval so rounding never lands on the previous frame
            times.append(CMTime(seconds: (Double(i) + 0.5) / fps, preferredTimescale: 60000))
            i += step
        }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5 / fps, preferredTimescale: 60000)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5 / fps, preferredTimescale: 60000)
        var images: [CGImage] = []
        for t in times {
            if let (img, _) = try? await gen.image(at: t) { images.append(img) }
        }
        guard !images.isEmpty else { throw VideoImportError.noFrames }
        return Result(images: images, frameDelay: Double(step) / fps)
    }

    /// New document with one raster layer per frame (bottom = first frame). Optionally a frame animation
    /// showing one layer per frame.
    static func makeDocument(_ r: Result, name: String, makeAnimation: Bool) -> Document {
        let w = r.images[0].width, h = r.images[0].height
        var st = DocumentState(width: w, height: h)
        for (i, img) in r.images.enumerated() {
            var l = Layer.raster(name: "Frame \(i + 1)", buffer: PixelBuffer(cgImage: img))
            l.isVisible = !makeAnimation || i == 0
            st.layers.append(l)
        }
        if makeAnimation {
            var frames: [AnimationFrame] = []
            for i in st.layers.indices {
                var f = Animation.capture(st)
                f.delay = (r.frameDelay * 100).rounded() / 100
                for (j, l) in st.layers.enumerated() { f.visibility[l.id] = (i == j) }
                frames.append(f)
            }
            st.frames = frames
            st.animationLoop = .forever
        }
        let d = Document(state: st, name: name)
        d.activeLayerID = st.layers.last?.id
        if let a = d.activeLayerID { d.selectedLayerIDs = [a] }
        return d
    }

    // MARK: UI

    static func importPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
        p.message = "Choose a video to import as layers"
        guard UIBlock.run(p) == .OK, let url = p.url else { return }

        let a = NSAlert()
        a.messageText = "Import Video To Layers"
        a.informativeText = url.lastPathComponent
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 84))
        let l1 = NSTextField(labelWithString: "Every Nth frame:"); l1.frame = NSRect(x: 0, y: 60, width: 150, height: 18)
        let nth = NSTextField(string: "1"); nth.frame = NSRect(x: 160, y: 58, width: 60, height: 22)
        let l2 = NSTextField(labelWithString: "Limit to frames:"); l2.frame = NSRect(x: 0, y: 32, width: 150, height: 18)
        let maxF = NSTextField(string: "100"); maxF.frame = NSRect(x: 160, y: 30, width: 60, height: 22)
        let anim = NSButton(checkboxWithTitle: "Make Frame Animation", target: nil, action: nil)
        anim.frame = NSRect(x: 0, y: 2, width: 260, height: 20); anim.state = .on
        for s in [l1, nth, l2, maxF, anim] as [NSView] { v.addSubview(s) }
        a.accessoryView = v
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        guard UIBlock.run(a) == .alertFirstButtonReturn else { return }
        let n = max(1, Int(nth.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1)
        let m = max(1, min(2000, Int(maxF.stringValue.trimmingCharacters(in: .whitespaces)) ?? 100))
        let makeAnim = anim.state == .on
        let name = (url.lastPathComponent as NSString).deletingPathExtension
        AppModel.shared.setStatus("Importing video frames…")
        Task { @MainActor in
            do {
                let r = try await extractFrames(url: url, everyNth: n, maxFrames: m)
                let d = makeDocument(r, name: name, makeAnimation: makeAnim)
                AppModel.shared.add(d)
                if makeAnim {
                    TimelineController.shared.selection[d.id] = 0
                    TimelineController.shared.isPanelVisible = true
                }
                AppModel.shared.setStatus("Imported \(r.images.count) frames")
            } catch {
                AppModel.shared.setStatus("")
                AppActions.alert("Could not import “\(url.lastPathComponent)”.", error.localizedDescription)
            }
        }
    }
}
