import Foundation

// MARK: - Portable brush preset model
//
// The format-neutral description of one brush preset: everything Photoshop's Brush Settings panel holds (tip shape,
// shape dynamics, scattering, texture, dual brush, colour dynamics, transfer, brush pose, noise, wet edges, build-up,
// smoothing, protect texture) plus the tool settings a preset may carry. Importers (ABR, TPL, GBR/GIH, Procreate,
// Krita) produce it, the ABR writer and ImageCrat's own brush-set archive consume it, and the brush library stores it.
// The app maps it onto its `BrushSettings` (Sources/Lumen/Tools/BrushPresetMapping.swift).
//
// Units: fractions are 0...1 (100% = 1), sizes in pixels, angles in degrees, spacing as a fraction of the diameter.
// Decoding is tolerant: a missing or unreadable key keeps its default, so libraries written by older or newer builds
// stay loadable.

/// What drives a dynamic parameter (Photoshop's "Control" popups; raw values match the app's `BrushControl`).
package enum BrushControlSource: String, Codable, CaseIterable {
    case off, fade, pressure, tilt, wheel, rotation, direction, initialDirection

    /// Photoshop's `bVTy` codes in brush descriptors.
    package init(photoshopCode c: Int) {
        switch c {
        case 1: self = .fade
        case 2: self = .pressure
        case 3: self = .tilt
        case 4: self = .wheel
        case 5: self = .rotation
        case 6: self = .initialDirection
        case 7: self = .direction
        default: self = .off
        }
    }
    package var photoshopCode: Int {
        switch self {
        case .off: return 0
        case .fade: return 1
        case .pressure: return 2
        case .tilt: return 3
        case .wheel: return 4
        case .rotation: return 5
        case .initialDirection: return 6
        case .direction: return 7
        }
    }
}

package struct BrushControlParam: Codable, Equatable {
    package var source: BrushControlSource = .off
    package var fadeSteps: Double = 25
    package init(source: BrushControlSource = .off, fadeSteps: Double = 25) { self.source = source; self.fadeSteps = fadeSteps }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = (try? c.decodeIfPresent(BrushControlSource.self, forKey: .source)) ?? .off
        fadeSteps = (try? c.decodeIfPresent(Double.self, forKey: .fadeSteps)) ?? 25
    }
}

/// How a texture or dual tip combines with the primary tip (raw values match the app's `BrushMaskMode`).
package enum BrushMaskBlend: String, Codable, CaseIterable {
    case multiply, subtract, darken, overlay, colorBurn, linearBurn, hardMix, height, linearHeight

    /// Photoshop `BlnM` enumeration values used by brush textures and dual brushes.
    package init?(photoshopKey k: String) {
        switch k {
        case "Mltp": self = .multiply
        case "Sbtr": self = .subtract
        case "Drkn": self = .darken
        case "Ovrl": self = .overlay
        case "CBrn": self = .colorBurn
        case "linearBurn": self = .linearBurn
        case "hardMix": self = .hardMix
        case "Hght", "height": self = .height
        case "linearHeight": self = .linearHeight
        default: return nil
        }
    }
    package var photoshopKey: String {
        switch self {
        case .multiply: return "Mltp"
        case .subtract: return "Sbtr"
        case .darken: return "Drkn"
        case .overlay: return "Ovrl"
        case .colorBurn: return "CBrn"
        case .linearBurn: return "linearBurn"
        case .hardMix: return "hardMix"
        case .height: return "Hght"
        case .linearHeight: return "linearHeight"
        }
    }
}

/// How an animated (multi-frame) tip picks the frame for each dab (GIMP image pipes).
package enum BrushFrameSelection: String, Codable, CaseIterable {
    case incremental, random, angular, pressure, velocity
}

package struct BrushParams: Codable, Equatable {
    // Brush Tip Shape
    package var size: Double = 30
    package var hardness: Double = 0.8
    package var spacing: Double = 0.12
    package var angle: Double = 0
    package var roundness: Double = 1
    package var flipX = false
    package var flipY = false

    // Tool settings a preset may include
    package var opacity: Double = 1
    package var flow: Double = 1
    package var smoothing: Double = 0.1
    package var blendMode: String = "normal"
    package var pressureSize = true
    package var pressureOpacity = false
    package var airbrush = false

    // Shape Dynamics
    package var shapeEnabled = false
    package var sizeJitter: Double = 0
    package var sizeControl = BrushControlParam()
    package var minDiameter: Double = 0
    package var tiltScale: Double = 0
    package var angleJitter: Double = 0
    package var angleControl = BrushControlParam()
    package var roundnessJitter: Double = 0
    package var roundnessControl = BrushControlParam()
    package var minRoundness: Double = 0.25
    package var flipXJitter = false
    package var flipYJitter = false
    package var brushProjection = false

    // Scattering
    package var scatterEnabled = false
    package var scatter: Double = 0            // fraction of the diameter
    package var scatterBothAxes = true
    package var scatterControl = BrushControlParam()
    package var count: Double = 1
    package var countJitter: Double = 0
    package var countControl = BrushControlParam()

    // Texture
    package var textureEnabled = false
    package var texturePatternID = "canvas"
    package var texturePatternName = ""
    package var textureScale: Double = 1
    package var textureBrightness: Double = 0
    package var textureContrast: Double = 0
    package var textureInvert = false
    package var textureEachTip = true
    package var textureMode: BrushMaskBlend = .multiply
    package var textureDepth: Double = 1
    package var textureMinDepth: Double = 0
    package var textureDepthJitter: Double = 0
    package var textureDepthControl = BrushControlParam()
    package var protectTexture = false

    // Dual Brush
    package var dualEnabled = false
    /// "round", a procedural tip id, or (inside an import / archive) the key of one of the set's tips.
    package var dualTipID = "chalk"
    package var dualSize: Double = 25
    package var dualHardness: Double = 1
    package var dualSpacing: Double = 0.25
    package var dualScatter: Double = 0
    package var dualBothAxes = false
    package var dualCount: Double = 1
    package var dualMode: BrushMaskBlend = .multiply
    package var dualFlip = false

    // Color Dynamics
    package var colorEnabled = false
    package var colorPerTip = true
    package var fgBgJitter: Double = 0
    package var fgBgControl = BrushControlParam()
    package var hueJitter: Double = 0
    package var saturationJitter: Double = 0
    package var brightnessJitter: Double = 0
    package var purity: Double = 0
    /// Scales the hue / saturation / brightness jitter (ImageCrat; Photoshop has no control for them).
    package var colorJitterControl = BrushControlParam()

    // Transfer
    package var transferEnabled = false
    package var opacityJitter: Double = 0
    package var opacityControl = BrushControlParam()
    package var minOpacity: Double = 0
    package var flowJitter: Double = 0
    package var flowControl = BrushControlParam()
    package var minFlow: Double = 0

    // Brush Pose (stylus values used when the input device doesn't provide them, or always when overridden)
    package var poseEnabled = false
    package var poseTiltX: Double = 0          // -1...1
    package var poseTiltY: Double = 0          // -1...1
    package var poseRotation: Double = 0       // degrees
    package var posePressure: Double = 1       // 0...1
    package var poseOverrideTilt = false
    package var poseOverrideRotation = false
    package var poseOverridePressure = false

    // Other options
    package var noise = false
    package var wetEdges = false

    package init() {}

    /// Convenience for the common tip-shape fields.
    package init(size: Double, hardness: Double = 1, spacing: Double = 0.25, angle: Double = 0, roundness: Double = 1) {
        self.size = size; self.hardness = hardness; self.spacing = spacing; self.angle = angle; self.roundness = roundness
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var v = BrushParams()
        func d<T: Decodable>(_ kp: WritableKeyPath<BrushParams, T>, _ k: CodingKeys) {
            if let x = try? c.decodeIfPresent(T.self, forKey: k) { v[keyPath: kp] = x }
        }
        d(\.size, .size); d(\.hardness, .hardness); d(\.spacing, .spacing); d(\.angle, .angle); d(\.roundness, .roundness)
        d(\.flipX, .flipX); d(\.flipY, .flipY)
        d(\.opacity, .opacity); d(\.flow, .flow); d(\.smoothing, .smoothing); d(\.blendMode, .blendMode)
        d(\.pressureSize, .pressureSize); d(\.pressureOpacity, .pressureOpacity); d(\.airbrush, .airbrush)
        d(\.shapeEnabled, .shapeEnabled); d(\.sizeJitter, .sizeJitter); d(\.sizeControl, .sizeControl); d(\.minDiameter, .minDiameter)
        d(\.tiltScale, .tiltScale); d(\.angleJitter, .angleJitter); d(\.angleControl, .angleControl)
        d(\.roundnessJitter, .roundnessJitter); d(\.roundnessControl, .roundnessControl); d(\.minRoundness, .minRoundness)
        d(\.flipXJitter, .flipXJitter); d(\.flipYJitter, .flipYJitter); d(\.brushProjection, .brushProjection)
        d(\.scatterEnabled, .scatterEnabled); d(\.scatter, .scatter); d(\.scatterBothAxes, .scatterBothAxes)
        d(\.scatterControl, .scatterControl); d(\.count, .count); d(\.countJitter, .countJitter); d(\.countControl, .countControl)
        d(\.textureEnabled, .textureEnabled); d(\.texturePatternID, .texturePatternID); d(\.texturePatternName, .texturePatternName)
        d(\.textureScale, .textureScale); d(\.textureBrightness, .textureBrightness); d(\.textureContrast, .textureContrast)
        d(\.textureInvert, .textureInvert); d(\.textureEachTip, .textureEachTip); d(\.textureMode, .textureMode)
        d(\.textureDepth, .textureDepth); d(\.textureMinDepth, .textureMinDepth); d(\.textureDepthJitter, .textureDepthJitter)
        d(\.textureDepthControl, .textureDepthControl); d(\.protectTexture, .protectTexture)
        d(\.dualEnabled, .dualEnabled); d(\.dualTipID, .dualTipID); d(\.dualSize, .dualSize); d(\.dualHardness, .dualHardness)
        d(\.dualSpacing, .dualSpacing); d(\.dualScatter, .dualScatter); d(\.dualBothAxes, .dualBothAxes); d(\.dualCount, .dualCount)
        d(\.dualMode, .dualMode); d(\.dualFlip, .dualFlip)
        d(\.colorEnabled, .colorEnabled); d(\.colorPerTip, .colorPerTip); d(\.fgBgJitter, .fgBgJitter); d(\.fgBgControl, .fgBgControl)
        d(\.hueJitter, .hueJitter); d(\.saturationJitter, .saturationJitter); d(\.brightnessJitter, .brightnessJitter); d(\.purity, .purity)
        d(\.colorJitterControl, .colorJitterControl)
        d(\.transferEnabled, .transferEnabled); d(\.opacityJitter, .opacityJitter); d(\.opacityControl, .opacityControl)
        d(\.minOpacity, .minOpacity); d(\.flowJitter, .flowJitter); d(\.flowControl, .flowControl); d(\.minFlow, .minFlow)
        d(\.poseEnabled, .poseEnabled); d(\.poseTiltX, .poseTiltX); d(\.poseTiltY, .poseTiltY); d(\.poseRotation, .poseRotation)
        d(\.posePressure, .posePressure); d(\.poseOverrideTilt, .poseOverrideTilt); d(\.poseOverrideRotation, .poseOverrideRotation)
        d(\.poseOverridePressure, .poseOverridePressure)
        d(\.noise, .noise); d(\.wetEdges, .wetEdges)
        self = v
    }

    /// Clamps every value into its valid range and replaces non-finite numbers (imported files can hold anything).
    package mutating func sanitize() {
        func f(_ v: inout Double, _ lo: Double, _ hi: Double, _ def: Double) { v = v.isFinite ? min(hi, max(lo, v)) : def }
        f(&size, 1, 5000, 30); f(&hardness, 0, 1, 0.8); f(&spacing, 0.01, 10, 0.25); f(&angle, -360, 360, 0); f(&roundness, 0.01, 1, 1)
        f(&opacity, 0, 1, 1); f(&flow, 0.01, 1, 1); f(&smoothing, 0, 0.95, 0.1)
        f(&sizeJitter, 0, 1, 0); f(&minDiameter, 0, 1, 0); f(&tiltScale, 0, 2, 0); f(&angleJitter, 0, 1, 0)
        f(&roundnessJitter, 0, 1, 0); f(&minRoundness, 0.01, 1, 0.25)
        f(&scatter, 0, 10, 0); f(&count, 1, 16, 1); f(&countJitter, 0, 1, 0)
        f(&textureScale, 0.01, 10, 1); f(&textureBrightness, -150, 150, 0); f(&textureContrast, -50, 100, 0)
        f(&textureDepth, 0, 1, 1); f(&textureMinDepth, 0, 1, 0); f(&textureDepthJitter, 0, 1, 0)
        f(&dualSize, 1, 5000, 25); f(&dualHardness, 0, 1, 1); f(&dualSpacing, 0.01, 10, 0.25); f(&dualScatter, 0, 10, 0); f(&dualCount, 1, 16, 1)
        f(&fgBgJitter, 0, 1, 0); f(&hueJitter, 0, 1, 0); f(&saturationJitter, 0, 1, 0); f(&brightnessJitter, 0, 1, 0); f(&purity, -1, 1, 0)
        f(&opacityJitter, 0, 1, 0); f(&minOpacity, 0, 1, 0); f(&flowJitter, 0, 1, 0); f(&minFlow, 0, 1, 0)
        f(&poseTiltX, -1, 1, 0); f(&poseTiltY, -1, 1, 0); f(&poseRotation, -360, 360, 0); f(&posePressure, 0, 1, 1)
        for kp in [\BrushParams.sizeControl, \.angleControl, \.roundnessControl, \.scatterControl, \.countControl, \.textureDepthControl,
                   \.fgBgControl, \.colorJitterControl, \.opacityControl, \.flowControl] {
            f(&self[keyPath: kp].fadeSteps, 1, 9999, 25)
        }
    }
}

// MARK: - Import results

/// A tip image as an importer found it: decoded gray coverage (white = paint), or encoded image bytes (PNG, JPEG, …)
/// the app decodes with the platform's image codecs (the core has no general image decoder).
package enum BrushImageData {
    case gray(PixelBuffer)
    case encoded(Data)
}

/// One tip of an import: a single image or the frames of an animated tip (GIMP image pipe).
package struct ImportedTipImage {
    package var frames: [BrushImageData]
    package var selection: BrushFrameSelection
    package init(frames: [BrushImageData], selection: BrushFrameSelection = .incremental) {
        self.frames = frames; self.selection = selection
    }
    package init(_ image: BrushImageData) { frames = [image]; selection = .incremental }
}

/// A pattern carried by a brush file (ABR `8BIMpatt`, a Procreate grain) for brush textures.
package struct ImportedPattern {
    package var id: String
    package var name: String
    /// .gray or .rgba
    package var image: BrushImageData
    package init(id: String, name: String, image: BrushImageData) { self.id = id; self.name = name; self.image = image }
}

package struct ImportedBrush {
    package var name: String
    /// Folder path inside the set (ABR groups); empty = the set's top level.
    package var folderPath: [String]
    /// Key into `ImportedBrushSet.tips`; nil = a computed round tip (shape from `params.hardness` / roundness / angle).
    package var tipKey: String?
    /// `params.dualTipID` may name a key in `tips`; `params.texturePatternID` a pattern id in `patterns`.
    package var params: BrushParams
    /// Colour the preset includes (nil: it doesn't).
    package var color: RGBA?
    package var includesSize: Bool
    package var includesToolSettings: Bool
    package init(name: String, folderPath: [String] = [], tipKey: String?, params: BrushParams, color: RGBA? = nil,
                 includesSize: Bool = true, includesToolSettings: Bool = false) {
        self.name = name; self.folderPath = folderPath; self.tipKey = tipKey; self.params = params; self.color = color
        self.includesSize = includesSize; self.includesToolSettings = includesToolSettings
    }
}

/// Everything one brush file holds.
package struct ImportedBrushSet {
    /// Display name of the set (file name without extension, or the name stored in the file).
    package var name: String
    package var brushes: [ImportedBrush] = []
    package var tips: [String: ImportedTipImage] = [:]
    package var patterns: [ImportedPattern] = []
    /// Human-readable reasons for brushes that were skipped ("Brush 4: unsupported bit depth 32").
    package var skipped: [String] = []
    /// Format description for summaries ("Photoshop ABR v6", "GIMP image pipe", …).
    package var format: String = ""
    package init(name: String, format: String = "") { self.name = name; self.format = format }
}

package enum BrushImportError: LocalizedError, Equatable {
    case malformed(String)
    case unsupportedVersion(Int)
    case unsupportedFormat(String)
    case noBrushes

    package var errorDescription: String? {
        switch self {
        case .malformed(let s): return "The brush file is damaged (\(s))."
        case .unsupportedVersion(let v): return "Brush file version \(v) is not supported."
        case .unsupportedFormat(let s): return "\(s) is not a brush format ImageCrat can read."
        case .noBrushes: return "The file contains no brushes that can be imported."
        }
    }
}
