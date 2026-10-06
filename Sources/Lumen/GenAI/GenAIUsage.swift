import Foundation
import AppKit
import Observation
import ImageCratCore

// MARK: - Records

/// One generative job as billed by a provider (one row of the usage log).
/// Never contains images; the prompt is truncated and omitted entirely when "Don't log prompts" is on.
struct GenUsageRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var provider = "-"
    var model = "-"
    var feature = ""
    /// Images returned.
    var images = 0
    /// Provider calls made for the job (providers that return one image per call are called once per variation).
    var calls = 1
    /// Local estimate (list price × images, or the provider module's size-aware estimate), USD.
    var estimatedCost = 0.0
    /// Cost taken from the provider's response (token usage, billed credits) when it reports one, USD.
    var reportedCost: Double? = nil
    var seconds = 0.0
    /// "ok", "cancelled", or an error message.
    var status = "ok"
    var prompt: String? = nil

    /// Best known cost: the provider-reported amount when there is one, else the estimate.
    var cost: Double { reportedCost ?? estimatedCost }
    var ok: Bool { status == "ok" }

    init() {}

    init(date: Date = Date(), provider: String, model: String, feature: String, images: Int, calls: Int = 1,
         estimatedCost: Double, reportedCost: Double? = nil, seconds: Double = 0, status: String = "ok", prompt: String? = nil) {
        self.date = date; self.provider = provider; self.model = model; self.feature = feature; self.images = images; self.calls = calls
        self.estimatedCost = estimatedCost; self.reportedCost = reportedCost; self.seconds = seconds; self.status = status; self.prompt = prompt
    }

    private enum K: String, CodingKey { case id, date, provider, model, feature, images, calls, estimatedCost, reportedCost, seconds, status, prompt }

    /// Tolerant: unknown keys are ignored, missing or mistyped keys fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? Date(timeIntervalSince1970: 0)
        provider = (try? c.decodeIfPresent(String.self, forKey: .provider)) ?? "-"
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? "-"
        feature = (try? c.decodeIfPresent(String.self, forKey: .feature)) ?? ""
        images = (try? c.decodeIfPresent(Int.self, forKey: .images)) ?? 0
        calls = (try? c.decodeIfPresent(Int.self, forKey: .calls)) ?? 1
        estimatedCost = (try? c.decodeIfPresent(Double.self, forKey: .estimatedCost)) ?? 0
        reportedCost = (try? c.decodeIfPresent(Double.self, forKey: .reportedCost)) ?? nil
        seconds = (try? c.decodeIfPresent(Double.self, forKey: .seconds)) ?? 0
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "ok"
        prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? nil
    }
}

/// Credit the user bought from a provider that has no balance API ("Credit added").
struct GenManualCredit: Codable, Equatable {
    var amount: Double
    var date: Date
}

/// Last balance read from a provider's API.
struct GenBalance: Codable, Equatable {
    var provider: String
    /// Remaining balance in USD.
    var usd: Double
    /// The number the provider returned (credits or currency).
    var raw: Double
    var unit: String
    var account: String? = nil
    var fetched = Date()
}

struct GenUsageTotals: Equatable {
    var cost = 0.0
    var generations = 0
    var images = 0
    var failed = 0
}

struct GenUsageGroup: Identifiable, Equatable {
    var key: String
    var generations: Int
    var images: Int
    var cost: Double
    var id: String { key }
    var average: Double { generations > 0 ? cost / Double(generations) : 0 }
}

struct GenDailySpend: Identifiable, Equatable {
    var day: Date
    var cost: Double
    var generations: Int
    var id: Date { day }
}

enum GenRemainingKind: String { case live, estimated, budget }

/// What is left to spend, and how we know.
struct GenRemaining: Equatable {
    var amount: Double
    var kind: GenRemainingKind
    var provider: ProviderID? = nil
    var asOf: Date? = nil
}

enum GenSpendLevel: String { case normal, warning, critical }

// MARK: - Store

/// Persistent usage log: `~/Library/Application Support/ImageCrat/genai-usage.json` (or `$LUMEN_SUPPORT_DIR/genai-usage.json`).
/// Holds one record per generative job, the manual "credit added" entries and the last balances read from provider APIs.
/// Self tests never touch the real folder: without an explicit directory the store stays in memory under `--selftest`.
@Observable
final class GenUsageStore {
    static let shared = GenUsageStore()
    static let fileName = "genai-usage.json"
    static let maxRecords = 20_000
    static let promptLimit = 120

    /// Oldest first.
    private(set) var records: [GenUsageRecord] = []
    private(set) var credits: [String: GenManualCredit] = [:]
    private(set) var balances: [String: GenBalance] = [:]

    /// Folder of the JSON file; nil = in-memory only.
    @ObservationIgnored private(set) var directory: URL?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var migrated = false
    /// Spend since this moment counts as "this session".
    @ObservationIgnored var sessionStart = Date()
    @ObservationIgnored var calendar = Calendar.current
    private static let ioQueue = DispatchQueue(label: "app.lumen.genai.usage", qos: .utility)

    static var isSelfTest: Bool { CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--perftest") }

    static var defaultDirectory: URL? {
        if let o = ProcessInfo.processInfo.environment["LUMEN_SUPPORT_DIR"], !o.isEmpty { return URL(fileURLWithPath: o) }
        if isSelfTest { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Brand.supportFolderName)
    }

    init(directory: URL? = GenUsageStore.defaultDirectory, load: Bool = false) {
        self.directory = directory
        if load { loadIfNeeded() }
    }

    var fileURL: URL? { directory?.appendingPathComponent(GenUsageStore.fileName) }

    /// Points the store at another folder (tests use a temp dir) and reloads. `legacy` supplies data to migrate on a first run.
    func configure(directory: URL?, legacyHistory: [GenHistoryEntry]? = nil, legacySpend: [String: Double]? = nil) {
        saveWork?.cancel(); saveWork = nil
        self.directory = directory
        records = []; credits = [:]; balances = [:]
        loaded = false; migrated = false
        load(legacyHistory: legacyHistory ?? [], legacySpend: legacySpend ?? [:])
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        load(legacyHistory: GenJobs.shared.history, legacySpend: GenAISettings.shared.data.spend)
    }

    // MARK: File

    private struct FileModel: Codable {
        var version = 1
        var migratedLegacyHistory = false
        var records: [Failable<GenUsageRecord>] = []
        var credits: [String: GenManualCredit] = [:]
        var balances: [String: GenBalance] = [:]

        init() {}
        private enum K: String, CodingKey { case version, migratedLegacyHistory, records, credits, balances }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
            migratedLegacyHistory = (try? c.decodeIfPresent(Bool.self, forKey: .migratedLegacyHistory)) ?? false
            records = (try? c.decodeIfPresent([Failable<GenUsageRecord>].self, forKey: .records)) ?? []
            credits = (try? c.decodeIfPresent([String: GenManualCredit].self, forKey: .credits)) ?? [:]
            balances = (try? c.decodeIfPresent([String: GenBalance].self, forKey: .balances)) ?? [:]
        }
    }

    /// Array element that decodes to nil instead of failing the whole array.
    private struct Failable<T: Codable>: Codable {
        var value: T?
        init(_ v: T) { value = v }
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
        func encode(to encoder: Encoder) throws { try value?.encode(to: encoder) }
    }

    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static func parseDate(_ s: String) -> Date? {
        if let d = isoFraction.date(from: s) ?? isoPlain.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { d, enc in var c = enc.singleValueContainer(); try c.encode(isoFraction.string(from: d)) }
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let s = try? c.decode(String.self), let date = parseDate(s) { return date }
            if let t = try? c.decode(Double.self) { return Date(timeIntervalSince1970: t) }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unreadable date")
        }
        return d
    }

    private func load(legacyHistory: [GenHistoryEntry], legacySpend: [String: Double]) {
        loaded = true
        var model = FileModel()
        var existed = false
        if let url = fileURL, let data = try? Data(contentsOf: url) {
            existed = true
            if let m = try? GenUsageStore.makeDecoder().decode(FileModel.self, from: data) {
                model = m
            } else {
                // Unreadable file: keep it for inspection instead of overwriting it.
                let aside = url.deletingLastPathComponent().appendingPathComponent("genai-usage.corrupt-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: aside)
                existed = false
            }
        }
        records = model.records.compactMap(\.value).sorted { $0.date < $1.date }
        credits = model.credits
        balances = model.balances
        migrated = model.migratedLegacyHistory
        if !migrated {
            let legacy = GenUsageStore.migrate(history: legacyHistory, monthSpend: legacySpend, calendar: calendar)
            if !legacy.isEmpty {
                let known = Set(records.map(\.id))
                records = (records + legacy.filter { !known.contains($0.id) }).sorted { $0.date < $1.date }
            }
            migrated = true
            if !legacy.isEmpty || !existed { scheduleSave() }
        }
    }

    /// Legacy data → records: every Generative History entry, plus one "earlier usage" row per month for spend the
    /// (300-entry) history no longer covers, so monthly totals carry over.
    static func migrate(history: [GenHistoryEntry], monthSpend: [String: Double], calendar: Calendar = .current) -> [GenUsageRecord] {
        var out = history.map { e -> GenUsageRecord in
            var r = GenUsageRecord(date: e.date, provider: e.provider, model: e.model, feature: e.feature, images: e.images,
                                   estimatedCost: e.cost, seconds: e.seconds, status: e.status, prompt: truncate(e.prompt))
            r.id = e.id
            return r
        }
        var byMonth: [String: Double] = [:]
        for r in out { byMonth[GenAISettings.monthKey(r.date), default: 0] += r.cost }
        for (month, total) in monthSpend {
            let missing = total - (byMonth[month] ?? 0)
            guard missing > 0.0005 else { continue }
            let parts = month.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2, let d = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)) else { continue }
            out.append(GenUsageRecord(date: d, provider: "-", model: "-", feature: "earlier", images: 0, calls: 0, estimatedCost: missing, status: "ok"))
        }
        return out.sorted { $0.date < $1.date }
    }

    static func truncate(_ prompt: String?) -> String? {
        guard let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return nil }
        return p.count > promptLimit ? String(p.prefix(promptLimit)) + "…" : p
    }

    /// Value snapshot taken on the main thread; encoding and writing happen on the I/O queue.
    private func snapshot() -> () -> Data? {
        let (r, c, b, mig) = (records, credits, balances, migrated)
        return {
            var m = FileModel()
            m.migratedLegacyHistory = mig
            m.records = r.map { Failable($0) }
            m.credits = c
            m.balances = b
            return try? GenUsageStore.makeEncoder().encode(m)
        }
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    /// Writes pending changes now (atomic; the write itself happens off the main thread unless `wait`).
    func flush(wait: Bool = false) {
        saveWork?.cancel(); saveWork = nil
        guard loaded, let url = fileURL else { return }     // never write a log that was not read first
        let encode = snapshot()
        let write = {
            guard let data = encode() else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        if wait { GenUsageStore.ioQueue.sync(execute: write) } else { GenUsageStore.ioQueue.async(execute: write) }
    }

    /// Stops persisting (pending writes are dropped, in-flight ones finish). Tests call this before deleting their temp folder.
    func detach() {
        saveWork?.cancel(); saveWork = nil
        directory = nil
        GenUsageStore.ioQueue.sync {}
    }

    // MARK: Mutations

    func add(_ r: GenUsageRecord) {
        loadIfNeeded()
        var r = r
        if GenAISettings.shared.data.dontLogPrompts { r.prompt = nil } else { r.prompt = GenUsageStore.truncate(r.prompt) }
        records.append(r)
        if records.count > GenUsageStore.maxRecords { records.removeFirst(records.count - GenUsageStore.maxRecords) }
        scheduleSave()
    }

    /// Attaches a provider-reported cost to a record after the fact.
    func reconcile(_ id: UUID, reportedCost: Double) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].reportedCost = reportedCost
        scheduleSave()
    }

    func setCredit(_ c: GenManualCredit?, for p: ProviderID) {
        loadIfNeeded()
        credits[p.rawValue] = c
        scheduleSave()
    }

    func setBalance(_ b: GenBalance?, for p: ProviderID) {
        loadIfNeeded()
        guard balances[p.rawValue] != b else { return }
        balances[p.rawValue] = b
        scheduleSave()
    }

    /// Removes the stored prompts (privacy), keeping the cost data.
    func removePrompts() {
        loadIfNeeded()
        for i in records.indices { records[i].prompt = nil }
        scheduleSave()
    }

    /// Deletes this month's records (the month counter starts again at zero).
    func resetMonth(now: Date = Date()) {
        loadIfNeeded()
        let start = monthStart(now)
        records.removeAll { $0.date >= start }
        scheduleSave()
    }

    func clearAll() {
        loadIfNeeded()
        records.removeAll()
        scheduleSave()
    }

    // MARK: Aggregation

    func dayStart(_ d: Date) -> Date { calendar.startOfDay(for: d) }
    func monthStart(_ d: Date) -> Date { calendar.date(from: calendar.dateComponents([.year, .month], from: d)) ?? d }

    func filtered(from: Date? = nil, to: Date? = nil, provider: String? = nil) -> [GenUsageRecord] {
        loadIfNeeded()
        return records.filter { r in
            if let f = from, r.date < f { return false }
            if let t = to, r.date >= t { return false }
            if let p = provider, r.provider != p { return false }
            return true
        }
    }

    func totals(from: Date? = nil, to: Date? = nil, provider: String? = nil) -> GenUsageTotals {
        var t = GenUsageTotals()
        for r in filtered(from: from, to: to, provider: provider) {
            t.cost += r.cost
            if r.ok { if r.calls > 0 { t.generations += 1 }; t.images += r.images } else if r.status != "cancelled" { t.failed += 1 }
        }
        return t
    }

    func today(now: Date = Date()) -> GenUsageTotals { totals(from: dayStart(now)) }
    func month(now: Date = Date()) -> GenUsageTotals { totals(from: monthStart(now)) }
    var session: GenUsageTotals { totals(from: sessionStart) }

    func breakdown(_ key: (GenUsageRecord) -> String, from: Date? = nil, to: Date? = nil) -> [GenUsageGroup] {
        var map: [String: GenUsageGroup] = [:]
        for r in filtered(from: from, to: to) where r.ok || r.cost > 0 {
            var g = map[key(r)] ?? GenUsageGroup(key: key(r), generations: 0, images: 0, cost: 0)
            if r.calls > 0 { g.generations += 1 }
            g.images += r.images
            g.cost += r.cost
            map[key(r)] = g
        }
        return map.values.sorted { $0.cost != $1.cost ? $0.cost > $1.cost : $0.key < $1.key }
    }

    func byFeature(from: Date? = nil) -> [GenUsageGroup] { breakdown({ $0.feature }, from: from) }
    func byModel(from: Date? = nil) -> [GenUsageGroup] { breakdown({ $0.provider + ":" + $0.model }, from: from) }

    /// One entry per calendar day, oldest first, ending today (days without usage are zero).
    func daily(days: Int = 30, now: Date = Date()) -> [GenDailySpend] {
        let end = dayStart(now)
        guard let first = calendar.date(byAdding: .day, value: -(days - 1), to: end) else { return [] }
        var out: [GenDailySpend] = (0..<days).compactMap { i in
            calendar.date(byAdding: .day, value: i, to: first).map { GenDailySpend(day: $0, cost: 0, generations: 0) }
        }
        for r in filtered(from: first) {
            let idx = calendar.dateComponents([.day], from: first, to: dayStart(r.date)).day ?? -1
            guard out.indices.contains(idx) else { continue }
            out[idx].cost += r.cost
            if r.ok && r.calls > 0 { out[idx].generations += 1 }
        }
        return out
    }

    // MARK: Remaining

    /// Credit added − tracked spend with that provider since the date it was added.
    func estimatedRemaining(_ p: ProviderID) -> Double? {
        loadIfNeeded()
        guard let c = credits[p.rawValue] else { return nil }
        return c.amount - totals(from: c.date, provider: p.rawValue).cost
    }

    /// Live balance if one was read from the provider, else the estimate from "Credit added".
    func remaining(for p: ProviderID) -> GenRemaining? {
        loadIfNeeded()
        if let b = balances[p.rawValue] { return GenRemaining(amount: b.usd, kind: .live, provider: p, asOf: b.fetched) }
        if let e = estimatedRemaining(p) { return GenRemaining(amount: e, kind: .estimated, provider: p, asOf: credits[p.rawValue]?.date) }
        return nil
    }

    func budgetRemaining(budget: Double = GenAISettings.shared.data.monthlyBudget, now: Date = Date()) -> Double? {
        budget > 0 ? budget - month(now: now).cost : nil
    }

    /// The provider the status chip reports on: the one used last (if it still has a key), else the first keyed one with a known balance.
    func primaryProvider(keyed: [ProviderID]) -> ProviderID? {
        loadIfNeeded()
        if let last = records.last(where: { r in keyed.contains { $0.rawValue == r.provider } }), let p = ProviderID(rawValue: last.provider) { return p }
        return keyed.first { remaining(for: $0) != nil } ?? keyed.first
    }

    /// What the status chip shows as "left": live balance, else estimated remaining, else budget remaining.
    func overallRemaining(keyed: [ProviderID], budget: Double = GenAISettings.shared.data.monthlyBudget, now: Date = Date()) -> GenRemaining? {
        if let p = primaryProvider(keyed: keyed), let r = remaining(for: p) { return r }
        if let b = budgetRemaining(budget: budget, now: now) { return GenRemaining(amount: b, kind: .budget) }
        return nil
    }

    static func level(_ r: GenRemaining?, budget: Double, lowBalance: Double) -> GenSpendLevel {
        guard let r else { return .normal }
        switch r.kind {
        case .budget:
            guard budget > 0 else { return .normal }
            if r.amount <= 0 { return .critical }
            return r.amount <= budget * 0.2 ? .warning : .normal
        case .live, .estimated:
            if r.amount <= max(0, lowBalance * 0.2) { return .critical }
            return r.amount <= lowBalance ? .warning : .normal
        }
    }

    /// Worst of the balance level and the budget level (the chip turns amber/red for either).
    func level(keyed: [ProviderID], settings: GenAISettingsData = GenAISettings.shared.data, now: Date = Date()) -> GenSpendLevel {
        var levels: [GenSpendLevel] = [GenUsageStore.level(overallRemaining(keyed: keyed, budget: settings.monthlyBudget, now: now), budget: settings.monthlyBudget, lowBalance: settings.lowBalanceWarning)]
        if let b = budgetRemaining(budget: settings.monthlyBudget, now: now) {
            levels.append(GenUsageStore.level(GenRemaining(amount: b, kind: .budget), budget: settings.monthlyBudget, lowBalance: settings.lowBalanceWarning))
        }
        if levels.contains(.critical) { return .critical }
        return levels.contains(.warning) ? .warning : .normal
    }

    // MARK: Export

    static let csvHeader = "date,provider,model,feature,images,calls,estimated_cost_usd,reported_cost_usd,cost_usd,seconds,status,prompt"

    static func csvField(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    func csv(from: Date? = nil) -> String {
        var lines = [GenUsageStore.csvHeader]
        for r in filtered(from: from) {
            let f: [String] = [GenUsageStore.isoPlain.string(from: r.date), r.provider, r.model, r.feature, String(r.images), String(r.calls),
                               String(format: "%.4f", r.estimatedCost), r.reportedCost.map { String(format: "%.4f", $0) } ?? "",
                               String(format: "%.4f", r.cost), String(format: "%.1f", r.seconds), r.status, r.prompt ?? ""]
            lines.append(f.map(GenUsageStore.csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Money formatting

enum GenMoney {
    /// "$0.42", "$18.30", "$1,204.00"; tiny non-zero amounts keep a third decimal ("$0.004").
    static func string(_ v: Double) -> String {
        let a = abs(v)
        let sign = v < -0.0005 ? "−" : ""
        if a > 0, a < 0.01 { return sign + String(format: "$%.3f", a) }
        if a >= 1000 {
            let f = NumberFormatter()
            f.numberStyle = .decimal; f.minimumFractionDigits = 2; f.maximumFractionDigits = 2; f.locale = Locale(identifier: "en_US")
            return sign + "$" + (f.string(from: NSNumber(value: a)) ?? String(format: "%.2f", a))
        }
        return sign + String(format: "$%.2f", a)
    }

    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86_400)) d ago"
    }
}

// MARK: - Cost estimates & budget

enum GenBudgetDecision: Equatable {
    case allow
    case warn(String)
    case block(String)
}

enum GenBudget {
    /// Features that return one image regardless of the Variations setting.
    static let singleImageFeatures: Set<GenFeature> = [.upscale, .denoise, .sharpen]
    /// Last warning raised (headless runs skip the dialog; tests read this).
    nonisolated(unsafe) static var lastWarning: String?
    nonisolated(unsafe) static var suppressWarningsThisSession = false

    static func count(for f: GenFeature, variations: Int = GenAISettings.shared.data.variations) -> Int {
        singleImageFeatures.contains(f) ? 1 : max(1, variations)
    }

    static func estimate(_ m: GenModel, count: Int) -> Double { m.pricePerImage * Double(max(1, count)) }

    /// "≈ $0.15 for 3 variations with fal.ai FLUX.1 Pro Fill"
    static func estimateText(_ m: GenModel, count: Int) -> String {
        "≈ \(GenMoney.string(estimate(m, count: count))) for \(count) \(count == 1 ? "image" : "variations") with \(m.provider.displayName) \(m.name)"
    }

    /// Pure budget rule. Budget overruns block when the hard stop is on, else warn; a balance shortfall only warns
    /// (balances can be stale and the provider enforces its own limit).
    static func evaluate(estimate: Double, provider: ProviderID, settings: GenAISettingsData, store: GenUsageStore, now: Date = Date()) -> GenBudgetDecision {
        if let left = store.budgetRemaining(budget: settings.monthlyBudget, now: now), estimate > left + 1e-9 {
            let used = settings.monthlyBudget - left
            let msg = "This generation (≈ \(GenMoney.string(estimate))) would exceed your \(GenMoney.string(settings.monthlyBudget)) monthly Generative AI budget (\(GenMoney.string(used)) used this month)."
            if settings.budgetHardStop { return .block(msg + " Raise the budget or turn off the hard stop in Preferences ▸ Generative AI.") }
            if settings.warnOverBudget { return .warn(msg) }
        }
        if settings.warnOverBudget, let r = store.remaining(for: provider), estimate > r.amount + 1e-9 {
            let how = r.kind == .live ? "balance" : "estimated remaining credit"
            return .warn("This generation (≈ \(GenMoney.string(estimate))) costs more than your \(provider.displayName) \(how) (\(GenMoney.string(r.amount))).")
        }
        return .allow
    }

    /// Called before the first provider call of a job: blocks, asks, or lets it through.
    @MainActor static func gate(_ m: GenModel, count: Int) throws {
        let est = estimate(m, count: count)
        switch evaluate(estimate: est, provider: m.provider, settings: GenAISettings.shared.data, store: GenUsageStore.shared) {
        case .allow: return
        case .block(let msg): throw GenError.budget(msg)
        case .warn(let msg):
            lastWarning = msg
            if GenJobs.shared.headless || suppressWarningsThisSession { return }
            let a = NSAlert()
            a.messageText = tr("Generate anyway?")
            a.informativeText = tr(msg)
            a.addButton(withTitle: tr("Generate")); a.addButton(withTitle: tr("Cancel"))
            a.showsSuppressionButton = true
            a.suppressionButton?.title = tr("Don't ask again this session")
            let r = a.runModal()
            if a.suppressionButton?.state == .on { suppressWarningsThisSession = true }
            guard r == .alertFirstButtonReturn else { throw GenError.cancelled }
        }
    }
}
