import AppKit
import SwiftUI
import WebKit
import ImageCratCore

// MARK: - Visual diff (exported page rendered by WebKit vs. the document composite)

enum HTMLVisualDiff {
    struct Report {
        var snapshot: CGImage?
        var reference: CGImage?
        /// Share of pixels whose colour is within a small tolerance of the document (0…1).
        var pixelMatch = 0.0
        /// 1 − mean absolute colour difference (0…1).
        var similarity = 0.0
        var error: String?

        var label: String {
            if let e = error { return e }
            return String(format: "%.1f%% match", pixelMatch * 100)
        }
        var detail: String {
            error == nil ? String(format: "%.1f%% of pixels match the document · average colour difference %.2f%%", pixelMatch * 100, (1 - similarity) * 100) : ""
        }
    }

    /// Keeps the web view, its window and the delegate alive until the snapshot is delivered.
    private final class Job: NSObject, WKNavigationDelegate {
        let web: WKWebView
        let window: NSWindow
        let size: CGSize
        var done: ((CGImage?) -> Void)?
        var finished = false

        init(size: CGSize) {
            self.size = size
            let cfg = WKWebViewConfiguration()
            cfg.suppressesIncrementalRendering = true
            web = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: cfg)
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            super.init()
            window.isReleasedWhenClosed = false
            window.contentView = web
            window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            window.orderFrontRegardless()
            web.navigationDelegate = self
        }

        func finish(_ img: CGImage?) {
            guard !finished else { return }
            finished = true
            let cb = done
            done = nil
            web.navigationDelegate = nil
            window.orderOut(nil)
            cb?(img)
            HTMLVisualDiff.jobs.removeAll { $0 === self }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // wait for fonts and image decoding, then for one more layout pass
            webView.evaluateJavaScript("document.fonts ? document.fonts.ready.then(function () { return true; }) : true") { [weak self] _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.snap() }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(nil) }

        func snap() {
            let c = WKSnapshotConfiguration()
            c.rect = CGRect(origin: .zero, size: size)
            c.snapshotWidth = NSNumber(value: Double(size.width))
            c.afterScreenUpdates = true
            web.takeSnapshot(with: c) { [weak self] img, _ in
                guard let self else { return }
                guard let img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { self.finish(nil); return }
                self.finish(HTMLVisualDiff.normalized(cg, width: Int(self.size.width), height: Int(self.size.height)))
            }
        }
    }

    private static var jobs: [Job] = []

    /// Renders `html` in an offscreen WKWebView of `size` CSS px and returns a 1× snapshot.
    static func snapshot(html: String, size: CGSize, timeout: TimeInterval = 25, completion: @escaping (CGImage?) -> Void) {
        let job = Job(size: size)
        jobs.append(job)
        job.done = completion
        job.web.loadHTMLString(html, baseURL: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak job] in job?.finish(nil) }
    }

    /// Blocking variant for self tests (spins the run loop).
    static func snapshotSync(html: String, size: CGSize, timeout: TimeInterval = 25) -> CGImage? {
        var result: CGImage?
        var done = false
        snapshot(html: html, size: size, timeout: timeout) { result = $0; done = true }
        let end = Date().addingTimeInterval(timeout + 2)
        while !done && Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return result
    }

    static func normalized(_ cg: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(RGBA.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// The document as the page should look: composite over white.
    static func reference(_ st: DocumentState) -> CGImage? { Compositor.shared.flatten(st, background: .white) }

    static func compare(_ a: CGImage, _ b: CGImage, tolerance: Int = 40) -> (pixelMatch: Double, similarity: Double) {
        let w = min(a.width, b.width), h = min(a.height, b.height)
        guard w > 0, h > 0, let na = normalized(a, width: w, height: h), let nb = normalized(b, width: w, height: h) else { return (0, 0) }
        let pa = PixelBuffer(cgImage: na), pb = PixelBuffer(cgImage: nb)
        let x = pa.data.assumingMemoryBound(to: UInt8.self), y = pb.data.assumingMemoryBound(to: UInt8.self)
        var total = 0.0
        var good = 0
        for r in 0..<h {
            let ra = x + r * pa.bytesPerRow, rb = y + r * pb.bytesPerRow
            for c in 0..<w {
                let i = c * 4
                let d0 = abs(Int(ra[i]) - Int(rb[i])), d1 = abs(Int(ra[i + 1]) - Int(rb[i + 1])), d2 = abs(Int(ra[i + 2]) - Int(rb[i + 2]))
                total += Double(d0 + d1 + d2)
                if max(d0, max(d1, d2)) <= tolerance { good += 1 }
            }
        }
        let n = Double(w * h)
        return (Double(good) / n, 1 - total / (n * 3 * 255))
    }

    /// Renders the page (single-file variant) offscreen and compares it with the document.
    static func check(_ state: DocumentState, options: HTMLExportOptions, completion: @escaping (Report) -> Void) {
        var o = options
        o.singleFile = true
        o.artboardID = options.artboardID
        let r = HTMLExporter.export(state, options: o)
        check(result: r, completion: completion)
    }

    static func check(result r: HTMLExportResult, completion: @escaping (Report) -> Void) {
        let maxSide: CGFloat = 4096
        guard r.pageSize.width <= maxSide, r.pageSize.height <= maxSide else {
            completion(Report(error: "Page too large to verify"))
            return
        }
        snapshot(html: r.html, size: r.pageSize) { img in
            guard let snap = img, let ref = reference(r.state) else {
                completion(Report(error: "Preview render unavailable"))
                return
            }
            let c = compare(snap, ref)
            completion(Report(snapshot: snap, reference: ref, pixelMatch: c.pixelMatch, similarity: c.similarity, error: nil))
        }
    }

    static func checkSync(result r: HTMLExportResult, timeout: TimeInterval = 30) -> Report {
        var rep = Report(error: "Preview render unavailable")
        var done = false
        check(result: r) { rep = $0; done = true }
        let end = Date().addingTimeInterval(timeout)
        while !done && Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return rep
    }
}

// MARK: - Live preview

struct WebPreview: NSViewRepresentable {
    let html: String
    let pageWidth: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let w = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        w.setValue(false, forKey: "drawsBackground")
        return w
    }

    func updateNSView(_ w: WKWebView, context: Context) {
        if context.coordinator.loaded != html {
            context.coordinator.loaded = html
            w.loadHTMLString(html, baseURL: nil)
        }
        let avail = max(100, w.bounds.width)
        w.pageZoom = min(1, avail / max(1, pageWidth))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loaded = "" }
}

// MARK: - Dialog

/// State of the export dialog (options, the generated page and the visual-diff report).
@Observable
final class HTMLExportModel {
    static var lastOptions: HTMLExportOptions?
    var opt: HTMLExportOptions { didSet { if opt != oldValue && started { scheduleRebuild() } } }
    @ObservationIgnored private var pending: DispatchWorkItem?

    /// Option changes are coalesced (dragging the quality slider must not re-export on every tick).
    private func scheduleRebuild() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.rebuild() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }
    var result: HTMLExportResult?
    var previewHTML = ""
    var tab = 0
    var report: HTMLVisualDiff.Report?
    var checking = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var started = false

    init() {
        var o = Self.lastOptions ?? HTMLExportOptions()
        o.title = (AppActions.doc?.name as NSString?)?.deletingPathExtension ?? "Untitled"
        o.artboardID = nil
        o.altText = [:]
        opt = o
    }

    /// First build (the dialog calls this when it appears).
    func start() {
        guard !started else { return }
        started = true
        rebuild()
    }

    func rebuild() {
        guard let d = AppActions.doc else { return }
        Self.lastOptions = opt
        generation += 1
        let gen = generation
        let r = HTMLExporter.export(d.state, options: opt)
        result = r
        var po = opt
        po.singleFile = true
        let single = opt.singleFile ? r : HTMLExporter.export(d.state, options: po)
        previewHTML = single.html
        checking = true
        HTMLVisualDiff.check(result: single) { [weak self] rep in
            guard let self, gen == self.generation else { return }
            self.report = rep
            self.checking = false
        }
    }
}

struct HTMLExportDialog: View {
    @State private var ownModel = HTMLExportModel()
    var injected: HTMLExportModel? = nil
    private var model: HTMLExportModel { injected ?? ownModel }

    var doc: Document? { AppActions.doc }
    private var result: HTMLExportResult? { model.result }
    private var report: HTMLVisualDiff.Report? { model.report }
    private var checking: Bool { model.checking }
    private var opt: HTMLExportOptions { model.opt }
    private var previewHTML: String { model.previewHTML }

    var body: some View {
        @Bindable var model = model
        DialogFrame(title: "Export HTML & CSS", width: 1000, okTitle: "Export…", onOK: export, extraButtons: AnyView(HStack(spacing: 6) {
            Button("Copy HTML") { copy(result?.html ?? "") }.buttonStyle(PanelButtonStyle())
            Button("Copy CSS") { copy(result?.css ?? "") }.buttonStyle(PanelButtonStyle())
        })) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("", selection: $model.tab) {
                            Text("Preview").tag(0); Text("HTML").tag(1); Text("CSS").tag(2); Text("Compare").tag(3)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
                        Spacer()
                        matchBadge
                    }
                    previewArea.frame(width: 640, height: 430)
                    if let r = result {
                        Text("\(r.elementCount) elements · \(r.textCount) text · \(r.boxCount) CSS boxes · \(r.svgCount) SVG · \(r.images.count) images · \(WebEncoder.sizeLabel(r.totalBytes))")
                            .font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                    }
                }
                ScrollView { optionsColumn.padding(.trailing, 6) }.frame(width: 316, height: 478)
            }
        }
        .onAppear { model.start() }
    }

    @ViewBuilder private var matchBadge: some View {
        if checking {
            HStack(spacing: 5) { ProgressView().controlSize(.small); Text("Comparing with the document…").foregroundStyle(Theme.textDim) }
        } else if let r = report {
            let good = r.error == nil && r.pixelMatch >= 0.95
            HStack(spacing: 5) {
                Image(systemName: r.error != nil ? "questionmark.circle" : (good ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"))
                    .foregroundStyle(r.error != nil ? Theme.textDim : (good ? Color.green : Color.orange))
                Text(r.label).font(Theme.fontBold)
            }
            .help(r.detail.isEmpty ? "The exported page is rendered off screen and compared with the document." : r.detail)
        }
    }

    @ViewBuilder private var previewArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.12))
            switch model.tab {
            case 0:
                if let r = result { WebPreview(html: previewHTML, pageWidth: r.pageSize.width).padding(1) }
            case 1: codeView(result?.html ?? "")
            case 2: codeView(result?.css ?? "")
            default:
                if let r = report, let a = r.reference, let b = r.snapshot {
                    HStack(spacing: 8) {
                        compareImage(a, "Document")
                        compareImage(b, "Web page (WebKit)")
                    }.padding(8)
                } else {
                    Text(checking ? "Rendering…" : (report?.error ?? "No comparison yet")).foregroundStyle(Theme.textDim)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func compareImage(_ cg: CGImage, _ label: String) -> some View {
        VStack(spacing: 4) {
            Image(decorative: cg, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .overlay(Rectangle().stroke(Color(white: 0.3), lineWidth: 0.5))
            Text(label).font(Theme.fontSmall).foregroundStyle(Theme.textDim)
        }
    }

    private func codeView(_ s: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(s.count > 60_000 ? String(s.prefix(60_000)) + "\n…" : s)
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(white: 0.85))
                .textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var optionsColumn: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            if let d = doc {
                let boards = AppActions.artboards(d)
                if !boards.isEmpty {
                    row("Source") {
                        Picker("", selection: $model.opt.artboardID) {
                            Text("Whole Document").tag(UUID?.none)
                            ForEach(boards) { b in Text(b.name).tag(Optional(b.id)) }
                        }.labelsHidden()
                    }
                }
            }
            row("Title") {
                TextField("Page title", text: $model.opt.title).textFieldStyle(.plain).font(Theme.font)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
            }
            row("Layout") {
                Picker("", selection: $model.opt.layout) { ForEach(HTMLExportOptions.Layout.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden()
            }
            Text(opt.layout == .absolute ? "Every element is positioned exactly where it is in the document." : "Groups whose layers form an evenly spaced row or column become flexbox containers with a gap; plates behind them become padding.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            row("Units") {
                Picker("", selection: $model.opt.units) { ForEach(HTMLExportOptions.Units.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 110)
            }
            row("Images") {
                Picker("", selection: $model.opt.imageFormat) {
                    ForEach(HTMLExportOptions.ImageFormat.allCases.filter { $0 != .webp || WebFormat.available.contains(.webp) }) { Text($0.rawValue).tag($0) }
                }.labelsHidden()
            }
            if opt.imageFormat != .png {
                ValueSlider(label: "Quality", value: $model.opt.quality, range: 10...100, unit: "%", labelWidth: 62)
            }
            Toggle2(label: "@2x image assets (srcset)", on: $model.opt.retina)
            Toggle2(label: "CSS variables for the document's colours", on: $model.opt.cssVariables)
            Toggle2(label: "Semantic tags (h1, p, header, nav, button…)", on: $model.opt.semanticTags)
            Toggle2(label: "Responsive: scale down on narrow screens", on: $model.opt.responsive)
            Toggle2(label: "Keep the document's line breaks", on: $model.opt.preserveLineBreaks)
            Toggle2(label: "Single file (embedded CSS and images)", on: $model.opt.singleFile)
            if let r = result, !r.images.isEmpty {
                Divider()
                Caption("Alt text")
                ForEach(r.images, id: \.id) { im in
                    HStack(spacing: 6) {
                        Text(im.name).lineLimit(1).frame(width: 90, alignment: .leading).foregroundStyle(Theme.textDim)
                        AltField(text: im.alt) { v in model.opt.altText[im.id] = v }
                    }
                }
            }
            if let r = result, !r.warnings.isEmpty {
                Divider()
                Caption("Notes (\(r.warnings.count))")
                ForEach(Array(Set(r.warnings)).sorted().prefix(8), id: \.self) { w in
                    Text("• " + w).font(Theme.fontSmall).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Theme.textDim).frame(width: 56, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func copy(_ s: String) {
        guard !s.isEmpty else { return }
        ClipboardHistory.shared.recordText(s)
        ClipboardHistory.shared.writeToPasteboard(text: s)
        AppModel.shared.setStatus("Copied to the clipboard.")
    }

    private func export() {
        guard let d = doc, let r = result else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Export"
        p.message = opt.singleFile ? "Choose a folder for the HTML file" : "Choose a folder for index.html, style.css and the assets folder"
        guard p.runModal() == .OK, let folder = p.url else { return }
        do {
            let base = HTMLExportBuilder.slug((d.name as NSString).deletingPathExtension)
            let page = try HTMLExporter.write(r, to: folder, options: opt, fileName: opt.singleFile ? "\(base).html" : "index.html")
            AppModel.shared.setStatus("Exported \(page.lastPathComponent)\(opt.singleFile ? "" : " with \(r.assets.count) image asset\(r.assets.count == 1 ? "" : "s")")\(report?.error == nil && report != nil ? " — \(report!.label)" : "").")
            NSWorkspace.shared.activateFileViewerSelecting([page])
        } catch { AppActions.alert("Could not export the page.", error.localizedDescription) }
    }
}

/// Text field that reports its value when editing ends (so typing does not rebuild the page per keystroke).
struct AltField: View {
    let text: String
    var commit: (String) -> Void
    @State private var value = ""
    @State private var fieldID = UUID()
    @FocusState private var focused: Bool
    var body: some View {
        // typed text also counts when a button is clicked straight after typing (see FieldEdits)
        TextField("Describe the image", text: Binding(get: { value }, set: { v in
            value = v
            FieldEdits.edited(fieldID, commit: { if value != text { commit(value) } }, discard: { value = text })
        }))
            .textFieldStyle(.plain).font(Theme.font).focused($focused)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
            .onAppear { value = text }
            .onSubmit { FieldEdits.ended(fieldID); if value != text { commit(value) } }
            .onChange(of: focused) { _, f in if !f { FieldEdits.ended(fieldID); if value != text { commit(value) } } }
    }
}

// MARK: - Copy CSS / Copy as SVG

enum WebCopyCommands {
    static func copyCSS() {
        guard let d = AppActions.doc, let l = d.activeLayer else { NSSound.beep(); return }
        let css = HTMLExporter.css(for: l, in: d.state)
        ClipboardHistory.shared.recordText(css)
        ClipboardHistory.shared.writeToPasteboard(text: css)
        AppModel.shared.setStatus("Copied the CSS of “\(l.name)”.")
    }

    static func canCopySVG(_ l: Layer?) -> Bool {
        guard let l else { return false }
        if l.isShape || l.isText { return true }
        return l.isGroup && l.children.contains { canCopySVG($0) }
    }

    static func copySVG() {
        guard let d = AppActions.doc, let l = d.activeLayer, let svg = LayerSVGExport.svg(for: l, in: d.state) else {
            NSSound.beep()
            AppModel.shared.setStatus("Copy as SVG works on shape and type layers (or groups of them).")
            return
        }
        let item: ClipItem = l.shape.map { ClipboardHistory.shared.recordShape($0, name: l.name) } ?? ClipboardHistory.shared.recordText(svg)
        ClipboardHistory.shared.writeToPasteboard(text: svg, item: item)
        AppModel.shared.setStatus("Copied “\(l.name)” as SVG.")
    }
}
