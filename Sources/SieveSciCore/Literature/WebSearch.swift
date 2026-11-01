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
    /// Keyless HTML endpoint; best effort (rate-limited, blocks datacenter IPs). Not for heavy use.
    case duckduckgo
}

public struct WebSearchConfig: Codable, Sendable, Equatable {
    public var backend: WebSearchBackend = .brave
    public var apiKeyRef: String = "BRAVE_API_KEY"
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

    /// The backend actually used: a keyed backend without its key falls back to keyless DuckDuckGo,
    /// so research is not blocked before a search key is set up.
    public var effectiveBackend: WebSearchBackend {
        let keyed: Set<WebSearchBackend> = [.brave, .tavily, .exa, .googleCSE]
        return keyed.contains(config.backend) && secrets.secret(for: config.apiKeyRef) == nil ? .duckduckgo : config.backend
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
        case .duckduckgo:
            req = URLRequest(url: try Self.url("https://html.duckduckgo.com/html/?q=\(q)&kl=wt-wt"))
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "user-agent")
            let (st, d) = try await http.send(req)
            let html = String(decoding: d, as: UTF8.self)
            guard st < 300, !html.contains("anomaly") else { throw ProviderError.http(status: st, body: "DuckDuckGo refused the request (rate limit / bot check). Configure Brave, Tavily, Exa or SearXNG.") }
            return Self.parseDuckDuckGo(html).prefix(count).filter { !excluded($0.url) }
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
        case .duckduckgo:
            hits = []  // handled above (HTML, not JSON)
        }
        return hits.filter { !excluded($0.url) }
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
