import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import Observation
import ImageCratCore

/// "Describe Image" and alt text on export. Florence-2 writes the caption (Vision labels when it is not installed),
/// Vision contributes keywords, OCR text and faces; the result is editable and written to the file's XMP / IPTC
/// description, copied to the clipboard or wrapped in an `<img>` snippet.
enum AssistDescribe {
    struct Description {
        var caption = ""
        var detailed = ""
        var objects: [(label: String, count: Int)] = []
        var text: [String] = []
        var colors: [AssistColor.Swatch] = []
        var keywords: [String] = []
        var engine = ""
        var seconds = 0.0

        /// Alt text: the detailed caption trimmed to whole sentences, plus prominent text — about 250 characters in all.
        var altText: String {
            let full = detailed.isEmpty ? caption : detailed
            let prominent = text.prefix(2).joined(separator: " ")
            var clause = ""
            if !prominent.isEmpty, prominent.count <= 80, !full.lowercased().contains(prominent.lowercased()) { clause = " Text reads: “\(prominent)”." }
            let budget = 255 - clause.count
            var s = full
            if s.count > budget {
                var out = ""
                for sentence in s.components(separatedBy: ". ") {
                    let next = out.isEmpty ? sentence : out + ". " + sentence
                    if next.count > budget, !out.isEmpty { break }
                    out = next
                    if out.count > budget { break }
                }
                s = out.count > budget + 40 ? Assist.truncate(out, budget) : (out.hasSuffix(".") ? out : out + ".")
            }
            return s + clause
        }

        /// Plain-text report for the Copy button.
        var report: String {
            var lines: [String] = []
            if !caption.isEmpty { lines.append("Caption: \(caption)") }
            if !detailed.isEmpty, detailed != caption { lines.append("Description: \(detailed)") }
            if !objects.isEmpty { lines.append("Objects: " + objects.map { $0.count > 1 ? "\($0.label) ×\($0.count)" : $0.label }.joined(separator: ", ")) }
            if !text.isEmpty { lines.append("Text: " + text.joined(separator: " / ")) }
            if !colors.isEmpty { lines.append("Colours: " + colors.map { "\($0.name) #\($0.color.hex) \(Int(($0.fraction * 100).rounded()))%" }.joined(separator: ", ")) }
            if !keywords.isEmpty { lines.append("Keywords: " + keywords.joined(separator: ", ")) }
            return lines.joined(separator: "\n")
        }
    }

    /// Full description of an image. Call off the main thread.
    static func describe(_ cg: CGImage, detailed: Bool = true, useFlorence: Bool = true) -> Description {
        let t0 = CFAbsoluteTimeGetCurrent()
        var d = Description()
        let small = NImg.fitted(cg, maxSide: 1024)
        let labels = AssistVision.classify(small, max: 14, minConfidence: 0.18)
        d.colors = AssistColor.dominant(small, max: 5)
        d.text = AssistVision.ocr(small).filter { $0.confidence > 0.35 }.map(\.text)
        let florence = useFlorence && AssistCaptioner.shared.isAvailable
        if florence {
            if let c = try? AssistCaptioner.shared.generate(small, task: .caption) { d.caption = AssistText.cleanCaption(c) }
            if detailed, let c = try? AssistCaptioner.shared.generate(small, task: .detailed) { d.detailed = AssistText.cleanCaption(c) }
            if let regions = try? Florence2Grounder.shared.ground(SegImage(image: CIImage(cgImage: small), width: small.width, height: small.height, id: "assist-od"), text: "", task: .objectDetection) {
                var counts: [String: Int] = [:]
                var order: [String] = []
                for r in regions where !r.label.isEmpty {
                    let l = r.label.lowercased()
                    if counts[l] == nil { order.append(l) }
                    counts[l, default: 0] += 1
                }
                d.objects = order.map { ($0, counts[$0]!) }
            }
            d.engine = "Florence-2 + Vision"
        } else {
            d.engine = "Vision"
        }
        if d.objects.isEmpty {
            var obj: [(String, Int)] = []
            let faces = AssistVision.faces(small).count, people = AssistVision.humans(small).count
            if max(faces, people) > 0 { obj.append(("person", max(faces, people))) }
            var animals: [String: Int] = [:]
            for a in AssistVision.animals(small) { animals[a.label, default: 0] += 1 }
            obj += animals.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            for l in labels where !AssistVision.genericLabels.contains(l.label) && l.confidence > 0.4 && obj.count < 8 && !obj.contains(where: { $0.0 == l.label }) { obj.append((l.label, 1)) }
            d.objects = obj
        }
        if d.caption.isEmpty {
            // Vision-only caption: "Beach, ocean and sky" + people / text hints
            let specific = labels.filter { !AssistVision.genericLabels.contains($0.label) }.prefix(3).map(\.label)
            var parts = specific.isEmpty ? labels.prefix(2).map(\.label) : Array(specific)
            if let p = d.objects.first(where: { $0.label == "person" }) { parts.insert(p.count == 1 ? "a person" : "\(p.count) people", at: 0) }
            var s: String
            switch parts.count {
            case 0: s = "An image"
            case 1: s = parts[0]
            default: s = parts.dropLast().joined(separator: ", ") + " and " + parts.last!
            }
            if let c = d.colors.first { s += " in \(c.name.lowercased()) tones" }
            d.caption = AssistText.cleanCaption(s)
        }
        if d.detailed.isEmpty { d.detailed = d.caption }
        // keywords: Vision labels + detected objects, most confident first
        var kw: [String] = []
        for o in d.objects where !kw.contains(o.label) { kw.append(o.label) }
        let junk: Set<String> = ["structure", "liquid", "material", "conveyance", "machine", "textile", "decoration", "colorfulness", "abstract", "pattern", "light", "land"]
        for l in labels where l.confidence >= 0.4 && !kw.contains(l.label) && !junk.contains(l.label) { kw.append(l.label) }
        d.keywords = Array(kw.prefix(14))
        d.seconds = CFAbsoluteTimeGetCurrent() - t0
        return d
    }
}

// MARK: - Metadata

enum AssistMetadata {
    enum MetaError: LocalizedError {
        case unreadable, unwritable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The exported file could not be read back."
            case .unwritable(let m): return "The description could not be written to the file (\(m))."
            }
        }
    }

    static let iptcCoreNS = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"

    /// Writes `altText` and `keywords` into an existing image file: XMP dc:description / dc:subject,
    /// Iptc4xmpCore:AltTextAccessibility, IPTC-IIM Caption-Abstract / Keywords and TIFF ImageDescription.
    /// Pixel data is not re-encoded when the format allows a metadata-only rewrite.
    static func write(altText: String, keywords: [String], to url: URL) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else { throw MetaError.unreadable }
        let meta: CGMutableImageMetadata
        if let existing = CGImageSourceCopyMetadataAtIndex(src, 0, nil), let copy = CGImageMetadataCreateMutableCopy(existing) { meta = copy } else { meta = CGImageMetadataCreateMutable() }
        CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract, altText as CFString)
        CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, altText as CFString)
        if !keywords.isEmpty {
            CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCKeywords, keywords as CFArray)
        }
        if !keywords.isEmpty, CGImageMetadataCopyTagWithPath(meta, nil, "dc:subject" as CFString) == nil {
            CGImageMetadataSetValueWithPath(meta, nil, "dc:subject" as CFString, keywords as CFArray)
        }
        CGImageMetadataRegisterNamespaceForPrefix(meta, iptcCoreNS as CFString, "Iptc4xmpCore" as CFString, nil)
        CGImageMetadataSetValueWithPath(meta, nil, "Iptc4xmpCore:AltTextAccessibility" as CFString, altText as CFString)

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { throw MetaError.unwritable("destination") }
        let opts: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: true]
        var err: Unmanaged<CFError>?
        if CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, &err) {
            try (data as Data).write(to: url, options: .atomic)
            return
        }
        // formats without lossless metadata rewrite: re-encode once with the metadata attached
        guard let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw MetaError.unreadable }
        let data2 = NSMutableData()
        guard let dest2 = CGImageDestinationCreateWithData(data2, type, 1, nil) else { throw MetaError.unwritable("destination") }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
        CGImageDestinationAddImageAndMetadata(dest2, img, meta, props)
        guard CGImageDestinationFinalize(dest2) else { throw MetaError.unwritable(err?.takeRetainedValue().localizedDescription ?? "encode") }
        try (data2 as Data).write(to: url, options: .atomic)
    }

    struct Readback {
        var iptcCaption: String?
        var xmpDescription: String?
        var altTextAccessibility: String?
        var tiffDescription: String?
        var keywords: [String] = []
    }

    static func read(_ url: URL) -> Readback {
        var r = Readback()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return r }
        if let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if let iptc = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
                r.iptcCaption = iptc[kCGImagePropertyIPTCCaptionAbstract] as? String
                r.keywords = iptc[kCGImagePropertyIPTCKeywords] as? [String] ?? []
            }
            if let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { r.tiffDescription = tiff[kCGImagePropertyTIFFImageDescription] as? String }
        }
        if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
            r.xmpDescription = CGImageMetadataCopyStringValueWithPath(meta, nil, "dc:description" as CFString) as String?
            r.altTextAccessibility = CGImageMetadataCopyStringValueWithPath(meta, nil, "Iptc4xmpCore:AltTextAccessibility" as CFString) as String?
            if r.keywords.isEmpty, let tag = CGImageMetadataCopyTagWithPath(meta, nil, "dc:subject" as CFString), let arr = CGImageMetadataTagCopyValue(tag) as? [Any] {
                r.keywords = arr.compactMap { v in
                    if let s = v as? String { return s }
                    if CFGetTypeID(v as CFTypeRef) == CGImageMetadataTagGetTypeID() { return CGImageMetadataTagCopyValue(v as! CGImageMetadataTag) as? String }
                    return nil
                }
            }
        }
        return r
    }

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func htmlSnippet(file: String, alt: String, width: Int, height: Int) -> String {
        "<img src=\"\(htmlEscape(file))\" alt=\"\(htmlEscape(alt))\" width=\"\(width)\" height=\"\(height)\">"
    }

    /// Exports the document and embeds the description. Returns the HTML snippet.
    @discardableResult
    static func export(_ st: DocumentState, to url: URL, format: ExportFormat, quality: Double, scale: Double = 1, altText: String, keywords: [String]) throws -> String {
        try DocumentIO.export(st, to: url, format: format, quality: quality, scale: scale, background: format.supportsAlpha ? nil : .white)
        try write(altText: altText, keywords: keywords, to: url)
        return htmlSnippet(file: url.lastPathComponent, alt: altText, width: Int(Double(st.width) * scale), height: Int(Double(st.height) * scale))
    }
}

// MARK: - Dialogs

@Observable
final class AssistDescribeModel {
    var d: AssistDescribe.Description?
    var running = false
    var alt = ""
    var keywords = ""

    func run(detailed: Bool = true) {
        guard let doc = AppActions.doc, let cg = Assist.compositeCG(doc.state, maxSide: 1536) else { return }
        running = true
        Task.detached(priority: .userInitiated) {
            let r = AssistDescribe.describe(cg, detailed: detailed)
            await MainActor.run { self.set(r) }
        }
    }

    func set(_ r: AssistDescribe.Description) {
        d = r
        alt = r.altText
        keywords = r.keywords.joined(separator: ", ")
        running = false
    }

    var keywordList: [String] { keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}

struct AssistDescribeDialog: View {
    @State private var m: AssistDescribeModel
    init(model: AssistDescribeModel = AssistDescribeModel()) { _m = State(initialValue: model) }

    var body: some View {
        DialogFrame(title: "Describe Image", width: 460, okTitle: "Copy", onOK: { if let d = m.d { Assist.copyToClipboard(d.report) } },
                    extraButtons: AnyView(Button("Copy Caption") { if let d = m.d { Assist.copyToClipboard(d.caption) } }.buttonStyle(PanelButtonStyle()).disabled(m.d == nil))) {
            if let d = m.d {
                section("Caption") { Text(tr(d.caption)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                if d.detailed != d.caption {
                    section("Description") { Text(tr(d.detailed)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                }
                if !d.objects.isEmpty {
                    section("Objects") { Text(tr(d.objects.map { $0.count > 1 ? "\($0.label) ×\($0.count)" : $0.label }.joined(separator: " · "))).textSelection(.enabled) }
                }
                if !d.text.isEmpty {
                    section("Text in image") { Text(tr(d.text.prefix(8).joined(separator: "\n"))).textSelection(.enabled).lineLimit(8) }
                }
                section("Colours") {
                    HStack(spacing: 8) {
                        ForEach(Array(d.colors.enumerated()), id: \.offset) { _, c in
                            HStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: c.color.nsColor)).frame(width: 14, height: 14).overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.border))
                                Text("\(c.name) \(Int((c.fraction * 100).rounded()))%").font(Theme.fontSmall)
                            }
                        }
                    }
                }
                if !d.keywords.isEmpty { section("Keywords") { Text(tr(d.keywords.joined(separator: ", "))).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } }
                Text(tr(String(format: "%@ · on-device · %.1f s", d.engine, d.seconds))).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Looking at the image…").foregroundStyle(Theme.textDim) }
            }
        }
        .onAppear { if m.d == nil { m.run() } }
    }

    @ViewBuilder func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) { Caption(title); content().font(Theme.font) }
    }
}

struct AssistAltExportDialog: View {
    @State private var m: AssistDescribeModel
    init(model: AssistDescribeModel = AssistDescribeModel()) { _m = State(initialValue: model) }
    @State private var format: ExportFormat = .jpeg
    @State private var quality: Double = 90
    @State private var copyAlt = true
    @State private var copyHTML = false

    var body: some View {
        DialogFrame(title: "Export with Alt Text", width: 460, okTitle: "Export…", onOK: export,
                    extraButtons: AnyView(HStack(spacing: 6) {
            Button("Copy Alt Text") { Assist.copyToClipboard(m.alt) }.buttonStyle(PanelButtonStyle())
            Button("Copy HTML") { Assist.copyToClipboard(snippet(file: fileName)) }.buttonStyle(PanelButtonStyle())
        })) {
            HStack {
                Caption("Alt text")
                Spacer()
                if m.running { ProgressView().controlSize(.mini) }
                Button("Short") { if let d = m.d { m.alt = d.caption } }.buttonStyle(PanelButtonStyle()).disabled(m.d == nil)
                Button("Detailed") { if let d = m.d { m.alt = d.altText } }.buttonStyle(PanelButtonStyle()).disabled(m.d == nil)
                Button("Regenerate") { m.run() }.buttonStyle(PanelButtonStyle()).disabled(m.running)
            }
            TextEditor(text: $m.alt).font(Theme.font).frame(height: 84)
                .scrollContentBackground(.hidden).padding(4).background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
            Text(tr("\(m.alt.count) characters" + (m.alt.count > 250 ? " — screen readers work best under ~250" : ""))).font(Theme.fontSmall).foregroundStyle(m.alt.count > 250 ? Color.orange : Theme.textFaint)
            Caption("Keywords")
            TextField("comma separated", text: $m.keywords).textFieldStyle(.plain).font(Theme.font)
                .padding(4).background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
            HStack {
                Picker("Format", selection: $format) { ForEach([ExportFormat.jpeg, .png, .tiff, .heic]) { Text(tr($0.rawValue)).tag($0) } }.frame(width: 170)
                if format.supportsQuality { ValueSlider(label: "Quality", value: $quality, range: 1...100, unit: "%", labelWidth: 46) }
            }
            HStack { Toggle2(label: "Copy alt text to the clipboard", on: $copyAlt); Toggle2(label: "Copy <img> snippet instead", on: $copyHTML) }
            Text(tr("Written to XMP dc:description, IPTC Alt Text (Accessibility), IPTC Caption and keywords. Generated on this Mac"
                 + (AssistCaptioner.shared.isAvailable ? " with Florence-2." : " from Vision labels (install Florence-2 for full sentences).")))
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if m.d == nil { m.run() } }
    }

    var fileName: String { ((AppActions.doc?.name ?? "image") as NSString).deletingPathExtension + "." + format.ext }

    func snippet(file: String) -> String {
        let d = AppActions.doc
        return AssistMetadata.htmlSnippet(file: file, alt: m.alt, width: d?.state.width ?? 0, height: d?.state.height ?? 0)
    }

    func export() {
        guard let d = AppActions.doc else { return }
        let st = d.state, fmt = format, q = quality / 100, alt = m.alt, kw = m.keywordList, html = copyHTML, copy = copyAlt
        let p = NSSavePanel()
        p.allowedContentTypes = [fmt.utType]
        p.nameFieldStringValue = fileName
        p.begin { r in
            guard r == .OK, let url = p.url else { return }
            do {
                let snippet = try AssistMetadata.export(st, to: url, format: fmt, quality: q, altText: alt, keywords: kw)
                if html { Assist.copyToClipboard(snippet) } else if copy { Assist.copyToClipboard(alt) }
                AppModel.shared.setStatus("Exported \(url.lastPathComponent) with alt text" + (html ? " (HTML snippet copied)." : (copy ? " (alt text copied)." : ".")))
            } catch { AppActions.alert("Export failed.", error.localizedDescription) }
        }
    }
}
