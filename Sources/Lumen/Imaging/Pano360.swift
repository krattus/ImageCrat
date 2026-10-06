import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import ImageCratCore

/// Filter ▸ 360 Panorama: 2:1 equirectangular canvas and export with Google Photo Sphere (GPano) XMP metadata.
enum Pano360 {
    enum Mode: String, CaseIterable, Identifiable { case asIs = "Keep size (cropped sphere metadata)", pad = "Pad to full 2:1 sphere"; var id: String { rawValue } }

    static let gpanoNS = "http://ns.google.com/photos/1.0/panorama/"

    /// Full-sphere size for a partial panorama that spans 360° horizontally (or less, at the same scale).
    static func fullSize(_ w: Int, _ h: Int) -> (Int, Int) {
        let fw = max(w, 2 * h)
        return (fw, fw / 2)
    }

    /// Pads the composite to a 2:1 canvas; the empty poles / sides are filled by stretching and softening the edges.
    static func padded(_ st: DocumentState) -> DocumentState {
        let (fw, fh) = fullSize(st.width, st.height)
        if fw == st.width && fh == st.height { return st }
        let sp = CanvasSpace(width: st.width, height: st.height)
        let comp = ImagingDisplay.inks(Compositor.shared.composite(st), state: st).cropped(to: sp.ciCanvas).composited(over: CIImage.color(.black, sp.ciCanvas))
        let dx = CGFloat(fw - st.width) / 2, dy = CGFloat(fh - st.height) / 2
        let full = CGRect(x: 0, y: 0, width: fw, height: fh)
        let placed = comp.translated(dx, dy)
        let stretched = placed.clampedToExtent().applyingGaussianBlur(sigma: Double(max(fw, fh)) / 150).cropped(to: full)
        let img = placed.composited(over: stretched)
        var out = DocumentState(width: fw, height: fh, resolution: st.resolution)
        out.layers = [Layer.raster(name: "Equirectangular", buffer: RenderEngine.renderBuffer(img, docRect: out.canvasRect, space: CanvasSpace(width: fw, height: fh)))]
        return out
    }

    static func export(_ st0: DocumentState, to url: URL, mode: Mode, quality: Double = 0.92) throws {
        let st = mode == .pad ? padded(st0) : st0
        let sp = CanvasSpace(width: st.width, height: st.height)
        let img = ImagingDisplay.inks(Compositor.shared.composite(st), state: st).composited(over: CIImage.color(.black, sp.ciCanvas))
        guard let cg = RenderEngine.readbackContext.createCGImage(img, from: sp.ciCanvas, format: .RGBA8, colorSpace: sRGBSpace) else { throw DocumentIOError.encodeFailed }
        let (fw, fh) = fullSize(st.width, st.height)
        let meta = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(meta, gpanoNS as CFString, "GPano" as CFString, nil)
        let values: [(String, Any)] = [
            ("ProjectionType", "equirectangular"), ("UsePanoramaViewer", "True"),
            ("FullPanoWidthPixels", fw), ("FullPanoHeightPixels", fh),
            ("CroppedAreaImageWidthPixels", st.width), ("CroppedAreaImageHeightPixels", st.height),
            ("CroppedAreaLeftPixels", (fw - st.width) / 2), ("CroppedAreaTopPixels", (fh - st.height) / 2),
        ]
        for (k, v) in values {
            let s: CFString = (v as? String).map { $0 as CFString } ?? ("\(v)" as CFString)
            CGImageMetadataSetValueWithPath(meta, nil, "GPano:\(k)" as CFString, s)
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw DocumentIOError.encodeFailed }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality, kCGImagePropertyDPIWidth: st.resolution, kCGImagePropertyDPIHeight: st.resolution]
        CGImageDestinationAddImageAndMetadata(dest, cg, meta, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) { throw DocumentIOError.encodeFailed }
    }

    static func hasGPano(_ url: URL) -> Bool {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let m = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
            if let v = CGImageMetadataCopyStringValueWithPath(m, nil, "GPano:ProjectionType" as CFString) as String?, v == "equirectangular" { return true }
        }
        guard let d = try? Data(contentsOf: url) else { return false }
        return d.range(of: Data("equirectangular".utf8)) != nil
    }

    /// Image ▸ 360: replaces the document with the padded 2:1 canvas (undoable).
    static func makeCanvas2x1(_ d: Document) {
        let st = padded(d.state)
        guard st.width != d.state.width || st.height != d.state.height else { AppModel.shared.setStatus("Already 2:1"); return }
        var ns = st
        ns.colorMode = d.state.colorMode == .rgb ? .rgb : d.state.colorMode
        ColorModes.finish(d, ns, "Equirectangular 2:1")
    }
}

struct Pano360Dialog: View {
    @State private var mode: Pano360.Mode = .asIs
    var body: some View {
        let d = AppActions.doc
        ImagingDialogFrame(title: "360° Panorama (Equirectangular)", width: 420, okTitle: "Export…", onOK: {
            AppModel.shared.dialog = nil
            guard let d else { return }
            let p = NSSavePanel()
            p.allowedContentTypes = [.jpeg]
            p.nameFieldStringValue = (d.name as NSString).deletingPathExtension + "_360.jpg"
            let m = mode
            UIBlock.begin(p) { r in
                guard r == .OK, let u = p.url else { return }
                do { try Pano360.export(d.state, to: u, mode: m) } catch { AppActions.alert("Could not export the panorama.", error.localizedDescription) }
            }
        }) {
            if let d {
                let (fw, fh) = Pano360.fullSize(d.state.width, d.state.height)
                Text("Document \(d.state.width)×\(d.state.height) px → sphere \(fw)×\(fh) px (2:1)").foregroundStyle(Theme.textDim)
            }
            Picker("Output", selection: $mode) { ForEach(Pano360.Mode.allCases) { Text(tr($0.rawValue)).tag($0) } }
            Text("Writes a JPEG with Photo Sphere (GPano) metadata so 360° viewers show it as a sphere. Use Photomerge ▸ Spherical with “360° equirectangular” for a full sphere.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            Button("Make Canvas 2:1 (in place)") { AppModel.shared.dialog = nil; if let d { Pano360.makeCanvas2x1(d) } }.buttonStyle(PanelButtonStyle())
        }
    }
}
