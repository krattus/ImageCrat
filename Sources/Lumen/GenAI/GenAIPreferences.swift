import SwiftUI
import AppKit
import ImageCratCore

enum GenAIPrefsState {
    /// Set before opening Preferences to land on the Generative AI section.
    static var openGenAISection = false
    /// Initial Preferences section (consumes the flag).
    static func initialSection() -> String {
        defer { openGenAISection = false }
        return openGenAISection ? "Generative AI" : "General"
    }
}

/// Preferences ▸ Generative AI.
struct GenAIPreferencesSection: View {
    @Bindable var s = GenAISettings.shared
    @State var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $tab) { Text("Keys").tag(0); Text("Routing").tag(1); Text("Privacy & Cost").tag(2) }
                .pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch tab {
                    case 0:
                        ForEach(ProviderID.allCases) { p in
                            ProviderKeyRow(provider: p)
                            if p == .fal { FalAdminKeyRow() }
                        }
                    case 1: routing
                    default: privacy
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
            }
            .frame(height: 380)
        }
    }

    @ViewBuilder var routing: some View {
        let _ = s.keysRevision
        Text("Only providers with a stored key are offered. “Automatic” uses the first keyed provider in the default order.")
            .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        ForEach(GenFeature.allCases) { f in
            let avail = ProviderRouter.shared.available(for: f)
            let auto = (try? ProviderRouter.shared.resolve(f))?.1
            VStack(alignment: .leading, spacing: 2) {
                Text(f.displayName).font(Theme.fontBold)
                Picker("", selection: Binding(get: { s.data.routing[f.rawValue] ?? "" }, set: { s.data.routing[f.rawValue] = $0.isEmpty ? nil : $0 })) {
                    Text("Automatic" + (auto.map { " (\($0.provider.displayName): \($0.name))" } ?? " — no keyed provider")).tag("")
                    ForEach(avail) { m in Text("\(m.provider.displayName): \(m.name)").tag(m.id) }
                }
                .labelsHidden()
            }
        }
    }

    @ViewBuilder var privacy: some View {
        Toggle2(label: "fal.ai: don't store inputs/outputs (X-Fal-Store-IO: 0)", on: $s.data.falDontStoreIO)
        Toggle2(label: "Ask before uploading images (once per provider per session)", on: $s.data.confirmUploads)
        Toggle2(label: "Replicate: wait synchronously (Prefer: wait)", on: $s.data.replicatePreferWait)
        Text("Only the selection area plus ~25% context is uploaded, flattened, without metadata. Replicate uploads are deleted after each job.")
            .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        Divider()
        Picker("Output", selection: $s.data.quality) { ForEach(OutputQuality.allCases) { Text($0.rawValue).tag($0) } }
        ValueSlider(label: "Variations", value: Binding(get: { Double(s.data.variations) }, set: { s.data.variations = Int($0) }), range: 1...4, step: 1, labelWidth: 90)
        Divider()
        GenBudgetPreferences()
    }
}

struct ProviderKeyRow: View {
    let provider: ProviderID
    @Bindable var s = GenAISettings.shared
    @State private var entry = ""
    @State private var reveal = false
    @State private var status = ""
    @State private var testing = false

    var body: some View {
        let _ = s.keysRevision
        let has = GenAIKeychain.shared.hasKey(provider)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(has ? Color.green : Color.gray.opacity(0.5)).frame(width: 7, height: 7)
                Text(provider.displayName).font(Theme.fontBold)
                Spacer()
                if let u = URL(string: provider.keyURL) { Link("Get a key", destination: u).font(Theme.fontSmall) }
            }
            HStack(spacing: 4) {
                Group {
                    if reveal { TextField(has ? "•••••• stored in Keychain — paste to replace" : "Paste API key", text: $entry) }
                    else { SecureField(has ? "•••••• stored in Keychain — paste to replace" : "Paste API key", text: $entry) }
                }
                .genField().font(Theme.mono)
                Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }.buttonStyle(.plain).help(reveal ? "Hide" : "Show")
            }
            HStack {
                Button("Save") { save() }.buttonStyle(PanelButtonStyle()).disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(testing ? "Testing…" : "Test key") { test() }.buttonStyle(PanelButtonStyle()).disabled(testing || (!has && entry.isEmpty))
                if has { Button("Remove") { GenAIKeychain.shared.delete(provider.rawValue); s.keysRevision += 1; status = "Key removed." }.buttonStyle(PanelButtonStyle()) }
            }
            if !status.isEmpty { Text(status).font(Theme.fontSmall).foregroundStyle(status.hasPrefix("Key OK") || status.hasPrefix("Saved") ? .green : .orange).lineLimit(3) }
            Text(provider.privacyNote).font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.fieldBG.opacity(0.6)))
    }

    func save() {
        let st = GenAIKeychain.shared.set(entry, for: provider.rawValue)
        status = st == errSecSuccess ? "Saved to Keychain." : "Keychain error \(st)."
        entry = ""
        reveal = false
        s.keysRevision += 1
    }

    func test() {
        let typed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = ProviderRouter.shared.providers[provider] else { return }
        testing = true
        status = ""
        Task { @MainActor in
            // the stored key is read off the main thread (it may wait for a Keychain access prompt)
            guard let key = typed.isEmpty ? await GenAIKeychain.shared.loadKey(provider) : typed else { testing = false; return }
            do { status = try await p.testKey(key) }
            catch { status = (error as? GenError)?.errorDescription ?? error.localizedDescription }
            testing = false
        }
    }
}

/// Self-test helper: the section opened on a given tab.
struct GenAIPreferencesSectionSnapshot: View {
    var tab: Int
    var body: some View { GenAIPreferencesSection(tab: tab).frame(width: 340) }
}
