import Foundation
import CoreML
import CoreImage
import Accelerate
import ImageCratCore

/// BiRefNet (dichotomous image segmentation) used as an edge/hair matting model.
/// Lite = fast, full = "High Quality". Both take a 1024×1024 ImageNet-normalized NCHW tensor.
enum SegMatting {
    enum Quality: String, CaseIterable, Identifiable {
        case fast = "Fast", high = "High Quality"
        var id: String { rawValue }
    }

    /// Best installed engine for a quality (falls back to the other one).
    static func engine(_ q: Quality) -> (id: String, pkg: String)? {
        let lite = (SegModels.birefnetLite, SegModels.birefnetLitePkg), full = (SegModels.birefnet, SegModels.birefnetPkg)
        let order = q == .high ? [full, lite] : [lite, full]
        return order.first { ModelManager.shared.isInstalled($0.0) }
    }

    static var isAvailable: Bool { SegModels.mattingInstalled }
    private static let lock = NSLock()

    /// Soft foreground matte (0…1) of doc region `rect` of `img`, as a CI image placed on the canvas.
    static func matte(_ img: SegImage, rect: CGRect, quality: Quality) throws -> CIImage {
        guard let e = engine(quality) else { throw ModelError.notInstalled("BiRefNet") }
        let model = try SegModels.model(e.id, e.pkg, units: .cpuAndGPU)
        let S = 1024
        let rgba = img.rgba(rect: rect, w: S, h: S)
        let n = S * S
        let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "image"
        let dtype = model.modelDescription.inputDescriptionsByName[inputName]?.multiArrayConstraint?.dataType ?? .float32
        let arr = try MLMultiArray(shape: [1, 3, NSNumber(value: S), NSNumber(value: S)], dataType: dtype == .float16 ? .float16 : .float32)
        // RGBA8 → planar float, ImageNet normalization
        var planes = [[Float]](repeating: [Float](repeating: 0, count: n), count: 3)
        let mean: [Float] = [0.485, 0.456, 0.406], std: [Float] = [0.229, 0.224, 0.225]
        rgba.withUnsafeBufferPointer { src in
            for c in 0..<3 {
                planes[c].withUnsafeMutableBufferPointer { dst in
                    vDSP_vfltu8(src.baseAddress! + c, 4, dst.baseAddress!, 1, vDSP_Length(n))
                    var scale = 1 / (255 * std[c]), bias = -mean[c] / std[c]
                    vDSP_vsmsa(dst.baseAddress!, 1, &scale, &bias, dst.baseAddress!, 1, vDSP_Length(n))
                }
            }
        }
        if arr.dataType == .float16 {
            for c in 0..<3 {
                planes[c].withUnsafeMutableBytes { s in
                    var src = vImage_Buffer(data: s.baseAddress!, height: 1, width: vImagePixelCount(n), rowBytes: n * 4)
                    var dst = vImage_Buffer(data: arr.dataPointer + c * n * 2, height: 1, width: vImagePixelCount(n), rowBytes: n * 2)
                    vImageConvert_PlanarFtoPlanar16F(&src, &dst, 0)
                }
            }
        } else {
            for c in 0..<3 { planes[c].withUnsafeBytes { memcpy(arr.dataPointer + c * n * 4, $0.baseAddress!, n * 4) } }
        }
        lock.lock(); defer { lock.unlock() }
        let out = try segTime("matting.\(e.id)") { try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inputName: arr])) }
        guard let oname = model.modelDescription.outputDescriptionsByName.keys.first,
              let res = out.featureValue(for: oname)?.multiArrayValue else { throw SAMError.failed("matting output") }
        var v = SAMSegmenter.floats(res)
        // logits → probability (models export either logits or sigmoid output)
        var mn: Float = 0, mx: Float = 0
        vDSP_minv(v, 1, &mn, vDSP_Length(v.count)); vDSP_maxv(v, 1, &mx, vDSP_Length(v.count))
        if mn < -0.01 || mx > 1.01 {
            var neg = v.map { -$0 }
            var cnt = Int32(v.count)
            vvexpf(&neg, neg, &cnt)
            var one: Float = 1
            vDSP_vsadd(neg, 1, &one, &neg, 1, vDSP_Length(v.count))
            vDSP_svdiv(&one, neg, 1, &v, 1, vDSP_Length(v.count))
        }
        let side = Int(Double(v.count).squareRoot())
        let img01 = SegMask.floatImage(v, w: side, h: side)
        let ci = img.ciRect(rect)
        let t = CGAffineTransform(scaleX: ci.width / CGFloat(side), y: ci.height / CGFloat(side)).concatenating(CGAffineTransform(translationX: ci.minX, y: ci.minY))
        let placed = img01.clampedToExtent().transformed(by: t).cropped(to: ci)
        let gray = placed.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        return gray.composited(over: CIImage(color: .black).cropped(to: img.canvas)).cropped(to: img.canvas)
    }

    static let bandBlendKernel = CIColorKernel(source: """
    kernel vec4 hairBlend(__sample base, __sample matte, __sample inner, __sample outer) {
        // inside the eroded core keep 1, outside the dilated shell keep 0, blend the matte in between
        float m = matte.r;
        float r = mix(base.r, m, clamp(outer.r - inner.r, 0.0, 1.0));
        r = max(r, inner.r);
        r = min(r, outer.r);
        return vec4(r, r, r, 1.0);
    }
    """)

    /// Hair/fine-edge refinement of a selection mask: runs matting on a crop around the mask and blends it
    /// into an uncertainty band around the mask edge (band width ≈ `bandFraction` of the object size).
    static func refine(mask: PixelBuffer, image: SegImage, quality: Quality, bandFraction: Double = 0.035, minBand: Double = 4) throws -> PixelBuffer {
        guard let b = mask.opaqueBounds(threshold: 20)?.cgRect else { return mask }
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let pad = max(b.width, b.height) * 0.12 + 16
        var crop = b.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
        // square-ish crop gives the model a natural aspect ratio
        if crop.width < crop.height { crop = crop.insetBy(dx: -(crop.height - crop.width) / 2, dy: 0).intersection(image.canvas) }
        else { crop = crop.insetBy(dx: 0, dy: -(crop.width - crop.height) / 2).intersection(image.canvas) }
        let m = try matte(image, rect: crop, quality: quality)
        let canvas = image.canvas
        let base = mask.ciImage
        let r = max(minBand, Double(max(b.width, b.height)) * bandFraction)
        let outer = base.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: r]).cropped(to: canvas)
            .clampedToExtent().applyingGaussianBlur(sigma: r / 3).cropped(to: canvas)
        let inner = base.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r]).cropped(to: canvas)
            .clampedToExtent().applyingGaussianBlur(sigma: r / 3).cropped(to: canvas)
        // only the crop region gets the matte; elsewhere keep the base mask
        let cropMask = CIImage(color: .white).cropped(to: image.ciRect(crop)).composited(over: CIImage(color: .black).cropped(to: canvas))
        let outerC = outer.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: cropMask])
        let innerC = inner.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: cropMask])
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: base.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: cropMask.inverted()])])
        let outerFull = outerC.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: base.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: cropMask.inverted()])])
        guard let k = bandBlendKernel, let blended = k.apply(extent: canvas, arguments: [base, m, innerC.cropped(to: canvas), outerFull.cropped(to: canvas)]) else { return mask }
        return SegMask.buffer(blended, width: image.width, height: image.height)
    }

    /// Whole-subject matte (BiRefNet on the full image, then on a crop around the subject for detail when it is small),
    /// edge-aware upsampled to the canvas — Select Subject (High Quality).
    static func subjectMatte(_ image: SegImage, quality: Quality) throws -> PixelBuffer? {
        var m = try matte(image, rect: image.canvas, quality: quality)
        let scale = CGFloat(max(image.width, image.height)) / 1024
        var buf = SegMask.buffer(m, width: image.width, height: image.height)
        guard let b = buf.opaqueBounds(threshold: 127)?.cgRect else { return nil }
        if max(b.width / CGFloat(image.width), b.height / CGFloat(image.height)) < 0.6 {
            // second pass on a crop for more pixels on the subject
            let pad = max(b.width, b.height) * 0.15
            let crop = b.insetBy(dx: -pad, dy: -pad).intersection(image.canvas).integral
            let mc = try matte(image, rect: crop, quality: quality)
            let cropMask = CIImage(color: .white).cropped(to: image.ciRect(crop)).composited(over: CIImage(color: .black).cropped(to: image.canvas))
            m = mc.mixed(with: m, mask: cropMask).cropped(to: image.canvas)
        }
        if scale > 1.2 {
            m = SegMask.refineEdges(m, guide: image.image, canvas: image.canvas, radius: Double(min(12, scale * 1.5)), epsilon: 0.002)
        }
        buf = SegMask.buffer(m, width: image.width, height: image.height)
        return buf.opaqueBounds(threshold: 127) == nil ? nil : buf
    }
}
