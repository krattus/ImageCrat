import Foundation

package enum FilterParamKind: Equatable {
    case slider(ClosedRange<Double>)
    case angle
    case toggle
    case choice([String])
    case percentPoint   // normalized 0...1 coordinate within canvas
}

package struct FilterParam: Identifiable {
    package let key: String
    package let label: String
    package let kind: FilterParamKind
    package let defaultValue: Double
    package var unit: String = ""
    package var id: String { key }
    package init(key: String, label: String, kind: FilterParamKind, defaultValue: Double, unit: String = "") {
        self.key = key; self.label = label; self.kind = kind; self.defaultValue = defaultValue; self.unit = unit
    }
}

package enum FilterCategory: String, CaseIterable {
    case blur = "Blur", blurGallery = "Blur Gallery", sharpen = "Sharpen", noise = "Noise", distort = "Distort", pixelate = "Pixelate"
    case stylize = "Stylize", render = "Render", photo = "Photo Effects", other = "Other"
}

package struct FilterInstance: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var kind: FilterKind
    package var values: [String: Double]
    package var colors: [RGBA] = []
    package var enabled = true
    package var opacity: Double = 1
    package var blendMode: BlendMode = .normal
    /// Filter Gallery stack (applied bottom → top).
    package var gallery: [GalleryEntry] = []
    /// On-canvas pins (Blur Gallery): normalized canvas positions with per-pin values.
    package var points: [FilterPin] = []
    /// Extra image input (Displace map), stored gray/RGBA.
    package var payload: PixelBuffer? = nil
    /// Node graph of a Recipe smart filter (`kind == .recipe`).
    package var recipe: RecipeGraph? = nil
    /// Smart filter mask (document coordinates, gray): where the filter shows. Added from the selection that was
    /// active when the smart filter was created, like Photoshop's filter mask; nil = everywhere.
    package var mask: LayerMask? = nil
    /// Displacement mesh of a Liquify smart filter (`kind == .liquify`).
    package var liquify: LiquifyMesh? = nil

    package init(kind: FilterKind, colors: [RGBA] = []) {
        self.kind = kind
        self.values = Dictionary(uniqueKeysWithValues: kind.params.map { ($0.key, $0.defaultValue) })
        self.colors = colors
    }

    package func value(_ key: String) -> Double { values[key] ?? kind.params.first { $0.key == key }?.defaultValue ?? 0 }
}

package enum FilterKind: String, Codable, CaseIterable, Identifiable {
    // Blur
    case gaussianBlur, boxBlur, motionBlur, radialBlur, spinBlur, lensBlur, tiltShift, average
    // Sharpen
    case sharpen, unsharpMask
    // Noise
    case addNoise, reduceNoise, median
    // Distort
    case twirl, pinch, spherize, ripple, wave, polarCoordinates, vortex, glass
    // Pixelate
    case mosaic, crystallize, pointillize, hexagon, colorHalftone, dotScreen, lineScreen
    // Stylize
    case emboss, findEdges, glowingEdges, edgeWork, solarize, oilPaint, comic, lineOverlay, bloom, gloom, kaleidoscope, wind
    // Render
    case clouds, differenceClouds, lensFlare, vignette, spotlight
    // Photo
    case cameraRaw, sepia, noir, chrome, fade, instant, mono, process, tonal, transfer, thermal, xray
    // Other
    case highPass, maximum, minimum, offset
    // Added
    case filterGallery, lensCorrection, smartSharpen, displace, surfaceBlur, dustAndScratches, fieldBlur, irisBlur, pathBlur
    // Neural Filters output as a smart filter (baked result in `payload`)
    case neuralFilter
    // Recipe filter: a node graph (`FilterInstance.recipe`) evaluated on the smart object's content
    case recipe
    // Liquify as a smart filter (mesh in `FilterInstance.liquify`); has its own menu item and dialog
    case liquify

    package var id: String { rawValue }

    package var category: FilterCategory {
        switch self {
        case .gaussianBlur, .boxBlur, .motionBlur, .radialBlur, .spinBlur, .lensBlur, .tiltShift, .average: return .blur
        case .sharpen, .unsharpMask: return .sharpen
        case .addNoise, .reduceNoise, .median: return .noise
        case .twirl, .pinch, .spherize, .ripple, .wave, .polarCoordinates, .vortex, .glass: return .distort
        case .mosaic, .crystallize, .pointillize, .hexagon, .colorHalftone, .dotScreen, .lineScreen: return .pixelate
        case .emboss, .findEdges, .glowingEdges, .edgeWork, .solarize, .oilPaint, .comic, .lineOverlay, .bloom, .gloom, .kaleidoscope, .wind: return .stylize
        case .clouds, .differenceClouds, .lensFlare, .vignette, .spotlight: return .render
        case .cameraRaw, .sepia, .noir, .chrome, .fade, .instant, .mono, .process, .tonal, .transfer, .thermal, .xray: return .photo
        case .highPass, .maximum, .minimum, .offset, .displace: return .other
        case .filterGallery: return .stylize
        case .lensCorrection: return .distort
        case .smartSharpen: return .sharpen
        case .surfaceBlur: return .blur
        case .dustAndScratches: return .noise
        case .fieldBlur, .irisBlur, .pathBlur: return .blurGallery
        case .neuralFilter, .recipe: return .other
        case .liquify: return .distort
        }
    }

    package var displayName: String {
        switch self {
        case .gaussianBlur: return "Gaussian Blur"
        case .boxBlur: return "Box Blur"
        case .motionBlur: return "Motion Blur"
        case .radialBlur: return "Radial Blur (Zoom)"
        case .spinBlur: return "Spin Blur"
        case .lensBlur: return "Lens Blur"
        case .tiltShift: return "Tilt-Shift"
        case .average: return "Average"
        case .sharpen: return "Sharpen"
        case .unsharpMask: return "Unsharp Mask"
        case .addNoise: return "Add Noise"
        case .reduceNoise: return "Reduce Noise"
        case .median: return "Median"
        case .twirl: return "Twirl"
        case .pinch: return "Pinch"
        case .spherize: return "Spherize"
        case .ripple: return "Ripple"
        case .wave: return "Wave"
        case .polarCoordinates: return "Polar Coordinates"
        case .vortex: return "Vortex"
        case .glass: return "Glass"
        case .mosaic: return "Mosaic"
        case .crystallize: return "Crystallize"
        case .pointillize: return "Pointillize"
        case .hexagon: return "Hexagonal Pixelate"
        case .colorHalftone: return "Color Halftone"
        case .dotScreen: return "Dot Screen"
        case .lineScreen: return "Line Screen"
        case .emboss: return "Emboss"
        case .findEdges: return "Find Edges"
        case .glowingEdges: return "Glowing Edges"
        case .edgeWork: return "Edge Work"
        case .solarize: return "Solarize"
        case .oilPaint: return "Oil Paint"
        case .comic: return "Comic"
        case .lineOverlay: return "Line Overlay"
        case .bloom: return "Bloom"
        case .gloom: return "Gloom"
        case .kaleidoscope: return "Kaleidoscope"
        case .wind: return "Wind"
        case .clouds: return "Clouds"
        case .differenceClouds: return "Difference Clouds"
        case .lensFlare: return "Lens Flare"
        case .vignette: return "Vignette"
        case .spotlight: return "Lighting Effects"
        case .cameraRaw: return "Camera Raw Filter"
        case .sepia: return "Sepia"
        case .noir: return "Noir"
        case .chrome: return "Chrome"
        case .fade: return "Fade"
        case .instant: return "Instant"
        case .mono: return "Mono"
        case .process: return "Process"
        case .tonal: return "Tonal"
        case .transfer: return "Transfer"
        case .thermal: return "Thermal"
        case .xray: return "X-Ray"
        case .highPass: return "High Pass"
        case .maximum: return "Maximum"
        case .minimum: return "Minimum"
        case .offset: return "Offset"
        case .filterGallery: return "Filter Gallery"
        case .lensCorrection: return "Lens Correction"
        case .smartSharpen: return "Smart Sharpen"
        case .displace: return "Displace"
        case .surfaceBlur: return "Surface Blur"
        case .dustAndScratches: return "Dust & Scratches"
        case .fieldBlur: return "Field Blur"
        case .irisBlur: return "Iris Blur"
        case .pathBlur: return "Path Blur"
        case .neuralFilter: return "Neural Filters"
        case .recipe: return "Recipe Filter"
        case .liquify: return "Liquify"
        }
    }

    package var params: [FilterParam] {
        switch self {
        case .gaussianBlur: return [FilterParam(key: "radius", label: "Radius", kind: .slider(0...250), defaultValue: 5, unit: "px")]
        case .boxBlur: return [FilterParam(key: "radius", label: "Radius", kind: .slider(1...200), defaultValue: 10, unit: "px")]
        case .motionBlur: return [FilterParam(key: "angle", label: "Angle", kind: .angle, defaultValue: 0),
                                  FilterParam(key: "distance", label: "Distance", kind: .slider(1...500), defaultValue: 20, unit: "px")]
        case .radialBlur: return [FilterParam(key: "amount", label: "Amount", kind: .slider(0...200), defaultValue: 20),
                                  FilterParam(key: "cx", label: "Center X", kind: .percentPoint, defaultValue: 0.5),
                                  FilterParam(key: "cy", label: "Center Y", kind: .percentPoint, defaultValue: 0.5)]
        case .spinBlur: return [FilterParam(key: "angle", label: "Blur Angle", kind: .slider(0...60), defaultValue: 10, unit: "°"),
                                FilterParam(key: "cx", label: "Center X", kind: .percentPoint, defaultValue: 0.5),
                                FilterParam(key: "cy", label: "Center Y", kind: .percentPoint, defaultValue: 0.5)]
        case .lensBlur: return [FilterParam(key: "radius", label: "Radius", kind: .slider(0...100), defaultValue: 15, unit: "px"),
                                FilterParam(key: "ring", label: "Ring Amount", kind: .slider(0...1), defaultValue: 0.2),
                                FilterParam(key: "ringSize", label: "Ring Size", kind: .slider(0...0.2), defaultValue: 0.1),
                                FilterParam(key: "softness", label: "Softness", kind: .slider(0...10), defaultValue: 1)]
        case .tiltShift: return [FilterParam(key: "radius", label: "Blur", kind: .slider(0...100), defaultValue: 15, unit: "px"),
                                 FilterParam(key: "focus", label: "Focus Position", kind: .percentPoint, defaultValue: 0.5),
                                 FilterParam(key: "width", label: "Focus Width", kind: .slider(0.02...1), defaultValue: 0.2),
                                 FilterParam(key: "feather", label: "Transition", kind: .slider(0.02...1), defaultValue: 0.25)]
        case .average: return []
        case .sharpen: return [FilterParam(key: "amount", label: "Amount", kind: .slider(0...5), defaultValue: 0.8)]
        case .unsharpMask: return [FilterParam(key: "amount", label: "Amount", kind: .slider(1...500), defaultValue: 100, unit: "%"),
                                   FilterParam(key: "radius", label: "Radius", kind: .slider(0.1...250), defaultValue: 2, unit: "px")]
        case .addNoise: return [FilterParam(key: "amount", label: "Amount", kind: .slider(0...100), defaultValue: 12, unit: "%"),
                                FilterParam(key: "mono", label: "Monochromatic", kind: .toggle, defaultValue: 0)]
        case .reduceNoise: return [FilterParam(key: "level", label: "Strength", kind: .slider(0...0.1), defaultValue: 0.02),
                                   FilterParam(key: "sharpness", label: "Preserve Details", kind: .slider(0...2), defaultValue: 0.4)]
        case .median: return [FilterParam(key: "passes", label: "Radius", kind: .slider(1...10), defaultValue: 2, unit: "px")]
        case .twirl: return [FilterParam(key: "angle", label: "Angle", kind: .slider(-999...999), defaultValue: 200, unit: "°"),
                             FilterParam(key: "radius", label: "Radius", kind: .slider(0.05...1.5), defaultValue: 0.5),
                             FilterParam(key: "cx", label: "Center X", kind: .percentPoint, defaultValue: 0.5),
                             FilterParam(key: "cy", label: "Center Y", kind: .percentPoint, defaultValue: 0.5)]
        case .pinch: return [FilterParam(key: "amount", label: "Amount", kind: .slider(-100...100), defaultValue: 50, unit: "%"),
                             FilterParam(key: "radius", label: "Radius", kind: .slider(0.05...1.5), defaultValue: 0.5)]
        case .spherize: return [FilterParam(key: "amount", label: "Amount", kind: .slider(-100...100), defaultValue: 60, unit: "%"),
                                FilterParam(key: "radius", label: "Radius", kind: .slider(0.05...1.5), defaultValue: 0.45),
                                FilterParam(key: "cx", label: "Center X", kind: .percentPoint, defaultValue: 0.5),
                                FilterParam(key: "cy", label: "Center Y", kind: .percentPoint, defaultValue: 0.5)]
        case .ripple: return [FilterParam(key: "amount", label: "Amount", kind: .slider(0...100), defaultValue: 8, unit: "px"),
                              FilterParam(key: "size", label: "Wavelength", kind: .slider(4...400), defaultValue: 40, unit: "px")]
        case .wave: return [FilterParam(key: "amount", label: "Amplitude", kind: .slider(0...200), defaultValue: 15, unit: "px"),
                            FilterParam(key: "size", label: "Wavelength", kind: .slider(4...1000), defaultValue: 120, unit: "px"),
                            FilterParam(key: "horizontal", label: "Horizontal", kind: .toggle, defaultValue: 1)]
        case .polarCoordinates: return [FilterParam(key: "mode", label: "Mode", kind: .choice(["Rectangular to Polar", "Polar to Rectangular"]), defaultValue: 0)]
        case .vortex: return [FilterParam(key: "angle", label: "Angle", kind: .slider(-1000...1000), defaultValue: 360, unit: "°"),
                              FilterParam(key: "radius", label: "Radius", kind: .slider(0.05...1.5), defaultValue: 0.4)]
        case .glass: return [FilterParam(key: "distortion", label: "Distortion", kind: .slider(0...200), defaultValue: 40),
                             FilterParam(key: "scale", label: "Texture Scale", kind: .slider(1...40), defaultValue: 8)]
        case .mosaic: return [FilterParam(key: "size", label: "Cell Size", kind: .slider(2...200), defaultValue: 16, unit: "px")]
        case .crystallize: return [FilterParam(key: "size", label: "Cell Size", kind: .slider(3...300), defaultValue: 20, unit: "px")]
        case .pointillize: return [FilterParam(key: "size", label: "Cell Size", kind: .slider(2...100), defaultValue: 10, unit: "px")]
        case .hexagon: return [FilterParam(key: "size", label: "Scale", kind: .slider(2...200), defaultValue: 16, unit: "px")]
        case .colorHalftone: return [FilterParam(key: "size", label: "Max Radius", kind: .slider(2...100), defaultValue: 8, unit: "px"),
                                     FilterParam(key: "angle", label: "Angle", kind: .angle, defaultValue: 45)]
        case .dotScreen: return [FilterParam(key: "size", label: "Width", kind: .slider(2...100), defaultValue: 8, unit: "px"),
                                 FilterParam(key: "angle", label: "Angle", kind: .angle, defaultValue: 0)]
        case .lineScreen: return [FilterParam(key: "size", label: "Width", kind: .slider(2...100), defaultValue: 8, unit: "px"),
                                  FilterParam(key: "angle", label: "Angle", kind: .angle, defaultValue: 45)]
        case .emboss: return [FilterParam(key: "angle", label: "Angle", kind: .angle, defaultValue: 135),
                              FilterParam(key: "height", label: "Height", kind: .slider(1...10), defaultValue: 2, unit: "px"),
                              FilterParam(key: "amount", label: "Amount", kind: .slider(1...500), defaultValue: 100, unit: "%")]
        case .findEdges: return [FilterParam(key: "intensity", label: "Intensity", kind: .slider(0.1...10), defaultValue: 2)]
        case .glowingEdges: return [FilterParam(key: "intensity", label: "Brightness", kind: .slider(0.5...20), defaultValue: 5),
                                    FilterParam(key: "width", label: "Edge Width", kind: .slider(0...5), defaultValue: 1)]
        case .edgeWork: return [FilterParam(key: "radius", label: "Radius", kind: .slider(0...20), defaultValue: 3)]
        case .solarize: return []
        case .oilPaint: return [FilterParam(key: "radius", label: "Stylization", kind: .slider(1...10), defaultValue: 4)]
        case .comic: return []
        case .lineOverlay: return [FilterParam(key: "edge", label: "Edge Intensity", kind: .slider(0...200), defaultValue: 1),
                                   FilterParam(key: "threshold", label: "Threshold", kind: .slider(0...1), defaultValue: 0.1),
                                   FilterParam(key: "contrast", label: "Contrast", kind: .slider(0.25...200), defaultValue: 50)]
        case .bloom: return [FilterParam(key: "radius", label: "Radius", kind: .slider(0...100), defaultValue: 10, unit: "px"),
                             FilterParam(key: "intensity", label: "Intensity", kind: .slider(0...2), defaultValue: 0.6)]
        case .gloom: return [FilterParam(key: "radius", label: "Radius", kind: .slider(0...100), defaultValue: 10, unit: "px"),
                             FilterParam(key: "intensity", label: "Intensity", kind: .slider(0...2), defaultValue: 0.6)]
        case .kaleidoscope: return [FilterParam(key: "count", label: "Segments", kind: .slider(2...24), defaultValue: 6),
                                    FilterParam(key: "angle", label: "Angle", kind: .angle, defaultValue: 0)]
        case .wind: return [FilterParam(key: "distance", label: "Strength", kind: .slider(1...200), defaultValue: 30, unit: "px"),
                            FilterParam(key: "direction", label: "Direction", kind: .choice(["From the Right", "From the Left"]), defaultValue: 0)]
        case .clouds: return [FilterParam(key: "scale", label: "Scale", kind: .slider(8...600), defaultValue: 160),
                              FilterParam(key: "seed", label: "Seed", kind: .slider(0...1000), defaultValue: 17)]
        case .differenceClouds: return [FilterParam(key: "scale", label: "Scale", kind: .slider(8...600), defaultValue: 160),
                                        FilterParam(key: "seed", label: "Seed", kind: .slider(0...1000), defaultValue: 42)]
        case .lensFlare: return [FilterParam(key: "brightness", label: "Brightness", kind: .slider(10...300), defaultValue: 100, unit: "%"),
                                 FilterParam(key: "cx", label: "Center X", kind: .percentPoint, defaultValue: 0.3),
                                 FilterParam(key: "cy", label: "Center Y", kind: .percentPoint, defaultValue: 0.3)]
        case .vignette: return [FilterParam(key: "intensity", label: "Intensity", kind: .slider(-1...1), defaultValue: 0.6),
                                FilterParam(key: "radius", label: "Radius", kind: .slider(0.05...1.5), defaultValue: 0.7),
                                FilterParam(key: "falloff", label: "Falloff", kind: .slider(0...1), defaultValue: 0.5)]
        case .spotlight: return [FilterParam(key: "brightness", label: "Intensity", kind: .slider(0...10), defaultValue: 3),
                                 FilterParam(key: "concentration", label: "Focus", kind: .slider(0.01...1), defaultValue: 0.2),
                                 FilterParam(key: "cx", label: "Target X", kind: .percentPoint, defaultValue: 0.5),
                                 FilterParam(key: "cy", label: "Target Y", kind: .percentPoint, defaultValue: 0.5),
                                 FilterParam(key: "height", label: "Height", kind: .slider(50...2000), defaultValue: 400)]
        case .cameraRaw: return [
            FilterParam(key: "temp", label: "Temperature", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "tint", label: "Tint", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "exposure", label: "Exposure", kind: .slider(-4...4), defaultValue: 0),
            FilterParam(key: "contrast", label: "Contrast", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "highlights", label: "Highlights", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "shadows", label: "Shadows", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "whites", label: "Whites", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "blacks", label: "Blacks", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "texture", label: "Texture", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "clarity", label: "Clarity", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "dehaze", label: "Dehaze", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "vibrance", label: "Vibrance", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "saturation", label: "Saturation", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "vignette", label: "Vignette", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "grain", label: "Grain", kind: .slider(0...100), defaultValue: 0),
        ]
        case .sepia: return [FilterParam(key: "intensity", label: "Intensity", kind: .slider(0...1), defaultValue: 0.9)]
        case .noir, .chrome, .fade, .instant, .mono, .process, .tonal, .transfer, .thermal, .xray: return []
        case .highPass: return [FilterParam(key: "radius", label: "Radius", kind: .slider(0.1...250), defaultValue: 10, unit: "px")]
        case .maximum: return [FilterParam(key: "radius", label: "Radius", kind: .slider(1...100), defaultValue: 3, unit: "px")]
        case .minimum: return [FilterParam(key: "radius", label: "Radius", kind: .slider(1...100), defaultValue: 3, unit: "px")]
        case .filterGallery: return []
        case .lensCorrection: return [
            // Lens profile (Edits/LensProfiles.swift)
            FilterParam(key: "profile", label: "Lens Profile", kind: .choice(LensProfiles.menuNames), defaultValue: 0),
            FilterParam(key: "profDistortion", label: "Profile Distortion", kind: .slider(0...200), defaultValue: 100, unit: "%"),
            FilterParam(key: "profCA", label: "Profile Chromatic Aberration", kind: .slider(0...200), defaultValue: 100, unit: "%"),
            FilterParam(key: "profVignette", label: "Profile Vignetting", kind: .slider(0...200), defaultValue: 100, unit: "%"),
            FilterParam(key: "distortion", label: "Remove Distortion", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "caRed", label: "Fix Red/Cyan Fringe", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "caBlue", label: "Fix Blue/Yellow Fringe", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "vignette", label: "Vignette Amount", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "vigMid", label: "Vignette Midpoint", kind: .slider(0...100), defaultValue: 50),
            FilterParam(key: "vertical", label: "Vertical Perspective", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "horizontal", label: "Horizontal Perspective", kind: .slider(-100...100), defaultValue: 0),
            FilterParam(key: "angle", label: "Angle", kind: .slider(-45...45), defaultValue: 0, unit: "°"),
            FilterParam(key: "scale", label: "Scale", kind: .slider(50...150), defaultValue: 100, unit: "%")]
        case .smartSharpen: return [
            FilterParam(key: "amount", label: "Amount", kind: .slider(0...500), defaultValue: 200, unit: "%"),
            FilterParam(key: "radius", label: "Radius", kind: .slider(0.1...64), defaultValue: 1.5, unit: "px"),
            FilterParam(key: "noise", label: "Reduce Noise", kind: .slider(0...100), defaultValue: 10, unit: "%"),
            FilterParam(key: "remove", label: "Remove", kind: .choice(["Gaussian Blur", "Lens Blur", "Motion Blur"]), defaultValue: 1),
            FilterParam(key: "angle", label: "Motion Angle", kind: .angle, defaultValue: 0),
            FilterParam(key: "shadowFade", label: "Shadows Fade", kind: .slider(0...100), defaultValue: 0, unit: "%"),
            FilterParam(key: "highlightFade", label: "Highlights Fade", kind: .slider(0...100), defaultValue: 0, unit: "%")]
        case .displace: return [
            FilterParam(key: "h", label: "Horizontal Scale", kind: .slider(-999...999), defaultValue: 10),
            FilterParam(key: "v", label: "Vertical Scale", kind: .slider(-999...999), defaultValue: 10),
            FilterParam(key: "tile", label: "Displacement Map", kind: .choice(["Stretch to Fit", "Tile"]), defaultValue: 0)]
        case .surfaceBlur: return [
            FilterParam(key: "radius", label: "Radius", kind: .slider(1...100), defaultValue: 5, unit: "px"),
            FilterParam(key: "threshold", label: "Threshold", kind: .slider(2...255), defaultValue: 15, unit: "levels")]
        case .dustAndScratches: return [
            FilterParam(key: "radius", label: "Radius", kind: .slider(1...16), defaultValue: 1, unit: "px"),
            FilterParam(key: "threshold", label: "Threshold", kind: .slider(0...255), defaultValue: 0, unit: "levels")]
        case .fieldBlur: return [FilterParam(key: "blur", label: "Blur (selected pin)", kind: .slider(0...500), defaultValue: 15, unit: "px")]
        case .irisBlur: return [
            FilterParam(key: "blur", label: "Blur", kind: .slider(0...500), defaultValue: 15, unit: "px"),
            FilterParam(key: "focus", label: "Focus", kind: .slider(0...100), defaultValue: 100, unit: "%"),
            FilterParam(key: "rx", label: "Width", kind: .slider(0.02...1.5), defaultValue: 0.3),
            FilterParam(key: "ry", label: "Height", kind: .slider(0.02...1.5), defaultValue: 0.2),
            FilterParam(key: "rotation", label: "Rotation", kind: .angle, defaultValue: 0),
            FilterParam(key: "feather", label: "Transition", kind: .slider(0.05...1), defaultValue: 0.5)]
        case .pathBlur: return [
            FilterParam(key: "speed", label: "Speed", kind: .slider(0...500), defaultValue: 50, unit: "%"),
            FilterParam(key: "taper", label: "Taper", kind: .slider(0...100), defaultValue: 0, unit: "%")]
        case .offset: return [FilterParam(key: "dx", label: "Horizontal", kind: .slider(-2000...2000), defaultValue: 100, unit: "px"),
                              FilterParam(key: "dy", label: "Vertical", kind: .slider(-2000...2000), defaultValue: 100, unit: "px"),
                              FilterParam(key: "wrap", label: "Wrap Around", kind: .toggle, defaultValue: 1)]
        case .neuralFilter, .recipe, .liquify: return []
        }
    }

    /// Filters that don't need a parameter dialog.
    package var isImmediate: Bool { params.isEmpty && self != .filterGallery && self != .liquify && self != .fieldBlur && self != .irisBlur && self != .pathBlur }

    /// Render filters that need the foreground/background colors.
    package var usesColors: Bool { self == .clouds || self == .differenceClouds }

    package static func byCategory(_ c: FilterCategory) -> [FilterKind] { allCases.filter { $0.category == c && $0 != .neuralFilter && $0 != .recipe && $0 != .liquify } }
}

// MARK: - Filter Gallery & pins

package struct GalleryEntry: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var filter: GalleryFilter
    package var values: [String: Double]
    package var visible = true

    package init(_ f: GalleryFilter) {
        filter = f
        values = Dictionary(uniqueKeysWithValues: f.params.map { ($0.key, $0.defaultValue) })
    }
}

package struct FilterPin: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var x: Double       // normalized canvas coords (0…1, y down)
    package var y: Double
    package var value: Double   // blur radius (Field Blur) / unused
    package init(id: UUID = UUID(), x: Double, y: Double, value: Double) {
        self.id = id; self.x = x; self.y = y; self.value = value
    }
}

extension FilterInstance {
    private enum Keys: String, CodingKey { case id, kind, values, colors, enabled, opacity, blendMode, gallery, points, payload, recipe, mask, liquify }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(kind: try c.decode(FilterKind.self, forKey: .kind))
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        values = try c.decodeIfPresent([String: Double].self, forKey: .values) ?? values
        colors = try c.decodeIfPresent([RGBA].self, forKey: .colors) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        blendMode = try c.decodeIfPresent(BlendMode.self, forKey: .blendMode) ?? .normal
        gallery = try c.decodeIfPresent([GalleryEntry].self, forKey: .gallery) ?? []
        points = try c.decodeIfPresent([FilterPin].self, forKey: .points) ?? []
        payload = try c.decodeIfPresent(PixelBuffer.self, forKey: .payload)
        recipe = try? c.decodeIfPresent(RecipeGraph.self, forKey: .recipe)
        mask = try? c.decodeIfPresent(LayerMask.self, forKey: .mask)
        liquify = try? c.decodeIfPresent(LiquifyMesh.self, forKey: .liquify)
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind); try c.encode(values, forKey: .values)
        try c.encode(colors, forKey: .colors); try c.encode(enabled, forKey: .enabled); try c.encode(opacity, forKey: .opacity)
        try c.encode(blendMode, forKey: .blendMode); try c.encode(gallery, forKey: .gallery); try c.encode(points, forKey: .points)
        try c.encodeIfPresent(payload, forKey: .payload)
        try c.encodeIfPresent(recipe, forKey: .recipe)
        try c.encodeIfPresent(mask, forKey: .mask)
        try c.encodeIfPresent(liquify, forKey: .liquify)
    }

    package static func == (a: FilterInstance, b: FilterInstance) -> Bool {
        a.id == b.id && a.kind == b.kind && a.values == b.values && a.colors == b.colors && a.enabled == b.enabled && a.opacity == b.opacity &&
            a.blendMode == b.blendMode && a.gallery == b.gallery && a.points == b.points && a.payload === b.payload && a.recipe == b.recipe &&
            a.mask?.buffer === b.mask?.buffer && a.mask?.origin == b.mask?.origin && a.mask?.isEnabled == b.mask?.isEnabled &&
            a.liquify == b.liquify
    }
}

extension FilterInstance {
    /// Loop count from a parameter value. Scripts, recorded actions and files can carry negative or non-finite values,
    /// and `0..<n` traps for n < 0 (as does `Int(.nan)`).
    package static func count(_ v: Double, limit: Int = 50) -> Int { v.isFinite ? max(0, min(limit, Int(v))) : 0 }
}
