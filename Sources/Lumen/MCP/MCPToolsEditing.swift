import AppKit
import ImageCratCore

// MCP tools: filters, adjustments, selections, fill, crop, image / canvas size, undo / redo.

private typealias S = MCPSchema

extension MCPTools {
    // MARK: - Filters

    /// Filters that need on-canvas pins, a node graph, an extra image or their own dialog are not offered.
    static let hiddenFilters: Set<FilterKind> = [.filterGallery, .displace, .neuralFilter, .recipe, .liquify, .fieldBlur, .irisBlur, .pathBlur]
    static var mcpFilters: [FilterKind] { FilterKind.allCases.filter { !hiddenFilters.contains($0) } }

    static func filterKind(_ name: String) throws -> FilterKind {
        let n = norm(name)
        if let k = mcpFilters.first(where: { norm($0.rawValue) == n || norm($0.displayName) == n }) { return k }
        let near = mcpFilters.filter { norm($0.displayName).contains(n) || n.contains(norm($0.rawValue)) }.prefix(5).map(\.rawValue)
        throw MCPToolError("Unknown filter “\(name)”." + (near.isEmpty ? "" : " Did you mean \(near.joined(separator: ", "))?") + " Use list_filters for the names.")
    }

    static func filterParamJSON(_ p: FilterParam) -> [String: Any] {
        var d: [String: Any] = ["key": p.key, "label": p.label, "default": p.defaultValue]
        if !p.unit.isEmpty { d["unit"] = p.unit }
        switch p.kind {
        case .slider(let r): d["type"] = "number"; d["min"] = r.lowerBound; d["max"] = r.upperBound
        case .angle: d["type"] = "number"; d["min"] = -360; d["max"] = 360; d["unit"] = "°"
        case .toggle: d["type"] = "boolean"; d["default"] = p.defaultValue != 0
        case .choice(let o): d["type"] = "choice"; d["choices"] = o; d["default"] = o.indices.contains(Int(p.defaultValue)) ? o[Int(p.defaultValue)] : o.first ?? ""
        case .percentPoint: d["type"] = "number"; d["min"] = 0; d["max"] = 1; d["description"] = "position as a fraction of the canvas (0.5 = centre)"
        }
        return d
    }

    /// A filter with checked parameters ("Unknown parameter `radus` for Gaussian Blur. Parameters: radius (0–250, default 5).").
    static func filterInstance(_ k: FilterKind, _ params: [String: Any]) throws -> FilterInstance {
        var f = FilterInstance(kind: k)
        let help = k.params.isEmpty ? "it has no parameters" : "parameters: " + k.params.map { p -> String in
            switch p.kind {
            case .slider(let r): return "\(p.key) (\(MCPSchemaValidator.fmt(r.lowerBound))–\(MCPSchemaValidator.fmt(r.upperBound)), default \(MCPSchemaValidator.fmt(p.defaultValue)))"
            case .choice(let o): return "\(p.key) (one of \(o.joined(separator: " / ")))"
            case .toggle: return "\(p.key) (true / false)"
            default: return p.key
            }
        }.joined(separator: ", ")
        for (key, v) in params {
            if norm(key) == "opacity" {
                guard let o = MCPJSON.double(v), (0...100).contains(o) else { throw MCPToolError("`params.opacity` must be a number 0–100.") }
                f.opacity = o / 100; continue
            }
            if norm(key) == "blendmode" {
                guard let s = v as? String else { throw MCPToolError("`params.blend_mode` must be a blend mode name.") }
                f.blendMode = try MCPArgs.blendMode(s); continue
            }
            guard let p = k.params.first(where: { norm($0.key) == norm(key) || norm($0.label) == norm(key) }) else {
                throw MCPToolError("Unknown parameter `\(key)` for \(k.displayName): \(help).")
            }
            switch p.kind {
            case .slider(let r):
                guard let x = MCPJSON.double(v) else { throw MCPToolError("`\(p.key)` must be a number (\(help)).") }
                guard r.contains(x) else { throw MCPToolError("`\(p.key)` must be between \(MCPSchemaValidator.fmt(r.lowerBound)) and \(MCPSchemaValidator.fmt(r.upperBound)) (got \(MCPSchemaValidator.fmt(x))).") }
                f.values[p.key] = x
            case .angle:
                guard let x = MCPJSON.double(v), (-360...360).contains(x) else { throw MCPToolError("`\(p.key)` must be an angle in degrees (−360–360).") }
                f.values[p.key] = x
            case .percentPoint:
                guard let x = MCPJSON.double(v), (0...1).contains(x) else { throw MCPToolError("`\(p.key)` must be a fraction of the canvas, 0–1 (0.5 = centre).") }
                f.values[p.key] = x
            case .toggle:
                if MCPJSON.isBool(v) { f.values[p.key] = ((v as? NSNumber)?.boolValue ?? false) ? 1 : 0 }
                else if let x = MCPJSON.double(v), x == 0 || x == 1 { f.values[p.key] = x }
                else { throw MCPToolError("`\(p.key)` must be true or false.") }
            case .choice(let opts):
                if let s = v as? String, let i = opts.firstIndex(where: { norm($0) == norm(s) }) { f.values[p.key] = Double(i) }
                else if let x = MCPJSON.double(v), opts.indices.contains(Int(x)) { f.values[p.key] = x.rounded() }
                else { throw MCPToolError("`\(p.key)` must be one of: \(opts.joined(separator: ", ")).") }
            }
        }
        return f
    }

    // MARK: - Adjustments

    struct AdjParam {
        let key: String
        let schema: [String: Any]
        let set: (inout AdjustmentSettings, Any) throws -> Void
    }

    static func adjNum(_ key: String, _ d: String, _ r: ClosedRange<Double>, _ def: Double, _ kp: WritableKeyPath<AdjustmentSettings, Double>) -> AdjParam {
        AdjParam(key: key, schema: S.number(d, min: r.lowerBound, max: r.upperBound, default: def)) { s, v in s[keyPath: kp] = MCPJSON.double(v) ?? def }
    }

    static func adjBool(_ key: String, _ d: String, _ kp: WritableKeyPath<AdjustmentSettings, Bool>) -> AdjParam {
        AdjParam(key: key, schema: S.boolean(d)) { s, v in s[keyPath: kp] = (v as? NSNumber)?.boolValue ?? false }
    }

    static func adjLevels(_ key: String, _ d: String, _ r: ClosedRange<Double>, _ def: Double, _ kp: WritableKeyPath<LevelsChannel, Double>) -> AdjParam {
        AdjParam(key: key, schema: S.number(d, min: r.lowerBound, max: r.upperBound, default: def)) { s, v in s.levels[0][keyPath: kp] = MCPJSON.double(v) ?? def }
    }

    static func adjTriple(_ key: String, _ d: String, _ kp: WritableKeyPath<AdjustmentSettings, ToneTriple>) -> AdjParam {
        AdjParam(key: key, schema: S.array(d + " [cyan–red, magenta–green, yellow–blue], each −100–100.",
                                           items: ["type": "number", "minimum": -100, "maximum": 100], minItems: 3, maxItems: 3)) { s, v in
            let n = ((v as? [Any]) ?? []).compactMap { MCPJSON.double($0) }
            s[keyPath: kp] = ToneTriple(cyanRed: n[0], magentaGreen: n[1], yellowBlue: n[2])
        }
    }

    static func adjMix(_ key: String, _ kp: WritableKeyPath<AdjustmentSettings, [Double]>) -> AdjParam {
        AdjParam(key: key, schema: S.array("Output \(key) channel: [red %, green %, blue %, constant %], each −200–200.",
                                           items: ["type": "number", "minimum": -200, "maximum": 200], minItems: 4, maxItems: 4)) { s, v in
            s[keyPath: kp] = ((v as? [Any]) ?? []).compactMap { MCPJSON.double($0) }
        }
    }

    static let selectiveRanges = ["reds", "yellows", "greens", "cyans", "blues", "magentas", "whites", "neutrals", "blacks"]

    /// The settings MCP exposes per adjustment kind (the AdjustmentSettings fields behind them).
    static func adjParams(_ k: AdjustmentKind) -> [AdjParam] {
        switch k {
        case .brightnessContrast:
            return [adjNum("brightness", "Brightness.", -150...150, 0, \.brightness), adjNum("contrast", "Contrast.", -50...100, 0, \.contrast)]
        case .levels:
            return [adjLevels("input_black", "Input black point.", 0...253, 0, \.inBlack), adjLevels("input_white", "Input white point.", 2...255, 255, \.inWhite),
                    adjLevels("gamma", "Midtone gamma.", 0.1...9.99, 1, \.gamma), adjLevels("output_black", "Output black.", 0...255, 0, \.outBlack),
                    adjLevels("output_white", "Output white.", 0...255, 255, \.outWhite)]
        case .curves:
            return [AdjParam(key: "points", schema: S.array("Curve points [[input, output], …] in 0–255, e.g. [[0,0],[64,48],[192,210],[255,255]].",
                                                            items: S.array("[input, output].", items: ["type": "number", "minimum": 0, "maximum": 255], minItems: 2, maxItems: 2),
                                                            minItems: 2, maxItems: 16)) { s, v in
                let pts = ((v as? [Any]) ?? []).compactMap { $0 as? [Any] }.map { p in
                    CGPoint(x: (MCPJSON.double(p[0]) ?? 0) / 255, y: (MCPJSON.double(p[1]) ?? 0) / 255)
                }.sorted { $0.x < $1.x }
                s.curves[0] = CurvePoints(points: pts)
            }]
        case .exposure:
            return [adjNum("exposure", "Exposure in stops.", -20...20, 0, \.exposure), adjNum("offset", "Offset.", -0.5...0.5, 0, \.offset),
                    adjNum("gamma", "Gamma correction.", 0.01...9.99, 1, \.gamma)]
        case .vibrance:
            return [adjNum("vibrance", "Vibrance.", -100...100, 0, \.vibrance), adjNum("saturation", "Saturation.", -100...100, 0, \.saturation)]
        case .hueSaturation:
            return [adjNum("hue", "Hue shift in degrees.", -180...180, 0, \.hue), adjNum("saturation", "Saturation.", -100...100, 0, \.hsSaturation),
                    adjNum("lightness", "Lightness.", -100...100, 0, \.lightness), adjBool("colorize", "Colorize (tint everything with the hue).", \.colorize)]
        case .colorBalance:
            return [adjTriple("shadows", "Shadows balance", \.shadows), adjTriple("midtones", "Midtones balance", \.midtones),
                    adjTriple("highlights", "Highlights balance", \.highlights), adjBool("preserve_luminosity", "Preserve luminosity.", \.preserveLuminosity)]
        case .blackWhite:
            return [adjNum("reds", "Reds %.", -200...300, 40, \.bwReds), adjNum("yellows", "Yellows %.", -200...300, 60, \.bwYellows),
                    adjNum("greens", "Greens %.", -200...300, 40, \.bwGreens), adjNum("cyans", "Cyans %.", -200...300, 60, \.bwCyans),
                    adjNum("blues", "Blues %.", -200...300, 20, \.bwBlues), adjNum("magentas", "Magentas %.", -200...300, 80, \.bwMagentas),
                    adjBool("tint", "Tint the result.", \.bwTint),
                    AdjParam(key: "tint_color", schema: S.color("Tint colour.")) { s, v in s.bwTintColor = try MCPArgs.color(v, name: "tint_color") }]
        case .photoFilter:
            return [AdjParam(key: "color", schema: S.color("Filter colour.")) { s, v in s.filterColor = try MCPArgs.color(v, name: "color") },
                    adjNum("density", "Density %.", 1...100, 25, \.density), adjBool("preserve_luminosity", "Preserve luminosity.", \.preserveLuminosity)]
        case .channelMixer:
            return [adjMix("red", \.mixRed), adjMix("green", \.mixGreen), adjMix("blue", \.mixBlue), adjBool("monochrome", "Monochrome output.", \.monochrome)]
        case .posterize: return [adjNum("levels", "Levels per channel.", 2...255, 4, \.posterizeLevels)]
        case .threshold: return [adjNum("level", "Threshold level.", 1...255, 128, \.thresholdLevel)]
        case .gradientMap:
            return [AdjParam(key: "colors", schema: S.array("Colours from shadows to highlights.", items: S.color("A colour."), minItems: 2, maxItems: 16)) { s, v in
                        let cols = try ((v as? [Any]) ?? []).enumerated().map { try MCPArgs.color($0.element, name: "colors[\($0.offset)]") }
                        s.gradient = ColorGradient(name: "MCP", stops: cols.enumerated().map { GradientStop(location: Double($0.offset) / Double(max(1, cols.count - 1)), color: $0.element) })
                    }, adjBool("reverse", "Reverse the gradient.", \.gradientReverse)]
        case .selectiveColor:
            return selectiveRanges.enumerated().map { i, r in
                AdjParam(key: r, schema: S.array("\(r.capitalized): [cyan, magenta, yellow, black] in %, each −100–100.",
                                                 items: ["type": "number", "minimum": -100, "maximum": 100], minItems: 4, maxItems: 4)) { s, v in
                    let n = ((v as? [Any]) ?? []).compactMap { MCPJSON.double($0) }
                    s.selective[i] = SelectiveColorEntry(cyan: n[0], magenta: n[1], yellow: n[2], black: n[3])
                }
            } + [adjBool("absolute", "Absolute (instead of relative) method.", \.selectiveAbsolute)]
        case .shadowsHighlights:
            return [adjNum("shadows", "Shadows amount %.", 0...100, 35, \.shAmountShadows), adjNum("highlights", "Highlights amount %.", 0...100, 0, \.shAmountHighlights),
                    adjNum("radius", "Radius in pixels.", 0...500, 30, \.shRadius)]
        case .colorLookup:
            return [AdjParam(key: "look", schema: S.string("The look.", oneOf: AdjustmentSettings.lookNames)) { s, v in s.lookName = v as? String ?? s.lookName }]
        case .colorWB, .clarity, .dehaze, .grain, .light:
            return EditsAdjustments.params(k).map { p in
                AdjParam(key: p.key, schema: S.number(p.label + ".", min: p.range.lowerBound, max: p.range.upperBound, default: p.def)) { s, v in
                    s.params[p.key] = MCPJSON.double(v) ?? p.def
                }
            }
        default: return []
        }
    }

    /// Kinds MCP can apply (Replace Color / Match Color / HDR Toning need their dialogs).
    static let mcpAdjustments: [AdjustmentKind] = AdjustmentKind.allCases.filter { ![.replaceColor, .matchColor, .hdrToning].contains($0) }

    static func adjustmentKind(_ name: String) throws -> AdjustmentKind {
        let n = norm(name)
        let aliases: [String: AdjustmentKind] = ["blackandwhite": .blackWhite, "bw": .blackWhite, "huesat": .hueSaturation, "whitebalance": .colorWB,
                                                 "color": .colorWB, "brightness": .brightnessContrast, "lut": .colorLookup, "shadowhighlight": .shadowsHighlights]
        if let k = mcpAdjustments.first(where: { norm($0.rawValue) == n || norm($0.displayName) == n }) ?? aliases[n] { return k }
        throw MCPToolError("Unknown adjustment “\(name)”. Use one of: \(mcpAdjustments.map(\.rawValue).joined(separator: ", ")) (see list_adjustments).")
    }

    static func adjustmentSettings(_ k: AdjustmentKind, _ params: [String: Any]) throws -> AdjustmentSettings {
        var s = AdjustmentSettings(kind: k)
        let defs = adjParams(k)
        for (key, v) in params.sorted(by: { $0.key < $1.key }) {
            guard let p = defs.first(where: { norm($0.key) == norm(key) }) else {
                throw MCPToolError("Unknown parameter `\(key)` for \(k.displayName): " + (defs.isEmpty ? "it has no parameters." : "parameters are \(defs.map(\.key).joined(separator: ", "))."))
            }
            let problems = MCPSchemaValidator.validate(v, p.schema, path: "params.\(p.key)")
            if !problems.isEmpty { throw MCPToolError(problems.joined(separator: " ")) }
            try p.set(&s, v)
        }
        return s
    }

    static func addAdjustmentLayer(_ d: Document, kind: String, params: [String: Any], name: String?) throws -> UUID {
        let k = try adjustmentKind(kind)
        guard AdjustmentKind.layerKinds.contains(k) else { throw MCPToolError("\(k.displayName) can't be an adjustment layer: use apply_adjustment with as_layer: false.") }
        let s = try adjustmentSettings(k, params)
        var l = Layer(name: name ?? d.nextLayerName(k.displayName), content: .adjustment(s))
        if let sel = d.state.selection { l.mask = LayerMask(buffer: sel.copy(), origin: .zero, outsideValue: 0) }
        else { l.mask = LayerMask.reveal(width: d.state.width, height: d.state.height) }
        d.addLayer(l, commitName: "New \(k.displayName) Layer")
        return l.id
    }

    // MARK: - Selection helpers

    static func combineMode(_ a: MCPArgs) -> SelectionCombine { a.string("combine").flatMap(SelectionCombine.init(rawValue:)) ?? .new }

    static func selectionJSON(_ d: Document) -> [String: Any] {
        guard let b = d.state.selectionBounds else { return ["has_selection": false] }
        return ["has_selection": true, "bounds": ["x": b.x, "y": b.y, "width": b.width, "height": b.height]]
    }

    static func rectMask(_ d: Document, _ r: CGRect, ellipse: Bool = false) -> PixelBuffer {
        let path = ellipse ? CGPath(ellipseIn: r, transform: nil) : CGPath(rect: r, transform: nil)
        return SelectionOps.mask(fromPath: path, width: d.state.width, height: d.state.height, antialias: ellipse)
    }

    /// The layer a pixel edit goes to: text and shapes are refused (say how to get pixels) rather than rasterized silently.
    static func pixelLayer(_ d: Document, _ l: Layer, _ what: String) throws {
        guard l.isRaster else {
            throw MCPToolError("\(what) changes pixels, but “\(l.name)” is a \(kind(l).replacingOccurrences(of: "_", with: " ")) layer. "
                               + "Target a pixel layer (add_layer kind: pixel)" + (l.isText || l.shape != nil ? ", or rasterize this one first with run_script." : "."))
        }
    }

    // MARK: - Tools

    static let editingTools: [MCPTool] = [
        MCPTool("list_filters", "List Filters", "The filters apply_filter accepts, with each parameter's key, range and default.",
                schema: S.object(["category": S.string("Only this category.", oneOf: FilterCategory.allCases.map(\.rawValue))]), readOnly: true) { a in
            let c = a.string("category")
            let list = mcpFilters.filter { c == nil || $0.category.rawValue == c }.map { k -> [String: Any] in
                ["name": k.rawValue, "display_name": k.displayName, "category": k.category.rawValue, "params": k.params.map(filterParamJSON)]
            }
            return ok("\(list.count) filters.", ["filters": list])
        },

        MCPTool("apply_filter", "Apply Filter",
                "Apply a filter (see list_filters) to a pixel layer — inside the selection if there is one. smart: true converts the layer "
                + "to a smart object first and adds an editable smart filter (smart objects always get smart filters). "
                + "Example: {\"name\": \"gaussianBlur\", \"params\": {\"radius\": 8}}.",
                schema: S.object(["name": S.string("Filter name, e.g. \"gaussianBlur\" or \"Gaussian Blur\".", minLength: 1),
                                  "params": S.map("Parameter values by key (see list_filters); missing ones use the defaults. Also `opacity` (0–100) and `blend_mode`."),
                                  "layer_id": layerID, "smart": S.boolean("Apply as an editable smart filter.", default: false), "doc_id": docID],
                                 required: ["name"])) { a in
            let d = try doc(a)
            let k = try filterKind(a.string("name")!)
            let f = try filterInstance(k, a.object("params") ?? [:])
            var l = try layer(d, a)
            if l.isGroup || l.isAdjustment || l.fill != nil {
                throw MCPToolError("Filters work on pixel layers and smart objects; “\(l.name)” is a \(kind(l).replacingOccurrences(of: "_", with: " ")) layer.")
            }
            select(d, l.id)
            if a.bool("smart") == true && !l.isSmartObject {
                AppActions.convertToSmartObject()
                guard let id = d.activeLayerID, let so = d.state.layer(id), so.isSmartObject else { throw MCPToolError("“\(l.name)” could not be converted to a smart object.") }
                l = so
            }
            if !l.isRaster && !l.isSmartObject {
                throw MCPToolError("“\(l.name)” is a \(kind(l)) layer: pass smart: true to filter it as a smart object (keeps it editable).")
            }
            if l.isRaster { _ = d.beginPixelEdit(layerID: l.id, target: .content, coverCanvas: true) }   // blurs and glows may spread past the pixels
            let before = d.currentHistoryEntryID
            AppActions.applyFilter(f)
            if d.currentHistoryEntryID == before { d.revertUncommitted(); throw MCPToolError("\(k.displayName) could not be applied to “\(l.name)”.") }
            return resultLayer(d, l.id, "Applied \(k.displayName) to “\(l.name)”\(l.isSmartObject ? " as a smart filter" : "").")
        },

        MCPTool("list_adjustments", "List Adjustments", "The adjustments apply_adjustment accepts, with their parameters.",
                schema: S.object([:]), readOnly: true) { _ in
            let list = mcpAdjustments.map { k -> [String: Any] in
                ["name": k.rawValue, "display_name": k.displayName, "as_layer": AdjustmentKind.layerKinds.contains(k),
                 "params": adjParams(k).map { p -> [String: Any] in var s = p.schema; s["key"] = p.key; return s }]
            }
            return ok("\(list.count) adjustments.", ["adjustments": list])
        },

        MCPTool("apply_adjustment", "Apply Adjustment",
                "Apply an adjustment (see list_adjustments). By default it is an adjustment layer above the target layer (non-destructive, "
                + "limited to the selection if there is one); as_layer: false changes the pixel layer itself. "
                + "Example: {\"kind\": \"hueSaturation\", \"params\": {\"hue\": 30, \"saturation\": 20}}.",
                schema: S.object(["kind": S.string("Adjustment name, e.g. \"brightnessContrast\", \"Hue/Saturation\", \"curves\".", minLength: 1),
                                  "params": S.map("Settings by key (see list_adjustments). Missing ones keep their defaults."),
                                  "as_layer": S.boolean("Add an adjustment layer (true) or change the pixels (false).", default: true),
                                  "layer_id": layerID, "name": S.string("Adjustment layer name."), "doc_id": docID], required: ["kind"])) { a in
            let d = try doc(a)
            let l = try layer(d, a)
            if a.bool("as_layer") ?? true {
                select(d, l.id)   // the new layer goes right above the target
                let id = try addAdjustmentLayer(d, kind: a.string("kind")!, params: a.object("params") ?? [:], name: a.string("name"))
                return resultLayer(d, id, "Added a \(d.state.layer(id)?.name ?? "") adjustment layer above “\(l.name)”.")
            }
            let k = try adjustmentKind(a.string("kind")!)
            let s = try adjustmentSettings(k, a.object("params") ?? [:])
            try pixelLayer(d, l, k.displayName)
            select(d, l.id)
            AppActions.applyAdjustment(s)
            return resultLayer(d, l.id, "Applied \(k.displayName) to “\(l.name)”.")
        },

        MCPTool("make_selection", "Make Selection",
                "Select pixels: rect / ellipse (`rect`), all, none, invert, subject (on-device subject detection), color_range (`color`, `fuzziness`), "
                + "or layer (the pixels of `layer_id`). `combine` adds to / subtracts from / intersects the current selection; `feather` softens the edge.",
                schema: S.object(["mode": S.string("How to select.", oneOf: ["rect", "ellipse", "all", "none", "invert", "subject", "color_range", "layer"]),
                                  "rect": S.rect("rect / ellipse: the area."),
                                  "color": S.color("color_range: the colour to select."),
                                  "fuzziness": S.number("color_range: tolerance.", min: 0, max: 200, default: 40),
                                  "layer_id": S.string("layer: the layer whose pixels to select."),
                                  "combine": S.string("How it combines with the current selection.", oneOf: SelectionCombine.allCases.map(\.rawValue), default: "new"),
                                  "feather": S.number("Feather radius in pixels.", min: 0, max: 250),
                                  "doc_id": docID], required: ["mode"])) { a in
            let d = try doc(a)
            let mode = a.string("mode")!
            let comb = combineMode(a)
            func set(_ m: PixelBuffer, _ name: String) { d.setSelection(SelectionOps.combine(d.state.selection, m, mode: comb), commitName: name) }
            switch mode {
            case "rect", "ellipse":
                guard let r = a.rect("rect"), r.width >= 1, r.height >= 1 else { throw MCPToolError("\(mode) needs `rect` {x, y, width, height} at least 1 × 1.") }
                set(rectMask(d, r, ellipse: mode == "ellipse"), mode == "rect" ? "Rectangular Marquee" : "Elliptical Marquee")
            case "all": d.setSelection(SelectionOps.all(width: d.state.width, height: d.state.height), commitName: "Select All")
            case "none":
                if d.state.selection != nil { AppActions.lastSelection = d.state.selection; d.setSelection(nil, commitName: "Deselect") }
            case "invert":
                guard let s = d.state.selection else { throw MCPToolError("There is no selection to invert.") }
                d.setSelection(SelectionOps.invert(s), commitName: "Inverse")
            case "subject":
                guard let m = AppActions.subjectMask() else { throw MCPToolError("No subject was found. Try a photo with a clear foreground subject.") }
                set(m, "Select Subject")
            case "color_range":
                guard let c = try a.color("color") else { throw MCPToolError("color_range needs `color`.") }
                guard let src = AppActions.sampleSource(allLayers: true) else { throw MCPToolError("The image could not be sampled.") }
                set(SelectionOps.colorRange(src: src, color: c, fuzziness: a.double("fuzziness") ?? 40), "Color Range")
            case "layer":
                let l = try layer(d, a)
                AppActions.selectLayerPixels(l.id, mode: comb)
            default: throw MCPToolError("Unknown mode \(mode).")
            }
            if let f = a.double("feather"), f > 0, let s = d.state.selection {
                d.setSelection(SelectionOps.feather(s, radius: f, direction: app.featherDirection), commitName: "Feather")
            }
            let info = selectionJSON(d)
            return ok(d.state.selection == nil ? "Nothing is selected." : "Selection updated.", info)
        },

        MCPTool("fill", "Fill",
                "Fill a pixel layer with a colour: inside `selection` if given (a rect, just for this fill), else inside the current selection, else the whole layer.",
                schema: S.object(["color": S.color("Fill colour."), "selection": S.rect("Fill only this rectangle."),
                                  "opacity": S.number("Opacity in percent.", min: 0, max: 100, default: 100),
                                  "blend_mode": S.string("Blend mode.", oneOf: blendModeNames),
                                  "preserve_transparency": S.boolean("Only fill where the layer already has pixels.", default: false),
                                  "layer_id": layerID, "doc_id": docID], required: ["color"])) { a in
            let d = try doc(a)
            let l = try layer(d, a)
            try pixelLayer(d, l, "Fill")
            guard !l.locks.pixelsLocked else { throw MCPToolError("“\(l.name)” is locked.") }
            let c = try a.color("color")!
            let mode = try a.blendMode("blend_mode") ?? .normal
            select(d, l.id)
            let prev = d.state.selection
            if let r = a.rect("selection") { d.state.selection = rectMask(d, r) }
            AppActions.fill(.color, color: c, opacity: (a.double("opacity") ?? 100) / 100, mode: mode,
                            preserveTransparency: a.bool("preserve_transparency") ?? false, commit: false)
            if a.has("selection") { d.state.selection = prev }
            d.commit("Fill")
            return resultLayer(d, l.id, "Filled “\(l.name)” with #\(c.hex).")
        },

        MCPTool("crop", "Crop", "Crop the canvas to a rectangle (document pixels).",
                schema: S.object(["rect": S.rect("The area to keep."),
                                  "delete_pixels": S.boolean("Delete the pixels outside (false keeps them, hidden beyond the canvas).", default: true),
                                  "doc_id": docID], required: ["rect"]), destructive: true) { a in
            let d = try doc(a)
            let r = a.rect("rect")!
            let ir = IRect(x: Int(r.minX.rounded()), y: Int(r.minY.rounded()), width: Int(r.width.rounded()), height: Int(r.height.rounded()))
            guard ir.width >= 1, ir.height >= 1 else { throw MCPToolError("The crop rectangle must be at least 1 × 1 pixel.") }
            AppActions.crop(to: ir, deletePixels: a.bool("delete_pixels") ?? true)
            return ok("Cropped to \(d.state.width) × \(d.state.height).", docJSON(d))
        },

        MCPTool("resize_image", "Resize Image",
                "Resample the whole image (Image Size). Give width and/or height; with only one the aspect ratio is kept.",
                schema: S.object(["width": S.integer("New width in pixels.", min: 1, max: maxCanvasDimension),
                                  "height": S.integer("New height in pixels.", min: 1, max: maxCanvasDimension),
                                  "resolution": S.number("New resolution (ppi). Default unchanged.", min: 1, max: 9999),
                                  "scale_styles": S.boolean("Scale layer effects too.", default: true), "doc_id": docID])) { a in
            let d = try doc(a)
            var w = a.int("width") ?? 0, h = a.int("height") ?? 0
            guard w > 0 || h > 0 else { throw MCPToolError("Give `width` and/or `height`.") }
            if w <= 0 { w = max(1, Int((Double(h) * Double(d.state.width) / Double(d.state.height)).rounded())) }
            if h <= 0 { h = max(1, Int((Double(w) * Double(d.state.height) / Double(d.state.width)).rounded())) }
            AppActions.imageSize(width: w, height: h, resolution: validResolution(a.double("resolution") ?? d.state.resolution), scaleStyles: a.bool("scale_styles") ?? true)
            return ok("Resized to \(d.state.width) × \(d.state.height).", docJSON(d))
        },

        MCPTool("resize_canvas", "Resize Canvas", "Change the canvas size without scaling the image (Canvas Size).",
                schema: S.object(["width": S.integer("New width in pixels.", min: 1, max: maxCanvasDimension),
                                  "height": S.integer("New height in pixels.", min: 1, max: maxCanvasDimension),
                                  "anchor": S.string("Where the existing image stays.", oneOf: ["center", "top-left", "top", "top-right", "left", "right", "bottom-left", "bottom", "bottom-right"], default: "center"),
                                  "color": S.color("Colour of new background areas, or \"transparent\". Default: the background colour."),
                                  "doc_id": docID], required: ["width", "height"])) { a in
            let d = try doc(a)
            let anchor = a.string("anchor") ?? "center"
            let ax = anchor.contains("left") ? 0 : (anchor.contains("right") ? 2 : 1), ay = anchor.hasPrefix("top") ? 0 : (anchor.hasPrefix("bottom") ? 2 : 1)
            let ext: RGBA?
            if let s = a.string("color"), s.lowercased() == "transparent" { ext = nil } else { ext = try a.color("color") ?? app.background }
            AppActions.canvasSize(width: a.int("width")!, height: a.int("height")!, anchorX: ax, anchorY: ay, extension: ext)
            return ok("Canvas is now \(d.state.width) × \(d.state.height).", docJSON(d))
        },

        MCPTool("undo", "Undo", "Undo the last step(s) of a document (each MCP call is one step).",
                schema: S.object(["steps": S.integer("How many steps.", min: 1, max: 100, default: 1), "doc_id": docID]), undoStep: false) { a in
            let d = try doc(a)
            var n = 0
            for _ in 0..<(a.int("steps") ?? 1) where d.canUndo { d.undo(); n += 1 }
            guard n > 0 else { throw MCPToolError("Nothing to undo in “\(d.name)”.") }
            return ok("Undid \(n) step\(n == 1 ? "" : "s"); now at “\(d.history[d.historyIndex].name)”.", ["current_step": d.history[d.historyIndex].name, "can_undo": d.canUndo, "can_redo": d.canRedo])
        },

        MCPTool("redo", "Redo", "Redo undone step(s).",
                schema: S.object(["steps": S.integer("How many steps.", min: 1, max: 100, default: 1), "doc_id": docID]), undoStep: false) { a in
            let d = try doc(a)
            var n = 0
            for _ in 0..<(a.int("steps") ?? 1) where d.canRedo { d.redo(); n += 1 }
            guard n > 0 else { throw MCPToolError("Nothing to redo in “\(d.name)”.") }
            return ok("Redid \(n) step\(n == 1 ? "" : "s"); now at “\(d.history[d.historyIndex].name)”.", ["current_step": d.history[d.historyIndex].name, "can_undo": d.canUndo, "can_redo": d.canRedo])
        },
    ]
}
