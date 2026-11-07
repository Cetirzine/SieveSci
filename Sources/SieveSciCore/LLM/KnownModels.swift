import Foundation

/// Specs for models the bundled catalogs (ZCode rules, models.dev) do not list yet, and how the
/// harness adapts to each. A listing from the endpoint or models.dev still wins where it says more;
/// settings the user made always win.
public enum KnownModels {
    public struct Spec: Sendable {
        public var contextWindow: Int
        public var maxOutput: Int
        public var supportsImages: Bool
        public var supportsReasoning: Bool
        /// USD per million tokens.
        public var input: Double, output: Double, cacheRead: Double
        /// How much context a session may hold before it compacts (in place of
        /// `AgentSession.contextBudget`, which keeps other 1M-token models near 200k).
        public var contextBudget: Int
        /// In a long tool loop, restate the turn's request and the plan every N tool rounds (0 = never).
        public var stateRefreshEvery: Int
    }

    /// Naive-N0.5-Flash (naive.ai, Sept 2026): 309B MoE, 15.5B active, native 1M context. Attention
    /// is sliding-window (128 tokens) and DeepSeek-style sparse attention (an indexer selects the top
    /// 2,048 tokens of the whole history) in a 5:1 layout, with no full-attention layer. Cache reads
    /// cost a tenth of input ($0.01 vs $0.10 per million), so a long, stable, append-only context is
    /// cheap to re-send — the budget is the full window, compacting at 60% of it. With no full
    /// attention, instructions far back are reached only through the sparse indexer, so long tool
    /// loops get a short restatement of the request and the plan near the end every 10 rounds.
    /// Text only: images go to the vision helper.
    static let naive = Spec(contextWindow: 1_000_000, maxOutput: 32_000, supportsImages: false, supportsReasoning: false,
                            input: 0.10, output: 0.40, cacheRead: 0.01, contextBudget: 1_000_000, stateRefreshEvery: 10)

    public static func spec(for model: String) -> Spec? {
        let m = model.lowercased()
        if m.hasPrefix("naive-") || m.contains("/naive-") { return naive }
        return nil
    }

    /// USD cost of one request's usage; cache writes are billed as input.
    public static func cost(_ u: Usage, model: String) -> Double? {
        guard let s = spec(for: model) else { return nil }
        return (Double(u.input + u.cacheWrite) * s.input + Double(u.cacheRead) * s.cacheRead + Double(u.output) * s.output) / 1_000_000
    }

    /// A UUID-formatted id derived from a session lineage: the same task and role always send the same
    /// id (the endpoint keeps routing it to its cache), different tasks never share one.
    public static func sessionUUID(_ lineage: String) -> String {
        var h = Array(Hashing.sha256Hex("sievesci-session:" + lineage).prefix(32))
        h[12] = "5"                                                  // version 5 (name-based)
        h[16] = ["8", "9", "a", "b"][Int(String(h[16]), radix: 16)! & 3] // RFC 4122 variant
        let s = String(h)
        func part(_ a: Int, _ b: Int) -> Substring { s[s.index(s.startIndex, offsetBy: a)..<s.index(s.startIndex, offsetBy: b)] }
        return [part(0, 8), part(8, 12), part(12, 16), part(16, 20), part(20, 32)].joined(separator: "-")
    }
}
