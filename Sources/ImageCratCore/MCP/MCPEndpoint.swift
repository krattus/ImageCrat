import Foundation

// The protocol side of ImageCrat's local MCP server (Streamable HTTP, docs/MCP.md): request checks (path, Origin,
// Host, bearer token), JSON-RPC 2.0, version negotiation for both protocol eras, sessions, tools/list and tools/call
// with argument validation. Transport-independent and Foundation-only; the app feeds it parsed HTTP requests from its
// loopback listener and runs the tools.
//
// Protocol eras (modelcontextprotocol.io/specification/2026-07-28/basic/versioning):
// - modern (2026-07-28): every request carries `_meta["io.modelcontextprotocol/protocolVersion"]` (mirrored in the
//   MCP-Protocol-Version header, plus Mcp-Method / Mcp-Name), no handshake, no sessions, `server/discover`;
// - legacy (2025-11-25 and earlier): `initialize` handshake, `notifications/initialized`, `Mcp-Session-Id` sessions.
// This endpoint is dual-era: a request with modern `_meta` is served statelessly, `initialize` opens a legacy session.

package struct MCPToolDescriptor {
    package var name: String
    package var title: String
    package var description: String
    package var inputSchema: [String: Any]
    /// readOnlyHint / destructiveHint / idempotentHint / openWorldHint.
    package var annotations: [String: Any]

    package init(name: String, title: String, description: String, inputSchema: [String: Any], annotations: [String: Any] = [:]) {
        self.name = name; self.title = title; self.description = description; self.inputSchema = inputSchema; self.annotations = annotations
    }

    package var json: [String: Any] {
        var a = annotations
        a["title"] = title
        return ["name": name, "title": title, "description": description, "inputSchema": inputSchema, "annotations": a]
    }
}

package struct MCPToolCall {
    package var name: String
    package var arguments: [String: Any]
    /// "claude-code 2.1.0" (clientInfo) when known.
    package var client: String
    package var protocolVersion: String
}

package struct MCPToolResult {
    /// MCP content blocks ({"type": "text", "text": …}, {"type": "image", "data": base64, "mimeType": "image/png"}).
    package var content: [[String: Any]]
    package var structured: Any?
    package var isError: Bool

    package init(content: [[String: Any]], structured: Any? = nil, isError: Bool = false) {
        self.content = content; self.structured = structured; self.isError = isError
    }

    package static func text(_ s: String, structured: Any? = nil) -> MCPToolResult {
        MCPToolResult(content: [["type": "text", "text": s]], structured: structured)
    }

    package static func error(_ s: String) -> MCPToolResult {
        MCPToolResult(content: [["type": "text", "text": s]], isError: true)
    }

    package static func image(png: Data, caption: String? = nil, structured: Any? = nil) -> MCPToolResult {
        var c: [[String: Any]] = [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]
        if let t = caption { c.append(["type": "text", "text": t]) }
        return MCPToolResult(content: c, structured: structured)
    }

    package func json(modern: Bool) -> [String: Any] {
        var r: [String: Any] = ["content": content, "isError": isError]
        if let s = structured { r["structuredContent"] = s }
        if modern { r["resultType"] = "complete" }
        return r
    }

    /// The text blocks joined (tests, logs).
    package var text: String { content.compactMap { $0["text"] as? String }.joined(separator: "\n") }
}

package final class MCPEndpoint {
    package static let modernVersions = ["2026-07-28"]
    package static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    package static var supportedVersions: [String] { modernVersions + legacyVersions }
    package static let path = "/mcp"
    static let metaVersion = "io.modelcontextprotocol/protocolVersion"
    static let metaClientInfo = "io.modelcontextprotocol/clientInfo"
    static let metaServerInfo = "io.modelcontextprotocol/serverInfo"

    // JSON-RPC / MCP error codes
    package static let parseError = -32700, invalidRequest = -32600, methodNotFound = -32601, invalidParams = -32602, internalError = -32603
    package static let headerMismatch = -32020, unsupportedVersion = -32022

    package struct ServerInfo {
        package var name: String, title: String, version: String, instructions: String
        package init(name: String, title: String, version: String, instructions: String) {
            self.name = name; self.title = title; self.version = version; self.instructions = instructions
        }
    }

    /// What happened, for the status line and the log (called on the caller's thread).
    package enum Event {
        case sessionOpened(client: String, version: String)
        case sessionClosed
        case request(method: String, client: String)
        case toolCall(name: String, client: String)
        case rejected(status: Int, reason: String)
    }

    private struct Session { var version: String; var client: String; var initialized = false; var lastSeen: Date }

    private let lock = NSLock()
    private var _token: String
    private var _tools: [MCPToolDescriptor] = []
    private var sessions: [String: Session] = [:]
    private var modernClients: [String: Date] = [:]
    package let info: ServerInfo
    /// Runs a tool (validated arguments). Must call the completion exactly once, on any thread.
    package var executor: ((MCPToolCall, @escaping (MCPToolResult) -> Void) -> Void)?
    package var onEvent: ((Event) -> Void)?

    package init(token: String, info: ServerInfo, tools: [MCPToolDescriptor] = []) {
        _token = token
        self.info = info
        _tools = tools
    }

    package var token: String {
        get { lock.lock(); defer { lock.unlock() }; return _token }
        set { lock.lock(); _token = newValue; lock.unlock() }
    }

    package var tools: [MCPToolDescriptor] {
        get { lock.lock(); defer { lock.unlock() }; return _tools }
        set { lock.lock(); _tools = newValue; lock.unlock() }
    }

    /// Clients seen within `window` seconds: open legacy sessions plus modern clients (by clientInfo).
    package func activeClients(within window: TimeInterval = 600, now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.filter { now.timeIntervalSince($0.lastSeen) < window }.count
            + modernClients.values.filter { now.timeIntervalSince($0) < window }.count
    }

    package var sessionCount: Int { lock.lock(); defer { lock.unlock() }; return sessions.count }

    // MARK: - HTTP

    /// Answers one HTTP request. `reply` is called exactly once (possibly later, on another thread, for tool calls).
    package func handle(_ req: MCPHTTPRequest, reply: @escaping (MCPHTTPResponse) -> Void) {
        func reject(_ status: Int, _ message: String, headers: [(String, String)] = []) {
            onEvent?(.rejected(status: status, reason: message))
            reply(.json(status, MCPEndpoint.errorObject(id: nil, code: MCPEndpoint.invalidRequest, message: message), headers: headers))
        }
        let path = req.path.count > 1 && req.path.hasSuffix("/") ? String(req.path.dropLast()) : req.path
        guard path == MCPEndpoint.path else {
            return reject(404, "Not found. The MCP endpoint is \(MCPEndpoint.path).")
        }
        // DNS rebinding / drive-by requests from web pages: a browser always sends Origin on these requests
        if let origin = req.header("origin") {
            return reject(403, "Requests from web pages are not accepted (Origin: \(origin)). Use an MCP client such as Claude Code.")
        }
        if let host = req.header("host"), !MCPEndpoint.isLoopbackHost(host) {
            return reject(403, "Host \(host) is not allowed: the server only answers on 127.0.0.1 / localhost.")
        }
        guard authorized(req.header("authorization")) else {
            let msg = req.header("authorization") == nil
                ? "Missing Authorization header. Send “Authorization: Bearer <token>” with the token from ImageCrat ▸ Preferences ▸ Integrations."
                : "Invalid token. Copy the current token (or the setup command) from ImageCrat ▸ Preferences ▸ Integrations."
            return reject(401, msg, headers: [("WWW-Authenticate", "Bearer realm=\"ImageCrat MCP\"")])
        }
        switch req.method {
        case "POST": break
        case "DELETE":
            // legacy sessions end with DELETE
            guard let sid = req.header("mcp-session-id") else { return reject(400, "DELETE needs an Mcp-Session-Id header.") }
            lock.lock(); let existed = sessions.removeValue(forKey: sid) != nil; lock.unlock()
            if existed { onEvent?(.sessionClosed); return reply(.empty(204)) }
            return reject(404, "Unknown or expired session.")
        default:
            // no standalone SSE stream (GET) and no CORS (OPTIONS)
            return reply(MCPHTTPResponse.json(405, MCPEndpoint.errorObject(id: nil, code: MCPEndpoint.invalidRequest,
                                                                            message: "Method \(req.method) is not allowed. Send JSON-RPC messages with POST."),
                                              headers: [("Allow", "POST, DELETE")]))
        }
        if let ct = req.header("content-type"), !ct.lowercased().contains("application/json") {
            return reject(415, "Content-Type must be application/json.")
        }
        if let accept = req.header("accept")?.lowercased(),
           !(accept.contains("application/json") || accept.contains("*/*") || accept.contains("application/*") || accept.contains("text/event-stream")) {
            return reject(406, "The client must accept application/json.")
        }
        guard let message = MCPJSON.parse(req.body) else {
            let e = MCPEndpoint.errorObject(id: nil, code: MCPEndpoint.parseError, message: "Parse error: the request body is not valid JSON.")
            onEvent?(.rejected(status: 400, reason: "parse error"))
            return reply(.json(400, e))
        }
        if let batch = message as? [Any] {
            guard !batch.isEmpty else { return reply(.json(400, MCPEndpoint.errorObject(id: nil, code: MCPEndpoint.invalidRequest, message: "Empty batch."))) }
            runBatch(batch, req, index: 0, collected: [], headers: []) { bodies, headers in
                reply(bodies.isEmpty ? .empty(202, headers: headers) : .json(200, bodies, headers: headers))
            }
            return
        }
        handleMessage(message, req, batched: false) { status, body, headers in
            reply(body.map { MCPHTTPResponse.json(status, $0, headers: headers) } ?? .empty(status, headers: headers))
        }
    }

    private func runBatch(_ items: [Any], _ req: MCPHTTPRequest, index: Int, collected: [Any], headers: [(String, String)],
                          done: @escaping ([Any], [(String, String)]) -> Void) {
        guard index < items.count else { return done(collected, headers) }
        handleMessage(items[index], req, batched: true) { [self] _, body, h in
            runBatch(items, req, index: index + 1, collected: collected + (body.map { [$0] } ?? []), headers: headers + h, done: done)
        }
    }

    // MARK: - JSON-RPC

    private typealias Done = (_ status: Int, _ body: Any?, _ headers: [(String, String)]) -> Void

    private func handleMessage(_ message: Any, _ req: MCPHTTPRequest, batched: Bool, done: @escaping Done) {
        guard let msg = message as? [String: Any], (msg["jsonrpc"] as? String) == "2.0" else {
            return done(400, MCPEndpoint.errorObject(id: nil, code: MCPEndpoint.invalidRequest, message: "Invalid Request: expected a JSON-RPC 2.0 object."), [])
        }
        let id = msg["id"]
        guard let method = msg["method"] as? String else {
            // a JSON-RPC response from the client: this server never sends requests, nothing to do
            if msg["result"] != nil || msg["error"] != nil { return done(202, nil, []) }
            return done(400, MCPEndpoint.errorObject(id: id, code: MCPEndpoint.invalidRequest, message: "Invalid Request: no method."), [])
        }
        if let i = id, !(i is String || MCPJSON.isNumber(i)) {
            return done(400, MCPEndpoint.errorObject(id: nil, code: MCPEndpoint.invalidRequest, message: "Invalid Request: id must be a string or a number."), [])
        }
        let isNotification = id == nil
        let params = msg["params"] as? [String: Any] ?? [:]
        if msg["params"] != nil && !(msg["params"] is [String: Any]) {
            return done(isNotification ? 400 : 200, MCPEndpoint.errorObject(id: id, code: MCPEndpoint.invalidParams, message: "params must be an object."), [])
        }
        let meta = params["_meta"] as? [String: Any]
        if method != "initialize", let version = meta?[MCPEndpoint.metaVersion] as? String {
            if batched { return done(400, MCPEndpoint.errorObject(id: id, code: MCPEndpoint.invalidRequest, message: "Batches are not part of protocol \(version)."), []) }
            return handleModern(method, id: id, params: params, meta: meta ?? [:], version: version, req, done: done)
        }
        handleLegacy(method, id: id, params: params, req, done: done)
    }

    // MARK: Modern (stateless, per-request metadata)

    private func handleModern(_ method: String, id: Any?, params: [String: Any], meta: [String: Any], version: String,
                              _ req: MCPHTTPRequest, done: @escaping Done) {
        func mismatch(_ m: String) { onEvent?(.rejected(status: 400, reason: m)); done(400, MCPEndpoint.errorObject(id: id, code: MCPEndpoint.headerMismatch, message: "Header mismatch: " + m), []) }
        guard let hv = req.header("mcp-protocol-version") else { return mismatch("the MCP-Protocol-Version header is missing.") }
        guard hv == version else { return mismatch("MCP-Protocol-Version header '\(hv)' does not match _meta version '\(version)'.") }
        guard MCPEndpoint.modernVersions.contains(version) else {
            onEvent?(.rejected(status: 400, reason: "unsupported version \(version)"))
            return done(400, MCPEndpoint.errorObject(id: id, code: MCPEndpoint.unsupportedVersion, message: "Unsupported protocol version",
                                                     data: ["supported": MCPEndpoint.supportedVersions, "requested": version]), [])
        }
        if id == nil { return done(202, nil, []) }   // no client notifications are defined for this revision: accept and ignore
        guard let mh = req.header("mcp-method") else { return mismatch("the Mcp-Method header is missing.") }
        guard mh == method else { return mismatch("Mcp-Method header '\(mh)' does not match body method '\(method)'.") }
        if ["tools/call", "resources/read", "prompts/get"].contains(method) {
            let bodyName = (params["name"] as? String) ?? (params["uri"] as? String) ?? ""
            guard let nh = req.header("mcp-name") else { return mismatch("the Mcp-Name header is missing.") }
            guard MCPEndpoint.decodeHeaderValue(nh) == bodyName else { return mismatch("Mcp-Name header value '\(nh)' does not match body value '\(bodyName)'.") }
        }
        let client = MCPEndpoint.clientName(meta[MCPEndpoint.metaClientInfo])
        lock.lock(); modernClients[client] = Date(); lock.unlock()
        onEvent?(.request(method: method, client: client))
        switch method {
        case "server/discover":
            done(200, MCPEndpoint.resultObject(id: id, [
                "resultType": "complete",
                "supportedVersions": MCPEndpoint.supportedVersions,
                "capabilities": ["tools": ["listChanged": false]],
                "_meta": [MCPEndpoint.metaServerInfo: serverInfoJSON],
                "instructions": info.instructions,
            ]), [])
        case "ping":
            done(200, MCPEndpoint.resultObject(id: id, ["resultType": "complete"]), [])
        case "tools/list":
            listTools(id: id, params: params, modern: true, done: done)
        case "tools/call":
            callTool(id: id, params: params, client: client, version: version, modern: true, done: done)
        default:
            done(404, MCPEndpoint.errorObject(id: id, code: MCPEndpoint.methodNotFound, message: "Method not found: \(method)"), [])
        }
    }

    // MARK: Legacy (initialize handshake, sessions)

    private func handleLegacy(_ method: String, id: Any?, params: [String: Any], _ req: MCPHTTPRequest, done: @escaping Done) {
        if method == "initialize" {
            guard let id else { return done(400, MCPEndpoint.errorObject(id: nil, code: MCPEndpoint.invalidRequest, message: "initialize must be a request (with an id)."), []) }
            guard let requested = params["protocolVersion"] as? String else {
                return done(200, MCPEndpoint.errorObject(id: id, code: MCPEndpoint.invalidParams, message: "initialize needs params.protocolVersion.",
                                                         data: ["supported": MCPEndpoint.supportedVersions]), [])
            }
            // the client's version when this server speaks it, otherwise the newest legacy version (the client decides)
            let version = MCPEndpoint.legacyVersions.contains(requested) ? requested : MCPEndpoint.legacyVersions[0]
            let client = MCPEndpoint.clientName(params["clientInfo"])
            let sid = MCPEndpoint.newSessionID()
            lock.lock()
            sessions[sid] = Session(version: version, client: client, lastSeen: Date())
            // forget sessions nobody used for a day (clients that never sent DELETE)
            let stale = sessions.filter { Date().timeIntervalSince($0.value.lastSeen) > 86_400 }.map(\.key)
            for k in stale { sessions.removeValue(forKey: k) }
            lock.unlock()
            onEvent?(.sessionOpened(client: client, version: version))
            var serverInfo = serverInfoJSON
            serverInfo["title"] = info.title
            return done(200, MCPEndpoint.resultObject(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": serverInfo,
                "instructions": info.instructions,
            ]), [("Mcp-Session-Id", sid)])
        }
        guard let sid = req.header("mcp-session-id") else {
            return done(400, MCPEndpoint.errorObject(id: id, code: MCPEndpoint.invalidRequest,
                                                     message: "Missing Mcp-Session-Id header: send initialize first (or use protocol version \(MCPEndpoint.modernVersions[0]) with per-request _meta)."), [])
        }
        lock.lock()
        let session = sessions[sid]
        if session != nil { sessions[sid]?.lastSeen = Date() }
        lock.unlock()
        guard let session else {
            return done(404, MCPEndpoint.errorObject(id: id, code: MCPEndpoint.invalidRequest, message: "Unknown or expired session: initialize again."), [])
        }
        if let hv = req.header("mcp-protocol-version"), !MCPEndpoint.legacyVersions.contains(hv) {
            return done(400, MCPEndpoint.errorObject(id: id, code: MCPEndpoint.invalidRequest,
                                                     message: "Unsupported MCP-Protocol-Version '\(hv)' for this session (negotiated \(session.version))."), [])
        }
        if id == nil {
            if method == "notifications/initialized" { lock.lock(); sessions[sid]?.initialized = true; lock.unlock() }
            return done(202, nil, [])   // notifications/initialized, notifications/cancelled, …
        }
        onEvent?(.request(method: method, client: session.client))
        switch method {
        case "ping":
            done(200, MCPEndpoint.resultObject(id: id, [:]), [])
        case "tools/list":
            listTools(id: id, params: params, modern: false, done: done)
        case "tools/call":
            callTool(id: id, params: params, client: session.client, version: session.version, modern: false, done: done)
        default:
            done(200, MCPEndpoint.errorObject(id: id, code: MCPEndpoint.methodNotFound, message: "Method not found: \(method)"), [])
        }
    }

    // MARK: Tools

    private func listTools(id: Any?, params: [String: Any], modern: Bool, done: @escaping Done) {
        if let c = params["cursor"], !(c is NSNull), (c as? String)?.isEmpty != true {
            return done(200, MCPEndpoint.errorObject(id: id, code: MCPEndpoint.invalidParams, message: "Invalid cursor: the tool list has a single page."), [])
        }
        var r: [String: Any] = ["tools": tools.map(\.json)]
        if modern { r["resultType"] = "complete" }
        done(200, MCPEndpoint.resultObject(id: id, r), [])
    }

    private func callTool(id: Any?, params: [String: Any], client: String, version: String, modern: Bool, done: @escaping Done) {
        guard let name = params["name"] as? String, !name.isEmpty else {
            return done(200, MCPEndpoint.errorObject(id: id, code: MCPEndpoint.invalidParams, message: "tools/call needs params.name (a tool name from tools/list)."), [])
        }
        let all = tools
        guard let tool = all.first(where: { $0.name == name }) else {
            let near = all.map(\.name).filter { $0.contains(name) || name.contains($0) }.prefix(3)
            return done(200, MCPEndpoint.errorObject(id: id, code: MCPEndpoint.invalidParams,
                                                     message: "Unknown tool: \(name)." + (near.isEmpty ? "" : " Did you mean \(near.joined(separator: ", "))?")
                                                        + " Call tools/list for the \(all.count) available tools."), [])
        }
        var args: [String: Any] = [:]
        if let a = params["arguments"], !(a is NSNull) {
            guard let o = a as? [String: Any] else {
                return done(200, MCPEndpoint.errorObject(id: id, code: MCPEndpoint.invalidParams, message: "params.arguments must be an object."), [])
            }
            args = o
        }
        onEvent?(.toolCall(name: name, client: client))
        let problems = MCPSchemaValidator.validate(args, tool.inputSchema)
        if !problems.isEmpty {
            let required = (tool.inputSchema["required"] as? [String]) ?? []
            let props = ((tool.inputSchema["properties"] as? [String: Any]) ?? [:]).keys.sorted()
            var text = "Invalid arguments for \(name): " + problems.joined(separator: " ")
            if !props.isEmpty {
                text += "\nArguments: " + props.map { required.contains($0) ? "\($0) (required)" : $0 }.joined(separator: ", ") + "."
            }
            return done(200, MCPEndpoint.resultObject(id: id, MCPToolResult.error(text).json(modern: modern)), [])
        }
        guard let exec = executor else {
            return done(200, MCPEndpoint.resultObject(id: id, MCPToolResult.error("ImageCrat is not ready to run tools.").json(modern: modern)), [])
        }
        exec(MCPToolCall(name: name, arguments: args, client: client, protocolVersion: version)) { result in
            done(200, MCPEndpoint.resultObject(id: id, result.json(modern: modern)), [])
        }
    }

    private var serverInfoJSON: [String: Any] { ["name": info.name, "version": info.version] }

    // MARK: - Helpers

    package static func errorObject(id: Any?, code: Int, message: String, data: Any? = nil) -> [String: Any] {
        var e: [String: Any] = ["code": code, "message": message]
        if let d = data { e["data"] = d }
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": e]
    }

    package static func resultObject(id: Any?, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    /// "Bearer <token>", compared in constant time.
    package func authorized(_ header: String?) -> Bool {
        let expected = token
        guard !expected.isEmpty, let h = header?.trimmingCharacters(in: .whitespaces), h.count > 7,
              h.prefix(7).lowercased() == "bearer " else { return false }
        let given = Array(h.dropFirst(7).trimmingCharacters(in: .whitespaces).utf8), want = Array(expected.utf8)
        var diff = given.count ^ want.count
        for i in 0..<want.count { diff |= Int(want[i] ^ (i < given.count ? given[i] : 0)) }
        return diff == 0
    }

    package static func isLoopbackHost(_ host: String) -> Bool {
        var h = host.lowercased().trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("[") { h = String(h.prefix { $0 != "]" }.dropFirst()) }
        else if let c = h.lastIndex(of: ":") { h = String(h[..<c]) }
        return h == "127.0.0.1" || h == "localhost" || h == "::1"
    }

    /// Mcp-Name / Mcp-Param values may be sent as "=?base64?…?=".
    package static func decodeHeaderValue(_ v: String) -> String {
        guard v.hasPrefix("=?base64?"), v.hasSuffix("?="), v.count >= 11 else { return v }
        let b = String(v.dropFirst(9).dropLast(2))
        guard let d = Data(base64Encoded: b), let s = String(data: d, encoding: .utf8) else { return v }
        return s
    }

    static func clientName(_ info: Any?) -> String {
        guard let o = info as? [String: Any], let n = o["name"] as? String else { return "MCP client" }
        if let v = o["version"] as? String, !v.isEmpty { return "\(n) \(v)" }
        return n
    }

    /// 128 random bits as hex (visible ASCII, as the session header requires).
    package static func newSessionID() -> String {
        (0..<2).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }.joined().prefix(32).description
    }

    /// A random 32-byte token, URL-safe base64 without padding (43 characters).
    package static func newToken() -> String {
        var g = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &g) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The command that registers this server with Claude Code.
    package static func claudeSetupCommand(port: Int, token: String, name: String = "imagecrat") -> String {
        "claude mcp add --transport http \(name) http://127.0.0.1:\(port)\(path) --header \"Authorization: Bearer \(token)\""
    }
}
