import Foundation
import AppKit
import Security
import SwiftUI
import ImageCratCore

/// `LUMEN_SELFTEST_ONLY=genai .build/debug/Lumen --selftest <out>`
/// Keychain, tolerant decoding, mask encoding and local compositing run offline; provider request/response tests run
/// against scripts/genai_mock_server.py (started and stopped here; override with LUMEN_GENAI_MOCK_SCRIPT).
enum GenAISelfTest {
    static var failures = 0
    static var passes = 0

    static func check(_ c: Bool, _ msg: @autoclosure () -> String) {
        if c { passes += 1; print("PASS genai: \(msg())") } else { failures += 1; print("FAIL genai: \(msg())") }
    }

    static func run(_ out: URL) {
        failures = 0; passes = 0
        GenJobs.shared.headless = true
        GenJobs.shared.persist = false
        GenAISettings.shared.persist = false
        let savedSettings = GenAISettings.shared.data
        GenAISettings.shared.data = GenAISettingsData()
        GenAISettings.shared.data.variations = 3
        defer { GenAISettings.shared.data = savedSettings }
        // Usage log: a temp folder for the whole run (never the real Application Support), removed afterwards.
        let usageDir = tempDir("usage")
        GenUsageStore.shared.configure(directory: usageDir)
        defer {
            GenUsageStore.shared.detach()
            GenUsageStore.shared.configure(directory: GenUsageStore.defaultDirectory)
            try? FileManager.default.removeItem(at: usageDir)
        }

        testUsageStore()
        testKeychain()
        testTolerantDecoding()
        testMaskEncoding()
        testLocalCompositing(out)
        testRouter()

        guard let (proc, port) = startMock() else {
            print("SKIP genai: mock server not started (python3 / script missing)")
            print("genai: \(passes) passed, \(failures) failed")
            return
        }
        defer {
            proc.terminate(); proc.waitUntilExit()
            GenHTTP.overrides = [:]; GenAIKeyOverrides.keys = [:]
            GenHTTP.platformOverride = nil; GenAIKeyOverrides.active = false; GenAIKeyOverrides.falAdmin = nil
            GenBalanceService.shared.falUsage = nil; GenBalanceService.shared.notes = [:]; GenBalanceService.shared.falNeedsAdmin = false
            print("genai: mock server stopped")
        }
        let base = "http://127.0.0.1:\(port)"
        for p in ProviderID.allCases {
            GenHTTP.overrides[p] = base + "/" + p.rawValue
            GenAIKeyOverrides.keys[p] = "test-\(p.rawValue)-key"
        }
        GenHTTP.pollInterval = 0.05
        GenHTTP.platformOverride = base + "/falapi"      // fal Platform API (billing / usage) mock
        GenAIKeyOverrides.active = true
        testKeyChecks(base)
        testProviders(base, out)
        testWholeImage(base, out)
        testErrors(base)
        testBalances(base)
        testUsageIntegration(base)
        let vdoc = testVariationSwitching(base, out)
        defer { if let vdoc { AppModel.shared.close(vdoc) } }
        if ProcessInfo.processInfo.environment["LUMEN_SELFTEST_UI"] == "1" {
            snapshots(base, out)
            uxSnapshots(base, out, doc: vdoc)
        }
        print("genai: \(passes) passed, \(failures) failed")
    }

    /// UI snapshots (LUMEN_SELFTEST_UI=1): Preferences section, dialogs, Properties for a generative layer, History panel.
    static func snapshots(_ base: String, _ out: URL) {
        let d = testDoc()
        AppModel.shared.add(d)
        defer { AppModel.shared.close(d) }
        _ = job { GenPipeline.runRegion(d, feature: .fill, prompt: "a hot air balloon", sel: d.state.selection, modelOverride: "openai:gpt-image-2.5-flare") }
        if let id = d.state.generative.first?.key { d.selectLayer(id) }
        func snap<V: View>(_ v: V, _ name: String, _ size: CGSize) {
            let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height, alignment: .topLeading).background(Theme.panelBG).environment(\.colorScheme, .dark))
            host.frame = CGRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
            print("wrote \(name)")
        }
        GenAIPrefsState.openGenAISection = true
        snap(PreferencesDialog(), "ui_genai_prefs_keys", CGSize(width: 580, height: 520))
        snap(VStack { GenAIPreferencesSectionSnapshot(tab: 1) }.padding(10), "ui_genai_prefs_routing", CGSize(width: 380, height: 460))
        snap(VStack { GenAIPreferencesSectionSnapshot(tab: 2) }.padding(10), "ui_genai_prefs_privacy", CGSize(width: 380, height: 460))
        snap(GenDialog(kind: .fill), "ui_genai_fill_dialog", CGSize(width: 400, height: 230))
        snap(GenDialog(kind: .generateImage), "ui_genai_generate_dialog", CGSize(width: 400, height: 360))
        snap(PropertiesPanel(), "ui_genai_properties", CGSize(width: 300, height: 480))
        snap(GenHistoryPanel(), "ui_genai_history", CGSize(width: 300, height: 400))
        GenJobs.shared.active = [GenJobs.Job(title: "Generative Fill", detail: "Variation 2/3: fal: generating… step 10/28", fraction: 0.4)]
        snap(GenHUDView(), "ui_genai_hud", CGSize(width: 360, height: 60))
        GenJobs.shared.active = []
    }

    // MARK: - Helpers

    static func wait(_ timeout: Double = 30, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return cond()
    }

    static func sync<T>(_ f: @escaping () async throws -> T) -> Result<T, Error> {
        var r: Result<T, Error>?
        Task { @MainActor in do { r = .success(try await f()) } catch { r = .failure(error) } }
        _ = wait(60) { r != nil }
        return r ?? .failure(GenError.timeout)
    }

    /// Starts a job and waits for every job to finish. Returns the error message, if any.
    @discardableResult
    static func job(_ start: () -> Void) -> String? {
        GenJobs.shared.lastError = nil
        start()
        let ok = wait(60) { GenJobs.shared.active.isEmpty }
        if !ok { return "timeout" }
        return GenJobs.shared.lastError
    }

    struct Req {
        var method: String, path: String, query: String, headers: [String: String], body: Data
        func header(_ k: String) -> String? { headers.first { $0.key.lowercased() == k.lowercased() }?.value }
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
        var multipart: [String: [Data]] {
            guard let ct = header("Content-Type"), let r = ct.range(of: "boundary=") else { return [:] }
            return GenAISelfTest.parseMultipart(body, boundary: String(ct[r.upperBound...]))
        }
        func field(_ n: String) -> String? { multipart[n]?.first.flatMap { String(data: $0, encoding: .utf8) } }
    }

    static func control(_ base: String, _ path: String, _ body: [String: Any]? = nil) {
        var r = URLRequest(url: URL(string: base + path)!)
        r.httpMethod = body == nil && path == "/__log" ? "GET" : "POST"
        if let b = body { r.httpBody = try? JSONSerialization.data(withJSONObject: b) }
        _ = sync { try await URLSession.shared.data(for: r) }
    }

    static func log(_ base: String) -> [Req] {
        guard case .success(let (d, _)) = sync({ try await URLSession.shared.data(from: URL(string: base + "/__log")!) }),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return arr.map { Req(method: $0["method"] as? String ?? "", path: $0["path"] as? String ?? "", query: $0["query"] as? String ?? "",
                             headers: $0["headers"] as? [String: String] ?? [:], body: Data(base64Encoded: $0["body"] as? String ?? "") ?? Data()) }
    }

    static func parseMultipart(_ body: Data, boundary: String) -> [String: [Data]] {
        var out: [String: [Data]] = [:]
        let sep = Data(("--" + boundary).utf8)
        var parts: [Data] = []
        var start = body.startIndex
        while let r = body.range(of: sep, in: start..<body.endIndex) {
            if r.lowerBound > start { parts.append(body[start..<r.lowerBound]) }
            start = r.upperBound
        }
        for var p in parts {
            if p.starts(with: Data("\r\n".utf8)) { p = p.dropFirst(2) }
            guard let hEnd = p.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let head = String(data: p[p.startIndex..<hEnd.lowerBound], encoding: .utf8) ?? ""
            var data = Data(p[hEnd.upperBound...])
            if data.suffix(2) == Data("\r\n".utf8) { data = data.dropLast(2) }
            if let n = head.range(of: "name=\""), let e = head[n.upperBound...].firstIndex(of: "\"") {
                out[String(head[n.upperBound..<e]), default: []].append(data)
            }
        }
        return out
    }

    static func decodeImage(_ d: Data?) -> CGImage? { d.flatMap { try? GenHTTP.decodeImage($0) } }
    static func decodeB64(_ s: String?) -> CGImage? {
        guard var s else { return nil }
        if s.hasPrefix("data:"), let c = s.firstIndex(of: ",") { s = String(s[s.index(after: c)...]) }
        return decodeImage(Data(base64Encoded: s))
    }

    /// Checks a provider mask: edit value at the selection centre, keep value at the corner.
    static func checkMask(_ img: CGImage?, alpha: Bool, expectSize: (Int, Int)?, center: (Double, Double), _ label: String) {
        guard let img else { check(false, "\(label): mask decodes"); return }
        if let s = expectSize { check(img.width == s.0 && img.height == s.1, "\(label): mask size \(img.width)x\(img.height) == image \(s.0)x\(s.1)") }
        let cx = Int(center.0 * Double(img.width)), cy = Int(center.1 * Double(img.height))
        if alpha {
            check(img.alphaInfo != .none, "\(label): mask has an alpha channel")
            let b = PixelBuffer(cgImage: img)
            check(b.alpha(cx, cy) == 0, "\(label): mask transparent (edit) inside selection (a=\(b.alpha(cx, cy)))")
            check(b.alpha(1, 1) == 255, "\(label): mask opaque (keep) outside selection (a=\(b.alpha(1, 1)))")
        } else {
            let b = PixelBuffer(cgImage: img, format: .gray)
            let p = b.data.assumingMemoryBound(to: UInt8.self)
            let inside = p[cy * b.bytesPerRow + cx], outside = p[b.bytesPerRow + 1]
            check(inside == 255 && outside == 0, "\(label): mask white inside (\(inside)) / black outside (\(outside))")
        }
    }

    static func testDoc(_ w: Int = 480, _ h: Int = 300) -> Document {
        var st = SelfTest.baseState(w, h)
        st.layers.append(SelfTest.shapeLayer(CGRect(x: 60, y: 60, width: 150, height: 110), RGBA(hex: "2E4057")!, radius: 10))
        st.selection = SelectionOps.mask(fromPath: CGPath(ellipseIn: CGRect(x: 250, y: 90, width: 140, height: 110), transform: nil), width: w, height: h)
        return Document(state: st, name: "genai-test")
    }

    /// Returns (differences outside selection, changed pixels inside).
    static func compareOutside(_ before: DocumentState, _ after: DocumentState, sel: PixelBuffer, margin: Double = 0) -> (Int, Int) {
        let a = GenImaging.composite(before, rect: before.canvasRect), b = GenImaging.composite(after, rect: after.canvasRect)
        let keep = margin > 0 ? SelectionOps.expand(sel, by: margin) : sel
        let pa = a.data.assumingMemoryBound(to: UInt8.self), pb = b.data.assumingMemoryBound(to: UInt8.self), ps = keep.data.assumingMemoryBound(to: UInt8.self)
        var outDiff = 0, inChanged = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let o = y * a.bytesPerRow + x * 4
                let same = pa[o] == pb[o] && pa[o + 1] == pb[o + 1] && pa[o + 2] == pb[o + 2] && pa[o + 3] == pb[o + 3]
                if ps[y * keep.bytesPerRow + x] == 0 { if !same { outDiff += 1 } } else if !same { inChanged += 1 }
            }
        }
        return (outDiff, inChanged)
    }

    // MARK: - Offline tests

    static func testKeychain() {
        let kc = GenAIKeychain(service: Brand.keychainService + ".selftest-\(UUID().uuidString.prefix(8))")
        let secret = "sk-selftest-\(UUID().uuidString)"
        let st = kc.set(secret, for: "openai")
        check(st == errSecSuccess, "keychain: add item (status \(st))")
        check(kc.get("openai") == secret, "keychain: read back")
        let acc = kc.accessibility("openai")
        if GenAIKeychain.dataProtectionAvailable {
            check(acc == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String), "keychain: accessibility = WhenUnlockedThisDeviceOnly (\(acc ?? "nil"))")
        } else {
            print("SKIP genai: keychain accessibility read-back (unsigned build → login keychain, which doesn't report kSecAttrAccessible; attribute is still passed)")
        }
        check(kc.set(secret + "2", for: "openai") == errSecSuccess && kc.get("openai") == secret + "2", "keychain: update")
        let inDefaults = UserDefaults.standard.dictionaryRepresentation().values.contains { "\($0)".contains("sk-selftest-") }
        check(!inDefaults, "keychain: key never written to UserDefaults")
        kc.delete("openai")
        check(kc.get("openai") == nil, "keychain: test item deleted")
    }

    static func testTolerantDecoding() {
        let json = #"{"prompt":"a red kite","unknownFutureKey":[1,2,3],"selected":7,"cost":"not a number"}"#
        let inf = try? JSONDecoder().decode(GenerativeLayerInfo.self, from: Data(json.utf8))
        check(inf?.prompt == "a red kite" && inf?.variations.isEmpty == true && inf?.selected == 0 && inf?.cost == 0, "metadata: tolerant decode (unknown keys, bad types, missing keys)")
        var st = DocumentState(width: 8, height: 8)
        let l = Layer.raster(name: "g", width: 8, height: 8)
        st.layers = [l]
        var i = GenerativeLayerInfo(); i.prompt = "p"; i.variations = [PixelBuffer(width: 4, height: 3)]; i.rect = IRect(x: 1, y: 2, width: 4, height: 3)
        st.generative[l.id] = i
        let d = try? JSONEncoder().encode(st)
        let back = d.flatMap { try? JSONDecoder().decode(DocumentState.self, from: $0) }
        check(back?.generative[l.id]?.prompt == "p" && back?.generative[l.id]?.variations.first?.width == 4 && back?.generative[l.id]?.rect == i.rect, "metadata: DocumentState round-trip")
        var old = DocumentState(width: 8, height: 8); old.layers = [l]
        let od = try? JSONEncoder().encode(old)
        let ob = od.flatMap { try? JSONDecoder().decode(DocumentState.self, from: $0) }
        check(ob != nil && ob!.generative.isEmpty, "metadata: documents without generative data still decode")
    }

    static func testMaskEncoding() {
        let m = PixelBuffer(width: 40, height: 20, format: .gray)
        m.context.setFillColor(gray: 1, alpha: 1); m.context.fill(CGRect(x: 10, y: 5, width: 20, height: 10)); m.markDirty()
        checkMask(decodeImage(GenImaging.encodeMask(m, kind: .alphaTransparentEdit)), alpha: true, expectSize: (40, 20), center: (0.5, 0.5), "encode alpha mask")
        checkMask(decodeImage(GenImaging.encodeMask(m, kind: .grayWhiteEdit)), alpha: false, expectSize: (40, 20), center: (0.5, 0.5), "encode gray mask")
        let caps = OpenAIProvider.caps
        let (w, h) = GenImaging.sendSize(for: 300, 120, caps: caps, quality: .standard)
        check(w % 16 == 0 && h % 16 == 0 && w * h >= 655_360 && w * h <= 8_294_400, "OpenAI send size \(w)x\(h) valid (multiple of 16, pixel budget)")
        let (sw, sh) = GenImaging.sendSize(for: 4000, 3000, caps: StabilityProvider.caps(), quality: .standard)
        check(max(sw, sh) <= 1024 && sw % 8 == 0, "Stability send size \(sw)x\(sh)")
        check(GenImaging.aspectString(1920, 1080) == "16:9" && GenImaging.aspectString(1000, 1000) == "1:1", "aspect snapping")
    }

    /// Local compositing only (fake provider result): outside-selection pixels must be byte-identical.
    static func testLocalCompositing(_ out: URL) {
        let d = testDoc()
        let before = d.state
        let sel = before.selection!
        let model = ProviderRouter.shared.model("stability:inpaint")!
        let pl = GenPipeline.plan(state: before, sel: sel, model: model)
        check(pl.rect.width > sel.opaqueBounds()!.width && pl.rect.x >= 0 && pl.rect.maxX <= before.width, "plan: context rect \(pl.rect) around selection, inside canvas")
        let fake = PixelBuffer(width: pl.sendW, height: pl.sendH)
        fake.context.setFillColor(RGBA(hex: "FF2D55")!.cgColor); fake.context.fill(CGRect(x: 0, y: 0, width: pl.sendW, height: pl.sendH)); fake.markDirty()
        let v = GenPipeline.variations([GenImage(image: fake.makeCGImage())], plan: pl)
        GenPipeline.addLayer(d, name: "fake", rect: pl.rect, variations: v, info: GenerativeLayerInfo())
        let (outDiff, inChanged) = compareOutside(before, d.state, sel: sel)
        check(outDiff == 0, "local composite: \(outDiff) pixels changed outside the selection (must be 0)")
        check(inChanged > 1000, "local composite: \(inChanged) pixels changed inside the selection")
        SelfTest.save(before, "genai_local_before", out)
        SelfTest.save(d.state, "genai_local_after", out)
    }

    static func testRouter() {
        let saved = GenAIKeyOverrides.keys
        GenAIKeyOverrides.keys = [.stability: "x"]
        let real = ProviderID.allCases.filter { $0 != .stability && GenAIKeychain.shared.has($0.rawValue) }
        if real.isEmpty {
            let r = try? ProviderRouter.shared.resolve(.fill)
            check(r?.1.provider == .stability, "router: only keyed providers are offered (fill → \(r?.1.id ?? "nil"))")
            check(ProviderRouter.shared.available(for: .fill).allSatisfy { $0.provider == .stability }, "router: available() filters by key")
            do { _ = try ProviderRouter.shared.resolve(.denoise); check(false, "router: denoise without fal key throws") }
            catch { check((error as? GenError) == .noProvider(.denoise), "router: missing key → \((error as? GenError)?.errorDescription ?? "")") }
        } else {
            print("SKIP genai: router key-filter test (real keys present for \(real.map(\.rawValue)))")
        }
        GenAISettings.shared.data.routing["fill"] = "stability:inpaint"
        check((try? ProviderRouter.shared.resolve(.fill))?.1.id == "stability:inpaint", "router: user override honoured")
        GenAISettings.shared.data.routing = [:]
        GenAIKeyOverrides.keys = saved
    }

    // MARK: - Mock server

    static func startMock() -> (Process, Int)? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let e = ProcessInfo.processInfo.environment["LUMEN_GENAI_MOCK_SCRIPT"] { candidates.append(e) }
        candidates.append(fm.currentDirectoryPath + "/scripts/genai_mock_server.py")
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(exe.deletingLastPathComponent().appendingPathComponent("../../scripts/genai_mock_server.py").standardized.path)
        guard let script = candidates.first(where: { fm.fileExists(atPath: $0) }) else { return nil }
        let port = Int.random(in: 20000...40000)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script, String(port)]
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let ok = wait(8) {
            if case .success = sync({ try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/__log")!) }) { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1)); return false
        }
        if !ok { p.terminate(); return nil }
        print("genai: mock server on :\(port) (\(script))")
        return (p, port)
    }

    // MARK: - Provider request/response tests

    static func testKeyChecks(_ base: String) {
        for p in ProviderID.allCases {
            let r = sync { try await ProviderRouter.shared.providers[p]!.testKey("test-\(p.rawValue)-key") }
            if case .success(let s) = r { check(s.hasPrefix("Key OK"), "\(p.rawValue): Test key → \(s)") }
            else if case .failure(let e) = r { check(false, "\(p.rawValue): Test key failed: \(e)") }
        }
        let l = log(base)
        check(l.contains { $0.path == "/openai/v1/models" && $0.header("Authorization") == "Bearer test-openai-key" }, "openai: key test GET /v1/models with Bearer")
        check(l.contains { $0.path == "/gemini/v1beta/models" && $0.header("x-goog-api-key") == "test-gemini-key" }, "gemini: key test GET /v1beta/models with x-goog-api-key")
        check(l.contains { $0.path == "/stability/v1/user/balance" }, "stability: key test GET /v1/user/balance")
        check(l.contains { $0.path.hasPrefix("/fal/") && $0.path.hasSuffix("/status") && $0.header("Authorization") == "Key test-fal-key" }, "fal: key test with Authorization: Key")
        check(l.contains { $0.path == "/replicate/v1/account" }, "replicate: key test GET /v1/account")
        check(l.contains { $0.path == "/bfl/v1/credits" && $0.header("x-key") == "test-bfl-key" }, "bfl: key test GET /v1/credits with x-key")
        check(!l.contains { $0.query.contains("test-") || $0.path.contains("test-") }, "keys never appear in URLs")
    }

    /// Runs a region feature against the mock and returns the document + the submit requests.
    static func region(_ base: String, _ model: String, feature: GenFeature = .fill, prompt: String = "a hot air balloon") -> (Document, DocumentState, GenRegionPlan, [Req], String?) {
        control(base, "/__reset")
        let d = testDoc()
        let before = d.state
        let m = ProviderRouter.shared.model(model)!
        let pl = GenPipeline.plan(state: before, sel: before.selection, model: m)
        let err = job { GenPipeline.runRegion(d, feature: feature, prompt: prompt, sel: before.selection, modelOverride: model) }
        return (d, before, pl, log(base), err)
    }

    static func selCenter(_ st: DocumentState, _ pl: GenRegionPlan) -> (Double, Double) {
        let b = st.selection!.opaqueBounds()!
        return ((Double(b.x) + Double(b.width) / 2 - Double(pl.rect.x)) / Double(pl.rect.width), (Double(b.y) + Double(b.height) / 2 - Double(pl.rect.y)) / Double(pl.rect.height))
    }

    static func checkResult(_ name: String, _ d: Document, _ before: DocumentState, _ err: String?, variations: Int = 3, out: URL? = nil) {
        check(err == nil, "\(name): job succeeded (\(err ?? "ok"))")
        guard let (id, inf) = d.state.generative.first else { check(false, "\(name): generative layer created"); return }
        check(inf.variations.count == variations, "\(name): \(inf.variations.count) variations stored (expected \(variations))")
        check(d.state.layer(id)?.raster?.buffer === inf.variations.first, "\(name): layer shows variation 1")
        let (outDiff, inChanged) = compareOutside(before, d.state, sel: before.selection!)
        check(outDiff == 0 && inChanged > 500, "\(name): outside selection byte-identical (\(outDiff) diffs), inside changed (\(inChanged))")
        if let out { SelfTest.save(d.state, "genai_\(name)_after", out) }
    }

    static func testProviders(_ base: String, _ out: URL) {
        // OpenAI edits (multipart, RGBA mask)
        do {
            let (d, before, pl, l, err) = region(base, "openai:gpt-image-2.5-sunburst")
            SelfTest.save(before, "genai_before", out)
            checkResult("openai_fill", d, before, err, out: out)
            let subs = l.filter { $0.path == "/openai/v1/images/edits" }
            check(subs.count == 1, "openai: one edits call for 3 variations (n=3), got \(subs.count)")
            if let r = subs.first {
                check(r.header("Authorization") == "Bearer test-openai-key", "openai: Bearer auth")
                check(r.header("Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true, "openai: multipart")
                check(r.field("model") == "gpt-image-2.5-sunburst" && r.field("n") == "3" && r.field("prompt") == "a hot air balloon", "openai: model/n/prompt fields")
                check(r.field("size") == "\(pl.sendW)x\(pl.sendH)" && r.field("quality") == "medium" && r.field("output_format") == "png", "openai: size \(r.field("size") ?? "?") quality output_format")
                let img = decodeImage(r.multipart["image[]"]?.first)
                check(img?.width == pl.sendW && img?.height == pl.sendH, "openai: image[] PNG \(img?.width ?? 0)x\(img?.height ?? 0)")
                checkMask(decodeImage(r.multipart["mask"]?.first), alpha: true, expectSize: (pl.sendW, pl.sendH), center: selCenter(before, pl), "openai mask")
            }
            if let inf = d.state.generative.first?.value { check(abs(inf.cost - (1500 * 30 + 1100 * 8 + 100 * 5) / 1_000_000) < 1e-6, "openai: cost from usage tokens ($\(inf.cost))") }
            // Properties-panel flows on this layer: switch variation, regenerate, similar
            if let id = d.state.generative.first?.key {
                GenPipeline.selectVariation(d, layerID: id, index: 2)
                check(d.state.layer(id)?.raster?.buffer === d.state.generative[id]?.variations[2] && d.state.generative[id]?.selected == 2, "variations: switching shows variation 3")
                let e1 = job { GenPipeline.regenerate(d, layerID: id, prompt: "a red balloon") }
                check(e1 == nil && d.state.generative[id]?.variations.count == 6 && d.state.generative[id]?.prompt == "a red balloon", "variations: Generate again appends 3 (now \(d.state.generative[id]?.variations.count ?? 0))")
                let e2 = job { GenPipeline.regenerate(d, layerID: id, similar: true) }
                check(e2 == nil && d.state.generative[id]?.variations.count == 9, "variations: Generate Similar appends 3 (\(e2 ?? "ok"))")
                let (outDiff, _) = compareOutside(before, d.state, sel: before.selection!)
                check(outDiff == 0, "variations: regenerated layer still byte-identical outside selection")
                d.undo()
                check(d.state.generative[id]?.variations.count == 6, "variations: undo restores metadata")
            }
        }
        // Gemini generateContent (image + mask as inline parts)
        do {
            let (d, before, pl, l, err) = region(base, "gemini:gemini-3.1-flash-image")
            checkResult("gemini_fill", d, before, err, out: out)
            let subs = l.filter { $0.path == "/gemini/v1beta/models/gemini-3.1-flash-image:generateContent" }
            check(subs.count == 3, "gemini: 3 generateContent calls for 3 variations (got \(subs.count))")
            if let r = subs.first, let j = r.json {
                check(r.header("x-goog-api-key") == "test-gemini-key", "gemini: x-goog-api-key header")
                let parts = ((j["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]]) ?? []
                check(parts.count == 3 && (parts[0]["text"] as? String)?.contains("white marks the region") == true, "gemini: text + image + mask parts")
                let img = decodeB64((parts[genSafe: 1]?["inlineData"] as? [String: Any])?["data"] as? String)
                check(img?.width == pl.sendW, "gemini: inline image \(img?.width ?? 0)x\(img?.height ?? 0)")
                checkMask(decodeB64((parts[genSafe: 2]?["inlineData"] as? [String: Any])?["data"] as? String), alpha: false, expectSize: (pl.sendW, pl.sendH), center: selCenter(before, pl), "gemini mask")
                let gc = j["generationConfig"] as? [String: Any]
                check((gc?["responseModalities"] as? [String]) == ["TEXT", "IMAGE"] && ((gc?["imageConfig"] as? [String: Any])?["aspectRatio"] as? String) != nil, "gemini: responseModalities + imageConfig.aspectRatio")
            }
        }
        // Stability inpaint + erase (multipart, gray mask, Accept json)
        for (model, path, feature) in [("stability:inpaint", "/stability/v2beta/stable-image/edit/inpaint", GenFeature.fill), ("stability:erase", "/stability/v2beta/stable-image/edit/erase", .remove)] {
            let (d, before, pl, l, err) = region(base, model, feature: feature)
            checkResult("stability_\(feature.rawValue)", d, before, err)
            let subs = l.filter { $0.path == path }
            check(subs.count == 3, "stability \(feature.rawValue): 3 calls (got \(subs.count))")
            if let r = subs.first {
                check(r.header("Authorization") == "Bearer test-stability-key" && r.header("Accept") == "application/json", "stability: Bearer + Accept: application/json")
                check(r.field("output_format") == "png" && r.field("grow_mask") == "5", "stability: output_format/grow_mask")
                if feature == .fill { check(r.field("prompt") == "a hot air balloon", "stability: prompt field") }
                checkMask(decodeImage(r.multipart["mask"]?.first), alpha: false, expectSize: (pl.sendW, pl.sendH), center: selCenter(before, pl), "stability \(feature.rawValue) mask")
            }
        }
        // Stability async relight (background) → poll /v2beta/results/{id}
        do {
            let (d, before, _, l, err) = region(base, "stability:replace-background-and-relight", feature: .background, prompt: "a beach at sunset")
            checkResult("stability_relight", d, before, err)
            check(l.filter { $0.path == "/stability/v2beta/results/st-async-1" }.count >= 2, "stability: async result polled until 200 (202 first)")
            if let r = l.first(where: { $0.path.hasSuffix("replace-background-and-relight") }) {
                check(r.multipart["subject_image"] != nil && r.field("background_prompt") == "a beach at sunset", "stability relight: subject_image + background_prompt")
            }
        }
        // fal queue (flux fill, JSON + data URIs, polling, result URL fetch, X-Fal-Store-IO)
        do {
            let (d, before, pl, l, err) = region(base, "fal:fal-ai/flux-pro/v1/fill")
            checkResult("fal_fill", d, before, err)
            let subs = l.filter { $0.method == "POST" && $0.path == "/fal/fal-ai/flux-pro/v1/fill" }
            check(subs.count == 1, "fal: one submit with num_images=3 (got \(subs.count))")
            if let r = subs.first, let j = r.json {
                check(r.header("Authorization") == "Key test-fal-key" && r.header("X-Fal-Store-IO") == "0", "fal: Key auth + X-Fal-Store-IO: 0")
                check(j["num_images"] as? Int == 3 && j["output_format"] as? String == "png" && j["prompt"] as? String == "a hot air balloon", "fal: num_images/output_format/prompt")
                check((j["image_url"] as? String)?.hasPrefix("data:image/png;base64,") == true, "fal: image_url data URI")
                checkMask(decodeB64(j["mask_url"] as? String), alpha: false, expectSize: (pl.sendW, pl.sendH), center: selCenter(before, pl), "fal mask_url")
            }
            check(l.filter { $0.path.hasSuffix("/status") && $0.query.contains("logs=1") }.count >= 3, "fal: status polled (IN_QUEUE → IN_PROGRESS → COMPLETED)")
            check(l.contains { $0.method == "GET" && $0.path.hasSuffix("/requests/req-0") || $0.path.range(of: #"/requests/req-\d+$"#, options: .regularExpression) != nil && $0.method == "GET" }, "fal: response_url fetched")
        }
        // Replicate flux-fill-pro (predictions + polling, data URIs ≤ 256 KB)
        do {
            let (d, before, pl, l, err) = region(base, "replicate:black-forest-labs/flux-fill-pro")
            checkResult("replicate_fill", d, before, err)
            let subs = l.filter { $0.path == "/replicate/v1/models/black-forest-labs/flux-fill-pro/predictions" }
            check(subs.count == 3, "replicate: 3 predictions (got \(subs.count))")
            if let r = subs.first, let input = r.json?["input"] as? [String: Any] {
                check(r.header("Authorization") == "Bearer test-replicate-key" && r.header("Prefer") == "wait=60", "replicate: Bearer + Prefer: wait=60")
                check((input["image"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true && input["prompt"] as? String == "a hot air balloon", "replicate: input.image data URI + prompt")
                checkMask(decodeB64(input["mask"] as? String), alpha: false, expectSize: (pl.sendW, pl.sendH), center: selCenter(before, pl), "replicate mask")
            }
            check(l.filter { $0.path.hasPrefix("/replicate/v1/predictions/") }.count >= 6, "replicate: predictions polled")
        }
        // Replicate file upload (> 256 KB) + cleanup
        do {
            control(base, "/__reset")
            let rp = ReplicateProvider()
            let noise = Data((0..<300_000).map { _ in UInt8.random(in: 0...255) })
            var uploaded: [String] = []
            let r = sync { () -> String in var u: [String] = []; let s = try await rp.fileURL(noise, mime: "image/png", key: "test-replicate-key", uploaded: &u); uploaded = u; return s }
            if case .success(let url) = r { check(url.hasSuffix("/v1/files/file-1") && uploaded == ["file-1"], "replicate: large input uploaded via POST /v1/files → urls.get") }
            else { check(false, "replicate: file upload") }
            let job = PendingJob(id: "x", pollURL: URL(string: base)!, extra: ["files": uploaded.joined(separator: ",")])
            _ = sync { await rp.cleanup(job, key: "test-replicate-key"); return true }
            let l = log(base)
            if let up = l.first(where: { $0.path == "/replicate/v1/files" }) { check(up.multipart["content"]?.first?.count == 300_000, "replicate: multipart field 'content' carries the file") }
            check(l.contains { $0.method == "DELETE" && $0.path == "/replicate/v1/files/file-1" }, "replicate: uploaded file deleted after the job")
        }
        // BFL fill (JSON base64, x-key, polling_url)
        do {
            let (d, before, pl, l, err) = region(base, "bfl:flux-pro-1.0-fill")
            checkResult("bfl_fill", d, before, err)
            let subs = l.filter { $0.path == "/bfl/v1/flux-pro-1.0-fill" }
            check(subs.count == 3, "bfl: 3 submits (got \(subs.count))")
            if let r = subs.first, let j = r.json {
                check(r.header("x-key") == "test-bfl-key", "bfl: x-key header")
                check(j["prompt"] as? String == "a hot air balloon" && j["output_format"] as? String == "png" && j["steps"] as? Int == 50, "bfl: prompt/output_format/steps")
                check(decodeB64(j["image"] as? String)?.width == pl.sendW, "bfl: image base64")
                checkMask(decodeB64(j["mask"] as? String), alpha: false, expectSize: (pl.sendW, pl.sendH), center: selCenter(before, pl), "bfl mask")
            }
            check(l.filter { $0.path == "/bfl/v1/get_result" }.count >= 6, "bfl: polling_url followed until Ready")
            if let inf = d.state.generative.first?.value { check(abs(inf.cost - 0.15) < 1e-9, "bfl: cost from reported credits ($\(inf.cost))") }
        }
        // BFL erase + fal bria eraser (remove)
        for model in ["bfl:flux-tools/erase-v1", "fal:fal-ai/bria/eraser", "fal:fal-ai/nano-banana-2/edit", "fal:openai/gpt-image-2.5/flare/edit"] {
            let (d, before, _, _, err) = region(base, model, feature: model.contains("erase") ? .remove : .fill)
            checkResult(model.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_"), d, before, err, variations: 3)
        }
    }

    static func testWholeImage(_ base: String, _ out: URL) {
        // Generate Image (per provider) into an open document
        let d0 = testDoc()
        d0.state.selection = nil
        AppModel.shared.add(d0)
        defer { AppModel.shared.close(d0) }
        for model in ["openai:gpt-image-2.5-flare", "gemini:gemini-3-pro-image", "stability:generate/core", "fal:fal-ai/nano-banana-2", "replicate:black-forest-labs/flux-kontext-pro", "bfl:flux-2-pro"] {
            control(base, "/__reset")
            let n = d0.state.layers.count
            let err = job { GenPipeline.generateImage(prompt: "a lighthouse", style: "Cinematic", contentType: .photo, aspect: "16:9", reference: nil, modelOverride: model) }
            check(err == nil && d0.state.layers.count == n + 1, "generate image via \(model): layer added (\(err ?? "ok"))")
            let l = log(base).filter { $0.method == "POST" }
            if model.hasPrefix("openai"), let j = l.first(where: { $0.path == "/openai/v1/images/generations" })?.json {
                check(j["model"] as? String == "gpt-image-2.5-flare" && j["n"] as? Int == 3 && (j["prompt"] as? String)?.contains("lighthouse") == true && (j["size"] as? String)?.contains("x") == true, "openai generations JSON (\(j["size"] ?? ""))")
            }
            if model.hasPrefix("gemini"), let j = l.first?.json {
                let ic = (j["generationConfig"] as? [String: Any])?["imageConfig"] as? [String: Any]
                check(ic?["aspectRatio"] as? String == "16:9" && ic?["imageSize"] as? String == "1K", "gemini generate: aspectRatio 16:9, imageSize 1K")
            }
            if model.hasPrefix("stability"), let r = l.first { check(r.field("aspect_ratio") == "16:9" && r.path.hasSuffix("generate/core"), "stability generate/core aspect_ratio") }
            if model.hasPrefix("bfl"), let j = l.first?.json { check((j["width"] as? Int ?? 0) > (j["height"] as? Int ?? 0), "bfl flux-2-pro width/height") }
        }
        SelfTest.save(d0.state, "genai_generate_image", out)

        // Generative Expand: Stability outpaint (native padding) and BFL expand
        for model in ["stability:outpaint", "bfl:flux-pro-1.0-expand", "fal:fal-ai/flux-pro/v1/fill"] {
            control(base, "/__reset")
            let d = testDoc(); d.state.selection = nil
            AppModel.shared.add(d)
            let before = d.state
            GenAISettings.shared.data.routing["expand"] = model
            let err = job { GenAIActions.expandCanvas(left: 60, right: 60, top: 0, bottom: 40, prompt: "") }
            GenAISettings.shared.data.routing = [:]
            check(err == nil && d.state.width == 600 && d.state.height == 340 && d.state.generative.count == 1, "expand via \(model): canvas 600×340 + generative layer (\(err ?? "ok"))")
            let l = log(base).filter { $0.method == "POST" }
            if model == "stability:outpaint", let r = l.first {
                let lft = Int(r.field("left") ?? "0") ?? 0, rgt = Int(r.field("right") ?? "0") ?? 0, dn = Int(r.field("down") ?? "0") ?? 0
                check(lft > 0 && rgt > 0 && dn > 0 && r.field("up") == "0", "stability outpaint: left/right/down padding (\(lft),\(rgt),\(dn))")
            }
            if model == "bfl:flux-pro-1.0-expand", let j = l.first?.json {
                check((j["left"] as? Int ?? 0) > 0 && (j["bottom"] as? Int ?? 0) > 0 && j["top"] as? Int == 0, "bfl expand: left/right/top/bottom")
            }
            // original pixels away from the seam unchanged; new area filled
            var st2 = d.state
            if let id = st2.generative.first?.key { st2.removeLayer(id) }
            let orig = PixelBuffer(width: 600, height: 340, format: .gray)
            orig.context.setFillColor(gray: 1, alpha: 1); orig.context.fill(CGRect(x: 60 + 14, y: 14, width: 480 - 28, height: 300 - 28)); orig.markDirty()
            let (diffInsideOriginal, _) = compareOutside(st2, d.state, sel: SelectionOps.invert(orig))
            check(diffInsideOriginal == 0, "expand via \(model): original pixels (≥14 px from the seam) unchanged (\(diffInsideOriginal) diffs)")
            let comp = GenImaging.composite(d.state, rect: d.state.canvasRect)
            check(comp.alpha(5, 150) == 255 && comp.alpha(590, 150) == 255 && comp.alpha(300, 335) == 255, "expand via \(model): new area filled opaque")
            if model == "stability:outpaint" { SelfTest.save(before, "genai_expand_before", out); SelfTest.save(d.state, "genai_expand_after", out) }
            AppModel.shared.close(d)
        }

        // Harmonize (fal IC-Light): new layer + contact shadow, source hidden
        do {
            control(base, "/__reset")
            let d = testDoc(); d.state.selection = nil
            AppModel.shared.add(d)
            let src = d.state.layers.last!.id
            d.selectLayer(src)
            let err = job { GenAIActions.harmonize(prompt: "", light: "left", modelOverride: "fal:fal-ai/iclight-v2") }
            check(err == nil && d.state.layers.contains { $0.name.hasSuffix("(Harmonized)") } && d.state.layers.contains { $0.name == "Contact Shadow" } && d.state.layer(src)?.isVisible == false,
                  "harmonize: harmonized layer + contact shadow, original hidden (\(err ?? "ok"))")
            if let j = log(base).first(where: { $0.path == "/fal/fal-ai/iclight-v2" })?.json {
                check(j["initial_latent"] as? String == "Left" && (j["mask_image_url"] as? String)?.hasPrefix("data:image/png") == true, "fal iclight: initial_latent + mask_image_url")
            }
            SelfTest.save(d.state, "genai_harmonize", out)
            AppModel.shared.close(d)
        }

        // Upscale (new document), Denoise / Sharpen (Topaz via fal)
        do {
            control(base, "/__reset")
            let d = testDoc()
            let n = AppModel.shared.documents.count
            let err = job { GenPipeline.enhance(d, feature: .upscale, factor: 2, modelOverride: "stability:upscale/fast") }
            check(err == nil && AppModel.shared.documents.count == n + 1 && AppModel.shared.documents.last?.state.width == 960, "upscale (stability fast): new \(AppModel.shared.documents.last?.state.width ?? 0)px document")
            if let nd = AppModel.shared.documents.last, AppModel.shared.documents.count == n + 1 { AppModel.shared.close(nd) }
            for f in [GenFeature.denoise, .sharpen] {
                control(base, "/__reset")
                let e = job { GenPipeline.enhance(d, feature: f) }
                let j = log(base).first { $0.path == "/fal/fal-ai/topaz/upscale/image" }?.json
                check(e == nil && (j?["upscale_factor"] as? Double ?? Double(j?["upscale_factor"] as? Int ?? 0)) == 1 && j?[f == .denoise ? "denoise" : "sharpen"] != nil,
                      "\(f.rawValue): Topaz request (upscale_factor 1) and layer added (\(e ?? "ok"))")
            }
            check(d.state.layers.filter { $0.name == "AI Denoise" || $0.name == "AI Sharpen" }.count == 2, "denoise/sharpen layers added")
            // UpscalerRegistry hook
            GenAISettings.shared.data.routing["upscale"] = "fal:fal-ai/topaz/upscale/image"
            let img = GenImaging.composite(d.state, rect: d.state.canvasRect).makeCGImage()
            let r = sync { try await UpscalerRegistry.upscalers.first(where: { $0.name.contains("Generative") })!.run(img, 2) }
            if case .success(let up) = r { check(up.width > 0, "UpscalerRegistry: cloud upscaler returns an image") } else { check(false, "UpscalerRegistry run") }
            GenAISettings.shared.data.routing = [:]
        }
    }

    static func testErrors(_ base: String) {
        // moderation per provider → clear message, no crash
        for (model, feature) in [("openai:gpt-image-2.5-flare", GenFeature.fill), ("gemini:gemini-3.1-flash-image", .fill), ("stability:inpaint", .fill),
                                 ("fal:fal-ai/flux-pro/v1/fill", .fill), ("replicate:black-forest-labs/flux-fill-pro", .fill), ("bfl:flux-pro-1.0-fill", .fill)] {
            control(base, "/__reset")
            control(base, "/__scenario", ["name": "moderation", "count": 1])
            let d = testDoc()
            let err = job { GenPipeline.runRegion(d, feature: feature, prompt: "x", sel: d.state.selection, modelOverride: model) }
            check(err?.contains("content filter") == true && d.state.generative.isEmpty, "moderation (\(model)) → “\(err ?? "no error")”")
        }
        // 429 with Retry-After: 1 → retried and succeeds
        do {
            control(base, "/__reset")
            control(base, "/__scenario", ["name": "ratelimit", "count": 1])
            let d = testDoc()
            let t0 = Date()
            let err = job { GenPipeline.runRegion(d, feature: .fill, prompt: "x", sel: d.state.selection, modelOverride: "openai:gpt-image-2.5-flare") }
            let posts = log(base).filter { $0.method == "POST" }.count
            check(err == nil && posts == 2 && Date().timeIntervalSince(t0) >= 1, "429 Retry-After: 1 → retried once and succeeded (\(posts) POSTs)")
        }
        // 429 with a long Retry-After → clear message
        do {
            control(base, "/__reset")
            control(base, "/__scenario", ["name": "ratelimit_long", "count": 1])
            let d = testDoc()
            let err = job { GenPipeline.runRegion(d, feature: .fill, prompt: "x", sel: d.state.selection, modelOverride: "stability:inpaint") }
            check(err?.contains("Rate limited") == true && err?.contains("120") == true, "429 Retry-After: 120 → “\(err ?? "")”")
        }
        // bad key
        do {
            control(base, "/__reset")
            control(base, "/__scenario", ["name": "auth", "count": 1])
            let d = testDoc()
            let err = job { GenPipeline.runRegion(d, feature: .fill, prompt: "x", sel: d.state.selection, modelOverride: "bfl:flux-pro-1.0-fill") }
            check(err?.contains("rejected") == true, "401 → “\(err ?? "")”")
            control(base, "/__scenario", ["name": "ok", "count": 0])
        }
        // network failure
        do {
            let saved = GenHTTP.overrides[.gemini]
            GenHTTP.overrides[.gemini] = "http://127.0.0.1:9"
            let d = testDoc()
            let err = job { GenPipeline.runRegion(d, feature: .fill, prompt: "x", sel: d.state.selection, modelOverride: "gemini:gemini-3.1-flash-image") }
            check(err?.contains("Network error") == true, "network failure → “\(err ?? "")”")
            GenHTTP.overrides[.gemini] = saved
        }
        // missing key for the requested provider → falls through to no provider message when nothing is keyed
        do {
            let saved = GenAIKeyOverrides.keys
            GenAIKeyOverrides.keys = [:]
            if ProviderID.allCases.allSatisfy({ !GenAIKeychain.shared.has($0.rawValue) }) {
                let d = testDoc()
                AppModel.shared.add(d)
                let err = job { GenAIActions.generativeFill(prompt: "x") }
                AppModel.shared.close(d)
                check(err?.contains("No") == true, "no keys → “\(err ?? "")”")
                let d2 = testDoc()
                let e2 = job { GenPipeline.runRegion(d2, feature: .fill, prompt: "x", sel: d2.state.selection) }
                check(e2?.contains("Preferences ▸ Generative AI") == true, "missing key → “\(e2 ?? "")”")
            }
            GenAIKeyOverrides.keys = saved
        }
        // no selection
        do {
            let d = testDoc(); d.state.selection = nil
            AppModel.shared.add(d)
            let err = job { GenAIActions.generativeFill(prompt: "x") }
            check(err == GenError.noSelection.errorDescription, "no selection → “\(err ?? "")”")
            AppModel.shared.close(d)
        }
        // cancel (fal job stuck in queue → PUT cancel_url)
        do {
            control(base, "/__reset")
            control(base, "/__scenario", ["name": "slow", "count": 1000])
            let d = testDoc()
            GenJobs.shared.lastError = nil
            GenPipeline.runRegion(d, feature: .fill, prompt: "x", sel: d.state.selection, modelOverride: "fal:fal-ai/flux-pro/v1/fill")
            _ = wait(1.0) { false }
            if let j = GenJobs.shared.active.first { GenJobs.shared.cancel(j.id) }
            let done = wait(10) { GenJobs.shared.active.isEmpty }
            control(base, "/__scenario", ["name": "ok", "count": 0])
            let l = log(base)
            check(done && l.contains { $0.method == "PUT" && $0.path.hasSuffix("/cancel") } && d.state.generative.isEmpty && GenJobs.shared.lastError == nil,
                  "cancel: job stopped, fal cancel_url PUT sent, nothing added")
            check(GenJobs.shared.history.first?.status == "cancelled", "history: cancelled job recorded")
        }
        check(GenJobs.shared.history.contains { $0.status == "ok" && $0.cost > 0 }, "history: entries with provider, cost and time recorded (\(GenJobs.shared.history.count))")
        check(GenAISettings.shared.spendThisMonth > 0, String(format: "spend counter: $%.3f this month", GenAISettings.shared.spendThisMonth))
    }
}
