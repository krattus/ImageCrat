import Foundation

// Particle effect settings (Codable, stored as JSON in presets and in re-editable smart objects).
//
// Units: every length is expressed in "units" where the canvas' short side is 1000 units, so a preset looks the
// same on any document size. Positions / emitter sizes are fractions of the canvas width / height. Angles are
// degrees, counter-clockwise from +x with y up (90 = up, 270 = down), like the app's angle dials. Time is seconds.

/// Enums decode unknown raw values as their first case (presets written by newer versions stay loadable).
package protocol PTolerantEnum: RawRepresentable, Codable, CaseIterable where RawValue == String {}
extension PTolerantEnum {
    package init(from decoder: Decoder) throws {
        let s = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = Self(rawValue: s) ?? Self.allCases.first!
    }
}

package enum PBlend: String, PTolerantEnum, Identifiable {
    case normal, additive, multiply
    package var id: String { rawValue }
    package var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .additive: return "Additive (light)"
        case .multiply: return "Multiply (shadow)"
        }
    }
    /// Blend mode of the layer the system is rendered into.
    package var layerMode: BlendMode {
        switch self {
        case .normal: return .normal
        case .additive: return .screen
        case .multiply: return .multiply
        }
    }
}

package enum PEmitterShape: String, PTolerantEnum, Identifiable {
    case point, line, circle, ring, rectangle, frame, grid, spiral, path
    case selectionOutline, selectionArea, layerAlpha, layerEdges, text, brightness
    package var id: String { rawValue }
    package var displayName: String {
        switch self {
        case .point: return "Point"
        case .line: return "Line"
        case .circle: return "Circle (area)"
        case .ring: return "Ring"
        case .rectangle: return "Rectangle (area)"
        case .frame: return "Rectangle outline"
        case .grid: return "Grid"
        case .spiral: return "Spiral arms"
        case .path: return "Along path"
        case .selectionOutline: return "Selection outline"
        case .selectionArea: return "Selection area"
        case .layerAlpha: return "Layer alpha"
        case .layerEdges: return "Layer edges"
        case .text: return "Text (fill or outlines)"
        case .brightness: return "Image brightness"
        }
    }
    /// Shapes sampled from a gray map of the document.
    package var usesMap: Bool {
        switch self {
        case .selectionOutline, .selectionArea, .layerAlpha, .layerEdges, .text, .brightness: return true
        default: return false
        }
    }
    package var isOutline: Bool { self == .selectionOutline || self == .layerEdges }
}

package enum PEmission: String, PTolerantEnum, Identifiable {
    case rate, burst
    package var id: String { rawValue }
    package var displayName: String { self == .rate ? "Rate over time" : "Burst" }
}

package enum PSprite: String, PTolerantEnum, Identifiable {
    case softDisc, hardDisc, star, sparkle, streak, snowflake, raindrop, bubble, smoke, flame, ember
    case confettiRect, confettiTriangle, bokeh, heart, leaf, petal, dust, lensDirt, balloon, square
    case glyph, shape, image
    package var id: String { rawValue }
    package var displayName: String {
        switch self {
        case .softDisc: return "Soft disc"
        case .hardDisc: return "Hard disc"
        case .star: return "Star (n-point)"
        case .sparkle: return "Sparkle / glint"
        case .streak: return "Line / streak"
        case .snowflake: return "Snowflake"
        case .raindrop: return "Raindrop"
        case .bubble: return "Bubble"
        case .smoke: return "Smoke puff"
        case .flame: return "Flame lick"
        case .ember: return "Ember"
        case .confettiRect: return "Confetti rectangle"
        case .confettiTriangle: return "Confetti triangle"
        case .bokeh: return "Bokeh polygon"
        case .heart: return "Heart"
        case .leaf: return "Leaf"
        case .petal: return "Petal"
        case .dust: return "Dust mote"
        case .lensDirt: return "Lens dirt"
        case .balloon: return "Balloon"
        case .square: return "Square"
        case .glyph: return "Text glyph / emoji"
        case .shape: return "Library shape"
        case .image: return "Custom image (layer / brush tip)"
        }
    }
}

package enum PColorBase: String, PTolerantEnum, Identifiable {
    case none, palette, image, parent
    package var id: String { rawValue }
    package var displayName: String {
        switch self {
        case .none: return "Colour over life only"
        case .palette: return "Random from palette"
        case .image: return "From layer / image pixels"
        case .parent: return "Inherit from parent"
        }
    }
}

package enum PTrail: String, PTolerantEnum, Identifiable {
    case none, stretch, streak, ribbon, echo
    package var id: String { rawValue }
    package var displayName: String {
        switch self {
        case .none: return "None"
        case .stretch: return "Stretch by velocity"
        case .streak: return "Motion-blur streak"
        case .ribbon: return "Ribbon (history)"
        case .echo: return "Echo stamps (history)"
        }
    }
}

package enum POutput: String, PTolerantEnum, Identifiable {
    case newLayer, activeLayer, smartObject
    package var id: String { rawValue }
    package var displayName: String {
        switch self {
        case .newLayer: return "New Layer"
        case .activeLayer: return "Into Active Layer"
        case .smartObject: return "Smart Object (re-editable)"
        }
    }
}

package enum PQuality: String, PTolerantEnum, Identifiable {
    case standard, best
    package var id: String { rawValue }
    package var displayName: String { self == .standard ? "Standard (4× MSAA)" : "Best (2× supersampled)" }
}

package struct PAttractor: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var pos = CGPoint(x: 0.5, y: 0.5)
    /// Acceleration (units/s²) at the centre; negative repels.
    package var strength: Double = 600
    /// Falloff radius (units).
    package var radius: Double = 250
    package init(id: UUID = UUID(), pos: CGPoint = CGPoint(x: 0.5, y: 0.5), strength: Double = 600, radius: Double = 250) {
        self.id = id; self.pos = pos; self.strength = strength; self.radius = radius
    }
}

package struct ParticleSystemSettings: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var name = "Particles"
    package var enabled = true
    package var blend: PBlend = .additive

    // MARK: Emitter
    package var shape: PEmitterShape = .point
    package var pos = CGPoint(x: 0.5, y: 0.5)
    /// Full width / height as fractions of the canvas.
    package var size = CGSize(width: 0.5, height: 0.5)
    package var emitterRotation: Double = 0
    package var arms: Double = 3
    package var twist: Double = 2.5
    package var gridJitter: Double = 0
    package var pathPoints: [CGPoint] = []
    package var pathClosed = false
    package var text = "IMAGECRAT"
    package var textFont = "Helvetica-Bold"
    /// Text / brightness emitters: emit from the outlines (edges) instead of the filled area.
    package var outlineOnly = false
    /// Baked emission map (gray PNG, base64) used when the live source (selection / layer) is gone.
    package var maskPNG: String? = nil
    package var densityNoise: Double = 0
    package var densityNoiseScale: Double = 300

    // MARK: Emission
    package var emission: PEmission = .rate
    package var count: Double = 300
    package var rate: Double = 100
    package var burstInterval: Double = 0
    package var burstSpread: Double = 0
    package var emitDuration: Double = 0
    package var startTime: Double = 0
    package var prewarm = true
    /// Seconds for the emission front to cross the emitter (0 = off). Used by the dispersion effect.
    package var sweep: Double = 0
    package var sweepAngle: Double = 0
    package var sweepNoise: Double = 0.3

    // MARK: Life
    package var lifeMin: Double = 2
    package var lifeMax: Double = 3
    package var immortal = false

    // MARK: Initial velocity
    package var direction: Double = 90
    package var spread: Double = 360
    package var speedMin: Double = 50
    package var speedMax: Double = 150
    package var radialSpeed: Double = 0
    package var tangentialSpeed: Double = 0
    package var normalSpeed: Double = 0
    package var inheritVelocity: Double = 0

    // MARK: Forces
    package var gravity: Double = 0
    package var wind: Double = 0
    package var gust: Double = 0
    package var drag: Double = 0
    package var turbulence: Double = 0
    package var turbulenceScale: Double = 250
    package var turbulenceSpeed: Double = 0.3
    package var noiseForce: Double = 0
    package var vortex: Double = 0
    package var vortexPull: Double = 0
    package var vortexCenter = CGPoint(x: 0.5, y: 0.5)
    package var vortexRadius: Double = 400
    package var attractors: [PAttractor] = []
    package var bounceEdges = false
    package var floorEnabled = false
    package var floorY: Double = 0.92
    package var restitution: Double = 0.5
    package var friction: Double = 0.2
    package var dieOnCollision = false
    package var collideMask = false
    package var confine = false
    package var followPath: Double = 0
    package var followSpeed: Double = 200

    // MARK: Appearance
    package var sprite: PSprite = .softDisc
    package var spritePoints: Double = 5
    package var spriteSoftness: Double = 0.6
    package var spriteAspect: Double = 1
    package var spriteText = "✦"
    package var spriteFont = "Helvetica"
    package var spriteShape = "heart"
    package var spriteImagePNG: String? = nil
    package var sizeMin: Double = 4
    package var sizeMax: Double = 10
    package var sizeBias: Double = 1
    package var sizeCurve = CurvePoints(points: [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)])
    package var sizeByDistance: Double = 0
    package var rotation: Double = 0
    package var rotationRandom: Double = 180
    package var spin: Double = 0
    package var spinRandom: Double = 0
    package var alignToVelocity = false
    package var tumble: Double = 0
    package var colorBase: PColorBase = .none
    package var gradient = ColorGradient.twoColor(.white, .white, name: "Over life")
    package var palette = ColorGradient.twoColor(.white, .white, name: "Palette")
    package var hueVariation: Double = 0
    package var brightnessVariation: Double = 0
    package var opacity: Double = 1
    package var opacityRandom: Double = 0
    package var opacityCurve = CurvePoints(points: [CGPoint(x: 0, y: 0), CGPoint(x: 0.1, y: 1), CGPoint(x: 0.75, y: 1), CGPoint(x: 1, y: 0)])
    package var twinkle: Double = 0
    package var twinkleSpeed: Double = 3

    // MARK: Trails
    package var trail: PTrail = .none
    package var trailLength: Double = 0.15
    package var trailSegments: Double = 12
    package var trailWidth: Double = 1
    package var trailGradient = false
    package var snapGrid: Double = 0

    // MARK: Depth
    package var depth: Double = 0
    package var focus: Double = 0.5
    package var dofBlur: Double = 0
    package var atmosphere: Double = 0

    // MARK: Sub-emitter (spawned when a particle dies)
    package var sub: [ParticleSystemSettings] = []

    package var maxLife: Double { immortal ? 1e9 : max(lifeMin, lifeMax) }
    package init(id: UUID = UUID(), name: String = "Particles", enabled: Bool = true, blend: PBlend = .additive, shape: PEmitterShape = .point, pos: CGPoint = CGPoint(x: 0.5, y: 0.5), size: CGSize = CGSize(width: 0.5, height: 0.5), emitterRotation: Double = 0, arms: Double = 3, twist: Double = 2.5, gridJitter: Double = 0, pathPoints: [CGPoint] = [], pathClosed: Bool = false, text: String = "IMAGECRAT", textFont: String = "Helvetica-Bold", outlineOnly: Bool = false, maskPNG: String? = nil, densityNoise: Double = 0, densityNoiseScale: Double = 300, emission: PEmission = .rate, count: Double = 300, rate: Double = 100, burstInterval: Double = 0, burstSpread: Double = 0, emitDuration: Double = 0, startTime: Double = 0, prewarm: Bool = true, sweep: Double = 0, sweepAngle: Double = 0, sweepNoise: Double = 0.3, lifeMin: Double = 2, lifeMax: Double = 3, immortal: Bool = false, direction: Double = 90, spread: Double = 360, speedMin: Double = 50, speedMax: Double = 150, radialSpeed: Double = 0, tangentialSpeed: Double = 0, normalSpeed: Double = 0, inheritVelocity: Double = 0, gravity: Double = 0, wind: Double = 0, gust: Double = 0, drag: Double = 0, turbulence: Double = 0, turbulenceScale: Double = 250, turbulenceSpeed: Double = 0.3, noiseForce: Double = 0, vortex: Double = 0, vortexPull: Double = 0, vortexCenter: CGPoint = CGPoint(x: 0.5, y: 0.5), vortexRadius: Double = 400, attractors: [PAttractor] = [], bounceEdges: Bool = false, floorEnabled: Bool = false, floorY: Double = 0.92, restitution: Double = 0.5, friction: Double = 0.2, dieOnCollision: Bool = false, collideMask: Bool = false, confine: Bool = false, followPath: Double = 0, followSpeed: Double = 200, sprite: PSprite = .softDisc, spritePoints: Double = 5, spriteSoftness: Double = 0.6, spriteAspect: Double = 1, spriteText: String = "✦", spriteFont: String = "Helvetica", spriteShape: String = "heart", spriteImagePNG: String? = nil, sizeMin: Double = 4, sizeMax: Double = 10, sizeBias: Double = 1, sizeCurve: CurvePoints = CurvePoints(points: [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]), sizeByDistance: Double = 0, rotation: Double = 0, rotationRandom: Double = 180, spin: Double = 0, spinRandom: Double = 0, alignToVelocity: Bool = false, tumble: Double = 0, colorBase: PColorBase = .none, gradient: ColorGradient = ColorGradient.twoColor(.white, .white, name: "Over life"), palette: ColorGradient = ColorGradient.twoColor(.white, .white, name: "Palette"), hueVariation: Double = 0, brightnessVariation: Double = 0, opacity: Double = 1, opacityRandom: Double = 0, opacityCurve: CurvePoints = CurvePoints(points: [CGPoint(x: 0, y: 0), CGPoint(x: 0.1, y: 1), CGPoint(x: 0.75, y: 1), CGPoint(x: 1, y: 0)]), twinkle: Double = 0, twinkleSpeed: Double = 3, trail: PTrail = .none, trailLength: Double = 0.15, trailSegments: Double = 12, trailWidth: Double = 1, trailGradient: Bool = false, snapGrid: Double = 0, depth: Double = 0, focus: Double = 0.5, dofBlur: Double = 0, atmosphere: Double = 0, sub: [ParticleSystemSettings] = []) {
        self.id = id; self.name = name; self.enabled = enabled; self.blend = blend; self.shape = shape; self.pos = pos; self.size = size; self.emitterRotation = emitterRotation; self.arms = arms; self.twist = twist; self.gridJitter = gridJitter; self.pathPoints = pathPoints; self.pathClosed = pathClosed; self.text = text; self.textFont = textFont; self.outlineOnly = outlineOnly; self.maskPNG = maskPNG; self.densityNoise = densityNoise; self.densityNoiseScale = densityNoiseScale; self.emission = emission; self.count = count; self.rate = rate; self.burstInterval = burstInterval; self.burstSpread = burstSpread; self.emitDuration = emitDuration; self.startTime = startTime; self.prewarm = prewarm; self.sweep = sweep; self.sweepAngle = sweepAngle; self.sweepNoise = sweepNoise; self.lifeMin = lifeMin; self.lifeMax = lifeMax; self.immortal = immortal; self.direction = direction; self.spread = spread; self.speedMin = speedMin; self.speedMax = speedMax; self.radialSpeed = radialSpeed; self.tangentialSpeed = tangentialSpeed; self.normalSpeed = normalSpeed; self.inheritVelocity = inheritVelocity; self.gravity = gravity; self.wind = wind; self.gust = gust; self.drag = drag; self.turbulence = turbulence; self.turbulenceScale = turbulenceScale; self.turbulenceSpeed = turbulenceSpeed; self.noiseForce = noiseForce; self.vortex = vortex; self.vortexPull = vortexPull; self.vortexCenter = vortexCenter; self.vortexRadius = vortexRadius; self.attractors = attractors; self.bounceEdges = bounceEdges; self.floorEnabled = floorEnabled; self.floorY = floorY; self.restitution = restitution; self.friction = friction; self.dieOnCollision = dieOnCollision; self.collideMask = collideMask; self.confine = confine; self.followPath = followPath; self.followSpeed = followSpeed; self.sprite = sprite; self.spritePoints = spritePoints; self.spriteSoftness = spriteSoftness; self.spriteAspect = spriteAspect; self.spriteText = spriteText; self.spriteFont = spriteFont; self.spriteShape = spriteShape; self.spriteImagePNG = spriteImagePNG; self.sizeMin = sizeMin; self.sizeMax = sizeMax; self.sizeBias = sizeBias; self.sizeCurve = sizeCurve; self.sizeByDistance = sizeByDistance; self.rotation = rotation; self.rotationRandom = rotationRandom; self.spin = spin; self.spinRandom = spinRandom; self.alignToVelocity = alignToVelocity; self.tumble = tumble; self.colorBase = colorBase; self.gradient = gradient; self.palette = palette; self.hueVariation = hueVariation; self.brightnessVariation = brightnessVariation; self.opacity = opacity; self.opacityRandom = opacityRandom; self.opacityCurve = opacityCurve; self.twinkle = twinkle; self.twinkleSpeed = twinkleSpeed; self.trail = trail; self.trailLength = trailLength; self.trailSegments = trailSegments; self.trailWidth = trailWidth; self.trailGradient = trailGradient; self.snapGrid = snapGrid; self.depth = depth; self.focus = focus; self.dofBlur = dofBlur; self.atmosphere = atmosphere; self.sub = sub
    }
}

package struct ParticleEffect: Codable, Equatable {
    package var version = 1
    package var name = "Particles"
    package var category = ""
    package var systems: [ParticleSystemSettings] = [ParticleSystemSettings()]
    package var seed: Int = 1
    /// The frozen moment for a still.
    package var time: Double = 2
    /// Scrubber range and animation length.
    package var duration: Double = 4
    package var loop = false
    /// nil = automatic (from the systems' blending).
    package var layerBlend: BlendMode? = nil
    package var quality: PQuality = .standard
    package var output: POutput = .newLayer
    package var clipToSelection = true
    package var behindSubject = false
    package var depthAware = false
    /// Dispersion: hide the dissolved part of the source layer with a layer mask.
    package var maskSourceLayer = false
    package var frames: Double = 24
    package var fps: Double = 12
    /// Layer the effect was sampled from (dispersion colours / alpha emitters), kept for re-editing.
    package var sourceLayerID: UUID? = nil
    /// Baked colours of the source layer (PNG, base64) so smart objects stay re-editable without it.
    package var imagePNG: String? = nil
    /// True when applying the effect created the source layer's mask (so re-editing replaces it).
    package var maskCreated = false
    /// First frame time of a (non-looping) animation.
    package var animStart: Double = 0
    package init(version: Int = 1, name: String = "Particles", category: String = "", systems: [ParticleSystemSettings] = [ParticleSystemSettings()], seed: Int = 1, time: Double = 2, duration: Double = 4, loop: Bool = false, layerBlend: BlendMode? = nil, quality: PQuality = .standard, output: POutput = .newLayer, clipToSelection: Bool = true, behindSubject: Bool = false, depthAware: Bool = false, maskSourceLayer: Bool = false, frames: Double = 24, fps: Double = 12, sourceLayerID: UUID? = nil, imagePNG: String? = nil, maskCreated: Bool = false, animStart: Double = 0) {
        self.version = version; self.name = name; self.category = category; self.systems = systems; self.seed = seed; self.time = time; self.duration = duration; self.loop = loop; self.layerBlend = layerBlend; self.quality = quality; self.output = output; self.clipToSelection = clipToSelection; self.behindSubject = behindSubject; self.depthAware = depthAware; self.maskSourceLayer = maskSourceLayer; self.frames = frames; self.fps = fps; self.sourceLayerID = sourceLayerID; self.imagePNG = imagePNG; self.maskCreated = maskCreated; self.animStart = animStart
    }
}

// MARK: - Tolerant JSON coding

package enum ParticleCoding {
    package static func encode(_ e: ParticleEffect) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(e)) ?? Data()
    }

    package static func json(_ e: ParticleEffect) -> String { String(data: encode(e), encoding: .utf8) ?? "{}" }

    /// Decodes settings written by any version: missing keys take the default value, unknown keys are ignored,
    /// unknown enum cases fall back to the first case.
    package static func decode(_ data: Data) -> ParticleEffect? {
        guard let obj = try? JSONSerialization.jsonObject(with: data), obj is [String: Any] else { return nil }
        let enc = JSONEncoder()
        guard let defEffect = try? JSONSerialization.jsonObject(with: enc.encode(ParticleEffect())),
              let defSystem = try? JSONSerialization.jsonObject(with: enc.encode(ParticleSystemSettings())),
              let defAttractor = try? JSONSerialization.jsonObject(with: enc.encode(PAttractor())) else { return nil }
        func merge(_ def: Any?, _ val: Any, key: String) -> Any {
            if let arr = val as? [Any] {
                switch key {
                case "systems", "sub":
                    return arr.map { el -> Any in
                        var m = merge(defSystem, el, key: "")
                        if var d = m as? [String: Any], (el as? [String: Any])?["id"] == nil { d["id"] = UUID().uuidString; m = d }
                        return m
                    }
                case "attractors":
                    return arr.map { el -> Any in
                        var m = merge(defAttractor, el, key: "")
                        if var d = m as? [String: Any], (el as? [String: Any])?["id"] == nil { d["id"] = UUID().uuidString; m = d }
                        return m
                    }
                case "stops":
                    return arr.map { el -> Any in
                        guard var d = el as? [String: Any] else { return el }
                        if d["id"] == nil { d["id"] = UUID().uuidString }
                        if d["location"] == nil { d["location"] = 0 }
                        if d["color"] == nil { d["color"] = ["r": 1, "g": 1, "b": 1, "a": 1] }
                        return d
                    }
                default:
                    return arr
                }
            }
            if let v = val as? [String: Any] {
                guard let d = def as? [String: Any] else { return v }
                var out = d
                for (k, x) in v {
                    if x is NSNull, d[k] != nil, !(d[k] is NSNull) { continue }
                    out[k] = merge(d[k], x, key: k)
                }
                return out
            }
            // type mismatch against the default (e.g. a string where a number is expected): keep the default
            if let d = def, !(d is NSNull) {
                if d is [String: Any] || d is [Any] { return d }
                if (d is NSNumber) != (val is NSNumber) && !(val is NSNull) { return d }
            }
            return val
        }
        let merged = merge(defEffect, obj, key: "")
        guard let md = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(ParticleEffect.self, from: md)
    }

    package static func decode(json: String) -> ParticleEffect? { decode(Data(json.utf8)) }
}

// MARK: - Small helpers used by presets

extension ColorGradient {
    /// Gradient from hex stops spread evenly (or "hex@location" / 8-digit hex with alpha).
    package static func hex(_ stops: String..., name: String = "Particles") -> ColorGradient {
        var out: [GradientStop] = []
        for (i, s) in stops.enumerated() {
            let parts = s.split(separator: "@")
            let loc = parts.count > 1 ? Double(parts[1]) ?? 0 : (stops.count > 1 ? Double(i) / Double(stops.count - 1) : 0)
            out.append(GradientStop(location: loc, color: RGBA(hex: String(parts[0])) ?? .white))
        }
        return ColorGradient(name: name, stops: out)
    }
}

extension CurvePoints {
    package static func pts(_ p: (Double, Double)...) -> CurvePoints { CurvePoints(points: p.map { CGPoint(x: $0.0, y: $0.1) }) }
    package static let flat = CurvePoints.pts((0, 1), (1, 1))
    package static let fadeOut = CurvePoints.pts((0, 1), (1, 0))
    package static let fadeInOut = CurvePoints.pts((0, 0), (0.15, 1), (0.7, 1), (1, 0))
    package static let quickInSlowOut = CurvePoints.pts((0, 0), (0.05, 1), (0.4, 0.7), (1, 0))
    package static let grow = CurvePoints.pts((0, 0.3), (1, 1))
    package static let shrink = CurvePoints.pts((0, 1), (1, 0.15))
}
