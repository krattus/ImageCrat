import SwiftUI
import AppKit
import Darwin
import ImageCratCore

// Status-bar chips. Every chip carries a short visible label ("AI $0.31 today", "REC 12", "Memory 1.2 GB"), a tooltip
// that says what it is and what a click does, and opens the related panel, dialog or preferences section when clicked.
// Labels shorten in steps as the bar gets narrower; the status message truncates first.

/// How much room the status bar has.
enum StatusBarTier: Equatable {
    case wide, medium, narrow
    init(width: CGFloat) { self = width >= 1100 ? .wide : width >= 760 ? .medium : .narrow }
}

struct StatusChipSpec: Equatable {
    enum Tint: Equatable { case normal, warning, critical, recording }
    var id: String
    var symbol: String?
    /// Labels for a wide / medium / narrow bar.
    var full: String
    var compact: String
    var tiny: String
    /// Tooltip: what the chip shows and what clicking it does.
    var help: String
    var tint: Tint = .normal
    /// Info text (document size, pointer) is drawn without the capsule.
    var capsule = true

    func label(_ tier: StatusBarTier) -> String {
        switch tier {
        case .wide: return full
        case .medium: return compact
        case .narrow: return tiny
        }
    }
}

enum StatusChips {
    // MARK: Specs (pure: tested by the workspace2 self test)

    static func documentInfo(_ d: Document) -> StatusChipSpec {
        let st = d.state
        let res = max(1, st.resolution)
        let inches = String(format: "%.1f × %.1f in", Double(st.width) / res, Double(st.height) / res)
        return StatusChipSpec(id: "doc", symbol: nil,
                              full: "\(st.width) × \(st.height) px · \(Int(st.resolution)) ppi",
                              compact: "\(st.width) × \(st.height) px",
                              tiny: "\(st.width)×\(st.height)",
                              help: "Document size: \(st.width) × \(st.height) pixels at \(Int(st.resolution)) ppi (\(inches), \(tr(st.colorMode.short)) \(st.bitDepth.rawValue)-bit). Click to open Image Size…",
                              capsule: false)
    }

    static func cursor(_ p: CGPoint) -> StatusChipSpec {
        StatusChipSpec(id: "cursor", symbol: nil,
                       full: "X \(Int(p.x))  Y \(Int(p.y)) px", compact: "\(Int(p.x)), \(Int(p.y))", tiny: "\(Int(p.x)), \(Int(p.y))",
                       help: "Pointer position on the canvas, in pixels from the top-left corner of the document (of the active artboard in an artboard document). Click to show the Info panel.",
                       capsule: false)
    }

    static func selection(_ w: Int, _ h: Int) -> StatusChipSpec {
        StatusChipSpec(id: "selection", symbol: nil,
                       full: "Selection \(w) × \(h) px", compact: "Sel \(w) × \(h)", tiny: "\(w)×\(h)",
                       help: "Size of the current selection's bounding box, in pixels. Click to show the Info panel.",
                       capsule: false)
    }

    static func ai(today: Double, month: Double, session: Double, remaining: GenRemaining?, level: GenSpendLevel) -> StatusChipSpec {
        var help = "AI usage: generative AI spend tracked by ImageCrat — today \(GenMoney.string(today)), this month \(GenMoney.string(month)), this session \(GenMoney.string(session))."
        if let r = remaining {
            switch r.kind {
            case .live: help += " \(r.provider?.displayName ?? "Provider") balance \(GenMoney.string(r.amount)) (live\(r.asOf.map { ", " + GenMoney.ago($0) } ?? ""))."
            case .estimated: help += " \(r.provider?.displayName ?? "Provider") estimated remaining \(GenMoney.string(r.amount)) (credit added − tracked spend)."
            case .budget: help += r.amount >= 0 ? " \(GenMoney.string(r.amount)) of the monthly budget left." : " \(GenMoney.string(-r.amount)) over the monthly budget."
            }
        }
        if level == .warning { help += " Running low." } else if level == .critical { help += " Budget or balance used up." }
        help += " Click to open the AI Usage panel."
        return StatusChipSpec(id: "ai", symbol: GenUsageUI.symbol(level),
                              full: GenUsageUI.chipText(today: today, remaining: remaining),
                              compact: "AI \(GenMoney.string(today)) today",
                              tiny: "AI \(GenMoney.string(today))",
                              help: help,
                              tint: level == .critical ? .critical : level == .warning ? .warning : .normal)
    }

    static func timelapse(frames n: Int) -> StatusChipSpec {
        StatusChipSpec(id: "rec", symbol: "circle.fill",
                       full: "Timelapse REC · \(n) frame\(n == 1 ? "" : "s")", compact: "REC \(n)", tiny: "REC",
                       help: "Recording a process timelapse of this document: \(n) frame\(n == 1 ? "" : "s") so far (a frame is stored as you edit). Click to pause, export the timelapse video or delete the frames.",
                       tint: .recording)
    }

    static func autosave(enabled: Bool, minutes: Double, onDeactivate: Bool) -> StatusChipSpec {
        guard enabled else {
            return StatusChipSpec(id: "autosave", symbol: "exclamationmark.arrow.circlepath",
                                  full: "Autosave off", compact: "Autosave off", tiny: "No autosave",
                                  help: "Autosave & recovery is off: unsaved work can't be recovered after a crash. Click to turn it on in Preferences ▸ Workflow.",
                                  tint: .warning)
        }
        let m = max(1, Int(minutes.rounded()))
        return StatusChipSpec(id: "autosave", symbol: "clock.arrow.circlepath",
                              full: "Autosave · \(m) min", compact: "Autosave \(m)m", tiny: "\(m)m",
                              help: "Autosave & recovery: unsaved documents are copied to a recovery folder every \(m) minute\(m == 1 ? "" : "s")\(onDeactivate ? " and when ImageCrat goes to the background" : ""), so they can be recovered after a crash. Click to change this in Preferences ▸ Workflow.")
    }

    static func memory(bytes: UInt64, documents: Int, historyStates: Int) -> StatusChipSpec {
        let s = memoryString(bytes)
        return StatusChipSpec(id: "memory", symbol: "memorychip",
                              full: "Memory \(s)", compact: s, tiny: s,
                              help: "Memory used by ImageCrat: \(s) (\(documents) document\(documents == 1 ? "" : "s") open, \(historyStates) history state\(historyStates == 1 ? "" : "s")). Click for Preferences ▸ Performance.")
    }

    static func memoryString(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb < 1000 ? "\(Int(mb.rounded())) MB" : String(format: "%.1f GB", mb / 1024)
    }

    /// The app's memory footprint (what Activity Monitor shows as Memory).
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    // MARK: Clicks

    /// What clicking chip `id` does. (The REC chip has a menu instead.)
    static func perform(_ id: String) {
        let app = AppModel.shared
        func showPanel(_ p: String) {
            if !app.showPanels { app.showPanels = true }
            WorkspaceManager.shared.reveal(p)
        }
        switch id {
        case "doc":
            guard app.dialog == nil, app.activeDocument != nil else { return }
            PendingEdits.willRunMenuCommand(topLevel: "Image")
            app.dialog = .imageSize
        case "cursor", "selection":
            showPanel("info")
        case "ai":
            GenUsageUI.open()
        case "autosave":
            guard app.dialog == nil else { return }
            Workflow2PrefsState.open("Workflow")
        case "memory":
            guard app.dialog == nil else { return }
            Workflow2PrefsState.open("Performance")
        case "mcp":
            MCPModule.openPreferences()
        default:
            break
        }
    }

    static func timelapseMenu(_ d: Document) -> [(String, () -> Void)] {
        let tl = Timelapse.shared
        return [("Pause Timelapse Recording", { tl.setRecording(d, false) }),
                ("Export Timelapse Video…", { DialogRegistry.show("w2.timelapseExport") }),
                ("Delete Recorded Frames", { tl.deleteFrames(d) })]
    }
}

// MARK: - Views

struct StatusChip: View {
    let spec: StatusChipSpec
    let tier: StatusBarTier
    var menu: [(String, () -> Void)]? = nil
    @State private var hover = false

    private var tintColor: Color? {
        switch spec.tint {
        case .normal: return nil
        case .warning: return GenUsageUI.color(.warning)
        case .critical: return GenUsageUI.color(.critical)
        case .recording: return .red
        }
    }

    var body: some View {
        Group {
            if let menu {
                HStack(spacing: 4) {
                    icon
                    Menu {
                        ForEach(menu.indices, id: \.self) { i in Button(tr(menu[i].0), action: menu[i].1) }
                    } label: {
                        text
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .modifier(ChipBackground(capsule: spec.capsule, tint: tintColor, hover: hover))
            } else {
                Button { StatusChips.perform(spec.id) } label: {
                    HStack(spacing: 4) { icon; text }
                        .modifier(ChipBackground(capsule: spec.capsule, tint: tintColor, hover: hover))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .help(tr(spec.help))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr(spec.full))
        .accessibilityHint(spec.help)
        .accessibilityAddTraits(.isButton)
        .onHover { hover = $0 }
    }

    @ViewBuilder private var icon: some View {
        if let s = spec.symbol {
            Image(systemName: s).font(.system(size: spec.tint == .recording ? 7 : 9))
                .foregroundStyle(tintColor ?? Theme.accent)
        }
    }

    private var text: some View {
        Text(tr(spec.label(tier)))
            .font(spec.capsule ? Theme.fontSmall : Theme.font).monospacedDigit()
            .foregroundStyle(spec.tint == .warning || spec.tint == .critical ? (tintColor ?? Theme.text) : (spec.capsule ? Theme.text : Theme.textDim))
            .lineLimit(1).truncationMode(.tail)
    }
}

private struct ChipBackground: ViewModifier {
    let capsule: Bool
    let tint: Color?
    let hover: Bool
    func body(content: Content) -> some View {
        if capsule {
            content
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(tint.map { $0.opacity(0.15) } ?? Color.white.opacity(hover ? 0.11 : 0.06)))
                .overlay(Capsule().stroke(tint.map { $0.opacity(0.65) } ?? Theme.border, lineWidth: 0.5))
        } else {
            content
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(hover ? Theme.hover : .clear))
        }
    }
}

/// Fixed values for snapshot tests (no keychain, no recording on disk).
struct StatusBarPreview {
    var aiKeyed: [ProviderID]? = nil
    var recordingFrames: Int? = nil
    var memoryBytes: UInt64? = nil
}

/// The chips at the right end of the status bar.
struct StatusBarChips: View {
    let tier: StatusBarTier
    var preview: StatusBarPreview? = nil
    @Bindable private var app = AppModel.shared
    @Bindable private var tl = Timelapse.shared
    @Bindable private var w2 = Workflow2Settings.shared

    var body: some View {
        HStack(spacing: tier == .narrow ? 6 : 8) {
            if let d = app.activeDocument {
                if tier == .wide || !w2.prefs.autosaveEnabled, tier != .narrow {
                    StatusChip(spec: StatusChips.autosave(enabled: w2.prefs.autosaveEnabled, minutes: w2.prefs.autosaveMinutes, onDeactivate: w2.prefs.autosaveOnDeactivate), tier: tier)
                }
                if let n = preview?.recordingFrames ?? (tl.recording.contains(d.id) ? tl.frameCounts[d.id] ?? 0 : nil) {
                    StatusChip(spec: StatusChips.timelapse(frames: n), tier: tier, menu: StatusChips.timelapseMenu(d)).layoutPriority(2)
                }
            }
            MCPStatusChip(tier: tier)   // only while the Claude Code / MCP server runs
            if tier != .narrow { MemoryStatusChip(tier: tier, bytesOverride: preview?.memoryBytes) }
            AIUsageStatusChip(tier: tier, keyedOverride: preview?.aiKeyed).layoutPriority(2)
        }
    }
}

struct MemoryStatusChip: View {
    let tier: StatusBarTier
    var bytesOverride: UInt64? = nil
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let docs = AppModel.shared.documents
            StatusChip(spec: StatusChips.memory(bytes: bytesOverride ?? StatusChips.footprint(), documents: docs.count,
                                                historyStates: docs.reduce(0) { $0 + $1.history.count }), tier: tier)
        }
    }
}

/// AI spend and remaining balance (only when a provider key exists). Click opens the AI Usage panel.
struct AIUsageStatusChip: View {
    let tier: StatusBarTier
    var keyedOverride: [ProviderID]? = nil
    @Bindable private var store = GenUsageStore.shared
    @Bindable private var settings = GenAISettings.shared

    var body: some View {
        let _ = settings.keysRevision
        let keyed = keyedOverride ?? GenAIKeychain.shared.keyedProviders
        if !keyed.isEmpty {
            let remaining = store.overallRemaining(keyed: keyed, budget: settings.data.monthlyBudget)
            let level = store.level(keyed: keyed, settings: settings.data)
            StatusChip(spec: StatusChips.ai(today: store.today().cost, month: store.month().cost, session: store.session.cost, remaining: remaining, level: level), tier: tier)
                .onAppear { if keyedOverride == nil { GenBalanceService.shared.panelAppeared() } }
                .onChange(of: settings.keysRevision) { _, _ in GenBalanceService.shared.keysChanged() }
        }
    }
}
