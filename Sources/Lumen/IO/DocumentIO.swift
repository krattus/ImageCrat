import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

enum ExportFormat: String, CaseIterable, Identifiable {
    case png = "PNG", jpeg = "JPEG", tiff = "TIFF", heic = "HEIC", bmp = "BMP", gif = "GIF", psd = "PSD"
    var id: String { rawValue }
    var ext: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        case .heic: return "heic"
        case .bmp: return "bmp"
        case .gif: return "gif"
        case .psd: return "psd"
        }
    }
    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        case .heic: return .heic
        case .bmp: return .bmp
        case .gif: return .gif
        case .psd: return UTType(filenameExtension: "psd") ?? .data
        }
    }
    var supportsQuality: Bool { self == .jpeg || self == .heic }
    var supportsAlpha: Bool { self != .jpeg && self != .bmp }
}

struct LumenFile: Codable {
    var version = 1
    var name: String
    var state: DocumentState
    /// Module side data stored with the document (Workflow2: named versions, timelapse id). Unknown keys are ignored.
    var extras: [String: Data]? = nil
}

enum DocumentIO {
    /// Format hooks for feature modules: openers / "Save As" writers keyed by lowercased extension
    /// (checked before the built-in formats) and extra types for the open / save panels.
    static var customLoaders: [String: (URL) throws -> Document] = [:]
    static var customSavers: [String: (Document, URL) throws -> Void] = [:]
    static var extraOpenTypes: [UTType] = []
    static var extraSaveTypes: [UTType] = []
    /// Side data written into / read from `LumenFile.extras`, keyed by module.
    static var nativeExtrasWriters: [String: (Document) -> Data?] = [:]
    static var nativeExtrasReaders: [String: (Document, Data) -> Void] = [:]
    /// Called after `export` has written a file (feature modules may post-process it, e.g. Ultra PNG re-packing).
    static var postExportHooks: [(URL, ExportFormat) -> Void] = []

    /// True while a file is loaded to become smart-object contents (Place, Replace Contents, linked reload): loaders
    /// skip their import dialogs.
    static var placing = false
    static func loadForPlacing(url: URL) throws -> Document {
        let was = placing
        placing = true
        defer { placing = was }
        return try load(url: url)
    }

    static func load(url: URL) throws -> Document {
        let ext = url.pathExtension.lowercased()
        if let loader = customLoaders[ext] { return try loader(url) }
        if Brand.nativeExtensions.contains(ext) {   // .imagecrat, and .lumen from before the rename (same format)
            let data = try Data(contentsOf: url)
            let f = try PropertyListDecoder().decode(LumenFile.self, from: data)
            let d = Document(state: f.state, name: url.lastPathComponent)
            d.fileURL = url
            for (k, v) in f.extras ?? [:] { nativeExtrasReaders[k]?(d, v) }
            return d
        }
        if ext == "psd" || ext == "psb", let d = PSDImportModule.open(url) { return d }   // live layers + import report
        if rawExtensions.contains(ext), let cg = loadRAW(url: url) {
            var st = DocumentState(width: cg.width, height: cg.height, resolution: 300)
            st.layers = [Layer.raster(name: "Background", buffer: PixelBuffer(cgImage: cg))]
            st.bitDepth = .sixteen
            let d = Document(state: st, name: url.lastPathComponent)
            d.fileURL = url
            return d
        }
        guard let (cg, dpi) = loadImage(url: url) else { throw DocumentIOError.unreadable }
        var st = DocumentState(width: cg.width, height: cg.height, resolution: dpi)
        st.layers = [Layer.raster(name: "Background", buffer: PixelBuffer(cgImage: cg))]
        let d = Document(state: st, name: url.lastPathComponent)
        d.fileURL = url
        return d
    }

    static let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "x3f", "3fr", "iiq", "erf", "kdc", "mos", "mrw"]

    /// Camera RAW decode (Core Image RAW pipeline, as-shot white balance, default noise reduction).
    static func loadRAW(url: URL, exposure: Double = 0) -> CGImage? {
        guard let f = CIRAWFilter(imageURL: url) else { return nil }
        f.exposure = Float(exposure)
        f.isGamutMappingEnabled = true
        guard let img = f.outputImage else { return nil }
        let ext = img.extent
        let moved = img.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
        return RenderEngine.readbackContext.createCGImage(moved, from: CGRect(origin: .zero, size: ext.size), format: .RGBA8, colorSpace: sRGBSpace)
    }

    /// Decodes an image file into sRGB with orientation applied.
    static func loadImage(url: URL) -> (CGImage, Double)? {
        var dpi = 72.0
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let d = props[kCGImagePropertyDPIWidth] as? Double { dpi = d }
        guard let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        let ext = ci.extent
        let img = ci.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
        guard let cg = RenderEngine.readbackContext.createCGImage(img, from: CGRect(origin: .zero, size: ext.size), format: .RGBA8, colorSpace: sRGBSpace) else { return nil }
        return (cg, dpi)
    }

    static func saveNative(_ d: Document, to url: URL) throws {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        let extras = nativeExtrasWriters.compactMapValues { $0(d) }
        let data = try enc.encode(LumenFile(name: d.name, state: d.state.droppingStaleTextPixels(), extras: extras.isEmpty ? nil : extras))
        try data.write(to: url, options: .atomic)
    }

    static func export(_ st: DocumentState, to url: URL, format: ExportFormat, quality: Double, scale: Double, background: RGBA? = nil) throws {
        if format == .psd {
            try PSDWriter.write(st, to: url)
            return
        }
        if try IndexedExport.exportIfNeeded(st, to: url, format: format, scale: scale) { postExportHooks.forEach { $0(url, format) }; return }   // palette GIF / PNG-8 (Imaging module)
        let bg: RGBA? = format.supportsAlpha ? background : (background ?? .white)
        let space = CanvasSpace(width: st.width, height: st.height)
        var ci = ImagingDisplay.inks(Compositor.shared.composite(st), state: st)
        if let bg { ci = ci.composited(over: CIImage.color(bg, space.ciCanvas)) }
        var rect = space.ciCanvas
        if abs(scale - 1) > 0.001 {
            ci = ci.cropped(to: rect).applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            rect = CGRect(x: 0, y: 0, width: max(1, Int(Double(st.width) * scale)), height: max(1, Int(Double(st.height) * scale)))
        }
        // Pixel values are in the document profile; tag the output with it.
        let profile = ColorProfiles.space(named: st.profileName)
        let tagSpace = profile.model == .rgb ? profile : sRGBSpace
        let highBit = st.bitDepth != .eight && [.png, .tiff, .psd].contains(format)
        let floatOut = st.bitDepth == .thirtyTwo && format == .tiff
        let ciFormat: CIFormat = floatOut ? .RGBAf : (highBit ? .RGBA16 : .RGBA8)
        let linearTag = floatOut ? (CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? tagSpace) : tagSpace
        var cg: CGImage
        if floatOut {
            guard let c = RenderEngine.readbackContext.createCGImage(ci, from: rect, format: .RGBAf, colorSpace: linearTag) else { throw DocumentIOError.encodeFailed }
            cg = c
        } else {
            guard let c = RenderEngine.readbackContext.createCGImage(ci, from: rect, format: ciFormat, colorSpace: sRGBSpace) else { throw DocumentIOError.encodeFailed }
            cg = c.copy(colorSpace: tagSpace) ?? c
        }
        // CMYK documents export CMYK JPEG/TIFF through the proof profile.
        if st.colorMode == .cmyk, format == .jpeg || format == .tiff {
            let cmyk = ColorProfiles.space(named: AppModel.shared.proof.profileName)
            if cmyk.model == .cmyk, let c = ColorConvert.draw(cg, into: cmyk, intent: AppModel.shared.proof.intent.cg) { cg = c }
        } else if st.colorMode == .grayscale, format != .gif {
            if let g = ColorConvert.draw(cg, into: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, intent: .perceptual), !format.supportsAlpha || bg != nil { cg = g }
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else { throw DocumentIOError.encodeFailed }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: st.resolution, kCGImagePropertyDPIHeight: st.resolution]
        if format.supportsQuality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) { throw DocumentIOError.encodeFailed }
        postExportHooks.forEach { $0(url, format) }
    }

    /// Writes an OpenEXR (32-bit float, linear) of the composite.
    static func exportEXR(_ st: DocumentState, to url: URL) throws {
        let space = CanvasSpace(width: st.width, height: st.height)
        let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        guard let cg = RenderEngine.readbackContext.createCGImage(Compositor.shared.composite(st), from: space.ciCanvas, format: .RGBAf, colorSpace: lin),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.ilm.openexr-image" as CFString, 1, nil) else { throw DocumentIOError.encodeFailed }
        CGImageDestinationAddImage(dest, cg, nil)
        if !CGImageDestinationFinalize(dest) { throw DocumentIOError.encodeFailed }
    }

    /// Encoded byte size estimate for the export dialog.
    static func estimateSize(_ st: DocumentState, format: ExportFormat, quality: Double, scale: Double) -> Int? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-estimate.\(format.ext)")
        do {
            try export(st, to: tmp, format: format, quality: quality, scale: scale)
            let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? nil
            try? FileManager.default.removeItem(at: tmp)
            return size
        } catch { return nil }
    }
}
