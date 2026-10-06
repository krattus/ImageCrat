import SwiftUI
import AppKit
import ImageCratCore

// MARK: - Contextual Task Bar

/// What the task bar offers for the current document state.
enum TaskBarContext: Equatable {
    case selection, pixelLayer, typeLayer, other
    /// Active layer is a generative layer (wins over a selection: the bar keeps the variation controls and adds Deselect).
    case generative

    static func of(_ d: Document) -> TaskBarContext {
        if let id = d.activeLayerID, d.state.generative[id] != nil { return .generative }
        if d.state.selection != nil { return .selection }
        guard let l = d.activeLayer else { return .other }
        if l.isText { return .typeLayer }
        if l.isRaster || l.isSmartObject { return .pixelLayer }
        return .other
    }

    /// Button titles in order (used by the view and the self test).
    var actions: [String] {
        switch self {
        case .selection: return ["Select and Mask…", "Invert", "Feather…", "Mask", "Fill…", "Content-Aware Fill", "Generative Fill…", "Deselect"]
        case .pixelLayer: return ["Select Subject", "Remove Background", "Transform"]
        case .typeLayer: return ["Font", "Size"]
        case .other: return ["Select Subject"]
        case .generative: return ["Previous Variation", "Next Variation", "Variations", "Generate"]
        }
    }

    static func perform(_ title: String) {
        let app = AppModel.shared
        switch title {
        case "Select and Mask…": app.dialog = .selectAndMask
        case "Invert": AppActions.inverseSelection()
        case "Feather…": app.dialog = .modifySelection(.feather)
        case "Mask": AppActions.addMask(.revealSelection)
        case "Fill…": app.dialog = .fill
        case "Content-Aware Fill": AppActions.contentAwareFill()
        case "Generative Fill…": NotificationCenter.default.post(name: Notification.Name("LumenGenerativeFill"), object: nil)
        case "Deselect": AppActions.deselect()
        case "Select Subject": AppActions.selectSubject()
        case "Remove Background": AppActions.removeBackground()
        case "Transform": AppActions.freeTransform()
        case "Previous Variation": GenVariations.previous()
        case "Next Variation": GenVariations.next()
        case "Generate": GenVariations.generateMoreActive()
        default: break
        }
    }

    static func symbol(_ title: String) -> String {
        switch title {
        case "Select and Mask…": return "wand.and.rays"
        case "Invert": return "circle.lefthalf.filled"
        case "Feather…": return "aqi.medium"
        case "Mask": return "rectangle.inset.filled"
        case "Fill…": return "drop.fill"
        case "Content-Aware Fill": return "wand.and.stars"
        case "Generative Fill…": return "sparkles"
        case "Deselect": return "xmark"
        case "Select Subject": return "person.crop.rectangle"
        case "Remove Background": return "person.crop.circle.badge.minus"
        case "Transform": return "arrow.up.left.and.arrow.down.right"
        default: return "circle"
        }
    }
}

/// Hosts the floating bar over the canvas (placed below the selection / active layer).
struct ContextualTaskBarHost: View {
    @Bindable var app = AppModel.shared
    @Bindable var ts = ToolsSettings.shared

    var body: some View {
        GeometryReader { g in
            if ts.taskBarVisible, app.dialog == nil, let d = app.activeDocument, let canvas = AppActions.canvas, !app.textEditingActive {
                let ctx = TaskBarContext.of(d)
                let anchor = anchorRect(d, canvas)
                let size = CGSize(width: ctx == .selection ? 470 : (ctx == .generative ? (d.state.selection != nil ? 600 : 420) : 300), height: 34)
                let pos = position(anchor: anchor, bar: size, in: g.size)
                ContextualTaskBar(doc: d, context: ctx)
                    .fixedSize()
                    .position(pos)
                    .animation(.easeOut(duration: 0.12), value: pos.y)
            }
        }
    }

    private func anchorRect(_ d: Document, _ canvas: CanvasView) -> CGRect {
        _ = d.zoom; _ = d.viewOffset; _ = d.viewRotation; _ = d.revision   // observation
        if let b = d.state.selectionBounds { return canvas.docToView(b.cgRect) }
        if let l = d.activeLayer, !l.isAdjustment, let b = Compositor.shared.contentBounds(l, state: d.state) {
            return canvas.docToView(b.intersection(d.state.canvasCGRect.insetBy(dx: -10000, dy: -10000)))
        }
        return canvas.docToView(d.state.canvasCGRect)
    }

    private func position(anchor: CGRect, bar: CGSize, in size: CGSize) -> CGPoint {
        var y = anchor.maxY + 14 + bar.height / 2
        if y > size.height - bar.height / 2 - 8 { y = anchor.minY - 14 - bar.height / 2 }    // no room below: above
        y = min(max(bar.height / 2 + 24, y), size.height - bar.height / 2 - 8)
        let x = min(max(bar.width / 2 + 8, anchor.midX), max(bar.width / 2 + 8, size.width - bar.width / 2 - 8))
        return CGPoint(x: x, y: y)
    }
}

struct ContextualTaskBar: View {
    let doc: Document
    let context: TaskBarContext
    @Bindable var app = AppModel.shared

    var body: some View {
        HStack(spacing: 4) {
            switch context {
            case .typeLayer:
                if let t = doc.activeLayer?.text {
                    FontPicker(fontName: Binding(get: { t.fontName }, set: { v in TypeEdit.update { $0.fontName = v } }))
                    NumberField(label: "", value: Binding(get: { t.fontSize }, set: { v in TypeEdit.update { $0.fontSize = max(1, v) } }), width: 40)
                    Text("px").foregroundStyle(Theme.textFaint)
                }
            case .generative:
                GenTaskBarControls(doc: doc)
            default:
                ForEach(context.actions, id: \.self) { a in
                    Button { TaskBarContext.perform(a) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: TaskBarContext.symbol(a)).font(.system(size: 10))
                            Text(tr(a)).lineLimit(1)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(a == "Generative Fill…" ? Theme.accent : Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help(tr(a))
                }
            }
            Menu {
                Button("Hide Bar (Window ▸ Contextual Task Bar)") { ToolsSettings.shared.taskBarVisible = false }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
        }
        .font(Theme.font)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panelBG.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}
