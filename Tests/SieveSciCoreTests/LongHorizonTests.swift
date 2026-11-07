import Foundation
import Testing
@testable import SieveSciCore

/// Long tasks keep their thread: the objective and what the user decided are recited and survive
/// compaction; an agent that lost its context is handed the task back instead of asking for it; repeated
/// idea reviews go back to the user instead of drifting away from their choice. (From a session where a
/// brainstorm's chosen direction was revised three times, the context was compacted, and the agent then
/// asked the user what the task was.)
@Suite struct LongHorizon {
    func services() throws -> SessionServices {
        let (s, _) = try makeServices()
        s.research.groundingRequired = false
        return s
    }

    func ctx(_ s: SessionServices) -> ToolContext {
        ToolContext(workspace: s.workspace, sessionId: "main", role: .main, ledger: s.ledger, audit: s.audit, services: s)
    }

    let request = "大语言模型的新架构可以有什么新创新可以降低推理/训练成本，头脑风暴思考一下"

    @Test func decisionsAreRecitedBesideTheObjective() throws {
        let s = try services()
        s.research.recordUserRequest(request, scale: .research)
        s.research.recordDecision(UserDecision(topic: "选方向", answer: "I19 裁定 Engram–Metis 冲突", ideas: ["I19"]))
        let render = TurnContext.render(services: s, model: "any-model")
        #expect(render.contains("objective (the user's request; fixed): 大语言模型的新架构"))
        #expect(render.contains("the user decided: 选方向: I19 裁定 Engram–Metis 冲突 [I19]"))
        // A host-started turn (recovery, job wake-up) restates the user's request, not the host's note.
        let refresh = TurnContext.refresh(services: s, request: "<recovery>The last step failed…</recovery>", steps: 12)
        #expect(refresh.contains("objective (the user's request; fixed)") && refresh.contains("[I19]"))
        #expect(!refresh.contains("<recovery>"))
        #expect(s.research.snapshot.markdown.contains("**User decisions**"))
    }

    @Test func everyModelGetsTheRestatement() {
        #expect(AgentSession.refreshEvery("claude-opus-5-5") == AgentSession.defaultRefreshEvery)
        #expect(AgentSession.refreshEvery("naive-n0.5-flash") == 10)
    }

    @Test func noGoalLoopIsNotNoTask() async throws {
        let s = try services()
        #expect(try await GoalTool().run(["action": "get"], ctx(s)).text == "No goal set.")
        s.research.recordUserRequest(request, scale: .research)
        let out = try await GoalTool().run(["action": "get"], ctx(s)).text
        #expect(out.contains("That does not mean there is no task") && out.contains("大语言模型的新架构"))
    }

    @Test func askingWhatTheTaskIsGetsTheTaskBack() async throws {
        let s = try services()
        s.asks.interactive = true
        s.research.recordUserRequest(request, scale: .research)
        let lost: JSON = ["questions": [["header": "Task", "kind": "text", "reason": "missing_value",
                                         "question": "What research question or task would you like me to work on in this workspace?"]]]
        #expect(AskUserTool.asksForTheTask("What research question or task would you like me to work on in this workspace?"))
        // Never left waiting for an answer if the guard misses: nobody is there to answer in a test.
        s.asks.interactive = false
        let out = try await AskUserTool().run(lost, ctx(s))
        #expect(out.isError && out.text.contains("The task is on record") && out.text.contains("大语言模型的新架构"))
        #expect(s.asks.pending.isEmpty, "the user was not asked")
        #expect(AskUserTool.asksForTheTask("你想让我做什么？"))
        #expect(!AskUserTool.asksForTheTask("你想研究哪个物种？"))
        #expect(!AskUserTool.asksForTheTask("How many cells per well?"))
    }

    @Test func answersBecomeDecisions() async throws {
        let s = try services()
        s.asks.interactive = true
        s.emit = { ev in
            if case .askRequested(let r) = ev {
                Task { s.asks.resolve(r.id, .answered([AskAnswer(questionId: r.questions[0].id, selected: ["I19 裁定冲突"])])) }
            }
        }
        _ = s.research.noteIdeaReviewFailed()
        let q: JSON = ["questions": [["header": "选方向", "question": "选哪条？", "kind": "multi",
                                      "options": [["label": "I19 裁定冲突", "idea": "I19"], ["label": "I4 角色分精度", "idea": "I4"]]]]]
        _ = try await AskUserTool().run(q, ctx(s))
        let d = s.research.decisions
        #expect(d.count == 1 && d[0].topic == "选方向" && d[0].ideas == ["I19"])
        #expect(s.research.snapshot.ideaReviewsSinceDecision == 0, "a new decision resets the review count")
    }

    @Test func repeatedReviewsGoBackToTheUser() {
        #expect(IdeaTool.backToTheUser(1).isEmpty)
        #expect(IdeaTool.backToTheUser(2).contains("ask_user"))
    }

    @Test func compactionKeepsTheDecisions() throws {
        let s = try services()
        s.research.recordUserRequest(request, scale: .research)
        s.research.recordDecision(UserDecision(topic: "brainstorm outcome", answer: "用户选定 I19"))
        // The state that goes into the compacted context is the rendered turn context.
        #expect(TurnContext.render(services: s, model: "m").contains("brainstorm outcome: 用户选定 I19"))
    }

    @Test func readingThisConversationBackIsRefused() async throws {
        let s = try services()
        let out = try await SessionReadTool().run(["id": .string(s.taskId)], ctx(s))
        #expect(out.isError || out.text.contains("No single conversation"))
    }

    @Test func aSectionSignInsideALessonDoesNotSplitIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString)")
        let mem = MemoryStore(dir: dir)
        _ = try mem.apply(.add, store: .lessons, text: "旧稿 §1.2/§3/§4.5 的数字无回执", match: nil)
        _ = try mem.apply(.add, store: .lessons, text: "第二条\n§\n不应被拆开", match: nil)
        let es = mem.entries(.lessons)
        #expect(es == ["旧稿 §1.2/§3/§4.5 的数字无回执", "第二条\nSec.\n不应被拆开"])
        #expect(MemoryStore.split("a\n§\nb §2 c\n  §  \nd") == ["a", "b §2 c", "d"])
    }
}
