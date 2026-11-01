import Foundation

/// Top-level controller for one research task: owns the services and the main agent, routes input
/// (`/command`, `!shell`, `#memory`, `@file`, plain prompts), and drives `/goal` rounds.
/// The SwiftUI app and the CLI are both thin shells around this.
/// Text the host adds to user turns (memory, skills index, per-turn context, attachments …). It is
/// part of what the model reads, never part of what the user typed, so transcripts hide it.
public enum HostContext {
    static let prefixes = ["<context>", "<long_term_memory", "<memory", "<available_skills>", "<hook_context>",
                           "<attachment", "<file path=", "<other_conversations", "<conversation id=", "<session_summary", "<skill name=", "<environment", "<job_notification"]

    public static func isHostBlock(_ text: String) -> Bool {
        let t = text.drop { $0 == " " || $0 == "\n" }
        return prefixes.contains { t.hasPrefix($0) }
    }

    /// The user's own words from a user-turn text block (host blocks appended to it removed).
    public static func userText(_ text: String) -> String {
        var t = text
        for tag in ["hook_context", "context"] {
            t = t.replacingOccurrences(of: "(?s)\\n*<\(tag)>.*?</\(tag)>", with: "", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public final class Workbench: @unchecked Sendable {
    public let services: SessionServices
    public private(set) var main: AgentSession
    private var introduced = false
    /// The turn in progress; Stop cancels it, which ends the model call (and kills a CLI agent's process).
    private var running: Task<Void, Error>?
    public var onOutput: @Sendable (String) -> Void = { _ in }
    private let stateLock = NSLock()
    private var busy = false
    private var queued: [(String, [Attachment])] = []
    /// Wake the main agent when a background job reports (exit, watched match, error, stall) while
    /// it is idle. On by default: agents get notified instead of sleeping and polling.
    public var autoWake = true
    /// The job count the goal driver last announced it is waiting for (so the notice is not repeated).
    private var goalJobsNoticed: Int?

    public init(services: SessionServices) {
        self.services = services
        let (p, m) = services.models.main
        let window = ModelDiscovery.effectiveSettings(model: m, profile: p.profile, discovered: nil).contextWindow
        main = AgentSession(id: "main", role: .main, services: services, tools: [], contextWindow: window)
    }

    /// Discovers MCP tools, freezes the toolset, runs SessionStart hooks, refreshes model metadata.
    public func start() async {
        // Keep capabilities, prices and endpoints current (daily, non-blocking). Leaderboard refresh
        // costs model tokens and runs only on /refresh or from Settings.
        Task.detached { _ = try? await ModelsDevCatalog.shared.refresh() }
        await services.freezeToolset()
        // Reproducibility: environment snapshot and a baseline commit of the workspace state.
        Task.detached { [services] in await EnvironmentSnapshot.capture(services: services) }
        await services.git.prepare()
        if let base = await services.git.snapshot(subject: "baseline before task \(services.taskId)", trailers: ["SieveSci-Task": services.taskId]) {
            services.log("git_commit", actor: "host", ["commit": .string(base.commit), "subject": "baseline"])
        } else if let why = services.git.skippedReason {
            services.emit(.notice(why))
            services.log("git_skipped", actor: "host", ["reason": .string(why)])
        }
        let (p, m) = services.models.main
        let window = ModelDiscovery.effectiveSettings(model: m, profile: p.profile, discovered: nil).contextWindow
        main = AgentSession(id: "main", role: .main, services: services, tools: services.toolset, contextWindow: window)
        var restored = SessionStore.load(dir: services.taskDir, agent: "main")
        // A turn that ended without a saved reply (before drafts existed, or a hard kill) is rebuilt
        // from the audit log, so its work stays visible and in context.
        if restored.last?.role == .user, let m = Self.recoveredReply(audit: services.audit.url) {
            SessionStore.shared.append(m, task: services.taskId, agent: "main", dir: services.taskDir)
            restored.append(m)
        }
        if !restored.isEmpty { main.restore(restored); introduced = true }
        services.log("session_start", actor: "host", ["provider": .string(p.profile.id), "model": .string(m), "tools": .array(services.toolset.map { .string($0.name) }),
                                                      "app_version": .string(SieveSci.version), "workspace": .string(services.workspace.path)])
        _ = await services.hooks.run(.sessionStart, payload: ["task": .string(services.taskId)])
        services.jobs.onNotify = { [weak self] _ in
            guard let self else { return }
            Task { await self.wakeIfIdle() }
        }
    }

    public var isRunning: Bool { stateLock.lock(); defer { stateLock.unlock() }; return busy }
    public var queuedPrompts: [String] { stateLock.lock(); defer { stateLock.unlock() }; return queued.map(\.0) }

    /// Starts a turn for pending job notifications if the agent is idle.
    func wakeIfIdle() async {
        let idle = stateLock.withLock { !busy && autoWake && services.jobs.hasPendingAny }
        guard idle else { return }
        await runTurn(nil)
    }

    static func wakePrompt(_ notes: [JobNotification]) -> String {
        notes.map(\.rendered).joined(separator: "\n") + """

        Background job events arrived while you were idle. If they need action (read the output with \
        job_output, diagnose and fix a failure, continue the plan with the results), take it; otherwise \
        acknowledge them in one line.
        """
    }

    /// The main agent's tool calls after the last user turn, as an interrupted reply (nil if none).
    static func recoveredReply(audit url: URL) -> Message? {
        guard let entries = try? AuditLog.read(url, kinds: ["user_turn", "tool_call"]) else { return nil }
        guard let lastTurn = entries.lastIndex(where: { $0.kind == "user_turn" && $0.actor == "user" }) else { return nil }
        let calls = entries[(lastTurn + 1)...].filter { $0.kind == "tool_call" && $0.actor == "main" }
        guard !calls.isEmpty else { return nil }
        let lines = calls.map { e -> String in
            let d = e.data
            let input = (d["input"]?.canonical ?? "").prefix(160)
            return "⏺ \(d.str("tool") ?? "tool")(\(input)) \(d["success"]?.boolValue == false ? "✗" : "→") [\(d.str("receipt") ?? "?")]"
        }
        let text = L10n.f("This reply was cut off before it was saved. The work it did is listed above (%d tool calls); every result has its receipt.", calls.count)
            + "\n\n" + TurnDraft.interruptedNote
        return Message(role: .assistant, blocks: [.thinking(ThinkingBlock(text: lines.joined(separator: "\n"))), .text(text)])
    }

    public func interrupt() {
        main.cancel()
        stateLock.withLock { running }?.cancel()
    }

    // MARK: Input routing

    public enum Routed: Equatable { case handled(String), prompt(String) }

    /// Submits user input. Slash commands and prefixes are handled locally (no model call) unless
    /// they expand into a prompt.
    public func submit(_ raw: String, attachments: [Attachment] = []) async {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty || !attachments.isEmpty else { return }
        switch await route(input) {
        case .handled(let msg):
            if !msg.isEmpty { onOutput(msg) }
        case .prompt(let p):
            services.goal.userReplied()
            await runTurn(p, attachments: attachments)
        }
    }

    func route(_ input: String) async -> Routed {
        if input.hasPrefix("!") {
            let cmd = String(input.dropFirst())
            let r = try? await ProcessRunner.run("/bin/bash", ["-lc", cmd], cwd: services.workspace, timeout: 600)
            services.log("user_shell", actor: "user", ["command": .string(cmd), "exit": .int(Int(r?.exitCode ?? -1))])
            return .handled((r?.stdout ?? "") + (r?.stderr.isEmpty == false ? "\n" + r!.stderr : "") + "\n[exit \(r?.exitCode ?? -1)]")
        }
        if input.hasPrefix("#") {
            try? ProjectMemory.remember(String(input.dropFirst()), workspace: services.workspace)
            return .handled(L("Saved to SIEVESCI.md (applies from the next session; this session continues unchanged so its cache stays warm)."))
        }
        if input.hasPrefix("/") { return await SlashCommands.run(input, bench: self) }
        return .prompt(expandMentions(input))
    }

    /// `@path` mentions inline small files (Claude Code behaviour); `@task:<id>` attaches the digest of
    /// another conversation in this workspace.
    func expandMentions(_ s: String) -> String {
        var extra: [String] = []
        for ref in Grounding.matches(#"(?<=^|\s)@task:([\w\-]+)"#, in: s, group: 1) {
            if let id = SessionStore.resolve(ref, in: services.workspace), id != services.taskId {
                extra.append("<conversation id=\"\(id)\">\n\(SessionStore.digest(task: id, in: services.workspace))\n</conversation>")
            }
        }
        for m in Grounding.matches(#"(?<=^|\s)@([\w./\-]+)"#, in: s, group: 1) where m != "task" {
            let url = services.workspace.appendingPathComponent(m)
            if let t = try? String(contentsOf: url, encoding: .utf8), t.count < 50_000 {
                extra.append("<file path=\"\(m)\">\n\(t)\n</file>")
            }
        }
        return extra.isEmpty ? s : s + "\n\n" + extra.joined(separator: "\n")
    }

    // MARK: Turns

    /// Runs a turn; if one is already running the prompt is queued and runs next (Claude Code's
    /// queued messages). After the turn, queued prompts run, then pending job notifications wake
    /// the agent. `prompt == nil` = a wake-up for notifications only.
    public func runTurn(_ prompt: String?, attachments: [Attachment] = []) async {
        let started: Bool = stateLock.withLock {
            if busy {
                if let prompt { queued.append((prompt, attachments)) }
                return false
            }
            busy = true
            return true
        }
        guard started else {
            if prompt != nil { services.emit(.notice(L("Queued; it will be sent when the current turn ends."))) }
            return
        }
        var next: (String, [Attachment])? = prompt.map { ($0, attachments) }
        while true {
            if let (p, a) = next {
                await turn(p, attachments: a)
            }
            enum Step { case queued((String, [Attachment])), wake([JobNotification]), idle }
            let step: Step = stateLock.withLock {
                if !queued.isEmpty { return .queued(queued.removeFirst()) }
                let notes = autoWake ? services.jobs.drain(for: "main", adoptOrphans: true) : []
                if notes.isEmpty { busy = false; return .idle }
                return .wake(notes)
            }
            let notes: [JobNotification]
            switch step {
            case .queued(let q): next = q; continue
            case .idle: return
            case .wake(let n): notes = n
            }
            services.log("job_wake", actor: "host", ["jobs": .array(notes.map { .string($0.job + ":" + $0.kind.rawValue) })])
            next = (Self.wakePrompt(notes), [])
        }
    }

    func turn(_ prompt: String, attachments: [Attachment]) async {
        var atts = attachments
        for u in Attachment.githubLinks(in: prompt) where !atts.contains(.githubRepo(u)) { atts.append(.githubRepo(u)) }
        var blocks = await AttachmentBuilder.blocks(for: atts, services: services)
        if !introduced {
            // Session-constant context goes into the first user turn, once, then stays in the cached prefix.
            let project = ProjectMemory.load(workspace: services.workspace)
            let others = SessionStore.index(workspace: services.workspace, excluding: services.taskId)
            let intro = [project, services.roleIntro(.main), others].filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !intro.isEmpty { blocks.insert(.text(intro), at: 0) }
            introduced = true
        }
        services.checkpoints.beginTurn(main.transcript.count)
        let auditStart = services.audit.head.seq
        let receiptStart = services.ledger.count
        defer { Task { await self.commitTurn(prompt: prompt, auditStart: auditStart, receiptStart: receiptStart) } }
        let main = self.main
        let work = Task { try await main.send(prompt, attachments: blocks); try await self.driveGoal() }
        stateLock.withLock { running = work }
        defer { stateLock.withLock { running = nil } }
        do {
            try await work.value
        } catch where work.isCancelled || error is CancellationError {
            services.emit(.notice(L("Interrupted.")))
        } catch {
            services.emit(.error(error.localizedDescription))
            services.log("error", actor: "host", ["message": .string(error.localizedDescription)])
        }
    }

    /// Goal driver: while a goal is active, start the next round when the agent goes idle, but only when
    /// a round can do something. Rounds never poll: running background jobs wake the agent when they
    /// report (`wakeIfIdle`), and a round that did no work or repeated the previous one hands the goal
    /// back to the user instead of spending tokens on the same reply again.
    func driveGoal() async throws {
        var previous: String?
        while true {
            if Task.isCancelled { return }
            guard let g = services.goal.current, g.phase == .active else { break }
            if services.permissions.mode == .plan {
                services.goal.hostWait(L("plan mode is read-only; approve the plan or leave plan mode to continue"))
                break
            }
            let jobs = services.jobs.runningCount
            if jobs > 0 && autoWake {
                if stateLock.withLock({ goalJobsNoticed != jobs }) {
                    stateLock.withLock { goalJobsNoticed = jobs }
                    services.emit(.notice(L10n.s("Goal: waiting for %@ background job(s); the next round starts when one reports.", String(jobs))))
                }
                return
            }
            stateLock.withLock { goalJobsNoticed = nil }
            guard let next = services.goal.nextRound(tokensSoFar: main.meter.session.promptTotal + main.meter.session.output) else { break }
            services.log("goal", actor: "host", ["event": "round", "objective": .string(g.objective),
                                                 "round": .int(services.goal.current?.roundsStarted ?? 0)])
            services.checkpoints.beginTurn(main.transcript.count)
            let before = main.transcript.count, epoch = main.epoch
            try await main.send(next)
            if Task.isCancelled { return }
            guard services.goal.current?.phase == .active else { break }   // the model completed, waited or blocked
            // Compaction replaces the transcript; then the whole (short) new transcript counts as the round.
            let round = main.epoch == epoch && main.transcript.count >= before ? Array(main.transcript[before...]) : main.transcript
            let uses = round.flatMap(\.toolUses)
            let fingerprint = uses.map { $0.name + $0.input.canonical }.joined(separator: "\n")
            if uses.isEmpty {
                services.goal.hostWait(L("the last round did no work"))
                break
            }
            if fingerprint == previous {
                services.goal.hostWait(L("the last round repeated the previous one"))
                break
            }
            previous = fingerprint
        }
        if let g = services.goal.current, g.phase != .active, g.phase != .paused {
            services.log("goal", actor: "host", ["event": .string(g.phase.rawValue), "reason": .string(g.waitingFor ?? g.blockedReason ?? g.completionNote ?? "")])
            var text = L10n.s("Goal %@", L(g.phase.rawValue)) + (g.blockedReason.map { ": \($0)" } ?? "") + (g.completionNote.map { " — \($0)" } ?? "")
            if g.phase == .waiting { text += (g.waitingFor.map { ": \($0)" } ?? "") + " " + L("Reply to continue.") }
            services.emit(.notice(text))
        }
    }

    public func replaceMain(_ s: AgentSession) { main = s }

    /// Snapshots the turn's file changes into the shadow repository, linking commit ⇄ audit log.
    func commitTurn(prompt: String, auditStart: Int, receiptStart: Int) async {
        let receipts = services.ledger.since(receiptStart).filter { !$0.filesWritten.isEmpty }.map(\.id)
        let head = services.audit.head
        let subject = "turn: " + prompt.split(separator: "\n").first.map { String($0).truncated(70, marker: "…") }.orEmpty
        guard let c = await services.git.snapshot(subject: subject, trailers: [
            "SieveSci-Task": services.taskId,
            "SieveSci-Receipts": receipts.joined(separator: " "),
            "SieveSci-Audit-Range": "\(auditStart + 1)-\(head.seq)",
            "SieveSci-Audit-Head": head.hash,
        ]) else { return }
        services.log("git_commit", actor: "host", ["commit": .string(c.commit), "subject": .string(subject),
                                                   "receipts": .array(receipts.map { .string($0) }),
                                                   "skipped_large": .array(c.skipped.map { .string("\($0.0) \($0.1)") })])
        services.emit(.committed(hash: c.commit, subject: subject, files: receipts.count))
    }
}

extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
