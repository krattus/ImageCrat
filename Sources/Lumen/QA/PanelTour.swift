import AppKit
import SwiftUI
import ImageCratCore

/// Real-window check of panel sizes: `LUMEN_PANEL_TOUR=<dir> Lumen` opens the app as usual, then shows every
/// registered panel in turn in its dock group (Essentials; panels of no stock workspace go where Window ▸ <panel> puts
/// them) at the default column width, at the minimum column width and in a short group, saves a `cacheDisplay` capture
/// of the group for each (`<panel>_<size>.png`, plus `<panel>_<size>_layers.png` drawn through the layer tree) and a
/// table of frames and sizes (`table.txt`) to `<dir>`, and quits.
/// It uses a temporary workspace store (the saved layout is untouched) and does nothing unless the variable is set.
enum PanelTour {
    static var requestedDir: URL? {
        guard let p = ProcessInfo.processInfo.environment["LUMEN_PANEL_TOUR"], !p.isEmpty else { return nil }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }

    private static var observer: NSObjectProtocol?

    static func installIfRequested() {
        guard let dir = requestedDir, !WorkspaceManager.isSelfTest, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            if let o = observer { NotificationCenter.default.removeObserver(o) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { start(dir, attempt: 0) }
        }
    }

    /// Waits for the main window's dock, runs the tour, writes the table and quits.
    private static func start(_ dir: URL, attempt: Int) {
        let dock = NSApp.windows.lazy.filter(\.isVisible).compactMap { $0.contentView.flatMap { Workspace2SelfTest.find(DockAreaView.self, in: $0).first } }.first
        guard let dock, let win = dock.window else {
            if attempt < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { start(dir, attempt: attempt + 1) } }
            else { print("PANEL TOUR: no main window with panels"); NSApp.terminate(nil) }
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppModel.shared
        app.dialog = nil
        app.showPanels = true
        var text = "ImageCrat panel tour — window \(Int(win.frame.width))×\(Int(win.frame.height)), scale \(win.backingScaleFactor), \(Date())\n"
        WorkspaceManager.shared.withStore(MemoryWorkspaceStore()) {
            let rows = run(dock: dock, out: dir, panels: PanelRegistry.defs.map(\.id), settle: 0.35)
            text += table(rows)
        }
        try? text.write(to: dir.appendingPathComponent("table.txt"), atomically: true, encoding: .utf8)
        print("PANEL TOUR COMPLETE: \(dir.path)")
        NSApp.terminate(nil)
    }

    struct Shot {
        var row: PanelMetrics.Row
        var hostFrame: CGRect
        var areaInWindow: CGRect
        var fitting: CGSize
        var minimum: CGSize
        var file: String
    }

    /// Shows each panel in its group of `dock` at the default width, the minimum width and in a short group; captures
    /// the group and measures it. (Self tests run it on an offscreen window.)
    static func run(dock: DockAreaView, out: URL, panels: [String], settle: Double) -> [Shot] {
        let ws = WorkspaceManager.shared
        var shots: [Shot] = []
        ws.apply(.essentials)
        AppModel.shared.showSecondaryPanels = true
        UIFixesSelfTest.spin(settle)
        for id in panels where PanelRegistry.def(id) != nil {
            ws.reveal(id)
            UIFixesSelfTest.spin(0.05)
            guard case .docked(let ci, let gi)? = ws.current.path(ofPanel: id) else { continue }
            let col = ws.current.columns[ci]
            let gid = col.groups[gi].id
            let steps: [(String, () -> Void)] = [
                ("default", { ws.setColumnWidth(column: col.id, col.width) }),
                ("min-width", { ws.setColumnWidth(column: col.id, DockMetrics.minColumnWidth) }),
                ("short", { ws.setColumnWidth(column: col.id, col.width); shortGroup(gid, in: col.id, dock: dock) }),
            ]
            for (name, apply) in steps {
                apply()
                UIFixesSelfTest.spin(settle)
                guard let gv = dock.groupView(gid), !gv.content.isHidden else { continue }
                let host = ws.host(id)
                let row = PanelMetrics.measure(id, in: gv.content, context: name)
                let file = PanelMetrics.fileName(id) + "_" + name + ".png"
                PanelMetrics.capture(gv, to: out.appendingPathComponent(file))
                // (and drawn through the layer tree, in case cacheDisplay leaves SwiftUI's layers out)
                PanelMetrics.snapshot(gv, to: out.appendingPathComponent(PanelMetrics.fileName(id) + "_" + name + "_layers.png"))
                shots.append(Shot(row: row, hostFrame: host.frame, areaInWindow: gv.content.convert(gv.content.bounds, to: nil), fitting: host.fittingSize,
                                  minimum: PanelMetrics.minimum(id, width: gv.content.bounds.width), file: file))
            }
            ws.apply(.essentials)
            UIFixesSelfTest.spin(0.05)
        }
        return shots
    }

    /// Gives group `gid` about 150 pt (the other expanded groups of its column share the rest).
    static func shortGroup(_ gid: String, in cid: String, dock: DockAreaView) {
        let ws = WorkspaceManager.shared
        guard let ci = ws.current.columnIndex(cid), let cv = dock.columnView(cid) else { return }
        dock.layoutSubtreeIfNeeded()
        let gs = ws.current.columns[ci].groups
        let heights = cv.laidOutHeights
        let expanded = gs.indices.filter { !gs[$0].collapsed }
        guard expanded.count > 1, heights.count == gs.count, let k = gs.firstIndex(where: { $0.id == gid }) else { return }
        let rest = expanded.reduce(0) { $0 + heights[$1] }
        let target: CGFloat = 150
        var w = ws.current
        for i in expanded { w.columns[ci].groups[i].height = i == k ? target : max(1, (rest - target) / CGFloat(expanded.count - 1)) }
        ws.current = w
    }

    static func table(_ shots: [Shot]) -> String {
        func s(_ z: CGSize) -> String { "\(Int(z.width.rounded()))×\(Int(z.height.rounded()))" }
        var t = PanelMetrics.Row.header + "   host frame        area in window         fitting     min height   doc          file\n"
        for x in shots {
            t += x.row.line + "   " + PanelMetrics.fmt(x.hostFrame) + "   " + PanelMetrics.fmt(x.areaInWindow) + "   " + s(x.fitting) + "   " + s(x.minimum)
                + "   " + (x.row.document.map(s) ?? "-") + "   " + x.file + "\n"
        }
        let bad = shots.filter { !$0.row.ok }
        t += "\n\(shots.count) captures, \(bad.count) cropped or with a bad frame" + (bad.isEmpty ? "" : ": " + bad.map { "\($0.row.panel) (\($0.row.context))" }.joined(separator: ", ")) + "\n"
        return t
    }
}
