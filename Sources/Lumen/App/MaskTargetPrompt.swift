import AppKit
import SwiftUI
import ImageCratCore

/// A filter or adjustment dialog opened while a layer's mask is the edit target: Photoshop silently filters the mask,
/// which reads as "the filter does nothing" (the user expected the element itself to change). Ask instead, unless the
/// user told us to remember an answer.
enum MaskTargetPrompt {
    enum Choice: String { case ask, image, mask }
    static let defaultsKey = "Lumen.MaskTargetChoice"

    static var choice: Choice {
        get { Choice(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
    /// Tests answer here instead of an alert (nil = keep the mask target, the behaviour automated runs had before).
    nonisolated(unsafe) static var testAnswer: Choice?

    /// Called before a filter / adjustment dialog opens. Switches the edit target to the image when that is the answer;
    /// false = cancelled.
    static func resolve(_ command: String) -> Bool {
        guard let d = AppActions.doc, d.editTarget == .mask, let l = d.activeLayer, l.mask != nil else { return true }
        let answer: Choice
        if let t = testAnswer { answer = t }
        else if GenAIKeyOverrides.realKeysBlocked || Automation.isHeadless { return true }
        else if choice != .ask { answer = choice }
        else {
            let a = NSAlert()
            a.messageText = "Apply \(command) to the image or to the layer mask?"
            a.informativeText = "The layer mask of “\(l.name)” is selected, so the filter would change the mask, not the picture."
            a.addButton(withTitle: "Image")
            a.addButton(withTitle: "Layer Mask")
            a.addButton(withTitle: "Cancel")
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Remember my choice (change it in Preferences ▸ General)"
            let r = UIBlock.run(a)
            switch r {
            case .alertFirstButtonReturn: answer = .image
            case .alertSecondButtonReturn: answer = .mask
            default: return false
            }
            if a.suppressionButton?.state == .on { choice = answer }
        }
        if answer == .image { d.editTarget = .content }
        return true
    }
}

/// Preferences ▸ General: what filters and adjustments change while a layer mask is selected.
struct MaskTargetPreference: View {
    @State private var choice = MaskTargetPrompt.choice
    var body: some View {
        Picker("Filters on a selected mask", selection: $choice) {
            Text("Ask each time").tag(MaskTargetPrompt.Choice.ask)
            Text("Change the image").tag(MaskTargetPrompt.Choice.image)
            Text("Change the mask").tag(MaskTargetPrompt.Choice.mask)
        }
        .onChange(of: choice) { _, v in MaskTargetPrompt.choice = v }
        .help("When a layer's mask is selected and you open a filter or adjustment dialog")
    }
}
