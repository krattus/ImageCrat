import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import Observation
import ImageCratCore

// Reference Board (PureRef-style): floating always-on-top windows holding reference images on an infinite
// pan / zoom board. There is one global board (Application Support/Lumen/reference-board.json) and one board per
// document, stored in the document state (`DocumentState.artist.board`) so it is saved inside the .lumen file and
// follows undo. Images are stored as downscaled copies (longest side ≤ RefBoard.maxPixelSide).

enum RefBoardScope: Equatable {
    case global
    case document
}

enum ReferenceImages {
    private static var cache: [UUID: (Int, CGImage)] = [:]
    private static var grayCache: [UUID: (Int, CGImage)] = [:]

    /// Builds a board item from an image: downscaled to the cap, PNG when it has transparency, JPEG otherwise.
    static func makeItem(_ image: CGImage, name: String = "") -> RefItem? {
        let cap = CGFloat(RefBoard.maxPixelSide)
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w >= 1, h >= 1 else { return nil }
        let k = min(1, cap / max(w, h))
        let nw = max(1, Int((w * k).rounded())), nh = max(1, Int((h * k).rounded()))
        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let scaled = ctx.makeImage() else { return nil }
        var transparent = false
        if hasAlpha, let p = ctx.data?.assumingMemoryBound(to: UInt8.self) {
            let bpr = ctx.bytesPerRow
            outer: for y in stride(from: 0, to: nh, by: 3) { for x in stride(from: 0, to: nw, by: 3) where p[y * bpr + x * 4 + 3] < 250 { transparent = true; break outer } }
        }
        let data = NSMutableData()
        let type = (transparent ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        var item = RefItem(imageData: data as Data, pixelWidth: nw, pixelHeight: nh)
        item.name = name
        return item
    }

    static func image(_ item: RefItem) -> CGImage? {
        if let c = cache[item.id], c.0 == item.imageData.count { return c.1 }
        guard let src = CGImageSourceCreateWithData(item.imageData as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        if cache.count > 200 { cache.removeAll() }
        cache[item.id] = (item.imageData.count, img)
        return img
    }

    static func grayImage(_ item: RefItem) -> CGImage? {
        if let c = grayCache[item.id], c.0 == item.imageData.count { return c.1 }
        guard let img = image(item) else { return nil }
        let w = img.width, h = img.height
        // luminance in a gray context, alpha kept through a second pass
        guard let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: graySpace, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let out = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        g.setFillColor(gray: 1, alpha: 1); g.fill(CGRect(x: 0, y: 0, width: w, height: h))
        g.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let gray = g.makeImage() else { return nil }
        out.clip(to: CGRect(x: 0, y: 0, width: w, height: h), mask: alphaMask(img) ?? gray)
        out.draw(gray, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let res = out.makeImage() else { return nil }
        if grayCache.count > 100 { grayCache.removeAll() }
        grayCache[item.id] = (item.imageData.count, res)
        return res
    }

    private static func alphaMask(_ img: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let m = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: graySpace, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let src = c.data?.assumingMemoryBound(to: UInt8.self), let dst = m.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bpr = c.bytesPerRow
        for y in 0..<h { for x in 0..<w { dst[y * w + x] = src[y * bpr + x * 4 + 3] } }
        return m.makeImage()
    }

    /// Images on a pasteboard (files first, then image data).
    static func images(from pb: NSPasteboard) -> [(CGImage, String)] {
        var out: [(CGImage, String)] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for u in urls { if let (cg, _) = DocumentIO.loadImage(url: u) { out.append((cg, u.deletingPathExtension().lastPathComponent)) } }
        }
        if out.isEmpty, let img = NSImage(pasteboard: pb), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            out.append((cg, "Pasted"))
        }
        return out
    }
}

/// Board storage: the global board file and the per-document boards.
@Observable
final class ReferenceBoardStore {
    static let shared = ReferenceBoardStore()
    static let file = "reference-board.json"

    private(set) var global = RefBoard()
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    private init() { reloadGlobal() }

    func reloadGlobal() { global = ArtistSupport.read(RefBoard.self, ReferenceBoardStore.file) ?? RefBoard() }

    func saveGlobalNow() {
        saveWork?.cancel(); saveWork = nil
        ArtistSupport.write(global, ReferenceBoardStore.file)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveGlobalNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func board(_ scope: RefBoardScope, doc: Document?) -> RefBoard {
        switch scope {
        case .global: return global
        case .document: return doc?.state.artist.board ?? RefBoard()
        }
    }

    /// Changes a board. Document boards record a history step (`name`); consecutive steps with the same name are merged.
    /// `name == nil` stores the change without a history step (view pan / zoom).
    func update(_ scope: RefBoardScope, doc: Document?, name: String?, _ body: (inout RefBoard) -> Void) {
        switch scope {
        case .global:
            body(&global)
            if ArtistSupport.isSelfTest { saveGlobalNow() } else { scheduleSave() }
        case .document:
            guard let d = doc else { return }
            var b = d.state.artist.board
            body(&b)
            guard b != d.state.artist.board else { return }
            d.state.artist.board = b
            guard let n = name else { return }
            if d.history.last?.name == n, d.historyIndex == d.history.count - 1, d.historyIndex > 0, ReferenceBoardStore.coalesced.contains(n) {
                d.commitReplacingLast(n)
            } else {
                d.commit(n)
            }
        }
    }

    static let coalesced: Set<String> = ["Move Reference", "Scale Reference", "Reference Opacity"]

    /// Adds images next to each other around `at` (board coordinates).
    @discardableResult
    func add(_ images: [(CGImage, String)], to scope: RefBoardScope, doc: Document?, at: CGPoint, fitSide: CGFloat = 360) -> [UUID] {
        var ids: [UUID] = []
        update(scope, doc: doc, name: "Add Reference") { b in
            var x = at.x
            for (cg, name) in images {
                guard var item = ReferenceImages.makeItem(cg, name: name) else { continue }
                item.scale = Double(min(1, fitSide / CGFloat(max(item.pixelWidth, item.pixelHeight))))
                let w = item.size.width
                item.center = CGPoint(x: x + w / 2, y: at.y)
                x += w + 16
                b.items.append(item)
                ids.append(item.id)
            }
        }
        return ids
    }
}

// MARK: - Rendering

enum RefBoardRenderer {
    /// Board → view transform for a view of `size` (y down).
    static func transform(_ b: RefBoard, size: CGSize) -> CGAffineTransform {
        let z = CGFloat(b.viewZoom)
        return CGAffineTransform(a: z, b: 0, c: 0, d: z, tx: size.width / 2 - b.viewCenter.x * z, ty: size.height / 2 - b.viewCenter.y * z)
    }

    /// Draws the board into a flipped (y down) context.
    static func draw(_ ctx: CGContext, board b: RefBoard, size: CGSize, selection: UUID? = nil, background: Bool = true) {
        if background {
            ctx.setFillColor(NSColor(white: 0.11, alpha: 1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        let t = transform(b, size: size)
        for item in b.items {
            guard let img = item.grayscale ? ReferenceImages.grayImage(item) : ReferenceImages.image(item) else { continue }
            let r = item.frame.applying(t)
            if !r.intersects(CGRect(origin: .zero, size: size)) { continue }
            ctx.saveGState()
            ctx.setAlpha(CGFloat(item.opacity))
            ctx.interpolationQuality = .high
            // images are y-up: flip inside the item rect, plus the item's own flips
            ctx.translateBy(x: r.midX, y: r.midY)
            ctx.scaleBy(x: item.flipH ? -1 : 1, y: item.flipV ? 1 : -1)
            ctx.draw(img, in: CGRect(x: -r.width / 2, y: -r.height / 2, width: r.width, height: r.height))
            ctx.restoreGState()
            if item.id == selection {
                ctx.setStrokeColor(OverlayStyle.accent.cgColor)
                ctx.setLineWidth(1.5)
                ctx.stroke(r.insetBy(dx: -1, dy: -1))
                OverlayStyle.handle(ctx, at: CGPoint(x: r.maxX, y: r.maxY), size: 9, filled: true)
            }
        }
    }

    static func render(_ b: RefBoard, size: CGSize, selection: UUID? = nil) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
        draw(ctx, board: b, size: size, selection: selection)
        return ctx.makeImage()
    }

    /// Topmost item under a view point.
    static func item(at p: CGPoint, board b: RefBoard, size: CGSize) -> RefItem? {
        let t = transform(b, size: size)
        return b.items.last { $0.frame.applying(t).contains(p) }
    }

    /// Colour shown at a view point (the item as displayed: flips, grayscale; opacity ignored). nil over empty board.
    static func color(at p: CGPoint, board b: RefBoard, size: CGSize) -> RGBA? {
        guard let item = item(at: p, board: b, size: size), let img = item.grayscale ? ReferenceImages.grayImage(item) : ReferenceImages.image(item) else { return nil }
        let r = item.frame.applying(transform(b, size: size))
        var u = (p.x - r.minX) / r.width, v = (p.y - r.minY) / r.height
        if item.flipH { u = 1 - u }
        if item.flipV { v = 1 - v }
        let px = clamp(Int(u * CGFloat(img.width)), 0, img.width - 1), py = clamp(Int(v * CGFloat(img.height)), 0, img.height - 1)
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // draw so that pixel (px, py) (top-left origin) lands on the single output pixel
        ctx.draw(img, in: CGRect(x: -CGFloat(px), y: -CGFloat(img.height - 1 - py), width: CGFloat(img.width), height: CGFloat(img.height)))
        guard let d = ctx.data?.assumingMemoryBound(to: UInt8.self), d[3] > 0 else { return nil }
        let a = Double(d[3])
        return RGBA(r: Double(d[0]) / a, g: Double(d[1]) / a, b: Double(d[2]) / a)
    }

    /// View that shows every item with a margin.
    static func fit(_ b: inout RefBoard, size: CGSize) {
        guard let first = b.items.first else { b.viewCenter = .zero; b.viewZoom = 1; return }
        let all = b.items.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        b.viewCenter = CGPoint(x: all.midX, y: all.midY)
        b.viewZoom = Double(clamp(min((size.width - 40) / max(1, all.width), (size.height - 40) / max(1, all.height)), 0.02, 8))
    }
}

// MARK: - Window

@Observable
final class RefBoardUIState {
    var scope: RefBoardScope = .global
    var selection: UUID?
    var eyedropper = false
    var clickThrough = false
    var windowOpacity: Double = 1
    var tick = 0
}

final class RefBoardView: NSView {
    let ui: RefBoardUIState
    private var drag: (mode: Int, start: CGPoint, item: RefItem?, view: (CGPoint, Double))?   // 0 pan, 1 move, 2 scale

    init(ui: RefBoardUIState) {
        self.ui = ui
        super.init(frame: CGRect(x: 0, y: 0, width: 420, height: 320))
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var doc: Document? { AppModel.shared.activeDocument }
    var board: RefBoard { ReferenceBoardStore.shared.board(ui.scope, doc: doc) }

    func update(_ name: String?, _ body: (inout RefBoard) -> Void) {
        ReferenceBoardStore.shared.update(ui.scope, doc: doc, name: name, body)
        needsDisplay = true
        ui.tick += 1
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = board
        RefBoardRenderer.draw(ctx, board: b, size: bounds.size, selection: ui.selection)
        if b.items.isEmpty {
            let msg = ui.scope == .document && doc == nil ? "No document open" : "Drop images here, or paste (⌘V)"
            let s = NSAttributedString(string: msg, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0.55, alpha: 1)])
            let sz = s.size()
            s.draw(at: CGPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2))
        }
    }

    private func boardPoint(_ v: CGPoint) -> CGPoint { v.applying(RefBoardRenderer.transform(board, size: bounds.size).inverted()) }

    func sample(_ v: CGPoint, background: Bool) {
        guard let c = RefBoardRenderer.color(at: v, board: board, size: bounds.size) else { return }
        let app = AppModel.shared
        if background { app.background = c } else { app.foreground = c }
        app.pushRecent(c)
        app.setStatus("Picked #\(c.hex) from the reference board")
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let v = convert(e.locationInWindow, from: nil)
        let b = board
        if ui.eyedropper || e.modifierFlags.contains(.option) {
            sample(v, background: e.modifierFlags.contains(.shift))
            drag = (3, v, nil, (b.viewCenter, b.viewZoom))
            return
        }
        let t = RefBoardRenderer.transform(b, size: bounds.size)
        if let sel = b.items.first(where: { $0.id == ui.selection }) {
            let r = sel.frame.applying(t)
            if CGPoint(x: r.maxX, y: r.maxY).distance(to: v) < 10 { drag = (2, v, sel, (b.viewCenter, b.viewZoom)); return }
        }
        if let item = RefBoardRenderer.item(at: v, board: b, size: bounds.size) {
            ui.selection = item.id
            if e.clickCount == 2 {       // double-click: bring to front
                update("Arrange Reference") { bb in if let i = bb.items.firstIndex(where: { $0.id == item.id }) { bb.items.append(bb.items.remove(at: i)) } }
            }
            drag = (1, v, item, (b.viewCenter, b.viewZoom))
        } else {
            ui.selection = nil
            if e.clickCount == 2 { update(nil) { RefBoardRenderer.fit(&$0, size: self.bounds.size) } }
            drag = (0, v, nil, (b.viewCenter, b.viewZoom))
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = drag else { return }
        let v = convert(e.locationInWindow, from: nil)
        let z = CGFloat(d.view.1)
        switch d.mode {
        case 0:
            update(nil) { $0.viewCenter = d.view.0 - (v - d.start) / z }
        case 1:
            guard let it = d.item else { return }
            update("Move Reference") { b in if let i = b.items.firstIndex(where: { $0.id == it.id }) { b.items[i].center = it.center + (v - d.start) / z } }
        case 2:
            guard let it = d.item else { return }
            let t = RefBoardRenderer.transform(board, size: bounds.size)
            let c = it.center.applying(t)
            let d0 = max(4, CGPoint(x: it.frame.maxX, y: it.frame.maxY).applying(t).distance(to: c))
            let k = Double(max(0.02, v.distance(to: c) / d0))
            update("Scale Reference") { b in if let i = b.items.firstIndex(where: { $0.id == it.id }) { b.items[i].scale = clamp(it.scale * k, 0.01, 40) } }
        default:
            sample(v, background: e.modifierFlags.contains(.shift))
        }
    }

    override func mouseUp(with e: NSEvent) { drag = nil }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.option) || e.modifierFlags.contains(.command) {
            zoom(by: pow(1.01, Double(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 1 : 5)), at: convert(e.locationInWindow, from: nil))
        } else {
            let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 12
            let z = CGFloat(board.viewZoom)
            update(nil) { $0.viewCenter = $0.viewCenter - CGPoint(x: e.scrollingDeltaX * k, y: e.scrollingDeltaY * k) / z }
        }
    }

    override func magnify(with e: NSEvent) { zoom(by: 1 + Double(e.magnification), at: convert(e.locationInWindow, from: nil)) }

    func zoom(by f: Double, at v: CGPoint) {
        let anchor = boardPoint(v)
        let size = bounds.size
        update(nil) { b in
            let nz = clamp(b.viewZoom * f, 0.02, 50)
            b.viewZoom = nz
            // keep `anchor` under the cursor
            b.viewCenter = CGPoint(x: anchor.x - (v.x - size.width / 2) / CGFloat(nz), y: anchor.y - (v.y - size.height / 2) / CGFloat(nz))
        }
    }

    /// The panel takes keyboard focus when the board is clicked (so ⌘V / ⌫ reach it) — except in eyedropper mode,
    /// where the document window keeps the keys for uninterrupted painting.
    override var needsPanelToBecomeKey: Bool { !ui.eyedropper }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, window?.firstResponder === self, e.modifierFlags.intersection([.command, .option, .control, .shift]) == .command else { return false }
        if e.charactersIgnoringModifiers == "v" { paste(); return true }
        return false
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 51 || e.keyCode == 117 { removeSelected(); return }
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "v" { paste(); return }
        if e.keyCode == 53 { ui.eyedropper = false; return }
        super.keyDown(with: e)
    }

    @objc func paste(_ sender: Any?) { paste() }

    func paste() {
        let imgs = ReferenceImages.images(from: .general)
        guard !imgs.isEmpty else { Beep.play(); return }
        add(imgs, at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func add(_ imgs: [(CGImage, String)], at v: CGPoint) {
        let ids = ReferenceBoardStore.shared.add(imgs, to: ui.scope, doc: doc, at: boardPoint(v), fitSide: 320 / CGFloat(max(0.05, board.viewZoom)))
        ui.selection = ids.last
        needsDisplay = true
        ui.tick += 1
    }

    func removeSelected() {
        guard let id = ui.selection else { return }
        update("Remove Reference") { $0.items.removeAll { $0.id == id } }
        ui.selection = nil
    }

    func modifySelected(_ name: String, _ body: (inout RefItem) -> Void) {
        guard let id = ui.selection else { return }
        update(name) { b in if let i = b.items.firstIndex(where: { $0.id == id }) { body(&b.items[i]) } }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let v = convert(event.locationInWindow, from: nil)
        if let it = RefBoardRenderer.item(at: v, board: board, size: bounds.size) { ui.selection = it.id; needsDisplay = true }
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector) { let i = NSMenuItem(title: title, action: sel, keyEquivalent: ""); i.target = self; m.addItem(i) }
        if ui.selection != nil {
            add("Flip Horizontal", #selector(menuFlipH)); add("Flip Vertical", #selector(menuFlipV)); add("Toggle Grayscale", #selector(menuGray))
            add("Opacity 100%", #selector(menuOpaque)); add("Opacity 50%", #selector(menuHalf))
            m.addItem(.separator())
            add("Remove", #selector(menuRemove))
            m.addItem(.separator())
        }
        add("Paste", #selector(paste(_:)))
        add("Fit All", #selector(menuFit))
        return m
    }
    @objc private func menuFlipH() { modifySelected("Flip Reference") { $0.flipH.toggle() } }
    @objc private func menuFlipV() { modifySelected("Flip Reference") { $0.flipV.toggle() } }
    @objc private func menuGray() { modifySelected("Reference Grayscale") { $0.grayscale.toggle() } }
    @objc private func menuOpaque() { modifySelected("Reference Opacity") { $0.opacity = 1 } }
    @objc private func menuHalf() { modifySelected("Reference Opacity") { $0.opacity = 0.5 } }
    @objc private func menuRemove() { removeSelected() }
    @objc private func menuFit() { update(nil) { RefBoardRenderer.fit(&$0, size: self.bounds.size) } }

    // Drag & drop
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let imgs = ReferenceImages.images(from: sender.draggingPasteboard)
        guard !imgs.isEmpty else { return false }
        add(imgs, at: convert(sender.draggingLocation, from: nil))
        return true
    }
}

/// Toolbar above the board.
struct RefBoardToolbar: View {
    @Bindable var ui: RefBoardUIState
    let view: RefBoardView
    let controller: ReferenceBoardController

    var body: some View {
        let _ = ui.tick
        let item = view.board.items.first { $0.id == ui.selection }
        HStack(spacing: 3) {
            Picker("", selection: Binding(get: { ui.scope }, set: { ui.scope = $0; ui.selection = nil; view.needsDisplay = true; controller.updateTitle() })) {
                Text("Global").tag(RefBoardScope.global)
                Text("Document").tag(RefBoardScope.document)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 124)
            IconButton(symbol: "plus", help: "Add images…") { controller.addFromFiles() }
            IconButton(symbol: "doc.on.clipboard", help: "Paste image (⌘V)") { view.paste() }
            IconButton(symbol: "eyedropper", help: "Pick colours from the references (or ⌥-click); ⇧ sets the background", active: ui.eyedropper) { ui.eyedropper.toggle() }
            Rectangle().fill(Theme.divider).frame(width: 1, height: 16)
            Group {
                IconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip horizontal") { view.modifySelected("Flip Reference") { $0.flipH.toggle() } }
                IconButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip vertical") { view.modifySelected("Flip Reference") { $0.flipV.toggle() } }
                IconButton(symbol: "circle.lefthalf.filled", help: "Grayscale", active: item?.grayscale ?? false) { view.modifySelected("Reference Grayscale") { $0.grayscale.toggle() } }
                Slider(value: Binding(get: { item?.opacity ?? 1 }, set: { v in view.modifySelected("Reference Opacity") { $0.opacity = max(0.05, v) } }), in: 0.05...1)
                    .frame(width: 44).help("Image opacity")
                IconButton(symbol: "trash", help: "Remove image (⌫)") { view.removeSelected() }
            }
            .disabled(item == nil).opacity(item == nil ? 0.4 : 1)
            Spacer(minLength: 0)
            Slider(value: Binding(get: { ui.windowOpacity }, set: { ui.windowOpacity = $0; controller.applyWindowState() }), in: 0.2...1).frame(width: 40).help("Window opacity")
            IconButton(symbol: "cursorarrow.rays", help: "Click-through: the window ignores the mouse (turn off from Window ▸ Reference Board Options)", active: ui.clickThrough) {
                controller.setClickThrough(!ui.clickThrough)
            }
        }
        .padding(.horizontal, 6).frame(height: 28)
        .background(Theme.panelHeader)
        .font(Theme.font).foregroundStyle(Theme.text)
    }
}

final class RefBoardPanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func close() { super.close(); onClose?() }
}

final class ReferenceBoardController {
    private(set) static var controllers: [ReferenceBoardController] = []

    let ui = RefBoardUIState()
    let panel: RefBoardPanel
    let view: RefBoardView

    init(scope: RefBoardScope, index: Int) {
        ui.scope = scope
        view = RefBoardView(ui: ui)
        panel = RefBoardPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
                              styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating                 // always on top of the document window
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = NSSize(width: 440, height: 200)
        let bar = NSHostingView(rootView: RefBoardToolbar(ui: ui, view: view, controller: self).environment(\.colorScheme, .dark).l10nRoot())
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 380))
        bar.frame = NSRect(x: 0, y: 352, width: 460, height: 28)
        bar.autoresizingMask = [.width, .minYMargin]
        view.frame = NSRect(x: 0, y: 0, width: 460, height: 352)
        view.autoresizingMask = [.width, .height]
        container.addSubview(view); container.addSubview(bar)
        panel.contentView = container
        let name = "Lumen.ReferenceBoard.\(index)"
        if !ArtistSupport.isSelfTest { panel.setFrameAutosaveName(name) }
        if ArtistSupport.isSelfTest || !panel.setFrameUsingName(name) {
            if let main = NSApp.mainWindow { panel.setFrameOrigin(NSPoint(x: main.frame.maxX - 500 - CGFloat(index * 24), y: main.frame.maxY - 470 - CGFloat(index * 24))) } else { panel.center() }
        }
        panel.onClose = { [weak self] in
            guard let self else { return }
            ReferenceBoardStore.shared.saveGlobalNow()
            ReferenceBoardController.controllers.removeAll { $0 === self }
            DispatchQueue.main.async { self.panel.contentView = nil }     // the toolbar holds the controller: break the cycle
        }
        updateTitle()
        observe()
    }

    func updateTitle() {
        switch ui.scope {
        case .global: panel.title = tr("Reference — Global")
        case .document: panel.title = tr("Reference — ") + (AppModel.shared.activeDocument?.name ?? tr("No Document"))
        }
    }

    /// Redraws when the active document changes or its state moves (undo / redo of board edits).
    private func observe() {
        withObservationTracking {
            _ = AppModel.shared.activeDocumentID
            _ = AppModel.shared.activeDocument?.revision
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, ReferenceBoardController.controllers.contains(where: { $0 === self }) else { return }
                self.view.needsDisplay = true
                self.ui.tick += 1
                self.updateTitle()
                self.observe()
            }
        }
    }

    func applyWindowState() {
        panel.alphaValue = CGFloat(ui.clickThrough ? min(ui.windowOpacity, 0.75) : ui.windowOpacity)
        panel.ignoresMouseEvents = ui.clickThrough
    }

    func setClickThrough(_ on: Bool) {
        ui.clickThrough = on
        applyWindowState()
        AppModel.shared.setStatus(on ? "Reference board is click-through — Window ▸ Reference Board Options ▸ Toggle Click-Through to turn it off" : "Reference board click-through off")
    }

    func addFromFiles() {
        let p = NSOpenPanel()
        p.allowedContentTypes = AppActions.openTypes
        p.allowsMultipleSelection = true
        p.begin { [weak self] r in
            guard let self, r == .OK else { return }
            let imgs = p.urls.compactMap { u in DocumentIO.loadImage(url: u).map { ($0.0, u.deletingPathExtension().lastPathComponent) } }
            if !imgs.isEmpty { self.view.add(imgs, at: CGPoint(x: self.view.bounds.midX, y: self.view.bounds.midY)) }
        }
    }

    // MARK: Menu entry points

    static func toggleMain() {
        if let c = controllers.first {
            if c.panel.isVisible && !c.ui.clickThrough { c.panel.orderOut(nil) } else { c.setClickThrough(false); c.panel.orderFront(nil) }
            return
        }
        openNew()
    }

    static func openNew() {
        let c = ReferenceBoardController(scope: controllers.isEmpty ? .global : .document, index: controllers.count)
        controllers.append(c)
        c.panel.orderFront(nil)
    }

    static func toggleClickThrough() {
        guard !controllers.isEmpty else { return }
        let on = !controllers.contains { $0.ui.clickThrough }
        for c in controllers { c.setClickThrough(on) }
    }

    static func pasteIntoFront() {
        if controllers.isEmpty { openNew() }
        controllers.first?.view.paste()
    }
}
