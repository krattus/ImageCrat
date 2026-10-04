import Foundation
import CoreGraphics
import ImageCratCore

/// The scratch PDF for one imported page: a page per piece that has to come from the PDF engine (colour swatches,
/// gradient ramps, images, text blocks for verification, anything rasterized). Pages are cheap to add; only the
/// ones that are actually needed get rendered.
final class PDFVectorPartial {
    let interpreter: PDFVectorInterpreter
    let writer = PDFVectorWriter()
    private let docToPage: CGAffineTransform
    private let mediaBox: CGRect
    private let pageGroup: CGPDFDictionaryRef?
    private var opaqueState: String? = nil
    private var extraCount = 0
    private var document: CGPDFDocument? = nil
    /// Palette index → (scratch page, cell).
    private var paletteCells: [(page: Int, cell: Int)] = []
    private var palettePages: [(page: Int, count: Int)] = []
    private static let paletteRow = 2048

    init(_ interpreter: PDFVectorInterpreter) {
        self.interpreter = interpreter
        docToPage = interpreter.pageToDoc.inverted()
        // everything the document shows, in page space (the scratch pages are never cropped tighter than that)
        mediaBox = interpreter.canvas.applying(docToPage).insetBy(dx: -2, dy: -2)
        pageGroup = interpreter.page.dictionary.flatMap { PDFVectorObj.dict($0, "Group") }
        if let cat = interpreter.document.catalog, let oc = PDFVectorObj.dict(cat, "OCProperties") {
            // optional content keeps its default visibility inside replayed pieces
            writer.catalogEntries = " /OCProperties " + writer.ref(oc)
        }
    }

    // MARK: Preamble

    private func name(_ prefix: String) -> String { extraCount += 1; return "PV\(prefix)\(extraCount)" }

    private func colorOps(_ c: PDFVectorColorState, stroke: Bool, extra: inout [String: [String: String]]) -> String {
        let comps = c.components.map { PDFVectorWriter.number($0) }.joined(separator: " ")
        var pattern = ""
        if let p = c.patternObject {
            let n = name("P")
            extra["Pattern", default: [:]][n] = writer.value(p)
            pattern = " /\(n)"
        }
        if let sp = c.space {
            let n = name("C")
            extra["ColorSpace", default: [:]][n] = writer.value(sp)
            var s = "/\(n) \(stroke ? "CS" : "cs")"
            if !comps.isEmpty || !pattern.isEmpty { s += " \(comps)\(pattern) \(stroke ? "SCN" : "scn")" }
            return s
        }
        switch c.spaceName {
        case "DeviceRGB" where c.components.count == 3: return comps + (stroke ? " RG" : " rg")
        case "DeviceCMYK" where c.components.count == 4: return comps + (stroke ? " K" : " k")
        case "Pattern": return "/Pattern \(stroke ? "CS" : "cs")" + (pattern.isEmpty ? "" : "\(pattern) \(stroke ? "SCN" : "scn")")
        default: return (c.components.first.map { PDFVectorWriter.number($0) } ?? "0") + (stroke ? " G" : " g")
        }
    }

    /// Operators that put the graphics state into `s`. `emitted` is the CTM (page space) and `clipCount` the number
    /// of `s.clips` already in force.
    private func stateOps(_ s: PDFVectorGState, emitted: inout CGAffineTransform, clipCount: inout Int, extra: inout [String: [String: String]]) -> String {
        var out = ""
        /// A matrix that can be undone: `cm` only concatenates, so leaving a CTM takes its inverse.
        func invertible(_ t: CGAffineTransform) -> Bool {
            let det = t.a * t.d - t.b * t.c
            let size = max(hypot(t.a, t.b), hypot(t.c, t.d))
            return det.isFinite && size.isFinite && size > 0 && abs(det) > 1e-7 * size * size
        }
        func setCTM(_ target: CGAffineTransform) {
            guard invertible(emitted) else { return }
            let m = target.concatenating(emitted.inverted())
            if !m.isIdentity { out += PDFVectorWriter.matrix(m) + " cm\n" }
            emitted = target
        }
        if s.clips.count > clipCount {
            setCTM(.identity)
            for id in s.clips[clipCount...] where id < interpreter.clips.count {
                out += PDFVectorGeometry.pathOperators(interpreter.clips[id].path, docToPage) + "W n\n"
            }
            clipCount = s.clips.count
        }
        for e in s.extStates {
            // only a soft mask depends on the CTM it was set under; everything else is replayed where we are, so a
            // degenerate matrix met on the way cannot strand the rest of the state
            let t = e.ctm.concatenating(docToPage)
            if PDFVectorObj.dict(e.dict, "SMask") != nil, invertible(t) { setCTM(t) }
            let n = name("G")
            extra["ExtGState", default: [:]][n] = writer.ref(e.dict)
            out += "/\(n) gs\n"
        }
        setCTM(s.ctm.concatenating(docToPage))
        out += "\(PDFVectorWriter.number(s.lineWidth)) w \(s.lineCap) J \(s.lineJoin) j \(PDFVectorWriter.number(s.miterLimit)) M "
        out += "[" + s.dash.map { PDFVectorWriter.number($0) }.joined(separator: " ") + "] \(PDFVectorWriter.number(s.dashPhase)) d\n"
        out += colorOps(s.fill, stroke: false, extra: &extra) + "\n" + colorOps(s.stroke, stroke: true, extra: &extra) + "\n"
        if let f = s.font {
            let n = name("F")
            extra["Font", default: [:]][n] = writer.ref(f.dict)
            out += "/\(n) \(PDFVectorWriter.number(s.fontSize)) Tf "
        }
        out += "\(PDFVectorWriter.number(s.charSpace)) Tc \(PDFVectorWriter.number(s.wordSpace)) Tw \(PDFVectorWriter.number(s.hScale * 100)) Tz "
        out += "\(PDFVectorWriter.number(s.leading)) TL \(s.renderMode) Tr \(PDFVectorWriter.number(s.rise)) Ts\n"
        return out
    }

    // MARK: Pages

    /// Adds a page that replays `slice` with the graphics state it started in. Returns the page index.
    func add(_ slice: PDFVectorSlice) -> Int {
        let stream = interpreter.streams[slice.stream]
        var extra: [String: [String: String]] = [:]
        var pre = ""
        var emitted = CGAffineTransform.identity
        var clipCount = 0
        for s in slice.stack {
            pre += stateOps(s, emitted: &emitted, clipCount: &clipCount, extra: &extra) + "q\n"
        }
        pre += stateOps(slice.state, emitted: &emitted, clipCount: &clipCount, extra: &extra)
        if slice.opaque {
            if opaqueState == nil { opaqueState = "\(writer.add("<< /Type /ExtGState /ca 1 /CA 1 /BM /Normal >>")) 0 R" }
            extra["ExtGState", default: [:]]["PVOpaque"] = opaqueState
            pre += "/PVOpaque gs\n"
        }
        if slice.inText {
            pre += "BT\n" + PDFVectorWriter.matrix(slice.lineMatrix) + " Tm\n"
            // the text position is the line start moved along the baseline (shows advance it; nothing else can)
            let l = slice.lineMatrix, t = slice.textMatrix
            let n2 = l.a * l.a + l.b * l.b
            let adv = slice.state.fontSize * slice.state.hScale
            if n2 > 1e-18, abs(adv) > 1e-9 {
                let dx = ((t.tx - l.tx) * l.a + (t.ty - l.ty) * l.b) / n2
                if abs(dx) > 1e-9 { pre += "[\(PDFVectorWriter.number(Double(-dx) * 1000 / adv))] TJ\n" }
            }
        }
        // names the replayed bytes use, and how they leave text objects / saved states open
        let replay = slice.synthetic ?? Array(stream.bytes[slice.range])
        var lx = PDFVectorLexer(replay)
        var used = Set<String>()
        var inText = slice.inText
        var depth = 0
        func collect(_ o: PDFVectorOperand) {
            switch o {
            case .name(let n): used.insert(n)
            case .array(let a): for e in a.prefix(64) { collect(e) }
            case .dict(let d): for (_, v) in d { collect(v) }
            default: break
            }
        }
        while lx.next() {
            for o in lx.operands { collect(o) }
            if let d = lx.inlineImage { for (_, v) in d { collect(v) } }
            switch lx.op {
            case PDFVectorOp.BT: inText = true
            case PDFVectorOp.ET: inText = false
            case PDFVectorOp.q: depth += 1
            case PDFVectorOp.Q: depth -= 1
            default: break
            }
        }
        var post = "\n"
        if inText { post += "ET\n" }
        if depth > 0 { post += String(repeating: "Q\n", count: min(depth, 512)) }
        if slice.stream == interpreter.annotationStream {
            for (n, s) in interpreter.annotationForms where used.contains(n) { extra["XObject", default: [:]][n] = writer.ref(s) }
        }
        var content = Data(pre.utf8)
        content.append(contentsOf: replay)
        content.append(Data(post.utf8))
        let res = writer.resources(from: stream.resources, used: used, extra: extra)
        return addPage(box: mediaBox, resources: res, content: content, chain: slice.chain)
    }

    /// Adds a page whose content is drawn inside copies of the transparency groups of `chain` (so colours take the
    /// same route to RGB as on the source page), on a page with the source page's own group.
    private func addPage(box: CGRect, resources: Int, content: Data, chain: Int) -> Int {
        var res = resources
        var body = content
        let groups = chain < interpreter.chains.count ? interpreter.chains[chain] : []
        let bbox = "[\(PDFVectorWriter.number(box.minX)) \(PDFVectorWriter.number(box.minY)) \(PDFVectorWriter.number(box.maxX)) \(PDFVectorWriter.number(box.maxY))]"
        for g in groups.reversed() {
            let form = writer.addStream(dict: "/Type /XObject /Subtype /Form /BBox \(bbox) /Group \(writer.ref(g)) /Resources \(res) 0 R", data: body)
            res = writer.add("<< /XObject << /PVW \(form) 0 R >> >>")
            body = Data("/PVW Do\n".utf8)
        }
        return writer.addPage(box: box, resources: res, content: body, group: pageGroup)
    }

    /// Adds swatch pages for the interpreter's colours (one unit square per colour, grouped by transparency chain).
    func addPalette() {
        let colors = interpreter.colors
        paletteCells = [(page: Int, cell: Int)](repeating: (-1, 0), count: colors.count)
        var byChain: [Int: [Int]] = [:]
        for (i, c) in colors.enumerated() { byChain[c.chain, default: []].append(i) }
        for (chain, list) in byChain.sorted(by: { $0.key < $1.key }) {
            var i = 0
            while i < list.count {
                let n = min(PDFVectorPartial.paletteRow, list.count - i)
                var extra: [String: [String: String]] = [:]
                var content = ""
                for k in 0..<n {
                    content += "q " + colorOps(colors[list[i + k]], stroke: false, extra: &extra) + " \(k) 0 1 1 re f Q\n"
                }
                let res = writer.resources(from: nil, used: nil, extra: extra)
                let page = addPage(box: CGRect(x: 0, y: 0, width: n, height: 1), resources: res, content: Data(content.utf8), chain: chain)
                palettePages.append((page, n))
                for k in 0..<n { paletteCells[list[i + k]] = (page, k) }
                i += n
            }
        }
    }

    /// Adds a 256 × 1 page showing a gradient's colours from start to end (pixel i = position i / 255).
    func addRamp(_ g: PDFVectorGradient) -> Int? {
        guard let fn = PDFVectorObj.object(g.shading, "Function"), let cs = PDFVectorObj.object(g.shading, "ColorSpace") else { return nil }
        var dict = "<< /ShadingType 2 /ColorSpace \(writer.value(cs)) /Coords [0.5 0 255.5 0] /Function \(writer.value(fn)) /Extend [true true]"
        if let dom = PDFVectorObj.object(g.shading, "Domain") { dict += " /Domain \(writer.value(dom))" }
        let sh = writer.add(dict + " >>")
        let res = writer.resources(from: nil, used: nil, extra: ["Shading": ["PVS": "\(sh) 0 R"]])
        return addPage(box: CGRect(x: 0, y: 0, width: 256, height: 1), resources: res, content: Data("/PVS sh\n".utf8), chain: g.chain)
    }

    /// Adds a page that fills the document white through a soft mask: the alpha of its rendering is the mask.
    func addMask(_ m: PDFVectorSoftMask) -> Int {
        let t = m.ctm.concatenating(docToPage)
        let n = name("G")
        var content = PDFVectorWriter.matrix(t) + " cm /\(n) gs " + PDFVectorWriter.matrix(t.inverted()) + " cm\n1 g "
        content += "\(PDFVectorWriter.number(mediaBox.minX)) \(PDFVectorWriter.number(mediaBox.minY)) \(PDFVectorWriter.number(mediaBox.width)) \(PDFVectorWriter.number(mediaBox.height)) re f\n"
        let res = writer.resources(from: nil, used: nil, extra: ["ExtGState": [n: writer.ref(m.state)]])
        return writer.addPage(box: mediaBox, resources: res, content: Data(content.utf8), group: pageGroup)
    }

    // MARK: Rendering

    /// Closes the scratch file. False when it could not be built (the caller then imports the page flattened).
    func finish() -> Bool {
        if writer.pageCount == 0 { return true }
        guard let data = writer.finish() else { return false }
        if let dump = ProcessInfo.processInfo.environment["LUMEN_PDFIMPORT_DUMP"] { try? data.write(to: URL(fileURLWithPath: dump)) }   // the scratch file, for debugging
        guard let prov = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(prov), doc.numberOfPages == writer.pageCount else { return false }
        document = doc
        return true
    }

    /// Draws a scratch page into a context whose CTM maps document pixels (y down) to the device.
    func draw(_ page: Int, in ctx: CGContext) {
        guard let p = document?.page(at: page + 1) else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.concatenate(interpreter.pageToDoc)
        ctx.drawPDFPage(p)
        ctx.restoreGState()
    }

    /// Pixels (premultiplied RGBA, sRGB) of a small scratch page at one pixel per unit.
    private func pixels(_ page: Int, width: Int) -> [UInt8]? {
        guard let p = document?.page(at: page + 1), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { return nil }
        ctx.setShouldAntialias(false)
        ctx.interpolationQuality = .none
        ctx.drawPDFPage(p)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * 4))
    }

    /// sRGB components (0…1) of every palette colour, in the interpreter's order.
    func paletteColors() -> [(r: Double, g: Double, b: Double)] {
        var rows: [Int: [UInt8]] = [:]
        for (page, n) in palettePages { rows[page] = pixels(page, width: n) }
        return paletteCells.map { cell in
            guard let px = rows[cell.page], cell.cell * 4 + 3 < px.count else { return (0, 0, 0) }
            let a = Double(px[cell.cell * 4 + 3])
            if a <= 0 { return (0, 0, 0) }
            return (Double(px[cell.cell * 4]) / a, Double(px[cell.cell * 4 + 1]) / a, Double(px[cell.cell * 4 + 2]) / a)
        }
    }

    /// 256 sRGB samples of a ramp page.
    func ramp(_ page: Int) -> [(r: Double, g: Double, b: Double)]? {
        guard let px = pixels(page, width: 256) else { return nil }
        return (0..<256).map { k in
            let a = max(1, Double(px[k * 4 + 3]))
            return (Double(px[k * 4]) / a, Double(px[k * 4 + 1]) / a, Double(px[k * 4 + 2]) / a)
        }
    }
}
