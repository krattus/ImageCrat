import AppKit
import SwiftUI
import ImageCratCore

/// The fuzz phases of one scenario: every menu item, every dialog, every panel, every tool, every key.
enum FuzzDriver {
    static var done = Set<String>()
    /// Results of finished items (journal), so sub-steps of an item that opened a dialog can resume after a restart.
    static var results: [String: String] = [:]

    static func run() {
        FuzzFixtures.ensure()
        Automation.fixtureDir = FuzzFixtures.dir
        Automation.saveDir = MenuFuzz.outDir.appendingPathComponent("saves")
        if MenuFuzz.scenarioName == "probe-menu" { probeMenu(); return }
        if MenuFuzz.scenarioName == "probe-canvas" { probeCanvas(); return }
        guard let sc = FuzzScenarios.named(MenuFuzz.scenarioName) else {
            FuzzLog.note("unknown scenario \(MenuFuzz.scenarioName)")
            return
        }
        Fuzz.scenario = sc
        if let d = MenuFuzz.argument("--depth").flatMap(Int.init) { Fuzz.scenario.depth = d }   // override the scenario's depth
        FuzzAX.enable()
        let (d, crashed) = FuzzLog.loadProgress()
        done = d
        for k in crashed { FuzzLog.crashed(k) }
        if let s = try? String(contentsOf: FuzzLog.progressURL, encoding: .utf8) {
            for line in s.split(separator: "\n") {
                let p = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                if p.count == 3, p[0] == "END" { results[p[1]] = p[2] }
            }
        }
        let phases = (MenuFuzz.argument("--phases") ?? "menu,dialogs,panels,tools,keys,misc,chrome").split(separator: ",").map(String.init)
        FuzzLog.note("scenario \(sc.name) core=\(sc.core) phases=\(phases) resume: \(done.count) done, \(crashed.count) crashed")
        Fuzz.rebuild("startup")
        Fuzz.forceDisplay()
        for ph in phases {
            switch ph {
            case "menu": menuPhase()
            case "dialogs": directDialogPhase()
            case "panels": panelPhase()
            case "tools": toolPhase()
            case "chrome": chromePhase()
            case "keys": keyPhase()
            case "misc": miscPhase()
            case "profile": profilePhase()
            default: break
            }
        }
        Fuzz.reset("teardown")
    }

    /// Runs one journaled step unless an earlier run already finished (or crashed in) it.
    /// `--only=<text>`: run just the steps whose key contains the text (debugging a single item).
    static let only = MenuFuzz.argument("--only")

    @discardableResult
    static func step(_ key: String, _ body: () -> String) -> String? {
        if done.contains(key) { return results[key] }
        if let o = only, !key.contains(o) { return nil }
        FuzzLog.begin(key)
        let t0 = Date()
        let r = body() + " ms=\(Int(Date().timeIntervalSince(t0) * 1000))"
        FuzzLog.end(key, r)
        done.insert(key)
        results[key] = r
        return r
    }

    /// Does a click on the canvas reach it while a non-dimming dialog (Blur Gallery pins, Levels eyedroppers) is open?
    static func probeCanvas() {
        Fuzz.scenario = FuzzScenarios.named("raster")!
        func clickCanvas() -> Bool {
            guard let c = AppActions.canvas, let w = c.window else { return false }
            c.lastMouseView = nil
            let p = c.convert(NSPoint(x: c.bounds.midX - 40, y: c.bounds.midY + 30), to: nil)
            Fuzz.click(p, in: w)
            Fuzz.spin(0.1)
            return c.lastMouseView != nil
        }
        Fuzz.rebuild()
        FuzzLog.note("PROBE canvas click, no dialog: reached=\(clickCanvas())")
        Fuzz.rebuild()
        AppActions.startBlurGallery(.fieldBlur)
        Fuzz.spin(0.3)
        let pins0 = AppActions.blurGallery?.inst.points.count ?? -1
        let reached = clickCanvas()
        FuzzLog.note("PROBE canvas click under Blur Gallery: reached=\(reached) dialog=\(AppModel.shared.dialog?.id ?? "nil") pins \(pins0) → \(AppActions.blurGallery?.inst.points.count ?? -1)")
        Fuzz.rebuild()
        AppModel.shared.dialog = .adjustment(.levels)
        Fuzz.spin(0.3)
        FuzzLog.note("PROBE canvas click under Levels (no dropper armed): reached=\(clickCanvas())")
        var sampled = false
        CanvasSampler.shared.arm("probe") { _, _ in sampled = true }
        Fuzz.spin(0.2)
        _ = clickCanvas()
        FuzzLog.note("PROBE canvas click under Levels (dropper armed): sampled=\(sampled)")
        CanvasSampler.shared.disarm()
    }

    /// Infrastructure check: when does SwiftUI refresh the enabled state / titles of main-menu items?
    static func probeMenu() {
        FuzzLog.note("PROBE windows before: key=\(NSApp.keyWindow != nil) main=\(NSApp.mainWindow != nil) active=\(NSApp.isActive)")
        Fuzz.mainWindow?.makeMain(); Fuzz.mainWindow?.makeKey()
        Fuzz.spin(0.1)
        FuzzLog.note("PROBE windows after makeMain/makeKey: key=\(NSApp.keyWindow != nil) main=\(NSApp.mainWindow != nil) isKey=\(Fuzz.mainWindow?.isKeyWindow ?? false) isMain=\(Fuzz.mainWindow?.isMainWindow ?? false)")
        func state(_ label: String) {
            let l = Fuzz.leaves()
            let a = l.first { $0.path.hasSuffix("Layers to Files…") }
            let b = l.first { $0.path.contains("Mode") && $0.item.title.contains("RGB Color") }
            let c = l.first { $0.path.hasSuffix("Curves…") && $0.path.contains("Adjustments") }
            let on = l.filter { $0.isAppCommand && $0.item.isEnabled }.count
            FuzzLog.note("PROBE \(label): enabled app commands \(on)/\(l.count); invert=\(l.first { $0.path.hasSuffix("Invert") }?.item.isEnabled ?? false) gaussian=\(l.first { $0.path.hasSuffix("Gaussian Blur…") }?.item.isEnabled ?? false) paste=\(l.first { $0.path.hasSuffix("Edit ▸ Paste") }?.item.isEnabled ?? false)")
            FuzzLog.note("PROBE \(label): layersToFiles.enabled=\(a?.item.isEnabled ?? false) rgbTitle=[\(b?.item.title ?? "?")] curvesKey=[\(c.map { Fuzz.shortcut($0.item) } ?? "?")] windowItems=\(l.filter { $0.path.hasPrefix("Window") }.count)")
        }
        state("no doc")
        Fuzz.scenario = FuzzScenarios.named("raster")!
        Fuzz.rebuild()
        state("doc, after 0.04s")
        Fuzz.spin(0.5)
        state("doc, after 0.5s more")
        if let main = NSApp.mainMenu {
            func poke(_ m: NSMenu) {
                m.delegate?.menuNeedsUpdate?(m)
                for i in m.items { if let s = i.submenu { poke(s) } }
            }
            poke(main)
        }
        state("after delegate.menuNeedsUpdate")
        Fuzz.spin(0.3)
        state("after spin")
        if let main = NSApp.mainMenu {
            func poke(_ m: NSMenu) {
                m.delegate?.menuWillOpen?(m)
                for i in m.items { if let s = i.submenu { poke(s) } }
            }
            poke(main)
        }
        state("after delegate.menuWillOpen")
        if let e = Fuzz.keyEvent("j", [.command, .option, .control]) { _ = NSApp.mainMenu?.performKeyEquivalent(with: e) }
        state("after performKeyEquivalent(unused combo)")
        for (c, ci) in [("Z", "Z"), ("z", "Z"), ("z", "z"), ("Z", "z")] {
            let before = AppActions.doc?.historyIndex ?? -1
            AppActions.doc?.undo()
            let mid = AppActions.doc?.historyIndex ?? -1
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Fuzz.mainWindow?.windowNumber ?? 0,
                                     context: nil, characters: c, charactersIgnoringModifiers: ci, isARepeat: false, keyCode: 6)!
            let r = NSApp.mainMenu?.performKeyEquivalent(with: e) ?? false
            FuzzLog.note("PROBE ⇧⌘Z chars=\(c) ignoring=\(ci): handled=\(r) history \(before) → \(mid) → \(AppActions.doc?.historyIndex ?? -1)")
        }
        for l in Fuzz.leaves() where !l.item.keyEquivalent.isEmpty && l.item.keyEquivalent.lowercased() == "m" { FuzzLog.note("PROBE m-key: \(l.path) \(Fuzz.shortcut(l.item)) action=\(l.item.action.map { NSStringFromSelector($0) } ?? "-")") }
        for l in Fuzz.leaves() where l.path.hasPrefix("Window") { FuzzLog.note("PROBE window: \(l.path) [\(Fuzz.shortcut(l.item))]") }
        FuzzLog.note("PROBE delegates: " + (NSApp.mainMenu?.items.prefix(4).map { "\($0.title):\($0.submenu?.delegate.map { String(describing: type(of: $0)) } ?? "nil")" }.joined(separator: ", ") ?? ""))
    }

    static func profilePhase() {
        func time(_ name: String, _ n: Int = 10, _ f: () -> Void) {
            let t = Date()
            for _ in 0..<n { f() }
            FuzzLog.note("PROFILE \(name): \(Int(Date().timeIntervalSince(t) * 1000 / Double(n))) ms")
        }
        time("rebuild") { Fuzz.rebuild() }
        time("leaves") { _ = Fuzz.leaves() }
        time("findLeaf") { _ = findLeaf("Filter ▸ Blur ▸ Gaussian Blur…") }
        time("snapshot") { _ = Fuzz.snapshot() }
        time("snapshot-nopixels") { _ = Fuzz.snapshot(pixels: false) }
        time("forceDisplay") { Fuzz.forceDisplay() }
        time("validateAll") { Fuzz.validateAll("profile") }
        time("axNodes") { _ = axNodes() }
        time("spin0") { Fuzz.spin(0) }
        time("spin0.05") { Fuzz.spin(0.05) }
    }

    // MARK: Observation after a command

    /// What a command did, plus findings for anything that looks broken.
    static func observe(_ key: String, base: Fuzz.Snapshot) -> String {
        let app = AppModel.shared
        let now = Fuzz.snapshot()
        var parts: [String] = []
        if now.docCount != base.docCount { parts.append("docs\(now.docCount - base.docCount > 0 ? "+" : "")\(now.docCount - base.docCount)") }
        if now.docID == base.docID {
            let dh = now.historyCount - base.historyCount
            if dh != 0 { parts.append("hist\(dh > 0 ? "+" : "")\(dh)") }
            if now.historyIndex != base.historyIndex && dh == 0 { parts.append("histIndex\(now.historyIndex - base.historyIndex)") }
            if now.committedFP != base.committedFP { parts.append("changed") }
            else if dh > 0 { parts.append("noop-step") }
        } else if now.docCount == base.docCount { parts.append("switched-doc") }
        if let d = now.dialog, d != base.dialog { parts.append("dlg=\(d)") }
        if now.dialog == nil, base.dialog != nil { parts.append("dialog-closed") }
        if now.tool != base.tool { parts.append("tool=\(now.tool)") }
        if now.busy && !base.busy { parts.append("session") }
        if !now.busy && base.busy { parts.append("session-ended") }
        if Automation.beeps > Fuzz.beepsAtReset { parts.append("beep") }
        for r in Automation.requests.prefix(4) { parts.append("ui:\(r.kind)[\(r.detail.prefix(60))]→\(r.answer.prefix(30))") }
        if !app.statusMessage.isEmpty, parts.isEmpty { parts.append("status[\(app.statusMessage.prefix(60))]") }

        // invariants
        Fuzz.validateAll(key)
        if now.dialog == nil, !now.busy, let d = app.activeDocument {
            if now.stateFP != now.committedFP {
                FuzzLog.finding(key, "document changed without a history step (state ≠ committed state) — Undo cannot restore it")
            }
            if now.overrides > 0 { FuzzLog.finding(key, "live preview left behind (\(now.overrides) contentOverrides) with no dialog or session") }
            if now.displayOverride && !base.displayOverride { FuzzLog.finding(key, "displayOverride left behind") }
            if now.hidden > base.hidden { FuzzLog.finding(key, "hiddenLayers left behind (\(now.hidden))") }
            _ = d
        }
        return parts.isEmpty ? "nothing" : parts.joined(separator: " ")
    }

    // MARK: Menu phase

    static func menuPhase() {
        Fuzz.rebuild("menu")
        // The baseline is rebuilt identically before every item, so system items and items that are disabled in it
        // are settled once here (no rebuild needed for them).
        let items = Fuzz.leaves().map { (path: $0.path, app: $0.isAppCommand, enabled: $0.item.isEnabled, key: Fuzz.shortcut($0.item)) }
        FuzzLog.note("menu items: \(items.count), app commands \(items.filter(\.app).count), enabled \(items.filter { $0.app && $0.enabled }.count)")
        for it in items {
            let path = it.path
            let key = "menu:" + path
            guard it.app || !it.enabled else { continue }          // Hide, Quit, Services, Writing Tools… are never invoked
            if !it.enabled { step(key) { "off" + (it.key.isEmpty ? "" : " key=\(it.key)") }; continue }
            var opened: String? = nil
            let r = step(key) { invokeMenu(path, key: key, answer: .cancel) }
            if let r, let range = r.range(of: "dlg=") {
                opened = String(r[range.upperBound...].prefix { $0 != " " })
            }
            if let r, r.contains("ui:"), !r.contains("dlg=") {
                // something asked a question (alert / file panel): run it again answering OK with a fixture file
                step(key + "#answerOK") { invokeMenu(path, key: key + "#answerOK", answer: .ok) }
            }
            if let dlg = opened, Fuzz.scenario.name.hasPrefix("dialog_") == false {
                exerciseDialog(key, id: dlg) { openViaMenu(path) }
            }
        }
    }

    static func findLeaf(_ path: String) -> Fuzz.Leaf? { Fuzz.leaves().first { $0.path == path } }

    static func openViaMenu(_ path: String) -> Bool {
        guard let leaf = findLeaf(path), leaf.isAppCommand, leaf.item.isEnabled else { return false }
        leaf.menu.performActionForItem(at: leaf.index)
        return true
    }

    static func invokeMenu(_ path: String, key: String, answer: Automation.Answer) -> String {
        Fuzz.rebuild(key)
        guard let leaf = findLeaf(path) else { return "missing" }
        let enabled = leaf.item.isEnabled
        let sc = Fuzz.shortcut(leaf.item)
        var prefix = (enabled ? "on" : "off") + (sc.isEmpty ? "" : " key=\(sc)")
        guard leaf.isAppCommand else { return prefix + " system" }
        guard enabled else { return prefix }
        let base = Fuzz.snapshot()
        Automation.answer = answer
        leaf.menu.performActionForItem(at: leaf.index)
        Fuzz.spin(0.06)
        Fuzz.forceDisplay()
        let r = observe(key, base: base)
        if AppModel.shared.dialog != nil, base.dialog == nil {
            // (a) Cancel must restore the document exactly
            prefix += " " + cancelCheck(key, atOpen: Fuzz.snapshot())
        } else if base.dialog != nil {
            // the scenario had a dialog open and a command ran underneath it: dismissing whatever dialog is up now must
            // leave a consistent document (no preview, nothing uncommitted)
            while AppModel.shared.dialog != nil { if cancelDialog() == "none" { break } }
            Fuzz.spin(0.05)
            Fuzz.validateAll(key)
            let now = Fuzz.snapshot()
            if !now.busy, AppModel.shared.activeDocument != nil {
                leftovers(key, "command under dialog \(base.dialog ?? "?"), then Cancel,", now)
                if now.stateFP != now.committedFP { FuzzLog.finding(key, "command under dialog \(base.dialog ?? "?"), then Cancel: document differs from its last history state") }
            }
        }
        Automation.answer = .cancel
        return prefix + " " + r
    }

    // MARK: Dialog exerciser

    static let cancelTitles = ["Cancel", "Close", "Done", "Dismiss"]
    static let okTitles = ["OK", "Apply", "Done", "Create", "Export…", "Export", "Save", "Render", "Run", "Place", "Generate", "Convert", "Select", "Commit", "Open", "Merge", "Process", "Close"]

    static func axNodes() -> [FuzzAX.Node] {
        guard let cv = Fuzz.mainWindow?.contentView else { return [] }
        return FuzzAX.tree(cv)
    }

    /// Nodes of the dialog card (the accessibility container `DialogOverlay` marks with its identifier).
    static func dialogNodes() -> [FuzzAX.Node] {
        guard let cv = Fuzz.mainWindow?.contentView else { return [] }
        let all = FuzzAX.tree(cv)
        guard let i = all.firstIndex(where: { FuzzAX.identifier($0.element) == DialogOverlay.accessibilityID }) else { return [] }
        var out: [FuzzAX.Node] = []
        var j = i + 1
        while j < all.count, all[j].depth > all[i].depth { out.append(all[j]); j += 1 }
        return out
    }

    static func escapeEvent() -> NSEvent? { Fuzz.keyEvent("\u{1b}") }
    static func returnEvent() -> NSEvent? { Fuzz.keyEvent("\r") }

    /// Dismisses the open dialog the way a user can; returns how.
    @discardableResult
    static func cancelDialog() -> String {
        let app = AppModel.shared
        guard app.dialog != nil else { return "none" }
        if let e = escapeEvent(), let w = Fuzz.mainWindow { _ = w.performKeyEquivalent(with: e) }
        Fuzz.spin(0.06)
        if app.dialog == nil { return "esc" }
        let nodes = dialogNodes()
        for t in cancelTitles {
            if let n = nodes.last(where: { $0.role == "AXButton" && $0.label == t }) {
                FuzzAX.press(n.element)
                Fuzz.spin(0.06)
                if app.dialog == nil { return "button:\(t)" }
            }
        }
        app.dialog = nil
        Fuzz.spin(0.05)
        return "forced"
    }

    @discardableResult
    static func confirmDialog() -> String {
        let app = AppModel.shared
        guard let id = app.dialog?.id else { return "none" }
        if let e = returnEvent(), let w = Fuzz.mainWindow { _ = w.performKeyEquivalent(with: e) }
        waitForDialogToClose(id, 0.3)
        if app.dialog?.id != id { return "return" }
        let nodes = dialogNodes()
        var tried = 0
        for t in okTitles where tried < 2 {
            if let n = nodes.last(where: { $0.role == "AXButton" && $0.label == t && FuzzAX.isEnabled($0.element) }) {
                tried += 1
                FuzzAX.press(n.element)
                waitForDialogToClose(id, 0.25)
                if app.dialog?.id != id { return "button:\(t)" }
            }
        }
        return "stuck"
    }

    static func waitForDialogToClose(_ id: String, _ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        Fuzz.spin(0.04)
        while AppModel.shared.dialog?.id == id, Date() < until { Fuzz.spin(0.02) }
    }

    /// (a) Cancel → the document equals what it was when the dialog opened; nothing is left behind.
    static func cancelCheck(_ key: String, atOpen: Fuzz.Snapshot) -> String {
        let how = cancelDialog()
        Fuzz.spin(0.05)
        let now = Fuzz.snapshot()
        if how == "forced" { FuzzLog.finding(key, "dialog \(atOpen.dialog ?? "?") has no Cancel / Close reachable by Esc or a button") }
        if now.dialog != nil { FuzzLog.finding(key, "Cancel opened another dialog: \(now.dialog!)"); cancelDialog() }
        if now.docID == atOpen.docID, now.docCount == atOpen.docCount {
            if now.stateFP != atOpen.committedFP { FuzzLog.finding(key, "Cancel of \(atOpen.dialog ?? "?") did not restore the document (\(how))") }
            if now.historyCount != atOpen.historyCount { FuzzLog.finding(key, "Cancel of \(atOpen.dialog ?? "?") recorded \(now.historyCount - atOpen.historyCount) history step(s)") }
        } else {
            FuzzLog.finding(key, "Cancel of \(atOpen.dialog ?? "?") changed the open documents (\(atOpen.docCount) → \(now.docCount))")
        }
        leftovers(key, "Cancel of \(atOpen.dialog ?? "?")", now)
        return "cancel=\(how)"
    }

    static func leftovers(_ key: String, _ what: String, _ now: Fuzz.Snapshot) {
        if CanvasSampler.shared.isArmed { FuzzLog.finding(key, "\(what) left the canvas eyedropper armed") }
        if now.busy { return }      // a pending transform / text edit owns previews of its own
        if now.overrides > 0 { FuzzLog.finding(key, "\(what) left a live preview behind (\(now.overrides) contentOverrides)") }
        if now.displayOverride { FuzzLog.finding(key, "\(what) left displayOverride behind") }
        if now.hidden > 0 && !now.busy { FuzzLog.finding(key, "\(what) left hiddenLayers behind") }
    }

    /// (b) OK → nothing or exactly one history step, and Undo restores the document.
    static func okCheck(_ key: String, atOpen: Fuzz.Snapshot, strict: Bool = true) -> String {
        let app = AppModel.shared
        let how = confirmDialog()
        if how == "stuck" {
            let r = cancelDialog()
            Fuzz.validateAll(key)
            return "ok=stuck(\(r))"
        }
        Fuzz.spin(0.06)
        if app.dialog != nil { cancelDialog() }
        Fuzz.forceDisplay()
        Fuzz.validateAll(key)
        if only != nil { FuzzLog.note("OP\t\(key)\tlastFilter=\(String(describing: AppActions.lastFilter?.values)) hist=\(app.activeDocument?.history.last?.name ?? "-")") }
        let now = Fuzz.snapshot()
        var out = "ok=\(how)"
        guard now.docID == atOpen.docID, now.docCount == atOpen.docCount, let d = app.activeDocument else { return out + " docs-changed" }
        let dh = now.historyCount - atOpen.historyCount
        out += " hist+\(dh)"
        if !now.busy {
            if now.stateFP != now.committedFP { FuzzLog.finding(key, "OK of \(atOpen.dialog ?? "?") changed the document without a history step") }
            leftovers(key, "OK of \(atOpen.dialog ?? "?")", now)
        }
        guard strict else { return out }
        if dh > 1 { FuzzLog.finding(key, "OK of \(atOpen.dialog ?? "?") recorded \(dh) history steps (expected one)") }
        if dh == 1, !now.busy {
            if now.committedFP == atOpen.committedFP { out += " noop-step" }
            d.undo()
            Fuzz.spin(0.03)
            if Fuzz.fingerprint(d.state) != atOpen.committedFP { FuzzLog.finding(key, "Undo after OK of \(atOpen.dialog ?? "?") does not restore the document") }
        }
        return out
    }

    /// Re-opens a dialog on a fresh baseline. Returns false if it didn't open.
    static func reopen(_ key: String, id: String, _ open: () -> Bool) -> Bool {
        Fuzz.rebuild(key)
        guard open() else { return false }
        Fuzz.spin(0.08)
        guard AppModel.shared.dialog != nil else { return false }
        Fuzz.forceDisplay()
        return true
    }

    static func exerciseDialog(_ key: String, id: String, _ open: @escaping () -> Bool) {
        step(key + "#ok") {
            guard reopen(key + "#ok", id: id, open) else { return "did-not-open" }
            return okCheck(key + "#ok", atOpen: Fuzz.snapshot())
        }
        guard Fuzz.scenario.core else { return }
        for (suffix, confirm) in [("#fuzz-cancel", false), ("#fuzz-ok", true)] {
            step(key + suffix) {
                let k = key + suffix
                guard reopen(k, id: id, open) else { return "did-not-open" }
                let atOpen = Fuzz.snapshot()
                var rng = FuzzRNG(k)
                let n = fuzzControls(k, nodes: dialogNodes(), rng: &rng, dialogID: id, monkey: true)
                if AppModel.shared.dialog?.id != id {
                    // a control closed or replaced the dialog
                    if AppModel.shared.dialog != nil { cancelDialog() }
                    Fuzz.validateAll(k)
                    return "controls=\(n) dialog-gone"
                }
                return "controls=\(n) " + (confirm ? okCheck(k, atOpen: atOpen, strict: false) : cancelCheck(k, atOpen: atOpen))
            }
        }
        // (d) the document goes away / changes underneath the open dialog (floating panels, scripts and ⌘Z can do that)
        guard Fuzz.scenario.depth >= 2 else { return }
        let under: [(String, () -> Void, Bool)] = [
            ("#close-ok", { if let d = AppModel.shared.activeDocument { AppModel.shared.close(d) } }, true),
            ("#close-cancel", { if let d = AppModel.shared.activeDocument { AppModel.shared.close(d) } }, false),
            ("#switch-ok", { FuzzScenarios.open([FuzzScenarios.text()], w: 97, h: 61, name: "Other") }, true),
            ("#undo-ok", { AppActions.undo() }, true),
            ("#undo-cancel", { AppActions.undo() }, false),
        ]
        for (suffix, change, confirm) in under {
            step(key + suffix) {
                let k = key + suffix
                guard reopen(k, id: id, open) else { return "did-not-open" }
                change()
                Fuzz.spin(0.06)
                Fuzz.forceDisplay()
                let how = confirm ? confirmDialog() : cancelDialog()
                Fuzz.spin(0.06)
                if AppModel.shared.dialog != nil { cancelDialog() }
                Fuzz.forceDisplay()
                Fuzz.validateAll(k)
                if !Fuzz.busy {
                    for d in AppModel.shared.documents {
                        if d.contentOverrides.count > 0 { FuzzLog.finding(k, "preview left behind on “\(d.name)” after the document changed under dialog \(id)") }
                        if d.displayOverride != nil { FuzzLog.finding(k, "displayOverride left behind on “\(d.name)” after the document changed under dialog \(id)") }
                        if !d.showSelectionEdges { FuzzLog.finding(k, "selection edges left hidden on “\(d.name)” after the document changed under dialog \(id)") }
                        if Fuzz.fingerprint(d.state) != Fuzz.fingerprint(d.committedState) { FuzzLog.finding(k, "“\(d.name)” changed without a history step after the document changed under dialog \(id)") }
                    }
                }
                return how
            }
        }
    }

    // MARK: Control fuzz (dialogs and panels)

    static func isOperable(_ n: FuzzAX.Node) -> Bool {
        switch n.role {
        case "AXButton", "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle", "AXSlider", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXIncrementor", "AXToggle", "AXSwitch":
            return FuzzAX.isEnabled(n.element)
        default:
            return false
        }
    }

    static let textValues = ["0", "-3", "7", "abc", "", "0.5", "nan", "inf", "1e20", "100", "99999999999999999999", "-0"]

    /// Operates one control. Returns a short description.
    static func operate(_ n: FuzzAX.Node, rng: inout FuzzRNG) -> String {
        let cell = n.element as? NSCell
        switch n.role {
        case "AXSlider":
            if let s = cell?.controlView as? NSSlider {
                let choices = [s.minValue, s.maxValue, s.minValue + (s.maxValue - s.minValue) * rng.unit()]
                s.doubleValue = choices[rng.int(3)]
                if let a = s.action { NSApp.sendAction(a, to: s.target, from: s) }
                return "slider→\(s.doubleValue)"
            }
            FuzzAX.perform(n.element, rng.int(2) == 0 ? "AXIncrement" : "AXDecrement")
            return "slider±"
        case "AXPopUpButton", "AXMenuButton":
            if let b = cell?.controlView as? NSPopUpButton, let menu = b.menu {
                // Pickers keep their items in the menu. (SwiftUI `Menu` pull-downs build theirs only while the menu is
                // really tracking the mouse, which headless mode never allows — those stay unexercised.)
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                let items = menu.items.enumerated().filter { !$0.element.isSeparatorItem && !$0.element.isHidden && $0.element.isEnabled && $0.element.submenu == nil }
                    .filter { !(b.pullsDown && $0.offset == 0) }
                guard !items.isEmpty else { return "popup(empty)" }
                let pick = items[rng.int(items.count)]
                if pick.element.action != nil {
                    menu.performActionForItem(at: pick.offset)
                } else {
                    // a picker: the button itself reports the selection
                    b.selectItem(at: pick.offset)
                    if let a = b.action { NSApp.sendAction(a, to: b.target, from: b) }
                }
                return "popup→\(pick.element.title)"
            }
            return "popup(skipped)"
        case "AXTextField":
            if let tf = cell?.controlView as? NSTextField, tf.isEditable, let w = tf.window {
                let v = textValues[rng.int(textValues.count)]
                w.makeFirstResponder(tf)
                if let ed = tf.currentEditor() as? NSTextView {
                    ed.selectAll(nil)
                    ed.insertText(v, replacementRange: ed.selectedRange())
                    ed.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                } else {
                    tf.stringValue = v
                    if let a = tf.action { NSApp.sendAction(a, to: tf.target, from: tf) }
                }
                w.makeFirstResponder(nil)
                return "text→“\(v)”"
            }
            return "text(skipped)"
        case "AXIncrementor":
            FuzzAX.perform(n.element, rng.int(2) == 0 ? "AXIncrement" : "AXDecrement")
            return "stepper"
        default:
            return FuzzAX.press(n.element) ? "press[\(n.label.prefix(24))]" : "press-failed"
        }
    }

    /// Changes every reachable control of a dialog (min / max / random values, toggles, pop-ups, buttons), then pokes
    /// the custom gesture-driven controls with synthetic clicks and drags. Returns the number of operations.
    static func fuzzControls(_ key: String, nodes: [FuzzAX.Node], rng: inout FuzzRNG, dialogID: String?, monkey: Bool) -> Int {
        let app = AppModel.shared
        var count = 0
        let closing = Set(cancelTitles + okTitles)
        let controls = nodes.filter { isOperable($0) && !($0.role == "AXButton" && closing.contains($0.label)) }
        for n in controls.prefix(70) {
            if let id = dialogID, app.dialog?.id != id { break }
            let what = operate(n, rng: &rng)
            count += 1
            Fuzz.spin(0.02)
            if only != nil { FuzzLog.note("OP\t\(key)\t\(n.role) [\(n.label)] \(what)") }
            if let id = dialogID, let now = app.dialog?.id, now != id { FuzzLog.note("INFO\t\(key)\t\(what) replaced dialog \(id) with \(now)") }
        }
        guard monkey, let id = dialogID, app.dialog?.id == id, let w = Fuzz.mainWindow else { return count }
        // frame of the dialog card in window coordinates
        var union: NSRect? = nil
        for n in nodes {
            if let f = FuzzAX.frame(n.element) {
                let r = w.convertFromScreen(f)
                if r.width < 900 && r.height < 900 { union = union.map { $0.union(r) } ?? r }
            }
        }
        if var u = union {
            u = u.insetBy(dx: -8, dy: -8).intersection(w.contentView?.frame ?? u)
            let closers = nodes.filter { $0.role == "AXButton" && closing.contains($0.label) }.compactMap { FuzzAX.frame($0.element).map { w.convertFromScreen($0).insetBy(dx: -4, dy: -4) } }
            for _ in 0..<24 {
                guard app.dialog?.id == id else { break }
                let p = NSPoint(x: u.minX + u.width * rng.unit(), y: u.minY + u.height * rng.unit())
                if closers.contains(where: { $0.contains(p) }) { continue }
                if rng.int(3) == 0 {
                    let q = NSPoint(x: min(u.maxX, max(u.minX, p.x + (rng.unit() - 0.5) * 120)), y: min(u.maxY, max(u.minY, p.y + (rng.unit() - 0.5) * 60)))
                    if closers.contains(where: { $0.contains(q) }) { continue }
                    Fuzz.click(p, in: w, dragTo: q)
                } else {
                    Fuzz.click(p, in: w)
                }
                count += 1
            }
            Fuzz.mainWindow?.makeFirstResponder(nil)
        }
        return count
    }

    // MARK: Direct dialog phase (dialogs the menu walk didn't open)

    static func allDialogs() -> [(String, () -> Bool)] {
        let app = AppModel.shared
        var list: [(String, () -> Bool)] = []
        func add(_ d: ActiveDialog) { list.append((d.id, { app.dialog = d; return true })) }
        for d: ActiveDialog in [.newDocument, .imageSize, .canvasSize, .export, .fill, .stroke, .colorRange, .gradientEditor, .about, .shortcuts, .liquify,
                                .selectAndMask, .focusArea, .globalLight, .batch, .preferences, .colorProfile(convert: false), .colorProfile(convert: true), .proofSetup] { add(d) }
        for k: ModifySelectionKind in [.expand, .contract, .border, .smooth, .feather] { add(.modifySelection(k)) }
        for k in AdjustmentKind.allCases { add(.adjustment(k)) }
        for k in FilterKind.allCases {
            list.append((ActiveDialog.filter(k, smartLayer: nil, editingFilter: nil).id, {
                let smart = AppActions.doc?.activeLayer?.isSmartObject == true ? AppActions.doc?.activeLayerID : nil
                app.dialog = .filter(k, smartLayer: smart, editingFilter: nil)
                return true
            }))
        }
        list.append(("style-active", {
            guard let id = AppActions.doc?.activeLayerID else { return false }
            app.dialog = .layerStyle(id)
            return true
        }))
        list.append((ActiveDialog.warpText.id, { TypeEdit.openWarpDialog(); return app.dialog != nil }))
        list.append((ActiveDialog.blurGallery.id, { AppActions.startBlurGallery(.fieldBlur); return app.dialog != nil }))
        for id in DialogRegistry.builders.keys.sorted() { add(.custom(id)) }
        return list
    }

    static func directDialogPhase() {
        var seen = Set<String>()
        for (_, r) in results {
            if let range = r.range(of: "dlg=") { seen.insert(String(r[range.upperBound...].prefix { $0 != " " })) }
        }
        for (id, open) in allDialogs() where !seen.contains(id) {
            let key = "dialog:" + id
            let r = step(key) {
                guard reopen(key, id: id, open) else { return "did-not-open" }
                let atOpen = Fuzz.snapshot()
                return "direct dlg=\(atOpen.dialog ?? "?") " + cancelCheck(key, atOpen: atOpen)
            }
            if let r, r != "did-not-open", !Fuzz.scenario.name.hasPrefix("dialog_") { exerciseDialog(key, id: id, open) }
        }
    }

    // MARK: Panels

    static func floatingWindow(_ id: String) -> NSWindow? {
        NSApp.windows.first { ($0 as? FloatingPanel)?.panelID == id }
    }

    static func panelPhase() {
        let ws = WorkspaceManager.shared
        let ids = PanelRegistry.defs.map(\.id)
        var controlCounts: [String: Int] = [:]
        for id in ids {
            let key = "panel:" + id
            let r = step(key) {
                Fuzz.rebuild(key)
                // docked + focused in the main window
                ws.toggle(id)
                Fuzz.spin(0.08)
                Fuzz.forceDisplay()
                // floating in its own window (NSHostingView + layout + display)
                ws.float(id)
                Fuzz.spin(0.12)
                Fuzz.forceDisplay()
                var n = 0
                if let w = floatingWindow(id), let cv = w.contentView {
                    n = FuzzAX.tree(cv).filter(isOperable).count
                } else {
                    FuzzLog.finding(key, "floating panel window for \(id) did not open")
                }
                ws.dock(id, secondary: true)
                Fuzz.spin(0.05)
                ws.close(id)
                Fuzz.spin(0.05)
                if ws.isVisible(id) { FuzzLog.finding(key, "panel \(id) still visible after close") }
                ws.toggle(id)
                Fuzz.spin(0.05)
                Fuzz.forceDisplay()
                Fuzz.validateAll(key)
                return "controls=\(n)"
            }
            if let r, let range = r.range(of: "controls=") { controlCounts[id] = Int(r[range.upperBound...].prefix { $0.isNumber }) ?? 0 }
        }
        guard Fuzz.scenario.core else { return }
        for id in ids {
            for i in 0..<min(controlCounts[id] ?? 0, 48) {
                let key = "panelctl:\(id):\(i)"
                step(key) {
                    Fuzz.rebuild(key)
                    ws.float(id)
                    Fuzz.spin(0.1)
                    guard let w = floatingWindow(id), let cv = w.contentView else { return "no-window" }
                    let controls = FuzzAX.tree(cv).filter(isOperable)
                    guard i < controls.count else { return "gone" }
                    let base = Fuzz.snapshot()
                    var rng = FuzzRNG(key)
                    let what = operate(controls[i], rng: &rng)
                    Fuzz.spin(0.06)
                    Fuzz.forceDisplay()
                    var r = what + " → " + observe(key, base: base)
                    if AppModel.shared.dialog != nil { r += " " + cancelCheck(key, atOpen: Fuzz.snapshot()) }
                    return r
                }
            }
        }
    }

    // MARK: Main window chrome (options bar per tool, tools palette, document tabs, status bar, timeline)

    /// Operable controls of the main window outside the docked panel columns and outside a dialog.
    static func chromeControls(barOnly: Bool) -> [FuzzAX.Node] {
        guard let w = Fuzz.mainWindow, let cv = w.contentView else { return [] }
        // the options bar is the strip above the document tabs (28 pt), which sit on top of the canvas
        let top = (AppActions.canvas.map { $0.convert($0.bounds, to: nil).maxY } ?? cv.bounds.height - 70) + 28
        let ws = WorkspaceManager.shared, app = AppModel.shared
        let panelsX = cv.bounds.width - (app.showPanels ? (app.showSecondaryPanels ? ws.dockWidthAll : ws.dockWidthPrimary) : 0) - 2
        return FuzzAX.tree(cv).filter(isOperable).filter { n in
            guard let f = FuzzAX.frame(n.element) else { return false }
            let r = w.convertFromScreen(f)
            let inBar = r.midY >= top
            if barOnly { return inBar }
            return !inBar && r.midX < panelsX
        }
    }

    static func chromePhase() {
        guard Fuzz.scenario.core else { return }
        var counts: [String: Int] = [:]
        func count(_ key: String, _ setup: @escaping () -> Void, barOnly: Bool) -> Int {
            let r = step(key) {
                Fuzz.rebuild(key)
                setup()
                Fuzz.spin(0.08)
                Fuzz.forceDisplay()
                return "controls=\(chromeControls(barOnly: barOnly).count)"
            }
            guard let r, let range = r.range(of: "controls=") else { return 0 }
            return Int(r[range.upperBound...].prefix { $0.isNumber }) ?? 0
        }
        func run(_ key: String, _ i: Int, _ setup: @escaping () -> Void, barOnly: Bool) {
            step(key) {
                Fuzz.rebuild(key)
                setup()
                Fuzz.spin(0.08)
                let controls = chromeControls(barOnly: barOnly)
                guard i < controls.count else { return "gone" }
                let base = Fuzz.snapshot()
                var rng = FuzzRNG(key)
                let what = "[\(controls[i].label.prefix(20))] " + operate(controls[i], rng: &rng)
                Fuzz.spin(0.06)
                Fuzz.forceDisplay()
                var r = what + " → " + observe(key, base: base)
                // the options bar holds a pending session's own controls: a pop-up / field / toggle there must not end it
                if barOnly, base.busy, !Fuzz.busy, what.contains("popup→") || what.contains("text→") || what.contains("slider→") {
                    FuzzLog.finding(key, "changing the options-bar control \(what) ended the pending \(AppModel.shared.tool) session")
                }
                if AppModel.shared.dialog != nil, base.dialog == nil { r += " " + cancelCheck(key, atOpen: Fuzz.snapshot()) }
                return r
            }
        }
        // tools palette, document tabs, status bar, timeline, contextual task bar
        let n = count("chrome", {}, barOnly: false)
        counts["chrome"] = n
        for i in 0..<min(n, 80) { run("chromectl:\(i)", i, {}, barOnly: false) }
        // the options bar of every tool
        for k in ToolKind.allCases {
            let setup = { AppModel.shared.tool = k }
            let m = count("bar:\(k)", setup, barOnly: true)
            for i in 0..<min(m, 30) { run("barctl:\(k):\(i)", i, setup, barOnly: true) }
        }
    }

    // MARK: Tools (options bar + overlay per tool, context menus)

    static func toolPhase() {
        var menuCounts: [ToolKind: Int] = [:]
        for k in ToolKind.allCases {
            let key = "tool:\(k)"
            let r = step(key) {
                Fuzz.rebuild(key)
                let base = Fuzz.snapshot()
                AppModel.shared.tool = k
                Fuzz.spin(0.08)
                Fuzz.forceDisplay()
                var n = 0
                if let c = AppActions.canvas, c.document != nil {
                    let p = CGPoint(x: 10, y: 10)
                    let te = ToolEvent(doc: p, view: c.docToView(p), pressure: 1, modifiers: [], clickCount: 1, isTablet: false)
                    n = c.currentTool.contextMenu(te)?.items.count ?? 0
                }
                // switch back: the tool must let go of whatever it set up
                AppModel.shared.tool = .move
                Fuzz.spin(0.04)
                return "menu=\(n) " + observe(key, base: base)
            }
            if let r, let range = r.range(of: "menu=") { menuCounts[k] = Int(r[range.upperBound...].prefix { $0.isNumber }) ?? 0 }
        }
        // (context menus are out of reach while a dialog covers the canvas)
        for k in ToolKind.allCases where !Fuzz.scenario.name.hasPrefix("dialog_") {
            for i in 0..<min(menuCounts[k] ?? 0, 40) {
                let key = "toolmenu:\(k):\(i)"
                step(key) {
                    Fuzz.rebuild(key)
                    AppModel.shared.tool = k
                    Fuzz.spin(0.05)
                    guard let c = AppActions.canvas, c.document != nil else { return "no-canvas" }
                    let p = CGPoint(x: 10, y: 10)
                    let te = ToolEvent(doc: p, view: c.docToView(p), pressure: 1, modifiers: [], clickCount: 1, isTablet: false)
                    guard let menu = c.currentTool.contextMenu(te) else { return "no-menu" }
                    menu.update()
                    guard i < menu.items.count else { return "gone" }
                    let item = menu.items[i]
                    guard !item.isSeparatorItem, item.submenu == nil, item.isEnabled, item.action != nil else { return "skip[\(item.title)]" }
                    let base = Fuzz.snapshot()
                    menu.performActionForItem(at: i)
                    Fuzz.spin(0.08)
                    Fuzz.forceDisplay()
                    var r = "[\(item.title)] " + observe(key, base: base)
                    if AppModel.shared.dialog != nil { r += " " + cancelCheck(key, atOpen: Fuzz.snapshot()) }
                    return r
                }
            }
        }
    }

    // MARK: Keys

    static let plainKeys: [(String, String, NSEvent.ModifierFlags)] = {
        var k: [(String, String, NSEvent.ModifierFlags)] = []
        for c in "abcdefghijklmnopqrstuvwxyz" { k.append((String(c), String(c), [])) }
        for c in "abcdefghijklmnopqrstuvwxyz" { k.append(("shift-" + String(c), String(c), [.shift])) }
        for c in "0123456789[]{}" { k.append((String(c), String(c), c == "{" || c == "}" ? [.shift] : [])) }
        k += [("tab", "\t", []), ("space", " ", []), ("return", "\r", []), ("enter", "\u{3}", []), ("escape", "\u{1b}", []), ("delete", "\u{7f}", []),
              ("forward-delete", "\u{F728}", []), ("shift-delete", "\u{7f}", [.shift]), ("option-delete", "\u{7f}", [.option]),
              ("left", "\u{F702}", []), ("right", "\u{F703}", []), ("down", "\u{F701}", []), ("up", "\u{F700}", []),
              ("shift-left", "\u{F702}", [.shift]), ("shift-up", "\u{F700}", [.shift])]
        return k
    }()

    static func keyPhase() {
        for (name, chars, mods) in plainKeys {
            let key = "key:" + name
            step(key) {
                Fuzz.rebuild(key)
                let base = Fuzz.snapshot()
                let taker = Fuzz.sendKey(chars, mods)
                Fuzz.spin(0.06)
                Fuzz.forceDisplay()
                var r = "taker=\(taker) " + observe(key, base: base)
                if AppModel.shared.dialog != nil, base.dialog == nil { r += " " + cancelCheck(key, atOpen: Fuzz.snapshot()) }
                return r
            }
        }
        // typing in a text field of the main window (options bar, docked panels) must never switch tools or edit the document
        for (name, chars, mods) in plainKeys where ["b", "v", "x", "d", "q", "5", "tab", "delete", "left", "shift-m", "["].contains(name) {
            let key = "keyfield:" + name
            step(key) {
                Fuzz.rebuild(key)
                AppModel.shared.tool = .brush
                for id in ["character", "layers", "properties"] { WorkspaceManager.shared.toggle(id) }
                Fuzz.spin(0.08)
                guard let w = Fuzz.mainWindow, let cv = w.contentView else { return "no-window" }
                var field: NSTextField?
                func find(_ v: NSView) { if field != nil { return }; if let t = v as? NSTextField, t.isEditable, !t.isHidden, t.window != nil { field = t; return }; v.subviews.forEach(find) }
                find(cv)
                guard let tf = field, w.makeFirstResponder(tf), w.firstResponder is NSText else { return "no-field" }
                let base = Fuzz.snapshot()
                let showPanels = AppModel.shared.showPanels, fg = AppModel.shared.foreground, qm = AppModel.shared.activeDocument?.quickMask
                let taker = Fuzz.sendKey(chars, mods)
                Fuzz.spin(0.05)
                let now = Fuzz.snapshot()
                var bad: [String] = []
                if taker == "router" { bad.append("KeyRouter handled it") }
                if now.tool != base.tool { bad.append("tool changed to \(now.tool)") }
                if now.historyCount != base.historyCount || now.committedFP != base.committedFP { bad.append("document changed") }
                if AppModel.shared.showPanels != showPanels { bad.append("panels toggled") }
                if AppModel.shared.foreground != fg { bad.append("colours changed") }
                if AppModel.shared.activeDocument?.quickMask != qm { bad.append("quick mask toggled") }
                if !bad.isEmpty { FuzzLog.finding(key, "key “\(name)” typed in a text field: " + bad.joined(separator: ", ")) }
                w.makeFirstResponder(nil)
                return "taker=\(taker) " + (bad.isEmpty ? "ok" : bad.joined(separator: ","))
            }
        }
        // every menu shortcut: does the key monitor swallow it before the menu sees it?
        Fuzz.rebuild("shortcuts")
        let withKeys = Fuzz.leaves().filter { !$0.item.keyEquivalent.isEmpty && $0.isAppCommand }.map { ($0.path, $0.item.keyEquivalent, $0.item.keyEquivalentModifierMask) }
        for (path, ke, mask) in withKeys {
            let key = "shortcut:" + path
            step(key) {
                Fuzz.rebuild(key)
                guard let leaf = findLeaf(path) else { return "missing" }
                guard let e = Fuzz.keyEvent(ke, mask) else { return "noevent" }
                let base = Fuzz.snapshot()
                let swallowed = KeyRouter.handle(e)
                Fuzz.spin(0.05)
                if swallowed {
                    FuzzLog.finding(key, "shortcut \(Fuzz.shortcut(leaf.item)) never reaches its menu item: the key monitor (KeyRouter) handles the key first")
                    return "swallowed-by-KeyRouter " + observe(key, base: base)
                }
                let viaMenu = NSApp.mainMenu?.performKeyEquivalent(with: e) ?? false
                Fuzz.spin(0.06)
                var r = (viaMenu ? "menu-handled " : "NOT-handled ") + observe(key, base: base)
                // (synthetic ⇧ combinations don't match AppKit's key-equivalent lookup, so only unshifted ones are judged)
                if !viaMenu, leaf.item.isEnabled, !mask.contains(.shift) { FuzzLog.finding(key, "shortcut \(Fuzz.shortcut(leaf.item)) is not handled by the menu") }
                if AppModel.shared.dialog != nil, base.dialog == nil { r += " " + cancelCheck(key, atOpen: Fuzz.snapshot()) }
                return r
            }
        }
    }

    // MARK: Workspaces, preferences, document switching

    static func miscPhase() {
        let app = AppModel.shared
        for w in Workspace.builtIn {
            let key = "workspace:" + w.name
            step(key) {
                Fuzz.rebuild(key)
                WorkspaceManager.shared.apply(w)
                Fuzz.spin(0.15)
                Fuzz.forceDisplay()
                WorkspaceManager.shared.reset()
                Fuzz.spin(0.05)
                Fuzz.validateAll(key)
                return "ok"
            }
        }
        for t in InterfaceTheme.allCases {
            let key = "prefs:theme:" + t.rawValue
            step(key) {
                Fuzz.rebuild(key)
                app.prefs.theme = t
                Fuzz.spin(0.15)
                app.dialog = .preferences
                Fuzz.spin(0.1)
                Fuzz.forceDisplay()
                cancelDialog()
                return "ok"
            }
        }
        for u in RulerUnit.allCases {
            let key = "prefs:units:" + u.rawValue
            step(key) {
                Fuzz.rebuild(key)
                app.prefs.rulerUnits = u
                app.prefs.typeUnits = u == .percent ? .points : u
                app.activeDocument?.showRulers = true
                app.activeDocument?.showGrid = true
                Fuzz.spin(0.12)
                Fuzz.forceDisplay()
                // info / properties / character panels show values in the chosen unit
                for id in ["info", "properties", "character", "navigator"] { WorkspaceManager.shared.toggle(id); Fuzz.spin(0.05) }
                Fuzz.forceDisplay()
                return "ok"
            }
        }
        for c in BrushCursorStyle.allCases {
            let key = "prefs:cursor:" + c.rawValue
            step(key) {
                Fuzz.rebuild(key)
                app.prefs.brushCursor = c
                app.tool = .brush
                AppActions.canvas?.lastMouseView = CGPoint(x: 100, y: 100)
                Fuzz.spin(0.06)
                Fuzz.forceDisplay()
                return "ok"
            }
        }
        step("prefs:extremes") {
            Fuzz.rebuild("prefs:extremes")
            app.prefs.checkerSize = 2; app.prefs.gridSpacing = 1; app.prefs.gridSubdivisions = 20; app.prefs.historyStates = 5
            app.activeDocument?.showGrid = true
            Fuzz.spin(0.1); Fuzz.forceDisplay()
            app.prefs.checkerSize = 32; app.prefs.gridSpacing = 500; app.prefs.gridSubdivisions = 1; app.prefs.largeDocumentThreshold = 1
            Fuzz.spin(0.1); Fuzz.forceDisplay()
            if let d = app.activeDocument { for i in 0..<8 { d.commit("Step \(i)") } }
            Fuzz.validateAll("prefs:extremes")
            return "ok"
        }
        // view state extremes on the canvas renderer
        step("view:extremes") {
            Fuzz.rebuild("view:extremes")
            guard let d = app.activeDocument, let c = AppActions.canvas else { return "nodoc" }
            for z in [0.01, 64.0, 1.0] { c.setZoom(z); Fuzz.forceDisplay() }
            c.setRotation(1.1); Fuzz.forceDisplay(); c.setRotation(0)
            for ch: ViewChannel in [.red, .green, .blue, .ink(0), .ink(3), .lab(0), .lab(2), .composite] { d.viewChannel = ch; d.setNeedsRender(); Fuzz.forceDisplay() }
            d.proofColors = true; d.gamutWarning = true; d.showPixelGrid = true; d.showGrid = true; d.setNeedsRender(); Fuzz.forceDisplay()
            c.fitOnScreen(); Fuzz.forceDisplay()
            Fuzz.validateAll("view:extremes")
            return "ok"
        }
        // isolation: real provider keys are invisible and no request can leave the machine
        step("isolation") {
            let keys = ProviderID.allCases.filter { GenAIKeychain.shared.hasKey($0) || GenAIKeychain.shared.key($0) != nil }
            if !keys.isEmpty { FuzzLog.finding("isolation", "real API keys are visible to the fuzz process: \(keys.map(\.rawValue))") }
            var outcome = "pending"
            let task = URLSession.shared.dataTask(with: URL(string: "https://example.com/")!) { _, resp, err in
                outcome = err != nil ? "blocked" : "REACHED \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            }
            task.resume()
            let until = Date().addingTimeInterval(4)
            while outcome == "pending", Date() < until { Fuzz.spin(0.05) }
            task.cancel()
            if outcome != "blocked" { FuzzLog.finding("isolation", "an external network request was not blocked (\(outcome))") }
            return "keys=\(keys.count) network=\(outcome)"
        }
        // Blur Gallery: its pins live on the canvas, so canvas clicks must get through the dialog layer
        if !Fuzz.scenario.name.hasPrefix("dialog_") { step("canvas:blur-gallery-pins") {
            Fuzz.rebuild("canvas:blur-gallery-pins")
            AppActions.startBlurGallery(.fieldBlur)
            Fuzz.spin(0.25)
            guard app.dialog == .blurGallery, let st = AppActions.blurGallery, let c = AppActions.canvas, let w = c.window else { return "not-applicable" }
            let n = st.inst.points.count
            Fuzz.click(c.convert(NSPoint(x: c.bounds.midX - 60, y: c.bounds.midY + 40), to: nil), in: w)
            Fuzz.spin(0.1)
            let m = AppActions.blurGallery?.inst.points.count ?? -1
            if m != n + 1 { FuzzLog.finding("canvas:blur-gallery-pins", "a click on the canvas does not add a Blur Gallery pin (\(n) → \(m)): the dialog layer swallows canvas clicks") }
            let r = cancelCheck("canvas:blur-gallery-pins", atOpen: Fuzz.snapshot())
            return "pins \(n) → \(m) " + r
        } }
        // history panel: jump to every state, then back
        step("history:jump") {
            Fuzz.rebuild("history:jump")
            guard let d = app.activeDocument else { return "nodoc" }
            for i in stride(from: d.history.count - 1, through: 0, by: -1) { d.jumpToHistory(i); Fuzz.spin(0.03); Fuzz.forceDisplay() }
            d.jumpToHistory(d.history.count - 1)
            Fuzz.spin(0.03)
            Fuzz.validateAll("history:jump")
            return "states=\(d.history.count)"
        }
    }
}
