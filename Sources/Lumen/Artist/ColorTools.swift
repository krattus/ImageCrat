import AppKit
import CoreImage
import ImageCratCore

// Colour tools logic: global (linked) colours, palette sources, recolour mapping and the text contrast checker.

// MARK: - Global colours
//
// Design: links are *re-applied on change* rather than resolved while rendering. A global colour lives in the
// document (`artist.globals`) together with a link table (`artist.links`: layer + colour slot → global). Editing a
// global writes its colour into every linked property and records ONE history step, so every other part of the app
// (compositor, exporters, PSD writer, panels) keeps seeing plain colours, and undo restores colours and table together.
// A link whose property was changed by hand no longer matches its global and is dropped the next time links are
// validated (the property was deliberately detached).

enum GlobalColors {
    // MARK: Slots

    /// Colour held by a slot; effect slots only count while the effect is enabled unless `evenIfDisabled`.
    static func color(_ l: Layer, _ slot: ColorSlot, evenIfDisabled: Bool = false) -> RGBA? {
        let fx = l.effects
        func on(_ enabled: Bool, _ c: RGBA?) -> RGBA? { (enabled && fx.enabled) || evenIfDisabled ? c : nil }
        switch slot {
        case .shapeFill: return l.shape?.fill.solidColor
        case .shapeStroke: return l.shape?.stroke.paint.solidColor
        case .textColor: return l.text?.color
        case .fillLayer: return l.fill?.paint.solidColor
        case .colorOverlay: return on(fx.colorOverlay.enabled, fx.colorOverlay.color)
        case .dropShadow: return on(fx.dropShadow.enabled, fx.dropShadow.color)
        case .innerShadow: return on(fx.innerShadow.enabled, fx.innerShadow.color)
        case .outerGlow: return on(fx.outerGlow.enabled, fx.outerGlow.color)
        case .innerGlow: return on(fx.innerGlow.enabled, fx.innerGlow.color)
        case .satin: return on(fx.satin.enabled, fx.satin.color)
        case .strokeEffect: return on(fx.stroke.enabled, fx.stroke.paint.solidColor)
        }
    }

    /// Writes a colour into a slot. The alpha of the existing colour is kept (opacity stays a property of the usage).
    static func set(_ l: inout Layer, _ slot: ColorSlot, _ c: RGBA) {
        func keepAlpha(_ old: RGBA?) -> RGBA { c.withAlpha(old?.a ?? 1) }
        switch slot {
        case .shapeFill: if var s = l.shape { s.fill = .color(keepAlpha(s.fill.solidColor)); l.shape = s }
        case .shapeStroke: if var s = l.shape { s.stroke.paint = .color(keepAlpha(s.stroke.paint.solidColor)); l.shape = s }
        case .textColor:
            if var t = l.text {
                let old = t.color
                t.color = keepAlpha(old)
                // runs that merely repeated the layer colour follow it
                for i in t.runs.indices where t.runs[i].style.color == old { t.runs[i].style.color = t.color }
                l.text = t
            }
        case .fillLayer: if let f = l.fill { l.fill = FillContent(paint: .color(keepAlpha(f.paint.solidColor))) }
        case .colorOverlay: l.effects.colorOverlay.color = keepAlpha(l.effects.colorOverlay.color)
        case .dropShadow: l.effects.dropShadow.color = keepAlpha(l.effects.dropShadow.color)
        case .innerShadow: l.effects.innerShadow.color = keepAlpha(l.effects.innerShadow.color)
        case .outerGlow: l.effects.outerGlow.color = keepAlpha(l.effects.outerGlow.color)
        case .innerGlow: l.effects.innerGlow.color = keepAlpha(l.effects.innerGlow.color)
        case .satin: l.effects.satin.color = keepAlpha(l.effects.satin.color)
        case .strokeEffect: l.effects.stroke.paint = .color(keepAlpha(l.effects.stroke.paint.solidColor))
        }
    }

    /// Slots of a layer that currently hold a solid colour.
    static func slots(_ l: Layer) -> [ColorSlot] { ColorSlot.allCases.filter { color(l, $0) != nil } }

    private static func same(_ a: RGBA, _ b: RGBA) -> Bool { a.r8 == b.r8 && a.g8 == b.g8 && a.b8 == b.b8 }

    // MARK: Table maintenance

    /// Drops links to missing layers / globals and links whose property no longer shows the global's colour.
    static func validate(_ st: inout DocumentState) {
        guard !st.artist.links.isEmpty else { return }
        let globals = Dictionary(st.artist.globals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        st.artist.links = st.artist.links.filter { link in
            guard let g = globals[link.globalID], let l = st.layer(link.layerID), let c = color(l, link.slot, evenIfDisabled: true) else { return false }
            return same(c, g.color)
        }
    }

    static func usageCount(_ st: DocumentState, _ id: UUID) -> Int {
        var s = st
        validate(&s)
        return s.artist.links.filter { $0.globalID == id }.count
    }

    static func link(_ st: DocumentState, layer: UUID, slot: ColorSlot) -> GlobalColor? {
        var s = st
        validate(&s)
        guard let l = s.artist.links.first(where: { $0.layerID == layer && $0.slot == slot }) else { return nil }
        return s.artist.globals.first { $0.id == l.globalID }
    }

    // MARK: Actions

    @discardableResult
    static func add(_ d: Document, color: RGBA, name: String? = nil) -> UUID {
        var n = name ?? "Global \(d.state.artist.globals.count + 1)"
        var i = 2
        let base = n
        while d.state.artist.globals.contains(where: { $0.name == n }) { n = "\(base) \(i)"; i += 1 }
        let g = GlobalColor(name: n, color: color.withAlpha(1))
        d.state.artist.globals.append(g)
        d.commit("New Global Colour")
        return g.id
    }

    static func rename(_ d: Document, _ id: UUID, _ name: String) {
        guard let i = d.state.artist.globals.firstIndex(where: { $0.id == id }), !name.isEmpty, d.state.artist.globals[i].name != name else { return }
        d.state.artist.globals[i].name = name
        d.commit("Rename Global Colour")
    }

    static func delete(_ d: Document, _ id: UUID) {
        d.state.artist.globals.removeAll { $0.id == id }
        d.state.artist.links.removeAll { $0.globalID == id }
        d.commit("Delete Global Colour")
    }

    /// Links a colour slot of a layer to a global colour and applies the colour.
    static func assign(_ d: Document, layer: UUID, slot: ColorSlot, global: UUID, commit: Bool = true) {
        guard let g = d.state.artist.globals.first(where: { $0.id == global }), var l = d.state.layer(layer) else { return }
        switch slot {     // effects are switched on when a colour is assigned to them
        case .colorOverlay: l.effects.colorOverlay.enabled = true
        case .dropShadow: l.effects.dropShadow.enabled = true
        case .innerShadow: l.effects.innerShadow.enabled = true
        case .outerGlow: l.effects.outerGlow.enabled = true
        case .innerGlow: l.effects.innerGlow.enabled = true
        case .satin: l.effects.satin.enabled = true
        case .strokeEffect: l.effects.stroke.enabled = true
        default: break
        }
        if slot.isEffect { l.effects.enabled = true }
        set(&l, slot, g.color)
        guard color(l, slot) != nil else { return }      // the layer has no such property
        d.state.updateLayer(layer) { $0 = l }
        d.state.artist.links.removeAll { $0.layerID == layer && $0.slot == slot }
        d.state.artist.links.append(ColorLink(layerID: layer, slot: slot, globalID: global))
        if commit { d.commit("Assign Global Colour") }
    }

    static func unlink(_ d: Document, layer: UUID, slot: ColorSlot) {
        let n = d.state.artist.links.count
        d.state.artist.links.removeAll { $0.layerID == layer && $0.slot == slot }
        if d.state.artist.links.count != n { d.commit("Unlink Global Colour") }
    }

    /// Changes a global colour and every usage. `commit: false` previews live (call again with `commit: true`, or
    /// `Document.revertUncommitted()`); the committed change is a single undo step.
    static func setColor(_ d: Document, _ id: UUID, _ c: RGBA, commit: Bool = true) {
        var st = d.state
        validate(&st)
        guard let gi = st.artist.globals.firstIndex(where: { $0.id == id }) else { return }
        st.artist.globals[gi].color = c.withAlpha(1)
        for link in st.artist.links where link.globalID == id {
            st.updateLayer(link.layerID) { set(&$0, link.slot, c) }
        }
        d.state = st
        if commit { d.commit("Edit Global Colour") }
    }
}

// MARK: - Palette sources

enum PaletteSource: String, CaseIterable, Identifiable {
    case document, selection, layer
    var id: String { rawValue }
    var title: String {
        switch self { case .document: return "Document"; case .selection: return "Selection"; case .layer: return "Active Layer" }
    }
}

enum PaletteTools {
    /// Pixels a palette is extracted from, reduced to at most `maxSide` on the longest side.
    static func buffer(_ st: DocumentState, source: PaletteSource, activeLayer: UUID?, maxSide: Int = 256) -> (PixelBuffer, PixelBuffer?)? {
        let sp = CanvasSpace(width: st.width, height: st.height)
        var img: CIImage
        switch source {
        case .document, .selection: img = Compositor.shared.composite(st)
        case .layer:
            guard let l = st.layer(activeLayer) else { return nil }
            img = Compositor.shared.layerAppearance(l, state: st)
        }
        img = img.cropped(to: sp.ciCanvas)
        let k = min(1, CGFloat(maxSide) / CGFloat(max(st.width, st.height)))
        let w = max(1, Int((CGFloat(st.width) * k).rounded())), h = max(1, Int((CGFloat(st.height) * k).rounded()))
        let small = CanvasSpace(width: w, height: h)
        let scaled = img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / CGFloat(st.width), y: CGFloat(h) / CGFloat(st.height)))
        let buf = RenderEngine.renderBuffer(scaled, docRect: IRect(x: 0, y: 0, width: w, height: h), space: small)
        var mask: PixelBuffer?
        if source == .selection, let sel = st.selection {
            let m = sel.ciImage.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / CGFloat(st.width), y: CGFloat(h) / CGFloat(st.height)))
            mask = RenderEngine.renderBuffer(m, docRect: IRect(x: 0, y: 0, width: w, height: h), space: small, format: .gray)
        }
        return (buf, mask)
    }

    static func palette(_ st: DocumentState, source: PaletteSource, activeLayer: UUID?, count: Int) -> [PaletteEntry] {
        guard let (buf, mask) = buffer(st, source: source, activeLayer: activeLayer) else { return [] }
        return PaletteExtractor.palette(buf, mask: mask, count: count)
    }

    static func addToSwatches(_ colors: [RGBA]) {
        let app = AppModel.shared
        for c in colors where !app.swatches.contains(c) { app.swatches.append(c) }
        app.setStatus("Added \(colors.count) colours to Swatches")
    }

    /// Adds a Gradient Map adjustment layer whose gradient runs through the palette (dark → light).
    @discardableResult
    static func applyGradientMap(_ d: Document, colors: [RGBA]) -> UUID? {
        guard colors.count >= 2 else { return nil }
        var s = AdjustmentSettings(kind: .gradientMap)
        s.gradient = PaletteExtractor.gradient(colors, name: "Palette Map")
        var l = Layer(name: d.nextLayerName("Palette Gradient Map"), content: .adjustment(s))
        if let sel = d.state.selection {
            l.mask = LayerMask(buffer: sel.copy(), origin: .zero, outsideValue: 0)
        }
        d.addLayer(l, commitName: "Palette Gradient Map")
        return l.id
    }
}

// MARK: - Recolour

/// A palette → palette mapping. For arbitrary colours the shift of each source colour is blended with inverse-distance
/// weights in Oklab, so source colours map exactly onto their targets and everything between moves smoothly.
struct RecolorMap: Equatable {
    var from: [RGBA]
    var to: [RGBA]
    var preserveLuminance = false

    static let lookPrefix = "Recolor|"
    static let reach = 0.35

    var isIdentity: Bool { zip(from, to).allSatisfy { $0.r8 == $1.r8 && $0.g8 == $1.g8 && $0.b8 == $1.b8 } }

    func map(_ c: RGBA) -> RGBA {
        let n = min(from.count, to.count)
        guard n > 0 else { return c }
        let x = Oklab(c)
        // identity anchor: colours far from every source colour (beyond ~`reach` in Oklab) are left alone
        var wsum = 1 / pow(RecolorMap.reach, 4), dl = 0.0, da = 0.0, db = 0.0
        for i in 0..<n {
            let f = Oklab(from[i]), t = Oklab(to[i])
            let d = x.distance(f)
            if d < 1e-5 {
                var o = t
                if preserveLuminance { o.L = x.L }
                return o.rgba.withAlpha(c.a)
            }
            let w = 1 / (d * d * d * d)
            wsum += w; dl += w * (t.L - f.L); da += w * (t.a - f.a); db += w * (t.b - f.b)
        }
        var o = Oklab(L: x.L + dl / wsum, a: x.a + da / wsum, b: x.b + db / wsum)
        if preserveLuminance { o.L = x.L }
        return o.rgba.withAlpha(c.a)
    }

    // Colour Lookup encoding: the mapping travels in the adjustment's look name, so it is saved with the layer,
    // cached by the adjustment engine like any other look and needs no extra document data.
    var lookName: String {
        RecolorMap.lookPrefix + (preserveLuminance ? "L1" : "L0") + "|" + zip(from, to).map { "\($0.hex)>\($1.hex)" }.joined(separator: ",")
    }

    init(from: [RGBA], to: [RGBA], preserveLuminance: Bool = false) { self.from = from; self.to = to; self.preserveLuminance = preserveLuminance }

    init?(lookName: String) {
        guard lookName.hasPrefix(RecolorMap.lookPrefix) else { return nil }
        let parts = lookName.dropFirst(RecolorMap.lookPrefix.count).split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        var f: [RGBA] = [], t: [RGBA] = []
        for pair in parts[1].split(separator: ",") {
            let ab = pair.split(separator: ">")
            guard ab.count == 2, let a = RGBA(hex: String(ab[0])), let b = RGBA(hex: String(ab[1])) else { continue }
            f.append(a); t.append(b)
        }
        self.init(from: f, to: t, preserveLuminance: parts[0] == "L1")
    }

    private static var parsed: [String: RecolorMap] = [:]

    /// Colour function of a "Recolor|…" look (called by `AdjustmentEngine.look` while it builds the colour cube).
    static func look(_ name: String, _ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let m: RecolorMap
        if let c = parsed[name] { m = c } else {
            guard let p = RecolorMap(lookName: name) else { return (r, g, b) }
            if parsed.count > 32 { parsed.removeAll() }
            parsed[name] = p
            m = p
        }
        let o = m.map(RGBA(r: r, g: g, b: b))
        return (o.r, o.g, o.b)
    }
}

enum RecolorScope: String, CaseIterable, Identifiable {
    case document, selectedLayers
    var id: String { rawValue }
    var title: String { self == .document ? "Whole Document" : "Selected Layers" }
}

enum Recolor {
    static let layerName = "Recolour"

    private static func targets(_ st: DocumentState, scope: RecolorScope, selected: Set<UUID>) -> [Layer] {
        let all = st.allLayers.filter { $0.isVisible && !$0.isGroup }
        return scope == .document ? all : all.filter { selected.contains($0.id) }
    }

    /// Solid colours used by vector / text / fill layers and effects in scope.
    static func vectorColors(_ st: DocumentState, scope: RecolorScope, selected: Set<UUID>) -> [RGBA] {
        var out: [RGBA] = []
        for l in targets(st, scope: scope, selected: selected) {
            for s in ColorSlot.allCases {
                if let c = GlobalColors.color(l, s), !out.contains(where: { $0.hex == c.hex }) { out.append(c.withAlpha(1)) }
            }
            for r in l.text?.runs ?? [] { if let c = r.style.color, !out.contains(where: { $0.hex == c.hex }) { out.append(c.withAlpha(1)) } }
        }
        return out
    }

    /// The artwork's palette: exact vector colours first, then the dominant raster colours (k-means), merged so that
    /// near-duplicates collapse, capped at `count`.
    static func sourcePalette(_ st: DocumentState, scope: RecolorScope, selected: Set<UUID>, count: Int) -> [RGBA] {
        var out = vectorColors(st, scope: scope, selected: selected)
        var sub = st
        if scope == .selectedLayers {
            for l in st.allLayers where !l.isGroup && !selected.contains(l.id) { sub.updateLayer(l.id) { $0.isVisible = false } }
        }
        let hasRaster = targets(st, scope: scope, selected: selected).contains { $0.isRaster || $0.isSmartObject }
        if hasRaster || out.isEmpty {
            let src: PaletteSource = st.selection != nil ? .selection : .document
            for e in PaletteTools.palette(sub, source: src, activeLayer: nil, count: count).sorted(by: { $0.weight > $1.weight }) {
                let lab = Oklab(e.color)
                if !out.contains(where: { Oklab($0).distance(lab) < 0.04 }) { out.append(e.color) }
            }
        }
        return Array(out.prefix(max(1, count)))
    }

    /// Target palette from a harmony rule: the scheme's hues are handed to the source colours in hue order; each target
    /// keeps the saturation and brightness of the colour it replaces.
    static func harmonyTargets(_ from: [RGBA], scheme: HarmonyScheme, base: RGBA) -> [RGBA] {
        let hues = ColorHarmony.colors(scheme, base: base).map { $0.hsb.h }
        guard !hues.isEmpty else { return from }
        let baseHue = base.hsb.h
        func rel(_ h: Double) -> Double { let d = h - baseHue; return d - floor(d) }
        let sortedHues = hues.sorted { rel($0) < rel($1) }
        let order = from.indices.sorted { rel(from[$0].hsb.h) < rel(from[$1].hsb.h) }
        var out = from
        for (rank, idx) in order.enumerated() {
            let (_, s, v) = from[idx].hsb
            let slot = min(sortedHues.count - 1, rank * sortedHues.count / max(1, order.count))
            // greys stay grey
            out[idx] = s < 0.05 ? from[idx] : RGBA(h: sortedHues[slot], s: scheme == .monochrome ? s * 0.9 : s, v: v)
        }
        return out
    }

    /// Applies a mapping to a document state: vector, text and fill colours (and effect colours) are edited in place
    /// (they stay live objects); every raster / smart-object layer in scope gets a clipped Colour Lookup adjustment
    /// carrying the mapping. Re-applying replaces earlier "Recolour" adjustments instead of stacking them.
    static func apply(_ map: RecolorMap, to st: inout DocumentState, scope: RecolorScope, selected: Set<UUID>, vector: Bool = true, raster: Bool = true) {
        let ids = targets(st, scope: scope, selected: selected).map(\.id)
        for id in ids {
            guard let l = st.layer(id) else { continue }
            if vector {
                st.updateLayer(id) { layer in
                    for s in ColorSlot.allCases {
                        if let c = GlobalColors.color(layer, s) { GlobalColors.set(&layer, s, map.map(c)) }
                    }
                    if var t = layer.text {
                        for i in t.runs.indices { if let c = t.runs[i].style.color { t.runs[i].style.color = map.map(c) } }
                        layer.text = t
                    }
                }
            }
            if raster && (l.isRaster || l.isSmartObject) {
                // an existing recolour adjustment directly above is updated in place
                let sib = st.siblings(of: id)
                if let i = sib.firstIndex(where: { $0.id == id }), i + 1 < sib.count, sib[i + 1].isClipped,
                   let a = sib[i + 1].adjustment, a.kind == .colorLookup, a.lookName.hasPrefix(RecolorMap.lookPrefix) {
                    st.updateLayer(sib[i + 1].id) { $0.adjustment?.lookName = map.lookName }
                } else if !map.isIdentity {
                    var s = AdjustmentSettings(kind: .colorLookup)
                    s.lookName = map.lookName
                    var adj = Layer(name: layerName, content: .adjustment(s))
                    adj.isClipped = true
                    if let sel = st.selection { adj.mask = LayerMask(buffer: sel.copy(), origin: .zero, outsideValue: 0) }
                    st.insertLayer(adj, above: id)
                }
            }
        }
        GlobalColors.validate(&st)
    }
}

// MARK: - Contrast checker

struct ContrastReport: Equatable {
    var text: RGBA
    /// Average colour beneath the glyphs, and the beneath colours giving the lowest / highest contrast.
    var background: RGBA
    var worstBackground: RGBA
    var bestBackground: RGBA
    /// Contrast against the average background and the worst-case (5th percentile) contrast.
    var ratio: Double
    var worstRatio: Double
    var largeText: Bool
    var level: WCAG.Level
    /// Nearest colours that pass AA and AAA against everything beneath (nil when already passing / impossible).
    var suggestionAA: RGBA?
    var suggestionAAA: RGBA?
}

enum ContrastChecker {
    /// Layers painted before (beneath) `id`, keeping the group structure.
    static func beneath(_ layers: [Layer], _ id: UUID) -> [Layer]? {
        for (i, l) in layers.enumerated() {
            if l.id == id { return Array(layers[..<i]) }
            if l.isGroup, let sub = beneath(l.children, id) {
                var g = l
                g.children = sub
                return Array(layers[..<i]) + [g]
            }
        }
        return nil
    }

    static func report(_ st: DocumentState, layerID: UUID) -> ContrastReport? {
        guard let layer = st.layer(layerID), let t = layer.text, let under = beneath(st.layers, layerID) else { return nil }
        let sp = CanvasSpace(width: st.width, height: st.height)
        // Where the glyphs are (reduced resolution keeps this quick on large documents).
        guard let content = Compositor.shared.contentImage(layer, space: sp) else { return nil }
        let k = min(1, 512 / CGFloat(max(st.width, st.height)))
        let w = max(1, Int((CGFloat(st.width) * k).rounded())), h = max(1, Int((CGFloat(st.height) * k).rounded()))
        let small = CanvasSpace(width: w, height: h)
        let scale = CGAffineTransform(scaleX: CGFloat(w) / CGFloat(st.width), y: CGFloat(h) / CGFloat(st.height))
        let rect = IRect(x: 0, y: 0, width: w, height: h)
        let glyphs = RenderEngine.renderBuffer(content.cropped(to: sp.ciCanvas).transformed(by: scale), docRect: rect, space: small)
        var below = st
        below.layers = under
        let bgImg = Compositor.shared.composite(below).composited(over: CIImage.color(.white, sp.ciCanvas)).cropped(to: sp.ciCanvas)
        let bg = RenderEngine.renderBuffer(bgImg.transformed(by: scale), docRect: rect, space: small)

        let gp = glyphs.data.assumingMemoryBound(to: UInt8.self), bp = bg.data.assumingMemoryBound(to: UInt8.self)
        var samples: [RGBA] = []
        var sr = 0.0, sg = 0.0, sb = 0.0
        // the glyph pixels and their immediate surroundings (what the eye compares the text against)
        let reach = 2
        for y in 0..<h {
            for x in 0..<w {
                var near = false
                search: for dy in -reach...reach {
                    for dx in -reach...reach {
                        let xx = x + dx, yy = y + dy
                        if xx >= 0, yy >= 0, xx < w, yy < h, gp[yy * glyphs.bytesPerRow + xx * 4 + 3] > 48 { near = true; break search }
                    }
                }
                guard near else { continue }
                let i = y * bg.bytesPerRow + x * 4
                let c = RGBA(r8: bp[i], g8: bp[i + 1], b8: bp[i + 2])
                samples.append(c)
                sr += c.r; sg += c.g; sb += c.b
            }
        }
        guard !samples.isEmpty else { return nil }
        let n = Double(samples.count)
        let avg = RGBA(r: sr / n, g: sg / n, b: sb / n)
        let text = t.color.withAlpha(1)
        let sorted = samples.sorted { WCAG.contrast(text, $0) < WCAG.contrast(text, $1) }
        let worst = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.05))]
        let best = sorted[max(0, Int(Double(sorted.count) * 0.95) - 1)]
        let ratio = WCAG.contrast(text, avg), worstRatio = WCAG.contrast(text, worst)
        let bold = t.fauxBold || t.fontName.lowercased().contains("bold") || t.fontName.lowercased().contains("black") || t.fontName.lowercased().contains("heavy")
        let large = WCAG.isLarge(fontSize: t.fontSize * Double(t.transform.scaleFactor), bold: bold)
        // extremes of what lies beneath: a suggestion has to pass against all of them
        let lums = samples.sorted { WCAG.luminance($0) < WCAG.luminance($1) }
        let ends = [lums[min(lums.count - 1, Int(Double(lums.count) * 0.05))], lums[max(0, Int(Double(lums.count) * 0.95) - 1)], avg]
        let aaTarget = large ? 3.0 : 4.5, aaaTarget = large ? 4.5 : 7.0
        let level = WCAG.level(worstRatio, largeText: large)
        return ContrastReport(text: text, background: avg, worstBackground: worst, bestBackground: best, ratio: ratio, worstRatio: worstRatio,
                              largeText: large, level: level,
                              suggestionAA: worstRatio >= aaTarget ? nil : WCAG.nearestPassing(text, on: ends, target: aaTarget),
                              suggestionAAA: worstRatio >= aaaTarget ? nil : WCAG.nearestPassing(text, on: ends, target: aaaTarget))
    }

    private static var cache: (key: String, report: ContrastReport?)?

    /// Report for a live document, recomputed only when the document is committed or the text's look changes
    /// (panels call this on every refresh).
    static func cachedReport(_ d: Document, layerID: UUID) -> ContrastReport? {
        guard let t = d.state.layer(layerID)?.text else { return nil }
        let key = "\(d.id)|\(layerID)|\(d.revision)|\(t.color.hex)|\(t.fontSize)|\(t.fontName)|\(t.fauxBold)|\(t.text.count)"
        if let c = cache, c.key == key { return c.report }
        let r = report(d.state, layerID: layerID)
        cache = (key, r)
        return r
    }

    static func apply(_ d: Document, layerID: UUID, color: RGBA) {
        d.updateLayer(layerID) { GlobalColors.set(&$0, .textColor, color) }
        GlobalColors.validate(&d.state)
        d.commit("Text Colour (Contrast)")
    }
}
