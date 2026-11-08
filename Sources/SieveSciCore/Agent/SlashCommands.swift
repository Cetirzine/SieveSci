import Foundation

/// Slash commands. Built-ins mirror the mainstream agents (Claude Code, Codex, Gemini CLI,
/// OpenCode, Reasonix); research commands are SieveSci's own; every custom command file and every
/// user-invocable skill is also a command. The app shows `catalog` in the autocomplete popup and
/// opens native UI for the few that need it (/model, /config, /providers …) before calling `run`.
public struct SlashCommandInfo: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public var name: String
    public var args: String
    public var summary: String
    public var group: String
}

public enum SlashCommands {
    #if os(macOS)
    static let scheduleSummary = "Recurring headless runs (macOS LaunchAgents), e.g. daily literature watch"
    #elseif os(Windows)
    static let scheduleSummary = "Recurring headless runs (Windows Task Scheduler), e.g. daily literature watch"
    #else
    static let scheduleSummary = "Recurring headless runs (cron), e.g. daily literature watch"
    #endif

    public static let builtins: [SlashCommandInfo] = [
        // Session
        .init(name: "help", args: "", summary: "List commands and input shortcuts", group: "Session"),
        .init(name: "clear", args: "", summary: "Start a new task (fresh context; the old one stays resumable)", group: "Session"),
        .init(name: "resume", args: "[task-id]", summary: "List or resume a previous task in this workspace", group: "Session"),
        .init(name: "fork", args: "", summary: "Copy this conversation into a new task and continue there", group: "Session"),
        .init(name: "rewind", args: "[n]", summary: "Undo the last n turns: restore files and conversation", group: "Session"),
        .init(name: "export", args: "[md|json|ipynb]", summary: "Export the transcript, or executed Python as a Jupyter notebook", group: "Session"),
        .init(name: "changes", args: "[revert <path>]", summary: "Files changed in this task with diffs; revert one", group: "Session"),
        .init(name: "history", args: "[commit]", summary: "Shadow-git commit history of agent changes", group: "Session"),
        .init(name: "commit", args: "[message]", summary: "Commit current changes to your own git repo (with provenance trailers)", group: "Session"),
        .init(name: "trace", args: "<r12>", summary: "Traceability chain of a receipt: code, output hash, files, commit, audit entry", group: "Research"),
        .init(name: "report", args: "[path.md]", summary: "Write or export the research report with provenance footnotes (MD/DOCX/PDF)", group: "Research"),
        .init(name: "status", args: "", summary: "Model, provider, permissions, MCP, skills, grounding status", group: "Session"),
        // Model & context
        .init(name: "model", args: "[provider/model]", summary: "Switch model (cold-starts the prompt cache)", group: "Model"),
        .init(name: "effort", args: "[low|medium|high|xhigh|max]", summary: "Reasoning effort", group: "Model"),
        .init(name: "context", args: "", summary: "Context window usage, cache hit rate, prefix fingerprint", group: "Model"),
        .init(name: "cost", args: "", summary: "Token usage and cache savings for this session", group: "Model"),
        .init(name: "compact", args: "[focus]", summary: "Summarize the conversation to free context", group: "Model"),
        .init(name: "cache", args: "[short|long]", summary: "Prompt-cache retention for new sessions", group: "Model"),
        // Modes & control
        .init(name: "plan", args: "", summary: "Plan mode: read-only research and planning", group: "Modes"),
        .init(name: "permissions", args: "[ask|acceptEdits|auto|plan]", summary: "Permission mode and allow rules", group: "Modes"),
        .init(name: "connect", args: "[connector]", summary: "Connect a scientific MCP server (ToolUniverse …)", group: "Extensions"),
        .init(name: "goal", args: "<objective> [--rounds N] | pause | resume | clear | status", summary: "Long-running goal with automatic continuation rounds", group: "Modes"),
        .init(name: "todos", args: "", summary: "Show the agent's working checklist", group: "Modes"),
        .init(name: "tasks", args: "[id | stop <id>]", summary: "Background jobs and their live logs", group: "Modes"),
        .init(name: "agents", args: "", summary: "Subagent roles and the models they use", group: "Modes"),
        // Research
        .init(name: "search", args: "<query>", summary: "Web search now (international sources)", group: "Research"),
        .init(name: "papers", args: "[query]", summary: "Task literature library", group: "Research"),
        .init(name: "cite", args: "<doi|pmid|arXiv>", summary: "Add a paper to the library and get its key", group: "Research"),
        .init(name: "links", args: "[key|file]", summary: "Paper ↔ code links", group: "Research"),
        .init(name: "plan-show", args: "", summary: "Research plan, hypotheses and checkpoints", group: "Research"),
        .init(name: "claims", args: "", summary: "Claims and their verification status", group: "Research"),
        .init(name: "review", args: "[focus]", summary: "Ask the independent checker to review the work now", group: "Research"),
        .init(name: "brainstorm", args: "[topic]", summary: "Brainstorm new ideas you can watch live; novelty-checked before they count", group: "Research"),
        .init(name: "ideas", args: "[dream]", summary: "Ideas from brainstorming (or last night's dream) and their checks", group: "Research"),
        .init(name: "clarify", args: "[request]", summary: "Search, brainstorm directions, then ask you to choose", group: "Research"),
        .init(name: "dream", args: "[on [daily HH:MM] | off | now | status]", summary: "Background dreaming: a nightly read-only run that links open threads into ideas", group: "Research"),
        .init(name: "notebook", args: "", summary: "Open the automatically written lab notebook", group: "Research"),
        .init(name: "audit", args: "", summary: "Verify the hash-chained provenance log", group: "Research"),
        .init(name: "grounding", args: "[on|off]", summary: "Require web + literature search before claims (default on)", group: "Research"),
        // Extensions
        .init(name: "skills", args: "", summary: "Installed skills (each is also a /command)", group: "Extensions"),
        .init(name: "evolution", args: "[approve|reject|revert <id>]", summary: "Learning proposals by every role, with their review outcome", group: "Extensions"),
        .init(name: "quota", args: "", summary: "Plan quota, API balance and tracked spend per provider", group: "Model"),
        .init(name: "models", args: "", summary: "Which model each role uses, and why (benchmarks)", group: "Model"),
        .init(name: "refresh", args: "", summary: "Refresh model catalog, prices, endpoints and leaderboards now", group: "Model"),
        .init(name: "plugins", args: "[install <pack>]", summary: "Skill packs (e.g. K-Dense scientific skills)", group: "Extensions"),
        .init(name: "mcp", args: "", summary: "MCP servers and their tools", group: "Extensions"),
        .init(name: "hooks", args: "", summary: "Configured hooks", group: "Extensions"),
        .init(name: "schedule", args: "[daily HH:MM|weekly mon HH:MM|every 6h <prompt> | remove <id>]", summary: scheduleSummary, group: "Extensions"),
        .init(name: "memory", args: "", summary: "Project memory files (SIEVESCI.md / AGENTS.md / CLAUDE.md)", group: "Extensions"),
        .init(name: "init", args: "", summary: "Analyse the workspace and write SIEVESCI.md", group: "Extensions"),
        .init(name: "add-dir", args: "<path>", summary: "Grant access to another directory (next session)", group: "Extensions"),
        .init(name: "config", args: "", summary: "Settings", group: "Extensions"),
        .init(name: "providers", args: "", summary: "Model providers, API keys, coding plans, relays", group: "Extensions"),
        .init(name: "doctor", args: "", summary: "Check python, R, git, CLIs, keys and network", group: "Extensions"),
    ]

    public static func catalog(workspace: URL, skills: SkillRegistry) -> [SlashCommandInfo] {
        builtins
            + CustomCommand.load(workspace: workspace).map { .init(name: $0.name, args: $0.argumentHint, summary: $0.description, group: "Custom") }
            + skills.skills.filter(\.userInvocable).map { .init(name: $0.name, args: "", summary: $0.description.truncated(120, marker: "…"), group: "Skills") }
    }

    static func run(_ input: String, bench: Workbench) async -> Workbench.Routed {
        let s = bench.services
        let body = String(input.dropFirst())
        let name = body.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let args = body.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        func ok(_ m: String) -> Workbench.Routed { .handled(m) }

        switch name {
        case "help":
            let groups = Dictionary(grouping: catalog(workspace: s.workspace, skills: s.skills), by: \.group)
            var out = L("Input: `/` command · `!` shell · `#` remember · `@path` mention · Esc interrupt · Esc Esc rewind · ⇧⇥ permission mode") + "\n"
            for g in ["Session", "Model", "Modes", "Research", "Extensions", "Custom", "Skills"] {
                guard let cs = groups[g] else { continue }
                out += "\n\(L(g))\n" + cs.map { "  /\($0.name)\($0.args.isEmpty ? "" : " " + $0.args) — \(L($0.summary))" }.joined(separator: "\n") + "\n"
            }
            return ok(out)
        case "status":
            let g = s.research.hasGrounding()
            return ok([
                L10n.s("Task %@ · workspace %@", s.taskId, s.workspace.path),
                L10n.s("Main: %@ / %@ · checker: %@ · verifier: %@", bench.main.provider.profile.displayName, bench.main.model, s.models.checker.1, s.models.verifier.1),
                L10n.s("Permissions: %@ · rules: %@", L(s.permissions.mode.rawValue), s.permissions.rules.joined(separator: ", ")),
                L10n.s("Grounding: %@ (web %@, literature %@)", L(s.research.groundingRequired ? "required" : "off"), g.web ? "✓" : "✗", g.literature ? "✓" : "✗"),
                L10n.s("MCP: %@ · skills: %@ · tools: %@", s.mcp.status.map { "\($0.name)\($0.connected ? "(\($0.tools))" : "✗")" }.joined(separator: " "),
                       String(s.skills.skills.count), String(s.toolset.count)),
                L10n.s("Cache retention: %@", s.retention.rawValue),
            ].joined(separator: "\n"))
        case "context", "cost":
            let m = bench.main.meter
            let u = m.session
            return ok([
                L10n.s("Context: %@ / %@ tokens (%@)", String(m.lastPromptTokens), String(m.contextWindow), "\(Int(m.fill * 100))%"),
                L10n.s("Session tokens — input %@, cache read %@, cache write %@, output %@ (reasoning %@)",
                       String(u.input), String(u.cacheRead), String(u.cacheWrite), String(u.output), String(u.reasoning)),
                L10n.s("Cache hit rate: %@ of prompt tokens", String(format: "%.1f%%", u.hitRate * 100)),
                L10n.s("Prefix: %@ tools, system prompt fingerprint %@", String(bench.main.tools.count), bench.main.system.stableHash),
            ].joined(separator: "\n"))
        case "compact":
            return ok(await bench.compactNow(focus: args.isEmpty ? nil : args).message)
        case "effort":
            if let e = Effort(rawValue: args) { s.effort = e; return ok(L10n.s("Effort → %@. (Changing effort mid-session can reset part of the cache on some vendors.)", e.rawValue)) }
            return ok(L10n.s("Effort: %@. Options: low medium high xhigh max", s.effort?.rawValue ?? L("model default")))
        case "cache":
            if let r = CacheRetention(rawValue: args) { s.retention = r; return ok(L10n.s("Cache retention → %@ (applies to new sessions; changing it now would cold-start the cache).", r.rawValue)) }
            return ok(L10n.s("Cache retention: %@. Options: short long none", s.retention.rawValue))
        case "plan":
            s.permissions.mode = s.permissions.mode == .plan ? .ask : .plan
            return ok(s.permissions.mode == .plan ? L("Plan mode on — read-only until you leave it with /plan.") : L("Plan mode off."))
        case "permissions":
            if let m = PermissionMode(rawValue: args) { s.permissions.mode = m; return ok(L10n.s("Permission mode → %@.", L(m.rawValue))) }
            return ok(L10n.s("Mode: %@", L(s.permissions.mode.rawValue)) + "\n" + L("Allow rules:") + "\n" + s.permissions.rules.map { "  \($0)" }.joined(separator: "\n"))
        case "goal":
            switch args {
            case "", "status":
                guard let g = s.goal.current else { return ok(L("No goal. Set one with /goal <objective>.")) }
                return ok(L10n.s("Goal: %@", g.objective) + "\n" + L10n.s("Phase: %@ · rounds %@", L(g.phase.rawValue), "\(g.roundsStarted)\(g.maxRounds.map { "/\($0)" } ?? "")")
                          + (g.blockedReason.map { " · \($0)" } ?? ""))
            case "pause": s.goal.pause(); bench.interrupt(); return ok(L("Goal paused."))
            case "resume": s.goal.resume(); return .prompt("Resume work on the goal.")
            case "clear": s.goal.clear(); return ok(L("Goal cleared."))
            default:
                // `--rounds N` sets the round cap (0 = none); without it the default cap applies.
                var objective = args, rounds: Int?
                if let m = objective.range(of: #"--rounds\s+(\d+)"#, options: .regularExpression) {
                    rounds = Int(objective[m].split(separator: " ").last ?? "")
                    objective.removeSubrange(m)
                    objective = objective.trimmingCharacters(in: .whitespaces)
                }
                let g = s.goal.create(objective, maxRounds: rounds)
                s.log("goal", actor: "user", ["event": "created", "objective": .string(g.objective), "max_rounds": .int(g.maxRounds ?? 0)])
                return .prompt("New goal: \(objective)\nStart by searching the background, then plan with checkpoints.")
            }
        case "todos":
            return ok(s.todos.items.isEmpty ? L("No todos.") : s.todos.items.map { ($0.status == "completed" ? "☒ " : $0.status == "in_progress" ? "◐ " : "☐ ") + $0.content }.joined(separator: "\n"))
        case "tasks":
            if args.hasPrefix("stop ") { return ok(s.jobs.stop(String(args.dropFirst(5))) ? L("Stopping.") : L("Not running.")) }
            if !args.isEmpty { return ok(s.jobs.output(args, onlyNew: false, maxLines: 400) ?? L10n.s("No job %@.", args)) }
            let all = s.jobs.all
            return ok(all.isEmpty ? L("No background jobs.") : all.map {
                "\($0.id)  \($0.running ? L("running") : L10n.s("exit %@", String($0.exitCode ?? -1)))  \(L10n.s("%@ lines", String($0.lineCount)))  \($0.label.truncated(80))"
            }.joined(separator: "\n") + "\n" + L("/tasks <id> shows a job's log · /tasks stop <id>"))
        case "agents":
            return ok([
                "\(L("main")) → \(s.models.main.0.profile.displayName) / \(s.models.main.1)",
                "\(L("checker")) → \(s.models.checker.0.profile.displayName) / \(s.models.checker.1)  (\(L("read-only reviews")))",
                "\(L("verifier")) → \(s.models.verifier.0.profile.displayName) / \(s.models.verifier.1)  (\(L("blind re-implementation")))",
                "\(L("worker")) → \(s.models.worker.0.profile.displayName) / \(s.models.worker.1)  (\(L("delegated subtasks")))",
                L10n.s("Reviews this session are capped at %@.", String(s.supervisorPolicy.maxReviewsPerSession)),
            ].joined(separator: "\n"))
        case "search":
            guard !args.isEmpty else { return ok(L("Usage: /search <query>")) }
            return .prompt("Search the web and the literature for: \(args). Summarize what you find with sources; do not add anything not in the results.")
        case "papers":
            let rs = s.library.records.filter { args.isEmpty || $0.title.lowercased().contains(args.lowercased()) }
            return ok(rs.isEmpty ? L("Library is empty.") : rs.map { "[@\($0.key)] \($0.title) (\($0.year.map(String.init) ?? L("n.d."))) · \($0.pdfPath != nil ? "PDF" : L("abstract"))" }.joined(separator: "\n"))
        case "cite":
            guard !args.isEmpty else { return ok(L("Usage: /cite <doi|pmid|arXiv id>")) }
            return .prompt("Add \(args) to the library with paper_fetch and tell me its citation key.")
        case "links":
            let links = CodePaperLinker.scan(workspace: s.workspace, library: s.library)
                .filter { args.isEmpty || $0.paperKey == args || $0.file.contains(args) }
            return ok(links.isEmpty ? L("No paper↔code links.") : links.map { "\($0.file):\($0.line) → \($0.paperKey.map { "[@\($0)]" } ?? $0.identifier)\($0.locator.map { " \($0)" } ?? "")" }.joined(separator: "\n"))
        case "plan-show":
            return ok(s.research.snapshot.markdown)
        case "claims":
            let cs = s.claims.snapshot
            var out = cs.isEmpty ? L("No claims.") : cs.map { "\($0.id) [\(L($0.status.rawValue))] \($0.statement)\($0.verdict.map { "\n    → \($0.truncated(300))" } ?? "")" }.joined(separator: "\n")
            let con = s.deliberation.contested
            if !con.isEmpty { out += "\n\n" + L("Contested between agents (your call):") + "\n" + con.map { "\($0.thread) [\($0.kind)] \($0.issue)\n    → \($0.reason)" }.joined(separator: "\n") }
            return ok(out)
        case "review":
            let r = await s.supervisor.review(kind: "manual", signals: [], focus: args.isEmpty ? bench.main.transcript.last?.plainText ?? "" : args)
            if let r { return .prompt(r) }
            return ok(L("The checker found no problems (or the review budget is exhausted)."))
        case "notebook":
            return ok(L10n.s("Lab notebook: %@", s.notebook.url.path))
        case "audit":
            do {
                let broken = try AuditLog.verify(s.audit.url)
                let n = s.audit.head.seq
                return ok(broken.map { "✗ " + L10n.s("Provenance chain broken at entry §%@.", String($0)) } ?? "✓ " + L10n.s("Provenance chain intact (%@ entries): %@", String(n), s.audit.url.path))
            } catch { return ok(L10n.s("Could not read the audit log: %@", error.localizedDescription)) }
        case "grounding":
            if args == "off" { s.research.groundingRequired = false; s.log("grounding", actor: "user", ["required": false]); return ok(L("Grounding gate off for this task (logged).")) }
            if args == "on" { s.research.groundingRequired = true; return ok(L("Grounding gate on.")) }
            return ok(L(s.research.groundingRequired ? "Grounding gate: on" : "Grounding gate: off"))
        case "evolution":
            let parts = args.split(separator: " ").map(String.init)
            if parts.count == 2 {
                switch parts[0] {
                case "approve": return ok(s.governor.decide(parts[1], approve: true, services: s))
                case "reject": return ok(s.governor.decide(parts[1], approve: false, services: s))
                case "revert": return ok(s.governor.revert(parts[1], services: s))
                default: break
                }
            }
            let ps = s.governor.proposals.suffix(30)
            return ok(ps.isEmpty ? L("No learning proposals yet.") : ps.map { "\($0.id) [\(L($0.status.rawValue))] \(L($0.role.rawValue)) · \($0.kind.rawValue) \($0.target) \($0.operation)\n    \($0.content.truncated(160, marker: "…"))\n    → \($0.reason.truncated(200, marker: "…"))" }.joined(separator: "\n")
                      + "\n\n" + L("Pending ones need /evolution approve <id> or /evolution reject <id>."))
        case "quota":
            var lines: [String] = []
            var seen = Set<String>()
            for (p, _) in [s.models.main, s.models.checker, s.models.verifier, s.models.worker] where seen.insert(p.profile.id).inserted {
                let q = await QuotaService.shared.refresh(p.profile, secrets: s.secrets)
                let spend = SpendTracker.shared.spend(providerId: p.profile.id)
                lines.append("\(p.profile.displayName)\(q.plan.map { " · \($0)" } ?? "")")
                for m in q.meters { lines.append("  \(m.label): \(m.remaining)\(m.resetsAt.map { " · " + L10n.s("resets %@", $0.formatted(date: .abbreviated, time: .shortened)) } ?? "")") }
                if let n = q.note { lines.append("  \(n)") }
                lines.append("  " + L10n.s("Tracked spend: %@ today · %@ this month (usage × models.dev prices)",
                                           String(format: "$%.4f", spend.today), String(format: "$%.2f", spend.month)))
            }
            return ok(lines.joined(separator: "\n"))
        case "models":
            if ModelsDevCatalog.shared.providers.isEmpty { _ = try? await ModelsDevCatalog.shared.refresh() }
            let snap = BenchmarkSnapshot.current()
            var out = L("Role models:") + "\n"
            for (r, pm) in [("main", s.models.main), ("checker", s.models.checker), ("verifier", s.models.verifier), ("worker", s.models.worker)] {
                let role = AgentRole(rawValue: r)!
                let (score, reasons) = RoleModelAdvisor.score((pm.0.profile, pm.1, nil), role: role, snapshot: snap)
                out += "  \(L(r)): \(pm.0.profile.displayName) / \(pm.1)\(score.map { " · " + L10n.s("fit %@", String(format: "%.2f", $0)) } ?? "")\n    \(reasons.joined(separator: "; "))\n"
            }
            out += "\n" + L("Benchmarks:") + " " + snap.benchmarks.values.map { "\($0.title) (\($0.asOf))" }.sorted().joined(separator: ", ")
            return ok(out + "\n" + L("Change the assignment in Settings → Models (Auto / Same for all / Custom)."))
        case "refresh":
            let r = await CatalogRefresher.refreshAll(extractor: s.models.worker.0, extractorModel: s.models.worker.1)
            return ok(r.lines.joined(separator: "\n"))
        case "skills":
            let sk = s.skills.skills
            return ok(sk.isEmpty ? L("No skills installed. Try /plugins install k-dense-scientific") : sk.map { "/\($0.name) — \($0.description.truncated(100, marker: "…")) [\($0.source)]" }.joined(separator: "\n"))
        case "plugins":
            if args.hasPrefix("install") {
                let id = args.dropFirst("install".count).trimmingCharacters(in: .whitespaces)
                guard let pack = SkillRegistry.knownPacks.first(where: { $0.id == id }) else {
                    return ok(L10n.s("Unknown pack. Available: %@", SkillRegistry.knownPacks.map(\.id).joined(separator: ", ")))
                }
                let msg = (try? await SkillRegistry.install(pack)) ?? L("Install failed.")
                s.skills.reload()
                return ok(msg + " " + L("Skills appear as /commands; the model sees them from the next session."))
            }
            return ok(SkillRegistry.knownPacks.map { "\($0.id) — \($0.title) [\($0.license)]\n   \($0.repo)\n   \($0.notes)" }.joined(separator: "\n") + "\n\n" + L("Install with /plugins install <id>"))
        case "connect":
            if args.isEmpty {
                return ok(ScienceConnectors.all.map { c in
                    "\(c.id) — \(c.title) [\(c.license)]\(ScienceConnectors.isConnected(c.id) ? " ✓" : "")\n   \(c.notes)\n   \(c.source)"
                }.joined(separator: "\n") + "\n\n/connect <id>")
            }
            do { return ok(try ScienceConnectors.connect(args)) } catch { return ok(error.localizedDescription) }
        case "mcp":
            let st = s.mcp.status
            return ok(st.isEmpty ? L("No MCP servers configured (.mcp.json or ~/.sievesci/mcp.json).") : st.map {
                "\($0.name): \($0.connected ? L10n.s("connected, %@ tools", String($0.tools)) : L10n.s("failed — %@", $0.error ?? ""))"
            }.joined(separator: "\n"))
        case "hooks":
            let lines = HookRunner.Event.allCases.flatMap { e in s.hooks.entries(for: e).map { "\(e.rawValue)\($0.matcher.map { " [\($0)]" } ?? ""): \($0.command)" } }
            return ok(lines.isEmpty ? L("No hooks configured (.sievesci/settings.json).") : lines.joined(separator: "\n"))
        case "memory":
            let m = ProjectMemory.load(workspace: s.workspace)
            return ok(m.isEmpty ? L("No memory files. Create SIEVESCI.md, or type `# <fact>` to add one.") : m)
        case "init":
            return .prompt("""
            Analyse this workspace (data files, code, existing notes) and write SIEVESCI.md: the project's scientific \
            question, data sources and formats, conventions, environments and how to run analyses, and open questions. \
            Only state what you can see in the files.
            """)
        case "export" where args == "ipynb":
            return ok(NotebookExport.ipynb(services: s).map { L10n.s("Jupyter notebook: %@", $0.path) } ?? L("Nothing to export."))
        case "changes":
            if args.hasPrefix("revert ") {
                let rel = String(args.dropFirst(7))
                let path = s.workspace.appendingPathComponent(rel).path
                let done = s.changes.revert(path)
                s.log("revert_file", actor: "user", ["path": .string(rel), "ok": .bool(done)])
                return ok(done ? L10n.s("Reverted %@ to its state before this task.", rel) : L10n.s("No recorded original for %@.", rel))
            }
            let files = s.changes.changedFiles
            return ok(files.isEmpty ? L("No files changed by agents in this task.") : files.map { p in
                let d = s.changes.diff(p, workspace: s.workspace)
                return "\(d.path)  +\(d.added) −\(d.removed)\(d.isNewFile ? "  (\(L("new")))" : "")"
            }.joined(separator: "\n"))
        case "history":
            if !args.isEmpty {
                let ds = await s.git.diffs(of: args)
                return ok(ds.map { $0.unified }.joined(separator: "\n").truncated(20_000))
            }
            let log = await s.git.log()
            return ok(log.isEmpty ? L("No history yet.") : log.map { "\($0.hash.prefix(10))  \($0.date.prefix(16))  \($0.subject)" }.joined(separator: "\n"))
        case "commit":
            let msg = args.isEmpty ? "SieveSci: changes from task \(s.taskId)" : args
            let r = await s.git.commitUserRepo(message: msg, trailers: ["SieveSci-Task": s.taskId, "SieveSci-Audit-Head": s.audit.head.hash])
            s.log("user_commit", actor: "user", ["message": .string(msg), "result": .string(r)])
            return ok(r)
        case "trace":
            guard !args.isEmpty else { return ok(L("Usage: /trace r12")) }
            return ok(ProvenanceTrace.build(auditURL: s.audit.url).describe(args))
        case "report":
            let path = args.isEmpty ? "report.md" : args
            let url = s.workspace.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                return ok(await ReportExporter.export(report: url, services: s).joined(separator: "\n"))
            }
            return .prompt("""
            Write the research report to \(path): question, background with [@key] citations (verified with \
            verify_citation), methods (software versions, seeds), results with every number followed by the receipt \
            that produced it, e.g. "(r12)", claims with their verification status, limitations, and conclusions \
            limited to verified claims. Then tell me to run /report \(path) again to export it with provenance.
            """)
        case "export":
            let msgs = bench.main.transcript
            let url = s.taskDir.appendingPathComponent(args == "json" ? "export.json" : "export.md")
            if args == "json" {
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                try? enc.encode(msgs).write(to: url)
            } else {
                try? SessionStore.markdown(msgs).writeReliably(to: url)
            }
            return ok(L10n.s("Exported to %@", url.path))
        case "rewind":
            let n = Int(args) ?? 1
            // The user's own turns: a host note riding with tool results is not a place to rewind to.
            let userTurns = bench.main.transcript.indices.filter { HostContext.ownWords(bench.main.transcript[$0]) != nil }
            guard userTurns.count >= n, let target = userTurns.dropLast(n - 1).last else { return ok(L("Nothing to rewind.")) }
            let files = s.checkpoints.rewind(toTurn: target)
            bench.main.truncate(to: target)
            s.log("rewind", actor: "user", ["to_message": .int(target), "files": .array(files.map { .string($0) })])
            return ok(L10n.s("Rewound %@ turn(s). Restored files: %@", String(n), files.isEmpty ? L("none") : files.joined(separator: ", ")))
        case "brainstorm":
            s.ideas.request(.user)
            return .prompt("Brainstorm" + (args.isEmpty ? " on the current task" : ": \(args)")
                + ". Use the skill “brainstorm” (load it with the skill tool first) and start with `brainstorm` start so I can watch.")
        case "clarify":
            return .prompt("Use the skill “clarify” (load it with the skill tool first) for this request: "
                + (args.isEmpty ? (bench.main.transcript.lazy.reversed().compactMap(HostContext.ownWords).first ?? "") : args))
        case "ideas":
            if args == "dream" {
                let inbox = DreamInbox.load(s.workspace)
                DreamInbox.markSeen(s.workspace)
                return ok(inbox.isEmpty ? L("No ideas from dreaming yet. Turn it on with /dream on.")
                    : inbox.suffix(30).map { "\($0.seen ? " " : "•") \($0.idea.id) [\($0.idea.novelty?.rawValue ?? L("not checked"))] \($0.idea.statement.truncated(140))  (\($0.task))" }.joined(separator: "\n"))
            }
            let all = s.ideas.snapshot
            return ok(all.isEmpty ? L("No ideas yet. Try /brainstorm.") : all.map {
                "\($0.id) [\(L($0.status.rawValue))\($0.novelty.map { ", " + L($0.rawValue) } ?? "")\($0.hypothesisId.map { " → \($0)" } ?? "")] \($0.statement.truncated(140))"
            }.joined(separator: "\n"))
        case "dream":
            let mine = Scheduler.list().filter { $0.workspace == s.workspace.path && $0.prompt == DreamProtocol.schedulePrompt }
            let parts = args.split(separator: " ").map(String.init)
            switch parts.first ?? "status" {
            case "now":
                s.ideas.request(.dream)
                return .prompt(DreamProtocol.prompt)
            case "on":
                guard mine.isEmpty else { return ok(L10n.s("Dreaming is already on (%@).", mine.map(\.when).joined(separator: ", "))) }
                let when = parts.count > 1 ? parts.dropFirst().joined(separator: " ") : "daily 03:00"
                let r = await Scheduler.add(workspace: s.workspace, when: when, prompt: DreamProtocol.schedulePrompt, mode: .plan)
                s.log("dream", actor: "user", ["event": "on", "when": .string(when)])
                return ok(r)
            case "off":
                guard !mine.isEmpty else { return ok(L("Dreaming is off.")) }
                for t in mine { _ = await Scheduler.remove(t.id) }
                s.log("dream", actor: "user", ["event": "off"])
                return ok(L("Dreaming turned off."))
            default:
                let unseen = DreamInbox.unseen(s.workspace).count
                return ok((mine.isEmpty ? L("Dreaming is off. /dream on schedules a nightly read-only run (default 03:00).")
                           : L10n.s("Dreaming is on: %@.", mine.map(\.when).joined(separator: ", ")))
                          + "\n" + L10n.s("%@ unseen idea(s) from dreaming · /ideas dream", String(unseen)))
            }
        case "schedule":
            if args.isEmpty { return ok(Scheduler.describe()) }
            if args.hasPrefix("remove ") { return ok(await Scheduler.remove(String(args.dropFirst(7)).trimmingCharacters(in: .whitespaces))) }
            guard let (when, prompt) = Scheduler.parse(args) else { return ok(L("Usage: /schedule daily 08:30 <prompt> · weekly mon 09:00 <prompt> · every 6h <prompt> · remove <id>")) }
            let r = await Scheduler.add(workspace: s.workspace, when: when, prompt: prompt)
            s.log("schedule", actor: "user", ["when": .string(when), "prompt": .string(prompt), "result": .string(r)])
            return ok(r)
        case "resume":
            let tasks = SessionStore.tasks(in: s.workspace)
            return ok(tasks.isEmpty ? L("No tasks.") : tasks.prefix(20).map { "\($0.id)  \($0.modified)" }.joined(separator: "\n") + "\n" + L("(Open one from the sidebar, or restart with --task <id>.)"))
        case "clear", "fork", "model", "config", "providers", "doctor", "add-dir":
            // These need the host (new session object / native UI); the app and CLI handle them.
            return ok(L10n.s("/%@ is handled by the app window.", name))
        default:
            if let c = CustomCommand.load(workspace: s.workspace).first(where: { $0.name == name }) { return .prompt(c.expand(args)) }
            if let sk = s.skills.skill(name) {
                return .prompt("Use the skill “\(sk.name)” for this request (load it with the skill tool first). \(args)")
            }
            return ok(L10n.s("Unknown command /%@. Type /help.", name))
        }
    }
}
