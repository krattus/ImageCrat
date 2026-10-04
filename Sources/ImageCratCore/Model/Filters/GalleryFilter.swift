import Foundation

/// Photoshop Filter Gallery approximations (Artistic, Brush Strokes, Distort, Sketch, Stylize, Texture),
/// built from Core Image filters plus runtime CI-kernel-language kernels.
package enum GalleryFilter: String, Codable, CaseIterable, Identifiable {
    // Artistic
    case coloredPencil, cutout, dryBrush, filmGrain, fresco, neonGlow, paintDaubs, paletteKnife, plasticWrap, posterEdges, roughPastels, smudgeStick, sponge, underpainting, watercolor
    // Brush Strokes
    case accentedEdges, angledStrokes, crosshatch, darkStrokes, inkOutlines, spatter, sprayedStrokes, sumie
    // Distort
    case diffuseGlow, glassDistort, oceanRipple
    // Sketch
    case basRelief, chalkCharcoal, charcoal, chrome, conteCrayon, graphicPen, halftonePattern, notePaper, photocopy, plaster, reticulation, stamp, tornEdges, waterPaper
    // Stylize
    case glowingEdges
    // Texture
    case craquelure, grain, mosaicTiles, patchwork, stainedGlass, texturizer

    package var id: String { rawValue }

    package var category: String {
        switch self {
        case .coloredPencil, .cutout, .dryBrush, .filmGrain, .fresco, .neonGlow, .paintDaubs, .paletteKnife, .plasticWrap,
             .posterEdges, .roughPastels, .smudgeStick, .sponge, .underpainting, .watercolor: return "Artistic"
        case .accentedEdges, .angledStrokes, .crosshatch, .darkStrokes, .inkOutlines, .spatter, .sprayedStrokes, .sumie: return "Brush Strokes"
        case .diffuseGlow, .glassDistort, .oceanRipple: return "Distort"
        case .basRelief, .chalkCharcoal, .charcoal, .chrome, .conteCrayon, .graphicPen, .halftonePattern, .notePaper, .photocopy,
             .plaster, .reticulation, .stamp, .tornEdges, .waterPaper: return "Sketch"
        case .glowingEdges: return "Stylize"
        case .craquelure, .grain, .mosaicTiles, .patchwork, .stainedGlass, .texturizer: return "Texture"
        }
    }

    package static let categories = ["Artistic", "Brush Strokes", "Distort", "Sketch", "Stylize", "Texture"]

    package var displayName: String {
        switch self {
        case .coloredPencil: return "Colored Pencil"
        case .cutout: return "Cutout"
        case .dryBrush: return "Dry Brush"
        case .filmGrain: return "Film Grain"
        case .fresco: return "Fresco"
        case .neonGlow: return "Neon Glow"
        case .paintDaubs: return "Paint Daubs"
        case .paletteKnife: return "Palette Knife"
        case .plasticWrap: return "Plastic Wrap"
        case .posterEdges: return "Poster Edges"
        case .roughPastels: return "Rough Pastels"
        case .smudgeStick: return "Smudge Stick"
        case .sponge: return "Sponge"
        case .underpainting: return "Underpainting"
        case .watercolor: return "Watercolor"
        case .accentedEdges: return "Accented Edges"
        case .angledStrokes: return "Angled Strokes"
        case .crosshatch: return "Crosshatch"
        case .darkStrokes: return "Dark Strokes"
        case .inkOutlines: return "Ink Outlines"
        case .spatter: return "Spatter"
        case .sprayedStrokes: return "Sprayed Strokes"
        case .sumie: return "Sumi-e"
        case .diffuseGlow: return "Diffuse Glow"
        case .glassDistort: return "Glass"
        case .oceanRipple: return "Ocean Ripple"
        case .basRelief: return "Bas Relief"
        case .chalkCharcoal: return "Chalk & Charcoal"
        case .charcoal: return "Charcoal"
        case .chrome: return "Chrome"
        case .conteCrayon: return "Conté Crayon"
        case .graphicPen: return "Graphic Pen"
        case .halftonePattern: return "Halftone Pattern"
        case .notePaper: return "Note Paper"
        case .photocopy: return "Photocopy"
        case .plaster: return "Plaster"
        case .reticulation: return "Reticulation"
        case .stamp: return "Stamp"
        case .tornEdges: return "Torn Edges"
        case .waterPaper: return "Water Paper"
        case .glowingEdges: return "Glowing Edges"
        case .craquelure: return "Craquelure"
        case .grain: return "Grain"
        case .mosaicTiles: return "Mosaic Tiles"
        case .patchwork: return "Patchwork"
        case .stainedGlass: return "Stained Glass"
        case .texturizer: return "Texturizer"
        }
    }

    // MARK: Parameters

    private static func s(_ key: String, _ label: String, _ r: ClosedRange<Double>, _ d: Double, _ unit: String = "") -> FilterParam {
        FilterParam(key: key, label: label, kind: .slider(r), defaultValue: d, unit: unit)
    }
    private static func c(_ key: String, _ label: String, _ options: [String], _ d: Double) -> FilterParam {
        FilterParam(key: key, label: label, kind: .choice(options), defaultValue: d)
    }
    package static let textureChoices = ["Brick", "Burlap", "Canvas", "Sandstone"]
    package static let lightChoices = ["Bottom", "Bottom Left", "Left", "Top Left", "Top", "Top Right", "Right", "Bottom Right"]
    package static let directionChoices = ["Right Diagonal", "Horizontal", "Left Diagonal", "Vertical"]

    package var params: [FilterParam] {
        typealias G = GalleryFilter
        switch self {
        case .coloredPencil: return [G.s("width", "Pencil Width", 1...24, 4), G.s("pressure", "Stroke Pressure", 0...15, 8), G.s("paper", "Paper Brightness", 0...50, 25)]
        case .cutout: return [G.s("levels", "Number of Levels", 2...8, 4), G.s("simplicity", "Edge Simplicity", 0...10, 4), G.s("fidelity", "Edge Fidelity", 1...3, 2)]
        case .dryBrush: return [G.s("size", "Brush Size", 0...10, 2), G.s("detail", "Brush Detail", 0...10, 8), G.s("texture", "Texture", 1...3, 1)]
        case .filmGrain: return [G.s("grain", "Grain", 0...20, 4), G.s("area", "Highlight Area", 0...20, 0), G.s("intensity", "Intensity", 0...10, 10)]
        case .fresco: return [G.s("size", "Brush Size", 0...10, 2), G.s("detail", "Brush Detail", 0...10, 8), G.s("texture", "Texture", 1...3, 1)]
        case .neonGlow: return [G.s("size", "Glow Size", -24...24, 5), G.s("brightness", "Glow Brightness", 0...50, 15), G.s("hue", "Glow Color (Hue)", 0...360, 200, "°")]
        case .paintDaubs: return [G.s("size", "Brush Size", 1...50, 8), G.s("sharpness", "Sharpness", 0...40, 7),
                                  G.c("type", "Brush Type", ["Simple", "Light Rough", "Dark Rough", "Wide Sharp", "Wide Blurry", "Sparkle"], 0)]
        case .paletteKnife: return [G.s("size", "Stroke Size", 1...50, 25), G.s("detail", "Stroke Detail", 1...3, 3), G.s("softness", "Softness", 0...10, 0)]
        case .plasticWrap: return [G.s("strength", "Highlight Strength", 0...20, 15), G.s("detail", "Detail", 1...15, 9), G.s("smoothness", "Smoothness", 1...15, 7)]
        case .posterEdges: return [G.s("thickness", "Edge Thickness", 0...10, 2), G.s("intensity", "Edge Intensity", 0...10, 1), G.s("posterization", "Posterization", 0...6, 2)]
        case .roughPastels: return [G.s("length", "Stroke Length", 0...40, 6), G.s("detail", "Stroke Detail", 1...20, 4),
                                    G.c("texture", "Texture", G.textureChoices, 2), G.s("relief", "Relief", 0...50, 20)]
        case .smudgeStick: return [G.s("length", "Stroke Length", 0...10, 2), G.s("area", "Highlight Area", 0...20, 0), G.s("intensity", "Intensity", 0...10, 10)]
        case .sponge: return [G.s("size", "Brush Size", 0...10, 2), G.s("definition", "Definition", 0...25, 12), G.s("smoothness", "Smoothness", 1...15, 5)]
        case .underpainting: return [G.s("size", "Brush Size", 0...40, 6), G.s("coverage", "Texture Coverage", 0...40, 16),
                                     G.c("texture", "Texture", G.textureChoices, 2), G.s("relief", "Relief", 0...50, 4)]
        case .watercolor: return [G.s("detail", "Brush Detail", 1...14, 9), G.s("shadow", "Shadow Intensity", 0...10, 1), G.s("texture", "Texture", 1...3, 1)]
        case .accentedEdges: return [G.s("width", "Edge Width", 1...14, 2), G.s("brightness", "Edge Brightness", 0...50, 38), G.s("smoothness", "Smoothness", 1...15, 5)]
        case .angledStrokes: return [G.s("balance", "Direction Balance", 0...100, 50), G.s("length", "Stroke Length", 3...50, 15), G.s("sharpness", "Sharpness", 0...10, 3)]
        case .crosshatch: return [G.s("length", "Stroke Length", 3...50, 9), G.s("sharpness", "Sharpness", 0...20, 6), G.s("strength", "Strength", 1...3, 1)]
        case .darkStrokes: return [G.s("balance", "Balance", 0...10, 5), G.s("black", "Black Intensity", 0...10, 6), G.s("white", "White Intensity", 0...10, 2)]
        case .inkOutlines: return [G.s("length", "Stroke Length", 1...50, 4), G.s("dark", "Dark Intensity", 0...50, 20), G.s("light", "Light Intensity", 0...50, 10)]
        case .spatter: return [G.s("radius", "Spray Radius", 0...25, 10), G.s("smoothness", "Smoothness", 1...15, 5)]
        case .sprayedStrokes: return [G.s("length", "Stroke Length", 0...20, 12), G.s("radius", "Spray Radius", 0...25, 7), G.c("direction", "Stroke Direction", G.directionChoices, 0)]
        case .sumie: return [G.s("width", "Stroke Width", 3...15, 10), G.s("pressure", "Stroke Pressure", 0...15, 2), G.s("contrast", "Contrast", 0...40, 16)]
        case .diffuseGlow: return [G.s("graininess", "Graininess", 0...10, 6), G.s("glow", "Glow Amount", 0...20, 10), G.s("clear", "Clear Amount", 0...20, 15)]
        case .glassDistort: return [G.s("distortion", "Distortion", 0...20, 5), G.s("smoothness", "Smoothness", 1...15, 3),
                                    G.c("texture", "Texture", ["Blocks", "Canvas", "Frosted", "Tiny Lens"], 2), G.s("scaling", "Scaling", 50...200, 100, "%")]
        case .oceanRipple: return [G.s("size", "Ripple Size", 1...15, 9), G.s("magnitude", "Ripple Magnitude", 0...20, 9)]
        case .basRelief: return [G.s("detail", "Detail", 1...15, 13), G.s("smoothness", "Smoothness", 1...15, 3), G.c("light", "Light", G.lightChoices, 0)]
        case .chalkCharcoal: return [G.s("charcoal", "Charcoal Area", 0...20, 6), G.s("chalk", "Chalk Area", 0...20, 6), G.s("pressure", "Stroke Pressure", 0...5, 1)]
        case .charcoal: return [G.s("thickness", "Charcoal Thickness", 1...7, 1), G.s("detail", "Detail", 0...5, 5), G.s("balance", "Light/Dark Balance", 0...100, 50)]
        case .chrome: return [G.s("detail", "Detail", 0...10, 4), G.s("smoothness", "Smoothness", 0...10, 7)]
        case .conteCrayon: return [G.s("fgLevel", "Foreground Level", 1...15, 11), G.s("bgLevel", "Background Level", 1...15, 7),
                                   G.c("texture", "Texture", G.textureChoices, 2), G.s("relief", "Relief", 0...50, 4)]
        case .graphicPen: return [G.s("length", "Stroke Length", 1...15, 15), G.s("balance", "Light/Dark Balance", 0...100, 50), G.c("direction", "Stroke Direction", G.directionChoices, 0)]
        case .halftonePattern: return [G.s("size", "Size", 1...12, 1), G.s("contrast", "Contrast", 0...50, 5), G.c("pattern", "Pattern Type", ["Circle", "Dot", "Line"], 1)]
        case .notePaper: return [G.s("balance", "Image Balance", 0...50, 25), G.s("graininess", "Graininess", 0...20, 10), G.s("relief", "Relief", 0...25, 11)]
        case .photocopy: return [G.s("detail", "Detail", 1...24, 7), G.s("darkness", "Darkness", 1...50, 8)]
        case .plaster: return [G.s("balance", "Image Balance", 0...50, 20), G.s("smoothness", "Smoothness", 1...15, 2), G.c("light", "Light", G.lightChoices, 4)]
        case .reticulation: return [G.s("density", "Density", 0...50, 12), G.s("fgLevel", "Foreground Level", 0...50, 40), G.s("bgLevel", "Background Level", 0...50, 5)]
        case .stamp: return [G.s("balance", "Light/Dark Balance", 0...50, 25), G.s("smoothness", "Smoothness", 1...50, 5)]
        case .tornEdges: return [G.s("balance", "Image Balance", 0...50, 25), G.s("smoothness", "Smoothness", 1...15, 11), G.s("contrast", "Contrast", 1...25, 17)]
        case .waterPaper: return [G.s("fiber", "Fiber Length", 3...50, 15), G.s("brightness", "Brightness", 0...100, 60), G.s("contrast", "Contrast", 0...100, 80)]
        case .glowingEdges: return [G.s("width", "Edge Width", 1...14, 2), G.s("brightness", "Edge Brightness", 0...20, 6), G.s("smoothness", "Smoothness", 1...15, 5)]
        case .craquelure: return [G.s("spacing", "Crack Spacing", 2...100, 15), G.s("depth", "Crack Depth", 0...10, 6), G.s("brightness", "Crack Brightness", 0...10, 9)]
        case .grain: return [G.s("intensity", "Intensity", 0...100, 40), G.s("contrast", "Contrast", 0...100, 50),
                             G.c("type", "Grain Type", ["Regular", "Soft", "Sprinkles", "Clumped", "Contrasty", "Enlarged", "Stippled", "Horizontal", "Vertical", "Speckle"], 0)]
        case .mosaicTiles: return [G.s("size", "Tile Size", 2...100, 12), G.s("grout", "Grout Width", 1...15, 3), G.s("lighten", "Lighten Grout", 0...10, 9)]
        case .patchwork: return [G.s("size", "Square Size", 0...10, 4), G.s("relief", "Relief", 0...25, 8)]
        case .stainedGlass: return [G.s("cell", "Cell Size", 2...50, 10), G.s("border", "Border Thickness", 1...20, 4), G.s("light", "Light Intensity", 0...10, 3)]
        case .texturizer: return [G.c("texture", "Texture", G.textureChoices, 2), G.s("scaling", "Scaling", 50...200, 100, "%"),
                                  G.s("relief", "Relief", 0...50, 4), G.c("light", "Light", G.lightChoices, 4)]
        }
    }

    package var defaultValues: [String: Double] { Dictionary(uniqueKeysWithValues: params.map { ($0.key, $0.defaultValue) }) }
}
