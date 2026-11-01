import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Remaining credit / plan quota per provider, shown natively next to the model picker.
///
/// Sources (each taken from what ZCode or Reasonix actually call, not guessed):
/// - DeepSeek            GET https://api.deepseek.com/user/balance                 (Reasonix billing)
/// - Moonshot / Kimi     GET https://api.moonshot.{cn,ai}/v1/users/me/balance       (Reasonix presets)
/// - GLM Coding Plan     GET https://{open.bigmodel.cn,api.z.ai}/api/monitor/usage/quota/limit  (ZCode)
/// - OpenRouter          GET https://openrouter.ai/api/v1/key  (limit, usage, limit_remaining)
/// - Codex (ChatGPT)     latest `token_count.rate_limits` in ~/.codex/sessions rollouts (Codex protocol)
/// - Claude Code         `rate_limit_event` lines in its stream-json output (captured by the bridge),
///                       one per window (five_hour, seven_day, seven_day_opus …)
/// - CloseAI             POST https://api.openai-proxy.org/api/v1/management/account/balance with a
///                       management key (sk-admin-…, enterprise accounts), CLOSEAI_ADMIN_KEY
/// - other relays        new-api / one-api: GET {base}/dashboard/billing/subscription + …/usage
/// - Anthropic / OpenAI / Gemini API keys have no key-level balance API: the rate-limit headers of
///   the latest response are shown instead (remaining requests/tokens in the current window).
public struct QuotaSnapshot: Sendable, Equatable, Identifiable {
    public struct Meter: Sendable, Equatable {
        /// What the meter measures, so the interface can name it in the user's language.
        public enum Kind: String, Sendable { case balance, credit, fiveHour, weekly, weeklyModel, window, prompts, tokens, usage, rateLimit, other }
        public var label: String          // English fallback / raw header name
        public var usedFraction: Double?  // 0…1 when the provider reports a limit
        public var remaining: String      // English fallback text, e.g. "37% left"
        public var resetsAt: Date?
        public var kind: Kind = .other
        /// Money left, already formatted with its currency ("¥52.29", "$3.10").
        public var amount: String? = nil
        /// Model family or window detail ("Opus", "6 h").
        public var detail: String? = nil
        /// Set when the provider says the limit is reached.
        public var exhausted = false

        public init(label: String, usedFraction: Double?, remaining: String, resetsAt: Date?, kind: Kind = .other,
                    amount: String? = nil, detail: String? = nil, exhausted: Bool = false) {
            self.label = label; self.usedFraction = usedFraction; self.remaining = remaining; self.resetsAt = resetsAt
            self.kind = kind; self.amount = amount; self.detail = detail; self.exhausted = exhausted
        }
    }
    public var id: String { providerId }
    public var providerId: String
    public var plan: String?
    public var meters: [Meter]
    public var fetchedAt: Date
    public var note: String?
}

public actor QuotaService {
    public static let shared = QuotaService()
    private var cache: [String: QuotaSnapshot] = [:]
    /// Rate-limit headers seen on the latest response per provider (fed by providers).
    private var headerSnapshots: [String: [String: String]] = [:]
    /// Claude Code rate-limit events per provider, keyed by window type.
    private var cliEvents: [String: [String: JSON]] = [:]

    public func cached(_ id: String) -> QuotaSnapshot? { cache[id] }

    public func recordHeaders(providerId: String, headers: [String: String]) {
        let interesting = headers.filter { $0.key.contains("ratelimit") || $0.key.contains("rate-limit") }
        if !interesting.isEmpty { headerSnapshots[providerId] = interesting }
    }

    public func recordCLIEvent(providerId: String, event: JSON) {
        let window = event.str("rateLimitType") ?? event.str("rate_limit_type") ?? "current"
        cliEvents[providerId, default: [:]][window] = event
    }

    /// Meters from Claude Code's rate-limit events, one per window it reported.
    static func claudeMeters(_ events: [String: JSON]) -> [QuotaSnapshot.Meter] {
        let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "overage", "current"]
        return events.sorted { (order.firstIndex(of: $0.key) ?? 99) < (order.firstIndex(of: $1.key) ?? 99) }.map { window, ev in
            let u = ev["utilization"]?.numberValue.map { $0 > 1 ? $0 / 100 : $0 }
            let status = ev.str("status") ?? ""
            let reset = (ev["resetsAt"] ?? ev["resets_at"])?.numberValue.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) }
            let kind: QuotaSnapshot.Meter.Kind = window == "five_hour" ? .fiveHour : window.hasPrefix("seven_day_") ? .weeklyModel : window == "seven_day" ? .weekly : .window
            let model = window.hasPrefix("seven_day_") ? String(window.dropFirst("seven_day_".count)).capitalized : nil
            let text = u.map { "\(Int((1 - $0) * 100))% left" } ?? (status == "rejected" ? "limit reached" : status == "allowed_warning" ? "nearing the limit" : "within the limit")
            return .init(label: window, usedFraction: u, remaining: text, resetsAt: reset, kind: kind, detail: model, exhausted: status == "rejected")
        }
    }

    /// GLM Coding Plan limits. Each entry names its window by `number` × `unit` (3 = hours, 4 = days,
    /// 5 = months, 6 = weeks): `CREDIT_LIMIT` 5 × hours is the 5-hour window and 1 × weeks the weekly
    /// one. `usage` is the window's allowance and `currentValue` what has been used. Older accounts
    /// report `TOKENS_LIMIT` (5-hour tokens) and `TIME_LIMIT` (monthly tool calls).
    static func glmMeters(_ limits: [JSON]) -> [QuotaSnapshot.Meter] {
        let units = [3: ("h", "hour"), 4: ("d", "day"), 5: ("mo", "month"), 6: ("w", "week")]
        let meters = limits.map { l -> QuotaSnapshot.Meter in
            let type = l.str("type") ?? ""
            let number = l["number"]?.intValue, unit = l["unit"]?.intValue
            let allowance = l["usage"]?.numberValue, used = l["currentValue"]?.numberValue
            let pct = l["percentage"]?.numberValue
            let fraction = allowance.flatMap { a in used.map { a > 0 ? min(1, $0 / a) : 0 } } ?? pct.map { $0 / 100 }
            let reset = l["nextResetTime"]?.numberValue.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) }
            let window = number.flatMap { n in unit.flatMap { units[$0] }.map { "\(n) \($0.0)" } }
            var kind: QuotaSnapshot.Meter.Kind = .window
            if (number == 5 && unit == 3) || (type == "TOKENS_LIMIT" && unit == nil) { kind = .fiveHour }
            else if (number == 1 && unit == 6) || (number == 7 && unit == 4) { kind = .weekly }
            else if type == "TIME_LIMIT" { kind = .prompts }
            let what = type == "TOKENS_LIMIT" ? "tokens" : type == "TIME_LIMIT" ? "tool calls" : nil
            let left = l["remaining"]?.numberValue.map { "\(Int($0)) left" } ?? fraction.map { "\(Int((1 - $0) * 100))% left" } ?? "?"
            return .init(label: [type, window].compactMap { $0 }.joined(separator: " "), usedFraction: fraction, remaining: left,
                         resetsAt: reset, kind: kind, detail: kind == .window ? window : what, exhausted: (fraction ?? 0) >= 1)
        }
        let order: [QuotaSnapshot.Meter.Kind] = [.fiveHour, .weekly, .window, .tokens, .prompts]
        return meters.sorted { (order.firstIndex(of: $0.kind) ?? 9) < (order.firstIndex(of: $1.kind) ?? 9) }
    }

    public func refresh(_ p: ProviderProfile, secrets: SecretStore, http: HTTPStreaming = URLSessionStreaming()) async -> QuotaSnapshot {
        var snap = await fetch(p, key: secrets.secret(for: p.apiKeyRef), http: http)
        if URL(string: p.baseURL)?.host?.lowercased() == "api.openai-proxy.org" { snap = await closeAI(snap, adminKey: secrets.secret(for: "CLOSEAI_ADMIN_KEY"), http: http) }
        cache[p.id] = snap
        return snap
    }

    func get(_ url: String, bearer: String?, http: HTTPStreaming, method: String = "GET") async throws -> JSON {
        guard let u = URL(string: url) else { throw ToolError.invalidInput(url) }
        var r = URLRequest(url: u)
        r.httpMethod = method
        if method == "POST" { r.httpBody = Data("{}".utf8); r.setValue("application/json", forHTTPHeaderField: "content-type") }
        if let b = bearer { r.setValue("Bearer \(b)", forHTTPHeaderField: "authorization") }
        r.setValue("application/json", forHTTPHeaderField: "accept")
        r.timeoutInterval = 15
        let (s, d) = try await http.send(r)
        guard s < 300 else { throw ProviderError.http(status: s, body: String(decoding: d.prefix(300), as: UTF8.self)) }
        return try JSONCodec.parse(d)
    }

    func fetch(_ p: ProviderProfile, key: String?, http: HTTPStreaming) async -> QuotaSnapshot {
        let host = URL(string: p.baseURL)?.host?.lowercased() ?? ""
        var snap = QuotaSnapshot(providerId: p.id, plan: nil, meters: [], fetchedAt: Date(), note: nil)
        do {
            if host.hasSuffix("deepseek.com") {
                let j = try await get("https://api.deepseek.com/user/balance", bearer: key, http: http)
                for b in j["balance_infos"]?.arrayValue ?? [] {
                    let sym = b.str("currency") == "CNY" ? "¥" : (b.str("currency") == "USD" ? "$" : (b.str("currency") ?? "") + " ")
                    snap.meters.append(.init(label: "Balance", usedFraction: nil,
                                             remaining: "\(sym)\(b.str("total_balance") ?? "?") (granted \(sym)\(b.str("granted_balance") ?? "0"), topped up \(sym)\(b.str("topped_up_balance") ?? "0"))",
                                             resetsAt: nil, kind: .balance, amount: "\(sym)\(b.str("total_balance") ?? "?")",
                                             exhausted: j.bool("is_available") == false))
                }
                if j.bool("is_available") == false { snap.note = "Balance insufficient for API calls." }
            } else if host.hasSuffix("moonshot.cn") || host.hasSuffix("moonshot.ai") {
                let j = try await get("https://\(host)/v1/users/me/balance", bearer: key, http: http)
                let d = j["data"]
                let avail = d?["available_balance"]?.numberValue.map { String(format: "%.2f", $0) } ?? "?"
                snap.meters.append(.init(label: "Balance", usedFraction: nil,
                                         remaining: "\(avail) (voucher \(d?["voucher_balance"]?.numberValue.map { String(format: "%.2f", $0) } ?? "0"))",
                                         resetsAt: nil, kind: .balance, amount: (host.hasSuffix(".cn") ? "¥" : "$") + avail))
            } else if host == "open.bigmodel.cn" || host == "api.z.ai" {
                let base = host == "api.z.ai" ? "https://api.z.ai" : "https://open.bigmodel.cn"
                let j = try await get("\(base)/api/monitor/usage/quota/limit", bearer: key, http: http)
                if let msg = j.str("msg"), j["data"] == nil || j["data"]?.isNull == true { snap.note = msg }
                let d = j["data"]
                if let level = d?.str("level") { snap.plan = "GLM Coding " + level.prefix(1).uppercased() + level.dropFirst().lowercased() }
                snap.meters += Self.glmMeters(d?["limits"]?.arrayValue ?? [])
            } else if host.hasSuffix("openrouter.ai") {
                let j = try await get("https://openrouter.ai/api/v1/key", bearer: key, http: http)
                let d = j["data"]
                let limit = d?["limit"]?.numberValue, usage = d?["usage"]?.numberValue ?? 0
                if let limit {
                    snap.meters.append(.init(label: "Key credit", usedFraction: limit > 0 ? usage / limit : nil,
                                             remaining: String(format: "$%.2f left of $%.2f", limit - usage, limit), resetsAt: nil,
                                             kind: .credit, amount: String(format: "$%.2f", limit - usage), exhausted: limit - usage <= 0))
                } else {
                    snap.meters.append(.init(label: "Usage", usedFraction: nil, remaining: String(format: "$%.2f used (no key limit)", usage), resetsAt: nil,
                                             kind: .usage, amount: String(format: "$%.2f", usage)))
                }
            } else if p.billing == "relay" || p.id == "openai-compatible", p.family == .openaiChat || p.family == .openaiResponses, let key,
                      let m = try? await relayCredit(base: p.baseURL, key: key, http: http) {
                snap.meters.append(m)
            } else if p.flavor == .codex {
                snap = codexSnapshot(p) ?? snap
            } else if p.flavor == .claudeCode {
                if let evs = cliEvents[p.id], !evs.isEmpty { snap.meters = Self.claudeMeters(evs) }
                else { snap.note = "Claude Code reports its 5-hour and weekly limits with each reply; they appear after the first request." }
            } else if p.flavor == .antigravity || p.flavor == .geminiCLI {
                snap.note = "This CLI does not report plan limits to other tools; check them in the CLI itself."
            }
        } catch {
            snap.note = error.localizedDescription.truncated(200)
        }
        // Rate-limit headers (Anthropic / OpenAI / relays) as a fallback signal.
        if snap.meters.isEmpty, let h = headerSnapshots[p.id] {
            for (k, v) in h.sorted(by: { $0.key < $1.key }) where k.contains("remaining") {
                let lim = h[k.replacingOccurrences(of: "remaining", with: "limit")].flatMap(Double.init)
                let rem = Double(v)
                snap.meters.append(.init(label: k.replacingOccurrences(of: "anthropic-ratelimit-", with: "").replacingOccurrences(of: "x-ratelimit-", with: ""),
                                         usedFraction: (lim != nil && rem != nil && lim! > 0) ? 1 - rem! / lim! : nil, remaining: v, resetsAt: nil))
            }
            if snap.meters.isEmpty { snap.note = snap.note ?? "This provider exposes no balance API; usage appears after the first request." }
        }
        if snap.meters.isEmpty && snap.note == nil { snap.note = "No balance or quota API for this provider." }
        return snap
    }

    /// The quota endpoint's raw JSON, for diagnosing how a plan reports its windows.
    public func rawResponse(_ p: ProviderProfile, secrets: SecretStore, http: HTTPStreaming = URLSessionStreaming()) async -> String? {
        let host = URL(string: p.baseURL)?.host?.lowercased() ?? ""
        guard host == "open.bigmodel.cn" || host == "api.z.ai" else { return nil }
        let base = host == "api.z.ai" ? "https://api.z.ai" : "https://open.bigmodel.cn"
        guard let j = try? await get("\(base)/api/monitor/usage/quota/limit", bearer: secrets.secret(for: p.apiKeyRef), http: http) else { return nil }
        return j.canonical
    }

    /// CloseAI account balance (management key only; model keys cannot call it).
    func closeAI(_ base: QuotaSnapshot, adminKey: String?, http: HTTPStreaming) async -> QuotaSnapshot {
        var snap = base
        guard let adminKey else {
            snap.note = "CloseAI shows the balance only to a management key (sk-admin-…, enterprise accounts): save one as CLOSEAI_ADMIN_KEY."
            return snap
        }
        do {
            let j = try await get("https://api.openai-proxy.org/api/v1/management/account/balance", bearer: adminKey, http: http, method: "POST")
            let v = j.str("balance") ?? j["balance"]?.numberValue.map { String($0) }
            if let v, let d = Double(v) {
                snap.meters = [.init(label: "Balance", usedFraction: nil, remaining: String(format: "¥%.2f", d), resetsAt: nil,
                                     kind: .balance, amount: String(format: "¥%.2f", d), exhausted: d <= 0)]
                snap.note = nil
            }
        } catch { snap.note = error.localizedDescription.truncated(200) }
        return snap
    }

    /// new-api / one-api relays answer the OpenAI legacy billing routes with the ordinary key.
    func relayCredit(base: String, key: String, http: HTTPStreaming) async throws -> QuotaSnapshot.Meter? {
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        let sub = try await get(root + "/dashboard/billing/subscription", bearer: key, http: http)
        guard let limit = sub["hard_limit_usd"]?.numberValue ?? sub["system_hard_limit_usd"]?.numberValue else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        let start = f.string(from: Date().addingTimeInterval(-99 * 86_400)), end = f.string(from: Date().addingTimeInterval(86_400))
        let used = ((try? await get(root + "/dashboard/billing/usage?start_date=\(start)&end_date=\(end)", bearer: key, http: http))?["total_usage"]?.numberValue ?? 0) / 100
        // Unlimited keys report an absurd limit; show only what was spent then.
        if limit >= 100_000_000 {
            return .init(label: "Usage", usedFraction: nil, remaining: String(format: "$%.2f used", used), resetsAt: nil, kind: .usage, amount: String(format: "$%.2f", used))
        }
        return .init(label: "Credit", usedFraction: limit > 0 ? min(1, used / limit) : nil, remaining: String(format: "$%.2f left of $%.2f", limit - used, limit),
                     resetsAt: nil, kind: .credit, amount: String(format: "$%.2f", limit - used), exhausted: limit - used <= 0)
    }

    /// Codex records `token_count` events with `rate_limits` (primary/secondary windows, used_percent,
    /// resets_at, plan_type) in its local rollout files; the newest one is the current state.
    func codexSnapshot(_ p: ProviderProfile) -> QuotaSnapshot? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var newest: (URL, Date)?
        for case let u as URL in en where u.pathExtension == "jsonl" {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if newest == nil || d > newest!.1 { newest = (u, d) }
        }
        guard let file = newest?.0, let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("rate_limits") {
            guard let j = try? JSONCodec.parse(String(line)) else { continue }
            let rl = j["payload"]?["rate_limits"] ?? j["rate_limits"]
            guard let rl, !rl.isNull else { continue }
            var s = QuotaSnapshot(providerId: p.id, plan: rl.str("plan_type").map { "ChatGPT \($0)" }, meters: [], fetchedAt: newest!.1, note: nil)
            for key in ["primary", "secondary"] {
                guard let w = rl[key], !w.isNull, let used = w["used_percent"]?.numberValue else { continue }
                let mins = w["window_minutes"]?.intValue
                let kind: QuotaSnapshot.Meter.Kind = mins == 300 ? .fiveHour : (mins ?? 0) >= 10080 ? .weekly : .window
                let name = kind == .fiveHour ? "5-hour window" : kind == .weekly ? "Weekly limit" : "Usage window"
                s.meters.append(.init(label: mins.map { $0 >= 1440 ? "\(name) (\($0 / 1440) d)" : "\(name) (\($0 / 60) h)" } ?? name,
                                      usedFraction: used / 100, remaining: "\(Int(100 - used))% left",
                                      resetsAt: w["resets_at"]?.numberValue.map { Date(timeIntervalSince1970: $0) },
                                      kind: kind, detail: mins.map { $0 >= 1440 ? "\($0 / 1440) d" : "\($0 / 60) h" }, exhausted: used >= 100))
            }
            return s
        }
        return nil
    }
}
