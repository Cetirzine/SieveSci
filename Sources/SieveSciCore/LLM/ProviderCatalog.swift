import Foundation

/// Provider directory and model metadata, loaded from two bundled upstream catalogs instead of
/// hand-maintained tables:
///
/// - `catalog/provider_protocol_endpoints.json` — from Reasonix (MIT). Verified base URLs per
///   vendor|region|plan for each wire format, each with its documentation source and check date.
/// - `catalog/zcode-builtin.json` — from ZCode (Apache-2.0). Provider templates plus regex rules
///   giving per-model context window, modalities, max output and reasoning levels.
///
/// See THIRD_PARTY_NOTICES.md. Both files can be refreshed from upstream without code changes.
public struct ProviderCatalog: Sendable {
    public struct Route: Codable, Sendable, Equatable {
        public init(baseUrl: String, source: String?, checkedOn: String?, authHeader: Bool?) {
            self.baseUrl = baseUrl; self.source = source; self.checkedOn = checkedOn; self.authHeader = authHeader
        }
        public var baseUrl: String
        public var source: String?
        public var checkedOn: String?
        /// Anthropic-format routes that expect `Authorization: Bearer` instead of `x-api-key`.
        public var authHeader: Bool?
    }

    /// One row of the directory, e.g. "zai|cn|coding" → GLM Coding Plan (mainland).
    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: String           // "vendor|region|plan"
        public var vendor: String
        public var region: String
        public var plan: String         // api | coding | token | local | go | zen
        public var routes: [ProviderFamily: Route]
    }

    public var entries: [Entry]
    public var modelRules: ModelRules

    public static let shared: ProviderCatalog = (try? .loadBundled()) ?? ProviderCatalog(entries: [], modelRules: ModelRules(rules: []))

    public static func loadBundled() throws -> ProviderCatalog {
        // Refreshed copies (CatalogRefresher) win over the bundled ones.
        func pick(_ name: String) -> URL? {
            let refreshed = CatalogRefresher.dir.appendingPathComponent("\(name).json")
            if FileManager.default.fileExists(atPath: refreshed.path) { return refreshed }
            return SieveSciResources.bundle.url(forResource: name, withExtension: "json", subdirectory: "Resources/catalog")
        }
        guard let eURL = pick("provider_protocol_endpoints"), let mURL = pick("zcode-builtin") else {
            throw ProviderError.protocolError("catalogs missing")
        }
        return try load(endpoints: Data(contentsOf: eURL), zcode: Data(contentsOf: mURL))
    }

    public static func load(endpoints: Data, zcode: Data) throws -> ProviderCatalog {
        let raw = try JSONDecoder().decode([String: [String: Route]].self, from: endpoints)
        var entries: [Entry] = []
        for (key, formats) in raw {
            let parts = key.split(separator: "|").map(String.init)
            guard parts.count == 3 else { continue }
            var routes: [ProviderFamily: Route] = [:]
            for (fmt, r) in formats {
                switch fmt {
                case "openai": routes[.openaiChat] = r
                case "responses": routes[.openaiResponses] = r
                case "anthropic": routes[.anthropic] = r
                default: continue
                }
            }
            entries.append(Entry(id: key, vendor: parts[0], region: parts[1], plan: parts[2], routes: routes))
        }
        // Gemini's native generateContent route is not in the Reasonix table (it lists only the
        // OpenAI-compatible route); add it because native is what exposes cachedContents.
        if let i = entries.firstIndex(where: { $0.id == "gemini|global|api" }) {
            entries[i].routes[.gemini] = Route(baseUrl: "https://generativelanguage.googleapis.com/v1beta",
                                               source: "https://ai.google.dev/api/generate-content", checkedOn: nil, authHeader: nil)
        }
        entries.sort { $0.id < $1.id }
        return ProviderCatalog(entries: entries, modelRules: try ModelRules.parse(zcode))
    }

    /// The format SieveSci prefers for a vendor: its own native protocol when one exists.
    public static func nativeFamily(for entry: Entry) -> ProviderFamily? {
        let order: [ProviderFamily]
        switch entry.vendor {
        case "anthropic": order = [.anthropic]
        case "openai", "xai": order = [.openaiResponses, .openaiChat]
        case "gemini": order = [.gemini, .openaiChat]
        // DeepSeek and Zhipu publish Chat Completions as their primary API; it reports their cache
        // fields (prompt_cache_hit_tokens, cached_tokens) natively.
        case "deepseek", "zai", "kimi", "qwen", "doubao": order = [.openaiChat, .anthropic, .openaiResponses]
        default: order = [.anthropic, .openaiResponses, .openaiChat]
        }
        return order.first { entry.routes[$0] != nil }
    }

    /// Builds an editable profile from a directory entry (the "供应商目录" path in the provider page).
    public func profile(for entry: Entry, family: ProviderFamily? = nil) -> ProviderProfile? {
        guard let fam = family ?? Self.nativeFamily(for: entry), let route = entry.routes[fam] else { return nil }
        let auth: AuthStyle
        switch fam {
        case .anthropic: auth = (route.authHeader ?? false) ? .bearer : .xApiKey
        case .gemini: auth = .googApiKey
        case .cliAgent: auth = .none
        default: auth = .bearer
        }
        let flavor: ProviderFlavor = entry.vendor == "deepseek" ? .deepseek : (entry.vendor == "zai" ? .zhipu : .standard)
        var options = ProviderOptions()
        // Only OpenAI itself is known to honour prompt_cache_key; unknown fields 400 on strict backends.
        options.sendPromptCacheKey = (entry.vendor == "openai")
        options.cacheControlInChatParts = (entry.vendor == "openrouter" && fam == .openaiChat)
        let billing = ["coding", "token", "go", "zen"].contains(entry.plan) ? "plan" : (entry.plan == "local" ? "local" : "api")
        return ProviderProfile(
            id: entry.id.replacingOccurrences(of: "|", with: "-") + "-" + fam.rawValue,
            displayName: "\(entry.vendor) · \(entry.region) · \(entry.plan)",
            family: fam, flavor: flavor, baseURL: route.baseUrl, auth: auth,
            apiKeyRef: entry.vendor.uppercased() + "_" + entry.plan.uppercased() + "_API_KEY",
            models: [], billing: billing, notes: route.source ?? "", options: options)
    }
}

/// ZCode-compatible model rule evaluation: every rule whose patterns full-match is applied as a
/// JSON merge patch, in the order model → model-api → provider-site → template-model.
/// Model ids match case-insensitively (as in ZCode's `matchesRule(pattern, id, true)`).
public struct ModelRules: Sendable {
    public struct Rule: Sendable {
        var modelMatch: String?
        var apiTypeMatch: String?
        var baseUrlMatch: String?
        var templateId: String?
        var modelId: String?
        var config: JSON
    }

    public var rules: [Rule] { didSet { cache = SettingsCache() } }

    public init(rules: [Rule]) { self.rules = rules }

    /// Resolved settings per (model, API format, endpoint). Resolving merges the matching rules (about a
    /// millisecond each); Settings and every configuration change resolve every configured model twice.
    final class SettingsCache: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: ModelSettings] = [:]
    }
    private var cache = SettingsCache()

    static func parse(_ data: Data) throws -> ModelRules {
        let root = try JSONCodec.parse(data)
        guard let mr = root["config"]?["modelConfigRules"] else { return ModelRules(rules: []) }
        var out: [Rule] = []
        for key in ["modelRules", "modelApiRules", "providerSiteRules", "templateModelRules"] {
            for r in mr[key]?.arrayValue ?? [] {
                out.append(Rule(modelMatch: r["modelMatch"]?.stringValue, apiTypeMatch: r["apiTypeMatch"]?.stringValue,
                                baseUrlMatch: r["baseUrlMatch"]?.stringValue, templateId: r["templateId"]?.stringValue,
                                modelId: r["modelId"]?.stringValue, config: r["config"] ?? .object([:])))
            }
        }
        return ModelRules(rules: out)
    }

    static func zcodeApiType(_ f: ProviderFamily) -> String {
        switch f {
        case .anthropic: return "anthropic-messages"
        case .openaiResponses: return "openai-responses"
        default: return "openai-chat-completions"
        }
    }

    static func fullMatch(_ pattern: String, _ value: String, ignoreCase: Bool = false) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "^(?:\(pattern))$", options: ignoreCase ? [.caseInsensitive] : []) else { return false }
        return re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// Effective merged config for a model on an endpoint.
    public func resolve(modelId: String, family: ProviderFamily, baseURL: String, templateId: String? = nil) -> JSON {
        var merged: JSON = .object([:])
        let api = Self.zcodeApiType(family)
        for r in rules {
            if let t = r.templateId {
                guard t == templateId, r.modelId?.lowercased() == modelId.lowercased() else { continue }
            } else {
                guard let mm = r.modelMatch, Self.fullMatch(mm, modelId, ignoreCase: true) else { continue }
                if let a = r.apiTypeMatch, !Self.fullMatch(a, api) { continue }
                if let b = r.baseUrlMatch, !Self.fullMatch(b, baseURL) { continue }
            }
            merged = MergePatch.apply(r.config, to: merged)
        }
        return merged
    }

    public func settings(modelId: String, family: ProviderFamily, baseURL: String) -> ModelSettings {
        let key = "\(modelId)\u{1}\(family.rawValue)\u{1}\(baseURL)"
        if let hit = cache.lock.withLock({ cache.values[key] }) { return hit }
        let s = resolvedSettings(modelId: modelId, family: family, baseURL: baseURL)
        cache.lock.withLock { cache.values[key] = s }
        return s
    }

    func resolvedSettings(modelId: String, family: ProviderFamily, baseURL: String) -> ModelSettings {
        let c = resolve(modelId: modelId, family: family, baseURL: baseURL)
        let props = c["properties"]
        let input = props?["inputFormat"]
        let levels = c["optionSpecs"]?["reasoningLevel"]?["values"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return ModelSettings(
            id: modelId,
            contextWindow: props?["contextWindow"]?.intValue ?? 200_000,
            maxOutput: c["optionSpecs"]?["maxOutputTokens"]?["max"]?.intValue ?? 32_000,
            supportsImages: input?["supportsImage"]?.boolValue ?? false,
            supportsReasoning: levels.contains { $0 != "disabled" })
    }
}

/// RFC 7386 JSON Merge Patch.
public enum MergePatch {
    public static func apply(_ patch: JSON, to target: JSON) -> JSON {
        guard case .object(let p) = patch else { return patch }
        var t = target.objectValue ?? [:]
        for (k, v) in p {
            if v.isNull { t.removeValue(forKey: k) } else { t[k] = apply(v, to: t[k] ?? .null) }
        }
        return .object(t)
    }
}
