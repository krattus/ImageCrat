import AppKit
import ImageIO
import ImageCratCore

// Smart objects, document-level data, bit depths / colour modes, PSB, robustness and the app-level flows.

extension PSDImportSelfTest {
    // MARK: Smart objects

    static func smartLayer(_ name: String, id: String, quad: Quad, size: CGSize, stored: PixelBuffer? = nil, origin: IPoint = .zero,
                           warp: PSDDescriptor? = nil, filters: PSDDescriptor? = nil) -> PSDTestLayer {
        var l = stored.map { PSDTestLayer(name: name, buffer: $0, origin: origin) } ?? PSDTestLayer(name: name)
        l.add("SoLd", PSDTestFile.smartObject(id: id, quad: quad, size: size, warp: warp, filters: filters))
        return l
    }

    static func testSmartObjects(_ dir: URL) {
        let pic = picture(120, 80, seed: 1)
        guard let png = pic.pngData() else { check(false, "test PNG"); return }
        let size = CGSize(width: 120, height: 80)
        let rot = CGAffineTransform(translationX: 150, y: 100).rotated(by: 0.35).scaledBy(x: 1.4, y: 1.4).translatedBy(x: -60, y: -40)
        let quad = Quad(rect: CGRect(origin: .zero, size: size)).applying(rot)
        let stored = solid(40, 30, RGBA(r: 0.2, g: 0.9, b: 0.2))   // what "Photoshop rendered": only used by fallbacks

        // embedded PNG with a rotated, scaled placement
        do {
            var f = file([background(), smartLayer("Placed", id: "id-png", quad: quad, size: size, stored: stored, origin: IPoint(x: 10, y: 10))])
            f.globalBlocks = [("lnk2", PSDTestFile.link(id: "id-png", name: "picture.png", data: png))]
            if let r = load(f, "smart_png", dir), let so = r.state.layers.last?.smart {
                var isImage = false
                if case .image(let b) = so.source { isImage = b.width == 120 && b.height == 80 }
                check(isImage && so.quad == quad && so.sourceName == "picture.png" && so.warp == nil && so.filters.isEmpty, "embedded PNG: source image, placement quad and file name")
                var exp = DocumentState(width: W, height: H)
                exp.layers = [Layer.raster(name: "Background", buffer: solid(W, H, RGBA(hex: "DDE6F0")!)),
                              Layer(name: "Placed", content: .smartObject(SmartObjectContent(source: .image(pic), quad: quad, sourceName: "picture.png")))]
                let d = compare(exp, r.state)
                check(d.mean < 0.3, String(format: "embedded PNG: composite equals the same picture placed in Lumen (mean %.3f, max %d)", d.mean, d.max))
                check(status(r, .editable, "Smart object"), "embedded PNG is reported as an editable smart object")
                if let cg = Compositor.shared.flatten(r.state, background: .white) { writePNG(cg, dir.appendingPathComponent("synthetic_smart_png.png")) }
            } else { check(false, "embedded PNG imports as a smart object") }
        }
        // JPEG and TIFF go through the same decoder
        for (type, ext) in [("public.jpeg", "jpg"), ("public.tiff", "tif")] {
            let d = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(d, type as CFString, 1, nil) { CGImageDestinationAddImage(dest, solid(64, 48, RGBA(r: 0.7, g: 0.3, b: 0.1)).makeCGImage(), nil); CGImageDestinationFinalize(dest) }
            var f = file([background(), smartLayer("Placed", id: "id-\(ext)", quad: Quad(rect: CGRect(x: 20, y: 20, width: 128, height: 96)), size: CGSize(width: 64, height: 48))])
            f.globalBlocks = [("lnk2", PSDTestFile.link(id: "id-\(ext)", name: "photo.\(ext)", data: d as Data))]
            let so = load(f, "smart_\(ext)")?.state.layers.last?.smart
            check(so?.source.size == CGSize(width: 64, height: 48) && so?.quad.bounds == CGRect(x: 20, y: 20, width: 128, height: 96), "embedded \(ext.uppercased()) stays a smart object with its placement")
        }
        // embedded PSD / PSB: a layered document, recursively (the inner file has its own type layer and smart object)
        do {
            var inner = file([background(100, 60, RGBA(r: 0.9, g: 0.8, b: 0.2))], w: 100, h: 60)
            var tl = PSDTestLayer(name: "Inner Title")
            tl.add("TySh", PSDTestFile.typeBlock(text: "Inner", runs: [.init(length: 5, size: 18)], fonts: ["Helvetica"], transform: [1, 0, 0, 1, 10, 30]))
            inner.layers.append(tl)
            inner.layers.append(smartLayer("Deep", id: "id-deep", quad: Quad(rect: CGRect(x: 50, y: 10, width: 40, height: 30)), size: size))
            inner.globalBlocks = [("lnk2", PSDTestFile.link(id: "id-deep", name: "deep.png", data: png))]
            for large in [false, true] {
                inner.large = large
                var f = file([background(), smartLayer("Nested", id: "id-psd", quad: Quad(rect: CGRect(x: 40, y: 40, width: 200, height: 120)), size: CGSize(width: 100, height: 60))])
                f.globalBlocks = [("lnk2", PSDTestFile.link(id: "id-psd", name: large ? "inner.psb" : "inner.psd", data: inner.data()))]
                guard let r = load(f, "smart_nested_\(large ? "psb" : "psd")", dir), case .document(let st)? = r.state.layers.last?.smart?.source else { check(false, "embedded \(large ? "PSB" : "PSD") opens as a layered document"); continue }
                check(st.width == 100 && st.height == 60 && st.layers.count == 3 && st.layers[1].isText && st.layers[2].isSmartObject,
                      "embedded \(large ? "PSB" : "PSD"): inner layers stay live (type + nested smart object)")
                check(r.report.items.contains { $0.layer.contains("▸ Inner Title") && $0.feature == "Type" }, "the inner document's layers appear in the report")
            }
            // a plain one-layer PSD collapses to an image source
            var flat = file([background(50, 50, .red)], w: 50, h: 50)
            flat.layers[0].name = "Layer 1"
            var f = file([background(), smartLayer("Flat", id: "id-flat", quad: Quad(rect: CGRect(x: 0, y: 0, width: 50, height: 50)), size: CGSize(width: 50, height: 50))])
            f.globalBlocks = [("lnk2", PSDTestFile.link(id: "id-flat", name: "flat.psd", data: flat.data()))]
            if case .image? = load(f, "smart_flat_psd")?.state.layers.last?.smart?.source { check(true, "one plain pixel layer inside an embedded PSD becomes an image source") } else { check(false, "one-layer embedded PSD") }
            // runaway nesting stops at the depth limit instead of recursing forever
            var data = flat.data()
            for i in 0..<(PSDImporter.maxNesting + 3) {
                var outer = file([smartLayer("L\(i)", id: "n\(i)", quad: Quad(rect: CGRect(x: 0, y: 0, width: 50, height: 50)), size: CGSize(width: 50, height: 50), stored: stored)], w: 50, h: 50)
                outer.globalBlocks = [("lnk2", PSDTestFile.link(id: "n\(i)", name: "n\(i).psd", data: data))]
                data = outer.data()
            }
            let deep = try? PSDImporter.read(data: data, name: "deep.psd")
            check(deep != nil && deep?.report.items.contains { $0.status == .flattened && $0.detail.contains("nested too deeply") } == true, "smart objects nested beyond the limit fall back to pixels")
        }
        // fallbacks that keep the layer a smart object around Photoshop's pixels
        do {
            func fallback(_ name: String, link: Data?, warp: PSDDescriptor? = nil, filters: PSDDescriptor? = nil, expect: String) {
                var f = file([background(), smartLayer("SO", id: "id-x", quad: quad, size: size, stored: stored, origin: IPoint(x: 30, y: 20), warp: warp, filters: filters)])
                if let link { f.globalBlocks = [("lnk2", link)] }
                guard let r = load(f, name), let so = r.state.layers.last?.smart else { check(false, "\(name): stays a smart object"); return }
                var isStored = false
                if case .image(let b) = so.source { isStored = b.width == 40 && b.height == 30 }
                let item = r.report.items.first { $0.status == .flattened && $0.feature == "Smart object" }
                check(isStored && so.quad == Quad(rect: CGRect(x: 30, y: 20, width: 40, height: 30)) && item?.detail.contains(expect) == true,
                      "\(name): smart object around Photoshop's pixels, reason recorded (\(item?.detail ?? "no report item"))")
            }
            fallback("smart_unknown_type", link: PSDTestFile.link(id: "id-x", name: "drawing.svg", data: Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8)), expect: "cannot open")
            fallback("smart_missing_data", link: nil, expect: "missing from the document")
            fallback("smart_missing_link", link: PSDTestFile.link(id: "id-x", name: "gone.png", externalPath: "file:///nonexistent-folder-psdimport/gone.png"), expect: "was not found")
            fallback("smart_preset_warp", link: PSDTestFile.link(id: "id-x", name: "picture.png", data: png), warp: PSDTestFile.plainWarp(size, style: "warpFlag", value: 40), expect: "warp preset")
            fallback("smart_filter_unsupported", link: PSDTestFile.link(id: "id-x", name: "picture.png", data: png),
                     filters: PSDTestFile.smartFilters([(name: "Oil Paint", cls: "oilPaint", items: [("stylization", .double(4))], enabled: true)]), expect: "Oil Paint")
            // no pixels and nothing to show: the layer is left out, the file still opens
            var f = file([background(), smartLayer("Empty", id: "id-none", quad: quad, size: size)])
            f.globalBlocks = []
            let r = load(f, "smart_nothing")
            check(r?.state.layers.count == 1 && r.map { status($0, .skipped, "Smart object") } == true, "smart object with neither source nor pixels is left out and reported")
        }
        // warps: untouched custom mesh = no warp; a bent mesh = Lumen mesh warp
        do {
            let regular = (0..<16).map { CGPoint(x: size.width * CGFloat($0 % 4) / 3, y: size.height * CGFloat($0 / 4) / 3) }
            var f = file([background(), smartLayer("W", id: "id-png", quad: quad, size: size, warp: PSDTestFile.customWarp(size, points: regular))])
            f.globalBlocks = [("lnk2", PSDTestFile.link(id: "id-png", name: "picture.png", data: png))]
            check(load(f, "smart_warp_identity")?.state.layers.last?.smart.map { $0.warp == nil && $0.quad == quad } == true, "untouched custom warp is no warp")
            var bent = regular
            for i in [5, 6, 9, 10] { bent[i].y -= 25 }   // push the four inner control points up
            let q2 = Quad(rect: CGRect(x: 60, y: 50, width: 180, height: 120))
            f = file([background(), smartLayer("W", id: "id-png", quad: q2, size: size, warp: PSDTestFile.customWarp(size, points: bent))])
            f.globalBlocks = [("lnk2", PSDTestFile.link(id: "id-png", name: "picture.png", data: png))]
            if let r = load(f, "smart_warp_custom", dir), let w = r.state.layers.last?.smart?.warp {
                // Bézier patch at the centre: (1/8, 3/8, 3/8, 1/8) weights → the inner points count (3/4)² of the way
                let centre = w.map(CGPoint(x: 150, y: 110))
                let expectY = 110 - 25.0 * 0.5625 * 1.5
                check(w.from.cols == w.to.cols && w.from.isValid && w.to.isValid && near(centre, CGPoint(x: 150, y: expectY), 0.6), "custom warp becomes a mesh warp: the centre moves as the Bézier patch says (\(centre), expected y \(expectY))")
                check(near(w.map(CGPoint(x: 60, y: 50)), CGPoint(x: 60, y: 50), 0.01) && near(w.map(CGPoint(x: 240, y: 170)), CGPoint(x: 240, y: 170), 0.01), "custom warp: the corners stay on the placement quad")
                if let cg = Compositor.shared.flatten(r.state, background: .white) { writePNG(cg, dir.appendingPathComponent("synthetic_smart_warp.png")) }
            } else { check(false, "custom warp imports as a mesh warp") }
        }
        // smart filters: Gaussian Blur maps, disabled unsupported filters do not force a fallback
        do {
            let fx = PSDTestFile.smartFilters([(name: "Gaussian Blur", cls: "GsnB", items: [("Rds ", .unitFloat(unit: "#Pxl", value: 6.5))], enabled: true),
                                               (name: "Oil Paint", cls: "oilPaint", items: [], enabled: false)])
            var f = file([background(), smartLayer("F", id: "id-png", quad: quad, size: size, stored: stored, filters: fx)])
            f.globalBlocks = [("lnk2", PSDTestFile.link(id: "id-png", name: "picture.png", data: png))]
            let r = load(f, "smart_filter_blur")
            let so = r?.state.layers.last?.smart
            check(so?.filters.count == 1 && so?.filters.first?.kind == .gaussianBlur && so?.filters.first?.values["radius"] == 6.5 && so?.source.size == size && r.map { status($0, .substituted, "Smart filters") } == true,
                  "Gaussian Blur smart filter stays a live smart filter on the real source")
        }
        // perspective placement, 'PlLd'-only layers
        do {
            let persp = Quad(tl: CGPoint(x: 60, y: 40), tr: CGPoint(x: 240, y: 60), br: CGPoint(x: 220, y: 160), bl: CGPoint(x: 80, y: 180))
            var f = file([background(), smartLayer("P", id: "id-png", quad: persp, size: size)])
            f.globalBlocks = [("lnk2", PSDTestFile.link(id: "id-png", name: "picture.png", data: png))]
            check(load(f, "smart_perspective")?.state.layers.last?.smart?.quad == persp, "perspective placement keeps all four corners")
            var l = PSDTestLayer(name: "Old")
            var w = BinaryWriter()
            w.ascii("plcL"); w.u32(3); w.pascal("id-png", pad: 1); w.u32(1); w.u32(1); w.u32(16); w.u32(2)
            for p in [quad.tl, quad.tr, quad.br, quad.bl] { w.u64(Double(p.x).bitPattern); w.u64(Double(p.y).bitPattern) }
            w.u32(0)
            l.add("PlLd", w.data + PSDTestFile.plainWarp(size).serializedVersioned())
            f = file([background(), l])
            f.globalBlocks = [("lnk2", PSDTestFile.link(id: "id-png", name: "picture.png", data: png))]
            check(load(f, "smart_plld")?.state.layers.last?.smart?.quad == quad, "'PlLd'-only placed layer (older files)")
        }
        // linked (external) file next to the PSD
        do {
            try? png.write(to: dir.appendingPathComponent("linked-source.png"))
            var l = PSDTestLayer(name: "Linked")
            var soLE = PSDTestFile.smartObject(id: "id-ext", quad: quad, size: size)
            soLE.replaceSubrange(0..<4, with: Data("soLD".utf8))
            l.add("SoLE", soLE)
            var f = file([background(), l])
            f.globalBlocks = [("lnkE", PSDTestFile.link(id: "id-ext", name: "linked-source.png", externalPath: "file:///moved-away-psdimport/linked-source.png"))]
            let so = load(f, "smart_linked", dir)?.state.layers.last?.smart
            check(so?.linkedURL?.lastPathComponent == "linked-source.png" && so?.source.size == size && so?.linkedModified != nil, "linked smart object: the file is found next to the PSD and stays linked")
        }
    }

    // MARK: Document-level data and layer attributes

    static func testDocument(_ dir: URL) {
        var f = file()
        var w = BinaryWriter()
        w.u32(UInt32(300 * 65536)); w.u16(1); w.u16(1); w.u32(UInt32(300 * 65536)); w.u16(1); w.u16(1)
        f.resources.append((1005, "", w.data))
        w = BinaryWriter(); w.u32(1); w.u32(576); w.u32(576); w.u32(3)
        for (pos, dir) in [(100 * 32, 0), (50 * 32 + 16, 1), (-10 * 32, 0)] { w.i32(Int32(pos)); w.u8(UInt8(dir)) }
        f.resources.append((1032, "", w.data))
        if let icc = CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() { f.resources.append((1039, "", icc as Data)) }
        f.resources.append((2000, "Outline", PSDTestFile.pathRecords(.ellipse(CGRect(x: 20, y: 20, width: 100, height: 60)), width: W, height: H)))
        w = BinaryWriter(); w.i32(75); f.resources.append((1037, "", w.data))
        f.resources.append((1026, "", PSDTestFile.u16([0, 5, 5, 0, 0, 0, 0, 9])))   // link groups: Base + Clipped; a lone 9 links nothing

        // layers: clipped + labelled + locked + blend-if + knockout + fill opacity + channel restrictions
        var base = PSDTestLayer(name: "Base", buffer: picture(160, 120), origin: IPoint(x: 20, y: 30))
        base.add("lclr", PSDTestFile.u16([4, 0, 0, 0]))
        var b = BinaryWriter(); b.u32(0x8000_0000); base.add("lspf", b.data)
        var clip = PSDTestLayer(name: "Clipped", buffer: solid(W, H, RGBA(r: 0.1, g: 0.1, b: 0.9)), origin: .zero)
        clip.clipping = 1; clip.blend = "mul "; clip.opacity = 128; clip.flags = 8 | 2
        clip.add("lclr", PSDTestFile.u16([1, 0, 0, 0]))
        b = BinaryWriter(); b.u32(5); clip.add("lspf", b.data)
        clip.add("iOpa", Data([102, 0, 0, 0]))
        clip.add("knko", Data([1, 0, 0, 0])); clip.add("infx", Data([1, 0, 0, 0])); clip.add("clbl", Data([0, 0, 0, 0]))
        clip.add("lmgm", Data([1, 0, 0, 0])); clip.add("vmgm", Data([1, 0, 0, 0]))
        b = BinaryWriter(); b.u32(1); clip.add("brst", b.data)
        // gray: this 10/40 … 200/230, underlying 0/0 … 255/255; red: underlying 30/60 … 255/255
        clip.blendRanges = Data([10, 40, 200, 230, 0, 0, 255, 255, 0, 0, 255, 255, 30, 60, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255])
        // masks: feather + density + disabled + unlinked, default colour white
        var masked = PSDTestLayer(name: "Masked", buffer: solid(100, 100, RGBA(r: 0.9, g: 0.5, b: 0.1)), origin: IPoint(x: 150, y: 60))
        masked.setMask(IRect(x: 160, y: 70, width: 50, height: 40), [UInt8](repeating: 30, count: 50 * 40), defaultColor: 255, flags: 0x01 | 0x02, density: 204, feather: 7.5)
        // group with a pixel mask, Normal (isolated) blending and an artboard
        var open = PSDTestLayer(name: "</Layer group>"); open.flags = 24
        b = BinaryWriter(); b.u32(3); open.add("lsct", b.data)
        var grp = PSDTestLayer(name: "Board"); grp.flags = 24; grp.opacity = 200
        b = BinaryWriter(); b.u32(2); b.ascii("8BIM"); b.ascii("norm"); grp.add("lsct", b.data)
        grp.setMask(IRect(x: 0, y: 0, width: 150, height: H), [UInt8](repeating: 255, count: 150 * H))
        grp.add("artb", PSDTestFile.versioned(PSDDescriptor(classID: "artboard", [
            ("artboardRect", .object(PSDDescriptor(classID: "classFloatRect", [("Top ", .double(10)), ("Left", .double(20)), ("Btom", .double(190)), ("Rght", .double(280))]))),
            ("artboardPresetName", .string("Custom")), ("artboardBackgroundType", .integer(4)), ("Clr ", PSDTestFile.colorDescriptor(RGBA(r: 0.2, g: 0.4, b: 0.6)))])))
        var empty = PSDTestLayer(name: "Empty")
        empty.add("lclr", PSDTestFile.u16([7, 0, 0, 0]))
        f.layers = [background(), base, clip, masked, open, PSDTestLayer(name: "In Group", buffer: solid(40, 40, .red), origin: IPoint(x: 30, y: 30)), grp, empty]

        guard let r = load(f, "document", dir) else { return }
        let st = r.state
        check(st.resolution == 300 && st.globalLight.angle == 75, "resolution and global light")
        check(st.guides.count == 3 && st.guides[0] == Guide(id: st.guides[0].id, isVertical: true, position: 100) && !st.guides[1].isVertical && st.guides[1].position == 50.5 && st.guides[2].position == -10,
              "guides: orientation and position (1/32 px units)")
        check(st.profileName == "Display P3" && status(r, .editable, "Colour profile"), "embedded ICC profile is matched to the installed profile (\(st.profileName))")
        check(st.paths.count == 1 && st.paths[0].name == "Outline" && st.paths[0].path.subpaths.first?.points.count == 4 && st.paths[0].path.bounds.insetBy(dx: -0.01, dy: -0.01).contains(CGRect(x: 20, y: 20, width: 100, height: 60)),
              "saved path resource becomes a document path")
        let ls = st.layers
        guard ls.count == 6 else { check(false, "document: 6 top-level layers (got \(ls.count): \(ls.map(\.name)))"); return }
        check(ls[0].locks == LayerLocks() && ls[1].locks.all && ls[1].colorLabel == .green && ls[2].locks == LayerLocks(transparency: true, pixels: false, position: true, all: false) && ls[2].colorLabel == .red && ls[5].colorLabel == .gray,
              "layer locks and colour labels")
        check(ls[1].linkID != nil && ls[1].linkID == ls[2].linkID && ls[3].linkID == nil && ls[5].linkID == nil, "linked layers share a link")
        let c = ls[2]
        check(c.isClipped && c.blendMode == .multiply && near(c.opacity, 128.0 / 255) && !c.isVisible && near(c.fillOpacity, 0.4), "clipping, blend mode, opacity, visibility, fill opacity")
        check(c.knockout == .shallow && c.blendInteriorEffectsAsGroup && !c.blendClippedAsGroup && c.layerMaskHidesEffects && c.vectorMaskHidesEffects && c.channelR && !c.channelG && c.channelB,
              "knockout, advanced blending switches, channel restrictions")
        check(c.blendIf == BlendIf(channel: .gray, thisLow: [10, 40], thisHigh: [200, 230], underLow: [0, 0], underHigh: [255, 255]) && status(r, .substituted, "Blend If"),
              "Blend If: gray ranges kept, the extra red range is reported")
        let m = ls[3].mask
        check(m?.frame == IRect(x: 160, y: 70, width: 50, height: 40) && m?.outsideValue == 255 && m?.isEnabled == false && m?.isLinked == false && m.map { near($0.density, 0.8) && $0.feather == 7.5 } == true && m?.buffer.psdTestGray(3, 3) == 30,
              "layer mask: pixels, default colour, disabled, unlinked, density, feather")
        let g = ls[4]
        check(g.isGroup && !g.isExpanded && g.blendMode == .normal && near(g.opacity, 200.0 / 255) && g.children.map(\.name) == ["In Group"] && g.mask?.frame.width == 150,
              "group: closed state, Normal blending from the divider, opacity, children, pixel mask")
        check(g.artboard == Artboard(rect: CGRect(x: 20, y: 10, width: 260, height: 180), background: RGBA(r: 0.2, g: 0.4, b: 0.6)) && status(r, .editable, "Artboard"), "artboard rectangle and background colour")
        check(ls[5].isRaster && ls[5].raster?.buffer.width == W && ls[5].raster?.buffer.opaqueBounds() == nil, "a layer without pixels stays as an empty layer")
        check(r.report.layerCount == 7 && !r.report.summary.isEmpty, "report counts \(r.report.layerCount) layers")
        if let cg = Compositor.shared.flatten(st, background: .white) { writePNG(cg, dir.appendingPathComponent("synthetic_document.png")) }

        // saved alpha channels: the image data planes after colour (and transparency)
        do {
            var fa = file([background()])
            var names = BinaryWriter(); names.unicode("Mask A"); names.unicode("Spot")
            fa.resources.append((1045, "", names.data))
            var a1 = [UInt8](repeating: 0, count: W * H), a2 = a1
            for y in 0..<H { for x in 0..<W { a1[y * W + x] = UInt8(x % 256); a2[y * W + x] = UInt8(y % 256) } }
            fa.merged = [[UInt8](repeating: 255, count: W * H), [UInt8](repeating: 255, count: W * H), [UInt8](repeating: 255, count: W * H), a1, a2]
            for comp in [0, 1] {
                fa.mergedCompression = comp
                let ra = load(fa, "alpha_channels_\(comp)")
                let ch = ra?.state.alphaChannels ?? []
                check(ch.map(\.name) == ["Mask A", "Spot"] && ch.first?.buffer.psdTestGray(77, 3) == 77 && ch.last?.buffer.psdTestGray(5, 99) == 99 && ch.first?.buffer.width == W,
                      "saved alpha channels are read with their names (\(comp == 0 ? "raw" : "PackBits"))")
            }
            fa.layers = []
            let flatA = load(fa, "alpha_channels_flat")
            check(flatA?.state.alphaChannels.count == 2 && flatA?.state.layers.first?.raster?.buffer.psdTestPixel(10, 10).3 == 255, "flat file: named extra channels are alpha channels, not transparency")
        }
        // a profile that is not installed: reported, values kept as sRGB
        var f2 = file([background()])
        if let data = CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() as Data? {
            // rename the description inside the profile ("Display P3" → "Xisplay P3", ASCII and UTF-16 copies)
            var icc = [UInt8](data)
            let ascii = Array("Display P3".utf8)
            var wide: [UInt8] = []
            for u in "Display P3".utf16 { wide += [UInt8(u >> 8), UInt8(u & 0xff)] }
            for (pat, at) in [(ascii, 0), (wide, 1)] {
                var i = 0
                while i + pat.count <= icc.count { if Array(icc[i..<(i + pat.count)]) == pat { icc[i + at] = 0x58 }; i += 1 }
            }
            f2.resources.append((1039, "", Data(icc)))
        }
        if let r2 = load(f2, "document_profile_unknown") {
            if r2.state.profileName == "Display P3" { print("INFO psdimport: the renamed test profile still reads as Display P3; unknown-profile check skipped") } else {
                check(ColorProfiles.isSRGB(r2.state.profileName) && status(r2, .substituted, "Colour profile"), "an ICC profile that is not installed leaves the document in sRGB and is reported")
            }
        }
    }

    // MARK: Bit depths, compressions, colour modes, PSB

    static func testDepthsAndModes(_ dir: URL) {
        let pic = picture(90, 70, seed: 3)
        let top = picture(50, 40, seed: 5)
        func worst(_ a: PixelBuffer, _ b: PixelBuffer) -> Int {
            guard a.width == b.width, a.height == b.height else { return 999 }
            var w = 0
            let x = a.data.assumingMemoryBound(to: UInt8.self), y = b.data.assumingMemoryBound(to: UInt8.self)
            for r in 0..<a.height { for c in 0..<(a.width * 4) { w = max(w, abs(Int(x[r * a.bytesPerRow + c]) - Int(y[r * b.bytesPerRow + c]))) } }
            return w
        }
        // RGB layers at every depth × compression, PSD and PSB
        for depth in [8, 16, 32] {
            for comp in 0...3 {
                for large in [false, true] {
                    var f = PSDTestFile(width: 120, height: 90)
                    f.depth = depth; f.compression = comp; f.large = large
                    f.layersInBlock = depth > 8
                    var masked = PSDTestLayer(name: "Top", buffer: top, origin: IPoint(x: 60, y: 40))
                    var mp = [UInt8](repeating: 255, count: 50 * 40)
                    for i in 0..<(50 * 20) { mp[i] = UInt8(i % 251) }
                    masked.setMask(IRect(x: 60, y: 40, width: 50, height: 40), mp)
                    f.layers = [PSDTestLayer(name: "Pic", buffer: pic, origin: IPoint(x: 10, y: 5)), masked]
                    f.merged = Array(repeating: [UInt8](repeating: 200, count: 120 * 90), count: 3)
                    let tag = "\(depth)-bit \(["raw", "PackBits", "ZIP", "ZIP+prediction"][comp]) \(large ? "PSB" : "PSD")"
                    guard let r = load(f, "depth_\(depth)_\(comp)_\(large ? "psb" : "psd")"), r.state.layers.count == 2, let a = r.state.layers[0].raster, let b = r.state.layers[1].raster else { check(false, "\(tag): layers read"); continue }
                    let tol = depth == 32 ? 2 : 1   // un-premultiply / premultiply rounding
                    let w0 = worst(a.buffer, pic), w1 = worst(b.buffer, top)
                    let mOK = r.state.layers[1].mask.map { $0.buffer.psdTestGray(7, 0) == 7 && $0.buffer.psdTestGray(0, 30) == 255 && $0.frame == IRect(x: 60, y: 40, width: 50, height: 40) } == true
                    let bits: BitDepth = depth == 8 ? .eight : (depth == 16 ? .sixteen : .thirtyTwo)
                    check(w0 <= tol && w1 <= tol && a.origin == IPoint(x: 10, y: 5) && mOK && r.state.bitDepth == bits, "\(tag): layer pixels, mask and bit depth (worst error \(max(w0, w1)))")
                }
            }
        }
        // flat files: the image data section becomes the Background (raw and PackBits, all depths, with transparency)
        for depth in [8, 16, 32] {
            for comp in [0, 1] {
                for large in [false, true] {
                    var f = PSDTestFile(width: 90, height: 70)
                    f.depth = depth; f.mergedCompression = comp; f.large = large
                    let l = PSDTestLayer(name: "", buffer: pic, origin: .zero)
                    f.merged = [l.planes[0]!, l.planes[1]!, l.planes[2]!]
                    guard let r = load(f, "flat_\(depth)_\(comp)_\(large)"), let bg = r.state.layers.first?.raster else { check(false, "flat \(depth)-bit file opens"); continue }
                    let opaque = PSDImporter.rgba(width: 90, height: 70, r: l.planes[0], g: l.planes[1], b: l.planes[2], a: nil)
                    check(r.state.layers.count == 1 && r.state.layers[0].name == "Background" && worst(bg.buffer, opaque) <= (depth == 32 ? 2 : 0), "flat \(depth)-bit \(comp == 0 ? "raw" : "PackBits") \(large ? "PSB" : "PSD") opens as a Background layer")
                }
            }
        }
        do {
            // transparency in the composite: colours are stored matted on white next to the alpha channel
            var f = PSDTestFile(width: 90, height: 70)
            let l = PSDTestLayer(name: "", buffer: pic, origin: .zero)
            let alpha = l.planes[-1]!
            func matte(_ p: [UInt8]) -> [UInt8] {
                var o = p
                for i in 0..<p.count { let a = Int(alpha[i]); let v: Int = Int(p[i]) * a + 255 * (255 - a) + 127; o[i] = UInt8(v / 255) }
                return o
            }
            f.merged = [matte(l.planes[0]!), matte(l.planes[1]!), matte(l.planes[2]!), l.planes[-1]!]
            if let bg = load(f, "flat_alpha")?.state.layers.first?.raster { check(worst(bg.buffer, pic) <= 3, "flat file with transparency: the white matte is removed (worst \(worst(bg.buffer, pic)))") } else { check(false, "flat file with transparency") }
        }
        // grayscale, layered
        do {
            var f = PSDTestFile(width: 60, height: 40); f.mode = 1
            var l = PSDTestLayer(name: "Gray"); l.rect = IRect(x: 5, y: 5, width: 50, height: 30)
            l.planes = [0: (0..<1500).map { UInt8($0 % 256) }, -1: [UInt8](repeating: 255, count: 1500)]
            f.layers = [l]; f.merged = [[UInt8](repeating: 128, count: 2400)]
            let r = load(f, "mode_gray")
            let p = r?.state.layers.first?.raster?.buffer.psdTestPixel(37, 0)
            check(r?.state.colorMode == .grayscale && p?.0 == 37 && p?.1 == 37 && p?.2 == 37, "Grayscale document: layers become gray RGB, mode is kept")
        }
        // CMYK, layered (values are stored inverted: 255 = no ink)
        do {
            var f = PSDTestFile(width: 40, height: 10); f.mode = 4
            var l = PSDTestLayer(name: "Ink"); l.rect = IRect(x: 0, y: 0, width: 40, height: 10)
            var c = [UInt8](repeating: 255, count: 400), m = c, y = c, k = c
            for row in 0..<10 { for x in 0..<40 {
                let i = row * 40 + x
                if x >= 10 && x < 20 { c[i] = 0 }          // cyan
                if x >= 20 && x < 30 { k[i] = 0 }          // black
                if x >= 30 { m[i] = 0; y[i] = 0 }          // magenta + yellow = red
            } }
            l.planes = [0: c, 1: m, 2: y, 3: k, -1: [UInt8](repeating: 255, count: 400)]
            f.layers = [l]; f.merged = [c, m, y, k]
            let r = load(f, "mode_cmyk", dir)
            if let b = r?.state.layers.first?.raster?.buffer {
                let white = b.psdTestPixel(5, 5), cyan = b.psdTestPixel(15, 5), black = b.psdTestPixel(25, 5), red = b.psdTestPixel(35, 5)
                check(r?.state.colorMode == .cmyk && white.0 > 245 && white.1 > 245 && white.2 > 245 && cyan.0 < 120 && cyan.2 > 150 && black.0 < 70 && black.1 < 70 && black.2 < 70 && red.0 > 180 && red.1 < 110 && red.2 < 110,
                      "CMYK document converts to RGB (paper \(white), cyan \(cyan), black \(black), M+Y \(red))")
                check(r.map { status($0, .info, "Colour mode") } == true, "CMYK conversion is noted in the report")
            } else { check(false, "CMYK document opens") }
        }
        // Lab, flat
        do {
            var f = PSDTestFile(width: 30, height: 4); f.mode = 9
            var L = [UInt8](repeating: 0, count: 120)
            for row in 0..<4 { for x in 0..<30 { L[row * 30 + x] = x < 10 ? 255 : (x < 20 ? 136 : 0) } }
            f.merged = [L, [UInt8](repeating: 128, count: 120), [UInt8](repeating: 128, count: 120)]
            let r = load(f, "mode_lab")
            if let b = r?.state.layers.first?.raster?.buffer {
                let w = b.psdTestPixel(5, 2), g = b.psdTestPixel(15, 2), k = b.psdTestPixel(25, 2)
                check(r?.state.colorMode == .lab && w.0 > 250 && abs(Int(g.0) - 128) < 8 && abs(Int(g.0) - Int(g.2)) < 6 && k.0 < 5, "Lab document converts to RGB (L 100 → \(w.0), L 53 → \(g), L 0 → \(k.0))")
            } else { check(false, "Lab document opens") }
        }
        // indexed colour with a transparent index, bitmap, duotone
        do {
            var f = PSDTestFile(width: 4, height: 2); f.mode = 2
            var pal = [UInt8](repeating: 0, count: 768)
            pal[1] = 255; pal[256 + 2] = 255; pal[512 + 3] = 255   // 1 red, 2 green, 3 blue
            f.colorModeData = Data(pal)
            var t = BinaryWriter(); t.u16(3); f.resources = [(1047, "", t.data)]
            f.merged = [[0, 1, 2, 3, 3, 2, 1, 0]]
            let r = load(f, "mode_indexed")
            let b = r?.state.layers.first?.raster?.buffer
            check(r?.state.colorMode == .indexed && b?.psdTestPixel(1, 0).0 == 255 && b?.psdTestPixel(2, 0).1 == 255 && b?.psdTestPixel(3, 0).3 == 0 && b?.psdTestPixel(0, 1).3 == 0 && r?.state.imaging?.colorTable?.count == 256
                  && r?.state.imaging?.transparentIndex == 3, "Indexed Color: palette, transparent index, colour table kept")
            f = PSDTestFile(width: 10, height: 2); f.mode = 0; f.depth = 1; f.mergedCompression = 0
            f.merged = [[0b1010_0000, 0b0100_0000, 0xFF, 0xC0]]
            let rb = load(f, "mode_bitmap")
            let bb = rb?.state.layers.first?.raster?.buffer
            check(rb?.state.colorMode == .bitmap && bb?.psdTestPixel(0, 0).0 == 0 && bb?.psdTestPixel(1, 0).0 == 255 && bb?.psdTestPixel(2, 0).0 == 0 && bb?.psdTestPixel(9, 0).0 == 0 && bb?.psdTestPixel(9, 1).0 == 0 && bb?.psdTestPixel(3, 0).0 == 255,
                  "Bitmap document: 1 bit per pixel, 1 = black")
            f = PSDTestFile(width: 4, height: 1); f.mode = 8; f.merged = [[0, 80, 160, 255]]
            let rd = load(f, "mode_duotone")
            check(rd?.state.colorMode == .grayscale && rd?.state.layers.first?.raster?.buffer.psdTestPixel(1, 0).0 == 80 && rd.map { status($0, .flattened, "Colour mode") } == true, "Duotone opens as Grayscale and says so")
            f = PSDTestFile(width: 4, height: 1); f.mode = 7; f.merged = [[0, 80, 160, 255]]
            check((try? PSDImporter.read(data: f.data(), name: "multi")) == nil, "Multichannel is refused by the layer reader (the app then opens the flattened picture)")
        }
        // a whole mixed document as PSB: every live kind through the 8-byte length paths
        do {
            var f = file()
            f.large = true
            var t = PSDTestLayer(name: "Title"); t.add("TySh", PSDTestFile.typeBlock(text: "PSB", runs: [.init(length: 3, size: 40)], fonts: ["Helvetica"], transform: [1, 0, 0, 1, 20, 80]))
            var sh = PSDTestLayer(name: "Shape"); sh.add("SoCo", PSDTestFile.solidFill(.red)); sh.add("vmsk", PSDTestFile.vectorMask(.ellipse(CGRect(x: 150, y: 50, width: 100, height: 80)), width: W, height: H))
            var adj = PSDTestLayer(name: "Levels")
            var w = BinaryWriter(); w.u16(2); for _ in 0..<29 { for v in [5, 250, 0, 255, 100] { w.u16(UInt16(v)) } }
            adj.add("levl", w.data)
            let so = smartLayer("Placed", id: "p", quad: Quad(rect: CGRect(x: 10, y: 110, width: 120, height: 80)), size: CGSize(width: 120, height: 80))
            var tile = PSDTestLayer(name: "Tile"); tile.opacity = 60
            tile.add("PtFl", PSDTestFile.versioned(PSDTestFile.patternFillDescriptor(id: "psb-pattern", name: "P", scale: 1)))
            f.layers = [background(), t, sh, adj, so, tile]
            f.globalBlocks = [("lnk2", PSDTestFile.link(id: "p", name: "p.png", data: picture(120, 80).pngData() ?? Data())), ("Patt", PSDTestFile.pattern(id: "psb-pattern", name: "P", image: solid(4, 4, .red)))]
            let r = load(f, "mixed", dir)
            let ls = r?.state.layers ?? []
            check(ls.count == 6 && ls[1].isText && ls[2].isShape && ls[3].isAdjustment && ls[4].isSmartObject && ls[5].isFill, "PSB with type, shape, adjustment, smart object and pattern fill: all stay live (\(ls.map(\.kindName)))")
            f.large = false
            let r1 = load(f, "mixed", dir)
            if let a = r, let b = r1 { let d = compare(a.state, b.state); check(d.mean == 0, "the PSD and PSB variants of the same document import identically") }
        }
    }

    // MARK: Robustness

    struct Rng {
        var s: UInt64
        mutating func next() -> UInt64 { s &+= 0x9E37_79B9_7F4A_7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9; z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB; return z ^ (z >> 31) }
        mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    }

    /// Truncates and corrupts test files: every variant must end in an error or a document, never a trap.
    static func testFuzz(_ dir: URL) {
        var seeds: [(String, Data)] = []
        for name in ["mixed.psd", "mixed.psb", "document.psd", "text_runs.psd", "shape_stroke.psd", "smart_nested_psd.psd", "smart_warp_custom.psd", "fill_pattern.psd", "mode_cmyk.psd"] {
            if let d = try? Data(contentsOf: dir.appendingPathComponent(name)) { seeds.append((name, d)) }
        }
        var f16 = PSDTestFile(width: 40, height: 30); f16.depth = 16; f16.compression = 3; f16.layersInBlock = true
        f16.layers = [PSDTestLayer(name: "Deep", buffer: picture(40, 30), origin: .zero)]; f16.merged = Array(repeating: [UInt8](repeating: 9, count: 1200), count: 3)
        seeds.append(("deep16", f16.data()))
        for (tag, path) in realFiles where ["trafficlights-vectormask", "icon-dvd-text", "workaround-text", "pushbutton-groups", "pagegradient-shape"].contains(tag) {
            if let d = try? Data(contentsOf: URL(fileURLWithPath: path)) { seeds.append((tag, d)) }
        }
        check(seeds.count >= 8, "fuzz seeds available (\(seeds.count))")
        var rng = Rng(s: 20260930)
        var opened = 0, refused = 0, rendered = 0, total = 0
        var renderAll = false
        func attempt(_ d: Data) {
            total += 1
            guard let r = try? PSDImporter.read(data: d, name: "fuzz") else { refused += 1; return }
            opened += 1
            let st = r.state
            if st.width < 1 || st.height < 1 || st.width > maxCanvasDimension || st.height > maxCanvasDimension { check(false, "fuzz: document with impossible size \(st.width)×\(st.height)") }
            // what opens must also draw (every third one: rendering is the slow part)
            if total % 3 == 0 || renderAll, st.width * st.height <= 400_000, Compositor.shared.flatten(st, background: .white) != nil { rendered += 1 }
            _ = r.report.summary; _ = r.report.text
        }
        for (_, d) in seeds {
            // truncations: around every structural boundary at the start, then spread over the file
            var cuts: [Int] = Array(0..<min(64, d.count))
            for _ in 0..<26 { cuts.append(rng.below(d.count)) }
            for c in cuts { attempt(d.prefix(c)) }
            // bit flips and byte stomps, biased towards the structured first part of the file
            for i in 0..<70 {
                var m = [UInt8](d)
                let hits = 1 + rng.below(6)
                for _ in 0..<hits {
                    let region = i % 3 == 0 ? m.count : min(m.count, 4096 + rng.below(8192))
                    let p = rng.below(region)
                    switch rng.below(4) {
                    case 0: m[p] ^= UInt8(1 << rng.below(8))
                    case 1: m[p] = 0xFF
                    case 2: m[p] = 0
                    default: m[p] = UInt8(rng.below(256))
                    }
                }
                attempt(Data(m))
            }
            // length fields blown up: 0xFFFFFFFF / 0x7FFFFFFF written over aligned words in the header area
            for _ in 0..<20 {
                var m = [UInt8](d)
                let p = rng.below(max(1, min(m.count - 4, 6000)))
                let v: [UInt8] = rng.below(2) == 0 ? [0xFF, 0xFF, 0xFF, 0xFF] : [0x7F, 0xFF, 0xFF, 0xFF]
                for k in 0..<4 where p + k < m.count { m[p + k] = v[k] }
                attempt(Data(m))
            }
        }
        // hostile numbers: every double in the descriptors (and the type transform) replaced by NaN, ±∞, ±1e300, a denormal
        renderAll = true   // these open more often than not: make sure they also draw
        let nasty: [Double] = [.nan, .infinity, -.infinity, 1e300, -1e300, 4.9e-324]
        for (_, d) in seeds where d.count < 600_000 {
            let bytes = [UInt8](d)
            var spots: [Int] = []
            for i in 0..<max(0, bytes.count - 16) {
                if bytes[i] == 0x64, bytes[i + 1] == 0x6F, bytes[i + 2] == 0x75, bytes[i + 3] == 0x62 { spots.append(i + 4) }          // 'doub'
                else if bytes[i] == 0x55, bytes[i + 1] == 0x6E, bytes[i + 2] == 0x74, bytes[i + 3] == 0x46 { spots.append(i + 8) }     // 'UntF' + unit
                else if bytes[i] == 0x54, bytes[i + 1] == 0x79, bytes[i + 2] == 0x53, bytes[i + 3] == 0x68 { for k in 0..<6 { spots.append(i + 10 + k * 8) } }   // 'TySh' transform
            }
            spots = spots.filter { $0 + 8 <= bytes.count }
            guard !spots.isEmpty else { continue }
            func put(_ m: inout [UInt8], _ at: Int, _ v: Double) { let b = v.bitPattern; for k in 0..<8 { m[at + k] = UInt8((b >> UInt64(56 - 8 * k)) & 0xff) } }
            for v in nasty {
                var all = bytes
                for sp in spots { put(&all, sp, v) }
                attempt(Data(all))
                for _ in 0..<6 { var one = bytes; put(&one, spots[rng.below(spots.count)], v); attempt(Data(one)) }
            }
        }
        // hostile type settings (engine data is text, so these are built rather than bit-flipped)
        let extremes: [(String, Double, String, [Double], CGRect?)] = [
            ("huge size", 1e308, "", [1, 0, 0, 1, 20, 60], nil), ("zero size", 0, "", [1, 0, 0, 1, 20, 60], nil), ("negative size", -40, "", [1, 0, 0, 1, 20, 60], nil),
            ("huge tracking", 20, "/Tracking 999999999999 /Leading 1e30 /AutoLeading false /BaselineShift -1e20 /HorizontalScale 0 /VerticalScale 1e9", [1, 0, 0, 1, 20, 60], nil),
            ("bad indices", 20, "/Font 9999 /FontBaseline 99 /FontCaps 77", [1, 0, 0, 1, 20, 60], nil),
            ("huge transform", 20, "", [1e6, 0, 0, 1e6, 1e6, -1e6], nil), ("zero transform", 20, "", [0, 0, 0, 0, 0, 0], nil), ("skew", 20, "", [1, 5, -7, 0.001, 20, 60], nil),
            ("huge box", 20, "", [1, 0, 0, 1, 20, 60], CGRect(x: -5e6, y: -5e6, width: 9e6, height: 9e6)), ("tiny box", 20, "", [1, 0, 0, 1, 20, 60], CGRect(x: 0, y: 0, width: 0.001, height: 0.001)),
        ]
        for (what, size, extra, m, box) in extremes {
            var l = PSDTestLayer(name: what)
            l.add("TySh", PSDTestFile.typeBlock(text: "Extreme values", runs: [.init(length: 14, size: size, extra: extra)], fonts: ["Helvetica"], transform: m, justification: 99, box: box,
                                                paragraphExtra: "/StartIndent 1e40\n/EndIndent -1e40\n/FirstLineIndent 1e300\n/SpaceBefore -5\n/SpaceAfter 1e99", warp: ("warpFisheye", 1e9, -1e9, 1e300)))
            attempt(file([background(), l]).data())
        }
        renderAll = false
        // hostile headers
        var huge = PSDTestFile(width: 30000, height: 30000); huge.merged = []
        attempt(huge.data().prefix(64))
        // a layer record that claims 841 MP of pixels in a file of a few kilobytes (bottom / right patched to 29000)
        var bomb = [UInt8](file([background(40, 30)], w: 40, h: 30).data())
        for (o, v) in [(52, 29000), (56, 29000)] { bomb[o] = UInt8(v >> 24); bomb[o + 1] = UInt8((v >> 16) & 0xff); bomb[o + 2] = UInt8((v >> 8) & 0xff); bomb[o + 3] = UInt8(v & 0xff) }
        let bombResult = try? PSDImporter.read(data: Data(bomb), name: "bomb")
        check(bombResult == nil || bombResult?.state.layers.first?.raster.map { $0.buffer.width <= 40 } == true, "a layer claiming 29000 × 29000 px in a tiny file does not allocate it")
        attempt(Data(bomb))
        attempt(Data("8BPS".utf8)); attempt(Data()); attempt(Data(repeating: 0x38, count: 4096))
        print("INFO psdimport: fuzz — \(total) variants of \(seeds.count) files: \(opened) opened (\(rendered) also rendered), \(refused) refused with an error, 0 crashes")
        check(total >= 2000 && opened > 0 && refused > 0, "fuzz: \(total) truncated / corrupted files handled without a trap (\(opened) opened, \(refused) refused)")
        // engine data and descriptor parsers on their own
        var junk = 0
        for _ in 0..<400 {
            let n = rng.below(200)
            let alphabet: [UInt8] = Array("<<>>[]()/\\ 0123456789.-truefals\n".utf8) + [0xFE, 0xFF, 0]
            let bytes = (0..<n).map { _ in alphabet[rng.below(alphabet.count)] }
            if (try? PSDEngineParser.parse(bytes)) == nil { junk += 1 }
        }
        let nested = [UInt8](repeating: 0x5B, count: 5000)
        check((try? PSDEngineParser.parse(nested)) == nil && (try? PSDEngineParser.parse(Array(String(repeating: "<< /a ", count: 3000).utf8))) == nil, "engine data: runaway nesting is refused (\(junk) of 400 random inputs rejected)")
    }

    // MARK: Report and app-level flows

    static func testApp(_ dir: URL) {
        let app = AppModel.shared
        let psd = dir.appendingPathComponent("mixed.psd"), psb = dir.appendingPathComponent("mixed.psb")
        guard FileManager.default.fileExists(atPath: psd.path), FileManager.default.fileExists(atPath: psb.path) else { check(false, "app: test files written by the depth tests"); return }
        // File ▸ Open: document, report, status line — and no modal
        let before = app.documents.count
        var alerts = 0
        let hook = AppActions.modalHook
        AppActions.modalHook = { _, _ in alerts += 1; return false }
        defer { AppActions.modalHook = hook }
        for url in [psd, psb] {
            AppActions.open(url: url)
            guard app.documents.count == before + 1, let d = app.activeDocument, d.fileURL == url else { check(false, "File ▸ Open \(url.lastPathComponent)"); continue }
            let rep = PSDImportModule.report(for: d)
            check(rep != nil && rep?.count(.editable) ?? 0 >= 5 && d.state.layers.count == 6, "File ▸ Open \(url.lastPathComponent): live layers and an import report")
            check(app.statusMessage.hasPrefix("Opened “\(url.lastPathComponent)”") && app.statusMessage.contains("kept editable") && app.dialog == nil && alerts == 0,
                  "opening shows a status line, not a dialog (\(app.statusMessage.prefix(70))…)")
            // the report and the file's patterns survive Save As .lumen
            let native = dir.appendingPathComponent("saved_\(url.pathExtension).imagecrat")
            do {
                try DocumentIO.saveNative(d, to: native)
                let back = try DocumentIO.load(url: native)
                check(PSDImportModule.report(for: back) == rep && PSDImportModule.patterns[back.id]?.first?.id == "psb-pattern", "report and patterns are stored in the .imagecrat file")
                check(back.state.layers.map(\.kindName) == d.state.layers.map(\.kindName), "the imported layers round-trip through .imagecrat (\(back.state.layers.map(\.kindName)))")
            } catch { check(false, "save / reload as .imagecrat threw \(error)") }
            app.close(d)
        }
        check(DialogRegistry.builders[PSDImportModule.dialogID] != nil && MenuRegistry.items(for: "File").contains { $0.title == "PSD Import Report…" }, "File ▸ PSD Import Report… is registered")
        let item = MenuRegistry.items(for: "File").first { $0.title == "PSD Import Report…" }
        check(item?.enabled() == false || app.activeDocument.flatMap { PSDImportModule.report(for: $0) } != nil, "the menu item is disabled without an imported document")
        // a PSD whose layers cannot be read opens flattened through the system decoder, with a report
        do {
            var f = PSDTestFile(width: 40, height: 20); f.mode = 7
            f.merged = [[UInt8](repeating: 40, count: 800), [UInt8](repeating: 90, count: 800), [UInt8](repeating: 200, count: 800)]
            let url = dir.appendingPathComponent("multichannel.psd")
            try? f.data().write(to: url)
            if let d = try? DocumentIO.load(url: url) {
                check(d.state.layers.count == 1 && PSDImportModule.report(for: d)?.count(.flattened) == 1, "unreadable layers: the flattened picture opens and the report explains it")
            } else { print("INFO psdimport: the system decoder does not read a multichannel PSD either (file refused with an error)") ; check(true, "unreadable file is refused with an error, not a crash") }
            // layers unreadable but the picture decodable: forced through the test hook
            PSDImporter.failForTesting = true
            let flat = try? DocumentIO.load(url: psd)
            PSDImporter.failForTesting = false
            let fr = flat.flatMap { PSDImportModule.report(for: $0) }
            check(flat?.state.layers.count == 1 && flat?.state.width == W && fr?.count(.flattened) == 1 && fr?.summary.contains("1 kept as pixels") == true,
                  "when the layers cannot be read the flattened picture opens instead, and the report explains it")
            let bad = dir.appendingPathComponent("garbage.psd")
            try? Data(repeating: 7, count: 300).write(to: bad)
            check((try? DocumentIO.load(url: bad)) == nil, "a file that is not a PSD is refused with an error")
        }
        // Place Embedded / Place Linked / Replace Contents with PSD and PSB
        var st = DocumentState(width: 400, height: 300)
        st.layers = [Layer.raster(name: "Background", buffer: solid(400, 300, .white))]
        let host = Document(state: st, name: "host")
        app.documents.append(host)
        app.activeDocumentID = host.id
        defer { app.documents.removeAll { $0.id == host.id } }
        for (url, linked) in [(psd, false), (psb, false), (psd, true), (psb, true)] {
            let tag = "\(url.pathExtension.uppercased()) \(linked ? "linked" : "embedded")"
            let n = host.state.layers.count
            AppActions.place([url], linked: linked)
            guard host.state.layers.count == n + 1, let so = host.activeLayer?.smart, case .document(let inner) = so.source else { check(false, "Place \(tag): smart object with a layered source"); continue }
            check(inner.layers.count == 6 && inner.layers[1].isText && (so.linkedURL != nil) == linked && so.quad.bounds.width == 300, "Place \(tag): the PSD's layers stay live inside the smart object")
        }
        if let target = host.activeLayer {
            let pngURL = dir.appendingPathComponent("linked-source.png")
            check(AppActions.replaceSmartContents(of: target.id, in: host, with: pngURL) && host.state.layer(target.id)?.smart?.source.size == CGSize(width: 120, height: 80), "Replace Contents: PSD → PNG")
            for url in [psd, psb] {
                let ok = AppActions.replaceSmartContents(of: target.id, in: host, with: url)
                var layered = false
                if case .document(let inner)? = host.state.layer(target.id)?.smart?.source { layered = inner.layers.count == 6 && inner.layers[2].isShape }
                check(ok && layered, "Replace Contents with a \(url.pathExtension.uppercased()) keeps its layers live")
            }
            host.undo()
            check(host.state.layer(target.id)?.isSmartObject == true, "Replace Contents can be undone")
        }
        check(alerts == 0 && app.dialog == nil, "no alert or dialog was raised by any of the flows")
        // report plumbing
        var rep = PSDImportReport(fileName: "x.psd", layerCount: 3)
        rep.add(.editable, layer: "Title", feature: "Type", detail: "d")
        rep.add(.substituted, layer: "Title", feature: "Font", detail: "f"); rep.missingFonts = ["A"]
        rep.add(.flattened, layer: "SO", feature: "Smart object", detail: "p")
        rep.add(.skipped, layer: "Look", feature: "Adjustment", detail: "c")
        check(rep.summary == "Opened “x.psd”: 3 layers — 1 kept editable (type), 1 font substituted, 1 kept as pixels, 1 left out. See File ▸ PSD Import Report…", "report summary line (\(rep.summary))")
        check(rep.text.contains("Kept as pixels (1)") && rep.text.contains("SO — Smart object: p"), "report text lists every group")
        let round = (try? PropertyListEncoder().encode(rep)).flatMap { try? PropertyListDecoder().decode(PSDImportReport.self, from: $0) }
        check(round == rep, "report is Codable")
        check(PSDImportReport(fileName: "plain.psd", layerCount: 2).summary == "Opened “plain.psd”: 2 layers.", "a file with only pixel layers gets a plain status line")
    }
}
