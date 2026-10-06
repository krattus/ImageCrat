import Foundation

// JSON Schema (2020-12 subset) for MCP tool arguments: small builders for tool definitions, a validator that turns
// wrong arguments into messages a language model can act on, and a checker for the schemas themselves.
// Supported keywords: type (name or list), description, properties, required, additionalProperties (bool or schema),
// enum, default, minimum, maximum, minLength, maxLength, items, minItems, maxItems, anyOf.

/// Builders. Every property carries a description (the checker insists on it).
package enum MCPSchema {
    package typealias Schema = [String: Any]

    package static func object(_ properties: [String: Schema], required: [String] = [], description: String? = nil,
                               additional: Bool = false) -> Schema {
        var s: Schema = ["type": "object", "properties": properties, "additionalProperties": additional]
        if !required.isEmpty { s["required"] = required }
        if let d = description { s["description"] = d }
        return s
    }

    package static func string(_ description: String, oneOf values: [String]? = nil, default def: String? = nil, minLength: Int? = nil) -> Schema {
        var s: Schema = ["type": "string", "description": description]
        if let v = values { s["enum"] = v }
        if let d = def { s["default"] = d }
        if let m = minLength { s["minLength"] = m }
        return s
    }

    package static func number(_ description: String, min: Double? = nil, max: Double? = nil, default def: Double? = nil) -> Schema {
        var s: Schema = ["type": "number", "description": description]
        if let m = min { s["minimum"] = m }
        if let m = max { s["maximum"] = m }
        if let d = def { s["default"] = d }
        return s
    }

    package static func integer(_ description: String, min: Int? = nil, max: Int? = nil, default def: Int? = nil) -> Schema {
        var s: Schema = ["type": "integer", "description": description]
        if let m = min { s["minimum"] = m }
        if let m = max { s["maximum"] = m }
        if let d = def { s["default"] = d }
        return s
    }

    package static func boolean(_ description: String, default def: Bool? = nil) -> Schema {
        var s: Schema = ["type": "boolean", "description": description]
        if let d = def { s["default"] = d }
        return s
    }

    package static func array(_ description: String, items: Schema, minItems: Int? = nil, maxItems: Int? = nil) -> Schema {
        var s: Schema = ["type": "array", "description": description, "items": items]
        if let m = minItems { s["minItems"] = m }
        if let m = maxItems { s["maxItems"] = m }
        return s
    }

    /// A free-form object (filter parameters, adjustment settings): its keys are checked by the tool itself.
    package static func map(_ description: String) -> Schema {
        ["type": "object", "description": description, "additionalProperties": true]
    }

    /// A colour: "#RRGGBB", "#RRGGBBAA" or [r, g, b(, a)] with 0…255 (or 0…1) components.
    package static func color(_ description: String) -> Schema {
        ["description": description + " Hex string \"#RRGGBB\" / \"#RRGGBBAA\", or an array [r, g, b] / [r, g, b, a] (0–255).",
         "anyOf": [["type": "string", "minLength": 3] as Schema,
                   ["type": "array", "items": ["type": "number"] as Schema, "minItems": 3, "maxItems": 4] as Schema]]
    }

    /// One of several forms (e.g. `false` or an effect object).
    package static func anyOf(_ description: String, _ options: [Schema]) -> Schema {
        ["description": description, "anyOf": options]
    }

    /// x, y point in document pixels.
    package static func point(_ description: String) -> Schema {
        object(["x": number("X in document pixels (0 = left edge)."), "y": number("Y in document pixels (0 = top edge).")],
               required: ["x", "y"], description: description)
    }

    /// x, y, width, height rectangle in document pixels.
    package static func rect(_ description: String) -> Schema {
        object(["x": number("Left edge in document pixels."), "y": number("Top edge in document pixels."),
                "width": number("Width in pixels.", min: 0), "height": number("Height in pixels.", min: 0)],
               required: ["x", "y", "width", "height"], description: description)
    }
}

package enum MCPSchemaValidator {
    static let typeNames: Set<String> = ["object", "array", "string", "number", "integer", "boolean", "null"]

    /// Problems with `value` against `schema`, as short sentences naming the argument ("`size` must be a number ≥ 1.").
    package static func validate(_ value: Any?, _ schema: [String: Any], path: String = "") -> [String] {
        let name = path.isEmpty ? "the arguments" : "`\(path)`"
        guard let value, !(value is NSNull) else {
            if let t = types(schema), t.contains("null") { return [] }
            if let any = schema["anyOf"] as? [[String: Any]], any.contains(where: { types($0)?.contains("null") == true }) { return [] }
            return path.isEmpty ? [] : ["\(name) must not be null."]
        }
        if let any = schema["anyOf"] as? [[String: Any]] {
            if any.contains(where: { validate(value, $0, path: path).isEmpty }) { return [] }
            // the alternative of the value's own type explains best what is wrong ("`drop_shadow.size` must be ≤ 250")
            if let same = any.first(where: { alt in types(alt).map { $0.contains { matches(value, $0) } } ?? false }) {
                return validate(value, same, path: path)
            }
            return ["\(name) has the wrong form (got \(describe(value))). \(hint(schema))"]
        }
        if let t = types(schema), !t.contains(where: { matches(value, $0) }) {
            return ["\(name) must be \(t.map(article).joined(separator: " or ")) (got \(describe(value)))."]
        }
        var errors: [String] = []
        if let e = schema["enum"] as? [Any], !e.contains(where: { equal($0, value) }) {
            let list = e.map { MCPJSON.string($0) }.joined(separator: ", ")
            errors.append("\(name) must be one of: \(list) (got \(MCPJSON.string(value))).")
        }
        if let d = MCPJSON.double(value) {
            if let m = MCPJSON.double(schema["minimum"]), d < m { errors.append("\(name) must be ≥ \(fmt(m)) (got \(fmt(d))).") }
            if let m = MCPJSON.double(schema["maximum"]), d > m { errors.append("\(name) must be ≤ \(fmt(m)) (got \(fmt(d))).") }
        }
        if let s = value as? String {
            if let m = schema["minLength"] as? Int, s.count < m { errors.append(m == 1 ? "\(name) must not be empty." : "\(name) must have at least \(m) characters.") }
            if let m = schema["maxLength"] as? Int, s.count > m { errors.append("\(name) must have at most \(m) characters.") }
        }
        if let a = value as? [Any] {
            if let m = schema["minItems"] as? Int, a.count < m { errors.append("\(name) needs at least \(m) item\(m == 1 ? "" : "s") (got \(a.count)).") }
            if let m = schema["maxItems"] as? Int, a.count > m { errors.append("\(name) takes at most \(m) item\(m == 1 ? "" : "s") (got \(a.count)).") }
            if let item = schema["items"] as? [String: Any] {
                for (i, v) in a.enumerated() { errors += validate(v, item, path: "\(path)[\(i)]") }
            }
        }
        if let o = value as? [String: Any] {
            let props = schema["properties"] as? [String: [String: Any]] ?? [:]
            for r in (schema["required"] as? [String]) ?? [] where o[r] == nil {
                let desc = (props[r]?["description"] as? String).map { " (\($0))" } ?? ""
                errors.append("missing required argument `\(join(path, r))`\(desc).")
            }
            for (k, v) in o.sorted(by: { $0.key < $1.key }) {
                if let p = props[k] {
                    errors += validate(v, p, path: join(path, k))
                } else if let extra = schema["additionalProperties"] as? [String: Any] {
                    errors += validate(v, extra, path: join(path, k))
                } else if (schema["additionalProperties"] as? Bool) == false {
                    let valid = props.keys.sorted().map { "`\($0)`" }.joined(separator: ", ")
                    errors.append("unknown argument `\(join(path, k))`" + (valid.isEmpty ? " (this takes no arguments)." : " (valid: \(valid))."))
                }
            }
        }
        return errors
    }

    /// Problems with a tool's input schema itself (used by the self test: every tool must have a valid schema).
    package static func check(_ schema: [String: Any], path: String = "inputSchema", root: Bool = true) -> [String] {
        var errors: [String] = []
        if root && (schema["type"] as? String) != "object" { errors.append("\(path): the root must be {\"type\": \"object\"}") }
        if let any = schema["anyOf"] {
            guard let list = any as? [[String: Any]], !list.isEmpty else { return ["\(path): anyOf must be a non-empty list of schemas"] }
            for (i, s) in list.enumerated() { errors += check(s, path: "\(path).anyOf[\(i)]", root: false) }
        } else if schema["type"] == nil && schema["enum"] == nil && !root {
            errors.append("\(path): no type")
        }
        if let t = schema["type"] {
            let names = (t as? [String]) ?? (t as? String).map { [$0] } ?? []
            if names.isEmpty || !names.allSatisfy(typeNames.contains) { errors.append("\(path): invalid type \(MCPJSON.string(t))") }
        }
        if let e = schema["enum"] {
            if (e as? [Any])?.isEmpty != false { errors.append("\(path): enum must be a non-empty list") }
        }
        if let lo = MCPJSON.double(schema["minimum"]), let hi = MCPJSON.double(schema["maximum"]), lo > hi { errors.append("\(path): minimum > maximum") }
        if let props = schema["properties"] {
            guard let p = props as? [String: Any] else { return errors + ["\(path): properties must be an object"] }
            for (k, v) in p {
                guard let s = v as? [String: Any] else { errors.append("\(path).\(k): not a schema object"); continue }
                if (s["description"] as? String)?.isEmpty != false { errors.append("\(path).\(k): no description") }
                errors += check(s, path: "\(path).\(k)", root: false)
            }
            if let req = schema["required"] {
                guard let r = req as? [String] else { return errors + ["\(path): required must be a list of names"] }
                for n in r where p[n] == nil { errors.append("\(path): required `\(n)` is not a property") }
            }
        }
        if let items = schema["items"] {
            if let s = items as? [String: Any] { errors += check(s, path: "\(path)[]", root: false) } else { errors.append("\(path): items must be a schema") }
        }
        if let extra = schema["additionalProperties"] as? [String: Any] { errors += check(extra, path: "\(path).*", root: false) }
        if let d = schema["default"], !validate(d, schema.filter { $0.key != "default" }, path: "default").isEmpty {
            errors.append("\(path): default \(MCPJSON.string(d)) does not match the schema")
        }
        // the 2026-07-28 binding rejects number-typed or nested x-mcp-header parameters; none are used here
        if schema["x-mcp-header"] != nil { errors.append("\(path): x-mcp-header is not used by this server") }
        return errors
    }

    // MARK: Helpers

    static func types(_ s: [String: Any]) -> [String]? {
        if let t = s["type"] as? String { return [t] }
        return s["type"] as? [String]
    }

    static func matches(_ v: Any, _ type: String) -> Bool {
        switch type {
        case "object": return v is [String: Any]
        case "array": return v is [Any]
        case "string": return v is String
        case "boolean": return MCPJSON.isBool(v)
        case "number": return MCPJSON.isNumber(v)
        case "integer":
            guard let d = MCPJSON.double(v) else { return false }
            return d.rounded() == d && abs(d) < 9.007e15
        case "null": return v is NSNull
        default: return false
        }
    }

    static func article(_ t: String) -> String {
        switch t {
        case "object": return "an object"
        case "array": return "an array"
        case "integer": return "an integer"
        default: return "a \(t)"
        }
    }

    static func describe(_ v: Any) -> String {
        if MCPJSON.isBool(v) { return "a boolean" }
        if MCPJSON.isNumber(v) { return "the number \(MCPJSON.string(v))" }
        if let s = v as? String { return "the string \(MCPJSON.string(s.count > 40 ? String(s.prefix(40)) + "…" : s))" }
        if v is [Any] { return "an array" }
        if v is [String: Any] { return "an object" }
        return "null"
    }

    static func hint(_ s: [String: Any]) -> String { (s["description"] as? String) ?? "" }

    static func equal(_ a: Any, _ b: Any) -> Bool {
        if let x = a as? String, let y = b as? String { return x == y }
        if let x = MCPJSON.double(a), let y = MCPJSON.double(b) { return x == y }
        if MCPJSON.isBool(a) && MCPJSON.isBool(b) { return (a as? NSNumber)?.boolValue == (b as? NSNumber)?.boolValue }
        return false
    }

    static func join(_ path: String, _ key: String) -> String { path.isEmpty ? key : path + "." + key }

    package static func fmt(_ d: Double) -> String { d.rounded() == d && abs(d) < 1e15 ? String(Int(d)) : String(d) }
}
