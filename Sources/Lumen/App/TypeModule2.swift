import AppKit
import SwiftUI
import ImageCratCore

/// Type features, part 2: lists, area type, variable fonts, Glyphs panel, emoji, Match Font, Dynamic Text,
/// world-ready composer. Registered from `FeatureModules.registerAll()`.
enum TypeModule2 {
    static func register() {
        // Our own Edit ▸ Emoji & Symbols replaces the item AppKit would add automatically (avoids a duplicate).
        UserDefaults.standard.register(defaults: ["NSDisabledCharacterPaletteMenuItem": true])

        PanelRegistry.register(PanelRegistry.Def(id: "glyphs", title: "Glyphs") { AnyView(GlyphsPanel()) })
        DialogRegistry.register("matchFont") { AnyView(MatchFontDialog()) }

        // Edit
        MenuRegistry.add("Edit", "Emoji & Symbols", key: " ", modifiers: [.command, .control], dividerBefore: true) {
            NSApp.orderFrontCharacterPalette(nil)
        }

        // Type ▸ Panels
        MenuRegistry.add("Type", "Glyphs Panel", submenu: "Panels") { WorkspaceManager.shared.toggle("glyphs") }
        MenuRegistry.add("Type", "Character Panel", submenu: "Panels") { WorkspaceManager.shared.toggle("character") }
        MenuRegistry.add("Type", "Paragraph Panel", submenu: "Panels") { WorkspaceManager.shared.toggle("paragraph") }

        // Type ▸ Bullets and Numbering
        let lists: [(String, TextListStyle?)] = [
            ("None", nil),
            ("Bulleted List •", TextListStyle(kind: .bullet, bullet: .disc)),
            ("Dash List –", TextListStyle(kind: .bullet, bullet: .dash)),
            ("Circle List ◦", TextListStyle(kind: .bullet, bullet: .circle)),
            ("Numbered List 1.", TextListStyle(kind: .numbered, numbering: .decimal)),
            ("Lettered List a.", TextListStyle(kind: .numbered, numbering: .lowerAlpha)),
            ("Lettered List A.", TextListStyle(kind: .numbered, numbering: .upperAlpha)),
            ("Roman List i.", TextListStyle(kind: .numbered, numbering: .lowerRoman)),
            ("Roman List I.", TextListStyle(kind: .numbered, numbering: .upperRoman)),
        ]
        for (title, l) in lists {
            MenuRegistry.add("Type", title, submenu: "Bullets and Numbering") { TypeActions2.setList(l) }
        }

        // Type ▸ conversions / area type / Dynamic Text
        MenuRegistry.add("Type", "Convert to Point Text", dividerBefore: true) { TypeActions2.convert("Convert to Point Text") { $0.convertToPointText() } }
        MenuRegistry.add("Type", "Convert to Paragraph Text") { TypeActions2.convert("Convert to Paragraph Text") { $0.convertToParagraphText() } }
        MenuRegistry.add("Type", "Create Area Type from Path") { TypeActions2.areaFromActivePath() }
        MenuRegistry.add("Type", "Fit Text to Box (Dynamic Text)") { TypeActions2.toggleFit() }
        MenuRegistry.add("Type", "Match Font…") {
            if AppModel.shared.textEditingActive { AppActions.canvas?.commitCurrentTool() }
            guard AppActions.doc != nil else { return }
            DialogRegistry.show("matchFont")
        }

        // Type ▸ Language Options (composer / direction)
        MenuRegistry.add("Type", "Latin Composer", submenu: "Language Options") { TypeActions2.updateParagraph("Latin Composer") { $0.composer = .latin } }
        MenuRegistry.add("Type", "World-Ready Composer", submenu: "Language Options") { TypeActions2.updateParagraph("World-Ready Composer") { $0.composer = .worldReady } }
        MenuRegistry.add("Type", "Text Direction: Auto", submenu: "Language Options") {
            TypeActions2.updateParagraph("Text Direction") { $0.composer = .worldReady; $0.direction = .auto }
        }
        MenuRegistry.add("Type", "Text Direction: Left-to-Right", submenu: "Language Options") {
            TypeActions2.updateParagraph("Text Direction") { t in
                t.composer = .worldReady
                if t.direction == .rtl && t.alignment == .right { t.alignment = .left }
                t.direction = .ltr
            }
        }
        MenuRegistry.add("Type", "Text Direction: Right-to-Left", submenu: "Language Options") {
            TypeActions2.updateParagraph("Text Direction") { t in
                t.composer = .worldReady
                if t.alignment == .left { t.alignment = .right }
                t.direction = .rtl
            }
        }

        TypeSelfTests2.register()
    }
}
