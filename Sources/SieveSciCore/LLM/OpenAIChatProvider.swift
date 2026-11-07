import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Chat Completions (`POST /chat/completions`, SSE). Native protocol for DeepSeek and Zhipu GLM,
/// and the lingua franca of relays and local servers.
///
/// Wire rules ported from Reasonix's OpenAI adapter (MIT):
/// - `content` is always present (DeepSeek's strict deserializer rejects a missing field): `null`
///   for a pure tool-call assistant turn, a string otherwise.
/// - DeepSeek thinking mode requires `reasoning_content` to be *present* on assistant tool-call
///   turns (empty is fine) and absent elsewhere.
/// - Images in tool results are flushed as a following user message (tool messages are text-only).
/// - Usage: DeepSeek's top-level `prompt_cache_hit_tokens`, OpenAI/GLM's nested
///   `prompt_tokens_details.cached_tokens`, and Anthropic-style fields from some gateways.
public struct OpenAIChatProvider: LLMProvider {
    public let profile: ProviderProfile
    let apiKey: String
    let http: HTTPStreaming

    public init(profile: ProviderProfile, apiKey: String, http: HTTPStreaming) {
        self.profile = profile
        self.apiKey = apiKey
        self.http = http
    }

    /// OpenRouter-style relays need explicit breakpoints when the upstream is Claude or Gemini.
    func wantsPartCacheControl(_ model: String) -> Bool {
        guard profile.options.cacheControlInChatParts else { return false }
        let m = model.lowercased()
        return m.contains("claude") || m.contains("anthropic/") || m.contains("gemini")
    }

    public func body(for req: LLMRequest) -> JSON {
        let partCC = wantsPartCacheControl(req.model) && req.cache.retention != .none
        var msgs: [JSON] = []
        if partCC {
            msgs.append(["role": "system", "content": [["type": "text", "text": .string(req.system), "cache_control": ["type": "ephemeral"]]]])
        } else {
            msgs.append(["role": "system", "content": .string(req.system)])
        }
        let isDeepSeek = profile.flavor == .deepseek

        for m in req.messages {
            switch m.role {
            case .user:
                var textParts: [String] = []
                var images: [ImageBlock] = []
                var pendingToolImages: [ImageBlock] = []
                for b in m.blocks {
                    switch b {
                    case .text(let t): textParts.append(t)
                    case .image(let img): images.append(img)
                    case .toolResult(let tr):
                        msgs.append(["role": "tool", "tool_call_id": .string(tr.toolUseId),
                                     "content": .string(tr.isError ? "ERROR: " + tr.content : tr.content)])
                        pendingToolImages += tr.images
                    default: break
                    }
                }
                let imgs = pendingToolImages + images
                let text = textParts.joined(separator: "\n\n")
                if imgs.isEmpty {
                    if !text.isEmpty { msgs.append(["role": "user", "content": .string(text)]) }
                } else {
                    var parts: [JSON] = imgs.map { ["type": "image_url", "image_url": ["url": .string("data:\($0.mediaType);base64,\($0.base64)")]] }
                    if !text.isEmpty { parts.append(["type": "text", "text": .string(text)]) }
                    msgs.append(["role": "user", "content": .array(parts)])
                }
            case .assistant:
                let text = m.blocks.compactMap(\.text).joined()
                var reasoning: String?
                var calls: [JSON] = []
                for b in m.blocks {
                    if case .thinking(let th) = b, let e = th.echo, e.family == .openaiChat {
                        reasoning = (reasoning ?? "") + (e.payload["reasoning_content"]?.stringValue ?? th.text)
                    }
                    if case .toolUse(let tu) = b {
                        let args = tu.echo?.family == .openaiChat ? (tu.echo?.payload["arguments"]?.stringValue ?? tu.input.canonical) : tu.input.canonical
                        var call: JSON = ["id": .string(tu.id), "type": "function", "function": ["name": .string(tu.name), "arguments": .string(args)]]
                        if let sig = tu.echo?.payload["thought_signature"]?.stringValue {
                            call = call.setting("extra_content", ["google": ["thought_signature": .string(sig)]])
                        }
                        calls.append(call)
                    }
                }
                var am: JSON = ["role": "assistant", "content": calls.isEmpty || !text.isEmpty ? .string(text) : .null]
                // DeepSeek: reasoning is replayed only on tool-call turns; plain answers omit it.
                if !calls.isEmpty {
                    am = am.setting("tool_calls", .array(calls))
                    if isDeepSeek { am = am.setting("reasoning_content", .string(reasoning ?? "")) }
                }
                msgs.append(am)
            }
        }

        // OpenRouter-style: rolling breakpoint on the last text part of the last message.
        if partCC, let last = msgs.indices.last, msgs[last]["role"]?.stringValue != "system" {
            if let s = msgs[last]["content"]?.stringValue, !s.isEmpty {
                msgs[last] = msgs[last].setting("content", [["type": "text", "text": .string(s), "cache_control": ["type": "ephemeral"]]])
            } else if var parts = msgs[last]["content"]?.arrayValue, let i = parts.lastIndex(where: { $0["type"]?.stringValue == "text" }) {
                parts[i] = parts[i].setting("cache_control", ["type": "ephemeral"])
                msgs[last] = msgs[last].setting("content", .array(parts))
            }
        }

        var body: [String: JSON] = [
            "model": .string(req.model),
            "stream": true,
            "messages": .array(msgs),
        ]
        body[Self.usesMaxCompletionTokens(req.model) ? "max_completion_tokens" : "max_tokens"] = .int(req.maxTokens)
        if profile.options.streamUsage { body["stream_options"] = ["include_usage": true] }
        let tools: [JSON] = req.tools.sorted { $0.name < $1.name }.map {
            ["type": "function", "function": ["name": .string($0.name), "description": .string($0.description), "parameters": $0.inputSchema]]
        }
        if !tools.isEmpty { body["tools"] = .array(tools) }
        if let e = req.effort {
            switch profile.flavor {
            // DeepSeek /models advertises low | high | max.
            case .deepseek: body["reasoning_effort"] = .string(e == .low ? "low" : (e == .xhigh || e == .max ? "max" : "high"))
            case .zhipu: body["thinking"] = ["type": "enabled"]; body["reasoning_effort"] = .string(e.rawValue)
            default: body["reasoning_effort"] = .string(e == .max || e == .xhigh ? "high" : e.rawValue)
            }
        }
        if req.cache.retention != .none, profile.options.sendPromptCacheKey {
            body["prompt_cache_key"] = .string(req.cache.promptCacheKey)
            if req.cache.retention == .long, profile.options.supportsLongRetention { body["prompt_cache_retention"] = "24h" }
        }
        for (k, v) in profile.extraBody { body[k] = v }
        return .object(body)
    }

    /// OpenAI's o-series and GPT-5-and-later models reject `max_tokens` (HTTP 400, also through relays
    /// such as CloseAI) and take `max_completion_tokens`; everything else keeps `max_tokens`.
    static func usesMaxCompletionTokens(_ model: String) -> Bool {
        let id = (model.split(separator: "/").last.map(String.init) ?? model).lowercased()
        if id.range(of: #"^o[1-9]\b"#, options: .regularExpression) != nil { return true }
        if let m = id.range(of: #"^gpt-(\d+)"#, options: .regularExpression),
           let major = Int(id[m].dropFirst(4)) { return major >= 5 }
        return false
    }

    func headers(lineage: String) -> [String: String] {
        var h = ["authorization": "Bearer \(apiKey)"]
        switch profile.options.sessionAffinity {
        case "openai": h["session_id"] = lineage; h["x-client-request-id"] = lineage
        case "openrouter": h["x-session-id"] = lineage
        case "affinity": h["x-session-affinity"] = lineage
        case "x-session-id": h["X-Session-Id"] = KnownModels.sessionUUID(lineage)
        default: break
        }
        for (k, v) in profile.options.headers { h[k] = v }
        return h
    }

    public func stream(_ req: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let body = JSONCodec.canonicalData(self.body(for: req))
        let url = profile.endpoint("/chat/completions")
        let headers = self.headers(lineage: req.cache.lineageKey)
        let http = self.http
        let model = req.model
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    guard let url else { throw ProviderError.protocolError("bad base URL \(profile.baseURL)") }
                    let resp = try await Retry.withBackoff { try await http.postSSE(.json(url: url, body: body, headers: headers)) }
                    await QuotaService.shared.recordHeaders(providerId: profile.id, headers: resp.headers)
                    var acc = ChatAccumulator(model: model)
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

struct ChatAccumulator {
    struct Call { var id = ""; var name = ""; var args = ""; var signature: String? }
    let model: String
    var text = ""
    var reasoning = ""
    var calls: [Int: Call] = [:]
    var usage = Usage()
    var stop: StopReason = .endTurn
    var requestId: String?
    var servedModel: String?

    init(model: String) { self.model = model }

    mutating func consume(_ ev: SSEMessage) throws -> [StreamEvent] {
        guard !ev.data.isEmpty, ev.data != "[DONE]", let j = try? JSONCodec.parse(ev.data) else { return [] }
        if let err = j["error"], !err.isNull {
            throw ProviderError.protocolError(err["message"]?.stringValue ?? ev.data)
        }
        if requestId == nil { requestId = j["id"]?.stringValue }
        if servedModel == nil { servedModel = j["model"]?.stringValue }
        if let u = j["usage"], !u.isNull { applyUsage(u) }
        var out: [StreamEvent] = []
        for choice in j["choices"]?.arrayValue ?? [] {
            let d = choice["delta"]
            if let t = d?["content"]?.stringValue, !t.isEmpty { text += t; out.append(.textDelta(t)) }
            // DeepSeek/GLM use reasoning_content; some relays use reasoning.
            if let r = d?["reasoning_content"]?.stringValue ?? d?["reasoning"]?.stringValue, !r.isEmpty {
                reasoning += r; out.append(.thinkingDelta(r))
            }
            for tc in d?["tool_calls"]?.arrayValue ?? [] {
                let i = tc["index"]?.intValue ?? 0
                var c = calls[i] ?? Call()
                if let id = tc["id"]?.stringValue, !id.isEmpty { c.id = id }
                if let n = tc["function"]?["name"]?.stringValue, !n.isEmpty {
                    c.name = n
                    out.append(.toolCallStarted(id: c.id, name: n))
                }
                if let a = tc["function"]?["arguments"]?.stringValue { c.args += a; out.append(.toolInputDelta(id: c.id, partialJSON: a)) }
                if let s = tc["extra_content"]?["google"]?["thought_signature"]?.stringValue { c.signature = s }
                calls[i] = c
            }
            if let f = choice["finish_reason"]?.stringValue {
                switch f {
                case "tool_calls", "function_call": stop = .toolUse
                case "length": stop = .maxTokens
                case "content_filter": stop = .refusal
                default: stop = .endTurn
                }
            }
        }
        return out
    }

    mutating func applyUsage(_ u: JSON) {
        let prompt = u["prompt_tokens"]?.intValue ?? u["input_tokens"]?.intValue ?? 0
        let hit = u["prompt_cache_hit_tokens"]?.intValue
            ?? u["prompt_tokens_details"]?["cached_tokens"]?.intValue
            ?? u["cache_read_input_tokens"]?.intValue ?? 0
        let write = u["cache_creation_input_tokens"]?.intValue ?? u["prompt_tokens_details"]?["cache_write_tokens"]?.intValue ?? 0
        usage.cacheRead = hit
        usage.cacheWrite = write
        usage.input = max(0, prompt - hit - write)
        usage.output = u["completion_tokens"]?.intValue ?? u["output_tokens"]?.intValue ?? 0
        usage.reasoning = u["completion_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0
    }

    func finish() -> LLMResponse {
        var blocks: [ContentBlock] = []
        let echoModel = servedModel ?? model
        if !reasoning.isEmpty {
            blocks.append(.thinking(ThinkingBlock(text: reasoning, echo: ProviderEcho(family: .openaiChat, model: echoModel, payload: ["reasoning_content": .string(reasoning)]))))
        }
        if !text.isEmpty { blocks.append(.text(text)) }
        for i in calls.keys.sorted() {
            let c = calls[i]!
            var payload: [String: JSON] = ["arguments": .string(c.args)]
            if let s = c.signature { payload["thought_signature"] = .string(s) }
            blocks.append(.toolUse(ToolUse(id: c.id.isEmpty ? "call_\(i)" : c.id, name: c.name,
                                           input: (try? JSONCodec.parse(c.args.isEmpty ? "{}" : c.args)) ?? .object([:]),
                                           echo: ProviderEcho(family: .openaiChat, model: echoModel, payload: .object(payload)))))
        }
        return LLMResponse(message: Message(role: .assistant, blocks: blocks), stopReason: calls.isEmpty ? stop : .toolUse,
                           usage: usage, providerRequestId: requestId, servedModel: servedModel)
    }
}
