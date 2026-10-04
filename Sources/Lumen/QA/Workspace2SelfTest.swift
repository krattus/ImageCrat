import AppKit
import SwiftUI
import ImageCratCore

/// Panel workspace: the layout model (dock, undock, tab, reorder, split, resize, collapse, icon columns), named workspaces
/// (save / load / delete / reset, persistence, old saved layouts), recovery of off-screen panels, no document history or
/// dirty flag from layout changes, `PendingEdits.clickIsInPanel` with the new columns and floating windows, keyboard
/// focus after panel interactions, and the status-bar chips. Views run in the real `MainView` hosted in offscreen windows
/// and are driven with mouse events; every store is temporary (memory or a throw-away defaults suite).
/// `LUMEN_SELFTEST_ONLY=workspace2 Lumen --selftest <dir>`
enum Workspace2SelfTest {
    static func register() { FeatureModules.selfTests.append(("workspace2", { run($0) })) }

    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") workspace2: \(name)\(d.isEmpty ? "" : " — " + d)")
        fflush(stdout)
    }

    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    static let g3 = "ess.c2.g3"           // Layers / Channels / Paths
    static let legacyJSON = #"{"name":"Graphic and Web","primary":[["color"],["layers","channels"]],"secondary":[["history"]],"showSecondary":false,"floating":["navigator"]}"#

    static func run(_ out: URL) {
        passes = 0; failures = 0
        let dir = out.appendingPathComponent("workspace2")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testDockPaintsInsideItsBounds()
        let app = AppModel.shared
        let saved = (canvas: AppActions.canvas, docs: app.documents, active: app.activeDocumentID, tool: app.tool, panels: app.showPanels,
                     secondary: app.showSecondaryPanels, theme: app.prefs.theme, dialog: app.dialog, hook: app.toolChanged, cursor: app.cursorDocPoint)
        defer {
            app.dialog = nil
            AppActions.canvas = saved.canvas; app.documents = saved.docs; app.activeDocumentID = saved.active; app.tool = saved.tool
            app.showPanels = saved.panels; app.showSecondaryPanels = saved.secondary
            if app.prefs.theme != saved.theme { app.prefs.theme = saved.theme }
            app.toolChanged = saved.hook; app.cursorDocPoint = saved.cursor
            UIFixesSelfTest.spin(0.1)
        }
        app.dialog = nil
        app.showPanels = true; app.showSecondaryPanels = true
        model()
        geometry()
        // a throw-away defaults suite (the user's saved layout is never read or written)
        let suite = "LumenWorkspace2SelfTest"
        if let ud = UserDefaults(suiteName: suite) {
            ud.removePersistentDomain(forName: suite)
            let store = DefaultsWorkspaceStore(ud)
            WorkspaceManager.shared.withStore(store) {
                persistence(store)
                noDocumentChanges()
            }
            ud.removePersistentDomain(forName: suite)
        } else {
            check(false, "temporary defaults suite")
        }
        WorkspaceManager.shared.withStore(MemoryWorkspaceStore()) {
            views(dir)
        }
        UIFixesSelfTest.spin(0.1)
        check(WorkspaceManager.shared.windows.isEmpty == WorkspaceManager.shared.current.floating.isEmpty, "test windows closed with the test layout")
        chips(dir)
        print("workspace2: \(passes) passed, \(failures) failed")
    }

    // MARK: - Layout model

    static func model() {
        let e = Workspace.essentials
        check(e.columns.count == 2 && e.primary == [["color", "swatches", "gradients", "patterns"], ["properties", "adjustments", "character", "paragraph"], ["layers", "channels", "paths"]]
              && e.secondary == [["navigator", "histogram", "info"], ["history", "brushes", "brushSettings", "actions", "layerComps"]] && e.columns.map(\.width) == [230, 300],
              "Essentials: the same two columns and groups as before (230 + 300 pt)")
        check(Workspace.builtIn.map(\.name) == ["Essentials", "Photography", "Painting", "Typography", "Web/UI"], "stock workspaces", Workspace.builtIn.map(\.name).joined(separator: ", "))
        for b in Workspace.builtIn {
            var c = b
            c.sanitize()
            let missing = b.allPanels.filter { PanelRegistry.def($0) == nil }
            check(c == b && missing.isEmpty && Set(b.allPanels).count == b.allPanels.count, "\(b.name): valid, no duplicates, every panel registered", missing.joined(separator: ","))
        }
        let lw = try? JSONDecoder().decode(Workspace.self, from: Data(legacyJSON.utf8))
        check(lw?.primary == [["color"], ["layers", "channels"]] && lw?.secondary == [["history"]] && lw?.floatingIDs == ["navigator"] && lw?.showSecondary == false
              && lw?.columns.map(\.width) == [230, 300], "old saved layouts (primary / secondary / floating ids) still load")
        let back = (try? JSONEncoder().encode(e)).flatMap { try? JSONDecoder().decode(Workspace.self, from: $0) }
        check(back == e, "a layout survives encode / decode unchanged")

        // reorder tabs
        var w = e
        w.move(["paths"], to: .tab(group: g3, index: 0))
        check(w.group(g3)?.panels == ["paths", "layers", "channels"] && w.group(g3)?.selected == "paths", "reorder: a tab dragged to the front (and selected)")
        w.move(["paths"], to: .tab(group: g3, index: 3))
        check(w.group(g3)?.panels == ["layers", "channels", "paths"], "reorder: to the end", "\(w.group(g3)?.panels ?? [])")
        w.move(["layers"], to: .tab(group: g3, index: 2))
        check(w.group(g3)?.panels == ["channels", "layers", "paths"], "reorder: one step right (index counted without the dragged tab)", "\(w.group(g3)?.panels ?? [])")

        // tab into another group
        var t = e
        t.move(["history"], to: .tab(group: g3, index: 1))
        check(t.group(g3)?.panels == ["layers", "history", "channels", "paths"] && t.group(g3)?.selected == "history"
              && t.group("ess.c1.g2")?.panels == ["brushes", "brushSettings", "actions", "layerComps"], "dock as a tab of another group (in another column)")

        // split above / below
        var sp = e
        sp.move(["navigator"], to: .split(group: "ess.c2.g1", below: true))
        check(sp.columns[1].groups.count == 4 && sp.columns[1].groups[1].panels == ["navigator"] && sp.columns[0].groups[0].panels == ["histogram", "info"],
              "drop below a group: a new group under it")
        sp.move(["info"], to: .split(group: "ess.c2.g1", below: false))
        check(sp.columns[1].groups.first?.panels == ["info"], "drop above a group")
        var same = e
        check(!same.move(["layers", "channels", "paths"], to: .split(group: g3, below: true)) && same == e, "a whole group dropped on itself changes nothing")

        // new column, pruning
        var nc = e
        nc.move(["info"], to: .column(index: 0))
        check(nc.columns.count == 3 && nc.columns[0].groups.map(\.panels) == [["info"]] && nc.primary == e.primary, "drop at a column edge: a new column")
        var pr = e
        pr.move(["navigator", "histogram", "info"], to: .tab(group: g3, index: 0))
        check(pr.columns[0].groups.count == 1 && pr.group("ess.c1.g1") == nil, "a group left empty goes away")
        pr.move(["history", "brushes", "brushSettings", "actions", "layerComps"], to: .columnEnd(column: "ess.c2"))
        check(pr.columns.count == 1 && pr.columns[0].groups.count == 4, "a column left empty goes away")

        // float / dock back
        var fl = e
        let fr = CGRect(x: 100, y: 120, width: 280, height: 380)
        fl.float(["layers"], frame: fr)
        check(fl.floatingIDs == ["layers"] && fl.floating.first?.frame == fr && !fl.allDocked.contains("layers") && fl.group(g3)?.panels == ["channels", "paths"],
              "tear out: the panel floats in its own window")
        let fg = fl.floating.first?.id ?? ""
        fl.move(["navigator"], to: .tab(group: fg, index: 1))
        check(fl.floating.first?.group.panels == ["layers", "navigator"], "drop onto a floating window: a tab there")
        fl.move(["layers", "navigator"], to: .tab(group: g3, index: 0), active: "layers")
        check(fl.floating.isEmpty && fl.group(g3)?.panels == ["layers", "navigator", "channels", "paths"] && fl.group(g3)?.selected == "layers",
              "a floating group dragged back into the dock (the window goes away)")
        var fg2 = e
        fg2.float(["layers", "channels", "paths"], frame: fr, active: "channels")
        check(fg2.floating.count == 1 && fg2.floating[0].group.panels == ["layers", "channels", "paths"] && fg2.floating[0].group.selected == "channels" && fg2.columns[1].groups.count == 2,
              "a whole tab group floats together")
        var cl = e
        cl.remove("layers")
        cl.move(["layers"], to: .tab(group: g3, index: 0))
        check(cl.group(g3)?.panels.first == "layers", "a closed panel can be docked anywhere")

        // resize
        var rz = e
        rz.setWidth("ess.c2", 50)
        let lo = rz.columns[1].width
        rz.setWidth("ess.c2", 5000)
        let hi = rz.columns[1].width
        rz.setWidth("ess.c2", 345.4)
        check(lo == DockMetrics.minColumnWidth && hi == DockMetrics.maxColumnWidth && rz.columns[1].width == 345, "column width: clamped to \(Int(DockMetrics.minColumnWidth))–\(Int(DockMetrics.maxColumnWidth)) pt")
        let ok = rz.resizeGroups(column: "ess.c2", divider: 0, delta: 50, actual: [200, 300, 380])
        check(ok && rz.columns[1].groups.map(\.height) == [250, 250, 380], "group divider: the two neighbours trade height", "\(rz.columns[1].groups.map(\.height))")
        rz.resizeGroups(column: "ess.c2", divider: 1, delta: 1000, actual: [250, 250, 380])
        check(rz.columns[1].groups.map(\.height) == [250, 630 - DockMetrics.minGroupHeight, DockMetrics.minGroupHeight], "group divider: a group keeps its minimum height",
              "\(rz.columns[1].groups.map(\.height))")

        // collapse
        var co = e
        co.setCollapsed(g3, true)
        let hs = WorkspaceGeometry.groupHeights(co.columns[1].groups, available: 800)
        check(hs[2] == DockMetrics.tabBarHeight && abs(hs.reduce(0, +) + 2 * DockMetrics.groupGap - 800) < 0.5 && abs(hs[0] / hs[1] - 210.0 / 300) < 0.02,
              "a collapsed group keeps only its tab bar; the others share the height", "\(hs)")
        co.select("channels")
        check(co.group(g3)?.collapsed == false && co.group(g3)?.selected == "channels", "choosing a tab of a collapsed group expands it")
        var all = e
        for g in all.columns[1].groups { all.setCollapsed(g.id, true) }
        let ah = WorkspaceGeometry.groupHeights(all.columns[1].groups, available: 800)
        check(ah == [26, 26, 26], "all groups collapsed: tab bars only", "\(ah)")

        // icon column
        var ic = e
        ic.setIconic("ess.c1", true)
        check(ic.columns[0].displayWidth == DockMetrics.iconColumnWidth && WorkspaceGeometry.dockWidth(ic, showSecondary: true) == 38 + 300 + 8
              && WorkspaceGeometry.dockWidth(e, showSecondary: true) == 538 && WorkspaceGeometry.dockWidth(e, showSecondary: false) == 304, "icon column and dock widths")

        // repair
        var bad = e
        bad.columns[0].groups[0].panels.append("layers")
        bad.columns[0].width = .nan
        bad.columns[1].groups[0].height = -5
        bad.columns.append(DockColumn([]))
        bad.floating.append(FloatingGroup(group: DockGroup([]), frame: nil))
        bad.floating.append(FloatingGroup(group: DockGroup(["info"]), frame: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)))
        bad.sanitize()
        check(bad.allPanels.filter { $0 == "layers" }.count == 1 && bad.allPanels.filter { $0 == "info" }.count == 1 && bad.columns.count == 2 && bad.floating.isEmpty
              && bad.columns[0].width == 260 && bad.columns[1].groups[0].height == DockMetrics.minGroupHeight, "a damaged saved layout is repaired (duplicates, empty containers, bad sizes)")
        var se = e
        se.select("properties")
        check(se == e, "selecting the first tab leaves the stock layout equal to itself")
    }

    // MARK: - Recovery and snapping

    static func geometry() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        var w = Workspace(name: "t", columns: [])
        w.floating = [
            FloatingGroup(group: DockGroup(["info"], id: "f1"), frame: CGRect(x: 60000, y: 40000, width: 280, height: 380)),
            FloatingGroup(group: DockGroup(["navigator"], id: "f2"), frame: CGRect(x: 200, y: 200, width: 280, height: 380)),
            FloatingGroup(group: DockGroup(["history"], id: "f3"), frame: CGRect(x: 100, y: -300, width: 3000, height: 2000)),
            FloatingGroup(group: DockGroup(["actions"], id: "f4"), frame: nil),
            FloatingGroup(group: DockGroup(["brushes"], id: "f5"), frame: CGRect(x: 300, y: 860, width: 280, height: 380)),   // title bar above the screen
        ]
        w.prune()
        let moved = w.recoverFloating(screens: [screen], anchor: screen)
        let frames = Dictionary(uniqueKeysWithValues: w.floating.map { ($0.id, $0.frame ?? .null) })
        check(Set(moved) == ["f1", "f3", "f4", "f5"], "lost windows found (off screen, too big, never placed, title bar unreachable)", moved.joined(separator: ","))
        check(frames.values.allSatisfy { WorkspaceGeometry.isReachable($0, screens: [screen]) && screen.contains($0.insetBy(dx: 1, dy: 1)) }, "…and all brought back on screen",
              frames.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
        check(frames["f2"] == CGRect(x: 200, y: 200, width: 280, height: 380), "a window that is on screen stays put")
        check(frames["f3"].map { $0.width <= screen.width && $0.height <= screen.height } == true, "a window larger than the screen is shrunk to fit")
        // a second display that was unplugged
        var two = Workspace.essentials
        two.floating = [FloatingGroup(group: DockGroup(["info"], id: "x"), frame: CGRect(x: 1600, y: 300, width: 280, height: 380))]
        let wasOn = WorkspaceGeometry.isReachable(two.floating[0].frame!, screens: [screen, CGRect(x: 1440, y: 0, width: 1920, height: 1080)])
        two.recoverFloating(screens: [screen], anchor: nil)
        check(wasOn && screen.contains(two.floating[0].frame!), "a window on an unplugged display comes back to the remaining one")

        // magnetic edges
        let s1 = WorkspaceGeometry.snap(CGRect(x: 6, y: 300, width: 280, height: 380), screens: [screen], windows: [])
        let s2 = WorkspaceGeometry.snap(CGRect(x: 515, y: 300, width: 280, height: 380), screens: [screen], windows: [CGRect(x: 800, y: 200, width: 600, height: 600)])
        let s3 = WorkspaceGeometry.snap(CGRect(x: 300, y: 300, width: 280, height: 380), screens: [screen], windows: [CGRect(x: 800, y: 200, width: 600, height: 600)])
        let s4 = WorkspaceGeometry.snap(CGRect(x: 515, y: 30, width: 100, height: 100), screens: [], windows: [CGRect(x: 620, y: 500, width: 100, height: 100)])
        check(s1.minX == 0 && s2.maxX == 800 && s3 == CGRect(x: 300, y: 300, width: 280, height: 380) && s4.minX == 515,
              "floating windows snap to screen and window edges within 10 pt (and only beside a window)", "\(s1) \(s2) \(s4)")
        let s5 = WorkspaceGeometry.snap(CGRect(x: 300, y: 300, width: 280, height: 380), screens: [screen], windows: [CGRect(x: 300, y: 690, width: 280, height: 100)])
        check(s5.maxY == 690, "…stacked under another window", "\(s5)")
    }

    // MARK: - Named workspaces and persistence

    static func decoded(_ store: WorkspaceStore) -> Workspace? {
        store.data(forKey: WorkspaceManager.currentKey).flatMap { try? JSONDecoder().decode(Workspace.self, from: $0) }
    }

    static func persistence(_ store: WorkspaceStore) {
        let ws = WorkspaceManager.shared
        let app = AppModel.shared
        check(ws.current == .essentials && store.data(forKey: WorkspaceManager.currentKey) == nil, "a fresh store starts with Essentials")
        ws.setColumnWidth(column: "ess.c2", 360)
        check(decoded(store)?.columns[1].width == 360, "a layout change is saved straight away")
        ws.beginLive()
        ws.setColumnWidth(column: "ess.c2", 420)
        let mid = decoded(store)?.columns[1].width
        ws.endLive()
        check(mid == 360 && decoded(store)?.columns[1].width == 420 && ws.current.columns[1].width == 420, "a live drag is applied at once and written when it ends")
        check(WorkspaceManager(store: store, managesWindows: false).current == ws.current, "the layout persists between launches")

        ws.saveCurrent(as: "Wide Main")
        check(ws.saved.map(\.name) == ["Wide Main"] && ws.current.name == "Wide Main" && WorkspaceManager(store: store, managesWindows: false).saved.map(\.name) == ["Wide Main"],
              "Window ▸ Workspace ▸ New Workspace… saves a named workspace (persists)")
        ws.switchTo("Painting")
        check(ws.current.name == "Painting" && ws.current.columns == Workspace.painting.columns, "load a stock workspace")
        ws.switchTo("Wide Main")
        check(ws.current.name == "Wide Main" && ws.current.columns.last?.width == 420, "load the saved workspace")
        ws.saveCurrent(as: "Essentials")
        check(ws.saved.contains { $0.name == "Essentials (Custom)" } && !ws.saved.contains { $0.name == "Essentials" }, "saving under a stock name keeps the stock workspace")
        ws.deleteSaved("Essentials (Custom)")
        ws.deleteSaved("Wide Main")
        check(ws.saved.isEmpty && WorkspaceManager(store: store, managesWindows: false).saved.isEmpty, "Delete Workspace removes it (persists)")

        ws.apply(.essentials)
        ws.setColumnWidth(column: "ess.c1", 280)
        ws.switchTo("Photography")
        check(ws.current.name == "Photography" && ws.current.columns.first?.iconic == true, "Photography opens with an icon column")
        ws.switchTo("Essentials")
        check(ws.current.columns.first?.width == 280 && ws.isModified, "switching back keeps the changes made to a workspace (until Reset)")
        check(WorkspaceManager(store: store, managesWindows: false).current.columns.first?.width == 280, "…also after a relaunch")
        ws.reset()
        check(ws.current == .essentials && !ws.isModified, "Reset puts the stock layout back")
        ws.switchTo("Painting")
        ws.switchTo("Essentials")
        check(ws.current == .essentials, "…and forgets the changes")

        ws.close("layers")
        ws.float("history")
        ws.setIconic(column: "ess.c2", true)
        ws.setCollapsed(group: "ess.c1.g1", true)
        app.showSecondaryPanels = false
        ws.reset()
        check(ws.current == .essentials && app.showSecondaryPanels && ws.windows.isEmpty, "Reset brings back closed, floating, collapsed and hidden panels")

        store.set(Data(legacyJSON.utf8), forKey: WorkspaceManager.currentKey)
        ws.reloadFromStore()
        check(ws.current.name == "Web/UI" && ws.current.primary == [["color"], ["layers", "channels"]] && ws.current.floatingIDs == ["navigator"],
              "an old saved layout loads (and the renamed Graphic and Web workspace becomes Web/UI)", ws.current.name)
        ws.reset()
        check(ws.current.columns == Workspace.webUI.columns, "…and Reset gives the new Web/UI layout")

        // panels lost off screen come back
        ws.apply(.essentials)
        ws.float("navigator", frame: CGRect(x: 90000, y: 90000, width: 280, height: 380))
        let lost = ws.current.floating.first?.frame
        let scr = ws.screens
        ws.recoverLostPanels()
        let back = ws.current.floating.first?.frame
        check(lost.map { !WorkspaceGeometry.isReachable($0, screens: scr) } == true && back.map { WorkspaceGeometry.isReachable($0, screens: scr) } == true, "Bring Panels Back On Screen / screen changes recover lost floating panels",
              "lost \(lost ?? .null) back \(back ?? .null)")
        if let gid = ws.current.floating.first?.id, let win = ws.windows[gid], let b = back {
            UIFixesSelfTest.spin(0.05)
            check(win.frame.equalTo(b, tolerance: 1) && !NSScreen.screens.contains { $0.frame.intersects(win.frame) }, "…its window follows (test windows stay off the real screens)", "\(win.frame)")
        } else {
            check(false, "floating window for the recovered panel")
        }
        ws.reset()

        // Window ▸ Panels
        ws.menuToggle("layers")
        check(!ws.isVisible("layers"), "Window ▸ Panels: a panel in front is hidden")
        ws.menuToggle("layers")
        check(ws.isFrontmost("layers"), "…and shown again (docked and selected)")
        ws.menuToggle("channels")
        check(ws.isFrontmost("channels") && ws.isVisible("layers"), "…a panel behind another tab comes to the front instead of hiding")
        app.showSecondaryPanels = false
        ws.reveal("history")
        check(app.showSecondaryPanels && ws.isFrontmost("history"), "revealing a panel of a hidden column shows the column")
        ws.toggle("history")
        check(ws.isVisible("history"), "the old toggle never hides a panel")
        let t0 = ws.focusRequest.tick
        ws.current = .essentials
        ws.reveal("properties")
        check(ws.current == .essentials && ws.focusRequest.id == "properties" && ws.focusRequest.tick == t0 + 1, "reveal of a docked panel moves nothing")
        ws.reset()
    }

    /// Layout changes are not document changes.
    static func noDocumentChanges() {
        let app = AppModel.shared
        let ws = WorkspaceManager.shared
        let d = Document(state: SelfTest.baseState(), name: "ws2")
        d.needsFitOnScreen = false
        let prevDocs = app.documents, prevActive = app.activeDocumentID
        app.documents = [d]; app.activeDocumentID = d.id
        defer { app.documents = prevDocs; app.activeDocumentID = prevActive }
        var commits = 0
        let prev = Document.willCommit
        Document.willCommit = { prev?($0); commits += 1 }
        defer { Document.willCommit = prev }
        let h0 = d.history.count, i0 = d.historyIndex, dirty0 = d.isDirty
        ws.perform(["navigator"], to: .split(group: g3, below: true))
        ws.float("info")
        ws.dock("info")
        ws.setColumnWidth(column: "ess.c2", 400)
        ws.resizeGroups(column: "ess.c2", divider: 0, delta: 30, actual: [200, 300, 380])
        ws.setCollapsed(group: g3, true)
        ws.setIconic(column: "ess.c1", true)
        ws.switchTo("Painting")
        ws.saveCurrent(as: "Tmp")
        ws.deleteSaved("Tmp")
        ws.switchTo("Essentials")
        ws.menuToggle("layers")
        ws.reset()
        check(commits == 0 && d.history.count == h0 && d.historyIndex == i0 && d.isDirty == dirty0 && app.documents.count == 1,
              "layout changes record no history step and don't mark the document dirty", "commits \(commits), history \(h0)→\(d.history.count), dirty \(dirty0)→\(d.isDirty)")
    }

    // MARK: - Views (real MainView in an offscreen window)

    static func event(_ type: NSEvent.EventType, _ p: CGPoint, _ w: NSWindow, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                           context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    static func screen(_ v: NSView, _ p: CGPoint) -> CGPoint { v.window!.convertPoint(toScreen: v.convert(p, to: nil)) }
    static func center(_ v: NSView, _ r: CGRect) -> CGPoint { screen(v, CGPoint(x: r.midX, y: r.midY)) }

    /// Presses at screen point `a` in window `w`, drags to `b` in steps and releases (locations are recomputed every step, so a
    /// window that moves with the pointer gets consistent events).
    static func drag(_ w: NSWindow, from a: CGPoint, to b: CGPoint, steps: Int = 8) {
        w.sendEvent(event(.leftMouseDown, w.convertPoint(fromScreen: a), w))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            w.sendEvent(event(.leftMouseDragged, w.convertPoint(fromScreen: p), w))
        }
        w.sendEvent(event(.leftMouseUp, w.convertPoint(fromScreen: b), w))
        UIFixesSelfTest.spin(0.12)
    }

    static func click(_ w: NSWindow, _ sp: CGPoint, clicks: Int = 1) {
        let p = w.convertPoint(fromScreen: sp)
        for c in 1...clicks {
            w.sendEvent(event(.leftMouseDown, p, w, clicks: c))
            w.sendEvent(event(.leftMouseUp, p, w, clicks: c))
        }
        UIFixesSelfTest.spin(0.1)
    }

    static func find<T: NSView>(_ type: T.Type, in v: NSView?) -> [T] {
        guard let v else { return [] }
        var out: [T] = []
        func walk(_ x: NSView) { if let t = x as? T { out.append(t) }; x.subviews.forEach(walk) }
        walk(v)
        return out
    }

    /// Small offscreen windows (status bar, a floating panel) render through their layer tree.
    static func snapshot(_ v: NSView, _ name: String, _ dir: URL) {
        v.window?.displayIfNeeded()
        let scale = v.window?.backingScaleFactor ?? 2
        let w = Int(v.bounds.width * scale), h = Int(v.bounds.height * scale)
        guard let layer = v.layer, w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }

    /// The large main-window scene: macOS doesn't render the layers of a big window that is off every screen (it is
    /// occluded), so the AppKit chrome (columns, tab bars, dividers, canvas rulers) is drawn through a PDF pass and each
    /// panel's SwiftUI content is drawn into its place with `ImageRenderer`. (The options bar and tools palette, SwiftUI
    /// parts of MainView, stay blank in these pictures.)
    static func composite(_ root: NSView, _ name: String, _ dir: URL) {
        let scale: CGFloat = 2
        let size = root.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(DockColors.gap.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        // AppKit chrome: a PDF pass runs draw(_:) of every view (layer contents of an occluded window are empty)
        if let pdf = NSImage(data: root.dataWithPDF(inside: root.bounds)) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            pdf.draw(in: CGRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
        }
        for host in find(NSHostingView<PanelContentRoot>.self, in: root) where !host.isHiddenOrHasHiddenAncestor && host.window != nil {
            var r = root.convert(host.bounds, from: host)
            if root.isFlipped { r.origin.y = size.height - r.maxY }
            let id = host.rootView.id
            let image: CGImage? = MainActor.assumeIsolated {
                let ir = ImageRenderer(content: PanelContentRoot(id: id).frame(width: r.width, height: r.height))
                ir.scale = scale
                return ir.cgImage
            }
            if let image { ctx.draw(image, in: r) }
        }
        // drop highlights sit above the panels
        for o in find(DockHighlightView.self, in: root) {
            var r = root.convert(o.bounds, from: o)
            if root.isFlipped { r.origin.y = size.height - r.maxY }
            if let img = NSImage(data: o.dataWithPDF(inside: o.bounds)) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                img.draw(in: r)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        guard let img = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }

    static func views(_ dir: URL) {
        let app = AppModel.shared
        let ws = WorkspaceManager.shared
        var st = DocumentState(width: 1600, height: 1000)
        st.layers = [Layer.raster(name: "Layer 1", width: 1600, height: 1000)]
        let d = Document(state: st, name: "workspace")
        d.needsFitOnScreen = false
        app.documents = [d]; app.activeDocumentID = d.id
        app.tool = .move
        let size = CGSize(width: 1440, height: 900)
        let hv = NSHostingView(rootView: MainView().frame(width: size.width, height: size.height))
        let w = KeyableWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        UIFixesSelfTest.spin(0.8)
        defer { w.makeFirstResponder(nil); UIFixesSelfTest.spin(0.05); w.orderOut(nil); w.contentView = nil }
        guard let canvas = find(CanvasView.self, in: hv).first, let dock = find(DockAreaView.self, in: hv).first else {
            check(false, "MainView hosts the canvas and the dock")
            return
        }
        AppActions.canvas = canvas
        func spin(_ s: Double = 0.15) { UIFixesSelfTest.spin(s); AppActions.canvas = canvas }
        let c1 = "ess.c1", c2 = "ess.c2"
        check(abs(dock.frame.width - 538) < 1 && dock.columnView(c1) != nil && dock.columnView(c2) != nil, "default layout: two docked columns (230 + 300 pt)", "\(dock.frame)")
        check(abs(canvas.frame.width - (1440 - 47 - 538)) < 2, "the canvas fills the rest", "\(canvas.frame.width)")
        composite(hv, "ws2_default_layout", dir)

        // column width → canvas follows
        let cw0 = canvas.frame.width
        ws.setColumnWidth(column: c2, 400)
        spin()
        check(abs(canvas.frame.width - (cw0 - 100)) < 2 && abs(dock.frame.width - 638) < 1, "widening a column narrows the canvas", "\(cw0) → \(canvas.frame.width)")

        // divider drag with the mouse
        if let div = dock.divider(column: c2) {
            let a = center(div, div.bounds)
            let saves = ws.revision
            w.sendEvent(event(.leftMouseDown, w.convertPoint(fromScreen: a), w))
            w.sendEvent(event(.leftMouseDragged, w.convertPoint(fromScreen: CGPoint(x: a.x - 30, y: a.y)), w))
            w.sendEvent(event(.leftMouseDragged, w.convertPoint(fromScreen: CGPoint(x: a.x - 50, y: a.y)), w))
            let midWidth = ws.current.columns.last?.width
            w.sendEvent(event(.leftMouseUp, w.convertPoint(fromScreen: CGPoint(x: a.x - 50, y: a.y)), w))
            spin()
            check(midWidth == 450 && ws.current.columns.last?.width == 450 && ws.revision > saves, "dragging the strip left of a column resizes it live", "\(midWidth ?? 0)")
            check(abs(canvas.frame.width - (cw0 - 150)) < 2, "…and the canvas resizes with it", "\(canvas.frame.width)")
            check(w.firstResponder === canvas, "…then the canvas has keyboard focus")
            // never wider than the window allows
            let b = center(div, div.bounds)
            drag(w, from: b, to: CGPoint(x: b.x - 2000, y: b.y), steps: 3)
            spin()
            check(canvas.frame.width >= DockMetrics.minCanvasWidth - 1, "the canvas keeps at least \(Int(DockMetrics.minCanvasWidth)) pt", "\(canvas.frame.width)")
        } else { check(false, "column divider") }
        ws.setColumnWidth(column: c2, 300)
        spin()

        // group divider drag
        if let cv = dock.columnView(c2), let gd = cv.groupDivider(1) {
            let h0 = cv.laidOutHeights
            let a = center(gd, gd.bounds)
            drag(w, from: a, to: CGPoint(x: a.x, y: a.y - 40), steps: 4)
            spin()
            let h1 = cv.laidOutHeights
            check(h0.count == 3 && h1.count == 3 && abs((h1[1] - h0[1]) - 40) <= 1 && abs((h0[2] - h1[2]) - 40) <= 1 && h1[0] == h0[0],
                  "dragging the strip between two groups shares their height", "\(h0) → \(h1)")
        } else { check(false, "group divider") }

        // tabs: click, focus, shortcuts
        guard let gv = dock.groupView(g3), let chRect = gv.tabBar.rect(of: "channels") else { check(false, "Layers group and its Channels tab"); return }
        if let field = find(NSTextField.self, in: dock).first(where: { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }) {
            w.makeFirstResponder(field)
        }
        click(w, center(gv.tabBar, chRect))
        spin()
        check(ws.current.group(g3)?.selected == "channels" && gv.content.hosted === ws.host("channels"), "clicking a tab shows that panel")
        check(w.firstResponder === canvas, "after a panel interaction the canvas has keyboard focus (shortcuts work)",
              "\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                    context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11) {
            if !KeyRouter.handle(e) { w.sendEvent(e) }
            check(app.tool.shortcut == "B", "…a single-key tool shortcut (B) reaches the tools", "\(app.tool)")
        }
        app.tool = .move

        // double-click collapses / expands
        let empty = screen(gv.tabBar, CGPoint(x: gv.tabBar.bounds.maxX - 60, y: 12))
        click(w, empty, clicks: 2)
        spin()
        check(ws.current.group(g3)?.collapsed == true && abs(gv.frame.height - DockMetrics.tabBarHeight) < 1, "double-clicking the tab bar collapses the group", "\(gv.frame.height)")
        if let cv = dock.columnView(c2) { composite(cv, "ws2_collapsed_group", dir) }
        click(w, screen(gv.tabBar, CGPoint(x: gv.tabBar.bounds.maxX - 60, y: 12)), clicks: 2)
        spin()
        check(ws.current.group(g3)?.collapsed == false && gv.frame.height > 100, "…and again expands it", "\(gv.frame.height)")

        // drag a tab into another group (other column)
        if let src = dock.groupView("ess.c1.g2"), let r = src.tabBar.rect(of: "history") {
            let target = screen(gv.tabBar, CGPoint(x: gv.tabBar.bounds.maxX - 60, y: 12))
            drag(w, from: center(src.tabBar, r), to: target)
            spin()
            check(ws.current.group(g3)?.panels == ["layers", "channels", "paths", "history"] && ws.current.group(g3)?.selected == "history"
                  && ws.current.group("ess.c1.g2")?.panels.contains("history") == false, "drag a tab onto another group's tab bar: it joins as a tab", "\(ws.current.group(g3)?.panels ?? [])")
        } else { check(false, "History tab") }

        // reorder by dragging within the bar
        if let r = gv.tabBar.rect(of: "history"), let lr = gv.tabBar.rect(of: "layers") {
            drag(w, from: center(gv.tabBar, r), to: screen(gv.tabBar, CGPoint(x: lr.minX + 4, y: 12)))
            spin()
            check(ws.current.group(g3)?.panels == ["history", "layers", "channels", "paths"], "drag a tab along its bar to reorder", "\(ws.current.group(g3)?.panels ?? [])")
        }

        // drop below a group
        if let src = dock.groupView("ess.c1.g1"), let r = src.tabBar.rect(of: "navigator"), let g2 = dock.groupView("ess.c2.g2") {
            drag(w, from: center(src.tabBar, r), to: screen(g2, CGPoint(x: g2.bounds.midX, y: g2.bounds.maxY - 12)))
            spin()
            let gs = ws.current.columns.last?.groups.map(\.panels) ?? []
            check(gs.count == 4 && gs[2] == ["navigator"], "drag a tab to the bottom of a group: a new group below it", "\(gs)")
        } else { check(false, "Navigator tab") }

        // tear out → floating window
        if let src = dock.groupView("ess.c1.g1"), let r = src.tabBar.rect(of: "info") {
            drag(w, from: center(src.tabBar, r), to: screen(canvas, CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)))
            spin(0.3)
            let fg = ws.current.floating.first
            let win = fg.flatMap { ws.windows[$0.id] }
            check(fg?.group.panels == ["info"] && win != nil && win?.isVisible == true, "drag a tab out over the canvas: it floats in its own window")
            if let win {
                check(win.isFloatingPanel && win.becomesKeyOnlyIfNeeded && win.styleMask.contains(.resizable) && FloatingPanel.productionStyle.contains(.utilityWindow),
                      "floating panels are resizable utility windows above the main window that don't take the keyboard")
                check(!NSScreen.screens.contains { $0.frame.intersects(win.frame) } && fg?.frame.map { win.frame.equalTo($0, tolerance: 1) } == true,
                      "…placed where the model says (off the real screens in tests)", "window \(win.frame) model \(fg?.frame ?? .null) screens \(NSScreen.screens.map(\.frame))")
                check(win.groupView.content.hosted === ws.host("info"), "…showing the panel")
                composite(win.contentView!, "ws2_floating_panel", dir)
                // move / resize persists
                win.setFrame(win.frame.offsetBy(dx: 40, dy: -20).insetBy(dx: -10, dy: -10), display: true)
                spin(0.1)
                check(ws.current.floating.first?.frame.map { $0.equalTo(win.frame, tolerance: 0.5) } == true, "moving / resizing a floating window is remembered")

                // drop another tab onto the floating window
                if let g1 = dock.groupView("ess.c2.g1"), let sr = g1.tabBar.rect(of: "swatches") {
                    let tp = win.convertPoint(toScreen: win.groupView.tabBar.convert(CGPoint(x: win.groupView.tabBar.bounds.maxX - 50, y: 12), to: nil))
                    let probe = DockDragSession(panels: ["swatches"], sourceGroup: "ess.c2.g1", wholeGroup: false, active: nil, movingWindow: nil, start: .zero, size: .zero)
                    probe.update(tp, suppressDocking: false)
                    check({ if case .target(let h) = probe.resolution, case .tab = h.target { return true }; return false }(), "over a floating window's tab bar: a tab target",
                          "\(probe.resolution) tp \(tp) win \(win.frame) bar \(win.groupView.tabBar.frame) visible \(win.isVisible)")
                    probe.cancel()
                    drag(w, from: center(g1.tabBar, sr), to: tp)
                    spin()
                    check(ws.current.floating.first?.group.panels == ["info", "swatches"], "drag a tab onto a floating window: it joins as a tab",
                          "\(ws.current.floating.first?.group.panels ?? [])")
                }
                // PendingEdits: floating content vs chrome
                let content = win.groupView.content
                let pc = win.convertPoint(fromScreen: center(content, content.bounds))
                let pt = win.convertPoint(fromScreen: screen(win.groupView.tabBar, CGPoint(x: 20, y: 12)))
                check(PendingEdits.clickIsInPanel(event(.leftMouseDown, pc, win)) && !PendingEdits.clickIsInPanel(event(.leftMouseDown, pt, win)),
                      "clickIsInPanel: a floating panel's content yes, its tab bar no")
                // drag the floating group back by its tab bar
                let from = win.convertPoint(toScreen: win.groupView.tabBar.convert(CGPoint(x: win.groupView.tabBar.bounds.maxX - 50, y: 12), to: nil))
                let to = screen(gv.tabBar, CGPoint(x: gv.tabBar.bounds.maxX - 50, y: 12))
                drag(win, from: from, to: to)
                spin(0.2)
                check(ws.current.floating.isEmpty && ws.windows.isEmpty && ws.current.group(g3)?.panels.suffix(2) == ["info", "swatches"],
                      "drag a floating window by its tab bar onto a group: docked as tabs, the window goes away", "\(ws.current.group(g3)?.panels ?? [])")
            }
        } else { check(false, "Info tab") }

        // clickIsInPanel in the main window
        if let g = dock.groupView(g3), let div = dock.divider(column: c2) {
            func at(_ v: NSView, _ p: CGPoint) -> NSEvent { event(.leftMouseDown, v.convert(p, to: nil), w) }
            let content = at(g.content, CGPoint(x: g.content.bounds.midX, y: g.content.bounds.midY))
            let tab = at(g.tabBar, CGPoint(x: 20, y: 12))
            let strip = at(div, CGPoint(x: div.bounds.midX, y: div.bounds.midY))
            let header = at(dock.columnView(c2)!.header, CGPoint(x: 10, y: 8))
            let cvs = at(canvas, CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
            let options = event(.leftMouseDown, CGPoint(x: 300, y: size.height - 10), w)
            check(PendingEdits.clickIsInPanel(content) && !PendingEdits.clickIsInPanel(tab) && !PendingEdits.clickIsInPanel(strip) && !PendingEdits.clickIsInPanel(header)
                  && !PendingEdits.clickIsInPanel(cvs) && !PendingEdits.clickIsInPanel(options),
                  "clickIsInPanel: docked panel content yes; tab bars, dividers, column headers, canvas and options bar no")
        }

        // drop-target highlights
        ws.reset()
        spin()
        if let g1 = dock.groupView("ess.c2.g1"), let g2 = dock.groupView("ess.c2.g2"), let lg = ws.current.group(containing: "layers") {
            let s = DockDragSession(panels: ["layers"], sourceGroup: lg.id, wholeGroup: false, active: "layers", movingWindow: nil,
                                    start: screen(g1, .zero), size: CGSize(width: 300, height: 380))
            s.update(screen(g1, CGPoint(x: g1.bounds.midX, y: g1.bounds.maxY - 10)), suppressDocking: false)
            spin(0.05)
            if case .target(let h) = s.resolution {
                check(h.target == .split(group: "ess.c2.g1", below: true) && h.style == .bar && s.overlay?.superview === hv, "highlight: a blue bar where the new group will go")
            } else { check(false, "highlight: split target", "\(s.resolution)") }
            check(s.ghost.map { g in !NSScreen.screens.contains { $0.frame.intersects(g.frame) } } == true, "a label follows the pointer")
            composite(hv, "ws2_drop_highlight_below", dir)
            s.update(screen(g2.tabBar, CGPoint(x: 30, y: 12)), suppressDocking: false)
            spin(0.05)
            if case .target(let h) = s.resolution {
                check(h.target == .tab(group: "ess.c2.g2", index: 0) && h.style == .outline && h.caret != nil, "highlight: an outline and a caret where the tab will go")
            } else { check(false, "highlight: tab target", "\(s.resolution)") }
            composite(hv, "ws2_drop_highlight_tab", dir)
            if let cv = dock.columnView(c1) {
                s.update(screen(cv, CGPoint(x: 2, y: 300)), suppressDocking: false)
                if case .target(let h) = s.resolution { check(h.target == .column(index: 0), "highlight: a column edge makes a new column") } else { check(false, "column edge target") }
            }
            s.update(screen(canvas, CGPoint(x: 200, y: 200)), suppressDocking: false)
            check(s.resolution == .nothing && s.overlay == nil, "over the canvas: no highlight (release floats the panel)")
            s.update(screen(dock.groupView(lg.id)!.content, CGPoint(x: 100, y: 150)), suppressDocking: false)
            check(s.resolution == .source || { if case .target = s.resolution { return true }; return false }(), "over its own group")
            s.cancel()
            check(s.overlay == nil && s.ghost == nil, "cancelled drags leave nothing behind")
        }

        // tabbed group with more tabs than fit
        ws.setColumnWidth(column: c1, 190)
        spin()
        if let tg = dock.groupView("ess.c1.g2") {
            check(!tg.tabBar.overflow.isEmpty && tg.tabBar.tabRects.contains { $0.id == ws.current.group("ess.c1.g2")?.selected }, "tabs that don't fit go to the » menu (the selected one stays visible)",
                  "visible \(tg.tabBar.tabRects.map(\.id)) overflow \(tg.tabBar.overflow)")
            composite(tg, "ws2_tabbed_group_narrow", dir)
            let kids = tg.tabBar.accessibilityChildren()?.compactMap { $0 as? DockTabElement } ?? []
            check(kids.map { $0.accessibilityLabel() ?? "" } == tg.tabBar.tabRects.map { PanelRegistry.title($0.id) } && tg.tabBar.accessibilityRole() == .tabGroup,
                  "VoiceOver: the tab bar is a tab group with a labelled element per tab")
        }
        ws.setColumnWidth(column: c1, 230)
        spin()
        if let tg = dock.groupView(g3) { composite(tg, "ws2_tabbed_group", dir) }

        // icon column
        let cwBefore = canvas.frame.width
        if let cv = dock.columnView(c1) {
            check(cv.header.button.accessibilityLabel() == "Collapse to Icons" && cv.header.button.toolTip == "Collapse to Icons", "the column header button is labelled")
            cv.header.button.performClick(nil)
            spin()
            check(ws.current.columns.first?.iconic == true && abs(canvas.frame.width - (cwBefore + 230 - 38)) < 2, "collapse a column to icons (the canvas gets the room)",
                  "\(cwBefore) → \(canvas.frame.width)")
            let icons = find(DockIconButton.self, in: cv)
            check(icons.map(\.panelID) == ws.current.columns[0].groups.flatMap(\.panels) && icons.allSatisfy { $0.accessibilityLabel() == PanelRegistry.title($0.panelID) && $0.toolTip != nil },
                  "one labelled icon per panel")
            composite(dock, "ws2_icon_column", dir)
            let s = DockDragSession(panels: ["layers"], sourceGroup: g3, wholeGroup: false, active: "layers", movingWindow: nil, start: .zero, size: CGSize(width: 280, height: 380))
            s.update(screen(cv, CGPoint(x: cv.bounds.midX, y: 200)), suppressDocking: false)
            if case .target(let h) = s.resolution { check(h.target == .columnEnd(column: c1), "dropping on an icon column adds the panel to it") } else { check(false, "icon column drop target") }
            s.cancel()
            cv.header.button.performClick(nil)
            spin()
            check(ws.current.columns.first?.iconic == false && abs(canvas.frame.width - cwBefore) < 2, "…and expand it again")
        }

        // no columns: the right edge of the window docks
        let essentials = ws.current
        var none = ws.current
        for id in none.allDocked { none.remove(id) }
        ws.current = none
        spin()
        check(dock.frame.width < 1 && abs(canvas.frame.width - (1440 - 47)) < 2, "with every panel closed the canvas takes the whole width")
        let s = DockDragSession(panels: ["layers"], sourceGroup: "none", wholeGroup: true, active: nil, movingWindow: nil, start: .zero, size: CGSize(width: 280, height: 380))
        s.finish(w.convertPoint(toScreen: CGPoint(x: size.width - 20, y: 400)), suppressDocking: false)
        spin()
        check(ws.current.columns.count == 1 && ws.current.allDocked == ["layers"], "…and dropping a panel at the window's right edge starts a new column")
        ws.current = essentials
        spin()

        // show / hide
        ws.float("navigator")
        spin()
        app.showPanels = false
        spin(0.25)
        let hiddenWin = ws.windows.values.first
        check(hiddenWin?.isVisible == false && abs(canvas.frame.width - (1440 - 47)) < 2, "Tab (Show/Hide Panels) hides the columns and floating panels",
              "docks \(find(DockAreaView.self, in: hv).count), window \(hiddenWin.map { "\($0.isVisible)" } ?? "none"), canvas \(canvas.frame.width)")
        app.showPanels = true
        spin(0.25)
        let live = find(DockAreaView.self, in: hv).filter { !$0.subviews.isEmpty }
        check(hiddenWin?.isVisible == true && live.count == 1 && ws.activeDock === live.first, "…and shows them again (one live dock holds the panels)", "\(live.count)")
        app.showSecondaryPanels = false
        spin()
        check(abs(find(DockAreaView.self, in: hv).first!.frame.width - 304) < 1, "Show/Hide Secondary Panels hides the other columns")
        app.showSecondaryPanels = true
        ws.reset()
        spin()

        // narrow window: columns squeeze, the canvas keeps its minimum
        ws.setColumnWidth(column: c2, 600)
        spin()
        w.setContentSize(CGSize(width: 1000, height: 700))
        hv.rootView = MainView().frame(width: 1000, height: 700)
        spin(0.3)
        let dockNow = find(DockAreaView.self, in: hv).first
        check(canvas.frame.width >= DockMetrics.minCanvasWidth - 1 && (dockNow?.frame.maxX ?? 0) <= 1000.5, "a narrow window squeezes the columns and keeps the canvas usable",
              "canvas \(canvas.frame.width), dock \(dockNow?.frame ?? .zero)")
        composite(hv, "ws2_narrow_window", dir)
        ws.reset()
        w.setContentSize(size)
        hv.rootView = MainView().frame(width: size.width, height: size.height)
        spin(0.3)

        // light theme
        let theme = app.prefs.theme
        app.prefs.theme = .light
        spin(0.3)
        composite(hv, "ws2_light_theme", dir)
        app.prefs.theme = theme
        spin(0.2)
        check(true, "theme switch redraws the chrome (see ws2_light_theme.png)")
    }

    // MARK: - Status bar chips

    static func chips(_ dir: URL) {
        let ai = StatusChips.ai(today: 0.31, month: 4.2, session: 0.1, remaining: GenRemaining(amount: 18.3, kind: .live, provider: .fal, asOf: nil), level: .normal)
        check(ai.full == "AI $0.31 today · $18.30 left" && ai.compact == "AI $0.31 today" && ai.tiny == "AI $0.31", "AI chip labels", "\(ai.full) | \(ai.compact) | \(ai.tiny)")
        check(ai.help.hasPrefix("AI usage:") && ai.help.contains("this month $4.20") && ai.help.contains("balance $18.30") && ai.help.hasSuffix("Click to open the AI Usage panel."), "AI chip tooltip", ai.help)
        let low = StatusChips.ai(today: 2, month: 40, session: 2, remaining: GenRemaining(amount: -3, kind: .budget), level: .critical)
        check(low.full == "AI $2.00 today · $3.00 over budget" && low.tint == .critical && low.help.contains("used up"), "AI chip over budget", low.full)
        let rec = StatusChips.timelapse(frames: 12)
        check(rec.full == "Timelapse REC · 12 frames" && rec.compact == "REC 12" && rec.help.contains("timelapse") && rec.help.contains("Click"), "REC chip", rec.full)
        check(StatusChips.timelapse(frames: 1).full == "Timelapse REC · 1 frame", "REC chip singular")
        let on = StatusChips.autosave(enabled: true, minutes: 5, onDeactivate: true), off = StatusChips.autosave(enabled: false, minutes: 5, onDeactivate: true)
        check(on.full == "Autosave · 5 min" && on.compact == "Autosave 5m" && on.help.contains("every 5 minutes and when ImageCrat goes to the background") && on.help.contains("Preferences ▸ Workflow"),
              "autosave chip", on.full)
        check(off.full == "Autosave off" && off.tint == .warning && off.help.contains("can't be recovered"), "autosave off is a warning")
        let mem = StatusChips.memory(bytes: UInt64(1.2 * 1024 * 1_048_576), documents: 2, historyStates: 37)
        check(mem.full == "Memory 1.2 GB" && mem.compact == "1.2 GB" && mem.help.contains("2 documents open, 37 history states") && StatusChips.memoryString(300 * 1_048_576) == "300 MB",
              "memory chip", mem.full)
        check(StatusChips.footprint() > 10_000_000, "memory chip reads the real footprint")
        var st = DocumentState(width: 3840, height: 2160)
        st.resolution = 300
        let d = Document(state: st, name: "chips")
        d.needsFitOnScreen = false
        let doc = StatusChips.documentInfo(d)
        check(doc.full == "3840 × 2160 px · 300 ppi" && doc.compact == "3840 × 2160 px" && doc.tiny == "3840×2160" && doc.help.contains("12.8 × 7.2 in") && doc.help.contains("Image Size"),
              "document chip", doc.full)
        let cur = StatusChips.cursor(CGPoint(x: 1204, y: 388)), sel = StatusChips.selection(640, 480)
        check(cur.full == "X 1204  Y 388 px" && sel.full == "Selection 640 × 480 px" && sel.compact == "Sel 640 × 480", "pointer and selection chips")
        for c in [ai, low, rec, on, off, mem, doc, cur, sel] {
            check(!c.full.isEmpty && !c.compact.isEmpty && !c.tiny.isEmpty && c.help.count > 30 && c.help.contains("Click"), "\(c.id) chip: label at every width and a tooltip that says what a click does")
        }
        check(StatusBarTier(width: 1200) == .wide && StatusBarTier(width: 900) == .medium && StatusBarTier(width: 600) == .narrow, "status bar width tiers")

        // clicks
        let app = AppModel.shared
        let ws = WorkspaceManager.shared
        let prevDocs = app.documents, prevActive = app.activeDocumentID
        app.documents = [d]; app.activeDocumentID = d.id
        defer { app.documents = prevDocs; app.activeDocumentID = prevActive; app.dialog = nil }
        WorkspaceManager.shared.withStore(MemoryWorkspaceStore()) {
            ws.close("info")
            StatusChips.perform("cursor")
            check(ws.isFrontmost("info"), "clicking the pointer chip shows the Info panel")
            StatusChips.perform("ai")
            check(ws.isFrontmost(GenUsageUI.panelID), "clicking the AI chip opens the AI Usage panel")
        }
        StatusChips.perform("doc")
        check(app.dialog == .imageSize, "clicking the document chip opens Image Size…")
        app.dialog = nil
        StatusChips.perform("memory")
        for _ in 0..<20 where app.dialog != .preferences { UIFixesSelfTest.spin(0.05) }
        check(app.dialog == .preferences, "clicking the memory chip opens Preferences (Performance)", "\(app.dialog.map { $0.id } ?? "nil")")
        app.dialog = nil
        StatusChips.perform("autosave")
        for _ in 0..<20 where app.dialog != .preferences { UIFixesSelfTest.spin(0.05) }
        check(app.dialog == .preferences, "clicking the autosave chip opens Preferences (Workflow)")
        app.dialog = nil
        UIFixesSelfTest.spin(0.05)

        // snapshots: wide, medium, narrow (with the zoom control on the left)
        let c = CanvasView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let prevCanvas = AppActions.canvas, prevCursor = app.cursorDocPoint
        AppActions.canvas = c
        c.document = d
        c.setZoom(0.25)
        d.state.selection = SelectionOps.rectMask(CGRect(x: 100, y: 100, width: 640, height: 480), width: 3840, height: 2160)
        app.cursorDocPoint = CGPoint(x: 1204, y: 388)
        app.statusMessage = "Opened “chips.psd” — 12 layers kept editable"
        defer { AppActions.canvas = prevCanvas; app.cursorDocPoint = prevCursor; c.document = nil; app.statusMessage = "" }
        let preview = StatusBarPreview(aiKeyed: [.fal], recordingFrames: 12, memoryBytes: UInt64(1.2 * 1024 * 1_048_576))
        for (name, width) in [("ws2_statusbar_wide", 1300.0), ("ws2_statusbar_medium", 900.0), ("ws2_statusbar_narrow", 600.0)] {
            let hv = NSHostingView(rootView: StatusBar(preview: preview).environment(\.colorScheme, .dark).frame(width: width, height: 24))
            let w = KeyableWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 24), styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = hv
            w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            w.orderFrontRegardless()
            UIFixesSelfTest.spin(0.4)
            AppActions.canvas = c
            snapshot(w.contentView!, name, dir)
            if let f = ZoomUISelfTest.zoomField(w) {
                let r = f.convert(f.bounds, to: nil)
                check(r.minX >= 0 && r.maxX <= width && r.width >= 30 && f.stringValue == "25%", "\(name): the zoom control fits and works", "\(r) \(f.stringValue)")
            } else { check(false, "\(name): zoom control present") }
            w.orderOut(nil); w.contentView = nil
        }
        d.state.selection = nil
        print("workspace2: wrote snapshots to \(dir.path)")
    }

    /// Regression (Oct 2026): since macOS 14 views don't clip to their bounds, and a dock view filling its whole dirty
    /// rect painted over the canvas, tools and options bar in the real window (offscreen snapshots never showed it).
    static func testDockPaintsInsideItsBounds() {
        check(DockAreaView(frame: .zero).clipsToBounds, "the dock area clips its drawing to its bounds")
        let views: [(String, NSView)] = [("DockAreaView", DockAreaView(frame: .zero)), ("DockColumnView", DockColumnView(columnID: "probe")),
                                         ("DockContentView", DockContentView(frame: .zero)), ("FloatingContentView", FloatingContentView(frame: .zero))]
        for (name, v) in views {
            v.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.cgContext.translateBy(x: 100, y: 100)
            v.draw(CGRect(x: -100, y: -100, width: 300, height: 300))   // a dirty rect reaching far outside the view
            NSGraphicsContext.restoreGraphicsState()
            var outside = 0
            for y in stride(from: 0, to: 300, by: 10) { for x in stride(from: 0, to: 300, by: 10) where !(100..<200).contains(x) || !(100..<200).contains(y) {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 { outside += 1 }
            } }
            check(outside == 0, "\(name) paints only inside its own bounds", "\(outside) samples painted outside")
        }
    }
}
