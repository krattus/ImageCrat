import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import ImageCratCore

/// How a PDF / Illustrator page is brought in.
enum PDFImportMode: String, CaseIterable {
    /// Shape, text and image layers in groups, with pixels only where there is no layer equivalent.
    case editable
    /// One pixel layer per page.
    case flattened
}

enum PDFVectorError: LocalizedError {
    case noPDFContent(String)
    case legacyIllustrator(String)
    case eps(String)
    case encrypted(String)
    case damaged(String)
    case emptyPage(String)

    var errorDescription: String? {
        switch self {
        case .noPDFContent(let n):
            return "“\(n)” was saved without PDF content, so it holds no artwork ImageCrat can read (only a notice page). In Illustrator choose File ▸ Save As and turn on “Create PDF Compatible File”, then open the new file."
        case .legacyIllustrator(let n):
            return "“\(n)” is a PostScript-based Illustrator file (Illustrator 8 or earlier, or saved for one of those versions). ImageCrat reads Illustrator files through their PDF content, and macOS no longer converts PostScript. Open it in Illustrator and choose File ▸ Save As with “Create PDF Compatible File” turned on, or export it as PDF."
        case .eps(let n):
            return "“\(n)” is an EPS (PostScript) file, which macOS can no longer convert. Open it in Illustrator or another app that reads EPS and save it as PDF, or as an Illustrator file with “Create PDF Compatible File” turned on."
        case .encrypted(let n):
            return "“\(n)” is password-protected. Open it with File ▸ Open to enter the password."
        case .damaged(let n):
            return "“\(n)” could not be read: it is damaged or not a PDF document."
        case .emptyPage(let n):
            return "“\(n)” has no page with a usable size."
        }
    }
}

/// Editable import of PDF and Illustrator files.
enum PDFVectorImport {
    // MARK: File checks

    static let illustratorExtensions: Set<String> = ["ai", "ait"]

    static func isIllustrator(_ url: URL) -> Bool { illustratorExtensions.contains(url.pathExtension.lowercased()) }

    /// Throws a message the user can act on for files that are not PDF inside (legacy Illustrator, EPS, damaged).
    static func checkFile(_ url: URL) throws {
        let name = url.lastPathComponent
        guard let h = try? FileHandle(forReadingFrom: url) else { throw DocumentIOError.unreadable }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 1024)) ?? Data()
        if head.range(of: Data("%PDF-".utf8)) != nil { return }
        if head.starts(with: [0xC5, 0xD0, 0xD3, 0xC6]) { throw PDFVectorError.eps(name) }
        if head.range(of: Data("%!PS-Adobe".utf8)) != nil {
            let ext = url.pathExtension.lowercased()
            if ext == "eps" || ext == "epsf" || (head.range(of: Data("EPSF".utf8)) != nil && !isIllustrator(url)) { throw PDFVectorError.eps(name) }
            throw PDFVectorError.legacyIllustrator(name)
        }
        throw PDFVectorError.damaged(name)
    }

    /// An Illustrator file saved without "Create PDF Compatible File" holds one page that says so.
    static func isPlaceholder(_ pdf: PDFDocument) -> Bool {
        guard pdf.pageCount == 1, let raw = pdf.page(at: 0)?.string, raw.count < 8000 else { return false }
        // PDFKit returns the notice's lines in its own order, with line breaks in the middle of the phrases
        let text = raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " }).joined(separator: " ")
        return text.contains("saved without PDF Content") || (text.contains("Illustrator") && text.contains("Compatible File") && text.contains("Save As"))
    }

    // MARK: Geometry

    struct Geometry {
        /// Page space (points, y up) → document pixels (y down).
        var pageToDoc: CGAffineTransform
        var width: Int
        var height: Int
        /// Pixels per inch actually used (lower than requested for very large pages).
        var resolution: Double
    }

    /// Same framing as `PDFImport.rasterize` (PDFKit's `draw(with:to:)`): the chosen box at the origin, the page's
    /// /Rotate applied, `resolution / 72` pixels per point.
    static func geometry(_ page: PDFPage, box: PDFDisplayBox, resolution: Double, options: PDFVectorOptions) -> Geometry? {
        let b = page.bounds(for: box)
        guard b.width.isFinite, b.height.isFinite, b.width > 0, b.height > 0 else { return nil }
        let rot = ((page.rotation % 360) + 360) % 360
        let quarter = rot == 90 || rot == 270
        let pw = quarter ? b.height : b.width, ph = quarter ? b.width : b.height
        var res = max(1, min(4800, resolution))
        // keep huge pages within what a document can hold
        let limit = min(Double(options.maxDimension) / Double(max(pw, ph)), (Double(options.maxPixels) / Double(pw * ph)).squareRoot()) * 72
        if res > limit { res = limit }
        guard res.isFinite, res > 0 else { return nil }
        let s = CGFloat(res / 72)
        let wd = (pw * s).rounded(), hd = (ph * s).rounded()
        guard wd.isFinite, hd.isFinite, wd >= 1, hd >= 1, wd <= 1_000_000, hd <= 1_000_000 else { return nil }
        let w = Int(wd), h = Int(hd)
        var t = CGAffineTransform(translationX: -b.minX, y: -b.minY)
        switch rot {
        case 90: t = t.concatenating(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: b.width))
        case 180: t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: b.width, ty: b.height))
        case 270: t = t.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: b.height, ty: 0))
        default: break
        }
        t = t.concatenating(CGAffineTransform(scaleX: s, y: s)).concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(h)))
        return Geometry(pageToDoc: t, width: w, height: h, resolution: res)
    }

    // MARK: Pages

    /// Imports one page as editable layers. Never fails: a page that cannot be followed comes back flattened, with
    /// the reason in the report.
    static func state(page: PDFPage, in pdf: PDFDocument, box: PDFDisplayBox = .cropBox, resolution: Double = 150, white: Bool = false,
                      options: PDFVectorOptions = PDFVectorOptions()) -> (DocumentState, PDFVectorReport)? {
        let start = Date()
        guard let geo = geometry(page, box: box, resolution: resolution, options: options) else { return nil }
        var report = PDFVectorReport()
        report.page = (pdf.index(for: page)) + 1
        if geo.resolution < resolution - 0.01 {
            report.note("The page is very large: it was imported at \(Int(geo.resolution)) ppi instead of \(Int(resolution)) ppi.")
        }
        var st = DocumentState(width: geo.width, height: geo.height, resolution: geo.resolution)
        var layers: [Layer]? = nil
        if let doc = pdf.documentRef, let ref = page.pageRef {
            let interp = PDFVectorInterpreter(document: doc, page: ref, pageToDoc: geo.pageToDoc, width: geo.width, height: geo.height)
            interp.limits.maxItems = max(1, options.maxLayers)
            interp.includeAnnotations = options.annotations
            interp.report = report
            do {
                try interp.run()
                let builder = PDFVectorBuilder(interp, options: options)
                layers = try builder.build()
                report = builder.report
            } catch PDFVectorInterpreter.Abort.limit(let why) {
                report = interp.report
                report.note("Imported flattened because \(why).")
            } catch {
                report = interp.report
                report.note("Imported flattened because the page could not be interpreted.")
            }
        } else {
            report.note("Imported flattened because the page could not be interpreted.")
        }
        if let layers {
            st.layers = layers
        } else {
            // the safety net: the page as PDFKit draws it
            report.flattened = true
            guard let cg = PDFImport.rasterize(page, resolution: geo.resolution, box: box) else { return nil }
            st = DocumentState(width: cg.width, height: cg.height, resolution: geo.resolution)
            st.layers = [Layer.raster(name: "Page \(report.page)", buffer: PixelBuffer(cgImage: cg))]
        }
        if white {
            let bg = PixelBuffer(width: st.width, height: st.height)
            bg.context.setFillColor(RGBA.white.cgColor)
            bg.context.fill(CGRect(x: 0, y: 0, width: st.width, height: st.height))
            bg.markDirty()
            st.layers.insert(Layer.raster(name: "Background", buffer: bg), at: 0)
        }
        if st.layers.isEmpty { st.layers = [Layer.raster(name: "Layer 1", width: st.width, height: st.height)] }
        report.seconds = Date().timeIntervalSince(start)
        return (st, report)
    }

    // MARK: Reports

    struct Entry: Identifiable {
        let id = UUID()
        var documentID: UUID
        var date = Date()
        var report: PDFVectorReport
    }

    /// Reports of recent imports, newest first (shown by File ▸ Import ▸ PDF Import Report…).
    static private(set) var reports: [Entry] = []

    static func record(_ report: PDFVectorReport, for d: Document) {
        reports.insert(Entry(documentID: d.id, report: report), at: 0)
        if reports.count > 30 { reports.removeLast(reports.count - 30) }
    }

    static func report(for id: UUID) -> PDFVectorReport? { reports.first { $0.documentID == id }?.report }

    static func clearReports() { reports = [] }

    // MARK: Loading

    /// Settings used by command-line and automated runs instead of showing the dialog (nil = a flattened first
    /// page, as before this importer existed).
    static var headlessSettings: PDFImport.Settings? = nil
    /// Settings of files imported in this session, so a linked smart object reloads without asking again.
    private static var sessionSettings: [String: PDFImport.Settings] = [:]
    private static let modeKey = "lumen.pdfImport.mode"
    private static let substituteKey = "lumen.pdfImport.substituteFonts"

    static var automated: Bool { FilesModule.headless || Automation.isHeadless }

    /// Mode chosen the last time the dialog was used (editable layers the first time).
    static var rememberedMode: PDFImportMode {
        get { automated ? .editable : (UserDefaults.standard.string(forKey: modeKey).flatMap(PDFImportMode.init(rawValue:)) ?? .editable) }
        set { if !automated { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) } }
    }
    static var rememberedSubstitute: Bool {
        get { automated ? false : UserDefaults.standard.bool(forKey: substituteKey) }
        set { if !automated { UserDefaults.standard.set(newValue, forKey: substituteKey) } }
    }

    /// Opens the PDF document behind `url`, asking for the password of an encrypted file when a person is there to
    /// answer. `password` is tried first.
    static func open(_ url: URL, password: String? = nil) throws -> PDFDocument {
        try checkFile(url)
        let name = url.lastPathComponent
        guard let pdf = PDFDocument(url: url) else { throw PDFVectorError.damaged(name) }
        if pdf.isLocked {
            var ok = pdf.unlock(withPassword: password ?? "")
            var tries = 0
            while !ok, !automated, tries < 3 {
                guard let p = askPassword(name, retry: tries > 0) else { throw CocoaError(.userCancelled) }
                ok = pdf.unlock(withPassword: p)
                tries += 1
            }
            if !ok { throw PDFVectorError.encrypted(name) }
        }
        guard pdf.pageCount > 0 else { throw PDFVectorError.damaged(name) }
        if isPlaceholder(pdf), isIllustrator(url) || pdf.page(at: 0)?.string?.contains("Illustrator") == true { throw PDFVectorError.noPDFContent(name) }
        return pdf
    }

    private static func askPassword(_ name: String, retry: Bool) -> String? {
        let a = NSAlert()
        a.messageText = tr(retry ? "That password did not unlock “\(name)”." : "“\(name)” is password-protected.")
        a.informativeText = tr("Enter the password to open it.")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        a.accessoryView = field
        a.addButton(withTitle: tr("Open"))
        a.addButton(withTitle: tr("Cancel"))
        a.window.initialFirstResponder = field
        guard UIBlock.run(a) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// True when an open document links a smart object to this file (so loading it again is a refresh).
    private static func isLinked(_ url: URL) -> Bool {
        AppModel.shared.documents.contains { d in
            d.state.allLayers.contains { l in if case .smartObject(let so) = l.content { return so.linkedURL == url }; return false }
        }
    }

    /// File ▸ Open / Place / Replace Contents / drag and drop for .pdf, .ai and .ait.
    static func load(url: URL) throws -> Document {
        let pdf = try open(url)
        var settings: PDFImport.Settings
        if automated {
            settings = headlessSettings ?? PDFImport.Settings()
        } else if let s = sessionSettings[url.path], isLinked(url) {
            settings = s
        } else {
            guard let s = ImportPDFDialog.run(pdf: pdf, name: url.lastPathComponent, illustrator: isIllustrator(url)) else { throw CocoaError(.userCancelled) }
            settings = s
            sessionSettings[url.path] = s
        }
        let docs = try PDFImport.documents(pdf: pdf, url: url, settings: settings)
        // Extra pages open as additional documents; the first one is returned to the caller.
        for d in docs.dropFirst() { AppModel.shared.add(d) }
        if settings.mode == .editable, let r = report(for: docs[0].id) {
            AppModel.shared.setStatus("\(url.lastPathComponent) — \(r.summary.replacingOccurrences(of: "Page \(r.page): ", with: "")). Details: File ▸ Import ▸ PDF Import Report")
        }
        return docs[0]
    }

    /// Documents for the selected pages in editable mode (one per page).
    static func documents(pdf: PDFDocument, url: URL?, settings: PDFImport.Settings) throws -> [Document] {
        let base = url.map { ($0.lastPathComponent as NSString).deletingPathExtension } ?? "Untitled"
        var out: [Document] = []
        for i in settings.pages where i >= 0 && i < pdf.pageCount {
            guard let page = pdf.page(at: i),
                  let (st, rep) = state(page: page, in: pdf, box: settings.box, resolution: settings.resolution, white: settings.whiteBackground, options: settings.vector) else { continue }
            var report = rep
            report.file = url?.lastPathComponent ?? ""
            let d = Document(state: st, name: pdf.pageCount > 1 ? "\(base) (Page \(i + 1))" : base)
            record(report, for: d)
            out.append(d)
        }
        if out.isEmpty { throw PDFVectorError.emptyPage(url?.lastPathComponent ?? "The file") }
        return out
    }

    // MARK: Paste

    /// Edit ▸ Paste with vector PDF data on the pasteboard (Illustrator and many Mac apps copy artwork as PDF): the
    /// artwork arrives as editable layers. Returns false when the pasteboard holds no vector PDF.
    @discardableResult
    static func pasteVector(from pb: NSPasteboard, inPlace: Bool = false) -> Bool {
        if let c = AppActions.clipboard, c.changeCount == pb.changeCount { return false }   // Lumen's own copy wins
        let type = NSPasteboard.PasteboardType.pdf
        guard pb.availableType(from: [type]) != nil, let data = pb.data(forType: type), data.count < 200_000_000,
              let pdf = PDFDocument(data: data), !pdf.isLocked, let page = pdf.page(at: 0) else { return false }
        let app = AppModel.shared
        let target = app.activeDocument
        let res = target?.state.resolution ?? 72
        guard let (st, report) = state(page: page, in: pdf, box: .cropBox, resolution: res), !report.flattened else { return false }
        // a PDF that only wraps a picture is better pasted as the picture itself
        let vector = st.allLayers.contains { $0.isShape || $0.isText }
        guard vector else { return false }
        guard let d = target else {
            let nd = Document(state: st, name: "Untitled")
            record(report, for: nd)
            app.add(nd)
            return true
        }
        var layers = st.layers
        // centre the artwork in the view (or on the canvas), unless pasting in place
        var dx = Double(d.state.width - st.width) / 2, dy = Double(d.state.height - st.height) / 2
        if !inPlace, let c = AppActions.canvas, c.document === d {   // (a canvas showing another document says nothing about this one)
            let center = c.viewToDoc(CGPoint(x: c.bounds.midX, y: c.bounds.midY))
            dx = Double(clamp(center.x, 0, CGFloat(d.state.width))) - Double(st.width) / 2
            dy = Double(clamp(center.y, 0, CGFloat(d.state.height))) - Double(st.height) / 2
        }
        for i in layers.indices { layers[i].translate(dx: dx.rounded(), dy: dy.rounded(), document: true) }
        let layer = layers.count == 1 ? layers[0] : Layer(name: "Pasted Artwork", content: .group(GroupContent(children: layers, isExpanded: false)))
        d.addLayer(layer, commitName: "Paste")
        record(report, for: d)
        app.setStatus("Pasted artwork as editable layers — \(report.summary.replacingOccurrences(of: "Page 1: ", with: ""))")
        return true
    }
}

/// Registers the PDF / Illustrator importer: `.ai` / `.ait` for File ▸ Open, Place, Replace Contents, Relink and
/// drag and drop, the import report, and the self tests.
enum PDFVectorModule {
    static func register() {
        DocumentIO.customLoaders["ai"] = { try PDFImport.load(url: $0) }
        DocumentIO.customLoaders["ait"] = { try PDFImport.load(url: $0) }
        // legacy / PostScript files are refused with an explanation instead of "unsupported format"
        DocumentIO.customLoaders["eps"] = { try PDFImport.load(url: $0) }
        var types: [UTType] = []
        for id in ["com.adobe.illustrator.ai-image"] { if let t = UTType(id) { types.append(t) } }
        for ext in ["ai", "ait"] { if let t = UTType(filenameExtension: ext), !types.contains(t) { types.append(t) } }
        for t in types where !DocumentIO.extraOpenTypes.contains(t) { DocumentIO.extraOpenTypes.append(t) }
        MenuRegistry.add("File", "PDF Import Report…", submenu: "Import", enabled: { !PDFVectorImport.reports.isEmpty }) { DialogRegistry.show("pdfImportReport") }
        DialogRegistry.register("pdfImportReport") { AnyView(PDFVectorReportDialog()) }
        FeatureModules.selfTests.append(("pdfimport", { out in PDFVectorSelfTest.run(out) }))
    }
}
