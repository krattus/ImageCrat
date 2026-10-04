import AppKit
import SwiftUI
import ImageIO
import ImageCratCore

// MARK: - Import report

/// What happened to the contents of a Photoshop file on import: what stayed editable, what was substituted
/// (fonts, profiles…), what was kept as pixels and what had to be left out.
struct PSDImportReport: Codable, Equatable {
    enum Status: String, Codable, CaseIterable {
        case editable, substituted, flattened, skipped, info

        var title: String {
            switch self {
            case .editable: return "Kept editable"
            case .substituted: return "Substituted or approximated"
            case .flattened: return "Kept as pixels"
            case .skipped: return "Left out"
            case .info: return "Notes"
            }
        }
        var symbol: String {
            switch self {
            case .editable: return "checkmark.circle"
            case .substituted: return "arrow.triangle.2.circlepath"
            case .flattened: return "square.grid.3x3.fill"
            case .skipped: return "xmark.circle"
            case .info: return "info.circle"
            }
        }
    }

    struct Item: Codable, Equatable, Identifiable {
        var id = UUID()
        var status: Status
        /// Layer name ("" = the document).
        var layer: String
        var feature: String
        var detail: String
    }

    var fileName = ""
    var layerCount = 0
    var items: [Item] = []
    var missingFonts: Set<String> = []

    mutating func add(_ status: Status, layer: String, feature: String, detail: String) {
        guard items.count < 5000 else { return }
        items.append(Item(status: status, layer: layer, feature: feature, detail: detail))
    }

    func count(_ s: Status) -> Int { items.filter { $0.status == s }.count }
    func items(_ s: Status) -> [Item] { items.filter { $0.status == s } }

    /// `Int(Double)` traps on NaN and out-of-range values, which a damaged file can contain.
    static func int(_ v: Double?) -> Int? { v.flatMap { $0.isFinite && abs($0) < 1e15 ? Int($0) : nil } }
    static func num(_ v: Double) -> String { int(v).map { Double($0) == v ? String($0) : String(format: "%.1f", v) } ?? "?" }

    /// One line for the status bar.
    var summary: String {
        var parts: [String] = []
        let e = items(.editable).filter { !$0.layer.isEmpty }
        if !e.isEmpty {
            var kinds: [String] = []
            for f in e.map({ $0.feature.lowercased() }) where !kinds.contains(f) { kinds.append(f) }
            parts.append("\(e.count) kept editable (\(kinds.prefix(4).joined(separator: ", "))\(kinds.count > 4 ? "…" : ""))")
        }
        if !missingFonts.isEmpty { parts.append("\(missingFonts.count) font\(missingFonts.count == 1 ? "" : "s") substituted") }
        let sub = count(.substituted) - items(.substituted).filter { $0.feature == "Font" }.count
        if sub > 0 { parts.append("\(sub) approximated") }
        if count(.flattened) > 0 { parts.append("\(count(.flattened)) kept as pixels") }
        if count(.skipped) > 0 { parts.append("\(count(.skipped)) left out") }
        let head = "Opened “\(fileName)”: \(layerCount) layer\(layerCount == 1 ? "" : "s")"
        return parts.isEmpty ? head + "." : head + " — " + parts.joined(separator: ", ") + ". See File ▸ PSD Import Report…"
    }

    /// True when there is something worth pointing the user to.
    var isNoteworthy: Bool { items.contains { $0.status != .info || !$0.layer.isEmpty } }

    /// Plain text version (clipboard, logs).
    var text: String {
        var out = "PSD Import Report — \(fileName)\n\(layerCount) layer\(layerCount == 1 ? "" : "s")\n"
        for s in Status.allCases {
            let list = items(s)
            if list.isEmpty { continue }
            out += "\n\(s.title) (\(list.count))\n"
            for i in list { out += "  • \(i.layer.isEmpty ? "Document" : i.layer) — \(i.feature): \(i.detail)\n" }
        }
        return out
    }
}

// MARK: - Module

enum PSDImportModule {
    static let dialogID = "psdImportReport"
    static let extrasKey = "psdImport"

    /// Reports and file patterns by document id (main thread).
    static var reports: [UUID: PSDImportReport] = [:]
    static var patterns: [UUID: [PatternDef]] = [:]

    private struct Extras: Codable {
        var report: PSDImportReport?
        var patterns: [PatternDef] = []
    }

    static func register() {
        DialogRegistry.register(dialogID) { AnyView(PSDImportReportDialog()) }
        MenuRegistry.add("File", "PSD Import Report…", dividerBefore: true, enabled: { report(for: AppModel.shared.activeDocument) != nil }) { DialogRegistry.show(dialogID) }
        // the report and the file's own patterns travel with the document when it is saved as .lumen
        DocumentIO.nativeExtrasWriters[extrasKey] = { d in
            guard reports[d.id] != nil || !(patterns[d.id] ?? []).isEmpty else { return nil }
            return try? PropertyListEncoder().encode(Extras(report: reports[d.id], patterns: patterns[d.id] ?? []))
        }
        DocumentIO.nativeExtrasReaders[extrasKey] = { d, data in
            guard let x = try? PropertyListDecoder().decode(Extras.self, from: data) else { return }
            if let r = x.report { reports[d.id] = r }
            if !x.patterns.isEmpty { patterns[d.id] = x.patterns; addPatterns(x.patterns) }
        }
        FeatureModules.selfTests.append(("psdimport", { out in PSDImportSelfTest.run(out) }))
        // `LUMEN_SELFTEST_ONLY=psdimport Lumen --selftest <dir>` runs just these tests (skips the rest of the suite)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count,
           let only = ProcessInfo.processInfo.environment["LUMEN_SELFTEST_ONLY"], only.hasPrefix("psdimport") {
            _ = NSApplication.shared
            let out = URL(fileURLWithPath: args[i + 1])
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            PSDImportSelfTest.run(out)
            print("done (psdimport only)")
            exit(PSDImportSelfTest.failed == 0 ? 0 : 1)
        }
    }

    static func report(for d: Document?) -> PSDImportReport? { d.flatMap { reports[$0.id] } }

    /// Patterns stored in a PSD become available to fills, shapes and effects (the library is app-wide).
    static func addPatterns(_ defs: [PatternDef]) {
        guard !defs.isEmpty else { return }
        let add = {
            let app = AppModel.shared
            let have = Set(app.customPatterns.map(\.id) + PatternDef.builtIn.map(\.id))
            for p in defs where !have.contains(p.id) { app.customPatterns.append(p) }
        }
        if Thread.isMainThread { add() } else { DispatchQueue.main.async(execute: add) }
    }

    /// Opens a PSD / PSB as a document. When the layers cannot be read the flattened picture is opened instead
    /// (through the system decoder) and the report says so; nil only when nothing at all is readable.
    static func open(_ url: URL) -> Document? {
        var failure = ""
        do {
            let res = try PSDImporter.read(url: url)
            if !res.state.layers.isEmpty {
                let d = Document(state: res.state, name: url.lastPathComponent)
                d.fileURL = url
                attach(res, to: d)
                return d
            }
            failure = "no layers"
        } catch { failure = "\(error)" }
        guard let (cg, dpi) = DocumentIO.loadImage(url: url) else { return nil }
        var st = DocumentState(width: cg.width, height: cg.height, resolution: validResolution(dpi))
        st.layers = [Layer.raster(name: "Background", buffer: PixelBuffer(cgImage: cg))]
        let d = Document(state: st, name: url.lastPathComponent)
        d.fileURL = url
        var r = PSDImportReport(fileName: url.lastPathComponent, layerCount: 1)
        r.add(.flattened, layer: "", feature: "Document", detail: "The layers could not be read (\(failure)); the flattened picture stored in the file was opened instead.")
        attach(PSDImporter.Result(state: st, report: r), to: d)
        return d
    }

    static func attach(_ res: PSDImporter.Result, to d: Document) {
        addPatterns(res.patterns)
        let set = {
            // forget documents that are no longer open
            let open = Set(AppModel.shared.documents.map(\.id))
            if reports.count > 64 { reports = reports.filter { open.contains($0.key) }; patterns = patterns.filter { open.contains($0.key) } }
            reports[d.id] = res.report
            if !res.patterns.isEmpty { patterns[d.id] = res.patterns }
        }
        if Thread.isMainThread { set() } else { DispatchQueue.main.async(execute: set) }
    }

    /// Status-bar line after File ▸ Open (never a dialog: the details are one menu command away).
    static func announce(_ d: Document) {
        guard let r = reports[d.id] else { return }
        AppModel.shared.setStatus(r.summary)
    }
}

// MARK: - Dialog

struct PSDImportReportDialog: View {
    @Bindable var app = AppModel.shared

    var body: some View {
        let r = PSDImportModule.report(for: app.activeDocument)
        DialogFrame(title: "PSD Import Report", width: 560, okTitle: "Done", onOK: {},
                    extraButtons: AnyView(Button("Copy Report") {
                        guard let r else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(r.text, forType: .string)
                    }.buttonStyle(PanelButtonStyle()).disabled(r == nil))) {
            if let r {
                Text("\(r.fileName) — \(r.layerCount) layer\(r.layerCount == 1 ? "" : "s")").foregroundStyle(Theme.textDim)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(PSDImportReport.Status.allCases, id: \.self) { s in
                            let list = r.items(s)
                            if !list.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Image(systemName: s.symbol).foregroundStyle(color(s))
                                        Text("\(s.title) (\(list.count))").font(Theme.fontBold)
                                    }
                                    ForEach(list) { i in
                                        HStack(alignment: .top, spacing: 6) {
                                            Text(i.layer.isEmpty ? "Document" : i.layer).lineLimit(1).frame(width: 150, alignment: .leading)
                                            Text(i.feature).foregroundStyle(Theme.textDim).frame(width: 92, alignment: .leading)
                                            Text(i.detail).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                                            Spacer(minLength: 0)
                                        }
                                        .font(Theme.font)
                                    }
                                }
                            }
                        }
                        if r.items.isEmpty { Text("Everything in the file is ordinary pixel layers and groups; nothing was changed.").foregroundStyle(Theme.textFaint) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
            } else {
                Text("This document was not opened from a Photoshop file.").foregroundStyle(Theme.textFaint)
            }
        }
    }

    func color(_ s: PSDImportReport.Status) -> Color {
        switch s {
        case .editable: return Color(red: 0.3, green: 0.7, blue: 0.4)
        case .substituted: return Color(red: 0.85, green: 0.65, blue: 0.2)
        case .flattened: return Color(red: 0.85, green: 0.5, blue: 0.25)
        case .skipped: return Color(red: 0.85, green: 0.35, blue: 0.35)
        case .info: return Theme.textDim
        }
    }
}
