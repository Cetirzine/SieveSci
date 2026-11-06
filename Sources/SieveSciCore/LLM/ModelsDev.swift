import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// models.dev (sst/models.dev, MIT) — the community model catalog OpenCode uses: ~230 providers
/// (first-party APIs, coding plans, relays), each model with limits, modalities, reasoning options
/// and prices (incl. cache read/write). Refreshed daily into `~/.sievesci/catalog/models.dev.json`.
public struct ModelsDevModel: Sendable, Equatable {
    public var id: String
    public var name: String
    public var provider: String
    public var context: Int?
    public var output: Int?
    public var inputModalities: [String]
    public var reasoning: Bool
    public var toolCall: Bool
    public var effortLevels: [String]
    /// USD per million tokens.
    public var cost: (input: Double?, output: Double?, cacheRead: Double?, cacheWrite: Double?)

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.provider == b.provider }
}

public struct ModelsDevProvider: Sendable {
    public var id: String
    public var name: String
    public var api: String?
    public var env: [String]
    public var doc: String?
    public var models: [String: ModelsDevModel]
}

public final class ModelsDevCatalog: @unchecked Sendable {
    public static let shared = ModelsDevCatalog()
    public static let url = URL(string: "https://models.dev/api.json")!
    private let lock = NSLock()
    public private(set) var providers: [String: ModelsDevProvider] = [:] { didSet { hostIndex = nil } }
    /// API host → provider id, built once per catalog: every model lookup needs it, and parsing each
    /// provider's URL per lookup made Settings slow (47 models × ~100 providers on every config change).
    private var hostIndex: [String: String]?
    public private(set) var loadedAt: Date?

    static var cacheFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/catalog/models.dev.json")
    }

    public init() { _ = try? load(Data(contentsOf: Self.cacheFile)) }

    /// Parses the catalog. JSONSerialization, not the `Value` decoder: the file is ~6 MB and this runs
    /// on first use (often on the main thread), where the generic decoder took seconds.
    @discardableResult
    public func load(_ data: Data) throws -> Int {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ToolError.invalidInput("models.dev: not an object") }
        func str(_ d: [String: Any]?, _ k: String) -> String? { d?[k] as? String }
        func int(_ d: [String: Any]?, _ k: String) -> Int? { (d?[k] as? NSNumber)?.intValue }
        func dbl(_ d: [String: Any]?, _ k: String) -> Double? { (d?[k] as? NSNumber)?.doubleValue }
        var out: [String: ModelsDevProvider] = [:]
        for (pid, pv) in root {
            guard let p = pv as? [String: Any] else { continue }
            var models: [String: ModelsDevModel] = [:]
            for (mid, mv) in p["models"] as? [String: Any] ?? [:] {
                guard let m = mv as? [String: Any] else { continue }
                let limit = m["limit"] as? [String: Any], cost = m["cost"] as? [String: Any]
                let effort = ((m["reasoning_options"] as? [[String: Any]]) ?? []).first { $0["type"] as? String == "effort" }?["values"] as? [String] ?? []
                models[mid] = ModelsDevModel(
                    id: str(m, "id") ?? mid, name: str(m, "name") ?? mid, provider: pid,
                    context: int(limit, "context"), output: int(limit, "output"),
                    inputModalities: ((m["modalities"] as? [String: Any])?["input"] as? [String]) ?? ["text"],
                    reasoning: (m["reasoning"] as? Bool) ?? false, toolCall: (m["tool_call"] as? Bool) ?? false, effortLevels: effort,
                    cost: (dbl(cost, "input"), dbl(cost, "output"), dbl(cost, "cache_read"), dbl(cost, "cache_write")))
            }
            out[pid] = ModelsDevProvider(id: pid, name: str(p, "name") ?? pid, api: str(p, "api"),
                                         env: p["env"] as? [String] ?? [], doc: str(p, "doc"), models: models)
        }
        lock.lock(); providers = out; loadedAt = Date(); lock.unlock()
        return out.count
    }

    /// Downloads the latest catalog (at most once a day unless forced).
    public func refresh(force: Bool = false, http: HTTPStreaming = URLSessionStreaming()) async throws -> Int {
        if !force, let d = (try? Self.cacheFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(d) < 86_400, !providers.isEmpty { return providers.count }
        var req = URLRequest(url: Self.url)
        req.timeoutInterval = 60
        let (s, data) = try await http.send(req)
        guard s < 300 else { throw ProviderError.http(status: s, body: "models.dev") }
        let n = try load(data)
        try FileManager.default.createDirectory(at: Self.cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Self.cacheFile)
        return n
    }

    /// Maps a configured endpoint to its models.dev provider id (by API host, then by name).
    public func providerId(for profile: ProviderProfile) -> String? {
        lock.lock(); defer { lock.unlock() }
        return providerIdUnlocked(profile)
    }

    public func model(_ id: String, profile: ProviderProfile) -> ModelsDevModel? {
        lock.lock(); defer { lock.unlock() }
        let norm = id.lowercased()
        if let pid = providerIdUnlocked(profile), let m = providers[pid]?.models[id] ?? providers[pid]?.models.values.first(where: { $0.id.lowercased() == norm }) {
            return m
        }
        // Same model served by another provider (e.g. a relay): use the first-party entry.
        for pid in ["anthropic", "openai", "google", "deepseek", "zhipuai", "moonshotai", "openrouter"] {
            let bare = norm.split(separator: "/").last.map(String.init) ?? norm
            if let m = providers[pid]?.models[bare] { return m }
        }
        return nil
    }

    static let knownHosts: [String: String] = [
        "api.anthropic.com": "anthropic", "api.openai.com": "openai", "generativelanguage.googleapis.com": "google",
        "api.deepseek.com": "deepseek", "open.bigmodel.cn": "zhipuai", "api.z.ai": "zai", "openrouter.ai": "openrouter",
        "api.moonshot.cn": "moonshotai-cn", "api.moonshot.ai": "moonshotai",
    ]

    /// Maps a configured endpoint to its models.dev provider id (by API host, then known hosts).
    private func providerIdUnlocked(_ profile: ProviderProfile) -> String? {
        let host = URL(string: profile.baseURL)?.host?.lowercased() ?? ""
        if hostIndex == nil {
            var index: [String: String] = [:]
            // Sorted, so a host several providers share maps to the same one every time.
            for p in providers.values.sorted(by: { $0.id < $1.id }) {
                if let h = p.api.flatMap({ URL(string: $0)?.host?.lowercased() }), index[h] == nil { index[h] = p.id }
            }
            hostIndex = index
        }
        return hostIndex?[host] ?? Self.knownHosts.first { host.hasSuffix($0.key) }?.value
    }

    /// USD cost of one request's usage, when prices are known.
    public func cost(_ u: Usage, model: String, profile: ProviderProfile) -> Double? {
        guard let m = self.model(model, profile: profile), let inp = m.cost.input, let out = m.cost.output else { return nil }
        let read = m.cost.cacheRead ?? inp, write = m.cost.cacheWrite ?? inp
        return (Double(u.input) * inp + Double(u.cacheRead) * read + Double(u.cacheWrite) * write + Double(u.output) * out) / 1_000_000
    }
}
