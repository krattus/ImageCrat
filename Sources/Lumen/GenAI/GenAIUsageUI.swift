import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageCratCore

// MARK: - Helpers

enum GenUsageUI {
    static let panelID = "genUsage"

    /// Opens (or brings forward) the AI Usage panel.
    static func open() {
        if !AppModel.shared.showPanels { AppModel.shared.showPanels = true }
        WorkspaceManager.shared.reveal(panelID)
    }

    /// "AI $0.42 today · $18.30 left" — left = live balance, else estimated remaining, else budget remaining.
    static func chipText(today: Double, remaining: GenRemaining?) -> String {
        var s = "AI \(GenMoney.string(today)) today"
        if let r = remaining {
            switch r.kind {
            case .live: s += " · \(GenMoney.string(r.amount)) left"
            case .estimated: s += " · ≈\(GenMoney.string(r.amount)) left"
            case .budget: s += r.amount >= 0 ? " · \(GenMoney.string(r.amount)) budget left" : " · \(GenMoney.string(-r.amount)) over budget"
            }
        }
        return s
    }

    static func color(_ l: GenSpendLevel) -> Color {
        switch l {
        case .normal: return Theme.textDim
        case .warning: return Color(red: 0.98, green: 0.70, blue: 0.16)
        case .critical: return Color(red: 0.96, green: 0.36, blue: 0.33)
        }
    }

    static func symbol(_ l: GenSpendLevel) -> String {
        switch l {
        case .normal: return "sparkles"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    static func featureName(_ raw: String) -> String {
        if raw == "earlier" { return "Earlier usage (carried over)" }
        return GenFeature(rawValue: raw)?.displayName ?? (raw.isEmpty ? "Other" : raw)
    }

    /// "fal.ai · FLUX.1 Pro Fill" for "fal:fal-ai/flux-pro/v1/fill".
    static func modelName(_ key: String) -> String {
        if key == "-:-" { return "—" }
        if let m = ProviderRouter.shared.model(key) { return "\(shortName(m.provider)) · \(m.name)" }
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return key }
        return "\(ProviderID(rawValue: parts[0]).map(shortName) ?? parts[0]) · \(parts[1])"
    }

    /// Compact provider names for narrow table rows.
    static func shortName(_ p: ProviderID) -> String {
        switch p {
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .stability: return "Stability"
        case .fal: return "fal"
        case .replicate: return "Replicate"
        case .bfl: return "BFL"
        }
    }

    static func exportCSV() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.commaSeparatedText]
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        p.nameFieldStringValue = "imagecrat-ai-usage-\(df.string(from: Date())).csv"
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try GenUsageStore.shared.csv().write(to: u, atomically: true, encoding: .utf8) }
        catch { AppActions.alert("Could not export the usage log.", error.localizedDescription) }
    }

    static func resetMonth() {
        guard AppActions.confirm("Reset this month's AI usage?", "Removes this month's records from the local usage log. Provider billing is not affected.", ok: "Reset") else { return }
        GenUsageStore.shared.resetMonth()
        GenAISettings.shared.data.spend[GenAISettings.monthKey()] = 0
    }

    static func clearAll() {
        guard AppActions.confirm("Clear all AI usage data?", "Deletes the whole local usage log. Provider billing is not affected.", ok: "Clear") else { return }
        GenUsageStore.shared.clearAll()
        GenAISettings.shared.data.spend = [:]
    }
}

// MARK: - Status bar chip

/// "AI $0.42 today · $18.30 left" in the status bar (only when a provider key exists). Click opens the usage panel.
struct GenUsageChip: View {
    @Bindable private var store = GenUsageStore.shared
    @Bindable private var settings = GenAISettings.shared
    /// Snapshot tests pass the keyed providers explicitly.
    var keyedOverride: [ProviderID]? = nil

    var body: some View {
        let _ = settings.keysRevision
        let keyed = keyedOverride ?? GenAIKeychain.shared.keyedProviders
        if !keyed.isEmpty {
            let remaining = store.overallRemaining(keyed: keyed, budget: settings.data.monthlyBudget)
            let level = store.level(keyed: keyed, settings: settings.data)
            Button { GenUsageUI.open() } label: {
                HStack(spacing: 4) {
                    Image(systemName: GenUsageUI.symbol(level)).font(.system(size: 9))
                        .foregroundStyle(level == .normal ? Theme.accent : GenUsageUI.color(level))
                    Text(GenUsageUI.chipText(today: store.today().cost, remaining: remaining)).font(Theme.fontSmall).monospacedDigit()
                        .foregroundStyle(level == .normal ? Theme.text : GenUsageUI.color(level))
                }
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(level == .normal ? Color.white.opacity(0.06) : GenUsageUI.color(level).opacity(0.16)))
                .overlay(Capsule().stroke(level == .normal ? Theme.border : GenUsageUI.color(level).opacity(0.7), lineWidth: 0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tooltip(remaining, level))
            .onAppear { GenBalanceService.shared.panelAppeared() }
            .onChange(of: settings.keysRevision) { _, _ in GenBalanceService.shared.keysChanged() }
        }
    }

    private func tooltip(_ r: GenRemaining?, _ level: GenSpendLevel) -> String {
        var s = "Generative AI spend — this month \(GenMoney.string(store.month().cost)), this session \(GenMoney.string(store.session.cost))."
        if let r {
            switch r.kind {
            case .live: s += " \(r.provider?.displayName ?? "Provider") balance \(GenMoney.string(r.amount)) (live\(r.asOf.map { ", " + GenMoney.ago($0) } ?? ""))."
            case .estimated: s += " \(r.provider?.displayName ?? "Provider") estimated remaining \(GenMoney.string(r.amount)) (credit added − tracked spend)."
            case .budget: s += " \(GenMoney.string(r.amount)) of the monthly budget left."
            }
        }
        if level == .warning { s += " Running low." } else if level == .critical { s += " Budget or balance used up." }
        return s + " Click for AI Usage."
    }
}

// MARK: - Panel

struct GenUsagePanel: View {
    @Bindable private var store = GenUsageStore.shared
    @Bindable private var settings = GenAISettings.shared
    @Bindable private var service = GenBalanceService.shared
    @State private var period = 1
    var keyedOverride: [ProviderID]? = nil

    private var keyed: [ProviderID] { keyedOverride ?? GenAIKeychain.shared.keyedProviders }

    private var periodStart: Date? {
        switch period {
        case 0: return store.dayStart(Date())
        case 1: return store.monthStart(Date())
        case 2: return store.calendar.date(byAdding: .day, value: -29, to: store.dayStart(Date()))
        default: return nil
        }
    }

    var body: some View {
        let _ = settings.keysRevision
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                GenUsageTiles(store: store)
                GenBudgetBar(store: store, settings: settings)
                if keyed.isEmpty {
                    WrappingHStack(spacing: 4, lineSpacing: 2) {
                        Text("No provider key yet.").foregroundStyle(Theme.textDim)
                        Button("Add one in Preferences…") { GenAIActions.openPreferences() }.buttonStyle(.link)
                    }.font(Theme.fontSmall)
                } else {
                    Caption("Balances")
                    ForEach(keyed) { GenBalanceCard(provider: $0) }
                }
                Caption("Daily spend · last 30 days")
                GenDailyChart(days: store.daily(days: 30))
                WrappingHStack {
                    Caption("Breakdown")
                    Spacer()
                    Picker("", selection: $period) { Text("Today").tag(0); Text("Month").tag(1); Text("30 days").tag(2); Text("All").tag(3) }
                        .labelsHidden().controlSize(.mini).segmentedOrMenu()
                }
                GenBreakdownTable(title: "Feature", groups: store.byFeature(from: periodStart), label: GenUsageUI.featureName)
                GenBreakdownTable(title: "Model", groups: store.byModel(from: periodStart), label: GenUsageUI.modelName)
                GenFalUsageSection(store: store, service: service)
                Text("Costs are estimates from list prices unless the provider reports the actual amount; a provider's own dashboard is authoritative. The log is stored on this Mac only (genai-usage.json) and never contains images.")
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.font)
        .foregroundStyle(Theme.text)
        .onAppear { store.loadIfNeeded(); service.panelAppeared() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            Text("AI Usage").font(Theme.fontBold)
            Spacer()
            if !service.refreshing.isEmpty { ProgressView().controlSize(.mini) }
            IconButton(symbol: "arrow.clockwise", help: "Refresh balances") { service.refreshAll(force: true) }
            Menu {
                Button("Export CSV…") { GenUsageUI.exportCSV() }
                Divider()
                Button("Reset This Month…") { GenUsageUI.resetMonth() }
                Button("Clear All Usage Data…") { GenUsageUI.clearAll() }
                Button("Remove Stored Prompts") { store.removePrompts() }
                Divider()
                Button("Generative History") { WorkspaceManager.shared.reveal("genHistory") }
                Button("Generative AI Preferences…") { GenAIActions.openPreferences() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 30)
                .help("Export, reset, preferences")
        }
    }
}

/// Today / This month / Session.
struct GenUsageTiles: View {
    let store: GenUsageStore

    var body: some View {
        HStack(spacing: 6) {
            tile("Today", store.today())
            tile("This month", store.month())
            tile("Session", store.session)
        }
    }

    private func tile(_ title: String, _ t: GenUsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Caption(title).lineLimit(1).minimumScaleFactor(0.7)
            Text(GenMoney.string(t.cost)).font(.system(size: 16, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text("\(t.generations) generation\(t.generations == 1 ? "" : "s")").font(Theme.fontSmall).foregroundStyle(Theme.textDim).lineLimit(1).minimumScaleFactor(0.8)
            Text("\(t.images) image\(t.images == 1 ? "" : "s")").font(Theme.fontSmall).foregroundStyle(Theme.textFaint).lineLimit(1)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fieldBG))
    }
}

/// Monthly budget with a progress bar (accent → amber at 80 % → red when exceeded).
struct GenBudgetBar: View {
    let store: GenUsageStore
    @Bindable var settings: GenAISettings

    var body: some View {
        let budget = settings.data.monthlyBudget
        let spent = store.month().cost
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Caption("Monthly budget")
                Spacer()
                NumberField(label: "$", value: $settings.data.monthlyBudget, width: 46)
                    .help("Monthly Generative AI budget in USD (0 = none)")
            }
            if budget > 0 {
                let frac = spent / budget
                let level: GenSpendLevel = frac >= 1 ? .critical : (frac >= 0.8 ? .warning : .normal)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fieldBG)
                        Capsule().fill(level == .normal ? Theme.accent : GenUsageUI.color(level))
                            .frame(width: max(spent > 0 ? 4 : 0, g.size.width * min(1, max(0, frac))))
                    }
                }
                .frame(height: 8)
                HStack(spacing: 4) {
                    if level != .normal { Image(systemName: GenUsageUI.symbol(level)).font(.system(size: 9)).foregroundStyle(GenUsageUI.color(level)) }
                    Text("\(GenMoney.string(spent)) of \(GenMoney.string(budget)) used (\(Int((frac * 100).rounded())) %)").monospacedDigit()
                    Spacer()
                    Text(budget - spent >= 0 ? "\(GenMoney.string(budget - spent)) left" : "\(GenMoney.string(spent - budget)) over").monospacedDigit()
                        .foregroundStyle(level == .normal ? Theme.textDim : GenUsageUI.color(level))
                }
                .font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                if settings.data.budgetHardStop {
                    Text("Hard stop is on: generations that would exceed the budget are refused.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                }
            } else {
                Text("No budget set. Enter an amount to track progress and get a warning before overspending.")
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Balance cards

struct GenBalanceCard: View {
    let provider: ProviderID
    @Bindable private var store = GenUsageStore.shared
    @Bindable private var settings = GenAISettings.shared
    @Bindable private var service = GenBalanceService.shared
    @State private var creditText = ""
    @State private var creditDate = Date()
    @State private var adminKey = ""
    @State private var adminStatus = ""

    private var live: Bool { GenBalanceService.supportsLive(provider) }

    var body: some View {
        let remaining = store.remaining(for: provider)
        let level = GenUsageStore.level(remaining, budget: settings.data.monthlyBudget, lowBalance: settings.data.lowBalanceWarning)
        let month = store.totals(from: store.monthStart(Date()), provider: provider.rawValue)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(provider.displayName).font(Theme.fontBold)
                tag(remaining)
                Spacer()
                if service.refreshing.contains(provider) { ProgressView().controlSize(.mini) }
                else if live { IconButton(symbol: "arrow.clockwise", help: "Refresh \(provider.displayName) balance", size: 18) { service.refresh(provider, force: true) } }
            }
            if let r = remaining {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text((r.kind == .estimated ? "≈ " : "") + GenMoney.string(r.amount)).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(level == .normal ? Theme.text : GenUsageUI.color(level))
                    Text("left").foregroundStyle(Theme.textDim)
                    if level != .normal {
                        Label(level == .critical ? "Almost empty" : "Low balance", systemImage: GenUsageUI.symbol(level))
                            .font(Theme.fontSmall).foregroundStyle(GenUsageUI.color(level))
                    }
                }
                Text(detail(r)).font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            }
            Text("This month: \(GenMoney.string(month.cost)) · \(month.generations) generation\(month.generations == 1 ? "" : "s") (tracked here)")
                .font(Theme.fontSmall).foregroundStyle(Theme.textDim)
            if provider == .fal, service.falNeedsAdmin { falAdmin }
            if remaining?.kind != .live { creditEditor }
            if let note = service.notes[provider], !(provider == .fal && service.falNeedsAdmin) {
                Label(note, systemImage: "exclamationmark.triangle").font(Theme.fontSmall).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !live, let why = GenBalanceService.localOnlyReason(provider) {
                Text(why + " Tracked locally.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fieldBG.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(level == .normal ? Theme.border : GenUsageUI.color(level).opacity(0.7), lineWidth: level == .normal ? 0.5 : 1))
        .onAppear {
            if let c = store.credits[provider.rawValue] { creditText = String(format: "%.2f", c.amount); creditDate = c.date }
        }
    }

    @ViewBuilder private func tag(_ r: GenRemaining?) -> some View {
        let (text, color): (String, Color) = {
            switch r?.kind {
            case .live?: return ("LIVE", Color(red: 0.25, green: 0.78, blue: 0.45))
            case .estimated?: return ("ESTIMATED", Theme.textDim)
            default: return (live && !(provider == .fal && service.falNeedsAdmin) ? "NO BALANCE YET" : "LOCAL TRACKING", Theme.textFaint)
            }
        }()
        Text(text).font(.system(size: 8, weight: .bold)).tracking(0.4).foregroundStyle(color)
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.7), lineWidth: 0.75))
    }

    private func detail(_ r: GenRemaining) -> String {
        switch r.kind {
        case .live:
            let b = store.balances[provider.rawValue]
            var s = "Read from \(provider.displayName)"
            if let b, b.unit.lowercased() == "credits" { s += " (\(String(format: "%.1f", b.raw)) credits)" }
            if let a = b?.account, !a.isEmpty { s += " · account \(a)" }
            return s + (r.asOf.map { " · " + GenMoney.ago($0) } ?? "")
        case .estimated:
            let df = DateFormatter(); df.dateStyle = .medium
            let c = store.credits[provider.rawValue]
            return "Estimated: \(GenMoney.string(c?.amount ?? 0)) credit added \(c.map { df.string(from: $0.date) } ?? "") − spend tracked here since then."
        case .budget: return ""
        }
    }

    /// fal.ai without an admin-scope key: explain, and offer a field for a separate admin key.
    @ViewBuilder private var falAdmin: some View {
        Label(GenBalanceService.falAdminMessage, systemImage: "lock").font(Theme.fontSmall).foregroundStyle(.orange)
        Text("fal's billing and usage APIs only accept keys created with the Admin scope (fal.ai ▸ Dashboard ▸ Keys). Add one here just for balance and usage; generation keeps using your normal key.")
            .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 4) {
            SecureField("fal.ai admin key", text: $adminKey).genField().font(Theme.mono)
            Button("Save") {
                let st = GenAIKeychain.shared.set(adminKey, for: GenAIKeychain.falAdminAccount)
                adminStatus = st == errSecSuccess ? "" : "Keychain error \(st)."
                adminKey = ""
                service.falNeedsAdmin = false
                service.refresh(.fal, force: true)
            }
            .buttonStyle(PanelButtonStyle()).disabled(adminKey.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if !adminStatus.isEmpty { Text(adminStatus).font(Theme.fontSmall).foregroundStyle(.orange) }
    }

    /// "Credit added": what the user bought and when → estimated remaining.
    @ViewBuilder private var creditEditor: some View {
        HStack(spacing: 4) {
            Text("Credit added").foregroundStyle(Theme.textDim).fixedSize()
            Text("$").foregroundStyle(Theme.textFaint)
            TextField("0.00", text: $creditText)
                .textFieldStyle(.plain).font(Theme.mono).frame(width: 42)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
                .onSubmit(applyCredit)
            Text("on").foregroundStyle(Theme.textFaint)
            DatePicker("", selection: $creditDate, in: ...Date(), displayedComponents: .date).labelsHidden().datePickerStyle(.field).controlSize(.mini)
                .fixedSize()
            Button(action: applyCredit) { Image(systemName: "checkmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(Theme.accent).help(store.credits[provider.rawValue] == nil ? "Set the credit" : "Update the credit")
            if store.credits[provider.rawValue] != nil {
                Button { store.setCredit(nil, for: provider); creditText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textFaint).help("Forget this credit")
            }
        }
        .font(Theme.fontSmall)
        .help("Enter the credit you bought and when; remaining ≈ credit − spend tracked here since that date.")
    }

    private func applyCredit() {
        let v = Double(creditText.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces))
        guard let v, v > 0 else { store.setCredit(nil, for: provider); return }
        store.setCredit(GenManualCredit(amount: v, date: store.dayStart(creditDate)), for: provider)
    }
}

// MARK: - Daily chart

/// Daily spend bars (one series, one hue). Hover a day for its date, amount and generation count.
struct GenDailyChart: View {
    let days: [GenDailySpend]
    @State private var hover: Int?

    private static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()

    /// A "nice" axis maximum at or above `v` (1 / 1.5 / 2 / 3 / 4 / 5 / 6 / 8 × 10ⁿ).
    static func niceMax(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let mag = pow(10, floor(log10(v)))
        for m in [1, 1.5, 2, 3, 4, 5, 6, 8, 10] where v <= m * mag + 1e-12 { return m * mag }
        return 10 * mag
    }

    var body: some View {
        let maxCost = days.map(\.cost).max() ?? 0
        let top = Self.niceMax(maxCost)
        let total = days.reduce(0) { $0 + $1.cost }
        VStack(alignment: .leading, spacing: 3) {
            Group {
                if let h = hover, days.indices.contains(h) {
                    Text("\(Self.dayFormat.string(from: days[h].day)) · \(GenMoney.string(days[h].cost)) · \(days[h].generations) generation\(days[h].generations == 1 ? "" : "s")")
                        .foregroundStyle(Theme.text)
                } else {
                    Text("\(GenMoney.string(total)) in 30 days · busiest day \(GenMoney.string(maxCost))").foregroundStyle(Theme.textDim)
                }
            }
            .font(Theme.fontSmall).monospacedDigit().lineLimit(1)
            Canvas { ctx, size in
                let labelW: CGFloat = 30
                let plot = CGRect(x: 0, y: 4, width: size.width - labelW, height: size.height - 8)
                // recessive grid: baseline, half, top
                for (i, f) in [0.0, 0.5, 1.0].enumerated() {
                    let y = plot.maxY - plot.height * f
                    var p = Path(); p.move(to: CGPoint(x: plot.minX, y: y)); p.addLine(to: CGPoint(x: plot.maxX, y: y))
                    ctx.stroke(p, with: .color(Theme.border.opacity(i == 0 ? 1 : 0.55)), lineWidth: i == 0 ? 1 : 0.5)
                    if i > 0 {
                        ctx.draw(Text(GenMoney.string(top * f)).font(.system(size: 8)).foregroundStyle(Theme.textFaint),
                                 at: CGPoint(x: plot.maxX + 3, y: y), anchor: .leading)
                    }
                }
                guard !days.isEmpty else { return }
                let pitch = plot.width / CGFloat(days.count)
                let w = max(2, pitch - 2)      // 2 px of surface between neighbouring bars
                for (i, d) in days.enumerated() {
                    let x = plot.minX + CGFloat(i) * pitch + (pitch - w) / 2
                    if d.cost <= 0 { continue }
                    let h = max(2, plot.height * CGFloat(d.cost / top))
                    let r = CGRect(x: x, y: plot.maxY - h, width: w, height: h)
                    let bar = Path(roundedRect: r, cornerRadii: RectangleCornerRadii(topLeading: min(2.5, w / 2), bottomLeading: 0, bottomTrailing: 0, topTrailing: min(2.5, w / 2)))
                    ctx.fill(bar, with: .color(hover == i ? Color(red: 0.42, green: 0.70, blue: 1.0) : Theme.accent))
                }
            }
            .frame(height: 86)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = nil; hoverIndex(p)
                case .ended: hover = nil
                }
            }
            .background(GeometryReader { g in Color.clear.preference(key: GenChartWidthKey.self, value: g.size.width) })
            .onPreferenceChange(GenChartWidthKey.self) { width = $0 }
            HStack {
                if let f = days.first { Text(Self.dayFormat.string(from: f.day)) }
                Spacer()
                if days.count > 2 { Text(Self.dayFormat.string(from: days[days.count / 2].day)) }
                Spacer()
                Text("Today")
            }
            .font(.system(size: 8)).foregroundStyle(Theme.textFaint)
            .padding(.trailing, 30)
        }
        .accessibilityLabel("Daily generative AI spend, last 30 days, total \(GenMoney.string(total))")
    }

    @State private var width: CGFloat = 0

    private func hoverIndex(_ p: CGPoint) {
        let plotW = width - 30
        guard plotW > 0, !days.isEmpty, p.x >= 0, p.x <= plotW else { return }
        hover = min(days.count - 1, Int(p.x / (plotW / CGFloat(days.count))))
    }
}

private struct GenChartWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Breakdown tables

/// Count / cost / average per feature or model; beyond eight rows the rest folds into "Other".
struct GenBreakdownTable: View {
    let title: String
    let groups: [GenUsageGroup]
    let label: (String) -> String

    static func folded(_ groups: [GenUsageGroup], limit: Int = 8) -> [GenUsageGroup] {
        guard groups.count > limit else { return groups }
        let rest = groups[(limit - 1)...]
        let other = GenUsageGroup(key: "__other", generations: rest.reduce(0) { $0 + $1.generations }, images: rest.reduce(0) { $0 + $1.images }, cost: rest.reduce(0) { $0 + $1.cost })
        return Array(groups[..<(limit - 1)]) + [other]
    }

    var body: some View {
        let rows = Self.folded(groups)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title.uppercased()).frame(maxWidth: .infinity, alignment: .leading)
                Text("COUNT").frame(width: 38, alignment: .trailing)
                Text("COST").frame(width: 50, alignment: .trailing)
                Text("AVG").frame(width: 44, alignment: .trailing)
            }
            .font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.textFaint)
            Rectangle().fill(Theme.border).frame(height: 0.5)
            if rows.isEmpty {
                Text("No usage in this period.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
            ForEach(rows) { g in
                HStack(spacing: 6) {
                    Text(g.key == "__other" ? "Other" : label(g.key)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                        .help(g.key == "__other" ? "Remaining entries" : "\(label(g.key)) — \(g.images) images")
                    Text("\(g.generations)").frame(width: 38, alignment: .trailing)
                    Text(GenMoney.string(g.cost)).frame(width: 50, alignment: .trailing)
                    Text(g.generations > 0 ? GenMoney.string(g.average) : "—").foregroundStyle(Theme.textDim).frame(width: 44, alignment: .trailing)
                }
                .font(Theme.fontSmall).monospacedDigit()
            }
        }
    }
}

// MARK: - fal live usage

/// fal.ai billed usage by endpoint (Platform API, admin key), next to Lumen's local estimate for the same period.
struct GenFalUsageSection: View {
    let store: GenUsageStore
    let service: GenBalanceService

    static func unit(_ u: String) -> String {
        switch u.lowercased() {
        case "image", "images": return "img"
        case "second", "seconds": return "s"
        case "megapixel", "megapixels": return "MP"
        case "video", "videos": return "vid"
        default: return String(u.prefix(4))
        }
    }

    var body: some View {
        if let u = service.falUsage {
            let local = store.totals(from: u.start, provider: ProviderID.fal.rawValue).cost
            let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()
            VStack(alignment: .leading, spacing: 3) {
                Caption("fal.ai billed usage · live · since \(df.string(from: u.start))")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(GenMoney.string(u.total)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    Text("billed by fal").foregroundStyle(Theme.textDim)
                    Spacer()
                    Text("ImageCrat estimate \(GenMoney.string(local))").font(Theme.fontSmall).foregroundStyle(Theme.textDim).monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text("ENDPOINT").frame(maxWidth: .infinity, alignment: .leading)
                    Text("QTY").frame(width: 48, alignment: .trailing)
                    Text("BILLED").frame(width: 46, alignment: .trailing)
                    Text("EST.").frame(width: 42, alignment: .trailing)
                }
                .font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.textFaint)
                Rectangle().fill(Theme.border).frame(height: 0.5)
                if u.rows.isEmpty { Text("fal reports no usage in this period.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
                ForEach(u.rows.prefix(10)) { r in
                    let est = GenBalanceService.localFalEstimate(endpoint: r.endpoint, since: u.start, store: store)
                    HStack(spacing: 6) {
                        Text(r.endpoint.replacingOccurrences(of: "fal-ai/", with: "")).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                            .help("\(r.endpoint) — \(GenMoney.string(r.unitPrice)) per \(r.unit)")
                        Text("\(r.quantity.formatted(.number.precision(.fractionLength(0...2)))) \(Self.unit(r.unit))").frame(width: 48, alignment: .trailing).foregroundStyle(Theme.textDim)
                        Text(GenMoney.string(r.cost)).frame(width: 46, alignment: .trailing)
                        Text(est > 0 ? GenMoney.string(est) : "—").frame(width: 42, alignment: .trailing).foregroundStyle(Theme.textDim)
                    }
                    .font(Theme.fontSmall).monospacedDigit()
                }
                if let note = GenBalanceService.differenceNote(billed: u.total, local: local) {
                    Label(note, systemImage: "info.circle").font(Theme.fontSmall).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                }
                Text("Updated \(GenMoney.ago(u.fetched)). Covers your whole fal account.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
        } else if let n = service.falUsageNote {
            Label(n, systemImage: "exclamationmark.triangle").font(Theme.fontSmall).foregroundStyle(.orange)
        }
    }
}

// MARK: - Preferences: budget, privacy of the log, fal admin key

/// Spend, budget and usage-log controls inside Preferences ▸ Generative AI ▸ Privacy & Cost.
struct GenBudgetPreferences: View {
    @Bindable var s = GenAISettings.shared
    @Bindable private var store = GenUsageStore.shared

    var body: some View {
        HStack {
            Text("This month \(GenMoney.string(store.month().cost)) · today \(GenMoney.string(store.today().cost))").font(Theme.fontBold).monospacedDigit()
            Spacer()
            Button("AI Usage…") { AppModel.shared.dialog = nil; GenUsageUI.open() }.buttonStyle(PanelButtonStyle())
        }
        ValueSlider(label: "Monthly budget", value: $s.data.monthlyBudget, range: 0...500, step: 5, unit: " $", labelWidth: 100)
        Toggle2(label: "Warn when a generation would exceed the remaining budget or balance", on: $s.data.warnOverBudget)
        Toggle2(label: "Hard stop: refuse generations that would exceed the monthly budget", on: $s.data.budgetHardStop)
            .disabled(s.data.monthlyBudget <= 0)
        ValueSlider(label: "Low balance at", value: $s.data.lowBalanceWarning, range: 0...50, step: 1, unit: " $", labelWidth: 100)
        Toggle2(label: "Don't log prompts in the usage log", on: $s.data.dontLogPrompts)
        Toggle2(label: "Show the Properties panel when a generation finishes", on: $s.data.revealPropertiesAfterGenerate)
        Text("The estimated cost is shown before each generation. Estimates use list prices per image (or the provider-reported cost when available); live balances come from fal.ai (admin key), Stability AI and Black Forest Labs.")
            .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
    }
}

/// Optional second fal.ai key (Admin scope) used only for the billing / usage APIs. Shown under the fal.ai key row.
struct FalAdminKeyRow: View {
    @Bindable var s = GenAISettings.shared
    @State private var entry = ""
    @State private var status = ""

    var body: some View {
        let _ = s.keysRevision
        let has = GenAIKeychain.shared.hasFalAdminKey
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(has ? Color.green : Color.gray.opacity(0.5)).frame(width: 7, height: 7)
                Text("fal.ai admin key (optional)").font(Theme.fontBold)
                Spacer()
                if let u = URL(string: ProviderID.fal.keyURL) { Link("Create one", destination: u).font(Theme.fontSmall) }
            }
            HStack(spacing: 4) {
                SecureField(has ? "•••••• stored in Keychain — paste to replace" : "Paste a key with Admin scope", text: $entry).genField().font(Theme.mono)
                Button("Save") {
                    let st = GenAIKeychain.shared.set(entry, for: GenAIKeychain.falAdminAccount)
                    status = st == errSecSuccess ? "Saved to Keychain." : "Keychain error \(st)."
                    entry = ""
                    s.keysRevision += 1
                    GenBalanceService.shared.falNeedsAdmin = false
                    GenBalanceService.shared.refresh(.fal, force: true)
                }
                .buttonStyle(PanelButtonStyle()).disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
                if has {
                    Button("Remove") {
                        GenAIKeychain.shared.delete(GenAIKeychain.falAdminAccount)
                        s.keysRevision += 1
                        status = "Key removed."
                        GenBalanceService.shared.refresh(.fal, force: true)
                    }.buttonStyle(PanelButtonStyle())
                }
            }
            if !status.isEmpty { Text(status).font(Theme.fontSmall).foregroundStyle(status.hasPrefix("Saved") ? .green : .orange) }
            Text("Only needed for the live balance and billed usage in AI Usage: fal's billing APIs reject normal keys. Generation never uses this key.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.fieldBG.opacity(0.6)))
    }
}
