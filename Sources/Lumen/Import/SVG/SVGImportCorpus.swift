import AppKit
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

/// Test corpus for the SVG importer: one small SVG per feature, plus the nasty cases. Every case is imported, composited
/// and compared with WebKit's rendering of the same markup; most also assert the layer structure they must produce.
enum SVGImportCorpus {
    struct Case {
        var name: String
        var svg: String
        /// Expected structure (`SVGImportQA.outline`), nil = not asserted.
        var outline: String? = nil
        var maxMean = 0.6
        var maxBad = 0.004
        var rasterized = 0
        /// False where WebKit itself is known to draw the feature wrongly (the case is still imported and rendered).
        var oracle = true
        /// Compare at half size (text: the two renderers antialias glyph edges differently).
        var soft = false
        /// Extra assertions on the imported document; returns failure descriptions.
        var verify: ((DocumentState, SVGImportReport) -> [String])? = nil
    }

    static func svg(_ w: Int, _ h: Int, _ body: String, attrs: String = "") -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"\(w)\" height=\"\(h)\" viewBox=\"0 0 \(w) \(h)\"\(attrs.isEmpty ? "" : " " + attrs)>\(body)</svg>"
    }

    /// A small test picture (quadrants and a diagonal) as a PNG data URI.
    static func png(_ w: Int, _ h: Int) -> String {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cols = ["E94F37", "2E86AB", "F6AE2D", "33673B"].map { RGBA(hex: $0)!.cgColor }
        for (i, c) in cols.enumerated() {
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: CGFloat(i % 2) * CGFloat(w) / 2, y: CGFloat(i / 2) * CGFloat(h) / 2, width: CGFloat(w) / 2, height: CGFloat(h) / 2))
        }
        ctx.setStrokeColor(RGBA.white.cgColor); ctx.setLineWidth(CGFloat(max(2, w / 12)))
        ctx.move(to: .zero); ctx.addLine(to: CGPoint(x: w, y: h)); ctx.strokePath()
        return "data:image/png;base64," + pngData(ctx.makeImage()!).base64EncodedString()
    }

    static func pngData(_ img: CGImage) -> Data {
        let d = NSMutableData()
        let dest = CGImageDestinationCreateWithData(d, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return d as Data
    }

    private static func layers(_ st: DocumentState) -> [Layer] { st.allLayers }
    private static func names(_ st: DocumentState) -> [String] { st.allLayers.map(\.name) }
    private static func expect(_ ok: Bool, _ msg: String) -> [String] { ok ? [] : [msg] }

    /// Composite colour (over white) at a pixel, as 0…255 components.
    static func pixel(_ st: DocumentState, _ x: Int, _ y: Int) -> [Int] {
        guard let cg = Compositor.shared.flatten(st, background: .white) else { return [] }
        let b = PixelBuffer(cgImage: cg)
        let (r, g, bl, _) = b.pixel(clamp(x, 0, b.width - 1), clamp(y, 0, b.height - 1))
        return [Int(r), Int(g), Int(bl)]
    }
    private static func near(_ a: [Int], _ b: [Int], _ tol: Int = 3) -> Bool { a.count == 3 && zip(a, b).allSatisfy { abs($0 - $1) <= tol } }

    // MARK: Cases

    static func cases() -> [Case] {
        var c: [Case] = []
        c += geometry()
        c += paint()
        c += structure()
        c += text()
        c += imagesClipMask()
        c += effectsAndRaster()
        return c
    }

    static func geometry() -> [Case] {
        [
            Case(name: "rect-basic", svg: svg(200, 120, "<rect x='20' y='20' width='100' height='60' fill='#e94f37'/><rect x='90' y='50' width='90' height='50' rx='12' fill='#2e86ab' stroke='#1b1f3a' stroke-width='4'/>"), outline: "shape, shape",
                 verify: { st, _ in
                     guard case .rectangle(let r, let rad)? = st.layers[1].shape?.geometry else { return ["rounded rect is not a live rectangle"] }
                     return expect(r == CGRect(x: 90, y: 50, width: 90, height: 50) && rad == 12, "live rectangle parameters \(r) r=\(rad)")
                 }),
            Case(name: "rect-radii", svg: svg(260, 120, "<rect x='10' y='10' width='70' height='40' rx='10' ry='20' fill='#3a7'/><rect x='95' y='10' width='70' height='40' ry='8' fill='#a37'/><rect x='180' y='10' width='70' height='40' rx='500' fill='#37a'/><rect x='10' y='65' width='70' height='40' rx='-5' fill='#777'/><rect x='95' y='65' width='0' height='40' fill='red'/><rect x='180' y='65' width='70' height='40' rx='15%' fill='#c93'/>"), outline: "shape, shape, shape, shape, shape"),
            Case(name: "circle-ellipse", svg: svg(200, 120, "<circle cx='60' cy='60' r='40' fill='gold' stroke='black' stroke-width='3'/><ellipse cx='140' cy='60' rx='50' ry='25' fill='rgb(40,160,90)' fill-opacity='.6'/><circle cx='20' cy='20' r='0' fill='red'/><ellipse cx='180' cy='20' rx='10' fill='navy'/>"), outline: "shape, shape, shape",
                 verify: { st, _ in
                     guard case .ellipse(let r)? = st.layers[0].shape?.geometry else { return ["circle is not a live ellipse"] }
                     return expect(r == CGRect(x: 20, y: 20, width: 80, height: 80), "live ellipse rect \(r)")
                 }),
            Case(name: "line-poly", svg: svg(200, 120, "<line x1='10' y1='10' x2='190' y2='30' stroke='#333' stroke-width='6' stroke-linecap='round'/><polyline points='10,100 50,50 90,100 130,50 170,100' fill='none' stroke='tomato' stroke-width='5' stroke-linejoin='round'/><polygon points='150,20 190,50 160,60 999' fill='hsl(210, 80%, 50%)'/><polyline points='20 60 60 60 40 90' fill='#9c6' stroke='black'/>"), outline: "shape, shape, shape, shape"),
            Case(name: "path-commands", svg: svg(240, 160, "<path d='M20 20h60v40h-60z M100 20 l40 0 0 40 -40 0z' fill='#444'/><path d='M20 90 C40 60 80 60 100 90 S160 120 180 90' fill='none' stroke='purple' stroke-width='4'/><path d='M20 130 Q60 100 100 130 T180 130' fill='none' stroke='teal' stroke-width='4'/><path d='M150 30 v30 h30 V30 H150 Z' fill='orange'/>"), outline: "shape, shape, shape, shape"),
            Case(name: "path-compact-numbers", svg: svg(240, 120, "<path d='M10,10.5.5,30-5.5,20zm40 0 20 0 0 20-20 0zM1e2 1E1l2e1 0 0 2.0e+1-.2e2 0z' fill='#246'/><path d='m130 20 20 0 0 20 -20 0 z m30 0 20 0 0 20 -20 0 z l-10 40 60 0' fill='#c33' stroke='black'/><path d='M20 70L60 70 60 110 20 110ZL100 110 100 70' fill='none' stroke='green' stroke-width='3'/>")),
            Case(name: "path-arcs", svg: svg(240, 160, "<path d='M40 80 A30 30 0 0 1 100 80 A30 30 0 0 0 160 80' fill='none' stroke='#c0392b' stroke-width='5'/><path d='M60 130 a40 20 30 1 0 60 -20' fill='#27ae60' stroke='black'/><path d='M170 100a25 25 0 1128 28' fill='none' stroke='navy' stroke-width='6' stroke-linecap='round'/><path d='M180 20 A5 5 0 0 1 230 60 L200 60Z' fill='plum'/>")),
            Case(name: "path-arcs-odd", svg: svg(240, 160, "<path d='M20 40 A0 20 0 0 1 60 40' fill='none' stroke='red' stroke-width='3'/><path d='M80 40 A20 20 0 0 1 80 40 L110 60' fill='none' stroke='blue' stroke-width='3'/><path d='M130 60a30 15-45 01 40-20 30 15-45 10-40 20z' fill='#fc6' stroke='#630'/><path d='M20 120 a25 25 0 1 0 50 0 a25 25 0 1 0 -50 0' fill='#6cf'/><path d='M100 120 A 1 2 90 1 1 160 120' fill='none' stroke='black' stroke-width='2'/><path d='M180 110 a20,10 720 0,0 40,20' fill='none' stroke='purple' stroke-width='4'/>")),
            Case(name: "path-errors", svg: svg(200, 100, "<path d='M10 10 L90 10 L90 50 X 10 50 Z' fill='none' stroke='black' stroke-width='4'/><path d='M110 10 L190 10 L190 50 L' fill='#9f9' stroke='black'/><path d='L10 90 H50' stroke='red' stroke-width='5'/><path d='' fill='red'/><path d='M120 70 h60 M' stroke='blue' stroke-width='5'/>"), outline: "shape, shape, shape"),
            Case(name: "units", svg: "<svg xmlns='http://www.w3.org/2000/svg' width='3in' height='40mm' viewBox='0 0 288 151.18'><rect x='10%' y='1em' width='50%' height='25%' fill='#5a9'/><rect x='10pt' y='20mm' width='3cm' height='2pc' fill='#a59'/><circle cx='80%' cy='50%' r='10%' fill='#59a'/><line x1='0' y1='100%' x2='100%' y2='0' stroke='#333' stroke-width='.5ex'/></svg>",
                 verify: { st, _ in expect(st.width == 288 && st.height == 151 && abs(st.resolution - 96) < 0.5, "document \(st.width)×\(st.height) @ \(st.resolution)") }),
            Case(name: "viewbox-offset", svg: "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100' viewBox='-50 -25 100 50'><rect x='-50' y='-25' width='100' height='50' fill='#def'/><circle r='20' fill='#c33'/><rect x='30' y='10' width='15' height='10' fill='#333'/></svg>", outline: "shape, shape, shape"),
            Case(name: "viewbox-aspect", svg: "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100' viewBox='0 0 50 50' preserveAspectRatio='xMaxYMid meet'><rect width='50' height='50' fill='#fd8'/><circle cx='25' cy='25' r='20' fill='#36c'/></svg>"),
            Case(name: "viewbox-slice", svg: "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100' viewBox='0 0 50 50' preserveAspectRatio='xMidYMin slice'><rect width='50' height='50' fill='#fd8'/><circle cx='25' cy='25' r='20' fill='#36c'/><rect y='40' width='50' height='10' fill='red'/></svg>"),
            Case(name: "viewbox-none", svg: "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100' viewBox='0 0 50 50' preserveAspectRatio='none'><rect width='50' height='50' fill='#fd8'/><circle cx='25' cy='25' r='20' fill='#36c' stroke='black' stroke-width='3'/></svg>",
                 outline: "shape, group[shape, shape]", verify: { _, r in expect(r.items.contains { $0.message.contains("outline") }, "non-uniform stroke is reported") }),
            Case(name: "nested-svg", svg: svg(240, 120, "<rect width='240' height='120' fill='#eee'/><svg x='20' y='10' width='100' height='100' viewBox='0 0 10 10'><rect width='10' height='10' fill='#9cf'/><circle cx='10' cy='5' r='4' fill='#c33'/></svg><svg x='140' y='30' width='80' height='40' viewBox='0 0 10 10' preserveAspectRatio='xMinYMin slice' overflow='visible'><circle cx='5' cy='5' r='5' fill='#3a3' fill-opacity='.7'/></svg>")),
            Case(name: "transforms-nested", svg: svg(240, 160, "<g transform='translate(120 80)'><g transform='rotate(30)'><rect x='-50' y='-20' width='100' height='40' fill='#3498db'/><g transform='scale(.5) skewX(20)'><rect x='-50' y='-20' width='100' height='40' fill='#e67e22'/></g></g><circle r='6' fill='black' transform='matrix(1 0 0 1 60 -50)'/></g>"),
                 outline: "shape, shape, shape",
                 verify: { st, _ in
                     let shapes = st.allLayers.compactMap(\.shape)
                     guard shapes.count == 3, case .rectangle(let r, _) = shapes[0].geometry, case .rectangle = shapes[1].geometry, case .ellipse(let e) = shapes[2].geometry else { return ["rotated and skewed rectangles stay live rectangles"] }
                     return expect(r == CGRect(x: -50, y: -20, width: 100, height: 40) && !shapes[0].transform.isIdentity, "a rotated rectangle keeps its parameters and carries the rotation as its transform")
                         + expect(e == CGRect(x: 174, y: 24, width: 12, height: 12) && shapes[2].transform.isIdentity, "a translated circle is a plain live ellipse (\(e))")
                 }),
            Case(name: "transforms-all", svg: svg(300, 160, "<rect width='40' height='20' fill='#c33' transform='translate(10,10)'/><rect width='40' height='20' fill='#3c3' transform='translate(70)'/><rect width='40' height='20' fill='#33c' transform='translate(130 10) scale(1.5 2)'/><rect width='40' height='20' fill='#cc3' transform='rotate(45 230 30) translate(210 20)'/><rect width='40' height='20' fill='#3cc' transform='translate(20 90) skewX(30)'/><rect width='40' height='20' fill='#c3c' transform='translate(90 90) skewY(-20)'/><rect width='40' height='20' fill='#666' transform='matrix(.8 .3 -.4 1.1 170 90)'/><rect width='40' height='20' fill='#f80' transform='translate(280 120) scale(-1 1)'/><rect width='40' height='20' fill='#08f' transform='translate(240,100),rotate(-10),scale(.5)'/>")),
            Case(name: "transforms-css", svg: svg(240, 120, "<rect width='40' height='20' fill='#c33' style='transform: translate(20px, 10px) rotate(15deg)'/><rect x='100' y='40' width='40' height='20' fill='#36c' style='transform: rotate(45deg); transform-origin: 120px 50px'/><rect x='170' y='40' width='40' height='20' fill='#3a3' style='transform: scale(1.5); transform-box: fill-box; transform-origin: center'/>"),
                 verify: { st, _ in expect(st.layers.count == 3, "three rectangles") }),
            Case(name: "transform-invalid", svg: svg(200, 100, "<rect x='10' y='10' width='40' height='30' fill='#393' transform='bogus(3)'/><rect x='70' y='10' width='40' height='30' fill='#939' transform='scale(0)'/><rect x='130' y='10' width='40' height='30' fill='#339' transform='rotate(1e400)'/><rect x='10' y='60' width='40' height='30' fill='#993' transform='matrix(1 0 0 1)'/>")),
            Case(name: "coordinates-huge", svg: svg(200, 100, "<rect x='-1e9' y='-1e9' width='2e9' height='2e9' fill='#def'/><path d='M-1e30 50 L1e30 50' stroke='#c33' stroke-width='6'/><circle cx='1e15' cy='50' r='1e15' fill='none' stroke='#36c' stroke-width='4'/><rect x='80' y='30' width='1e-9' height='40' fill='red'/><g transform='scale(1e6)'><rect x='.00005' y='.00002' width='.00004' height='.00005' fill='#3a3'/></g><path d='M20 20 L NaN 40 L 60 60' stroke='black'/><path d='M120 20 l 30 Infinity' stroke='black'/><path d='M150 80 L190 80 L1e400 0' stroke='#909' stroke-width='4'/>"), oracle: false,
                 // (WebKit paints neither the enormous rectangle nor the rectangle under scale(1e6))
                 verify: { st, _ in
                     expect(near(pixel(st, 10, 10), [221, 238, 255]), "enormous background rectangle is painted \(pixel(st, 10, 10))")
                         + expect(near(pixel(st, 100, 50), [204, 51, 51]), "line with enormous end points crosses the canvas \(pixel(st, 100, 50))")
                         + expect(near(pixel(st, 70, 60), [51, 170, 51]), "rectangle under scale(1e6) \(pixel(st, 70, 60))")
                         + expect(near(pixel(st, 170, 80), [153, 0, 153]), "path keeps the segments before a number that overflows \(pixel(st, 170, 80))")
                 }),
            Case(name: "empty-and-degenerate", svg: svg(160, 80, "<g/><g><g><g></g></g></g><rect width='0' height='0'/><path d='M10 10'/><polygon points=''/><circle r='-5'/><g transform='scale(2)'><rect x='10' y='5' width='30' height='20' fill='#c63'/></g><path d='M120 40 z' stroke='black' stroke-width='12' stroke-linecap='round'/><path d='M140 40 h0' stroke='#36c' stroke-width='12' stroke-linecap='square'/>"), maxMean: 1.5, maxBad: 0.02),
        ]
    }

    static func paint() -> [Case] {
        [
            Case(name: "colors", svg: svg(320, 80, "<rect x='0' width='20' height='40' fill='red'/><rect x='20' width='20' height='40' fill='#0f0'/><rect x='40' width='20' height='40' fill='#00f8'/><rect x='60' width='20' height='40' fill='#336699'/><rect x='80' width='20' height='40' fill='#336699cc'/><rect x='100' width='20' height='40' fill='rgb(255, 128, 0)'/><rect x='120' width='20' height='40' fill='rgb(50%,0%,100%)'/><rect x='140' width='20' height='40' fill='rgba(0,0,0,.5)'/><rect x='160' width='20' height='40' fill='hsl(120, 100%, 25%)'/><rect x='180' width='20' height='40' fill='hsla(300,60%,50%,0.5)'/><rect x='200' width='20' height='40' fill='rgb(0 128 255 / 50%)'/><rect x='220' width='20' height='40' fill='CornflowerBlue'/><rect x='240' width='20' height='40' fill='transparent' stroke='black'/><rect x='260' width='20' height='40' fill='notacolor'/><rect x='280' width='20' height='40' fill='url(#missing) orange'/><rect x='300' width='20' height='40' fill='url(#missing)'/><g color='crimson'><rect y='40' width='160' height='40' fill='currentColor'/><rect x='160' y='40' width='160' height='40' fill='none' stroke='currentColor' stroke-width='8' color='teal'/></g>")),
            Case(name: "linear-gradient", svg: svg(240, 120, "<defs><linearGradient id='a'><stop offset='0' stop-color='#f00'/><stop offset='1' stop-color='#00f'/></linearGradient><linearGradient id='b' x1='0' y1='0' x2='0' y2='1'><stop offset='0%' stop-color='#fc0'/><stop offset='50%' stop-color='#f06'/><stop offset='100%' stop-color='#306' stop-opacity='.4'/></linearGradient></defs><rect x='10' y='10' width='100' height='100' fill='url(#a)'/><rect x='130' y='10' width='100' height='100' rx='20' fill='url(#b)'/>"), outline: "shape, shape", maxMean: 0.8,
                 verify: { st, _ in
                     guard case .gradient(let g)? = st.layers[0].shape?.fill else { return ["no gradient fill"] }
                     return expect(g.shape == nil && g.type == .linear && abs(g.angle) < 1e-6 && abs(g.scale - 1) < 1e-6, "plain horizontal gradient stays a native gradient (angle \(g.angle), scale \(g.scale), shaped \(g.shape != nil))")
                 }),
            Case(name: "gradient-userspace-transform", svg: svg(240, 120, "<defs><linearGradient id='a' gradientUnits='userSpaceOnUse' x1='20' y1='20' x2='80' y2='60' gradientTransform='rotate(20 50 50)'><stop offset='.1' stop-color='#0a6'/><stop offset='.9' stop-color='#fd0'/></linearGradient><linearGradient id='b' href='#a' spreadMethod='reflect' x1='140' x2='160' y1='0' y2='0' gradientTransform='skewX(-20)'/></defs><rect x='10' y='10' width='100' height='100' fill='url(#a)'/><rect x='130' y='10' width='100' height='100' fill='url(#b)'/>"), maxMean: 0.8),
            Case(name: "gradient-inherit-chain", svg: svg(300, 100, "<defs><linearGradient id='base'><stop offset='0' stop-color='#fff'/><stop offset='.5' style='stop-color:#f90;stop-opacity:.8'/><stop offset='1' stop-color='#900'/></linearGradient><linearGradient id='v' xlink:href='#base' x2='0' y2='1'/><radialGradient id='r' href='#v' r='.7'/><linearGradient id='u' href='#v' gradientUnits='userSpaceOnUse' x1='210' y1='0' x2='290' y2='0'/></defs><rect x='10' y='10' width='80' height='80' fill='url(#v)'/><rect x='110' y='10' width='80' height='80' fill='url(#r)'/><rect x='210' y='10' width='80' height='80' fill='url(#u)'/>"), maxMean: 0.9),
            Case(name: "gradient-on-shapes", svg: svg(300, 140, "<defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='1'><stop offset='0' stop-color='#0cf'/><stop offset='1' stop-color='#c0f'/></linearGradient></defs><ellipse cx='70' cy='40' rx='60' ry='25' fill='url(#g)'/><rect x='150' y='20' width='120' height='30' fill='url(#g)' transform='rotate(12 210 35)'/><path d='M20 90 L140 90 L80 130 Z' fill='none' stroke='url(#g)' stroke-width='10' stroke-linejoin='round'/><rect x='170' y='80' width='110' height='45' fill='#eee' stroke='url(#g)' stroke-width='8'/>"), outline: "shape, shape, shape, shape", maxMean: 0.9),
            Case(name: "gradient-degenerate", svg: svg(240, 80, "<defs><linearGradient id='one'><stop offset='.3' stop-color='#393'/></linearGradient><linearGradient id='none'/><radialGradient id='r0' r='0'><stop offset='0' stop-color='red'/><stop offset='1' stop-color='#c93'/></radialGradient><linearGradient id='order'><stop offset='.6' stop-color='#000'/><stop offset='.2' stop-color='#fff'/><stop offset='2' stop-color='#f00'/></linearGradient></defs><rect x='5' y='10' width='40' height='60' fill='url(#one)'/><rect x='50' y='10' width='40' height='60' fill='url(#none)' stroke='black'/><rect x='140' y='10' width='40' height='60' fill='url(#r0)'/><rect x='185' y='10' width='40' height='60' fill='url(#order)'/>"), maxMean: 0.9),
            // x1 = x2, y1 = y2: the last stop's colour everywhere (SVG 1.1 §13.2.2); WebKit splits the area at x1 instead
            Case(name: "gradient-zero-length", svg: svg(60, 40, "<defs><linearGradient id='zero' gradientUnits='userSpaceOnUse' x1='30' y1='10' x2='30' y2='10'><stop offset='0' stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient></defs><rect x='5' y='5' width='50' height='30' fill='url(#zero)'/>"), outline: "shape", oracle: false,
                 verify: { st, _ in expect(near(pixel(st, 10, 20), [0, 0, 255]) && near(pixel(st, 50, 20), [0, 0, 255]), "solid last stop colour \(pixel(st, 10, 20))") }),
            Case(name: "radial-gradient", svg: svg(360, 120, "<defs><radialGradient id='a'><stop offset='0' stop-color='#fff'/><stop offset='1' stop-color='#06c'/></radialGradient><radialGradient id='b' cx='.3' cy='.3' r='.6'><stop offset='0' stop-color='#ffd'/><stop offset='.6' stop-color='#f80'/><stop offset='1' stop-color='#400'/></radialGradient><radialGradient id='c' gradientUnits='userSpaceOnUse' cx='300' cy='60' r='30' gradientTransform='translate(300 60) scale(1.4 .7) rotate(30) translate(-300 -60)'><stop offset='0' stop-color='#0c9'/><stop offset='1' stop-color='#036'/></radialGradient></defs><circle cx='60' cy='60' r='50' fill='url(#a)'/><rect x='130' y='10' width='110' height='100' fill='url(#b)'/><rect x='250' y='10' width='100' height='100' fill='url(#c)'/>"), outline: "shape, shape, shape", maxMean: 0.9,
                 verify: { st, _ in
                     guard case .gradient(let a)? = st.layers[0].shape?.fill, case .gradient(let b)? = st.layers[1].shape?.fill else { return ["no gradient fills"] }
                     return expect(a.shape == nil && a.type == .radial, "centred circular gradient stays native") + expect(b.shape != nil, "elliptical gradient keeps its exact shape")
                 }),
            Case(name: "radial-focal", svg: svg(240, 120, "<defs><radialGradient id='f' cx='.5' cy='.5' r='.5' fx='.25' fy='.25'><stop offset='0' stop-color='#fff'/><stop offset='1' stop-color='#c03'/></radialGradient><radialGradient id='g' gradientUnits='userSpaceOnUse' cx='180' cy='60' r='50' fx='210' fy='60' fr='5'><stop offset='0' stop-color='#ff0'/><stop offset='1' stop-color='#063'/></radialGradient></defs><circle cx='60' cy='60' r='50' fill='url(#f)'/><circle cx='180' cy='60' r='50' fill='url(#g)'/>"), maxMean: 1.2, maxBad: 0.01),
            // WebKit draws spreadMethod on radial gradients as `pad`; Lumen follows the specification
            Case(name: "radial-spread", svg: svg(240, 120, "<defs><radialGradient id='a' r='.2' spreadMethod='repeat'><stop offset='0' stop-color='#fff'/><stop offset='1' stop-color='#06c'/></radialGradient><radialGradient id='b' r='.2' spreadMethod='reflect'><stop offset='0' stop-color='#fff'/><stop offset='1' stop-color='#c60'/></radialGradient></defs><rect x='10' y='10' width='100' height='100' fill='url(#a)'/><rect x='130' y='10' width='100' height='100' fill='url(#b)'/>"), oracle: false),
            Case(name: "linear-spread", svg: svg(240, 120, "<defs><linearGradient id='a' x1='.4' x2='.6' spreadMethod='repeat'><stop offset='0' stop-color='#fff'/><stop offset='1' stop-color='#06c'/></linearGradient><linearGradient id='b' x1='.4' x2='.6' y2='.1' spreadMethod='reflect'><stop offset='0' stop-color='#fff'/><stop offset='1' stop-color='#c60'/></linearGradient></defs><rect x='10' y='10' width='100' height='100' fill='url(#a)'/><rect x='130' y='10' width='100' height='100' fill='url(#b)'/>"), maxMean: 1.2, maxBad: 0.02),
            Case(name: "strokes", svg: svg(240, 160, "<path d='M20 30 L80 30 L50 80 Z' fill='none' stroke='#222' stroke-width='10' stroke-linejoin='miter'/><path d='M110 30 L170 30 L140 80 Z' fill='#9cf' stroke='#222' stroke-width='10' stroke-linejoin='round'/><path d='M190 30 L230 30 L210 80' fill='none' stroke='#222' stroke-width='10' stroke-linejoin='bevel' stroke-linecap='square'/><path d='M20 120 H220' stroke='#c00' stroke-width='6' stroke-dasharray='12 6 2 6' stroke-dashoffset='5'/><path d='M20 140 H220' stroke='#06c' stroke-width='6' stroke-dasharray='1 10' stroke-linecap='round'/><path d='M100 100 L105 140 L110 100' fill='none' stroke='green' stroke-width='4' stroke-miterlimit='20'/>"),
                 verify: { st, _ in
                     let s = st.layers[3].shape?.stroke
                     return expect(s?.dash == [2, 1, 1.0 / 3, 1] && abs((s?.dashPhase ?? 0) - 5.0 / 6) < 1e-9, "dash pattern in stroke widths: \(s?.dash ?? []) phase \(s?.dashPhase ?? -1)")
                         + expect(st.layers[5].shape?.stroke.miterLimit == 20 && st.layers[0].shape?.stroke.miterLimit == 4, "miter limits kept")
                 }),
            Case(name: "stroke-miter-limit", svg: svg(240, 100, "<path d='M20 80 L40 20 L60 80' fill='none' stroke='#333' stroke-width='8'/><path d='M80 80 L95 20 L110 80' fill='none' stroke='#333' stroke-width='8'/><path d='M130 80 L138 20 L146 80' fill='none' stroke='#333' stroke-width='8'/><path d='M170 80 L178 20 L186 80' fill='none' stroke='#c33' stroke-width='8' stroke-miterlimit='12'/><path d='M205 80 L225 20' fill='none' stroke='#36c' stroke-width='8' stroke-dasharray='5' stroke-dashoffset='13'/>")),
            // a negative offset counts backwards through the pattern (WebKit starts as if it were positive)
            Case(name: "stroke-dash-negative-offset", svg: svg(60, 20, "<path d='M5 10 H55' stroke='#36c' stroke-width='4' stroke-dasharray='5' stroke-dashoffset='-3'/>"), outline: "shape", oracle: false,
                 verify: { st, _ in
                     let s = st.layers[0].shape?.stroke
                     return expect(abs((s?.dashPhase ?? 0) - 1.75) < 1e-9, "offset −3 of a 10-long pattern is phase 7 (in widths: \(s?.dashPhase ?? -1))")
                         + expect(near(pixel(st, 6, 10), [255, 255, 255]) && near(pixel(st, 10, 10), [51, 102, 204]), "the line starts inside the gap")
                 }),
            Case(name: "stroke-dash-shapes", svg: svg(260, 120, "<circle cx='60' cy='60' r='45' fill='none' stroke='#c33' stroke-width='6' stroke-dasharray='20 8'/><rect x='130' y='15' width='110' height='90' rx='18' fill='#eef' stroke='#36c' stroke-width='5' stroke-dasharray='14 6 3 6' stroke-linecap='round'/><ellipse cx='60' cy='60' rx='25' ry='15' fill='none' stroke='black' stroke-width='2' stroke-dasharray='3' stroke-dashoffset='1.5'/>")),
            Case(name: "stroke-dash-edge", svg: svg(240, 90, "<path d='M10 15 H230' stroke='#333' stroke-width='6' stroke-dasharray='10 5 2'/><path d='M10 35 H230' stroke='#333' stroke-width='6' stroke-dasharray='0 0'/><path d='M10 55 H230' stroke='#333' stroke-width='6' stroke-dasharray='10 -5'/><path d='M10 75 H230' stroke='#333' stroke-width='6' stroke-dasharray='5%' pathLength='115'/>")),
            Case(name: "stroke-transformed", svg: svg(300, 140, "<g transform='translate(60 60) rotate(30) scale(2)'><rect x='-15' y='-10' width='30' height='20' fill='#fc6' stroke='#630' stroke-width='3' stroke-dasharray='6 2'/></g><g transform='translate(170 20) scale(3 1)'><circle cx='10' cy='30' r='12' fill='#9cf' stroke='#036' stroke-width='4'/></g><g transform='translate(240 40) skewX(30)'><path d='M0 0 H40 V50' fill='none' stroke='#c03' stroke-width='6' stroke-linejoin='round'/></g><g transform='scale(2)'><line x1='10' y1='62' x2='130' y2='62' stroke='#393' stroke-width='4' vector-effect='non-scaling-stroke'/></g>"),
                 outline: "shape, group[shape, shape], shape, shape", maxMean: 0.8, maxBad: 0.006),
            Case(name: "stroke-only-and-caps", svg: svg(240, 100, "<path d='M20 20 L60 20 M20 50 L60 50 M20 80 L60 80' stroke='#333' stroke-width='10' stroke-linecap='round'/><path d='M90 20 L130 20 M90 50 L130 50' stroke='#c33' stroke-width='10' stroke-linecap='square' fill='red'/><path d='M160 20 Q200 60 160 80' stroke='#36c' stroke-width='6' fill='none'/><path d='M200 20 h30 v60' stroke='#393' stroke-width='6' fill='#cfc' stroke-opacity='.5'/>"), outline: "shape, shape, shape, shape"),
            Case(name: "stroke-multi-subpath", svg: svg(240, 110, "<path d='M20 20 h60 v60 h-60 z M50 50 h60 v50 h-60 z' fill='#fd8' stroke='#630' stroke-width='5'/><path d='M140 20 h40 v40 h-40 z M190 20 h40 v40 h-40 z' fill='#8df' stroke='#036' stroke-width='5'/><path d='M140 75 h40 v25 h-40 z M190 75 h40 v25 h-40 z M150 70 L220 105' fill='#dfd' stroke='#363' stroke-width='4'/>"),
                 verify: { st, r in expect(st.layers.count == 3 && st.layers[0].isGroup && st.layers[1].isShape && st.layers[2].isGroup, "overlapping / mixed subpaths get a separate stroke outline, disjoint ones stay one shape (\(SVGImportQA.outline(st.layers)))") }),
            Case(name: "fill-rule", svg: svg(240, 120, "<path d='M60 10 L90 100 L15 40 L105 40 L30 100 Z' fill='#e74c3c' fill-rule='evenodd' stroke='black' stroke-width='2'/><path d='M180 10 L210 100 L135 40 L225 40 L150 100 Z' fill='#2980b9' fill-rule='nonzero'/><path d='M115 60 a20 20 0 1 0 40 0 a20 20 0 1 0 -40 0 M125 60 a10 10 0 1 0 20 0 a10 10 0 1 0 -20 0' fill-rule='evenodd' fill='#2c3e50'/>")),
            Case(name: "fill-rule-compound", svg: svg(240, 120, "<path d='M10 10 h100 v100 h-100 z M30 30 h60 v60 h-60 z M45 45 h30 v30 h-30 z' fill='#393' fill-rule='evenodd'/><path d='M130 10 h100 v100 h-100 z M150 30 v60 h60 v-60 z' fill='#339' fill-rule='nonzero'/><path d='M160 40 h40 v40 h-40 z M170 50 h20 v20 h-20 z' fill='#fc3' style='fill-rule:evenodd' stroke='#630' stroke-width='3'/>"),
                 verify: { st, _ in expect(st.layers.last?.isShape == true, "even-odd ring whose subpaths do not overlap stays one shape with a live stroke (\(SVGImportQA.outline(st.layers)))") }),
            Case(name: "opacity-group", svg: svg(200, 120, "<rect width='200' height='120' fill='#eee'/><g opacity='.5'><rect x='20' y='20' width='80' height='60' fill='red'/><rect x='60' y='40' width='80' height='60' fill='blue'/></g><rect x='120' y='10' width='60' height='40' fill='green' opacity='.4'/>"), outline: "shape, group[shape, shape], shape"),
            Case(name: "opacity-leaf-stroke", svg: svg(240, 100, "<rect width='240' height='100' fill='#fff'/><rect x='20' y='20' width='80' height='60' fill='#f00' stroke='#00f' stroke-width='16' opacity='.5'/><rect x='140' y='20' width='80' height='60' fill='#f00' fill-opacity='.5' stroke='#00f' stroke-width='16' stroke-opacity='.5'/>")),
            Case(name: "opacity-nested", svg: svg(200, 100, "<g opacity='.8'><g opacity='.5'><rect x='10' y='10' width='80' height='80' fill='#c03'/><g opacity='.5'><circle cx='90' cy='50' r='35' fill='#03c'/></g></g><rect x='120' y='20' width='60' height='60' fill='#393' opacity='0'/></g>")),
            Case(name: "blend-modes", svg: svg(320, 160, "<rect width='320' height='160' fill='#d9c9a5'/><circle cx='50' cy='50' r='35' fill='#e0503a'/><circle cx='80' cy='50' r='35' fill='#2a7fd0' style='mix-blend-mode:multiply'/><circle cx='150' cy='50' r='35' fill='#e0503a'/><circle cx='180' cy='50' r='35' fill='#2a7fd0' style='mix-blend-mode:screen'/><circle cx='250' cy='50' r='35' fill='#e0503a'/><circle cx='280' cy='50' r='35' fill='#2a7fd0' style='mix-blend-mode:overlay'/><circle cx='50' cy='120' r='35' fill='#e0503a'/><circle cx='80' cy='120' r='35' fill='#2a7fd0' style='mix-blend-mode:darken'/><circle cx='150' cy='120' r='35' fill='#e0503a'/><circle cx='180' cy='120' r='35' fill='#2a7fd0' style='mix-blend-mode:difference'/><circle cx='250' cy='120' r='35' fill='#e0503a'/><g style='mix-blend-mode:lighten' opacity='.8'><circle cx='280' cy='120' r='35' fill='#2a7fd0'/></g>"), maxMean: 1.2, maxBad: 0.01,
                 verify: { st, _ in expect(st.layers[2].blendMode == .multiply && st.layers[4].blendMode == .screen && st.layers[6].blendMode == .overlay && st.layers[8].blendMode == .darken && st.layers[10].blendMode == .difference && st.layers[12].blendMode == .lighten, "blend modes mapped") }),
            Case(name: "blend-isolation", svg: svg(240, 100, "<rect width='240' height='100' fill='#9c6'/><g><rect x='20' y='20' width='60' height='60' fill='#c33' style='mix-blend-mode:multiply'/></g><g style='isolation:isolate'><rect x='90' y='20' width='60' height='60' fill='#c33' style='mix-blend-mode:multiply'/></g><g opacity='.99'><rect x='160' y='20' width='60' height='60' fill='#fff'/><rect x='170' y='30' width='40' height='40' fill='#c33' style='mix-blend-mode:multiply'/></g>"), maxMean: 1.2, maxBad: 0.01),
            Case(name: "display-visibility", svg: svg(240, 80, "<rect x='10' y='10' width='40' height='60' fill='#c33' display='none'/><g style='display:none' id='hiddenGroup'><rect x='60' y='10' width='40' height='60' fill='#3c3'/></g><g visibility='hidden'><rect x='110' y='10' width='40' height='60' fill='#33c'/><rect x='160' y='10' width='40' height='60' fill='#cc3' visibility='visible'/></g>"),
                 outline: "shape(hidden), shape(hidden), shape",
                 verify: { st, r in expect(st.layers[1].name == "hiddenGroup", "hidden group's name survives on its only child (\(st.layers[1].name))") + expect(r.hidden == 2, "hidden elements counted (\(r.hidden))") }),
            Case(name: "paint-order", svg: svg(240, 100, "<rect width='240' height='100' fill='#eee'/><circle cx='60' cy='50' r='30' fill='#fc0' stroke='#036' stroke-width='16' paint-order='stroke'/><circle cx='170' cy='50' r='30' fill='#fc0' stroke='#036' stroke-width='16' style='paint-order:stroke fill markers' fill-opacity='.6'/>"), outline: "shape, group[shape, shape], group[shape, shape]"),
        ]
    }

    static func structure() -> [Case] {
        [
            Case(name: "names", svg: svg(200, 80, "<g id='Layer_1' data-name='Layer 1'><rect id='sky' width='90' height='70' fill='#9cf'/><rect width='40' height='30' x='100' fill='#c93'><title>Roof tile</title></rect></g><g id='g1234' inkscape:label='Inked' xmlns:inkscape='http://www.inkscape.org/namespaces/inkscape'><circle id='path77' cx='170' cy='40' r='20' fill='#393'/><circle id='My_x20_Shape_x2C__x31_' cx='120' cy='60' r='10' fill='#933'/></g>"),
                 outline: "group[shape, shape], group[shape, shape]",
                 verify: { st, _ in
                     let n = names(st)
                     return expect(n == ["Layer 1", "sky", "Roof tile", "Inked", "Ellipse", "My Shape,1"], "layer names \(n)")
                 }),
            Case(name: "collapse-nesting", svg: svg(200, 80, "<g><g><g transform='translate(5 5)'><g><g id='icon'><g><path d='M10 10h40v40h-40z' fill='#c33'/></g></g></g></g></g></g><g><g><rect x='70' y='10' width='30' height='30' fill='#3c3'/><rect x='110' y='10' width='30' height='30' fill='#33c'/></g></g><g id='kept'><g id='inner'><rect id='r' x='150' y='10' width='30' height='30' fill='#cc3'/><rect x='150' y='45' width='30' height='20' fill='#3cc'/></g></g><g opacity='.5'><g><g><circle cx='30' cy='65' r='10' fill='black'/></g></g></g>"),
                 outline: "shape, shape, shape, group[group[shape, shape]], shape",
                 verify: { st, _ in
                     expect(st.layers[0].name == "icon", "single child takes the named group's name (\(st.layers[0].name))")
                         + expect(abs(st.layers[4].opacity - 0.5) < 1e-9, "group opacity folded into its only child (\(st.layers[4].opacity))")
                 }),
            Case(name: "css-classes", svg: svg(200, 120, "<style>.a{fill:#1abc9c;stroke:#16a085;stroke-width:4} #big{fill:#f39c12} rect.b{fill:#8e44ad} g .c{fill:#c0392b !important} circle{opacity:.8}</style><rect class='a' x='10' y='10' width='60' height='40'/><rect id='big' class='a' x='80' y='10' width='60' height='40'/><rect class='b a' x='150' y='10' width='40' height='40'/><g><circle class='c' cx='40' cy='90' r='20' fill='blue' style='fill:blue'/><circle cx='100' cy='90' r='20' style='fill:#2c3e50;stroke:#bdc3c7;stroke-width:5'/></g>")),
            Case(name: "css-selectors", svg: svg(260, 120, "<style type='text/css'><![CDATA[\n/* comment */ svg > g.top > rect { fill: #c33 } g rect { fill: #33c } [data-k='v'] { fill: #3c3 } rect[id^='pre'] { stroke: black; stroke-width: 3 } .x.y { fill: #fc0 } * { stroke-linejoin: round } :root { --accent: #909 } .v { fill: var(--accent) } .w { fill: var(--nope, #099) } @media print { rect { fill: red !important } } rect:hover { fill: red } .top ~ rect { fill: red }\n]]></style><g class='top'><rect x='10' y='10' width='40' height='40'/><g><rect x='60' y='10' width='40' height='40'/></g></g><rect data-k='v' x='110' y='10' width='40' height='40'/><rect id='prefix1' x='160' y='10' width='40' height='40' fill='#ccc'/><rect class='y x' x='210' y='10' width='40' height='40'/><rect class='v' x='10' y='65' width='40' height='40'/><rect class='w' x='60' y='65' width='40' height='40'/><style>.late { fill: #f60 } </style><rect class='late' x='110' y='65' width='40' height='40' fill='red'/><rect x='160' y='65' width='40' height='40' style='fill: #06f; fill: bogus'/>")),
            Case(name: "css-cascade-inherit", svg: svg(240, 80, "<style>g{fill:#393} .p{stroke:#333;stroke-width:6}</style><g stroke='red' class='p'><rect x='10' y='10' width='50' height='60'/><rect x='70' y='10' width='50' height='60' fill='#fc0' stroke='inherit'/><g fill='#c33' style='stroke-width:2'><rect x='130' y='10' width='50' height='60'/><rect x='190' y='10' width='40' height='60' fill='inherit' stroke='none'/></g></g>")),
            Case(name: "use-symbol", svg: svg(240, 120, "<defs><g id='dot'><circle r='12' fill='inherit'/><rect x='-3' y='-20' width='6' height='12' fill='black'/></g><symbol id='sym' viewBox='0 0 10 10'><rect width='10' height='10' fill='#9b59b6'/><circle cx='5' cy='5' r='3' fill='white'/></symbol></defs><use href='#dot' x='30' y='40' fill='crimson'/><use xlink:href='#dot' x='80' y='40' fill='seagreen' transform='rotate(45 80 40)'/><use href='#sym' x='120' y='20' width='50' height='50'/><use href='#sym' x='180' y='40' width='40' height='60'/>")),
            Case(name: "use-chains", svg: svg(240, 100, "<defs><rect id='r' width='20' height='20' fill='#c33'/><use id='u1' href='#r' x='5' y='5'/><g id='row'><use href='#u1'/><use href='#u1' x='30'/><use href='#u1' x='60' opacity='.5'/></g><symbol id='s' overflow='visible'><use href='#row'/></symbol></defs><use href='#row' x='10' y='5'/><use href='#row' x='10' y='35' transform='translate(100 0) scale(1.2)'/><use href='#s' x='10' y='70'/><use href='#nothing'/><use href='other.svg#x'/><rect id='live' x='200' y='70' width='20' height='20' fill='#36c'/><use href='#live' x='-60'/>")),
            Case(name: "symbol-viewbox", svg: svg(260, 100, "<symbol id='a' viewBox='0 0 20 10' preserveAspectRatio='xMidYMid slice'><rect width='20' height='10' fill='#fc6'/><circle cx='10' cy='5' r='6' fill='#c03'/></symbol><symbol id='b' viewBox='0 0 10 10' width='30' height='30'><rect width='10' height='10' fill='#06c'/><path d='M0 0L10 10' stroke='white'/></symbol><use href='#a' x='10' y='10' width='80' height='80'/><use href='#b' x='110' y='10'/><use href='#b' x='160' y='10' width='80' height='40'/>")),
            Case(name: "switch-and-links", svg: svg(200, 80, "<switch><foreignObject requiredExtensions='http://ns.adobe.com/AdobeIllustrator/10.0/' width='1' height='1'><p/></foreignObject><g><rect x='10' y='10' width='60' height='60' fill='#393'/></g><rect x='10' y='10' width='60' height='60' fill='red'/></switch><a href='https://example.com/'><circle cx='120' cy='40' r='25' fill='#36c'/></a><switch><rect systemLanguage='xx-nope' x='160' y='10' width='30' height='60' fill='red'/><rect x='160' y='10' width='30' height='60' fill='#c93'/></switch>"), outline: "shape, shape, shape"),
            Case(name: "doctype-entities", svg: "<?xml version='1.0' encoding='UTF-8' standalone='no'?>\n<!DOCTYPE svg PUBLIC '-//W3C//DTD SVG 1.1//EN' 'http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd' [\n<!ENTITY ns_svg 'http://www.w3.org/2000/svg'>\n<!ENTITY ns_xlink 'http://www.w3.org/1999/xlink'>\n<!ENTITY st0 'fill:#c33;'>\n]>\n<svg xmlns='&ns_svg;' xmlns:xlink='&ns_xlink;' width='120' height='60' viewBox='0 0 120 60'><rect width='50' height='40' x='5' y='10' style='&st0;'/><rect id='e' width='50' height='40' x='65' y='10' fill='#36c'/></svg>", outline: "shape, shape"),
            Case(name: "unknown-and-foreign-elements", svg: svg(160, 60, "<sodipodi:namedview xmlns:sodipodi='http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd' pagecolor='#fff'/><metadata><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'><rect width='160' height='60' fill='red'/></rdf:RDF></metadata><unknown><rect width='160' height='60' fill='red'/></unknown><rect x='10' y='10' width='40' height='40' fill='#393'><animate attributeName='opacity' from='1' to='1' dur='2s'/></rect><script>alert(1)</script><rect x='60' y='10' width='40' height='40' fill='#339' onclick='alert(2)'/>"), outline: "shape, shape",
                 verify: { _, r in expect(r.items.contains { $0.message.contains("Animation") } && r.items.contains { $0.message.contains("Script") }, "animation and script are reported as ignored") }),
        ]
    }

    static func text() -> [Case] {
        let loose = (3.8, 0.022)
        return [
            Case(name: "text-simple", svg: svg(300, 120, "<text x='20' y='40' font-family='Helvetica' font-size='28' fill='#1b1f3a'>Hello Lumen</text><text x='150' y='80' font-family='Georgia, serif' font-size='20' font-weight='bold' text-anchor='middle' fill='#c0392b'>Centered bold</text><text x='290' y='110' font-family='Courier' font-size='14' text-anchor='end' font-style='italic'>right aligned</text>"), outline: "text, text, text", maxMean: loose.0, maxBad: loose.1, soft: true,
                 verify: { st, _ in
                     let t = st.layers.compactMap(\.text)
                     return expect(t.map(\.fontName) == ["Helvetica", "Georgia-Bold", "Courier-Oblique"], "fonts \(t.map(\.fontName))")
                         + expect(t.map(\.alignment) == [.left, .center, .right], "alignment follows text-anchor") + expect(t[0].text == "Hello Lumen" && t[0].fontSize == 28, "text and size kept")
                 }),
            Case(name: "text-runs", svg: svg(320, 80, "<text x='10' y='45' font-family='Helvetica' font-size='24' fill='#222'>Plain <tspan font-weight='bold'>bold</tspan> <tspan fill='#c03' font-style='italic'>red italic</tspan> <tspan font-size='14' letter-spacing='3'>small</tspan> <tspan text-decoration='underline'>under</tspan></text>"), outline: "text", maxMean: loose.0, maxBad: loose.1, soft: true,
                 verify: { st, _ in
                     guard let t = st.layers[0].text else { return ["not a text layer"] }
                     return expect(t.text == "Plain bold red italic small under", "whitespace collapsed across tspans: “\(t.text)”") + expect(t.runs.count >= 4, "style runs kept (\(t.runs.count))")
                 }),
            Case(name: "text-lines", svg: svg(240, 140, "<text font-family='Helvetica' font-size='18' fill='#123'><tspan x='20' y='30'>First line</tspan><tspan x='20' dy='1.3em'>Second line</tspan><tspan x='20' dy='1.3em'>Third</tspan></text><text font-family='Times' font-size='16' text-anchor='middle'><tspan x='120' y='105'>centred one</tspan><tspan x='120' y='125'>two</tspan></text>"), outline: "text, text", maxMean: loose.0, maxBad: loose.1, soft: true,
                 verify: { st, _ in
                     let t = st.layers.compactMap(\.text)
                     return expect(t.count == 2 && t[0].text == "First line\nSecond line\nThird" && abs((t[0].leading ?? 0) - 23.4) < 0.01, "three tspans are one paragraph with leading (\(t.first?.text.debugDescription ?? ""), \(t.first?.leading ?? 0))")
                 }),
            Case(name: "text-separate-chunks", svg: svg(240, 100, "<text font-family='Helvetica' font-size='16'><tspan x='10' y='30'>left</tspan><tspan x='150' y='30'>far</tspan><tspan x='60' y='80' fill='#c03'>low</tspan></text>"), outline: "group[text, text, text]", maxMean: loose.0, maxBad: loose.1, soft: true),
            Case(name: "text-illustrator-split", svg: svg(260, 60, "<text transform='matrix(1 0 0 1 12 38)' font-family='Helvetica' font-size='24'><tspan x='0' y='0'>Spl</tspan><tspan x='34.69' y='0'>it by an </tspan><tspan x='118.73' y='0'>exporter</tspan></text>"), outline: "text", maxMean: loose.0, maxBad: loose.1, soft: true,
                 verify: { st, _ in expect(st.layers[0].text?.text == "Split by an exporter", "continuation tspans rejoined: “\(st.layers[0].text?.text ?? "")”") }),
            Case(name: "text-transformed", svg: svg(260, 160, "<text x='0' y='0' font-family='Helvetica' font-size='10' transform='translate(30 60) rotate(-20) scale(2)' fill='#036'>Rotated ×2</text><text x='140' y='120' font-family='Georgia' font-size='22' transform='skewX(-20)'>skewed</text><g transform='scale(1.5 1)'><text x='10' y='140' font-family='Helvetica' font-size='14'>stretched</text></g>"), outline: "text, text, text", maxMean: loose.0, maxBad: loose.1, soft: true,
                 verify: { st, _ in expect(abs((st.layers[0].text?.fontSize ?? 0) - 20) < 1e-6, "uniform scale goes into the font size (\(st.layers[0].text?.fontSize ?? 0))") }),
            Case(name: "text-baseline-spacing", svg: svg(300, 120, "<line x1='0' y1='40' x2='300' y2='40' stroke='#ccc'/><text y='40' font-family='Helvetica' font-size='20'><tspan x='10'>base</tspan></text><text x='70' y='40' font-family='Helvetica' font-size='20' dominant-baseline='middle'>middle</text><text x='150' y='40' font-family='Helvetica' font-size='20' dominant-baseline='hanging'>hang</text><text x='210' y='40' font-family='Helvetica' font-size='20' dominant-baseline='central'>central</text><text x='10' y='90' font-family='Helvetica' font-size='18' letter-spacing='4'>tracked</text><text x='150' y='90' font-family='Helvetica' font-size='1.5em' style='text-transform:uppercase'>upper</text>"), maxMean: loose.0, maxBad: loose.1, soft: true),
            Case(name: "text-whitespace", svg: svg(300, 90, "<text x='10' y='30' font-family='Courier' font-size='16'>  a   b\n   c  </text><text x='10' y='60' font-family='Courier' font-size='16' xml:space='preserve'>a   b  c</text><text x='160' y='60' font-family='Courier' font-size='16' style='white-space:pre'> x  y</text>"), outline: "text, text, text", maxMean: loose.0, maxBad: loose.1, soft: true,
                 verify: { st, _ in
                     let t = st.layers.compactMap { $0.text?.text }
                     return expect(t == ["a b c", "a   b  c", " x  y"], "white space handling \(t)")
                 }),
            Case(name: "text-missing-font", svg: svg(260, 60, "<text x='10' y='38' font-family='No Such Font 123' font-size='26'>Fallback face</text>"), outline: "text", maxMean: loose.0, maxBad: loose.1, soft: true,
                 verify: { st, r in expect(r.missingFonts["No Such Font 123"] != nil && st.layers[0].text?.fontName == "Times-Roman", "missing font reported and substituted (\(r.missingFonts))") }),
            Case(name: "text-outlined-cases", svg: svg(300, 170, "<defs><linearGradient id='g'><stop offset='0' stop-color='#f06'/><stop offset='1' stop-color='#06f'/></linearGradient></defs><text x='10' y='40' font-family='Helvetica' font-weight='bold' font-size='34' fill='url(#g)'>Gradient</text><text x='10' y='85' font-family='Helvetica' font-size='34' fill='#fd0' stroke='#630' stroke-width='1.5'>Stroked</text><text x='10 35 62 90' y='125 120 125 120' font-family='Georgia' font-size='26' fill='#063'>Wavy text</text><text x='160' y='125' font-family='Helvetica' font-size='22' rotate='0 15 30 45' fill='#306'>Spin</text><text x='10' y='160' font-family='Helvetica' font-size='20'>a<tspan dy='-8' font-size='12'>sup</tspan><tspan dy='8'> and </tspan><tspan dx='10'>shifted</tspan></text>"),
                 maxMean: loose.0, maxBad: loose.1, soft: true,
                 verify: { st, r in expect(!st.allLayers.contains { $0.isText } && st.allLayers.filter(\.isShape).count >= 5 && r.outlinedTexts == 5, "five texts became outline shapes (\(SVGImportQA.outline(st.layers)), \(r.outlinedTexts))") }),
            Case(name: "text-path-raster", svg: svg(240, 120, "<defs><path id='curve' d='M20 90 Q120 -10 220 90'/></defs><use href='#curve' fill='none' stroke='#ccc'/><text font-family='Helvetica' font-size='18' fill='#036'><textPath href='#curve' startOffset='20'>Text along a curve</textPath></text>"), outline: "shape, pixel", rasterized: 1),
        ]
    }

    static func imagesClipMask() -> [Case] {
        let img = png(40, 30)
        let nested = "data:image/svg+xml;base64," + Data(svg(20, 20, "<rect width='20' height='20' fill='#fc0'/><circle cx='10' cy='10' r='7' fill='#c03'/>").utf8).base64EncodedString()
        return [
            Case(name: "image-embedded", svg: svg(260, 120, "<rect width='260' height='120' fill='#f4f4f4'/><image x='10' y='10' width='40' height='30' href='\(img)'/><image x='70' y='10' width='100' height='90' xlink:href='\(img)'/><image x='185' y='10' width='60' height='90' preserveAspectRatio='xMidYMid slice' href='\(img)'/><image x='10' y='60' width='40' height='30' href='\(img)' transform='rotate(15 30 75)' opacity='.7'/>"),
                 outline: "shape, pixel, smart, smart+vm, smart", maxMean: 1.6, maxBad: 0.02),
            Case(name: "image-nested-svg", svg: svg(160, 80, "<image x='10' y='10' width='60' height='60' href='\(nested)'/><image x='90' y='20' height='40' href='\(img)'/><image x='0' y='0' width='10' height='10' href='https://example.com/x.png'/><image href='nope.png' width='10' height='10'/>"),
                 outline: "smart, smart", maxMean: 1.6, maxBad: 0.02,
                 verify: { st, r in
                     guard case .document(let d)? = st.layers[0].smart?.source else { return ["nested SVG image is not a document smart object"] }
                     return expect(d.layers.count == 2 && d.layers.allSatisfy(\.isShape), "nested SVG keeps its shapes") + expect(r.items.contains { $0.message.contains("network") }, "remote image reported")
                 }),
            Case(name: "image-fill-pattern", svg: svg(260, 110, "<defs><pattern id='p0' patternContentUnits='objectBoundingBox' width='1' height='1'><use xlink:href='#img0' transform='scale(0.025 0.0333333)'/></pattern><image id='img0' width='40' height='30' xlink:href='\(img)'/><pattern id='p1' patternContentUnits='objectBoundingBox' width='1' height='1'><image width='40' height='30' href='\(img)' transform='matrix(0.0375 0 0 0.05 -0.25 -0.25)'/></pattern></defs><rect x='10' y='10' width='120' height='90' rx='16' fill='url(#p0)'/><circle cx='200' cy='55' r='45' fill='url(#p1)' fill-opacity='.8' stroke='#1b1f3a' stroke-width='4'/>"),
                 outline: "smart+vm, group[smart+vm, shape]", maxMean: 1.8, maxBad: 0.03,
                 verify: { st, r in
                     expect(st.layers[0].smart?.source.size == CGSize(width: 40, height: 30), "the image keeps its own pixels")
                         + expect(abs((st.layers[1].children.first?.opacity ?? 0) - 0.8) < 1e-9 && st.layers[1].name == "Ellipse", "fill-opacity becomes the image layer's opacity; fill and stroke stay together as “\(st.layers[1].name)”")
                         + expect(r.rasterized == 0 && r.invisible == 0, "nothing is rasterized")
                 }),
            Case(name: "clip-path", svg: svg(200, 120, "<defs><clipPath id='c'><circle cx='100' cy='60' r='50'/></clipPath></defs><g clip-path='url(#c)'><rect width='200' height='120' fill='#34495e'/><rect x='80' y='0' width='40' height='120' fill='#f1c40f'/></g>"), outline: "group[shape, shape]+vm"),
            Case(name: "clip-path-variants", svg: svg(320, 120, "<defs><clipPath id='multi' transform='translate(5 0)'><rect x='5' y='10' width='40' height='40'/><circle cx='60' cy='70' r='30' transform='scale(1 .8)'/></clipPath><clipPath id='obb' clipPathUnits='objectBoundingBox'><path d='M.5 0 L1 1 L0 1 Z'/></clipPath><clipPath id='eo'><path d='M210 10 h90 v90 h-90 z M230 30 h50 v50 h-50 z' clip-rule='evenodd'/></clipPath><rect id='cr' x='120' y='60' width='70' height='50'/><clipPath id='viaUse'><use href='#cr'/></clipPath></defs><rect width='100' height='120' fill='#c33' clip-path='url(#multi)'/><rect x='110' y='5' width='80' height='50' fill='#36c' clip-path='url(#obb)'/><rect x='200' width='120' height='120' fill='#393' style='clip-path:url(#eo)'/><circle cx='155' cy='85' r='35' fill='#fc0' clip-path='url(#viaUse)'/>"),
                 outline: "shape+vm, shape+vm, shape+vm, shape+vm"),
            Case(name: "clip-path-nested-text", svg: svg(260, 110, "<defs><clipPath id='outer'><rect x='20' y='0' width='100' height='110'/></clipPath><clipPath id='inner' clip-path='url(#outer)'><circle cx='70' cy='55' r='60'/><rect x='0' y='0' width='10' height='10' clip-path='url(#outer)'/></clipPath><clipPath id='t'><text x='135' y='80' font-family='Helvetica' font-weight='bold' font-size='70'>Ab</text></clipPath></defs><rect width='130' height='110' fill='#c03' clip-path='url(#inner)'/><g clip-path='url(#t)'><rect x='130' width='130' height='55' fill='#fc0'/><rect x='130' y='55' width='130' height='55' fill='#06c'/></g>"),
                 outline: "shape+vm, group[shape, shape]+vm", maxMean: 1.5, maxBad: 0.02),
            Case(name: "clip-canvas-noop", svg: svg(120, 60, "<defs><clipPath id='clip0'><rect width='120' height='60' fill='white'/></clipPath></defs><g clip-path='url(#clip0)'><rect x='10' y='10' width='40' height='40' fill='#c33'/><rect x='70' y='10' width='40' height='40' fill='#36c'/></g>"), outline: "shape, shape"),
            Case(name: "mask", svg: svg(200, 120, "<defs><linearGradient id='g'><stop offset='0' stop-color='white'/><stop offset='1' stop-color='black'/></linearGradient><mask id='m'><rect width='200' height='120' fill='url(#g)'/></mask></defs><rect width='200' height='120' fill='#16a085' mask='url(#m)'/>"), outline: "shape+mask", maxMean: 0.9),
            Case(name: "mask-as-vector", svg: svg(320, 110, "<defs><mask id='sketch' fill='white'><use href='#shape'/></mask><circle id='shape' cx='55' cy='55' r='45'/><mask id='figma' style='mask-type:alpha' maskUnits='userSpaceOnUse' x='115' y='10' width='90' height='90'><rect x='115' y='10' width='90' height='90' rx='20' fill='#D9D9D9'/></mask><mask id='two'><rect x='220' y='10' width='40' height='90' fill='#fff'/><g><path d='M270 10 h40 v90 h-40 z' fill='white'/></g></mask></defs><g mask='url(#sketch)'><rect width='110' height='110' fill='#c33'/><rect y='55' width='110' height='55' fill='#fc0'/></g><g mask='url(#figma)'><rect x='110' width='100' height='110' fill='#36c'/><circle cx='160' cy='55' r='30' fill='#fff'/></g><rect x='215' width='105' height='110' fill='#393' mask='url(#two)'/>"),
                 outline: "group[shape, shape]+vm, group[shape, shape]+vm, shape+vm",
                 verify: { _, r in expect(r.vectorMasks == 3 && r.masks == 0, "opaque masks become vector masks (\(r.vectorMasks) vector, \(r.masks) raster)") }),
            Case(name: "mask-soft-variants", svg: svg(320, 110, "<defs><mask id='grey'><rect width='100' height='110' fill='#888'/></mask><mask id='alpha' mask-type='alpha'><circle cx='160' cy='55' r='50' fill='black' fill-opacity='.5'/><circle cx='160' cy='55' r='25' fill='black'/></mask><radialGradient id='rg'><stop offset='.5' stop-color='#fff'/><stop offset='1' stop-color='#000'/></radialGradient><mask id='obb' maskContentUnits='objectBoundingBox'><rect width='1' height='1' fill='url(#rg)'/></mask></defs><rect width='100' height='110' fill='#c03' mask='url(#grey)'/><rect x='110' width='100' height='110' fill='#06c' mask='url(#alpha)'/><g mask='url(#obb)'><rect x='220' y='5' width='47' height='100' fill='#393'/><rect x='267' y='5' width='48' height='100' fill='#fc0'/></g>"),
                 outline: "shape+mask, shape+mask, group[shape, shape]+mask", maxMean: 0.9, maxBad: 0.006),
        ]
    }

    static func effectsAndRaster() -> [Case] {
        let figmaShadow = "<filter id='fs' x='20' y='14' width='120' height='90' filterUnits='userSpaceOnUse' color-interpolation-filters='sRGB'><feFlood flood-opacity='0' result='BackgroundImageFix'/><feColorMatrix in='SourceAlpha' type='matrix' values='0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 127 0' result='hardAlpha'/><feOffset dy='4'/><feGaussianBlur stdDeviation='4'/><feComposite in2='hardAlpha' operator='out'/><feColorMatrix type='matrix' values='0 0 0 0 0.1 0 0 0 0 0.2 0 0 0 0 0.6 0 0 0 0.5 0'/><feBlend mode='normal' in2='BackgroundImageFix' result='effect1_dropShadow'/><feBlend mode='normal' in='SourceGraphic' in2='effect1_dropShadow' result='shape'/></filter>"
        let figmaInner = "<filter id='fi' x='170' y='20' width='100' height='70' filterUnits='userSpaceOnUse' color-interpolation-filters='sRGB'><feFlood flood-opacity='0' result='BackgroundImageFix'/><feBlend mode='normal' in='SourceGraphic' in2='BackgroundImageFix' result='shape'/><feColorMatrix in='SourceAlpha' type='matrix' values='0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 127 0' result='hardAlpha'/><feOffset dx='3' dy='5'/><feGaussianBlur stdDeviation='3'/><feComposite in2='hardAlpha' operator='arithmetic' k2='-1' k3='1'/><feColorMatrix type='matrix' values='0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0.6 0'/><feBlend mode='normal' in2='shape' result='effect1_innerShadow'/></filter>"
        return [
            Case(name: "drop-shadow-effect", svg: svg(200, 120, "<defs><filter id='f' x='-50%' y='-50%' width='200%' height='200%'><feDropShadow dx='4' dy='6' stdDeviation='3' flood-color='#000' flood-opacity='.5'/></filter></defs><rect x='40' y='25' width='110' height='60' rx='10' fill='#3498db' filter='url(#f)'/>"), outline: "shape+fx", maxMean: 1.0, maxBad: 0.006,
                 verify: { st, _ in
                     let d = st.layers[0].effects.dropShadow
                     return expect(d.enabled && abs(d.distance - 7.211) < 0.01 && abs(d.size - 6.6) < 0.01 && abs(d.opacity - 0.5) < 1e-6 && !d.useGlobalLight, "drop shadow parameters (distance \(d.distance), size \(d.size), opacity \(d.opacity))")
                 }),
            Case(name: "shadow-figma", svg: svg(300, 110, "<defs>\(figmaShadow)\(figmaInner)</defs><rect width='300' height='110' fill='#f2f2f2'/><g filter='url(#fs)'><rect x='28' y='18' width='104' height='74' rx='12' fill='#fff' fill-opacity='.5'/></g><g filter='url(#fi)'><rect x='170' y='20' width='100' height='70' rx='12' fill='#fc6'/></g>"),
                 outline: "shape, shape+fx, shape+fx", maxMean: 1.0, maxBad: 0.006,
                 verify: { st, _ in
                     expect(st.layers[1].effects.dropShadow.enabled && st.layers[1].effects.dropShadow.layerKnocksOut, "Figma drop shadow knocks out under the layer")
                         + expect(st.layers[2].effects.innerShadow.enabled && !st.layers[2].effects.dropShadow.enabled, "Figma inner shadow becomes an inner-shadow effect")
                 }),
            Case(name: "shadow-classic", svg: svg(320, 110, "<defs><filter id='a' x='-30%' y='-30%' width='160%' height='170%'><feGaussianBlur in='SourceAlpha' stdDeviation='3'/><feOffset dx='5' dy='5' result='o'/><feComponentTransfer><feFuncA type='linear' slope='.6'/></feComponentTransfer><feMerge><feMergeNode/><feMergeNode in='SourceGraphic'/></feMerge></filter><filter id='b' x='-30%' y='-30%' width='160%' height='170%' color-interpolation-filters='sRGB'><feOffset in='SourceAlpha' dx='-4' dy='6'/><feGaussianBlur stdDeviation='2.5' result='blur'/><feFlood flood-color='#903' flood-opacity='.7'/><feComposite in2='blur' operator='in'/><feMerge><feMergeNode/><feMergeNode in='SourceGraphic'/></feMerge></filter></defs><circle cx='60' cy='50' r='35' fill='#fc0' filter='url(#a)'/><rect x='130' y='20' width='70' height='60' fill='#9cf' filter='url(#b)'/>"),
                 outline: "shape+fx, shape+fx", maxMean: 1.0, maxBad: 0.006),
            // WebKit does not apply CSS filter functions to SVG elements
            Case(name: "shadow-css-function", svg: svg(110, 100, "<rect x='20' y='20' width='70' height='60' fill='#9f9' style='filter: drop-shadow(3px 5px 2px rgba(0,0,80,.6))'/>"), outline: "shape+fx", oracle: false,
                 verify: { st, _ in
                     let d = st.layers[0].effects.dropShadow
                     return expect(d.enabled && abs(d.size - 4.4) < 0.01 && abs(d.opacity - 0.6) < 1e-6 && near(pixel(st, 60, 83), [140, 140, 172], 25), "CSS drop-shadow() becomes a drop shadow effect (size \(d.size), pixel \(pixel(st, 60, 83)))")
                 }),
            Case(name: "filter-blur-raster", svg: svg(200, 120, "<defs><filter id='f'><feGaussianBlur stdDeviation='4'/></filter></defs><rect x='10' y='10' width='80' height='100' fill='#2ecc71'/><circle cx='140' cy='60' r='35' fill='#e74c3c' filter='url(#f)' opacity='.8' id='Blurry'/>"), outline: "shape, pixel", rasterized: 1,
                 verify: { st, r in expect(abs(st.layers[1].opacity - 0.8) < 1e-9 && st.layers[1].name == "Blurry", "rasterized element keeps its name and opacity as layer properties")
                     + expect(r.items.contains { $0.kind == .rasterized && $0.message.contains("feGaussianBlur") }, "report names the filter") }),
            Case(name: "filter-complex-raster", svg: svg(240, 110, "<defs><filter id='t' x='0' y='0' width='1' height='1'><feTurbulence baseFrequency='.05' numOctaves='2' seed='3'/><feColorMatrix type='saturate' values='3'/><feComposite in2='SourceGraphic' operator='in'/></filter><filter id='m'><feMorphology operator='dilate' radius='3'/></filter><filter id='missingRef'/></defs><rect x='10' y='10' width='100' height='90' fill='#000' filter='url(#t)'/><g filter='url(#m)'><path d='M130 30 h90 M130 60 h90' stroke='#c03' stroke-width='4'/><circle cx='175' cy='85' r='8' fill='#036'/></g>"),
                 outline: "pixel, pixel", rasterized: 2),
            // a filter reference that leads nowhere is ignored (Filter Effects 1); WebKit drops the element instead
            Case(name: "filter-missing-reference", svg: svg(40, 30, "<rect x='5' y='5' width='30' height='20' fill='#393' filter='url(#doesNotExist)'/>"), outline: "shape", oracle: false,
                 verify: { st, _ in expect(near(pixel(st, 20, 15), [51, 153, 51]), "the element is drawn unfiltered") }),
            Case(name: "pattern-raster", svg: svg(200, 120, "<defs><pattern id='p' width='20' height='20' patternUnits='userSpaceOnUse'><circle cx='10' cy='10' r='6' fill='#e67e22'/></pattern></defs><rect x='10' y='10' width='180' height='100' fill='url(#p)' stroke='black'/>"), outline: "pixel", rasterized: 1),
            Case(name: "marker-raster", svg: svg(220, 100, "<defs><marker id='arrow' viewBox='0 0 10 10' refX='9' refY='5' markerWidth='6' markerHeight='6' orient='auto-start-reverse'><path d='M0 0L10 5L0 10z' fill='#c03'/></marker><marker id='dot' markerWidth='4' markerHeight='4' refX='2' refY='2'><circle cx='2' cy='2' r='2' fill='#036'/></marker></defs><path d='M20 80 L80 20 L140 80 L200 20' fill='none' stroke='#333' stroke-width='3' marker-start='url(#arrow)' marker-mid='url(#dot)' marker-end='url(#arrow)'/><rect x='10' y='5' width='20' height='10' fill='#393' marker-end='url(#arrow)'/>"),
                 outline: "pixel, shape", rasterized: 1),
            Case(name: "foreign-object-raster", svg: svg(220, 90, "<rect width='220' height='90' fill='#eef'/><foreignObject x='10' y='10' width='200' height='70'><div xmlns='http://www.w3.org/1999/xhtml' style='font: 16px Helvetica; color: #036; background: #fff; border: 2px solid #c03; padding: 6px'>HTML <b>inside</b> SVG<script>document.title = 'x'</script></div></foreignObject>"),
                 outline: "shape, pixel", rasterized: 1),
            Case(name: "raster-inside-use", svg: svg(240, 90, "<defs><pattern id='p' width='8' height='8' patternUnits='userSpaceOnUse'><rect width='4' height='4' fill='#c03'/></pattern><g id='tile'><rect width='50' height='50' fill='url(#p)' stroke='#333'/><circle cx='25' cy='25' r='10' fill='#036'/></g></defs><use href='#tile' x='10' y='20' id='First'/><use href='#tile' x='90' y='20' opacity='.5' transform='rotate(10 115 45)'/><rect x='170' y='20' width='50' height='50' fill='#393'/>"),
                 outline: "pixel, pixel, shape", rasterized: 2,
                 verify: { st, _ in expect(st.layers[0].name == "First" && abs(st.layers[1].opacity - 0.5) < 1e-9, "rasterized instances keep name and opacity (\(st.layers[0].name), \(st.layers[1].opacity))") }),
            Case(name: "raster-under-transform-and-group", svg: svg(240, 120, "<defs><filter id='b' x='-20%' y='-20%' width='140%' height='140%'><feGaussianBlur stdDeviation='2'/></filter><clipPath id='c'><rect x='0' y='0' width='70' height='70'/></clipPath></defs><g transform='translate(30 20) rotate(10)' opacity='.6' clip-path='url(#c)'><rect width='60' height='60' fill='#fc0'/><g transform='scale(1.5)'><circle cx='30' cy='30' r='14' fill='#c03' filter='url(#b)'/></g></g><g filter='url(#b)' transform='translate(140 20)'><rect width='70' height='30' fill='#06c'/><text x='5' y='60' font-family='Helvetica' font-size='20' fill='#333'>soft</text></g>"),
                 outline: "group[shape, pixel]+vm, pixel", maxMean: 0.9, maxBad: 0.006, rasterized: 2),
            Case(name: "whole-image-filter", svg: "<svg xmlns='http://www.w3.org/2000/svg' width='120' height='80' viewBox='0 0 120 80' filter='url(#f)' opacity='.9'><defs><filter id='f'><feGaussianBlur stdDeviation='1.5'/></filter></defs><rect x='20' y='20' width='80' height='40' fill='#c03'/></svg>", outline: "pixel", rasterized: 1),
        ]
    }
}
