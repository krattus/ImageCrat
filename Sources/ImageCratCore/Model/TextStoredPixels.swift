import Foundation

/// Photoshop's own rendering of an imported type layer whose font is not installed. Like Photoshop, the layer keeps
/// showing these pixels (moved and transformed with it) until its text or styling is edited; from then on it is drawn
/// with the substitute font. The pixels are only valid for the exact type settings they were captured with.
package struct TextStoredPixels: Codable {
    package var buffer: PixelBuffer
    /// Document position of the buffer while the layer has `transform`.
    package var origin: IPoint
    /// `TextContent.transform` at capture time: later moves / transforms map the pixels along.
    package var transform: CGAffineTransform
    /// The layer's type settings at capture time (JSON of `TextContent.appearanceKey`).
    package var content: Data
    package init(buffer: PixelBuffer, origin: IPoint, transform: CGAffineTransform, content: Data) {
        self.buffer = buffer; self.origin = origin; self.transform = transform; self.content = content
    }
}

extension TextStoredPixels: Equatable {
    package static func == (a: TextStoredPixels, b: TextStoredPixels) -> Bool {
        a.buffer === b.buffer && a.origin == b.origin && a.transform == b.transform && a.content == b.content
    }
}

extension TextContent {
    /// What the stored pixels depend on: everything except where the layer sits and the import bookkeeping.
    package var appearanceKey: TextContent {
        var k = self
        k.transform = .identity; k.storedPixels = nil; k.missingFonts = []
        return k
    }

    /// The layer showing `buffer` (at document `origin`) until it is edited.
    package func capturingStoredPixels(_ buffer: PixelBuffer, origin: IPoint) -> TextContent {
        var t = self
        guard let data = try? JSONEncoder().encode(appearanceKey) else { return t }
        t.storedPixels = TextStoredPixels(buffer: buffer, origin: origin, transform: transform, content: data)
        return t
    }

    /// True while the stored pixels still show this layer: only its placement changed since they were captured.
    package var showsStoredPixels: Bool {
        guard let p = storedPixels else { return false }
        return StoredPixelsCheck.reference(p).map { $0 == appearanceKey } ?? false
    }

    /// Maps the stored pixels from where they were captured to where the layer is now.
    package var storedPixelsTransform: CGAffineTransform? { storedPixels.map { $0.transform.inverted().concatenating(transform) } }

    /// Document bounds of the stored pixels as currently placed.
    package var storedPixelsBounds: CGRect? {
        guard let p = storedPixels, let m = storedPixelsTransform else { return nil }
        return CGRect(x: p.origin.x, y: p.origin.y, width: p.buffer.width, height: p.buffer.height).applying(m)
    }

    /// Tooltip / report wording for a type layer whose font is missing.
    package var missingFontNote: String? {
        guard !missingFonts.isEmpty else { return nil }
        let names = missingFonts.map { "“\($0)”" }.joined(separator: ", ")
        return showsStoredPixels
            ? "Missing font \(names): showing the pixels Photoshop rendered until the text is edited (then \(fontName) is used)."
            : "Missing font \(names): drawn with \(fontName)."
    }
}

extension DocumentState {
    /// Drops stored pixels that no longer show their layer (its text was edited), before saving.
    package func droppingStaleTextPixels() -> DocumentState {
        var st = self
        func clean(_ ls: inout [Layer]) {
            for i in ls.indices {
                if case .text(var t) = ls[i].content, t.storedPixels != nil, !t.showsStoredPixels { t.storedPixels = nil; ls[i].content = .text(t) }
                if ls[i].isGroup { var c = ls[i].children; clean(&c); ls[i].children = c }
            }
        }
        clean(&st.layers)
        return st
    }
}

/// Decoded capture-time settings, cached by stored-pixel buffer (decoding JSON on every check would be slow). The
/// buffer is held weakly so closed documents release their pixels.
package enum StoredPixelsCheck {
    private final class Entry { weak var buffer: PixelBuffer?; let data: Data; let content: TextContent
        package init(_ b: PixelBuffer, _ d: Data, _ c: TextContent) { buffer = b; data = d; content = c } }
    private static let lock = NSLock()
    private static var cache: [ObjectIdentifier: Entry] = [:]

    package static func reference(_ p: TextStoredPixels) -> TextContent? {
        let key = ObjectIdentifier(p.buffer)
        lock.lock()
        if let c = cache[key], c.buffer === p.buffer, c.data == p.content { lock.unlock(); return c.content }
        lock.unlock()
        guard let t = try? JSONDecoder().decode(TextContent.self, from: p.content) else { return nil }
        let key2 = t.appearanceKey
        lock.lock()
        if cache.count > 64 { cache = cache.filter { $0.value.buffer != nil } }
        cache[key] = Entry(p.buffer, p.content, key2)
        lock.unlock()
        return key2
    }
}
