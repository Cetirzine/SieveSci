import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native Anthropic Messages API (`POST /v1/messages`, SSE). Also used for Anthropic-format
/// endpoints of relays, GLM (`/api/anthropic`) and DeepSeek (`/anthropic`).
public struct AnthropicProvider: LLMProvider {
    public let profile: ProviderProfile
    let apiKey: String
    let http: HTTPStreaming

    public init(profile: ProviderProfile, apiKey: String, http: HTTPStreaming) {
        self.profile = profile
        self.apiKey = apiKey
        self.http = http
    }

    /// Claude models get adaptive thinking + effort; other models behind Anthropic-format endpoints
    /// (GLM, DeepSeek, relays to non-Claude models) get a plain request.
    static func isClaude(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("claude-") || m.contains("/claude-") || m == "opus" || m == "sonnet" || m == "haiku"
    }

    // MARK: Request body

    public func body(for req: LLMRequest) -> JSON {
        var msgs: [[String: JSON]] = req.messages.compactMap { m in
            let blocks = m.blocks.compactMap { wireBlock($0, role: m.role, model: req.model) }
            return blocks.isEmpty ? nil : ["role": .string(m.role.rawValue), "content": .array(blocks)]
        }
        var system: [JSON] = [["type": "text", "text": .string(req.system)]]
        let tools: [JSON] = req.tools.sorted { $0.name < $1.name }.map {
            ["name": .string($0.name), "description": .string($0.description), "input_schema": $0.inputSchema]
        }

        if profile.options.anthropicCacheControl && req.cache.retention != .none {
            let long = req.cache.retention == .long && profile.options.supportsLongRetention
            let plan = AnthropicCachePlan.make(messages: msgs.map { $0["content"]?.arrayValue ?? [] }, prefixTTL: long ? "1h" : "5m")
            var sysCC: JSON = ["type": "ephemeral"]
            if long { sysCC = sysCC.setting("ttl", "1h") }
            system[system.count - 1] = system[system.count - 1].setting("cache_control", sysCC)
            for (mi, bi) in plan.messageBreakpoints {
                guard var content = msgs[mi]["content"]?.arrayValue else { continue }
                content[bi] = content[bi].setting("cache_control", ["type": "ephemeral"])
                msgs[mi]["content"] = .array(content)
            }
        }

        var body: [String: JSON] = [
            "model": .string(req.model),
            "max_tokens": .int(req.maxTokens),
            "stream": true,
            "system": .array(system),
            "messages": .array(msgs.map { .object($0) }),
        ]
        if !tools.isEmpty { body["tools"] = .array(tools) }
        if Self.isClaude(req.model) {
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
            if let e = req.effort { body["output_config"] = ["effort": .string(e.rawValue)] }
        }
        for (k, v) in profile.extraBody { body[k] = v }
        return .object(body)
    }

    func wireBlock(_ b: ContentBlock, role: Role, model: String) -> JSON? {
        switch b {
        case .text(let t):
            return t.isEmpty ? nil : ["type": "text", "text": .string(t)]
        case .image(let img):
            return ["type": "image", "source": ["type": "base64", "media_type": .string(img.mediaType), "data": .string(img.base64)]]
        case .thinking(let th):
            // Signed thinking blocks are echoed verbatim to the same family; the API itself drops
            // blocks the current model cannot read (unbilled). Unsigned/foreign thinking is omitted.
            guard let echo = th.echo, echo.family == .anthropic else { return nil }
            return echo.payload
        case .toolUse(let tu):
            return ["type": "tool_use", "id": .string(tu.id), "name": .string(tu.name), "input": tu.input]
        case .toolResult(let tr):
            var content: [JSON] = [["type": "text", "text": .string(tr.content.isEmpty ? "(no output)" : tr.content)]]
            for img in tr.images {
                content.append(["type": "image", "source": ["type": "base64", "media_type": .string(img.mediaType), "data": .string(img.base64)]])
            }
            var r: JSON = ["type": "tool_result", "tool_use_id": .string(tr.toolUseId), "content": .array(content)]
            if tr.isError { r = r.setting("is_error", true) }
            return r
        case .opaque:
            return nil
        }
    }

    func headers() -> [String: String] {
        var h = ["anthropic-version": "2023-06-01"]
        switch profile.auth {
        case .bearer: h["authorization"] = "Bearer \(apiKey)"
        default: h["x-api-key"] = apiKey
        }
        for (k, v) in profile.options.headers { h[k] = v }
        return h
    }

    func headers(lineage: String) -> [String: String] {
        var h = headers()
        switch profile.options.sessionAffinity {
        case "openrouter": h["x-session-id"] = lineage
        case "affinity": h["x-session-affinity"] = lineage
        case "x-session-id": h["X-Session-Id"] = KnownModels.sessionUUID(lineage)
        default: break
        }
        return h
    }

    // MARK: Streaming

    public func stream(_ req: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let body = JSONCodec.canonicalData(self.body(for: req))
        let url = profile.endpoint("/v1/messages")
        let headers = self.headers(lineage: req.cache.lineageKey)
        let http = self.http
        let model = req.model
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    guard let url else { throw ProviderError.protocolError("bad base URL \(profile.baseURL)") }
                    let resp = try await Retry.withBackoff { try await http.postSSE(.json(url: url, body: body, headers: headers)) }
                    await QuotaService.shared.recordHeaders(providerId: profile.id, headers: resp.headers)
                    var acc = AnthropicAccumulator(model: model)
                    acc.requestId = resp.headers["request-id"]
                    for try await ev in resp.events {
                        for out in try acc.consume(ev) { cont.yield(out) }
                    }
                    cont.yield(.completed(try acc.finish()))
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

/// Folds Anthropic SSE events into deltas for the UI and a final `LLMResponse`.
struct AnthropicAccumulator {
    let model: String
    var requestId: String?
    var servedModel: String?
    var usage = Usage()
    var stop: StopReason = .endTurn
    var blocks: [Int: JSON] = [:]           // raw content blocks by index
    var partialJSON: [Int: String] = [:]
    var order: [Int] = []

    init(model: String) { self.model = model }

    mutating func consume(_ ev: SSEMessage) throws -> [StreamEvent] {
        guard let data = ev.data.data(using: .utf8), !ev.data.isEmpty,
              let j = try? JSONCodec.parse(data) else { return [] }
        switch j["type"]?.stringValue ?? ev.event ?? "" {
        case "message_start":
            let m = j["message"]
            servedModel = m?["model"]?.stringValue
            if requestId == nil { requestId = m?["id"]?.stringValue }
            applyUsage(m?["usage"])
        case "content_block_start":
            guard let i = j["index"]?.intValue, let cb = j["content_block"] else { return [] }
            blocks[i] = cb
            order.append(i)
            if cb["type"]?.stringValue == "tool_use" {
                return [.toolCallStarted(id: cb["id"]?.stringValue ?? "", name: cb["name"]?.stringValue ?? "")]
            }
        case "content_block_delta":
            guard let i = j["index"]?.intValue, let d = j["delta"], var cb = blocks[i] else { return [] }
            switch d["type"]?.stringValue {
            case "text_delta":
                let t = d["text"]?.stringValue ?? ""
                cb = cb.setting("text", .string((cb["text"]?.stringValue ?? "") + t))
                blocks[i] = cb
                return [.textDelta(t)]
            case "thinking_delta":
                let t = d["thinking"]?.stringValue ?? ""
                cb = cb.setting("thinking", .string((cb["thinking"]?.stringValue ?? "") + t))
                blocks[i] = cb
                return [.thinkingDelta(t)]
            case "signature_delta":
                cb = cb.setting("signature", .string((cb["signature"]?.stringValue ?? "") + (d["signature"]?.stringValue ?? "")))
                blocks[i] = cb
            case "input_json_delta":
                let p = d["partial_json"]?.stringValue ?? ""
                partialJSON[i, default: ""] += p
                return [.toolInputDelta(id: cb["id"]?.stringValue ?? "", partialJSON: p)]
            default: break
            }
        case "content_block_stop":
            if let i = j["index"]?.intValue, let raw = partialJSON[i], var cb = blocks[i] {
                cb = cb.setting("input", (try? JSONCodec.parse(raw.isEmpty ? "{}" : raw)) ?? .object([:]))
                blocks[i] = cb
            }
        case "message_delta":
            if let s = j["delta"]?["stop_reason"]?.stringValue { stop = Self.mapStop(s) }
            applyUsage(j["usage"])
        case "error":
            throw ProviderError.protocolError(j["error"]?["message"]?.stringValue ?? ev.data)
        default: break
        }
        return []
    }

    mutating func applyUsage(_ u: JSON?) {
        guard let u else { return }
        if let v = u["input_tokens"]?.intValue { usage.input = v }
        if let v = u["cache_read_input_tokens"]?.intValue { usage.cacheRead = v }
        if let v = u["cache_creation_input_tokens"]?.intValue { usage.cacheWrite = v }
        if let v = u["output_tokens"]?.intValue { usage.output = v }
    }

    static func mapStop(_ s: String) -> StopReason {
        switch s {
        case "tool_use": return .toolUse
        case "max_tokens": return .maxTokens
        case "refusal": return .refusal
        case "pause_turn": return .pause
        default: return .endTurn
        }
    }

    func finish() throws -> LLMResponse {
        var out: [ContentBlock] = []
        for i in order {
            guard let cb = blocks[i] else { continue }
            switch cb["type"]?.stringValue {
            case "text":
                out.append(.text(cb["text"]?.stringValue ?? ""))
            case "thinking", "redacted_thinking":
                // Keep the exact block (with signature) for verbatim replay.
                var raw = cb
                if raw["type"]?.stringValue == "thinking", raw["signature"] == nil { raw = raw.setting("signature", "") }
                out.append(.thinking(ThinkingBlock(text: cb["thinking"]?.stringValue ?? "", echo: ProviderEcho(family: .anthropic, model: servedModel ?? model, payload: raw))))
            case "tool_use":
                out.append(.toolUse(ToolUse(id: cb["id"]?.stringValue ?? UUID().uuidString, name: cb["name"]?.stringValue ?? "", input: cb["input"] ?? .object([:]))))
            default:
                continue
            }
        }
        return LLMResponse(message: Message(role: .assistant, blocks: out), stopReason: stop, usage: usage, providerRequestId: requestId, servedModel: servedModel)
    }
}
