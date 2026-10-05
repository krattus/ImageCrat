import Foundation
import CoreGraphics
import ImageCratCore

/// Places and rasterizes brush dabs with Photoshop-style dynamics into a stroke buffer.
///
/// Per-dab options (shape dynamics, scattering, color dynamics, transfer, per-tip texture) are applied while
/// stamping. Stroke-level options (dual brush, stroke texture, wet edges, noise) are applied by `postProcess`
/// from the raw stroke buffer into an output buffer, so overlapping dabs combine like in Photoshop.
final class BrushDynamicsEngine {
    enum Paint {
        /// Foreground / background colors (color dynamics apply).
        case dynamic(fg: RGBA, bg: RGBA)
        /// A fixed color (erasers, markers).
        case fixed(RGBA)
    }

    /// A computed dab (document coordinates) for tools that draw dabs themselves.
    struct DabInstance {
        var center: CGPoint
        var diameter: Double
        var roundness: Double
        var angle: Double
        var flipX: Bool
        var flipY: Bool
        var alpha: Double
    }

    let settings: BrushSettings
    let target: PixelBuffer
    /// Document position of target pixel (0,0).
    let origin: IPoint
    let paint: Paint
    let aliased: Bool
    /// Converts colors to gray (painting on masks).
    let grayOutput: Bool
    /// When set, dabs are handed to this closure instead of being rasterized into `target`.
    var customStamp: ((DabInstance) -> Void)?

    private var dyn: BrushDynamics { settings.dynamics }
    private var rng: SeededRandom
    private let tip: TipSource
    private var dualTip: TipSource?
    private(set) var dualBuf: PixelBuffer?
    private var sampler: TextureSampler?
    private var dirty = IRect.zero

    // Path state
    private var last: PenSample?
    /// Pulled-string smoothing of the options-bar Smoothing amount (see `StrokeSmoother`).
    private var smoother: StrokeSmoother
    private let smoothingOptions: SmoothingOptions
    private var sinceLast: Double = 0
    private var dualSince: Double = 0
    private var dabIndex = 0
    private var travelled: Double = 0
    private var direction: Double = 0
    private var initialDirection: Double?
    private var strokeColor: (Float, Float, Float)?

    // Scratch for the wet-edges box blur (reused between flushes).
    private var prefixRow: [Int32] = []
    private var colPrefix: [Int32] = []

    private static var strokeCounter: UInt64 = 0
    /// Extra dab positions for a dab at a document point (symmetry painting); nil/empty = none.
    nonisolated(unsafe) static var symmetryPoints: ((CGPoint) -> [CGPoint])?
    /// Input-point filter (stabilisers, assisted drawing): returns the samples to paint instead of the raw one
    /// ([] swallows it), or nil to leave the input untouched.
    enum InputPhase { case begin, move, end }
    nonisolated(unsafe) static var inputHook: ((BrushDynamicsEngine, PenSample, InputPhase) -> [PenSample]?)?
    /// Replaces the foreground colour of a dab (colour jitter from a palette); nil keeps it.
    nonisolated(unsafe) static var dabColorHook: ((BrushDynamicsEngine, RGBA) -> RGBA?)?
    private var inInputHook = false

    init(settings: BrushSettings, target: PixelBuffer, origin: IPoint, paint: Paint, aliased: Bool = false, grayOutput: Bool = false, seed: UInt64? = nil) {
        self.settings = settings
        self.target = target
        self.origin = origin
        self.paint = paint
        self.aliased = aliased
        self.grayOutput = grayOutput
        BrushDynamicsEngine.strokeCounter &+= 1
        rng = SeededRandom(seed: seed ?? (12345 &+ BrushDynamicsEngine.strokeCounter &* 0x9E3779B1))
        let opts = TabletSettings.shared.prefs.smoothing
        smoothingOptions = opts
        smoother = StrokeSmoother(radius: StrokeSmoother.radius(smoothing: settings.smoothing, zoom: TabletInput.shared.viewZoom,
                                                                adjustForZoom: opts.adjustForZoom),
                                  pulledString: opts.pulledString)
        tip = TipSource.get(settings.tipID)
        let d = settings.dynamics
        if d.dualEnabled {
            dualTip = TipSource.get(d.dualTipID)
            dualBuf = PixelBuffer(width: target.width, height: target.height, format: .gray)
        }
        if d.textureEnabled {
            sampler = TextureSampler.get(patternID: d.texturePatternID, scale: d.textureScale, brightness: d.textureBrightness,
                                         contrast: d.textureContrast, invert: d.textureInvert)
        }
    }

    /// Whether `postProcess` must run (stroke-level options are enabled).
    var needsPost: Bool { customStamp == nil && dyn.needsStrokePass }

    /// Returns and clears the region touched since the last call.
    func takeDirty() -> IRect {
        let r = dirty
        dirty = .zero
        if !r.isEmpty { target.markDirty() }
        return r
    }

    // MARK: Path

    func begin(_ s0: PenSample) {
        let s = BrushDynamicsEngine.inputHook?(self, s0, .begin)?.first ?? s0
        last = s
        smoother.begin(s.p)
        sinceLast = 0
        dualSince = 0
        place(s)
        placeDual(s)
    }

    func move(_ raw: PenSample, final: Bool = false) {
        if !inInputHook, last != nil, let pts = BrushDynamicsEngine.inputHook?(self, raw, final ? .end : .move) {
            inInputHook = true
            defer { inInputHook = false }
            for (i, p) in pts.enumerated() { move(p, final: final && i == pts.count - 1) }
            return
        }
        guard let l = last else { begin(raw); return }
        let sp: CGPoint
        if raw.direct {
            sp = raw.p
            smoother.begin(raw.p)
        } else if final {
            sp = smoother.finish(raw.p, catchUp: smoothingOptions.catchUpOnEnd)
        } else {
            sp = smoother.step(raw.p, catchUp: raw.catchUp)
        }
        var cur = raw
        cur.p = sp
        let d = Double(l.p.distance(to: sp))
        if d <= 1e-6 { return }
        direction = atan2(-Double(sp.y - l.p.y), Double(sp.x - l.p.x)) * 180 / .pi
        travelled += d
        if initialDirection == nil && travelled >= 2 { initialDirection = direction }

        var pos = spacing(l.pressure) - sinceLast
        var lastPos: Double?
        while pos <= d {
            let smp = l.lerp(cur, max(0, pos) / d)
            place(smp)
            lastPos = max(0, pos)
            pos = max(0, pos) + spacing(smp.pressure)
        }
        sinceLast = lastPos.map { d - $0 } ?? sinceLast + d

        if dualBuf != nil {
            let ds = max(1, dyn.dualSize * dyn.dualSpacing)
            var dp = ds - dualSince
            var lastD: Double?
            while dp <= d {
                placeDual(l.lerp(cur, max(0, dp) / d))
                lastD = max(0, dp)
                dp = max(0, dp) + ds
            }
            dualSince = lastD.map { d - $0 } ?? dualSince + d
        }
        last = cur
    }

    /// Build-up (airbrush): deposits paint at the current position while the pen rests.
    func airbrushTick() {
        guard let l = last else { return }
        var s = l
        if let sm = smoother.tip { s.p = sm }
        place(s)
        placeDual(s)
    }

    /// Distance between dabs for the current pressure.
    private func spacing(_ pressure: Double) -> Double {
        var size = settings.size
        if settings.pressureSize {
            size *= DynamicsMath.pressureSizeFactor(pressure, settings)
        } else if dyn.shapeEnabled && dyn.sizeControl.source == .pressure {
            size *= dyn.minDiameter + (1 - dyn.minDiameter) * clamp(pressure, 0, 1)
        }
        return max(aliased ? 1 : 0.5, size * settings.spacing)
    }

    // MARK: Controls

    private func control(_ c: ControlSetting, _ s: PenSample) -> Double {
        DynamicsMath.control(c, s, dabIndex: dabIndex, direction: direction, initialDirection: initialDirection)
    }

    private func angleOffset(_ c: ControlSetting, _ s: PenSample) -> Double {
        DynamicsMath.angleOffset(c, s, dabIndex: dabIndex, direction: direction, initialDirection: initialDirection)
    }

    /// Jitter + control + minimum, Photoshop style: control scales from the minimum to 100%, jitter reduces randomly.
    private func dynamicFactor(control c: ControlSetting, jitter: Double, minimum: Double, _ s: PenSample) -> Double {
        let on = c.source != .off
        var f = on ? minimum + (1 - minimum) * control(c, s) : 1
        if jitter > 0 { f *= 1 - jitter * rng.next() }
        if on || jitter > 0 { f = max(f, minimum) }
        return f
    }

    // MARK: Dabs

    private func place(_ s0: PenSample) {
        let s = dyn.posed(s0)
        var n = 1
        if dyn.scatterEnabled {
            var c = dyn.count * control(dyn.countControl, s)
            if dyn.countJitter > 0 { c *= 1 - dyn.countJitter * rng.next() }
            n = max(1, min(16, Int(c.rounded())))
        }
        // Symmetry painting: every dab is repeated through the active symmetry transforms.
        let mirrors = BrushDynamicsEngine.symmetryPoints?(s.p) ?? []
        for _ in 0..<n {
            stamp(s)
            for m in mirrors { var ms = s; ms.p = m; stamp(ms) }
        }
        dabIndex += 1
    }

    private func stamp(_ s: PenSample) {
        let st = settings
        let d = dyn
        var size = st.size
        // The options-bar pressure button overrides the panel's size control (Photoshop): pressure drives the size
        // (down to Minimum Diameter), the jitter still applies.
        if st.pressureSize { size *= DynamicsMath.pressureSizeFactor(s.pressure, st) }
        var angle = st.angle
        var roundness = st.roundness
        var flipX = d.flipX, flipY = d.flipY
        if d.shapeEnabled {
            size *= dynamicFactor(control: st.pressureSize ? ControlSetting() : d.sizeControl, jitter: st.sizeJitter, minimum: d.minDiameter, s)
            angle += angleOffset(d.angleControl, s)
            if d.angleJitter > 0 { angle += (rng.next() * 2 - 1) * 180 * d.angleJitter }
            roundness *= dynamicFactor(control: d.roundnessControl, jitter: d.roundnessJitter, minimum: d.minRoundness, s)
            if d.flipXJitter && rng.next() < 0.5 { flipX.toggle() }
            if d.flipYJitter && rng.next() < 0.5 { flipY.toggle() }
        }
        if size < 0.2 { return }

        var pos = s.p
        if d.scatterEnabled && st.scatter > 0 {
            let amt = st.scatter * st.size * control(d.scatterControl, s)
            if d.scatterBothAxes {
                pos.x += CGFloat((rng.next() * 2 - 1) * amt)
                pos.y += CGFloat((rng.next() * 2 - 1) * amt)
            } else {
                let r = (rng.next() * 2 - 1) * amt, t = direction * .pi / 180
                pos.x += CGFloat(sin(t) * r)
                pos.y += CGFloat(cos(t) * r)
            }
        }

        // Opacity (pen pressure via the options-bar button, or the Transfer opacity control) is a ceiling the
        // stroke builds up to; flow is how much each dab deposits (Photoshop).
        var alpha = st.flow
        var ceiling = 1.0
        if st.pressureOpacity { ceiling *= DynamicsMath.pressureOpacityFactor(s.pressure, st) }
        if d.transferEnabled {
            ceiling *= dynamicFactor(control: st.pressureOpacity ? ControlSetting() : d.opacityControl, jitter: st.opacityJitter, minimum: d.minOpacity, s)
            alpha *= dynamicFactor(control: d.flowControl, jitter: d.flowJitter, minimum: d.minFlow, s)
        }
        if alpha * ceiling <= 0.001 { return }

        if let cs = customStamp {
            cs(DabInstance(center: pos, diameter: size, roundness: roundness, angle: angle, flipX: flipX, flipY: flipY, alpha: alpha * ceiling))
            return
        }

        let color = dabColor(s)
        var texture: DabRaster.Texture?
        if d.textureEnabled && d.textureEachTip, let smp = sampler {
            let depth = d.textureDepth * dynamicFactor(control: d.textureDepthControl, jitter: d.textureDepthJitter, minimum: d.textureMinDepth, s)
            texture = DabRaster.Texture(sampler: smp, mode: d.textureMode, depth: Float(depth), ox: origin.x, oy: origin.y)
        }
        var cx = Double(pos.x) - Double(origin.x), cy = Double(pos.y) - Double(origin.y)
        if aliased {
            size = max(1, size.rounded())
            if Int(size) % 2 == 0 { cx = cx.rounded(); cy = cy.rounded() } else { cx = floor(cx) + 0.5; cy = floor(cy) + 0.5 }
        }
        let dab = DabRaster.Dab(cx: cx, cy: cy, diameter: size, roundness: roundness, angle: angle,
                                flipX: flipX, flipY: flipY, hardness: st.hardness, aliased: aliased)
        let t = tip.frames.isEmpty ? tip : tip.frame(dab: dabIndex, angle: angle, pressure: s.pressure, random: rng.next())   // animated tips (GIMP image pipes)
        let r = DabRaster.stamp(dab, tip: t, into: target, color: color, alpha: Float(min(1, alpha)), texture: texture, ceiling: Float(min(1, ceiling)))
        dirty = dirty.union(r)
    }

    private func placeDual(_ s: PenSample) {
        guard let db = dualBuf, let dt = dualTip else { return }
        let d = dyn
        let size = max(1, d.dualSize)
        let n = max(1, min(16, Int(d.dualCount.rounded())))
        for _ in 0..<n {
            var p = s.p
            if d.dualScatter > 0 {
                let amt = d.dualScatter * size
                if d.dualBothAxes {
                    p.x += CGFloat((rng.next() * 2 - 1) * amt)
                    p.y += CGFloat((rng.next() * 2 - 1) * amt)
                } else {
                    let r = (rng.next() * 2 - 1) * amt, t = direction * .pi / 180
                    p.x += CGFloat(sin(t) * r)
                    p.y += CGFloat(cos(t) * r)
                }
            }
            let flip = d.dualFlip && rng.next() < 0.5
            let dab = DabRaster.Dab(cx: Double(p.x) - Double(origin.x), cy: Double(p.y) - Double(origin.y), diameter: size,
                                    roundness: 1, angle: 0, flipX: flip, hardness: d.dualHardness)
            let r = DabRaster.stamp(dab, tip: dt, into: db, alpha: 1)
            // The primary stroke under a changed dual area must be re-processed.
            dirty = dirty.union(r)
        }
    }

    // MARK: Color

    private func dabColor(_ s: PenSample) -> (Float, Float, Float) {
        var c: RGBA
        switch paint {
        case .fixed(let f):
            c = f
        case .dynamic(let fg0, let bg):
            let fg = BrushDynamicsEngine.dabColorHook?(self, fg0) ?? fg0
            if dyn.colorEnabled {
                if !dyn.colorPerTip, let sc = strokeColor { return sc }
                c = jitteredColor(fg, bg, s)
            } else {
                c = fg
            }
        }
        if grayOutput { c = RGBA(gray: c.luminance) }
        let v = (Float(clamp(c.r, 0, 1)), Float(clamp(c.g, 0, 1)), Float(clamp(c.b, 0, 1)))
        if dyn.colorEnabled && !dyn.colorPerTip { strokeColor = v }
        return v
    }

    private func jitteredColor(_ fg: RGBA, _ bg: RGBA, _ s: PenSample) -> RGBA {
        let d = dyn
        var t = d.fgBgControl.source != .off ? 1 - control(d.fgBgControl, s) : 0
        if d.fgBgJitter > 0 { t = min(1, t + d.fgBgJitter * rng.next()) }
        var c = fg.mix(bg, t)
        if d.hueJitter > 0 || d.saturationJitter > 0 || d.brightnessJitter > 0 || d.purity != 0 {
            var (h, sat, v) = c.hsb
            let k = d.colorJitterControl.source == .off ? 1 : control(d.colorJitterControl, s)
            if d.hueJitter > 0 { h += (rng.next() * 2 - 1) * 0.5 * d.hueJitter * k }
            if d.saturationJitter > 0 { sat = clamp(sat + (rng.next() * 2 - 1) * d.saturationJitter * k, 0, 1) }
            if d.brightnessJitter > 0 { v = clamp(v + (rng.next() * 2 - 1) * d.brightnessJitter * k, 0, 1) }
            if d.purity > 0 { sat += (1 - sat) * d.purity } else if d.purity < 0 { sat *= 1 + d.purity }
            c = RGBA(h: h, s: clamp(sat, 0, 1), v: v, a: 1)
        }
        return c
    }

    // MARK: Stroke-level pass

    private var wetRadius: Int { Int(clamp(settings.size * 0.1, 1, 40).rounded()) }

    /// Applies dual brush, stroke texture, wet edges and noise to `source` (the raw stroke) inside `r`,
    /// writing premultiplied RGBA into `out`. Returns the rect that was written (may be larger than `r`).
    func postProcess(_ r: IRect, source: PixelBuffer, out: PixelBuffer) -> IRect {
        let d = dyn
        let wet = d.wetEdges
        let R = wet ? wetRadius : 0
        let o = r.insetBy(-R).intersection(source.bounds)
        if o.isEmpty { return o }
        let ow = o.width, oh = o.height
        let W = source.width, H = source.height
        let sbpr = source.bytesPerRow, obpr = out.bytesPerRow
        let src = source.data.assumingMemoryBound(to: UInt8.self)
        let dst = out.data.assumingMemoryBound(to: UInt8.self)

        // Box blur of the stroke alpha (for wet edges): column prefix sums over horizontally summed rows.
        let ih = oh + 2 * R
        if wet {
            let xs = max(0, o.x - R), xe = min(W, o.maxX + R)
            if prefixRow.count < xe - xs + 1 { prefixRow = [Int32](repeating: 0, count: xe - xs + 1) }
            if colPrefix.count < (ih + 1) * ow { colPrefix = [Int32](repeating: 0, count: (ih + 1) * ow) }
            prefixRow.withUnsafeMutableBufferPointer { P in
                colPrefix.withUnsafeMutableBufferPointer { C in
                    for i in 0..<ow { C[i] = 0 }
                    for j in 0..<ih {
                        let y = o.y - R + j
                        let prev = j * ow, cur = (j + 1) * ow
                        if y < 0 || y >= H {
                            for i in 0..<ow { C[cur + i] = C[prev + i] }
                            continue
                        }
                        let row = src + y * sbpr
                        P[0] = 0
                        var acc: Int32 = 0
                        for x in xs..<xe { acc += Int32(row[x * 4 + 3]); P[x - xs + 1] = acc }
                        for i in 0..<ow {
                            let x = o.x + i
                            let lo = max(xs, x - R), hi = min(xe, x + R + 1)
                            C[cur + i] = C[prev + i] + P[hi - xs] - P[lo - xs]
                        }
                    }
                }
            }
        }
        let blurDiv = Float((2 * R + 1) * (2 * R + 1) * 255)
        let dual = d.dualEnabled ? dualBuf : nil
        let dualPx = dual?.data.assumingMemoryBound(to: UInt8.self)
        let dbpr = dual?.bytesPerRow ?? 0
        let strokeTex = d.textureEnabled && !d.textureEachTip ? sampler : nil
        let depth = Float(d.textureDepth)
        let noise = d.noise
        let ox = origin.x, oy = origin.y

        colPrefix.withUnsafeBufferPointer { C in
            for yy in 0..<oh {
                let y = o.y + yy
                let srow = src + y * sbpr, drow = dst + y * obpr
                for i in 0..<ow {
                    let x = o.x + i
                    let si = x * 4
                    let a = srow[si + 3]
                    if a == 0 {
                        drow[si] = 0; drow[si + 1] = 0; drow[si + 2] = 0; drow[si + 3] = 0
                        continue
                    }
                    var m = Float(a) / 255
                    if noise {   // grain on the soft parts of the raw stroke only
                        let amp = min(m, 1 - m)
                        m = BrushMaskMath.clamp01(m + (BrushMaskMath.noise(x + ox, y + oy) * 2 - 1) * amp)
                    }
                    if let dp = dualPx { m = BrushMaskMath.combine(m, Float(dp[y * dbpr + x]) / 255, d.dualMode) }
                    if let t = strokeTex { m = BrushMaskMath.texture(m, t.value(x + ox, y + oy), depth, d.textureMode) }
                    if wet {
                        let sum = C[(yy + 2 * R + 1) * ow + i] - C[yy * ow + i]
                        let b = Float(sum) / blurDiv
                        m *= 0.4 + 0.6 * min(1, 2 * max(0, 1 - b))
                    }
                    let na = m * 255
                    if na < 0.5 {
                        drow[si] = 0; drow[si + 1] = 0; drow[si + 2] = 0; drow[si + 3] = 0
                        continue
                    }
                    let k = na / Float(a)
                    drow[si] = UInt8(min(na, Float(srow[si]) * k) + 0.5)
                    drow[si + 1] = UInt8(min(na, Float(srow[si + 1]) * k) + 0.5)
                    drow[si + 2] = UInt8(min(na, Float(srow[si + 2]) * k) + 0.5)
                    drow[si + 3] = UInt8(min(255, na + 0.5))
                }
            }
        }
        out.markDirty()
        return o
    }
}


// MARK: - Shared dynamics math (the engine and the dab-placer tools: clone, healing, retouch, mixer, …)

enum DynamicsMath {
    /// 0…1 for an angle over a full turn.
    static func turn(_ deg: Double) -> Double {
        var r = deg.truncatingRemainder(dividingBy: 360)
        if r < 0 { r += 360 }
        return r / 360
    }

    /// Value (0…1) of a Control for a sample. Mouse samples have no tilt, rotation or wheel: those read as full.
    static func control(_ c: ControlSetting, _ s: PenSample, dabIndex: Int, direction: Double, initialDirection: Double?) -> Double {
        switch c.source {
        case .off: return 1
        case .fade: return max(0, 1 - Double(dabIndex) / max(1, c.fadeSteps))
        case .pressure: return clamp(s.pressure, 0, 1)
        case .tilt: return s.mouse ? 1 : 1 - s.tiltMagnitude
        case .wheel: return s.mouse ? 1 : clamp(s.wheel, 0, 1)
        case .rotation: return s.mouse ? 1 : turn(s.rotation)
        case .direction: return turn(direction)
        case .initialDirection: return turn(initialDirection ?? direction)
        }
    }

    /// Angle added (degrees) by an angle Control.
    static func angleOffset(_ c: ControlSetting, _ s: PenSample, dabIndex: Int, direction: Double, initialDirection: Double?) -> Double {
        switch c.source {
        case .off: return 0
        case .fade: return 360 * min(1, Double(dabIndex) / max(1, c.fadeSteps))
        case .pressure: return 360 * clamp(s.pressure, 0, 1)
        case .tilt: return s.mouse ? 0 : s.tiltAngle
        case .wheel: return s.mouse ? 0 : 360 * clamp(s.wheel, 0, 1)
        case .rotation: return s.mouse ? 0 : s.rotation
        case .direction: return direction
        case .initialDirection: return initialDirection ?? direction
        }
    }

    /// Size factor of the options-bar "pressure controls size" button: from Minimum Diameter (when Shape Dynamics
    /// is on; else a 5% floor) to 100%.
    static func pressureSizeFactor(_ pressure: Double, _ st: BrushSettings) -> Double {
        let p = clamp(pressure, 0, 1)
        if st.dynamics.shapeEnabled { return st.dynamics.minDiameter + (1 - st.dynamics.minDiameter) * p }
        return max(0.05, p)
    }

    static func pressureOpacityFactor(_ pressure: Double, _ st: BrushSettings) -> Double {
        let p = clamp(pressure, 0, 1)
        if st.dynamics.transferEnabled { return st.dynamics.minOpacity + (1 - st.dynamics.minOpacity) * p }
        return p
    }
}

/// Brush dynamics for tools that place dabs themselves (clone, healing, retouch, mixer, selection brush, …): size,
/// angle, roundness and opacity from pressure / tilt / rotation / wheel / direction, like the brush engine.
struct DabDynamics {
    struct Dab { var size: Double; var angle: Double; var roundness: Double; var alpha: Double }

    private var rng = SeededRandom(seed: 0x7AB1E7)
    private(set) var dabIndex = 0
    private var last: CGPoint?
    private var travelled: Double = 0
    private(set) var direction: Double = 0
    private(set) var initialDirection: Double?

    init() {}

    /// The dab for a sample (call once per placed dab, in order).
    mutating func dab(_ s: PenSample, _ st: BrushSettings) -> Dab {
        if let l = last {
            let d = Double(l.distance(to: s.p))
            if d > 1e-6 {
                direction = atan2(-Double(s.p.y - l.y), Double(s.p.x - l.x)) * 180 / .pi
                travelled += d
                if initialDirection == nil && travelled >= 2 { initialDirection = direction }
            }
        }
        last = s.p
        let d = st.dynamics
        func ctl(_ c: ControlSetting) -> Double { DynamicsMath.control(c, s, dabIndex: dabIndex, direction: direction, initialDirection: initialDirection) }
        func factor(_ c: ControlSetting, _ jitter: Double, _ minimum: Double) -> Double {
            let on = c.source != .off
            var f = on ? minimum + (1 - minimum) * ctl(c) : 1
            if jitter > 0 { f *= 1 - jitter * rng.next() }
            if on || jitter > 0 { f = max(f, minimum) }
            return f
        }
        var size = st.size
        if st.pressureSize { size *= DynamicsMath.pressureSizeFactor(s.pressure, st) }
        var angle = st.angle, roundness = st.roundness
        if d.shapeEnabled {
            size *= factor(st.pressureSize ? ControlSetting() : d.sizeControl, st.sizeJitter, d.minDiameter)
            angle += DynamicsMath.angleOffset(d.angleControl, s, dabIndex: dabIndex, direction: direction, initialDirection: initialDirection)
            if d.angleJitter > 0 { angle += (rng.next() * 2 - 1) * 180 * d.angleJitter }
            roundness *= factor(d.roundnessControl, d.roundnessJitter, d.minRoundness)
        }
        var alpha = 1.0
        if st.pressureOpacity { alpha *= DynamicsMath.pressureOpacityFactor(s.pressure, st) }
        if d.transferEnabled {
            alpha *= factor(st.pressureOpacity ? ControlSetting() : d.opacityControl, st.opacityJitter, d.minOpacity)
            alpha *= factor(d.flowControl, d.flowJitter, d.minFlow)
        }
        dabIndex += 1
        return Dab(size: max(0.5, size), angle: angle, roundness: max(0.02, roundness), alpha: alpha)
    }
}
