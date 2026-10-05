import Foundation

/// Photoshop brush preset descriptors (`8BIMdesc` of .abr / .tpl files) ↔ `BrushParams`.
///
/// A preset (class `brushPreset`) holds its name (`Nm  `), the tip (`Brsh`: class `computedBrush` or `sampledBrush`
/// with `Dmtr`, `Hrdn`, `Angl`, `Rndn`, `Spcn`, `Intr`, `flipX`, `flipY`, `sampledData`) and the Brush Settings panel:
/// Shape Dynamics (`useTipDynamics`, `szVr`, `minimumDiameter`, `tiltScale`, `angleDynamics`, `roundnessDynamics`,
/// `minimumRoundness`, `flipX`/`flipY` jitter, `brushProjection`), Scattering (`useScatter`, `scatterDynamics`,
/// `bothAxes`, `Cnt `, `countDynamics`), Texture (`useTexture`, `Txtr`, `textureScale`, `textureBrightness`,
/// `textureContrast`, `InvT`, `TxtC`, `textureBlendMode`, `textureDepth`, `minimumDepth`, `textureDepthDynamics`,
/// `protectTexture`), Dual Brush (`dualBrush`), Color Dynamics (`useColorDynamics`, `clVr`, `H   `, `Strt`, `Brgh`,
/// `purity`, `colorDynamicsPerTip`), Transfer (`usePaintDynamics`, `opVr`, `prVr`), Brush Pose (`useBrushPose`,
/// `brushPose…`, `overridePose…`), Noise (`Nose`), Wet Edges (`Wtdg`), Build-up (`Rpt `) and Smoothing (`Smoo`).
/// Dynamics are `brVr` objects: `bVTy` (control), `fStp` (fade steps), `jitter`, `Mnm ` (minimum).
/// Tool presets and presets saved with "Include Tool Settings" add `Opct`, `flow`, `Md  `, `Clr ` and smoothing.
/// Values are read leniently (`UntF` percent / pixels / angle, `doub` or `long`); unknown keys are ignored.
enum ABRPresetMapping {
    struct Found {
        var name: String
        var folder: [String]
        var sampleKey: String?
        var dualSampleKey: String?
        var params: BrushParams
        var color: RGBA?
        var hasToolSettings: Bool
    }

    // MARK: Finding presets

    /// Brush presets of an .abr descriptor, with group folders: objects in the `Brsh` list that have no tip but their own
    /// list of presets are groups.
    static func findPresets(_ root: PSDDescriptor) -> [Found] {
        var out: [Found] = []
        var budget = 100_000
        func walkList(_ items: [PSDDescriptorValue], folder: [String], depth: Int) {
            guard depth < 24 else { return }
            for item in items {
                budget -= 1
                if budget < 0 { return }
                guard let o = item.objectValue else { continue }
                if isPreset(o) {
                    out.append(preset(o, folder: folder, toolContext: nil))
                } else if let (name, kids) = group(o) {
                    walkList(kids, folder: folder + [name.isEmpty ? "Group" : name], depth: depth + 1)
                }
            }
        }
        if let list = root.list("Brsh") {
            walkList(list, folder: [], depth: 0)
        } else {
            // Unknown root layout: take every preset found anywhere.
            out = findToolPresets(root)
        }
        return out
    }

    /// Every brush preset anywhere in a (tool preset) descriptor tree; the name and tool settings come from the nearest
    /// enclosing object that has a name.
    static func findToolPresets(_ root: PSDDescriptor) -> [Found] {
        var out: [Found] = []
        var budget = 200_000
        func walk(_ o: PSDDescriptor, ancestors: [PSDDescriptor], depth: Int) {
            budget -= 1
            guard depth < 32, budget > 0 else { return }
            if isPreset(o) {
                let ctx = ancestors.last { $0.string("Nm  ") != nil }
                var f = preset(o, folder: [], toolContext: ctx)
                if let n = ctx?.string("Nm  "), !n.isEmpty, o.string("Nm  ")?.isEmpty ?? true { f.name = clean(n) }
                else if let n = ctx?.string("Nm  "), !n.isEmpty { f.name = clean(n) }
                out.append(f)
                return
            }
            for e in o.entries {
                switch e.value {
                case .object(let d), .globalObject(let d): walk(d, ancestors: ancestors + [o], depth: depth + 1)
                case .list(let l):
                    for v in l { if let d = v.objectValue { walk(d, ancestors: ancestors + [o], depth: depth + 1) } }
                default: break
                }
            }
        }
        walk(root, ancestors: [], depth: 0)
        return out
    }

    /// Folder paths from a `phry` hierarchy, one per preset in order (empty when the layout isn't recognised).
    static func hierarchyPaths(_ h: PSDDescriptor) -> [[String]] {
        var out: [[String]] = []
        var budget = 100_000
        func walk(_ items: [PSDDescriptorValue], _ folder: [String], _ depth: Int) {
            guard depth < 24 else { return }
            for v in items {
                budget -= 1
                if budget < 0 { return }
                guard let o = v.objectValue else { continue }
                if let kids = o.entries.lazy.compactMap({ $0.value.listValue }).first(where: { $0.contains { $0.objectValue != nil } }) {
                    walk(kids, folder + [clean(o.string("Nm  ") ?? o.string("name") ?? "Group")], depth + 1)
                } else {
                    out.append(folder)
                }
            }
        }
        if let list = h.list("hierarchy") ?? h.entries.lazy.compactMap({ $0.value.listValue }).first {
            walk(list, [], 0)
        }
        return out
    }

    static func isPreset(_ o: PSDDescriptor) -> Bool {
        guard let t = o.object("Brsh") else { return false }
        return isTip(t)
    }

    static func isTip(_ t: PSDDescriptor) -> Bool {
        t.classID == "computedBrush" || t.classID == "sampledBrush" || t["Dmtr"] != nil || t["sampledData"] != nil
    }

    static func group(_ o: PSDDescriptor) -> (String, [PSDDescriptorValue])? {
        for e in o.entries {
            if let l = e.value.listValue, l.contains(where: { $0.objectValue.map { isPreset($0) || group($0) != nil } ?? false }) {
                return (clean(o.string("Nm  ") ?? o.string("name") ?? ""), l)
            }
        }
        return nil
    }

    static func clean(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines)) }

    // MARK: Descriptor → params

    private static func pct(_ o: PSDDescriptor, _ k: String) -> Double? {
        guard let v = o[k] else { return nil }
        switch v {
        case .unitFloat(let u, let d): return u == "#Prc" ? d / 100 : (d > 1 ? d / 100 : d)
        case .double(let d): return d > 1 ? d / 100 : d
        case .integer(let i): return Double(i) / 100
        default: return nil
        }
    }

    private static func num(_ o: PSDDescriptor, _ k: String) -> Double? {
        o[k]?.doubleValue.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func dyn(_ o: PSDDescriptor?, _ key: String) -> (control: BrushControlParam, jitter: Double, minimum: Double)? {
        guard let v = o?.object(key) else { return nil }
        let c = BrushControlParam(source: BrushControlSource(photoshopCode: Int(num(v, "bVTy") ?? 0)), fadeSteps: num(v, "fStp") ?? 25)
        return (c, pct(v, "jitter") ?? 0, pct(v, "Mnm ") ?? 0)
    }

    static func preset(_ o: PSDDescriptor, folder: [String], toolContext ctx: PSDDescriptor?) -> Found {
        var p = BrushParams()
        p.pressureSize = false      // Photoshop presets drive size by Shape Dynamics, not the options bar toggle
        var f = Found(name: clean(o.string("Nm  ") ?? ""), folder: folder, sampleKey: nil, dualSampleKey: nil, params: p, color: nil, hasToolSettings: false)
        let tip = o.object("Brsh") ?? PSDDescriptor(classID: "computedBrush")
        if let d = num(tip, "Dmtr"), d > 0 { p.size = d }
        if let h = pct(tip, "Hrdn") { p.hardness = h } else { p.hardness = 1 }
        if let a = num(tip, "Angl") { p.angle = a }
        if let r = pct(tip, "Rndn") { p.roundness = max(0.01, r) }
        if let s = pct(tip, "Spcn") { p.spacing = s > 0 ? s : 0.25 }
        if tip.bool("Intr") == false { p.spacing = max(p.spacing, 0.25) }    // spacing switched off: speed based in Photoshop
        p.flipX = tip.bool("flipX") ?? false
        p.flipY = tip.bool("flipY") ?? false
        if let key = tip.string("sampledData") { f.sampleKey = ABRSections.normalizedKey(key) }
        if f.name.isEmpty, let n = tip.string("Nm  ") { f.name = clean(n) }

        // Shape Dynamics
        p.shapeEnabled = o.bool("useTipDynamics") ?? false
        if let s = dyn(o, "szVr") { p.sizeControl = s.control; p.sizeJitter = s.jitter }
        if let v = pct(o, "minimumDiameter") { p.minDiameter = v }
        if let v = pct(o, "tiltScale") { p.tiltScale = v }
        if let s = dyn(o, "angleDynamics") { p.angleControl = s.control; p.angleJitter = s.jitter }
        if let s = dyn(o, "roundnessDynamics") { p.roundnessControl = s.control; p.roundnessJitter = s.jitter }
        if let v = pct(o, "minimumRoundness") { p.minRoundness = max(0.01, v) }
        p.flipXJitter = o.bool("flipX") ?? false
        p.flipYJitter = o.bool("flipY") ?? false
        p.brushProjection = o.bool("brushProjection") ?? false

        // Scattering
        p.scatterEnabled = o.bool("useScatter") ?? false
        if let s = dyn(o, "scatterDynamics") { p.scatterControl = s.control; p.scatter = s.jitter }
        p.scatterBothAxes = o.bool("bothAxes") ?? false
        if let c = num(o, "Cnt ") { p.count = max(1, min(16, c)) }
        if let s = dyn(o, "countDynamics") { p.countControl = s.control; p.countJitter = s.jitter }

        // Texture
        p.textureEnabled = o.bool("useTexture") ?? false
        if let t = o.object("Txtr") {
            p.texturePatternID = clean(t.string("Idnt") ?? "")
            p.texturePatternName = clean(t.string("Nm  ") ?? "")
        }
        if let v = pct(o, "textureScale") { p.textureScale = max(0.01, v) }
        if let v = num(o, "textureBrightness") { p.textureBrightness = v }
        if let v = num(o, "textureContrast") { p.textureContrast = v }
        p.textureInvert = o.bool("InvT") ?? false
        p.textureEachTip = o.bool("TxtC") ?? true
        if let m = o.enumValue("textureBlendMode").flatMap(BrushMaskBlend.init(photoshopKey:)) { p.textureMode = m }
        if let v = pct(o, "textureDepth") { p.textureDepth = v }
        if let v = pct(o, "minimumDepth") { p.textureMinDepth = v }
        if let s = dyn(o, "textureDepthDynamics") { p.textureDepthControl = s.control; p.textureDepthJitter = s.jitter }
        p.protectTexture = o.bool("protectTexture") ?? false

        // Dual Brush
        if let db = o.object("dualBrush") {
            p.dualEnabled = db.bool("useDualBrush") ?? false
            p.dualFlip = db.bool("Flip") ?? false
            if let m = db.enumValue("BlnM").flatMap(BrushMaskBlend.init(photoshopKey:)) { p.dualMode = m }
            if let dt = db.object("Brsh") {
                if let d = num(dt, "Dmtr"), d > 0 { p.dualSize = d }
                if let h = pct(dt, "Hrdn") { p.dualHardness = h } else { p.dualHardness = 1 }
                if let s = pct(dt, "Spcn") { p.dualSpacing = s > 0 ? s : 0.25 }
                if let key = dt.string("sampledData") { f.dualSampleKey = ABRSections.normalizedKey(key) } else { p.dualTipID = "round" }
            }
            if let s = pct(db, "Spcn") { p.dualSpacing = s > 0 ? s : p.dualSpacing }
            if let s = dyn(db, "scatterDynamics") { p.dualScatter = s.jitter }
            p.dualBothAxes = db.bool("bothAxes") ?? false
            if let c = num(db, "Cnt ") { p.dualCount = max(1, min(16, c)) }
        }

        // Color Dynamics
        p.colorEnabled = o.bool("useColorDynamics") ?? false
        if let s = dyn(o, "clVr") { p.fgBgControl = s.control; p.fgBgJitter = s.jitter }
        if let v = pct(o, "H   ") { p.hueJitter = v }
        if let v = pct(o, "Strt") { p.saturationJitter = v }
        if let v = pct(o, "Brgh") { p.brightnessJitter = v }
        if let v = pct(o, "purity") { p.purity = v }
        p.colorPerTip = o.bool("colorDynamicsPerTip") ?? true

        // Transfer
        p.transferEnabled = o.bool("usePaintDynamics") ?? false
        if let s = dyn(o, "opVr") { p.opacityControl = s.control; p.opacityJitter = s.jitter; p.minOpacity = s.minimum }
        if let s = dyn(o, "prVr") { p.flowControl = s.control; p.flowJitter = s.jitter; p.minFlow = s.minimum }

        // Brush Pose
        p.poseEnabled = o.bool("useBrushPose") ?? false
        if let v = num(o, "brushPoseTiltX") { p.poseTiltX = v / 100 }
        if let v = num(o, "brushPoseTiltY") { p.poseTiltY = v / 100 }
        if let v = num(o, "brushPoseAngle") { p.poseRotation = v }
        if let v = pct(o, "brushPosePressure") { p.posePressure = v }
        p.poseOverrideTilt = (o.bool("overridePoseTiltX") ?? false) || (o.bool("overridePoseTiltY") ?? false)
        p.poseOverrideRotation = o.bool("overridePoseAngle") ?? false
        p.poseOverridePressure = o.bool("overridePosePressure") ?? false

        // Other options
        p.noise = o.bool("Nose") ?? false
        p.wetEdges = o.bool("Wtdg") ?? false
        p.airbrush = o.bool("Rpt ") ?? false
        if let sm = o.bool("Smoo") ?? o.bool("smoothing") { p.smoothing = sm ? 0.1 : 0 }

        // Tool settings (presets saved with "Include Tool Settings", tool presets)
        let tool = o.object("toolOptions") ?? ctx
        if let t = tool {
            var any = false
            if let v = pct(t, "Opct") { p.opacity = max(0, min(1, v)); any = true }
            if let v = pct(t, "flow") ?? pct(t, "Flw ") { p.flow = max(0.01, min(1, v)); any = true }
            if let m = t.enumValue("Md  ").flatMap(BlendMode.init(descriptorKey:)) { p.blendMode = m.rawValue; any = true }
            if let v = num(t, "smoothingValue") { p.smoothing = max(0, min(0.95, v / 100)); any = true }
            if t.bool("Rpt ") == true { p.airbrush = true }
            if let c = PSDLayerStyle.parseColor(t.object("Clr ")) { f.color = c }
            f.hasToolSettings = any
        }
        f.params = p
        return f
    }

    // MARK: Params → descriptor (writer)

    private typealias V = PSDDescriptorValue
    private static func uPct(_ v: Double) -> V { .unitFloat(unit: "#Prc", value: v * 100) }
    private static func uPx(_ v: Double) -> V { .unitFloat(unit: "#Pxl", value: v) }
    private static func uAng(_ v: Double) -> V { .unitFloat(unit: "#Ang", value: v) }

    private static func brVr(_ c: BrushControlParam, jitter: Double, minimum: Double = 0) -> V {
        .object(PSDDescriptor(classID: "brVr", [
            ("bVTy", .integer(Int32(c.source.photoshopCode))),
            ("fStp", .integer(Int32(max(1, min(9999, c.fadeSteps.rounded()))))),
            ("jitter", uPct(jitter)),
            ("Mnm ", uPct(minimum)),
        ]))
    }

    private static func tipDescriptor(sampleKey: String?, size: Double, hardness: Double, angle: Double, roundness: Double,
                                      spacing: Double, flipX: Bool, flipY: Bool, name: String) -> PSDDescriptor {
        var items: [(String, V)] = [
            ("Dmtr", uPx(size)),
        ]
        if sampleKey == nil { items.append(("Hrdn", uPct(hardness))) }
        items += [
            ("Angl", uAng(angle)),
            ("Rndn", uPct(roundness)),
            ("Spcn", uPct(spacing)),
            ("Intr", .bool(true)),
            ("flipX", .bool(flipX)),
            ("flipY", .bool(flipY)),
        ]
        if let k = sampleKey {
            items.insert(("Nm  ", .string(name)), at: 0)
            items.append(("sampledData", .string("$" + k)))
        }
        return PSDDescriptor(classID: sampleKey == nil ? "computedBrush" : "sampledBrush", items)
    }

    /// A `brushPreset` descriptor. `sampleKey` / `dualSampleKey`: sample UUIDs (nil = computed round tip);
    /// `patternID`: the texture pattern's id in the file's `patt` section.
    static func descriptor(name: String, params p: BrushParams, sampleKey: String?, dualSampleKey: String?, patternID: String?,
                           color: RGBA?, includeToolSettings: Bool) -> PSDDescriptor {
        var items: [(String, V)] = [
            ("Nm  ", .string(name)),
            ("Brsh", .object(tipDescriptor(sampleKey: sampleKey, size: p.size, hardness: p.hardness, angle: p.angle, roundness: p.roundness,
                                           spacing: p.spacing, flipX: p.flipX, flipY: p.flipY, name: name))),
            ("useTipDynamics", .bool(p.shapeEnabled)),
            ("flipX", .bool(p.flipXJitter)),
            ("flipY", .bool(p.flipYJitter)),
            ("brushProjection", .bool(p.brushProjection)),
            ("minimumDiameter", uPct(p.minDiameter)),
            ("minimumRoundness", uPct(p.minRoundness)),
            ("tiltScale", uPct(p.tiltScale)),
            ("szVr", brVr(p.sizeControl, jitter: p.sizeJitter)),
            ("angleDynamics", brVr(p.angleControl, jitter: p.angleJitter)),
            ("roundnessDynamics", brVr(p.roundnessControl, jitter: p.roundnessJitter)),
            ("useScatter", .bool(p.scatterEnabled)),
            ("Spcn", uPct(p.spacing)),
            ("Cnt ", .double(p.count)),
            ("bothAxes", .bool(p.scatterBothAxes)),
            ("countDynamics", brVr(p.countControl, jitter: p.countJitter)),
            ("scatterDynamics", brVr(p.scatterControl, jitter: p.scatter)),
            ("dualBrush", .object(PSDDescriptor(classID: "dualBrush", [
                ("useDualBrush", .bool(p.dualEnabled)),
                ("Flip", .bool(p.dualFlip)),
                ("Brsh", .object(tipDescriptor(sampleKey: p.dualTipID == "round" ? nil : dualSampleKey, size: p.dualSize, hardness: p.dualHardness,
                                               angle: 0, roundness: 1, spacing: p.dualSpacing, flipX: false, flipY: false, name: "Dual"))),
                ("BlnM", .enumerated(type: "BlnM", value: p.dualMode.photoshopKey)),
                ("useScatter", .bool(p.dualScatter > 0)),
                ("Spcn", uPct(p.dualSpacing)),
                ("Cnt ", .double(p.dualCount)),
                ("bothAxes", .bool(p.dualBothAxes)),
                ("countDynamics", brVr(BrushControlParam(), jitter: 0)),
                ("scatterDynamics", brVr(BrushControlParam(), jitter: p.dualScatter)),
            ]))),
            ("brushGroup", .object(PSDDescriptor(classID: "brushGroup", [("useBrushGroup", .bool(false))]))),
            ("useTexture", .bool(p.textureEnabled && patternID != nil)),
            ("TxtC", .bool(p.textureEachTip)),
            ("interpretation", .bool(false)),
            ("textureBlendMode", .enumerated(type: "BlnM", value: p.textureMode.photoshopKey)),
            ("textureDepth", uPct(p.textureDepth)),
            ("minimumDepth", uPct(p.textureMinDepth)),
            ("textureDepthDynamics", brVr(p.textureDepthControl, jitter: p.textureDepthJitter)),
            ("textureScale", uPct(p.textureScale)),
            ("InvT", .bool(p.textureInvert)),
            ("protectTexture", .bool(p.protectTexture)),
            ("textureBrightness", .integer(Int32(max(-150, min(150, p.textureBrightness.rounded()))))),
            ("textureContrast", .integer(Int32(max(-50, min(100, p.textureContrast.rounded()))))),
            ("usePaintDynamics", .bool(p.transferEnabled)),
            ("prVr", brVr(p.flowControl, jitter: p.flowJitter, minimum: p.minFlow)),
            ("opVr", brVr(p.opacityControl, jitter: p.opacityJitter, minimum: p.minOpacity)),
            ("useColorDynamics", .bool(p.colorEnabled)),
            ("clVr", brVr(p.fgBgControl, jitter: p.fgBgJitter)),
            ("H   ", uPct(p.hueJitter)),
            ("Strt", uPct(p.saturationJitter)),
            ("Brgh", uPct(p.brightnessJitter)),
            ("purity", uPct(p.purity)),
            ("colorDynamicsPerTip", .bool(p.colorPerTip)),
            ("Wtdg", .bool(p.wetEdges)),
            ("Nose", .bool(p.noise)),
            ("Rpt ", .bool(p.airbrush)),
            ("Smoo", .bool(p.smoothing > 0)),
            ("useBrushPose", .bool(p.poseEnabled)),
            ("overridePoseAngle", .bool(p.poseOverrideRotation)),
            ("overridePoseTiltX", .bool(p.poseOverrideTilt)),
            ("overridePoseTiltY", .bool(p.poseOverrideTilt)),
            ("overridePosePressure", .bool(p.poseOverridePressure)),
            ("brushPosePressure", uPct(p.posePressure)),
            ("brushPoseTiltX", .integer(Int32((p.poseTiltX * 100).rounded()))),
            ("brushPoseTiltY", .integer(Int32((p.poseTiltY * 100).rounded()))),
            ("brushPoseAngle", .integer(Int32(p.poseRotation.rounded()))),
        ]
        if let pid = patternID {
            items.append(("Txtr", .object(PSDDescriptor(classID: "Ptrn", [("Nm  ", .string(p.texturePatternName.isEmpty ? "Pattern" : p.texturePatternName)),
                                                                           ("Idnt", .string(pid))]))))
        }
        if includeToolSettings || color != nil {
            var t: [(String, V)] = []
            if includeToolSettings {
                t += [("Opct", uPct(p.opacity)), ("flow", uPct(p.flow)),
                      ("Md  ", .enumerated(type: "BlnM", value: (BlendMode(rawValue: p.blendMode) ?? .normal).descriptorKey)),
                      ("smoothingValue", .integer(Int32((p.smoothing * 100).rounded())))]
            }
            if let c = color {
                t.append(("Clr ", .object(PSDDescriptor(classID: "RGBC", [("Rd  ", .double(c.r * 255)), ("Grn ", .double(c.g * 255)), ("Bl  ", .double(c.b * 255))]))))
            }
            items.append(("toolOptions", .object(PSDDescriptor(classID: "currentToolOptions", t))))
        }
        return PSDDescriptor(classID: "brushPreset", items)
    }
}
