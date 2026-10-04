import AppKit
import SwiftUI
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

/// Headless tests: `LUMEN_SELFTEST_ONLY=particles .build/debug/Lumen --selftest <outdir>`.
/// `LUMEN_PARTICLES_ONLY=sheets,determinism,…` runs a subset; `LUMEN_PARTICLES_PRESETS=fire,snow.light` renders
/// only those presets (full size, one PNG each).
enum ParticleSelfTest {
    static var passed = 0, failed = 0

    static func check(_ ok: Bool, _ msg: String) {
        if ok { passed += 1; print("PASS particles: \(msg)") } else { failed += 1; print("FAIL particles: \(msg)") }
    }

    static func run(_ out: URL) {
        let dir = out.appendingPathComponent("particles")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["LUMEN_PARTICLES_ONLY"]
        func want(_ n: String) -> Bool { only == nil || only!.split(separator: ",").contains { n.hasPrefix($0) } }
        if want("sprites") { testSprites(dir) }
        if want("sheets") { testPresetSheets(dir) }
        if want("emitters") { testEmitters(dir) }
        if want("determinism") { testDeterminism(dir) }
        if want("decode") { testCoding(dir) }
        if want("features") { testFeatures(dir) }
        if want("clip") { testClipAndSubject(dir) }
        if want("output") { testOutputs(dir) }
        if want("smart") { testSmartObject(dir) }
        if want("animation") { testAnimation(dir) }
        if want("cancel") { testCancel(dir) }
        if want("userpresets") { testUserPresets(dir) }
        if want("handles") { testHandles(dir) }
        if want("perf") { testPerformance(dir) }
        // offscreen snapshots of the dialog views (opt-in: LUMEN_PARTICLES_ONLY=ui)
        if only?.split(separator: ",").contains("ui") == true { testUISnapshots(dir) }
        print("particles: \(passed) passed, \(failed) failed")
    }

    // MARK: Helpers

    static func writePNG(_ cg: CGImage, _ url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    static func darkBackground(_ w: Int, _ h: Int) -> CGImage {
        let b = PixelBuffer(width: w, height: h)
        let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "0A0C14")!.cgColor, RGBA(hex: "151A26")!.cgColor] as CFArray, locations: [0, 1])!
        b.context.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        b.markDirty()
        return b.makeCGImage()
    }

    /// A generic system wallpaper (never a personal file); falls back to a synthetic landscape.
    static func photoBackground(_ w: Int, _ h: Int) -> CGImage {
        let candidates = ["/System/Library/Desktop Pictures/.thumbnails/Big Sur Coastline.heic", "/System/Library/Desktop Pictures/.thumbnails/Catalina Coast.heic",
                          "/System/Library/Desktop Pictures/.thumbnails/Big Sur Road.heic"]
        let b = PixelBuffer(width: w, height: h)
        for c in candidates {
            if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: c) as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                // aspect fill
                let s = max(CGFloat(w) / CGFloat(img.width), CGFloat(h) / CGFloat(img.height))
                let dw = CGFloat(img.width) * s, dh = CGFloat(img.height) * s
                b.drawImage(img, in: CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh))
                b.markDirty()
                return b.makeCGImage()
            }
        }
        let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "6FA8DC")!.cgColor, RGBA(hex: "F6D7A8")!.cgColor, RGBA(hex: "3D5A3A")!.cgColor] as CFArray, locations: [0, 0.55, 1])!
        b.context.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        b.markDirty()
        return b.makeCGImage()
    }

    static func subjectLayer(_ w: Int, _ h: Int) -> PixelBuffer { ParticleSources.demoSubject(w, h) }

    static func context(for preset: ParticlePreset, _ w: Int, _ h: Int) -> ParticleContext {
        let ctx = ParticleContext(width: w, height: h)
        if preset.id == "dispersion" {
            let layer = subjectLayer(w, h)
            ctx.layerColor = PColorMap(cgImage: layer.makeCGImage())
            ctx.layerAlpha = PMap(buffer: layer, useAlpha: true)
        }
        return ctx
    }

    /// Renders a preset over a background (for the dispersion preset: over the masked subject layer).
    static func renderPreset(_ p: ParticlePreset, _ w: Int, _ h: Int, background: CGImage) -> (CGImage?, ParticleEngine.Output) {
        let e = p.make(Double(w) / Double(h))
        let ctx = context(for: p, w, h)
        var bg = CIImage(cgImage: background)
        if p.id == "dispersion" {
            var layer = CIImage(cgImage: subjectLayer(w, h).makeCGImage())
            if e.maskSourceLayer, let s = e.systems.first {
                let cover = ParticleSystem.sweepCoverage(s, effect: e, ctx: ctx, index: 0, T: e.time).buffer(width: w, height: h)
                layer = layer.masked(byGray: cover.ciImage.inverted())
            }
            bg = layer.composited(over: bg)
        }
        let o = ParticleEngine.render(e, ctx: ctx)
        let img = ParticleEngine.composite(o, over: bg, effect: e, ctx: ctx)
        return (RenderEngine.cgImage(img, rect: CGRect(x: 0, y: 0, width: w, height: h)), o)
    }

    static func label(_ ctx: CGContext, _ text: String, at p: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(s)
        let b = CTLineGetBoundsWithOptions(line, [])
        ctx.setFillColor(NSColor(white: 0, alpha: 0.6).cgColor)
        ctx.fill(CGRect(x: p.x - 4, y: p.y - 6, width: b.width + 8, height: b.height + 8))
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }

    // MARK: Tests

    static func testSprites(_ dir: URL) {
        let kinds = PSprite.allCases
        let cell = 160, cols = 8
        let rows = (kinds.count + cols - 1) / cols
        guard let ctx = CGContext(data: nil, width: cols * cell, height: rows * cell, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(RGBA(hex: "20242E")!.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: cols * cell, height: rows * cell))
        var ok = true
        for (i, k) in kinds.enumerated() {
            var s = ParticleSystemSettings()
            s.sprite = k
            if k == .glyph { s.spriteText = "★" }
            let layers = ParticleSprites.layers(for: PSpriteKey(s), imagePNG: nil)
            guard let first = layers.first, let img = ParticleSprites.cgImage(first) else { ok = false; continue }
            // every sprite must contain visible pixels
            var sum = 0
            for j in stride(from: 3, to: first.count, by: 4) { sum += Int(first[j]) }
            if sum < 2000 { ok = false; print("  empty sprite: \(k.rawValue)") }
            let x = (i % cols) * cell, y = (rows - 1 - i / cols) * cell
            ctx.draw(img, in: CGRect(x: x + 16, y: y + 24, width: cell - 32, height: cell - 32))
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.8, alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: k.rawValue, attributes: attrs))
            ctx.textPosition = CGPoint(x: x + 8, y: y + 6)
            CTLineDraw(line, ctx)
        }
        if let img = ctx.makeImage() { writePNG(img, dir.appendingPathComponent("sprites.png")) }
        check(ok, "all \(kinds.count) sprite kinds generate visible pixels")
    }

    static func testPresetSheets(_ dir: URL) {
        let W = 960, H = 540
        let bgs: [(String, CGImage)] = [("dark", darkBackground(W, H)), ("photo", photoBackground(W, H))]
        if let list = ProcessInfo.processInfo.environment["LUMEN_PARTICLES_PRESETS"] {
            let ids = list.split(separator: ",").map(String.init)
            for p in ParticlePresets.all where ids.contains(where: { p.id.hasPrefix($0) }) {
                for (bn, bg) in [("dark", darkBackground(1600, 900)), ("photo", photoBackground(1600, 900))] {
                    let (img, o) = renderPreset(p, 1600, 900, background: bg)
                    if let img { writePNG(img, dir.appendingPathComponent("preset_\(p.id)_\(bn).png")) }
                    print(String(format: "  %@ [%@]: %d particles, %d sprites, sim %.0f ms, render %.0f ms", p.id, bn, o.particles, o.instances, o.simSeconds * 1000, o.renderSeconds * 1000))
                    if bn == "dark" {
                        // vertical distribution of the sprites (tenths of the canvas height)
                        let e = p.make(1600.0 / 900.0)
                        let sim = ParticleSystem.simulate(e, ctx: context(for: p, 1600, 900), atlas: ParticleSpriteAtlas.atlas(for: e.systems))
                        var hist = [Int](repeating: 0, count: 10)
                        for r in sim.runs { for i in r.instances where i.y >= 0 && i.y < 900 { hist[min(9, Int(i.y / 90))] += 1 } }
                        print("    vertical distribution: \(hist)")
                    }
                }
            }
            return
        }
        var allOK = true
        for (bn, bg) in bgs {
            for cat in ParticlePresets.categories {
                let presets = ParticlePresets.all.filter { $0.category == cat }
                let per = 4
                for page in 0..<((presets.count + per - 1) / per) {
                    guard let ctx = CGContext(data: nil, width: W * 2, height: H * 2, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                    ctx.setFillColor(NSColor.black.cgColor)
                    ctx.fill(CGRect(x: 0, y: 0, width: W * 2, height: H * 2))
                    for k in 0..<per {
                        let idx = page * per + k
                        guard idx < presets.count else { break }
                        let p = presets[idx]
                        let (img, o) = renderPreset(p, W, H, background: bg)
                        let x = (k % 2) * W, y = (1 - k / 2) * H
                        if let img { ctx.draw(img, in: CGRect(x: x, y: y, width: W, height: H)) } else { allOK = false }
                        if o.instances == 0 { allOK = false; print("  no particles: \(p.id)") }
                        label(ctx, p.name, at: CGPoint(x: x + 14, y: y + 14))
                        if bn == "dark" {
                            print(String(format: "  %@: %d particles, %d sprites, sim %.0f ms, render %.0f ms", p.id, o.particles, o.instances, o.simSeconds * 1000, o.renderSeconds * 1000))
                        }
                    }
                    let slug = cat.lowercased().replacingOccurrences(of: " & ", with: "_").replacingOccurrences(of: " ", with: "_")
                    if let img = ctx.makeImage() { writePNG(img, dir.appendingPathComponent("sheet_\(bn)_\(slug)_\(page + 1).png")) }
                }
            }
        }
        check(allOK, "all \(ParticlePresets.all.count) presets render with particles on dark and photo backgrounds")
    }

    // MARK: Test documents & pixel helpers

    static func testDocument(_ w: Int = 640, _ h: Int = 400, subject: Bool = false) -> Document {
        var st = DocumentState(width: w, height: h)
        st.layers = [Layer.raster(name: "Background", buffer: PixelBuffer(cgImage: photoBackground(w, h)))]
        if subject { st.layers.append(Layer.raster(name: "Subject", buffer: subjectLayer(w, h))) }
        return Document(state: st, name: "Particles Test")
    }

    static func bytes(_ b: PixelBuffer) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: b.width * b.height * b.bytesPerPixel)
        let rb = b.width * b.bytesPerPixel
        out.withUnsafeMutableBytes { dst in
            for y in 0..<b.height { memcpy(dst.baseAddress! + y * rb, b.data + y * b.bytesPerRow, rb) }
        }
        return out
    }

    static func flat(_ st: DocumentState) -> [UInt8] {
        guard let cg = Compositor.shared.flatten(st, background: .black) else { return [] }
        return bytes(PixelBuffer(cgImage: cg))
    }

    /// Largest and mean absolute byte difference.
    static func diff(_ a: [UInt8], _ b: [UInt8]) -> (max: Int, mean: Double) {
        guard a.count == b.count, !a.isEmpty else { return (255, 255) }
        var mx = 0, sum = 0
        for i in 0..<a.count { let d = abs(Int(a[i]) - Int(b[i])); mx = max(mx, d); sum += d }
        return (mx, Double(sum) / Double(a.count))
    }

    /// Sum of alpha inside a rect of an RGBA buffer placed at `origin` in the canvas.
    static func alphaSum(_ b: PixelBuffer, origin: IPoint, in r: IRect) -> Int {
        var sum = 0
        for y in r.minY..<r.maxY { for x in r.minX..<r.maxX { sum += Int(b.alpha(x - origin.x, y - origin.y)) } }
        return sum
    }

    /// A sine wave across the canvas (normalized points).
    static func wavePath(_ n: Int) -> [CGPoint] {
        var pts: [CGPoint] = []
        for k in 0...n {
            let t = Double(k) / Double(n)
            pts.append(CGPoint(x: 0.1 + 0.8 * t, y: 0.5 + 0.3 * sin(t * 2 * Double.pi)))
        }
        return pts
    }

    static func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    static func effect(_ id: String, _ d: Document) -> ParticleEffect {
        ParticlePresets.effect(id, aspect: Double(d.state.width) / Double(d.state.height)) ?? ParticleEffect()
    }

    // MARK: Emitters

    static func testEmitters(_ dir: URL) {
        let W = 480, H = 300
        let shapes = PEmitterShape.allCases
        let cols = 5, rows = (shapes.count + cols - 1) / cols
        guard let sheet = CGContext(data: nil, width: W * cols, height: H * rows, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let ctx = ParticleContext(width: W, height: H)
        let subj = subjectLayer(W, H)
        ctx.layerAlpha = PMap(buffer: subj, useAlpha: true)
        ctx.layerColor = PColorMap(cgImage: subj.makeCGImage())
        ctx.brightness = PMap(buffer: PixelBuffer(cgImage: photoBackground(W, H)))
        let sel = PixelBuffer(width: W, height: H, format: .gray)
        sel.context.setFillColor(gray: 1, alpha: 1)
        sel.context.fillEllipse(in: CGRect(x: 60, y: 50, width: 200, height: 160))
        sel.context.fill(CGRect(x: 300, y: 150, width: 120, height: 100))
        sel.markDirty()
        ctx.selection = PMap(buffer: sel)
        var ok = true
        for (i, shape) in shapes.enumerated() {
            var s = ParticleSystemSettings()
            s.shape = shape; s.emission = .burst; s.count = 3500; s.immortal = true; s.speedMin = 0; s.speedMax = 0
            s.sprite = .softDisc; s.sizeMin = 5; s.sizeMax = 8; s.opacityCurve = .flat; s.gradient = .hex("8FE9FF", "8FE9FF")
            s.size = CGSize(width: 0.6, height: 0.6); s.emitterRotation = shape == .rectangle || shape == .frame ? 20 : 0
            s.pathPoints = wavePath(30)
            s.text = "Aa"; s.arms = 3
            if shape == .grid { s.count = 600 }
            var e = ParticleEffect(); e.systems = [s]; e.time = 1
            let o = ParticleEngine.render(e, ctx: ctx)
            if o.instances < 100 { ok = false; print("  emitter \(shape.rawValue): only \(o.instances) particles") }
            let bg = CIImage(cgImage: darkBackground(W, H))
            if let img = RenderEngine.cgImage(ParticleEngine.composite(o, over: bg, effect: e, ctx: ctx), rect: CGRect(x: 0, y: 0, width: W, height: H)) {
                let x = (i % cols) * W, y = (rows - 1 - i / cols) * H
                sheet.draw(img, in: CGRect(x: x, y: y, width: W, height: H))
                label(sheet, shape.displayName, at: CGPoint(x: x + 10, y: y + 10))
            }
        }
        if let img = sheet.makeImage() { writePNG(img, dir.appendingPathComponent("emitters.png")) }
        check(ok, "all \(shapes.count) emitter shapes emit particles (point, line, circle, ring, rect, frame, grid, spiral, path, selection, layer, text, brightness)")
    }

    // MARK: Determinism

    static func testDeterminism(_ dir: URL) {
        let W = 800, H = 450
        var allSame = true, seedDiffers = true
        for id in ["fire", "snow.heavy", "fireworks.finale", "galaxy", "flowfield", "confetti.burst", "plasma"] {
            guard let e = ParticlePresets.effect(id, aspect: Double(W) / Double(H)) else { continue }
            let ctx = ParticleContext(width: W, height: H)
            func render(_ e: ParticleEffect) -> [[UInt8]] { ParticleEngine.render(e, ctx: ctx).runs.map { bytes(ParticleRenderer.pixelBuffer($0.texture)) } }
            let a = render(e), b = render(e)
            if a != b { allSame = false; print("  not deterministic: \(id)") }
            var e2 = e; e2.seed = e.seed + 1
            if render(e2) == a { seedDiffers = false; print("  seed has no effect: \(id)") }
        }
        check(allSame, "same seed → identical pixels (7 presets rendered twice, byte-for-byte)")
        check(seedDiffers, "a different seed changes the result")
        // the simulation itself is independent of the render scale (preview vs final differ only in resolution)
        if let e = ParticlePresets.effect("snow.heavy", aspect: 16.0 / 9) {
            let ctx = ParticleContext(width: 1600, height: 900)
            let atlas = ParticleSpriteAtlas.atlas(for: e.systems)
            let full = ParticleSystem.simulate(e, ctx: ctx, atlas: atlas), half = ParticleSystem.simulate(e, ctx: ctx, atlas: atlas, scale: 0.5)
            var same = full.instances == half.instances && full.instances > 0
            if same, let f = full.runs.first?.instances, let h = half.runs.first?.instances {
                for i in stride(from: 0, to: f.count, by: 97) where abs(f[i].x * 0.5 - h[i].x) > 0.01 || abs(f[i].y * 0.5 - h[i].y) > 0.01 { same = false }
            }
            check(same, "preview (scaled) and final renders simulate the same particles")
        }
    }

    // MARK: Coding

    static func testCoding(_ dir: URL) {
        var roundTrip = true
        for p in ParticlePresets.all {
            let e = p.make(1.5)
            guard let back = ParticleCoding.decode(ParticleCoding.encode(e)) else { roundTrip = false; print("  decode failed: \(p.id)"); continue }
            if back != e { roundTrip = false; print("  round trip differs: \(p.id)") }
        }
        check(roundTrip, "every preset survives JSON encode → decode unchanged")
        let sparse = #"{"name":"Sparse","futureKey":42,"systems":[{"name":"A","rate":55,"sprite":"hologram","blend":"additive","unknown":{"x":1},"gradient":{"name":"g","stops":[{"location":0,"color":{"r":1,"g":0,"b":0,"a":1}},{"location":1,"color":{"r":0,"g":0,"b":1,"a":0}}]},"attractors":[{"strength":-300}],"sub":[{"count":12}]}]}"#
        let e = ParticleCoding.decode(json: sparse)
        let s = e?.systems.first
        var tolerant = false
        if let e, let s {
            let basics: Bool = e.name == "Sparse" && s.rate == 55 && s.sprite == PSprite.softDisc
            let defaults: Bool = s.lifeMax == ParticleSystemSettings().lifeMax && s.gradient.stops.count == 2
            let nested: Bool = s.attractors.first?.strength == -300 && s.attractors.first?.radius == PAttractor().radius && s.sub.first?.count == 12
            tolerant = basics && defaults && nested
        }
        check(tolerant, "tolerant decoding: missing keys take defaults, unknown keys / enum cases are ignored")
        check(ParticleCoding.decode(json: "not json") == nil && ParticleCoding.decode(json: "[1,2]") == nil, "invalid JSON is rejected without crashing")
    }

    // MARK: Engine features

    static func testFeatures(_ dir: URL) {
        let W = 800, H = 500
        let ctx = ParticleContext(width: W, height: H)
        func sim(_ s: ParticleSystemSettings, time: Double = 2, loop: Bool = false, ctx c: ParticleContext? = nil, _ f: ((inout ParticleEffect) -> Void)? = nil) -> PSimResult {
            var e = ParticleEffect(); e.systems = [s]; e.time = time; e.loop = loop
            f?(&e)
            return ParticleSystem.simulate(e, ctx: c ?? ctx, atlas: ParticleSpriteAtlas.atlas(for: e.systems))
        }
        var base = ParticleSystemSettings()
        base.shape = .line; base.pos = CGPoint(x: 0.5, y: 0.1); base.size = CGSize(width: 0.8, height: 0)
        base.rate = 400; base.lifeMin = 3; base.lifeMax = 3; base.direction = 270; base.spread = 20; base.speedMin = 200; base.speedMax = 400; base.gravity = 900
        base.opacityCurve = .flat

        // floor bounce keeps every particle above the floor
        var fl = base; fl.floorEnabled = true; fl.floorY = 0.8; fl.restitution = 0.5
        let bounced = sim(fl).runs[0].instances
        check(!bounced.isEmpty && bounced.allSatisfy { Double($0.y) <= 0.8 * Double(H) + 1.5 }, "floor collision: \(bounced.count) particles, none below the floor")

        // edges
        var ed = base; ed.bounceEdges = true; ed.spread = 360; ed.speedMax = 900; ed.gravity = 0; ed.pos = CGPoint(x: 0.5, y: 0.5)
        let inside = sim(ed, time: 3).runs[0].instances
        check(!inside.isEmpty && inside.allSatisfy { $0.x >= -2 && $0.x <= Float(W) + 2 && $0.y >= -2 && $0.y <= Float(H) + 2 }, "bounce off canvas edges keeps particles inside")

        // die on impact + sub-emitter (rain splashes)
        var rn = fl; rn.dieOnCollision = true
        var child = ParticleActions.defaultSubEmitter(); child.count = 6; child.lifeMin = 0.3; child.lifeMax = 0.4; child.direction = 90; child.spread = 120
        rn.sub = [child]
        let noSub = sim(fl.with { $0.dieOnCollision = true }).particles, withSub = sim(rn).particles
        check(withSub > noSub + 50, "sub-emitter on death: \(withSub - noSub) splash particles spawned by impacts")

        // trails
        var tr = base; tr.trail = .ribbon; tr.trailSegments = 10; tr.trailLength = 0.3
        let ribbon = sim(tr)
        check(ribbon.instances > ribbon.particles * 6, "ribbon trails: \(ribbon.instances) sprites for \(ribbon.particles) particles")
        var st = base; st.trail = .stretch; st.trailLength = 0.05
        let stretched = sim(st).runs[0].instances
        check(stretched.contains { $0.hx > $0.hy * 3 }, "velocity stretch elongates sprites along their motion")

        // confine
        var cf = base; cf.shape = .circle; cf.pos = CGPoint(x: 0.5, y: 0.5); cf.size = CGSize(width: 0.3, height: 0.48); cf.confine = true
        cf.spread = 360; cf.gravity = 0; cf.speedMin = 300; cf.speedMax = 600
        let conf = sim(cf, time: 4).runs[0].instances
        let rx = 0.15 * Double(W), ry = 0.24 * Double(H)
        check(!conf.isEmpty && conf.allSatisfy { pow((Double($0.x) - 0.5 * Double(W)) / rx, 2) + pow((Double($0.y) - 0.5 * Double(H)) / ry, 2) <= 1.02 }, "confine keeps particles inside the emitter ellipse")

        // collision mask (selection as an obstacle): nothing stays inside
        let sel = PixelBuffer(width: W, height: H, format: .gray)
        sel.context.setFillColor(gray: 1, alpha: 1); sel.context.fill(CGRect(x: 200, y: 250, width: 400, height: 120)); sel.markDirty()
        let cctx = ParticleContext(width: W, height: H); cctx.selection = PMap(buffer: sel)
        var cm = base; cm.collideMask = true; cm.restitution = 0.3
        let col = sim(cm, time: 2.5, ctx: cctx).runs[0].instances
        let stuck = col.filter { $0.x > 215 && $0.x < 585 && $0.y > 265 && $0.y < 355 }.count
        check(!col.isEmpty && stuck == 0, "mask collision: no particle ends up inside the obstacle (\(col.count) simulated)")

        // depth-aware placement with a synthetic depth map (left half near)
        var dm = PMap(w: 64, h: 40)
        for y in 0..<40 { for x in 0..<32 { dm.data[y * 64 + x] = 1 } }
        let dctx = ParticleContext(width: W, height: H); dctx.depth = dm
        var da = base; da.shape = .rectangle; da.pos = CGPoint(x: 0.5, y: 0.5); da.size = CGSize(width: 1, height: 1); da.speedMin = 0; da.speedMax = 0; da.gravity = 0
        da.emission = .burst; da.count = 4000; da.immortal = true
        let aware = sim(da, ctx: dctx) { $0.depthAware = true }.runs[0].instances
        let leftN = aware.filter { $0.x < Float(W) * 0.45 }.count, rightN = aware.filter { $0.x > Float(W) * 0.55 }.count
        check(rightN > 1000 && leftN < rightN / 8, "depth-aware placement hides particles behind near scene content (\(leftN) vs \(rightN))")

        // follow path
        var fp = base; fp.shape = .path; fp.gravity = 0; fp.speedMin = 0; fp.speedMax = 0; fp.followPath = 1; fp.followSpeed = 300
        fp.pathPoints = wavePath(40)
        let fol = sim(fp).runs[0].instances
        let sampler = PPathSampler(fp.pathPoints.map { CGPoint(x: $0.x * CGFloat(W), y: $0.y * CGFloat(H)) }, closed: false)!
        var far = 0
        for p in fol {
            var best = Double.infinity
            for k in 0...200 { let a = sampler.at(Double(k) / 200); best = min(best, hypot(a.x - Double(p.x), a.y - Double(p.y))) }
            if best > 25 { far += 1 }
        }
        check(!fol.isEmpty && far < fol.count / 20, "follow-path keeps particles on the path (\(far) of \(fol.count) strayed)")

        // sweep coverage matches the emission front (dispersion)
        var sw = base; sw.shape = .rectangle; sw.pos = CGPoint(x: 0.5, y: 0.5); sw.size = CGSize(width: 0.6, height: 0.6)
        sw.emission = .burst; sw.count = 5000; sw.sweep = 4; sw.sweepAngle = 0; sw.sweepNoise = 0; sw.speedMin = 0; sw.speedMax = 0; sw.gravity = 0; sw.lifeMin = 10; sw.lifeMax = 10; sw.prewarm = false
        let born = sim(sw, time: 2).runs[0].instances
        check(!born.isEmpty && born.allSatisfy { $0.x > Float(W) * 0.49 }, "emission sweep releases particles from the blown-towards side first")
        _ = dir
    }

    // MARK: Clipping / behind subject

    static func testClipAndSubject(_ dir: URL) {
        let d = testDocument(640, 400)
        let sel = PixelBuffer(width: 640, height: 400, format: .gray)
        sel.context.setFillColor(gray: 1, alpha: 1); sel.context.fill(CGRect(x: 320, y: 0, width: 320, height: 400)); sel.markDirty()
        d.setSelection(sel)
        var e = effect("bokeh.circle", d); e.clipToSelection = true
        let ed = ParticleEditor(doc: d, effect: e, interactive: false)
        let before = d.history.count
        ed.apply()
        let l = d.activeLayer
        if let r = l?.raster {
            let outside = alphaSum(r.buffer, origin: r.origin, in: IRect(x: 0, y: 0, width: 316, height: 400))
            let insideA = alphaSum(r.buffer, origin: r.origin, in: IRect(x: 324, y: 0, width: 316, height: 400))
            check(outside == 0 && insideA > 100_000, "selection clips the particles (alpha outside = \(outside), inside = \(insideA))")
        } else { check(false, "selection clip produced a layer") }
        check(d.history.count == before + 1 && l?.blendMode == .screen && l?.name == "Bokeh – Circular", "new layer: one history step, named after the preset, Screen blend for light effects")
        SelfTest.save(d.state, "particles/clip_selection", dir.deletingLastPathComponent())

        // behind the subject (mask injected, as the segmentation service would deliver it)
        let d2 = testDocument(640, 400, subject: true)
        var e2 = effect("snow.heavy", d2); e2.behindSubject = true
        let ed2 = ParticleEditor(doc: d2, effect: e2, interactive: false)
        let subj = subjectLayer(640, 400).toGray(useAlpha: true)
        ed2.subjectMask = subj
        ed2.apply()
        if let r = d2.activeLayer?.raster {
            // centre of the subject disc
            let inSubject = alphaSum(r.buffer, origin: r.origin, in: IRect(x: 270, y: 150, width: 100, height: 100))
            let away = alphaSum(r.buffer, origin: r.origin, in: IRect(x: 20, y: 150, width: 100, height: 100))
            check(inSubject == 0 && away > 0, "behind subject: no particles over the subject (alpha \(inSubject)), particles elsewhere (\(away))")
        } else { check(false, "behind-subject produced a layer") }
        SelfTest.save(d2.state, "particles/behind_subject", dir.deletingLastPathComponent())
    }

    // MARK: Output modes

    static func testOutputs(_ dir: URL) {
        // mixed blends → group with one layer per blend run
        let d = testDocument(640, 400)
        let ed = ParticleEditor(doc: d, effect: effect("fire", d), interactive: false)
        let h0 = d.history.count
        ed.apply()
        let g = d.activeLayer
        let modes = g?.children.map(\.blendMode) ?? []
        check(g?.isGroup == true && modes == [.normal, .screen] && d.history.count == h0 + 1, "fire → group with a Normal smoke layer and a Screen flame layer, one history step")
        d.undo()
        check(d.state.layers.count == 1 && d.displayOverride == nil, "undo removes the effect")

        // into the active layer
        let d2 = testDocument(640, 400)
        let beforePixels = flat(d2.state)
        var e2 = effect("confetti.burst", d2); e2.output = .activeLayer
        let ed2 = ParticleEditor(doc: d2, effect: e2, interactive: false)
        let h2 = d2.history.count
        ed2.apply()
        check(d2.state.layers.count == 1 && d2.history.count == h2 + 1 && diff(flat(d2.state), beforePixels).mean > 0.2, "into active layer: pixels merged, no new layer, one history step")
        d2.undo()
        check(diff(flat(d2.state), beforePixels).max == 0, "undo restores the active layer exactly")

        // dispersion: particles use the layer's colours and the dissolved part is masked
        let d3 = testDocument(800, 500, subject: true)
        let ed3 = ParticleEditor(doc: d3, effect: effect("dispersion", d3), interactive: false)
        let h3 = d3.history.count
        ed3.apply()
        let subjectLayer = d3.state.layers[1]
        let hidden = subjectLayer.mask.map { m -> Int in
            var n = 0
            for y in stride(from: 0, to: m.buffer.height, by: 4) { for x in stride(from: 0, to: m.buffer.width, by: 4) where m.buffer.alpha(x, y) < 128 { n += 1 } }
            return n
        } ?? 0
        check(d3.state.layers.count == 3 && subjectLayer.mask != nil && hidden > 500 && d3.history.count == h3 + 1,
              "dispersion: fragments layer added and the source layer masked where it dissolved — one history step")
        if let r = d3.state.layers[2].raster {
            // fragments carry the subject's warm colours, not white
            var warm = 0, total = 0
            for y in stride(from: 0, to: r.buffer.height, by: 3) { for x in stride(from: 0, to: r.buffer.width, by: 3) {
                let p = r.buffer.pixel(x, y)
                if p.3 > 200 { total += 1; if Int(p.0) > Int(p.2) + 30 { warm += 1 } }
            } }
            check(total > 200 && warm > total / 3, "dispersion fragments are coloured from the layer's pixels (\(warm) of \(total) sampled are warm)")
        }
        SelfTest.save(d3.state, "particles/dispersion_applied", dir.deletingLastPathComponent())
        d3.undo()
        check(d3.state.layers.count == 2 && d3.state.layers[1].mask == nil, "undo removes both the fragments and the mask")

        // Repeat Last applies without UI
        let d4 = testDocument(480, 300)
        ParticleEditor.lastEffect = effect("stars", d4)
        AppModel.shared.add(d4)
        ParticleActions.repeatLast()
        check(d4.state.layers.count == 2 && d4.history.count == 2, "Repeat Last adds the effect again as a single step")
        AppModel.shared.close(d4)
    }

    // MARK: Smart object round trip

    static func testSmartObject(_ dir: URL) {
        let d = testDocument(640, 400, subject: true)
        AppModel.shared.add(d)
        d.selectLayer(d.state.layers[1].id)
        var e = effect("dispersion", d); e.output = .smartObject
        let ed = ParticleEditor(doc: d, effect: e, interactive: false)
        ed.apply()
        guard let lid = d.activeLayerID, let layer = d.state.layer(lid), layer.isSmartObject, let stored = ParticleStorage.effect(in: layer) else {
            check(false, "smart object output stores its settings"); AppModel.shared.close(d); return
        }
        let sameShape: Bool = stored.name == e.name && stored.systems.count == e.systems.count
        let bakedIn: Bool = stored.systems[0].maskPNG != nil && stored.imagePNG != nil && stored.sourceLayerID == d.state.layers[1].id
        check(sameShape && bakedIn, "smart object carries the settings (with baked emitter map and layer colours)")
        let before = flat(d.state)

        // save → load
        let url = dir.appendingPathComponent("particles_smart.imagecrat")
        var loaded: Document?
        do { try DocumentIO.saveNative(d, to: url); loaded = try DocumentIO.load(url: url) } catch { print("  save/load error: \(error)") }
        if let l2 = loaded, let sl = l2.state.layer(lid), let back = ParticleStorage.effect(in: sl) {
            check(back == stored, "settings survive save / load unchanged")
            check(diff(flat(l2.state), before).max <= 1, "the reloaded document renders identically")
            // re-edit the reloaded smart object: change the moment, update in place
            AppModel.shared.add(l2)
            let re = ParticleEditor(doc: l2, effect: back, reeditLayer: lid, interactive: false)
            re.schedulePreview()
            check(l2.hiddenLayers.contains(lid) && l2.displayOverride != nil, "re-edit previews live with the old render hidden")
            re.state.effect.time = 2.4
            re.state.effect.seed += 5
            let h = l2.history.count, layers = l2.state.layers.count
            let rev = sl.smart?.sourceRevision
            re.apply()
            let after = l2.state.layer(lid)
            check(l2.history.count == h + 1 && l2.state.layers.count == layers && after?.smart?.sourceRevision != rev
                  && ParticleStorage.effect(in: after)?.time == 2.4 && l2.hiddenLayers.isEmpty && l2.displayOverride == nil,
                  "re-edit updates the same layer in one step and stores the new settings")
            check(diff(flat(l2.state), before).mean > 0.05, "the re-rendered smart object shows the changed effect")
            SelfTest.save(l2.state, "particles/smart_reedited", dir.deletingLastPathComponent())

            // double-click / Edit Contents opens a child document → swapped for the particle editor
            AppActions.editSmartContents(lid)
            let opened = AppModel.shared.activeDocument?.smartParent === l2
            let swapped = ParticleReedit.check(openEditor: false)
            check(opened && swapped && AppModel.shared.activeDocument === l2 && !AppModel.shared.documents.contains { $0.smartParent === l2 },
                  "Edit Contents on a particle smart object is redirected to the particle editor")
            // an ordinary smart object is left alone
            AppActions.placeBuffer(subjectLayer(200, 120), name: "Plain")
            if let pid = l2.activeLayerID {
                AppActions.editSmartContents(pid)
                check(!ParticleReedit.check(openEditor: false) && AppModel.shared.activeDocument?.smartParent === l2, "ordinary smart objects still open their contents")
                if let child = AppModel.shared.activeDocument, child !== l2 { AppModel.shared.close(child) }
            }
            AppModel.shared.close(l2)
        } else {
            check(false, "settings survive save / load")
        }
        AppModel.shared.close(d)
    }

    // MARK: Animation

    static func testAnimation(_ dir: URL) {
        // loop seamlessness: frame N (= one loop later) must equal frame 0
        var maxLoopDiff = 0, minFrameDiff = Double.infinity
        var nonLoopDiffers = true
        for id in ["snow.heavy", "fire", "fireworks.peony", "flowfield", "rain.storm", "confetti.fall", "portal"] {
            guard var e = ParticlePresets.effect(id, aspect: 1.6) else { continue }
            e.loop = true; e.frames = 12; e.fps = 12
            let le = ParticleEditor.animationEffect(e)
            let ctx = ParticleContext(width: 640, height: 400)
            func frame(_ e: ParticleEffect, _ t: Double) -> [UInt8] {
                ParticleEngine.render(e, ctx: ctx, time: t).runs.reduce(into: [UInt8]()) { $0 += bytes(ParticleRenderer.pixelBuffer($1.texture)) }
            }
            let f0 = frame(le, 0), fN = frame(le, le.duration), f1 = frame(le, 1.0 / 12)
            let dl = diff(f0, fN), d1 = diff(f0, f1)
            maxLoopDiff = max(maxLoopDiff, dl.max)
            minFrameDiff = min(minFrameDiff, d1.mean)
            print(String(format: "  loop %@: first vs last+1 max diff %d, first vs second mean diff %.3f", id, dl.max, d1.mean))
            var ne = e; ne.loop = false
            if id == "fire", diff(frame(ne, 0), frame(ne, ne.frames / ne.fps)).max == 0 { nonLoopDiffers = false }
        }
        check(maxLoopDiff == 0, "seamless loop: frame N is pixel-identical to frame 0 for 7 presets (max diff \(maxLoopDiff))")
        check(minFrameDiff > 0.001, "consecutive frames actually move (min mean diff \(String(format: "%.3f", minFrameDiff)))")
        check(nonLoopDiffers, "without Loop the last+1 frame differs from the first")

        // frame animation output
        let d = testDocument(480, 300)
        AppModel.shared.add(d)
        var e = effect("confetti.fall", d); e.loop = true; e.frames = 8; e.fps = 8
        let ed = ParticleEditor(doc: d, effect: e, interactive: false)
        let h = d.history.count
        let t0 = CFAbsoluteTimeGetCurrent()
        ed.animate(.frames)
        let animMS = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let frames = d.state.frames
        let ids = d.state.layers.dropFirst().map(\.id)
        var oneVisible = frames.count == 8 && ids.count == 8
        for (k, f) in frames.enumerated() { for (j, id) in ids.enumerated() where f.visibility[id] != (j == k) { oneVisible = false } }
        check(oneVisible && d.history.count == h + 1 && frames.allSatisfy { abs($0.delay - 0.125) < 1e-9 },
              String(format: "Animate → frame animation: 8 frames, one particle layer visible per frame, one history step (%.0f ms)", animMS))
        let rendered = Animation.renderFrames(d.state, background: .black)
        let distinct = Set(rendered.map { bytes(PixelBuffer(cgImage: $0.image)).hashValue }).count
        check(rendered.count == 8 && distinct == 8, "the 8 frames render as 8 different images")
        let gif = dir.appendingPathComponent("particles_confetti.gif")
        var gifOK = false
        do { try AnimationExport.writeGIF(d.state, to: gif, background: .black); gifOK = (try? Data(contentsOf: gif).count) ?? 0 > 10_000 } catch { print("  gif error: \(error)") }
        check(gifOK, "the frames export with the existing GIF exporter")
        d.undo()
        check(d.state.layers.count == 1 && d.state.frames.isEmpty, "undo removes the whole animation")
        AppModel.shared.close(d)

        // video timeline output
        let d2 = testDocument(480, 300)
        AppModel.shared.add(d2)
        var e2 = effect("hearts", d2); e2.frames = 6; e2.fps = 12; e2.animStart = 2
        let ed2 = ParticleEditor(doc: d2, effect: e2, interactive: false)
        ed2.animate(.timeline)
        if let tl = d2.state.videoTimeline {
            let ids2 = d2.state.layers.dropFirst().map(\.id)
            var gated = ids2.count == 6 && abs(tl.duration - 0.5) < 1e-6
            for (k, id) in ids2.enumerated() {
                let st = VideoTimelineEngine.evaluated(d2.state, at: (Double(k) + 0.5) / 12, decodeVideo: false)
                for (j, other) in ids2.enumerated() where st.layer(other)?.isVisible != (j == k) { gated = false }
                _ = id
            }
            check(gated, "Animate → video timeline: 6 clips of one frame each, exactly one visible at any time")
        } else { check(false, "Animate → video timeline creates a timeline") }
        AppModel.shared.close(d2)

        // PNG sequence
        let d3 = testDocument(320, 200)
        var e3 = effect("sparks.welding", d3); e3.frames = 5; e3.fps = 10
        let ed3 = ParticleEditor(doc: d3, effect: e3, interactive: false)
        let seqDir = dir.appendingPathComponent("sequence")
        let urls = ed3.exportSequence(to: seqDir, overDocument: false)
        let firstHasAlpha = urls.first.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            .map { img -> Bool in let b = PixelBuffer(cgImage: img); return b.alpha(2, 2) == 0 && b.opaqueBounds() != nil } ?? false
        check(urls.count == 5 && firstHasAlpha && d3.history.count == 1, "Export PNG sequence: 5 transparent frames written, document untouched")
        ed3.cancel()
    }

    // MARK: Cancel / safety

    static func testCancel(_ dir: URL) {
        struct Snapshot: Equatable {
            var pixels: [UInt8]; var history: Int; var index: Int; var layerIDs: [UUID]; var buffers: [ObjectIdentifier]
            var noOverride: Bool; var overrides: Int; var hidden: Int; var masks: Int
        }
        func snap(_ d: Document) -> Snapshot {
            Snapshot(pixels: bytes(RenderEngine.renderBuffer(CanvasRenderer.applyViewMode(Compositor.shared.composite(d), doc: d), docRect: d.state.canvasRect,
                                                             space: CanvasSpace(width: d.state.width, height: d.state.height))),
                     history: d.history.count, index: d.historyIndex, layerIDs: d.state.allLayers.map(\.id),
                     buffers: d.state.allLayers.compactMap { $0.raster.map { ObjectIdentifier($0.buffer) } },
                     noOverride: d.displayOverride == nil, overrides: d.contentOverrides.count, hidden: d.hiddenLayers.count,
                     masks: d.state.allLayers.filter { $0.mask != nil }.count)
        }
        let app = AppModel.shared
        let d = testDocument(640, 400, subject: true)
        app.add(d)
        d.selectLayer(d.state.layers[1].id)
        let before = snap(d)

        // 1. plain cancel (with the dispersion preset, which also previews a mask on the source layer)
        var ed = ParticleEditor(doc: d, effect: effect("dispersion", d), interactive: false)
        ed.schedulePreview()
        let previewing = d.displayOverride != nil && d.contentOverrides.count == 1 && snap(d).pixels != before.pixels
        ed.cancel()
        check(previewing, "the editor previews on the canvas through a display override (document state untouched)")
        check(snap(d) == before, "Cancel leaves the document identical: no override, no mask, same history, same pixels")

        // interactive sessions: every way out must clean up
        func session(_ id: String) -> ParticleEditor {
            let e = ParticleEditor(doc: d, effect: effect(id, d))
            e.begin()
            pump(0.35)
            return e
        }
        // 2. another dialog replaces the editor
        ed = session("fire")
        let live = d.displayOverride != nil && app.dialog == .custom(ParticleEditor.dialogID)
        app.dialog = .about
        ed.tick()
        check(live && ed.isClosed && snap(d) == before, "replacing the dialog closes the session and removes the preview")
        app.dialog = nil

        // 3. document switch
        let other = testDocument(200, 120)
        ed = session("dispersion")
        app.add(other)          // becomes the active document
        ed.tick()
        check(ed.isClosed && snap(d) == before && other.displayOverride == nil, "switching documents closes the session and removes the preview")
        app.activeDocumentID = d.id
        app.dialog = nil

        // 4. a menu command that can change the document (Filter ▸ …)
        // (the menu has to hang off the main menu when one exists — earlier suites may have built it — or it counts as a pop-up)
        func menuCommand(_ title: String) {
            let m = NSMenu(title: title)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let main = NSApp.mainMenu { item.submenu = m; main.addItem(item) }
            NotificationCenter.default.post(name: NSMenu.willSendActionNotification, object: m)
            if let main = NSApp.mainMenu, main.items.contains(item) { main.removeItem(item) }
        }
        ed = session("snow.light")
        menuCommand("Filter")
        check(ed.isClosed && app.dialog == nil && snap(d) == before, "a document menu command closes the session first (no preview left behind)")
        // …but View / Particles menus don't
        ed = session("snow.light")
        menuCommand("View")
        menuCommand("Particles")
        check(!ed.isClosed, "View and Particles menu commands keep the editor open")

        // 5. choosing another preset while open swaps the effect in the same session
        ParticleEditor.open(presetID: "bokeh.hex")
        check(ParticleEditor.current === ed && ed.state.effect.name == "Bokeh – Hexagonal", "picking another preset re-uses the open session")

        // 6. a foreign history step (another command committed) → session closes, the step stays
        d.updateLayer(d.state.layers[1].id) { $0.opacity = 0.5 }
        d.commit("Foreign Edit")
        ed.tick()
        check(ed.isClosed && d.displayOverride == nil && d.contentOverrides.isEmpty && d.history.count == before.history + 1, "a history change underneath the editor closes it cleanly")
        d.undo()
        check(snap(d) == Snapshot(pixels: before.pixels, history: before.history + 1, index: before.index, layerIDs: before.layerIDs, buffers: before.buffers,
                                  noOverride: true, overrides: 0, hidden: 0, masks: 0), "after undoing that step the document shows its original pixels")

        // 7. tool switch while open: the session doesn't depend on the tool and keeps the document clean
        ed = session("glitter")
        let oldTool = app.tool
        app.tool = oldTool == .brush ? .eraser : .brush
        ed.tick()
        let stillClean = d.contentOverrides.isEmpty && d.history.count == before.history + 1
        ed.cancel()
        app.tool = oldTool
        check(stillClean && d.displayOverride == nil && app.dialog == nil, "switching tools with the editor open leaves nothing behind after closing")

        // 8. apply = exactly one history step, preview gone
        ed = session("hearts")
        let h = d.historyIndex
        ed.apply()
        check(ed.isClosed && d.historyIndex == h + 1 && d.displayOverride == nil && d.contentOverrides.isEmpty && app.dialog == nil && ParticleEditor.current == nil,
              "OK applies one history step and removes the preview")
        app.close(d); app.close(other)
        _ = dir
    }

    // MARK: On-canvas handles

    static func testHandles(_ dir: URL) {
        let app = AppModel.shared
        let d = testDocument(800, 500)
        app.add(d)
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        let oldCanvas = AppActions.canvas
        AppActions.canvas = canvas
        canvas.document = d
        d.zoom = 1; d.viewOffset = CGPoint(x: 100, y: 100)
        defer { AppActions.canvas = oldCanvas; app.close(d) }

        var e = effect("confetti.burst", d)
        e.systems[0].shape = .rectangle; e.systems[0].pos = CGPoint(x: 0.5, y: 0.5); e.systems[0].size = CGSize(width: 0.4, height: 0.3)
        e.systems[0].floorEnabled = true; e.systems[0].floorY = 0.9
        e.systems[0].attractors = [PAttractor(pos: CGPoint(x: 0.2, y: 0.3), strength: 500, radius: 200)]
        let ed = ParticleEditor(doc: d, effect: e)
        ed.begin()
        pump(0.3)
        guard let ov = ed.overlay, let h0 = ov.handlePoints() else { check(false, "the editor installs its on-canvas handles"); ed.cancel(); return }
        check(canvas.subviews.contains { $0 is ParticleHandlesView }, "the editor installs its on-canvas handles above the canvas")

        // position
        ov.simulateDrag(from: h0.pos, to: CGPoint(x: h0.pos.x + 120, y: h0.pos.y - 60))
        let p1 = ed.state.effect.systems[0].pos
        check(abs(p1.x - (0.5 + 120.0 / 800)) < 0.004 && abs(p1.y - (0.5 - 60.0 / 500)) < 0.004, "dragging the ● handle moves the emitter (\(String(format: "%.3f, %.3f", p1.x, p1.y)))")
        // size + rotation
        let h1 = ov.handlePoints()!
        ov.simulateDrag(from: h1.width, to: CGPoint(x: h1.pos.x + 200, y: h1.pos.y))
        let w1 = ed.state.effect.systems[0].size.width
        check(abs(w1 - 0.5) < 0.01, "dragging the width ■ handle resizes the emitter (width \(String(format: "%.3f", w1)))")
        let h2 = ov.handlePoints()!
        ov.simulateDrag(from: h2.height, to: CGPoint(x: h2.pos.x, y: h2.pos.y + 50))
        check(abs(ed.state.effect.systems[0].size.height - 0.2) < 0.01, "dragging the height ■ handle resizes the emitter")
        // direction arrow
        let h3 = ov.handlePoints()!
        let len = h3.arrow.distance(to: h3.pos)
        ov.simulateDrag(from: h3.arrow, to: CGPoint(x: h3.pos.x + len, y: h3.pos.y))
        check(abs(ed.state.effect.systems[0].direction) < 1.5, "dragging the arrow sets the emission direction (\(String(format: "%.1f", ed.state.effect.systems[0].direction))°)")
        // attractor
        let av = canvas.docToView(CGPoint(x: 0.2 * 800, y: 0.3 * 500))
        ov.simulateDrag(from: av, to: CGPoint(x: av.x + 80, y: av.y + 40))
        let ap = ed.state.effect.systems[0].attractors[0].pos
        check(abs(ap.x - (0.2 + 0.1)) < 0.005 && abs(ap.y - (0.3 + 0.08)) < 0.005, "attractor handles can be dragged")
        // floor
        let fv = canvas.docToView(CGPoint(x: 600, y: 0.9 * 500))
        ov.simulateDrag(from: fv, to: CGPoint(x: fv.x, y: fv.y - 100))
        check(abs(ed.state.effect.systems[0].floorY - 0.7) < 0.01, "the floor line can be dragged")
        // particle brush: draw the emission path
        ed.state.drawPath = true
        ov.simulateDrag(from: CGPoint(x: 200, y: 300), to: CGPoint(x: 700, y: 450), steps: 40)
        let s0 = ed.state.effect.systems[0]
        check(s0.shape == .path && s0.pathPoints.count > 10 && abs(s0.pathPoints.first!.x - 0.125) < 0.01 && abs(s0.pathPoints.last!.x - 0.75) < 0.01,
              "Particle Brush: dragging draws the emission path (\(s0.pathPoints.count) points)")
        ed.state.drawPath = false

        // picture of the handles over the preview
        ed.state.effect.systems[0].shape = .rectangle
        ed.schedulePreview()
        pump(0.4)
        let sp = CanvasSpace(width: 800, height: 500)
        let comp = CanvasRenderer.applyViewMode(Compositor.shared.composite(d), doc: d)
        if let cg = RenderEngine.cgImage(comp, rect: sp.ciCanvas),
           let ctx = CGContext(data: nil, width: 1000, height: 700, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(NSColor(white: 0.16, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 700))
            ctx.draw(cg, in: CGRect(x: 100, y: 700 - 100 - 500, width: 800, height: 500))
            // the handles view is flipped (y down)
            ctx.translateBy(x: 0, y: 700); ctx.scaleBy(x: 1, y: -1)
            let g = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
            ov.draw(ctx)
            NSGraphicsContext.restoreGraphicsState()
            if let img = ctx.makeImage() { writePNG(img, dir.appendingPathComponent("handles.png")) }
        }
        ed.cancel()
        check(!canvas.subviews.contains { $0 is ParticleHandlesView } && d.displayOverride == nil, "closing the editor removes the handles and the preview")
    }

    // MARK: UI snapshots (offscreen)

    static func testUISnapshots(_ dir: URL) {
        let app = AppModel.shared
        let d = testDocument(800, 500, subject: true)
        app.add(d)
        defer { app.close(d) }
        func snap<V: View>(_ v: V, _ name: String, _ size: CGSize) {
            let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height, alignment: .top).background(Theme.panelBG).environment(\.colorScheme, .dark))
            host.frame = CGRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            pump(0.4)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            print("  wrote \(name)")
        }
        var e = effect("fireworks.ring", d)
        e.systems[0].attractors = [PAttractor()]
        let ed = ParticleEditor(doc: d, effect: e, presetID: "fireworks.ring", interactive: false)
        ParticleEditor.current = ed
        ed.schedulePreview()
        snap(DraggableCard { ParticleEditorPanel(editor: ed, st: ed.state) }, "ui_editor_default", CGSize(width: 420, height: 760))
        snap(ParticleEditorPanel(editor: ed, st: ed.state, open: ParticleEditorPanel.allSections, contentHeight: 2900), "ui_editor_all_sections_1", CGSize(width: 420, height: 3100))
        ed.state.effect = effect("dispersion", d)
        ed.state.effect.systems[0].colorBase = .palette
        ed.state.effect.systems[0].shape = .path
        ed.state.effect.systems[0].sprite = .glyph
        ed.state.effect.systems[0].trail = .ribbon
        ed.state.effect.systems[0].floorEnabled = true
        snap(ParticleEditorPanel(editor: ed, st: ed.state, open: ParticleEditorPanel.allSections, contentHeight: 2900), "ui_editor_all_sections_2", CGSize(width: 420, height: 3100))
        // thumbnails are rendered in the background: wait for them
        _ = ParticleThumbnails.shared.image("fire")
        let t0 = Date()
        while ParticleThumbnails.shared.version < ParticlePresets.all.count && Date().timeIntervalSince(t0) < 300 { pump(0.5) }
        check(ParticleThumbnails.shared.version == ParticlePresets.all.count, "a thumbnail is rendered for every preset (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s in the background)")
        snap(ParticlePresetPicker(current: "fire") {}, "ui_preset_picker", CGSize(width: 456, height: 460))
        // contact sheet of every thumbnail
        let cols = 9, cw = 100, chh = 64
        let rows = (ParticlePresets.all.count + cols - 1) / cols
        if let ctx = CGContext(data: nil, width: cols * cw * 2, height: rows * chh * 2, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            for (i, p) in ParticlePresets.all.enumerated() {
                guard let img = ParticleThumbnails.shared.image(p.id)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                ctx.draw(img, in: CGRect(x: (i % cols) * cw * 2 + 4, y: (rows - 1 - i / cols) * chh * 2 + 4, width: 192, height: 120))
            }
            if let img = ctx.makeImage() { writePNG(img, dir.appendingPathComponent("ui_thumbnails.png")) }
        }
        snap(DraggableCard { ParticlePresetManager() }, "ui_preset_manager", CGSize(width: 460, height: 340))
        ed.cancel()
    }

    // MARK: User presets

    static func testUserPresets(_ dir: URL) {
        let store = ParticleUserPresets.shared
        let tmp = dir.appendingPathComponent("user_presets")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for u in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [] where u.pathExtension == "json" {
            try? FileManager.default.removeItem(at: u)
        }
        store.directoryOverride = tmp
        defer { store.directoryOverride = nil; store.reload() }
        store.reload()
        var e = ParticlePresets.effect("fire", aspect: 1.5)!
        e.systems[0].gravity = -77; e.sourceLayerID = UUID(); e.imagePNG = "abc"
        let url = try? store.save(e, name: "My Fire: v2")
        let back = url.flatMap { store.load($0) }
        check(store.presets.count == 1 && back?.systems[0].gravity == -77 && back?.name == "My Fire: v2" && back?.sourceLayerID == nil && back?.imagePNG == nil,
              "user preset saved as JSON and loaded back (document-specific data stripped)")
        let exported = dir.appendingPathComponent("exported_preset.json")
        if let entry = store.presets.first {
            try? store.export(entry, to: exported)
            let n = store.importFiles([exported, dir.appendingPathComponent("sprites.png")])
            check(n == 1 && store.presets.count == 2, "export and import round trip (invalid files are skipped)")
            store.rename(entry, to: "Renamed")
            check(store.presets.contains { $0.name == "Renamed" } && store.presets.count == 2, "presets can be renamed")
        } else { check(false, "preset listed after saving") }
        print("  default presets folder: \(ParticleUserPresets().directoryOverride == nil ? "~/Library/Application Support/ImageCrat/ParticlePresets" : "?")")
    }

    // MARK: Performance

    static func testPerformance(_ dir: URL) {
        let W = 1920, H = 1080
        let ctx = ParticleContext(width: W, height: H)
        func system(_ n: Double, turbulence: Bool) -> ParticleEffect {
            var s = ParticleSystemSettings()
            s.shape = .rectangle; s.pos = CGPoint(x: 0.5, y: 0.5); s.size = CGSize(width: 1, height: 1)
            s.emission = .rate; s.rate = n / 2.5; s.lifeMin = 2; s.lifeMax = 3; s.prewarm = true
            s.spread = 360; s.speedMin = 20; s.speedMax = 120; s.gravity = 60
            if turbulence { s.turbulence = 120; s.turbulenceScale = 220 }
            s.sprite = .softDisc; s.sizeMin = 3; s.sizeMax = 9; s.opacity = 0.6; s.opacityCurve = .fadeInOut
            s.gradient = .hex("8FE9FF", "FF9AE0")
            var e = ParticleEffect(); e.systems = [s]; e.time = 5
            return e
        }
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        var lines: [String] = ["build: \(build), canvas \(W)×\(H), \(ProcessInfo.processInfo.activeProcessorCount) cores"]
        _ = ParticleEngine.render(system(1000, turbulence: true), ctx: ctx)      // warm up pipelines / atlas
        var previewOK = true
        for turb in [false, true] {
            for n in [100_000.0, 500_000.0, 1_000_000.0] {
                let e = system(n, turbulence: turb)
                var best = (sim: Double.infinity, render: Double.infinity, prev: Double.infinity, count: 0)
                for _ in 0..<3 {
                    let o = ParticleEngine.render(e, ctx: ctx)
                    let p = ParticleEngine.render(e, ctx: ctx, scale: 0.9375, preview: true)
                    best.sim = min(best.sim, o.simSeconds); best.render = min(best.render, o.renderSeconds)
                    best.prev = min(best.prev, p.simSeconds + p.renderSeconds); best.count = o.particles
                }
                let line = String(format: "%@ %7d particles: sim %6.1f ms (%.1f M particles/s), render 4×MSAA %5.1f ms, interactive preview total %6.1f ms (%.0f fps)",
                                  turb ? "curl turbulence (~75 steps each)" : "closed-form motion               ", best.count, best.sim * 1000,
                                  Double(best.count) / best.sim / 1e6, best.render * 1000, best.prev * 1000, 1 / best.prev)
                lines.append(line)
                print("  " + line)
                // generous limits: the numbers swing a lot when other builds are using the machine
                let limit = (build == "debug" ? 3.0 : (turb ? 0.3 : 0.1))
                if n == 100_000, best.prev > limit { previewOK = false }
            }
        }
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("performance_\(build).txt"), atomically: true, encoding: .utf8)
        check(previewOK, "100k particles preview interactively (\(build) build)")
    }
}

private extension ParticleSystemSettings {
    func with(_ f: (inout ParticleSystemSettings) -> Void) -> ParticleSystemSettings { var s = self; f(&s); return s }
}

