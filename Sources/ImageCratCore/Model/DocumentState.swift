import Foundation

/// `CGColorSpace.sRGB` as a string: the profile name documents store for sRGB.
package let sRGBProfileName = "kCGColorSpaceSRGB"

package struct AlphaChannel: Codable, Identifiable {
    package var id = UUID()
    package var name: String
    package var buffer: PixelBuffer   // gray, canvas size
    package init(id: UUID = UUID(), name: String, buffer: PixelBuffer) {
        self.id = id; self.name = name; self.buffer = buffer
    }
}

/// The complete undoable state of a document. Value type; pixel buffers are shared by reference
/// and must be cloned before mutation.
package struct DocumentState: Codable {
    package var width: Int
    package var height: Int
    package var resolution: Double = 72
    package var layers: [Layer] = []            // bottom-first
    package var selection: PixelBuffer? = nil   // gray canvas-size mask; nil = no selection
    package var alphaChannels: [AlphaChannel] = []
    package var paths: [NamedPath] = []
    package var guides: [Guide] = []
    package var globalLight = GlobalLight()
    package var layerComps: [LayerComp] = []
    package var colorMode: ColorMode = .rgb
    package var bitDepth: BitDepth = .eight
    /// ICC profile identifier (a CGColorSpace name) the pixel values are encoded in.
    package var profileName: String = sRGBProfileName
    package var frames: [AnimationFrame] = []
    package var animationLoop: AnimationLoop = .forever
    /// Generative AI metadata (prompt, provider, variations) keyed by layer id.
    package var generative: [UUID: GenerativeLayerInfo] = [:]
    /// Slices, notes, count marks, color samplers, frames and measurement scale (ToolsModule).
    package var toolData = ToolDocData()
    /// Video Timeline (Timeline panel in video mode); nil in frame-animation mode.
    package var videoTimeline: VideoTimeline? = nil
    /// Data-driven graphics: variables and data sets (Image > Variables).
    package var variables: DocumentVariables? = nil
    /// Colour-mode data (colour table, duotone inks, spot channels) — Imaging module.
    package var imaging: ImagingData? = nil
    /// Drawing guides, assist rulers, global colours / colour links and the reference board (Artist module).
    package var artist = ArtistDocData()
    /// Main components of this document, keyed by component id (Components module).
    package var components: [UUID: ComponentMaster] = [:]
    /// Artboard documents: where the document's own (0, 0) is in canvas pixels. Artboard X / Y are measured from it, so
    /// they stay put when the canvas is auto-sized on the left or top (Photoshop keeps the artboard origin too).
    package var artboardOrigin: CGPoint = .zero

    package init(width: Int, height: Int, resolution: Double = 72) {
        self.width = width
        self.height = height
        self.resolution = resolution
    }

    package var canvasRect: IRect { IRect(x: 0, y: 0, width: width, height: height) }
    package var canvasCGRect: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    // MARK: Layer access

    package func layer(_ id: UUID?) -> Layer? {
        guard let id else { return nil }
        return layers.find(id)
    }

    package mutating func updateLayer(_ id: UUID, _ body: (inout Layer) -> Void) {
        layers.update(id, body)
    }

    /// ID of the parent group (nil = root).
    package func parentID(of id: UUID) -> UUID? {
        guard let p = layers.indexPath(of: id), p.count > 1 else { return nil }
        return layers[path: Array(p.dropLast())].id
    }

    /// Siblings array containing the layer.
    package func siblings(of id: UUID) -> [Layer] {
        guard let p = layers.indexPath(of: id) else { return [] }
        if p.count == 1 { return layers }
        return layers[path: Array(p.dropLast())].children
    }

    @discardableResult
    package mutating func removeLayer(_ id: UUID) -> Layer? {
        guard let p = layers.indexPath(of: id) else { return nil }
        return layers.remove(at: p)
    }

    /// Inserts above the given layer (same parent). If `above` is a group and `inside` true, inserts at the top of it.
    package mutating func insertLayer(_ layer: Layer, above: UUID?, inside: Bool = false) {
        guard let a = above, var p = layers.indexPath(of: a) else {
            layers.append(layer)
            return
        }
        if inside, layers[path: p].isGroup {
            let n = layers[path: p].children.count
            layers.insert(layer, at: p + [n])
            return
        }
        p[p.count - 1] += 1
        layers.insert(layer, at: p)
    }

    package mutating func insertLayer(_ layer: Layer, below: UUID) {
        guard let p = layers.indexPath(of: below) else { layers.insert(layer, at: 0); return }
        layers.insert(layer, at: p)
    }

    package var allLayers: [Layer] { layers.allLayers }

    /// Topmost layer ID (panel order).
    package var topLayerID: UUID? { layers.last?.id }

    /// Layer directly below (in same parent) for clipping base resolution.
    package func clippingBase(of id: UUID) -> Layer? {
        let sib = siblings(of: id)
        guard let i = sib.firstIndex(where: { $0.id == id }) else { return nil }
        var j = i - 1
        while j >= 0 {
            if !sib[j].isClipped { return sib[j] }
            j -= 1
        }
        return nil
    }

    // MARK: Selection helpers

    package var hasSelection: Bool { selection != nil }

    package var selectionBounds: IRect? {
        guard let s = selection else { return nil }
        return s.opaqueBounds()
    }
}

extension DocumentState {
    private enum Keys: String, CodingKey {
        case width, height, resolution, layers, selection, alphaChannels, paths, guides
        case globalLight, layerComps, colorMode, bitDepth, profileName, frames, animationLoop
        case generative
        case toolData
        case videoTimeline, variables
        case imaging
        case artist
        case components
        case artboardOrigin
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(width: try c.decode(Int.self, forKey: .width), height: try c.decode(Int.self, forKey: .height),
                  resolution: try c.decodeIfPresent(Double.self, forKey: .resolution) ?? 72)
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers) ?? []
        selection = try c.decodeIfPresent(PixelBuffer.self, forKey: .selection)
        alphaChannels = try c.decodeIfPresent([AlphaChannel].self, forKey: .alphaChannels) ?? []
        paths = try c.decodeIfPresent([NamedPath].self, forKey: .paths) ?? []
        guides = try c.decodeIfPresent([Guide].self, forKey: .guides) ?? []
        globalLight = try c.decodeIfPresent(GlobalLight.self, forKey: .globalLight) ?? GlobalLight()
        layerComps = try c.decodeIfPresent([LayerComp].self, forKey: .layerComps) ?? []
        colorMode = try c.decodeIfPresent(ColorMode.self, forKey: .colorMode) ?? .rgb
        bitDepth = try c.decodeIfPresent(BitDepth.self, forKey: .bitDepth) ?? .eight
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName) ?? sRGBProfileName
        frames = try c.decodeIfPresent([AnimationFrame].self, forKey: .frames) ?? []
        animationLoop = try c.decodeIfPresent(AnimationLoop.self, forKey: .animationLoop) ?? .forever
        generative = (try? c.decodeIfPresent([UUID: GenerativeLayerInfo].self, forKey: .generative)) ?? [:]
        toolData = (try? c.decodeIfPresent(ToolDocData.self, forKey: .toolData)) ?? ToolDocData()
        videoTimeline = try? c.decodeIfPresent(VideoTimeline.self, forKey: .videoTimeline)
        variables = try? c.decodeIfPresent(DocumentVariables.self, forKey: .variables)
        imaging = try? c.decodeIfPresent(ImagingData.self, forKey: .imaging)
        artist = (try? c.decodeIfPresent(ArtistDocData.self, forKey: .artist)) ?? ArtistDocData()
        components = (try? c.decodeIfPresent([UUID: ComponentMaster].self, forKey: .components)) ?? [:]
        artboardOrigin = (try? c.decodeIfPresent(CGPoint.self, forKey: .artboardOrigin)) ?? .zero
        ComponentCodec.restore(&self)   // instances are stored without their resolved source
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(width, forKey: .width); try c.encode(height, forKey: .height); try c.encode(resolution, forKey: .resolution)
        try c.encode(ComponentCodec.stripped(layers, components), forKey: .layers); try c.encodeIfPresent(selection, forKey: .selection)
        try c.encode(alphaChannels, forKey: .alphaChannels); try c.encode(paths, forKey: .paths); try c.encode(guides, forKey: .guides)
        try c.encode(globalLight, forKey: .globalLight); try c.encode(layerComps, forKey: .layerComps)
        try c.encode(colorMode, forKey: .colorMode); try c.encode(bitDepth, forKey: .bitDepth); try c.encode(profileName, forKey: .profileName)
        try c.encode(frames, forKey: .frames); try c.encode(animationLoop, forKey: .animationLoop)
        try c.encodeIfPresent(imaging, forKey: .imaging)
        try c.encodeIfPresent(videoTimeline, forKey: .videoTimeline); try c.encodeIfPresent(variables, forKey: .variables)
        if !toolData.isEmpty { try c.encode(toolData, forKey: .toolData) }
        if !generative.isEmpty { try c.encode(generative, forKey: .generative) }
        if !components.isEmpty { try c.encode(components, forKey: .components) }
        if !artist.isEmpty { try c.encode(artist, forKey: .artist) }
        if artboardOrigin != .zero { try c.encode(artboardOrigin, forKey: .artboardOrigin) }
    }
}
