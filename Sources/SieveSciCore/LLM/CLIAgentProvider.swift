import Foundation

/// Drives a vendor's own, user-signed-in CLI headless. This is how subscription plans (Claude
/// Pro/Max, ChatGPT plans, Google AI Pro/Ultra) are used: SieveSci never touches their OAuth
/// tokens. Each CLI runs its own agent loop and its own (vendor-optimal) prompt caching.
///
/// Flags were taken from the CLIs' own `--help` (claude 2.1.x, codex-cli 0.163, gemini 0.64):
/// - claude: `-p --output-format stream-json --verbose --include-partial-messages`,
///   `--append-system-prompt`, `--resume <id>`, `--model`, `--permission-mode`, `--mcp-config`
/// - codex:  `exec --json --skip-git-repo-check -C <dir> -s <sandbox> [-m]`, `exec resume <id>`
/// - gemini: `-p <prompt> -o stream-json [-m] --approval-mode <plan|auto_edit|yolo|default>`; the workspace
///   is marked trusted with `GEMINI_CLI_TRUST_WORKSPACE=true` (headless runs refuse untrusted folders)
/// - agy (Antigravity CLI): `-p <prompt> --output-format stream-json --print-timeout <d> [--model]
///   [--conversation <id>] --mode <plan|accept-edits> [--dangerously-skip-permissions --sandbox]`;
///   NDJSON `init` / `step_update` / `result` events
///
/// Session continuity: the CLI's session/thread id is remembered per lineage key, so later turns
/// send only the new user content (`--resume`), which is also what keeps the CLI's cache warm.
public struct CLIAgentProvider: LLMProvider {
    public let profile: ProviderProfile
    public var workingDirectory: URL?
    /// "plan" → read-only (claude permission-mode plan / codex read-only sandbox / gemini plan).
    public var readOnly: Bool
    public var mcpConfigPath: String?
    let sessions: CLISessionTable

    public init(profile: ProviderProfile, workingDirectory: URL? = nil, readOnly: Bool = false, mcpConfigPath: String? = nil,
                sessions: CLISessionTable = .shared) {
        self.profile = profile
        self.workingDirectory = workingDirectory
        self.readOnly = readOnly
        self.mcpConfigPath = mcpConfigPath
        self.sessions = sessions
    }

    /// Text sent to the CLI: everything after the last assistant turn when resuming, otherwise the
    /// whole conversation rendered as text.
    static func prompt(for req: LLMRequest, resuming: Bool, includeSystem: Bool) -> String {
        var msgs = req.messages
        if resuming, let lastAssistant = msgs.lastIndex(where: { $0.role == .assistant }) {
            msgs = Array(msgs[(lastAssistant + 1)...])
        }
        var out: [String] = []
        if includeSystem { out.append("<instructions>\n\(req.system)\n</instructions>") }
        for m in msgs {
            for b in m.blocks {
                switch b {
                case .text(let t): out.append(m.role == .user ? t : "[assistant] \(t)")
                case .toolResult(let tr): out.append("[tool result \(tr.toolUseId)]\n\(tr.content)")
                default: break
                }
            }
        }
        return out.joined(separator: "\n\n")
    }

    func arguments(for req: LLMRequest, resumeId: String?) -> [String] {
        let model = req.model.isEmpty ? nil : req.model
        let readOnly = self.readOnly || req.host.readOnly
        let workingDirectory = req.host.workspace ?? self.workingDirectory
        let mcp = req.host.mcp
        // Every CLI runs with its own tools switched off: it may act only through SieveSci's tools
        // (receipts, sandbox, permissions). Without the bridge it can still answer in text.
        var prompt = Self.prompt(for: req, resuming: resumeId != nil, includeSystem: resumeId == nil)
        if resumeId == nil { prompt = (mcp == nil ? CLIHost.noToolsInstructions : CLIHost.toolInstructions) + "\n\n" + prompt }
        switch profile.flavor {
        case .claudeCode:
            var a = ["-p", Self.prompt(for: req, resuming: resumeId != nil, includeSystem: false),
                     "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                     "--append-system-prompt", req.system + "\n\n" + (mcp == nil ? CLIHost.noToolsInstructions : CLIHost.toolInstructions),
                     "--tools", "", "--strict-mcp-config"]
            if let mcp, let config = Self.claudeMCPConfig(mcp) {
                // SieveSci applies its own permission policy to these calls.
                a += ["--mcp-config", config, "--allowedTools", "mcp__sievesci"]
            }
            if let resumeId { a += ["--resume", resumeId] }
            if let model { a += ["--model", model] }
            if readOnly { a += ["--permission-mode", "plan"] }
            return a
        case .codex:
            var a = ["exec"]
            if let resumeId { a += ["resume", resumeId] }
            a += ["--json", "--skip-git-repo-check"]
            if let wd = workingDirectory { a += ["-C", wd.path] }
            a += ["-s", "read-only"]
            for f in Self.codexBuiltinFeatures { a += ["--disable", f] }
            a += ["-c", "web_search=\"disabled\""]
            if let model, model != "default" { a += ["-m", model] }
            if let mcp { a += Self.codexMCPOverrides(mcp) }
            a.append(prompt)
            return a
        case .antigravity:
            // The `sievesci` agent from SieveSci's agy plugin has no built-in tools (only `finish` and,
            // with the bridge, the plugin's MCP server), so permissions can be skipped: the only tools
            // left are SieveSci's, which apply SieveSci's own policy.
            var a = ["-p", prompt, "--output-format", "stream-json", "--print-timeout", "30m",
                     "--agent", mcp == nil ? Self.agyTextAgent : Self.agyAgent, "--dangerously-skip-permissions",
                     "--mode", readOnly ? "plan" : "accept-edits"]
            if let resumeId { a += ["--conversation", resumeId] }
            if let model, model != "default" { a += ["--model", model] }
            return a
        default: // geminiCLI: no per-run switch for its tools; the stream guard stops any built-in use
            var a = ["-p", prompt, "-o", "stream-json", "--approval-mode", "plan"]
            if let resumeId { a += ["--resume", resumeId] }
            if let model { a += ["-m", model] }
            return a
        }
    }

    /// Settings a persistent agy process was started with; a change means a new process.
    func agySignature(_ req: LLMRequest, cwd: URL?) -> String {
        [req.model, req.host.mcp == nil ? Self.agyTextAgent : Self.agyAgent, (readOnly || req.host.readOnly) ? "plan" : "accept-edits",
         cwd?.path ?? "", req.host.mcp?.token ?? ""].joined(separator: "|")
    }

    /// What one turn sends: everything new since the last reply when the conversation continues.
    func agyMessage(_ req: LLMRequest, resuming: Bool) -> String {
        var prompt = Self.prompt(for: req, resuming: resuming, includeSystem: !resuming)
        if !resuming { prompt = (req.host.mcp == nil ? CLIHost.noToolsInstructions : CLIHost.toolInstructions) + "\n\n" + prompt }
        return prompt
    }

    /// `agy` reading turns from stdin (stream-json in and out) for `AgyPool`.
    func agySpawnArguments(_ req: LLMRequest, resumeId: String?) -> [String] {
        var a = ["--input-format", "stream-json", "--output-format", "stream-json", "--print=",
                 "--agent", req.host.mcp == nil ? Self.agyTextAgent : Self.agyAgent, "--dangerously-skip-permissions",
                 "--mode", (readOnly || req.host.readOnly) ? "plan" : "accept-edits"]
        if let resumeId { a += ["--conversation", resumeId] }
        if !req.model.isEmpty, req.model != "default" { a += ["--model", req.model] }
        return a
    }

    static let codexBuiltinFeatures = ["shell_tool", "unified_exec", "apps", "browser_use", "computer_use"]
    static let agyAgent = "sievesci", agyTextAgent = "sievesci-text"

    public func stream(_ req: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let exe = profile.executable ?? "claude"
        let flavor = profile.flavor
        let sessions = self.sessions
        let wd = req.host.workspace ?? workingDirectory
        let key = Self.conversationKey(req, profile: profile)
        let model = req.model
        let self_ = self
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var req = req
                    // Codex's "default" is the first model its catalog offers this account: its own config
                    // can name a model the account may no longer use.
                    if flavor == .codex, req.model.isEmpty || req.model == "default", let m = await CodexCatalog.shared.recommended(exe) { req.model = m }
                    let resumeId = await sessions.get(key)
                    var acc = CLIEventAccumulator(flavor: flavor, model: model)
                    var env = flavor == .geminiCLI ? ["GEMINI_CLI_TRUST_WORKSPACE": "true"] : [:]
                    if let mcp = req.host.mcp { env.merge(mcp.env) { $1 } }
                    let lines: AsyncThrowingStream<String, Error>
                    if flavor == .antigravity {
                        try await AgyPlugin.shared.ensure(exe: exe, bridge: req.host.mcp?.command ?? ToolBridge.shared.bridgeCommand)
                        // One long-lived agy per conversation: later turns skip its startup and sign-in.
                        let sig = self_.agySignature(req, cwd: wd)
                        let live = AgyPool.shared.hasLive(key, signature: sig)
                        let message = self_.agyMessage(req, resuming: live || resumeId != nil)
                        let args = self_.agySpawnArguments(req, resumeId: live ? nil : resumeId)
                        let spawnEnv = env.isEmpty ? nil : env
                        lines = AgyPool.shared.turn(key: key, signature: sig,
                                                    spawn: { try AgyPool.spawn(exe, args, cwd: wd, env: spawnEnv, signature: sig) }, message: message)
                    } else {
                        lines = ProcessRunner.lines(exe, self_.arguments(for: req, resumeId: resumeId), cwd: wd, env: env.isEmpty ? nil : env)
                    }
                    // The CLI starts, signs in and reasons before it says anything, and some models never show
                    // their reasoning: open a thinking row now, so the turn reads as working, not stuck.
                    cont.yield(.thinkingDelta(""))
                    // Codex reports how full its context is only in its rollout file: follow it during the turn.
                    let codexThread = LockedValue<String?>(resumeId)
                    let poller: Task<Void, Never>? = flavor != .codex ? nil : Task {
                        var last: CodexRollout.TokenCount?
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            guard let thread = codexThread.value, let now = CodexRollout.lastTokenCount(thread: thread), now != last else { continue }
                            last = now
                            cont.yield(.contextUsage(tokens: now.tokens, window: now.window))
                        }
                    }
                    defer { poller?.cancel() }
                    do {
                    for try await line in lines {
                        for ev in acc.consume(line) { cont.yield(ev) }
                        if flavor == .codex, let sid = acc.sessionId, codexThread.value != sid { codexThread.mutate { $0 = sid } }
                        // Anything the CLI does must go through SieveSci: a built-in tool ends the turn at once.
                        if let v = acc.violation {
                            throw ProviderError.protocolError(L10n.s("Stopped: %@ tried to use its own tool (%@) instead of SieveSci's tools. Nothing it did outside SieveSci is trusted; the turn was ended.", self_.profile.displayName, v))
                        }
                    }
                    } catch {
                        // A CLI that exits non-zero usually said why on stdout (turn.failed / error events);
                        // that beats its stderr, which is mostly warnings.
                        if let said = acc.error, !said.isEmpty, !(error is CancellationError) { throw ProviderError.protocolError(said) }
                        throw error
                    }
                    for ev in acc.endOfStream() { cont.yield(ev) }
                    poller?.cancel()
                    if flavor == .codex, let sid = acc.sessionId, let tc = CodexRollout.lastTokenCount(thread: sid) {
                        acc.contextTokens = tc.tokens
                        acc.contextWindow = tc.window ?? acc.contextWindow
                    }
                    if let sid = acc.sessionId { await sessions.set(key, sid) }
                    if let rl = acc.rateLimit { await QuotaService.shared.recordCLIEvent(providerId: self_.profile.id, event: rl) }
                    if let err = acc.error, acc.text.isEmpty { throw ProviderError.protocolError(err) }
                    cont.yield(.completed(acc.finish()))
                    cont.finish()
                } catch {
                    cont.finish(throwing: Self.explain(error, flavor: flavor))
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

extension CLIAgentProvider {
    /// Which CLI conversation (resume id, pooled agy process) a request continues.
    static func conversationKey(_ req: LLMRequest, profile: ProviderProfile) -> String {
        (req.host.conversation ?? req.cache.lineageKey) + "|" + profile.id
    }

    /// Ends the pooled agy process of a finished conversation (a later turn resumes it by id).
    static func endProcess(conversation: String, profile: ProviderProfile) {
        AgyPool.shared.stop(conversation + "|" + profile.id)
    }

    /// A per-session `--mcp-config` file for Claude Code (the token is private to this user's temp dir).
    static func claudeMCPConfig(_ mcp: CLIHost.MCP) -> String? {
        let server: JSON = ["type": "stdio", "command": .string(mcp.command[0]), "args": .array(mcp.command.dropFirst().map { .string($0) }),
                            "env": .object(mcp.env.mapValues { .string($0) })]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-mcp-\(mcp.token.prefix(8)).json")
        guard (try? Data(JSON.object(["mcpServers": ["sievesci": server]]).canonical.utf8).writeReliably(to: url)) != nil else { return nil }
        return url.path
    }

    /// `-c` overrides adding the bridge to Codex for this run only (TOML values).
    static func codexMCPOverrides(_ mcp: CLIHost.MCP) -> [String] {
        func toml(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let args = "[" + mcp.command.dropFirst().map(toml).joined(separator: ",") + "]"
        let env = "{" + mcp.env.sorted { $0.key < $1.key }.map { "\($0.key)=\(toml($0.value))" }.joined(separator: ",") + "}"
        return ["-c", "mcp_servers.sievesci.command=\(toml(mcp.command[0]))", "-c", "mcp_servers.sievesci.args=\(args)",
                "-c", "mcp_servers.sievesci.env=\(env)",
                // SieveSci's own permission policy decides; Codex must not block its tools for approval.
                "-c", "mcp_servers.sievesci.default_tools_approval_mode=\"approve\"",
                "-c", "mcp_servers.sievesci.tool_timeout_sec=3600"]
    }

    /// Known CLI failures, said plainly and with the way out (the raw output stays attached).
    static func explain(_ error: Error, flavor: ProviderFlavor) -> Error {
        let raw = "\(error)"
        if raw.contains("IneligibleTierError") || raw.contains("no longer supported for Gemini Code Assist for individuals") {
            return ProviderError.protocolError(L("Google no longer serves personal accounts through Gemini CLI. Use Antigravity CLI (Settings → Providers → Antigravity CLI), a Gemini API key, or a Code Assist Standard/Enterprise licence.") + "\n\n" + raw.truncated(600))
        }
        if flavor == .codex, raw.contains("is not supported when using Codex") || raw.contains("model is not supported") {
            return ProviderError.protocolError(L("Your ChatGPT account cannot use this model in Codex. Pick another (or \"default\") in Settings → Providers → Codex CLI, where the list comes from Codex itself.") + "\n\n" + raw.truncated(400))
        }
        if case ProviderError.cliNotFound(let exe) = error, flavor == .antigravity {
            return ProviderError.protocolError(L10n.s("%@ is not installed. Install Antigravity CLI with `curl -fsSL https://antigravity.google/cli/install.sh | bash`, then run `agy` once in Terminal to sign in.", exe))
        }
        return error
    }
}

public actor CLISessionTable {
    public static let shared = CLISessionTable()
    var ids: [String: String] = [:]
    public func get(_ k: String) -> String? { ids[k] }
    public func set(_ k: String, _ v: String) { ids[k] = v }
}

/// Tolerant NDJSON parser for the three CLIs. Unknown event types are ignored, so CLI upgrades
/// that add events do not break the bridge. Tool activity is surfaced as thinking text (for the UI
/// and the audit log) but is not replayed to other providers.
struct CLIEventAccumulator {
    let flavor: ProviderFlavor
    let model: String
    var text = ""
    var activity: [String] = []
    /// The model's own reasoning, where the CLI streams it (Claude thinking, Codex reasoning summaries).
    var reasoning = ""
    var sawPartialThinking = false
    var usage = Usage()
    /// Prompt tokens of the latest model request inside this turn (`usage` sums all of them).
    var contextTokens: Int?
    var contextWindow: Int?
    var sessionId: String?
    var error: String?
    var sawPartialText = false
    var rateLimit: JSON?
    /// Set when the CLI uses a tool that is not SieveSci's (its built-ins, or another MCP server).
    var violation: String?

    init(flavor: ProviderFlavor, model: String) {
        self.flavor = flavor
        self.model = model
    }

    mutating func consume(_ line: String) -> [StreamEvent] {
        if flavor == .antigravity {
            guard let j = try? JSONCodec.parse(line), let event = j["event"]?.stringValue else { raw += line + "\n"; return [] }
            return antigravity(j, event)
        }
        guard let j = try? JSONCodec.parse(line) else { return [] }
        let type = j["type"]?.stringValue ?? ""
        switch flavor {
        case .claudeCode: return claude(j, type)
        case .codex: return codex(j, type)
        default: return gemini(j, type)
        }
    }

    /// `agy --output-format stream-json`: `init`, then `step_update` (agent text as `text_delta`,
    /// tool steps with `tool_name` / `tool_info`), then one `result` like the json envelope, which may
    /// list `denied_actions`.
    var sawEvents = false
    var denied: [String] = []

    mutating func antigravity(_ j: JSON, _ event: String) -> [StreamEvent] {
        sawEvents = true
        switch event {
        case "init":
            sessionId = j.str("conversation_id") ?? sessionId
        case "step_update":
            guard let st = j["step_update"] else { return [] }
            let state = st.str("state") ?? ""
            switch st.str("step_type") {
            case "agent_response":
                guard let t = st.str("text_delta"), !t.isEmpty else { return [] }
                // agy's `finish` step narrates itself as {"toolAction": …, "toolSummary": …}: not part of the reply.
                if t.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{\"toolAction\"") { return [] }
                text += t
                return [.textDelta(t)]
            case "tool":
                let name = st.str("tool_name") ?? "tool"
                let server = st["tool_info"]?["parameters"]?.str("ServerName") ?? ""
                // MCP plumbing agy grants with MCP access is fine when it points at SieveSci's server
                // (list_resources without a server only lists; it reads nothing).
                let mcpTool = ["call_mcp_tool", "read_resource", "list_resources"].contains(name)
                let ours = server.hasPrefix("sievesci") || (name == "list_resources" && server.isEmpty)
                if name != "finish" && !(mcpTool && ours) {
                    violation = violation ?? (name == "call_mcp_tool" ? "mcp:\(server)" : name)
                }
                if state == "ACTIVE" {
                    let params = st["tool_info"]?["parameters"]?.canonical ?? ""
                    return note("⏺ \(name)(\(params.prefix(160)))")
                }
                if state == "ERROR" {
                    return note("  ✗ \(name): " + (st["tool_info"]?["error"]?.str("message") ?? "failed").truncated(200))
                }
            default: break
            }
        case "result":
            if let r = j["result"] { envelope(r) }
        default: break
        }
        return []
    }

    /// The final envelope (`--output-format json`, or the `result` event of stream-json).
    mutating func envelope(_ j: JSON) {
        sessionId = j.str("conversation_id") ?? j.str("conversationId") ?? sessionId
        let status = (j.str("status") ?? "SUCCESS").uppercased()
        let response = j.str("response") ?? j["response"]?["text"]?.stringValue ?? ""
        if status != "SUCCESS" && status != "OK" && status != "COMPLETED" {
            error = response.isEmpty ? "Antigravity CLI status \(status)" : response
        }
        if let u = j["usage"] {
            func n(_ keys: String...) -> Int { keys.lazy.compactMap { u[$0]?.intValue }.first ?? 0 }
            let cached = n("cache_read_tokens", "cached_tokens", "cachedTokens", "cached_input_tokens", "cachedContentTokenCount", "cache_read_input_tokens")
            usage.cacheRead = cached
            usage.input = max(0, n("input_tokens", "inputTokens", "prompt_tokens", "promptTokenCount") - cached)
            usage.output = n("output_tokens", "outputTokens", "completion_tokens", "candidatesTokenCount")
        }
        denied += (j["denied_actions"]?.arrayValue ?? []).compactMap { $0.str("display_name") ?? $0.str("action") }
        if text.isEmpty && !response.isEmpty { pendingResponse = response }
    }
    var pendingResponse: String?

    /// Antigravity's json envelope, possibly pretty-printed over many lines, is collected and parsed
    /// at the end; stream-json output was handled line by line.
    var raw = ""

    mutating func endOfStream() -> [StreamEvent] {
        guard flavor == .antigravity else { return [] }
        var out: [StreamEvent] = []
        if !sawEvents { out = legacyEnvelope() }
        if text.isEmpty, let r = pendingResponse { text = r; out.append(.textDelta(r)) }
        if text.isEmpty && error == nil {
            error = denied.isEmpty
                ? L("Antigravity CLI finished without a reply.")
                : L10n.s("Antigravity wanted to use %@, which headless agy denies because it cannot ask you. Switch the session to Auto to let it run commands in its own sandbox, or ask for an answer in text.", denied.joined(separator: ", "))
        }
        return out
    }

    mutating func legacyEnvelope() -> [StreamEvent] {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return [] }
        guard let j = (try? JSONCodec.parse(body)) ?? body.split(separator: "\n").reversed().lazy.compactMap({ try? JSONCodec.parse(String($0)) }).first else {
            error = "Antigravity CLI returned unreadable output: " + body.truncated(300)
            return []
        }
        envelope(j)
        return []
    }

    mutating func note(_ s: String) -> [StreamEvent] {
        activity.append(s)
        return [.thinkingDelta(s + "\n")]
    }

    mutating func claude(_ j: JSON, _ type: String) -> [StreamEvent] {
        switch type {
        case "system":
            if sessionId == nil { sessionId = j["session_id"]?.stringValue }
        case "stream_event":
            let e = j["event"]
            if j["parent_tool_use_id"]?.isNull == false { return [] }  // subagent internals
            switch e?["type"]?.stringValue {
            case "message_start":
                // A new model request (the first, or the next after a tool result): its prompt size is
                // the context fill, and the model is reasoning until it writes something.
                var out: [StreamEvent] = [.thinkingDelta("")]
                if let n = Self.claudePromptTokens(e?["message"]?["usage"]) { contextTokens = n; out.append(.contextUsage(tokens: n, window: nil)) }
                return out
            case "content_block_start":
                let kind = e?["content_block"]?["type"]?.stringValue
                if kind == "thinking" || kind == "redacted_thinking" { return [.thinkingDelta("")] }
            case "content_block_delta":
                if let t = e?["delta"]?["text"]?.stringValue {
                    sawPartialText = true
                    text += t
                    return [.textDelta(t)]
                }
                if e?["delta"]?["type"]?.stringValue == "thinking_delta", let t = e?["delta"]?["thinking"]?.stringValue {
                    sawPartialThinking = true
                    reasoning += t
                    return [.thinkingDelta(t)]
                }
            default: break
            }
        case "assistant":
            var out: [StreamEvent] = []
            if j["parent_tool_use_id"]?.isNull != false, let n = Self.claudePromptTokens(j["message"]?["usage"]), n != contextTokens {
                contextTokens = n
                out.append(.contextUsage(tokens: n, window: nil))
            }
            for b in j["message"]?["content"]?.arrayValue ?? [] {
                if b["type"]?.stringValue == "thinking", !sawPartialThinking, let t = b["thinking"]?.stringValue, !t.isEmpty {
                    reasoning += t + "\n"
                    out.append(.thinkingDelta(t + "\n"))
                    continue
                }
                if b["type"]?.stringValue == "tool_use" {
                    let name = b["name"]?.stringValue ?? "tool"
                    if !name.hasPrefix("mcp__sievesci__") { violation = violation ?? name }
                    let input = b["input"]?.canonical ?? ""
                    out += note("⏺ \(b["name"]?.stringValue ?? "tool")(\(input.prefix(160)))")
                } else if b["type"]?.stringValue == "text", !sawPartialText, let t = b["text"]?.stringValue {
                    text += t
                    out.append(.textDelta(t))
                }
            }
            return out
        case "rate_limit_event":
            rateLimit = j["rate_limit_info"] ?? j
        case "result":
            sessionId = j["session_id"]?.stringValue ?? sessionId
            if let r = j["result"]?.stringValue, text.isEmpty { text = r }
            if j["is_error"]?.boolValue == true { error = j["result"]?.stringValue ?? "Claude Code reported an error" }
            if let u = j["usage"] {
                usage.input = u["input_tokens"]?.intValue ?? 0
                usage.cacheRead = u["cache_read_input_tokens"]?.intValue ?? 0
                usage.cacheWrite = u["cache_creation_input_tokens"]?.intValue ?? 0
                usage.output = u["output_tokens"]?.intValue ?? 0
            }
            // `modelUsage` names each model used with its context window; the largest is the main model's.
            let windows = (j["modelUsage"]?.objectValue ?? [:]).values.compactMap { $0["contextWindow"]?.intValue }
            if let w = windows.max(), w > 0 { contextWindow = w }
        default: break
        }
        return []
    }

    /// Prompt size of one Claude request: uncached input plus cache reads and writes.
    static func claudePromptTokens(_ u: JSON?) -> Int? {
        guard let u, let input = u["input_tokens"]?.intValue else { return nil }
        let n = input + (u["cache_read_input_tokens"]?.intValue ?? 0) + (u["cache_creation_input_tokens"]?.intValue ?? 0)
        return n > 0 ? n : nil
    }

    mutating func codex(_ j: JSON, _ type: String) -> [StreamEvent] {
        switch type {
        case "thread.started":
            sessionId = j["thread_id"]?.stringValue
        case "item.completed", "item.started":
            let item = j["item"]
            switch item?["type"]?.stringValue {
            case "command_execution", "file_change", "web_search", "computer_use", "browser_use":
                violation = violation ?? (item?["type"]?.stringValue ?? "tool")
            case "mcp_tool_call" where item?["server"]?.stringValue != "sievesci":
                violation = violation ?? "mcp:\(item?["server"]?.stringValue ?? "?")/\(item?["tool"]?.stringValue ?? "?")"
            default: break
            }
            switch item?["type"]?.stringValue {
            case "agent_message" where type == "item.completed":
                let t = item?["text"]?.stringValue ?? ""
                text += (text.isEmpty ? "" : "\n\n") + t
                return [.textDelta(t)]
            case "command_execution" where type == "item.completed":
                return note("⏺ Bash(\(item?["command"]?.stringValue ?? "")) → exit \(item?["exit_code"]?.intValue.map(String.init) ?? "?")")
            case "file_change" where type == "item.completed":
                let paths = (item?["changes"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }.joined(separator: ", ")
                return note("⏺ Edit(\(paths))")
            case "reasoning" where type == "item.started":
                return [.thinkingDelta("")]
            case "reasoning" where type == "item.completed":
                let t = (item?["text"]?.stringValue ?? "") + "\n"
                reasoning += t
                return [.thinkingDelta(t)]
            case "mcp_tool_call" where type == "item.completed":
                // Back from a SieveSci tool: the model reasons (often invisibly) before its next step.
                return [.thinkingDelta("")]
            default: break
            }
        case "turn.completed":
            let u = j["usage"]
            let cached = u?["cached_input_tokens"]?.intValue ?? 0
            usage.cacheRead = cached
            usage.input = max(0, (u?["input_tokens"]?.intValue ?? 0) - cached)
            usage.output = u?["output_tokens"]?.intValue ?? 0
        case "turn.failed":
            error = j["error"]?["message"]?.stringValue ?? "codex turn failed"
        case "error":
            error = j["message"]?.stringValue
        default: break
        }
        return []
    }

    mutating func gemini(_ j: JSON, _ type: String) -> [StreamEvent] {
        switch type {
        case "init":
            sessionId = j["session_id"]?.stringValue
        case "message":
            guard j["role"]?.stringValue == "assistant", let t = j["content"]?.stringValue else { return [] }
            text += t
            return [.textDelta(t)]
        case "tool_use":
            violation = violation ?? (j["tool_name"]?.stringValue ?? "tool")
            return note("⏺ \(j["tool_name"]?.stringValue ?? "tool")(\((j["parameters"]?.canonical ?? "").prefix(160)))")
        case "result":
            let s = j["stats"]
            usage.input = s?["input_tokens"]?.intValue ?? s?["input"]?.intValue ?? 0
            usage.cacheRead = s?["cached"]?.intValue ?? 0
            usage.output = s?["output_tokens"]?.intValue ?? 0
            if j["status"]?.stringValue == "error" { error = j["error"]?["message"]?.stringValue ?? "gemini error" }
        case "error":
            error = j["message"]?.stringValue
        default: break
        }
        return []
    }

    func finish() -> LLMResponse {
        var blocks: [ContentBlock] = []
        let thought = ([reasoning.trimmingCharacters(in: .whitespacesAndNewlines)] + activity).filter { !$0.isEmpty }
        if !thought.isEmpty { blocks.append(.thinking(ThinkingBlock(text: thought.joined(separator: "\n")))) }
        blocks.append(.text(text))
        return LLMResponse(message: Message(role: .assistant, blocks: blocks), stopReason: .endTurn, usage: usage,
                           providerRequestId: sessionId, servedModel: model, contextTokens: contextTokens, contextWindow: contextWindow)
    }
}

/// The models `codex debug models` lists for this account, read once per run of SieveSci.
actor CodexCatalog {
    static let shared = CodexCatalog()
    private var cached: [String]?

    func recommended(_ exe: String) async -> String? {
        if cached == nil, let r = try? await ProcessRunner.run(exe, ["debug", "models"], timeout: 60), r.exitCode == 0 {
            cached = ModelDiscovery.parseCodexModels(r.stdout).map(\.id)
        }
        return cached?.first
    }
}

/// Codex writes a `token_count` event after every model request to its rollout file
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<thread id>.jsonl`): `last_token_usage` is that
/// request (so its input is how full the context is) and `model_context_window` the window.
/// `codex exec --json` reports only the turn's sum, so the context ring reads it from here.
enum CodexRollout {
    struct TokenCount: Equatable, Sendable { var tokens: Int; var window: Int? }

    static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions") }
    private static let files = LockedValue<[String: URL]>([:])

    static func file(thread: String, root: URL = root) -> URL? {
        if let hit = files.value[thread], FileManager.default.fileExists(atPath: hit.path) { return hit }
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in en where u.pathExtension == "jsonl" && u.lastPathComponent.contains(thread) {
            files.mutate { $0[thread] = u }
            return u
        }
        return nil
    }

    static func lastTokenCount(thread: String, root: URL = root) -> TokenCount? {
        guard let url = file(thread: thread, root: root), let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        // Rollouts grow to many MB; the newest token_count is near the end.
        guard let end = try? fh.seekToEnd() else { return nil }
        try? fh.seek(toOffset: end > 262_144 ? end - 262_144 : 0)
        guard let data = try? fh.readToEnd() else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ text: String) -> TokenCount? {
        for line in text.split(separator: "\n").reversed() where line.contains("\"token_count\"") {
            guard let j = try? JSONCodec.parse(String(line)), let info = j["payload"]?["info"] ?? j["info"], !info.isNull,
                  let tokens = info["last_token_usage"]?["input_tokens"]?.intValue, tokens > 0 else { continue }
            return TokenCount(tokens: tokens, window: info["model_context_window"]?.intValue)
        }
        return nil
    }
}
