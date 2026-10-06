import AppKit
import SwiftUI
import CoreImage
import ImageCratCore

/// Layer ▸ Name Layers Automatically: descriptive names from what each layer actually is.
/// Text → its text; shapes → "Blue Rounded Rectangle"; adjustments / fills → kind + key value; pixel layers and smart
/// objects → a 2–4 word description of their own pixels (Florence-2 caption, else Vision label + colour) plus
/// position; groups → a summary of their children.
enum AssistNaming {
    // MARK: Default-name detection

    private static let defaultBases: [String] = {
        var b = ["Layer", "Group", "Shape", "Rectangle", "Rounded Rectangle", "Ellipse", "Polygon", "Line", "Path", "Custom Shape", "Text", "Type",
                 "Smart Object", "Embedded", "Frame", "Color Fill", "Gradient Fill", "Pattern Fill", "Solid Color", "Gradient", "Pattern", "Fill",
                 "Content-Aware Fill", "Star", "Triangle", "Pasted Layer", "Stamp", "Merged"]
        b += AdjustmentKind.allCases.map(\.displayName)
        return b
    }()

    /// True for names the app generated ("Layer 3", "Rectangle 1 copy", "Text", "Levels 2").
    static func isDefaultName(_ name: String) -> Bool {
        var n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return true }
        if n == "Background" { return false }     // the Background layer keeps its special name
        while let r = n.range(of: #"\s+copy(\s+\d+)?$"#, options: [.regularExpression, .caseInsensitive]) { n.removeSubrange(r) }
        if let r = n.range(of: #"\s+\d+$"#, options: .regularExpression) { n.removeSubrange(r) }
        return defaultBases.contains { $0.caseInsensitiveCompare(n) == .orderedSame }
    }

    // MARK: Deterministic names (no ML)

    static func signed(_ v: Double, _ fmt: String = "%.0f") -> String { (v > 0 ? "+" : (v < 0 ? "−" : "")) + String(format: fmt, abs(v)) }

    static func shapeKind(_ s: ShapeContent) -> String {
        func square(_ r: CGRect) -> Bool { abs(r.width - r.height) <= max(1, 0.03 * max(r.width, r.height)) }
        switch s.geometry {
        case .rectangle(let r, let radius):
            if radius >= Double(min(r.width, r.height)) / 2 - 0.5, radius > 0 { return square(r) ? "Circle" : "Pill" }
            if radius > 0 { return square(r) ? "Rounded Square" : "Rounded Rectangle" }
            return square(r) ? "Square" : "Rectangle"
        case .ellipse(let r): return square(r) ? "Circle" : "Ellipse"
        case .polygon(_, let sides, let star):
            if star < 0.999 { return "\(sides)-Point Star" }
            switch sides {
            case 3: return "Triangle"
            case 4: return "Diamond"
            case 5: return "Pentagon"
            case 6: return "Hexagon"
            case 8: return "Octagon"
            default: return "\(sides)-Sided Polygon"
            }
        case .line: return "Line"
        case .path: return "Shape"
        case .library: return s.geometry.kindName
        }
    }

    static func paintWord(_ p: PaintStyle) -> String? {
        switch p {
        case .none: return nil
        case .color(let c): return AssistColor.name(c)
        case .gradient(let g):
            let st = g.gradient.sortedStops
            if let a = st.first, let b = st.last { return "\(AssistColor.name(a.color))–\(AssistColor.name(b.color)) Gradient" }
            return "Gradient"
        case .pattern: return "Patterned"
        }
    }

    static func shapeName(_ s: ShapeContent) -> String {
        let kind = shapeKind(s)
        if let f = paintWord(s.fill) { return "\(f) \(kind)" }
        if let st = paintWord(s.stroke.paint) { return "\(st) \(kind) Outline" }
        return kind
    }

    static func textName(_ t: TextContent) -> String {
        var s = t.text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Empty Text" : Assist.truncate(s, 32)
    }

    static func fillName(_ f: FillContent) -> String {
        switch f.paint {
        case .color(let c): return "\(AssistColor.name(c)) Fill"
        case .gradient(let g):
            let st = g.gradient.sortedStops
            if let a = st.first, let b = st.last { return "Gradient Fill: \(AssistColor.name(a.color)) → \(AssistColor.name(b.color))" }
            return "Gradient Fill"
        case .pattern(let id, _): return "Pattern Fill: \(id.capitalized)"
        case .none: return "Empty Fill"
        }
    }

    static func adjustmentName(_ a: AdjustmentSettings) -> String {
        let base = a.kind.displayName
        func join(_ parts: [String]) -> String { parts.isEmpty ? base : parts.prefix(2).joined(separator: ", ") }
        func p(_ k: String) -> Double { EditsAdjustments.value(a, k) }
        switch a.kind {
        case .brightnessContrast:
            var parts: [String] = []
            if a.brightness != 0 { parts.append("Brightness \(signed(a.brightness))") }
            if a.contrast != 0 { parts.append("Contrast \(signed(a.contrast))") }
            return join(parts)
        case .levels:
            let m = a.levels[0]
            if m.inBlack != 0 || m.inWhite != 255 || m.gamma != 1 {
                var s = "Levels \(Int(m.inBlack))–\(Int(m.inWhite))"
                if m.gamma != 1 { s += String(format: " γ%.2f", m.gamma) }
                return s
            }
            return a.levels.dropFirst().contains { !$0.isIdentity } ? "Levels (per channel)" : base
        case .curves:
            if a.curves[0].isIdentity { return a.curves.dropFirst().contains { !$0.isIdentity } ? "Curves (colour)" : base }
            let lut = a.curves[0].lut(256)
            let mid = lut[128] - 0.5, lo = lut[64] - 0.25, hi = lut[192] - 0.75
            if lo < -0.02 && hi > 0.02 { return "Curves: Contrast" }
            if lo > 0.02 && hi < -0.02 { return "Curves: Flatten" }
            if mid > 0.02 { return "Curves: Brighten" }
            if mid < -0.02 { return "Curves: Darken" }
            return base
        case .exposure: return a.exposure != 0 ? "Exposure \(signed(a.exposure, "%.2f"))" : base
        case .vibrance:
            var parts: [String] = []
            if a.vibrance != 0 { parts.append("Vibrance \(signed(a.vibrance))") }
            if a.saturation != 0 { parts.append("Saturation \(signed(a.saturation))") }
            return join(parts)
        case .hueSaturation:
            if a.colorize { return "Colorize \(AssistColor.name(RGBA(h: ((a.hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)) / 360, s: 0.8, v: 0.9)))" }
            var parts: [String] = []
            if a.hue != 0 { parts.append("Hue \(signed(a.hue))°") }
            if a.hsSaturation != 0 { parts.append("Saturation \(signed(a.hsSaturation))") }
            if a.lightness != 0 { parts.append("Lightness \(signed(a.lightness))") }
            return join(parts)
        case .colorBalance:
            let m = a.midtones
            if m.cyanRed > 0 && m.yellowBlue < 0 { return "Color Balance: Warmer" }
            if m.cyanRed < 0 && m.yellowBlue > 0 { return "Color Balance: Cooler" }
            return base
        case .photoFilter: return "Photo Filter: \(AssistColor.name(a.filterColor)) \(Int(a.density))%"
        case .posterize: return "Posterize \(Int(a.posterizeLevels)) Levels"
        case .threshold: return "Threshold \(Int(a.thresholdLevel))"
        case .gradientMap:
            let st = a.gradient.sortedStops
            if let f = st.first, let l = st.last { return "Gradient Map: \(AssistColor.name(f.color)) → \(AssistColor.name(l.color))" }
            return base
        case .colorLookup: return "Look: \(a.lookName)"
        case .blackWhite: return a.bwTint ? "Black & White (tinted)" : base
        case .colorWB:
            var parts: [String] = []
            if p("temperature") != 0 { parts.append(p("temperature") > 0 ? "Warmer \(signed(p("temperature")))" : "Cooler \(signed(p("temperature")))") }
            if p("tint") != 0 { parts.append("Tint \(signed(p("tint")))") }
            if p("vibrance") != 0 { parts.append("Vibrance \(signed(p("vibrance")))") }
            if p("saturation") != 0 { parts.append("Saturation \(signed(p("saturation")))") }
            return parts.isEmpty ? base : "Color: " + parts.prefix(2).joined(separator: ", ")
        case .light:
            var parts: [String] = []
            if p("exposure") != 0 { parts.append("Exposure \(signed(p("exposure"), "%.2f"))") }
            for k in ["contrast", "highlights", "shadows", "whites", "blacks"] where p(k) != 0 { parts.append("\(k.capitalized) \(signed(p(k)))") }
            return parts.isEmpty ? base : "Light: " + parts.prefix(2).joined(separator: ", ")
        case .clarity, .dehaze: return p("amount") != 0 ? "\(base) \(signed(p("amount")))" : base
        case .grain: return "Grain \(Int(p("amount")))"
        default: return base
        }
    }

    /// Name that needs no image analysis, or nil (pixel layers, smart objects, groups).
    static func quickName(_ l: Layer) -> String? {
        var n: String
        switch l.content {
        case .text(let t): n = textName(t)
        case .shape(let s): n = shapeName(s)
        case .fill(let f): n = fillName(f)
        case .adjustment(let a): n = adjustmentName(a)
        default: return nil
        }
        if l.isAdjustment || l.isFill, let m = l.mask, m.outsideValue == 0 { n += " (masked)" }
        return n
    }

    // MARK: Pixel descriptions

    struct PixelInput {
        var image: CGImage          // layer over white
        var alphaImage: CGImage     // layer with transparency
        var bounds: CGRect          // doc space
        var canvas: CGSize
        var isBottom: Bool
    }

    struct PixelResult {
        var name: String
        var caption: String?
        var source: String          // "florence", "vision", "colour", "ocr"
    }

    /// Describes a layer's pixels in a few words. Call off the main thread.
    static func describe(_ i: PixelInput, useFlorence: Bool = true) -> PixelResult {
        let st = AssistColor.stats(i.alphaImage)
        let coverCanvas = (i.bounds.width * i.bounds.height) / max(1, i.canvas.width * i.canvas.height) > 0.9 && st.coverage > 0.9
        let pos = Assist.position(of: i.bounds, in: i.canvas)
        func withPos(_ s: String) -> String { pos.map { "\(s) — \($0)" } ?? s }

        // flat colour / smooth gradient
        if st.detail < 1.2, st.coverage > 0.85 {
            if st.spread < 7 {
                let c = AssistColor.name(st.mean)
                return PixelResult(name: coverCanvas ? "\(c) \(i.isBottom ? "Background" : "Fill")" : withPos("\(c) Block"), caption: nil, source: "colour")
            }
            let sw = AssistColor.dominant(i.alphaImage, max: 2)
            if sw.count >= 2, sw[0].name != sw[1].name {
                let n = "\(sw[0].name)–\(sw[1].name) Gradient"
                return PixelResult(name: coverCanvas ? n + (i.isBottom ? " Background" : "") : withPos(n), caption: nil, source: "colour")
            }
        }
        // mostly text (rasterised type, logos, screenshots of a label)
        let lines = AssistVision.ocr(i.image, fast: true).filter { l in l.confidence >= 0.5 && l.text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count >= 3 }
        let area = CGFloat(i.image.width * i.image.height)
        let textArea = lines.reduce(CGFloat(0)) { $0 + $1.box.width * $1.box.height }
        if textArea / area > 0.22 {
            let t = lines.prefix(2).map(\.text).joined(separator: " ")
            return PixelResult(name: withPos("“\(Assist.truncate(t, 24))” Text Image"), caption: nil, source: "ocr")
        }
        // Florence-2 caption → head noun phrase
        if useFlorence, AssistCaptioner.shared.isAvailable, let cap = try? AssistCaptioner.shared.generate(i.image, task: .caption) {
            let clean = AssistText.cleanCaption(cap)
            if let head = AssistText.namePhrase(clean) {
                var n = head
                if coverCanvas, i.isBottom, !n.lowercased().contains("background") { n += " Photo" }
                return PixelResult(name: coverCanvas ? n : withPos(n), caption: clean, source: "florence")
            }
        }
        // Vision classification + dominant colour
        let labels = AssistVision.classify(i.image)
        let colour = AssistColor.dominant(i.alphaImage, max: 1).first?.name
        let best = (labels.first?.confidence ?? 0) >= 0.3 ? AssistVision.bestLabels(labels, max: coverCanvas ? 2 : 1) : []
        if !best.isEmpty {
            let label = Assist.titleCase(best.joined(separator: " and "))
            let n = (colour != nil && !coverCanvas) ? "\(colour!) \(label)" : label
            return PixelResult(name: coverCanvas ? n + (i.isBottom ? " Photo" : "") : withPos(n), caption: nil, source: "vision")
        }
        let n = "\(colour ?? "Mixed") \(st.coverage < 0.6 ? "Cutout" : "Image")"
        return PixelResult(name: withPos(n), caption: nil, source: "colour")
    }

    // MARK: Groups

    static func groupName(_ g: Layer, childNames: [UUID: String]) -> String {
        let kids = g.children.reversed()      // top first
        if kids.isEmpty { return g.isArtboard ? "Empty Artboard" : "Empty Group" }
        let names = kids.map { childNames[$0.id] ?? $0.name }
        let kinds = Set(kids.map { $0.kindName })
        if kids.count >= 3, kinds.count == 1, let k = kinds.first {
            let plural: String
            switch k {
            case "Pixel Layer": plural = "Images"
            case "Type Layer": plural = "Text Layers"
            case "Shape Layer": plural = "Shapes"
            case "Smart Object": plural = "Smart Objects"
            default: plural = k + "s"
            }
            return "\(kids.count) \(plural)"
        }
        // lead with text (it usually says what the group is), then the rest in stacking order
        var ordered: [String] = []
        for (k, n) in zip(kids, names) where k.isText { ordered.append(n) }
        for (k, n) in zip(kids, names) where !k.isText && !k.isAdjustment { ordered.append(n) }
        for (k, n) in zip(kids, names) where k.isAdjustment { ordered.append(n) }
        let short = ordered.map { n -> String in
            let base = n.components(separatedBy: " — ").first ?? n
            return Assist.truncate(base, 18)
        }
        var s = short.prefix(2).joined(separator: " + ")
        if short.count > 2 { s += " +\(short.count - 2)" }
        return g.isArtboard ? "Artboard: \(s)" : s
    }

    // MARK: Whole-document naming

    struct Result {
        var names: [UUID: String] = [:]
        var captions: [UUID: String] = [:]
        var sources: [UUID: String] = [:]
    }

    /// Layers the command acts on: several selected layers → those (and their children); otherwise every
    /// default-named layer of the document.
    static func targets(_ d: Document, forceSelection: Bool = false) -> [UUID] {
        let sel = d.orderedSelection
        if forceSelection || sel.count > 1 {
            var ids: [UUID] = []
            for id in sel { if let l = d.state.layer(id) { ids += l.allIDs.filter { i in i == id || isDefaultName(d.state.layer(i)?.name ?? "") } } }
            return ids
        }
        return d.state.allLayers.filter { isDefaultName($0.name) }.map(\.id)
    }

    /// Computes names for `ids`. Rendering happens on the main thread, analysis off it.
    static func computeNames(state: DocumentState, ids: [UUID], useFlorence: Bool = true, progress: ((Int, Int) -> Void)? = nil) async -> Result {
        var res = Result()
        let idSet = Set(ids)
        let all = state.allLayers
        let bottomID = state.layers.first?.id
        // 1. deterministic kinds + pixel inputs (main thread)
        let inputs: [(UUID, PixelInput)] = await Assist.onMain {
            var out: [(UUID, PixelInput)] = []
            for l in all where idSet.contains(l.id) && (l.isRaster || l.isSmartObject) {
                guard let (img, b) = Assist.layerImage(l, state: state, maxSide: 768, background: .white),
                      let (alpha, _) = Assist.layerImage(l, state: state, maxSide: 256, background: nil) else { continue }
                out.append((l.id, PixelInput(image: img, alphaImage: alpha, bounds: b, canvas: CGSize(width: state.width, height: state.height), isBottom: l.id == bottomID)))
            }
            return out
        }
        for l in all where idSet.contains(l.id) {
            if let q = quickName(l) { res.names[l.id] = q; res.sources[l.id] = "rule" }
            if (l.isRaster || l.isSmartObject), !inputs.contains(where: { $0.0 == l.id }) { res.names[l.id] = "Empty Layer"; res.sources[l.id] = "rule" }
        }
        // 2. pixel layers (ML)
        for (n, (id, input)) in inputs.enumerated() {
            let r = describe(input, useFlorence: useFlorence)
            res.names[id] = r.name
            res.sources[id] = r.source
            if let c = r.caption { res.captions[id] = c }
            progress?(n + 1, inputs.count)
        }
        // 3. groups, innermost first
        func nameGroups(_ layers: [Layer]) {
            for l in layers where l.isGroup {
                nameGroups(l.children)
                if idSet.contains(l.id) { res.names[l.id] = groupName(l, childNames: res.names); res.sources[l.id] = "group" }
            }
        }
        nameGroups(state.layers)
        // 4. unique names (siblings that look alike get a counter)
        var used: [String: Int] = [:]
        for l in all where !idSet.contains(l.id) { used[l.name, default: 0] += 1 }
        for l in all.reversed() where idSet.contains(l.id) {
            guard let n = res.names[l.id] else { continue }
            let c = used[n, default: 0]
            used[n] = c + 1
            if c > 0 { res.names[l.id] = "\(n) \(c + 1)" }
        }
        return res
    }

    /// Applies names as one undo step. Returns how many layers changed.
    @discardableResult
    static func apply(_ d: Document, _ r: Result) -> Int {
        var changed = 0
        for (id, n) in r.names where d.state.layer(id)?.name != n && !n.isEmpty {
            d.updateLayer(id) { $0.name = n }
            changed += 1
        }
        if changed > 0 { d.commit(changed == 1 ? "Name Layer Automatically" : "Name \(changed) Layers Automatically") }
        for (id, n) in r.names { AssistNameCache.shared.store(id, n) }
        return changed
    }

    static func autoNameAction(selectionOnly: Bool = false) {
        guard let d = AppActions.doc else { return }
        let ids = targets(d, forceSelection: selectionOnly)
        guard !ids.isEmpty else {
            AppModel.shared.setStatus("Name Layers Automatically: no default-named layers (select layers to rename them anyway).")
            Beep.play()
            return
        }
        let st = d.state
        Assist.run("Naming \(ids.count) layer\(ids.count == 1 ? "" : "s")…", { await computeNames(state: st, ids: ids) }) { r in
            let n = apply(d, r)
            AppModel.shared.setStatus(n == 0 ? "Layer names are already descriptive." : "Named \(n) layer\(n == 1 ? "" : "s") automatically (⌘Z to undo).")
        }
    }

    // MARK: {auto} token for Layer ▸ Rename Layers…

    /// The automatic name of `l` for the batch-rename `{auto}` token. Deterministic kinds resolve at once; pixel
    /// layers return a cached description (call `prepare` to compute it) or the current name until it is ready.
    static func token(for l: Layer) -> String {
        _ = AssistState.shared.revision     // dialog previews refresh when names arrive
        if let c = AssistNameCache.shared.name(l.id) { return c }
        if let q = quickName(l) { return q }
        return l.name
    }

    /// Computes the automatic names of the selected layers in the background and publishes them to `token(for:)`.
    static func prepare() {
        guard let d = AppActions.doc else { return }
        let ids = d.orderedSelection.flatMap { d.state.layer($0)?.allIDs ?? [] }
        guard !ids.isEmpty else { return }
        let st = d.state
        Assist.run("Describing \(ids.count) layer\(ids.count == 1 ? "" : "s")…", { await computeNames(state: st, ids: ids) }) { r in
            for (id, n) in r.names { AssistNameCache.shared.store(id, n) }
            AssistState.shared.revision += 1
            AppModel.shared.setStatus("Automatic names ready.")
        }
    }
}

/// Automatic names computed for the `{auto}` rename token (per layer id, for this session).
final class AssistNameCache {
    static let shared = AssistNameCache()
    private var names: [UUID: String] = [:]
    private let lock = NSLock()
    func name(_ id: UUID) -> String? { lock.lock(); defer { lock.unlock() }; return names[id] }
    func store(_ id: UUID, _ n: String) { lock.lock(); names[id] = n; lock.unlock() }
    func clear() { lock.lock(); names.removeAll(); lock.unlock() }
}

/// Layers-panel context menu entries (one line in `LayerRow.contextMenu`).
struct AssistLayerContextMenu: View {
    let doc: Document
    let layerID: UUID

    var body: some View {
        let many = doc.orderedSelection.count > 1 && doc.selectedLayerIDs.contains(layerID)
        Button(tr(many ? "Name \(doc.orderedSelection.count) Layers Automatically" : "Name Automatically")) {
            if !many { doc.selectLayer(layerID) }
            AssistNaming.autoNameAction(selectionOnly: true)
        }
        Button("Select Similar Looking Layers") {
            if !many { doc.selectLayer(layerID) }
            AssistSearch.selectSimilarAction()
        }
        if let l = doc.state.layer(layerID), l.isRaster || l.isSmartObject {
            Button(tr(many ? "Remove Backgrounds" : "Remove Background (mask)")) {
                if !many { doc.selectLayer(layerID) }
                AssistSubject.removeBackgroundsAction()
            }
        }
        Divider()
    }
}
