import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider-native web search, following ZCode's `WebSearch` handler: the agent always sees one
/// stable `web_search` tool (so the cached prompt prefix never changes), and the handler fulfils it
/// with a *separate* nested request that carries the provider's server-side `web_search` tool.
///
/// Endpoints with native search (from ZCode's catalog rules, `supportsNativeWebSearch`):
///   Claude on api.anthropic.com · any model on api.deepseek.com/anthropic ·
///   GLM on api.z.ai/api/anthropic and open.bigmodel.cn/api/anthropic (incl. the Coding Plan).
/// For a Chat-format profile on those vendors (e.g. DeepSeek's native API), the sibling Anthropic
/// route from the endpoint catalog is used with the same key.
public struct NativeWebSearch: Sendable {
    public let endpoint: ProviderProfile
    public let model: String
    let apiKey: String
    let http: HTTPStreaming

    static let nativeHosts: [String: String] = [
        "api.anthropic.com": "https://api.anthropic.com",
        "api.deepseek.com": "https://api.deepseek.com/anthropic",
        "api.z.ai": "https://api.z.ai/api/anthropic",
        "open.bigmodel.cn": "https://open.bigmodel.cn/api/anthropic",
    ]

    /// Returns a native-search client for the profile, if its vendor offers one.
    public static func forProfile(_ p: ProviderProfile, model: String, secrets: SecretStore, http: HTTPStreaming = URLSessionStreaming()) -> NativeWebSearch? {
        guard p.family != .cliAgent, let host = URL(string: p.baseURL)?.host?.lowercased(),
              let base = nativeHosts[host], let key = secrets.secret(for: p.apiKeyRef) else { return nil }
        // Only Claude models on Anthropic's own API; any model on DeepSeek / Zhipu.
        if host == "api.anthropic.com" && !AnthropicProvider.isClaude(model) { return nil }
        // Anthropic and DeepSeek take x-api-key (verified live); Zhipu documents Bearer for its Anthropic route.
        let auth: AuthStyle = (host == "api.z.ai" || host == "open.bigmodel.cn") ? .bearer : .xApiKey
        let ep = ProviderProfile(id: p.id + "-websearch", displayName: p.displayName + " (web search)", family: .anthropic,
                                 baseURL: base, auth: auth, apiKeyRef: p.apiKeyRef, models: [model])
        return NativeWebSearch(endpoint: ep, model: model, apiKey: key, http: http)
    }

    public struct Result: Sendable {
        public var hits: [SearchHit]
        public var summary: String
        public var searches: Int
        public var usage: Usage
    }

    public func search(_ query: String, blockedDomains: [String], allowedDomains: [String] = [], maxUses: Int = 5) async throws -> Result {
        var tool: JSON = ["type": "web_search_20250305", "name": "web_search", "max_uses": .int(maxUses)]
        if !allowedDomains.isEmpty { tool = tool.setting("allowed_domains", .array(allowedDomains.map { .string($0) })) }
        else if !blockedDomains.isEmpty { tool = tool.setting("blocked_domains", .array(blockedDomains.map { .string($0) })) }
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        f.locale = Locale(identifier: "en_US")
        let body: JSON = [
            "model": .string(model), "max_tokens": 2048,
            "system": .string("You are an assistant performing a web search tool use. The current month is \(f.string(from: Date())). Search, then list the most relevant findings with their source URLs. Report only what the results say."),
            "messages": [["role": "user", "content": .string("Perform a web search for the query: \(query)")]],
            "tools": [tool],
        ]
        guard let url = endpoint.endpoint("/v1/messages") else { throw ToolError.invalidInput("bad endpoint") }
        var headers = ["anthropic-version": "2023-06-01"]
        if endpoint.auth == .bearer { headers["authorization"] = "Bearer \(apiKey)" } else { headers["x-api-key"] = apiKey }
        var req = URLRequest.json(url: url, body: JSONCodec.canonicalData(body), headers: headers)
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.timeoutInterval = 90
        let (status, data) = try await Retry.withBackoff { try await http.send(req) }
        guard status < 300 else { throw ProviderError.http(status: status, body: String(decoding: data.prefix(800), as: UTF8.self)) }
        let j = try JSONCodec.parse(data)
        var hits: [SearchHit] = []
        var text: [String] = []
        for b in j["content"]?.arrayValue ?? [] {
            switch b.str("type") {
            case "web_search_tool_result":
                if let arr = b["content"]?.arrayValue {
                    for r in arr where r.str("type") == "web_search_result" {
                        let u = (r.str("url") ?? "").replacingOccurrences(of: "#1$", with: "", options: .regularExpression)
                        hits.append(SearchHit(title: r.str("title") ?? "", url: u, snippet: "", published: r.str("page_age")))
                    }
                } else if let err = b["content"]?.str("error_code") {
                    throw ProviderError.protocolError("native web search error: \(err)")
                }
            case "text": if let t = b.str("text") { text.append(t) }
            default: break
            }
        }
        let u = j["usage"]
        let usage = Usage(input: u?.int("input_tokens") ?? 0, cacheRead: u?.int("cache_read_input_tokens") ?? 0,
                          cacheWrite: u?.int("cache_creation_input_tokens") ?? 0, output: u?.int("output_tokens") ?? 0)
        var seen = Set<String>()
        return Result(hits: hits.filter { seen.insert($0.url).inserted }, summary: text.joined(separator: "\n"),
                      searches: u?["server_tool_use"]?.int("web_search_requests") ?? 0, usage: usage)
    }
}
