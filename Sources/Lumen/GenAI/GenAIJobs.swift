import SwiftUI
import AppKit
import Observation
import ImageCratCore

struct GenHistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var feature: String
    var prompt: String
    var provider: String
    var model: String
    var cost: Double
    var seconds: Double
    var images: Int
    var status: String          // "ok", "cancelled", or an error message
}

/// Tracks running generative jobs (non-blocking HUD with cancel) and the Generative History list.
@Observable
final class GenJobs {
    static let shared = GenJobs()

    struct Job: Identifiable {
        let id = UUID()
        var title: String
        var detail: String = ""
        var fraction: Double? = nil
        var started = Date()
        var task: Task<Void, Never>? = nil
        /// "≈ $0.15 for 3 variations with fal.ai FLUX.1 Pro Fill" (set when the first provider call starts).
        var estimate: String = ""
    }

    /// The job the current task belongs to (lets the pipeline annotate its own HUD row).
    @TaskLocal static var currentJob: UUID?

    func setEstimate(_ text: String) {
        lastEstimate = text
        guard let id = GenJobs.currentJob, let i = active.firstIndex(where: { $0.id == id }) else { return }
        active[i].estimate = text
        GenHUD.shared.refresh()     // the row grew by a line
    }
    /// Estimate text of the most recent generation (tests read it).
    @ObservationIgnored var lastEstimate: String?

    var active: [Job] = []
    var history: [GenHistoryEntry] = []
    /// Last error (tests read it; UI shows an alert).
    var lastError: String?
    @ObservationIgnored var headless = false
    @ObservationIgnored var persist = true
    private static let historyKey = "Lumen.GenAI.History"

    private init() {
        if let d = UserDefaults.standard.data(forKey: GenJobs.historyKey), let h = try? JSONDecoder().decode([GenHistoryEntry].self, from: d) { history = h }
    }

    func record(_ e: GenHistoryEntry) {
        history.insert(e, at: 0)
        if history.count > 300 { history.removeLast(history.count - 300) }
        if persist, let d = try? JSONEncoder().encode(history) { UserDefaults.standard.set(d, forKey: GenJobs.historyKey) }
    }

    func clearHistory() {
        history.removeAll()
        if persist { UserDefaults.standard.removeObject(forKey: GenJobs.historyKey) }
    }

    /// Runs `work` as a cancellable job on the main actor (network awaits don't block the UI).
    @discardableResult
    func start(_ title: String, _ work: @escaping @MainActor (_ update: @escaping (GenProgress) -> Void) async throws -> Void) -> UUID {
        var job = Job(title: title, detail: "Starting…")
        let id = job.id
        let task = Task { @MainActor [weak self] in
            do {
                try await GenJobs.$currentJob.withValue(id) {
                    try await work { p in
                        Task { @MainActor in self?.update(id, p) }
                    }
                }
            } catch {
                let ge = (error as? GenError) ?? ((error is CancellationError) ? .cancelled : .network(error.localizedDescription))
                if ge != .cancelled { self?.report(ge, title: title) }
            }
            self?.finish(id)
        }
        job.task = task
        active.append(job)
        GenHUD.shared.refresh()
        return id
    }

    func update(_ id: UUID, _ p: GenProgress) {
        guard let i = active.firstIndex(where: { $0.id == id }) else { return }
        active[i].detail = p.message
        active[i].fraction = p.fraction
    }

    func cancel(_ id: UUID) {
        guard let i = active.firstIndex(where: { $0.id == id }) else { return }
        active[i].detail = "Cancelling…"
        active[i].task?.cancel()
    }

    func cancelAll() { for j in active { j.task?.cancel() } }

    private func finish(_ id: UUID) {
        active.removeAll { $0.id == id }
        GenHUD.shared.refresh()
    }

    func report(_ e: GenError, title: String) {
        let msg = e.errorDescription ?? "\(e)"
        lastError = msg
        AppModel.shared.setStatus("\(title): \(msg)")
        if headless { print("genai error [\(title)]: \(msg)"); return }
        let a = NSAlert()
        a.messageText = tr("\(title) failed")
        a.informativeText = tr(msg)
        if case .missingKey = e { a.addButton(withTitle: tr("Open Preferences")); a.addButton(withTitle: tr("Cancel")) }
        else if case .noProvider = e { a.addButton(withTitle: tr("Open Preferences")); a.addButton(withTitle: tr("Cancel")) }
        if let w = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
            UIBlock.beginSheet(a, for: w) { r in if r == .alertFirstButtonReturn, a.buttons.count > 1 { GenAIActions.openPreferences() } }
        } else if UIBlock.run(a) == .alertFirstButtonReturn, a.buttons.count > 1 {
            GenAIActions.openPreferences()
        }
    }
}

// MARK: - HUD

/// Floating, non-blocking progress HUD pinned to the bottom of the main window.
final class GenHUD {
    static let shared = GenHUD()
    private var panel: NSPanel?

    func refresh() {
        if GenJobs.shared.headless { return }
        if GenJobs.shared.active.isEmpty { panel?.orderOut(nil); return }
        guard let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else { return }
        let size = CGSize(width: 380, height: GenJobs.shared.active.reduce(12) { $0 + ($1.estimate.isEmpty ? 46 : 60) })
        if panel == nil {
            let p = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.hidesOnDeactivate = true
            p.contentView = NSHostingView(rootView: GenHUDView().l10nRoot())
            panel = p
        }
        guard let p = panel else { return }
        let f = main.frame
        p.setFrame(CGRect(x: f.midX - size.width / 2, y: f.minY + 40, width: size.width, height: size.height), display: true)
        if p.parent == nil { main.addChildWindow(p, ordered: .above) }
        p.orderFront(nil)
    }
}

struct GenHUDView: View {
    @Bindable var jobs = GenJobs.shared
    var body: some View {
        VStack(spacing: 6) {
            ForEach(jobs.active) { j in
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tr(j.title)).font(Theme.fontBold).foregroundStyle(Theme.text).lineLimit(1)
                        if let f = j.fraction { ProgressView(value: f).progressViewStyle(.linear).controlSize(.small) }
                        else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
                        Text(tr(j.detail)).font(Theme.fontSmall).foregroundStyle(Theme.textDim).lineLimit(1)
                        if !j.estimate.isEmpty { Text(tr(j.estimate)).font(Theme.fontSmall).foregroundStyle(Theme.textFaint).lineLimit(1) }
                    }
                    Button { jobs.cancel(j.id) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 14)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.textDim).help("Cancel")
                }
                .padding(.horizontal, 10).frame(height: j.estimate.isEmpty ? 40 : 54)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelBG.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }
}

// MARK: - History panel

struct GenHistoryPanel: View {
    @Bindable var jobs = GenJobs.shared
    @Bindable var settings = GenAISettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("This month ≈ \(GenMoney.string(GenUsageStore.shared.month().cost))").font(Theme.fontBold)
                Button("AI Usage…") { GenUsageUI.open() }.buttonStyle(.link).font(Theme.fontSmall)
                Spacer()
                Button("Clear") { jobs.clearHistory() }.buttonStyle(PanelButtonStyle()).disabled(jobs.history.isEmpty)
            }
            if !jobs.active.isEmpty {
                ForEach(jobs.active) { j in
                    HStack {
                        ProgressView().controlSize(.mini)
                        Text(tr(j.title)).lineLimit(1)
                        Spacer()
                        Button("Cancel") { jobs.cancel(j.id) }.buttonStyle(PanelButtonStyle())
                    }
                }
                Divider()
            }
            if jobs.history.isEmpty {
                Text("Generative jobs appear here (prompt, provider, cost, time).").foregroundStyle(Theme.textFaint)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(jobs.history) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(tr(GenFeature(rawValue: e.feature)?.displayName ?? e.feature)).font(Theme.fontBold)
                                Spacer()
                                Text(e.date, style: .time).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                            }
                            if !e.prompt.isEmpty { Text("“\(e.prompt)”").lineLimit(2).foregroundStyle(Theme.text) }
                            HStack {
                                Text("\(ProviderID(rawValue: e.provider)?.displayName ?? e.provider) · \(e.model)").lineLimit(1)
                                Spacer()
                                Text(tr(String(format: "$%.3f · %.1fs", e.cost, e.seconds))).font(Theme.mono)
                            }.font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                            if e.status != "ok" { Text(tr(e.status)).font(Theme.fontSmall).foregroundStyle(.orange).lineLimit(2) }
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
                    }
                }
            }
        }
        .padding(10)
        .font(Theme.font)
        .foregroundStyle(Theme.text)
    }
}
