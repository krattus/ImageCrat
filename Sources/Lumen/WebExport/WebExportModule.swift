import AppKit
@testable import LumenUltra
import SwiftUI
import CoreImage
import UniformTypeIdentifiers
import ImageCratCore

/// Web export module: Lumen Ultra PNG (lossless + Perceptual Ultra), "Smallest for Web" assistant, SVG export,
/// "Copy as Optimised PNG" and the "Use Ultra PNG when saving PNG" preference.
enum WebExportModule {
    static var headless: Bool { CommandLine.arguments.contains("--selftest") }

    static func register() {
        let hasDoc: () -> Bool = { AppModel.shared.activeDocument != nil }
        MenuRegistry.add("File", "Ultra PNG…", submenu: "Export", dividerBefore: true, enabled: hasDoc) { DialogRegistry.show("ultraPNG") }
        MenuRegistry.add("File", "Smallest for Web…", submenu: "Export", enabled: hasDoc) { DialogRegistry.show("smallestForWeb") }
        MenuRegistry.add("File", "SVG…", submenu: "Export", enabled: hasDoc) { DialogRegistry.show("svgExport") }
        MenuRegistry.add("File", "Ultra PNG on Save…", submenu: "Export") { DialogRegistry.show("ultraPNGPrefs") }
        MenuRegistry.add("Edit", "Copy as Optimised PNG", enabled: hasDoc) { WebExportActions.copyOptimisedPNG() }
        DialogRegistry.register("ultraPNG") {
            guard let d = AppModel.shared.activeDocument else { return AnyView(EmptyView()) }
            return AnyView(UltraPNGDialog(session: UltraPNGSession(document: d)))
        }
        DialogRegistry.register("smallestForWeb") {
            guard let d = AppModel.shared.activeDocument else { return AnyView(EmptyView()) }
            return AnyView(SmallestForWebDialog(session: SmallestForWebSession(document: d)))
        }
        DialogRegistry.register("svgExport") {
            guard let d = AppModel.shared.activeDocument else { return AnyView(EmptyView()) }
            return AnyView(SVGExportDialog(doc: d))
        }
        DialogRegistry.register("ultraPNGPrefs") { AnyView(UltraPNGPrefsDialog()) }
        DocumentIO.postExportHooks.append { url, format in WebExportActions.optimiseExportedPNG(url, format) }
        FeatureModules.selfTests.append(("webexport", { out in WebExportSelfTest.run(out) }))
        // `LUMEN_SELFTEST_ONLY=webexport Lumen --selftest <dir>` runs just this module and exits
        if headless, let only = ProcessInfo.processInfo.environment["LUMEN_SELFTEST_ONLY"], only.hasPrefix("webexport"),
           let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
            let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            WebExportSelfTest.run(out)
            print("done (webexport only)")
            exit(0)
        }
    }
}

/// Preferences of the module (UserDefaults; independent of the shared `Preferences` struct).
enum WebExportPrefs {
    private static let kOnSave = "LumenWebExport.ultraPNGOnSave"
    private static let kEffort = "LumenWebExport.onSaveEffort"
    private static let kLast = "LumenWebExport.lastSettings"

    /// PNG files written by Export As / Quick Export / Layers to Files are re-packed losslessly by Ultra PNG.
    static var ultraPNGOnSave: Bool {
        get { UserDefaults.standard.bool(forKey: kOnSave) }
        set { UserDefaults.standard.set(newValue, forKey: kOnSave) }
    }
    static var onSaveEffort: UPEffort {
        get { UPEffort(rawValue: UserDefaults.standard.object(forKey: kEffort) as? Int ?? 0) ?? .fast }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: kEffort) }
    }
    static var lastSettings: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: kLast) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: kLast) }
    }
}

/// Document → straight-alpha pixels for the encoders.
enum WXDoc {
    /// Composites the document. Pixel values are in the document profile; with `convertToSRGB` they are converted
    /// (browsers assume sRGB for untagged images), otherwise the profile travels along as `iccProfile`.
    static func image(_ st: DocumentState, scale: Double = 1, convertToSRGB: Bool = true, background: RGBA? = nil) -> UPImage? {
        let space = CanvasSpace(width: st.width, height: st.height)
        var ci = ImagingDisplay.inks(Compositor.shared.composite(st), state: st)
        if let bg = background { ci = ci.composited(over: CIImage.color(bg, space.ciCanvas)) }
        var rect = space.ciCanvas
        if abs(scale - 1) > 0.001 {
            ci = ci.cropped(to: rect).applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            rect = CGRect(x: 0, y: 0, width: max(1, Int(Double(st.width) * scale)), height: max(1, Int(Double(st.height) * scale)))
        }
        let deep = st.bitDepth != .eight
        guard var cg = RenderEngine.readbackContext.createCGImage(ci, from: rect, format: deep ? .RGBA16 : .RGBA8, colorSpace: sRGBSpace) else { return nil }
        var icc: Data? = nil
        let profile = ColorProfiles.space(named: st.profileName)
        if !ColorProfiles.isSRGB(st.profileName), profile.model == .rgb {
            if convertToSRGB {
                if let tagged = cg.copy(colorSpace: profile),
                   let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0, space: sRGBSpace,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0)) {
                    ctx.setBlendMode(.copy)
                    ctx.interpolationQuality = .none
                    ctx.draw(tagged, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                    if let c = ctx.makeImage() { cg = c }
                }
            } else {
                icc = profile.copyICCData() as Data?
            }
        }
        var img = UPBridge.rawDecode(cg) ?? UPBridge.render(cg)
        img.iccProfile = icc
        img.dpi = st.resolution
        return img
    }

    static func cgImage(_ img: UPImage) -> CGImage? { UPBridge.cgImage(img, space: UPBridge.srgb) }

    static func baseName(_ d: Document) -> String { (d.name as NSString).deletingPathExtension }
}

enum WebExportActions {
    /// Post-export hook: lossless Ultra re-pack of a PNG the normal exporter just wrote (when the preference is on).
    static func optimiseExportedPNG(_ url: URL, _ format: ExportFormat) {
        guard format == .png, WebExportPrefs.ultraPNGOnSave, let data = try? Data(contentsOf: url) else { return }
        guard let better = UPRecompress.optimise(data, effort: WebExportPrefs.onSaveEffort) else { return }
        do {
            try better.write(to: url, options: .atomic)
            if !WebExportModule.headless {
                AppModel.shared.setStatus("Ultra PNG: \(WXTransfer.bytes(data.count)) → \(WXTransfer.bytes(better.count)) (\(Int((1 - Double(better.count) / Double(data.count)) * 100))% smaller, lossless)")
            }
        } catch {}
    }

    /// Puts a losslessly optimised PNG of the visible document on the pasteboard.
    static func copyOptimisedPNG() {
        guard let d = AppModel.shared.activeDocument, let img = WXDoc.image(d.state) else { Beep.play(); return }
        AppModel.shared.setStatus("Optimising PNG…")
        DispatchQueue.global(qos: .userInitiated).async {
            var o = UPLosslessOptions()
            o.effort = .thorough
            o.ancillary.srgbIntent = 0
            let r = UPLossless.encode(img, options: o)
            DispatchQueue.main.async {
                guard let r else { AppModel.shared.setStatus("Could not optimise the image."); return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(r.data, forType: .png)
                AppModel.shared.setStatus("Copied optimised PNG: \(WXTransfer.bytes(r.data.count)) (\(r.representation))")
            }
        }
    }

    static func save(_ data: Data, suggested: String, type: UTType, done: ((URL) -> Void)? = nil) {
        let p = NSSavePanel()
        p.allowedContentTypes = [type]
        p.nameFieldStringValue = suggested
        p.begin { r in
            guard r == .OK, let url = p.url else { return }
            do { try data.write(to: url, options: .atomic); done?(url) } catch { AppActions.alert("Could not save.", error.localizedDescription) }
        }
    }
}

/// The row shown in Export As when the format is PNG.
struct WebExportExportAsRow: View {
    @State private var on = WebExportPrefs.ultraPNGOnSave
    @State private var effort = WebExportPrefs.onSaveEffort
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle2(label: "Use Ultra PNG when saving PNG (lossless, smaller)", on: $on)
                .onChange(of: on) { _, v in WebExportPrefs.ultraPNGOnSave = v }
            if on {
                Picker("Effort", selection: $effort) { ForEach(UPEffort.allCases) { Text(tr($0.title)).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 240)
                    .onChange(of: effort) { _, v in WebExportPrefs.onSaveEffort = v }
            }
        }
    }
}

struct UltraPNGPrefsDialog: View {
    var body: some View {
        DialogFrame(title: "Ultra PNG on Save", width: 400, okTitle: "Done", onOK: {}) {
            Text("When on, every PNG written by Export As, Quick Export and Layers to Files is re-packed by ImageCrat Ultra PNG. The pixels stay bit-identical; only the file gets smaller. Metadata chunks are kept.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            WebExportExportAsRow()
            Text("For lossy “Perceptual Ultra” and live previews use File ▸ Export ▸ Ultra PNG…").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
    }
}
