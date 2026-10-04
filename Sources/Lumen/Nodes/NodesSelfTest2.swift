import AppKit
import CoreImage
import SwiftUI
import Metal
import ImageCratCore

extension NodesSelfTest {
    static let photoPath = "/System/Library/Desktop Pictures/Sonoma.heic"

    /// A generic system photo scaled to `w`×`h` (nil when the file is missing).
    static func testPhoto(_ w: Int, _ h: Int) -> PixelBuffer? {
        guard let (cg, _) = DocumentIO.loadImage(url: URL(fileURLWithPath: photoPath)) else { return nil }
        let src = CIImage(cgImage: cg)
        let s = max(CGFloat(w) / src.extent.width, CGFloat(h) / src.extent.height)
        var img = src.transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: true)
        img = img.translated(-(img.extent.width - CGFloat(w)) / 2, -(img.extent.height - CGFloat(h)) / 2)
        return buffer(img, w, h)
    }

    static func tempDir(_ name: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-nodes-\(name)-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func composite(_ st: DocumentState) -> PixelBuffer {
        let sp = CanvasSpace(width: st.width, height: st.height)
        return RenderEngine.renderBuffer(Compositor.shared.composite(st), docRect: st.canvasRect, space: sp)
    }

    static func savePNG(_ b: PixelBuffer, _ name: String, _ out: URL) {
        try? NSBitmapImageRep(cgImage: b.makeCGImage()).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        print("wrote \(name)")
    }

    // MARK: Built-in recipes

    static func recipeTests(_ out: URL) {
        let W = 720, H = 480
        let sp = CanvasSpace(width: W, height: H)
        let synth = buffer(RecipeThumbnails.sampleImage(width: W, height: H), W, H)
        let photo = testPhoto(W, H)
        check(photo != nil, "generic system test photo available (\(photoPath))")
        check(RecipePresets.builtIn.count >= 12, "\(RecipePresets.builtIn.count) built-in recipes")
        for (label, src) in [("photo", photo), ("synthetic", synth)] {
            guard let src else { continue }
            var cells: [(String, CGImage)] = [("Original", src.makeCGImage())]
            for p in RecipePresets.builtIn {
                let id = UUID()
                let t0 = CFAbsoluteTimeGetCurrent()
                let img = RecipeRuntime.shared.render(target: id, graph: p.graph, source: src.ciImage, space: sp)
                let b = buffer(img, W, H)
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                let errs = RecipeRuntime.shared.errors(target: id)
                check(errs.isEmpty, "recipe “\(p.name)” on \(label): no node errors \(errs.values.joined(separator: "; "))")
                check(lumaStdDev(b) > 3, "recipe “\(p.name)” on \(label): renders an image (σ \(Int(lumaStdDev(b))), \(Int(ms)) ms incl. kernel compile)")
                if p.usesSource { check(meanDiff(b, src) > 2, "recipe “\(p.name)” on \(label): changes the picture (Δ \(String(format: "%.1f", meanDiff(b, src))))") }
                check(p.graph.outputNode != nil && !p.graph.exposed.isEmpty, "recipe “\(p.name)”: has an Output node and exposed parameters (\(p.graph.exposed.count))")
                for e in p.graph.exposed {
                    let ok = p.graph.node(e.node).flatMap { RecipeLibrary.spec($0.type)?.param(e.key) } != nil
                    if !ok { check(false, "recipe “\(p.name)”: exposed parameter \(e.key) exists") }
                }
                cells.append((p.name, b.makeCGImage()))
            }
            contactSheet(cells, cell: CGSize(width: 360, height: 240), columns: 4, "nodes_recipes_\(label)", out)
        }
        // wiring sanity: every wire the presets declare was accepted (the builder prints rejected ones)
        for p in RecipePresets.builtIn {
            let dangling = p.graph.nodes.filter { n in
                n.type != RecipeLibrary.outputNodeType && !p.graph.connections.contains { $0.from == n.id }
            }
            check(dangling.isEmpty, "recipe “\(p.name)”: every node feeds something (\(dangling.map(\.type)))")
        }
    }

    // MARK: Documents

    static func documentTests(_ out: URL) {
        let app = AppModel.shared
        let W = 480, H = 300
        func baseDoc(_ name: String) -> Document {
            var st = SelfTest.baseState(W, H)
            st.layers.append(SelfTest.shapeLayer(CGRect(x: 60, y: 60, width: 200, height: 140)))
            var t = TextContent(); t.text = "Recipe"; t.fontName = "Helvetica-Bold"; t.fontSize = 64; t.color = RGBA(hex: "1B1F3A")!; t.position = CGPoint(x: 200, y: 170)
            st.layers.append(Layer(name: "Text", content: .text(t)))
            return Document(state: st, name: name)
        }

        // --- Recipe layer over real layers: save / load, undo / redo, export, PSD
        do {
            let d = baseDoc("recipe-doc")
            let before = composite(d.state)
            let lid = RecipeActions.newRecipeLayer(RecipePresets.frostedGlass.graph, in: d)!
            check(d.state.layer(lid)?.isRecipe == true && d.state.layer(lid)?.kindName == "Recipe Layer", "New Recipe Layer adds a Recipe layer on top")
            check(d.history.last?.name == "New Recipe Layer", "one history step: New Recipe Layer")
            let a = composite(d.state)
            check(meanDiff(a, before) > 2, "frosted glass recipe changes the composite below it (Δ \(String(format: "%.1f", meanDiff(a, before))))")
            savePNG(a, "nodes_doc_frosted_glass", out)

            // layer features: opacity, blend mode, mask
            var st2 = d.state
            st2.updateLayer(lid) { l in
                l.opacity = 0.5
                l.mask = LayerMask(buffer: SelectionOps.rectMask(CGRect(x: 0, y: 0, width: 240, height: 300), width: W, height: H), origin: .zero, outsideValue: 0)
            }
            let half = composite(st2)
            check(maxDiff(half.cropped(to: IRect(x: 260, y: 0, width: 200, height: 300)), before.cropped(to: IRect(x: 260, y: 0, width: 200, height: 300))) <= 1,
                  "layer mask hides the recipe (right half untouched)")
            check(meanDiff(half.cropped(to: IRect(x: 0, y: 0, width: 220, height: 300)), a.cropped(to: IRect(x: 0, y: 0, width: 220, height: 300))) > 0.5,
                  "layer opacity applies to the recipe")

            // save / load
            let dir = tempDir("doc")
            let url = dir.appendingPathComponent("recipe.imagecrat")
            do {
                try DocumentIO.saveNative(d, to: url)
                let back = try DocumentIO.load(url: url)
                check(back.state.layer(lid)?.recipe == d.state.layer(lid)?.recipe, "save / load: the graph round-trips exactly")
                RecipeRuntime.shared.reset()
                check(maxDiff(composite(back.state), a) == 0, "save / load: the rendered document is pixel-identical")
            } catch { check(false, "save / load: \(error)") }

            // undo / redo (one step per edit, exact)
            let t = RecipeTarget.layer(lid)
            let g0 = d.state.recipeGraph(t)!
            let blurNode = g0.nodes.first { $0.type == "filter.gaussianBlur" }!.id
            let steps0 = d.history.count
            for v in stride(from: 15.0, through: 40.0, by: 5.0) { RecipeActions.mutate(d, t) { $0.update(blurNode) { $0.numbers["radius"] = v } } }   // a slider drag
            d.commit("Recipe: Radius")
            check(d.history.count == steps0 + 1, "a slider drag (6 live updates) is one history step")
            let c = composite(d.state)
            check(meanDiff(c, a) > 0.3, "changing the blur radius changes the picture")
            d.undo()
            check(d.state.recipeGraph(t) == g0 && maxDiff(composite(d.state), a) == 0, "undo restores the graph and the exact pixels")
            d.redo()
            check(maxDiff(composite(d.state), c) == 0, "redo re-applies the exact pixels")
            d.undo()

            // export PNG
            let png = dir.appendingPathComponent("recipe.png")
            do {
                try DocumentIO.export(d.state, to: png, format: .png, quality: 1, scale: 1)
                if let (cg, _) = DocumentIO.loadImage(url: png) { check(maxDiff(PixelBuffer(cgImage: cg), a) <= 2, "PNG export matches the canvas") } else { check(false, "PNG export readable") }
            } catch { check(false, "PNG export: \(error)") }

            // PSD export: the recipe layer is rasterised with its true backdrop
            let psd = dir.appendingPathComponent("recipe.psd")
            do {
                try PSDWriter.write(d.state, to: psd)
                let st = try PSDReader.read(url: psd)
                let rl = st.layers.last
                check(rl?.isRaster == true && rl?.name == d.state.layer(lid)?.name, "PSD export: the Recipe layer arrives as a pixel layer (\(rl?.kindName ?? "nil"))")
                let p = composite(st)
                savePNG(p, "nodes_doc_psd_roundtrip", out)
                check(meanDiff(p, a) < 1.5, "PSD export: re-opened PSD looks like the document (Δ \(String(format: "%.2f", meanDiff(p, a))))")
            } catch { check(false, "PSD export: \(error)") }

            // rasterize command
            app.add(d)
            d.selectLayer(lid)
            RecipeActions.rasterize(lid)
            check(d.state.layer(lid)?.isRaster == true && maxDiff(composite(d.state), a) <= 1, "Rasterize Recipe Layer bakes exactly what was shown")
            d.undo()
            // the app's own Layer ▸ Rasterize takes the same path
            AppActions.rasterizeLayer(lid)
            check(d.state.layer(lid)?.isRaster == true && meanDiff(composite(d.state), a) < 0.5, "Layer ▸ Rasterize Layer also bakes the true backdrop")
            d.undo()
            check(d.state.layer(lid)?.isRecipe == true, "undo brings the live recipe back")

            // duplicate (copy / paste of the layer)
            let copy = d.state.layer(lid)!.duplicated(newName: "Recipe copy")
            d.state.insertLayer(copy, above: lid)
            d.commit("Duplicate Layer")
            check(d.state.layer(copy.id)?.recipe == d.state.layer(lid)?.recipe && copy.id != lid, "duplicating the layer copies the recipe")
            _ = composite(d.state)
            d.undo()

            // layer clipboard-style Codable round trip (what copy / paste between documents encodes)
            if let data = try? JSONEncoder().encode(d.state.layer(lid)!), let l2 = try? JSONDecoder().decode(Layer.self, from: data) {
                check(l2.recipe == d.state.layer(lid)?.recipe, "layer JSON round trip keeps the recipe")
            } else { check(false, "layer JSON round trip") }
            app.close(d)
        }

        // --- old documents: fill layers / filters without the new keys
        do {
            let fill = FillContent(paint: .color(.red))
            if let data = try? JSONEncoder().encode(fill), let s = String(data: data, encoding: .utf8) {
                check(!s.contains("recipe"), "plain fill layers don't write a recipe key")
                check((try? JSONDecoder().decode(FillContent.self, from: data))?.recipe == nil, "fill layers without the key decode (older documents)")
            }
            let f = FilterInstance(kind: .gaussianBlur)
            if let data = try? JSONEncoder().encode(f), let back = try? JSONDecoder().decode(FilterInstance.self, from: data) {
                check(back.recipe == nil && back.kind == .gaussianBlur, "filters without a recipe decode (older documents)")
            } else { check(false, "filter round trip") }
        }

        // --- layer references: live, missing, circular
        do {
            let d = baseDoc("refs")
            let shapeID = d.state.layers[1].id
            var b = RecipeBuilder("Ref")
            let ln = b.add("in.layer", col: 0) { $0.strings["layer"] = shapeID.uuidString }
            let inv = b.add("imath.invert", col: 1)
            let o = b.add("out.output", col: 2)
            b.wire(ln, "Image", inv); b.wire(inv, "Image", o)
            let lid = RecipeActions.newRecipeLayer(b.graph, in: d)!
            var px = composite(d.state).pixel(100, 100)
            check(near(px, 255 - 0xE9, 255 - 0x4F, 255 - 0x37), "Layer node: inverted copy of the shape layer (\(px))")
            d.state.updateLayer(shapeID) { l in if var s = l.shape { s.fill = .color(RGBA(r: 0, g: 0, b: 1)); l.shape = s } }
            px = composite(d.state).pixel(100, 100)
            check(near(px, 255, 255, 0), "Layer node is live: follows edits of the referenced layer (\(px))")
            d.state.updateLayer(shapeID) { $0.isVisible = false }
            check(near(composite(d.state).pixel(100, 100), 255, 255, 0), "a hidden layer can still feed a recipe")
            // missing layer
            d.state.removeLayer(shapeID)
            let c = composite(d.state)
            let errs = RecipeRuntime.shared.errors(target: lid)
            check(errs.values.contains { $0.contains("not found") }, "deleted referenced layer → “Layer not found” on the node, no crash")
            check(lumaStdDev(c) > 1, "document still renders with a missing reference")
            // circular references between two recipe layers
            let d2 = baseDoc("cycle")
            let a = RecipeActions.newRecipeLayer(RecipeActions.passthroughGraph(), in: d2)!
            let bb = RecipeActions.newRecipeLayer(RecipeActions.passthroughGraph(), in: d2)!
            for (me, other) in [(a, bb), (bb, a)] {
                var g = RecipeBuilder("Loop")
                let n = g.add("in.layer", col: 0) { $0.strings["layer"] = other.uuidString }
                let o2 = g.add("out.output", col: 1)
                g.wire(n, "Image", o2)
                d2.state.setRecipeGraph(.layer(me), g.graph)
            }
            _ = composite(d2.state)
            check(true, "two Recipe layers referencing each other terminate")
            // a recipe reading its own layer
            var self1 = RecipeBuilder("Self")
            let sn = self1.add("in.layer", col: 0) { $0.strings["layer"] = a.uuidString }
            let so = self1.add("out.output", col: 1)
            self1.wire(sn, "Image", so)
            d2.state.setRecipeGraph(.layer(a), self1.graph)
            _ = composite(d2.state)
            check(RecipeRuntime.shared.errors(target: a).values.contains { $0.contains("own layer") }, "a recipe reading its own layer reports an error instead of recursing")
        }

        // --- moving a recipe layer shifts generators
        do {
            var st = DocumentState(width: 200, height: 160)
            var l = Layer.recipe(name: "Tex", graph: TextureActions.graph(TextureSettings(gen: "cells")))
            st.layers = [l]
            let a = composite(st)
            l.translate(dx: 30, dy: 20)
            st.layers = [l]
            let b = composite(st)
            let shifted = a.cropped(to: IRect(x: 0, y: 0, width: 170, height: 140)), moved = b.cropped(to: IRect(x: 30, y: 20, width: 170, height: 140))
            check(l.recipe?.origin == CGPoint(x: 30, y: 20) && meanDiff(shifted, moved) < 1.0, "moving a Recipe layer translates its generators (Δ \(String(format: "%.2f", meanDiff(shifted, moved))))")
        }

        // --- Recipe smart filter
        do {
            let d = baseDoc("smart")
            app.add(d)
            defer { app.close(d) }
            let src = PixelBuffer(width: 160, height: 120)
            src.context.setFillColor(RGBA(r: 0.2, g: 0.6, b: 0.9).cgColor); src.context.fill(CGRect(x: 0, y: 0, width: 160, height: 120)); src.markDirty()
            let so = SmartObjectContent(source: .image(src), quad: Quad(rect: CGRect(x: 280, y: 40, width: 160, height: 120)), sourceName: "SO")
            let sl = Layer(name: "Smart", content: .smartObject(so))
            d.addLayer(sl, commitName: "Place")
            let before = composite(d.state)
            var b = RecipeBuilder("Invert Filter")
            let s = b.add("in.source", col: 0)
            let inv = b.add("imath.invert", col: 1)
            let o = b.add("out.output", col: 2)
            b.wire(s, "Image", inv); b.wire(inv, "Image", o)
            let t = RecipeActions.addRecipeFilter(b.graph, in: d, layerID: sl.id)
            check(t != nil && d.state.layer(sl.id)?.smart?.filters.last?.kind == .recipe, "Recipe Filter is added to the smart filter stack")
            let after = composite(d.state)
            check(near(after.pixel(360, 100), 204, 102, 26) && maxDiff(after.cropped(to: IRect(x: 0, y: 0, width: 270, height: 300)), before.cropped(to: IRect(x: 0, y: 0, width: 270, height: 300))) == 0,
                  "Recipe smart filter inverts only the smart object (\(after.pixel(360, 100)))")
            // disabled / opacity behave like any smart filter
            d.updateLayer(sl.id) { $0.smart?.filters[0].enabled = false }
            check(maxDiff(composite(d.state), before) == 0, "disabling the Recipe filter restores the original")
            d.updateLayer(sl.id) { $0.smart?.filters[0].enabled = true }
            // save / load
            let url = tempDir("smart").appendingPathComponent("smart.imagecrat")
            do {
                try DocumentIO.saveNative(d, to: url)
                let back = try DocumentIO.load(url: url)
                check(back.state.layer(sl.id)?.smart?.filters.first?.recipe == d.state.layer(sl.id)?.smart?.filters.first?.recipe && maxDiff(composite(back.state), after) == 0,
                      "Recipe smart filter survives save / load")
            } catch { check(false, "smart filter save / load: \(error)") }
            // edit through the target API + undo
            if let t, let invID = d.state.recipeGraph(t)?.nodes.first(where: { $0.type == "imath.invert" })?.id {
                check(invID != inv, "instances get fresh node ids")
                RecipeActions.mutate(d, t, commit: "Recipe: Mute") { $0.update(invID) { $0.muted = true } }
                let muted = composite(d.state)
                check(maxDiff(muted, before) == 0, "editing the filter's graph updates the render (max Δ \(maxDiff(muted, before)), px \(muted.pixel(360, 100)) vs \(before.pixel(360, 100)), edge \(muted.pixel(281, 41)) vs \(before.pixel(281, 41)))")
                d.undo()
                check(maxDiff(composite(d.state), after) == 0, "undo of a filter graph edit")
            }
        }

        // --- exposed parameters
        do {
            let d = baseDoc("exposed")
            let lid = RecipeActions.newRecipeLayer(RecipePresets.duotonePoster.graph, in: d)!
            let t = RecipeTarget.layer(lid)
            let g = d.state.recipeGraph(t)!
            check(g.exposed.map(\.label) == ["Contrast", "Levels", "Inks", "Grain"], "Duotone Poster exposes Contrast / Levels / Inks / Grain")
            let a = composite(d.state)
            let e = g.exposed[1]
            check(RecipeActions.exposedNumber(g, e) == 6, "exposed value reads the node parameter")
            RecipeActions.mutate(d, t, commit: "Recipe: Levels") { RecipeActions.setExposedNumber(&$0, e, 2) }
            check(meanDiff(composite(d.state), a) > 1, "changing an exposed parameter re-renders")
            check(RecipeActions.exposedNumber(d.state.recipeGraph(t)!, e) == 2, "exposed value written")
            // new ids per instance: two layers from the same preset don't share node ids
            let lid2 = RecipeActions.newRecipeLayer(RecipePresets.duotonePoster.graph, in: d)!
            let ids1 = Set(d.state.recipeGraph(t)!.nodes.map(\.id)), ids2 = Set(d.state.recipeGraph(.layer(lid2))!.nodes.map(\.id))
            check(ids1.isDisjoint(with: ids2), "each Recipe layer gets its own node ids")
        }

        // --- presets on disk
        do {
            let dir = tempDir("presets")
            let store = RecipePresetStore(directory: dir)
            var g = RecipePresets.glitch.graph
            g.name = "My Glitch"
            do {
                let p = try store.save(name: "My Glitch", description: "test", graph: g)
                let file = dir.appendingPathComponent("My Glitch.icrecipe")
                check(p.url == file && FileManager.default.fileExists(atPath: file.path), "preset saved as .icrecipe in the support folder")
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                check(text.contains("\"lumenRecipe\"") && text.contains("\"nodes\""), "preset file is readable JSON")
                let store2 = RecipePresetStore(directory: dir)
                store2.loadIfNeeded()
                check(store2.user.count == 1 && store2.user[0].graph == p.graph && store2.user[0].name == "My Glitch", "preset reloads with an identical graph")
                store2.delete(store2.user[0])
                check(!FileManager.default.fileExists(atPath: file.path) && store2.user.isEmpty, "preset deleted")
            } catch { check(false, "preset save: \(error)") }
            check(RecipePresetStore.defaultDirectory == nil || ProcessInfo.processInfo.environment["LUMEN_SUPPORT_DIR"] != nil, "self tests never use the real Application Support folder")
            check(RecipePresetStore.shared.directory == nil || ProcessInfo.processInfo.environment["LUMEN_SUPPORT_DIR"] != nil, "shared preset store is in-memory during tests")
        }

        // --- texture outputs
        do {
            let d = baseDoc("tex")
            app.add(d)
            defer { app.close(d) }
            var s = TextureSettings(gen: "bricks")
            let n0 = d.state.layers.count
            check(TextureActions.apply(s, output: .newLayer, in: d) && d.state.layers.count == n0 + 1 && d.state.layers.last?.isRaster == true, "texture → new pixel layer")
            check(TextureActions.apply(s, output: .recipeLayer, in: d) && d.state.layers.last?.isRecipe == true, "texture → live Recipe layer")
            check(meanDiff(composite(d.state), composite({ var st = d.state; st.layers.removeLast(); return st }())) < 1.0, "the Recipe layer matches the rendered pixel layer")
            // fill selection
            let paint = Layer.raster(name: "Paint", width: W, height: H)
            d.addLayer(paint, commitName: "New Layer")
            d.state.selection = SelectionOps.rectMask(CGRect(x: 40, y: 40, width: 100, height: 80), width: W, height: H)
            s = TextureSettings(gen: "checker")
            check(TextureActions.apply(s, output: .fillSelection, in: d), "texture → fill selection")
            let buf = d.state.layer(paint.id)!.raster!.buffer
            check(buf.alpha(60, 60) == 255 && buf.alpha(200, 200) == 0, "fill respects the selection")
            d.state.selection = nil
            check(TextureActions.apply(TextureSettings(gen: "clouds"), output: .layerMask, in: d) && d.state.layer(paint.id)?.mask != nil, "texture → layer mask")
            let pats = app.customPatterns.count
            var ps = TextureSettings(gen: "weave"); ps.values["scale"] = 16
            check(TextureActions.apply(ps, output: .pattern, patternSize: 128, in: d) && app.customPatterns.count == pats + 1, "texture → Patterns library")
            if let pat = app.customPatterns.last {
                let sc = seamScore(pat.image)
                check(pat.image.width == 128 && sc.seam <= max(6, sc.interior * 3.5), "library pattern is a seamless 128 px tile")
                app.customPatterns.removeLast()
            }
            let r = TextureActions.randomized(TextureSettings(gen: "marble"))
            check(r.values["seed"] != nil && r != TextureSettings(gen: "marble"), "Randomize changes seed / parameters")
        }

        // --- isolated renders (thumbnails, sampling) reuse the real backdrop; registration
        do {
            let d = baseDoc("thumb")
            let lid = RecipeActions.newRecipeLayer(RecipePresets.frostedGlass.graph, in: d)!
            _ = composite(d.state)
            let sp = CanvasSpace(width: W, height: H)
            let content = Compositor.shared.contentImage(d.state.layer(lid)!, space: sp) ?? CIImage.clearImage
            let cb = buffer(content, W, H)
            check(cb.opaqueBounds() != nil && lumaStdDev(cb) > 5, "layer thumbnail / sampling (no backdrop passed) shows the recipe over its real backdrop")
            check(Thumbnails.shared.layer(d.state.layer(lid)!, doc: d, size: 30) != nil, "Layers panel thumbnail renders for a Recipe layer")
            let texItems = MenuRegistry.items(for: "Filter/Render").filter { $0.submenu == "Textures" }
            check(texItems.count == TextureCatalog.all.count + 5, "Filter ▸ Render ▸ Textures lists every generator + utilities (\(texItems.count) items)")
            check(MenuRegistry.items(for: "Layer/New").contains { $0.title == "Recipe Layer…" } && MenuRegistry.items(for: "Filter").contains { $0.title == "Recipe Filter…" },
                  "menus: Layer ▸ New ▸ Recipe Layer… and Filter ▸ Recipe Filter…")
            check(["recipeNewLayer", "recipeNewFilter", "texture", "recipeNodeFilter"].allSatisfy { DialogRegistry.builders[$0] != nil } && PanelRegistry.def("recipes") != nil,
                  "dialogs and the Recipes panel are registered")
            // single-node utility filter applied destructively (Normal Map from Height)
            app.add(d)
            d.selectLayer(d.state.layers[0].id)
            let before = composite(d.state)
            RecipeNodeFilterModel.shared.start("util.normal")
            RecipeNodeFilterModel.shared.apply()
            let bgPx = d.state.layers[0].raster!.buffer.pixel(20, 20)
            check(meanDiff(composite(d.state), before) > 1 && bgPx.2 > 200, "Normal Map from Height applied to a pixel layer (flat area → \(bgPx))")
            d.undo()
            app.close(d)
        }

        // --- Time node follows the Video Timeline clock
        do {
            var st = DocumentState(width: 64, height: 48)
            st.videoTimeline = VideoTimeline()
            var b = RecipeBuilder("time")
            let t = b.add("in.time", col: 0)
            let s = b.add("in.solid", col: 1)
            let o = b.add("out.output", col: 2)
            b.wire(t, "Seconds", s, "p:color"); b.wire(s, "Image", o)
            st.layers = [Layer.recipe(name: "T", graph: b.graph)]
            let at = { (time: Double) -> Int in
                let ev = VideoTimelineEngine.evaluated(st, at: time, decodeVideo: false)
                return Int(composite(ev).pixel(5, 5).0)
            }
            let a = at(0.2), c = at(0.8)
            check(abs(a - 51) <= 3 && abs(c - 204) <= 3, "Time node follows the Video Timeline (t=0.2 → \(a), t=0.8 → \(c))")
        }
    }

    // MARK: Editor model (headless)

    static func editorTests(_ out: URL) {
        var st = SelfTest.baseState(480, 300)
        st.layers.append(SelfTest.shapeLayer(CGRect(x: 60, y: 60, width: 200, height: 140)))
        let d = Document(state: st, name: "editor")
        let lid = RecipeActions.newRecipeLayer(RecipeActions.passthroughGraph(), in: d)!
        let m = RecipeEditorModel(document: d, target: .layer(lid))
        func steps() -> Int { d.history.count }
        var n = steps()
        let blur = m.addNode("filter.gaussianBlur", at: CGPoint(x: 300, y: 200))!
        check(steps() == n + 1 && m.graph?.node(blur) != nil && m.selection == [blur], "editor: Add Node is one history step and selects the node"); n = steps()
        let src = m.graph!.nodes.first { $0.type == "in.source" }!.id, outN = m.graph!.outputNode!.id
        check(m.connect(from: src, "Image", to: blur, "Image") && m.connect(from: blur, "Image", to: outN, "Image") && steps() == n + 2, "editor: two connections, two history steps"); n = steps()
        check(m.graph!.connections.count == 2, "editor: connecting to an occupied input replaces the old wire")
        check(!m.connect(from: outN, "Image", to: blur, "Image") && steps() == n, "editor: a wire that would loop is refused without a history step")
        // slider drag coalescing
        for v in [4.0, 8, 12, 16, 20] { m.setNumber(blur, "radius", v) }
        check(steps() == n, "editor: live slider updates add no history steps")
        m.commit("Radius")
        check(steps() == n + 1 && d.history.last?.name == "Recipe: Radius" && m.graph?.node(blur)?.numbers["radius"] == 20, "editor: releasing the slider records one step"); n = steps()
        d.undo()
        check(m.graph?.node(blur)?.numbers["radius"] == 5, "editor: undo (document history) restores the parameter")
        d.redo()
        // move
        m.selectOnly(blur)
        m.dragOffset = CGSize(width: 63, height: 41)
        m.endNodeDrag()
        check(steps() == n + 1 && m.graph?.node(blur)?.position == CGPoint(x: 360, y: 240), "editor: dragging a node commits once on release (snapped to the grid)"); n = steps()
        // duplicate, copy / paste
        m.duplicateSelection()
        check(m.graph!.nodes.count == 4 && steps() == n + 1 && m.selection.count == 1 && m.selection.first != blur, "editor: Duplicate"); n = steps()
        let dup = m.selection.first!
        check(m.graph!.input(dup, "Image")?.from == src, "editor: the duplicate keeps its input wire")
        m.selection = [blur, dup]
        m.copySelection()
        m.paste(at: CGPoint(x: 600, y: 300))
        check(m.graph!.nodes.count == 6 && steps() == n + 1, "editor: Copy / Paste of two nodes is one step"); n = steps()
        // align
        m.selection = Set(m.graph!.nodes.filter { $0.type == "filter.gaussianBlur" }.map(\.id))
        m.align(.left)
        let xs = Set(m.graph!.nodes.filter { m.selection.contains($0.id) }.map(\.position.x))
        check(xs.count == 1 && steps() == n + 1, "editor: Align Left"); n = steps()
        // frame
        m.addFrame()
        check(m.graph!.frames.count == 1 && steps() == n + 1, "editor: Frame around the selection"); n = steps()
        if let f = m.graph!.frames.first {
            m.resizingFrame = f.id
            m.dragOffset = CGSize(width: 50, height: 30)
            check(m.rect(f).width == f.rect.width + 50, "editor: frame resize previews live")
            m.endFrameResize()
            check(m.graph!.frames[0].rect.size == CGSize(width: f.rect.width + 50, height: f.rect.height + 30) && steps() == n + 1, "editor: frame resize commits one step"); n = steps()
            m.draggingFrame = f.id
            m.dragOffset = CGSize(width: 20, height: 10)
            let inside = m.graph!.nodes.filter { m.graph!.frames[0].rect.contains(CGPoint(x: $0.position.x + 10, y: $0.position.y + 10)) }.map { ($0.id, $0.position) }
            m.endFrameDrag()
            let movedAll = inside.allSatisfy { id, p in m.graph!.node(id)!.position == CGPoint(x: p.x + 20, y: p.y + 10) }
            check(!inside.isEmpty && movedAll && steps() == n + 1, "editor: dragging a frame moves the nodes inside it (one step)"); n = steps()
        }
        // mute / solo
        m.selectOnly(blur)
        m.toggleMute()
        check(m.graph!.node(blur)!.muted && steps() == n + 1, "editor: Mute"); n = steps()
        m.toggleSolo(src)
        check(m.graph!.solo == src, "editor: View This Node sets the solo node")
        let soloPx = composite(d.state).pixel(100, 100)
        check(near(soloPx, 0xE9, 0x4F, 0x37), "editor: the canvas shows the soloed node (\(soloPx))")
        m.toggleSolo(nil)
        check(m.graph!.solo == nil, "editor: View Output clears solo"); n = steps()
        // expose
        m.toggleExposed(blur, "radius")
        check(m.graph!.exposed.count == 1 && m.isExposed(blur, "radius"), "editor: Expose parameter"); n = steps()
        // wire drag: pick up + drop on empty space disconnects; drop on a port reconnects
        m.beginWire(node: outN, port: "Image", isOutput: false, at: .zero)
        check(m.wire?.fromOutput == true && m.graph!.input(outN, "Image") == nil, "editor: dragging from a connected input picks the wire up")
        m.endWire(at: CGPoint(x: -500, y: -500))
        check(m.graph!.input(outN, "Image") == nil && steps() == n + 1, "editor: dropping a picked-up wire on empty canvas disconnects (one step)"); n = steps()
        m.beginWire(node: blur, port: "Image", isOutput: true, at: .zero)
        let target = RecipeLibrary.inputPosition(m.graph!.node(outN)!, "Image")
        m.endWire(at: CGPoint(x: target.x + 3, y: target.y - 2))
        check(m.graph!.input(outN, "Image")?.from == blur && steps() == n + 1, "editor: dropping a wire on a socket connects"); n = steps()
        // wire dropped on empty canvas opens search; picking a node auto-connects it
        m.beginWire(node: src, port: "Image", isOutput: true, at: .zero)
        m.endWire(at: CGPoint(x: 900, y: 500))
        check(m.search?.pending != nil, "editor: dropping a new wire on empty canvas opens the node search")
        let res = RecipeLibrary.search("hue", accepting: .image)
        check(res.first?.type == "adj.hueSaturation", "editor: search “hue” finds Hue/Saturation first (\(res.first?.name ?? "—"))")
        let added = m.addNode("adj.hueSaturation", at: m.search!.position, connecting: m.search!.pending)!
        m.search = nil
        check(m.graph!.input(added, "Image")?.from == src, "editor: the new node is wired to the dragged output")
        // type conversion feedback + number → colour socket
        let num = m.addNode("const.number", at: CGPoint(x: 0, y: 500))!
        let solid = m.addNode("in.solid", at: CGPoint(x: 250, y: 500))!
        check(m.connect(from: num, "Value", to: solid, "p:color") && m.status.contains("conversion"), "editor: number → colour wire reports the conversion")
        // delete
        n = steps()
        m.selection = [num, solid]
        m.deleteSelection()
        check(m.graph!.node(num) == nil && m.graph!.connections.allSatisfy { $0.to != solid } && steps() == n + 1, "editor: Delete removes nodes and their wires in one step")
        // box select
        m.box = CGRect(x: -10000, y: -10000, width: 20000, height: 20000)
        m.finishBox(extend: false)
        check(m.selection.count == m.graph!.nodes.count, "editor: box select")
        // search coverage
        check(RecipeLibrary.search("").count == RecipeLibrary.all.count && RecipeLibrary.search("perlin").first?.type == "gen.perlin" && !RecipeLibrary.search("zzzz").map(\.type).contains("gen.perlin"),
              "editor: search index (\(RecipeLibrary.all.count) node types)")
        // previews + errors
        m.refreshPreviews(synchronous: true)
        check(m.previews.count >= 3 && m.errors.isEmpty, "editor: node previews rendered (\(m.previews.count)), no errors")
        // library coverage
        let filterCount = RecipeLibrary.all.filter { $0.type.hasPrefix("filter.") }.count
        check(filterCount == FilterKind.allCases.count - 3, "library: one node per FilterKind (\(filterCount))")
        check(RecipeLibrary.all.filter { $0.type.hasPrefix("gallery.") }.count == GalleryFilter.allCases.count, "library: one node per Filter Gallery look")
        check(RecipeLibrary.all.filter { $0.type.hasPrefix("gen.") }.count == TextureCatalog.all.count, "library: one node per texture generator (\(TextureCatalog.all.count))")
        check(RecipeLibrary.all.filter { $0.type.hasPrefix("adj.") }.count == AdjustmentKind.allCases.count - 1, "library: one node per adjustment kind")
        check(Set(RecipeLibrary.all.map(\.type)).count == RecipeLibrary.all.count, "library: node type ids are unique")
    }

    /// Every node type evaluates on a sample image without throwing (other than a missing second input).
    static func libraryTests(_ out: URL) {
        let W = 160, H = 120
        let sp = CanvasSpace(width: W, height: H)
        let sample = RecipeThumbnails.sampleImage(width: W, height: H)
        var failed: [String] = []
        var blank: [String] = []
        let t0 = CFAbsoluteTimeGetCurrent()
        for spec in RecipeLibrary.all where spec.category != .output {
            var g = RecipeGraph(name: spec.type)
            let src = RecipeLibrary.makeNode("in.source"), grad = RecipeLibrary.makeNode("gen.perlin")
            var n = RecipeLibrary.makeNode(spec.type)
            if spec.type == "in.file" { n.strings["path"] = photoPath }
            let o = RecipeLibrary.makeNode(RecipeLibrary.outputNodeType)
            g.nodes = [src, grad, n, o]
            for (i, inp) in spec.inputs.enumerated() { _ = try? g.connect(from: i == 0 ? src.id : grad.id, "Image", to: n.id, inp.name) }
            guard let first = spec.outputs.first else { continue }
            _ = try? g.connect(from: n.id, first.name, to: o.id, "Image")
            let id = UUID()
            let needsDoc = spec.uses.contains(.document)
            let img = RecipeRuntime.shared.render(target: id, graph: g, source: sample, space: sp)
            let b = buffer(img, W, H)
            if let e = RecipeRuntime.shared.errors(target: id)[n.id], !needsDoc { failed.append("\(spec.type): \(e)") }
            if first.type == .image || first.type == .mask, !needsDoc, b.opaqueBounds() == nil { blank.append(spec.type) }
        }
        check(failed.isEmpty, "library: all \(RecipeLibrary.all.count) node types evaluate without errors \(failed.prefix(6))")
        check(blank.isEmpty, "library: every image node produces pixels \(blank.prefix(8))")
        print(String(format: "nodes: evaluated every node type in %.1fs", CFAbsoluteTimeGetCurrent() - t0))
    }

    // MARK: Performance

    static func perfTests(_ out: URL) {
        let W = 2000, H = 1500
        let sp = CanvasSpace(width: W, height: H)
        let src = RecipeThumbnails.sampleImage(width: W, height: H)
        // 15-node graph: source → grade → blur/mask chain → textures → blends → output
        var b = RecipeBuilder("Perf 15")
        let s = b.add("in.source", col: 0)
        let lv = b.add("adj.levels", col: 1, ["inBlack": 12, "inWhite": 240])
        let hs = b.add("adj.hueSaturation", col: 2, ["hsSaturation": 20])
        let bl = b.add("filter.gaussianBlur", col: 3, ["radius": 12])
        let ed = b.add("util.edge", col: 3, row: 1)
        let mk = b.add("mask.feather", col: 4, row: 1, ["radius": 6])
        let mx = b.add("imath.mix", col: 5)
        let n1 = b.add("gen.fbm", col: 4, row: 2)
        let n2 = b.add("gen.worley", col: 4, row: 3)
        let gm = b.add("util.gradientMap", col: 5, row: 2)
        let b1 = b.add("comp.blend", col: 6, ["mode": Double(BlendMode.layerModes.firstIndex(of: .softLight)!), "opacity": 60])
        let b2 = b.add("comp.blend", col: 7, ["mode": Double(BlendMode.layerModes.firstIndex(of: .multiply)!), "opacity": 40])
        let gr = b.add("gen.filmgrain", col: 7, row: 1)
        let b3 = b.add("comp.blend", col: 8, ["mode": Double(BlendMode.layerModes.firstIndex(of: .overlay)!), "opacity": 40])
        let o = b.add("out.output", col: 9)
        b.wire(s, "Image", lv); b.wire(lv, "Image", hs); b.wire(hs, "Image", bl); b.wire(hs, "Image", ed); b.wire(ed, "Edges", mk, "Mask")
        b.wire(bl, "Image", mx, "A"); b.wire(hs, "Image", mx, "B"); b.wire(mk, "Mask", mx, "Factor")
        b.wire(n1, "Image", gm); b.wire(mx, "Image", b1, "Base"); b.wire(gm, "Image", b1, "Blend")
        b.wire(b1, "Image", b2, "Base"); b.wire(n2, "Image", b2, "Blend"); b.wire(b2, "Image", b3, "Base"); b.wire(gr, "Image", b3, "Blend"); b.wire(b3, "Image", o)
        check(b.graph.nodes.count == 15, "perf graph has 15 nodes")
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.shaderWrite, .shaderRead, .renderTarget]
        guard let tex = RenderEngine.device.makeTexture(descriptor: td) else { check(false, "perf: texture"); return }
        let id = UUID()
        func frame(_ g: RecipeGraph) -> (build: Double, total: Double) {
            let t0 = CFAbsoluteTimeGetCurrent()
            let img = RecipeRuntime.shared.render(target: id, graph: g, source: src, space: sp)
            let t1 = CFAbsoluteTimeGetCurrent()
            let cb = RenderEngine.commandQueue.makeCommandBuffer()!
            RenderEngine.context.render(img, to: tex, commandBuffer: cb, bounds: sp.ciCanvas, colorSpace: sRGBSpace)
            cb.commit(); cb.waitUntilCompleted()
            return ((t1 - t0) * 1000, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        let first = frame(b.graph)
        // every frame changes a parameter near the start of the chain, so nearly everything re-renders
        var totals: [Double] = [], builds: [Double] = []
        for i in 0..<12 {
            var g = b.graph
            g.update(lv) { $0.numbers["inBlack"] = Double(i % 6) * 3 }
            g.update(n1) { $0.numbers["seed"] = Double(i + 2) }
            let f = frame(g)
            totals.append(f.total); builds.append(f.build)
        }
        totals.sort()
        let median = totals[totals.count / 2]
        var unchanged: [Double] = []
        for _ in 0..<6 { unchanged.append(frame(b.graph).total) }
        unchanged.sort()
        #if DEBUG
        let config = "debug"
        #else
        let config = "release"
        #endif
        print(String(format: "nodes perf (%@ build, 2000×1500, 15 nodes): first frame %.0f ms (kernel compile), changed-parameter frame median %.1f ms (min %.1f, max %.1f), graph build %.2f ms, unchanged frame %.1f ms",
                     config, first.total, median, totals.first ?? 0, totals.last ?? 0, builds.reduce(0, +) / Double(builds.count), unchanged[unchanged.count / 2]))
        check(median < 400, "perf: full-canvas evaluation of a 15-node graph under 400 ms (\(String(format: "%.1f", median)) ms)")
        // single generator throughput
        var gens: [(String, Double)] = []
        for gid in ["perlin", "fbm", "worley", "curl", "marble", "caustics", "bokeh", "frost", "terrain"] {
            var s2 = TextureSettings(gen: gid)
            _ = { let cb = RenderEngine.commandQueue.makeCommandBuffer()!; RenderEngine.context.render(TextureEngine.render(s2, space: sp), to: tex, commandBuffer: cb, bounds: sp.ciCanvas, colorSpace: sRGBSpace); cb.commit(); cb.waitUntilCompleted() }()
            var ts: [Double] = []
            for i in 0..<5 {
                s2.values["seed"] = Double(i + 3)
                let t0 = CFAbsoluteTimeGetCurrent()
                let cb = RenderEngine.commandQueue.makeCommandBuffer()!
                RenderEngine.context.render(TextureEngine.render(s2, space: sp), to: tex, commandBuffer: cb, bounds: sp.ciCanvas, colorSpace: sRGBSpace)
                cb.commit(); cb.waitUntilCompleted()
                ts.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
            ts.sort()
            gens.append((gid, ts[ts.count / 2]))
        }
        print("nodes perf generators @2000×1500: " + gens.map { String(format: "%@ %.1f ms", $0.0, $0.1) }.joined(separator: ", "))
    }

    // MARK: UI snapshots (LUMEN_SELFTEST_UI=1)

    static func snap<V: View>(_ v: V, _ name: String, _ size: CGSize, _ out: URL, wait: Double = 0.4) {
        let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height).background(Theme.panelBG).environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(wait))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        print("wrote \(name)")
    }

    static func uiSnapshots(_ out: URL) {
        let app = AppModel.shared
        var st = DocumentState(width: 900, height: 600)
        let bg = testPhoto(900, 600) ?? buffer(RecipeThumbnails.sampleImage(width: 900, height: 600), 900, 600)
        st.layers = [Layer.raster(name: "Background", buffer: bg)]
        let d = Document(state: st, name: "ui")
        app.add(d)
        defer { app.close(d) }
        let lid = RecipeActions.newRecipeLayer(RecipePresets.filmLook.graph, in: d)!
        _ = composite(d.state)      // gives the runtime the real backdrop for node previews
        let m = RecipeEditorModel(document: d, target: .layer(lid))
        m.viewSize = CGSize(width: 1000, height: 700)
        m.refreshPreviews(synchronous: true)
        snap(RecipeEditorView(model: m), "nodes_ui_editor_film_look", CGSize(width: 1280, height: 780), out, wait: 0.8)
        // a node selected: inspector with parameters, a soloed node, search popup
        if let blur = m.graph?.nodes.first(where: { $0.type == "filter.gaussianBlur" }) {
            m.selectOnly(blur.id)
            m.zoom = 1; m.pan = CGPoint(x: 330 - blur.position.x, y: 120 - blur.position.y)
            m.search = .init(position: m.toGraph(CGPoint(x: 80, y: 60)), query: "blur")
            snap(RecipeEditorView(model: m), "nodes_ui_editor_inspector_search", CGSize(width: 1280, height: 780), out, wait: 0.8)
            m.search = nil
        }
        // a smaller recipe with number wires + a wire being dragged
        let lid2 = RecipeActions.newRecipeLayer(RecipePresets.glitch.graph, in: d)!
        _ = composite(d.state)
        let m2 = RecipeEditorModel(document: d, target: .layer(lid2))
        m2.refreshPreviews(synchronous: true)
        if let g = m2.graph, let src = g.nodes.first(where: { $0.type == "gen.scanlines" }) {
            m2.wire = .init(node: src.id, port: "Image", fromOutput: true, type: .image, point: CGPoint(x: src.position.x + 420, y: src.position.y + 160))
            m2.selection = [src.id]
        }
        snap(RecipeEditorView(model: m2), "nodes_ui_editor_glitch", CGSize(width: 1400, height: 820), out, wait: 0.8)
        if (ProcessInfo.processInfo.environment["LUMEN_NODES_ONLY"] ?? "").contains("uiall") {
            for p in RecipePresets.builtIn {
                let l = RecipeActions.newRecipeLayer(p.graph, in: d)!
                _ = composite(d.state)
                let pm = RecipeEditorModel(document: d, target: .layer(l))
                pm.refreshPreviews(synchronous: true)
                snap(RecipeEditorView(model: pm), "nodes_ui_preset_" + p.name.lowercased().filter { $0.isLetter }, CGSize(width: 1500, height: 820), out, wait: 0.6)
                d.undo()
            }
        }
        // Properties panel with exposed parameters
        d.selectLayer(lid)
        snap(ScrollView { VStack(alignment: .leading, spacing: 10) { PropertiesContent(doc: d, layer: d.state.layer(lid)!) }.padding(10) }, "nodes_ui_properties_exposed", CGSize(width: 300, height: 420), out)
        // dialogs
        snap(DraggableCard { RecipePresetDialog(asFilter: false) }, "nodes_ui_new_recipe_dialog", CGSize(width: 600, height: 520), out, wait: 1.0)
        TextureDialogModel.shared.start("marble")
        TextureDialogModel.shared.preview = false
        snap(DraggableCard { TextureDialog() }, "nodes_ui_texture_dialog", CGSize(width: 640, height: 560), out, wait: 0.8)
        RecipeNodeFilterModel.shared.start("util.normal")
        RecipeNodeFilterModel.shared.preview = false
        snap(DraggableCard { RecipeNodeFilterDialog() }, "nodes_ui_normal_map_dialog", CGSize(width: 400, height: 220), out)
        snap(RecipesPanel(), "nodes_ui_recipes_panel", CGSize(width: 300, height: 560), out, wait: 1.0)
        d.displayOverride = nil
    }
}
