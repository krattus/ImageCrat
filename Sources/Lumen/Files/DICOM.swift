import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

// MARK: - Model

/// Decoded DICOM image: modality values (rescale applied) for grayscale, 8-bit RGB for colour.
struct DICOMImage {
    var rows = 0
    var columns = 0
    var frames = 1
    var samplesPerPixel = 1
    var bitsAllocated = 8
    var bitsStored = 8
    var pixelRepresentation = 0      // 0 unsigned, 1 signed
    var planarConfiguration = 0
    var photometric = "MONOCHROME2"
    var windowCenter: Double?
    var windowWidth: Double?
    var rescaleSlope = 1.0
    var rescaleIntercept = 0.0
    var transferSyntax = DICOM.explicitLE
    /// Grayscale frames: rows*columns modality values each.
    var grayFrames: [[Float]] = []
    /// Colour frames: interleaved RGB bytes.
    var rgbFrames: [[UInt8]] = []
    /// Descriptive attributes (Patient Name, Modality, …) for display.
    var attributes: [(String, String)] = []

    var isColor: Bool { samplesPerPixel >= 3 }
    var isInverted: Bool { photometric == "MONOCHROME1" }

    /// Min / max modality value over all frames.
    var valueRange: (Float, Float) {
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for f in grayFrames { for v in f { if v < lo { lo = v }; if v > hi { hi = v } } }
        return lo <= hi ? (lo, hi) : (0, 255)
    }

    /// Default window: from the file, else the full value range.
    var defaultWindow: (center: Double, width: Double) {
        if let c = windowCenter, let w = windowWidth, w > 0 { return (c, w) }
        let (lo, hi) = valueRange
        return (Double(lo + hi) / 2, max(1, Double(hi - lo)))
    }
}

enum DICOMError: LocalizedError {
    case notDICOM, unsupported(String), truncated
    var errorDescription: String? {
        switch self {
        case .notDICOM: return "The file is not a DICOM file."
        case .unsupported(let s): return "Unsupported DICOM encoding: \(s)."
        case .truncated: return "The DICOM file is truncated."
        }
    }
}

enum DICOM {
    static let implicitLE = "1.2.840.10008.1.2"
    static let explicitLE = "1.2.840.10008.1.2.1"
    static let explicitBE = "1.2.840.10008.1.2.2"
    static let jpegBaseline = "1.2.840.10008.1.2.4.50"
    static let jpegExtended = "1.2.840.10008.1.2.4.51"
    static let rleLossless = "1.2.840.10008.1.2.5"
    static let secondaryCapture = "1.2.840.10008.5.1.4.1.1.7"
    static let multiframeSC = "1.2.840.10008.5.1.4.1.1.7.2"

    /// VRs with a 2-byte reserved field and a 4-byte length in explicit VR.
    static let longVRs: Set<String> = ["OB", "OW", "OF", "SQ", "UT", "UN", "OD", "OL", "OV", "UC", "UR", "SV", "UV"]

    /// VR dictionary for implicit VR (tags this reader interprets).
    static let implicitVR: [UInt32: String] = [
        0x0002_0010: "UI", 0x0008_0016: "UI", 0x0008_0018: "UI", 0x0008_0060: "CS", 0x0008_0020: "DA", 0x0008_1030: "LO",
        0x0010_0010: "PN", 0x0010_0020: "LO", 0x0018_0015: "CS",
        0x0028_0002: "US", 0x0028_0004: "CS", 0x0028_0006: "US", 0x0028_0008: "IS", 0x0028_0010: "US", 0x0028_0011: "US",
        0x0028_0100: "US", 0x0028_0101: "US", 0x0028_0102: "US", 0x0028_0103: "US",
        0x0028_1050: "DS", 0x0028_1051: "DS", 0x0028_1052: "DS", 0x0028_1053: "DS", 0x7FE0_0010: "OW",
    ]
    static let attributeNames: [UInt32: String] = [
        0x0010_0010: "Patient Name", 0x0010_0020: "Patient ID", 0x0008_0060: "Modality", 0x0008_0020: "Study Date",
        0x0008_1030: "Study Description", 0x0018_0015: "Body Part",
    ]

    static func isDICOM(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 132), d.count == 132 else { return false }
        return d[128] == 0x44 && d[129] == 0x49 && d[130] == 0x43 && d[131] == 0x4D
    }

    // MARK: Parser

    private struct Reader {
        let b: [UInt8]
        var pos = 0
        var explicit = true
        var bigEndian = false
        var remaining: Int { b.count - pos }
        mutating func u16() throws -> UInt16 {
            guard pos + 2 <= b.count else { throw DICOMError.truncated }
            defer { pos += 2 }
            return bigEndian ? UInt16(b[pos]) << 8 | UInt16(b[pos + 1]) : UInt16(b[pos]) | UInt16(b[pos + 1]) << 8
        }
        mutating func u32() throws -> UInt32 {
            let a = UInt32(try u16()), c = UInt32(try u16())
            return bigEndian ? a << 16 | c : a | c << 16
        }
        mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, pos + n <= b.count else { throw DICOMError.truncated }
            defer { pos += n }
            return b[pos..<(pos + n)]
        }
        mutating func vr() throws -> String { String(decoding: try bytes(2), as: UTF8.self) }
    }

    private struct Element { var tag: UInt32; var vr: String; var length: UInt32; var valueStart: Int }

    private static func readHeader(_ r: inout Reader) throws -> Element {
        let g = UInt32(try r.u16()), e = UInt32(try r.u16())
        let tag = g << 16 | e
        if g == 0xFFFE {   // item / delimiters have no VR
            let len = try r.u32()
            return Element(tag: tag, vr: "", length: len, valueStart: r.pos)
        }
        // meta group is always explicit little endian
        if r.explicit || g == 0x0002 {
            let vr = try r.vr()
            if longVRs.contains(vr) {
                _ = try r.u16()
                return Element(tag: tag, vr: vr, length: try r.u32(), valueStart: r.pos)
            }
            return Element(tag: tag, vr: vr, length: UInt32(try r.u16()), valueStart: r.pos)
        }
        return Element(tag: tag, vr: implicitVR[tag] ?? "UN", length: try r.u32(), valueStart: r.pos)
    }

    /// Skips an undefined-length sequence / item list up to its delimiter.
    private static func skipUndefined(_ r: inout Reader) throws {
        while r.remaining >= 8 {
            let el = try readHeader(&r)
            if el.tag == 0xFFFE_E0DD || el.tag == 0xFFFE_E00D { return }
            if el.length == 0xFFFF_FFFF { try skipUndefined(&r) } else { _ = try r.bytes(Int(el.length)) }
        }
    }

    private static func string(_ s: ArraySlice<UInt8>) -> String {
        String(decoding: s, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
    }
    private static func number(_ s: ArraySlice<UInt8>) -> Double? {
        Double(string(s).split(separator: "\\").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    static func read(url: URL) throws -> DICOMImage { try read(data: Data(contentsOf: url)) }

    static func read(data: Data) throws -> DICOMImage {
        var r = Reader(b: [UInt8](data))
        var img = DICOMImage()
        if r.b.count >= 132, r.b[128] == 0x44, r.b[129] == 0x49, r.b[130] == 0x43, r.b[131] == 0x4D {
            r.pos = 132
        } else {
            // raw dataset without preamble: guess explicit vs implicit from the first element
            guard r.b.count >= 8 else { throw DICOMError.notDICOM }
            let a = r.b[4], c = r.b[5]
            r.explicit = (65...90).contains(a) && (65...90).contains(c)
            img.transferSyntax = r.explicit ? explicitLE : implicitLE
        }
        var pixelData: ArraySlice<UInt8>? = nil
        var fragments: [ArraySlice<UInt8>] = []
        var switched = false
        while r.remaining >= 8 {
            // after the meta group, switch to the dataset transfer syntax
            if !switched, r.pos + 2 <= r.b.count, (UInt16(r.b[r.pos]) | UInt16(r.b[r.pos + 1]) << 8) != 0x0002 {
                switched = true
                let ts = img.transferSyntax
                r.explicit = ts != implicitLE
                r.bigEndian = ts == explicitBE
            }
            let el = try readHeader(&r)
            if el.tag == 0x7FE0_0010 {
                if el.length == 0xFFFF_FFFF {
                    // encapsulated: items until sequence delimiter; the first item is the offset table
                    var first = true
                    while r.remaining >= 8 {
                        let it = try readHeader(&r)
                        if it.tag == 0xFFFE_E0DD { break }
                        let body = try r.bytes(Int(it.length))
                        if first { first = false; continue }
                        fragments.append(body)
                    }
                } else {
                    pixelData = try r.bytes(min(Int(el.length), r.remaining))
                }
                break
            }
            if el.length == 0xFFFF_FFFF { try skipUndefined(&r); continue }
            let v = try r.bytes(min(Int(el.length), r.remaining))
            func us() -> Int {
                guard v.count >= 2 else { return 0 }
                let i = v.startIndex
                return r.bigEndian ? Int(v[i]) << 8 | Int(v[i + 1]) : Int(v[i]) | Int(v[i + 1]) << 8
            }
            switch el.tag {
            case 0x0002_0010: img.transferSyntax = string(v)
            case 0x0028_0002: img.samplesPerPixel = max(1, us())
            case 0x0028_0004: img.photometric = string(v).uppercased()
            case 0x0028_0006: img.planarConfiguration = us()
            case 0x0028_0008: img.frames = max(1, Int(number(v) ?? 1))
            case 0x0028_0010: img.rows = us()
            case 0x0028_0011: img.columns = us()
            case 0x0028_0100: img.bitsAllocated = us()
            case 0x0028_0101: img.bitsStored = us()
            case 0x0028_0103: img.pixelRepresentation = us()
            case 0x0028_1050: img.windowCenter = number(v)
            case 0x0028_1051: img.windowWidth = number(v)
            case 0x0028_1052: img.rescaleIntercept = number(v) ?? 0
            case 0x0028_1053: img.rescaleSlope = number(v) ?? 1
            default:
                if let n = attributeNames[el.tag] {
                    img.attributes.append((n, string(v).replacingOccurrences(of: "^", with: " ")))
                }
            }
        }
        guard img.rows > 0, img.columns > 0 else { throw DICOMError.notDICOM }
        if img.rescaleSlope == 0 { img.rescaleSlope = 1 }
        if !fragments.isEmpty {
            try decodeEncapsulated(fragments, into: &img)
        } else if let px = pixelData {
            try decodeNative(px, into: &img, bigEndian: r.bigEndian)
        } else {
            throw DICOMError.unsupported("no pixel data")
        }
        return img
    }

    private static func decodeNative(_ px: ArraySlice<UInt8>, into img: inout DICOMImage, bigEndian: Bool) throws {
        let n = img.rows * img.columns
        let spp = img.samplesPerPixel
        let bpp = max(1, img.bitsAllocated / 8)
        let frameBytes = n * spp * bpp
        guard frameBytes > 0 else { throw DICOMError.unsupported("bits allocated \(img.bitsAllocated)") }
        let frames = min(img.frames, px.count / frameBytes)
        guard frames > 0 else { throw DICOMError.truncated }
        img.frames = frames
        let base = px.startIndex
        if spp >= 3 {
            guard img.bitsAllocated == 8 else { throw DICOMError.unsupported("\(img.bitsAllocated)-bit colour") }
            let isYBR = img.photometric.hasPrefix("YBR")
            for f in 0..<frames {
                var out = [UInt8](repeating: 0, count: n * 3)
                let o = base + f * frameBytes
                for i in 0..<n {
                    var c0, c1, c2: UInt8
                    if img.planarConfiguration == 1 {
                        c0 = px[o + i]; c1 = px[o + n + i]; c2 = px[o + 2 * n + i]
                    } else {
                        c0 = px[o + i * spp]; c1 = px[o + i * spp + 1]; c2 = px[o + i * spp + 2]
                    }
                    if isYBR {
                        let y = Double(c0), cb = Double(c1) - 128, cr = Double(c2) - 128
                        c0 = UInt8(clamp(y + 1.402 * cr, 0, 255)); c1 = UInt8(clamp(y - 0.344136 * cb - 0.714136 * cr, 0, 255)); c2 = UInt8(clamp(y + 1.772 * cb, 0, 255))
                    }
                    out[i * 3] = c0; out[i * 3 + 1] = c1; out[i * 3 + 2] = c2
                }
                img.rgbFrames.append(out)
            }
            img.samplesPerPixel = 3
            return
        }
        let slope = Float(img.rescaleSlope), icpt = Float(img.rescaleIntercept)
        let stored = img.bitsStored > 0 ? min(img.bitsStored, img.bitsAllocated) : img.bitsAllocated
        let signed = img.pixelRepresentation == 1
        for f in 0..<frames {
            var out = [Float](repeating: 0, count: n)
            let o = base + f * frameBytes
            switch img.bitsAllocated {
            case 8:
                for i in 0..<n {
                    var v = Int(px[o + i])
                    if signed && stored == 8 { v = Int(Int8(bitPattern: UInt8(v))) }
                    out[i] = Float(v) * slope + icpt
                }
            case 16:
                let mask = stored >= 16 ? 0xFFFF : (1 << stored) - 1
                for i in 0..<n {
                    let a = Int(px[o + 2 * i]), b = Int(px[o + 2 * i + 1])
                    var v = (bigEndian ? a << 8 | b : a | b << 8) & mask
                    if signed && v & (1 << (stored - 1)) != 0 { v -= 1 << stored }
                    out[i] = Float(v) * slope + icpt
                }
            case 32:
                for i in 0..<n {
                    let j = o + 4 * i
                    var u = UInt32(px[j]) | UInt32(px[j + 1]) << 8 | UInt32(px[j + 2]) << 16 | UInt32(px[j + 3]) << 24
                    if bigEndian { u = u.byteSwapped }
                    out[i] = (signed ? Float(Int32(bitPattern: u)) : Float(u)) * slope + icpt
                }
            default:
                throw DICOMError.unsupported("\(img.bitsAllocated) bits allocated")
            }
            img.grayFrames.append(out)
        }
    }

    /// JPEG (baseline / extended) fragments decoded through ImageIO: one fragment per frame when the counts
    /// match, otherwise all fragments form one frame.
    private static func decodeEncapsulated(_ frags: [ArraySlice<UInt8>], into img: inout DICOMImage) throws {
        var streams: [Data] = []
        if frags.count == img.frames || img.frames <= 1 && frags.count == 1 {
            streams = frags.map { Data($0) }
        } else {
            streams = [frags.reduce(into: Data()) { $0.append(contentsOf: $1) }]
        }
        let n = img.rows * img.columns
        img.grayFrames = []; img.rgbFrames = []
        for s in streams {
            guard let src = CGImageSourceCreateWithData(s as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw DICOMError.unsupported("compressed transfer syntax \(img.transferSyntax)")
            }
            let color = img.samplesPerPixel >= 3
            let buf = PixelBuffer(width: img.columns, height: img.rows)
            buf.context.draw(cg, in: CGRect(x: 0, y: 0, width: img.columns, height: img.rows))
            let p = buf.data.assumingMemoryBound(to: UInt8.self)
            if color {
                var out = [UInt8](repeating: 0, count: n * 3)
                for y in 0..<img.rows { for x in 0..<img.columns {
                    let q = y * buf.bytesPerRow + x * 4, i = (y * img.columns + x) * 3
                    out[i] = p[q]; out[i + 1] = p[q + 1]; out[i + 2] = p[q + 2]
                } }
                img.rgbFrames.append(out)
            } else {
                var out = [Float](repeating: 0, count: n)
                let slope = Float(img.rescaleSlope), icpt = Float(img.rescaleIntercept)
                for y in 0..<img.rows { for x in 0..<img.columns {
                    out[y * img.columns + x] = Float(p[y * buf.bytesPerRow + x * 4]) * slope + icpt
                } }
                img.grayFrames.append(out)
            }
        }
        img.frames = max(img.grayFrames.count, img.rgbFrames.count)
        if img.samplesPerPixel >= 3 { img.samplesPerPixel = 3; img.photometric = "RGB" }
        img.bitsAllocated = 8; img.bitsStored = 8
    }

    // MARK: Rendering

    /// Renders frame `f` with a window (DICOM linear VOI function) into an RGBA buffer.
    static func render(_ img: DICOMImage, frame f: Int, center: Double, width: Double) -> PixelBuffer {
        let W = img.columns, H = img.rows
        let buf = PixelBuffer(width: W, height: H)
        let p = buf.data.assumingMemoryBound(to: UInt8.self)
        if img.isColor {
            let src = img.rgbFrames[min(f, img.rgbFrames.count - 1)]
            for y in 0..<H { for x in 0..<W {
                let i = (y * W + x) * 3, q = y * buf.bytesPerRow + x * 4
                p[q] = src[i]; p[q + 1] = src[i + 1]; p[q + 2] = src[i + 2]; p[q + 3] = 255
            } }
        } else {
            let src = img.grayFrames[min(f, img.grayFrames.count - 1)]
            let lut = windowFunction(center: center, width: width, inverted: img.isInverted)
            for y in 0..<H { for x in 0..<W {
                let g = lut(src[y * W + x])
                let q = y * buf.bytesPerRow + x * 4
                p[q] = g; p[q + 1] = g; p[q + 2] = g; p[q + 3] = 255
            } }
        }
        buf.markDirty()
        return buf
    }

    /// DICOM PS3.3 C.11.2.1.2 linear window.
    static func windowFunction(center c: Double, width w0: Double, inverted: Bool) -> (Float) -> UInt8 {
        let w = max(1, w0)
        let lo = Float(c - 0.5 - (w - 1) / 2), hi = Float(c - 0.5 + (w - 1) / 2)
        let cc = Float(c - 0.5), ww = Float(w - 1)
        return { x in
            var v: Float
            if x <= lo { v = 0 } else if x > hi { v = 255 } else { v = ((x - cc) / max(ww, 1e-6) + 0.5) * 255 }
            v = min(255, max(0, v))
            return UInt8((inverted ? 255 - v : v).rounded())
        }
    }

    // MARK: Documents

    /// Opens a DICOM file: one layer per frame (bottom = frame 1); multi-frame files also get a frame animation.
    static func makeDocument(_ img: DICOMImage, name: String, animate: Bool = true) -> Document {
        var st = DocumentState(width: img.columns, height: img.rows, resolution: 72)
        st.colorMode = img.isColor ? .rgb : .grayscale
        let (c, w) = img.defaultWindow
        var ids: [UUID] = []
        for f in 0..<img.frames {
            var l = Layer.raster(name: img.frames == 1 ? "Background" : "Frame \(f + 1)", buffer: render(img, frame: f, center: c, width: w))
            l.isVisible = !animate || img.frames == 1 || f == 0
            ids.append(l.id)
            st.layers.append(l)
        }
        if animate && img.frames > 1 {
            var frames: [AnimationFrame] = []
            for i in 0..<img.frames {
                var fr = Animation.capture(st)
                fr.delay = 0.1
                for (j, id) in ids.enumerated() { fr.visibility[id] = (i == j) }
                frames.append(fr)
            }
            st.frames = frames
        }
        let d = Document(state: st, name: name)
        DICOMStore.shared.entries[d.id] = DICOMStore.Entry(image: img, layerIDs: ids, center: c, width: w)
        return d
    }

    static func load(url: URL) throws -> Document {
        let img = try read(url: url)
        var animate = true
        if img.frames > 1 && !FilesModule.headless {
            let a = NSAlert()
            a.messageText = "Open Multi-Frame DICOM"
            a.informativeText = "“\(url.lastPathComponent)” has \(img.frames) frames. Each frame becomes a layer."
            a.addButton(withTitle: "Frame Animation")
            a.addButton(withTitle: "Layers Only")
            animate = UIBlock.run(a) == .alertFirstButtonReturn
        }
        let d = makeDocument(img, name: url.lastPathComponent, animate: animate)
        if animate && img.frames > 1 { TimelineController.shared.selection[d.id] = 0 }
        d.fileURL = url
        return d
    }

    /// Re-renders every frame layer of a DICOM document with a new window (uncommitted).
    static func applyWindow(_ d: Document, center: Double, width: Double) {
        guard var e = DICOMStore.shared.entries[d.id] else { return }
        e.center = center; e.width = width
        DICOMStore.shared.entries[d.id] = e
        for (f, id) in e.layerIDs.enumerated() where d.state.layer(id) != nil {
            let buf = render(e.image, frame: f, center: center, width: width)
            d.updateLayer(id) { l in
                if var r = l.raster, r.buffer.width == buf.width, r.buffer.height == buf.height { r.buffer = buf; l.raster = r }
            }
        }
    }

    // MARK: Writer

    /// Minimal DICOM dataset builder (little endian, explicit or implicit VR).
    struct DataSetWriter {
        var explicit = true
        private(set) var data = Data()

        private mutating func u16(_ v: UInt16) { data.append(UInt8(v & 0xff)); data.append(UInt8(v >> 8)) }
        private mutating func u32(_ v: UInt32) { u16(UInt16(v & 0xffff)); u16(UInt16(v >> 16)) }

        mutating func element(_ tag: UInt32, _ vr: String, _ value: Data, forceExplicit: Bool = false) {
            var v = value
            if v.count % 2 == 1 { v.append(vr == "UI" || vr == "OB" ? 0 : 0x20) }
            u16(UInt16(tag >> 16)); u16(UInt16(tag & 0xffff))
            if explicit || forceExplicit {
                data.append(contentsOf: Array(vr.utf8))
                if DICOM.longVRs.contains(vr) { u16(0); u32(UInt32(v.count)) } else { u16(UInt16(v.count)) }
            } else {
                u32(UInt32(v.count))
            }
            data.append(v)
        }
        mutating func string(_ tag: UInt32, _ vr: String, _ s: String, forceExplicit: Bool = false) { element(tag, vr, Data(s.utf8), forceExplicit: forceExplicit) }
        mutating func us(_ tag: UInt32, _ v: Int) { var d = Data(); d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff)); element(tag, "US", d) }
        mutating func ul(_ tag: UInt32, _ v: UInt32, forceExplicit: Bool = false) {
            var d = Data(); for s in [0, 8, 16, 24] { d.append(UInt8((v >> UInt32(s)) & 0xff)) }
            element(tag, "UL", d, forceExplicit: forceExplicit)
        }
        /// Encapsulated pixel data (undefined length, empty offset table, one fragment per frame).
        mutating func encapsulatedPixels(_ fragments: [Data]) {
            u16(0x7FE0); u16(0x0010)
            if explicit { data.append(contentsOf: Array("OB".utf8)); u16(0) }
            u32(0xFFFF_FFFF)
            u16(0xFFFE); u16(0xE000); u32(0)
            for f in fragments {
                var b = f; if b.count % 2 == 1 { b.append(0) }
                u16(0xFFFE); u16(0xE000); u32(UInt32(b.count)); data.append(b)
            }
            u16(0xFFFE); u16(0xE0DD); u32(0)
        }
        mutating func raw(_ d: Data) { data.append(d) }
    }

    static func newUID() -> String {
        // 2.25.<128-bit UUID as decimal>, computed from the UUID bytes
        let u = UUID().uuid
        let bytes = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        var digits = [UInt8](repeating: 0, count: 40)   // base-10 big number
        for b in bytes {
            var carry = Int(b)
            for i in stride(from: digits.count - 1, through: 0, by: -1) {
                let v = Int(digits[i]) * 256 + carry
                digits[i] = UInt8(v % 10); carry = v / 10
            }
        }
        let s = digits.map(String.init).joined().drop { $0 == "0" }
        return "2.25." + (s.isEmpty ? "0" : String(s))
    }

    /// File preamble + meta information group for a dataset with `ts` transfer syntax.
    static func metaHeader(sopClass: String, sopInstance: String, transferSyntax ts: String) -> Data {
        var meta = DataSetWriter(explicit: true)
        meta.element(0x0002_0001, "OB", Data([0, 1]))
        meta.string(0x0002_0002, "UI", sopClass)
        meta.string(0x0002_0003, "UI", sopInstance)
        meta.string(0x0002_0010, "UI", ts)
        meta.string(0x0002_0012, "UI", "1.2.826.0.1.3680043.10.1418.1")
        meta.string(0x0002_0013, "SH", "IMAGECRAT_1")
        var head = Data(count: 128)
        head.append(contentsOf: Array("DICM".utf8))
        var g = DataSetWriter(explicit: true)
        g.ul(0x0002_0000, UInt32(meta.data.count))
        head.append(g.data)
        head.append(meta.data)
        return head
    }

    struct WriteSpec {
        var rows: Int
        var columns: Int
        var samples = 1                    // 1 gray, 3 RGB
        var bitsAllocated = 8
        var signed = false
        var photometric = "MONOCHROME2"
        var frames: [Data]                 // native little-endian frame bytes
        var windowCenter: Double? = nil
        var windowWidth: Double? = nil
        var rescaleSlope: Double? = nil
        var rescaleIntercept: Double? = nil
        var transferSyntax = DICOM.explicitLE
        var jpegFragments: [Data]? = nil   // encapsulated JPEG instead of `frames`
        var patientName = "Anonymous"
        var modality = "OT"
    }

    /// Writes a DICOM Part 10 file.
    static func write(_ s: WriteSpec, to url: URL) throws {
        let sop = s.frames.count > 1 || (s.jpegFragments?.count ?? 0) > 1 ? multiframeSC : secondaryCapture
        let inst = newUID()
        var out = metaHeader(sopClass: sop, sopInstance: inst, transferSyntax: s.transferSyntax)
        var ds = DataSetWriter(explicit: s.transferSyntax != implicitLE)
        func fmt(_ v: Double) -> String { String(format: "%g", v) }
        ds.string(0x0008_0016, "UI", sop)
        ds.string(0x0008_0018, "UI", inst)
        ds.string(0x0008_0060, "CS", s.modality)
        ds.string(0x0008_0064, "CS", "WSD")
        ds.string(0x0010_0010, "PN", s.patientName)
        ds.string(0x0010_0020, "LO", "IMAGECRAT")
        ds.string(0x0020_000D, "UI", newUID())
        ds.string(0x0020_000E, "UI", newUID())
        ds.us(0x0028_0002, s.samples)
        ds.string(0x0028_0004, "CS", s.photometric)
        if s.samples > 1 { ds.us(0x0028_0006, 0) }
        let nFrames = s.jpegFragments?.count ?? s.frames.count
        if nFrames > 1 { ds.string(0x0028_0008, "IS", "\(nFrames)") }
        ds.us(0x0028_0010, s.rows)
        ds.us(0x0028_0011, s.columns)
        ds.us(0x0028_0100, s.bitsAllocated)
        ds.us(0x0028_0101, s.bitsAllocated)
        ds.us(0x0028_0102, s.bitsAllocated - 1)
        ds.us(0x0028_0103, s.signed ? 1 : 0)
        if let c = s.windowCenter { ds.string(0x0028_1050, "DS", fmt(c)) }
        if let w = s.windowWidth { ds.string(0x0028_1051, "DS", fmt(w)) }
        if let i = s.rescaleIntercept { ds.string(0x0028_1052, "DS", fmt(i)) }
        if let m = s.rescaleSlope { ds.string(0x0028_1053, "DS", fmt(m)) }
        if let frags = s.jpegFragments {
            ds.encapsulatedPixels(frags)
        } else {
            var px = Data()
            for f in s.frames { px.append(f) }
            ds.element(0x7FE0_0010, s.bitsAllocated > 8 ? "OW" : "OB", px)
        }
        out.append(ds.data)
        try out.write(to: url, options: .atomic)
    }

    /// File > Export > DICOM: 8-bit MONOCHROME2 (grayscale documents) or RGB; frame animations become multi-frame.
    static func export(_ st: DocumentState, to url: URL) throws {
        let images: [CGImage] = st.frames.isEmpty ? [Compositor.shared.flatten(st, background: .black)].compactMap { $0 }
            : Animation.renderFrames(st, background: .black).map(\.image)
        guard let first = images.first else { throw DocumentIOError.encodeFailed }
        let gray = st.colorMode == .grayscale
        let W = first.width, H = first.height
        var frames: [Data] = []
        for cg in images {
            let buf = PixelBuffer(width: W, height: H)
            buf.context.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
            let p = buf.data.assumingMemoryBound(to: UInt8.self)
            var d = Data(capacity: W * H * (gray ? 1 : 3))
            for y in 0..<H { for x in 0..<W {
                let q = y * buf.bytesPerRow + x * 4
                if gray {
                    let r = Double(p[q]), g = Double(p[q + 1]), b = Double(p[q + 2])
                    let lum: Double = r * 0.299 + g * 0.587 + b * 0.114
                    d.append(UInt8(min(255.0, lum.rounded())))
                } else { d.append(p[q]); d.append(p[q + 1]); d.append(p[q + 2]) }
            } }
            frames.append(d)
        }
        try write(WriteSpec(rows: H, columns: W, samples: gray ? 1 : 3, photometric: gray ? "MONOCHROME2" : "RGB", frames: frames), to: url)
    }

    static func exportPanel() {
        guard let d = AppActions.doc else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: "dcm") ?? .data]
        p.nameFieldStringValue = (d.name as NSString).deletingPathExtension + ".dcm"
        guard UIBlock.run(p) == .OK, let url = p.url else { return }
        do { try export(d.state, to: url); AppModel.shared.setStatus("Exported \(url.lastPathComponent)") }
        catch { AppActions.alert("Could not export DICOM.", error.localizedDescription) }
    }
}

/// Source data of open DICOM documents (for Window/Level); not saved with the document.
final class DICOMStore {
    static let shared = DICOMStore()
    struct Entry { var image: DICOMImage; var layerIDs: [UUID]; var center: Double; var width: Double }
    var entries: [UUID: Entry] = [:]
}

// MARK: - Window / Level dialog

struct DICOMWindowLevelDialog: View {
    let doc: Document
    let entry: DICOMStore.Entry
    @State private var center: Double
    @State private var width: Double
    private let lo: Double, hi: Double

    init(doc: Document, entry: DICOMStore.Entry) {
        self.doc = doc
        self.entry = entry
        _center = State(initialValue: entry.center)
        _width = State(initialValue: entry.width)
        let r = entry.image.valueRange
        lo = Double(r.0); hi = Double(max(r.1, r.0 + 1))
    }

    private var presets: [(String, Double, Double)] {
        var p: [(String, Double, Double)] = []
        if let c = entry.image.windowCenter, let w = entry.image.windowWidth { p.append(("From File", c, w)) }
        p.append(("Full Range", (lo + hi) / 2, hi - lo))
        if lo < -500 {   // looks like CT Hounsfield units
            p += [("CT Brain", 40, 80), ("CT Abdomen", 40, 400), ("CT Lung", -600, 1500), ("CT Bone", 300, 1500)]
        }
        return p
    }

    var body: some View {
        DialogFrame(title: "DICOM Window / Level", width: 420, onOK: {
            doc.commit("Window/Level")
        }, onCancel: {
            DICOM.applyWindow(doc, center: entry.center, width: entry.width)
            doc.revertUncommitted()
        }) {
            VStack(alignment: .leading, spacing: 8) {
                ValueSlider(label: "Level", value: $center, range: safeRange(lo - (hi - lo) / 2, hi + (hi - lo) / 2), format: "%.0f")
                ValueSlider(label: "Window", value: $width, range: safeRange(1, max(2, (hi - lo) * 2)), format: "%.0f")
                HStack {
                    Menu("Presets") {
                        ForEach(presets, id: \.0) { p in
                            Button("\(p.0)  (\(Int(p.1)) / \(Int(p.2)))") { center = p.1; width = p.2 }
                        }
                    }.fixedSize()
                    Text(String(format: "Level %.0f  ·  Window %.0f", center, width)).font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                }
                Text("Values \(Int(lo)) … \(Int(hi))  ·  \(entry.image.frames) frame(s)  ·  \(entry.image.photometric)")
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                ForEach(Array(entry.image.attributes.enumerated()), id: \.offset) { _, a in
                    Text("\(a.0): \(a.1)").font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                }
            }
        }
        .onChange(of: center) { _, _ in DICOM.applyWindow(doc, center: center, width: width) }
        .onChange(of: width) { _, _ in DICOM.applyWindow(doc, center: center, width: width) }
    }
}
