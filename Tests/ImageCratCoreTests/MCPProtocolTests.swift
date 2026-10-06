import Foundation
import XCTest
import ImageCratCore

/// The MCP endpoint's protocol logic (docs/MCP.md) without a socket: HTTP parsing, schema validation, both protocol
/// eras, auth / Origin / Host checks. The app's `mcp` self test covers the same over real loopback HTTP.
final class MCPProtocolTests: XCTestCase {
    private let token = "test-token-0123456789"

    private func endpoint() -> MCPEndpoint {
        let e = MCPEndpoint(token: token, info: .init(name: "imagecrat", title: "ImageCrat", version: "1.0", instructions: "Test."))
        e.tools = [MCPToolDescriptor(name: "echo", title: "Echo", description: "Echoes text.",
                                     inputSchema: MCPSchema.object(["text": MCPSchema.string("Text to echo.", minLength: 1),
                                                                    "times": MCPSchema.integer("Repeat count.", min: 1, max: 3)], required: ["text"]))]
        e.executor = { call, done in
            let n = (call.arguments["times"] as? NSNumber)?.intValue ?? 1
            done(.text(Array(repeating: call.arguments["text"] as? String ?? "", count: n).joined(separator: " ")))
        }
        return e
    }

    private func post(_ e: MCPEndpoint, _ body: Any, headers: [String: String] = [:], auth: Bool = true) -> (Int, [String: Any]?, MCPHTTPResponse) {
        var h = ["content-type": "application/json", "accept": "application/json, text/event-stream", "host": "127.0.0.1:47800"]
        if auth { h["authorization"] = "Bearer \(token)" }
        for (k, v) in headers { h[k] = v }
        let data = (body as? Data) ?? MCPJSON.data(body)
        var out: MCPHTTPResponse?
        e.handle(MCPHTTPRequest(method: "POST", path: "/mcp", headers: h, body: data)) { out = $0 }
        let r = out!
        return (r.status, MCPJSON.parse(r.body) as? [String: Any], r)
    }

    private func modern(_ method: String, id: Int = 1, params: [String: Any] = [:]) -> (Any, [String: String]) {
        var p = params
        p["_meta"] = ["io.modelcontextprotocol/protocolVersion": "2026-07-28",
                      "io.modelcontextprotocol/clientInfo": ["name": "test", "version": "1"], "io.modelcontextprotocol/clientCapabilities": [:] as [String: Any]]
        var h = ["mcp-protocol-version": "2026-07-28", "mcp-method": method]
        if let n = params["name"] as? String { h["mcp-name"] = n }
        return (["jsonrpc": "2.0", "id": id, "method": method, "params": p] as [String: Any], h)
    }

    func testHTTPParser() {
        let raw = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\nAuthorization: Bearer x\r\n\r\n{}"
        guard case .request(let r, let n) = MCPHTTP.parse(Data(raw.utf8)) else { return XCTFail("not parsed") }
        XCTAssertEqual(r.method, "POST"); XCTAssertEqual(r.path, "/mcp"); XCTAssertEqual(r.header("AUTHORIZATION"), "Bearer x")
        XCTAssertEqual(r.body, Data("{}".utf8)); XCTAssertEqual(n, raw.utf8.count)
        guard case .needMore(let cont) = MCPHTTP.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n{".utf8)) else { return XCTFail() }
        XCTAssertTrue(cont)
        guard case .needMore = MCPHTTP.parse(Data("POST /mcp HTTP/1.1\r\nHost".utf8)) else { return XCTFail() }
        guard case .invalid(let s, _) = MCPHTTP.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(s, 413)
        guard case .invalid(let s2, _) = MCPHTTP.parse(Data("garbage\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(s2, 400)
        let resp = MCPHTTPResponse.json(200, ["a": 1]).serialized(keepAlive: true)
        let text = String(decoding: resp, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n")); XCTAssertTrue(text.contains("Content-Length: 7\r\n")); XCTAssertTrue(text.hasSuffix("{\"a\":1}"))
    }

    func testSchemaValidation() {
        let s = MCPSchema.object(["size": MCPSchema.number("Size.", min: 1, max: 100), "kind": MCPSchema.string("Kind.", oneOf: ["a", "b"]),
                                  "on": MCPSchema.boolean("On."), "c": MCPSchema.color("Colour."),
                                  "pts": MCPSchema.array("Points.", items: MCPSchema.point("A point."), minItems: 1)], required: ["size"])
        XCTAssertTrue(MCPSchemaValidator.check(s).isEmpty, "\(MCPSchemaValidator.check(s))")
        XCTAssertTrue(MCPSchemaValidator.validate(["size": 5, "kind": "a", "on": true, "c": "#FF0000", "pts": [["x": 1, "y": 2]]], s).isEmpty)
        XCTAssertTrue(MCPSchemaValidator.validate(["size": 5, "c": [255, 0, 0]], s).isEmpty)
        let e1 = MCPSchemaValidator.validate(["size": "big"], s).joined()
        XCTAssertTrue(e1.contains("`size` must be a number"), e1)
        XCTAssertTrue(MCPSchemaValidator.validate([:] as [String: Any], s).joined().contains("missing required argument `size`"))
        XCTAssertTrue(MCPSchemaValidator.validate(["size": 500], s).joined().contains("≤ 100"))
        XCTAssertTrue(MCPSchemaValidator.validate(["size": 5, "kind": "z"], s).joined().contains("one of"))
        XCTAssertTrue(MCPSchemaValidator.validate(["size": 5, "bogus": 1], s).joined().contains("unknown argument `bogus`"))
        XCTAssertTrue(MCPSchemaValidator.validate(["size": 5, "on": 1], s).joined().contains("boolean"))
        XCTAssertTrue(MCPSchemaValidator.validate(["size": 5, "pts": [["x": 1]]], s).joined().contains("pts[0].y"))
        XCTAssertFalse(MCPSchemaValidator.validate(["size": 5, "c": 7], s).isEmpty)
        XCTAssertFalse(MCPSchemaValidator.check(["type": "object", "properties": ["x": ["type": "strng", "description": "x"]]]).isEmpty)
        XCTAssertFalse(MCPSchemaValidator.check(["type": "object", "properties": ["x": ["type": "string"]]]).isEmpty, "no description")
        XCTAssertFalse(MCPSchemaValidator.check(["type": "object", "properties": [:] as [String: Any], "required": ["y"]]).isEmpty)
    }

    func testAuthOriginHost() {
        let e = endpoint()
        let ping: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "ping"]
        XCTAssertEqual(post(e, ping, auth: false).0, 401)
        XCTAssertEqual(post(e, ping, headers: ["authorization": "Bearer wrong"], auth: false).0, 401)
        XCTAssertEqual(post(e, ping, headers: ["authorization": "Bearer \(token)x"], auth: false).0, 401)
        XCTAssertEqual(post(e, ping, auth: false).2.header("WWW-Authenticate")?.hasPrefix("Bearer"), true)
        XCTAssertEqual(post(e, ping, headers: ["origin": "https://evil.example"]).0, 403)
        XCTAssertEqual(post(e, ping, headers: ["host": "evil.example:47800"]).0, 403)
        XCTAssertTrue(MCPEndpoint.isLoopbackHost("localhost:1")); XCTAssertTrue(MCPEndpoint.isLoopbackHost("[::1]:47800"))
        var out: MCPHTTPResponse?
        e.handle(MCPHTTPRequest(method: "GET", path: "/mcp", headers: ["authorization": "Bearer \(token)"])) { out = $0 }
        XCTAssertEqual(out?.status, 405)
        e.handle(MCPHTTPRequest(method: "POST", path: "/other", headers: ["authorization": "Bearer \(token)"])) { out = $0 }
        XCTAssertEqual(out?.status, 404)
    }

    func testLegacyHandshake() throws {
        let e = endpoint()
        let (s, body, resp) = post(e, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                       "params": ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any], "clientInfo": ["name": "t", "version": "1"]]])
        XCTAssertEqual(s, 200)
        let result = try XCTUnwrap(body?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        let sid = try XCTUnwrap(resp.header("Mcp-Session-Id"))
        // an unknown version negotiates down to the newest legacy one
        let other = post(e, ["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        XCTAssertEqual((other.1?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        let h = ["mcp-session-id": sid, "mcp-protocol-version": "2025-06-18"]
        XCTAssertEqual(post(e, ["jsonrpc": "2.0", "method": "notifications/initialized"], headers: h).0, 202)
        XCTAssertNotNil(post(e, ["jsonrpc": "2.0", "id": 3, "method": "ping"], headers: h).1?["result"])
        let list = post(e, ["jsonrpc": "2.0", "id": 4, "method": "tools/list"], headers: h).1
        XCTAssertEqual(((list?["result"] as? [String: Any])?["tools"] as? [Any])?.count, 1)
        let call = post(e, ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "echo", "arguments": ["text": "hi", "times": 2]]], headers: h).1
        let cr = try XCTUnwrap(call?["result"] as? [String: Any])
        XCTAssertEqual((cr["content"] as? [[String: Any]])?.first?["text"] as? String, "hi hi")
        XCTAssertEqual(cr["isError"] as? Bool, false)
        // wrong arguments: a tool execution error the model can fix
        let bad = post(e, ["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": ["name": "echo", "arguments": ["times": 9]]], headers: h).1
        let br = try XCTUnwrap(bad?["result"] as? [String: Any])
        XCTAssertEqual(br["isError"] as? Bool, true)
        let msg = (br["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(msg.contains("missing required argument `text`") && msg.contains("≤ 3"), msg)
        // unknown tool: a protocol error
        let unk = post(e, ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "nope"]], headers: h).1
        XCTAssertEqual((unk?["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual((post(e, ["jsonrpc": "2.0", "id": 8, "method": "bogus/method"], headers: h).1?["error"] as? [String: Any])?["code"] as? Int, -32601)
        // sessions are required and checked
        XCTAssertEqual(post(e, ["jsonrpc": "2.0", "id": 9, "method": "ping"]).0, 400)
        XCTAssertEqual(post(e, ["jsonrpc": "2.0", "id": 9, "method": "ping"], headers: ["mcp-session-id": "nope"]).0, 404)
        XCTAssertEqual(post(e, ["jsonrpc": "2.0", "id": 9, "method": "ping"], headers: ["mcp-session-id": sid, "mcp-protocol-version": "1999-01-01"]).0, 400)
        // batch (2025-03-26)
        var out: MCPHTTPResponse?
        e.handle(MCPHTTPRequest(method: "POST", path: "/mcp", headers: ["authorization": "Bearer \(token)", "mcp-session-id": sid],
                                body: MCPJSON.data([["jsonrpc": "2.0", "id": 1, "method": "ping"], ["jsonrpc": "2.0", "method": "notifications/initialized"]]))) { out = $0 }
        XCTAssertEqual((MCPJSON.parse(out!.body) as? [Any])?.count, 1)
        e.handle(MCPHTTPRequest(method: "DELETE", path: "/mcp", headers: ["authorization": "Bearer \(token)", "mcp-session-id": sid])) { out = $0 }
        XCTAssertEqual(out?.status, 204)
        XCTAssertEqual(post(e, ["jsonrpc": "2.0", "id": 10, "method": "ping"], headers: ["mcp-session-id": sid]).0, 404)
    }

    func testModernRequests() throws {
        let e = endpoint()
        let (d, dh) = modern("server/discover")
        let disc = post(e, d, headers: dh)
        XCTAssertEqual(disc.0, 200)
        let dr = try XCTUnwrap(disc.1?["result"] as? [String: Any])
        XCTAssertEqual(dr["resultType"] as? String, "complete")
        XCTAssertEqual((dr["supportedVersions"] as? [String])?.first, "2026-07-28")
        let (c, ch) = modern("tools/call", params: ["name": "echo", "arguments": ["text": "yo"]])
        let call = post(e, c, headers: ch)
        XCTAssertEqual(((call.1?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String, "yo")
        // header checks
        var bad = ch; bad["mcp-name"] = "other"
        XCTAssertEqual((post(e, c, headers: bad).1?["error"] as? [String: Any])?["code"] as? Int, -32020)
        bad = ch; bad["mcp-name"] = "=?base64?" + Data("echo".utf8).base64EncodedString() + "?="
        XCTAssertEqual(post(e, c, headers: bad).0, 200, "base64 sentinel decoded")
        bad = ch; bad.removeValue(forKey: "mcp-method")
        XCTAssertEqual(post(e, c, headers: bad).0, 400)
        bad = ch; bad["mcp-protocol-version"] = "2025-06-18"
        XCTAssertEqual((post(e, c, headers: bad).1?["error"] as? [String: Any])?["code"] as? Int, -32020)
        // unsupported version
        var (u, uh) = modern("ping")
        var um = u as! [String: Any]; var up = um["params"] as! [String: Any]; var meta = up["_meta"] as! [String: Any]
        meta["io.modelcontextprotocol/protocolVersion"] = "2099-01-01"; up["_meta"] = meta; um["params"] = up; u = um
        uh["mcp-protocol-version"] = "2099-01-01"
        let uv = post(e, u, headers: uh)
        XCTAssertEqual(uv.0, 400)
        let ue = try XCTUnwrap(uv.1?["error"] as? [String: Any])
        XCTAssertEqual(ue["code"] as? Int, -32022)
        XCTAssertEqual(((ue["data"] as? [String: Any])?["supported"] as? [String])?.contains("2026-07-28"), true)
        let (m, mh) = modern("resources/list")
        XCTAssertEqual(post(e, m, headers: mh).0, 404)
        // parse error
        let pe = post(e, Data("{nope".utf8))
        XCTAssertEqual(pe.0, 400); XCTAssertEqual((pe.1?["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertGreaterThanOrEqual(e.activeClients(), 1)
    }

    func testTokenAndCommand() {
        let a = MCPEndpoint.newToken(), b = MCPEndpoint.newToken()
        XCTAssertEqual(a.count, 43); XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        XCTAssertEqual(MCPEndpoint.claudeSetupCommand(port: 47800, token: "T"),
                       "claude mcp add --transport http imagecrat http://127.0.0.1:47800/mcp --header \"Authorization: Bearer T\"")
    }
}
