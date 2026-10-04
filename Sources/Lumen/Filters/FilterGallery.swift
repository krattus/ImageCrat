import Foundation
import CoreImage
import ImageCratCore

extension GalleryFilter {
    // MARK: Apply

    /// input: CI-space image (alpha preserved). fg/bg: foreground/background colors. canvas: CI-space document rect.
    func apply(_ input: CIImage, values: [String: Double], fg: RGBA, bg: RGBA, canvas: CGRect) -> CIImage {
        let ext = input.extent
        if ext.isEmpty || ext.isInfinite { return input }
        let ps = params
        func v(_ k: String) -> Double {
            let raw = values[k] ?? ps.first { $0.key == k }?.defaultValue ?? 0
            if let p = ps.first(where: { $0.key == k }) {
                switch p.kind {
                case .slider(let r): return min(max(raw, r.lowerBound), r.upperBound)
                case .choice(let opts): return min(max(raw.rounded(), 0), Double(max(opts.count - 1, 0)))
                default: return raw
                }
            }
            return raw
        }
        func i(_ k: String) -> Int { Int(v(k).rounded()) }
        let R = ext.insetBy(dx: -6, dy: -6)
        let o = GX.opaque(input)
        let fgV = GX.vec(fg), bgV = GX.vec(bg)
        var out: CIImage

        switch self {
        // MARK: Artistic
        case .coloredPencil:
            let w = v("width")
            let src = GX.blur(o, 0.6)
            let l = GX.lum(src)
            let e = GX.edgeMag(src, 1.2 + w * 0.08, blur: 0.5 + w * 0.12)
            let spw = 1.6 + w * 0.45
            let s1 = GX.strokes(R, angle: 55, length: 14 + w * 4, width: spw, seed: 1)
            let s2 = GX.strokes(R, angle: -35, length: 12 + w * 3, width: spw, seed: 2)
            let paperLevel = 0.6 + v("paper") / 50 * 0.4
            let paper = CIVector(x: CGFloat(bg.r * paperLevel), y: CGFloat(bg.g * paperLevel), z: CGFloat(bg.b * paperLevel), w: 1)
            out = GX.colorK(GX.kPencil, R, [src, l, s1, s2, e, Float(v("pressure")), paper], o)

        case .cutout:
            let levels = v("levels"), simp = v("simplicity"), fid = v("fidelity")
            var img = GX.blur(o, 0.8 + simp * 0.9 + (3 - fid) * 0.8)
            img = GX.kuwahara(img, radius: 2 + (3 - fid), rect: R)
            let chroma = GX.blur(img, 6 + simp * 1.5)
            img = GX.colorK(GX.kCutout, R, [img, chroma, Float(levels)], img)
            for _ in 0..<(1 + Int(simp / 3)) { img = img.applyingFilter("CIMedianFilter") }
            // smooth the jaggies then re-quantize edges softly
            out = img

        case .dryBrush:
            let size = v("size"), detail = v("detail"), tex = v("texture")
            var img = GX.kuwahara(o, radius: 2 + size * 0.9, rect: R)
            img = img.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2.0, kCIInputIntensityKey: detail / 10 * 0.9])
            img = GX.saturate(img, 1.12, contrast: 1.08)
            let n = GX.strokes(R, angle: 30, length: 10 + size * 2, width: 2 + size * 0.3, seed: 5)
            out = GX.colorK(GX.kStreak, R, [img, n, img, Float(0.08 + tex * 0.07), Float(0)], img)

        case .filmGrain:
            let n = GX.noise(seed: 3).applyingGaussianBlur(sigma: 0.45)
            let bl = GX.blur(o, 5)
            out = GX.colorK(GX.kFilmGrain, R, [o, n, bl, Float(v("grain") / 20 * 0.6), Float(v("area") / 20 * 0.75), Float(v("intensity") / 10 * 0.85)], o)

        case .fresco:
            let size = v("size"), detail = v("detail"), tex = v("texture")
            var img = GX.kuwahara(o, radius: 2 + size * 0.8, rect: R)
            let dark = img.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1.5 + size * 0.4])
            img = GX.colorK(GX.kFresco, R, [img, dark.applyingGaussianBlur(sigma: 1.2), Float(0.55 - detail * 0.025)], img)
            img = GX.saturate(img, 1.25, contrast: 1.3)
            let n = GX.valueNoise(R, scale: 5, octaves: 2, seed: 7)
            out = GX.colorK(GX.kTexMul, R, [img, n, Float(0.07 * tex)], img)

        case .neonGlow:
            let size = v("size"), br = v("brightness")
            let l = GX.lum(o)
            let base = GX.duo(l, fg, bg)
            let mask = size >= 0 ? l.inverted() : l
            let m = GX.colorK(GX.kStretch, R, [GX.blur(mask, 1 + abs(size) * 1.1), Float(1.6)], mask)
            let gc = GX.hueColor(v("hue"))
            out = GX.colorK(GX.kNeon, R, [base, m, gc, Float(br / 15 * 0.85)], o)

        case .paintDaubs:
            let size = v("size"), sharp = v("sharpness"), type = i("type")
            var src = o
            if type == 4 { src = GX.blur(src, 1.5 + size * 0.1) }
            var img = GX.kuwahara(src, radius: 1 + size * 0.45, rect: R)
            switch type {
            case 1: img = GX.blend(img, img.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 1.5 + size * 0.06]), 0.5)
            case 2: img = GX.blend(img, img.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1.5 + size * 0.06]), 0.5)
            default: break
            }
            let usmR = (type == 3 ? 4.0 : 2.0) + size * 0.05
            img = img.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: usmR, kCIInputIntensityKey: sharp / 10 * (type == 3 ? 1.6 : 1.0)])
            if type == 5 {
                let e = GX.edgeMag(img, 3, blur: 0.8)
                img = GX.colorK(GX.kAccent, R, [img, e, Float(1), Float(1.0)], img)
            }
            out = GX.saturate(img, 1.1, contrast: 1.05)

        case .paletteKnife:
            let size = v("size"), det = v("detail"), soft = v("softness")
            var img = GX.kuwahara(o, radius: 2 + size * 0.12 + (3 - det), rect: R)
            let w = Double(Int(3 + size * 0.5) | 1), h = Double(Int(1 + size * 0.2) | 1)
            let opened = img.applyingFilter("CIMorphologyRectangleMinimum", parameters: ["inputWidth": w, "inputHeight": h])
                .applyingFilter("CIMorphologyRectangleMaximum", parameters: ["inputWidth": w, "inputHeight": h])
            let closed = opened.applyingFilter("CIMorphologyRectangleMaximum", parameters: ["inputWidth": h, "inputHeight": w])
                .applyingFilter("CIMorphologyRectangleMinimum", parameters: ["inputWidth": h, "inputHeight": w])
            img = GX.blend(img, closed, 0.55 + (3 - det) * 0.15)
            if soft > 0 { img = GX.blur(img, soft * 0.5) }
            out = GX.saturate(img, 1.1, contrast: 1.08)

        case .plasticWrap:
            let smooth = v("smoothness"), detail = v("detail")
            let h = GX.blur(GX.lum(o), 1.5 + smooth * 0.9)
            out = GX.generalK(GX.kPlastic, R, pad: 2, [o, h, Float(10 + detail * 5), Float(v("strength") / 20 * 1.3)], o)

        case .posterEdges:
            let thick = v("thickness"), inten = v("intensity"), post = v("posterization")
            let src = GX.blur(o, 0.7)
            let poster = GX.posterize(src, levels: post + 2)
            var e = GX.edgeMag(src, 2.5, blur: 0.4)
            if thick > 0.5 { e = e.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: thick * 0.45]) }
            e = GX.blur(e, 0.5)
            out = GX.colorK(GX.kPosterEdge, R, [poster, e, Float(0.34 - inten * 0.024)], poster)

        case .roughPastels:
            let len = v("length"), detail = v("detail")
            let ang = 50.0
            let smear = GX.motion(o, 1 + len * 0.9, ang)
            let sp = GX.strokes(R, angle: ang, length: 8 + len * 3, width: 3.5, seed: 11)
            var img = GX.colorK(GX.kStreak, R, [smear, sp, o, Float(0.6), Float(detail / 20 * 0.6)], o)
            img = GX.saturate(img, 1.15, contrast: 1.05)
            let hm = GX.texture(R, type: Double(i("texture")), scale: 1, seed: 1)
            out = GX.relief(img, hm, light: CIVector(x: -0.6, y: 0.8), depth: 0.5 + v("relief") * 0.05, amount: 0.7, rect: R)

        case .smudgeStick:
            let len = v("length")
            let smear = GX.motion(o, 2 + len * 3.2, 45)
            let dk = smear.applyingFilter("CIDarkenBlendMode", parameters: [kCIInputBackgroundImageKey: o])
            let img = GX.blend(o, dk, 0.85)
            let bl = GX.blur(img, 4)
            let n = GX.noise(seed: 9).applyingGaussianBlur(sigma: 0.5)
            out = GX.colorK(GX.kFilmGrain, R, [img, n, bl, Float(0.06), Float(v("area") / 20 * 0.75), Float(v("intensity") / 10 * 0.85)], img)

        case .sponge:
            let size = v("size"), def = v("definition"), smooth = v("smoothness")
            let base = GX.saturate(GX.blur(o, 0.8 + size * 0.25), 1.15, contrast: 1.05)
            let n = GX.valueNoise(R, scale: 3.5 + size * 1.3, octaves: 1, seed: 13)
            out = GX.colorK(GX.kSponge, R, [base, n, Float(def / 25 * 0.6), Float(0.05 + smooth / 15 * 0.25)], base)

        case .underpainting:
            let size = v("size"), cov = v("coverage")
            var img = GX.kuwahara(o, radius: 1 + size * 0.2, rect: R)
            img = GX.blend(img, GX.blur(o, 1 + size * 0.4), 0.35)
            img = GX.saturate(img, 1.05, contrast: 0.92, brightness: 0.04)
            let hm = GX.texture(R, type: Double(i("texture")), scale: 1, seed: 3)
            out = GX.relief(img, hm, light: CIVector(x: -0.6, y: 0.8), depth: 0.8 + v("relief") * 0.1, amount: 0.3 + cov / 40 * 0.9, rect: R)

        case .watercolor:
            let detail = v("detail"), tex = v("texture")
            var s = GX.kuwahara(o, radius: 1.5 + (14 - detail) * 0.35, rect: R)
            s = GX.blur(s, 1.2)
            s = GX.noiseWarp(s, scale: 3, amp: 1 + tex, mode: 0, seed: 4, rect: R)
            let l = GX.lum(s)
            let l1 = GX.blur(l, 1.0), l2 = GX.blur(l, 3.5)
            let n = GX.valueNoise(R, scale: 5, octaves: 4, seed: 21)
            out = GX.colorK(GX.kWatercolor, R, [s, l1, l2, n, Float(v("shadow")), Float(tex)], s)

        // MARK: Brush Strokes
        case .accentedEdges:
            let w = v("width"), b = v("brightness"), smooth = v("smoothness")
            let src = GX.blur(o, 0.3 + smooth * 0.12)
            var e = GX.edgeMag(GX.blur(o, 0.5 + smooth * 0.2), 2.0 + w * 0.3, blur: 0.3 + w * 0.15)
            if w > 2 { e = e.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: (w - 2) * 0.35]) }
            let t = (b - 25) / 25
            out = GX.colorK(GX.kAccent, R, [src, GX.blur(e, 0.6), Float(b / 50), Float((0.45 + abs(t) * 0.8) * 4)], src)

        case .angledStrokes:
            let len = v("length"), bal = v("balance")
            let a = GX.motion(o, 1 + len * 0.45, 45), b = GX.motion(o, 1 + len * 0.45, -45)
            let sa = GX.strokes(R, angle: 45, length: 6 + len * 1.6, width: 3, seed: 31)
            let sb = GX.strokes(R, angle: -45, length: 6 + len * 1.6, width: 3, seed: 32)
            var img = GX.colorK(GX.kTwoStrokes, R, [a, b, sa, sb, GX.lum(GX.blur(o, 2)), Float(bal / 100), Float(0.35), Float(0)], o)
            img = img.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2.0, kCIInputIntensityKey: v("sharpness") / 10 * 1.2])
            out = img

        case .crosshatch:
            let len = v("length"), str = v("strength")
            let a = GX.motion(o, 1 + len * 0.35, 45), b = GX.motion(o, 1 + len * 0.35, -45)
            let sa = GX.strokes(R, angle: 45, length: 5 + len * 1.4, width: 2.5, seed: 41)
            let sb = GX.strokes(R, angle: -45, length: 5 + len * 1.4, width: 2.5, seed: 42)
            var img = GX.colorK(GX.kTwoStrokes, R, [a, b, sa, sb, GX.lum(o), Float(0.5), Float(0.3 + str * 0.18), Float(1)], o)
            img = GX.blend(o, img, 0.8)
            out = img.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 1.5, kCIInputIntensityKey: v("sharpness") / 20 * 1.5])

        case .darkStrokes:
            let a = GX.motion(o, 10, 45), b = GX.motion(o, 4, -45)
            let sa = GX.strokes(R, angle: 45, length: 26, width: 3, seed: 51)
            let sb = GX.strokes(R, angle: -45, length: 10, width: 3, seed: 52)
            out = GX.colorK(GX.kDarkStrokes, R, [a, b, sa, sb, GX.lum(GX.blur(o, 1.5)),
                                                 Float(0.25 + v("balance") * 0.05), Float(v("black") / 10 * 0.9), Float(v("white") / 10 * 0.8)], o)

        case .inkOutlines:
            let len = v("length")
            let st = GX.blend(o, GX.motion(o, 1 + len * 0.6, 45), 0.6)
            let l = GX.lum(o)
            let sp = GX.strokes(R, angle: 45, length: 6 + len * 2, width: 2.5, seed: 61)
            out = GX.colorK(GX.kInk, R, [st, GX.blur(l, 0.8), GX.blur(l, 2.8), sp, Float(v("dark") / 50 * 0.9), Float(v("light") / 50 * 0.7)], o)

        case .spatter:
            let rad = v("radius"), smooth = v("smoothness")
            var img = GX.noiseWarp(o, scale: 0.7 + smooth * 0.12, amp: rad * 0.9, mode: 0, seed: 71, rect: R)
            if smooth > 8 { img = img.applyingFilter("CIMedianFilter") }
            out = img

        case .sprayedStrokes:
            let len = v("length"), rad = v("radius")
            let ang = [45.0, 0, 135, 90][i("direction")]
            let warped = GX.noiseWarp(o, scale: 0.9, amp: rad * 0.7, mode: 0, seed: 81, rect: R)
            let mb = GX.motion(warped, 1 + len * 1.4, ang)
            let sp = GX.strokes(R, angle: ang, length: 8 + len * 3, width: 3, seed: 82)
            out = GX.colorK(GX.kStreak, R, [mb, sp, warped, Float(0.4), Float(0.25)], o)

        case .sumie:
            let w = v("width"), pr = v("pressure"), con = v("contrast")
            var img = GX.kuwahara(o, radius: 1 + w * 0.3, rect: R)
            img = GX.blur(img, 0.6 + w * 0.12)
            let l = GX.lum(img)
            let ink = GX.blur(l.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1 + pr * 0.25]), 1.5 + w * 0.3)
            let se = GX.colorK(GX.kSumie, R, [img, ink, Float(con / 40), Float(pr / 15)], img)
            let sp = GX.strokes(R, angle: 60, length: 20 + w * 3, width: 3 + w * 0.3, seed: 77)
            out = GX.colorK(GX.kStreak, R, [GX.motion(se, 2 + w * 0.4, 60), sp, se, Float(0.35), Float(0.3)], se)

        // MARK: Distort
        case .diffuseGlow:
            let bl = GX.blur(o, 4)
            let n = GX.noise(seed: 91)
            out = GX.colorK(GX.kDiffuse, R, [o, bl, n, bgV, Float(0.28 + v("clear") / 20 * 0.55), Float(v("glow") / 20 * 1.4), Float(v("graininess") / 10)], o)

        case .glassDistort:
            let type = [4.0, 2, 5, 6][i("texture")]
            var hm = GX.texture(R.insetBy(dx: -40, dy: -40), type: type, scale: v("scaling") / 100, seed: 2)
            hm = GX.blur(hm, 0.5 + v("smoothness") * 0.45)
            let amt = v("distortion") * (type == 4 ? 8.0 : 5.0) * (1 + v("smoothness") * 0.3)
            out = GX.generalK(GX.kGlassWarp, R, pad: CGFloat(amt + 4), [o, hm, Float(amt)], o, roiPerImage: true)

        case .oceanRipple:
            let size = v("size"), mag = v("magnitude")
            let scale = 5 + size * 2.2
            out = GX.noiseWarp(o, scale: scale, amp: mag * 0.9, mode: 1, seed: 101, rect: R)

        // MARK: Sketch
        case .basRelief:
            let detail = v("detail"), smooth = v("smoothness")
            let h = GX.blur(GX.lum(o), 0.6 + smooth * 0.6 + (15 - detail) * 0.25)
            let t = GX.shade(h, light: GX.light(i("light")), depth: 4 + detail * 1.2, gain: 1.4, base: 0.45, rect: R)
            out = GX.duo(t, fg, bg)

        case .chalkCharcoal:
            let l = GX.lum(GX.blur(o, 1.2))
            let s1 = GX.strokes(R, angle: 45, length: 16, width: 3.2, seed: 111)
            let s2 = GX.strokes(R, angle: -45, length: 20, width: 3.6, seed: 112)
            let t = GX.colorK(GX.kChalk, R, [l, s1, s2, Float(v("charcoal") / 20), Float(v("chalk") / 20), Float(v("pressure"))], l)
            out = GX.duo(t, fg, bg)

        case .charcoal:
            let th = v("thickness"), det = v("detail")
            let l = GX.lum(GX.blur(o, 0.8 + (5 - det) * 0.6))
            let e = GX.edgeMag(GX.blur(o, 1.0 + (5 - det) * 0.4), 1.6 + det * 0.2, blur: 0.8 + th * 0.3)
            let sp = GX.strokes(R, angle: 45, length: 14 + th * 2, width: 2.2 + th * 0.9, seed: 121)
            let t = GX.colorK(GX.kCharcoal, R, [l, sp, e, Float(v("balance") / 100), Float(th)], l)
            out = GX.duo(t, fg, bg)

        case .chrome:
            let det = v("detail"), smooth = v("smoothness")
            let h = GX.blur(GX.lum(o), 1.5 + smooth * 1.1 + (10 - det) * 0.35)
            out = GX.generalK(GX.kChrome, R, pad: 2, [h, Float(18 + det * 6)], o)

        case .conteCrayon:
            let l = GX.lum(GX.blur(o, 0.8))
            let hm = GX.texture(R, type: Double(i("texture")), scale: 1, seed: 5)
            let g = GX.colorK(GX.kMixGray, R, [hm, GX.noise(seed: 131), Float(0.35)], hm)
            let t = GX.colorK(GX.kConte, R, [l, g, Float(v("fgLevel") / 11), Float(v("bgLevel") / 7)], l)
            out = GX.relief(GX.duo(t, fg, bg), hm, light: CIVector(x: -0.6, y: 0.8), depth: 0.8 + v("relief") * 0.12, amount: 0.6, rect: R)

        case .graphicPen:
            let len = v("length")
            let ang = [45.0, 0, 135, 90][i("direction")]
            let l = GX.lum(GX.blur(o, 0.8))
            let sp = GX.strokes(R, angle: ang, length: 5 + len * 3.2, width: 2.6, seed: 141)
            let t = GX.colorK(GX.kPen, R, [l, sp, Float((v("balance") - 50) / 100 * 0.9)], l)
            out = GX.duo(GX.blur(t, 0.35), fg, bg)

        case .halftonePattern:
            let size = v("size"), con = v("contrast")
            let l = GX.lum(o).applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + con / 25, kCIInputSaturationKey: 0])
            let period = 3.5 + size * 1.7
            let t = GX.colorK(GX.kHalftone, R, [l, Float(v("pattern")), Float(period), CIVector(x: canvas.midX, y: canvas.midY)], l)
            out = GX.duo(t, fg, bg)

        case .notePaper:
            let l = GX.lum(GX.blur(o, 1.5))
            let m = GX.colorK(GX.kThresh, R, [l, Float(v("balance") / 50), Float(0.04), Float(1)], l)
            let mb = GX.blur(m, 1.6)
            let n = GX.noise(seed: 151).applyingGaussianBlur(sigma: 0.6)
            let t = GX.colorK(GX.kNote, R, [mb, n, Float(v("graininess") / 20 * 0.35)], mb)
            let fibers = GX.colorK(GX.kMixGray, R, [mb, GX.valueNoise(R, scale: 1.4, octaves: 2, seed: 152), Float(0.08)], mb)
            out = GX.relief(GX.duo(t, fg, bg), fibers, light: CIVector(x: -0.6, y: 0.8), depth: 1 + v("relief") * 0.35, amount: 0.9, rect: R)

        case .photocopy:
            let det = v("detail"), dark = v("darkness")
            let l = GX.lum(GX.blur(o, 0.6))
            let b = GX.blur(l, 1.5 + det * 0.9)
            let t = GX.colorK(GX.kPhotocopy, R, [l, b, Float(2 + dark * 0.55)], l)
            out = GX.duo(t, fg, bg)

        case .plaster:
            let l = GX.lum(GX.blur(o, 1))
            let th = 0.12 + v("balance") / 50 * 0.6
            let m = GX.colorK(GX.kThresh, R, [l, Float(th), Float(0.08), Float(1)], l)   // 1 where dark (raised)
            let h = GX.blur(m, 2 + v("smoothness") * 1.3)
            let t = GX.shade(h, light: GX.light(i("light")), depth: 18, gain: 1.3, base: -0.25, rect: R)
            out = GX.duo(t, fg, bg)

        case .reticulation:
            let l = GX.lum(o)
            let n = GX.noise(seed: 161).applyingGaussianBlur(sigma: 0.7)
            let n2 = GX.colorK(GX.kStretch, R, [n, Float(3.5)], n)
            let th = 0.5 + (v("fgLevel") - 40) / 50 * 0.3 - (v("bgLevel") - 5) / 50 * 0.3
            let t = GX.colorK(GX.kNoisyThresh, R, [l, n2, Float(0.3 + v("density") / 50 * 1.1), Float(th - 0.05), Float(0.08)], l)
            out = GX.duo(t, fg, bg)

        case .stamp:
            let l = GX.lum(GX.blur(o, 0.5 + v("smoothness") * 0.45))
            let t = GX.colorK(GX.kThresh, R, [l, Float(v("balance") / 50), Float(0.02), Float(0)], l)
            out = GX.duo(t, fg, bg)

        case .tornEdges:
            let smooth = v("smoothness")
            let l = GX.lum(GX.blur(o, 1))
            let n = GX.colorK(GX.kMixGray, R, [GX.valueNoise(R, scale: 3, octaves: 3, seed: 171), GX.noise(seed: 172), Float(0.35)], l)
            var nv = GX.colorK(GX.kAddGray, R, [l, n, Float(0.55 - smooth * 0.02)], l)
            nv = GX.blur(nv, 0.4 + smooth * 0.12)
            let t = GX.colorK(GX.kThresh, R, [nv, Float(v("balance") / 50), Float(0.3 / v("contrast")), Float(0)], l)
            out = GX.duo(t, fg, bg)

        case .waterPaper:
            let fib = v("fiber")
            let sparse = GX.colorK(GX.kSparse, R, [GX.noise(seed: 181), Float(0.94)], o)
            let f1 = GX.motion(sparse, fib * 0.8, 20), f2 = GX.motion(sparse.translated(37, 11), fib * 0.8, 110), f3 = GX.motion(sparse.translated(-13, 29), fib * 0.6, 160)
            let fibers = f1.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: f2])
                .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: f3])
            var img = GX.noiseWarp(o, scale: 2.5, amp: 2.5, mode: 0, seed: 182, rect: R)
            img = GX.blur(img, 1.6)
            let bri = (v("brightness") - 60) / 100 * 0.8 + 0.06, con = 0.55 + v("contrast") / 100 * 0.7
            img = GX.saturate(img, 1.2, contrast: con, brightness: bri)
            let blot = GX.valueNoise(R, scale: 9, octaves: 3, seed: 183)
            out = GX.colorK(GX.kFiber, R, [img, fibers, blot, Float(14 / sqrt(max(fib, 3)))], img)

        // MARK: Stylize
        case .glowingEdges:
            let w = v("width"), br = v("brightness"), smooth = v("smoothness")
            let src = GX.blur(o, 0.5 + smooth * 0.3)
            var e = src.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1.0 + br * 0.9])
            if w > 1 { e = e.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: (w - 1) * 0.5]) }
            e = GX.opaqueRGB(e).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 4, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 4, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 4, w: 0)]).applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.8])
            let glow = GX.blur(e, 1 + w * 0.6)
            out = e.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: glow.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.7, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.7, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.7, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])])
            out = GX.opaqueRGB(out)

        // MARK: Texture
        case .craquelure:
            let spacing = v("spacing"), depth = v("depth"), bright = v("brightness")
            let h = GX.generate(GX.kCrack, R, [Float(14 + spacing * 2.2), Float(1.2 + depth * 0.35), Float(3)])
            let base = GX.saturate(o, 1.0, contrast: 1.0, brightness: (bright - 5) / 10 * 0.12)
            let lit = GX.relief(base, h, light: CIVector(x: -0.6, y: 0.8), depth: 1.2 + depth * 0.4, amount: 0.8, rect: R)
            out = GX.colorK(GX.kCrackDarken, R, [lit, h.clampedToExtent(), Float(0.1 + depth * 0.035)], lit)

        case .grain:
            out = GX.grain(o, type: i("type"), intensity: v("intensity") / 100, contrast: v("contrast") / 100, fg: fgV, bg: bgV, rect: R)

        case .mosaicTiles:
            let size = 8 + v("size") * 2.2, grout = v("grout")
            let h = GX.generate(GX.kTileHeight, R, [Float(size), Float(0.8 + grout * 0.7), Float(0), Float(5)])
            let lit = GX.relief(o, h, light: CIVector(x: -0.6, y: 0.8), depth: 3, amount: 0.8, rect: R)
            out = GX.colorK(GX.kGrout, R, [lit, h.clampedToExtent(), o, Float(v("lighten") / 10)], lit)

        case .patchwork:
            let size = 6 + v("size") * 2.6
            let col = GX.generalK(GX.kCellColor, R, pad: CGFloat(size + 2), [GX.blur(o, size * 0.25), Float(size)], o)
            let h = GX.generate(GX.kTileHeight, R, [Float(size), Float(1), Float(1), Float(9)])
            out = GX.relief(col, h, light: CIVector(x: -0.6, y: 0.8), depth: 1 + v("relief") * 0.35, amount: 1.0, rect: R)

        case .stainedGlass:
            let size = 7 + v("cell") * 2.4
            let border = 0.8 + v("border") * 0.75
            let src = GX.saturate(GX.blur(o, size * 0.2), 1.35, contrast: 1.1)
            let radius = max(canvas.width, canvas.height) * 0.75
            out = GX.generalK(GX.kStainedGlass, R, pad: CGFloat(size * 2.5), [src, Float(size), Float(border), fgV,
                                                                              CIVector(x: canvas.midX, y: canvas.midY), Float(radius), Float(v("light") / 10)], o)

        case .texturizer:
            let hm = GX.texture(R, type: Double(i("texture")), scale: v("scaling") / 100, seed: 1)
            out = GX.relief(o, hm, light: GX.light(i("light")), depth: 0.8 + v("relief") * 0.3, amount: 1.1, rect: R)
        }
        return out.cropped(to: ext).masked(byAlphaOf: input)
    }
}

// MARK: - Helpers & kernels

fileprivate enum GX {
    static func vec(_ c: RGBA) -> CIVector { CIVector(x: CGFloat(c.r), y: CGFloat(c.g), z: CGFloat(c.b), w: 1) }

    /// Unpremultiplied, opaque, clamped-to-extent copy of the input.
    static func opaque(_ input: CIImage) -> CIImage {
        input.applyingFilter("CIUnpremultiply").applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).clampedToExtent()
    }

    static func opaqueRGB(_ img: CIImage) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }

    static func lum(_ img: CIImage) -> CIImage {
        let w = CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0)
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": w, "inputGVector": w, "inputBVector": w,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    static func blur(_ img: CIImage, _ sigma: Double) -> CIImage {
        sigma < 0.05 ? img : img.applyingGaussianBlur(sigma: sigma)
    }

    static func motion(_ img: CIImage, _ radius: Double, _ angleDeg: Double) -> CIImage {
        radius < 0.5 ? img : img.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: angleDeg * .pi / 180])
    }

    /// a * (1 - t) + b * t
    static func blend(_ a: CIImage, _ b: CIImage, _ t: Double) -> CIImage {
        colorK(kLerp, a.extent.isInfinite ? b.extent : a.extent, [a, b, Float(t)], a)
    }

    static func saturate(_ img: CIImage, _ sat: Double, contrast: Double = 1, brightness: Double = 0) -> CIImage {
        img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: sat, kCIInputContrastKey: contrast, kCIInputBrightnessKey: brightness])
    }

    /// Maps gray t: 0 → a, 1 → b (opaque).
    static func duo(_ t: CIImage, _ a: RGBA, _ b: RGBA) -> CIImage {
        t.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(b.r - a.r), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: CGFloat(b.g - a.g), y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: CGFloat(b.b - a.b), y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: CGFloat(a.r), y: CGFloat(a.g), z: CGFloat(a.b), w: 1),
        ])
    }

    static func hueColor(_ hueDeg: Double) -> CIVector {
        let h = (hueDeg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (1, x, 0)
        case 1: (r, g, b) = (x, 1, 0)
        case 2: (r, g, b) = (0, 1, x)
        case 3: (r, g, b) = (0, x, 1)
        case 4: (r, g, b) = (x, 0, 1)
        default: (r, g, b) = (1, 0, x)
        }
        return CIVector(x: CGFloat(r), y: CGFloat(g), z: CGFloat(b), w: 1)
    }

    static func light(_ idx: Int) -> CIVector {
        let dirs: [(Double, Double)] = [(0, -1), (-1, -1), (-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1)]
        let d = dirs[min(max(idx, 0), 7)]
        let len = sqrt(d.0 * d.0 + d.1 * d.1)
        return CIVector(x: CGFloat(d.0 / len), y: CGFloat(d.1 / len))
    }

    /// Per-pixel white noise (infinite).
    static func noise(seed: Double) -> CIImage {
        CIFilter(name: "CIRandomGenerator")!.outputImage!.translated(CGFloat(seed * 173).rounded(), CGFloat(seed * 97).rounded())
    }

    static func edgeMag(_ img: CIImage, _ intensity: Double, blur b: Double) -> CIImage {
        let e = lum(img.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: intensity]))
        return b > 0.05 ? e.applyingGaussianBlur(sigma: b) : e
    }

    static func posterize(_ img: CIImage, levels: Double) -> CIImage {
        colorK(kPosterRGB, img.extent, [img, Float(levels)], img)
    }

    // MARK: Kernel application

    static func colorK(_ k: CIColorKernel?, _ rect: CGRect, _ args: [Any], _ fallback: CIImage) -> CIImage {
        guard let k, let out = k.apply(extent: rect, arguments: args) else { return fallback }
        return out.extent.isInfinite ? out : out.clampedToExtent()
    }

    static func generalK(_ k: CIKernel?, _ rect: CGRect, pad: CGFloat, _ args: [Any], _ fallback: CIImage, roiPerImage: Bool = false) -> CIImage {
        guard let k, let out = k.apply(extent: rect, roiCallback: { idx, r in
            if roiPerImage && idx > 0 { return r.insetBy(dx: -3, dy: -3) }
            return r.insetBy(dx: -pad, dy: -pad)
        }, arguments: args) else { return fallback }
        return out.clampedToExtent()
    }

    static func generate(_ k: CIKernel?, _ rect: CGRect, _ args: [Any]) -> CIImage {
        guard let k, let out = k.apply(extent: rect, roiCallback: { _, r in r }, arguments: args) else {
            return CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: rect).clampedToExtent()
        }
        return out.clampedToExtent()
    }

    static func kuwahara(_ img: CIImage, radius: Double, rect: CGRect) -> CIImage {
        let r = max(1, radius.rounded())
        let step = max(1, (r / 5).rounded(.up))
        return generalK(kKuwahara, rect, pad: CGFloat(r + 2), [img, Float(r), Float(step)], img)
    }

    static func strokes(_ rect: CGRect, angle: Double, length: Double, width: Double, seed: Double) -> CIImage {
        generate(kStrokes, rect, [Float(angle * .pi / 180), Float(max(length, 2)), Float(max(width, 1)), Float(seed)])
    }

    static func valueNoise(_ rect: CGRect, scale: Double, octaves: Double, seed: Double) -> CIImage {
        generate(kNoise, rect, [Float(max(scale, 0.3)), Float(octaves), Float(seed)])
    }

    static func texture(_ rect: CGRect, type: Double, scale: Double, seed: Double) -> CIImage {
        generate(kTexture, rect, [Float(type), Float(max(scale, 0.2)), Float(seed)])
    }

    static func relief(_ img: CIImage, _ hm: CIImage, light: CIVector, depth: Double, amount: Double, rect: CGRect) -> CIImage {
        generalK(kRelief, rect, pad: 2, [img, hm, light, Float(depth), Float(amount)], img)
    }

    static func shade(_ hm: CIImage, light: CIVector, depth: Double, gain: Double, base: Double, rect: CGRect) -> CIImage {
        generalK(kShade, rect, pad: 2, [hm, light, Float(depth), Float(gain), Float(base)], hm)
    }

    static func noiseWarp(_ img: CIImage, scale: Double, amp: Double, mode: Double, seed: Double, rect: CGRect) -> CIImage {
        if amp < 0.01 { return img }
        return generalK(kNoiseWarp, rect, pad: CGFloat(amp * 3 + 3), [img, Float(scale), Float(amp), Float(mode), Float(seed)], img)
    }

    static func grain(_ o: CIImage, type: Int, intensity: Double, contrast: Double, fg: CIVector, bg: CIVector, rect: CGRect) -> CIImage {
        let con = 0.6 + contrast * 0.8
        let img = saturate(o, 1, contrast: type == 4 ? con * 1.35 : con)
        var n = noise(seed: 191)
        var mode: Float = 0
        var amt = intensity
        switch type {
        case 0: amt *= 0.7                                          // Regular
        case 1: n = n.applyingGaussianBlur(sigma: 0.9); amt *= 0.9  // Soft
        case 2: mode = 1                                            // Sprinkles
        case 3: n = colorK(kStretch, rect, [n.applyingGaussianBlur(sigma: 1.3), Float(4)], n); amt *= 0.8   // Clumped
        case 4: amt *= 0.6                                          // Contrasty
        case 5: n = n.transformed(by: CGAffineTransform(scaleX: 2.5, y: 2.5)); amt *= 0.8   // Enlarged
        case 6: mode = 2                                            // Stippled
        case 7: n = colorK(kStretch, rect, [motion(n, 6, 0), Float(3.5)], n); amt *= 0.8     // Horizontal
        case 8: n = colorK(kStretch, rect, [motion(n, 6, 90), Float(3.5)], n); amt *= 0.8    // Vertical
        default: mode = 3                                           // Speckle
        }
        return colorK(kGrain, rect, [img, n, Float(amt), mode, fg, bg], img)
    }

    // MARK: Kernel sources

    static let lib = """
    float h12(vec2 p) { vec3 p3 = fract(vec3(p.x, p.y, p.x) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
    vec2 h22(vec2 p) { vec3 p3 = fract(vec3(p.x, p.y, p.x) * vec3(0.1031, 0.1030, 0.0973)); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.xx + p3.yz) * p3.zy); }
    float vnoise(vec2 p) {
        vec2 ip = floor(p); vec2 f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
        float a = h12(ip); float b = h12(ip + vec2(1.0, 0.0)); float c = h12(ip + vec2(0.0, 1.0)); float d = h12(ip + vec2(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }
    float fbm(vec2 p) {
        float v = 0.0; float a = 0.5; float tot = 0.0;
        for (float o = 0.0; o < 4.5; o += 1.0) { v += a * vnoise(p); tot += a; p = p * 2.03 + vec2(17.1, 9.3); a *= 0.5; }
        return v / tot;
    }
    float vedge(vec2 p) {
        vec2 ip = floor(p); vec2 fp = fract(p);
        vec2 mg = vec2(0.0); vec2 mr = vec2(0.0); float md = 8.0;
        for (float j = -1.0; j <= 1.0; j += 1.0) {
            for (float i = -1.0; i <= 1.0; i += 1.0) {
                vec2 g = vec2(i, j);
                vec2 r = g + 0.1 + 0.8 * h22(ip + g) - fp;
                float d = dot(r, r);
                if (d < md) { md = d; mr = r; mg = g; }
            }
        }
        float ed = 8.0;
        for (float j = -2.0; j <= 2.0; j += 1.0) {
            for (float i = -2.0; i <= 2.0; i += 1.0) {
                vec2 g = mg + vec2(i, j);
                vec2 r = g + 0.1 + 0.8 * h22(ip + g) - fp;
                vec2 dr = r - mr;
                if (dot(dr, dr) > 0.00001) { ed = min(ed, dot(0.5 * (mr + r), normalize(dr))); }
            }
        }
        return ed;
    }
    float lumv(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

    """

    static func gk(_ src: String) -> CIKernel? {
        let k = CIKernel(source: lib + src)
        if k == nil { NSLog("GalleryFilter: kernel failed to compile: %@", String(src.prefix(60))) }
        return k
    }
    static func ck(_ src: String) -> CIColorKernel? {
        let k = CIColorKernel(source: lib + src)
        if k == nil { NSLog("GalleryFilter: color kernel failed to compile: %@", String(src.prefix(60))) }
        return k
    }

    static let kLerp = ck("""
    kernel vec4 lerpK(__sample a, __sample b, float t) { return vec4(mix(a.rgb, b.rgb, t), 1.0); }
    """)

    static let kCutout = ck("""
    kernel vec4 cutoutK(__sample c, __sample ch, float levels) {
        float l = lumv(c.rgb);
        float n = levels - 1.0;
        float q = floor(l * n + 0.5) / n;
        q = mix(q, l, 0.25);
        float lc = lumv(ch.rgb);
        vec3 chroma = ch.rgb - vec3(lc);
        vec3 r = clamp(vec3(q) + chroma * 1.15, 0.0, 1.0);
        return vec4(r, 1.0);
    }
    """)

    static let kPosterRGB = ck("""
    kernel vec4 posterRGB(__sample c, float levels) {
        float n = levels - 1.0;
        return vec4(floor(clamp(c.rgb, 0.0, 1.0) * n + 0.5) / n, 1.0);
    }
    """)

    static let kKuwahara = gk("""
    kernel vec4 kuwaharaS(sampler src, float radius, float stp) {
        vec2 dc = destCoord();
        vec3 m0 = vec3(0.0); vec3 m1 = vec3(0.0); vec3 m2 = vec3(0.0); vec3 m3 = vec3(0.0);
        vec3 s0 = vec3(0.0); vec3 s1 = vec3(0.0); vec3 s2 = vec3(0.0); vec3 s3 = vec3(0.0);
        float n = 0.0;
        for (float j = 0.0; j <= radius + 0.01; j += stp) {
            for (float i = 0.0; i <= radius + 0.01; i += stp) {
                vec3 c;
                c = sample(src, samplerTransform(src, dc + vec2(-i, -j))).rgb; m0 += c; s0 += c * c;
                c = sample(src, samplerTransform(src, dc + vec2(i, -j))).rgb; m1 += c; s1 += c * c;
                c = sample(src, samplerTransform(src, dc + vec2(i, j))).rgb; m2 += c; s2 += c * c;
                c = sample(src, samplerTransform(src, dc + vec2(-i, j))).rgb; m3 += c; s3 += c * c;
                n += 1.0;
            }
        }
        m0 /= n; m1 /= n; m2 /= n; m3 /= n;
        vec3 v0 = abs(s0 / n - m0 * m0); vec3 v1 = abs(s1 / n - m1 * m1);
        vec3 v2 = abs(s2 / n - m2 * m2); vec3 v3 = abs(s3 / n - m3 * m3);
        float q0 = v0.r + v0.g + v0.b; float q1 = v1.r + v1.g + v1.b;
        float q2 = v2.r + v2.g + v2.b; float q3 = v3.r + v3.g + v3.b;
        vec3 res = m0; float best = q0;
        if (q1 < best) { best = q1; res = m1; }
        if (q2 < best) { best = q2; res = m2; }
        if (q3 < best) { best = q3; res = m3; }
        return vec4(res, 1.0);
    }
    """)

    static let kStrokes = gk("""
    kernel vec4 strokePattern(float ang, float len, float wid, float seed) {
        vec2 p = destCoord();
        float ca = cos(ang); float sa = sin(ang);
        float u = p.x * ca + p.y * sa;
        float v = -p.x * sa + p.y * ca;
        float line = floor(v / wid);
        float fv = fract(v / wid);
        float jl = len * (0.7 + 0.6 * h12(vec2(line, seed + 3.0)));
        float off = h12(vec2(line, seed)) * jl;
        float seg = floor((u + off) / jl);
        float fu = fract((u + off) / jl);
        float val = h12(vec2(line * 1.37 + seed, seg + 0.5));
        float prof = sin(3.14159 * fv);
        float taper = smoothstep(0.0, 0.12, fu) * (1.0 - smoothstep(0.88, 1.0, fu));
        return vec4(val, prof * (0.35 + 0.65 * taper), 0.0, 1.0);
    }
    """)

    static let kNoise = gk("""
    kernel vec4 valueNoise(float scale, float oct, float seed) {
        vec2 p = destCoord() / scale + vec2(seed * 31.7, seed * 17.3);
        float v = 0.0; float a = 0.5; float tot = 0.0;
        for (float o = 0.0; o < oct; o += 1.0) { v += a * vnoise(p); tot += a; p = p * 2.03 + vec2(17.1, 9.3); a *= 0.5; }
        v = v / tot;
        v = clamp((v - 0.5) * (1.0 + oct * 0.25) + 0.5, 0.0, 1.0);
        return vec4(vec3(v), 1.0);
    }
    """)

    static let kTexture = gk("""
    kernel vec4 texHeight(float type, float scale, float seed) {
        vec2 p = destCoord() / scale + vec2(seed * 13.7, seed * 7.3);
        float h = 0.5;
        if (type < 0.5) {
            vec2 bs = vec2(56.0, 24.0);
            vec2 b = p / bs;
            float row = floor(b.y);
            b.x += mod(row, 2.0) * 0.5;
            vec2 f = fract(b);
            vec2 dd = min(f, 1.0 - f) * bs;
            float e = min(dd.x, dd.y) + (vnoise(p * 0.45) - 0.5) * 1.6;
            float mortar = smoothstep(1.0, 4.0, e);
            float rough = fbm(p * 0.16);
            h = mortar * (0.62 + 0.28 * rough + 0.1 * h12(floor(b))) + (1.0 - mortar) * 0.12 * vnoise(p * 0.8);
        } else if (type < 2.5) {
            float cs = type < 1.5 ? 7.0 : 3.6;
            vec2 u = p / cs;
            vec2 cid = floor(u);
            vec2 f = fract(u);
            float nx = vnoise(vec2(cid.x * 3.1, p.y * 0.07));
            float ny = vnoise(vec2(p.x * 0.07, cid.y * 3.1 + 50.0));
            float wob = type < 1.5 ? 0.9 : 0.4;
            float hx = pow(sin(3.14159 * f.x), 0.6 + wob * nx);
            float hy = pow(sin(3.14159 * f.y), 0.6 + wob * ny);
            float over = mod(cid.x + cid.y, 2.0);
            float bx = 0.65 + 0.35 * sin(3.14159 * f.y);
            float by = 0.65 + 0.35 * sin(3.14159 * f.x);
            if (over > 0.5) { h = max(hx * bx, hy * 0.5); } else { h = max(hy * by, hx * 0.5); }
            h = h * (0.75 + 0.25 * vnoise(p * (type < 1.5 ? 0.8 : 1.3)));
        } else if (type < 3.5) {
            h = 0.5 * fbm(p / 9.0) + 0.3 * vnoise(p / 1.7) + 0.2 * h12(floor(p));
        } else if (type < 4.5) {
            vec2 f = fract(p / 26.0);
            vec2 d = min(f, 1.0 - f) * 26.0;
            h = smoothstep(0.0, 8.0, min(d.x, d.y));
        } else if (type < 5.5) {
            h = 0.55 * vnoise(p / 2.2) + 0.45 * vnoise(p / 5.5 + 13.0);
        } else {
            vec2 f = fract(p / 12.0) - 0.5;
            float r = length(f) * 2.0;
            h = sqrt(max(0.0, 1.0 - r * r));
        }
        return vec4(vec3(h), 1.0);
    }
    """)

    static let kRelief = gk("""
    kernel vec4 relief(sampler img, sampler hm, vec2 L, float depth, float amount) {
        vec2 dc = destCoord();
        vec4 c = sample(img, samplerTransform(img, dc));
        float l = sample(hm, samplerTransform(hm, dc + vec2(-1.0, 0.0))).r;
        float r = sample(hm, samplerTransform(hm, dc + vec2(1.0, 0.0))).r;
        float b = sample(hm, samplerTransform(hm, dc + vec2(0.0, -1.0))).r;
        float t = sample(hm, samplerTransform(hm, dc + vec2(0.0, 1.0))).r;
        vec2 g = vec2(r - l, t - b) * 0.5 * depth;
        vec3 n = normalize(vec3(-g, 1.0));
        vec3 ld = normalize(vec3(L, 1.0));
        float s = clamp((dot(n, ld) / ld.z - 1.0) * amount, -0.65, 0.6);
        vec3 rgb = c.rgb;
        if (s > 0.0) { rgb = mix(rgb, vec3(1.0), min(s * 1.4, 1.0)); } else { rgb = rgb * max(1.0 + s, 0.0); }
        return vec4(rgb, 1.0);
    }
    """)

    static let kShade = gk("""
    kernel vec4 shadeK(sampler hm, vec2 L, float depth, float gain, float base) {
        vec2 dc = destCoord();
        float l = sample(hm, samplerTransform(hm, dc + vec2(-1.0, 0.0))).r;
        float r = sample(hm, samplerTransform(hm, dc + vec2(1.0, 0.0))).r;
        float b = sample(hm, samplerTransform(hm, dc + vec2(0.0, -1.0))).r;
        float t = sample(hm, samplerTransform(hm, dc + vec2(0.0, 1.0))).r;
        float hc = sample(hm, samplerTransform(hm, dc)).r;
        vec2 g = vec2(r - l, t - b) * 0.5 * depth;
        vec3 n = normalize(vec3(-g, 1.0));
        vec3 ld = normalize(vec3(L, 1.0));
        float s = dot(n, ld) / ld.z - 1.0;
        float v = 0.5 + s * gain + (hc - 0.5) * base;
        return vec4(vec3(clamp(v, 0.0, 1.0)), 1.0);
    }
    """)

    static let kGlassWarp = gk("""
    kernel vec4 glassWarp(sampler src, sampler hm, float amount) {
        vec2 dc = destCoord();
        float l = sample(hm, samplerTransform(hm, dc + vec2(-1.0, 0.0))).r;
        float r = sample(hm, samplerTransform(hm, dc + vec2(1.0, 0.0))).r;
        float b = sample(hm, samplerTransform(hm, dc + vec2(0.0, -1.0))).r;
        float t = sample(hm, samplerTransform(hm, dc + vec2(0.0, 1.0))).r;
        vec2 g = clamp(vec2(r - l, t - b) * 0.5, -1.0, 1.0);
        return sample(src, samplerTransform(src, dc + g * amount));
    }
    """)

    static let kNoiseWarp = gk("""
    kernel vec4 noiseWarp(sampler src, float scale, float amp, float mode, float seed) {
        vec2 dc = destCoord();
        vec2 p = dc / scale + vec2(seed * 3.7, seed * 1.9);
        vec2 off;
        if (mode < 0.5) {
            off = (vec2(vnoise(p), vnoise(p + vec2(31.7, 11.3))) - 0.5) * 2.0 * amp;
        } else {
            float e = 0.25;
            vec2 q = p * 2.0 + 5.0;
            float hx = vnoise(p + vec2(e, 0.0)) - vnoise(p - vec2(e, 0.0)) + 0.5 * (vnoise(q + vec2(2.0 * e, 0.0)) - vnoise(q - vec2(2.0 * e, 0.0)));
            float hy = vnoise(p + vec2(0.0, e)) - vnoise(p - vec2(0.0, e)) + 0.5 * (vnoise(q + vec2(0.0, 2.0 * e)) - vnoise(q - vec2(0.0, 2.0 * e)));
            off = clamp(vec2(hx, hy) / (2.0 * e) * amp * 0.8, -3.0 * amp, 3.0 * amp);
        }
        return sample(src, samplerTransform(src, dc + off));
    }
    """)

    static let kStainedGlass = gk("""
    kernel vec4 stainedGlass(sampler src, float size, float border, vec4 lead, vec2 center, float radius, float light) {
        vec2 dc = destCoord();
        vec2 p = dc / size;
        vec2 ip = floor(p); vec2 fp = fract(p);
        vec2 mg = vec2(0.0); vec2 mr = vec2(0.0); float md = 8.0;
        for (float j = -1.0; j <= 1.0; j += 1.0) {
            for (float i = -1.0; i <= 1.0; i += 1.0) {
                vec2 g = vec2(i, j);
                vec2 r = g + 0.1 + 0.8 * h22(ip + g) - fp;
                float d = dot(r, r);
                if (d < md) { md = d; mr = r; mg = g; }
            }
        }
        float ed = 8.0;
        for (float j = -2.0; j <= 2.0; j += 1.0) {
            for (float i = -2.0; i <= 2.0; i += 1.0) {
                vec2 g = mg + vec2(i, j);
                vec2 r = g + 0.1 + 0.8 * h22(ip + g) - fp;
                vec2 dr = r - mr;
                if (dot(dr, dr) > 0.00001) { ed = min(ed, dot(0.5 * (mr + r), normalize(dr))); }
            }
        }
        vec2 site = dc + mr * size;
        vec3 col = sample(src, samplerTransform(src, site)).rgb;
        float epx = ed * size;
        float inner = smoothstep(0.0, size * 0.4, epx);
        col = col * (0.8 + 0.28 * inner);
        float dl = length(dc - center) / radius;
        col = col * (1.0 - light * 0.35) + light * 0.6 * max(0.0, 1.0 - dl * dl) * (col * 0.8 + 0.2);
        float lm = 1.0 - smoothstep(border * 0.5 - 0.7, border * 0.5 + 0.7, epx);
        col = mix(col, lead.rgb, lm);
        return vec4(clamp(col, 0.0, 1.0), 1.0);
    }
    """)

    static let kCrack = gk("""
    kernel vec4 crackHeight(float size, float width, float seed) {
        vec2 dc = destCoord();
        vec2 q = dc / size + seed;
        q += (vec2(vnoise(q * 2.5), vnoise(q * 2.5 + 19.0)) - 0.5) * 0.45;
        float e1 = vedge(q) * size;
        float w = width * (0.55 + 0.9 * vnoise(q * 4.0 + 7.0));
        float h = smoothstep(0.0, w, e1);
        vec2 q2 = dc / (size * 0.45) + seed + 40.0;
        q2 += (vec2(vnoise(q2 * 2.0), vnoise(q2 * 2.0 + 9.0)) - 0.5) * 0.5;
        float e2 = vedge(q2) * size * 0.45;
        float h2 = smoothstep(0.0, w * 0.5, e2);
        float fade = smoothstep(0.35, 0.65, vnoise(q2 * 0.7 + 3.0));
        h = min(h, mix(1.0, h2, 0.5 * fade));
        h = h * (0.9 + 0.1 * vnoise(dc * 0.25)) ;
        return vec4(vec3(h), 1.0);
    }
    """)

    static let kCrackDarken = ck("""
    kernel vec4 crackDarken(__sample c, __sample h, float dark) {
        float k = mix(1.0 - dark, 1.0, smoothstep(0.0, 0.8, h.r));
        return vec4(c.rgb * k, 1.0);
    }
    """)

    static let kTileHeight = gk("""
    kernel vec4 tileHeight(float size, float grout, float mode, float seed) {
        vec2 dc = destCoord();
        vec2 q = dc;
        if (mode < 0.5) {
            vec2 np = dc / (size * 0.9) + seed;
            q += (vec2(vnoise(np), vnoise(np + 40.0)) - 0.5) * size * 0.14;
        }
        vec2 u = q / size;
        vec2 f = fract(u); vec2 cid = floor(u);
        vec2 d = min(f, 1.0 - f) * size;
        float e = min(d.x, d.y);
        float h;
        if (mode < 0.5) {
            float gw = grout * (0.75 + 0.5 * h12(cid + seed));
            h = smoothstep(gw * 0.5, gw * 0.5 + 2.5, e);
            h = h * (0.85 + 0.15 * vnoise(dc * 0.15));
        } else {
            float lvl = 0.3 + 0.7 * h12(cid + seed);
            h = lvl * smoothstep(0.2, 2.5, e);
        }
        return vec4(vec3(h), 1.0);
    }
    """)

    static let kGrout = ck("""
    kernel vec4 groutK(__sample c, __sample h, __sample o, float lighten) {
        vec3 g = mix(o.rgb * 0.35, vec3(0.92), lighten * 0.8);
        float m = smoothstep(0.05, 0.5, h.r);
        return vec4(mix(g, c.rgb, m), 1.0);
    }
    """)

    static let kCellColor = gk("""
    kernel vec4 cellColor(sampler src, float size) {
        vec2 dc = destCoord();
        vec2 c = (floor(dc / size) + 0.5) * size;
        return vec4(sample(src, samplerTransform(src, c)).rgb, 1.0);
    }
    """)

    static let kPlastic = gk("""
    kernel vec4 plasticK(sampler img, sampler hm, float depth, float strength) {
        vec2 dc = destCoord();
        vec4 c = sample(img, samplerTransform(img, dc));
        float l = sample(hm, samplerTransform(hm, dc + vec2(-1.0, 0.0))).r;
        float r = sample(hm, samplerTransform(hm, dc + vec2(1.0, 0.0))).r;
        float b = sample(hm, samplerTransform(hm, dc + vec2(0.0, -1.0))).r;
        float t = sample(hm, samplerTransform(hm, dc + vec2(0.0, 1.0))).r;
        vec2 g = vec2(r - l, t - b) * 0.5 * depth;
        vec3 n = normalize(vec3(-g, 1.0));
        vec3 L = normalize(vec3(-0.5, 0.7, 1.0));
        vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
        float spec = pow(max(dot(n, H), 0.0), 50.0);
        float spec0 = pow(H.z, 50.0);
        float sp = clamp((spec - spec0) * 1.6, 0.0, 1.0) * strength;
        float diff = clamp(dot(n, L) / L.z, 0.0, 1.3);
        vec3 rgb = c.rgb * (0.55 + 0.4 * diff) + vec3(sp);
        return vec4(clamp(rgb, 0.0, 1.0), 1.0);
    }
    """)

    static let kChrome = gk("""
    kernel vec4 chromeK(sampler hm, float depth) {
        vec2 dc = destCoord();
        float l = sample(hm, samplerTransform(hm, dc + vec2(-1.0, 0.0))).r;
        float r = sample(hm, samplerTransform(hm, dc + vec2(1.0, 0.0))).r;
        float b = sample(hm, samplerTransform(hm, dc + vec2(0.0, -1.0))).r;
        float t = sample(hm, samplerTransform(hm, dc + vec2(0.0, 1.0))).r;
        float hc = sample(hm, samplerTransform(hm, dc)).r;
        vec2 g = vec2(r - l, t - b) * 0.5 * depth;
        vec3 n = normalize(vec3(-g, 1.0));
        float s = dot(n, normalize(vec3(-0.6, 0.8, 1.0)));
        float ph = hc * 2.2 + n.x * 1.1 - n.y * 0.8;
        float v = 0.5 + 0.5 * cos(ph * 6.28318);
        v = mix(v, s, 0.35);
        v = clamp(v, 0.0, 1.0);
        v = v * v * (3.0 - 2.0 * v);
        return vec4(vec3(v), 1.0);
    }
    """)

    static let kPencil = ck("""
    kernel vec4 cpencil(__sample c, __sample l, __sample s1, __sample s2, __sample e, float pressure, vec4 paper) {
        float dk = clamp((1.0 - l.r) * (0.55 + pressure / 12.0) + e.r * 1.6, 0.0, 1.0);
        float c1 = step(s1.r, dk * 1.1) * smoothstep(0.2, 0.65, s1.g);
        float c2 = step(s2.r, dk * dk * 1.3 - 0.1) * smoothstep(0.2, 0.65, s2.g);
        float cov = clamp(max(c1, c2 * 0.85) * (0.5 + 0.5 * dk), 0.0, 1.0);
        vec3 pc = clamp(mix(vec3(lumv(c.rgb)), c.rgb, 1.25) * 0.9, 0.0, 1.0);
        return vec4(mix(paper.rgb, pc, cov), 1.0);
    }
    """)

    static let kTexMul = ck("""
    kernel vec4 texMul(__sample c, __sample n, float amt) {
        return vec4(clamp(c.rgb * (1.0 + (n.r - 0.5) * amt * 2.0), 0.0, 1.0), 1.0);
    }
    """)

    static let kFresco = ck("""
    kernel vec4 frescoK(__sample c, __sample d, float amt) {
        vec3 r = mix(c.rgb, d.rgb, amt);
        return vec4(min(c.rgb, r), 1.0);
    }
    """)

    static let kFilmGrain = ck("""
    kernel vec4 filmGrain(__sample c, __sample n, __sample bl, float grain, float area, float inten) {
        float l = lumv(c.rgb);
        float g = (n.r - 0.5) * grain * (1.0 - 0.6 * l);
        vec3 r = c.rgb + vec3(g);
        float lb = lumv(bl.rgb);
        float h = smoothstep(1.0 - area - 0.001, 1.0, lb) * inten * step(0.001, area);
        r = mix(r, vec3(1.0), h);
        return vec4(clamp(r, 0.0, 1.0), 1.0);
    }
    """)

    static let kNeon = ck("""
    kernel vec4 neonK(__sample base, __sample m, vec4 gc, float br) {
        vec3 g = gc.rgb * clamp(m.r * br, 0.0, 1.2);
        vec3 r = 1.0 - (1.0 - base.rgb * base.rgb * 0.55) * (1.0 - clamp(g, 0.0, 1.0));
        return vec4(clamp(r, 0.0, 1.0), 1.0);
    }
    """)

    static let kAccent = ck("""
    kernel vec4 accentK(__sample c, __sample e, float target, float amt) {
        float m = clamp(e.r * amt * 1.5, 0.0, 1.0);
        return vec4(mix(c.rgb, vec3(target), m), 1.0);
    }
    """)

    static let kPosterEdge = ck("""
    kernel vec4 posterEdgeK(__sample p, __sample e, float th) {
        float m = smoothstep(th, th + 0.18, e.r);
        return vec4(p.rgb * (1.0 - m), 1.0);
    }
    """)

    static let kStreak = ck("""
    kernel vec4 streakK(__sample c, __sample s, __sample o, float tex, float keep) {
        vec3 r = c.rgb * (1.0 + (s.r - 0.5) * tex * s.g);
        r = mix(r, o.rgb, keep);
        return vec4(clamp(r, 0.0, 1.0), 1.0);
    }
    """)

    static let kSponge = ck("""
    kernel vec4 spongeK(__sample c, __sample n, float def, float w) {
        float m = smoothstep(0.5 - w, 0.5 + w, n.r);
        vec3 r = c.rgb * (1.0 + def * (0.35 - m));
        return vec4(clamp(r, 0.0, 1.0), 1.0);
    }
    """)

    static let kWatercolor = ck("""
    kernel vec4 watercolorK(__sample s, __sample l1, __sample l2, __sample n, float shadow, float tex) {
        float e = l1.r - l2.r;
        vec3 c = s.rgb;
        float lm = lumv(c);
        c = clamp(mix(vec3(lm), c, 1.4), 0.0, 1.0);
        c = pow(c, vec3(1.25 + shadow * 0.15));
        float pool = clamp(-e * 7.0, 0.0, 0.6) + clamp(abs(e) * 2.5, 0.0, 0.2);
        c = c * (1.0 - pool);
        c = c * (1.0 - tex * 0.07 * (n.r - 0.5) * 2.0);
        return vec4(clamp(c, 0.0, 1.0), 1.0);
    }
    """)

    static let kTwoStrokes = ck("""
    kernel vec4 twoStrokes(__sample a, __sample b, __sample sa, __sample sb, __sample l, float bal, float tex, float fixedMix) {
        float t = mix(smoothstep(bal - 0.12, bal + 0.12, l.r), 0.5, fixedMix);
        vec3 ca = a.rgb * (1.0 + (sa.r - 0.5) * tex * 2.0 * sa.g);
        vec3 cb = b.rgb * (1.0 + (sb.r - 0.5) * tex * 2.0 * sb.g);
        return vec4(clamp(mix(cb, ca, t), 0.0, 1.0), 1.0);
    }
    """)

    static let kDarkStrokes = ck("""
    kernel vec4 darkStrokesK(__sample a, __sample b, __sample sa, __sample sb, __sample l, float bal, float blk, float wht) {
        float t = smoothstep(bal - 0.1, bal + 0.1, l.r);
        vec3 d = b.rgb * (1.0 + (sb.r - 0.5) * 0.8 * sb.g);
        d = d * (1.0 - blk * (1.0 - l.r * 0.6));
        vec3 w = a.rgb * (1.0 + (sa.r - 0.5) * 0.5 * sa.g);
        w = mix(w, vec3(1.0), wht * l.r * l.r);
        w = (w - 0.5) * 1.15 + 0.5;
        return vec4(clamp(mix(d, w, t), 0.0, 1.0), 1.0);
    }
    """)

    static let kInk = ck("""
    kernel vec4 inkK(__sample c, __sample l1, __sample l2, __sample s, float dark, float light) {
        float e = l1.r - l2.r;
        float ink = smoothstep(0.012, 0.06, -e);
        float lm = lumv(c.rgb);
        vec3 r = c.rgb * (1.0 - dark * (1.0 - lm) * (1.0 - lm));
        r = mix(r, vec3(1.0), light * lm * lm);
        r = r * (1.0 + (s.r - 0.5) * 0.5 * s.g);
        r = r * (1.0 - ink * 0.9);
        return vec4(clamp(r, 0.0, 1.0), 1.0);
    }
    """)

    static let kSumie = ck("""
    kernel vec4 sumieK(__sample c, __sample ink, float con, float pr) {
        vec3 r = pow(c.rgb, vec3(1.0 + con * 1.2));
        float dark = smoothstep(0.55, 0.12, ink.r) * (0.55 + pr * 0.45);
        r = mix(r, vec3(0.04), dark);
        r = (r - 0.5) * (1.0 + con * 0.4) + 0.5;
        return vec4(clamp(r, 0.0, 1.0), 1.0);
    }
    """)

    static let kDiffuse = ck("""
    kernel vec4 diffuseK(__sample c, __sample bl, __sample n, vec4 bg, float th, float amt, float grain) {
        float l = lumv(bl.rgb);
        float m = clamp(smoothstep(th - 0.3, th + 0.25, l) * amt, 0.0, 1.0);
        float gm = step(n.r, m);
        float cov = clamp(mix(m, gm, grain * 0.8), 0.0, 1.0);
        return vec4(mix(c.rgb, bg.rgb, cov), 1.0);
    }
    """)

    static let kChalk = ck("""
    kernel vec4 chalkK(__sample l, __sample s1, __sample s2, float ch, float ck, float pr) {
        float D = clamp((0.4 + ch * 0.35 - l.r) * 2.5, 0.0, 1.0);
        float C = clamp((l.r - (0.6 - ck * 0.35)) * 2.5, 0.0, 1.0);
        float thr = 0.6 - pr * 0.08;
        float cc = step(s1.r, D) * smoothstep(thr - 0.15, thr + 0.15, s1.g + D * 0.35);
        float kc = step(s2.r, C) * smoothstep(thr - 0.15, thr + 0.15, s2.g + C * 0.25);
        float t = 0.5;
        t = mix(t, 1.0, kc * 0.92);
        t = mix(t, 0.0, cc * 0.95);
        return vec4(vec3(t), 1.0);
    }
    """)

    static let kCharcoal = ck("""
    kernel vec4 charcoalK(__sample l, __sample s, __sample e, float bal, float thick) {
        float D = clamp((bal - l.r) * 2.4 + 0.45, 0.0, 1.0);
        float thr = mix(0.6 - thick * 0.05, 0.0, D * D);
        float cov = step(s.r, D) * smoothstep(thr - 0.15, thr + 0.15, s.g);
        cov = max(cov, clamp(e.r * 1.6, 0.0, 1.0));
        return vec4(vec3(1.0 - cov * 0.95), 1.0);
    }
    """)

    static let kPen = ck("""
    kernel vec4 penK(__sample l, __sample s, float bal) {
        float D = clamp(1.0 - l.r + bal, 0.0, 1.0);
        D = smoothstep(0.08, 0.95, D);
        float thr = mix(0.62, 0.0, D * D * D);
        float cov = step(s.r, D) * smoothstep(thr - 0.1, thr + 0.1, s.g);
        return vec4(vec3(1.0 - cov), 1.0);
    }
    """)

    static let kHalftone = ck("""
    kernel vec4 halftoneK(__sample l, float type, float period, vec2 c) {
        vec2 p = destCoord() - c;
        float ink = 1.0 - clamp(l.r, 0.0, 1.0);
        float w = 1.2 / period;
        float cov;
        if (type < 0.5) {
            float f = abs(fract(length(p) / period) - 0.5) * 2.0;
            cov = 1.0 - smoothstep(ink - w, ink + w, f);
        } else if (type < 1.5) {
            vec2 q = vec2(p.x + p.y, p.y - p.x) * 0.70710678 / period;
            vec2 f = fract(q) - 0.5;
            float d = length(f) * 1.41421356;
            float r = ink < 0.6 ? sqrt(ink) * 0.8 : mix(0.62, 1.05, (ink - 0.6) / 0.4);
            cov = 1.0 - smoothstep(r - w, r + w, d);
        } else {
            float f = abs(fract(p.y / period) - 0.5) * 2.0;
            cov = 1.0 - smoothstep(ink - w, ink + w, f);
        }
        cov = cov * clamp(ink / w, 0.0, 1.0);
        return vec4(vec3(1.0 - cov), 1.0);
    }
    """)

    /// t = smoothstep(th - w, th + w, x); invert > 0.5 flips.
    static let kThresh = ck("""
    kernel vec4 threshK(__sample x, float th, float w, float inv) {
        float t = smoothstep(th - w, th + w, x.r);
        t = mix(t, 1.0 - t, inv);
        return vec4(vec3(t), 1.0);
    }
    """)

    static let kNote = ck("""
    kernel vec4 noteK(__sample m, __sample n, float grain) {
        float t = mix(0.9, 0.42, m.r) + (n.r - 0.5) * grain;
        return vec4(vec3(clamp(t, 0.0, 1.0)), 1.0);
    }
    """)

    static let kPhotocopy = ck("""
    kernel vec4 photocopyK(__sample l, __sample b, float dark) {
        float d = (b.r - l.r) * dark;
        float ink = smoothstep(0.06, 0.28, d);
        ink = max(ink, smoothstep(0.1, 0.02, l.r) * 0.9);
        return vec4(vec3(1.0 - ink), 1.0);
    }
    """)

    static let kStretch = ck("""
    kernel vec4 stretchK(__sample x, float k) {
        return vec4(clamp((x.rgb - 0.5) * k + 0.5, 0.0, 1.0), 1.0);
    }
    """)

    static let kNoisyThresh = ck("""
    kernel vec4 noisyThresh(__sample l, __sample n, float dens, float th, float w) {
        float v = l.r + (n.r - 0.5) * dens;
        return vec4(vec3(smoothstep(th - w, th + w, v)), 1.0);
    }
    """)

    static let kMixGray = ck("""
    kernel vec4 mixGray(__sample a, __sample b, float t) {
        return vec4(vec3(mix(a.r, b.r, t)), 1.0);
    }
    """)

    static let kAddGray = ck("""
    kernel vec4 addGray(__sample a, __sample n, float amp) {
        return vec4(vec3(a.r + (n.r - 0.5) * amp), 1.0);
    }
    """)

    static let kConte = ck("""
    kernel vec4 conteK(__sample l, __sample g, float fgl, float bgl) {
        float v = l.r;
        float d = clamp((0.6 - v) * 2.0 * fgl, 0.0, 1.0);
        float b = clamp((v - 0.45) * 2.0 * bgl, 0.0, 1.0);
        float t = 0.5;
        t = mix(t, 1.0, b * smoothstep(0.25, 0.65, g.r + b * 0.35));
        t = mix(t, 0.0, d * smoothstep(0.3, 0.65, g.r + d * 0.45));
        return vec4(vec3(t), 1.0);
    }
    """)

    static let kSparse = ck("""
    kernel vec4 sparseK(__sample n, float th) {
        return vec4(vec3(step(th, n.r)), 1.0);
    }
    """)

    static let kFiber = ck("""
    kernel vec4 fiberK(__sample c, __sample f, __sample bl, float k) {
        float fb = clamp(f.r * k, 0.0, 1.0);
        vec3 r = c.rgb * (0.82 + 0.3 * bl.r) * (0.85 + 0.15 * fb) + vec3(fb * 0.16);
        return vec4(clamp(r, 0.0, 1.0), 1.0);
    }
    """)

    static let kGrain = ck("""
    kernel vec4 grainK(__sample c, __sample n, float amt, float mode, vec4 fg, vec4 bg) {
        vec3 r = c.rgb;
        if (mode < 0.5) {
            r = r + (n.rgb - 0.5) * amt;
        } else if (mode < 1.5) {
            float m = step(1.0 - amt * 0.3, n.r);
            r = mix(r, bg.rgb, m);
        } else if (mode < 2.5) {
            float l = lumv(c.rgb);
            float m = step(n.r, (1.0 - l) * (0.4 + amt * 1.2));
            r = mix(bg.rgb, fg.rgb, m);
        } else {
            float dk = step(1.0 - amt * 0.25, n.r);
            float lt = step(1.0 - amt * 0.25, n.g);
            r = mix(r, r * 0.25, dk);
            r = mix(r, 1.0 - (1.0 - r) * 0.25, lt);
        }
        return vec4(clamp(r, 0.0, 1.0), 1.0);
    }
    """)
}
