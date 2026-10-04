import Foundation

// MARK: - Settings

/// Live Repeater: a group that renders N transformed instances of its children (the "source").
/// Everything is measured relative to the source's bounds, so moving or editing the source moves / updates every instance.
package struct RepeaterSettings: Codable, Equatable {
    package enum Mode: String, Codable, CaseIterable, Identifiable {
        case grid = "Grid", radial = "Radial", path = "Along Shape", mirror = "Mirror", scatter = "Scatter"
        package var id: String { rawValue }
    }
    package enum Mirror: String, Codable, CaseIterable, Identifiable {
        case horizontal = "Left | Right", vertical = "Top | Bottom", four = "4-Way", kaleidoscope = "Kaleidoscope"
        package var id: String { rawValue }
    }
    package enum Region: String, Codable, CaseIterable, Identifiable {
        case circle = "Circle", rectangle = "Rectangle", custom = "Custom Shape", captured = "Selection / Path"
        package var id: String { rawValue }
    }

    package var mode: Mode = .grid
    // Grid
    package var columns = 3
    package var rows = 3
    package var gapX: Double = 20
    package var gapY: Double = 20
    /// Brick offset of every other row, in % of the column pitch.
    package var stagger: Double = 0
    // Radial / along shape / scatter
    package var count = 8
    package var radius: Double = 160
    package var arc: Double = 360
    package var rotateInstances = true
    // Along shape (an `ArrangeSettings.Shape` raw value)
    package var shape: String = ArrangeSettings.Shape.circle.rawValue
    package var shapeWidth: Double = 400
    package var shapeHeight: Double = 400
    package var shapeRotation: Double = 0
    package var sides = 6
    package var starInset: Double = 0.5
    package var arcAngle: Double = 180
    package var turns: Double = 2
    package var waves: Double = 2
    package var customID = "heart"
    package var followPath = false
    /// Outline captured from the active path or the selection when the repeater was made, relative to the source centre.
    package var captured: VectorPath? = nil
    /// The captured outline came from a selection (plain loops filled even-odd) rather than from a path with its own operations.
    package var capturedEvenOdd = false
    // Mirror
    package var mirror: Mirror = .horizontal
    package var mirrorGap: Double = 20
    package var segments = 6
    // Scatter
    package var region: Region = .circle
    package var regionWidth: Double = 500
    package var regionHeight: Double = 500
    package var minDistance: Double = 0
    package var noOverlap = true
    // Progressive per-instance transform
    package var stepX: Double = 0
    package var stepY: Double = 0
    package var stepRotation: Double = 0
    /// Size of each instance relative to the previous one, in %.
    package var stepScale: Double = 100
    /// Opacity lost per instance, in %.
    package var stepOpacity: Double = 0
    // Random per-instance variation
    package var varyHue: Double = 0
    package var varyBrightness: Double = 0
    package var varyRotation: Double = 0
    package var varyScale: Double = 0
    package var seed = 1
    /// The whole repeater was flipped (Flip Horizontal / Vertical, negative scale): the pattern runs the other way.
    package var flipX = false
    package var flipY = false

    package static let maxInstances = 400

    /// Makes the pattern follow an axis-aligned scale / flip applied to the repeater as a whole:
    /// distances scale with the source, a negative factor mirrors the pattern.
    package mutating func follow(kx: Double, ky: Double) {
        let ax = abs(kx), ay = abs(ky), k = (ax * ay).squareRoot()
        gapX *= ax; gapY *= ay; stepX *= ax; stepY *= ay
        shapeWidth *= ax; shapeHeight *= ay; regionWidth *= ax; regionHeight *= ay
        radius *= k; mirrorGap *= k; minDistance *= k
        if let c = captured { captured = c.applying(CGAffineTransform(scaleX: CGFloat(ax), y: CGFloat(ay))) }
        if kx < 0 { flipX.toggle() }
        if ky < 0 { flipY.toggle() }
    }

    /// Number of instances the settings ask for (before scatter rejection).
    package var requestedCount: Int {
        let n: Int
        switch mode {
        case .grid: n = max(1, columns) * max(1, rows)
        case .radial, .path, .scatter: n = max(1, count)
        case .mirror:
            switch mirror {
            case .horizontal, .vertical: n = 2
            case .four: n = 4
            case .kaleidoscope: n = 2 * max(2, segments)
            }
        }
        return min(RepeaterSettings.maxInstances, n)
    }

    package var summary: String {
        switch mode {
        case .grid: return "Grid \(max(1, columns)) × \(max(1, rows))"
        case .radial: return "Radial × \(max(1, count))"
        case .path: return "\(shape) × \(max(1, count))"
        case .mirror: return "Mirror \(mirror.rawValue)"
        case .scatter: return "Scatter × \(max(1, count))"
        }
    }
    package init(mode: Mode = .grid, columns: Int = 3, rows: Int = 3, gapX: Double = 20, gapY: Double = 20, stagger: Double = 0, count: Int = 8, radius: Double = 160, arc: Double = 360, rotateInstances: Bool = true, shape: String = ArrangeSettings.Shape.circle.rawValue, shapeWidth: Double = 400, shapeHeight: Double = 400, shapeRotation: Double = 0, sides: Int = 6, starInset: Double = 0.5, arcAngle: Double = 180, turns: Double = 2, waves: Double = 2, customID: String = "heart", followPath: Bool = false, captured: VectorPath? = nil, capturedEvenOdd: Bool = false, mirror: Mirror = .horizontal, mirrorGap: Double = 20, segments: Int = 6, region: Region = .circle, regionWidth: Double = 500, regionHeight: Double = 500, minDistance: Double = 0, noOverlap: Bool = true, stepX: Double = 0, stepY: Double = 0, stepRotation: Double = 0, stepScale: Double = 100, stepOpacity: Double = 0, varyHue: Double = 0, varyBrightness: Double = 0, varyRotation: Double = 0, varyScale: Double = 0, seed: Int = 1, flipX: Bool = false, flipY: Bool = false) {
        self.mode = mode; self.columns = columns; self.rows = rows; self.gapX = gapX; self.gapY = gapY; self.stagger = stagger; self.count = count; self.radius = radius; self.arc = arc; self.rotateInstances = rotateInstances; self.shape = shape; self.shapeWidth = shapeWidth; self.shapeHeight = shapeHeight; self.shapeRotation = shapeRotation; self.sides = sides; self.starInset = starInset; self.arcAngle = arcAngle; self.turns = turns; self.waves = waves; self.customID = customID; self.followPath = followPath; self.captured = captured; self.capturedEvenOdd = capturedEvenOdd; self.mirror = mirror; self.mirrorGap = mirrorGap; self.segments = segments; self.region = region; self.regionWidth = regionWidth; self.regionHeight = regionHeight; self.minDistance = minDistance; self.noOverlap = noOverlap; self.stepX = stepX; self.stepY = stepY; self.stepRotation = stepRotation; self.stepScale = stepScale; self.stepOpacity = stepOpacity; self.varyHue = varyHue; self.varyBrightness = varyBrightness; self.varyRotation = varyRotation; self.varyScale = varyScale; self.seed = seed; self.flipX = flipX; self.flipY = flipY
    }
}

// tolerant decoding: missing keys fall back to defaults (older documents keep opening when fields are added)
extension RepeaterSettings {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RepeaterSettings()
        mode = c.tdValue(.mode, d.mode)
        columns = c.tdValue(.columns, d.columns); rows = c.tdValue(.rows, d.rows)
        gapX = c.tdValue(.gapX, d.gapX); gapY = c.tdValue(.gapY, d.gapY); stagger = c.tdValue(.stagger, d.stagger)
        count = c.tdValue(.count, d.count); radius = c.tdValue(.radius, d.radius); arc = c.tdValue(.arc, d.arc)
        rotateInstances = c.tdValue(.rotateInstances, d.rotateInstances)
        shape = c.tdValue(.shape, d.shape); shapeWidth = c.tdValue(.shapeWidth, d.shapeWidth); shapeHeight = c.tdValue(.shapeHeight, d.shapeHeight)
        shapeRotation = c.tdValue(.shapeRotation, d.shapeRotation); sides = c.tdValue(.sides, d.sides); starInset = c.tdValue(.starInset, d.starInset)
        arcAngle = c.tdValue(.arcAngle, d.arcAngle); turns = c.tdValue(.turns, d.turns); waves = c.tdValue(.waves, d.waves)
        customID = c.tdValue(.customID, d.customID); followPath = c.tdValue(.followPath, d.followPath)
        captured = (try? c.decodeIfPresent(VectorPath.self, forKey: .captured)) ?? nil
        capturedEvenOdd = c.tdValue(.capturedEvenOdd, d.capturedEvenOdd)
        mirror = c.tdValue(.mirror, d.mirror); mirrorGap = c.tdValue(.mirrorGap, d.mirrorGap); segments = c.tdValue(.segments, d.segments)
        region = c.tdValue(.region, d.region); regionWidth = c.tdValue(.regionWidth, d.regionWidth); regionHeight = c.tdValue(.regionHeight, d.regionHeight)
        minDistance = c.tdValue(.minDistance, d.minDistance); noOverlap = c.tdValue(.noOverlap, d.noOverlap)
        stepX = c.tdValue(.stepX, d.stepX); stepY = c.tdValue(.stepY, d.stepY); stepRotation = c.tdValue(.stepRotation, d.stepRotation)
        stepScale = c.tdValue(.stepScale, d.stepScale); stepOpacity = c.tdValue(.stepOpacity, d.stepOpacity)
        varyHue = c.tdValue(.varyHue, d.varyHue); varyBrightness = c.tdValue(.varyBrightness, d.varyBrightness)
        varyRotation = c.tdValue(.varyRotation, d.varyRotation); varyScale = c.tdValue(.varyScale, d.varyScale)
        seed = c.tdValue(.seed, d.seed)
        flipX = c.tdValue(.flipX, d.flipX); flipY = c.tdValue(.flipY, d.flipY)
    }
}

/// One rendered copy of the source. `transform` maps the source (document space) onto the instance.
package struct RepeaterInstance: Equatable {
    package var transform: CGAffineTransform = .identity
    package var opacity: Double = 1
    package var hue: Double = 0            // degrees
    package var brightness: Double = 0     // -100…100 (Hue/Saturation lightness)

    package var isPlain: Bool { transform.isIdentity && opacity >= 0.9999 && hue == 0 && brightness == 0 }
    package init(transform: CGAffineTransform = .identity, opacity: Double = 1, hue: Double = 0, brightness: Double = 0) {
        self.transform = transform; self.opacity = opacity; self.hue = hue; self.brightness = brightness
    }
}
