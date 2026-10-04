import AppKit

extension AppActions {
    /// File ▸ Place Embedded / Place Linked. The open panel also has a "Link to file" checkbox,
    /// so either command can switch mode; several files can be placed at once.
    static func placePanel(linked: Bool) {
        let p = NSOpenPanel()
        p.allowedContentTypes = openTypes + DocumentIO.extraOpenTypes
        p.allowsMultipleSelection = true
        p.prompt = "Place"
        let check = NSButton(checkboxWithTitle: "Link to file (updates when the file changes)", target: nil, action: nil)
        check.state = linked ? .on : .off
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 34))
        check.frame = NSRect(x: 12, y: 8, width: 340, height: 18)
        box.addSubview(check)
        p.accessoryView = box
        p.isAccessoryViewDisclosed = true
        p.message = linked ? "Place Linked: the smart object references the file on disk" : "Place Embedded: the file is copied into the document"
        guard UIBlock.run(p) == .OK, !p.urls.isEmpty else { return }
        place(p.urls, linked: check.state == .on)
    }

    /// Places files as smart objects (embedded or linked); a single placed file enters Free Transform like Photoshop.
    static func place(_ urls: [URL], linked: Bool) {
        guard doc != nil else {
            for u in urls { open(url: u) }
            return
        }
        for u in urls {
            if linked { placeLinked(u) } else { placeFile(u) }
        }
        if urls.count == 1, let c = canvas {
            c.commitCurrentTool()
            app.tool = .move
            (c.tool(for: .move) as? MoveTool)?.startTransform()
            app.setStatus("Placed “\(urls[0].lastPathComponent)” \(linked ? "(linked)" : "(embedded)") — adjust the size, then press Return.")
        }
    }
}
