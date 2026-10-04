import AppKit
import CoreText
import PDFKit
import ImageCratCore

/// Test files for the importer's self tests: PDFs drawn with Core Graphics, and hand-written ones for features a
/// CG PDF context cannot emit (optional content, page rotation, mesh shadings, Type 3 fonts, soft masks…).
enum PDFVectorTestCorpus {
    // MARK: Core Graphics

    static func cgPDF(_ url: URL, size: CGSize, pages: Int = 1, aux: [CFString: Any] = [:], _ draw: (CGContext, Int) -> Void) {
        var box = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, aux as CFDictionary) else { return }
        for p in 0..<pages {
            ctx.beginPDFPage(nil)
            draw(ctx, p)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: sRGBSpace, components: [r, g, b, a])! }

    static func line(_ s: String, font: String, size: CGFloat, color: CGColor = rgb(0, 0, 0)) -> CTLine {
        let f = CTFontCreateWithName(font as CFString, size, nil)
        let a: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f,
                                                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: a))
    }

    static func testImage(_ w: Int, _ h: Int, alpha: Bool = false) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<8 { for x in 0..<8 {
            ctx.setFillColor(rgb(CGFloat(x) / 7, CGFloat(y) / 7, (x + y) % 2 == 0 ? 0.9 : 0.2))
            ctx.fill(CGRect(x: CGFloat(x * w) / 8, y: CGFloat(y * h) / 8, width: CGFloat(w) / 8 + 1, height: CGFloat(h) / 8 + 1))
        } }
        if alpha {
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        }
        return ctx.makeImage()!
    }

    static func shapes(_ url: URL) {
        cgPDF(url, size: CGSize(width: 400, height: 300)) { c, _ in
            c.setFillColor(rgb(0.9, 0.2, 0.15)); c.fill(CGRect(x: 20, y: 200, width: 120, height: 70))
            c.setStrokeColor(rgb(0.1, 0.3, 0.8)); c.setLineWidth(6); c.setLineCap(.round); c.setLineDash(phase: 0, lengths: [14, 10])
            c.strokeEllipse(in: CGRect(x: 170, y: 195, width: 90, height: 80))
            c.setLineDash(phase: 0, lengths: [])
            // even-odd ring
            c.setFillColor(rgb(0.1, 0.6, 0.3))
            c.addEllipse(in: CGRect(x: 290, y: 195, width: 90, height: 80)); c.addEllipse(in: CGRect(x: 312, y: 215, width: 46, height: 40))
            c.fillPath(using: .evenOdd)
            // CMYK and gray fills
            c.setFillColor(CGColor(genericCMYKCyan: 0.8, magenta: 0.1, yellow: 0.3, black: 0.1, alpha: 1)); c.fill(CGRect(x: 20, y: 120, width: 80, height: 60))
            c.setFillColor(CGColor(gray: 0.35, alpha: 1)); c.fill(CGRect(x: 110, y: 120, width: 60, height: 60))
            // fill + stroke with a miter join
            c.setFillColor(rgb(1, 0.85, 0.2)); c.setStrokeColor(rgb(0.4, 0.1, 0.5)); c.setLineWidth(5); c.setLineJoin(.miter)
            c.move(to: CGPoint(x: 190, y: 125)); c.addLine(to: CGPoint(x: 250, y: 180)); c.addLine(to: CGPoint(x: 270, y: 125)); c.closePath()
            c.drawPath(using: .fillStroke)
            // translucent overlap
            c.setFillColor(rgb(0.2, 0.4, 0.9, 0.5)); c.fill(CGRect(x: 290, y: 110, width: 60, height: 60))
            c.setFillColor(rgb(0.9, 0.3, 0.2, 0.5)); c.fill(CGRect(x: 320, y: 130, width: 60, height: 50))
            // blend mode
            c.saveGState(); c.setBlendMode(.multiply); c.setFillColor(rgb(0.3, 0.8, 0.8)); c.fill(CGRect(x: 60, y: 150, width: 90, height: 80)); c.restoreGState()
            // clip to an ellipse, then stripes
            c.saveGState()
            c.addEllipse(in: CGRect(x: 30, y: 20, width: 150, height: 80)); c.clip()
            for i in 0..<12 { c.setFillColor(i % 2 == 0 ? rgb(0.95, 0.5, 0.1) : rgb(0.2, 0.2, 0.5)); c.fill(CGRect(x: 20 + CGFloat(i) * 14, y: 10, width: 14, height: 100)) }
            c.restoreGState()
            // curves, thick round-joined open stroke
            c.setStrokeColor(rgb(0.1, 0.1, 0.1)); c.setLineWidth(8); c.setLineJoin(.round); c.setLineCap(.butt)
            c.move(to: CGPoint(x: 210, y: 30)); c.addCurve(to: CGPoint(x: 370, y: 40), control1: CGPoint(x: 250, y: 120), control2: CGPoint(x: 320, y: -40))
            c.addLine(to: CGPoint(x: 380, y: 90)); c.strokePath()
        }
    }

    static func gradients(_ url: URL) {
        cgPDF(url, size: CGSize(width: 360, height: 240)) { c, _ in
            let g = CGGradient(colorsSpace: sRGBSpace, colors: [rgb(1, 0.2, 0.2), rgb(1, 0.9, 0.1), rgb(0.1, 0.4, 0.9)] as CFArray, locations: [0, 0.45, 1])!
            c.saveGState()
            c.addPath(CGPath(roundedRect: CGRect(x: 20, y: 130, width: 200, height: 90), cornerWidth: 18, cornerHeight: 18, transform: nil)); c.clip()
            c.drawLinearGradient(g, start: CGPoint(x: 30, y: 140), end: CGPoint(x: 210, y: 210), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            c.restoreGState()
            c.saveGState()
            c.addEllipse(in: CGRect(x: 240, y: 120, width: 100, height: 100)); c.clip()
            c.drawRadialGradient(g, startCenter: CGPoint(x: 290, y: 170), startRadius: 0, endCenter: CGPoint(x: 290, y: 170), endRadius: 50, options: [.drawsAfterEndLocation])
            c.restoreGState()
            // rotated, non-uniformly scaled linear gradient
            c.saveGState()
            c.translateBy(x: 110, y: 60); c.rotate(by: 0.4); c.scaleBy(x: 1.6, y: 0.7)
            c.addRect(CGRect(x: -50, y: -40, width: 100, height: 80)); c.clip()
            c.drawLinearGradient(g, start: CGPoint(x: -50, y: 0), end: CGPoint(x: 50, y: 30), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            c.restoreGState()
            // a gradient that stops short of its clip: no layer equivalent
            c.saveGState()
            c.addRect(CGRect(x: 230, y: 20, width: 110, height: 80)); c.clip()
            c.drawLinearGradient(g, start: CGPoint(x: 260, y: 20), end: CGPoint(x: 310, y: 20), options: [])
            c.restoreGState()
        }
    }

    static func images(_ url: URL) {
        cgPDF(url, size: CGSize(width: 320, height: 240)) { c, _ in
            let img = testImage(64, 48)
            c.draw(img, in: CGRect(x: 20, y: 150, width: 128, height: 72))
            c.saveGState()
            c.translateBy(x: 230, y: 170); c.rotate(by: 0.5)
            c.setAlpha(0.7)
            c.draw(img, in: CGRect(x: -50, y: -30, width: 100, height: 60))
            c.restoreGState()
            c.setFillColor(rgb(0.2, 0.7, 0.4)); c.fill(CGRect(x: 30, y: 20, width: 200, height: 90))
            c.draw(testImage(80, 80, alpha: true), in: CGRect(x: 60, y: 25, width: 80, height: 80))
        }
    }

    static let textSamples: [(String, String, CGFloat)] = [
        ("Hello Lumen Layers", "Helvetica", 28), ("Times Roman body text 123", "Times-Roman", 18), ("Courier monospace", "Courier", 16),
        ("Menlo code = true", "Menlo-Regular", 14), ("Bold Helvetica Neue", "HelveticaNeue-Bold", 20),
    ]

    static func text(_ url: URL) {
        cgPDF(url, size: CGSize(width: 420, height: 320)) { c, _ in
            var y: CGFloat = 280
            for (s, f, size) in textSamples {
                c.textPosition = CGPoint(x: 24, y: y)
                CTLineDraw(line(s, font: f, size: size, color: rgb(0.1, 0.1, 0.3)), c)
                y -= size * 1.6
            }
            // rotated, coloured
            c.saveGState()
            c.translateBy(x: 300, y: 60); c.rotate(by: 0.6)
            c.textPosition = .zero
            CTLineDraw(line("Rotated", font: "Helvetica-Bold", size: 26, color: rgb(0.8, 0.2, 0.1)), c)
            c.restoreGState()
            // a paragraph laid out by Core Text (several lines, kerning as Core Text applies it)
            let para = NSAttributedString(string: "A paragraph of plain text that wraps onto several lines so the importer has to find the lines again.",
                                          attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Georgia" as CFString, 13, nil)])
            let fs = CTFramesetterCreateWithAttributedString(para)
            let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 24, y: 20, width: 200, height: 80), transform: nil), nil)
            CTFrameDraw(frame, c)
        }
    }

    static func transparency(_ url: URL) {
        cgPDF(url, size: CGSize(width: 300, height: 200)) { c, _ in
            c.setFillColor(rgb(0.95, 0.9, 0.7)); c.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            c.setFillColor(rgb(0.1, 0.2, 0.6)); c.fill(CGRect(x: 20, y: 60, width: 260, height: 40))
            c.saveGState()
            c.setAlpha(0.5)
            c.beginTransparencyLayer(auxiliaryInfo: nil)
            c.setFillColor(rgb(0.9, 0.1, 0.1)); c.fillEllipse(in: CGRect(x: 40, y: 30, width: 120, height: 120))
            c.setFillColor(rgb(0.1, 0.7, 0.2)); c.fillEllipse(in: CGRect(x: 110, y: 50, width: 120, height: 120))
            c.endTransparencyLayer()
            c.restoreGState()
            c.saveGState()
            c.setBlendMode(.screen)
            c.setFillColor(rgb(0.2, 0.5, 0.9)); c.fill(CGRect(x: 200, y: 20, width: 80, height: 160))
            c.restoreGState()
        }
    }

    static func pattern(_ url: URL) {
        cgPDF(url, size: CGSize(width: 240, height: 160)) { c, _ in
            var callbacks = CGPatternCallbacks(version: 0, drawPattern: { _, ctx in
                ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0.9, 0.3, 0.2, 1])!)
                ctx.fillEllipse(in: CGRect(x: 2, y: 2, width: 8, height: 8))
            }, releaseInfo: nil)
            let p = CGPattern(info: nil, bounds: CGRect(x: 0, y: 0, width: 12, height: 12), matrix: .identity, xStep: 12, yStep: 12, tiling: .constantSpacing, isColored: true, callbacks: &callbacks)!
            c.setFillColor(rgb(0.2, 0.3, 0.7)); c.fill(CGRect(x: 10, y: 10, width: 100, height: 140))
            c.setFillColorSpace(CGColorSpace(patternBaseSpace: nil)!)
            var alpha: CGFloat = 1
            c.setFillPattern(p, colorComponents: &alpha)
            c.fill(CGRect(x: 60, y: 30, width: 150, height: 100))
        }
    }

    /// Many small paths in a few colours: `runs` same-coloured paths in a row, then the colour changes.
    static func complex(_ url: URL, count: Int, colors: Int, runs: Int) {
        cgPDF(url, size: CGSize(width: 500, height: 400)) { c, _ in
            var seed: UInt64 = 12345
            func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 33) % 10000) / 10000 }
            for i in 0..<count {
                let k = (i / runs) % colors
                c.setFillColor(rgb(CGFloat(k % 5) / 5, CGFloat((k * 3) % 7) / 7, CGFloat((k * 5) % 11) / 11))
                let x = rnd() * 470, y = rnd() * 370, w = 6 + rnd() * 24
                if i % 3 == 0 { c.fillEllipse(in: CGRect(x: x, y: y, width: w, height: w * 0.8)) }
                else {
                    c.move(to: CGPoint(x: x, y: y)); c.addLine(to: CGPoint(x: x + w, y: y + 4)); c.addLine(to: CGPoint(x: x + w / 2, y: y + w)); c.closePath(); c.fillPath()
                }
            }
        }
    }

    static func multiPage(_ url: URL) {
        cgPDF(url, size: CGSize(width: 200, height: 150), pages: 3) { c, p in
            c.setFillColor([rgb(0.9, 0.2, 0.2), rgb(0.2, 0.7, 0.3), rgb(0.2, 0.3, 0.9)][p]); c.fill(CGRect(x: 20 + p * 30, y: 30, width: 80, height: 70))
            c.textPosition = CGPoint(x: 20, y: 120)
            CTLineDraw(line("Page \(p + 1)", font: "Helvetica", size: 18), c)
        }
    }

    static func encrypted(_ url: URL, password: String) {
        cgPDF(url, size: CGSize(width: 200, height: 120), aux: [kCGPDFContextUserPassword: password, kCGPDFContextOwnerPassword: password + "-owner"]) { c, _ in
            c.setFillColor(rgb(0.3, 0.5, 0.9)); c.fill(CGRect(x: 20, y: 20, width: 160, height: 80))
        }
    }

    // MARK: Hand-written PDFs

    struct Raw {
        private var objects: [Data] = []
        @discardableResult
        mutating func add(_ s: String) -> Int { objects.append(Data(s.utf8)); return objects.count }
        @discardableResult
        mutating func stream(_ dict: String, _ content: Data) -> Int {
            var d = Data("<< \(dict) /Length \(content.count) >>\nstream\n".utf8)
            d.append(content)
            d.append(Data("\nendstream".utf8))
            objects.append(d)
            return objects.count
        }
        @discardableResult
        mutating func stream(_ dict: String, _ content: String) -> Int { stream(dict, Data(content.utf8)) }
        /// Reserves an object number (for forward references).
        mutating func reserve() -> Int { objects.append(Data()); return objects.count }
        mutating func set(_ n: Int, _ s: String) { objects[n - 1] = Data(s.utf8) }

        func data(root: Int) -> Data {
            var out = Data("%PDF-1.7\n".utf8)
            var offs: [Int] = []
            for (i, o) in objects.enumerated() {
                offs.append(out.count)
                out.append(Data("\(i + 1) 0 obj\n".utf8)); out.append(o); out.append(Data("\nendobj\n".utf8))
            }
            let x = out.count
            var t = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
            for o in offs { t += String(format: "%010d 00000 n \n", o) }
            t += "trailer\n<< /Size \(objects.count + 1) /Root \(root) 0 R >>\nstartxref\n\(x)\n%%EOF\n"
            out.append(Data(t.utf8))
            return out
        }
    }

    /// One page with `content`. `pageExtra` goes into the page dictionary, `resources` is the resource dictionary
    /// body, `catalogExtra` into the catalog; `more` may add objects first (their numbers start at 5).
    static func raw(_ url: URL, mediaBox: String = "0 0 300 200", pageExtra: String = "", resources: String = "", catalogExtra: String = "",
                    content: String, more: (inout Raw) -> Void = { _ in }) {
        var r = Raw()
        let cat = r.reserve(), pages = r.reserve(), page = r.reserve()
        let c = r.stream("", content)
        more(&r)
        r.set(cat, "<< /Type /Catalog /Pages \(pages) 0 R \(catalogExtra) >>")
        r.set(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
        r.set(page, "<< /Type /Page /Parent \(pages) 0 R /MediaBox [\(mediaBox)] /Contents \(c) 0 R /Resources << \(resources) >> \(pageExtra) >>")
        try? r.data(root: cat).write(to: url)
    }

    static let artwork = """
    0.9 0.9 0.85 rg 0 0 300 200 re f
    0.8 0.1 0.1 rg 20 120 100 60 re f
    0 0.4 0.8 RG 5 w 150 110 m 280 110 l 215 185 l h S
    0.1 0.6 0.2 rg 40 20 m 140 20 l 90 90 l h f

    """

    /// Two optional-content layers, the second one switched off by default.
    static func optionalContent(_ url: URL) {
        raw(url, resources: "/Properties << /MC0 5 0 R /MC1 6 0 R >>",
            catalogExtra: "/OCProperties << /OCGs [5 0 R 6 0 R] /D << /Order [5 0 R 6 0 R] /ON [5 0 R] /OFF [6 0 R] >> >>",
            content: "/OC /MC0 BDC\n0.2 0.4 0.9 rg 20 20 120 160 re f\n1 0.8 0 rg 60 60 m 120 60 l 90 140 l h f\nEMC\n/OC /MC1 BDC\n0.9 0.1 0.1 rg 160 40 120 120 re f\nEMC\n") { r in
            r.add("<< /Type /OCG /Name (Artwork) >>")
            r.add("<< /Type /OCG /Name (Hidden Notes) >>")
        }
    }

    static func rotated(_ url: URL, rotate: Int) {
        raw(url, mediaBox: "0 0 320 220", pageExtra: "/Rotate \(rotate) /CropBox [10 20 310 200]", content: artwork + "0 0 0 rg 12 22 8 8 re f\n")
    }

    static func userUnit(_ url: URL) {
        raw(url, pageExtra: "/UserUnit 2", content: artwork)
    }

    /// A free-form triangle mesh painted with `sh`.
    static func mesh(_ url: URL) {
        let verts: [[UInt8]] = [[0, 20, 20, 255, 0, 0], [0, 230, 40, 0, 255, 0], [0, 120, 230, 0, 0, 255]]
        raw(url, resources: "/Shading << /Sh0 5 0 R >>", content: "0.2 0.2 0.2 rg 10 10 280 180 re f\nq 1.1 0 0 0.7 10 10 cm /Sh0 sh Q\n") { r in
            r.stream("/ShadingType 4 /ColorSpace /DeviceRGB /BitsPerCoordinate 8 /BitsPerComponent 8 /BitsPerFlag 8 /Decode [0 255 0 255 0 1 0 1 0 1]", Data(verts.flatMap { $0 }))
        }
    }

    /// Text in a Type 3 font (glyphs are little content streams).
    static func type3(_ url: URL) {
        raw(url, resources: "/Font << /F1 7 0 R >>", content: "0.95 0.95 0.95 rg 0 0 300 200 re f\nBT /F1 40 Tf 0.1 0.2 0.6 rg 30 90 Td (ABAB) Tj ET\n") { r in
            let a = r.stream("", "700 0 0 0 600 700 d1 0 0 600 700 re f")
            let b = r.stream("", "700 0 0 0 600 700 d1 300 350 m 600 0 l 0 0 l h f")
            r.add("<< /Type /Font /Subtype /Type3 /FontBBox [0 0 700 700] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /A \(a) 0 R /B \(b) 0 R >> /Encoding << /Type /Encoding /Differences [65 /A /B] >> /FirstChar 65 /LastChar 66 /Widths [700 700] /Resources << >> >>")
        }
    }

    /// Artwork drawn through a luminosity soft mask (a gradient in a transparency group).
    static func softMask(_ url: URL) {
        raw(url, resources: "/ExtGState << /GS0 5 0 R >> /XObject << /Fm0 8 0 R >>", content: "0.2 0.3 0.8 rg 0 0 300 200 re f\n/GS0 gs\n0.95 0.8 0.1 rg 30 30 240 140 re f\n") { r in
            r.add("<< /Type /ExtGState /SMask << /Type /Mask /S /Luminosity /G 6 0 R >> >>")
            r.stream("/Type /XObject /Subtype /Form /BBox [0 0 300 200] /Group << /S /Transparency /CS /DeviceGray >> /Resources << /Shading << /Sh0 7 0 R >> >>", "/Sh0 sh")
            r.add("<< /ShadingType 2 /ColorSpace /DeviceGray /Coords [30 0 270 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1 >> /Extend [true true] >>")
            r.stream("/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "0 g 0 0 10 10 re f")
        }
    }

    /// A knockout group with overlapping translucent shapes, and a plain group next to it.
    static func groups(_ url: URL) {
        raw(url, resources: "/ExtGState << /A5 5 0 R /A7 9 0 R >> /XObject << /K 6 0 R /G 7 0 R /Self 8 0 R >>",
            content: "0.9 0.9 0.9 rg 0 0 300 200 re f\n0.1 0.1 0.1 rg 0 90 300 20 re f\n/K Do\n/A7 gs /G Do\n/Self Do\n") { r in
            r.add("<< /Type /ExtGState /ca 0.5 /CA 0.5 >>")
            r.stream("/Type /XObject /Subtype /Form /BBox [0 0 150 200] /Group << /S /Transparency /K true >> /Resources << /ExtGState << /A5 5 0 R >> >>",
                     "/A5 gs 1 0 0 rg 20 40 80 100 re f 0 0 1 rg 60 70 80 100 re f")
            r.stream("/Type /XObject /Subtype /Form /BBox [150 0 300 200] /Group << /S /Transparency /I true >>",
                     "0 0.6 0.2 rg 170 40 70 100 re f 1 0.8 0 rg 210 70 70 100 re f")
            // a form that draws itself: must not recurse forever
            r.stream("/Type /XObject /Subtype /Form /BBox [0 0 300 200] /Resources << /XObject << /Self 8 0 R >> >>", "0.5 0 0.5 rg 130 5 40 20 re f /Self Do")
            r.add("<< /Type /ExtGState /ca 0.7 >>")
        }
    }

    /// A transparency group that blends in DeviceCMYK: a dark CMYK fill under a half-transparent white veil mixes
    /// differently there than in RGB.
    static func cmykGroup(_ url: URL) {
        raw(url, resources: "/XObject << /Fm0 5 0 R >>", content: "0.9 0.9 0.9 rg 0 0 300 200 re f\n/Fm0 Do\n") { r in
            r.stream("/Type /XObject /Subtype /Form /BBox [0 0 300 200] /Group << /S /Transparency /CS /DeviceCMYK /I true >> /Resources << /ExtGState << /A5 6 0 R >> >>",
                     "0.7 0.6 0.55 0.8 k 30 30 240 140 re f /A5 gs 0 0 0 0 k 60 50 200 120 re f")
            r.add("<< /Type /ExtGState /ca 0.5 >>")
        }
    }

    /// A page with a square annotation that has an appearance stream.
    static func annotation(_ url: URL) {
        raw(url, pageExtra: "/Annots [5 0 R]", content: artwork) { r in
            r.add("<< /Type /Annot /Subtype /Square /Rect [200 20 280 80] /F 4 /AP << /N 6 0 R >> >>")
            r.stream("/Type /XObject /Subtype /Form /BBox [0 0 80 60]", "0.6 0.1 0.7 rg 0 0 80 60 re f 1 1 1 rg 10 10 60 40 re f")
        }
    }

    static func zeroBox(_ url: URL) { raw(url, mediaBox: "0 0 0 0", content: artwork) }
    static func hugeBox(_ url: URL) { raw(url, mediaBox: "0 0 40000 30000", content: "0.2 0.5 0.8 rg 1000 1000 20000 15000 re f\n") }

    /// A PostScript-based Illustrator file header (what Illustrator 8 and earlier wrote).
    static func legacyIllustrator(_ url: URL) {
        let s = "%!PS-Adobe-3.0 \n%%Creator: Adobe Illustrator(R) 8.0\n%%AI8_CreatorVersion: 8\n%%BoundingBox: 0 0 100 100\n%%EndComments\n%%BeginProlog\n%%EndProlog\n0 0 m 100 100 l S\n%%EOF\n"
        try? Data(s.utf8).write(to: url)
    }

    static func eps(_ url: URL) {
        let s = "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 100 100\n%%EndComments\nnewpath 0 0 moveto 100 100 lineto stroke\n%%EOF\n"
        try? Data(s.utf8).write(to: url)
    }

    /// What Illustrator writes as the only page of a file saved without "Create PDF Compatible File".
    static func placeholder(_ url: URL) {
        cgPDF(url, size: CGSize(width: 612, height: 792)) { c, _ in
            let lines = ["This is an Adobe\u{00AE} Illustrator\u{00AE} File that was", "saved without PDF Content.", "To Place or open this file in other",
                         "applications, it should be re-saved from", "Adobe Illustrator with the \"Create PDF", "Compatible File\" option turned on. This",
                         "option is in the Illustrator Native Format", "Options dialog box, which appears when", "saving an Adobe Illustrator file using the", "Save As command."]
            var y: CGFloat = 700
            for l in lines { c.textPosition = CGPoint(x: 60, y: y); CTLineDraw(line(l, font: "Helvetica", size: 20), c); y -= 28 }
        }
    }
}
