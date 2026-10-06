import AppKit
import CoreGraphics
import CoreImage
import ImageCratCore

/// A region sent to a provider plus everything needed to blend the answer back.
struct GenRegionPlan {
    var rect: IRect                 // doc-space region (may extend beyond the canvas for Expand)
    var source: PixelBuffer         // rect-sized composite
    var regionMask: PixelBuffer?    // rect-sized gray, white = edit (nil = whole region)
    var sendW: Int
    var sendH: Int
    var image: CGImage              // flattened + resized source
    var mask: PixelBuffer?          // send-sized binary provider mask
    var blend: PixelBuffer?         // rect-sized feathered blend mask
    var padding = ExpandPadding()
    var unpadded: CGImage? = nil
}

/// Generative pipeline: plan → provider calls (variations) → local compositing → new layer + metadata.
enum GenPipeline {
    static var settings: GenAISettingsData { GenAISettings.shared.data }
    /// Session-level upload confirmations (privacy option).
    static var confirmedProviders: Set<ProviderID> = []

    // MARK: Planning

    static func plan(state: DocumentState, sel: PixelBuffer?, bbox: IRect? = nil, model: GenModel, clampToCanvas: Bool = true,
                     context: Double = 0.25, feather: Double? = nil, outerBlend: Double = 0, originalRect: IRect? = nil) -> GenRegionPlan {
        let caps = model.caps
        let box = bbox ?? sel?.opaqueBounds() ?? state.canvasRect
        let clamp: IRect? = clampToCanvas ? state.canvasRect : nil
        var rect = sel == nil && bbox == nil ? state.canvasRect : GenImaging.contextRect(around: box, context: context, clampTo: clamp)
        let a = Double(rect.width) / Double(max(1, rect.height))
        let ca = min(max(a, caps.minAspect), caps.maxAspect)
        if abs(ca - a) > 0.001 { rect = GenImaging.contextRect(around: rect, context: 0, aspect: ca, clampTo: clamp) }
        let source = GenImaging.composite(state, rect: rect)
        let regionMask = sel.map { GenImaging.crop($0, to: rect) }
        let (sw, sh) = GenImaging.sendSize(for: rect.width, rect.height, caps: caps, quality: settings.quality)
        let image = GenImaging.resize(GenImaging.flatten(source.makeCGImage()), sw, sh)
        let mask = regionMask.map { GenImaging.providerMask(GenImaging.resizeMask($0, sw, sh), grow: 3) }
        let f = feather ?? max(1.5, min(8, Double(min(box.width, box.height)) * 0.02))
        let blend = regionMask.map { GenImaging.blendMask($0, feather: f, outerBlend: outerBlend) }
        var p = GenRegionPlan(rect: rect, source: source, regionMask: regionMask, sendW: sw, sendH: sh, image: image, mask: mask, blend: blend)
        if let o = originalRect {
            // native outpaint: the unpadded original inside the region, and padding in send pixels
            let inner = rect.intersection(o)
            if !inner.isEmpty {
                let sx = Double(sw) / Double(rect.width), sy = Double(sh) / Double(rect.height)
                let iw = max(1, Int(Double(inner.width) * sx)), ih = max(1, Int(Double(inner.height) * sy))
                p.unpadded = GenImaging.resize(GenImaging.composite(state, rect: inner).makeCGImage(), iw, ih)
                p.padding = ExpandPadding(left: Int(Double(inner.x - rect.x) * sx), right: max(0, sw - iw - Int(Double(inner.x - rect.x) * sx)),
                                          top: Int(Double(inner.y - rect.y) * sy), bottom: max(0, sh - ih - Int(Double(inner.y - rect.y) * sy)))
            }
        }
        return p
    }

    static func request(_ f: GenFeature, prompt: String, plan: GenRegionPlan?, references: [CGImage] = []) -> GenRequest {
        var r = GenRequest(feature: f, prompt: prompt)
        if let p = plan {
            r.image = p.image; r.mask = p.mask; r.width = p.sendW; r.height = p.sendH
            r.padding = p.padding; r.unpadded = p.unpadded
            r.aspectRatio = GenImaging.aspectString(p.sendW, p.sendH)
        }
        r.references = references
        r.quality = settings.quality
        r.storeIO = !settings.falDontStoreIO
        return r
    }

    // MARK: Calls

    /// Calls the provider until `count` images exist (partial results are kept if a later call fails).
    @MainActor static func generate(_ p: GenerativeProvider, _ m: GenModel, key: String, req: GenRequest, count: Int,
                         update: @escaping (GenProgress) -> Void) async throws -> ([GenImage], Double) {
        try GenBudget.gate(m, count: count)
        try confirmUpload(m.provider, hasImage: req.image != nil || !req.references.isEmpty)
        GenJobs.shared.setEstimate(GenBudget.estimateText(m, count: count))
        var imgs: [GenImage] = []
        var cost = 0.0
        var call = 0
        while imgs.count < count {
            var r = req
            r.count = min(count - imgs.count, max(1, m.caps.maxImagesPerCall))
            if let s = req.seed { r.seed = s + call }
            let label = count > 1 ? "Variation \(imgs.count + 1)/\(count): " : ""
            do {
                let got = try await p.run(r, model: m, key: key) { pr in update(GenProgress(fraction: pr.fraction, message: label + pr.message)) }
                let reported = got.compactMap(\.cost).reduce(0, +)
                cost += reported > 0 ? reported : m.pricePerImage * Double(got.count)
                imgs += got
                if got.isEmpty { break }
            } catch {
                if imgs.isEmpty || (error as? GenError) == .cancelled { throw error }
                AppModel.shared.setStatus("Kept \(imgs.count) variation(s); next call failed: \((error as? GenError)?.errorDescription ?? "\(error)")")
                break
            }
            call += 1
            update(GenProgress(fraction: Double(imgs.count) / Double(count), message: "\(imgs.count)/\(count) received"))
        }
        return (imgs, cost)
    }

    @MainActor static func confirmUpload(_ p: ProviderID, hasImage: Bool) throws {
        guard settings.confirmUploads, hasImage, !confirmedProviders.contains(p), !GenJobs.shared.headless else { return }
        let a = NSAlert()
        a.messageText = tr("Upload image to \(tr(p.displayName))?")
        a.informativeText = tr("Part of your document will be sent to \(tr(p.displayName)) for processing. \(p.privacyNote)")
        a.addButton(withTitle: tr("Upload")); a.addButton(withTitle: tr("Cancel"))
        guard UIBlock.run(a) == .alertFirstButtonReturn else { throw GenError.cancelled }
        confirmedProviders.insert(p)
    }

    static func variations(_ imgs: [GenImage], plan: GenRegionPlan) -> [PixelBuffer] {
        imgs.map { GenImaging.masked(result: $0.image, size: plan.rect.width, plan.rect.height, blend: plan.blend) }
    }

    // MARK: Layers

    static func alive(_ d: Document) -> Bool { AppModel.shared.documents.contains { $0 === d } || GenJobs.shared.headless }

    /// Adds a generative layer (variation 0 visible) with metadata; one undo step.
    @discardableResult
    static func addLayer(_ d: Document, name: String, rect: IRect, variations: [PixelBuffer], info: GenerativeLayerInfo, above: UUID? = nil, hideSource: UUID? = nil) -> UUID? {
        guard alive(d), let first = variations.first else { return nil }
        let layer = Layer.raster(name: name, buffer: first, origin: rect.origin)
        if let a = above, d.state.layer(a) != nil {
            d.state.insertLayer(layer, above: a)
            d.activeLayerID = layer.id; d.selectedLayerIDs = [layer.id]; d.editTarget = .content
        } else {
            d.addLayer(layer)
        }
        var i = info
        i.rect = rect
        i.variations = variations
        i.selected = 0
        d.state.generative[layer.id] = i
        if let h = hideSource { d.updateLayer(h) { $0.isVisible = false } }
        d.commit(name)
        d.setNeedsRender()
        GenVariations.generationAdded(d, layerID: layer.id)
        return layer.id
    }

    static func info(_ f: GenFeature, prompt: String, model: GenModel, cost: Double, imgs: [GenImage], mask: PixelBuffer?) -> GenerativeLayerInfo {
        var i = GenerativeLayerInfo()
        i.feature = f.rawValue; i.prompt = prompt; i.providerID = model.provider.rawValue; i.modelID = model.model
        i.cost = cost; i.mask = mask; i.seeds = imgs.map(\.seed); i.createdAt = Date()
        return i
    }

    /// Logs a finished job: Generative History entry + one usage record. `reported` = `cost` came from the provider's
    /// response (not the price table), in which case the record keeps both the list-price estimate and the reported amount.
    @MainActor static func record(_ f: GenFeature, prompt: String, model: GenModel?, cost: Double, started: Date, images: Int, status: String, reported: Bool = false) {
        let seconds = Date().timeIntervalSince(started)
        GenAISettings.shared.addSpend(cost)
        GenJobs.shared.record(GenHistoryEntry(feature: f.rawValue, prompt: prompt, provider: model?.provider.rawValue ?? "-", model: model?.model ?? "-",
                                              cost: cost, seconds: seconds, images: images, status: status))
        let perCall = max(1, model?.caps.maxImagesPerCall ?? 1)
        let isReported = reported && cost > 0
        GenUsageStore.shared.add(GenUsageRecord(provider: model?.provider.rawValue ?? "-", model: model?.model ?? "-", feature: f.rawValue, images: images,
                                                calls: max(1, (images + perCall - 1) / perCall),
                                                estimatedCost: isReported ? (model?.pricePerImage ?? 0) * Double(images) : cost,
                                                reportedCost: isReported ? cost : nil, seconds: seconds, status: status, prompt: prompt))
        let b = GenAISettings.shared.data.monthlyBudget
        let spent = GenUsageStore.shared.month().cost
        if b > 0, spent > b {
            AppModel.shared.setStatus("Generative AI: spend this month \(GenMoney.string(spent)) exceeds your \(GenMoney.string(b)) budget.")
        }
        if status == "ok", let p = model?.provider { GenBalanceService.shared.generationFinished(p) }
    }

    /// True when any image of a job carries a provider-reported cost.
    static func reported(_ imgs: [GenImage]) -> Bool { imgs.contains { $0.costReported } }

    // MARK: Region features (Fill / Remove / Reference / Sky / Background / Expand / Harmonize / Prompt edit)

    /// Runs a masked region feature and adds a generative layer. `sel` is canvas-size gray (white = edit).
    @discardableResult
    static func runRegion(_ d: Document, feature f: GenFeature, prompt: String, sel: PixelBuffer?, references: [CGImage] = [],
                          modelOverride: String? = nil, layerName: String? = nil, outerBlend: Double = 0, originalRect: IRect? = nil,
                          clampToCanvas: Bool = true, above: UUID? = nil, hideSource: UUID? = nil, extra: ((inout GenRequest) -> Void)? = nil,
                          after: ((UUID?) -> Void)? = nil) -> UUID {
        let title = f.displayName
        return GenJobs.shared.start(title) { update in
            let started = Date()
            var model: GenModel?
            do {
                let (p, m, key) = try await ProviderRouter.shared.resolveWithKey(f, override: modelOverride)
                model = m
                let state = d.committedState
                let pl = plan(state: state, sel: sel, model: m, clampToCanvas: clampToCanvas, outerBlend: outerBlend, originalRect: originalRect)
                var req = request(f, prompt: prompt, plan: pl, references: references)
                extra?(&req)
                let (imgs, cost) = try await generate(p, m, key: key, req: req, count: max(1, settings.variations), update: update)
                let vars = variations(imgs, plan: pl)
                var inf = info(f, prompt: prompt, model: m, cost: cost, imgs: imgs, mask: pl.regionMask)
                if let r = references.first { inf.reference = PixelBuffer(cgImage: GenImaging.resize(r, min(r.width, 512), Int(Double(min(r.width, 512)) * Double(r.height) / Double(max(1, r.width))))) }
                let id = addLayer(d, name: layerName ?? f.displayName, rect: pl.rect, variations: vars, info: inf, above: above, hideSource: hideSource)
                record(f, prompt: prompt, model: m, cost: cost, started: started, images: imgs.count, status: "ok", reported: reported(imgs))
                after?(id)
            } catch {
                let ge = (error as? GenError) ?? .network(error.localizedDescription)
                record(f, prompt: prompt, model: model, cost: 0, started: started, images: 0, status: ge == .cancelled ? "cancelled" : (ge.errorDescription ?? "error"))
                after?(nil)
                throw ge
            }
        }
    }

    // MARK: Regenerate / Similar / Enhance (Properties panel)

    /// Adds more variations to an existing generative layer. `similar` uses the current variation as reference.
    static func regenerate(_ d: Document, layerID: UUID, prompt newPrompt: String? = nil, similar: Bool = false, enhance: Bool = false) {
        guard var inf = d.state.generative[layerID], let layer = d.state.layer(layerID) else { return }
        if let np = newPrompt { inf.prompt = np }
        let f: GenFeature = enhance ? .upscale : (similar ? .similar : inf.featureKind)
        GenJobs.shared.start(similar ? "Generate Similar" : (enhance ? "Enhance Detail" : "Generate \(inf.featureKind.displayName)")) { update in
            let started = Date()
            var model: GenModel?
            do {
                let override = !similar && !enhance && !inf.providerID.isEmpty ? "\(inf.providerID):\(inf.modelID)" : nil
                let (p, m, key) = try await ProviderRouter.shared.resolveWithKey(f, override: override)
                model = m
                var st = d.committedState
                st.removeLayer(layerID)
                let rect = inf.rect
                let cur = inf.variations.indices.contains(inf.selected) ? inf.variations[inf.selected] : (layer.raster?.buffer ?? PixelBuffer(width: 1, height: 1))
                var vars: [PixelBuffer] = []
                var imgs: [GenImage] = []
                var cost = 0.0
                if enhance {
                    // Enhance Detail: upscale the current variation 2× with a detail-adding upscaler, resample back, re-mask.
                    var req = request(.upscale, prompt: inf.prompt, plan: nil)
                    let src = GenImaging.resize(GenImaging.flatten(cur.makeCGImage()), min(cur.width, m.caps.preferredEdge), Int(Double(min(cur.width, m.caps.preferredEdge)) * Double(cur.height) / Double(max(1, cur.width))))
                    req.image = src; req.upscaleFactor = 2
                    (imgs, cost) = try await generate(p, m, key: key, req: req, count: 1, update: update)
                    let blend = inf.mask.map { GenImaging.blendMask($0, feather: 3) }
                    vars = imgs.map { GenImaging.masked(result: $0.image, size: rect.width, rect.height, blend: blend) }
                } else {
                    let sel: PixelBuffer? = inf.mask.map { m in
                        let c = PixelBuffer(width: st.width, height: st.height, format: .gray)
                        c.copyPixels(from: m, at: rect.origin); c.markDirty(); return c
                    }
                    var pl = plan(state: st, sel: sel, bbox: sel?.opaqueBounds(), model: m, clampToCanvas: false)
                    // keep the stored region exactly (variations must align)
                    if pl.rect != rect {
                        let source = GenImaging.composite(st, rect: rect)
                        let (sw, sh) = GenImaging.sendSize(for: rect.width, rect.height, caps: m.caps, quality: settings.quality)
                        pl = GenRegionPlan(rect: rect, source: source, regionMask: inf.mask, sendW: sw, sendH: sh,
                                           image: GenImaging.resize(GenImaging.flatten(source.makeCGImage()), sw, sh),
                                           mask: inf.mask.map { GenImaging.providerMask(GenImaging.resizeMask($0, sw, sh), grow: 3) },
                                           blend: inf.mask.map { GenImaging.blendMask($0, feather: 4) })
                    }
                    var refs: [CGImage] = inf.reference.map { [$0.makeCGImage()] } ?? []
                    if similar {
                        // current look (source + variation) as the image to vary
                        let look = pl.source.copy()
                        look.drawImage(cur.makeCGImage(), in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
                        look.markDirty()
                        refs.insert(GenImaging.resize(GenImaging.flatten(look.makeCGImage()), pl.sendW, pl.sendH), at: 0)
                    }
                    var req = request(f, prompt: inf.prompt, plan: pl, references: refs)
                    if inf.featureKind == .generateImage && !similar { req.image = nil; req.mask = nil }
                    if similar, inf.mask == nil { req.image = refs.first; req.references = Array(refs.dropFirst()); req.strength = 0.35 }
                    (imgs, cost) = try await generate(p, m, key: key, req: req, count: max(1, settings.variations), update: update)
                    vars = variations(imgs, plan: pl)
                }
                guard alive(d), d.state.layer(layerID) != nil, var now = d.state.generative[layerID] else { return }
                now.prompt = inf.prompt
                now.variations += vars
                now.seeds += imgs.map(\.seed)
                now.cost += cost
                now.selected = now.variations.count - vars.count
                d.state.generative[layerID] = now
                if let v = now.variations[genSafe: now.selected] {
                    let origin = GenVariations.origin(d.state.layer(layerID), info: now, variation: v)
                    d.updateLayer(layerID) { $0.raster = RasterContent(buffer: v, origin: origin) }
                }
                d.commit(similar ? "Generate Similar" : (enhance ? "Enhance Detail" : "Generate"))
                record(f, prompt: inf.prompt, model: m, cost: cost, started: started, images: imgs.count, status: "ok", reported: reported(imgs))
            } catch {
                let ge = (error as? GenError) ?? .network(error.localizedDescription)
                record(f, prompt: inf.prompt, model: model, cost: 0, started: started, images: 0, status: ge == .cancelled ? "cancelled" : (ge.errorDescription ?? "error"))
                throw ge
            }
        }
    }

    static func selectVariation(_ d: Document, layerID: UUID, index: Int) { GenVariations.select(d, layerID: layerID, index: index) }

    static func deleteVariation(_ d: Document, layerID: UUID, index: Int) { GenVariations.delete(d, layerID: layerID, index: index) }

    // MARK: Whole-image features

    /// Generate Image: new layer (or new document when none is open), scaled to fit the canvas.
    static func generateImage(prompt: String, negative: String = "", style: String?, contentType: ContentType, aspect: String,
                              reference: CGImage?, modelOverride: String? = nil) {
        let doc = AppActions.doc
        GenJobs.shared.start("Generate Image") { update in
            let started = Date()
            var model: GenModel?
            do {
                let (p, m, key) = try await ProviderRouter.shared.resolveWithKey(.generateImage, override: modelOverride)
                model = m
                let ar = GenImaging.ratio(aspect)
                let (w, h) = GenImaging.sendSize(for: Int(1000 * max(1, ar)), Int(1000 * max(1, 1 / ar)), caps: m.caps, quality: settings.quality)
                var req = request(.generateImage, prompt: prompt, plan: nil, references: reference.map { [$0] } ?? [])
                req.width = w; req.height = h; req.aspectRatio = aspect; req.negativePrompt = negative
                req.stylePreset = style; req.contentType = contentType
                let (imgs, cost) = try await generate(p, m, key: key, req: req, count: max(1, settings.variations), update: update)
                var inf = info(.generateImage, prompt: prompt, model: m, cost: cost, imgs: imgs, mask: nil)
                inf.aspectRatio = aspect; inf.contentType = contentType.rawValue; inf.stylePreset = style ?? ""
                if let d = doc, alive(d) {
                    // aspect-fit into the canvas, centred
                    let iw = Double(imgs[0].image.width), ih = Double(imgs[0].image.height)
                    let s = min(Double(d.state.width) / iw, Double(d.state.height) / ih)
                    let rw = max(1, Int(iw * s)), rh = max(1, Int(ih * s))
                    let rect = IRect(x: (d.state.width - rw) / 2, y: (d.state.height - rh) / 2, width: rw, height: rh)
                    let vars = imgs.map { GenImaging.masked(result: $0.image, size: rw, rh, blend: nil) }
                    addLayer(d, name: "Generated Image", rect: rect, variations: vars, info: inf)
                } else {
                    let w = imgs[0].image.width, h = imgs[0].image.height
                    var st = DocumentState(width: w, height: h)
                    let vars = imgs.map { GenImaging.masked(result: $0.image, size: w, h, blend: nil) }
                    let l = Layer.raster(name: "Generated Image", buffer: vars[0])
                    st.layers = [l]
                    inf.rect = IRect(x: 0, y: 0, width: w, height: h); inf.variations = vars
                    st.generative[l.id] = inf
                    let nd = Document(state: st, name: "Generated")
                    AppModel.shared.add(nd)
                }
                record(.generateImage, prompt: prompt, model: m, cost: cost, started: started, images: imgs.count, status: "ok", reported: reported(imgs))
            } catch {
                let ge = (error as? GenError) ?? .network(error.localizedDescription)
                record(.generateImage, prompt: prompt, model: model, cost: 0, started: started, images: 0, status: ge == .cancelled ? "cancelled" : (ge.errorDescription ?? "error"))
                throw ge
            }
        }
    }

    /// Upscale / Denoise / Sharpen of the composite (or a given image). Upscale opens a new document; denoise/sharpen add a layer.
    static func enhance(_ d: Document, feature f: GenFeature, factor: Double = 2, modelOverride: String? = nil, completion: ((CGImage?) -> Void)? = nil) {
        GenJobs.shared.start(f.displayName) { update in
            let started = Date()
            var model: GenModel?
            do {
                let (p, m, key) = try await ProviderRouter.shared.resolveWithKey(f, override: modelOverride)
                model = m
                let st = d.committedState
                let src = GenImaging.composite(st, rect: st.canvasRect)
                var img = GenImaging.flatten(src.makeCGImage(), over: .white)
                // respect the model's input limits
                let mp = Double(img.width * img.height) / 1_000_000
                if mp > m.caps.maxMegapixels || max(img.width, img.height) > m.caps.maxEdge {
                    let k = min((m.caps.maxMegapixels / mp).squareRoot(), Double(m.caps.maxEdge) / Double(max(img.width, img.height)))
                    img = GenImaging.resize(img, max(1, Int(Double(img.width) * k)), max(1, Int(Double(img.height) * k)))
                }
                var req = request(f, prompt: "", plan: nil)
                req.image = img; req.upscaleFactor = factor
                let (imgs, cost) = try await generate(p, m, key: key, req: req, count: 1, update: update)
                guard let out = imgs.first?.image else { throw GenError.badResponse("no image") }
                if f == .upscale {
                    completion?(out)
                    if completion == nil {
                        var ns = DocumentState(width: out.width, height: out.height, resolution: st.resolution)
                        ns.layers = [Layer.raster(name: "Background", buffer: PixelBuffer(cgImage: out))]
                        AppModel.shared.add(Document(state: ns, name: "\(d.name) (\(Int(factor))× upscaled)"))
                    }
                } else if alive(d) {
                    let buf = GenImaging.masked(result: out, size: st.width, st.height, blend: nil)
                    var inf = info(f, prompt: "", model: m, cost: cost, imgs: imgs, mask: nil)
                    inf.rect = st.canvasRect
                    addLayer(d, name: f.displayName, rect: st.canvasRect, variations: [buf], info: inf)
                }
                record(f, prompt: "", model: m, cost: cost, started: started, images: imgs.count, status: "ok", reported: reported(imgs))
            } catch {
                completion?(nil)
                let ge = (error as? GenError) ?? .network(error.localizedDescription)
                record(f, prompt: "", model: model, cost: 0, started: started, images: 0, status: ge == .cancelled ? "cancelled" : (ge.errorDescription ?? "error"))
                throw ge
            }
        }
    }
}

extension Array {
    subscript(genSafe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Upscaler hook for Image Size (no registry existed in the codebase, so it is defined here).
// UpscalerRegistry lives in Edits/ImageResample.swift.

// MARK: - User-facing actions

enum GenAIActions {
    static var doc: Document? { AppActions.doc }

    static func openPreferences() {
        GenAIPrefsState.openGenAISection = true
        AppModel.shared.dialog = .preferences
    }

    static func requireDoc() -> Document? {
        guard let d = doc else { GenJobs.shared.report(.noDocument, title: "Generative AI"); return nil }
        return d
    }

    static func generativeFill(prompt: String, reference: CGImage? = nil, modelOverride: String? = nil) {
        guard let d = requireDoc() else { return }
        guard let sel = d.state.selection, sel.opaqueBounds() != nil else { GenJobs.shared.report(.noSelection, title: "Generative Fill"); return }
        GenPipeline.runRegion(d, feature: reference == nil ? .fill : .referenceFill, prompt: prompt, sel: sel,
                              references: reference.map { [$0] } ?? [], modelOverride: modelOverride,
                              layerName: prompt.isEmpty ? "Generative Fill" : String(prompt.prefix(40)))
    }

    static func removeWithAI() {
        guard let d = requireDoc() else { return }
        guard let sel = d.state.selection, sel.opaqueBounds() != nil else { GenJobs.shared.report(.noSelection, title: "Remove with AI"); return }
        GenPipeline.runRegion(d, feature: .remove, prompt: "", sel: sel, layerName: "Remove (AI)")
    }

    /// Remove tool in "Generative AI (cloud)" mode: `hole` is the painted canvas-size mask.
    static func remove(_ d: Document, hole: PixelBuffer) {
        GenPipeline.runRegion(d, feature: .remove, prompt: "", sel: hole, layerName: "Remove (AI)")
    }

    /// Enlarges the canvas (anchored) and fills the new area generatively.
    static func expandCanvas(left: Int, right: Int, top: Int, bottom: Int, prompt: String) {
        guard let d = requireDoc() else { return }
        let old = d.state.canvasRect
        let r = IRect(x: -left, y: -top, width: old.width + left + right, height: old.height + top + bottom)
        guard r != old, r.width > 0, r.height > 0 else { return }
        AppActions.crop(to: r, deletePixels: false)
        expandAfterCrop(d, originalInNew: IRect(x: left, y: top, width: old.width, height: old.height), prompt: prompt)
    }

    /// After a crop that grew the canvas: fill everything outside `originalInNew`.
    static func expandAfterCrop(_ d: Document, originalInNew o: IRect, prompt: String) {
        let W = d.state.width, H = d.state.height
        let sel = PixelBuffer(width: W, height: H, gray: 255)
        sel.context.setFillColor(gray: 0, alpha: 1)
        sel.context.fill(o.intersection(d.state.canvasRect).cgRect)
        sel.markDirty()
        guard sel.opaqueBounds() != nil else { return }
        GenPipeline.runRegion(d, feature: .expand, prompt: prompt, sel: sel, layerName: "Generative Expand", outerBlend: 10, originalRect: o)
    }

    static func promptEdit(prompt: String, scope: Int, modelOverride: String? = nil) {
        guard let d = requireDoc() else { return }
        guard !prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        switch scope {
        case 1:   // active layer: region = layer bounds, blended through the layer's alpha
            guard let l = d.activeLayer else { return }
            let sp = CanvasSpace(width: d.state.width, height: d.state.height)
            guard let img = Compositor.shared.contentImage(l, space: sp) else { return }
            let alpha = RenderEngine.renderBuffer(img.cropped(to: sp.ciCanvas), docRect: d.state.canvasRect, space: sp).toGray(useAlpha: true)
            guard alpha.opaqueBounds() != nil else { return }
            GenPipeline.runRegion(d, feature: .promptEdit, prompt: prompt, sel: alpha, modelOverride: modelOverride, layerName: "Edit: " + prompt.prefix(30), above: l.id)
        case 2:   // selection
            guard let sel = d.state.selection, sel.opaqueBounds() != nil else { GenJobs.shared.report(.noSelection, title: "Edit with Prompt"); return }
            GenPipeline.runRegion(d, feature: .promptEdit, prompt: prompt, sel: sel, modelOverride: modelOverride, layerName: "Edit: " + prompt.prefix(30))
        default:  // whole image
            GenPipeline.runRegion(d, feature: .promptEdit, prompt: prompt, sel: nil, modelOverride: modelOverride, layerName: "Edit: " + prompt.prefix(30))
        }
    }

    static func generateBackground(prompt: String, modelOverride: String? = nil) {
        guard let d = requireDoc() else { return }
        AppModel.shared.setStatus("Finding the subject…")
        guard let subject = AppActions.subjectMask() else { GenJobs.shared.report(.unsupported("No subject was found for Generate Background."), title: "Generate Background"); return }
        let bg = SelectionOps.invert(subject)
        GenPipeline.runRegion(d, feature: .background, prompt: prompt, sel: bg, modelOverride: modelOverride, layerName: "Generated Background")
    }

    static func skyReplacement(prompt: String) {
        guard let d = requireDoc() else { return }
        let before = d.state.selection
        AppActions.selectSky()
        guard let sky = d.state.selection, sky.opaqueBounds() != nil, sky !== before else { return }
        GenPipeline.runRegion(d, feature: .sky, prompt: prompt, sel: sky, layerName: "Generated Sky")
    }

    /// Harmonize: relight/recolour the active layer to the layers below, as a new layer (source hidden) + a local contact shadow.
    static func harmonize(prompt: String = "", light: String? = nil, modelOverride: String? = nil) {
        guard let d = requireDoc(), let l = d.activeLayer, !l.isGroup, !l.isAdjustment else { Beep.play(); return }
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        guard let img = Compositor.shared.contentImage(l, space: sp) else { return }
        let content = RenderEngine.renderBuffer(img.cropped(to: sp.ciCanvas), docRect: d.state.canvasRect, space: sp)
        let alpha = content.toGray(useAlpha: true)
        guard alpha.opaqueBounds() != nil else { Beep.play(); return }
        let sourceID = l.id
        let grown = SelectionOps.expand(alpha, by: 2)
        GenPipeline.runRegion(d, feature: .harmonize, prompt: prompt, sel: grown, modelOverride: modelOverride, layerName: "\(l.name) (Harmonized)",
                              above: sourceID, hideSource: sourceID, extra: { $0.lightDirection = light }) { newID in
            guard let newID, GenPipeline.alive(d) else { return }
            // local contact shadow under the harmonized layer
            var shadow = Layer.raster(name: "Contact Shadow", buffer: GenImaging.contactShadow(for: content))
            shadow.blendMode = .multiply
            shadow.opacity = 0.7
            d.state.insertLayer(shadow, below: newID)
            d.commit("Harmonize Shadow")
        }
    }

    static func generateSimilar() {
        guard let d = requireDoc(), let id = d.activeLayerID, d.state.generative[id] != nil else {
            GenJobs.shared.report(.unsupported("Select a generative layer first."), title: "Generate Similar"); return
        }
        GenPipeline.regenerate(d, layerID: id, similar: true)
    }

    static func upscale(factor: Double) {
        guard let d = requireDoc() else { return }
        GenPipeline.enhance(d, feature: .upscale, factor: factor)
    }

    static func denoise() { if let d = requireDoc() { GenPipeline.enhance(d, feature: .denoise) } }
    static func sharpen() { if let d = requireDoc() { GenPipeline.enhance(d, feature: .sharpen) } }

    /// Image Size hook: provider-backed upscaler usable by any caller.
    /// Whole-image instruction edit (used by Neural Filters' cloud-only options).
    static func promptEditImage(_ img: CGImage, instruction: String) async throws -> CGImage {
        let (p, m, key) = try await ProviderRouter.shared.resolveWithKey(.promptEdit)
        var req = GenPipeline.request(.promptEdit, prompt: instruction, plan: nil)
        req.image = img
        req.width = img.width; req.height = img.height
        req.aspectRatio = GenImaging.aspectString(img.width, img.height)
        let (imgs, cost) = try await GenPipeline.generate(p, m, key: key, req: req, count: 1) { _ in }
        await GenPipeline.record(.promptEdit, prompt: instruction, model: m, cost: cost, started: Date(), images: imgs.count, status: "ok", reported: GenPipeline.reported(imgs))
        guard let out = imgs.first?.image else { throw GenError.badResponse("no image") }
        return out
    }

    static func upscaleImage(_ img: CGImage, factor: Double) async throws -> CGImage {
        let (p, m, key) = try await ProviderRouter.shared.resolveWithKey(.upscale)
        var req = GenPipeline.request(.upscale, prompt: "", plan: nil)
        req.image = img; req.upscaleFactor = factor
        let (imgs, cost) = try await GenPipeline.generate(p, m, key: key, req: req, count: 1) { _ in }
        await GenPipeline.record(.upscale, prompt: "", model: m, cost: cost, started: Date(), images: imgs.count, status: "ok", reported: GenPipeline.reported(imgs))
        guard let out = imgs.first?.image else { throw GenError.badResponse("no image") }
        return out
    }
}
