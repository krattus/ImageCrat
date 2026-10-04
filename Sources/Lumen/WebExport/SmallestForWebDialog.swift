import AppKit
@testable import LumenUltra
import SwiftUI
import UniformTypeIdentifiers

// File ▸ Export ▸ Smallest for Web… — renders the document once, encodes it in every format this Mac can write, each
// tuned to the same perceptual target, and shows the table (size, quality, browser support) with the winner preselected.
// Can export several formats at once with a <picture> / srcset snippet, @1x / @2x / @3x and width variants.

final class SmallestForWebSession: ObservableObject {
    let document: Document
    @Published var preset = 1 { didSet { invalidate() } }
    @Published var effort: UPEffort = .fast { didSet { invalidate() } }
    @Published var smartBlur = false { didSet { invalidate() } }
    @Published var enabled: Set<WXFormatKind> = Set(WXFormatKind.allCases.filter { $0 != .heic && $0 != .gif })
    @Published var candidates: [WXCandidate] = []
    @Published var selected: Set<WXFormatKind> = []
    @Published var winner: WXFormatKind?
    @Published var busy = false
    @Published var progress = 0.0
    @Published var stage = ""
    @Published var gradient: WXGradientSuggestion?
    @Published var vectorNote: String?
    // responsive set
    @Published var displayWidthText = ""
    @Published var x1 = true
    @Published var x2 = true
    @Published var x3 = false
    @Published var widthsText = ""
    @Published var snippet = ""
    @Published var baseName: String

    private(set) var source: UPImage?
    private var work: UPProgress?
    private var generation = 0
    var synchronous = false

    init(document: Document, synchronous: Bool = false) {
        self.document = document
        self.synchronous = synchronous
        baseName = FilesUI.safeName(WXDoc.baseName(document)).replacingOccurrences(of: " ", with: "-").lowercased()
        source = WXDoc.image(document.state)
        if let img = source {
            gradient = WXGradientDetector.detect(img)
            let vis = document.state.layers.filter(\.isVisible)
            if !vis.isEmpty, vis.allSatisfy(SVGExport.isVector) {
                let svg = SVGExport.export(document.state, options: SVGExportOptions())
                let t = WXTransfer.estimate(svg.data, mime: "image/svg+xml")
                vectorNote = "Every visible layer is vector: an SVG is \(WXTransfer.bytes(svg.data.count)) (\(WXTransfer.bytes(t.brotli)) with Brotli) and sharp at any size — see Export ▸ SVG…"
            }
        }
    }

    var target: UPQualityTarget { UPQualityTarget.presets[max(0, min(3, preset))] }
    var displayWidth: Int? { Int(displayWidthText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil } }
    var extraWidths: [Int] { widthsText.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { $0 > 0 } }
    var densities: [Int] { (x1 ? [1] : []) + (x2 ? [2] : []) + (x3 ? [3] : []) }
    var hasAlpha: Bool { source?.hasAlpha ?? false }

    var downscaleHint: String? {
        guard let img = source, let d = displayWidth, let w = WXResponsive.downscaleSuggestion(sourceWidth: img.width, displayWidth: d, maxDensity: densities.max() ?? 2) else { return nil }
        return "The document is \(img.width) px wide but will be shown at \(d) px: \(w) px is enough for the sharpest screen you selected (about \(Int((1 - Double(w * w) / Double(img.width * img.width)) * 100))% fewer pixels)."
    }

    private func onMain(_ f: @escaping () -> Void) { if synchronous || Thread.isMainThread { f() } else { DispatchQueue.main.async(execute: f) } }

    func invalidate() { candidates = []; selected = []; winner = nil; snippet = "" }

    func cancel() { work?.cancel(); work = nil; generation += 1; busy = false }

    func analyse() {
        guard let img = source else { return }
        cancel()
        let gen = generation
        let p = UPProgress()
        work = p
        busy = true; progress = 0; stage = "Encoding…"
        p.onUpdate = { [weak self] f, s in self?.onMain { guard let me = self, me.generation == gen else { return }; me.progress = f; me.stage = s } }
        var o = WXAssistantOptions()
        o.target = target; o.effort = effort; o.smartBlur = smartBlur
        o.formats = WXFormatKind.allCases.filter { enabled.contains($0) }
        let job = { [weak self] in
            let list = WXAssistant.run(img, options: o, progress: p)
            if p.cancelled { return }
            self?.onMain {
                guard let me = self, me.generation == gen else { return }
                me.candidates = list
                me.winner = WXAssistant.winner(list, hasAlpha: img.hasAlpha)?.kind
                me.selected = me.winner.map { [$0] } ?? []
                me.busy = false
                me.updateSnippet()
            }
        }
        if synchronous { job() } else { DispatchQueue.global(qos: .userInitiated).async(execute: job) }
    }

    func toggle(_ k: WXFormatKind) {
        if selected.contains(k) { selected.remove(k) } else { selected.insert(k) }
        updateSnippet()
    }

    /// Markup for the current selection (single size). The exported responsive set writes its own, complete snippet.
    func updateSnippet() {
        guard let img = source else { return }
        let chosen = candidates.filter { selected.contains($0.kind) }
        guard !chosen.isEmpty else { snippet = ""; return }
        var o = WXResponsiveOptions()
        o.baseName = baseName; o.displayWidth = displayWidth; o.densities = densities; o.widths = extraWidths
        let widths = WXResponsive.variantWidths(sourceWidth: img.width, options: o)
        var files: [(name: String, data: Data, width: Int, kind: WXFormatKind)] = []
        for c in chosen { for w in widths { files.append(("\(baseName)-\(w).\(c.kind.ext)", Data(), w, c.kind)) } }
        if widths.count == 1 && displayWidth == nil && extraWidths.isEmpty {
            files = chosen.map { ("\(baseName).\($0.kind.ext)", Data(), img.width, $0.kind) }
        }
        var s = WXResponsive.pictureHTML(files: files, kinds: chosen.map(\.kind), options: o, sourceWidth: img.width, sourceHeight: img.height)
        if selected.contains(.jpegMask) { s += "\n\n" + WXAlphaSplit.cssSnippet(name: baseName, width: img.width, height: img.height) }
        if let g = gradient { s += "\n\n/* or no file at all */\n" + g.css }
        snippet = s
    }

    /// Writes the selected formats (and the responsive variants when a display width / extra widths are set) plus the snippet.
    func export(to folder: URL, done: @escaping (Int, Int) -> Void) {
        guard let img = source else { return }
        let chosen = candidates.filter { selected.contains($0.kind) }
        guard !chosen.isEmpty else { return }
        cancel()
        let gen = generation
        let p = UPProgress()
        work = p
        busy = true; progress = 0; stage = "Exporting…"
        p.onUpdate = { [weak self] f, s in self?.onMain { guard let me = self, me.generation == gen else { return }; me.progress = f; me.stage = s } }
        var o = WXResponsiveOptions()
        o.baseName = baseName; o.displayWidth = displayWidth; o.densities = densities; o.widths = extraWidths
        o.formats = chosen.map(\.kind); o.target = target; o.effort = effort
        let single = displayWidth == nil && extraWidths.isEmpty
        let snippetText = snippet
        let job = { [weak self] in
            var count = 0, bytes = 0
            var html = snippetText
            if single {
                for c in chosen {
                    try? c.data.write(to: folder.appendingPathComponent("\(o.baseName).\(c.kind.ext)"), options: .atomic)
                    count += 1; bytes += c.data.count
                    for e in c.extra { try? e.data.write(to: folder.appendingPathComponent("\(o.baseName)\(e.suffix)"), options: .atomic); count += 1; bytes += e.data.count }
                }
            } else {
                let set = WXResponsive.build(img, options: o, progress: p)
                if p.cancelled { return }
                for f in set.files { try? f.data.write(to: folder.appendingPathComponent(f.name), options: .atomic); count += 1; bytes += f.data.count }
                html = set.html
            }
            try? html.write(to: folder.appendingPathComponent("\(o.baseName).html"), atomically: true, encoding: .utf8)
            self?.onMain {
                guard let me = self, me.generation == gen else { return }
                me.busy = false
                done(count, bytes)
            }
        }
        if synchronous { job() } else { DispatchQueue.global(qos: .userInitiated).async(execute: job) }
    }
}

struct SmallestForWebDialog: View {
    @StateObject var session: SmallestForWebSession

    init(session: SmallestForWebSession) { _session = StateObject(wrappedValue: session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Smallest for Web").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 12) {
                Text("Quality").foregroundStyle(Theme.textDim)
                Picker("", selection: $session.preset) { Text("Visually lossless").tag(0); Text("High").tag(1); Text("Medium").tag(2); Text("Small").tag(3) }
                    .labelsHidden().frame(width: 150)
                Picker("", selection: $session.effort) { ForEach(UPEffort.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Toggle2(label: "Soften unimportant background", on: $session.smartBlur)
                Spacer()
                Button(session.candidates.isEmpty ? "Analyse" : "Analyse Again") { session.analyse() }.buttonStyle(PanelButtonStyle(prominent: session.candidates.isEmpty))
            }
            HStack(spacing: 10) {
                Text("Try").foregroundStyle(Theme.textDim)
                ForEach(WXFormatKind.allCases.filter { WXEncoders.available($0) && !($0 == .jpegMask && !session.hasAlpha) }) { k in
                    Toggle2(label: k == .ultraPNG ? "Ultra PNG" : (k == .ultraPNGLossless ? "PNG lossless" : k.rawValue),
                            on: Binding(get: { session.enabled.contains(k) }, set: { v in if v { session.enabled.insert(k) } else { session.enabled.remove(k) }; session.invalidate() }))
                }
            }
            table
            ForEach(WXEncoders.unavailableNotes, id: \.self) { Text($0).font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
            if let g = session.gradient { hint("CSS", g.description + "  " + g.css) }
            if let v = session.vectorNote { hint("SVG", v) }
            Divider()
            HStack(spacing: 10) {
                Text("Responsive set").font(Theme.fontBold)
                Text("shown at").foregroundStyle(Theme.textDim)
                TextField("width", text: $session.displayWidthText).frame(width: 56).onChange(of: session.displayWidthText) { _, _ in session.updateSnippet() }
                Text("CSS px").foregroundStyle(Theme.textDim)
                Toggle2(label: "@1x", on: $session.x1).onChange(of: session.x1) { _, _ in session.updateSnippet() }
                Toggle2(label: "@2x", on: $session.x2).onChange(of: session.x2) { _, _ in session.updateSnippet() }
                Toggle2(label: "@3x", on: $session.x3).onChange(of: session.x3) { _, _ in session.updateSnippet() }
                Text("extra widths").foregroundStyle(Theme.textDim)
                TextField("e.g. 480, 960", text: $session.widthsText).frame(width: 110).onChange(of: session.widthsText) { _, _ in session.updateSnippet() }
                Text("name").foregroundStyle(Theme.textDim)
                TextField("", text: $session.baseName).frame(width: 110).onChange(of: session.baseName) { _, _ in session.updateSnippet() }
            }
            if let d = session.downscaleHint { hint("Size", d) }
            if !session.snippet.isEmpty {
                ScrollView { Text(session.snippet).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6) }
                    .frame(height: 96).background(Theme.fieldBG).clipShape(RoundedRectangle(cornerRadius: 4))
            }
            HStack(spacing: 10) {
                if session.busy {
                    ProgressView(value: session.progress).frame(width: 200)
                    Text(session.stage).font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                    Button("Stop") { session.cancel() }.buttonStyle(PanelButtonStyle())
                }
                Spacer()
                Button("Close") { session.cancel(); AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Copy Snippet") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.snippet, forType: .string) }
                    .buttonStyle(PanelButtonStyle()).disabled(session.snippet.isEmpty)
                Button("Export Selected…") { export() }.buttonStyle(PanelButtonStyle(prominent: !session.candidates.isEmpty)).disabled(session.selected.isEmpty || session.busy)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(width: 900)
        .onAppear { if session.candidates.isEmpty && !session.busy { session.analyse() } }
        .onDisappear { session.cancel() }
    }

    private func hint(_ tag: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(tag).font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 3).fill(Theme.accent.opacity(0.6)))
            Text(text).font(Theme.fontSmall).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("").frame(width: 26)
                Text("Format").frame(width: 170, alignment: .leading)
                Text("Size").frame(width: 80, alignment: .trailing)
                Text("SSIM").frame(width: 60, alignment: .trailing)
                Text("Q").frame(width: 60, alignment: .trailing)
                Text("Settings").frame(width: 210, alignment: .leading).padding(.leading, 12)
                Text("Browser support").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textFaint).padding(.vertical, 3)
            Divider()
            if session.candidates.isEmpty {
                Text(session.busy ? "Encoding every format to the same perceptual quality…" : "Press Analyse.").foregroundStyle(Theme.textFaint).frame(height: 120).frame(maxWidth: .infinity)
            }
            ForEach(session.candidates) { c in
                HStack(spacing: 0) {
                    Image(systemName: session.selected.contains(c.kind) ? "checkmark.square.fill" : "square").frame(width: 26)
                        .foregroundStyle(session.selected.contains(c.kind) ? Theme.accent : Theme.textFaint)
                    HStack(spacing: 4) {
                        Text(c.kind.rawValue).fontWeight(c.kind == session.winner ? .semibold : .regular)
                        if c.kind == session.winner { Text("smallest").font(.system(size: 8, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1).background(Capsule().fill(Color.green.opacity(0.55))) }
                    }.frame(width: 170, alignment: .leading)
                    Text(WXTransfer.bytes(c.totalBytes)).font(Theme.mono).frame(width: 80, alignment: .trailing)
                    Text(c.lossless ? "lossless" : String(format: "%.4f", c.quality.ssim)).font(Theme.mono).frame(width: 60, alignment: .trailing)
                    Text(c.lossless ? "" : String(format: "%.4f", c.quality.q)).font(Theme.mono).frame(width: 60, alignment: .trailing)
                    Text(c.setting + (c.targetMet ? "" : " — target not reached")).lineLimit(1).foregroundStyle(c.targetMet ? Theme.textDim : Color.orange)
                        .frame(width: 210, alignment: .leading).padding(.leading, 12)
                    Text(c.kind.support).lineLimit(1).foregroundStyle(Theme.textFaint).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 3)
                .background(c.kind == session.winner ? Theme.selection.opacity(0.35) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { session.toggle(c.kind) }
            }
            if let c = session.candidates.first(where: { session.selected.contains($0.kind) }) {
                let t = WXTransfer.estimate(c.data, mime: c.kind.mime)
                Text("\(c.kind.rawValue): \(t.raw) B on disk · as a data: URI \(t.dataURI) B (\(t.dataURIGzip) B after gzip, \(t.dataURIBrotli) B after Brotli) · the file itself gzips to \(t.gzip) B")
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).padding(.top, 4)
            }
        }
    }

    func export() {
        guard let folder = FilesUI.chooseFolder(message: "Choose a folder for the web files") else { return }
        session.export(to: folder) { count, bytes in
            AppModel.shared.setStatus("Exported \(count) web file(s), \(WXTransfer.bytes(bytes)), plus \(session.baseName).html")
            NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("\(session.baseName).html")])
        }
    }
}
