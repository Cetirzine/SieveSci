import Foundation
import Testing
@testable import SieveSciCore

/// 0.3.0: results that go against the plan are looked back at before the work goes on, the way on
/// is chosen from a fixed ladder, the objective stays the user's, and nothing about it is hidden.
@Suite struct ChangeOfCourse {
    func services() throws -> SessionServices {
        let (s, _) = try makeServices()
        s.research.groundingRequired = false
        return s
    }

    @discardableResult
    func receipt(_ s: SessionServices, _ tool: String = "python", ok: Bool = true) -> Receipt {
        s.ledger.record(tool: tool, args: ["code": "x"], output: ok ? ToolOutput("ok") : .error("Traceback: boom"), role: .main, startedAt: Date(), duration: 0)
    }

    func plan(_ s: SessionServices, onNegative: String? = nil, onFailure: String? = nil) {
        var h = Hypothesis(id: "H1", statement: "A binds B", prediction: "Kd < 1 µM", falsification: "Kd > 10 µM", status: "open", registeredAt: Date())
        h.onNegative = onNegative
        var st = PlanStep(id: "S1", title: "Measure", detail: "", status: "pending", checkpoint: false, criteria: "", evidence: [], note: "")
        st.onFailure = onFailure
        _ = s.research.setPlan(goal: "test binding", background: "", hypotheses: [h], steps: [st], rationale: "")
    }

    func review(_ subject: String, _ d: ReviewDecision, rule: Bool = false, alt: String? = nil, receipts: [String] = []) -> ResultReview {
        ResultReview(id: "", at: Date(), trigger: "", subject: subject, expected: "Kd < 1 µM", observed: "Kd 40 µM", causes: ["the hypothesis is false"],
                     check: "replicate", decision: d, followsRule: rule, servesObjective: "still answers whether A binds B", next: "report it",
                     receipts: receipts, alternative: alt)
    }

    @Test func aFailedStepHoldsAnalysisUntilItIsReviewed() throws {
        let s = try services()
        plan(s)
        _ = s.research.updateStep(id: "S1", status: "failed", evidence: [], note: "crashed")
        #expect(s.research.pendingReview?.subject == "S1")
        #expect(s.research.takeReviewNotice()?.contains("result_review") == true)
        #expect(s.research.takeReviewNotice() == nil, "said once")
        if case .allow = s.research.requireReview(tool: "python", input: ["code": "1"]) { Issue.record("analysis ran before the review") }
        if case .refuse = s.research.requireReview(tool: "bash", input: ["command": "ls -la"]) { Issue.record("reading was blocked") }
        if case .refuse = s.research.requireReview(tool: "read_file", input: ["path": "a"]) { Issue.record("reading was blocked") }
        let (d, r) = s.research.addReview(review("S1", .repair), ideaExists: { _ in false })
        #expect(d == .allow && r?.id == "RV1")
        #expect(s.research.pendingReview == nil)
        if case .refuse = s.research.requireReview(tool: "python", input: ["code": "1"]) { Issue.record("still held after the review") }
    }

    @Test func aRefutedHypothesisAsksForAReview() throws {
        let s = try services()
        plan(s)
        var h = s.research.snapshot.hypotheses[0]
        h.status = "refuted"
        _ = s.research.setPlan(goal: "test binding", background: "", hypotheses: [h], steps: s.research.snapshot.steps, rationale: "H1 came out negative")
        #expect(s.research.pendingReview?.subject == "H1")
    }

    @Test func threeFailedRunsInARowAreAStall() throws {
        let s = try services()
        plan(s)
        receipt(s, ok: true)
        for _ in 0..<2 { receipt(s, ok: false) }
        s.research.checkStall()
        #expect(s.research.pendingReview == nil)
        receipt(s, ok: false)
        s.research.checkStall()
        #expect(s.research.pendingReview?.trigger == "three failed runs in a row")
    }

    @Test func repairIsBoundedAndPivotsNameWhereTheyGo() throws {
        let s = try services()
        plan(s)
        for _ in 0..<3 { #expect(s.research.addReview(review("S1", .repair), ideaExists: { _ in false }).0 == .allow) }
        if case .allow = s.research.addReview(review("S1", .repair), ideaExists: { _ in false }).0 { Issue.record("a fourth repair was allowed") }
        if case .allow = s.research.addReview(review("S1", .pivot), ideaExists: { _ in false }).0 { Issue.record("a pivot without a destination") }
        if case .allow = s.research.addReview(review("S1", .pivot, alt: "I9"), ideaExists: { _ in false }).0 { Issue.record("a pivot to a missing idea") }
        #expect(s.research.addReview(review("S1", .pivot, alt: "I2"), ideaExists: { $0 == "I2" }).0 == .allow)
        #expect(s.research.addReview(review("S1", .pivot, alt: "brainstorm"), ideaExists: { _ in false }).0 == .allow)
    }

    @Test func aReviewCitesRealReceiptsAndFillsItsReasoning() throws {
        let s = try services()
        plan(s)
        if case .allow = s.research.addReview(review("S1", .stop, receipts: ["r999"]), ideaExists: { _ in false }).0 { Issue.record("a made-up receipt was accepted") }
        var empty = review("S1", .adjust)
        empty.servesObjective = " "
        if case .allow = s.research.addReview(empty, ideaExists: { _ in false }).0 { Issue.record("a review that ignores the objective") }
        let r = receipt(s)
        #expect(s.research.addReview(review("S1", .stop, receipts: [r.id]), ideaExists: { _ in false }).0 == .allow)
    }

    @Test func asPlannedOnlyWhenTheRuleWasWrittenBefore() throws {
        let s = try services()
        plan(s, onNegative: "switch to ITC")
        let a = s.research.addReview(review("H1", .adjust, rule: true), ideaExists: { _ in false }).1
        #expect(a?.followsRule == true)
        let b = s.research.addReview(review("S1", .adjust, rule: true), ideaExists: { _ in false }).1
        #expect(b?.followsRule == false, "S1 had no on_failure rule")
    }

    @Test func changingARuleAfterResultsIsADeviation() throws {
        let s = try services()
        plan(s, onNegative: "switch to ITC")
        receipt(s)   // analysis has run
        var h = s.research.snapshot.hypotheses[0]
        h.onNegative = "keep trying other buffers until it binds"
        let (_, rev) = s.research.setPlan(goal: "test binding", background: "", hypotheses: [h], steps: s.research.snapshot.steps, rationale: "the rule for H1 was changed after the run")
        #expect(rev?.afterResults == true && rev?.changedCriteria.contains("H1") == true)
    }

    @Test func theObjectiveIsTheUsersAndStaysFixed() async throws {
        let s = try services()
        s.research.lastUserRequest = "Find out whether compound A binds protein B"
        plan(s)
        #expect(s.research.objective == "Find out whether compound A binds protein B")
        // A new goal wording does not move the objective.
        _ = s.research.setPlan(goal: "optimise A's solubility instead", background: "", hypotheses: s.research.snapshot.hypotheses,
                               steps: s.research.snapshot.steps, rationale: "the model would rather do something else")
        #expect(s.research.objective == "Find out whether compound A binds protein B")
        // Changing it needs the user's own words.
        let ctx = ToolContext(workspace: s.workspace, sessionId: "main", role: .main, ledger: s.ledger, audit: s.audit, services: s)
        let refused = try await UpdatePlanTool().run(["action": "objective", "objective": "optimise solubility", "user_quote": "please optimise solubility"], ctx)
        #expect(refused.isError)
        s.log("user_turn", actor: "user", ["text": "OK, forget binding — please optimise solubility instead"])
        let ok = try await UpdatePlanTool().run(["action": "objective", "objective": "optimise solubility", "user_quote": "please optimise solubility"], ctx)
        #expect(!ok.isError)
        #expect(s.research.objective == "optimise solubility")
    }

    @Test func theTurnContextCarriesTheObjectiveAndWhatWasLearned() throws {
        let s = try services()
        s.research.lastUserRequest = "Does A bind B?"
        plan(s)
        _ = s.research.updateStep(id: "S1", status: "failed", evidence: [], note: "")
        var text = TurnContext.render(services: s, model: "m")
        #expect(text.contains("objective (the user's request; fixed): Does A bind B?"))
        #expect(text.contains("result review needed: S1 failed"))
        _ = s.research.addReview(review("S1", .adjust), ideaExists: { _ in false })
        text = TurnContext.render(services: s, model: "m")
        #expect(text.contains("learned so far: RV1 S1 → adjust"))
        #expect(!text.contains("result review needed"))
    }

    @Test func aFocusedReBrainstormNeedsFewerIdeas() throws {
        let s = try services()
        let led = s.ideas
        led.request(.user)
        guard case .success(let b) = led.start(topic: "next route", reason: "RV1", goal: .proven, afterReview: "RV1") else { Issue.record("not started"); return }
        #expect(b.afterReview == "RV1")
        #expect(BrainstormState.Goal.proven == b.goal)
    }

    @Test func theAgentLoopHoldsAnalysisUntilTheReviewThenGoesOn() async throws {
        final class Script: LLMProvider, @unchecked Sendable {
            let profile = ProviderProfile(id: "script", displayName: "script", family: .anthropic, baseURL: "http://localhost", auth: .none, apiKeyRef: "", models: ["m"])
            let lock = NSLock()
            var n = 0
            var requests: [LLMRequest] = []
            let steps: [(String, JSON)] = [
                ("update_plan", ["action": "step", "step_id": "S1", "status": "failed", "note": "crashed"]),
                ("python", ["code": "print(1)"]),
                ("result_review", ["subject": "S1", "expected": "a fit", "observed": "a crash", "causes": ["a bug in the loader"],
                                   "check": "rerun with a fixed path", "decision": "repair", "serves_objective": "same question",
                                   "next": "fix the path and rerun"]),
            ]
            func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
                let i: Int = lock.withLock { requests.append(request); n += 1; return n - 1 }
                let msg: Message = i < steps.count
                    ? Message(role: .assistant, blocks: [.toolUse(ToolUse(id: "t\(i)", name: steps[i].0, input: steps[i].1))])
                    : .assistant("done")
                return AsyncThrowingStream { c in
                    c.yield(.completed(LLMResponse(message: msg, stopReason: i < steps.count ? .toolUse : .endTurn, usage: Usage(input: 1, output: 1))))
                    c.finish()
                }
            }
        }
        let p = Script()
        let (s, _) = try makeServices(p)
        s.research.groundingRequired = false
        s.permissions.mode = .yolo
        plan(s)
        let a = AgentSession(id: "main", role: .main, services: s, tools: BuiltinTools.all())
        _ = try await a.send("go on")
        func results(_ r: LLMRequest) -> String {
            r.messages.last?.blocks.map { b -> String in
                if case .toolResult(let t) = b { return t.content }
                if case .text(let t) = b { return t }
                return ""
            }.joined(separator: "\n") ?? ""
        }
        #expect(p.requests.count >= 4)   // the end-of-turn reviewer may call the model too
        #expect(results(p.requests[1]).contains("<result_review_needed>S1 failed"))
        #expect(results(p.requests[2]).contains("Result review first"), "python was held")
        #expect(results(p.requests[3]).contains("Review RV1 recorded (repair)"))
        #expect(s.research.pendingReview == nil && s.research.reviews.count == 1)
    }

    @Test func theFirstResearchRequestIsTheObjectiveAndLaterRepliesDoNotReplaceIt() throws {
        let s = try services()
        s.research.recordUserRequest("hello", scale: .chat)
        #expect(s.research.objective == nil, "a greeting is not a task")
        s.research.recordUserRequest("Design a small model that runs fast on a phone NPU", scale: .research)
        s.research.recordUserRequest("ok, go with option 2", scale: .quick)
        plan(s)
        #expect(s.research.objective == "Design a small model that runs fast on a phone NPU")
    }

    @Test func aShortMessageInsideResearchStaysResearch() async throws {
        let (s, _) = try makeServices(ScriptedProvider(replies: ["ok"]))
        s.research.groundingRequired = false
        plan(s)
        let a = AgentSession(id: "main", role: .main, services: s, tools: [])
        _ = try await a.send("继续")
        #expect(s.research.turnScale == .research, "continuing a plan keeps its gates")
        _ = try await a.send("你好")
        #expect(s.research.turnScale == .chat)
    }

    @Test func unnamedRepairsAreBoundedToo() throws {
        let s = try services()
        plan(s)
        for _ in 0..<3 { #expect(s.research.addReview(review("", .repair), ideaExists: { _ in false }).0 == .allow) }
        if case .allow = s.research.addReview(review("", .repair), ideaExists: { _ in false }).0 { Issue.record("endless unnamed repairs") }
    }

    @Test func failuresBeforeAReviewNeverCountAgain() throws {
        let s = try services()
        plan(s)
        for _ in 0..<3 { receipt(s, ok: false) }
        s.research.checkStall()
        #expect(s.research.pendingReview != nil)
        _ = s.research.addReview(review("S1", .repair), ideaExists: { _ in false })
        receipt(s, ok: false)
        s.research.checkStall()
        #expect(s.research.pendingReview == nil, "one new failure after the review is not a stall")
        #expect(s.research.snapshot.reviewMark == s.ledger.count - 1, "kept in the saved plan, so a restart does not recount")
    }
}
