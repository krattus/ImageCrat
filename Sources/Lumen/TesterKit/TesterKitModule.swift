import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageCratCore

/// Things a tester on another Mac needs: Help ▸ Report a Bug…, Help ▸ Open Crash Reports Folder, the diagnostic log,
/// and (in Preferences ▸ AI Models) models packs. Self test: `LUMEN_SELFTEST_ONLY=testerkit Lumen --selftest <dir>`.
enum TesterKitModule {
    static let bugReportDialog = "testerkit.bugReport"

    static func register() {
        DialogRegistry.register(bugReportDialog) { AnyView(BugReportDialog()) }
        MenuRegistry.add("Help", "Report a Bug…", dividerBefore: true, enabled: { AppModel.shared.dialog == nil }) { openBugReport() }
        MenuRegistry.add("Help", "Open Crash Reports Folder") { openCrashReportsFolder() }
        FeatureModules.selfTests.append(("testerkit", { TesterKitSelfTest.run($0) }))
        DiagLog.shared.info("\(Brand.name) \(AppInfo.version) (\(AppInfo.build)) on macOS \(AppInfo.macOS.replacingOccurrences(of: "Version ", with: "")), \(AppInfo.modelIdentifier)")
    }

    /// Takes the window snapshot first (the dialog would otherwise be in it), then shows the dialog.
    static func openBugReport() {
        BugReportModel.shared.prepare(windowPNG: BugReportSources.captureWindowPNG(), document: AppActions.doc)
        DialogRegistry.show(bugReportDialog)
    }

    /// Reveals the newest ImageCrat crash report, or opens the folder (~/Library/Logs/DiagnosticReports).
    static func openCrashReportsFolder() {
        let folder = BugReport.defaultCrashFolder
        if let newest = BugReport.crashReports(in: folder, limit: 1).first {
            NSWorkspace.shared.activateFileViewerSelecting([newest])
        } else if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.open(folder)
            AppModel.shared.setStatus("No ImageCrat crash reports — that folder holds every app's reports.")
        } else {
            NSWorkspace.shared.open(folder.deletingLastPathComponent())
        }
    }
}

/// State of the Report a Bug dialog (kept while Lumen runs, so closing it by mistake doesn't lose the text).
@Observable
final class BugReportModel {
    static let shared = BugReportModel()
    var text = BugReportText()
    var options = BugReportOptions()
    var busy = false
    var message = ""
    @ObservationIgnored var sources = BugReportSources()
    /// Self tests use a private pasteboard.
    @ObservationIgnored var pasteboard: NSPasteboard = .general
    @ObservationIgnored private var sent = false

    func prepare(windowPNG: Data?, document: Document?) {
        if sent { text = BugReportText(); sent = false }
        sources = .live(windowPNG: windowPNG, document: document)
        if document == nil { options.document = false }
        message = ""
    }

    var crashCount: Int { BugReport.crashReports(in: sources.crashFolder, limit: sources.crashLimit).count }
    var logCount: Int { sources.logLines().count }
    var historyCount: Int { sources.historyNames().count }

    func copySummary() {
        pasteboard.clearContents()
        pasteboard.setString(BugReport.summaryText(text, options, sources), forType: .string)
        message = "Summary copied."
    }

    func save() {
        let p = NSSavePanel()
        p.title = "Save Bug Report"
        p.nameFieldStringValue = BugReport.defaultFileName()
        p.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        p.allowedContentTypes = [.zip]
        p.canCreateDirectories = true
        guard p.runModal() == .OK, let url = p.url else { return }
        write(to: url) { [weak self] ok in
            guard ok else { return }
            self?.sent = true
            AppModel.shared.dialog = nil
            AppModel.shared.setStatus("Bug report saved: \(url.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func email() {
        if GenAIKeyOverrides.realKeysBlocked { message = "Email is not opened in automated runs."; return }   // nothing may leave the process
        guard let service = NSSharingService(named: .composeEmail) else {
            message = "No email app is set up on this Mac — use Save Report… and attach the file yourself."
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImageCrat Bug Report \(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(BugReport.defaultFileName())
        write(to: url) { [weak self] ok in
            guard let self, ok else { return }
            let first = self.text.what.split(separator: "\n").first.map(String.init) ?? ""
            service.subject = "ImageCrat bug report" + (first.isEmpty ? "" : ": " + String(first.prefix(60)))
            service.recipients = []   // the tester chooses who gets it
            service.perform(withItems: [BugReport.summaryText(self.text, self.options, self.sources), url])
            self.sent = true
            self.message = "Opened a new email with the report attached."
        }
    }

    /// Writes the zip off the main thread (a large document can take a moment).
    func write(to url: URL, _ done: @escaping (Bool) -> Void) {
        busy = true; message = "Writing the report…"
        let text = self.text, options = self.options, sources = self.sources
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try BugReport.writeZip(text, options, sources, to: url) }
            DispatchQueue.main.async {
                self.busy = false
                switch r {
                case .success: self.message = ""; done(true)
                case .failure(let e): self.message = "Couldn't write the report: \(e.localizedDescription)"; done(false)
                }
            }
        }
    }
}

struct BugReportDialog: View {
    @Bindable var m = BugReportModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Report a Bug").font(.system(size: 13, weight: .semibold))
            field("What happened?", $m.text.what, placeholder: "Describe the problem", height: 56)
            field("Steps to reproduce", $m.text.steps, placeholder: "1. Open a photo\n2. …", height: 56)
            field("What did you expect?", $m.text.expected, placeholder: "What should have happened", height: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text("Attach").font(Theme.fontBold)
                option($m.options.systemInfo, "System info",
                       "ImageCrat \(AppInfo.version) (\(AppInfo.build)), macOS, Mac model, chip, memory, displays, AI models, which providers have a key (yes / no)")
                option($m.options.crashReports, "ImageCrat's crash reports", m.crashCount == 0 ? "none found" : "\(m.crashCount) recent (ImageCrat's only)")
                option($m.options.log, "Recent log lines", "\(m.logCount) status messages, warnings and errors")
                option($m.options.history, "Recent actions", m.historyCount == 0 ? "no document open" : "\(m.historyCount) history step names (names only)")
                option($m.options.screenshot, "Screenshot of the ImageCrat window",
                       m.sources.windowPNG == nil ? "not available" : (m.sources.saveCanvas != nil ? "taken when you chose Report a Bug; the canvas is added as its own image (window snapshots can't see the Metal canvas)" : "taken when you chose Report a Bug"))
                    .disabled(m.sources.windowPNG == nil)
                if let name = m.sources.documentName {
                    option($m.options.document, "Current document", "“\(name)”, about \(ModelPack.bytes(m.sources.documentBytes)) — shares your image")
                    if m.options.document {
                        Label("This sends the image itself. Only include it if you're happy to share it.", systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.fontSmall).foregroundStyle(.orange)
                    }
                } else {
                    option(.constant(false), "Current document", "no document open").disabled(true)
                }
            }
            Label("Only what's ticked goes into the report. Nothing is sent anywhere automatically — you choose where it goes. API keys and prompts are never included.",
                  systemImage: "lock.fill")
                .font(Theme.fontSmall).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            if !m.message.isEmpty { Text(m.message).font(Theme.fontSmall).foregroundStyle(Theme.textDim) }
            HStack {
                Button("Copy Summary") { m.copySummary() }.buttonStyle(PanelButtonStyle())
                Button("Email…") { m.email() }.buttonStyle(PanelButtonStyle()).disabled(m.busy)
                Spacer()
                if m.busy { ProgressView().controlSize(.small) }
                Button("Cancel") { AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save Report…") { m.save() }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(m.busy)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(width: 500)
    }

    func field(_ title: String, _ text: Binding<String>, placeholder: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(Theme.textDim)
            ZStack(alignment: .topLeading) {
                TextEditor(text: text).font(Theme.font).scrollContentBackground(.hidden).padding(2)
                if text.wrappedValue.isEmpty {
                    Text(placeholder).font(Theme.font).foregroundStyle(Theme.textFaint).padding(.horizontal, 7).padding(.vertical, 2).allowsHitTesting(false)
                }
            }
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 0.5))
        }
    }

    func option(_ on: Binding<Bool>, _ title: String, _ detail: String) -> some View {
        Toggle(isOn: on) {
            (Text(title) + Text(" — " + detail).foregroundStyle(Theme.textFaint)).font(Theme.font).fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
    }
}
