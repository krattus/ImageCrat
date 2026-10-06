import Foundation
import ImageCratCore
import ImageCratWinSupport
#if os(Windows)
import WinSDK
#endif

// imagecrat-cli: command-line companion of ImageCrat Preview (technical preview for Windows).

#if os(Windows)
_ = SetConsoleOutputCP(65001)   // UTF-8 (×, —, layer names)
#endif

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let usage = """
\(BuildInfo.versionLine)

Usage:
  imagecrat-cli selfcheck                     run the built-in checks (exit code 0 = all passed, 1 = a failure)
  imagecrat-cli info <file>                   document info and the layer tree (.psd/.psb), image or brush info
  imagecrat-cli composite <psd> <out.png>     write the composite stored in a PSD/PSB (or a PNG) as PNG
  imagecrat-cli brushes <file> <outdir>       write every brush tip of .abr/.gbr/.gih/.brush/.brushset/.kpp/.icbrushes as PNG
  imagecrat-cli make-samples <dir>            write synthetic test files (brushes, PSDs, PNGs)
  imagecrat-cli --version

\(BuildInfo.licence) — \(BuildInfo.website)
"""

func fileName(_ s: String) -> String {
    let bad = Set("<>:\"/\\|?*")
    let t = String(s.map { bad.contains($0) || $0.asciiValue.map { $0 < 32 } == true ? "_" : $0 }).trimmingCharacters(in: .whitespaces)
    return t.isEmpty ? "brush" : String(t.prefix(80))
}

func load(_ path: String) -> LoadedFile? {
    do { return try FileLoader.load(URL(fileURLWithPath: path)) } catch {
        eprint("error: \(path): \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        return nil
    }
}

func run(_ args: [String]) -> Int32 {
    guard let cmd = args.first else { print(usage); return 2 }
    switch cmd {
    case "--version", "-v", "version":
        print(BuildInfo.versionLine)
        return 0
    case "help", "--help", "-h", "/?":
        print(usage)
        return 0
    case "selfcheck":
        let results = SelfCheck.run { i, n, name in eprint("[\(i + 1)/\(n)] \(name)") }
        print(SelfCheck.report(results))
        return results.allSatisfy(\.passed) ? 0 : 1
    case "info":
        guard args.count == 2 else { eprint("usage: imagecrat-cli info <file>"); return 2 }
        guard let f = load(args[1]) else { return 1 }
        print(f.summary)
        return 0
    case "composite":
        guard args.count == 3 else { eprint("usage: imagecrat-cli composite <psd> <out.png>"); return 2 }
        guard let f = load(args[1]) else { return 1 }
        guard let pic = f.picture else {
            if case .psd(_, _, let err) = f.content { eprint("error: no composite: \(err ?? "unknown")") } else { eprint("error: \(f.displayName) has no single picture (brush file?)") }
            return 1
        }
        do {
            try PNGCodec.encode(pic.pixelBuffer()).write(to: URL(fileURLWithPath: args[2]))
            print("wrote \(args[2]) (\(pic.width) × \(pic.height) px)")
            return 0
        } catch { eprint("error: can't write \(args[2]): \(error.localizedDescription)"); return 1 }
    case "brushes":
        guard args.count == 3 else { eprint("usage: imagecrat-cli brushes <file> <outdir>"); return 2 }
        guard let f = load(args[1]) else { return 1 }
        guard case .brushes(let set, let tips) = f.content else { eprint("error: \(f.displayName) is not a brush file"); return 1 }
        let dir = URL(fileURLWithPath: args[2], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let full = FileLoader.tipPreviews(set, maxSide: 4096)
            for (i, t) in full.enumerated() {
                let name = String(format: "%03d ", i + 1) + fileName(t.name) + ".png"
                try PNGCodec.encode(t.image.pixelBuffer()).write(to: dir.appendingPathComponent(name))
                print("\(name)  (\(t.detail))")
            }
            print("wrote \(tips.count) tip\(tips.count == 1 ? "" : "s") of “\(set.name)” to \(dir.path)")
            return 0
        } catch { eprint("error: \(error.localizedDescription)"); return 1 }
    case "make-samples":
        guard args.count == 2 else { eprint("usage: imagecrat-cli make-samples <dir>"); return 2 }
        do {
            let names = try SampleFiles.writeAll(to: URL(fileURLWithPath: args[1], isDirectory: true))
            for n in names { print(n) }
            return 0
        } catch { eprint("error: \(error.localizedDescription)"); return 1 }
    default:
        eprint("unknown command: \(cmd)\n")
        eprint(usage)
        return 2
    }
}

exit(run(Array(CommandLine.arguments.dropFirst())))
