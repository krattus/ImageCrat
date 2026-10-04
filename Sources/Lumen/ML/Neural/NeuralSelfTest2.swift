import Foundation
import CoreImage
import AppKit
import SwiftUI
import ImageCratCore

/// Feature-level neural self tests (filters, Remove / distractions, sky replacement, Content Credentials).
enum NeuralSelfTest2 {
    typealias T = NeuralSelfTest

    /// Generic stock portrait shipped inside Keynote (app resources, not user files); nil when not installed.
    static func portrait() -> CGImage? {
        let paths = ["/Applications/Keynote Creator Studio.app/Contents/SharedSupport/DocumentResources/a9/cbb46fcbaf55e3c6b44fcf52eccf7780e0b611.jpeg",
                     "/Applications/Keynote.app/Contents/SharedSupport/DocumentResources/a9/cbb46fcbaf55e3c6b44fcf52eccf7780e0b611.jpeg"]
        for p in paths where FileManager.default.fileExists(atPath: p) { if let c = NImg.loadCG(URL(fileURLWithPath: p)) { return NImg.fitted(c, maxSide: 1400) } }
        return nil
    }

    static func values(_ k: NeuralFilterKind, _ over: [String: Double]) -> (String) -> Double {
        let d = k.defaults().merging(over) { $1 }
        return { d[$0] ?? 0 }
    }

    static func sideBySide(_ a: CGImage, _ b: CGImage) -> CGImage {
        let h = max(a.height, b.height)
        let buf = PixelBuffer(width: a.width + b.width + 8, height: h)
        buf.context.setFillColor(gray: 1, alpha: 1); buf.context.fill(CGRect(x: 0, y: 0, width: buf.width, height: h))
        buf.drawImage(a, in: CGRect(x: 0, y: 0, width: a.width, height: a.height))
        buf.drawImage(b, in: CGRect(x: a.width + 8, y: 0, width: b.width, height: b.height))
        buf.markDirty()
        return buf.makeCGImage()
    }

    static func overlay(_ img: CGImage, mask: PlanarImage, color: RGBA = RGBA(r: 1, g: 0.1, b: 0.3, a: 0.6)) -> CGImage {
        let base = CIImage(cgImage: img)
        let m = CIImage(cgImage: mask.cgImage())
        return NImg.cg(CIImage.color(color, base.extent).masked(byGray: m).composited(over: base), rect: base.extent) ?? img
    }

    // MARK: Synthetic power-line scene

    static func powerLines(_ w: Int, _ h: Int) -> (CGImage, PlanarImage) {
        let sky = SkyPresets.presets[0].make(w, h)
        let buf = RenderEngine.renderBuffer(sky, docRect: IRect(x: 0, y: 0, width: w, height: h), space: CanvasSpace(width: w, height: h))
        let c = buf.context
        // hills
        c.setFillColor(RGBA(hex: "4F7A3A")!.cgColor)
        let hills = CGMutablePath(); hills.move(to: CGPoint(x: 0, y: Double(h) * 0.72))
        for i in 0...24 { hills.addLine(to: CGPoint(x: Double(w) * Double(i) / 24, y: Double(h) * (0.7 + 0.05 * sin(Double(i) * 0.7)))) }
        hills.addLine(to: CGPoint(x: w, y: h)); hills.addLine(to: CGPoint(x: 0, y: h)); hills.closeSubpath()
        c.addPath(hills); c.fillPath()
        // wires (ground truth drawn into a mask too)
        let gt = PixelBuffer(width: w, height: h, format: .gray)
        func wire(_ ctx: CGContext, _ y0: Double, _ y1: Double, _ sag: Double, _ lw: Double) {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -10, y: y0))
            p.addQuadCurve(to: CGPoint(x: Double(w) + 10, y: y1), control: CGPoint(x: Double(w) / 2, y: (y0 + y1) / 2 + sag))
            ctx.addPath(p); ctx.setLineWidth(lw); ctx.strokePath()
        }
        c.setStrokeColor(RGBA(hex: "1A1A1A")!.cgColor)
        gt.context.setStrokeColor(gray: 1, alpha: 1)
        let wires: [(Double, Double, Double, Double)] = [(0.18, 0.30, 90, 3), (0.24, 0.35, 80, 3), (0.30, 0.40, 70, 2.5), (0.12, 0.12, 0, 2)]
        for (a, b, sag, lw) in wires {
            wire(c, Double(h) * a, Double(h) * b, sag, lw)
            wire(gt.context, Double(h) * a, Double(h) * b, sag, lw)
        }
        // a pole
        c.setFillColor(RGBA(hex: "3B2A1E")!.cgColor)
        c.fill(CGRect(x: Double(w) * 0.82, y: Double(h) * 0.1, width: 10, height: Double(h) * 0.65))
        buf.markDirty(); gt.markDirty()
        return (buf.makeCGImage(), PlanarImage.gray(gt.makeCGImage()))
    }

    /// Offscreen snapshots of the dialogs / panels (LUMEN_NEURAL_ONLY=ui).
    static func runUI(_ out: URL, _ img: CGImage) {
        var st = DocumentState(width: img.width, height: img.height)
        st.layers = [Layer.raster(name: "Background", buffer: PixelBuffer(cgImage: img))]
        let d = Document(state: st, name: "Lake")
        let app = AppModel.shared
        app.add(d)
        defer { app.close(d) }
        func snap<V: View>(_ v: V, _ name: String, _ size: CGSize, wait: Double) {
            let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height, alignment: .top).background(Theme.panelBG).environment(\.colorScheme, .dark))
            host.frame = CGRect(origin: .zero, size: size)
            // never ordered on screen (models are pre-loaded, so onAppear isn't needed)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            let end = Date().addingTimeInterval(wait)
            while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
            print("wrote \(name)")
        }
        func pump(_ seconds: Double, until done: () -> Bool) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end && !done() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        let nf = NeuralFiltersModel(); nf.load(); nf.focalPoint = CGPoint(x: 0.8, y: 0.85); nf.toggle(.depthBlur)
        pump(20) { nf.previewResult != nil }
        snap(DraggableCard { NeuralFiltersDialog(model: nf) }, "neural_ui_filters_dialog", CGSize(width: 1100, height: 640), wait: 0.4)
        let nf2 = NeuralFiltersModel(); nf2.load(); nf2.values[.styleTransfer]?["mode"] = 1; nf2.toggle(.styleTransfer); nf2.compare = 2
        pump(20) { nf2.previewResult != nil }
        snap(DraggableCard { NeuralFiltersDialog(model: nf2) }, "neural_ui_filters_style", CGSize(width: 1100, height: 640), wait: 0.4)
        let sky = SkyReplacementModel(); sky.s.presetIndex = 1; sky.load()
        pump(30) { sky.preview != nil }
        snap(DraggableCard { SkyReplacementDialog(model: sky) }, "neural_ui_sky_dialog", CGSize(width: 840, height: 620), wait: 0.4)
        let dn = NeuralQuickModel(kind: .denoise); dn.load()
        pump(30) { dn.after != nil }
        snap(DraggableCard { NeuralQuickDialog(model: dn) }, "neural_ui_denoise_dialog", CGSize(width: 580, height: 420), wait: 0.4)
        let sh = NeuralQuickModel(kind: .sharpen); sh.sharpenMode = 1; sh.load()
        pump(30) { sh.after != nil }
        snap(DraggableCard { NeuralQuickDialog(model: sh) }, "neural_ui_sharpen_dialog", CGSize(width: 580, height: 450), wait: 0.4)
        snap(HStack { RemoveOptions() }, "neural_ui_remove_options", CGSize(width: 900, height: 40), wait: 0.3)
        // Content Credentials panel on a signed file
        let signed = out.appendingPathComponent("neural_c2pa_signed.jpg")
        snap(ContentCredentialsPanel(preload: FileManager.default.fileExists(atPath: signed.path) ? signed : nil), "neural_ui_credentials_panel", CGSize(width: 300, height: 420), wait: 0.5)
        snap(DraggableCard { ExportDialog() }, "neural_ui_export_dialog", CGSize(width: 400, height: 330), wait: 0.3)
    }

    static func run(_ out: URL) {
        let img = T.aerial(1200)
        // --- Find Distractions: wires, then LaMa -----------------------------------------------------------
        if T.want("wires") {
            let (scene, gt) = powerLines(1400, 900)
            let m = T.time("Wire detection 1400×900") { WireDetector.detect(scene) }
            var tp = 0, gtN = 0, fp = 0, mN = 0
            for i in gt.data.indices {
                let g = gt.data[i] > 0.5, d = m.data[i] > 0.5
                if g { gtN += 1; if d { tp += 1 } }
                if d { mN += 1; if !g { fp += 1 } }
            }
            print(String(format: "  wires: recall %.1f%%, mask area %.2f%% of image (GT %.2f%%)", 100 * Double(tp) / Double(max(1, gtN)),
                         100 * Double(mN) / Double(gt.data.count), 100 * Double(gtN) / Double(gt.data.count)))
            T.write(scene, "neural_wires_input", out)
            T.write(overlay(scene, mask: m), "neural_wires_mask", out)
            if LamaInpainter.isAvailable {
                do {
                    let r = try T.time("LaMa remove wires") { try T.sync { try await LamaInpainter.inpaint(scene, hole: m) } }
                    T.write(r, "neural_wires_removed", out)
                } catch { print("FAIL wires lama: \(error)") }
            }
            // also on the real landscape: nothing should be detected in open sky
            let m2 = WireDetector.detect(img)
            print(String(format: "  wires on landscape (no wires): mask area %.2f%%", 100 * Double(m2.data.filter { $0 > 0.5 }.count) / Double(m2.data.count)))
            T.write(overlay(img, mask: m2), "neural_wires_landscape_falsepos", out)
        }
        // --- Remove tool path (document + async fill) ------------------------------------------------------
        if T.want("remove"), LamaInpainter.isAvailable {
            var st = DocumentState(width: img.width, height: img.height)
            st.layers = [Layer.raster(name: "Background", buffer: PixelBuffer(cgImage: img))]
            let d = Document(state: st, name: "remove-test")
            let hole = PixelBuffer(width: img.width, height: img.height, format: .gray)
            hole.context.setFillColor(gray: 1, alpha: 1)
            let s = Double(img.width) / 800
            hole.context.fillEllipse(in: CGRect(x: 560 * s, y: 240 * s, width: 80 * s, height: 50 * s))   // the medium rock right of centre
            hole.markDirty()
            var done: Bool? = nil
            let t0 = CFAbsoluteTimeGetCurrent()
            NeuralRemove.shared.modeOverride = .generative
            NeuralRemove.fill(d, layerID: d.state.layers[0].id, hole: SelectionOps.expand(hole, by: 6), sampleAll: false, name: "Remove") { done = $0 }
            while done == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
            print(String(format: "  ⏱ Remove tool (LaMa, via document): %.2f s, ok=%@, history: %@", CFAbsoluteTimeGetCurrent() - t0, "\(done!)", d.history.last?.name ?? "-"))
            NeuralRemove.shared.modeOverride = nil
            SelfTest.save(d.state, "neural_remove_tool_doc", out)
        }
        // --- Depth blur near / far ------------------------------------------------------------------------
        if T.want("depthblur"), DepthEstimator.isAvailable {
            do {
                let depth = try T.sync { try await DepthEstimator.depth(img) }
                let near = try T.time("Depth Blur (focus near)") { try T.sync { try await DepthBlur.apply(img, v: values(.depthBlur, ["strength": 70, "focalRange": 15, "focusSubject": 0]), focal: CGPoint(x: 0.8, y: 0.85), depth: depth) } }
                let far = try T.time("Depth Blur (focus far)") { try T.sync { try await DepthBlur.apply(img, v: values(.depthBlur, ["strength": 70, "focalRange": 15, "focusSubject": 0, "haze": 30]), focal: CGPoint(x: 0.3, y: 0.46), depth: depth) } }
                T.write(near, "neural_depthblur_near", out); T.write(far, "neural_depthblur_far", out)
            } catch { print("FAIL depth blur: \(error)") }
        }
        // --- Portrait: face restoration, skin smoothing, smart portrait --------------------------------------
        if let face = portrait() {
            let faces = FaceTools.detect(face)
            print("  portrait \(face.width)×\(face.height): \(faces.count) face(s)")
            if T.want("face"), FaceTools.gfpganAvailable, let f0 = faces.first {
                // degrade: ×4 down, back up, JPEG
                let small = NImg.resized(face, face.width / 4, face.height / 4)
                let degraded = jpeg(NImg.resized(small, face.width, face.height), quality: 0.35)
                do {
                    let (r, n) = try T.time("GFPGAN face restoration") { try T.sync { try await FaceTools.restoreFaces(degraded, strength: 1)! } }
                    let crop = f0.bounds.insetBy(dx: -f0.bounds.width * 0.3, dy: -f0.bounds.height * 0.3).intersection(CGRect(x: 0, y: 0, width: face.width, height: face.height))
                    print(String(format: "  faces restored: %d, face-crop PSNR degraded %.2f dB → restored %.2f dB", n,
                                 NImg.psnr(face.cropping(to: crop)!, degraded.cropping(to: crop)!), NImg.psnr(face.cropping(to: crop)!, r.cropping(to: crop)!)))
                    T.write(sideBySide(degraded.cropping(to: crop)!, r.cropping(to: crop)!), "neural_face_restore_before_after", out)
                    // Super Zoom on the small image with face enhancement
                    let sz = try T.time("Super Zoom ×4 + faces") { try T.sync { try await NeuralFilterEngine.run(.superZoom, values: ["scale": 1, "faces": 1], input: small, ctx: NeuralContext()) } }
                    T.write(sz.cropping(to: crop) ?? sz, "neural_superzoom_face", out)
                } catch { print("FAIL face: \(error)") }
            }
            if T.want("skin"), let f0 = faces.first {
                do {
                    let r = try T.time("Skin Smoothing") { try PortraitFilters.skinSmoothing(face, blur: 80, smoothness: 20) }
                    let crop = f0.bounds.insetBy(dx: -f0.bounds.width * 0.15, dy: -f0.bounds.height * 0.2)
                    T.write(sideBySide(face.cropping(to: crop)!, r.cropping(to: crop)!), "neural_skin_smoothing", out)
                    T.write(NImg.grayCG(PortraitFilters.skinMask(face, faces: faces))!, "neural_skin_mask", out)
                    let lit = try T.time("Smart Portrait light") { try T.sync { try await PortraitFilters.smartPortrait(face, v: values(.smartPortrait, ["lightDirection": -40, "lightStrength": 80, "brightness": 10])) } }
                    T.write(sideBySide(face.cropping(to: crop)!, lit.cropping(to: crop)!), "neural_smart_portrait_light", out)
                    do { _ = try T.sync { try await PortraitFilters.smartPortrait(face, v: values(.smartPortrait, ["happiness": 30])) }; print("FAIL: cloud option should need a provider") }
                    catch { print("  smart portrait cloud option without provider → \(error.localizedDescription)") }
                } catch { print("FAIL skin: \(error)") }
            }
        } else { print("  (no portrait image available: face tests skipped)") }
        // --- Style transfer ---------------------------------------------------------------------------------
        if T.want("style") {
            for (i, p) in StyleTransfer.presets.enumerated() { if let s = StyleTransfer.styleImage(p, size: 256) { T.write(s, "neural_style_preset_\(i)_\(p.id)", out) } }
            let content = T.aerial(800)
            let fast = StyleTransfer.fast(content, StyleTransfer.presets[1], preserveColor: false)
            T.write(fast, "neural_style_fast_stainedglass", out)
            do {
                let p = StyleTransfer.presets[0]
                try? FileManager.default.removeItem(at: StyleTransfer.compiledURL(p.id))
                _ = try T.time("Style training (Create ML, \(p.name), 120 it)") { try T.sync { try await StyleTransfer.Trainer.shared.train(p, content: content) } }
                let m = try StyleTransfer.model(p.id)
                print("  style model: \(NeuralTensor.describe(m))")
                let r = try T.time("Style inference") { try StyleTransfer.stylize(content, model: m) }
                T.write(r, "neural_style_neural_swirls", out)
            } catch { print("FAIL style training: \(error)") }
        }
        // --- Sky replacement ----------------------------------------------------------------------------------
        if T.want("sky") {
            let (mask, src) = T.time("Sky mask") { T.sync2 { await SkyEstimator.mask(img) } }
            print("  sky mask source: \(src)")
            T.write(mask.cgImage(), "neural_sky_mask", out)
            for (i, name) in [(1, "sunset"), (2, "dramatic")] {
                var s = SkySettings(); s.presetIndex = i; s.lighting = 50; s.edgeLighting = 30; s.colorAdjust = 50
                let photo = CIImage(cgImage: img)
                let parts = T.time("Sky replacement \(name)") { SkyReplacement.parts(photo: photo, mask: mask, s) }
                T.write(NImg.cg(SkyReplacement.composite(photo: photo, parts: parts, s), rect: photo.extent)!, "neural_sky_\(name)", out)
            }
            // as layers in a document (Photoshop-style group)
            var st = DocumentState(width: img.width, height: img.height)
            st.layers = [Layer.raster(name: "Background", buffer: PixelBuffer(cgImage: img))]
            let d = Document(state: st, name: "sky")
            var s = SkySettings(); s.presetIndex = 1
            let parts = SkyReplacement.parts(photo: CIImage(cgImage: img), mask: mask, s)
            MainActor.assumeIsolated { SkyReplacement.applyAsLayers(d, parts: parts, s) }
            let names = d.state.allLayers.map(\.name)
            print("  sky layers: \(names)")
            SelfTest.save(d.state, "neural_sky_layers_doc", out)
        }
        // --- Harmonization / Color transfer ---------------------------------------------------------------------
        if T.want("harmon"), let parrot = NImg.loadCG(URL(fileURLWithPath: "/Library/User Pictures/Animals/Parrot.heic")) {
            let obj = NImg.resized(parrot, 300, 300)
            let bg = T.aerial(1000)
            // the layer (canvas-size) with the object placed on transparent, below = landscape
            let layer = PixelBuffer(width: bg.width, height: bg.height)
            layer.drawImage(obj, in: CGRect(x: 640, y: 250, width: 300, height: 300))
            layer.markDirty()
            let h = Harmonize.harmonize(layer.makeCGImage(), to: bg, v: values(.harmonization, ["strength": 80]))
            let before = NImg.cg(CIImage(cgImage: layer.makeCGImage()).composited(over: CIImage(cgImage: bg)))!
            let after = NImg.cg(CIImage(cgImage: h).composited(over: CIImage(cgImage: bg)))!
            T.write(sideBySide(NImg.fitted(before, maxSide: 600), NImg.fitted(after, maxSide: 600)), "neural_harmonization", out)
            let ct = ColorTransfer.transfer(bg, to: ColorTransfer.presets[0].stats, luminance: 1, intensity: 1, strength: 1, preserveLuminance: true)
            T.write(ct, "neural_color_transfer_golden", out)
        }
        // --- Restoration: JPEG artifacts, old photo ------------------------------------------------------------
        if T.want("restore"), Restoration.isAvailable(.denoise), let clean = NImg.crop(img, CGRect(x: 300, y: 200, width: 640, height: 400)) {
            let jp = jpeg(clean, quality: 0.06)
            do {
                let r = try T.time("JPEG Artifacts Removal (high)") { try T.sync { try await NeuralFilterEngine.run(.jpegArtifacts, values: ["strength": 2], input: jp, ctx: NeuralContext()) } }
                print(String(format: "  JPEG q=0.06 PSNR %.2f dB → %.2f dB", NImg.psnr(clean, jp), NImg.psnr(clean, r)))
                T.write(sideBySide(jp, r), "neural_jpeg_artifacts", out)
            } catch { print("FAIL jpeg: \(error)") }
            // old photo: sepia + noise + scratches
            let old = oldPhoto(clean)
            do {
                let m = ScratchReduction.mask(old, amount: 0.8)
                T.write(overlay(old, mask: m), "neural_scratch_mask", out)
                scratchStats(clean)
                let r = try T.time("Photo Restoration (enhance+scratches)") { try T.sync { try await NeuralFilterEngine.run(.photoRestoration, values: ["enhance": 70, "scratch": 80, "face": 0, "contrast": 10], input: old, ctx: NeuralContext()) } }
                T.write(sideBySide(old, r), "neural_photo_restoration", out)
            } catch { print("FAIL restoration: \(error)") }
            if Restoration.isAvailable(.deblur) {
                let mb = motionBlur(clean, 9)
                do {
                    let r = try T.time("NAFNet deblur (motion 9 px)") { try T.sync { try await Restoration.run(mb, .deblur) } }
                    print(String(format: "  motion deblur PSNR %.2f dB → %.2f dB", NImg.psnr(clean, mb), NImg.psnr(clean, r)))
                    T.write(sideBySide(mb, r), "neural_deblur_motion", out)
                    let soft = NImg.cg(CIImage(cgImage: clean).clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: CGRect(x: 0, y: 0, width: clean.width, height: clean.height)))!
                    let r2 = try T.time("Soft-focus restore (Real-ESRGAN)") { try T.sync { try await Restoration.restoreViaSR(soft) } }
                    let r3 = try T.sync { try await Restoration.run(soft, .deblur) }
                    print(String(format: "  soft focus σ1.5 PSNR %.2f dB → ESRGAN-restore %.2f dB, NAFNet-GoPro(guarded) %.2f dB", NImg.psnr(clean, soft), NImg.psnr(clean, r2), NImg.psnr(clean, r3)))
                    T.write(sideBySide(soft, r2), "neural_soft_restore", out)
                } catch { print("FAIL deblur: \(error)") }
            }
        }
        // --- Colorize via filter (hints) + stack & outputs ------------------------------------------------------
        if T.want("output") {
            var st = DocumentState(width: img.width, height: img.height)
            st.layers = [Layer.raster(name: "Background", buffer: PixelBuffer(cgImage: img))]
            let d = Document(state: st, name: "outputs")
            let id = d.state.layers[0].id
            let r = ColorTransfer.transfer(img, to: ColorTransfer.presets[2].stats, luminance: 1, intensity: 1.2, strength: 1, preserveLuminance: false)
            MainActor.assumeIsolated {
                NeuralFiltersModel.write(r, to: d, layerID: id, output: .smartFilter, name: "Color Transfer", settings: ["enabled.colorTransfer": 1])
            }
            let l = d.state.layers.last!
            print("  smart filter output: layer '\(l.name)' smart=\(l.isSmartObject) filters=\(l.smart?.filters.map(\.kind.rawValue) ?? [])")
            SelfTest.save(d.state, "neural_output_smartfilter", out)
            // filter stack (Colorize with a colour hint → Depth Blur) through the engine, then the other outputs
            let small = NImg.fitted(img, maxSide: 800)
            let gray = NImg.cg(CIImage(cgImage: small).applyingFilter("CIPhotoEffectMono"))!
            var ctx = NeuralContext()
            ctx.hints = [(CGPoint(x: 0.5, y: 0.75), RGBA(hex: "E94F37")!)]
            ctx.focalPoint = CGPoint(x: 0.8, y: 0.85)
            do {
                let r2 = try T.time("Stack: Colorize(+hint) → Depth Blur (800 px)") { try T.sync {
                    try await NeuralFilterEngine.runStack([.colorize, .depthBlur], values: [.depthBlur: NeuralFilterKind.depthBlur.defaults().merging(["strength": 40]) { $1 }], input: gray, ctx: ctx) } }
                T.write(r2, "neural_stack_colorize_depthblur", out)
                var st2 = DocumentState(width: small.width, height: small.height)
                st2.layers = [Layer.raster(name: "Background", buffer: PixelBuffer(cgImage: gray))]
                let d2 = Document(state: st2, name: "stack")
                let before = AppModel.shared.documents.count
                MainActor.assumeIsolated {
                    NeuralFiltersModel.write(r2, to: d2, layerID: d2.state.layers[0].id, output: .newLayer, name: "Neural Filters", settings: [:])
                    NeuralFiltersModel.write(r2, to: d2, layerID: d2.state.layers[0].id, output: .currentLayer, name: "Neural Filters", settings: [:])
                    NeuralFiltersModel.write(r2, to: d2, layerID: d2.state.layers[0].id, output: .newDocument, name: "Neural Filters", settings: [:])
                }
                print("  outputs: layers=\(d2.state.layers.map(\.name)) history=\(d2.history.map(\.name)) newDocs=\(AppModel.shared.documents.count - before)")
                print("  C2PA neural tools detected from history: \(ContentCredentials.usedNeuralTools(d2))")
                if let nd = AppModel.shared.documents.last, AppModel.shared.documents.count > before { AppModel.shared.close(nd) }
            } catch { print("FAIL stack: \(error)") }
            // Find Distractions ▸ People on a single-subject portrait → nothing to remove
            if let face = portrait() {
                let pm = T.time("People distraction scan") { NeuralRemove.peopleMask(face) }
                print("  people distractions on single-subject portrait: \(pm == nil ? "none (main subject kept)" : "mask returned")")
            }
        }
        // --- Content Credentials ------------------------------------------------------------------------------
        if T.want("c2pa") {
            var st = DocumentState(width: 640, height: 360)
            st.layers = [Layer.raster(name: "Background", buffer: PixelBuffer(cgImage: NImg.fitted(img, maxSide: 640)))]
            for fmt in [ExportFormat.png, .jpeg, .tiff, .heic, .gif] {
                let url = out.appendingPathComponent("neural_c2pa_signed.\(fmt.ext)")
                do {
                    try DocumentIO.export(st, to: url, format: fmt, quality: 0.9, scale: 1)
                    try T.time("C2PA sign \(fmt.rawValue)") { try ContentCredentials.sign(file: url, generativeAI: false, neuralTools: ["Remove", "Sky Replacement"], newDocument: false) }
                    switch ContentCredentials.read(url) {
                    case .success(let s):
                        print("  C2PA \(fmt.rawValue): state=\(s.state) untrusted=\(s.untrusted) generator=\(s.generator) issuer=\(s.issuer) ai=\(s.aiGenerated)")
                        if fmt == .png {
                            print("    actions: \(s.actions)")
                            print("    status: \(s.statusCodes.prefix(8))")
                        }
                    case .failure(let e): print("FAIL C2PA read \(fmt.rawValue): \(e)")
                    }
                } catch { print("FAIL C2PA \(fmt.rawValue): \(error)") }
            }
            // unsigned file → no credentials
            let plain = out.appendingPathComponent("neural_c2pa_unsigned.png")
            try? DocumentIO.export(st, to: plain, format: .png, quality: 1, scale: 1)
            if case .failure(let e) = ContentCredentials.read(plain) { print("  unsigned file → \(e.localizedDescription)") }
            if T.want("ui") { runUI(out, img) }
            // tamper: flip bytes in the JPEG's image data → validation must fail
            let signed = out.appendingPathComponent("neural_c2pa_signed.jpg")
            if var data = try? Data(contentsOf: signed), data.count > 5000 {
                for i in stride(from: data.count - 3000, to: data.count - 2000, by: 7) { data[i] ^= 0x5A }
                let tampered = out.appendingPathComponent("neural_c2pa_tampered.jpg")
                try? data.write(to: tampered)
                switch ContentCredentials.read(tampered) {
                case .success(let s): print("  tampered JPEG: state=\(s.state) failures=\(s.statusCodes.filter { $0.hasPrefix("✗") || $0.contains("mismatch") })")
                case .failure(let e): print("  tampered JPEG → \(e.localizedDescription)")
                }
            }
        }
    }

    // MARK: Helpers

    static func jpeg(_ cg: CGImage, quality: Double) -> CGImage {
        let d = NSMutableData()
        let dest = CGImageDestinationCreateWithData(d, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let src = CGImageSourceCreateWithData(d, nil)!
        return CGImageSourceCreateImageAtIndex(src, 0, nil)!
    }

    static func motionBlur(_ cg: CGImage, _ n: Int) -> CGImage {
        let p = PlanarImage.rgb(cg)
        var o = p
        let w = p.width, h = p.height
        for c in 0..<3 { for y in 0..<h { for x in 0..<w {
            var s: Float = 0
            for k in -(n / 2)...(n / 2) { s += p.data[c * w * h + y * w + max(0, min(w - 1, x + k))] }
            o.data[c * w * h + y * w + x] = s / Float(n)
        } } }
        return o.cgImage()
    }

    static func oldPhoto(_ cg: CGImage) -> CGImage {
        let sep = NImg.cg(CIImage(cgImage: cg).applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.8]))!
        let noisy = T.addNoise(sep, sigma: 12)
        let buf = PixelBuffer(cgImage: noisy)
        let c = buf.context
        var seed: UInt64 = 7
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        for i in 0..<9 {
            let x0 = rnd() * Double(buf.width), y0 = rnd() * Double(buf.height) * 0.3
            let p = CGMutablePath(); p.move(to: CGPoint(x: x0, y: y0))
            p.addCurve(to: CGPoint(x: x0 + (rnd() - 0.5) * 120, y: y0 + Double(buf.height) * (0.4 + rnd() * 0.5)),
                       control1: CGPoint(x: x0 + (rnd() - 0.5) * 80, y: y0 + 80), control2: CGPoint(x: x0 + (rnd() - 0.5) * 80, y: y0 + 200))
            c.addPath(p); c.setLineWidth(i % 3 == 0 ? 2 : 1.2)
            c.setStrokeColor(gray: i % 4 == 0 ? 0.1 : 0.95, alpha: 0.9); c.strokePath()
        }
        for _ in 0..<40 { c.setFillColor(gray: 0.95, alpha: 0.9); c.fillEllipse(in: CGRect(x: rnd() * Double(buf.width), y: rnd() * Double(buf.height), width: 2.5, height: 2.5)) }
        buf.markDirty()
        return buf.makeCGImage()
    }
}

extension NeuralSelfTest {
    /// Non-throwing variant of `sync`.
    static func sync2<T>(_ body: @escaping () async -> T) -> T {
        var result: T?
        Task.detached { result = await body() }
        while result == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        return result!
    }
}

extension NeuralSelfTest2 {
    /// Scratch-detector accuracy on the synthetic old photo (draws the ground truth separately).
    static func scratchStats(_ clean: CGImage) {
        let old = oldPhoto(clean)
        let m = ScratchReduction.mask(old, amount: 0.8)
        // ground truth: pixels that differ strongly from the clean sepia+noise version
        let base = PlanarImage.rgb(T.addNoise(NImg.cg(CIImage(cgImage: clean).applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.8]))!, sigma: 12))
        let o = PlanarImage.rgb(old)
        let n = o.width * o.height
        var gt = 0, hit = 0, area = 0
        for i in 0..<n {
            let d = abs(o.data[i] - base.data[i]) + abs(o.data[n + i] - base.data[n + i]) + abs(o.data[2 * n + i] - base.data[2 * n + i])
            if d > 0.3 { gt += 1; if m.data[i] > 0.5 { hit += 1 } }
            if m.data[i] > 0.5 { area += 1 }
        }
        print(String(format: "  scratch detector: recall %.1f%%, mask area %.2f%% (scratch pixels %.2f%%)", 100 * Double(hit) / Double(max(1, gt)), 100 * Double(area) / Double(n), 100 * Double(gt) / Double(n)))
    }
}
