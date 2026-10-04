import Foundation
import AppKit
import SwiftUI
import ImageCratCore

/// Self tests for variation switching (task bar / Properties / Layers badge / menu / ⌥←→, history coalescing) and
/// usage tracking (usage log, balances against the mock, budget rules, CSV). Part of `LUMEN_SELFTEST_ONLY=genai`.
extension GenAISelfTest {
    static func tempDir(_ name: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-genai-selftest-\(ProcessInfo.processInfo.processIdentifier)-\(name)")
        try? FileManager.default.removeItem(at: u)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func near(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) < eps }

    // MARK: - Usage store (offline)

    static func testUsageStore() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 12))!
        let hour = 3600.0, day = 86_400.0
        let fill = "fal-ai/flux-pro/v1/fill"

        // self tests must never reach ~/Library/Application Support: in-memory unless LUMEN_SUPPORT_DIR points elsewhere
        if let o = ProcessInfo.processInfo.environment["LUMEN_SUPPORT_DIR"], !o.isEmpty {
            check(GenUsageStore.defaultDirectory?.path == URL(fileURLWithPath: o).path, "usage store: LUMEN_SUPPORT_DIR override honoured")
        } else {
            check(GenUsageStore.defaultDirectory == nil && GenUsageStore.isSelfTest, "usage store: self tests default to in-memory (never the real Application Support folder)")
        }
        check(GenUsageStore.shared.fileURL?.path.hasPrefix(FileManager.default.temporaryDirectory.path) == true, "usage store: this run logs to a temp folder (\(GenUsageStore.shared.fileURL?.lastPathComponent ?? "-"))")

        // --- migration of the old Generative History + monthly estimate
        let dirA = tempDir("usage-a")
        let longPrompt = String(repeating: "a very long prompt ", count: 20)
        let legacy = [
            GenHistoryEntry(date: now - 2 * day, feature: "fill", prompt: "a red kite", provider: "fal", model: fill, cost: 0.15, seconds: 4, images: 3, status: "ok"),
            GenHistoryEntry(date: now - day, feature: "generateImage", prompt: longPrompt, provider: "openai", model: "gpt-image-2.5-sunburst", cost: 0.30, seconds: 9, images: 3, status: "ok"),
            GenHistoryEntry(date: cal.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 9))!, feature: "fill", prompt: "", provider: "stability", model: "inpaint", cost: 0.5, seconds: 3, images: 3, status: "ok"),
        ]
        let a = GenUsageStore(directory: nil)
        defer { a.detach(); try? FileManager.default.removeItem(at: dirA) }
        a.calendar = cal
        a.configure(directory: dirA, legacyHistory: legacy, legacySpend: ["2026-09": 2.0, "2026-08": 0.5])
        check(a.records.count == 4 && a.records.contains { $0.feature == "earlier" && near($0.estimatedCost, 1.55) },
              "usage migration: 3 history entries + 1 carried-over row for spend the history no longer covers (\(a.records.count) records)")
        check(near(a.month(now: now).cost, 2.0) && a.month(now: now).generations == 2, "usage migration: month total preserved ($\(a.month(now: now).cost), \(a.month(now: now).generations) generations)")
        check(near(a.totals(from: cal.date(from: DateComponents(year: 2026, month: 8, day: 1)), to: a.monthStart(now)).cost, 0.5), "usage migration: previous month total preserved")
        check(a.records.allSatisfy { ($0.prompt?.count ?? 0) <= GenUsageStore.promptLimit + 1 } && a.records.contains { $0.prompt == "a red kite" }, "usage migration: prompts truncated to \(GenUsageStore.promptLimit) characters")
        a.flush(wait: true)
        let fileA = dirA.appendingPathComponent(GenUsageStore.fileName)
        let jsonA = (try? Data(contentsOf: fileA)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check(jsonA?["migratedLegacyHistory"] as? Bool == true && (jsonA?["records"] as? [Any])?.count == 4, "usage store: JSON file written to the configured folder (\(fileA.lastPathComponent))")
        let a2 = GenUsageStore(directory: nil)
        a2.calendar = cal
        a2.configure(directory: dirA, legacyHistory: legacy, legacySpend: ["2026-09": 2.0, "2026-08": 0.5])
        a2.detach()
        check(a2.records.count == 4 && near(a2.month(now: now).cost, 2.0), "usage migration: runs once (reload keeps \(a2.records.count) records, no duplicates)")

        // --- aggregation
        let dirB = tempDir("usage-b")
        let b = GenUsageStore(directory: nil)
        defer { b.detach(); try? FileManager.default.removeItem(at: dirB) }
        b.calendar = cal
        b.configure(directory: dirB)
        b.sessionStart = now - 1.5 * hour
        func rec(_ ago: Double, _ p: String, _ m: String, _ f: String, _ n: Int, _ est: Double, reported: Double? = nil, status: String = "ok", prompt: String? = nil) {
            b.add(GenUsageRecord(date: now - ago, provider: p, model: m, feature: f, images: n, estimatedCost: est, reportedCost: reported, seconds: 5, status: status, prompt: prompt))
        }
        rec(1 * hour, "fal", fill, "fill", 3, 0.15, prompt: "a \"quoted\", prompt")
        rec(2 * hour, "fal", fill, "fill", 3, 0.15)
        rec(3 * hour, "openai", "gpt-image-2.5-sunburst", "generateImage", 3, 0.12, reported: 0.0538)
        rec(1 * day, "bfl", "flux-pro-1.0-fill", "fill", 3, 0.15, reported: 0.15)
        rec(3 * day, "fal", "fal-ai/nano-banana-2/edit", "promptEdit", 1, 0.08)
        rec(20 * day, "fal", fill, "fill", 3, 0.15)
        rec(0.5 * hour, "fal", fill, "fill", 0, 0, status: "Rate limited by the provider.")
        rec(0.2 * hour, "fal", fill, "fill", 0, 0, status: "cancelled")
        let today = b.today(now: now), month = b.month(now: now)
        check(near(today.cost, 0.3538) && today.generations == 3 && today.images == 9 && today.failed == 1, "usage: today $\(today.cost), \(today.generations) generations, \(today.images) images, \(today.failed) failed")
        check(near(month.cost, 0.5838) && month.generations == 5, "usage: this month $\(month.cost), \(month.generations) generations (last month's excluded)")
        check(near(b.session.cost, 0.15) && b.session.generations == 1, "usage: session spend counts only records since launch ($\(b.session.cost))")
        check(near(b.totals().cost, 0.7338) && near(b.totals(from: b.monthStart(now), provider: "fal").cost, 0.38), "usage: all-time total and per-provider filter")
        let feat = b.byFeature(from: b.monthStart(now))
        check(feat.map(\.key) == ["fill", "promptEdit", "generateImage"] && feat[0].generations == 3 && near(feat[0].cost, 0.45) && near(feat[0].average, 0.15),
              "usage: breakdown by feature (count, cost, average) sorted by cost → \(feat.map { "\($0.key) \($0.generations)×" })")
        let models = b.byModel()
        check(models.first?.key == "fal:" + fill && models.first?.generations == 3 && near(models.first?.cost ?? 0, 0.45) && models.count == 4, "usage: breakdown by model (\(models.count) models, top \(models.first?.key ?? "-"))")
        let daily = b.daily(days: 30, now: now)
        check(daily.count == 30 && near(daily[29].cost, 0.3538) && near(daily[28].cost, 0.15) && near(daily[26].cost, 0.08) && near(daily[9].cost, 0.15) && near(daily.reduce(0) { $0 + $1.cost }, 0.7338),
              "usage: 30 daily buckets ending today (today $\(daily.last?.cost ?? -1), total $\(daily.reduce(0) { $0 + $1.cost }))")
        check(b.records.first(where: { $0.reportedCost != nil })?.cost == 0.0538, "usage: provider-reported cost wins over the estimate")

        // --- remaining: live → estimated → budget
        b.setCredit(GenManualCredit(amount: 20, date: b.dayStart(now - 2 * day)), for: .fal)
        let est = b.remaining(for: .fal)
        check(est?.kind == .estimated && near(est?.amount ?? 0, 19.70), "remaining: credit added $20 − tracked spend since then = $\(est?.amount ?? -1) (estimated)")
        check(b.overallRemaining(keyed: [.fal, .openai], budget: 50, now: now)?.kind == .estimated, "remaining: chip uses the last-used provider's estimate when no live balance exists")
        b.setBalance(GenBalance(provider: "fal", usd: 24.5, raw: 24.5, unit: "USD", account: "team", fetched: now), for: .fal)
        let live = b.overallRemaining(keyed: [.fal, .openai], budget: 50, now: now)
        check(live?.kind == .live && live?.amount == 24.5 && live?.provider == .fal, "remaining: live balance preferred over the estimate")
        let bud = b.overallRemaining(keyed: [.openai], budget: 50, now: now)
        check(bud?.kind == .budget && near(bud?.amount ?? 0, 50 - 0.5838), "remaining: falls back to budget − month spend ($\(bud?.amount ?? -1))")
        check(b.overallRemaining(keyed: [.openai], budget: 0, now: now) == nil, "remaining: nothing known → no “left” figure")
        func lvl(_ amount: Double, _ kind: GenRemainingKind) -> GenSpendLevel { GenUsageStore.level(GenRemaining(amount: amount, kind: kind), budget: 50, lowBalance: 5) }
        check(lvl(24.5, .live) == .normal && lvl(4, .live) == .warning && lvl(0.9, .estimated) == .critical && lvl(30, .budget) == .normal && lvl(8, .budget) == .warning && lvl(-1, .budget) == .critical,
              "levels: normal / amber (low balance, <20 % of budget) / red (nearly empty, over budget)")
        check(GenUsageUI.chipText(today: 0.42, remaining: GenRemaining(amount: 18.3, kind: .live)) == "AI $0.42 today · $18.30 left"
              && GenUsageUI.chipText(today: 0, remaining: nil) == "AI $0.00 today"
              && GenUsageUI.chipText(today: 1, remaining: GenRemaining(amount: 3, kind: .estimated)) == "AI $1.00 today · ≈$3.00 left"
              && GenUsageUI.chipText(today: 1, remaining: GenRemaining(amount: -2.5, kind: .budget)) == "AI $1.00 today · $2.50 over budget",
              "status chip text: “\(GenUsageUI.chipText(today: 0.42, remaining: GenRemaining(amount: 18.3, kind: .live)))”")

        // --- budget rules
        var s = GenAISettingsData()
        s.monthlyBudget = 0.60
        if case .warn(let m) = GenBudget.evaluate(estimate: 0.15, provider: .fal, settings: s, store: b, now: now) { check(m.contains("$0.60") && m.contains("$0.15"), "budget: over-budget generation → warning (“\(m.prefix(70))…”)") }
        else { check(false, "budget: over-budget generation → warning") }
        s.budgetHardStop = true
        if case .block = GenBudget.evaluate(estimate: 0.15, provider: .fal, settings: s, store: b, now: now) { check(true, "budget: hard stop blocks the generation") } else { check(false, "budget: hard stop blocks the generation") }
        check(GenBudget.evaluate(estimate: 0.01, provider: .fal, settings: s, store: b, now: now) == .allow, "budget: a generation that still fits is allowed with the hard stop on")
        s.budgetHardStop = false; s.warnOverBudget = false
        check(GenBudget.evaluate(estimate: 0.15, provider: .fal, settings: s, store: b, now: now) == .allow, "budget: warnings off → allowed")
        s = GenAISettingsData(); s.monthlyBudget = 50
        check(GenBudget.evaluate(estimate: 0.15, provider: .fal, settings: s, store: b, now: now) == .allow, "budget: within budget and balance → allowed")
        b.setBalance(GenBalance(provider: "stability", usd: 0.10, raw: 10, unit: "credits", fetched: now), for: .stability)
        if case .warn(let m) = GenBudget.evaluate(estimate: 0.15, provider: .stability, settings: s, store: b, now: now) { check(m.contains("Stability AI balance"), "budget: cost above the provider balance → warning (“\(m.prefix(80))…”)") }
        else { check(false, "budget: cost above the provider balance → warning") }
        let fm = ProviderRouter.shared.model("fal:" + fill)!
        check(GenBudget.estimateText(fm, count: 3) == "≈ $0.15 for 3 variations with fal.ai FLUX.1 Pro Fill" && GenBudget.count(for: .upscale, variations: 3) == 1, "estimate text: “\(GenBudget.estimateText(fm, count: 3))”")

        // --- CSV
        let csv = b.csv()
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)
        check(lines.count == b.records.count + 1 && lines.first.map(String.init) == GenUsageStore.csvHeader, "CSV: header + \(b.records.count) rows")
        check(csv.contains("\"a \"\"quoted\"\", prompt\"") && csv.contains(",0.1200,0.0538,0.0538,"), "CSV: quoting of commas/quotes, estimated + reported + effective cost columns")

        // --- persistence (records, credits, balances survive a relaunch)
        b.flush(wait: true)
        let b2 = GenUsageStore(directory: nil)
        b2.calendar = cal
        b2.configure(directory: dirB)
        b2.detach()
        check(b2.records.count == b.records.count && near(b2.month(now: now).cost, 0.5838) && b2.credits["fal"]?.amount == 20 && b2.balances["fal"]?.usd == 24.5 && Set(b2.records.map(\.id)) == Set(b.records.map(\.id)),
              "usage store: persistence round-trip (\(b2.records.count) records, credit and cached balance restored)")
        let raw = (try? String(contentsOf: dirB.appendingPathComponent(GenUsageStore.fileName), encoding: .utf8)) ?? ""
        check(!raw.contains("data:image") && !raw.contains("base64") && raw.contains("\"estimatedCost\""), "usage store: file holds no image data")

        // --- privacy toggle
        GenAISettings.shared.data.dontLogPrompts = true
        b.add(GenUsageRecord(date: now, provider: "fal", model: fill, feature: "fill", images: 1, estimatedCost: 0.05, prompt: "secret prompt"))
        check(b.records.last?.prompt == nil, "privacy: “Don't log prompts” keeps the prompt out of the log")
        GenAISettings.shared.data.dontLogPrompts = false
        b.removePrompts()
        check(b.records.allSatisfy { $0.prompt == nil }, "privacy: stored prompts can be removed")
        b.resetMonth(now: now)
        check(near(b.month(now: now).cost, 0) && near(b.totals().cost, 0.15), "reset: “Reset this month” drops this month's records only")
        b.clearAll()
        check(b.records.isEmpty, "reset: “Clear all” empties the log")

        // --- tolerant decoding
        let dirC = tempDir("usage-c")
        defer { try? FileManager.default.removeItem(at: dirC) }
        let odd = #"""
        {"version": 7, "future": {"x": 1},
         "records": [{"provider": "fal", "model": "m", "feature": "fill", "images": 3, "estimatedCost": 0.15, "date": "2026-09-14T10:00:00Z", "status": "ok", "extra": true},
                     "garbage",
                     {"provider": 5, "estimatedCost": "NaN?"},
                     {"date": 1789000000, "estimatedCost": 0.2}],
         "credits": {"fal": {"amount": 10, "date": "2026-09-01"}},
         "balances": "oops"}
        """#
        try? odd.write(to: dirC.appendingPathComponent(GenUsageStore.fileName), atomically: true, encoding: .utf8)
        let c = GenUsageStore(directory: nil)
        c.configure(directory: dirC)
        c.detach()
        check(c.records.count == 3 && near(c.totals().cost, 0.35) && c.credits["fal"]?.amount == 10 && c.balances.isEmpty,
              "usage store: tolerant decoding (unknown keys, bad rows, mixed date formats) → \(c.records.count) records, $\(c.totals().cost)")
        try? "not json {".write(to: dirC.appendingPathComponent(GenUsageStore.fileName), atomically: true, encoding: .utf8)
        let c2 = GenUsageStore(directory: nil)
        c2.configure(directory: dirC)
        c2.detach()
        let aside = ((try? FileManager.default.contentsOfDirectory(atPath: dirC.path)) ?? []).contains { $0.hasPrefix("genai-usage.corrupt-") }
        check(c2.records.isEmpty && aside, "usage store: an unreadable file is set aside, not overwritten")

        check(near(GenDailyChart.niceMax(0.37), 0.4) && GenDailyChart.niceMax(1.2) == 1.5 && GenDailyChart.niceMax(5.12) == 6 && GenDailyChart.niceMax(0) == 1, "chart: “nice” axis maximum")
        check(GenBalanceService.differenceNote(billed: 1.16, local: 1.16) == nil && GenBalanceService.differenceNote(billed: 1.16, local: 0.30)?.contains("more than ImageCrat estimated") == true,
              "fal billed vs local: note only when they differ")
    }

    // MARK: - Balances / fal Platform API (mock)

    static func testBalances(_ base: String) {
        let store = GenUsageStore.shared
        let svc = GenBalanceService.shared
        func refresh(_ p: ProviderID) { _ = sync { await svc.refreshAsync(p); return true } }

        // fal with a normal key: 403 → graceful fallback
        control(base, "/__reset")
        GenAIKeyOverrides.falAdmin = nil
        refresh(.fal)
        var l = log(base).filter { $0.path.hasPrefix("/falapi/") }
        check(svc.falNeedsAdmin && svc.notes[.fal] == GenBalanceService.falAdminMessage && store.balances["fal"] == nil && svc.falUsage == nil,
              "fal billing with a non-admin key: 403 → “\(svc.notes[.fal] ?? "")”, local tracking")
        check(l.count == 1 && l.first?.path == "/falapi/v1/account/billing" && l.first?.query == "expand=credits" && l.first?.header("Authorization") == "Key test-fal-key",
              "fal billing request: GET /v1/account/billing?expand=credits with Authorization: Key (\(l.count) call)")
        svc.refresh(.fal)     // automatic refreshes stop once the key is known to lack the scope
        _ = wait(0.3) { false }
        check(log(base).filter { $0.path.hasPrefix("/falapi/") }.count == 1, "fal billing: no automatic retry with a key known to lack admin scope")

        // fal with an admin key: balance + paginated usage
        control(base, "/__reset")
        GenAIKeyOverrides.falAdmin = "test-fal-admin-key"
        refresh(.fal)
        l = log(base).filter { $0.path.hasPrefix("/falapi/") }
        let bal = store.balances["fal"]
        check(!svc.falNeedsAdmin && bal?.usd == 24.5 && bal?.unit == "USD" && bal?.account == "mock-team" && svc.notes[.fal] == nil, "fal billing with an admin key: live balance $\(bal?.usd ?? -1) (\(bal?.account ?? "?"))")
        check(store.remaining(for: .fal)?.kind == .live, "fal: remaining is reported as live")
        let usageReqs = l.filter { $0.path == "/falapi/v1/models/usage" }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let startStr = df.string(from: store.monthStart(Date()))
        check(usageReqs.count == 2 && usageReqs.allSatisfy { $0.header("Authorization") == "Key test-fal-admin-key" }, "fal usage: 2 pages fetched with the admin key (\(usageReqs.count))")
        if let q = usageReqs.first?.query {
            check(q.contains("expand=summary&expand=time_series") && q.contains("start=\(startStr)") && q.contains("timeframe=day") && !q.contains("cursor="),
                  "fal usage request: repeated expand, start=\(startStr), timeframe=day (\(q))")
        }
        check(usageReqs.last?.query.contains("cursor=page2") == true, "fal usage: next_cursor followed while has_more")
        if let u = svc.falUsage {
            check(u.pages == 2 && u.rows.count == 3 && near(u.total, 1.16) && u.rows.first?.endpoint == "fal-ai/flux-pro/v1/fill" && u.rows.first?.quantity == 12 && near(u.rows.first?.unitPrice ?? 0, 0.05),
                  "fal usage: summary by endpoint (\(u.rows.count) endpoints, billed $\(u.total), not double-counted across pages)")
            check(u.days.count == 3 && near(u.days.reduce(0) { $0 + $1.cost }, 1.16) && near(u.days.last?.cost ?? 0, 0.16), "fal usage: daily time series merged across pages (\(u.days.count) days)")
        } else { check(false, "fal usage: parsed") }
        check(!log(base).contains { $0.query.contains("test-fal") }, "fal platform API: keys never appear in URLs")

        // Stability / BFL credits (1 credit = $0.01)
        control(base, "/__reset")
        refresh(.stability); refresh(.bfl)
        l = log(base)
        check(near(store.balances["stability"]?.usd ?? 0, 0.425) && store.balances["stability"]?.raw == 42.5 && l.contains { $0.path == "/stability/v1/user/balance" && $0.header("Authorization") == "Bearer test-stability-key" },
              "stability balance: GET /v1/user/balance → 42.5 credits = $\(store.balances["stability"]?.usd ?? -1)")
        check(near(store.balances["bfl"]?.usd ?? 0, 12.34) && l.contains { $0.path == "/bfl/v1/credits" && $0.header("x-key") == "test-bfl-key" }, "bfl balance: GET /v1/credits → 1234 credits = $\(store.balances["bfl"]?.usd ?? -1)")
        check(!GenBalanceService.supportsLive(.openai) && !GenBalanceService.supportsLive(.gemini) && !GenBalanceService.supportsLive(.replicate) && GenBalanceService.localOnlyReason(.openai) != nil,
              "openai / gemini / replicate: no balance API → local tracking only")
        refresh(.openai)
        check(log(base).count == l.count, "providers without a balance API are never queried")

        // rate limit of automatic refreshes; forced refresh goes through
        let n0 = log(base).filter { $0.path == "/stability/v1/user/balance" }.count
        svc.refresh(.stability)
        _ = wait(0.3) { false }
        let n1 = log(base).filter { $0.path == "/stability/v1/user/balance" }.count
        svc.refresh(.stability, force: true)
        _ = wait(5) { log(base).filter { $0.path == "/stability/v1/user/balance" }.count > n1 }
        _ = wait(5) { !svc.refreshing.contains(.stability) }
        let n2 = log(base).filter { $0.path == "/stability/v1/user/balance" }.count
        check(n1 == n0 && n2 == n0 + 1, "balance refresh: automatic refreshes are rate-limited, Refresh forces one (\(n0) → \(n1) → \(n2))")

        // failures: a small note, cached value kept, nothing thrown
        let saved = GenHTTP.overrides[.bfl]
        GenHTTP.overrides[.bfl] = "http://127.0.0.1:9"
        refresh(.bfl)
        GenHTTP.overrides[.bfl] = saved
        check(svc.notes[.bfl]?.hasPrefix("Couldn't refresh") == true && near(store.balances["bfl"]?.usd ?? 0, 12.34), "balance refresh failure → note “\(svc.notes[.bfl]?.prefix(48) ?? "")…”, last value kept")
        refresh(.bfl)
        check(svc.notes[.bfl] == nil, "balance refresh: note cleared after the next success")
        control(base, "/__reset")
        control(base, "/__scenario", ["name": "auth", "count": 1])
        refresh(.stability)
        control(base, "/__scenario", ["name": "ok", "count": 0])
        check(store.balances["stability"] == nil && svc.notes[.stability]?.contains("rejected") == true, "balance with a rejected key → cached balance dropped, note shown")
        refresh(.stability)

        // cache survives a relaunch
        store.flush(wait: true)
        if let dir = store.directory {
            let again = GenUsageStore(directory: nil)
            again.configure(directory: dir)
            again.detach()
            check(again.balances["fal"]?.usd == 24.5 && again.balances["fal"]?.fetched != nil, "balances: last value + timestamp cached in the usage file")
        }
    }

    // MARK: - Pipeline → usage log (mock)

    static func testUsageIntegration(_ base: String) {
        let store = GenUsageStore.shared
        // fal: no cost in the response → estimate only, one call for 3 images
        var before = store.records.count
        let (_, _, _, _, e1) = region(base, "fal:fal-ai/flux-pro/v1/fill")
        let r1 = store.records.last
        check(e1 == nil && store.records.count == before + 1 && r1?.provider == "fal" && r1?.model == "fal-ai/flux-pro/v1/fill" && r1?.feature == "fill" && r1?.images == 3 && r1?.calls == 1
              && near(r1?.estimatedCost ?? 0, 0.15) && r1?.reportedCost == nil && r1?.status == "ok" && (r1?.seconds ?? 0) > 0 && r1?.prompt == "a hot air balloon",
              "usage log: fal job → 1 record (3 images, 1 call, est. $\(r1?.estimatedCost ?? -1), no reported cost)")
        check(GenJobs.shared.lastEstimate == "≈ $0.15 for 3 variations with fal.ai FLUX.1 Pro Fill", "cost shown before generating: “\(GenJobs.shared.lastEstimate ?? "")”")
        // BFL reports credits → reconciled record keeps both numbers
        before = store.records.count
        let (_, _, _, _, e2) = region(base, "bfl:flux-pro-1.0-fill")
        let r2 = store.records.last
        let list = (ProviderRouter.shared.model("bfl:flux-pro-1.0-fill")?.pricePerImage ?? 0) * 3
        check(e2 == nil && store.records.count == before + 1 && near(r2?.reportedCost ?? 0, 0.15) && near(r2?.estimatedCost ?? 0, list) && r2?.calls == 3 && near(r2?.cost ?? 0, 0.15),
              "usage log: BFL-reported cost reconciled (reported $\(r2?.reportedCost ?? -1), list estimate $\(r2?.estimatedCost ?? -1), 3 calls)")
        // OpenAI: cost from usage tokens counts as reported
        let (_, _, _, _, e3) = region(base, "openai:gpt-image-2.5-sunburst")
        check(e3 == nil && near(store.records.last?.reportedCost ?? 0, (1500 * 30 + 1100 * 8 + 100 * 5) / 1_000_000.0), "usage log: OpenAI token-based cost stored as reported ($\(store.records.last?.reportedCost ?? -1))")
        // failures are logged with zero cost
        control(base, "/__reset")
        control(base, "/__scenario", ["name": "moderation", "count": 1])
        let d = testDoc()
        _ = job { GenPipeline.runRegion(d, feature: .fill, prompt: "x", sel: d.state.selection, modelOverride: "stability:inpaint") }
        check(store.records.last?.ok == false && store.records.last?.cost == 0 && store.records.last?.images == 0, "usage log: failed job recorded with status and no cost")
        check(store.session.cost > 0.4 && store.session.generations >= 3 && store.session.failed >= 1, "usage: session totals ($\(String(format: "%.3f", store.session.cost)), \(store.session.generations) generations, \(store.session.failed) failed)")

        // the running job's HUD row carries the estimate (task-local job id)
        do {
            control(base, "/__reset")
            control(base, "/__scenario", ["name": "slow", "count": 1000])
            let ds = testDoc()
            GenJobs.shared.lastError = nil
            GenPipeline.runRegion(ds, feature: .fill, prompt: "x", sel: ds.state.selection, modelOverride: "fal:fal-ai/flux-pro/v1/fill")
            let shown = wait(5) { GenJobs.shared.active.first?.estimate.isEmpty == false }
            check(shown && GenJobs.shared.active.first?.estimate == "≈ $0.15 for 3 variations with fal.ai FLUX.1 Pro Fill", "HUD: running job shows “\(GenJobs.shared.active.first?.estimate ?? "")”")
            if let j = GenJobs.shared.active.first { GenJobs.shared.cancel(j.id) }
            _ = wait(10) { GenJobs.shared.active.isEmpty }
            control(base, "/__scenario", ["name": "ok", "count": 0])
            check(store.records.last?.status == "cancelled" && store.records.last?.cost == 0, "usage log: cancelled job recorded without cost")
        }

        // budget: hard stop refuses before anything is sent; warning mode proceeds in headless runs
        let savedSettings = GenAISettings.shared.data
        GenAISettings.shared.data.monthlyBudget = 0.01
        GenAISettings.shared.data.budgetHardStop = true
        control(base, "/__reset")
        let d2 = testDoc()
        let err = job { GenPipeline.runRegion(d2, feature: .fill, prompt: "x", sel: d2.state.selection, modelOverride: "fal:fal-ai/flux-pro/v1/fill") }
        check(err?.contains("monthly Generative AI budget") == true && log(base).filter { $0.method == "POST" }.isEmpty && d2.state.generative.isEmpty, "budget hard stop: generation refused, nothing sent (“\(err?.prefix(60) ?? "")…”)")
        GenAISettings.shared.data.budgetHardStop = false
        GenBudget.lastWarning = nil
        let err2 = job { GenPipeline.runRegion(d2, feature: .fill, prompt: "x", sel: d2.state.selection, modelOverride: "fal:fal-ai/flux-pro/v1/fill") }
        check(err2 == nil && GenBudget.lastWarning?.contains("would exceed") == true && d2.state.generative.count == 1, "budget warning: raised (dialog skipped in headless mode) and the job runs")
        GenAISettings.shared.data = savedSettings
        GenAISettings.shared.data.variations = 3
        let hint = GenCostHint.text(feature: .fill, model: "fal:fal-ai/flux-pro/v1/fill")
        check(hint?.0.hasPrefix("≈ $0.15 for 3 variations with fal.ai FLUX.1 Pro Fill · $24.50 left") == true, "dialog cost hint: “\(hint?.0 ?? "")”")
    }

    // MARK: - Variation switching (mock)

    static func pixel(_ b: PixelBuffer, _ x: Int, _ y: Int) -> [UInt8] {
        guard x >= 0, y >= 0, x < b.width, y < b.height else { return [] }
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        let o = y * b.bytesPerRow + x * 4
        return [p[o], p[o + 1], p[o + 2], p[o + 3]]
    }

    static func menuAction(_ title: String) -> MenuItemSpec? { MenuRegistry.items(for: "Layer").first { $0.title == title && $0.submenu == "Generative" } }

    static func keyEvent(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
    }

    /// Generative Fill with 3 variations, then every entry point for switching; pixels, mask, position and undo are checked.
    static func testVariationSwitching(_ base: String, _ out: URL) -> Document? {
        control(base, "/__reset")
        let d = testDoc()
        AppModel.shared.add(d)
        let sel = d.state.selection!
        GenAISettings.shared.data.routing["fill"] = "fal:fal-ai/flux-pro/v1/fill"
        // WorkspaceManager restores floating panel windows when first used: leave it alone if this machine's dev workspace has any.
        let wsOK = UserDefaults.standard.data(forKey: "Lumen.Workspace").flatMap { try? JSONDecoder().decode(Workspace.self, from: $0) }?.floating.isEmpty ?? true
        let tick0 = wsOK ? WorkspaceManager.shared.focusRequest.tick : 0
        let err = job { GenAIActions.generativeFill(prompt: "a hot air balloon") }
        GenAISettings.shared.data.routing = [:]
        guard err == nil, let id = d.activeLayerID, let inf0 = d.state.generative[id], inf0.variations.count == 3 else {
            check(false, "variation UX: Generative Fill produced 3 variations (\(err ?? "no generative layer"))")
            return d
        }
        check(d.state.layer(id)?.name == "a hot air balloon" && inf0.selected == 0, "variation UX: Generative Fill added an active generative layer with 3 variations")
        if wsOK { check(WorkspaceManager.shared.focusRequest.tick == tick0, "variation UX: the Properties panel is not revealed in headless mode") }
        check(d.state.selection != nil && TaskBarContext.of(d) == .generative, "task bar: generative bar right after the fill, even while the selection still exists")
        check(TaskBarContext.generative.actions == ["Previous Variation", "Next Variation", "Variations", "Generate"], "task bar: generative actions \(TaskBarContext.generative.actions)")

        let b = sel.opaqueBounds()!
        let cx = b.x + b.width / 2, cy = b.y + b.height / 2
        let vars = inf0.variations
        let lx = cx - inf0.rect.x, ly = cy - inf0.rect.y
        let px = vars.map { pixel($0, lx, ly) }
        check(Set(px).count == 3, "variation UX: the three variations differ at the selection centre (\(px.map { $0.prefix(3).map(String.init).joined(separator: ",") }))")
        func shown() -> [UInt8] { pixel(GenImaging.composite(d.state, rect: d.state.canvasRect), cx, cy) }
        func close(_ a: [UInt8], _ b: [UInt8]) -> Bool { a.count == b.count && !a.isEmpty && zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 3 } }
        func isShowing(_ i: Int) -> Bool { d.state.generative[id]?.selected == i && d.state.layer(id)?.raster?.buffer === vars[i] && close(shown(), px[i]) }
        check(isShowing(0), "variation UX: canvas shows variation 1 (\(shown()))")

        // the user adds a mask, moves the layer and lowers its opacity: switching must not touch any of that
        let mask = LayerMask.reveal(width: d.state.width, height: d.state.height)
        d.updateLayer(id) { $0.mask = mask; $0.opacity = 0.8; $0.translate(dx: 7, dy: -5) }
        d.commit("User edits")
        let movedOrigin = d.state.layer(id)!.raster!.origin
        func intact() -> Bool {
            guard let l = d.state.layer(id) else { return false }
            return l.mask?.buffer === mask.buffer && l.raster?.origin == movedOrigin && l.opacity == 0.8 && d.state.selection === sel
        }
        let h0 = d.history.count

        // 1. Contextual Task Bar arrows
        GenVariations.coalesceWindow = 30
        TaskBarContext.perform("Next Variation")
        check(d.state.generative[id]?.selected == 1 && d.state.layer(id)?.raster?.buffer === vars[1], "task bar ›: variation 2 shown")
        TaskBarContext.perform("Previous Variation")
        TaskBarContext.perform("Previous Variation")
        check(d.state.generative[id]?.selected == 2 && d.state.layer(id)?.raster?.buffer === vars[2], "task bar ‹: wraps around to variation 3")
        // 2. Thumbnail click (Properties grid / task-bar popover / Layers badge popover all call this)
        GenVariations.select(d, layerID: id, index: 1)
        check(d.state.generative[id]?.selected == 1 && d.state.layer(id)?.raster?.buffer === vars[1], "thumbnail click (Properties / popovers): variation 2 shown")
        // 3. Layer ▸ Generative menu
        check(menuAction("Next Variation (⌥→)") != nil && menuAction("Previous Variation (⌥←)") != nil && menuAction("Generate More") != nil && menuAction("Flatten to Normal Layer") != nil,
              "menu: Layer ▸ Generative has Next / Previous Variation, Generate More, Flatten")
        check(menuAction("Next Variation (⌥→)")?.enabled() == true, "menu: Next Variation enabled for the active generative layer")
        menuAction("Next Variation (⌥→)")?.action()
        check(d.state.generative[id]?.selected == 2, "menu Next Variation: variation 3 shown")
        menuAction("Previous Variation (⌥←)")?.action()
        check(d.state.generative[id]?.selected == 1, "menu Previous Variation: variation 2 shown")
        // 4. ⌥→ / ⌥← (KeyRouter hook)
        if let right = keyEvent(124, [.option]), let left = keyEvent(123, [.option]), let plain = keyEvent(124, []), let cmd = keyEvent(124, [.option, .command]) {
            check(GenVariations.handleKey(right) && d.state.generative[id]?.selected == 2, "⌥→: next variation")
            check(GenVariations.handleKey(left) && GenVariations.handleKey(left) && d.state.generative[id]?.selected == 0, "⌥←: previous variation")
            check(!GenVariations.handleKey(plain) && !GenVariations.handleKey(cmd) && d.state.generative[id]?.selected == 0, "plain → and ⌘⌥→ are left alone (nudge / other shortcuts)")
            AppModel.shared.textEditingActive = true
            check(!GenVariations.handleKey(right), "⌥→ is ignored while text is being edited")
            AppModel.shared.textEditingActive = false
            let other = d.state.layers.first!.id
            d.selectLayer(other)
            check(!GenVariations.handleKey(right) && TaskBarContext.of(d) == .selection && menuAction("Next Variation (⌥→)")?.enabled() == false, "⌥→ / menu / task bar are inert on a non-generative layer")
            d.selectLayer(id)
        } else { check(false, "⌥ arrow key events") }
        // 5. Layers-panel context menu (step) — back to variation 3
        GenVariations.step(d, layerID: id, by: -1)
        check(d.state.generative[id]?.selected == 2 && d.state.layer(id)?.raster?.buffer === vars[2], "layer context menu Previous Variation: variation 3 shown")

        // pixels, mask, position
        let expected = pixel(vars[2], lx, ly)
        let comp = GenImaging.composite(d.state, rect: d.state.canvasRect)
        let at = pixel(comp, cx + 7, cy - 5)
        var ref = d.state; ref.updateLayer(id) { $0.raster = RasterContent(buffer: vars[0], origin: movedOrigin) }
        let atV0 = pixel(GenImaging.composite(ref, rect: ref.canvasRect), cx + 7, cy - 5)
        check(at != atV0 && expected != px[0], "variation UX: canvas pixels changed to the chosen variation (\(atV0.prefix(3).map { $0 }) → \(at.prefix(3).map { $0 }))")
        check(intact(), "variation UX: mask, position (\(movedOrigin.x),\(movedOrigin.y)), opacity and selection untouched by 10 switches")
        SelfTest.save(d.state, "genai_variation_3", out)

        // history: the whole run of switches is one step; undo returns to where it started
        check(d.history.count == h0 + 1 && d.history.last?.name == "Select Variation", "history: 10 rapid switches coalesced into 1 step (\(d.history.count - h0) added)")
        d.undo()
        check(d.state.generative[id]?.selected == 0 && d.state.layer(id)?.raster?.buffer === vars[0] && intact(), "undo: back to variation 1, mask/position intact")
        d.redo()
        check(d.state.generative[id]?.selected == 2 && d.state.layer(id)?.raster?.buffer === vars[2], "redo: variation 3 again")
        // another edit in between starts a new step; outside the time window every switch is its own step
        d.updateLayer(id) { $0.name = "Balloon" }; d.commit("Rename Layer")
        let h1 = d.history.count
        GenVariations.step(d, layerID: id, by: 1); GenVariations.step(d, layerID: id, by: 1)
        check(d.history.count == h1 + 1, "history: a switch after another edit starts a new (again coalescing) step")
        GenVariations.coalesceWindow = 0
        let h2 = d.history.count
        GenVariations.step(d, layerID: id, by: 1); GenVariations.step(d, layerID: id, by: 1)
        check(d.history.count == h2 + 2, "history: switches further apart than the window stay separate steps")
        GenVariations.coalesceWindow = 3
        let h3 = d.history.count
        GenVariations.select(d, layerID: id, index: d.state.generative[id]!.selected)
        check(d.history.count == h3, "history: re-selecting the shown variation adds nothing")

        // Generate More (menu) appends and shows the first new one at the layer's current position
        menuAction("Generate More")?.action()
        let done = wait(60) { GenJobs.shared.active.isEmpty }
        let inf1 = d.state.generative[id]
        check(done && inf1?.variations.count == 6 && inf1?.selected == 3 && d.state.layer(id)?.raster?.origin == movedOrigin && intact(), "Generate More: 3 more variations (now \(inf1?.variations.count ?? 0)), layer position kept")

        // housekeeping
        GenVariations.select(d, layerID: id, index: 4)
        GenVariations.deleteCurrent(d, layerID: id)
        check(d.state.generative[id]?.variations.count == 5 && d.state.generative[id]?.selected == 4 && intact(), "Delete variation: 5 left, next one shown")
        let kept = d.state.layer(id)?.raster?.buffer
        GenVariations.keepOnlyCurrent(d, layerID: id)
        check(d.state.generative[id]?.variations.count == 1 && d.state.generative[id]?.variations.first === kept && d.state.layer(id)?.raster?.buffer === kept, "Keep only this one: 1 variation left, pixels unchanged")
        d.undo()
        check(d.state.generative[id]?.variations.count == 5, "Keep only this one: undoable")
        d.redo()
        let copy = d.state.layer(id)?.raster?.buffer
        GenVariations.flatten(d, layerID: id)
        check(d.state.generative[id] == nil && d.state.layer(id)?.raster?.buffer === copy && TaskBarContext.of(d) == .selection && !GenVariations.handleKey(keyEvent(124, [.option])!),
              "Flatten to normal layer: metadata dropped, pixels kept, generative UI gone")
        d.undo()
        check(d.state.generative[id] != nil, "Flatten: undoable")
        d.undo()    // back to several variations (UI snapshots)

        // Workspace reveal (docked → tab selected; closed → docked + selected).
        if wsOK {
            let ws = WorkspaceManager.shared
            let before = ws.current
            ws.current = .essentials
            let t = ws.focusRequest.tick
            ws.reveal("properties")
            check(ws.focusRequest.id == "properties" && ws.focusRequest.tick == t + 1 && ws.current == .essentials, "Workspace.reveal: docked panel → its tab is selected, nothing moves")
            ws.close("properties")
            ws.reveal("properties")
            check(ws.current.primary.last?.contains("properties") == true && ws.focusRequest.id == "properties" && ws.focusRequest.tick == t + 2, "Workspace.reveal: closed panel → docked and selected")
            ws.reveal(GenUsageUI.panelID)
            check(ws.isVisible(GenUsageUI.panelID) && PanelRegistry.def(GenUsageUI.panelID)?.title == "AI Usage", "AI Usage panel registered and revealed by the status chip")
            ws.current = before
        } else {
            print("SKIP genai: Workspace.reveal (floating panels in the saved dev workspace)")
        }
        return d
    }

    // MARK: - UI snapshots

    static func snapUX<V: View>(_ v: V, _ name: String, _ size: CGSize, _ out: URL) {
        let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height, alignment: .topLeading).background(Theme.panelBG).environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        print("wrote \(name)")
    }

    /// LUMEN_SELFTEST_UI=1: usage panel with data, status chip states, task bar variation controls, Properties section, Layers badge.
    static func uxSnapshots(_ base: String, _ out: URL, doc d: Document?) {
        let store = GenUsageStore.shared
        let svc = GenBalanceService.shared
        // a month of plausible usage
        let models: [(String, String, String, Double)] = [("fal", "fal-ai/flux-pro/v1/fill", "fill", 0.15), ("fal", "fal-ai/nano-banana-2/edit", "promptEdit", 0.24), ("fal", "fal-ai/topaz/upscale/image", "upscale", 0.08),
                                                         ("stability", "erase", "remove", 0.15), ("openai", "gpt-image-2.5-sunburst", "generateImage", 0.16), ("fal", "fal-ai/flux-pro/v1/fill", "expand", 0.15)]
        var seed: UInt64 = 42
        func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        for dayAgo in 0..<30 {
            let count = [0, 2, 5, 1, 0, 3, 8, 4, 0, 0, 6, 2, 1, 9, 3, 0, 4, 2, 7, 1, 0, 5, 3, 2, 0, 11, 4, 2, 6, 3][dayAgo]
            for k in 0..<count {
                let m = models[rnd(models.count)]
                store.add(GenUsageRecord(date: Date().addingTimeInterval(-Double(dayAgo) * 86_400 - Double(k) * 600 - 3600), provider: m.0, model: m.1, feature: m.2,
                                         images: m.2 == "upscale" ? 1 : 3, estimatedCost: m.3, seconds: 6, status: "ok", prompt: "snapshot"))
            }
        }
        store.setCredit(GenManualCredit(amount: 10, date: store.monthStart(Date())), for: .openai)
        let saved = GenAISettings.shared.data
        GenAISettings.shared.data.monthlyBudget = 40
        let keyed: [ProviderID] = [.fal, .stability, .openai, .gemini]
        snapUX(GenUsagePanel(keyedOverride: keyed), "ui_genai_usage_panel", CGSize(width: 300, height: 1420), out)
        snapUX(GenUsagePanel(keyedOverride: keyed), "ui_genai_usage_panel_top", CGSize(width: 300, height: 620), out)
        snapUX(StatusBar(), "ui_genai_statusbar", CGSize(width: 900, height: 22), out)
        snapUX(HStack { GenUsageChip(keyedOverride: [.fal]); Spacer() }.padding(6), "ui_genai_chip_normal", CGSize(width: 300, height: 30), out)
        // low balance (amber), then over budget (red)
        let falBalance = store.balances["fal"]
        store.setBalance(GenBalance(provider: "fal", usd: 3.2, raw: 3.2, unit: "USD", account: "mock-team"), for: .fal)
        snapUX(HStack { GenUsageChip(keyedOverride: [.fal]); Spacer() }.padding(6), "ui_genai_chip_low", CGSize(width: 300, height: 30), out)
        snapUX(VStack { GenBalanceCard(provider: .fal) }.padding(10), "ui_genai_balance_low", CGSize(width: 300, height: 110), out)
        GenAISettings.shared.data.monthlyBudget = 5
        store.setBalance(nil, for: .fal)
        snapUX(HStack { GenUsageChip(keyedOverride: [.fal]); Spacer() }.padding(6), "ui_genai_chip_over_budget", CGSize(width: 300, height: 30), out)
        snapUX(VStack { GenBudgetBar(store: store, settings: GenAISettings.shared) }.padding(10), "ui_genai_budget_over", CGSize(width: 300, height: 70), out)
        // fal without an admin key
        svc.falNeedsAdmin = true
        svc.notes[.fal] = GenBalanceService.falAdminMessage
        snapUX(VStack { GenBalanceCard(provider: .fal) }.padding(10), "ui_genai_balance_fal_needs_admin", CGSize(width: 300, height: 200), out)
        svc.falNeedsAdmin = false
        svc.notes[.fal] = nil
        store.setBalance(falBalance, for: .fal)
        GenAISettings.shared.data.monthlyBudget = 40
        snapUX(VStack(alignment: .leading) { GenAIPreferencesSectionSnapshot(tab: 2) }.padding(10), "ui_genai_prefs_budget", CGSize(width: 380, height: 470), out)
        snapUX(VStack(alignment: .leading) { FalAdminKeyRow() }.padding(10), "ui_genai_prefs_fal_admin_key", CGSize(width: 360, height: 130), out)
        snapUX(GenDialog(kind: .fill), "ui_genai_fill_dialog_cost", CGSize(width: 400, height: 250), out)
        GenJobs.shared.active = [GenJobs.Job(title: "Generative Fill", detail: "Variation 2/3: fal: generating… step 10/28", fraction: 0.4, estimate: "≈ $0.15 for 3 variations with fal.ai FLUX.1 Pro Fill")]
        snapUX(GenHUDView(), "ui_genai_hud_estimate", CGSize(width: 380, height: 74), out)
        GenJobs.shared.active = []
        snapUX(GenHistoryPanel(), "ui_genai_history_usage_link", CGSize(width: 300, height: 200), out)
        GenAISettings.shared.data = saved
        GenAISettings.shared.data.variations = 3

        // variation controls on a real generative layer (3 variations, the 2nd shown)
        guard let d, let id = d.state.generative.first?.key else { return }
        AppModel.shared.activeDocumentID = d.id
        d.selectLayer(id)
        d.editTarget = .content
        while (d.state.generative[id]?.variations.count ?? 0) > 3 { GenVariations.delete(d, layerID: id, index: 3) }
        GenVariations.select(d, layerID: id, index: 1)
        snapUX(HStack { ContextualTaskBar(doc: d, context: TaskBarContext.of(d)) }.padding(8), "ui_genai_taskbar_variations", CGSize(width: 660, height: 50), out)
        let sel = d.state.selection
        d.state.selection = nil
        snapUX(HStack { ContextualTaskBar(doc: d, context: TaskBarContext.of(d)) }.padding(8), "ui_genai_taskbar_variations_nosel", CGSize(width: 480, height: 50), out)
        d.state.selection = sel
        snapUX(GenVariationPopover(doc: d, layerID: id), "ui_genai_variations_popover", CGSize(width: 344, height: 190), out)
        snapUX(PropertiesPanel(), "ui_genai_properties_variations", CGSize(width: 300, height: 640), out)
        d.editTarget = .mask
        snapUX(PropertiesPanel(), "ui_genai_properties_mask_target", CGSize(width: 300, height: 640), out)
        d.editTarget = .content
        snapUX(LayersPanel(), "ui_genai_layers_badge", CGSize(width: 300, height: 260), out)
    }
}
