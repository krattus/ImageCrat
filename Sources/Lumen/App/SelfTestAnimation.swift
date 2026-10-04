import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

extension SelfTest {
    /// Timeline: frames, tween, frame sync, GIF/MP4 export + re-read, video import, print-to-PDF.
    static func runAnimationTests(_ out: URL) {
        func check(_ ok: Bool, _ msg: String) { print(ok ? "ok   anim: \(msg)" : "FAIL anim: \(msg)") }

        // Document: gradient background + red rounded rect (shape) + blue circle (raster)
        var st = baseState(240, 160)
        var red = shapeLayer(CGRect(x: 10, y: 50, width: 60, height: 60), RGBA(hex: "E94F37")!, radius: 12)
        red.name = "Red"
        let circle = PixelBuffer(width: 50, height: 50)
        circle.context.setFillColor(RGBA(hex: "2E86DE")!.cgColor)
        circle.context.fillEllipse(in: CGRect(x: 0, y: 0, width: 50, height: 50))
        circle.markDirty()
        let blue = Layer.raster(name: "Blue", buffer: circle, origin: IPoint(x: 170, y: 10))
        st.layers += [red, blue]
        let doc = Document(state: st, name: "anim-test")
        AppModel.shared.add(doc)
        let tl = TimelineController.shared

        // Frame 1 = current state
        tl.createAnimation(doc)
        check(doc.state.frames.count == 1, "create animation")
        tl.setDelay(doc, index: 0, 0.2)
        // Frame 2: duplicate, then move red right / fade it, hide blue → synced into frame 2 by the commit hook
        tl.newFrame(doc)
        check(doc.state.frames.count == 2 && tl.selectedIndex(doc) == 1, "new frame selected")
        doc.updateLayer(red.id) { $0.translate(dx: 160, dy: 0); $0.opacity = 0.3 }
        doc.updateLayer(blue.id) { $0.isVisible = false }
        doc.commit("Move")
        let f2 = doc.state.frames[1]
        check(f2.opacities[red.id].map { abs($0 - 0.3) < 1e-6 } == true && f2.visibility[blue.id] == false, "commit hook synced frame 2")
        check(doc.state.frames[0].visibility[blue.id] == true && doc.state.frames[0].opacities[red.id] == 1, "frame 1 untouched")
        // Select frame 1 → layers restored
        tl.select(doc, 0)
        check(doc.state.layer(blue.id)?.isVisible == true && doc.state.layer(red.id)?.opacity == 1, "select frame 1 restores layers")
        let p1 = Animation.anchor(doc.state.layer(red.id)!)!
        tl.select(doc, 1)
        let p2 = Animation.anchor(doc.state.layer(red.id)!)!
        check(abs(p2.x - p1.x - 160) < 0.01, "select frame 2 moves layer (dx \(p2.x - p1.x))")
        // Undo the frame selection → resync follows the layers
        doc.undo(); tl.resync(doc)
        check(tl.selectedIndex(doc) == 0, "resync after undo selects frame 1")
        // Tween 3 frames between 1 and 2
        tl.select(doc, 0)
        tl.tween(doc, count: 3, withNext: true)
        check(doc.state.frames.count == 5, "tween inserted 3 frames (count \(doc.state.frames.count))")
        let xs = doc.state.frames.compactMap { $0.positions[red.id]?.x }
        let ops = doc.state.frames.compactMap { $0.opacities[red.id] }
        print("     tween red x: \(xs.map { String(format: "%.1f", $0) }) opacity: \(ops.map { String(format: "%.2f", $0) })")
        check(xs.count == 5 && abs(xs[2] - (xs[0] + xs[4]) / 2) < 0.01, "tween positions linear")
        let bops = doc.state.frames.map { ($0.visibility[blue.id] ?? true) ? ($0.opacities[blue.id] ?? 1) : 0 }
        print("     tween blue effective opacity: \(bops.map { String(format: "%.2f", $0) })")
        check(bops.count == 5 && bops[0] == 1 && bops[4] == 0 && bops[2] > 0.4 && bops[2] < 0.6, "tween fades hidden layer")
        tl.setDelayForAll(doc, 0.25)
        tl.setDelay(doc, index: 4, 1.0)
        tl.setLoop(doc, .forever)

        // Save/load round trip keeps frames
        let lumenURL = out.appendingPathComponent("anim_test.imagecrat")
        do {
            try DocumentIO.saveNative(doc, to: lumenURL)
            let re = try DocumentIO.load(url: lumenURL)
            check(re.state.frames == doc.state.frames && re.state.animationLoop == .forever, "native save/load keeps frames")
        } catch { check(false, "native save/load: \(error)") }

        // GIF export + re-read
        let gifURL = out.appendingPathComponent("anim_test.gif")
        do {
            try AnimationExport.writeGIF(doc.state, to: gifURL)
            if let src = CGImageSourceCreateWithURL(gifURL as CFURL, nil) {
                let n = CGImageSourceGetCount(src)
                var delays: [Double] = []
                for i in 0..<n {
                    let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
                    let g = p?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                    delays.append((g?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (g?[kCGImagePropertyGIFDelayTime] as? Double) ?? -1)
                    if [0, 2, 4].contains(i), let cg = CGImageSourceCreateImageAtIndex(src, i, nil) {
                        let png = out.appendingPathComponent("anim_gif_frame\(i).png")
                        if let d = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) {
                            CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
                        }
                    }
                }
                let fp = CGImageSourceCopyProperties(src, nil) as? [CFString: Any]
                let loop = (fp?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount]
                print("     gif frames: \(n) delays: \(delays) loop: \(String(describing: loop))")
                check(n == 5 && abs(delays[0] - 0.25) < 0.011 && abs(delays[4] - 1.0) < 0.011, "GIF frame count & delays")
                check((loop as? Int) == 0, "GIF loops forever")
            } else { check(false, "GIF unreadable") }
            // loop once / 3 times
            var s1 = doc.state; s1.animationLoop = .once
            let onceURL = out.appendingPathComponent("anim_test_once.gif")
            try AnimationExport.writeGIF(s1, to: onceURL)
            s1.animationLoop = .three
            let threeURL = out.appendingPathComponent("anim_test_three.gif")
            try AnimationExport.writeGIF(s1, to: threeURL)
            for (u, name) in [(onceURL, "once"), (threeURL, "three")] {
                let src = CGImageSourceCreateWithURL(u as CFURL, nil)
                let fp = src.flatMap { CGImageSourceCopyProperties($0, nil) } as? [CFString: Any]
                let loop = (fp?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount]
                let raw = (try? Data(contentsOf: u)) ?? Data()
                var block = "none"
                if let r = raw.range(of: Data("NETSCAPE2.0".utf8)), raw.count > r.upperBound + 3 {
                    block = "\(Int(raw[r.upperBound + 2]) | Int(raw[r.upperBound + 3]) << 8)"
                }
                print("     gif loop \(name): ImageIO \(String(describing: loop)), NETSCAPE repeats \(block)")
                check(name == "once" ? block == "none" : block == "2", "GIF loop \(name) encoded")
            }
        } catch { check(false, "GIF export: \(error)") }

        // MP4 export + re-read
        let mp4URL = out.appendingPathComponent("anim_test.mp4")
        do {
            try AnimationExport.writeVideo(doc.state, to: mp4URL)
            let expected = doc.state.frames.reduce(0) { $0 + $1.delay }
            var dur = -1.0, size = CGSize.zero, frames = 0
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                let asset = AVURLAsset(url: mp4URL)
                if let d = try? await asset.load(.duration) { dur = d.seconds }
                if let t = try? await asset.loadTracks(withMediaType: .video).first {
                    size = (try? await t.load(.naturalSize)) ?? .zero
                    // count samples
                    if let reader = try? AVAssetReader(asset: asset) {
                        let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
                        reader.add(o); reader.startReading()
                        while let sb = o.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(sb) > 0 { frames += 1 } }
                    }
                }
                sem.signal()
            }
            sem.wait()
            print("     mp4 duration: \(String(format: "%.3f", dur)) s (expected \(expected)) size: \(size) samples: \(frames)")
            check(abs(dur - expected) < 0.05, "MP4 duration honours delays")
            check(frames == 5 && size == CGSize(width: 240, height: 160), "MP4 frames & size")

            // Video import of the MP4 we just wrote (every frame of a variable-rate file ≈ nominal fps)
            var result: VideoImport.Result?
            let sem2 = DispatchSemaphore(value: 0)
            Task.detached {
                result = try? await VideoImport.extractFrames(url: mp4URL, everyNth: 1, maxFrames: 8)
                sem2.signal()
            }
            sem2.wait()
            if let r = result {
                let d2 = VideoImport.makeDocument(r, name: "import", makeAnimation: true)
                for i in [1, 5] where i < r.images.count {
                    let u = out.appendingPathComponent("anim_mp4_import_frame\(i).png")
                    if let dst = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil) { CGImageDestinationAddImage(dst, r.images[i], nil); CGImageDestinationFinalize(dst) }
                }
                print("     video import: \(r.images.count) frames, delay \(String(format: "%.3f", r.frameDelay)), layers \(d2.state.layers.count), anim frames \(d2.state.frames.count)")
                check(!r.images.isEmpty && d2.state.layers.count == r.images.count && d2.state.frames.count == r.images.count
                      && d2.state.width == 240, "video frames to layers")
                let visibleInFrame1 = d2.state.layers.filter { d2.state.frames[0].visibility[$0.id] == true }.count
                check(visibleInFrame1 == 1, "import animation shows one layer per frame")
            } else { check(false, "video import failed") }
        } catch { check(false, "MP4 export: \(error)") }

        // Make Frames From Layers
        do {
            var s = baseState(120, 80)
            for (i, c) in ["E94F37", "27AE60", "2E86DE"].enumerated() {
                s.layers.append(shapeLayer(CGRect(x: 10 + i * 35, y: 20, width: 30, height: 30), RGBA(hex: c)!, radius: 4))
            }
            let d = Document(state: s, name: "fl")
            tl.makeFramesFromLayers(d)
            let ok = d.state.frames.count == 3 && d.state.frames.allSatisfy { f in d.state.layers.dropFirst().filter { f.visibility[$0.id] == true }.count == 1 && f.visibility[d.state.layers[0].id] == true }
            check(ok, "make frames from layers (\(d.state.frames.count) frames)")
            if let cg = Compositor.shared.flatten(Animation.applied(d.state.frames[2], to: d.state)) {
                let u = out.appendingPathComponent("anim_fromlayers_frame3.png")
                if let dst = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil) { CGImageDestinationAddImage(dst, cg, nil); CGImageDestinationFinalize(dst) }
            }
        }

        // Print to PDF
        let pdfURL = out.appendingPathComponent("anim_print.pdf")
        try? FileManager.default.removeItem(at: pdfURL)
        let printed = Printing.writePDF(doc.state, to: pdfURL)
        let pdfSize = (try? FileManager.default.attributesOfItem(atPath: pdfURL.path)[.size] as? Int) ?? 0
        let pages = CGPDFDocument(pdfURL as CFURL)?.numberOfPages ?? 0
        check(printed && pdfSize > 1000 && pages == 1, "print to PDF (\(pdfSize) bytes, \(pages) page)")

        AppModel.shared.close(doc)
    }
}
