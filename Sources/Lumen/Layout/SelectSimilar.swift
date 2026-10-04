import AppKit
import ImageCratCore

/// Select ▸ Similar Layers: selects every layer that matches the active layer in one respect
/// (like Illustrator's Select ▸ Same, for layers).
enum SimilarCriterion: String, CaseIterable {
    case kind = "Same Kind"
    case fill = "Same Fill Colour"
    case stroke = "Same Stroke"
    case font = "Same Font"
    case fontSize = "Same Font Size"
    case effects = "Same Effects"
    case blendMode = "Same Blend Mode"
    case size = "Same Size"
    case namePattern = "Same Name Pattern"
    case colorLabel = "Same Colour Label"
}

enum SelectSimilar {
    /// A short tag for the layer kind (adjustments are told apart by their type, shapes are all "shape").
    static func kindKey(_ l: Layer) -> String {
        switch l.content {
        case .raster: return "raster"
        case .text: return "text"
        case .shape: return "shape"
        case .smartObject: return "smart"
        case .adjustment(let a): return "adjustment:\(a.kind.rawValue)"
        case .fill(let f):
            switch f.paint { case .color: return "fill:color"; case .gradient: return "fill:gradient"; case .pattern: return "fill:pattern"; case .none: return "fill:none" }
        case .group(let g): return g.artboard != nil ? "artboard" : (g.repeater != nil ? "repeater" : "group")
        }
    }

    /// The layer's main colour: shape fill, type colour or solid fill layer.
    static func fillColor(_ l: Layer) -> RGBA? {
        switch l.content {
        case .shape(let s): return s.fill.solidColor
        case .text(let t): return t.color
        case .fill(let f): return f.paint.solidColor
        default: return nil
        }
    }

    static func sameColor(_ a: RGBA, _ b: RGBA) -> Bool {
        abs(a.r - b.r) < 0.004 && abs(a.g - b.g) < 0.004 && abs(a.b - b.b) < 0.004 && abs(a.a - b.a) < 0.004
    }

    private static let zeroID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Gradients carry per-instance ids; these copies compare by value only.
    static func normalized(_ g: ColorGradient) -> ColorGradient {
        ColorGradient(id: zeroID, name: "", stops: g.sortedStops.map { GradientStop(id: zeroID, location: $0.location, color: $0.color) })
    }
    static func normalized(_ p: PaintStyle) -> PaintStyle {
        guard case .gradient(var g) = p else { return p }
        g.gradient = normalized(g.gradient)
        return .gradient(g)
    }
    static func normalized(_ fx: LayerEffects) -> LayerEffects {
        var f = fx
        f.outerGlow.gradient = normalized(f.outerGlow.gradient)
        f.innerGlow.gradient = normalized(f.innerGlow.gradient)
        f.gradientOverlay.fill.gradient = normalized(f.gradientOverlay.fill.gradient)
        for i in f.extraGradientOverlays.indices { f.extraGradientOverlays[i].fill.gradient = normalized(f.extraGradientOverlays[i].fill.gradient) }
        f.stroke.paint = normalized(f.stroke.paint)
        for i in f.extraStrokes.indices { f.extraStrokes[i].paint = normalized(f.extraStrokes[i].paint) }
        return f
    }

    /// Shape stroke (paint + width), or the Stroke layer effect when there is no shape stroke.
    static func strokeKey(_ l: Layer) -> (PaintStyle, Double)? {
        if let s = l.shape, !s.stroke.paint.isNone, s.stroke.width > 0 { return (s.stroke.paint, s.stroke.width) }
        if l.effects.enabled, let fx = l.effects.strokes.first(where: { $0.enabled }) { return (fx.paint, fx.size) }
        return nil
    }

    /// Fonts used by a type layer (layer default plus per-range overrides).
    static func fonts(_ t: TextContent) -> Set<String> {
        var out: Set<String> = []
        let n = t.utf16Count
        let covered = t.runs.filter { $0.style.fontName != nil }.reduce(0) { $0 + $1.length }
        if covered < n || t.runs.isEmpty { out.insert(t.fontName) }
        for r in t.runs { if let f = r.style.fontName { out.insert(f) } }
        return out
    }

    /// Rendered size of the type (font size × the layer's scale).
    static func fontSize(_ t: TextContent) -> Double { t.fontSize * Double(t.transform.scaleFactor) }

    /// "Button 12", "Button copy 3" and "Button" all share the pattern "button".
    static func namePattern(_ name: String) -> String {
        var s = name.lowercased()
        while let r = s.range(of: #"(\s+copy)?(\s*[-_#]?\s*\d+)?\s*$"#, options: .regularExpression), !r.isEmpty { s.removeSubrange(r) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func matches(_ l: Layer, _ ref: Layer, _ c: SimilarCriterion, state st: DocumentState) -> Bool {
        switch c {
        case .kind: return kindKey(l) == kindKey(ref)
        case .fill:
            guard let a = fillColor(l), let b = fillColor(ref) else { return false }
            return sameColor(a, b)
        case .stroke:
            guard let a = strokeKey(l), let b = strokeKey(ref) else { return false }
            return normalized(a.0) == normalized(b.0) && abs(a.1 - b.1) < 0.01
        case .font:
            guard let a = l.text, let b = ref.text else { return false }
            return !fonts(a).isDisjoint(with: fonts(b))
        case .fontSize:
            guard let a = l.text, let b = ref.text else { return false }
            return abs(fontSize(a) - fontSize(b)) < 0.26
        case .effects:
            let on = { (x: Layer) in x.effects.enabled && x.effects.hasAny }
            if !on(ref) { return !on(l) && !l.isGroup && !l.isAdjustment }
            return on(l) && normalized(l.effects) == normalized(ref.effects)
        case .blendMode: return l.blendMode == ref.blendMode && l.isGroup == ref.isGroup
        case .size:
            guard let a = Compositor.shared.contentBounds(l, state: st), let b = Compositor.shared.contentBounds(ref, state: st) else { return false }
            return abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
        case .namePattern: return namePattern(l.name) == namePattern(ref.name)
        case .colorLabel: return l.colorLabel == ref.colorLabel
        }
    }

    /// Ids of all layers that match `ref` (always includes `ref`), bottom-first.
    static func find(_ c: SimilarCriterion, ref: Layer, in st: DocumentState) -> [UUID] {
        st.allLayers.filter { $0.id == ref.id || matches($0, ref, c, state: st) }.map(\.id)
    }

    static func run(_ c: SimilarCriterion) {
        guard let d = AppActions.doc, let ref = d.activeLayer else { NSSound.beep(); return }
        let ids = find(c, ref: ref, in: d.state)
        d.selectedLayerIDs = Set(ids)
        d.activeLayerID = ref.id
        // reveal matches that sit in collapsed groups
        var st = d.state
        var expanded = false
        for id in ids {
            var p = st.parentID(of: id)
            while let pid = p {
                if st.layer(pid)?.isExpanded == false { st.updateLayer(pid) { $0.isExpanded = true }; expanded = true }
                p = st.parentID(of: pid)
            }
        }
        if expanded { d.state = st }
        d.setNeedsOverlay()
        let what = c.rawValue.replacingOccurrences(of: "Same ", with: "").lowercased()
        AppModel.shared.setStatus(ids.count <= 1 ? "No other layer has the same \(what)." : "Selected \(ids.count) layers with the same \(what).")
    }
}
