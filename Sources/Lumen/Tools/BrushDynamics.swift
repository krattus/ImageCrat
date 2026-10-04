import Foundation
import CoreGraphics
import ImageCratCore

// MARK: - Brush dynamics model (Photoshop "Brush Settings" panel)

/// What drives a dynamic parameter (Photoshop "Control" popups).
enum BrushControl: String, CaseIterable, Identifiable, Codable {
    case off, fade, pressure, tilt, wheel, rotation, direction, initialDirection

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .fade: return "Fade"
        case .pressure: return "Pen Pressure"
        case .tilt: return "Pen Tilt"
        case .wheel: return "Stylus Wheel"
        case .rotation: return "Rotation"
        case .direction: return "Direction"
        case .initialDirection: return "Initial Direction"
        }
    }

    /// Controls offered for size / roundness / scatter / count / depth.
    static let shapeControls: [BrushControl] = [.off, .fade, .pressure, .tilt, .wheel, .rotation]
    /// Controls offered for the angle.
    static let angleControls: [BrushControl] = [.off, .fade, .pressure, .tilt, .wheel, .rotation, .initialDirection, .direction]
    /// Controls offered for opacity / flow / foreground-background.
    static let transferControls: [BrushControl] = [.off, .fade, .pressure, .tilt, .wheel]
}

struct ControlSetting: Equatable, Codable {
    var source: BrushControl = .off
    /// Number of dabs over which a "Fade" control goes from 100% to its minimum.
    var fadeSteps: Double = 25

    init(source: BrushControl = .off, fadeSteps: Double = 25) { self.source = source; self.fadeSteps = fadeSteps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = (try? c.decodeIfPresent(BrushControl.self, forKey: .source)) ?? .off
        fadeSteps = (try? c.decodeIfPresent(Double.self, forKey: .fadeSteps)) ?? 25
    }
}

/// How the texture / dual tip is combined with the primary tip.
enum BrushMaskMode: String, CaseIterable, Identifiable, Codable {
    case multiply, subtract, darken, overlay, colorBurn, linearBurn, hardMix, height, linearHeight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .multiply: return "Multiply"
        case .subtract: return "Subtract"
        case .darken: return "Darken"
        case .overlay: return "Overlay"
        case .colorBurn: return "Color Burn"
        case .linearBurn: return "Linear Burn"
        case .hardMix: return "Hard Mix"
        case .height: return "Height"
        case .linearHeight: return "Linear Height"
        }
    }

    static let textureModes: [BrushMaskMode] = allCases
    static let dualModes: [BrushMaskMode] = [.multiply, .darken, .overlay, .colorBurn, .linearBurn, .hardMix]
}

/// All Brush Settings panel options beyond the basic tip. Stored in `BrushSettings.dynamics`.
///
/// The legacy fields of `BrushSettings` supply some of the values:
/// `sizeJitter` (Shape Dynamics › Size Jitter), `scatter` (Scattering › Scatter, fraction of the diameter)
/// and `opacityJitter` (Transfer › Opacity Jitter). They only take effect while their section is enabled.
struct BrushDynamics: Equatable, Codable, DefaultInitializable {
    // Brush Tip Shape
    var flipX = false
    var flipY = false

    // Shape Dynamics
    var shapeEnabled = false
    var sizeControl = ControlSetting()
    var minDiameter: Double = 0          // 0...1
    var angleJitter: Double = 0          // 0...1 (1 = ±180°)
    var angleControl = ControlSetting()
    var roundnessJitter: Double = 0      // 0...1
    var roundnessControl = ControlSetting()
    var minRoundness: Double = 0.25      // 0...1
    var flipXJitter = false
    var flipYJitter = false

    // Scattering
    var scatterEnabled = false
    var scatterBothAxes = true
    var scatterControl = ControlSetting()
    var count: Double = 1                // 1...16
    var countJitter: Double = 0          // 0...1
    var countControl = ControlSetting()

    // Texture
    var textureEnabled = false
    var texturePatternID = "canvas"
    var textureScale: Double = 1         // 0.01...10
    var textureBrightness: Double = 0    // -150...150
    var textureContrast: Double = 0      // -50...100
    var textureInvert = false
    var textureEachTip = true
    var textureMode: BrushMaskMode = .multiply
    var textureDepth: Double = 1         // 0...1
    var textureMinDepth: Double = 0      // 0...1
    var textureDepthJitter: Double = 0   // 0...1
    var textureDepthControl = ControlSetting()

    // Dual Brush
    var dualEnabled = false
    var dualTipID = "chalk"
    var dualSize: Double = 25            // px
    var dualHardness: Double = 1
    var dualSpacing: Double = 0.25       // fraction of the dual diameter
    var dualScatter: Double = 0          // fraction of the dual diameter
    var dualBothAxes = false
    var dualCount: Double = 1            // 1...16
    var dualMode: BrushMaskMode = .multiply

    // Color Dynamics
    var colorEnabled = false
    var colorPerTip = true
    var fgBgJitter: Double = 0           // 0...1
    var fgBgControl = ControlSetting()
    var hueJitter: Double = 0            // 0...1
    var saturationJitter: Double = 0     // 0...1
    var brightnessJitter: Double = 0     // 0...1
    var purity: Double = 0               // -1...1

    // Transfer
    var transferEnabled = false
    var opacityControl = ControlSetting()
    var minOpacity: Double = 0
    var flowJitter: Double = 0
    var flowControl = ControlSetting()
    var minFlow: Double = 0

    // Other options
    var noise = false
    var wetEdges = false


    init() {}

    /// Tolerant decoding: missing or unknown values keep their defaults (older saved presets stay loadable).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var v = BrushDynamics()
        func d<T: Decodable>(_ kp: WritableKeyPath<BrushDynamics, T>, _ k: CodingKeys) {
            if let x = try? c.decodeIfPresent(T.self, forKey: k) { v[keyPath: kp] = x }
        }
        d(\.flipX, .flipX)
        d(\.flipY, .flipY)
        d(\.shapeEnabled, .shapeEnabled)
        d(\.sizeControl, .sizeControl)
        d(\.minDiameter, .minDiameter)
        d(\.angleJitter, .angleJitter)
        d(\.angleControl, .angleControl)
        d(\.roundnessJitter, .roundnessJitter)
        d(\.roundnessControl, .roundnessControl)
        d(\.minRoundness, .minRoundness)
        d(\.flipXJitter, .flipXJitter)
        d(\.flipYJitter, .flipYJitter)
        d(\.scatterEnabled, .scatterEnabled)
        d(\.scatterBothAxes, .scatterBothAxes)
        d(\.scatterControl, .scatterControl)
        d(\.count, .count)
        d(\.countJitter, .countJitter)
        d(\.countControl, .countControl)
        d(\.textureEnabled, .textureEnabled)
        d(\.texturePatternID, .texturePatternID)
        d(\.textureScale, .textureScale)
        d(\.textureBrightness, .textureBrightness)
        d(\.textureContrast, .textureContrast)
        d(\.textureInvert, .textureInvert)
        d(\.textureEachTip, .textureEachTip)
        d(\.textureMode, .textureMode)
        d(\.textureDepth, .textureDepth)
        d(\.textureMinDepth, .textureMinDepth)
        d(\.textureDepthJitter, .textureDepthJitter)
        d(\.textureDepthControl, .textureDepthControl)
        d(\.dualEnabled, .dualEnabled)
        d(\.dualTipID, .dualTipID)
        d(\.dualSize, .dualSize)
        d(\.dualHardness, .dualHardness)
        d(\.dualSpacing, .dualSpacing)
        d(\.dualScatter, .dualScatter)
        d(\.dualBothAxes, .dualBothAxes)
        d(\.dualCount, .dualCount)
        d(\.dualMode, .dualMode)
        d(\.colorEnabled, .colorEnabled)
        d(\.colorPerTip, .colorPerTip)
        d(\.fgBgJitter, .fgBgJitter)
        d(\.fgBgControl, .fgBgControl)
        d(\.hueJitter, .hueJitter)
        d(\.saturationJitter, .saturationJitter)
        d(\.brightnessJitter, .brightnessJitter)
        d(\.purity, .purity)
        d(\.transferEnabled, .transferEnabled)
        d(\.opacityControl, .opacityControl)
        d(\.minOpacity, .minOpacity)
        d(\.flowJitter, .flowJitter)
        d(\.flowControl, .flowControl)
        d(\.minFlow, .minFlow)
        d(\.noise, .noise)
        d(\.wetEdges, .wetEdges)
        self = v
    }

    /// Options that are applied to the accumulated stroke rather than to single dabs.
    var needsStrokePass: Bool { dualEnabled || (textureEnabled && !textureEachTip) || wetEdges || noise }
}

// MARK: - Codable helpers

protocol DefaultInitializable { init() }

/// Encodes transparently; a missing key decodes as `T()` (lets `BrushSettings` gain `dynamics` without breaking
/// synthesized decoding of settings saved before the field existed).
@propertyWrapper
struct DefaultIfMissing<T: Codable & Equatable & DefaultInitializable>: Codable, Equatable {
    var wrappedValue: T
    init(wrappedValue: T) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws { wrappedValue = try T(from: decoder) }
    func encode(to encoder: Encoder) throws { try wrappedValue.encode(to: encoder) }
}

extension KeyedDecodingContainer {
    func decode<T>(_ type: DefaultIfMissing<T>.Type, forKey key: Key) throws -> DefaultIfMissing<T> {
        (try? decodeIfPresent(type, forKey: key)) ?? DefaultIfMissing(wrappedValue: T())
    }
}

/// One pen sample (from a mouse / tablet event or synthesized).
struct PenSample {
    var p: CGPoint
    var pressure: Double = 1
    /// Tablet tilt, each axis -1...1 (0,0 = upright).
    var tilt: CGPoint = .zero
    /// Barrel rotation in degrees.
    var rotation: Double = 0
    /// Stylus (airbrush) wheel, 0...1.
    var wheel: Double = 1

    func lerp(_ o: PenSample, _ t: Double) -> PenSample {
        PenSample(p: p.lerp(o.p, CGFloat(t)),
                  pressure: pressure + (o.pressure - pressure) * t,
                  tilt: tilt.lerp(o.tilt, CGFloat(t)),
                  rotation: rotation + (o.rotation - rotation) * t,
                  wheel: wheel + (o.wheel - wheel) * t)
    }

    var tiltMagnitude: Double { min(1, Double(tilt.length)) }
    /// Direction the pen leans, in degrees counter-clockwise on screen (NSEvent tilt y is positive towards the bottom).
    var tiltAngle: Double { tilt == .zero ? 0 : atan2(-Double(tilt.y), Double(tilt.x)) * 180 / .pi }
}

extension PenSample {
    init(_ e: ToolEvent) {
        self.init(p: e.doc, pressure: e.pressure, tilt: e.tilt, rotation: e.rotation,
                  wheel: e.isTablet ? min(1, abs(e.tangentialPressure)) : 1)
    }
}

// MARK: - Presets

extension BrushPreset {
    /// Applies the preset to brush settings (keeps opacity, flow, mode, smoothing).
    func apply(to s: inout BrushSettings) {
        s.size = size; s.hardness = hardness; s.spacing = spacing
        s.roundness = roundness; s.angle = angle; s.scatter = scatter
        s.sizeJitter = sizeJitter; s.tipID = tipID
        if let d = dynamics {
            s.dynamics = d
        } else {
            var d = BrushDynamics()
            d.shapeEnabled = sizeJitter > 0
            d.scatterEnabled = scatter > 0
            // Legacy procedural tips looked best with a little random rotation.
            if tipID == "grass" || tipID == "star" { d.shapeEnabled = true; d.angleJitter = 60.0 / 360 }
            s.dynamics = d
        }
    }

    /// Built-in presets that showcase the dynamics.
    static let dynamicPresets: [BrushPreset] = {
        var out: [BrushPreset] = []
        var wet = BrushDynamics(); wet.wetEdges = true
        var p = BrushPreset(id: "dyn-watercolor", name: "Watercolor Wet", size: 60, hardness: 0.6, spacing: 0.08)
        p.dynamics = wet; out.append(p)

        var tex = BrushDynamics(); tex.textureEnabled = true; tex.texturePatternID = "canvas"; tex.textureScale = 1.5; tex.textureDepth = 0.9; tex.textureMode = .height
        tex.transferEnabled = true; tex.opacityControl.source = .pressure
        p = BrushPreset(id: "dyn-canvaschalk", name: "Canvas Chalk", size: 45, hardness: 0.9, spacing: 0.1, tipID: "chalk")
        p.dynamics = tex; out.append(p)

        var leaves = BrushDynamics(); leaves.shapeEnabled = true; leaves.angleJitter = 1; leaves.roundnessJitter = 0.5; leaves.minRoundness = 0.3
        leaves.scatterEnabled = true; leaves.count = 2; leaves.countJitter = 0.5
        leaves.colorEnabled = true; leaves.fgBgJitter = 1; leaves.hueJitter = 0.08; leaves.brightnessJitter = 0.2
        p = BrushPreset(id: "dyn-leaves", name: "Scattered Leaves", size: 50, hardness: 1, spacing: 0.35, scatter: 1.5, sizeJitter: 0.6, tipID: "star")
        p.dynamics = leaves; out.append(p)

        var dual = BrushDynamics(); dual.dualEnabled = true; dual.dualTipID = "charcoal"; dual.dualSize = 30; dual.dualScatter = 0.8; dual.dualBothAxes = true; dual.dualCount = 2
        p = BrushPreset(id: "dyn-dualspatter", name: "Dual Spatter", size: 55, hardness: 0.8, spacing: 0.1)
        p.dynamics = dual; out.append(p)

        var ink = BrushDynamics(); ink.shapeEnabled = true; ink.sizeControl.source = .pressure; ink.minDiameter = 0.15
        ink.angleControl.source = .direction
        p = BrushPreset(id: "dyn-ink", name: "Calligraphy Ink", size: 30, hardness: 1, spacing: 0.04, roundness: 0.3)
        p.dynamics = ink; out.append(p)

        var noisy = BrushDynamics(); noisy.noise = true
        p = BrushPreset(id: "dyn-noisy", name: "Soft Noise", size: 80, hardness: 0, spacing: 0.1)
        p.dynamics = noisy; out.append(p)
        return out
    }()
}
