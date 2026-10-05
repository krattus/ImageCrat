import SwiftUI
import CoreImage
import Vision
import ImageCratCore

/// Remove tool upgrade: generative (on-device LaMa) fill and Find Distractions (people, wires & cables).
@Observable
final class NeuralRemove {
    static let shared = NeuralRemove()

    enum Mode: String, CaseIterable, Identifiable {
        case generative = "Generative (on-device LaMa)"
        case contentAware = "Content-Aware (PatchMatch)"
        var id: String { rawValue }
    }

    enum Distraction: String, CaseIterable { case people = "People", wires = "Wires & Cables" }

    /// nil = automatic (generative when LaMa is installed).
    var modeOverride: Mode? = UserDefaults.standard.string(forKey: "Lumen.RemoveMode").flatMap(Mode.init(rawValue:)) {
        didSet { UserDefaults.standard.set(modeOverride?.rawValue, forKey: "Lumen.RemoveMode") }
    }
    var mode: Mode { modeOverride ?? (LamaInpainter.isAvailable ? .generative : .contentAware) }
    var busy = false
    var message = ""

    // MARK: Remove stroke (called by RemoveTool)

    /// Handles a Remove stroke with LaMa. Returns false to let the tool use Content-Aware Fill.
    static func removeStroke(_ d: Document, layerID: UUID, hole: PixelBuffer, sampleAll: Bool) -> Bool {
        let s = shared
        guard s.mode == .generative else { return false }
        if !LamaInpainter.isAvailable {
            // fetch the model for next time, fill with PatchMatch now
            AppModel.shared.setStatus("Downloading LaMa for generative Remove… (using Content-Aware Fill meanwhile)")
            Task {
                do { try await ModelManager.shared.ensure(NeuralModelID.lama) }
                catch { await MainActor.run { AppModel.shared.setStatus("Generative Remove: \(error.localizedDescription) (using Content-Aware Fill)") } }
            }
            return false
        }
        // LaMa likes a generous mask
        let grown = SelectionOps.expand(hole, by: max(4, Double(max(d.state.width, d.state.height)) / 300))
        fill(d, layerID: layerID, hole: grown, sampleAll: sampleAll, name: "Remove")
        return true
    }

    /// Fills `hole` (canvas-size gray) on a raster layer with LaMa, asynchronously; commits `name`.
    static func fill(_ d: Document, layerID: UUID, hole: PixelBuffer, sampleAll: Bool, name: String, completion: ((Bool) -> Void)? = nil) {
        guard let l = d.state.layer(layerID), l.isRaster else { completion?(false); return }
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        let srcImg: CIImage = sampleAll ? Compositor.shared.composite(d.committedState) : (Compositor.shared.contentImage(l, space: space) ?? CIImage.clearImage)
        guard let src = NImg.cg(srcImg.cropped(to: space.ciCanvas).composited(over: CIImage.clearImage.cropped(to: space.ciCanvas)), rect: space.ciCanvas) else { completion?(false); return }
        let holeP = PlanarImage.gray(hole.makeCGImage())
        shared.busy = true
        AppModel.shared.setStatus("Removing (LaMa)…")
        Task.detached {
            do {
                let t0 = CFAbsoluteTimeGetCurrent()
                let filled = try await LamaInpainter.inpaint(src, hole: holeP)
                let dt = CFAbsoluteTimeGetCurrent() - t0
                await MainActor.run {
                    write(filled, into: d, layerID: layerID, hole: hole, replace: !sampleAll)
                    d.commit(name)
                    d.setNeedsRender()
                    shared.busy = false
                    AppModel.shared.setStatus(String(format: "%@ done (%.1f s)", name, dt))
                    completion?(true)
                }
            } catch {
                await MainActor.run {
                    shared.busy = false
                    AppModel.shared.setStatus("Remove failed: \(error.localizedDescription)")
                    completion?(false)
                }
            }
        }
    }

    /// Writes a canvas-size image into the layer inside the (feathered) hole.
    static func write(_ img: CGImage, into d: Document, layerID: UUID, hole: PixelBuffer, replace: Bool) {
        guard let (w, o) = d.beginPixelEdit(layerID: layerID, target: .content) else { return }
        let soft = SelectionOps.feather(hole, radius: 1)
        let ctx = w.context
        ctx.saveGState()
        w.clip(toMask: soft.makeCGImage(), in: CGRect(x: -o.x, y: -o.y, width: d.state.width, height: d.state.height))
        if replace { ctx.setBlendMode(.copy) }
        w.drawImage(img, in: CGRect(x: -o.x, y: -o.y, width: d.state.width, height: d.state.height))
        ctx.restoreGState()
        w.markDirty()
    }

    // MARK: Find Distractions

    /// Canvas-size mask of distractions of `kind` in `cg`.
    static func distractionMask(_ cg: CGImage, kind: Distraction) -> PlanarImage? {
        switch kind {
        case .people: return peopleMask(cg)
        case .wires: return WireDetector.detect(cg)
        }
    }

    /// People instances except the main subject (the largest, most central one) when several are present;
    /// a single person is only returned when small (< 6% of the frame).
    static func peopleMask(_ cg: CGImage) -> PlanarImage? {
        let req = VNGeneratePersonInstanceMaskRequest()
        let h = VNImageRequestHandler(cgImage: cg)
        guard (try? h.perform([req])) != nil, let obs = req.results?.first else { return nil }
        let W = cg.width, H = cg.height
        var instances: [(Int, PlanarImage, Double)] = []
        for i in obs.allInstances {
            guard let pb = try? obs.generateScaledMaskForImage(forInstances: IndexSet(integer: i), from: h) else { continue }
            let ci = CIImage(cvPixelBuffer: pb)
            let sc = ci.transformed(by: CGAffineTransform(scaleX: CGFloat(W) / ci.extent.width, y: CGFloat(H) / ci.extent.height))
            guard let g = NImg.grayCG(sc, rect: CGRect(x: 0, y: 0, width: W, height: H)) else { continue }
            let p = PlanarImage.gray(g)
            let area = Double(p.data.reduce(0, +)) / Double(W * H)
            instances.append((i, p, area))
        }
        guard !instances.isEmpty else { return nil }
        var chosen = instances
        if instances.count > 1 {
            let main = instances.max { $0.2 < $1.2 }!
            chosen = instances.filter { $0.0 != main.0 }
        } else if instances[0].2 > 0.06 {
            return nil
        }
        var m = PlanarImage(width: W, height: H, channels: 1)
        for (_, p, _) in chosen { for i in m.data.indices { m.data[i] = max(m.data[i], p.data[i] > 0.4 ? 1 : 0) } }
        let grow = max(3, max(W, H) / 150)
        return MaskMath.dilate(m, grow)
    }

    /// Finds distractions in the document and selects them (so they can be reviewed / refined), then optionally removes them.
    @MainActor
    static func findDistractions(_ kind: Distraction, remove: Bool) {
        guard let d = AppActions.doc, let id = d.activeLayerID else { return }
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        guard let cg = NImg.cg(Compositor.shared.composite(d.committedState).composited(over: CIImage.color(.white, space.ciCanvas)), rect: space.ciCanvas) else { return }
        shared.busy = true
        AppModel.shared.setStatus("Finding \(kind.rawValue.lowercased())…")
        Task.detached {
            let m = distractionMask(cg, kind: kind)
            await MainActor.run {
                shared.busy = false
                guard let m, m.data.contains(where: { $0 > 0.5 }) else {
                    AppModel.shared.setStatus("No \(kind.rawValue.lowercased()) found.")
                    shared.message = "No \(kind.rawValue.lowercased()) found."
                    return
                }
                let buf = PixelBuffer(cgImage: m.cgImage(), format: .gray)
                d.setSelection(buf, commitName: "Find Distractions: \(kind.rawValue)")
                shared.message = "\(kind.rawValue) selected."
                if remove { removeSelection() } else { AppModel.shared.setStatus("\(kind.rawValue) selected — click Remove to fill.") }
                _ = id
            }
        }
    }

    /// Fills the current selection on the active layer (LaMa, or Content-Aware Fill).
    @MainActor
    static func removeSelection() {
        guard let d = AppActions.doc, let id = d.activeLayerID, let sel = d.state.selection else { Beep.play(); return }
        guard let l = d.state.layer(id), l.isRaster else { AppActions.offerRasterize(layer: id); return }
        let hole = SelectionOps.expand(sel, by: 2)
        if shared.mode == .generative && LamaInpainter.isAvailable {
            fill(d, layerID: id, hole: hole, sampleAll: AppModel.shared.removeSampleAll, name: "Remove Distractions") { ok in
                if ok { d.setSelection(nil, commitName: nil) }
            }
        } else {
            Healing.contentAwareFill(d, layerID: id, hole: hole, sampleAll: AppModel.shared.removeSampleAll, name: "Remove Distractions")
        }
    }
}

/// Options-bar controls for the Remove tool (mode, Find Distractions).
struct NeuralRemoveOptions: View {
    @Bindable var nr = NeuralRemove.shared
    @Bindable var mm = ModelManager.shared
    var body: some View {
        Picker("", selection: Binding(get: { nr.mode }, set: { nr.modeOverride = $0 })) {
            ForEach(NeuralRemove.Mode.allCases) { Text($0.rawValue).tag($0) }
        }.labelsHidden().frame(width: 230)
        if nr.mode == .generative && !LamaInpainter.isAvailable {
            if let p = mm.progress[NeuralModelID.lama] { ProgressView(value: p).frame(width: 60) } else {
                Button("Get LaMa (95 MB)") {
                    Task {
                        do { try await mm.ensure(NeuralModelID.lama) }
                        catch { await MainActor.run { AppModel.shared.setStatus(error.localizedDescription) } }
                    }
                }.buttonStyle(PanelButtonStyle())
            }
        }
        Menu("Find Distractions") {
            ForEach(NeuralRemove.Distraction.allCases, id: \.self) { k in
                Button("Select \(k.rawValue)") { NeuralRemove.findDistractions(k, remove: false) }
                Button("Remove \(k.rawValue)") { NeuralRemove.findDistractions(k, remove: true) }
            }
            Divider()
            Button("Remove Selection") { NeuralRemove.removeSelection() }
        }.frame(width: 150).disabled(nr.busy)
        if nr.busy { ProgressView().controlSize(.small) }
    }
}

// MARK: - Wires & cables

enum WireDetector {
    /// Canvas-size mask (1 = wire) of long thin high-contrast structures (straight or sagging) whose two sides look
    /// alike (so object edges and horizons are ignored).
    static func detect(_ cg: CGImage) -> PlanarImage {
        let W = cg.width, H = cg.height
        let sc = min(1, 1000 / Double(max(W, H)))
        let w = max(8, Int(Double(W) * sc)), h = max(8, Int(Double(H) * sc))
        let lum = NeuralTensor.luminance(PlanarImage.rgb(cg, width: w, height: h))
        let resp = ThinStructures.lineResponse(lum, r: 3, darkWeight: 1, brightWeight: 0.8)
        // adaptive threshold: well above the local texture level
        let local = MaskMath.boxBlur(resp, 12)
        var bin = PlanarImage(width: w, height: h, channels: 1)
        for i in bin.data.indices { bin.data[i] = resp.data[i] > max(0.045, local.data[i] * 2.2) ? 1 : 0 }
        var keep = PlanarImage(width: w, height: h, channels: 1)
        let minLen = Double(max(w, h)) * 0.12
        // 1) elongated thin components with similar sides
        for c in ThinStructures.components(bin) where c.length >= minLen && c.thickness <= 4.5 {
            if ThinStructures.sideDifference(c, lum: lum, offset: 5) > 0.06 { continue }
            for p in c.pixels { keep.data[Int(p)] = 1 }
        }
        // 2) straight lines (Hough) to bridge gaps where wires cross textured areas
        for (theta, rho) in hough(bin, minVotes: Int(Double(max(w, h)) * 0.25)) {
            let cth = cos(theta), sth = sin(theta)
            var pts: [Int32] = []
            if abs(sth) > abs(cth) {
                for x in 0..<w { let y = Int(((rho - Double(x) * cth) / sth).rounded()); if y >= 0 && y < h { pts.append(Int32(y * w + x)) } }
            } else {
                for y in 0..<h { let x = Int(((rho - Double(y) * sth) / cth).rounded()); if x >= 0 && x < w { pts.append(Int32(y * w + x)) } }
            }
            var line = ThinStructures.Component(pixels: pts, x0: 0, y0: 0, x1: w - 1, y1: h - 1)
            line.pixels = pts
            if ThinStructures.sideDifference(line, lum: lum, offset: 5) > 0.06 { continue }
            for p in pts {
                let x = Int(p) % w, y = Int(p) / w
                for dy in -1...1 { for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    if xx >= 0, yy >= 0, xx < w, yy < h, resp.data[yy * w + xx] > 0.02 { keep.data[yy * w + xx] = 1 }
                } }
            }
        }
        let grown = MaskMath.dilate(keep, 1)
        var full = grown.resizedFloat(W, H)
        for i in full.data.indices { full.data[i] = full.data[i] > 0.2 ? 1 : 0 }
        return MaskMath.dilate(full, max(1, Int(1.5 / sc)))
    }

    /// Hough transform on a binary image; returns (theta, rho) of peaks (non-maximum suppressed).
    static func hough(_ bin: PlanarImage, minVotes: Int, maxLines: Int = 12) -> [(Double, Double)] {
        let w = bin.width, h = bin.height
        let nT = 360
        let diag = Int(hypot(Double(w), Double(h))) + 1
        let nR = 2 * diag + 1
        var acc = [Int32](repeating: 0, count: nT * nR)
        var cosT = [Double](repeating: 0, count: nT), sinT = cosT
        for t in 0..<nT { let a = Double(t) * .pi / Double(nT); cosT[t] = cos(a); sinT[t] = sin(a) }
        acc.withUnsafeMutableBufferPointer { a in
            bin.data.withUnsafeBufferPointer { b in
                for y in 0..<h {
                    for x in 0..<w where b[y * w + x] > 0.5 {
                        for t in 0..<nT {
                            let r = Int((Double(x) * cosT[t] + Double(y) * sinT[t]).rounded()) + diag
                            a[t * nR + r] += 1
                        }
                    }
                }
            }
        }
        var peaks: [(Int32, Int, Int)] = []
        for t in 0..<nT {
            for r in 0..<nR where acc[t * nR + r] >= Int32(minVotes) {
                let v = acc[t * nR + r]
                var isMax = true
                loop: for dt in -4...4 { for dr in -6...6 {
                    let tt = (t + dt + nT) % nT, rr = r + dr
                    if rr < 0 || rr >= nR || (dt == 0 && dr == 0) { continue }
                    if acc[tt * nR + rr] > v { isMax = false; break loop }
                } }
                if isMax { peaks.append((v, t, r)) }
            }
        }
        peaks.sort { $0.0 > $1.0 }
        return peaks.prefix(maxLines).map { (Double($0.1) * .pi / Double(nT), Double($0.2 - diag)) }
    }
}
