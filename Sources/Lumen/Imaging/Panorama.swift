import Foundation
import CoreImage
import simd
import ImageCratCore

enum PanoLayout: String, CaseIterable, Identifiable {
    case auto = "Auto", perspective = "Perspective", cylindrical = "Cylindrical", spherical = "Spherical", collage = "Collage", reposition = "Reposition"
    var id: String { rawValue }
    var model: Registration.Model {
        switch self {
        case .collage: return .similarity
        case .reposition: return .translation
        default: return .homography
        }
    }
}

struct PanoOptions {
    var layout: PanoLayout = .auto
    var blend = true
    var vignette = false
    var distortion = false
    var contentAwareFill = false
    var asLayers = true
    var full360 = false
    var maxPixels = 80_000_000
}

struct PanoSource {
    var name: String
    var image: CIImage      // extent (0, 0, w, h)
    var w: Int { Int(image.extent.width) }
    var h: Int { Int(image.extent.height) }
}

/// Output-space projection (reference camera; output pixel → reference homogeneous point).
struct PanoProjection {
    var type = 0                 // 0 plane, 1 cylinder, 2 sphere
    var f = 1000.0
    var cx = 0.0, cy = 0.0       // reference principal point (doc px)
    var x0 = 0.0, y0 = 0.0       // param-space origin of output pixel (0,0)
    var s = 1.0                  // output px per param unit

    func refHomog(_ X: Double, _ Y: Double) -> SIMD3<Double> {
        let u = X / s + x0, v = Y / s + y0
        switch type {
        case 0: return SIMD3(u, v, 1)
        case 1:
            let th = u / f
            return SIMD3(f * sin(th) + cx * cos(th), v + cy * cos(th), cos(th))
        default:
            let th = u / f, ph = v / f
            let r = SIMD3(sin(th) * cos(ph), sin(ph), cos(th) * cos(ph))
            return SIMD3(f * r.x + cx * r.z, f * r.y + cy * r.z, r.z)
        }
    }

    /// Reference homogeneous point → param (u, v).
    func param(_ q: SIMD3<Double>) -> SIMD2<Double>? {
        switch type {
        case 0:
            guard q.z > 1e-9 else { return nil }
            return SIMD2(q.x / q.z, q.y / q.z)
        default:
            let r = SIMD3((q.x - cx * q.z) / f, (q.y - cy * q.z) / f, q.z)
            let hz = sqrt(r.x * r.x + r.z * r.z)
            let th = atan2(r.x, r.z)
            if type == 1 { return SIMD2(f * th, f * r.y / max(1e-9, hz)) }
            return SIMD2(f * th, f * atan2(r.y, hz))
        }
    }
}

/// One warped input.
struct PanoImage {
    var source: PanoSource
    var H: Homography          // source → reference
    var Hinv: Homography       // reference → source
    var k1 = 0.0               // radial distortion (undistorted → source)
    var vignette = 0.0         // v(r) = 1 + vignette·r²
    var gain = SIMD3<Double>(1, 1, 1)
    var bounds = CGRect.null   // output doc rect covered
}

struct PanoResult {
    var width: Int
    var height: Int
    var layers: [(name: String, image: CIImage, mask: CIImage?)]   // output CI space
    var blended: CIImage
    var footprint: CIImage          // gray union coverage
    var layout: PanoLayout
    var reference: Int
    var log: [String]
}

enum Panorama {
    // MARK: Kernels

    static let warpKernel = CIKernel(source: """
    kernel vec4 lumenPanoWarp(sampler src, vec4 proj, vec4 geo, vec3 g0, vec3 g1, vec3 g2, vec4 lens) {
        vec2 d = destCoord();
        float X = d.x - 0.5;
        float Y = geo.w - d.y - 0.5;
        float u = X / geo.z + geo.x;
        float v = Y / geo.z + geo.y;
        vec3 q;
        if (proj.x < 0.5) {
            q = vec3(u, v, 1.0);
        } else if (proj.x < 1.5) {
            float th = u / proj.y;
            q = vec3(proj.y * sin(th) + proj.z * cos(th), v + proj.w * cos(th), cos(th));
        } else {
            float th = u / proj.y;
            float ph = v / proj.y;
            vec3 r = vec3(sin(th) * cos(ph), sin(ph), cos(th) * cos(ph));
            q = vec3(proj.y * r.x + proj.z * r.z, proj.y * r.y + proj.w * r.z, r.z);
        }
        vec3 sp = vec3(dot(g0, q), dot(g1, q), dot(g2, q));
        if (sp.z <= 0.000001) { return vec4(0.0); }
        vec2 p = sp.xy / sp.z;
        vec2 c = vec2(0.5 * (lens.z - 1.0), 0.5 * (lens.w - 1.0));
        vec2 dd = p - c;
        float rn2 = dot(dd, dd) / max(dot(c, c), 1.0);
        p = c + dd * (1.0 + lens.x * rn2);
        if (p.x < -0.5 || p.y < -0.5 || p.x > lens.z - 0.5 || p.y > lens.w - 0.5) { return vec4(0.0); }
        vec2 ci = vec2(p.x + 0.5, lens.w - p.y - 0.5);
        return sample(src, samplerTransform(src, ci));
    }
    """)

    /// Gain (linear light) + vignette correction on the source image.
    static let photoKernel = CIColorKernel(source: """
    float lumenS2L(float c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }
    float lumenL2S(float c) { return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055; }
    kernel vec4 lumenPhotoFix(__sample s, vec3 gain, vec4 vig) {
        if (s.a <= 0.0) { return s; }
        vec3 c = s.rgb / s.a;
        vec2 d = destCoord() - vig.yz;
        float rn2 = dot(d, d) / max(vig.w, 1.0);
        float v = max(0.05, 1.0 + vig.x * rn2);
        vec3 lin = vec3(lumenS2L(c.r), lumenS2L(c.g), lumenS2L(c.b)) * gain / v;
        vec3 o = vec3(lumenL2S(max(lin.r, 0.0)), lumenL2S(max(lin.g, 0.0)), lumenL2S(max(lin.b, 0.0)));
        return vec4(clamp(o, 0.0, 1.0) * s.a, s.a);
    }
    """)

    static func warp(_ img: PanoImage, proj: PanoProjection, outW: Int, outH: Int, corrected: Bool = true) -> CIImage {
        var src = img.source.image
        if corrected, let k = photoKernel, img.gain != SIMD3(1, 1, 1) || img.vignette != 0 {
            let w = Double(img.source.w), h = Double(img.source.h)
            src = k.apply(extent: src.extent, arguments: [src, CIVector(x: CGFloat(img.gain.x), y: CGFloat(img.gain.y), z: CGFloat(img.gain.z)),
                                                           CIVector(x: CGFloat(img.vignette), y: CGFloat(w / 2), z: CGFloat(h / 2), w: CGFloat(w * w / 4 + h * h / 4))]) ?? src
        }
        let m = img.Hinv.m
        let ext = src.extent
        let out = CGRect(x: 0, y: 0, width: outW, height: outH)
        let bb = img.bounds.isNull ? out : CGRect(x: img.bounds.minX, y: CGFloat(outH) - img.bounds.maxY, width: img.bounds.width, height: img.bounds.height).insetBy(dx: -2, dy: -2).intersection(out).integral
        guard let k = warpKernel, !bb.isEmpty else { return CIImage.clearImage.cropped(to: .zero) }
        return k.apply(extent: bb, roiCallback: { _, _ in ext }, arguments: [
            src,
            CIVector(x: CGFloat(proj.type), y: CGFloat(proj.f), z: CGFloat(proj.cx), w: CGFloat(proj.cy)),
            CIVector(x: CGFloat(proj.x0), y: CGFloat(proj.y0), z: CGFloat(proj.s), w: CGFloat(outH)),
            CIVector(x: CGFloat(m[0]), y: CGFloat(m[1]), z: CGFloat(m[2])),
            CIVector(x: CGFloat(m[3]), y: CGFloat(m[4]), z: CGFloat(m[5])),
            CIVector(x: CGFloat(m[6]), y: CGFloat(m[7]), z: CGFloat(m[8])),
            CIVector(x: CGFloat(img.k1), y: 0, z: CGFloat(img.source.w), w: CGFloat(img.source.h)),
        ]) ?? CIImage.clearImage.cropped(to: .zero)
    }

    // MARK: CPU mirror of the warp (for estimation on a coarse grid)

    static func sourcePoint(_ img: PanoImage, proj: PanoProjection, X: Double, Y: Double) -> SIMD2<Double>? {
        let q = proj.refHomog(X, Y)
        let m = img.Hinv.m
        let sz = m[6] * q.x + m[7] * q.y + m[8] * q.z
        guard sz > 1e-9 else { return nil }
        var p = SIMD2((m[0] * q.x + m[1] * q.y + m[2] * q.z) / sz, (m[3] * q.x + m[4] * q.y + m[5] * q.z) / sz)
        let c = SIMD2(0.5 * Double(img.source.w - 1), 0.5 * Double(img.source.h - 1))
        let d = p - c
        p = c + d * (1 + img.k1 * simd_length_squared(d) / max(1, simd_length_squared(c)))
        guard p.x >= -0.5, p.y >= -0.5, p.x <= Double(img.source.w) - 0.5, p.y <= Double(img.source.h) - 0.5 else { return nil }
        return p
    }

    /// Undistorted point for a distorted source point (fixed-point inversion of the radial model).
    static func undistort(_ p: SIMD2<Double>, k1: Double, w: Int, h: Int) -> SIMD2<Double> {
        let c = SIMD2(0.5 * Double(w - 1), 0.5 * Double(h - 1))
        let n = max(1, simd_length_squared(c))
        var u = p
        for _ in 0..<8 { let d = u - c; u = c + (p - c) / (1 + k1 * simd_length_squared(d) / n) }
        return u
    }

    // MARK: Build

    static func build(_ sources: [PanoSource], options o: PanoOptions, progress: ((String) -> Void)? = nil) -> PanoResult? {
        guard sources.count >= 2 else { return nil }
        var log: [String] = []
        progress?("Finding features…")
        let upright = o.layout != .collage
        let sets = sources.map { Registration.prepare($0.image, maxSide: 1000, upright: upright) }
        progress?("Matching images…")
        var align = Registration.alignAll(sets, model: o.layout.model)
        log.append("reference \(align.reference); pairs: " + align.pairs.map { "\($0.0)→\($0.1) \($0.2.method) inl \($0.2.inliers) ncc \(String(format: "%.3f", $0.2.score))" }.joined(separator: ", "))

        // Geometric distortion correction: pick k1 minimising the homography fit residual of all inlier matches.
        var k1 = 0.0
        if o.distortion, o.layout.model == .homography {
            k1 = estimateDistortion(align, sources: sources)
            log.append("k1 \(String(format: "%.3f", k1))")
            if abs(k1) > 1e-4 {
                // refit pair homographies on undistorted matches and re-chain
                align = refit(align, sources: sources, k1: k1)
            }
        }
        var imgs: [PanoImage] = []
        var names: [Int] = []
        for (i, s) in sources.enumerated() {
            guard let H = align.H[i], let Hi = H.inverted else { log.append("\(s.name): no overlap found (skipped)"); continue }
            imgs.append(PanoImage(source: s, H: H, Hinv: Registration.normalized(Hi), k1: k1))
            names.append(i)
        }
        guard imgs.count >= 2 else { log.append("could not align"); print(log.joined(separator: "\n")); return nil }
        let refIndex = names.firstIndex(of: align.reference) ?? 0

        // Projection
        var proj = PanoProjection()
        let ref = sources[align.reference]
        proj.cx = Double(ref.w - 1) / 2; proj.cy = Double(ref.h - 1) / 2
        var fs: [Double] = []
        for (a, b, p) in align.pairs where o.layout.model == .homography {
            let Ta = Homography(m: [1, 0, Double(sources[a].w - 1) / 2, 0, 1, Double(sources[a].h - 1) / 2, 0, 0, 1])
            let Tb = Homography(m: [1, 0, -Double(sources[b].w - 1) / 2, 0, 1, -Double(sources[b].h - 1) / 2, 0, 0, 1])
            if let f = Registration.focal(from: Tb.concat(p.H).concat(Ta)), f > Double(max(ref.w, ref.h)) * 0.3, f < Double(max(ref.w, ref.h)) * 8 { fs.append(f) }
        }
        let fDefault = Double(max(ref.w, ref.h)) * 1.0
        proj.f = fs.isEmpty ? fDefault : fs.sorted()[fs.count / 2]
        log.append("focal \(Int(proj.f))\(fs.isEmpty ? " (default)" : "")")
        var layout = o.layout
        if layout == .auto {
            proj.type = 0
            let planar = bounds(imgs, proj)
            let area = imgs.reduce(0.0) { $0 + Double($1.source.w * $1.source.h) }
            let planarOK = planar.map { !$0.isInfinite && $0.width * $0.height < area * 3 && $0.width < Double(ref.w) * 8 } ?? false
            proj.type = 1
            let cyl = bounds(imgs, proj)
            let fovH = (cyl?.width ?? 0) / proj.f, fovV = (cyl?.height ?? 0) / proj.f
            if planarOK && fovH < 1.9 { layout = .perspective } else { layout = fovV > 1.4 ? .spherical : .cylindrical }
            log.append("auto → \(layout.rawValue) (h fov \(Int(fovH * 180 / .pi))°)")
        }
        switch layout {
        case .cylindrical: proj.type = 1
        case .spherical: proj.type = 2
        default: proj.type = 0
        }
        // Wave correction: level the horizon of rotating-camera panoramas (Brown & Lowe automatic straightening).
        if proj.type != 0, !fs.isEmpty, imgs.count >= 3 {
            if let L = levelingHomography(imgs, proj) {
                for i in imgs.indices { imgs[i].H = Registration.normalized(L.concat(imgs[i].H)); imgs[i].Hinv = Registration.normalized(imgs[i].H.inverted!) }
                log.append("levelled horizon")
            }
        }
        // Collage / Reposition: keep the median image orientation upright.
        if layout == .collage {
            let angles = imgs.map { atan2($0.H.m[3], $0.H.m[0]) }.sorted()
            let med = angles[angles.count / 2]
            if abs(med) > 0.001 {
                let c = cos(-med), sn = sin(-med)
                let R = Homography(m: [1, 0, proj.cx, 0, 1, proj.cy, 0, 0, 1]).concat(Homography(m: [c, -sn, 0, sn, c, 0, 0, 0, 1])).concat(Homography(m: [1, 0, -proj.cx, 0, 1, -proj.cy, 0, 0, 1]))
                for i in imgs.indices { imgs[i].H = Registration.normalized(R.concat(imgs[i].H)); imgs[i].Hinv = Registration.normalized(imgs[i].H.inverted!) }
            }
        }
        guard var bb = bounds(imgs, proj) else { log.append("bad bounds"); return nil }
        if proj.type == 0 {
            // guard against runaway perspective
            let area = imgs.reduce(0.0) { $0 + Double($1.source.w * $1.source.h) }
            if bb.width * bb.height > area * 6 {
                log.append("perspective too extreme → cylindrical")
                proj.type = 1; layout = .cylindrical
                bb = bounds(imgs, proj) ?? bb
            }
        }
        if o.full360 && proj.type == 2 {
            bb = CGRect(x: -Double.pi * proj.f, y: -Double.pi / 2 * proj.f, width: 2 * Double.pi * proj.f, height: Double.pi * proj.f)
        }
        proj.x0 = bb.minX; proj.y0 = bb.minY
        let px = bb.width * bb.height
        proj.s = px > Double(o.maxPixels) ? sqrt(Double(o.maxPixels) / px) : 1
        var W = max(1, Int((bb.width * proj.s).rounded(.up)))
        if o.full360 && proj.type == 2 { W += W & 1; proj.s = Double(W) / bb.width }
        let H = o.full360 && proj.type == 2 ? W / 2 : max(1, Int((bb.height * proj.s).rounded(.up)))
        for i in imgs.indices { imgs[i].bounds = outputBounds(imgs[i], proj, W: W, H: H) }
        log.append("output \(W)×\(H) \(layout.rawValue)")

        // Coarse grid for exposure / vignette / seams
        progress?("Balancing exposure…")
        let grid = PanoGrid(imgs, proj: proj, W: W, H: H)
        if o.vignette { let v = grid.estimateVignette(); for i in imgs.indices { imgs[i].vignette = v }; log.append("vignette \(String(format: "%.3f", v))") }
        if o.blend {
            let gains = grid.gains(vignette: imgs.first?.vignette ?? 0)
            for i in imgs.indices { imgs[i].gain = gains[i] }
            log.append("gains " + gains.map { String(format: "%.3f", $0.y) }.joined(separator: " "))
        }

        progress?("Blending…")
        let outRect = CGRect(x: 0, y: 0, width: W, height: H)
        let warped = imgs.map { warp($0, proj: proj, outW: W, outH: H) }
        var foot = CIImage.color(.black, outRect)
        for w in warped { foot = w.alphaAsGray.composited(over: CIImage.clearImage.cropped(to: outRect)).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: foot]) }
        foot = foot.cropped(to: outRect)
        var layers: [(String, CIImage, CIImage?)] = []
        var blended: CIImage
        if o.blend {
            let labels = grid.seamLabels()
            let masks = imgs.indices.map { grid.maskImage(labels, index: $0, W: W, H: H) }
            blended = MultiBand.blend(images: warped, masks: masks, rect: outRect).masked(byGray: foot)
            let hardMasks = MergeActions.partition(masks, images: warped, rect: outRect)
            for (i, w) in warped.enumerated() {
                let hm = hardMasks[i]
                let content = blended.mixed(with: w, mask: hm).cropped(to: w.extent.union(hm.extent).intersection(outRect))
                layers.append((sources[names[i]].name, content, hm))
            }
        } else {
            blended = CIImage.clearImage.cropped(to: outRect)
            for (i, w) in warped.enumerated() {
                blended = w.composited(over: blended)
                layers.append((sources[names[i]].name, w, nil))
            }
        }
        print(log.joined(separator: "\n"))
        return PanoResult(width: W, height: H, layers: layers, blended: blended.cropped(to: outRect), footprint: foot, layout: layout, reference: refIndex, log: log)
    }

    /// Rotation (as a homography in reference pixels) that makes the common "up" direction vertical:
    /// the up vector is the direction most perpendicular to every camera's x-axis.
    static func levelingHomography(_ imgs: [PanoImage], _ proj: PanoProjection) -> Homography? {
        let K = Homography(m: [proj.f, 0, proj.cx, 0, proj.f, proj.cy, 0, 0, 1])
        guard let Ki = K.inverted else { return nil }
        var C = simd_double3x3(0)
        for img in imgs {
            let R = Ki.concat(img.H).concat(K).m
            var x = SIMD3(R[0], R[3], R[6])
            let n = simd_length(x); guard n > 1e-9 else { continue }
            x /= n
            C += simd_double3x3(rows: [x * x.x, x * x.y, x * x.z])
        }
        // smallest eigenvector of C by inverse power iteration (C + εI)⁻¹
        let Ce = C + simd_double3x3(diagonal: SIMD3(repeating: 1e-6))
        guard abs(Ce.determinant) > 1e-15 else { return nil }
        let inv = Ce.inverse
        var u = SIMD3<Double>(0, 1, 0)
        for _ in 0..<50 { u = simd_normalize(inv * u) }
        // Only meaningful when the cameras actually rotate (x-axes span a plane); otherwise "up" is ambiguous.
        var vmax = SIMD3<Double>(1, 0.3, 0.2)
        for _ in 0..<50 { vmax = simd_normalize(C * vmax) }
        let lmax = simd_dot(vmax, C * vmax), lmin = simd_dot(u, C * u)
        let tr = C[0][0] + C[1][1] + C[2][2]
        guard tr - lmax - lmin > 0.01 * tr else { return nil }
        if u.y < 0 { u = -u }
        let t = SIMD3<Double>(0, 1, 0)
        let axis = simd_cross(u, t)
        let sinA = simd_length(axis), cosA = simd_dot(u, t)
        guard sinA > 1e-6 else { return nil }
        let k = axis / sinA
        let Kx = simd_double3x3(rows: [SIMD3(0, -k.z, k.y), SIMD3(k.z, 0, -k.x), SIMD3(-k.y, k.x, 0)])
        let Rm = simd_double3x3(diagonal: SIMD3(repeating: 1)) + sinA * Kx + (1 - cosA) * (Kx * Kx)
        let r = [Rm[0][0], Rm[1][0], Rm[2][0], Rm[0][1], Rm[1][1], Rm[2][1], Rm[0][2], Rm[1][2], Rm[2][2]]
        return K.concat(Homography(m: r)).concat(Ki)
    }

    /// Param-space bounds of all images (edges sampled).
    static func bounds(_ imgs: [PanoImage], _ proj: PanoProjection) -> CGRect? {
        var r = CGRect.null
        for img in imgs {
            let w = Double(img.source.w), h = Double(img.source.h)
            var pts: [SIMD2<Double>] = []
            let n = 24
            for i in 0...n {
                let t = Double(i) / Double(n)
                pts += [SIMD2(t * (w - 1), 0), SIMD2(t * (w - 1), h - 1), SIMD2(0, t * (h - 1)), SIMD2(w - 1, t * (h - 1))]
            }
            for p in pts {
                let u = undistort(p, k1: img.k1, w: img.source.w, h: img.source.h)
                let m = img.H.m
                let q = SIMD3(m[0] * u.x + m[1] * u.y + m[2], m[3] * u.x + m[4] * u.y + m[5], m[6] * u.x + m[7] * u.y + m[8])
                guard let pp = proj.param(q) else { return nil }
                r = r.union(CGRect(x: pp.x, y: pp.y, width: 0, height: 0))
            }
        }
        return r.isNull ? nil : r.insetBy(dx: -0.5, dy: -0.5)
    }

    static func outputBounds(_ img: PanoImage, _ proj: PanoProjection, W: Int, H: Int) -> CGRect {
        guard var b = bounds([img], proj) else { return CGRect(x: 0, y: 0, width: W, height: H) }
        b = CGRect(x: (b.minX - proj.x0) * proj.s, y: (b.minY - proj.y0) * proj.s, width: b.width * proj.s, height: b.height * proj.s)
        if proj.type != 0 && b.width > Double(W) * 0.9 { b = CGRect(x: 0, y: b.minY, width: Double(W), height: b.height) }
        return b.insetBy(dx: -2, dy: -2).intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
    }

    // MARK: Lens distortion

    static func estimateDistortion(_ a: Registration.Alignment, sources: [PanoSource]) -> Double {
        var best = (0.0, Double.greatestFiniteMagnitude)
        for step in -15...15 {
            let k = Double(step) * 0.02
            var err = 0.0, n = 0.0
            for (f, r, p) in a.pairs where p.matches.count >= 8 {
                let src = p.matches.map { undistort($0.0, k1: k, w: sources[f].w, h: sources[f].h) }
                let dst = p.matches.map { undistort($0.1, k1: k, w: sources[r].w, h: sources[r].h) }
                guard let H = Registration.fit(src, dst, model: .homography) else { continue }
                for i in src.indices { err += simd_length_squared(Registration.apply(H, src[i]) - dst[i]); n += 1 }
            }
            if n > 0, err / n < best.1 { best = (k, err / n) }
        }
        return best.0
    }

    static func refit(_ a: Registration.Alignment, sources: [PanoSource], k1: Double) -> Registration.Alignment {
        var out = a
        var H = [Homography?](repeating: nil, count: a.H.count)
        H[a.reference] = .identity
        var pairs: [(Int, Int, Registration.Pair)] = []
        for (f, r, p) in a.pairs {
            var q = p
            let src = p.matches.map { undistort($0.0, k1: k1, w: sources[f].w, h: sources[f].h) }
            let dst = p.matches.map { undistort($0.1, k1: k1, w: sources[r].w, h: sources[r].h) }
            if let h = Registration.fit(src, dst, model: .homography) { q.H = Registration.normalized(h) }
            pairs.append((f, r, q))
            if let hr = H[r] { H[f] = Registration.normalized(hr.concat(q.H)) }
        }
        out.H = H
        out.pairs = pairs
        return out
    }
}

// MARK: - Coarse estimation grid

final class PanoGrid {
    let gw: Int, gh: Int
    let n: Int
    var valid: [[Bool]]
    var col: [[SIMD3<Float>]]        // linear RGB
    var r2: [[Float]]
    var wgt: [[Float]]

    init(_ imgs: [PanoImage], proj: PanoProjection, W: Int, H: Int, maxSide: Int = 360) {
        let g = min(1.0, Double(maxSide) / Double(max(W, H)))
        gw = max(2, Int(Double(W) * g)); gh = max(2, Int(Double(H) * g))
        n = imgs.count
        valid = Array(repeating: Array(repeating: false, count: gw * gh), count: n)
        col = Array(repeating: Array(repeating: .zero, count: gw * gh), count: n)
        r2 = Array(repeating: Array(repeating: 0, count: gw * gh), count: n)
        wgt = Array(repeating: Array(repeating: 0, count: gw * gh), count: n)
        for (i, img) in imgs.enumerated() {
            // small linear-light copy of the source
            let ss = min(1.0, 200.0 / Double(max(img.source.w, img.source.h)))
            let sw = max(2, Int(Double(img.source.w) * ss)), sh = max(2, Int(Double(img.source.h) * ss))
            var px = [Float](repeating: 0, count: sw * sh * 4)
            let small = img.source.image.transformed(by: CGAffineTransform(scaleX: CGFloat(Double(sw) / Double(img.source.w)), y: CGFloat(Double(sh) / Double(img.source.h))), highQualityDownsample: true)
            let rr = CGRect(x: 0, y: 0, width: sw, height: sh)
            RenderEngine.readbackContext.render(small.composited(over: CIImage.clearImage.cropped(to: rr)), toBitmap: &px, rowBytes: sw * 16, bounds: rr, format: .RGBAf,
                                                colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
            let cx = Double(img.source.w - 1) / 2, cy = Double(img.source.h - 1) / 2
            let norm = cx * cx + cy * cy
            let bnd = img.bounds
            for gy in 0..<gh {
                for gx in 0..<gw {
                    let X = (Double(gx) + 0.5) / g - 0.5, Y = (Double(gy) + 0.5) / g - 0.5
                    if !bnd.isNull && !bnd.insetBy(dx: -4, dy: -4).contains(CGPoint(x: X, y: Y)) { continue }
                    guard let p = Panorama.sourcePoint(img, proj: proj, X: X, Y: Y) else { continue }
                    let sx = (p.x + 0.5) * ss - 0.5, sy = (p.y + 0.5) * ss - 0.5
                    let x0 = clamp(Int(sx), 0, sw - 2), y0 = clamp(Int(sy), 0, sh - 2)
                    let fx = Float(clamp(sx - Double(x0), 0, 1)), fy = Float(clamp(sy - Double(y0), 0, 1))
                    func at(_ x: Int, _ y: Int) -> SIMD4<Float> { let o = (y * sw + x) * 4; return SIMD4(px[o], px[o + 1], px[o + 2], px[o + 3]) }
                    let c = (at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx) * (1 - fy) + (at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx) * fy
                    guard c.w > 0.9 else { continue }
                    let k = gy * gw + gx
                    valid[i][k] = true
                    col[i][k] = SIMD3(c.x, c.y, c.z) / c.w
                    let d = SIMD2(p.x - cx, p.y - cy)
                    r2[i][k] = Float(simd_length_squared(d) / max(1, norm))
                    wgt[i][k] = Float(min(p.x + 0.5, Double(img.source.w) - 0.5 - p.x, p.y + 0.5, Double(img.source.h) - 0.5 - p.y) / (0.5 * Double(min(img.source.w, img.source.h))))
                }
            }
        }
    }

    /// Per-image RGB gains in linear light (Brown & Lowe gain compensation).
    func gains(vignette v: Double) -> [SIMD3<Double>] {
        // σN: overlap mismatch (linear light, relative), σg: weak prior that only pins the overall exposure
        let sn = 0.01, sg = 1.0
        var out = [SIMD3<Double>](repeating: SIMD3(1, 1, 1), count: n)
        for ch in 0..<3 {
            var A = [Double](repeating: 0, count: n * n), b = [Double](repeating: 0, count: n)
            for i in 0..<n {
                for j in (i + 1)..<max(i + 1, n) {
                    var si = 0.0, sj = 0.0, cnt = 0.0
                    for k in 0..<(gw * gh) where valid[i][k] && valid[j][k] {
                        si += Double(col[i][k][ch]) / (1 + v * Double(r2[i][k]))
                        sj += Double(col[j][k][ch]) / (1 + v * Double(r2[j][k]))
                        cnt += 1
                    }
                    guard cnt > 10 else { continue }
                    let Ii = si / cnt, Ij = sj / cnt
                    let w = cnt / (sn * sn)
                    A[i * n + i] += w * Ii * Ii; A[j * n + j] += w * Ij * Ij
                    A[i * n + j] -= w * Ii * Ij; A[j * n + i] -= w * Ii * Ij
                    let wg = cnt / (sg * sg)
                    A[i * n + i] += wg; b[i] += wg
                    A[j * n + j] += wg; b[j] += wg
                }
            }
            for i in 0..<n where A[i * n + i] == 0 { A[i * n + i] = 1; b[i] = 1 }
            if let g = Registration.solve(A, b, n) { for i in 0..<n { out[i][ch] = clamp(g[i], 0.25, 4) } }
        }
        // keep the overall exposure: geometric mean of the green gains = 1
        let lg = out.reduce(0.0) { $0 + log($1.y) } / Double(max(1, n))
        let k = exp(-lg)
        return out.map { $0 * k }
    }

    /// Vignetting coefficient (v(r) = 1 + a·r², a ≤ 0 darkens corners) minimising overlap differences.
    func estimateVignette() -> Double {
        var best = (0.0, Double.greatestFiniteMagnitude)
        for step in 0...14 {
            let a = -Double(step) * 0.05
            let g = gains(vignette: a)
            var err = 0.0, cnt = 0.0
            for i in 0..<n { for j in (i + 1)..<max(i + 1, n) {
                for k in 0..<(gw * gh) where valid[i][k] && valid[j][k] {
                    let ci = Double(col[i][k].y) * g[i].y / (1 + a * Double(r2[i][k]))
                    let cj = Double(col[j][k].y) * g[j].y / (1 + a * Double(r2[j][k]))
                    let d = ci - cj
                    err += d * d; cnt += 1
                }
            } }
            if cnt > 0, err / cnt < best.1 { best = (a, err / cnt) }
        }
        return best.0
    }

    /// Seam labels: distance-weighted Voronoi initialisation refined by ICM on colour differences along the seam.
    func seamLabels(iterations: Int = 10) -> [Int] {
        let N = gw * gh
        var label = [Int](repeating: -1, count: N)
        for k in 0..<N {
            var best = -1; var bw: Float = -1
            for i in 0..<n where valid[i][k] && wgt[i][k] > bw { bw = wgt[i][k]; best = i }
            label[k] = best
        }
        let lambdaD: Float = 0.08, beta: Float = 0.01
        func diff(_ a: Int, _ b: Int, _ k: Int) -> Float {
            if a == b { return 0 }
            guard valid[a][k] && valid[b][k] else { return 10 }
            let d = col[a][k] - col[b][k]
            return abs(d.x) + abs(d.y) + abs(d.z)
        }
        for it in 0..<iterations {
            let forward = it % 2 == 0
            for kk in 0..<N {
                let k = forward ? kk : N - 1 - kk
                let cur = label[k]
                guard cur >= 0 else { continue }
                let x = k % gw, y = k / gw
                var nb: [Int] = []
                if x > 0 { nb.append(k - 1) }; if x < gw - 1 { nb.append(k + 1) }
                if y > 0 { nb.append(k - gw) }; if y < gh - 1 { nb.append(k + gw) }
                var bestL = cur, bestE = Float.greatestFiniteMagnitude
                for l in 0..<n where valid[l][k] {
                    var e = lambdaD * (1 - min(1, wgt[l][k]))
                    for q in nb {
                        let lq = label[q]
                        if lq < 0 || lq == l { continue }
                        e += beta + diff(l, lq, k) + diff(l, lq, q)
                    }
                    if e < bestE { bestE = e; bestL = l }
                }
                label[k] = bestL
            }
        }
        return label
    }

    /// Soft mask of label == index, upsampled to the output (CI space, gray).
    func maskImage(_ labels: [Int], index: Int, W: Int, H: Int) -> CIImage {
        var bytes = [UInt8](repeating: 0, count: gw * gh * 4)
        for k in 0..<(gw * gh) {
            let v: UInt8 = labels[k] == index ? 255 : 0
            bytes[k * 4] = v; bytes[k * 4 + 1] = v; bytes[k * 4 + 2] = v; bytes[k * 4 + 3] = 255
        }
        let img = CIImage(bitmapData: Data(bytes), bytesPerRow: gw * 4, size: CGSize(width: gw, height: gh), format: .RGBA8, colorSpace: nil)
        // bitmap rows are top-first, which CIImage(bitmapData:) already treats as the top
        let sx = CGFloat(W) / CGFloat(gw), sy = CGFloat(H) / CGFloat(gh)
        return img.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .applyingGaussianBlur(sigma: Double(max(sx, sy)) * 0.5)
            .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    }
}

// MARK: - Multi-band (Laplacian pyramid) blending

enum MultiBand {
    static let lapKernel = CIColorKernel(source: "kernel vec4 lumenLap(__sample a, __sample b) { return vec4(a.rgb - b.rgb, 1.0); }")
    static let accKernel = CIColorKernel(source: "kernel vec4 lumenAcc(__sample acc, __sample l, __sample m) { return vec4(acc.rgb + l.rgb * m.r, 1.0); }")
    static let wKernel = CIColorKernel(source: "kernel vec4 lumenAccW(__sample acc, __sample m) { return vec4(acc.r + m.r, 0.0, 0.0, 1.0); }")
    static let normKernel = CIColorKernel(source: "kernel vec4 lumenNorm(__sample acc, __sample w, __sample up) { return vec4(acc.rgb / max(w.r, 0.00001) + up.rgb, 1.0); }")

    static func rect(_ r0: CGRect, _ k: Int) -> CGRect {
        let d = CGFloat(1 << k)
        return CGRect(x: 0, y: 0, width: ceil(r0.width / d), height: ceil(r0.height / d))
    }

    static func down(_ img: CIImage, _ r: CGRect) -> CIImage {
        img.clampedToExtent().applyingGaussianBlur(sigma: 1.0).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5)).cropped(to: r)
    }

    static func up(_ img: CIImage, _ r: CGRect) -> CIImage {
        img.clampedToExtent().transformed(by: CGAffineTransform(scaleX: 2, y: 2)).cropped(to: r)
    }

    /// Pull-push fill: extends a partially transparent image into an opaque one (smooth colours outside its footprint).
    static func extend(_ img: CIImage, _ r0: CGRect) -> CIImage {
        var levels = [img.composited(over: CIImage.clearImage.cropped(to: r0)).cropped(to: r0)]
        var k = 0
        while rect(r0, k).width > 4 && rect(r0, k).height > 4 && k < 14 {
            k += 1
            levels.append(levels[k - 1].transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5)).cropped(to: rect(r0, k)))
        }
        let top = levels[k]
        let avg = top.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: top.extent)])
            .unpremultiplyingAlpha().settingAlphaOne(in: CGRect(x: 0, y: 0, width: 1, height: 1)).clampedToExtent().cropped(to: top.extent)
        var F = top.composited(over: avg)
        var j = k - 1
        while j >= 0 {
            F = levels[j].composited(over: up(F, rect(r0, j)))
            j -= 1
        }
        let out = F.cropped(to: r0)
        // materialise (keeps later pyramids shallow)
        if let cg = RenderEngine.readbackContext.createCGImage(out, from: r0, format: .RGBA16, colorSpace: sRGBSpace) { return CIImage(cgImage: cg) }
        return out
    }

    /// Blends `images` (output CI space, partially transparent) with soft `masks` (gray) using Laplacian pyramids.
    static func blend(images: [CIImage], masks: [CIImage], rect r0: CGRect, levels maxLevels: Int = 7) -> CIImage {
        guard let lapK = lapKernel, let accK = accKernel, let wK = wKernel, !images.isEmpty else { return images.first ?? CIImage.clearImage }
        let L = max(1, min(maxLevels, Int(log2(Double(min(r0.width, r0.height)) / 12))))
        var accRGB = (0...L).map { CIImage.color(.black, rect(r0, $0)) }
        var accW = (0...L).map { CIImage.color(.black, rect(r0, $0)) }
        for (i, img) in images.enumerated() {
            let F = extend(img, r0)
            var G = [F], M = [masks[i].cropped(to: r0)]
            // Materialise each level: otherwise Core Image folds down(×0.5)·up(×2) into one transform and the
            // Laplacian no longer matches the collapse (detail loss).
            for k in 1...L { G.append(materialize(down(G[k - 1], rect(r0, k)))); M.append(down(M[k - 1], rect(r0, k))) }
            for k in 0...L {
                let lap = k == L ? G[k] : (lapK.apply(extent: rect(r0, k), arguments: [G[k], up(G[k + 1], rect(r0, k))]) ?? G[k])
                accRGB[k] = accK.apply(extent: rect(r0, k), arguments: [accRGB[k], lap, M[k]]) ?? accRGB[k]
                accW[k] = wK.apply(extent: rect(r0, k), arguments: [accW[k], M[k]]) ?? accW[k]
            }
            // materialise accumulators every few images to keep graphs small
            if i % 3 == 2 {
                accRGB = accRGB.map { materialize($0) }
                accW = accW.map { materialize($0) }
            }
        }
        return collapse(accRGB, accW, r0)
    }

    /// Collapses a weighted Laplacian pyramid: R_L = acc_L / w_L, R_k = acc_k / w_k + up(R_k+1).
    static func collapse(_ acc: [CIImage], _ w: [CIImage], _ r0: CGRect) -> CIImage {
        guard let normK = normKernel else { return acc[0] }
        let L = acc.count - 1
        var R = normK.apply(extent: rect(r0, L), arguments: [acc[L], w[L], CIImage.color(.black, rect(r0, L))]) ?? acc[L]
        var k = L - 1
        while k >= 0 {
            R = normK.apply(extent: rect(r0, k), arguments: [acc[k], w[k], up(R, rect(r0, k))]) ?? R
            k -= 1
        }
        return R.cropped(to: r0)
    }

    static func materialize(_ img: CIImage) -> CIImage {
        let r = img.extent
        guard !r.isInfinite, !r.isEmpty else { return img }
        var data = Data(count: Int(r.width) * Int(r.height) * 16)
        data.withUnsafeMutableBytes { p in
            RenderEngine.readbackContext.render(img, toBitmap: p.baseAddress!, rowBytes: Int(r.width) * 16, bounds: r, format: .RGBAf, colorSpace: nil)
        }
        return CIImage(bitmapData: data, bytesPerRow: Int(r.width) * 16, size: r.size, format: .RGBAf, colorSpace: nil).translated(r.minX, r.minY)
    }
}
