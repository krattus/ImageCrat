import AppKit
import CoreML
import CryptoKit
import UniformTypeIdentifiers

/// A models pack: installed on-device models copied to a folder with checksums, so another Mac can install models it
/// can't download (NAFNet and GFPGAN have no public host yet) or shouldn't download again (SAM 3.1 is 3.3 GB).
///
///     Lumen Models 2026-10-02/
///       manifest.json            format, Lumen version, and per model: id, name, version, size, sha256, files
///       README.txt               how to import
///       nafnet-sidd-w32/
///         lumen-model.json       the same entry for this model alone (a single model folder imports on its own)
///         NAFNet_SIDD_w32.mlpackage/…, NAFNet_SIDD_w32.mlmodelc/…
///
/// Export writes a folder, not a zip: the weights are already dense binaries (zip saves a few percent), zipping 6 GB
/// takes minutes and twice the disk space, and Finder / AirDrop compress a folder on their own when sending it.
/// Import accepts the pack folder, its manifest.json, a zip of it, or one model folder (from a pack, or copied
/// straight from another Mac's Models folder — then only ImageCrat's built-in checksums can be checked).
struct ModelPackManifest: Codable, Equatable {
    static let fileName = "manifest.json"
    static let modelFileName = "imagecrat-model.json"
    static let formatName = "imagecrat-models-pack"
    /// Names used by packs exported before the rename (still imported).
    static let legacyModelFileName = "lumen-model.json"
    static let legacyFormatName = "lumen-models-pack"
    static let modelFileNames: Set<String> = [modelFileName, legacyModelFileName]

    struct FileEntry: Codable, Equatable {
        var path: String
        var size: Int64
        var sha256: String
    }
    struct Model: Codable, Equatable {
        var id: String
        var name: String
        var version: String
        var size: Int64
        /// SHA-256 over the sorted "sha256  path" lines of `files` (one value to compare a whole model).
        var sha256: String
        var files: [FileEntry]
    }

    var format = ModelPackManifest.formatName
    var formatVersion = 1
    var createdBy = ""
    var created = ""
    var models: [Model] = []

    static func digest(_ files: [FileEntry]) -> String {
        let lines = files.sorted { $0.path < $1.path }.map { "\($0.sha256)  \($0.path)" }.joined(separator: "\n")
        return ModelPack.hex(SHA256.hash(data: Data(lines.utf8)))
    }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    static func read(_ url: URL) -> ModelPackManifest? {
        guard let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode(ModelPackManifest.self, from: d), m.format == formatName || m.format == legacyFormatName else { return nil }
        return m
    }
}

enum ModelPack {
    enum PackError: LocalizedError {
        case cancelled, nothingToExport, destinationExists(String), notEnoughSpace(needed: Int64, free: Int64), notAPack(String), unzip(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Cancelled."
            case .nothingToExport: return "No installed models to export."
            case .destinationExists(let n): return "“\(n)” already exists — choose another name."
            case .notEnoughSpace(let n, let f):
                return "Not enough free space: \(ModelPack.bytes(n)) needed, \(ModelPack.bytes(f)) available."
            case .notAPack(let n): return "“\(n)” is not an ImageCrat models pack or model folder."
            case .unzip(let m): return "Could not unzip the models pack: \(m)"
            }
        }
    }

    /// Cancellation and progress for a running export / import (called from the worker thread).
    final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var _cancelled = false
        var onProgress: (Double, String) -> Void = { _, _ in }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
        func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
        func check() throws { if cancelled { throw PackError.cancelled } }
        var total: Int64 = 1
        var done: Int64 = 0
        func advance(_ n: Int, _ message: String) {
            done += Int64(n)
            onProgress(min(1, Double(done) / Double(max(1, total))), message)
        }
    }

    static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static let skippedNames: Set<String> = Set([".complete", ".DS_Store"]).union(ModelPackManifest.modelFileNames)

    /// Regular files of a model folder, relative paths sorted (markers and pack metadata left out).
    static func files(in dir: URL) -> [(path: String, url: URL, size: Int64)] {
        let base = dir.standardizedFileURL.resolvingSymlinksInPath().path
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [] }
        var out: [(String, URL, Int64)] = []
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true,
                  !skippedNames.contains(u.lastPathComponent) else { continue }
            let full = u.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(base + "/") else { continue }
            out.append((String(full.dropFirst(base.count + 1)), u, Int64(v.fileSize ?? 0)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Streams `src` through SHA-256, copying it to `dst` on the way when given. Returns the hex digest.
    static func hashFile(_ src: URL, copyTo dst: URL? = nil, job: Job? = nil, label: String = "") throws -> String {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        var output: FileHandle?
        if let dst {
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dst.path, contents: nil)
            output = try FileHandle(forWritingTo: dst)
        }
        defer { try? output?.close() }
        var h = SHA256()
        while true {
            try job?.check()
            let chunk: Data = try autoreleasepool { try input.read(upToCount: 8 << 20) ?? Data() }
            if chunk.isEmpty { break }
            h.update(data: chunk)
            try output?.write(contentsOf: chunk)
            job?.advance(chunk.count, label)
        }
        return hex(h.finalize())
    }

    static func freeSpace(at url: URL) -> Int64? {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 { u.deleteLastPathComponent() }
        return (try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Export

    /// Copies the installed models `ids` from `root` into a new folder `dest` (written as `dest.partial`, renamed when
    /// complete; removed on error or cancel).
    @discardableResult
    static func export(ids: [String], specs: [ModelSpec], root: URL, to dest: URL, job: Job = Job()) throws -> ModelPackManifest {
        let fm = FileManager.default
        let wanted = ids.filter { fm.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent(".complete").path) }
        guard !wanted.isEmpty else { throw PackError.nothingToExport }
        guard !fm.fileExists(atPath: dest.path) else { throw PackError.destinationExists(dest.lastPathComponent) }
        let listing = wanted.map { ($0, files(in: root.appendingPathComponent($0))) }
        job.total = max(1, listing.reduce(0) { $0 + $1.1.reduce(0) { $0 + $1.size } })
        if let free = freeSpace(at: dest.deletingLastPathComponent()), free < job.total + (64 << 20) {
            throw PackError.notEnoughSpace(needed: job.total, free: free)
        }
        let partial = dest.deletingLastPathComponent().appendingPathComponent(dest.lastPathComponent + ".partial")
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        do {
            var manifest = ModelPackManifest(createdBy: "\(Brand.name) \(AppInfo.version) (\(AppInfo.build))", created: ISO8601DateFormatter().string(from: Date()))
            for (id, list) in listing {
                let spec = specs.first { $0.id == id }
                var entries: [ModelPackManifest.FileEntry] = []
                for f in list {
                    let sha = try hashFile(f.url, copyTo: partial.appendingPathComponent(id).appendingPathComponent(f.path), job: job,
                                           label: "Exporting \(spec?.name ?? id)…")
                    entries.append(.init(path: f.path, size: f.size, sha256: sha))
                }
                let model = ModelPackManifest.Model(id: id, name: spec?.name ?? id, version: spec?.version ?? "unknown",
                                                    size: entries.reduce(0) { $0 + $1.size }, sha256: ModelPackManifest.digest(entries), files: entries)
                var single = manifest
                single.models = [model]
                try single.encoded().write(to: partial.appendingPathComponent(id).appendingPathComponent(ModelPackManifest.modelFileName))
                manifest.models.append(model)
            }
            try manifest.encoded().write(to: partial.appendingPathComponent(ModelPackManifest.fileName))
            try readme(manifest).write(to: partial.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
            try fm.moveItem(at: partial, to: dest)
            DiagLog.shared.info("Exported a models pack (\(manifest.models.count) models, \(bytes(job.total)))")
            return manifest
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    static func readme(_ m: ModelPackManifest) -> String {
        var s = "ImageCrat models pack — \(m.models.count) on-device model\(m.models.count == 1 ? "" : "s"), created by \(m.createdBy).\n\n"
        s += "To install on another Mac: open ImageCrat ▸ Preferences ▸ AI Models ▸ Import Models… and choose this folder\n"
        s += "(or manifest.json, a zip of this folder, or a single model folder). ImageCrat checks every file's SHA-256 before installing.\n\n"
        for x in m.models { s += "  \(x.id)  \(x.name)  version \(x.version)  \(bytes(x.size))\n" }
        return s
    }

    // MARK: Import

    struct ImportResult: Equatable {
        var installed: [String] = []
        var skipped: [String: String] = [:]     // id → why
        var rejected: [String: String] = [:]    // id → why
        var notes: [String] = []

        var summary: String {
            var parts: [String] = []
            if !installed.isEmpty { parts.append("Installed \(installed.count): \(installed.joined(separator: ", "))") }
            if !skipped.isEmpty { parts.append("Skipped \(skipped.count): " + skipped.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")) }
            if !rejected.isEmpty { parts.append("Rejected \(rejected.count): " + rejected.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")) }
            if parts.isEmpty { parts.append("Nothing to import.") }
            return (parts + notes).joined(separator: ". ") + (parts.last?.hasSuffix(".") == true ? "" : ".")
        }
    }

    /// One model to import: its folder, and the manifest entry when the pack has one (nil for a bare model folder).
    struct Source {
        var id: String
        var folder: URL
        var entry: ModelPackManifest.Model?
    }

    static func unzip(_ zip: URL, into dir: URL, job: Job) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        while p.isRunning {
            if job.cancelled { p.terminate(); throw PackError.cancelled }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard p.terminationStatus == 0 else {
            throw PackError.unzip(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ditto failed")
        }
    }

    /// What `url` (pack folder, manifest.json, model folder, or an already unzipped folder) contains.
    static func sources(at url: URL, specs: [ModelSpec]) -> [Source]? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            guard url.lastPathComponent == ModelPackManifest.fileName || ModelPackManifest.modelFileNames.contains(url.lastPathComponent) else { return nil }
            return sources(at: url.deletingLastPathComponent(), specs: specs)
        }
        let known = Set(specs.map(\.id))
        if let m = ModelPackManifest.read(url.appendingPathComponent(ModelPackManifest.fileName)) {
            return m.models.map { Source(id: $0.id, folder: url.appendingPathComponent($0.id), entry: $0) }
        }
        if let m = ModelPackManifest.read(url.appendingPathComponent(ModelPackManifest.modelFileName))
            ?? ModelPackManifest.read(url.appendingPathComponent(ModelPackManifest.legacyModelFileName)), let e = m.models.first {
            return [Source(id: e.id, folder: url, entry: e)]
        }
        // a model folder inside a pack, given on its own: the pack's manifest is one level up
        if known.contains(url.lastPathComponent),
           let m = ModelPackManifest.read(url.deletingLastPathComponent().appendingPathComponent(ModelPackManifest.fileName)),
           let e = m.models.first(where: { $0.id == url.lastPathComponent }) {
            return [Source(id: e.id, folder: url, entry: e)]
        }
        // a bare model folder copied from another Mac's Models folder
        if known.contains(url.lastPathComponent) { return [Source(id: url.lastPathComponent, folder: url, entry: nil)] }
        // a folder of model folders (another Mac's whole Models folder), or a zip that unpacked into one folder
        let children = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.lastPathComponent != "__MACOSX" }
        let models = children.filter { known.contains($0.lastPathComponent) }
        if !models.isEmpty {
            return models.sorted { $0.lastPathComponent < $1.lastPathComponent }.flatMap { sources(at: $0, specs: specs) ?? [] }
        }
        if children.count == 1 { return sources(at: children[0], specs: specs) }
        return nil
    }

    /// Items a working install needs: every compiled package (as .mlmodelc or .mlpackage) and every downloaded file that
    /// isn't an archive.
    static func missingItems(_ spec: ModelSpec, in dir: URL) -> [String] {
        let fm = FileManager.default
        var missing: [String] = []
        for rel in spec.compile {
            let compiled = (rel as NSString).deletingPathExtension + ".mlmodelc"
            if !fm.fileExists(atPath: dir.appendingPathComponent(rel).path) && !fm.fileExists(atPath: dir.appendingPathComponent(compiled).path) { missing.append(rel) }
        }
        for f in spec.files where f.url.pathExtension != "zip" && !spec.compile.contains(where: { f.path.hasPrefix($0 + "/") }) {
            if !fm.fileExists(atPath: dir.appendingPathComponent(f.path).path) { missing.append(f.path) }
        }
        return missing
    }

    /// Installs models from `url` into `root`: checks every file against the pack's SHA-256 (and Lumen's own checksums
    /// where it has them) while copying into a staging folder next to the models, compiles Core ML packages that come
    /// without a compiled copy, then swaps the folder in and marks it installed (`.complete`). Models that are already
    /// installed with identical files are skipped; a model with a missing or altered file is rejected and nothing of it
    /// is installed.
    static func importModels(from url: URL, specs: [ModelSpec], root: URL, job: Job = Job()) async throws -> ImportResult {
        let fm = FileManager.default
        var tempDir: URL?
        defer { if let t = tempDir { try? fm.removeItem(at: t) } }
        var src = url
        if url.pathExtension.lowercased() == "zip" {
            job.onProgress(0, "Unzipping…")
            let t = root.deletingLastPathComponent().appendingPathComponent(".imagecrat-import-\(UUID().uuidString)")
            try fm.createDirectory(at: t, withIntermediateDirectories: true)
            tempDir = t
            try unzip(url, into: t, job: job)
            src = t
        }
        guard let list = sources(at: src, specs: specs), !list.isEmpty else { throw PackError.notAPack(url.lastPathComponent) }

        var result = ImportResult()
        var plan: [(Source, ModelSpec, [(path: String, url: URL, size: Int64)])] = []
        for s in list {
            guard let spec = specs.first(where: { $0.id == s.id }) else { result.rejected[s.id] = "not a model this version of ImageCrat knows"; continue }
            guard fm.fileExists(atPath: s.folder.path) else { result.rejected[s.id] = "its folder is missing from the pack"; continue }
            let present = files(in: s.folder)
            if let e = s.entry {
                let have = Dictionary(present.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
                if let miss = e.files.first(where: { have[$0.path] == nil }) { result.rejected[s.id] = "missing file \(miss.path)"; continue }
                if let bad = e.files.first(where: { have[$0.path] != $0.size }) { result.rejected[s.id] = "wrong size: \(bad.path)"; continue }
            }
            plan.append((s, spec, present.filter { p in s.entry.map { $0.files.contains { $0.path == p.path } } ?? true }))
        }
        job.total = max(1, plan.reduce(0) { $0 + $1.2.reduce(0) { $0 + $1.size } })
        let need = plan.reduce(Int64(0)) { $0 + $1.2.reduce(0) { $0 + $1.size } }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if let free = freeSpace(at: root), free < need + (64 << 20) { throw PackError.notEnoughSpace(needed: need, free: free) }

        for (s, spec, list) in plan {
            try job.check()
            let dest = root.appendingPathComponent(s.id)
            let label = "Checking \(spec.name)…"
            // Lumen's own checksums (downloads with a known SHA-256 that are kept as-is, e.g. Core ML package weights)
            let builtIn = Dictionary(spec.files.compactMap { f in f.sha256.map { (f.path, $0.lowercased()) } }, uniquingKeysWith: { a, _ in a })
            // already installed and identical → skip (sizes first, then contents)
            if fm.fileExists(atPath: dest.appendingPathComponent(".complete").path) {
                let installed = files(in: dest)
                if installed.map(\.path) == list.map(\.path), installed.map(\.size) == list.map(\.size) {
                    var same = true
                    let expected = s.entry.map { Dictionary($0.files.map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a }) }
                    for (i, f) in installed.enumerated() {
                        let a = try hashFile(f.url, job: job, label: label)
                        let b = try expected?[f.path] ?? hashFile(list[i].url, job: nil)
                        if a != b { same = false; break }
                    }
                    if same {
                        result.skipped[s.id] = "already installed, identical"
                        job.advance(Int(clamping: list.reduce(Int64(0)) { $0 + $1.size }) , label)
                        continue
                    }
                }
            }
            let stage = root.appendingPathComponent(".import-\(s.id)-\(UUID().uuidString.prefix(8))")
            try? fm.removeItem(at: stage)
            var failure: String?
            do {
                for f in list {
                    let sha = try hashFile(f.url, copyTo: stage.appendingPathComponent(f.path), job: job, label: label)
                    if let want = s.entry?.files.first(where: { $0.path == f.path })?.sha256, want.lowercased() != sha { failure = "checksum mismatch: \(f.path)"; break }
                    if let want = builtIn[f.path], want != sha { failure = "doesn't match ImageCrat's checksum: \(f.path)"; break }
                }
                if failure == nil {
                    let missing = missingItems(spec, in: stage)
                    if !missing.isEmpty { failure = "incomplete (missing \(missing.joined(separator: ", ")))" }
                }
                if failure == nil {
                    // Core ML packages without a compiled copy are compiled here, as after a download
                    for rel in spec.compile {
                        let compiled = stage.appendingPathComponent((rel as NSString).deletingPathExtension + ".mlmodelc")
                        let pkg = stage.appendingPathComponent(rel)
                        guard !fm.fileExists(atPath: compiled.path), fm.fileExists(atPath: pkg.path) else { continue }
                        job.onProgress(Double(job.done) / Double(job.total), "Compiling \(spec.name)…")
                        do {
                            let c = try await MLModel.compileModel(at: pkg)
                            try fm.moveItem(at: c, to: compiled)
                        } catch { failure = "could not compile \(rel): \(error.localizedDescription)"; break }
                    }
                }
            } catch PackError.cancelled {
                try? fm.removeItem(at: stage)
                throw PackError.cancelled
            } catch {
                failure = error.localizedDescription
            }
            if let failure {
                try? fm.removeItem(at: stage)
                result.rejected[s.id] = failure
                DiagLog.shared.warning("Models pack: rejected \(s.id) — \(failure)")
                continue
            }
            if s.entry == nil { result.notes.append("\(s.id): no pack checksums (a plain model folder) — checked against ImageCrat's built-in checksums only") }
            if let e = s.entry, e.version != spec.version { result.notes.append("\(s.id): pack version \(e.version), this ImageCrat expects \(spec.version)") }
            if let e = s.entry {
                var single = ModelPackManifest(createdBy: "imported", created: ISO8601DateFormatter().string(from: Date()))
                single.models = [e]
                try? single.encoded().write(to: stage.appendingPathComponent(ModelPackManifest.modelFileName))
            }
            fm.createFile(atPath: stage.appendingPathComponent(".complete").path, contents: Data())
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: stage, to: dest)
            result.installed.append(s.id)
            DiagLog.shared.info("Models pack: installed \(s.id)")
        }
        return result
    }
}

/// Runs model pack exports / imports off the main thread for Preferences ▸ AI Models (progress, Cancel, last result).
@Observable
final class ModelPackController {
    static let shared = ModelPackController()
    private(set) var running: String?
    private(set) var fraction: Double = 0
    private(set) var message = ""
    var result: String?
    @ObservationIgnored private var job: ModelPack.Job?

    var isRunning: Bool { running != nil }
    func cancel() { job?.cancel(); message = "Cancelling…" }

    private func makeJob() -> ModelPack.Job {
        let j = ModelPack.Job()
        j.onProgress = { [weak self] f, m in
            DispatchQueue.main.async { guard let self, self.job === j else { return }; self.fraction = f; if !m.isEmpty { self.message = tr(m) } }
        }
        job = j
        return j
    }

    static var defaultPackName: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "ImageCrat Models \(f.string(from: Date()))"
    }

    /// Asks where to write the pack, then exports.
    func chooseAndExport(ids: [String]) {
        // automated runs (menu fuzzing answers panels with a scratch folder) must not copy gigabytes of real models
        if GenAIKeyOverrides.realKeysBlocked { result = "Export is not available in automated runs."; return }
        let p = NSSavePanel()
        p.title = tr("Export Models")
        p.message = tr("ImageCrat writes a folder with the models and a manifest of their checksums.")
        p.nameFieldStringValue = ModelPackController.defaultPackName
        p.canCreateDirectories = true
        p.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard p.runModal() == .OK, let url = p.url else { return }
        startExport(ids: ids, to: url)
    }

    func startExport(ids: [String], to url: URL, root: URL = ModelManager.root, completion: ((Result<ModelPackManifest, Error>) -> Void)? = nil) {
        guard !isRunning else { return }
        let specs = ModelManager.shared.specs
        let j = makeJob()
        running = "Exporting"; fraction = 0; message = "Exporting…"; result = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try ModelPack.export(ids: ids, specs: specs, root: root, to: url, job: j) }
            DispatchQueue.main.async {
                self.running = nil; self.job = nil
                switch r {
                case .success(let m):
                    self.result = "Exported \(m.models.count) model\(m.models.count == 1 ? "" : "s") (\(ModelPack.bytes(m.models.reduce(0) { $0 + $1.size }))) to “\(url.lastPathComponent)”."
                    if completion == nil { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                case .failure(let e): self.result = "Export failed: \(e.localizedDescription)"
                }
                completion?(r)
            }
        }
    }

    func chooseAndImport() {
        if GenAIKeyOverrides.realKeysBlocked { result = "Import is not available in automated runs."; return }   // never writes the real Models folder
        let p = NSOpenPanel()
        p.title = tr("Import Models")
        p.message = tr("Choose an ImageCrat models pack (folder, zip or manifest.json) or a single model folder.")
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = false
        p.allowedContentTypes = [.folder, .zip, .json]
        guard p.runModal() == .OK, let url = p.url else { return }
        startImport(from: url)
    }

    func startImport(from url: URL, root: URL = ModelManager.root, completion: ((Result<ModelPack.ImportResult, Error>) -> Void)? = nil) {
        guard !isRunning else { return }
        let specs = ModelManager.shared.specs
        let j = makeJob()
        running = "Importing"; fraction = 0; message = "Reading the pack…"; result = nil
        Task.detached(priority: .userInitiated) {
            let r: Result<ModelPack.ImportResult, Error>
            do { r = .success(try await ModelPack.importModels(from: url, specs: specs, root: root, job: j)) } catch { r = .failure(error) }
            await MainActor.run {
                self.running = nil; self.job = nil
                switch r {
                case .success(let res): self.result = res.summary
                case .failure(let e): self.result = "Import failed: \(e.localizedDescription)"
                }
                ModelManager.shared.revision += 1
                if case .success(let res) = r, !res.installed.isEmpty { SegModels.unloadAll(); NeuralModels.unloadAll() }
                completion?(r)
            }
        }
    }
}
