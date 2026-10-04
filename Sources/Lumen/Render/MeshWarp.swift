import Foundation
import CoreGraphics
import CoreImage
import Metal
import ImageCratCore

// MARK: - GPU mesh warp

enum MeshWarp {
    /// Hard texture size limit.
    static let maxTextureSide = 16384

    private struct Vertex {
        var pos: SIMD2<Float>
        var uv: SIMD2<Float>
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct MeshVertex { float2 pos; float2 uv; };
    struct MeshVOut { float4 position [[position]]; float2 uv; };
    vertex MeshVOut lumen_mesh_vs(uint vid [[vertex_id]], const device MeshVertex* verts [[buffer(0)]]) {
        MeshVOut o;
        o.position = float4(verts[vid].pos, 0.0, 1.0);
        o.uv = verts[vid].uv;
        return o;
    }
    fragment float4 lumen_mesh_fs(MeshVOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(address::clamp_to_zero, filter::linear, coord::normalized);
        return tex.sample(s, in.uv);
    }
    """

    private static let pixelFormat: MTLPixelFormat = .rgba16Float

    private struct Pipelines {
        let msaa: MTLRenderPipelineState?
        let single: MTLRenderPipelineState?
    }

    private static let pipelines: Pipelines = {
        let device = RenderEngine.device
        func make(_ samples: Int) -> MTLRenderPipelineState? {
            do {
                let lib = try device.makeLibrary(source: shaderSource, options: nil)
                let d = MTLRenderPipelineDescriptor()
                d.label = "Lumen.MeshWarp"
                d.vertexFunction = lib.makeFunction(name: "lumen_mesh_vs")
                d.fragmentFunction = lib.makeFunction(name: "lumen_mesh_fs")
                d.rasterSampleCount = samples
                let ca = d.colorAttachments[0]!
                ca.pixelFormat = pixelFormat
                // Premultiplied source-over, so folded meshes composite sensibly.
                ca.isBlendingEnabled = true
                ca.rgbBlendOperation = .add
                ca.alphaBlendOperation = .add
                ca.sourceRGBBlendFactor = .one
                ca.sourceAlphaBlendFactor = .one
                ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: d)
            } catch {
                NSLog("MeshWarp pipeline error: \(error)")
                return nil
            }
        }
        let msaaOK = device.supportsTextureSampleCount(4)
        return Pipelines(msaa: msaaOK ? make(4) : nil, single: make(1))
    }()

    private static let lock = NSLock()

    /// Renders `image` (a CI-space image) textured over a mesh: the source mesh `from` (doc coords, describing
    /// where texture pixels are) is mapped onto `to` (same topology). Returns a CI-space image placed in the
    /// document (for `space`), transparent outside the warped mesh.
    static func warp(_ image: CIImage, from: MeshGrid, to: MeshGrid, space: CanvasSpace) -> CIImage {
        guard from.isValid, to.isValid, from.cols == to.cols, from.rows == to.rows else { return CIImage.empty() }
        lock.lock(); defer { lock.unlock() }

        let device = RenderEngine.device
        let W = max(1, space.width), H = max(1, space.height)

        // --- Destination rect (doc coords, integer), clamped to 3× canvas and the texture limit.
        let toB = to.bounds
        guard !toB.isNull, toB.width.isFinite, toB.height.isFinite else { return CIImage.empty() }
        var dst = IRect(enclosing: toB.insetBy(dx: -1, dy: -1))
        dst = dst.intersection(IRect(x: -W, y: -H, width: 3 * W, height: 3 * H))
        if dst.width > maxTextureSide { dst.width = maxTextureSide }
        if dst.height > maxTextureSide { dst.height = maxTextureSide }
        guard !dst.isEmpty else { return CIImage.empty() }

        // --- Source rect: bbox of `from` (plus a margin for bilinear taps), limited to the image extent.
        let fromB = from.bounds
        guard !fromB.isNull, fromB.width.isFinite, fromB.height.isFinite else { return CIImage.empty() }
        var src = IRect(enclosing: fromB.insetBy(dx: -2, dy: -2))
        let ext = image.extent
        if !ext.isInfinite {
            if ext.isEmpty { return CIImage.empty() }
            src = src.intersection(IRect(enclosing: space.docRect(ext)))
        }
        guard !src.isEmpty else { return CIImage.empty() }
        let srcScale = min(1.0, Double(maxTextureSide) / Double(max(src.width, src.height)))
        let tw = max(1, min(maxTextureSide, Int(ceil(Double(src.width) * srcScale))))
        let th = max(1, min(maxTextureSide, Int(ceil(Double(src.height) * srcScale))))

        // --- Textures
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: tw, height: th, mipmapped: false)
        sd.usage = [.shaderRead, .shaderWrite, .renderTarget]
        sd.storageMode = .private
        guard let srcTex = device.makeTexture(descriptor: sd) else { return CIImage.empty() }

        let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: dst.width, height: dst.height, mipmapped: false)
        od.usage = [.shaderRead, .renderTarget]
        od.storageMode = .private
        guard let outTex = device.makeTexture(descriptor: od) else { return CIImage.empty() }

        var msaaTex: MTLTexture?
        if pipelines.msaa != nil {
            let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: dst.width, height: dst.height, mipmapped: false)
            md.textureType = .type2DMultisample
            md.sampleCount = 4
            md.usage = [.renderTarget]
            let apple = device.supportsFamily(.apple2)
            let bytes = dst.width * dst.height * 8 * 4
            if apple {
                md.storageMode = .memoryless
                msaaTex = device.makeTexture(descriptor: md)
            } else if bytes <= 1 << 30 {
                md.storageMode = .private
                msaaTex = device.makeTexture(descriptor: md)
            }
        }
        guard let pipeline = (msaaTex != nil ? pipelines.msaa : pipelines.single) else { return CIImage.empty() }

        guard let cb = RenderEngine.commandQueue.makeCommandBuffer() else { return CIImage.empty() }
        cb.label = "Lumen.MeshWarp"

        // --- Render the source region into srcTex. CI space: region `srcCI`, scaled to (tw, th).
        let srcCI = space.ciRect(src)
        let sx = CGFloat(tw) / CGFloat(src.width), sy = CGFloat(th) / CGFloat(src.height)
        let texRect = CGRect(x: 0, y: 0, width: tw, height: th)
        var placed = image.transformed(by: CGAffineTransform(translationX: -srcCI.minX, y: -srcCI.minY))
        if sx != 1 || sy != 1 { placed = placed.transformed(by: CGAffineTransform(scaleX: sx, y: sy)) }
        placed = placed.cropped(to: texRect).composited(over: CIImage.clearImage.cropped(to: texRect))
        RenderEngine.context.render(placed, to: srcTex, commandBuffer: cb, bounds: texRect, colorSpace: sRGBSpace)

        // --- Geometry. Output texture row 0 = doc y `dst.y`; Metal NDC +y = row 0.
        // CI's render-to-texture writes CI y = 0 (the bottom of `bounds`, i.e. doc y = src.maxY) to texture
        // row 0, so texture v runs opposite to doc y. (Verified by probing Core Image on macOS 15+.)
        let n = to.positions.count
        var verts = [Vertex](repeating: Vertex(pos: .zero, uv: .zero), count: n)
        let dw = Double(dst.width), dh = Double(dst.height)
        let swd = Double(src.width), shd = Double(src.height)
        for i in 0..<n {
            let p = to.positions[i], q = from.positions[i]
            let nx = (Double(p.x) - Double(dst.x)) / dw * 2 - 1
            let ny = 1 - (Double(p.y) - Double(dst.y)) / dh * 2
            let u = (Double(q.x) - Double(src.x)) / swd
            let v = 1 - (Double(q.y) - Double(src.y)) / shd
            verts[i] = Vertex(pos: SIMD2(Float(nx), Float(ny)), uv: SIMD2(Float(u), Float(v)))
        }
        var indices: [UInt32] = []
        indices.reserveCapacity((to.cols - 1) * (to.rows - 1) * 6)
        for r in 0..<(to.rows - 1) {
            for c in 0..<(to.cols - 1) {
                let a = UInt32(r * to.cols + c), b = a + 1
                let d = UInt32((r + 1) * to.cols + c), e = d + 1
                indices.append(contentsOf: [a, b, d, b, e, d])
            }
        }
        guard let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<Vertex>.stride * n, options: .storageModeShared),
              let ibuf = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt32>.stride * indices.count, options: .storageModeShared)
        else { return CIImage.empty() }

        // --- Draw
        let rp = MTLRenderPassDescriptor()
        let att = rp.colorAttachments[0]!
        att.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        att.loadAction = .clear
        if let ms = msaaTex {
            att.texture = ms
            att.resolveTexture = outTex
            att.storeAction = .multisampleResolve
        } else {
            att.texture = outTex
            att.storeAction = .store
        }
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return CIImage.empty() }
        enc.setRenderPipelineState(pipeline)
        enc.setCullMode(.none)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setFragmentTexture(srcTex, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: indices.count, indexType: .uint32, indexBuffer: ibuf, indexBufferOffset: 0)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if cb.status == .error { return CIImage.empty() }

        // --- Wrap: CIImage(mtlTexture:) treats row 0 as CI y = 0 (bottom), but our row 0 is the doc top → flip.
        guard let out = CIImage(mtlTexture: outTex, options: [.colorSpace: sRGBSpace]) else { return CIImage.empty() }
        let flipped = out.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(dst.height)))
        let ciDst = space.ciRect(dst)
        return flipped.transformed(by: CGAffineTransform(translationX: ciDst.minX, y: ciDst.minY))
    }
}
