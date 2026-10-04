import AppKit
import SwiftUI
import ImageCratCore

/// Panel sizes ("some panels get cropped"): every registered panel hosted exactly as the dock hosts it
/// (`DockContentView` + `WorkspaceManager.host`) at the sizes it really gets — the groups of every stock workspace in two
/// window sizes, at the default and the minimum column width, a short group, a wide one, a floating window and an
/// icon-column pop-over — measured against what its SwiftUI content needs (`PanelMetrics`). Content that needs more
/// room than it has must be reachable by scrolling; hosting views must have their content area's frame after tab
/// switches, resizes, collapse / expand, re-docking, floating and icon columns. Writes `panelsize/table.txt` and PNGs.
/// Views run in offscreen windows; the workspace store is temporary.
/// `LUMEN_SELFTEST_ONLY=panelsize Lumen --selftest <dir>`
enum PanelSizeSelfTest {
    static func register() {
        FeatureModules.selfTests.append(("panelsize", { run($0) }))
        PanelTour.installIfRequested()   // LUMEN_PANEL_TOUR=<dir>: the same measurements in the real window
    }

    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") panelsize: \(name)\(d.isEmpty ? "" : " — " + d)")
        fflush(stdout)
    }

    final class TestWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    typealias Row = PanelMetrics.Row
    static var rows: [(section: String, row: Row)] = []
    /// Content area of Essentials' Layers group (where a panel of no stock workspace is docked) in the 1440 × 850 window.
    static var defaultDockArea = CGSize(width: 300, height: 380)

    static func run(_ out: URL) {
        passes = 0; failures = 0; rows = []
        let dir = out.appendingPathComponent("panelsize")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppModel.shared
        let saved = (canvas: AppActions.canvas, docs: app.documents, active: app.activeDocumentID, panels: app.showPanels, secondary: app.showSecondaryPanels,
                     dialog: app.dialog, tool: app.tool)
        defer {
            app.dialog = nil
            AppActions.canvas = saved.canvas; app.documents = saved.docs; app.activeDocumentID = saved.active; app.tool = saved.tool
            app.showPanels = saved.panels; app.showSecondaryPanels = saved.secondary
            PanelMetrics.resetProbes()
            UIFixesSelfTest.spin(0.1)
        }
        app.dialog = nil
        app.showPanels = true; app.showSecondaryPanels = true
        app.tool = .move
        let d = document()
        app.documents = [d]; app.activeDocumentID = d.id
        PanelMetrics.resetProbes()
        print("panelsize: \(PanelRegistry.defs.count) registered panels: \(PanelRegistry.defs.map(\.id).joined(separator: ", "))")
        WorkspaceManager.shared.withStore(MemoryWorkspaceStore()) {
            workspaces(dir)
            everyPanel(dir)
            floating(dir)
            frames(dir)
            tour(dir)
        }
        layerStates(dir)
        brushSections()
        UIFixesSelfTest.spin(0.1)
        check(WorkspaceManager.shared.windows.isEmpty == WorkspaceManager.shared.current.floating.isEmpty, "test windows closed with the test layout")
        writeTable(dir)
        print("panelsize: \(passes) passed, \(failures) failed")
    }

    /// Background, a painted layer, a shape and a type layer (selected: Properties, Character and Paragraph show it).
    static func document() -> Document {
        var st = SelfTest.baseState(1200, 800)
        st.layers.append(FuzzScenarios.painted("Paint", w: 1200, h: 800))
        st.layers.append(SelfTest.shapeLayer(CGRect(x: 100, y: 100, width: 300, height: 200)))
        let t = FuzzScenarios.text("Panel sizes")
        st.layers.append(t)
        let d = Document(state: st, name: "panelsize")
        d.needsFitOnScreen = false
        d.activeLayerID = t.id
        d.selectedLayerIDs = [t.id]
        return d
    }

    static func record(_ section: String, _ r: Row) {
        rows.append((section, r))
        if !r.ok || r.overflows { print("panelsize: \(section): \(r.line)") }
    }

    // MARK: - Windows

    static func window(_ size: CGSize) -> TestWindow {
        let w = TestWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        return w
    }

    static func close(_ w: NSWindow) {
        w.makeFirstResponder(nil)
        UIFixesSelfTest.spin(0.05)
        w.orderOut(nil)
        w.contentView = nil
    }

    /// The real main window content (canvas, tools, dock) in an offscreen window.
    static func mainWindow(_ size: CGSize) -> (NSWindow, DockAreaView, CanvasView)? {
        let hv = NSHostingView(rootView: MainView().frame(maxWidth: .infinity, maxHeight: .infinity))
        hv.sizingOptions = []
        let w = window(size)
        w.contentView = hv
        w.orderFrontRegardless()
        w.makeKey()
        UIFixesSelfTest.spin(0.8)
        guard let canvas = Workspace2SelfTest.find(CanvasView.self, in: hv).first, let dock = Workspace2SelfTest.find(DockAreaView.self, in: hv).first else {
            check(false, "MainView hosts the canvas and the dock")
            close(w)
            return nil
        }
        AppActions.canvas = canvas
        return (w, dock, canvas)
    }

    // MARK: - Stock workspaces in the main window

    static let windowSizes = [CGSize(width: 1440, height: 850), CGSize(width: 1280, height: 720)]

    static func workspaces(_ dir: URL) {
        let ws = WorkspaceManager.shared
        for size in windowSizes {
            guard let m = mainWindow(size) else { continue }
            let (w, dock, canvas) = m
            func spin(_ s: Double = 0.1) { UIFixesSelfTest.spin(s); AppActions.canvas = canvas }
            let label = "\(Int(size.width))×\(Int(size.height))"
            for def in Workspace.builtIn {
                ws.apply(def)
                spin(0.25)
                for minWidth in [false, true] {
                    if minWidth {
                        for c in ws.current.columns where !c.iconic { ws.setColumnWidth(column: c.id, DockMetrics.minColumnWidth) }
                        spin(0.2)
                    }
                    var bad: [String] = []
                    var count = 0
                    for c in ws.current.columns where !c.iconic {
                        for g in c.groups {
                            for p in g.panels {
                                ws.select(p)
                                spin()
                                guard let gv = dock.groupView(g.id) else { bad.append("\(p): no group view"); continue }
                                let r = PanelMetrics.measure(p, in: gv.content, context: "\(def.name) \(label)\(minWidth ? " min" : "") \(Int(gv.content.bounds.width))")
                                record(minWidth ? "workspace, min width" : "workspace", r)
                                count += 1
                                if !r.ok { bad.append("\(p) \(r.verdict) needs \(Int(r.needed.width))×\(Int(r.needed.height)) in \(Int(r.given.width))×\(Int(r.given.height))") }
                                if def.name == "Essentials" && g.id == "ess.c2.g3" && !minWidth && size == windowSizes[0] { defaultDockArea = r.given }
                            }
                        }
                    }
                    check(bad.isEmpty && count > 0, "\(def.name), \(label)\(minWidth ? ", columns at the minimum width" : ""): every docked panel fits or scrolls (\(count))",
                          bad.joined(separator: "; "))
                }
                if size == windowSizes[0] { Workspace2SelfTest.composite(w.contentView!, "panelsize_\(PanelMetrics.fileName(def.name))_min", dir) }
            }
            ws.apply(.essentials)
            spin()
            close(w)
        }
    }

    // MARK: - Every registered panel at fixed sizes

    static func everyPanel(_ dir: URL) {
        let ws = WorkspaceManager.shared
        // every panel open (a host is let go of when its panel leaves the workspace)
        var all = Workspace.essentials
        for d in PanelRegistry.defs where !all.contains(d.id) { all.dockAtDefault(d.id) }
        ws.apply(all)
        let configs: [(name: String, size: (String) -> CGSize, picture: Bool)] = [
            ("dock", { _ in CGSize(width: defaultDockArea.width, height: defaultDockArea.height + DockMetrics.tabBarHeight) }, true),
            ("dock-min", { _ in CGSize(width: DockMetrics.minColumnWidth, height: defaultDockArea.height + DockMetrics.tabBarHeight) }, true),
            ("short", { _ in CGSize(width: 260, height: 150) }, true),
            ("wide", { _ in CGSize(width: DockMetrics.maxColumnWidth, height: 500) }, false),
            ("flyout", { id in DockFlyout.contentSize(for: id, screen: ws.screens.first) }, false),
        ]
        let w = window(CGSize(width: 300, height: 400))
        let gv = DockGroupView(floating: false)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        root.addSubview(gv)
        w.contentView = root
        w.orderFrontRegardless()
        defer { gv.content.show(nil); close(w) }
        var focus: [String] = []
        for (name, size, picture) in configs {
            var bad: [String] = []
            for def in PanelRegistry.defs {
                let s = size(def.id)
                w.setContentSize(s)
                root.frame = CGRect(origin: .zero, size: s)
                gv.frame = root.bounds
                gv.update(DockGroup([def.id], id: "panelsize"))
                UIFixesSelfTest.spin(0.08)
                let r = PanelMetrics.measure(def.id, in: gv.content, context: "\(name) \(Int(s.width))×\(Int(s.height))")
                record(name, r)
                if !r.ok { bad.append("\(def.id) \(r.verdict) needs \(Int(r.needed.width))×\(Int(r.needed.height)) in \(Int(r.given.width))×\(Int(r.given.height))") }
                if picture { PanelMetrics.snapshot(gv, to: dir.appendingPathComponent("\(PanelMetrics.fileName(def.id))_\(name).png")) }
                if name.hasPrefix("dock") { focus += PanelMetrics.focusRingsCut(ws.host(def.id)).map { "\(def.id) (\(name)): \($0)" } }
            }
            check(bad.isEmpty, "every registered panel (\(PanelRegistry.defs.count)) fits or scrolls: \(name)", bad.joined(separator: "; "))
        }
        check(focus.isEmpty, "no focus ring of a panel control is cut by the panel's edges (default and minimum column width)", focus.joined(separator: "; "))
        ws.apply(.essentials)
    }

    // MARK: - Floating windows

    static func floating(_ dir: URL) {
        let ws = WorkspaceManager.shared
        ws.apply(.essentials)
        var bad: [String] = []
        for def in PanelRegistry.defs {
            ws.float(def.id)
            UIFixesSelfTest.spin(0.08)
            guard let win = ws.floatingWindow(containing: def.id) else { bad.append("\(def.id): no window"); continue }
            let r = PanelMetrics.measure(def.id, in: win.groupView.content, context: "float \(Int(win.frame.width))×\(Int(win.frame.height))")
            record("float", r)
            if !r.ok { bad.append("\(def.id) \(r.verdict) needs \(Int(r.needed.width))×\(Int(r.needed.height)) in \(Int(r.given.width))×\(Int(r.given.height))") }
            ws.close(def.id)
        }
        check(bad.isEmpty, "every panel fits or scrolls in a new floating window", bad.joined(separator: "; "))
        ws.apply(.essentials)
        UIFixesSelfTest.spin(0.05)
    }

    // MARK: - Hosting frames after layout changes

    static func frameProblems(_ root: NSView) -> [String] {
        Workspace2SelfTest.find(DockContentView.self, in: root).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { cv in
            let p = PanelMetrics.frameProblems(cv)
            let id = (cv.hosted as? NSHostingView<PanelContentRoot>)?.rootView.id ?? "?"
            return p.isEmpty ? nil : "\(id): \(p)"
        }
    }

    static func frames(_ dir: URL) {
        let ws = WorkspaceManager.shared
        guard let m = mainWindow(windowSizes[0]) else { return }
        let (w, dock, canvas) = m
        defer { ws.apply(.essentials); UIFixesSelfTest.spin(0.1); close(w) }
        func spin(_ s: Double = 0.15) { UIFixesSelfTest.spin(s); AppActions.canvas = canvas }
        func verify(_ label: String, extra: [String] = []) {
            let p = frameProblems(dock) + extra
            check(p.isEmpty, "hosting views have their content area's frame after \(label)", p.joined(separator: "; "))
        }
        ws.apply(.essentials)
        spin(0.3)
        verify("the first layout")
        let g3 = "ess.c2.g3", c1 = "ess.c1", c2 = "ess.c2"

        // tab switches
        for p in ["channels", "paths", "layers"] {
            ws.select(p)
            spin()
            let gv = dock.groupView(g3)
            let others = ["layers", "channels", "paths"].filter { $0 != p }.filter { ws.host($0).window != nil }
            verify("a tab switch to \(p)", extra: (gv?.content.hosted === ws.host(p) ? [] : ["\(p) not shown"]) + others.map { "\($0) still in the window" })
        }

        // column widths (live drags go through the same call)
        for width in [DockMetrics.minColumnWidth, 420, DockMetrics.maxColumnWidth, 300] {
            ws.setColumnWidth(column: c2, width)
            spin()
            verify("the main column resized to \(Int(width)) pt")
        }
        ws.setColumnWidth(column: c1, DockMetrics.minColumnWidth)
        spin()
        verify("the secondary column at its minimum width")

        // group dividers
        if let cv = dock.columnView(c2) {
            ws.resizeGroups(column: c2, divider: 1, delta: -150, actual: cv.laidOutHeights)
            spin()
            verify("a group divider drag")
            ws.resizeGroups(column: c2, divider: 0, delta: 200, actual: cv.laidOutHeights)
            spin()
            verify("another group divider drag")
        }

        // collapse / expand
        ws.setCollapsed(group: g3, true)
        spin()
        verify("collapsing a group", extra: dock.groupView(g3)?.content.isHidden == true ? [] : ["collapsed group shows content"])
        ws.setCollapsed(group: g3, false)
        spin()
        let expanded = dock.groupView(g3).map { $0.content.frame.height > 50 } ?? false
        verify("expanding it again", extra: expanded ? [] : ["content area not restored"])

        // re-dock: split, tab into another column, a new column, back
        ws.reset()
        spin()
        ws.perform(["layers"], to: .split(group: "ess.c1.g1", below: true))
        spin()
        verify("docking Layers as a new group in the other column", extra: ws.host("layers").window === w ? [] : ["Layers not in the window"])
        ws.perform(["layers"], to: .tab(group: "ess.c2.g1", index: 1))
        spin()
        verify("docking Layers as a tab of another group")
        ws.perform(["layers"], to: .column(index: 0))
        spin()
        verify("docking Layers in a new column")
        ws.perform(["layers"], to: .tab(group: g3, index: 0))
        spin()
        verify("docking Layers back")

        // float and dock back
        ws.float("channels")
        spin()
        if let win = ws.floatingWindow(containing: "channels") {
            let inWindow = frameProblems(win.contentView!)
            let gvOK = win.groupView.frame.equalTo(win.contentView!.bounds, tolerance: 0.5)
            check(inWindow.isEmpty && gvOK, "a floating window's panel has its content area's frame", (inWindow + (gvOK ? [] : ["group \(win.groupView.frame)"])).joined(separator: "; "))
            win.setFrame(CGRect(origin: win.frame.origin, size: CGSize(width: 420, height: 520)), display: true)
            spin()
            let afterResize = frameProblems(win.contentView!)
            check(afterResize.isEmpty && abs(win.groupView.content.bounds.width - 420) < 1, "…and after the window is resized", afterResize.joined(separator: "; "))
        } else {
            check(false, "Channels floats in a window")
        }
        ws.dock("channels")
        spin()
        verify("docking a floating panel back")

        // icon column and back
        ws.setIconic(column: c1, true)
        spin()
        verify("collapsing a column to icons")
        ws.setIconic(column: c1, false)
        spin()
        verify("expanding the icon column", extra: dock.groupView("ess.c1.g2").map { $0.content.frame.width > 100 } == true ? [] : ["group not restored"])

        // secondary columns hidden / shown, window resized
        AppModel.shared.showSecondaryPanels = false
        spin(0.25)
        verify("hiding the secondary column")
        AppModel.shared.showSecondaryPanels = true
        spin(0.25)
        verify("showing it again")
        w.setContentSize(CGSize(width: 1100, height: 700))
        spin(0.3)
        verify("the window shrinking")

        // the root scroller only scrolls (and shows scroll bars) when the panel doesn't fit
        if let gv = dock.groupView(g3), let h = gv.content.hosted, let root = PanelMetrics.rootScroller(h) {
            check(root.autohidesScrollers || root.scrollerStyle == .overlay, "a panel that fits shows no scroll bars", "autohides \(root.autohidesScrollers), style \(root.scrollerStyle.rawValue)")
            let doc = root.documentView?.frame.size ?? .zero
            check(abs(doc.width - root.contentSize.width) < 1 && abs(doc.height - root.contentSize.height) < 1, "…and its scroller's document is exactly the visible area",
                  "document \(doc), visible \(root.contentSize)")
        } else {
            check(false, "the Layers group has a root scroller")
        }

        // icon-column pop-overs and new floating windows are sized from the content
        let screen = ws.screens.first
        let colorPop = DockFlyout.contentSize(for: "color", screen: screen), layersPop = DockFlyout.contentSize(for: "layers", screen: screen)
        let colorNeed = PanelMetrics.needed("color", in: CGSize(width: colorPop.width, height: 1)).height + DockMetrics.tabBarHeight
        check(abs(colorPop.height - max(colorNeed.rounded(.up), DockMetrics.minFloatSize.height)) <= 1 && colorPop.height < 460 && layersPop == CGSize(width: 300, height: 460),
              "a pop-over is as tall as a panel's controls (Color), or 460 pt for a list panel (Layers)", "color \(colorPop), layers \(layersPop)")
        let shortScreen = CGRect(x: 0, y: 0, width: 1280, height: 400)
        check(DockFlyout.contentSize(for: "assistFindLayers", screen: shortScreen).height <= 340, "…never taller than the screen leaves room for")
        let chrome = FloatingPanel.frameHeight(forContentHeight: 0)
        let colorFloat = ws.floatingSize(for: ["color"]), layersFloat = ws.floatingSize(for: ["layers"])
        check(colorFloat.height < DockMetrics.defaultFloatSize.height && colorFloat.height >= colorNeed - 1 + chrome && layersFloat.height == DockMetrics.defaultFloatSize.height,
              "a new floating window is as tall as the panel's controls, 380 pt for a list panel", "color \(colorFloat), layers \(layersFloat)")

        // the icon-column pop-over: built like DockFlyout builds it (an NSPopover isn't shown in an offscreen test)
        for id in ["history", "layers", "brushSettings", "properties", "color", "info"] {
            let size = DockFlyout.contentSize(for: id, screen: ws.screens.first)
            let fw = window(size)
            let container = DockGroupView(floating: true)
            container.frame = CGRect(origin: .zero, size: size)
            fw.contentView = container
            fw.orderFrontRegardless()
            container.update(DockGroup([id], id: "flyout"))
            UIFixesSelfTest.spin(0.1)
            let r = PanelMetrics.measure(id, in: container.content, context: "pop-over \(Int(size.width))×\(Int(size.height))")
            record("pop-over", r)
            check(r.ok, "icon-column pop-over of \(id): \(r.verdict)", r.line)
            if id == "color" {
                // the same panel in a short pop-over overflows: then its scroller clips what is scrolled away
                fw.setContentSize(CGSize(width: size.width, height: 110))
                container.frame = CGRect(origin: .zero, size: CGSize(width: size.width, height: 110))
                UIFixesSelfTest.spin(0.15)
                let root = PanelMetrics.rootScroller(ws.host(id))
                let clipped = root.map { $0.contentView.clipsToBounds || $0.contentView.layer?.masksToBounds == true } ?? false
                let r2 = PanelMetrics.measure(id, in: container.content, context: "pop-over short")
                check(clipped && r2.verdict == "scrolls", "a panel that overflows scrolls and clips at its edges", r2.line)
            }
            PanelMetrics.snapshot(container, to: dir.appendingPathComponent("\(id)_popover.png"))
            container.content.show(nil)
            close(fw)
        }
    }

    // MARK: - Panels that follow the selected layer, for every kind of layer

    /// Panels whose content depends on the active layer, measured (content only) with each core QA layer subject selected
    /// (and with its mask as the edit target when it has one), at the minimum and the default column width.
    static let layerPanels = ["properties", "layers", "character", "paragraph", "channels", "paths", "adjustments", "info", "histogram", "components",
                              "contentCredentials", "cloneSource", "assistFindLayers", "preflight"]

    static func layerStates(_ dir: URL) {
        let app = AppModel.shared
        let prev = (docs: app.documents, active: app.activeDocumentID, cursor: app.cursorDocPoint)
        defer { app.documents = prev.docs; app.activeDocumentID = prev.active; app.cursorDocPoint = prev.cursor; PanelMetrics.resetProbes() }
        // no document open: every panel
        app.documents = []; app.activeDocumentID = nil
        PanelMetrics.resetProbes()
        let empty = PanelRegistry.defs.compactMap { def -> String? in
            let need = PanelMetrics.needed(def.id, in: CGSize(width: DockMetrics.minColumnWidth, height: defaultDockArea.height))
            return need.width > DockMetrics.minColumnWidth + 0.5 ? "\(def.id) \(Int(need.width))" : nil
        }
        check(empty.isEmpty, "with no document open every panel fits a column at the minimum width", empty.joined(separator: "; "))
        let subjects = QASubjects.all().filter { $0.core || $0.name.hasPrefix("mask") }
        app.cursorDocPoint = CGPoint(x: 40, y: 40)   // (Info shows the colour under the pointer: its widest state)
        var bad: [String: [String]] = [:]
        var count = 0
        // pictures of Properties for a few kinds, at the minimum width (hosted as the dock hosts it)
        let pictured: Set<String> = ["fill.solid", "fill.gradient", "shape.rect", "generative", "artboard", "mask.linked.raster", "smart.filters"]
        let w = window(CGSize(width: DockMetrics.minColumnWidth, height: 520))
        let gv = DockGroupView(floating: false)
        gv.frame = CGRect(x: 0, y: 0, width: DockMetrics.minColumnWidth, height: 520)
        w.contentView = gv
        w.orderFrontRegardless()
        defer { gv.content.show(nil); close(w) }
        for subj in subjects {
            let (st, ids) = subj.make()
            let d = Document(state: st, name: subj.name)
            d.needsFitOnScreen = false
            d.activeLayerID = ids.last
            d.selectedLayerIDs = Set(ids)
            if subj.name.hasPrefix("mask"), d.activeLayer?.mask != nil { d.editTarget = .mask }
            app.documents = [d]; app.activeDocumentID = d.id
            PanelMetrics.resetProbes()
            if pictured.contains(subj.name) {
                gv.update(DockGroup(["properties"], id: "panelsize"))
                UIFixesSelfTest.spin(0.12)
                PanelMetrics.snapshot(gv, to: dir.appendingPathComponent("properties_\(PanelMetrics.fileName(subj.name))_min.png"))
            }
            for id in layerPanels where PanelRegistry.def(id) != nil {
                for width in [DockMetrics.minColumnWidth, 300] {
                    let given = CGSize(width: width, height: defaultDockArea.height)
                    let need = PanelMetrics.needed(id, in: given)
                    count += 1
                    if need.width > given.width + 0.5 { bad[id, default: []].append("\(subj.name) @\(Int(width)): \(Int(need.width))") }
                }
            }
        }
        for id in layerPanels {
            check(bad[id] == nil, "\(id) fits the column width with every kind of layer selected (\(subjects.count) layer subjects, 190 and 300 pt)",
                  (bad[id] ?? []).prefix(40).joined(separator: "; "))
        }
        print("panelsize: \(count) layer-state measurements")
    }

    /// Every section of Brush Settings (sections are the editor's own state) at the minimum column width.
    static func brushSections() {
        var s = AppModel.shared.activeBrushSettings
        s.dynamics.shapeEnabled = true; s.dynamics.scatterEnabled = true; s.dynamics.textureEnabled = true; s.dynamics.dualEnabled = true
        s.dynamics.colorEnabled = true; s.dynamics.transferEnabled = true
        s.dynamics.sizeControl = ControlSetting(source: .fade)
        var bad: [String] = []
        for sec in BrushSettingsSection.allCases {
            let v = BrushSettingsEditor(settings: .constant(s), section: sec).padding(10)
                .environment(\.panelWidth, DockMetrics.minColumnWidth).environment(\.colorScheme, Theme.colorScheme).font(Theme.font)
            let h = NSHostingController(rootView: v)
            let need = h.sizeThatFits(in: CGSize(width: DockMetrics.minColumnWidth, height: 2000))
            if need.width > DockMetrics.minColumnWidth + 0.5 { bad.append("\(sec.rawValue) needs \(Int(need.width))") }
        }
        check(bad.isEmpty, "every Brush Settings section fits a column at the minimum width", bad.joined(separator: "; "))
    }

    // MARK: - Tour mechanics (offscreen)

    static func tour(_ dir: URL) {
        guard let m = mainWindow(windowSizes[1]) else { return }
        let (w, dock, canvas) = m
        defer { WorkspaceManager.shared.apply(.essentials); UIFixesSelfTest.spin(0.1); close(w) }
        AppActions.canvas = canvas
        let tdir = dir.appendingPathComponent("tour")
        try? FileManager.default.createDirectory(at: tdir, withIntermediateDirectories: true)
        let panels = ["layers", "properties", "glyphs"]
        let shots = PanelTour.run(dock: dock, out: tdir, panels: panels, settle: 0.12)
        let files = shots.filter { FileManager.default.fileExists(atPath: tdir.appendingPathComponent($0.file).path) }
        let text = PanelTour.table(shots)
        try? text.write(to: tdir.appendingPathComponent("table.txt"), atomically: true, encoding: .utf8)
        check(shots.count == panels.count * 3 && files.count == shots.count, "the panel tour captures each panel at three sizes and tabulates them", "\(shots.count) shots, \(files.count) files")
        let short = shots.filter { $0.row.context == "short" }
        check(short.allSatisfy { $0.row.given.height < 140 && $0.row.given.height > 100 }, "…the short group is about 150 pt", short.map { "\($0.row.panel) \(Int($0.row.given.height))" }.joined(separator: ", "))
        check(PanelTour.requestedDir == nil, "the tour is off unless LUMEN_PANEL_TOUR is set")
    }

    // MARK: - Table

    static func writeTable(_ dir: URL) {
        var t = "Panel sizes — \(PanelRegistry.defs.count) panels, \(rows.count) measurements (given = content area under the tab bar; needed = what the panel's SwiftUI content takes when offered it)\n\n"
        var sections: [String] = []
        for r in rows where !sections.contains(r.section) { sections.append(r.section) }
        for s in sections {
            t += "== \(s)\n" + Row.header + "\n"
            for r in rows where r.section == s { t += r.row.line + "\n" }
            t += "\n"
        }
        let bad = rows.filter { !$0.row.ok }
        t += "\(bad.count) of \(rows.count) cropped or with a bad frame\n"
        try? t.write(to: dir.appendingPathComponent("table.txt"), atomically: true, encoding: .utf8)
    }
}
