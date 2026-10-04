import AppKit
import ImageCratCore

/// Releases what closed documents and idle engines leave behind, and answers system memory pressure.
/// Everything dropped here is a cache: it is rebuilt on demand.
enum MemoryHygiene {
    nonisolated(unsafe) private static var pressure: DispatchSourceMemoryPressure?
    nonisolated(unsafe) private static var idleTimer: Timer?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastModelUse: Date?
    /// On-device models unused for this long are unloaded (they hold GBs of GPU / ANE memory; reloading takes seconds).
    static var modelIdleTimeout: TimeInterval = 10 * 60

    static func install() {
        guard pressure == nil else { return }
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        s.setEventHandler { relieve(critical: s.data.contains(.critical)) }
        s.resume()
        pressure = s
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in unloadIdleModels() }
    }

    /// Called by the model loaders (Florence-2 / SAM / SAM 3.1 / LaMa / Depth Anything / style transfer).
    static func modelUsed() { lock.lock(); lastModelUse = Date(); lock.unlock() }

    @discardableResult
    static func unloadIdleModels(now: Date = Date()) -> Bool {
        lock.lock(); let last = lastModelUse; lock.unlock()
        guard let last, now.timeIntervalSince(last) >= modelIdleTimeout else { return false }
        unloadModels()
        lock.lock(); lastModelUse = nil; lock.unlock()
        return true
    }

    /// In-flight inferences keep their own references; the caches only stop holding the models.
    static func unloadModels() {
        SegModels.unloadAll()
        SAMSegmenter.shared.release()
        SAM3Engine.unload()
        NeuralModels.unloadAll()
        StyleTransfer.unloadAll()
    }

    /// Layer ids (and smart-filter ids) of every open document, including the documents inside smart objects.
    static func openIDs() -> Set<UUID> {
        var ids = Set<UUID>()
        func visit(_ layers: [Layer], depth: Int) {
            for l in layers.allLayers {
                ids.insert(l.id)
                if let so = l.smart {
                    for f in so.filters { ids.insert(f.id) }
                    if depth < 4, case .document(let st) = so.source { visit(st.layers, depth: depth + 1) }
                }
            }
        }
        for d in AppModel.shared.documents { visit(d.state.layers, depth: 0) }
        return ids
    }

    /// A document was closed: drop what would otherwise keep its layers (and their pixel buffers / GPU copies) alive.
    static func documentClosed(_ d: Document) {
        SnapshotStore.shared.forget(d.id)
        Workflow2Module.forget(d.id)
        CanvasRenderer.forget(d.id)
        let ids = openIDs()
        Compositor.shared.prune(keeping: ids)
        RecipeRuntime.shared.prune(keeping: ids)
        if ParticleEditor.current == nil { ParticleRenderer.releaseTargets() }
        // intermediates and uploaded layer images of the closed document
        RenderEngine.context.clearCaches()
    }

    /// Memory pressure: drop render caches and pools; unload models (critical: immediately, warning: when idle for a minute).
    static func relieve(critical: Bool) {
        Compositor.shared.clearCaches()
        CanvasRenderer.forget(nil)
        RecipeRuntime.shared.prune(keeping: openIDs())
        if ParticleEditor.current == nil { ParticleRenderer.releaseTargets() }
        ParticleSpriteAtlas.purge()
        RenderEngine.context.clearCaches()
        RenderEngine.readbackContext.clearCaches()
        lock.lock(); let last = lastModelUse; lock.unlock()
        let unload = critical || last.map { Date().timeIntervalSince($0) > 60 } ?? true
        if unload { unloadModels() }
        AppModel.shared.setStatus("Memory is low: ImageCrat released its caches" + (unload ? " and unloaded idle on-device AI models." : "."))
    }
}
