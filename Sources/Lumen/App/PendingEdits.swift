import AppKit
import ImageCratCore

/// A pending interactive edit (Free Transform, Warp, Puppet Warp, Perspective Warp, Content-Aware Scale, Transform
/// Selection, on-canvas type, type masks) only exists as a live preview until it is confirmed. Any other command that
/// runs meanwhile would see the unedited layer and leave the transform box behind, so — like Photoshop's "Apply the
/// transformation?" — the pending edit is applied first. What "pending" means for a tool is declared by the tool itself
/// (`Tool.pendingPolicy`).
enum PendingEdits {
    /// True while the tool itself is committing (so the safety net below doesn't fire).
    static var inToolCommit = false
    private static var installed = false

    /// The selected tool when it holds an unconfirmed edit on the active canvas. (Not `currentTool`: holding Space
    /// temporarily shows the hand while e.g. a transform stays pending.)
    static var busyTool: Tool? {
        guard let c = AppActions.canvas else { return nil }
        let t = c.tool(for: AppModel.shared.tool)
        return t.isBusy ? t : nil
    }

    /// The Move tool when it holds an unconfirmed transform / mesh session on the active canvas.
    static var busyMoveTool: MoveTool? {
        guard let c = AppActions.canvas, let mt = c.tool(for: .move) as? MoveTool, mt.isBusy else { return nil }
        return mt
    }

    /// Applies the busy tool's pending edit as its policy says. `textCommand`: the command belongs to the text editor
    /// itself (Edit / Type menus, context menus, panels), which keeps an open type editor. Returns true if applied.
    @discardableResult
    static func applyPending(textCommand: Bool = false) -> Bool {
        guard let t = busyTool else { return false }
        switch t.pendingPolicy {
        case .keep: return false
        case .commitExceptTextCommands where textCommand: return false
        case .commit, .commitExceptTextCommands:
            t.commit()
            return true
        }
    }

    /// Applies the pending transform / warp. Returns true if something was applied.
    @discardableResult
    static func applyPendingTransform() -> Bool {
        guard let mt = busyMoveTool, mt.pendingPolicy == .commit else { return false }
        mt.commit()
        return true
    }

    /// Applies a crop box the user has dragged (Crop / Perspective Crop tool). A command chosen while it is pending
    /// would otherwise work on the uncropped canvas — dialogs such as Image Size even show the old dimensions and the
    /// crop is then applied underneath them on OK.
    static func applyPendingCrop() {
        guard let c = AppActions.canvas, c.currentTool is CropTool || c.currentTool is PerspectiveCropTool, c.currentTool.isBusy else { return }
        c.currentTool.commit()
    }

    /// Commits an in-progress text edit (for commands that change the document rather than the text).
    static func applyPendingText() {
        guard let t = busyTool, t.pendingPolicy == .commitExceptTextCommands else { return }
        t.commit()
    }

    /// A command of the main menu `top` ("" = context / pop-up menu) is about to run.
    static func willRunMenuCommand(topLevel top: String, keyEquivalent key: String = "") {
        switch top {
        case "View", "Window", "Help", PendingEdits.appMenu:
            return                                   // navigation and app-level items (a pending edit that still fits stays open)
        case "File", "Image", "Layer", "Select", "Filter", "Plugins":
            // Select ▸ All (⌘A) while typing selects the text being edited (see AppActions.selectAll)
            if top == "Select", key == "a", AppActions.isTextEditing { return }
            applyPending()
            applyPendingCrop()
        case "Edit", "Type":
            applyPending(textCommand: true)          // the text editor keeps Undo / Cut / Copy / Paste and the Type options
            // (⌘Z / ⇧⌘Z with a dragged crop box cancel the box: AppActions.undo)
            if key != "z" { applyPendingCrop() }
        default:
            // context menus: the text editor's own menu must keep working on the text being edited
            applyPending(textCommand: true)
        }
    }

    /// A click landed in a panel (Layers, Properties, History …) or a floating panel window.
    static func willClickPanel() {
        applyPending(textCommand: true)              // Character / Paragraph / Glyphs panels edit the text being typed
    }

    /// Safety net for commands that bypass the hooks above: a history step is being recorded (or the history jumped)
    /// while a session is pending.
    static func documentChanging(_ doc: Document, restored: Bool) {
        guard !inToolCommit else { return }
        if let mt = busyMoveTool, mt.doc === doc {
            if restored { mt.abandonPending() } else { mt.reconcileWithDocument() }
        }
        // an open type editor whose layer is gone has nothing left to edit
        if let t = busyTool, t.pendingPolicy == .commitExceptTextCommands { t.abandonPending() }
    }

    static func install() {
        guard !installed else { return }
        installed = true

        // 1. Menu commands (including keyboard shortcuts and context menus).
        NotificationCenter.default.addObserver(forName: NSMenu.willSendActionNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu else { return }
            let top = topLevelTitle(menu)
            if top.isEmpty {
                // pop-ups in the options bar are the pending session's own controls (Warp style, grid, density,
                // perspective-warp mode…): choosing a value there must not apply the session
                if isOptionsBarPopUp(menu) { return }
                // …and so must choosing a value in a pop-up of an open dialog (Proof Setup, Preferences)
                if AppModel.shared.dialog != nil { return }
            }
            willRunMenuCommand(topLevel: top, keyEquivalent: (note.userInfo?["MenuItem"] as? NSMenuItem)?.keyEquivalent ?? "")
        }

        // 2. Clicks in panels (Layers, Properties, History …) or floating panel windows.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { e in
            // (a dialog covers the panels: a click on one of its controls that happens to sit over a panel is not a panel click)
            if AppModel.shared.dialog == nil, busyTool != nil, clickIsInPanel(e) { willClickPanel() }
            return e
        }

        // 3. Safety net: some other code records a history step while a session is still pending. A session that still
        //    fits the document stays open; one that doesn't is dropped instead of leaving a detached transform box.
        let previous = Document.willCommit
        Document.willCommit = { doc in
            previous?(doc)
            documentChanging(doc, restored: false)
        }
        // 4. …or the history jumps (undo / redo / History panel) underneath it.
        let previousRestore = Document.didRestore
        Document.didRestore = { doc in
            previousRestore?(doc)
            documentChanging(doc, restored: true)
        }
    }

    /// True when `menu` belongs to a pop-up button in the options bar (the strip above the document tabs and canvas).
    private static func isOptionsBarPopUp(_ menu: NSMenu) -> Bool {
        guard let c = AppActions.canvas, let root = c.window?.contentView else { return false }
        let canvasTop = c.convert(c.bounds, to: nil).maxY
        var result = false, done = false
        func walk(_ v: NSView) {
            if done { return }
            if let b = v as? NSPopUpButton, let m = b.menu, m === menu || menu.supermenu === m {
                result = b.convert(b.bounds, to: nil).minY >= canvasTop
                done = true
                return
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
        return result
    }

    /// What `topLevelTitle` reports for the application menu (whose title is the app's name).
    static let appMenu = Brand.name

    private static func topLevelTitle(_ menu: NSMenu) -> String {
        var m = menu
        while let s = m.supermenu, s !== NSApp.mainMenu { m = s }
        guard m.supermenu === NSApp.mainMenu else { return "" }      // context / pop-up menu
        if let main = NSApp.mainMenu, let i = main.items.firstIndex(where: { $0.submenu === m }), i == 0 { return appMenu }
        return m.title
    }

    /// True for clicks outside the canvas column: the panel columns to its right, the status bar / timeline below it,
    /// or another window (a floating panel, an icon column's pop-over). The options bar above the canvas holds the
    /// session's own controls. Dock chrome (tab bars, dividers, column headers) only arranges panels: not a panel click.
    static func clickIsInPanel(_ e: NSEvent) -> Bool {
        guard let c = AppActions.canvas, let cw = c.window else { return false }
        guard let w = e.window else { return false }
        if w !== cw { return WorkspaceManager.isPanelWindow(w) && !WorkspaceManager.isDockChrome(w, e.locationInWindow) }
        let f = c.convert(c.bounds, to: nil)
        let p = e.locationInWindow
        if f.contains(p) { return false }
        if p.y > f.maxY { return false }                  // options bar, document tabs, title bar
        if p.x < f.minX { return false }                  // tools palette: switching tools commits on its own
        if WorkspaceManager.isDockChrome(w, p) { return false }
        return true
    }
}

extension MoveTool {
    /// Drops a pending session without touching the document (used when the document changed underneath it).
    func abandonSession() {
        if let d = doc { d.contentOverrides.removeAll(); d.showSelectionEdges = true; d.setNeedsRender() }
        clearSessions()
        canvas.overlay.needsDisplay = true
        AppModel.shared.sessionTick += 1
    }
}
