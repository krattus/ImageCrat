import Foundation

// Document-level data of the Artist module (drawing guides, assist rulers, global colours, colour links and the
// per-document reference board). Stored in `DocumentState.artist`; every type decodes tolerantly so older / newer
// files keep opening.

extension KeyedDecodingContainer {
    /// Tolerant decode used by the Artist module: missing or malformed values fall back to `def`.
    package func art<T: Decodable>(_ key: Key, _ def: T) -> T { ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? def }
}

// MARK: - Drawing guides

package enum DrawingGuideKind: String, Codable, CaseIterable, Identifiable {
    case none, perspective1, perspective2, perspective3, isometric, grid, radial
    package var id: String { rawValue }
    package var title: String {
        switch self {
        case .none: return "None"
        case .perspective1: return "1-Point Perspective"
        case .perspective2: return "2-Point Perspective"
        case .perspective3: return "3-Point Perspective"
        case .isometric: return "Isometric Grid"
        case .grid: return "2D Grid"
        case .radial: return "Radial / Concentric"
        }
    }
    package var vanishingPoints: Int {
        switch self { case .perspective1: return 1; case .perspective2: return 2; case .perspective3: return 3; default: return 0 }
    }
}

/// Procreate-style drawing guide. All positions are document coordinates. Non-printing (overlay only).
package struct DrawingGuide: Codable, Equatable {
    package var kind: DrawingGuideKind = .none
    package var visible = true
    /// Vanishing points (1–3, perspective kinds).
    package var vps: [CGPoint] = []
    /// Tilt of the horizon for 1-point perspective (degrees).
    package var horizonAngle: Double = 0
    /// Isometric axis angle above the horizontal (degrees, 30 = true isometric).
    package var isoAngle: Double = 30
    /// Cell size of the grid / isometric grid and ring spacing of the radial guide (px).
    package var spacing: Double = 40
    /// Rotation of the 2D grid (degrees).
    package var gridAngle: Double = 0
    /// Centre of the radial guide.
    package var center: CGPoint = .zero
    /// Number of spokes of the radial guide.
    package var spokes: Int = 12
    package var color: RGBA = RGBA(r: 0.1, g: 0.75, b: 1)
    package var opacity: Double = 0.55

    package init() {}

    /// A sensible guide of `kind` for a canvas of the given size.
    package static func standard(_ kind: DrawingGuideKind, width: Int, height: Int) -> DrawingGuide {
        var g = DrawingGuide()
        g.kind = kind
        let W = CGFloat(width), H = CGFloat(height)
        g.center = CGPoint(x: W / 2, y: H / 2)
        g.spacing = Double(max(16, (min(W, H) / 12).rounded()))
        switch kind {
        case .perspective1: g.vps = [CGPoint(x: W / 2, y: H * 0.45)]
        case .perspective2: g.vps = [CGPoint(x: -W * 0.25, y: H * 0.45), CGPoint(x: W * 1.25, y: H * 0.45)]
        case .perspective3: g.vps = [CGPoint(x: -W * 0.25, y: H * 0.4), CGPoint(x: W * 1.25, y: H * 0.4), CGPoint(x: W / 2, y: H * 2.2)]
        default: break
        }
        return g
    }

    private enum K: String, CodingKey { case kind, visible, vps, horizonAngle, isoAngle, spacing, gridAngle, center, spokes, color, opacity }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let d = DrawingGuide()
        kind = c.art(.kind, d.kind); visible = c.art(.visible, d.visible); vps = c.art(.vps, d.vps)
        horizonAngle = c.art(.horizonAngle, d.horizonAngle); isoAngle = c.art(.isoAngle, d.isoAngle)
        spacing = max(2, c.art(.spacing, d.spacing)); gridAngle = c.art(.gridAngle, d.gridAngle)
        center = c.art(.center, d.center); spokes = max(2, min(72, c.art(.spokes, d.spokes)))
        color = c.art(.color, d.color); opacity = c.art(.opacity, d.opacity)
        // keep the vanishing point list well formed for the kind
        let need = kind.vanishingPoints
        if vps.count > need { vps = Array(vps.prefix(need)) }
        if vps.count < need { kind = .none; vps = [] }
    }
}

// MARK: - Assist rulers

package enum AssistRulerKind: String, Codable, CaseIterable, Identifiable {
    case straight, ellipse, curve
    package var id: String { rawValue }
    package var title: String {
        switch self { case .straight: return "Straight Edge"; case .ellipse: return "Ellipse Ruler"; case .curve: return "French Curve" }
    }
    package var pointCount: Int { switch self { case .straight: return 2; case .ellipse: return 3; case .curve: return 4 } }
}

/// A ruler placed on the canvas that brush strokes follow.
/// straight: [a, b] · ellipse: [centre, end of first semi-axis, end of second semi-axis] · curve: cubic Bézier [p0, c1, c2, p3].
package struct AssistRuler: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var kind: AssistRulerKind
    package var points: [CGPoint]

    package init(kind: AssistRulerKind, points: [CGPoint]) { self.kind = kind; self.points = points }

    package static func standard(_ kind: AssistRulerKind, width: Int, height: Int) -> AssistRuler {
        let W = CGFloat(width), H = CGFloat(height)
        switch kind {
        case .straight: return AssistRuler(kind: kind, points: [CGPoint(x: W * 0.2, y: H * 0.6), CGPoint(x: W * 0.8, y: H * 0.4)])
        case .ellipse: return AssistRuler(kind: kind, points: [CGPoint(x: W / 2, y: H / 2), CGPoint(x: W * 0.8, y: H / 2), CGPoint(x: W / 2, y: H * 0.3)])
        case .curve: return AssistRuler(kind: kind, points: [CGPoint(x: W * 0.15, y: H * 0.7), CGPoint(x: W * 0.35, y: H * 0.15), CGPoint(x: W * 0.65, y: H * 0.85), CGPoint(x: W * 0.85, y: H * 0.3)])
        }
    }

    package var isValid: Bool { points.count == kind.pointCount }

    private enum K: String, CodingKey { case id, kind, points }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.art(.id, UUID()); kind = c.art(.kind, .straight); points = c.art(.points, [])
    }
}

// MARK: - Global colours

package struct GlobalColor: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var name: String
    package var color: RGBA

    package init(name: String, color: RGBA) { self.name = name; self.color = color }

    private enum K: String, CodingKey { case id, name, color }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.art(.id, UUID()); name = c.art(.name, "Global"); color = c.art(.color, .black)
    }
}

/// A colour property of a layer that can follow a global colour.
package enum ColorSlot: String, Codable, CaseIterable, Identifiable {
    case shapeFill, shapeStroke, textColor, fillLayer
    case colorOverlay, dropShadow, innerShadow, outerGlow, innerGlow, satin, strokeEffect
    package var id: String { rawValue }
    package var title: String {
        switch self {
        case .shapeFill: return "Shape Fill"
        case .shapeStroke: return "Shape Stroke"
        case .textColor: return "Text Colour"
        case .fillLayer: return "Fill Layer Colour"
        case .colorOverlay: return "Colour Overlay"
        case .dropShadow: return "Drop Shadow"
        case .innerShadow: return "Inner Shadow"
        case .outerGlow: return "Outer Glow"
        case .innerGlow: return "Inner Glow"
        case .satin: return "Satin"
        case .strokeEffect: return "Stroke Effect"
        }
    }
    package var isEffect: Bool {
        switch self { case .shapeFill, .shapeStroke, .textColor, .fillLayer: return false; default: return true }
    }
}

package struct ColorLink: Codable, Equatable {
    package var layerID: UUID
    package var slot: ColorSlot
    package var globalID: UUID

    package init(layerID: UUID, slot: ColorSlot, globalID: UUID) { self.layerID = layerID; self.slot = slot; self.globalID = globalID }

    private enum K: String, CodingKey { case layerID, slot, globalID }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        // A link without its ids is meaningless; throwing lets the array decoder below drop just this entry.
        layerID = try c.decode(UUID.self, forKey: .layerID)
        slot = try c.decode(ColorSlot.self, forKey: .slot)
        globalID = try c.decode(UUID.self, forKey: .globalID)
    }
}

/// Decodes an array element by element, skipping entries that fail (unknown enum cases, missing ids…).
package struct LossyArray<T: Codable>: Codable {
    package var items: [T]
    package init(_ items: [T]) { self.items = items }
    /// Accepts any value, so a bad element is consumed and the container moves on.
    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }
    package init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [T] = []
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) { out.append(v) } else { _ = try? c.decode(Skip.self) }
        }
        items = out
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        for i in items { try c.encode(i) }
    }
}

// MARK: - Reference board

/// One image on a reference board. `imageData` is a PNG / JPEG copy capped at `RefBoard.maxPixelSide`.
package struct RefItem: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var imageData: Data
    package var pixelWidth: Int
    package var pixelHeight: Int
    /// Centre on the (infinite) board and display scale (board units per image pixel).
    package var center: CGPoint = .zero
    package var scale: Double = 1
    package var flipH = false
    package var flipV = false
    package var grayscale = false
    package var opacity: Double = 1
    package var name: String = ""

    package init(imageData: Data, pixelWidth: Int, pixelHeight: Int) {
        self.imageData = imageData; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }

    package var size: CGSize { CGSize(width: Double(pixelWidth) * scale, height: Double(pixelHeight) * scale) }
    package var frame: CGRect { CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height) }

    private enum K: String, CodingKey { case id, imageData, pixelWidth, pixelHeight, center, scale, flipH, flipV, grayscale, opacity, name }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        imageData = try c.decode(Data.self, forKey: .imageData)     // an item without pixels is dropped (LossyArray)
        id = c.art(.id, UUID()); pixelWidth = max(1, c.art(.pixelWidth, 1)); pixelHeight = max(1, c.art(.pixelHeight, 1))
        center = c.art(.center, .zero); scale = max(0.001, c.art(.scale, 1))
        flipH = c.art(.flipH, false); flipV = c.art(.flipV, false); grayscale = c.art(.grayscale, false)
        opacity = clamp(c.art(.opacity, 1), 0.05, 1); name = c.art(.name, "")
    }
}

package struct RefBoard: Codable, Equatable {
    /// Longest side (px) of the stored copy of a reference image.
    package static let maxPixelSide = 1600

    package var items: [RefItem] = []
    /// Board point shown at the centre of the window, and zoom.
    package var viewCenter: CGPoint = .zero
    package var viewZoom: Double = 1

    package init() {}
    package var isEmpty: Bool { items.isEmpty }

    private enum K: String, CodingKey { case items, viewCenter, viewZoom }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        items = c.art(.items, LossyArray<RefItem>([])).items
        viewCenter = c.art(.viewCenter, .zero); viewZoom = clamp(c.art(.viewZoom, 1), 0.02, 50)
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(LossyArray(items), forKey: .items)
        try c.encode(viewCenter, forKey: .viewCenter); try c.encode(viewZoom, forKey: .viewZoom)
    }
}

// MARK: - Container

package struct ArtistDocData: Codable, Equatable {
    package var guide = DrawingGuide()
    package var rulers: [AssistRuler] = []
    package var globals: [GlobalColor] = []
    package var links: [ColorLink] = []
    package var board = RefBoard()

    package init() {}

    package var isEmpty: Bool { guide.kind == .none && rulers.isEmpty && globals.isEmpty && links.isEmpty && board.isEmpty }

    private enum K: String, CodingKey { case guide, rulers, globals, links, board }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        guide = c.art(.guide, DrawingGuide())
        rulers = c.art(.rulers, LossyArray<AssistRuler>([])).items.filter(\.isValid)
        globals = c.art(.globals, LossyArray<GlobalColor>([])).items
        links = c.art(.links, LossyArray<ColorLink>([])).items
        board = c.art(.board, RefBoard())
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(guide, forKey: .guide)
        try c.encode(LossyArray(rulers), forKey: .rulers)
        try c.encode(LossyArray(globals), forKey: .globals)
        try c.encode(LossyArray(links), forKey: .links)
        if !board.isEmpty { try c.encode(board, forKey: .board) }
    }
}
