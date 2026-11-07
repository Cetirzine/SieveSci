import Foundation

/// `result_review`: the look back after a result that went against the plan (a failed step, a refuted
/// or inconclusive hypothesis, a claim that did not hold, a stuck route, a reviewer's pivot or stop).
/// The host asks for it and holds analysis until it is recorded; the agent writes it itself, in the
/// same turn, so it costs no extra model call.
struct ResultReviewTool: Tool {
    let name = "result_review"
    let description = """
    Look back at a result that went against the plan, then decide how to go on. Required by the host \
    after a failed step, a refuted or inconclusive hypothesis or claim, three failed runs in a row, or a \
    reviewer suggesting pivot/stop; analysis waits until it is recorded. Give: what you expected and what \
    you observed (cite receipts), the likely causes ranked (a bug or the environment, the data, an \
    assumption, the hypothesis itself), the check that tells the leading cause apart, and one decision: \
    repair (fix and rerun; at most three times per item), adjust (another method for the same question — \
    then revise the plan), pivot (this route cannot reach the objective — name an idea from the pool or \
    "brainstorm" for a focused re-brainstorm), stop (the negative result answers the question — report it \
    with why), ask (the way forward changes the objective, scope or cost — ask the user). Every decision \
    must still serve the task's fixed objective. Never choose a route because it is more likely to give \
    the hoped-for answer; changing analysis until the data agree is not a pivot.
    """
    var inputSchema: JSON {
        Schema.object([
            "subject": Schema.string("The plan item: H1, S3, C2 (empty if none)"),
            "expected": Schema.string("What the plan predicted"),
            "observed": Schema.string("What happened, with the numbers"),
            "causes": Schema.array("Likely causes, most likely first", items: ["type": "string"]),
            "check": Schema.string("How the leading cause was or will be told apart from the others"),
            "decision": Schema.stringEnum("How to go on", ReviewDecision.allCases.map(\.rawValue)),
            "follows_rule": Schema.bool("The decision is the subject's pre-registered on_negative / on_failure rule"),
            "serves_objective": Schema.string("How this still serves the task's fixed objective"),
            "next": Schema.string("The new high-level plan for what comes next"),
            "alternative": Schema.string("pivot: an idea id from the pool, or \"brainstorm\""),
            "receipts": Schema.array("Receipt ids that show the result", items: ["type": "string"]),
        ], required: ["decision", "expected", "next", "observed", "serves_objective"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func runsConcurrently(for input: JSON) -> Bool { false }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard ctx.role == .main else { return .error("Only the main agent reviews results; report the problem in your result instead.") }
        guard let decision = input.str("decision").flatMap(ReviewDecision.init(rawValue:)) else {
            return .error("decision must be one of: " + ReviewDecision.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let s = ctx.services
        let rp = s.research
        let pending = rp.pendingReview
        let review = ResultReview(
            id: "", at: Date(), trigger: pending?.trigger ?? "", subject: input.str("subject") ?? pending?.subject ?? "",
            expected: input.str("expected") ?? "", observed: input.str("observed") ?? "",
            causes: input["causes"]?.arrayValue?.compactMap(\.stringValue).filter { !$0.isEmpty } ?? [],
            check: input.str("check") ?? "", decision: decision, followsRule: input.bool("follows_rule") ?? false,
            servesObjective: input.str("serves_objective") ?? "", next: input.str("next") ?? "",
            receipts: input["receipts"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            alternative: input.str("alternative"))
        let live = Set(s.ideas.snapshot.filter(\.isLive).map(\.id))
        let (d, saved) = rp.addReview(review, ideaExists: { live.contains($0) })
        if case .refuse(let m) = d { return .error(m) }
        guard let r = saved else { return .error("The review was not recorded.") }
        s.log("result_review", actor: "main", ["id": .string(r.id), "trigger": .string(r.trigger), "subject": .string(r.subject),
                                               "decision": .string(r.decision.rawValue), "follows_rule": .bool(r.followsRule),
                                               "causes": .array(r.causes.map { .string($0) }), "receipts": .array(r.receipts.map { .string($0) })])
        s.emit(.planChanged(rp.snapshot))
        // What comes next, briefly: each decision has one way forward.
        let then: String = switch r.decision {
        case .repair: "Fix it and rerun; the plan stays. (Repairs on \(r.subject.isEmpty ? "this" : r.subject) so far: \(rp.reviews.filter { $0.subject == r.subject && $0.decision == .repair }.count) of 3.)"
        case .adjust: "Revise the plan with `update_plan` set (rationale: \(r.id))\(r.followsRule ? "; this follows the rule written in advance." : "; changed criteria are recorded as a deviation and the analysis is exploratory.")"
        case .pivot: r.alternative == "brainstorm"
            ? "Start a focused re-brainstorm: `brainstorm` start with after_review \(r.id) (the task's searches count; at least 4 ideas built on what this review learned)."
            : "Take idea \(r.alternative ?? "") from the pool: register it (`idea` promote after its checks), then revise the plan."
        case .stop: "Report the negative result as the answer: what was expected, what was found, why — and mark the hypothesis or step accordingly."
        case .ask: "Ask the user with `ask_user` (the options and what each costs). Do not change the objective without their words."
        }
        return ToolOutput("Review \(r.id) recorded (\(r.decision.rawValue)\(r.followsRule ? ", by the rule written in advance" : "")). \(then)",
                          facts: ["review": .string(r.id), "decision": .string(r.decision.rawValue)])
    }
}
