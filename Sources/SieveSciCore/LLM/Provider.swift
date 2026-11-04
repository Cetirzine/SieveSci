import Foundation

/// Wire protocol family. Each vendor is reached through its *native* protocol where one exists,
/// because only the native protocol exposes that vendor's full cache controls and usage fields.
public enum ProviderFamily: String, Codable, Sendable, CaseIterable {
    case anthropic        // POST /v1/messages (Claude; also GLM/DeepSeek Anthropic-compatible endpoints)
    case openaiResponses  // POST /v1/responses (OpenAI native)
    case openaiChat       // POST /chat/completions (DeepSeek native, GLM native, generic compatible)
    case gemini           // POST /v1beta/models/{m}:streamGenerateContent (Gemini native)
    case cliAgent         // first-party CLI (Claude Code / Codex / Gemini CLI) driven as a delegate
}

/// Vendor quirks that change request shape or usage parsing within a family.
public enum ProviderFlavor: String, Codable, Sendable {
    case standard
    case deepseek   // prompt_cache_hit_tokens; reasoning_content must be present on tool-call turns
    case zhipu      // GLM: prompt_tokens_details.cached_tokens; thinking.type + reasoning_effort
    case claudeCode, codex, geminiCLI
    case antigravity   // Google Antigravity CLI (`agy`), the successor to Gemini CLI for personal accounts
}

public enum AuthStyle: String, Codable, Sendable {
    case xApiKey        // Anthropic: x-api-key
    case bearer         // Authorization: Bearer
    case googApiKey     // x-goog-api-key
    case none           // CLI agents authenticate themselves
}

/// Per-model settings, editable in the provider page (mirrors ZCode's model edit dialog).
public struct ModelSettings: Codable, Equatable, Sendable {
    public var id: String
    public var contextWindow: Int
    public var maxOutput: Int
    public var supportsImages: Bool
    public var supportsReasoning: Bool

    public init(id: String, contextWindow: Int = 200_000, maxOutput: Int = 32_000, supportsImages: Bool = true, supportsReasoning: Bool = true) {
        self.id = id
        self.contextWindow = contextWindow
        self.maxOutput = maxOutput
        self.supportsImages = supportsImages
        self.supportsReasoning = supportsReasoning
    }
}

/// Wire toggles, modelled on Pi's per-provider "compat" matrix (earendil-works/pi, MIT). Relays
/// (中转站: new-api/one-api, OpenRouter, vendor resellers) differ in which fields they forward, so
/// each cache-related field can be switched off per provider instead of failing with a 400.
public struct ProviderOptions: Codable, Equatable, Sendable {
    /// Anthropic format: emit `cache_control` breakpoints. Most relays forward them verbatim.
    public var anthropicCacheControl: Bool = true
    /// Long retention supported: Anthropic `ttl: "1h"`, OpenAI `prompt_cache_retention: "24h"` or
    /// `prompt_cache_options.ttl: "30m"` (GPT-5.6+), Gemini explicit `cachedContents`.
    public var supportsLongRetention: Bool = true
    /// OpenAI formats: send `prompt_cache_key` (OpenAI routes same-key requests to the same cache).
    public var sendPromptCacheKey: Bool = true
    /// OpenAI Responses: model accepts `prompt_cache_options` (GPT-5.6+); older models reject it.
    public var explicitPromptCacheMode: Bool = false
    /// Chat format via OpenRouter-style relays: put `cache_control` on the system text, last tool and
    /// last message text part (needed when the upstream is Claude or Gemini).
    public var cacheControlInChatParts: Bool = false
    /// Session-affinity headers so a relay pins the session to one replica (and its cache):
    /// "openai" → session_id + x-client-request-id; "openrouter" → x-session-id; "affinity" →
    /// x-session-affinity (Fireworks-style); "" → none.
    public var sessionAffinity: String = ""
    /// Chat format: request `stream_options.include_usage` (needed for cache accounting).
    public var streamUsage: Bool = true
    /// Additional HTTP headers (e.g. OpenRouter's HTTP-Referer / X-Title, relay group headers).
    public var headers: [String: String] = [:]

    public init() {}

    /// Defaults by host, so a user who pastes a base URL gets the right behaviour without toggling.
    public static func detected(family: ProviderFamily, baseURL: String) -> ProviderOptions {
        var o = ProviderOptions()
        let host = URL(string: baseURL)?.host?.lowercased() ?? ""
        let isOpenAI = host == "api.openai.com"
        o.sendPromptCacheKey = isOpenAI
        if host.hasSuffix("openrouter.ai") {
            o.sessionAffinity = "openrouter"
            o.cacheControlInChatParts = family == .openaiChat
        } else if isOpenAI {
            o.sessionAffinity = "openai"
        } else if host.hasSuffix("fireworks.ai") {
            o.sessionAffinity = "affinity"
        }
        // Only first-party Anthropic/OpenAI/Google are known to honour long retention.
        o.supportsLongRetention = host.hasSuffix("anthropic.com") || isOpenAI || host.hasSuffix("googleapis.com")
        return o
    }
}

/// A configured model endpoint. Secrets are not stored here; `apiKeyRef` names a Keychain item
/// (macOS) or environment variable (CLI / tests).
public struct ProviderProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var family: ProviderFamily
    public var flavor: ProviderFlavor
    public var baseURL: String
    public var auth: AuthStyle
    public var apiKeyRef: String
    public var models: [String]
    public var defaultModel: String
    /// "api" (pay-as-you-go key), "plan" (coding plan / subscription) or "relay". Shown in the UI
    /// and the audit log; it never changes request bytes.
    public var billing: String
    public var notes: String
    /// Extra top-level request fields merged into every request (canonical order, so cache-safe).
    public var extraBody: [String: JSON]
    /// For `.cliAgent`: executable name or absolute path.
    public var executable: String?
    public var options: ProviderOptions
    public var modelSettings: [ModelSettings]
    public var enabled: Bool

    public init(
        id: String, displayName: String, family: ProviderFamily, flavor: ProviderFlavor = .standard,
        baseURL: String, auth: AuthStyle, apiKeyRef: String, models: [String], defaultModel: String? = nil,
        billing: String = "api", notes: String = "", extraBody: [String: JSON] = [:], executable: String? = nil,
        options: ProviderOptions = ProviderOptions(), modelSettings: [ModelSettings] = [], enabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.family = family
        self.flavor = flavor
        self.baseURL = baseURL
        self.auth = auth
        self.apiKeyRef = apiKeyRef
        self.models = models
        self.defaultModel = defaultModel ?? models.first ?? ""
        self.billing = billing
        self.notes = notes
        self.extraBody = extraBody
        self.executable = executable
        self.options = options
        self.modelSettings = modelSettings
        self.enabled = enabled
    }

    public func settings(for model: String) -> ModelSettings {
        modelSettings.first { $0.id == model } ?? ModelSettings(id: model)
    }

    /// Joins the base URL with an endpoint path without doubling `/v1`. Anthropic-format bases are
    /// entered without `/v1` (as in ZCode); OpenAI-format bases usually include it.
    public func endpoint(_ path: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        var p = path.hasPrefix("/") ? path : "/" + path
        if base.hasSuffix("/v1"), p.hasPrefix("/v1/") { p.removeFirst(3) }
        return URL(string: base + p)
    }
}

/// How hard the model should think. Mapped per vendor (Anthropic `output_config.effort`, OpenAI
/// `reasoning.effort`, Gemini `thinkingLevel`, DeepSeek/GLM `reasoning_effort`).
public enum Effort: String, Codable, Sendable, CaseIterable {
    case low, medium, high, xhigh, max
}

/// Prompt-cache retention, mapped per wire format (Pi's `cacheRetention` vocabulary).
public enum CacheRetention: String, Codable, Sendable {
    case none   // never mark or key anything (one-shot calls)
    case short  // vendor default (Anthropic 5m, OpenAI in-memory, Gemini implicit)
    case long   // Anthropic 1h on the static prefix; OpenAI 24h / 30m; Gemini explicit cachedContents
}

/// Cache-relevant knobs the agent passes to a provider. Decided once per session lineage and kept
/// fixed: changing any of them mid-session is itself a cache invalidator.
public struct CacheHints: Codable, Equatable, Sendable {
    /// Stable lineage key (root session id). Subagents that share the parent's prefix inherit it, so
    /// OpenAI and affinity-routing relays send them to the same cache shard.
    public var lineageKey: String
    public var retention: CacheRetention

    public init(lineageKey: String, retention: CacheRetention = .short) {
        self.lineageKey = lineageKey
        self.retention = retention
    }

    /// OpenAI caps prompt_cache_key at 64 characters.
    public var promptCacheKey: String { String(("sievesci-" + lineageKey).prefix(64)) }
}

public struct LLMRequest: Sendable {
    public var model: String
    /// Frozen for the whole session. Never interpolate dates, paths or flags into it.
    public var system: String
    /// Sorted by name by `PromptPrefix`; never reordered or swapped mid-session.
    public var tools: [ToolSpec]
    public var messages: [Message]
    public var maxTokens: Int
    public var effort: Effort?
    public var cache: CacheHints
    /// Where and how a CLI agent (Claude Code, Codex, Antigravity …) may act; API providers ignore it.
    public var host = CLIHost()

    public init(model: String, system: String, tools: [ToolSpec], messages: [Message], maxTokens: Int = 32000, effort: Effort? = nil, cache: CacheHints) {
        self.model = model
        self.system = system
        self.tools = tools
        self.messages = messages
        self.maxTokens = maxTokens
        self.effort = effort
        self.cache = cache
    }
}

/// The workspace and permission level a CLI agent runs with: it acts with its own tools, so it must
/// start in the task's workspace and inherit the session's permission mode.
public struct CLIHost: Sendable, Equatable {
    public var workspace: URL?
    /// Plan mode, or a reviewing role: no edits, no commands.
    public var readOnly = false
    /// The user chose "auto": the CLI may run commands without asking (inside its own sandbox).
    public var allowCommands = false
    /// SieveSci's tools for this session, served over MCP (see `ToolBridge`).
    public var mcp: MCP?
    /// The CLI conversation this request belongs to (nil: the request's lineage key). Subagents of one
    /// role share a lineage key for cache routing but each needs its own CLI conversation and process.
    public var conversation: String?
    public init(workspace: URL? = nil, readOnly: Bool = false, allowCommands: Bool = false, mcp: MCP? = nil) {
        self.workspace = workspace; self.readOnly = readOnly; self.allowCommands = allowCommands; self.mcp = mcp
    }

    public struct MCP: Sendable, Equatable {
        public var url: String
        public var token: String
        /// The stdio bridge the CLI starts (`sievesci-cli mcp-bridge`).
        public var command: [String]
        public var env: [String: String] { ["SIEVESCI_MCP_URL": url, "SIEVESCI_MCP_TOKEN": token, "SIEVESCI_BRIDGE_EXE": command.first ?? ""] }
    }

    /// Told to a CLI agent when SieveSci's tools could not be connected: it has no tools at all.
    public static let noToolsInstructions = """
    You have no tools in this session (your built-in tools are switched off by SieveSci). Answer in text \
    from what is in this conversation, and say plainly what would need to be run or checked.
    """

    /// Told to every CLI agent that has SieveSci's tools.
    public static let toolInstructions = """
    SieveSci's tools are available to you through the MCP server "sievesci" (python, bash, read_file, \
    write_file, edit_file, literature and database search, claims, notebook, and `task` / `dispatch` to \
    hand independent subtasks to worker agents …). Use them for all code \
    execution, file access, web and literature work: their results carry SieveSci receipts, which the \
    checker and the blind verifier rely on and which make numbers citable. Do not use your own built-in \
    shell, file, search or web tools: they are switched off, and using one ends the turn.
    """
}

/// Unified token accounting. `input` is uncached input only.
public struct Usage: Codable, Equatable, Sendable {
    public var input: Int = 0
    public var cacheRead: Int = 0
    public var cacheWrite: Int = 0
    public var output: Int = 0
    public var reasoning: Int = 0

    public init(input: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, output: Int = 0, reasoning: Int = 0) {
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
        self.reasoning = reasoning
    }

    public var promptTotal: Int { input + cacheRead + cacheWrite }
    /// Fraction of prompt tokens served from cache.
    public var hitRate: Double { promptTotal == 0 ? 0 : Double(cacheRead) / Double(promptTotal) }

    public static func + (a: Usage, b: Usage) -> Usage {
        Usage(input: a.input + b.input, cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite,
              output: a.output + b.output, reasoning: a.reasoning + b.reasoning)
    }
}

public enum StopReason: String, Codable, Sendable {
    case endTurn, toolUse, maxTokens, refusal, pause, error
}

public struct LLMResponse: Sendable {
    public var message: Message
    public var stopReason: StopReason
    public var usage: Usage
    public var providerRequestId: String?
    public var servedModel: String?
    /// Prompt tokens of the last model request, when that differs from `usage`: a CLI agent's turn
    /// is many requests and its `usage` is their sum, which is not how full the context is.
    public var contextTokens: Int?
    /// The context window the provider reported for the served model (Claude Code, Codex).
    public var contextWindow: Int?

    public init(message: Message, stopReason: StopReason, usage: Usage, providerRequestId: String? = nil, servedModel: String? = nil,
                contextTokens: Int? = nil, contextWindow: Int? = nil) {
        self.message = message
        self.stopReason = stopReason
        self.usage = usage
        self.providerRequestId = providerRequestId
        self.servedModel = servedModel
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
    }
}

public enum StreamEvent: Sendable {
    case textDelta(String)
    case thinkingDelta(String)
    case toolCallStarted(id: String, name: String)
    case toolInputDelta(id: String, partialJSON: String)
    /// Mid-turn context fill (prompt tokens of the request just made), for providers whose one call
    /// spans many model requests (CLI agents), so the context ring moves during a long turn.
    case contextUsage(tokens: Int, window: Int?)
    case completed(LLMResponse)
}

public protocol LLMProvider: Sendable {
    var profile: ProviderProfile { get }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

extension LLMProvider {
    /// Collects a stream into its final response (used by subagents and verifiers).
    public func complete(_ request: LLMRequest, onEvent: (@Sendable (StreamEvent) -> Void)? = nil) async throws -> LLMResponse {
        var final: LLMResponse?
        for try await ev in stream(request) {
            onEvent?(ev)
            if case .completed(let r) = ev { final = r }
        }
        guard let final else { throw ProviderError.protocolError("stream ended without a final message") }
        return final
    }
}

public enum ProviderError: Error, LocalizedError, Sendable {
    case missingAPIKey(String)
    case http(status: Int, body: String)
    case protocolError(String)
    case refused(String)
    case cliNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let ref): return "No API key configured for \(ref)."
        case .http(let s, let b): return "HTTP \(s): \(b.truncated(800))"
        case .protocolError(let m): return "Provider protocol error: \(m)"
        case .refused(let m): return "Model declined: \(m)"
        case .cliNotFound(let m): return "CLI not found: \(m)"
        }
    }

    /// 408/409/429/5xx and transport errors are retryable; other 4xx are not.
    public var isRetryable: Bool {
        if case .http(let s, _) = self { return s == 408 || s == 409 || s == 429 || s >= 500 }
        return false
    }
}

/// Resolves secrets. The app backs this with the Keychain; the CLI with environment variables.
public protocol SecretStore: Sendable {
    func secret(for ref: String) -> String?
}

public struct EnvironmentSecretStore: SecretStore {
    public init() {}
    public func secret(for ref: String) -> String? {
        let v = ProcessInfo.processInfo.environment[ref]
        return (v?.isEmpty ?? true) ? nil : v
    }
}

/// Environment variables first, then the keys the SieveSci app saved in the macOS Keychain, so the
/// CLI works with the same keys without exporting them. macOS shows its usual permission prompt the
/// first time. Values are cached for the process and never logged.
public final class KeychainFallbackSecretStore: SecretStore, @unchecked Sendable {
    public static let service = "app.sievesci.SieveSci"
    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    public init() {}

    public func secret(for ref: String) -> String? {
        guard !ref.isEmpty else { return nil }
        if let v = EnvironmentSecretStore().secret(for: ref) { return v }
        #if os(macOS)
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[ref] { return hit }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", Self.service, "-a", ref, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var value: String?
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readRest()
            p.waitUntilExit()
            let v = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0, !v.isEmpty { value = v }
        }
        cache[ref] = value
        return value
        #else
        return nil
        #endif
    }
}

public enum ProviderFactory {
    public static func make(_ profile: ProviderProfile, secrets: SecretStore, http: HTTPStreaming = URLSessionStreaming()) throws -> LLMProvider {
        func key() throws -> String {
            guard let k = secrets.secret(for: profile.apiKeyRef) else { throw ProviderError.missingAPIKey(profile.apiKeyRef) }
            return k
        }
        switch profile.family {
        case .anthropic: return AnthropicProvider(profile: profile, apiKey: try key(), http: http)
        case .openaiResponses: return OpenAIResponsesProvider(profile: profile, apiKey: try key(), http: http)
        case .openaiChat: return OpenAIChatProvider(profile: profile, apiKey: try key(), http: http)
        case .gemini: return GeminiProvider(profile: profile, apiKey: try key(), http: http)
        case .cliAgent: return CLIAgentProvider(profile: profile)
        }
    }
}
