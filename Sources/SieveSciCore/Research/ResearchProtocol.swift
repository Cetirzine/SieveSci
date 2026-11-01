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

    public init(goal: String = "") {
        self.goal = goal
        background = ""
        hypotheses = []
        steps = []
        revisions = []
        stage = .scoping
    }

    public var markdown: String {
        var s = "**Goal:** \(goal)\n"
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
        return s
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
        guard groundingRequired, Self.gatedBeforePlan.contains(tool) else { return .allow }
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
        let analysisDone = ledger.all.contains { Self.analysisTools.contains($0.tool) && $0.success }
        var changed: [String] = []
        for h in hypotheses {
            if let old = plan.hypotheses.first(where: { $0.id == h.id }),
               old.prediction != h.prediction || old.falsification != h.falsification { changed.append(h.id) }
        }
        for s in steps {
            if let old = plan.steps.first(where: { $0.id == s.id }), old.criteria != s.criteria { changed.append(s.id) }
        }
        let isFirst = plan.steps.isEmpty
        if !isFirst && rationale.trimmingCharacters(in: .whitespacesAndNewlines).count < 15 {
            return (.refuse("A plan revision needs a rationale (what changed and why)."), nil)
        }
        let rev = PlanRevision(at: Date(), rationale: isFirst ? "initial plan" : rationale, changedCriteria: changed,
                               afterResults: analysisDone && !changed.isEmpty)
        var hs = hypotheses
        for i in hs.indices {
            // Registration time is preserved across revisions; it is what makes pre-registration checkable.
            hs[i].registeredAt = plan.hypotheses.first { $0.id == hs[i].id }?.registeredAt ?? Date()
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
        plan.steps[i].status = status
        plan.steps[i].evidence = evidence
        plan.steps[i].note = note
        if status == "done", ledger.all.contains(where: { Self.analysisTools.contains($0.tool) }) { plan.stage = .analysis }
        else if status == "in_progress" { plan.stage = .execution }
        persist()
        return (.allow, plan.steps[i].checkpoint && status == "done" ? plan.steps[i] : nil)
    }

    public func setStage(_ s: ResearchStage) { lock.lock(); plan.stage = s; persist(); lock.unlock() }

    public func setHypothesisStatus(_ id: String, _ status: String) {
        lock.lock(); defer { lock.unlock() }
        if let i = plan.hypotheses.firstIndex(where: { $0.id == id }) { plan.hypotheses[i].status = status; persist() }
    }

    public func restore(_ p: ResearchPlan) { lock.lock(); plan = p; persist(); lock.unlock() }
}
