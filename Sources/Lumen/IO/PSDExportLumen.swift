import Foundation
import ImageCratCore

// MARK: - Lumen's own layer data inside a PSD
//
// Photoshop's representation of a type, shape, fill or adjustment layer cannot hold everything Lumen has (type on a
// path, polygon parameters, Camera Raw adjustments, smart filters…). The exporter therefore also stores the exact
// Lumen layer in a private image resource (ID 4000, the plug-in range, named "Lumen"), keyed by the layer id it wrote
// ('lyid'). Each entry carries a fingerprint of the layer record as written: when Photoshop (or anything else)
// re-saves the file, the record changes and the importer ignores the entry, so only untouched Lumen files are
// restored from it.

enum PSDExportLumen {
    static let resourceID: UInt16 = 4000
    /// Name written on the resource. Files exported before the rename carry "Lumen"; both are read (`resourceNames`).
    nonisolated(unsafe) static var resourceName = Brand.name   // (the rename self test writes the old name)
    static let resourceNames: Set<String> = [Brand.name, Brand.Legacy.name]
    static let magic = Data("LMNP".utf8)

    struct Entry: Codable {
        var layerID: UInt32
        var fingerprint: UInt64
        var layer: Layer
        /// The record's masks only approximate the layer's (a shape's extra vector mask, a one-sided feather):
        /// restore them from `layer` too.
        var masks: Bool
    }

    private struct Payload: Codable {
        var version = 1
        var entries: [Entry]
    }

    static func entry(_ l: Layer, _ r: PSDWriteRecord) -> Entry {
        let masks = (l.isShape && !(l.vectorMask?.isEmpty ?? true)) || ((l.mask?.feather ?? 0) > 0 && (l.mask?.featherDirection ?? .centered) != .centered)
        var copy = l
        if !masks { copy.mask = nil; copy.vectorMask = nil }   // masks, styles and blending travel in the record itself
        copy.effects = LayerEffects()
        return Entry(layerID: r.layerID, fingerprint: fingerprint(name: r.name, rect: r.rect, blocks: r.blocks.map { ($0.0, padded($0.1)) }), layer: copy, masks: masks)
    }

    static func padded(_ d: Data) -> Data {
        var b = d
        while b.count % 4 != 0 { b.append(0) }
        return b
    }

    /// FNV-1a over the name, the rectangle and every tagged block (key + padded payload) of the record.
    static func fingerprint(name: String, rect: IRect, blocks: [(String, Data)]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        func eat<S: Sequence>(_ s: S) where S.Element == UInt8 { for b in s { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 } }
        eat(name.utf8)
        for v in [rect.x, rect.y, rect.width, rect.height] { eat(withUnsafeBytes(of: Int64(v).bigEndian) { Array($0) }) }
        for (k, d) in blocks { eat(k.utf8); eat(d) }
        return h
    }

    static func resource(_ entries: [Entry]) -> Data? {
        guard let plist = try? PropertyListEncoder().encode(Payload(entries: entries)),
              let packed = try? (plist as NSData).compressed(using: .lzfse) as Data else { return nil }
        return magic + packed
    }

    static func decode(_ data: Data) -> [UInt32: Entry] {
        guard data.count > magic.count, data.prefix(magic.count) == magic,
              let raw = try? (data.dropFirst(magic.count) as NSData).decompressed(using: .lzfse) as Data,
              let p = try? PropertyListDecoder().decode(Payload.self, from: raw), p.version == 1 else { return [:] }
        var out: [UInt32: Entry] = [:]
        for e in p.entries { out[e.layerID] = e }
        return out
    }
}

extension PSDImporter {
    /// The entry Lumen stored for this record, when the record is still exactly what Lumen wrote.
    func lumenEntry(_ r: PSDRecord) -> PSDExportLumen.Entry? {
        guard r.layerID != 0, let e = lumenEntries[UInt32(truncatingIfNeeded: r.layerID)] else { return nil }
        let blocks = r.blocks.map { ($0.key, Data(bytes[$0.range])) }
        return PSDExportLumen.fingerprint(name: r.name, rect: r.rect, blocks: blocks) == e.fingerprint ? e : nil
    }

    func lumenLayer(_ r: PSDRecord) -> Layer? {
        guard let e = lumenEntry(r) else { return nil }
        var l = Layer(name: r.name, content: e.layer.content)
        l.constraints = e.layer.constraints
        if case .smartObject(var so) = l.content { so.sourceRevision += 1; l.content = .smartObject(so) }
        report.add(.editable, layer: r.name, feature: e.layer.kindName, detail: "restored exactly from the ImageCrat data stored with the layer")
        return l
    }

    func restoreLumenMasks(_ l: inout Layer, _ r: PSDRecord) {
        guard let e = lumenEntry(r), e.masks else { return }
        l.mask = e.layer.mask
        l.vectorMask = e.layer.vectorMask
        l.vectorMaskEnabled = e.layer.vectorMaskEnabled
    }
}
