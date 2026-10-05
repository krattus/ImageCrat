import Foundation
import ImageCratCore

/// The brushes ImageCrat ships: procedural tips only (no third-party brush files), in Photoshop-like folders.
/// Ids of the older flat preset list are kept, so presets chosen before still resolve.
enum BrushDefaults {
    /// Bump when brushes are added; a library with an older version gets the new ones (never the deleted ones back).
    static let version = 1

    static let folders = ["General", "Dry Media", "Wet Media", "Special Effects"]

    static func records() -> [(folder: String, record: BrushRecord)] {
        var out: [(String, BrushRecord)] = []
        func add(_ folder: String, _ p: BrushPreset) {
            out.append((folder, BrushRecord(id: p.id, name: p.name, tipID: p.tipID, params: p.params, builtIn: true, source: "ImageCrat")))
        }
        func add(_ folder: String, _ id: String, _ name: String, tip: String = "round", _ f: (inout BrushParams) -> Void) {
            var p = BrushParams()
            f(&p)
            p.sanitize()
            out.append((folder, BrushRecord(id: id, name: name, tipID: tip, params: p, builtIn: true, source: "ImageCrat")))
        }
        let legacy = Dictionary(uniqueKeysWithValues: (BrushPreset.builtIn + BrushPreset.dynamicPresets).map { ($0.id, $0) })
        func L(_ folder: String, _ id: String) { if let p = legacy[id] { add(folder, p) } }

        // General
        for id in ["hard5", "hard13", "hard30", "hard100", "soft13", "soft45", "soft100", "soft300", "airbrush", "flat"] { L("General", id) }
        add("General", "hard-square", "Hard Square 30", tip: "square") { $0.size = 30; $0.hardness = 1; $0.spacing = 0.1 }
        add("General", "pressure-round", "Hard Round Pressure Size", tip: "round") {
            $0.size = 24; $0.hardness = 1; $0.spacing = 0.05
            $0.shapeEnabled = true; $0.sizeControl.source = .pressure; $0.minDiameter = 0.1
        }
        L("General", "dyn-ink")

        // Dry Media
        L("Dry Media", "chalk"); L("Dry Media", "charcoal"); L("Dry Media", "dyn-canvaschalk"); L("Dry Media", "dry")
        add("Dry Media", "hb-pencil", "HB Pencil", tip: "pencil") {
            $0.size = 6; $0.hardness = 1; $0.spacing = 0.08
            $0.shapeEnabled = true; $0.angleJitter = 1
            $0.transferEnabled = true; $0.opacityControl.source = .pressure; $0.minOpacity = 0.2
        }
        add("Dry Media", "soft-pastel", "Soft Pastel", tip: "chalk") {
            $0.size = 40; $0.spacing = 0.12
            $0.shapeEnabled = true; $0.angleJitter = 1; $0.sizeJitter = 0.15
            $0.textureEnabled = true; $0.texturePatternID = "noise"; $0.textureMode = .subtract; $0.textureDepth = 0.5; $0.textureScale = 1
        }
        add("Dry Media", "crayon", "Wax Crayon", tip: "pencil") {
            $0.size = 18; $0.spacing = 0.1
            $0.shapeEnabled = true; $0.angleJitter = 1; $0.roundnessJitter = 0.3; $0.minRoundness = 0.6
            $0.textureEnabled = true; $0.texturePatternID = "noise"; $0.textureMode = .height; $0.textureDepth = 0.8; $0.textureScale = 0.8
        }

        // Wet Media
        L("Wet Media", "dyn-watercolor")
        add("Wet Media", "watercolor-wash", "Watercolor Wash", tip: "round") {
            $0.size = 120; $0.hardness = 0.3; $0.spacing = 0.06; $0.flow = 0.35
            $0.wetEdges = true; $0.transferEnabled = true; $0.flowControl.source = .pressure; $0.minFlow = 0.2
        }
        add("Wet Media", "ink-pen", "Ink Pen", tip: "round") {
            $0.size = 8; $0.hardness = 1; $0.spacing = 0.03; $0.smoothing = 0.4
            $0.shapeEnabled = true; $0.sizeControl.source = .pressure; $0.minDiameter = 0.05
        }
        add("Wet Media", "gouache", "Gouache Bristle", tip: "bristle") {
            $0.size = 50; $0.spacing = 0.05
            $0.shapeEnabled = true; $0.angleControl.source = .direction
            $0.transferEnabled = true; $0.flowControl.source = .pressure; $0.minFlow = 0.3
            $0.dualEnabled = true; $0.dualTipID = "bristle"; $0.dualSize = 40; $0.dualSpacing = 0.1; $0.dualMode = .multiply
        }
        add("Wet Media", "wet-sponge", "Wet Sponge", tip: "sponge") {
            $0.size = 70; $0.spacing = 0.2
            $0.shapeEnabled = true; $0.angleJitter = 1; $0.sizeJitter = 0.2
            $0.wetEdges = true
        }

        // Special Effects
        L("Special Effects", "spatter"); L("Special Effects", "dyn-dualspatter")
        add("Special Effects", "spray-paint", "Spray Paint", tip: "spray") {
            $0.size = 90; $0.spacing = 0.15; $0.airbrush = true
            $0.shapeEnabled = true; $0.angleJitter = 1
            $0.transferEnabled = true; $0.flowControl.source = .pressure
        }
        L("Special Effects", "grass"); L("Special Effects", "dyn-leaves")
        add("Special Effects", "falling-leaves", "Falling Leaves", tip: "leaf") {
            $0.size = 40; $0.spacing = 0.8
            $0.shapeEnabled = true; $0.sizeJitter = 0.5; $0.angleJitter = 1; $0.flipXJitter = true
            $0.scatterEnabled = true; $0.scatter = 2; $0.count = 2; $0.countJitter = 0.5
            $0.colorEnabled = true; $0.fgBgJitter = 1; $0.hueJitter = 0.05; $0.brightnessJitter = 0.2
        }
        L("Special Effects", "star"); L("Special Effects", "dyn-noisy")
        return out
    }

    /// Adds the default brushes a library doesn't have yet (in their folders), skipping ones the user deleted.
    static func install(into ix: inout BrushLibraryIndex) -> Int {
        guard ix.defaultsVersion < version else { return 0 }
        var added = 0
        for (folder, r) in records() where ix.brushes[r.id] == nil && !ix.deletedDefaults.contains(r.id) {
            let fid = ix.folder(path: [folder])
            ix.add(r, to: fid)
            added += 1
        }
        ix.defaultsVersion = version
        return added
    }
}
