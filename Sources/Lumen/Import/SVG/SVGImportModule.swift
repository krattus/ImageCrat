import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageCratCore

/// SVG import module: File ▸ Open / Place / Replace Contents for .svg and .svgz, pasting SVG markup, the import
/// dialog and the import report.
enum SVGImportModule {
    static func register() {
        DocumentIO.customLoaders["svg"] = { try SVGImportUI.open(url: $0) }
        DocumentIO.customLoaders["svgz"] = { try SVGImportUI.open(url: $0) }
        // appended (FilesModule assigns the list, so this module registers after it)
        for t in [UTType.svg, UTType(filenameExtension: "svgz")].compactMap({ $0 }) where !DocumentIO.extraOpenTypes.contains(t) {
            DocumentIO.extraOpenTypes.append(t)
        }
        MenuRegistry.add("File", "SVG Import Report…", submenu: "Import", enabled: { SVGImportReports.current != nil }) { DialogRegistry.show("svgImportReport") }
        DialogRegistry.register("svgImportReport") { AnyView(SVGImportReportDialog()) }
        // the report travels with the document when it is saved as .lumen
        DocumentIO.nativeExtrasWriters["svgimport"] = { d in SVGImportReports.reports[d.id].flatMap { try? JSONEncoder().encode($0) } }
        DocumentIO.nativeExtrasReaders["svgimport"] = { d, data in
            if let r = try? JSONDecoder().decode(SVGImportReport.self, from: data) { SVGImportReports.reports[d.id] = r }
        }
        FeatureModules.selfTests.append(("svgimport", { out in SVGImportSelfTest.run(out) }))
        // development shortcut: `LUMEN_SVGIMPORT_DIRECT=1 Lumen --selftest <dir>` runs this suite alone, skipping the core tests
        let args = CommandLine.arguments
        if ProcessInfo.processInfo.environment["LUMEN_SVGIMPORT_DIRECT"] == "1", let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            _ = NSApplication.shared       // modules register before the application object exists
            SVGImportSelfTest.run(URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
    }
}

/// Reports of imported documents (by document id) for File ▸ Import ▸ SVG Import Report.
enum SVGImportReports {
    static var reports: [UUID: SVGImportReport] = [:]
    /// The most recent import, whatever it went into (placed and pasted SVGs have no document of their own).
    static var last: SVGImportReport?

    /// Report of the active document, else of the last placed / pasted SVG.
    static var current: SVGImportReport? {
        if let d = AppModel.shared.activeDocument, let r = reports[d.id] { return r }
        return last
    }

    static func attach(_ r: SVGImportReport, to d: Document?) {
        last = r
        if let d { reports[d.id] = r }
        if reports.count > 64 {
            let open = Set(AppModel.shared.documents.map(\.id))
            reports = reports.filter { open.contains($0.key) || $0.key == d?.id }
        }
    }
}

enum SVGImportUI {
    /// No person to answer a dialog: command-line runs, self tests and scripted UI.
    static var unattended: Bool {
        FilesModule.headless || Automation.isHeadless || CommandLine.arguments.contains("--perftest") || NSApp == nil
    }

    /// Settings used when the import dialog is not shown (tests may change them).
    static var defaultSettings = SVGImportSettings()

    /// Loader hook for File ▸ Open (import dialog) and for Place / Replace Contents / linked reloads (no dialog: the
    /// smart object is sized on the canvas).
    static func open(url: URL) throws -> Document {
        guard let data = try? Data(contentsOf: url) else { throw SVGImportError.unreadable }
        let doc = try SVGImportXML.parse(data, baseURL: url.deletingLastPathComponent())
        var settings = defaultSettings
        let placing = DocumentIO.placing
        // a placed SVG arrives at its own size: the smart object re-renders from the vectors when it is enlarged
        if placing { settings.minimumSide = 0 }
        if !placing && !unattended {
            guard let s = SVGImportDialog.run(natural: SVGImport.naturalSize(doc), name: url.lastPathComponent, initial: settings) else { throw CocoaError(.userCancelled) }
            settings = s
        }
        let result = SVGImport.load(doc, name: url.lastPathComponent, settings: settings)
        let d = Document(state: result.state, name: url.lastPathComponent)
        d.fileURL = url
        SVGImportReports.attach(result.report, to: placing ? nil : d)
        announce(result.report)
        return d
    }

    static func announce(_ r: SVGImportReport) {
        AppModel.shared.setStatus(r.summary + (r.hasFindings ? " Details: File ▸ Import ▸ SVG Import Report." : ""))
    }

    // MARK: Paste

    private static let svgTypes = ["public.svg-image", "image/svg+xml", "com.adobe.svg", "Scalable Vector Graphics", "org.inkscape.output.svg.plain"]

    /// SVG markup on the pasteboard: a typed SVG flavour (Illustrator, Sketch, Inkscape) or plain text that is an SVG
    /// document (Figma's "Copy as SVG").
    static func svgData(on pb: NSPasteboard) -> Data? {
        for t in svgTypes {
            if let d = pb.data(forType: NSPasteboard.PasteboardType(t)), d.count > 10, d.count < SVGImportXML.maxBytes { return d }
        }
        if let s = pb.string(forType: .string), s.utf8.count < 64 << 20, SVGImport.looksLikeSVG(s) { return Data(s.utf8) }
        return nil
    }

    /// Hook in `AppActions.paste`: pasted SVG becomes a smart object holding the editable artwork (or a new document
    /// when none is open), like Place Embedded.
    static func handlePaste(_ pb: NSPasteboard) -> Bool {
        // a copy made inside Lumen after the SVG was put on the pasteboard wins
        if let c = AppActions.clipboard, c.changeCount == pb.changeCount { return false }
        var settings = defaultSettings
        if AppActions.doc != nil { settings.minimumSide = 0 }      // placed at its own size, like Place Embedded
        guard let data = svgData(on: pb), let result = try? SVGImport.load(data: data, name: "Pasted SVG", settings: settings) else { return false }
        if AppActions.doc == nil {
            let d = Document(state: result.state, name: "Pasted SVG")
            AppModel.shared.add(d)
            SVGImportReports.attach(result.report, to: d)
        } else {
            AppActions.canvas?.commitCurrentTool()
            if result.state.layers.count == 1, let r = result.state.layers[0].raster, result.report.flattened { AppActions.placeBuffer(r.buffer, name: "Pasted SVG") }
            else { AppActions.placeDocumentState(result.state, name: "Pasted SVG") }
            SVGImportReports.attach(result.report, to: nil)
        }
        announce(result.report)
        return true
    }
}

// MARK: - Import dialog

final class SVGImportDialogModel: ObservableObject {
    let natural: CGSize
    @Published var width: Double
    @Published var height: Double
    @Published var lock = true
    @Published var mode: SVGImportSettings.Mode
    @Published var white: Bool
    @Published var hidden: Bool

    init(natural: CGSize, initial: SVGImportSettings) {
        self.natural = natural
        let d = SVGImport.defaultPixelSize(natural, minimumSide: initial.minimumSide)
        width = Double(initial.width ?? d.0)
        height = Double(initial.height ?? d.1)
        mode = initial.mode
        white = initial.whiteBackground
        hidden = initial.includeHidden
    }

    var aspect: Double { Double(natural.width / natural.height) }

    func setWidth(_ w: Double) {
        width = clamp(w.rounded(), 1, Double(SVGImport.maxSide))
        if lock { height = clamp((width / aspect).rounded(), 1, Double(SVGImport.maxSide)) }
    }
    func setHeight(_ h: Double) {
        height = clamp(h.rounded(), 1, Double(SVGImport.maxSide))
        if lock { width = clamp((height * aspect).rounded(), 1, Double(SVGImport.maxSide)) }
    }
    func setScale(_ k: Double) {
        lock = true
        width = clamp((Double(natural.width) * k).rounded(), 1, Double(SVGImport.maxSide))
        height = clamp((Double(natural.height) * k).rounded(), 1, Double(SVGImport.maxSide))
    }
    var scaleLabel: String {
        let k = width / Double(natural.width)
        return String(format: abs(k - k.rounded()) < 0.005 ? "%.0f×" : "%.2f×", k)
    }

    var settings: SVGImportSettings {
        var s = SVGImportSettings()
        s.width = Int(clamp(width, 1, Double(SVGImport.maxSide)))
        s.height = Int(clamp(height, 1, Double(SVGImport.maxSide)))
        s.mode = mode
        s.whiteBackground = white
        s.includeHidden = hidden
        return s
    }
}

struct SVGImportDialogView: View {
    @ObservedObject var m: SVGImportDialogModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Width:").frame(width: 56, alignment: .leading)
                TextField("", value: Binding(get: { m.width }, set: { m.setWidth($0) }), format: .number.precision(.fractionLength(0))).frame(width: 70)
                Text("px")
                Button(action: { m.lock.toggle(); if m.lock { m.setWidth(m.width) } }) {
                    Image(systemName: m.lock ? "lock.fill" : "lock.open")
                }.buttonStyle(.borderless).help("Keep the proportions of the artwork")
                Spacer()
                Text(m.scaleLabel).foregroundStyle(.secondary).font(.system(size: 11))
            }
            HStack(spacing: 6) {
                Text("Height:").frame(width: 56, alignment: .leading)
                TextField("", value: Binding(get: { m.height }, set: { m.setHeight($0) }), format: .number.precision(.fractionLength(0))).frame(width: 70)
                Text("px")
                Spacer()
                ForEach([1.0, 2, 4, 8], id: \.self) { k in
                    Button(String(format: "%.0f×", k)) { m.setScale(k) }.controlSize(.small)
                }
            }
            Picker("Import as:", selection: $m.mode) {
                ForEach(SVGImportSettings.Mode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.radioGroup)
            Picker("Background:", selection: $m.white) {
                Text("Transparent").tag(false)
                Text("White").tag(true)
            }.pickerStyle(.radioGroup).horizontalRadioGroupLayout()
            Toggle("Import hidden elements as hidden layers", isOn: $m.hidden).disabled(m.mode == .flattened)
            Text(m.mode == .editable
                 ? "Shapes, text and groups stay editable. Anything ImageCrat cannot represent is rasterized at this size and listed in File ▸ Import ▸ SVG Import Report."
                 : "The whole image is rendered into one pixel layer at this size.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 360)
        .padding(4)
    }
}

enum SVGImportDialog {
    static func run(natural: CGSize, name: String, initial: SVGImportSettings) -> SVGImportSettings? {
        let m = SVGImportDialogModel(natural: natural, initial: initial)
        let a = NSAlert()
        a.messageText = "Import SVG"
        let w = (Double(natural.width) * 100).rounded() / 100, h = (Double(natural.height) * 100).rounded() / 100
        a.informativeText = "\(name) — \(w == w.rounded() ? String(Int(w)) : String(w)) × \(h == h.rounded() ? String(Int(h)) : String(h)) px at 1×. SVG has no fixed pixel size: choose the size of the document."
        let host = NSHostingView(rootView: SVGImportDialogView(m: m))
        host.frame = NSRect(x: 0, y: 0, width: 372, height: 236)
        a.accessoryView = host
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        guard UIBlock.run(a) == .alertFirstButtonReturn else { return nil }
        return m.settings
    }
}

// MARK: - Report dialog

struct SVGImportReportDialog: View {
    var body: some View {
        let text = SVGImportReports.current?.text ?? "No SVG has been imported."
        DialogFrame(title: "SVG Import Report", width: 520, okTitle: "Done", onOK: {},
                    extraButtons: AnyView(Button("Copy") {
                        AppActions.pasteboard.clearContents()
                        AppActions.pasteboard.setString(text, forType: .string)
                    }.buttonStyle(PanelButtonStyle()))) {
            ScrollView {
                Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            .frame(height: 320)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.15)))
        }
    }
}

// MARK: - Vector-sharp smart objects

/// A smart object whose source is a document re-renders that document at the size it is shown at when it is scaled
/// up, instead of enlarging its 1:1 pixels — shapes and text inside stay sharp (placed SVG, PDF and .lumen artwork).
enum SmartVectorScale {
    static func hasVector(_ layers: [Layer]) -> Bool {
        layers.contains { l in
            guard l.isVisible else { return false }
            switch l.content {
            case .shape, .text: return true
            case .group(let g): return hasVector(g.children)
            case .smartObject(let so): if case .document(let d) = so.source { return hasVector(d.layers) }; return false
            default: return false
            }
        }
    }

    /// Factor the quad enlarges the source by (1 = shown at its own size).
    static func enlargement(_ size: CGSize, _ quad: Quad) -> Double {
        guard size.width > 0, size.height > 0 else { return 1 }
        let kx = Double(max(quad.tl.distance(to: quad.tr), quad.bl.distance(to: quad.br)) / size.width)
        let ky = Double(max(quad.tl.distance(to: quad.bl), quad.tr.distance(to: quad.br)) / size.height)
        return max(kx, ky)
    }

    static func scaled(_ st: DocumentState, by k: Double) -> DocumentState {
        var out = st
        out.width = max(1, Int((Double(st.width) * k).rounded()))
        out.height = max(1, Int((Double(st.height) * k).rounded()))
        let sx = CGFloat(out.width) / CGFloat(st.width), sy = CGFloat(out.height) / CGFloat(st.height)
        let sp = CanvasSpace(width: out.width, height: out.height)
        let h = Homography(affine: CGAffineTransform(scaleX: sx, y: sy))
        out.layers = st.layers.map { LayerTransformer.apply(h, to: $0, space: sp, scaleEffects: k, document: true) }
        out.selection = nil
        return out
    }

    /// The source composited at the enlarged size, or nil to use the 1:1 composite (not enlarged, nothing vector
    /// inside, or too large to be worth it).
    static func image(_ st: DocumentState, quad: Quad, composite: (DocumentState) -> CIImage) -> CIImage? {
        var k = enlargement(CGSize(width: st.width, height: st.height), quad)
        guard k > 1.05, k.isFinite, hasVector(st.layers) else { return nil }
        let side = Double(max(st.width, st.height)), area = Double(st.width * st.height)
        k = min(k, 16384 / side, (64_000_000 / area).squareRoot())
        guard k > 1.05 else { return nil }
        return composite(scaled(st, by: k))
    }
}
