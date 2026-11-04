import Foundation

/// Host-driven delegation: once the plan holds two or more pending steps that need no other step's
/// results, SieveSci itself runs them on worker subagents (bounded concurrency) instead of waiting
/// for the main model to call `task` — models, CLI agents above all, rarely delegate on their own.
///
/// Runs right after a successful `update_plan`, inside that call, so the workers' reports come back
/// as its tool result and the main agent continues with synthesis. Each report is saved under
/// `<task>/workers/`, and the step records the worker's successful receipts as its evidence.
public struct DelegationPolicy: Sendable {
    /// Off: the main agent delegates only by calling `task` / `dispatch` itself.
    public var auto = true
    /// Workers running at once.
    public var maxParallel = 3
    /// Steps handed out per plan update.
    public var maxSteps = 6
    /// Fewer independent steps than this are left to the main agent.
    public var minSteps = 2
    public init() {}
}

public enum HostDelegation {
    /// Step titles that are the lead agent's own job: combining the other steps' results.
    static let synthesisPattern = #"(?i)\b(synthes|summar|integrat|combin|compar|conclu|final|report|writ|draft|recommend|overall)|综合|总结|汇总|比较|结论|撰写|报告"#

    /// Pending steps that can run now, each on its own worker.
    /// - `parallel: true` steps qualify once the steps they depend on are done.
    /// - `parallel: false` never does.
    /// - A step that declares `depends_on` (and is not a synthesis step) qualifies once those are done.
    /// - In a plan with no annotations at all, steps qualify when they name no other step and are not
    ///   synthesis steps (the model ignored the fields; the plan still says what is independent).
    public static func eligible(_ plan: ResearchPlan, excluding handled: Set<String> = []) -> [PlanStep] {
        let done = Set(plan.steps.filter { $0.status == "done" || $0.status == "skipped" }.map(\.id))
        let ids = Set(plan.steps.map(\.id))
        let annotated = plan.steps.contains { $0.parallel != nil || $0.dependsOn != nil }
        func depsMet(_ s: PlanStep) -> Bool { (s.dependsOn ?? []).allSatisfy { done.contains($0) || !ids.contains($0) } }
        func synthesis(_ s: PlanStep) -> Bool { s.title.range(of: synthesisPattern, options: .regularExpression) != nil }
        func namesOtherStep(_ s: PlanStep) -> Bool {
            let text = [s.title, s.detail, s.criteria].joined(separator: " ")
            return ids.subtracting([s.id]).contains { id in
                text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: id))\\b", options: [.regularExpression, .caseInsensitive]) != nil
            } || text.range(of: #"(?i)\b(previous|above|prior) step|results? (of|from) (the )?(step|steps)\b|上一步|前面的步骤"#, options: .regularExpression) != nil
        }
        return plan.steps.filter { s in
            guard s.status == "pending", !handled.contains(s.id), !s.title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            switch s.parallel {
            case true?: return depsMet(s)
            case false?: return false
            case nil:
                if s.dependsOn != nil { return depsMet(s) && !synthesis(s) }
                return !annotated && !synthesis(s) && !namesOtherStep(s)
            }
        }
    }

    /// Splitting a turn before the lead model starts skips grounding, the plan and its checkpoints, so
    /// it is only allowed once a plan exists (or when the research protocol is off). Before that, the
    /// lead agent grounds and plans, and the independent plan steps go to workers after `update_plan`.
    public static func mayDelegateTurn(groundingRequired: Bool, plan: ResearchPlan) -> Bool {
        !groundingRequired || !plan.steps.isEmpty
    }

    /// Added to a multi-part request that arrives before any plan: the parts become plan steps, and the
    /// independent ones run on workers after `update_plan`.
    public static let planFirstNote = "<planning_note>This request has several parts. After grounding (literature and "
        + "background), set the plan with `update_plan` before doing the parts: one step per part with its acceptance "
        + "criteria, `parallel: true` on each step that needs no other step's results (SieveSci runs those on workers), "
        + "and a checkpoint on the step that produces the deliverable.</planning_note>"

    /// The worker's whole instructions for one step: the step, plus the plan around it as context.
    public static func brief(step s: PlanStep, plan: ResearchPlan, others: [PlanStep]) -> String {
        var lines = ["<delegated_step id=\"\(s.id)\">",
                     "The lead research agent set a plan and SieveSci handed you one step of it. Other workers are doing "
                     + "the other independent steps at the same time; the lead agent will combine the reports.",
                     "", "Plan goal: \(plan.goal)"]
        if !plan.background.isEmpty { lines.append("Background so far: \(plan.background.truncated(2500))") }
        if !plan.hypotheses.isEmpty {
            lines.append("Hypotheses: " + plan.hypotheses.map { "\($0.id) \($0.statement.truncated(200))" }.joined(separator: "; "))
        }
        if !others.isEmpty { lines.append("Done by other workers (not your job): " + others.map { "\($0.id) \($0.title.truncated(80))" }.joined(separator: "; ")) }
        lines += ["", "Your step: \(s.id) — \(s.title)"]
        if !s.detail.isEmpty { lines.append("How: \(s.detail)") }
        if !s.criteria.isEmpty { lines.append("Done when: \(s.criteria)") }
        lines += ["",
                  "Do this step only. Search before asserting, `paper_fetch` the papers you rely on and cite them as [@key], "
                  + "never fabricate data, citations or numbers, and report failures as failures. End with a concise report: "
                  + "what you did, the findings with receipt ids, files you wrote, and open issues.",
                  "</delegated_step>"]
        return lines.joined(separator: "\n")
    }

    /// Whether a request lists two or more parts (numbered or bulleted). Only such requests are worth a
    /// decomposition call; the decomposer still decides whether the parts are independent.
    public static func looksMultiPart(_ prompt: String) -> Bool {
        let markers = [#"(?:^|\s)\(\d{1,2}\)\s"#, #"(?m)^\s*\d{1,2}[.)、]\s*\S"#, #"(?m)^\s*[-*•]\s+\S"#,
                       #"[（(][一二三四五六七八九十]+[)）]"#, #"[①②③④⑤⑥⑦⑧⑨]"#]
        let count = markers.reduce(0) { n, p in
            n + ((try? NSRegularExpression(pattern: p))?.numberOfMatches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)) ?? 0)
        }
        return count >= 2
    }

    /// Frozen instructions for the decomposition call (cache-stable).
    static let decomposer = """
    You split a research request into independent parts for parallel workers. A part is independent when it \
    can be done completely without any other part's results: separate topics, organisms, datasets, compounds or \
    questions. Do not split a request that is one question, whose steps must run in order, or that one agent \
    can answer in a few steps. Never make the final combination, comparison or summary a part: the lead agent \
    does that. Reply with one JSON object and nothing else:
    {"split": true | false, "parts": [{"title": "3-8 words", "brief": "complete instructions for a worker who has not \
    seen the request: what to find or do, the scope, constraints from the request (length, number of papers, \
    format), and what to return"}]}
    At most 6 parts. Keep the user's language in the briefs.
    """

    /// Asks the worker model to split `prompt`; [] when it should not be split or the call fails.
    static func decompose(_ prompt: String, services: SessionServices) async -> [(title: String, brief: String)] {
        let (p, m) = services.models.pick(.worker)
        var req = LLMRequest(model: m, system: decomposer, tools: [], messages: [Message.user("<request>\n\(prompt.truncated(8000))\n</request>")],
                             maxTokens: 3000, effort: .low, cache: CacheHints(lineageKey: services.taskId + "-decomposer", retention: services.retention))
        req.host = CLIHost(workspace: services.workspace, readOnly: true)
        let started = Date()
        let response = try? await p.complete(req)
        if p is CLIAgentProvider { CLIAgentProvider.endProcess(conversation: req.cache.lineageKey, profile: p.profile) }
        guard let resp = response else {
            services.log("host_decomposition", actor: "host", ["model": .string(m), "error": "call failed"])
            return []
        }
        let j = Supervisor.parseJSON(resp.message.plainText)
        let parts: [(title: String, brief: String)] = j?["split"]?.boolValue == true ? (j?["parts"]?.arrayValue ?? []).compactMap { e in
            guard let t = e.str("title"), let b = e.str("brief"), !b.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (t, b)
        } : []
        services.log("host_decomposition", actor: "host", ["model": .string(m), "parts": .array(parts.map { .string($0.title) }),
                                                           "seconds": .double(Date().timeIntervalSince(started)),
                                                           "input": .int(resp.usage.input), "output": .int(resp.usage.output)])
        return parts
    }
}

final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}

extension LockedValue where T == Int {
    /// Adds one and returns the new value, atomically.
    func increment() -> Int { var n = 0; mutate { $0 += 1; n = $0 }; return n }
}

/// Live subagents of a session, so Stop ends them too.
final class SubagentRegistry: @unchecked Sendable {
    private final class Weak { weak var s: AgentSession?; init(_ s: AgentSession) { self.s = s } }
    private let lock = NSLock()
    private var all: [Weak] = []

    func add(_ s: AgentSession) { lock.withLock { all = all.filter { $0.s != nil } + [Weak(s)] } }
    func cancelAll() { lock.withLock { all.compactMap(\.s) }.forEach { $0.cancel() } }
}

extension AgentSession {
    /// After a successful `update_plan`: hands independent pending steps to workers and returns what
    /// to append to the tool result (nil when nothing was delegated).
    func delegatePlanSteps(callId: String? = nil) async -> String? {
        let policy = services.delegation
        guard role == .main, policy.auto, !turnDelegated, tool(named: "task") != nil else { return nil }
        let plan = services.research.snapshot
        let steps = Array(HostDelegation.eligible(plan, excluding: delegatedSteps).prefix(policy.maxSteps))
        guard steps.count >= policy.minSteps else { return nil }
        return await runDelegated(steps, context: plan, inPlan: true, callId: callId)
    }

    /// At the start of a user turn: a request with several independent parts is split by the worker
    /// model and the parts run on workers before the main model starts, so it only has to combine the
    /// reports. Returns the `<host_delegation>` block for the user message (nil when nothing ran).
    func delegateTurn(_ prompt: String) async -> String? {
        let policy = services.delegation
        guard role == .main, policy.auto, tool(named: "task") != nil,
              HostDelegation.mayDelegateTurn(groundingRequired: services.research.groundingRequired, plan: services.research.snapshot),
              HostDelegation.looksMultiPart(prompt) else { return nil }
        let parts = await HostDelegation.decompose(prompt, services: services)
        guard parts.count >= policy.minSteps else { return nil }
        let steps = parts.prefix(policy.maxSteps).enumerated().map { i, p in
            PlanStep(id: "T\(i + 1)", title: p.title, detail: p.brief, status: "pending", checkpoint: false, criteria: "", evidence: [], note: "")
        }
        var context = services.research.snapshot
        context.goal = "The user's request (for context; do only your part):\n" + prompt.truncated(3000)
        context.hypotheses = []
        turnDelegated = true
        return await runDelegated(Array(steps), context: context, inPlan: false, callId: nil)
    }

    /// Runs `steps` on workers (at most `maxParallel` at once) after one permission check, saves each
    /// report, and — for plan steps — records the worker's receipts as the step's evidence.
    private func runDelegated(_ steps: [PlanStep], context plan: ResearchPlan, inPlan: Bool, callId: String?) async -> String? {
        guard let taskTool = tool(named: "task") else { return nil }
        let policy = services.delegation
        let workerModel = services.models.pick(.worker).1
        let kind = inPlan ? "plan steps" : "parts of the request"
        let summary = steps.map { "\($0.id) \($0.title.truncated(60))" }.joined(separator: "; ")

        // Starting workers is approved like the `task` tool it stands in for (once for the batch).
        let use = ToolUse(id: "host-delegation-" + String(UUID().uuidString.prefix(6)).lowercased(), name: "task",
                          input: ["description": .string("\(steps.count) \(kind) in parallel"), "prompt": .string(summary)])
        if let denial = await authorize(taskTool, use, .executes) {
            services.log("host_delegation", actor: "host", ["agent": .string(id), "steps": .array(steps.map { .string($0.id) }), "denied": .string(denial)])
            return inPlan ? "<host_delegation>SieveSci would have run \(summary) on workers, but starting workers was not allowed (\(denial)). Do these steps yourself.</host_delegation>" : nil
        }
        if inPlan {
            delegatedSteps.formUnion(steps.map(\.id))
            for s in steps { _ = services.research.updateStep(id: s.id, status: "in_progress", evidence: [], note: "delegated to a worker by SieveSci") }
            services.emit(.planChanged(services.research.snapshot))
        }
        services.emit(.notice(L10n.s("Running %@ plan steps on workers (%@).", "\(steps.count)", workerModel)))
        services.log("host_delegation", actor: "host", ["agent": .string(id), "trigger": .string(inPlan ? "plan" : "turn"),
                                                        "steps": .array(steps.map { .string("\($0.id) \($0.title)") }),
                                                        "model": .string(workerModel), "parallel": .int(policy.maxParallel)])
        ToolBridge.setPendingNote(for: callId, "SieveSci is running plan steps \(steps.map(\.id).joined(separator: ", ")) on workers. "
                                  + "Do not do these steps yourself; their reports are this call's result.")

        let dir = services.taskDir.appendingPathComponent("workers")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let failures = LockedValue<[String: String]>([:])
        let results = await runBounded(steps.count, par: policy.maxParallel) { i -> (String, String, [String], Bool) in
            let s = steps[i]
            guard !Task.isCancelled, !self.isCancelled else { return ("", "", [], false) }
            let w = self.services.makeSubagent(role: .worker, purpose: "\(s.id) · \(s.title.truncated(70))", parent: self.id)
            let writable = dir.path.replacingOccurrences(of: self.services.workspace.path + "/", with: "")
            let brief = HostDelegation.brief(step: s, plan: plan, others: steps.filter { $0.id != s.id })
                + "\n\nFiles: you may write only under `\(writable)/` (relative to the workspace); the rest of the "
                + "workspace is read-only for you. Prefix your file names with \(s.id)."
            let reply: String
            do { reply = try await w.send(brief)?.plainText ?? "" } catch {
                reply = ""
                failures.mutate { $0[s.id] = error.localizedDescription.truncated(600) }
                self.services.log("worker_error", actor: "host", ["agent": .string(w.id), "step": .string(s.id), "error": .string(error.localizedDescription.truncated(2000))])
            }
            return (w.id, reply, w.ownReceipts.value, !reply.isEmpty && !Task.isCancelled && !self.isCancelled)
        }
        let stopped = isCancelled || Task.isCancelled

        var out = [inPlan
            ? "<host_delegation>SieveSci ran \(steps.count) independent plan steps on workers (model: \(workerModel)) in parallel. "
                + "Their reports are below; check the receipts before relying on them, do not redo these steps, and continue "
                + "with the remaining steps and the synthesis."
            : "<host_delegation>SieveSci split this request into \(steps.count) independent parts and ran them on workers (model: \(workerModel)) "
                + "in parallel before your turn. Their reports are below, with receipts (the searches and fetched papers are in the task "
                + "library). Do not redo this work: check what matters against the receipts (`receipt`, `paper_read`, `verify_citation`), "
                + "fill real gaps only, and write the combined answer."]
        for (s, r) in zip(steps, results) {
            let (workerId, report, receipts, ok) = r
            guard ok else {
                if inPlan { _ = services.research.updateStep(id: s.id, status: "pending", evidence: [], note: stopped ? "worker stopped" : "worker failed") }
                out.append("\n## \(s.id) \(s.title)\n(worker \(workerId.isEmpty ? "not started" : workerId) \(stopped ? "was stopped" : failures.value[s.id].map { "failed: \($0)" } ?? "returned no report"); "
                           + (inPlan ? "the step is pending again — do it yourself or retry with `task`.)" : "do this part yourself.)"))
                continue
            }
            let file = dir.appendingPathComponent("\(s.id.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression))-\(workerId).md")
            try? "# \(s.id) \(s.title)\n\nworker: \(workerId) · model: \(workerModel) · receipts: \(receipts.joined(separator: ", "))\n\n\(report)\n".write(to: file, atomically: true, encoding: .utf8)
            let rel = file.path.replacingOccurrences(of: services.workspace.path + "/", with: "")
            var next = ""
            if inPlan {
                // A checkpoint is the lead agent's to pass (marking it done runs the review); the rest are done
                // when the worker has receipts to show for them.
                let status = !s.checkpoint && !receipts.isEmpty ? "done" : "in_progress"
                _ = services.research.updateStep(id: s.id, status: status, evidence: receipts, note: "worker \(workerId): \(report.truncated(300))")
                next = " — " + (status == "done" ? "marked done" : s.checkpoint ? "checkpoint: check the report, then mark it done with these receipts"
                    : "no receipts: verify before marking it done")
            }
            out.append("\n## \(s.id) \(s.title)\(next)\nworker \(workerId) · receipts: \(receipts.isEmpty ? "none" : receipts.joined(separator: ", ")) · full report: \(rel)\n"
                       + report.truncated(5000, marker: "\n[… report clipped; full text in \(rel)]"))
        }
        out.append("</host_delegation>")
        if inPlan { services.emit(.planChanged(services.research.snapshot)) }
        services.log("host_delegation_done", actor: "host", ["agent": .string(id), "steps": .array(zip(steps, results).map { s, r in
            ["step": .string(s.id), "worker": .string(r.0), "ok": .bool(r.3), "receipts": .array(r.2.map { .string($0) })]
        })])
        // Stopped before any worker reported: nothing to hand the main agent.
        if !inPlan && !results.contains(where: \.3) { return nil }
        return out.joined(separator: "\n")
    }

    /// Runs `count` jobs with at most `par` in flight; results in job order.
    private func runBounded<T: Sendable>(_ count: Int, par: Int, _ job: @escaping @Sendable (Int) async -> T) async -> [T] {
        var results = [T?](repeating: nil, count: count)
        var next = 0
        await withTaskGroup(of: (Int, T).self) { g in
            func launch() { if next < count { let i = next; next += 1; g.addTask { (i, await job(i)) } } }
            for _ in 0..<max(1, par) { launch() }
            for await (i, r) in g { results[i] = r; launch() }
        }
        return results.map { $0! }
    }
}
