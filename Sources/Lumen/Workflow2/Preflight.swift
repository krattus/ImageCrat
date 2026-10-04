import AppKit
import CoreImage
import ImageCratCore

// MARK: - Model

enum PreflightKind: String, CaseIterable, Identifiable {
    case linkedMissing, linkedModified, missingFont, smartUpscaled, tinyText, outOfGamut
    case emptyLayer, maskHidesAll, zeroOpacity, offCanvas, hiddenLayer, duplicateLayer
    case hiddenEffects, oversizedRaster, largeEmbedded, defaultName

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linkedMissing: return "Missing linked files"
        case .linkedModified: return "Linked files changed on disk"
        case .missingFont: return "Missing fonts"
        case .smartUpscaled: return "Smart objects scaled above 100%"
        case .tinyText: return "Very small text"
        case .outOfGamut: return "Colours out of gamut"
        case .emptyLayer: return "Empty layers"
        case .maskHidesAll: return "Masks that hide everything"
        case .zeroOpacity: return "Layers at 0% opacity"
        case .offCanvas: return "Layers entirely off-canvas"
        case .hiddenLayer: return "Hidden layers"
        case .duplicateLayer: return "Duplicate layers"
        case .hiddenEffects: return "Unused effects"
        case .oversizedRaster: return "Pixels outside the canvas"
        case .largeEmbedded: return "Large embedded smart objects"
        case .defaultName: return "Default layer names"
        }
    }

    var symbol: String {
        switch self {
        case .linkedMissing: return "link.badge.plus"
        case .linkedModified: return "arrow.triangle.2.circlepath"
        case .missingFont: return "textformat"
        case .smartUpscaled: return "arrow.up.left.and.arrow.down.right"
        case .tinyText: return "textformat.size.smaller"
        case .outOfGamut: return "paintpalette"
        case .emptyLayer: return "square.dashed"
        case .maskHidesAll: return "circle.slash"
        case .zeroOpacity: return "circle.dotted"
        case .offCanvas: return "arrow.up.right.square"
        case .hiddenLayer: return "eye.slash"
        case .duplicateLayer: return "plus.square.on.square"
        case .hiddenEffects: return "fx"
        case .oversizedRaster: return "crop"
        case .largeEmbedded: return "shippingbox"
        case .defaultName: return "character.cursor.ibeam"
        }
    }

    /// 2 = problem for output, 1 = worth a look, 0 = tidiness / file size.
    var severity: Int {
        switch self {
        case .linkedMissing, .missingFont: return 2
        case .linkedModified, .smartUpscaled, .tinyText, .outOfGamut: return 1
        default: return 0
        }
    }

    var fixTitle: String? {
        switch self {
        case .linkedMissing: return "Embed"
        case .linkedModified: return "Update"
        case .missingFont: return "Use Helvetica"
        case .smartUpscaled: return "Scale to 100%"
        case .tinyText: return "Enlarge"
        case .outOfGamut: return nil
        case .emptyLayer, .maskHidesAll, .zeroOpacity, .offCanvas, .hiddenLayer: return "Delete"
        case .duplicateLayer: return "Delete Copies"
        case .hiddenEffects: return "Remove"
        case .oversizedRaster: return "Trim"
        case .largeEmbedded: return nil                 // needs a file name: Convert to Linked…
        case .defaultName: return "Auto-Name"
        }
    }

    /// Fixes that never change how the document looks: pre-selected in Clean Up Document.
    var cleanupDefault: Bool {
        switch self {
        case .emptyLayer, .zeroOpacity, .maskHidesAll, .hiddenEffects, .oversizedRaster: return true
        default: return false
        }
    }
}

struct PreflightIssue: Identifiable {
    let id = UUID()
    var kind: PreflightKind
    var layerIDs: [UUID]
    var title: String
    var detail: String
    /// Estimated bytes saved by the fix (file size related issues).
    var saves = 0
}

struct PreflightSizeRow: Identifiable {
    var id: String
    var layerID: UUID?
    var name: String
    var kind: String
    var bytes: Int
}

struct PreflightReport {
    var issues: [PreflightIssue] = []
    var sizes: [PreflightSizeRow] = []
    var totalBytes = 0
    var scanned = Date()

    func issues(_ k: PreflightKind) -> [PreflightIssue] { issues.filter { $0.kind == k } }
    var kinds: [PreflightKind] { PreflightKind.allCases.filter { k in issues.contains { $0.kind == k } } }
}

// MARK: - Scan

enum Preflight {
    static let defaultNamePattern: NSRegularExpression = {
        var bases = ["Layer", "Group", "Rectangle", "Rounded Rectangle", "Ellipse", "Polygon", "Triangle", "Line", "Shape", "Path", "Color Fill", "Gradient Fill", "Pattern Fill",
                     "Layer via Copy", "Layer via Cut", "Merged", "Artboard", "Frame", "Dropped Image", "Pasted Layer", "Embedded"]
        bases += AdjustmentKind.allCases.map(\.displayName)
        let alt = bases.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return try! NSRegularExpression(pattern: "^(?:\(alt))(?: \\d+)?(?: copy(?: \\d+)?)*$", options: [.caseInsensitive])
    }()

    static func isDefaultName(_ name: String) -> Bool {
        if name == "Background" { return false }
        let r = NSRange(name.startIndex..., in: name)
        if defaultNamePattern.firstMatch(in: name, options: [], range: r) != nil { return true }
        return name.range(of: #" copy( \d+)?$"#, options: .regularExpression) != nil
    }

    static func fontAvailable(_ name: String) -> Bool { NSFont(name: name, size: 12) != nil }

    static func fontNames(_ t: TextContent) -> [String] {
        var n = [t.fontName]
        for r in t.runs { if let f = r.style.fontName, !n.contains(f) { n.append(f) } }
        return n
    }

    /// Smallest rendered font size (px) of a text layer, including its transform.
    static func smallestTextSize(_ t: TextContent) -> Double {
        let tr = t.transform
        let scale = sqrt(abs(Double(tr.a * tr.d - tr.b * tr.c)))
        var s = t.fontSize
        for r in t.runs { if let f = r.style.fontSize { s = min(s, f) } }
        return s * (scale > 0 ? scale : 1)
    }

    /// Largest scale factor a smart object's source is stretched by.
    static func smartScale(_ so: SmartObjectContent) -> Double {
        let sz = so.source.size
        guard sz.width > 0, sz.height > 0 else { return 1 }
        let q = so.quad
        let sx = max(q.tl.distance(to: q.tr), q.bl.distance(to: q.br)) / sz.width
        let sy = max(q.tl.distance(to: q.bl), q.tr.distance(to: q.br)) / sz.height
        return Double(max(sx, sy))
    }

    // MARK: Size estimates

    /// Fast content hash of a buffer (cached per buffer version).
    static func hash(_ b: PixelBuffer) -> UInt64 {
        b.derived("w2.hash") { () -> UInt64 in
            var h: UInt64 = 0xcbf29ce484222325
            let rb = b.width * b.bytesPerPixel
            let words = rb / 8
            for y in 0..<b.height {
                let row = UnsafeRawPointer(b.data + y * b.bytesPerRow)
                for x in 0..<words { h = (h ^ row.loadUnaligned(fromByteOffset: x * 8, as: UInt64.self)) &* 0x100000001b3 }
                for x in (words * 8)..<rb { h = (h ^ UInt64(row.load(fromByteOffset: x, as: UInt8.self))) &* 0x100000001b3 }
            }
            return h
        }
    }

    /// Estimated bytes a buffer takes in a .lumen file (LZFSE of the packed rows; large buffers are sampled).
    static func encodedSize(_ b: PixelBuffer) -> Int {
        b.derived("w2.size") { () -> Int in
            let rb = b.width * b.bytesPerPixel
            let total = rb * b.height
            guard total > 0 else { return 0 }
            func packed(_ rows: [Int]) -> Int {
                var raw = Data(count: rb * rows.count)
                raw.withUnsafeMutableBytes { dst in
                    for (i, y) in rows.enumerated() { memcpy(dst.baseAddress! + i * rb, b.data + y * b.bytesPerRow, rb) }
                }
                return ((try? (raw as NSData).compressed(using: .lzfse) as Data) ?? raw).count
            }
            // sample 12 bands of 64 rows (whole buffer when it is small or too short to sample)
            let bands = 12, bandRows = min(64, b.height / bands)
            if total <= 8_000_000 || bandRows < 1 { return packed(Array(0..<b.height)) + 64 }
            var rows: [Int] = []
            for i in 0..<bands { let y0 = (b.height - bandRows) * i / (bands - 1); rows += Array(y0..<(y0 + bandRows)) }
            let sample = packed(rows)
            return Int(Double(sample) * Double(b.height) / Double(rows.count)) + 64
        }
    }

    static func encodedSize(_ st: DocumentState) -> Int {
        st.layers.reduce(0) { $0 + encodedSize($1) } + (st.selection.map(encodedSize) ?? 0) + st.alphaChannels.reduce(0) { $0 + encodedSize($1.buffer) } + 600
    }

    /// Estimated bytes of a layer (its own pixels, mask and embedded sources; groups include their children).
    static func encodedSize(_ l: Layer) -> Int {
        var n = 700        // properties, effects
        if let m = l.mask { n += encodedSize(m.buffer) }
        switch l.content {
        case .raster(let r): n += encodedSize(r.buffer)
        case .text(let t): n += 900 + t.text.utf8.count + t.runs.count * 80
        case .shape: n += 500
        case .fill, .adjustment: n += 400
        case .smartObject(let so):
            switch so.source {
            case .image(let b): n += encodedSize(b)
            case .document(let d): n += encodedSize(d)
            }
            n += so.filters.count * 200
        case .group(let g): n += g.children.reduce(0) { $0 + encodedSize($1) }
        }
        return n
    }

    /// "What makes this file big": one row per leaf layer (groups are expanded), largest first, plus document-level data.
    static func sizeBreakdown(_ st: DocumentState, extras: [(String, Int)] = []) -> (rows: [PreflightSizeRow], total: Int) {
        var rows: [PreflightSizeRow] = []
        func add(_ layers: [Layer], path: String) {
            for l in layers {
                if l.isGroup {
                    rows.append(PreflightSizeRow(id: l.id.uuidString, layerID: l.id, name: path + l.name, kind: "Group", bytes: 700 + (l.mask.map { encodedSize($0.buffer) } ?? 0)))
                    add(l.children, path: path + l.name + " / ")
                } else {
                    rows.append(PreflightSizeRow(id: l.id.uuidString, layerID: l.id, name: path + l.name, kind: l.kindName, bytes: encodedSize(l)))
                }
            }
        }
        add(st.layers, path: "")
        if let s = st.selection { rows.append(PreflightSizeRow(id: "selection", layerID: nil, name: "Selection", kind: "Document", bytes: encodedSize(s))) }
        if !st.alphaChannels.isEmpty {
            rows.append(PreflightSizeRow(id: "channels", layerID: nil, name: "Alpha Channels (\(st.alphaChannels.count))", kind: "Document",
                                         bytes: st.alphaChannels.reduce(0) { $0 + encodedSize($1.buffer) }))
        }
        for (name, bytes) in extras where bytes > 0 { rows.append(PreflightSizeRow(id: "x-" + name, layerID: nil, name: name, kind: "Document", bytes: bytes)) }
        rows.sort { $0.bytes > $1.bytes }
        return (rows, rows.reduce(0) { $0 + $1.bytes } + 600)
    }

    // MARK: Gamut

    /// Fraction (0…1) of visible pixels whose colour does not survive the proof profile.
    static func outOfGamutFraction(_ st: DocumentState, proof: ProofSettings) -> Double {
        let sp = CanvasSpace(width: st.width, height: st.height)
        let s = min(1, 200 / CGFloat(max(st.width, st.height)))
        let w = max(1, Int(CGFloat(st.width) * s)), h = max(1, Int(CGFloat(st.height) * s))
        let small = Compositor.shared.composite(st).cropped(to: sp.ciCanvas)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / CGFloat(st.width), y: CGFloat(h) / CGFloat(st.height)))
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        var a = proof, b = proof
        a.gamutColor = RGBA(r: 0, g: 1, b: 0); b.gamutColor = RGBA(r: 1, g: 0, b: 1)
        let space = CanvasSpace(width: w, height: h)
        let base = RenderEngine.renderBuffer(small, docRect: IRect(x: 0, y: 0, width: w, height: h), space: space)
        let ba = RenderEngine.renderBuffer(ColorConvert.gamutWarning(small, settings: a).cropped(to: rect), docRect: IRect(x: 0, y: 0, width: w, height: h), space: space)
        let bb = RenderEngine.renderBuffer(ColorConvert.gamutWarning(small, settings: b).cropped(to: rect), docRect: IRect(x: 0, y: 0, width: w, height: h), space: space)
        var flagged = 0, visible = 0
        for y in 0..<h {
            for x in 0..<w {
                guard base.alpha(x, y) > 8 else { continue }
                visible += 1
                let p = ba.pixel(x, y), q = bb.pixel(x, y)
                if abs(Int(p.0) - Int(q.0)) + abs(Int(p.1) - Int(q.1)) + abs(Int(p.2) - Int(q.2)) > 60 { flagged += 1 }
            }
        }
        return visible == 0 ? 0 : Double(flagged) / Double(visible)
    }

    // MARK: Scan

    /// Signature used to find identical layers.
    static func signature(_ l: Layer) -> String? {
        var key: String
        switch l.content {
        case .raster(let r):
            guard r.buffer.opaqueBounds() != nil else { return nil }
            key = "R|\(r.buffer.width)x\(r.buffer.height)|\(r.origin.x),\(r.origin.y)|\(hash(r.buffer))"
        case .text(let t): key = "T|" + ((try? JSONEncoder().encode(t)).flatMap { String(data: $0, encoding: .utf8) } ?? UUID().uuidString)
        case .shape(let s): key = "S|" + ((try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? UUID().uuidString)
        case .fill(let f): key = "F|" + ((try? JSONEncoder().encode(f)).flatMap { String(data: $0, encoding: .utf8) } ?? UUID().uuidString)
        case .smartObject(let so):
            let src: String
            switch so.source {
            case .image(let b): src = "\(b.width)x\(b.height)|\(hash(b))"
            case .document(let d): src = "\(d.width)x\(d.height)|\(d.allLayers.map(\.id.uuidString).joined())"
            }
            key = "O|\(src)|\(so.quad)|\(so.filters.count)|\(so.linkedURL?.path ?? "")"
        case .adjustment, .group: return nil
        }
        if let m = l.mask { key += "|M\(m.origin.x),\(m.origin.y),\(m.buffer.width)x\(m.buffer.height),\(hash(m.buffer)),\(m.isEnabled)" }
        key += "|\(l.opacity)|\(l.fillOpacity)|\(l.blendMode.rawValue)|\(l.isClipped)|\(l.isVisible)|\(l.effects.hasAny ? ((try? JSONEncoder().encode(l.effects))?.count ?? 0) : 0)"
        return key
    }

    /// Value signature of an effect that ignores per-instance ids (gradient stops carry UUIDs).
    private static func sig<T: Encodable>(_ v: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let d = try? enc.encode(v), let s = String(data: d, encoding: .utf8) else { return UUID().uuidString }
        return s.replacingOccurrences(of: #""id":"[0-9A-Fa-f-]{36}",?"#, with: "", options: .regularExpression)
    }

    private static let defaultSignatures: [String: String] = {
        let d = LayerEffects()
        return ["dropShadow": sig(d.dropShadow), "innerShadow": sig(d.innerShadow), "outerGlow": sig(d.outerGlow), "innerGlow": sig(d.innerGlow), "bevel": sig(d.bevel),
                "satin": sig(d.satin), "colorOverlay": sig(d.colorOverlay), "gradientOverlay": sig(d.gradientOverlay), "patternOverlay": sig(d.patternOverlay), "stroke": sig(d.stroke)]
    }()

    /// Names of effects / smart filters that are switched off but still stored with the layer.
    static func unusedEffects(_ l: Layer) -> [String] {
        let fx = l.effects
        var n: [String] = []
        if !fx.enabled && fx.hasAny { n.append("all effects (switched off)") }
        func changed<T: Encodable>(_ key: String, _ v: T) -> Bool { sig(v) != defaultSignatures[key] }
        if !fx.dropShadow.enabled && changed("dropShadow", fx.dropShadow) { n.append("Drop Shadow") }
        if !fx.innerShadow.enabled && changed("innerShadow", fx.innerShadow) { n.append("Inner Shadow") }
        if !fx.outerGlow.enabled && changed("outerGlow", fx.outerGlow) { n.append("Outer Glow") }
        if !fx.innerGlow.enabled && changed("innerGlow", fx.innerGlow) { n.append("Inner Glow") }
        if !fx.bevel.enabled && changed("bevel", fx.bevel) { n.append("Bevel & Emboss") }
        if !fx.satin.enabled && changed("satin", fx.satin) { n.append("Satin") }
        if !fx.colorOverlay.enabled && changed("colorOverlay", fx.colorOverlay) { n.append("Color Overlay") }
        if !fx.gradientOverlay.enabled && changed("gradientOverlay", fx.gradientOverlay) { n.append("Gradient Overlay") }
        if !fx.patternOverlay.enabled && changed("patternOverlay", fx.patternOverlay) { n.append("Pattern Overlay") }
        if !fx.stroke.enabled && changed("stroke", fx.stroke) { n.append("Stroke") }
        let extras = fx.extraDropShadows.filter { !$0.enabled }.count + fx.extraInnerShadows.filter { !$0.enabled }.count + fx.extraColorOverlays.filter { !$0.enabled }.count
            + fx.extraGradientOverlays.filter { !$0.enabled }.count + fx.extraStrokes.filter { !$0.enabled }.count
        if extras > 0 { n.append("\(extras) extra effect\(extras == 1 ? "" : "s")") }
        if let so = l.smart {
            let off = so.filtersEnabled ? so.filters.filter { !$0.enabled }.count : so.filters.count
            if off > 0 { n.append("\(off) smart filter\(off == 1 ? "" : "s")") }
        }
        return n
    }

    static func removeUnusedEffects(_ l: inout Layer) {
        let d = LayerEffects()
        if !l.effects.enabled { l.effects = d } else {
            if !l.effects.dropShadow.enabled { l.effects.dropShadow = d.dropShadow }
            if !l.effects.innerShadow.enabled { l.effects.innerShadow = d.innerShadow }
            if !l.effects.outerGlow.enabled { l.effects.outerGlow = d.outerGlow }
            if !l.effects.innerGlow.enabled { l.effects.innerGlow = d.innerGlow }
            if !l.effects.bevel.enabled { l.effects.bevel = d.bevel }
            if !l.effects.satin.enabled { l.effects.satin = d.satin }
            if !l.effects.colorOverlay.enabled { l.effects.colorOverlay = d.colorOverlay }
            if !l.effects.gradientOverlay.enabled { l.effects.gradientOverlay = d.gradientOverlay }
            if !l.effects.patternOverlay.enabled { l.effects.patternOverlay = d.patternOverlay }
            if !l.effects.stroke.enabled { l.effects.stroke = d.stroke }
            l.effects.extraDropShadows.removeAll { !$0.enabled }
            l.effects.extraInnerShadows.removeAll { !$0.enabled }
            l.effects.extraColorOverlays.removeAll { !$0.enabled }
            l.effects.extraGradientOverlays.removeAll { !$0.enabled }
            l.effects.extraStrokes.removeAll { !$0.enabled }
        }
        if var so = l.smart {
            if so.filtersEnabled { so.filters.removeAll { !$0.enabled } } else { so.filters = []; so.filtersEnabled = true }
            so.sourceRevision += 1
            l.smart = so
        }
    }

    /// True when deleting `id` could change the look: a clipped layer above would clip to something else.
    static func isClippingBase(_ id: UUID, in st: DocumentState) -> Bool {
        let sib = st.siblings(of: id)
        guard let i = sib.firstIndex(where: { $0.id == id }), !sib[i].isClipped else { return false }
        return i + 1 < sib.count && sib[i + 1].isClipped
    }

    static func scan(_ st: DocumentState, prefs: Workflow2Prefs = Workflow2Settings.shared.prefs, proof: ProofSettings? = nil, checkGamut: Bool = true,
                     extras: [(String, Int)] = []) -> PreflightReport {
        var rep = PreflightReport()
        let canvas = st.canvasRect
        var hidden: [UUID] = [], named: [UUID] = []
        var signatures: [String: [UUID]] = [:]

        func visit(_ layers: [Layer], ancestorsVisible: Bool) {
            for l in layers {
                let base = isClippingBase(l.id, in: st)
                // naming
                if isDefaultName(l.name) { named.append(l.id) }
                // visibility
                if !l.isVisible { hidden.append(l.id) }
                if l.isVisible, l.opacity <= 0.001 {
                    rep.issues.append(PreflightIssue(kind: .zeroOpacity, layerIDs: [l.id], title: "“\(l.name)” is at 0% opacity", detail: "It contributes nothing to the image.", saves: encodedSize(l)))
                }
                if let m = l.mask, m.isEnabled, m.outsideValue == 0, m.buffer.opaqueBounds() == nil {
                    rep.issues.append(PreflightIssue(kind: .maskHidesAll, layerIDs: [l.id], title: "The mask of “\(l.name)” hides the whole layer", detail: "Nothing of this layer is visible.", saves: encodedSize(l)))
                }
                let unused = unusedEffects(l)
                if !unused.isEmpty {
                    rep.issues.append(PreflightIssue(kind: .hiddenEffects, layerIDs: [l.id], title: "“\(l.name)” carries switched-off effects", detail: unused.joined(separator: ", ")))
                }
                switch l.content {
                case .raster(let r):
                    if r.buffer.opaqueBounds() == nil {
                        if !base { rep.issues.append(PreflightIssue(kind: .emptyLayer, layerIDs: [l.id], title: "“\(l.name)” has no pixels", detail: "Empty pixel layer.", saves: encodedSize(l))) }
                    } else if let ob = r.buffer.opaqueBounds() {
                        let content = ob.offsetBy(dx: r.origin.x, dy: r.origin.y)
                        let inside = content.intersection(canvas)
                        if inside.isEmpty {
                            rep.issues.append(PreflightIssue(kind: .offCanvas, layerIDs: [l.id], title: "“\(l.name)” is completely outside the canvas", detail: "\(ob.width)×\(ob.height) px that can't be seen.", saves: encodedSize(l)))
                        } else {
                            let wasted = content.width * content.height - inside.width * inside.height
                            if wasted > 40_000, Double(wasted) > 0.1 * Double(content.width * content.height) {
                                let ratio = Double(wasted) / Double(max(1, content.width * content.height))
                                rep.issues.append(PreflightIssue(kind: .oversizedRaster, layerIDs: [l.id], title: "“\(l.name)” extends far beyond the canvas",
                                                                 detail: "\(Int((ratio * 100).rounded()))% of its pixels (\(wasted / 1000)k px) are outside the canvas.",
                                                                 saves: Int(Double(encodedSize(r.buffer)) * ratio)))
                            }
                        }
                    }
                case .text(let t):
                    if t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        rep.issues.append(PreflightIssue(kind: .emptyLayer, layerIDs: [l.id], title: "“\(l.name)” has no text", detail: "Empty type layer."))
                    } else {
                        let missing = fontNames(t).filter { !fontAvailable($0) }
                        if !missing.isEmpty {
                            rep.issues.append(PreflightIssue(kind: .missingFont, layerIDs: [l.id], title: "“\(l.name)” uses a font that is not installed", detail: missing.joined(separator: ", ")))
                        }
                        let px = smallestTextSize(t)
                        if px < prefs.preflightMinTextPx {
                            rep.issues.append(PreflightIssue(kind: .tinyText, layerIDs: [l.id], title: "Text in “\(l.name)” is only \(String(format: "%.1f", px)) px tall",
                                                             detail: "Smaller than \(Int(prefs.preflightMinTextPx)) px: hard to read."))
                        }
                        if !TextRenderer.docBounds(t).intersects(st.canvasCGRect) {
                            rep.issues.append(PreflightIssue(kind: .offCanvas, layerIDs: [l.id], title: "“\(l.name)” is completely outside the canvas", detail: "Type layer."))
                        }
                    }
                case .shape(let s):
                    let b = ShapeRenderer.docBounds(s)
                    if b.isEmpty || b.isNull {
                        rep.issues.append(PreflightIssue(kind: .emptyLayer, layerIDs: [l.id], title: "“\(l.name)” has no shape", detail: "Empty shape layer."))
                    } else if !b.intersects(st.canvasCGRect) {
                        rep.issues.append(PreflightIssue(kind: .offCanvas, layerIDs: [l.id], title: "“\(l.name)” is completely outside the canvas", detail: "Shape layer."))
                    }
                case .smartObject(let so):
                    let scale = smartScale(so)
                    if scale > 1.01 {
                        let ppi = st.resolution / scale
                        rep.issues.append(PreflightIssue(kind: .smartUpscaled, layerIDs: [l.id], title: "“\(l.name)” is scaled to \(Int((scale * 100).rounded()))%",
                                                         detail: "Effective resolution \(Int(ppi.rounded())) ppi (document: \(Int(st.resolution)) ppi)" + (ppi < prefs.preflightMinPPI ? " — below \(Int(prefs.preflightMinPPI)) ppi." : ".")))
                    }
                    if let url = so.linkedURL {
                        if !FileManager.default.fileExists(atPath: url.path) {
                            rep.issues.append(PreflightIssue(kind: .linkedMissing, layerIDs: [l.id], title: "The file linked by “\(l.name)” is missing", detail: url.path))
                        } else if let mod = AppActions.modificationDate(url), let known = so.linkedModified, abs(mod.timeIntervalSince(known)) > 1 {
                            rep.issues.append(PreflightIssue(kind: .linkedModified, layerIDs: [l.id], title: "“\(l.name)” is out of date", detail: "\(url.lastPathComponent) changed on disk."))
                        }
                    } else {
                        let bytes: Int
                        switch so.source { case .image(let b): bytes = encodedSize(b); case .document(let d): bytes = encodedSize(d) }
                        if Double(bytes) > prefs.preflightLargeEmbedMB * 1_000_000 {
                            rep.issues.append(PreflightIssue(kind: .largeEmbedded, layerIDs: [l.id], title: "“\(l.name)” embeds \(Workflow2Util.byteString(bytes))",
                                                             detail: "Convert it to a linked file to keep this document small.", saves: bytes))
                        }
                    }
                    if !so.quad.bounds.intersects(st.canvasCGRect) {
                        rep.issues.append(PreflightIssue(kind: .offCanvas, layerIDs: [l.id], title: "“\(l.name)” is completely outside the canvas", detail: "Smart object.", saves: encodedSize(l)))
                    }
                case .group(let g):
                    if g.children.isEmpty {
                        rep.issues.append(PreflightIssue(kind: .emptyLayer, layerIDs: [l.id], title: "Group “\(l.name)” is empty", detail: "No layers inside."))
                    }
                    visit(g.children, ancestorsVisible: ancestorsVisible && l.isVisible)
                case .fill, .adjustment: break
                }
                if let sig = signature(l) { signatures[sig, default: []].append(l.id) }
            }
        }
        visit(st.layers, ancestorsVisible: true)

        for (_, ids) in signatures where ids.count > 1 {
            let order = st.allLayers.map(\.id)
            let sorted = ids.sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
            let names = sorted.compactMap { st.layer($0)?.name }
            rep.issues.append(PreflightIssue(kind: .duplicateLayer, layerIDs: sorted, title: "\(ids.count) identical layers: \(names.prefix(3).map { "“\($0)”" }.joined(separator: ", "))\(names.count > 3 ? "…" : "")",
                                             detail: "Same content, position and appearance.", saves: sorted.dropFirst().reduce(0) { $0 + (st.layer($1).map(encodedSize) ?? 0) }))
        }
        if !hidden.isEmpty {
            let usedByComps = !st.layerComps.isEmpty || !st.frames.isEmpty
            rep.issues.append(PreflightIssue(kind: .hiddenLayer, layerIDs: hidden, title: "\(hidden.count) hidden layer\(hidden.count == 1 ? "" : "s")",
                                             detail: usedByComps ? "Layer comps or animation frames may still show them." : hidden.prefix(4).compactMap { st.layer($0)?.name }.joined(separator: ", ") + (hidden.count > 4 ? "…" : ""),
                                             saves: hidden.reduce(0) { $0 + (st.layer($1).map(encodedSize) ?? 0) }))
        }
        if !named.isEmpty {
            rep.issues.append(PreflightIssue(kind: .defaultName, layerIDs: named, title: "\(named.count) layer\(named.count == 1 ? " has a" : "s have") default name\(named.count == 1 ? "" : "s")",
                                             detail: named.prefix(4).compactMap { st.layer($0)?.name }.joined(separator: ", ") + (named.count > 4 ? "…" : "")))
        }
        if checkGamut, let proof {
            let f = outOfGamutFraction(st, proof: proof)
            if f > 0.005 {
                rep.issues.append(PreflightIssue(kind: .outOfGamut, layerIDs: [], title: "\(String(format: "%.0f", max(1, f * 100)))% of the image is out of gamut",
                                                 detail: "For \(proof.profileName). View ▸ Gamut Warning shows where."))
            }
        }
        rep.issues.sort { a, b in
            a.kind.severity != b.kind.severity ? a.kind.severity > b.kind.severity
                : (PreflightKind.allCases.firstIndex(of: a.kind)! < PreflightKind.allCases.firstIndex(of: b.kind)!)
        }
        let (rows, total) = sizeBreakdown(st, extras: extras)
        rep.sizes = rows
        rep.totalBytes = total
        return rep
    }

    // MARK: Fixes

    /// A content-based name for a default-named layer, built with `BatchRename`'s template tokens.
    static func suggestedName(_ l: Layer, in st: DocumentState) -> String {
        var s = BatchRenameSettings()
        s.mode = .template
        s.stripCopy = true
        switch l.content {
        case .text(let t):
            let words = t.text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? "Text"
            return String(words.trimmingCharacters(in: .whitespaces).prefix(28))
        case .smartObject(let so):
            let n = (so.sourceName as NSString).deletingPathExtension
            if !n.isEmpty, n != "Embedded" { return n }
            s.template = "Smart Object {w}×{h}"
        case .shape(let sh): s.template = "\(sh.geometry.kindName) {w}×{h}"
        case .raster(let r):
            if r.buffer.opaqueBounds() == nil { return "Empty Layer" }
            s.template = "Pixels {w}×{h}"
        case .group(let g): return "Group (\(g.children.count) layer\(g.children.count == 1 ? "" : "s"))"
        case .adjustment(let a): return a.kind.displayName
        case .fill(let f):
            switch f.paint { case .color(let c): return "Fill #\(c.hex)"; default: return "Fill" }
        }
        return BatchRename.names(for: [l], s, state: st).first ?? l.name
    }

    /// Applies the fix of one issue to a state. Returns false when nothing changed.
    @discardableResult
    static func applyFix(_ issue: PreflightIssue, to st: inout DocumentState, prefs: Workflow2Prefs = Workflow2Settings.shared.prefs) -> Bool {
        var changed = false
        func delete(_ ids: [UUID]) {
            for id in ids where st.layer(id) != nil {
                if st.allLayers.filter({ !$0.isGroup }).count <= 1, st.layer(id)?.isGroup == false { continue }   // never delete the last layer
                if isClippingBase(id, in: st) { continue }
                st.removeLayer(id)
                changed = true
            }
        }
        switch issue.kind {
        case .emptyLayer, .maskHidesAll, .zeroOpacity, .offCanvas, .hiddenLayer:
            delete(issue.layerIDs)
        case .duplicateLayer:
            delete(Array(issue.layerIDs.dropFirst()))
        case .hiddenEffects:
            for id in issue.layerIDs { st.updateLayer(id) { removeUnusedEffects(&$0) }; changed = true }
        case .oversizedRaster:
            for id in issue.layerIDs {
                guard let r = st.layer(id)?.raster else { continue }
                let keep = r.frame.intersection(st.canvasRect)
                guard !keep.isEmpty, keep != r.frame else { continue }
                let nb = r.buffer.cropped(to: IRect(x: keep.x - r.origin.x, y: keep.y - r.origin.y, width: keep.width, height: keep.height))
                nb.markDirty()
                st.updateLayer(id) { $0.raster = RasterContent(buffer: nb, origin: IPoint(x: keep.x, y: keep.y)) }
                changed = true
            }
        case .linkedMissing:
            for id in issue.layerIDs {
                st.updateLayer(id) { l in if var so = l.smart { so.linkedURL = nil; so.linkedModified = nil; l.smart = so } }
                changed = true
            }
        case .linkedModified:
            for id in issue.layerIDs {
                guard let so = st.layer(id)?.smart, let url = so.linkedURL, let loaded = try? DocumentIO.load(url: url) else { continue }
                Workflow2Module.forget(loaded.id)
                let src: SmartSource = loaded.state.layers.count == 1 && loaded.state.layers[0].raster != nil ? .image(loaded.state.layers[0].raster!.buffer) : .document(loaded.state)
                st.updateLayer(id) { l in
                    if var s = l.smart { s.replaceSource(src); s.linkedModified = AppActions.modificationDate(url); l.smart = s }
                }
                changed = true
            }
        case .missingFont:
            for id in issue.layerIDs {
                st.updateLayer(id) { l in
                    guard var t = l.text else { return }
                    if !fontAvailable(t.fontName) { t.fontName = "Helvetica" }
                    for i in t.runs.indices { if let f = t.runs[i].style.fontName, !fontAvailable(f) { t.runs[i].style.fontName = "Helvetica" } }
                    t.normalizeRuns()
                    l.text = t
                }
                changed = true
            }
        case .tinyText:
            for id in issue.layerIDs {
                st.updateLayer(id) { l in
                    guard var t = l.text else { return }
                    let tr = t.transform
                    let scale = max(0.0001, sqrt(abs(Double(tr.a * tr.d - tr.b * tr.c))))
                    let target = prefs.preflightMinTextPx / scale
                    if t.fontSize < target { t.fontSize = target }
                    for i in t.runs.indices { if let f = t.runs[i].style.fontSize, f < target { t.runs[i].style.fontSize = target } }
                    t.normalizeRuns()
                    l.text = t
                }
                changed = true
            }
        case .smartUpscaled:
            for id in issue.layerIDs {
                st.updateLayer(id) { l in
                    guard var so = l.smart else { return }
                    let k = CGFloat(smartScale(so))
                    guard k > 1 else { return }
                    let c = CGPoint(x: so.quad.bounds.midX, y: so.quad.bounds.midY)
                    so.quad = so.quad.mapped { c + ($0 - c) / k }
                    so.warp = so.warp?.mapped { c + ($0 - c) / k }
                    l.smart = so
                }
                changed = true
            }
        case .defaultName:
            var used = Set(st.allLayers.map(\.name))
            for id in issue.layerIDs {
                guard let l = st.layer(id) else { continue }
                var name = suggestedName(l, in: st)
                if name.isEmpty || isDefaultName(name) { continue }
                if used.contains(name) { var i = 2; while used.contains("\(name) \(i)") { i += 1 }; name = "\(name) \(i)" }
                used.insert(name)
                st.updateLayer(id) { $0.name = name }
                changed = true
            }
        case .outOfGamut, .largeEmbedded:
            break
        }
        return changed
    }

    /// Applies fixes as ONE history step. Returns the number of issues fixed.
    @discardableResult
    static func fix(_ issues: [PreflightIssue], in d: Document, name: String) -> Int {
        AppActions.canvas?.commitCurrentTool()
        var st = d.state
        var n = 0
        for i in issues where applyFix(i, to: &st) { n += 1 }
        guard n > 0 else { return 0 }
        d.state = st
        d.commit(name)
        Compositor.shared.clearCaches()
        return n
    }

    /// Clean Up Document: every issue of the chosen kinds, one undo step.
    @discardableResult
    static func cleanUp(_ d: Document, kinds: Set<PreflightKind>, report: PreflightReport? = nil) -> Int {
        let rep = report ?? scan(d.state, checkGamut: false)
        return fix(rep.issues.filter { kinds.contains($0.kind) && $0.kind.fixTitle != nil }, in: d, name: "Clean Up Document")
    }

    /// Converts an embedded smart object to a linked .lumen file at `url` (one history step).
    @discardableResult
    static func convertToLinked(_ id: UUID, in d: Document, url: URL) -> Bool {
        guard let so = d.state.layer(id)?.smart else { return false }
        let st: DocumentState
        switch so.source {
        case .document(let s): st = s
        case .image(let b):
            var s = DocumentState(width: b.width, height: b.height)
            s.layers = [Layer.raster(name: "Layer 1", buffer: b)]
            st = s
        }
        do {
            let enc = PropertyListEncoder()
            enc.outputFormat = .binary
            try enc.encode(LumenFile(name: url.lastPathComponent, state: st)).write(to: url, options: .atomic)
        } catch { return false }
        d.updateLayer(id) { x in
            guard var s = x.smart else { return }
            s.linkedURL = url
            s.linkedModified = AppActions.modificationDate(url)
            s.sourceName = url.lastPathComponent
            x.smart = s
        }
        d.commit("Convert to Linked")
        return true
    }
}
