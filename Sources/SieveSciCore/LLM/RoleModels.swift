import Foundation

/// Which model each agent role uses. Three modes, as in the settings page:
/// - `.auto`   — recommended from the user's own configured models using benchmark evidence;
/// - `.same`   — one model for every role;
/// - `.custom` — chosen per role.
public struct ModelRef: Codable, Hashable, Sendable {
    public var providerId: String
    public var model: String
    public init(providerId: String, model: String) { self.providerId = providerId; self.model = model }
}

public struct RoleAssignment: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable { case auto, same, custom }
    public var mode: Mode = .auto
    public var same: ModelRef?
    public var custom: [String: ModelRef] = [:]     // keyed by AgentRole.rawValue
    public init() {}
}

public struct Benchmark: Codable, Sendable {
    public var title: String
    public var source: String
    public var asOf: String
    public var harness: String
    public var scores: [String: Double]
}

public struct BenchmarkSnapshot: Codable, Sendable {
    public var note: String?
    public var benchmarks: [String: Benchmark]

    static var refreshedFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/catalog/benchmarks.json") }

    /// The refreshed copy if present, else the bundled fallback.
    public static func current() -> BenchmarkSnapshot {
        let dec = JSONDecoder()
        if let d = try? Data(contentsOf: refreshedFile), let s = try? dec.decode(BenchmarkSnapshot.self, from: d) { return s }
        if let u = SieveSciResources.bundle.url(forResource: "benchmarks", withExtension: "json", subdirectory: "Resources/catalog"),
           let d = try? Data(contentsOf: u), let s = try? dec.decode(BenchmarkSnapshot.self, from: d) { return s }
        return BenchmarkSnapshot(note: nil, benchmarks: [:])
    }
}

public struct RoleRecommendation: Sendable {
    public var role: AgentRole
    public var ref: ModelRef
    public var score: Double?
    public var reasons: [String]
}

/// Picks models per role from what the user actually has configured.
///
/// Role weights reflect what each role does:
/// - main     — biology research + scientific computing: LABBench2, Terminal-Bench-Science, with
///              PostTrainBench (long autonomous ML work) and Riemann-bench (rigorous reasoning);
/// - checker  — critical reasoning and domain knowledge: Riemann-bench + LABBench2;
/// - verifier — re-implementing analyses from scratch: Terminal-Bench-Science + PostTrainBench;
/// - worker   — the main mix, discounted by price (it runs often, on narrow subtasks).
/// Checker and verifier get a bonus for a vendor different from the main model's: independent
/// review is stronger when reviewer and author do not share training and blind spots.
public enum RoleModelAdvisor {
    public static let weights: [AgentRole: [String: Double]] = [
        .main: ["labbench2": 0.35, "terminal-bench-science": 0.35, "posttrainbench": 0.15, "riemannbench": 0.15],
        .checker: ["riemannbench": 0.4, "labbench2": 0.4, "terminal-bench-science": 0.2],
        .verifier: ["terminal-bench-science": 0.5, "posttrainbench": 0.25, "labbench2": 0.25],
        .worker: ["labbench2": 0.4, "terminal-bench-science": 0.4, "riemannbench": 0.2],
    ]

    public static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "claude", with: "").replacingOccurrences(of: "google", with: "")
    }

    /// Finds a model's score in a benchmark by id or display name (exact after normalization).
    static func lookup(_ b: Benchmark, ids: [String]) -> Double? {
        let keys = Set(ids.map(normalize))
        return b.scores.first { keys.contains(normalize($0.key)) }?.value
    }

    static func vendor(_ p: ProviderProfile, _ model: String) -> String {
        let m = model.lowercased()
        if m.contains("claude") || ["opus", "sonnet", "haiku"].contains(m) { return "anthropic" }
        if m.hasPrefix("gpt") || m.hasPrefix("o3") || m.hasPrefix("o4") || m.contains("/gpt") { return "openai" }
        if m.contains("gemini") { return "google" }
        if m.contains("deepseek") { return "deepseek" }
        if m.contains("glm") { return "zhipu" }
        if m.contains("kimi") { return "moonshot" }
        if m.contains("grok") { return "xai" }
        if m.contains("qwen") { return "alibaba" }
        return URL(string: p.baseURL)?.host ?? p.id
    }

    public typealias Candidate = (profile: ProviderProfile, model: String, displayName: String?)

    public static func score(_ c: Candidate, role: AgentRole, snapshot: BenchmarkSnapshot) -> (Double?, [String]) {
        let ids = [c.model, c.displayName ?? "", ModelsDevCatalog.shared.model(c.model, profile: c.profile)?.name ?? ""].filter { !$0.isEmpty }
        var total = 0.0, wsum = 0.0, covered = 0.0
        var reasons: [String] = []
        for (bid, w) in weights[role] ?? [:] {
            guard let b = snapshot.benchmarks[bid] else { continue }
            wsum += w
            guard let s = lookup(b, ids: ids), let top = b.scores.values.max(), top > 0 else { continue }
            total += w * s / top
            covered += w
            reasons.append("\(b.title) \(String(format: "%.1f", s)) (\(b.asOf))")
        }
        guard covered > 0, wsum > 0 else { return (nil, ["no benchmark data for \(c.model)"]) }
        // Average over the benchmarks we have, discounted when coverage is partial.
        let s = (total / covered) * (0.6 + 0.4 * covered / wsum)
        return (s, reasons)
    }

    public static func recommend(candidates: [Candidate], snapshot: BenchmarkSnapshot = .current()) -> [RoleRecommendation] {
        guard !candidates.isEmpty else { return [] }
        func best(_ role: AgentRole, mainVendor: String?) -> RoleRecommendation {
            var ranked: [(Candidate, Double, [String])] = []
            for c in candidates {
                let (s, r) = score(c, role: role, snapshot: snapshot)
                var v = s ?? -1
                var reasons = r
                if let mv = mainVendor, s != nil, vendor(c.profile, c.model) != mv {
                    v += 0.08
                    reasons.append("different vendor from the main model (independent review)")
                }
                if role == .worker, s != nil, let price = ModelsDevCatalog.shared.model(c.model, profile: c.profile)?.cost.input {
                    v = v * 0.6 + 0.4 / (1 + price)   // cheaper is better for frequent narrow subtasks
                    reasons.append(String(format: "$%.2f/M input", price))
                }
                ranked.append((c, v, reasons))
            }
            let top = ranked.max { $0.1 < $1.1 }!
            return RoleRecommendation(role: role, ref: ModelRef(providerId: top.0.profile.id, model: top.0.model),
                                      score: top.1 >= 0 ? top.1 : nil,
                                      reasons: top.1 >= 0 ? top.2 : ["no benchmark data for any configured model; using \(top.0.model)"])
        }
        let main = best(.main, mainVendor: nil)
        let mainCandidate = candidates.first { $0.profile.id == main.ref.providerId && $0.model == main.ref.model }!
        let mv = vendor(mainCandidate.profile, mainCandidate.model)
        return [main, best(.checker, mainVendor: mv), best(.verifier, mainVendor: mv), best(.worker, mainVendor: nil)]
    }

    /// Resolves the effective model per role for an assignment.
    public static func resolve(_ a: RoleAssignment, candidates: [Candidate]) -> [AgentRole: ModelRef] {
        switch a.mode {
        case .same:
            guard let s = a.same ?? candidates.first.map({ ModelRef(providerId: $0.profile.id, model: $0.model) }) else { return [:] }
            return [.main: s, .checker: s, .verifier: s, .worker: s]
        case .custom:
            var out: [AgentRole: ModelRef] = [:]
            let fallback = recommend(candidates: candidates)
            for r in [AgentRole.main, .checker, .verifier, .worker] {
                out[r] = a.custom[r.rawValue] ?? fallback.first { $0.role == r }?.ref
            }
            return out
        case .auto:
            return Dictionary(uniqueKeysWithValues: recommend(candidates: candidates).map { ($0.role, $0.ref) })
        }
    }
}
