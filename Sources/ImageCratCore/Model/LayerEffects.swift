import Foundation

package struct ShadowEffect: Codable, Equatable {
    package var enabled = false
    package var blendMode: BlendMode = .multiply
    package var color: RGBA = .black
    package var opacity: Double = 0.75
    package var angle: Double = 120
    package var distance: Double = 10
    package var spread: Double = 0      // 0...100 %
    package var size: Double = 10
    package var contour: Contour = .linear
    package var noise: Double = 0       // 0...100 %
    package var useGlobalLight: Bool = true
    /// Drop shadow only: the layer's own shape knocks out the shadow (visible through semi-transparent fills).
    package var layerKnocksOut: Bool = true
    /// Photoshop's eye in the Layers panel: the effect stays in the style with its settings but is switched off
    /// (`enabled` false). Rendering only looks at `enabled`; see LayerEffectItem.
    package var isHidden = false

    package init(enabled: Bool = false, blendMode: BlendMode = .multiply, color: RGBA = .black, opacity: Double = 0.75, angle: Double = 120, distance: Double = 10, spread: Double = 0, size: Double = 10, contour: Contour = .linear, noise: Double = 0, useGlobalLight: Bool = true, layerKnocksOut: Bool = true, isHidden: Bool = false) {
        self.enabled = enabled; self.blendMode = blendMode; self.color = color; self.opacity = opacity; self.angle = angle; self.distance = distance; self.spread = spread; self.size = size; self.contour = contour; self.noise = noise; self.useGlobalLight = useGlobalLight; self.layerKnocksOut = layerKnocksOut; self.isHidden = isHidden
    }
}
// tolerant-decoding:ShadowEffect (generated: missing keys fall back to defaults)
extension ShadowEffect {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShadowEffect()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        blendMode = try c.decodeIfPresent(BlendMode.self, forKey: .blendMode) ?? d.blendMode
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? d.color
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? d.angle
        distance = try c.decodeIfPresent(Double.self, forKey: .distance) ?? d.distance
        spread = try c.decodeIfPresent(Double.self, forKey: .spread) ?? d.spread
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        contour = try c.decodeIfPresent(Contour.self, forKey: .contour) ?? d.contour
        noise = try c.decodeIfPresent(Double.self, forKey: .noise) ?? d.noise
        useGlobalLight = try c.decodeIfPresent(Bool.self, forKey: .useGlobalLight) ?? d.useGlobalLight
        layerKnocksOut = try c.decodeIfPresent(Bool.self, forKey: .layerKnocksOut) ?? d.layerKnocksOut
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? d.isHidden
    }
}
// end-tolerant

package enum GlowSource: String, Codable, CaseIterable { case edge, center }
package enum GlowTechnique: String, Codable, CaseIterable { case softer, precise }

package struct GlowEffect: Codable, Equatable {
    package var enabled = false
    package var blendMode: BlendMode = .screen
    package var color: RGBA = RGBA(r: 1, g: 1, b: 0.75)
    package var opacity: Double = 0.75
    package var spread: Double = 0
    package var size: Double = 10
    package var source: GlowSource = .edge
    package var technique: GlowTechnique = .softer
    package var contour: Contour = .linear
    package var range: Double = 50      // % of the ramp the contour covers
    package var noise: Double = 0
    package var jitter: Double = 0      // gradient jitter
    package var useGradient: Bool = false
    package var gradient: ColorGradient = .twoColor(RGBA(r: 1, g: 1, b: 0.75), RGBA(r: 1, g: 1, b: 0.75, a: 0), name: "Glow")
    /// Photoshop's eye in the Layers panel: the effect stays in the style with its settings but is switched off
    /// (`enabled` false). Rendering only looks at `enabled`; see LayerEffectItem.
    package var isHidden = false

    package init(enabled: Bool = false, blendMode: BlendMode = .screen, color: RGBA = RGBA(r: 1, g: 1, b: 0.75), opacity: Double = 0.75, spread: Double = 0, size: Double = 10, source: GlowSource = .edge, technique: GlowTechnique = .softer, contour: Contour = .linear, range: Double = 50, noise: Double = 0, jitter: Double = 0, useGradient: Bool = false, gradient: ColorGradient = .twoColor(RGBA(r: 1, g: 1, b: 0.75), RGBA(r: 1, g: 1, b: 0.75, a: 0), name: "Glow"), isHidden: Bool = false) {
        self.enabled = enabled; self.blendMode = blendMode; self.color = color; self.opacity = opacity; self.spread = spread; self.size = size; self.source = source; self.technique = technique; self.contour = contour; self.range = range; self.noise = noise; self.jitter = jitter; self.useGradient = useGradient; self.gradient = gradient; self.isHidden = isHidden
    }
}
// tolerant-decoding:GlowEffect (generated: missing keys fall back to defaults)
extension GlowEffect {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GlowEffect()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        blendMode = try c.decodeIfPresent(BlendMode.self, forKey: .blendMode) ?? d.blendMode
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? d.color
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        spread = try c.decodeIfPresent(Double.self, forKey: .spread) ?? d.spread
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        source = try c.decodeIfPresent(GlowSource.self, forKey: .source) ?? d.source
        technique = try c.decodeIfPresent(GlowTechnique.self, forKey: .technique) ?? d.technique
        contour = try c.decodeIfPresent(Contour.self, forKey: .contour) ?? d.contour
        range = try c.decodeIfPresent(Double.self, forKey: .range) ?? d.range
        noise = try c.decodeIfPresent(Double.self, forKey: .noise) ?? d.noise
        jitter = try c.decodeIfPresent(Double.self, forKey: .jitter) ?? d.jitter
        useGradient = try c.decodeIfPresent(Bool.self, forKey: .useGradient) ?? d.useGradient
        gradient = try c.decodeIfPresent(ColorGradient.self, forKey: .gradient) ?? d.gradient
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? d.isHidden
    }
}
// end-tolerant

package enum BevelStyle: String, Codable, CaseIterable {
    case innerBevel, outerBevel, emboss, pillowEmboss
    package var displayName: String {
        switch self {
        case .innerBevel: return "Inner Bevel"
        case .outerBevel: return "Outer Bevel"
        case .emboss: return "Emboss"
        case .pillowEmboss: return "Pillow Emboss"
        }
    }
}

package enum BevelTechnique: String, Codable, CaseIterable { case smooth, chiselHard, chiselSoft
    package var displayName: String { switch self { case .smooth: return "Smooth"; case .chiselHard: return "Chisel Hard"; case .chiselSoft: return "Chisel Soft" } }
}

package struct BevelEffect: Codable, Equatable {
    package var enabled = false
    package var style: BevelStyle = .innerBevel
    package var technique: BevelTechnique = .smooth
    package var depth: Double = 100      // %
    package var directionUp = true
    package var size: Double = 5
    package var soften: Double = 0
    package var angle: Double = 120
    package var altitude: Double = 30
    package var highlightMode: BlendMode = .screen
    package var highlightColor: RGBA = .white
    package var highlightOpacity: Double = 0.75
    package var shadowMode: BlendMode = .multiply
    package var shadowColor: RGBA = .black
    package var shadowOpacity: Double = 0.75
    package var useGlobalLight: Bool = true
    package var glossContour: Contour = .linear
    package var contourEnabled: Bool = false
    package var contour: Contour = .linear
    package var contourRange: Double = 50
    package var textureEnabled: Bool = false
    package var texturePatternID: String = "canvas"
    package var textureScale: Double = 1
    package var textureDepth: Double = 100      // -1000...1000 %
    package var textureInvert: Bool = false
    /// Photoshop's eye in the Layers panel: the effect stays in the style with its settings but is switched off
    /// (`enabled` false). Rendering only looks at `enabled`; see LayerEffectItem.
    package var isHidden = false

    package init(enabled: Bool = false, style: BevelStyle = .innerBevel, technique: BevelTechnique = .smooth, depth: Double = 100, directionUp: Bool = true, size: Double = 5, soften: Double = 0, angle: Double = 120, altitude: Double = 30, highlightMode: BlendMode = .screen, highlightColor: RGBA = .white, highlightOpacity: Double = 0.75, shadowMode: BlendMode = .multiply, shadowColor: RGBA = .black, shadowOpacity: Double = 0.75, useGlobalLight: Bool = true, glossContour: Contour = .linear, contourEnabled: Bool = false, contour: Contour = .linear, contourRange: Double = 50, textureEnabled: Bool = false, texturePatternID: String = "canvas", textureScale: Double = 1, textureDepth: Double = 100, textureInvert: Bool = false, isHidden: Bool = false) {
        self.enabled = enabled; self.style = style; self.technique = technique; self.depth = depth; self.directionUp = directionUp; self.size = size; self.soften = soften; self.angle = angle; self.altitude = altitude; self.highlightMode = highlightMode; self.highlightColor = highlightColor; self.highlightOpacity = highlightOpacity; self.shadowMode = shadowMode; self.shadowColor = shadowColor; self.shadowOpacity = shadowOpacity; self.useGlobalLight = useGlobalLight; self.glossContour = glossContour; self.contourEnabled = contourEnabled; self.contour = contour; self.contourRange = contourRange; self.textureEnabled = textureEnabled; self.texturePatternID = texturePatternID; self.textureScale = textureScale; self.textureDepth = textureDepth; self.textureInvert = textureInvert; self.isHidden = isHidden
    }
}
// tolerant-decoding:BevelEffect (generated: missing keys fall back to defaults)
extension BevelEffect {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BevelEffect()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        style = try c.decodeIfPresent(BevelStyle.self, forKey: .style) ?? d.style
        technique = try c.decodeIfPresent(BevelTechnique.self, forKey: .technique) ?? d.technique
        depth = try c.decodeIfPresent(Double.self, forKey: .depth) ?? d.depth
        directionUp = try c.decodeIfPresent(Bool.self, forKey: .directionUp) ?? d.directionUp
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        soften = try c.decodeIfPresent(Double.self, forKey: .soften) ?? d.soften
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? d.angle
        altitude = try c.decodeIfPresent(Double.self, forKey: .altitude) ?? d.altitude
        highlightMode = try c.decodeIfPresent(BlendMode.self, forKey: .highlightMode) ?? d.highlightMode
        highlightColor = try c.decodeIfPresent(RGBA.self, forKey: .highlightColor) ?? d.highlightColor
        highlightOpacity = try c.decodeIfPresent(Double.self, forKey: .highlightOpacity) ?? d.highlightOpacity
        shadowMode = try c.decodeIfPresent(BlendMode.self, forKey: .shadowMode) ?? d.shadowMode
        shadowColor = try c.decodeIfPresent(RGBA.self, forKey: .shadowColor) ?? d.shadowColor
        shadowOpacity = try c.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? d.shadowOpacity
        useGlobalLight = try c.decodeIfPresent(Bool.self, forKey: .useGlobalLight) ?? d.useGlobalLight
        glossContour = try c.decodeIfPresent(Contour.self, forKey: .glossContour) ?? d.glossContour
        contourEnabled = try c.decodeIfPresent(Bool.self, forKey: .contourEnabled) ?? d.contourEnabled
        contour = try c.decodeIfPresent(Contour.self, forKey: .contour) ?? d.contour
        contourRange = try c.decodeIfPresent(Double.self, forKey: .contourRange) ?? d.contourRange
        textureEnabled = try c.decodeIfPresent(Bool.self, forKey: .textureEnabled) ?? d.textureEnabled
        texturePatternID = try c.decodeIfPresent(String.self, forKey: .texturePatternID) ?? d.texturePatternID
        textureScale = try c.decodeIfPresent(Double.self, forKey: .textureScale) ?? d.textureScale
        textureDepth = try c.decodeIfPresent(Double.self, forKey: .textureDepth) ?? d.textureDepth
        textureInvert = try c.decodeIfPresent(Bool.self, forKey: .textureInvert) ?? d.textureInvert
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? d.isHidden
    }
}
// end-tolerant

package struct SatinEffect: Codable, Equatable {
    package var enabled = false
    package var blendMode: BlendMode = .multiply
    package var color: RGBA = .black
    package var opacity: Double = 0.5
    package var angle: Double = 19
    package var distance: Double = 11
    package var size: Double = 14
    package var invert: Bool = true
    package var contour: Contour = Contour(preset: .gaussian)
    /// Photoshop's eye in the Layers panel: the effect stays in the style with its settings but is switched off
    /// (`enabled` false). Rendering only looks at `enabled`; see LayerEffectItem.
    package var isHidden = false

    package init(enabled: Bool = false, blendMode: BlendMode = .multiply, color: RGBA = .black, opacity: Double = 0.5, angle: Double = 19, distance: Double = 11, size: Double = 14, invert: Bool = true, contour: Contour = Contour(preset: .gaussian), isHidden: Bool = false) {
        self.enabled = enabled; self.blendMode = blendMode; self.color = color; self.opacity = opacity; self.angle = angle; self.distance = distance; self.size = size; self.invert = invert; self.contour = contour; self.isHidden = isHidden
    }
}
// tolerant-decoding:SatinEffect (generated: missing keys fall back to defaults)
extension SatinEffect {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SatinEffect()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        blendMode = try c.decodeIfPresent(BlendMode.self, forKey: .blendMode) ?? d.blendMode
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? d.color
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? d.angle
        distance = try c.decodeIfPresent(Double.self, forKey: .distance) ?? d.distance
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? d.invert
        contour = try c.decodeIfPresent(Contour.self, forKey: .contour) ?? d.contour
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? d.isHidden
    }
}
// end-tolerant

package struct ColorOverlayEffect: Codable, Equatable {
    package var enabled = false
    package var blendMode: BlendMode = .normal
    package var color: RGBA = RGBA(r: 1, g: 0, b: 0)
    package var opacity: Double = 1
    /// Photoshop's eye in the Layers panel: the effect stays in the style with its settings but is switched off
    /// (`enabled` false). Rendering only looks at `enabled`; see LayerEffectItem.
    package var isHidden = false

    package init(enabled: Bool = false, blendMode: BlendMode = .normal, color: RGBA = RGBA(r: 1, g: 0, b: 0), opacity: Double = 1, isHidden: Bool = false) {
        self.enabled = enabled; self.blendMode = blendMode; self.color = color; self.opacity = opacity; self.isHidden = isHidden
    }
}
// tolerant-decoding:ColorOverlayEffect (generated: missing keys fall back to defaults)
extension ColorOverlayEffect {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ColorOverlayEffect()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        blendMode = try c.decodeIfPresent(BlendMode.self, forKey: .blendMode) ?? d.blendMode
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? d.color
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? d.isHidden
    }
}
// end-tolerant

package struct GradientOverlayEffect: Codable, Equatable {
    package var enabled = false
    package var blendMode: BlendMode = .normal
    package var opacity: Double = 1
    package var fill = GradientFill(gradient: ColorGradient.presets[0])
    /// Photoshop's eye in the Layers panel: the effect stays in the style with its settings but is switched off
    /// (`enabled` false). Rendering only looks at `enabled`; see LayerEffectItem.
    package var isHidden = false

    package init(enabled: Bool = false, blendMode: BlendMode = .normal, opacity: Double = 1, fill: GradientFill = GradientFill(gradient: ColorGradient.presets[0]), isHidden: Bool = false) {
        self.enabled = enabled; self.blendMode = blendMode; self.opacity = opacity; self.fill = fill; self.isHidden = isHidden
    }
}
// tolerant-decoding:GradientOverlayEffect (generated: missing keys fall back to defaults)
extension GradientOverlayEffect {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GradientOverlayEffect()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        blendMode = try c.decodeIfPresent(BlendMode.self, forKey: .blendMode) ?? d.blendMode
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        fill = try c.decodeIfPresent(GradientFill.self, forKey: .fill) ?? d.fill
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? d.isHidden
    }
}
// end-tolerant

package struct PatternOverlayEffect: Codable, Equatable {
    package var enabled = false
    package var blendMode: BlendMode = .normal
    package var opacity: Double = 1
    package var patternID: String = "checker"
    package var scale: Double = 1
    /// Photoshop's eye in the Layers panel: the effect stays in the style with its settings but is switched off
    /// (`enabled` false). Rendering only looks at `enabled`; see LayerEffectItem.
    package var isHidden = false

    package init(enabled: Bool = false, blendMode: BlendMode = .normal, opacity: Double = 1, patternID: String = "checker", scale: Double = 1, isHidden: Bool = false) {
        self.enabled = enabled; self.blendMode = blendMode; self.opacity = opacity; self.patternID = patternID; self.scale = scale; self.isHidden = isHidden
    }
}
// tolerant-decoding:PatternOverlayEffect (generated: missing keys fall back to defaults)
extension PatternOverlayEffect {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PatternOverlayEffect()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        blendMode = try c.decodeIfPresent(BlendMode.self, forKey: .blendMode) ?? d.blendMode
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        patternID = try c.decodeIfPresent(String.self, forKey: .patternID) ?? d.patternID
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? d.scale
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? d.isHidden
    }
}
// end-tolerant

package enum StrokePosition: String, Codable, CaseIterable { case outside, inside, center }

package struct StrokeEffect: Codable, Equatable {
    package var enabled = false
    package var size: Double = 3
    package var position: StrokePosition = .outside
    package var blendMode: BlendMode = .normal
    package var opacity: Double = 1
    package var paint: PaintStyle = .color(.black)
    /// Photoshop's eye in the Layers panel: the effect stays in the style with its settings but is switched off
    /// (`enabled` false). Rendering only looks at `enabled`; see LayerEffectItem.
    package var isHidden = false

    package init(enabled: Bool = false, size: Double = 3, position: StrokePosition = .outside, blendMode: BlendMode = .normal, opacity: Double = 1, paint: PaintStyle = .color(.black), isHidden: Bool = false) {
        self.enabled = enabled; self.size = size; self.position = position; self.blendMode = blendMode; self.opacity = opacity; self.paint = paint; self.isHidden = isHidden
    }
}
// tolerant-decoding:StrokeEffect (generated: missing keys fall back to defaults)
extension StrokeEffect {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StrokeEffect()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        position = try c.decodeIfPresent(StrokePosition.self, forKey: .position) ?? d.position
        blendMode = try c.decodeIfPresent(BlendMode.self, forKey: .blendMode) ?? d.blendMode
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        paint = try c.decodeIfPresent(PaintStyle.self, forKey: .paint) ?? d.paint
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? d.isHidden
    }
}
// end-tolerant

package struct LayerEffects: Codable, Equatable {
    package var enabled = true
    package var dropShadow = ShadowEffect()
    package var innerShadow = ShadowEffect(opacity: 0.75, distance: 5, size: 5)
    package var outerGlow = GlowEffect()
    package var innerGlow = GlowEffect(color: RGBA(r: 1, g: 1, b: 0.75))
    package var bevel = BevelEffect()
    package var satin = SatinEffect()
    package var colorOverlay = ColorOverlayEffect()
    package var gradientOverlay = GradientOverlayEffect()
    package var patternOverlay = PatternOverlayEffect()
    package var stroke = StrokeEffect()

    // Additional instances (Photoshop's "+" button). The primary instance is listed first / drawn on top.
    package var extraDropShadows: [ShadowEffect] = []
    package var extraInnerShadows: [ShadowEffect] = []
    package var extraColorOverlays: [ColorOverlayEffect] = []
    package var extraGradientOverlays: [GradientOverlayEffect] = []
    package var extraStrokes: [StrokeEffect] = []

    package init() {}

    package var dropShadows: [ShadowEffect] { [dropShadow] + extraDropShadows }
    package var innerShadows: [ShadowEffect] { [innerShadow] + extraInnerShadows }
    package var colorOverlays: [ColorOverlayEffect] { [colorOverlay] + extraColorOverlays }
    package var gradientOverlays: [GradientOverlayEffect] { [gradientOverlay] + extraGradientOverlays }
    package var strokes: [StrokeEffect] { [stroke] + extraStrokes }

    package var hasAny: Bool {
        dropShadows.contains { $0.enabled } || innerShadows.contains { $0.enabled } || outerGlow.enabled || innerGlow.enabled ||
            bevel.enabled || satin.enabled || colorOverlays.contains { $0.enabled } || gradientOverlays.contains { $0.enabled } ||
            patternOverlay.enabled || strokes.contains { $0.enabled }
    }

    /// Enabled effects in Photoshop's panel order (top of the stack first).
    package var activeNames: [String] {
        var n: [String] = []
        if bevel.enabled { n.append("Bevel & Emboss") }
        n += strokes.filter(\.enabled).map { _ in "Stroke" }
        n += innerShadows.filter(\.enabled).map { _ in "Inner Shadow" }
        if innerGlow.enabled { n.append("Inner Glow") }
        if satin.enabled { n.append("Satin") }
        n += colorOverlays.filter(\.enabled).map { _ in "Color Overlay" }
        n += gradientOverlays.filter(\.enabled).map { _ in "Gradient Overlay" }
        if patternOverlay.enabled { n.append("Pattern Overlay") }
        if outerGlow.enabled { n.append("Outer Glow") }
        n += dropShadows.filter(\.enabled).map { _ in "Drop Shadow" }
        return n
    }

    /// How far effects can extend beyond the layer content (for bounds).
    package var extent: Double {
        var e = 0.0
        for d in dropShadows where d.enabled { e = max(e, d.distance + d.size * 2) }
        if outerGlow.enabled { e = max(e, outerGlow.size * 2) }
        for s in strokes where s.enabled && s.position != .inside { e = max(e, s.size) }
        // (the band, plus the smoothing of Smooth and Soften: see BevelHeightMap)
        if bevel.enabled && (bevel.style == .outerBevel || bevel.style == .emboss || bevel.style == .pillowEmboss) { e = max(e, bevel.size * 2 + bevel.soften * 1.5) }
        return e
    }

    // Tolerant decoding: files written before a field existed still open.
    private enum CodingKeys: String, CodingKey {
        case enabled, dropShadow, innerShadow, outerGlow, innerGlow, bevel, satin, colorOverlay, gradientOverlay, patternOverlay, stroke
        case extraDropShadows, extraInnerShadows, extraColorOverlays, extraGradientOverlays, extraStrokes
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LayerEffects()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        dropShadow = try c.decodeIfPresent(ShadowEffect.self, forKey: .dropShadow) ?? d.dropShadow
        innerShadow = try c.decodeIfPresent(ShadowEffect.self, forKey: .innerShadow) ?? d.innerShadow
        outerGlow = try c.decodeIfPresent(GlowEffect.self, forKey: .outerGlow) ?? d.outerGlow
        innerGlow = try c.decodeIfPresent(GlowEffect.self, forKey: .innerGlow) ?? d.innerGlow
        bevel = try c.decodeIfPresent(BevelEffect.self, forKey: .bevel) ?? d.bevel
        satin = try c.decodeIfPresent(SatinEffect.self, forKey: .satin) ?? d.satin
        colorOverlay = try c.decodeIfPresent(ColorOverlayEffect.self, forKey: .colorOverlay) ?? d.colorOverlay
        gradientOverlay = try c.decodeIfPresent(GradientOverlayEffect.self, forKey: .gradientOverlay) ?? d.gradientOverlay
        patternOverlay = try c.decodeIfPresent(PatternOverlayEffect.self, forKey: .patternOverlay) ?? d.patternOverlay
        stroke = try c.decodeIfPresent(StrokeEffect.self, forKey: .stroke) ?? d.stroke
        extraDropShadows = try c.decodeIfPresent([ShadowEffect].self, forKey: .extraDropShadows) ?? []
        extraInnerShadows = try c.decodeIfPresent([ShadowEffect].self, forKey: .extraInnerShadows) ?? []
        extraColorOverlays = try c.decodeIfPresent([ColorOverlayEffect].self, forKey: .extraColorOverlays) ?? []
        extraGradientOverlays = try c.decodeIfPresent([GradientOverlayEffect].self, forKey: .extraGradientOverlays) ?? []
        extraStrokes = try c.decodeIfPresent([StrokeEffect].self, forKey: .extraStrokes) ?? []
    }
}
