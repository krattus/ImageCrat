import AppKit
import CoreImage
import ImageCratCore

/// Move tool ▸ Auto-Select: what a click on the canvas picks.
enum AutoSelectMode: String, CaseIterable {
    case layer = "Layer", group = "Group"
}

/// The Move tool's auto-select settings, remembered between launches. On for new users. Automated runs (self tests,
/// menu fuzzing, scripts) start from the historical "off" and never write the user's preferences.
enum AutoSelectPrefs {
    static let onKey = "Lumen.Move.AutoSelect"
    static let modeKey = "Lumen.Move.AutoSelectMode"
    static var automated: Bool { GenAIKeyOverrides.realKeysBlocked }

    static var initialOn: Bool { automated ? false : resolveOn(UserDefaults.standard.object(forKey: onKey)) }
    static var initialMode: AutoSelectMode { automated ? .layer : resolveMode(UserDefaults.standard.string(forKey: modeKey)) }
    /// The stored setting, or on when there is none (new users).
    static func resolveOn(_ stored: Any?) -> Bool { stored as? Bool ?? true }
    static func resolveMode(_ stored: String?) -> AutoSelectMode { stored.flatMap(AutoSelectMode.init(rawValue:)) ?? .layer }
    static func save(_ on: Bool) { if !automated { UserDefaults.standard.set(on, forKey: onKey) } }
    static func save(_ m: AutoSelectMode) { if !automated { UserDefaults.standard.set(m.rawValue, forKey: modeKey) } }
}

/// Finds the layers that draw a pixel under the cursor, like Photoshop's auto-select:
/// - only visible layers (hidden ancestors, `Document.hiddenLayers` and clipped layers over a hidden base count as hidden);
///   adjustment layers have no pixels of their own;
/// - transparent pixels don't count (alpha ≤ `threshold`); layer and vector masks (and a group's masks) cut the area;
///   a clipped layer counts only where its clipping base has pixels;
/// - layer effects count where they are drawn (a drop shadow, outer glow or stroke picks its layer, as in Photoshop);
///   effects hidden with their eye or the master switch don't;
/// - type is picked by its glyphs, smart objects by their rendered (filtered, warped) pixels, fill layers by their mask;
/// - auto-select skips locked layers (position or all) and clicks through to the layer below; the context-menu list
///   includes them;
/// - artboards behave like groups (their rectangle clips the children), see `AutoSelectArtboards`.
/// Raster layers without effects that grow them are tested on their pixels directly; everything else is rendered once into
/// an alpha mask (at most 1024² samples) cached per layer until the layer changes.
final class LayerHitTester {
    static let shared = LayerHitTester()

    /// Alpha (0…255) a pixel needs to count.
    var threshold: UInt8 = 12
    /// Largest cached mask (samples); bigger layers are cached at a reduced resolution.
    var maxMaskSamples = 1024 * 1024
    /// Total cache budget in bytes (oldest entries go first).
    var budget = 96 * 1024 * 1024

    private struct Entry {
        var sig: Sig
        var region: CGRect      // doc space, the canvas part of the layer's appearance
        var scale: CGFloat
        var width: Int, height: Int
        var alpha: [UInt8]
        var used: Int
    }
    private enum ContentSig: Equatable {
        case raster(ObjectIdentifier, Int, IPoint)
        case text(TextContent)
        case shape(ShapeContent)
        case other(Int)          // smart objects, recipe fills: re-rendered when the document changes
    }
    private struct Sig: Equatable {
        var content: ContentSig
        var mask: String
        var vmask: VectorPath?
        var effects: LayerEffects?
        var light: GlobalLight
        var flags: Int
        var w: Int, h: Int
    }
    private var cache: [UUID: Entry] = [:]
    private var clock = 0
    /// Masks rendered since launch (tests).
    private(set) var renders = 0

    func clear() { cache.removeAll() }
    var cachedLayerCount: Int { cache.count }

    // MARK: Queries

    /// The layer auto-select picks at `p` (doc space): the topmost visible, unlocked layer with a pixel there, or — in
    /// group mode — the outermost group containing it (artboards are skipped: their top-level groups are picked).
    func target(at p: CGPoint, in d: Document, mode: AutoSelectMode) -> UUID? {
        var found: UUID?
        walk(d.state.layers, ancestors: [], p: p, d: d) { leaf, ancestors in
            let t = mode == .group ? AutoSelectArtboards.outermostGroup(ancestors) ?? leaf : leaf
            if t.locks.positionLocked || leaf.locks.positionLocked { return false }    // click through locked layers
            found = t.id
            return true
        }
        return found
    }

    /// Every layer with a pixel at `p`, topmost first (locked ones included): the Move tool's context menu.
    func layers(at p: CGPoint, in d: Document) -> [UUID] {
        var out: [UUID] = []
        walk(d.state.layers, ancestors: [], p: p, d: d) { leaf, _ in out.append(leaf.id); return false }
        return out
    }

    /// Layers whose visible content (with effects) intersects `rect` (doc space): the Move tool's ⇧-drag marquee. Locked
    /// and hidden layers are left out; in group mode their outermost groups are returned instead. Topmost first.
    func layers(in rect: CGRect, of d: Document, mode: AutoSelectMode) -> [UUID] {
        var out: [UUID] = []
        func visit(_ layers: [Layer], _ ancestors: [Layer]) {
            for l in layers.reversed() where l.isVisible && !d.hiddenLayers.contains(l.id) {
                if l.isGroup {
                    if let ab = l.artboard, !ab.rect.intersects(rect) { continue }
                    visit(l.children, ancestors + [l])
                    continue
                }
                guard !l.isAdjustment, !l.locks.positionLocked, draws(l, in: rect, d) else { continue }
                let t = mode == .group ? AutoSelectArtboards.outermostGroup(ancestors) ?? l : l
                if !t.locks.positionLocked && !out.contains(t.id) { out.append(t.id) }
            }
        }
        visit(d.state.layers, [])
        return out
    }

    /// Doc-space outline of what auto-select would pick (the hover highlight): the layer's box (type and smart objects:
    /// their transformed quad), a group's union of its children.
    func outline(_ id: UUID, in d: Document) -> CGPath? {
        guard let l = d.state.layer(id) else { return nil }
        if let t = l.text { return TextRenderer.docQuad(t).path }
        if let so = l.smart, so.warp == nil { return so.quad.path }
        guard let b = Compositor.shared.contentBounds(l, state: d.state), b.width > 0, b.height > 0 else { return nil }
        return CGPath(rect: b, transform: nil)
    }

    // MARK: Walk

    /// Visits the layers with a pixel at `p`, topmost first, until `visit` returns true. Returns true if it stopped.
    @discardableResult
    private func walk(_ layers: [Layer], ancestors: [Layer], p: CGPoint, d: Document, visit: (Layer, [Layer]) -> Bool) -> Bool {
        guard p.x >= 0, p.y >= 0, p.x < CGFloat(d.state.width), p.y < CGFloat(d.state.height) else { return false }   // only the canvas shows pixels
        for i in layers.indices.reversed() {
            let l = layers[i]
            guard l.isVisible, !d.hiddenLayers.contains(l.id) else { continue }
            if l.isClipped {
                guard let base = layers[..<i].last(where: { !$0.isClipped }), base.isVisible, !d.hiddenLayers.contains(base.id),
                      shapeHit(base, p, d) else { continue }
            }
            if l.isGroup {
                guard groupAllows(l, p) else { continue }
                if walk(l.children, ancestors: ancestors + [l], p: p, d: d, visit: visit) { return true }
            } else if leafHit(l, p, d, effects: true) {
                if visit(l, ancestors) { return true }
            }
        }
        return false
    }

    /// The clipping base's shape at `p` (its content and masks, without effects).
    private func shapeHit(_ base: Layer, _ p: CGPoint, _ d: Document) -> Bool {
        if base.isAdjustment { return maskAllows(base, p) }
        if base.isGroup {
            guard groupAllows(base, p) else { return false }
            return walk(base.children, ancestors: [], p: p, d: d) { _, _ in true }
        }
        return leafHit(base, p, d, effects: false)
    }

    /// A group's masks and an artboard's rectangle.
    private func groupAllows(_ g: Layer, _ p: CGPoint) -> Bool {
        AutoSelectArtboards.allows(g, p) && maskAllows(g, p)
    }

    /// Layer mask (with density) and vector mask at `p` (a mask's feather is ignored here; leaf layers with a feathered
    /// mask are tested on their rendered appearance instead).
    private func maskAllows(_ l: Layer, _ p: CGPoint) -> Bool {
        if let m = l.mask, m.isEnabled {
            let x = Int(floor(p.x)) - m.origin.x, y = Int(floor(p.y)) - m.origin.y
            let inside = x >= 0 && y >= 0 && x < m.buffer.width && y < m.buffer.height
            let v = Double(inside ? m.buffer.alpha(x, y) : m.outsideValue)
            let eff = 255 - clamp(m.density, 0, 1) * (255 - v)
            if eff <= Double(threshold) { return false }
        }
        if let vm = l.vectorMask, l.vectorMaskEnabled, !vm.isEmpty, !vm.cgPath.contains(p, using: .winding) { return false }
        return true
    }

    // MARK: Leaf layers

    private func effectsGrow(_ l: Layer) -> Bool { l.effects.enabled && l.effects.hasAny && l.effects.extent > 0 }

    private func leafHit(_ l: Layer, _ p: CGPoint, _ d: Document, effects: Bool) -> Bool {
        switch l.content {
        case .adjustment, .group:
            return false
        case .fill(let f) where f.recipe == nil:
            return maskAllows(l, p)                                        // a fill covers the canvas
        case .raster(let r) where !(effects && effectsGrow(l)) && (l.mask?.feather ?? 0) <= 0:
            let a = r.buffer.alpha(Int(floor(p.x)) - r.origin.x, Int(floor(p.y)) - r.origin.y)
            return a > threshold && maskAllows(l, p)
        default:
            return cachedAlpha(l, p, d, effects: effects && l.effects.enabled && l.effects.hasAny) > threshold
        }
    }

    /// Doc-space bounds of the layer's appearance (content plus effects that reach out), or nil if it draws nothing.
    private func bounds(_ l: Layer, d: Document, effects: Bool) -> CGRect? {
        guard var b = Compositor.shared.contentBounds(l, state: d.state), b.width > 0, b.height > 0 else { return nil }
        if effects && effectsGrow(l) { let e = CGFloat(l.effects.extent) + 2; b = b.insetBy(dx: -e, dy: -e) }
        return b
    }

    private func signature(_ l: Layer, _ d: Document, effects: Bool) -> Sig {
        let content: ContentSig
        switch l.content {
        case .raster(let r): content = .raster(ObjectIdentifier(r.buffer), r.buffer.version, r.origin)
        case .text(let t): content = .text(t)
        case .shape(let s): content = .shape(s)
        default: content = .other(d.renderVersion)
        }
        var mask = ""
        if let m = l.mask { mask = "\(ObjectIdentifier(m.buffer))-\(m.buffer.version)-\(m.origin.x),\(m.origin.y)-\(m.isEnabled)-\(m.density)-\(m.feather)-\(m.outsideValue)" }
        let flags = (l.vectorMaskEnabled ? 1 : 0) | (l.layerMaskHidesEffects ? 2 : 0) | (l.vectorMaskHidesEffects ? 4 : 0)
        return Sig(content: content, mask: mask, vmask: l.vectorMask, effects: effects ? l.effects : nil, light: d.state.globalLight,
                   flags: flags, w: d.state.width, h: d.state.height)
    }

    /// Alpha of the layer's own appearance at `p` (content × masks, plus effects), from the cached mask.
    private func cachedAlpha(_ l: Layer, _ p: CGPoint, _ d: Document, effects: Bool) -> UInt8 {
        guard let e = entry(l, d, effects: effects, near: CGRect(origin: p, size: .zero)) else { return 0 }
        return sample(e, p)
    }

    /// The layer's cached appearance mask, rendered if needed — unless `near` misses the layer's box (no render then).
    private func entry(_ l: Layer, _ d: Document, effects: Bool, near: CGRect) -> Entry? {
        let sig = signature(l, d, effects: effects)
        let key = effects ? l.id : Self.shapeKey(l.id)
        clock += 1
        if var e = cache[key], e.sig == sig {
            e.used = clock
            cache[key] = e
            return e
        }
        guard let b = bounds(l, d: d, effects: effects) else { return nil }
        let region = b.intersection(d.state.canvasCGRect).integral
        guard !region.isEmpty, near.width > 0 || near.height > 0 ? region.intersects(near) : region.contains(near.origin) else { return nil }
        let e = render(l, d, region: region, effects: effects, sig: sig)
        cache[key] = e
        trim()
        return e
    }

    /// Whether the layer draws a pixel inside `rect` (the marquee): its pixels, masks and effects, like a click.
    private func draws(_ l: Layer, in rect: CGRect, _ d: Document) -> Bool {
        let r = rect.intersection(d.state.canvasCGRect)
        guard !r.isEmpty, let b = bounds(l, d: d, effects: true), b.intersects(r) else { return false }
        if case .raster = l.content, l.mask == nil, l.vectorMask == nil, !effectsGrow(l) { return true }   // its opaque box
        guard let e = entry(l, d, effects: l.effects.enabled && l.effects.hasAny, near: r) else { return false }
        let x0 = max(0, Int(floor((r.minX - e.region.minX) * e.scale))), x1 = min(e.width, Int(ceil((r.maxX - e.region.minX) * e.scale)))
        let y0 = max(0, Int(floor((r.minY - e.region.minY) * e.scale))), y1 = min(e.height, Int(ceil((r.maxY - e.region.minY) * e.scale)))
        guard x0 < x1, y0 < y1 else { return false }
        for y in y0..<y1 { for x in x0..<x1 where e.alpha[y * e.width + x] > threshold { return true } }
        return false
    }

    /// Cache key of a layer's effect-less shape (used for clipping bases), distinct from its own id.
    private static func shapeKey(_ id: UUID) -> UUID {
        var u = id.uuid
        u.0 ^= 0x5A
        return UUID(uuid: u)
    }

    private func sample(_ e: Entry, _ p: CGPoint) -> UInt8 {
        let i = Int(floor((p.x - e.region.minX) * e.scale)), j = Int(floor((p.y - e.region.minY) * e.scale))
        guard i >= 0, j >= 0, i < e.width, j < e.height else { return 0 }
        return e.alpha[j * e.width + i]
    }

    private func render(_ layer: Layer, _ d: Document, region: CGRect, effects: Bool, sig: Sig) -> Entry {
        renders += 1
        var l = layer
        l.isVisible = true; l.isClipped = false
        l.opacity = 1; l.fillOpacity = 1; l.blendMode = .normal; l.knockout = .none; l.blendIf = BlendIf()
        if !effects { l.effects.enabled = false }
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        let img = Compositor.shared.layerAppearance(l, state: d.state)
        let area = Double(region.width * region.height)
        let s = CGFloat(min(1, (Double(maxMaskSamples) / max(1, area)).squareRoot()))
        let bw = max(1, Int(ceil(region.width * s))), bh = max(1, Int(ceil(region.height * s)))
        let ci = space.ciRect(region)
        let scaled = s < 1 ? img.transformed(by: CGAffineTransform(scaleX: s, y: s)) : img
        let rect = CGRect(x: ci.minX * s, y: ci.maxY * s - CGFloat(bh), width: CGFloat(bw), height: CGFloat(bh))
        var rgba = [UInt8](repeating: 0, count: bw * bh * 4)
        rgba.withUnsafeMutableBytes { buf in
            RenderEngine.readbackContext.render(scaled.composited(over: CIImage.clearImage.cropped(to: rect)), toBitmap: buf.baseAddress!,
                                                rowBytes: bw * 4, bounds: rect, format: .RGBA8, colorSpace: sRGBSpace)
        }
        var alpha = [UInt8](repeating: 0, count: bw * bh)
        for k in 0..<(bw * bh) { alpha[k] = rgba[k * 4 + 3] }
        return Entry(sig: sig, region: region, scale: s, width: bw, height: bh, alpha: alpha, used: clock)
    }

    private func trim() {
        var total = cache.values.reduce(0) { $0 + $1.alpha.count }
        guard total > budget else { return }
        for (k, e) in cache.sorted(by: { $0.value.used < $1.value.used }) {
            cache[k] = nil
            total -= e.alpha.count
            if total <= budget { break }
        }
    }
}

/// Artboards for hit-testing: treated as groups whose rectangle clips their children. (Kept apart: artboards are being
/// reworked separately.)
enum AutoSelectArtboards {
    /// A group passes everywhere; an artboard only inside its rectangle.
    static func allows(_ g: Layer, _ p: CGPoint) -> Bool {
        guard let ab = g.artboard else { return true }
        return ab.rect.contains(p)
    }

    /// Group mode: the outermost group around a layer, not counting artboards (Photoshop picks the top-level group inside
    /// an artboard). nil if the layer isn't in a group.
    static func outermostGroup(_ ancestors: [Layer]) -> Layer? {
        ancestors.first { !$0.isArtboard }
    }
}

/// Target of the Move tool's "layers under the cursor" context menu items.
final class AutoSelectMenuTarget: NSObject {
    static let shared = AutoSelectMenuTarget()
    @objc func pick(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID, let d = AppActions.doc, d.state.layer(id) != nil else { return }
        d.selectLayer(id)
        LayerGroups.reveal(d, id)
    }
}
