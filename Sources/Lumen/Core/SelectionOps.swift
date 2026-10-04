import Foundation
import CoreGraphics
import CoreImage
import ImageCratCore


enum SelectionOps {
    /// Canvas-size gray mask with a path filled white.
    static func mask(fromPath path: CGPath, width: Int, height: Int, antialias: Bool = true, evenOdd: Bool = false) -> PixelBuffer {
        let m = PixelBuffer(width: width, height: height, format: .gray)
        let c = m.context
        c.setShouldAntialias(antialias)
        c.setFillColor(gray: 1, alpha: 1)
        c.addPath(path)
        if evenOdd { c.fillPath(using: .evenOdd) } else { c.fillPath() }
        m.markDirty()
        return m
    }

    static func rectMask(_ r: CGRect, width: Int, height: Int) -> PixelBuffer {
        mask(fromPath: CGPath(rect: r, transform: nil), width: width, height: height, antialias: false)
    }

    static func all(width: Int, height: Int) -> PixelBuffer { PixelBuffer(width: width, height: height, gray: 255) }

    /// Combine two canvas-size masks.
    static func combine(_ base: PixelBuffer?, _ new: PixelBuffer, mode: SelectionCombine) -> PixelBuffer {
        guard let base else {
            if mode == .subtract || mode == .intersect { return PixelBuffer(width: new.width, height: new.height, format: .gray) }
            return new
        }
        if mode == .new { return new }
        let out = PixelBuffer(width: new.width, height: new.height, format: .gray)
        let a = base.data.assumingMemoryBound(to: UInt8.self)
        let b = new.data.assumingMemoryBound(to: UInt8.self)
        let o = out.data.assumingMemoryBound(to: UInt8.self)
        let w = new.width, h = new.height
        for y in 0..<h {
            let ar = a + y * base.bytesPerRow, br = b + y * new.bytesPerRow, orow = o + y * out.bytesPerRow
            for x in 0..<w {
                let av = Int(ar[x]), bv = Int(br[x])
                switch mode {
                case .add: orow[x] = UInt8(max(av, bv))
                case .subtract: orow[x] = UInt8(av * (255 - bv) / 255)
                case .intersect: orow[x] = UInt8(min(av, bv))
                case .new: orow[x] = UInt8(bv)
                }
            }
        }
        out.markDirty()
        return out
    }

    static func invert(_ m: PixelBuffer) -> PixelBuffer {
        let out = PixelBuffer(width: m.width, height: m.height, format: .gray)
        let a = m.data.assumingMemoryBound(to: UInt8.self)
        let o = out.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<m.height {
            let ar = a + y * m.bytesPerRow, orow = o + y * out.bytesPerRow
            for x in 0..<m.width { orow[x] = 255 - ar[x] }
        }
        out.markDirty()
        return out
    }

    /// Applies a CI operation to a gray mask.
    static func process(_ m: PixelBuffer, _ f: (CIImage) -> CIImage) -> PixelBuffer {
        let space = CanvasSpace(width: m.width, height: m.height)
        let img = f(m.ciImage.clampedToExtent()).cropped(to: space.ciCanvas)
        return RenderEngine.renderBuffer(img, docRect: IRect(x: 0, y: 0, width: m.width, height: m.height), space: space, format: .gray)
    }

    static func feather(_ m: PixelBuffer, radius: Double, direction: FeatherDirection = .centered) -> PixelBuffer {
        if radius <= 0 { return m }
        let edge = CIImage(color: .black)
        let space = CanvasSpace(width: m.width, height: m.height)
        let padded = m.ciImage.composited(over: edge.cropped(to: space.ciCanvas.insetBy(dx: -CGFloat(radius * 3), dy: -CGFloat(radius * 3))))
        let img = featherImage(padded, radius: radius, direction: direction).cropped(to: space.ciCanvas)
        return RenderEngine.renderBuffer(img, docRect: IRect(x: 0, y: 0, width: m.width, height: m.height), space: space, format: .gray)
    }

    /// Feathers a gray mask image. `centered` blurs across the edge (half inside, half outside); `inside` keeps the
    /// original outline and fades inward only; `outside` keeps everything selected and fades outward only.
    static func featherImage(_ img: CIImage, radius: Double, direction: FeatherDirection) -> CIImage {
        if radius <= 0 { return img }
        let ext = img.extent
        let blurred = img.clampedToExtent().applyingGaussianBlur(sigma: radius / 2).cropped(to: ext)
        func remap(_ scale: CGFloat, _ bias: CGFloat) -> CIImage {
            blurred.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)])
                .applyingFilter("CIColorClamp").cropped(to: ext)
        }
        switch direction {
        case .centered:
            return blurred
        case .inside:
            // the blurred edge is 50% at the original outline: stretch the inner half to 0…1, never exceed the original
            return remap(2, -1).applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: ext)
        case .outside:
            // stretch the outer half to 0…1 so the original area stays fully selected
            return remap(2, 0).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: ext)
        }
    }

    static func expand(_ m: PixelBuffer, by r: Double) -> PixelBuffer {
        process(m) { $0.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: r]) }
    }

    static func contract(_ m: PixelBuffer, by r: Double) -> PixelBuffer {
        let space = CanvasSpace(width: m.width, height: m.height)
        let img = m.ciImage.composited(over: CIImage(color: .black).cropped(to: space.ciCanvas.insetBy(dx: -CGFloat(r + 4), dy: -CGFloat(r + 4))))
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r]).cropped(to: space.ciCanvas)
        return RenderEngine.renderBuffer(img, docRect: IRect(x: 0, y: 0, width: m.width, height: m.height), space: space, format: .gray)
    }

    static func border(_ m: PixelBuffer, width r: Double) -> PixelBuffer {
        let outer = expand(m, by: r / 2)
        let inner = contract(m, by: r / 2)
        return combine(outer, inner, mode: .subtract)
    }

    static func smooth(_ m: PixelBuffer, radius r: Double) -> PixelBuffer {
        let blurred = feather(m, radius: r)
        // re-threshold
        let out = PixelBuffer(width: m.width, height: m.height, format: .gray)
        let a = blurred.data.assumingMemoryBound(to: UInt8.self)
        let o = out.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<m.height {
            let ar = a + y * blurred.bytesPerRow, orow = o + y * out.bytesPerRow
            for x in 0..<m.width { orow[x] = ar[x] >= 128 ? 255 : 0 }
        }
        out.markDirty()
        return out
    }

    /// Selection from a layer's alpha, in canvas coordinates.
    static func fromAlpha(_ buffer: PixelBuffer, origin: IPoint, width: Int, height: Int) -> PixelBuffer {
        let out = PixelBuffer(width: width, height: height, format: .gray)
        let s = buffer.data.assumingMemoryBound(to: UInt8.self)
        let o = out.data.assumingMemoryBound(to: UInt8.self)
        let r = IRect(x: origin.x, y: origin.y, width: buffer.width, height: buffer.height).intersection(IRect(x: 0, y: 0, width: width, height: height))
        if r.isEmpty { return out }
        for y in r.minY..<r.maxY {
            let sr = s + (y - origin.y) * buffer.bytesPerRow, orow = o + y * out.bytesPerRow
            for x in r.minX..<r.maxX {
                orow[x] = buffer.format == .rgba ? sr[(x - origin.x) * 4 + 3] : sr[x - origin.x]
            }
        }
        out.markDirty()
        return out
    }

    // MARK: Flood fill (magic wand / bucket)

    /// Returns a canvas-size mask of pixels similar to the seed. `src` is an RGBA buffer covering the canvas.
    static func floodMask(src: PixelBuffer, seed: IPoint, tolerance: Double, contiguous: Bool, antialias: Bool) -> PixelBuffer {
        let w = src.width, h = src.height
        let out = PixelBuffer(width: w, height: h, format: .gray)
        guard seed.x >= 0, seed.y >= 0, seed.x < w, seed.y < h else { return out }
        let p = src.data.assumingMemoryBound(to: UInt8.self)
        let o = out.data.assumingMemoryBound(to: UInt8.self)
        let bpr = src.bytesPerRow, obpr = out.bytesPerRow
        let si = seed.y * bpr + seed.x * 4
        let sr = Int(p[si]), sg = Int(p[si + 1]), sb = Int(p[si + 2]), sa = Int(p[si + 3])
        let tol = Int(tolerance)
        @inline(__always) func matches(_ i: Int) -> Bool {
            abs(Int(p[i]) - sr) <= tol && abs(Int(p[i + 1]) - sg) <= tol && abs(Int(p[i + 2]) - sb) <= tol && abs(Int(p[i + 3]) - sa) <= tol
        }
        if !contiguous {
            for y in 0..<h {
                for x in 0..<w where matches(y * bpr + x * 4) { o[y * obpr + x] = 255 }
            }
        } else {
            var visited = [Bool](repeating: false, count: w * h)
            var stack: [(Int, Int)] = [(seed.x, seed.y)]
            stack.reserveCapacity(4096)
            while let (x0, y) = stack.popLast() {
                if visited[y * w + x0] { continue }
                // scanline
                var x1 = x0
                while x1 >= 0 && !visited[y * w + x1] && matches(y * bpr + x1 * 4) { x1 -= 1 }
                x1 += 1
                var spanUp = false, spanDown = false
                var x = x1
                while x < w && !visited[y * w + x] && matches(y * bpr + x * 4) {
                    visited[y * w + x] = true
                    o[y * obpr + x] = 255
                    if y > 0 {
                        let m = !visited[(y - 1) * w + x] && matches((y - 1) * bpr + x * 4)
                        if !spanUp && m { stack.append((x, y - 1)); spanUp = true } else if spanUp && !m { spanUp = false }
                    }
                    if y < h - 1 {
                        let m = !visited[(y + 1) * w + x] && matches((y + 1) * bpr + x * 4)
                        if !spanDown && m { stack.append((x, y + 1)); spanDown = true } else if spanDown && !m { spanDown = false }
                    }
                    x += 1
                }
            }
        }
        out.markDirty()
        if antialias { return feather(out, radius: 0.8) }
        return out
    }

    /// Color range selection: soft mask of pixels near a color.
    static func colorRange(src: PixelBuffer, color: RGBA, fuzziness: Double) -> PixelBuffer {
        let w = src.width, h = src.height
        let out = PixelBuffer(width: w, height: h, format: .gray)
        let p = src.data.assumingMemoryBound(to: UInt8.self)
        let o = out.data.assumingMemoryBound(to: UInt8.self)
        let cr = Double(color.r8), cg = Double(color.g8), cb = Double(color.b8)
        let f = max(1, fuzziness)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * src.bytesPerRow + x * 4
                let a = Double(p[i + 3])
                if a == 0 { continue }
                let k = 255 / a
                let d = sqrt(pow(Double(p[i]) * k - cr, 2) + pow(Double(p[i + 1]) * k - cg, 2) + pow(Double(p[i + 2]) * k - cb, 2))
                let v = clamp(1 - d / (f * 1.7), 0, 1)
                o[y * out.bytesPerRow + x] = UInt8(v * 255)
            }
        }
        out.markDirty()
        return out
    }

    // MARK: Outline

    /// Marching-ants outline of a mask (threshold 128) as a path of pixel-edge segments.
    static func outline(_ m: PixelBuffer) -> CGPath {
        m.derived("outline") { () -> CGPath in
            let w = m.width, h = m.height
            let p = m.data.assumingMemoryBound(to: UInt8.self)
            let bpr = m.bytesPerRow
            let path = CGMutablePath()
            @inline(__always) func inside(_ x: Int, _ y: Int) -> Bool {
                if x < 0 || y < 0 || x >= w || y >= h { return false }
                return p[y * bpr + x] >= 128
            }
            // Horizontal edges between row y-1 and y
            for y in 0...h {
                var runStart = -1
                var runDir = false
                for x in 0...w {
                    var edge = false, dir = false
                    if x < w {
                        let a = inside(x, y - 1), b = inside(x, y)
                        edge = a != b
                        dir = b
                    }
                    if edge && runStart >= 0 && dir != runDir {
                        path.move(to: CGPoint(x: runStart, y: y)); path.addLine(to: CGPoint(x: x, y: y))
                        runStart = x; runDir = dir
                    } else if edge && runStart < 0 {
                        runStart = x; runDir = dir
                    } else if !edge && runStart >= 0 {
                        path.move(to: CGPoint(x: runStart, y: y)); path.addLine(to: CGPoint(x: x, y: y))
                        runStart = -1
                    }
                }
            }
            // Vertical edges between column x-1 and x, built row by row with open runs
            var open = [Int](repeating: -1, count: w + 1)
            for y in 0...h {
                for x in 0...w {
                    var edge = false
                    if y < h { edge = inside(x - 1, y) != inside(x, y) }
                    if edge && open[x] < 0 { open[x] = y }
                    else if !edge && open[x] >= 0 {
                        path.move(to: CGPoint(x: x, y: open[x])); path.addLine(to: CGPoint(x: x, y: y))
                        open[x] = -1
                    }
                }
            }
            return path
        }
    }

    /// Warps a canvas-size mask with a doc-space homography.
    static func transform(_ m: PixelBuffer, by h: Homography) -> PixelBuffer {
        let space = CanvasSpace(width: m.width, height: m.height)
        let warped = LayerTransformer.warp(m.ciImage, docRect: IRect(x: 0, y: 0, width: m.width, height: m.height), h: h, space: space)
        let img = warped.composited(over: CIImage(color: .black).cropped(to: space.ciCanvas)).cropped(to: space.ciCanvas)
        return RenderEngine.renderBuffer(img, docRect: IRect(x: 0, y: 0, width: m.width, height: m.height), space: space, format: .gray)
    }
}
