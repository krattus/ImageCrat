import Foundation
import Metal
import CoreImage
import CoreGraphics
import ImageCratCore

/// One rendered blend run: premultiplied RGBA8 on transparent, ready to become a layer.
struct PRenderedRun {
    let texture: MTLTexture
    let blend: PBlend
    let name: String
}

/// Instanced sprite renderer (Metal): every particle is one quad drawn from a texture array, accumulated in a
/// 16-bit float MSAA target (so additive light can exceed 1 before it is clipped) and resolved to RGBA8.
enum ParticleRenderer {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Inst { float2 pos; float2 half_; float2 rot; float2 tex; float4 color; };
    struct Uni { float2 viewport; float2 pad; };
    struct VOut {
        float4 position [[position]];
        float2 uv;
        float4 color;
        float layer [[flat]];
        float lod [[flat]];
    };

    vertex VOut particle_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                const device Inst *inst [[buffer(0)]], constant Uni &u [[buffer(1)]]) {
        const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        Inst p = inst[iid];
        float2 c = corners[vid];
        float2 local = c * p.half_;
        float2 ay = float2(-p.rot.y, p.rot.x);
        float2 world = p.pos + p.rot * local.x + ay * local.y;
        VOut o;
        o.position = float4(world.x / u.viewport.x * 2.0 - 1.0, 1.0 - world.y / u.viewport.y * 2.0, 0.0, 1.0);
        o.uv = c * 0.5 + 0.5;
        o.color = p.color;
        o.layer = p.tex.x;
        o.lod = p.tex.y;
        return o;
    }

    fragment float4 particle_fragment(VOut in [[stage_in]], texture2d_array<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        float4 t = tex.sample(s, in.uv, uint(in.layer + 0.5), bias(in.lod));
        return float4(t.rgb * in.color.rgb, t.a * in.color.a);
    }

    struct FOut { float4 position [[position]]; float2 uv; };
    struct FUni { int mode; int pad0; int pad1; int pad2; };

    vertex FOut finish_vertex(uint vid [[vertex_id]]) {
        const float2 pts[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        FOut o;
        o.position = float4(pts[vid], 0, 1);
        o.uv = float2(pts[vid].x * 0.5 + 0.5, 0.5 - pts[vid].y * 0.5);
        return o;
    }

    fragment float4 finish_fragment(FOut in [[stage_in]], texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]], constant FUni &u [[buffer(0)]]) {
        float4 c = src.sample(s, in.uv);
        if (u.mode == 1) {
            float3 rgb = clamp(c.rgb, 0.0, 1.0);
            float a = max(rgb.r, max(rgb.g, rgb.b));
            return float4(rgb, a);
        }
        float a = clamp(c.a, 0.0, 1.0);
        return float4(clamp(c.rgb, 0.0, a), a);
    }
    """

    private static let library: MTLLibrary? = {
        do { return try RenderEngine.device.makeLibrary(source: shaderSource, options: nil) } catch {
            NSLog("ImageCrat particles: shader compile failed: \\(error)")
            return nil
        }
    }()

    private static var pipelines: [String: MTLRenderPipelineState] = [:]
    private static let lock = NSLock()

    private static func pipeline(additive: Bool, samples: Int) -> MTLRenderPipelineState? {
        let key = "\(additive)-\(samples)"
        lock.lock(); defer { lock.unlock() }
        if let p = pipelines[key] { return p }
        guard let lib = library else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "particle_vertex")
        d.fragmentFunction = lib.makeFunction(name: "particle_fragment")
        d.rasterSampleCount = samples
        let a = d.colorAttachments[0]!
        a.pixelFormat = .rgba16Float
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        guard let p = try? RenderEngine.device.makeRenderPipelineState(descriptor: d) else { return nil }
        pipelines[key] = p
        return p
    }

    private static let finishPipeline: MTLRenderPipelineState? = {
        guard let lib = library else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "finish_vertex")
        d.fragmentFunction = lib.makeFunction(name: "finish_fragment")
        d.colorAttachments[0].pixelFormat = .rgba8Unorm
        return try? RenderEngine.device.makeRenderPipelineState(descriptor: d)
    }()

    private static let sampler: MTLSamplerState? = {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear; d.magFilter = .linear; d.mipFilter = .linear
        d.sAddressMode = .clampToEdge; d.tAddressMode = .clampToEdge
        d.maxAnisotropy = 4
        return RenderEngine.device.makeSamplerState(descriptor: d)
    }()

    // Reusable float targets (checked out while a render is in flight).
    private static var targetPool: [String: [(MTLTexture, MTLTexture?)]] = [:]

    private static func takeTargets(_ w: Int, _ h: Int, samples: Int) -> (MTLTexture, MTLTexture?)? {
        let key = "\(w)x\(h)x\(samples)"
        lock.lock()
        if var list = targetPool[key], let t = list.popLast() { targetPool[key] = list; lock.unlock(); return t }
        lock.unlock()
        let dev = RenderEngine.device
        let rd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        rd.usage = [.renderTarget, .shaderRead]
        rd.storageMode = .private
        guard let resolve = dev.makeTexture(descriptor: rd) else { return nil }
        if samples <= 1 { return (resolve, nil) }
        let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        md.textureType = .type2DMultisample
        md.sampleCount = samples
        md.usage = [.renderTarget]
        md.storageMode = .private
        guard let ms = dev.makeTexture(descriptor: md) else { return (resolve, nil) }
        return (resolve, ms)
    }

    /// Frees the pooled float / MSAA targets (up to hundreds of MB each at final quality) once no editor needs them.
    static func releaseTargets() {
        lock.lock(); targetPool.removeAll(); lock.unlock()
    }

    static var pooledTargets: Int { lock.lock(); defer { lock.unlock() }; return targetPool.values.reduce(0) { $0 + $1.count } }

    private static func returnTargets(_ t: (MTLTexture, MTLTexture?), samples: Int) {
        let key = "\(t.0.width)x\(t.0.height)x\(t.1 == nil ? 1 : samples)"
        lock.lock()
        var list = targetPool[key] ?? []
        if list.count < 2 { list.append(t) }
        targetPool[key] = list
        if targetPool.count > 6 { targetPool = [key: list] }
        lock.unlock()
    }

    /// Picks the internal supersampling factor and MSAA sample count for an output size.
    static func sampling(width: Int, height: Int, quality: PQuality, preview: Bool) -> (ss: Int, msaa: Int) {
        if preview { return (1, 1) }
        var ss = quality == .best ? 2 : 1
        if width * ss > 16384 || height * ss > 16384 || width * height * ss * ss > 48_000_000 { ss = 1 }
        let msaa = width * height * ss * ss <= 40_000_000 ? 4 : 1
        return (ss, msaa)
    }

    /// Renders blend runs to RGBA8 textures of `width` × `height` (instances are in output pixels).
    static func render(_ runs: [PRun], width: Int, height: Int, atlas: ParticleSpriteAtlas, ss: Int = 1, msaa: Int = 4) -> [PRenderedRun] {
        let dev = RenderEngine.device
        guard width > 0, height > 0, width <= 16384, height <= 16384, let finish = finishPipeline, let samp = sampler else { return [] }
        let iw = width * ss, ih = height * ss
        let samples = dev.supportsTextureSampleCount(msaa) ? msaa : 1
        guard let targets = takeTargets(iw, ih, samples: samples) else { return [] }
        let usedSamples = targets.1 == nil ? 1 : samples
        defer { returnTargets(targets, samples: usedSamples) }
        var out: [PRenderedRun] = []
        for run in runs {
            let additive = run.blend == .additive
            guard let pipe = pipeline(additive: additive, samples: usedSamples),
                  let cb = RenderEngine.commandQueue.makeCommandBuffer() else { continue }
            let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            od.usage = [.renderTarget, .shaderRead]
            od.storageMode = .shared
            guard let dst = dev.makeTexture(descriptor: od) else { continue }

            let pass = MTLRenderPassDescriptor()
            let att = pass.colorAttachments[0]!
            att.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            att.loadAction = .clear
            if let ms = targets.1 {
                att.texture = ms
                att.resolveTexture = targets.0
                att.storeAction = .multisampleResolve
            } else {
                att.texture = targets.0
                att.storeAction = .store
            }
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { continue }
            let count = run.instances.count
            if count > 0 {
                let len = count * MemoryLayout<PInstance>.stride
                let buf: MTLBuffer? = run.instances.withUnsafeBytes { raw in dev.makeBuffer(bytes: raw.baseAddress!, length: len, options: .storageModeShared) }
                if let buf {
                    var uni: (Float, Float, Float, Float) = (Float(width), Float(height), 0, 0)
                    enc.setRenderPipelineState(pipe)
                    enc.setVertexBuffer(buf, offset: 0, index: 0)
                    enc.setVertexBytes(&uni, length: 16, index: 1)
                    enc.setFragmentTexture(atlas.texture, index: 0)
                    enc.setFragmentSamplerState(samp, index: 0)
                    // very large instance counts are split so a single draw never exceeds driver limits
                    var start = 0
                    while start < count {
                        let n = min(1_000_000, count - start)
                        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n, baseInstance: start)
                        start += n
                    }
                }
            }
            enc.endEncoding()

            let fp = MTLRenderPassDescriptor()
            fp.colorAttachments[0].texture = dst
            fp.colorAttachments[0].loadAction = .dontCare
            fp.colorAttachments[0].storeAction = .store
            if let fe = cb.makeRenderCommandEncoder(descriptor: fp) {
                var fu: (Int32, Int32, Int32, Int32) = (additive ? 1 : 0, 0, 0, 0)
                fe.setRenderPipelineState(finish)
                fe.setFragmentTexture(targets.0, index: 0)
                fe.setFragmentSamplerState(samp, index: 0)
                fe.setFragmentBytes(&fu, length: 16, index: 0)
                fe.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                fe.endEncoding()
            }
            cb.commit()
            cb.waitUntilCompleted()
            out.append(PRenderedRun(texture: dst, blend: run.blend, name: run.name))
        }
        return out
    }

    /// Copies a rendered run into a canvas-size pixel buffer.
    static func pixelBuffer(_ tex: MTLTexture) -> PixelBuffer {
        let b = PixelBuffer(width: tex.width, height: tex.height)
        tex.getBytes(b.data, bytesPerRow: b.bytesPerRow, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
        b.markDirty()
        return b
    }

    /// CI image of a rendered run scaled to the canvas (CI space, y up).
    static func ciImage(_ tex: MTLTexture, canvasWidth: Int, canvasHeight: Int) -> CIImage {
        guard var img = CIImage(mtlTexture: tex, options: [.colorSpace: sRGBSpace]) else { return CIImage.clearImage }
        img = img.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(tex.height)))
        if tex.width != canvasWidth || tex.height != canvasHeight {
            img = img.transformed(by: CGAffineTransform(scaleX: CGFloat(canvasWidth) / CGFloat(tex.width), y: CGFloat(canvasHeight) / CGFloat(tex.height)))
        }
        return img
    }
}

/// Simulation + rendering in one call.
enum ParticleEngine {
    struct Output {
        var runs: [PRenderedRun] = []
        var particles = 0
        var instances = 0
        var simSeconds = 0.0
        var renderSeconds = 0.0
        var width = 0, height = 0
    }

    /// Renders the effect at time `time` (default: the effect's frozen moment) into textures of canvas size × `scale`.
    static func render(_ effect: ParticleEffect, ctx: ParticleContext, time: Double? = nil, scale: Double = 1, preview: Bool = false) -> Output {
        var out = Output()
        guard let atlas = ParticleSpriteAtlas.atlas(for: effect.systems) else { return out }
        let w = max(1, Int((Double(ctx.width) * scale).rounded())), h = max(1, Int((Double(ctx.height) * scale).rounded()))
        let sim = ParticleSystem.simulate(effect, ctx: ctx, atlas: atlas, time: time, scale: Double(w) / Double(ctx.width))
        let t0 = CFAbsoluteTimeGetCurrent()
        let smp = ParticleRenderer.sampling(width: w, height: h, quality: effect.quality, preview: preview)
        out.runs = ParticleRenderer.render(sim.runs, width: w, height: h, atlas: atlas, ss: smp.ss, msaa: smp.msaa)
        out.particles = sim.particles
        out.instances = sim.instances
        out.simSeconds = sim.seconds
        out.renderSeconds = CFAbsoluteTimeGetCurrent() - t0
        out.width = w; out.height = h
        return out
    }

    /// Layer blend mode for a run (the effect's override applies to light runs).
    static func layerMode(_ run: PBlend, effect: ParticleEffect) -> BlendMode {
        if let m = effect.layerBlend, run != .multiply { return m }
        return run.layerMode
    }

    /// Composites rendered runs over a backdrop exactly like the layers they become.
    static func composite(_ o: Output, over backdrop: CIImage, effect: ParticleEffect, ctx: ParticleContext, mask: CIImage? = nil) -> CIImage {
        var acc = backdrop
        let canvas = CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)
        for r in o.runs {
            var img = ParticleRenderer.ciImage(r.texture, canvasWidth: ctx.width, canvasHeight: ctx.height).cropped(to: canvas)
            if let m = mask { img = img.masked(byGray: m) }
            acc = img.blended(over: acc, mode: layerMode(r.blend, effect: effect))
        }
        return acc
    }

    /// Flattened CGImage of the effect over a background colour (thumbnails, tests, PNG sequences).
    static func image(_ effect: ParticleEffect, ctx: ParticleContext, time: Double? = nil, background: CIImage? = nil, scale: Double = 1, mask: CIImage? = nil) -> CGImage? {
        let o = render(effect, ctx: ctx, time: time, scale: scale)
        let canvas = CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)
        let bg = background ?? CIImage.clearImage.cropped(to: canvas)
        let img = composite(o, over: bg, effect: effect, ctx: ctx, mask: mask)
        return RenderEngine.cgImage(img, rect: canvas)
    }
}
