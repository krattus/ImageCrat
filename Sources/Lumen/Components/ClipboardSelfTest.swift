import AppKit
import CoreImage
import ImageCratCore

/// Clipboard History tests. They use a private pasteboard and a scratch support folder — never the user's clipboard.
enum ClipboardSelfTest {
    static func check(_ ok: Bool, _ msg: @autoclosure () -> String) { ComponentsSelfTest.check(ok, "clipboard: " + msg()) }

    static func run(_ dir: URL) {
        let app = AppModel.shared
        let h = ClipboardHistory.shared
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        h.pasteboard = pb
        h.resetForTesting()
        h.lastChangeCount = pb.changeCount
        let savedEffects = AppActions.copiedEffects
        check(!h.persistAll && h.usesUserDefaults == false, "defaults: history is not persisted (privacy) and tests do not touch user defaults")
        check(h.fileURL.path.hasPrefix(ComponentsSupport.directory.path) && !h.fileURL.path.contains("Library/Application Support"), "history file lives under the test support folder")

        // A document with a text layer, a shape, a raster and a component instance
        let (d, shapeID, labelID, iconID) = ComponentsSelfTest.buttonDoc(520, 360)
        app.add(d)
        app.activeDocumentID = d.id

        // 1. Internal copies of each kind
        d.selectLayer(labelID)
        let buf1 = PixelBuffer(width: 90, height: 28)
        let itText = h.record(copyOf: d, buffer: buf1, origin: IPoint(x: 112, y: 58), merged: false, changeCount: pb.changeCount)
        check(itText.kind == .layers && itText.layers?.first?.text?.text == "Buy now", "copy of a whole layer keeps the live layer (type stays type)")

        d.selectedLayerIDs = [shapeID, labelID, iconID]; d.activeLayerID = iconID
        let cid = ComponentActions.createComponent(d, name: "Button")!
        let instID = d.activeLayerID!
        let itInst = h.record(copyOf: d, buffer: PixelBuffer(width: 220, height: 64), origin: IPoint(x: 40, y: 40), merged: false)
        check(itInst.kind == .layers && itInst.layers?.first?.isComponentInstance == true && itInst.masters?.first?.id == cid, "copy of a component instance carries its main component")
        check(itInst.subtitle.contains("Component instance"), "instance item is labelled (\(itInst.subtitle))")

        d.state.selection = SelectionOps.mask(fromPath: CGPath(rect: CGRect(x: 60, y: 50, width: 100, height: 40), transform: nil), width: d.state.width, height: d.state.height)
        let selBuf = ComponentsSelfTest.photo(100, 40, "FF6B6B", "FFD93D")
        let itPix = h.record(copyOf: d, buffer: selBuf, origin: IPoint(x: 60, y: 50), merged: false)
        check(itPix.kind == .pixels && itPix.origin == IPoint(x: 60, y: 50), "copy with a selection is a pixel item (origin kept for Paste in Place)")
        d.state.selection = nil
        let itMerged = h.record(copyOf: d, buffer: ComponentsSelfTest.photo(64, 64, "4D96FF", "6BCB77"), origin: .zero, merged: true)
        check(itMerged.kind == .pixels && itMerged.title == "Merged copy", "Copy Merged is a pixel item")

        pb.clearContents(); pb.setString("Headline copied inside Lumen", forType: .string)
        h.poll(external: false)
        check(h.items.first?.kind == .text && h.items.first?.fromLumen == true, "text copied while Lumen is frontmost is recorded as from Lumen")

        h.copyColor(RGBA(hex: "E94F37")!)
        check(h.items.first?.kind == .color && pb.string(forType: .string) == "#E94F37", "Copy Foreground Colour as Hex: colour item + hex on the pasteboard")
        let n0 = h.items.count
        h.poll(external: false)
        check(h.items.count == n0, "our own pasteboard write is not recorded twice")

        var fx = LayerEffects(); fx.dropShadow.enabled = true; fx.stroke.enabled = true; fx.stroke.size = 4; fx.stroke.paint = .color(RGBA(hex: "1B1F3A")!)
        AppActions.copiedEffects = fx
        h.poll(external: false)
        check(h.items.first?.kind == .style && h.items.first?.style == fx, "Copy Layer Style is recorded as a style item")

        let star = ShapeContent(geometry: .polygon(CGRect(x: 300, y: 200, width: 120, height: 120), sides: 5, starRatio: 0.45), fill: .color(RGBA(hex: "F6AE2D")!))
        var starLayer = Layer(name: "Star", content: .shape(star))
        starLayer.id = UUID()
        d.addLayer(starLayer); d.commit("Star")
        WebCopyCommands.copySVG()
        check(h.items.first?.kind == .path && (pb.string(forType: .string) ?? "").hasPrefix("<svg"), "Copy as SVG: shape item + SVG markup on the pasteboard")
        let kinds = Set(h.items.map(\.kind))
        check(kinds.isSuperset(of: [.layers, .pixels, .text, .color, .style, .path]), "internal kinds recorded: \(kinds.map(\.rawValue).sorted())")

        // 2. External items (copied in another app, seen when Lumen becomes active)
        pb.clearContents()
        pb.setData(ComponentsSelfTest.photo(80, 60, "845EC2", "FF9671").pngData()!, forType: .png)
        h.poll(external: true)
        check(h.items.first?.kind == .image && h.items.first?.fromLumen == false && h.items.first?.buffer?.width == 80, "external image is recorded (from another app)")
        pb.clearContents(); pb.setString("A sentence copied in another app.", forType: .string)
        h.poll(external: true)
        check(h.items.first?.kind == .text && h.items.first?.fromLumen == false, "external text is recorded")
        pb.clearContents(); pb.setString("rgb(12, 166, 120)", forType: .string)
        h.poll(external: true)
        check(h.items.first?.kind == .color && h.items.first?.color?.hex == "0CA678", "external colour code becomes a colour item (#\(h.items.first?.color?.hex ?? ""))")

        // 3. Concealed / secret items are never stored
        var before = h.items.count
        pb.clearContents()
        pb.setString("correct horse battery staple", forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        h.poll(external: true)
        check(h.items.count == before, "concealed pasteboard item (password manager) is skipped")
        pb.clearContents()
        pb.setString("plain words", forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        h.poll(external: false)
        check(h.items.count == before, "transient pasteboard item is skipped even inside Lumen")
        let secrets = ["hunter2!Xq9", "sk-proj-A1b2C3d4E5f6G7h8I9j0", "ghp_16C7e42F292c6912E7710c838347Ae178B4a", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc", "482913",
                       "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08", "password=opensesame", "-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----"]
        var leaked: [String] = []
        for s in secrets {
            pb.clearContents(); pb.setString(s, forType: .string)
            h.poll(external: true)
            if h.items.count != before { leaked.append(s); before = h.items.count }
        }
        check(leaked.isEmpty, "secret-looking text from other apps is not stored (\(secrets.count) samples\(leaked.isEmpty ? "" : ", leaked: \(leaked)"))")
        let harmless = ["https://example.com/docs/page", "Lorem ipsum dolor sit amet", "IMG_2041.png", "hello@example.com", "1920", "Helvetica-Bold", "#FFAA00"]
        let wrong = harmless.filter { ClipboardHistory.looksSecret($0) }
        check(wrong.isEmpty, "ordinary text is not mistaken for a secret\(wrong.isEmpty ? "" : ": \(wrong)")")
        pb.clearContents(); pb.setString("hunter2!Xq9", forType: .string)
        h.poll(external: false)
        check(h.items.first?.text == "hunter2!Xq9", "the same text copied inside Lumen is kept (it came from the document)")

        // 4. De-duplication and the size cap
        let cnt = h.items.count
        h.recordText("Headline copied inside Lumen")
        check(h.items.count == cnt && h.items.first?.text == "Headline copied inside Lumen", "re-copying the same thing moves it to the top instead of duplicating")
        let pinID = itInst.id
        h.togglePin(pinID)
        h.togglePin(h.items.first { $0.kind == .color && $0.color?.hex == "E94F37" }!.id)
        h.maxItems = 6
        for i in 0..<10 { h.recordText("filler \(i)") }
        let unpinned = h.items.filter { !$0.pinned }.count
        check(unpinned == 6 && h.items.filter(\.pinned).count == 2, "size cap: \(unpinned) unpinned items kept (max 6), pinned items are exempt")
        check(h.item(pinID) != nil, "a pinned item survives the cap")

        // 5. Persistence: pinned only by default
        h.save()
        check(FileManager.default.fileExists(atPath: h.fileURL.path), "pinned items are written to disk")
        let perms = (try? FileManager.default.attributesOfItem(atPath: h.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue
        check(perms == 0o600, "history file is private (mode \(String(perms ?? 0, radix: 8)))")
        h.resetForTesting()
        h.load()
        check(h.items.count == 2 && h.items.allSatisfy(\.pinned), "after a relaunch only the pinned items come back (\(h.items.count))")
        let back = h.item(pinID)
        check(back?.layers?.first?.isComponentInstance == true && back?.masters?.first?.id == cid, "a persisted layer item round-trips with its component")
        h.recordText("kept between launches")
        h.persistAll = true
        h.resetForTesting(); h.load()
        check(h.items.count == 3, "with “Keep History Between Launches” everything is restored (\(h.items.count))")
        h.persistAll = false
        h.resetForTesting(); h.load()
        check(h.items.count == 2, "switching it off again removes the unpinned items from disk")

        // 6. Paste modes
        let target = Document.newBlank(width: 480, height: 320, background: RGBA(hex: "F8F9FA"), name: "paste-target")
        app.add(target)
        app.activeDocumentID = target.id
        check(h.paste(pinID, mode: .newLayer, into: target), "paste as new layer: layer item")
        let pasted = target.activeLayer
        check(pasted?.isComponentInstance == true && target.state.components[cid] != nil, "pasted instance is live in the other document (main component copied)")
        check(pasted?.id != instID, "pasted layers get new ids")
        let textItem = h.recordLayers([d.state.components[cid]!.layers[1]], from: d.state)
        _ = textItem
        let pixID = h.record(copyOf: { d.state.selection = PixelBuffer(width: d.state.width, height: d.state.height, gray: 255); return d }(), buffer: selBuf, origin: IPoint(x: 300, y: 40), merged: false).id
        d.state.selection = nil
        check(h.paste(pixID, mode: .inPlace, into: target) && target.activeLayer?.raster?.origin == IPoint(x: 300, y: 40), "paste in place: pixels land at their original position")
        target.state.selection = SelectionOps.mask(fromPath: CGPath(ellipseIn: CGRect(x: 40, y: 200, width: 120, height: 90), transform: nil), width: 480, height: 320)
        check(h.paste(pixID, mode: .intoSelection, into: target), "paste into selection")
        let into = target.activeLayer
        check(into?.mask != nil && target.state.selection == nil && into?.raster?.origin == IPoint(x: 50, y: 225), "paste into: new layer masked by the selection, centred in it (\(into?.raster?.origin.x ?? 0),\(into?.raster?.origin.y ?? 0))")
        let styleID = h.recordStyle(fx, name: "Card").id
        target.selectLayer(pasted!.id)
        check(h.paste(styleID, mode: .style, into: target) && target.state.layer(pasted!.id)?.effects == fx, "paste style onto the selected layer")
        let tID = h.recordText("Pasted headline").id
        check(h.paste(tID, mode: .newLayer, into: target) && target.activeLayer?.text?.text == "Pasted headline", "paste text as a type layer")
        let cItem = h.recordColor(RGBA(hex: "7048E8")!)
        check(h.paste(cItem.id, mode: .newLayer, into: target) && app.foreground == RGBA(hex: "7048E8")!, "paste colour sets the foreground colour")
        let sID = h.recordShape(star, name: "Star").id
        check(ComponentCommands.handleDrop(string: ClipboardHistory.dragPrefix + sID.uuidString, doc: target, at: CGPoint(x: 400, y: 250)), "drag a history item onto the canvas")
        let dropped = target.activeLayer
        check(dropped?.isShape == true && abs((dropped?.shape?.path.bounds.midX ?? 0) - 400) < 1.5, "dropped shape is centred at the drop point")
        check(ClipboardHistory.modes(for: h.item(sID)!) == [.newLayer] && ClipboardHistory.modes(for: h.item(pixID)!).contains(.intoSelection), "paste modes depend on the item kind")

        // ⌘V hook: a live layer copy pastes as a layer, a plain pixel layer falls through to the normal paste
        pb.clearContents(); pb.setString("marker", forType: .string)
        let live = h.record(copyOf: { d.selectLayer(instID); return d }(), buffer: PixelBuffer(width: 10, height: 10), origin: .zero, merged: false, changeCount: pb.changeCount)
        _ = live
        let countBefore = target.state.allLayers.count
        check(h.handlePaste(inPlace: false) && target.state.allLayers.count == countBefore + 1 && target.activeLayer?.isComponentInstance == true, "⌘V pastes a copied instance as an instance")
        let bgOnly = Document.newBlank(width: 60, height: 40, background: .white, name: "plain")
        app.add(bgOnly); app.activeDocumentID = bgOnly.id
        _ = h.record(copyOf: bgOnly, buffer: PixelBuffer(width: 60, height: 40), origin: .zero, merged: false, changeCount: pb.changeCount)
        check(!h.handlePaste(inPlace: false), "⌘V of a plain pixel layer keeps the standard pixel paste")
        app.close(bgOnly)
        pb.clearContents(); pb.setString("newer", forType: .string)
        check(!h.handlePaste(inPlace: false), "⌘V ignores the history once the system clipboard changed")

        ComponentsSelfTest.save(target.state, "clip01_pasted", dir)
        let thumbs = h.items.filter { h.thumbnail($0) != nil }.count
        check(thumbs >= 3, "thumbnails rendered for image / layer / style / shape items (\(thumbs))")

        // 7. Clear
        h.clear()
        check(h.items.allSatisfy(\.pinned) && !h.items.isEmpty, "Clear History keeps the pinned items")
        h.clear(includingPinned: true)
        check(h.items.isEmpty && !FileManager.default.fileExists(atPath: h.fileURL.path), "Clear History and Pinned Items empties the history and removes the file")

        AppActions.copiedEffects = savedEffects
        h.maxItems = 25
        h.resetForTesting()
        h.pasteboard = .general
        h.lastChangeCount = NSPasteboard.general.changeCount
        app.close(target)
        app.close(d)
    }
}
