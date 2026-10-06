import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

// MARK: - Action playback without the Actions panel

enum ActionPlayback {
    /// Plays the steps of `a` on the active document (stops are skipped).
    static func play(_ a: RecordedAction) {
        let rec = ActionRecorder.shared
        let wasPlaying = rec.playing
        rec.playing = true
        defer { rec.playing = wasPlaying }
        for (i, step) in a.steps.enumerated() where a.isEnabled(i) {
            if case .stop = step { continue }
            ActionRecorder.perform(step)
        }
    }

    /// Finds an action by UUID string or by name.
    static func find(_ key: String) -> RecordedAction? {
        let all = ActionRecorder.shared.sets.flatMap(\.actions)
        if let id = UUID(uuidString: key), let a = all.first(where: { $0.id == id }) { return a }
        return all.first { $0.name == key } ?? all.first { $0.name.lowercased() == key.lowercased() }
    }
}

// MARK: - Output helpers

enum OutputWriter {
    enum Format: String, CaseIterable, Identifiable {
        case jpeg = "JPEG", png = "PNG", tiff = "TIFF", psd = "PSD"
        var id: String { rawValue }
        var ext: String { ["jpg", "png", "tif", "psd"][Format.allCases.firstIndex(of: self)!] }
        static func from(_ s: String) -> Format? {
            switch s.lowercased() {
            case "jpg", "jpeg": return .jpeg
            case "png": return .png
            case "tif", "tiff": return .tiff
            case "psd": return .psd
            default: return nil
            }
        }
        var utType: UTType { [UTType.jpeg, .png, .tiff, .data][Format.allCases.firstIndex(of: self)!] }
    }

    struct Metadata {
        var copyright = ""
        var includeICC = true
        var convertToSRGB = true
    }

    /// Flattened image of `st` fitted inside `fit` (w, h) when given.
    static func flatImage(_ st: DocumentState, fit: (Int, Int)?, background: RGBA?, meta: Metadata) -> CGImage? {
        guard var cg = Compositor.shared.flatten(st, background: background) else { return nil }
        if let (w, h) = fit, w > 0, h > 0 {
            let k = min(Double(w) / Double(cg.width), Double(h) / Double(cg.height))
            if abs(k - 1) > 0.0005 { cg = VideoRenderer.scaled(cg, max(1, Int((Double(cg.width) * k).rounded())), max(1, Int((Double(cg.height) * k).rounded()))) ?? cg }
        }
        // pixel values are in the document profile
        let profile = ColorProfiles.space(named: st.profileName)
        if profile.model == .rgb, !ColorProfiles.isSRGB(st.profileName) {
            let tagged = cg.copy(colorSpace: profile) ?? cg
            if meta.convertToSRGB, let c = ColorConvert.draw(tagged, into: sRGBSpace, intent: .perceptual) { cg = c } else { cg = tagged }
        }
        if !meta.includeICC { cg = cg.copy(colorSpace: CGColorSpaceCreateDeviceRGB()) ?? cg }
        return cg
    }

    static func write(_ cg: CGImage, to url: URL, format: Format, quality: Double, dpi: Double, meta: Metadata) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else { throw DocumentIOError.encodeFailed }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = quality }
        if format == .tiff { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] }   // LZW
        if !meta.copyright.isEmpty {
            var tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
            tiff[kCGImagePropertyTIFFCopyright] = meta.copyright
            props[kCGImagePropertyTIFFDictionary] = tiff
            props[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCCopyrightNotice: meta.copyright]
            props[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGCopyright: meta.copyright]
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw DocumentIOError.encodeFailed }
    }

    /// Saves a document in `format` (PSD keeps layers; others are flattened).
    static func save(_ d: Document, to url: URL, format: Format, quality: Double = 0.9, fit: (Int, Int)? = nil, meta: Metadata = Metadata()) throws {
        if format == .psd {
            if let (w, h) = fit, w > 0, h > 0 {
                let k = min(Double(w) / Double(d.state.width), Double(h) / Double(d.state.height))
                if abs(k - 1) > 0.0005 {
                    FilesUI.withActive(d) {
                        AppActions.imageSize(width: max(1, Int(Double(d.state.width) * k)), height: max(1, Int(Double(d.state.height) * k)),
                                             resolution: d.state.resolution, scaleStyles: true)
                    }
                }
            }
            try PSDWriter.write(d.state, to: url)
            return
        }
        guard let cg = flatImage(d.state, fit: fit, background: format == .jpeg ? .white : nil, meta: meta) else { throw DocumentIOError.encodeFailed }
        try write(cg, to: url, format: format, quality: quality, dpi: d.state.resolution, meta: meta)
    }
}

// MARK: - Command-line mode (droplets)

/// `ImageCrat --run-action <id|name> [--action-file a.json] --output <folder> [--format jpeg|png|tiff|psd] [--quality 0.9] files…`
/// and `Lumen --run-script <file.js> [files…]`: headless processing, then exit.
enum CommandLineRunner {
    static func installIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--run-action") || args.contains("--run-script") else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.willFinishLaunchingNotification, object: nil, queue: nil) { _ in
            NSApp.setActivationPolicy(.prohibited)   // no Dock icon for droplet runs
            let code = args.contains("--run-script") ? runScript(args) : runAction(args)
            exit(code)
        }
    }

    struct Parsed { var options: [String: String] = [:]; var files: [URL] = [] }

    static func parse(_ args: [String], valued: Set<String>) -> Parsed {
        var p = Parsed()
        var i = 1
        while i < args.count {
            let a = args[i]
            if valued.contains(a), i + 1 < args.count { p.options[a] = args[i + 1]; i += 2; continue }
            if a.hasPrefix("-") { p.options[a] = ""; i += 1; continue }
            p.files.append(URL(fileURLWithPath: a))
            i += 1
        }
        // expand folders
        p.files = p.files.flatMap { u -> [URL] in
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { return BatchRunner.files(in: u, recursive: true) }
            return [u]
        }
        return p
    }

    /// Returns the process exit code.
    static func runAction(_ args: [String]) -> Int32 {
        let p = parse(args, valued: ["--run-action", "--action-file", "--output", "--format", "--quality", "--suffix"])
        var action: RecordedAction?
        if let f = p.options["--action-file"], let d = try? Data(contentsOf: URL(fileURLWithPath: f)) {
            action = try? JSONDecoder().decode(RecordedAction.self, from: d)
        }
        if action == nil, let key = p.options["--run-action"] { action = ActionPlayback.find(key) }
        guard let a = action else { print("imagecrat: action not found"); return 2 }
        let out = p.options["--output"].map { URL(fileURLWithPath: $0) }
        let fmtOpt = p.options["--format"].flatMap(OutputWriter.Format.from)
        let quality = p.options["--quality"].flatMap(Double.init) ?? 0.9
        let suffix = p.options["--suffix"] ?? ""
        var failures = 0
        for url in p.files {
            do {
                let d = try DocumentIO.load(url: url)
                FilesUI.withActive(d) { ActionPlayback.play(a) }
                let fmt = fmtOpt ?? OutputWriter.Format.from(url.pathExtension) ?? .png
                let folder = out ?? url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let dst = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + suffix + "." + fmt.ext)
                try OutputWriter.save(d, to: dst, format: fmt, quality: quality)
                print("imagecrat: \(url.lastPathComponent) → \(dst.path)")
            } catch {
                failures += 1
                print("imagecrat: failed \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return failures == 0 ? 0 : 1
    }

    static func runScript(_ args: [String]) -> Int32 {
        let p = parse(args, valued: ["--run-script"])
        guard let path = p.options["--run-script"], let src = try? String(contentsOfFile: path, encoding: .utf8) else { print("imagecrat: script not found"); return 2 }
        for f in p.files { if let d = try? DocumentIO.load(url: f) { AppModel.shared.add(d) } }
        let engine = ScriptEngine(name: (path as NSString).lastPathComponent, interactive: false)
        engine.log = { print($0) }
        engine.context.setObject(p.files.map(\.path), forKeyedSubscript: "arguments" as NSString)
        let ok = engine.evaluate(src, file: path)
        return ok ? 0 : 1
    }
}

// MARK: - Droplets

enum DropletBuilder {
    /// Path of the running ImageCrat executable (what the droplet launches).
    static var lumenExecutable: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func asQuote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    /// Creates `<name>.app`: an AppleScript applet (osacompile) whose `open` handler passes the dropped files to
    /// `ImageCrat --run-action … --action-file <bundle>/Contents/Resources/action.json --output <folder>`.
    /// A `run.sh` with the same command line is included for shell use. Falls back to a shell-script bundle.
    @discardableResult
    static func create(at app: URL, action: RecordedAction, output: URL, format: OutputWriter.Format?, executable: String = lumenExecutable) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: app)
        let fmtArg = format.map { " --format " + $0.ext } ?? ""
        let script = """
        on open theItems
        \tset res to (POSIX path of (path to me)) & "Contents/Resources/"
        \tset cmd to quoted form of \(asQuote(executable)) & " --run-action " & quoted form of \(asQuote(action.id.uuidString)) & " --action-file " & quoted form of (res & "action.json") & " --output " & quoted form of \(asQuote(output.path)) & \(asQuote(fmtArg))
        \trepeat with f in theItems
        \t\tset cmd to cmd & " " & quoted form of (POSIX path of f)
        \tend repeat
        \tdo shell script cmd & " > /dev/null 2>&1 &"
        end open

        on run
        \tdisplay dialog "Drop image files or folders on this droplet to process them with the ImageCrat action " & \(asQuote("“" + action.name + "”")) & "." & return & return & "Output: " & \(asQuote(output.path)) buttons {"OK"} default button 1
        end run
        """
        let tmp = fm.temporaryDirectory.appendingPathComponent("lumen-droplet-\(UUID().uuidString).applescript")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: tmp) }
        var compiled = false
        if fm.isExecutableFile(atPath: "/usr/bin/osacompile") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            p.arguments = ["-o", app.path, tmp.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            compiled = p.terminationStatus == 0 && fm.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path)
        }
        let res = app.appendingPathComponent("Contents/Resources")
        let runSh = """
        #!/bin/sh
        # ImageCrat droplet: processes the given files with action “\(action.name)”.
        DIR="$(cd "$(dirname "$0")" && pwd)"
        exec \(shellQuote(executable)) --run-action \(shellQuote(action.id.uuidString)) --action-file "$DIR/action.json" --output \(shellQuote(output.path))\(fmtArg) "$@"
        """
        if !compiled {
            // minimal bundle: the executable is the shell script (works when launched with file arguments)
            let macos = app.appendingPathComponent("Contents/MacOS")
            try fm.createDirectory(at: macos, withIntermediateDirectories: true)
            try fm.createDirectory(at: res, withIntermediateDirectories: true)
            let exe = macos.appendingPathComponent("droplet")
            try runSh.replacingOccurrences(of: "DIR=\"$(cd \"$(dirname \"$0\")\" && pwd)\"", with: "DIR=\"$(cd \"$(dirname \"$0\")/../Resources\" && pwd)\"")
                .write(to: exe, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            let plist: [String: Any] = [
                "CFBundleExecutable": "droplet", "CFBundleIdentifier": "app.imagecrat.droplet.\(action.id.uuidString.prefix(8))",
                "CFBundleName": app.deletingPathExtension().lastPathComponent, "CFBundlePackageType": "APPL",
                "CFBundleDocumentTypes": [["CFBundleTypeRole": "Viewer", "LSItemContentTypes": ["public.item"]]],
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        }
        try fm.createDirectory(at: res, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        try enc.encode(action).write(to: res.appendingPathComponent("action.json"))
        let sh = res.appendingPathComponent("run.sh")
        try runSh.write(to: sh, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sh.path)
        return app
    }
}

struct CreateDropletDialog: View {
    @State private var actionID: UUID? = ActionRecorder.shared.selectedActionID ?? ActionRecorder.shared.sets.first?.actions.first?.id
    @State private var output: URL?
    @State private var format: OutputWriter.Format? = nil

    var body: some View {
        DialogFrame(title: "Create Droplet", width: 440, okTitle: "Save Droplet…", onOK: create) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Action", selection: $actionID) {
                    ForEach(ActionRecorder.shared.sets.flatMap(\.actions)) { a in Text(tr(a.name)).tag(Optional(a.id)) }
                }
                HStack {
                    Text("Destination").frame(width: 80, alignment: .leading)
                    Text(output?.path ?? "—").lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.textDim)
                    Spacer()
                    Button("Choose…") { output = FilesUI.chooseFolder() }.buttonStyle(PanelButtonStyle())
                }
                Picker("Save As", selection: $format) {
                    Text("Same as source").tag(OutputWriter.Format?.none)
                    ForEach(OutputWriter.Format.allCases) { Text(tr($0.rawValue)).tag(Optional($0)) }
                }.frame(width: 260)
                Text("Drop files or folders on the droplet in Finder to run the action; results are saved to the destination.")
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
        }
    }

    func create() {
        guard let id = actionID, let a = ActionRecorder.shared.action(id) else { return }
        guard let out = output ?? FilesUI.chooseFolder(message: "Choose the destination folder for processed files") else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = FilesUI.safeName(a.name) + ".app"
        p.allowedContentTypes = [.application]
        guard UIBlock.run(p) == .OK, let url = p.url else { return }
        do {
            try DropletBuilder.create(at: url, action: a, output: out, format: format)
            AppModel.shared.setStatus("Created droplet \(url.lastPathComponent)")
        } catch { AppActions.alert("Could not create the droplet.", error.localizedDescription) }
    }
}

// MARK: - Image Processor

struct ImageProcessorSettings {
    struct FormatOption { var enabled = false; var resize = false; var width = 1200; var height = 1200; var quality = 0.8 }
    var sources: [URL] = []
    var useOpenImages = false
    var includeSubfolders = false
    var destination: URL? = nil          // nil = same folder as each source
    var jpeg = FormatOption(enabled: true)
    var psd = FormatOption()
    var tiff = FormatOption()
    var png = FormatOption()
    var convertToSRGB = true
    var includeICC = true
    var actionID: UUID? = nil
    var action: RecordedAction? = nil    // explicit action (scripts / tests)
    var copyright = ""
}

enum ImageProcessor {
    /// Runs the processor. Output goes to `<destination>/<FORMAT>/<name>.<ext>`. Returns written files and failures.
    static func run(_ s: ImageProcessorSettings, progress: ((Int, Int, String) -> Void)? = nil) -> (written: [URL], failed: Int) {
        var jobs: [(Document, URL?)] = []
        if s.useOpenImages { jobs = AppModel.shared.documents.map { ($0, $0.fileURL) } }
        let urls = s.sources.flatMap { u -> [URL] in
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { return BatchRunner.files(in: u, recursive: s.includeSubfolders) }
            return [u]
        }
        var written: [URL] = []
        var failed = 0
        let action = s.action ?? s.actionID.flatMap { ActionRecorder.shared.action($0) }
        let total = jobs.count + urls.count
        var n = 0
        func process(_ src: Document, _ url: URL?) {
            n += 1
            progress?(n, total, src.name)
            let base = FilesUI.safeName(((url?.lastPathComponent ?? src.name) as NSString).deletingPathExtension)
            let d = Document(state: src.state, name: src.name)
            if let a = action { FilesUI.withActive(d) { ActionPlayback.play(a) } }
            guard let root = s.destination ?? url?.deletingLastPathComponent() else { failed += 1; return }
            let meta = OutputWriter.Metadata(copyright: s.copyright, includeICC: s.includeICC, convertToSRGB: s.convertToSRGB)
            let formats: [(ImageProcessorSettings.FormatOption, OutputWriter.Format)] = [(s.jpeg, .jpeg), (s.psd, .psd), (s.tiff, .tiff), (s.png, .png)]
            for (opt, fmt) in formats where opt.enabled {
                let folder = root.appendingPathComponent(fmt.rawValue)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let dst = folder.appendingPathComponent(base + "." + fmt.ext)
                    // PSD resizing mutates the working copy: use a fresh copy per format
                    let work = fmt == .psd ? Document(state: d.state, name: d.name) : d
                    try OutputWriter.save(work, to: dst, format: fmt, quality: opt.quality, fit: opt.resize ? (opt.width, opt.height) : nil, meta: meta)
                    written.append(dst)
                } catch { failed += 1 }
            }
        }
        for (d, u) in jobs { process(d, u) }
        for u in urls {
            guard let d = try? DocumentIO.load(url: u) else { failed += 1; continue }
            process(d, u)
        }
        return (written, failed)
    }
}

struct ImageProcessorDialog: View {
    @State private var s = ImageProcessorSettings()
    @State private var status = ""

    var body: some View {
        DialogFrame(title: "Image Processor", width: 520, okTitle: "Run", onOK: run) {
            VStack(alignment: .leading, spacing: 8) {
                Text("1  Select the images to process").font(Theme.fontBold)
                Toggle2(label: "Use Open Images (\(AppModel.shared.documents.count))", on: $s.useOpenImages)
                HStack {
                    Button("Select Folder…") { if let f = FilesUI.chooseFolder() { s.sources = [f] } }.buttonStyle(PanelButtonStyle())
                    Button("Select Files…") { let f = FilesUI.chooseFiles([.image, .pdf]); if !f.isEmpty { s.sources = f } }.buttonStyle(PanelButtonStyle())
                    Text(tr(s.sources.isEmpty ? "—" : (s.sources.count == 1 ? s.sources[0].lastPathComponent : "\(s.sources.count) files")))
                        .lineLimit(1).foregroundStyle(Theme.textDim)
                    Toggle2(label: "Include Subfolders", on: $s.includeSubfolders)
                }
                Text("2  Select location to save processed images").font(Theme.fontBold)
                HStack {
                    Button("Select Folder…") { s.destination = FilesUI.chooseFolder() }.buttonStyle(PanelButtonStyle())
                    Text(tr(s.destination?.path ?? "Save in same location")).lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.textDim)
                    if s.destination != nil { Button("Same Location") { s.destination = nil }.buttonStyle(PanelButtonStyle()) }
                }
                Text("3  File Type").font(Theme.fontBold)
                formatRow("Save as JPEG", $s.jpeg, quality: true)
                Toggle2(label: "Convert Profile to sRGB", on: $s.convertToSRGB).padding(.leading, 20)
                formatRow("Save as PSD", $s.psd, quality: false)
                formatRow("Save as TIFF", $s.tiff, quality: false)
                formatRow("Save as PNG", $s.png, quality: false)
                Text("4  Preferences").font(Theme.fontBold)
                HStack {
                    Toggle("Run Action", isOn: Binding(get: { s.actionID != nil }, set: { s.actionID = $0 ? ActionRecorder.shared.sets.first?.actions.first?.id : nil }))
                        .toggleStyle(.checkbox)
                    if s.actionID != nil {
                        Picker("", selection: $s.actionID) {
                            ForEach(ActionRecorder.shared.sets.flatMap(\.actions)) { a in Text(tr(a.name)).tag(Optional(a.id)) }
                        }.labelsHidden().frame(width: 220)
                    }
                }
                HStack { Text("Copyright Info").frame(width: 90, alignment: .leading); TextField("", text: $s.copyright) }
                Toggle2(label: "Include ICC Profile", on: $s.includeICC)
                if !status.isEmpty { Text(tr(status)).font(Theme.fontSmall).foregroundStyle(Theme.textDim) }
            }
        }
    }

    @ViewBuilder func formatRow(_ title: String, _ o: Binding<ImageProcessorSettings.FormatOption>, quality: Bool) -> some View {
        HStack(spacing: 8) {
            Toggle(tr(title), isOn: o.enabled).toggleStyle(.checkbox).frame(width: 110, alignment: .leading)
            if quality {
                Text("Quality"); TextField("", value: Binding(get: { Int((o.wrappedValue.quality * 12).rounded()) }, set: { o.wrappedValue.quality = Double(max(0, min(12, $0))) / 12 }), format: .number).frame(width: 34)
            }
            Toggle("Resize to Fit", isOn: o.resize).toggleStyle(.checkbox)
            Text("W"); TextField("", value: o.width, format: .number.grouping(.never)).frame(width: 52)
            Text("H"); TextField("", value: o.height, format: .number.grouping(.never)).frame(width: 52)
            Text("px").foregroundStyle(Theme.textFaint)
        }
        .disabled(false)
    }

    func run() {
        guard s.useOpenImages || !s.sources.isEmpty else { AppActions.alert("Select images to process."); return }
        let r = ImageProcessor.run(s)
        AppModel.shared.setStatus("Image Processor: \(r.written.count) file(s) written" + (r.failed > 0 ? ", \(r.failed) failed." : "."))
    }
}
