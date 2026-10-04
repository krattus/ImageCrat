import AppKit
import SwiftUI
import CoreImage
import ImageCratCore

/// Follow-ups of the manual QA report (U03 Generative Fill stall, memory growth, particle smart-object menu, PSD round trip).
/// `LUMEN_SELFTEST_ONLY=invfixes Lumen --selftest <dir>`. `LUMEN_INVFIX_FIXTURE=<doc.lumen>` also round-trips that file
/// through PSD and prints per-layer differences.
enum InvFixesModule {
    static func register() {
        FeatureModules.selfTests.append(("invfixes", { out in InvFixesSelfTest.run(out) }))
    }
}

enum InvFixesSelfTest {
    static var passes = 0, failures = 0

    static func check(_ c: Bool, _ msg: @autoclosure () -> String) {
        if c { passes += 1; print("PASS invfixes: \(msg())") } else { failures += 1; print("FAIL invfixes: \(msg())") }
    }

    static func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    static func run(_ out: URL) {
        passes = 0; failures = 0
        let dir = out.appendingPathComponent("invfixes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testKeychainNonBlocking()
        testParticleMenu()
        testMemory(dir)
        if let f = ProcessInfo.processInfo.environment["LUMEN_INVFIX_FIXTURE"] { investigatePSD(URL(fileURLWithPath: f), dir) }
        print("invfixes: \(passes) passed, \(failures) failed")
    }

    // MARK: U03 — Generative Fill must open without waiting for the Keychain

    static func testKeychainNonBlocking() {
        let savedKeys = GenAIKeyOverrides.keys
        GenAIKeyOverrides.keys = [:]
        let lock = NSLock()
        var calls = 0
        // Stands in for a Keychain whose every read waits 0.8 s (an unanswered access prompt); only a fal key exists.
        GenAIKeychain.testReader = { account in
            lock.lock(); calls += 1; lock.unlock()
            Thread.sleep(forTimeInterval: 0.8)
            return account == ProviderID.fal.rawValue ? "mock-fal-key" : nil
        }
        GenAIKeychain.resetCaches()
        defer { GenAIKeychain.testReader = nil; GenAIKeychain.resetCaches(); GenAIKeyOverrides.keys = savedKeys }
        let d = Document(state: SelfTest.baseState(512, 512), name: "gen")
        AppModel.shared.add(d)
        defer { AppModel.shared.close(d) }

        let t0 = Date()
        let host = NSHostingView(rootView: GenDialog(kind: .fill).frame(width: 420))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        let avail = ProviderRouter.shared.available(for: .fill)
        _ = GenCostHint.text(feature: .fill, model: "")
        let opened = Date().timeIntervalSince(t0)
        check(opened < 0.5, String(format: "Generative Fill dialog builds in %.2f s while every Keychain read blocks for 0.8 s", opened))
        check(!GenAIKeychain.shared.presenceKnown && avail.isEmpty, "while the Keychain hasn't answered the dialog shows the checking state, not a key")

        // the main thread keeps running while the lookups finish in the background
        var ticks = 0, maxGap = 0.0, last = Date()
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in ticks += 1; maxGap = max(maxGap, Date().timeIntervalSince(last)); last = Date() }
        RunLoop.current.add(timer, forMode: .common)
        let deadline = Date().addingTimeInterval(20)
        while !GenAIKeychain.shared.presenceKnown && Date() < deadline { pump(0.02) }
        check(GenAIKeychain.shared.presenceKnown, "presence lookups answer in the background")
        pump(0.1)
        check(maxGap < 0.3 && ticks > 50, String(format: "main run loop kept ticking during the lookups (%d ticks, longest gap %.2f s)", ticks, maxGap))
        host.layoutSubtreeIfNeeded()
        let fal = ProviderRouter.shared.available(for: .fill)
        check(!fal.isEmpty && fal.allSatisfy { $0.provider == .fal }, "after the lookup the picker offers the keyed provider (\(fal.map(\.id)))")
        lock.lock(); let before = calls; lock.unlock()
        let r = try? ProviderRouter.shared.resolve(.fill)
        _ = GenCostHint.text(feature: .fill, model: "")
        host.layoutSubtreeIfNeeded()
        lock.lock(); let after = calls; lock.unlock()
        check(r?.1.provider == .fal && after == before, "resolving the model for the dialog never reads a secret (\(after - before) reads)")

        // a job reads the key off the main thread
        var got: String?
        var finished = false
        ticks = 0; maxGap = 0; last = Date()
        Task { @MainActor in
            got = (try? await ProviderRouter.shared.resolveWithKey(.fill))?.2
            finished = true
        }
        let d2 = Date().addingTimeInterval(10)
        while !finished && Date() < d2 { pump(0.02) }
        check(got == "mock-fal-key", "a job gets the key through the background read")
        check(maxGap < 0.3, String(format: "main thread stayed responsive while the key was read (longest gap %.2f s)", maxGap))
        lock.lock(); let c1 = calls; lock.unlock()
        finished = false
        Task { @MainActor in _ = try? await ProviderRouter.shared.resolveWithKey(.fill); finished = true }
        while !finished && Date() < d2 { pump(0.02) }
        lock.lock(); let c2 = calls; lock.unlock()
        check(c2 == c1, "the key is read once per session (a second job asks the Keychain \(c2 - c1) more times)")
        timer.invalidate()
    }

    // MARK: Particles ▸ Tools after a "Smart Object (re-editable)" apply

    /// Enabled state of the Tools items as the real (SwiftUI-hosted) Particles menu shows them.
    static func toolItems(_ menu: NSMenu) -> [String: Bool] {
        menu.update()
        guard let tools = menu.items.first(where: { $0.title == "Tools" })?.submenu else { return [:] }
        tools.update()
        var r: [String: Bool] = [:]
        for i in tools.items where !i.isSeparatorItem { r[i.title] = i.isEnabled }
        return r
    }

    static func testParticleMenu() {
        let savedLast = ParticleEditor.lastEffect
        ParticleEditor.current?.cancel()
        ParticleEditor.lastEffect = nil
        defer { ParticleEditor.lastEffect = savedLast }
        let d = Document(state: SelfTest.baseState(480, 300), name: "particles-menu")
        AppModel.shared.add(d)
        defer { AppModel.shared.close(d) }
        let menu = NSHostingMenu(rootView: ParticleMenuItems())
        pump(0.1)
        let before = toolItems(menu)
        let names = ["Randomize (New Seed)", "Repeat Last", "Edit Particle Layer…"]
        check(!before.isEmpty && names.allSatisfy { before[$0] == false }, "fresh document: Randomize / Repeat Last / Edit Particle Layer start disabled (\(names.map { before[$0].map { "\($0)" } ?? "missing" }))")
        var e = ParticlePresets.effect("stars", aspect: 480.0 / 300) ?? ParticleEffect()
        e.output = .smartObject
        let ed = ParticleEditor(doc: d, effect: e, interactive: false)
        ed.apply()
        let isParticleSO = ParticleStorage.effect(in: d.activeLayer) != nil
        let enabledByLogic = names.compactMap { n in MenuRegistry.items(for: ParticlesModule.menu).first { $0.title == n } }.map { $0.enabled() }
        check(isParticleSO && enabledByLogic == [true, true, true], "after the apply the active layer is a particle smart object and the menu conditions hold (\(enabledByLogic))")
        pump(0.1)
        let after = toolItems(menu)
        check(names.allSatisfy { after[$0] == true }, "the hosted Particles menu enables them after a Smart Object apply (\(names.map { after[$0].map { "\($0)" } ?? "missing" }))")
    }

    // MARK: Memory: closed documents, engines after their editors, pressure

    static func testMemory(_ dir: URL) {
        // caches of a document that stays open survive another document's close; the closed one's go
        let a = MemorySoak.makeDocument(100)
        MemorySoak.display(a)
        let b = MemorySoak.makeDocument(101)
        MemorySoak.display(b)
        let aIDs = Set(a.state.allLayers.map(\.id)), bIDs = Set(b.state.allLayers.map(\.id))
        let cachedB = !Compositor.shared.cachedLayerIDs.isDisjoint(with: bIDs)
        AppModel.shared.close(b)
        let cached = Compositor.shared.cachedLayerIDs
        check(cachedB && cached.isDisjoint(with: bIDs) && !cached.isDisjoint(with: aIDs), "closing a document drops its render caches and keeps the open document's")
        AppModel.shared.close(a)

        // particle float / MSAA targets are released when the editor closes
        let d = MemorySoak.makeDocument(102)
        var e = ParticlePresets.effect(ParticlePresets.all[0].id, aspect: 1600.0 / 1080) ?? ParticleEffect()
        e.quality = .best
        ParticleEditor(doc: d, effect: e, interactive: false).apply()
        check(ParticleRenderer.pooledTargets == 0, "particle render targets are freed once the editor has closed (\(ParticleRenderer.pooledTargets) pooled)")
        AppModel.shared.close(d)

        // short soak: every closed round must actually be freed
        MemorySoak.tracked = []
        let rounds = ProcessInfo.processInfo.environment["LUMEN_SOAK"].flatMap { Int($0) } ?? 4
        let fp = MemorySoak.run(rounds: rounds, csv: dir.appendingPathComponent("soak.csv"))
        pump(0.5)
        let closed = MemorySoak.tracked.dropLast()      // the newest may still be referenced by work that finishes late
        check(closed.allSatisfy { $0.buffer == nil }, "soak: pixel buffers of closed documents are freed (\(closed.filter { $0.buffer != nil }.count) of \(closed.count) alive)")
        check(closed.allSatisfy { $0.doc == nil }, "soak: closed documents are deallocated (\(closed.filter { $0.doc != nil }.count) of \(closed.count) alive)")
        let allIDs = MemorySoak.tracked.reduce(into: Set<UUID>()) { $0.formUnion($1.ids) }
        let tracked = Set(MemorySoak.tracked.map(\.id))
        check(SnapshotStore.shared.byDoc.keys.allSatisfy { !tracked.contains($0) }, "soak: History snapshots of closed documents are dropped")
        check(RecipeRuntime.shared.targetIDs.isDisjoint(with: allIDs) && Compositor.shared.cachedLayerIDs.isDisjoint(with: allIDs),
              "soak: recipe evaluators and render caches of closed documents are dropped")
        if fp.count >= 4 { print(String(format: "invfixes: soak footprint %@ MB", fp.map { String(format: "%.0f", $0.current) }.joined(separator: " → "))) }

        // memory pressure and idle models
        let o = MemorySoak.makeDocument(103)
        MemorySoak.display(o)
        MemoryHygiene.relieve(critical: false)
        check(Compositor.shared.cachedLayerIDs.isEmpty && AppModel.shared.statusMessage.contains("Memory is low"), "memory pressure drops the render caches and says so")
        MemorySoak.display(o)
        check(!Compositor.shared.cachedLayerIDs.isEmpty, "caches rebuild on the next draw after a pressure purge")
        AppModel.shared.close(o)
        MemoryHygiene.modelUsed()
        let early = MemoryHygiene.unloadIdleModels()
        let late = MemoryHygiene.unloadIdleModels(now: Date().addingTimeInterval(MemoryHygiene.modelIdleTimeout + 1))
        check(!early && late && SegModels.loadedCount == 0 && NeuralModels.loadedCount == 0 && !SAM3Engine.isLoaded,
              "on-device models are unloaded after \(Int(MemoryHygiene.modelIdleTimeout / 60)) idle minutes, not before")
    }

    // MARK: PSD round trip investigation (fixture)

    static func buffer(_ st: DocumentState) -> PixelBuffer {
        let sp = CanvasSpace(width: st.width, height: st.height)
        return RenderEngine.renderBuffer(Compositor.shared.composite(st), docRect: st.canvasRect, space: sp)
    }

    /// Max channel difference, count of pixels differing by more than `tol`, and their bounding box.
    static func diff(_ a: PixelBuffer, _ b: PixelBuffer, tol: Int = 8) -> (max: Int, count: Int, box: IRect?) {
        guard a.width == b.width, a.height == b.height else { return (255, a.width * a.height, nil) }
        var mx = 0, n = 0, x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        for y in 0..<a.height { for x in 0..<a.width {
            let p = a.pixel(x, y), q = b.pixel(x, y)
            let m = max(abs(Int(p.0) - Int(q.0)), abs(Int(p.1) - Int(q.1)), abs(Int(p.2) - Int(q.2)), abs(Int(p.3) - Int(q.3)))
            mx = max(mx, m)
            if m > tol { n += 1; x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y) }
        } }
        return (mx, n, n > 0 ? IRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1) : nil)
    }

    static func describe(_ l: Layer) -> String {
        let kind: String
        switch l.content {
        case .raster: kind = "raster"
        case .text: kind = "text"
        case .shape: kind = "shape"
        case .smartObject: kind = "smart"
        case .adjustment: kind = "adjustment"
        case .fill: kind = "fill"
        case .group: kind = "group"
        }
        return "\(l.name) [\(kind)] vis=\(l.isVisible) op=\(l.opacity) blend=\(l.blendMode) fx=\(l.effects.enabled ? l.effects.activeNames : []) mask=\(l.mask != nil)"
    }

    static func investigatePSD(_ url: URL, _ dir: URL) {
        guard let src = try? DocumentIO.load(url: url) else { print("invfixes: cannot load \(url.path)"); return }
        let st = src.state
        print("invfixes psd: \(url.lastPathComponent) \(st.width)x\(st.height), \(st.allLayers.count) layers")
        for l in st.allLayers { print("  src  " + describe(l)) }
        let psd = dir.appendingPathComponent("roundtrip.psd")
        do { try DocumentIO.export(st, to: psd, format: .psd, quality: 1, scale: 1) } catch { print("invfixes psd: export failed \(error)"); return }
        guard let back = try? DocumentIO.load(url: psd) else { print("invfixes psd: reopen failed"); return }
        for l in back.state.allLayers { print("  back " + describe(l)) }
        let a = buffer(st), b = buffer(back.state)
        let d = diff(a, b)
        print("invfixes psd: composite max diff \(d.max), \(d.count) px > 8, box \(d.box.map { "\($0)" } ?? "-")")
        SelfTest.save(st, "invfixes/psd_source", dir.deletingLastPathComponent())
        SelfTest.save(back.state, "invfixes/psd_reopened", dir.deletingLastPathComponent())
        // display scale (the tester compared fit-to-window screenshots)
        for z in [0.37, 0.5] {
            func scaled(_ s: DocumentState) -> PixelBuffer {
                let img = Compositor.shared.composite(s).transformed(by: CGAffineTransform(scaleX: z, y: z), highQualityDownsample: true)
                let w = Int(Double(s.width) * z), h = Int(Double(s.height) * z)
                return RenderEngine.renderBuffer(img, docRect: IRect(x: 0, y: 0, width: w, height: h), space: CanvasSpace(width: w, height: h))
            }
            let e = diff(scaled(st), scaled(back.state))
            print("invfixes psd: at \(z)×: max \(e.max), \(e.count) px > 8, box \(e.box.map { "\($0)" } ?? "-")")
            let full = buffer(st)
            let refImg = full.ciImage.transformed(by: CGAffineTransform(scaleX: z, y: z), highQualityDownsample: true)
            let rw = Int(Double(st.width) * z), rh = Int(Double(st.height) * z)
            let ref = RenderEngine.renderBuffer(refImg, docRect: IRect(x: 0, y: 0, width: rw, height: rh), space: CanvasSpace(width: rw, height: rh))
            let r1 = diff(ref, scaled(st)), r2 = diff(ref, scaled(back.state))
            print("invfixes psd:   reference (100 % render, then downsampled) vs source \(r1.max)/\(r1.count) px, vs reopened \(r2.max)/\(r2.count) px")
            let viaIntermediate = Compositor.shared.composite(back.state).insertingIntermediate(cache: false).transformed(by: CGAffineTransform(scaleX: z, y: z), highQualityDownsample: true)
            let r3 = diff(ref, RenderEngine.renderBuffer(viaIntermediate, docRect: IRect(x: 0, y: 0, width: rw, height: rh), space: CanvasSpace(width: rw, height: rh)))
            print("invfixes psd:   reopened drawn through a full-resolution intermediate vs reference \(r3.max)/\(r3.count) px")
            var noAdj = st; noAdj.layers.removeAll { $0.isAdjustment }
            let g = diff(scaled(noAdj), scaled(back.state)), h = diff(scaled(noAdj), scaled(st))
            print("invfixes psd:   source without adjustment layers vs reopened at \(z)×: max \(g.max), \(g.count) px; vs source: max \(h.max), \(h.count) px, box \(h.box.map { "\($0)" } ?? "-")")
            for l in st.allLayers { if let m = l.mask { print("invfixes psd:   mask of \(l.name): frame \(m.frame) outside \(m.outsideValue) enabled \(m.isEnabled) opaque \(m.buffer.opaqueBounds().map { "\($0)" } ?? "-")") } }
            for l in st.layers {
                guard let m = back.state.layers.first(where: { $0.name == l.name }) else { continue }
                var s1 = st; s1.layers = [l]; var s2 = back.state; s2.layers = [m]
                let a1 = scaled(s1), b1 = scaled(s2)
                let f = diff(a1, b1)
                print("invfixes psd:   \(l.name) at \(z)×: max \(f.max), \(f.count) px > 8, box \(f.box.map { "\($0)" } ?? "-")")
                if f.count > 0 {
                    for (n, b) in [("src", a1), ("back", b1)] {
                        var t = DocumentState(width: b.width, height: b.height); t.layers = [Layer.raster(name: n, buffer: b)]
                        SelfTest.save(t, "invfixes/psd_scaled_\(z)_\(l.name)_\(n)", dir.deletingLastPathComponent())
                    }
                }
            }
        }
        // per layer (matched by name): the layer alone
        for l in st.layers {
            var s1 = st; s1.layers = [l]
            guard let m = back.state.layers.first(where: { $0.name == l.name }) else { print("invfixes psd: layer \(l.name) missing after reopening"); continue }
            var s2 = back.state; s2.layers = [m]
            let e = diff(buffer(s1), buffer(s2))
            print("invfixes psd: layer \(l.name): max \(e.max), \(e.count) px > 8, box \(e.box.map { "\($0)" } ?? "-")")
            if e.count > 0 {
                SelfTest.save(s1, "invfixes/psd_\(l.name)_src", dir.deletingLastPathComponent())
                SelfTest.save(s2, "invfixes/psd_\(l.name)_back", dir.deletingLastPathComponent())
            }
        }
        for l in st.allLayers where l.isAdjustment { print("invfixes psd: adjustment \(l.name): \(l.content)") }
    }
}
