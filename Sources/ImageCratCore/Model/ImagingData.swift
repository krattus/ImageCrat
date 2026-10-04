import Foundation

/// Per-document data for the Bitmap / Indexed / Duotone / Multichannel modes and spot channels.
/// Stored in `DocumentState.imaging` so every change is part of the undo history.
package struct ImagingData: Codable {
    /// Indexed Color: the colour table (≤ 256 entries). Pixels hold exactly these colours.
    package var colorTable: [RGBA]? = nil
    /// Indexed Color: index of the entry that is written as transparent (GIF / PNG-8), if any.
    package var transparentIndex: Int? = nil
    /// Duotone (monotone … quadtone) inks and curves. Pixels hold the gray data.
    package var duotone: DuotoneSettings? = nil
    /// Spot channels. Each entry describes an `AlphaChannel` (same id) whose white areas carry the ink.
    package var spots: [SpotInfo] = []

    package init() {}

    private enum Keys: String, CodingKey { case colorTable, transparentIndex, duotone, spots }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        colorTable = try? c.decodeIfPresent([RGBA].self, forKey: .colorTable)
        transparentIndex = try? c.decodeIfPresent(Int.self, forKey: .transparentIndex)
        duotone = try? c.decodeIfPresent(DuotoneSettings.self, forKey: .duotone)
        spots = ((try? c.decodeIfPresent([SpotInfo].self, forKey: .spots)) ?? nil) ?? []
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(colorTable, forKey: .colorTable)
        try c.encodeIfPresent(transparentIndex, forKey: .transparentIndex)
        try c.encodeIfPresent(duotone, forKey: .duotone)
        try c.encode(spots, forKey: .spots)
    }
}

/// Spot colour channel metadata (the pixels live in `DocumentState.alphaChannels`).
package struct SpotInfo: Codable, Equatable, Identifiable {
    package var id: UUID
    package var ink: RGBA
    /// 0 = transparent ink (multiplies), 1 = fully opaque ink.
    package var solidity: Double = 0
    package var visible = true

    package init(id: UUID, ink: RGBA, solidity: Double, visible: Bool = true) {
        self.id = id; self.ink = ink; self.solidity = solidity; self.visible = visible
    }
    private enum Keys: String, CodingKey { case id, ink, solidity, visible }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        ink = (try? c.decode(RGBA.self, forKey: .ink)) ?? .black
        solidity = (try? c.decode(Double.self, forKey: .solidity)) ?? 0
        visible = (try? c.decode(Bool.self, forKey: .visible)) ?? true
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.encode(ink, forKey: .ink)
        try c.encode(solidity, forKey: .solidity); try c.encode(visible, forKey: .visible)
    }
}

package struct DuotoneInk: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var name: String
    package var color: RGBA
    /// Ink coverage (y) for tone (x, 0 = paper white … 1 = full shadow).
    package var curve = CurvePoints()

    package init(name: String, color: RGBA, curve: CurvePoints = CurvePoints()) {
        self.name = name; self.color = color; self.curve = curve
    }
    private enum Keys: String, CodingKey { case id, name, color, curve }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Ink"
        color = (try? c.decode(RGBA.self, forKey: .color)) ?? .black
        curve = (try? c.decode(CurvePoints.self, forKey: .curve)) ?? CurvePoints()
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(color, forKey: .color); try c.encode(curve, forKey: .curve)
    }
}

package enum DuotoneType: Int, CaseIterable, Identifiable {
    case monotone = 1, duotone, tritone, quadtone
    package var id: Int { rawValue }
    package var name: String { ["Monotone", "Duotone", "Tritone", "Quadtone"][rawValue - 1] }
}

package struct DuotoneSettings: Codable, Equatable {
    package var inks: [DuotoneInk]

    package var type: DuotoneType { DuotoneType(rawValue: max(1, min(4, inks.count))) ?? .monotone }

    package static let presets: [(String, DuotoneSettings)] = [
        ("Black Monotone", DuotoneSettings(inks: [DuotoneInk(name: "Black", color: .black)])),
        ("Sepia Duotone", DuotoneSettings(inks: [
            DuotoneInk(name: "Black", color: .black, curve: CurvePoints(points: [.zero, CGPoint(x: 0.5, y: 0.28), CGPoint(x: 1, y: 0.92)])),
            DuotoneInk(name: "Warm Brown", color: RGBA(hex: "A0652A")!, curve: CurvePoints(points: [.zero, CGPoint(x: 0.5, y: 0.62), CGPoint(x: 1, y: 0.85)])),
        ])),
        ("Cyanotype Duotone", DuotoneSettings(inks: [
            DuotoneInk(name: "Prussian", color: RGBA(hex: "1D3F6E")!),
            DuotoneInk(name: "Cyan", color: RGBA(hex: "4FA3C7")!, curve: CurvePoints(points: [.zero, CGPoint(x: 0.4, y: 0.5), CGPoint(x: 1, y: 0.6)])),
        ])),
        ("Warm Tritone", DuotoneSettings(inks: [
            DuotoneInk(name: "Black", color: .black, curve: CurvePoints(points: [.zero, CGPoint(x: 0.6, y: 0.3), CGPoint(x: 1, y: 0.95)])),
            DuotoneInk(name: "Orange", color: RGBA(hex: "E08A2E")!, curve: CurvePoints(points: [.zero, CGPoint(x: 0.5, y: 0.45), CGPoint(x: 1, y: 0.6)])),
            DuotoneInk(name: "Yellow", color: RGBA(hex: "F4D35E")!, curve: CurvePoints(points: [.zero, CGPoint(x: 0.3, y: 0.35), CGPoint(x: 1, y: 0.4)])),
        ])),
        ("Cool Quadtone", DuotoneSettings(inks: [
            DuotoneInk(name: "Black", color: .black, curve: CurvePoints(points: [.zero, CGPoint(x: 0.6, y: 0.3), CGPoint(x: 1, y: 0.95)])),
            DuotoneInk(name: "Slate", color: RGBA(hex: "4A5A70")!, curve: CurvePoints(points: [.zero, CGPoint(x: 0.5, y: 0.45), CGPoint(x: 1, y: 0.7)])),
            DuotoneInk(name: "Teal", color: RGBA(hex: "3C9D9B")!, curve: CurvePoints(points: [.zero, CGPoint(x: 0.4, y: 0.3), CGPoint(x: 1, y: 0.4)])),
            DuotoneInk(name: "Pale Blue", color: RGBA(hex: "B9D6F2")!, curve: CurvePoints(points: [.zero, CGPoint(x: 0.25, y: 0.3), CGPoint(x: 1, y: 0.3)])),
        ])),
    ]

    /// Output colour (sRGB) for a gray value (0 = black … 1 = white): inks overprint multiplicatively.
    package func color(forGray g: Double, luts: [[Double]]? = nil) -> (Double, Double, Double) {
        let t = clamp(1 - g, 0, 1)
        var r = 1.0, gg = 1.0, b = 1.0
        for (i, ink) in inks.enumerated() {
            let cov: Double
            if let l = luts?[i] { cov = l[min(l.count - 1, Int((t * Double(l.count - 1)).rounded()))] } else { cov = clamp(ink.curve.lut(256)[Int(t * 255)], 0, 1) }
            r *= 1 - cov * (1 - ink.color.r)
            gg *= 1 - cov * (1 - ink.color.g)
            b *= 1 - cov * (1 - ink.color.b)
        }
        return (r, gg, b)
    }
    package init(inks: [DuotoneInk]) {
        self.inks = inks
    }
}

extension DocumentState {
    package var imagingData: ImagingData { imaging ?? ImagingData() }

    package func spotInfo(_ id: UUID) -> SpotInfo? { imaging?.spots.first { $0.id == id } }
    package func isSpotChannel(_ id: UUID) -> Bool { spotInfo(id) != nil }

    /// Spot channels (pixels + ink) in channel order.
    package var spotChannels: [(AlphaChannel, SpotInfo)] {
        guard let spots = imaging?.spots, !spots.isEmpty else { return [] }
        return alphaChannels.compactMap { ch in spots.first { $0.id == ch.id }.map { (ch, $0) } }
    }
}

/// Smart object Stack Modes (Layer ▸ Smart Objects ▸ Stack Mode).
package enum StackMode: String, CaseIterable, Identifiable {
    case none = "None", entropy = "Entropy", kurtosis = "Kurtosis", maximum = "Maximum", mean = "Mean", median = "Median"
    case minimum = "Minimum", range = "Range", skewness = "Skewness", stdDev = "Standard Deviation", summation = "Summation", variance = "Variance"
    package var id: String { rawValue }
    package var shaderIndex: Int32 {
        switch self {
        case .none, .mean: return 0
        case .median: return 1
        case .maximum: return 2
        case .minimum: return 3
        case .range: return 4
        case .summation: return 5
        case .variance: return 6
        case .stdDev: return 7
        case .entropy: return 8
        case .skewness: return 9
        case .kurtosis: return 10
        }
    }
}

extension SmartObjectContent {
    package var stack: StackMode {
        get { stackMode.flatMap(StackMode.init(rawValue:)) ?? .none }
        set { stackMode = newValue == .none ? nil : newValue.rawValue }
    }
}
