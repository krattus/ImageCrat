import Foundation
import CoreGraphics
import CoreImage
import ImageCratCore

/// Local pre/post-processing: context crops, provider sizing, mask encoding and feathered compositing.
/// Everything a provider returns is blended back locally so pixels outside the selection never change.
enum GenImaging {
    // MARK: Geometry

    /// Selection bbox grown by `context` (fraction of its size, min 32 px) and, if given, widened to `aspect` (w/h).
    /// With `clampTo`, the rect is shifted/clipped to stay inside it.
    static func contextRect(around b: IRect, context: Double = 0.25, aspect: Double? = nil, clampTo bounds: IRect?) -> IRect {
        let padX = max(32, Int((Double(b.width) * context).rounded())), padY = max(32, Int((Double(b.height) * context).rounded()))
        var r = CGRect(x: b.x - padX, y: b.y - padY, width: b.width + 2 * padX, height: b.height + 2 * padY)
        if let a = aspect, a > 0 {
            if r.width / r.height < a { let nw = r.height * a; r = r.insetBy(dx: -(nw - r.width) / 2, dy: 0) }
            else { let nh = r.width / a; r = r.insetBy(dx: 0, dy: -(nh - r.height) / 2) }
        }
        var ir = IRect(enclosing: r)
        if let c = bounds {
            // shift inside, then clip
            if ir.width <= c.width { ir.x = min(max(ir.x, c.minX), c.maxX - ir.width) }
            if ir.height <= c.height { ir.y = min(max(ir.y, c.minY), c.maxY - ir.height) }
            ir = ir.intersection(c)
        }
        return ir
    }

    /// Pixel size to send for a region: longest edge ≈ preferred edge for the quality, capped by max MP / edge,
    /// rounded to the provider multiple, or snapped to the closest allowed fixed size.
    static func sendSize(for w: Int, _ h: Int, caps: ProviderCapabilities, quality: OutputQuality) -> (Int, Int) {
        if let sizes = caps.allowedSizes, !sizes.isEmpty {
            let a = Double(w) / Double(max(1, h))
            let best = sizes.min { abs(log(Double($0.width / $0.height)) - log(a)) < abs(log(Double($1.width / $1.height)) - log(a)) }!
            return (Int(best.width), Int(best.height))
        }
        let edge: Double
        switch quality {
        case .draft: edge = Double(min(caps.preferredEdge, 768))
        case .standard: edge = Double(caps.preferredEdge)
        case .high: edge = Double(caps.maxEdge)
        }
        let s = edge / Double(max(w, h))
        var sw = Double(w) * s, sh = Double(h) * s
        let mp = sw * sh / 1_000_000
        if mp > caps.maxMegapixels { let k = (caps.maxMegapixels / mp).squareRoot(); sw *= k; sh *= k }
        if caps.minMegapixels > 0, sw * sh / 1_000_000 < caps.minMegapixels {
            let k = (caps.minMegapixels * 1.02 / (sw * sh / 1_000_000)).squareRoot(); sw *= k; sh *= k
        }
        let m = Double(max(1, caps.sizeMultiple))
        let round: (Double) -> Int = { v in max(Int(m), Int(((caps.minMegapixels > 0 ? (v / m).rounded(.up) : (v / m).rounded(.down)) * m))) }
        let rw = round(sw), rh = round(sh)
        return (rw, rh)
    }

    /// "W:H" string closest to a pixel size among the ratios image APIs accept.
    static func aspectString(_ w: Int, _ h: Int, allowed: [String] = ["1:1", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4", "9:16", "16:9", "21:9", "9:21"]) -> String {
        let a = Double(w) / Double(max(1, h))
        return allowed.min { abs(log(ratio($0)) - log(a)) < abs(log(ratio($1)) - log(a)) } ?? "1:1"
    }
    static func ratio(_ s: String) -> Double {
        let p = s.split(separator: ":").compactMap { Double($0) }
        return p.count == 2 && p[1] > 0 ? p[0] / p[1] : 1
    }

    // MARK: Pixels

    /// High-quality resample to an exact size.
    static func resize(_ img: CGImage, _ w: Int, _ h: Int) -> CGImage {
        if img.width == w && img.height == h { return img }
        let b = PixelBuffer(width: w, height: h)
        b.drawImage(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return b.makeCGImage()
    }

    /// Composite of `state` for a doc rect (may extend beyond the canvas: outside is transparent).
    static func composite(_ state: DocumentState, rect: IRect) -> PixelBuffer {
        let sp = CanvasSpace(width: state.width, height: state.height)
        let img = Compositor.shared.composite(state).cropped(to: sp.ciCanvas)
        return RenderEngine.renderBuffer(img, docRect: rect, space: sp)
    }

    /// Canvas-size gray mask → rect-sized gray (outside the canvas = 0).
    static func crop(_ mask: PixelBuffer, to r: IRect) -> PixelBuffer {
        let n = PixelBuffer(width: r.width, height: r.height, format: .gray)
        n.copyPixels(from: mask, at: IPoint(x: -r.x, y: -r.y))
        n.markDirty()
        return n
    }

    /// Nearest/area resample of a gray mask.
    static func resizeMask(_ m: PixelBuffer, _ w: Int, _ h: Int) -> PixelBuffer {
        if m.width == w && m.height == h { return m.copy() }
        let n = PixelBuffer(width: w, height: h, format: .gray)
        n.context.interpolationQuality = .high
        n.drawImage(m.makeCGImage(), in: CGRect(x: 0, y: 0, width: w, height: h))
        n.markDirty()
        return n
    }

    /// Grows the edit area a little and hardens it (providers expect binary masks; the local blend restores softness).
    static func providerMask(_ m: PixelBuffer, grow: Double = 4) -> PixelBuffer {
        let g = grow > 0 ? SelectionOps.expand(m, by: grow) : m.copy()
        let p = g.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<g.height { for x in 0..<g.width { let i = y * g.bytesPerRow + x; p[i] = p[i] > 8 ? 255 : 0 } }
        g.markDirty()
        return g
    }

    /// Encodes the internal mask (gray, white = edit) in the provider's format.
    static func encodeMask(_ m: PixelBuffer, kind: MaskKind) -> Data {
        switch kind {
        case .none, .grayWhiteEdit:
            return GenHTTP.pngData(m.makeCGImage())            // 8-bit gray PNG, white = edit
        case .alphaTransparentEdit:
            // RGBA PNG: alpha 0 where the model may edit, opaque elsewhere (OpenAI /images/edits).
            let out = PixelBuffer(width: m.width, height: m.height)
            let s = m.data.assumingMemoryBound(to: UInt8.self), d = out.data.assumingMemoryBound(to: UInt8.self)
            for y in 0..<m.height {
                for x in 0..<m.width {
                    let a: UInt8 = 255 - s[y * m.bytesPerRow + x]
                    let o = y * out.bytesPerRow + x * 4
                    d[o] = a; d[o + 1] = a; d[o + 2] = a; d[o + 3] = a     // premultiplied white
                }
            }
            out.markDirty()
            return GenHTTP.pngData(out.makeCGImage())
        }
    }

    /// Flattens an RGBA crop onto a colour (providers that reject alpha / for outpaint areas).
    static func flatten(_ img: CGImage, over c: RGBA = RGBA(gray: 0.5)) -> CGImage {
        let b = PixelBuffer(width: img.width, height: img.height)
        b.context.setFillColor(c.cgColor)
        b.context.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        b.drawImage(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return b.makeCGImage()
    }

    /// The blend mask used to composite a result: feathered **inside** the selection (never beyond it),
    /// optionally extended `outerBlend` px outward (Generative Expand seams).
    static func blendMask(_ sel: PixelBuffer, feather: Double, outerBlend: Double = 0) -> PixelBuffer {
        let soft = feather > 0 ? SelectionOps.feather(sel, radius: feather) : sel.copy()
        let out = PixelBuffer(width: sel.width, height: sel.height, format: .gray)
        let s = sel.data.assumingMemoryBound(to: UInt8.self), f = soft.data.assumingMemoryBound(to: UInt8.self), o = out.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<sel.height {
            for x in 0..<sel.width {
                let i = y * sel.bytesPerRow, j = y * soft.bytesPerRow, k = y * out.bytesPerRow
                let sv = Int(s[i + x]), fv = Int(f[j + x])
                // inside-only feather: 0 outside, ~25% at the selection edge, 100% in the interior
                let v = min(sv, max(0, min(255, 2 * fv - 191)))
                o[k + x] = UInt8(v)
            }
        }
        if outerBlend > 0 {
            let grown = SelectionOps.feather(SelectionOps.expand(sel, by: outerBlend / 2), radius: outerBlend / 2)
            let g = grown.data.assumingMemoryBound(to: UInt8.self)
            for y in 0..<sel.height { for x in 0..<sel.width {
                let k = y * out.bytesPerRow + x, gi = y * grown.bytesPerRow + x
                o[k] = max(o[k], g[gi])
            } }
        }
        out.markDirty()
        return out
    }

    /// Scales a provider result to the region size and multiplies its alpha by the blend mask. Returns a region-sized
    /// premultiplied RGBA buffer that is fully transparent wherever `blend` is 0.
    static func masked(result: CGImage, size w: Int, _ h: Int, blend: PixelBuffer?) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        b.context.setBlendMode(.copy)
        b.drawImage(result, in: CGRect(x: 0, y: 0, width: w, height: h), blend: .copy)
        guard let m = blend else { b.markDirty(); return b }
        let p = b.data.assumingMemoryBound(to: UInt8.self), mp = m.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let a = UInt32(mp[y * m.bytesPerRow + x])
                let o = y * b.bytesPerRow + x * 4
                if a == 255 { continue }
                if a == 0 { p[o] = 0; p[o + 1] = 0; p[o + 2] = 0; p[o + 3] = 0; continue }
                for c in 0..<4 { p[o + c] = UInt8((UInt32(p[o + c]) * a + 127) / 255) }
            }
        }
        b.markDirty()
        return b
    }

    /// Small thumbnail for the Properties panel / history.
    static func thumbnail(_ b: PixelBuffer, maxEdge: Int = 72) -> CGImage {
        let s = Double(maxEdge) / Double(max(b.width, b.height))
        let w = max(1, Int(Double(b.width) * s)), h = max(1, Int(Double(b.height) * s))
        let t = PixelBuffer(width: w, height: h)
        t.drawImage(b.makeCGImage(), in: CGRect(x: 0, y: 0, width: w, height: h))
        return t.makeCGImage()
    }

    /// Soft contact shadow under a layer's alpha (Harmonize): offset, blurred, low opacity.
    static func contactShadow(for layer: PixelBuffer, strength: Double = 0.45) -> PixelBuffer {
        let alpha = layer.toGray(useAlpha: true)
        let h = alpha.height, w = alpha.width
        let squashed = PixelBuffer(width: w, height: h, format: .gray)
        if let b = alpha.opaqueBounds(threshold: 8) {
            let crop = alpha.cropped(to: b).makeCGImage()
            // flatten the object's silhouette into a thin band at its base (ground contact)
            let band = max(4, Double(b.height) * 0.12)
            squashed.drawImage(crop, in: CGRect(x: Double(b.x) + Double(b.width) * 0.04, y: Double(b.maxY) - band * 0.6, width: Double(b.width) * 0.92, height: band))
        }
        squashed.markDirty()
        let blurred = SelectionOps.feather(squashed, radius: max(3, Double(squashed.opaqueBounds()?.height ?? 10) * 0.35))
        let out = PixelBuffer(width: w, height: h)
        let s = blurred.data.assumingMemoryBound(to: UInt8.self), d = out.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w {
            let a = UInt8(Double(s[y * blurred.bytesPerRow + x]) * strength)
            d[y * out.bytesPerRow + x * 4 + 3] = a        // black, premultiplied
        } }
        out.markDirty()
        return out
    }
}
