import AppKit
import CoreImage
import Metal
import ImageCratCore

/// Headless memory soak: repeats a representative editing session (open a 1600×1080 document, draw it the way the canvas
/// does, filters, undo / redo, particles, recipes, textures, smart filters, snapshots, close) and samples the process's
/// `phys_footprint` after every round, so retention shows up as steady growth.
/// Full run: `LUMEN_SOAK=<rounds> LUMEN_SELFTEST_ONLY=invfixes Lumen --selftest <dir>` (writes soak.csv); the suite runs a short one.
enum MemorySoak {
    struct Footprint { var current: Double; var peak: Double }   // MB

    static func footprint() -> Footprint {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return Footprint(current: 0, peak: 0) }
        return Footprint(current: Double(info.phys_footprint) / 1_048_576, peak: Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    private static let target: MTLTexture? = {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1600, height: 1080, mipmapped: false)
        td.usage = [.shaderWrite, .renderTarget, .shaderRead]
        td.storageMode = .private
        return RenderEngine.device.makeTexture(descriptor: td)
    }()

    /// Draws the document like `CanvasRenderer` does (shared caching context, GPU destination) at a zoom.
    static func display(_ d: Document, zoom z: Double = 0.5) {
        guard let tex = target, let cb = RenderEngine.commandQueue.makeCommandBuffer() else { return }
        let comp = CanvasRenderer.cachedComposite(d).cropped(to: CGRect(x: 0, y: 0, width: d.state.width, height: d.state.height))
        let img = z < 1 ? comp.transformed(by: CGAffineTransform(scaleX: z, y: z), highQualityDownsample: true) : comp
        let rect = CGRect(x: 0, y: 0, width: min(tex.width, Int(Double(d.state.width) * z)), height: min(tex.height, Int(Double(d.state.height) * z)))
        let dest = CIRenderDestination(mtlTexture: tex, commandBuffer: cb)
        _ = try? RenderEngine.context.startTask(toRender: img, from: rect, to: dest, at: .zero)
        cb.commit()
        cb.waitUntilCompleted()
    }

    static func makeDocument(_ i: Int) -> Document {
        var st = SelfTest.baseState(1600, 1080)
        var shape = SelfTest.shapeLayer(CGRect(x: 900 + i % 7 * 10, y: 700, width: 300, height: 200))
        shape.effects.stroke.enabled = true; shape.effects.stroke.size = 6
        shape.effects.dropShadow.enabled = true; shape.effects.dropShadow.size = 18
        st.layers.append(shape)
        let d = Document(state: st, name: "soak \(i)")
        AppModel.shared.add(d)
        // a placed image becomes a smart object (like dragging a photo in)
        let photo = PixelBuffer(width: 900, height: 600)
        let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "E94F37")!.cgColor, RGBA(hex: "2E86AB")!.cgColor] as CFArray, locations: [0, 1])!
        photo.context.drawRadialGradient(g, startCenter: CGPoint(x: 450, y: 300), startRadius: 0, endCenter: CGPoint(x: 450, y: 300), endRadius: 500, options: [])
        photo.markDirty()
        AppActions.placeBuffer(photo, name: "Photo")
        return d
    }

    /// A closed round's document, watched weakly, with the ids its caches would be keyed by.
    final class Weak {
        let id: UUID
        weak var doc: Document?
        weak var buffer: PixelBuffer?
        var ids = Set<UUID>()
        init(_ d: Document) { id = d.id; doc = d; buffer = d.state.layers.first?.raster?.buffer }
    }
    static var tracked: [Weak] = []

    /// One round of the workload; the document is closed at the end.
    static func round(_ i: Int) {
        autoreleasepool {
            let d = makeDocument(i)
            tracked.append(Weak(d))
            display(d); display(d, zoom: 1)
            let smartID = d.activeLayerID
            // pixel filters on the background, each drawn
            d.selectLayer(d.state.layers[0].id)
            let kinds: [FilterKind] = [.gaussianBlur, .motionBlur, .unsharpMask, .addNoise, .crystallize, .emboss]
            for k in kinds { AppActions.applyFilter(FilterInstance(kind: k)); display(d) }
            for _ in 0..<4 { d.undo(); display(d) }
            for _ in 0..<3 { d.redo(); display(d) }
            // smart filters on the placed photo
            if let s = smartID { d.selectLayer(s); AppActions.applyFilter(FilterInstance(kind: .gaussianBlur)); display(d) }
            // particles: a live preview session that is cancelled, then a new layer and a re-editable smart object
            let presets = ParticlePresets.all
            for (k, out) in [(0, POutput.newLayer), (1, .smartObject)] {
                var e = ParticlePresets.effect(presets[(i * 2 + k) % presets.count].id, aspect: 1600.0 / 1080) ?? ParticleEffect()
                e.output = out
                if k == 1 { e.quality = .best }   // 2× supersampled + 4× MSAA float targets
                let preview = ParticleEditor(doc: d, effect: e, interactive: false)
                preview.schedulePreview(); InvFixesSelfTest.pump(0.15); display(d); preview.cancel()
                ParticleEditor(doc: d, effect: e, interactive: false).apply()
                display(d)
            }
            // recipes and textures
            let recipe = RecipePresets.builtIn[i % RecipePresets.builtIn.count]
            RecipeActions.newRecipeLayer(recipe.graph, in: d)
            display(d)
            let gen = TextureCatalog.all[(i * 5) % TextureCatalog.all.count]
            TextureActions.apply(TextureSettings(gen: gen.id), output: .newLayer, in: d)
            display(d)
            // History panel snapshot, then undo / redo across everything
            SnapshotStore.shared.newSnapshot(d)
            for _ in 0..<6 { d.undo(); display(d) }
            for _ in 0..<6 { d.redo(); display(d) }
            for l in d.state.allLayers { tracked.last?.ids.insert(l.id); for f in l.smart?.filters ?? [] { tracked.last?.ids.insert(f.id) } }
            AppModel.shared.close(d)
        }
        InvFixesSelfTest.pump(0.3)   // freed IOSurfaces / pages are returned with a short delay
    }

    /// Region summary of this (test) process, for telling GPU / IOSurface / malloc growth apart.
    static func vmmap() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
        p.arguments = ["--summary", "\(ProcessInfo.processInfo.processIdentifier)"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") where ["IOAccelerator", "IOSurface", "MALLOC_LARGE", "MALLOC_SMALL", "CG image", "CoreImage", "Physical footprint", "owned unmapped", "VM_ALLOCATE", "TOTAL"].contains(where: { line.contains($0) }) {
            print("soak vmmap: " + line)
        }
    }

    /// Runs `rounds` rounds and returns the footprint after each (MB).
    @discardableResult
    static func run(rounds: Int, csv: URL? = nil) -> [Footprint] {
        var out: [Footprint] = []
        var lines = ["round,footprint_mb,peak_mb"]
        let start = footprint()
        print(String(format: "soak: start %.0f MB", start.current))
        for i in 0..<rounds {
            let t0 = Date()
            round(i)
            let f = footprint()
            out.append(f)
            lines.append(String(format: "%d,%.1f,%.1f", i + 1, f.current, f.peak))
            print(String(format: "soak: round %d footprint %.0f MB (peak %.0f MB) %.1f s", i + 1, f.current, f.peak, Date().timeIntervalSince(t0)))
        }
        print("soak: \(tracked.filter { $0.doc != nil }.count) of \(tracked.count) closed documents still alive, \(tracked.filter { $0.buffer != nil }.count) background buffers alive")
        if ProcessInfo.processInfo.environment["LUMEN_SOAK_VMMAP"] != nil { vmmap() }
        if let csv { try? lines.joined(separator: "\n").write(to: csv, atomically: true, encoding: .utf8) }
        return out
    }
}
