import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Automatic model capability detection, layered (later layers win):
///   1. ZCode catalog rules (offline; regex per model id / API format / base URL)
///   1b. models.dev (refreshed daily: limits, modalities, reasoning, prices)
///   2. live listing from the endpoint itself (`GET /models`, `GET /v1/models`, Gemini `models`),
///      remembered on disk so it applies at run time, not only in the provider page
///   2b. what the model itself showed: image input accepted or refused (`ModelCapabilities.learned`) —
///      catalogs lag behind models that gain vision
///   3. the user's manual overrides in the provider page
///
/// The listing parser follows DeepSeek Harness's `dsh-llm-pi-ai/discovery` (MIT): it accepts the
/// standard `data` array and the enriched `models` map that gateways expose, and every field
/// spelling seen in the wild (`context_window`, `context_length`, `max_input_tokens`,
/// `limit.context`, `max_output_tokens`, `max_tokens`, `top_provider.max_completion_tokens`, …).
public struct DiscoveredModel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String?
    public var contextWindow: Int?
    public var maxOutput: Int?
    public var inputModalities: [String]?
    public var effortLevels: [String]?
    public var supportsTools: Bool?
}

public enum ModelDiscovery {
    static let maxBytes = 4 * 1024 * 1024

    public static func list(_ profile: ProviderProfile, apiKey: String?, http: HTTPStreaming = URLSessionStreaming()) async throws -> [DiscoveredModel] {
        var req: URLRequest
        switch profile.family {
        case .anthropic:
            guard let u = profile.endpoint("/v1/models?limit=1000") else { throw ToolError.invalidInput("base URL") }
            req = URLRequest(url: u)
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if let k = apiKey { req.setValue(profile.auth == .bearer ? "Bearer \(k)" : k, forHTTPHeaderField: profile.auth == .bearer ? "authorization" : "x-api-key") }
        case .openaiChat, .openaiResponses:
            guard let u = profile.endpoint("/models") else { throw ToolError.invalidInput("base URL") }
            req = URLRequest(url: u)
            if let k = apiKey { req.setValue("Bearer \(k)", forHTTPHeaderField: "authorization") }
        case .gemini:
            guard let u = profile.endpoint("/models?pageSize=1000") else { throw ToolError.invalidInput("base URL") }
            req = URLRequest(url: u)
            if let k = apiKey { req.setValue(k, forHTTPHeaderField: "x-goog-api-key") }
        case .cliAgent:
            if profile.flavor == .antigravity {
                // `agy models` asks the signed-in account which models it may use (no tokens spent).
                let r = try await ProcessRunner.run(profile.executable ?? "agy", ["models"], timeout: 60)
                guard r.exitCode == 0 else {
                    throw ProviderError.protocolError("agy models exited \(r.exitCode): " + (r.stderr.isEmpty ? r.stdout : r.stderr).truncated(400))
                }
                return [DiscoveredModel(id: "default", displayName: "Account default")] + parseAgyModels(r.stdout)
            }
            if profile.flavor == .codex {
                // The catalog Codex itself uses for this account; "list" models are the selectable ones.
                let r = try await ProcessRunner.run(profile.executable ?? "codex", ["debug", "models"], timeout: 60)
                guard r.exitCode == 0 else { throw ProviderError.protocolError("codex debug models exited \(r.exitCode): " + r.stderr.truncated(400)) }
                return [DiscoveredModel(id: "default", displayName: "Codex config default")] + parseCodexModels(r.stdout)
            }
            return profile.models.map { DiscoveredModel(id: $0) }
        }
        for (k, v) in profile.options.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = 20
        let (status, data) = try await http.send(req)
        guard status < 300 else { throw ProviderError.http(status: status, body: String(decoding: data.prefix(600), as: UTF8.self)) }
        guard data.count <= maxBytes else { throw ProviderError.protocolError("model listing larger than 4 MiB") }
        let models = parse(try JSONCodec.parse(data), family: profile.family)
        ModelCapabilities.shared.remember(listing: models, profile: profile.id)
        return models
    }

    /// `codex debug models`: {"models": [{slug, display_name, visibility, supported_reasoning_levels …}]}.
    public static func parseCodexModels(_ text: String) -> [DiscoveredModel] {
        guard let j = try? JSONCodec.parse(text) else { return [] }
        let models = j["models"]?.arrayValue ?? j.arrayValue ?? []
        return models.compactMap { m in
            guard let slug = m.str("slug") ?? m.str("id"), m.str("visibility") != "hide" else { return nil }
            let levels = m["supported_reasoning_levels"]?.arrayValue?.compactMap { $0.str("effort") }
            return DiscoveredModel(id: slug, displayName: m.str("display_name"), contextWindow: m.int("context_window"),
                                   effortLevels: levels, supportsTools: true)
        }
    }

    /// `agy models` prints a progress line, then one `slug<TAB>Display name` per model.
    public static func parseAgyModels(_ text: String) -> [DiscoveredModel] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { line -> DiscoveredModel? in
            let parts = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let id = parts.first, !id.isEmpty, !id.contains(" "), seen.insert(id).inserted else { return nil }
            return DiscoveredModel(id: id, displayName: parts[1].isEmpty ? nil : parts[1])
        }
    }

    static func firstInt(_ j: JSON, _ paths: [[String]]) -> Int? {
        for p in paths {
            var cur: JSON? = j
            for k in p { cur = cur?[k] }
            if let v = cur?.intValue ?? cur?.numberValue.map({ Int($0) }) ?? cur?.stringValue.flatMap({ Int($0) }), v > 0 { return v }
        }
        return nil
    }

    public static func parse(_ j: JSON, family: ProviderFamily) -> [DiscoveredModel] {
        if family == .gemini {
            return (j["models"]?.arrayValue ?? []).compactMap { m in
                guard let name = m.str("name") else { return nil }
                let methods = m["supportedGenerationMethods"]?.arrayValue?.compactMap(\.stringValue) ?? []
                guard methods.isEmpty || methods.contains("generateContent") else { return nil }
                return DiscoveredModel(id: name.replacingOccurrences(of: "models/", with: ""), displayName: m.str("displayName"),
                                       contextWindow: m.int("inputTokenLimit"), maxOutput: m.int("outputTokenLimit"),
                                       inputModalities: nil, effortLevels: m.bool("thinking") == true ? ["low", "medium", "high"] : nil,
                                       supportsTools: true)
            }
        }
        var entries: [(String?, JSON)] = (j["data"]?.arrayValue ?? []).map { (nil, $0) }
        if let map = j["models"]?.objectValue { entries += map.map { ($0.key, $0.value) } }
        if let arr = j["models"]?.arrayValue { entries += arr.map { (nil, $0) } }
        return entries.compactMap { (k, e) -> DiscoveredModel? in
            guard let id = e.str("id") ?? k else { return nil }
            let ctx = firstInt(e, [["context_window"], ["contextWindow"], ["context_length"], ["max_input_tokens"], ["limit", "context"],
                                   ["top_provider", "context_length"]])
            let out = firstInt(e, [["max_output_tokens"], ["maxOutputTokens"], ["max_tokens"], ["maxTokens"], ["limit", "output"],
                                   ["top_provider", "max_completion_tokens"]])
            var modalities = e["input_modalities"]?.arrayValue?.compactMap(\.stringValue)
                ?? e["architecture"]?["input_modalities"]?.arrayValue?.compactMap(\.stringValue)
            if modalities == nil, let caps = e["capabilities"], caps["image_input"]?["supported"]?.boolValue == true { modalities = ["text", "image"] }
            let params = e["supported_parameters"]?.arrayValue?.compactMap(\.stringValue)
            var effort = e["effort"]?["supported_levels"]?.arrayValue?.compactMap(\.stringValue)
            if effort == nil, params?.contains("reasoning") == true { effort = ["low", "medium", "high"] }
            let tools = params?.contains("tools")
            return DiscoveredModel(id: id, displayName: e.str("display_name") ?? e.str("name") ?? e.str("displayName"),
                                   contextWindow: ctx, maxOutput: out, inputModalities: modalities, effortLevels: effort, supportsTools: tools)
        }
    }

    /// Merges catalog rules, live listing and user overrides into effective settings.
    public static func effectiveSettings(model: String, profile: ProviderProfile, discovered: DiscoveredModel?,
                                         catalog: ProviderCatalog = .shared) -> ModelSettings {
        var s = catalog.modelRules.settings(modelId: model, family: profile.family, baseURL: profile.baseURL)
        if let m = ModelsDevCatalog.shared.model(model, profile: profile) {
            if let c = m.context { s.contextWindow = c }
            if let o = m.output { s.maxOutput = o }
            s.supportsImages = m.inputModalities.contains("image")
            s.supportsReasoning = m.reasoning
        }
        if let d = discovered ?? ModelCapabilities.shared.listed(model, profile: profile.id) {
            if let c = d.contextWindow { s.contextWindow = c }
            if let o = d.maxOutput { s.maxOutput = o }
            if let m = d.inputModalities { s.supportsImages = m.contains("image") }
            if let e = d.effortLevels { s.supportsReasoning = e.contains { $0 != "disabled" && $0 != "none" } }
        }
        if let images = ModelCapabilities.shared.learnedImages(model, profile: profile.id) { s.supportsImages = images }
        if let user = profile.modelSettings.first(where: { $0.id == model }) { s = user }
        return s
    }
}


/// Capabilities remembered across runs: the endpoint's own model listing, and image support learned
/// from use. When a model the catalogs call text-only is given an image, the request is tried once
/// natively; the provider accepting or refusing it settles the question for that model.
public final class ModelCapabilities: @unchecked Sendable {
    public static let shared = ModelCapabilities()
    private let lock = NSLock()
    private struct Store: Codable { var listings: [String: [DiscoveredModel]] = [:]; var images: [String: Bool] = [:] }
    private var store: Store
    private let url: URL

    init(url: URL = CatalogRefresher.dir.appendingPathComponent("model-capabilities.json")) {
        self.url = url
        store = (try? JSONDecoder().decode(Store.self, from: Data(contentsOf: url))) ?? Store()
    }

    static func key(_ model: String, _ profile: String) -> String { profile + "/" + model }

    func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(store) { try? d.writeReliably(to: url) }
    }

    public func remember(listing: [DiscoveredModel], profile: String) {
        // Only listings that say something beyond ids are worth keeping.
        let useful = listing.filter { $0.inputModalities != nil || $0.contextWindow != nil || $0.effortLevels != nil }
        guard !useful.isEmpty else { return }
        lock.withLock { store.listings[profile] = useful; save() }
    }

    public func listed(_ model: String, profile: String) -> DiscoveredModel? {
        lock.withLock { store.listings[profile]?.first { $0.id == model } }
    }

    public func learnedImages(_ model: String, profile: String) -> Bool? {
        lock.withLock { store.images[Self.key(model, profile)] }
    }

    public func learn(images: Bool, model: String, profile: String) {
        lock.withLock {
            guard store.images[Self.key(model, profile)] != images else { return }
            store.images[Self.key(model, profile)] = images
            save()
        }
    }

    /// A provider error that means "this model does not take images" (worded differently by every vendor).
    public static func isImageRefusal(_ error: Error) -> Bool {
        guard case ProviderError.http(let status, let body) = error, (400..<500).contains(status) else { return false }
        let b = body.lowercased()
        return ["image", "vision", "multimodal", "multi-modal", "image_url", "unsupported content", "content type"].contains { b.contains($0) }
    }
}
