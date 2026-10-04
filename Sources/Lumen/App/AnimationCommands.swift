import SwiftUI

/// Menu items for animation export/import, printing and the Timeline window.
struct AnimationCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("Page Setup…") { Printing.pageSetup() }.disabled(AppModel.shared.dialog != nil)   // ⇧⌘P is the Command Palette (Workflow2)
            Button("Print…") { Printing.print() }.keyboardShortcut("p").disabled(AppModel.shared.activeDocument == nil || AppModel.shared.dialog != nil)
            Button("Print One Copy") { Printing.printOneCopy() }.keyboardShortcut("p", modifiers: [.command, .option, .shift]).disabled(AppModel.shared.activeDocument == nil || AppModel.shared.dialog != nil)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Timeline") {
                let tl = TimelineController.shared
                if tl.isPanelVisible { tl.stop() }
                tl.isPanelVisible.toggle()
            }
        }
    }
}
