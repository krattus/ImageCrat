import Foundation

// MARK: - Little-endian byte helpers

@inline(__always) private func le16(_ b: [UInt8], _ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 }
@inline(__always) private func le32(_ b: [UInt8], _ p: Int) -> Int {
    Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24
}
@inline(__always) private func le64(_ b: [UInt8], _ p: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in (0..<8).reversed() { v = v << 8 | UInt64(b[p + i]) }
    return v
}

/// 64-bit size / offset fields clamped to a range that cannot overflow later arithmetic.
@inline(__always) private func bounded(_ v: UInt64) -> Int { v > 1 << 40 ? 1 << 40 : Int(v) }

// MARK: - Reader

/// In-memory ZIP reader (PKWARE APPNOTE): end-of-central-directory search (also behind an archive comment), central
/// directory, local headers, methods 0 (stored) and 8 (deflate), data descriptors (sizes come from the central
/// directory), minimal ZIP64 (64-bit sizes / offsets / entry counts). Encrypted entries are listed but refuse to read.
///
/// Decompression is capped per entry by the declared size (and `maxEntrySize`) and across all reads of one reader by
/// `maxTotalOutput`, so zip bombs fail with `BrushImportError.malformed`.
package struct ZipReader {
    package struct Entry {
        /// Path inside the archive, "/"-separated, without a leading "/" or "./".
        package var name: String
        package var method: Int
        package var flags: Int
        package var crc32: UInt32
        package var compressedSize: Int
        package var uncompressedSize: Int
        package var localHeaderOffset: Int
        package init(name: String, method: Int, flags: Int, crc32: UInt32, compressedSize: Int, uncompressedSize: Int,
                     localHeaderOffset: Int) {
            self.name = name; self.method = method; self.flags = flags; self.crc32 = crc32
            self.compressedSize = compressedSize; self.uncompressedSize = uncompressedSize; self.localHeaderOffset = localHeaderOffset
        }
        package var isEncrypted: Bool { flags & 1 != 0 }
        /// Last path component.
        package var fileName: String { name.split(separator: "/").last.map(String.init) ?? name }
        /// Directory part ("" at the top level), without a trailing "/".
        package var directory: String {
            guard let r = name.range(of: "/", options: .backwards) else { return "" }
            return String(name[..<r.lowerBound])
        }
        /// macOS resource-fork / Finder junk (`__MACOSX/…`, `.DS_Store`, `._name`).
        package var isMetadataJunk: Bool {
            name.hasPrefix("__MACOSX/") || name.contains("/__MACOSX/") || fileName == ".DS_Store" || fileName.hasPrefix("._")
        }
    }

    /// Byte budget shared by all reads of one reader (and its copies).
    private final class Budget { var remaining: Int; init(_ n: Int) { remaining = n } }

    package static let maxEntrySize = 256 << 20
    package static let maxTotalOutput = 1 << 30
    package static let maxEntries = 100_000

    /// File entries in central-directory order (directories are not listed).
    package private(set) var entries: [Entry] = []
    private let bytes: [UInt8]
    private let budget: Budget

    package static func isZip(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let b = [UInt8](data.prefix(4))
        return b[0] == 0x50 && b[1] == 0x4B && ((b[2] == 3 && b[3] == 4) || (b[2] == 5 && b[3] == 6) || (b[2] == 7 && b[3] == 8))
    }

    package init(data: Data, maxTotalOutput: Int = ZipReader.maxTotalOutput) throws {
        bytes = [UInt8](data)
        budget = Budget(maxTotalOutput)
        try parse()
    }

    private mutating func parse() throws {
        let b = bytes
        let n = b.count
        guard n >= 22 else { throw BrushImportError.malformed("not a zip archive") }
        // End of central directory: scan backwards over at most a 64 KB comment.
        var eocd = -1
        var p = n - 22
        let lowest = max(0, n - 22 - 65535)
        while p >= lowest {
            if b[p] == 0x50 && b[p + 1] == 0x4B && b[p + 2] == 5 && b[p + 3] == 6 { eocd = p; break }
            p -= 1
        }
        guard eocd >= 0 else { throw BrushImportError.malformed("zip end of central directory not found") }
        var count = le16(b, eocd + 10)
        var cdSize = le32(b, eocd + 12)
        var cdOffset = le32(b, eocd + 16)
        // ZIP64 end of central directory (via its locator just before the EOCD).
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF, eocd >= 20,
           le32(b, eocd - 20) == 0x0706_4B50 {
            let z = le64(b, eocd - 20 + 8)
            if z < UInt64(n), Int(z) + 56 <= n, le32(b, Int(z)) == 0x0606_4B50 {
                let zp = Int(z)
                let c64 = le64(b, zp + 32), s64 = le64(b, zp + 40), o64 = le64(b, zp + 48)
                guard c64 <= UInt64(ZipReader.maxEntries), s64 <= UInt64(n), o64 <= UInt64(n) else {
                    throw BrushImportError.malformed("zip64 directory")
                }
                count = Int(c64); cdSize = Int(s64); cdOffset = Int(o64)
            }
        }
        guard count <= ZipReader.maxEntries else { throw BrushImportError.malformed("too many zip entries") }
        // Data prepended to the archive (self-extractors) shifts every offset: detect it from the EOCD position.
        var shift = 0
        if cdOffset + cdSize <= eocd, eocd - (cdOffset + cdSize) > 0,
           !(cdOffset + 4 <= n && le32(b, cdOffset) == 0x0201_4B50) {
            shift = eocd - (cdOffset + cdSize)
        }
        var q = cdOffset + shift
        guard q >= 0, q <= n else { throw BrushImportError.malformed("zip central directory offset") }
        var out: [Entry] = []
        out.reserveCapacity(min(count, 4096))
        var seen = 0
        while seen < count || count == 0xFFFF {
            guard q + 46 <= n, le32(b, q) == 0x0201_4B50 else {
                if seen == 0 && count > 0 { throw BrushImportError.malformed("zip central directory") }
                break   // tolerate a short / wrong count
            }
            let flags = le16(b, q + 8)
            let method = le16(b, q + 10)
            let crc = UInt32(truncatingIfNeeded: le32(b, q + 16))
            var csize = le32(b, q + 20)
            var usize = le32(b, q + 24)
            let nameLen = le16(b, q + 28), extraLen = le16(b, q + 30), commentLen = le16(b, q + 32)
            var local = le32(b, q + 42)
            let nameStart = q + 46
            guard nameStart + nameLen + extraLen + commentLen <= n else { throw BrushImportError.malformed("zip entry header") }
            let nameBytes = Array(b[nameStart..<(nameStart + nameLen)])
            // ZIP64 extended information extra field (id 1): only the fields saturated in the fixed header, in order.
            var e = nameStart + nameLen
            let eEnd = e + extraLen
            while e + 4 <= eEnd {
                let id = le16(b, e), sz = le16(b, e + 2)
                let body = e + 4
                guard body + sz <= eEnd else { break }
                if id == 1 {
                    var f = body
                    if usize == 0xFFFF_FFFF, f + 8 <= body + sz { usize = bounded(le64(b, f)); f += 8 }
                    if csize == 0xFFFF_FFFF, f + 8 <= body + sz { csize = bounded(le64(b, f)); f += 8 }
                    if local == 0xFFFF_FFFF, f + 8 <= body + sz { local = bounded(le64(b, f)); f += 8 }
                }
                e = body + sz
            }
            q = eEnd + commentLen
            seen += 1
            if seen > ZipReader.maxEntries { throw BrushImportError.malformed("too many zip entries") }
            let name = ZipReader.sanitize(ZipReader.decodeName(nameBytes, utf8: flags & 0x800 != 0))
            if name.isEmpty || name.hasSuffix("/") { continue }   // directory
            out.append(Entry(name: name, method: method, flags: flags, crc32: crc, compressedSize: csize,
                             uncompressedSize: usize, localHeaderOffset: local + shift))
        }
        entries = out
    }

    private static func decodeName(_ b: [UInt8], utf8: Bool) -> String {
        if let s = String(bytes: b, encoding: .utf8) { return s }
        // Legacy names are CP437; Latin-1 keeps ASCII intact and never fails.
        return String(bytes: b, encoding: .isoLatin1) ?? ""
    }

    private static func sanitize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\", with: "/")
        while t.hasPrefix("/") { t.removeFirst() }
        while t.hasPrefix("./") { t.removeFirst(2) }
        return t
    }

    // MARK: Lookup

    /// Exact name first, then a case-insensitive match.
    package func entry(named name: String) -> Entry? {
        let n = ZipReader.sanitize(name)
        if let e = entries.first(where: { $0.name == n }) { return e }
        let l = n.lowercased()
        return entries.first(where: { $0.name.lowercased() == l })
    }

    package func contains(_ name: String) -> Bool { entry(named: name) != nil }

    package func data(for name: String) throws -> Data {
        guard let e = entry(named: name) else { throw BrushImportError.malformed("zip entry \(name) missing") }
        return try data(for: e)
    }

    package func data(for e: Entry) throws -> Data {
        guard !e.isEncrypted else { throw BrushImportError.unsupportedFormat("An encrypted zip entry") }
        let b = bytes
        let n = b.count
        let h = e.localHeaderOffset
        guard h >= 0, h + 30 <= n, le32(b, h) == 0x0403_4B50 else { throw BrushImportError.malformed("zip local header") }
        let start = h + 30 + le16(b, h + 26) + le16(b, h + 28)
        guard e.compressedSize >= 0, e.uncompressedSize >= 0, start <= n, e.compressedSize <= n - start else {
            throw BrushImportError.malformed("zip entry data out of range")
        }
        guard e.uncompressedSize <= ZipReader.maxEntrySize, e.uncompressedSize <= budget.remaining else {
            throw BrushImportError.malformed("zip entry too large")
        }
        let raw = b[start..<(start + e.compressedSize)]
        var out: [UInt8]
        switch e.method {
        case 0:
            out = Array(raw)
            guard out.count == e.uncompressedSize || e.uncompressedSize == 0 else { throw BrushImportError.malformed("zip stored size") }
        case 8:
            let r = raw.withUnsafeBytes { Inflate.inflateRawPartial($0, maxOutput: e.uncompressedSize) }
            if let err = r.error { throw err }
            out = r.output
            guard out.count == e.uncompressedSize else { throw BrushImportError.malformed("zip entry size mismatch") }
        default:
            throw BrushImportError.unsupportedFormat("Zip compression method \(e.method)")
        }
        budget.remaining -= out.count
        guard CRC32.checksum(out) == e.crc32 else { throw BrushImportError.malformed("zip CRC mismatch in \(e.name)") }
        return Data(out)
    }
}

// MARK: - Writer

/// Minimal ZIP writer: STORED entries (no compression), UTF-8 names, correct CRC-32, local headers, central directory
/// and end record. Not ZIP64: entries and the archive must stay below 4 GB.
package struct ZipWriter {
    private var body: [UInt8] = []
    private var central: [UInt8] = []
    private var count = 0
    private var names = Set<String>()

    package init() {}

    private static func put16(_ a: inout [UInt8], _ v: Int) { a.append(UInt8(v & 0xFF)); a.append(UInt8((v >> 8) & 0xFF)) }
    private static func put32(_ a: inout [UInt8], _ v: UInt32) {
        a.append(UInt8(v & 0xFF)); a.append(UInt8((v >> 8) & 0xFF)); a.append(UInt8((v >> 16) & 0xFF)); a.append(UInt8(v >> 24))
    }

    /// Adds a file. A name that was already added is ignored (zip readers disagree about duplicates).
    package mutating func add(name: String, data: Data) {
        var nm = name.replacingOccurrences(of: "\\", with: "/")
        while nm.hasPrefix("/") { nm.removeFirst() }
        guard !nm.isEmpty, !names.contains(nm) else { return }
        names.insert(nm)
        let nameBytes = Array(nm.utf8)
        let payload = [UInt8](data)
        let crc = CRC32.checksum(payload)
        let offset = UInt32(truncatingIfNeeded: body.count)
        let dosTime = 0                      // 00:00:00
        let dosDate = (46 << 9) | (1 << 5) | 1   // 2026-01-01 (deterministic output)
        // Local file header
        ZipWriter.put32(&body, 0x0403_4B50)
        ZipWriter.put16(&body, 10)           // version needed: 1.0 (stored)
        ZipWriter.put16(&body, 0x0800)       // UTF-8 names
        ZipWriter.put16(&body, 0)            // stored
        ZipWriter.put16(&body, dosTime)
        ZipWriter.put16(&body, dosDate)
        ZipWriter.put32(&body, crc)
        ZipWriter.put32(&body, UInt32(truncatingIfNeeded: payload.count))
        ZipWriter.put32(&body, UInt32(truncatingIfNeeded: payload.count))
        ZipWriter.put16(&body, nameBytes.count)
        ZipWriter.put16(&body, 0)
        body.append(contentsOf: nameBytes)
        body.append(contentsOf: payload)
        // Central directory header
        ZipWriter.put32(&central, 0x0201_4B50)
        ZipWriter.put16(&central, 0x031E)    // made by: Unix, spec 3.0
        ZipWriter.put16(&central, 10)
        ZipWriter.put16(&central, 0x0800)
        ZipWriter.put16(&central, 0)
        ZipWriter.put16(&central, dosTime)
        ZipWriter.put16(&central, dosDate)
        ZipWriter.put32(&central, crc)
        ZipWriter.put32(&central, UInt32(truncatingIfNeeded: payload.count))
        ZipWriter.put32(&central, UInt32(truncatingIfNeeded: payload.count))
        ZipWriter.put16(&central, nameBytes.count)
        ZipWriter.put16(&central, 0)         // extra
        ZipWriter.put16(&central, 0)         // comment
        ZipWriter.put16(&central, 0)         // disk
        ZipWriter.put16(&central, 0)         // internal attributes
        ZipWriter.put32(&central, 0o100644 << 16)   // external attributes: regular file rw-r--r--
        ZipWriter.put32(&central, offset)
        central.append(contentsOf: nameBytes)
        count += 1
    }

    package func finish() -> Data {
        var out = body
        out.append(contentsOf: central)
        ZipWriter.put32(&out, 0x0605_4B50)
        ZipWriter.put16(&out, 0)
        ZipWriter.put16(&out, 0)
        ZipWriter.put16(&out, min(count, 0xFFFF))
        ZipWriter.put16(&out, min(count, 0xFFFF))
        ZipWriter.put32(&out, UInt32(truncatingIfNeeded: central.count))
        ZipWriter.put32(&out, UInt32(truncatingIfNeeded: body.count))
        ZipWriter.put16(&out, 0)
        return Data(out)
    }
}
