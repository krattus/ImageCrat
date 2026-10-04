import AppKit
import SwiftUI
import CoreImage
import Observation
import ImageCratCore

/// Observable state shared between the editor dialog, the on-canvas handles and the preview pipeline.
@Observable
final class ParticleEditorState {
    var effect: ParticleEffect
    /// Selected top-level system and whether its sub-emitter is being edited.
    var selected = 0
    var editSub = false
    var presetID: String?
    var particles = 0
    var instances = 0
    var simMS = 0.0
    var renderMS = 0.0
    /// "Particle Brush": dragging on the canvas draws the emission path of the selected system.
    var drawPath = false
    var status = ""
    var playing = false
    var isReedit = false
    var subjectAvailable = false
    var depthAvailable = false

    init(effect: ParticleEffect) { self.effect = effect }

    var system: ParticleSystemSettings {
        get {
            guard effect.systems.indices.contains(selected) else { return ParticleSystemSettings() }
            let s = effect.systems[selected]
            if editSub, let c = s.sub.first { return c }
            return s
        }
        set {
            guard effect.systems.indices.contains(selected) else { return }
            if editSub, !effect.systems[selected].sub.isEmpty { effect.systems[selected].sub[0] = newValue } else { effect.systems[selected] = newValue }
        }
    }
}

/// Settings stored inside re-editable particle smart objects.
///
/// The smart object embeds a small document (the rendered particle layers) and the effect's JSON rides along in
/// an alpha channel's name — no change to the document model, survives save / load, and older builds simply
/// see a normal smart object.
enum ParticleStorage {
    static let marker = "lumen.particles.v1:"

    static func effect(in layer: Layer?) -> ParticleEffect? {
        guard let so = layer?.smart, case .document(let st) = so.source else { return nil }
        guard let ch = st.alphaChannels.first(where: { $0.name.hasPrefix(marker) }) else { return nil }
        return ParticleCoding.decode(json: String(ch.name.dropFirst(marker.count)))
    }

    static func embeddedState(_ effect: ParticleEffect, layers: [Layer], width: Int, height: Int) -> DocumentState {
        var st = DocumentState(width: width, height: height)
        st.layers = layers
        st.alphaChannels = [AlphaChannel(name: marker + ParticleCoding.json(effect), buffer: PixelBuffer(width: 1, height: 1, gray: 0))]
        return st
    }
}

/// One editing session: owns the live preview (a display override on the document — the document state is never
/// touched until Apply), the on-canvas handles and the output.
final class ParticleEditor {
    static let dialogID = "particles.editor"
    // Both drive the Particles ▸ Tools items; plain statics are invisible to SwiftUI, so changes bump an observable revision.
    static var current: ParticleEditor? { didSet { ParticleMenuState.shared.revision &+= 1 } }
    /// Settings of the last applied / cancelled session ("Repeat Last", reopening the editor).
    static var lastEffect: ParticleEffect? { didSet { ParticleMenuState.shared.revision &+= 1 } }

    let doc: Document
    let state: ParticleEditorState
    private(set) var ctx: ParticleContext
    let sourceLayerID: UUID?
    let reeditLayerID: UUID?
    let interactive: Bool

    var subjectMask: PixelBuffer? { didSet { state.subjectAvailable = subjectMask != nil } }
    private var previousOverride: ((CIImage) -> CIImage)?
    private var installedOverride = false
    private var maskedLayer: UUID?
    private var hidLayer = false
    private var closed = false
    private let queue = DispatchQueue(label: "lumen.particles.preview", qos: .userInitiated)
    private let genLock = NSLock()
    private var generation = 0
    private var historyToken: UUID?
    private var historyCount = 0
    private var watchdog: Timer?
    private var playTimer: Timer?
    var overlay: ParticleOverlayController?
    private var menuObserver: NSObjectProtocol?
    private var lastSubjectRequest = false, lastDepthRequest = false

    init(doc: Document, effect: ParticleEffect, presetID: String? = nil, reeditLayer: UUID? = nil, interactive: Bool = true) {
        self.doc = doc
        self.interactive = interactive
        reeditLayerID = reeditLayer
        var e = effect
        let src = reeditLayer != nil ? (e.sourceLayerID.flatMap { doc.state.layer($0) != nil ? $0 : nil }) : doc.activeLayerID
        sourceLayerID = src
        if reeditLayer == nil { e.sourceLayerID = src }
        ctx = ParticleContext.capture(doc, layerID: src ?? (reeditLayer == nil ? doc.activeLayerID : nil))
        if reeditLayer != nil, src == nil { ctx.layerAlpha = nil; ctx.layerColor = nil }
        ctx.applyBaked(e)
        state = ParticleEditorState(effect: e)
        state.presetID = presetID
        state.isReedit = reeditLayer != nil
        previousOverride = doc.displayOverride
        historyToken = doc.history.indices.contains(doc.historyIndex) ? doc.history[doc.historyIndex].id : nil
        historyCount = doc.history.count
        if let id = reeditLayer { doc.hiddenLayers.insert(id); hidLayer = true }
    }

    // MARK: Opening

    /// Opens the editor with an effect (or swaps the effect of the session that is already open).
    static func open(_ effect: ParticleEffect, presetID: String? = nil) {
        guard let d = AppActions.doc else { NSSound.beep(); return }
        if let cur = current, !cur.closed, cur.doc === d, cur.reeditLayerID == nil {
            var e = effect
            // keep the output choices of the running session
            let old = cur.state.effect
            e.output = old.output; e.clipToSelection = old.clipToSelection; e.behindSubject = old.behindSubject; e.depthAware = old.depthAware
            e.quality = old.quality; e.sourceLayerID = old.sourceLayerID
            cur.state.selected = 0; cur.state.editSub = false
            cur.state.presetID = presetID
            cur.state.effect = e
            cur.schedulePreview()
            return
        }
        current?.cancel()
        AppActions.canvas?.commitCurrentTool()
        let ed = ParticleEditor(doc: d, effect: effect, presetID: presetID)
        ed.begin()
    }

    static func open(presetID: String) {
        guard let d = AppActions.doc else { NSSound.beep(); return }
        guard let e = ParticlePresets.effect(presetID, aspect: Double(d.state.width) / Double(max(1, d.state.height))) else { return }
        open(e, presetID: presetID)
    }

    /// Re-opens the settings stored in a particle smart object.
    @discardableResult
    static func reedit(layer id: UUID) -> Bool {
        guard let d = AppActions.doc, let e = ParticleStorage.effect(in: d.state.layer(id)) else { return false }
        current?.cancel()
        AppActions.canvas?.commitCurrentTool()
        let ed = ParticleEditor(doc: d, effect: e, reeditLayer: id)
        ed.begin()
        return true
    }

    func begin() {
        ParticleEditor.current = self
        if interactive {
            AppModel.shared.dialog = .custom(ParticleEditor.dialogID)
            if let c = AppActions.canvas { overlay = ParticleOverlayController(editor: self, canvas: c) }
            watchdog = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
            menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.willSendActionNotification, object: nil, queue: nil) { [weak self] note in
                self?.menuWillAct(note)
            }
        }
        schedulePreview()
    }

    // MARK: Safety: never leave a preview behind

    /// Top-level menu an action comes from ("" for pop-up / context menus).
    private static func topLevelTitle(_ menu: NSMenu) -> String {
        var m = menu
        while let s = m.supermenu, s !== NSApp.mainMenu { m = s }
        guard m.supermenu === NSApp.mainMenu else { return "" }
        if let main = NSApp.mainMenu, let i = main.items.firstIndex(where: { $0.submenu === m }), i == 0 { return PendingEdits.appMenu }
        return m.title
    }

    func menuWillAct(_ note: Notification) {
        guard !closed, let menu = note.object as? NSMenu else { return }
        switch ParticleEditor.topLevelTitle(menu) {
        case "", "View", "Window", "Help", PendingEdits.appMenu, "Particles": return
        default:
            // any command that may change the document: drop the preview first (the settings are kept for reopening)
            AppModel.shared.setStatus("Particles editor closed — reopen it with Particles ▸ Particle Editor… (your settings are kept).")
            cancel()
        }
    }

    /// Watchdog (20 Hz while the editor is open): closes the session when the dialog, document or history changed underneath it.
    func tick() {
        guard !closed else { return }
        let app = AppModel.shared
        if app.dialog != .custom(ParticleEditor.dialogID) { cancel(); return }
        if app.activeDocument !== doc { cancel(); return }
        let token = doc.history.indices.contains(doc.historyIndex) ? doc.history[doc.historyIndex].id : nil
        if token != historyToken || doc.history.count != historyCount { cancel(); return }
        if reeditLayerID != nil, !doc.hiddenLayers.contains(reeditLayerID!) { doc.hiddenLayers.insert(reeditLayerID!); doc.setNeedsRender() }
        overlay?.refresh()
    }

    private func teardown() {
        guard !closed else { return }
        closed = true
        genLock.lock(); generation += 1; genLock.unlock()
        watchdog?.invalidate(); watchdog = nil
        playTimer?.invalidate(); playTimer = nil
        if let o = menuObserver { NotificationCenter.default.removeObserver(o); menuObserver = nil }
        overlay?.remove(); overlay = nil
        if installedOverride { doc.displayOverride = previousOverride; installedOverride = false }
        if let id = maskedLayer { doc.contentOverrides.removeValue(forKey: id); maskedLayer = nil }
        if hidLayer, let id = reeditLayerID { doc.hiddenLayers.remove(id); hidLayer = false }
        doc.setNeedsRender()
        ParticleEditor.lastEffect = state.effect
        if ParticleEditor.current === self { ParticleEditor.current = nil }
        if ParticleEditor.current == nil { ParticleRenderer.releaseTargets() }
        if interactive, AppModel.shared.dialog == .custom(ParticleEditor.dialogID) { AppModel.shared.dialog = nil }
    }

    func cancel() { teardown() }

    var isClosed: Bool { closed }

    // MARK: Preview

    var previewScale: Double { min(1, 1800 / Double(max(ctx.width, ctx.height))) }

    /// Gray clip mask (selection and / or "behind subject"), or nil.
    func clipMask(for e: ParticleEffect) -> CIImage? {
        var m: CIImage?
        if e.clipToSelection, let sel = doc.state.selection { m = sel.ciImage }
        if e.behindSubject, let subj = subjectMask {
            let inv = subj.ciImage.inverted()
            m = m.map { $0.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: inv]) } ?? inv
        }
        return m
    }

    /// The part of the source layer that stays visible while it disperses (gray, canvas size), or nil.
    func keepMask(for e: ParticleEffect, time: Double? = nil, ctx c: ParticleContext? = nil) -> PixelBuffer? {
        guard e.maskSourceLayer, sourceLayerID != nil, let i = e.systems.firstIndex(where: { $0.enabled && $0.sweep > 0 }) else { return nil }
        let ctx = c ?? self.ctx
        var cover = ParticleSystem.sweepCoverage(e.systems[i], effect: e, ctx: ctx, index: i, T: time ?? e.time)
        for k in cover.data.indices { cover.data[k] = 1 - cover.data[k] }
        return cover.buffer(width: ctx.width, height: ctx.height)
    }

    private func requestAnalysis() {
        let e = state.effect
        if e.behindSubject, subjectMask == nil, !lastSubjectRequest {
            lastSubjectRequest = true
            state.status = "Finding the subject…"
            if let comp = AppActions.sampleSource(allLayers: true) {
                Task {
                    let mask = try? await SegmentationService.subjectMask(in: comp)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.closed else { return }
                        self.subjectMask = mask
                        self.state.status = mask == nil ? "No subject found — particles are not masked." : ""
                        self.schedulePreview()
                    }
                }
            }
        }
        if e.depthAware, ctx.depth == nil, !lastDepthRequest {
            lastDepthRequest = true
            guard DepthEstimator.isAvailable else { state.status = "Depth-aware placement needs the Depth Anything model (Filter ▸ Neural Filters…)."; return }
            state.status = "Estimating depth…"
            if let cg = Compositor.shared.flatten(doc.state, background: .white) {
                Task {
                    let depth = try? await DepthEstimator.depth(cg)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.closed else { return }
                        if let d = depth {
                            var m = PMap(w: d.width, h: d.height)
                            for i in 0..<(d.width * d.height) { m.data[i] = d.data[i] }
                            self.setDepth(m)
                        }
                        self.state.status = depth == nil ? "Depth estimation failed." : ""
                        self.schedulePreview()
                    }
                }
            }
        }
    }

    /// Installs a scene depth map (0 far … 1 near) used by the depth-aware option.
    func setDepth(_ m: PMap) {
        let c = ParticleContext(width: ctx.width, height: ctx.height)
        c.selection = ctx.selection; c.layerAlpha = ctx.layerAlpha; c.layerColor = ctx.layerColor; c.brightness = ctx.brightness
        c.depth = m.w > 512 ? PMap(buffer: m.buffer(width: m.w, height: m.h), maxDim: 512) : m
        ctx = c
        state.depthAvailable = true
    }

    /// Re-renders the preview on a background queue; stale requests are dropped.
    func schedulePreview() {
        guard !closed else { return }
        if interactive { requestAnalysis() }
        genLock.lock(); generation += 1; let gen = generation; genLock.unlock()
        let e = state.effect
        let c = ctx
        let scale = previewScale
        let work = { [weak self] in
            guard let self else { return }
            self.genLock.lock(); let stale = gen != self.generation; self.genLock.unlock()
            if stale { return }
            let out = ParticleEngine.render(e, ctx: c, scale: scale, preview: true)
            let keep = self.keepMask(for: e, ctx: c)
            let install = { [weak self] in
                guard let self else { return }
                self.install(out, keep: keep, effect: e, gen: gen)
            }
            if Thread.isMainThread { install() } else { DispatchQueue.main.async(execute: install) }
        }
        if interactive { queue.async(execute: work) } else { work() }
    }

    private func install(_ out: ParticleEngine.Output, keep: PixelBuffer?, effect e: ParticleEffect, gen: Int) {
        guard !closed else { return }
        genLock.lock(); let latest = gen == generation; genLock.unlock()
        state.particles = out.particles; state.instances = out.instances
        state.simMS = out.simSeconds * 1000; state.renderMS = out.renderSeconds * 1000
        // intermediate results are shown too (they keep scrubbing responsive), the latest one wins
        _ = latest
        let c = ctx
        let mask = clipMask(for: e)
        let prev = previousOverride
        doc.displayOverride = { comp in
            ParticleEngine.composite(out, over: prev?(comp) ?? comp, effect: e, ctx: c, mask: mask)
        }
        installedOverride = true
        if let id = sourceLayerID, let keep {
            let km = keep.ciImage
            doc.contentOverrides[id] = { img in img.masked(byGray: km) }
            maskedLayer = id
        } else if let id = maskedLayer {
            doc.contentOverrides.removeValue(forKey: id)
            maskedLayer = nil
        }
        doc.setNeedsRender()
    }

    // MARK: Playback (scrubs the moment while the editor is open)

    func togglePlay() {
        if state.playing { playTimer?.invalidate(); playTimer = nil; state.playing = false; return }
        state.playing = true
        playTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self, !self.closed else { return }
            var t = self.state.effect.time + 1.0 / 20
            if t > self.state.effect.duration { t = 0 }
            self.state.effect.time = t
        }
    }

    // MARK: Output

    struct FinalRun {
        var buffer: PixelBuffer
        var blend: PBlend
        var name: String
    }

    /// Full-resolution render of the effect (clip mask applied), one buffer per blend run.
    func renderFinal(_ e: ParticleEffect, time: Double? = nil) -> [FinalRun] {
        let out = ParticleEngine.render(e, ctx: ctx, time: time, scale: 1, preview: false)
        let mask = clipMask(for: e)
        let sp = CanvasSpace(width: ctx.width, height: ctx.height)
        return out.runs.map { r in
            var buf = ParticleRenderer.pixelBuffer(r.texture)
            if let m = mask {
                buf = RenderEngine.renderBuffer(sp.place(buf, at: .zero).masked(byGray: m), docRect: doc.state.canvasRect, space: sp)
            }
            return FinalRun(buffer: buf, blend: r.blend, name: r.name)
        }
    }

    private func layer(_ r: FinalRun, name: String, effect e: ParticleEffect) -> Layer {
        let b = r.buffer.opaqueBounds() ?? IRect(x: 0, y: 0, width: 1, height: 1)
        let buf = b == r.buffer.bounds ? r.buffer : r.buffer.cropped(to: b)
        var l = Layer.raster(name: name, buffer: buf, origin: b.origin)
        l.blendMode = ParticleEngine.layerMode(r.blend, effect: e)
        return l
    }

    /// Layers for the rendered runs: a single layer, or a group when the effect mixes blend modes.
    func outputLayers(_ runs: [FinalRun], name: String, effect e: ParticleEffect) -> Layer {
        if runs.count == 1 { return layer(runs[0], name: name, effect: e) }
        let children = runs.map { layer($0, name: "\(name) – \($0.name)", effect: e) }
        return Layer(name: name, content: .group(GroupContent(children: children)))
    }

    /// Bakes the document-dependent inputs into the settings so a smart object stays re-editable on its own.
    func baked(_ e0: ParticleEffect) -> ParticleEffect {
        var e = e0
        for i in e.systems.indices where e.systems[i].shape.usesMap && e.systems[i].shape != .text {
            let s = e.systems[i]
            var map: PMap?
            switch s.shape {
            case .selectionArea, .selectionOutline: map = ctx.selection
            case .layerAlpha, .layerEdges: map = ctx.layerAlpha
            case .brightness: map = ctx.brightness
            default: break
            }
            if let m = map, !m.isEmpty { e.systems[i].maskPNG = m.pngBase64() }
        }
        if e.systems.contains(where: { $0.colorBase == .image || $0.sub.contains { $0.colorBase == .image } }), let c = ctx.layerColor {
            e.imagePNG = c.pngBase64()
        }
        return e
    }

    private func applySourceMask(_ e: inout ParticleEffect, time: Double? = nil) {
        guard let id = sourceLayerID, let keep = keepMask(for: e, time: time), let l = doc.state.layer(id) else { return }
        if let old = l.mask, !(state.isReedit && e.maskCreated) {
            // combine with the existing mask (canvas-size result)
            let sp = CanvasSpace(width: ctx.width, height: ctx.height)
            let oldImg = sp.place(old.buffer, at: old.origin).composited(over: CIImage.color(RGBA(gray: Double(old.outsideValue) / 255), sp.ciCanvas))
            let combined = keep.ciImage.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: oldImg])
            let buf = RenderEngine.renderBuffer(combined, docRect: doc.state.canvasRect, space: sp, format: .gray)
            doc.updateLayer(id) { $0.mask = LayerMask(buffer: buf, origin: .zero, outsideValue: 0) }
        } else {
            doc.updateLayer(id) { $0.mask = LayerMask(buffer: keep, origin: .zero, outsideValue: 0) }
            e.maskCreated = true
        }
    }

    /// Applies the effect as one history step and closes the editor.
    @discardableResult
    func apply() -> Bool {
        guard !closed else { return false }
        var e = state.effect
        let runs = renderFinal(e)
        guard !runs.isEmpty else { AppModel.shared.setStatus("Nothing to render."); return false }
        let name = e.name.isEmpty ? "Particles" : e.name
        teardown()      // previews off before the document changes
        let d = doc
        let sp = CanvasSpace(width: ctx.width, height: ctx.height)

        if let rid = reeditLayerID, d.state.layer(rid)?.smart != nil {
            applySourceMask(&e)
            let be = baked(e)
            let inner = ParticleStorage.embeddedState(be, layers: runs.map { layer($0, name: $0.name, effect: be) }, width: ctx.width, height: ctx.height)
            d.updateLayer(rid) { l in
                guard var so = l.smart else { return }
                so.source = .document(inner)
                so.sourceRevision = SourceRevision.next()
                l.smart = so
                l.blendMode = ParticleEditor.smartBlend(runs, effect: be)
            }
            d.commit("Edit Particles")
            ParticleEditor.lastEffect = e
            return true
        }

        var output = e.output
        if output == .activeLayer, d.activeLayer?.isRaster != true {
            output = .newLayer
            AppModel.shared.setStatus("The active layer isn't a pixel layer — particles were added as a new layer.")
        }
        switch output {
        case .newLayer:
            applySourceMask(&e)
            d.addLayer(outputLayers(runs, name: name, effect: e))
        case .activeLayer:
            guard let id = d.activeLayerID, let (w, o) = d.beginPixelEdit(layerID: id, target: .content, coverCanvas: true) else { return false }
            var acc = sp.place(w, at: o)
            let ext = acc.extent
            for r in runs { acc = sp.place(r.buffer, at: .zero).blended(over: acc, mode: ParticleEngine.layerMode(r.blend, effect: e)) }
            RenderEngine.render(acc.cropped(to: ext), into: w, docOrigin: o, space: sp)
        case .smartObject:
            applySourceMask(&e)
            let be = baked(e)
            let inner = ParticleStorage.embeddedState(be, layers: runs.map { layer($0, name: $0.name, effect: be) }, width: ctx.width, height: ctx.height)
            var so = SmartObjectContent(source: .document(inner), quad: Quad(rect: d.state.canvasCGRect), sourceName: "Particles – \(name)")
            so.sourceRevision = SourceRevision.next()
            var l = Layer(name: name, content: .smartObject(so))
            l.blendMode = ParticleEditor.smartBlend(runs, effect: be)
            d.addLayer(l)
        }
        d.commit("Particles: \(name)")
        ParticleEditor.lastEffect = e
        return true
    }

    /// Blend mode of a particle smart object (its runs are flattened inside the embedded document).
    static func smartBlend(_ runs: [FinalRun], effect e: ParticleEffect) -> BlendMode {
        let blends = Set(runs.map(\.blend))
        if blends.count == 1, let b = blends.first { return ParticleEngine.layerMode(b, effect: e) }
        return .normal
    }

    // MARK: Animation

    enum AnimationTarget { case frames, timeline }

    /// Times of the animation frames.
    static func frameTimes(_ e: ParticleEffect) -> [Double] {
        let n = max(1, min(600, Int(e.frames.rounded())))
        let fps = max(1, e.fps)
        return (0..<n).map { (e.loop ? 0 : e.animStart) + Double($0) / fps }
    }

    /// Effect prepared for animation rendering (in loop mode the loop length is the animation length).
    static func animationEffect(_ e0: ParticleEffect) -> ParticleEffect {
        var e = e0
        if e.loop { e.duration = max(1, e.frames.rounded()) / max(1, e.fps) }
        return e
    }

    /// Renders every frame into its own layer and wires them into the frame animation or the video timeline.
    @discardableResult
    func animate(_ target: AnimationTarget) -> Bool {
        guard !closed else { return false }
        let e = ParticleEditor.animationEffect(state.effect)
        let times = ParticleEditor.frameTimes(e)
        let name = e.name.isEmpty ? "Particles" : e.name
        var layers: [Layer] = []
        for (i, t) in times.enumerated() {
            let runs = renderFinal(e, time: t)
            guard !runs.isEmpty else { continue }
            layers.append(outputLayers(runs, name: String(format: "%@ %02d", name, i + 1), effect: e))
            state.status = "Rendering frame \(i + 1) of \(times.count)…"
        }
        guard !layers.isEmpty else { return false }
        teardown()
        let d = doc
        let delay = 1 / max(1, e.fps)
        TimelineController.shared.stop()
        var st = d.state
        // insert all frame layers above the active layer (first frame at the bottom)
        var above = d.activeLayerID
        for l in layers {
            st.insertLayer(l, above: above)
            above = l.id
        }
        let ids = layers.map(\.id)
        switch target {
        case .frames:
            st.videoTimeline = nil
            for (k, id) in ids.enumerated() { st.updateLayer(id) { $0.isVisible = k == 0 } }
            let base = Animation.capture(st)
            st.frames = ids.indices.map { k in
                var f = base
                f.id = UUID()
                f.delay = delay
                for (j, id) in ids.enumerated() { f.visibility[id] = j == k }
                return f
            }
            st.animationLoop = .forever
            d.state = st
            TimelineController.shared.selection[d.id] = 0
        case .timeline:
            let total = Double(ids.count) * delay
            var tl: VideoTimeline
            if let existing = st.videoTimeline {
                tl = existing
            } else if st.frames.isEmpty {
                tl = VideoTimeline(duration: total, frameRate: e.fps, tracks: [])
            } else {
                tl = VideoTimelineEngine.timeline(fromFrames: st, frameRate: e.fps)     // keep an existing frame animation as keyframes
            }
            st.frames = []
            if tl.duration < total {
                // full-length clips grow with the timeline
                for i in tl.tracks.indices where abs(tl.tracks[i].end - tl.duration) < 1e-6 && tl.tracks[i].start < 1e-6 { tl.tracks[i].duration = total }
                tl.duration = total
            }
            tl.frameRate = e.fps
            for l in st.allLayers where tl.track(l.id) == nil && !ids.contains(l.id) { tl.tracks.append(LayerTrack(layerID: l.id, duration: tl.duration)) }
            for (k, id) in ids.enumerated() {
                tl.tracks.removeAll { $0.layerID == id }
                tl.tracks.append(LayerTrack(layerID: id, start: Double(k) * delay, duration: delay))
            }
            st.videoTimeline = tl
            VideoTimelineEngine.apply(at: 0, to: &st, decodeVideo: false)
            d.state = st
        }
        d.activeLayerID = ids.last
        d.selectedLayerIDs = ids.last.map { [$0] } ?? []
        d.commit("Particle Animation: \(name)")
        TimelineController.shared.isPanelVisible = true
        ParticleEditor.lastEffect = e
        AppModel.shared.setStatus("\(ids.count) particle frames added to the \(target == .frames ? "frame animation" : "video timeline") — export with File ▸ Export.")
        return true
    }

    /// Writes the animation frames as PNG files (particles on transparent, or over the document).
    @discardableResult
    func exportSequence(to folder: URL, overDocument: Bool) -> [URL] {
        let e = ParticleEditor.animationEffect(state.effect)
        let times = ParticleEditor.frameTimes(e)
        let canvas = CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)
        let backdrop = overDocument ? Compositor.shared.composite(doc.state).cropped(to: canvas) : CIImage.clearImage.cropped(to: canvas)
        let mask = clipMask(for: e)
        var urls: [URL] = []
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (e.name.isEmpty ? "particles" : e.name).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
        for (i, t) in times.enumerated() {
            let out = ParticleEngine.render(e, ctx: ctx, time: t, scale: 1, preview: false)
            let img = ParticleEngine.composite(out, over: backdrop, effect: e, ctx: ctx, mask: mask)
            guard let cg = RenderEngine.cgImage(img, rect: canvas) else { continue }
            let url = folder.appendingPathComponent(String(format: "%@_%04d.png", base, i + 1))
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, cg, nil)
            if CGImageDestinationFinalize(dest) { urls.append(url) }
        }
        return urls
    }
}
