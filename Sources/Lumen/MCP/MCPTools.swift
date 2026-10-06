import AppKit
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

// The tools the MCP server offers (docs/MCP.md has the list with examples). Each tool runs on the main thread
// against the live app, reuses the app's own commands (AppActions, ScriptAPI, FilterCatalog, DocumentIO …), is one
// undo step named "MCP: <title>", and makes the document it works on the active one so the result shows in the window.
// Definitions: MCPToolsDocuments.swift, MCPToolsLayers.swift, MCPToolsEditing.swift, MCPToolsMore.swift.

struct MCPToolError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct MCPTool {
    let name: String
    /// Undo step: "MCP: <title>".
    let title: String
    let description: String
    let schema: [String: Any]
    var readOnly = false
    var destructive = false
    /// Talks to services outside the app (generative AI).
    var openWorld = false
    /// The call's history steps are folded into one "MCP: <title>" step (not for undo / redo themselves).
    var undoStep = true
    /// The body calls `done` exactly once (possibly later, for jobs that run in the background).
    let run: (MCPArgs, @escaping (MCPToolResult) -> Void) throws -> Void

    init(_ name: String, _ title: String, _ description: String, schema: [String: Any], readOnly: Bool = false, destructive: Bool = false,
         openWorld: Bool = false, undoStep: Bool = true, async run: @escaping (MCPArgs, @escaping (MCPToolResult) -> Void) throws -> Void) {
        self.name = name; self.title = title; self.description = description; self.schema = schema
        self.readOnly = readOnly; self.destructive = destructive; self.openWorld = openWorld; self.undoStep = undoStep; self.run = run
    }

    init(_ name: String, _ title: String, _ description: String, schema: [String: Any], readOnly: Bool = false, destructive: Bool = false,
         undoStep: Bool = true, _ body: @escaping (MCPArgs) throws -> MCPToolResult) {
        self.init(name, title, description, schema: schema, readOnly: readOnly, destructive: destructive, undoStep: undoStep, async: { a, done in done(try body(a)) })
    }

    var descriptor: MCPToolDescriptor {
        MCPToolDescriptor(name: name, title: title, description: description, inputSchema: schema,
                          annotations: ["readOnlyHint": readOnly, "destructiveHint": destructive, "openWorldHint": openWorld])
    }
}

/// Typed access to validated arguments (the endpoint has already checked them against the schema).
struct MCPArgs {
    let raw: [String: Any]
    init(_ raw: [String: Any]) { self.raw = raw }

    subscript(_ k: String) -> Any? { raw[k] is NSNull ? nil : raw[k] }
    func has(_ k: String) -> Bool { self[k] != nil }
    func string(_ k: String) -> String? { self[k] as? String }
    func double(_ k: String) -> Double? { MCPJSON.double(self[k]) }
    func int(_ k: String) -> Int? { double(k).map { Int($0.rounded()) } }
    func bool(_ k: String) -> Bool? { MCPJSON.isBool(self[k]) ? (self[k] as? NSNumber)?.boolValue ?? (self[k] as? Bool) : nil }
    func object(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
    func array(_ k: String) -> [Any]? { self[k] as? [Any] }

    func require(_ k: String) throws -> String {
        guard let s = string(k), !s.isEmpty else { throw MCPToolError("`\(k)` is required.") }
        return s
    }

    func color(_ k: String) throws -> RGBA? {
        guard let v = self[k] else { return nil }
        return try MCPArgs.color(v, name: k)
    }

    static func color(_ v: Any, name: String) throws -> RGBA {
        if let s = v as? String {
            let named: [String: String] = ["black": "000000", "white": "FFFFFF", "red": "FF0000", "green": "00FF00", "blue": "0000FF",
                                           "yellow": "FFFF00", "cyan": "00FFFF", "magenta": "FF00FF", "gray": "808080", "grey": "808080",
                                           "orange": "FF8000", "purple": "800080", "transparent": "00000000"]
            if let c = RGBA(hex: named[s.lowercased()] ?? s) { return c }
            throw MCPToolError("`\(name)` is not a colour: \(s). Use \"#RRGGBB\", \"#RRGGBBAA\" or [r, g, b] with 0–255 components.")
        }
        if let a = v as? [Any], a.count >= 3, a.count <= 4 {
            let n = a.compactMap { MCPJSON.double($0) }
            guard n.count == a.count else { throw MCPToolError("`\(name)` components must be numbers.") }
            let k = n.prefix(3).contains { $0 > 1 } ? 255.0 : 1.0
            func c(_ x: Double) -> Double { min(1, max(0, x / k)) }
            let alpha = n.count > 3 ? (n[3] > 1 ? min(1, n[3] / 255) : max(0, n[3])) : 1
            return RGBA(r: c(n[0]), g: c(n[1]), b: c(n[2]), a: alpha)
        }
        throw MCPToolError("`\(name)` is not a colour. Use \"#RRGGBB\" or [r, g, b] (0–255).")
    }

    func point(_ k: String) -> CGPoint? {
        guard let o = object(k), let x = MCPJSON.double(o["x"]), let y = MCPJSON.double(o["y"]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    func rect(_ k: String) -> CGRect? {
        guard let o = object(k) else { return nil }
        return MCPArgs.rect(o)
    }

    static func rect(_ o: [String: Any]) -> CGRect? {
        guard let x = MCPJSON.double(o["x"]), let y = MCPJSON.double(o["y"]), let w = MCPJSON.double(o["width"]), let h = MCPJSON.double(o["height"]) else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func blendMode(_ k: String) throws -> BlendMode? {
        guard let s = string(k) else { return nil }
        return try MCPArgs.blendMode(s)
    }

    static func blendMode(_ s: String) throws -> BlendMode {
        let n = MCPTools.norm(s)
        if let m = BlendMode.allCases.first(where: { MCPTools.norm($0.rawValue) == n || MCPTools.norm($0.displayName) == n }) { return m }
        throw MCPToolError("Unknown blend mode “\(s)”. Use one of: \(BlendMode.allCases.map(\.rawValue).joined(separator: ", ")).")
    }
}

enum MCPTools {
    static var app: AppModel { AppModel.shared }

    /// Every tool, in a fixed order (clients cache the list).
    static let all: [MCPTool] = documentTools + inspectTools + layerTools + editingTools + textShapeTools + brushTools + automationTools + aiTools
    static let byName: [String: MCPTool] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    static var descriptors: [MCPToolDescriptor] { all.map(\.descriptor) }

    static let instructions = """
    ImageCrat is a layered image editor (like Photoshop) running on this Mac; these tools act on the open app and the user \
    sees every change. Coordinates are document pixels with the origin at the top-left. Start with list_documents or \
    new_document / open_document, use get_document_info for layer ids, and render_preview to look at the result. Every \
    editing call is one undo step ("MCP: …") the user can undo; undo / redo work too. Paths are absolute file paths. \
    Colours are "#RRGGBB" hex strings or [r, g, b] arrays (0–255).
    """

    // MARK: Running

    /// Runs a validated call on the main thread. `done` is called once.
    static func run(_ call: MCPToolCall, _ done: @escaping (MCPToolResult) -> Void) {
        guard let tool = byName[call.name] else { return done(.error("Unknown tool \(call.name).")) }
        if !tool.readOnly {
            if let dlg = app.dialog {
                return done(.error("\(Brand.name) has a dialog open (\(dialogName(dlg))). Close it in \(Brand.name), then try again."))
            }
            PendingEdits.applyPending()   // a pending transform / type edit is confirmed first, as for menu commands
        }
        let before = MCPUndo.snapshot()
        let statusBefore = app.statusMessage
        var alerts: [String] = []
        let savedHook = AppActions.modalHook
        AppActions.modalHook = { title, info in alerts.append(info.isEmpty ? title : "\(title) \(info)"); return false }
        var finished = false
        let finish: (MCPToolResult) -> Void = { r in
            guard !finished else { return }
            finished = true
            var r = r
            if !tool.readOnly {
                if tool.undoStep { MCPUndo.fold(before, name: "MCP: \(tool.title)") }   // (history names are stored in English)
                // (a tool that wrote a file already put its path in the status bar)
                if !r.isError && app.statusMessage == statusBefore { app.setStatus("MCP: \(tool.title)") }
            }
            if !alerts.isEmpty {
                r.content.append(["type": "text", "text": "\(Brand.name) reported: " + alerts.joined(separator: " · ")])
            }
            done(r)
        }
        do {
            try tool.run(MCPArgs(call.arguments), finish)
        } catch {
            finish(.error((error as? MCPToolError)?.message ?? error.localizedDescription))
        }
        AppActions.modalHook = savedHook   // jobs that finish later must not capture the user's own alerts
    }

    static func dialogName(_ d: ActiveDialog) -> String {
        switch d {
        case .filter(let k, _, _): return k.displayName
        case .adjustment(let k): return k.displayName
        case .preferences: return "Preferences"   // (read by the MCP client: English)
        default: return d.id
        }
    }

    // MARK: Lookup

    static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// The document named by `doc_id`, else the active one; it becomes the active document (so the user sees it).
    static func doc(_ a: MCPArgs, activate: Bool = true) throws -> Document {
        if let id = a.string("doc_id") {
            guard let d = app.documents.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
                throw MCPToolError("No open document has id \(id). Use list_documents to see the open documents.")
            }
            if activate && app.activeDocumentID != d.id { app.activeDocumentID = d.id }
            return d
        }
        guard let d = app.activeDocument ?? app.documents.last else {
            throw MCPToolError("No document is open. Use new_document or open_document first.")
        }
        if activate && app.activeDocumentID != d.id { app.activeDocumentID = d.id }
        return d
    }

    /// The layer `key` names (default `layer_id`), else the active layer.
    static func layer(_ d: Document, _ a: MCPArgs, key: String = "layer_id", required: Bool = false) throws -> Layer {
        if let s = a.string(key) {
            guard let id = UUID(uuidString: s), let l = d.state.layer(id) else {
                throw MCPToolError("Layer not found: \(s). Use get_document_info to list the layer ids of “\(d.name)”.")
            }
            return l
        }
        if required { throw MCPToolError("`\(key)` is required.") }
        guard let l = d.activeLayer else { throw MCPToolError("“\(d.name)” has no active layer. Pass `\(key)` (see get_document_info).") }
        return l
    }

    /// Makes `id` the only selected layer (AppActions commands act on the selection).
    static func select(_ d: Document, _ id: UUID) {
        if d.activeLayerID != id || d.selectedLayerIDs != [id] { d.selectLayer(id) }
        d.editTarget = .content
    }

    /// Absolute file path argument.
    static func path(_ a: MCPArgs, _ key: String = "path") throws -> URL {
        let p = try a.require(key)
        let expanded = (p as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw MCPToolError("`\(key)` must be an absolute path (got “\(p)”).") }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    // MARK: Results

    static func ok(_ summary: String, _ data: Any? = nil) -> MCPToolResult {
        guard let data else { return .text(summary) }
        return MCPToolResult(content: [["type": "text", "text": summary + "\n" + MCPJSON.string(data, pretty: true)]], structured: data)
    }

    static func docJSON(_ d: Document, layers: Bool = false) -> [String: Any] {
        let st = d.state
        var i: [String: Any] = ["id": d.id.uuidString, "name": d.name, "width": st.width, "height": st.height, "resolution": st.resolution,
                                "mode": st.colorMode.rawValue, "bit_depth": st.bitDepth.rawValue, "profile": st.profileName,
                                "active": app.activeDocumentID == d.id, "unsaved_changes": d.isDirty, "layer_count": st.allLayers.count]
        if let u = d.fileURL { i["path"] = u.path }
        if let b = st.selectionBounds { i["selection"] = ["x": b.x, "y": b.y, "width": b.width, "height": b.height] }
        if let a = d.activeLayerID { i["active_layer_id"] = a.uuidString }
        if layers { i["layers"] = st.layers.reversed().map { layerJSON(d, $0) } }
        return i
    }

    static func kind(_ l: Layer) -> String {
        switch l.content {
        case .raster: return "pixel"
        case .text: return "text"
        case .shape: return "shape"
        case .smartObject: return "smart_object"
        case .adjustment: return "adjustment"
        case .fill(let f):
            if f.recipe != nil { return "recipe" }
            switch f.paint {
            case .gradient: return "gradient_fill"
            case .pattern: return "pattern_fill"
            default: return "solid_fill"
            }
        case .group: return l.isArtboard ? "artboard" : "group"
        }
    }

    static func effectNames(_ fx: LayerEffects) -> [String] {
        guard fx.enabled else { return [] }
        var n: [String] = []
        if fx.dropShadows.contains(where: \.enabled) { n.append("drop_shadow") }
        if fx.innerShadow.enabled || fx.extraInnerShadows.contains(where: \.enabled) { n.append("inner_shadow") }
        if fx.outerGlow.enabled { n.append("outer_glow") }
        if fx.innerGlow.enabled { n.append("inner_glow") }
        if fx.bevel.enabled { n.append("bevel") }
        if fx.satin.enabled { n.append("satin") }
        if fx.colorOverlay.enabled || fx.extraColorOverlays.contains(where: \.enabled) { n.append("color_overlay") }
        if fx.gradientOverlay.enabled || fx.extraGradientOverlays.contains(where: \.enabled) { n.append("gradient_overlay") }
        if fx.patternOverlay.enabled { n.append("pattern_overlay") }
        if fx.stroke.enabled || fx.extraStrokes.contains(where: \.enabled) { n.append("stroke") }
        return n
    }

    static func layerJSON(_ d: Document, _ l: Layer) -> [String: Any] {
        var i: [String: Any] = ["id": l.id.uuidString, "name": l.name, "kind": kind(l), "visible": l.isVisible,
                                "opacity": (l.opacity * 100).rounded(), "fill_opacity": (l.fillOpacity * 100).rounded(),
                                "blend_mode": l.blendMode.rawValue, "locked": l.locks.all, "clipped": l.isClipped,
                                "has_mask": l.mask != nil, "effects": effectNames(l.effects)]
        if let b = Compositor.shared.contentBounds(l, state: d.state), !b.isNull, !b.isInfinite {
            i["bounds"] = ["x": Double(b.minX).rounded(), "y": Double(b.minY).rounded(), "width": Double(b.width).rounded(), "height": Double(b.height).rounded()]
        }
        if let t = l.text {
            var ti: [String: Any] = ["text": t.text, "font": t.fontName, "size": t.fontSize, "color": "#" + t.color.hex,
                                     "alignment": t.alignment.rawValue, "position": ["x": Double(t.position.x), "y": Double(t.position.y)]]
            if let b = t.boxSize { ti["box"] = ["width": Double(b.width), "height": Double(b.height)] }
            i["text"] = ti
        }
        if let s = l.shape { i["shape"] = s.geometry.kindName.lowercased() }
        if case .adjustment(let s) = l.content { i["adjustment"] = s.kind.rawValue }
        if let so = l.smart { i["smart_filters"] = so.filters.map { $0.kind.rawValue } }
        if l.isGroup { i["children"] = l.children.reversed().map { layerJSON(d, $0) } }
        return i
    }

    // MARK: Images

    static func png(_ cg: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// The image fitted inside max × max (never enlarged).
    static func fit(_ cg: CGImage, max m: Int) -> CGImage {
        let k = min(1, Double(m) / Double(max(cg.width, cg.height)))
        guard k < 0.9999 else { return cg }
        return VideoRenderer.scaled(cg, max(1, Int((Double(cg.width) * k).rounded())), max(1, Int((Double(cg.height) * k).rounded()))) ?? cg
    }
}

/// One undo step per tool call: the history steps a call recorded in each open document are folded into one.
enum MCPUndo {
    typealias Snapshot = [UUID: UUID]   // document id → current history step

    static func snapshot() -> Snapshot {
        var s: Snapshot = [:]
        for d in AppModel.shared.documents { if let e = d.currentHistoryEntryID { s[d.id] = e } }
        return s
    }

    static func fold(_ s: Snapshot, name: String) {
        for d in AppModel.shared.documents {
            guard let base = s[d.id] else { continue }   // documents the call created start with their own history
            d.foldSteps(after: base, name: name)
        }
    }
}

/// Runs tool calls one at a time on the main thread, in arrival order (a call that waits for a confirmation or a
/// generative job holds the next one back).
final class MCPToolRunner {
    static let shared = MCPToolRunner()
    private var pending: [(MCPToolCall, (MCPToolResult) -> Void)] = []
    private var busy = false

    func enqueue(_ call: MCPToolCall, _ done: @escaping (MCPToolResult) -> Void) {
        pending.append((call, done))
        pump()
    }

    private func pump() {
        guard !busy, !pending.isEmpty else { return }
        busy = true
        let (call, done) = pending.removeFirst()
        MCPTools.run(call) { [weak self] result in
            done(result)
            DispatchQueue.main.async {
                self?.busy = false
                self?.pump()
            }
        }
    }
}
