import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Keeps every external fact current instead of pinned to what was bundled at build time:
/// - models.dev (capabilities, limits, prices for ~230 providers incl. coding plans and relays)
/// - Reasonix's verified endpoint catalog and ZCode's model rules (re-pulled from GitHub)
/// - benchmark leaderboards (LABBench2, Terminal-Bench-Science, PostTrainBench, Riemann-bench)
/// Runs at app start and then daily; every result is validated before it replaces the old one.
public enum CatalogRefresher {
    public static var dir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/catalog") }

    public static let upstream: [(file: String, url: String)] = [
        ("provider_protocol_endpoints.json", "https://raw.githubusercontent.com/futureflowtech/reasonix/main/internal/config/provider_protocol_endpoints.json"),
        ("zcode-builtin.json", "https://raw.githubusercontent.com/zai-org/ZCode/main/config/provider/zcode-builtin.json"),
    ]

    public struct Report: Sendable { public var lines: [String] }

    /// Refreshes everything at once (the catalogs and every leaderboard in parallel), each source capped
    /// in time so one slow page or silent model cannot hold the rest. `onLine` gets each result as it lands.
    public static func refreshAll(http: HTTPStreaming = URLSessionStreaming(), extractor: LLMProvider?, extractorModel: String?,
                                  perSource: TimeInterval = 120, onLine: (@Sendable (String) -> Void)? = nil) async -> Report {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let collected = LockedLines(onLine)
        await withTaskGroup(of: Void.self) { g in
            g.addTask {
                do { collected.add("models.dev: " + L10n.s("%@ providers", String(try await withTimeLimit(perSource) { try await ModelsDevCatalog.shared.refresh(http: http) }))) }
                catch { collected.add("models.dev: " + L10n.s("kept cached copy (%@)", error.localizedDescription.truncated(120))) }
            }
            for (file, url) in upstream {
                g.addTask {
                    do {
                        var r = URLRequest(url: URL(string: url)!)
                        r.timeoutInterval = 60
                        let (s, d) = try await http.send(r)
                        guard s < 300 else { throw ProviderError.http(status: s, body: "") }
                        // Validate with the same parsers the loader uses before replacing anything.
                        if file == "zcode-builtin.json" {
                            guard try !ModelRules.parse(d).rules.isEmpty else { throw ProviderError.protocolError("no model rules") }
                        } else {
                            guard try !JSONDecoder().decode([String: [String: ProviderCatalog.Route]].self, from: d).isEmpty else { throw ProviderError.protocolError("empty") }
                        }
                        try d.write(to: dir.appendingPathComponent(file))
                        collected.add("\(file): " + L("updated"))
                    } catch { collected.add("\(file): " + L10n.s("kept previous (%@)", error.localizedDescription.truncated(120))) }
                }
            }
            if let extractor, let extractorModel {
                g.addTask {
                    _ = await refreshBenchmarks(http: http, extractor: extractor, model: extractorModel, perSource: perSource, onLine: { collected.add($0) })
                }
            }
        }
        return Report(lines: collected.all)
    }

    /// Re-reads each leaderboard page (all at once). A model extracts `{"model name": score}` pairs; a row
    /// is kept only if its score literally appears in the fetched page text, so a hallucinated row cannot
    /// enter the snapshot. A benchmark is replaced only when ≥3 rows survive.
    public static func refreshBenchmarks(http: HTTPStreaming, extractor: LLMProvider, model: String, perSource: TimeInterval = 120,
                                         onLine: (@Sendable (String) -> Void)? = nil) async -> [String] {
        var snap = BenchmarkSnapshot.current()
        let fetcher = WebSearchClient(config: WebSearchConfig(), secrets: EnvironmentSecretStore(), http: http)
        let results = await withTaskGroup(of: (String, Benchmark?, String).self) { g -> [(String, Benchmark?, String)] in
            for (id, b) in snap.benchmarks {
                g.addTask {
                    do {
                        let nb = try await withTimeLimit(perSource) { () async throws -> Benchmark? in
                            let page = try await fetcher.fetchText(b.source, limit: 120_000)
                            let req = LLMRequest(model: model, system: "You extract leaderboard tables into JSON. Output only JSON.",
                                                 tools: [], messages: [.user("""
                                                 From this leaderboard page, output a JSON object mapping each model name (as written) to its \
                                                 \(b.title) score as a number in percent. Include every row; nothing else.

                                                 \(page.truncated(60_000))
                                                 """)], maxTokens: 4000, effort: .low, cache: CacheHints(lineageKey: "catalog-refresh", retention: .none))
                            let reply = try await extractor.complete(req).message.plainText
                            guard let obj = Supervisor.parseJSON(reply)?.objectValue else { throw ProviderError.protocolError("no JSON") }
                            var rows: [String: Double] = [:]
                            for (name, v) in obj {
                                guard let n = v.numberValue, n >= 0, n <= 100 else { continue }
                                let forms = [String(format: "%.1f", n), String(format: "%.2f", n), n == n.rounded() ? String(Int(n)) : String(n)]
                                if forms.contains(where: { page.contains($0) }) && page.localizedCaseInsensitiveContains(name.prefix(12)) { rows[name] = n }
                            }
                            guard rows.count >= 3 else { return nil }
                            var nb = b
                            nb.scores = rows
                            nb.asOf = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate]) + " (fetched)"
                            return nb
                        }
                        let line = nb.map { "\(b.title): \($0.scores.count) rows" } ?? "\(b.title): kept previous (fewer than 3 verifiable rows)"
                        onLine?(line)
                        return (id, nb, line)
                    } catch {
                        let line = "\(b.title): kept previous (\(error.localizedDescription.truncated(120)))"
                        onLine?(line)
                        return (id, nil, line)
                    }
                }
            }
            var out: [(String, Benchmark?, String)] = []
            for await r in g { out.append(r) }
            return out
        }
        for (id, nb, _) in results { if let nb { snap.benchmarks[id] = nb } }
        if let d = try? JSONEncoder().encode(snap) { try? d.write(to: BenchmarkSnapshot.refreshedFile) }
        return results.map(\.2)
    }

    /// Lines collected from parallel work, each also passed on as it arrives.
    final class LockedLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private let onLine: (@Sendable (String) -> Void)?
        init(_ onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }
        func add(_ s: String) { lock.withLock { lines.append(s) }; onLine?(s) }
        var all: [String] { lock.withLock { lines } }
    }
}

/// Runs `op`, giving up after `seconds` (the work is cancelled).
public struct TimeLimitExceeded: LocalizedError {
    public let seconds: TimeInterval
    public var errorDescription: String? { "no answer within \(Int(seconds)) s" }
}

public func withTimeLimit<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await op() }
        g.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeLimitExceeded(seconds: seconds)
        }
        defer { g.cancelAll() }
        return try await g.next()!
    }
}

/// Relay and admin billing endpoints, complementing `QuotaService`.
public enum ExtraBilling {
    /// new-api / one-api style relays implement OpenAI's legacy billing endpoints for API keys.
    public static func relayBalance(_ p: ProviderProfile, key: String, http: HTTPStreaming = URLSessionStreaming()) async -> QuotaSnapshot.Meter? {
        guard let sub = p.endpoint("/v1/dashboard/billing/subscription"), let use = p.endpoint("/v1/dashboard/billing/usage?start_date=2000-01-01&end_date=2100-01-01") else { return nil }
        func get(_ u: URL) async -> JSON? {
            var r = URLRequest(url: u)
            r.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
            r.timeoutInterval = 15
            guard let (s, d) = try? await http.send(r), s < 300 else { return nil }
            return try? JSONCodec.parse(d)
        }
        guard let s = await get(sub), let limit = s["hard_limit_usd"]?.numberValue else { return nil }
        let usedCents = await get(use)?["total_usage"]?.numberValue ?? 0
        let used = usedCents / 100
        return .init(label: "Relay credit", usedFraction: limit > 0 ? min(1, used / limit) : nil,
                     remaining: String(format: "$%.2f left of $%.2f", max(0, limit - used), limit), resetsAt: nil)
    }

    /// Anthropic Admin API cost report (needs an admin key, `sk-ant-admin…`). Month-to-date spend.
    public static func anthropicMonthToDate(adminKey: String, http: HTTPStreaming = URLSessionStreaming()) async -> QuotaSnapshot.Meter? {
        let cal = Calendar(identifier: .gregorian)
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let iso = ISO8601DateFormatter().string(from: start)
        guard let u = URL(string: "https://api.anthropic.com/v1/organizations/cost_report?starting_at=\(iso)&bucket_width=1d") else { return nil }
        var r = URLRequest(url: u)
        r.setValue(adminKey, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        guard let (s, d) = try? await http.send(r), s < 300, let j = try? JSONCodec.parse(d) else { return nil }
        var total = 0.0
        for bucket in j["data"]?.arrayValue ?? [] {
            for res in bucket["results"]?.arrayValue ?? [] { total += Double(res.str("amount") ?? "") ?? res["amount"]?.numberValue ?? 0 }
        }
        return .init(label: "Month-to-date spend (org)", usedFraction: nil, remaining: String(format: "$%.2f spent", total / 100), resetsAt: nil)
    }

    /// OpenAI organization costs (needs an admin key). Month-to-date spend.
    public static func openAIMonthToDate(adminKey: String, http: HTTPStreaming = URLSessionStreaming()) async -> QuotaSnapshot.Meter? {
        let cal = Calendar(identifier: .gregorian)
        let start = Int(cal.date(from: cal.dateComponents([.year, .month], from: Date()))!.timeIntervalSince1970)
        guard let u = URL(string: "https://api.openai.com/v1/organization/costs?start_time=\(start)&limit=31") else { return nil }
        var r = URLRequest(url: u)
        r.setValue("Bearer \(adminKey)", forHTTPHeaderField: "authorization")
        guard let (s, d) = try? await http.send(r), s < 300, let j = try? JSONCodec.parse(d) else { return nil }
        var total = 0.0
        for bucket in j["data"]?.arrayValue ?? [] {
            for res in bucket["results"]?.arrayValue ?? [] { total += res["amount"]?["value"]?.numberValue ?? 0 }
        }
        return .init(label: "Month-to-date spend (org)", usedFraction: nil, remaining: String(format: "$%.2f spent", total), resetsAt: nil)
    }
}

/// SieveSci's own spend tracking: every model call's usage × models.dev prices, per provider and
/// day, persisted in `~/.sievesci/usage.json`. Works for every provider, including those without a
/// balance API (Claude, GPT, Gemini API keys).
public final class SpendTracker: @unchecked Sendable {
    public static let shared = SpendTracker()
    struct Day: Codable { var usd: Double; var input: Int; var cacheRead: Int; var cacheWrite: Int; var output: Int }
    private let lock = NSLock()
    private var data: [String: [String: Day]] = [:]   // provider → yyyy-mm-dd → totals
    static var file: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/usage.json") }

    init() {
        if let d = try? Data(contentsOf: Self.file) { data = (try? JSONDecoder().decode([String: [String: Day]].self, from: d)) ?? [:] }
    }

    public func record(_ u: Usage, model: String, profile: ProviderProfile) {
        let usd = ModelsDevCatalog.shared.cost(u, model: model, profile: profile) ?? 0
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        lock.lock()
        var d = data[profile.id]?[day] ?? Day(usd: 0, input: 0, cacheRead: 0, cacheWrite: 0, output: 0)
        d.usd += usd; d.input += u.input; d.cacheRead += u.cacheRead; d.cacheWrite += u.cacheWrite; d.output += u.output
        data[profile.id, default: [:]][day] = d
        let snapshot = data
        lock.unlock()
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: Self.file)
    }

    /// (today, month-to-date) USD for a provider, from tracked usage.
    public func spend(providerId: String) -> (today: Double, month: Double) {
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let month = String(today.prefix(7))
        lock.lock(); defer { lock.unlock() }
        let days = data[providerId] ?? [:]
        return (days[today]?.usd ?? 0, days.filter { $0.key.hasPrefix(month) }.values.reduce(0) { $0 + $1.usd })
    }
}
