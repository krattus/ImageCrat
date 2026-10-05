import Foundation

/// Entry point for brush files: detects the format from the content (and the extension where the content is not
/// conclusive) and dispatches to the matching reader.
///
/// Plain images (PNG without a Krita preset chunk, JPEG, PSD, TIFF, …) are not handled here: check `isPlainImage`
/// first and let the app decode them with the platform codecs and `BrushTipImaging.grayCoverage`.
package enum BrushImport {
    package enum Kind: String, CaseIterable {
        case abr, tpl, gbr, gih, procreate, kpp, icbrushes
    }

    package static let supportedExtensions = ["abr", "tpl", "gbr", "gih", "brush", "brushset", "kpp", "icbrushes"]
    package static let plainImageExtensions = ["png", "jpg", "jpeg", "psd", "psb", "tif", "tiff", "gif", "bmp", "webp", "heic", "heif"]

    /// File name without directory and extension.
    package static func baseName(_ fileName: String) -> String {
        let last = fileName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? fileName
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return last }
        return String(last[..<dot])
    }

    package static func fileExtension(_ fileName: String) -> String {
        let last = fileName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? fileName
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return "" }
        return String(last[last.index(after: dot)...]).lowercased()
    }

    private static func prefix(_ data: Data, _ n: Int) -> [UInt8] { [UInt8](data.prefix(n)) }

    private static func looksLikeABR(_ data: Data) -> Bool {
        let b = prefix(data, 12)
        guard b.count >= 12 else { return false }
        let version = Int(b[0]) << 8 | Int(b[1])
        if [6, 7, 10].contains(version) { return b[4] == 0x38 && b[5] == 0x42 && b[6] == 0x49 && b[7] == 0x4D }   // "8BIM"
        return false
    }

    private static func looksLikeTPL(_ data: Data) -> Bool {
        let b = prefix(data, 4)
        return b == Array("8BTP".utf8)
    }

    /// Image signatures the app should decode itself.
    private static func imageSignature(_ data: Data) -> Bool {
        let b = prefix(data, 12)
        guard b.count >= 4 else { return false }
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return true }                       // JPEG
        if b == Array("8BPS".utf8) || Array(b[0..<4]) == Array("8BPS".utf8) { return true }   // PSD / PSB
        if (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0) || (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0 && b[3] == 0x2A) { return true }
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38 { return true }       // GIF
        if b.count >= 12, Array(b[0..<4]) == Array("RIFF".utf8), Array(b[8..<12]) == Array("WEBP".utf8) { return true }
        if b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8) { return true }               // HEIF family
        return false
    }

    /// The brush format of a file, or nil.
    package static func detect(data: Data, fileName: String) -> Kind? {
        let ext = fileExtension(fileName)
        if ZipReader.isZip(data) {
            guard let zip = try? ZipReader(data: data) else {
                return ext == "icbrushes" ? .icbrushes : (ext == "brush" || ext == "brushset" ? .procreate : nil)
            }
            if BrushSetArchive.isBrushSetArchive(zip) { return .icbrushes }
            if ProcreateBrush.isProcreate(zip) { return .procreate }
            return nil
        }
        if PNGCodec.isPNG(data) {
            return (ext == "kpp" || KritaPreset.presetXML(data) != nil) ? .kpp : nil
        }
        if GIMPBrush.isGBR(data) { return .gbr }
        if ext == "gih" || (ext != "gbr" && ext != "abr" && ext != "tpl" && GIMPBrush.looksLikeGIH(data)) { return .gih }
        if ext == "abr" || looksLikeABR(data) { return .abr }
        if ext == "tpl" || looksLikeTPL(data) { return .tpl }
        if ext == "gbr" { return .gbr }
        return nil
    }

    /// True for image files that are not brush files (the app imports those as a sampled tip itself).
    package static func isPlainImage(data: Data, fileName: String) -> Bool {
        if detect(data: data, fileName: fileName) != nil { return false }
        if PNGCodec.isPNG(data) || imageSignature(data) { return true }
        return plainImageExtensions.contains(fileExtension(fileName))
    }

    package static func load(data: Data, fileName: String) throws -> ImportedBrushSet {
        var name = baseName(fileName)
        if name.isEmpty { name = "Brushes" }
        guard let kind = detect(data: data, fileName: fileName) else {
            if ZipReader.isZip(data) { _ = try ZipReader(data: data) }   // surface "damaged zip" rather than "unsupported"
            let ext = fileExtension(fileName)
            throw BrushImportError.unsupportedFormat(ext.isEmpty ? "This file" : "A .\(ext) file")
        }
        var set: ImportedBrushSet
        switch kind {
        case .abr: set = try ABRBrushReader.read(data: data, name: name)
        case .tpl: set = try TPLReader.read(data: data, name: name)
        case .gbr: set = try GIMPBrush.readGBR(data: data, name: name)
        case .gih: set = try GIMPBrush.readGIH(data: data, name: name)
        case .kpp: set = try KritaPreset.read(data: data, name: name)
        case .procreate: set = try ProcreateBrush.read(zip: try ZipReader(data: data), name: name)
        case .icbrushes: set = try BrushSetArchive.read(zip: try ZipReader(data: data), fallbackName: name)
        }
        if set.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { set.name = name }
        return set
    }
}
