import Foundation

// MARK: - Minimal XML

/// A tiny tolerant XML reader (elements, attributes, text, CDATA, comments, entities). `XMLParser` lives in
/// FoundationXML outside Apple platforms, which the portable core does not import.
package final class MiniXMLElement {
    package let name: String
    package var attributes: [String: String]
    package var children: [MiniXMLElement] = []
    /// Concatenated text and CDATA content directly inside this element.
    package var text = ""

    package init(name: String, attributes: [String: String] = [:]) { self.name = name; self.attributes = attributes }

    package func child(_ n: String) -> MiniXMLElement? { children.first { $0.name == n } }

    /// Depth-first search (self included), bounded.
    package func descendants(named n: String, limit: Int = 100_000) -> [MiniXMLElement] {
        var out: [MiniXMLElement] = []
        var stack: [MiniXMLElement] = [self]
        var visited = 0
        while let e = stack.popLast(), visited < limit {
            visited += 1
            if e.name == n { out.append(e) }
            stack.append(contentsOf: e.children.reversed())
        }
        return out
    }
}

package enum MiniXML {
    package static let maxDepth = 128
    package static let maxElements = 200_000

    /// Parses a document and returns its root element (nil when there is none).
    package static func parse(_ s: String) -> MiniXMLElement? {
        let b = Array(s.utf8)
        let doc = MiniXMLElement(name: "#document")
        var stack: [MiniXMLElement] = [doc]
        var i = 0
        let n = b.count
        var elements = 0
        func starts(_ lit: String, at p: Int) -> Bool {
            let l = Array(lit.utf8)
            return p + l.count <= n && Array(b[p..<(p + l.count)]) == l
        }
        func find(_ lit: String, from p: Int) -> Int? {
            let l = Array(lit.utf8)
            guard let f = l.first, l.count <= n else { return nil }
            var q = p
            while q + l.count <= n {
                if b[q] == f && Array(b[q..<(q + l.count)]) == l { return q }
                q += 1
            }
            return nil
        }
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        func isNameEnd(_ c: UInt8) -> Bool { isSpace(c) || c == 0x3E || c == 0x2F || c == 0x3D }
        while i < n {
            if b[i] != 0x3C {   // text
                let start = i
                while i < n && b[i] != 0x3C { i += 1 }
                stack.last?.text += decodeEntities(String(decoding: b[start..<i], as: UTF8.self))
                continue
            }
            if starts("<!--", at: i) {
                i = (find("-->", from: i + 4).map { $0 + 3 }) ?? n
            } else if starts("<![CDATA[", at: i) {
                let s = i + 9
                let e = find("]]>", from: s) ?? n
                stack.last?.text += String(decoding: b[s..<e], as: UTF8.self)
                i = min(n, e + 3)
            } else if starts("<?", at: i) {
                i = (find("?>", from: i + 2).map { $0 + 2 }) ?? n
            } else if starts("<!", at: i) {
                var depth = 0
                i += 2
                while i < n {
                    if b[i] == 0x5B { depth += 1 } else if b[i] == 0x5D { depth -= 1 } else if b[i] == 0x3E && depth <= 0 { break }
                    i += 1
                }
                i += 1
            } else if starts("</", at: i) {
                var j = i + 2
                while j < n && !isNameEnd(b[j]) { j += 1 }
                let name = String(decoding: b[(i + 2)..<j], as: UTF8.self)
                while j < n && b[j] != 0x3E { j += 1 }
                i = j + 1
                if let idx = stack.lastIndex(where: { $0.name == name }), idx > 0 { stack.removeSubrange(idx...) }
            } else {
                var j = i + 1
                while j < n && !isNameEnd(b[j]) { j += 1 }
                let name = String(decoding: b[(i + 1)..<j], as: UTF8.self)
                var attrs: [String: String] = [:]
                var selfClosing = false
                while j < n {
                    while j < n && isSpace(b[j]) { j += 1 }
                    guard j < n else { break }
                    if b[j] == 0x3E { j += 1; break }
                    if b[j] == 0x2F { selfClosing = true; j += 1; continue }
                    let a0 = j
                    while j < n && !isNameEnd(b[j]) { j += 1 }
                    let an = String(decoding: b[a0..<j], as: UTF8.self)
                    if j == a0 { j += 1; continue }   // stray character
                    while j < n && isSpace(b[j]) { j += 1 }
                    var value = ""
                    if j < n && b[j] == 0x3D {
                        j += 1
                        while j < n && isSpace(b[j]) { j += 1 }
                        if j < n && (b[j] == 0x22 || b[j] == 0x27) {
                            let q = b[j]
                            let v0 = j + 1
                            var v1 = v0
                            while v1 < n && b[v1] != q { v1 += 1 }
                            value = String(decoding: b[v0..<v1], as: UTF8.self)
                            j = min(n, v1 + 1)
                        } else {
                            let v0 = j
                            while j < n && !isSpace(b[j]) && b[j] != 0x3E { j += 1 }
                            value = String(decoding: b[v0..<j], as: UTF8.self)
                        }
                    }
                    attrs[an] = decodeEntities(value)
                    selfClosing = false
                }
                i = j
                elements += 1
                guard elements <= maxElements else { break }
                let el = MiniXMLElement(name: name, attributes: attrs)
                stack.last?.children.append(el)
                if !selfClosing && stack.count <= maxDepth { stack.append(el) }
            }
        }
        return doc.children.first
    }

    package static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let ent = String(s[s.index(after: i)..<semi])
                var rep: String? = nil
                switch ent {
                case "lt": rep = "<"
                case "gt": rep = ">"
                case "amp": rep = "&"
                case "quot": rep = "\""
                case "apos": rep = "'"
                default:
                    if ent.hasPrefix("#x") || ent.hasPrefix("#X"), let v = UInt32(ent.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) {
                        rep = String(Character(u))
                    } else if ent.hasPrefix("#"), let v = UInt32(ent.dropFirst()), let u = Unicode.Scalar(v) {
                        rep = String(Character(u))
                    }
                }
                if let r = rep { out += r; i = s.index(after: semi); continue }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }
}

// MARK: - Krita presets

/// Krita paintop presets (`.kpp`): a PNG (the preset's thumbnail) whose text chunk "preset" holds the settings XML:
///
///     <Preset paintopid="paintbrush" name="…">
///       <param name="brush_definition" type="string"><![CDATA[<Brush type="auto_brush" spacing="0.1" angle="0"
///           useAutoSpacing="0" autoSpacingCoeff="0.8" …><MaskGenerator diameter="40" ratio="1" hfade="0.5"
///           vfade="0.5" type="circle" …/></Brush>]]></param>
///       <param name="OpacityValue" type="string"><![CDATA[1]]></param> …
///       <resources><resource type="brushes" name="…" filename="x.gbr" md5sum="…">BASE64</resource></resources>
///     </Preset>
///
/// Mapping: name ← Preset@name; size ← MaskGenerator@diameter (auto brushes) or the tip's size × Brush@scale;
/// spacing ← Brush@spacing (or autoSpacingCoeff / √diameter with useAutoSpacing, Krita's auto-spacing rule);
/// angle ← Brush@angle (radians) in degrees; roundness ← MaskGenerator@ratio; hardness ← MaskGenerator@hfade (Krita's
/// circle/rect mask is fully opaque out to hfade × radius, so hfade 1 = hard edge); opacity / flow ← OpacityValue /
/// FlowValue. Auto brushes import as computed round tips (tipKey nil). Predefined brushes use the embedded resource
/// (GBR / GIH via `GIMPBrush`, PNG via `PNGCodec` and the shared coverage rule, anything else as `.encoded`). When no
/// tip can be found the preset's own PNG (its thumbnail) becomes the tip, with the shared coverage rule (dark = paint).
package enum KritaPreset {
    package static func presetXML(_ data: Data) -> String? {
        let t = PNGCodec.textChunks(data)
        return t["preset"] ?? t["Preset"]
    }

    package static func isKritaPreset(_ data: Data) -> Bool {
        PNGCodec.isPNG(data) && presetXML(data) != nil
    }

    package static func read(data: Data, name: String) throws -> ImportedBrushSet {
        guard PNGCodec.isPNG(data) else { throw BrushImportError.unsupportedFormat("This file") }
        var set = ImportedBrushSet(name: name, format: "Krita preset")
        var params = BrushParams()
        var brushName = name
        var tip: ImportedTipImage? = nil
        var computed = false

        if let xml = presetXML(data), let root = MiniXML.parse(xml) {
            if let n = root.attributes["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { brushName = n }
            if let op = root.attributes["paintopid"] { set.format = "Krita preset (\(op))" }
            var paramValues: [String: String] = [:]
            for p in root.descendants(named: "param") {
                if let pn = p.attributes["name"], paramValues[pn] == nil { paramValues[pn] = p.text }
            }
            if let v = paramValues["OpacityValue"].flatMap({ Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) { params.opacity = v }
            if let v = paramValues["FlowValue"].flatMap({ Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) { params.flow = v }
            var resources = root.descendants(named: "resource")
            let brushDef = (paramValues["brush_definition"] ?? paramValues["requiredBrushFile"]).flatMap { MiniXML.parse($0) }
            if let bd = brushDef { resources += bd.descendants(named: "resource") }
            if let brush = brushDef.flatMap({ $0.name == "Brush" ? $0 : $0.descendants(named: "Brush").first }) {
                let type = brush.attributes["type"] ?? ""
                func attr(_ e: MiniXMLElement?, _ k: String) -> Double? {
                    e?.attributes[k].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0.isFinite ? $0 : nil }
                }
                if let a = attr(brush, "angle") { params.angle = a * 180 / .pi }
                let scale = attr(brush, "scale") ?? 1
                if type == "auto_brush" || brush.child("MaskGenerator") != nil && brush.attributes["filename"] == nil {
                    computed = true
                    let mg = brush.child("MaskGenerator")
                    if let d = attr(mg, "diameter"), d > 0 { params.size = d }
                    if let r = attr(mg, "ratio"), r > 0 { params.roundness = min(1, r) }
                    if let hf = attr(mg, "hfade") {
                        var hard = min(1, max(0, hf))
                        if (mg?.attributes["id"] ?? "").lowercased().contains("gauss") { hard *= 0.5 }   // gaussian falloff is softer
                        params.hardness = hard
                    }
                } else {
                    let file = brush.attributes["filename"] ?? ""
                    let match = resources.first { r in
                        let rf = r.attributes["filename"] ?? "", rn = r.attributes["name"] ?? ""
                        return !file.isEmpty && (rf == file || rn == file || lastComponent(rf) == lastComponent(file))
                    } ?? resources.first { ($0.attributes["type"] ?? "").lowercased().contains("brush") }
                    if let r = match, let decoded = Data(base64Encoded: r.text, options: .ignoreUnknownCharacters) {
                        let fname = (r.attributes["filename"] ?? file).lowercased()
                        if let t = tipImage(from: decoded, fileName: fname) {
                            tip = t.tip
                            if t.side > 0 { params.size = Double(t.side) * (scale > 0 ? scale : 1) }
                            if t.spacing > 0 { params.spacing = t.spacing }
                        }
                    }
                }
                if let sp = attr(brush, "spacing"), sp > 0 { params.spacing = sp }
                if (brush.attributes["useAutoSpacing"] ?? "") == "1" || (brush.attributes["useAutoSpacing"] ?? "").lowercased() == "true",
                   let coeff = attr(brush, "autoSpacingCoeff"), coeff > 0 {
                    params.spacing = coeff / max(1, params.size).squareRoot()
                }
            }
        }

        if !computed && tip == nil, let img = PNGCodec.decode(data) {
            let cov = BrushTipImaging.grayCoverage(fromRGBA: img)
            tip = ImportedTipImage(.gray(BrushTipImaging.squareGray(cov)))
            params.size = Double(max(cov.width, cov.height))
        }
        params.sanitize()
        var key: String? = nil
        if let t = tip { key = "kpp0"; set.tips["kpp0"] = t }
        guard computed || key != nil else { throw BrushImportError.noBrushes }
        set.brushes = [ImportedBrush(name: brushName, tipKey: key, params: params, includesToolSettings: false)]
        return set
    }

    private static func lastComponent(_ s: String) -> String {
        s.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? s
    }

    /// Decodes an embedded brush resource.
    private static func tipImage(from data: Data, fileName: String) -> (tip: ImportedTipImage, side: Int, spacing: Double)? {
        if fileName.hasSuffix(".gih") || (!GIMPBrush.isGBR(data) && GIMPBrush.looksLikeGIH(data)) {
            if let s = try? GIMPBrush.readGIH(data: data, name: fileName), let k = s.brushes.first?.tipKey, let t = s.tips[k] {
                return (t, Int(s.brushes[0].params.size), s.brushes[0].params.spacing)
            }
        }
        if fileName.hasSuffix(".gbr") || GIMPBrush.isGBR(data) {
            if let s = try? GIMPBrush.readGBR(data: data, name: fileName), let k = s.brushes.first?.tipKey, let t = s.tips[k] {
                return (t, Int(s.brushes[0].params.size), s.brushes[0].params.spacing)
            }
        }
        if PNGCodec.isPNG(data) {
            if let img = PNGCodec.decode(data) {
                let cov = BrushTipImaging.grayCoverage(fromRGBA: img)
                return (ImportedTipImage(.gray(BrushTipImaging.squareGray(cov))), max(cov.width, cov.height), 0)
            }
            return (ImportedTipImage(.encoded(data)), 0, 0)
        }
        if data.count > 4 {
            // Other image formats (JPEG, SVG, …): let the app decode them. Size unknown here.
            return (ImportedTipImage(.encoded(data)), 0, 0)
        }
        return nil
    }
}
