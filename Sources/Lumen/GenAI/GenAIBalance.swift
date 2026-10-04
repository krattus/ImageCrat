import Foundation
import Observation
import ImageCratCore

/// One line of fal.ai's billed usage (`summary[]` / `time_series[].results[]`).
struct GenFalUsageRow: Identifiable, Equatable {
    var endpoint: String
    var unit: String
    var quantity: Double
    var unitPrice: Double
    var cost: Double
    var currency: String
    var id: String { endpoint + "|" + unit }
}

struct GenFalUsageDay: Identifiable, Equatable {
    var day: Date
    var cost: Double
    var id: Date { day }
}

/// Billed usage read from fal.ai's Platform API for a period (whole fal account, all keys and apps).
struct GenFalUsage: Equatable {
    var start: Date
    var fetched = Date()
    var rows: [GenFalUsageRow] = []
    var days: [GenFalUsageDay] = []
    var pages = 1
    var total: Double { rows.reduce(0) { $0 + $1.cost } }
}

/// Live balances and billed usage, where a provider's API offers them with the user's key:
///
/// - fal.ai — `GET https://api.fal.ai/v1/account/billing?expand=credits` and `GET /v1/models/usage` (Platform APIs,
///   `Authorization: Key …`, **admin-scope key required**: a normal key gets 401/403).
///   Docs: https://fal.ai/docs/platform-apis/v1/account/billing , https://fal.ai/docs/platform-apis/v1/models/usage
/// - Stability AI — `GET /v1/user/balance` → `{"credits": n}` (1 credit = $0.01).
/// - Black Forest Labs — `GET /v1/credits` (`x-key`) → `{"credits": n}` (1 credit = $0.01). Docs: https://docs.bfl.ml/api-reference/get-the-users-credits
/// - OpenAI (usage/costs need an `sk-admin` organisation key and there is no balance endpoint), Google Gemini (billing is
///   only in AI Studio / Cloud Billing) and Replicate (`/v1/account` has no balance) have nothing usable with a normal API
///   key, so they are tracked locally ("Credit added" − tracked spend).
@Observable
final class GenBalanceService {
    static let shared = GenBalanceService()

    static let liveProviders: Set<ProviderID> = [.fal, .stability, .bfl]
    static let falAdminMessage = "Live balance needs a fal.ai key with Admin scope"

    /// Small per-provider warnings (never alerts).
    var notes: [ProviderID: String] = [:]
    var refreshing: Set<ProviderID> = []
    /// The stored fal key(s) were refused by the Platform API (no admin scope).
    var falNeedsAdmin = false
    var falUsage: GenFalUsage?
    var falUsageNote: String?

    @ObservationIgnored private var lastAttempt: [ProviderID: Date] = [:]
    @ObservationIgnored private var debounce: [ProviderID: Task<Void, Never>] = [:]
    /// Minimum time between automatic refreshes of one provider.
    @ObservationIgnored var minInterval: TimeInterval = 60
    @ObservationIgnored var debounceDelay: TimeInterval = 2.5

    static func supportsLive(_ p: ProviderID) -> Bool { liveProviders.contains(p) }

    /// Why a provider has no live balance (shown on its card).
    static func localOnlyReason(_ p: ProviderID) -> String? {
        switch p {
        case .openai: return "OpenAI has no balance API; its usage/costs API needs an organisation admin key."
        case .gemini: return "Google shows Gemini billing only in AI Studio / Cloud Billing."
        case .replicate: return "Replicate's API does not report a balance."
        default: return nil
        }
    }

    // MARK: Network (pure)

    private static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func fetchStability(key: String) async throws -> GenBalance {
        var r = URLRequest(url: try GenHTTP.url(GenHTTP.base(.stability, "https://api.stability.ai") + "/v1/user/balance"))
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (d, _) = try await GenHTTP.send(r, provider: .stability, retries: 0)
        guard let c = number(try GenHTTP.parseJSON(d)["credits"]) else { throw GenError.badResponse("no credits in balance response") }
        return GenBalance(provider: ProviderID.stability.rawValue, usd: c * 0.01, raw: c, unit: "credits")
    }

    static func fetchBFL(key: String) async throws -> GenBalance {
        var r = URLRequest(url: try GenHTTP.url(GenHTTP.base(.bfl, "https://api.bfl.ai") + "/v1/credits"))
        r.setValue(key, forHTTPHeaderField: "x-key")
        r.setValue("application/json", forHTTPHeaderField: "accept")
        let (d, _) = try await GenHTTP.send(r, provider: .bfl, retries: 0)
        guard let c = number(try GenHTTP.parseJSON(d)["credits"]) else { throw GenError.badResponse("no credits in response") }
        return GenBalance(provider: ProviderID.bfl.rawValue, usd: c * 0.01, raw: c, unit: "credits")
    }

    private static func falPlatformURL(_ path: String, _ items: [URLQueryItem]) throws -> URL {
        guard let base = GenHTTP.falPlatformBase, var c = URLComponents(string: base + path) else { throw GenError.unsupported("fal.ai Platform API is not available.") }
        c.queryItems = items
        guard let u = c.url else { throw GenError.badResponse("invalid URL") }
        return u
    }

    /// `GET /v1/account/billing?expand=credits` → `{"username": …, "credits": {"current_balance": 24.5, "currency": "USD"}}`.
    static func fetchFalBilling(key: String) async throws -> GenBalance {
        var r = URLRequest(url: try falPlatformURL("/v1/account/billing", [URLQueryItem(name: "expand", value: "credits")]))
        r.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        let (d, _) = try await GenHTTP.send(r, provider: .fal, retries: 0)
        let json = try GenHTTP.parseJSON(d)
        guard let credits = json["credits"] as? [String: Any], let bal = number(credits["current_balance"]) else {
            throw GenError.badResponse("no credits.current_balance in billing response")
        }
        return GenBalance(provider: ProviderID.fal.rawValue, usd: bal, raw: bal, unit: (credits["currency"] as? String) ?? "USD", account: json["username"] as? String)
    }

    private static func falRows(_ a: Any?) -> [GenFalUsageRow] {
        ((a as? [[String: Any]]) ?? []).compactMap { r in
            guard let e = r["endpoint_id"] as? String else { return nil }
            return GenFalUsageRow(endpoint: e, unit: r["unit"] as? String ?? "", quantity: number(r["quantity"]) ?? 0, unitPrice: number(r["unit_price"]) ?? 0,
                                  cost: number(r["cost"]) ?? number(r["cost_total"]) ?? 0, currency: r["currency"] as? String ?? "USD")
        }
    }

    private static func merge(_ rows: [GenFalUsageRow]) -> [GenFalUsageRow] {
        var map: [String: GenFalUsageRow] = [:]
        for r in rows {
            if var m = map[r.id] { m.quantity += r.quantity; m.cost += r.cost; map[r.id] = m } else { map[r.id] = r }
        }
        return map.values.sorted { $0.cost != $1.cost ? $0.cost > $1.cost : $0.endpoint < $1.endpoint }
    }

    /// `GET /v1/models/usage?expand=summary&expand=time_series&start=<date>&timeframe=day` (repeated `expand`, cursor pagination).
    static func fetchFalUsage(key: String, start: Date, timeZone: TimeZone = .current, maxPages: Int = 25) async throws -> GenFalUsage {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = timeZone; df.dateFormat = "yyyy-MM-dd"
        var usage = GenFalUsage(start: start)
        var summary: [GenFalUsageRow] = []
        var series: [GenFalUsageRow] = []
        var days: [Date: Double] = [:]
        var cursor: String?
        var page = 0
        repeat {
            var items = [URLQueryItem(name: "expand", value: "summary"), URLQueryItem(name: "expand", value: "time_series"),
                         URLQueryItem(name: "start", value: df.string(from: start)), URLQueryItem(name: "timeframe", value: "day"),
                         URLQueryItem(name: "timezone", value: timeZone.identifier)]
            if let c = cursor { items.append(URLQueryItem(name: "cursor", value: c)) }
            var r = URLRequest(url: try falPlatformURL("/v1/models/usage", items))
            r.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
            let (d, _) = try await GenHTTP.send(r, provider: .fal, retries: 0)
            let json = try GenHTTP.parseJSON(d)
            // The summary covers the whole period: take it once; buckets accumulate across pages.
            if summary.isEmpty { summary = falRows(json["summary"]) }
            for b in (json["time_series"] as? [[String: Any]]) ?? [] {
                let rows = falRows(b["results"])
                series += rows
                if let s = b["bucket"] as? String, let day = GenUsageStore.parseDate(s) { days[day, default: 0] += rows.reduce(0) { $0 + $1.cost } }
            }
            page += 1
            cursor = (json["has_more"] as? Bool) == true ? json["next_cursor"] as? String : nil
        } while cursor != nil && page < maxPages
        usage.rows = merge(summary.isEmpty ? series : summary)
        usage.days = days.map { GenFalUsageDay(day: $0.key, cost: $0.value) }.sorted { $0.day < $1.day }
        usage.pages = page
        return usage
    }

    // MARK: Refresh

    /// The key used for fal's Platform API: the dedicated admin key when stored, else the normal key (which may itself be admin-scoped).
    static func falPlatformKeys() async -> [String] {
        var keys: [String] = []
        if let a = await GenAIKeychain.shared.loadFalAdminKey(), !a.isEmpty { keys.append(a) }
        if let k = await GenAIKeychain.shared.loadKey(.fal), !keys.contains(k) { keys.append(k) }
        return keys
    }

    static func isAuthError(_ e: Error) -> Bool {
        if case .unauthorized = e as? GenError { return true }
        if case .http(let code, _) = e as? GenError, code == 401 || code == 403 { return true }
        return false
    }

    private static func brief(_ e: Error) -> String {
        let s = (e as? GenError)?.errorDescription ?? e.localizedDescription
        return s.count > 90 ? String(s.prefix(90)) + "…" : s
    }

    /// Fetches one provider's balance (and fal's billed usage) and updates the cache. Failures become a small note.
    @MainActor func refreshAsync(_ p: ProviderID) async {
        guard GenBalanceService.supportsLive(p), !refreshing.contains(p) else { return }
        // Self tests only ever talk to the mock.
        if GenUsageStore.isSelfTest && GenHTTP.overrides[p] == nil { return }
        lastAttempt[p] = Date()
        refreshing.insert(p)
        defer { refreshing.remove(p) }
        let store = GenUsageStore.shared
        do {
            switch p {
            case .stability:
                guard let k = await GenAIKeychain.shared.loadKey(.stability) else { store.setBalance(nil, for: p); return }
                store.setBalance(try await GenBalanceService.fetchStability(key: k), for: p)
            case .bfl:
                guard let k = await GenAIKeychain.shared.loadKey(.bfl) else { store.setBalance(nil, for: p); return }
                store.setBalance(try await GenBalanceService.fetchBFL(key: k), for: p)
            case .fal:
                let keys = await GenBalanceService.falPlatformKeys()
                guard !keys.isEmpty else { store.setBalance(nil, for: p); falUsage = nil; return }
                var lastAuth: Error?
                var got: (GenBalance, String)?
                for k in keys {
                    do { got = (try await GenBalanceService.fetchFalBilling(key: k), k); break }
                    catch where GenBalanceService.isAuthError(error) { lastAuth = error }
                }
                guard let (bal, key) = got else {
                    // No admin scope: fall back to local tracking.
                    falNeedsAdmin = true
                    falUsage = nil
                    store.setBalance(nil, for: p)
                    notes[p] = GenBalanceService.falAdminMessage
                    _ = lastAuth
                    return
                }
                falNeedsAdmin = false
                store.setBalance(bal, for: p)
                do {
                    falUsage = try await GenBalanceService.fetchFalUsage(key: key, start: store.monthStart(Date()))
                    falUsageNote = nil
                } catch {
                    falUsageNote = "Couldn't load fal usage: \(GenBalanceService.brief(error))"
                }
            default: return
            }
            notes[p] = nil
        } catch {
            if GenBalanceService.isAuthError(error) {
                store.setBalance(nil, for: p)
                notes[p] = "The \(p.displayName) key was rejected when reading the balance."
            } else if (error as? GenError) != .cancelled {
                notes[p] = "Couldn't refresh the balance: \(GenBalanceService.brief(error))"
            }
        }
    }

    /// Non-blocking refresh. Automatic refreshes are rate-limited; `force` is the user's Refresh button.
    func refresh(_ p: ProviderID, force: Bool = false) {
        guard GenBalanceService.supportsLive(p), GenAIKeychain.shared.hasKey(p) || (p == .fal && GenAIKeychain.shared.hasFalAdminKey) else { return }
        if !force, let t = lastAttempt[p], Date().timeIntervalSince(t) < minInterval { return }
        // A key without admin scope stays that way: don't keep asking until the user presses Refresh or saves a key.
        if !force, p == .fal, falNeedsAdmin { return }
        Task { @MainActor in await self.refreshAsync(p) }
    }

    func refreshAll(force: Bool = false) {
        for p in ProviderID.allCases where GenBalanceService.supportsLive(p) { refresh(p, force: force) }
    }

    /// After a generation: refresh that provider's balance once things settle (debounced; skipped in headless runs).
    @MainActor func generationFinished(_ p: ProviderID) {
        guard GenBalanceService.supportsLive(p), !GenJobs.shared.headless else { return }
        debounce[p]?.cancel()
        let delay = debounceDelay
        debounce[p] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // providers take a moment to bill a finished job; a forced refresh here replaces any pending automatic one
            await self.refreshAsync(p)
        }
    }

    /// A key was added, replaced or removed: forget what no longer applies and read the balances again.
    func keysChanged() {
        guard !GenJobs.shared.headless else { return }
        falNeedsAdmin = false
        lastAttempt = [:]
        for p in ProviderID.allCases where GenBalanceService.supportsLive(p) && !GenAIKeychain.shared.hasKey(p) && !(p == .fal && GenAIKeychain.shared.hasFalAdminKey) {
            GenUsageStore.shared.setBalance(nil, for: p)
            notes[p] = nil
            if p == .fal { falUsage = nil }
        }
        refreshAll()
    }

    /// Panel opened: refresh whatever is stale (not in headless runs).
    func panelAppeared() {
        guard !GenJobs.shared.headless else { return }
        refreshAll()
    }

    // MARK: fal billed vs local

    /// Local estimate for one fal endpoint since `start` (model ids carry "#variant" suffixes the endpoint doesn't).
    static func localFalEstimate(endpoint: String, since start: Date, store: GenUsageStore = .shared) -> Double {
        store.filtered(from: start, provider: ProviderID.fal.rawValue)
            .filter { $0.model.components(separatedBy: "#")[0] == endpoint }
            .reduce(0) { $0 + $1.cost }
    }

    /// Note shown when fal's billed total and Lumen's local estimate for the same period disagree by more than a cent and 2 %.
    static func differenceNote(billed: Double, local: Double) -> String? {
        let diff = billed - local
        guard abs(diff) > 0.01, abs(diff) > max(billed, local) * 0.02 else { return nil }
        if diff > 0 {
            return "fal billed \(GenMoney.string(diff)) more than ImageCrat estimated — fal's numbers cover the whole account (other apps and keys) and its current prices."
        }
        return "fal billed \(GenMoney.string(-diff)) less than ImageCrat estimated (discounts, failed jobs that were not charged, or usage fal has not billed yet)."
    }
}
