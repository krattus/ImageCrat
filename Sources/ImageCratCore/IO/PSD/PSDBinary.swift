import Foundation

// MARK: - Binary helpers

package struct BinaryWriter {
    package var data = Data()
    @inlinable package mutating func u8(_ v: UInt8) { data.append(v) }
    @inlinable package mutating func u16(_ v: UInt16) { data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xff)) }
    @inlinable package mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    @inlinable package mutating func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(v & 0xffff)) }
    @inlinable package mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    @inlinable package mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xffff_ffff)) }
    /// Section/channel length: 4 bytes in PSD, 8 bytes in PSB (`large`).
    @inlinable package mutating func len(_ v: Int, large: Bool) { if large { u64(UInt64(v)) } else { u32(UInt32(v)) } }
    @inlinable package mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    @inlinable package mutating func raw(_ d: Data) { data.append(d) }
    @inlinable package mutating func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
    @inlinable package mutating func pascal(_ s: String, pad: Int) {
        let b = Array(s.utf8.prefix(255))
        u8(UInt8(b.count))
        bytes(b)
        var len = b.count + 1
        while len % pad != 0 { u8(0); len += 1 }
    }
    @inlinable package mutating func unicode(_ s: String) {
        let u = Array(s.utf16)
        u32(UInt32(u.count))
        for c in u { u16(c) }
    }
    @inlinable package init(data: Data = Data()) {
        self.data = data
    }
}

package struct BinaryReader {
    package let data: Data
    package var pos = 0
    @inlinable package init(_ d: Data) { data = d }
    @inlinable package var remaining: Int { data.count - pos }
    @inlinable package mutating func u8() throws -> UInt8 {
        guard pos < data.count else { throw DocumentIOError.unreadable }
        let v = data[data.startIndex + pos]; pos += 1; return v
    }
    @inlinable package mutating func u16() throws -> UInt16 { UInt16(try u8()) << 8 | UInt16(try u8()) }
    @inlinable package mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    @inlinable package mutating func u32() throws -> UInt32 { UInt32(try u16()) << 16 | UInt32(try u16()) }
    @inlinable package mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    @inlinable package mutating func u64() throws -> UInt64 { UInt64(try u32()) << 32 | UInt64(try u32()) }
    /// Section/channel length: 4 bytes in PSD, 8 bytes in PSB (`large`).
    @inlinable package mutating func len(large: Bool) throws -> Int {
        if large { let v = try u64(); guard v < UInt64(Int.max) else { throw DocumentIOError.unreadable }; return Int(v) }
        return Int(try u32())
    }
    @inlinable package mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, pos + n <= data.count else { throw DocumentIOError.unreadable }
        let d = data.subdata(in: (data.startIndex + pos)..<(data.startIndex + pos + n)); pos += n; return d
    }
    @inlinable package mutating func skip(_ n: Int) throws { guard pos + n <= data.count else { throw DocumentIOError.unreadable }; pos += n }
    @inlinable package mutating func ascii(_ n: Int) throws -> String { String(decoding: try bytes(n), as: UTF8.self) }
}

package enum PackBits {
    @inlinable package static func encode(_ row: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        let n = row.count
        var i = 0
        while i < n {
            // run?
            var run = 1
            while i + run < n && run < 128 && row[i + run] == row[i] { run += 1 }
            if run >= 3 {
                out.append(UInt8(bitPattern: Int8(-(run - 1))))
                out.append(row[i])
                i += run
                continue
            }
            // literal
            var lit = 0
            let start = i
            while i < n && lit < 128 {
                if i + 2 < n && row[i] == row[i + 1] && row[i] == row[i + 2] { break }
                i += 1; lit += 1
            }
            out.append(UInt8(lit - 1))
            out.append(contentsOf: row[start..<(start + lit)])
        }
        return out
    }

    @inlinable package static func decode(_ r: inout BinaryReader, into out: UnsafeMutablePointer<UInt8>, count: Int, byteLength: Int) throws {
        let end = r.pos + byteLength
        var o = 0
        while r.pos < end && o < count {
            let n = Int(Int8(bitPattern: try r.u8()))
            if n >= 0 {
                for _ in 0...n { let b = try r.u8(); if o < count { out[o] = b }; o += 1 }
            } else if n != -128 {
                let b = try r.u8()
                for _ in 0...(-n) { if o < count { out[o] = b }; o += 1 }
            }
        }
        r.pos = end
    }
}

// MARK: - Blend mode keys

extension BlendMode {
    @inlinable package var psdKey: String {
        switch self {
        case .passThrough: return "pass"
        case .normal: return "norm"
        case .dissolve: return "diss"
        case .darken: return "dark"
        case .multiply: return "mul "
        case .colorBurn: return "idiv"
        case .linearBurn: return "lbrn"
        case .darkerColor: return "dkCl"
        case .lighten: return "lite"
        case .screen: return "scrn"
        case .colorDodge: return "div "
        case .linearDodge: return "lddg"
        case .lighterColor: return "lgCl"
        case .overlay: return "over"
        case .softLight: return "sLit"
        case .hardLight: return "hLit"
        case .vividLight: return "vLit"
        case .linearLight: return "lLit"
        case .pinLight: return "pLit"
        case .hardMix: return "hMix"
        case .difference: return "diff"
        case .exclusion: return "smud"
        case .subtract: return "fsub"
        case .divide: return "fdiv"
        case .hue: return "hue "
        case .saturation: return "sat "
        case .color: return "colr"
        case .luminosity: return "lum "
        }
    }

    @inlinable package init(psdKey: String) {
        self = BlendMode.allCases.first { $0.psdKey == psdKey } ?? .normal
    }
}
