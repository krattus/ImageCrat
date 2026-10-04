import Foundation
import CoreImage
import CoreGraphics
import ImageCratCore

/// Deterministic CPU helpers for number nodes.
enum RecipeMath {
    static func hash(_ i: Int, _ seed: Int) -> Double {
        var x = UInt64(bitPattern: Int64(i)) &* 0x9E3779B97F4A7C15 &+ UInt64(bitPattern: Int64(seed)) &* 0xBF58476D1CE4E5B9
        x ^= x >> 30; x = x &* 0xBF58476D1CE4E5B9
        x ^= x >> 27; x = x &* 0x94D049BB133111EB
        x ^= x >> 31
        return Double(x >> 11) / Double(1 << 53)
    }

    /// Smooth 1-D value noise in 0…1.
    static func noise(_ x: Double, seed: Int) -> Double {
        let i = floor(x), f = x - i
        let u = f * f * (3 - 2 * f)
        return hash(Int(i), seed) * (1 - u) + hash(Int(i) + 1, seed) * u
    }

    static func fbm(_ x: Double, seed: Int, octaves: Int) -> Double {
        var s = 0.0, amp = 0.5, norm = 0.0, fr = 1.0
        for o in 0..<max(1, octaves) {
            s += amp * noise(x * fr, seed: seed &+ o &* 131)
            norm += amp; amp *= 0.5; fr *= 2
        }
        return s / norm
    }
}

/// `.cube` 3-D LUT files for the LUT node.
enum RecipeLUTCache {
    private static var cache: [String: (Date?, Int, Data)] = [:]
    private static let lock = NSLock()

    static func cube(_ path: String) -> (Int, Data)? {
        lock.lock(); defer { lock.unlock() }
        let p = (path as NSString).expandingTildeInPath
        let mod = (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate]) as? Date
        if let c = cache[p], c.0 == mod { return (c.1, c.2) }
        guard let text = try? String(contentsOfFile: p, encoding: .utf8) else { return nil }
        var size = 0
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("LUT_3D_SIZE") { size = Int(line.split(separator: " ").last ?? "") ?? 0; continue }
            if line.first?.isLetter == true { continue }
            let parts = line.split(separator: " ").compactMap { Float($0) }
            if parts.count >= 3 { values.append(contentsOf: [parts[0], parts[1], parts[2], 1]) }
        }
        guard size >= 2, size <= 64, values.count == size * size * size * 4 else { return nil }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        cache[p] = (mod, size, data)
        return (size, data)
    }
}

extension RecipeLibrary {
    private static let image = RecipePortSpec("Image", .image)
    private static let edgeChoices = ["Transparent", "Clamp", "Wrap", "Mirror"]

    /// Resamples `img` through a dest → source affine map with an edge mode.
    static func resample(_ img: CIImage, m: (CGFloat, CGFloat, CGFloat, CGFloat), t: CGPoint, edge: Int, canvas: CGRect) throws -> CIImage {
        guard let k = RecipeKernels.affine else { throw RecipeError.message("Kernel unavailable") }
        let src = edge == 0 ? img : img.clampedToExtent()
        let roi = canvas.insetBy(dx: -2, dy: -2)
        guard let out = k.apply(extent: canvas, roiCallback: { _, _ in roi }, image: src,
                                arguments: [CIVector(cgRect: canvas), CIVector(x: m.0, y: m.1, z: m.2, w: m.3), CIVector(x: t.x, y: t.y), Float(edge)]) else {
            throw RecipeError.message("Transform failed")
        }
        return out
    }

    // MARK: Composite

    static let compositeNodes: [RecipeNodeSpec] = [
        RecipeNodeSpec(type: "comp.blend", name: "Blend", category: .composite,
                       inputs: [RecipePortSpec("Base", .image), RecipePortSpec("Blend", .image), RecipePortSpec("Mask", .mask)],
                       params: [.choice("mode", "Mode", BlendMode.layerModes.map(\.displayName), 0), .slider("opacity", "Opacity", 0...100, 100, unit: "%")],
                       keywords: ["mix", "composite", "over", "multiply", "screen", "overlay", "layer"], bypass: "Base") { ev in
            let base = ev.image("Base") ?? ev.clear
            guard var top = ev.image("Blend") else { ev.set(base); return }
            let mode = BlendMode.layerModes[min(max(0, ev.int("mode")), BlendMode.layerModes.count - 1)]
            if let m = ev.mask("Mask"), let k = Kernels.alphaMultiplyKernel { top = k.apply(extent: ev.canvas, arguments: [top, m]) ?? top }
            ev.set(top.withOpacity(ev.num("opacity") / 100).blended(over: base, mode: mode).cropped(to: ev.canvas))
        },
        RecipeNodeSpec(type: "comp.mask", name: "Apply Mask", category: .composite, group: "Mask",
                       inputs: [image, RecipePortSpec("Mask", .mask)], params: [.toggle("invert", "Invert Mask", false)],
                       keywords: ["cut out", "alpha", "stencil"], bypass: "Image") { ev in
            let img = try ev.need()
            var m = try ev.needMask()
            if ev.bool("invert") { m = RecipeKernels.maskAdjust?.apply(extent: ev.canvas, arguments: [m, CIVector(x: 0, y: 1, z: 1, w: 1), CIVector(x: 0, y: 0, z: 0, w: 0)]) ?? m }
            ev.set(Kernels.alphaMultiplyKernel?.apply(extent: ev.canvas, arguments: [img, m]) ?? img)
        },
        RecipeNodeSpec(type: "mask.fromImage", name: "Image to Mask", category: .composite, group: "Mask", inputs: [image], outputs: [RecipePortSpec("Mask", .mask)],
                       params: [.choice("channel", "Channel", ["Luminance", "Red", "Green", "Blue", "Alpha", "Luminance (ignore alpha)"], 0)],
                       keywords: ["luma", "key", "channel"]) { ev in
            let img = try ev.need()
            ev.setMask(RecipeKernels.toMask?.apply(extent: ev.canvas, arguments: [img, Float(ev.int("channel"))]) ?? img)
        },
        RecipeNodeSpec(type: "mask.combine", name: "Combine Masks", category: .composite, group: "Mask",
                       inputs: [RecipePortSpec("A", .mask), RecipePortSpec("B", .mask)], outputs: [RecipePortSpec("Mask", .mask)],
                       params: [.choice("op", "Operation", ["Multiply (intersect)", "Add (union)", "Subtract", "Maximum", "Minimum", "Difference"], 0)],
                       keywords: ["intersect", "union"], bypass: "A") { ev in
            let a = try ev.needMask("A"), b = try ev.needMask("B")
            ev.setMask(RecipeKernels.maskCombine?.apply(extent: ev.canvas, arguments: [a, b, Float(ev.int("op"))]) ?? a)
        },
        RecipeNodeSpec(type: "mask.invert", name: "Invert Mask", category: .composite, group: "Mask",
                       inputs: [RecipePortSpec("Mask", .mask)], outputs: [RecipePortSpec("Mask", .mask)], bypass: "Mask") { ev in
            let m = try ev.needMask()
            ev.setMask(RecipeKernels.maskAdjust?.apply(extent: ev.canvas, arguments: [m, CIVector(x: 0, y: 1, z: 1, w: 1), CIVector(x: 0, y: 0, z: 0, w: 0)]) ?? m)
        },
        RecipeNodeSpec(type: "mask.feather", name: "Feather Mask", category: .composite, group: "Mask",
                       inputs: [RecipePortSpec("Mask", .mask)], outputs: [RecipePortSpec("Mask", .mask)],
                       params: [.slider("radius", "Radius", 0...250, 12, unit: "px"), .slider("grow", "Expand / Contract", -100...100, 0, unit: "px")],
                       keywords: ["blur", "soften", "expand", "contract", "choke"], bypass: "Mask") { ev in
            var m = try ev.needMask()
            let grow = ev.num("grow")
            if grow > 0.5 { m = m.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: grow]).cropped(to: ev.canvas) }
            if grow < -0.5 { m = m.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: -grow]).cropped(to: ev.canvas) }
            ev.setMask(m.blurred(ev.num("radius"), clampTo: ev.canvas))
        },
        RecipeNodeSpec(type: "mask.threshold", name: "Threshold Mask", category: .composite, group: "Mask",
                       inputs: [RecipePortSpec("Mask", .mask)], outputs: [RecipePortSpec("Mask", .mask)],
                       params: [.slider("level", "Level", 0...1, 0.5), .slider("soft", "Softness", 0...1, 0.02)], bypass: "Mask") { ev in
            let m = try ev.needMask()
            ev.setMask(RecipeKernels.maskAdjust?.apply(extent: ev.canvas, arguments: [m, CIVector(x: 0, y: 1, z: 1, w: 0),
                                                                                         CIVector(x: 1, y: CGFloat(ev.num("level")), z: CGFloat(ev.num("soft")), w: 0)]) ?? m)
        },
        RecipeNodeSpec(type: "mask.levels", name: "Mask Levels", category: .composite, group: "Mask",
                       inputs: [RecipePortSpec("Mask", .mask)], outputs: [RecipePortSpec("Mask", .mask)],
                       params: [.slider("black", "Black Point", 0...1, 0), .slider("white", "White Point", 0...1, 1), .slider("gamma", "Gamma", 0.1...5, 1)], bypass: "Mask") { ev in
            let m = try ev.needMask()
            ev.setMask(RecipeKernels.maskAdjust?.apply(extent: ev.canvas, arguments: [m, CIVector(x: CGFloat(ev.num("black")), y: CGFloat(ev.num("white")), z: CGFloat(ev.num("gamma")), w: 0),
                                                                                         CIVector(x: 0, y: 0, z: 0, w: 0)]) ?? m)
        },
        RecipeNodeSpec(type: "chan.split", name: "Split Channels", category: .composite, group: "Channels", inputs: [image],
                       outputs: [RecipePortSpec("R", .mask), RecipePortSpec("G", .mask), RecipePortSpec("B", .mask), RecipePortSpec("A", .mask)],
                       keywords: ["rgb", "separate"]) { ev in
            let img = try ev.need()
            guard let k = RecipeKernels.toMask else { throw RecipeError.message("Kernel unavailable") }
            ev.out = [1, 2, 3, 4].map { .mask(k.apply(extent: ev.canvas, arguments: [img, Float($0)]) ?? img) }
        },
        RecipeNodeSpec(type: "chan.merge", name: "Merge Channels", category: .composite, group: "Channels",
                       inputs: [RecipePortSpec("R", .mask), RecipePortSpec("G", .mask), RecipePortSpec("B", .mask), RecipePortSpec("A", .mask)],
                       keywords: ["rgb", "combine"]) { ev in
            let black = CIImage.color(.black, ev.canvas), white = CIImage.color(.white, ev.canvas)
            guard let k = RecipeKernels.merge else { throw RecipeError.message("Kernel unavailable") }
            ev.set(k.apply(extent: ev.canvas, arguments: [ev.mask("R") ?? black, ev.mask("G") ?? black, ev.mask("B") ?? black, ev.mask("A") ?? white]) ?? black)
        },
        RecipeNodeSpec(type: "chan.shuffle", name: "Shuffle Channels", category: .composite, group: "Channels", inputs: [image],
                       params: ["Red", "Green", "Blue", "Alpha"].enumerated().map { i, n in
                           RecipeParamSpec.choice(["r", "g", "b", "a"][i], n + " From", ["Red", "Green", "Blue", "Alpha", "Zero", "One", "Luminance"], i)
                       }, keywords: ["swap", "rgb", "bgr"], bypass: "Image") { ev in
            let img = try ev.need()
            let sel = CIVector(x: CGFloat(ev.int("r")), y: CGFloat(ev.int("g")), z: CGFloat(ev.int("b")), w: CGFloat(ev.int("a")))
            ev.set(RecipeKernels.shuffle?.apply(extent: ev.canvas, arguments: [img, sel]) ?? img)
        },
        RecipeNodeSpec(type: "alpha.ops", name: "Alpha", category: .composite, group: "Channels", inputs: [image, RecipePortSpec("Mask", .mask)],
                       params: [.choice("mode", "Operation", ["Set Alpha from Mask", "Multiply Alpha by Mask", "Invert Alpha", "Make Opaque (matte)", "Unpremultiply to Opaque", "Premultiply"], 0),
                                .color("matte", "Matte Color", .black)],
                       keywords: ["transparency", "premultiply", "matte", "opaque"], bypass: "Image") { ev in
            let img = try ev.need()
            let mode = ev.int("mode")
            let m = ev.mask("Mask") ?? CIImage.color(.white, ev.canvas)
            if mode <= 1 && !ev.connected("Mask") { throw RecipeError.missingInput("Mask") }
            let c = ev.color("matte")
            ev.set(RecipeKernels.alphaOp?.apply(extent: ev.canvas, arguments: [img, m, Float(mode), CIVector(x: CGFloat(c.r), y: CGFloat(c.g), z: CGFloat(c.b), w: 1)]) ?? img)
        },
    ]

    // MARK: Transform

    static let transformNodes: [RecipeNodeSpec] = [
        RecipeNodeSpec(type: "xf.translate", name: "Translate", category: .transform, inputs: [image],
                       params: [.slider("dx", "X", -4000...4000, 0, unit: "px"), .slider("dy", "Y", -4000...4000, 0, unit: "px"), .choice("edge", "Edges", edgeChoices, 0)],
                       keywords: ["move", "shift"], bypass: "Image") { ev in
            let img = try ev.need()
            ev.set(try resample(img, m: (1, 0, 0, 1), t: CGPoint(x: -ev.num("dx"), y: ev.num("dy")), edge: ev.int("edge"), canvas: ev.canvas))
        },
        RecipeNodeSpec(type: "xf.scale", name: "Scale", category: .transform, inputs: [image],
                       params: [.slider("sx", "Width", 1...1000, 100, unit: "%"), .slider("sy", "Height", 1...1000, 100, unit: "%"), .toggle("uniform", "Uniform (use Width)", true),
                                .point("center", "Center"), .choice("edge", "Edges", edgeChoices, 0)],
                       keywords: ["resize", "zoom"], bypass: "Image") { ev in
            let img = try ev.need()
            let sx = CGFloat(max(0.01, ev.num("sx") / 100)), sy = ev.bool("uniform") ? sx : CGFloat(max(0.01, ev.num("sy") / 100))
            let c = ev.ciPoint("center")
            ev.set(try resample(img, m: (1 / sx, 0, 0, 1 / sy), t: CGPoint(x: c.x - c.x / sx, y: c.y - c.y / sy), edge: ev.int("edge"), canvas: ev.canvas))
        },
        RecipeNodeSpec(type: "xf.rotate", name: "Rotate", category: .transform, inputs: [image],
                       params: [.slider("angle", "Angle", -360...360, 0, unit: "°"), .point("center", "Center"), .choice("edge", "Edges", edgeChoices, 0)],
                       keywords: ["turn", "spin"], bypass: "Image") { ev in
            let img = try ev.need()
            let th = ev.num("angle") * .pi / 180
            let cs = CGFloat(cos(th)), sn = CGFloat(sin(th))
            let c = ev.ciPoint("center")
            // clockwise on screen: source = c + R(θ)(d − c)
            ev.set(try resample(img, m: (cs, -sn, sn, cs), t: CGPoint(x: c.x - (cs * c.x - sn * c.y), y: c.y - (sn * c.x + cs * c.y)), edge: ev.int("edge"), canvas: ev.canvas))
        },
        RecipeNodeSpec(type: "xf.tile", name: "Tile", category: .transform, inputs: [image],
                       params: [.int("nx", "Columns", 1...32, 3), .int("ny", "Rows", 1...32, 3), .toggle("mirror", "Mirror Alternate Tiles", false)],
                       keywords: ["repeat", "grid", "pattern"], bypass: "Image") { ev in
            let img = try ev.need()
            let nx = CGFloat(ev.int("nx")), ny = CGFloat(ev.int("ny"))
            let c = ev.canvas
            // tiles start at the top-left of the canvas
            ev.set(try resample(img, m: (nx, 0, 0, ny), t: CGPoint(x: c.minX * (1 - nx), y: c.maxY * (1 - ny)), edge: ev.bool("mirror") ? 3 : 2, canvas: c))
        },
        RecipeNodeSpec(type: "xf.mirror", name: "Mirror", category: .transform, inputs: [image],
                       params: [.choice("mode", "Mode", ["Left onto Right", "Right onto Left", "Top onto Bottom", "Bottom onto Top", "Four-way"], 0), .point("center", "Axis")],
                       keywords: ["flip", "reflect", "symmetry", "kaleidoscope"], bypass: "Image") { ev in
            let img = try ev.need()
            guard let k = RecipeKernels.mirror else { throw RecipeError.message("Kernel unavailable") }
            let c = ev.ciPoint("center"), roi = ev.canvas
            ev.set(k.apply(extent: ev.canvas, roiCallback: { _, _ in roi }, image: img.clampedToExtent(),
                           arguments: [CIVector(x: c.x, y: c.y), Float(ev.int("mode"))]) ?? img)
        },
        RecipeNodeSpec(type: "xf.offset", name: "Offset (wrap)", category: .transform, inputs: [image],
                       params: [.slider("x", "Horizontal", -100...100, 50, unit: "%"), .slider("y", "Vertical", -100...100, 50, unit: "%")],
                       keywords: ["wrap", "seam", "shift"], bypass: "Image") { ev in
            let img = try ev.need()
            let c = ev.canvas
            ev.set(try resample(img, m: (1, 0, 0, 1), t: CGPoint(x: -CGFloat(ev.num("x")) / 100 * c.width, y: CGFloat(ev.num("y")) / 100 * c.height), edge: 2, canvas: c))
        },
        RecipeNodeSpec(type: "xf.crop", name: "Crop", category: .transform, inputs: [image],
                       params: [.slider("left", "Left", 0...100, 10, unit: "%"), .slider("top", "Top", 0...100, 10, unit: "%"),
                                .slider("right", "Right", 0...100, 10, unit: "%"), .slider("bottom", "Bottom", 0...100, 10, unit: "%"), .slider("feather", "Feather", 0...250, 0, unit: "px")],
                       keywords: ["trim", "window", "rectangle"], bypass: "Image") { ev in
            let img = try ev.need()
            let c = ev.canvas
            let l = CGFloat(ev.num("left")) / 100 * c.width, r = CGFloat(ev.num("right")) / 100 * c.width
            let t = CGFloat(ev.num("top")) / 100 * c.height, b = CGFloat(ev.num("bottom")) / 100 * c.height
            let rect = CGRect(x: c.minX + l, y: c.minY + b, width: max(0, c.width - l - r), height: max(0, c.height - t - b))
            let f = ev.num("feather")
            if f < 0.5 { ev.set(img.cropped(to: rect).composited(over: ev.clear)); return }
            let m = CIImage.color(.white, rect).composited(over: CIImage.color(.black, c)).blurred(f, clampTo: c)
            ev.set(Kernels.alphaMultiplyKernel?.apply(extent: c, arguments: [img, m]) ?? img)
        },
        RecipeNodeSpec(type: "xf.displace", name: "Displace by Map", category: .transform, inputs: [image, RecipePortSpec("Map", .image)],
                       params: [.slider("sx", "Strength X", -500...500, 20, unit: "px"), .slider("sy", "Strength Y", -500...500, 20, unit: "px"), .choice("edge", "Edges", ["Transparent", "Clamp"], 1)],
                       keywords: ["distort", "warp", "refraction", "glass"], bypass: "Image") { ev in
            let img = try ev.need()
            let map = try ev.need("Map")
            guard let k = RecipeKernels.displace else { throw RecipeError.message("Kernel unavailable") }
            let sx = CGFloat(ev.num("sx")), sy = CGFloat(ev.num("sy"))
            let src = ev.int("edge") == 1 ? img.clampedToExtent() : img
            ev.set(k.apply(extent: ev.canvas, roiCallback: { i, r in i == 0 ? r.insetBy(dx: -abs(sx) - 2, dy: -abs(sy) - 2) : r },
                           arguments: [src, map.clampedToExtent(), CIVector(x: sx, y: sy)]) ?? img)
        },
        RecipeNodeSpec(type: "xf.polar", name: "Polar Coordinates", category: .transform, inputs: [image],
                       params: [.choice("mode", "Mode", ["Rectangular to Polar", "Polar to Rectangular"], 0)], keywords: ["radial", "planet", "unwrap"], bypass: "Image") { ev in
            let img = try ev.need()
            guard let k = Kernels.polarWarp else { throw RecipeError.message("Kernel unavailable") }
            let c = ev.canvas
            ev.set(k.apply(extent: c, roiCallback: { _, _ in c }, image: img.clampedToExtent(),
                           arguments: [CIVector(x: c.midX, y: c.midY), CIVector(cgRect: c), Float(ev.int("mode") == 0 ? 1 : 0)]) ?? img)
        },
    ]

    // MARK: Math

    private static let bigRange: ClosedRange<Double> = -10000...10000

    static let mathNodes: [RecipeNodeSpec] = [
        // Constants
        RecipeNodeSpec(type: "const.number", name: "Number", category: .math, group: "Constants", outputs: [RecipePortSpec("Value", .number)],
                       params: [.slider("value", "Value", -1000...1000, 1)], keywords: ["constant", "value", "float"]) { ev in ev.out = [.number(ev.num("value"))] },
        RecipeNodeSpec(type: "const.color", name: "Color", category: .math, group: "Constants", outputs: [RecipePortSpec("Color", .color)],
                       params: [.color("color", "Color", RGBA(hex: "E94F37")!)], keywords: ["constant", "rgb"]) { ev in ev.out = [.color(ev.color("color"))] },
        RecipeNodeSpec(type: "const.vector", name: "Vector / Point", category: .math, group: "Constants", outputs: [RecipePortSpec("Vector", .vector)],
                       params: [.point("value", "Value")], keywords: ["constant", "position", "xy"]) { ev in ev.out = [.vector(ev.point("value"))] },
        RecipeNodeSpec(type: "const.gradient", name: "Gradient Ramp", category: .math, group: "Constants", outputs: [RecipePortSpec("Gradient", .gradient)],
                       params: [.gradient("gradient", "Gradient", ColorGradient.presets[3])], keywords: ["constant", "ramp", "colors"]) { ev in ev.out = [.gradient(ev.gradient("gradient"))] },
        RecipeNodeSpec(type: "const.curve", name: "Curve", category: .math, group: "Constants", outputs: [RecipePortSpec("Curve", .curve)],
                       params: [.curve("curve", "Curve")], keywords: ["constant", "tone curve"]) { ev in ev.out = [.curve(ev.curve("curve"))] },
        // Numbers
        RecipeNodeSpec(type: "math.op", name: "Number Math", category: .math, group: "Number", outputs: [RecipePortSpec("Value", .number)],
                       params: [.choice("op", "Operation", ["Add", "Subtract", "Multiply", "Divide", "Power", "Minimum", "Maximum", "Modulo", "Sine (A·B)", "Cosine (A·B)",
                                                            "Absolute (A)", "Floor (A)", "Round (A)", "One Minus (1 − A)"], 0),
                                .slider("a", "A", bigRange, 1), .slider("b", "B", bigRange, 1)],
                       keywords: ["add", "multiply", "subtract", "divide", "arithmetic"]) { ev in
            let a = ev.num("a"), b = ev.num("b")
            let v: Double
            switch ev.int("op") {
            case 0: v = a + b
            case 1: v = a - b
            case 2: v = a * b
            case 3: v = abs(b) < 1e-12 ? 0 : a / b
            case 4: v = pow(a, b)
            case 5: v = min(a, b)
            case 6: v = max(a, b)
            case 7: v = abs(b) < 1e-12 ? 0 : a - b * floor(a / b)
            case 8: v = sin(a * b)
            case 9: v = cos(a * b)
            case 10: v = abs(a)
            case 11: v = floor(a)
            case 12: v = a.rounded()
            default: v = 1 - a
            }
            ev.out = [.number(v.isFinite ? v : 0)]
        },
        RecipeNodeSpec(type: "math.mix", name: "Number Mix", category: .math, group: "Number", outputs: [RecipePortSpec("Value", .number)],
                       params: [.slider("a", "A", bigRange, 0), .slider("b", "B", bigRange, 1), .slider("t", "Factor", 0...1, 0.5)], keywords: ["lerp", "interpolate"]) { ev in
            ev.out = [.number(ev.num("a") + (ev.num("b") - ev.num("a")) * ev.num("t"))]
        },
        RecipeNodeSpec(type: "math.clamp", name: "Number Clamp", category: .math, group: "Number", outputs: [RecipePortSpec("Value", .number)],
                       params: [.slider("value", "Value", bigRange, 0), .slider("lo", "Minimum", bigRange, 0), .slider("hi", "Maximum", bigRange, 1)], keywords: ["limit"]) { ev in
            ev.out = [.number(min(max(ev.num("value"), ev.num("lo")), max(ev.num("lo"), ev.num("hi"))))]
        },
        RecipeNodeSpec(type: "math.remap", name: "Number Remap", category: .math, group: "Number", outputs: [RecipePortSpec("Value", .number)],
                       params: [.slider("value", "Value", bigRange, 0), .slider("inLo", "From Min", bigRange, 0), .slider("inHi", "From Max", bigRange, 1),
                                .slider("outLo", "To Min", bigRange, 0), .slider("outHi", "To Max", bigRange, 100), .toggle("clamp", "Clamp", true)],
                       keywords: ["map range", "scale", "fit"]) { ev in
            let d = ev.num("inHi") - ev.num("inLo")
            var t = abs(d) < 1e-12 ? 0 : (ev.num("value") - ev.num("inLo")) / d
            if ev.bool("clamp") { t = min(max(t, 0), 1) }
            ev.out = [.number(ev.num("outLo") + t * (ev.num("outHi") - ev.num("outLo")))]
        },
        RecipeNodeSpec(type: "math.compare", name: "Number Compare", category: .math, group: "Number", outputs: [RecipePortSpec("Value", .number)],
                       params: [.choice("op", "Test", ["A > B", "A < B", "A ≈ B"], 0), .slider("a", "A", bigRange, 0), .slider("b", "B", bigRange, 0.5),
                                .slider("eps", "Tolerance", 0...10, 0.001)], keywords: ["greater", "less", "equal", "if"]) { ev in
            let a = ev.num("a"), b = ev.num("b")
            let r: Bool
            switch ev.int("op") { case 0: r = a > b; case 1: r = a < b; default: r = abs(a - b) <= ev.num("eps") }
            ev.out = [.number(r ? 1 : 0)]
        },
        RecipeNodeSpec(type: "math.random", name: "Random Number", category: .math, group: "Number", outputs: [RecipePortSpec("Value", .number)],
                       params: [.seed(), .slider("lo", "Minimum", bigRange, 0), .slider("hi", "Maximum", bigRange, 1)], keywords: ["seed", "random"]) { ev in
            ev.out = [.number(ev.num("lo") + RecipeMath.hash(0, ev.int("seed")) * (ev.num("hi") - ev.num("lo")))]
        },
        RecipeNodeSpec(type: "math.noise", name: "Noise Value", category: .math, group: "Number", outputs: [RecipePortSpec("Value", .number)],
                       params: [.slider("x", "Position (e.g. Time)", bigRange, 0), .seed(), .slider("frequency", "Frequency", 0.01...50, 1), .int("octaves", "Octaves", 1...6, 2),
                                .slider("lo", "Minimum", bigRange, 0), .slider("hi", "Maximum", bigRange, 1)],
                       keywords: ["wiggle", "jitter", "animate", "random", "driven"]) { ev in
            let n = RecipeMath.fbm(ev.num("x") * ev.num("frequency"), seed: ev.int("seed"), octaves: ev.int("octaves"))
            ev.out = [.number(ev.num("lo") + n * (ev.num("hi") - ev.num("lo")))]
        },
        // Colors & vectors
        RecipeNodeSpec(type: "color.mix", name: "Color Mix", category: .math, group: "Color", outputs: [RecipePortSpec("Color", .color)],
                       params: [.color("a", "A", .black), .color("b", "B", .white), .slider("t", "Factor", 0...1, 0.5)], keywords: ["blend", "lerp"]) { ev in
            ev.out = [.color(ev.color("a").mix(ev.color("b"), ev.num("t")))]
        },
        RecipeNodeSpec(type: "color.hsv", name: "Color from HSV", category: .math, group: "Color", outputs: [RecipePortSpec("Color", .color)],
                       params: [.slider("h", "Hue", 0...1, 0.58), .slider("s", "Saturation", 0...1, 0.8), .slider("v", "Value", 0...1, 0.9), .slider("a", "Alpha", 0...1, 1)],
                       keywords: ["hue", "rainbow"]) { ev in
            ev.out = [.color(RGBA(h: ev.num("h"), s: ev.num("s"), v: ev.num("v"), a: ev.num("a")))]
        },
        RecipeNodeSpec(type: "vec.combine", name: "Combine XY", category: .math, group: "Color", outputs: [RecipePortSpec("Vector", .vector)],
                       params: [.slider("x", "X", bigRange, 0.5), .slider("y", "Y", bigRange, 0.5)], keywords: ["vector", "point"]) { ev in
            ev.out = [.vector(CGPoint(x: ev.num("x"), y: ev.num("y")))]
        },
        RecipeNodeSpec(type: "vec.split", name: "Split XY", category: .math, group: "Color", outputs: [RecipePortSpec("X", .number), RecipePortSpec("Y", .number)],
                       params: [.point("value", "Vector")], keywords: ["vector", "separate"]) { ev in
            let p = ev.point("value")
            ev.out = [.number(Double(p.x)), .number(Double(p.y))]
        },
        // Images
        RecipeNodeSpec(type: "imath.op", name: "Image Math", category: .math, group: "Image", inputs: [RecipePortSpec("A", .image), RecipePortSpec("B", .image)],
                       params: [.choice("op", "Operation", ["Add", "Subtract", "Multiply", "Divide", "Minimum", "Maximum", "Difference", "Screen", "Power", "Average"], 2),
                                .toggle("clamp", "Clamp to 0…1", true)],
                       keywords: ["add", "multiply", "subtract", "pixel"], bypass: "A") { ev in
            let a = try ev.need("A"), b = try ev.need("B")
            ev.set(RecipeKernels.math?.apply(extent: ev.canvas, arguments: [a, b, Float(ev.int("op")), Float(ev.num("clamp"))]) ?? a)
        },
        RecipeNodeSpec(type: "imath.mix", name: "Mix", category: .math, group: "Image", inputs: [RecipePortSpec("A", .image), RecipePortSpec("B", .image), RecipePortSpec("Factor", .mask)],
                       params: [.slider("amount", "Amount", 0...1, 0.5)], keywords: ["lerp", "crossfade", "blend"], bypass: "A") { ev in
            let a = ev.image("A") ?? ev.clear, b = ev.image("B") ?? ev.clear
            let f = ev.mask("Factor") ?? CIImage.color(.white, ev.canvas)
            ev.set(RecipeKernels.mix?.apply(extent: ev.canvas, arguments: [a, b, f, Float(ev.num("amount"))]) ?? a)
        },
        RecipeNodeSpec(type: "imath.clamp", name: "Clamp", category: .math, group: "Image", inputs: [image],
                       params: [.slider("lo", "Minimum", 0...1, 0), .slider("hi", "Maximum", 0...1, 1)], bypass: "Image") { ev in
            let img = try ev.need()
            ev.set(RecipeKernels.clampK?.apply(extent: ev.canvas, arguments: [img, Float(ev.num("lo")), Float(max(ev.num("lo"), ev.num("hi")))]) ?? img)
        },
        RecipeNodeSpec(type: "imath.remap", name: "Remap", category: .math, group: "Image", inputs: [image],
                       params: [.slider("inLo", "From Min", -1...2, 0), .slider("inHi", "From Max", -1...2, 1), .slider("outLo", "To Min", -1...2, 0),
                                .slider("outHi", "To Max", -1...2, 1), .toggle("clamp", "Clamp", true)], keywords: ["levels", "range", "contrast"], bypass: "Image") { ev in
            let img = try ev.need()
            let r = CIVector(x: CGFloat(ev.num("inLo")), y: CGFloat(ev.num("inHi")), z: CGFloat(ev.num("outLo")), w: CGFloat(ev.num("outHi")))
            ev.set(RecipeKernels.remap?.apply(extent: ev.canvas, arguments: [img, r, Float(ev.num("clamp"))]) ?? img)
        },
        RecipeNodeSpec(type: "imath.invert", name: "Invert", category: .math, group: "Image", inputs: [image], keywords: ["negative"], bypass: "Image") { ev in
            let img = try ev.need()
            ev.set(RecipeKernels.invert?.apply(extent: ev.canvas, arguments: [img]) ?? img)
        },
        RecipeNodeSpec(type: "imath.compare", name: "Compare", category: .math, group: "Image", inputs: [RecipePortSpec("A", .image), RecipePortSpec("B", .image)],
                       outputs: [RecipePortSpec("Mask", .mask)],
                       params: [.choice("op", "Test", ["A > B", "A < B", "A ≈ B"], 0), .slider("soft", "Softness", 0...0.5, 0.01)],
                       keywords: ["threshold", "greater", "halftone", "step"]) { ev in
            let a = try ev.need("A"), b = try ev.need("B")
            ev.setMask(RecipeKernels.compare?.apply(extent: ev.canvas, arguments: [a, b, Float(ev.int("op")), Float(ev.num("soft"))]) ?? a)
        },
    ]

    // MARK: Utility

    static let utilityNodes: [RecipeNodeSpec] = [
        RecipeNodeSpec(type: "util.blurByMask", name: "Blur by Mask", category: .utility, inputs: [image, RecipePortSpec("Mask", .mask)],
                       params: [.slider("radius", "Max Radius", 0...200, 20, unit: "px")], keywords: ["variable blur", "depth of field", "tilt shift", "lens"], bypass: "Image") { ev in
            let img = try ev.need()
            let m = try ev.needMask()
            ev.set(img.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: ["inputMask": m, kCIInputRadiusKey: ev.num("radius")]).cropped(to: ev.canvas))
        },
        RecipeNodeSpec(type: "util.edge", name: "Edge Detect", category: .utility, inputs: [image], outputs: [RecipePortSpec("Edges", .mask)],
                       params: [.slider("strength", "Strength", 0...10, 2), .slider("radius", "Width", 1...6, 1, unit: "px")], keywords: ["sobel", "outline", "lines"]) { ev in
            let img = try ev.need()
            guard let k = RecipeKernels.sobel else { throw RecipeError.message("Kernel unavailable") }
            let r = CGFloat(ev.num("radius"))
            let flat = img.composited(over: CIImage.color(.white, ev.canvas)).clampedToExtent()
            ev.setMask(k.apply(extent: ev.canvas, roiCallback: { _, rr in rr.insetBy(dx: -r - 1, dy: -r - 1) }, arguments: [flat, Float(ev.num("strength")), Float(r)]) ?? img)
        },
        RecipeNodeSpec(type: "util.distance", name: "Distance Field", category: .utility, inputs: [RecipePortSpec("Mask", .mask)], outputs: [RecipePortSpec("Distance", .mask)],
                       params: [.slider("spread", "Spread", 1...1024, 64, unit: "px"), .choice("mode", "Measure", ["Outside the Mask", "Inside the Mask", "Both (0.5 at the edge)"], 0)],
                       keywords: ["sdf", "glow", "outline", "bevel", "stroke"]) { ev in
            let m = try ev.needMask()
            let sp = ev.num("spread")
            let outside = RecipeKernels.distance(toSet: m, inverted: false, spread: sp, extent: ev.canvas)     // 0 inside, grows outward
            let inside = RecipeKernels.distance(toSet: m, inverted: true, spread: sp, extent: ev.canvas)       // 0 outside, grows inward
            switch ev.int("mode") {
            case 0: ev.setMask(outside)
            case 1: ev.setMask(inside)
            default:
                // 0.5 + (outside − inside) / 2
                let half = CIVector(x: 0.5, y: 0, z: 0, w: 0)
                let o = outside.applyingFilter("CIColorMatrix", parameters: ["inputRVector": half, "inputGVector": CIVector(x: 0, y: 0.5, z: 0, w: 0),
                                                                             "inputBVector": CIVector(x: 0, y: 0, z: 0.5, w: 0), "inputBiasVector": CIVector(x: 0.5, y: 0.5, z: 0.5, w: 0)])
                let i = inside.applyingFilter("CIColorMatrix", parameters: ["inputRVector": half, "inputGVector": CIVector(x: 0, y: 0.5, z: 0, w: 0),
                                                                            "inputBVector": CIVector(x: 0, y: 0, z: 0.5, w: 0)])
                ev.setMask(RecipeKernels.maskCombine?.apply(extent: ev.canvas, arguments: [o, i, 2]) ?? o)
            }
        },
        RecipeNodeSpec(type: "util.normal", name: "Normal Map from Height", category: .utility, inputs: [RecipePortSpec("Height", .image)],
                       outputs: [RecipePortSpec("Normal", .image)], params: [.slider("strength", "Strength", 0...50, 8), .toggle("flip", "Flip Green (DirectX)", false)],
                       keywords: ["bump", "relief", "3d"]) { ev in
            let h = try ev.need("Height")
            guard let k = RecipeKernels.normalMap else { throw RecipeError.message("Kernel unavailable") }
            let flat = h.composited(over: CIImage.color(.black, ev.canvas)).clampedToExtent()
            ev.set(k.apply(extent: ev.canvas, roiCallback: { _, r in r.insetBy(dx: -2, dy: -2) }, arguments: [flat, Float(ev.num("strength")), Float(ev.num("flip"))]) ?? h)
        },
        RecipeNodeSpec(type: "util.light", name: "Light", category: .utility, inputs: [RecipePortSpec("Normal", .image), RecipePortSpec("Albedo", .image)],
                       params: [.slider("angle", "Light Angle", -180...180, 135, unit: "°"), .slider("elevation", "Elevation", 0...90, 45, unit: "°"), .color("color", "Light Color", .white),
                                .slider("ambient", "Ambient", 0...1, 0.25), .slider("diffuse", "Diffuse", 0...3, 1.1), .slider("specular", "Specular", 0...2, 0.35),
                                .slider("shininess", "Shininess", 1...200, 40), .color("base", "Base Color (no Albedo)", RGBA(gray: 0.75))],
                       keywords: ["relight", "shade", "3d", "bump", "specular"], bypass: "Albedo") { ev in
            let n = try ev.need("Normal")
            let b = ev.color("base")
            let alb = ev.image("Albedo") ?? RecipeKernels.constant(b.r, b.g, b.b, 1, ev.canvas)
            let a = ev.num("angle") * .pi / 180, e = ev.num("elevation") * .pi / 180
            let L = CIVector(x: CGFloat(cos(a) * cos(e)), y: CGFloat(sin(a) * cos(e)), z: CGFloat(sin(e)))
            let c = ev.color("color")
            let p = CIVector(x: CGFloat(ev.num("ambient")), y: CGFloat(ev.num("diffuse")), z: CGFloat(ev.num("specular")), w: CGFloat(ev.num("shininess")))
            ev.set(RecipeKernels.light?.apply(extent: ev.canvas, arguments: [n, alb, L, CIVector(x: CGFloat(c.r), y: CGFloat(c.g), z: CGFloat(c.b), w: 1), p]) ?? alb)
        },
        RecipeNodeSpec(type: "util.ao", name: "Ambient Occlusion", category: .utility, inputs: [RecipePortSpec("Height", .image)], outputs: [RecipePortSpec("AO", .mask)],
                       params: [.slider("radius", "Radius", 1...64, 10, unit: "px"), .slider("strength", "Strength", 0...4, 1.5)], keywords: ["shadow", "crevice", "cavity"]) { ev in
            let h = try ev.need("Height")
            guard let k = RecipeKernels.ambientOcclusion else { throw RecipeError.message("Kernel unavailable") }
            let r = CGFloat(ev.num("radius"))
            let flat = h.composited(over: CIImage.color(.black, ev.canvas)).clampedToExtent()
            ev.setMask(k.apply(extent: ev.canvas, roiCallback: { _, rr in rr.insetBy(dx: -r - 1, dy: -r - 1) }, arguments: [flat, Float(r), Float(ev.num("strength"))]) ?? h)
        },
        RecipeNodeSpec(type: "util.dither", name: "Dither / Posterize", category: .utility, inputs: [image],
                       params: [.int("levels", "Levels", 2...32, 2), .choice("pattern", "Pattern", ["Bayer 4×4", "Bayer 8×8", "Noise", "None (posterize)"], 1),
                                .toggle("mono", "Monochrome", false), .int("cell", "Pixel Size", 1...16, 1)],
                       keywords: ["1-bit", "retro", "posterize", "quantize", "gameboy", "riso"], bypass: "Image") { ev in
            let img = try ev.need()
            ev.set(RecipeKernels.dither?.apply(extent: ev.canvas, arguments: [img, Float(ev.int("levels")), Float(ev.int("pattern")), Float(ev.num("mono")), Float(ev.int("cell"))]) ?? img)
        },
        RecipeNodeSpec(type: "util.gradientMap", name: "Gradient Map", category: .utility, inputs: [image],
                       params: [.gradient("gradient", "Gradient", ColorGradient.presets[3]), .slider("amount", "Amount", 0...1, 1)],
                       keywords: ["color ramp", "duotone", "tint", "false color", "colorize"], bypass: "Image") { ev in
            let img = try ev.need()
            guard let k = RecipeKernels.ramp else { throw RecipeError.message("Kernel unavailable") }
            let lut = TextureEngine.lut(ev.gradient("gradient"))
            let le = lut.extent
            ev.set(k.apply(extent: ev.canvas, roiCallback: { i, r in i == 0 ? r : le }, arguments: [img, lut, Float(ev.num("amount"))]) ?? img)
        },
        RecipeNodeSpec(type: "util.curves", name: "Curves (from Curve)", category: .utility, inputs: [image],
                       params: [.curve("curve", "Curve"), .choice("channel", "Channel", ["RGB", "Red", "Green", "Blue"], 0)], keywords: ["tone", "contrast"], bypass: "Image") { ev in
            let img = try ev.need()
            var s = AdjustmentSettings(kind: .curves)
            s.curves[min(3, max(0, ev.int("channel")))] = ev.curve("curve")
            ev.set(AdjustmentEngine.apply(s, to: img))
        },
        RecipeNodeSpec(type: "util.lut", name: "LUT", category: .utility, inputs: [image],
                       params: [.choice("look", "Look", AdjustmentSettings.lookNames + ["Custom .cube File"], 0), .file("path", ".cube File"), .slider("amount", "Amount", 0...1, 1)],
                       keywords: ["color lookup", "grade", "film look", "cube"], bypass: "Image") { ev in
            let img = try ev.need()
            let look = ev.int("look")
            var graded: CIImage
            if look < AdjustmentSettings.lookNames.count {
                var s = AdjustmentSettings(kind: .colorLookup)
                s.lookName = AdjustmentSettings.lookNames[look]
                graded = AdjustmentEngine.apply(s, to: img)
            } else {
                let path = ev.string("path")
                if path.isEmpty { throw RecipeError.message("Choose a .cube file") }
                guard let (size, data) = RecipeLUTCache.cube(path) else { throw RecipeError.message("Can't read LUT: \((path as NSString).lastPathComponent)") }
                graded = img.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": size, "inputCubeData": data]).cropped(to: ev.canvas)
            }
            let amt = ev.num("amount")
            if amt < 0.999 { graded = RecipeKernels.mix?.apply(extent: ev.canvas, arguments: [img, graded, CIImage.color(.white, ev.canvas), Float(amt)]) ?? graded }
            ev.set(graded)
        },
        RecipeNodeSpec(type: "util.seamless", name: "Make Seamless Tile", category: .utility, inputs: [image],
                       params: [.slider("blend", "Edge Blend", 0.02...0.5, 0.25), .toggle("preview", "Preview Tiled 2×2", false)],
                       keywords: ["tileable", "pattern", "wrap", "repeat"], bypass: "Image") { ev in
            let img = try ev.need()
            var out = TextureEngine.makeSeamless(img, blend: ev.num("blend"))
            if ev.bool("preview") {
                let c = ev.canvas
                out = TextureEngine.tiled(out.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))).cropped(to: c)
            }
            ev.set(out)
        },
    ]

    // MARK: Output

    static let outputNodes: [RecipeNodeSpec] = [
        RecipeNodeSpec(type: outputNodeType, name: "Output", category: .output, inputs: [image, RecipePortSpec("Mask", .mask)],
                       keywords: ["result", "final"], bypass: "Image") { ev in
            var img = ev.image() ?? ev.clear
            if let m = ev.mask("Mask"), let k = Kernels.alphaMultiplyKernel { img = k.apply(extent: ev.canvas, arguments: [img, m]) ?? img }
            ev.set(img)
        },
    ]
}
