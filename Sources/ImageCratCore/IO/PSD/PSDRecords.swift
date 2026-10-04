import Foundation

// MARK: - PSD / PSB import
//
// Reads a Photoshop document into live Lumen layers: type, shapes, vector masks, adjustments, fill layers and
// smart objects become the matching layer kind; whatever Lumen cannot represent keeps the pixels Photoshop stored
// for the layer, and the reason is written to the import report. Every read is bounds-checked: a damaged file
// gives an error or a partial document, never a trap.

package enum PSDImportError: Error, CustomStringConvertible {
    case truncated
    case unsupported(String)
    case invalid(String)

    @inlinable package var description: String {
        switch self {
        case .truncated: return "the file ends early"
        case .unsupported(let s): return s
        case .invalid(let s): return s
        }
    }
}

/// Big-endian cursor over a shared byte array, limited to `start..<end`. Reads throw instead of trapping.
package struct PSDCursor {
    package let bytes: [UInt8]
    package let start: Int
    package let end: Int
    package private(set) var pos: Int

    @inlinable package init(_ bytes: [UInt8], _ range: Range<Int>? = nil) {
        self.bytes = bytes
        let lo = max(0, min(bytes.count, range?.lowerBound ?? 0))
        let hi = max(lo, min(bytes.count, range?.upperBound ?? bytes.count))
        start = lo; end = hi; pos = lo
    }

    @inlinable package var remaining: Int { end - pos }
    @inlinable package var atEnd: Bool { pos >= end }

    private func need(_ n: Int) throws { guard n >= 0, n <= end - pos else { throw PSDImportError.truncated } }

    @inlinable package mutating func u8() throws -> UInt8 { try need(1); defer { pos += 1 }; return bytes[pos] }
    @inlinable package mutating func u16() throws -> Int { try need(2); defer { pos += 2 }; return Int(bytes[pos]) << 8 | Int(bytes[pos + 1]) }
    @inlinable package mutating func i16() throws -> Int { Int(Int16(truncatingIfNeeded: try u16())) }
    @inlinable package mutating func u32() throws -> Int {
        try need(4); defer { pos += 4 }
        return Int(bytes[pos]) << 24 | Int(bytes[pos + 1]) << 16 | Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3])
    }
    @inlinable package mutating func i32() throws -> Int { Int(Int32(truncatingIfNeeded: try u32())) }
    @inlinable package mutating func u64() throws -> Int {
        let hi = try u32(), lo = try u32()
        guard hi < 0x4000_0000 else { throw PSDImportError.invalid("length out of range") }
        return hi << 32 | lo
    }
    @inlinable package mutating func f32() throws -> Double { Double(Float(bitPattern: UInt32(truncatingIfNeeded: try u32()))) }
    @inlinable package mutating func f64() throws -> Double {
        try need(8)
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(bytes[pos + i]) }
        pos += 8
        return Double(bitPattern: v)
    }
    /// Section / channel length: 4 bytes in PSD, 8 in PSB.
    @inlinable package mutating func len(large: Bool) throws -> Int { large ? try u64() : try u32() }
    @inlinable package mutating func skip(_ n: Int) throws { try need(n); pos += n }
    @inlinable package mutating func seek(_ p: Int) throws { guard p >= start, p <= end else { throw PSDImportError.truncated }; pos = p }
    @inlinable package mutating func take(_ n: Int) throws -> Range<Int> { try need(n); defer { pos += n }; return pos..<(pos + n) }
    /// Cursor over the next `n` bytes (advances past them).
    @inlinable package mutating func sub(_ n: Int) throws -> PSDCursor { PSDCursor(bytes, try take(n)) }
    @inlinable package mutating func fourCC() throws -> String {
        let r = try take(4)
        return String(String.UnicodeScalarView(bytes[r].map { Unicode.Scalar($0) }))
    }
    @inlinable package func peekFourCC() -> String? {
        guard pos + 4 <= end else { return nil }
        return String(String.UnicodeScalarView(bytes[pos..<(pos + 4)].map { Unicode.Scalar($0) }))
    }
    /// Pascal string padded so that length byte + text is a multiple of `pad`.
    @inlinable package mutating func pascal(pad: Int) throws -> String {
        let n = Int(try u8())
        let r = try take(n)
        var total = n + 1
        while total % max(1, pad) != 0, pos < end { pos += 1; total += 1 }
        return String(decoding: bytes[r], as: UTF8.self)
    }
    /// 4-byte count of UTF-16 units followed by the units (trailing NULs dropped).
    @inlinable package mutating func unicode() throws -> String {
        let n = try u32()
        guard n <= remaining / 2 else { throw PSDImportError.truncated }
        var units: [UInt16] = []
        units.reserveCapacity(n)
        for _ in 0..<n { units.append(UInt16(truncatingIfNeeded: try u16())) }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
    @inlinable package func data(_ r: Range<Int>) -> Data { Data(bytes[max(0, r.lowerBound)..<min(bytes.count, max(r.lowerBound, r.upperBound))]) }
}

package struct PSDBlock {
    package var key: String
    package var range: Range<Int>
    @inlinable package init(key: String, range: Range<Int>) {
        self.key = key; self.range = range
    }
}

package struct PSDMaskInfo {
    package var rect = IRect.zero
    package var defaultColor: UInt8 = 0
    package var flags: UInt8 = 0
    package var userDensity: Double? = nil
    package var userFeather: Double? = nil
    package var vectorDensity: Double? = nil
    package var vectorFeather: Double? = nil
    package var realRect: IRect? = nil
    package var realDefault: UInt8 = 0
    package var realFlags: UInt8 = 0
    /// Channel -2 is a rendering of the vector mask (the real pixel mask, if any, is channel -3).
    @inlinable package var fromVector: Bool { flags & 0x08 != 0 }
    @inlinable package init(rect: IRect = IRect.zero, defaultColor: UInt8 = 0, flags: UInt8 = 0, userDensity: Double? = nil, userFeather: Double? = nil, vectorDensity: Double? = nil, vectorFeather: Double? = nil, realRect: IRect? = nil, realDefault: UInt8 = 0, realFlags: UInt8 = 0) {
        self.rect = rect; self.defaultColor = defaultColor; self.flags = flags; self.userDensity = userDensity; self.userFeather = userFeather; self.vectorDensity = vectorDensity; self.vectorFeather = vectorFeather; self.realRect = realRect; self.realDefault = realDefault; self.realFlags = realFlags
    }
}

package struct PSDRecord {
    package var rect = IRect.zero
    package var chans: [(id: Int, len: Int)] = []
    package var blendKey = "norm"
    package var opacity: UInt8 = 255
    package var clipping: UInt8 = 0
    package var flags: UInt8 = 0
    package var name = ""
    package var mask: PSDMaskInfo? = nil
    package var blendRanges: Range<Int> = 0..<0
    package var blocks: [PSDBlock] = []
    /// Decoded 8-bit planes by channel id (0… colour, -1 transparency, -2 mask, -3 real user mask).
    package var planes: [Int: [UInt8]] = [:]
    package var section: Int? = nil
    package var sectionBlend: String? = nil
    /// Link group from resource 1026 (0 = not linked): layers with the same number move together.
    package var linkGroup = 0
    /// 'lyid' (0 = none).
    package var layerID = 0

    @inlinable package func block(_ key: String) -> Range<Int>? { blocks.first { $0.key == key }?.range }
    @inlinable package func has(_ key: String) -> Bool { blocks.contains { $0.key == key } }
    @inlinable package init(rect: IRect = IRect.zero, chans: [(id: Int, len: Int)] = [], blendKey: String = "norm", opacity: UInt8 = 255, clipping: UInt8 = 0, flags: UInt8 = 0, name: String = "", mask: PSDMaskInfo? = nil, blendRanges: Range<Int> = 0..<0, blocks: [PSDBlock] = [], planes: [Int: [UInt8]] = [:], section: Int? = nil, sectionBlend: String? = nil, linkGroup: Int = 0, layerID: Int = 0) {
        self.rect = rect; self.chans = chans; self.blendKey = blendKey; self.opacity = opacity; self.clipping = clipping; self.flags = flags; self.name = name; self.mask = mask; self.blendRanges = blendRanges; self.blocks = blocks; self.planes = planes; self.section = section; self.sectionBlend = sectionBlend; self.linkGroup = linkGroup; self.layerID = layerID
    }
}

package struct PSDLinkedFile {
    package var id: String
    package var name: String
    package var fileType: String
    package var data: Range<Int>?        // embedded bytes
    package var externalPath: String?    // linked (external) file
    @inlinable package init(id: String, name: String, fileType: String, data: Range<Int>? = nil, externalPath: String? = nil) {
        self.id = id; self.name = name; self.fileType = fileType; self.data = data; self.externalPath = externalPath
    }
}

/// Pixel sizes that are safe to allocate: a damaged header must not ask for gigabytes.
package enum PSDLimits {
    package static let maxSide = 300_000          // the PSB limit
    package static let maxPixels = 900_000_000    // Lumen's largest canvas (30000 × 30000)
    @inlinable package static func plausible(_ w: Int, _ h: Int) -> Bool { w > 0 && h > 0 && w <= maxSide && h <= maxSide && w * h <= maxPixels }
}

/// The bytes of a PSD being read, with the tagged-block helpers that only need the bytes (the platform importer
/// conforms; the adjustment-block parsers take any source).
package protocol PSDByteSource {
    var bytes: [UInt8] { get }
}

extension PSDByteSource {
    /// Versioned descriptor (u32 16 + descriptor) stored in a tagged block, optionally after `skip` leading bytes.
    package func descriptor(_ range: Range<Int>, skip: Int = 0) -> PSDDescriptor? {
        guard range.count > skip + 4 else { return nil }
        return try? PSDDescriptor.readVersioned(PSDCursor(bytes).data((range.lowerBound + skip)..<range.upperBound))
    }
}
