import Foundation
import Metal
import ImageCratCore

/// Runtime-compiled Metal compute kernels used by the Imaging module (palette mapping, stack statistics).
enum ImagingMetal {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct PalParams {
        uint width; uint height; uint rowPixels; uint count;
        int mode; float spread; int transparentIndex; int preserveExact;
        float4 matte;
        uint seed; uint pad0; uint pad1; uint pad2;
    };

    static float lumenBayer8(uint x, uint y) {
        uint v = 0;
        for (uint i = 0; i < 3; i++) {
            uint xb = (x >> i) & 1u, yb = (y >> i) & 1u;
            v += (2u * (xb ^ yb) + yb) << (2u * (2u - i));
        }
        return (float(v) + 0.5) / 64.0;
    }

    static float lumenHash(uint x, uint y, uint s) {
        uint h = x * 374761393u + y * 668265263u + s * 2246822519u;
        h = (h ^ (h >> 13)) * 1274126177u;
        h = h ^ (h >> 16);
        return float(h & 0xffffffu) / 16777216.0;
    }

    kernel void lumenMapPalette(device const uchar4* src [[buffer(0)]], device uchar* dst [[buffer(1)]],
                                constant float4* pal [[buffer(2)]], constant PalParams& p [[buffer(3)]],
                                uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        uchar4 c = src[gid.y * p.rowPixels + gid.x];
        uint o = gid.y * p.width + gid.x;
        if (p.transparentIndex >= 0 && c.a < 128) { dst[o] = uchar(p.transparentIndex); return; }
        float a = float(c.a) / 255.0;
        float3 col = a > 0.0 ? (float3(c.rgb) / 255.0) / a : float3(0.0);
        col = clamp(col, 0.0, 1.0) * a + p.matte.rgb * (1.0 - a);
        col *= 255.0;
        int best = 0; float bd = 1e20;
        for (uint i = 0; i < p.count; i++) {
            if (int(i) == p.transparentIndex) continue;
            float3 d = col - pal[i].rgb;
            float dd = dot(d, d);
            if (dd < bd) { bd = dd; best = int(i); }
        }
        bool exact = bd < 0.75;
        if (p.mode != 0 && !(exact && p.preserveExact != 0)) {
            float t = p.mode == 1 ? lumenBayer8(gid.x & 7u, gid.y & 7u) : lumenHash(gid.x, gid.y, p.seed);
            float3 q = clamp(col + (t - 0.5) * p.spread, 0.0, 255.0);
            bd = 1e20;
            for (uint i = 0; i < p.count; i++) {
                if (int(i) == p.transparentIndex) continue;
                float3 d = q - pal[i].rgb;
                float dd = dot(d, d);
                if (dd < bd) { bd = dd; best = int(i); }
            }
        }
        dst[o] = uchar(best);
    }

    struct StackParams { uint width; uint height; uint count; int mode; };

    kernel void lumenStackStats(device const uchar4* src [[buffer(0)]], device uchar4* dst [[buffer(1)]],
                                constant StackParams& p [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        uint idx = gid.y * p.width + gid.x;
        uint plane = p.width * p.height;
        float v0[64]; float v1[64]; float v2[64];
        int n = 0; float amax = 0.0;
        for (uint i = 0; i < p.count && n < 64; i++) {
            uchar4 c = src[i * plane + idx];
            if (c.a == 0) continue;
            float a = float(c.a) / 255.0;
            amax = max(amax, a);
            v0[n] = min(1.0, float(c.r) / 255.0 / a);
            v1[n] = min(1.0, float(c.g) / 255.0 / a);
            v2[n] = min(1.0, float(c.b) / 255.0 / a);
            n++;
        }
        if (n == 0) { dst[idx] = uchar4(0); return; }
        float outv[3];
        for (int ch = 0; ch < 3; ch++) {
            float v[64];
            for (int k = 0; k < n; k++) { v[k] = ch == 0 ? v0[k] : (ch == 1 ? v1[k] : v2[k]); }
            float r = 0.0;
            float mean = 0.0;
            for (int k = 0; k < n; k++) { mean += v[k]; }
            float sum = mean;
            mean /= float(n);
            float m2 = 0.0, m3 = 0.0, m4 = 0.0, mn = 1.0, mx = 0.0;
            for (int k = 0; k < n; k++) {
                float d = v[k] - mean;
                m2 += d * d; m3 += d * d * d; m4 += d * d * d * d;
                mn = min(mn, v[k]); mx = max(mx, v[k]);
            }
            m2 /= float(n); m3 /= float(n); m4 /= float(n);
            switch (p.mode) {
            case 0: r = mean; break;
            case 1: {
                for (int a = 1; a < n; a++) { float key = v[a]; int b = a - 1; while (b >= 0 && v[b] > key) { v[b + 1] = v[b]; b--; } v[b + 1] = key; }
                r = (n & 1) ? v[n / 2] : 0.5 * (v[n / 2 - 1] + v[n / 2]);
                break;
            }
            case 2: r = mx; break;
            case 3: r = mn; break;
            case 4: r = mx - mn; break;
            case 5: r = sum; break;
            case 6: r = m2 * 255.0; break;
            case 7: r = sqrt(m2); break;
            case 8: {
                for (int a = 1; a < n; a++) { float key = v[a]; int b = a - 1; while (b >= 0 && v[b] > key) { v[b + 1] = v[b]; b--; } v[b + 1] = key; }
                float h = 0.0; int run = 1;
                for (int k = 1; k <= n; k++) {
                    if (k < n && floor(v[k] * 255.0 + 0.5) == floor(v[k - 1] * 255.0 + 0.5)) { run++; continue; }
                    float q = float(run) / float(n);
                    h -= q * log2(q);
                    run = 1;
                }
                r = n > 1 ? h / log2(float(n)) : 0.0;
                break;
            }
            case 9: {
                float sk = m2 > 1e-10 ? m3 / pow(m2, 1.5) : 0.0;
                float lim = n > 2 ? float(n - 2) / sqrt(float(n - 1)) : 1.0;
                r = 0.5 + 0.5 * sk / max(lim, 1e-3);
                break;
            }
            default: {
                float ku = m2 > 1e-10 ? m4 / (m2 * m2) : 0.0;
                r = ku / max(float(n), 1.0);
                break;
            }
            }
            outv[ch] = clamp(r, 0.0, 1.0);
        }
        dst[idx] = uchar4(uchar(outv[0] * amax * 255.0 + 0.5), uchar(outv[1] * amax * 255.0 + 0.5), uchar(outv[2] * amax * 255.0 + 0.5), uchar(amax * 255.0 + 0.5));
    }
    """

    static let library: MTLLibrary? = {
        do { return try RenderEngine.device.makeLibrary(source: source, options: nil) } catch {
            print("ImagingMetal compile error: \(error)")
            return nil
        }
    }()

    private static var pipelines: [String: MTLComputePipelineState] = [:]
    private static let lock = NSLock()

    static func pipeline(_ name: String) -> MTLComputePipelineState? {
        lock.lock(); defer { lock.unlock() }
        if let p = pipelines[name] { return p }
        guard let f = library?.makeFunction(name: name), let p = try? RenderEngine.device.makeComputePipelineState(function: f) else { return nil }
        pipelines[name] = p
        return p
    }

    /// Dispatches a 2D compute kernel over width × height and waits.
    static func dispatch(_ name: String, width: Int, height: Int, _ encode: (MTLComputeCommandEncoder) -> Void) -> Bool {
        guard let p = pipeline(name), let cb = RenderEngine.commandQueue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return false }
        enc.setComputePipelineState(p)
        encode(enc)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return cb.status == .completed
    }
}
