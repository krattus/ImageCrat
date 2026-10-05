import AppKit
import SwiftUI
import ImageCratCore

/// Adding effects to layers that arrive from a PSD with a layer style already on them ('lfx2' / 'lmfx'): every entry
/// point (Layers panel fx menu, Layer ▸ Layer Style ▸ <effect>, the Layer Style dialog's checkboxes, row clicks and "+",
/// Properties ▸ Layer Style…, Paste Layer Style, the clipboard history) on raster, shape, type, group and smart-object
/// layers, with several instances of the multi-instance effects, Photoshop's 'present' false placeholders, long-form
/// blend mode names, unknown keys, the master switch off and per-effect eyes. Each case checks that the imported
/// effects stay as they were, the new one is listed and drawn, Undo / Redo restore both states and a PSD round trip
/// keeps everything.
/// `LUMEN_SELFTEST_ONLY=psdfxadd Lumen --selftest <dir>`; `LUMEN_PSDFX_SAMPLES=<dir>` adds the real Photoshop files
/// (`ps_resave_*.psd`, `ic_export_*.psd`); `LUMEN_PSDFX_IMAGES=<dir>` is where the before / after renders go
/// (default `<dir>/psdfxadd`).
enum PSDFXAddSelfTest {
    static var passes = 0, failures = 0
    static var imgDir = URL(fileURLWithPath: NSTemporaryDirectory())
    static var workDir = URL(fileURLWithPath: NSTemporaryDirectory())

    static func register() {
        FeatureModules.selfTests.append(("psdfxadd", { out in run(out) }))
    }

    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") psdfxadd: \(name)\(d.isEmpty || ok ? "" : " — " + d)")
        fflush(stdout)
    }

    static func run(_ out: URL) {
        passes = 0; failures = 0
        let env = ProcessInfo.processInfo.environment
        workDir = out.appendingPathComponent("psdfxadd")
        imgDir = env["LUMEN_PSDFX_IMAGES"].map { URL(fileURLWithPath: $0) } ?? workDir
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
        let app = AppModel.shared
        let saved = (docs: app.documents, active: app.activeDocumentID, copied: AppActions.copiedEffects, dialog: app.dialog)
        defer {
            app.dialog = nil
            app.documents = saved.docs; app.activeDocumentID = saved.active
            AppActions.copiedEffects = saved.copied
            LayerStyleDialog.openingSection = nil
        }
        let t0 = Date()
        codec()
        synthetic()
        hiddenMaster()
        eyes()
        dialogInstances()
        globalLight()
        layerKinds()
        menus()
        drags()
        if let dir = env["LUMEN_PSDFX_SAMPLES"] { samples(URL(fileURLWithPath: dir)) }
        print("psdfxadd: \(passes) passed, \(failures) failed (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s)")
    }

    // MARK: Fixtures

    static let W = 240, H = 240
    static let box = CGRect(x: 70, y: 70, width: 100, height: 100)

    static func boxBuffer(_ c: RGBA = RGBA(hex: "4C7BD9")!) -> PixelBuffer {
        let b = PixelBuffer(width: W, height: H)
        b.context.setFillColor(c.cgColor); b.context.fill(box); b.markDirty()
        return b
    }

    static func white() -> PixelBuffer {
        let b = PixelBuffer(width: W, height: H)
        b.context.setFillColor(CGColor(gray: 1, alpha: 1)); b.context.fill(CGRect(x: 0, y: 0, width: W, height: H)); b.markDirty()
        return b
    }

    /// The style the synthetic files carry: two drop shadows, two inner shadows, two colour overlays (the second hidden
    /// with its eye), two gradient overlays, two strokes and an outer glow.
    static func importedStyle() -> LayerEffects {
        var f = LayerEffects()
        f.dropShadow = ShadowEffect(enabled: true, color: RGBA(hex: "202020")!, opacity: 0.6, angle: 120, distance: 8, size: 6, useGlobalLight: false)
        f.extraDropShadows = [ShadowEffect(enabled: true, color: RGBA(hex: "D02020")!, opacity: 0.8, angle: 30, distance: 14, size: 2, useGlobalLight: false)]
        f.innerShadow = ShadowEffect(enabled: true, opacity: 0.5, angle: 90, distance: 4, size: 4, useGlobalLight: false)
        f.extraInnerShadows = [ShadowEffect(enabled: true, color: RGBA(hex: "FFFFFF")!, opacity: 0.5, angle: 270, distance: 3, size: 3, useGlobalLight: false)]
        f.colorOverlay = ColorOverlayEffect(enabled: true, blendMode: .multiply, color: RGBA(hex: "FFE080")!, opacity: 0.5)
        f.extraColorOverlays = [ColorOverlayEffect(enabled: false, color: RGBA(hex: "00FF00")!, opacity: 1, isHidden: true)]
        f.gradientOverlay = GradientOverlayEffect(enabled: true, opacity: 0.3)
        f.extraGradientOverlays = [GradientOverlayEffect(enabled: true, blendMode: .screen, opacity: 0.2)]
        f.stroke = StrokeEffect(enabled: true, size: 3, position: .outside, paint: .color(RGBA(hex: "103080")!))
        f.extraStrokes = [StrokeEffect(enabled: true, size: 6, position: .outside, opacity: 0.6, paint: .color(RGBA(hex: "F0A000")!))]
        f.outerGlow = GlowEffect(enabled: true, opacity: 0.5, size: 12)
        return f
    }

    /// Long-form blend mode names Photoshop writes in newer files ('multiply', 'screen', 'linearDodge'…).
    static let longNames: [String: String] = ["Nrml": "normal", "Mltp": "multiply", "Scrn": "screen", "Ovrl": "overlay", "Drkn": "darken", "Lghn": "lighten",
                                              "CDdg": "colorDodge", "CBrn": "colorBurn", "SftL": "softLight", "HrdL": "hardLight", "Dfrn": "difference",
                                              "Xclu": "exclusion", "Dslv": "dissolve", "H   ": "hue", "Strt": "saturation", "Clr ": "color", "Lmns": "luminosity"]

    static func longForm(_ v: PSDDescriptorValue) -> PSDDescriptorValue {
        switch v {
        case .enumerated(let t, let e) where t == "BlnM": return .enumerated(type: t, value: longNames[e] ?? e)
        case .object(let d): return .object(longForm(d))
        case .list(let l): return .list(l.map(longForm))
        default: return v
        }
    }
    static func longForm(_ d: PSDDescriptor) -> PSDDescriptor {
        var o = d
        for i in o.entries.indices { o.entries[i].value = longForm(o.entries[i].value) }
        return o
    }

    /// An effect descriptor Photoshop writes for an effect that is not part of the style ('present' false).
    static func placeholder(_ cls: String) -> PSDDescriptorValue {
        .object(PSDDescriptor(classID: cls, [("enab", .bool(false)), ("present", .bool(false)), ("showInDialog", .bool(true)),
                                             ("Md  ", .enumerated(type: "BlnM", value: "normal")), ("Opct", .unitFloat(unit: "#Prc", value: 100))]))
    }

    enum Variant { case plain, photoshop, both, masterOff }

    /// 'lfx2' payload for `fx` the way Photoshop writes it: `.photoshop` puts every multi-instance kind in a '…Multi' list
    /// (with a 'present' false placeholder appended), uses long blend mode names, a 200 % 'Scl ', unknown keys at the
    /// root and inside effects and placeholders for the absent single effects; `.both` writes the classic key and a
    /// '…Multi' list with only placeholders (seen in Photoshop files); `.masterOff` hides the whole Effects group.
    static func lfx2(_ fx: LayerEffects, _ v: Variant) -> Data {
        var root = PSDLayerStyle.descriptor(fx)
        switch v {
        case .plain: break
        case .masterOff: root["masterFXSwitch"] = .bool(false)
        case .photoshop:
            root["Scl "] = .unitFloat(unit: "#Prc", value: 200)
            for (single, multi) in [("DrSh", "dropShadowMulti"), ("IrSh", "innerShadowMulti"), ("SoFi", "solidFillMulti"), ("GrFl", "gradientFillMulti"), ("FrFX", "frameFXMulti")] {
                var items: [PSDDescriptorValue] = root.list(multi) ?? (root[single].map { [$0] } ?? [])
                items = items.map { v in
                    guard case .object(var o) = v else { return v }
                    o["futureEffectKey"] = .string("unknown")
                    o["gs99"] = .enumerated(type: "gradientInterpolationMethodType", value: "Smoo")
                    return .object(o)
                }
                items.append(placeholder(single))
                root[single] = nil
                root[multi] = .list(items)
            }
            for k in ["IrGl", "ebbl", "ChFX"] where root[k] == nil { root[k] = placeholder(k) }
            root["futureRootKey"] = .objectArray(count: 1, PSDDescriptor(classID: "null", [("x", .integer(1))]))
            root = longForm(root)
        case .both:
            for (single, multi) in [("DrSh", "dropShadowMulti"), ("FrFX", "frameFXMulti")] {
                if let l = root.list(multi) { root[multi] = nil; root[single] = l.first }
                root[multi] = .list([placeholder(single)])
            }
        }
        var w = PSDDescriptorWriter()
        w.u32(0); w.u32(16); w.descriptor(root)
        return w.data
    }

    static func syntheticFile(_ fx: LayerEffects, _ v: Variant, light: Int32 = 120, group: Bool = false) -> PSDTestFile {
        var f = PSDTestFile(width: W, height: H)
        var lw = BinaryWriter(); lw.i32(light)
        f.resources.append((1037, "", lw.data))
        var bg = PSDTestLayer(name: "Background", buffer: white(), origin: .zero)
        bg.flags = 8
        var l = PSDTestLayer(name: "Styled", buffer: boxBuffer(), origin: .zero)
        l.add("lfx2", lfx2(fx, v))
        if group {
            var open = PSDTestLayer(name: "</Layer group>"); open.flags = 24
            var b = BinaryWriter(); b.u32(3); open.add("lsct", b.data)
            var grp = PSDTestLayer(name: "Styled Group"); grp.flags = 24
            b = BinaryWriter(); b.u32(1); b.ascii("8BIM"); b.ascii("norm"); grp.add("lsct", b.data)
            grp.add("lfx2", lfx2(fx, v))
            let inner = PSDTestLayer(name: "Inside", buffer: boxBuffer(), origin: .zero)
            f.layers = [bg, open, inner, grp]
        } else {
            f.layers = [bg, l]
        }
        return f
    }

    static func importFile(_ f: PSDTestFile, _ name: String) -> DocumentState? {
        let url = workDir.appendingPathComponent(name + ".psd")
        do {
            try f.data().write(to: url)
            return try PSDReader.read(url: url)
        } catch { check(false, "\(name): import", "\(error)"); return nil }
    }

    static func makeDoc(_ st: DocumentState, _ name: String) -> Document {
        let d = Document(state: st, name: name)
        d.needsFitOnScreen = false
        let app = AppModel.shared
        if !app.documents.contains(where: { $0 === d }) { app.documents.append(d) }
        app.activeDocumentID = d.id
        return d
    }

    static func close(_ d: Document) {
        AppModel.shared.dialog = nil
        AppModel.shared.documents.removeAll { $0 === d }
    }

    // MARK: Signatures

    static func json<T: Encodable>(_ v: T) -> String {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return (try? e.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
    }

    static func itemJSON(_ i: any LayerEffectItem) -> String {
        switch i {
        case let x as ShadowEffect: return json(x)
        case let x as GlowEffect: return json(x)
        case let x as BevelEffect: return json(x)
        case let x as SatinEffect: return json(x)
        case let x as ColorOverlayEffect: return json(x)
        case let x as GradientOverlayEffect: return json(x)
        case let x as PatternOverlayEffect: return json(x)
        case let x as StrokeEffect: return json(x)
        default: return "?"
        }
    }

    /// Listed effects (shown or hidden), panel order: kind + full settings.
    static func listed(_ fx: LayerEffects) -> [String] {
        fx.listedSlots.map { s in "\(s.kind.rawValue):" + (fx.item(s).map { itemJSON($0) } ?? "nil") }
    }

    /// What a PSD keeps: per listed effect its kind, shown / hidden and the main numbers.
    static func psdSig(_ fx: LayerEffects) -> [String] {
        func r(_ v: Double) -> String { String(format: "%.1f", v) }
        return fx.listedSlots.map { s -> String in
            var t = "\(s.kind.rawValue) \(fx.isShown(s) ? "on" : "off")"
            switch fx.item(s) {
            case let x as ShadowEffect: t += " d\(r(x.distance)) s\(r(x.size)) o\(r(x.opacity)) \(x.blendMode.rawValue) g\(x.useGlobalLight)"
            case let x as StrokeEffect: t += " s\(r(x.size)) o\(r(x.opacity)) \(x.position.rawValue)"
            case let x as ColorOverlayEffect: t += " o\(r(x.opacity)) \(x.blendMode.rawValue) \(x.color.hex)"
            case let x as GradientOverlayEffect: t += " o\(r(x.opacity)) \(x.blendMode.rawValue)"
            case let x as GlowEffect: t += " s\(r(x.size)) o\(r(x.opacity)) \(x.blendMode.rawValue)"
            case let x as BevelEffect: t += " s\(r(x.size)) \(x.style.rawValue)"
            case let x as SatinEffect: t += " s\(r(x.size))"
            case let x as PatternOverlayEffect: t += " o\(r(x.opacity))"
            default: break
            }
            return t
        } + ["master \(fx.enabled)"]
    }

    /// `a` appears in `b` in order (other entries may sit in between).
    static func subsequence(_ a: [String], of b: [String]) -> Bool {
        var i = 0
        for x in b where i < a.count && a[i] == x { i += 1 }
        return i == a.count
    }

    static func render(_ st: DocumentState) -> PixelBuffer {
        RenderEngine.renderBuffer(Compositor.shared.composite(st), docRect: st.canvasRect, space: CanvasSpace(width: st.width, height: st.height))
    }

    static func maxDiff(_ a: PixelBuffer, _ b: PixelBuffer) -> Int {
        guard a.width == b.width, a.height == b.height else { return 255 }
        let pa = a.data.assumingMemoryBound(to: UInt8.self), pb = b.data.assumingMemoryBound(to: UInt8.self)
        var m = 0
        for y in 0..<a.height { for x in 0..<(a.width * 4) { m = max(m, abs(Int(pa[y * a.bytesPerRow + x]) - Int(pb[y * b.bytesPerRow + x]))) } }
        return m
    }

    static func changedPixels(_ a: PixelBuffer, _ b: PixelBuffer) -> Int {
        guard a.width == b.width, a.height == b.height else { return Int.max }
        let pa = a.data.assumingMemoryBound(to: UInt8.self), pb = b.data.assumingMemoryBound(to: UInt8.self)
        var n = 0
        for y in 0..<a.height { for x in 0..<a.width {
            let i = y * a.bytesPerRow + x * 4
            if (0..<4).contains(where: { abs(Int(pa[i + $0]) - Int(pb[i + $0])) > 3 }) { n += 1 }
        } }
        return n
    }

    static func save(_ b: PixelBuffer, _ name: String) {
        try? b.pngData()?.write(to: imgDir.appendingPathComponent(name + ".png"))
    }

    // MARK: Entry points

    enum Entry: CustomStringConvertible {
        case fxMenu(StyleSection), layerMenu(StyleSection), checkbox(StyleSection), rowClick(StyleSection), plus(StyleSection, after: Int)
        case properties(StyleSection), paste, clipboardHistory, preset
        case drag(from: UUID, EffectSlot?, copy: Bool)
        var description: String {
            switch self {
            case .fxMenu(let s): return "fx menu ▸ \(s.rawValue)"
            case .layerMenu(let s): return "Layer ▸ Layer Style ▸ \(s.rawValue)"
            case .checkbox(let s): return "dialog checkbox \(s.rawValue)"
            case .rowClick(let s): return "dialog row \(s.rawValue)"
            case .plus(let s, let i): return "dialog + \(s.rawValue) after #\(i + 1)"
            case .properties(let s): return "Properties ▸ Layer Style… ▸ \(s.rawValue)"
            case .paste: return "Paste Layer Style"
            case .clipboardHistory: return "clipboard history ▸ paste style"
            case .preset: return "dialog Style Presets ▸ Soft Drop Shadow"
            case .drag(_, let s, let c): return "\(c ? "⌥-drag" : "drag") \(s.map { $0.kind.displayName + " #\($0.index + 1)" } ?? "Effects") from Donor"
            }
        }
    }

    static func ok(_ d: Document) {
        FieldEdits.commit(); d.commit("Layer Style"); AppModel.shared.dialog = nil
    }

    /// Runs `e` on layer `id` the way the UI does it, through to OK. Returns false if the entry point was unavailable.
    @discardableResult
    static func perform(_ e: Entry, _ d: Document, _ id: UUID) -> Bool {
        d.selectLayer(id)
        switch e {
        case .fxMenu(let s):
            LayerStyleDialog.open(s, layer: id, doc: d)
            ok(d)
        case .layerMenu(let s):
            LayerStyleDialog.openFromMenu(s)
            guard case .layerStyle(let x)? = AppModel.shared.dialog, x == id else { return false }
            ok(d)
        case .checkbox(let s), .properties(let s):
            AppModel.shared.dialog = .layerStyle(id)
            let dlg = LayerStyleDialog(layerID: id)
            dlg.enabledBinding(s, 0, dlg.fxBinding()).wrappedValue = true
            ok(d)
        case .rowClick(let s):
            AppModel.shared.dialog = .layerStyle(id)
            let dlg = LayerStyleDialog(layerID: id)
            let fx = dlg.fxBinding()
            // (the row's button: selects the section and switches the effect on if it is off)
            if !dlg.enabledBinding(s, 0, fx).wrappedValue { dlg.enabledBinding(s, 0, fx).wrappedValue = true }
            ok(d)
        case .plus(let s, let i):
            AppModel.shared.dialog = .layerStyle(id)
            let dlg = LayerStyleDialog(layerID: id)
            dlg.addInstance(s, after: i, dlg.fxBinding())
            ok(d)
        case .paste:
            AppActions.pasteLayerStyle()
        case .clipboardHistory:
            guard let fx = AppActions.copiedEffects else { return false }
            let h = ClipboardHistory.shared
            let known = Set(h.items.map(\.id))
            let it = h.recordStyle(fx, name: "Source")
            defer { if !known.contains(it.id) { h.remove(it.id) } }
            guard h.paste(it.id, mode: .style, into: d) else { return false }
        case .drag(let src, let slot, let copy):
            return LayerFX.transfer(d, from: src, slot: slot, to: id, copy: copy)
        case .preset:
            AppModel.shared.dialog = .layerStyle(id)
            let dlg = LayerStyleDialog(layerID: id)
            dlg.applyPreset { $0.dropShadow = ShadowEffect(enabled: true, opacity: 0.45, distance: 8, size: 18) }
            ok(d)
        }
        return true
    }

    /// One case: `e` on layer `id` of a document opened from `st`; `adds` is the number of new listed effects expected,
    /// `kind` the effect expected to be listed and shown afterwards.
    static func scenario(_ label: String, _ st: DocumentState, _ id: UUID, _ e: Entry, adds: Int, kind: EffectKind?, pixels: Bool = true, images: Bool = false) {
        let name = "\(label) — \(e)"
        let d = makeDoc(st, label)
        defer { close(d) }
        guard let before = d.state.layer(id)?.effects else { check(false, "\(name): layer"); return }
        let r0 = render(d.state)
        let steps0 = d.history.count
        guard perform(e, d, id) else { check(false, "\(name): entry point exists"); return }
        guard let after = d.state.layer(id)?.effects else { check(false, "\(name): layer after"); return }
        let lb = listed(before), la = listed(after)
        // the imported effects are all still there, unchanged (an fx menu pick of a kind already present may show it)
        let keep = kind.map { k in lb.filter { !$0.hasPrefix(k.rawValue + ":") } } ?? lb
        check(subsequence(keep, of: la), "\(name): imported effects kept", "before \(psdSig(before))\nafter  \(psdSig(after))")
        check(la.count == lb.count + adds, "\(name): \(adds) effect(s) added", "\(lb.count) → \(la.count): \(psdSig(after))")
        if let k = kind {
            check(after.listedSlots.contains { $0.kind == k && after.isShown($0) }, "\(name): \(k.displayName) listed and shown")
        }
        check(after.enabled, "\(name): Effects shown after adding")
        check(d.history.count == steps0 + 1, "\(name): one history step", "\(steps0) → \(d.history.count)")
        let r1 = render(d.state)
        let changed = changedPixels(r0, r1)
        if pixels { check(changed > 50, "\(name): the new effect is drawn", "\(changed) px changed") }
        if images {
            let f = label.replacingOccurrences(of: " ", with: "_") + "_" + "\(e)".replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "▸", with: "").replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "/", with: "-")
            save(r0, f + "_before"); save(r1, f + "_after")
        }
        // Undo / Redo
        d.undo()
        check(d.state.layer(id)?.effects == before, "\(name): Undo restores the imported style")
        check(maxDiff(render(d.state), r0) <= 1, "\(name): Undo restores the render")
        d.redo()
        check(d.state.layer(id)?.effects == after, "\(name): Redo")
        // PSD round trip keeps old + new
        let url = workDir.appendingPathComponent("rt_\(abs(name.hashValue)).psd")
        do {
            try PSDWriter.write(d.state, to: url)
            let back = try PSDReader.read(url: url)
            let lname = d.state.layer(id)?.name
            let fx2 = back.allLayers.first { $0.name == lname }?.effects
            check(fx2.map(psdSig) == psdSig(after), "\(name): PSD round trip keeps imported + new effects",
                  "wrote \(psdSig(after))\nread  \(fx2.map(psdSig) ?? [])")
        } catch { check(false, "\(name): PSD round trip", "\(error)") }
    }

    // MARK: Codec

    static func codec() {
        let fx = importedStyle()
        for v in [Variant.plain, .photoshop, .both, .masterOff] {
            var r = PSDCursorFreeReader(lfx2(fx, v))
            guard let back = r.decode() else { check(false, "decode \(v)"); continue }
            switch v {
            case .both:
                check(back.dropShadows.filter(\.isListed).count == 1 && back.strokes.filter(\.isListed).count == 1,
                      "classic key next to a '…Multi' list of placeholders: the classic effect is read", "\(psdSig(back))")
            case .masterOff:
                check(!back.enabled && psdSig(back).dropLast() == psdSig(fx).dropLast(), "masterFXSwitch off: effects read, Effects hidden")
            default:
                check(psdSig(back) == psdSig(fx), "lfx2 \(v): every instance read, eyes and blend modes kept", "\(psdSig(fx))\n\(psdSig(back))")
            }
        }
        // long-form blend mode names on every mode Photoshop writes that way
        for m in BlendMode.allCases where m != .passThrough {
            var f = LayerEffects()
            f.dropShadow = ShadowEffect(enabled: true, blendMode: m)
            var root = PSDLayerStyle.descriptor(f)
            if let short = root.object("DrSh")?.enumValue("Md  "), let long = longNames[short] {
                root = longForm(root)
                _ = long
            } else { continue }
            let back = PSDLayerStyle.effects(from: root)
            check(back.dropShadow.blendMode == m, "long blend mode name '\(longNames[m.descriptorKey] ?? "")' read as \(m.rawValue)", "got \(back.dropShadow.blendMode.rawValue)")
        }
    }

    /// (decodes an lfx2 payload with the public entry point)
    struct PSDCursorFreeReader {
        let data: Data
        init(_ d: Data) { data = d }
        mutating func decode() -> LayerEffects? { PSDLayerStyle.decode(data) }
    }

    // MARK: Synthetic files

    static func styledID(_ st: DocumentState, _ name: String = "Styled") -> UUID? { st.allLayers.first { $0.name == name }?.id }

    static func synthetic() {
        for v in [Variant.plain, .photoshop, .both] {
            guard let st = importFile(syntheticFile(importedStyle(), v), "synthetic_\(v)"), let id = styledID(st) else { continue }
            let imported = st.layer(id)!.effects
            if v != .both { check(psdSig(imported) == psdSig(importedStyle()), "synthetic \(v): imported style as written", "\(psdSig(imported))") }
            let label = "synthetic \(v)"
            let img = v == .photoshop
            scenario(label, st, id, .fxMenu(.bevel), adds: 1, kind: .bevel, images: img)
            scenario(label, st, id, .layerMenu(.satin), adds: 1, kind: .satin, images: img)
            scenario(label, st, id, .checkbox(.innerGlow), adds: 1, kind: .innerGlow, images: img)
            scenario(label, st, id, .rowClick(.patternOverlay), adds: 1, kind: .patternOverlay)
            scenario(label, st, id, .properties(.bevel), adds: 1, kind: .bevel)
            let ds = st.layer(id)!.effects.instanceCount(.dropShadow)
            scenario(label, st, id, .plus(.dropShadow, after: ds - 1), adds: 1, kind: .dropShadow, pixels: false, images: img)
            scenario(label, st, id, .plus(.stroke, after: 0), adds: 1, kind: .stroke, pixels: false)
            scenario(label, st, id, .plus(.innerShadow, after: 0), adds: 1, kind: .innerShadow, pixels: false)
            scenario(label, st, id, .plus(.colorOverlay, after: 0), adds: 1, kind: .colorOverlay, pixels: false)
            scenario(label, st, id, .plus(.gradientOverlay, after: 1), adds: 1, kind: .gradientOverlay, pixels: false)
            // an fx menu pick of an effect the layer already has opens it: nothing is added, nothing is lost
            scenario(label, st, id, .fxMenu(.dropShadow), adds: 0, kind: .dropShadow, pixels: false)
            // the hidden second colour overlay: checking it in the dialog shows it again
            scenario(label, st, id, .fxMenu(.colorOverlay), adds: 0, kind: .colorOverlay, pixels: false)
            scenario(label, st, id, .preset, adds: 0, kind: .dropShadow, pixels: false)
            // a "+" on a new instance draws a second copy of the first one: change it and check it is drawn
            plusThenEdit(label, st, id)
        }
        // Paste Layer Style onto a styled imported layer replaces its style (Photoshop); copying it elsewhere keeps all
        guard let st = importFile(syntheticFile(importedStyle(), .photoshop), "synthetic_paste"), let id = styledID(st) else { return }
        var src = LayerEffects()
        src.bevel = BevelEffect(enabled: true, size: 8)
        AppActions.copiedEffects = src
        pasteCase(st, id, src, history: false)
        pasteCase(st, id, src, history: true)
        // copy the imported style onto a plain layer: every instance arrives, PSD keeps them
        let d = makeDoc(st, "copy imported")
        defer { close(d) }
        d.selectLayer(id); AppActions.copyLayerStyle()
        let bg = d.state.allLayers.first { $0.name == "Background" }!.id
        d.selectLayer(bg); AppActions.pasteLayerStyle()
        check(psdSig(d.state.layer(bg)!.effects) == psdSig(st.layer(id)!.effects), "Copy / Paste Layer Style of an imported multi-instance style keeps every instance")
    }

    static func pasteCase(_ st: DocumentState, _ id: UUID, _ src: LayerEffects, history: Bool) {
        let d = makeDoc(st, "paste")
        defer { close(d) }
        let before = d.state.layer(id)!.effects
        perform(history ? .clipboardHistory : .paste, d, id)
        let after = d.state.layer(id)!.effects
        let what = history ? "clipboard history paste" : "Paste Layer Style"
        check(after == src, "\(what) replaces the imported style with the copied one (as Photoshop)")
        d.undo()
        check(d.state.layer(id)!.effects == before, "\(what): Undo brings the imported style back")
    }

    static func plusThenEdit(_ label: String, _ st: DocumentState, _ id: UUID) {
        let d = makeDoc(st, label)
        defer { close(d) }
        AppModel.shared.dialog = .layerStyle(id)
        let dlg = LayerStyleDialog(layerID: id)
        let fx = dlg.fxBinding()
        let n = fx.wrappedValue.instanceCount(.dropShadow)
        dlg.addInstance(.dropShadow, after: n - 1, fx)
        let r0 = render(d.state)
        // (a SwiftUI Binding keeps the value it was made with: the dialog makes fresh ones every time it is drawn)
        let b = dlg.inst(\.dropShadow, \.extraDropShadows, n, dlg.fxBinding())
        var v = b.wrappedValue
        v.angle = -45; v.distance = 30; v.color = RGBA(hex: "00A000")!; v.opacity = 1; v.useGlobalLight = false
        b.wrappedValue = v
        let r1 = render(d.state)
        ok(d)
        let after = d.state.layer(id)!.effects
        check(after.extraDropShadows.count == n && after.extraDropShadows[n - 1].distance == 30 && after.extraDropShadows.dropLast().allSatisfy { $0.distance != 30 },
              "\(label): + then edit changes the new drop shadow only", "\(after.dropShadows.map(\.distance))")
        check(changedPixels(r0, r1) > 50, "\(label): the edited new drop shadow is drawn")
        save(r1, "\(label.replacingOccurrences(of: " ", with: "_"))_plus_dropshadow_edited")
    }

    // MARK: Effects hidden (masterFXSwitch off)

    static func hiddenMaster() {
        guard let st = importFile(syntheticFile(importedStyle(), .masterOff), "synthetic_masteroff"), let id = styledID(st) else { return }
        check(!st.layer(id)!.effects.enabled && st.layer(id)!.effects.hasStyle, "masterFXSwitch off imports as Effects hidden, effects listed")
        let label = "effects hidden"
        scenario(label, st, id, .fxMenu(.bevel), adds: 1, kind: .bevel, images: true)
        scenario(label, st, id, .layerMenu(.satin), adds: 1, kind: .satin)
        scenario(label, st, id, .checkbox(.innerGlow), adds: 1, kind: .innerGlow, images: true)
        scenario(label, st, id, .rowClick(.patternOverlay), adds: 1, kind: .patternOverlay)
        scenario(label, st, id, .properties(.bevel), adds: 1, kind: .bevel)
        scenario(label, st, id, .plus(.dropShadow, after: 1), adds: 1, kind: .dropShadow)
        scenario(label, st, id, .preset, adds: 0, kind: .dropShadow)
        // the dialog's own "Layer effects enabled" switch and the panel's Effects eye still work
        let d = makeDoc(st, label)
        defer { close(d) }
        LayerFX.toggleMaster(d, id)
        check(d.state.layer(id)!.effects.enabled, "effects hidden: the Effects eye shows them")
    }

    // MARK: Per-effect eyes

    static func eyes() {
        guard let st = importFile(syntheticFile(importedStyle(), .photoshop), "synthetic_eyes"), let id = styledID(st) else { return }
        let d = makeDoc(st, "eyes")
        defer { close(d) }
        LayerStyleDialog.open(.bevel, layer: id, doc: d); ok(d)
        let slots = d.state.layer(id)!.effects.listedSlots
        // hide every imported effect with its eye, one by one; the new bevel stays drawn
        for s in slots where s.kind != .bevel { LayerFX.setShown(d, id, s, false) }
        var fx = d.state.layer(id)!.effects
        check(fx.listedSlots.filter { fx.isShown($0) }.map(\.kind) == [.bevel], "eyes: imported effects hidden one by one, the new Bevel stays", "\(psdSig(fx))")
        check(fx.listedSlots.count == slots.count, "eyes: hidden effects stay listed")
        // the eye of the second drop shadow (index 1) hides that one, not the first
        LayerFX.setShown(d, id, EffectSlot(kind: .dropShadow, index: 1), true)
        fx = d.state.layer(id)!.effects
        check(!fx.dropShadow.enabled && fx.extraDropShadows[0].enabled, "eyes: the second drop shadow's eye shows the second one")
        // round trip keeps the hidden ones as hidden
        let url = workDir.appendingPathComponent("eyes.psd")
        if (try? PSDWriter.write(d.state, to: url)) != nil, let back = try? PSDReader.read(url: url), let fx2 = back.allLayers.first(where: { $0.name == "Styled" })?.effects {
            check(psdSig(fx2) == psdSig(fx), "eyes: PSD keeps shown / hidden per effect", "\(psdSig(fx))\n\(psdSig(fx2))")
        } else { check(false, "eyes: PSD round trip") }
        for _ in 0..<(slots.count) { d.undo() }
        check(d.state.layer(id)!.effects.listedSlots.allSatisfy { s in d.state.layer(id)!.effects.isShown(s) || (s.kind == .colorOverlay && s.index == 1) },
              "eyes: Undo brings every eye back")
    }

    // MARK: Dialog ↔ imported instances

    static func dialogInstances() {
        guard let st = importFile(syntheticFile(importedStyle(), .photoshop), "synthetic_instances"), let id = styledID(st) else { return }
        let d = makeDoc(st, "instances")
        defer { close(d) }
        let fx0 = d.state.layer(id)!.effects
        // double-clicking each effect row opens that very instance; editing it changes that instance only
        for s in fx0.listedSlots where StyleSection(rawValue: s.kind.displayName)?.allowsMultiple == true {
            LayerFX.openStyle(s, layer: id, doc: d)
            let opened = LayerStyleDialog.openingSection?.section.rawValue == s.kind.displayName && LayerStyleDialog.openingInstance == s.index
            check(opened, "double-click on \(s.kind.displayName) #\(s.index + 1) opens that instance")
            let dlg = LayerStyleDialog(layerID: id)
            let fx = dlg.fxBinding()
            switch s.kind {
            case .dropShadow: dlg.inst(\.dropShadow, \.extraDropShadows, s.index, fx).wrappedValue.opacity = 0.11
            case .innerShadow: dlg.inst(\.innerShadow, \.extraInnerShadows, s.index, fx).wrappedValue.opacity = 0.11
            case .stroke: dlg.inst(\.stroke, \.extraStrokes, s.index, fx).wrappedValue.opacity = 0.11
            case .colorOverlay: dlg.inst(\.colorOverlay, \.extraColorOverlays, s.index, fx).wrappedValue.opacity = 0.11
            case .gradientOverlay: dlg.inst(\.gradientOverlay, \.extraGradientOverlays, s.index, fx).wrappedValue.opacity = 0.11
            default: break
            }
            let now = d.state.layer(id)!.effects
            let changed = now.allSlots.filter { x in
                guard let a = fx0.item(x), let b = now.item(x) else { return true }
                return itemJSON(a) != itemJSON(b)
            }
            check(changed == [s], "dialog edit of \(s.kind.displayName) #\(s.index + 1) changes that instance only", "\(changed)")
            d.revertUncommitted()
            AppModel.shared.dialog = nil
        }
        // the dialog's checkbox of instance #2 matches its eye in the Layers panel
        let dlg = LayerStyleDialog(layerID: id)
        let fx = dlg.fxBinding()
        check(dlg.enabledBinding(.colorOverlay, 1, fx).wrappedValue == false && dlg.enabledBinding(.colorOverlay, 0, fx).wrappedValue == true,
              "dialog checkboxes match the imported eyes per instance")
        // "-" on an imported instance removes that one
        dlg.removeInstance(.dropShadow, 1, fx)
        let after = d.state.layer(id)!.effects
        check(after.dropShadows.count == 1 && after.dropShadow == fx0.dropShadow, "dialog − removes the second imported drop shadow only")
        d.revertUncommitted()
    }

    // MARK: Global Light

    static func globalLight() {
        var fx = LayerEffects()
        fx.dropShadow = ShadowEffect(enabled: true, angle: 30, distance: 12, size: 4, useGlobalLight: true)
        guard let st = importFile(syntheticFile(fx, .photoshop, light: 30), "synthetic_light"), let id = styledID(st) else { return }
        check(st.globalLight.angle == 30, "Global Light angle read from the file", "\(st.globalLight.angle)")
        let d = makeDoc(st, "light")
        defer { close(d) }
        // a new Inner Shadow (Use Global Light) follows the file's light, like the imported Drop Shadow
        LayerStyleDialog.open(.innerShadow, layer: id, doc: d); ok(d)
        let l = d.state.layer(id)!.effects
        check(l.innerShadow.useGlobalLight, "new Inner Shadow uses Global Light")
        check(abs(l.innerShadow.angle - 30) < 0.01, "new Inner Shadow's own angle starts at the document's Global Light", "\(l.innerShadow.angle)")
        // switching Use Global Light off keeps the direction it had
        let dlg = LayerStyleDialog(layerID: id)
        let b = dlg.inst(\.innerShadow, \.extraInnerShadows, 0, dlg.fxBinding())
        // the imported style's own angle differs: switching Use Global Light off on a fresh copy of it must not jump
        dlg.globalLightToggle(b, angle: \.angle, use: \.useGlobalLight).wrappedValue = false
        let s = d.state.layer(id)!.effects.innerShadow
        check(!s.useGlobalLight && abs(s.angle - 30) < 0.01, "unchecking Use Global Light keeps the shadow's direction", "\(s.angle)")
        d.revertUncommitted()
        // "+" on the imported drop shadow: the copy follows the same light
        AppModel.shared.dialog = .layerStyle(id)
        let dlg2 = LayerStyleDialog(layerID: id)
        dlg2.addInstance(.dropShadow, after: 0, dlg2.fxBinding()); ok(d)
        let e = d.state.layer(id)!.effects
        check(e.extraDropShadows.first?.useGlobalLight == true, "+ copy of the imported drop shadow keeps Use Global Light")
        // the PSD writes the angle Photoshop draws for Use Global Light effects
        let data = PSDLayerStyle.encode(e, globalLight: d.state.globalLight)
        let root = try? PSDLayerStyle.rootDescriptor(data)
        let angles = (root?.list("dropShadowMulti") ?? []).compactMap { $0.objectValue?.double("lagl") }
        check(angles == [30, 30], "PSD: Use Global Light shadows are written with the Global Light angle", "\(angles)")
        // a file without Global Light resource: the light comes from the imported effects
        var f2 = syntheticFile(fx, .photoshop, light: 30)
        f2.resources.removeAll { $0.0 == 1037 }
        if let st2 = importFile(f2, "synthetic_nolight") {
            check(st2.globalLight.angle == 30, "no Global Light resource: taken from the effects that use it", "\(st2.globalLight.angle)")
        }
    }

    // MARK: Layer kinds

    static func layerKinds() {
        // group with a style, read from a PSD
        if let st = importFile(syntheticFile(importedStyle(), .photoshop, group: true), "synthetic_group"), let id = styledID(st, "Styled Group") {
            check(st.layer(id)?.isGroup == true && st.layer(id)!.effects.listedSlots.count == importedStyle().listedSlots.count, "group: imported style")
            scenario("group", st, id, .fxMenu(.bevel), adds: 1, kind: .bevel, images: true)
            scenario("group", st, id, .checkbox(.innerGlow), adds: 1, kind: .innerGlow)
            scenario("group", st, id, .plus(.stroke, after: 1), adds: 1, kind: .stroke, pixels: false)
        }
        // smart object, type and shape layers holding an imported style
        let style = PSDLayerStyle.decode(lfx2(importedStyle(), .photoshop)) ?? importedStyle()
        var so = Layer(name: "Styled", content: .smartObject(SmartObjectContent(source: .image(boxBuffer()), quad: Quad(rect: CGRect(x: 0, y: 0, width: W, height: H)))))
        so.effects = style
        var t = TextContent(); t.text = "Ab"; t.fontSize = 90; t.position = CGPoint(x: 40, y: 50); t.color = RGBA(hex: "4C7BD9")!
        var tx = Layer(name: "Styled", content: .text(t)); tx.effects = style
        var sh = Layer(name: "Styled", content: .shape(ShapeContent(geometry: .ellipse(box), fill: .color(RGBA(hex: "4C7BD9")!)))); sh.effects = style
        for (k, l) in [("smart object", so), ("type", tx), ("shape", sh)] {
            var st = DocumentState(width: W, height: H)
            st.layers = [Layer.raster(name: "Background", buffer: white()), l]
            scenario(k, st, l.id, .fxMenu(.bevel), adds: 1, kind: .bevel, images: true)
            scenario(k, st, l.id, .checkbox(.satin), adds: 1, kind: .satin)
            scenario(k, st, l.id, .plus(.dropShadow, after: 0), adds: 1, kind: .dropShadow, pixels: false)
        }
    }

    // MARK: Menus

    static func menus() {
        let titles = StyleSection.allCases.map(\.menuTitle)
        check(titles.first == "Blending Options…" && titles.count == 11 && Set(titles).count == 11, "Layer ▸ Layer Style: Blending Options… and every effect", "\(titles)")
        guard let st = importFile(syntheticFile(importedStyle(), .photoshop), "synthetic_menu"), let id = styledID(st) else { return }
        let d = makeDoc(st, "menu")
        defer { close(d) }
        d.selectLayer(id)
        LayerStyleDialog.openFromMenu(.blending)
        var open = false
        if case .layerStyle(let x)? = AppModel.shared.dialog, x == id { open = true }
        check(open && d.state.layer(id)!.effects == st.layer(id)!.effects, "Layer ▸ Layer Style ▸ Blending Options… opens the dialog, style untouched")
        AppModel.shared.dialog = nil
        // a dialog that was open is replaced: its uncommitted edits go, the new effect stays
        d.updateLayer(id) { $0.opacity = 0.3 }
        AppModel.shared.dialog = .globalLight
        LayerStyleDialog.openFromMenu(.satin)
        let l = d.state.layer(id)!
        check(l.opacity == st.layer(id)!.opacity && l.effects.satin.enabled, "fx pick while another dialog is open: that dialog is cancelled, the new effect kept")
        d.revertUncommitted()
    }

    // MARK: Drag effects between layers

    static func drags() {
        guard let st0 = importFile(syntheticFile(importedStyle(), .photoshop), "synthetic_drag"), let id = styledID(st0) else { return }
        var st = st0
        var donor = Layer.raster(name: "Donor", buffer: boxBuffer(RGBA(hex: "C04040")!))
        donor.effects.bevel = BevelEffect(enabled: true, size: 10)
        donor.effects.dropShadow = ShadowEffect(enabled: true, color: RGBA(hex: "0000C0")!, opacity: 1, angle: -90, distance: 25, size: 0, useGlobalLight: false)
        donor.isVisible = false
        st.layers.insert(donor, at: 1)
        let label = "drag"
        scenario(label, st, id, .drag(from: donor.id, EffectSlot(kind: .bevel), copy: false), adds: 1, kind: .bevel, images: true)
        scenario(label, st, id, .drag(from: donor.id, EffectSlot(kind: .dropShadow), copy: true), adds: 1, kind: .dropShadow, images: true)
        // moving takes it off the donor; copying leaves it
        let d = makeDoc(st, "drag move")
        defer { close(d) }
        LayerFX.transfer(d, from: donor.id, slot: EffectSlot(kind: .bevel), to: id, copy: false)
        check(!d.state.layer(donor.id)!.effects.bevel.isListed && d.state.layer(donor.id)!.effects.dropShadow.enabled, "drag moves the effect off the donor, its other effects stay")
        d.undo()
        check(d.state.layer(donor.id)!.effects == donor.effects && d.state.layer(id)!.effects == st.layer(id)!.effects, "drag: one Undo puts both layers back")
        // the second imported drop shadow dragged onto the donor: that instance goes, the first one stays
        let fx0 = d.state.layer(id)!.effects
        LayerFX.transfer(d, from: id, slot: EffectSlot(kind: .dropShadow, index: 1), to: donor.id, copy: false)
        let a = d.state.layer(id)!.effects, b = d.state.layer(donor.id)!.effects
        check(a.dropShadows.count == 1 && a.dropShadow == fx0.dropShadow && b.extraDropShadows.last == fx0.extraDropShadows[0],
              "drag of an imported second drop shadow moves that instance only")
        // the Effects row: whole style, replaces (like Paste Layer Style); payload round trip
        check(LayerFX.parseDrag(LayerFX.dragString(id, nil))?.slot == nil && LayerFX.parseDrag(LayerFX.dragString(id, EffectSlot(kind: .stroke, index: 1)))?.slot == EffectSlot(kind: .stroke, index: 1),
              "effect drag payload round trip")
        check(LayerFX.parseDrag(id.uuidString) == nil, "a layer drag is not an effect drag")
    }

    // MARK: Real files

    static func samples(_ dir: URL) {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".psd") || $0.hasSuffix(".psb") }.sorted()
        check(!files.isEmpty, "sample folder has files", dir.path)
        for f in files {
            guard let st = try? PSDReader.read(url: dir.appendingPathComponent(f)) else { check(false, "\(f): opens"); continue }
            let styled = st.allLayers.filter { $0.effects.hasStyle }
            for l in styled {
                let label = "\(f.replacingOccurrences(of: ".psd", with: "").replacingOccurrences(of: ".psb", with: "")) \(l.name)"
                let img = f.hasPrefix("ps_resave_08")
                let fx = l.effects
                let missing = StyleSection.allCases.filter { s in s != .blending && !fx.listedSlots.contains { $0.kind.displayName == s.rawValue } }
                if let m = missing.first(where: { [.bevel, .innerGlow, .satin, .colorOverlay].contains($0) }) {
                    scenario(label, st, l.id, .fxMenu(m), adds: 1, kind: EffectKind.allCases.first { $0.displayName == m.rawValue }, images: img)
                }
                if let m = missing.last(where: { [.innerShadow, .outerGlow, .gradientOverlay, .stroke].contains($0) }) {
                    scenario(label, st, l.id, .checkbox(m), adds: 1, kind: EffectKind.allCases.first { $0.displayName == m.rawValue }, images: img)
                    scenario(label, st, l.id, .layerMenu(m), adds: 1, kind: EffectKind.allCases.first { $0.displayName == m.rawValue })
                }
                for s in fx.listedSlots where StyleSection(rawValue: s.kind.displayName)?.allowsMultiple == true && s.index == 0 {
                    scenario(label, st, l.id, .plus(StyleSection(rawValue: s.kind.displayName)!, after: 0), adds: 1, kind: s.kind, pixels: false, images: img && s.kind == .dropShadow)
                }
            }
            // a re-export of the untouched file keeps every style as it was read
            let url = workDir.appendingPathComponent("rt_" + f)
            if (try? PSDWriter.write(st, to: url, large: f.hasSuffix(".psb"))) != nil, let back = try? PSDReader.read(url: url) {
                let a = styled.map { psdSig($0.effects) }, b = back.allLayers.filter { $0.effects.hasStyle }.map { psdSig($0.effects) }
                check(a == b, "\(f): re-export keeps every layer style", "\(a)\n\(b)")
            } else if !styled.isEmpty { check(false, "\(f): re-export") }
        }
    }
}
