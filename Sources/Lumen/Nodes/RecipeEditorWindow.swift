import AppKit
import SwiftUI
import ImageCratCore

/// Floating, resizable window hosting the Recipe Editor. Keys and scrolling are routed to the editor model
/// (the main window's single-key tool shortcuts only fire when the main window is key).
final class RecipeEditorPanel: NSPanel {
    weak var model: RecipeEditorModel?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private var editingText: Bool { firstResponder is NSText }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if !editingText, e.type == .keyDown, e.modifierFlags.contains(.command), let m = model, m.handleKey(e) { return true }
        return super.performKeyEquivalent(with: e)
    }

    override func sendEvent(_ e: NSEvent) {
        if let m = model {
            if e.type == .keyDown, !editingText, !e.modifierFlags.contains(.command), m.handleKey(e) { return }
            if e.type == .scrollWheel, m.hovering, m.search == nil {
                let precise = e.hasPreciseScrollingDeltas
                if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
                    m.zoom(by: CGFloat(exp(Double(e.scrollingDeltaY) * (precise ? 0.01 : 0.08))), around: m.mouseView)
                } else {
                    let k: CGFloat = precise ? 1 : 12
                    m.pan = CGPoint(x: m.pan.x + e.scrollingDeltaX * k, y: m.pan.y + e.scrollingDeltaY * k)
                }
                return
            }
        }
        super.sendEvent(e)
    }

    override func cancelOperation(_ sender: Any?) {}
}

final class RecipeEditorWindow: NSObject, NSWindowDelegate {
    static let shared = RecipeEditorWindow()

    private(set) var panel: RecipeEditorPanel?
    private(set) var model: RecipeEditorModel?

    /// Opens (or retargets) the editor. Headless runs only create the model.
    @discardableResult
    func open(document: Document, target: RecipeTarget) -> RecipeEditorModel {
        if let m = model, m.document === document, m.target == target, panel?.isVisible == true {
            panel?.makeKeyAndOrderFront(nil)
            return m
        }
        let m = RecipeEditorModel(document: document, target: target)
        model = m
        if RecipePresetStore.isSelfTest { return m }
        TextureEngine.prewarm()
        let p: RecipeEditorPanel
        if let existing = panel { p = existing } else {
            p = RecipeEditorPanel(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable, .utilityWindow], backing: .buffered, defer: false)
            p.identifier = NSUserInterfaceItemIdentifier("recipeEditor")
            p.isFloatingPanel = true
            p.hidesOnDeactivate = true
            p.becomesKeyOnlyIfNeeded = false
            p.isReleasedWhenClosed = false
            p.minSize = NSSize(width: 780, height: 460)
            p.appearance = NSAppearance(named: AppModel.shared.prefs.theme.isLight ? .aqua : .darkAqua)
            p.delegate = self
            p.center()
            p.setFrameAutosaveName("LumenRecipeEditor")
            panel = p
        }
        p.model = m
        p.title = m.title
        p.contentView = NSHostingView(rootView: RecipeEditorView(model: m))
        p.makeKeyAndOrderFront(nil)
        return m
    }

    func close() {
        panel?.orderOut(nil)
        model = nil
        panel?.model = nil
    }

    func windowWillClose(_ notification: Notification) {
        model = nil
        panel?.model = nil
        panel?.contentView = NSView()
    }

    var isOpen: Bool { panel?.isVisible == true }
}
