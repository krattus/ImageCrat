import CoreImage

import ImageCratCore

extension LensProfiles {
    static let distortionKernel = CIWarpKernel(source: """
    kernel vec2 editsLensDist(vec2 c, float norm, vec3 abc, float amt) {
        vec2 d = destCoord() - c;
        float r = length(d) / norm;
        float f = abc.x * r * r * r + abc.y * r * r + abc.z * r + 1.0 - abc.x - abc.y - abc.z;
        f = 1.0 + amt * (f - 1.0);
        return c + d * f;
    }
    """)

    static let tcaKernel = CIKernel(source: """
    kernel vec4 editsLensTCA(sampler src, vec2 c, float norm, vec4 k, float amt) {
        vec2 dc = destCoord();
        vec2 d = dc - c;
        float r2 = dot(d, d) / (norm * norm);
        float fr = 1.0 + amt * (k.x + k.y * r2 - 1.0);
        float fb = 1.0 + amt * (k.z + k.w * r2 - 1.0);
        vec4 g = sample(src, samplerTransform(src, dc));
        vec4 rr = sample(src, samplerTransform(src, c + d * fr));
        vec4 bb = sample(src, samplerTransform(src, c + d * fb));
        return vec4(rr.r, g.g, bb.b, g.a);
    }
    """)

    static let vignetteKernel = CIKernel(source: """
    kernel vec4 editsLensVig(sampler src, vec2 c, float norm, vec3 k, float amt) {
        vec2 dc = destCoord();
        vec4 s = sample(src, samplerTransform(src, dc));
        vec2 d = dc - c;
        float r2 = dot(d, d) / (norm * norm);
        float f = 1.0 + k.x * r2 + k.y * r2 * r2 + k.z * r2 * r2 * r2;
        f = max(0.05, 1.0 + amt * (f - 1.0));
        vec3 col = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        col = clamp(col * pow(1.0 / f, 1.0 / 2.2), 0.0, 1.0);
        return vec4(col * s.a, s.a);
    }
    """)

    /// Applies the selected profile ("profile" = index into `menuNames`), scaled by the amount sliders (100 = profile).
    static func apply(_ input: CIImage, v: (String) -> Double, ext: CGRect, canvas: CGRect) -> CIImage {
        let idx = Int(v("profile").rounded()) - 1
        guard all.indices.contains(idx) else { return input }
        let p = all[idx]
        let c = CIVector(x: canvas.midX, y: canvas.midY)
        let normD = Float(min(canvas.width, canvas.height) / 2)
        let normV = Float(hypot(canvas.width, canvas.height) / 2)
        var img = input
        let tAmt = v("profCA") / 100, dAmt = v("profDistortion") / 100, vAmt = v("profVignette") / 100
        if let t = p.tca, tAmt != 0, let k = tcaKernel {
            let src = img.clampedToExtent()
            img = k.apply(extent: ext, roiCallback: { _, r in r.insetBy(dx: -24, dy: -24) },
                          arguments: [src, c, normD, CIVector(x: CGFloat(t.vr), y: CGFloat(t.br), z: CGFloat(t.vb), w: CGFloat(t.bb)), Float(tAmt)]) ?? img
        }
        if dAmt != 0, let k = distortionKernel {
            let src = img
            img = k.apply(extent: ext, roiCallback: { _, _ in src.extent }, image: src,
                          arguments: [c, normD, CIVector(x: CGFloat(p.abc.0), y: CGFloat(p.abc.1), z: CGFloat(p.abc.2)), Float(dAmt)]) ?? img
        }
        if let vg = p.vignette, vAmt != 0, let k = vignetteKernel {
            img = k.apply(extent: ext, roiCallback: { _, r in r }, arguments: [img.clampedToExtent(), c, normV,
                                                                               CIVector(x: CGFloat(vg.0), y: CGFloat(vg.1), z: CGFloat(vg.2)), Float(vAmt)]) ?? img
        }
        return img.cropped(to: ext)
    }
}
