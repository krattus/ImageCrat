import AppKit
import ImageCratCore

/// Edit ▸ Define Brush Preset… (from the selection, any shape, or the whole visible image) and Define Brush from Layer.
/// The pixels become a gray tip: transparency never paints, dark paints (Photoshop's rule), a light shape on
/// transparency paints with its alpha (`coverage`); a selection only limits the tip. The tip is trimmed to its content and
/// padded square; the user names the brush and picks its folder.
enum DefineBrush {
    enum Source { case visible, activeLayer }

    /// The tip pixels for a document (nil: nothing to define from — an empty selection or layer).
    static func tip(_ d: Document, source: Source) -> PixelBuffer? {
        let sp = AppActions.space(d)
        let image: CIImage
        switch source {
        case .visible: image = Compositor.shared.composite(d)
        case .activeLayer:
            guard let l = d.activeLayer else { return nil }
            image = Compositor.shared.layerAppearance(l, state: d.state)
        }
        var rect = d.state.canvasRect
        if let sel = d.state.selection {
            guard let b = sel.opaqueBounds() else { return nil }
            rect = b
        }
        let rgba = RenderEngine.renderBuffer(image, docRect: rect, space: sp)
        let cov = coverage(rgba)
        // Any selection shape: the selection's coverage limits the tip (it doesn't change what paints).
        if let sel = d.state.selection {
            let p = cov.data.assumingMemoryBound(to: UInt8.self)
            let m = sel.data.assumingMemoryBound(to: UInt8.self)
            for y in 0..<cov.height {
                let sy = y + rect.y
                for x in 0..<cov.width {
                    let sx = x + rect.x
                    let k = sx >= 0 && sy >= 0 && sx < sel.width && sy < sel.height ? Int(m[sy * sel.bytesPerRow + sx]) : 0
                    let i = y * cov.bytesPerRow + x
                    p[i] = UInt8((Int(p[i]) * k + 127) / 255)
                }
            }
            cov.markDirty()
        }
        guard let content = cov.opaqueBounds(threshold: 2) else { return nil }
        return BrushLibrary.normalizedTip(cov.cropped(to: content))
    }

    /// Photoshop's Define Brush rule: dark paints (coverage = 1 − luminance, over transparency × alpha); a light shape
    /// on transparency (visible pixels mostly light) paints with its alpha instead.
    static func coverage(_ rgba: PixelBuffer) -> PixelBuffer {
        let w = rgba.width, h = rgba.height
        let out = PixelBuffer(width: w, height: h, format: .gray)
        let s = rgba.data.assumingMemoryBound(to: UInt8.self), o = out.data.assumingMemoryBound(to: UInt8.self)
        var translucent = 0, lumSum = 0, alphaSum = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = y * rgba.bytesPerRow + x * 4
                let a = Int(s[i + 3])
                if a < 250 { translucent += 1 }
                lumSum += (Int(s[i]) * 77 + Int(s[i + 1]) * 150 + Int(s[i + 2]) * 29) >> 8     // premultiplied
                alphaSum += a
            }
        }
        let lightShape = Double(translucent) / Double(max(1, w * h)) >= 0.005 && alphaSum > 0 && Double(lumSum) / Double(alphaSum) > 0.8
        for y in 0..<h {
            for x in 0..<w {
                let i = y * rgba.bytesPerRow + x * 4
                let a = Int(s[i + 3])
                let pl = min(a, (Int(s[i]) * 77 + Int(s[i + 1]) * 150 + Int(s[i + 2]) * 29) >> 8)
                o[y * out.bytesPerRow + x] = UInt8(lightShape ? a : a - pl)
            }
        }
        out.markDirty()
        return out
    }

    /// Menu command: asks for a name and a folder, then adds the brush and selects it.
    static func run(_ source: Source) {
        guard let d = AppActions.doc else { return }
        guard let t = tip(d, source: source) else {
            AppActions.alert("Nothing to define a brush from.", source == .activeLayer ? "The active layer has no pixels in the selection." : "The selection is empty.")
            return
        }
        let lib = BrushLibrary.shared
        let suggested = source == .activeLayer ? (d.activeLayer?.name ?? "Sampled Brush") : "Sampled Brush \(lib.orderedBrushes.filter { $0.source.hasPrefix("Defined") }.count + 1)"
        guard let (name, folder) = askNameAndFolder(title: "Brush Name", initial: suggested, tip: t) else { return }
        if let id = lib.defineBrush(tip: t, name: name, in: folder, source: source == .activeLayer ? "Defined from layer" : "Defined from selection") {
            lib.select(id)
            AppModel.shared.setStatus("Brush “\(name)” defined (\(t.width)×\(t.height) px).")
        }
    }

    /// Name + folder dialog (headless runs take the defaults).
    static func askNameAndFolder(title: String, initial: String, tip: PixelBuffer?) -> (String, String)? {
        let lib = BrushLibrary.shared
        let a = NSAlert()
        a.messageText = tr(title)
        a.informativeText = tr("The brush is added to the Brushes panel.")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        let field = NSTextField(frame: NSRect(x: 0, y: 34, width: 300, height: 24))
        field.stringValue = initial
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        let folders = lib.index.allFolders
        let def = lib.defaultFolderForNewBrushes()
        popup.addItem(withTitle: tr("Top Level"))
        popup.lastItem?.representedObject = BrushLibraryIndex.rootID
        for f in lib.index.allFolders {
            popup.addItem(withTitle: f.path.joined(separator: " ▸ "))
            popup.lastItem?.representedObject = f.id
            if f.id == def { popup.select(popup.lastItem) }
        }
        if !folders.contains(where: { $0.id == def }) { popup.selectItem(at: 0) }
        box.addSubview(field)
        box.addSubview(popup)
        a.accessoryView = box
        if let t = tip { a.icon = NSImage(cgImage: t.makeCGImage(), size: NSSize(width: 48, height: 48)) }
        a.addButton(withTitle: tr("OK"))
        a.addButton(withTitle: tr("Cancel"))
        a.window.initialFirstResponder = field
        guard UIBlock.run(a) == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = popup.selectedItem?.representedObject as? String ?? def
        return (name.isEmpty ? initial : name, folder)
    }

    /// "New Brush Preset…" from the current tool's settings (Photoshop's New Brush dialog: capture size, include tool
    /// settings, include colour).
    static func newBrushFromCurrentSettings() {
        let app = AppModel.shared
        let lib = BrushLibrary.shared
        let s = app.activeBrushSettings
        let a = NSAlert()
        a.messageText = tr("New Brush")
        a.informativeText = tr("Saves the current brush settings as a preset.")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 136))
        let field = NSTextField(frame: NSRect(x: 0, y: 110, width: 300, height: 24))
        field.stringValue = (lib.activePreset?.name).map { "\($0) copy" } ?? "Brush \(lib.orderedBrushes.count + 1)"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 78, width: 300, height: 26))
        popup.addItem(withTitle: tr("Top Level")); popup.lastItem?.representedObject = BrushLibraryIndex.rootID
        let def = lib.defaultFolderForNewBrushes()
        for f in lib.index.allFolders {
            popup.addItem(withTitle: f.path.joined(separator: " ▸ ")); popup.lastItem?.representedObject = f.id
            if f.id == def { popup.select(popup.lastItem) }
        }
        let size = NSButton(checkboxWithTitle: tr("Capture Brush Size in Preset"), target: nil, action: nil); size.state = .on
        size.frame = NSRect(x: 0, y: 52, width: 300, height: 20)
        let tool = NSButton(checkboxWithTitle: tr("Include Tool Settings (opacity, flow, mode)"), target: nil, action: nil); tool.state = .off
        tool.frame = NSRect(x: 0, y: 28, width: 300, height: 20)
        let color = NSButton(checkboxWithTitle: tr("Include Color"), target: nil, action: nil); color.state = .off
        color.frame = NSRect(x: 0, y: 4, width: 300, height: 20)
        for v in [field, popup, size, tool, color] as [NSView] { box.addSubview(v) }
        a.accessoryView = box
        a.addButton(withTitle: tr("OK")); a.addButton(withTitle: tr("Cancel"))
        a.window.initialFirstResponder = field
        guard UIBlock.run(a) == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = lib.newBrush(from: s, name: name.isEmpty ? "Brush" : name, in: popup.selectedItem?.representedObject as? String ?? def,
                              includesSize: size.state == .on, includesToolSettings: tool.state == .on, color: color.state == .on ? app.foreground : nil)
        lib.activePresetIDs[app.tool.rawValue] = id
        lib.select(id)
    }
}
