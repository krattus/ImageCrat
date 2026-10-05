import AppKit
import CoreImage
import UniformTypeIdentifiers
import ImageCratCore

/// Central command layer used by menus, panels and tools.
enum AppActions {
    static var app: AppModel { AppModel.shared }
    static var doc: Document? { app.activeDocument }
    static weak var canvas: CanvasView?

    static func space(_ d: Document) -> CanvasSpace { CanvasSpace(width: d.state.width, height: d.state.height) }

    // MARK: Sampling

    /// Canvas-size RGBA buffer of the composite (allLayers) or the active layer.
    static func sampleSource(allLayers: Bool) -> PixelBuffer? {
        guard let d = doc else { return nil }
        let sp = space(d)
        let img: CIImage
        if allLayers {
            img = Compositor.shared.composite(d)
        } else if let l = d.activeLayer {
            if d.editTarget == .mask, let m = l.mask {
                img = sp.place(m.buffer, at: m.origin)
            } else {
                img = Compositor.shared.contentImage(l, space: sp) ?? CIImage.clearImage
            }
        } else {
            return nil
        }
        return RenderEngine.renderBuffer(img.cropped(to: sp.ciCanvas), docRect: d.state.canvasRect, space: sp)
    }

    /// The Quick Mask as an RGBA canvas buffer (white = selected; no selection = all white), for tools that sample it.
    static func quickMaskSample(_ d: Document) -> PixelBuffer {
        let sp = space(d)
        let img = d.state.selection?.ciImage ?? CIImage.color(.white, sp.ciCanvas)
        return RenderEngine.renderBuffer(img.cropped(to: sp.ciCanvas), docRect: d.state.canvasRect, space: sp)
    }

    /// Topmost visible layer with opaque pixels at point.
    static func layerAt(_ p: CGPoint, shapesOnly: Bool = false, textOnly: Bool = false) -> UUID? {
        guard let d = doc else { return nil }
        let x = Int(floor(p.x)), y = Int(floor(p.y))
        let sp = space(d)
        for (l, _) in d.state.layers.flattenedForDisplay(includeCollapsed: true) {
            guard l.isVisible, !l.isGroup, !l.isAdjustment else { continue }
            if shapesOnly && !l.isShape { continue }
            if textOnly && !l.isText { continue }
            switch l.content {
            case .raster(let r):
                if r.buffer.alpha(x - r.origin.x, y - r.origin.y) > 10 { return l.id }
            case .text(let t):
                if TextRenderer.docQuad(t).path.contains(p) { return l.id }
            case .shape(let s):
                let path = s.path.resolved.path
                if path.contains(p) || path.copy(strokingWithWidth: max(6, s.stroke.width), lineCap: .round, lineJoin: .round, miterLimit: 4).contains(p) { return l.id }
            case .smartObject(let so):
                if so.quad.path.contains(p) {
                    let img = Compositor.shared.contentImage(l, space: sp)
                    if img != nil { return l.id }
                }
            case .fill:
                if !shapesOnly && !textOnly { return l.id }
            default: break
            }
        }
        return nil
    }

    // MARK: File

    static func newDocument(width: Int, height: Int, resolution: Double, background: RGBA?, name: String) {
        let d = Document.newBlank(width: width, height: height, resolution: validResolution(resolution), background: background, name: name)
        app.add(d)
    }

    static let openTypes: [UTType] = {
        var t: [UTType] = [.png, .jpeg, .tiff, .heic, .gif, .bmp, .image]
        t.insert(contentsOf: [Brand.documentType, Brand.legacyDocumentType], at: 0)   // .imagecrat, and .lumen from before the rename
        if let psd = UTType(filenameExtension: "psd") { t.append(psd) }
        if let webp = UTType(filenameExtension: "webp") { t.append(webp) }
        t.append(.rawImage)
        for e in DocumentIO.rawExtensions { if let u = UTType(filenameExtension: e), !t.contains(u) { t.append(u) } }
        return t
    }()

    static func openPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = openTypes + DocumentIO.extraOpenTypes
        p.allowsMultipleSelection = true
        UIBlock.begin(p) { r in
            if r == .OK { for u in p.urls { open(url: u) } }
        }
    }

    static func open(url: URL) {
        if BrushLibrary.isBrushFile(url) { BrushLibrary.shared.importInBackground([url]); return }   // .abr, .brushset, … → Brushes panel
        if let existing = app.documents.first(where: { $0.fileURL == url }) {
            app.activeDocumentID = existing.id
            return
        }
        do {
            let d = try DocumentIO.load(url: url)
            app.add(d)
            PSDImportModule.announce(d)   // status line: what a Photoshop file kept editable
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            if (error as? CocoaError)?.code == .userCancelled { return }   // e.g. Import PDF dialog cancelled
            alert("Could not open “\(url.lastPathComponent)”.", error.localizedDescription)
        }
    }

    static func save() {
        guard let d = doc else { return }
        canvas?.commitCurrentTool()
        if let parent = d.smartParent, let lid = d.smartParentLayerID {
            updateSmartObject(parent: parent, layerID: lid, from: d)
            d.markSaved()
            return
        }
        // A native file is saved in place: `.imagecrat`, and also a `.lumen` file from before the rename (same format;
        // it stays a .lumen file that older builds can still open — Save As… offers .imagecrat).
        if let url = d.fileURL, Brand.isNativeDocument(url) {
            do {
                try DocumentIO.saveNative(d, to: url)
                d.markSaved()
            } catch { alert("Could not save the document.", error.localizedDescription) }
        } else {
            saveAs()
        }
    }

    static func saveAs() {
        guard let d = doc else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [Brand.documentType, UTType(filenameExtension: "psd") ?? .data] + DocumentIO.extraSaveTypes
        p.nameFieldStringValue = (d.name as NSString).deletingPathExtension + "." + Brand.documentExtension
        p.canSelectHiddenExtension = true
        UIBlock.begin(p) { r in
            guard r == .OK, let url = p.url else { return }
            do {
                if let saver = DocumentIO.customSavers[url.pathExtension.lowercased()] {
                    try saver(d, url)
                } else if url.pathExtension.lowercased() == "psd" {
                    try PSDWriter.write(d.state, to: url)
                } else {
                    try DocumentIO.saveNative(d, to: url)
                    d.fileURL = url
                    d.name = url.lastPathComponent
                    d.markSaved()
                }
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            } catch { alert("Could not save the document.", error.localizedDescription) }
        }
    }

    static func quickExportPNG() {
        guard let d = doc else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.nameFieldStringValue = (d.name as NSString).deletingPathExtension + ".png"
        UIBlock.begin(p) { r in
            guard r == .OK, let url = p.url else { return }
            do { try DocumentIO.export(d.state, to: url, format: .png, quality: 1, scale: 1) } catch { alert("Export failed.", error.localizedDescription) }
        }
    }

    static func closeDocument(_ d: Document? = nil) {
        guard let d = d ?? doc else { return }
        if d.isDirty && d.smartParent == nil {
            let a = NSAlert()
            a.messageText = "Save changes to “\(d.name)” before closing?"
            a.informativeText = "Your changes will be lost if you don't save them."
            a.addButton(withTitle: "Save")
            a.addButton(withTitle: "Don't Save")
            a.addButton(withTitle: "Cancel")
            let r = UIBlock.run(a)
            if r == .alertThirdButtonReturn { return }
            if r == .alertFirstButtonReturn {
                app.activeDocumentID = d.id
                save()
                if d.isDirty { return }
            }
        } else if let parent = d.smartParent, let lid = d.smartParentLayerID, d.isDirty {
            let a = NSAlert()
            a.messageText = "Apply changes to the Smart Object?"
            a.addButton(withTitle: "Apply")
            a.addButton(withTitle: "Discard")
            if UIBlock.run(a) == .alertFirstButtonReturn { updateSmartObject(parent: parent, layerID: lid, from: d) }
        }
        app.close(d)
    }

    static func placeFile(_ url: URL) {
        guard doc != nil else { open(url: url); return }
        do {
            let placed = try DocumentIO.loadForPlacing(url: url)
            let name = (url.lastPathComponent as NSString).deletingPathExtension
            if placed.state.layers.count == 1, let r = placed.state.layers[0].raster {
                placeBuffer(r.buffer, name: name)
            } else {
                placeDocumentState(placed.state, name: name)
            }
        } catch {
            alert("Could not place “\(url.lastPathComponent)”.", error.localizedDescription)
        }
    }

    static func placeImage(_ cg: CGImage, name: String) {
        placeBuffer(PixelBuffer(cgImage: cg), name: name)
    }

    /// Places an image as an embedded smart object, fitted inside the canvas.
    static func placeBuffer(_ buf: PixelBuffer, name: String) {
        guard let d = doc else { return }
        let W = CGFloat(d.state.width), H = CGFloat(d.state.height)
        var w = CGFloat(buf.width), h = CGFloat(buf.height)
        let s = min(1, min(W / w, H / h))
        w *= s; h *= s
        let r = CGRect(x: (W - w) / 2, y: (H - h) / 2, width: w, height: h)
        let so = SmartObjectContent(source: .image(buf), quad: Quad(rect: r), sourceName: name)
        d.addLayer(Layer(name: name, content: .smartObject(so)), commitName: "Place Embedded")
    }

    static func placeDocumentState(_ st: DocumentState, name: String) {
        guard let d = doc else { return }
        let W = CGFloat(d.state.width), H = CGFloat(d.state.height)
        var w = CGFloat(st.width), h = CGFloat(st.height)
        let s = min(1, min(W / w, H / h))
        w *= s; h *= s
        let r = CGRect(x: (W - w) / 2, y: (H - h) / 2, width: w, height: h)
        let so = SmartObjectContent(source: .document(st), quad: Quad(rect: r), sourceName: name)
        d.addLayer(Layer(name: name, content: .smartObject(so)), commitName: "Place Embedded")
    }

    // MARK: Alerts

    /// Headless hook (self tests): when set, alerts and confirmations are answered by it instead of running a modal panel.
    static var modalHook: ((_ title: String, _ info: String) -> Bool)?

    static func alert(_ title: String, _ info: String = "") {
        DiagLog.shared.warning("Alert: \(title) \(info)")   // for Help ▸ Report a Bug… (redacted)
        if let h = modalHook { _ = h(title, info); return }
        // A self-test run has nobody to dismiss a modal panel: log it instead of blocking the whole suite.
        if CommandLine.arguments.contains("--selftest") { print("ALERT (not shown): \(title) \(info)"); return }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        UIBlock.run(a)
    }

    static func confirm(_ title: String, _ info: String, ok: String) -> Bool {
        if let h = modalHook { return h(title, info) }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel")
        return UIBlock.run(a) == .alertFirstButtonReturn
    }

    static func offerRasterize(layer id: UUID) {
        guard let d = doc, let l = d.state.layer(id) else { return }
        let lost: String
        switch l.content {
        case .text: lost = "live text"
        case .shape: lost = "a vector shape"
        case .fill(let f): lost = f.recipe != nil ? "a Recipe layer" : "a fill layer"
        case .group: lost = "a group"
        case .adjustment: lost = "an adjustment layer"
        case .smartObject, .raster: lost = "a smart object"
        }
        if confirm("This \(l.kindName.lowercased()) must be rasterized before proceeding.", "Its content will no longer be editable as \(lost).", ok: "Rasterize") {
            rasterizeLayer(id)
        }
    }

    // MARK: Smart objects

    static func editSmartContents(_ id: UUID? = nil) {
        guard let d = doc, let lid = id ?? d.activeLayerID, let l = d.state.layer(lid), let so = l.smart else { return }
        if ComponentActions.interceptEdit(d, lid) { return }   // component instance → Edit Main Component
        let st: DocumentState
        switch so.source {
        case .document(let s): st = s
        case .image(let b):
            var s = DocumentState(width: b.width, height: b.height)
            s.layers = [Layer.raster(name: "Layer 0", buffer: b)]
            st = s
        }
        let child = Document(state: st, name: "\(l.name).psb")
        child.smartParent = d
        child.smartParentLayerID = lid
        app.add(child)
        app.setStatus("Editing Smart Object contents. Save (⌘S) to update “\(l.name)”.")
    }

    static func updateSmartObject(parent: Document, layerID: UUID, from child: Document) {
        if ComponentActions.interceptUpdate(parent: parent, child: child) { return }   // main component document
        let st = child.state
        parent.updateLayer(layerID) { l in
            guard var so = l.smart else { return }
            // keep the same placement (incl. perspective) but adapt if the canvas size changed
            so.setSource(.document(st))
            l.smart = so
        }
        parent.commit("Edit Contents")
        parent.setNeedsRender()
    }

    // MARK: Misc

    static func nudge(dx: Double, dy: Double) {
        guard let d = doc else { return }
        if let mt = canvas?.currentTool as? MoveTool, let s = mt.session {
            s.quad = s.quad.mapped { $0 + CGPoint(x: dx, y: dy) }
            s.updatePreview()
            return
        }
        // Warp / Puppet Warp / … pending: nudging the layer underneath would throw the mesh away
        if let mt = canvas?.currentTool as? MoveTool, mt.interactive != nil { return }
        if app.tool == .move {
            if d.state.selection != nil, let id = d.activeLayerID, d.state.layer(id)?.isRaster == true {
                if let s = TransformSession(doc: d, layerIDs: [id]) {
                    s.quad = s.quad.mapped { $0 + CGPoint(x: dx, y: dy) }
                    s.commit()
                }
                return
            }
            var moved = false
            for id in d.withoutDescendants(d.withLinked(d.orderedSelection)) {   // linked layers move together
                guard let l = d.state.layer(id), !l.locks.positionLocked, l.isVisible else { continue }   // like dragging
                d.updateLayer(id) { $0.translate(dx: dx, dy: dy) }
                moved = true
            }
            if moved { d.commit("Nudge") }
        } else if app.tool.isMarquee || app.tool == .magicWand, let sel = d.state.selection {
            let m = PixelBuffer(width: sel.width, height: sel.height, format: .gray)
            m.copyPixels(from: sel, at: IPoint(x: Int(dx), y: Int(dy)))
            m.markDirty()
            d.setSelection(m, commitName: "Nudge Selection")
        }
    }
}
