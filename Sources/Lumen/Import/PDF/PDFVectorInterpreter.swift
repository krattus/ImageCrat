import Foundation
import CoreGraphics
import ImageCratCore

/// Walks a page's content stream (and the form XObjects it draws) and records what is painted as a display list
/// of shapes, text blocks and pieces to be rendered from the PDF itself. Nothing is drawn here.
final class PDFVectorInterpreter {
    enum Abort: Error {
        /// The current stream uses something that cannot be followed object by object: render it as a whole.
        case rasterizeStream(String)
        /// The page is beyond what the importer handles.
        case limit(String)
    }

    struct Stream {
        var bytes: [UInt8]
        var resources: CGPDFDictionaryRef?
    }

    let document: CGPDFDocument
    let page: CGPDFPage
    /// Page space (default user space, y up) → document pixels (y down).
    let pageToDoc: CGAffineTransform
    let canvas: CGRect
    var limits = PDFVectorLimits()

    private(set) var streams: [Stream] = []
    private(set) var items: [PDFVectorItem] = []
    private(set) var clips: [PDFVectorClip] = []
    private(set) var forms: [PDFVectorFormInstance] = []
    private(set) var ocgs: [PDFVectorOCG] = []
    private(set) var colors: [PDFVectorColorState] = []
    private(set) var gradients: [PDFVectorGradient] = []
    private(set) var softMasks: [PDFVectorSoftMask] = []
    /// Chains of enclosing transparency groups (outermost first), as /Group dictionaries. Chain 0 is the page itself.
    /// A colour converts to RGB through the blending colour spaces of the groups it is painted in, so swatches and
    /// replayed pieces are rendered inside the same chain.
    private(set) var chains: [[CGPDFDictionaryRef]] = [[]]
    private var chain = 0
    var report = PDFVectorReport()
    /// Number of paths painted (before merging).
    private(set) var pathCount = 0

    private var colorIndex: [String: Int] = [:]
    private var gs: PDFVectorGState
    private var stack: [PDFVectorGState] = []
    private var fonts: [Int: PDFVectorFont] = [:]
    private var ocgIndex: [Int: Int] = [:]
    private var hiddenOCGs = Set<Int>()
    private var opCount = 0
    /// Items below this index are closed for merging (they belong to an enclosing stream).
    private var mergeBarrier = 0
    private var banding = false
    private var activeStreams: [Int] = []
    private var openText: PDFVectorText? = nil
    /// Set where a throw is not possible; the stream being interpreted is then rendered as a whole.
    private var pendingAbort: String? = nil

    private final class Level {
        let stream: Int
        var lexer: PDFVectorLexer
        let resources: CGPDFDictionaryRef?
        let baseContext: [PDFVectorContext]
        let baseClipCount: Int
        let baseCTM: CGAffineTransform
        let depth: Int
        let stackBase: Int
        var marked: [Int?] = []
        /// Parallel to `marked`: true for an /OC section whose property list does not resolve. Core Graphics saves
        /// the graphics state twice when such a section starts and restores it twice at its EMC.
        var markedRestore: [Bool] = []
        /// Set inside a hidden optional-content section: the state and saved-state stack as Core Graphics sees
        /// them (only q / Q applied), restored when the section ends.
        var hidden: (gs: PDFVectorGState, stack: [PDFVectorGState], inText: Bool, tm: CGAffineTransform, tlm: CGAffineTransform,
                     path: CGMutablePath?, pathStart: Int, pathPoints: Int, current: CGPoint, subpathStart: CGPoint)? = nil
        var path: CGMutablePath? = nil
        var pathStart = 0
        var pathPoints = 0
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var inText = false
        var tm = CGAffineTransform.identity
        var tlm = CGAffineTransform.identity
        var tmKnown = true
        var bandStart: Int? = nil
        var bandState: PDFVectorGState? = nil
        var bandStack: [PDFVectorGState] = []
        var bandContext: [PDFVectorContext] = []
        var bandChain = 0
        var bandInText = false
        var bandTM = CGAffineTransform.identity
        var bandTLM = CGAffineTransform.identity

        init(stream: Int, bytes: [UInt8], resources: CGPDFDictionaryRef?, baseContext: [PDFVectorContext], baseClipCount: Int,
             baseCTM: CGAffineTransform, depth: Int, stackBase: Int) {
            self.stream = stream; lexer = PDFVectorLexer(bytes); self.resources = resources; self.baseContext = baseContext
            self.baseClipCount = baseClipCount; self.baseCTM = baseCTM; self.depth = depth; self.stackBase = stackBase
        }
    }

    init(document: CGPDFDocument, page: CGPDFPage, pageToDoc: CGAffineTransform, width: Int, height: Int) {
        self.document = document
        self.page = page
        self.pageToDoc = pageToDoc
        canvas = CGRect(x: 0, y: 0, width: width, height: height)
        gs = PDFVectorGState(ctm: pageToDoc)
        readOptionalContent()
    }

    // MARK: Entry

    /// Resources of the page, following /Parent for inherited ones.
    static func pageResources(_ page: CGPDFPage) -> CGPDFDictionaryRef? {
        guard var d = page.dictionary else { return nil }
        for _ in 0..<64 {
            if let r = PDFVectorObj.dict(d, "Resources") { return r }
            guard let p = PDFVectorObj.dict(d, "Parent") else { return nil }
            d = p
        }
        return nil
    }

    /// Interprets the page. On return `items` holds the display list; a page that cannot be followed at all ends
    /// up as a single whole-page raster item.
    func run() throws {
        let cs = CGPDFContentStreamCreateWithPage(page)
        guard let data = PDFVectorObj.contentData(cs, limit: limits.maxContentBytes) else { throw Abort.limit("the page description is too large") }
        let res = PDFVectorInterpreter.pageResources(page)
        streams.append(Stream(bytes: [UInt8](data), resources: res))
        let level = Level(stream: 0, bytes: streams[0].bytes, resources: res, baseContext: [], baseClipCount: 0, baseCTM: pageToDoc, depth: 0, stackBase: 0)
        activeStreams = [0]
        do {
            try interpret(level)
        } catch Abort.rasterizeStream(let why) {
            // the page itself: one raster of everything
            items.removeAll()
            openText = nil
            var st = PDFVectorGState(ctm: pageToDoc)
            st.clips = []
            let slice = PDFVectorSlice(stream: 0, range: 0..<streams[0].bytes.count, state: st, opaque: false)
            items.append(PDFVectorItem(kind: .raster(PDFVectorRaster(slice: slice, reason: why, name: "Page")), context: [], bounds: canvas))
            report.raster(why)
        }
        try appendAnnotations()
    }

    private func readOptionalContent() {
        guard let cat = document.catalog, let oc = PDFVectorObj.dict(cat, "OCProperties") else { return }
        for o in PDFVectorObj.objects(PDFVectorObj.array(oc, "OCGs")) {
            guard let d = PDFVectorObj.asDict(o) else { continue }
            ocgIndex[PDFVectorObj.id(d)] = ocgs.count
            ocgs.append(PDFVectorOCG(name: PDFVectorObj.string(d, "Name") ?? "Layer \(ocgs.count + 1)", visible: true))
        }
        guard let cfg = PDFVectorObj.dict(oc, "D") else { return }
        if PDFVectorObj.name(cfg, "BaseState") == "OFF" { for i in ocgs.indices { ocgs[i].visible = false } }
        for o in PDFVectorObj.objects(PDFVectorObj.array(cfg, "ON")) {
            if let d = PDFVectorObj.asDict(o), let i = ocgIndex[PDFVectorObj.id(d)] { ocgs[i].visible = true }
        }
        for o in PDFVectorObj.objects(PDFVectorObj.array(cfg, "OFF")) {
            if let d = PDFVectorObj.asDict(o), let i = ocgIndex[PDFVectorObj.id(d)] { ocgs[i].visible = false }
        }
    }

    /// OCG index for the property list of a `/OC … BDC`. The rules are Core Graphics' (it is what PDFKit shows, and
    /// what the flattened import and the rendered pieces follow), which are narrower than the PDF specification's:
    /// only optional-content groups named directly count (membership dictionaries are always visible), only in the
    /// page's own content stream (not inside form XObjects, and not the /OC entry of an XObject). Inside a hidden
    /// section Core Graphics skips every operator except q and Q, and the section ends at the next EMC, whatever
    /// it closes. The hidden artwork is still imported (into a hidden group); what follows it starts from the
    /// graphics state Core Graphics would have, kept in `Level.hidden`.
    private func ocg(for d: CGPDFDictionaryRef) -> Int? { ocgIndex[PDFVectorObj.id(d)] }

    // MARK: Resources

    private func resource(_ level: Level, _ category: String, _ name: String) -> CGPDFObjectRef? {
        guard let res = level.resources, let cat = PDFVectorObj.dict(res, category) else { return nil }
        return PDFVectorObj.object(cat, name)
    }

    private func font(_ d: CGPDFDictionaryRef) -> PDFVectorFont {
        let id = PDFVectorObj.id(d)
        if let f = fonts[id] { return f }
        let f = PDFVectorFont(d)
        fonts[id] = f
        return f
    }

    private func colorRef(_ color: PDFVectorColorState) -> Int {
        var c = color
        c.chain = chain
        let k = c.key
        if let i = colorIndex[k] { return i }
        colors.append(c)
        colorIndex[k] = colors.count - 1
        return colors.count - 1
    }

    // MARK: Context

    private func context(_ level: Level, clips: Bool) -> [PDFVectorContext] {
        var c = level.baseContext
        if !clips { c.removeAll { $0.isClip } }
        for m in level.marked { if let i = m { c.append(.ocg(i)) } }
        if clips, gs.clips.count > level.baseClipCount { for id in gs.clips[level.baseClipCount...] { c.append(.clip(id)) } }
        return c
    }

    private func clipBounds() -> CGRect {
        var r = canvas
        for id in gs.clips { r = r.intersection(clips[id].bounds) }
        return r.isNull ? .zero : r
    }

    // MARK: Bands

    private func beginBand(_ level: Level, at offset: Int) {
        level.bandStart = offset
        level.bandState = gs
        level.bandStack = stack.count > level.stackBase ? Array(stack[level.stackBase...]) : []
        level.bandContext = context(level, clips: false)
        level.bandChain = chain
        level.bandInText = level.inText
        level.bandTM = level.tm
        level.bandTLM = level.tlm
    }

    private func flushBand(_ level: Level, end: Int) {
        guard let s = level.bandStart, let st = level.bandState else { return }
        level.bandStart = nil
        guard end > s else { return }
        var slice = PDFVectorSlice(stream: level.stream, range: s..<end, state: st, stack: level.bandStack, opaque: false)
        slice.chain = level.bandChain
        slice.inText = level.bandInText
        slice.textMatrix = level.bandTM
        slice.lineMatrix = level.bandTLM
        let why = "artwork beyond the layer limit"
        items.append(PDFVectorItem(kind: .raster(PDFVectorRaster(slice: slice, reason: why, name: "Remaining Artwork")), context: level.bandContext, bounds: canvas))
        report.raster(why)
    }

    /// True when the object starting at `start` must not become an item (band mode, or the layer limit was just hit).
    private func skipForBand(_ level: Level, start: Int, adding: Bool) -> Bool {
        if !banding, adding, items.count >= limits.maxItems {
            banding = true
            openText = nil
            report.note("The page has more objects than the layer limit (\(limits.maxItems)); the artwork above that point was rasterized.")
        }
        guard banding else { return false }
        if level.bandStart == nil { beginBand(level, at: start) }
        return true
    }

    // MARK: Interpretation

    private func num(_ a: [PDFVectorOperand], _ i: Int) -> Double {
        guard i < a.count, let n = a[i].number, n.isFinite else { return 0 }
        return n
    }

    private func interpret(_ level: Level) throws {
        let O = PDFVectorOp.self
        while level.lexer.next() {
            opCount += 1
            if opCount > limits.maxOperators { throw Abort.limit("the page has too many drawing operators") }
            if let why = pendingAbort { pendingAbort = nil; throw Abort.rasterizeStream(why) }
            let op = level.lexer.op
            var a = level.lexer.operands
            // Core Graphics takes an operator's operands off the end of the operand list and drops the operator
            // when one has the wrong type (or is missing); surplus operands before them are ignored
            if let n = PDFVectorInterpreter.numericArity[op] {
                guard a.count >= n, a[(a.count - n)...].allSatisfy({ $0.number?.isFinite ?? false }) else { continue }
                if a.count > n { a.removeFirst(a.count - n) }
            }
            switch op {
            // graphics state
            case O.q:
                if stack.count < 4096 { stack.append(gs) }
                if let h = level.hidden, h.stack.count < 4096 { level.hidden?.stack.append(h.gs) }
            case O.Q:
                if stack.count > level.stackBase { gs = stack.removeLast() }
                if let t = openText, stack.count < t.depth { t.closed = true }
                if let h = level.hidden, h.stack.count > level.stackBase, let top = h.stack.last {
                    level.hidden?.gs = top
                    level.hidden?.stack.removeLast()
                }
            case O.cm:
                if a.count >= 6 {
                    let m = CGAffineTransform(a: num(a, 0), b: num(a, 1), c: num(a, 2), d: num(a, 3), tx: num(a, 4), ty: num(a, 5))
                    gs.ctm = m.concatenating(gs.ctm)
                }
            // Core Graphics ignores a line-state operator whose value is out of range (it does not clamp), and wants
            // integers for cap, join and text rendering mode
            case O.w: if !a.isEmpty, num(a, 0) >= 0 { gs.lineWidth = num(a, 0) }
            case O.J: if !a.isEmpty, level.lexer.tailIsInteger, (0...2).contains(num(a, 0)) { gs.lineCap = Int(num(a, 0)) }
            case O.j: if !a.isEmpty, level.lexer.tailIsInteger, (0...2).contains(num(a, 0)) { gs.lineJoin = Int(num(a, 0)) }
            case O.M: if !a.isEmpty, num(a, 0) >= 1 { gs.miterLimit = num(a, 0) }
            case O.d:
                guard a.count >= 2, let arr = a[a.count - 2].array, var phase = a[a.count - 1].number, phase.isFinite else { break }
                let lengths = arr.compactMap { $0.number }
                // a pattern with anything but numbers, a negative length or no length above zero is ignored as a whole
                guard lengths.count == arr.count, lengths.allSatisfy({ $0.isFinite && $0 >= 0 }), lengths.isEmpty || lengths.contains(where: { $0 > 0 }) else { break }
                let period = lengths.reduce(0, +) * (lengths.count % 2 == 1 ? 2 : 1)
                if phase < 0, period > 0 { phase = phase.truncatingRemainder(dividingBy: period) + period }
                gs.dash = lengths.count > 1024 ? [] : lengths
                gs.dashPhase = phase
            case O.ri, O.i: break
            case O.gs:
                if let n = a.last?.name, let d = PDFVectorObj.asDict(resource(level, "ExtGState", n)) { applyExtGState(d, level) }

            // paths
            case O.m:
                guard a.count >= 2 else { break }   // like Core Graphics, an operator short of operands does nothing
                beginPath(level)
                let p = CGPoint(x: num(a, 0), y: num(a, 1))
                level.path?.move(to: p.applying(gs.ctm))
                level.current = p; level.subpathStart = p; level.pathPoints += 1
            case O.l:
                guard level.path != nil, a.count >= 2 else { break }
                let p = CGPoint(x: num(a, 0), y: num(a, 1))
                level.path?.addLine(to: p.applying(gs.ctm))
                level.current = p; level.pathPoints += 1
            case O.c:
                guard level.path != nil, a.count >= 6 else { break }
                let p = CGPoint(x: num(a, 4), y: num(a, 5))
                level.path?.addCurve(to: p.applying(gs.ctm), control1: CGPoint(x: num(a, 0), y: num(a, 1)).applying(gs.ctm),
                                     control2: CGPoint(x: num(a, 2), y: num(a, 3)).applying(gs.ctm))
                level.current = p; level.pathPoints += 1
            case O.v:
                guard level.path != nil, a.count >= 4 else { break }
                let p = CGPoint(x: num(a, 2), y: num(a, 3))
                level.path?.addCurve(to: p.applying(gs.ctm), control1: level.current.applying(gs.ctm), control2: CGPoint(x: num(a, 0), y: num(a, 1)).applying(gs.ctm))
                level.current = p; level.pathPoints += 1
            case O.y:
                guard level.path != nil, a.count >= 4 else { break }
                let p = CGPoint(x: num(a, 2), y: num(a, 3))
                level.path?.addCurve(to: p.applying(gs.ctm), control1: CGPoint(x: num(a, 0), y: num(a, 1)).applying(gs.ctm), control2: p.applying(gs.ctm))
                level.current = p; level.pathPoints += 1
            case O.h:
                guard level.path != nil else { break }
                level.path?.closeSubpath()
                level.current = level.subpathStart
            case O.re:
                guard a.count >= 4 else { break }
                beginPath(level)
                let x = num(a, 0), y = num(a, 1), w = num(a, 2), h = num(a, 3)
                let t = gs.ctm
                level.path?.move(to: CGPoint(x: x, y: y).applying(t))
                level.path?.addLine(to: CGPoint(x: x + w, y: y).applying(t))
                level.path?.addLine(to: CGPoint(x: x + w, y: y + h).applying(t))
                level.path?.addLine(to: CGPoint(x: x, y: y + h).applying(t))
                level.path?.closeSubpath()
                level.current = CGPoint(x: x, y: y); level.subpathStart = level.current; level.pathPoints += 4
            case O.S: paint(level, fill: false, stroke: true, evenOdd: false, close: false)
            case O.s: paint(level, fill: false, stroke: true, evenOdd: false, close: true)
            case O.f, O.F: paint(level, fill: true, stroke: false, evenOdd: false, close: false)
            case O.fStar: paint(level, fill: true, stroke: false, evenOdd: true, close: false)
            case O.B: paint(level, fill: true, stroke: true, evenOdd: false, close: false)
            case O.BStar: paint(level, fill: true, stroke: true, evenOdd: true, close: false)
            case O.b: paint(level, fill: true, stroke: true, evenOdd: false, close: true)
            case O.bStar: paint(level, fill: true, stroke: true, evenOdd: true, close: true)
            case O.n: paint(level, fill: false, stroke: false, evenOdd: false, close: false)
            // (with or without a path under construction: the clip takes effect when the next path is painted or ended)
            case O.W: gs.pendingClip = false
            case O.WStar: gs.pendingClip = true

            // colour
            case O.CS: setSpace(&gs.stroke, a.last?.name, level)
            case O.cs: setSpace(&gs.fill, a.last?.name, level)
            case O.SC, O.SCN: setColor(&gs.stroke, a, level, named: op == O.SCN)
            case O.sc, O.scn: setColor(&gs.fill, a, level, named: op == O.scn)
            case O.G: if a.count >= 1 { gs.stroke = device("DeviceGray", a, 1) }
            case O.g: if a.count >= 1 { gs.fill = device("DeviceGray", a, 1) }
            case O.RG: if a.count >= 3 { gs.stroke = device("DeviceRGB", a, 3) }
            case O.rg: if a.count >= 3 { gs.fill = device("DeviceRGB", a, 3) }
            case O.K: if a.count >= 4 { gs.stroke = device("DeviceCMYK", a, 4) }
            case O.k: if a.count >= 4 { gs.fill = device("DeviceCMYK", a, 4) }

            // text
            case O.BT:
                level.inText = true
                level.tm = .identity; level.tlm = .identity; level.tmKnown = true
            case O.ET:
                level.inText = false
            case O.Tc: gs.charSpace = num(a, 0)
            case O.Tw: gs.wordSpace = num(a, 0)
            case O.Tz: gs.hScale = num(a, 0) / 100
            case O.TL: gs.leading = num(a, 0)
            case O.Ts: gs.rise = num(a, 0)
            case O.Tr:
                if level.lexer.tailIsInteger, (0...7).contains(num(a, 0)) { gs.renderMode = Int(num(a, 0)) }
            case O.Tf:
                guard a.count >= 2, let size = a[a.count - 1].number, size.isFinite, let n = a[a.count - 2].name else { break }
                gs.fontSize = size
                if let d = PDFVectorObj.asDict(resource(level, "Font", n)) { gs.font = font(d) } else { gs.font = nil }
            case O.Td: moveLine(level, num(a, 0), num(a, 1))
            case O.TD:
                gs.leading = -num(a, 1)
                moveLine(level, num(a, 0), num(a, 1))
            case O.Tm:
                if a.count >= 6 {
                    level.tlm = CGAffineTransform(a: num(a, 0), b: num(a, 1), c: num(a, 2), d: num(a, 3), tx: num(a, 4), ty: num(a, 5))
                    level.tm = level.tlm
                    level.tmKnown = true
                }
            case O.TStar: moveLine(level, 0, -gs.leading)
            case O.Tj:
                if let s = a.last, s.bytes != nil { try show(level, [s]) }
            case O.TJ:
                if let arr = a.last?.array { try show(level, arr) }
            case O.quote:
                guard let s = a.last, s.bytes != nil else { break }
                moveLine(level, 0, -gs.leading)
                try show(level, [s])
            case O.dquote:
                guard a.count >= 3, let s = a.last, s.bytes != nil, let aw = a[a.count - 3].number, let ac = a[a.count - 2].number else { break }
                gs.wordSpace = aw; gs.charSpace = ac
                moveLine(level, 0, -gs.leading)
                try show(level, [s])

            // objects
            case O.sh:
                if let n = a.last?.name, let d = PDFVectorObj.asDict(resource(level, "Shading", n)) { shade(level, d) }
            case O.BI:
                if level.lexer.inlineImage != nil { image(level, name: "Inline Image") }
            case O.Do:
                if let n = a.last?.name { try xobject(level, n) }

            // marked content
            case O.BMC:
                if level.hidden == nil, a.last?.name != nil { level.marked.append(nil); level.markedRestore.append(false) }
            case O.BDC:
                if level.hidden != nil || a.count < 2 || a[a.count - 2].name == nil { break }
                var idx: Int? = nil
                var restore = false
                if a[a.count - 2].name == "OC", level.depth == 0, level.stream == 0 {
                    if let n = a[a.count - 1].name, let d = PDFVectorObj.asDict(resource(level, "Properties", n)) { idx = ocg(for: d) }
                    else if stack.count < 4094 { restore = true; stack.append(gs); stack.append(gs) }
                }
                if idx != nil { splitBand(level) }
                level.marked.append(idx)
                level.markedRestore.append(restore)
                if let i = idx, !ocgs[i].visible {
                    level.hidden = (gs, stack, level.inText, level.tm, level.tlm, level.path?.mutableCopy(), level.pathStart, level.pathPoints,
                                    level.current, level.subpathStart)
                }
                if idx != nil, banding, !level.inText { beginBand(level, at: level.lexer.end) }
            case O.EMC:
                if let last = level.marked.last {
                    if last != nil { splitBand(level) }
                    level.marked.removeLast()
                    if level.markedRestore.popLast() == true, level.hidden == nil {
                        for _ in 0..<2 where stack.count > level.stackBase { gs = stack.removeLast() }
                        openText = nil
                    }
                    if let h = level.hidden {
                        // what came after the hidden BDC never happened as far as the visible page is concerned
                        level.hidden = nil
                        gs = h.gs
                        stack = h.stack
                        level.inText = h.inText; level.tm = h.tm; level.tlm = h.tlm; level.tmKnown = true
                        level.path = h.path; level.pathStart = h.pathStart; level.pathPoints = h.pathPoints
                        level.current = h.current; level.subpathStart = h.subpathStart
                        openText = nil
                    }
                    if last != nil, banding, !level.inText { beginBand(level, at: level.lexer.end) }
                }
            default: break
            }
        }
        flushBand(level, end: level.lexer.bytes.count)
    }

    /// Ends the running band before an optional-content boundary so each layer gets its own raster.
    private func splitBand(_ level: Level) {
        openText = nil
        guard banding, !level.inText else { return }
        flushBand(level, end: level.lexer.start)
    }

    private func clampD(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v.isNaN ? lo : min(max(v, lo), hi) }

    /// Operators whose operands are all numbers, with how many they take.
    private static let numericArity: [UInt32: Int] = {
        let O = PDFVectorOp.self
        return [O.cm: 6, O.w: 1, O.J: 1, O.j: 1, O.M: 1, O.m: 2, O.l: 2, O.c: 6, O.v: 4, O.y: 4, O.re: 4, O.G: 1, O.g: 1, O.RG: 3, O.rg: 3, O.K: 4, O.k: 4,
                O.Tc: 1, O.Tw: 1, O.Tz: 1, O.TL: 1, O.Ts: 1, O.Tr: 1, O.Td: 2, O.TD: 2, O.Tm: 6]
    }()

    private func beginPath(_ level: Level) {
        if level.path == nil {
            level.path = CGMutablePath()
            level.pathStart = level.lexer.start
            level.pathPoints = 0
        }
    }

    private func applyExtGState(_ d: CGPDFDictionaryRef, _ level: Level) {
        let id = PDFVectorObj.id(d)
        let ctm = gs.ctm
        gs.extStates.removeAll { PDFVectorObj.id($0.dict) == id && $0.ctm == ctm }
        if gs.extStates.count >= 48 { gs.extStates.removeFirst() }
        gs.extStates.append((d, gs.ctm))
        if let v = PDFVectorObj.number(d, "LW"), v >= 0 { gs.lineWidth = v }
        if let v = PDFVectorObj.int(d, "LC"), (0...2).contains(v) { gs.lineCap = v }
        if let v = PDFVectorObj.int(d, "LJ"), (0...2).contains(v) { gs.lineJoin = v }
        if let v = PDFVectorObj.number(d, "ML"), v >= 1 { gs.miterLimit = v }
        // (Core Graphics ignores a dash pattern given in an ExtGState, so it is not applied here either)
        if let v = PDFVectorObj.number(d, "CA") { gs.strokeAlpha = clampD(v, 0, 1) }
        if let v = PDFVectorObj.number(d, "ca") { gs.fillAlpha = clampD(v, 0, 1) }
        if let n = PDFVectorObj.name(d, "BM") { gs.blend = n }
        else if let arr = PDFVectorObj.array(d, "BM"), let n = PDFVectorObj.objects(arr).compactMap({ PDFVectorObj.asName($0) }).first { gs.blend = n }
        if let o = PDFVectorObj.object(d, "SMask") {
            gs.softMask = PDFVectorObj.asName(o) != "None" && PDFVectorObj.asDict(o) != nil
            gs.softMaskIndex = nil
            let det = ctm.a * ctm.d - ctm.b * ctm.c
            if gs.softMask, det.isFinite, abs(det) > 1e-12 {
                if let i = softMasks.firstIndex(where: { PDFVectorObj.id($0.state) == id && $0.ctm == ctm }) { gs.softMaskIndex = i }
                else if softMasks.count < 64 { softMasks.append(PDFVectorSoftMask(state: d, ctm: ctm)); gs.softMaskIndex = softMasks.count - 1 }
            }
        }
        if let arr = PDFVectorObj.array(d, "Font") {
            let parts = PDFVectorObj.objects(arr)
            if parts.count >= 2, let fd = PDFVectorObj.asDict(parts[0]) { gs.font = font(fd); gs.fontSize = PDFVectorObj.asNumber(parts[1]) ?? gs.fontSize }
        }
    }

    // MARK: Colour

    private func device(_ space: String, _ a: [PDFVectorOperand], _ n: Int) -> PDFVectorColorState {
        var c = PDFVectorColorState()
        c.spaceName = space
        c.components = (0..<n).map { clampD(num(a, $0), 0, 1) }
        return c
    }

    private func setSpace(_ c: inout PDFVectorColorState, _ name: String?, _ level: Level) {
        guard let name else { return }
        var n = PDFVectorColorState()
        switch name {
        case "DeviceGray": n.spaceName = name; n.components = [0]
        case "DeviceRGB": n.spaceName = name; n.components = [0, 0, 0]
        case "DeviceCMYK": n.spaceName = name; n.components = [0, 0, 0, 1]
        case "Pattern": n.spaceName = name; n.components = []
        default:
            // a name that is not a colour space leaves the colour as it was (as Core Graphics does)
            guard let o = resource(level, "ColorSpace", name) else { return }
            n.spaceName = ""; n.space = o; n.components = []
        }
        c = n
    }

    /// Number of components of a colour-space resource, where that is plain to see.
    private func componentCount(_ o: CGPDFObjectRef) -> Int? {
        func named(_ n: String) -> Int? {
            switch n {
            case "DeviceGray", "CalGray", "G", "Separation", "Indexed", "I": return 1
            case "DeviceRGB", "CalRGB", "RGB", "Lab": return 3
            case "DeviceCMYK", "CMYK": return 4
            default: return nil
            }
        }
        if let n = PDFVectorObj.asName(o) { return named(n) }
        let parts = PDFVectorObj.objects(PDFVectorObj.asArray(o))
        guard let family = parts.first.flatMap({ PDFVectorObj.asName($0) }) else { return nil }
        if family == "ICCBased", parts.count > 1, let st = PDFVectorObj.asStream(parts[1]), let d = CGPDFStreamGetDictionary(st) { return PDFVectorObj.int(d, "N") }
        if family == "DeviceN", parts.count > 1 { let k = PDFVectorObj.objects(PDFVectorObj.asArray(parts[1])).count; return k > 0 ? k : nil }
        return named(family)
    }

    private func setColor(_ c: inout PDFVectorColorState, _ a: [PDFVectorOperand], _ level: Level, named: Bool) {
        var numbers = a.compactMap { $0.number }.prefix(32).map { $0.isFinite ? $0 : 0 }
        // Core Graphics takes as many operands as the space has components off the end of the list, and ignores the
        // operator when they are not all numbers
        var count: Int? = nil
        switch c.spaceName {
        case "DeviceGray": count = 1
        case "DeviceRGB": count = 3
        case "DeviceCMYK": count = 4
        case "": count = c.space.flatMap { componentCount($0) }
        default: break
        }
        // in a pattern space the list has to end with a name
        let family = c.space.flatMap { PDFVectorObj.objects(PDFVectorObj.asArray($0)).first }.flatMap { PDFVectorObj.asName($0) }
        if c.spaceName == "Pattern" || family == "Pattern" {
            if !named { c = PDFVectorColorState(); return }   // Core Graphics paints black after sc / SC in a pattern space
            if a.last?.name == nil { return }
        }
        if let count {
            guard a.count >= count, a.suffix(count).allSatisfy({ $0.number != nil }) else { return }
            numbers = a.suffix(count).map { $0.number!.isFinite ? $0.number! : 0 }
        }
        c.components = numbers
        c.pattern = nil; c.patternObject = nil
        if let n = a.last?.name, let o = resource(level, "Pattern", n) {
            c.patternObject = o
            c.pattern = PDFVectorObj.asDict(o)
        }
    }

    /// Paint for the current fill / stroke colour: a palette entry, a gradient, or nil for something only the PDF
    /// engine can draw (tiling patterns, mesh shadings).
    private func paint(for c: PDFVectorColorState, _ level: Level, bounds: CGRect) -> (PDFVectorPaint?, String) {
        if let p = c.pattern {
            if PDFVectorObj.int(p, "PatternType") == 2, let sh = PDFVectorObj.dict(p, "Shading") {
                let m = PDFVectorObj.matrix(PDFVectorObj.numbers(p, "Matrix")) ?? .identity
                if PDFVectorObj.dict(p, "ExtGState") == nil, let g = gradient(sh, matrix: m.concatenating(level.baseCTM), asPattern: true, bounds: bounds) { return (.gradient(g), "") }
                return (nil, PDFVectorObj.int(sh, "ShadingType").map { $0 >= 4 ? "mesh gradient" : "gradient that has no layer equivalent" } ?? "gradient")
            }
            return (nil, "pattern fill")
        }
        if c.patternObject != nil || c.spaceName == "Pattern" { return (nil, "pattern fill") }
        return (.color(colorRef(c)), "")
    }

    /// Registers an axial / radial shading as a gradient. `matrix` maps the shading's space to the document.
    private func gradient(_ sh: CGPDFDictionaryRef, matrix m: CGAffineTransform, asPattern: Bool, bounds: CGRect) -> Int? {
        guard let type = PDFVectorObj.int(sh, "ShadingType"), type == 2 || type == 3, PDFVectorObj.object(sh, "Function") != nil,
              PDFVectorObj.array(sh, "BBox") == nil, PDFVectorObj.array(sh, "Background") == nil || !asPattern else { return nil }
        let c = PDFVectorObj.numbers(sh, "Coords")
        var ext = [false, false]
        if let e = PDFVectorObj.array(sh, "Extend") {
            for i in 0..<min(2, CGPDFArrayGetCount(e)) { var b: CGPDFBoolean = 0; if CGPDFArrayGetBoolean(e, i, &b) { ext[i] = b != 0 } }
        }
        let det = m.a * m.d - m.b * m.c
        guard det.isFinite, abs(det) > 1e-12 else { return nil }
        if type == 2 {
            guard c.count >= 4 else { return nil }
            let p0 = CGPoint(x: c[0], y: c[1]), p1 = CGPoint(x: c[2], y: c[3])
            let d = CGPoint(x: p1.x - p0.x, y: p1.y - p0.y)
            let len2 = d.x * d.x + d.y * d.y
            guard len2 > 1e-18 else { return nil }
            // t(q) stays linear under an affine map, but its gradient direction is the inverse-transpose image of d:
            // the layer gradient needs an axis perpendicular to the lines of equal colour
            let inv = m.inverted()
            let gx = (inv.a * d.x + inv.b * d.y) / len2, gy = (inv.c * d.x + inv.d * d.y) / len2
            let g2 = gx * gx + gy * gy
            guard g2 > 1e-18, g2.isFinite else { return nil }
            let s = p0.applying(m)
            let e = CGPoint(x: s.x + gx / g2, y: s.y + gy / g2)
            // a layer gradient continues its end colours: a shading that stops must not be needed past its ends
            if !ext[0] || !ext[1] {
                var tmin = Double.infinity, tmax = -Double.infinity
                for q in [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY), CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)] {
                    let t = Double((q.x - s.x) * gx + (q.y - s.y) * gy)
                    tmin = min(tmin, t); tmax = max(tmax, t)
                }
                if (!ext[0] && tmin < -0.003) || (!ext[1] && tmax > 1.003) { return nil }
            }
            gradients.append(PDFVectorGradient(shading: sh, radial: false, start: s, end: e, extendStart: ext[0], extendEnd: ext[1], chain: chain))
        } else {
            guard c.count >= 6 else { return nil }
            let r0 = c[2], r1 = c[5]
            guard r1 > 0, r0 >= 0, r1 > r0, hypot(c[3] - c[0], c[4] - c[1]) <= r1 * 0.002 else { return nil }
            // only a conformal matrix keeps the circles round
            let sx = hypot(m.a, m.b), sy = hypot(m.c, m.d)
            guard sx > 0, abs(sx - sy) <= sx * 0.01, abs(m.a * m.c + m.b * m.d) <= sx * sy * 0.01 else { return nil }
            let ctr = CGPoint(x: c[3], y: c[4]).applying(m)
            if r0 > 0, !ext[0] { return nil }
            if !ext[1] {
                let far = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY), CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
                    .map { hypot($0.x - ctr.x, $0.y - ctr.y) }.max() ?? 0
                if far > CGFloat(r1) * sx * 1.003 { return nil }
            }
            gradients.append(PDFVectorGradient(shading: sh, radial: true, start: ctr, end: CGPoint(x: ctr.x + CGFloat(r1) * sx, y: ctr.y),
                                               innerFraction: r0 / r1, extendStart: ext[0], extendEnd: ext[1], chain: chain))
        }
        return gradients.count - 1
    }

    // MARK: Painting paths

    private func uniformScale(_ t: CGAffineTransform) -> Double? {
        let sx = hypot(t.a, t.b), sy = hypot(t.c, t.d)
        guard sx > 0, sy > 0, abs(sx - sy) <= max(sx, sy) * 0.01, abs(t.a * t.c + t.b * t.d) <= sx * sy * 0.01 else { return nil }
        return Double((sx + sy) / 2)
    }

    private func paint(_ level: Level, fill: Bool, stroke: Bool, evenOdd: Bool, close: Bool) {
        guard let path = level.path else { gs.pendingClip = nil; return }
        defer {
            if let eo = gs.pendingClip { gs.pendingClip = nil; addClip(path, evenOdd: eo) }
            level.path = nil
        }
        if close { path.closeSubpath() }
        guard fill || stroke, !path.isEmpty else { return }
        let bbox = path.boundingBoxOfPath
        guard !bbox.isNull, bbox.minX.isFinite, bbox.width.isFinite, bbox.height.isFinite else { return }
        pathCount += 1
        let range = level.pathStart..<level.lexer.end
        let wantFill = fill && gs.fillAlpha > 0
        var wantStroke = stroke && gs.strokeAlpha > 0
        guard wantFill || wantStroke else { return }

        // A dash pattern with a period far below the path's length makes Core Graphics (the PDF engine and Lumen's
        // shape renderer alike) grind through millions of dashes; no real artwork has that.
        if wantStroke, !gs.dash.isEmpty {
            // the number of dashes is the path's length over the pattern's, both in user space
            let period = gs.dash.reduce(0, +)
            let det = gs.ctm.a * gs.ctm.d - gs.ctm.b * gs.ctm.c
            var count = Double.infinity
            if period > 0, det.isFinite, abs(det) > 1e-9 {
                var inv = gs.ctm.inverted()
                if let user = path.copy(using: &inv) { count = Double(PDFVectorGeometry.roughLength(user)) / period }
            }
            if !(count < 20_000) {
                wantStroke = false
                report.note("A stroke with an extremely fine dash pattern was left out.")
                if !wantFill { return }
            }
        }

        // stroke geometry
        var spec: PDFVectorStroke? = nil
        var expanded: CGPath? = nil
        var strokeWhy = ""
        var strokeBounds = bbox
        if wantStroke {
            let scale = uniformScale(gs.ctm)
            let dashes = gs.dash.count % 2 == 1 ? gs.dash + gs.dash : gs.dash
            let width = gs.lineWidth
            var needsExpand = scale == nil || (!dashes.isEmpty && abs(gs.dashPhase) > 1e-6)
            if !needsExpand, gs.lineJoin == 0, abs(gs.miterLimit - 10) > 0.01, PDFVectorGeometry.hasCornerBetween(path, gs.miterLimit, 10) { needsExpand = true }
            if needsExpand {
                expanded = PDFVectorGeometry.strokeOutline(path, ctm: gs.ctm, width: width, cap: gs.lineCap, join: gs.lineJoin, miter: gs.miterLimit,
                                                           dash: dashes, phase: gs.dashPhase)
                // an outline that cannot be made, or one of thousands of pieces, is left to the PDF engine
                if let e = expanded, PDFVectorGeometry.elementCount(e) <= 6000 { strokeBounds = e.boundingBoxOfPath } else {
                    expanded = nil
                    needsExpand = false
                    strokeWhy = "stroke that has no layer equivalent"
                    let reach = CGFloat(max(1, width) * Double(max(hypot(gs.ctm.a, gs.ctm.b), hypot(gs.ctm.c, gs.ctm.d))) * max(1, gs.miterLimit) + 2)
                    strokeBounds = bbox.insetBy(dx: -reach, dy: -reach)
                }
            }
            if !needsExpand, strokeWhy.isEmpty {
                let s = scale ?? 1
                let w = width > 0 ? width * s : 1   // zero width = the thinnest line the device draws
                spec = PDFVectorStroke(width: max(w, 0.01), cap: gs.lineCap, join: gs.lineJoin, dash: dashes.map { $0 * s })
                let reach = CGFloat(w / 2 * (gs.lineJoin == 0 ? max(1, gs.miterLimit) : 1.5) + 1)
                strokeBounds = bbox.insetBy(dx: -reach, dy: -reach)
            }
        }
        let total = wantStroke ? bbox.union(strokeBounds) : bbox

        // things only the PDF engine draws faithfully
        var why = strokeWhy
        var fillPaint: PDFVectorPaint? = .some(.empty), strokePaint: PDFVectorPaint? = .some(.empty)
        if why.isEmpty, gs.softMask, gs.softMaskIndex == nil { why = "soft mask" }
        if why.isEmpty, wantFill { let (p, r) = paint(for: gs.fill, level, bounds: bbox); fillPaint = p; if p == nil { why = r } }
        if why.isEmpty, wantStroke {
            let (p, r) = paint(for: gs.stroke, level, bounds: strokeBounds)
            strokePaint = p
            if p == nil { why = r == "pattern fill" ? "pattern stroke" : r }
            if case .gradient? = p { strokePaint = nil; why = "gradient stroke" }
        }
        if level.pathPoints > 30_000 { why = "very large path" }
        // an even-odd fill is stored as its non-zero equivalent; a path too large to convert stays pixels
        var evenOddPath: CGPath? = nil
        if why.isEmpty, wantFill, evenOdd {
            evenOddPath = PDFVectorGeometry.normalized(path, using: .evenOdd)
            if evenOddPath == nil { why = "very large path" }
        }
        if !why.isEmpty {
            // The path is written out again for the PDF engine rather than replayed from its bytes: those may have
            // other operators (even painted text) between the path's segments and the operator that paints it.
            let det = gs.ctm.a * gs.ctm.d - gs.ctm.b * gs.ctm.c
            guard det.isFinite, abs(det) > 1e-12 else { return }
            let op = wantFill && wantStroke ? (evenOdd ? "B*" : "B") : (wantFill ? (evenOdd ? "f*" : "f") : "S")
            raster(level, range: range, bounds: total, reason: why, name: "Path", opaque: gs.fillAlpha == gs.strokeAlpha || !(wantFill && wantStroke),
                   alpha: wantFill ? gs.fillAlpha : gs.strokeAlpha, synthetic: Array((PDFVectorGeometry.pathOperators(path, gs.ctm.inverted()) + op + "\n").utf8))
            return
        }
        if skipForBand(level, start: level.pathStart, adding: false) { return }

        let ctx = context(level, clips: true)
        let closedCount = PDFVectorGeometry.closedSubpathCount(path)
        let label = PDFVectorGeometry.axisAlignedRect(path) != nil ? "Rectangle" : (PDFVectorGeometry.subpathCount(path) > 1 ? "Compound Path" : "Path")
        let fillPath: CGPath = evenOddPath ?? path.copy()!

        // one layer for fill + stroke only when nothing distinguishes it from painting them separately
        if wantFill, wantStroke, let st = spec, gs.fillAlpha == 1, gs.strokeAlpha == 1, !gs.softMask, !evenOdd, closedCount <= 1, st.dash.isEmpty || closedCount == 0,
           let fp = fillPaint, let sp = strokePaint {
            let sh = PDFVectorShape()
            sh.parts = [.init(path: fillPath, bounds: total)]
            sh.fill = fp; sh.strokePaint = sp; sh.stroke = st
            sh.pointCount = level.pathPoints; sh.closedSubpaths = closedCount; sh.unionBounds = total; sh.label = label
            append(level, shape: sh, context: ctx, opacity: 1, bounds: total, start: level.pathStart, mergeable: false)
            return
        }
        if wantFill, let fp = fillPaint {
            let sh = PDFVectorShape()
            sh.parts = [.init(path: fillPath, bounds: bbox, normalized: evenOdd)]
            sh.fill = fp
            sh.pointCount = level.pathPoints; sh.closedSubpaths = closedCount; sh.unionBounds = bbox; sh.label = label
            var canMerge = true
            if case .gradient = fp { canMerge = false; sh.label = "Gradient" }
            append(level, shape: sh, context: ctx, opacity: gs.fillAlpha, bounds: bbox, start: level.pathStart, mergeable: canMerge)
        }
        if wantStroke, let sp = strokePaint {
            let sh = PDFVectorShape()
            if let e = expanded {
                // drawn as the stroke's outline: exact, but no longer a live stroke
                sh.parts = [.init(path: e, bounds: strokeBounds, normalized: true)]
                sh.fill = sp
                sh.label = "Stroke Outline"
                report.note("Some strokes (dash offset, non-uniform scaling or a special miter limit) were converted to outlines.")
            } else if let st = spec {
                sh.parts = [.init(path: path.copy()!, bounds: strokeBounds)]
                sh.strokePaint = sp; sh.stroke = st
                sh.closedSubpaths = closedCount
                sh.label = label
            }
            sh.pointCount = level.pathPoints; sh.unionBounds = strokeBounds
            append(level, shape: sh, context: ctx, opacity: gs.strokeAlpha, bounds: strokeBounds, start: level.pathStart, mergeable: true)
        }
    }

    private func append(_ level: Level, shape sh: PDFVectorShape, context ctx: [PDFVectorContext], opacity: Double, bounds: CGRect, start: Int, mergeable: Bool) {
        let blend = gs.blend
        // join the previous shape when it is painted identically and nothing was drawn in between
        if mergeable, blend == "Normal" || blend == "Compatible", items.count > mergeBarrier, let last = items.last, case .shape(let acc) = last.kind,
           last.opacity == opacity, last.blend == blend, last.context == ctx, last.softMask == gs.softMaskIndex, acc.fill == sh.fill, acc.strokePaint == sh.strokePaint, acc.stroke == sh.stroke,
           acc.pointCount + sh.pointCount <= limits.maxShapePoints, acc.parts.count + sh.parts.count <= limits.maxShapeParts, mergeableFill(acc.fill) {
            var ok = true
            let overlaps = acc.unionBounds.intersects(bounds) && acc.parts.contains { $0.bounds.intersects(bounds) }
            if overlaps {
                if opacity < 1 || gs.softMask { ok = false }   // overlapping translucent objects darken where they overlap: keep them apart
                else if sh.stroke != nil && !(sh.stroke?.dash.isEmpty ?? true) { ok = false }
            }
            if sh.stroke != nil, acc.closedSubpaths + sh.closedSubpaths > 1, !(sh.stroke?.dash.isEmpty ?? true) { ok = false }
            var part = sh.parts[0]
            if ok, sh.stroke == nil, overlaps {
                // overlapping fills must add up to a union under the non-zero rule whatever their directions
                // (paths too large to normalize are left alone and not merged)
                if !part.normalized, let n = PDFVectorGeometry.normalized(part.path, using: .winding) { part.path = n; part.normalized = true }
                for i in acc.parts.indices where !acc.parts[i].normalized && acc.parts[i].bounds.intersects(bounds) {
                    if let n = PDFVectorGeometry.normalized(acc.parts[i].path, using: .winding) { acc.parts[i].path = n; acc.parts[i].normalized = true }
                }
                ok = part.normalized && !acc.parts.contains { !$0.normalized && $0.bounds.intersects(bounds) }
            }
            if ok {
                acc.parts.append(part)
                acc.pointCount += sh.pointCount
                acc.closedSubpaths += sh.closedSubpaths
                acc.unionBounds = acc.unionBounds.union(bounds)
                acc.label = "Paths"
                items[items.count - 1].bounds = last.bounds.union(bounds)
                return
            }
        }
        if skipForBand(level, start: start, adding: true) { return }
        openText = nil
        items.append(PDFVectorItem(kind: .shape(sh), context: ctx, opacity: opacity, blend: blend, bounds: bounds, softMask: gs.softMaskIndex))
    }

    private func mergeableFill(_ p: PDFVectorPaint) -> Bool { if case .gradient = p { return false }; return true }

    private func addClip(_ path: CGPath, evenOdd: Bool) {
        let b = path.boundingBoxOfPath
        guard !b.isNull, b.minX.isFinite, b.width.isFinite else { return }
        let rect = PDFVectorGeometry.axisAlignedRect(path)
        // a rectangle that covers the page clips nothing
        if let r = rect, r.insetBy(dx: -0.5, dy: -0.5).contains(canvas) { return }
        var p: CGPath = path.copy()!
        if evenOdd {
            // a vector mask fills with the non-zero rule; an even-odd clip too large to convert cannot be one
            guard let n = PDFVectorGeometry.normalized(path, using: .evenOdd) else { pendingAbort = "very complex clipping path"; return }
            p = n
        }
        clips.append(PDFVectorClip(path: p, bounds: b, rect: rect))
        gs.clips.append(clips.count - 1)
    }

    // MARK: Pieces rendered from the PDF

    private func raster(_ level: Level, range: Range<Int>, bounds: CGRect, reason: String, name: String, isImage: Bool = false, opaque: Bool = true, alpha: Double? = nil,
                        synthetic: [UInt8]? = nil) {
        if skipForBand(level, start: range.lowerBound, adding: true) { return }
        openText = nil
        var slice = PDFVectorSlice(stream: level.stream, range: range, state: gs, opaque: opaque)
        slice.chain = chain
        slice.synthetic = synthetic
        slice.inText = synthetic == nil && level.inText
        slice.textMatrix = level.tm
        slice.lineMatrix = level.tlm
        let b = bounds.intersection(clipBounds())
        guard !b.isNull, b.width > 0, b.height > 0 else { return }
        items.append(PDFVectorItem(kind: .raster(PDFVectorRaster(slice: slice, isImage: isImage, reason: reason, name: name)), context: context(level, clips: false),
                                   opacity: opaque ? (alpha ?? gs.fillAlpha) : 1, blend: gs.blend, bounds: b))
        if isImage { report.images += 1 } else { report.raster(reason) }
    }

    private func image(_ level: Level, name: String) {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1).applying(gs.ctm).insetBy(dx: -1, dy: -1)
        raster(level, range: level.lexer.start..<level.lexer.end, bounds: unit, reason: "image", name: name, isImage: true)
    }

    private func shade(_ level: Level, _ sh: CGPDFDictionaryRef) {
        let range = level.lexer.start..<level.lexer.end
        let area = clipBounds()
        guard area.width > 0, area.height > 0 else { return }
        if (gs.softMask && gs.softMaskIndex == nil) || gs.fillAlpha <= 0 {
            if gs.fillAlpha > 0 { raster(level, range: range, bounds: area, reason: "soft mask", name: "Gradient") }
            return
        }
        guard let g = gradient(sh, matrix: gs.ctm, asPattern: false, bounds: gs.clips.last.map { clips[$0].bounds.intersection(area) } ?? area) else {
            let t = PDFVectorObj.int(sh, "ShadingType") ?? 0
            raster(level, range: range, bounds: area, reason: t >= 4 ? "mesh gradient" : "gradient that has no layer equivalent", name: "Gradient")
            return
        }
        if skipForBand(level, start: range.lowerBound, adding: false) { return }
        // the shading fills the clip: the innermost clipping path becomes the shape, the outer ones stay masks
        let shp = PDFVectorShape()
        var ctx = context(level, clips: true)
        var path: CGPath = CGPath(rect: canvas, transform: nil)
        var b = canvas
        if let last = gs.clips.last, gs.clips.count > level.baseClipCount, case .clip? = ctx.last {
            ctx.removeLast()
            path = clips[last].path
            b = clips[last].bounds
        } else if let last = gs.clips.last {
            path = clips[last].path
            b = clips[last].bounds
        }
        shp.parts = [.init(path: path, bounds: b, normalized: true)]
        shp.fill = .gradient(g)
        shp.unionBounds = b
        shp.label = "Gradient"
        pathCount += 1
        append(level, shape: shp, context: ctx, opacity: gs.fillAlpha, bounds: b, start: range.lowerBound, mergeable: false)
    }

    private func xobject(_ level: Level, _ name: String) throws {
        guard let obj = resource(level, "XObject", name), let s = PDFVectorObj.asStream(obj), let d = CGPDFStreamGetDictionary(s) else { return }
        let range = level.lexer.start..<level.lexer.end
        switch PDFVectorObj.name(d, "Subtype") {
        case "Image":
            image(level, name: "Image")
        case "Form":
            try form(level, s, d, name: name, range: range)
        default: break
        }
    }

    private func form(_ level: Level, _ s: CGPDFStreamRef, _ d: CGPDFDictionaryRef, name: String, range: Range<Int>) throws {
        let m = PDFVectorObj.matrix(PDFVectorObj.numbers(d, "Matrix")) ?? .identity
        let bbox = PDFVectorObj.rect(PDFVectorObj.numbers(d, "BBox"))
        let ctm = m.concatenating(gs.ctm)
        let docBox = bbox.map { $0.applying(ctm) } ?? canvas
        let group = PDFVectorObj.dict(d, "Group")
        let isGroup = group.map { PDFVectorObj.name($0, "S") == "Transparency" } ?? false
        let knockout = group.flatMap { PDFVectorObj.bool($0, "K") } ?? false
        let sid = PDFVectorObj.id(s)
        var why = ""
        if gs.softMask, gs.softMaskIndex == nil { why = "soft mask" }
        else if level.depth >= limits.maxFormDepth || activeStreams.contains(sid) { why = "deeply nested artwork" }
        if banding {
            _ = skipForBand(level, start: range.lowerBound, adding: false)
            return
        }
        if !why.isEmpty {
            raster(level, range: range, bounds: docBox, reason: why, name: "Group")
            return
        }
        guard let (data, _) = PDFVectorObj.data(s) else { return }
        if data.count > limits.maxContentBytes { throw Abort.limit("the page description is too large") }
        if data.isEmpty { return }

        let saved = gs
        let savedStack = stack.count
        let itemsBefore = items.count
        let barrierBefore = mergeBarrier
        let formsBefore = forms.count
        openText = nil
        mergeBarrier = items.count

        let savedChain = chain
        if isGroup, let group {
            let next = chains[chain] + [group]
            if let i = chains.firstIndex(where: { $0.count == next.count && zip($0, next).allSatisfy { PDFVectorObj.id($0) == PDFVectorObj.id($1) } }) { chain = i }
            else if chains.count < 4096, next.count <= 12 { chains.append(next); chain = chains.count - 1 }
        }
        var inst = PDFVectorFormInstance(name: name)
        inst.slice = PDFVectorSlice(stream: level.stream, range: range, state: gs, opaque: true, chain: savedChain)
        if isGroup {
            inst.isGroup = true
            inst.opacity = gs.fillAlpha
            inst.blend = gs.blend
            inst.isolated = group.flatMap { PDFVectorObj.bool($0, "I") } ?? false
            inst.softMask = gs.softMaskIndex
        }
        forms.append(inst)
        var base = context(level, clips: true)
        base.append(.form(forms.count - 1))
        stack.append(gs)
        gs.ctm = ctm
        if isGroup { gs.fillAlpha = 1; gs.strokeAlpha = 1; gs.blend = "Normal"; gs.softMask = false; gs.softMaskIndex = nil }
        let inherited = gs.clips.count
        if let bbox {
            let p = CGMutablePath()
            p.addRect(bbox, transform: ctm)
            addClip(p, evenOdd: false)
        }
        let res = PDFVectorObj.dict(d, "Resources") ?? level.resources
        streams.append(Stream(bytes: [UInt8](data), resources: res))
        let sub = Level(stream: streams.count - 1, bytes: streams[streams.count - 1].bytes, resources: res, baseContext: base, baseClipCount: inherited,
                        baseCTM: ctm, depth: level.depth + 1, stackBase: stack.count)
        activeStreams.append(sid)
        var failure: String? = nil
        do { try interpret(sub) } catch Abort.rasterizeStream(let r) { failure = r }
        activeStreams.removeLast()
        chain = savedChain
        if stack.count > savedStack { stack.removeLast(stack.count - savedStack) }
        gs = saved
        openText = nil
        mergeBarrier = barrierBefore
        if failure == nil, isGroup, formsBefore < forms.count {
            // Lumen blends in RGB and has no knockout groups: where that can show, the group is checked against
            // the PDF's own rendering once its layers exist
            let translucent = items[itemsBefore...].contains { $0.opacity < 0.999 || PDFVectorInterpreter.blends($0.blend) }
                || forms[(formsBefore + 1)...].contains { $0.isGroup && ($0.opacity < 0.999 || PDFVectorInterpreter.blends($0.blend)) }
            if knockout, items.count - itemsBefore > 1 { forms[formsBefore].needsCheck = true; forms[formsBefore].checkReason = "knockout group" }
            else if translucent, let group, PDFVectorInterpreter.nonRGB(group) {
                forms[formsBefore].needsCheck = true
                forms[formsBefore].checkReason = "transparency blended in a CMYK group"
            }
        }
        if let failure {
            // drop what was collected from inside the form and render the whole form instead
            items.removeLast(items.count - itemsBefore)
            forms.removeLast(forms.count - formsBefore)
            let wasBanding = banding
            banding = false
            raster(level, range: range, bounds: docBox, reason: failure, name: "Group")
            banding = wasBanding
        }
        mergeBarrier = max(mergeBarrier, items.count)
        if banding, level.bandStart == nil { beginBand(level, at: level.lexer.end) }
    }

    static func blends(_ mode: String) -> Bool { mode != "Normal" && mode != "Compatible" }

    /// Whether a transparency group blends in a colour space other than RGB.
    static func nonRGB(_ group: CGPDFDictionaryRef) -> Bool {
        if let n = PDFVectorObj.name(group, "CS") { return n == "DeviceCMYK" || n == "DeviceGray" }
        if let a = PDFVectorObj.array(group, "CS") {
            let parts = PDFVectorObj.objects(a)
            if PDFVectorObj.asName(parts.first) == "ICCBased", parts.count > 1, let d = PDFVectorObj.asDict(parts[1]) { return PDFVectorObj.int(d, "N") != 3 }
            return PDFVectorObj.asName(parts.first) != "CalRGB"
        }
        return false
    }

    // MARK: Text

    private func moveLine(_ level: Level, _ tx: Double, _ ty: Double) {
        level.tlm = CGAffineTransform(translationX: tx, y: ty).concatenating(level.tlm)
        level.tm = level.tlm
        level.tmKnown = true
    }

    private func show(_ level: Level, _ elements: [PDFVectorOperand]) throws {
        guard let font = gs.font else { return }
        let mode = gs.renderMode
        if mode >= 4 { throw Abort.rasterizeStream("text used as a clipping path") }
        if mode == 1 || mode == 2, !gs.dash.isEmpty {
            // dashed outlines of type: the same concern as for paths, estimated from the glyph count
            let period = gs.dash.reduce(0, +)
            let glyphs = elements.reduce(0) { $0 + ($1.bytes?.count ?? 0) }
            if !(period > 0 && Double(glyphs) * 8 * abs(gs.fontSize) / period < 20_000) {
                level.tmKnown = false
                report.note("Text outlined with an extremely fine dash pattern was left out.")
                return
            }
        }
        // type set at an absurd size (corrupt files) is not worth the minutes Core Graphics would spend on it
        let em = abs(gs.fontSize) * Double(max(hypot(gs.ctm.a, gs.ctm.b), hypot(gs.ctm.c, gs.ctm.d))) * Double(max(hypot(level.tm.a, level.tm.b), hypot(level.tm.c, level.tm.d)))
        if !em.isFinite || em > 60_000 || !(abs(gs.hScale) * em <= 60_000) || !(abs(gs.charSpace) < 1e6) || !(abs(gs.wordSpace) < 1e6) || !(abs(gs.rise) < 1e6) {
            level.tmKnown = false
            report.note("Text set at an unusable size was left out.")
            return
        }
        let start = level.lexer.start, end = level.lexer.end
        let fs = gs.fontSize, th = gs.hScale
        let positionable = font.bytesPerCode > 0 && font.widthsKnown && !font.isVertical && level.tmKnown
        let visible = mode != 3 && (mode == 1 ? gs.strokeAlpha > 0 : gs.fillAlpha > 0 || (mode == 2 && gs.strokeAlpha > 0))
        let tmAtStart = level.tm

        // walk the glyphs
        var glyphs: [PDFVectorGlyph] = []
        let basis = CGAffineTransform(a: fs * th, b: 0, c: 0, d: fs, tx: 0, ty: 0).concatenating(level.tm).concatenating(gs.ctm)
        if positionable {
            let step = font.bytesPerCode
            for e in elements {
                if let n = e.number {
                    let tx = -n / 1000 * fs * th
                    level.tm = CGAffineTransform(translationX: tx, y: 0).concatenating(level.tm)
                } else if let bytes = e.bytes {
                    var i = 0
                    while i + step <= bytes.count {
                        let code = step == 1 ? Int(bytes[i]) : Int(bytes[i]) << 8 | Int(bytes[i + 1])
                        i += step
                        let origin = CGPoint(x: 0, y: gs.rise).applying(level.tm).applying(gs.ctm)
                        var tx = font.width(code) / 1000 * fs + gs.charSpace
                        if step == 1 && code == 32 { tx += gs.wordSpace }
                        tx *= th
                        level.tm = CGAffineTransform(translationX: tx, y: 0).concatenating(level.tm)
                        if visible, glyphs.count < 100_000 {
                            glyphs.append(PDFVectorGlyph(code: Int32(code), origin: origin, end: CGPoint(x: 0, y: gs.rise).applying(level.tm).applying(gs.ctm)))
                        }
                    }
                }
            }
        } else {
            level.tmKnown = false
        }
        guard visible else { return }
        if positionable && glyphs.isEmpty { return }

        // extent: baseline run padded by the font's reach
        var bounds: CGRect
        if positionable, let first = glyphs.first, let last = glyphs.last {
            let t = CGAffineTransform(a: basis.a, b: basis.b, c: basis.c, d: basis.d, tx: 0, ty: 0)
            let up = CGPoint(x: 0, y: 1.4).applying(t), down = CGPoint(x: 0, y: -0.7).applying(t), side = CGPoint(x: 0.6, y: 0).applying(t)
            var pts: [CGPoint] = []
            for p in [first.origin, last.end] {
                for v in [up, down] { for s in [CGFloat(-1), 1] { pts.append(CGPoint(x: p.x + v.x + side.x * s, y: p.y + v.y + side.y * s)) } }
            }
            var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
            for p in pts { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
            guard minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite else { return }
            bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            if mode != 0 {
                // stroked glyphs reach out by half the line width, and by the miter limit times that at sharp corners
                let w = CGFloat(gs.lineWidth) * max(hypot(gs.ctm.a, gs.ctm.b), hypot(gs.ctm.c, gs.ctm.d), 1) * CGFloat(gs.lineJoin == 0 ? max(1, gs.miterLimit) : 1) / 2 + 2
                bounds = bounds.insetBy(dx: -w, dy: -w)
            }
        } else {
            bounds = clipBounds()
        }

        // paints
        var why = ""
        var fillPaint = PDFVectorPaint.empty, strokePaint = PDFVectorPaint.empty
        var spec: PDFVectorStroke? = nil
        if gs.softMask { why = "soft mask" }
        if mode == 0 || mode == 2 {
            let (p, r) = paint(for: gs.fill, level, bounds: bounds)
            if let p, case .color = p { fillPaint = p } else if why.isEmpty { why = r.isEmpty ? "gradient-filled text" : r.replacingOccurrences(of: "fill", with: "filled text") }
        }
        if mode == 1 || mode == 2 {
            let (p, r) = paint(for: gs.stroke, level, bounds: bounds)
            if let p, case .color = p, let s = uniformScale(gs.ctm) {
                strokePaint = p
                spec = PDFVectorStroke(width: max(0.01, gs.lineWidth > 0 ? gs.lineWidth * s : 1), cap: gs.lineCap, join: gs.lineJoin, dash: gs.dash.map { $0 * s })
            } else if why.isEmpty { why = r.isEmpty ? "stroked text" : r }
        }
        // Translucent type that is both filled and outlined shows the fill through the inner half of the outline;
        // a layer's opacity fades the two as one. Such text keeps its own alpha in pixels.
        let baked = mode == 2 && (gs.fillAlpha < 1 || gs.strokeAlpha < 1)
        if baked, why.isEmpty { why = "translucent text with fill and outline" }
        let alpha = mode == 1 ? gs.strokeAlpha : gs.fillAlpha
        if font.isType3, why.isEmpty { why = "Type 3 font" }
        if !positionable, why.isEmpty { why = font.bytesPerCode == 0 ? "text in an encoding that is not decoded" : (font.isVertical ? "vertical text" : "text without usable metrics") }

        if skipForBand(level, start: start, adding: false) { return }
        let ctx = context(level, clips: true)
        let run = PDFVectorTextRun(font: font, basis: basis, glyphs: glyphs, fill: fillPaint, strokePaint: strokePaint, stroke: spec, mode: mode,
                                   tracking: fs != 0 ? gs.charSpace / fs * 1000 : 0, wordSpaced: gs.wordSpace != 0)
        // continue the open block when this run carries on its line or starts the next one
        if let t = openText, !t.closed, items.count > mergeBarrier, let last = items.last, case .text(let lt) = last.kind, lt === t,
           last.context == ctx, last.opacity == alpha, last.blend == gs.blend, t.slice.stream == level.stream, stack.count >= t.depth,
           t.reason == why, t.positioned == positionable {
            var fits = !positionable
            if positionable, let prev = t.runs.last, let pe = prev.glyphs.last?.end, let ps = prev.glyphs.first?.origin, let ns = glyphs.first?.origin {
                let (along, across, size) = PDFVectorGeometry.offset(from: pe, to: ns, basis: prev.basis)
                let sameBasis = PDFVectorGeometry.sameDirection(prev.basis, basis)
                if sameBasis, abs(across) < size * 0.6, along > -size * 0.5, along < size * 1.2 {
                    fits = t.glyphCount + glyphs.count <= limits.maxTextGlyphs
                } else if sameBasis, let head = t.runs.first, head.font === font, head.fill == fillPaint, head.mode == mode,
                          abs(hypot(head.basis.c, head.basis.d) - hypot(basis.c, basis.d)) < size * 0.01,
                          t.lineCount < limits.maxTextLines, t.glyphCount + glyphs.count <= limits.maxTextGlyphs {
                    // a new line of the same paragraph: same font and size, one constant line pitch below the last line
                    let (a2, c2, _) = PDFVectorGeometry.offset(from: t.lineOrigin, to: ns, basis: prev.basis)
                    let pitch = -c2
                    if pitch > size * 0.7, pitch < size * 2.6, abs(a2) < size * 30, t.pitch == 0 || abs(pitch - t.pitch) < t.pitch * 0.04 {
                        fits = true
                        t.lineCount += 1
                        t.pitch = pitch
                        t.lineOrigin = ns
                    }
                }
                _ = ps
            }
            if fits {
                t.runs.append(run)
                t.glyphCount += glyphs.count
                t.slice.range = t.slice.range.lowerBound..<end
                items[items.count - 1].bounds = last.bounds.union(bounds)
                return
            }
        }
        if skipForBand(level, start: start, adding: true) { return }
        // Core Graphics composites each glyph on its own, so translucent glyphs that touch add up where they
        // overlap: the reference rendering of translucent text keeps its alpha, and a type layer or outline (which
        // fade as one) is only accepted when it looks the same.
        var slice = PDFVectorSlice(stream: level.stream, range: start..<end, state: gs, opaque: !baked && alpha >= 1)
        slice.chain = chain
        slice.inText = level.inText
        slice.textMatrix = tmAtStart
        slice.lineMatrix = level.tlm
        let t = PDFVectorText(slice: slice)
        t.runs = [run]
        t.positioned = positionable
        t.glyphCount = glyphs.count
        t.depth = stack.count
        t.reason = why
        t.lineOrigin = glyphs.first?.origin ?? .zero
        let b = positionable ? bounds : bounds.intersection(canvas)
        items.append(PDFVectorItem(kind: .text(t), context: ctx, opacity: alpha, blend: gs.blend, bounds: b))
        openText = t
    }

    // MARK: Annotations

    /// Visible annotation appearances are part of what the page shows: each becomes a form drawn on top.
    private func appendAnnotations() throws {
        guard includeAnnotations, !banding, let pd = page.dictionary, let annots = PDFVectorObj.array(pd, "Annots") else { return }
        var content = ""
        var xobjects: [(String, CGPDFStreamRef)] = []
        for o in PDFVectorObj.objects(annots).prefix(2000) {
            guard let a = PDFVectorObj.asDict(o) else { continue }
            let flags = PDFVectorObj.int(a, "F") ?? 0
            if flags & 2 != 0 || flags & 32 != 0 { continue }   // hidden / no view
            if PDFVectorObj.name(a, "Subtype") == "Popup" { continue }
            guard let ap = PDFVectorObj.dict(a, "AP"), let rect = PDFVectorObj.rect(PDFVectorObj.numbers(a, "Rect")) else { continue }
            var stream = PDFVectorObj.stream(ap, "N")
            if stream == nil, let states = PDFVectorObj.dict(ap, "N") {
                let state = PDFVectorObj.name(a, "AS") ?? "Off"
                stream = PDFVectorObj.stream(states, state)
            }
            guard let s = stream, let d = CGPDFStreamGetDictionary(s), let bbox = PDFVectorObj.rect(PDFVectorObj.numbers(d, "BBox")), bbox.width > 0, bbox.height > 0 else { continue }
            // the appearance's transformed bounding box is fitted to the annotation rectangle
            let m = PDFVectorObj.matrix(PDFVectorObj.numbers(d, "Matrix")) ?? .identity
            let tb = bbox.applying(m)
            guard tb.width > 0, tb.height > 0 else { continue }
            let sx = rect.width / tb.width, sy = rect.height / tb.height
            let a2 = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: rect.minX - tb.minX * sx, ty: rect.minY - tb.minY * sy)
            let n = "PVAnnot\(xobjects.count)"
            xobjects.append((n, s))
            content += "q \(PDFVectorWriter.matrix(a2)) cm /\(n) Do Q\n"
        }
        guard !xobjects.isEmpty else { return }
        annotationForms = xobjects
        streams.append(Stream(bytes: Array(content.utf8), resources: nil))
        annotationStream = streams.count - 1
        gs = PDFVectorGState(ctm: pageToDoc)
        stack = []
        openText = nil
        mergeBarrier = items.count
        let lv = Level(stream: streams.count - 1, bytes: streams[streams.count - 1].bytes, resources: nil, baseContext: [], baseClipCount: 0,
                       baseCTM: pageToDoc, depth: 0, stackBase: 0)
        annotationLookup = Dictionary(xobjects.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        defer { annotationLookup = nil }
        do { try interpretAnnotations(lv) } catch Abort.rasterizeStream { /* individual appearances fall back on their own */ }
    }

    /// Appearance streams drawn by the synthetic annotation content (name → stream), also needed by the writer.
    private(set) var annotationForms: [(String, CGPDFStreamRef)] = []
    private(set) var annotationStream: Int? = nil
    private var annotationLookup: [String: CGPDFStreamRef]? = nil
    /// PDFKit draws annotation appearances with the page; set to false to import the page content only.
    var includeAnnotations = true

    private func interpretAnnotations(_ level: Level) throws {
        let O = PDFVectorOp.self
        while level.lexer.next() {
            let a = level.lexer.operands
            switch level.lexer.op {
            case O.q: stack.append(gs)
            case O.Q: if !stack.isEmpty { gs = stack.removeLast() }
            case O.cm:
                if a.count >= 6 { gs.ctm = CGAffineTransform(a: num(a, 0), b: num(a, 1), c: num(a, 2), d: num(a, 3), tx: num(a, 4), ty: num(a, 5)).concatenating(gs.ctm) }
            case O.Do:
                if let n = a.first?.name, let s = annotationLookup?[n], let d = CGPDFStreamGetDictionary(s) {
                    try form(level, s, d, name: "Annotation", range: level.lexer.start..<level.lexer.end)
                }
            default: break
            }
        }
        flushBand(level, end: level.lexer.bytes.count)
    }
}
