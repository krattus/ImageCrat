import AppKit
import SwiftUI
import PDFKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

// MARK: - Photoshop PDF export

/// Photoshop PDF: one page per artboard (or the whole canvas), text and shape layers drawn as live vector
/// graphics through Core Graphics, everything else placed as images.
enum PDFExport {
    struct Options: Equatable {
        /// Draw text / shape layers as vectors (false = one flattened image per page).
        var preserveVector = true
        /// One page per artboard when the document has artboards.
        var artboardsAsPages = true
        /// JPEG-compress raster images (nil = lossless Flate).
        var jpegQuality: Double? = nil
        /// Title stored in the PDF info dictionary.
        var title: String? = nil
    }

    /// Pages to write: (state cropped to the page, page name).
    static func pages(_ st: DocumentState, options: Options = Options()) -> [(DocumentState, String)] {
        if options.artboardsAsPages {
            let abs = st.allLayers.filter { $0.isArtboard && $0.isVisible }
            if !abs.isEmpty { return abs.compactMap { l in AppActions.artboardState(st, l).map { ($0, l.name) } } }
        }
        return [(st, "Page 1")]
    }

    static func write(_ st: DocumentState, to url: URL, options: Options = Options()) throws {
        let list = pages(st, options: options)
        guard !list.isEmpty else { throw DocumentIOError.encodeFailed }
        var info: [CFString: Any] = [kCGPDFContextCreator: Brand.name]
        if let t = options.title { info[kCGPDFContextTitle] = t }
        var first = pageBox(list[0].0)
        guard let ctx = CGContext(url as CFURL, mediaBox: &first, info as CFDictionary) else { throw DocumentIOError.encodeFailed }
        for (page, _) in list {
            var box = pageBox(page)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            drawPage(page, in: ctx, options: options)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// Page size in points (pixels at the document resolution).
    static func pageBox(_ st: DocumentState) -> CGRect {
        let s = 72 / max(1, st.resolution)
        return CGRect(x: 0, y: 0, width: CGFloat(st.width) * s, height: CGFloat(st.height) * s)
    }

    /// Draws one page. The context is set up so that one unit = one document pixel, y down.
    static func drawPage(_ st: DocumentState, in ctx: CGContext, options: Options) {
        let s = 72 / max(1, st.resolution)
        ctx.saveGState()
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: 0, y: CGFloat(st.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: st.canvasCGRect)
        if options.preserveVector {
            drawLayers(st.layers, st: st, ctx: ctx, options: options)
        } else if let cg = Compositor.shared.flatten(st) {
            drawImage(cg, rect: st.canvasCGRect, ctx: ctx, options: options)
        }
        ctx.restoreGState()
    }

    // MARK: Layer drawing

    /// A layer that can't be drawn on its own (it depends on what is below it).
    private static func needsBackdrop(_ l: Layer) -> Bool {
        if !l.isVisible { return false }
        if l.isAdjustment || l.isClipped || l.knockout != .none || !l.blendIf.isDefault { return true }
        if l.isGroup { return l.blendMode != .passThrough && l.blendMode != .normal || (l.blendMode == .passThrough && l.children.contains(where: needsBackdrop)) }
        return l.blendMode != .normal
    }

    static func drawLayers(_ layers: [Layer], st: DocumentState, ctx: CGContext, options: Options) {
        var start = 0
        // Everything up to the last layer that blends with its backdrop (and its clipping base) is flattened.
        if let k = layers.lastIndex(where: needsBackdrop) {
            let sp = CanvasSpace(width: st.width, height: st.height)
            let img = Compositor.shared.composite(layers: Array(layers[0...k]), backdrop: CIImage.clearImage.cropped(to: sp.ciCanvas),
                                                  space: sp, options: Compositor.Options(globalLight: st.globalLight))
            if let cg = RenderEngine.cgImage(img.cropped(to: sp.ciCanvas), rect: sp.ciCanvas) {
                drawImage(cg, rect: st.canvasCGRect, ctx: ctx, options: options)
            }
            start = k + 1
        }
        var i = start
        while i < layers.count {
            // a clipping base together with its clipped layers is flattened as a unit
            var j = i
            while j + 1 < layers.count && layers[j + 1].isClipped { j += 1 }
            if j > i {
                rasterGroup(Array(layers[i...j]), st: st, ctx: ctx, options: options)
            } else {
                drawLayer(layers[i], st: st, ctx: ctx, options: options)
            }
            i = j + 1
        }
    }

    private static func isPlainVector(_ l: Layer) -> Bool {
        l.mask == nil && (l.vectorMask == nil || !l.vectorMaskEnabled) && !l.effects.hasAny && l.blendMode == .normal
            && l.fillOpacity >= 0.999 && l.channelR && l.channelG && l.channelB
    }

    static func drawLayer(_ l: Layer, st: DocumentState, ctx: CGContext, options: Options) {
        guard l.isVisible else { return }
        switch l.content {
        case .text(let t) where isPlainVector(l) && TextRenderer.activeWarp(t) == nil:
            withOpacity(l.opacity, ctx) {
                ctx.concatenate(TextRenderer.docTransform(t))
                TextRenderer.draw(t, in: ctx)
            }
        case .shape(let s) where isPlainVector(l) && s.perspective == nil:
            let sp = CanvasSpace(width: st.width, height: st.height)
            withOpacity(l.opacity, ctx) { ShapeRenderer.draw(s, in: ctx, space: sp) }
        case .fill(let f) where isPlainVector(l):
            if case .color(let c) = f.paint {
                withOpacity(l.opacity, ctx) { ctx.setFillColor(c.cgColor); ctx.fill(st.canvasCGRect) }
            } else { rasterGroup([l], st: st, ctx: ctx, options: options) }
        case .group(let g) where l.mask == nil && !l.effects.hasAny && (l.blendMode == .passThrough || l.blendMode == .normal):
            withOpacity(l.opacity, ctx) {
                if let ab = g.artboard {
                    ctx.clip(to: ab.rect)
                    if let bg = ab.background { ctx.setFillColor(bg.cgColor); ctx.fill(ab.rect) }
                }
                drawLayers(g.children, st: st, ctx: ctx, options: options)
            }
        case .adjustment:
            break
        default:
            rasterGroup([l], st: st, ctx: ctx, options: options)
        }
    }

    private static func withOpacity(_ o: Double, _ ctx: CGContext, _ body: () -> Void) {
        ctx.saveGState()
        if o < 0.999 {
            ctx.setAlpha(CGFloat(max(0, o)))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            body()
            ctx.endTransparencyLayer()
        } else {
            body()
        }
        ctx.restoreGState()
    }

    /// Full appearance of `layers` (content, effects, masks, opacity) placed as one image, trimmed to content.
    private static func rasterGroup(_ layers: [Layer], st: DocumentState, ctx: CGContext, options: Options) {
        let sp = CanvasSpace(width: st.width, height: st.height)
        var ls = layers
        if var first = ls.first { first.isClipped = false; ls[0] = first }
        let img = Compositor.shared.composite(layers: ls, backdrop: CIImage.clearImage.cropped(to: sp.ciCanvas), space: sp,
                                              options: Compositor.Options(globalLight: st.globalLight)).cropped(to: sp.ciCanvas)
        let ext = img.extent.integral.intersection(sp.ciCanvas)
        guard !ext.isEmpty, let cg = RenderEngine.cgImage(img, rect: ext) else { return }
        // trim transparent borders
        let buf = PixelBuffer(cgImage: cg)
        guard let ob = buf.opaqueBounds() else { return }
        let trimmed = ob == buf.bounds ? cg : (buf.cropped(to: ob).makeCGImage())
        let docExt = sp.docRect(ext)
        let r = CGRect(x: docExt.minX + CGFloat(ob.x), y: docExt.minY + CGFloat(ob.y), width: CGFloat(ob.width), height: CGFloat(ob.height))
        drawImage(trimmed, rect: r, ctx: ctx, options: options)
    }

    /// Draws an image into doc rect `r` of a y-down context.
    static func drawImage(_ cg: CGImage, rect r: CGRect, ctx: CGContext, options: Options) {
        var img = cg
        if let q = options.jpegQuality, let j = jpegImage(cg, quality: q) { img = j }
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    /// JPEG-backed CGImage (Core Graphics passes it through to the PDF as DCT data). Opaque images only.
    private static func jpegImage(_ cg: CGImage, quality: Double) -> CGImage? {
        if cg.alphaInfo != .none && cg.alphaInfo != .noneSkipLast && cg.alphaInfo != .noneSkipFirst {
            // keep transparency lossless unless the image is fully opaque
            let b = PixelBuffer(cgImage: cg)
            if let ob = b.opaqueBounds(threshold: 254), ob == b.bounds {} else { return nil }
            let p = b.data.assumingMemoryBound(to: UInt8.self)
            for y in 0..<b.height { for x in 0..<b.width where p[y * b.bytesPerRow + x * 4 + 3] != 255 { return nil } }
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let prov = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: PDF Presentation

    struct PresentationOptions {
        var background: RGBA = .white
        var includeFilename = false
        /// Fixed page size in points (nil = each page matches its image at its resolution).
        var pageSize: CGSize? = nil
        var jpegQuality: Double? = 0.9
    }

    /// Multi-page PDF with one image per page (File > Automate > PDF Presentation).
    static func writePresentation(_ items: [(image: CGImage, name: String, dpi: Double)], to url: URL, options: PresentationOptions) throws {
        guard !items.isEmpty else { throw DocumentIOError.encodeFailed }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextCreator: Brand.name] as CFDictionary) else { throw DocumentIOError.encodeFailed }
        for it in items {
            let s = 72 / max(1, it.dpi)
            let natural = CGSize(width: CGFloat(it.image.width) * s, height: CGFloat(it.image.height) * s)
            let caption: CGFloat = options.includeFilename ? 28 : 0
            let page = options.pageSize ?? CGSize(width: natural.width, height: natural.height + caption)
            var mb = CGRect(origin: .zero, size: page)
            let boxData = Data(bytes: &mb, count: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            ctx.setFillColor(options.background.cgColor)
            ctx.fill(mb)
            let avail = CGRect(x: 0, y: caption, width: page.width, height: page.height - caption)
            let k = min(1, min(avail.width / natural.width, avail.height / natural.height))
            let sz = CGSize(width: natural.width * k, height: natural.height * k)
            let r = CGRect(x: avail.midX - sz.width / 2, y: avail.midY - sz.height / 2, width: sz.width, height: sz.height)
            var img = it.image
            if let q = options.jpegQuality, let j = jpegImage(it.image, quality: q) { img = j }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: r)
            if options.includeFilename {
                let lum = options.background.r * 0.3 + options.background.g * 0.59 + options.background.b * 0.11
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                            .foregroundColor: lum > 0.5 ? NSColor.black : NSColor.white]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: it.name, attributes: attrs))
                let w = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.textPosition = CGPoint(x: (page.width - CGFloat(w)) / 2, y: 10)
                CTLineDraw(line, ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}

// MARK: - PDF import

enum PDFImport {
    struct Settings {
        var pages: [Int] = [0]          // zero-based
        var resolution: Double = 150
        var box: PDFDisplayBox = .cropBox
        var whiteBackground = false
        /// Editable layers (Import/PDF) or one flattened pixel layer per page.
        var mode: PDFImportMode = .flattened
        var vector = PDFVectorOptions()
        /// Tried on an encrypted file before anyone is asked.
        var password: String? = nil
    }

    static func pageCount(_ url: URL) -> Int { PDFDocument(url: url)?.pageCount ?? 0 }

    /// Rasterizes one page at `resolution` ppi.
    static func rasterize(_ page: PDFPage, resolution: Double, box: PDFDisplayBox = .cropBox, white: Bool = false) -> CGImage? {
        let b = page.bounds(for: box)
        let s = resolution / 72
        var w = Int((b.width * s).rounded()), h = Int((b.height * s).rounded())
        let rot = page.rotation % 360
        if rot == 90 || rot == 270 { swap(&w, &h) }
        guard w > 0, h > 0, w < 30000, h < 30000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if white { ctx.setFillColor(CGColor.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: s, y: s)
        page.draw(with: box, to: ctx)
        return ctx.makeImage()
    }

    static func documents(url: URL, settings: Settings) throws -> [Document] {
        try documents(pdf: try PDFVectorImport.open(url, password: settings.password), url: url, settings: settings)
    }

    /// Documents for the selected pages of an opened (unlocked) PDF or PDF-compatible Illustrator file.
    static func documents(pdf: PDFDocument, url: URL, settings: Settings) throws -> [Document] {
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        var out: [Document] = []
        if settings.mode == .editable { out = try PDFVectorImport.documents(pdf: pdf, url: url, settings: settings) }
        for i in settings.pages where settings.mode == .flattened && i >= 0 && i < pdf.pageCount {
            guard let page = pdf.page(at: i), let cg = rasterize(page, resolution: settings.resolution, box: settings.box, white: settings.whiteBackground) else { continue }
            var st = DocumentState(width: cg.width, height: cg.height, resolution: settings.resolution)
            st.layers = [Layer.raster(name: pdf.pageCount > 1 ? "Page \(i + 1)" : "Layer 1", buffer: PixelBuffer(cgImage: cg))]
            let d = Document(state: st, name: pdf.pageCount > 1 ? "\(base) (Page \(i + 1))" : base)
            out.append(d)
        }
        if out.isEmpty { throw DocumentIOError.unreadable }
        // Only a single-page import is associated with the file (re-opening focuses it).
        if out.count == 1 { out[0].fileURL = url }
        return out
    }

    /// Loader hook for File > Open (.pdf, .ai, .ait): shows the import dialog (mode, page picker, resolution) in the app.
    static func load(url: URL) throws -> Document { try PDFVectorImport.load(url: url) }
}

/// Import PDF / Illustrator: import mode, page thumbnails (multi-select), resolution and crop box. Runs as a modal alert.
final class ImportPDFModel: ObservableObject {
    @Published var selected: Set<Int> = [0]
    @Published var resolution: Double = 150
    @Published var boxIndex = 1
    @Published var white = false
    @Published var mode: PDFImportMode = PDFVectorImport.rememberedMode
    @Published var substituteFonts = PDFVectorImport.rememberedSubstitute
    @Published var exactAppearance = true
    let pdf: PDFDocument
    /// An Illustrator file: its pages are artboards.
    let illustrator: Bool
    var thumbs: [Int: NSImage] = [:]
    init(pdf: PDFDocument, illustrator: Bool = false) { self.pdf = pdf; self.illustrator = illustrator }
    var pageWord: String { illustrator ? "Artboard" : "Page" }
    func thumb(_ i: Int) -> NSImage? {
        if let t = thumbs[i] { return t }
        guard let p = pdf.page(at: i) else { return nil }
        let t = p.thumbnail(of: NSSize(width: 110, height: 140), for: .cropBox)
        thumbs[i] = t
        return t
    }
    var box: PDFDisplayBox { [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox][boxIndex] }
    func pixelSize(_ i: Int) -> String {
        guard let p = pdf.page(at: i) else { return "" }
        let b = p.bounds(for: box)
        return "\(Int(b.width * resolution / 72)) × \(Int(b.height * resolution / 72)) px"
    }
}

struct ImportPDFView: View {
    @ObservedObject var m: ImportPDFModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Import As:").frame(width: 80, alignment: .leading)
                Picker("", selection: $m.mode) {
                    Text("Editable Layers").tag(PDFImportMode.editable)
                    Text("Flattened Image").tag(PDFImportMode.flattened)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 260)
            }
            Text(m.mode == .editable ? "Shapes, text and images become layers in groups; anything without a layer equivalent is rasterized in place."
                                     : "Each page becomes one pixel layer.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], spacing: 8) {
                    ForEach(0..<m.pdf.pageCount, id: \.self) { i in
                        VStack(spacing: 2) {
                            if let t = m.thumb(i) { Image(nsImage: t).resizable().aspectRatio(contentMode: .fit).frame(height: 120) }
                            Text("\(m.pageWord) \(i + 1)").font(.system(size: 10))
                        }
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 4).stroke(m.selected.contains(i) ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: m.selected.contains(i) ? 2 : 1))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                                if m.selected.contains(i) && m.selected.count > 1 { m.selected.remove(i) } else { m.selected.insert(i) }
                            } else { m.selected = [i] }
                        }
                    }
                }.padding(4)
            }.frame(height: 250)
            HStack {
                Button("Select All") { m.selected = Set(0..<m.pdf.pageCount) }
                Spacer()
                Text("\(m.selected.count) of \(m.pdf.pageCount) selected").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Text("Crop To:").frame(width: 80, alignment: .leading)
                Picker("", selection: $m.boxIndex) {
                    ForEach(Array(["Media Box", "Crop Box", "Bleed Box", "Trim Box", "Art Box"].enumerated()), id: \.offset) { Text($1).tag($0) }
                }.labelsHidden().frame(width: 140)
            }
            HStack {
                Text("Resolution:").frame(width: 80, alignment: .leading)
                TextField("", value: $m.resolution, format: .number).frame(width: 70)
                Text("Pixels/Inch").font(.system(size: 11))
                Spacer()
                Text(m.pixelSize(m.selected.min() ?? 0)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Toggle("White background (otherwise transparent)", isOn: $m.white)
            Toggle("Keep text editable when its font is missing (substitutes a font)", isOn: $m.substituteFonts).disabled(m.mode != .editable)
            Toggle("Exact appearance (rasterize groups ImageCrat would blend differently)", isOn: $m.exactAppearance).disabled(m.mode != .editable)
        }
        .frame(width: 420)
        .padding(4)
    }
}

enum ImportPDFDialog {
    static func run(pdf: PDFDocument, name: String, illustrator: Bool = false) -> PDFImport.Settings? {
        let m = ImportPDFModel(pdf: pdf, illustrator: illustrator)
        let a = NSAlert()
        a.messageText = illustrator ? "Import Illustrator File" : "Import PDF"
        let unit = illustrator ? "artboard" : "page"
        a.informativeText = "\(name) — \(pdf.pageCount) \(unit)\(pdf.pageCount == 1 ? "" : "s"). Each selected \(unit) opens as a document."
        let host = NSHostingView(rootView: ImportPDFView(m: m))
        host.frame = NSRect(x: 0, y: 0, width: 430, height: 492)
        a.accessoryView = host
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        guard UIBlock.run(a) == .alertFirstButtonReturn else { return nil }
        PDFVectorImport.rememberedMode = m.mode
        PDFVectorImport.rememberedSubstitute = m.substituteFonts
        var s = PDFImport.Settings(pages: m.selected.sorted(), resolution: max(10, min(2400, m.resolution)), box: m.box, whiteBackground: m.white)
        s.mode = m.mode
        s.vector.substituteFonts = m.substituteFonts
        s.vector.exactAppearance = m.exactAppearance
        return s
    }
}

// MARK: - UI

enum PDFUI {
    /// Photoshop PDF options (modal). nil when cancelled.
    static func askOptions(_ d: Document) -> PDFExport.Options? {
        var o = PDFExport.Options()
        o.title = (d.name as NSString).deletingPathExtension
        if FilesModule.headless { return o }
        let a = NSAlert()
        a.messageText = "Save Adobe PDF"
        a.informativeText = "Text and shape layers are kept as vector graphics; other layers are embedded as images."
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 84))
        let vec = NSButton(checkboxWithTitle: "Preserve vector data (text & shapes)", target: nil, action: nil)
        vec.frame = NSRect(x: 0, y: 60, width: 300, height: 20); vec.state = .on
        let ab = NSButton(checkboxWithTitle: "One page per artboard", target: nil, action: nil)
        ab.frame = NSRect(x: 0, y: 36, width: 300, height: 20); ab.state = .on
        let comp = NSPopUpButton(frame: NSRect(x: 0, y: 4, width: 260, height: 24))
        comp.addItems(withTitles: ["Image Compression: ZIP (lossless)", "Image Compression: JPEG High", "Image Compression: JPEG Medium"])
        for s in [vec, ab, comp] as [NSView] { v.addSubview(s) }
        a.accessoryView = v
        a.addButton(withTitle: "Save PDF")
        a.addButton(withTitle: "Cancel")
        guard UIBlock.run(a) == .alertFirstButtonReturn else { return nil }
        o.preserveVector = vec.state == .on
        o.artboardsAsPages = ab.state == .on
        o.jpegQuality = [nil, 0.9, 0.6][comp.indexOfSelectedItem]
        return o
    }

    static func save(_ d: Document, to url: URL) throws {
        guard let o = askOptions(d) else { return }
        try PDFExport.write(d.state, to: url, options: o)
        AppModel.shared.setStatus("Saved \(url.lastPathComponent) (\(PDFExport.pages(d.state, options: o).count) page(s))")
    }

    static func exportPanel() {
        guard let d = AppActions.doc else { return }
        AppActions.canvas?.commitCurrentTool()
        let p = NSSavePanel()
        p.allowedContentTypes = [.pdf]
        p.nameFieldStringValue = (d.name as NSString).deletingPathExtension + ".pdf"
        guard UIBlock.run(p) == .OK, let url = p.url else { return }
        do { try save(d, to: url) } catch { AppActions.alert("Could not save the PDF.", error.localizedDescription) }
    }
}

/// File > Automate > PDF Presentation…
struct PDFPresentationDialog: View {
    @State private var files: [URL] = []
    @State private var includeOpen = true
    @State private var bgIndex = 0
    @State private var includeName = false
    @State private var sizeIndex = 0
    @State private var jpeg = true

    var body: some View {
        DialogFrame(title: "PDF Presentation", width: 460, okTitle: "Save…", onOK: save) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle2(label: "Add Open Files (\(AppModel.shared.documents.count))", on: $includeOpen)
                HStack {
                    Text("Source Files").font(Theme.fontBold)
                    Spacer()
                    Button("Browse…") { browse() }.buttonStyle(PanelButtonStyle())
                    Button("Remove All") { files = [] }.buttonStyle(PanelButtonStyle()).disabled(files.isEmpty)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(files.enumerated()), id: \.offset) { i, u in
                            HStack {
                                Text(u.lastPathComponent).lineLimit(1)
                                Spacer()
                                Button { files.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                            }
                        }
                        if files.isEmpty { Text("No files added").foregroundStyle(Theme.textFaint) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 110).padding(4).background(Color(white: 0.16))
                HStack {
                    Text("Background").frame(width: 90, alignment: .leading)
                    Picker("", selection: $bgIndex) { Text("White").tag(0); Text("Gray").tag(1); Text("Black").tag(2) }.labelsHidden().frame(width: 120)
                }
                HStack {
                    Text("Page Size").frame(width: 90, alignment: .leading)
                    Picker("", selection: $sizeIndex) { Text("Fit Each Image").tag(0); Text("US Letter").tag(1); Text("A4").tag(2) }.labelsHidden().frame(width: 140)
                }
                Toggle2(label: "Include Filename", on: $includeName)
                Toggle2(label: "JPEG compression", on: $jpeg)
            }
        }
    }

    func browse() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.image]
        if UIBlock.run(p) == .OK { files += p.urls }
    }

    func save() {
        var items: [(image: CGImage, name: String, dpi: Double)] = []
        if includeOpen {
            for d in AppModel.shared.documents { if let cg = Compositor.shared.flatten(d.state, background: .white) { items.append((cg, d.name, d.state.resolution)) } }
        }
        for u in files {
            if let d = try? DocumentIO.load(url: u), let cg = Compositor.shared.flatten(d.state, background: .white) { items.append((cg, u.lastPathComponent, d.state.resolution)) }
        }
        guard !items.isEmpty else { AppActions.alert("No images to include."); return }
        let sp = NSSavePanel()
        sp.allowedContentTypes = [.pdf]
        sp.nameFieldStringValue = "Presentation.pdf"
        guard UIBlock.run(sp) == .OK, let url = sp.url else { return }
        var o = PDFExport.PresentationOptions()
        o.background = [RGBA.white, RGBA(gray: 0.5), RGBA.black][bgIndex]
        o.includeFilename = includeName
        o.pageSize = [nil, CGSize(width: 612, height: 792), CGSize(width: 595, height: 842)][sizeIndex]
        o.jpegQuality = jpeg ? 0.9 : nil
        do {
            try PDFExport.writePresentation(items, to: url, options: o)
            AppModel.shared.setStatus("Saved PDF presentation with \(items.count) pages.")
        } catch { AppActions.alert("Could not save the PDF.", error.localizedDescription) }
    }
}
