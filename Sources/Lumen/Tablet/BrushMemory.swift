import Foundation
import ImageCratCore

/// Per-tool brushes: every painting tool remembers its own tip, size and settings (Photoshop behaviour), unless
/// Preferences ▸ Tablet ▸ "Sync brush across tools" is on — then the tip travels with you from tool to tool.
/// The brush library follows the same rule for the preset each tool's brush came from (`activePresetID(for:)`):
/// per tool without sync, carried along with the tip with sync.
extension AppModel {
    /// Tools that paint with a brush of their own.
    static let brushTools: [ToolKind] = [.brush, .pencil, .eraser, .mixerBrush, .colorReplacement, .cloneStamp, .patternStamp,
                                         .healing, .spotHealing, .removeTool, .historyBrush, .artHistoryBrush, .backgroundEraser,
                                         .blur, .sharpen, .smudge, .dodge, .burn, .sponge, .selectionBrush]
    static func hasBrush(_ k: ToolKind) -> Bool { brushTools.contains(k) }

    static let retouchKinds: [ToolKind] = [.blur, .sharpen, .smudge, .dodge, .burn, .sponge]
    static let healingDefault = BrushSettings(size: 40, hardness: 0.6)
    static let retouchDefault = BrushSettings(size: 50, hardness: 0.3)
    static var sharedSlotDefaults: [ToolKind: BrushSettings] {
        var d: [ToolKind: BrushSettings] = [.healing: healingDefault, .spotHealing: healingDefault]
        for k in retouchKinds { d[k] = retouchDefault }
        return d
    }

    /// The brush a tool paints with (tools without a brush of their own read the main brush).
    func brushSettings(for k: ToolKind) -> BrushSettings {
        switch k {
        case .pencil: return pencil
        case .eraser: return eraser
        case .cloneStamp: return clone
        case .healing, .spotHealing: return toolBrushes[k] ?? AppModel.healingDefault
        case .historyBrush: return historyBrush
        case .removeTool: return removeBrush
        case .colorReplacement: return colorReplaceBrush
        case .mixerBrush: return mixerBrushSettings
        case .blur, .sharpen, .smudge, .dodge, .burn, .sponge: return toolBrushes[k] ?? AppModel.retouchDefault
        default: return ToolsSettings.shared.brush(for: k) ?? brush
        }
    }

    func setBrushSettings(_ s: BrushSettings, for k: ToolKind) {
        switch k {
        case .pencil: pencil = s
        case .eraser: eraser = s
        case .cloneStamp: clone = s
        case .healing, .spotHealing: toolBrushes[k] = s
        case .historyBrush: historyBrush = s
        case .removeTool: removeBrush = s
        case .colorReplacement: colorReplaceBrush = s
        case .mixerBrush: mixerBrushSettings = s
        case .blur, .sharpen, .smudge, .dodge, .burn, .sponge: toolBrushes[k] = s
        default: if !ToolsSettings.shared.setBrush(s, for: k) { brush = s }
        }
    }

    /// With sync on, the brush tip of the tool being left is carried over to the new tool (opacity, flow, mode and
    /// the pressure buttons stay with each tool, like the tool's own options), and so is its library preset.
    func syncBrush(from old: ToolKind, to new: ToolKind) {
        guard TabletSettings.shared.prefs.syncBrushAcrossTools, AppModel.hasBrush(old), AppModel.hasBrush(new) else { return }
        let src = brushSettings(for: old)
        var dst = brushSettings(for: new)
        BrushMemory.copyTip(from: src, to: &dst)
        if dst != brushSettings(for: new) { setBrushSettings(dst, for: new) }
        BrushLibrary.shared.toolBrushSynced(from: old, to: new)
    }
}

enum BrushMemory {
    /// The tip part of brush settings (what "sync" shares between tools): everything a brush preset owns except the
    /// tool settings (opacity, flow, mode, smoothing) and the options-bar pressure buttons.
    static func copyTip(from src: BrushSettings, to dst: inout BrushSettings) {
        dst.size = src.size; dst.hardness = src.hardness; dst.tipID = src.tipID; dst.spacing = src.spacing
        dst.angle = src.angle; dst.roundness = src.roundness; dst.sizeJitter = src.sizeJitter; dst.scatter = src.scatter
        dst.opacityJitter = src.opacityJitter; dst.airbrush = src.airbrush
        dst.dynamics = src.dynamics
    }
}
