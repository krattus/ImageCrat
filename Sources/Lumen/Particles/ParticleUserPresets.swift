import AppKit
import Observation
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

/// User presets: one JSON file per preset in ~/Library/Application Support/ImageCrat/ParticlePresets.
@Observable
final class ParticleUserPresets {
    static let shared = ParticleUserPresets()

    struct Entry: Identifiable, Equatable {
        var name: String
        var url: URL
        var id: String { url.path }
    }

    /// Tests point this at a temporary folder.
    @ObservationIgnored var directoryOverride: URL?
    private(set) var presets: [Entry] = []

    var directory: URL {
        if let d = directoryOverride { return d }
        return Brand.supportFolder.appendingPathComponent("ParticlePresets", isDirectory: true)
    }

    init() { reload() }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        presets = urls.filter { $0.pathExtension.lowercased() == "json" }
            .map { Entry(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Settings as stored in a preset file: document-specific data (source layer, baked maps) is dropped.
    static func portable(_ e0: ParticleEffect, name: String) -> ParticleEffect {
        var e = e0
        e.name = name
        e.category = "User"
        e.sourceLayerID = nil
        e.imagePNG = nil
        e.maskCreated = false
        for i in e.systems.indices { e.systems[i].maskPNG = nil }
        return e
    }

    private func fileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Preset" : cleaned
    }

    @discardableResult
    func save(_ effect: ParticleEffect, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(name) + ".json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(ParticleUserPresets.portable(effect, name: name)).write(to: url, options: .atomic)
        reload()
        return url
    }

    func load(_ url: URL) -> ParticleEffect? {
        guard let data = try? Data(contentsOf: url), var e = ParticleCoding.decode(data) else { return nil }
        if e.name.isEmpty { e.name = url.deletingPathExtension().lastPathComponent }
        return e
    }

    func delete(_ entry: Entry) {
        // presets go to the Trash so a mistaken delete can be undone in Finder
        try? FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        reload()
    }

    func rename(_ entry: Entry, to name: String) {
        guard let e = load(entry.url) else { return }
        let dest = directory.appendingPathComponent(fileName(name) + ".json")
        guard dest != entry.url, !FileManager.default.fileExists(atPath: dest.path) else { return }
        if (try? save(e, name: name)) != nil { try? FileManager.default.removeItem(at: entry.url) }
        reload()
    }

    /// Copies valid preset files into the presets folder. Returns how many were imported.
    @discardableResult
    func importFiles(_ urls: [URL]) -> Int {
        var n = 0
        for u in urls {
            guard let e = load(u) else { continue }
            var name = u.deletingPathExtension().lastPathComponent
            var k = 2
            while FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName(name) + ".json").path) {
                name = u.deletingPathExtension().lastPathComponent + " \(k)"; k += 1
            }
            if (try? save(e, name: name)) != nil { n += 1 }
        }
        return n
    }

    func export(_ entry: Entry, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.copyItem(at: entry.url, to: url)
    }
}

/// Small helpers that turn document content into particle inputs.
enum ParticleSources {
    private static func png(_ img: CGImage, maxDim: Int = 128) -> String? {
        let s = min(1, CGFloat(maxDim) / CGFloat(max(img.width, img.height)))
        let w = max(1, Int(CGFloat(img.width) * s)), h = max(1, Int(CGFloat(img.height) * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, small, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data).base64EncodedString()
    }

    /// The active layer (cropped to its content) as a sprite image.
    static func spriteFromActiveLayer(_ d: Document) -> String? {
        guard let l = d.activeLayer else { return nil }
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        guard let content = Compositor.shared.contentImage(l, space: sp) else { return nil }
        let full = RenderEngine.renderBuffer(content.cropped(to: sp.ciCanvas), docRect: d.state.canvasRect, space: sp)
        guard let b = full.opaqueBounds() else { return nil }
        return png(full.cropped(to: b).makeCGImage())
    }

    /// The current brush tip as a white sprite.
    static func spriteFromBrushTip() -> String? {
        let b = AppModel.shared.brush
        guard let mask = BrushTips.mask(diameter: 120, hardness: b.hardness, roundness: b.roundness, angle: b.angle, tipID: b.tipID) else { return nil }
        let w = mask.width, h = mask.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h), mask: mask)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage().flatMap { png($0) }
    }

    /// The active path (or the active shape layer's outline) as normalized polyline points.
    static func activePath(_ d: Document) -> (points: [CGPoint], closed: Bool)? {
        var vp: VectorPath?
        if let pid = d.activePathID, let np = d.state.paths.first(where: { $0.id == pid }) { vp = np.path }
        else if let s = d.activeLayer?.shape { vp = s.path.applying(s.transform) }
        else if let np = d.state.paths.first { vp = np.path }
        guard let path = vp, !path.isEmpty else { return nil }
        let subs = ParticleMaps.flatten(path.cgPath, step: 3)
        func length(_ p: [CGPoint]) -> CGFloat { zip(p, p.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) } }
        guard let longest = subs.max(by: { length($0) < length($1) }), longest.count >= 2 else { return nil }
        let W = CGFloat(d.state.width), H = CGFloat(d.state.height)
        let closed = longest.first!.distance(to: longest.last!) < 1.5
        var pts = longest.map { CGPoint(x: $0.x / W, y: $0.y / H) }
        if closed { pts.removeLast() }
        let step = max(1, pts.count / 400)
        pts = pts.enumerated().filter { $0.offset % step == 0 }.map(\.element)
        return (pts, closed)
    }

    /// A stand-in subject (used for thumbnails and tests of effects that need a layer).
    static func demoSubject(_ w: Int, _ h: Int) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        let c = b.context
        let r = CGRect(x: Double(w) * 0.3, y: Double(h) * 0.18, width: Double(h) * 0.64, height: Double(h) * 0.64)
        c.saveGState()
        c.addEllipse(in: r); c.clip()
        let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "FF5E62")!.cgColor, RGBA(hex: "FF9966")!.cgColor, RGBA(hex: "2B86C5")!.cgColor] as CFArray, locations: [0, 0.5, 1])!
        c.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        c.setFillColor(RGBA(hex: "1B1F3A")!.cgColor)
        c.fillEllipse(in: CGRect(x: r.midX - r.width * 0.22, y: r.midY - r.height * 0.15, width: r.width * 0.12, height: r.width * 0.12))
        c.fillEllipse(in: CGRect(x: r.midX + r.width * 0.10, y: r.midY - r.height * 0.15, width: r.width * 0.12, height: r.width * 0.12))
        c.setFillColor(RGBA(hex: "FFFFFF")!.cgColor)
        c.fill(CGRect(x: r.midX - r.width * 0.2, y: r.midY + r.height * 0.15, width: r.width * 0.4, height: r.height * 0.06))
        c.restoreGState()
        b.markDirty()
        return b
    }
}

/// Preset thumbnails, rendered once in the background with the real engine.
@Observable
final class ParticleThumbnails {
    static let shared = ParticleThumbnails()
    /// Bumped whenever a thumbnail becomes available.
    private(set) var version = 0
    @ObservationIgnored private var cache: [String: NSImage] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private let queue = DispatchQueue(label: "lumen.particles.thumbs", qos: .utility)

    static func render(_ effect: ParticleEffect, id: String, width w: Int = 480, height h: Int = 300) -> CGImage? {
        let ctx = ParticleContext(width: w, height: h)
        let canvas = CGRect(x: 0, y: 0, width: w, height: h)
        var bg = CIImage.color(RGBA(hex: "10131B")!, canvas)
        if effect.systems.contains(where: { $0.shape == .layerAlpha || $0.shape == .layerEdges || $0.colorBase == .image }) {
            let layer = ParticleSources.demoSubject(w, h)
            ctx.layerColor = PColorMap(cgImage: layer.makeCGImage())
            ctx.layerAlpha = PMap(buffer: layer, useAlpha: true)
            var li = layer.ciImage
            if effect.maskSourceLayer, let i = effect.systems.firstIndex(where: { $0.sweep > 0 }) {
                let cover = ParticleSystem.sweepCoverage(effect.systems[i], effect: effect, ctx: ctx, index: i, T: effect.time).buffer(width: w, height: h)
                li = li.masked(byGray: cover.ciImage.inverted())
            }
            bg = li.composited(over: bg)
        }
        return ParticleEngine.image(effect, ctx: ctx, background: bg)
    }

    func image(_ id: String) -> NSImage? {
        _ = version
        if !started { start() }
        return cache[id]
    }

    private func start() {
        started = true
        queue.async { [weak self] in
            for p in ParticlePresets.all {
                guard let self else { return }
                var e = p.make(480.0 / 300.0)
                // thumbnails are tiny: enlarge fine particles so every preset stays legible
                for i in e.systems.indices where e.systems[i].sizeMax < 40 && e.systems[i].shape != .grid && e.systems[i].sprite != .glyph {
                    let k = e.systems[i].trail == .ribbon ? 1.5 : 2.2
                    e.systems[i].sizeMin *= k; e.systems[i].sizeMax *= k
                    for j in e.systems[i].sub.indices { e.systems[i].sub[j].sizeMin *= 1.5; e.systems[i].sub[j].sizeMax *= 1.5 }
                }
                guard let cg = ParticleThumbnails.render(e, id: p.id) else { continue }
                let img = NSImage(cgImage: cg, size: NSSize(width: 96, height: 60))
                DispatchQueue.main.async {
                    self.cache[p.id] = img
                    self.version += 1
                }
            }
        }
    }
}
