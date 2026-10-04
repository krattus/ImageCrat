import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageCratCore

/// File ▸ Export ▸ Artboards to Files / Artboards to PDF and Export Artboard As (Photoshop's options: artboard
/// content only or overlapping areas, background on or off, selected artboards, a file-name prefix).
enum ArtboardExport {
    enum Format: String, CaseIterable, Identifiable {
        case png = "PNG", jpeg = "JPEG", tiff = "TIFF", psd = "PSD", pdf = "PDF"
        var id: String { rawValue }
        var ext: String { self == .jpeg ? "jpg" : rawValue.lowercased() }
        var image: ExportFormat? {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .tiff: return .tiff
            case .psd: return .psd
            case .pdf: return nil
            }
        }
        static func from(ext: String) -> Format? { allCases.first { $0.ext == ext.lowercased() || (ext.lowercased() == "jpeg" && $0 == .jpeg) || (ext.lowercased() == "tif" && $0 == .tiff) } }
    }

    struct Options: Equatable {
        var format: Format = .png
        var prefix = ""
        /// false: only the artboard's own layers; true: everything that overlaps it (other artboards, loose layers).
        var overlapping = false
        var includeBackground = true
        var quality = 0.9
        var scale = 1.0
        /// PDF: one multi-page file (false: one PDF per artboard).
        var multiPage = true
    }

    /// The artboard as its own document (canvas = the artboard).
    static func state(_ st: DocumentState, _ id: UUID, options o: Options = Options()) -> DocumentState? {
        guard let l = st.layer(id), let ab = l.artboard else { return nil }
        let r = ab.rect.integral
        var out = st
        if o.overlapping {
            for i in out.layers.indices { out.layers[i].translate(dx: -Double(r.minX), dy: -Double(r.minY), document: true) }
        } else {
            var c = l
            c.translate(dx: -Double(r.minX), dy: -Double(r.minY), document: true)
            c.isVisible = true
            out.layers = [c]
        }
        if !o.includeBackground {
            out.updateLayer(id) { l in
                guard case .group(var g) = l.content else { return }
                g.artboard?.background = nil
                l.content = .group(g)
            }
        }
        out.width = max(1, Int(r.width))
        out.height = max(1, Int(r.height))
        out.selection = nil
        out.alphaChannels = []
        out.guides = []
        out.paths = out.paths.map { var p = $0; p.path = p.path.applying(CGAffineTransform(translationX: -r.minX, y: -r.minY)); return p }
        out.frames = []
        out.videoTimeline = nil
        return out
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let t = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Artboard" : t
    }

    /// Which artboards to export: `ids` (artboards only) or every visible artboard.
    static func list(_ st: DocumentState, _ ids: [UUID]?) -> [Layer] {
        if let ids, !ids.isEmpty { return ids.compactMap { st.layer($0) }.filter(\.isArtboard) }
        return ArtboardOps.boards(st).filter(\.isVisible)
    }

    /// Writes the artboards into `dir`. Returns the files written.
    @discardableResult
    static func export(_ st: DocumentState, ids: [UUID]?, to dir: URL, options o: Options) throws -> [URL] {
        let boards = list(st, ids)
        guard !boards.isEmpty else { return [] }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var used = Set<String>(), out: [URL] = []
        func url(_ base: String, _ ext: String) -> URL {
            var name = safeName(o.prefix + base), n = 2
            while used.contains(name.lowercased()) { name = safeName(o.prefix + base) + "-\(n)"; n += 1 }
            used.insert(name.lowercased())
            return dir.appendingPathComponent(name + "." + ext)
        }
        if o.format == .pdf {
            let pages = boards.compactMap { l in state(st, l.id, options: o).map { ($0, l.name) } }
            if o.multiPage {
                let u = url(boards.count == 1 ? boards[0].name : "Artboards", "pdf")
                try writePDF(pages, to: u)
                return [u]
            }
            for p in pages { let u = url(p.1, "pdf"); try writePDF([p], to: u); out.append(u) }
            return out
        }
        for l in boards {
            guard let s = state(st, l.id, options: o), let f = o.format.image else { continue }
            let u = url(l.name, o.format.ext)
            try DocumentIO.export(s, to: u, format: f, quality: o.quality, scale: f == .psd ? 1 : o.scale)
            out.append(u)
        }
        return out
    }

    /// One PDF page per state (page size = the artboard at the document resolution).
    static func writePDF(_ pages: [(DocumentState, String)], to url: URL) throws {
        guard let firstPage = pages.first?.0 else { throw DocumentIOError.encodeFailed }
        var first = PDFExport.pageBox(firstPage)
        guard let ctx = CGContext(url as CFURL, mediaBox: &first, [kCGPDFContextCreator: Brand.name] as CFDictionary) else { throw DocumentIOError.encodeFailed }
        for (page, _) in pages {
            var box = PDFExport.pageBox(page)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            PDFExport.drawPage(page, in: ctx, options: PDFExport.Options(artboardsAsPages: false))
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    // MARK: Panels

    /// Export Artboard As…: one artboard → a save panel (format from the extension); several → a folder of PNGs.
    static func exportAsPanel(_ d: Document, _ ids: [UUID]) {
        let boards = list(d.state, ids)
        guard !boards.isEmpty else { NSSound.beep(); return }
        if boards.count == 1, let l = boards.first {
            let p = NSSavePanel()
            p.nameFieldStringValue = safeName(l.name) + ".png"
            p.allowedContentTypes = [.png, .jpeg, .tiff, .pdf] + [UTType(filenameExtension: "psd")].compactMap { $0 }
            p.allowsOtherFileTypes = true
            p.message = "Export artboard “\(l.name)” (\(Int(l.artboard!.rect.width)) × \(Int(l.artboard!.rect.height)) px)"
            guard UIBlock.run(p) == .OK, let u = p.url else { return }
            var o = Options()
            o.format = Format.from(ext: u.pathExtension) ?? .png
            do {
                let written = try export(d.state, ids: [l.id], to: u.deletingLastPathComponent(), options: o)
                // honour the exact name typed in the panel
                if let w = written.first, w != u { try? FileManager.default.removeItem(at: u); try FileManager.default.moveItem(at: w, to: u) }
                AppModel.shared.setStatus("Exported “\(l.name)”.")
            } catch { AppActions.alert("Could not export the artboard.", error.localizedDescription) }
            return
        }
        d.selectedLayerIDs = Set(boards.map(\.id))
        DialogRegistry.show("artboardsToFiles")
    }

    static func pdfPanel(_ d: Document) {
        guard !ArtboardOps.boards(d.state).isEmpty else { AppActions.alert("This document has no artboards."); return }
        DialogRegistry.show("artboardsToPDF")
    }
}

/// Artboards to Files / Artboards to PDF dialog.
struct ArtboardsExportDialog: View {
    let pdf: Bool
    @State private var o = ArtboardExport.Options()
    @State private var selectedOnly = false
    @State private var dir: URL? = nil
    @State private var hasSelection = false
    @State private var count = 0

    var body: some View {
        DialogFrame(title: pdf ? "Artboards to PDF" : "Artboards to Files", width: 420, okTitle: "Export", onOK: run) {
            HStack {
                Text("Destination:").foregroundStyle(Theme.textDim)
                Text(dir?.path ?? "Choose a folder…").lineLimit(1).truncationMode(.middle).foregroundStyle(dir == nil ? Theme.textFaint : Theme.text)
                Spacer()
                Button("Choose…") { choose() }.buttonStyle(PanelButtonStyle())
            }
            HStack { Text("File Name Prefix:").foregroundStyle(Theme.textDim); TextField("", text: $o.prefix).textFieldStyle(.roundedBorder) }
            if hasSelection { Toggle2(label: "Export Selected Artboards only", on: $selectedOnly) }
            Picker("Content", selection: $o.overlapping) {
                Text("Artboard Content Only").tag(false)
                Text("Include Overlapping Areas").tag(true)
            }.pickerStyle(.radioGroup)
            Toggle2(label: "Include Background in Export", on: $o.includeBackground)
            if pdf {
                Picker("", selection: $o.multiPage) { Text("Multi-Page Document").tag(true); Text("Document per Artboard").tag(false) }.pickerStyle(.radioGroup).labelsHidden()
            } else {
                HStack {
                    Picker("File Type", selection: $o.format) { ForEach(ArtboardExport.Format.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 180)
                    if o.format == .jpeg { NumberField(label: "Quality", value: Binding(get: { o.quality * 100 }, set: { o.quality = min(max($0, 1), 100) / 100 }), width: 40) }
                    if o.format != .psd && o.format != .pdf {
                        Picker("Scale", selection: $o.scale) { Text("1×").tag(1.0); Text("2×").tag(2.0); Text("3×").tag(3.0); Text("0.5×").tag(0.5) }.frame(width: 110)
                    }
                }
                if o.format == .pdf { Toggle2(label: "One multi-page PDF", on: $o.multiPage) }
            }
            Text("\(count) artboard\(count == 1 ? "" : "s") will be exported.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
        .onAppear {
            if pdf { o.format = .pdf }
            guard let d = AppActions.doc else { return }
            let sel = ArtboardOps.selectedBoards(d)
            hasSelection = !sel.isEmpty && sel.count < ArtboardOps.boards(d.state).count
            selectedOnly = hasSelection
            dir = d.fileURL?.deletingLastPathComponent()
            updateCount()
        }
        .onChange(of: selectedOnly) { _, _ in updateCount() }
    }

    func ids(_ d: Document) -> [UUID]? { selectedOnly ? ArtboardOps.selectedBoards(d) : nil }

    func updateCount() {
        guard let d = AppActions.doc else { return }
        count = ArtboardExport.list(d.state, ids(d)).count
    }

    func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Choose"
        if UIBlock.run(p) == .OK, let u = p.url { dir = u }
    }

    func run() {
        guard let d = AppActions.doc else { return }
        if dir == nil { choose() }
        guard let folder = dir else { return }
        do {
            let files = try ArtboardExport.export(d.state, ids: ids(d), to: folder, options: o)
            AppModel.shared.setStatus("Exported \(files.count) file\(files.count == 1 ? "" : "s") to \(folder.lastPathComponent).")
        } catch { AppActions.alert("Could not export the artboards.", error.localizedDescription) }
    }
}
