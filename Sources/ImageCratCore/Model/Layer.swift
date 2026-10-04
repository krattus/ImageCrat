import Foundation

package enum LayerContent: Codable {
    case raster(RasterContent)
    case text(TextContent)
    case shape(ShapeContent)
    case smartObject(SmartObjectContent)
    case adjustment(AdjustmentSettings)
    case fill(FillContent)
    case group(GroupContent)
}

package struct LayerLocks: Codable, Equatable {
    package var transparency = false
    package var pixels = false
    package var position = false
    package var all = false

    package var anyLocked: Bool { transparency || pixels || position || all }
    package var pixelsLocked: Bool { pixels || all }
    package var positionLocked: Bool { position || all }
    /// Blend mode, opacity and fill opacity (Photoshop's Lock All freezes these too).
    package var propertiesLocked: Bool { all }
    package init(transparency: Bool = false, pixels: Bool = false, position: Bool = false, all: Bool = false) {
        self.transparency = transparency; self.pixels = pixels; self.position = position; self.all = all
    }
}
// tolerant-decoding:LayerLocks (generated: missing keys fall back to defaults)
extension LayerLocks {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LayerLocks()
        transparency = try c.decodeIfPresent(Bool.self, forKey: .transparency) ?? d.transparency
        pixels = try c.decodeIfPresent(Bool.self, forKey: .pixels) ?? d.pixels
        position = try c.decodeIfPresent(Bool.self, forKey: .position) ?? d.position
        all = try c.decodeIfPresent(Bool.self, forKey: .all) ?? d.all
    }
}
// end-tolerant

package enum LayerColorLabel: String, Codable, CaseIterable {
    case none, red, orange, yellow, green, blue, violet, gray
    package var rgba: RGBA? {
        switch self {
        case .none: return nil
        case .red: return RGBA(hex: "B84A4A")
        case .orange: return RGBA(hex: "C27A3A")
        case .yellow: return RGBA(hex: "BFA83C")
        case .green: return RGBA(hex: "4F9A55")
        case .blue: return RGBA(hex: "4A76B8")
        case .violet: return RGBA(hex: "8A5AB8")
        case .gray: return RGBA(hex: "7A7A7A")
        }
    }
}

package struct LayerMask: Codable {
    package var buffer: PixelBuffer      // gray
    package var origin: IPoint
    package var outsideValue: UInt8 = 255
    package var isEnabled = true
    package var isLinked = true
    package var density: Double = 1
    package var feather: Double = 0
    /// nil = centered (older documents).
    package var featherDirection: FeatherDirection? = nil

    package var frame: IRect { IRect(x: origin.x, y: origin.y, width: buffer.width, height: buffer.height) }

    package static func reveal(width: Int, height: Int) -> LayerMask {
        LayerMask(buffer: PixelBuffer(width: width, height: height, gray: 255), origin: .zero, outsideValue: 255)
    }
    package static func hide(width: Int, height: Int) -> LayerMask {
        LayerMask(buffer: PixelBuffer(width: width, height: height, gray: 0), origin: .zero, outsideValue: 0)
    }
    package init(buffer: PixelBuffer, origin: IPoint, outsideValue: UInt8 = 255, isEnabled: Bool = true, isLinked: Bool = true, density: Double = 1, feather: Double = 0, featherDirection: FeatherDirection? = nil) {
        self.buffer = buffer; self.origin = origin; self.outsideValue = outsideValue; self.isEnabled = isEnabled; self.isLinked = isLinked; self.density = density; self.feather = feather; self.featherDirection = featherDirection
    }
}

package enum BlendIfChannel: String, Codable, CaseIterable { case gray = "Gray", red = "Red", green = "Green", blue = "Blue" }

/// "Blend If" sliders (0…255). Each range is a split slider: values below low[0] are hidden, fully shown from low[1]; shown until high[0], hidden past high[1].
package struct BlendIf: Codable, Equatable {
    package var channel: BlendIfChannel = .gray
    package var thisLow: [Double] = [0, 0]
    package var thisHigh: [Double] = [255, 255]
    package var underLow: [Double] = [0, 0]
    package var underHigh: [Double] = [255, 255]

    package var isDefault: Bool { thisLow == [0, 0] && thisHigh == [255, 255] && underLow == [0, 0] && underHigh == [255, 255] }
    package init(channel: BlendIfChannel = .gray, thisLow: [Double] = [0, 0], thisHigh: [Double] = [255, 255], underLow: [Double] = [0, 0], underHigh: [Double] = [255, 255]) {
        self.channel = channel; self.thisLow = thisLow; self.thisHigh = thisHigh; self.underLow = underLow; self.underHigh = underHigh
    }
}
// tolerant-decoding:BlendIf (generated: missing keys fall back to defaults)
extension BlendIf {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BlendIf()
        channel = try c.decodeIfPresent(BlendIfChannel.self, forKey: .channel) ?? d.channel
        thisLow = try c.decodeIfPresent([Double].self, forKey: .thisLow) ?? d.thisLow
        thisHigh = try c.decodeIfPresent([Double].self, forKey: .thisHigh) ?? d.thisHigh
        underLow = try c.decodeIfPresent([Double].self, forKey: .underLow) ?? d.underLow
        underHigh = try c.decodeIfPresent([Double].self, forKey: .underHigh) ?? d.underHigh
        // each range is a [low, high] pair that the dialog and the compositor index directly (a damaged file must not trap)
        if thisLow.count != 2 { thisLow = d.thisLow }
        if thisHigh.count != 2 { thisHigh = d.thisHigh }
        if underLow.count != 2 { underLow = d.underLow }
        if underHigh.count != 2 { underHigh = d.underHigh }
    }
}
// end-tolerant

package enum Knockout: String, Codable, CaseIterable { case none = "None", shallow = "Shallow", deep = "Deep" }

package struct Layer: Identifiable, Codable {
    package var id = UUID()
    package var name: String
    package var content: LayerContent
    package var isVisible = true
    package var opacity: Double = 1
    package var fillOpacity: Double = 1
    package var blendMode: BlendMode = .normal
    package var isClipped = false
    package var locks = LayerLocks()
    package var mask: LayerMask?
    package var vectorMask: VectorPath?
    package var vectorMaskEnabled = true
    package var effects = LayerEffects()
    package var colorLabel: LayerColorLabel = .none

    // Advanced blending
    package var blendIf = BlendIf()
    package var knockout: Knockout = .none
    package var blendInteriorEffectsAsGroup = false
    package var blendClippedAsGroup = true
    package var layerMaskHidesEffects = false
    package var vectorMaskHidesEffects = false
    package var channelR = true
    package var channelG = true
    package var channelB = true
    /// Layers sharing a link ID move and transform together.
    package var linkID: UUID? = nil
    /// Layout constraints (pin / centre / scale) honoured when the canvas or artboard is resized (Layout module).
    package var constraints: LayoutConstraints? = nil

    package init(name: String, content: LayerContent) {
        self.name = name
        self.content = content
        if case .group = content { blendMode = .passThrough }
    }

    package static func raster(name: String, width: Int, height: Int) -> Layer {
        Layer(name: name, content: .raster(RasterContent(buffer: PixelBuffer(width: width, height: height), origin: .zero)))
    }

    package static func raster(name: String, buffer: PixelBuffer, origin: IPoint = .zero) -> Layer {
        Layer(name: name, content: .raster(RasterContent(buffer: buffer, origin: origin)))
    }

    // MARK: Kind queries

    package var isGroup: Bool { if case .group = content { return true }; return false }
    package var artboard: Artboard? { if case .group(let g) = content { return g.artboard }; return nil }
    package var isArtboard: Bool { artboard != nil }
    package var isRaster: Bool { if case .raster = content { return true }; return false }
    package var isText: Bool { if case .text = content { return true }; return false }
    package var isShape: Bool { if case .shape = content { return true }; return false }
    package var isSmartObject: Bool { if case .smartObject = content { return true }; return false }
    package var isAdjustment: Bool { if case .adjustment = content { return true }; return false }
    package var isFill: Bool { if case .fill = content { return true }; return false }

    package var kindName: String {
        switch content {
        case .raster: return "Pixel Layer"
        case .text: return "Type Layer"
        case .shape: return "Shape Layer"
        case .smartObject: return "Smart Object"
        case .adjustment(let a): return a.kind.displayName
        case .fill(let f): return f.recipe != nil ? "Recipe Layer" : "Fill Layer"
        case .group: return "Group"
        }
    }

    package var children: [Layer] {
        get { if case .group(let g) = content { return g.children }; return [] }
        set { if case .group(var g) = content { g.children = newValue; content = .group(g) } }
    }

    package var isExpanded: Bool {
        get { if case .group(let g) = content { return g.isExpanded }; return false }
        set { if case .group(var g) = content { g.isExpanded = newValue; content = .group(g) } }
    }

    package var raster: RasterContent? {
        get { if case .raster(let r) = content { return r }; return nil }
        set { if let r = newValue { content = .raster(r) } }
    }
    package var text: TextContent? {
        get { if case .text(let t) = content { return t }; return nil }
        set { if let t = newValue { content = .text(t) } }
    }
    package var shape: ShapeContent? {
        get { if case .shape(let s) = content { return s }; return nil }
        set { if let s = newValue { content = .shape(s) } }
    }
    package var smart: SmartObjectContent? {
        get { if case .smartObject(let s) = content { return s }; return nil }
        set { if let s = newValue { content = .smartObject(s) } }
    }
    package var adjustment: AdjustmentSettings? {
        get { if case .adjustment(let a) = content { return a }; return nil }
        set { if let a = newValue { content = .adjustment(a) } }
    }
    package var fill: FillContent? {
        get { if case .fill(let f) = content { return f }; return nil }
        set { if let f = newValue { content = .fill(f) } }
    }

    /// Deep copy (new IDs, cloned pixel buffers) for duplication.
    package func duplicated(newName: String? = nil) -> Layer {
        var l = self
        l.id = UUID()
        if let n = newName { l.name = n }
        switch content {
        case .raster(var r): r.buffer = r.buffer.copy(); l.content = .raster(r)
        case .group(var g): g.children = g.children.map { $0.duplicated() }; l.content = .group(g)
        default: break
        }
        if var m = mask { m.buffer = m.buffer.copy(); l.mask = m }
        return l
    }

    /// All layer IDs in this subtree.
    package var allIDs: [UUID] { [id] + children.flatMap { $0.allIDs } }

    // MARK: Translation

    package mutating func translate(dx: Double, dy: Double, document: Bool = false) {
        guard dx.isFinite, dy.isFinite else { return }
        let idx = Int(max(-1e9, min(1e9, dx.rounded()))), idy = Int(max(-1e9, min(1e9, dy.rounded())))
        switch content {
        case .raster(var r):
            r.origin.x += idx; r.origin.y += idy
            content = .raster(r)
        case .text(var t):
            t.transform = t.transform.concatenating(CGAffineTransform(translationX: dx, y: dy))
            content = .text(t)
        case .shape(var s):
            if let p = s.perspective {
                s.perspective = Homography(affine: CGAffineTransform(translationX: dx, y: dy)).concat(p)
            } else {
                s.transform = s.transform.concatenating(CGAffineTransform(translationX: dx, y: dy))
            }
            // a gradient with placed end points (imported vector artwork) travels with its shape
            if case .gradient(var g) = s.fill, let a = g.start, let b = g.end {
                g.start = a + CGPoint(x: dx, y: dy); g.end = b + CGPoint(x: dx, y: dy)
                s.fill = .gradient(g)
            }
            content = .shape(s)
        case .smartObject(var s):
            s.quad = s.quad.applying(CGAffineTransform(translationX: dx, y: dy))
            s.warp = s.warp?.mapped { $0 + CGPoint(x: dx, y: dy) }
            for i in s.filters.indices where s.filters[i].mask != nil {   // filter masks are linked to the layer
                s.filters[i].mask?.origin.x += idx; s.filters[i].mask?.origin.y += idy
            }
            content = .smartObject(s)
        case .fill(var f):
            if f.recipe != nil { f.recipe?.translate(dx: dx, dy: dy); content = .fill(f) }   // Recipe layer: moves the pattern origin
            if var pl = f.patternPlacement, pl.linked {   // Pattern Fill "Link with Layer": the tiles move with the layer
                pl.offset = CGPoint(x: pl.offset.x + CGFloat(dx), y: pl.offset.y + CGFloat(dy))
                f.patternPlacement = pl
                content = .fill(f)
            }
            if case .gradient(var g) = f.paint, let s = g.start, let e = g.end {
                g.start = s + CGPoint(x: dx, y: dy); g.end = e + CGPoint(x: dx, y: dy)
                f.paint = .gradient(g)
                content = .fill(f)
            }
        case .group(var g):
            for i in g.children.indices { g.children[i].translate(dx: dx, dy: dy, document: document) }
            if let r = g.artboard?.rect { g.artboard?.rect = r.offsetBy(dx: CGFloat(dx), dy: CGFloat(dy)) }
            content = .group(g)
        case .adjustment:
            break
        }
        if var m = mask, m.isLinked || document {
            m.origin.x += idx; m.origin.y += idy
            mask = m
        }
        if let vm = vectorMask {
            vectorMask = vm.applying(CGAffineTransform(translationX: dx, y: dy))
        }
    }
}

// MARK: - Layer tree helpers

extension Array where Element == Layer {
    package func find(_ id: UUID) -> Layer? {
        for l in self {
            if l.id == id { return l }
            if l.isGroup, let f = l.children.find(id) { return f }
        }
        return nil
    }

    package func indexPath(of id: UUID) -> [Int]? {
        for (i, l) in enumerated() {
            if l.id == id { return [i] }
            if l.isGroup, let p = l.children.indexPath(of: id) { return [i] + p }
        }
        return nil
    }

    @discardableResult
    package mutating func update(_ id: UUID, _ body: (inout Layer) -> Void) -> Bool {
        for i in indices {
            if self[i].id == id { body(&self[i]); return true }
            if self[i].isGroup {
                var ch = self[i].children
                if ch.update(id, body) { self[i].children = ch; return true }
            }
        }
        return false
    }

    package subscript(path path: [Int]) -> Layer {
        get {
            if path.count == 1 { return self[path[0]] }
            return self[path[0]].children[path: [Int](path.dropFirst())]
        }
        set {
            if path.count == 1 { self[path[0]] = newValue; return }
            var ch = self[path[0]].children
            ch[path: [Int](path.dropFirst())] = newValue
            self[path[0]].children = ch
        }
    }

    @discardableResult
    package mutating func remove(at path: [Int]) -> Layer {
        if path.count == 1 { return self.remove(at: path[0]) }
        var ch = self[path[0]].children
        let r = ch.remove(at: [Int](path.dropFirst()))
        self[path[0]].children = ch
        return r
    }

    package mutating func insert(_ layer: Layer, at path: [Int]) {
        if path.count == 1 { self.insert(layer, at: Swift.min(Swift.max(0, path[0]), count)); return }
        var ch = self[path[0]].children
        ch.insert(layer, at: [Int](path.dropFirst()))
        self[path[0]].children = ch
    }

    /// Depth-first list top-to-bottom (panel order), with depth.
    package func flattenedForDisplay(depth: Int = 0, includeCollapsed: Bool = false) -> [(Layer, Int)] {
        var out: [(Layer, Int)] = []
        for l in reversed() {
            out.append((l, depth))
            if l.isGroup && (l.isExpanded || includeCollapsed) {
                out += l.children.flattenedForDisplay(depth: depth + 1, includeCollapsed: includeCollapsed)
            }
        }
        return out
    }

    /// All leaf and group layers depth-first (bottom-first order).
    package var allLayers: [Layer] {
        var out: [Layer] = []
        for l in self {
            out.append(l)
            if l.isGroup { out += l.children.allLayers }
        }
        return out
    }
}

extension Layer {
    private enum Keys: String, CodingKey {
        case id, name, content, isVisible, opacity, fillOpacity, blendMode, isClipped, locks, mask, vectorMask, vectorMaskEnabled, effects, colorLabel
        case blendIf, knockout, blendInteriorEffectsAsGroup, blendClippedAsGroup, layerMaskHidesEffects, vectorMaskHidesEffects, channelR, channelG, channelB, linkID, constraints
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(name: try c.decode(String.self, forKey: .name), content: try c.decode(LayerContent.self, forKey: .content))
        id = try c.decode(UUID.self, forKey: .id)
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        fillOpacity = try c.decodeIfPresent(Double.self, forKey: .fillOpacity) ?? 1
        blendMode = try c.decodeIfPresent(BlendMode.self, forKey: .blendMode) ?? blendMode
        isClipped = try c.decodeIfPresent(Bool.self, forKey: .isClipped) ?? false
        locks = try c.decodeIfPresent(LayerLocks.self, forKey: .locks) ?? LayerLocks()
        mask = try c.decodeIfPresent(LayerMask.self, forKey: .mask)
        vectorMask = try c.decodeIfPresent(VectorPath.self, forKey: .vectorMask)
        vectorMaskEnabled = try c.decodeIfPresent(Bool.self, forKey: .vectorMaskEnabled) ?? true
        effects = try c.decodeIfPresent(LayerEffects.self, forKey: .effects) ?? LayerEffects()
        colorLabel = try c.decodeIfPresent(LayerColorLabel.self, forKey: .colorLabel) ?? .none
        blendIf = try c.decodeIfPresent(BlendIf.self, forKey: .blendIf) ?? BlendIf()
        knockout = try c.decodeIfPresent(Knockout.self, forKey: .knockout) ?? .none
        blendInteriorEffectsAsGroup = try c.decodeIfPresent(Bool.self, forKey: .blendInteriorEffectsAsGroup) ?? false
        blendClippedAsGroup = try c.decodeIfPresent(Bool.self, forKey: .blendClippedAsGroup) ?? true
        layerMaskHidesEffects = try c.decodeIfPresent(Bool.self, forKey: .layerMaskHidesEffects) ?? false
        vectorMaskHidesEffects = try c.decodeIfPresent(Bool.self, forKey: .vectorMaskHidesEffects) ?? false
        channelR = try c.decodeIfPresent(Bool.self, forKey: .channelR) ?? true
        channelG = try c.decodeIfPresent(Bool.self, forKey: .channelG) ?? true
        channelB = try c.decodeIfPresent(Bool.self, forKey: .channelB) ?? true
        linkID = try c.decodeIfPresent(UUID.self, forKey: .linkID)
        constraints = (try? c.decodeIfPresent(LayoutConstraints.self, forKey: .constraints)) ?? nil
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(content, forKey: .content)
        try c.encode(isVisible, forKey: .isVisible); try c.encode(opacity, forKey: .opacity); try c.encode(fillOpacity, forKey: .fillOpacity)
        try c.encode(blendMode, forKey: .blendMode); try c.encode(isClipped, forKey: .isClipped); try c.encode(locks, forKey: .locks)
        try c.encodeIfPresent(mask, forKey: .mask); try c.encodeIfPresent(vectorMask, forKey: .vectorMask)
        try c.encode(vectorMaskEnabled, forKey: .vectorMaskEnabled); try c.encode(effects, forKey: .effects); try c.encode(colorLabel, forKey: .colorLabel)
        try c.encode(blendIf, forKey: .blendIf); try c.encode(knockout, forKey: .knockout)
        try c.encode(blendInteriorEffectsAsGroup, forKey: .blendInteriorEffectsAsGroup); try c.encode(blendClippedAsGroup, forKey: .blendClippedAsGroup)
        try c.encode(layerMaskHidesEffects, forKey: .layerMaskHidesEffects); try c.encode(vectorMaskHidesEffects, forKey: .vectorMaskHidesEffects)
        try c.encode(channelR, forKey: .channelR); try c.encode(channelG, forKey: .channelG); try c.encode(channelB, forKey: .channelB)
        try c.encodeIfPresent(linkID, forKey: .linkID)
        try c.encodeIfPresent(constraints, forKey: .constraints)
    }
}
