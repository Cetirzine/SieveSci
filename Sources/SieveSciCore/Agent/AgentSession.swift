import Foundation

/// One agent conversation (main agent, or a checker/verifier/worker subagent).
///
/// Cache discipline, applied to every vendor:
/// - `system` and `tools` are frozen at construction; tools are sorted by name.
/// - The transcript is append-only. Per-turn facts ride in a `<context>` block appended to the new
///   user message (Reasonix's "workspace block" rule), never in the system prompt.
/// - Subagents of the same role reuse the same frozen prompt + tool list, so every checker run
///   in a session (and across sessions) reads the same cached prefix.
/// - Receipt ids are appended at the *end* of tool results, so result text stays stable.
public final class AgentSession: @unchecked Sendable {
    public let id: String
    public let role: AgentRole
    public let services: SessionServices
    public let system: String
    public let tools: [Tool]
    public private(set) var transcript: [Message] = []
    public private(set) var meter: ContextMeter
    public var provider: LLMProvider
    public var model: String
    let toolContext: ToolContext
    let cache: CacheHints
    private var cancelled = false
    private var lastRequestAt: Date?
    var interventionsThisTurn = 0
    /// Per-call bookkeeping, locked: read-only calls of one step run concurrently on this instance
    /// (`runTools`), and an unlocked dictionary here crashed 0.2.1 (two `respond_review` calls resized
    /// `repeatCounts` at once). Tool calls in the current user turn, and which delegation hints this
    /// turn already got.
    private let turnToolCalls = LockedValue(0)
    private let delegationHinted = LockedValue<Set<String>>([])
    /// Plan steps the host already handed to workers (see `HostDelegation`), for the whole session.
    var delegatedSteps: Set<String> = []
    /// Successful receipts of this agent's own tool calls (also those a CLI agent makes over the bridge,
    /// which never appear in its transcript).
    let ownReceipts = LockedValue<[String]>([])
    /// This turn's request was already split and run on workers at its start.
    var turnDelegated = false
    /// Identical-call counter (DeepSeek Harness repeat-tool-reminder: advisory at 3, 5, 8 repeats).
    private let repeatCounts = LockedValue<[String: Int]>([:])
    /// Epoch counter: incremented by compaction (which starts a new transcript prefix).
    public private(set) var epoch = 0
    public var maxSteps = 200
    /// Context size (tokens) treated as "full" for compaction, whatever the model's window.
    public static var contextBudget = 200_000
    /// The reply being streamed, saved as it grows (main agent only).
    var draft: TurnDraft?
    /// Who dispatched this agent and why (shown live in the UI's agent cards).
    public var parentId = "main"
    public var purpose = ""
    private var announced = false

    public init(id: String = UUID().uuidString, role: AgentRole, services: SessionServices, tools: [Tool],
                lineageKey: String? = nil, writeRoot: URL? = nil, blindedPaths: [String] = [], readableRoots: [String]? = nil,
                contextWindow: Int = 200_000) {
        self.id = id
        self.role = role
        self.services = services
        system = SystemPrompts.prompt(for: role)
        self.tools = tools.sorted { $0.name < $1.name }
        let (p, m) = services.models.pick(role)
        provider = p
        model = m
        // Same-role subagents share the main lineage so OpenAI/affinity relays route them to the same shard.
        cache = CacheHints(lineageKey: lineageKey ?? services.taskId, retention: services.retention)
        toolContext = ToolContext(workspace: services.workspace, sessionId: id, role: role, blindedPaths: blindedPaths,
                                  writeRoot: writeRoot, readableRoots: readableRoots, ledger: services.ledger, audit: services.audit, services: services)
        meter = ContextMeter(model: m, contextWindow: contextWindow)
    }

    public func cancel() {
        cancelled = true
        ToolBridge.shared.cancelCalls(for: self)
        // Stop ends the workers, checkers and verifiers this agent started, too.
        if role == .main { services.subagents.cancelAll() }
    }

    var isCancelled: Bool { cancelled }

    /// Switches this agent to another model (used when a reviewer declines or fails and the host
    /// retries with a different, preferably different-vendor, reviewer).
    public func useModel(_ p: LLMProvider, _ m: String) {
        provider = p
        model = m
        meter = ContextMeter(model: m, contextWindow: ModelDiscovery.effectiveSettings(model: m, profile: p.profile, discovered: nil).contextWindow)
    }

    var actor: String { role.rawValue }

    /// A subagent's own CLI conversation: concurrent workers on one CLI model would otherwise share (and
    /// kill) one agy process, and a new checker or verifier would resume an earlier one's conversation.
    var cliConversation: String? { role == .main ? nil : cache.lineageKey + "/" + id }

    // MARK: Turn entry

    /// Sends a user turn and runs the loop until the model ends its turn (or the supervisor's
    /// intervention budget is spent). Returns the final assistant message.
    @discardableResult
    public func send(_ text: String, attachments: [ContentBlock] = []) async throws -> Message? {
        if role != .main && !announced {
            announced = true
            let shown = purpose.isEmpty ? String(text.prefix(200)) : purpose
            services.emit(.agentStarted(id: id, role: role, parent: parentId, purpose: shown))
            // The card's title and parent, for a reopened task (ServeServer.timeline).
            services.log("agent_start", actor: role.rawValue, ["agent": .string(id), "parent": .string(parentId), "purpose": .string(shown)])
        }
        defer {
            if role != .main {
                services.emit(.agentFinished(id: id, role: role, result: transcript.last?.plainText ?? ""))
                if let c = cliConversation, provider is CLIAgentProvider { CLIAgentProvider.endProcess(conversation: c, profile: provider.profile) }
            }
        }
        cancelled = false
        interventionsThisTurn = 0
        turnToolCalls.mutate { $0 = 0 }
        delegationHinted.mutate { $0 = [] }
        turnDelegated = false
        repeatCounts.mutate { $0 = [:] }
        var userText = text
        // Hooks may add context or block the prompt (Claude-Code UserPromptSubmit semantics).
        if role == .main {
            let hook = await services.hooks.run(.userPromptSubmit, payload: ["prompt": .string(text)])
            if hook.blocked { services.emit(.notice(L10n.s("Prompt blocked by hook: %@", hook.message))); return nil }
            if !hook.message.isEmpty { userText += "\n\n<hook_context>\n\(hook.message)\n</hook_context>" }
            // A brainstorm (live or just asked for) is not split across workers or turned into plan steps.
            if services.ideas.isBrainstorming {
                // nothing: the brainstorm runs in this agent's own context, stage by stage
            } else if let delegated = await delegateTurn(text) {
                hint("plan")
                userText += "\n\n" + delegated
            } else if services.research.groundingRequired, services.research.snapshot.steps.isEmpty,
                      HostDelegation.looksMultiPart(text) {
                userText += "\n\n" + HostDelegation.planFirstNote
            }
        }
        var blocks: [ContentBlock] = attachments
        if role != .main && transcript.isEmpty {
            let intro = services.roleIntro(role)
            if !intro.isEmpty { blocks.append(.text(intro)) }
        }
        blocks.append(.text(userText))
        if role == .main {
            let turn = transcript.filter { $0.role == .user && $0.blocks.contains { $0.text?.hasPrefix("<context>") == true } }.count + 1
            blocks.append(.text(TurnContext.render(services: services, model: model, turn: turn)))
        }
        blocks = await services.vision.adapt(blocks, modelSupportsImages: services.supportsImages(role))
        append(Message(role: .user, blocks: blocks))
        services.log("user_turn", actor: role == .main ? "user" : "host", ["text": .string(text.truncated(4000)), "agent": .string(id)])
        return try await loop()
    }

    func append(_ m: Message) {
        transcript.append(m)
        if role == .main { SessionStore.shared.append(m, task: services.taskId, agent: id, dir: services.taskDir) }
    }

    // MARK: Loop

    func loop() async throws -> Message? {
        services.emit(.turnStarted(role: role, agentId: id))
        var steps = 0
        var last: Message?
        while !cancelled && !Task.isCancelled && steps < maxSteps {
            steps += 1
            try await compactIfNeeded()
            let resp = try await callModel()
            append(resp.message)
            last = resp.message
            services.emit(.assistantMessage(agentId: id, resp.message))

            let uses = resp.message.toolUses
            if !uses.isEmpty {
                var results = await services.vision.adapt(await runTools(uses), modelSupportsImages: services.supportsImages(role))
                // Job events that arrived meanwhile ride along at the end (append-only: cache-safe).
                let notes = services.jobs.drain(for: id)
                if !notes.isEmpty { results.append(.text(notes.map(\.rendered).joined(separator: "\n"))) }
                if role == .main, let wrap = services.ideas.drainWrapUp() { results.append(.text(wrap)) }
                if role != .main && steps >= maxSteps - 2 {
                    results.append(.text("<step_budget>This is your last step: do not call more tools. Give your final answer now, from what you have.</step_budget>"))
                }
                append(Message(role: .user, blocks: results))
                continue
            }
            if resp.stopReason == .maxTokens {
                append(Message.user("Your reply was cut off by the output limit. Continue exactly where you stopped."))
                continue
            }
            // End of turn: deterministic integrity checks, possibly a supervisor review.
            if role == .main, let review = await services.supervisor(for: self).endOfTurn(final: resp.message),
               interventionsThisTurn < services.supervisorPolicy.maxInterventionsPerTurn {
                interventionsThisTurn += 1
                append(Message(role: .user, blocks: [.text(review)]))
                continue
            }
            if role == .main {
                let stop = await services.hooks.run(.stop, payload: ["last": .string(resp.message.plainText.truncated(4000))])
                if stop.blocked && interventionsThisTurn < services.supervisorPolicy.maxInterventionsPerTurn {
                    interventionsThisTurn += 1
                    append(Message.user("<hook_feedback>\n\(stop.message)\n</hook_feedback>"))
                    continue
                }
            }
            services.emit(.turnFinished(agentId: id, stop: resp.stopReason))
            return last
        }
        services.emit(.turnFinished(agentId: id, stop: cancelled ? .pause : .endTurn))
        return last
    }

    /// Reviewers stay read-only whatever the session mode; others follow it.
    var cliHost: CLIHost {
        let mode = services.permissions.mode
        let readOnly = mode == .plan || role == .checker || role == .verifier
        return CLIHost(workspace: services.workspace, readOnly: readOnly, allowCommands: !readOnly && (mode == .auto || mode == .yolo))
    }

    static func hasImages(_ m: Message) -> Bool {
        m.blocks.contains { b in
            if case .image = b { return true }
            if case .toolResult(let r) = b { return !r.images.isEmpty }
            return false
        }
    }

    func callModel() async throws -> LLMResponse {
        var req = LLMRequest(model: model, system: system, tools: tools.map(\.spec), messages: transcript,
                             maxTokens: min(meter.contextWindow / 4, 64_000), effort: services.effort, cache: cache)
        req.host = cliHost
        if provider is CLIAgentProvider {
            req.host.mcp = await ToolBridge.shared.endpoint(for: self)
            req.host.conversation = cliConversation
        }
        let started = Date()
        let id = self.id
        let emit = services.emit
        // What has streamed so far is kept on disk: a turn cut off by Stop, an error or quitting
        // (a CLI agent's whole turn is one call) is saved as an interrupted reply instead of lost.
        let draft = role == .main ? TurnDraft(url: services.taskDir.appendingPathComponent("transcript-\(id == "main" ? "main" : id).partial.json")) : nil
        self.draft = draft
        defer { self.draft = nil }
        let resp: LLMResponse
        let meterAtStart = meter
        let userWindow = windowSetByUser
        let thinking = ThinkingClock()
        do {
            resp = try await provider.complete(req) { ev in
                draft?.add(ev)
                switch ev {
                case .textDelta(let t): thinking.stop(); emit(.textDelta(agentId: id, t))
                case .thinkingDelta(let t): thinking.think(); emit(.thinkingDelta(agentId: id, t))
                case .toolInputDelta: thinking.stop()
                case .contextUsage(let tokens, let window):
                    var m = meterAtStart
                    m.lastPromptTokens = tokens
                    if let window, window > 0, !userWindow { m.contextWindow = window }
                    emit(.usage(agentId: id, m))
                default: break
                }
            }
        } catch where ModelCapabilities.isImageRefusal(error) && transcript.contains(where: Self.hasImages) {
            // The model refused image input: remember it, describe the images in text, ask again.
            draft?.clear()
            ModelCapabilities.shared.learn(images: false, model: model, profile: provider.profile.id)
            var adapted: [Message] = []
            for m in transcript { adapted.append(Message(id: m.id, role: m.role, blocks: await services.vision.adapt(m.blocks, modelSupportsImages: false))) }
            transcript = adapted
            services.emit(.notice(L("This model does not take images; they are described in text instead.")))
            return try await callModel()
        } catch {
            if let draft, let m = draft.message() { append(m) }
            draft?.clear()
            throw error
        }
        draft?.clear()
        if req.messages.contains(where: Self.hasImages), ModelCapabilities.shared.learnedImages(model, profile: provider.profile.id) == nil {
            ModelCapabilities.shared.learn(images: true, model: model, profile: provider.profile.id)
        }
        lastRequestAt = Date()
        meter.lastPromptTokens = resp.contextTokens ?? resp.usage.promptTotal
        if let w = resp.contextWindow, w > 0, !windowSetByUser { meter.contextWindow = w }
        meter.lastOutputTokens = resp.usage.output
        meter.session = meter.session + resp.usage
        SpendTracker.shared.record(resp.usage, model: resp.servedModel ?? model, profile: provider.profile)
        meter.model = resp.servedModel ?? model
        services.emit(.usage(agentId: id, meter))
        services.log("model_call", actor: actor, [
            "agent": .string(id), "provider": .string(provider.profile.id), "model": .string(model),
            "served_model": .string(resp.servedModel ?? ""), "request_id": .string(resp.providerRequestId ?? ""),
            "prefix_fingerprint": .string((system + tools.map(\.spec).map { $0.name + $0.inputSchema.canonical }.joined()).stableHash),
            "input": .int(resp.usage.input), "cache_read": .int(resp.usage.cacheRead), "cache_write": .int(resp.usage.cacheWrite),
            "output": .int(resp.usage.output), "stop": .string(resp.stopReason.rawValue),
            "seconds": .double(Date().timeIntervalSince(started)),
            // Which saved reply this call made, and how long it thought: a reopened task shows
            // "Thought for N s" as the live view did (DisplayTimeline).
            "message": .string(resp.message.id),
            "thinking_seconds": thinking.seconds.map { .double($0) } ?? .null,
        ])
        if resp.stopReason == .refusal { services.emit(.notice(L("The model declined this request."))) }
        return resp
    }

    // MARK: Tools

    /// Prompt to hand work to workers at the moments it pays (models rarely delegate on their own, CLI
    /// agents least of all): once a multi-step plan is set, and when a turn has run many tool calls.
    func delegationHint(after use: ToolUse, output: ToolOutput) -> String? {
        guard role == .main, tools.contains(where: { $0.name == "task" }), services.ideas.live == nil else { return nil }
        let calls = turnToolCalls.increment()
        let workerModel = services.models.pick(.worker).1
        let pending = services.research.snapshot.steps.filter { $0.status == "pending" }
        if use.name == "update_plan", !output.isError, pending.count >= 3, hint("plan") {
            return "<delegation_hint>The plan has \(pending.count) pending steps. Mark the steps that need no other step's results "
                + "`parallel: true` (and give the others `depends_on`) in `update_plan`: SieveSci then runs them on workers at once "
                + "(model: \(workerModel), own context, report with receipts). Or hand one to a worker with `task` (e.g. "
                + pending.prefix(3).map { "\($0.id) \($0.title.prefix(40))" }.joined(separator: "; ")
                + "). Keep planning, synthesis and claims yourself.</delegation_hint>"
        }
        for n in [30, 80, 150] where calls == n && hint("calls\(n)") {
            return "<delegation_hint>This turn has run \(n) tool calls in your own context. Hand independent work to workers: `task` for one subtask "
                + "(a literature sweep, implementing and testing one module, processing one dataset, a long analysis), `dispatch` for the same "
                + "instructions over many items. Workers (model: \(workerModel)) run in parallel and keep your context small.</delegation_hint>"
        }
        return nil
    }

    /// What a tool result costs in context: it is re-sent with every later call of the conversation.
    /// Long outputs go in as head + tail (errors and summaries sit at the end) with the path of the full
    /// text, which the receipt keeps; grounding and the checker still see all of it.
    static let modelOutputLimit = 16_000

    static func clipForModel(_ text: String, receipt: String, services: SessionServices) -> String {
        guard text.count > modelOutputLimit else { return text }
        let head = text.prefix(9_000), tail = text.suffix(5_000)
        let omitted = text.count - head.count - tail.count
        let path = services.taskDir.appendingPathComponent("state/outputs/\(receipt).txt").path
            .replacingOccurrences(of: services.workspace.path + "/", with: "")
        return head + "\n\n[… \(omitted) characters omitted to save context; the full output is in \(path) — read_file it with an offset if you need more]\n\n" + tail
    }

    func tool(named n: String) -> Tool? { tools.first { $0.name == n } }

    /// Marks a delegation hint as given; true the first time in this turn.
    @discardableResult
    func hint(_ key: String) -> Bool {
        var inserted = false
        delegationHinted.mutate { inserted = $0.insert(key).inserted }
        return inserted
    }

    /// Pure reads run concurrently; anything with side effects, or that changes session state (see
    /// `Tool.runsConcurrently`), runs in order. All results go
    /// back in one user message (splitting them teaches models to stop calling tools in parallel).
    func runTools(_ uses: [ToolUse]) async -> [ContentBlock] {
        // `ask_user` is a decision barrier: what was written alongside it was written without the
        // answer, so only the question runs (after Reasonix's ask tool).
        if uses.count > 1, let ask = uses.first(where: { $0.name == "ask_user" }) {
            var out: [ContentBlock] = []
            for u in uses where u.id != ask.id {
                out.append(.toolResult(ToolResult(toolUseId: u.id, content: "Not run: you asked the user a question in the same step. "
                    + "Wait for the answer, then call this again if it is still needed.", isError: true)))
            }
            let answer = await execute(ask)
            let order = uses.map(\.id)
            return (out + [answer]).sorted { a, b in
                (order.firstIndex(of: a.toolResult?.toolUseId ?? "") ?? 0) < (order.firstIndex(of: b.toolResult?.toolUseId ?? "") ?? 0)
            }
        }
        let concurrent = uses.allSatisfy { u in tool(named: u.name)?.runsConcurrently(for: u.input) == true }
        if concurrent && uses.count > 1 {
            return await withTaskGroup(of: (Int, ContentBlock).self) { g in
                for (i, u) in uses.enumerated() { g.addTask { (i, await self.execute(u)) } }
                var out: [(Int, ContentBlock)] = []
                for await r in g { out.append(r) }
                return out.sorted { $0.0 < $1.0 }.map(\.1)
            }
        }
        var out: [ContentBlock] = []
        for u in uses { out.append(await execute(u)) }
        return out
    }

    func execute(_ use: ToolUse) async -> ContentBlock {
        guard let t = tool(named: use.name) else {
            return .toolResult(ToolResult(toolUseId: use.id, content: "Unknown tool \(use.name).", isError: true))
        }
        services.emit(.toolStarted(agentId: id, id: use.id, name: use.name, input: use.input))
        let effect = t.effect(for: use.input)
        let started = Date()
        var output: ToolOutput

        if let denial = await authorize(t, use, effect) {
            output = .error(denial)
        } else {
            let pre = await services.hooks.run(.preToolUse, payload: ["tool_name": .string(use.name), "tool_input": use.input], matcher: use.name)
            if pre.blocked {
                output = .error("Blocked by a PreToolUse hook: \(pre.message)")
            } else {
                if role == .main && effect == .writesFiles { services.checkpoints.snapshot(input: use.input, tool: use.name, ctx: toolContext) }
                let editedPath = (effect == .writesFiles) ? use.input.str("path").flatMap { try? toolContext.resolve($0).path } : nil
                let before = editedPath.flatMap { services.changes.before($0) }
                if let p = editedPath { services.changes.record(path: p, before: before) }
                do { output = try await CurrentToolCall.$id.withValue(use.id) { try await t.run(use.input, toolContext) } } catch { output = .error(error.localizedDescription) }
                if let p = editedPath, !output.isError {
                    let rel = p.hasPrefix(services.workspace.path + "/") ? String(p.dropFirst(services.workspace.path.count + 1)) : p
                    let diff = FileDiff.make(path: rel, old: before, new: try? String(contentsOfFile: p, encoding: .utf8))
                    services.emit(.fileChanged(agentId: id, path: rel, diff: diff))
                    output.text += "\n(+\(diff.added) −\(diff.removed) lines)"
                }
                let post = await services.hooks.run(.postToolUse, payload: ["tool_name": .string(use.name), "tool_input": use.input,
                                                                            "tool_output": .string(output.text.truncated(8000))], matcher: use.name)
                if !post.message.isEmpty { output.text += "\n\n<hook_feedback>\(post.message)</hook_feedback>" }
            }
        }

        let receipt = services.ledger.record(tool: use.name, args: use.input, output: output, role: role,
                                             startedAt: started, duration: Date().timeIntervalSince(started))
        if receipt.success { ownReceipts.mutate { $0.append(receipt.id) } }
        services.log("tool_call", actor: actor, [
            "agent": .string(id), "receipt": .string(receipt.id), "tool": .string(use.name), "input": use.input,
            "success": .bool(receipt.success), "exit_code": receipt.exitCode.map { .int(Int($0)) } ?? .null,
            "output_sha256": .string(receipt.outputDigest), "output_excerpt": .string(receipt.outputExcerpt.truncated(2000)),
            "files_written": .object(receipt.filesWritten.mapValues { .string($0) }), "facts": .object(output.facts),
            "seconds": .double(receipt.duration),
        ])
        services.emit(.toolFinished(agentId: id, id: use.id, name: use.name, output: output.text, isError: !receipt.success, receipt: receipt.id))

        // Integrity: scan executed or written code as it happens.
        if role == .main || role == .worker {
            await services.supervisor(for: self).afterTool(use: use, output: output, receipt: receipt)
        }
        var text = (output.text.isEmpty ? "(no output)" : Self.clipForModel(output.text, receipt: receipt.id, services: services)) + "\n[receipt \(receipt.id)]"
        if role == .main, use.name == "update_plan", receipt.success, let delegated = await delegatePlanSteps(callId: use.id) {
            hint("plan")
            text += "\n" + delegated
        }
        if let hint = delegationHint(after: use, output: output) { text += "\n" + hint }
        let callKey = use.name + use.input.canonical
        var repeats = 0
        repeatCounts.mutate { $0[callKey, default: 0] += 1; repeats = $0[callKey] ?? 0 }
        if [3, 5, 8].contains(repeats) {
            text += "\n<repeat_notice>You have made this exact call \(repeats) times. Read the previous result, then change approach or finish — repeating it will not give a different answer.</repeat_notice>"
            services.log("repeat_guard", actor: "host", ["agent": .string(id), "tool": .string(use.name), "count": .int(repeats)])
        }
        return .toolResult(ToolResult(toolUseId: use.id, content: text, isError: !receipt.success, images: output.images))
    }

    /// Returns a denial message, or nil if the call may proceed.
    func authorize(_ t: Tool, _ use: ToolUse, _ effect: ToolEffect) async -> String? {
        // A live brainstorm is a closed phase: no plan, no workers, no analysis until it ends.
        if role == .main, let why = services.ideas.brainstormBlocker(tool: t.name, input: use.input) {
            services.log("brainstorm_gate", actor: "host", ["tool": .string(t.name), "agent": .string(id)])
            return why
        }
        if role == .main, case .refuse(let why) = services.research.requirePlan(tool: t.name, input: use.input) {
            services.log("preregistration_gate", actor: "host", ["tool": .string(t.name), "agent": .string(id)])
            return why
        }
        if role != .main {
            // Subagents follow the same policy as the main agent. What they may do without asking is
            // only what the delegating call (dispatch / task / claim_finding) already approved: file
            // writes inside their own directory, and code that runs under the sandbox. Code that would
            // run unsandboxed and calls to external services are asked about separately.
            if effect == .readOnly { return nil }
            if role == .checker { return "The checker is read-only." }
            if services.permissions.mode == .plan { return "plan mode is read-only; subagents cannot run or edit either" }
            if effect == .writesFiles { return nil }   // tools confine writes to the agent's own directory
            if effect == .executes && toolContext.sandboxMode != .off && Seatbelt.available {
                if case .deny(let why) = services.permissions.evaluate(tool: t.name, input: use.input, effect: effect) {
                    services.log("permission", actor: "host", ["tool": .string(t.name), "agent": .string(id), "decision": "deny", "reason": .string(why)])
                    return why
                }
                return nil
            }
        }
        switch services.permissions.evaluate(tool: t.name, input: use.input, effect: effect) {
        case .allow:
            return nil
        case .deny(let why):
            services.log("permission", actor: "host", ["tool": .string(t.name), "decision": "deny", "reason": .string(why)])
            return why
        case .ask:
            // A subagent's request says which agent is asking.
            let who = role == .main ? "" : "[\(role.rawValue)\(purpose.isEmpty ? "" : " · " + purpose.truncated(60))] "
            let req = PermissionRequest(id: use.id, tool: t.name, summary: (who + PermissionPolicy.summary(t.name, use.input)).truncated(500),
                                        input: use.input, effect: effect,
                                        rememberPattern: PermissionPolicy.rememberPattern(tool: t.name, input: use.input))
            if cancelled { return "Stopped by the user." }
            let d = await services.askUser(req, cancelled: { [weak self] in self?.cancelled ?? true })
            services.log("permission", actor: "user", ["tool": .string(t.name), "agent": .string(id), "decision": .string("\(d)")])
            switch d {
            case .allowOnce: return nil
            case .allowAlways: services.permissions.remember(req.rememberPattern); return nil
            case .deny(let reason): return "The user declined this \(t.name) call." + (reason.isEmpty ? "" : " They said: \(reason)")
            }
        }
    }

    // MARK: Compaction

    /// The user set this model's specs by hand (Settings → Providers): a window the provider reports
    /// does not override theirs.
    var windowSetByUser: Bool { provider.profile.modelSettings.contains { $0.id == model } }

    /// Compacts when the window is getting full. When the vendor's prefix cache has already expired
    /// (idle longer than its TTL), compaction costs no cache, so it happens at a lower threshold.
    func compactIfNeeded() async throws {
        guard meter.contextWindow > 0, transcript.count > 6 else { return }
        // Fill is measured against the window, capped at `contextBudget`: on a 1M-token model the context
        // would otherwise grow to ~800k tokens, all of it re-sent with every call.
        let budget = Double(min(meter.contextWindow, Self.contextBudget))
        let fill = Double(meter.lastPromptTokens) / budget
        let idle = lastRequestAt.map { Date().timeIntervalSince($0) } ?? 0
        let cold = idle > CachePolicy.ttl(for: provider.profile)
        guard fill > 0.6 || (cold && fill > 0.4) else { return }
        // First the free step (OpenCode's prune): old tool outputs give way to their receipt ids. Only when
        // that is not enough does a model call summarize the session.
        let freed = prune()
        if freed > 0 { meter.lastPromptTokens = max(0, meter.lastPromptTokens - freed) }
        let after = Double(meter.lastPromptTokens) / budget
        guard after > 0.8 || (cold && after > 0.5) else { return }
        try await compact(focus: nil, reason: cold ? "cache already cold" : "context \(Int(fill * 100))% full",
                          shown: cold ? L("the prompt cache had already expired") : L10n.s("context %@ full", "\(Int(fill * 100))%"))
    }

    /// Tool output kept verbatim at the end of the context (OpenCode's PRUNE_PROTECT / PRUNE_MINIMUM).
    static let pruneProtect = 40_000, pruneMinimum = 20_000
    /// Tools whose output is working state the agent keeps relying on.
    static let unprunable: Set<String> = ["skill", "memory", "update_plan", "todo_write", "goal"]

    /// Replaces tool outputs older than the newest `pruneProtect` tokens with a pointer to their receipt,
    /// when that frees at least `pruneMinimum` tokens. No model call; the full output stays in the ledger
    /// (`receipt` tool). Returns the tokens freed (estimated).
    @discardableResult
    func prune() -> Int {
        var names: [String: String] = [:]
        for m in transcript { for u in m.toolUses { names[u.id] = u.name } }
        func cost(_ s: String) -> Int { max(1, s.utf8.count / 3) }   // bytes per token: ~4 for English, ~3 for CJK
        var seen = 0, candidates: [(msg: Int, block: Int, tokens: Int)] = []
        for i in transcript.indices.reversed() {
            for (j, b) in transcript[i].blocks.enumerated().reversed() {
                guard case .toolResult(let r) = b, !r.content.hasPrefix(Self.prunedMarker) else { continue }
                let t = cost(r.content)
                seen += t
                if seen > Self.pruneProtect, !Self.unprunable.contains(names[r.toolUseId] ?? ""), t > 60 { candidates.append((i, j, t)) }
            }
        }
        let total = candidates.reduce(0) { $0 + $1.tokens }
        guard total >= Self.pruneMinimum else { return 0 }
        for c in candidates {
            guard case .toolResult(var r) = transcript[c.msg].blocks[c.block] else { continue }
            let receipt = Grounding.matches(#"\[receipt (r\d+)\]"#, in: r.content, group: 1).last
            let gist = r.content.split(separator: "\n").first.map { String($0).truncated(160, marker: "…") } ?? ""
            r.content = Self.prunedMarker + " \(gist)" + (receipt.map { " — full output: receipt \($0)]" } ?? "]")
            r.images = []
            transcript[c.msg].blocks[c.block] = .toolResult(r)
        }
        services.log("prune", actor: "host", ["agent": .string(id), "outputs": .int(candidates.count), "tokens": .int(total)])
        return total
    }

    static let prunedMarker = "[old output pruned:"

    /// Compaction (after Codex's `compact.rs` and opencode's `session/compaction.ts`): the model writes a
    /// structured checkpoint with a fork of the same prefix (so the call reads the cache); a reply that is
    /// empty or skips the template gets one nudge without tools; failing that, a checkpoint is built from
    /// the transcript itself — the context is never replaced by an empty summary. The new context keeps
    /// the user's own messages and answers verbatim, the live research state from the tools, and the most
    /// recent exchanges as they were, behind a note that this is the same task continuing.
    public func compact(focus: String?, reason: String, shown: String? = nil) async throws {
        let instruction = Self.checkpointPrompt + (focus.map { "\n\nFocus especially on: \($0)." } ?? "")
        var req = LLMRequest(model: model, system: system, tools: tools.map(\.spec),
                             messages: transcript + [Message.user(instruction)], maxTokens: 16000, effort: .low, cache: cache)
        req.host = CLIHost(workspace: services.workspace, readOnly: true)
        var summary = (try? await provider.complete(req))?.message.plainText ?? ""
        if !Self.filled(summary) {
            var retry = req
            retry.tools = []
            retry.messages = transcript + [Message.user(instruction), Message.user(Self.checkpointNudge)]
            summary = (try? await provider.complete(retry))?.message.plainText ?? ""
        }
        let fromModel = Self.filled(summary)
        if !fromModel { summary = fallbackCheckpoint() }
        // The most recent exchanges stay verbatim, from an assistant message on (so every tool result
        // still follows its call and roles keep alternating).
        let keep = Self.keepTokens
        var cut = transcript.count, size = 0
        for i in transcript.indices.reversed() {
            size += Self.tokens(transcript[i])
            if size > keep { break }
            if transcript[i].role == .assistant { cut = i }
        }
        let tail = Array(transcript[cut...])
        let users = Self.userMessages(Array(transcript[..<cut]))
        epoch += 1
        services.log("compaction", actor: "host", ["agent": .string(id), "reason": .string(reason), "epoch": .int(epoch),
                                                   "messages_before": .int(transcript.count), "kept": .int(tail.count),
                                                   "checkpoint": .string(fromModel ? "model" : "fallback"), "summary": .string(summary)])
        let state = role == .main ? TurnContext.render(services: services, model: model) + Self.ideasState(services) : ""
        let text = """
        <session_summary epoch="\(epoch)">
        \(Self.continuationNote)
        <user_messages>
        \(users.joined(separator: "\n§\n"))
        </user_messages>
        <checkpoint>
        \(summary)
        </checkpoint>
        \(state)
        </session_summary>
        """
        transcript = [Message.user(text)] + tail
        services.emit(.notice(L10n.s("Context compacted (%@).", shown ?? L(reason))))
    }

    /// Recent conversation kept verbatim beside the checkpoint (opencode's `keep.tokens`), and the user's
    /// own messages carried forward (Codex's COMPACT_USER_MESSAGE_MAX_TOKENS).
    static let keepTokens = 15_000, userMessageTokens = 20_000

    static let continuationNote = "The conversation so far was compacted to fit the context window. This is the same task, continuing: below are the user's own messages (verbatim), your checkpoint of the work, and the current state of the research tools; the most recent exchanges follow unchanged. Build on them — do not restart, do not ask the user what the task is, and do not redo steps the checkpoint or the receipts show as done."

    static let checkpointPrompt = """
    Write a checkpoint of this research session that you will continue from after the older conversation is \
    removed. Do not continue the task or call tools. Return only these Markdown sections:

    ## Objective
    - the user's request, in their own words where possible
    ## Requirements
    - constraints, preferences and decisions the user gave (including answers to questions), or "(none)"
    ## Work State
    ### Completed
    - finished steps, each with its receipt ids, file paths and key numbers exactly as measured
    ### Active
    - what was in progress when the context filled up
    ### Blocked
    - open problems, unresolved reviewer issues, or "(none)"
    ## Next Move
    1. the next concrete actions, in order
    ## Important Context
    - library citation keys, idea / hypothesis / claim ids and their status, findings the next step needs

    Terse single-line bullets. Preserve exact ids, paths, numbers and citation keys. Add nothing that is not in the conversation.
    """

    static let checkpointNudge = "The previous response did not fill in the checkpoint. Do not call tools. Return the checkpoint as text, using the exact section headings."

    static func filled(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 80 && (t.contains("## Objective") || t.contains("## Work State") || t.count >= 400)
    }

    static func tokens(_ m: Message) -> Int {
        m.blocks.reduce(0) { n, b in
            switch b {
            case .text(let t): return n + t.utf8.count / 3
            case .toolResult(let r): return n + r.content.utf8.count / 3
            case .toolUse(let u): return n + u.input.canonical.utf8.count / 3
            case .thinking(let t): return n + t.text.utf8.count / 3
            default: return n + 500
            }
        }
    }

    /// What the user typed and answered (ask_user), oldest first, newest kept within the budget; messages
    /// carried by an earlier checkpoint come along.
    static func userMessages(_ msgs: [Message]) -> [String] {
        var askIds = Set<String>()
        for m in msgs { for u in m.toolUses where u.name == "ask_user" { askIds.insert(u.id) } }
        var out: [String] = []
        for m in msgs where m.role == .user {
            for b in m.blocks {
                switch b {
                case .text(let t) where t.hasPrefix("<session_summary"):
                    if let a = t.range(of: "<user_messages>\n"), let z = t.range(of: "\n</user_messages>"), a.upperBound <= z.lowerBound {
                        out += t[a.upperBound..<z.lowerBound].components(separatedBy: "\n§\n").filter { !$0.isEmpty }
                    }
                case .text(let t) where !HostContext.isHostBlock(t):
                    let own = HostContext.userText(t).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !own.isEmpty, !own.hasPrefix("[tool result") { out.append(own) }
                case .toolResult(let r) where askIds.contains(r.toolUseId):
                    out.append("(answer to a question) " + r.content.truncated(2000))
                default: break
                }
            }
        }
        var kept: [String] = [], budget = userMessageTokens * 3
        for u in out.reversed() {
            guard budget > 0 else { break }
            let piece = u.utf8.count > budget ? String(u.prefix(budget / 3)) + " …" : u
            kept.append(piece)
            budget -= piece.utf8.count
        }
        return kept.reversed()
    }

    /// Ideas from brainstorming, so their ids and status survive compaction.
    static func ideasState(_ s: SessionServices) -> String {
        let ideas = s.ideas.snapshot
        guard !ideas.isEmpty else { return "" }
        let lines = ideas.suffix(40).map { "\($0.id) [\($0.status.rawValue)\($0.novelty.map { ", " + $0.rawValue } ?? "")] \($0.statement.truncated(140))" }
        return "\n<ideas>\n" + lines.joined(separator: "\n") + "\n</ideas>"
    }

    /// A checkpoint without a model: the tool calls made, with their receipts, when the model returned none.
    func fallbackCheckpoint() -> String {
        var names: [String: String] = [:]
        var lines: [String] = []
        for m in transcript {
            for u in m.toolUses { names[u.id] = u.name }
            for b in m.blocks {
                if case .toolResult(let r) = b {
                    let receipt = Grounding.matches(#"\[receipt (r\d+)\]"#, in: r.content, group: 1).last.map { " (\($0))" } ?? ""
                    let gist = r.content.split(separator: "\n").first.map { String($0).truncated(140, marker: "…") } ?? ""
                    lines.append("- \(names[r.toolUseId] ?? "tool")\(receipt): \(gist)")
                }
            }
        }
        return "## Work State\n### Completed\n" + lines.suffix(120).joined(separator: "\n")
            + "\n## Next Move\n1. Continue the user's request from the last step above; check the receipts before repeating anything."
    }

    /// Restores a transcript (session resume). The bytes are reused as stored, so a resumed session
    /// hits the same prefix cache it left.
    /// Loads a saved conversation; unanswered tool calls are closed so it can be sent (`TranscriptRepair`).
    public func restore(_ messages: [Message]) { transcript = TranscriptRepair.repair(messages).messages }

    /// Rewind: drops messages after `index` (user-initiated; this necessarily changes the prefix).
    public func truncate(to index: Int) { if index < transcript.count { transcript = Array(transcript.prefix(index)) } }
}

/// Vendor prefix-cache retention, from Reasonix's cache policy (Anthropic and DashScope 5 min;
/// DeepSeek's on-disk cache and unknown vendors are treated as long-lived).
public enum CachePolicy {
    public static func ttl(for p: ProviderProfile) -> TimeInterval {
        let host = URL(string: p.baseURL)?.host?.lowercased() ?? ""
        if host.hasSuffix("anthropic.com") || host.hasSuffix("dashscope.aliyuncs.com") { return 300 }
        if host.hasSuffix("openai.com") { return 600 }
        if host.hasSuffix("googleapis.com") { return 600 }
        return 24 * 3600
    }
}

/// The per-turn context block. Lives at the tail of the user message, so it never disturbs the
/// cached prefix. Day-granularity date only.
public enum TurnContext {
    public static func render(services s: SessionServices, model: String, turn: Int = 0) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let plan = s.research.snapshot
        let g = s.research.hasGrounding()
        var lines = ["<context>",
                     "date: \(f.string(from: Date()))",
                     "workspace: \(s.workspace.path)"]
        let extra = s.readOnlyFolders
        if !extra.isEmpty { lines.append("read-only folders (read with SieveSci's tools; never write there): " + extra.map(\.path).joined(separator: ", ")) }
        lines += [
                     "task: \(s.taskId)  library: \(s.library.records.count) papers  stage: \(plan.stage.rawValue)",
                     "grounding: web_search \(g.web ? "done" : "NOT YET") · literature \(g.literature ? "done" : "NOT YET")"]
        if !plan.steps.isEmpty {
            let done = plan.steps.filter { $0.status == "done" }.count
            let current = plan.steps.first { $0.status == "in_progress" }?.title ?? plan.steps.first { $0.status == "pending" }?.title ?? "-"
            lines.append("plan: \(done)/\(plan.steps.count) steps done; current: \(current)")
        }
        let open = s.claims.snapshot.filter { $0.status != .verified && $0.status != .refuted }
        if !open.isEmpty { lines.append("open claims: " + open.map { "\($0.id) [\($0.status.rawValue)]" }.joined(separator: ", ")) }
        if let goal = s.goal.current, goal.phase == .active { lines.append("goal: \(goal.objective) (round \(goal.roundsStarted))") }
        let contested = s.deliberation.contested
        if !contested.isEmpty {
            lines.append("contested (do not present as settled): " + contested.map { "\($0.thread) \($0.issue.truncated(80))" }.joined(separator: "; "))
        }
        let running = s.jobs.all.filter(\.running)
        if !running.isEmpty {
            lines.append("running jobs (you are notified on exit/match/error/stall; do not poll): "
                         + running.map { "\($0.id) \($0.label.truncated(60))" }.joined(separator: "; "))
        }
        lines.append("permission mode: \(s.permissions.mode.rawValue)")
        if let b = s.ideas.live {
            lines.append("brainstorm running: \(b.topic.truncated(80)) (stage \(b.stage); \(s.ideas.snapshot.filter(\.isLive).count) live ideas) — "
                + "no plan, workers, analysis or file writes until `brainstorm` end")
        } else if !s.ideas.autoAllowed {
            lines.append("autonomous brainstorming: off (brainstorm only when the user asks, e.g. /brainstorm)")
        }
        if L10n.resolved != "en" { lines.append("user interface language: \(L10n.resolved) (reply in the user's language)") }
        if let n = LearningNudges.nudge(turn: turn) { lines.append(n) }
        lines.append("</context>")
        return lines.joined(separator: "\n")
    }
}

/// A reply in progress, written to `transcript-main.partial.json` as it streams (at most every 2 s,
/// and at every tool call). `SessionStore.load` turns a leftover draft into an interrupted reply.
final class TurnDraft: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var text = "", activity = ""
    private var lastWrite = Date.distantPast

    init(url: URL) { self.url = url }

    func add(_ ev: StreamEvent) {
        let due: Bool = lock.withLock {
            switch ev {
            case .textDelta(let t): text += t
            case .thinkingDelta(let t): activity += t
            default: return false
            }
            if case .thinkingDelta(let t) = ev, t.hasPrefix("⏺") { return true }
            return Date().timeIntervalSince(lastWrite) > 2
        }
        if due { write() }
    }

    func note(_ s: String) { lock.withLock { activity += s + "\n" }; write() }

    /// Model-facing. As in dsh-superagent's restart recovery: check what already happened before repeating
    /// any step that acts outside the workspace.
    static let interruptedNote = "(Interrupted: this reply was cut off before it finished. Before repeating a step, check the workspace, its history and the receipts above; do not redo downloads, submissions or messages that already happened.)"

    func message() -> Message? {
        lock.withLock {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines), a = activity.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty || !a.isEmpty else { return nil }
            var blocks: [ContentBlock] = []
            if !a.isEmpty { blocks.append(.thinking(ThinkingBlock(text: a))) }
            blocks.append(.text((t.isEmpty ? "" : t + "\n\n") + Self.interruptedNote))
            return Message(role: .assistant, blocks: blocks)
        }
    }

    private func write() {
        guard let m = message(), let data = try? JSONCodec.canonicalData(encodable: m) else { return }
        lock.withLock { lastWrite = Date() }
        try? data.writeReliably(to: url)
    }

    func clear() { try? FileManager.default.removeItem(at: url) }
}

/// How long a model call spent thinking: from its first reasoning delta to the first text or tool
/// input after it (or the end of the call).
final class ThinkingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var began: Date?
    private var ended: Date?
    func think() { lock.withLock { if began == nil { began = Date() } } }
    func stop() { lock.withLock { if began != nil, ended == nil { ended = Date() } } }
    var seconds: Double? { lock.withLock { began.map { (ended ?? Date()).timeIntervalSince($0) } } }
}
