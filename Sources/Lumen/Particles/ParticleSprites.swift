import Foundation
import CoreGraphics
import CoreText
import Metal
import AppKit
import ImageCratCore

/// Identifies one procedurally generated sprite (and its variants) in the atlas.
struct PSpriteKey: Hashable {
    var kind: PSprite
    var points = 5
    var softness = 60           // percent
    var text = ""
    var font = ""
    var shape = ""
    var imageHash = 0

    init(_ s: ParticleSystemSettings) {
        kind = s.sprite
        switch s.sprite {
        case .star, .bokeh, .sparkle: points = Int(s.spritePoints.rounded())
        default: points = 0
        }
        switch s.sprite {
        case .softDisc, .bokeh: softness = Int((s.spriteSoftness * 20).rounded()) * 5
        case .hardDisc: softness = 0
        default: softness = 0
        }
        if s.sprite == .glyph { text = s.spriteText; font = s.spriteFont }
        if s.sprite == .shape { shape = s.spriteShape }
        if s.sprite == .image { imageHash = s.spriteImagePNG?.hashValue ?? 0 }
    }
}

/// Sprite bitmaps: 256 × 256 premultiplied RGBA, row 0 at the top. Most are white (tinted per particle).
enum ParticleSprites {
    static let size = 256

    /// Reserved atlas layers used by trails.
    static let barLayer = 0, cometLayer = 1, glowLayer = 2, reserved = 3

    typealias Pixel = (g: Double, a: Double)

    @inline(__always) static func sstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        if e0 == e1 { return x < e0 ? 0 : 1 }
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// Fills a layer from a per-pixel function of (u, v) in [-1, 1] (v down), optionally supersampled.
    static func make(samples: Int = 1, _ f: (Double, Double) -> Pixel) -> [UInt8] {
        let n = size
        var out = [UInt8](repeating: 0, count: n * n * 4)
        let inv = 2.0 / Double(n)
        for y in 0..<n {
            for x in 0..<n {
                var g = 0.0, a = 0.0
                for sy in 0..<samples {
                    for sx in 0..<samples {
                        let u = (Double(x) + (Double(sx) + 0.5) / Double(samples)) * inv - 1
                        let v = (Double(y) + (Double(sy) + 0.5) / Double(samples)) * inv - 1
                        let p = f(u, v)
                        let pa = min(1, max(0, p.a))
                        g += min(1, max(0, p.g)) * pa; a += pa
                    }
                }
                let k = 1.0 / Double(samples * samples)
                g *= k; a *= k
                let i = (y * n + x) * 4
                let gv = UInt8((g * 255).rounded())
                out[i] = gv; out[i + 1] = gv; out[i + 2] = gv; out[i + 3] = UInt8((a * 255).rounded())
            }
        }
        return out
    }

    static func disc(softness s: Double) -> [UInt8] {
        make(samples: s < 0.2 ? 2 : 1) { u, v in
            let r = sqrt(u * u + v * v)
            if s >= 0.95 {
                let e = exp(-5.0)
                return (1, max(0, (exp(-5 * r * r) - e) / (1 - e)) * (1 - sstep(0.92, 1, r)))
            }
            let inner = (1 - s) * 0.95
            return (1, 1 - sstep(inner, 0.97, r))
        }
    }

    static func sdStar(_ px: Double, _ py: Double, r: Double, n: Int, m: Double) -> Double {
        let an = Double.pi / Double(n), en = Double.pi / m
        let acx = cos(an), acy = sin(an), ecx = cos(en), ecy = sin(en)
        var bn = atan2(px, py).truncatingRemainder(dividingBy: 2 * an)
        if bn < 0 { bn += 2 * an }
        bn -= an
        let len = sqrt(px * px + py * py)
        var x = len * cos(bn), y = len * abs(sin(bn))
        x -= r * acx; y -= r * acy
        let k = min(max(-(x * ecx + y * ecy), 0), r * acy / ecy)
        x += ecx * k; y += ecy * k
        return sqrt(x * x + y * y) * (x < 0 ? -1 : 1)
    }

    static func star(points: Int) -> [UInt8] {
        let n = max(3, min(24, points))
        let m = max(2.0, Double(n) * 0.5)
        return make(samples: 2) { u, v in
            let d = sdStar(u, -v, r: 0.92, n: n, m: m)
            return (1, 1 - sstep(-0.012, 0.012, d))
        }
    }

    static func sparkle(points: Int) -> [UInt8] {
        let axes = max(2, min(6, (points <= 0 ? 4 : points) / 2))
        return make { u, v in
            let r = sqrt(u * u + v * v)
            var a = exp(-r * r * 38) * 1.0 + 0.25 * exp(-r * r * 6)
            for k in 0..<axes {
                let ang = Double(k) * .pi / Double(axes)
                let x = u * cos(ang) + v * sin(ang), y = -u * sin(ang) + v * cos(ang)
                let len = (axes == 2 || k % 2 == 0) ? 1.0 : 0.62
                let t = max(0, 1 - abs(x) / len)
                let w = 0.006 + 0.05 * t * t
                a += exp(-abs(y) / w) * t * t * 0.95
            }
            return (1, a * (1 - sstep(0.93, 1, r)))
        }
    }

    static func snowflake(variant k: Int) -> [UInt8] {
        let sets: [[(Double, Double)]] = [
            [(0.35, 0.24), (0.58, 0.2), (0.78, 0.12)],
            [(0.3, 0.32), (0.62, 0.22)],
            [(0.25, 0.14), (0.45, 0.26), (0.68, 0.18), (0.84, 0.08)],
            [(0.5, 0.34), (0.74, 0.16)],
        ]
        let branches = sets[k % sets.count]
        let w = 0.032 + 0.008 * Double(k % 2)
        func seg(_ px: Double, _ py: Double, _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
            let pax = px - ax, pay = py - ay, bax = bx - ax, bay = by - ay
            let h = min(1, max(0, (pax * bax + pay * bay) / (bax * bax + bay * bay)))
            let dx = pax - bax * h, dy = pay - bay * h
            return sqrt(dx * dx + dy * dy)
        }
        return make(samples: 2) { u, v in
            let r = sqrt(u * u + v * v)
            var th = atan2(v, u).truncatingRemainder(dividingBy: .pi / 3)
            if th < 0 { th += .pi / 3 }
            th = abs(th - .pi / 6)
            let x = r * cos(th), y = r * sin(th)
            var d = seg(x, y, 0, 0, 0.93, 0)
            for (pos, len) in branches {
                d = min(d, seg(x, y, pos, 0, pos + len * 0.5, len * 0.866))
            }
            // small hexagonal plate in the centre
            let hex = abs(r * cos(th) - 0.13)
            if r < 0.2 { d = min(d, hex) }
            return (1, 1 - sstep(w - 0.012, w + 0.012, d))
        }
    }

    static func smoke(variant k: Int) -> [UInt8] {
        let ox = Double(k) * 7.31 + 1.7, oy = Double(k) * 3.77 + 9.2
        return make { u, v in
            let r = sqrt(u * u + v * v)
            let r2 = r * (1 + 0.28 * PNoise.value(u * 1.1 + ox * 2, v * 1.1 - oy, 0.5))
            let fall = 1 - sstep(0.1, 0.96, r2)
            let tex = min(1, max(0, 0.55 + 0.75 * PNoise.fbm(u * 1.7 + ox, v * 1.7 + oy, 0.3, octaves: 4)))
            return (1, pow(fall, 1.25) * tex * (1 - sstep(0.9, 1, r)))
        }
    }

    static func flame(variant k: Int) -> [UInt8] {
        make { u, v in
            let t = (1 - v) / 2            // 0 bottom … 1 tip
            if t <= 0.001 || t >= 0.999 { return (1, 0) }
            let uu = u + 0.2 * t * sin(5 * t + Double(k) * 2.1) + 0.06 * PNoise.value(u * 2 + Double(k) * 5, v * 2.5, 1)
            let w = 1.45 * sqrt(t) * pow(1 - t, 1.1)
            let q = abs(uu) / max(1e-3, w)
            let a = pow(max(0, 1 - q * q), 1.3) * sstep(0, 0.1, t)
            return (1, a)
        }
    }

    static func polygonQ(_ u: Double, _ v: Double, n: Int) -> Double {
        let r = sqrt(u * u + v * v)
        if n >= 9 || n < 3 { return r }
        let seg = 2 * Double.pi / Double(n)
        var th = (atan2(v, u) + .pi / 2).truncatingRemainder(dividingBy: seg)
        if th < 0 { th += seg }
        let rho = cos(.pi / Double(n)) / cos(th - seg / 2)
        let q = r / rho * cos(.pi / Double(n)) / 0.92      // keep the polygon inside the unit disc
        return q * 0.8 + r * 0.2 * (1 / 0.98)              // slightly rounded blades
    }

    static func bokeh(blades: Int, softness s: Double) -> [UInt8] {
        make(samples: 2) { u, v in
            let q = polygonQ(u, v, n: blades) / 0.98
            let edge = 1 - sstep(0.95 - 0.35 * s, 0.985, q)
            let rim = 0.52 + 0.48 * sstep(0.74, 0.9, q)
            return (1, edge * rim)
        }
    }

    static func bubble() -> [UInt8] {
        make(samples: 2) { u, v in
            let r = sqrt(u * u + v * v)
            if r > 1 { return (1, 0) }
            let rim = sstep(0.74, 0.93, r) * (1 - sstep(0.94, 0.985, r))
            let inside = (0.05 + 0.1 * r * r) * (1 - sstep(0.94, 0.985, r))
            let d1 = (u + 0.42) * (u + 0.42) + (v + 0.46) * (v + 0.46)
            let hl = exp(-d1 / 0.014)
            let d2 = (u - 0.4) * (u - 0.4) + (v - 0.45) * (v - 0.45)
            let hl2 = exp(-d2 / 0.03) * sstep(0.45, 0.8, r)
            return (1, 0.85 * rim + inside + 0.95 * hl + 0.35 * hl2)
        }
    }

    static func rect(insetY: Double = 0.04) -> [UInt8] {
        make(samples: 2) { u, v in (1, (abs(u) < 0.96 && abs(v) < 1 - insetY) ? 1 : 0) }
    }

    static func triangle() -> [UInt8] {
        make(samples: 3) { u, v in
            // (−0.92, 0.85) (0.92, 0.85) (0, −0.9)
            if v > 0.85 { return (1, 0) }
            let t = (v + 0.9) / 1.75
            return (1, t >= 0 && abs(u) < 0.92 * t ? 1 : 0)
        }
    }

    static func heart() -> [UInt8] {
        make(samples: 3) { u, v in
            let x = u * 1.22, y = -v * 1.22 + 0.22
            let q = x * x + y * y - 1
            let f = q * q * q - x * x * y * y * y
            return (0.86 + 0.14 * max(0, 1 - ((u + 0.35) * (u + 0.35) + (v + 0.4) * (v + 0.4)) / 0.2), f < 0 ? 1 : 0)
        }
    }

    static func leaf(variant k: Int) -> [UInt8] {
        make(samples: 3) { u, v in
            let t = (v + 1) / 2
            if t <= 0 || t >= 1 { return (1, 0) }
            let tt = pow(t, k == 0 ? 0.8 : 1.15)
            let w = (k == 0 ? 0.5 : 0.42) * pow(sin(.pi * tt), 1.25)
            let bend = 0.08 * sin(.pi * t) * (k == 0 ? 1 : -1)
            let uu = u - bend
            if abs(uu) > w { return (1, 0) }
            var g = 1 - 0.32 * exp(-(uu / 0.035) * (uu / 0.035))
            let vein = abs(((t * 9 + abs(uu) * 5).truncatingRemainder(dividingBy: 1)) - 0.5)
            g -= 0.1 * (1 - sstep(0, 0.08, vein))
            g *= 0.82 + 0.18 * (1 - abs(uu) / max(1e-3, w))
            return (g, 1)
        }
    }

    static func petal() -> [UInt8] {
        make(samples: 3) { u, v in
            let t = (1 - v) / 2
            if t <= 0 || t >= 1 { return (1, 0) }
            let w = 0.62 * pow(sin(.pi * pow(t, 1.45)), 0.62)
            if abs(u) > w { return (1, 0) }
            let g = 0.74 + 0.26 * t - 0.08 * exp(-(u / 0.05) * (u / 0.05)) * (1 - t)
            return (g, 1)
        }
    }

    static func dust(variant k: Int) -> [UInt8] {
        let sx = [1.0, 1.35, 0.8][k % 3], sy = [1.0, 0.8, 1.3][k % 3]
        return make { u, v in
            let r = sqrt(u * u * sx * sx + v * v * sy * sy)
            let n = 0.65 + 0.35 * PNoise.value(u * 2.2 + Double(k) * 4.1, v * 2.2, 2)
            return (1, exp(-r * r * 4.2) * n * (1 - sstep(0.85, 1, r)))
        }
    }

    static func lensDirt(variant k: Int) -> [UInt8] {
        make { u, v in
            let r0 = sqrt(u * u + v * v)
            let r = r0 * (1 + 0.12 * PNoise.value(u * 1.3 + Double(k) * 3.3, v * 1.3, 4))
            let body = 0.32 * (1 - sstep(0.6, 0.92, r))
            let ring = 0.5 * exp(-pow((r - 0.78) / 0.07, 2)) * (0.6 + 0.4 * PNoise.value(u * 3 + Double(k), v * 3, 7))
            let speck = k % 2 == 0 ? 0.0 : 0.35 * exp(-((u - 0.2) * (u - 0.2) + (v + 0.15) * (v + 0.15)) / 0.02)
            return (1, (body + ring + speck) * (1 - sstep(0.93, 1, r0)))
        }
    }

    static func balloon() -> [UInt8] {
        make(samples: 3) { u, v in
            let bx = u / 0.56, by = (v + 0.3) / 0.66
            let q = bx * bx + by * by
            if q < 1 {
                let hl = exp(-((u + 0.2) * (u + 0.2) + (v + 0.56) * (v + 0.56)) / 0.035)
                let shade = 0.78 + 0.1 * (1 - q) + 0.3 * hl - 0.12 * max(0, u * 0.8 + v * 0.3 + 0.2)
                return (shade, 0.96)
            }
            // knot
            if v > 0.34 && v < 0.46 && abs(u) < (v - 0.33) * 0.7 { return (0.7, 0.96) }
            // string
            if v >= 0.46 && abs(u - 0.05 * sin(v * 9)) < 0.012 { return (0.75, 0.7) }
            return (1, 0)
        }
    }

    static func ember() -> [UInt8] {
        make { u, v in
            let r2 = u * u + v * v
            let e = 0.4 * exp(-4.5)
            return (1, (exp(-r2 * 28) + 0.4 * exp(-r2 * 4.5) - e) * (1 - sstep(0.9, 1, sqrt(r2))))
        }
    }

    static func streak() -> [UInt8] {
        make { u, v in (1, exp(-(v / 0.12) * (v / 0.12) * 1.0) * (1 - sstep(0.55, 1, abs(u))) * (1 - sstep(0.7, 1, abs(v)))) }
    }

    static func bar() -> [UInt8] {
        make { _, v in (1, 1 - sstep(0.3, 1, abs(v))) }
    }

    static func comet(slim: Bool) -> [UInt8] {
        make { u, v in
            let along = (u + 1) / 2
            let w = slim ? 0.3 : 0.14 + 0.3 * along
            let body = slim ? 0.25 + 0.75 * along * along : pow(along, 1.6)
            return (1, body * exp(-(v / w) * (v / w)) * (1 - sstep(0.86, 1, u)) * (1 - sstep(0.8, 1, abs(v))) * sstep(-1, -0.9, u))
        }
    }

    // MARK: Core Graphics sprites

    private static func cgLayer(_ draw: (CGContext, CGRect) -> Void) -> [UInt8] {
        let n = size
        var out = [UInt8](repeating: 0, count: n * n * 4)
        out.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: sRGBSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .high
            draw(ctx, CGRect(x: 0, y: 0, width: n, height: n))
        }
        return out
    }

    static func glyph(_ ch: String, font: String) -> [UInt8] {
        cgLayer { ctx, r in
            let f = CTFontCreateWithName((font.isEmpty ? "Helvetica" : font) as CFString, r.height * 0.72, nil)
            let attr = NSAttributedString(string: ch, attributes: [.font: f as Any, .foregroundColor: NSColor.white])
            let line = CTLineCreateWithAttributedString(attr)
            let b = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            let bb = b.isNull || b.isEmpty ? CTLineGetBoundsWithOptions(line, []) : b
            // scale to fit with a margin
            let s = min(1, min(r.width * 0.9 / max(1, bb.width), r.height * 0.9 / max(1, bb.height)))
            ctx.translateBy(x: r.midX, y: r.midY)
            ctx.scaleBy(x: s, y: s)
            ctx.textPosition = CGPoint(x: -bb.midX, y: -bb.midY)
            CTLineDraw(line, ctx)
        }
    }

    static func libraryShape(_ id: String) -> [UInt8] {
        cgLayer { ctx, r in
            guard let s = ShapeLibrary.shape(id) ?? ShapeLibrary.all.first else { return }
            // CG is y-up here: flip so the shape's y-down unit square lands upright
            ctx.translateBy(x: 0, y: r.height); ctx.scaleBy(x: 1, y: -1)
            let res = s.path(in: r.insetBy(dx: 10, dy: 10)).resolved
            ctx.addPath(res.path)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath(using: res.evenOdd ? .evenOdd : .winding)
        }
    }

    static func image(base64 png: String?) -> [UInt8] {
        guard let png, let data = Data(base64Encoded: png), let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return disc(softness: 0.6) }
        return image(img)
    }

    static func image(_ img: CGImage) -> [UInt8] {
        cgLayer { ctx, r in
            let s = min(r.width / CGFloat(img.width), r.height / CGFloat(img.height))
            let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
            ctx.draw(img, in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
        }
    }

    /// Layers (variants) for a sprite key.
    static func layers(for key: PSpriteKey, imagePNG: String?) -> [[UInt8]] {
        switch key.kind {
        case .softDisc: return [disc(softness: Double(key.softness) / 100)]
        case .hardDisc: return [disc(softness: 0.04)]
        case .star: return [star(points: key.points)]
        case .sparkle: return [sparkle(points: key.points)]
        case .streak: return [streak()]
        case .snowflake: return (0..<4).map { snowflake(variant: $0) }
        case .raindrop: return [comet(slim: true)]
        case .bubble: return [bubble()]
        case .smoke: return (0..<4).map { smoke(variant: $0) }
        case .flame: return (0..<3).map { flame(variant: $0) }
        case .ember: return [ember()]
        case .confettiRect, .square: return [rect()]
        case .confettiTriangle: return [triangle()]
        case .bokeh: return [bokeh(blades: key.points, softness: Double(key.softness) / 100)]
        case .heart: return [heart()]
        case .leaf: return (0..<2).map { leaf(variant: $0) }
        case .petal: return [petal()]
        case .dust: return (0..<3).map { dust(variant: $0) }
        case .lensDirt: return (0..<4).map { lensDirt(variant: $0) }
        case .balloon: return [balloon()]
        case .glyph:
            let chars = Array(key.text.isEmpty ? "✦" : key.text).filter { !$0.isWhitespace }.prefix(48)
            let list = chars.isEmpty ? ["✦"] : chars.map { String($0) }
            return list.map { glyph($0, font: key.font) }
        case .shape: return [libraryShape(key.shape)]
        case .image: return [image(base64: imagePNG)]
        }
    }

    static func cgImage(_ bytes: [UInt8]) -> CGImage? {
        let n = size
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: sRGBSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// GPU texture array holding every sprite an effect needs (mipmapped for clean minification and DOF blur).
final class ParticleSpriteAtlas {
    let texture: MTLTexture
    let ranges: [PSpriteKey: (base: Int, count: Int)]

    private init(texture: MTLTexture, ranges: [PSpriteKey: (base: Int, count: Int)]) {
        self.texture = texture
        self.ranges = ranges
    }

    func range(_ s: ParticleSystemSettings) -> (base: Int, count: Int) { ranges[PSpriteKey(s)] ?? (ParticleSprites.glowLayer, 1) }

    private static var layerCache: [PSpriteKey: [[UInt8]]] = [:]
    private static var reservedLayers: [[UInt8]]?
    private static var atlasCache: [[PSpriteKey]: ParticleSpriteAtlas] = [:]
    private static let lock = NSLock()

    /// Memory pressure: sprite layers and atlases are rebuilt on demand.
    static func purge() {
        lock.lock(); atlasCache.removeAll(); layerCache.removeAll(); lock.unlock()
    }

    /// Sprite keys of every (sub-)system, in a stable order.
    static func keys(_ systems: [ParticleSystemSettings]) -> [(PSpriteKey, String?)] {
        var out: [(PSpriteKey, String?)] = []
        func visit(_ s: ParticleSystemSettings) {
            let k = PSpriteKey(s)
            if !out.contains(where: { $0.0 == k }) { out.append((k, s.spriteImagePNG)) }
            for c in s.sub { visit(c) }
        }
        for s in systems { visit(s) }
        return out
    }

    static func atlas(for systems: [ParticleSystemSettings]) -> ParticleSpriteAtlas? {
        let ks = keys(systems)
        lock.lock(); defer { lock.unlock() }
        if let a = atlasCache[ks.map(\.0)] { return a }
        if reservedLayers == nil {
            reservedLayers = [ParticleSprites.bar(), ParticleSprites.comet(slim: false), ParticleSprites.disc(softness: 1)]
        }
        var layers = reservedLayers!
        var ranges: [PSpriteKey: (base: Int, count: Int)] = [:]
        for (k, png) in ks {
            let ls: [[UInt8]]
            if let c = layerCache[k] { ls = c } else {
                ls = ParticleSprites.layers(for: k, imagePNG: png)
                layerCache[k] = ls
            }
            ranges[k] = (layers.count, ls.count)
            layers += ls
        }
        let n = ParticleSprites.size
        let td = MTLTextureDescriptor()
        td.textureType = .type2DArray
        td.pixelFormat = .rgba8Unorm
        td.width = n; td.height = n
        td.arrayLength = layers.count
        td.mipmapLevelCount = 1 + Int(log2(Double(n)))
        td.usage = [.shaderRead, .renderTarget]
        td.storageMode = .private
        let dev = RenderEngine.device
        guard let tex = dev.makeTexture(descriptor: td) else { return nil }
        // upload through a shared staging texture (private textures can't be written from the CPU)
        let sd = MTLTextureDescriptor()
        sd.textureType = .type2DArray
        sd.pixelFormat = .rgba8Unorm
        sd.width = n; sd.height = n
        sd.arrayLength = layers.count
        sd.usage = [.shaderRead]
        sd.storageMode = .shared
        guard let stage = dev.makeTexture(descriptor: sd), let cb = RenderEngine.commandQueue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        for (i, l) in layers.enumerated() {
            l.withUnsafeBytes { raw in
                stage.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, slice: i, withBytes: raw.baseAddress!, bytesPerRow: n * 4, bytesPerImage: n * n * 4)
            }
            blit.copy(from: stage, sourceSlice: i, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: n, height: n, depth: 1),
                      to: tex, destinationSlice: i, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        blit.generateMipmaps(for: tex)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let a = ParticleSpriteAtlas(texture: tex, ranges: ranges)
        if atlasCache.count > 24 { atlasCache.removeAll() }
        atlasCache[ks.map(\.0)] = a
        return a
    }
}
