import Foundation

/// The research workflow SieveSci enforces. It is *flexible*: stages can be revisited and the plan
/// revised at any time (Agent Laboratory loops back from interpretation to experimentation when
/// results are insufficient), but a few transitions are gated by host-checked evidence:
///
/// 1. **Grounding gate** — before planning, claiming, passing a checkpoint or writing conclusions,
///    the task must have receipts from a web search *and* a literature search. No reasoning from
///    memory alone.
/// 2. **Pre-registration** — every hypothesis states a prediction and a falsification criterion
///    before analysis; changing a criterion after results exist is recorded as a deviation and
///    sent to the checker (HARKing guard).
/// 3. **Checkpoints** — soft milestones in the plan. Reaching one dispatches the checker agent;
///    the plan continues unless the checker returns `block`.
/// 4. **Claims** — a finding the agent calls significant/novel is verified by an independent,
///    blind subagent before it may appear as a conclusion.
public enum ResearchStage: String, Codable, Sendable, CaseIterable {
    case scoping, background, planning, execution, analysis, verification, writing, done
}

public struct Hypothesis: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var statement: String
    public var prediction: String
    public var falsification: String
    public var status: String          // open | supported | refuted | inconclusive
    public var registeredAt: Date
    /// What to do if the result is negative or inconclusive, written before the analysis (like an
    /// adaptive trial's pre-specified rule): following it later is not a deviation.
    public var onNegative: String? = nil
}

public struct PlanStep: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var status: String          // pending | in_progress | done | skipped | failed
    /// A checkpoint step triggers a supervisor review when marked done.
    public var checkpoint: Bool
    /// Soft acceptance criteria the checker reviews against (not a rigid gate).
    public var criteria: String
    /// Receipt ids the agent cites as evidence that the step is done.
    public var evidence: [String]
    public var note: String
    /// Whether the step can run alongside the others (nil: not said). Independent pending steps are
    /// handed to workers by the host (see `HostDelegation`).
    public var parallel: Bool? = nil
    /// Steps whose results this one needs (nil: not said; [] declares it needs none).
    public var dependsOn: [String]? = nil
    /// What to do if this step fails, written in advance (following it later is not a deviation).
    public var onFailure: String? = nil
}

extension PlanStep {
    /// Plans saved before `parallel` / `dependsOn` existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        checkpoint = try c.decodeIfPresent(Bool.self, forKey: .checkpoint) ?? false
        criteria = try c.decodeIfPresent(String.self, forKey: .criteria) ?? ""
        evidence = try c.decodeIfPresent([String].self, forKey: .evidence) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        parallel = try c.decodeIfPresent(Bool.self, forKey: .parallel)
        dependsOn = try c.decodeIfPresent([String].self, forKey: .dependsOn)
        onFailure = try c.decodeIfPresent(String.self, forKey: .onFailure)
    }
}

public struct PlanRevision: Codable, Sendable, Equatable {
    public var at: Date
    public var rationale: String
    public var changedCriteria: [String]   // step/hypothesis ids whose criteria changed
    public var afterResults: Bool          // true if analysis receipts existed when criteria changed
}

public struct ResearchPlan: Codable, Sendable, Equatable {
    public var goal: String
    public var background: String          // what the searches established, with citations
    public var hypotheses: [Hypothesis]
    public var steps: [PlanStep]
    public var revisions: [PlanRevision]
    public var stage: ResearchStage
    /// The task's objective in the user's own words, fixed when the first plan is set: every change of
    /// course must still serve it, and only the user can change it.
    public var objective: String? = nil
    /// Looks back at results that went against the plan (`result_review`), oldest first.
    public var reviews: [ResultReview]? = nil
    /// A review the host is waiting for before analysis goes on.
    public var pendingReview: PendingReview? = nil
    /// Ledger position of the last review: failed runs before it do not count towards a stall (kept
    /// across restarts, so old failures never trigger a review again).
    public var reviewMark: Int? = nil
    /// What the user decided along the way (answers to `ask_user`, the brainstorm's outcome), oldest first.
    /// Shown in every turn's context and kept through compaction, so a long task does not forget a choice
    /// made at its start (Manus's recitation; Anthropic's progress file for long-running agents).
    public var decisions: [UserDecision]? = nil
    /// Idea reviews that did not pass since the user last decided: after a few, the user is asked again
    /// instead of the agent revising the idea away from what they chose.
    public var ideaReviewsSinceDecision: Int? = nil

    public init(goal: String = "") {
        self.goal = goal
        background = ""
        hypotheses = []
        steps = []
        revisions = []
        stage = .scoping
    }

    public var markdown: String {
        var s = (objective.map { "**Objective (fixed):** \($0.truncated(300))\n" } ?? "") + "**Goal:** \(goal)\n"
        if !hypotheses.isEmpty {
            s += "\n**Hypotheses**\n"
            for h in hypotheses { s += "- [\(h.status)] \(h.id): \(h.statement) — predicts: \(h.prediction); falsified if: \(h.falsification)\n" }
        }
        s += "\n**Plan**\n"
        for st in steps {
            let box = ["done": "☒", "in_progress": "◐", "failed": "✗", "skipped": "⊘"][st.status] ?? "☐"
            let deps = (st.dependsOn ?? []).isEmpty ? "" : "  ← " + st.dependsOn!.joined(separator: ", ")
            s += "\(box) \(st.id) \(st.title)\(st.checkpoint ? "  ⟡ checkpoint" : "")\(st.parallel == true ? "  ∥ parallel" : "")\(deps)\n"
        }
        if let ds = decisions, !ds.isEmpty {
            s += "\n**User decisions**\n" + ds.map { "- \($0.line)" }.joined(separator: "\n") + "\n"
        }
        if let rv = reviews, !rv.isEmpty {
            s += "\n**Reviews**\n" + rv.map { "- \($0.id) \($0.subject.isEmpty ? "" : $0.subject + " ")→ \($0.decision.rawValue): \($0.next.truncated(120))" }.joined(separator: "\n") + "\n"
        }
        return s
    }
}

/// A decision the user made during the task, in their words (or the options they picked).
public struct UserDecision: Codable, Sendable, Equatable {
    public var at: Date
    /// What was decided: the question's header, or "brainstorm".
    public var topic: String
    public var answer: String
    /// Idea ids the decision chose, when its options came from ideas.
    public var ideas: [String]?
    /// The receipt of the answer, when there is one.
    public var receipt: String?

    public init(at: Date = Date(), topic: String, answer: String, ideas: [String]? = nil, receipt: String? = nil) {
        self.at = at; self.topic = topic; self.answer = answer; self.ideas = ideas; self.receipt = receipt
    }

    public var line: String {
        "\(topic.truncated(40)): \(answer.truncated(240))" + ((ideas ?? []).isEmpty ? "" : " [\((ideas ?? []).joined(separator: ", "))]")
            + (receipt.map { " (\($0))" } ?? "")
    }
}

/// Gate outcome. `refuse` text is returned to the model as the tool error, telling it what to do.
public enum GateDecision: Equatable, Sendable {
    case allow
    case refuse(String)
}

/// Owns the plan and the gates. Thread-safe; shared by tools and the supervisor.
public final class ResearchProtocol: @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var plan = ResearchPlan()
    public let ledger: EvidenceLedger
    /// Grounding can be relaxed for non-research chores (e.g. "rename this file"); the agent may
    /// not change this itself — only the user via settings or `/grounding off`.
    public var groundingRequired = true
    /// What the user's current message needs (`TurnScale`): a chat or quick task runs without the
    /// pre-registration gate; a plan written during it switches the protocol back on.
    private var _turnScale: TurnScale = .research
    private var _forcedScale: TurnScale?
    /// The mode the user named for their next message (`/lookup`, `/learn` …).
    public func forceNextScale(_ s: TurnScale) { lock.withLock { _forcedScale = s } }
    func takeForcedScale() -> TurnScale? { lock.withLock { defer { _forcedScale = nil }; return _forcedScale } }
    public var turnScale: TurnScale {
        get { lock.withLock { _turnScale } }
        set { lock.withLock { _turnScale = newValue } }
    }

    public static let webSearchTools: Set<String> = ["web_search"]
    /// `library_search` reads papers fetched (with receipts) in this workspace's earlier tasks.
    public static let literatureTools: Set<String> = ["literature_search", "paper_fetch", "paper_graph", "library_search"]
    public static let analysisTools: Set<String> = ["python", "bash"]

    /// `plan.json` in the task's state directory; nil = in memory only.
    let stateURL: URL?

    public init(ledger: EvidenceLedger, stateURL: URL? = nil) {
        self.ledger = ledger
        self.stateURL = stateURL
        if let p = StateFile.load(ResearchPlan.self, from: stateURL) { plan = p }
    }

    /// Call with the lock held, after every mutation.
    private func persist() { StateFile.save(plan, to: stateURL) }

    public var snapshot: ResearchPlan { lock.lock(); defer { lock.unlock() }; return plan }

    public func hasGrounding() -> (web: Bool, literature: Bool) {
        let rs = ledger.all.filter { $0.success }
        return (rs.contains { Self.webSearchTools.contains($0.tool) }, rs.contains { Self.literatureTools.contains($0.tool) })
    }

    /// The grounding gate. `action` names what is being attempted, for the refusal message.
    public func requireGrounding(_ action: String) -> GateDecision {
        guard groundingRequired else { return .allow }
        let g = hasGrounding()
        if g.web && g.literature { return .allow }
        var missing: [String] = []
        if !g.web { missing.append("`web_search` (international sources)") }
        if !g.literature { missing.append("`literature_search` / `paper_fetch`") }
        return .refuse("Search before \(action): this task has no successful \(missing.joined(separator: " or ")) yet. "
            + "Run the searches, read the relevant results, and cite them; do not rely on memory.")
    }

    /// The pre-registration gate: analysis (Python, scripts, background jobs) and writing files wait for
    /// a plan with hypotheses, steps and a checkpoint, so criteria are fixed before results exist and a
    /// deliverable never skips the plan. Reading and exploring stay open: files, searches and read-only
    /// shell commands. Off with the grounding gate.
    public static let gatedBeforePlan: Set<String> = analysisTools.union(["write_file", "edit_file"])

    public func requirePlan(tool: String, input: JSON) -> GateDecision {
        guard groundingRequired, turnScale == .research, Self.gatedBeforePlan.contains(tool) else { return .allow }
        if !snapshot.steps.isEmpty { return .allow }
        if tool == "bash", let cmd = input.str("command") ?? input.str("cmd"), Self.isReadOnlyShell(cmd) { return .allow }
        let g = hasGrounding()
        let next = g.web && g.literature
            ? "set the plan with `update_plan` (goal, hypotheses with predictions and falsification criteria, steps with success criteria)"
            : "search first (`web_search` and `literature_search` / `library_search`), then set the plan with `update_plan`"
        return .refuse("Pre-registration: no analysis or file writing before the plan (with at least one checkpoint step). Next: \(next). Until then, read and explore freely "
            + "(read_file, glob, grep, read-only shell such as ls, cat, head, sed -n, git log).")
    }

    /// Shell that only looks: every segment starts with an inspection command, nothing is redirected
    /// into a file, nothing is deleted or executed.
    static func isReadOnlyShell(_ cmd: String) -> Bool {
        let looks: Set<String> = ["ls", "cat", "head", "tail", "wc", "grep", "rg", "find", "file", "stat", "du", "df", "pwd", "echo",
                                  "which", "tree", "sort", "uniq", "cut", "less", "more", "md5", "shasum", "sha256sum", "basename",
                                  "dirname", "realpath", "printf", "date", "whoami", "uname", "env", "nproc", "sysctl", "column", "jq"]
        if cmd.range(of: #"(^|[^0-9&])>(?!\s*/dev/null)|`|\$\("#, options: .regularExpression) != nil { return false }
        let segments = cmd.components(separatedBy: CharacterSet(charactersIn: ";|&\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { seg in
            let words = seg.split(separator: " ").map(String.init)
            guard let w = words.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) else { return false }
            switch w {
            case "sed": return words.contains("-n") && !seg.contains(" -i")
            case "find": return !seg.contains("-exec") && !seg.contains("-delete") && !seg.contains("-ok")
            case "git": return ["status", "log", "diff", "show", "ls-files", "branch", "rev-parse", "blame"].contains(words.dropFirst().first ?? "")
            case "awk": return !seg.contains("system") && !seg.contains(">")
            default: return looks.contains(w)
            }
        }
    }

    // MARK: Plan mutations (called by the update_plan tool)

    public func setPlan(goal: String, background: String, hypotheses: [Hypothesis], steps: [PlanStep], rationale: String) -> (GateDecision, PlanRevision?) {
        if case .refuse(let m) = requireGrounding("planning") { return (.refuse(m), nil) }
        // Every plan gets at least one checkpoint, so the deliverable is always independently reviewed.
        var steps = steps
        if !steps.isEmpty, !steps.contains(where: \.checkpoint) { steps[steps.count - 1].checkpoint = true }
        lock.lock(); defer { lock.unlock() }
        _turnScale = .research   // a plan makes this research, whatever the message looked like
        let analysisDone = ledger.all.contains { Self.analysisTools.contains($0.tool) && $0.success }
        var changed: [String] = []
        for h in hypotheses {
            if let old = plan.hypotheses.first(where: { $0.id == h.id }),
               old.prediction != h.prediction || old.falsification != h.falsification || (old.onNegative ?? "") != (h.onNegative ?? "") { changed.append(h.id) }
        }
        for s in steps {
            if let old = plan.steps.first(where: { $0.id == s.id }), old.criteria != s.criteria || (old.onFailure ?? "") != (s.onFailure ?? "") { changed.append(s.id) }
        }
        // A hypothesis newly marked refuted or inconclusive is a result to look back at before going on.
        for h in hypotheses where ["refuted", "inconclusive"].contains(h.status) {
            if let old = plan.hypotheses.first(where: { $0.id == h.id }), old.status != h.status {
                requestReviewLocked(trigger: "\(h.id) marked \(h.status)", subject: h.id)
            }
        }
        let isFirst = plan.steps.isEmpty
        if !isFirst && rationale.trimmingCharacters(in: .whitespacesAndNewlines).count < 15 {
            return (.refuse("A plan revision needs a rationale (what changed and why)."), nil)
        }
        let rev = PlanRevision(at: Date(), rationale: isFirst ? "initial plan" : rationale, changedCriteria: changed,
                               afterResults: analysisDone && !changed.isEmpty)
        var hs = hypotheses
        // Hypotheses registered earlier (promoted ideas above all) stay registered when a plan update leaves them
        // out: pre-registration means a hypothesis is resolved by its status, never by disappearing.
        for old in plan.hypotheses where !hs.contains(where: { $0.id == old.id }) { hs.append(old) }
        for i in hs.indices {
            // Registration time is preserved across revisions; it is what makes pre-registration checkable.
            hs[i].registeredAt = plan.hypotheses.first { $0.id == hs[i].id }?.registeredAt ?? Date()
        }
        if (plan.objective ?? "").isEmpty {
            // Inside the lock already: read the stored value, not the locking accessor (NSLock is not re-entrant).
            let asked = _lastUserRequest.trimmingCharacters(in: .whitespacesAndNewlines)
            plan.objective = (asked.isEmpty ? goal : asked).truncated(1200)
        }
        plan.goal = goal.isEmpty ? plan.goal : goal
        plan.background = background.isEmpty ? plan.background : background
        plan.hypotheses = hs
        plan.steps = steps
        plan.revisions.append(rev)
        if plan.stage.rawValue == ResearchStage.scoping.rawValue || plan.stage == .background { plan.stage = .planning }
        persist()
        return (.allow, rev)
    }

    /// Marks a step's status. Returns the step if it is a checkpoint that was just completed.
    public func updateStep(id: String, status: String, evidence: [String], note: String) -> (GateDecision, PlanStep?) {
        lock.lock(); defer { lock.unlock() }
        guard let i = plan.steps.firstIndex(where: { $0.id == id }) else { return (.refuse("No plan step \(id)."), nil) }
        if status == "done" {
            // A completion is a report; receipts are proof. Each cited receipt must exist and succeed.
            let bad = evidence.filter { ledger.receipt($0)?.success != true }
            if evidence.isEmpty && plan.steps[i].checkpoint {
                return (.refuse("Checkpoint \(id) needs evidence: cite the receipt ids (e.g. r12) of the tool calls that produced its result."), nil)
            }
            if !bad.isEmpty {
                return (.refuse("Receipts \(bad.joined(separator: ", ")) do not exist or did not succeed. Cite successful receipts: \(ledger.all.suffix(8).filter(\.success).map(\.id).joined(separator: ", "))"), nil)
            }
        }
        let was = plan.steps[i].status
        plan.steps[i].status = status
        plan.steps[i].evidence = evidence
        plan.steps[i].note = note
        if status == "failed" && was != "failed" { requestReviewLocked(trigger: "\(id) failed", subject: id) }
        if status == "done", ledger.all.contains(where: { Self.analysisTools.contains($0.tool) }) { plan.stage = .analysis }
        else if status == "in_progress" { plan.stage = .execution }
        persist()
        return (.allow, plan.steps[i].checkpoint && status == "done" ? plan.steps[i] : nil)
    }

    /// Registers one hypothesis (an idea promoted after its novelty check and review) without
    /// touching the rest of the plan. Recorded as a plan revision with its rationale.
    public func addHypothesis(statement: String, prediction: String, falsification: String, rationale: String) -> (GateDecision, Hypothesis?) {
        if case .refuse(let m) = requireGrounding("registering a hypothesis") { return (.refuse(m), nil) }
        guard !prediction.isEmpty, !falsification.isEmpty else { return (.refuse("A hypothesis needs a prediction and a falsification criterion."), nil) }
        lock.lock(); defer { lock.unlock() }
        var n = plan.hypotheses.count + 1
        while plan.hypotheses.contains(where: { $0.id == "H\(n)" }) { n += 1 }
        let h = Hypothesis(id: "H\(n)", statement: statement, prediction: prediction, falsification: falsification, status: "open", registeredAt: Date())
        plan.hypotheses.append(h)
        plan.revisions.append(PlanRevision(at: Date(), rationale: rationale, changedCriteria: [], afterResults: false))
        persist()
        return (.allow, h)
    }

    public func setStage(_ s: ResearchStage) { lock.lock(); plan.stage = s; persist(); lock.unlock() }

    public func setHypothesisStatus(_ id: String, _ status: String) {
        lock.lock(); defer { lock.unlock() }
        if let i = plan.hypotheses.firstIndex(where: { $0.id == id }) {
            let was = plan.hypotheses[i].status
            plan.hypotheses[i].status = status
            if ["refuted", "inconclusive"].contains(status) && was != status { requestReviewLocked(trigger: "\(id) marked \(status)", subject: id) }
            persist()
        }
    }

    // MARK: Changing course (result reviews)

    /// The user's latest research request, in their words (set by the main agent each turn): it becomes
    /// the fixed objective when the first plan is written.
    private var _lastUserRequest = ""
    public var lastUserRequest: String {
        get { lock.withLock { _lastUserRequest } }
        set { lock.withLock { _lastUserRequest = newValue } }
    }

    /// A user message as it arrives. The first one that asks for research work becomes the task's fixed
    /// objective right away ("the original task decides"); later replies ("ok, go with option 2") never
    /// replace it.
    public func recordUserRequest(_ text: String, scale: TurnScale) {
        lock.lock(); defer { lock.unlock() }
        _lastUserRequest = text
        guard (plan.objective ?? "").isEmpty, scale == .research || scale == .unclear else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        plan.objective = t.truncated(1200)
        persist()
    }
    /// The review request not yet shown to the model (shown once, then the gate and context remind).
    private var unannounced: PendingReview?

    public var pendingReview: PendingReview? { lock.withLock { plan.pendingReview } }
    public var reviews: [ResultReview] { lock.withLock { plan.reviews ?? [] } }
    public var objective: String? { lock.withLock { plan.objective } }

    /// Asks for a look back before analysis goes on (a result went against the plan).
    public func requestReview(trigger: String, subject: String) {
        lock.lock(); defer { lock.unlock() }
        requestReviewLocked(trigger: trigger, subject: subject)
        persist()
    }

    private func requestReviewLocked(trigger: String, subject: String) {
        guard plan.pendingReview == nil, !plan.steps.isEmpty || !plan.hypotheses.isEmpty else { return }
        let p = PendingReview(trigger: trigger, subject: subject)
        plan.pendingReview = p
        unannounced = p
    }

    /// Three failed analysis runs in a row since the last review: the route is stuck.
    public func checkStall() {
        lock.lock(); defer { lock.unlock() }
        guard plan.pendingReview == nil else { return }
        let runs = ledger.all.dropFirst(plan.reviewMark ?? 0).filter { Self.analysisTools.contains($0.tool) }
        guard runs.count >= 3, runs.suffix(3).allSatisfy({ !$0.success }) else { return }
        requestReviewLocked(trigger: "three failed runs in a row", subject: plan.steps.first { $0.status == "in_progress" }?.id ?? "")
        persist()
    }

    /// The note the model sees once, right after the result that needs a review.
    public func takeReviewNotice() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let p = unannounced else { return nil }
        unannounced = nil
        return "<result_review_needed>\(p.trigger). Before more analysis, look back with `result_review`: expected vs observed, "
            + "likely causes, the check that tells them apart, and the decision (repair · adjust · pivot · stop · ask).</result_review_needed>"
    }

    /// Tools that wait for a pending review: analysis, file writes, workers and claims.
    public static let gatedByReview: Set<String> = gatedBeforePlan.union(["task", "dispatch", "claim_finding"])

    public func requireReview(tool: String, input: JSON) -> GateDecision {
        guard let p = pendingReview, Self.gatedByReview.contains(tool) else { return .allow }
        if tool == "bash", let cmd = input.str("command") ?? input.str("cmd"), Self.isReadOnlyShell(cmd) { return .allow }
        return .refuse("Result review first (\(p.trigger)): record it with `result_review` — expected vs observed, likely causes, "
            + "how to tell them apart, and the decision — before running more analysis, writing files or starting workers. "
            + "Reading and read-only shell stay open.")
    }

    /// Records a review. The host checks what it can: the receipts exist, the reasoning is filled in,
    /// a repair is not tried a fourth time on the same thing, and a pivot names where it goes.
    public func addReview(_ r: ResultReview, ideaExists: (String) -> Bool) -> (GateDecision, ResultReview?) {
        lock.lock(); defer { lock.unlock() }
        var r = r
        let missing = [("expected", r.expected), ("observed", r.observed), ("serves_objective", r.servesObjective), ("next", r.next)]
            .filter { $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.0)
        if !missing.isEmpty { return (.refuse("A review needs: \(missing.joined(separator: ", "))."), nil) }
        if r.causes.isEmpty && r.decision != .stop { return (.refuse("Name the likely causes, most likely first."), nil) }
        let bad = r.receipts.filter { ledger.receipt($0) == nil }
        if !bad.isEmpty { return (.refuse("Receipts \(bad.joined(separator: ", ")) do not exist; cite the runs that show the result."), nil) }
        let past = plan.reviews ?? []
        // Bounded repair (AIDE's max_debug_depth): three per item, and three for unnamed ones, so a stuck
        // route cannot be "repaired" forever.
        if r.decision == .repair, past.filter({ $0.subject == r.subject && $0.decision == .repair }).count >= 3 {
            return (.refuse("\(r.subject.isEmpty ? "This" : r.subject) has been repaired three times already. Escalate: adjust, pivot, stop or ask the user."), nil)
        }
        if r.decision == .pivot {
            let alt = (r.alternative ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if alt.isEmpty { return (.refuse("A pivot names where it goes: an idea id from the pool (`idea` list) or \"brainstorm\"."), nil) }
            if alt != "brainstorm" && !ideaExists(alt) { return (.refuse("No live idea \(alt) in the pool. Name another, or \"brainstorm\"."), nil) }
        }
        // A decision is "by the rule" only when the subject has a rule written before.
        if r.followsRule {
            let rule = plan.hypotheses.first { $0.id == r.subject }?.onNegative ?? plan.steps.first { $0.id == r.subject }?.onFailure
            if (rule ?? "").isEmpty { r.followsRule = false }
        }
        r.id = "RV\(past.count + 1)"
        r.at = Date()
        if r.trigger.isEmpty { r.trigger = plan.pendingReview?.trigger ?? "review" }
        plan.reviews = past + [r]
        plan.pendingReview = nil
        unannounced = nil
        plan.reviewMark = ledger.count
        persist()
        return (.allow, r)
    }

    // MARK: User decisions

    /// Kept in full on disk; the context shows the last few.
    public static let decisionsShown = 5

    public var decisions: [UserDecision] { lock.withLock { plan.decisions ?? [] } }

    /// Records what the user decided. A new decision also resets the count of idea reviews that did not pass.
    public func recordDecision(_ d: UserDecision) {
        let a = d.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var d = d
        d.answer = a.truncated(1200)
        plan.decisions = (plan.decisions ?? []) + [d]
        plan.ideaReviewsSinceDecision = 0
        persist()
    }

    /// Counts an idea review that did not pass; returns how many there were since the user last decided.
    @discardableResult
    public func noteIdeaReviewFailed() -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = (plan.ideaReviewsSinceDecision ?? 0) + 1
        plan.ideaReviewsSinceDecision = n
        persist()
        return n
    }

    /// The task's anchor in a few lines: the objective in the user's words, what they decided since, and
    /// where the plan stands. Recited in the turn context, in long tool loops, after compaction and when
    /// the agent asks about the goal — wherever a long task could otherwise lose its thread.
    public func compass(lastRequest: String? = nil) -> [String] {
        let p = snapshot
        var lines: [String] = []
        if let o = p.objective, !o.isEmpty { lines.append("objective (the user's request; fixed): " + o.truncated(400)) }
        let ds = (p.decisions ?? []).suffix(Self.decisionsShown)
        if !ds.isEmpty { lines.append("the user decided: " + ds.map(\.line).joined(separator: " | ")) }
        if let r = lastRequest?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty, r != p.objective {
            lines.append("the user's latest message: " + r.truncated(300))
        }
        if !p.steps.isEmpty {
            let done = p.steps.filter { $0.status == "done" }.count
            let current = p.steps.first { $0.status == "in_progress" }?.title ?? p.steps.first { $0.status == "pending" }?.title ?? "-"
            lines.append("plan: \(done)/\(p.steps.count) steps done; current: \(current)")
        }
        return lines
    }

    /// Changes the task's objective; only with the user's own words (checked by the caller).
    public func changeObjective(_ text: String) {
        lock.lock(); plan.objective = text.truncated(1200); persist(); lock.unlock()
    }

    public func restore(_ p: ResearchPlan) { lock.lock(); plan = p; persist(); lock.unlock() }
}
