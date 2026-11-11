import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SearchHit: Codable, Sendable, Equatable {
    public var title: String
    public var url: String
    public var snippet: String
    public var published: String?
}

/// International web search backends. All are queried through their public HTTP APIs; the user
/// supplies the key for the one they use (SearXNG needs only a URL to a self-hosted instance).
public enum WebSearchBackend: String, Codable, Sendable, CaseIterable {
    case brave, tavily, exa, googleCSE, searxng
    /// Built in, no key (DuckDuckGo's page): best effort, and not reachable from mainland China without a proxy.
    case builtin
    /// Search APIs that answer from mainland China directly: Bocha, and Zhipu's Web Search (the GLM key).
    case bocha, zhipu
    /// Google results through Serper; Jina's search API.
    case serper, jina
    /// Keyless HTML endpoint; best effort (rate-limited, blocks datacenter IPs). Not for heavy use.
    case duckduckgo
}

public struct WebSearchConfig: Codable, Sendable, Equatable {
    public var backend: WebSearchBackend = .builtin
    public var apiKeyRef: String = ""
    public var searxngURL: String = "http://localhost:8888"
    public var googleCX: String = ""
    /// Domains dropped from results by default: content farms and repost sites that are poor
    /// primary sources for research. Editable in settings.
    public var excludedDomains: [String] = [
        "csdn.net", "zhihu.com", "baidu.com", "baijiahao.baidu.com", "sohu.com", "163.com", "sina.com.cn",
        "toutiao.com", "jianshu.com", "360doc.com", "bilibili.com", "douyin.com", "weixin.qq.com", "cnblogs.com",
    ]
    public init() {}
}

public struct WebSearchClient: Sendable {
    public var config: WebSearchConfig
    let secrets: SecretStore
    let http: HTTPStreaming

    public init(config: WebSearchConfig, secrets: SecretStore, http: HTTPStreaming = URLSessionStreaming()) {
        self.config = config
        self.secrets = secrets
        self.http = http
    }

    func excluded(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return config.excludedDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The backend actually used: a keyed backend without its key falls back to the built-in search,
    /// so research is not blocked before a search key is set up.
    public var effectiveBackend: WebSearchBackend {
        Self.keyRefs[config.backend] != nil && secrets.secret(for: config.apiKeyRef) == nil ? .builtin : config.backend
    }

    /// Backends that need a key, with the name the key is stored under.
    public static let keyRefs: [WebSearchBackend: String] = [.brave: "BRAVE_API_KEY", .tavily: "TAVILY_API_KEY", .exa: "EXA_API_KEY", .googleCSE: "GOOGLE_CSE_KEY",
                                                              .bocha: "BOCHA_API_KEY", .zhipu: "ZHIPU_API_KEY", .serper: "SERPER_API_KEY", .jina: "JINA_API_KEY"]

    static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    func duckDuckGo(_ q: String, count: Int, timeout: TimeInterval) async throws -> [SearchHit] {
        var req = URLRequest(url: try Self.url("https://html.duckduckgo.com/html/?q=\(q)&kl=wt-wt"))
        req.setValue(Self.browserAgent, forHTTPHeaderField: "user-agent")
        req.timeoutInterval = timeout
        let (st, d) = try await http.send(req)
        let html = String(decoding: d, as: UTF8.self)
        guard st < 300, !html.contains("anomaly") else { throw ProviderError.http(status: st, body: "DuckDuckGo refused the request (rate limit / bot check).") }
        return Self.parseDuckDuckGo(html).prefix(count).filter { !excluded($0.url) }
    }

    /// The built-in search: DuckDuckGo's keyless page. Where it cannot be reached (mainland China without a
    /// proxy), the error says what works there instead of a bare timeout.
    func builtinSearch(_ query: String, count: Int) async throws -> [SearchHit] {
        do { return try await duckDuckGo(Self.enc(query), count: count, timeout: 12) } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            throw ProviderError.protocolError("The built-in search (DuckDuckGo) could not be reached: \(error.localizedDescription.truncated(160, marker: "…")). "
                + "In mainland China without a proxy, use a model with its own search (DeepSeek, GLM) or add a Bocha or Zhipu search key in Settings → Web search.")
        }
    }

    /// Query-component encoding: `&`, `=`, `+` and `#` in a query or key must not split the URL.
    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))) ?? s
    }

    /// Settings feed parts of these URLs (SearXNG address, Google CX), so a malformed value is an error, not a crash.
    static func url(_ s: String) throws -> URL {
        guard let u = URL(string: s), u.scheme != nil, u.host != nil else {
            throw ProviderError.protocolError("Invalid search URL “\(s.truncated(80, marker: "…"))”. Check the search settings.")
        }
        return u
    }

    public func search(_ query: String, count: Int = 8) async throws -> [SearchHit] {
        let key = secrets.secret(for: config.apiKeyRef)
        let q = Self.enc(query)
        var req: URLRequest
        let backend = effectiveBackend
        switch backend {
        case .brave:
            guard let key else { throw ProviderError.missingAPIKey(config.apiKeyRef) }
            req = URLRequest(url: try Self.url("https://api.search.brave.com/res/v1/web/search?q=\(q)&count=\(count)"))
            req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        case .tavily:
            guard let key else { throw ProviderError.missingAPIKey(config.apiKeyRef) }
            req = URLRequest(url: try Self.url("https://api.tavily.com/search"))
            req.httpMethod = "POST"
            req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = JSONCodec.canonicalData(["query": .string(query), "max_results": .int(count), "search_depth": "advanced"])
        case .exa:
            guard let key else { throw ProviderError.missingAPIKey(config.apiKeyRef) }
            req = URLRequest(url: try Self.url("https://api.exa.ai/search"))
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = JSONCodec.canonicalData(["query": .string(query), "numResults": .int(count), "contents": ["highlights": true]])
        case .googleCSE:
            guard let key else { throw ProviderError.missingAPIKey(config.apiKeyRef) }
            req = URLRequest(url: try Self.url("https://www.googleapis.com/customsearch/v1?key=\(Self.enc(key))&cx=\(Self.enc(config.googleCX))&q=\(q)&num=\(min(count, 10))"))
        case .searxng:
            let base = config.searxngURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            req = URLRequest(url: try Self.url("\(base)/search?q=\(q)&format=json&language=en"))
        case .bocha:
            guard let key else { throw ProviderError.missingAPIKey(config.apiKeyRef) }
            req = URLRequest(url: try Self.url("https://api.bochaai.com/v1/web-search"))
            req.httpMethod = "POST"
            req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = JSONCodec.canonicalData(["query": .string(query), "count": .int(count), "summary": true, "freshness": "noLimit"])
        case .zhipu:
            guard let key else { throw ProviderError.missingAPIKey(config.apiKeyRef) }
            req = URLRequest(url: try Self.url("https://open.bigmodel.cn/api/paas/v4/web_search"))
            req.httpMethod = "POST"
            req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = JSONCodec.canonicalData(["search_engine": "search_std", "search_query": .string(String(query.prefix(70))), "search_intent": false, "count": .int(count)])
        case .serper:
            guard let key else { throw ProviderError.missingAPIKey(config.apiKeyRef) }
            req = URLRequest(url: try Self.url("https://google.serper.dev/search"))
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = JSONCodec.canonicalData(["q": .string(query), "num": .int(count)])
        case .jina:
            guard let key else { throw ProviderError.missingAPIKey(config.apiKeyRef) }
            req = URLRequest(url: try Self.url("https://s.jina.ai/?q=\(q)"))
            req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
            req.setValue("no-content", forHTTPHeaderField: "x-respond-with")
        case .duckduckgo:
            return try await duckDuckGo(q, count: count, timeout: 30)
        case .builtin:
            return try await builtinSearch(query, count: count)
        }
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.timeoutInterval = 30
        let (status, data) = try await http.send(req)
        guard status < 300 else { throw ProviderError.http(status: status, body: String(decoding: data, as: UTF8.self)) }
        let j = try JSONCodec.parse(data)
        let hits: [SearchHit]
        switch backend {
        case .brave:
            hits = (j["web"]?["results"]?.arrayValue ?? []).map {
                SearchHit(title: $0.str("title") ?? "", url: $0.str("url") ?? "", snippet: $0.str("description") ?? "", published: $0.str("age"))
            }
        case .tavily:
            hits = (j["results"]?.arrayValue ?? []).map {
                SearchHit(title: $0.str("title") ?? "", url: $0.str("url") ?? "", snippet: $0.str("content") ?? "", published: $0.str("published_date"))
            }
        case .exa:
            hits = (j["results"]?.arrayValue ?? []).map {
                SearchHit(title: $0.str("title") ?? "", url: $0.str("url") ?? "",
                          snippet: ($0["highlights"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: " … "),
                          published: $0.str("publishedDate"))
            }
        case .googleCSE:
            hits = (j["items"]?.arrayValue ?? []).map {
                SearchHit(title: $0.str("title") ?? "", url: $0.str("link") ?? "", snippet: $0.str("snippet") ?? "", published: nil)
            }
        case .searxng:
            hits = (j["results"]?.arrayValue ?? []).map {
                SearchHit(title: $0.str("title") ?? "", url: $0.str("url") ?? "", snippet: $0.str("content") ?? "", published: $0.str("publishedDate"))
            }
        case .bocha:
            hits = ((j["data"] ?? j)["webPages"]?["value"]?.arrayValue ?? []).map {
                SearchHit(title: $0.str("name") ?? "", url: $0.str("url") ?? "", snippet: $0.str("summary") ?? $0.str("snippet") ?? "", published: $0.str("datePublished") ?? $0.str("dateLastCrawled"))
            }
        case .zhipu:
            hits = (j["search_result"]?.arrayValue ?? []).map {
                SearchHit(title: $0.str("title") ?? "", url: $0.str("link") ?? $0.str("url") ?? "", snippet: $0.str("content") ?? $0.str("snippet") ?? "", published: $0.str("publish_date"))
            }
        case .serper:
            hits = (j["organic"]?.arrayValue ?? []).map {
                SearchHit(title: $0.str("title") ?? "", url: $0.str("link") ?? "", snippet: $0.str("snippet") ?? "", published: $0.str("date"))
            }
        case .jina:
            hits = (j["data"]?.arrayValue ?? []).map {
                SearchHit(title: $0.str("title") ?? "", url: $0.str("url") ?? "", snippet: $0.str("description") ?? $0.str("content") ?? "", published: $0.str("date"))
            }
        case .duckduckgo, .builtin:
            hits = []  // handled above (HTML, not JSON)
        }
        return hits.filter { !$0.url.isEmpty && !excluded($0.url) }
    }

    static func parseDuckDuckGo(_ html: String) -> [SearchHit] {
        let blocks = html.components(separatedBy: "class=\"result__body")
        return blocks.dropFirst().compactMap { b in
            func grab(_ pat: String) -> String? {
                guard let re = try? NSRegularExpression(pattern: pat, options: [.dotMatchesLineSeparators]),
                      let m = re.firstMatch(in: b, range: NSRange(b.startIndex..., in: b)), let r = Range(m.range(at: 1), in: b) else { return nil }
                return HTMLText.extract(String(b[r]))
            }
            guard var url = grab(#"class="result__a"[^>]*href="([^"]+)""#), let title = grab(#"class="result__a"[^>]*>(.*?)</a>"#) else { return nil }
            if let r = url.range(of: "uddg="), let decoded = url[r.upperBound...].split(separator: "&").first?.removingPercentEncoding { url = decoded }
            return SearchHit(title: title, url: url, snippet: grab(#"class="result__snippet"[^>]*>(.*?)</a>"#) ?? "", published: nil)
        }
    }

    /// Fetches a page and reduces it to readable text (scripts/styles/tags stripped).
    public func fetchText(_ urlString: String, limit: Int = 60_000) async throws -> String {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme ?? "") else {
            throw ToolError.invalidInput("not an http(s) URL")
        }
        if excluded(urlString) { throw ToolError.denied("\(url.host ?? "") is on the excluded-domain list") }
        var req = URLRequest(url: url)
        req.setValue("SieveSci/\(SieveSci.version) (research agent)", forHTTPHeaderField: "user-agent")
        req.timeoutInterval = 30
        let (status, data) = try await http.send(req)
        guard status < 400 else { throw ProviderError.http(status: status, body: "") }
        return HTMLText.extract(String(decoding: data, as: UTF8.self)).truncated(limit)
    }
}

enum HTMLText {
    static func extract(_ html: String) -> String {
        var s = html
        for pat in ["(?is)<script.*?</script>", "(?is)<style.*?</style>", "(?is)<noscript.*?</noscript>", "(?is)<!--.*?-->"] {
            s = s.replacingOccurrences(of: pat, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "(?i)<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (e, r) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            s = s.replacingOccurrences(of: e, with: r)
        }
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
