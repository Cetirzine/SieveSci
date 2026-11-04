import Foundation
import Testing
@testable import SieveSciCore

private struct Keys: SecretStore {
    let keys: [String: String]
    func secret(for ref: String) -> String? { keys[ref] }
}

@Suite struct AntigravityBridge {
    let profile = ProviderPresets.profile(id: "antigravity")!

    @Test func argumentsFollowTheHeadlessMode() {
        let p = CLIAgentProvider(profile: profile, readOnly: true)
        let req = LLMRequest(model: "default", system: "sys", tools: [], messages: [Message.user("hello")], maxTokens: 100,
                             cache: CacheHints(lineageKey: "l", retention: .short))
        let fresh = p.arguments(for: req, resumeId: nil)
        #expect(fresh.prefix(1) == ["-p"])
        #expect(fresh.contains("--output-format") && fresh.contains("stream-json") && fresh.contains("--print-timeout"))
        #expect(Array(fresh.drop { $0 != "--agent" }.prefix(2)) == ["--agent", "sievesci-text"], "no bridge: the tool-less agent")
        #expect(fresh[1].hasPrefix(CLIHost.noToolsInstructions))
        #expect(Array(fresh.drop { $0 != "--mode" }.prefix(2)) == ["--mode", "plan"])
        #expect(!fresh.contains("--model"), "\"default\" leaves the model to the CLI")
        let resumed = p.arguments(for: req, resumeId: "conv-1")
        #expect(Array(resumed.drop { $0 != "--conversation" }.prefix(2)) == ["--conversation", "conv-1"])
    }

    @Test func parsesThePrettyPrintedEnvelope() {
        var acc = CLIEventAccumulator(flavor: .antigravity, model: "default")
        for line in "{\n  \"conversation_id\": \"c42\",\n  \"status\": \"SUCCESS\",\n  \"response\": \"BRCA1 is P38398.\",\n  \"usage\": {\"input_tokens\": 1200, \"cached_tokens\": 800, \"output_tokens\": 40}\n}".split(separator: "\n") {
            #expect(acc.consume(String(line)).isEmpty)
        }
        let evs = acc.endOfStream()
        #expect(evs.count == 1)
        #expect(acc.text == "BRCA1 is P38398." && acc.sessionId == "c42")
        #expect(acc.usage.input == 400 && acc.usage.cacheRead == 800 && acc.usage.output == 40)
        #expect(acc.error == nil)

        var failed = CLIEventAccumulator(flavor: .antigravity, model: "default")
        _ = failed.consume(#"{"status":"ERROR","response":"Not signed in"}"#)
        _ = failed.endOfStream()
        #expect(failed.error == "Not signed in")
    }

    /// Every CLI runs with its built-in tools off; with the bridge it gets SieveSci's tools instead.
    @Test func everyCLIRunsWithoutItsOwnTools() {
        var req = LLMRequest(model: "m", system: "sys", tools: [], messages: [Message.user("hi")], maxTokens: 100,
                             cache: CacheHints(lineageKey: "l", retention: .short))
        let mcp = CLIHost.MCP(url: "http://127.0.0.1:9/mcp", token: "tok", command: ["/x/sievesci-cli", "mcp-bridge"])
        req.host = CLIHost(workspace: URL(fileURLWithPath: "/tmp/ws"), mcp: mcp)
        func args(_ id: String) -> [String] { CLIAgentProvider(profile: ProviderPresets.profile(id: id)!).arguments(for: req, resumeId: nil) }
        func after(_ a: [String], _ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }

        let claude = args("claude-code")
        #expect(after(claude, "--tools") == "" && claude.contains("--strict-mcp-config"))
        #expect(after(claude, "--allowedTools") == "mcp__sievesci" && claude.contains("--mcp-config"))

        let codex = args("codex")
        for f in CLIAgentProvider.codexBuiltinFeatures { #expect(codex.contains(f), "\(f) disabled") }
        #expect(codex.contains("web_search=\"disabled\"") && codex.contains("mcp_servers.sievesci.default_tools_approval_mode=\"approve\""))
        #expect(codex.last?.hasPrefix(CLIHost.toolInstructions) == true)

        let agy = args("antigravity")
        #expect(after(agy, "--agent") == "sievesci" && agy.contains("--dangerously-skip-permissions"))
        #expect(!agy.contains("--sandbox"))
        #expect(AgyPlugin.files(bridge: mcp.command)["agents/sievesci.md"]?.contains("tools:\n  - finish\ninheritMcp: true") == true)
        #expect(AgyPlugin.files(bridge: mcp.command) == AgyPlugin.files(bridge: ["/other/copy/sievesci-cli", "mcp-bridge"]),
                "the plugin is the same for every copy of SieveSci, so it is never reinstalled under a running agent")
        #expect(mcp.env["SIEVESCI_BRIDGE_EXE"] == "/x/sievesci-cli")
    }

    /// A built-in tool (or another MCP server) in the stream is a violation, whatever the CLI.
    @Test func builtinToolUseIsAViolation() {
        func check(_ flavor: ProviderFlavor, _ line: String) -> String? {
            var a = CLIEventAccumulator(flavor: flavor, model: "m"); _ = a.consume(line); return a.violation
        }
        #expect(check(.claudeCode, #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#) == "Bash")
        #expect(check(.claudeCode, #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__sievesci__bash","input":{}}]}}"#) == nil)
        #expect(check(.codex, #"{"type":"item.started","item":{"type":"command_execution","command":"ls"}}"#) == "command_execution")
        #expect(check(.codex, #"{"type":"item.started","item":{"type":"mcp_tool_call","server":"sievesci","tool":"bash"}}"#) == nil)
        #expect(check(.codex, #"{"type":"item.started","item":{"type":"mcp_tool_call","server":"github","tool":"x"}}"#) != nil)
        #expect(check(.antigravity, #"{"event":"step_update","step_update":{"state":"ACTIVE","step_type":"tool","tool_name":"run_command"}}"#) == "run_command")
        #expect(check(.antigravity, #"{"event":"step_update","step_update":{"state":"ACTIVE","step_type":"tool","tool_name":"call_mcp_tool","tool_info":{"parameters":{"ServerName":"sievesci_sievesci","ToolName":"bash"}}}}"#) == nil)
        #expect(check(.antigravity, #"{"event":"step_update","step_update":{"state":"ACTIVE","step_type":"tool","tool_name":"finish"}}"#) == nil)
        #expect(check(.antigravity, #"{"event":"step_update","step_update":{"state":"ACTIVE","step_type":"tool","tool_name":"read_resource","tool_info":{"parameters":{"ServerName":"sievesci_sievesci","Uri":"x"}}}}"#) == nil)
        #expect(check(.antigravity, #"{"event":"step_update","step_update":{"state":"ACTIVE","step_type":"tool","tool_name":"read_resource","tool_info":{"parameters":{"ServerName":"firebase_mcp","Uri":"x"}}}}"#) != nil)
    }

    /// Claude Code: thinking streams as thinking rows, and the context ring follows each request's
    /// prompt size rather than the turn's summed usage.
    @Test func claudeStreamsThinkingAndPerRequestContext() {
        var acc = CLIEventAccumulator(flavor: .claudeCode, model: "m")
        var thinking = "", rows = 0, fills: [Int] = []
        func feed(_ line: String) {
            for ev in acc.consume(line) {
                switch ev {
                case .thinkingDelta(let t): if t.isEmpty { rows += 1 } else { thinking += t }
                case .contextUsage(let n, _): fills.append(n)
                default: break
                }
            }
        }
        feed(#"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":40000,"cache_creation_input_tokens":2000}}}}"#)
        feed(#"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_start","content_block":{"type":"thinking"}}}"#)
        feed(#"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"Check UniProt first."}}}"#)
        feed(#"{"type":"assistant","parent_tool_use_id":null,"message":{"usage":{"input_tokens":10,"cache_read_input_tokens":40000,"cache_creation_input_tokens":2000},"content":[{"type":"thinking","thinking":"Check UniProt first."}]}}"#)
        feed(#"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"message_start","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":45000}}}}"#)
        feed(#"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"P38398"}}}"#)
        feed(#"{"type":"result","result":"P38398","usage":{"input_tokens":15,"cache_read_input_tokens":85000,"output_tokens":30},"modelUsage":{"claude-x":{"contextWindow":200000},"claude-haiku":{"contextWindow":100000}}}"#)
        #expect(thinking == "Check UniProt first.", "streamed thinking is not repeated from the assistant message")
        #expect(rows == 3, "a thinking row opens at each request and at the thinking block")
        #expect(fills == [42010, 45005])
        let r = acc.finish()
        #expect(r.contextTokens == 45005 && r.contextWindow == 200000)
        #expect(r.usage.cacheRead == 85000, "the turn's spend still counts every request")
        #expect(r.message.blocks.contains { if case .thinking(let t) = $0 { return t.text.contains("UniProt") }; return false })
    }

    @Test func codexReasoningAndRolloutContext() throws {
        var acc = CLIEventAccumulator(flavor: .codex, model: "m")
        #expect(acc.consume(#"{"type":"item.started","item":{"type":"reasoning"}}"#).count == 1)
        let done = acc.consume(#"{"type":"item.completed","item":{"type":"reasoning","text":"Compare isoforms."}}"#)
        #expect(acc.reasoning.contains("Compare isoforms."))
        if case .thinkingDelta(let t)? = done.first { #expect(t.contains("isoforms")) } else { Issue.record("no thinking") }
        #expect(acc.consume(#"{"type":"item.completed","item":{"type":"mcp_tool_call","server":"sievesci","tool":"bash"}}"#).count == 1)

        let rollout = """
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200},"model_context_window":258400}}}
        {"type":"event_msg","payload":{"type":"agent_message"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900000},"last_token_usage":{"input_tokens":163710,"cached_input_tokens":163456},"model_context_window":258400}}}
        {"type":"event_msg","payload":{"type":"token_count","info":null}}
        """
        #expect(CodexRollout.parse(rollout) == .init(tokens: 163710, window: 258400), "the newest request with token info, not the total")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
        let day = root.appendingPathComponent("2026/11/04")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try rollout.write(to: day.appendingPathComponent("rollout-2026-11-04T10-00-00-thread-abc.jsonl"), atomically: true, encoding: .utf8)
        #expect(CodexRollout.lastTokenCount(thread: "thread-abc", root: root)?.tokens == 163710)
        #expect(CodexRollout.lastTokenCount(thread: "thread-zzz", root: root) == nil)
    }

    /// Recorded from agy on 2026-10-17 (trimmed).
    @Test func streamsTextAndExplainsDeniedTools() {
        var acc = CLIEventAccumulator(flavor: .antigravity, model: "m")
        var text = ""
        for line in [#"{"event":"init","conversation_id":"c7","init":{"model":"m"}}"#,
                     #"{"event":"step_update","step_update":{"step_index":2,"state":"ACTIVE","step_type":"agent_response","text_delta":"O"}}"#,
                     #"{"event":"step_update","step_update":{"step_index":2,"state":"DONE","step_type":"agent_response","text_delta":"K"}}"#,
                     #"{"event":"result","result":{"conversation_id":"c7","status":"SUCCESS","response":"OK","usage":{"input_tokens":28563,"output_tokens":1,"cache_read_tokens":0}}}"#] {
            for case .textDelta(let t) in acc.consume(line) { text += t }
        }
        _ = acc.consume(#"{"event":"step_update","step_update":{"step_index":3,"state":"DONE","step_type":"agent_response","text_delta":"{\"toolAction\":\"Finishing task\",\"toolSummary\":\"Task completion\"}\n"}}"#)
        _ = acc.endOfStream()
        #expect(text == "OK" && acc.text == "OK" && acc.sessionId == "c7" && acc.error == nil, "agy's finish narration stays out of the reply")
        #expect(acc.usage.input == 28563 && acc.usage.output == 1)

        var denied = CLIEventAccumulator(flavor: .antigravity, model: "m")
        for line in [#"{"event":"step_update","step_update":{"step_index":3,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"echo hi"}}}}"#,
                     #"{"event":"step_update","step_update":{"step_index":3,"state":"ERROR","step_type":"tool","tool_name":"run_command","tool_info":{"error":{"type":"TOOL_ERROR","message":"permission check failed"}}}}"#,
                     #"{"event":"result","result":{"status":"SUCCESS","response":"","denied_actions":[{"action":"command","display_name":"RunCommand"}]}}"#] {
            _ = denied.consume(line)
        }
        _ = denied.endOfStream()
        #expect(denied.activity.first?.contains("run_command") == true)
        #expect(denied.error?.contains("RunCommand") == true, "an empty reply after a denied tool is explained, not shown blank")
    }

    @Test func geminiTierErrorIsExplained() {
        let raw = ProviderError.protocolError("gemini exited 55: IneligibleTierError: This client is no longer supported for Gemini Code Assist for individuals.")
        let e = CLIAgentProvider.explain(raw, flavor: .geminiCLI)
        #expect("\(e)".contains("Antigravity"))
        #expect("\(CLIAgentProvider.explain(ProviderError.cliNotFound("agy"), flavor: .antigravity))".contains("install.sh"))
    }

    @Test func presetsIncludeAntigravityAndCloseAI() {
        #expect(ProviderPresets.profile(id: "antigravity")?.executable == "agy")
        #expect(ProviderPresets.profile(id: "closeai")?.baseURL == "https://api.openai-proxy.org/v1")
        #expect(ProviderPresets.profile(id: "closeai-anthropic")?.baseURL == "https://api.openai-proxy.org/anthropic")
        #expect(ProviderPresets.profile(id: "closeai-anthropic")?.auth == .xApiKey)
    }
}

@Suite struct PlanLimitsAndBalances {
    @Test func claudeCodeKeepsEveryWindow() async throws {
        let q = QuotaService()
        await q.recordCLIEvent(providerId: "claude-code", event: ["rateLimitType": "five_hour", "status": "allowed", "utilization": 0.37, "resetsAt": 1_800_000_000])
        await q.recordCLIEvent(providerId: "claude-code", event: ["rateLimitType": "seven_day", "status": "allowed_warning", "utilization": 0.81])
        await q.recordCLIEvent(providerId: "claude-code", event: ["rateLimitType": "seven_day_opus", "status": "rejected"])
        let snap = await q.refresh(ProviderPresets.profile(id: "claude-code")!, secrets: Keys(keys: [:]), http: RoutedHTTP([]))
        try #require(snap.meters.map(\.kind) == [.fiveHour, .weekly, .weeklyModel])
        #expect(snap.meters[0].usedFraction == 0.37 && snap.meters[0].resetsAt != nil)
        #expect(snap.meters[2].exhausted && snap.meters[2].detail == "Opus")
    }

    @Test func closeAIBalanceNeedsTheManagementKey() async {
        let p = ProviderPresets.profile(id: "closeai")!
        let http = RoutedHTTP([("/api/v1/management/account/balance", #"{"balance":"2203.81187842"}"#)])
        let without = await QuotaService().refresh(p, secrets: Keys(keys: ["CLOSEAI_API_KEY": "sk-x"]), http: http)
        #expect(without.meters.isEmpty && without.note?.contains("CLOSEAI_ADMIN_KEY") == true)
        let with = await QuotaService().refresh(p, secrets: Keys(keys: ["CLOSEAI_API_KEY": "sk-x", "CLOSEAI_ADMIN_KEY": "sk-admin-y"]), http: http)
        #expect(with.meters.first?.kind == .balance && with.meters.first?.amount == "¥2203.81")
    }

    @Test func newApiRelaysShowTheirCredit() async {
        var p = ProviderPresets.profile(id: "relay-openai")!
        p.baseURL = "https://relay.example.com/v1"
        let http = RoutedHTTP([("/v1/dashboard/billing/subscription", #"{"hard_limit_usd": 50}"#),
                               ("/v1/dashboard/billing/usage", #"{"total_usage": 1250}"#)])
        let snap = await QuotaService().refresh(p, secrets: Keys(keys: ["RELAY_OPENAI_KEY": "sk-r"]), http: http)
        let m = snap.meters.first
        #expect(m?.kind == .credit && m?.amount == "$37.50" && m?.usedFraction == 0.25)
    }

    @Test func deepSeekBalanceIsTyped() async {
        let http = RoutedHTTP([("api.deepseek.com/user/balance", #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"52.29","granted_balance":"0","topped_up_balance":"52.29"}]}"#)])
        let snap = await QuotaService().refresh(ProviderPresets.profile(id: "deepseek")!, secrets: Keys(keys: ["DEEPSEEK_API_KEY": "k"]), http: http)
        #expect(snap.meters.first?.kind == .balance && snap.meters.first?.amount == "¥52.29")
    }
}

@Suite struct AntigravityModels {
    @Test func parsesAgyModelListing() {
        let out = "Fetching available models...\ngemini-3.8-flash-high\tGemini 3.8 Flash (High)\nclaude-sonnet-5-5-low\tClaude Sonnet 5.5 (Low)\n\ngemini-3.8-flash-high\tdup\nnot a model line\n"
        let m = ModelDiscovery.parseAgyModels(out)
        #expect(m.map(\.id) == ["gemini-3.8-flash-high", "claude-sonnet-5-5-low"])
        #expect(m.first?.displayName == "Gemini 3.8 Flash (High)")
    }
}

@Suite struct GLMQuotaWindows {
    /// The shape bigmodel.cn returned on 2026-10-17: both windows are `CREDIT_LIMIT`, told apart by number × unit.
    @Test func splitsFiveHourAndWeeklyCredit() throws {
        let j = try JSONCodec.parse(#"{"limits":[{"currentValue":25001,"nextResetTime":1792400511970,"number":1,"percentage":41,"remaining":34998,"type":"CREDIT_LIMIT","unit":6,"usage":60000},{"currentValue":0,"number":5,"percentage":0,"remaining":12000,"type":"CREDIT_LIMIT","unit":3,"usage":12000}]}"#)
        let m = QuotaService.glmMeters(j["limits"]?.arrayValue ?? [])
        #expect(m.map(\.kind) == [.fiveHour, .weekly])
        #expect(m[0].usedFraction == 0 && m[0].resetsAt == nil)
        #expect(abs((m[1].usedFraction ?? 0) - 25001.0 / 60000) < 1e-9)
        #expect(m[1].resetsAt == Date(timeIntervalSince1970: 1792400511.970))
    }

    @Test func olderTokenAndToolCallLimitsKeepTheirMeaning() throws {
        let j = try JSONCodec.parse(#"{"limits":[{"type":"TIME_LIMIT","percentage":10,"usage":1000,"currentValue":100,"unit":5,"number":1},{"type":"TOKENS_LIMIT","percentage":30}]}"#)
        let m = QuotaService.glmMeters(j["limits"]?.arrayValue ?? [])
        #expect(m.map(\.kind) == [.fiveHour, .prompts])
        #expect(m[0].detail == "tokens" && m[1].detail == "tool calls")
    }
}

@Suite struct OpenAITokenLimitParameter {
    @Test func newerOpenAIModelsGetMaxCompletionTokens() {
        for m in ["gpt-6-astra", "gpt-5", "openai/gpt-5.2-mini", "o3", "o4-mini"] { #expect(OpenAIChatProvider.usesMaxCompletionTokens(m), "\(m)") }
        for m in ["gpt-4o", "gpt-4.1-mini", "deepseek-flash", "glm-5.3", "claude-opus-5-5", "openai/gpt-oss-120b", "omni-moderation"] {
            #expect(!OpenAIChatProvider.usesMaxCompletionTokens(m), "\(m)")
        }
    }
}

@Suite struct CodexModelsAndErrors {
    @Test func parsesCodexCatalogSkippingHiddenModels() {
        let json = #"{"models":[{"slug":"gpt-6-luna","display_name":"GPT-6-Luna","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]},{"slug":"gpt-reserve","visibility":"hide"},{"slug":"gpt-5.6-terra","visibility":"list"}]}"#
        let m = ModelDiscovery.parseCodexModels(json)
        #expect(m.map(\.id) == ["gpt-6-luna", "gpt-5.6-terra"])
        #expect(m.first?.effortLevels == ["low", "high"])
    }

    /// A CLI that exits 1 explains itself on stdout; that message reaches the user, not its stderr noise.
    @Test func cliErrorFromStdoutBeatsStderr() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake-codex")
        try """
        #!/bin/bash
        echo "Reading additional input from stdin..." >&2
        echo '{"type":"turn.failed","error":{"message":"The model is not supported when using Codex with a ChatGPT account."}}'
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var profile = ProviderPresets.profile(id: "codex")!
        profile.executable = script.path
        let req = LLMRequest(model: "gpt-x", system: "s", tools: [], messages: [Message.user("hi")], maxTokens: 10,
                             cache: CacheHints(lineageKey: "cx-\(UUID().uuidString)", retention: .short))
        do {
            _ = try await CLIAgentProvider(profile: profile).complete(req)
            Issue.record("should fail")
        } catch {
            let text = "\(error)"
            #expect(text.contains("ChatGPT account cannot use this model"), "\(text)")
            #expect(!text.contains("Reading additional input"))
        }
    }
}
