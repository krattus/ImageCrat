import Foundation
import CoreGraphics
import ImageCratCore

extension PatternDef {
    static let builtIn: [PatternDef] = PatternLibrary.makeBuiltIns()
}

enum PatternLibrary {
    static func makeBuiltIns() -> [PatternDef] {
        var out: [PatternDef] = []
        func make(_ id: String, _ name: String, _ size: Int, _ draw: (CGContext, CGFloat) -> Void) {
            let b = PixelBuffer(width: size, height: size)
            draw(b.context, CGFloat(size))
            b.markDirty()
            out.append(PatternDef(id: id, name: name, image: b))
        }
        make("checker", "Checkerboard", 32) { c, s in
            c.setFillColor(RGBA.white.cgColor); c.fill(CGRect(x: 0, y: 0, width: s, height: s))
            c.setFillColor(RGBA(gray: 0.75).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: s / 2, height: s / 2)); c.fill(CGRect(x: s / 2, y: s / 2, width: s / 2, height: s / 2))
        }
        make("dots", "Polka Dots", 24) { c, s in
            c.setFillColor(RGBA.white.cgColor); c.fill(CGRect(x: 0, y: 0, width: s, height: s))
            c.setFillColor(RGBA(gray: 0.2).cgColor)
            c.fillEllipse(in: CGRect(x: s * 0.3, y: s * 0.3, width: s * 0.4, height: s * 0.4))
        }
        make("stripes", "Diagonal Stripes", 16) { c, s in
            c.setFillColor(RGBA.white.cgColor); c.fill(CGRect(x: 0, y: 0, width: s, height: s))
            c.setStrokeColor(RGBA(gray: 0.3).cgColor); c.setLineWidth(s * 0.25)
            for k in -1...1 {
                c.move(to: CGPoint(x: CGFloat(k) * s, y: s)); c.addLine(to: CGPoint(x: CGFloat(k) * s + s, y: 0))
            }
            c.strokePath()
        }
        make("grid", "Grid", 32) { c, s in
            c.setFillColor(RGBA.white.cgColor); c.fill(CGRect(x: 0, y: 0, width: s, height: s))
            c.setFillColor(RGBA(gray: 0.55).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: s, height: 1)); c.fill(CGRect(x: 0, y: 0, width: 1, height: s))
        }
        make("bricks", "Bricks", 64) { c, s in
            c.setFillColor(RGBA(hex: "B5563A")!.cgColor); c.fill(CGRect(x: 0, y: 0, width: s, height: s))
            c.setFillColor(RGBA(hex: "E8DCCB")!.cgColor)
            let h = s / 4
            for r in 0..<4 {
                c.fill(CGRect(x: 0, y: CGFloat(r) * h, width: s, height: 3))
                let off: CGFloat = r % 2 == 0 ? 0 : s / 2
                c.fill(CGRect(x: off, y: CGFloat(r) * h, width: 3, height: h))
                c.fill(CGRect(x: off + s / 2, y: CGFloat(r) * h, width: 3, height: h))
            }
        }
        make("noise", "Noise", 64) { c, s in
            var rng = SystemRandomNumberGenerator()
            let n = Int(s)
            for y in 0..<n { for x in 0..<n {
                let v = Double(UInt8.random(in: 90...200, using: &rng)) / 255
                c.setFillColor(RGBA(gray: v).cgColor)
                c.fill(CGRect(x: x, y: y, width: 1, height: 1))
            } }
        }
        make("hex", "Honeycomb", 48) { c, s in
            c.setFillColor(RGBA(hex: "F2C94C")!.cgColor); c.fill(CGRect(x: 0, y: 0, width: s, height: s))
            c.setStrokeColor(RGBA(hex: "8A6D1D")!.cgColor); c.setLineWidth(2)
            let r = s / 4
            for (cx, cy) in [(s / 4, s / 4), (s * 3 / 4, s * 3 / 4), (s * 3 / 4, -s / 4), (s / 4, s * 5 / 4), (-s / 4, s * 3 / 4), (s * 5 / 4, s / 4)] {
                let p = CGMutablePath()
                for i in 0..<6 {
                    let a = CGFloat(i) * .pi / 3
                    let pt = CGPoint(x: cx + r * 1.15 * cos(a), y: cy + r * 1.15 * sin(a))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                p.closeSubpath()
                c.addPath(p); c.strokePath()
            }
        }
        make("canvas", "Canvas", 32) { c, s in
            c.setFillColor(RGBA(hex: "EDE6D6")!.cgColor); c.fill(CGRect(x: 0, y: 0, width: s, height: s))
            c.setFillColor(RGBA(hex: "D5CBB5")!.cgColor)
            for i in stride(from: 0, to: Int(s), by: 4) {
                c.fill(CGRect(x: CGFloat(i), y: 0, width: 1.5, height: s))
                c.fill(CGRect(x: 0, y: CGFloat(i) + 2, width: s, height: 1))
            }
        }
        return out
    }

    static func pattern(id: String?, custom: [PatternDef]) -> PatternDef? {
        guard let id else { return nil }
        return (custom + PatternDef.builtIn).first { $0.id == id }
    }
}
