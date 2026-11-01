import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native OpenAI Responses API (`POST /responses`, SSE), stateless (`store: false`).
///
/// Cache behaviour follows Pi's openai-responses adapter (earendil-works/pi, MIT):
/// - `prompt_cache_key` (≤64 chars) = lineage key, so parent and subagents share a cache shard;
/// - long retention: `prompt_cache_options.ttl: "30m"` on models that accept it (GPT-5.6+),
///   otherwise `prompt_cache_retention: "24h"`;
/// - session-affinity headers (`session_id`, `x-client-request-id`) for OpenAI;
/// - reasoning items are requested with `include: ["reasoning.encrypted_content"]` and echoed back
///   verbatim, so reasoning survives across turns without server-side storage.
public struct OpenAIResponsesProvider: LLMProvider {
    public let profile: ProviderProfile
    let apiKey: String
    let http: HTTPStreaming

    public init(profile: ProviderProfile, apiKey: String, http: HTTPStreaming) {
        self.profile = profile
        self.apiKey = apiKey
        self.http = http
    }

    public func body(for req: LLMRequest) -> JSON {
        var input: [JSON] = []
        for m in req.messages {
            var parts: [JSON] = []
            func flushParts() {
                if !parts.isEmpty {
                    input.append(["role": .string(m.role.rawValue), "content": .array(parts)])
                    parts = []
                }
            }
            for b in m.blocks {
                switch b {
                case .text(let t) where !t.isEmpty:
                    parts.append(["type": m.role == .user ? "input_text" : "output_text", "text": .string(t)])
                case .image(let img) where m.role == .user:
                    parts.append(["type": "input_image", "image_url": .string("data:\(img.mediaType);base64,\(img.base64)")])
                case .thinking(let th):
                    flushParts()
                    if let e = th.echo, e.family == .openaiResponses { input.append(e.payload) }
                case .opaque(let e) where e.family == .openaiResponses:
                    flushParts()
                    input.append(e.payload)
                case .toolUse(let tu):
                    flushParts()
                    let args = tu.echo?.family == .openaiResponses ? (tu.echo?.payload["arguments"]?.stringValue ?? tu.input.canonical) : tu.input.canonical
                    input.append(["type": "function_call", "call_id": .string(tu.id), "name": .string(tu.name), "arguments": .string(args)])
                case .toolResult(let tr):
                    flushParts()
                    let out = tr.isError ? "ERROR: " + tr.content : tr.content
                    input.append(["type": "function_call_output", "call_id": .string(tr.toolUseId), "output": .string(out)])
                    if !tr.images.isEmpty {
                        // Function outputs are text-only; attach images as a following user turn.
                        input.append(["role": "user", "content": .array(tr.images.map {
                            ["type": "input_image", "image_url": .string("data:\($0.mediaType);base64,\($0.base64)")]
                        })])
                    }
                default: break
                }
            }
            flushParts()
        }

        var body: [String: JSON] = [
            "model": .string(req.model),
            "stream": true,
            "store": false,
            "instructions": .string(req.system),
            "input": .array(input),
            "include": ["reasoning.encrypted_content"],
            "max_output_tokens": .int(req.maxTokens),
        ]
        let tools: [JSON] = req.tools.sorted { $0.name < $1.name }.map {
            ["type": "function", "name": .string($0.name), "description": .string($0.description), "parameters": $0.inputSchema]
        }
        if !tools.isEmpty { body["tools"] = .array(tools) }
        if let e = req.effort { body["reasoning"] = ["effort": .string(e == .max ? "xhigh" : e.rawValue), "summary": "auto"] }

        let o = profile.options
        if req.cache.retention != .none, o.sendPromptCacheKey {
            body["prompt_cache_key"] = .string(req.cache.promptCacheKey)
        }
        if req.cache.retention == .long, o.supportsLongRetention {
            if o.explicitPromptCacheMode { body["prompt_cache_options"] = ["ttl": "30m"] }
            else { body["prompt_cache_retention"] = "24h" }
        }
        for (k, v) in profile.extraBody { body[k] = v }
        return .object(body)
    }

    func headers(lineage: String) -> [String: String] {
        var h = ["authorization": "Bearer \(apiKey)"]
        switch profile.options.sessionAffinity {
        case "openai": h["session_id"] = lineage; h["x-client-request-id"] = lineage
        case "openrouter": h["x-session-id"] = lineage
        default: break
        }
        for (k, v) in profile.options.headers { h[k] = v }
        return h
    }

    public func stream(_ req: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let body = JSONCodec.canonicalData(self.body(for: req))
        let url = profile.endpoint("/responses")
        let headers = self.headers(lineage: req.cache.lineageKey)
        let http = self.http
        let model = req.model
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    guard let url else { throw ProviderError.protocolError("bad base URL \(profile.baseURL)") }
                    let resp = try await Retry.withBackoff { try await http.postSSE(.json(url: url, body: body, headers: headers)) }
                    await QuotaService.shared.recordHeaders(providerId: profile.id, headers: resp.headers)
                    var acc = ResponsesAccumulator(model: model)
                    for try await ev in resp.events {
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

struct ResponsesAccumulator {
    let model: String
    var items: [JSON] = []
    var usage = Usage()
    var stop: StopReason = .endTurn
    var requestId: String?
    var servedModel: String?
    var reasoningSummary: [String: String] = [:]

    init(model: String) { self.model = model }

    mutating func consume(_ ev: SSEMessage) throws -> [StreamEvent] {
        guard !ev.data.isEmpty, ev.data != "[DONE]", let j = try? JSONCodec.parse(ev.data) else { return [] }
        switch j["type"]?.stringValue ?? ev.event ?? "" {
        case "response.created":
            requestId = j["response"]?["id"]?.stringValue
            servedModel = j["response"]?["model"]?.stringValue
        case "response.output_item.added":
            if let item = j["item"], item["type"]?.stringValue == "function_call" {
                return [.toolCallStarted(id: item["call_id"]?.stringValue ?? "", name: item["name"]?.stringValue ?? "")]
            }
        case "response.output_text.delta":
            return [.textDelta(j["delta"]?.stringValue ?? "")]
        case "response.reasoning_summary_text.delta":
            let d = j["delta"]?.stringValue ?? ""
            reasoningSummary[j["item_id"]?.stringValue ?? "", default: ""] += d
            return [.thinkingDelta(d)]
        case "response.function_call_arguments.delta":
            return [.toolInputDelta(id: j["item_id"]?.stringValue ?? "", partialJSON: j["delta"]?.stringValue ?? "")]
        case "response.output_item.done":
            if let item = j["item"] { items.append(item) }
        case "response.completed", "response.incomplete":
            let r = j["response"]
            let u = r?["usage"]
            let cached = u?["input_tokens_details"]?["cached_tokens"]?.intValue ?? 0
            usage.cacheRead = cached
            usage.input = max(0, (u?["input_tokens"]?.intValue ?? 0) - cached)
            usage.cacheWrite = u?["input_tokens_details"]?["cache_write_tokens"]?.intValue ?? 0
            usage.input = max(0, usage.input - usage.cacheWrite)
            usage.output = u?["output_tokens"]?.intValue ?? 0
            usage.reasoning = u?["output_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0
            if r?["status"]?.stringValue == "incomplete" { stop = .maxTokens }
            // Some gateways omit encrypted_content on output_item.done but include it here.
            for full in r?["output"]?.arrayValue ?? [] where full["type"]?.stringValue == "reasoning" {
                if let i = items.firstIndex(where: { $0["id"] == full["id"] }), items[i]["encrypted_content"] == nil {
                    items[i] = full
                }
            }
        case "response.failed", "error":
            let msg = j["response"]?["error"]?["message"]?.stringValue ?? j["message"]?.stringValue ?? ev.data
            throw ProviderError.protocolError(msg)
        default: break
        }
        return []
    }

    func finish() -> LLMResponse {
        var blocks: [ContentBlock] = []
        var sawTool = false
        let echoModel = servedModel ?? model
        for item in items {
            switch item["type"]?.stringValue {
            case "message":
                let text = (item["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
                if !text.isEmpty { blocks.append(.text(text)) }
            case "reasoning":
                let summary = (item["summary"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                blocks.append(.thinking(ThinkingBlock(text: summary.isEmpty ? (reasoningSummary[item["id"]?.stringValue ?? ""] ?? "") : summary,
                                                      echo: ProviderEcho(family: .openaiResponses, model: echoModel, payload: item))))
            case "function_call":
                sawTool = true
                let raw = item["arguments"]?.stringValue ?? "{}"
                blocks.append(.toolUse(ToolUse(
                    id: item["call_id"]?.stringValue ?? UUID().uuidString, name: item["name"]?.stringValue ?? "",
                    input: (try? JSONCodec.parse(raw)) ?? .object([:]),
                    echo: ProviderEcho(family: .openaiResponses, model: echoModel, payload: ["arguments": .string(raw)]))))
            default: continue
            }
        }
        return LLMResponse(message: Message(role: .assistant, blocks: blocks), stopReason: sawTool ? .toolUse : stop,
                           usage: usage, providerRequestId: requestId, servedModel: servedModel)
    }
}
