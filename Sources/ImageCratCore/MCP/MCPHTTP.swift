import Foundation

// Minimal HTTP/1.1 message handling for the local MCP endpoint (see docs/MCP.md). Pure byte parsing and formatting:
// the socket side (Network.framework on the Mac) lives in the app. Only what an MCP client sends is supported:
// a request line, headers, and a body sized by Content-Length (no chunked request bodies).

/// One parsed HTTP request. Header names are lower-cased (HTTP field names are case-insensitive).
package struct MCPHTTPRequest {
    package var method: String
    /// The request target without the query string ("/mcp").
    package var path: String
    package var headers: [String: String]
    package var body: Data

    package init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }

    package func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// The connection stays open after the response (HTTP/1.1 default) unless the client asked to close it.
    package var keepAlive: Bool { header("connection")?.lowercased().contains("close") != true }
}

package struct MCPHTTPResponse {
    package var status: Int
    package var headers: [(String, String)]
    package var body: Data

    package init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    package static func json(_ status: Int, _ object: Any, headers: [(String, String)] = []) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, headers: [("Content-Type", "application/json")] + headers, body: MCPJSON.data(object))
    }

    package static func empty(_ status: Int, headers: [(String, String)] = []) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, headers: headers)
    }

    package func header(_ name: String) -> String? { headers.first { $0.0.lowercased() == name.lowercased() }?.1 }

    package static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 415: return "Unsupported Media Type"
        case 421: return "Misdirected Request"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    /// Wire format. Content-Length is always sent (the connection may be reused).
    package func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(MCPHTTPResponse.reason(status))\r\n"
        for (k, v) in headers where k.lowercased() != "content-length" && k.lowercased() != "connection" {
            head += "\(k): \(MCPHTTP.sanitize(v))\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        head += "Cache-Control: no-store\r\n\r\n"
        var d = Data(head.utf8)
        d.append(body)
        return d
    }
}

package enum MCPHTTP {
    /// Largest request body accepted (scripts and JSON arguments; images are never uploaded).
    package static let maxBody = 8 * 1024 * 1024
    package static let maxHead = 64 * 1024

    package enum ParseResult {
        /// More bytes are needed. `expectContinue`: the head is complete and the client waits for "100 Continue".
        case needMore(expectContinue: Bool)
        /// A complete request and the number of bytes it used.
        case request(MCPHTTPRequest, consumed: Int)
        /// The bytes are not a request this server accepts: answer with `status` and close.
        case invalid(status: Int, message: String)
    }

    /// Parses one request from the start of `buffer`.
    package static func parse(_ buffer: Data) -> ParseResult {
        let bytes = [UInt8](buffer)
        guard let headEnd = find(bytes, [13, 10, 13, 10]) else {
            return bytes.count > maxHead ? .invalid(status: 431, message: "Request header too large.") : .needMore(expectContinue: false)
        }
        guard let headText = String(bytes: bytes[0..<headEnd], encoding: .utf8) else { return .invalid(status: 400, message: "Malformed request header.") }
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid(status: 400, message: "Malformed request line.") }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400, message: "Malformed header line.") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid(status: 400, message: "Malformed header line.") }
            if let old = headers[name] { headers[name] = old + ", " + value } else { headers[name] = value }
        }
        if let te = headers["transfer-encoding"], te.lowercased() != "identity" {
            return .invalid(status: 411, message: "Chunked request bodies are not supported; send Content-Length.")
        }
        var length = 0
        if let cl = headers["content-length"] {
            guard let n = Int(cl.trimmingCharacters(in: .whitespaces)), n >= 0 else { return .invalid(status: 400, message: "Invalid Content-Length.") }
            length = n
        }
        if length > maxBody { return .invalid(status: 413, message: "Request body too large (limit \(maxBody / 1_048_576) MB).") }
        let bodyStart = headEnd + 4
        if bytes.count < bodyStart + length {
            let expect = headers["expect"]?.lowercased() == "100-continue"
            return .needMore(expectContinue: expect)
        }
        var target = String(requestLine[1])
        if let q = target.firstIndex(of: "?") { target = String(target[..<q]) }
        let req = MCPHTTPRequest(method: String(requestLine[0]).uppercased(), path: target, headers: headers,
                                 body: Data(bytes[bodyStart..<(bodyStart + length)]))
        return .request(req, consumed: bodyStart + length)
    }

    private static func find(_ hay: [UInt8], _ needle: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        var i = 0
        outer: while i <= hay.count - needle.count {
            for j in 0..<needle.count where hay[i + j] != needle[j] { i += 1; continue outer }
            return i
        }
        return nil
    }

    /// Header values never carry CR / LF (no response splitting).
    package static func sanitize(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }.map(Character.init))
    }
}

/// JSON helpers (JSONSerialization values: dictionaries, arrays, strings, NSNumber, NSNull).
package enum MCPJSON {
    package static func data(_ object: Any) -> Data {
        if JSONSerialization.isValidJSONObject(object),
           let d = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return d
        }
        // fragments (a bare string / number) and anything not representable
        if let d = try? JSONSerialization.data(withJSONObject: [object], options: [.withoutEscapingSlashes]), d.count >= 2 {
            return d.subdata(in: 1..<(d.count - 1))
        }
        return Data("null".utf8)
    }

    package static func string(_ object: Any, pretty: Bool = false) -> String {
        if pretty, JSONSerialization.isValidJSONObject(object),
           let d = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]) {
            return String(decoding: d, as: UTF8.self)
        }
        return String(decoding: data(object), as: UTF8.self)
    }

    package static func parse(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// True for JSON booleans (NSNumber from JSONSerialization keeps the distinction on Apple platforms and in
    /// swift-corelibs-foundation).
    package static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return v is Bool }
        return String(cString: n.objCType) == "c"   // JSON never produces char numbers: "c" is a boolean
    }

    package static func isNumber(_ v: Any?) -> Bool {
        guard v != nil, !isBool(v) else { return false }
        if let n = v as? NSNumber { return n.doubleValue.isFinite }
        return v is Double || v is Int
    }

    package static func double(_ v: Any?) -> Double? {
        guard isNumber(v) else { return nil }
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }
}
