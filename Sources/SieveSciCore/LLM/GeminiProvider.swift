import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native Gemini API (`models/{model}:streamGenerateContent?alt=sse`).
///
/// - Model turns are replayed from their raw `parts` as received, which keeps every
///   `thoughtSignature` byte-exact (signatures can sit on any part type, and Gemini 3 rejects
///   function-calling history whose signatures were dropped).
/// - Function responses use `{output}` / `{error}`; on Gemini 3+ images nest inside
///   `functionResponse.parts`, older models get a separate user image turn (as in Pi's adapter).
/// - Caching: implicit caching is automatic on Gemini 2.5+; with `.long` retention and a large
///   static prefix, the system instruction + tools are moved into an explicit `cachedContents`
///   entry (guaranteed discount, 1h TTL) managed by `GeminiContextCache`.
public struct GeminiProvider: LLMProvider {
    public let profile: ProviderProfile
    let apiKey: String
    let http: HTTPStreaming
    let contextCache: GeminiContextCache

    /// Explicit caching only pays off for big prefixes; below this, implicit caching suffices.
    public static let explicitCacheMinChars = 4 * 32_768

    public init(profile: ProviderProfile, apiKey: String, http: HTTPStreaming, contextCache: GeminiContextCache = .shared) {
        self.profile = profile
        self.apiKey = apiKey
        self.http = http
        self.contextCache = contextCache
    }

    static func multimodalFunctionResponses(_ model: String) -> Bool {
        let m = model.lowercased()
        return !(m.contains("gemini-1") || m.contains("gemini-2"))
    }

    func contents(for req: LLMRequest) -> [JSON] {
        var toolNames: [String: String] = [:]
        var callIds: Set<String> = []
        var out: [JSON] = []
        for m in req.messages {
            if m.role == .assistant {
                for tu in m.toolUses { toolNames[tu.id] = tu.name }
                // Same-family history: replay raw parts verbatim.
                if case .opaque(let e)? = m.blocks.first(where: { if case .opaque(let e) = $0 { return e.family == .gemini }; return false }),
                   let parts = e.payload["parts"]?.arrayValue {
                    for p in parts { if let id = p["functionCall"]?["id"]?.stringValue { callIds.insert(id) } }
                    out.append(["role": "model", "parts": .array(parts)])
                    continue
                }
                var parts: [JSON] = []
                for b in m.blocks {
                    switch b {
                    case .text(let t) where !t.isEmpty: parts.append(["text": .string(t)])
                    case .toolUse(let tu): parts.append(["functionCall": ["name": .string(tu.name), "args": tu.input]])
                    default: break
                    }
                }
                if !parts.isEmpty { out.append(["role": "model", "parts": .array(parts)]) }
            } else {
                var parts: [JSON] = []
                var trailingImages: [JSON] = []
                for b in m.blocks {
                    switch b {
                    case .text(let t) where !t.isEmpty: parts.append(["text": .string(t)])
                    case .image(let img): parts.append(["inlineData": ["mimeType": .string(img.mediaType), "data": .string(img.base64)]])
                    case .toolResult(let tr):
                        var fr: JSON = ["name": .string(toolNames[tr.toolUseId] ?? "tool"),
                                        "response": tr.isError ? ["error": .string(tr.content)] : ["output": .string(tr.content)]]
                        let imgs: [JSON] = tr.images.map { ["inlineData": ["mimeType": .string($0.mediaType), "data": .string($0.base64)]] }
                        if !imgs.isEmpty {
                            if Self.multimodalFunctionResponses(req.model) { fr = fr.setting("parts", .array(imgs)) } else { trailingImages += imgs }
                        }
                        if callIds.contains(tr.toolUseId) { fr = fr.setting("id", .string(tr.toolUseId)) }
                        parts.append(["functionResponse": fr])
                    default: break
                    }
                }
                if !parts.isEmpty { out.append(["role": "user", "parts": .array(parts)]) }
                if !trailingImages.isEmpty { out.append(["role": "user", "parts": .array(trailingImages)]) }
            }
        }
        return out
    }

    func staticPrefix(for req: LLMRequest) -> (system: JSON, tools: [JSON]) {
        let decls: [JSON] = req.tools.sorted { $0.name < $1.name }.map {
            ["name": .string($0.name), "description": .string($0.description), "parametersJsonSchema": $0.inputSchema]
        }
        return (["parts": [["text": .string(req.system)]]], decls.isEmpty ? [] : [["functionDeclarations": .array(decls)]])
    }

    public func body(for req: LLMRequest, cachedContent: String? = nil) -> JSON {
        let (system, tools) = staticPrefix(for: req)
        var gen: [String: JSON] = ["maxOutputTokens": .int(req.maxTokens)]
        var thinking: [String: JSON] = ["includeThoughts": true]
        if let e = req.effort { thinking["thinkingLevel"] = .string(e == .low ? "low" : (e == .medium ? "medium" : "high")) }
        gen["thinkingConfig"] = .object(thinking)
        var body: [String: JSON] = ["contents": .array(contents(for: req)), "generationConfig": .object(gen)]
        if let cachedContent {
            body["cachedContent"] = .string(cachedContent)   // system + tools live in the cache entry
        } else {
            body["systemInstruction"] = system
            if !tools.isEmpty { body["tools"] = .array(tools) }
        }
        for (k, v) in profile.extraBody { body[k] = v }
        return .object(body)
    }

    func headers() -> [String: String] {
        var h = ["x-goog-api-key": apiKey]
        for (k, v) in profile.options.headers { h[k] = v }
        return h
    }

    public func stream(_ req: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let http = self.http
        let headers = self.headers()
        let model = req.model
        let profile = self.profile
        let cache = self.contextCache
        let prefix = staticPrefix(for: req)
        let wantsExplicit = req.cache.retention == .long && profile.options.supportsLongRetention
            && req.system.count + prefix.tools.map(\.canonical).joined().count >= Self.explicitCacheMinChars
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var cachedName: String?
                    if wantsExplicit {
                        cachedName = try? await cache.entry(profile: profile, model: model, system: prefix.system, tools: prefix.tools,
                                                            headers: headers, http: http)
                    }
                    let body = JSONCodec.canonicalData(self.body(for: req, cachedContent: cachedName))
                    guard let url = profile.endpoint("/models/\(model):streamGenerateContent?alt=sse") else {
                        throw ProviderError.protocolError("bad base URL \(profile.baseURL)")
                    }
                    let resp = try await Retry.withBackoff { try await http.postSSE(.json(url: url, body: body, headers: headers)) }
                    var acc = GeminiAccumulator(model: model)
                    for try await ev in resp.events {
                        cont.yield(.alive)   // any SSE event, pings included: the stream is still answering
                        for out in try acc.consume(ev) { cont.yield(out) }
                    }
                    cont.yield(.completed(acc.finish()))
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

struct GeminiAccumulator {
    let model: String
    var rawParts: [JSON] = []
    var text = ""
    var thoughts = ""
    var calls: [ToolUse] = []
    var usage = Usage()
    var stop: StopReason = .endTurn
    var requestId: String?
    var servedModel: String?

    init(model: String) { self.model = model }

    mutating func consume(_ ev: SSEMessage) throws -> [StreamEvent] {
        guard !ev.data.isEmpty, let j = try? JSONCodec.parse(ev.data) else { return [] }
        if let err = j["error"], !err.isNull { throw ProviderError.protocolError(err["message"]?.stringValue ?? ev.data) }
        requestId = requestId ?? j["responseId"]?.stringValue
        servedModel = servedModel ?? j["modelVersion"]?.stringValue
        if let u = j["usageMetadata"] {
            let prompt = u["promptTokenCount"]?.intValue ?? 0
            let cached = u["cachedContentTokenCount"]?.intValue ?? 0
            usage.cacheRead = cached
            usage.input = max(0, prompt - cached)
            usage.output = (u["candidatesTokenCount"]?.intValue ?? 0) + (u["thoughtsTokenCount"]?.intValue ?? 0)
            usage.reasoning = u["thoughtsTokenCount"]?.intValue ?? 0
        }
        var out: [StreamEvent] = []
        for cand in j["candidates"]?.arrayValue ?? [] {
            for p in cand["content"]?["parts"]?.arrayValue ?? [] {
                rawParts.append(p)
                if let fc = p["functionCall"] {
                    let id = fc["id"]?.stringValue ?? "gemini_call_\(calls.count)_\(UUID().uuidString.prefix(8))"
                    let tu = ToolUse(id: id, name: fc["name"]?.stringValue ?? "", input: fc["args"] ?? .object([:]))
                    calls.append(tu)
                    out.append(.toolCallStarted(id: id, name: tu.name))
                } else if let t = p["text"]?.stringValue {
                    if p["thought"]?.boolValue == true { thoughts += t; out.append(.thinkingDelta(t)) }
                    else { text += t; out.append(.textDelta(t)) }
                }
            }
            if let f = cand["finishReason"]?.stringValue {
                switch f {
                case "MAX_TOKENS": stop = .maxTokens
                case "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION": stop = .refusal
                default: stop = .endTurn
                }
            }
        }
        return out
    }

    func finish() -> LLMResponse {
        let echoModel = servedModel ?? model
        // Raw parts are kept exactly as received (no injected ids); functionResponses for calls
        // without a server id are matched by name, which is how Gemini pairs them.
        var blocks: [ContentBlock] = [.opaque(ProviderEcho(family: .gemini, model: echoModel, payload: ["parts": .array(rawParts)]))]
        if !thoughts.isEmpty { blocks.append(.thinking(ThinkingBlock(text: thoughts))) }
        if !text.isEmpty { blocks.append(.text(text)) }
        blocks += calls.map { .toolUse($0) }
        return LLMResponse(message: Message(role: .assistant, blocks: blocks), stopReason: calls.isEmpty ? stop : .toolUse,
                           usage: usage, providerRequestId: requestId, servedModel: servedModel)
    }
}

/// Manages explicit Gemini `cachedContents` entries keyed by (endpoint, model, prefix fingerprint).
/// Entries are created with a 1h TTL and recreated when expired; the static prefix is frozen per
/// session, so one entry serves the whole session and all its subagents.
public actor GeminiContextCache {
    public static let shared = GeminiContextCache()
    struct Entry { var name: String; var expires: Date }
    var entries: [String: Entry] = [:]

    public func entry(profile: ProviderProfile, model: String, system: JSON, tools: [JSON],
                      headers: [String: String], http: HTTPStreaming) async throws -> String {
        let key = (profile.baseURL + "|" + model + "|" + system.canonical + JSON.array(tools).canonical).stableHash
        if let e = entries[key], e.expires.timeIntervalSinceNow > 120 { return e.name }
        var body: [String: JSON] = ["model": .string("models/\(model)"), "systemInstruction": system, "ttl": "3600s",
                                    "displayName": .string("sievesci-\(key)")]
        if !tools.isEmpty { body["tools"] = .array(tools) }
        guard let url = profile.endpoint("/cachedContents") else { throw ProviderError.protocolError("bad base URL") }
        var r = URLRequest.json(url: url, body: JSONCodec.canonicalData(.object(body)), headers: headers)
        r.setValue("application/json", forHTTPHeaderField: "accept")
        let (status, data) = try await http.send(r)
        guard status < 300, let name = try JSONCodec.parse(data)["name"]?.stringValue else {
            throw ProviderError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        entries[key] = Entry(name: name, expires: Date().addingTimeInterval(3600))
        return name
    }
}
