import AppKit
import AVFoundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

/// Headless tests for the Files module (`LUMEN_SELFTEST_ONLY=files`).
enum FilesSelfTest {
    static var passed = 0, failed = 0

    static func check(_ ok: Bool, _ msg: String) {
        if ok { passed += 1; print("PASS files: \(msg)") } else { failed += 1; print("FAIL files: \(msg)") }
    }

    static func run(_ out: URL) {
        let dir = out.appendingPathComponent("files")
        let only = ProcessInfo.processInfo.environment["LUMEN_FILES_ONLY"]
        if only == nil { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func want(_ n: String) -> Bool { only == nil || only!.split(separator: ",").contains { n.hasPrefix($0) } }
        if want("psd") { testPSDPSB(dir) }
        if want("pdf") { testPDF(dir) }
        if want("layers") { testLayersToFiles(dir) }
        if want("web") { testSaveForWeb(dir) }
        if want("dicom") { testDICOM(dir) }
        if want("video") { testVideo(dir) }
        if want("droplet") { testDroplet(dir) }
        if want("processor") { testImageProcessor(dir) }
        if want("variables") { testVariables(dir) }
        if want("script") { testScripting(dir) }
        if only?.contains("ui") == true { testUI(dir) }
        print("files: \(passed) passed, \(failed) failed")
    }

    // MARK: Helpers

    static func sampleState(_ w: Int = 320, _ h: Int = 200) -> DocumentState {
        var st = SelfTest.baseState(w, h)
        st.layers.append(SelfTest.shapeLayer(CGRect(x: 30, y: 30, width: 120, height: 90), RGBA(hex: "E94F37")!, radius: 12))
        var t = TextContent()
        t.text = "Hello Lumen"
        t.fontSize = 32
        t.color = RGBA(hex: "1B1F3A")!
        t.position = CGPoint(x: 150, y: 120)
        st.layers.append(Layer(name: "Title", content: .text(t)))
        return st
    }

    static func diff(_ a: DocumentState, _ b: DocumentState) -> Double {
        guard let ia = Compositor.shared.flatten(a, background: .white), let ib = Compositor.shared.flatten(b, background: .white),
              ia.width == ib.width, ia.height == ib.height else { return 999 }
        let pa = PixelBuffer(cgImage: ia), pb = PixelBuffer(cgImage: ib)
        var total = 0.0
        let x = pa.data.assumingMemoryBound(to: UInt8.self), y = pb.data.assumingMemoryBound(to: UInt8.self)
        for r in 0..<pa.height { for c in 0..<(pa.width * 4) { total += abs(Double(x[r * pa.bytesPerRow + c]) - Double(y[r * pb.bytesPerRow + c])) } }
        return total / Double(pa.width * pa.height * 4)
    }

    static func imageSize(_ url: URL) -> (Int, Int)? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    static func writePNG(_ cg: CGImage, _ url: URL) {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
    }

    // MARK: PSD / PSB

    static func testPSDPSB(_ dir: URL) {
        var st = sampleState()
        // group with a masked raster child
        let buf = PixelBuffer(width: 80, height: 60)
        buf.context.setFillColor(RGBA(hex: "3BB273")!.cgColor); buf.context.fill(CGRect(x: 0, y: 0, width: 80, height: 60)); buf.markDirty()
        var child = Layer.raster(name: "Green", buffer: buf, origin: IPoint(x: 200, y: 20))
        child.mask = LayerMask(buffer: PixelBuffer(width: 40, height: 60, gray: 255), origin: IPoint(x: 200, y: 20), outsideValue: 0)
        child.opacity = 0.8
        st.layers.append(Layer(name: "Group", content: .group(GroupContent(children: [child]))))
        for large in [false, true] {
            let ext = large ? "psb" : "psd"
            let url = dir.appendingPathComponent("roundtrip.\(ext)")
            do {
                try PSDWriter.write(st, to: url, large: large)
                let data = try Data(contentsOf: url)
                check(data.count > 26 && data[4] == 0 && data[5] == (large ? 2 : 1), "\(ext) header version \(large ? 2 : 1)")
                // layer & mask section length: 8 bytes in PSB — must equal the bytes up to the merged image data
                var r = BinaryReader(data); r.pos = 26
                let cm = Int(try r.u32()); r.pos += cm   // color mode data
                let rs = Int(try r.u32()); r.pos += rs   // image resources
                let lmi = try r.len(large: large)
                let lmiStart = r.pos
                let li = try r.len(large: large)
                check(li > 0 && li <= lmi && lmiStart + lmi < data.count, "\(ext) layer/mask section length (\(large ? 8 : 4)-byte) consistent (\(lmi) bytes)")
                let back = try PSDReader.read(url: url)
                let names = back.allLayers.map(\.name)
                check(names == ["Background", "Shape", "Title", "Group", "Green"], "\(ext) layer tree \(names)")
                check(back.layer(back.allLayers.last!.id)?.mask != nil, "\(ext) layer mask survives")
                let dd = diff(st, back)
                check(dd < 3, String(format: "\(ext) composite matches (mean diff %.2f)", dd))
                if let cg = Compositor.shared.flatten(back, background: .white) { writePNG(cg, dir.appendingPathComponent("\(ext)_roundtrip.png")) }
                // through DocumentIO (extension routing)
                let d = try DocumentIO.load(url: url)
                check(d.state.allLayers.count == 5, "\(ext) opens through DocumentIO")
            } catch { check(false, "\(ext) round trip threw \(error)") }
        }
        var huge = DocumentState(width: 40000, height: 100)
        huge.layers = []
        check(PSBSupport.needsPSB(huge), "PSD > 30000 px suggests PSB")
        check(!PSBSupport.needsPSB(st), "small document stays PSD")
        // headless Save As .psd of an oversized document writes .psb instead (pixel data kept tiny)
        var tall = DocumentState(width: 30001, height: 2)
        tall.layers = [Layer.raster(name: "Background", buffer: PixelBuffer(width: 30001, height: 2))]
        let doc = Document(state: tall, name: "tall")
        do {
            try PSBSupport.save(doc, to: dir.appendingPathComponent("tall.psd"), large: false)
            let u = dir.appendingPathComponent("tall.psb")
            let back = try PSDReader.read(url: u)
            check(back.width == 30001, "oversized PSD saved as PSB and reads back")
        } catch { check(false, "oversized save threw \(error)") }
    }

    // MARK: PDF

    static func testPDF(_ dir: URL) {
        // single page with vector text + shape
        let st = sampleState()
        let url1 = dir.appendingPathComponent("single.pdf")
        do {
            try PDFExport.write(st, to: url1)
            let pdf = PDFDocument(url: url1)
            check(pdf?.pageCount == 1, "PDF single page")
            let text = pdf?.page(at: 0)?.string ?? ""
            check(text.contains("Hello Lumen"), "PDF text is live vector text (extracted “\(text.trimmingCharacters(in: .whitespacesAndNewlines))”)")
            if let p = pdf?.page(at: 0), let cg = PDFImport.rasterize(p, resolution: 144, white: true) { writePNG(cg, dir.appendingPathComponent("pdf_single_page.png")) }
            // rasterized-only version has no text
            try PDFExport.write(st, to: dir.appendingPathComponent("flat.pdf"), options: .init(preserveVector: false))
            check((PDFDocument(url: dir.appendingPathComponent("flat.pdf"))?.page(at: 0)?.string ?? "").isEmpty, "PDF without vector data has no text")
        } catch { check(false, "PDF export threw \(error)") }

        // artboards → pages
        var ab = DocumentState(width: 900, height: 400)
        for i in 0..<3 {
            var t = TextContent(); t.text = "Artboard page \(i + 1)"; t.fontSize = 28; t.position = CGPoint(x: CGFloat(i * 300 + 20), y: 40)
            let children = [SelfTest.shapeLayer(CGRect(x: CGFloat(i * 300 + 20), y: 120, width: 200, height: 150), [RGBA(hex: "E94F37")!, RGBA(hex: "2E86AB")!, RGBA(hex: "3BB273")!][i]),
                            Layer(name: "Text \(i + 1)", content: .text(t))]
            ab.layers.append(Layer(name: "Artboard \(i + 1)", content: .group(GroupContent(children: children, artboard: Artboard(rect: CGRect(x: i * 300, y: 0, width: 280, height: 400))))))
        }
        let url2 = dir.appendingPathComponent("artboards.pdf")
        do {
            try PDFExport.write(ab, to: url2)
            let pdf = PDFDocument(url: url2)
            check(pdf?.pageCount == 3, "PDF one page per artboard (\(pdf?.pageCount ?? 0))")
            check(pdf?.page(at: 1)?.string?.contains("Artboard page 2") == true, "PDF artboard page 2 text")
            if let p = pdf?.page(at: 2), let cg = PDFImport.rasterize(p, resolution: 72, white: true) { writePNG(cg, dir.appendingPathComponent("pdf_artboard3.png")) }
        } catch { check(false, "artboard PDF threw \(error)") }

        // import
        do {
            let docs = try PDFImport.documents(url: url2, settings: .init(pages: [0, 2], resolution: 144))
            check(docs.count == 2, "PDF import two selected pages")
            check(docs.first.map { $0.state.width == 560 && $0.state.height == 800 } ?? false, "PDF import at 144 ppi → 560×800 (\(docs.first?.state.width ?? 0)×\(docs.first?.state.height ?? 0))")
            if let d = docs.last, let cg = Compositor.shared.flatten(d.state, background: .white) { writePNG(cg, dir.appendingPathComponent("pdf_import_page3.png")) }
            // loader hook (headless: page 1)
            let d = try DocumentIO.load(url: url1)
            check(d.state.layers.count == 1 && d.state.width > 0, "PDF opens through File > Open hook")
        } catch { check(false, "PDF import threw \(error)") }

        // presentation
        do {
            let imgs = [Compositor.shared.flatten(st, background: .white)!, Compositor.shared.flatten(ab, background: .white)!]
            let u = dir.appendingPathComponent("presentation.pdf")
            try PDFExport.writePresentation(imgs.enumerated().map { ($0.element, "img\($0.offset).png", 72.0) }, to: u, options: .init(includeFilename: true))
            let pdf = PDFDocument(url: u)
            check(pdf?.pageCount == 2 && (pdf?.page(at: 1)?.string?.contains("img1.png") ?? false), "PDF Presentation 2 pages with captions")
        } catch { check(false, "presentation threw \(error)") }
    }

    // MARK: Layers to Files

    static func testLayersToFiles(_ dir: URL) {
        var st = sampleState()
        var hidden = SelfTest.shapeLayer(CGRect(x: 10, y: 10, width: 20, height: 20))
        hidden.name = "Hidden"; hidden.isVisible = false
        st.layers.append(hidden)
        let folder = dir.appendingPathComponent("layers")
        do {
            let urls = try LayersToFiles.export(st, options: .init(folder: folder, prefix: "L", format: .png, visibleOnly: true, trim: true))
            check(urls.count == 3, "Layers to Files: 3 visible layers → \(urls.count) files")
            let shape = urls.first { $0.lastPathComponent.contains("Shape") }
            let sz = shape.flatMap(imageSize)
            check(sz.map { $0.0 >= 120 && $0.0 <= 126 && $0.1 >= 90 && $0.1 <= 96 } ?? false, "trimmed shape file ≈120×90 (\(sz.map { "\($0.0)×\($0.1)" } ?? "?"))")
            let all = try LayersToFiles.export(st, options: .init(folder: dir.appendingPathComponent("layers_all"), prefix: "L", format: .jpeg, visibleOnly: false))
            check(all.count == 4 && imageSize(all[0]).map { $0 == (320, 200) } == true, "all layers untrimmed as JPEG (\(all.count))")
        } catch { check(false, "layers to files threw \(error)") }
    }

    // MARK: Save for Web

    static func testSaveForWeb(_ dir: URL) {
        guard let cg = Compositor.shared.flatten(sampleState()) else { return }
        var sizes: [String: Int] = [:]
        for f in WebFormat.available {
            var s = WebSettings(format: f, quality: 60, colors: 16)
            s.dither = f == .gif
            guard let r = WebEncoder.encode(cg, s, metadata: .copyright, copyright: "© Lumen") else { check(false, "encode \(f.rawValue)"); continue }
            sizes[f.rawValue] = r.data.count
            try? r.data.write(to: dir.appendingPathComponent("web_\(f.rawValue).\(f.ext)"))
            check(r.preview != nil, "Save for Web \(f.rawValue) decodes (\(WebEncoder.sizeLabel(r.data.count)))")
            if f == .png8, let p = r.preview {
                let (_, _, px) = WebQuantizer.pixels(p)
                var set = Set<UInt32>()
                for i in stride(from: 0, to: px.count, by: 4) { set.insert(UInt32(px[i]) << 24 | UInt32(px[i + 1]) << 16 | UInt32(px[i + 2]) << 8 | UInt32(px[i + 3])) }
                check(set.count <= 16, "PNG-8 has ≤16 colours (\(set.count))")
            }
        }
        check((sizes["JPEG"] ?? 0) > 0 && (sizes["PNG-24"] ?? 0) > (sizes["PNG-8"] ?? .max), "PNG-8 smaller than PNG-24 (\(sizes))")
        check(abs(WebEncoder.downloadTime(56_600 / 8, bitsPerSecond: 56_600) - 1) < 1e-9, "download time estimate")
    }

    // MARK: DICOM

    static func testDICOM(_ dir: URL) {
        let W = 64, H = 48
        // a) 8-bit MONOCHROME2, explicit VR
        var g8 = Data()
        for y in 0..<H { for x in 0..<W { g8.append(UInt8((x * 4 + y) & 255)) } }
        let u8 = dir.appendingPathComponent("mono8.dcm")
        // b) 16-bit signed, implicit VR, rescale intercept -1024 (CT-like)
        var g16 = Data()
        func hu(_ x: Int, _ y: Int) -> Int { let dx = x - W / 2, dy = y - H / 2; return dx * dx + dy * dy < 200 ? 800 : (x < W / 2 ? -1000 : 40) }
        for y in 0..<H { for x in 0..<W {
            let stored = Int16(hu(x, y) + 1024)
            let v = UInt16(bitPattern: stored)
            g16.append(UInt8(v & 255)); g16.append(UInt8(v >> 8))
        } }
        let u16 = dir.appendingPathComponent("ct16_implicit.dcm")
        // c) RGB
        var rgb = Data()
        for y in 0..<H { for x in 0..<W { rgb.append(UInt8(x * 4)); rgb.append(UInt8(y * 5)); rgb.append(128) } }
        let urgb = dir.appendingPathComponent("rgb.dcm")
        // d) multi-frame
        let frames = (0..<3).map { f -> Data in var d = Data(); for y in 0..<H { for x in 0..<W { d.append(UInt8(((x + f * 20) % W) * 4)); _ = y } }; return d }
        let umf = dir.appendingPathComponent("multiframe.dcm")
        // e) JPEG baseline encapsulated
        let ujp = dir.appendingPathComponent("jpeg.dcm")
        do {
            try DICOM.write(.init(rows: H, columns: W, frames: [g8], patientName: "Test^Eight"), to: u8)
            try DICOM.write(.init(rows: H, columns: W, bitsAllocated: 16, signed: true, frames: [g16], windowCenter: 40, windowWidth: 400,
                                  rescaleSlope: 1, rescaleIntercept: -1024, transferSyntax: DICOM.implicitLE, modality: "CT"), to: u16)
            try DICOM.write(.init(rows: H, columns: W, samples: 3, photometric: "RGB", frames: [rgb]), to: urgb)
            try DICOM.write(.init(rows: H, columns: W, frames: frames), to: umf)
            // JPEG fragment from ImageIO
            let gray = PixelBuffer(width: W, height: H)
            let gp = gray.data.assumingMemoryBound(to: UInt8.self)
            for y in 0..<H { for x in 0..<W { let v = UInt8(x * 4); let q = y * gray.bytesPerRow + x * 4; gp[q] = v; gp[q + 1] = v; gp[q + 2] = v; gp[q + 3] = 255 } }
            gray.markDirty()
            let jpeg = WebEncoder.imageIO(gray.makeCGImage(), type: UTType.jpeg.identifier, props: [kCGImageDestinationLossyCompressionQuality: 0.95])!
            try DICOM.write(.init(rows: H, columns: W, frames: [], transferSyntax: DICOM.jpegBaseline, jpegFragments: [jpeg]), to: ujp)
        } catch { check(false, "writing synthetic DICOM threw \(error)"); return }

        do {
            let a = try DICOM.read(url: u8)
            check(a.rows == H && a.columns == W && a.bitsAllocated == 8 && a.grayFrames.count == 1, "DICOM 8-bit header")
            check(a.grayFrames[0][5 * W + 10] == Float((10 * 4 + 5) & 255), "DICOM 8-bit pixel value")
            check(a.attributes.contains { $0.0 == "Patient Name" && $0.1 == "Test Eight" }, "DICOM patient name attribute")

            let b = try DICOM.read(url: u16)
            check(b.bitsAllocated == 16 && b.pixelRepresentation == 1 && b.transferSyntax == DICOM.implicitLE, "DICOM 16-bit signed implicit VR header")
            check(b.grayFrames[0][0] == -1000 && b.grayFrames[0][(H / 2) * W + W / 2] == 800 && b.grayFrames[0][W - 1] == 40, "DICOM rescale → HU values")
            check(b.windowCenter == 40 && b.windowWidth == 400, "DICOM window center/width tags")
            let soft = DICOM.render(b, frame: 0, center: 40, width: 400)
            let bone = DICOM.render(b, frame: 0, center: 800, width: 400)
            check(soft.pixel(W - 1, 0).0 == 128 || abs(Int(soft.pixel(W - 1, 0).0) - 128) <= 1, "window 40/400: 40 HU → mid gray (\(soft.pixel(W - 1, 0).0))")
            check(soft.pixel(0, 0).0 == 0 && soft.pixel(W / 2, H / 2).0 == 255, "window clips air to black, bone to white")
            check(bone.pixel(W - 1, 0).0 == 0, "window 800/400 hides soft tissue")
            writePNG(soft.makeCGImage(), dir.appendingPathComponent("dicom_ct_soft.png"))
            writePNG(bone.makeCGImage(), dir.appendingPathComponent("dicom_ct_bone.png"))

            let c = try DICOM.read(url: urgb)
            check(c.isColor && c.rgbFrames.count == 1, "DICOM RGB")
            let cr = DICOM.render(c, frame: 0, center: 0, width: 1)
            check(cr.pixel(10, 7) == (40, 35, 128, 255), "DICOM RGB pixel \(cr.pixel(10, 7))")

            let m = try DICOM.read(url: umf)
            check(m.frames == 3 && m.grayFrames.count == 3, "DICOM multi-frame (3)")
            let md = DICOM.makeDocument(m, name: "mf")
            check(md.state.layers.count == 3 && md.state.frames.count == 3, "multi-frame → 3 layers + frame animation")

            let j = try DICOM.read(url: ujp)
            let jv = j.grayFrames.first?[10 * W + 32] ?? -1
            check(abs(jv - 128) < 6, "DICOM JPEG baseline encapsulated decode (\(jv))")

            // Window/Level on an opened document
            let d = try DICOM.load(url: u16)
            DICOM.applyWindow(d, center: 800, width: 400)
            d.commit("Window/Level")
            if let l = d.state.layers.first?.raster { check(l.buffer.pixel(W - 1, 0).0 == 0, "Window/Level re-renders the document layers") }
            if let cg = Compositor.shared.flatten(d.state) { writePNG(cg, dir.appendingPathComponent("dicom_window_level_doc.png")) }

            // export round trip
            let e = dir.appendingPathComponent("export.dcm")
            var st = sampleState(); st.colorMode = .grayscale
            try DICOM.export(st, to: e)
            let back = try DICOM.read(url: e)
            check(back.rows == 200 && back.columns == 320 && !back.isColor, "DICOM export (grayscale 8-bit) reads back")
            check(DICOM.isDICOM(e), "exported file has DICM preamble")
        } catch { check(false, "DICOM read threw \(error)") }
    }

    // MARK: Video

    static func testVideo(_ dir: URL) {
        var st = SelfTest.baseState(320, 240)
        let shape = SelfTest.shapeLayer(CGRect(x: 20, y: 80, width: 80, height: 80), RGBA(hex: "E94F37")!, radius: 8)
        st.layers.append(shape)
        var tl = VideoTimeline(duration: 2, frameRate: 30)
        var tr = LayerTrack(layerID: shape.id, duration: 2)
        tr.setKeys(.position, [Keyframe(time: 0, value: .point(CGPoint(x: 60, y: 120))), Keyframe(time: 2, value: .point(CGPoint(x: 260, y: 120)))])
        tr.setKeys(.opacity, [Keyframe(time: 0, interpolation: .hold, value: .number(1)), Keyframe(time: 1.5, value: .number(0.4))])
        tr.setKeys(.transform, [Keyframe(time: 0, interpolation: .ease, value: .transform(scale: 1, rotation: 0)), Keyframe(time: 2, value: .transform(scale: 1.5, rotation: 90))])
        var fx0 = LayerEffects(); fx0.dropShadow.enabled = true; fx0.dropShadow.distance = 0; fx0.dropShadow.size = 0
        var fx1 = fx0; fx1.dropShadow.distance = 20; fx1.dropShadow.size = 10
        tr.setKeys(.style, [Keyframe(time: 0, value: .style(fx0)), Keyframe(time: 2, value: .style(fx1))])
        tl.tracks = [tr]
        st.videoTimeline = tl

        let mid = VideoTimelineEngine.evaluated(st, at: 1, decodeVideo: false)
        let ml = mid.layer(shape.id)!
        let c = VideoTimelineEngine.center(ml, state: mid)!
        check(abs(c.x - 160) < 0.6 && abs(c.y - 120) < 0.6, "linear position at 1 s → (160,120) got \(c)")
        check(abs(ml.opacity - 1) < 1e-9, "hold opacity stays 1 before next key")
        let t1 = VideoTimelineEngine.transformValue(ml)!
        check(abs(t1.1 - 45) < 0.01 && abs(t1.0 - 1.25) < 0.001, "ease transform at midpoint (scale 1.25, 45°) got \(t1)")
        let e1 = VideoTimelineEngine.evaluated(st, at: 0.5, decodeVideo: false).layer(shape.id)!
        let rot = VideoTimelineEngine.transformValue(e1)!.1
        check(abs(rot - 90 * VideoTimelineEngine.ease(0.25)) < 0.01, "ease curve at 0.25 (\(rot))")
        check(abs(ml.effects.dropShadow.distance - 10) < 0.001 && abs(ml.effects.dropShadow.size - 5) < 0.001, "style keyframes interpolate (distance \(ml.effects.dropShadow.distance))")
        let late = VideoTimelineEngine.evaluated(st, at: 1.75, decodeVideo: false).layer(shape.id)!
        check(abs(late.opacity - 0.4) < 1e-9, "after last key the value holds (0.4)")
        // duration bar trimmed → hidden outside
        var st2 = st; st2.videoTimeline!.tracks[0].start = 0.5; st2.videoTimeline!.tracks[0].duration = 1
        check(!VideoTimelineEngine.evaluated(st2, at: 0.2, decodeVideo: false).layer(shape.id)!.isVisible
              && VideoTimelineEngine.evaluated(st2, at: 1.0, decodeVideo: false).layer(shape.id)!.isVisible, "duration bar controls visibility")
        if let cg = Compositor.shared.flatten(mid, background: .white) { writePNG(cg, dir.appendingPathComponent("video_frame_1s.png")) }
        // native .lumen keeps the timeline
        do {
            let d0 = Document(state: st, name: "native")
            let u = dir.appendingPathComponent("timeline.imagecrat")
            try DocumentIO.saveNative(d0, to: u)
            let back = try DocumentIO.load(url: u)
            check(back.state.videoTimeline == st.videoTimeline, "native .imagecrat round-trips the video timeline")
        } catch { check(false, "native save threw \(error)") }

        // keyframe sync: edit at the playhead records a keyframe
        let d = Document(state: st, name: "video")
        AppModel.shared.add(d)
        let vt = VideoTimelineController.shared
        vt.setTime(d, 1, decodeVideo: false)
        d.updateLayer(shape.id) { $0.translate(dx: 0, dy: 40) }
        d.commit("Move")
        let keys = d.state.videoTimeline!.track(shape.id)!.keys(.position)
        check(keys.count == 3 && keys.contains { abs($0.time - 1) < 0.001 }, "moving a layer at the playhead adds a position keyframe (\(keys.count) keys)")
        // frames <-> timeline conversion
        vt.convertToFrames(d)
        check(d.state.videoTimeline == nil && d.state.frames.count == 60, "Convert to Frame Animation → 60 frames (\(d.state.frames.count))")
        vt.createTimeline(d)
        check(d.state.videoTimeline != nil && d.state.frames.isEmpty && abs(d.state.videoTimeline!.duration - 2) < 0.05, "Convert back to Video Timeline")
        AppModel.shared.close(d)

        // render MP4
        let mp4 = dir.appendingPathComponent("timeline.mp4")
        do {
            try VideoRenderer.writeMovie(st, to: mp4, settings: VideoRenderSettings(codec: .h264))
            let (dur, count) = movieInfo(mp4)
            check(abs(dur - 2) < 0.05, String(format: "MP4 duration %.3f s", dur))
            check(count == 60, "MP4 has 60 frames (\(count))")
            let hevc = dir.appendingPathComponent("timeline_hevc.mp4")
            var hs = VideoRenderSettings(codec: .hevc); hs.frameRate = 10
            try VideoRenderer.writeMovie(st, to: hevc, settings: hs)
            check(movieInfo(hevc).1 == 20, "HEVC at 10 fps → 20 frames")
            let pr = dir.appendingPathComponent("timeline_prores.mov")
            var ps = VideoRenderSettings(codec: .prores); ps.frameRate = 5
            try VideoRenderer.writeMovie(st, to: pr, settings: ps)
            check(movieInfo(pr).1 == 10, "ProRes 422 .mov at 5 fps → 10 frames")
            var seq = VideoRenderSettings(codec: .png); seq.frameRate = 5
            let files = try VideoRenderer.writeSequence(st, folder: dir.appendingPathComponent("sequence"), baseName: "frame", settings: seq)
            check(files.count == 10 && files[3].lastPathComponent == "frame_0003.png", "PNG sequence numbered files (\(files.count))")
        } catch { check(false, "video render threw \(error)") }

        // video layer: import the rendered movie and scrub
        do {
            let vd = Document.newBlank(width: 320, height: 240, background: .black, name: "vl")
            AppModel.shared.add(vd)
            let id = try VideoLayerImport.addVideoLayer(mp4, to: vd)
            let vdur = vd.state.videoTimeline?.duration ?? 0
            check(vd.state.videoTimeline?.track(id)?.video != nil && abs(vdur - 2) < 0.05, "Video to Layer creates a video track (duration \(vdur), clip \(vd.state.videoTimeline?.track(id)?.video?.sourceDuration ?? -1))")
            vt.setTime(vd, 0)
            let a = Compositor.shared.flatten(vd.state)
            vt.setTime(vd, 1.5)
            let b = Compositor.shared.flatten(vd.state)
            if let a, let b {
                writePNG(b, dir.appendingPathComponent("video_layer_1_5s.png"))
                let da = PixelBuffer(cgImage: a), db = PixelBuffer(cgImage: b)
                check(da.pixel(60, 120) != db.pixel(60, 120), "video layer shows the frame at the playhead")
            }
            AppModel.shared.close(vd)
        } catch { check(false, "video layer threw \(error)") }
    }

    static func movieInfo(_ url: URL) -> (Double, Int) {
        let asset = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        var dur = 0.0, count = 0
        Task.detached {
            if let d = try? await asset.load(.duration) { dur = d.seconds }
            if let track = try? await asset.loadTracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) {
                let o = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                reader.add(o)
                reader.startReading()
                while let s = o.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(s) > 0 { count += 1 } }
            }
            sem.signal()
        }
        while sem.wait(timeout: .now() + 0.01) == .timedOut { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        return (dur, count)
    }

    // MARK: Droplet

    static func testDroplet(_ dir: URL) {
        let inputs = dir.appendingPathComponent("droplet_in")
        let outputs = dir.appendingPathComponent("droplet_out")
        try? FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        var files: [URL] = []
        for i in 0..<2 {
            var st = sampleState(200 + i * 40, 120)
            st.layers[1].name = "S\(i)"
            let u = inputs.appendingPathComponent("in\(i).png")
            try? DocumentIO.export(st, to: u, format: .png, quality: 1, scale: 1)
            files.append(u)
        }
        let action = RecordedAction(name: "Invert Half", steps: [.invert, .imageSizePercent(50)])
        let app = dir.appendingPathComponent("Invert Half.app")
        do {
            try DropletBuilder.create(at: app, action: action, output: outputs, format: .png)
            let fm = FileManager.default
            check(fm.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path), "droplet bundle Info.plist")
            let scpt = fm.fileExists(atPath: app.appendingPathComponent("Contents/Resources/Scripts/main.scpt").path)
            let sh = fm.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/droplet").path)
            check(scpt || sh, "droplet has an AppleScript applet (\(scpt)) or shell executable (\(sh))")
            check(fm.fileExists(atPath: app.appendingPathComponent("Contents/Resources/action.json").path), "droplet embeds action.json")
            // run the droplet's command line on 2 files (same command the applet's open handler runs)
            let p = Process()
            p.executableURL = app.appendingPathComponent("Contents/Resources/run.sh")
            p.arguments = files.map(\.path)
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try p.run()
            let deadline = Date().addingTimeInterval(90)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { p.terminate(); check(false, "droplet run timed out") }
            let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            print(log.split(separator: "\n").map { "  droplet> " + $0 }.joined(separator: "\n"))
            check(p.terminationStatus == 0, "droplet --run-action exit status \(p.terminationStatus)")
            let o0 = outputs.appendingPathComponent("in0.png"), o1 = outputs.appendingPathComponent("in1.png")
            check(imageSize(o0).map { $0 == (100, 60) } == true && imageSize(o1).map { $0 == (120, 60) } == true, "droplet processed 2 files at 50% (\(imageSize(o0).map { "\($0)" } ?? "-"), \(imageSize(o1).map { "\($0)" } ?? "-"))")
            if let (cg, _) = DocumentIO.loadImage(url: o0), let (src, _) = DocumentIO.loadImage(url: files[0]) {
                let a = PixelBuffer(cgImage: cg).pixel(2, 2), b = PixelBuffer(cgImage: src).pixel(4, 4)
                check(abs(Int(a.0) - (255 - Int(b.0))) < 8, "droplet output is inverted (\(a.0) vs 255-\(b.0))")
            }
        } catch { check(false, "droplet threw \(error)") }
    }

    // MARK: Image Processor

    static func testImageProcessor(_ dir: URL) {
        let src = dir.appendingPathComponent("ip_src")
        try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for i in 0..<2 { try? DocumentIO.export(sampleState(400, 200 + i * 100), to: src.appendingPathComponent("photo\(i).png"), format: .png, quality: 1, scale: 1) }
        var s = ImageProcessorSettings()
        s.sources = [src]
        s.destination = dir.appendingPathComponent("ip_out")
        s.jpeg = .init(enabled: true, resize: true, width: 100, height: 100, quality: 0.8)
        s.png = .init(enabled: true)
        s.tiff = .init(enabled: true, resize: true, width: 200, height: 50)
        s.psd = .init(enabled: true, resize: true, width: 200, height: 200)
        s.copyright = "© Lumen Test"
        s.action = RecordedAction(name: "Gray", steps: [.adjustment(AdjustmentSettings(kind: .desaturate))])
        let r = ImageProcessor.run(s)
        check(r.written.count == 8 && r.failed == 0, "Image Processor wrote 8 files (\(r.written.count), failed \(r.failed))")
        let j = s.destination!.appendingPathComponent("JPEG/photo0.jpg")
        check(imageSize(j).map { $0 == (100, 50) } == true, "JPEG resized to fit 100×100 → 100×50 (\(imageSize(j).map { "\($0)" } ?? "-"))")
        if let so = CGImageSourceCreateWithURL(j as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(so, 0, nil) as? [CFString: Any] {
            let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            check((tiff?[kCGImagePropertyTIFFCopyright] as? String) == "© Lumen Test", "copyright metadata written")
        }
        if let back = try? PSDReader.read(url: s.destination!.appendingPathComponent("PSD/photo1.psd")) {
            check(back.width == 200 && back.height == 150, "PSD resized to fit 200×200 (\(back.width)×\(back.height))")
        } else { check(false, "PSD output readable") }
        if let (cg, _) = DocumentIO.loadImage(url: s.destination!.appendingPathComponent("PNG/photo0.png")) {
            let px = PixelBuffer(cgImage: cg).pixel(200, 190)
            check(abs(Int(px.0) - Int(px.1)) < 3 && abs(Int(px.1) - Int(px.2)) < 3, "action (desaturate) ran before saving \(px)")
        }
    }

    // MARK: Variables

    static func testVariables(_ dir: URL) {
        var st = SelfTest.baseState(360, 200)
        var t = TextContent(); t.text = "Name"; t.fontSize = 36; t.position = CGPoint(x: 20, y: 20)
        let text = Layer(name: "Name", content: .text(t))
        var badge = SelfTest.shapeLayer(CGRect(x: 280, y: 20, width: 60, height: 60), RGBA(hex: "F6AE2D")!, radius: 30)
        badge.name = "Badge"
        // pixel replacement target: a smart object
        let ph = PixelBuffer(width: 10, height: 10); ph.context.setFillColor(CGColor(gray: 0.5, alpha: 1)); ph.context.fill(CGRect(x: 0, y: 0, width: 10, height: 10)); ph.markDirty()
        let photo = Layer(name: "Photo", content: .smartObject(SmartObjectContent(source: .image(ph), quad: Quad(rect: CGRect(x: 20, y: 90, width: 120, height: 90)), sourceName: "ph")))
        st.layers += [text, badge, photo]
        // images for pixel replacement
        for (i, hex) in ["2E86AB", "3BB273", "E94F37"].enumerated() {
            let b = PixelBuffer(width: 160, height: 90); b.context.setFillColor(RGBA(hex: hex)!.cgColor); b.context.fill(CGRect(x: 0, y: 0, width: 160, height: 90)); b.markDirty()
            try? b.pngData()?.write(to: dir.appendingPathComponent("var_img\(i).png"))
        }
        var vars = DocumentVariables()
        vars.variables = [LayerVariable(name: "name", kind: .text, layerID: text.id),
                          LayerVariable(name: "badge", kind: .visibility, layerID: badge.id),
                          LayerVariable(name: "photo", kind: .pixel, layerID: photo.id, box: CGRect(x: 20, y: 90, width: 120, height: 90))]
        vars.baseFolder = dir
        st.variables = vars
        let csv = "Data Set,name,badge,photo\nAlice,\"Alice, Ph.D.\",true,var_img0.png\nBob,Bob,false,var_img1.png\r\nCarol,Carol,visible,var_img2.png\n"
        let (sets, unmatched) = Variables.dataSets(fromText: csv, variables: vars.variables)
        check(sets.count == 3 && unmatched.isEmpty && sets[0].name == "Alice" && sets[0].values["name"] == "Alice, Ph.D.", "CSV → 3 data sets (quoted fields)")
        let tsv = Variables.dataSets(fromText: "name\tbadge\nX\ttrue\nY\tfalse\n", variables: vars.variables)
        check(tsv.sets.count == 2 && tsv.sets[1].values["badge"] == "false", "TSV parsing")
        st.variables!.dataSets = sets
        if let data = try? PropertyListEncoder().encode(LumenFile(name: "v", state: st)),
           let back = try? PropertyListDecoder().decode(LumenFile.self, from: data) {
            check(back.state.variables == st.variables, "native .imagecrat round-trips variables & data sets")
        } else { check(false, "variables native encode") }
        let bob = Variables.applied(sets[1], to: st)
        check(bob.layer(text.id)?.text?.text == "Bob" && bob.layer(badge.id)?.isVisible == false, "apply data set: text + visibility")
        if case .image(let b) = bob.layer(photo.id)?.smart?.source { check(b.width == 160, "pixel replacement swaps the smart object image") }
        check(bob.layer(photo.id)?.smart?.quad.bounds.width == 120, "pixel replacement fits the variable's box (\(bob.layer(photo.id)?.smart?.quad.bounds ?? .zero))")
        do {
            let urls = try Variables.exportDataSets(st, folder: dir.appendingPathComponent("datasets"), prefix: "card_", format: .png)
            check(urls.count == 3 && urls.map(\.lastPathComponent) == ["card_Alice.png", "card_Bob.png", "card_Carol.png"], "Export Data Sets as Files → 3 PNGs")
            let expect: [(UInt8, UInt8, UInt8)] = [(0x2E, 0x86, 0xAB), (0x3B, 0xB2, 0x73), (0xE9, 0x4F, 0x37)]
            for (i, u) in urls.enumerated() {
                guard let (cg, _) = DocumentIO.loadImage(url: u) else { continue }
                let px = PixelBuffer(cgImage: cg).pixel(80, 135)
                check(abs(Int(px.0) - Int(expect[i].0)) < 6 && abs(Int(px.1) - Int(expect[i].1)) < 6 && abs(Int(px.2) - Int(expect[i].2)) < 6,
                      "data set \(i + 1) shows its replacement image \(px)")
            }
            let psds = try Variables.exportDataSets(st, folder: dir.appendingPathComponent("datasets_psd"), prefix: "", format: .psd)
            check(psds.count == 3, "Export Data Sets as PSD")
        } catch { check(false, "export data sets threw \(error)") }
    }

    // MARK: Scripting

    static func testScripting(_ dir: URL) {
        let e = ScriptEngine(name: "test", interactive: false)
        var logs: [String] = []
        e.log = { logs.append($0); print("  js> " + $0) }
        let outPNG = dir.appendingPathComponent("script_result.png").path
        let src = """
        var doc = app.newDocument(400, 240, 'Scripted', { background: '#F4F1EA' });
        var title = doc.addTextLayer('Scripted!', { x: 24, y: 20, size: 40, color: '#1B1F3A' });
        var box = doc.addShape('rectangle', { x: 40, y: 100, width: 140, height: 100, fill: '#E94F37', radius: 10 });
        var dot = doc.addShape('ellipse', { x: 230, y: 90, width: 120, height: 120, fill: '#2E86AB' });
        var px = doc.addLayer('Pixels', { fill: '#3BB273' });
        doc.selection.rect(250, 20, 120, 40);
        doc.selection.invert();
        px.select();
        doc.selection.fill('#FFFFFF', 100);
        doc.selection.deselect();
        px.opacity = 50;
        px.blendMode = 'multiply';
        box.applyFilter('Gaussian Blur', { radius: 6 });
        var copy = dot.duplicate('Dot copy');
        copy.translate(-60, 0).rotate(30);
        title.text = 'Scripted & blurred';
        console.log(doc.layers.map(function (l) { return l.name + ':' + l.kind; }).join(', '));
        var r = { layers: doc.layers.length, boxKind: box.kind, filters: app.filters().length, pxOpacity: px.opacity, text: title.text };
        doc.exportAs('\(outPNG)');
        r;
        """
        e.evaluate(src, file: nil)
        check(e.lastError == nil, "JS script ran without errors \(e.lastError ?? "")")
        let res = e.context.evaluateScript("r")?.toDictionary() ?? [:]
        check((res["layers"] as? Int) == 6, "JS created layers (\(res["layers"] ?? "nil"))")
        check((res["boxKind"] as? String) == "pixel", "filter on a shape rasterized it and applied (\(res["boxKind"] ?? "nil"))")
        check((res["pxOpacity"] as? Double).map { abs($0 - 50) < 0.5 } == true && (res["text"] as? String) == "Scripted & blurred", "JS property setters")
        check((res["filters"] as? Int ?? 0) > 50, "app.filters() lists filters")
        if let d = AppModel.shared.documents.first(where: { $0.name == "Scripted" }) {
            if let box = d.state.allLayers.first(where: { $0.name.hasPrefix("Rectangle") }), let r = box.raster {
                // blurred edge: pixels just outside / inside the original rect edge are partially covered
                let a = r.buffer.alpha(37 - r.origin.x, 150 - r.origin.y)
                check(a > 5 && a < 250, "Gaussian Blur softened the edge (alpha \(a))")
            }
            AppModel.shared.close(d)
        } else { check(false, "scripted document exists") }
        check(FileManager.default.fileExists(atPath: outPNG), "JS exportAs wrote a PNG")
        // errors surface as exceptions
        e.evaluate("app.activeDocument && app.activeDocument.applyFilter('No Such Filter')")
        let e2 = ScriptEngine(name: "err", interactive: false)
        e2.evaluate("Document.prototype.x = 1; app.newDocument(10, 10).applyFilter('No Such Filter');")
        check(e2.lastError?.contains("Unknown filter") == true, "unknown filter raises a JS error")
        for d in AppModel.shared.documents where d.state.width == 10 { AppModel.shared.close(d) }

        // sample scripts & plugin
        let support = dir.appendingPathComponent("support")
        ScriptLibrary.installSamplesIfNeeded(into: support)
        let sampleDir = support.appendingPathComponent("Scripts")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: sampleDir.path)) ?? []).sorted()
        check(names == ["Contact Sheet.js", "Random Rotate Layers.js"], "sample scripts installed \(names)")
        // Contact Sheet over the droplet / processor inputs (prompt → default in headless mode)
        let imgs = dir.appendingPathComponent("contact_src")
        try? FileManager.default.createDirectory(at: imgs, withIntermediateDirectories: true)
        for i in 0..<5 { try? DocumentIO.export(sampleState(300, 200 + i * 20), to: imgs.appendingPathComponent("img\(i).png"), format: .png, quality: 1, scale: 1) }
        let cs = ScriptEngine(name: "Contact Sheet", interactive: false)
        cs.log = { print("  contact> " + $0) }
        cs.context.setObject([imgs.path], forKeyedSubscript: "arguments" as NSString)
        cs.evaluate((try? String(contentsOf: sampleDir.appendingPathComponent("Contact Sheet.js"), encoding: .utf8)) ?? "", file: "Contact Sheet.js")
        if let d = AppModel.shared.documents.first(where: { $0.name == "Contact Sheet" }) {
            check(d.state.layers.count == 11, "Contact Sheet placed 5 images + 5 captions (\(d.state.layers.count) layers)")
            // Random Rotate on the contact sheet
            let rr = ScriptEngine(name: "Random Rotate", interactive: false)
            AppModel.shared.activeDocumentID = d.id
            let before = d.state.layers.compactMap { $0.smart?.quad }
            rr.evaluate((try? String(contentsOf: sampleDir.appendingPathComponent("Random Rotate Layers.js"), encoding: .utf8)) ?? "", file: "rr.js")
            let after = d.state.layers.compactMap { $0.smart?.quad }
            check(rr.lastError == nil && before != after, "Random Rotate Layers rotated the layers")
            if let cg = Compositor.shared.flatten(d.state, background: .white) { writePNG(cg, dir.appendingPathComponent("script_contact_sheet_rotated.png")) }
            AppModel.shared.close(d)
        } else { check(false, "Contact Sheet document created \(cs.lastError ?? "")") }

        let pm = PluginManager()
        pm.reload(from: support.appendingPathComponent("Plugins"))
        check(pm.plugins.count == 1 && pm.plugins[0].manifest.name == "Quick Swatches" && pm.plugins[0].manifest.panel == "panel.html", "sample plugin manifest loads")
        if let p = pm.plugins.first {
            let sw = p.engine.callFunction("swatches") as? [Any]
            check((sw?.count ?? 0) >= 8, "plugin runs in its own context (swatches: \(sw?.count ?? 0))")
            let other = ScriptEngine(name: "other", interactive: false)
            check(other.context.objectForKeyedSubscript("swatches")?.isUndefined == true, "plugin globals are isolated from other contexts")
            let d = Document.newBlank(width: 200, height: 100, background: .white, name: "plugin")
            AppModel.shared.add(d)
            p.engine.interactive = false
            _ = p.engine.callFunction("run")
            check(d.state.allLayers.filter(\.isShape).count == 8, "plugin run() added 8 swatch shapes")
            // the panel bridge calls the same dispatcher
            let r = try? ScriptAPI.dispatch("plugin.invoke", ["addColorLayer", ["#123456"]], engine: p.engine)
            check((r as? String) == "Swatch #123456", "panel bridge plugin.invoke → \(String(describing: r))")
            AppModel.shared.close(d)
        }
    }
}
