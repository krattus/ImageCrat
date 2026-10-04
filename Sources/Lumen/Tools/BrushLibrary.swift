import AppKit
import Observation
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

/// Registry of imported (ABR) brush tips. Tips are persisted to
/// `~/Library/Application Support/ImageCrat/Brushes/` as gray PNGs plus an `index.json` describing the presets.
@Observable
final class BrushLibrary {
    static let shared = BrushLibrary()

    /// Presets for the imported tips (tipID == preset id).
    private(set) var presets: [BrushPreset] = []
    @ObservationIgnored private var tips: [String: PixelBuffer] = [:]

    private struct Entry: Codable {
        var id: String
        var name: String
        var diameter: Double
        var spacing: Double
        var file: String
    }
    @ObservationIgnored private var entries: [Entry] = []

    /// Where tips are persisted.
    @ObservationIgnored let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    static var defaultDirectory: URL {
        Brand.supportFolder.appendingPathComponent("Brushes", isDirectory: true)
    }
    init(directory: URL = BrushLibrary.defaultDirectory) {
        self.directory = directory
        load()
    }

    func tipBuffer(_ id: String) -> PixelBuffer? { tips[id] }

    // MARK: Adding / removing

    /// Registers imported tips as presets. Returns the new presets.
    @discardableResult
    func add(_ imported: [ImportedBrushTip], persist: Bool = true) -> [BrushPreset] {
        var added: [BrushPreset] = []
        for t in imported {
            let id = "abr-\(UUID().uuidString.prefix(8).lowercased())"
            let tip = t.tip.format == .gray ? t.tip : t.tip.toGray()
            tips[id] = tip
            let d = clamp(t.diameter.isFinite && t.diameter > 0 ? t.diameter : Double(max(tip.width, tip.height)), 1, 2500)
            let spacing = clamp(t.spacing.isFinite && t.spacing > 0 ? t.spacing : 0.25, 0.01, 10)
            let name = t.name.isEmpty ? "Brush \(presets.count + 1)" : t.name
            let entry = Entry(id: id, name: name, diameter: d, spacing: spacing, file: "\(id).png")
            if persist { write(tip, entry) }
            entries.append(entry)
            let p = BrushLibrary.preset(entry)
            presets.append(p)
            added.append(p)
        }
        if persist { saveIndex() }
        return added
    }

    func remove(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let e = entries.remove(at: i)
        presets.removeAll { $0.id == id }
        tips.removeValue(forKey: id)
        TipSource.invalidate(id)
        BrushTips.invalidateTexture(id)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(e.file))
        saveIndex()
    }

    func contains(_ id: String) -> Bool { tips[id] != nil }

    private static func preset(_ e: Entry) -> BrushPreset {
        BrushPreset(id: e.id, name: e.name, size: e.diameter, hardness: 1, spacing: e.spacing, tipID: e.id)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        for e in list {
            let url = directory.appendingPathComponent(e.file)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            tips[e.id] = PixelBuffer(cgImage: img, format: .gray)
            entries.append(e)
            presets.append(BrushLibrary.preset(e))
        }
    }

    private func write(_ tip: PixelBuffer, _ e: Entry) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let png = tip.pngData() { try png.write(to: directory.appendingPathComponent(e.file), options: .atomic) }
        } catch {
            NSLog("ImageCrat: could not save brush tip \(e.name): \(error)")
        }
    }

    private func saveIndex() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(entries).write(to: indexURL, options: .atomic)
        } catch {
            NSLog("ImageCrat: could not save brush index: \(error)")
        }
    }

    // MARK: UI action

    /// Shows an open panel for .abr files, imports every brush and selects the first one.
    static func importBrushes() {
        let panel = NSOpenPanel()
        panel.title = "Import Brushes"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let abr = UTType(filenameExtension: "abr") { panel.allowedContentTypes = [abr] }
        guard UIBlock.run(panel) == .OK else { return }
        importFiles(panel.urls)
    }

    static func importFiles(_ urls: [URL]) {
        let app = AppModel.shared
        var added: [BrushPreset] = []
        var errors: [String] = []
        for url in urls {
            do {
                added += shared.add(try ABRImporter.load(url: url))
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if let first = added.first {
            var s = app.activeBrushSettings
            first.apply(to: &s)
            app.activeBrushSettings = s
        }
        if !errors.isEmpty {
            let alert = NSAlert()
            alert.messageText = added.isEmpty ? "No brushes were imported." : "Some brushes could not be imported."
            alert.informativeText = errors.joined(separator: "\n")
            UIBlock.run(alert)
        }
        app.setStatus("Imported \(added.count) brush\(added.count == 1 ? "" : "es").")
    }
}
