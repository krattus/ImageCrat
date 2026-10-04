import AppKit
import CoreImage
import SwiftUI
import ImageCratCore

/// Headless tests for the Nodes module: `LUMEN_SELFTEST_ONLY=nodes .build/debug/Lumen --selftest <dir>`.
/// Sub-filter with `LUMEN_NODES_ONLY=tex,graph,recipes,doc,ui,perf` (comma separated prefixes).
enum NodesSelfTest {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        if ok { print("ok   nodes: \(what)") } else { failures += 1; print("FAIL nodes: \(what)") }
    }

    static func want(_ n: String) -> Bool {
        guard let only = ProcessInfo.processInfo.environment["LUMEN_NODES_ONLY"], !only.isEmpty else { return true }
        return only.split(separator: ",").contains { n.hasPrefix(String($0)) }
    }

    static func run(_ out: URL) {
        failures = 0
        let t0 = CFAbsoluteTimeGetCurrent()
        if want("kern") { kernels() }
        if want("graph") { graphTests(out) }
        if want("lib") { libraryTests(out) }
        if want("editor") { editorTests(out) }
        if want("doc") { documentTests(out) }
        if want("recipes") { recipeTests(out) }
        if want("tex") { textures(out) }
        if want("perf") { perfTests(out) }
        let only = ProcessInfo.processInfo.environment["LUMEN_NODES_ONLY"] ?? ""
        if ProcessInfo.processInfo.environment["LUMEN_SELFTEST_UI"] == "1" || only.contains("ui") { uiSnapshots(out) }
        RecipeRuntime.shared.reset()
        print(String(format: "nodes: finished in %.1fs, %d failure(s)", CFAbsoluteTimeGetCurrent() - t0, failures))
    }

    // MARK: Helpers

    static func writePNG(_ img: CIImage, rect: CGRect, _ name: String, _ out: URL) {
        guard let cg = RenderEngine.cgImage(img, rect: rect) else { print("FAIL nodes: render \(name)"); failures += 1; return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        print("wrote \(name)")
    }

    static func buffer(_ img: CIImage, _ w: Int, _ h: Int) -> PixelBuffer {
        let sp = CanvasSpace(width: w, height: h)
        return RenderEngine.renderBuffer(img, docRect: IRect(x: 0, y: 0, width: w, height: h), space: sp)
    }

    /// Mean absolute difference (0…255) between two same-size RGBA buffers.
    static func meanDiff(_ a: PixelBuffer, _ b: PixelBuffer) -> Double {
        guard a.width == b.width, a.height == b.height else { return 255 }
        let pa = a.data.assumingMemoryBound(to: UInt8.self), pb = b.data.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        for y in 0..<a.height {
            let ra = pa + y * a.bytesPerRow, rb = pb + y * b.bytesPerRow
            for i in 0..<(a.width * 4) { sum += abs(Double(ra[i]) - Double(rb[i])) }
        }
        return sum / Double(a.width * a.height * 4)
    }

    static func maxDiff(_ a: PixelBuffer, _ b: PixelBuffer) -> Int {
        guard a.width == b.width, a.height == b.height else { return 255 }
        let pa = a.data.assumingMemoryBound(to: UInt8.self), pb = b.data.assumingMemoryBound(to: UInt8.self)
        var m = 0
        for y in 0..<a.height {
            let ra = pa + y * a.bytesPerRow, rb = pb + y * b.bytesPerRow
            for i in 0..<(a.width * 4) { m = max(m, abs(Int(ra[i]) - Int(rb[i]))) }
        }
        return m
    }

    /// Standard deviation of luminance (0…255): "is there anything in this image".
    static func lumaStdDev(_ b: PixelBuffer) -> Double {
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        var s = 0.0, s2 = 0.0
        let n = Double(b.width * b.height)
        for y in 0..<b.height {
            let r = p + y * b.bytesPerRow
            for x in 0..<b.width {
                let l = 0.299 * Double(r[x * 4]) + 0.587 * Double(r[x * 4 + 1]) + 0.114 * Double(r[x * 4 + 2])
                s += l; s2 += l * l
            }
        }
        let m = s / n
        return (max(0, s2 / n - m * m)).squareRoot()
    }

    /// Draws labelled cells into a contact sheet.
    static func contactSheet(_ items: [(String, CGImage)], cell: CGSize, columns: Int, _ name: String, _ out: URL) {
        let rows = (items.count + columns - 1) / columns
        let labelH: CGFloat = 16
        let W = Int(cell.width) * columns, H = Int(cell.height + labelH) * rows
        let buf = PixelBuffer(width: W, height: H)
        let ctx = buf.context
        ctx.setFillColor(RGBA(gray: 0.12).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let g = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        for (i, it) in items.enumerated() {
            let cx = CGFloat(i % columns) * cell.width, cy = CGFloat(i / columns) * (cell.height + labelH)
            buf.drawImage(it.1, in: CGRect(x: cx + 1, y: cy + 1, width: cell.width - 2, height: cell.height - 2))
            (it.0 as NSString).draw(at: CGPoint(x: cx + 3, y: cy + cell.height), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white])
        }
        NSGraphicsContext.restoreGraphicsState()
        buf.markDirty()
        let rep = NSBitmapImageRep(cgImage: buf.makeCGImage())
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        print("wrote \(name)")
    }

    // MARK: Kernels

    static func kernels() {
        for (name, ok) in RecipeKernels.allCompiled() { check(ok, "kernel compiles: \(name)") }
        // constant(): values are what the working space sees (premultiplied by us)
        let c = buffer(RecipeKernels.constant(1, 0, 0, 0.5, CGRect(x: 0, y: 0, width: 4, height: 4)), 4, 4)
        let p = c.data.assumingMemoryBound(to: UInt8.self)
        check(abs(Int(p[0]) - 128) <= 2 && abs(Int(p[3]) - 128) <= 2, "constant image is premultiplied once (r=\(p[0]) a=\(p[3]))")
    }

    // MARK: Graph evaluation

    /// Evaluates a graph headlessly and returns the rendered buffer.
    static func render(_ g: RecipeGraph, _ w: Int = 64, _ h: Int = 48, source: CIImage? = nil, target: UUID = UUID(), state: DocumentState? = nil) -> PixelBuffer {
        let sp = CanvasSpace(width: w, height: h)
        return buffer(RecipeRuntime.shared.render(target: target, graph: g, source: source, space: sp, state: state), w, h)
    }

    static func near(_ px: (UInt8, UInt8, UInt8, UInt8), _ r: Int, _ g: Int, _ b: Int, _ a: Int = 255, tol: Int = 3) -> Bool {
        abs(Int(px.0) - r) <= tol && abs(Int(px.1) - g) <= tol && abs(Int(px.2) - b) <= tol && abs(Int(px.3) - a) <= tol
    }

    static func graphTests(_ out: URL) {
        let W = 64, H = 48
        // solid → output
        do {
            var b = RecipeBuilder("solid")
            let s = b.add("in.solid", col: 0, colors: ["color": RGBA(r: 0.2, g: 0.4, b: 0.6)])
            let o = b.add("out.output", col: 1)
            b.wire(s, "Image", o, "Image")
            let px = render(b.graph).pixel(W / 2, H / 2)
            check(near(px, 51, 102, 153), "solid → output = (51,102,153), got \(px)")
        }
        // image × number (number → image conversion)
        do {
            var b = RecipeBuilder("math")
            let s = b.add("in.solid", col: 0, colors: ["color": RGBA(gray: 0.5)])
            let n = b.add("const.number", col: 0, row: 1, ["value": 0.5])
            let m = b.add("imath.op", col: 1, ["op": 2])
            let o = b.add("out.output", col: 2)
            b.wire(s, "Image", m, "A"); b.wire(n, "Value", m, "B"); b.wire(m, "Image", o, "Image")
            // sRGB 0.5 * 0.5 = 0.25 in the (gamma-encoded) working space → 64
            let px = render(b.graph).pixel(10, 10)
            check(near(px, 64, 64, 64), "gray 0.5 × number 0.5 = 64, got \(px)")
        }
        // blend 50 %
        do {
            var b = RecipeBuilder("blend")
            let a = b.add("in.solid", col: 0, colors: ["color": RGBA(r: 1, g: 0, b: 0)])
            let c = b.add("in.solid", col: 0, row: 1, colors: ["color": RGBA(r: 0, g: 0, b: 1)])
            let bl = b.add("comp.blend", col: 1, ["opacity": 50])
            let o = b.add("out.output", col: 2)
            b.wire(a, "Image", bl, "Base"); b.wire(c, "Image", bl, "Blend"); b.wire(bl, "Image", o, "Image")
            let px = render(b.graph).pixel(5, 5)
            check(near(px, 128, 0, 128), "normal blend at 50 % = (128,0,128), got \(px)")
            var g2 = b.graph
            g2.update(bl) { $0.numbers["mode"] = Double(BlendMode.layerModes.firstIndex(of: .multiply)!); $0.numbers["opacity"] = 100 }
            check(near(render(g2).pixel(5, 5), 0, 0, 0), "multiply red × blue = black")
        }
        // crop, shuffle, gradient mask, source + invert
        do {
            var b = RecipeBuilder("crop")
            let s = b.add("in.solid", col: 0, colors: ["color": RGBA(r: 0.2, g: 0.4, b: 0.6)])
            let sh = b.add("chan.shuffle", col: 1, ["r": 2, "g": 1, "b": 0, "a": 3])
            let cr = b.add("xf.crop", col: 2, ["left": 50, "top": 0, "right": 0, "bottom": 0])
            let o = b.add("out.output", col: 3)
            b.wire(s, "Image", sh, "Image"); b.wire(sh, "Image", cr, "Image"); b.wire(cr, "Image", o, "Image")
            let buf = render(b.graph)
            check(buf.pixel(10, 10).3 == 0 && near(buf.pixel(50, 10), 153, 102, 51), "shuffle (B,G,R) + crop left 50 %: left clear, right (153,102,51), got \(buf.pixel(10, 10)) \(buf.pixel(50, 10))")
        }
        do {
            var b = RecipeBuilder("mask")
            let s = b.add("in.solid", col: 0, colors: ["color": .white])
            let gr = b.add("in.gradient", col: 0, row: 1)
            let m = b.add("comp.mask", col: 1)
            let o = b.add("out.output", col: 2)
            b.wire(s, "Image", m, "Image"); b.wire(gr, "Image", m, "Mask"); b.wire(m, "Image", o, "Image")
            let buf = render(b.graph)
            check(buf.pixel(1, 20).3 < 16 && buf.pixel(62, 20).3 > 240 && abs(Int(buf.pixel(32, 20).3) - 128) < 12, "gradient (image → mask conversion) drives alpha: \(buf.pixel(1, 20).3) / \(buf.pixel(32, 20).3) / \(buf.pixel(62, 20).3)")
        }
        do {
            var b = RecipeBuilder("source")
            let s = b.add("in.source", col: 0)
            let inv = b.add("imath.invert", col: 1)
            let o = b.add("out.output", col: 2)
            b.wire(s, "Image", inv, "Image"); b.wire(inv, "Image", o, "Image")
            let src = CIImage.color(RGBA(r: 0.2, g: 0.4, b: 0.6), CGRect(x: 0, y: 0, width: W, height: H))
            check(near(render(b.graph, source: src).pixel(3, 3), 204, 153, 102), "Layer Below → Invert = (204,153,102)")
            check(render(b.graph, source: nil).pixel(3, 3).3 == 0, "no source → transparent")
            // threshold adjust + number → colour parameter socket
            var b2 = RecipeBuilder("adjust")
            let num = b2.add("const.number", col: 0, ["value": 0.6])
            let sol = b2.add("in.solid", col: 1)
            let th = b2.add("adj.threshold", col: 2, ["thresholdLevel": 128])
            let o2 = b2.add("out.output", col: 3)
            b2.wire(num, "Value", sol, "p:color"); b2.wire(sol, "Image", th, "Image"); b2.wire(th, "Image", o2, "Image")
            check(near(render(b2.graph).pixel(3, 3), 255, 255, 255), "number 0.6 → colour socket → Threshold 128 = white")
            var g3 = b2.graph
            g3.update(num) { $0.numbers["value"] = 0.3 }
            check(near(render(g3).pixel(3, 3), 0, 0, 0), "number 0.3 → Threshold 128 = black")
        }
        // filter node (auto-generated from FilterKind) and texture node
        do {
            var b = RecipeBuilder("filter")
            let c = b.add("gen.checker", col: 0, ["scale": 8])
            let bl = b.add("filter.gaussianBlur", col: 1, ["radius": 6])
            let o = b.add("out.output", col: 2)
            b.wire(c, "Image", bl, "Image"); b.wire(bl, "Image", o, "Image")
            let blurred = render(b.graph)
            var g2 = b.graph
            g2.update(bl) { $0.muted = true }
            let sharp = render(g2)
            check(lumaStdDev(sharp) > 100 && lumaStdDev(blurred) < lumaStdDev(sharp) * 0.5, "Gaussian Blur node flattens a checker (σ \(Int(lumaStdDev(sharp))) → \(Int(lumaStdDev(blurred)))); muted node passes through")
        }
        // distance field
        do {
            var b = RecipeBuilder("distance")
            let s = b.add("in.solid", col: 0, colors: ["color": .white])
            let cr = b.add("xf.crop", col: 1, ["left": 50, "top": 0, "right": 0, "bottom": 0])
            let mk = b.add("mask.fromImage", col: 2, ["channel": 4])
            let d = b.add("util.distance", col: 3, ["spread": 16, "mode": 0])
            let o = b.add("out.output", col: 4)
            b.wire(s, "Image", cr, "Image"); b.wire(cr, "Image", mk, "Image"); b.wire(mk, "Mask", d, "Mask"); b.wire(d, "Distance", o, "Image")
            let buf = render(b.graph)
            // mask covers x ≥ 32; at x = 24 the distance is 8 px = 0.5 of the spread
            let v = Int(buf.pixel(24, 20).0)
            check(buf.pixel(40, 20).0 == 0 && abs(v - 128) < 14 && buf.pixel(4, 20).0 > 245, "distance field: inside 0, 8 px out ≈ 128 (\(v)), far = 255")
        }
        // cycles and type checks
        do {
            var g = RecipeGraph()
            let a = RecipeLibrary.makeNode("imath.invert"), b = RecipeLibrary.makeNode("imath.invert"), c = RecipeLibrary.makeNode("imath.invert")
            g.nodes = [a, b, c]
            try? g.connect(from: a.id, "Image", to: b.id, "Image")
            try? g.connect(from: b.id, "Image", to: c.id, "Image")
            var threw: RecipeGraphError? = nil
            do { try g.connect(from: c.id, "Image", to: a.id, "Image") } catch { threw = error as? RecipeGraphError }
            check(threw == .cycle && g.connections.count == 2, "cycle rejected (a → b → c → a)")
            threw = nil
            do { try g.connect(from: a.id, "Image", to: a.id, "Image") } catch { threw = error as? RecipeGraphError }
            check(threw == .sameNode, "self connection rejected")
            let cur = RecipeLibrary.makeNode("const.curve")
            g.nodes.append(cur)
            threw = nil
            do { try g.connect(from: cur.id, "Curve", to: a.id, "Image") } catch { threw = error as? RecipeGraphError }
            check(threw == .incompatible(.curve, .image), "curve → image rejected")
            check(RecipePortType.number.canConvert(to: .color) && RecipePortType.color.canConvert(to: .image) && RecipePortType.image.canConvert(to: .mask)
                  && RecipePortType.gradient.canConvert(to: .image) && !RecipePortType.image.canConvert(to: .number), "conversion table")
            // one wire per input: connecting again replaces
            let s1 = RecipeLibrary.makeNode("in.solid"), s2 = RecipeLibrary.makeNode("in.solid")
            g.nodes += [s1, s2]
            try? g.connect(from: s1.id, "Image", to: a.id, "Image")
            try? g.connect(from: s2.id, "Image", to: a.id, "Image")
            check(g.connections.filter { $0.to == a.id }.count == 1 && g.input(a.id, "Image")?.from == s2.id, "a new wire replaces the old one on an input")
            // a hand-made loop in a file is broken on decode
            var bad = g
            bad.connections.append(RecipeConnection(from: c.id, fromPort: "Image", to: a.id, toPort: "Image"))
            if let data = try? JSONEncoder().encode(bad), let back = try? JSONDecoder().decode(RecipeGraph.self, from: data) {
                let loops = back.nodes.contains { n in back.connections.contains { $0.to == n.id && back.dependsOn($0.from, n.id) } }
                check(!loops, "decoding breaks loops in damaged files")
            } else { check(false, "graph JSON round trip") }
        }
        // caching: only downstream of a change is re-evaluated
        do {
            var b = RecipeBuilder("cache")
            let n1 = b.add("gen.perlin", col: 0)
            let n2 = b.add("filter.gaussianBlur", col: 1, ["radius": 3])
            let n3 = b.add("in.solid", col: 1, row: 1, colors: ["color": RGBA(r: 1, g: 0, b: 0, a: 0.5)])
            let n4 = b.add("comp.blend", col: 2)
            let n5 = b.add("out.output", col: 3)
            let n6 = b.add("in.source", col: 0, row: 2)
            let n7 = b.add("imath.mix", col: 2, row: 1)
            b.wire(n1, "Image", n2, "Image"); b.wire(n2, "Image", n4, "Base"); b.wire(n3, "Image", n4, "Blend")
            b.wire(n4, "Image", n7, "A"); b.wire(n6, "Image", n7, "B"); b.wire(n7, "Image", n5, "Image")
            let id = UUID()
            let sp = CanvasSpace(width: W, height: H)
            let rt = RecipeRuntime.shared
            let src = CIImage.color(.white, sp.ciCanvas)
            _ = rt.render(target: id, graph: b.graph, source: src, space: sp)
            let ev = rt.evaluator(id)
            check(Set(ev.lastEvaluated) == Set([n1, n2, n3, n4, n5, n6, n7]), "first evaluation builds all 7 nodes (\(ev.lastEvaluated.count))")
            _ = rt.render(target: id, graph: b.graph, source: src, space: sp)
            check(ev.lastEvaluated.isEmpty, "unchanged graph + same source: nothing re-evaluated (\(ev.lastEvaluated.count))")
            var g = b.graph
            g.update(n3) { $0.colors["color"] = RGBA(r: 0, g: 1, b: 0, a: 0.5) }
            _ = rt.render(target: id, graph: g, source: src, space: sp)
            check(Set(ev.lastEvaluated) == Set([n3, n4, n7, n5]), "changing the solid re-evaluates solid → blend → mix → output only (\(ev.lastEvaluated.count))")
            g.update(n1) { $0.numbers["seed"] = 7 }
            _ = rt.render(target: id, graph: g, source: src, space: sp)
            check(Set(ev.lastEvaluated) == Set([n1, n2, n4, n7, n5]), "changing the noise seed re-evaluates its 5 downstream nodes (\(ev.lastEvaluated.count))")
            g.update(n1) { $0.position.x += 40; $0.title = "renamed" }
            _ = rt.render(target: id, graph: g, source: src, space: sp)
            check(ev.lastEvaluated.isEmpty, "moving / renaming a node re-evaluates nothing")
            _ = rt.render(target: id, graph: g, source: CIImage.color(.black, sp.ciCanvas), space: sp)
            check(Set(ev.lastEvaluated) == Set([n6, n7, n5]), "a new source image re-evaluates Layer Below → mix → output only (\(ev.lastEvaluated.count))")
        }
        // missing inputs, missing output, unknown nodes
        do {
            var b = RecipeBuilder("missing")
            let bl = b.add("filter.gaussianBlur", col: 0)
            let o = b.add("out.output", col: 1)
            b.wire(bl, "Image", o, "Image")
            let id = UUID()
            let buf = render(b.graph, target: id)
            let errs = RecipeRuntime.shared.errors(target: id)
            check(buf.pixel(5, 5).3 == 0 && errs[bl] != nil && errs[o] == nil, "unconnected filter: transparent result + error on that node (“\(errs[bl] ?? "")”)")
            var g = b.graph
            g.removeNodes([o])
            _ = render(g, target: id)
            check(RecipeRuntime.shared.graphError(target: id) != nil, "graph without an Output node reports it")
            // unknown node type (file from a newer version): passes its input through
            var b2 = RecipeBuilder("unknown")
            let s = b2.add("in.solid", col: 0, colors: ["color": RGBA(r: 0, g: 1, b: 0)])
            var alien = RecipeNode(type: "future.node", position: CGPoint(x: 300, y: 40))
            alien.numbers["x"] = 1
            b2.graph.nodes.append(alien)
            let o2 = b2.add("out.output", col: 2)
            b2.graph.connections.append(RecipeConnection(from: s, fromPort: "Image", to: alien.id, toPort: "Image"))
            b2.graph.connections.append(RecipeConnection(from: alien.id, fromPort: "Image", to: o2, toPort: "Image"))
            let id2 = UUID()
            _ = render(b2.graph, target: id2)
            check(RecipeRuntime.shared.errors(target: id2)[alien.id] != nil, "unknown node type is reported, graph still evaluates")
            // tolerant decoding: unknown keys, missing keys
            let json = #"{"name":"Old","nodes":[{"type":"in.solid","id":"\#(UUID().uuidString)","futureField":3}],"connections":[{"bogus":1}],"somethingNew":{"a":1}}"#
            let dec = try? JSONDecoder().decode(RecipeGraph.self, from: Data(json.utf8))
            check(dec?.nodes.count == 1 && dec?.connections.isEmpty == true && dec?.name == "Old", "tolerant decoding of graphs with unknown / malformed fields")
        }
        // muted generator → transparent; solo shows a node
        do {
            var b = RecipeBuilder("solo")
            let a = b.add("in.solid", col: 0, colors: ["color": RGBA(r: 1, g: 0, b: 0)])
            let inv = b.add("imath.invert", col: 1)
            let o = b.add("out.output", col: 2)
            b.wire(a, "Image", inv, "Image"); b.wire(inv, "Image", o, "Image")
            var g = b.graph
            check(near(render(g).pixel(2, 2), 0, 255, 255), "red → invert = cyan")
            g.solo = a
            check(near(render(g).pixel(2, 2), 255, 0, 0), "solo (view this node) shows the solid")
            g.solo = nil
            g.update(a) { $0.muted = true }
            check(render(g).pixel(2, 2).3 == 0 || near(render(g).pixel(2, 2), 255, 255, 255, 0, tol: 255), "muted input node outputs nothing")
        }
        // time node
        do {
            var b = RecipeBuilder("time")
            let t = b.add("in.time", col: 0)
            let s = b.add("in.solid", col: 1)
            let o = b.add("out.output", col: 2)
            b.wire(t, "Seconds", s, "p:color"); b.wire(s, "Image", o, "Image")
            let a = RecipeClock.withTime(0.25) { render(b.graph).pixel(2, 2) }
            let c = RecipeClock.withTime(0.75) { render(b.graph).pixel(2, 2) }
            check(abs(Int(a.0) - 64) <= 3 && abs(Int(c.0) - 191) <= 3, "Time node drives a colour: t=0.25 → \(a.0), t=0.75 → \(c.0)")
        }
    }

    // MARK: Textures

    /// Largest absolute difference between the two opposite edges of a tile (wrap-around continuity), relative to
    /// the typical difference between neighbouring interior rows / columns.
    static func seamScore(_ b: PixelBuffer) -> (seam: Double, interior: Double) {
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        func px(_ x: Int, _ y: Int, _ c: Int) -> Double { Double(p[y * b.bytesPerRow + x * 4 + c]) }
        var seam = 0.0, inner = 0.0
        var n = 0
        for y in 0..<b.height { for c in 0..<3 {
            seam += abs(px(0, y, c) - px(b.width - 1, y, c))
            inner += abs(px(b.width / 2, y, c) - px(b.width / 2 - 1, y, c)) + abs(px(b.width / 3, y, c) - px(b.width / 3 - 1, y, c))
            n += 1
        } }
        for x in 0..<b.width { for c in 0..<3 {
            seam += abs(px(x, 0, c) - px(x, b.height - 1, c))
            inner += abs(px(x, b.height / 2, c) - px(x, b.height / 2 - 1, c)) + abs(px(x, b.height / 3, c) - px(x, b.height / 3 - 1, c))
            n += 1
        } }
        return (seam / Double(n), inner / Double(2 * n))
    }

    static func textures(_ out: URL) {
        let W = 480, H = 360
        let sp = CanvasSpace(width: W, height: H)
        // determinism by seed, tileability
        var tiles: [(String, CGImage)] = []
        for g in TextureCatalog.all {
            var s = TextureSettings(gen: g.id)
            s.values["seed"] = 11
            let a = buffer(TextureEngine.render(s, space: CanvasSpace(width: 160, height: 120)), 160, 120)
            let a2 = buffer(TextureEngine.render(s, space: CanvasSpace(width: 160, height: 120)), 160, 120)
            s.values["seed"] = 12
            let b = buffer(TextureEngine.render(s, space: CanvasSpace(width: 160, height: 120)), 160, 120)
            let seeded = !["stripes", "checker", "dots", "chevron", "waves", "spirals", "concentric", "guilloche", "plaid", "weave", "stars", "hexgrid", "scanlines", "banding", "plasma", "polka"].contains(g.id)
            check(maxDiff(a, a2) == 0, "deterministic: \(g.id)")
            if seeded { check(meanDiff(a, b) > 0.4, "seed changes the result: \(g.id) (Δ \(String(format: "%.2f", meanDiff(a, b))))") }
            // tileable: one 192×160 tile; opposite edges must continue into each other
            var t = TextureSettings(gen: g.id)
            t.values["scale"] = min(g.scale, 48)
            let tile = TextureEngine.tileBuffer(t, width: 192, height: 160)
            let sc = seamScore(tile)
            check(sc.seam <= max(6, sc.interior * 3.5), "tileable edges continuous: \(g.id) (seam \(String(format: "%.1f", sc.seam)) vs interior \(String(format: "%.1f", sc.interior)))")
            // 2×2 preview of the tile for the contact sheet
            let two = PixelBuffer(width: 384, height: 320)
            for (ox, oy) in [(0, 0), (192, 0), (0, 160), (192, 160)] { two.copyPixels(from: tile, at: IPoint(x: ox, y: oy)) }
            two.markDirty()
            tiles.append((g.name + (g.nativeTile(TextureSettings.defaults(g).values) ? "" : " (blend)"), two.makeCGImage()))
        }
        for (i, chunk) in stride(from: 0, to: tiles.count, by: 20).map({ Array(tiles[$0..<min($0 + 20, tiles.count)]) }).enumerated() {
            contactSheet(chunk, cell: CGSize(width: 240, height: 200), columns: 5, "nodes_tex_tiles_\(i + 1)", out)
        }
        // 1. every generator compiles and renders something
        for cat in TextureCategory.allCases {
            var cells: [(String, CGImage)] = []
            for g in TextureCatalog.byCategory(cat) {
                let ok = TextureEngine.kernel(g) != nil
                check(ok, "kernel compiles: \(g.id)")
                guard ok else { continue }
                let s = TextureSettings(gen: g.id)
                let img = TextureEngine.render(s, space: sp)
                let b = buffer(img, W, H)
                check(lumaStdDev(b) > 1.5, "generator renders detail: \(g.id) (σ=\(String(format: "%.1f", lumaStdDev(b))))")
                cells.append((g.name, b.makeCGImage()))
            }
            contactSheet(cells, cell: CGSize(width: W / 2, height: H / 2), columns: 5, "nodes_tex_\(cat.rawValue.lowercased())", out)
        }
    }
}
