import AppKit
import SwiftUI
import Observation
import ImageCratCore

// MARK: - Storage locations

/// Everything Workflow2 writes at runtime lives under `~/Library/Application Support/ImageCrat`
/// (or `$LUMEN_SUPPORT_DIR`). Command-line runs (self test, droplets) never touch the real folder.
enum Workflow2Paths {
    /// Tests point this at a temp directory.
    static var overrideRoot: URL?

    private static let headlessRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumen-workflow2-\(ProcessInfo.processInfo.processIdentifier)")

    static var root: URL {
        if let o = overrideRoot { return o }
        if let o = ProcessInfo.processInfo.environment["LUMEN_SUPPORT_DIR"], !o.isEmpty { return URL(fileURLWithPath: o) }
        if FilesModule.headless { return headlessRoot }
        return Brand.supportFolder
    }

    /// Subfolder of the support directory (created on demand).
    static func dir(_ name: String) -> URL {
        let u = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func file(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(name)
    }

    /// Removes the throwaway folder used by command-line runs.
    static func removeHeadlessRoot() { try? FileManager.default.removeItem(at: headlessRoot) }
}

// MARK: - Preferences

struct Workflow2Prefs: Codable, Equatable {
    // Autosave & recovery
    var autosaveEnabled = true
    var autosaveMinutes: Double = 5
    var autosaveOnDeactivate = true
    /// Recovery copies kept per document.
    var autosaveKeep = 2
    // Process timelapse
    /// Start recording automatically for every new / opened document.
    var timelapseAuto = false
    var timelapseMaxDimension = 1280
    /// Minimum seconds between captured frames.
    var timelapseMinInterval: Double = 2
    /// Per-document cap for stored frames (megabytes).
    var timelapseCapMB = 250
    // History tree
    var maxBranches = 16
    /// Memory that kept branches may hold beyond what the live history already holds (megabytes).
    var branchMemoryMB = 1024
    // Preflight
    var preflightMinTextPx: Double = 8
    var preflightMinPPI: Double = 150
    var preflightLargeEmbedMB: Double = 8

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Workflow2Prefs()
        autosaveEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .autosaveEnabled)) ?? d.autosaveEnabled
        autosaveMinutes = (try? c.decodeIfPresent(Double.self, forKey: .autosaveMinutes)) ?? d.autosaveMinutes
        autosaveOnDeactivate = (try? c.decodeIfPresent(Bool.self, forKey: .autosaveOnDeactivate)) ?? d.autosaveOnDeactivate
        autosaveKeep = (try? c.decodeIfPresent(Int.self, forKey: .autosaveKeep)) ?? d.autosaveKeep
        timelapseAuto = (try? c.decodeIfPresent(Bool.self, forKey: .timelapseAuto)) ?? d.timelapseAuto
        timelapseMaxDimension = (try? c.decodeIfPresent(Int.self, forKey: .timelapseMaxDimension)) ?? d.timelapseMaxDimension
        timelapseMinInterval = (try? c.decodeIfPresent(Double.self, forKey: .timelapseMinInterval)) ?? d.timelapseMinInterval
        timelapseCapMB = (try? c.decodeIfPresent(Int.self, forKey: .timelapseCapMB)) ?? d.timelapseCapMB
        maxBranches = (try? c.decodeIfPresent(Int.self, forKey: .maxBranches)) ?? d.maxBranches
        branchMemoryMB = (try? c.decodeIfPresent(Int.self, forKey: .branchMemoryMB)) ?? d.branchMemoryMB
        preflightMinTextPx = (try? c.decodeIfPresent(Double.self, forKey: .preflightMinTextPx)) ?? d.preflightMinTextPx
        preflightMinPPI = (try? c.decodeIfPresent(Double.self, forKey: .preflightMinPPI)) ?? d.preflightMinPPI
        preflightLargeEmbedMB = (try? c.decodeIfPresent(Double.self, forKey: .preflightLargeEmbedMB)) ?? d.preflightLargeEmbedMB
    }
}

@Observable
final class Workflow2Settings {
    static let shared = Workflow2Settings()

    var prefs: Workflow2Prefs { didSet { if prefs != oldValue { save() } } }

    private static var url: URL { Workflow2Paths.file("workflow2-prefs.json") }

    private init() { prefs = Workflow2Settings.read() }

    private static func read() -> Workflow2Prefs {
        let u = Workflow2Paths.root.appendingPathComponent("workflow2-prefs.json")
        guard let d = try? Data(contentsOf: u), let p = try? JSONDecoder().decode(Workflow2Prefs.self, from: d) else { return Workflow2Prefs() }
        return p
    }

    /// Re-reads the file (tests switch the support directory).
    func reload() { prefs = Workflow2Settings.read() }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(prefs) { try? d.write(to: Workflow2Settings.url, options: .atomic) }
    }
}

/// Lets the palette open Preferences on a given section.
enum Workflow2PrefsState {
    static var pendingSection: String?
    static func initialSection() -> String? {
        defer { pendingSection = nil }
        return pendingSection
    }
    static let sections = ["General", "Interface", "Artboards", "Cursors", "Tablet", "Transparency & Guides", "Units", "Performance", "Workflow", "Radial Menu", "Generative AI", "AI Models"]
    static func open(_ section: String) {
        pendingSection = section
        AppModel.shared.dialog = nil
        DispatchQueue.main.async { AppModel.shared.dialog = .preferences }
    }
}

/// Preferences ▸ Workflow.
struct Workflow2PrefsSection: View {
    @Bindable var s = Workflow2Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Autosave & Recovery")
            Toggle2(label: "Automatically save recovery information", on: $s.prefs.autosaveEnabled)
            ValueSlider(label: "Every", value: $s.prefs.autosaveMinutes, range: 1...60, step: 1, unit: " min", labelWidth: 110)
                .disabled(!s.prefs.autosaveEnabled)
            Toggle2(label: "Also when ImageCrat goes to the background", on: $s.prefs.autosaveOnDeactivate)
                .disabled(!s.prefs.autosaveEnabled)
            ValueSlider(label: "Copies to Keep", value: Binding(get: { Double(s.prefs.autosaveKeep) }, set: { s.prefs.autosaveKeep = max(1, Int($0)) }),
                        range: 1...10, step: 1, labelWidth: 110)
            Caption("Process Timelapse").padding(.top, 6)
            Toggle2(label: "Record a timelapse for every document", on: $s.prefs.timelapseAuto)
            ValueSlider(label: "Frame Size", value: Binding(get: { Double(s.prefs.timelapseMaxDimension) }, set: { s.prefs.timelapseMaxDimension = Int($0) }),
                        range: 480...3840, step: 80, unit: " px", labelWidth: 110)
            ValueSlider(label: "Min. Interval", value: $s.prefs.timelapseMinInterval, range: 0...30, step: 0.5, unit: " s", format: "%.1f", labelWidth: 110)
            ValueSlider(label: "Storage Cap", value: Binding(get: { Double(s.prefs.timelapseCapMB) }, set: { s.prefs.timelapseCapMB = Int($0) }),
                        range: 50...4000, step: 50, unit: " MB", labelWidth: 110)
            Caption("History Tree & Preflight").padding(.top, 6)
            ValueSlider(label: "Branches Kept", value: Binding(get: { Double(s.prefs.maxBranches) }, set: { s.prefs.maxBranches = max(1, Int($0)) }),
                        range: 1...64, step: 1, labelWidth: 110)
            ValueSlider(label: "Branch Memory", value: Binding(get: { Double(s.prefs.branchMemoryMB) }, set: { s.prefs.branchMemoryMB = max(64, Int($0)) }),
                        range: 128...8192, step: 128, unit: " MB", labelWidth: 110)
            ValueSlider(label: "Smallest Text", value: $s.prefs.preflightMinTextPx, range: 4...24, step: 1, unit: " px", labelWidth: 110)
            ValueSlider(label: "Min. Resolution", value: $s.prefs.preflightMinPPI, range: 36...600, step: 1, unit: " ppi", labelWidth: 110)
            Text("Recovery files and timelapse frames are stored in \(Workflow2Paths.root.path).")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Small shared helpers

extension View {
    /// Text field look that matches the app's dark fields.
    func w2Field() -> some View {
        self.textFieldStyle(.plain).font(Theme.font)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 0.5))
    }
}

enum Workflow2Util {
    static func byteString(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(n))
    }

    static func relativeTime(_ d: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(d)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }

    static func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }

    /// Composite of a state scaled to fit `maxSide` pixels, as CGImage.
    static func thumbnail(_ st: DocumentState, maxSide: CGFloat, background: RGBA? = nil) -> CGImage? {
        let sp = CanvasSpace(width: st.width, height: st.height)
        let s = min(1, maxSide / CGFloat(max(st.width, st.height)))
        var img = Compositor.shared.composite(st).cropped(to: sp.ciCanvas)
        if let bg = background { img = img.composited(over: CIImage.color(bg, sp.ciCanvas)) }
        let w = max(1, (CGFloat(st.width) * s).rounded()), h = max(1, (CGFloat(st.height) * s).rounded())
        let scaled = img.transformed(by: CGAffineTransform(scaleX: w / CGFloat(st.width), y: h / CGFloat(st.height)), highQualityDownsample: true)
        return RenderEngine.readbackContext.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: sRGBSpace)
    }

    static func pngData(_ cg: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    static func image(fromPNG data: Data?) -> NSImage? {
        guard let data, let img = NSImage(data: data) else { return nil }
        return img
    }

    /// Mean absolute difference (0…255) between the composites of two states (same size) — used by tests and "identical" checks.
    static func compositeDifference(_ a: DocumentState, _ b: DocumentState) -> Double {
        guard a.width == b.width, a.height == b.height else { return 255 }
        let sp = CanvasSpace(width: a.width, height: a.height)
        let ba = RenderEngine.renderBuffer(Compositor.shared.composite(a), docRect: a.canvasRect, space: sp)
        let bb = RenderEngine.renderBuffer(Compositor.shared.composite(b), docRect: b.canvasRect, space: sp)
        return bufferDifference(ba, bb)
    }

    static func bufferDifference(_ a: PixelBuffer, _ b: PixelBuffer) -> Double {
        guard a.width == b.width, a.height == b.height, a.format == b.format else { return 255 }
        let pa = a.data.assumingMemoryBound(to: UInt8.self), pb = b.data.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        let rb = a.width * a.bytesPerPixel
        for y in 0..<a.height {
            let oa = y * a.bytesPerRow, ob = y * b.bytesPerRow
            for x in 0..<rb { sum += abs(Int(pa[oa + x]) - Int(pb[ob + x])) }
        }
        return Double(sum) / Double(max(1, rb * a.height))
    }
}
