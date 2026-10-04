import AppKit
@testable import LumenUltra
import SwiftUI
import UniformTypeIdentifiers
import ImageCratCore

// SVG export: shape, type and solid / gradient fill layers become real SVG (paths, gradients, strokes) — for logos and
// UI artwork nothing is smaller or sharper. "Hybrid" mode embeds everything that is not expressible as vectors
// (pixel layers, effects, masks, blend modes) as Ultra-PNG images at the right place in the stack.

struct SVGExportOptions {
    enum Mode: String, CaseIterable, Identifiable { case vectorOnly = "Vector layers only", hybrid = "Hybrid (vectors + embedded raster)"; var id: String { rawValue } }
    var mode: Mode = .hybrid
    /// Decimal places for coordinates (1 is plenty at pixel scale and saves bytes).
    var precision = 2
    /// Simple point text as `<text>` (needs the font on the viewer's machine) instead of outlines.
    var liveText = false
    /// Embedded rasters: perceptual target, or nil for lossless.
    var rasterTarget: UPQualityTarget? = .high
    var effort: UPEffort = .fast
}

struct SVGExportResult {
    var svg: String
    var vectorLayers = 0
    var rasterLayers = 0
    var skippedLayers = 0
    var embeddedBytes = 0
    var notes: [String] = []
    var data: Data { Data(svg.utf8) }
}

enum SVGExport {
    /// True when the layer itself can be written as SVG without rasterising.
    static func isVector(_ l: Layer) -> Bool {
        guard l.isVisible, !l.isClipped, l.mask == nil, l.vectorMask == nil, !l.effects.hasAny, l.blendMode == .normal || (l.isGroup && l.blendMode == .passThrough) else { return false }
        switch l.content {
        case .shape(let s):
            return paintOK(s.fill) && paintOK(s.stroke.paint) && (s.stroke.paint.isNone || s.stroke.alignment == .center || s.stroke.width <= 0)
        case .text(let t):
            // per-run colours cannot be expressed by one outline path
            return !t.runs.contains { $0.style.color != nil && $0.style.color != t.color }
        case .fill(let f): return paintOK(f.paint)
        case .group(let g): return g.children.allSatisfy { !$0.isVisible || isVector($0) }
        default: return false
        }
    }

    static func paintOK(_ p: PaintStyle) -> Bool {
        switch p {
        case .none, .color: return true
        case .gradient(let g): return g.type == .linear || g.type == .radial
        case .pattern: return false
        }
    }

    static func export(_ st: DocumentState, options o: SVGExportOptions = SVGExportOptions()) -> SVGExportResult {
        var r = SVGExportResult(svg: "")
        var defs = ""
        var body = ""
        var gradientCount = 0
        let f = { (v: CGFloat) -> String in num(Double(v), o.precision) }

        func color(_ c: RGBA) -> (String, String) {
            let hex = "#" + c.hex.lowercased()
            // #rrggbb → #rgb when possible
            let h = Array(hex)
            let short = h[1] == h[2] && h[3] == h[4] && h[5] == h[6] ? "#\(h[1])\(h[3])\(h[5])" : hex
            return (short, c.a < 0.999 ? num(c.a, 3) : "")
        }

        func paintAttr(_ p: PaintStyle, _ attr: String, bounds: CGRect) -> String {
            switch p {
            case .none: return " \(attr)=\"none\""
            case .color(let c):
                let (h, a) = color(c)
                if attr == "fill" && h == "#000" && a.isEmpty { return "" }      // black is the SVG default fill
                return " \(attr)=\"\(h)\"" + (a.isEmpty ? "" : " \(attr)-opacity=\"\(a)\"")
            case .gradient(let g):
                gradientCount += 1
                let id = "g\(gradientCount)"
                let (s, e) = g.endpoints(in: bounds)
                var stops = ""
                let list = g.reverse ? g.gradient.reversed().sortedStops : g.gradient.sortedStops
                for sp in list {
                    let (h, a) = color(sp.color)
                    stops += "<stop offset=\"\(num(sp.location, 3))\" stop-color=\"\(h)\"" + (a.isEmpty ? "" : " stop-opacity=\"\(a)\"") + "/>"
                }
                if g.type == .radial {
                    let rad = hypot(e.x - s.x, e.y - s.y)
                    defs += "<radialGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" cx=\"\(f(s.x))\" cy=\"\(f(s.y))\" r=\"\(f(rad))\">\(stops)</radialGradient>"
                } else {
                    defs += "<linearGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(f(s.x))\" y1=\"\(f(s.y))\" x2=\"\(f(e.x))\" y2=\"\(f(e.y))\">\(stops)</linearGradient>"
                }
                return " \(attr)=\"url(#\(id))\""
            case .pattern: return ""
            }
        }

        func opacityAttr(_ l: Layer) -> String {
            let a = l.opacity * (l.isGroup ? 1 : l.fillOpacity)
            return a < 0.999 ? " opacity=\"\(num(a, 3))\"" : ""
        }

        func emitVector(_ l: Layer) -> String {
            switch l.content {
            case .shape(let s):
                let vp = s.path
                let (path, evenOdd) = vp.resolved
                var el = "<path d=\"\(pathData(path, precision: o.precision))\"" + paintAttr(s.fill, "fill", bounds: vp.bounds)
                if evenOdd && !s.fill.isNone { el += " fill-rule=\"evenodd\"" }
                if !s.stroke.paint.isNone && s.stroke.width > 0 {
                    el += paintAttr(s.stroke.paint, "stroke", bounds: vp.bounds)
                    if abs(s.stroke.width - 1) > 0.001 { el += " stroke-width=\"\(num(s.stroke.width, 2))\"" }
                    if s.stroke.cap != .butt { el += " stroke-linecap=\"\(s.stroke.cap.rawValue)\"" }
                    if s.stroke.join != .miter { el += " stroke-linejoin=\"\(s.stroke.join.rawValue)\"" }
                    if !s.stroke.dash.isEmpty { el += " stroke-dasharray=\"\(s.stroke.dash.map { num($0 * s.stroke.width, 2) }.joined(separator: " "))\"" }
                }
                r.vectorLayers += 1
                return el + opacityAttr(l) + "/>"
            case .text(let t):
                r.vectorLayers += 1
                let (h, a) = color(t.color)
                let fill = (h == "#000" ? "" : " fill=\"\(h)\"") + (a.isEmpty ? "" : " fill-opacity=\"\(a)\"")
                if o.liveText, t.runs.isEmpty, t.warp == nil, t.pathText == nil, t.area == nil, t.boxSize == nil, t.transform.isIdentity, t.orientation == .horizontal,
                   !t.text.contains("\n") {
                    let font = NSFont(name: t.fontName, size: CGFloat(t.fontSize)) ?? NSFont.systemFont(ofSize: CGFloat(t.fontSize))
                    let family = font.familyName ?? t.fontName
                    let weight = NSFontManager.shared.traits(of: font).contains(.boldFontMask) || t.fauxBold ? " font-weight=\"bold\"" : ""
                    let italic = NSFontManager.shared.traits(of: font).contains(.italicFontMask) || t.fauxItalic ? " font-style=\"italic\"" : ""
                    let anchor = t.alignment == .center ? " text-anchor=\"middle\"" : (t.alignment == .right ? " text-anchor=\"end\"" : "")
                    let spacing = t.tracking != 0 ? " letter-spacing=\"\(num(t.tracking / 1000 * t.fontSize, 2))\"" : ""
                    return "<text x=\"\(f(t.position.x))\" y=\"\(f(t.position.y + font.ascender))\" font-family=\"\(escape(family)), sans-serif\" font-size=\"\(num(t.fontSize, 2))\""
                        + weight + italic + anchor + spacing + fill + opacityAttr(l) + ">\(escape(t.allCaps ? t.text.uppercased() : t.text))</text>"
                }
                let path = TextRenderer.outlinePath(t)
                return "<path d=\"\(pathData(path, precision: o.precision))\"" + fill + opacityAttr(l) + "/>"
            case .fill(let fc):
                r.vectorLayers += 1
                return "<rect width=\"\(st.width)\" height=\"\(st.height)\"" + paintAttr(fc.paint, "fill", bounds: st.canvasCGRect) + opacityAttr(l) + "/>"
            case .group(let g):
                let inner = g.children.filter(\.isVisible).map(emitVector).joined()
                let op = opacityAttr(l)
                return op.isEmpty ? inner : "<g\(op)>\(inner)</g>"
            default: return ""
            }
        }

        func emitRaster(_ layers: [Layer]) {
            guard !layers.isEmpty else { return }
            if o.mode == .vectorOnly { r.skippedLayers += layers.count; return }
            var s = st
            s.layers = layers
            s.selection = nil
            guard let img = WXDoc.image(s) else { return }
            // crop to the visible pixels
            var x0 = img.width, y0 = img.height, x1 = -1, y1 = -1
            for y in 0..<img.height { for x in 0..<img.width where img.px[(y * img.width + x) * 4 + 3] != 0 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
            guard x1 >= x0, y1 >= y0 else { return }
            let cw = x1 - x0 + 1, ch = y1 - y0 + 1
            var crop = UPImage(width: cw, height: ch, px: [UInt8](repeating: 0, count: cw * ch * 4))
            for y in 0..<ch { for i in 0..<(cw * 4) { crop.px[y * cw * 4 + i] = img.px[((y0 + y) * img.width + x0) * 4 + i] } }
            var data: Data?
            if let t = o.rasterTarget {
                var lo = UPLossyOptions(); lo.target = t; lo.effort = o.effort
                data = UPLossy.encode(crop, options: lo)?.data
            } else {
                var lo = UPLosslessOptions(); lo.effort = o.effort
                data = UPLossless.encode(crop, options: lo)?.data
            }
            guard let d = data else { return }
            r.rasterLayers += layers.count
            r.embeddedBytes += d.count
            body += "<image x=\"\(x0)\" y=\"\(y0)\" width=\"\(cw)\" height=\"\(ch)\" href=\"data:image/png;base64,\(d.base64EncodedString())\"/>"
        }

        // Everything up to the topmost layer that acts on what is below it (adjustments, blend modes, clipping)
        // has to be flattened together; above that, runs of raster layers alternate with vector layers.
        let visible = st.layers.filter(\.isVisible)
        var flattenThrough = -1
        for (i, l) in visible.enumerated() {
            let actsBelow = l.isAdjustment || l.isClipped || !(l.blendMode == .normal || (l.isGroup && l.blendMode == .passThrough))
            if actsBelow { flattenThrough = i }
        }
        var run: [Layer] = flattenThrough >= 0 ? Array(visible[0...flattenThrough]) : []
        if flattenThrough >= 0 && run.contains(where: isVector) { r.notes.append("Vector layers below an adjustment / blend-mode layer were rasterised with it.") }
        for l in visible.dropFirst(flattenThrough + 1) {
            if isVector(l) {
                emitRaster(run); run = []
                body += emitVector(l)
            } else { run.append(l) }
        }
        emitRaster(run)
        if r.skippedLayers > 0 { r.notes.append("\(r.skippedLayers) non-vector layer(s) were left out (use Hybrid to embed them).") }
        if o.liveText { r.notes.append("Live text needs the fonts on the viewer's machine; outlines are exact.") }
        var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(st.width) \(st.height)\" width=\"\(st.width)\" height=\"\(st.height)\">"
        if !defs.isEmpty { svg += "<defs>\(defs)</defs>" }
        svg += body + "</svg>"
        r.svg = svg
        return r
    }

    static func num(_ v: Double, _ precision: Int) -> String {
        var s = String(format: "%.\(precision)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" { s = "0" }
        if s.hasPrefix("0.") { s.removeFirst() } else if s.hasPrefix("-0.") { s = "-" + s.dropFirst(2) }
        return s.isEmpty ? "0" : s
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Compact SVG path data (absolute commands, H / V shortcuts, implicit separators).
    static func pathData(_ path: CGPath, precision: Int) -> String {
        var d = ""
        var cur = CGPoint.zero
        var last = ""
        func n(_ v: CGFloat) -> String { num(Double(v), precision) }
        func add(_ cmd: String, _ values: [CGFloat]) {
            // a repeated command letter may be omitted; numbers need a separator unless the next one starts with '-'
            let implicit = cmd == last
            var s = implicit ? "" : cmd
            for (i, v) in values.enumerated() {
                let t = n(v)
                if (i > 0 || implicit) && !t.hasPrefix("-") { s += " " }
                s += t
            }
            d += s
            last = cmd
        }
        path.applyWithBlock { ep in
            let e = ep.pointee
            switch e.type {
            case .moveToPoint: add("M", [e.points[0].x, e.points[0].y]); cur = e.points[0]; last = "L"
            case .addLineToPoint:
                let p = e.points[0]
                if abs(p.y - cur.y) < 0.0005 { add("H", [p.x]) } else if abs(p.x - cur.x) < 0.0005 { add("V", [p.y]) } else { add("L", [p.x, p.y]) }
                cur = p
            case .addQuadCurveToPoint: add("Q", [e.points[0].x, e.points[0].y, e.points[1].x, e.points[1].y]); cur = e.points[1]
            case .addCurveToPoint: add("C", [e.points[0].x, e.points[0].y, e.points[1].x, e.points[1].y, e.points[2].x, e.points[2].y]); cur = e.points[2]
            case .closeSubpath: d += "Z"; last = "Z"
            @unknown default: break
            }
        }
        return d
    }
}

struct SVGExportDialog: View {
    let doc: Document
    @State private var mode: SVGExportOptions.Mode = .hybrid
    @State private var liveText = false
    @State private var precision = 2.0
    @State private var lossyRaster = true
    @State private var result: SVGExportResult?

    var options: SVGExportOptions {
        var o = SVGExportOptions()
        o.mode = mode; o.liveText = liveText; o.precision = Int(precision); o.rasterTarget = lossyRaster ? .high : nil
        return o
    }

    var body: some View {
        DialogFrame(title: "Export SVG", width: 460, okTitle: "Save…", onOK: save) {
            Picker("", selection: $mode) { ForEach(SVGExportOptions.Mode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            Toggle2(label: "Keep text live (<text>; needs the font on the viewer's machine)", on: $liveText)
            if mode == .hybrid { Toggle2(label: "Embedded pixels: Perceptual Ultra PNG (off = lossless)", on: $lossyRaster) }
            ValueSlider(label: "Precision", value: $precision, range: 0...4, step: 1, unit: " dp")
            if let r = result {
                let t = WXTransfer.estimate(r.data, mime: "image/svg+xml")
                Text("\(WXTransfer.bytes(r.data.count)) — \(WXTransfer.bytes(t.gzip)) gzip, \(WXTransfer.bytes(t.brotli)) Brotli on the wire").font(Theme.fontBold)
                Text("\(r.vectorLayers) vector layer(s), \(r.rasterLayers) embedded raster layer(s)" + (r.embeddedBytes > 0 ? " (\(WXTransfer.bytes(r.embeddedBytes)) of PNG)" : ""))
                    .foregroundStyle(Theme.textDim)
                ForEach(r.notes, id: \.self) { Text($0).font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: mode) { _, _ in refresh() }
        .onChange(of: liveText) { _, _ in refresh() }
        .onChange(of: precision) { _, _ in refresh() }
        .onChange(of: lossyRaster) { _, _ in refresh() }
    }

    func refresh() { result = SVGExport.export(doc.state, options: options) }

    func save() {
        let r = result ?? SVGExport.export(doc.state, options: options)
        WebExportActions.save(r.data, suggested: WXDoc.baseName(doc) + ".svg", type: .svg) { url in
            AppModel.shared.setStatus("Saved \(url.lastPathComponent) (\(WXTransfer.bytes(r.data.count)))")
        }
    }
}
