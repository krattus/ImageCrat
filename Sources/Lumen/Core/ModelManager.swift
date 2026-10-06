import Foundation
import CoreML
import SwiftUI

/// A downloadable on-device model (Core ML package/model or raw weight files).
struct ModelSpec: Identifiable, Hashable {
    struct File: Hashable {
        var url: URL                 // remote source
        var path: String             // relative path inside the model's folder
        var sha256: String? = nil
    }
    var id: String                   // folder name, e.g. "sam2.1-small"
    var name: String                 // display name
    var purpose: String              // what it powers
    var license: String
    var approxMB: Int
    var files: [File]
    /// Relative paths of `.mlpackage` / `.mlmodel` items to compile to `.mlmodelc` after download.
    var compile: [String] = []

    static func == (a: ModelSpec, b: ModelSpec) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// False while a file's source is a placeholder (models converted by the Lumen team that have no public host yet):
    /// such a model can only be installed from a models pack (Preferences ▸ AI Models ▸ Import Models…).
    var isDownloadable: Bool { !files.isEmpty && !files.contains { ModelManager.isPlaceholder($0.url) } }

    /// The pinned Hugging Face revision of its files (first 12 characters), else a fingerprint of the expected checksums,
    /// else "main" (follows the repository's main branch). Written into model packs.
    var version: String {
        let revs = Set(files.compactMap { ModelManager.revision($0.url) })
        if revs.count == 1, let r = revs.first, r != "main" { return String(r.prefix(12)) }
        if let s = files.compactMap(\.sha256).first { return "sha-" + s.prefix(12) }
        return "main"
    }
}

enum ModelError: LocalizedError {
    case notInstalled(String), download(String), compile(String), notDownloadable(String)
    var errorDescription: String? {
        switch self {
        case .notInstalled(let n):
            if let s = ModelManager.shared.specs.first(where: { $0.name == n || $0.id == n }), !s.isDownloadable {
                return ModelError.notDownloadable(s.name).errorDescription
            }
            return "The model “\(n)” is not installed. Download it in Preferences ▸ AI Models."
        case .notDownloadable(let n):
            return "The model “\(n)” can't be downloaded yet — import it from a models pack (Preferences ▸ AI Models ▸ Import Models…)."
        case .download(let m): return "Model download failed: \(m)"
        case .compile(let m): return "Model compilation failed: \(m)"
        }
    }
}

/// Downloads, verifies, compiles and caches models in ~/Library/Application Support/ImageCrat/Models/<id>/.
@Observable
final class ModelManager {
    static let shared = ModelManager()

    private(set) var specs: [ModelSpec] = []
    /// id → 0…1 while downloading.
    var progress: [String: Double] = [:]
    var errors: [String: String] = [:]
    private var tasks: [String: Task<URL, Error>] = [:]
    /// Bumped when models are installed or removed outside a download (import, remove): views that ask `isInstalled` refresh.
    var revision = 0

    /// Self tests point the models folder at a temporary one (also `LUMEN_MODELS_DIR`).
    nonisolated(unsafe) static var rootOverride: URL?

    /// Automated runs read the user's installed models where they already are (ImageCrat's, else Lumen's folder before
    /// the first-launch migration), so ML tests run without downloading. They never create the real folder.
    static var automatedModelsFolder: URL? {
        guard GenAIKeyOverrides.realKeysBlocked, ProcessInfo.processInfo.environment["LUMEN_SUPPORT_DIR"] == nil else { return nil }
        let real = Brand.realSupportFolder.appendingPathComponent("Models")
        let legacy = Brand.applicationSupport.appendingPathComponent(Brand.Legacy.supportFolderName).appendingPathComponent("Models")
        return [real, legacy].first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var root: URL {
        let base = rootOverride ?? ProcessInfo.processInfo.environment["LUMEN_MODELS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? automatedModelsFolder ?? Brand.supportFolder.appendingPathComponent("Models")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func register(_ s: ModelSpec) {
        if let i = specs.firstIndex(where: { $0.id == s.id }) { specs[i] = s } else { specs.append(s) }
    }

    /// Self tests: drops temporary specs.
    func removeSpecs(_ ids: Set<String>) { specs.removeAll { ids.contains($0.id) } }

    func spec(_ id: String) -> ModelSpec? { specs.first { $0.id == id } }
    func folder(_ id: String) -> URL { ModelManager.root.appendingPathComponent(id) }
    private func marker(_ id: String) -> URL { folder(id).appendingPathComponent(".complete") }

    func isInstalled(_ id: String) -> Bool { FileManager.default.fileExists(atPath: marker(id).path) }

    /// Installed, or can be downloaded (not a placeholder): optional extras are only fetched when this is true.
    func canObtain(_ id: String) -> Bool { isInstalled(id) || spec(id)?.isDownloadable == true }

    /// What a feature shows when it needs a model that isn't installed: what to get, and where.
    func missingMessage(_ id: String) -> String {
        guard let s = spec(id) else { return "A required model (\(id)) is not available in this version of ImageCrat." }
        if let e = errors[id] { return e }
        if progress[id] != nil { return "“\(s.name)” is still downloading…" }
        if !s.isDownloadable { return ModelError.notDownloadable(s.name).errorDescription ?? "" }
        return "Needs the “\(s.name)” model (\(s.approxMB) MB) — download it in Preferences ▸ AI Models."
    }

    /// Bytes on disk of an installed model's folder (0 when absent).
    func installedBytes(_ id: String) -> Int64 { ModelManager.folderBytes(folder(id)) }

    static func folderBytes(_ dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            if let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        return total
    }

    /// Hosts of models converted by the Lumen team that have no public repository yet (see `NeuralModelID.lumenModelsRepo`).
    static let placeholderRepos: [String] = [NeuralModelID.lumenModelsRepo]

    static func isPlaceholder(_ url: URL) -> Bool {
        let s = url.absoluteString
        return placeholderRepos.contains { s.contains("/" + $0 + "/") } || url.host == nil || url.host == "example.com"
    }

    /// The revision of a Hugging Face `…/resolve/<revision>/…` URL.
    static func revision(_ url: URL) -> String? {
        let c = url.pathComponents
        guard let i = c.firstIndex(of: "resolve"), i + 1 < c.count else { return nil }
        return c[i + 1]
    }

    /// URL of a file inside an installed model (compiled `.mlmodelc` for compiled items).
    func file(_ id: String, _ relPath: String) throws -> URL {
        guard isInstalled(id) else { throw ModelError.notInstalled(spec(id)?.name ?? id) }
        let f = folder(id)
        if relPath.hasSuffix(".mlpackage") || relPath.hasSuffix(".mlmodel") {
            let c = f.appendingPathComponent((relPath as NSString).deletingPathExtension + ".mlmodelc")
            if FileManager.default.fileExists(atPath: c.path) { return c }
        }
        return f.appendingPathComponent(relPath)
    }

    /// Loads a compiled Core ML model from an installed spec.
    func loadModel(_ id: String, _ relPath: String, units: MLComputeUnits = .all) throws -> MLModel {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        return try MLModel(contentsOf: try file(id, relPath), configuration: cfg)
    }

    /// Ensures the model is present, downloading it if necessary. Returns its folder.
    @discardableResult
    func ensure(_ id: String) async throws -> URL {
        if isInstalled(id) { return folder(id) }
        guard let s = spec(id) else { throw ModelError.notInstalled(id) }
        guard s.isDownloadable else {
            let e = ModelError.notDownloadable(s.name)
            await MainActor.run { self.errors[id] = e.errorDescription }
            DiagLog.shared.warning("Model \(id): not downloadable (needs a models pack)")
            throw e
        }
        if let t = tasks[id] { return try await t.value }
        let t = Task<URL, Error> { try await self.download(s) }
        tasks[id] = t
        defer { tasks[id] = nil }
        return try await t.value
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: folder(id))
        progress[id] = nil
        revision += 1
    }

    private func download(_ s: ModelSpec) async throws -> URL {
        let dir = folder(s.id)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await MainActor.run { self.progress[s.id] = 0; self.errors[s.id] = nil }
        do {
            for (i, f) in s.files.enumerated() {
                let dest = dir.appendingPathComponent(f.path)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let (tmp, resp) = try await URLSession.shared.download(from: f.url)
                if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                    throw ModelError.download("HTTP \(h.statusCode) for \(f.url.lastPathComponent)")
                }
                if let want = f.sha256 {
                    let got = try ModelManager.sha256(tmp)
                    guard got.lowercased() == want.lowercased() else { throw ModelError.download("checksum mismatch for \(f.path)") }
                }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                // unzip archives (e.g. zipped .mlpackage)
                if dest.pathExtension == "zip" {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    p.arguments = ["-x", "-k", dest.path, dest.deletingLastPathComponent().path]
                    try p.run(); p.waitUntilExit()
                    try? FileManager.default.removeItem(at: dest)
                }
                let p = Double(i + 1) / Double(max(1, s.files.count)) * 0.9
                await MainActor.run { self.progress[s.id] = p }
            }
            for rel in s.compile {
                let src = dir.appendingPathComponent(rel)
                do {
                    let compiled = try await MLModel.compileModel(at: src)
                    let dest = dir.appendingPathComponent((rel as NSString).deletingPathExtension + ".mlmodelc")
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: compiled, to: dest)
                } catch { throw ModelError.compile("\(rel): \(error.localizedDescription)") }
            }
            FileManager.default.createFile(atPath: marker(s.id).path, contents: Data())
            await MainActor.run { self.progress[s.id] = nil }
            return dir
        } catch {
            await MainActor.run { self.progress[s.id] = nil; self.errors[s.id] = error.localizedDescription }
            DiagLog.shared.error("Model \(s.id): \(error.localizedDescription)")
            throw error
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return String(out.split(separator: " ").first ?? "")
    }

    /// Hugging Face "resolve" URL for a file in a repo.
    static func hf(_ repo: String, _ path: String, revision: String = "main") -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(path)")!
    }
}

/// Preferences ▸ AI Models: install / remove on-device models, and export / import models packs (for a Mac that can't
/// download a model, see `ModelPack`).
struct ModelsPreferencesView: View {
    @Bindable var mm = ModelManager.shared
    @Bindable var pack = ModelPackController.shared
    @State private var selected: Set<String> = []

    var body: some View {
        let _ = mm.revision
        let installed = mm.specs.filter { mm.isInstalled($0.id) }.map(\.id)
        let chosen = installed.filter { selected.contains($0) }
        VStack(alignment: .leading, spacing: 6) {
            Text("On-device models are stored in ~/Library/Application Support/ImageCrat/Models.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(mm.specs) { s in row(s, installed: installed.contains(s.id)) }
                }
            }
            .frame(height: 220)
            Divider()
            if pack.isRunning {
                HStack(spacing: 6) {
                    ProgressView(value: pack.fraction).frame(width: 110)
                    Text(tr(pack.message)).font(Theme.fontSmall).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Cancel") { pack.cancel() }.buttonStyle(PanelButtonStyle())
                }
            } else {
                HStack(spacing: 6) {
                    Button(tr(chosen.isEmpty ? "Export All…" : "Export \(chosen.count) Selected…")) { pack.chooseAndExport(ids: chosen.isEmpty ? installed : chosen) }
                        .buttonStyle(PanelButtonStyle()).disabled(installed.isEmpty)
                    Button("Import Models…") { pack.chooseAndImport() }.buttonStyle(PanelButtonStyle())
                    Spacer()
                }
            }
            Text(tr(pack.result ?? "A models pack is a folder of installed models with checksums, for installing them on a Mac that can't download them. Tick models to export only those."))
                .font(Theme.fontSmall).foregroundStyle(pack.result == nil ? Theme.textFaint : Theme.textDim)
                .fixedSize(horizontal: false, vertical: true).lineLimit(5)
        }
    }

    func row(_ s: ModelSpec, installed: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Toggle("", isOn: Binding(get: { selected.contains(s.id) }, set: { if $0 { selected.insert(s.id) } else { selected.remove(s.id) } }))
                .toggleStyle(.checkbox).labelsHidden().disabled(!installed).opacity(installed ? 1 : 0.3)
                .help(tr(installed ? "Include in Export" : "Not installed"))
            VStack(alignment: .leading, spacing: 1) {
                Text(tr(s.name)).font(Theme.fontBold)
                Text(tr(s.purpose)).font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                Text("\(s.approxMB) MB · \(s.license)").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                if let e = mm.errors[s.id] { Text(tr(e)).font(Theme.fontSmall).foregroundStyle(.red) }
            }
            Spacer()
            if let p = mm.progress[s.id] {
                ProgressView(value: p).frame(width: 80)
            } else if installed {
                Button("Remove") { mm.delete(s.id); selected.remove(s.id) }.buttonStyle(PanelButtonStyle())
            } else if !s.isDownloadable {
                Text("Not downloadable — import from a models pack").font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.trailing).frame(width: 104, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
                    .help("This model has no public download yet. Export it on a Mac that has it (Export…), then use Import Models… here.")
            } else {
                Button("Download") { Task { try? await mm.ensure(s.id) } }.buttonStyle(PanelButtonStyle(prominent: true))
            }
        }
    }
}
