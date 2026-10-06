import SwiftUI
import AppKit
import ImageCratCore

// Preferences ▸ Integrations ("Claude Code / MCP"), the status-bar chip and the module hooks of the local MCP server.

enum MCPModule {
    static func register() {
        FeatureModules.selfTests.append(("mcp", { MCPSelfTest.run($0) }))
        MenuRegistry.add("Help", "Claude Code / MCP Setup…", dividerBefore: true) { openPreferences() }
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MCPServerController.shared.startAtLaunchIfEnabled()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MCPServerController.shared.stop()
        }
    }

    static let preferencesSection = "Integrations"

    static func openPreferences() {
        guard AppModel.shared.dialog == nil || AppModel.shared.dialog == .preferences else { return }
        Workflow2PrefsState.open(preferencesSection)
    }

    /// Puts `s` on the general pasteboard (user actions only: never called by tests).
    static func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

/// Preferences ▸ Integrations.
struct MCPPreferencesSection: View {
    @Bindable var c = MCPServerController.shared
    @State private var shownToken: String?
    @State private var note: String = ""
    @State private var portText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Claude Code / MCP").font(Theme.fontBold)
            Text("Lets Claude Code and other MCP clients on this Mac open, edit and export images in ImageCrat. Only this Mac can connect (127.0.0.1), and every request needs the token below.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $c.settings.enabled) { Text("Enable the local MCP server") }.toggleStyle(.checkbox).font(Theme.font)
            HStack(spacing: 6) {
                Text("Port").foregroundStyle(Theme.textDim).frame(width: 60, alignment: .leading)
                TextField("47800", text: $portText).genField().frame(width: 70).onSubmit(applyPort)
                Text("Another free port is used when this one is taken.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
            HStack(alignment: .top, spacing: 6) {
                Text("Token").foregroundStyle(Theme.textDim).frame(width: 60, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Text(shownToken ?? "••••••••••••••••••••").font(Theme.mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    HStack(spacing: 6) {
                        Button(shownToken == nil ? "Show" : "Hide") {
                            if shownToken != nil { shownToken = nil } else { c.withToken { shownToken = $0 } }
                        }.buttonStyle(PanelButtonStyle())
                        Button("Copy") { c.withToken { MCPModule.copy($0); note = tr("Token copied.") } }.buttonStyle(PanelButtonStyle())
                        Button("Regenerate…") { regenerate() }.buttonStyle(PanelButtonStyle())
                    }
                }
            }
            HStack {
                Button("Copy Claude Code setup command") {
                    c.withToken { MCPModule.copy(c.setupCommand(token: $0)); note = tr("Copied. Paste it in Terminal, then type /mcp in Claude Code to check the connection.") }
                }.buttonStyle(PanelButtonStyle(prominent: true))
                Spacer()
            }
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let _ = c.activity
                HStack(spacing: 6) {
                    Circle().fill(c.running ? Color.green : (c.statusError != nil && c.settings.enabled ? Color.orange : Color.gray.opacity(0.5))).frame(width: 7, height: 7)
                    Text(c.statusLine(clients: c.activeClients())).font(Theme.fontSmall).foregroundStyle(Theme.textDim).lineLimit(2)
                }
            }
            if let f = c.lastWrittenFile {
                Text("Last file written: \(f)").font(Theme.fontSmall).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.middle)
            }
            if !note.isEmpty { Text(note).font(Theme.fontSmall).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true) }
            Divider()
            Toggle(isOn: $c.settings.allowPaidGenerative) { Text("Allow paid generative AI calls from MCP") }.toggleStyle(.checkbox).font(Theme.font)
            Text("Off: tools that would call fal.ai or another paid provider are refused. On: ImageCrat still asks you to confirm the cost of each call.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            if c.settings.allowPaidGenerative {
                Toggle(isOn: $c.settings.skipPaidConfirmation) { Text("Don't ask again for MCP") }.toggleStyle(.checkbox).font(Theme.font).padding(.leading, 18)
            }
            Text("Your generative AI keys are never available to MCP clients. Files the tools write are listed in the status bar and the diagnostic log.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { portText = String(c.settings.port) }
    }

    private func applyPort() {
        guard let p = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(p) else {
            note = tr("The port must be a number from 1024 to 65535.")
            portText = String(c.settings.port)
            return
        }
        c.settings.port = p
        note = ""
    }

    private func regenerate() {
        let ok = AppActions.confirm(tr("Regenerate the MCP token?"),
                                    tr("Clients set up with the current token stop working until you set them up again with the new one."),
                                    ok: tr("Regenerate"))
        guard ok else { return }
        c.regenerateToken()
        if shownToken != nil { c.withToken { shownToken = $0 } }
        note = tr("New token created. Copy the setup command again for your clients.")
    }
}

extension StatusChips {
    static func mcp(port: Int, clients: Int, lastCall: String?) -> StatusChipSpec {
        var help = tr("Claude Code / MCP server is on, listening on 127.0.0.1:\(String(port))")
        help += clients == 1 ? tr(" (1 client).") : tr(" (\(clients) clients).")
        if let l = lastCall { help += " " + tr("Last call: \(l).") }
        help += " " + tr("Click for Preferences ▸ Integrations.")
        return StatusChipSpec(id: "mcp", symbol: "point.3.connected.trianglepath.dotted",
                              full: "MCP · :\(port)", compact: "MCP", tiny: "MCP", help: help)
    }
}

/// Shown while the MCP server runs; click opens Preferences ▸ Integrations.
struct MCPStatusChip: View {
    let tier: StatusBarTier
    @Bindable private var c = MCPServerController.shared

    var body: some View {
        if c.running, let p = c.listeningPort {
            let _ = c.activity
            StatusChip(spec: StatusChips.mcp(port: p, clients: c.activeClients(), lastCall: c.lastCall), tier: tier)
        }
    }
}
