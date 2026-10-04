import Foundation
import CoreGraphics
import ImageCratCore

/// One sprite instance handed to the GPU (layout matches the Metal shader: 48 bytes).
struct PInstance {
    var x: Float = 0, y: Float = 0          // centre, pixels (y down)
    var hx: Float = 0, hy: Float = 0        // half extents along the local axes
    var cs: Float = 1, sn: Float = 0        // local x axis
    var layer: Float = 0, lod: Float = 0    // sprite layer, mip bias
    var r: Float = 1, g: Float = 1, b: Float = 1, a: Float = 1   // premultiplied colour
}

/// Instances of consecutive systems that share a blend mode (rendered into one layer).
struct PRun {
    var blend: PBlend
    var name: String
    var instances: [PInstance] = []
    var particles = 0
}

struct PSimResult {
    var runs: [PRun] = []
    var particles = 0
    var instances: Int { runs.reduce(0) { $0 + $1.instances.count } }
    var seconds: Double = 0
}

/// Deterministic particle engine: every particle is simulated independently from its birth to the requested time,
/// so any moment can be evaluated directly (scrubbing, animation frames, seamless loops) and the work is spread
/// over all cores with results that don't depend on thread scheduling.
enum ParticleSystem {
    static let maxParticlesPerSystem = 1_500_000
    static let dt = 1.0 / 30.0

    // MARK: Prepared per-system data

    final class RT {
        let s: ParticleSystemSettings
        let W: Double, H: Double, U: Double
        let seed: UInt64
        var cx: Double, cy: Double              // emitter centre (px)
        var ex: Double, ey: Double              // emitter half extents (px)
        let erc: Double, ers: Double            // emitter rotation
        var area: PAreaSampler?
        /// Map whose gradient gives the emitter normal (the un-edged source for outline shapes).
        var normalMap: PMap?
        let isChild: Bool
        var path: PPathSampler?
        var collision: PMap?
        var colorMap: PColorMap?
        var depthMap: PMap?
        var sweepMax = 0.0
        let sizeLUT: [Float], opacityLUT: [Float]
        let gradLUT: [Float], palLUT: [Float]
        let needsIntegration: Bool
        let stepDT: Double
        let life0: Double, life1: Double
        let windowExtra: Double                 // how long after death sub-particles may still live
        var sub: RT?
        var spriteBase = ParticleSprites.glowLayer, spriteCount = 1
        let noiseOX: Double, noiseOY: Double
        let loopD: Double
        let gridCols: Int, gridRows: Int
        let vcx: Double, vcy: Double
        let attractors: [(x: Double, y: Double, s: Double, r: Double)]
        let floorPx: Double
        let depthAware: Bool

        init(_ s: ParticleSystemSettings, effect e: ParticleEffect, ctx: ParticleContext, index: Int, atlas: ParticleSpriteAtlas?, level: Int = 0) {
            // the hot loops copy `rt.s`: keep only the scalar settings in it (no strings / arrays to retain)
            var lite = s
            lite.name = ""; lite.text = ""; lite.textFont = ""; lite.spriteText = ""; lite.spriteFont = ""; lite.spriteShape = ""
            lite.maskPNG = nil; lite.spriteImagePNG = nil
            lite.pathPoints = []; lite.attractors = []; lite.sub = []
            lite.sizeCurve = CurvePoints(points: []); lite.opacityCurve = CurvePoints(points: [])
            lite.gradient = ColorGradient(name: "", stops: []); lite.palette = ColorGradient(name: "", stops: [])
            self.s = lite
            isChild = level > 0
            W = Double(ctx.width); H = Double(ctx.height); U = ctx.unit
            seed = PRNG.mix(UInt64(bitPattern: Int64(e.seed)) &* 0x9E37 &+ UInt64(index + 1) &* 0x100000001B3 &+ UInt64(level) &* 7919)
            cx = Double(s.pos.x) * W; cy = Double(s.pos.y) * H
            ex = Double(s.size.width) * W / 2; ey = Double(s.size.height) * H / 2
            erc = cos(-s.emitterRotation * .pi / 180); ers = sin(-s.emitterRotation * .pi / 180)
            loopD = e.loop ? max(0.1, e.duration) : 0
            sizeLUT = s.sizeCurve.lut(256).map { Float(max(0, $0)) }
            opacityLUT = s.opacityCurve.lut(256).map { Float(min(1, max(0, $0))) }
            gradLUT = RT.lut(s.gradient)
            palLUT = RT.lut(s.palette)
            life0 = max(0.01, min(s.lifeMin, s.lifeMax)); life1 = max(0.01, max(s.lifeMin, s.lifeMax))
            var r = PRNG(seed, 99)
            noiseOX = r.range(-500, 500); noiseOY = r.range(-500, 500)
            vcx = Double(s.vortexCenter.x) * W; vcy = Double(s.vortexCenter.y) * H
            let cw = Double(ctx.width), ch = Double(ctx.height), cu = ctx.unit
            attractors = s.attractors.map { (Double($0.pos.x) * cw, Double($0.pos.y) * ch, $0.strength * cu, max(1, $0.radius * cu)) }
            floorPx = s.floorY * H
            depthAware = e.depthAware && ctx.depth != nil
            if depthAware { depthMap = ctx.depth }

            // emitter sources
            if level == 0 {
                var map: PMap?
                switch s.shape {
                case .selectionArea, .selectionOutline: map = ctx.selection
                case .layerAlpha, .layerEdges: map = ctx.layerAlpha
                case .brightness: map = ctx.brightness
                case .text:
                    map = ParticleMaps.text(s.text, font: s.textFont, pos: s.pos, size: s.size, rotation: s.emitterRotation, canvas: CGSize(width: W, height: H))
                default: break
                }
                if s.shape.usesMap, s.shape != .text, map == nil || map!.isEmpty, let png = s.maskPNG, let baked = PMap(pngBase64: png) { map = baked }
                if let m = map {
                    normalMap = m
                    let edges = s.shape.isOutline || (s.outlineOnly && (s.shape == .text || s.shape == .brightness))
                    area = PAreaSampler(edges ? m.edges : m)
                    // the emitter box becomes the bounds of the map's content (centre for radial speed, sweep extent)
                    if s.shape != .text, s.shape != .brightness {
                        var x0 = m.w, y0 = m.h, x1 = -1, y1 = -1
                        for y in 0..<m.h { for x in 0..<m.w where m.data[y * m.w + x] > 0.05 {
                            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                        } }
                        if x1 >= x0 {
                            let sx = W / Double(m.w), sy = H / Double(m.h)
                            cx = Double(x0 + x1 + 1) / 2 * sx; cy = Double(y0 + y1 + 1) / 2 * sy
                            ex = Double(x1 - x0 + 1) / 2 * sx; ey = Double(y1 - y0 + 1) / 2 * sy
                        }
                    }
                }
                if s.shape == .path || s.followPath > 0 {
                    path = PPathSampler(s.pathPoints.map { CGPoint(x: $0.x * CGFloat(cw), y: $0.y * CGFloat(ch)) }, closed: s.pathClosed)
                }
            }
            if s.collideMask { collision = ctx.selection ?? ctx.layerAlpha }
            if s.colorBase == .image { colorMap = ctx.layerColor }
            if s.sweep > 0 { sweepMax = s.sweep * (1 + s.sweepNoise) }

            let collides = s.bounceEdges || s.floorEnabled || (s.collideMask && collision != nil) || s.confine
            needsIntegration = collides || s.turbulence != 0 || s.noiseForce != 0 || s.vortex != 0 || s.vortexPull != 0 || !s.attractors.isEmpty
                || (s.followPath > 0 && path != nil) || (s.gust > 0 && s.wind != 0)
            // collisions and violent (jagged) forces need finer steps
            stepDT = s.noiseForce > 5000 ? ParticleSystem.dt / 4 : (collides ? ParticleSystem.dt / 2 : ParticleSystem.dt)

            if let c = s.sub.first, c.enabled, level < 2 {
                let child = RT(c, effect: e, ctx: ctx, index: index * 31 + 17, atlas: atlas, level: level + 1)
                sub = child
                windowExtra = (c.immortal ? 30 : child.life1) + c.burstSpread + child.windowExtra
            } else {
                windowExtra = 0
            }
            if let a = atlas { let rg = a.range(s); spriteBase = rg.base; spriteCount = rg.count }

            if s.shape == .grid {
                let n = max(1, s.emission == .burst ? s.count : s.rate * max(0.1, e.duration))
                let aspect = max(1e-3, ex) / max(1e-3, ey)
                let cols = max(1, Int((sqrt(n * aspect)).rounded()))
                gridCols = cols; gridRows = max(1, Int((n / Double(cols)).rounded(.up)))
            } else { gridCols = 1; gridRows = 1 }
        }

        static func lut(_ g: ColorGradient) -> [Float] {
            var out = [Float](repeating: 1, count: 256 * 4)
            for i in 0..<256 {
                let c = g.color(at: Double(i) / 255)
                out[i * 4] = Float(c.r); out[i * 4 + 1] = Float(c.g); out[i * 4 + 2] = Float(c.b); out[i * 4 + 3] = Float(c.a)
            }
            return out
        }

        var lifeWindow: Double { s.immortal ? 1e9 : life1 * (s.depth > 0 ? 1 + 3 * s.depth : 1) }
    }

    struct Body {
        var x = 0.0, y = 0.0, vx = 0.0, vy = 0.0
        /// Age at which the particle died in a collision (-1 = still alive).
        var diedAt = -1.0
    }

    /// Scratch storage reused by one worker.
    final class Scratch {
        var hist: [Double] = []     // x, y pairs per integration step
        var pts: [(Double, Double)] = []   // ribbon history points
        var out: [PInstance] = []
        var zs: [Float] = []
        var particles = 0
    }

    // MARK: Entry point

    static func simulate(_ effect: ParticleEffect, ctx: ParticleContext, atlas: ParticleSpriteAtlas?, time: Double? = nil, scale: Double = 1) -> PSimResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        let T = time ?? effect.time
        var result = PSimResult()
        for (i, s) in effect.systems.enumerated() where s.enabled {
            let rt = RT(s, effect: effect, ctx: ctx, index: i, atlas: atlas)
            let (insts, count) = run(rt, T: T)
            result.particles += count
            if var last = result.runs.last, last.blend == s.blend {
                last.instances += insts
                last.particles += count
                last.name += " + " + s.name
                result.runs[result.runs.count - 1] = last
            } else {
                result.runs.append(PRun(blend: s.blend, name: s.name, instances: insts, particles: count))
            }
        }
        if scale != 1 {
            let k = Float(scale)
            for ri in result.runs.indices {
                result.runs[ri].instances.withUnsafeMutableBufferPointer { p in
                    for i in p.indices { p[i].x *= k; p[i].y *= k; p[i].hx *= k; p[i].hy *= k }
                }
            }
        }
        result.seconds = CFAbsoluteTimeGetCurrent() - t0
        return result
    }

    /// Emission slots of a top-level system that can matter at time T: (slot count, slot → (id a, id b, birth before sweep)).
    private static func slots(_ rt: RT, T: Double) -> (Int, (Int) -> (UInt64, UInt64, Double)) {
        let s = rt.s
        let window = rt.lifeWindow + rt.windowExtra + rt.sweepMax + s.burstSpread
        let cap = maxParticlesPerSystem
        if s.emission == .rate {
            let rate = max(0.001, s.rate)
            if rt.loopD > 0 {
                let n = min(cap, max(1, Int((rate * rt.loopD).rounded())))
                return (n, { k in
                    var r = PRNG(rt.seed, UInt64(k), 1)
                    return (UInt64(k), 0, (Double(k) + r.next()) / rate)
                })
            }
            var kmax = Int(((T - s.startTime) * rate).rounded(.up))
            if s.emitDuration > 0 { kmax = min(kmax, Int(s.emitDuration * rate)) }
            var kmin = window > 1e8 ? Int.min / 4 : Int(((T - window - s.startTime) * rate).rounded(.down)) - 1
            if !s.prewarm || s.immortal { kmin = max(kmin, 0) }
            if kmax - kmin > cap { kmin = kmax - cap }
            let n = max(0, kmax - kmin)
            return (n, { i in
                let k = kmin + i
                var r = PRNG(rt.seed, UInt64(bitPattern: Int64(k)), 1)
                return (UInt64(bitPattern: Int64(k)), 0, s.startTime + (Double(k) + r.next()) / rate)
            })
        }
        let per = min(cap, max(0, Int(s.count.rounded())))
        if per == 0 { return (0, { _ in (0, 0, 0) }) }
        if rt.loopD > 0 {
            let bursts = s.burstInterval > 0 ? max(1, Int(rt.loopD / s.burstInterval)) : 1
            let nb = min(bursts, max(1, cap / per))
            return (per * nb, { i in
                let j = i / per
                return (UInt64(i % per), UInt64(j + 1), s.startTime + Double(j) * s.burstInterval)
            })
        }
        if s.burstInterval <= 0 {
            return (per, { i in (UInt64(i), 1, s.startTime) })
        }
        var jmax = Int(((T - s.startTime) / s.burstInterval).rounded(.down))
        if s.emitDuration > 0 { jmax = min(jmax, Int(s.emitDuration / s.burstInterval)) }
        var jmin = window > 1e8 ? 0 : Int(((T - window - s.startTime) / s.burstInterval).rounded(.up))
        if !s.prewarm { jmin = max(0, jmin) }
        let nb = max(0, min(jmax - jmin + 1, max(1, cap / per)))
        jmin = jmax - nb + 1
        return (per * nb, { i in
            let j = jmin + i / per
            return (UInt64(i % per), UInt64(bitPattern: Int64(j)) &+ 1, s.startTime + Double(j) * s.burstInterval)
        })
    }

    private static func run(_ rt: RT, T: Double) -> ([PInstance], Int) {
        let (n, slot) = slots(rt, T: T)
        if n <= 0 { return ([], 0) }
        let chunk = 1024
        let chunks = (n + chunk - 1) / chunk
        let needSort = rt.s.blend != .additive && (rt.s.depth > 0 || rt.depthAware)
        var parts = [Scratch?](repeating: nil, count: chunks)
        parts.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let sc = Scratch()
                let a = c * chunk, b = min(n, a + chunk)
                sc.out.reserveCapacity((b - a) * 2)
                for i in a..<b {
                    let (ia, ib, birth) = slot(i)
                    emitTop(rt, idA: ia, idB: ib, slot: i, total: n, birth: birth, T: T, sc: sc, sort: needSort)
                }
                p[c] = sc
            }
        }
        var total = 0, particles = 0
        for s in parts { total += s?.out.count ?? 0; particles += s?.particles ?? 0 }
        var out = [PInstance]()
        out.reserveCapacity(total)
        for s in parts { if let s { out.append(contentsOf: s.out) } }
        if needSort {
            var zs = [Float]()
            zs.reserveCapacity(total)
            for s in parts { if let s { zs.append(contentsOf: s.zs) } }
            if zs.count == out.count {
                let order = (0..<out.count).sorted { zs[$0] > zs[$1] || (zs[$0] == zs[$1] && $0 < $1) }
                out = order.map { out[$0] }
            }
        }
        return (out, particles)
    }

    // MARK: Emitter

    /// Birth position (px), emitter normal (unit) and path parameter.
    private static func emitterSample(_ rt: RT, rng: inout PRNG, slot: Int, total: Int) -> (x: Double, y: Double, nx: Double, ny: Double, u: Double) {
        let s = rt.s
        let r0 = rng.next(), r1 = rng.next(), r2 = rng.next()
        @inline(__always) func local(_ lx: Double, _ ly: Double) -> (Double, Double) {
            (rt.cx + lx * rt.erc - ly * rt.ers, rt.cy + lx * rt.ers + ly * rt.erc)
        }
        @inline(__always) func rot(_ nx: Double, _ ny: Double) -> (Double, Double) { (nx * rt.erc - ny * rt.ers, nx * rt.ers + ny * rt.erc) }
        switch s.shape {
        case .point:
            let a = r0 * 2 * .pi
            return (rt.cx, rt.cy, cos(a), sin(a), 0)
        case .line:
            let (x, y) = local((r0 * 2 - 1) * rt.ex, 0)
            let (nx, ny) = rot(0, -1)
            return (x, y, nx, ny, r0)
        case .circle:
            let a = r0 * 2 * .pi, rr = sqrt(r1)
            let (x, y) = local(cos(a) * rr * rt.ex, sin(a) * rr * rt.ey)
            let (nx, ny) = rot(cos(a), sin(a))
            return (x, y, nx, ny, r0)
        case .ring:
            let a = r0 * 2 * .pi, rr = 1 - r1 * 0.04
            let (x, y) = local(cos(a) * rr * rt.ex, sin(a) * rr * rt.ey)
            let (nx, ny) = rot(cos(a), sin(a))
            return (x, y, nx, ny, r0)
        case .rectangle:
            let (x, y) = local((r0 * 2 - 1) * rt.ex, (r1 * 2 - 1) * rt.ey)
            let (nx, ny) = rot(0, -1)
            return (x, y, nx, ny, r0)
        case .frame:
            let per = 2 * (rt.ex + rt.ey)
            var d = r0 * 2 * per
            var lx = 0.0, ly = 0.0, nx = 0.0, ny = 0.0
            if d < 2 * rt.ex { lx = d - rt.ex; ly = -rt.ey; ny = -1 }
            else { d -= 2 * rt.ex
                if d < 2 * rt.ey { lx = rt.ex; ly = d - rt.ey; nx = 1 }
                else { d -= 2 * rt.ey
                    if d < 2 * rt.ex { lx = rt.ex - d; ly = rt.ey; ny = 1 }
                    else { d -= 2 * rt.ex; lx = -rt.ex; ly = rt.ey - d; nx = -1 }
                }
            }
            let (x, y) = local(lx, ly)
            let (rx, ry) = rot(nx, ny)
            return (x, y, rx, ry, r0)
        case .grid:
            let cells = rt.gridCols * rt.gridRows
            let i = ((slot % cells) + cells) % cells
            let gx = (Double(i % rt.gridCols) + 0.5 + (r0 - 0.5) * s.gridJitter) / Double(rt.gridCols)
            let gy = (Double(i / rt.gridCols) + 0.5 + (r1 - 0.5) * s.gridJitter) / Double(rt.gridRows)
            let (x, y) = local((gx * 2 - 1) * rt.ex, (gy * 2 - 1) * rt.ey)
            let dx = x - rt.cx, dy = y - rt.cy, l = max(1e-6, sqrt(dx * dx + dy * dy))
            return (x, y, dx / l, dy / l, gx)
        case .spiral:
            let arms = max(1, Int(s.arms.rounded()))
            let g1 = (rng.next() + rng.next() + rng.next() - 1.5) / 1.5, g2 = (rng.next() + rng.next() + rng.next() - 1.5) / 1.5
            if r2 < 0.18 {   // central bulge
                let (x, y) = local(g1 * 0.16 * rt.ex, g2 * 0.16 * rt.ey)
                return (x, y, g1, g2, 0)
            }
            let arm = Int(r0 * Double(arms)) % arms
            let t = pow(r1, 0.75)
            let ang = Double(arm) * 2 * .pi / Double(arms) + s.twist * t * .pi
            let scatter = 0.035 + 0.11 * t
            let lx = (cos(ang) * t + g1 * scatter) * rt.ex, ly = (sin(ang) * t + g2 * scatter) * rt.ey
            let (x, y) = local(lx, ly)
            let (nx, ny) = rot(cos(ang), sin(ang))
            return (x, y, nx, ny, t)
        case .path:
            if let p = rt.path {
                let a = p.at(r0)
                return (a.x, a.y, a.ty, -a.tx, r0)
            }
            let (x, y) = local((r0 * 2 - 1) * rt.ex, 0)
            return (x, y, 0, -1, r0)
        case .selectionOutline, .selectionArea, .layerAlpha, .layerEdges, .text, .brightness:
            if let ar = rt.area {
                let (u, v) = ar.sample(r0, r1, r2)
                var nx = 0.0, ny = -1.0
                if s.normalSpeed != 0 || s.shape.isOutline || s.outlineOnly {
                    let (gx, gy) = (rt.normalMap ?? ar.map).gradient(u, v)
                    let l = sqrt(gx * gx + gy * gy)
                    if l > 1e-6 { nx = -gx / l; ny = -gy / l }
                }
                return (u * rt.W, v * rt.H, nx, ny, r0)
            }
            let (x, y) = local((r0 * 2 - 1) * rt.ex, (r1 * 2 - 1) * rt.ey)
            return (x, y, 0, -1, r0)
        }
    }

    /// Delay before a point is released: the front starts on the side the particles are blown towards
    /// (`sweepAngle`) and eats its way back through the emitter, with a noisy edge.
    private static func sweepDelay(_ rt: RT, _ x: Double, _ y: Double) -> Double {
        let s = rt.s
        if s.sweep <= 0 { return 0 }
        let a = s.sweepAngle * .pi / 180
        let dx = cos(a), dy = -sin(a)
        // extent of the emitter box projected on the sweep direction
        let half = abs(dx) * max(1, rt.ex) + abs(dy) * max(1, rt.ey)
        let proj = ((x - rt.cx) * dx + (y - rt.cy) * dy) / half * 0.5 + 0.5
        let n = PNoise.fbm(x / (160 * rt.U) + rt.noiseOX, y / (160 * rt.U) + rt.noiseOY, 0.37, octaves: 3)
        return max(0, (1 - proj + n * s.sweepNoise * 0.5)) * s.sweep
    }

    /// Fraction (0…1) of the dissolve front at a canvas point for time T (1 = already dissolved). Used to mask the source layer.
    static func sweepCoverage(_ s: ParticleSystemSettings, effect e: ParticleEffect, ctx: ParticleContext, index: Int, T: Double) -> PMap {
        let rt = RT(s, effect: e, ctx: ctx, index: index, atlas: nil)
        let sc = min(1, 512 / Double(max(ctx.width, ctx.height)))
        var m = PMap(w: Int(Double(ctx.width) * sc), h: Int(Double(ctx.height) * sc))
        let soft = max(0.02, s.sweep * 0.03)
        for y in 0..<m.h {
            for x in 0..<m.w {
                let px = (Double(x) + 0.5) / Double(m.w) * rt.W, py = (Double(y) + 0.5) / Double(m.h) * rt.H
                let d = s.startTime + sweepDelay(rt, px, py)
                m.data[y * m.w + x] = Float(ParticleSprites.sstep(d - soft, d + soft, T))
            }
        }
        return m
    }

    // MARK: Particle

    private static func emitTop(_ rt: RT, idA: UInt64, idB: UInt64, slot: Int, total: Int, birth: Double, T: Double, sc: Scratch, sort: Bool) {
        let s = rt.s
        var rng = PRNG(rt.seed, idA, idB)
        // density noise: rejection sample the emitter
        var e = emitterSample(rt, rng: &rng, slot: slot, total: total)
        if s.densityNoise > 0 {
            var tries = 0
            let sc2 = max(10, s.densityNoiseScale * rt.U)
            while tries < 6 {
                let n = PNoise.fbm(e.x / sc2 + rt.noiseOY, e.y / sc2 + rt.noiseOX, 1.7, octaves: 3) * 0.5 + 0.5
                let keep = 1 - s.densityNoise + s.densityNoise * ParticleSprites.sstep(0.35, 0.7, n)
                if rng.next() < keep { break }
                e = emitterSample(rt, rng: &rng, slot: slot, total: total)
                tries += 1
            }
            if tries == 6 && s.densityNoise > 0.85 { return }
        }
        var b = birth + rng.next() * s.burstSpread
        if s.sweep > 0 { b += sweepDelay(rt, e.x, e.y) }
        if rt.loopD > 0 {
            var base = (T - b).truncatingRemainder(dividingBy: rt.loopD)
            if base < 0 { base += rt.loopD }
            let window = rt.lifeWindow + rt.windowExtra
            var age = base
            var n = 0
            while age < window && n < 64 {
                var r2 = rng
                particle(rt, rng: &r2, ex: e.x, ey: e.y, nx: e.nx, ny: e.ny, u: e.u, pvx: 0, pvy: 0, parentColor: nil, age: age, T: T, sc: sc, sort: sort)
                age += rt.loopD; n += 1
            }
        } else {
            let age = T - b
            if age < 0 { return }
            if s.emitDuration > 0, s.emission == .rate, b - s.startTime > s.emitDuration + rt.sweepMax { return }
            particle(rt, rng: &rng, ex: e.x, ey: e.y, nx: e.nx, ny: e.ny, u: e.u, pvx: 0, pvy: 0, parentColor: nil, age: age, T: T, sc: sc, sort: sort)
        }
    }

    /// Simulates one particle born at (ex, ey) `age` seconds before T and appends its sprites (and its sub-particles).
    private static func particle(_ rt: RT, rng: inout PRNG, ex: Double, ey: Double, nx: Double, ny: Double, u: Double, pvx: Double, pvy: Double,
                                 parentColor: (Float, Float, Float)?, age: Double, T: Double, sc: Scratch, sort: Bool) {
        let s = rt.s
        // fixed-order random attributes (so toggling options doesn't reshuffle the others)
        let rLife = rng.next(), rSpeed = rng.next(), rAng = rng.next(), rSize = rng.next(), rRot = rng.next(), rSpin = rng.next()
        let rCol = rng.next(), rHue = rng.next(), rBri = rng.next(), rOp = rng.next(), rPhase = rng.next(), rZ = rng.next()
        let rVar = rng.next(), rTum = rng.next(), rRad = rng.next()
        let childSeed = rng.nextU64()

        // depth: near particles are larger and faster; lifetimes stretch with distance so every depth travels equally far
        let z = s.depth > 0 || s.dofBlur > 0 || s.atmosphere > 0 || rt.depthAware ? sqrt(rZ) : 0.5
        let pscale = s.depth > 0 ? pow(1 + 3 * s.depth, 1 - 2 * z) : 1
        let life = (rt.life0 + (rt.life1 - rt.life0) * rLife) / pscale
        let dead = !s.immortal && age >= life
        if dead && (rt.sub == nil || age - life > rt.windowExtra) { return }

        // initial velocity
        let dir = s.direction * .pi / 180 + (rAng - 0.5) * s.spread * .pi / 180
        let speed = (s.speedMin + (s.speedMax - s.speedMin) * rSpeed) * rt.U
        var vx = cos(dir) * speed, vy = -sin(dir) * speed
        if s.radialSpeed != 0 || s.tangentialSpeed != 0 {
            var rx = ex - rt.cx, ry = ey - rt.cy
            let l = sqrt(rx * rx + ry * ry)
            if l > 1e-6 && !rt.isChild { rx /= l; ry /= l } else { rx = nx; ry = ny }
            let rs = s.radialSpeed * rt.U * (0.6 + 0.8 * rRad), ts = s.tangentialSpeed * rt.U
            vx += rx * rs + ry * ts; vy += ry * rs - rx * ts
        }
        if s.normalSpeed != 0 { vx += nx * s.normalSpeed * rt.U * (0.5 + rRad); vy += ny * s.normalSpeed * rt.U * (0.5 + rRad) }
        vx = vx * pscale + pvx * s.inheritVelocity; vy = vy * pscale + pvy * s.inheritVelocity

        var body = Body(x: ex, y: ey, vx: vx, vy: vy)
        let simAge = dead ? life : age
        let wantHist = !dead && (s.trail == .ribbon || s.trail == .echo)
        let steps = advance(rt, &body, age: simAge, birthAbs: T - age, pscale: pscale, u0: u, sc: sc, record: wantHist)
        let died = dead || body.diedAt >= 0
        if died {
            guard let sub = rt.sub else { return }
            let deathAge = body.diedAt >= 0 ? body.diedAt : life
            let since = age - deathAge
            if since < 0 || since > rt.windowExtra { return }
            // colour handed to the children
            var pc: (Float, Float, Float) = parentColor ?? (1, 1, 1)
            if s.colorBase == .palette {
                let i = min(255, Int(rCol * 255)) * 4
                pc = (rt.palLUT[i], rt.palLUT[i + 1], rt.palLUT[i + 2])
            }
            let n = min(20000, max(0, Int(sub.s.count.rounded())))
            for c in 0..<n {
                var cr = PRNG(childSeed, UInt64(c), 0xC41D)
                let delay = cr.next() * sub.s.burstSpread
                let cage = since - delay
                if cage < 0 { continue }
                let a = cr.next() * 2 * .pi
                particle(sub, rng: &cr, ex: body.x, ey: body.y, nx: cos(a), ny: sin(a), u: 0, pvx: body.vx, pvy: body.vy, parentColor: pc,
                         age: cage, T: T, sc: sc, sort: sort)
            }
            return
        }
        sc.particles += 1

        // ---- appearance ----
        let lifeT = s.immortal ? (age / life).truncatingRemainder(dividingBy: 1) : min(1, age / life)
        let li = min(255, Int(lifeT * 255))
        var size = (s.sizeMin + (s.sizeMax - s.sizeMin) * pow(rSize, max(0.05, s.sizeBias))) * rt.U * Double(rt.sizeLUT[li]) * pscale
        if s.sizeByDistance != 0 {
            let d = min(1.5, sqrt(pow((ex - rt.cx) / max(1, rt.ex), 2) + pow((ey - rt.cy) / max(1, rt.ey), 2)))
            size *= max(0, s.sizeByDistance > 0 ? 1 - s.sizeByDistance * d : 1 + s.sizeByDistance * (1 - d))
        }
        if size <= 0.01 { return }

        var cr = rt.gradLUT[li * 4], cg = rt.gradLUT[li * 4 + 1], cb = rt.gradLUT[li * 4 + 2]
        var alpha = Double(rt.gradLUT[li * 4 + 3]) * Double(rt.opacityLUT[li]) * s.opacity * (1 - s.opacityRandom * rOp)
        switch s.colorBase {
        case .none: break
        case .palette:
            let i = min(255, Int(rCol * 255)) * 4
            cr *= rt.palLUT[i]; cg *= rt.palLUT[i + 1]; cb *= rt.palLUT[i + 2]; alpha *= Double(rt.palLUT[i + 3])
        case .image:
            if let m = rt.colorMap {
                let c = m.sample(ex / rt.W, ey / rt.H)
                cr *= Float(c.0); cg *= Float(c.1); cb *= Float(c.2); alpha *= c.3
            }
        case .parent:
            if let p = parentColor { cr *= p.0; cg *= p.1; cb *= p.2 }
        }
        if s.hueVariation > 0 {
            let c = RGBA(r: Double(cr), g: Double(cg), b: Double(cb))
            let hsb = c.hsb
            let shifted = RGBA(h: hsb.h + (rHue - 0.5) * s.hueVariation, s: hsb.s, v: hsb.b)
            cr = Float(shifted.r); cg = Float(shifted.g); cb = Float(shifted.b)
        }
        if s.brightnessVariation > 0 {
            let k = Float(1 - s.brightnessVariation * rBri)
            cr *= k; cg *= k; cb *= k
        }
        if s.twinkle > 0 {
            let tw = 0.5 + 0.5 * sin(2 * .pi * (s.twinkleSpeed * age * (0.6 + 0.8 * rTum) + rPhase))
            alpha *= 1 - s.twinkle * (1 - tw * tw)
        }
        if s.atmosphere > 0 { alpha *= 1 - s.atmosphere * z }
        var lod: Float = 0
        if s.dofBlur > 0 {
            let bl = 1 + s.dofBlur * 6 * abs(z - s.focus)
            size *= bl
            alpha /= bl
            lod = Float(log2(bl) * 1.25)
        }
        if let dm = rt.depthMap {
            let sn = dm.sample(body.x / rt.W, body.y / rt.H)
            alpha *= ParticleSprites.sstep(-0.05, 0.05, (1 - z) - sn)
        }
        if alpha <= 0.002 { return }

        var px = body.x, py = body.y
        if s.snapGrid > 0 {
            let g = s.snapGrid * rt.U
            px = (px / g).rounded() * g; py = (py / g).rounded() * g
        }

        // rotation
        var ang: Double
        let sp = sqrt(body.vx * body.vx + body.vy * body.vy)
        if s.alignToVelocity && sp > 1e-6 {
            ang = atan2(body.vy, body.vx) - s.rotation * .pi / 180
        } else {
            ang = -(s.rotation + (rRot * 2 - 1) * s.rotationRandom + (s.spin + (rSpin * 2 - 1) * s.spinRandom) * age) * .pi / 180
        }
        var hx = size / 2, hy = size / 2 * s.spriteAspect
        if s.tumble != 0 {
            let c = cos(2 * .pi * (s.tumble * age * (0.5 + rTum) + rPhase))
            hx *= max(0.08, abs(c))
            let shade = Float(c > 0 ? 1.0 : 0.72) * Float(0.8 + 0.2 * abs(c))
            cr *= shade; cg *= shade; cb *= shade
        }
        // sub-pixel sprites: keep at least ~1 px and conserve energy
        let minHalf = 0.5
        if hx < minHalf { alpha *= hx / minHalf; hx = minHalf }
        if hy < minHalf { alpha *= hy / minHalf; hy = minHalf }

        let layer = Float(rt.spriteBase + (rt.spriteCount > 1 ? min(rt.spriteCount - 1, Int(rVar * Double(rt.spriteCount))) : 0))
        let fa = Float(min(1, alpha))
        let zf = Float(z)
        @inline(__always) func push(_ x: Double, _ y: Double, _ hx: Double, _ hy: Double, _ c: Double, _ sn: Double, _ layer: Float, _ a: Float,
                                    _ r: Float, _ g: Float, _ b: Float) {
            sc.out.append(PInstance(x: Float(x), y: Float(y), hx: Float(hx), hy: Float(hy), cs: Float(c), sn: Float(sn), layer: layer, lod: lod,
                                    r: r * a, g: g * a, b: b * a, a: a))
            if sort { sc.zs.append(zf) }
        }

        switch s.trail {
        case .none:
            push(px, py, hx, hy, cos(ang), sin(ang), layer, fa, cr, cg, cb)
        case .stretch, .streak:
            let L = sp * s.trailLength
            if sp < 1e-6 || L < 0.5 {
                push(px, py, hx, hy, cos(ang), sin(ang), layer, fa, cr, cg, cb)
            } else {
                let dx = body.vx / sp, dy = body.vy / sp
                let half = (L + size) / 2
                let shift = L / 2
                let lay = s.trail == .streak ? Float(ParticleSprites.cometLayer) : layer
                push(px - dx * shift, py - dy * shift, half, max(minHalf, hy * s.trailWidth), dx, dy, lay, fa, cr, cg, cb)
            }
        case .ribbon, .echo:
            let segs = max(1, min(64, Int(s.trailSegments.rounded())))
            let stepAge = s.trailLength / Double(segs)
            let dtStep = rt.stepDT
            @inline(__always) func histAt(_ a: Double) -> (Double, Double) {
                if !rt.needsIntegration {
                    var bb = Body(x: ex, y: ey, vx: vx, vy: vy)
                    closedForm(rt, &bb, age: max(0, a), pscale: pscale)
                    return (bb.x, bb.y)
                }
                let f = max(0, a) / dtStep
                let i0 = min(steps, Int(f)), i1 = min(steps, i0 + 1)
                let t = f - Double(i0)
                return sc.hist.withUnsafeBufferPointer { h in
                    (h[i0 * 2] + (h[i1 * 2] - h[i0 * 2]) * t, h[i0 * 2 + 1] + (h[i1 * 2 + 1] - h[i0 * 2 + 1]) * t)
                }
            }
            if s.trail == .ribbon {
                // history points, newest first
                if sc.pts.count < segs + 1 { sc.pts = [(Double, Double)](repeating: (0, 0), count: 65) }
                sc.pts[0] = (px, py)
                var length = 0.0
                for k in 1...segs {
                    sc.pts[k] = histAt(age - Double(k) * stepAge)
                    length += hypot(sc.pts[k].0 - sc.pts[k - 1].0, sc.pts[k].1 - sc.pts[k - 1].1)
                }
                // segments much shorter than the ribbon is wide overlap visibly at bends: use fewer, longer ones
                let width = max(1, size * s.trailWidth)
                let m = max(2, min(segs, Int(length / (width * 0.75)) + 1))
                var lastI = 0
                for k in 1...m {
                    let i = k == m ? segs : min(segs, Int((Double(k) * Double(segs) / Double(m)).rounded()))
                    if i == lastI { continue }
                    let (ax, ay) = sc.pts[lastI], (bx, by) = sc.pts[i]
                    let dx = ax - bx, dy = ay - by
                    let l = sqrt(dx * dx + dy * dy)
                    if l > 0.05 {
                        let f0 = 1 - Double(lastI) / Double(segs)
                        let w = max(minHalf, size / 2 * s.trailWidth * (0.25 + 0.75 * f0))
                        var r = cr, g = cg, b = cb
                        if s.trailGradient {
                            let gi = min(255, Int(Double(lastI) / Double(segs) * 255)) * 4
                            r = rt.gradLUT[gi]; g = rt.gradLUT[gi + 1]; b = rt.gradLUT[gi + 2]
                        }
                        push((ax + bx) / 2, (ay + by) / 2, l / 2 + 0.35, w, dx / l, dy / l, Float(ParticleSprites.barLayer), fa * Float(pow(f0, 1.3)), r, g, b)
                    }
                    lastI = i
                }
                push(px, py, hx, hy, cos(ang), sin(ang), layer, fa, cr, cg, cb)
            } else {
                var hr = PRNG(childSeed, 77)
                for k in stride(from: segs, through: 0, by: -1) {
                    let a = age - Double(k) * stepAge
                    if a < 0 { _ = hr.nextU64(); continue }
                    var (hxp, hyp) = k == 0 ? (body.x, body.y) : histAt(a)
                    if s.snapGrid > 0 {
                        let g = s.snapGrid * rt.U
                        hxp = (hxp / g).rounded() * g; hyp = (hyp / g).rounded() * g
                    }
                    let f0 = 1 - Double(k) / Double(segs + 1)
                    var r = cr, g = cg, b = cb
                    if s.trailGradient {
                        let gi = min(255, Int(Double(k) / Double(segs) * 255)) * 4
                        r = rt.gradLUT[gi]; g = rt.gradLUT[gi + 1]; b = rt.gradLUT[gi + 2]
                    }
                    // each stamp shows its own sprite variant (glyph columns), changing slowly over time
                    let pick = PRNG.mix(hr.nextU64() &+ UInt64(max(0, Int((T - Double(k) * stepAge) * 2.0 + Double(k)))))
                    let lay = Float(rt.spriteBase + (rt.spriteCount > 1 ? Int(pick % UInt64(rt.spriteCount)) : 0))
                    push(hxp, hyp, hx, hy, cos(ang), sin(ang), lay, fa * Float(pow(f0, 1.4)), r, g, b)
                }
            }
        }
    }

    // MARK: Motion

    /// Moves a body from birth to `age`. Returns the number of integration steps recorded in the scratch history.
    @discardableResult
    private static func advance(_ rt: RT, _ b: inout Body, age: Double, birthAbs: Double, pscale: Double, u0: Double, sc: Scratch, record: Bool) -> Int {
        if !rt.needsIntegration {
            closedForm(rt, &b, age: age, pscale: pscale)
            return 0
        }
        let s = rt.s
        let dt = rt.stepDT
        let n = Int(age / dt)
        let rem = age - Double(n) * dt
        let total = n + (rem > 1e-9 ? 1 : 0)
        if record {
            if sc.hist.count < (total + 2) * 2 { sc.hist = [Double](repeating: 0, count: (total + 64) * 2) }
            sc.hist[0] = b.x; sc.hist[1] = b.y
        }
        let U = rt.U
        let gAcc = s.gravity * U * pscale, wAcc = s.wind * U * pscale
        let turb = s.turbulence * U * pscale, tScale = 1 / max(1, s.turbulenceScale * U)
        let nForce = s.noiseForce * U * pscale
        let om = s.vortex * .pi / 180, vR = max(1, s.vortexRadius * U), pull = s.vortexPull * U
        let hasPath = s.followPath > 0 && rt.path != nil
        let ox0 = b.x, oy0 = b.y
        var pathOffX = 0.0, pathOffY = 0.0
        if hasPath, let p = rt.path { let a = p.at(u0); pathOffX = ox0 - a.x; pathOffY = oy0 - a.y }
        let mask = rt.collision
        var recorded = 0
        for i in 0..<total {
            let h = i < n ? dt : rem
            let localAge = Double(i) * dt
            let tAbs = birthAbs + localAge
            var ax = wAcc, ay = gAcc
            if s.gust > 0 && wAcc != 0 {
                // periodic in loop mode: the time axis runs around a circle
                let g0 = rt.loopD > 0 ? cos(2 * .pi * tAbs / rt.loopD) * 0.8 : tAbs * 0.45
                let g1 = rt.loopD > 0 ? sin(2 * .pi * tAbs / rt.loopD) * 0.8 : 0
                ax *= 1 + s.gust * PNoise.value(g0 + rt.noiseOX, b.y * tScale * 0.3 + g1, b.x * tScale * 0.15)
            }
            for a in rt.attractors {
                let dx = a.x - b.x, dy = a.y - b.y
                let d = sqrt(dx * dx + dy * dy) + 1e-6
                let f = a.s / (1 + (d / a.r) * (d / a.r))
                ax += dx / d * f; ay += dy / d * f
            }
            if nForce != 0 {
                let (fx, fy) = forceAt(rt, b.x * tScale * 1.7, b.y * tScale * 1.7, tAbs)
                ax += fx * nForce; ay += fy * nForce
            }
            b.vx += ax * h; b.vy += ay * h
            if s.drag > 0 { let k = exp(-s.drag * h); b.vx *= k; b.vy *= k }
            if hasPath, let p = rt.path {
                let u = u0 + s.followSpeed * U * localAge / p.length
                let tg = p.at(u)
                // at the end of an open path the particle settles on the end point instead of overshooting
                let along = !p.closed && (u >= 1 || u <= 0) ? 0 : s.followSpeed * U
                let dvx = (tg.x + pathOffX - b.x) * 4 + tg.tx * along
                let dvy = (tg.y + pathOffY - b.y) * 4 + tg.ty * along
                let k = min(1, s.followPath * h * 8)
                b.vx += (dvx - b.vx) * k; b.vy += (dvy - b.vy) * k
            }
            let prevX = b.x, prevY = b.y
            b.x += b.vx * h; b.y += b.vy * h
            if turb != 0 {
                let (cx, cy) = curlAt(rt, b.x * tScale + rt.noiseOX, b.y * tScale + rt.noiseOY, tAbs)
                b.x += cx * turb * h; b.y += cy * turb * h
            }
            if om != 0 || pull != 0 {
                let dx = b.x - rt.vcx, dy = b.y - rt.vcy
                let d = sqrt(dx * dx + dy * dy) + 1e-6
                let f = 1 / (1 + (d / vR) * (d / vR))
                b.x += dy * om * f * h * pscale - dx / d * pull * f * h
                b.y += -dx * om * f * h * pscale - dy / d * pull * f * h
            }
            // collisions
            if s.floorEnabled, b.y > rt.floorPx {
                if s.dieOnCollision { b.y = rt.floorPx; b.diedAt = localAge + h; recorded = i + 1; if record { sc.hist[(i + 1) * 2] = b.x; sc.hist[(i + 1) * 2 + 1] = b.y }; break }
                b.y = rt.floorPx - (b.y - rt.floorPx) * s.restitution
                b.vy = -abs(b.vy) * s.restitution
                b.vx *= 1 - s.friction
            }
            if s.bounceEdges {
                if b.x < 0 { b.x = -b.x * s.restitution; b.vx = abs(b.vx) * s.restitution }
                if b.x > rt.W { b.x = rt.W - (b.x - rt.W) * s.restitution; b.vx = -abs(b.vx) * s.restitution }
                if b.y < 0 { b.y = -b.y * s.restitution; b.vy = abs(b.vy) * s.restitution }
                if b.y > rt.H {
                    if s.dieOnCollision { b.y = rt.H; b.diedAt = localAge + h; recorded = i + 1; if record { sc.hist[(i + 1) * 2] = b.x; sc.hist[(i + 1) * 2 + 1] = b.y }; break }
                    b.y = rt.H - (b.y - rt.H) * s.restitution; b.vy = -abs(b.vy) * s.restitution; b.vx *= 1 - s.friction
                }
            }
            if let m = mask, localAge > 0.05 {
                let u = b.x / rt.W, v = b.y / rt.H
                if u >= 0, u <= 1, v >= 0, v <= 1, m.sample(u, v) > 0.5 {
                    if s.dieOnCollision { b.diedAt = localAge + h; recorded = i + 1; if record { sc.hist[(i + 1) * 2] = b.x; sc.hist[(i + 1) * 2 + 1] = b.y }; break }
                    let (gx, gy) = m.gradient(u, v)
                    let gl = sqrt(gx * gx + gy * gy)
                    if gl > 1e-6 {
                        let nx = -gx / gl, ny = -gy / gl     // pointing out of the obstacle
                        let vn = b.vx * nx + b.vy * ny
                        if vn < 0 { b.vx -= (1 + s.restitution) * vn * nx; b.vy -= (1 + s.restitution) * vn * ny }
                        b.vx *= 1 - s.friction * 0.5; b.vy *= 1 - s.friction * 0.5
                    } else { b.vx = -b.vx * s.restitution; b.vy = -b.vy * s.restitution }
                    b.x = prevX; b.y = prevY
                }
            }
            if s.confine {
                // emitter-local coordinates
                let dx = b.x - rt.cx, dy = b.y - rt.cy
                let lx = dx * rt.erc + dy * rt.ers, ly = -dx * rt.ers + dy * rt.erc
                let rx = max(1, rt.ex), ry = max(1, rt.ey)
                if s.shape == .circle || s.shape == .ring {
                    let q = (lx / rx) * (lx / rx) + (ly / ry) * (ly / ry)
                    if q > 1 {
                        var nx = lx / (rx * rx), ny = ly / (ry * ry)
                        let nl = sqrt(nx * nx + ny * ny); nx /= nl; ny /= nl
                        let wnx = nx * rt.erc - ny * rt.ers, wny = nx * rt.ers + ny * rt.erc
                        let vn = b.vx * wnx + b.vy * wny
                        if vn > 0 { b.vx -= (1 + s.restitution) * vn * wnx; b.vy -= (1 + s.restitution) * vn * wny }
                        let k = 1 / sqrt(q)
                        let clx = lx * k * 0.995, cly = ly * k * 0.995
                        b.x = rt.cx + clx * rt.erc - cly * rt.ers; b.y = rt.cy + clx * rt.ers + cly * rt.erc
                    }
                } else if abs(lx) > rx || abs(ly) > ry {
                    var vlx = b.vx * rt.erc + b.vy * rt.ers, vly = -b.vx * rt.ers + b.vy * rt.erc
                    var clx = lx, cly = ly
                    if abs(lx) > rx { clx = lx > 0 ? rx : -rx; vlx = -vlx * s.restitution }
                    if abs(ly) > ry { cly = ly > 0 ? ry : -ry; vly = -vly * s.restitution }
                    b.x = rt.cx + clx * rt.erc - cly * rt.ers; b.y = rt.cy + clx * rt.ers + cly * rt.erc
                    b.vx = vlx * rt.erc - vly * rt.ers; b.vy = vlx * rt.ers + vly * rt.erc
                }
            }
            recorded = i + 1
            if record { sc.hist[(i + 1) * 2] = b.x; sc.hist[(i + 1) * 2 + 1] = b.y }
        }
        return recorded
    }

    /// Random (non-conservative) force direction; cross-faded in loop mode like the curl field.
    @inline(__always) private static func forceAt(_ rt: RT, _ x: Double, _ y: Double, _ tAbs: Double) -> (Double, Double) {
        let sp = rt.s.turbulenceSpeed
        @inline(__always) func f(_ z: Double) -> (Double, Double) {
            (PNoise.simplex(x + rt.noiseOY, y + rt.noiseOX, z + 11.3).n, PNoise.simplex(x - rt.noiseOX + 40, y + rt.noiseOY - 40, z + 3.1).n)
        }
        if rt.loopD > 0 && sp != 0 {
            var tau = tAbs.truncatingRemainder(dividingBy: rt.loopD)
            if tau < 0 { tau += rt.loopD }
            let w = tau / rt.loopD
            let a = f(tau * sp), b = f((tau - rt.loopD) * sp)
            return (a.0 * (1 - w) + b.0 * w, a.1 * (1 - w) + b.1 * w)
        }
        return f(tAbs * sp)
    }

    /// Curl-noise velocity; in loop mode the field is cross-faded so it repeats every loop.
    @inline(__always) private static func curlAt(_ rt: RT, _ x: Double, _ y: Double, _ tAbs: Double) -> (Double, Double) {
        let sp = rt.s.turbulenceSpeed
        if rt.loopD > 0 && sp != 0 {
            var tau = tAbs.truncatingRemainder(dividingBy: rt.loopD)
            if tau < 0 { tau += rt.loopD }
            let w = tau / rt.loopD
            let a = PNoise.curl(x, y, tau * sp), b = PNoise.curl(x, y, (tau - rt.loopD) * sp)
            return (a.0 * (1 - w) + b.0 * w, a.1 * (1 - w) + b.1 * w)
        }
        return PNoise.curl(x, y, tAbs * sp)
    }

    /// Exact motion under constant acceleration and linear drag.
    @inline(__always) private static func closedForm(_ rt: RT, _ b: inout Body, age t: Double, pscale: Double) {
        let s = rt.s
        let ax = s.wind * rt.U * pscale, ay = s.gravity * rt.U * pscale
        let k = s.drag
        if k > 1e-6 {
            let e = exp(-k * t)
            let tx = ax / k, ty = ay / k
            b.x += tx * t + (b.vx - tx) * (1 - e) / k
            b.y += ty * t + (b.vy - ty) * (1 - e) / k
            b.vx = tx + (b.vx - tx) * e
            b.vy = ty + (b.vy - ty) * e
        } else {
            b.x += b.vx * t + 0.5 * ax * t * t
            b.y += b.vy * t + 0.5 * ay * t * t
            b.vx += ax * t; b.vy += ay * t
        }
    }
}
