import AppKit
import CoreImage
import ImageCratCore

extension SelfTest {
    /// Vectors, layer workflow and colour tests.
    static func runWorkflowTests(_ out: URL) {
        let only = ProcessInfo.processInfo.environment["LUMEN_SELFTEST_ONLY"]
        func want(_ n: String) -> Bool { only == nil || n.hasPrefix(only!) }
        if want("vec") {
            var st = baseState()
            // live boolean: rect minus ellipse, plus intersect & exclude variants
            let ops: [PathOperation] = [.combine, .subtract, .intersect, .exclude]
            for (i, op) in ops.enumerated() {
                var p = VectorPath.rect(CGRect(x: 15 + CGFloat(i) * 115, y: 30, width: 80, height: 80))
                p.subpaths += VectorPath.ellipse(CGRect(x: 55 + CGFloat(i) * 115, y: 60, width: 60, height: 60)).withOperation(op).subpaths
                var sc = ShapeContent(geometry: .path(p), fill: .color(RGBA(hex: "2E86AB")!))
                sc.stroke = StrokeStyle(paint: .color(.black), width: 2, alignment: .center)
                st.layers.append(Layer(name: "op\(i)", content: .shape(sc)))
            }
            // library shapes row
            for (i, id) in ["heart", "ring", "arrowR", "bubble", "moon", "sun", "puzzle", "pin"].enumerated() {
                let r = CGRect(x: 12 + CGFloat(i) * 58, y: 160, width: 50, height: 50)
                st.layers.append(Layer(name: id, content: .shape(ShapeContent(geometry: .library(id, r), fill: .color(RGBA(hex: "E94F37")!)))))
            }
            // live rounded rect under perspective, then radius edited afterwards
            var l = shapeLayer(CGRect(x: 60, y: 225, width: 140, height: 60), RGBA(hex: "3BB273")!, radius: 10)
            let sp = CanvasSpace(width: st.width, height: st.height)
            let q = Quad(rect: CGRect(x: 60, y: 225, width: 140, height: 60))
            let q2 = Quad(tl: CGPoint(x: 80, y: 225), tr: CGPoint(x: 180, y: 225), br: CGPoint(x: 220, y: 290), bl: CGPoint(x: 40, y: 290))
            if let h = Homography(from: q, to: q2) { l = LayerTransformer.apply(h, to: l, space: sp) }
            if var s = l.shape, case .rectangle(let r, _) = s.geometry { s.geometry = .rectangle(r, cornerRadius: 28); l.content = .shape(s) }
            st.layers.append(l)
            save(st, "vec_boolean_library", out)
        }
        if want("caf") {
            let st = baseState()
            let buf = PixelBuffer(width: st.width, height: st.height)
            let ctx = buf.context
            for i in stride(from: -300, to: 800, by: 24) {
                ctx.setFillColor(RGBA(hex: i / 24 % 2 == 0 ? "D96C3F" : "F2E3C6")!.cgColor)
                ctx.move(to: CGPoint(x: i, y: 0)); ctx.addLine(to: CGPoint(x: i + 12, y: 0)); ctx.addLine(to: CGPoint(x: i + 312, y: 300)); ctx.addLine(to: CGPoint(x: i + 300, y: 300)); ctx.fillPath()
            }
            ctx.setFillColor(RGBA(hex: "1E5AA8")!.cgColor); ctx.fillEllipse(in: CGRect(x: 200, y: 100, width: 90, height: 90))
            buf.markDirty()
            let hole = SelectionOps.mask(fromPath: CGPath(ellipseIn: CGRect(x: 190, y: 90, width: 110, height: 110), transform: nil), width: st.width, height: st.height)
            let filled = Inpainter.inpaint(buf, hole: hole)
            var s2 = st; s2.layers = [Layer.raster(name: "L", buffer: filled)]
            save(s2, "caf_patchmatch", out)
        }
        if want("color") {
            var st = baseState()
            st.layers.append(shapeLayer(CGRect(x: 40, y: 40, width: 120, height: 120), RGBA(r: 0, g: 1, b: 0.2)))
            st.layers.append(shapeLayer(CGRect(x: 180, y: 40, width: 120, height: 120), RGBA(r: 0.1, g: 0.2, b: 1)))
            st.layers.append(shapeLayer(CGRect(x: 320, y: 40, width: 120, height: 120), RGBA(r: 1, g: 0.55, b: 0.1)))
            let sp = CanvasSpace(width: st.width, height: st.height)
            let comp = Compositor.shared.composite(st)
            let proof = ProofSettings()
            func saveImg(_ img: CIImage, _ n: String) {
                var s2 = DocumentState(width: st.width, height: st.height)
                s2.layers = [Layer.raster(name: "L", buffer: RenderEngine.renderBuffer(img.cropped(to: sp.ciCanvas), docRect: st.canvasRect, space: sp))]
                save(s2, n, out)
            }
            saveImg(ColorConvert.softProof(comp, settings: proof), "color_softproof_cmyk")
            saveImg(ColorConvert.gamutWarning(comp, settings: proof), "color_gamut_warning")
            let flat = comp.composited(over: CIImage.color(.white, sp.ciCanvas)).cropped(to: sp.ciCanvas)
            if let k = ColorConvert.labChannelKernel?.apply(extent: sp.ciCanvas, arguments: [flat, Float(1)]) { saveImg(k, "color_lab_a") }
            if let k = ColorConvert.cmykChannelKernel?.apply(extent: sp.ciCanvas, arguments: [flat, Float(1)]) { saveImg(k, "color_ink_magenta") }
            // assign vs convert Adobe RGB
            saveImg(ColorConvert.displayImage(comp, profile: "Adobe RGB (1998)"), "color_assign_adobergb")
            // CMYK and 16-bit export
            var cm = st; cm.colorMode = .cmyk
            let cmURL = out.appendingPathComponent("color_cmyk.jpg")
            try? DocumentIO.export(cm, to: cmURL, format: .jpeg, quality: 0.9, scale: 1)
            if let src = CGImageSourceCreateWithURL(cmURL as CFURL, nil), let im = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                print("color_cmyk.jpg model:", im.colorSpace?.model == .cmyk ? "CMYK" : "other", "components:", im.colorSpace?.numberOfComponents ?? 0)
            }
            var hb = st; hb.bitDepth = .sixteen
            let hbURL = out.appendingPathComponent("color_16bit.png")
            try? DocumentIO.export(hb, to: hbURL, format: .png, quality: 1, scale: 1)
            if let src = CGImageSourceCreateWithURL(hbURL as CFURL, nil), let im = CGImageSourceCreateImageAtIndex(src, 0, nil) { print("color_16bit.png bitsPerComponent:", im.bitsPerComponent) }
            try? DocumentIO.exportEXR(st, to: out.appendingPathComponent("color_32bit.exr"))
            if let src = CGImageSourceCreateWithURL(out.appendingPathComponent("color_32bit.exr") as CFURL, nil), let im = CGImageSourceCreateImageAtIndex(src, 0, nil) { print("color_32bit.exr bitsPerComponent:", im.bitsPerComponent) }
            print("profiles available:", ColorProfiles.all.count, "cmyk:", ColorProfiles.cmykProfiles.count)
        }
        if want("workflow") {
            // artboards + comps + actions through the app model
            let app = AppModel.shared
            let d = Document(state: baseState(), name: "wf")
            app.documents.append(d); app.activeDocumentID = d.id
            AppActions.newArtboard(size: CGSize(width: 200, height: 150))
            let abID = d.activeLayerID!
            let inner = shapeLayer(CGRect(x: 120, y: 80, width: 200, height: 120), RGBA(hex: "E94F37")!)
            d.state.updateLayer(abID) { l in if case .group(var g) = l.content { g.children.append(inner); l.content = .group(g) } }   // (the first artboard holds the Background)
            AppActions.newArtboard(size: CGSize(width: 180, height: 150))
            if let ab2 = d.activeLayerID { d.state.updateLayer(ab2) { l in if case .group(var g) = l.content { g.artboard?.background = RGBA(hex: "2E86AB"); g.children = [shapeLayer(CGRect(x: 520, y: 20, width: 80, height: 80), .white)]; l.content = .group(g) } } }
            d.commit("test")
            save(d.state, "workflow_artboards", out)
            if let ab = d.state.layer(abID), let s1 = AppActions.artboardState(d.state, ab) { save(s1, "workflow_artboard1_export", out) }
            print("artboard canvas:", d.state.width, "x", d.state.height)
            // linked layers move together
            let a = shapeLayer(CGRect(x: 10, y: 10, width: 30, height: 30)), b = shapeLayer(CGRect(x: 50, y: 10, width: 30, height: 30))
            d.state.layers.append(a); d.state.layers.append(b)
            d.selectedLayerIDs = [a.id, b.id]
            AppActions.toggleLinkLayers()
            print("linked:", d.withLinked([a.id]).count == 2 ? "ok" : "FAIL")
            // comps
            AppActions.newLayerComp()
            let c1 = d.state.layerComps.last!.id
            d.state.updateLayer(a.id) { $0.isVisible = false; $0.translate(dx: 40, dy: 40) }
            d.commit("change")
            AppActions.applyLayerComp(c1)
            let back = d.state.layer(a.id)!
            print("comp restore:", back.isVisible && abs((Compositor.shared.contentBounds(back, state: d.state)?.minX ?? 0) - 10) < 2 ? "ok" : "FAIL")
            // actions: record then play
            let rec = ActionRecorder.shared
            let aid = rec.newAction(name: "Test")
            rec.recordingActionID = aid
            if let bg = d.state.allLayers.first(where: { $0.isRaster }) { d.selectLayer(bg.id) }
            AppActions.invertActive()
            rec.recordingActionID = nil
            print("recorded steps:", rec.action(aid)?.steps.map(\.title) ?? [])
            rec.play(aid, interactive: false)
            rec.delete(aid)
            app.documents.removeAll { $0.id == d.id }
        }
        if want("face") {
            let st = baseState(400, 400)
            let buf = PixelBuffer(width: 400, height: 400)
            let c = buf.context
            c.setFillColor(RGBA(hex: "F2C9A0")!.cgColor); c.fillEllipse(in: CGRect(x: 80, y: 50, width: 240, height: 300))
            c.setFillColor(RGBA(hex: "3A2A1A")!.cgColor)
            c.fillEllipse(in: CGRect(x: 135, y: 150, width: 40, height: 22)); c.fillEllipse(in: CGRect(x: 225, y: 150, width: 40, height: 22))
            c.setStrokeColor(RGBA(hex: "B5462F")!.cgColor); c.setLineWidth(8)
            c.move(to: CGPoint(x: 160, y: 270)); c.addLine(to: CGPoint(x: 240, y: 270)); c.strokePath()
            c.setStrokeColor(RGBA(hex: "C99A70")!.cgColor); c.setLineWidth(5)
            c.move(to: CGPoint(x: 200, y: 180)); c.addLine(to: CGPoint(x: 190, y: 230)); c.addLine(to: CGPoint(x: 210, y: 230)); c.strokePath()
            buf.markDirty()
            func ring(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> [CGPoint] { (0..<8).map { i in let a = CGFloat(i) / 8 * 2 * .pi; return CGPoint(x: cx + cos(a) * rx, y: cy + sin(a) * ry) } }
            let face = FaceLandmarks(bounds: CGRect(x: 80, y: 90, width: 240, height: 260), leftEye: ring(155, 161, 20, 11), rightEye: ring(245, 161, 20, 11),
                                     nose: [CGPoint(x: 200, y: 180), CGPoint(x: 190, y: 230), CGPoint(x: 210, y: 230)], outerLips: ring(200, 270, 42, 10), contour: [])
            let sp = CanvasSpace(width: 400, height: 400)
            var out2 = st
            for (name, fs) in [("face_eyes", FaceAwareSettings(eyeSize: 100)), ("face_smile", FaceAwareSettings(smile: 100, mouthWidth: 60)), ("face_narrow", FaceAwareSettings(jawline: -100, faceWidth: -100))] {
                let f = DisplacementField(width: 400, height: 400)
                f.applyFaces([face], fs)
                let img = f.warp(buf.ciImage, space: sp)
                out2.layers = [st.layers[0], Layer.raster(name: "F", buffer: RenderEngine.renderBuffer(img.cropped(to: sp.ciCanvas), docRect: st.canvasRect, space: sp))]
                save(out2, name, out)
            }
            out2.layers = [st.layers[0], Layer.raster(name: "F", buffer: buf)]
            save(out2, "face_source", out)
            // freeze: forward warp across a frozen half
            let f = DisplacementField(width: 400, height: 400)
            for gy in 0..<f.gh { for gx in 0..<(f.gw / 2) { f.frozen[gy * f.gw + gx] = 1 } }
            for i in 0..<30 { f.apply(mode: .forward, center: CGPoint(x: 150 + i * 3, y: 200), delta: CGPoint(x: 3, y: 0), radius: 120, pressure: 1) }
            out2.layers = [st.layers[0], Layer.raster(name: "F", buffer: RenderEngine.renderBuffer(f.warp(buf.ciImage, space: sp).cropped(to: sp.ciCanvas), docRect: st.canvasRect, space: sp))]
            save(out2, "face_freeze_left", out)
        }
        if want("place") {
            let app = AppModel.shared
            let d = Document(state: baseState(), name: "place")
            app.documents.append(d); app.activeDocumentID = d.id
            // a small file to place
            let src = out.appendingPathComponent("place_src.png")
            var s1 = DocumentState(width: 120, height: 80); s1.layers = [shapeLayer(CGRect(x: 0, y: 0, width: 120, height: 80), RGBA(hex: "E94F37")!, radius: 0)]
            try? DocumentIO.export(s1, to: src, format: .png, quality: 1, scale: 1)
            AppActions.place([src], linked: false)
            let emb = d.activeLayer?.smart
            print("place embedded:", emb != nil && emb?.linkedURL == nil ? "ok" : "FAIL")
            AppActions.place([src], linked: true)
            let lid = d.activeLayerID!
            print("place linked:", d.activeLayer?.smart?.linkedURL == src ? "ok" : "FAIL")
            // change the file on disk → linked layer updates, embedded doesn't
            Thread.sleep(forTimeInterval: 1.1)
            s1.layers = [shapeLayer(CGRect(x: 0, y: 0, width: 120, height: 80), RGBA(hex: "2E86AB")!, radius: 0)]
            try? DocumentIO.export(s1, to: src, format: .png, quality: 1, scale: 1)
            let n = AppActions.updateModifiedLinkedContent(d)
            var c: Double? = nil
            if case .image(let b)? = d.state.layer(lid)?.smart?.source { c = Double(b.pixel(60, 40).2) / 255 }
            print("linked refresh:", n == 1 && (c ?? 0) > 0.5 ? "ok" : "FAIL (\(n) \(String(describing: c)))")
            save(d.state, "place_embedded_and_linked", out)
            app.documents.removeAll { $0.id == d.id }
        }
    }
}
