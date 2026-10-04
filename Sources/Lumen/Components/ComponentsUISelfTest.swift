import AppKit
import SwiftUI
import ImageCratCore

/// Offscreen snapshots of the module's panels and dialogs (`LUMEN_SELFTEST_UI=1` or `LUMEN_COMPONENTS_ONLY=ui`).
enum ComponentsUISelfTest {
    static func run(_ dir: URL) {
        let app = AppModel.shared
        let h = ClipboardHistory.shared
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally(); h.pasteboard = .general; h.resetForTesting() }
        h.pasteboard = pb
        h.resetForTesting()

        // Document with two components (one with variants), three instances, overrides
        let (d, s1, l1, i1) = ComponentsSelfTest.buttonDoc(640, 440)
        app.add(d)
        app.activeDocumentID = d.id
        d.selectedLayerIDs = [s1, l1, i1]; d.activeLayerID = i1
        guard let cid = ComponentActions.createComponent(d, name: "Button") else { return }
        let inst = d.activeLayerID!
        let m = d.state.components[cid]!
        let i2 = ComponentActions.insertInstance(d, component: cid, center: CGPoint(x: 430, y: 120))!
        _ = ComponentActions.insertInstance(d, component: cid, center: CGPoint(x: 200, y: 300))
        let hover = ComponentActions.addVariant(d, component: cid, name: "Hover")!
        var hv = DocumentState(width: m.width, height: m.height)
        hv.layers = m.layers
        hv.layers.update(s1) { l in if var s = l.shape { s.fill = .color(RGBA(hex: "F59F00")!); l.shape = s } }
        ComponentActions.commitMain(parent: d, component: cid, variant: hover, edited: hv)
        _ = ComponentActions.addVariant(d, component: cid, name: "Disabled")
        var card = SelfTest.shapeLayer(CGRect(x: 380, y: 250, width: 200, height: 130), RGBA(hex: "0CA678")!, radius: 18)
        card.name = "Card"
        d.addLayer(card); d.commit("Card")
        d.selectLayer(card.id)
        let cardID = ComponentActions.createComponent(d, name: "Card")
        ComponentActions.setText(d, layer: i2, inner: m.layers[1], "Cancel")
        ComponentActions.setColor(d, layer: i2, inner: m.layers[0], kind: .fill, RGBA(hex: "444B59")!)
        ComponentActions.setVisible(d, layer: i2, inner: m.layers[2], false)
        ComponentActions.setTint(d, layer: inst, ComponentTint(color: RGBA(hex: "00A8E8")!, amount: 0.4))
        if let lib = try? ComponentLibraries.create(named: "Brand Kit") {
            var st = d.state
            _ = try? ComponentLibraries.publish(cid, from: &st, to: lib)
            if let c2 = cardID { _ = try? ComponentLibraries.publish(c2, from: &st, to: lib) }
            d.state = st
            d.commit("Save to Library")
            ComponentsPanelState.shared.libraryURL = lib
        }
        ComponentsPanelState.shared.selected = cid
        ComponentsPanelState.shared.showLibrary = false
        FilesSelfTest.snapshot(ComponentsPanel(), size: CGSize(width: 300, height: 330), to: dir.appendingPathComponent("ui_components_panel.png"))
        ComponentsPanelState.shared.showLibrary = true
        ComponentsPanelState.shared.librarySelected = cid
        FilesSelfTest.snapshot(ComponentsPanel(), size: CGSize(width: 300, height: 330), to: dir.appendingPathComponent("ui_components_library.png"))
        ComponentsPanelState.shared.showLibrary = false

        d.selectLayer(i2)
        FilesSelfTest.snapshot(PropertiesPanel(), size: CGSize(width: 300, height: 640), to: dir.appendingPathComponent("ui_instance_properties.png"))
        FilesSelfTest.snapshot(LayersPanel(), size: CGSize(width: 300, height: 260), to: dir.appendingPathComponent("ui_layers_badges.png"))

        // Clipboard history with one item of each kind
        h.recordLayers([d.state.layer(i2)!], from: d.state)
        var pix = ClipItem(kind: .pixels, title: "x"); pix.buffer = nil
        d.state.selection = PixelBuffer(width: d.state.width, height: d.state.height, gray: 255)
        h.record(copyOf: d, buffer: ComponentsSelfTest.photo(120, 80, "FF6B6B", "FFD93D"), origin: IPoint(x: 10, y: 10), merged: false)
        d.state.selection = nil
        h.recordText("Headline copied from the design")
        h.recordColor(RGBA(hex: "E94F37")!)
        var fx = LayerEffects(); fx.dropShadow.enabled = true; fx.stroke.enabled = true; fx.stroke.size = 5; fx.stroke.paint = .color(RGBA(hex: "FFD166")!)
        fx.gradientOverlay.enabled = true; fx.gradientOverlay.fill.gradient = ColorGradient.presets[7]
        h.recordStyle(fx, name: "Card")
        h.recordShape(ShapeContent(geometry: .polygon(CGRect(x: 0, y: 0, width: 120, height: 120), sides: 5, starRatio: 0.45), fill: .color(RGBA(hex: "06D6A0")!)), name: "Star")
        pb.clearContents(); pb.setData(ComponentsSelfTest.photo(160, 100, "845EC2", "FF9671").pngData()!, forType: .png)
        h.poll(external: true)
        pb.clearContents(); pb.setString("A quote copied in another app while Lumen was in front.", forType: .string)
        h.poll(external: true)
        if let first = h.items.last { h.togglePin(first.id) }
        ClipboardPanelState.shared.selected = h.items.first { $0.kind == .style }?.id
        FilesSelfTest.snapshot(ClipboardPanel(), size: CGSize(width: 300, height: 470), to: dir.appendingPathComponent("ui_clipboard_panel.png"))
        let ps = ClipboardPopupState()
        ps.items = h.items
        ps.index = 2
        FilesSelfTest.snapshot(ClipboardPopupView(state: ps, choose: { _, _ in }).padding(10), size: CGSize(width: 340, height: 400), to: dir.appendingPathComponent("ui_clipboard_popup.png"))
        h.clear(includingPinned: true)

        // HTML export dialog on the sample design
        let web = Document(state: HTMLExportSelfTest.sampleDesign(), name: "Landing Page.imagecrat")
        app.add(web)
        app.activeDocumentID = web.id
        HTMLExportModel.lastOptions = nil
        let model = HTMLExportModel()
        model.tab = 3
        model.start()
        let host = NSHostingView(rootView: HTMLExportDialog(injected: model).environment(\.colorScheme, .dark).font(Theme.font).foregroundStyle(Theme.text)
            .padding(.top, 14).frame(width: 1032, height: 600).background(Theme.panelBG))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1032, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        win.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        // give the live preview and the visual diff time to finish
        let end = Date().addingTimeInterval(6)
        while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("ui_html_export_dialog.png"))
        }
        win.orderOut(nil)
        app.close(web)
        app.close(d)
        let names = ["ui_components_panel", "ui_components_library", "ui_instance_properties", "ui_layers_badges", "ui_clipboard_panel", "ui_clipboard_popup", "ui_html_export_dialog"]
        let ok = names.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0 + ".png").path) }
        ComponentsSelfTest.check(ok, "ui: snapshots of the Components panel, library, instance properties, Clipboard History, popup and HTML export dialog written")
    }
}
