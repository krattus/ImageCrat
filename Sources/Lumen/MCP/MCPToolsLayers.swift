import AppKit
import ImageCratCore

// MCP tools: layers (add / properties / delete / duplicate / move / group / merge / select), layer styles, transforms,
// text and shapes.

private typealias S = MCPSchema

extension MCPTools {
    static let layerID = S.string("Layer id (from get_document_info). Default: the active layer.")
    static let layerKinds = ["pixel", "text", "shape", "solid_fill", "gradient_fill", "adjustment", "group"]
    static let alignments = ["left", "center", "right", "justify"]
    static let shapeKinds = ["rect", "rectangle", "ellipse", "polygon", "star", "line"]

    static var blendModeNames: [String] { BlendMode.allCases.map(\.rawValue) }

    static func gradientSchema(_ d: String) -> [String: Any] {
        S.object(["colors": S.array("Colour stops, evenly spaced (first = start).", items: S.color("A stop colour."), minItems: 2, maxItems: 16),
                  "type": S.string("Gradient shape.", oneOf: GradientType.allCases.map(\.rawValue), default: "linear"),
                  "angle": S.number("Angle in degrees (90 = top to bottom).", min: -360, max: 360, default: 90),
                  "reverse": S.boolean("Reverse the colours.", default: false)],
                 required: ["colors"], description: d)
    }

    static func gradient(_ o: [String: Any], name: String) throws -> GradientFill {
        let cols = try ((o["colors"] as? [Any]) ?? []).enumerated().map { try MCPArgs.color($0.element, name: "\(name).colors[\($0.offset)]") }
        guard cols.count >= 2 else { throw MCPToolError("`\(name).colors` needs at least two colours.") }
        let stops = cols.enumerated().map { GradientStop(location: Double($0.offset) / Double(cols.count - 1), color: $0.element) }
        return GradientFill(gradient: ColorGradient(name: "MCP", stops: stops),
                            type: (o["type"] as? String).flatMap(GradientType.init(rawValue:)) ?? .linear,
                            angle: MCPJSON.double(o["angle"]) ?? 90, reverse: (o["reverse"] as? Bool) ?? false)
    }

    // MARK: Builders shared by add_layer / add_text / add_shape

    static let textProps: [String: [String: Any]] = [
        "text": S.string("The text. Use \\n for line breaks.", minLength: 1),
        "font": S.string("Font PostScript name or family (see list_fonts), e.g. \"Helvetica-Bold\" or \"Avenir Next\". Default Helvetica."),
        "size": S.number("Font size in pixels.", min: 1, max: 5000, default: 48),
        "color": S.color("Text colour. Default black."),
        "position": S.point("Top-left corner of the text (or of its box) in document pixels. Default {x: 20, y: 20}."),
        "alignment": S.string("Paragraph alignment.", oneOf: alignments, default: "left"),
        "box": S.object(["width": S.number("Box width in pixels.", min: 1), "height": S.number("Box height in pixels.", min: 1)], required: ["width", "height"],
                        description: "Paragraph text box: the text wraps inside it. Default: point text (no wrapping)."),
    ]

    static func fontName(_ requested: String) throws -> String {
        if NSFont(name: requested, size: 12) != nil { return requested }
        if let f = NSFontManager.shared.font(withFamily: requested, traits: [], weight: 5, size: 12) { return f.fontName }
        let n = norm(requested)
        if let match = NSFontManager.shared.availableFonts.first(where: { norm($0) == n }) { return match }
        let near = NSFontManager.shared.availableFontFamilies.filter { norm($0).contains(n.prefix(5)) }.prefix(5)
        throw MCPToolError("Font “\(requested)” is not installed." + (near.isEmpty ? "" : " Similar: \(near.joined(separator: ", ")).") + " Use list_fonts to see the fonts.")
    }

    static func applyText(_ t: inout TextContent, _ a: MCPArgs) throws {
        if let s = a.string("text") { t.text = s; t.runs = [] }
        if let f = a.string("font") { t.fontName = try fontName(f) }
        if let s = a.double("size") { t.fontSize = s }
        if let c = try a.color("color") { t.color = c }
        if let p = a.point("position") { t.position = p }
        if let al = a.string("alignment") { t.alignment = TextAlign(rawValue: al) ?? .left }
        if a.raw["box"] is NSNull { t.boxSize = nil }
        if let b = a.object("box"), let w = MCPJSON.double(b["width"]), let h = MCPJSON.double(b["height"]) { t.boxSize = CGSize(width: w, height: h) }
    }

    static func addText(_ d: Document, _ a: MCPArgs) throws -> Layer {
        guard a.string("text")?.isEmpty == false else { throw MCPToolError("`text` is required for a text layer.") }
        var t = TextContent()
        t.position = CGPoint(x: 20, y: 20)
        t.fontSize = 48
        t.color = .black
        try applyText(&t, a)
        let l = Layer(name: a.string("name") ?? String(t.text.replacingOccurrences(of: "\n", with: " ").prefix(30)), content: .text(t))
        d.addLayer(l, commitName: "New Type Layer")
        return l
    }

    static let shapeProps: [String: [String: Any]] = [
        "shape": S.string("Shape kind.", oneOf: shapeKinds),
        "bounds": S.rect("Bounding box in document pixels (for a line: from the top-left to the bottom-right corner)."),
        "fill": S.color("Fill colour, or \"none\". Default #4A90E2."),
        "stroke": S.color("Stroke colour. Default: no stroke."),
        "stroke_width": S.number("Stroke width in pixels.", min: 0, max: 1000, default: 3),
        "corner_radius": S.number("Rectangle corner radius in pixels.", min: 0, default: 0),
        "sides": S.integer("Polygon / star points.", min: 3, max: 100, default: 5),
        "star_ratio": S.number("Star inner radius as a fraction of the outer one (0.1–0.95).", min: 0.05, max: 0.99, default: 0.5),
    ]

    static func addShape(_ d: Document, _ a: MCPArgs, kindKey: String = "shape") throws -> Layer {
        guard let kind = a.string(kindKey)?.lowercased() else { let kinds = shapeKinds.joined(separator: ", "); throw MCPToolError("`\(kindKey)` is required (\(kinds)).") }
        guard let r = a.rect("bounds") else { throw MCPToolError("`bounds` {x, y, width, height} is required for a shape.") }
        let geo: ShapeGeometry
        switch kind {
        case "ellipse", "circle": geo = .ellipse(r)
        case "polygon", "star": geo = .polygon(r, sides: a.int("sides") ?? 5, starRatio: kind == "star" ? (a.double("star_ratio") ?? 0.5) : 1)
        case "line": geo = .line(CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), weight: a.double("stroke_width") ?? 4)
        default: geo = .rectangle(r, cornerRadius: a.double("corner_radius") ?? 0)
        }
        let fill: PaintStyle
        if let s = a.string("fill"), s.lowercased() == "none" || s.lowercased() == "transparent" { fill = .none }
        else { fill = .color(try a.color("fill") ?? RGBA(hex: "4A90E2")!) }
        var sc = ShapeContent(geometry: geo, fill: kind == "line" && !a.has("fill") ? .color(try a.color("stroke") ?? .black) : fill)
        if let c = try a.color("stroke"), kind != "line" { sc.stroke = StrokeStyle(paint: .color(c), width: a.double("stroke_width") ?? 3) }
        let l = Layer(name: a.string("name") ?? d.nextLayerName(geo.kindName), content: .shape(sc))
        d.addLayer(l, commitName: "New Shape Layer")
        return l
    }

    static func resultLayer(_ d: Document, _ id: UUID, _ summary: String) -> MCPToolResult {
        guard let l = d.state.layer(id) else { return ok(summary) }
        return ok(summary, ["layer": layerJSON(d, l), "doc_id": d.id.uuidString])
    }

    // MARK: - Layers

    static let layerTools: [MCPTool] = [
        MCPTool("add_layer", "Add Layer",
                "Add a layer above the active one and make it active. kind: pixel (empty, or filled with `color`), text (see add_text), "
                + "shape (see add_shape), solid_fill (`color`), gradient_fill (`gradient`), adjustment (`adjustment` + `params`, see list_adjustments), "
                + "group (optionally around `layer_ids`).",
                schema: S.object([
                    "kind": S.string("Layer kind.", oneOf: layerKinds),
                    "name": S.string("Layer name."),
                    "color": S.color("pixel: fill colour (default transparent); solid_fill: the colour (default the foreground colour)."),
                    "gradient": gradientSchema("gradient_fill: the gradient."),
                    "adjustment": S.string("adjustment: the adjustment kind (see list_adjustments), e.g. \"hueSaturation\"."),
                    "params": S.map("adjustment: its settings (see list_adjustments)."),
                    "layer_ids": S.array("group: layers to put into the new group.", items: S.string("A layer id.")),
                    "opacity": S.number("Layer opacity in percent.", min: 0, max: 100, default: 100),
                    "blend_mode": S.string("Blend mode.", oneOf: blendModeNames),
                    "doc_id": docID,
                ].merging(textProps) { a, _ in a }.merging(shapeProps) { a, _ in a }, required: ["kind"])) { a in
            let d = try doc(a)
            let kind = a.string("kind")!
            var id: UUID
            switch kind {
            case "text": id = try addText(d, a).id
            case "shape": id = try addShape(d, a).id
            case "pixel":
                var l = Layer.raster(name: a.string("name") ?? d.nextLayerName(), width: d.state.width, height: d.state.height)
                if let c = try a.color("color") {
                    let buf = l.raster!.buffer
                    buf.context.setFillColor(c.cgColor)
                    buf.context.fill(CGRect(x: 0, y: 0, width: buf.width, height: buf.height))
                    buf.markDirty()
                    l.raster = RasterContent(buffer: buf, origin: .zero)
                }
                d.addLayer(l, commitName: "New Layer")
                id = l.id
            case "solid_fill", "gradient_fill":
                let paint: PaintStyle
                if kind == "solid_fill" { paint = .color(try a.color("color") ?? app.foreground) } else {
                    guard let g = a.object("gradient") else { throw MCPToolError("gradient_fill needs `gradient` {colors: [\"#…\", \"#…\"]}.") }
                    paint = .gradient(try gradient(g, name: "gradient"))
                }
                let base = kind == "solid_fill" ? "Color Fill" : "Gradient Fill"
                var l = Layer(name: a.string("name") ?? d.nextLayerName(base), content: .fill(FillContent(paint: paint)))
                if let sel = d.state.selection { l.mask = LayerMask(buffer: sel.copy(), origin: .zero, outsideValue: 0) }
                d.addLayer(l, commitName: "New \(base) Layer")
                id = l.id
            case "adjustment":
                guard let k = a.string("adjustment") else { throw MCPToolError("An adjustment layer needs `adjustment` (see list_adjustments).") }
                id = try addAdjustmentLayer(d, kind: k, params: a.object("params") ?? [:], name: a.string("name"))
            case "group":
                if let ids = a.array("layer_ids") as? [String], !ids.isEmpty {
                    id = try groupLayers(d, ids, name: a.string("name"))
                } else {
                    let g = Layer(name: a.string("name") ?? d.nextLayerName("Group"), content: .group(GroupContent()))
                    d.addLayer(g, commitName: "New Group")
                    id = g.id
                }
            default: throw MCPToolError("Unknown layer kind \(kind).")
            }
            if a.has("opacity") || a.has("blend_mode") {
                let m = try a.blendMode("blend_mode")
                d.updateLayer(id) { l in
                    if let o = a.double("opacity") { l.opacity = o / 100 }
                    if let m { l.blendMode = m }
                }
                d.commit("Layer Properties")
            }
            if let n = a.string("name"), d.state.layer(id)?.name != n { d.updateLayer(id) { $0.name = n }; d.commit("Rename Layer") }
            return resultLayer(d, id, "Added \(kind) layer “\(d.state.layer(id)?.name ?? "")”.")
        },

        MCPTool("set_layer_properties", "Set Layer Properties",
                "Change a layer's name, visibility, opacity, fill opacity, blend mode, lock, clipping or position (the top-left of its bounds).",
                schema: S.object(["layer_id": layerID, "name": S.string("New name.", minLength: 1), "visible": S.boolean("Show or hide the layer."),
                                  "opacity": S.number("Opacity in percent.", min: 0, max: 100),
                                  "fill_opacity": S.number("Fill opacity in percent (effects keep full opacity).", min: 0, max: 100),
                                  "blend_mode": S.string("Blend mode.", oneOf: blendModeNames), "locked": S.boolean("Lock all (no edits)."),
                                  "clipped": S.boolean("Clip to the layer below (clipping mask)."),
                                  "position": S.point("Move the layer so its bounds' top-left corner is here."),
                                  "doc_id": docID])) { a in
            let d = try doc(a)
            let l = try layer(d, a)
            let mode = try a.blendMode("blend_mode")
            var delta: (Double, Double)?
            if let p = a.point("position") {
                guard let b = Compositor.shared.contentBounds(l, state: d.state), !b.isNull else { throw MCPToolError("“\(l.name)” has no pixels to position.") }
                delta = (Double(p.x - b.minX), Double(p.y - b.minY))
            }
            d.updateLayer(l.id) { x in
                if let n = a.string("name") { x.name = n }
                if let v = a.bool("visible") { x.isVisible = v }
                if let o = a.double("opacity") { x.opacity = o / 100 }
                if let o = a.double("fill_opacity") { x.fillOpacity = o / 100 }
                if let m = mode { x.blendMode = m }
                if let k = a.bool("locked") { x.locks.all = k }
                if let c = a.bool("clipped") { x.isClipped = c }
            }
            if let (dx, dy) = delta, dx != 0 || dy != 0 {
                for id in d.withLinked([l.id]) { d.updateLayer(id) { $0.translate(dx: dx, dy: dy) } }
            }
            d.commit("Layer Properties")
            return resultLayer(d, l.id, "Updated “\(d.state.layer(l.id)?.name ?? l.name)”.")
        },

        MCPTool("delete_layer", "Delete Layer", "Delete a layer (a group with everything in it).",
                schema: S.object(["layer_id": S.string("Id of the layer to delete.", minLength: 1), "doc_id": docID], required: ["layer_id"]),
                destructive: true) { a in
            let d = try doc(a)
            let l = try layer(d, a, required: true)
            if d.state.layers.count == 1 && d.state.layers[0].id == l.id { throw MCPToolError("“\(l.name)” is the only layer: a document needs at least one.") }
            d.state.removeLayer(l.id)
            d.validateActiveLayer()
            d.commit("Delete Layer")
            return ok("Deleted “\(l.name)”.", ["deleted": l.id.uuidString, "active_layer_id": (d.activeLayerID?.uuidString as Any?) ?? NSNull()])
        },

        MCPTool("duplicate_layer", "Duplicate Layer", "Duplicate a layer; the copy goes right above it and becomes active.",
                schema: S.object(["layer_id": layerID, "name": S.string("Name of the copy. Default “<name> copy”."), "doc_id": docID])) { a in
            let d = try doc(a)
            let l = try layer(d, a)
            let c = l.duplicated(newName: a.string("name") ?? l.name + " copy")
            d.state.insertLayer(c, above: l.id)
            d.activeLayerID = c.id; d.selectedLayerIDs = [c.id]
            d.commit("Duplicate Layer")
            return resultLayer(d, c.id, "Duplicated “\(l.name)”.")
        },

        MCPTool("move_layer", "Move Layer",
                "Change a layer's place in the stack: `index` among its siblings (0 = bottom), directly `above` / `below` another layer, "
                + "or `into_group` (as the group's top layer). Give one of them.",
                schema: S.object(["layer_id": S.string("Id of the layer to move.", minLength: 1),
                                  "index": S.integer("New position among its siblings (0 = bottom, -1 = top).", min: -1),
                                  "above": S.string("Put it directly above this layer id."), "below": S.string("Put it directly below this layer id."),
                                  "into_group": S.string("Put it inside this group (layer id), at the top."), "doc_id": docID], required: ["layer_id"])) { a in
            let d = try doc(a)
            let l = try layer(d, a, required: true)
            let choices = ["index", "above", "below", "into_group"].filter { a.has($0) }
            guard choices.count == 1 else { throw MCPToolError("Give exactly one of `index`, `above`, `below` or `into_group`.") }
            if let i = a.int("index") {
                guard var path = d.state.layers.indexPath(of: l.id) else { throw MCPToolError("Layer not found.") }
                let count = d.state.siblings(of: l.id).count
                let moved = d.state.layers.remove(at: path)
                path[path.count - 1] = i < 0 ? count - 1 : min(i, count - 1)
                d.state.layers.insert(moved, at: path)
            } else {
                let key = choices[0]
                let target = try layer(d, a, key: key, required: true)
                if l.allIDs.contains(target.id) { throw MCPToolError("A layer can't be moved into or next to itself or its own contents.") }
                if key == "into_group" && !target.isGroup { throw MCPToolError("“\(target.name)” is not a group.") }
                guard let moved = d.state.removeLayer(l.id) else { throw MCPToolError("Layer not found.") }
                switch key {
                case "below": d.state.insertLayer(moved, below: target.id)
                case "into_group": d.state.insertLayer(moved, above: target.id, inside: true)
                default: d.state.insertLayer(moved, above: target.id)
                }
            }
            d.commit("Move Layer")
            return resultLayer(d, l.id, "Moved “\(l.name)”.")
        },

        MCPTool("group_layers", "Group Layers", "Put layers into a new group (placed where the topmost of them was).",
                schema: S.object(["layer_ids": S.array("Ids of the layers to group.", items: S.string("A layer id."), minItems: 1),
                                  "name": S.string("Group name."), "doc_id": docID], required: ["layer_ids"])) { a in
            let d = try doc(a)
            let id = try groupLayers(d, (a.array("layer_ids") as? [String]) ?? [], name: a.string("name"))
            return resultLayer(d, id, "Grouped \((a.array("layer_ids") ?? []).count) layer(s).")
        },

        MCPTool("merge_layers", "Merge Layers", "Merge layers (siblings in the same group) into one pixel layer.",
                schema: S.object(["layer_ids": S.array("Ids of the layers to merge.", items: S.string("A layer id."), minItems: 2),
                                  "doc_id": docID], required: ["layer_ids"]), destructive: true) { a in
            let d = try doc(a)
            let ids = try ((a.array("layer_ids") as? [String]) ?? []).map { s -> UUID in
                guard let u = UUID(uuidString: s), d.state.layer(u) != nil else { throw MCPToolError("Layer not found: \(s).") }
                return u
            }
            let parents = Set(ids.map { d.state.parentID(of: $0)?.uuidString ?? "root" })
            guard parents.count == 1 else { throw MCPToolError("The layers must be siblings (in the same group). Move them first with move_layer.") }
            let ordered = d.state.allLayers.map(\.id).filter { ids.contains($0) }
            AppActions.mergeLayers(ordered)
            guard let merged = d.activeLayerID, !ids.contains(merged) else { throw MCPToolError("The layers could not be merged.") }
            return resultLayer(d, merged, "Merged \(ids.count) layers.")
        },

        MCPTool("select_layer", "Select Layer", "Make a layer the active (selected) layer, or add it to the selected layers.",
                schema: S.object(["layer_id": S.string("Id of the layer.", minLength: 1), "add": S.boolean("Add to the selected layers instead.", default: false),
                                  "doc_id": docID], required: ["layer_id"])) { a in
            let d = try doc(a)
            let l = try layer(d, a, required: true)
            if a.bool("add") == true { if !d.selectedLayerIDs.contains(l.id) { d.selectLayer(l.id, extend: true) } } else { select(d, l.id) }
            return ok("“\(l.name)” is the active layer.", ["active_layer_id": l.id.uuidString, "selected": d.orderedSelection.map(\.uuidString)])
        },

        MCPTool("set_layer_style", "Set Layer Style",
                "Add, change or remove layer effects. Each effect is an object of settings (it is turned on) or false (turned off). "
                + "Opacity is 0–100, sizes and distances in pixels, angles in degrees. `clear: true` removes all effects first.",
                schema: S.object(effectSchemas.merging(["layer_id": layerID, "clear": S.boolean("Remove all existing effects first.", default: false),
                                                        "doc_id": docID]) { a, _ in a })) { a in
            let d = try doc(a)
            let l = try layer(d, a)
            var fx = a.bool("clear") == true ? LayerEffects() : l.effects
            for key in effectSchemas.keys.sorted() where a.has(key) { try applyEffect(&fx, key, a[key]!) }
            fx.enabled = true
            d.updateLayer(l.id) { $0.effects = fx }
            d.commit("Layer Style")
            return resultLayer(d, l.id, "Layer style of “\(l.name)”: \(effectNames(fx).joined(separator: ", ").isEmpty ? "no effects" : effectNames(fx).joined(separator: ", ")).")
        },

        MCPTool("transform_layer", "Transform Layer",
                "Scale, rotate, flip and move a layer (around the centre of its bounds). Linked layers follow, like Free Transform.",
                schema: S.object(["layer_id": layerID,
                                  "scale": S.anyOf("Scale in percent: one number (uniform) or {x, y}.",
                                                   [["type": "number", "minimum": 0.1, "maximum": 10000],
                                                    S.object(["x": S.number("Horizontal scale in percent.", min: 0.1, max: 10000),
                                                              "y": S.number("Vertical scale in percent.", min: 0.1, max: 10000)], required: ["x", "y"])]),
                                  "rotate": S.number("Rotation in degrees, clockwise.", min: -360, max: 360),
                                  "translate": S.object(["x": S.number("Horizontal offset in pixels."), "y": S.number("Vertical offset in pixels.")],
                                                        required: ["x", "y"], description: "Move by this many pixels."),
                                  "flip": S.string("Mirror the layer.", oneOf: ["horizontal", "vertical", "both"]),
                                  "doc_id": docID])) { a in
            let d = try doc(a)
            let l = try layer(d, a)
            var sx = 1.0, sy = 1.0
            if let s = a.double("scale") { sx = s / 100; sy = s / 100 }
            if let s = a.object("scale") { sx = (MCPJSON.double(s["x"]) ?? 100) / 100; sy = (MCPJSON.double(s["y"]) ?? 100) / 100 }
            let flip = a.string("flip")
            if flip == "horizontal" || flip == "both" { sx = -sx }
            if flip == "vertical" || flip == "both" { sy = -sy }
            let r = (a.double("rotate") ?? 0) * .pi / 180
            let t = a.object("translate")
            let dx = MCPJSON.double(t?["x"]) ?? 0, dy = MCPJSON.double(t?["y"]) ?? 0
            guard sx != 1 || sy != 1 || r != 0 || dx != 0 || dy != 0 else { throw MCPToolError("Nothing to do: give `scale`, `rotate`, `translate` or `flip`.") }
            guard !l.locks.positionLocked else { throw MCPToolError("“\(l.name)” is locked (position): unlock it with set_layer_properties first.") }
            select(d, l.id)
            let before = d.currentHistoryEntryID
            AppActions.transformSelectedLayers({ b in
                let c = CGPoint(x: b.midX, y: b.midY)
                let m = CGAffineTransform(translationX: -c.x, y: -c.y)
                    .concatenating(CGAffineTransform(scaleX: CGFloat(sx), y: CGFloat(sy)))
                    .concatenating(CGAffineTransform(rotationAngle: CGFloat(r)))
                    .concatenating(CGAffineTransform(translationX: c.x + CGFloat(dx), y: c.y + CGFloat(dy)))
                return Homography(affine: m)
            }, name: "Transform")
            guard d.currentHistoryEntryID != before else { throw MCPToolError("“\(l.name)” could not be transformed (it has no pixels).") }
            return resultLayer(d, l.id, "Transformed “\(l.name)”.")
        },
    ]

    static func groupLayers(_ d: Document, _ idStrings: [String], name: String?) throws -> UUID {
        let ids = try idStrings.map { s -> UUID in
            guard let u = UUID(uuidString: s), d.state.layer(u) != nil else { throw MCPToolError("Layer not found: \(s).") }
            return u
        }
        guard !ids.isEmpty else { throw MCPToolError("`layer_ids` is empty.") }
        d.selectedLayerIDs = Set(ids)
        d.activeLayerID = ids.last
        AppActions.groupLayers()
        guard let g = d.activeLayerID, d.state.layer(g)?.isGroup == true, !ids.contains(g) else {
            throw MCPToolError("The layers could not be grouped (artboards can't go into a group).")
        }
        if let n = name { d.updateLayer(g) { $0.name = n }; d.commit("Rename Group") }
        return g
    }

    // MARK: - Layer style

    static let shadowFields: [String: [String: Any]] = [
        "color": S.color("Colour."), "opacity": S.number("Opacity in percent.", min: 0, max: 100), "blend_mode": S.string("Blend mode.", oneOf: blendModeNames),
        "angle": S.number("Light angle in degrees (120 = from the top left).", min: -360, max: 360),
        "distance": S.number("Offset in pixels.", min: 0, max: 30000), "spread": S.number("Spread in percent.", min: 0, max: 100),
        "size": S.number("Blur size in pixels.", min: 0, max: 250),
    ]
    static let glowFields: [String: [String: Any]] = [
        "color": S.color("Colour."), "opacity": S.number("Opacity in percent.", min: 0, max: 100), "blend_mode": S.string("Blend mode.", oneOf: blendModeNames),
        "size": S.number("Size in pixels.", min: 0, max: 250), "spread": S.number("Spread (outer) / choke (inner) in percent.", min: 0, max: 100),
        "source": S.string("Inner glow source.", oneOf: ["edge", "center"]),
    ]
    static let overlayFields: [String: [String: Any]] = [
        "color": S.color("Colour."), "opacity": S.number("Opacity in percent.", min: 0, max: 100), "blend_mode": S.string("Blend mode.", oneOf: blendModeNames),
    ]

    static func effect(_ d: String, _ fields: [String: [String: Any]]) -> [String: Any] {
        S.anyOf(d + " An object of settings turns it on, false turns it off.",
                [["type": "boolean"], S.object(fields.merging(["enabled": S.boolean("On or off. Default on.", default: true)]) { a, _ in a })])
    }

    static let effectSchemas: [String: [String: Any]] = [
        "drop_shadow": effect("Drop shadow.", shadowFields),
        "inner_shadow": effect("Inner shadow.", shadowFields),
        "outer_glow": effect("Outer glow.", glowFields),
        "inner_glow": effect("Inner glow.", glowFields),
        "color_overlay": effect("Colour overlay.", overlayFields),
        "stroke": effect("Stroke (outline).", overlayFields.merging([
            "size": S.number("Width in pixels.", min: 1, max: 250), "position": S.string("Where the stroke sits.", oneOf: ["outside", "inside", "center"])]) { a, _ in a }),
        "gradient_overlay": effect("Gradient overlay.", [
            "colors": S.array("Colour stops.", items: S.color("A stop colour."), minItems: 2, maxItems: 16),
            "angle": S.number("Angle in degrees.", min: -360, max: 360), "type": S.string("Gradient shape.", oneOf: GradientType.allCases.map(\.rawValue)),
            "reverse": S.boolean("Reverse the colours."), "opacity": S.number("Opacity in percent.", min: 0, max: 100),
            "blend_mode": S.string("Blend mode.", oneOf: blendModeNames)]),
        "bevel": effect("Bevel & emboss.", [
            "style": S.string("Bevel style.", oneOf: BevelStyle.allCases.map(\.rawValue)), "depth": S.number("Depth in percent.", min: 1, max: 1000),
            "size": S.number("Size in pixels.", min: 0, max: 250), "soften": S.number("Soften in pixels.", min: 0, max: 16),
            "angle": S.number("Light angle in degrees.", min: -360, max: 360), "altitude": S.number("Light altitude in degrees.", min: 0, max: 90),
            "direction": S.string("Up or down.", oneOf: ["up", "down"])]),
        "satin": effect("Satin.", overlayFields.merging([
            "angle": S.number("Angle in degrees.", min: -360, max: 360), "distance": S.number("Distance in pixels.", min: 1, max: 250),
            "size": S.number("Size in pixels.", min: 0, max: 250), "invert": S.boolean("Invert.")]) { a, _ in a }),
    ]

    static func applyEffect(_ fx: inout LayerEffects, _ key: String, _ value: Any) throws {
        let on: Bool
        var o: [String: Any] = [:]
        if MCPJSON.isBool(value) { on = (value as? NSNumber)?.boolValue ?? false } else { o = value as? [String: Any] ?? [:]; on = (o["enabled"] as? Bool) ?? true }
        func num(_ k: String) -> Double? { MCPJSON.double(o[k]) }
        func col() throws -> RGBA? { try o["color"].map { try MCPArgs.color($0, name: "\(key).color") } }
        func mode() throws -> BlendMode? { try (o["blend_mode"] as? String).map(MCPArgs.blendMode) }
        func shadow(_ s: inout ShadowEffect) throws {
            s.enabled = on
            if let c = try col() { s.color = c }
            if let v = num("opacity") { s.opacity = v / 100 }
            if let m = try mode() { s.blendMode = m }
            if let v = num("angle") { s.angle = v; s.useGlobalLight = false }
            if let v = num("distance") { s.distance = v }
            if let v = num("spread") { s.spread = v }
            if let v = num("size") { s.size = v }
        }
        func glow(_ g: inout GlowEffect) throws {
            g.enabled = on
            if let c = try col() { g.color = c }
            if let v = num("opacity") { g.opacity = v / 100 }
            if let m = try mode() { g.blendMode = m }
            if let v = num("size") { g.size = v }
            if let v = num("spread") { g.spread = v }
            if let s = o["source"] as? String, let src = GlowSource(rawValue: s) { g.source = src }
        }
        switch key {
        case "drop_shadow": try shadow(&fx.dropShadow)
        case "inner_shadow": try shadow(&fx.innerShadow)
        case "outer_glow": try glow(&fx.outerGlow)
        case "inner_glow": try glow(&fx.innerGlow)
        case "color_overlay":
            fx.colorOverlay.enabled = on
            if let c = try col() { fx.colorOverlay.color = c }
            if let v = num("opacity") { fx.colorOverlay.opacity = v / 100 }
            if let m = try mode() { fx.colorOverlay.blendMode = m }
        case "stroke":
            fx.stroke.enabled = on
            if let c = try col() { fx.stroke.paint = .color(c) }
            if let v = num("opacity") { fx.stroke.opacity = v / 100 }
            if let m = try mode() { fx.stroke.blendMode = m }
            if let v = num("size") { fx.stroke.size = v }
            if let p = o["position"] as? String, let pos = StrokePosition(rawValue: p) { fx.stroke.position = pos }
        case "gradient_overlay":
            fx.gradientOverlay.enabled = on
            if o["colors"] != nil { fx.gradientOverlay.fill = try gradient(o, name: key) }
            else {
                if let v = num("angle") { fx.gradientOverlay.fill.angle = v }
                if let t = o["type"] as? String, let gt = GradientType(rawValue: t) { fx.gradientOverlay.fill.type = gt }
                if let r = o["reverse"] as? Bool { fx.gradientOverlay.fill.reverse = r }
            }
            if let v = num("opacity") { fx.gradientOverlay.opacity = v / 100 }
            if let m = try mode() { fx.gradientOverlay.blendMode = m }
        case "bevel":
            fx.bevel.enabled = on
            if let s = o["style"] as? String, let st = BevelStyle(rawValue: s) { fx.bevel.style = st }
            if let v = num("depth") { fx.bevel.depth = v }
            if let v = num("size") { fx.bevel.size = v }
            if let v = num("soften") { fx.bevel.soften = v }
            if let v = num("angle") { fx.bevel.angle = v; fx.bevel.useGlobalLight = false }
            if let v = num("altitude") { fx.bevel.altitude = v; fx.bevel.useGlobalLight = false }
            if let dir = o["direction"] as? String { fx.bevel.directionUp = dir != "down" }
        case "satin":
            fx.satin.enabled = on
            if let c = try col() { fx.satin.color = c }
            if let v = num("opacity") { fx.satin.opacity = v / 100 }
            if let m = try mode() { fx.satin.blendMode = m }
            if let v = num("angle") { fx.satin.angle = v }
            if let v = num("distance") { fx.satin.distance = v }
            if let v = num("size") { fx.satin.size = v }
            if let i = o["invert"] as? Bool { fx.satin.invert = i }
        default: throw MCPToolError("Unknown effect \(key).")
        }
    }

    // MARK: - Text and shapes

    static let textShapeTools: [MCPTool] = [
        MCPTool("add_text", "Add Text Layer",
                "Add a live text layer (stays editable: see edit_text). Point text by default; give `box` for wrapping paragraph text.",
                schema: S.object(textProps.merging(["name": S.string("Layer name. Default: the start of the text."), "doc_id": docID]) { a, _ in a },
                                 required: ["text"])) { a in
            let d = try doc(a)
            let l = try addText(d, a)
            return resultLayer(d, l.id, "Added text layer “\(l.name)”.")
        },

        MCPTool("edit_text", "Edit Text",
                "Change a text layer's text or style. Changing `text` replaces all of it (and its per-character styling). `box: null` turns paragraph text into point text.",
                schema: S.object(textProps.merging(["layer_id": S.string("Id of the text layer.", minLength: 1), "doc_id": docID,
                                                    "box": S.anyOf("Paragraph text box {width, height}, or null for point text.",
                                                                   [["type": "null"], textProps["box"]!])]) { _, b in b },
                                 required: ["layer_id"])) { a in
            let d = try doc(a)
            let l = try layer(d, a, required: true)
            guard var t = l.text else { throw MCPToolError("“\(l.name)” is not a text layer (it is \(kind(l))).") }
            try applyText(&t, a)
            d.updateLayer(l.id) { $0.text = t }
            d.commit("Edit Type")
            return resultLayer(d, l.id, "Edited text layer “\(l.name)”.")
        },

        MCPTool("add_shape", "Add Shape",
                "Add a vector shape layer: rect, ellipse, polygon, star or line, in `bounds`, with a fill and an optional stroke.",
                schema: S.object(shapeProps.merging(["kind": S.string("Shape kind.", oneOf: shapeKinds), "name": S.string("Layer name."), "doc_id": docID]) { a, _ in a }
                                    .filter { $0.key != "shape" }, required: ["kind", "bounds"])) { a in
            let d = try doc(a)
            let l = try addShape(d, a, kindKey: "kind")
            return resultLayer(d, l.id, "Added \(a.string("kind") ?? "") shape “\(l.name)”.")
        },

        MCPTool("list_fonts", "List Fonts", "Installed fonts by family, with the PostScript names add_text accepts.",
                schema: S.object(["filter": S.string("Only families whose name contains this (case-insensitive)."),
                                  "limit": S.integer("Maximum number of families.", min: 1, max: 2000, default: 200)]), readOnly: true) { a in
            let f = a.string("filter")?.lowercased()
            let fams = NSFontManager.shared.availableFontFamilies.filter { f == nil || $0.lowercased().contains(f!) }
            let shown = fams.prefix(a.int("limit") ?? 200).map { fam -> [String: Any] in
                let members = (NSFontManager.shared.availableMembers(ofFontFamily: fam) ?? []).compactMap { m -> [String: Any]? in
                    guard let ps = m.first as? String else { return nil }
                    return ["name": ps, "style": (m.count > 1 ? m[1] as? String : nil) ?? ""]
                }
                return ["family": fam, "fonts": members]
            }
            return ok("\(fams.count) font famil\(fams.count == 1 ? "y" : "ies")\(fams.count > shown.count ? " (showing \(shown.count))" : "").", ["families": shown, "total": fams.count])
        },
    ]
}
