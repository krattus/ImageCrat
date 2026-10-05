import Foundation

/// A property-list value, including the `UID` type NSKeyedArchiver uses for object references.
package indirect enum PlistValue: Equatable {
    case dict([String: PlistValue])
    case array([PlistValue])
    case string(String)
    case int(Int64)
    case real(Double)
    case bool(Bool)
    case data(Data)
    /// Seconds since 2001-01-01 00:00:00 UTC.
    case date(Double)
    case uid(UInt64)
    case null

    package subscript(key: String) -> PlistValue? {
        if case .dict(let d) = self { return d[key] }
        return nil
    }

    package var dict: [String: PlistValue]? { if case .dict(let d) = self { return d }; return nil }
    package var array: [PlistValue]? { if case .array(let a) = self { return a }; return nil }
    package var string: String? { if case .string(let s) = self { return s }; return nil }
    package var data: Data? { if case .data(let d) = self { return d }; return nil }
    /// Numbers and booleans as Double (also numeric strings).
    package var double: Double? {
        switch self {
        case .real(let v): return v
        case .int(let v): return Double(v)
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
    package var int: Int? {
        switch self {
        case .int(let v): return Int(clamping: v)
        case .real(let v): return v.isFinite && abs(v) < 9e18 ? Int(v) : nil
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    package var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let v): return v != 0
        case .real(let v): return v != 0
        case .string(let s): return ["true", "yes", "1"].contains(s.lowercased())
        default: return nil
        }
    }
}

/// Property-list reading: an own `bplist00` parser (portable, keeps UIDs), XML plists via Foundation, and an
/// NSKeyedArchiver resolver that turns `$objects` / `$top` graphs into plain values.
package enum BinaryPlist {
    package static let maxDepth = 256
    package static let maxObjects = 4_000_000

    package static func isBinaryPlist(_ data: Data) -> Bool {
        data.count >= 8 && data.prefix(6) == Data("bplist".utf8)
    }

    /// Parses a binary or XML property list.
    package static func parse(_ data: Data) throws -> PlistValue {
        if isBinaryPlist(data) { return try parseBinary(data) }
        return try parseWithFoundation(data)
    }

    // MARK: Binary

    package static func parseBinary(_ data: Data) throws -> PlistValue {
        var p = BinaryParser(bytes: [UInt8](data))
        return try p.parseTop()
    }

    private struct BinaryParser {
        let bytes: [UInt8]
        var offsets: [Int] = []
        var refSize = 0
        var cache: [Int: PlistValue] = [:]
        var active = Set<Int>()
        var work = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        func readUInt(_ p: Int, _ n: Int) throws -> UInt64 {
            guard n >= 1, n <= 8, p >= 0, p + n <= bytes.count else { throw BrushImportError.malformed("plist integer") }
            var v: UInt64 = 0
            for i in 0..<n { v = v << 8 | UInt64(bytes[p + i]) }
            return v
        }

        mutating func parseTop() throws -> PlistValue {
            let n = bytes.count
            guard n >= 40, bytes[0] == 0x62, bytes[6] == 0x30 else { throw BrushImportError.malformed("bplist header") }
            let t = n - 32
            let offSize = Int(bytes[t + 6])
            refSize = Int(bytes[t + 7])
            let numObjects = try readUInt(t + 8, 8)
            let top = try readUInt(t + 16, 8)
            let tableOffset = try readUInt(t + 24, 8)
            guard (1...8).contains(offSize), (1...8).contains(refSize),
                  numObjects > 0, numObjects <= UInt64(BinaryPlist.maxObjects), top < numObjects,
                  tableOffset >= 8, tableOffset < UInt64(t),
                  numObjects * UInt64(offSize) <= UInt64(t) - tableOffset else {
                throw BrushImportError.malformed("bplist trailer")
            }
            let to = Int(tableOffset)
            offsets.reserveCapacity(Int(numObjects))
            for i in 0..<Int(numObjects) {
                let o = try readUInt(to + i * offSize, offSize)
                guard o >= 8, o < UInt64(t) else { throw BrushImportError.malformed("bplist object offset") }
                offsets.append(Int(o))
            }
            return try object(Int(top), depth: 0)
        }

        /// Length of a variable-size object: the low nibble, or a following int object when it is 0xF.
        func count(_ marker: UInt8, at p: Int) throws -> (Int, Int) {
            let nib = Int(marker & 0x0F)
            if nib != 0x0F { return (nib, p + 1) }
            guard p + 1 < bytes.count, bytes[p + 1] >> 4 == 0x1 else { throw BrushImportError.malformed("bplist length") }
            let sz = 1 << Int(bytes[p + 1] & 0x0F)
            guard sz <= 8 else { throw BrushImportError.malformed("bplist length") }
            let v = try readUInt(p + 2, sz)
            guard v <= UInt64(bytes.count) else { throw BrushImportError.malformed("bplist length") }
            return (Int(v), p + 2 + sz)
        }

        func ref(_ p: Int, _ i: Int) throws -> Int {
            let v = try readUInt(p + i * refSize, refSize)
            guard v < UInt64(offsets.count) else { throw BrushImportError.malformed("bplist object reference") }
            return Int(v)
        }

        mutating func object(_ index: Int, depth: Int) throws -> PlistValue {
            if let c = cache[index] { return c }
            guard depth < BinaryPlist.maxDepth else { throw BrushImportError.malformed("bplist nesting") }
            guard !active.contains(index) else { throw BrushImportError.malformed("bplist reference cycle") }
            work += 1
            guard work <= BinaryPlist.maxObjects else { throw BrushImportError.malformed("bplist too large") }
            let p = offsets[index]
            let m = bytes[p]
            let v: PlistValue
            switch m >> 4 {
            case 0x0:
                switch m {
                case 0x08: v = .bool(false)
                case 0x09: v = .bool(true)
                default: v = .null
                }
            case 0x1:
                let n = 1 << Int(m & 0x0F)
                guard n <= 16 else { throw BrushImportError.malformed("bplist int size") }
                if n == 16 {
                    v = .int(Int64(bitPattern: try readUInt(p + 9, 8)))   // 128-bit: keep the low 64 bits
                } else {
                    let u = try readUInt(p + 1, n)
                    v = .int(n == 8 ? Int64(bitPattern: u) : Int64(u))
                }
            case 0x2:
                let n = 1 << Int(m & 0x0F)
                if n == 4 { v = .real(Double(Float(bitPattern: UInt32(try readUInt(p + 1, 4))))) }
                else if n == 8 { v = .real(Double(bitPattern: try readUInt(p + 1, 8))) }
                else { throw BrushImportError.malformed("bplist real size") }
            case 0x3:
                v = .date(Double(bitPattern: try readUInt(p + 1, 8)))
            case 0x4:
                let (len, s) = try count(m, at: p)
                guard s + len <= bytes.count else { throw BrushImportError.malformed("bplist data") }
                v = .data(Data(bytes[s..<(s + len)]))
            case 0x5:
                let (len, s) = try count(m, at: p)
                guard s + len <= bytes.count else { throw BrushImportError.malformed("bplist string") }
                let sl = bytes[s..<(s + len)]
                v = .string(String(bytes: sl, encoding: .ascii) ?? String(decoding: sl, as: UTF8.self))
            case 0x6:
                let (len, s) = try count(m, at: p)
                guard len <= (bytes.count - s) / 2 else { throw BrushImportError.malformed("bplist string") }
                var units = [UInt16](repeating: 0, count: len)
                for i in 0..<len { units[i] = UInt16(bytes[s + 2 * i]) << 8 | UInt16(bytes[s + 2 * i + 1]) }
                v = .string(String(decoding: units, as: UTF16.self))
            case 0x7:
                let (len, s) = try count(m, at: p)
                guard s + len <= bytes.count else { throw BrushImportError.malformed("bplist string") }
                v = .string(String(decoding: bytes[s..<(s + len)], as: UTF8.self))
            case 0x8:
                v = .uid(try readUInt(p + 1, Int(m & 0x0F) + 1))
            case 0xA, 0xB, 0xC:
                let (len, s) = try count(m, at: p)
                guard len <= (bytes.count - s) / refSize else { throw BrushImportError.malformed("bplist array") }
                active.insert(index)
                defer { active.remove(index) }
                var arr: [PlistValue] = []
                arr.reserveCapacity(len)
                for i in 0..<len { arr.append(try object(try ref(s, i), depth: depth + 1)) }
                v = .array(arr)
            case 0xD:
                let (len, s) = try count(m, at: p)
                guard len <= (bytes.count - s) / (2 * refSize) else { throw BrushImportError.malformed("bplist dict") }
                active.insert(index)
                defer { active.remove(index) }
                var d: [String: PlistValue] = [:]
                for i in 0..<len {
                    let k = try object(try ref(s, i), depth: depth + 1)
                    let val = try object(try ref(s, len + i), depth: depth + 1)
                    switch k {
                    case .string(let ks): d[ks] = val
                    case .int(let ki): d[String(ki)] = val
                    default: continue
                    }
                }
                v = .dict(d)
            default:
                throw BrushImportError.malformed("bplist object type")
            }
            cache[index] = v
            return v
        }
    }

    // MARK: XML (and anything else Foundation reads)

    private static func parseWithFoundation(_ data: Data) throws -> PlistValue {
        let obj: Any
        do {
            obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw BrushImportError.malformed("property list")
        }
        var budget = maxObjects
        return convert(obj, depth: 0, budget: &budget)
    }

    private static func convert(_ o: Any, depth: Int, budget: inout Int) -> PlistValue {
        budget -= 1
        guard depth < maxDepth, budget > 0 else { return .null }
        switch o {
        case let s as String: return .string(s)
        case let d as Data: return .data(d)
        case let d as Date: return .date(d.timeIntervalSinceReferenceDate)
        case let a as [Any]: return .array(a.map { convert($0, depth: depth + 1, budget: &budget) })
        case let d as [String: Any]:
            if d.count == 1, let u = d["CF$UID"] as? NSNumber { return .uid(u.uint64Value) }
            var out: [String: PlistValue] = [:]
            for (k, v) in d { out[k] = convert(v, depth: depth + 1, budget: &budget) }
            return .dict(out)
        case let n as NSNumber:
            let t = String(cString: n.objCType)
            if t == "c" || t == "B" { return .bool(n.boolValue) }
            if t == "d" || t == "f" { return .real(n.doubleValue) }
            return .int(n.int64Value)
        default:
            return .null
        }
    }

    // MARK: NSKeyedArchiver

    /// Resolves an NSKeyedArchiver graph: returns `$top` with every UID replaced by the object it references, or nil
    /// when `root` is not a keyed archive. Collections become plain values (NSDictionary → .dict, NSArray / NSSet →
    /// .array, NSString → .string, NSData → .data, NSDate → .date, "$null" → .null); other objects become a .dict of
    /// their encoded fields plus "$classname". Reference cycles resolve to .null at the repeated object; nesting is
    /// limited to `maxDepth` and the total work to `maxObjects`.
    package static func unarchive(_ root: PlistValue) -> PlistValue? {
        guard case .dict(let d) = root, case .array(let objects)? = d["$objects"], case .dict(let top)? = d["$top"] else {
            return nil
        }
        var r = KeyedResolver(objects: objects)
        var out: [String: PlistValue] = [:]
        for (k, v) in top { out[k] = r.resolve(v, depth: 0) }
        return .dict(out)
    }

    /// Convenience: parse + resolve, returning `$top.root` (falls back to the whole `$top`).
    package static func unarchiveRoot(_ data: Data) -> PlistValue? {
        guard let p = try? parse(data), let top = unarchive(p) else { return nil }
        return top["root"] ?? top
    }

    private struct KeyedResolver {
        let objects: [PlistValue]
        var memo: [Int: PlistValue] = [:]
        var active = Set<Int>()
        var work = 0

        mutating func resolve(_ v: PlistValue, depth: Int) -> PlistValue {
            work += 1
            guard depth < BinaryPlist.maxDepth, work < BinaryPlist.maxObjects else { return .null }
            switch v {
            case .uid(let u):
                guard u < UInt64(objects.count) else { return .null }
                let i = Int(u)
                if let m = memo[i] { return m }
                if active.contains(i) { return .null }   // cycle
                active.insert(i)
                let r = resolveObject(objects[i], depth: depth + 1)
                active.remove(i)
                memo[i] = r
                return r
            case .array(let a):
                return .array(a.map { resolve($0, depth: depth + 1) })
            case .dict:
                return resolveObject(v, depth: depth + 1)
            case .string(let s):
                return s == "$null" ? .null : v
            default:
                return v
            }
        }

        mutating func className(_ d: [String: PlistValue]) -> String? {
            guard case .uid(let u)? = d["$class"], u < UInt64(objects.count),
                  case .dict(let cd) = objects[Int(u)] else { return nil }
            return cd["$classname"]?.string
        }

        mutating func resolveObject(_ o: PlistValue, depth: Int) -> PlistValue {
            switch o {
            case .string(let s): return s == "$null" ? .null : o
            case .array(let a): return .array(a.map { resolve($0, depth: depth + 1) })
            case .dict(let d):
                if case .array(let keys)? = d["NS.keys"], case .array(let vals)? = d["NS.objects"] {
                    var out: [String: PlistValue] = [:]
                    for (k, val) in zip(keys, vals) {
                        let rk = resolve(k, depth: depth + 1)
                        let key: String
                        switch rk {
                        case .string(let s): key = s
                        case .int(let i): key = String(i)
                        case .real(let r): key = String(r)
                        default: continue
                        }
                        out[key] = resolve(val, depth: depth + 1)
                    }
                    return .dict(out)
                }
                if case .array(let vals)? = d["NS.objects"] { return .array(vals.map { resolve($0, depth: depth + 1) }) }
                if let s = d["NS.string"] { return resolve(s, depth: depth + 1) }
                if let b = d["NS.bytes"] ?? d["NS.data"] { return resolve(b, depth: depth + 1) }
                if case .real(let t)? = d["NS.time"] { return .date(t) }
                if let rel = d["NS.relative"] { return resolve(rel, depth: depth + 1) }
                var out: [String: PlistValue] = [:]
                for (k, v) in d where k != "$class" { out[k] = resolve(v, depth: depth + 1) }
                if let cn = className(d) { out["$classname"] = .string(cn) }
                return .dict(out)
            default:
                return o
            }
        }
    }
}
