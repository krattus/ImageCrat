import Foundation

package enum AdjustmentKind: String, Codable, CaseIterable, Identifiable {
    case brightnessContrast, levels, curves, exposure
    case vibrance, hueSaturation, colorBalance, blackWhite, photoFilter, channelMixer
    case invert, posterize, threshold, gradientMap, selectiveColor
    case shadowsHighlights, desaturate, colorLookup
    // Destructive-only (Image > Adjustments dialogs)
    case replaceColor, matchColor, hdrToning
    // Camera Raw style panels (EditsAdjustments.swift); settings live in `params`
    case colorWB, clarity, dehaze, grain, light

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .brightnessContrast: return "Brightness/Contrast"
        case .levels: return "Levels"
        case .curves: return "Curves"
        case .exposure: return "Exposure"
        case .vibrance: return "Vibrance"
        case .hueSaturation: return "Hue/Saturation"
        case .colorBalance: return "Color Balance"
        case .blackWhite: return "Black & White"
        case .photoFilter: return "Photo Filter"
        case .channelMixer: return "Channel Mixer"
        case .invert: return "Invert"
        case .posterize: return "Posterize"
        case .threshold: return "Threshold"
        case .gradientMap: return "Gradient Map"
        case .selectiveColor: return "Selective Color"
        case .shadowsHighlights: return "Shadows/Highlights"
        case .desaturate: return "Desaturate"
        case .colorLookup: return "Color Lookup"
        case .replaceColor: return "Replace Color"
        case .matchColor: return "Match Color"
        case .hdrToning: return "HDR Toning"
        case .colorWB, .clarity, .dehaze, .grain, .light: return editsDisplayName
        }
    }

    package var symbol: String {
        switch self {
        case .brightnessContrast: return "sun.max"
        case .levels: return "chart.bar"
        case .curves: return "point.topleft.down.to.point.bottomright.curvepath"
        case .exposure: return "plusminus.circle"
        case .vibrance: return "triangle"
        case .hueSaturation: return "drop.halffull"
        case .colorBalance: return "scalemass"
        case .blackWhite: return "circle.lefthalf.filled"
        case .photoFilter: return "camera.filters"
        case .channelMixer: return "slider.horizontal.3"
        case .invert: return "circle.righthalf.filled.inverse"
        case .posterize: return "square.stack.3d.down.right"
        case .threshold: return "square.split.diagonal"
        case .gradientMap: return "square.fill.and.line.vertical.and.square"
        case .selectiveColor: return "paintpalette"
        case .shadowsHighlights: return "circle.dotted"
        case .desaturate: return "circle.slash"
        case .colorLookup: return "cube"
        case .replaceColor: return "eyedropper.halffull"
        case .matchColor: return "square.on.square"
        case .hdrToning: return "camera.aperture"
        case .colorWB, .clarity, .dehaze, .grain, .light: return editsSymbol
        }
    }

    /// Kinds offered as adjustment layers.
    package static let layerKinds: [AdjustmentKind] = [.brightnessContrast, .levels, .curves, .exposure, .vibrance, .hueSaturation, .colorBalance,
                                               .blackWhite, .photoFilter, .channelMixer, .colorLookup, .invert, .posterize, .threshold,
                                               .gradientMap, .selectiveColor] + AdjustmentKind.editsLayerKinds
}

package struct LevelsChannel: Codable, Equatable {
    package var inBlack: Double = 0      // 0...255
    package var inWhite: Double = 255
    package var gamma: Double = 1        // 0.1...9.99
    package var outBlack: Double = 0
    package var outWhite: Double = 255

    package var isIdentity: Bool { inBlack == 0 && inWhite == 255 && gamma == 1 && outBlack == 0 && outWhite == 255 }

    package func apply(_ v: Double) -> Double {
        let x = v * 255
        var t = (x - inBlack) / max(1, inWhite - inBlack)
        t = clamp(t, 0, 1)
        t = pow(t, 1 / max(0.01, gamma))
        return (outBlack + t * (outWhite - outBlack)) / 255
    }
    package init(inBlack: Double = 0, inWhite: Double = 255, gamma: Double = 1, outBlack: Double = 0, outWhite: Double = 255) {
        self.inBlack = inBlack; self.inWhite = inWhite; self.gamma = gamma; self.outBlack = outBlack; self.outWhite = outWhite
    }
}

package struct CurvePoints: Codable, Equatable {
    package var points: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]   // 0...1

    package var isIdentity: Bool { points.count == 2 && points[0] == .zero && points[1] == CGPoint(x: 1, y: 1) }

    /// Monotone cubic interpolation lookup table.
    package func lut(_ n: Int = 256) -> [Double] {
        let pts = points.sorted { $0.x < $1.x }
        guard pts.count >= 2 else { return (0..<n).map { Double($0) / Double(n - 1) } }
        let xs = pts.map { Double($0.x) }, ys = pts.map { Double($0.y) }
        let k = xs.count
        var d = [Double](repeating: 0, count: k - 1)
        var m = [Double](repeating: 0, count: k)
        for i in 0..<(k - 1) { d[i] = (ys[i + 1] - ys[i]) / max(1e-9, xs[i + 1] - xs[i]) }
        m[0] = d[0]; m[k - 1] = d[k - 2]
        if k > 2 { for i in 1..<(k - 1) { m[i] = (d[i - 1] * d[i] <= 0) ? 0 : (d[i - 1] + d[i]) / 2 } }
        for i in 0..<(k - 1) {
            if abs(d[i]) < 1e-12 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 { let t = 3 / sqrt(s); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        var out = [Double](repeating: 0, count: n)
        for j in 0..<n {
            let x = Double(j) / Double(n - 1)
            if x <= xs[0] { out[j] = ys[0]; continue }
            if x >= xs[k - 1] { out[j] = ys[k - 1]; continue }
            var i = 0
            while i < k - 2 && x > xs[i + 1] { i += 1 }
            let h = xs[i + 1] - xs[i]
            let t = (x - xs[i]) / h
            let t2 = t * t, t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t, h01 = -2 * t3 + 3 * t2, h11 = t3 - t2
            out[j] = clamp(h00 * ys[i] + h10 * h * m[i] + h01 * ys[i + 1] + h11 * h * m[i + 1], 0, 1)
        }
        return out
    }
    package init(points: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]) {
        self.points = points
    }
}

package struct ToneTriple: Codable, Equatable {
    package var cyanRed: Double = 0        // -100...100
    package var magentaGreen: Double = 0
    package var yellowBlue: Double = 0
    package init(cyanRed: Double = 0, magentaGreen: Double = 0, yellowBlue: Double = 0) {
        self.cyanRed = cyanRed; self.magentaGreen = magentaGreen; self.yellowBlue = yellowBlue
    }
}

package struct SelectiveColorEntry: Codable, Equatable {
    package var cyan: Double = 0, magenta: Double = 0, yellow: Double = 0, black: Double = 0  // -100...100
    package init(cyan: Double = 0, magenta: Double = 0, yellow: Double = 0, black: Double = 0) {
        self.cyan = cyan; self.magenta = magenta; self.yellow = yellow; self.black = black
    }
}

package struct AdjustmentSettings: Codable, Equatable {
    package var kind: AdjustmentKind

    // Brightness / contrast
    package var brightness: Double = 0     // -150...150
    package var contrast: Double = 0       // -50...100
    // Levels: master, r, g, b
    package var levels: [LevelsChannel] = Array(repeating: LevelsChannel(), count: 4)
    // Curves: master, r, g, b
    package var curves: [CurvePoints] = Array(repeating: CurvePoints(), count: 4)
    // Exposure
    package var exposure: Double = 0       // -20...20
    package var offset: Double = 0         // -0.5...0.5
    package var gamma: Double = 1          // 0.01...9.99
    // Vibrance
    package var vibrance: Double = 0       // -100...100
    package var saturation: Double = 0     // -100...100
    // Hue / saturation
    package var hue: Double = 0            // -180...180
    package var hsSaturation: Double = 0   // -100...100
    package var lightness: Double = 0      // -100...100
    package var colorize = false
    /// Per-range edits: reds, yellows, greens, cyans, blues, magentas.
    package var hsRanges: [HueRange] = HueRange.defaults
    // Color balance
    package var shadows = ToneTriple()
    package var midtones = ToneTriple()
    package var highlights = ToneTriple()
    package var preserveLuminosity = true
    // Black & White (percent weights)
    package var bwReds: Double = 40, bwYellows: Double = 60, bwGreens: Double = 40, bwCyans: Double = 60, bwBlues: Double = 20, bwMagentas: Double = 80
    package var bwTint = false
    package var bwTintColor = RGBA(hex: "E1D3B3")!
    // Photo filter
    package var filterColor = RGBA(hex: "EC8A00")!
    package var density: Double = 25       // %
    // Channel mixer rows: [r, g, b, constant] percentages
    package var mixRed: [Double] = [100, 0, 0, 0]
    package var mixGreen: [Double] = [0, 100, 0, 0]
    package var mixBlue: [Double] = [0, 0, 100, 0]
    package var monochrome = false
    // Posterize / threshold
    package var posterizeLevels: Double = 4
    package var thresholdLevel: Double = 128
    // Gradient map
    package var gradient = ColorGradient.twoColor(.black, .white, name: "Black, White")
    package var gradientReverse = false
    // Selective color: reds, yellows, greens, cyans, blues, magentas, whites, neutrals, blacks
    package var selective: [SelectiveColorEntry] = Array(repeating: SelectiveColorEntry(), count: 9)
    package var selectiveAbsolute = false
    // Shadows/highlights
    package var shAmountShadows: Double = 35
    package var shAmountHighlights: Double = 0
    package var shRadius: Double = 30
    // Color lookup
    package var lookName: String = "Warm Film"
    // Replace Color / Match Color / HDR Toning (destructive dialogs)
    package var replace = ReplaceColorSettings()
    package var match = MatchColorSettings()
    package var hdr = HDRToningSettings()
    /// Named values for the Color / Clarity / Dehaze / Grain / Light kinds (see EditsAdjustments.swift).
    package var params: [String: Double] = [:]

    package init(kind: AdjustmentKind) {
        self.kind = kind
    }

    package static let lookNames = ["Warm Film", "Cool Teal", "Teal & Orange", "Faded", "Bleach Bypass", "Crisp Winter", "Golden Hour", "Moonlight", "Vintage", "Cross Process"]
}

// tolerant-decoding:AdjustmentSettings (missing keys fall back to defaults)
extension AdjustmentSettings {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(AdjustmentKind.self, forKey: .kind)
        let d = AdjustmentSettings(kind: kind)
        self.init(kind: kind)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        brightness = v(.brightness, d.brightness)
        contrast = v(.contrast, d.contrast)
        levels = v(.levels, d.levels)
        curves = v(.curves, d.curves)
        exposure = v(.exposure, d.exposure)
        offset = v(.offset, d.offset)
        gamma = v(.gamma, d.gamma)
        vibrance = v(.vibrance, d.vibrance)
        saturation = v(.saturation, d.saturation)
        hue = v(.hue, d.hue)
        hsSaturation = v(.hsSaturation, d.hsSaturation)
        lightness = v(.lightness, d.lightness)
        colorize = v(.colorize, d.colorize)
        hsRanges = v(.hsRanges, d.hsRanges)
        shadows = v(.shadows, d.shadows)
        midtones = v(.midtones, d.midtones)
        highlights = v(.highlights, d.highlights)
        preserveLuminosity = v(.preserveLuminosity, d.preserveLuminosity)
        bwReds = v(.bwReds, d.bwReds); bwYellows = v(.bwYellows, d.bwYellows); bwGreens = v(.bwGreens, d.bwGreens)
        bwCyans = v(.bwCyans, d.bwCyans); bwBlues = v(.bwBlues, d.bwBlues); bwMagentas = v(.bwMagentas, d.bwMagentas)
        bwTint = v(.bwTint, d.bwTint)
        bwTintColor = v(.bwTintColor, d.bwTintColor)
        filterColor = v(.filterColor, d.filterColor)
        density = v(.density, d.density)
        mixRed = v(.mixRed, d.mixRed); mixGreen = v(.mixGreen, d.mixGreen); mixBlue = v(.mixBlue, d.mixBlue)
        monochrome = v(.monochrome, d.monochrome)
        posterizeLevels = v(.posterizeLevels, d.posterizeLevels)
        thresholdLevel = v(.thresholdLevel, d.thresholdLevel)
        gradient = v(.gradient, d.gradient)
        gradientReverse = v(.gradientReverse, d.gradientReverse)
        selective = v(.selective, d.selective)
        selectiveAbsolute = v(.selectiveAbsolute, d.selectiveAbsolute)
        shAmountShadows = v(.shAmountShadows, d.shAmountShadows)
        shAmountHighlights = v(.shAmountHighlights, d.shAmountHighlights)
        shRadius = v(.shRadius, d.shRadius)
        lookName = v(.lookName, d.lookName)
        replace = v(.replace, d.replace)
        match = v(.match, d.match)
        hdr = v(.hdr, d.hdr)
        params = v(.params, d.params)
        // Keep fixed-size arrays well formed.
        func pad<T>(_ a: [T], _ def: [T]) -> [T] { a.count >= def.count ? Array(a.prefix(def.count)) : a + def[a.count...] }
        levels = pad(levels, d.levels); curves = pad(curves, d.curves); selective = pad(selective, d.selective)
        hsRanges = pad(hsRanges, d.hsRanges)
        if mixRed.count < 4 { mixRed = d.mixRed }
        if mixGreen.count < 4 { mixGreen = d.mixGreen }
        if mixBlue.count < 4 { mixBlue = d.mixBlue }
    }
}
// end-tolerant
