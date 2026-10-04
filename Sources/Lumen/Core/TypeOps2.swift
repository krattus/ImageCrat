import Foundation
import CoreGraphics
import ImageCratCore

/// Area type / point ↔ paragraph conversions / Dynamic Text baking.
extension TextContent {
    /// Area type bounded by `docPath` (document coordinates). Character settings come from `base`.
    static func areaText(in docPath: VectorPath, base: TextContent) -> TextContent {
        var t = base
        let b = docPath.bounds
        t.position = b.origin
        t.boxSize = CGSize(width: max(1, b.width), height: max(1, b.height))
        t.area = AreaTextShape(path: docPath.applying(CGAffineTransform(translationX: -b.minX, y: -b.minY)))
        t.orientation = .horizontal
        t.pathText = nil
        t.transform = .identity
        return t
    }

    var isPointText: Bool { boxSize == nil && pathText == nil }
    var isParagraphText: Bool { boxSize != nil && area == nil && pathText == nil }
    var isAreaText: Bool { area != nil && pathText == nil }

    /// Bakes the Dynamic Text size into the character settings and turns the option off.
    mutating func bakeFit() {
        guard fitToBox != nil else { return }
        let L = TextRenderer.layout(self)
        self = TextRenderer.fitScaled(self, Double(L.fitScale), L.fitTracking)
    }

    /// Type ▸ Convert to Point Text: soft line breaks become hard returns; box / shape removed.
    mutating func convertToPointText() {
        guard boxSize != nil, pathText == nil else { return }
        bakeFit()
        let L = TextRenderer.layout(self)
        let ns = text as NSString
        var inserts: [Int] = []
        let lines = L.lines.filter { !$0.isMarker && $0.textRange.location != NSNotFound }
        for i in 0..<max(0, lines.count - 1) {
            let r = lines[i].textRange
            let end = r.location + r.length
            guard end > 0, end <= ns.length else { continue }
            let c = ns.character(at: end - 1)
            if c == 10 || c == 13 || c == 0x2028 || c == 0x2029 { continue }
            inserts.append(end)
        }
        // Lines dropped because they overflowed the box stay in the text (like Photoshop).
        for i in inserts.sorted(by: >) {
            // replace a single trailing space with the break
            if i > 0, (text as NSString).character(at: i - 1) == 32 {
                let r = NSRange(location: i - 1, length: 1)
                text = (text as NSString).replacingCharacters(in: r, with: "\n")
            } else {
                insertText("\n", at: i)
            }
        }
        boxSize = nil
        area = nil
        if alignment.isJustified { alignment = .left }
    }

    /// Type ▸ Convert to Paragraph Text: point text gets a box around its current extent; area type keeps its bounds.
    mutating func convertToParagraphText() {
        guard pathText == nil else { return }
        if area != nil { bakeFit(); area = nil; return }
        guard boxSize == nil, orientation == .horizontal else { return }
        let before = TextRenderer.layout(self)
        let r = before.baseRect
        boxSize = CGSize(width: ceil(r.width) + 4, height: ceil(r.height) + 4)
        // The box is a little wider than the text: centred / right-aligned lines would shift inside it.
        if let a = before.lines.first(where: { !$0.isMarker }), let b = TextRenderer.layout(self).lines.first(where: { !$0.isMarker }) {
            position.x -= (b.bounds.minX - a.bounds.minX) * CGFloat(horizontalScale)
            position.y -= (b.bounds.minY - a.bounds.minY) * CGFloat(verticalScale)
        }
    }

    /// Resizes the text box (and area shape) to `size`, keeping the top-left corner.
    mutating func resizeBox(to size: CGSize) {
        guard let old = boxSize, old.width > 0, old.height > 0 else { boxSize = size; return }
        let sx = size.width / old.width, sy = size.height / old.height
        if var a = area {
            a.path = a.path.applying(CGAffineTransform(scaleX: sx, y: sy))
            area = a
        }
        boxSize = size
    }
}
