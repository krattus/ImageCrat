import AppKit
import SwiftUI
import ImageIO
import ImageCratCore

/// The local MCP server end to end: `LUMEN_SELFTEST_ONLY=mcp Lumen --selftest <dir>`.
/// Starts the real server on an ephemeral loopback port with an in-memory test token (no Keychain, no preferences,
/// no clipboard) and talks to it over real HTTP with a raw socket client: handshake and version negotiation (both
/// protocol eras), auth / Origin / malformed requests, every tool's schema, an editing session (document, text, shape,
/// filter, adjustment layer, layer style, preview, undo / redo, save and reopen, export, script, brush stroke), the
/// paid-generative refusal and shutdown when the setting is turned off. Headless: no windows.
enum MCPSelfTest {
    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") mcp: \(name)\(d.isEmpty || ok ? "" : " — " + d)")
        fflush(stdout)
    }

    static let token = "selftest-token-\(UUID().uuidString)"
    static var port = 0
    static var session: String?
    static var nextID = 1

    static func run(_ out: URL) {
        passes = 0; failures = 0
        let app = AppModel.shared
        let c = MCPServerController.shared
        let dir = out.appendingPathComponent("mcp")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // the suite starts with no documents (restored afterwards)
        let savedDocs = app.documents, savedActive = app.activeDocumentID
        app.documents = []; app.activeDocumentID = nil
        let savedSettings = c.settings
        defer {
            c.settings.enabled = false
            c.settings = savedSettings
            app.documents = savedDocs; app.activeDocumentID = savedActive
            print("mcp: \(passes) passed, \(failures) failed")
        }

        check(c.ephemeral, "automated run: token and settings stay in memory (no Keychain, no preferences)")
        c.useTestToken(token)
        c.settings.allowPaidGenerative = false
        c.settings.port = 0
        c.settings.enabled = true
        check(wait(10) { c.running && c.listeningPort != nil }, "server starts on an ephemeral port", c.statusError ?? "not running")
        guard let p = c.listeningPort else { return }
        port = p
        check(p > 0 && p != MCPServerController.defaultPort, "listening port \(p) reported")
        check(c.statusLine(clients: 0).contains("Listening on 127.0.0.1:\(p)"), "status line names the address", c.statusLine(clients: 0))
        check(c.setupCommand(token: "T") == "claude mcp add --transport http imagecrat http://127.0.0.1:\(p)/mcp --header \"Authorization: Bearer T\"",
              "Claude Code setup command", c.setupCommand(token: "T"))

        transport()
        handshake()
        toolList()
        errors()
        editingSession(dir)
        generativeRefused()
        externalClients(dir)
        if ProcessInfo.processInfo.environment["LUMEN_SELFTEST_UI"] == "1" { snapshots(out) }

        // turning the setting off stops the server
        c.settings.enabled = false
        check(wait(5) { !c.running }, "setting off: server stops")
        let refused = bg { TestSocket(port: p) == nil } ?? false
        check(refused, "setting off: connections are refused")
    }

    // MARK: - Transport, auth, Origin

    static func transport() {
        let ping: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "ping"]
        var r = send(ping, auth: nil)
        check(r?.status == 401, "no Authorization header → 401", "\(r?.status ?? -1)")
        check(r?.headers["www-authenticate"]?.hasPrefix("Bearer") == true, "401 carries WWW-Authenticate: Bearer")
        r = send(ping, auth: "wrong-token")
        check(r?.status == 401, "wrong token → 401", "\(r?.status ?? -1)")
        r = send(ping, extra: ["Origin": "https://example.com"])
        check(r?.status == 403, "browser Origin → 403", "\(r?.status ?? -1)")
        r = send(ping, extra: ["Host": "attacker.example:\(port)"])
        check(r?.status == 403, "non-loopback Host (DNS rebinding) → 403", "\(r?.status ?? -1)")
        r = send(nil, method: "GET")
        check(r?.status == 405 && r?.headers["allow"]?.contains("POST") == true, "GET /mcp → 405 (no SSE stream)", "\(r?.status ?? -1)")
        r = send(ping, path: "/other")
        check(r?.status == 404, "other paths → 404")
        r = send(Data("{\"jsonrpc\": \"2.0\", \"id\": 1, \"method\": ".utf8))
        check(r?.status == 400 && code(r) == -32700, "malformed JSON → parse error -32700", "\(r?.status ?? -1) \(code(r) ?? 0)")

        // keep-alive: two requests on one connection, written back to back
        let two: [(Int, [String: Any]?)]?? = bg { () -> [(Int, [String: Any]?)]? in
            guard let s = TestSocket(port: port) else { return nil }
            defer { s.close() }
            let req = rawRequest(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
            guard s.write(req + req) else { return nil }
            return (0..<2).compactMap { _ in s.readResponse().map { ($0.status, MCPJSON.parse($0.body) as? [String: Any]) } }
        }
        let two2 = two ?? nil
        check(two2?.count == 2 && two2!.allSatisfy { $0.0 == 200 }, "keep-alive: pipelined requests answered in order", "\(two2?.map(\.0) ?? [])")

        // Expect: 100-continue (curl sends it for large bodies)
        let cont: (Bool, Int)?? = bg { () -> (Bool, Int)? in
            guard let s = TestSocket(port: port) else { return nil }
            defer { s.close() }
            let body = MCPJSON.data(["jsonrpc": "2.0", "id": 5, "method": "initialize", "params": ["protocolVersion": "2025-11-25"]])
            let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nExpect: 100-continue\r\nContent-Length: \(body.count)\r\n\r\n"
            guard s.write(Data(head.utf8)), let interim = s.readResponse(), interim.status == 100, s.write(body), let final = s.readResponse() else { return (false, 0) }
            return (true, final.status)
        }
        let cont2 = cont ?? nil
        check(cont2?.0 == true && cont2?.1 == 200, "Expect: 100-continue handled", "\(String(describing: cont2))")
    }

    // MARK: - Handshake (legacy and modern eras)

    static func handshake() {
        var r = send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                      "params": ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any], "clientInfo": ["name": "mcp-selftest", "version": "1"]]])
        let res = r?.json?["result"] as? [String: Any]
        check(r?.status == 200 && res?["protocolVersion"] as? String == "2025-06-18", "initialize: the client's supported version is accepted")
        check((res?["capabilities"] as? [String: Any])?["tools"] != nil, "initialize: tools capability")
        check(((res?["serverInfo"] as? [String: Any])?["name"] as? String) == "imagecrat", "initialize: serverInfo")
        check((res?["instructions"] as? String)?.isEmpty == false, "initialize: instructions")
        session = r?.headers["mcp-session-id"]
        check(session != nil && session!.count >= 32, "initialize: Mcp-Session-Id issued")
        r = send(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "2099-12-31"]])
        check((r?.json?["result"] as? [String: Any])?["protocolVersion"] as? String == MCPEndpoint.legacyVersions[0],
              "initialize: an unknown version negotiates to \(MCPEndpoint.legacyVersions[0])")
        r = send(["jsonrpc": "2.0", "method": "notifications/initialized"], session: true)
        check(r?.status == 202 && r?.body.isEmpty == true, "notifications/initialized → 202 Accepted")
        r = send(["jsonrpc": "2.0", "id": 3, "method": "ping"], session: true)
        check(r?.status == 200 && (r?.json?["result"] as? [String: Any]) != nil, "ping → {}")
        r = send(["jsonrpc": "2.0", "id": 4, "method": "ping"], extra: ["Mcp-Session-Id": "nope"])
        check(r?.status == 404, "unknown session → 404")
        r = send(["jsonrpc": "2.0", "id": 4, "method": "ping"])
        check(r?.status == 400, "no session and no protocol metadata → 400")

        // modern (2026-07-28): stateless, per-request metadata and headers
        let meta: [String: Any] = ["io.modelcontextprotocol/protocolVersion": "2026-07-28",
                                   "io.modelcontextprotocol/clientInfo": ["name": "mcp-selftest", "version": "1"],
                                   "io.modelcontextprotocol/clientCapabilities": [:] as [String: Any]]
        let mh = ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "server/discover"]
        r = send(["jsonrpc": "2.0", "id": 5, "method": "server/discover", "params": ["_meta": meta]], extra: mh)
        let disc = r?.json?["result"] as? [String: Any]
        check(r?.status == 200 && (disc?["supportedVersions"] as? [String])?.contains("2026-07-28") == true && (disc?["supportedVersions"] as? [String])?.contains("2025-06-18") == true,
              "server/discover lists both protocol eras")
        r = send(["jsonrpc": "2.0", "id": 6, "method": "ping", "params": ["_meta": meta]], extra: ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "ping"])
        check(r?.status == 200 && (r?.json?["result"] as? [String: Any])?["resultType"] as? String == "complete", "modern ping")
        var old = meta; old["io.modelcontextprotocol/protocolVersion"] = "2099-01-01"
        r = send(["jsonrpc": "2.0", "id": 7, "method": "ping", "params": ["_meta": old]], extra: ["MCP-Protocol-Version": "2099-01-01", "Mcp-Method": "ping"])
        check(r?.status == 400 && code(r) == -32022, "unsupported version → UnsupportedProtocolVersionError", "\(r?.status ?? -1) \(code(r) ?? 0)")
        r = send(["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": ["_meta": meta, "name": "list_documents", "arguments": [:] as [String: Any]]],
                 extra: ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "get_history"])
        check(r?.status == 400 && code(r) == -32020, "Mcp-Name header mismatch → HeaderMismatch")
        r = send(["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["_meta": meta, "name": "list_documents", "arguments": [:] as [String: Any]]],
                 extra: ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "list_documents"])
        check(r?.status == 200 && ((r?.json?["result"] as? [String: Any])?["isError"] as? Bool) == false, "modern tools/call")
    }

    // MARK: - Tool list

    static let expectedTools = ["list_documents", "new_document", "open_document", "save_document", "export_image", "close_document", "set_active_document",
                                "get_document_info", "render_preview", "get_selection", "get_history",
                                "add_layer", "set_layer_properties", "delete_layer", "duplicate_layer", "move_layer", "group_layers", "merge_layers", "select_layer",
                                "apply_filter", "list_filters", "apply_adjustment", "list_adjustments", "set_layer_style", "transform_layer",
                                "make_selection", "fill", "crop", "resize_image", "resize_canvas", "undo", "redo",
                                "add_text", "edit_text", "add_shape", "list_fonts", "list_brushes", "paint_stroke",
                                "list_actions", "run_action", "run_script", "remove_background", "select_subject", "generative_fill"]

    static func toolList() {
        let r = send(["jsonrpc": "2.0", "id": 10, "method": "tools/list"], session: true)
        let tools = ((r?.json?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        check(tools.count == MCPTools.all.count && tools.count >= expectedTools.count, "tools/list returns every tool (\(tools.count))")
        let names = Set(tools.compactMap { $0["name"] as? String })
        let missing = expectedTools.filter { !names.contains($0) }
        check(missing.isEmpty, "all required tools are offered", missing.joined(separator: ", "))
        var bad: [String] = []
        for t in tools {
            let n = t["name"] as? String ?? "?"
            if n.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) == nil { bad.append("\(n): name") }
            if (t["description"] as? String)?.count ?? 0 < 20 { bad.append("\(n): description") }
            if (t["title"] as? String)?.isEmpty != false { bad.append("\(n): title") }
            guard let s = t["inputSchema"] as? [String: Any] else { bad.append("\(n): no inputSchema"); continue }
            bad += MCPSchemaValidator.check(s).map { "\(n): \($0)" }
            if (t["annotations"] as? [String: Any])?["readOnlyHint"] == nil { bad.append("\(n): annotations") }
        }
        check(bad.isEmpty, "every tool has a valid JSON Schema, title, description and annotations", bad.prefix(8).joined(separator: "; "))
        let order2 = ((send(["jsonrpc": "2.0", "id": 11, "method": "tools/list"], session: true)?.json?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        check(order2 == tools.compactMap { $0["name"] as? String }, "tool order is deterministic")
    }

    // MARK: - Errors

    static func errors() {
        let r = send(["jsonrpc": "2.0", "id": 12, "method": "tools/call", "params": ["name": "make_coffee", "arguments": [:] as [String: Any]]], session: true)
        check(code(r) == -32602 && message(r).contains("Unknown tool"), "unknown tool → -32602 Unknown tool", message(r))
        check(code(send(["jsonrpc": "2.0", "id": 13, "method": "resources/list"], session: true)) == -32601, "unknown method → -32601")
        var t = call("new_document", ["width": "big", "height": 100])
        check(t.isError && t.text.contains("`width` must be an integer"), "wrong argument type → isError with a helpful message", t.text)
        t = call("new_document", ["height": 100])
        check(t.isError && t.text.contains("missing required argument `width`"), "missing argument → isError naming it", t.text)
        t = call("new_document", ["width": 100, "height": 100, "colour": "red"])
        check(t.isError && t.text.contains("unknown argument `colour`"), "unknown argument → isError listing the valid ones", t.text)
        t = call("get_document_info", [:])
        check(t.isError && t.text.contains("No document is open. Use new_document or open_document first."), "no document → friendly error", t.text)
    }

    // MARK: - Editing session

    static func editingSession(_ dir: URL) {
        let app = AppModel.shared
        var t = call("new_document", ["width": 400, "height": 300, "background": "#FFFFFF", "name": "MCP Test"])
        let docID = (t.structured?["id"] as? String) ?? ""
        check(!t.isError && app.activeDocument?.id.uuidString == docID && app.activeDocument?.state.width == 400, "new_document creates the active document", t.text)
        guard let d = app.activeDocument else { return }

        func steps() -> Int { d.history.count }
        func lastStep() -> String { d.history[d.historyIndex].name }

        var n = steps()
        t = call("add_text", ["text": "Hello MCP", "size": 56, "color": "#D0021B", "position": ["x": 30, "y": 40], "font": "Helvetica"])
        let textID = ((t.structured?["layer"] as? [String: Any])?["id"] as? String) ?? ""
        check(!t.isError && d.state.layer(UUID(uuidString: textID))?.text?.text == "Hello MCP", "add_text adds a live text layer", t.text)
        check(steps() == n + 1 && lastStep() == "MCP: Add Text Layer", "add_text is one undo step named after the tool", lastStep())
        t = call("add_text", ["text": "x", "font": "No Such Font 123"])
        check(t.isError && t.text.contains("not installed"), "unknown font → isError", t.text)

        t = call("add_shape", ["kind": "rect", "bounds": ["x": 200, "y": 150, "width": 150, "height": 110], "fill": "#2E86DE", "corner_radius": 12])
        var shapeID = ((t.structured?["layer"] as? [String: Any])?["id"] as? String) ?? ""
        check(!t.isError && d.state.layer(UUID(uuidString: shapeID))?.shape != nil, "add_shape adds a shape layer", t.text)

        let before = preview(d)
        check(before != nil && before!.width == 400 && before!.height == 300, "render_preview returns a valid PNG of the document")

        n = steps()
        t = call("apply_filter", ["name": "gaussianBlur", "params": ["radius": 6], "layer_id": shapeID, "smart": true])
        shapeID = ((t.structured?["layer"] as? [String: Any])?["id"] as? String) ?? ""   // the smart object that replaced the shape
        let fl = d.state.layer(UUID(uuidString: shapeID) ?? UUID())
        check(!t.isError && fl?.isSmartObject == true && fl?.smart?.filters.contains { $0.kind == .gaussianBlur } == true, "apply_filter (gaussian blur, smart)", t.text)
        check(steps() == n + 1 && lastStep() == "MCP: Apply Filter", "convert + filter fold into one undo step", "\(steps() - n) steps, \(lastStep())")
        t = call("apply_filter", ["name": "gaussianBlur", "params": ["radius": 9999], "layer_id": shapeID])
        check(t.isError && t.text.contains("between 0 and 250"), "filter parameter out of range → isError", t.text)
        t = call("apply_filter", ["name": "gaussianBlur", "params": ["radus": 3]])
        check(t.isError && t.text.contains("radius"), "unknown filter parameter → isError listing the parameters", t.text)
        // a destructive blur on a pixel layer
        t = call("add_layer", ["kind": "pixel", "color": "#000000", "name": "Block"])
        let blockID = ((t.structured?["layer"] as? [String: Any])?["id"] as? String) ?? ""
        _ = call("set_layer_properties", ["layer_id": blockID, "opacity": 40])
        t = call("make_selection", ["mode": "rect", "rect": ["x": 10, "y": 200, "width": 120, "height": 80]])
        check(!t.isError && d.state.selectionBounds?.width == 120, "make_selection rect", t.text)
        t = call("apply_filter", ["name": "Gaussian Blur", "params": ["radius": 4], "layer_id": blockID])
        check(!t.isError && d.state.layer(UUID(uuidString: blockID) ?? UUID())?.isRaster == true, "apply_filter on a pixel layer", t.text)
        _ = call("make_selection", ["mode": "none"])
        check(d.state.selection == nil, "make_selection none")

        t = call("apply_adjustment", ["kind": "hueSaturation", "params": ["hue": 40, "saturation": 25], "as_layer": true])
        let adj = (t.structured?["layer"] as? [String: Any])
        check(!t.isError && adj?["kind"] as? String == "adjustment" && adj?["adjustment"] as? String == "hueSaturation", "apply_adjustment as an adjustment layer", t.text)
        t = call("apply_adjustment", ["kind": "hueSaturation", "params": ["hue": 400]])
        check(t.isError && t.text.contains("hue"), "adjustment parameter out of range → isError", t.text)

        n = steps()
        t = call("set_layer_style", ["layer_id": textID, "drop_shadow": ["distance": 8, "size": 6, "opacity": 70, "color": "#000000"],
                                     "stroke": ["size": 2, "color": "#FFFFFF"]])
        let fx = d.state.layer(UUID(uuidString: textID) ?? UUID())?.effects
        check(!t.isError && fx?.dropShadow.enabled == true && fx?.dropShadow.distance == 8 && fx?.stroke.enabled == true, "set_layer_style (drop shadow + stroke)", t.text)
        check(steps() == n + 1 && lastStep() == "MCP: Set Layer Style", "set_layer_style is one undo step")
        t = call("set_layer_style", ["layer_id": textID, "drop_shadow": ["size": 9999]])
        check(t.isError && t.text.contains("drop_shadow.size"), "effect setting out of range → isError naming it", t.text)

        let after = preview(d)
        check(after != nil && before != nil && pixelDifference(before!, after!) > 0.002, "render_preview: the edits changed the pixels",
              "\(pixelDifference(before ?? after!, after ?? before!))")
        t = call("render_preview", ["max_size": 100, "layer_id": textID])
        check(!t.isError && t.image.map { decode($0)?.width == 100 } == true, "render_preview of one layer, scaled")

        // undo / redo
        t = call("undo", [:])
        check(!t.isError && d.state.layer(UUID(uuidString: textID) ?? UUID())?.effects.dropShadow.enabled == false, "undo reverts the last MCP call", t.text)
        t = call("redo", [:])
        check(!t.isError && d.state.layer(UUID(uuidString: textID) ?? UUID())?.effects.dropShadow.enabled == true, "redo restores it", t.text)
        t = call("get_history", [:])
        check(!t.isError && ((t.structured?["steps"] as? [[String: Any]])?.last?["name"] as? String) == "MCP: Set Layer Style", "get_history lists the MCP steps", t.text)

        t = call("transform_layer", ["layer_id": textID, "rotate": 15, "scale": 110])
        check(!t.isError && lastStep() == "MCP: Transform Layer", "transform_layer", t.text)
        t = call("edit_text", ["layer_id": textID, "text": "Hello again", "size": 40])
        check(!t.isError && d.state.layer(UUID(uuidString: textID) ?? UUID())?.text?.text == "Hello again", "edit_text", t.text)

        // painting
        n = steps()
        let pts = (0...20).map { i -> [String: Any] in ["x": 40 + i * 15, "y": 270, "pressure": 0.3 + Double(i) / 30] }
        t = call("paint_stroke", ["points": pts, "size": 14, "color": "#00AA00", "layer_id": blockID])
        let bl = d.state.layer(UUID(uuidString: blockID) ?? UUID())
        check(!t.isError && steps() == n + 1 && bl?.raster != nil, "paint_stroke paints on the pixel layer in one step", t.text)
        t = call("paint_stroke", ["points": [["x": 1, "y": 1]], "layer_id": textID])
        check(t.isError && t.text.contains("pixel layer"), "paint_stroke on a text layer → isError", t.text)

        // fill, groups, info
        t = call("fill", ["color": "#FFCC00", "layer_id": blockID, "selection": ["x": 0, "y": 0, "width": 40, "height": 40]])
        check(!t.isError && d.state.selection == nil, "fill inside a temporary rectangle (selection restored)", t.text)
        t = call("group_layers", ["layer_ids": [textID, shapeID], "name": "Title"])
        let groupID = ((t.structured?["layer"] as? [String: Any])?["id"] as? String) ?? ""
        check(!t.isError && d.state.layer(UUID(uuidString: groupID) ?? UUID())?.children.count == 2, "group_layers", t.text)
        t = call("get_document_info", [:])
        let layers = (t.structured?["layers"] as? [[String: Any]]) ?? []
        let flat = flatten(layers)
        check(!t.isError && flat.contains { ($0["text"] as? [String: Any])?["text"] as? String == "Hello again" } && flat.contains { ($0["effects"] as? [String])?.contains("drop_shadow") == true },
              "get_document_info: layer tree with text and effects")
        t = call("get_selection", [:])
        check(!t.isError && t.structured?["has_selection"] as? Bool == false, "get_selection")

        // scripting
        n = steps()
        t = call("run_script", ["js": "const d = app.activeDocument; const l = d.addTextLayer('From JS', {size: 24, x: 10, y: 10}); l.opacity = 50; console.log('ok'); d.allLayers.length"])
        check(!t.isError && t.text.contains("ok") && t.text.contains("→"), "run_script runs JavaScript and returns its output", t.text)
        check(steps() == n + 1 && lastStep() == "MCP: Run Script", "run_script's edits are one undo step", "\(steps() - n) \(lastStep())")
        t = call("run_script", ["js": "this is not javascript ("])
        check(t.isError && t.text.contains("Script error"), "run_script syntax error → isError", t.text)
        let scriptFile = dir.appendingPathComponent("from-script.txt")
        t = call("run_script", ["js": "app.writeFile('\(scriptFile.path)', 'written by a script')"])
        check(!t.isError && MCPServerController.shared.lastWrittenFile == scriptFile.path, "files a script writes are reported like the tools'", t.text)

        // save, reopen, export
        let native = dir.appendingPathComponent("mcp-test.\(Brand.documentExtension)"), psd = dir.appendingPathComponent("mcp-test.psd")
        t = call("save_document", ["path": native.path])
        check(!t.isError && FileManager.default.fileExists(atPath: native.path) && !d.isDirty, "save_document .imagecrat", t.text)
        check(MCPServerController.shared.lastWrittenFile == native.path, "written files are reported in the status")
        t = call("save_document", ["path": psd.path, "format": "psd"])
        let magic = (try? Data(contentsOf: psd))?.prefix(4)
        check(!t.isError && magic == Data("8BPS".utf8), "save_document psd", t.text)
        t = call("save_document", ["path": dir.appendingPathComponent("x.png").path, "format": "psd"])
        check(t.isError && t.text.contains("extension"), "format / extension mismatch → isError", t.text)
        let origNames = d.state.allLayers.map(\.name)
        t = call("open_document", ["path": native.path])
        let reopened = app.activeDocument
        check(!t.isError && reopened !== d && reopened?.state.allLayers.map(\.name) == origNames, "open_document of the saved file: layers match",
              "\(reopened?.state.allLayers.map(\.name) ?? []) vs \(origNames)")
        if let r = reopened { _ = call("close_document", ["doc_id": r.id.uuidString]) }
        check(!app.documents.contains { $0 === reopened }, "close_document")
        t = call("set_active_document", ["doc_id": d.id.uuidString])
        let png = dir.appendingPathComponent("mcp-export.png")
        t = call("export_image", ["path": png.path, "size": ["width": 200]])
        let img = (try? Data(contentsOf: png)).flatMap(decode)
        check(!t.isError && img?.width == 200 && img?.height == 150, "export_image png scaled", t.text)
        t = call("open_document", ["path": dir.appendingPathComponent("missing.png").path])
        check(t.isError && t.text.contains("No file"), "open_document of a missing file → isError", t.text)
        t = call("save_document", ["path": "relative/file.png"])
        check(t.isError && t.text.contains("absolute"), "relative paths are refused", t.text)

        // lists
        t = call("list_filters", ["category": "Blur"])
        let gb = (t.structured?["filters"] as? [[String: Any]])?.first { $0["name"] as? String == "gaussianBlur" }
        check(((gb?["params"] as? [[String: Any]])?.first?["max"] as? Double) == 250, "list_filters gives parameter ranges")
        t = call("list_adjustments", [:])
        check(((t.structured?["adjustments"] as? [[String: Any]])?.contains { $0["name"] as? String == "curves" }) == true, "list_adjustments")
        t = call("list_fonts", ["filter": "helvetica", "limit": 3])
        check(!t.isError && ((t.structured?["families"] as? [[String: Any]])?.isEmpty == false), "list_fonts", t.text)
        t = call("list_brushes", ["limit": 5])
        check(!t.isError, "list_brushes", t.text)
        t = call("list_actions", [:])
        check(!t.isError, "list_actions", t.text)
        t = call("run_action", ["name": "No Such Action"])
        check(t.isError && t.text.contains("list_actions"), "run_action of an unknown action → isError", t.text)

        // closing with unsaved changes needs a decision
        _ = call("add_layer", ["kind": "group"])
        t = call("close_document", [:])
        check(t.isError && t.text.contains("unsaved changes") && app.documents.contains { $0 === d }, "close_document refuses to drop unsaved changes", t.text)
        t = call("close_document", ["discard_changes": true])
        check(!t.isError && !app.documents.contains { $0 === d }, "close_document with discard_changes", t.text)
        check(MCPServerController.shared.lastCall == "close_document" && MCPServerController.shared.statusLine(clients: 1).contains("last call: close_document"),
              "status line names the last call", MCPServerController.shared.statusLine(clients: 1))
    }

    static func generativeRefused() {
        _ = call("new_document", ["width": 64, "height": 64])
        _ = call("make_selection", ["mode": "all"])
        let jobs = GenJobs.shared.active.count
        let t = call("generative_fill", ["prompt": "a red balloon"])
        check(t.isError && t.text.contains("Preferences ▸ Integrations"), "generative_fill is refused unless paid calls are allowed", t.text)
        check(GenJobs.shared.active.count == jobs, "no generative job was started")
        _ = call("close_document", ["discard_changes": true])
    }

    // MARK: - UI snapshots (LUMEN_SELFTEST_UI=1; off-screen, never shown)

    static func snapshots(_ out: URL) {
        func snap<V: View>(_ v: V, _ name: String, _ size: CGSize) {
            let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height, alignment: .topLeading).padding(10)
                .background(Theme.panelBG).environment(\.colorScheme, .dark))
            host.frame = CGRect(origin: .zero, size: CGSize(width: size.width + 20, height: size.height + 20))
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
                print("wrote \(name)")
            }
            win.contentView = nil
            win.close()
        }
        snap(MCPPreferencesSection(), "ui_mcp_prefs", CGSize(width: 340, height: 430))
        snap(HStack { MCPStatusChip(tier: .wide); MCPStatusChip(tier: .narrow) }, "ui_mcp_chip", CGSize(width: 220, height: 24))
    }

    // MARK: - External clients

    /// scripts/mcp_smoke.sh (curl) when run from the repository, plus `LUMEN_MCP_EXTERNAL_CHECK` (a shell command, e.g. a
    /// Node script using the official MCP SDK). Both get MCP_URL, IMAGECRAT_MCP_TOKEN and MCP_SMOKE_OUT in the environment.
    static func externalClients(_ dir: URL) {
        var cmds: [(String, String)] = []
        let smoke = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts/mcp_smoke.sh")
        if FileManager.default.isExecutableFile(atPath: smoke.path), FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") {
            cmds.append(("scripts/mcp_smoke.sh (curl) passes", "'\(smoke.path)'"))
        } else {
            print("INFO mcp: scripts/mcp_smoke.sh not found from \(FileManager.default.currentDirectoryPath): curl smoke test skipped")
        }
        if let extra = ProcessInfo.processInfo.environment["LUMEN_MCP_EXTERNAL_CHECK"], !extra.isEmpty { cmds.append(("external MCP client check passes", extra)) }
        for (name, cmd) in cmds {
            let url = "http://127.0.0.1:\(port)/mcp", out = dir.path
            let r = bg(300) { () -> (Int32, String) in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", cmd]
                var env = ProcessInfo.processInfo.environment
                env["MCP_URL"] = url; env["IMAGECRAT_MCP_TOKEN"] = token; env["MCP_SMOKE_OUT"] = out
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { return (-1, "could not start: \(error)") }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return (p.terminationStatus, String(decoding: data, as: UTF8.self))
            }
            let output = r?.1 ?? "timed out"
            for line in output.split(separator: "\n") { print("INFO mcp:   \(line)") }
            check(r?.0 == 0, name, output.split(separator: "\n").filter { $0.hasPrefix("FAIL") }.joined(separator: "; "))
        }
    }

    // MARK: - Helpers

    struct ToolOutcome {
        var isError: Bool
        var text: String
        var structured: [String: Any]?
        var image: Data?
    }

    static func call(_ name: String, _ args: [String: Any]) -> ToolOutcome {
        nextID += 1
        let r = send(["jsonrpc": "2.0", "id": nextID, "method": "tools/call", "params": ["name": name, "arguments": args]], session: true)
        guard let res = r?.json?["result"] as? [String: Any] else {
            return ToolOutcome(isError: true, text: "protocol error: \(message(r)) (HTTP \(r?.status ?? -1))")
        }
        let content = res["content"] as? [[String: Any]] ?? []
        let img = content.first { $0["type"] as? String == "image" }.flatMap { ($0["data"] as? String).flatMap { Data(base64Encoded: $0) } }
        return ToolOutcome(isError: (res["isError"] as? Bool) ?? false, text: content.compactMap { $0["text"] as? String }.joined(separator: "\n"),
                           structured: res["structuredContent"] as? [String: Any], image: img)
    }

    static func preview(_ d: Document) -> CGImage? {
        let t = call("render_preview", ["max_size": 1024, "doc_id": d.id.uuidString])
        guard !t.isError, let data = t.image else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> CGImage? {
        guard data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Mean absolute RGBA difference, 0…1.
    static func pixelDifference(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1 }
        let pa = PixelBuffer(cgImage: a), pb = PixelBuffer(cgImage: b)
        var sum = 0.0, n = 0
        for y in stride(from: 0, to: a.height, by: 2) {
            for x in stride(from: 0, to: a.width, by: 2) {
                let ca = pa.pixel(x, y), cb = pb.pixel(x, y)
                let d = abs(Int(ca.0) - Int(cb.0)) + abs(Int(ca.1) - Int(cb.1)) + abs(Int(ca.2) - Int(cb.2)) + abs(Int(ca.3) - Int(cb.3))
                sum += Double(d) / 255
                n += 4
            }
        }
        return n == 0 ? 0 : sum / Double(n)
    }

    static func flatten(_ layers: [[String: Any]]) -> [[String: Any]] {
        layers.flatMap { [$0] + flatten(($0["children"] as? [[String: Any]]) ?? []) }
    }

    static func code(_ r: HTTPResult?) -> Int? { (r?.json?["error"] as? [String: Any])?["code"] as? Int }
    static func message(_ r: HTTPResult?) -> String { ((r?.json?["error"] as? [String: Any])?["message"] as? String) ?? "" }

    static func wait(_ timeout: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return cond()
    }

    /// Runs `f` on a background thread while the main run loop keeps going (the server runs its tools on the main thread).
    static func bg<T>(_ timeout: Double = 120, _ f: @escaping () -> T) -> T? {
        var result: T?
        var done = false
        DispatchQueue.global(qos: .userInitiated).async {
            let v = f()
            DispatchQueue.main.async { result = v; done = true }
        }
        _ = wait(timeout) { done }
        return result
    }

    struct HTTPResult {
        var status: Int
        var headers: [String: String]
        var body: Data
        var json: [String: Any]? { MCPJSON.parse(body) as? [String: Any] }
    }

    static func rawRequest(_ body: Any?, method: String = "POST", path: String = "/mcp", auth: String? = token, session: Bool = false,
                           extra: [String: String] = [:]) -> Data {
        let data = (body as? Data) ?? body.map { MCPJSON.data($0) } ?? Data()
        var h: [(String, String)] = [("Host", "127.0.0.1:\(port)"), ("Accept", "application/json, text/event-stream")]
        if body != nil { h.append(("Content-Type", "application/json")) }
        if let a = auth { h.append(("Authorization", "Bearer \(a)")) }
        if session, let s = self.session { h.append(("Mcp-Session-Id", s)); h.append(("MCP-Protocol-Version", "2025-06-18")) }
        for (k, v) in extra {
            if let i = h.firstIndex(where: { $0.0.lowercased() == k.lowercased() }) { h[i].1 = v } else { h.append((k, v)) }
        }
        h.append(("Content-Length", "\(data.count)"))
        var head = "\(method) \(path) HTTP/1.1\r\n"
        for (k, v) in h { head += "\(k): \(v)\r\n" }
        return Data((head + "\r\n").utf8) + data
    }

    static func send(_ body: Any?, method: String = "POST", path: String = "/mcp", auth: String? = token, session: Bool = false,
                     extra: [String: String] = [:]) -> HTTPResult? {
        let req = rawRequest(body, method: method, path: path, auth: auth, session: session, extra: extra)
        return bg {
            guard let s = TestSocket(port: port) else { return nil }
            defer { s.close() }
            guard s.write(req) else { return nil }
            return s.readResponse()
        } ?? nil
    }
}

/// A blocking loopback HTTP/1.1 client socket (test only; used off the main thread).
final class TestSocket {
    private let fd: Int32
    private var buffer = Data()

    init?(port: Int) {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var tv = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else { Darwin.close(s); return nil }
        fd = s
    }

    func write(_ d: Data) -> Bool {
        d.withUnsafeBytes { p in
            var off = 0
            while off < d.count {
                let n = Darwin.write(fd, p.baseAddress! + off, d.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }

    /// One response (an interim "100 Continue" counts as one).
    func readResponse() -> MCPSelfTest.HTTPResult? {
        let sep = Data("\r\n\r\n".utf8)
        while buffer.range(of: sep) == nil { guard fill() else { return nil } }
        let r = buffer.range(of: sep)!
        guard let head = String(data: buffer[buffer.startIndex..<r.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { return nil }
        var headers: [String: String] = [:]
        for l in lines { if let c = l.firstIndex(of: ":") { headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces) } }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = r.upperBound
        while buffer.count - (bodyStart - buffer.startIndex) < length { guard fill() else { return nil } }
        let body = buffer[bodyStart..<(bodyStart + length)]
        buffer = Data(buffer[(bodyStart + length)...])
        return MCPSelfTest.HTTPResult(status: status, headers: headers, body: Data(body))
    }

    func close() { Darwin.close(fd) }
}
