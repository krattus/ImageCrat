import AppKit
import SwiftUI
import ImageCratCore

/// Offscreen snapshots of the module's dialogs and panels (`LUMEN_FILES_ONLY=ui`), for visual checks.
extension FilesSelfTest {
    static func snapshot<V: View>(_ view: V, size: CGSize, to url: URL) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).font(Theme.font).foregroundStyle(Theme.text)
            .frame(width: size.width, height: size.height).background(Theme.panelBG))
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        win.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        win.orderOut(nil)
    }

    static func testUI(_ dir: URL) {
        var st = SelfTest.baseState(320, 240)
        let shape = SelfTest.shapeLayer(CGRect(x: 20, y: 80, width: 80, height: 80))
        var t = TextContent(); t.text = "Title"; t.position = CGPoint(x: 20, y: 20)
        let text = Layer(name: "Title", content: .text(t))
        st.layers += [shape, text]
        var tl = VideoTimeline(duration: 4, frameRate: 30)
        var tr = LayerTrack(layerID: shape.id, start: 0.5, duration: 3)
        tr.setKeys(.position, [Keyframe(time: 0.5, value: .point(CGPoint(x: 60, y: 120))), Keyframe(time: 2, interpolation: .hold, value: .point(CGPoint(x: 200, y: 120))),
                               Keyframe(time: 3.2, interpolation: .ease, value: .point(CGPoint(x: 260, y: 60)))])
        tr.setKeys(.opacity, [Keyframe(time: 1, value: .number(1)), Keyframe(time: 3, value: .number(0.2))])
        tl.tracks = [tr, LayerTrack(layerID: text.id, duration: 4), LayerTrack(layerID: st.layers[0].id, duration: 4)]
        st.videoTimeline = tl
        let d = Document(state: st, name: "ui")
        AppModel.shared.add(d)
        VideoTimelineController.shared.expanded = [shape.id]
        VideoTimelineController.shared.setTime(d, 1.4, decodeVideo: false)
        snapshot(VideoTimelineView(doc: d), size: CGSize(width: 900, height: 250), to: dir.appendingPathComponent("ui_video_timeline.png"))
        snapshot(SaveForWebDialog(), size: CGSize(width: 920, height: 600), to: dir.appendingPathComponent("ui_save_for_web.png"))
        snapshot(ImageProcessorDialog(), size: CGSize(width: 540, height: 560), to: dir.appendingPathComponent("ui_image_processor.png"))
        snapshot(LayersToFilesDialog(), size: CGSize(width: 460, height: 320), to: dir.appendingPathComponent("ui_layers_to_files.png"))
        snapshot(RenderVideoDialog(), size: CGSize(width: 440, height: 260), to: dir.appendingPathComponent("ui_render_video.png"))
        snapshot(VariablesDefineDialog(doc: d), size: CGSize(width: 480, height: 360), to: dir.appendingPathComponent("ui_variables.png"))
        ScriptConsole.shared.append("› app.activeDocument.name")
        ScriptConsole.shared.append("→ ui")
        snapshot(ScriptConsolePanel(), size: CGSize(width: 300, height: 220), to: dir.appendingPathComponent("ui_console.png"))
        AppModel.shared.close(d)
        if let img = try? DICOM.read(url: dir.appendingPathComponent("ct16_implicit.dcm")) {
            let dd = DICOM.makeDocument(img, name: "ct")
            AppModel.shared.add(dd)
            if let e = DICOMStore.shared.entries[dd.id] {
                snapshot(DICOMWindowLevelDialog(doc: dd, entry: e), size: CGSize(width: 440, height: 260), to: dir.appendingPathComponent("ui_dicom_wl.png"))
            }
            AppModel.shared.close(dd)
        }
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ui_video_timeline.png").path), "UI snapshots written")
    }
}
