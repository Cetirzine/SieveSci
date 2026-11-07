import Foundation
import Testing
@testable import SieveSciCore

/// The brainstorm is a closed phase with a fixed order, enforced by the host:
/// ground → diverge → dedupe → rank → novelty → [review → evolve] → report → (user chooses) → end → promote → plan.
///
/// Regressions (0.2.3): the agent jumped stages, ended without ranking or checking novelty, wrote a plan in the
/// middle of a brainstorm to unblock an analysis, and the host then sent that plan's steps to workers.
@Suite struct BrainstormFlowTests {
    func ctx(_ s: SessionServices) -> ToolContext {
        ToolContext(workspace: s.workspace, sessionId: "main", role: .main, ledger: s.ledger, audit: s.audit, services: s)
    }

    func ground(_ s: SessionServices) {
        for t in ["web_search", "literature_search"] {
            _ = s.ledger.record(tool: t, args: [:], output: ToolOutput("ok"), role: .main, startedAt: Date().addingTimeInterval(-300), duration: 0)
        }
    }

    func stage(_ s: SessionServices, _ name: String) async throws -> ToolOutput {
        try await BrainstormTool().run(["action": "stage", "stage": .string(name), "note": "n"], ctx(s))
    }

    func addIdeas(_ s: SessionServices, _ n: Int) async throws -> ToolOutput {
        let topics = ["membrane", "lipid", "kinase", "solvent", "zeolite", "graphene", "enzyme", "photon", "ribosome", "plasmid"]
        let ideas: [JSON] = (0..<n).map { i in
            ["statement": .string("Idea about \(topics[i % topics.count]) number \(i) with unique word w\(i)x\(i)"),
             "test": "assay", "falsifier": "no change"]
        }
        return try await IdeaTool().run(["action": "add", "ideas": .array(ideas)], ctx(s))
    }

    func started() throws -> SessionServices {
        let (s, _) = try makeServices()
        s.ideas.request(.user)
        guard case .success = s.ideas.start(topic: "electrolyte additives", reason: "test", goal: .novel) else { throw ToolError.invalidInput("start") }
        return s
    }

    @Test func stagesRunInOrderAndNeedTheirWork() async throws {
        let s = try started()
        // Grounding first.
        #expect(try await stage(s, "diverge").text.contains("Grounding is not done"))
        ground(s)
        // No skipping ahead.
        #expect(try await stage(s, "rank").text.contains("Stage diverge comes before rank"))
        #expect(!(try await stage(s, "diverge")).isError)
        // Ideas only in diverge/evolve, and enough of them before converging.
        _ = try await addIdeas(s, 3)
        #expect(try await stage(s, "dedupe").text.contains("Only 3 live ideas"))
        _ = try await addIdeas(s, 6)
        #expect(!(try await stage(s, "dedupe")).isError)
        #expect(try await addIdeas(s, 1).text.contains("recorded in the diverge stage"))
        #expect(!(try await stage(s, "rank")).isError)
        #expect(try await stage(s, "novelty").text.contains("record the order with `idea` rank"))
        let live = s.ideas.snapshot.filter(\.isLive).map { JSON.string($0.id) }
        #expect(!(try await IdeaTool().run(["action": "rank", "order": .array(live)], ctx(s))).isError)
        #expect(!(try await stage(s, "novelty")).isError)
        // Cannot end, or report, before the top ideas are checked.
        #expect(try await BrainstormTool().run(["action": "end", "summary": "x"], ctx(s)).text.contains("ends from the report stage"))
        #expect(try await stage(s, "report").text.contains("Novelty-check the top 3"))
        let rs = (0..<3).map { _ in s.ledger.record(tool: "literature_search", args: [:], output: ToolOutput("ok"), role: .main, startedAt: Date().addingTimeInterval(5), duration: 0).id }
        for id in live.prefix(3) {
            let out = try await IdeaTool().run(["action": "novelty", "id": id, "verdict": "not_found_in_search", "receipts": .array(rs.map { .string($0) })], ctx(s))
            #expect(!out.isError, "\(out.text)")
        }
        // Review and evolve are optional; promotion waits for the end.
        let report = try await stage(s, "report")
        #expect(!report.isError && report.text.contains("ask_user"))
        #expect(try await IdeaTool().run(["action": "promote", "id": live[0], "prediction": "p"], ctx(s)).text.contains("after the brainstorm"))
        let end = try await BrainstormTool().run(["action": "end", "summary": "x"], ctx(s))
        #expect(!end.isError && end.text.contains("update_plan"))
        #expect(s.ideas.live == nil)
    }

    @Test func evolveMayLoopBackTwice() async throws {
        let s = try started()
        ground(s)
        _ = try await stage(s, "diverge")
        _ = try await addIdeas(s, 6)
        _ = try await stage(s, "dedupe")
        _ = try await stage(s, "rank")
        let ids = s.ideas.snapshot.filter(\.isLive).map { JSON.string($0.id) }
        _ = try await IdeaTool().run(["action": "rank", "order": .array(ids)], ctx(s))
        _ = try await stage(s, "novelty")
        let rs = (0..<3).map { _ in s.ledger.record(tool: "web_search", args: [:], output: ToolOutput("ok"), role: .main, startedAt: Date().addingTimeInterval(5), duration: 0).id }
        for id in ids.prefix(3) { _ = try await IdeaTool().run(["action": "novelty", "id": id, "verdict": "not_found_in_search", "receipts": .array(rs.map { .string($0) })], ctx(s)) }
        #expect(!(try await stage(s, "evolve")).isError)
        #expect(try await stage(s, "ground").text.contains("Stages run forward"))
        for _ in 0..<2 {
            #expect(!(try await stage(s, "rank")).isError)
            #expect(!(try await stage(s, "novelty")).isError)
            #expect(!(try await stage(s, "evolve")).isError)
        }
        #expect(try await stage(s, "rank").text.contains("evolve rounds are done"))
        #expect(!(try await stage(s, "report")).isError)
    }

    @Test func wrapUpJumpsToReport() async throws {
        let s = try started()
        ground(s)
        _ = try await stage(s, "diverge")
        _ = s.ideas.requestWrapUp()
        #expect(!(try await stage(s, "report")).isError)
        #expect(!(try await BrainstormTool().run(["action": "end", "summary": "x"], ctx(s))).isError)
    }

    /// No plan and no workers while a brainstorm is live; read-only work stays open.
    @Test func planningAndWorkersWaitForTheEnd() async throws {
        let s = try started()
        for tool in ["update_plan", "task", "dispatch", "python", "write_file", "claim_finding"] {
            #expect(s.ideas.brainstormBlocker(tool: tool, input: [:]) != nil, "\(tool) must wait")
        }
        #expect(s.ideas.brainstormBlocker(tool: "bash", input: ["command": "rm -rf x"]) != nil)
        #expect(s.ideas.brainstormBlocker(tool: "bash", input: ["command": "ls -la"]) == nil)
        for tool in ["web_search", "literature_search", "paper_fetch", "read_file", "idea"] {
            #expect(s.ideas.brainstormBlocker(tool: tool, input: [:]) == nil)
        }
        // Through the session, the host refuses the call before it runs.
        let a = AgentSession(id: "main", role: .main, services: s, tools: BuiltinTools.all(), contextWindow: 100_000)
        let out = await a.runTools([ToolUse(id: "u1", name: "update_plan", input: ["goal": "g", "steps": [["id": "S1", "title": "t"]]])])
        let r = try #require(out.compactMap(\.toolResult).first)
        #expect(r.isError && r.content.contains("not part of brainstorming"))
        #expect(s.research.snapshot.steps.isEmpty)
        _ = s.ideas.end(summary: "", stopped: true)
        #expect(s.ideas.brainstormBlocker(tool: "update_plan", input: [:]) == nil)
    }

    /// A promoted idea's hypothesis survives a later `update_plan` that does not repeat it.
    @Test func planUpdateKeepsPromotedHypotheses() throws {
        let (s, _) = try makeServices()
        ground(s)
        let (_, h) = s.research.addHypothesis(statement: "promoted", prediction: "p", falsification: "f", rationale: "from idea I1")
        let hid = try #require(h?.id)
        let (gate, _) = s.research.setPlan(goal: "g", background: "", hypotheses: [], steps: [PlanStep(id: "S1", title: "test it", detail: "", status: "pending", checkpoint: true, criteria: "c", evidence: [], note: "")], rationale: "")
        #expect(gate == .allow)
        #expect(s.research.snapshot.hypotheses.contains { $0.id == hid })
    }

    /// The choice at the end of a brainstorm is not capped as a pre-plan question.
    @Test func reportQuestionIsNotAPrePlanDetour() async throws {
        let s = try started()
        s.asks.interactive = false
        for _ in 0..<(AskCenter.maxBeforePlan + 1) {
            let out = try await AskUserTool().run(["questions": [["header": "Pick", "question": "Which?", "kind": "single",
                                                                  "options": [["label": "A"], ["label": "B"]]]]], ctx(s))
            #expect(!out.text.contains("before planning"))
        }
    }

    @Test func oldSavedStateStillDecodes() throws {
        let json = #"{"id":"Babc","topic":"t","reason":"","trigger":"user","stage":"rank","stageNote":"","stagesDone":[],"startedAt":"2026-11-01T00:00:00Z","wrapUpRequested":false,"stopped":false}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let st = try d.decode(BrainstormState.self, from: Data(json.utf8))
        #expect(st.evolveRounds == nil && st.origin == "brainstorm:Babc")
    }
    /// Not every task needs novelty: the goal is settled first, and "what works best" checks evidence.
    @Test func theGoalIsSettledFirstAndWhatWorksBestChecksEvidence() async throws {
        let (s, _) = try makeServices()
        // No goal yet: the agent is told to ask the user.
        let refused = try await BrainstormTool().run(["action": "start", "topic": "target fishing", "reason": "open request"], ctx(s))
        #expect(refused.isError && refused.text.contains("is novelty required"))
        let started = try await BrainstormTool().run(["action": "start", "topic": "target fishing", "reason": "open request", "goal": "proven"], ctx(s))
        #expect(!started.isError && started.text.contains("what works best"))
        #expect(s.ideas.live?.order.contains("evidence") == true && s.ideas.live?.order.contains("novelty") == false)
        ground(s)
        _ = try await stage(s, "diverge")
        _ = try await addIdeas(s, 6)
        #expect(s.ideas.snapshot.allSatisfy { $0.aim == "proven" })
        _ = try await stage(s, "dedupe")
        _ = try await stage(s, "rank")
        let ids = s.ideas.snapshot.filter(\.isLive).map { JSON.string($0.id) }
        _ = try await IdeaTool().run(["action": "rank", "order": .array(ids)], ctx(s))
        // The novelty stage does not exist here; evidence takes its place and needs its work.
        #expect(try await stage(s, "novelty").text.contains("its check is stage evidence"))
        #expect(!(try await stage(s, "evidence")).isError)
        #expect(try await IdeaTool().run(["action": "novelty", "id": ids[0], "verdict": "known", "closest_prior": ["x"]], ctx(s)).text.contains("record `idea` evidence"))
        #expect(try await stage(s, "report").text.contains("Check the evidence for the top 3"))
        let rs = (0..<3).map { _ in s.ledger.record(tool: "web_search", args: [:], output: ToolOutput("ok"), role: .main, startedAt: Date().addingTimeInterval(5), duration: 0).id }
        // Support needs the published results it rests on.
        #expect(try await IdeaTool().run(["action": "evidence", "id": ids[0], "support": "established", "receipts": .array(rs.map { .string($0) })], ctx(s)).text.contains("Name the published results"))
        for id in ids.prefix(3) {
            let out = try await IdeaTool().run(["action": "evidence", "id": id, "support": "established", "results": ["[@lee2024] AUC 0.91 on DUD-E"],
                                                "receipts": .array(rs.map { .string($0) })], ctx(s))
            #expect(!out.isError, "\(out.text)")
        }
        let report = try await stage(s, "report")
        #expect(!report.isError && report.text.contains("recommended approach"))
        _ = try await BrainstormTool().run(["action": "end", "summary": "x"], ctx(s))
        // Prior work is expected here, so promotion does not ask for a novelty check.
        let ideaId = ids[0].stringValue ?? ""
        #expect(s.ideas.promotionBlocker(ideaId) == nil)
        _ = s.ideas.setSupport(ids[3].stringValue ?? "", .unproven, results: [], receipts: rs, ledger: s.ledger)
        #expect(s.ideas.promotionBlocker(ids[3].stringValue ?? "")?.contains("No published results") == true)
    }

    @Test func aDreamLooksForNewIdeasWithoutAsking() {
        let l = IdeaLedger()
        l.request(.dream)
        guard case .success(let st) = l.start(topic: "x", reason: "") else { Issue.record("a dream starts without a goal"); return }
        #expect(st.goal == .novel && st.order.contains("novelty"))
    }
}
