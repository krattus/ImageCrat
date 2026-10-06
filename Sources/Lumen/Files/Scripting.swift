import AppKit
import JavaScriptCore
import CoreImage
import UniformTypeIdentifiers
import ImageCratCore

enum ScriptError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

// MARK: - Engine

/// One JavaScriptCore context with the ImageCrat document API (`app`, `Document`, `Layer`, `alert`, `prompt`, `console`).
/// Scripts, the console and every plugin each get their own engine.
final class ScriptEngine {
    let context: JSContext
    let name: String
    var interactive: Bool
    /// Output sink (console panel / stdout).
    var log: ((String) -> Void)?
    private(set) var lastError: String?

    init(name: String, interactive: Bool = true) {
        self.name = name
        self.interactive = interactive
        context = JSContext()!
        context.name = "\(Brand.name) – \(name)"
        context.exceptionHandler = { [weak self] _, exc in
            let msg = exc?.toString() ?? "error"
            let line = exc?.objectForKeyedSubscript("line")?.toString() ?? "?"
            self?.lastError = "\(msg) (line \(line))"
            self?.log?("⚠︎ \(msg) (line \(line))")
        }
        let logFn: @convention(block) () -> Void = { [weak self] in
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            self?.log?(args.map { ScriptEngine.describe($0) }.joined(separator: " "))
        }
        let console = JSValue(newObjectIn: context)!
        for k in ["log", "info", "warn", "error"] { console.setObject(logFn, forKeyedSubscript: k as NSString) }
        context.setObject(console, forKeyedSubscript: "console" as NSString)
        let call: @convention(block) (String, JSValue) -> JSValue = { [weak self] method, args in
            let ctx = JSContext.current()!
            let list = (args.toArray() ?? []).map { $0 is NSNull ? NSNull() : $0 }
            do {
                let r = try ScriptAPI.dispatch(method, list, engine: self)
                return JSValue(object: r ?? NSNull(), in: ctx)
            } catch {
                ctx.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: ctx)
                return JSValue(undefinedIn: ctx)
            }
        }
        context.setObject(call, forKeyedSubscript: "__lumenCall" as NSString)
        context.evaluateScript(ScriptAPI.prelude, withSourceURL: URL(string: "imagecrat://prelude.js"))
    }

    static func describe(_ v: JSValue) -> String {
        if v.isString { return v.toString() }
        if v.isObject, !v.isArray, let json = v.context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [v]), json.isString {
            let s = json.toString() ?? ""
            if s != "{}" { return s }
        }
        if v.isArray, let json = v.context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [v]), json.isString { return json.toString() }
        return v.toString()
    }

    /// Runs source; returns false when it threw.
    @discardableResult
    func evaluate(_ source: String, file: String? = nil) -> Bool {
        lastError = nil
        let r = context.evaluateScript(source, withSourceURL: file.map { URL(fileURLWithPath: $0) })
        if lastError == nil, let r, !r.isUndefined, file == nil { log?("→ " + ScriptEngine.describe(r)) }
        return lastError == nil
    }

    /// Calls a global function (plugins' `run()` and panel `invoke`).
    func callFunction(_ name: String, _ args: [Any] = []) -> Any? {
        guard let f = context.objectForKeyedSubscript(name), !f.isUndefined else { return nil }
        lastError = nil
        let r = f.call(withArguments: args)
        return r?.toObject()
    }
}

// MARK: - API

/// Native side of the script / plugin API. Documents and layers are referred to by UUID string
/// ("active" or null = the active one). Results are JSON-compatible values.
enum ScriptAPI {
    static var app: AppModel { AppModel.shared }
    /// Told about every file a script writes (the MCP server's run_script reports them, see MCPToolsMore.swift).
    static var didWriteFile: ((URL) -> Void)?

    // MARK: Lookup

    static func doc(_ v: Any?) throws -> Document {
        if let s = v as? String, s != "active", let d = app.documents.first(where: { $0.id.uuidString == s }) { return d }
        if let d = app.activeDocument, v == nil || v is NSNull || (v as? String) == "active" { return d }
        throw ScriptError.message(app.documents.isEmpty ? "There is no open document." : "Document not found.")
    }

    static func layerID(_ d: Document, _ v: Any?) throws -> UUID {
        if let s = v as? String, s != "active", let id = UUID(uuidString: s), d.state.layer(id) != nil { return id }
        if let a = d.activeLayerID, v == nil || v is NSNull || (v as? String) == "active" { return a }
        throw ScriptError.message("Layer not found.")
    }

    /// Runs `body` with `d` active (and `layer` selected), restoring the previous active document.
    static func on<T>(_ d: Document, layer: UUID? = nil, _ body: () throws -> T) rethrows -> T {
        let prev = app.activeDocumentID
        app.activeDocumentID = d.id
        if let l = layer, d.activeLayerID != l { d.activeLayerID = l; d.selectedLayerIDs = [l]; d.editTarget = .content }
        defer { if let p = prev, app.documents.contains(where: { $0.id == p }) { app.activeDocumentID = p } }
        return try body()
    }

    static func num(_ v: Any?, _ def: Double = 0) -> Double {
        // JavaScript readily produces NaN / Infinity (0/0, 1/0, parseFloat('x')), and the bridge converts many
        // arguments with Int(…), which traps on them: a script bug must not take the app down.
        func safe(_ d: Double) -> Double { d.isFinite ? min(max(d, -1e9), 1e9) : def }
        if let n = v as? NSNumber { return safe(n.doubleValue) }
        if let s = v as? String, let d = Double(s) { return safe(d) }
        return def
    }
    static func str(_ v: Any?) -> String? { v as? String ?? (v as? NSNumber)?.stringValue }
    static func dict(_ v: Any?) -> [String: Any] { v as? [String: Any] ?? [:] }

    static func color(_ v: Any?, _ def: RGBA = .black) -> RGBA {
        if let s = v as? String { return RGBA(hex: s) ?? def }
        if let a = v as? [Any], a.count >= 3 {
            let k = a.prefix(3).contains { num($0) > 1 } ? 255.0 : 1.0
            return RGBA(r: num(a[0]) / k, g: num(a[1]) / k, b: num(a[2]) / k, a: a.count > 3 ? num(a[3], 1) : 1)
        }
        if let d = v as? [String: Any] {
            let k = [d["r"], d["g"], d["b"]].contains { num($0) > 1 } ? 255.0 : 1.0
            return RGBA(r: num(d["r"]) / k, g: num(d["g"]) / k, b: num(d["b"]) / k, a: num(d["a"], 1))
        }
        return def
    }
    static func hex(_ c: RGBA) -> String { String(format: "#%02X%02X%02X", Int(c.r * 255), Int(c.g * 255), Int(c.b * 255)) }

    // MARK: Info

    static func kind(_ l: Layer) -> String {
        switch l.content {
        case .raster: return "pixel"
        case .text: return "text"
        case .shape: return "shape"
        case .smartObject: return "smartObject"
        case .adjustment: return "adjustment"
        case .fill: return "fill"
        case .group: return l.isArtboard ? "artboard" : "group"
        }
    }

    static func layerInfo(_ d: Document, _ l: Layer) -> [String: Any] {
        var i: [String: Any] = ["id": l.id.uuidString, "name": l.name, "kind": kind(l), "visible": l.isVisible, "opacity": l.opacity * 100,
                                "fillOpacity": l.fillOpacity * 100, "blendMode": l.blendMode.rawValue, "clipped": l.isClipped,
                                "isGroup": l.isGroup, "docId": d.id.uuidString, "active": d.activeLayerID == l.id]
        if let b = Compositor.shared.contentBounds(l, state: d.state) {
            i["bounds"] = ["x": Double(b.minX), "y": Double(b.minY), "width": Double(b.width), "height": Double(b.height)]
        }
        if let t = l.text { i["text"] = t.text; i["font"] = t.fontName; i["size"] = t.fontSize; i["color"] = hex(t.color) }
        if let p = d.state.parentID(of: l.id) { i["parentId"] = p.uuidString }
        if l.isGroup { i["childCount"] = l.children.count }
        return i
    }

    static func docInfo(_ d: Document) -> [String: Any] {
        var i: [String: Any] = ["id": d.id.uuidString, "name": d.name, "width": d.state.width, "height": d.state.height,
                                "resolution": d.state.resolution, "mode": d.state.colorMode.rawValue, "layerCount": d.state.allLayers.count,
                                "dirty": d.isDirty, "active": app.activeDocumentID == d.id]
        if let u = d.fileURL { i["path"] = u.path }
        if let b = d.state.selectionBounds { i["selection"] = ["x": b.x, "y": b.y, "width": b.width, "height": b.height] }
        return i
    }

    // MARK: Filters / adjustments by name

    static func filterKind(_ name: String) -> FilterKind? {
        let n = name.lowercased().replacingOccurrences(of: " ", with: "")
        return FilterKind.allCases.first { $0.rawValue.lowercased() == n }
            ?? FilterKind.allCases.first { $0.displayName.lowercased().replacingOccurrences(of: " ", with: "") == n }
            ?? FilterKind.allCases.first { $0.displayName.lowercased().replacingOccurrences(of: " ", with: "").hasPrefix(n) }
    }

    static func filterInstance(_ name: String, _ params: [String: Any]) throws -> FilterInstance {
        guard let k = filterKind(name) else { throw ScriptError.message("Unknown filter “\(name)”. See app.filters().") }
        var f = FilterInstance(kind: k)
        for (key, v) in params {
            if key == "opacity" { f.opacity = num(v, 100) / 100; continue }
            if key == "blendMode", let s = v as? String, let m = BlendMode(rawValue: s) { f.blendMode = m; continue }
            if key == "colors", let a = v as? [Any] { f.colors = a.map { color($0) }; continue }
            let p = k.params.first { $0.key == key } ?? k.params.first { $0.label.lowercased() == key.lowercased() }
            guard let p else { continue }
            if case .choice(let opts) = p.kind, let s = v as? String, let i = opts.firstIndex(where: { $0.lowercased() == s.lowercased() }) {
                f.values[p.key] = Double(i)
            } else if let b = v as? Bool {
                f.values[p.key] = b ? 1 : 0
            } else {
                f.values[p.key] = num(v, p.defaultValue)
            }
        }
        return f
    }

    static func adjustmentKind(_ name: String) -> AdjustmentKind? {
        let n = name.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "/", with: "")
        return AdjustmentKind.allCases.first { $0.rawValue.lowercased() == n }
            ?? AdjustmentKind.allCases.first { $0.displayName.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "/", with: "") == n }
    }

    /// Default settings merged with `params` (any AdjustmentSettings field by its Swift name).
    static func adjustmentSettings(_ name: String, _ params: [String: Any]) throws -> AdjustmentSettings {
        guard let k = adjustmentKind(name) else { throw ScriptError.message("Unknown adjustment “\(name)”. See app.adjustments().") }
        let base = AdjustmentSettings(kind: k)
        guard !params.isEmpty, let data = try? JSONEncoder().encode(base),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return base }
        for (key, v) in params where key != "kind" { obj[key] = v }
        guard let d2 = try? JSONSerialization.data(withJSONObject: obj), let s = try? JSONDecoder().decode(AdjustmentSettings.self, from: d2) else {
            throw ScriptError.message("Invalid parameters for “\(name)”.")
        }
        return s
    }

    // MARK: Dispatch

    static func dispatch(_ method: String, _ a: [Any], engine: ScriptEngine?) throws -> Any? {
        func arg(_ i: Int) -> Any? { i < a.count ? (a[i] is NSNull ? nil : a[i]) : nil }
        let interactive = engine?.interactive ?? true
        switch method {
        // App
        case "app.version": return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        case "app.documents": return app.documents.map(docInfo)
        case "app.activeDocument": return app.activeDocument.map(docInfo)
        case "app.setActiveDocument": let d = try doc(arg(0)); app.activeDocumentID = d.id; return nil
        case "app.open":
            guard let p = str(arg(0)) else { throw ScriptError.message("open(path) needs a path") }
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            let d = try DocumentIO.load(url: url)
            app.add(d)
            return docInfo(d)
        case "app.newDocument":
            let w = Int(num(arg(0), 1920)), h = Int(num(arg(1), 1080))
            let o = dict(arg(3))
            let bgArg = o["background"] as? String ?? "white"
            let bg: RGBA? = bgArg == "transparent" ? nil : (bgArg == "white" ? .white : RGBA(hex: bgArg) ?? .white)
            let d = Document.newBlank(width: min(maxCanvasDimension, max(1, w)), height: min(maxCanvasDimension, max(1, h)), resolution: validResolution(num(o["resolution"], 72)), background: bg, name: str(arg(2)) ?? "Untitled")
            app.add(d)
            return docInfo(d)
        case "app.alert":
            let m = str(arg(0)) ?? ""
            if interactive && !FilesModule.headless { AppActions.alert(m) } else { engine?.log?("[alert] " + m) }
            return nil
        case "app.confirm":
            let m = str(arg(0)) ?? ""
            if interactive && !FilesModule.headless { return AppActions.confirm(m, "", ok: "OK") }
            engine?.log?("[confirm] " + m); return true
        case "app.prompt":
            let m = str(arg(0)) ?? "", def = str(arg(1)) ?? ""
            guard interactive && !FilesModule.headless else { engine?.log?("[prompt] " + m + " → " + def); return def }
            let al = NSAlert(); al.messageText = tr(m)
            let f = NSTextField(string: def); f.frame = NSRect(x: 0, y: 0, width: 260, height: 24); al.accessoryView = f
            al.addButton(withTitle: tr("OK")); al.addButton(withTitle: tr("Cancel"))
            return UIBlock.run(al) == .alertFirstButtonReturn ? f.stringValue : nil
        case "app.chooseFolder":
            guard interactive && !FilesModule.headless else { return nil }
            return FilesUI.chooseFolder(message: str(arg(0)))?.path
        case "app.chooseFile":
            guard interactive && !FilesModule.headless else { return nil }
            return FilesUI.chooseFiles([.item]).first?.path
        case "app.listFiles":
            guard let p = str(arg(0)) else { return [] }
            let exts = (arg(1) as? [Any])?.compactMap { str($0)?.lowercased() }
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            let all = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            return all.filter { u in exts.map { $0.contains(u.pathExtension.lowercased()) } ?? BatchRunner.imageExts.contains(u.pathExtension.lowercased()) }
                .map(\.path).sorted()
        case "app.readFile":
            guard let p = str(arg(0)) else { return nil }
            return try String(contentsOfFile: (p as NSString).expandingTildeInPath, encoding: .utf8)
        case "app.writeFile":
            guard let p = str(arg(0)) else { return false }
            try (str(arg(1)) ?? "").write(toFile: (p as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
            didWriteFile?(URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
            return true
        case "app.filters":
            return FilterKind.allCases.map { k in
                ["name": k.rawValue, "displayName": k.displayName, "category": k.category.rawValue,
                 "params": k.params.map { p -> [String: Any] in
                    var d: [String: Any] = ["key": p.key, "label": p.label, "default": p.defaultValue]
                    if case .slider(let r) = p.kind { d["min"] = r.lowerBound; d["max"] = r.upperBound }
                    if case .choice(let o) = p.kind { d["choices"] = o }
                    return d
                 }] as [String: Any]
            }
        case "app.adjustments": return AdjustmentKind.allCases.map { ["name": $0.rawValue, "displayName": $0.displayName] }
        case "app.foregroundColor": return hex(app.foreground)
        case "app.setForegroundColor": app.foreground = color(arg(0)); app.pushRecent(app.foreground); return nil
        case "app.backgroundColor": return hex(app.background)
        case "app.setBackgroundColor": app.background = color(arg(0), .white); return nil
        case "app.swatches": return app.swatches.map(hex)
        case "app.status": app.setStatus(str(arg(0)) ?? ""); return nil

        // Document
        case "doc.info": return docInfo(try doc(arg(0)))
        case "doc.layers":
            let d = try doc(arg(0))
            let parent = str(arg(1)).flatMap(UUID.init(uuidString:))
            let list = parent.flatMap { d.state.layer($0)?.children } ?? d.state.layers
            return list.reversed().map { layerInfo(d, $0) }   // top first, like Photoshop's DOM
        case "doc.allLayers":
            let d = try doc(arg(0))
            return d.state.layers.flattenedForDisplay(includeCollapsed: true).map { layerInfo(d, $0.0) }
        case "doc.activeLayer":
            let d = try doc(arg(0))
            return d.activeLayer.map { layerInfo(d, $0) }
        case "doc.setActiveLayer":
            let d = try doc(arg(0)); let id = try layerID(d, arg(1))
            d.selectLayer(id); return nil
        case "doc.activate": let d = try doc(arg(0)); app.activeDocumentID = d.id; return nil
        case "doc.addLayer":
            let d = try doc(arg(0))
            var l = Layer.raster(name: str(arg(1)) ?? d.nextLayerName(), width: d.state.width, height: d.state.height)
            if let c = dict(arg(2))["fill"] {
                let buf = l.raster!.buffer
                buf.context.setFillColor(color(c).cgColor)
                buf.context.fill(CGRect(x: 0, y: 0, width: buf.width, height: buf.height))
                buf.markDirty()
                l.raster = RasterContent(buffer: buf, origin: .zero)
            }
            d.addLayer(l, commitName: "New Layer")
            return layerInfo(d, l)
        case "doc.addGroup":
            let d = try doc(arg(0))
            let g = Layer(name: str(arg(1)) ?? d.nextLayerName("Group"), content: .group(GroupContent()))
            d.addLayer(g, commitName: "New Group")
            return layerInfo(d, g)
        case "doc.addTextLayer":
            let d = try doc(arg(0))
            let o = dict(arg(2))
            var t = TextContent()
            t.text = str(arg(1)) ?? "Text"
            if let f = o["font"] as? String { t.fontName = f }
            t.fontSize = num(o["size"], 48)
            t.color = color(o["color"], .black)
            t.position = CGPoint(x: num(o["x"], 20), y: num(o["y"], 20))
            if let al = o["align"] as? String, let a = TextAlign(rawValue: al) { t.alignment = a }
            if o["width"] != nil { t.boxSize = CGSize(width: num(o["width"]), height: num(o["height"], t.fontSize * 3)) }
            let l = Layer(name: str(o["name"]) ?? String(t.text.prefix(30)), content: .text(t))
            d.addLayer(l, commitName: "New Type Layer")
            return layerInfo(d, l)
        case "doc.addShape":
            let d = try doc(arg(0))
            let type = (str(arg(1)) ?? "rectangle").lowercased()
            let o = dict(arg(2))
            let r = CGRect(x: num(o["x"], 0), y: num(o["y"], 0), width: num(o["width"], 100), height: num(o["height"], 100))
            let geo: ShapeGeometry
            switch type {
            case "ellipse", "circle": geo = .ellipse(r)
            case "polygon", "star": geo = .polygon(r, sides: Int(num(o["sides"], 5)), starRatio: type == "star" ? num(o["starRatio"], 0.5) : 1)
            case "line": geo = .line(CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), weight: num(o["weight"], 4))
            default: geo = .rectangle(r, cornerRadius: num(o["radius"], 0))
            }
            var sc = ShapeContent(geometry: geo, fill: o["fill"] as? String == "none" ? .none : .color(color(o["fill"] ?? o["color"], RGBA(hex: "4A90E2")!)))
            if let s = o["stroke"] { sc.stroke = StrokeStyle(paint: .color(color(s)), width: num(o["strokeWidth"], 3)) }
            let l = Layer(name: str(o["name"]) ?? d.nextLayerName(geo.kindName), content: .shape(sc))
            d.addLayer(l, commitName: "New Shape Layer")
            return layerInfo(d, l)
        case "doc.addAdjustmentLayer":
            let d = try doc(arg(0))
            let s = try adjustmentSettings(str(arg(1)) ?? "", dict(arg(2)))
            var l = Layer(name: d.nextLayerName(s.kind.displayName), content: .adjustment(s))
            l.mask = LayerMask.reveal(width: d.state.width, height: d.state.height)
            d.addLayer(l, commitName: "New \(s.kind.displayName) Layer")
            return layerInfo(d, l)
        case "doc.placeFile":
            let d = try doc(arg(0))
            guard let p = str(arg(1)) else { throw ScriptError.message("placeFile(path) needs a path") }
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            let placed = try DocumentIO.loadForPlacing(url: url)
            let src: SmartSource = placed.state.layers.count == 1 && placed.state.layers[0].raster != nil
                ? .image(placed.state.layers[0].raster!.buffer) : .document(placed.state)
            let o = dict(arg(2))
            var r = CGRect(x: 0, y: 0, width: CGFloat(placed.state.width), height: CGFloat(placed.state.height))
            if o["width"] != nil || o["height"] != nil {
                let box = CGRect(x: num(o["x"]), y: num(o["y"]), width: num(o["width"], Double(r.width)), height: num(o["height"], Double(r.height)))
                let k = min(box.width / r.width, box.height / r.height)
                r = CGRect(x: box.midX - r.width * k / 2, y: box.midY - r.height * k / 2, width: r.width * k, height: r.height * k)
            } else { r.origin = CGPoint(x: num(o["x"]), y: num(o["y"])) }
            let so = SmartObjectContent(source: src, quad: Quad(rect: r), sourceName: url.lastPathComponent)
            let l = Layer(name: str(o["name"]) ?? (url.lastPathComponent as NSString).deletingPathExtension, content: .smartObject(so))
            d.addLayer(l, commitName: "Place Embedded")
            return layerInfo(d, l)
        case "doc.flatten": let d = try doc(arg(0)); on(d) { AppActions.flattenImage() }; return nil
        case "doc.mergeVisible": let d = try doc(arg(0)); on(d) { AppActions.mergeVisible() }; return nil
        case "doc.resizeImage":
            let d = try doc(arg(0))
            var w = Int(num(arg(1), 0)), h = Int(num(arg(2), 0))
            if w <= 0 && h <= 0 { throw ScriptError.message("resizeImage(width, height)") }
            if w <= 0 { w = Int((Double(h) * Double(d.state.width) / Double(d.state.height)).rounded()) }
            if h <= 0 { h = Int((Double(w) * Double(d.state.height) / Double(d.state.width)).rounded()) }
            on(d) { AppActions.imageSize(width: w, height: h, resolution: num(arg(3), d.state.resolution), scaleStyles: true) }
            return docInfo(d)
        case "doc.resizeCanvas":
            let d = try doc(arg(0))
            let anchor = str(arg(3)) ?? "center"
            let ax = anchor.contains("left") ? 0 : (anchor.contains("right") ? 2 : 1), ay = anchor.contains("top") ? 0 : (anchor.contains("bottom") ? 2 : 1)
            on(d) { AppActions.canvasSize(width: Int(num(arg(1), Double(d.state.width))), height: Int(num(arg(2), Double(d.state.height))), anchorX: ax, anchorY: ay, extension: app.background) }
            return docInfo(d)
        case "doc.rotateCanvas": let d = try doc(arg(0)); on(d) { AppActions.rotateCanvas(Int(num(arg(1), 90))) }; return docInfo(d)
        case "doc.flipCanvas": let d = try doc(arg(0)); on(d) { AppActions.flipCanvas(horizontal: (arg(1) as? Bool) ?? true) }; return nil
        case "doc.selectAll": let d = try doc(arg(0)); on(d) { AppActions.selectAll() }; return nil
        case "doc.deselect": let d = try doc(arg(0)); d.setSelection(nil, commitName: "Deselect"); return nil
        case "doc.invertSelection": let d = try doc(arg(0)); on(d) { AppActions.inverseSelection() }; return nil
        case "doc.selectRect", "doc.selectEllipse":
            let d = try doc(arg(0))
            let r = CGRect(x: num(arg(1)), y: num(arg(2)), width: num(arg(3)), height: num(arg(4)))
            let path = method == "doc.selectRect" ? CGPath(rect: r, transform: nil) : CGPath(ellipseIn: r, transform: nil)
            let m = SelectionOps.mask(fromPath: path, width: d.state.width, height: d.state.height, antialias: method != "doc.selectRect")
            let mode = str(arg(5)) ?? "new"
            let combine: SelectionCombine = mode == "add" ? .add : (mode == "subtract" ? .subtract : (mode == "intersect" ? .intersect : .new))
            d.setSelection(SelectionOps.combine(d.state.selection, m, mode: combine), commitName: "Select")
            return nil
        case "doc.selectionBounds":
            let d = try doc(arg(0))
            return d.state.selectionBounds.map { ["x": $0.x, "y": $0.y, "width": $0.width, "height": $0.height] }
        case "doc.fill":
            let d = try doc(arg(0))
            let c = color(arg(1))
            let lid = try layerID(d, arg(2))
            if d.state.layer(lid)?.isRaster != true { throw ScriptError.message("fill() needs a pixel layer.") }
            on(d, layer: lid) { AppActions.fill(.color, color: c, opacity: num(arg(3), 100) / 100, mode: .normal, preserveTransparency: false) }
            return nil
        case "doc.applyFilter":
            let d = try doc(arg(0))
            return try dispatch("layer.applyFilter", [d.id.uuidString, NSNull(), arg(1) ?? "", arg(2) ?? [:]], engine: engine)
        case "doc.undo": let d = try doc(arg(0)); d.undo(); return nil
        case "doc.redo": let d = try doc(arg(0)); d.redo(); return nil
        case "doc.duplicate":
            let d = try doc(arg(0))
            let n = Document(state: d.state, name: str(arg(1)) ?? (d.name as NSString).deletingPathExtension + " copy")
            app.add(n)
            return docInfo(n)
        case "doc.save":
            let d = try doc(arg(0))
            guard let p = str(arg(1)) ?? d.fileURL?.path else { throw ScriptError.message("save(path): no file path") }
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            switch url.pathExtension.lowercased() {
            case Brand.documentExtension, Brand.Legacy.documentExtension: try DocumentIO.saveNative(d, to: url); d.fileURL = url; d.markSaved()
            case "psd": try PSDWriter.write(d.state, to: url)
            case "psb": try PSDWriter.write(d.state, to: url, large: true)
            case "pdf": try PDFExport.write(d.state, to: url)
            case "dcm": try DICOM.export(d.state, to: url)
            default: return try dispatch("doc.export", [d.id.uuidString, p, [:] as [String: Any]], engine: engine)
            }
            didWriteFile?(url)
            return url.path
        case "doc.export":
            let d = try doc(arg(0))
            guard let p = str(arg(1)) else { throw ScriptError.message("exportAs(path) needs a path") }
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            let o = dict(arg(2))
            let ext = (str(o["format"]) ?? url.pathExtension).lowercased()
            let fmt = ExportFormat.allCases.first { $0.ext == ext || $0.rawValue.lowercased() == ext } ?? (ext == "jpeg" ? .jpeg : (ext == "tif" ? .tiff : .png))
            try DocumentIO.export(d.state, to: url, format: fmt, quality: num(o["quality"], 90) / (num(o["quality"], 90) > 1 ? 100 : 1), scale: num(o["scale"], 1))
            didWriteFile?(url)
            return url.path
        case "doc.close":
            let d = try doc(arg(0))
            if (arg(1) as? Bool) == true { _ = try dispatch("doc.save", [d.id.uuidString], engine: engine) }
            app.close(d)
            return nil

        // Layer
        case "layer.get":
            let d = try doc(arg(0)); let id = try layerID(d, arg(1))
            return layerInfo(d, d.state.layer(id)!)
        case "layer.set":
            let d = try doc(arg(0)); let id = try layerID(d, arg(1))
            let p = dict(arg(2))
            d.updateLayer(id) { l in
                if let n = p["name"] as? String { l.name = n }
                if let v = p["visible"] as? Bool { l.isVisible = v }
                if p["opacity"] != nil { l.opacity = min(1, max(0, num(p["opacity"]) / 100)) }
                if p["fillOpacity"] != nil { l.fillOpacity = min(1, max(0, num(p["fillOpacity"]) / 100)) }
                if let b = p["blendMode"] as? String, let m = BlendMode(rawValue: b) ?? BlendMode.allCases.first(where: { $0.displayName.lowercased() == b.lowercased() }) { l.blendMode = m }
                if let c = p["clipped"] as? Bool { l.isClipped = c }
                if let lk = p["locked"] as? Bool { l.locks.all = lk }
            }
            d.commit("Layer Properties")
            return layerInfo(d, d.state.layer(id)!)
        case "layer.setText":
            let d = try doc(arg(0)); let id = try layerID(d, arg(1))
            guard d.state.layer(id)?.isText == true else { throw ScriptError.message("Not a text layer.") }
            let o = dict(arg(3))
            d.updateLayer(id) { l in
                guard var t = l.text else { return }
                if let s = str(arg(2)) { t.text = s; t.runs = [] }
                if o["size"] != nil { t.fontSize = num(o["size"]) }
                if let f = o["font"] as? String { t.fontName = f }
                if o["color"] != nil { t.color = color(o["color"]) }
                l.text = t
            }
            d.commit("Edit Type")
            return layerInfo(d, d.state.layer(id)!)
        case "layer.translate":
            let d = try doc(arg(0)); let id = try layerID(d, arg(1))
            let dx = num(arg(2)), dy = num(arg(3))
            for lid in d.withLinked([id]) { d.updateLayer(lid) { $0.translate(dx: dx, dy: dy) } }
            d.commit("Move")
            return layerInfo(d, d.state.layer(id)!)
        case "layer.rotate", "layer.scale":
            let d = try doc(arg(0)); let id = try layerID(d, arg(1))
            guard let l = d.state.layer(id), let b = Compositor.shared.contentBounds(l, state: d.state) else { return nil }
            let c = CGPoint(x: b.midX, y: b.midY)
            let m: CGAffineTransform
            if method == "layer.rotate" {
                m = CGAffineTransform(rotationAngle: CGFloat(num(arg(2)) * .pi / 180))
            } else {
                let sx = num(arg(2), 100) / 100
                m = CGAffineTransform(scaleX: CGFloat(sx), y: CGFloat(num(arg(3), sx * 100) / 100))
            }
            let full = CGAffineTransform(translationX: -c.x, y: -c.y).concatenating(m).concatenating(CGAffineTransform(translationX: c.x, y: c.y))
            let sp = CanvasSpace(width: d.state.width, height: d.state.height)
            d.updateLayer(id) { $0 = LayerTransformer.apply(Homography(affine: full), to: $0, space: sp) }
            d.commit(method == "layer.rotate" ? "Rotate" : "Scale")
            return layerInfo(d, d.state.layer(id)!)
        case "layer.duplicate":
            let d = try doc(arg(0)); let id = try layerID(d, arg(1))
            guard let l = d.state.layer(id) else { return nil }
            let c = l.duplicated(newName: str(arg(2)) ?? l.name + " copy")
            d.state.insertLayer(c, above: id)
            d.activeLayerID = c.id; d.selectedLayerIDs = [c.id]
            d.commit("Duplicate Layer")
            return layerInfo(d, c)
        case "layer.remove":
            let d = try doc(arg(0)); let id = try layerID(d, arg(1))
            d.state.removeLayer(id)
            d.validateActiveLayer()
            d.commit("Delete Layer")
            return nil
        case "layer.move":
            let d = try doc(arg(0)); let id = try layerID(d, arg(1))
            let other = try layerID(d, arg(2))
            guard id != other, let l = d.state.removeLayer(id) else { return nil }
            if (str(arg(3)) ?? "above") == "below" { d.state.insertLayer(l, below: other) } else { d.state.insertLayer(l, above: other) }
            d.commit("Arrange")
            return nil
        case "layer.applyFilter":
            let d = try doc(arg(0)); let id = try layerID(d, arg(1))
            let f = try filterInstance(str(arg(2)) ?? "", dict(arg(3)))
            guard let l = d.state.layer(id) else { return nil }
            if !l.isRaster && !l.isSmartObject {
                if l.isGroup || l.isAdjustment { throw ScriptError.message("Filters need a pixel layer or smart object.") }
                on(d, layer: id) { AppActions.rasterizeLayer(id) }
            }
            // let the filter spread beyond the layer's pixels (blur, glow…): grow the buffer to the canvas first
            if d.state.layer(id)?.isRaster == true { _ = d.beginPixelEdit(layerID: id, target: .content, coverCanvas: true) }
            on(d, layer: id) {
                let prevTarget = d.editTarget
                d.editTarget = .content
                AppActions.applyFilter(f)
                d.editTarget = prevTarget
            }
            return layerInfo(d, d.state.layer(id) ?? l)
        case "layer.adjust":
            let d = try doc(arg(0)); let id = try layerID(d, arg(1))
            let s = try adjustmentSettings(str(arg(2)) ?? "", dict(arg(3)))
            if d.state.layer(id)?.isRaster != true { on(d, layer: id) { AppActions.rasterizeLayer(id) } }
            on(d, layer: id) { AppActions.applyAdjustment(s) }
            return nil
        case "layer.rasterize":
            let d = try doc(arg(0)); let id = try layerID(d, arg(1))
            on(d, layer: id) { AppActions.rasterizeLayer(id) }
            return layerInfo(d, d.state.layer(id)!)
        case "layer.children":
            return try dispatch("doc.layers", [arg(0) ?? NSNull(), arg(1) ?? NSNull()], engine: engine)

        // Plugins: call a function defined in the plugin's own context
        case "plugin.invoke":
            guard let e = engine, let fn = str(arg(0)) else { return nil }
            return e.callFunction(fn, (arg(1) as? [Any]) ?? [])
        case "plugin.log":
            engine?.log?(a.map { "\($0)" }.joined(separator: " "))
            return nil
        default:
            throw ScriptError.message("Unknown API method “\(method)”.")
        }
    }

    // MARK: JavaScript object model

    static let prelude = #"""
    (function (g) {
      'use strict';
      const call = (m, ...a) => __lumenCall(m, a);
      const withGetByName = (arr) => { arr.getByName = (n) => arr.find(x => x.name === n) || null; return arr; };

      class Layer {
        constructor(doc, info) { this.doc = doc; this.id = info.id; }
        get info() { return call('layer.get', this.doc.id, this.id); }
        get name() { return this.info.name; }            set name(v) { call('layer.set', this.doc.id, this.id, { name: String(v) }); }
        get visible() { return this.info.visible; }      set visible(v) { call('layer.set', this.doc.id, this.id, { visible: !!v }); }
        get opacity() { return this.info.opacity; }      set opacity(v) { call('layer.set', this.doc.id, this.id, { opacity: +v }); }
        get fillOpacity() { return this.info.fillOpacity; } set fillOpacity(v) { call('layer.set', this.doc.id, this.id, { fillOpacity: +v }); }
        get blendMode() { return this.info.blendMode; }  set blendMode(v) { call('layer.set', this.doc.id, this.id, { blendMode: String(v) }); }
        get kind() { return this.info.kind; }
        get isGroup() { return this.info.isGroup; }
        get bounds() { return this.info.bounds || null; }
        get text() { return this.info.text; }            set text(v) { call('layer.setText', this.doc.id, this.id, String(v), {}); }
        get layers() { return withGetByName(call('doc.layers', this.doc.id, this.id).map(i => new Layer(this.doc, i))); }
        setTextStyle(o) { call('layer.setText', this.doc.id, this.id, null, o || {}); return this; }
        translate(dx, dy) { call('layer.translate', this.doc.id, this.id, +dx || 0, +dy || 0); return this; }
        rotate(deg) { call('layer.rotate', this.doc.id, this.id, +deg || 0); return this; }
        resize(sx, sy) { call('layer.scale', this.doc.id, this.id, +sx || 100, sy === undefined ? +sx || 100 : +sy); return this; }
        duplicate(name) { return new Layer(this.doc, call('layer.duplicate', this.doc.id, this.id, name || null)); }
        remove() { call('layer.remove', this.doc.id, this.id); }
        delete() { this.remove(); }
        applyFilter(name, params) { call('layer.applyFilter', this.doc.id, this.id, String(name), params || {}); return this; }
        adjust(kind, params) { call('layer.adjust', this.doc.id, this.id, String(kind), params || {}); return this; }
        rasterize() { call('layer.rasterize', this.doc.id, this.id); return this; }
        moveAbove(l) { call('layer.move', this.doc.id, this.id, l.id, 'above'); return this; }
        moveBelow(l) { call('layer.move', this.doc.id, this.id, l.id, 'below'); return this; }
        select() { call('doc.setActiveLayer', this.doc.id, this.id); return this; }
        fill(color) { call('doc.fill', this.doc.id, color, this.id); return this; }
        toString() { return '[Layer ' + this.name + ']'; }
      }

      class Selection {
        constructor(doc) { this.doc = doc; }
        selectAll() { call('doc.selectAll', this.doc.id); return this; }
        deselect() { call('doc.deselect', this.doc.id); return this; }
        rect(x, y, w, h, mode) { call('doc.selectRect', this.doc.id, x, y, w, h, mode || 'new'); return this; }
        select(r, mode) { return this.rect(r.x, r.y, r.width, r.height, mode); }
        ellipse(x, y, w, h, mode) { call('doc.selectEllipse', this.doc.id, x, y, w, h, mode || 'new'); return this; }
        invert() { call('doc.invertSelection', this.doc.id); return this; }
        get bounds() { return call('doc.selectionBounds', this.doc.id); }
        fill(color, opacity) { call('doc.fill', this.doc.id, color, null, opacity === undefined ? 100 : opacity); return this; }
      }

      class Document {
        constructor(info) { this.id = info.id; }
        get info() { return call('doc.info', this.id); }
        get name() { return this.info.name; }
        get width() { return this.info.width; }
        get height() { return this.info.height; }
        get resolution() { return this.info.resolution; }
        get path() { return this.info.path || null; }
        get mode() { return this.info.mode; }
        get layers() { return withGetByName(call('doc.layers', this.id, null).map(i => new Layer(this, i))); }
        get allLayers() { return withGetByName(call('doc.allLayers', this.id).map(i => new Layer(this, i))); }
        get activeLayer() { const i = call('doc.activeLayer', this.id); return i ? new Layer(this, i) : null; }
        set activeLayer(l) { call('doc.setActiveLayer', this.id, l.id); }
        get selection() { return new Selection(this); }
        activate() { call('doc.activate', this.id); return this; }
        addLayer(name, opts) { return new Layer(this, call('doc.addLayer', this.id, name || null, opts || {})); }
        addGroup(name) { return new Layer(this, call('doc.addGroup', this.id, name || null)); }
        addTextLayer(text, opts) { return new Layer(this, call('doc.addTextLayer', this.id, String(text), opts || {})); }
        addShape(type, opts) { return new Layer(this, call('doc.addShape', this.id, String(type || 'rectangle'), opts || {})); }
        addAdjustmentLayer(kind, params) { return new Layer(this, call('doc.addAdjustmentLayer', this.id, String(kind), params || {})); }
        placeFile(path, rect) { return new Layer(this, call('doc.placeFile', this.id, String(path), rect || {})); }
        applyFilter(name, params) { call('doc.applyFilter', this.id, String(name), params || {}); return this; }
        flatten() { call('doc.flatten', this.id); return this; }
        mergeVisible() { call('doc.mergeVisible', this.id); return this; }
        resizeImage(w, h, res) { call('doc.resizeImage', this.id, w || 0, h || 0, res || null); return this; }
        resizeCanvas(w, h, anchor) { call('doc.resizeCanvas', this.id, w, h, anchor || 'center'); return this; }
        rotateCanvas(deg) { call('doc.rotateCanvas', this.id, deg); return this; }
        flipCanvas(horizontal) { call('doc.flipCanvas', this.id, horizontal !== false); return this; }
        undo() { call('doc.undo', this.id); return this; }
        redo() { call('doc.redo', this.id); return this; }
        duplicate(name) { return new Document(call('doc.duplicate', this.id, name || null)); }
        save(path) { return call('doc.save', this.id, path || null); }
        saveAs(path) { return call('doc.save', this.id, path); }
        exportAs(path, opts) { return call('doc.export', this.id, path, opts || {}); }
        close(save) { call('doc.close', this.id, !!save); }
        toString() { return '[Document ' + this.name + ']'; }
      }

      const app = {
        get version() { return call('app.version'); },
        get activeDocument() { const i = call('app.activeDocument'); return i ? new Document(i) : null; },
        set activeDocument(d) { call('app.setActiveDocument', d.id); },
        get documents() { return withGetByName(call('app.documents').map(i => new Document(i))); },
        open(path) { return new Document(call('app.open', String(path))); },
        newDocument(w, h, name, opts) { return new Document(call('app.newDocument', w, h, name || null, opts || {})); },
        alert(m) { call('app.alert', String(m)); },
        confirm(m) { return call('app.confirm', String(m)); },
        prompt(m, d) { return call('app.prompt', String(m), d === undefined ? '' : String(d)); },
        chooseFolder(m) { return call('app.chooseFolder', m || null); },
        chooseFile() { return call('app.chooseFile'); },
        listFiles(folder, exts) { return call('app.listFiles', String(folder), exts || null); },
        readFile(p) { return call('app.readFile', String(p)); },
        writeFile(p, s) { return call('app.writeFile', String(p), String(s)); },
        filters() { return call('app.filters'); },
        adjustments() { return call('app.adjustments'); },
        get foregroundColor() { return call('app.foregroundColor'); },
        set foregroundColor(c) { call('app.setForegroundColor', c); },
        get backgroundColor() { return call('app.backgroundColor'); },
        set backgroundColor(c) { call('app.setBackgroundColor', c); },
        get swatches() { return call('app.swatches'); },
        status(m) { call('app.status', String(m)); },
      };
      g.app = app; g.Document = Document; g.Layer = Layer; g.Selection = Selection;
      g.alert = (m) => app.alert(m); g.prompt = (m, d) => app.prompt(m, d); g.confirm = (m) => app.confirm(m);
      g.print = (...a) => console.log(...a);
    })(this);
    """#
}

// MARK: - Script library & running

enum ScriptLibrary {
    static var supportFolder: URL {
        if let o = ProcessInfo.processInfo.environment["LUMEN_SUPPORT_DIR"] { return URL(fileURLWithPath: o) }
        return Brand.supportFolder
    }
    static var scriptsFolder: URL { supportFolder.appendingPathComponent("Scripts") }
    static var pluginsFolder: URL { supportFolder.appendingPathComponent("Plugins") }

    static func scripts() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: scriptsFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["js", "jsx"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Writes the sample scripts and the sample plugin the first time (never overwrites user files).
    static func installSamplesIfNeeded(into root: URL? = nil) {
        let fm = FileManager.default
        let base = root ?? supportFolder
        let marker = base.appendingPathComponent(".samples-installed")
        if fm.fileExists(atPath: marker.path) { return }
        let scripts = base.appendingPathComponent("Scripts"), plugins = base.appendingPathComponent("Plugins")
        try? fm.createDirectory(at: scripts, withIntermediateDirectories: true)
        for (name, src) in SampleScripts.scripts {
            let u = scripts.appendingPathComponent(name)
            if !fm.fileExists(atPath: u.path) { try? src.write(to: u, atomically: true, encoding: .utf8) }
        }
        for (folder, files) in SampleScripts.plugins {
            let dir = plugins.appendingPathComponent(folder)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, src) in files {
                let u = dir.appendingPathComponent(name)
                if !fm.fileExists(atPath: u.path) { try? src.write(to: u, atomically: true, encoding: .utf8) }
            }
        }
        try? "1".write(to: marker, atomically: true, encoding: .utf8)
    }
}

enum ScriptRunner {
    static func runFile(_ url: URL) {
        guard let src = try? String(contentsOf: url, encoding: .utf8) else { AppActions.alert("Could not read the script."); return }
        let e = ScriptEngine(name: url.lastPathComponent, interactive: true)
        let console = ScriptConsole.shared
        e.log = { console.append($0) }
        console.append("▶︎ \(url.lastPathComponent)")
        if !e.evaluate(src, file: url.path) {
            AppActions.alert("Script error in “\(url.lastPathComponent)”.", e.lastError ?? "")
        }
    }

    static func browse() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "js") ?? .sourceCode, UTType(filenameExtension: "jsx") ?? .sourceCode, .javaScript]
        p.directoryURL = ScriptLibrary.scriptsFolder
        guard UIBlock.run(p) == .OK, let u = p.url else { return }
        runFile(u)
    }
}
