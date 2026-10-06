import SwiftUI

/// Type ▸ Match Font… dialog: crop preview, recognized text, top 10 installed fonts with previews.
struct MatchFontDialog: View {
    @State private var session: MatchFontSession
    @State private var loaded: Bool

    /// `preloaded`: an already analysed session (self tests).
    init(preloaded: MatchFontSession? = nil) {
        _session = State(initialValue: preloaded ?? MatchFontSession())
        _loaded = State(initialValue: preloaded != nil)
    }

    var body: some View {
        DialogFrame(title: "Match Font", width: 460, okTitle: "Use Font", onOK: {
            if let f = session.selected { session.apply(fontName: f) }
        }, extraButtons: AnyView(
            Button("Select Text Area…") {
                // Photoshop's crop box: drag a rectangle around the text, then reopen Match Font.
                AppModel.shared.dialog = nil
                AppModel.shared.tool = .marqueeRect
                AppModel.shared.setStatus("Drag a rectangle around the text, then choose Type ▸ Match Font… again.")
            }.buttonStyle(PanelButtonStyle())
        )) {
            if let c = session.crop {
                Image(nsImage: NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height)))
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 428, maxHeight: 90)
                    .background(Color.white.opacity(0.9))
                    .border(Theme.border)
            }
            HStack {
                Text("Text").foregroundStyle(Theme.textDim)
                TextField("Recognized text", text: $session.text).textFieldStyle(.roundedBorder).controlSize(.small)
                    .onSubmit { session.run() }
                Button("Match") { session.run() }.buttonStyle(PanelButtonStyle()).disabled(session.running || session.text.isEmpty)
            }
            if !session.message.isEmpty { Text(tr(session.message)).font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
            if session.running {
                ProgressView(value: session.progress).controlSize(.small)
                Text("Comparing installed fonts…").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(session.results.enumerated()), id: \.element.id) { i, c in
                        HStack(spacing: 8) {
                            Text("\(i + 1)").font(Theme.mono).foregroundStyle(Theme.textFaint).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Image(nsImage: MatchFontEngine.preview(session.text, fontName: c.fontName, height: 30, color: NSColor(Theme.text)))
                                    .frame(maxWidth: 380, alignment: .leading).clipped()
                                Text("\(c.family) \(c.style)").font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                            }
                            Spacer()
                        }
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(session.selected == c.fontName ? Theme.selection : Color.clear))
                        .contentShape(Rectangle())
                        .onTapGesture { session.selected = c.fontName }
                        .onTapGesture(count: 2) { session.apply(fontName: c.fontName); AppModel.shared.dialog = nil }
                    }
                }
            }
            .frame(height: 300)
            Text(tr(TypeEdit.activeTextLayer != nil ? "The font is applied to the selected type layer." : "A new type layer is created over the text."))
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
        .onAppear {
            guard !loaded, let d = AppActions.doc else { return }
            loaded = true
            session.load(from: d)
            session.run()
        }
    }
}
