import Foundation
import CoreGraphics
import CoreText
import ImageIO

// Test corpus for the web-export self tests: generated artwork (logo on alpha, soft shadows, a UI screenshot with
// text, gradients), generic macOS system pictures, and the edge cases of the PNG format.

struct WXCorpusItem {
    enum Kind { case artwork, photo, edge }
    var name: String
    var image: UPImage
    var kind: Kind
    /// Whether the perceptual (lossy) path is exercised on this item.
    var lossy: Bool
}

enum WXCorpus {
    static func context(_ w: Int, _ h: Int) -> CGContext {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: UPBridge.srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)     // top-left origin
        return ctx
    }

    static func image(_ ctx: CGContext) -> UPImage {
        let w = ctx.width, h = ctx.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let src = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for i in 0..<(w * 4) { px[y * w * 4 + i] = src[y * ctx.bytesPerRow + i] } }
        UPBridge.unpremultiply(&px)
        return UPImage(width: w, height: h, px: px)
    }

    static func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
    }

    static func text(_ ctx: CGContext, _ s: String, x: CGFloat, y: CGFloat, size: CGFloat, color c: CGColor, bold: Bool = false, font name: String? = nil) {
        let font = CTFontCreateWithName((name ?? (bold ? "Helvetica-Bold" : "Helvetica")) as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): c]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.saveGState()
        ctx.translateBy(x: x, y: y); ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func rounded(_ ctx: CGContext, _ r: CGRect, _ rad: CGFloat, _ c: CGColor) {
        ctx.setFillColor(c)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.fillPath()
    }

    // MARK: artwork

    /// Flat logo / UI artwork on a transparent background (anti-aliased edges, few colours).
    static func logo(_ w: Int = 512, _ h: Int = 320) -> UPImage {
        let c = context(w, h)
        rounded(c, CGRect(x: 24, y: 24, width: 200, height: 200), 44, color(0x2E86AB))
        c.setFillColor(color(0xF6F5AE)); c.fillEllipse(in: CGRect(x: 64, y: 64, width: 120, height: 120))
        c.setFillColor(color(0xE94F37))
        c.move(to: CGPoint(x: 124, y: 84)); c.addLine(to: CGPoint(x: 164, y: 156)); c.addLine(to: CGPoint(x: 84, y: 156)); c.closePath(); c.fillPath()
        text(c, "Lumen", x: 244, y: 120, size: 72, color: color(0x1B1F3A), bold: true)
        text(c, "Ultra PNG export", x: 248, y: 162, size: 26, color: color(0x5A6072))
        rounded(c, CGRect(x: 248, y: 190, width: 150, height: 42), 21, color(0x3BB273))
        text(c, "Download", x: 276, y: 219, size: 20, color: color(0xFFFFFF), bold: true)
        c.setStrokeColor(color(0x1B1F3A)); c.setLineWidth(3)
        for i in 0..<8 { c.strokeEllipse(in: CGRect(x: 40 + CGFloat(i) * 56, y: 256, width: 36, height: 36)) }
        return image(c)
    }

    /// A card with a wide, soft drop shadow over transparency (smooth alpha ramps).
    static func shadow(_ w: Int = 480, _ h: Int = 320) -> UPImage {
        let c = context(w, h)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -14), blur: 38, color: color(0x000000, 0.55))
        rounded(c, CGRect(x: 70, y: 50, width: 340, height: 190), 22, color(0xFFFFFF))
        c.restoreGState()
        rounded(c, CGRect(x: 94, y: 76, width: 64, height: 64), 32, color(0x7B61FF))
        text(c, "Soft shadow card", x: 176, y: 106, size: 24, color: color(0x20222B), bold: true)
        text(c, "Alpha ramps compress badly.", x: 176, y: 134, size: 16, color: color(0x6A6F7D))
        rounded(c, CGRect(x: 94, y: 170, width: 292, height: 10), 5, color(0xE7E9F0))
        rounded(c, CGRect(x: 94, y: 170, width: 180, height: 10), 5, color(0x7B61FF))
        c.setFillColor(color(0xFF4D6D, 0.6)); c.fillEllipse(in: CGRect(x: 330, y: 190, width: 110, height: 110))
        return image(c)
    }

    /// A synthetic application screenshot: chrome, sidebar, list rows and plenty of small text.
    static func screenshot(_ w: Int = 640, _ h: Int = 400) -> UPImage {
        let c = context(w, h)
        c.setFillColor(color(0xF4F5F7)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let bar = CGGradient(colorsSpace: UPBridge.srgb, colors: [color(0xE9EAEE), color(0xD9DBE1)] as CFArray, locations: [0, 1])!
        c.saveGState(); c.clip(to: CGRect(x: 0, y: 0, width: w, height: 36))
        c.drawLinearGradient(bar, start: .zero, end: CGPoint(x: 0, y: 36), options: []); c.restoreGState()
        for (i, col) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() { c.setFillColor(color(UInt32(col))); c.fillEllipse(in: CGRect(x: 14 + i * 20, y: 12, width: 12, height: 12)) }
        text(c, "Inbox — 12 unread messages", x: 210, y: 24, size: 13, color: color(0x3C4150), bold: true)
        c.setFillColor(color(0x252A3A)); c.fill(CGRect(x: 0, y: 36, width: 150, height: h - 36))
        let items = ["Inbox", "Starred", "Sent", "Drafts", "Archive", "Spam", "Trash"]
        for (i, s) in items.enumerated() {
            if i == 0 { rounded(c, CGRect(x: 8, y: 50, width: 134, height: 26), 6, color(0x3D7BFD)) }
            text(c, s, x: 22, y: 68 + CGFloat(i) * 30, size: 13, color: color(i == 0 ? 0xFFFFFF : 0xB9C0D4))
        }
        let subjects = ["Quarterly report is ready for review", "Re: Lunch on Thursday?", "Your invoice #20418 has been paid", "Design review notes and next steps",
                        "Build 4.2.1 passed all checks", "Weekend hiking trip — packing list", "Password changed successfully", "New comment on “Export pipeline”",
                        "Reminder: dentist appointment", "Welcome to the beta programme", "Minutes from Monday's stand-up"]
        for (i, s) in subjects.enumerated() {
            let y = 44 + CGFloat(i) * 32
            if i % 2 == 1 { c.setFillColor(color(0xECEEF3)); c.fill(CGRect(x: 150, y: y, width: CGFloat(w) - 150, height: 32)) }
            c.setFillColor(color([0x3D7BFD, 0x3BB273, 0xE94F37, 0xF2A541][i % 4])); c.fillEllipse(in: CGRect(x: 162, y: y + 8, width: 16, height: 16))
            text(c, s, x: 190, y: y + 21, size: 13, color: color(0x20222B), bold: i < 3)
            text(c, "\(9 + i % 3):\(10 + i * 4)", x: CGFloat(w) - 52, y: y + 21, size: 11, color: color(0x8A90A0))
        }
        return image(c)
    }

    /// Smooth multi-stop linear gradient with a radial glow (banding torture test).
    static func gradient(_ w: Int = 512, _ h: Int = 320) -> UPImage {
        let c = context(w, h)
        let g = CGGradient(colorsSpace: UPBridge.srgb, colors: [color(0x1A2A6C), color(0xB21F1F), color(0xFDBB2D)] as CFArray, locations: [0, 0.55, 1])!
        c.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: w, y: h), options: [])
        let glow = CGGradient(colorsSpace: UPBridge.srgb, colors: [color(0xFFFFFF, 0.55), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        c.drawRadialGradient(glow, startCenter: CGPoint(x: 150, y: 110), startRadius: 0, endCenter: CGPoint(x: 150, y: 110), endRadius: 190, options: [])
        return image(c)
    }

    /// Pure two-stop linear gradient (what CSS could draw for free).
    static func cssGradient(_ w: Int = 400, _ h: Int = 240) -> UPImage {
        let c = context(w, h)
        let g = CGGradient(colorsSpace: UPBridge.srgb, colors: [color(0x8EC5FC), color(0xE0C3FC)] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        return image(c)
    }

    /// Generic macOS system picture, scaled to fit `maxSide` (nil when the file is missing).
    static func systemPicture(_ path: String, maxSide: Int, crop: CGRect? = nil) -> UPImage? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxSide,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard var cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        if let r = crop, let c = cg.cropping(to: r) { cg = c }
        var img = UPBridge.render(cg)
        for i in stride(from: 3, to: img.px.count, by: 4) { img.px[i] = 255 }
        return img
    }

    /// A photo with a caption bar and headline drawn on top (text + photo in one image).
    static func photoWithText(_ photo: UPImage) -> UPImage {
        let w = photo.width, h = photo.height
        let c = context(w, h)
        if let cg = UPBridge.cgImage(photo) {
            c.saveGState(); c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); c.restoreGState()
        }
        c.setFillColor(color(0x000000, 0.55)); c.fill(CGRect(x: 0, y: CGFloat(h) - 64, width: CGFloat(w), height: 64))
        text(c, "Coastline at dusk", x: 16, y: CGFloat(h) - 34, size: 22, color: color(0xFFFFFF), bold: true)
        text(c, "Photo caption in small type, 12 px", x: 16, y: CGFloat(h) - 14, size: 12, color: color(0xE0E3EA))
        text(c, "SALE", x: CGFloat(w) - 120, y: 48, size: 40, color: color(0xFFE14D), bold: true)
        var img = image(c)
        for i in stride(from: 3, to: img.px.count, by: 4) { img.px[i] = 255 }
        return img
    }

    /// Procedural stand-in when no system picture is available: clouds of smooth noise plus grain.
    static func syntheticPhoto(_ w: Int = 384, _ h: Int = 256) -> UPImage {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var s: UInt64 = 0x1234_5678_9ABC_DEF1
        func rnd() -> Double { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return Double(s >> 11) / Double(1 << 53) }
        let gw = 12, gh = 9
        var grid = [Double](repeating: 0, count: (gw + 1) * (gh + 1) * 3)
        for i in 0..<grid.count { grid[i] = rnd() }
        for y in 0..<h {
            for x in 0..<w {
                let fx = Double(x) / Double(w) * Double(gw), fy = Double(y) / Double(h) * Double(gh)
                let ix = Int(fx), iy = Int(fy)
                let tx = fx - Double(ix), ty = fy - Double(iy)
                let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
                for c in 0..<3 {
                    func g(_ a: Int, _ b: Int) -> Double { grid[((iy + b) * (gw + 1) + ix + a) * 3 + c] }
                    let v = (g(0, 0) * (1 - sx) + g(1, 0) * sx) * (1 - sy) + (g(0, 1) * (1 - sx) + g(1, 1) * sx) * sy
                    let grain = (rnd() - 0.5) * (y > h / 2 ? 0.16 : 0.03)
                    px[(y * w + x) * 4 + c] = UInt8(max(0, min(255, (v * 0.8 + 0.1 + grain) * 255)))
                }
            }
        }
        return UPImage(width: w, height: h, px: px)
    }

    // MARK: edge cases

    static func solid(_ w: Int, _ h: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> UPImage {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBufferPointer { p in
            var i = 0
            let n = p.count
            while i < n { p[i] = r; p[i + 1] = g; p[i + 2] = b; p[i + 3] = a; i += 4 }
        }
        return UPImage(width: w, height: h, px: px)
    }

    /// `count` distinct opaque colours in a repeating pattern.
    static func nColors(_ w: Int, _ h: Int, count: Int, alpha: Bool = false) -> UPImage {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let k = ((x / 3) + (y / 2) * 7) % count
                let o = (y * w + x) * 4
                px[o] = UInt8(k & 255); px[o + 1] = UInt8((k * 5 + 40) & 255); px[o + 2] = UInt8(k >> 8 == 0 ? 200 - (k & 127) : 17)
                if alpha { px[o + 3] = k % 4 == 0 ? 0 : (k % 4 == 1 ? 96 : (k % 4 == 2 ? 190 : 255)) }
            }
        }
        return UPImage(width: w, height: h, px: px)
    }

    /// Pixel art with `levels` colours and an odd width (exercises 1 / 2 / 4-bit packing and row padding).
    static func indexedArt(_ w: Int, _ h: Int, levels: Int, gray: Bool) -> UPImage {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var s: UInt64 = UInt64(w * 131 + h * 17 + levels)
        func rnd(_ n: Int) -> Int { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return Int((s >> 13) % UInt64(n)) }
        let pal: [(UInt8, UInt8, UInt8)] = (0..<levels).map { i in
            if gray { let v = UInt8(i * 255 / max(1, levels - 1)); return (v, v, v) }
            return (UInt8((i * 97 + 30) & 255), UInt8((i * 53 + 90) & 255), UInt8((i * 151 + 10) & 255))
        }
        for y in 0..<h {
            for x in 0..<w {
                var k = ((x / 5) ^ (y / 4)) % levels
                if rnd(9) == 0 { k = rnd(levels) }
                let o = (y * w + x) * 4
                px[o] = pal[k].0; px[o + 1] = pal[k].1; px[o + 2] = pal[k].2
            }
        }
        return UPImage(width: w, height: h, px: px)
    }

    static func deep16(_ w: Int, _ h: Int, reducible: Bool, alpha: Bool) -> UPImage {
        var p = [UInt16](repeating: 65535, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                if reducible {
                    p[o] = UInt16((x * 255 / max(1, w - 1))) * 257; p[o + 1] = UInt16((y * 255 / max(1, h - 1))) * 257; p[o + 2] = UInt16(((x + y) & 255)) * 257
                } else {
                    p[o] = UInt16(x * 65535 / max(1, w - 1)); p[o + 1] = UInt16(y * 65535 / max(1, h - 1)); p[o + 2] = UInt16((x * 131 + y * 517) & 65535)
                }
                if alpha { p[o + 3] = reducible ? UInt16(min(255, x * 4)) * 257 : UInt16(min(65535, x * 1111)) }
            }
        }
        return UPImage(width: w, height: h, px16: p)
    }

    /// Gray photo-like ramp with optional alpha.
    static func grayRamp(_ w: Int, _ h: Int, alpha: Bool) -> UPImage {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = UInt8((x * 255 / max(1, w - 1) + (y * 3) % 17) & 255)
                let o = (y * w + x) * 4
                px[o] = v; px[o + 1] = v; px[o + 2] = v
                if alpha { px[o + 3] = UInt8(min(255, y * 255 / max(1, h - 1))) }
            }
        }
        return UPImage(width: w, height: h, px: px)
    }

    /// Opaque sprite on binary transparency (colour-key candidate).
    static func binaryAlphaSprite(_ w: Int = 96, _ h: Int = 96, gray: Bool) -> UPImage {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let dx = x - w / 2, dy = y - h / 2
                guard dx * dx + dy * dy < (w / 2 - 4) * (w / 2 - 4) else { continue }
                let o = (y * w + x) * 4
                let v = UInt8((x * 2 + y * 3) & 255)
                px[o] = v; px[o + 1] = gray ? v : UInt8((x * 5) & 255); px[o + 2] = gray ? v : UInt8((y * 7) & 255); px[o + 3] = 255
            }
        }
        return UPImage(width: w, height: h, px: px)
    }

    static let picturesDir = "/System/Library/Desktop Pictures"

    static func build(large: Bool) -> [WXCorpusItem] {
        var items: [WXCorpusItem] = []
        items.append(WXCorpusItem(name: "logo_alpha", image: logo(), kind: .artwork, lossy: true))
        items.append(WXCorpusItem(name: "shadow_alpha", image: shadow(), kind: .artwork, lossy: true))
        items.append(WXCorpusItem(name: "screenshot", image: screenshot(), kind: .artwork, lossy: true))
        items.append(WXCorpusItem(name: "gradient", image: gradient(), kind: .artwork, lossy: true))
        let fm = FileManager.default
        var photos: [(String, UPImage)] = []
        let thumbs = ["Big Sur Coastline", "The Lake", "Catalina Rock", "Tree"]
        for t in thumbs {
            let p = "\(picturesDir)/.thumbnails/\(t).heic"
            if fm.fileExists(atPath: p), let im = systemPicture(p, maxSide: 360) { photos.append(("photo_" + t.lowercased().replacingOccurrences(of: " ", with: "_"), im)) }
            if photos.count >= 2 { break }
        }
        if large, fm.fileExists(atPath: "\(picturesDir)/Sonoma.heic"), let im = systemPicture("\(picturesDir)/Sonoma.heic", maxSide: 1024) {
            photos.append(("photo_sonoma_1024", im))
        }
        if photos.isEmpty { photos.append(("photo_synthetic", syntheticPhoto())) }
        for (n, im) in photos { items.append(WXCorpusItem(name: n, image: im, kind: .photo, lossy: true)) }
        items.append(WXCorpusItem(name: "photo_text", image: photoWithText(photos[0].1), kind: .photo, lossy: true))
        // edge cases
        items.append(WXCorpusItem(name: "edge_1x1", image: solid(1, 1, 200, 30, 90, 255), kind: .edge, lossy: true))
        items.append(WXCorpusItem(name: "edge_1x1_alpha", image: solid(1, 1, 200, 30, 90, 128), kind: .edge, lossy: false))
        items.append(WXCorpusItem(name: "edge_1x37", image: nColors(1, 37, count: 9), kind: .edge, lossy: true))
        items.append(WXCorpusItem(name: "edge_41x1", image: nColors(41, 1, count: 9), kind: .edge, lossy: false))
        items.append(WXCorpusItem(name: "edge_transparent", image: solid(64, 48, 0, 0, 0, 0), kind: .edge, lossy: true))
        items.append(WXCorpusItem(name: "edge_hidden_rgb", image: { var i = nColors(40, 30, count: 200); for k in stride(from: 3, to: i.px.count, by: 8) { i.px[k] = 0 }; return i }(), kind: .edge, lossy: false))
        items.append(WXCorpusItem(name: "edge_16bit", image: deep16(96, 64, reducible: false, alpha: false), kind: .edge, lossy: false))
        items.append(WXCorpusItem(name: "edge_16bit_alpha", image: deep16(80, 50, reducible: false, alpha: true), kind: .edge, lossy: false))
        items.append(WXCorpusItem(name: "edge_16bit_as8", image: deep16(96, 64, reducible: true, alpha: true), kind: .edge, lossy: false))
        items.append(WXCorpusItem(name: "edge_256colors", image: nColors(160, 90, count: 256), kind: .edge, lossy: false))
        items.append(WXCorpusItem(name: "edge_257colors", image: nColors(160, 90, count: 257), kind: .edge, lossy: true))
        items.append(WXCorpusItem(name: "edge_pal_alpha", image: nColors(120, 80, count: 60, alpha: true), kind: .edge, lossy: true))
        items.append(WXCorpusItem(name: "edge_1bit_w37", image: indexedArt(37, 29, levels: 2, gray: false), kind: .edge, lossy: false))
        items.append(WXCorpusItem(name: "edge_2bit_w37", image: indexedArt(37, 29, levels: 4, gray: false), kind: .edge, lossy: false))
        items.append(WXCorpusItem(name: "edge_4bit_w37", image: indexedArt(37, 29, levels: 16, gray: false), kind: .edge, lossy: false))
        items.append(WXCorpusItem(name: "edge_gray1_w13", image: indexedArt(13, 11, levels: 2, gray: true), kind: .edge, lossy: false))
        items.append(WXCorpusItem(name: "edge_gray2_w13", image: indexedArt(13, 11, levels: 4, gray: true), kind: .edge, lossy: false))
        items.append(WXCorpusItem(name: "edge_gray4_w13", image: indexedArt(13, 11, levels: 16, gray: true), kind: .edge, lossy: false))
        items.append(WXCorpusItem(name: "edge_gray8", image: grayRamp(200, 60, alpha: false), kind: .edge, lossy: false))
        items.append(WXCorpusItem(name: "edge_gray_alpha", image: grayRamp(200, 60, alpha: true), kind: .edge, lossy: false))
        items.append(WXCorpusItem(name: "edge_key_rgb", image: binaryAlphaSprite(gray: false), kind: .edge, lossy: false))
        items.append(WXCorpusItem(name: "edge_key_gray", image: binaryAlphaSprite(gray: true), kind: .edge, lossy: false))
        items.append(WXCorpusItem(name: "edge_huge_flat", image: solid(large ? 4096 : 1536, large ? 4096 : 1536, 36, 120, 200, 255), kind: .edge, lossy: false))
        return items
    }
}
