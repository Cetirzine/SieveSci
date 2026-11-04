import Foundation
import Testing
@testable import SieveSciCore

@Suite struct AskUserTests {
    func q(_ extra: JSON = [:]) -> JSON {
        var o: [String: JSON] = ["header": "Direction", "question": "Which direction?", "kind": "single",
                                 "options": [["label": "A"], ["label": "B", "recommended": true], ["label": "Other"]]]
        if case .object(let e) = extra { for (k, v) in e { o[k] = v } }
        return .object(o)
    }

    @Test func parseNormalisesOptions() throws {
        let qs = try AskFormat.parse(["questions": [q()]])
        #expect(qs.count == 1)
        // "Other" is the front end's job; the recommendation goes first.
        #expect(qs[0].options.map(\.label) == ["B", "A"])
        #expect(qs[0].options[0].recommended)
        #expect(qs[0].allowOther)
        let text = try AskFormat.parse(["questions": [["header": "Cells", "question": "How many?", "kind": "text"]]])
        #expect(text[0].kind == .text && text[0].options.isEmpty && !text[0].allowOther)
    }

    @Test func parseRejectsBadInput() {
        #expect(throws: (any Error).self) { try AskFormat.parse(["questions": []]) }
        #expect(throws: (any Error).self) { try AskFormat.parse(["questions": [["header": "X", "question": "?", "kind": "single", "options": [["label": "only"]]]]]) }
        #expect(throws: (any Error).self) { try AskFormat.parse(["questions": [["header": "X", "question": "?", "kind": "single", "options": [["label": "a"], ["label": "a"]]]]]) }
    }

    @Test func resultsSayWhatHappened() throws {
        let qs = try AskFormat.parse(["questions": [q(), ["header": "N", "question": "n?", "kind": "text", "optional": true]]])
        let req = AskRequest(id: "t1", agentId: "main", questions: qs)
        let ok = AskFormat.result(req, .answered([AskAnswer(questionId: qs[0].id, selected: ["A"], other: "also C")]))
        #expect(ok.contains("Direction: A; other: \"also C\""))
        #expect(ok.contains("left unanswered"))
        // An answer with nothing in it is a dismissal, never a choice.
        #expect(AskFormat.result(req, .answered([AskAnswer(questionId: qs[0].id)])).contains("dismissed"))
        #expect(AskFormat.result(req, .timedOut(30)).contains("not a preference"))
        #expect(AskFormat.result(req, .unavailable).contains("Do not choose for them"))
    }

    @Test func headlessRunsGetNoAnswer() async throws {
        let (s, _) = try makeServices()
        s.asks.interactive = false
        let ctx = ToolContext(workspace: s.workspace, sessionId: "main", role: .main, ledger: s.ledger, audit: s.audit, services: s)
        let out = try await AskUserTool().run(["questions": [q()]], ctx)
        #expect(out.text.contains("outcome=\"unavailable\""))
    }

    @Test func answerResumesTheWaitingCall() async throws {
        let (s, _) = try makeServices()
        s.asks.interactive = true
        let seen = LockedBox<[String]>([])
        s.emit = { ev in
            if case .askRequested(let r) = ev {
                seen.mutate { $0.append(r.id) }
                Task { s.asks.resolve(r.id, .answered([AskAnswer(questionId: r.questions[0].id, selected: ["B"])])) }
            }
        }
        let ctx = ToolContext(workspace: s.workspace, sessionId: "main", role: .main, ledger: s.ledger, audit: s.audit, services: s)
        let out = try await AskUserTool().run(["questions": [q()]], ctx)
        #expect(out.text.contains("Direction: B"))
        #expect(seen.value.count == 1)
        #expect(s.asks.pending.isEmpty)
    }

    @Test func onlyMainAsksAndDirectionsNeedSearches() async throws {
        let (s, _) = try makeServices()
        s.asks.interactive = true
        let worker = ToolContext(workspace: s.workspace, sessionId: "w", role: .worker, ledger: s.ledger, audit: s.audit, services: s)
        #expect(try await AskUserTool().run(["questions": [q()]], worker).isError)
        let main = ToolContext(workspace: s.workspace, sessionId: "main", role: .main, ledger: s.ledger, audit: s.audit, services: s)
        let r = try await AskUserTool().run(["questions": [q(["reason": "direction"])]], main)
        #expect(r.isError && r.text.contains("Search before"))
    }

    @Test func askIsADecisionBarrier() async throws {
        let (s, _) = try makeServices()
        s.asks.interactive = false
        let a = AgentSession(id: "main", role: .main, services: s, tools: BuiltinTools.all(), contextWindow: 100_000)
        let uses = [ToolUse(id: "u1", name: "glob", input: ["pattern": "*"]), ToolUse(id: "u2", name: "ask_user", input: ["questions": [q()]])]
        let out = await a.runTools(uses)
        let results = out.compactMap(\.toolResult)
        #expect(results.map(\.toolUseId) == ["u1", "u2"])
        #expect(results[0].isError && results[0].content.contains("Not run"))
        #expect(results[1].content.contains("ask_answer"))
    }
}

@Suite struct IdeaLedgerTests {
    func idea(_ st: String, at: Date = Date()) -> Idea {
        Idea(id: "", statement: st, mechanism: "", test: "run it", falsifier: "no effect", op: "free", seeds: [], evidence: [], status: .raw,
             mergedInto: nil, novelty: nil, noveltyReceipts: [], closestPrior: [], rank: nil, review: nil, reviewFingerprint: nil,
             hypothesisId: nil, note: nil, origin: "session", createdAt: at)
    }

    @Test func nearDuplicatesAreMerged() {
        let l = IdeaLedger()
        let out = l.add([idea("A temperature gated second additive takes over film formation"),
                         idea("A second additive, temperature gated, takes over film formation"),
                         idea("Trace water catalyses additive breakdown")])
        #expect(out.map(\.status) == [.raw, .merged, .raw])
        #expect(out[1].mergedInto == "I1")
        // CJK text is compared by character bigrams.
        let zh = l.add([idea("高温下第二种添加剂接管成膜"), idea("高温下第二种添加剂接管成膜过程")])
        #expect(zh[1].status == .merged)
    }

    @Test func noveltyNeedsSearchesAfterTheIdea() throws {
        let (s, _) = try makeServices()
        let i = s.ideas.add([idea("An idea")])[0]
        let before = s.ledger.record(tool: "web_search", args: [:], output: ToolOutput("ok"), role: .main, startedAt: Date().addingTimeInterval(-60), duration: 0)
        guard case .failure = s.ideas.setNovelty(i.id, .notFound, prior: [], receipts: [before.id], ledger: s.ledger) else {
            Issue.record("a search from before the idea must not count"); return
        }
        let rs = (0..<3).map { _ in s.ledger.record(tool: "literature_search", args: [:], output: ToolOutput("ok"), role: .main, startedAt: Date(), duration: 0).id }
        guard case .success(let checked) = s.ideas.setNovelty(i.id, .notFound, prior: [], receipts: rs, ledger: s.ledger) else {
            Issue.record("three later searches are enough"); return
        }
        #expect(checked.status == .checked && checked.noveltyReceipts == rs)
        #expect(s.ideas.promotionBlocker(i.id) == nil)
        // Known work is discarded and can never be promoted.
        let k = s.ideas.add([idea("Coat the cathode")])[0]
        _ = s.ideas.setNovelty(k.id, .known, prior: ["@smith2020"], receipts: [], ledger: s.ledger)
        #expect(s.ideas.promotionBlocker(k.id) != nil)
    }

    @Test func autonomousStartFollowsTheSetting() {
        let l = IdeaLedger()
        l.autoAllowed = false
        guard case .failure = l.start(topic: "x", reason: "") else { Issue.record("auto start must be refused when off"); return }
        // The user can always ask.
        l.request(.user)
        guard case .success(let st) = l.start(topic: "x", reason: "") else { Issue.record("a user request starts it"); return }
        #expect(st.trigger == .user)
        #expect(l.requestWrapUp() != nil)
        #expect(l.drainWrapUp()?.contains("wrap up") == true)
        #expect(l.drainWrapUp() == nil)   // delivered once
        #expect(l.end(summary: "done")?.endedAt != nil)
        #expect(l.live == nil)
    }

    @Test func promotionRegistersAHypothesisAfterReview() async throws {
        let checker = ScriptedProvider(replies: [#"{"verdict":"pass","issues":[],"required_actions":[],"questions":[],"notes":"ok"}"#])
        let (s, _) = try makeServices(checker: checker)
        _ = s.ledger.record(tool: "web_search", args: [:], output: ToolOutput("ok"), role: .main, startedAt: Date().addingTimeInterval(-120), duration: 0)
        let i = s.ideas.add([idea("An idea worth testing")])[0]
        let rs = (0..<3).map { _ in s.ledger.record(tool: "literature_search", args: [:], output: ToolOutput("ok"), role: .main, startedAt: Date(), duration: 0).id }
        _ = s.ideas.setNovelty(i.id, .notFound, prior: [], receipts: rs, ledger: s.ledger)
        let ctx = ToolContext(workspace: s.workspace, sessionId: "main", role: .main, ledger: s.ledger, audit: s.audit, services: s)
        let out = try await IdeaTool().run(["action": "promote", "id": .string(i.id), "prediction": "effect > 0"], ctx)
        #expect(!out.isError, "\(out.text)")
        #expect(s.research.snapshot.hypotheses.contains { $0.statement == "An idea worth testing" && $0.falsification == "no effect" })
        #expect(s.ideas.snapshot.first { $0.id == i.id }?.status == .promoted)
    }

    @Test func seedsAreReproducible() async throws {
        let (s, _) = try makeServices()
        let ctx = ToolContext(workspace: s.workspace, sessionId: "main", role: .main, ledger: s.ledger, audit: s.audit, services: s)
        let a = try await IdeationSeedsTool().run(["topic": "additive", "sources": ["cross_domain"], "seed": 42], ctx)
        let b = try await IdeationSeedsTool().run(["topic": "additive", "sources": ["cross_domain"], "seed": 42], ctx)
        #expect(a.text == b.text && a.text.contains("rng seed: 42"))
    }
}
