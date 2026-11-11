import Foundation

// MARK: - ask_user

struct AskUserTool: Tool {
    let name = "ask_user"
    let description = """
    Ask the user what only they can supply: a choice between real alternatives (scope, organism, data, method \
    family, which direction to pursue) or a value the request never gave. Not for anything a search, a file or a \
    tool can answer, and not for permission. 1–4 questions per call; each has a short `header` (≤12 characters), \
    the `question`, a `kind` (single | multi | text = fill-in) and, for choices, 2–5 `options` (label, optional \
    description, evidence [@key or receipt ids], `recommended` on at most one). "Other" with a text box is added \
    automatically — do not list it. `reason`: user_decision | missing_value | direction (directions found by \
    searching and brainstorming; needs the background searches first). Calling this ends your step: other tool \
    calls in the same message do not run. The result is the user's answer, or that they dismissed the question \
    (then stop and wait), or that nobody could answer (then do not choose for them).
    """
    var inputSchema: JSON {
        let option = Schema.object(["label": Schema.string("Concise choice text"),
                                    "description": Schema.string("One line: what choosing this means"),
                                    "evidence": Schema.array("Library keys (@key) or receipt ids this option rests on", items: ["type": "string"]),
                                    "recommended": Schema.bool("Your recommendation (at most one)"),
                                    "idea": Schema.string("Idea id (I3) this option came from")], required: ["label"])
        let question = Schema.object(["id": Schema.string("Short id (optional)"),
                                      "header": Schema.string("Tab label, ≤12 characters"),
                                      "question": Schema.string("The full question"),
                                      "kind": Schema.stringEnum("single | multi | text", ["single", "multi", "text"]),
                                      "reason": Schema.stringEnum("Why only the user can answer", ["user_decision", "missing_value", "direction"]),
                                      "options": Schema.array("2–5 choices (none for text)", items: option),
                                      "allow_other": Schema.bool("Offer \"Other\" with a text box (default true)"),
                                      "placeholder": Schema.string("Hint for the text box"),
                                      "optional": Schema.bool("May be left unanswered")],
                                     required: ["header", "kind", "question"])
        return Schema.object(["questions": Schema.array("1–4 questions asked together", items: question)], required: ["questions"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func runsConcurrently(for input: JSON) -> Bool { false }   // changes session state; runs in order

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard ctx.role == .main else { return .error("Only the main agent asks the user; report the open question in your result instead.") }
        let s = ctx.services
        let questions = try AskFormat.parse(input)
        // An agent that lost its thread (a long turn, a thin compaction) asks the user what the task is. The
        // task is on record: hand it back instead of putting the question to the user.
        if let o = s.research.objective, !o.isEmpty, let q = questions.first(where: { $0.kind == .text && Self.asksForTheTask($0.question) }) {
            s.log("ask_refused", actor: "host", ["question": .string(q.question.truncated(300)), "reason": "task on record"])
            return .error("The task is on record — do not ask the user for it:\n" + s.research.compass(lastRequest: s.research.lastUserRequest).joined(separator: "\n")
                + "\nContinue from the plan, the ideas and the receipts. Ask only for a specific value or decision this task still needs.")
        }
        if questions.contains(where: { $0.reason == .direction }),
           case .refuse(let m) = s.research.requireGrounding("asking the user to choose a research direction") {
            return .error(m + " Options for a direction must rest on what the searches found.")
        }
        // The choice at the end of a brainstorm is the step that leads to the plan; it is not a pre-plan detour.
        if s.research.snapshot.steps.isEmpty, s.ideas.live == nil {
            if s.asks.askedBeforePlan >= AskCenter.maxBeforePlan {
                return .error("You have asked \(AskCenter.maxBeforePlan) times before planning. Proceed with what you have: state your assumptions and plan.")
            }
            s.asks.noteAskedBeforePlan()
        }
        let req = AskRequest(id: CurrentToolCall.id ?? UUID().uuidString, agentId: ctx.sessionId, questions: questions)
        s.log("ask", actor: "agent", ["id": .string(req.id), "questions": .array(questions.map { q in
            ["id": .string(q.id), "header": .string(q.header), "kind": .string(q.kind.rawValue), "reason": .string(q.reason.rawValue),
             "question": .string(q.question), "options": .array(q.options.map { .string($0.label) })]
        })])
        let goalWasActive = s.goal.current?.phase == .active
        if goalWasActive { s.goal.hostWait(req.summary) }
        let outcome = await s.asks.ask(req, emit: s.emit)
        if case .answered = outcome, goalWasActive { s.goal.userReplied() }
        if case .answered(let answers) = outcome { Self.recordDecisions(req, answers, s) }
        s.log("ask_answer", actor: outcome == .unavailable ? "host" : "user", ["id": .string(req.id), "outcome": .string(outcome.label),
                                                                             "answer": (try? JSONCodec.parse(JSONEncoder().encode(outcome))) ?? .null])
        s.emit(.askResolved(id: req.id, outcome: outcome))
        return ToolOutput(AskFormat.result(req, outcome), facts: ["ask": .string(req.id), "outcome": .string(outcome.label)])
    }

    /// "What would you like me to work on?" and its kin, in English and Chinese.
    static func asksForTheTask(_ question: String) -> Bool {
        let q = question.lowercased()
        let patterns = [#"\bwhat\b[^?]{0,40}\b(question|task|topic|problem)s?\b[^?]{0,20}\b(would|do|should|shall) you\b"#,
                        #"would you like (me )?to (work on|do|research|study)\b"#,
                        #"what (should|shall) i (work on|do|research)"#,
                        #"(你|您)(想|要|希望)(让)?我(做|研究|处理|完成)什么"#,
                        #"(什么|哪个)(任务|研究问题|课题)"#]
        return patterns.contains { q.range(of: $0, options: .regularExpression) != nil }
    }

    /// Every answer is a user decision; it is kept with the plan so later steps (and a compacted context) still see it.
    static func recordDecisions(_ req: AskRequest, _ answers: [AskAnswer], _ s: SessionServices) {
        let by = Dictionary(answers.map { ($0.questionId, $0) }, uniquingKeysWith: { a, _ in a })
        for q in req.questions {
            guard let a = by[q.id], !a.isEmpty else { continue }
            var parts = a.selected
            if let o = a.other?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty { parts.append("other: \"\(o)\"") }
            if let t = a.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { parts.append("\"\(t)\"") }
            let ideas = q.options.filter { a.selected.contains($0.label) }.compactMap(\.idea)
            s.research.recordDecision(UserDecision(topic: q.header.isEmpty ? q.question : q.header, answer: parts.joined(separator: "; "),
                                                   ideas: ideas.isEmpty ? nil : ideas))
        }
        s.emit(.planChanged(s.research.snapshot))
    }
}

// MARK: - brainstorm

struct BrainstormTool: Tool {
    let name = "brainstorm"
    let description = """
    Enter, advance and leave brainstorming mode, which the user watches live. Enter it on your own when the work \
    needs new ideas (the request asks for them, a direction is unclear, an approach keeps failing, a claim was \
    refuted) — unless the user turned that off, in which case `start` is refused. Actions: start (topic, reason, \
    goal) · stage (stage: ground | diverge | dedupe | rank | novelty (or evidence) | review | evolve | report; note: \
    one line on what you are doing) · end (summary). goal is the user's answer to "is novelty required?": novel — \
    new ideas, checked for novelty against prior work; proven — what works best, where methods with published good \
    results are preferred and the field's best answers are combined (stage evidence replaces novelty). Ask the user \
    once with `ask_user` before starting unless they already said. Stages run in this order and the host refuses a skipped stage or one whose work is \
    not done (review and evolve are optional). While a brainstorm is live there is no planning, no workers \
    (`task`, `dispatch`), no analysis and no file writing: those come after `end`, built on the ideas the user \
    chose. Record ideas with `idea`; follow the `brainstorm` skill for the procedure.
    """
    var inputSchema: JSON {
        Schema.object(["action": Schema.stringEnum("start | stage | end", ["start", "stage", "end"]),
                       "topic": Schema.string("start: what the ideas are for"),
                       "reason": Schema.string("start: why new ideas are needed now"),
                       "goal": Schema.stringEnum("start: novel (novelty required) or proven (what works best)", ["novel", "proven"]),
                       "stage": Schema.stringEnum("stage: the step you are entering", BrainstormState.allStages),
                       "note": Schema.string("stage: one line the user sees"),
                       "summary": Schema.string("end: what came out, in two lines"),
                       "after_review": Schema.string("start: the result review (RV…) whose pivot asked for this focused re-brainstorm")], required: ["action"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func runsConcurrently(for input: JSON) -> Bool { false }   // changes session state; runs in order

    /// Grounding counts as done when the searches the session requires have succeeded (one kind when the gate is off).
    static func grounded(_ ctx: ToolContext) -> Bool {
        let g = ctx.services.research.hasGrounding()
        return ctx.services.research.groundingRequired ? (g.web && g.literature) : (g.web || g.literature)
    }

    /// One line per stage, returned when it is entered, so the procedure is in front of the model at every step.
    static let stageGuide: [String: String] = [
        "ground": "Search (`web_search`, `literature_search`), fetch the 5–10 papers that matter, write the evidence brief.",
        "diverge": "Generate 12–24 ideas yourself with several operators (facet, analogy, invert, seed, verbalized); record each batch with `idea` add.",
        "dedupe": "Merge ideas that say the same thing (`idea` discard with \"duplicate of In\").",
        "rank": "Compare the live ideas pairwise yourself and record the order with `idea` rank.",
        "novelty": "For the top third: ≥3 searches each, read the closest papers, record `idea` novelty.",
        "evidence": "For the top third: ≥3 searches each for published results (benchmarks, comparisons, reviews, wide use), "
            + "read them, record `idea` evidence with the results and their numbers.",
        "review": "Name the recurring weaknesses of the survivors.",
        "evolve": "Add improved versions as new ideas (operator evolve:<id>); go back to rank for one more round, or on to report.",
        "report": "Present the top ideas as speculation (what each builds on, how it was checked, what is unchecked), then `ask_user` "
            + "(kind multi, reason direction, one option per idea). After the answer, call `brainstorm` end; planning starts after that.",
    ]

    /// The stages that differ when the goal is what works best: collect the field's proven answers, rank by
    /// reported results, and assemble the best-supported ones into one recommended approach.
    static let provenGuide: [String: String] = [
        "diverge": "Collect 12–24 candidates the field has shown to work: methods with published results, widely used tools, "
            + "benchmark leaders, and combinations of their strongest parts (operator survey or merge). Record each batch with `idea` add, "
            + "citing the work it comes from in `evidence`.",
        "rank": "Compare the live candidates pairwise on reported performance on comparable problems, robustness, maturity of the "
            + "tools and fit to this data; record the order with `idea` rank.",
        "report": "Assemble the best-supported candidates into one recommended approach — the field's best answer for this problem, "
            + "each part with its published results — plus the main alternatives. Then `ask_user` (kind multi, reason direction, your "
            + "recommendation first). After the answer, call `brainstorm` end; planning starts after that.",
    ]

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard ctx.role == .main else { return .error("Only the main agent runs a brainstorm; return your ideas in your report.") }
        let led = ctx.services.ideas
        switch input.str("action") {
        case "start":
            let topic = (input.str("topic") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topic.isEmpty else { return .error("Give the brainstorm a topic.") }
            let goal = input.str("goal").flatMap(BrainstormState.Goal.init(rawValue:))
            // A focused re-brainstorm follows a review that chose to pivot to new ideas.
            var after: String?
            if let rv = input.str("after_review"), !rv.isEmpty {
                guard let r = ctx.services.research.reviews.first(where: { $0.id == rv }), r.decision == .pivot, r.alternative == "brainstorm" else {
                    return .error("\(rv) is not a review that chose to pivot to a brainstorm.")
                }
                after = rv
            }
            switch led.start(topic: topic, reason: input.str("reason") ?? "", goal: goal, afterReview: after) {
            case .failure(let r): return .error(r.message)
            case .success(let st):
                ctx.services.log("brainstorm", actor: st.trigger == .auto ? "agent" : "user",
                                 ["event": "start", "id": .string(st.id), "topic": .string(topic), "trigger": .string(st.trigger.rawValue),
                                  "goal": .string(st.goal?.rawValue ?? "novel")])
                ctx.services.emit(.brainstormChanged(st))
                let g = ctx.services.research.hasGrounding()
                let aim = st.goal == .proven
                    ? "Goal: what works best — prior work with good published results is preferred; the check is stage evidence; "
                        + "the report assembles the field's best answers into one recommended approach. "
                    : "Goal: new ideas — each top idea is checked for novelty against prior work. "
                return ToolOutput("Brainstorm \(st.id) started (\(st.trigger.rawValue)); stage: ground. " + aim
                    + "The user sees each stage and every idea as you record it, "
                    + "and may ask you to wrap up. Ideas are speculation until checked. Until `brainstorm` end: no `update_plan`, no workers, "
                    + "no analysis or file writing — do every stage yourself, in order."
                    + (g.web && g.literature ? "" : " Ground first: search the background before generating anything."))
            }
        case "stage":
            let stage = input.str("stage") ?? ""
            guard BrainstormState.allStages.contains(stage) else { return .error("Unknown stage \(stage).") }
            guard let running = led.live else { return .error("No brainstorm is running; start one first.") }
            if let why = led.stageBlocker(stage, grounded: Self.grounded(ctx)) {
                ctx.services.log("brainstorm_gate", actor: "host", ["stage": .string(stage), "reason": .string(why)])
                return .error("Not moved to \(stage): " + why)
            }
            guard let st = led.stage(stage, note: input.str("note") ?? "") else { return .error("No brainstorm is running; start one first.") }
            ctx.services.emit(.brainstormChanged(st))
            let guide = running.goal == .proven ? (Self.provenGuide[stage] ?? Self.stageGuide[stage]) : Self.stageGuide[stage]
            return ToolOutput("Stage: \(stage). " + (guide ?? ""))
        case "end":
            if let c = led.live, c.stage != "report", !c.wrapUpRequested {
                return .error("The brainstorm is in \(c.stage); it ends from the report stage. Finish the remaining stages "
                    + "(\(c.order.joined(separator: " → "))), then report and let the user choose before ending. "
                    + "If the user wants to cut it short, they press Wrap up (straight to report) or Stop in the brainstorm panel; tell them so.")
            }
            guard let st = led.end(summary: input.str("summary") ?? "") else { return .error("No brainstorm is running.") }
            ctx.services.log("brainstorm", actor: "agent", ["event": "end", "id": .string(st.id), "summary": .string(st.summary ?? "")])
            ctx.services.emit(.brainstormChanged(st))
            // The outcome is where the work goes from here: kept beside the objective for the rest of the task.
            if st.trigger != .dream, let sum = st.summary, !sum.isEmpty {
                ctx.services.research.recordDecision(UserDecision(topic: "brainstorm outcome", answer: sum))
                ctx.services.emit(.planChanged(ctx.services.research.snapshot))
            }
            var text = "Brainstorm ended. Next, in this order: (1) if the user chose ideas, `idea` promote each one (independent review); "
                + "(2) set or revise the plan with `update_plan` around the promoted hypotheses — steps that test them, `parallel: true` "
                + "where a step needs no other step's results; (3) do the work, with workers where the plan allows. "
                + "If nobody chose, present the ideas as speculation and wait."
            if st.trigger == .dream {
                let ws = ctx.services.workspace
                let mine = led.snapshot.filter { $0.origin == "dream:\(st.id)" && $0.isLive }
                DreamInbox.add(mine, task: ctx.services.taskId, workspace: ws)
                let diary = DreamInbox.writeDiary(st, ideas: mine, workspace: ws)
                text += " Dream diary: \(diary.path)"
            }
            return ToolOutput(text)
        default:
            return .error("action must be start, stage or end")
        }
    }
}

// MARK: - idea

struct IdeaTool: Tool {
    let name = "idea"
    let description = """
    The idea ledger (speculation, kept apart from hypotheses and claims). Actions: add (ideas: [{statement, \
    mechanism, test, falsifier, operator, seeds, evidence}]; near-duplicates are merged automatically) · list · \
    discard (id, reason) · rank (order: ids best first, e.g. from `dispatch` rank) · novelty (id, verdict: \
    not_found_in_search | incremental | known, closest_prior: [@key…], receipts: ids of ≥3 searches run after the \
    idea was written) · evidence (in a brainstorm after what works best, instead of novelty: id, support: \
    established | partial | unproven, results: [@key or URL with the reported numbers], receipts: ids of ≥3 searches) \
    · promote (id, prediction): an independent checker reviews the check, then the idea is registered as a \
    hypothesis in the plan. Never call an idea novel: say "no prior work found in these searches".
    """
    var inputSchema: JSON {
        let idea = Schema.object(["statement": Schema.string("The idea in one or two sentences"),
                                  "mechanism": Schema.string("How it would work"),
                                  "test": Schema.string("The experiment or analysis that tests it"),
                                  "falsifier": Schema.string("The result that would refute it"),
                                  "operator": Schema.string("facet | analogy | invert | seed | verbalized | merge | evolve:<id> | free"),
                                  "seeds": Schema.array("Seed concepts used", items: ["type": "string"]),
                                  "evidence": Schema.array("[@key] or receipt ids it builds on", items: ["type": "string"])],
                                 required: ["statement"])
        return Schema.object(["action": Schema.stringEnum("Action", ["add", "list", "discard", "rank", "novelty", "evidence", "promote"]),
                              "support": Schema.stringEnum("evidence: how well published results back it", ["established", "partial", "unproven"]),
                              "results": Schema.array("evidence: the published results ([@key] or URL, with numbers)", items: ["type": "string"]),
                              "ideas": Schema.array("add: new ideas", items: idea),
                              "id": Schema.string("Idea id (I3)"),
                              "reason": Schema.string("discard: why"),
                              "order": Schema.array("rank: idea ids, best first", items: ["type": "string"]),
                              "verdict": Schema.stringEnum("novelty verdict", ["not_found_in_search", "incremental", "known"]),
                              "closest_prior": Schema.array("novelty: closest prior work", items: ["type": "string"]),
                              "receipts": Schema.array("novelty and evidence: receipt ids (r…) of the ≥3 searches run after the idea was written that the verdict rests on; left out, the host takes every search it saw since then", items: ["type": "string"]),
                              "prediction": Schema.string("promote: the prediction the hypothesis makes")],
                             required: ["action"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func runsConcurrently(for input: JSON) -> Bool { false }   // changes session state; runs in order

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let s = ctx.services
        let led = s.ideas
        func changed() { s.emit(.ideasChanged(led.snapshot)) }
        if let why = led.ideaActionBlocker(input.str("action") ?? "") { return .error(why) }
        switch input.str("action") {
        case "add":
            guard ctx.role == .main else { return .error("Workers return ideas in their report; the main agent records them.") }
            let raw = input["ideas"]?.arrayValue ?? []
            guard !raw.isEmpty else { return .error("No ideas given.") }
            let origin = led.live.map { $0.trigger == .dream ? "dream:\($0.id)" : "brainstorm:\($0.id)" } ?? "session"
            let aim = led.live?.goal == .proven ? "proven" : nil
            let now = Date()
            let new = raw.compactMap { j -> Idea? in
                let st = (j.str("statement") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !st.isEmpty else { return nil }
                return Idea(id: "", statement: st, mechanism: j.str("mechanism") ?? "", test: j.str("test") ?? "", falsifier: j.str("falsifier") ?? "",
                            op: j.str("operator") ?? "free", seeds: j["seeds"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                            evidence: j["evidence"]?.arrayValue?.compactMap(\.stringValue) ?? [], status: .raw, mergedInto: nil, novelty: nil,
                            noveltyReceipts: [], closestPrior: [], rank: nil, review: nil, reviewFingerprint: nil, hypothesisId: nil, note: nil,
                            origin: origin, createdAt: now, aim: aim)
            }
            let added = led.add(new)
            changed()
            s.log("idea", actor: "agent", ["event": "add", "ids": .array(added.map { .string($0.id) }),
                                           "merged": .array(added.filter { $0.status == .merged }.map { .string("\($0.id)→\($0.mergedInto ?? "")") })])
            let merged = added.filter { $0.status == .merged }
            let all = led.snapshot
            let liveCount = all.filter(\.isLive).count
            return ToolOutput(added.map { "\($0.id)\($0.status == .merged ? " (duplicate of \($0.mergedInto ?? ""))" : "") \($0.statement.truncated(100))" }.joined(separator: "\n")
                + "\n\(added.count) recorded, \(merged.count) merged as duplicates; \(liveCount) live ideas of \(all.count)."
                + (merged.count * 2 > added.count ? " Over half were duplicates: switch operator or seeds instead of generating more of the same." : ""))
        case "list":
            let all = led.snapshot
            guard !all.isEmpty else { return ToolOutput("No ideas yet.") }
            return ToolOutput(all.map { i in
                "\(i.id) [\(i.status.rawValue)\(i.novelty.map { ", \($0.rawValue)" } ?? "")\(i.support.map { ", \($0.rawValue)" } ?? "")\(i.rank.map { ", #\($0)" } ?? "")] \(i.statement.truncated(140)) · \(i.op)"
            }.joined(separator: "\n"))
        case "discard":
            guard let id = input.str("id"), let i = led.discard(id, reason: input.str("reason") ?? "") else { return .error("No such idea.") }
            changed()
            return ToolOutput("\(i.id) discarded.")
        case "rank":
            let order = input["order"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard !order.isEmpty else { return .error("Give the ids in order, best first.") }
            led.setRanks(order)
            changed()
            return ToolOutput("Ranked \(order.count) ideas.")
        case "novelty":
            guard let id = input.str("id"), let v = Idea.Novelty(rawValue: input.str("verdict") ?? "") else { return .error("Give id and verdict.") }
            let r = led.setNovelty(id, v, prior: input["closest_prior"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                   receipts: input["receipts"]?.arrayValue?.compactMap(\.stringValue) ?? [], ledger: s.ledger)
            switch r {
            case .failure(let g): return .error(g.message)
            case .success(let i):
                changed()
                s.log("idea", actor: "agent", ["event": "novelty", "id": .string(i.id), "verdict": .string(v.rawValue),
                                               "receipts": .array(i.noveltyReceipts.map { .string($0) }), "prior": .array(i.closestPrior.map { .string($0) })])
                return ToolOutput("\(i.id): \(v.rawValue)" + (v == .known ? " — discarded as already published." : " (searches \(i.noveltyReceipts.joined(separator: ", "))). The checker reviews this verdict when the idea is promoted."))
            }
        case "evidence":
            guard let id = input.str("id"), let v = Idea.Support(rawValue: input.str("support") ?? "") else { return .error("Give id and support.") }
            let r = led.setSupport(id, v, results: input["results"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                   receipts: input["receipts"]?.arrayValue?.compactMap(\.stringValue) ?? [], ledger: s.ledger)
            switch r {
            case .failure(let g): return .error(g.message)
            case .success(let i):
                changed()
                s.log("idea", actor: "agent", ["event": "evidence", "id": .string(i.id), "support": .string(v.rawValue),
                                               "receipts": .array(i.noveltyReceipts.map { .string($0) }), "results": .array(i.closestPrior.map { .string($0) })])
                return ToolOutput("\(i.id): \(v.rawValue) (searches \(i.noveltyReceipts.joined(separator: ", "))). The checker reviews this when the idea is promoted.")
            }
        case "promote":
            guard ctx.role == .main else { return .error("Only the main agent registers hypotheses.") }
            guard let id = input.str("id") else { return .error("Give the idea id.") }
            if led.live?.trigger == .dream || led.current?.trigger == .dream && !s.asks.interactive {
                return .error("A dreaming run does not register hypotheses; the user decides when they read the ideas.")
            }
            if let b = led.promotionBlocker(id) { return .error(b) }
            if case .refuse(let m) = s.research.requireGrounding("registering a hypothesis") { return .error(m) }
            guard let idea = led.snapshot.first(where: { $0.id == id }) else { return .error("No idea \(id).") }
            let prediction = (input.str("prediction") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prediction.isEmpty else { return .error("State the prediction the hypothesis makes.") }
            let fp = (idea.statement + idea.falsifier + idea.noveltyReceipts.joined() + idea.closestPrior.joined() + prediction).stableHash
            if idea.reviewFingerprint == fp, let v = idea.review, v != "pass" {
                return .error("The checker returned \(v) on this idea and nothing has changed since. Address its points (more searches, a sharper test) first.")
            }
            let searches = idea.noveltyReceipts.compactMap { s.ledger.receipt($0) }.map { "\($0.id) · \($0.tool) · \($0.argsSummary.prefix(200))" }
            let focus = idea.aim == "proven" ? """
            Idea \(idea.id) is about to be registered as a hypothesis. The user wants what works best, not novelty: \
            review its evidence check and testability.
            Statement: \(idea.statement)
            Mechanism: \(idea.mechanism)
            Test: \(idea.test)
            Falsifier: \(idea.falsifier)
            Prediction: \(prediction)
            Support: \(idea.support?.rawValue ?? "none") · published results: \(idea.closestPrior.joined(separator: ", "))
            Searches cited (open them with `receipt`):
            \(searches.joined(separator: "\n"))
            Check: do the cited results really show this approach working well on comparable problems (read them)? Are better \
            supported alternatives being passed over? Is the test feasible here and could the falsifier occur? Prior work is \
            expected, not a fault. Use "block" if the support is unfounded; "revise" only for a named gap that decides whether this is worth testing (a missing \
            source for the central support, a test that cannot be run here); otherwise pass and put improvements in the notes.
            """ : """
            Idea \(idea.id) is about to be registered as a hypothesis. Review its novelty check and testability.
            Statement: \(idea.statement)
            Mechanism: \(idea.mechanism)
            Test: \(idea.test)
            Falsifier: \(idea.falsifier)
            Prediction: \(prediction)
            Novelty verdict: \(idea.novelty?.rawValue ?? "none") · closest prior: \(idea.closestPrior.joined(separator: ", "))
            Searches cited (open them with `receipt`):
            \(searches.joined(separator: "\n"))
            Check: do the queries cover synonyms, the mechanism, the method and the organism? Is the closest prior work really \
            different, or is this already published (search yourself)? Is the test feasible and could the falsifier actually occur? \
            Use "block" if it is already published or the verdict is unsupported; "revise" only for a named gap that decides whether \
            this is worth testing (a specific search that was not run and could overturn the verdict, a test that cannot be run \
            here, a falsifier that cannot occur); otherwise pass and put improvements in the notes. The idea becomes a \
            hypothesis to be tested, not a result: it does not have to be proven before the test.
            """
            // The reviewer judges the idea against what the user asked and chose, not in isolation: one review
            // after another can otherwise narrow an idea until it no longer answers the request.
            let anchor = s.research.compass()
            let anchored = anchor.isEmpty ? focus : focus + "\n\nThe task this idea must serve:\n" + anchor.joined(separator: "\n")
                + "\nAlso check: does it still answer this objective and the direction the user chose? Ask for fixes that keep it "
                + "serving them; if it has drifted away from them, say so as an issue."
            let outcome = await s.supervisor.reviewOutcome(kind: "ideation",
                                                   signals: [IntegritySignal(kind: .ideation, severity: 2, detail: "idea \(idea.id) → hypothesis (\(fp.prefix(8)))", location: nil)],
                                                   focus: anchored, subject: idea.id)
            var review: String?, passNotes = ""
            switch outcome {
            case .message(let m): review = m
            case .passed(let notes): passNotes = notes.map { "\n" + $0 } ?? ""
            case .skipped(let why): passNotes = "\n(Registered without a new review: \(why). Say so if you report this hypothesis.)"
            }
            let verdict = review.map { $0.contains("verdict=\"block\"") ? "block" : $0.contains("verdict=\"unavailable\"") ? "unavailable" : "revise" } ?? "pass"
            led.setReview(id, verdict: verdict, fingerprint: fp)
            if let review {
                changed()
                let failed = verdict == "unavailable" ? 0 : s.research.noteIdeaReviewFailed()
                return .error("Not registered: the independent review did not pass.\n" + review + Self.backToTheUser(failed))
            }
            let (gate, h) = s.research.addHypothesis(statement: idea.statement, prediction: prediction, falsification: idea.falsifier,
                                                     rationale: "promoted from idea \(idea.id) after \(idea.aim == "proven" ? "evidence" : "novelty") check and review")
            if case .refuse(let m) = gate { return .error(m) }
            guard let h else { return .error("Could not register the hypothesis.") }
            _ = led.markPromoted(id, hypothesis: h.id)
            changed()
            s.emit(.planChanged(s.research.snapshot))
            s.log("idea", actor: "host", ["event": "promoted", "id": .string(id), "hypothesis": .string(h.id)])
            let how = if case .skipped = outcome { "is registered" } else { "passed review and is registered" }
            return ToolOutput("\(idea.id) \(how) as hypothesis \(h.id). Add plan steps that test it; any finding goes through `claim_finding`." + passNotes)
        default:
            return .error("Unknown action.")
        }
    }

    /// Reviews that may fail before the user decides again; each revision moves the idea further from their choice.
    static let reviewsBeforeAsking = 2

    static func backToTheUser(_ failed: Int) -> String {
        guard failed >= reviewsBeforeAsking else { return "" }
        return "\n\n<back_to_the_user>\(failed) idea reviews have not passed since the user last decided. Do not revise again on your own: "
            + "show the user the current version, the open issues, and how it now differs from what they chose and from their objective; "
            + "then ask with `ask_user` (reason direction) whether to go on with this version, go back to their original choice as it was, "
            + "or pick another idea.</back_to_the_user>"
    }
}

// MARK: - ideation_seeds

struct IdeationSeedsTool: Tool {
    let name = "ideation_seeds"
    let description = """
    Draw seed concepts for divergent thinking — provocations, not facts. Sources: library (distinctive terms from \
    the task library), far_papers (library papers least related to the topic, for analogy), cross_domain (mechanisms \
    and design patterns from other fields). The draw is seeded and recorded, so it can be replayed. Whatever a seed \
    suggests must still be searched before you rely on it.
    """
    var inputSchema: JSON {
        Schema.object(["topic": Schema.string("What the ideas are for"),
                       "sources": Schema.array("library | far_papers | cross_domain (default all)", items: ["type": "string"]),
                       "k": Schema.integer("Seeds per source (default 4, max 12)"),
                       "seed": Schema.integer("RNG seed (default: drawn and reported)")], required: ["topic"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func runsConcurrently(for input: JSON) -> Bool { false }   // changes session state; runs in order

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let topic = try input.required("topic")
        let k = max(1, min(12, input.int("k") ?? 4))
        let seed = UInt64(truncatingIfNeeded: input.int("seed") ?? Int.random(in: 1...999_999))
        var rng = IdeationSeeds.RNG(seed: seed)
        let sources = input["sources"]?.arrayValue?.compactMap(\.stringValue) ?? ["library", "far_papers", "cross_domain"]
        let records = ctx.services.library.records
        var out = ["rng seed: \(seed)"]
        for src in sources {
            switch src {
            case "library":
                let pool = IdeationSeeds.libraryTerms(records).filter { !IdeaLedger.terms(topic).contains($0) }
                out.append("library terms: " + (pool.isEmpty ? "(library is empty — fetch papers first)" : IdeationSeeds.sample(pool, k: k, rng: &rng).joined(separator: ", ")))
            case "far_papers":
                let far = IdeationSeeds.farPapers(records, topic: topic, k: max(k * 3, 6))
                let pick = IdeationSeeds.sample(far, k: k, rng: &rng)
                out.append("distant library papers: " + (pick.isEmpty ? "(none)" : pick.map { "[@\($0.key)] \($0.title.truncated(90))" }.joined(separator: "; ")))
            case "cross_domain":
                out.append("cross-domain mechanisms: " + IdeationSeeds.sample(IdeationSeeds.crossDomain, k: k, rng: &rng).joined(separator: ", "))
            default:
                out.append("unknown source \(src)")
            }
        }
        out.append("Use each seed as a forced association (\"what if \(topic.truncated(60)) worked like …?\"); keep only ideas you can state with a mechanism and a test, and search before relying on any.")
        return ToolOutput(out.joined(separator: "\n"), facts: ["rng_seed": .int(Int(seed % UInt64(Int.max)))])
    }
}
