import AppKit
import SwiftUI
import ImageCratCore

/// Deterministic random numbers (the same item always gets the same fuzz input).
struct FuzzRNG {
    var state: UInt64
    init(_ seed: String) {
        var h: UInt64 = 0xcbf29ce484222325
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        state = h
    }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    mutating func unit() -> Double { Double(next() % 10_000) / 10_000 }
}

final class ClickFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

/// Shared helpers for the fuzz driver.
enum Fuzz {
    static var scenario = FuzzScenario(name: "nodoc", build: {})
    static let originalPrefs = AppModel.shared.prefs

    // MARK: Run loop

    /// Lets the app run for a moment: queued events, SwiftUI updates, main-queue blocks, timers.
    static func spin(_ seconds: Double = 0.05) {
        let until = Date().addingTimeInterval(seconds)
        repeat {
            while let e = NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) { NSApp.sendEvent(e) }
            RunLoop.current.run(mode: .default, before: min(until, Date().addingTimeInterval(0.01)))
        } while Date() < until
    }

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true } ?? NSApp.windows.first { !($0 is NSPanel) }
    }

    /// Draws what a visible window would draw: the Metal canvas, the tool overlay and the SwiftUI layers.
    static func forceDisplay() {
        if let c = AppActions.canvas, c.bounds.width > 1, c.bounds.height > 1 {
            c.metalView.draw()
            if let rep = c.overlay.bitmapImageRepForCachingDisplay(in: c.overlay.bounds) { c.overlay.cacheDisplay(in: c.overlay.bounds, to: rep) }
        }
        for w in NSApp.windows where w.isVisible {
            w.contentView?.layoutSubtreeIfNeeded()
            w.displayIfNeeded()
        }
    }

    // MARK: Menu walking

    struct Leaf {
        let path: String
        let item: NSMenuItem
        let menu: NSMenu
        let index: Int
        /// App-defined command (a SwiftUI menu button); system items (Hide, Quit, Minimize, Full Screen…) are never invoked.
        var isAppCommand: Bool {
            guard let a = item.action else { return false }
            return NSStringFromSelector(a) == "menuAction:"
        }
    }

    static func shortcut(_ i: NSMenuItem) -> String {
        guard !i.keyEquivalent.isEmpty else { return "" }
        var s = ""
        let m = i.keyEquivalentModifierMask
        let k = i.keyEquivalent
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) || (k != k.lowercased()) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        let names: [String: String] = [" ": "Space", "\u{8}": "⌫", "\u{7f}": "⌦", "\r": "↩", "\u{1b}": "⎋", "\t": "⇥"]
        if let n = names[k] { return s + n }
        if let u = k.unicodeScalars.first, u.value >= 0xF704, u.value <= 0xF726 { return s + "F\(u.value - 0xF703)" }
        return s + k.uppercased()
    }

    /// All leaf items of the main menu (submenus are populated on demand, as AppKit does before showing them).
    static func leaves() -> [Leaf] {
        var out: [Leaf] = []
        var used: [String: Int] = [:]
        func walk(_ menu: NSMenu, _ prefix: String, _ depth: Int) {
            menu.delegate?.menuNeedsUpdate?(menu)   // SwiftUI refreshes titles / enabled state / shortcuts here (as when a menu opens)
            menu.update()
            for (i, item) in menu.items.enumerated() {
                if item.isSeparatorItem { continue }
                // state marks ("✓ RGB Color") are not part of an item's identity
                var title = item.title.replacingOccurrences(of: "✓ ", with: "").trimmingCharacters(in: .whitespaces)
                if title.isEmpty { title = "(untitled \(i))" }
                var path = prefix.isEmpty ? title : prefix + " ▸ " + title
                if let sub = item.submenu {
                    if depth < 6 { walk(sub, path, depth + 1) }
                } else {
                    let n = (used[path] ?? 0) + 1
                    used[path] = n
                    if n > 1 { path += " (\(n))" }
                    out.append(Leaf(path: path, item: item, menu: menu, index: i))
                }
            }
        }
        if let main = NSApp.mainMenu { walk(main, "", 0) }
        return out
    }

    // MARK: Baseline

    /// Returns the app to a clean slate the way a user would (closing every document), then checks nothing is left over.
    static func reset(_ key: String = "") {
        let app = AppModel.shared
        if app.dialog != nil {
            app.dialog = nil
            spin(0.02)
        }
        for d in app.documents { app.close(d) }
        spin(0.025)
        if let c = AppActions.canvas {
            if c.document != nil { c.document = nil }
            if let mt = PendingEdits.busyMoveTool {
                FuzzLog.finding(key, "transform / warp session survives closing its document")
                mt.abandonSession()
            }
            if c.currentTool.isBusy {
                FuzzLog.finding(key, "tool \(app.tool) still busy after its document closed")
                c.currentTool.cancel()
            }
        }
        if app.textEditingActive {
            FuzzLog.finding(key, "textEditingActive still set after the document closed")
            app.textEditingActive = false
        }
        if CanvasSampler.shared.isArmed { CanvasSampler.shared.disarm() }
        app.documents.removeAll()
        app.activeDocumentID = nil
        app.tool = .move
        app.groupSelection = [:]
        app.statusMessage = ""
        app.foreground = .black; app.background = .white
        app.showPanels = true; app.showSecondaryPanels = true
        if app.prefs != originalPrefs { app.prefs = originalPrefs }
        app.proof = ProofSettings()
        app.gradients = ColorGradient.presets
        app.customPatterns = []
        let ws = WorkspaceManager.shared
        if ws.current != Workspace.essentials { ws.apply(.essentials) }
        TimelineController.shared.stop()
        TimelineController.shared.isPanelVisible = false
        Automation.reset()
        Automation.answer = .cancel
        beepsAtReset = Automation.beeps
    }

    static var beepsAtReset = 0

    static func rebuild(_ key: String = "") {
        reset(key)
        scenario.build()
        spin(0.04)
    }

    // MARK: State fingerprints

    static func pixelHash(_ st: DocumentState) -> String {
        guard st.width > 0, st.height > 0, let cg = Compositor.shared.flatten(st, background: .white) else { return "noimage" }
        let pb = PixelBuffer(cgImage: cg)
        let n = pb.bytesPerRow * pb.height
        let p = pb.data.assumingMemoryBound(to: UInt8.self)
        var h: UInt64 = 0xcbf29ce484222325
        var i = 0
        while i < n { h = (h ^ UInt64(p[i])) &* 0x100000001b3; i += 1 }
        return String(h, radix: 16)
    }

    static func structure(_ st: DocumentState) -> String {
        var s = "\(st.width)x\(st.height)@\(Int(st.resolution)) \(st.colorMode.short)/\(st.bitDepth.rawValue)"
        func walk(_ layers: [Layer], _ depth: Int) {
            for l in layers {
                s += " |\(depth):\(l.id.uuidString.prefix(6)):\(l.kindName):\(l.name):\(l.isVisible ? "v" : "h"):\(Int(l.opacity * 100)):\(l.blendMode.rawValue)"
                if let r = l.raster { s += ":\(r.frame.x),\(r.frame.y),\(r.frame.width),\(r.frame.height)" }
                if let m = l.mask { s += ":m\(m.buffer.width)x\(m.buffer.height)\(m.isEnabled ? "" : "off")" }
                if l.vectorMask != nil { s += ":vm" }
                if l.isClipped { s += ":clip" }
                if l.locks.anyLocked { s += ":lock" }
                if l.isGroup { walk(l.children, depth + 1) }
            }
        }
        walk(st.layers, 0)
        if let b = st.selectionBounds { s += " sel:\(b.x),\(b.y),\(b.width),\(b.height)" } else if st.selection != nil { s += " sel:empty" }
        s += " ch\(st.alphaChannels.count) p\(st.paths.count) g\(st.guides.count) c\(st.layerComps.count) f\(st.frames.count)"
        if st.videoTimeline != nil { s += " video" }
        if !st.generative.isEmpty { s += " gen\(st.generative.count)" }
        return s
    }

    static func fingerprint(_ st: DocumentState) -> String { structure(st) + " #" + pixelHash(st) }

    /// Problems that make a document invalid (each one is a bug in whatever produced it).
    static func validate(_ d: Document) -> [String] {
        var p: [String] = []
        let st = d.state
        if st.width < 1 || st.height < 1 { p.append("canvas is \(st.width)×\(st.height)") }
        if let a = d.activeLayerID, st.layer(a) == nil { p.append("activeLayerID points at a missing layer") }
        if d.selectedLayerIDs.contains(where: { st.layer($0) == nil }) { p.append("selectedLayerIDs contains a missing layer") }
        if let s = st.selection, s.width != st.width || s.height != st.height { p.append("selection is \(s.width)×\(s.height) on a \(st.width)×\(st.height) canvas") }
        let all = st.allLayers
        if Set(all.map(\.id)).count != all.count { p.append("duplicate layer ids") }
        for l in all {
            if let r = l.raster, r.buffer.width < 1 || r.buffer.height < 1 { p.append("raster layer “\(l.name)” has an empty buffer") }
            if let m = l.mask, m.buffer.width < 1 || m.buffer.height < 1 { p.append("mask of “\(l.name)” has an empty buffer") }
            if !l.opacity.isFinite || !l.fillOpacity.isFinite { p.append("layer “\(l.name)” opacity is not finite") }
            if let so = l.smart, [so.quad.tl, so.quad.tr, so.quad.br, so.quad.bl].contains(where: { !$0.x.isFinite || !$0.y.isFinite }) { p.append("smart object “\(l.name)” quad is not finite") }
            if let t = l.text, !t.fontSize.isFinite || t.fontSize <= 0 { p.append("text layer “\(l.name)” font size \(t.fontSize)") }
        }
        if st.alphaChannels.contains(where: { $0.buffer.width != st.width || $0.buffer.height != st.height }) { p.append("alpha channel size ≠ canvas") }
        if !d.history.indices.contains(d.historyIndex) { p.append("historyIndex out of range") }
        if d.editTarget == .mask, d.activeLayer?.mask == nil { p.append("editTarget is mask but the active layer has no mask") }
        if !d.zoom.isFinite || d.zoom <= 0 { p.append("zoom \(d.zoom)") }
        if st.width >= 1 && st.height >= 1 && Compositor.shared.flatten(st, background: .white) == nil { p.append("composite could not be rendered") }
        return p
    }

    static func validateAll(_ key: String) {
        for d in AppModel.shared.documents {
            for problem in validate(d) { FuzzLog.finding(key, "invalid document “\(d.name)”: \(problem)") }
        }
        let app = AppModel.shared
        if let id = app.activeDocumentID, !app.documents.contains(where: { $0.id == id }) { FuzzLog.finding(key, "activeDocumentID points at a closed document") }
        if app.activeDocumentID == nil, !app.documents.isEmpty { FuzzLog.finding(key, "documents are open but none is active") }
    }

    struct Snapshot {
        var docCount = 0
        var docID: UUID?
        var stateFP = ""
        var committedFP = ""
        var historyCount = 0
        var historyIndex = 0
        var dialog: String?
        var tool: ToolKind = .move
        var busy = false
        var overrides = 0
        var displayOverride = false
        var hidden = 0
        var quickMask = false
        var editTarget: EditTarget = .content
    }

    static var busy: Bool {
        guard let c = AppActions.canvas else { return false }
        if PendingEdits.busyMoveTool != nil { return true }
        return c.currentTool.isBusy
    }

    static func snapshot(pixels: Bool = true) -> Snapshot {
        let app = AppModel.shared
        var s = Snapshot()
        s.docCount = app.documents.count
        s.dialog = app.dialog?.id
        s.tool = app.tool
        s.busy = busy
        if let d = app.activeDocument {
            s.docID = d.id
            s.stateFP = pixels ? fingerprint(d.state) : structure(d.state)
            s.committedFP = d.history.indices.contains(d.historyIndex) ? (pixels ? fingerprint(d.committedState) : structure(d.committedState)) : "?"
            s.historyCount = d.history.count
            s.historyIndex = d.historyIndex
            s.overrides = d.contentOverrides.count
            s.displayOverride = d.displayOverride != nil
            s.hidden = d.hiddenLayers.count
            s.quickMask = d.quickMask
            s.editTarget = d.editTarget
        }
        return s
    }

    // MARK: Keys

    static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
        "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "{": 33, "}": 30, "\t": 48, " ": 49, "\r": 36, "\u{3}": 76, "\u{1b}": 53, "\u{7f}": 51, "\u{8}": 51, "\u{F728}": 117,
        "\u{F702}": 123, "\u{F703}": 124, "\u{F701}": 125, "\u{F700}": 126,
    ]

    static func keyEvent(_ chars: String, _ mods: NSEvent.ModifierFlags = [], up: Bool = false, repeated: Bool = false) -> NSEvent? {
        let plain = chars.lowercased()
        let code = keyCodes[plain] ?? keyCodes[chars] ?? 200
        var typed = chars
        if mods.contains(.shift), chars.count == 1, chars.first!.isLetter { typed = chars.uppercased() }
        return NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: mainWindow?.windowNumber ?? 0, context: nil, characters: typed, charactersIgnoringModifiers: mods.contains(.shift) ? typed : plain,
                                isARepeat: repeated, keyCode: code)
    }

    /// Delivers a key press the way `NSApplication.sendEvent` does: the app's key monitor (`KeyRouter`) first, then menu
    /// key equivalents, then the window's first responder. Returns who took it.
    @discardableResult
    static func sendKey(_ chars: String, _ mods: NSEvent.ModifierFlags = []) -> String {
        guard let down = keyEvent(chars, mods), let up = keyEvent(chars, mods, up: true) else { return "noevent" }
        var taker = "router"
        if !KeyRouter.handle(down) {
            if mainWindow?.performKeyEquivalent(with: down) == true { taker = "window-shortcut" }
            else if !mods.intersection([.command, .control, .option]).isEmpty, NSApp.mainMenu?.performKeyEquivalent(with: down) == true { taker = "menu" }
            else if let w = mainWindow, let r = w.firstResponder, r !== w {
                r.keyDown(with: down); taker = "responder:\(type(of: r))"
            } else { taker = "nobody" }
        }
        _ = KeyRouter.handle(up)
        return taker
    }

    // MARK: Synthetic mouse (delivered inside this process only)

    static func mouse(_ type: NSEvent.EventType, _ p: NSPoint, _ w: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
    }

    /// Frames (window coordinates) of controls whose mouse-down starts a nested tracking loop that a queued mouse-up
    /// can't end (pop-up menus, segmented controls, combo boxes).
    static func trackingControlFrames(_ w: NSWindow) -> [NSRect] {
        var out: [NSRect] = []
        func walk(_ v: NSView) {
            let n = String(describing: type(of: v))
            // (text fields too: the field editor's mouse tracking discards queued events and waits for a real mouse-up)
            if v is NSPopUpButton || v is NSSegmentedControl || v is NSComboBox || v is NSColorWell || v is NSTextField || v is NSTextView || n.contains("Popup") || n.contains("PopUp") || n.contains("Menu") {
                out.append(v.convert(v.bounds, to: nil).insetBy(dx: -3, dy: -3))
                return
            }
            for c in v.subviews { walk(c) }
        }
        if let cv = w.contentView { walk(cv) }
        return out
    }

    static func unsafeToClick(_ p: NSPoint, in w: NSWindow) -> Bool {
        trackingControlFrames(w).contains { $0.contains(p) }
    }

    static func click(_ p: NSPoint, in w: NSWindow, dragTo q: NSPoint? = nil) {
        if unsafeToClick(p, in: w) { return }
        if let q, unsafeToClick(q, in: w) { return }
        guard let down = mouse(.leftMouseDown, p, w), let up = mouse(.leftMouseUp, q ?? p, w) else { return }
        // queue the rest of the gesture first: AppKit controls track the mouse in a nested loop that reads the queue
        if let q {
            for i in 1...4 {
                let t = CGFloat(i) / 4
                if let drag = mouse(.leftMouseDragged, NSPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t), w) { NSApp.postEvent(drag, atStart: false) }
            }
        }
        NSApp.postEvent(up, atStart: false)
        // Some controls discard queued events before tracking the mouse: keep offering a mouse-up from another thread
        // until the mouse-down returns (postEvent is documented as callable from secondary threads).
        let finished = ClickFlag()
        DispatchQueue.global().async {
            var n = 0
            while !finished.value && n < 100 {
                usleep(120_000)
                if !finished.value { NSApp.postEvent(up, atStart: true) }
                n += 1
            }
        }
        w.sendEvent(down)
        finished.value = true
        spin(0.02)
    }
}
