import AppKit
import CoreImage
import ImageCratCore

let sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let graySpace = CGColorSpaceCreateDeviceGray()
let linearGraySpace = CGColorSpace(name: CGColorSpace.linearGray)!

extension RGBA {
    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor.usingColorSpace(.deviceRGB) ?? .black
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    var cgColor: CGColor { CGColor(colorSpace: sRGBSpace, components: [r, g, b, a])! }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var ciColor: CIColor { CIColor(red: r, green: g, blue: b, alpha: a, colorSpace: sRGBSpace) ?? CIColor(red: r, green: g, blue: b, alpha: a) }
    /// Premultiplied CIColor for constant generator images.
    var ciImage: CIImage { CIImage(color: ciColor) }
}
