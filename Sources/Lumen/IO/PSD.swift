import Foundation
import CoreImage
import ImageCratCore

// MARK: - Writer

enum PSDWriter {
    /// Writes a layered PSD, or a PSB (Large Document Format, version 2) when `large` is true. See `PSDExport`.
    static func write(_ st: DocumentState, to url: URL, large: Bool = false) throws {
        try PSDExport.write(st, to: url, large: large)
    }
}

// MARK: - Reader

enum PSDReader {
    /// Layers of a PSD / PSB (see `PSDImporter`: type, shapes, adjustments, fills and smart objects arrive as live
    /// layers). Patterns stored in the file are added to the pattern library.
    static func read(url: URL) throws -> DocumentState {
        let res = try PSDImporter.read(url: url)
        PSDImportModule.addPatterns(res.patterns)
        return res.state
    }
}
