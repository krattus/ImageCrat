import SwiftUI
import AppKit
import ImageCratCore

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        CorePlatform.install()   // before any PixelBuffer or document exists (CGContext pixel storage, core hooks)
        Beep.installHeadlessGuards()   // automated runs: no AppKit "unhandled key" beeps either
        LegacyMigration.runAtLaunch()   // first: carries Lumen's folder and preferences over before anything reads them
        FeatureModules.registerAll()
    }

    var body: some Scene {
        Window(Brand.name, id: "main") {
            MainView()
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultLaunchBehavior(.presented)
        .commands {
            LumenCommands()
            LumenCommands2()
            LumenCommands3()
            AnimationCommands()
            PluginCommands()
            ParticleCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        SelfTest.runIfRequested()
        PerfTest.runIfRequested()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: AppModel.shared.prefs.theme.isLight ? .aqua : .darkAqua)
        _ = WorkspaceManager.shared
        if Automation.isProcessWide {
            NSApp.setActivationPolicy(.accessory)      // headless automation / QA fuzz driver: never take focus from the user
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
            KeyRouter.handle(e) ? nil : e
        }
        PendingEdits.install()
        MemoryHygiene.install()
        TabletSettings.shared.applyAtLaunch()   // pressure-button defaults, pen-eraser proximity monitor (not in self tests)
        LegacyMigration.afterLaunch()   // Keychain items (in the background) and the one-time "Lumen is now ImageCrat" note
        DispatchQueue.main.async {
            if let w = NSApp.windows.first {
                w.titlebarAppearsTransparent = true
                w.backgroundColor = NSColor(white: 0.13, alpha: 1)
                if w.frame.width < 1200 { w.setFrame(NSScreen.main?.visibleFrame ?? w.frame, display: true) }
            }
            // Open files passed on the command line (for testing)
            let args = Automation.isFuzz ? [] : CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            for a in args { AppActions.open(url: URL(fileURLWithPath: a)) }
            // Debug hook for automated UI testing
            if ProcessInfo.processInfo.environment["LUMEN_OPEN_DIALOG"] == "liquify", AppActions.doc != nil {
                AppModel.shared.dialog = .liquify
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Linked smart objects: pick up files edited in other apps.
        for d in AppModel.shared.documents { AppActions.updateModifiedLinkedContent(d) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Brush files (double-clicked in Finder, dropped on the Dock icon) go into the brush library.
        let brushes = urls.filter(BrushLibrary.isBrushFile)
        if !brushes.isEmpty { BrushLibrary.shared.importInBackground(brushes) }
        for u in urls where !BrushLibrary.isBrushFile(u) { AppActions.open(url: u) }
    }

    /// (Not during a self-test run: a test that closes its last offscreen window while pumping the run loop would
    /// otherwise quit the process with exit 0 and silently skip every module after it.)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !CommandLine.arguments.contains("--selftest") }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = AppModel.shared.documents.filter { $0.isDirty && $0.smartParent == nil && !($0.history.count <= 1) }
        if dirty.isEmpty { return .terminateNow }
        let a = NSAlert()
        a.messageText = "You have \(dirty.count) document\(dirty.count == 1 ? "" : "s") with unsaved changes."
        a.informativeText = "Do you want to quit anyway? Your changes will be lost."
        a.addButton(withTitle: "Quit")
        a.addButton(withTitle: "Cancel")
        return UIBlock.run(a) == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// Global single-key shortcuts (tools, colors) when not typing in a text field.
enum KeyRouter {
    static func handle(_ e: NSEvent) -> Bool {
        let app = AppModel.shared
        if DialogFocus.handleTab(e) { return true }       // Tab stays inside an open dialog
        // (the event's own window first: that is where the keystroke goes, also for events posted to a non-key window)
        if let r = (e.window ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }))?.firstResponder, r is NSText { return false }
        if app.dialog != nil { return false }
        guard NSApp.keyWindow?.identifier?.rawValue.contains("main") ?? true else { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        // While the mouse button is down on the canvas (mid-stroke, mid-drag) shortcuts are ignored, like in Photoshop:
        // a tool switch, Undo or any other command in the middle of a drag would act on a half-finished edit.
        // Space (reposition / hand), Return and Esc still reach the tool.
        if e.type == .keyDown, let c = AppActions.canvas, c.isTrackingMouse, ![49, 36, 76, 53].contains(e.keyCode) { return true }
        if mods == [.option], GenVariations.handleKey(e) { return true }   // ⌥← / ⌥→: previous / next generative variation
        if mods.contains(.command), ZoomController.handleKey(e) { return true }   // ⌘+ / keypad, ⌥⌘0
        if !mods.isEmpty && !(mods == [.option] && e.keyCode == 51) { return false }
        guard let canvas = AppActions.canvas else { return false }
        if Workflow2Keys.handle(e) { return true }   // hold "\\": show the original

        // Keys the canvas should always receive (space, enter, esc, arrows, delete, brackets)
        let canvasKeys: Set<UInt16> = [49, 36, 76, 53, 51, 117, 123, 124, 125, 126]
        if e.type == .keyUp {
            if e.keyCode == 49 { canvas.keyUp(with: e); return true }
            return SpringLoadedTools.keyUp(e)
        }
        if canvasKeys.contains(e.keyCode) {
            // ⇧⌫ is Edit ▸ Fill…: leave it to the menu (the canvas would treat it as a plain Delete and clear pixels)
            if e.keyCode == 51 && e.modifierFlags.contains(.shift) && !e.modifierFlags.contains(.option) { return false }
            if e.keyCode == 51 && e.modifierFlags.contains(.option) {
                AppActions.fillForegroundShortcut(); return true   // (a selected shape layer takes it as its fill)
            }
            canvas.keyDown(with: e)
            return true
        }
        guard let ch = e.charactersIgnoringModifiers?.lowercased(), ch.count == 1 else { return false }
        if ch == "[" || ch == "]" || ch == "{" || ch == "}" {
            if !canvas.currentTool.keyDown(e) { _ = BrushTool.handleBracketKeys(e) }
            canvas.overlay.needsDisplay = true
            return true
        }
        switch ch {
        case "d": app.resetColors(); return true
        case "x": app.swapColors(); return true
        case "q": AppActions.toggleQuickMask(); return true
        case "\t": app.showPanels.toggle(); return true
        default: break
        }
        // number keys: opacity (1 = 10% … 0 = 100%, two quick digits = exact), ⇧ + number: flow
        if BrushKeys.handleDigit(e) { return true }
        // Tool shortcuts
        let upper = ch.uppercased()
        let groups = ToolKind.groups.enumerated().filter { $0.element.first?.shortcut == upper }
        if e.isARepeat && SpringLoadedTools.isHolding(ch) { return true }
        SpringLoadedTools.keyDown(e, key: ch, previous: app.tool)
        guard !groups.isEmpty else { return SpringLoadedTools.selectLooseTool(upper) }
        var all = groups.flatMap { $0.element }
        // Tools with this key that sit in a group led by another key (Rotate View = R lives behind Hand) or are hidden
        // from the toolbar would never be reached: ⇧+key cycles through them too.
        all += (ToolKind.groups.flatMap { $0 } + ToolbarConfig.shared.hiddenTools).filter { $0.shortcut == upper && !all.contains($0) }
        if e.modifierFlags.contains(.shift), let i = all.firstIndex(of: app.tool) {
            app.tool = all[(i + 1) % all.count]
        } else if all.contains(app.tool) {
            // already in this group
        } else {
            let gi = groups[0].offset
            app.tool = app.groupSelection[gi] ?? groups[0].element[0]
        }
        return true
    }
}

// MARK: - Menus

/// Commands that act on a document are disabled while none is open (they used to stay enabled and silently do nothing)
/// and while a dialog is up. Dialogs are in-window overlays, so the menu bar stays live underneath them: a command run
/// there changed the document behind the dialog's back (its preview stuck to the old layer, its uncommitted live edits
/// were baked into the command's history step and survived Cancel), and a second dialog replaced the first without
/// running its Cancel. Like a modal dialog, an open dialog now owns the document until it is confirmed or cancelled.
private var noDocument: Bool { AppModel.shared.activeDocument == nil || AppModel.shared.dialog != nil }
/// Commands that don't need a document but open a dialog / change documents: unavailable while a dialog is up.
private var dialogOpen: Bool { AppModel.shared.dialog != nil }

struct LumenCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About ImageCrat") { AppModel.shared.dialog = .about }.disabled(dialogOpen)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Preferences…") { AppModel.shared.dialog = .preferences }.keyboardShortcut("k").disabled(dialogOpen)
        }
        CommandGroup(replacing: .newItem) {
            Button("New…") { AppModel.shared.dialog = .newDocument }.keyboardShortcut("n").disabled(dialogOpen)
            Button("Open…") { AppActions.openPanel() }.keyboardShortcut("o").disabled(dialogOpen)
            Menu("Open Recent") {
                ForEach(NSDocumentController.shared.recentDocumentURLs, id: \.self) { u in
                    Button(u.lastPathComponent) { AppActions.open(url: u) }
                }
            }.disabled(dialogOpen)
            Divider()
            Button("Close") { AppActions.closeDocument() }.keyboardShortcut("w").disabled(noDocument)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { AppActions.save() }.keyboardShortcut("s").disabled(noDocument)
            Button("Save As…") { AppActions.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(noDocument)
            Divider()
            Button("Place Embedded…") { AppActions.placePanel(linked: false) }.disabled(dialogOpen)
            Button("Place Linked…") { AppActions.placePanel(linked: true) }.disabled(dialogOpen)
        }
        CommandGroup(replacing: .importExport) {
            Button("Export As…") { AppModel.shared.dialog = .export }.keyboardShortcut("w", modifiers: [.command, .option, .shift]).disabled(noDocument)
            Button("Quick Export as PNG") { AppActions.quickExportPNG() }.keyboardShortcut("'", modifiers: [.command, .option, .shift]).disabled(noDocument)
            ExtensionMenuItems(menu: "File")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { AppActions.undo() }.keyboardShortcut("z")
            Button("Redo") { AppActions.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            Button("Step Backward") { AppActions.stepBackward() }.keyboardShortcut("z", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { AppActions.cut() }.keyboardShortcut("x")
            Button("Copy") { AppActions.copy() }.keyboardShortcut("c")
            Button("Copy Merged") { AppActions.copy(merged: true) }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Paste") { AppActions.paste() }.keyboardShortcut("v")
            Button("Paste in Place") { AppActions.paste(inPlace: true) }.keyboardShortcut("v", modifiers: [.command, .shift])
            Group {
            Button("Clear") { AppActions.clearSelectionPixels() }
            Divider()
            Button("Fill…") { AppModel.shared.dialog = .fill }.keyboardShortcut(.delete, modifiers: [.shift])
            Button("Stroke…") { AppModel.shared.dialog = .stroke }
            Button("Content-Aware Fill") { AppActions.contentAwareFill() }
            Divider()
            Button("Free Transform") { AppActions.freeTransform() }.keyboardShortcut("t").disabled(!AppActions.canFreeTransform)
            Menu("Transform") {
                Button("Flip Horizontal") { AppActions.flipLayers(horizontal: true) }
                Button("Flip Vertical") { AppActions.flipLayers(horizontal: false) }
                Button("Rotate 90° Clockwise") { AppActions.rotateLayers(degrees: 90) }
                Button("Rotate 90° Counter Clockwise") { AppActions.rotateLayers(degrees: -90) }
                Button("Rotate 180°") { AppActions.rotateLayers(degrees: 180) }
                Divider()
                Button("Warp") { AppActions.warp() }
            }.disabled(!AppActions.canFreeTransform)
            Group {   // (nothing to transform: an adjustment layer, an empty group or layer, a position-locked layer)
            Button("Content-Aware Scale") { AppActions.contentAwareScale() }.keyboardShortcut("c", modifiers: [.command, .option, .shift])
            Button("Puppet Warp") { AppActions.puppetWarp() }
            Button("Perspective Warp") { AppActions.perspectiveWarp() }
            }.disabled(!AppActions.canFreeTransform)
            Divider()
            Button("Define Brush Preset") { AppActions.defineBrush() }
            Button("Define Pattern") { AppActions.definePattern() }
            }.disabled(noDocument)
            ExtensionMenuItems(menu: "Edit")
        }
    }
}

struct LumenCommands2: Commands {
    var body: some Commands {
        CommandMenu("Image") {
            Group {
            Menu("Mode") {
                ForEach(ColorMode.allCases) { m in
                    Button((AppActions.doc?.state.colorMode == m ? "✓ " : "    ") + m.rawValue) { AppActions.convertMode(m) }
                }
                Divider()
                ForEach(BitDepth.allCases) { b in
                    Button((AppActions.doc?.state.bitDepth == b ? "✓ " : "    ") + b.displayName) { AppActions.setBitDepth(b) }
                }
                Divider()
                Button("Assign Profile…") { AppModel.shared.dialog = .colorProfile(convert: false) }
                Button("Convert to Profile…") { AppModel.shared.dialog = .colorProfile(convert: true) }
            }
            Menu("Adjustments") {
                Button("Brightness/Contrast…") { AppModel.shared.dialog = .adjustment(.brightnessContrast) }
                Button("Levels…") { AppModel.shared.dialog = .adjustment(.levels) }.keyboardShortcut("l")
                Button("Curves…") { AppModel.shared.dialog = .adjustment(.curves) }.keyboardShortcut("m")
                Button("Exposure…") { AppModel.shared.dialog = .adjustment(.exposure) }
                Divider()
                Button("Vibrance…") { AppModel.shared.dialog = .adjustment(.vibrance) }
                Button("Hue/Saturation…") { AppModel.shared.dialog = .adjustment(.hueSaturation) }.keyboardShortcut("u")
                Button("Color Balance…") { AppModel.shared.dialog = .adjustment(.colorBalance) }.keyboardShortcut("b")
                Button("Black & White…") { AppModel.shared.dialog = .adjustment(.blackWhite) }.keyboardShortcut("b", modifiers: [.command, .option, .shift])
                Button("Photo Filter…") { AppModel.shared.dialog = .adjustment(.photoFilter) }
                Button("Channel Mixer…") { AppModel.shared.dialog = .adjustment(.channelMixer) }
                Button("Color Lookup…") { AppModel.shared.dialog = .adjustment(.colorLookup) }
                Divider()
                Button("Invert") { AppActions.invertActive() }.keyboardShortcut("i")
                Button("Posterize…") { AppModel.shared.dialog = .adjustment(.posterize) }
                Button("Threshold…") { AppModel.shared.dialog = .adjustment(.threshold) }
                Button("Gradient Map…") { AppModel.shared.dialog = .adjustment(.gradientMap) }
                Button("Selective Color…") { AppModel.shared.dialog = .adjustment(.selectiveColor) }
                Divider()
                Button("Shadows/Highlights…") { AppModel.shared.dialog = .adjustment(.shadowsHighlights) }
                Button("HDR Toning…") { AppModel.shared.dialog = .adjustment(.hdrToning) }
                Button("Desaturate") { AppActions.desaturateActive() }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Match Color…") { AppModel.shared.dialog = .adjustment(.matchColor) }
                Button("Replace Color…") { AppModel.shared.dialog = .adjustment(.replaceColor) }
                Button("Equalize") { AppActions.equalize() }
            }
            Divider()
            Button("Auto Tone") { AppActions.autoLevels(perChannel: true) }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Auto Contrast") { AppActions.autoLevels(perChannel: false) }.keyboardShortcut("l", modifiers: [.command, .option, .shift])
            Button("Auto Color") { AppActions.autoColor() }.keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Image Size…") { AppModel.shared.dialog = .imageSize }.keyboardShortcut("i", modifiers: [.command, .option])
            Button("Canvas Size…") { AppModel.shared.dialog = .canvasSize }.keyboardShortcut("c", modifiers: [.command, .option])
            Menu("Image Rotation") {
                Button("180°") { AppActions.rotateCanvas(180) }
                Button("90° Clockwise") { AppActions.rotateCanvas(90) }
                Button("90° Counter Clockwise") { AppActions.rotateCanvas(-90) }
                Divider()
                Button("Flip Canvas Horizontal") { AppActions.flipCanvas(horizontal: true) }
                Button("Flip Canvas Vertical") { AppActions.flipCanvas(horizontal: false) }
            }
            Button("Crop") { AppActions.cropToSelection() }
            Button("Trim") { AppActions.trimTransparent() }
            Button("Reveal All") { AppActions.revealAll() }
            Divider()
            Button("Duplicate…") { AppActions.duplicateDocument() }
            }.disabled(noDocument)
            ExtensionMenuItems(menu: "Image")
        }
        CommandMenu("Layer") {
            Group {
            Menu("New") {
                Button("Layer…") { AppActions.newLayer() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Group") { AppActions.newGroup() }
                Menu("Artboard") { ArtboardMenuItems(items: ArtboardMenu.newArtboardItems()) }   // presets grouped like the options bar
                Button("Artboard from Layers") { AppActions.artboardFromLayers() }
                Divider()
                Button("Layer via Copy") { AppActions.layerViaCopy() }.keyboardShortcut("j")
                Button("Layer via Cut") { AppActions.layerViaCopy(cut: true) }.keyboardShortcut("j", modifiers: [.command, .shift])
                ExtensionMenuItems(menu: "Layer/New")
            }
            Button("Duplicate Layer") { AppActions.duplicateLayers() }
            Button("Delete Layer") { AppActions.deleteLayers() }
            Button("Link Layers") { AppActions.toggleLinkLayers() }
            Button("Select Linked Layers") { AppActions.selectLinkedLayers() }
            Divider()
            Button("Layer Style…") { if let id = AppActions.doc?.activeLayerID { AppModel.shared.dialog = .layerStyle(id) } }
            Menu("Layer Style Options") {
                // Photoshop's Layer ▸ Layer Style ▸ Blending Options… / <effect>…: opens Layer Style with that effect added
                ForEach(StyleSection.allCases) { sec in
                    Button(sec.menuTitle) { LayerStyleDialog.openFromMenu(sec) }
                    if sec == .blending { Divider() }
                }
                Divider()
                Button("Copy Layer Style") { AppActions.copyLayerStyle() }
                Button("Paste Layer Style") { AppActions.pasteLayerStyle() }
                Button("Clear Layer Style") { AppActions.clearLayerStyle() }
                Divider()
                Button("Global Light…") { AppModel.shared.dialog = .globalLight }
                ExtensionMenuItems(menu: "Layer/Layer Style")
            }
            Menu("New Fill Layer") {
                Button("Solid Color…") { FillLayerDialog.newLayer(.solid) }
                Button("Gradient…") { FillLayerDialog.newLayer(.gradient) }
                Button("Pattern…") { FillLayerDialog.newLayer(.pattern) }
            }
            Menu("New Adjustment Layer") {
                ForEach(AdjustmentKind.layerKinds) { k in
                    Button(k.displayName + "…") { AppActions.newAdjustmentLayer(k) }
                }
            }
            Divider()
            Menu("Layer Mask") {
                Button("Reveal All") { AppActions.addMask(.revealAll) }
                Button("Hide All") { AppActions.addMask(.hideAll) }
                Button("Reveal Selection") { AppActions.addMask(.revealSelection) }
                Button("Hide Selection") { AppActions.addMask(.hideSelection) }
                Button("From Transparency") { AppActions.addMask(.fromTransparency) }
                Divider()
                Button("Delete") { AppActions.deleteMask() }
                Button("Apply") { AppActions.applyMask() }
                Button("Disable / Enable") { AppActions.toggleMaskEnabled() }
                Button("Invert Mask") { AppActions.invertMask() }
            }
            Menu("Vector Mask") {
                Button("Current Path") { AppActions.addVectorMask() }
                Button("Delete") { if let d = AppActions.doc, let id = d.activeLayerID, d.state.layer(id)?.vectorMask != nil { d.updateLayer(id) { $0.vectorMask = nil }; d.commit("Delete Vector Mask") } }
            }
            Button("Create Clipping Mask") { AppActions.toggleClippingMask() }.keyboardShortcut("g", modifiers: [.command, .option])
            Divider()
            Menu("Smart Objects") {
                Button("Convert to Smart Object") { AppActions.convertToSmartObject() }
                Button("Edit Contents") { AppActions.editSmartContents() }
                Button("Replace Contents…") { AppActions.replaceSmartContents() }
                Button("Export Contents…") { AppActions.exportSmartContents() }
                Button("Rasterize") { AppActions.rasterizeLayer() }
                Divider()
                Button("Update Modified Content") { if let d = AppActions.doc { AppActions.updateModifiedLinkedContent(d, all: true) } }
                Button("Relink to File…") { AppActions.relinkToFile() }
                Button("Embed Linked") { AppActions.embedLinked() }
                Button("Convert to Linked…") { AppActions.convertToLinked() }
                ExtensionMenuItems(menu: "Layer/Smart Objects")
            }
            Menu("Rasterize") {
                Button("Layer") { AppActions.rasterizeLayer() }
                Button("Layer Style") { AppActions.rasterizeLayerStyle() }
            }
            Divider()
            Button("Group Layers") { AppActions.groupLayers() }.keyboardShortcut("g").disabled(!AppActions.canGroupLayers)   // (not with an artboard selected)
            Button("Ungroup Layers") { AppActions.ungroupLayers() }.keyboardShortcut("g", modifiers: [.command, .shift])
            Menu("Arrange") {
                Button("Bring to Front") { AppActions.arrange(.front) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Bring Forward") { AppActions.arrange(.forward) }.keyboardShortcut("]")
                Button("Send Backward") { AppActions.arrange(.backward) }.keyboardShortcut("[")
                Button("Send to Back") { AppActions.arrange(.back) }.keyboardShortcut("[", modifiers: [.command, .shift])
                ExtensionMenuItems(menu: "Layer/Arrange")
            }
            Menu("Align") {
                Button("Left Edges") { AppActions.align(.left) }
                Button("Horizontal Centers") { AppActions.align(.hCenter) }
                Button("Right Edges") { AppActions.align(.right) }
                Divider()
                Button("Top Edges") { AppActions.align(.top) }
                Button("Vertical Centers") { AppActions.align(.vCenter) }
                Button("Bottom Edges") { AppActions.align(.bottom) }
            }
            Menu("Distribute") {
                Button("Horizontal Centers") { AppActions.distribute(horizontal: true) }
                Button("Vertical Centers") { AppActions.distribute(horizontal: false) }
            }
            Menu("Lock") {
                Button("Transparent Pixels") { AppActions.setLock(\.transparency) }
                Button("Image Pixels") { AppActions.setLock(\.pixels) }
                Button("Position") { AppActions.setLock(\.position) }
                Button("All") { AppActions.setLock(\.all) }
            }
            Divider()
            Button("Merge Down") { AppActions.mergeDown() }.keyboardShortcut("e")
            Button("Merge Visible") { AppActions.mergeVisible() }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Stamp Visible") { AppActions.stampVisible() }.keyboardShortcut("e", modifiers: [.command, .option, .shift])
            Button("Flatten Image") { AppActions.flattenImage() }
            }.disabled(noDocument)
            ExtensionMenuItems(menu: "Layer")
        }
    }
}

struct LumenCommands3: Commands {
    var body: some Commands {
        CommandMenu("Type") {
            Group {
            Button("Convert to Shape") { AppActions.convertTextToShape() }
            Button("Create Work Path") { AppActions.createWorkPathFromText() }
            Button("Rasterize Type Layer") { AppActions.rasterizeLayer() }
            Divider()
            Button("Warp Text…") { TypeEdit.openWarpDialog() }
            Button("Toggle Text Orientation") { TypeEdit.toggleOrientation() }
            Button("Flip Type on Path") { TypeEdit.flipPathText() }
            }.disabled(noDocument)
            ExtensionMenuItems(menu: "Type")
        }
        CommandMenu("Select") {
            // (not part of the group below: ⌘A must keep working in text fields, including those of an open dialog)
            Button("All") { if AppModel.shared.dialog == nil || AppActions.isTextEditing { AppActions.selectAll() } }.keyboardShortcut("a")
            Group {
            Button("Deselect") { AppActions.deselect() }.keyboardShortcut("d")
            Button("Reselect") { AppActions.reselect() }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Inverse") { AppActions.inverseSelection() }.keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Subject") { AppActions.selectSubject() }
            Button("Sky") { AppActions.selectSky() }
            Button("Focus Area…") { AppModel.shared.dialog = .focusArea }
            Button("Select and Mask…") { AppModel.shared.dialog = .selectAndMask }.keyboardShortcut("r", modifiers: [.command, .option])
            Button("Color Range…") { AppModel.shared.dialog = .colorRange }
            Button("Load Layer Transparency") { AppActions.selectLayerPixels() }
            Divider()
            Menu("Modify") {
                Button("Border…") { AppModel.shared.dialog = .modifySelection(.border) }
                Button("Smooth…") { AppModel.shared.dialog = .modifySelection(.smooth) }
                Button("Expand…") { AppModel.shared.dialog = .modifySelection(.expand) }
                Button("Contract…") { AppModel.shared.dialog = .modifySelection(.contract) }
                Button("Feather…") { AppModel.shared.dialog = .modifySelection(.feather) }.keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF6FunctionKey)!)), modifiers: [.shift])
            }
            Button("Grow") { AppActions.growSelection() }
            Button("Similar") { AppActions.selectSimilar() }
            Button("Transform Selection") { AppActions.transformSelection() }
            Divider()
            Button("Remove Background") { AppActions.removeBackground() }
            Button("Make Work Path") { AppActions.workPathFromSelection() }
            Button("Save Selection") { AppActions.saveSelection() }
            Button("Edit in Quick Mask Mode") { AppActions.toggleQuickMask() }
            }.disabled(noDocument)
            ExtensionMenuItems(menu: "Select")
        }
        CommandMenu("Filter") {
            Group {
            // (disabled where the filter has nothing to work on: adjustment layers, groups — see FilterLauncher.target)
            Button("Last Filter") { AppActions.repeatLastFilter() }.keyboardShortcut("f", modifiers: [.command, .control])
                .disabled(AppActions.lastFilter == nil || !FilterLauncher.canRun())
            Button("Convert for Smart Filters") { AppActions.convertToSmartObject() }.disabled(!AppActions.canConvertToSmartObject)
            Divider()
            Group {
            Button("Filter Gallery…") { FilterLauncher.launch(.filterGallery) }
            Button("Camera Raw Filter…") { FilterLauncher.launch(.cameraRaw) }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Lens Correction…") { FilterLauncher.launch(.lensCorrection) }.keyboardShortcut("r", modifiers: [.command, .shift])
            }.disabled(!FilterLauncher.canRun())
            Button("Liquify…") { FilterLauncher.liquify() }.keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(!FilterLauncher.canRun(smartFilter: true, layerPixels: true))
            Divider()
            ForEach(FilterCategory.allCases, id: \.self) { cat in
                Menu(cat.rawValue) {
                    ForEach(FilterKind.byCategory(cat)) { k in
                        Button(k.displayName + (k.isImmediate ? "" : "…")) { FilterLauncher.launch(k) }.disabled(!FilterLauncher.canRun())
                    }
                    ExtensionMenuItems(menu: "Filter/" + cat.rawValue)
                }
            }
            }.disabled(noDocument)
            ExtensionMenuItems(menu: "Filter")
        }
        CommandGroup(before: .toolbar) {
            Group {
            ForEach(Array(ZoomCommand.viewMenu.enumerated()), id: \.offset) { _, c in
                if let c { ZoomMenuItem(command: c) } else { Divider() }
            }
            }.disabled(noDocument)
            Divider()
            Button("Proof Setup…") { AppModel.shared.dialog = .proofSetup }.disabled(dialogOpen)
            Group {
            Button("Proof Colors") { if let d = AppActions.doc { d.proofColors.toggle(); d.setNeedsRender() } }.keyboardShortcut("y")
            Button("Gamut Warning") { if let d = AppActions.doc { d.gamutWarning.toggle(); d.setNeedsRender() } }.keyboardShortcut("y", modifiers: [.command, .shift])
            Divider()
            Button("Rulers") { AppActions.doc?.showRulers.toggle(); AppActions.canvas?.setNeedsRender() }.keyboardShortcut("r")
            Button("Grid") { AppActions.doc?.showGrid.toggle(); AppActions.canvas?.setNeedsRender() }.keyboardShortcut("'")
            Button("Guides") { AppActions.doc?.showGuides.toggle(); AppActions.canvas?.setNeedsRender() }.keyboardShortcut(";")
            Button("Pixel Grid") { AppActions.doc?.showPixelGrid.toggle(); AppActions.canvas?.setNeedsRender() }
            Button("Selection Edges") { AppActions.doc?.showSelectionEdges.toggle(); AppActions.canvas?.setNeedsRender() }.keyboardShortcut("h", modifiers: [.command, .control])
            Button("Snap") { AppActions.doc?.snapEnabled.toggle() }.keyboardShortcut(";", modifiers: [.command, .shift])
            Button("Clear Guides") { AppActions.clearGuides() }
            }.disabled(noDocument)
            Divider()
            ExtensionMenuItems(menu: "View")
        }
        CommandGroup(replacing: .windowSize) {
            // ⌘M is Image ▸ Adjustments ▸ Curves… (as in Photoshop). The standard Window ▸ Minimize item claims ⌘M too, and
            // the system then strips the shortcut from Curves — so Minimize moves to ⌃⌘M, where Photoshop has it.
            Button("Minimize") { (NSApp.keyWindow ?? NSApp.mainWindow)?.miniaturize(nil) }.keyboardShortcut("m", modifiers: [.command, .control])
            Button("Zoom") { (NSApp.keyWindow ?? NSApp.mainWindow)?.zoom(nil) }
        }
        CommandGroup(after: .windowArrangement) {
            Menu("Workspace") { WorkspaceMenu() }
            Menu("Panels") { PanelVisibilityMenu() }
            Divider()
            Button("Show/Hide Panels") { AppModel.shared.showPanels.toggle() }
            Button("Show/Hide Secondary Panels") { AppModel.shared.showSecondaryPanels.toggle() }
            Divider()
            Button("Next Document") {
                let a = AppModel.shared
                if let i = a.documents.firstIndex(where: { $0.id == a.activeDocumentID }), !a.documents.isEmpty {
                    a.activeDocumentID = a.documents[(i + 1) % a.documents.count].id
                }
            }.keyboardShortcut("`", modifiers: [.control]).disabled(dialogOpen)
            ForEach(AppModel.shared.documents) { d in
                Button(d.name) { AppModel.shared.activeDocumentID = d.id }.disabled(dialogOpen)
            }
            ExtensionMenuItems(menu: "Window")
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { AppModel.shared.dialog = .shortcuts }.disabled(dialogOpen)
            ExtensionMenuItems(menu: "Help")
        }
    }
}

/// Opens filters either immediately or via the parameter dialog.
enum FilterLauncher {
    /// What a Filter command can do with the active layer.
    enum Target: Equatable {
        case pixels          // a pixel layer, a layer mask being edited, or the Quick Mask
        case smartFilter     // a smart object: the filter is added as a smart filter
        case needsRasterize  // type, shape, fill (and smart objects for filters that only work on pixels): offer to rasterize first
        case none            // adjustment layers and groups have no pixels of their own; no layer
    }

    /// `smartFilter`: the filter can run as a smart filter. `layerPixels`: it needs the pixels of a layer (not a mask).
    static func target(_ d: Document?, smartFilter: Bool = true, layerPixels: Bool = false) -> Target {
        guard let d else { return .none }
        if d.quickMask { return layerPixels ? .none : .pixels }
        guard let l = d.activeLayer else { return .none }
        if !layerPixels, d.editTarget == .mask, l.mask != nil { return .pixels }
        if l.isRaster { return .pixels }
        if l.isSmartObject { return smartFilter ? .smartFilter : .needsRasterize }
        if l.isText || l.isShape || l.isFill { return .needsRasterize }
        return .none
    }

    /// Menu state of a Filter command (the same test `prepare` makes before running it, so the two can't disagree).
    static func canRun(smartFilter: Bool = true, layerPixels: Bool = false) -> Bool {
        target(AppActions.doc, smartFilter: smartFilter, layerPixels: layerPixels) != .none
    }

    /// Before a filter runs: type / shape / fill layers (and smart objects, for filters without a smart version) are
    /// rasterized after asking, like Photoshop, and the filter then carries on. False when it must not run.
    static func prepare(smartFilter: Bool = true, layerPixels: Bool = false) -> Bool {
        let d = AppActions.doc
        switch target(d, smartFilter: smartFilter, layerPixels: layerPixels) {
        case .pixels, .smartFilter: return true
        case .none: Beep.play(); return false
        case .needsRasterize:
            guard let d, let id = d.activeLayerID else { return false }
            AppActions.offerRasterize(layer: id)
            return d.state.layer(id)?.isRaster == true
        }
    }

    /// Liquify, like Photoshop: on a smart object it is a smart filter (no rasterizing), otherwise it warps the pixels.
    static func liquify() {
        guard prepare(smartFilter: true, layerPixels: true) else { return }
        AppModel.shared.dialog = .liquify
    }

    static func launch(_ k: FilterKind) {
        if k == .liquify { liquify(); return }
        guard AppActions.doc != nil, MaskTargetPrompt.resolve(k.displayName), let d = AppActions.doc, prepare() else { return }
        switch k {
        case .fieldBlur, .irisBlur, .pathBlur:
            AppActions.startBlurGallery(k); return
        case .displace:
            let p = NSOpenPanel()
            p.allowedContentTypes = AppActions.openTypes
            p.message = "Choose a displacement map (red = horizontal, green = vertical)"
            guard UIBlock.run(p) == .OK, let url = p.url, let (cg, _) = DocumentIO.loadImage(url: url) else { return }
            AppActions.pendingFilterPayload = PixelBuffer(cgImage: cg)
        default: break
        }
        let colors = [AppModel.shared.foreground, AppModel.shared.background]
        if k.isImmediate {
            AppActions.applyFilter(FilterInstance(kind: k, colors: colors))
        } else {
            let smart = d.activeLayer?.isSmartObject == true ? d.activeLayerID : nil
            AppModel.shared.dialog = .filter(k, smartLayer: smart, editingFilter: nil)
        }
    }
}

/// Top-level Plugins menu (items come from the plugin manager via MenuRegistry).
struct PluginCommands: Commands {
    var body: some Commands {
        CommandMenu("Plugins") {
            let items = MenuRegistry.items(for: "Plugins")
            ForEach(items) { item in
                if item.dividerBefore { Divider() }
                Button(item.title, action: item.action).disabled(dialogOpen)
            }
        }
    }
}

/// Top-level Particles menu (items come from ParticlesModule).
struct ParticleCommands: Commands {
    var body: some Commands {
        CommandMenu("Particles") { ParticleMenuItems() }
    }
}

/// A View ▸ zoom command with its shortcut. (Zoom In / Out stay enabled: their state would read the zoom, and the menu
/// bar would then be rebuilt on every frame of a pinch.)
struct ZoomMenuItem: View {
    let command: ZoomCommand
    var body: some View {
        let on = command == .zoomIn || command == .zoomOut || ZoomController.isEnabled(command)
        if let k = command.shortcut {
            Button(command.title) { ZoomController.run(command) }.keyboardShortcut(k.key, modifiers: k.modifiers).disabled(!on)
        } else {
            Button(command.title) { ZoomController.run(command) }.disabled(!on)
        }
    }
}
