import SwiftUI
import ImageCratCore

enum Theme {
    private static var t: InterfaceTheme { AppModel.shared.prefs.theme }
    private static func g(_ v: Double) -> Color { Color(white: max(0, min(1, v))) }
    private static var p: Double { t.panel }

    static var appBG: Color { g(t.isLight ? p - 0.1 : p - 0.066) }
    static var panelBG: Color { g(p) }
    static var panelHeader: Color { g(t.isLight ? p - 0.05 : p - 0.031) }
    static var fieldBG: Color { g(t.isLight ? p + 0.18 : p - 0.076) }
    static var border: Color { g(t.isLight ? p - 0.25 : p - 0.116) }
    static var divider: Color { g(t.isLight ? p - 0.15 : p + 0.074) }
    static var text: Color { g(t.isLight ? 0.1 : 0.85) }
    static var textDim: Color { g(t.isLight ? 0.3 : 0.6) }
    static var textFaint: Color { g(t.isLight ? 0.45 : 0.42) }
    static let accent = Color(red: 0.08, green: 0.45, blue: 0.9)
    static var selection: Color { t.isLight ? Color(red: 0.62, green: 0.74, blue: 0.9) : Color(red: 0.25, green: 0.33, blue: 0.45) }
    static var hover: Color { g(t.isLight ? p - 0.08 : p + 0.064) }
    static var toolActive: Color { g(t.isLight ? p - 0.2 : p - 0.116) }
    static var colorScheme: ColorScheme { t.isLight ? .light : .dark }

    static let font = Font.system(size: 11)
    static let fontSmall = Font.system(size: 10)
    static let fontBold = Font.system(size: 11, weight: .semibold)
    static let mono = Font.system(size: 11).monospacedDigit()
}

extension View {
    func panelText() -> some View { font(Theme.font).foregroundStyle(Theme.text) }
}

/// Uppercase small caption.
struct Caption: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textFaint).tracking(0.5)
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    var active: Bool = false
    var size: CGFloat = 22
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.55))
                .frame(width: size, height: size)
                .foregroundStyle(active ? Color.white : Theme.text)
                .background(RoundedRectangle(cornerRadius: 4).fill(active ? Theme.accent.opacity(0.8) : (hovering ? Theme.hover : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct PanelButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(prominent ? Theme.accent.opacity(configuration.isPressed ? 0.7 : 1) : Color(white: configuration.isPressed ? 0.3 : 0.24)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(white: 0.35), lineWidth: prominent ? 0 : 0.5))
            .foregroundStyle(.white)
    }
}

/// The numeric field (`NumberField` / `ValueSlider`) whose typed text has not reached its value yet.
///
/// Typed numbers used to be applied only on Return or when focus left the field. A click on a button doesn't move
/// keyboard focus, so a dialog's OK / Create ran with the old value (QA B01). The pending text is now committed when AppKit
/// ends the field's editing session (Tab, Return, focus moving elsewhere), when a click lands anywhere outside the field,
/// and before a dialog's OK runs; a dialog that closes any other way drops it.
enum FieldEdits {
    private struct Pending {
        let id: UUID
        weak var field: NSTextField?
        var commit: () -> Void
        var discard: () -> Void
    }
    private static var pending: Pending?
    private static var installed = false

    /// The user typed into field `id` (called from its text binding, i.e. while handling the key event).
    static func edited(_ id: UUID, commit: @escaping () -> Void, discard: @escaping () -> Void) {
        install()
        if let p = pending, p.id != id { pending = nil; p.commit() }
        let field = pending?.field ?? editingField(NSApp.keyWindow)
        pending = Pending(id: id, field: field, commit: commit, discard: discard)
    }

    /// Re-renders of a field with typed text hand in fresh closures (bindings built in a parent's body go stale).
    static func refresh(_ id: UUID, commit: @escaping () -> Void, discard: @escaping () -> Void) {
        guard pending?.id == id else { return }
        pending?.commit = commit
        pending?.discard = discard
    }

    static func ended(_ id: UUID) { if pending?.id == id { pending = nil } }

    static var hasPending: Bool { pending != nil }

    /// Applies the typed text of the field being edited, if any.
    static func commit() {
        guard let p = pending else { return }
        pending = nil
        p.commit()
    }

    /// Forgets the typed text of the field being edited (its value stays as it was).
    static func discard() {
        guard let p = pending else { return }
        pending = nil
        p.discard()
    }

    static func editingField(_ w: NSWindow?) -> NSTextField? {
        guard let fe = w?.firstResponder as? NSTextView, fe.isFieldEditor else { return nil }
        return fe.delegate as? NSTextField
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSControl.textDidChangeNotification, object: nil, queue: nil) { n in
            if pending != nil, pending?.field == nil { pending?.field = n.object as? NSTextField }
        }
        // Tab, Return, a click into another field, the window resigning the field…
        nc.addObserver(forName: NSControl.textDidEndEditingNotification, object: nil, queue: nil) { n in
            guard let p = pending, p.field == nil || p.field === n.object as? NSTextField else { return }
            commit()
        }
        // …and clicks that don't take keyboard focus (buttons, sliders, the canvas). Runs before the click is dispatched,
        // so the button's action sees the typed value.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { e in
            if let p = pending {
                let f = p.field ?? editingField(e.window)
                let inField = f.map { $0.window === e.window && $0.convert($0.bounds, to: nil).contains(e.locationInWindow) } ?? false
                if !inField { commit() }
            }
            return e
        }
    }
}

/// Label + slider + numeric field.
struct ValueSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var unit: String = ""
    var format: String = "%.0f"
    var labelWidth: CGFloat = 78
    var onCommit: (() -> Void)? = nil

    /// Text typed but not committed yet; nil while the field just shows the value (so a value derived from another
    /// setting, like Auto leading, stays current even while the field has keyboard focus).
    @State private var draft: String?
    /// The text just committed: when editing ends, the text field hands its (not yet reformatted) text back once more.
    @State private var committed: String?
    @State private var fieldID = UUID()
    @FocusState private var focused: Bool

    var body: some View {
        let _ = draft == nil ? () : FieldEdits.refresh(fieldID, commit: commitDraft, discard: { draft = nil })
        HStack(spacing: 6) {
            if !label.isEmpty {
                Text(label).font(Theme.font).foregroundStyle(Theme.textDim).frame(width: labelWidth, alignment: .leading).lineLimit(1)
            }
            Slider(value: Binding(get: { clamp(value, range.lowerBound, range.upperBound) }, set: { v in
                var nv = v
                if let s = step { nv = (v / s).rounded() * s }
                value = nv
            }), in: range, onEditingChanged: { editing in if !editing { onCommit?() } })
            .controlSize(.mini)
            HStack(spacing: 1) {
                TextField("", text: Binding(get: { draft ?? shown }, set: typed))
                    .textFieldStyle(.plain)
                    .font(Theme.mono)
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .onSubmit { commitDraft() }
                if !unit.isEmpty { Text(unit).font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .frame(width: unit.isEmpty ? 46 : 58)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
        }
        .onChange(of: focused) { _, f in if !f { commitDraft() } }
    }

    private var shown: String { String(format: format, value) }

    private func typed(_ s: String) {
        guard draft != nil || (s != shown && s != committed) else { return }
        committed = nil
        draft = s
        FieldEdits.edited(fieldID, commit: commitDraft, discard: { draft = nil })
    }

    /// Applies typed text (only text the user typed: focus merely passing through the field changes nothing).
    private func commitDraft() {
        guard let t = draft else { return }
        draft = nil
        committed = t
        FieldEdits.ended(fieldID)
        if let v = Double(t.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)), v.isFinite {   // "nan" / "inf" parse as Doubles
            value = clamp(v, range.lowerBound, range.upperBound)
            onCommit?()
        }
    }
}

/// Compact numeric field.
struct NumberField: View {
    /// Largest magnitude a field accepts (far beyond any real setting, small enough to convert to Int safely).
    static let limit: Double = 1_000_000_000
    /// Typed text → value. "nan", "inf" and 20-digit numbers all parse as Doubles, and callers convert the value with
    /// Int(…), which traps on them — so non-finite input is rejected and the magnitude bounded.
    static func parse(_ text: String) -> Double? {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)), v.isFinite else { return nil }
        return min(max(v, -limit), limit)
    }
    let label: String
    @Binding var value: Double
    var width: CGFloat = 54
    var format: String = "%.0f"
    var onCommit: (() -> Void)? = nil
    /// Typed, uncommitted text and the text just committed (see `ValueSlider`).
    @State private var draft: String?
    @State private var committed: String?
    @State private var fieldID = UUID()
    @FocusState private var focused: Bool

    var body: some View {
        let _ = draft == nil ? () : FieldEdits.refresh(fieldID, commit: commitDraft, discard: { draft = nil })
        HStack(spacing: 3) {
            if !label.isEmpty { Text(label).font(Theme.font).foregroundStyle(Theme.textDim) }
            TextField("", text: Binding(get: { draft ?? shown }, set: typed))
                .textFieldStyle(.plain)
                .font(Theme.mono)
                .focused($focused)
                .onSubmit { commitDraft() }
                .padding(.horizontal, 4).padding(.vertical, 2)
                .frame(width: width)
                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
        }
        .onChange(of: focused) { _, f in if !f { commitDraft() } }
    }

    private var shown: String { String(format: format, value) }

    private func typed(_ s: String) {
        guard draft != nil || (s != shown && s != committed) else { return }
        committed = nil
        draft = s
        FieldEdits.edited(fieldID, commit: commitDraft, discard: { draft = nil })
    }

    private func commitDraft() {
        guard let t = draft else { return }
        draft = nil
        committed = t
        FieldEdits.ended(fieldID)
        if let v = NumberField.parse(t) { value = v; onCommit?() }
    }
}

struct BlendModePicker: View {
    @Binding var mode: BlendMode
    var includePassThrough = false
    var width: CGFloat? = 120
    var onChange: (() -> Void)? = nil

    var body: some View {
        Menu {
            if includePassThrough {
                Button(BlendMode.passThrough.displayName) { mode = .passThrough; onChange?() }
                Divider()
            }
            ForEach(Array(BlendMode.groups.enumerated()), id: \.offset) { i, g in
                ForEach(g) { m in
                    Button { mode = m; onChange?() } label: {
                        if m == mode { Label(m.displayName, systemImage: "checkmark") } else { Text(m.displayName) }
                    }
                }
                if i < BlendMode.groups.count - 1 { Divider() }
            }
        } label: {
            Text(mode.displayName).font(Theme.font)
        }
        .menuStyle(.borderlessButton)
        .frame(width: width)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
    }
}

struct CheckerBackground: View {
    var size: CGFloat = 5
    var body: some View {
        Canvas { ctx, sz in
            let cols = Int(ceil(sz.width / size)), rows = Int(ceil(sz.height / size))
            ctx.fill(Path(CGRect(origin: .zero, size: sz)), with: .color(.white))
            for r in 0..<rows { for c in 0..<cols where (r + c) % 2 == 0 {
                ctx.fill(Path(CGRect(x: CGFloat(c) * size, y: CGFloat(r) * size, width: size, height: size)), with: .color(Color(white: 0.8)))
            } }
        }
    }
}

struct GradientSwatch: View {
    let gradient: ColorGradient
    var reverse = false
    var body: some View {
        ZStack {
            CheckerBackground(size: 4)
            LinearGradient(stops: (reverse ? gradient.reversed() : gradient).sortedStops.map {
                .init(color: Color(nsColor: $0.color.nsColor), location: $0.location)
            }, startPoint: .leading, endPoint: .trailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(white: 0.4), lineWidth: 0.5))
    }
}

struct AngleDial: View {
    @Binding var angle: Double
    var onCommit: (() -> Void)? = nil
    var body: some View {
        GeometryReader { g in
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let r = min(g.size.width, g.size.height) / 2 - 2
            ZStack {
                Circle().fill(Theme.fieldBG)
                Circle().stroke(Color(white: 0.45), lineWidth: 1)
                Path { p in
                    p.move(to: c)
                    p.addLine(to: CGPoint(x: c.x + cos(angle * .pi / 180) * r, y: c.y - sin(angle * .pi / 180) * r))
                }.stroke(Color.white, lineWidth: 1.5)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let d = CGPoint(x: v.location.x - c.x, y: c.y - v.location.y)
                var a = atan2(d.y, d.x) * 180 / .pi
                if NSEvent.modifierFlags.contains(.shift) { a = (a / 15).rounded() * 15 }
                angle = a.rounded()
            }.onEnded { _ in onCommit?() })
        }
        .frame(width: 30, height: 30)
    }
}

struct SectionHeader: View {
    let title: String
    @Binding var expanded: Bool
    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() } } label: {
            HStack(spacing: 4) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textFaint)
                Text(title).font(Theme.fontBold).foregroundStyle(Theme.text)
                Spacer()
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
