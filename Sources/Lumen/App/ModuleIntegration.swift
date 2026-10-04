import AppKit
import CoreImage
import ImageCratCore

/// Wires feature modules to each other (each was built independently around small hooks).
enum ModuleIntegration {
    /// File-menu items that live in the shared Export / Import / Automate submenus (registered first so they lead).
    static func registerCoreMenus() {
        let hasDoc = { AppModel.shared.activeDocument != nil }
        MenuRegistry.add("File", "Artboards to Files…", submenu: "Export", enabled: hasDoc) { AppActions.exportArtboards() }
        MenuRegistry.add("File", "Layer Comps to Files…", submenu: "Export", enabled: hasDoc) { AppActions.exportLayerCompsToFiles() }
        MenuRegistry.add("File", "OpenEXR (32-bit)…", submenu: "Export", enabled: hasDoc) {
            guard let d = AppActions.doc else { return }
            let p = NSSavePanel()
            p.nameFieldStringValue = (d.name as NSString).deletingPathExtension + ".exr"
            if UIBlock.run(p) == .OK, let u = p.url {
                do { try DocumentIO.exportEXR(d.state, to: u) } catch { AppActions.alert("Could not export EXR.", error.localizedDescription) }
            }
        }
        MenuRegistry.add("File", "Animated GIF…", submenu: "Export", dividerBefore: true, enabled: hasDoc) { AnimationExport.exportGIFPanel() }
        MenuRegistry.add("File", "Video (MP4)…", submenu: "Export", enabled: hasDoc) { AnimationExport.exportVideoPanel() }
        MenuRegistry.add("File", "Video Frames to Layers…", submenu: "Import") { VideoImport.importPanel() }
        MenuRegistry.add("File", "Batch…", submenu: "Automate") { AppModel.shared.dialog = .batch }
    }

    static func register() {
        // Sky Replacement: use the SAM / Florence sky mask when the models are installed.
        SkyMaskProvider.provider = { cg in
            let buf = PixelBuffer(cgImage: cg)
            guard let m = try await SegmentationService.skyMask(in: buf) else { return nil }
            return m.makeCGImage()
        }

        // Image Size ▸ Preserve Details 2.0: on-device Real-ESRGAN next to MetalFX and the cloud upscaler.
        UpscalerRegistry.register(name: NeuralUpscalers.name) { img, factor in
            try await NeuralUpscalers.upscale(img, factor: factor)
        }

        // Content Credentials: flag documents that contain cloud-generated layers.
        ContentCredentials.usedGenerativeAI = { doc in !doc.state.generative.isEmpty }

        // Neural Filters' cloud-only options (Smart Portrait expressions, Landscape Mixer) use the Prompt-to-Edit provider.
        let cloudEdit: (CGImage, String) async throws -> CGImage = { img, instruction in
            try await GenAIActions.promptEditImage(img, instruction: instruction)
        }
        NeuralCloudHook.editPortrait = cloudEdit
        NeuralCloudHook.mixLandscape = cloudEdit
    }
}
