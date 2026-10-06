import Foundation
import ImageCratCore

/// One brush tip ready to show: coverage as a gray image (255 = paint) plus a caption.
package struct BrushTipPreview {
    package var name: String
    package var folder: String
    /// Straight RGBA: black paint on transparency (alpha = coverage).
    package var image: RGBA8Image
    package var detail: String
}

/// What a file turned into.
package enum LoadedContent {
    /// A Photoshop document; `composite` is nil when the file has no usable composite (`compositeError` says why).
    case psd(PSDFile, composite: RGBA8Image?, compositeError: String?)
    case image(RGBA8Image, info: String)
    case brushes(ImportedBrushSet, tips: [BrushTipPreview])
}

package struct LoadedFile {
    package var url: URL
    package var fileSize: Int
    package var content: LoadedContent

    package var displayName: String { url.lastPathComponent }

    /// The picture to show on the canvas (composite, PNG, or the brush sheet is built by the caller).
    package var picture: RGBA8Image? {
        switch content {
        case .psd(_, let c, _): return c
        case .image(let i, _): return i
        case .brushes: return nil
        }
    }

    /// Multi-line summary for the info panel / CLI.
    package var summary: String {
        var s = ""
        switch content {
        case .psd(let f, let c, let err):
            s = f.describe(fileName: displayName)
            if c == nil { s += "\nComposite:   not shown (\(err ?? "the file has none"))\n" }
        case .image(let img, let info):
            s = "File:        \(displayName)\nFormat:      \(info)\nSize:        \(img.width) × \(img.height) px\nTransparency: \(img.isOpaque ? "none (opaque)" : "yes")\n"
        case .brushes(let set, let tips):
            s = "File:        \(displayName)\nFormat:      \(set.format.isEmpty ? "brush file" : set.format)\nSet:         \(set.name)\nBrushes:     \(set.brushes.count)\nTips shown:  \(tips.count)\nPatterns:    \(set.patterns.count)\n"
            for k in set.skipped { s += "Skipped:     \(k)\n" }
            s += "\n"
            for t in tips { s += "  \(t.folder.isEmpty ? "" : t.folder + " / ")\(t.name)  (\(t.detail))\n" }
        }
        return s
    }
}

package enum LoadError: LocalizedError {
    case unsupported(String)
    case unreadable(String)
    case tooLarge(Int)

    package var errorDescription: String? {
        switch self {
        case .unsupported(let ext):
            return "ImageCrat Preview can't open \(ext.isEmpty ? "this kind of file" : ".\(ext) files").\n\nSupported: Photoshop documents (.psd, .psb), PNG images (.png) and brush files (.abr, .gbr, .gih, .brush, .brushset, .kpp, .icbrushes)."
        case .unreadable(let why): return why
        case .tooLarge(let n): return "The file is too large for the preview (\(n / 1_048_576) MB; the limit is 4 GB)."
        }
    }
}

package enum FileLoader {
    package static let openExtensions = ["psd", "psb", "png"] + BrushImport.supportedExtensions.filter { $0 != "tpl" }

    /// Reads and decodes `url`. Errors carry a message meant for the user.
    package static func load(_ url: URL) throws -> LoadedFile {
        let ext = url.pathExtension.lowercased()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if size > 4 << 30 { throw LoadError.tooLarge(size) }
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch {
            throw LoadError.unreadable("The file could not be read.\n\n\(error.localizedDescription)")
        }
        return try load(data: data, url: url, ext: ext)
    }

    package static func load(data: Data, url: URL, ext: String) throws -> LoadedFile {
        let content: LoadedContent
        let head = [UInt8](data.prefix(4))
        if ext == "psd" || ext == "psb" || head == Array("8BPS".utf8) {
            let f: PSDFile
            do { f = try PSDFile(data: data) } catch {
                throw LoadError.unreadable("This Photoshop file can't be read: \(error).")
            }
            var comp: RGBA8Image? = nil
            var err: String? = nil
            do { comp = try f.composite(); if comp == nil { err = "the file has no image data section" } } catch {
                err = "the composite can't be decoded: \(error)"
            }
            content = .psd(f, composite: comp, compositeError: err)
        } else if PNGCodec.isPNG(data) && ext != "kpp" {
            guard let img = PNGCodec.decodeImage(data) else { throw LoadError.unreadable("This PNG file is damaged or uses a feature the decoder doesn't support.") }
            let h = PNGCodec.header(data)
            let kinds = [0: "grayscale", 2: "RGB", 3: "indexed", 4: "grayscale + alpha", 6: "RGBA"]
            let info = "PNG, \(h.map { "\($0.bitDepth)-bit \(kinds[$0.colorType] ?? "type \($0.colorType)")\($0.interlaced ? ", interlaced" : "")" } ?? "")"
            content = .image(RGBA8Image(width: img.width, height: img.height, pixels: img.rgba), info: info)
        } else if BrushImport.detect(data: data, fileName: url.lastPathComponent) != nil || BrushImport.supportedExtensions.contains(ext) {
            let set: ImportedBrushSet
            do { set = try BrushImport.load(data: data, fileName: url.lastPathComponent) } catch {
                throw LoadError.unreadable("This brush file can't be read: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
            content = .brushes(set, tips: tipPreviews(set))
        } else {
            throw LoadError.unsupported(ext)
        }
        return LoadedFile(url: url, fileSize: data.count, content: content)
    }

    // MARK: Brush tips

    /// One preview per brush (computed tips are drawn from their settings), in file order.
    package static func tipPreviews(_ set: ImportedBrushSet, maxSide: Int = 256) -> [BrushTipPreview] {
        var out: [BrushTipPreview] = []
        for b in set.brushes.prefix(2000) {
            var img: RGBA8Image? = nil
            var detail = ""
            if let key = b.tipKey, let tip = set.tips[key], let first = tip.frames.first {
                img = coverageImage(first)
                if let i = img { detail = "\(i.width)×\(i.height) px tip" }
                if tip.frames.count > 1 { detail += ", \(tip.frames.count) frames" }
                if img == nil { detail = "tip image not decodable" }
            } else if b.tipKey == nil {
                img = computedTip(b.params)
                detail = "computed round, \(Int(b.params.size)) px, hardness \(Int((b.params.hardness * 100).rounded()))%"
            }
            detail += detail.isEmpty ? "" : ", "
            detail += "spacing \(Int((b.params.spacing * 100).rounded()))%"
            let shown = (img ?? RGBA8Image(width: 1, height: 1)).downscaled(maxSide: maxSide)
            out.append(BrushTipPreview(name: b.name, folder: b.folderPath.joined(separator: " / "), image: shown, detail: detail))
        }
        return out
    }

    /// Gray coverage → black paint with alpha = coverage.
    package static func coverageImage(_ d: BrushImageData) -> RGBA8Image? {
        let buf: PixelBuffer
        switch d {
        case .gray(let b): buf = b.format == .gray ? b : BrushTipImaging.grayCoverage(fromRGBA: b)
        case .encoded(let data):
            guard let decoded = PNGCodec.decodeCoverage(data) else { return nil }
            buf = decoded
        }
        var img = RGBA8Image(width: buf.width, height: buf.height)
        let s = buf.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<buf.height { for x in 0..<buf.width { img.pixels[(y * buf.width + x) * 4 + 3] = s[y * buf.bytesPerRow + x] } }
        return img
    }

    /// A computed (round) tip drawn from its diameter, hardness, roundness and angle.
    package static func computedTip(_ p: BrushParams) -> RGBA8Image {
        let side = max(3, min(256, Int(p.size.rounded())))
        var img = RGBA8Image(width: side, height: side)
        let r = Double(side) / 2
        let hard = max(0, min(1, p.hardness)), round = max(0.05, min(1, p.roundness))
        let a = p.angle * .pi / 180
        for y in 0..<side {
            for x in 0..<side {
                let dx = Double(x) + 0.5 - r, dy = Double(y) + 0.5 - r
                let u = (dx * cos(a) + dy * sin(a)) / r, v = (-dx * sin(a) + dy * cos(a)) / (r * round)
                let d = (u * u + v * v).squareRoot()
                var c = 0.0
                if d <= hard { c = 1 } else if d < 1 { let t = (d - hard) / max(1e-6, 1 - hard); c = 1 - t * t * (3 - 2 * t) }
                img.pixels[(y * side + x) * 4 + 3] = UInt8((c * 255).rounded())
            }
        }
        return img
    }

    // MARK: Brush sheet layout

    package struct SheetCell {
        package var rect: IRect        // whole cell
        package var tipRect: IRect     // where the tip image is drawn
        package var labelRect: IRect   // caption area
        package var index: Int
    }

    /// Grid layout for `count` tips: `cell` px squares plus a caption strip, `columns` per row.
    package static func sheetLayout(count: Int, columns: Int = 6, cell: Int = 132, caption: Int = 40, gap: Int = 12) -> (width: Int, height: Int, cells: [SheetCell]) {
        let cols = max(1, min(columns, count))
        let rows = max(1, (count + cols - 1) / cols)
        let cw = cell, ch = cell + caption
        var cells: [SheetCell] = []
        for i in 0..<count {
            let cx = gap + (i % cols) * (cw + gap), cy = gap + (i / cols) * (ch + gap)
            cells.append(SheetCell(rect: IRect(x: cx, y: cy, width: cw, height: ch),
                                   tipRect: IRect(x: cx + 6, y: cy + 6, width: cw - 12, height: cell - 12),
                                   labelRect: IRect(x: cx + 2, y: cy + cell, width: cw - 4, height: caption), index: i))
        }
        return (gap + cols * (cw + gap), gap + rows * (ch + gap), cells)
    }

    /// The brush sheet as an image: white cards with each tip drawn (black) fitted into its cell. Captions are drawn
    /// by the caller (they need a font).
    package static func brushSheet(_ tips: [BrushTipPreview], columns: Int = 6) -> (image: RGBA8Image, cells: [SheetCell]) {
        let layout = sheetLayout(count: tips.count, columns: columns)
        var img = RGBA8Image(width: layout.width, height: layout.height)
        // background (light gray) and white cards
        for i in 0..<(layout.width * layout.height) { img.pixels[i * 4] = 236; img.pixels[i * 4 + 1] = 236; img.pixels[i * 4 + 2] = 240; img.pixels[i * 4 + 3] = 255 }
        for c in layout.cells {
            for y in c.rect.y..<(c.rect.y + c.rect.height) { for x in c.rect.x..<(c.rect.x + c.rect.width) {
                let i = (y * layout.width + x) * 4
                img.pixels[i] = 255; img.pixels[i + 1] = 255; img.pixels[i + 2] = 255
            } }
            let tip = tips[c.index].image
            guard tip.width > 0, tip.height > 0 else { continue }
            let s = min(Double(c.tipRect.width) / Double(tip.width), Double(c.tipRect.height) / Double(tip.height), 1.0)
            let tw = max(1, Int(Double(tip.width) * s)), th = max(1, Int(Double(tip.height) * s))
            let fitted = s < 1 ? tip.resampled(width: tw, height: th, placing: IRect(x: 0, y: 0, width: tip.width, height: tip.height), canvasWidth: tip.width, canvasHeight: tip.height) : tip
            let ox = c.tipRect.x + (c.tipRect.width - fitted.width) / 2, oy = c.tipRect.y + (c.tipRect.height - fitted.height) / 2
            for y in 0..<fitted.height { for x in 0..<fitted.width {
                let a = Int(fitted.pixels[(y * fitted.width + x) * 4 + 3])
                guard a > 0 else { continue }
                let i = ((oy + y) * layout.width + ox + x) * 4
                for k in 0..<3 { img.pixels[i + k] = UInt8(Int(img.pixels[i + k]) * (255 - a) / 255) }
            } }
        }
        return (img, layout.cells)
    }
}
