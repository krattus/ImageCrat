import Foundation

// MARK: - Photoshop Action Descriptor (version 16)
//
// Binary layout (all big-endian):
//   Descriptor  = UnicodeString name, ID classID, u32 count, count × (ID key, OSType, value)
//   ID          = u32 length; length == 0 → 4-byte charID follows, else `length` bytes (stringID)
//   Unicode     = u32 count of UTF-16 units (Photoshop includes a trailing NUL), UTF-16BE units
// Used by the 'lfx2' / 'lmfx' tagged blocks (layer styles) among many others.

package enum PSDDescriptorError: Error, CustomStringConvertible {
    case truncated(at: Int)
    case invalid(String)
    case tooDeep

    package var description: String {
        switch self {
        case .truncated(let p): return "descriptor truncated at \(p)"
        case .invalid(let s): return "invalid descriptor: \(s)"
        case .tooDeep: return "descriptor nested too deeply"
        }
    }
}

package struct PSDDescriptor {
    package struct Entry {
        package var key: String
        package var value: PSDDescriptorValue
        package init(key: String, value: PSDDescriptorValue) {
            self.key = key; self.value = value
        }
    }

    package var name: String = ""
    package var classID: String
    package var entries: [Entry] = []

    package init(classID: String, name: String = "", _ items: [(String, PSDDescriptorValue)] = []) {
        self.classID = classID
        self.name = name
        self.entries = items.map { Entry(key: $0.0, value: $0.1) }
    }

    package var keys: [String] { entries.map(\.key) }

    package subscript(key: String) -> PSDDescriptorValue? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let i = entries.firstIndex(where: { $0.key == key }) {
                if let v = newValue { entries[i].value = v } else { entries.remove(at: i) }
            } else if let v = newValue {
                entries.append(Entry(key: key, value: v))
            }
        }
    }

    package func double(_ key: String) -> Double? { self[key]?.doubleValue }
    package func bool(_ key: String) -> Bool? { self[key]?.boolValue }
    package func enumValue(_ key: String) -> String? { self[key]?.enumValue }
    package func object(_ key: String) -> PSDDescriptor? { self[key]?.objectValue }
    package func list(_ key: String) -> [PSDDescriptorValue]? { self[key]?.listValue }
    package func string(_ key: String) -> String? { self[key]?.stringValue }
    package func unit(_ key: String) -> String? { if case .unitFloat(let u, _)? = self[key] { return u }; return nil }

    // Serialization

    /// Parses a bare descriptor (no version prefix) at the start of `data`. Trailing bytes are ignored.
    package init(data: Data) throws {
        var r = PSDDescriptorReader(data)
        self = try r.descriptor()
    }

    /// Parses `u32 version (16)` + descriptor.
    package static func readVersioned(_ data: Data) throws -> PSDDescriptor {
        var r = PSDDescriptorReader(data)
        let v = try r.u32()
        guard v == 16 else { throw PSDDescriptorError.invalid("descriptor version \(v)") }
        return try r.descriptor()
    }

    package func serialized() -> Data {
        var w = PSDDescriptorWriter()
        w.descriptor(self)
        return w.data
    }

    package func serializedVersioned() -> Data {
        var w = PSDDescriptorWriter()
        w.u32(16)
        w.descriptor(self)
        return w.data
    }
}

package indirect enum PSDDescriptorValue {
    case object(PSDDescriptor)                               // 'Objc'
    case globalObject(PSDDescriptor)                         // 'GlbO'
    case list([PSDDescriptorValue])                          // 'VlLs'
    case double(Double)                                      // 'doub'
    case unitFloat(unit: String, value: Double)              // 'UntF'  (#Pxl #Prc #Ang #Rsl #Rlt #Nne #Mlm #Pnt)
    case unitFloats(unit: String, values: [Double])          // 'UnFl'
    case integer(Int32)                                      // 'long'
    case largeInteger(Int64)                                 // 'comp'
    case bool(Bool)                                          // 'bool'
    case enumerated(type: String, value: String)             // 'enum'
    case string(String)                                      // 'TEXT'
    case classType(osType: String, name: String, classID: String) // 'type' / 'GlbC' / 'Clss'
    case objectArray(count: UInt32, PSDDescriptor)           // 'ObAr'
    case data(osType: String, Data)                          // length-prefixed: 'tdta' / 'alis' / 'Pth '
    case reference(Data)                                     // 'obj ' — preserved as its raw body

    package var osType: String {
        switch self {
        case .object: return "Objc"
        case .globalObject: return "GlbO"
        case .list: return "VlLs"
        case .double: return "doub"
        case .unitFloat: return "UntF"
        case .unitFloats: return "UnFl"
        case .integer: return "long"
        case .largeInteger: return "comp"
        case .bool: return "bool"
        case .enumerated: return "enum"
        case .string: return "TEXT"
        case .classType(let t, _, _): return t
        case .objectArray: return "ObAr"
        case .data(let t, _): return t
        case .reference: return "obj "
        }
    }

    package var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .unitFloat(_, let d): return d
        case .integer(let i): return Double(i)
        case .largeInteger(let i): return Double(i)
        default: return nil
        }
    }
    package var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .integer(let i): return i != 0
        default: return nil
        }
    }
    package var enumValue: String? { if case .enumerated(_, let v) = self { return v }; return nil }
    package var objectValue: PSDDescriptor? {
        switch self {
        case .object(let d), .globalObject(let d): return d
        default: return nil
        }
    }
    package var listValue: [PSDDescriptorValue]? { if case .list(let l) = self { return l }; return nil }
    package var stringValue: String? { if case .string(let s) = self { return s }; return nil }
}

// MARK: Reader

package struct PSDDescriptorReader {
    private let bytes: [UInt8]
    package private(set) var pos = 0
    private var depth = 0
    package static let maxDepth = 48
    package static let maxIDLength = 1 << 16

    package init(_ data: Data) { bytes = [UInt8](data) }

    package var remaining: Int { bytes.count - pos }

    private func need(_ n: Int) throws {
        guard n >= 0, n <= bytes.count - pos else { throw PSDDescriptorError.truncated(at: pos) }
    }

    package mutating func u8() throws -> UInt8 { try need(1); defer { pos += 1 }; return bytes[pos] }
    package mutating func u32() throws -> UInt32 {
        try need(4)
        defer { pos += 4 }
        return UInt32(bytes[pos]) << 24 | UInt32(bytes[pos + 1]) << 16 | UInt32(bytes[pos + 2]) << 8 | UInt32(bytes[pos + 3])
    }
    package mutating func u64() throws -> UInt64 { UInt64(try u32()) << 32 | UInt64(try u32()) }
    package mutating func f64() throws -> Double { Double(bitPattern: try u64()) }
    package mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        try need(n)
        defer { pos += n }
        return bytes[pos..<(pos + n)]
    }
    package mutating func skip(_ n: Int) throws { try need(n); pos += n }

    private static func latin1(_ b: ArraySlice<UInt8>) -> String {
        String(String.UnicodeScalarView(b.map { Unicode.Scalar($0) }))
    }

    package mutating func fourCC() throws -> String { Self.latin1(try take(4)) }

    /// charID (length 0 + 4 bytes) or stringID (length + bytes).
    package mutating func id() throws -> String {
        let len = Int(try u32())
        guard len <= Self.maxIDLength else { throw PSDDescriptorError.invalid("ID length \(len)") }
        return Self.latin1(try take(len == 0 ? 4 : len))
    }

    package mutating func unicode() throws -> String {
        let n = Int(try u32())
        guard n <= remaining / 2 else { throw PSDDescriptorError.truncated(at: pos) }
        let raw = try take(n * 2)
        var units: [UInt16] = []
        units.reserveCapacity(n)
        var i = raw.startIndex
        while i < raw.endIndex { units.append(UInt16(raw[i]) << 8 | UInt16(raw[i + 1])); i += 2 }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    package mutating func descriptor() throws -> PSDDescriptor {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else { throw PSDDescriptorError.tooDeep }
        let name = try unicode()
        let classID = try id()
        let count = Int(try u32())
        guard count <= remaining / 9 else { throw PSDDescriptorError.invalid("item count \(count)") }  // key(≥8) + type(4) - 3 slack
        var d = PSDDescriptor(classID: classID, name: name)
        for _ in 0..<count {
            let key = try id()
            let type = try fourCC()
            d.entries.append(.init(key: key, value: try value(type)))
        }
        return d
    }

    package mutating func value(_ type: String) throws -> PSDDescriptorValue {
        switch type {
        case "Objc": return .object(try descriptor())
        case "GlbO": return .globalObject(try descriptor())
        case "VlLs":
            depth += 1
            defer { depth -= 1 }
            guard depth <= Self.maxDepth else { throw PSDDescriptorError.tooDeep }
            let count = Int(try u32())
            guard count <= remaining / 5 else { throw PSDDescriptorError.invalid("list count \(count)") }
            var items: [PSDDescriptorValue] = []
            for _ in 0..<count {
                let t = try fourCC()
                items.append(try value(t))
            }
            return .list(items)
        case "doub": return .double(try f64())
        case "UntF":
            let unit = try fourCC()
            return .unitFloat(unit: unit, value: try f64())
        case "UnFl":
            let unit = try fourCC()
            let count = Int(try u32())
            guard count <= remaining / 8 else { throw PSDDescriptorError.truncated(at: pos) }
            var vals: [Double] = []
            vals.reserveCapacity(count)
            for _ in 0..<count { vals.append(try f64()) }
            return .unitFloats(unit: unit, values: vals)
        case "long": return .integer(Int32(bitPattern: try u32()))
        case "comp": return .largeInteger(Int64(bitPattern: try u64()))
        case "bool": return .bool(try u8() != 0)
        case "enum":
            let t = try id()
            return .enumerated(type: t, value: try id())
        case "TEXT": return .string(try unicode())
        case "type", "GlbC", "Clss":
            let n = try unicode()
            return .classType(osType: type, name: n, classID: try id())
        case "ObAr":
            let count = try u32()
            return .objectArray(count: count, try descriptor())
        case "tdta", "alis", "Pth ":
            let n = Int(try u32())
            return .data(osType: type, Data(try take(n)))
        case "obj ":
            let start = pos
            try skipReference()
            return .reference(Data(bytes[start..<pos]))
        default:
            throw PSDDescriptorError.invalid("unknown OSType '\(type)'")
        }
    }

    private mutating func skipReference() throws {
        let count = Int(try u32())
        guard count <= remaining / 4 else { throw PSDDescriptorError.invalid("reference count \(count)") }
        for _ in 0..<count {
            switch try fourCC() {
            case "prop": _ = try unicode(); _ = try id(); _ = try id()
            case "Clss": _ = try unicode(); _ = try id()
            case "Enmr": _ = try unicode(); _ = try id(); _ = try id(); _ = try id()
            case "rele": _ = try unicode(); _ = try id(); _ = try u32()
            case "Idnt", "indx": _ = try u32()
            case "name": _ = try unicode(); _ = try id(); _ = try unicode()
            case let t: throw PSDDescriptorError.invalid("unknown reference form '\(t)'")
            }
        }
    }
}

// MARK: Writer

package struct PSDDescriptorWriter {
    package var data = Data()

    package mutating func u8(_ v: UInt8) { data.append(v) }
    package mutating func u32(_ v: UInt32) { data.append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
    package mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xffff_ffff)) }
    package mutating func f64(_ v: Double) { u64(v.bitPattern) }

    private static func latin1(_ s: String) -> [UInt8] { s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } }

    package mutating func fourCC(_ s: String) {
        var b = Self.latin1(s)
        while b.count < 4 { b.append(0x20) }
        data.append(contentsOf: b.prefix(4))
    }

    package mutating func id(_ s: String) {
        let b = Self.latin1(s)
        if b.count == 4 { u32(0) } else { u32(UInt32(b.count)) }
        data.append(contentsOf: b)
    }

    /// Photoshop writes descriptor strings NUL-terminated (the count includes the terminator).
    package mutating func unicode(_ s: String) {
        let u = Array(s.utf16) + [0]
        u32(UInt32(u.count))
        for c in u { data.append(UInt8(c >> 8)); data.append(UInt8(c & 0xff)) }
    }

    package mutating func descriptor(_ d: PSDDescriptor) {
        unicode(d.name)
        id(d.classID)
        u32(UInt32(d.entries.count))
        for e in d.entries {
            id(e.key)
            fourCC(e.value.osType)
            value(e.value)
        }
    }

    package mutating func value(_ v: PSDDescriptorValue) {
        switch v {
        case .object(let d), .globalObject(let d): descriptor(d)
        case .list(let items):
            u32(UInt32(items.count))
            for i in items { fourCC(i.osType); value(i) }
        case .double(let d): f64(d)
        case .unitFloat(let u, let d): fourCC(u); f64(d)
        case .unitFloats(let u, let vals): fourCC(u); u32(UInt32(vals.count)); for d in vals { f64(d) }
        case .integer(let i): u32(UInt32(bitPattern: i))
        case .largeInteger(let i): u64(UInt64(bitPattern: i))
        case .bool(let b): u8(b ? 1 : 0)
        case .enumerated(let t, let e): id(t); id(e)
        case .string(let s): unicode(s)
        case .classType(_, let n, let c): unicode(n); id(c)
        case .objectArray(let count, let d): u32(count); descriptor(d)
        case .data(_, let d): u32(UInt32(d.count)); data.append(d)
        case .reference(let raw): data.append(raw)
        }
    }
    package init(data: Data = Data()) {
        self.data = data
    }
}

// MARK: - Layer styles ('lfx2' / 'lmfx')

package enum PSDLayerStyle {
    private typealias V = PSDDescriptorValue

    /// True if the layer carries at least one effect worth writing.
    package static func shouldEncode(_ fx: LayerEffects) -> Bool { fx.hasStyle }   // (effects hidden with their eye are written with 'enab' false)

    /// True if any effect has more than one enabled instance (written as a '…Multi' list).
    package static func needsMulti(_ fx: LayerEffects) -> Bool {
        fx.dropShadows.filter(\.isListed).count > 1 || fx.innerShadows.filter(\.isListed).count > 1 ||
            fx.colorOverlays.filter(\.isListed).count > 1 || fx.gradientOverlays.filter(\.isListed).count > 1 ||
            fx.strokes.filter { $0.isListed && !$0.paint.isNone }.count > 1
    }

    /// Payload of an 'lfx2' block: u32 version 0, u32 descriptor version 16, descriptor.
    /// Layout follows current Photoshop: an effect with one instance uses its classic key ('DrSh'…),
    /// one with several instances uses the CC '…Multi' list key inside the same 'lfx2' block.
    /// `globalLight`: the document's Global Light. Effects that use it are written with its angle (and altitude), the
    /// direction Photoshop draws them in, rather than their own stored angle.
    package static func encode(_ fx: LayerEffects, globalLight: GlobalLight? = nil) -> Data {
        var w = PSDDescriptorWriter()
        w.u32(0)
        w.u32(16)
        w.descriptor(descriptor(fx, globalLight: globalLight))
        return w.data
    }

    /// Decodes an 'lfx2' or 'lmfx' payload. Returns nil if the payload is malformed.
    package static func decode(_ payload: Data) -> LayerEffects? {
        guard let root = try? rootDescriptor(payload) else { return nil }
        return effects(from: root)
    }

    package static func rootDescriptor(_ payload: Data) throws -> PSDDescriptor {
        var r = PSDDescriptorReader(payload)
        let version = try r.u32()
        guard version == 0 else { throw PSDDescriptorError.invalid("effects version \(version)") }
        let dv = try r.u32()
        guard dv == 16 else { throw PSDDescriptorError.invalid("descriptor version \(dv)") }
        return try r.descriptor()
    }

    // MARK: Building

    package static func descriptor(_ fx: LayerEffects, globalLight: GlobalLight? = nil) -> PSDDescriptor {
        var root = PSDDescriptor(classID: "null")
        let light = globalLight.flatMap { $0.angle.isFinite && $0.altitude.isFinite ? $0 : nil }
        root["Scl "] = pct(100)
        root["masterFXSwitch"] = .bool(fx.enabled)

        // Every effect of the style is written ('present'); one hidden with its eye in the Layers panel has 'enab' false.
        let drops = fx.dropShadows.filter(\.isListed)
        let inners = fx.innerShadows.filter(\.isListed)
        let fills = fx.colorOverlays.filter(\.isListed)
        let grads = fx.gradientOverlays.filter(\.isListed)
        let strokes = fx.strokes.filter { $0.isListed && !$0.paint.isNone }
        var usedMulti = false

        func put(_ single: String, _ multiKey: String, _ items: [PSDDescriptor]) {
            if items.count > 1 {
                root[multiKey] = .list(items.map { .object($0) })
                usedMulti = true
            } else if let first = items.first {
                root[single] = .object(first)
            }
        }

        // Photoshop CC key order.
        put("DrSh", "dropShadowMulti", drops.map { shadow($0, inner: false, light: light) })
        put("IrSh", "innerShadowMulti", inners.map { shadow($0, inner: true, light: light) })
        if fx.outerGlow.isListed { root["OrGl"] = .object(glow(fx.outerGlow, inner: false)) }
        put("SoFi", "solidFillMulti", fills.map(colorOverlay))
        put("GrFl", "gradientFillMulti", grads.map(gradientOverlay))
        if fx.patternOverlay.isListed { root["patternFill"] = .object(patternOverlay(fx.patternOverlay)) }
        put("FrFX", "frameFXMulti", strokes.map(stroke))
        if fx.innerGlow.isListed { root["IrGl"] = .object(glow(fx.innerGlow, inner: true)) }
        if fx.bevel.isListed { root["ebbl"] = .object(bevel(fx.bevel, light: light)) }
        if fx.satin.isListed { root["ChFX"] = .object(satin(fx.satin)) }
        if usedMulti {
            let singles = [fx.outerGlow.isListed, fx.innerGlow.isListed, fx.bevel.isListed, fx.patternOverlay.isListed, fx.satin.isListed]
            let n = drops.count + inners.count + fills.count + grads.count + strokes.count + singles.filter { $0 }.count
            root["numModifyingFX"] = .integer(Int32(n))
        }
        return root
    }

    private static func pct(_ v: Double) -> V { .unitFloat(unit: "#Prc", value: v) }
    private static func px(_ v: Double) -> V { .unitFloat(unit: "#Pxl", value: v) }
    private static func ang(_ v: Double) -> V { .unitFloat(unit: "#Ang", value: v) }
    private static func en(_ type: String, _ v: String) -> V { .enumerated(type: type, value: v) }
    private static func fin(_ v: Double, _ fallback: Double = 0) -> Double { v.isFinite ? v : fallback }

    private static func color(_ c: RGBA) -> V {
        .object(PSDDescriptor(classID: "RGBC", [
            ("Rd  ", .double(clamp(fin(c.r), 0, 1) * 255)),
            ("Grn ", .double(clamp(fin(c.g), 0, 1) * 255)),
            ("Bl  ", .double(clamp(fin(c.b), 0, 1) * 255)),
        ]))
    }

    /// Photoshop colors carry no alpha: fold it into the effect opacity.
    private static func opacity(_ o: Double, _ c: RGBA) -> V { pct(clamp(fin(o, 1) * clamp(fin(c.a, 1), 0, 1), 0, 1) * 100) }
    private static func opacity(_ o: Double) -> V { pct(clamp(fin(o, 1), 0, 1) * 100) }

    private static func mode(_ m: BlendMode) -> V { en("BlnM", m.descriptorKey) }

    private static func contour(_ name: String = "Linear", _ pts: [(Double, Double)] = [(0, 0), (255, 255)]) -> V {
        .object(PSDDescriptor(classID: "ShpC", [
            ("Nm  ", .string(name)),
            ("Crv ", .list(pts.map { p in .object(PSDDescriptor(classID: "CrPt", [("Hrzn", .double(p.0)), ("Vrtc", .double(p.1))])) })),
        ]))
    }

    private static func head(_ enabled: Bool) -> [(String, V)] {
        [("enab", .bool(enabled)), ("present", .bool(true)), ("showInDialog", .bool(true))]
    }

    private static func shadow(_ s: ShadowEffect, inner: Bool, light: GlobalLight? = nil) -> PSDDescriptor {
        let angle = s.useGlobalLight ? (light?.angle ?? s.angle) : s.angle
        var items = head(s.enabled) + [
            ("Md  ", mode(s.blendMode)),
            ("Clr ", color(s.color)),
            ("Opct", opacity(s.opacity, s.color)),
            ("uglg", .bool(s.useGlobalLight)),
            ("lagl", ang(fin(angle, 120))),
            ("Dstn", px(max(0, fin(s.distance)))),
            ("Ckmt", px(clamp(fin(s.spread), 0, 100))),
            ("blur", px(max(0, fin(s.size)))),
            ("Nose", pct(clamp(fin(s.noise), 0, 100))),
            ("AntA", .bool(false)),
            ("TrnS", contour()),
        ]
        if !inner { items.append(("layerConceals", .bool(s.layerKnocksOut))) }
        return PSDDescriptor(classID: inner ? "IrSh" : "DrSh", items)
    }

    private static func glow(_ g: GlowEffect, inner: Bool) -> PSDDescriptor {
        var items = head(g.enabled) + [
            ("Md  ", mode(g.blendMode)),
            ("Clr ", color(g.color)),
            ("Opct", opacity(g.opacity, g.color)),
            ("GlwT", en("BETE", g.technique == .precise ? "PrBL" : "SfBL")),
            ("Ckmt", px(clamp(fin(g.spread), 0, 100))),
            ("blur", px(max(0, fin(g.size)))),
            ("Nose", pct(clamp(fin(g.noise), 0, 100))),
            ("ShdN", pct(clamp(fin(g.jitter), 0, 100))),
            ("AntA", .bool(false)),
        ]
        if inner { items.append(("glwS", en("IGSr", g.source == .center ? "SrcC" : "SrcE"))) }
        items += [("TrnS", contour()), ("Inpr", pct(clamp(fin(g.range, 50), 1, 100)))]
        return PSDDescriptor(classID: inner ? "IrGl" : "OrGl", items)
    }

    private static func bevel(_ b: BevelEffect, light: GlobalLight? = nil) -> PSDDescriptor {
        let angle = b.useGlobalLight ? (light?.angle ?? b.angle) : b.angle
        let altitude = b.useGlobalLight ? (light?.altitude ?? b.altitude) : b.altitude
        let style: String
        switch b.style {
        case .innerBevel: style = "InrB"
        case .outerBevel: style = "OtrB"
        case .emboss: style = "Embs"
        case .pillowEmboss: style = "PlEb"
        }
        let tech: String
        switch b.technique {
        case .smooth: tech = "SfBL"
        case .chiselHard: tech = "PrBL"
        case .chiselSoft: tech = "Slmt"
        }
        return PSDDescriptor(classID: "ebbl", head(b.enabled) + [
            ("hglM", mode(b.highlightMode)),
            ("hglC", color(b.highlightColor)),
            ("hglO", opacity(b.highlightOpacity, b.highlightColor)),
            ("sdwM", mode(b.shadowMode)),
            ("sdwC", color(b.shadowColor)),
            ("sdwO", opacity(b.shadowOpacity, b.shadowColor)),
            ("bvlT", en("bvlT", tech)),
            ("bvlS", en("BESl", style)),
            ("uglg", .bool(b.useGlobalLight)),
            ("lagl", ang(fin(angle, 120))),
            ("Lald", ang(fin(altitude, 30))),
            ("srgR", pct(max(0, fin(b.depth, 100)))),
            ("blur", px(max(0, fin(b.size)))),
            ("bvlD", en("BESs", b.directionUp ? "In  " : "Out ")),
            ("TrnS", contour()),
            ("antialiasGloss", .bool(false)),
            ("Sftn", px(max(0, fin(b.soften)))),
            ("useShape", .bool(false)),
            ("useTexture", .bool(false)),
        ])
    }

    private static func satin(_ s: SatinEffect) -> PSDDescriptor {
        PSDDescriptor(classID: "ChFX", head(s.enabled) + [
            ("Md  ", mode(s.blendMode)),
            ("Clr ", color(s.color)),
            ("AntA", .bool(true)),
            ("Invr", .bool(s.invert)),
            ("Opct", opacity(s.opacity, s.color)),
            ("lagl", ang(fin(s.angle, 19))),
            ("Dstn", px(max(0, fin(s.distance)))),
            ("blur", px(max(0, fin(s.size)))),
            // Photoshop's default satin contour ("Gaussian"-like S curve).
            ("MpgS", contour("Gaussian", [(0, 0), (64, 18), (128, 128), (192, 237), (255, 255)])),
        ])
    }

    private static func colorOverlay(_ c: ColorOverlayEffect) -> PSDDescriptor {
        PSDDescriptor(classID: "SoFi", head(c.enabled) + [
            ("Md  ", mode(c.blendMode)),
            ("Clr ", color(c.color)),
            ("Opct", opacity(c.opacity, c.color)),
        ])
    }

    private static func gradientType(_ t: GradientType) -> String {
        switch t {
        case .linear: return "Lnr "
        case .radial: return "Rdl "
        case .angle: return "Angl"
        case .reflected: return "Rflc"
        case .diamond: return "Dmnd"
        }
    }

    private static func gradient(_ g: ColorGradient) -> V {
        var stops = g.sortedStops
        if stops.isEmpty { stops = ColorGradient.twoColor(.black, .white).stops }
        let loc: (GradientStop) -> V = { .integer(Int32(clamp(fin($0.location), 0, 1) * 4096 + 0.5)) }
        let clrs: [V] = stops.map { s in
            .object(PSDDescriptor(classID: "Clrt", [("Clr ", color(s.color)), ("Type", en("Clry", "UsrS")), ("Lctn", loc(s)), ("Mdpn", .integer(50))]))
        }
        let trns: [V] = stops.map { s in
            .object(PSDDescriptor(classID: "TrnS", [("Opct", pct(clamp(fin(s.color.a, 1), 0, 1) * 100)), ("Lctn", loc(s)), ("Mdpn", .integer(50))]))
        }
        return .object(PSDDescriptor(classID: "Grdn", [
            ("Nm  ", .string(g.name)),
            ("GrdF", en("GrdF", "CstS")),
            ("Intr", .double(4096)),
            ("Clrs", .list(clrs)),
            ("Trns", .list(trns)),
        ]))
    }

    private static func gradientFillItems(_ f: GradientFill) -> [(String, V)] {
        [
            ("Grad", gradient(f.gradient)),
            ("Angl", ang(fin(f.angle, 90))),
            ("Type", en("GrdT", gradientType(f.type))),
            ("Rvrs", .bool(f.reverse)),
            ("Dthr", .bool(f.dither)),
            ("Algn", .bool(true)),
            ("Scl ", pct(max(0, fin(f.scale, 1)) * 100)),
            ("Ofst", .object(PSDDescriptor(classID: "Pnt ", [("Hrzn", pct(0)), ("Vrtc", pct(0))]))),
        ]
    }

    private static func gradientOverlay(_ g: GradientOverlayEffect) -> PSDDescriptor {
        PSDDescriptor(classID: "GrFl", head(g.enabled) + [("Md  ", mode(g.blendMode)), ("Opct", opacity(g.opacity))] + gradientFillItems(g.fill))
    }

    private static func pattern(_ id: String) -> V {
        .object(PSDDescriptor(classID: "Ptrn", [("Nm  ", .string(id)), ("Idnt", .string(id))]))
    }

    private static func phase() -> V {
        .object(PSDDescriptor(classID: "Pnt ", [("Hrzn", .double(0)), ("Vrtc", .double(0))]))
    }

    private static func patternOverlay(_ p: PatternOverlayEffect) -> PSDDescriptor {
        PSDDescriptor(classID: "patternFill", head(p.enabled) + [
            ("Md  ", mode(p.blendMode)),
            ("Opct", opacity(p.opacity)),
            ("Ptrn", pattern(p.patternID)),
            ("Algn", .bool(true)),
            ("Scl ", pct(max(0, fin(p.scale, 1)) * 100)),
            ("phase", phase()),
        ])
    }

    private static func stroke(_ s: StrokeEffect) -> PSDDescriptor {
        let style: String
        switch s.position {
        case .outside: style = "OutF"
        case .inside: style = "InsF"
        case .center: style = "CtrF"
        }
        var items = head(s.enabled) + [
            ("Styl", en("FStl", style)),
        ]
        var c = RGBA.black
        var tail: [(String, V)] = []
        var paintType = "SClr"
        switch s.paint {
        case .none: break
        case .color(let col): c = col
        case .gradient(let f): paintType = "GrFl"; tail = gradientFillItems(f)
        case .pattern(let id, let scale):
            paintType = "Ptrn"
            tail = [("Ptrn", pattern(id)), ("Lnkd", .bool(true)), ("Scl ", pct(max(0, fin(scale, 1)) * 100)), ("phase", phase())]
        }
        items += [
            ("PntT", en("FrFl", paintType)),
            ("Md  ", mode(s.blendMode)),
            ("Opct", paintType == "SClr" ? opacity(s.opacity, c) : opacity(s.opacity)),
            ("Sz  ", px(max(0, fin(s.size)))),
            ("Clr ", color(c)),
            ("overprint", .bool(false)),
        ]
        return PSDDescriptor(classID: "FrFX", items + tail)
    }

    // MARK: Parsing

    package static func effects(from root: PSDDescriptor) -> LayerEffects {
        var fx = LayerEffects()
        let d = LayerEffects()
        fx.enabled = root.bool("masterFXSwitch") ?? true
        // 'Scl ' is not a factor to apply: it follows the document resolution (416.7 % = 300 / 72 ppi) while the stored sizes
        // are the ones Photoshop draws (a 70 px glow in a 300 ppi file reaches ~60 px, not 290)
        let scale = 1.0

        // Photoshop writes an effect that is not part of the style with 'present' false (the dialog keeps its settings),
        // sometimes as a '…Multi' list holding only such placeholders next to the classic key with the real effect: the
        // list wins only when it holds an effect that is present.
        func instances(_ single: String, _ multi: String?) -> [PSDDescriptor] {
            func present(_ l: [PSDDescriptor]) -> [PSDDescriptor] { l.filter { $0.bool("present") ?? true } }
            if let multi, let l = root.list(multi) {
                let out = present(l.compactMap(\.objectValue))
                if !out.isEmpty { return out }
            }
            return present(root.object(single).map { [$0] } ?? [])
        }

        let drops = instances("DrSh", "dropShadowMulti").map { parseShadow($0, base: d.dropShadow, scale: scale) }
        if let f = drops.first { fx.dropShadow = f; fx.extraDropShadows = Array(drops.dropFirst()) }
        let inners = instances("IrSh", "innerShadowMulti").map { parseShadow($0, base: d.innerShadow, scale: scale) }
        if let f = inners.first { fx.innerShadow = f; fx.extraInnerShadows = Array(inners.dropFirst()) }
        if let o = instances("OrGl", nil).first { fx.outerGlow = parseGlow(o, base: d.outerGlow, scale: scale) }
        if let o = instances("IrGl", nil).first { fx.innerGlow = parseGlow(o, base: d.innerGlow, scale: scale) }
        if let o = instances("ebbl", nil).first { fx.bevel = parseBevel(o, base: d.bevel, scale: scale) }
        if let o = instances("ChFX", nil).first { fx.satin = parseSatin(o, base: d.satin, scale: scale) }
        let fills = instances("SoFi", "solidFillMulti").map { parseColorOverlay($0, base: d.colorOverlay) }
        if let f = fills.first { fx.colorOverlay = f; fx.extraColorOverlays = Array(fills.dropFirst()) }
        let grads = instances("GrFl", "gradientFillMulti").map { parseGradientOverlay($0, base: d.gradientOverlay) }
        if let f = grads.first { fx.gradientOverlay = f; fx.extraGradientOverlays = Array(grads.dropFirst()) }
        if let o = instances("patternFill", nil).first { fx.patternOverlay = parsePatternOverlay(o, base: d.patternOverlay) }
        let strokes = instances("FrFX", "frameFXMulti").map { parseStroke($0, base: d.stroke, scale: scale) }
        if let f = strokes.first { fx.stroke = f; fx.extraStrokes = Array(strokes.dropFirst()) }
        return fx
    }

    private static func num(_ d: PSDDescriptor, _ key: String, _ fallback: Double, _ lo: Double = -1e6, _ hi: Double = 1e6) -> Double {
        guard let v = d.double(key), v.isFinite else { return fallback }
        return clamp(v, lo, hi)
    }
    private static func percent(_ d: PSDDescriptor, _ key: String, _ fallback: Double) -> Double {
        guard let v = d.double(key), v.isFinite else { return fallback }
        return clamp(v / 100, 0, 1)
    }
    private static func blend(_ d: PSDDescriptor, _ key: String, _ fallback: BlendMode) -> BlendMode {
        guard let e = d.enumValue(key) else { return fallback }
        return BlendMode(descriptorKey: e) ?? fallback
    }

    /// Parses 'RGBC' (0-255 or float), 'HSBC', 'Grsc', 'CMYC', 'LbCl' color objects.
    package static func parseColor(_ o: PSDDescriptor?) -> RGBA? {
        guard let o else { return nil }
        func c(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? clamp($0, 0, 1) : nil } }
        if let r = o.double("Rd  "), let g = o.double("Grn "), let b = o.double("Bl  ") {
            if let rr = c(r / 255), let gg = c(g / 255), let bb = c(b / 255) { return RGBA(r: rr, g: gg, b: bb) }
        }
        if let r = c(o.double("redFloat")), let g = c(o.double("greenFloat")), let b = c(o.double("blueFloat")) { return RGBA(r: r, g: g, b: b) }
        if let h = o.double("H   "), let s = o.double("Strt"), let v = o.double("Brgh"), h.isFinite, s.isFinite, v.isFinite {
            let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
            let ss = clamp(s / 100, 0, 1), vv = clamp(v / 100, 0, 1)
            let i = Int(hh) % 6, f = hh - floor(hh)
            let p = vv * (1 - ss), q = vv * (1 - ss * f), t = vv * (1 - ss * (1 - f))
            let rgb: [(Double, Double, Double)] = [(vv, t, p), (q, vv, p), (p, vv, t), (p, q, vv), (t, p, vv), (vv, p, q)]
            return RGBA(r: rgb[i].0, g: rgb[i].1, b: rgb[i].2)
        }
        if let g = c(o.double("Gry ").map { 1 - $0 / 100 }) { return RGBA(gray: g) }
        if let cy = o.double("Cyn "), let m = o.double("Mgnt"), let y = o.double("Ylw "), let k = o.double("Blck") {
            let kk = 1 - (c(k / 100) ?? 0)
            return RGBA(r: (1 - (c(cy / 100) ?? 0)) * kk, g: (1 - (c(m / 100) ?? 0)) * kk, b: (1 - (c(y / 100) ?? 0)) * kk)
        }
        if let L = o.double("Lmnc"), let A = o.double("A   "), let B = o.double("B   "), L.isFinite, A.isFinite, B.isFinite {
            // Lab (D50) → XYZ → linear sRGB (Bradford-adapted) → sRGB.
            let fy = (L + 16) / 116, fx = fy + A / 500, fz = fy - B / 200
            func finv(_ t: Double) -> Double { t > 6.0 / 29 ? t * t * t : 3 * (6.0 / 29) * (6.0 / 29) * (t - 4.0 / 29) }
            let X = 0.9642 * finv(fx), Y = finv(fy), Z = 0.8249 * finv(fz)
            let lr = 3.1339 * X - 1.6169 * Y - 0.4906 * Z
            let lg = -0.9785 * X + 1.9160 * Y + 0.0333 * Z
            let lb = 0.0720 * X - 0.2290 * Y + 1.4057 * Z
            func gamma(_ v: Double) -> Double { let x = clamp(v, 0, 1); return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
            return RGBA(r: gamma(lr), g: gamma(lg), b: gamma(lb))
        }
        return nil
    }

    private static func parseShadow(_ o: PSDDescriptor, base: ShadowEffect, scale: Double) -> ShadowEffect {
        var s = base
        s.enabled = o.bool("enab") ?? true; s.isHidden = !s.enabled   // present but switched off: listed with its eye closed
        s.blendMode = blend(o, "Md  ", base.blendMode)
        s.color = parseColor(o.object("Clr ")) ?? base.color
        s.opacity = percent(o, "Opct", base.opacity)
        s.angle = num(o, "lagl", base.angle, -360, 360)
        // without "Use Global Light" the effect keeps its own angle (Photoshop writes uglg on every shadow)
        s.useGlobalLight = o.bool("uglg") ?? base.useGlobalLight
        s.distance = num(o, "Dstn", base.distance, 0, 30000) * scale
        s.spread = num(o, "Ckmt", base.spread, 0, 100)
        s.size = num(o, "blur", base.size, 0, 1000) * scale
        s.noise = num(o, "Nose", base.noise, 0, 100)
        s.contour = parseContour(o.object("TrnS")) ?? base.contour
        s.layerKnocksOut = o.bool("layerConceals") ?? base.layerKnocksOut
        return s
    }

    private static func parseGlow(_ o: PSDDescriptor, base: GlowEffect, scale: Double) -> GlowEffect {
        var g = base
        g.enabled = o.bool("enab") ?? true; g.isHidden = !g.enabled   // present but switched off: listed with its eye closed
        g.blendMode = blend(o, "Md  ", base.blendMode)
        if let c = parseColor(o.object("Clr ")) {
            g.color = c
        } else if let grad = parseGradient(o.object("Grad")), let first = grad.sortedStops.first {
            // Gradient glows are approximated by their first stop.
            g.color = RGBA(r: first.color.r, g: first.color.g, b: first.color.b)
        }
        g.opacity = percent(o, "Opct", base.opacity)
        g.spread = num(o, "Ckmt", base.spread, 0, 100)
        g.size = num(o, "blur", base.size, 0, 1000) * scale
        if let src = o.enumValue("glwS") { g.source = src == "SrcC" ? .center : .edge }
        if let t = o.enumValue("GlwT") { g.technique = t == "PrBL" || t == "Slmt" ? .precise : .softer }
        g.range = num(o, "Inpr", base.range, 1, 100)
        g.noise = num(o, "Nose", base.noise, 0, 100)
        g.jitter = num(o, "ShdN", base.jitter, 0, 100)
        g.contour = parseContour(o.object("TrnS")) ?? base.contour
        return g
    }

    private static func parseBevel(_ o: PSDDescriptor, base: BevelEffect, scale: Double) -> BevelEffect {
        var b = base
        b.enabled = o.bool("enab") ?? true; b.isHidden = !b.enabled   // present but switched off: listed with its eye closed
        switch o.enumValue("bvlS") {
        case "InrB"?: b.style = .innerBevel
        case "OtrB"?: b.style = .outerBevel
        case "Embs"?: b.style = .emboss
        case "PlEb"?: b.style = .pillowEmboss
        default: break   // 'strokeEmboss' and unknown → keep default
        }
        switch o.enumValue("bvlT") {
        case "SfBL"?: b.technique = .smooth
        case "PrBL"?: b.technique = .chiselHard
        case "Slmt"?: b.technique = .chiselSoft
        default: break
        }
        b.depth = num(o, "srgR", base.depth, 0, 1000)
        if let dir = o.enumValue("bvlD") { b.directionUp = dir != "Out " }
        b.size = num(o, "blur", base.size, 0, 1000) * scale
        b.soften = num(o, "Sftn", base.soften, 0, 1000) * scale
        b.angle = num(o, "lagl", base.angle, -360, 360)
        b.useGlobalLight = o.bool("uglg") ?? base.useGlobalLight
        b.altitude = num(o, "Lald", base.altitude, 0, 90)
        b.glossContour = parseContour(o.object("TrnS")) ?? base.glossContour
        if o.bool("useShape") == true, let c = parseContour(o.object("MpgS")) {
            b.contourEnabled = true
            b.contour = c
            b.contourRange = num(o, "Inpr", base.contourRange, 1, 100)
        }
        b.highlightMode = blend(o, "hglM", base.highlightMode)
        b.highlightColor = parseColor(o.object("hglC")) ?? base.highlightColor
        b.highlightOpacity = percent(o, "hglO", base.highlightOpacity)
        b.shadowMode = blend(o, "sdwM", base.shadowMode)
        b.shadowColor = parseColor(o.object("sdwC")) ?? base.shadowColor
        b.shadowOpacity = percent(o, "sdwO", base.shadowOpacity)
        return b
    }

    /// 'ShpC' contour: Linear → the preset, anything else → its curve points (0…255 both ways).
    package static func parseContour(_ o: PSDDescriptor?) -> Contour? {
        guard let o, let list = o.list("Crv ") else { return nil }
        let pts: [CGPoint] = list.compactMap { v in
            guard let p = v.objectValue, let x = p.double("Hrzn"), let y = p.double("Vrtc"), x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: clamp(x, 0, 255) / 255, y: clamp(y, 0, 255) / 255)
        }
        guard pts.count >= 2 else { return nil }
        var c = Contour()
        let curve = CurvePoints(points: pts.sorted { $0.x < $1.x })
        if !curve.isIdentity { c.preset = .custom; c.custom = curve }
        return c
    }

    private static func parseSatin(_ o: PSDDescriptor, base: SatinEffect, scale: Double) -> SatinEffect {
        var s = base
        s.enabled = o.bool("enab") ?? true; s.isHidden = !s.enabled   // present but switched off: listed with its eye closed
        s.blendMode = blend(o, "Md  ", base.blendMode)
        s.color = parseColor(o.object("Clr ")) ?? base.color
        s.opacity = percent(o, "Opct", base.opacity)
        s.angle = num(o, "lagl", base.angle, -360, 360)
        s.distance = num(o, "Dstn", base.distance, 0, 30000) * scale
        s.size = num(o, "blur", base.size, 0, 1000) * scale
        s.invert = o.bool("Invr") ?? base.invert
        return s
    }

    private static func parseColorOverlay(_ o: PSDDescriptor, base: ColorOverlayEffect) -> ColorOverlayEffect {
        var c = base
        c.enabled = o.bool("enab") ?? true; c.isHidden = !c.enabled   // present but switched off: listed with its eye closed
        c.blendMode = blend(o, "Md  ", base.blendMode)
        c.color = parseColor(o.object("Clr ")) ?? base.color
        c.opacity = percent(o, "Opct", base.opacity)
        return c
    }

    /// Parses a 'Grdn' gradient object. Color and transparency stops are merged at the union of their locations.
    package static func parseGradient(_ o: PSDDescriptor?) -> ColorGradient? {
        guard let o else { return nil }
        let name = o.string("Nm  ") ?? "Gradient"
        if o.enumValue("GrdF") == "ClNs" {   // noise gradient: not representable
            return ColorGradient.twoColor(.black, .white, name: name)
        }
        func location(_ d: PSDDescriptor) -> Double { clamp(num(d, "Lctn", 0) / 4096, 0, 1) }
        var colorStops: [(Double, RGBA)] = []
        for v in o.list("Clrs") ?? [] {
            guard let s = v.objectValue else { continue }
            var col = parseColor(s.object("Clr "))
            if col == nil {
                switch s.enumValue("Type") {
                case "BckC"?: col = .white
                default: col = .black
                }
            }
            colorStops.append((location(s), col!))
        }
        var alphaStops: [(Double, Double)] = []
        for v in o.list("Trns") ?? [] {
            guard let s = v.objectValue else { continue }
            alphaStops.append((location(s), percent(s, "Opct", 1)))
        }
        guard !colorStops.isEmpty || !alphaStops.isEmpty else { return nil }
        colorStops.sort { $0.0 < $1.0 }
        alphaStops.sort { $0.0 < $1.0 }

        func interpColor(_ t: Double) -> RGBA {
            guard let first = colorStops.first, let last = colorStops.last else { return .black }
            if t <= first.0 { return first.1 }
            if t >= last.0 { return last.1 }
            for i in 0..<(colorStops.count - 1) where t >= colorStops[i].0 && t <= colorStops[i + 1].0 {
                let a = colorStops[i], b = colorStops[i + 1]
                let f = (t - a.0) / max(1e-9, b.0 - a.0)
                return RGBA(r: a.1.r + (b.1.r - a.1.r) * f, g: a.1.g + (b.1.g - a.1.g) * f, b: a.1.b + (b.1.b - a.1.b) * f)
            }
            return last.1
        }
        func interpAlpha(_ t: Double) -> Double {
            guard let first = alphaStops.first, let last = alphaStops.last else { return 1 }
            if t <= first.0 { return first.1 }
            if t >= last.0 { return last.1 }
            for i in 0..<(alphaStops.count - 1) where t >= alphaStops[i].0 && t <= alphaStops[i + 1].0 {
                let a = alphaStops[i], b = alphaStops[i + 1]
                return a.1 + (b.1 - a.1) * (t - a.0) / max(1e-9, b.0 - a.0)
            }
            return last.1
        }
        var locs: [Double] = []
        for l in (colorStops.map(\.0) + alphaStops.map(\.0)).sorted() where locs.last.map({ abs($0 - l) > 1e-6 }) ?? true {
            locs.append(l)
        }
        let stops = locs.prefix(256).map { t -> GradientStop in
            var c = interpColor(t)
            c.a = interpAlpha(t)
            return GradientStop(location: t, color: c)
        }
        return ColorGradient(name: name, stops: Array(stops))
    }

    private static func parseGradientFill(_ o: PSDDescriptor, base: GradientFill) -> GradientFill {
        var f = base
        if let g = parseGradient(o.object("Grad")) { f.gradient = g }
        switch o.enumValue("Type") {
        case "Lnr "?: f.type = .linear
        case "Rdl "?: f.type = .radial
        case "Angl"?: f.type = .angle
        case "Rflc"?: f.type = .reflected
        case "Dmnd"?: f.type = .diamond
        default: break
        }
        f.angle = num(o, "Angl", base.angle, -360, 360)
        f.scale = num(o, "Scl ", base.scale * 100, 1, 10000) / 100
        f.reverse = o.bool("Rvrs") ?? base.reverse
        f.dither = o.bool("Dthr") ?? base.dither
        f.start = nil
        f.end = nil
        return f
    }

    private static func parseGradientOverlay(_ o: PSDDescriptor, base: GradientOverlayEffect) -> GradientOverlayEffect {
        var g = base
        g.enabled = o.bool("enab") ?? true; g.isHidden = !g.enabled   // present but switched off: listed with its eye closed
        g.blendMode = blend(o, "Md  ", base.blendMode)
        g.opacity = percent(o, "Opct", base.opacity)
        g.fill = parseGradientFill(o, base: base.fill)
        return g
    }

    private static func patternID(_ o: PSDDescriptor?) -> String? {
        guard let o else { return nil }
        if let id = o.string("Idnt"), !id.isEmpty { return id }
        if let n = o.string("Nm  "), !n.isEmpty { return n }
        return nil
    }

    private static func parsePatternOverlay(_ o: PSDDescriptor, base: PatternOverlayEffect) -> PatternOverlayEffect {
        var p = base
        p.enabled = o.bool("enab") ?? true; p.isHidden = !p.enabled   // present but switched off: listed with its eye closed
        p.blendMode = blend(o, "Md  ", base.blendMode)
        p.opacity = percent(o, "Opct", base.opacity)
        p.patternID = patternID(o.object("Ptrn")) ?? base.patternID
        p.scale = num(o, "Scl ", base.scale * 100, 1, 10000) / 100
        return p
    }

    private static func parseStroke(_ o: PSDDescriptor, base: StrokeEffect, scale: Double) -> StrokeEffect {
        var s = base
        s.enabled = o.bool("enab") ?? true; s.isHidden = !s.enabled   // present but switched off: listed with its eye closed
        switch o.enumValue("Styl") {
        case "OutF"?: s.position = .outside
        case "InsF"?: s.position = .inside
        case "CtrF"?: s.position = .center
        default: break
        }
        s.blendMode = blend(o, "Md  ", base.blendMode)
        s.opacity = percent(o, "Opct", base.opacity)
        s.size = num(o, "Sz  ", base.size, 0, 1000) * scale
        switch o.enumValue("PntT") {
        case "GrFl"?:
            s.paint = .gradient(parseGradientFill(o, base: GradientFill(gradient: ColorGradient.presets[0])))
        case "Ptrn"?:
            s.paint = .pattern(id: patternID(o.object("Ptrn")) ?? "checker", scale: num(o, "Scl ", 100, 1, 10000) / 100)
        default:
            s.paint = .color(parseColor(o.object("Clr ")) ?? .black)
        }
        return s
    }
}

// MARK: - Blend mode descriptor enums ('BlnM')

extension BlendMode {
    package var descriptorKey: String {
        switch self {
        case .passThrough: return "passThrough"
        case .normal: return "Nrml"
        case .dissolve: return "Dslv"
        case .darken: return "Drkn"
        case .multiply: return "Mltp"
        case .colorBurn: return "CBrn"
        case .linearBurn: return "linearBurn"
        case .darkerColor: return "darkerColor"
        case .lighten: return "Lghn"
        case .screen: return "Scrn"
        case .colorDodge: return "CDdg"
        case .linearDodge: return "linearDodge"
        case .lighterColor: return "lighterColor"
        case .overlay: return "Ovrl"
        case .softLight: return "SftL"
        case .hardLight: return "HrdL"
        case .vividLight: return "vividLight"
        case .linearLight: return "linearLight"
        case .pinLight: return "pinLight"
        case .hardMix: return "hardMix"
        case .difference: return "Dfrn"
        case .exclusion: return "Xclu"
        case .subtract: return "blendSubtraction"
        case .divide: return "blendDivide"
        case .hue: return "H   "
        case .saturation: return "Strt"
        case .color: return "Clr "
        case .luminosity: return "Lmns"
        }
    }

    package init?(descriptorKey: String) {
        switch descriptorKey {
        case "Sbtr": self = .subtract
        case "Dvd ": self = .divide
        default:
            if let m = BlendMode.allCases.first(where: { $0.descriptorKey == descriptorKey }) {
                self = m
            } else if let m = BlendMode.longDescriptorKeys[descriptorKey] {
                // newer Photoshop versions write the long string IDs ('multiply', 'screen'…) in layer styles
                self = m
            } else {
                return nil
            }
        }
    }

    /// Photoshop's long string IDs for the modes whose descriptor key is a four-character code.
    package static let longDescriptorKeys: [String: BlendMode] = [
        "passThrough": .passThrough, "normal": .normal, "dissolve": .dissolve, "darken": .darken, "multiply": .multiply,
        "colorBurn": .colorBurn, "lighten": .lighten, "screen": .screen, "colorDodge": .colorDodge, "overlay": .overlay,
        "softLight": .softLight, "hardLight": .hardLight, "difference": .difference, "exclusion": .exclusion,
        "subtract": .subtract, "divide": .divide, "hue": .hue, "saturation": .saturation, "color": .color, "luminosity": .luminosity,
    ]
}
