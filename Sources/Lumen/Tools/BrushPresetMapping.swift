import Foundation
import ImageCratCore

// MARK: - Portable preset model (core `BrushParams`) ↔ the app's `BrushSettings`

extension BrushControl {
    init(_ s: BrushControlSource) { self = BrushControl(rawValue: s.rawValue) ?? .off }
    var portable: BrushControlSource { BrushControlSource(rawValue: rawValue) ?? .off }
}

extension ControlSetting {
    init(_ p: BrushControlParam) { self.init(source: BrushControl(p.source), fadeSteps: p.fadeSteps) }
    var portable: BrushControlParam { BrushControlParam(source: source.portable, fadeSteps: fadeSteps) }
}

extension BrushMaskMode {
    init(_ m: BrushMaskBlend) { self = BrushMaskMode(rawValue: m.rawValue) ?? .multiply }
    var portable: BrushMaskBlend { BrushMaskBlend(rawValue: rawValue) ?? .multiply }
}

extension BrushParams {
    /// Everything the settings hold (the tip id is kept by the library record, not here).
    init(_ s: BrushSettings) {
        self.init()
        let d = s.dynamics
        size = s.size; hardness = s.hardness; spacing = s.spacing; angle = s.angle; roundness = s.roundness
        flipX = d.flipX; flipY = d.flipY
        opacity = s.opacity; flow = s.flow; smoothing = s.smoothing; blendMode = s.blendMode.rawValue
        pressureSize = s.pressureSize; pressureOpacity = s.pressureOpacity; airbrush = s.airbrush
        shapeEnabled = d.shapeEnabled; sizeJitter = s.sizeJitter; sizeControl = d.sizeControl.portable; minDiameter = d.minDiameter
        tiltScale = d.tiltScale; angleJitter = d.angleJitter; angleControl = d.angleControl.portable
        roundnessJitter = d.roundnessJitter; roundnessControl = d.roundnessControl.portable; minRoundness = d.minRoundness
        flipXJitter = d.flipXJitter; flipYJitter = d.flipYJitter; brushProjection = d.brushProjection
        scatterEnabled = d.scatterEnabled; scatter = s.scatter; scatterBothAxes = d.scatterBothAxes; scatterControl = d.scatterControl.portable
        count = d.count; countJitter = d.countJitter; countControl = d.countControl.portable
        textureEnabled = d.textureEnabled; texturePatternID = d.texturePatternID; textureScale = d.textureScale
        textureBrightness = d.textureBrightness; textureContrast = d.textureContrast; textureInvert = d.textureInvert
        textureEachTip = d.textureEachTip; textureMode = d.textureMode.portable; textureDepth = d.textureDepth
        textureMinDepth = d.textureMinDepth; textureDepthJitter = d.textureDepthJitter; textureDepthControl = d.textureDepthControl.portable
        protectTexture = d.protectTexture
        dualEnabled = d.dualEnabled; dualTipID = d.dualTipID; dualSize = d.dualSize; dualHardness = d.dualHardness
        dualSpacing = d.dualSpacing; dualScatter = d.dualScatter; dualBothAxes = d.dualBothAxes; dualCount = d.dualCount
        dualMode = d.dualMode.portable; dualFlip = d.dualFlip
        colorEnabled = d.colorEnabled; colorPerTip = d.colorPerTip; fgBgJitter = d.fgBgJitter; fgBgControl = d.fgBgControl.portable
        hueJitter = d.hueJitter; saturationJitter = d.saturationJitter; brightnessJitter = d.brightnessJitter; purity = d.purity
        colorJitterControl = d.colorJitterControl.portable
        transferEnabled = d.transferEnabled; opacityJitter = s.opacityJitter; opacityControl = d.opacityControl.portable
        minOpacity = d.minOpacity; flowJitter = d.flowJitter; flowControl = d.flowControl.portable; minFlow = d.minFlow
        poseEnabled = d.poseEnabled; poseTiltX = d.poseTiltX; poseTiltY = d.poseTiltY; poseRotation = d.poseRotation
        posePressure = d.posePressure; poseOverrideTilt = d.poseOverrideTilt; poseOverrideRotation = d.poseOverrideRotation
        poseOverridePressure = d.poseOverridePressure
        noise = d.noise; wetEdges = d.wetEdges
    }

    /// The preset part of the parameters (what choosing a preset changes); tool settings and size are masked by flags.
    func presetPart(includesSize: Bool, includesToolSettings: Bool) -> BrushParams {
        var p = self
        let neutral = BrushParams()
        if !includesSize { p.size = neutral.size }
        if !includesToolSettings {
            p.opacity = neutral.opacity; p.flow = neutral.flow; p.smoothing = neutral.smoothing; p.blendMode = neutral.blendMode
        }
        // The options-bar pressure toggles belong to the tool, not the preset.
        p.pressureSize = neutral.pressureSize; p.pressureOpacity = neutral.pressureOpacity
        return p
    }
}

extension BrushSettings {
    /// Writes a preset's parameters into these settings. Size and tool settings (opacity, flow, mode, smoothing) only
    /// when the preset includes them; texture settings stay when Protect Texture is on in the current settings.
    mutating func apply(_ p: BrushParams, tipID: String, includesSize: Bool, includesToolSettings: Bool) {
        let keepTexture = dynamics.protectTexture
        let oldTexture = dynamics
        if includesSize { size = p.size }
        hardness = p.hardness; spacing = p.spacing; angle = p.angle; roundness = p.roundness
        self.tipID = tipID
        if includesToolSettings {
            opacity = p.opacity; flow = p.flow; smoothing = p.smoothing
            blendMode = BlendMode(rawValue: p.blendMode) ?? blendMode
        }
        airbrush = p.airbrush
        sizeJitter = p.sizeJitter; scatter = p.scatter; opacityJitter = p.opacityJitter
        var d = BrushDynamics()
        d.flipX = p.flipX; d.flipY = p.flipY
        d.shapeEnabled = p.shapeEnabled; d.sizeControl = ControlSetting(p.sizeControl); d.minDiameter = p.minDiameter
        d.tiltScale = p.tiltScale; d.angleJitter = p.angleJitter; d.angleControl = ControlSetting(p.angleControl)
        d.roundnessJitter = p.roundnessJitter; d.roundnessControl = ControlSetting(p.roundnessControl); d.minRoundness = p.minRoundness
        d.flipXJitter = p.flipXJitter; d.flipYJitter = p.flipYJitter; d.brushProjection = p.brushProjection
        d.scatterEnabled = p.scatterEnabled; d.scatterBothAxes = p.scatterBothAxes; d.scatterControl = ControlSetting(p.scatterControl)
        d.count = p.count; d.countJitter = p.countJitter; d.countControl = ControlSetting(p.countControl)
        d.textureEnabled = p.textureEnabled; d.texturePatternID = p.texturePatternID; d.textureScale = p.textureScale
        d.textureBrightness = p.textureBrightness; d.textureContrast = p.textureContrast; d.textureInvert = p.textureInvert
        d.textureEachTip = p.textureEachTip; d.textureMode = BrushMaskMode(p.textureMode); d.textureDepth = p.textureDepth
        d.textureMinDepth = p.textureMinDepth; d.textureDepthJitter = p.textureDepthJitter; d.textureDepthControl = ControlSetting(p.textureDepthControl)
        d.protectTexture = p.protectTexture
        d.dualEnabled = p.dualEnabled; d.dualTipID = p.dualTipID; d.dualSize = p.dualSize; d.dualHardness = p.dualHardness
        d.dualSpacing = p.dualSpacing; d.dualScatter = p.dualScatter; d.dualBothAxes = p.dualBothAxes; d.dualCount = p.dualCount
        d.dualMode = BrushMaskMode(p.dualMode); d.dualFlip = p.dualFlip
        d.colorEnabled = p.colorEnabled; d.colorPerTip = p.colorPerTip; d.fgBgJitter = p.fgBgJitter; d.fgBgControl = ControlSetting(p.fgBgControl)
        d.hueJitter = p.hueJitter; d.saturationJitter = p.saturationJitter; d.brightnessJitter = p.brightnessJitter; d.purity = p.purity
        d.colorJitterControl = ControlSetting(p.colorJitterControl)
        d.transferEnabled = p.transferEnabled; d.opacityControl = ControlSetting(p.opacityControl); d.minOpacity = p.minOpacity
        d.flowJitter = p.flowJitter; d.flowControl = ControlSetting(p.flowControl); d.minFlow = p.minFlow
        d.poseEnabled = p.poseEnabled; d.poseTiltX = p.poseTiltX; d.poseTiltY = p.poseTiltY; d.poseRotation = p.poseRotation
        d.posePressure = p.posePressure; d.poseOverrideTilt = p.poseOverrideTilt; d.poseOverrideRotation = p.poseOverrideRotation
        d.poseOverridePressure = p.poseOverridePressure
        d.noise = p.noise; d.wetEdges = p.wetEdges
        if keepTexture {
            d.textureEnabled = oldTexture.textureEnabled; d.texturePatternID = oldTexture.texturePatternID; d.textureScale = oldTexture.textureScale
            d.textureBrightness = oldTexture.textureBrightness; d.textureContrast = oldTexture.textureContrast; d.textureInvert = oldTexture.textureInvert
            d.textureEachTip = oldTexture.textureEachTip; d.textureMode = oldTexture.textureMode; d.textureDepth = oldTexture.textureDepth
            d.textureMinDepth = oldTexture.textureMinDepth; d.textureDepthJitter = oldTexture.textureDepthJitter
            d.textureDepthControl = oldTexture.textureDepthControl; d.protectTexture = true
        }
        dynamics = d
    }
}

extension BrushPreset {
    /// The full parameters of a legacy built-in preset (what `apply(to:)` produces from default settings).
    var params: BrushParams {
        var s = BrushSettings()
        s.pressureSize = true
        apply(to: &s)
        return BrushParams(s)
    }
}
