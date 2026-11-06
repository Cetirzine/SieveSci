import Foundation
import Testing
@testable import SieveSciCore

/// A tool that only reads, and counts how many of its calls run at once.
private struct ProbeTool: Tool {
    let name: String
    let description = "probe"
    let concurrent: Bool
    let inFlight: LockedBox<Int>, peak: LockedBox<Int>
    var delayNs: UInt64 = 5_000_000
    var inputSchema: JSON { Schema.object(["q": Schema.string("q")]) }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func runsConcurrently(for input: JSON) -> Bool { concurrent }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        inFlight.mutate { $0 += 1 }
        let now = inFlight.value
        peak.mutate { $0 = max($0, now) }
        if delayNs > 0 { try? await Task.sleep(nanoseconds: delayNs) }
        inFlight.mutate { $0 -= 1 }
        return ToolOutput("ok")
    }
}

private func session(_ tools: [Tool]) throws -> AgentSession {
    let (s, _) = try makeServices()
    s.research.groundingRequired = false
    return AgentSession(id: "main", role: .main, services: s, tools: tools, contextWindow: 100_000)
}

@Suite struct ConcurrentToolCalls {
    /// 0.2.1 crashed here: identical read-only calls in one step updated the repeat counter at once.
    @Test func identicalReadOnlyCallsInOneStepDoNotRace() async throws {
        // Instant calls with many distinct keys make the counter dictionary grow (and rehash) while
        // other calls update it — the exact collision in the crash report.
        let probe = ProbeTool(name: "probe", concurrent: true, inFlight: LockedBox(0), peak: LockedBox(0), delayNs: 0)
        let a = try session([probe])
        for round in 0..<40 {
            let uses = (0..<64).map { ToolUse(id: "c\(round)-\($0)", name: "probe", input: ["q": .string("\(round)-\($0 % 48)")]) }
            let results = await a.runTools(uses)
            #expect(results.compactMap(\.toolResult).map(\.toolUseId) == uses.map(\.id), "results stay in call order")
        }
        let slow = ProbeTool(name: "slow", concurrent: true, inFlight: LockedBox(0), peak: LockedBox(0))
        let b = try session([slow])
        _ = await b.runTools((0..<4).map { ToolUse(id: "p\($0)", name: "slow", input: ["q": .string("\($0)")]) })
        #expect(slow.peak.value > 1, "pure reads still run concurrently")
    }

    @Test func theRepeatGuardCountsEveryConcurrentCall() async throws {
        let probe = ProbeTool(name: "probe", concurrent: true, inFlight: LockedBox(0), peak: LockedBox(0))
        let a = try session([probe])
        let uses = (0..<8).map { ToolUse(id: "r\($0)", name: "probe", input: ["q": "same"]) }
        let texts = await a.runTools(uses).compactMap(\.toolResult).map(\.content)
        let notices = texts.filter { $0.contains("<repeat_notice>") }
        #expect(notices.count == 3, "one notice each at the 3rd, 5th and 8th identical call, none lost")
        for n in [3, 5, 8] { #expect(notices.contains { $0.contains("this exact call \(n) times") }) }
    }

    @Test func statefulReadOnlyToolsRunInOrder() async throws {
        let serial = ProbeTool(name: "stateful", concurrent: false, inFlight: LockedBox(0), peak: LockedBox(0))
        let pure = ProbeTool(name: "pure", concurrent: true, inFlight: LockedBox(0), peak: LockedBox(0))
        let a = try session([serial, pure])
        _ = await a.runTools((0..<4).map { ToolUse(id: "s\($0)", name: "stateful", input: ["q": .string("\($0)")]) })
        #expect(serial.peak.value == 1)
        // One stateful call in the step makes the whole step run in order.
        _ = await a.runTools([ToolUse(id: "m1", name: "pure", input: ["q": "a"]), ToolUse(id: "m2", name: "stateful", input: ["q": "b"]),
                              ToolUse(id: "m3", name: "pure", input: ["q": "c"])])
        #expect(pure.peak.value == 1)
    }

    @Test func toolsThatChangeSessionStateAreNotRunConcurrently() {
        let names = ["respond_review", "update_plan", "todo_write", "goal", "idea", "brainstorm", "ideation_seeds", "ask_user", "memory", "skill_manage"]
        var tools: [String: Tool] = [:]
        for t in BuiltinTools.all() + [RespondReviewTool() as Tool] { tools[t.name] = t }
        for n in names {
            guard let t = tools[n] else { Issue.record("no tool \(n)"); continue }
            #expect(t.effect(for: [:]) == .readOnly, "\(n) stays allowed in plan mode and for reviewers")
            #expect(!t.runsConcurrently(for: [:]), "\(n) must run in order")
        }
        for n in ["read_file", "grep", "glob", "web_search", "literature_search", "paper_fetch"] {
            guard let t = tools[n] else { continue }
            #expect(t.runsConcurrently(for: [:]), "\(n) is a pure read")
        }
    }
}

@Suite struct TranscriptRepairs {
    static func call(_ ids: String...) -> Message {
        Message(role: .assistant, blocks: [.text("checking")] + ids.map { .toolUse(ToolUse(id: $0, name: "respond_review", input: ["id": "rv1"])) })
    }
    static func results(_ ids: String...) -> Message {
        Message(role: .user, blocks: ids.map { .toolResult(ToolResult(toolUseId: $0, content: "done \($0)")) })
    }

    @Test func aWellFormedTranscriptIsUnchanged() {
        let t = [Message.user("q"), Self.call("a", "b"), Self.results("a", "b"), Message.assistant("answer"), Message.user("next")]
        let r = TranscriptRepair.repair(t)
        #expect(!r.changed && r.appended == nil)
        #expect(r.messages == t, "same messages and ids: the prompt cache is kept")
    }

    /// The incident: the app died after the calls and before their results were saved.
    @Test func callsAtTheEndGetANotRecordedResult() {
        let t = [Message.user("q"), Self.call("call_00", "call_01")]
        let r = TranscriptRepair.repair(t)
        #expect(r.closed == ["call_00", "call_01"])
        let patch = try? #require(r.appended)
        #expect(r.messages.last == patch)
        #expect(patch?.blocks.compactMap(\.toolResult).map(\.toolUseId) == ["call_00", "call_01"])
        #expect(patch?.blocks.compactMap(\.toolResult).allSatisfy { $0.isError && $0.content.hasPrefix("Not recorded") } == true)
        #expect(!TranscriptRepair.repair(r.messages).changed, "repairing twice changes nothing")
    }

    /// After the restart the user pressed "continue" twice; both were saved after the open calls.
    @Test func callsFollowedByNewQuestionsAreAnsweredInPlace() {
        let t = [Message.user("q"), Self.call("call_00", "call_01"), Message.user("继续"), Message.user("继续")]
        let r = TranscriptRepair.repair(t)
        #expect(r.appended == nil && r.closed.count == 2)
        #expect(r.messages.count == 4)
        let fixed = r.messages[2]
        #expect(fixed.id == t[2].id)
        #expect(fixed.blocks.compactMap(\.toolResult).map(\.toolUseId) == ["call_00", "call_01"])
        #expect(fixed.blocks.last?.text == "继续", "the user's words follow the results")
        #expect(r.messages[3] == t[3])
    }

    @Test func partialResultsAreCompletedAndStrayOnesDropped() {
        let t = [Self.call("a", "b"), Self.results("b", "zzz"), Message.assistant("x"), Self.results("orphan")]
        let r = TranscriptRepair.repair(t)
        #expect(r.closed == ["a"])
        #expect(Set(r.dropped) == ["zzz", "orphan"])
        #expect(r.messages[1].blocks.compactMap(\.toolResult).map(\.toolUseId) == ["a", "b"], "results in call order")
        #expect(r.messages[1].blocks.compactMap(\.toolResult).last?.content == "done b", "the saved result is kept")
        #expect(r.messages.count == 3, "a message of only stray results is removed")
    }

    @Test func twoAssistantMessagesInARow() {
        let r = TranscriptRepair.repair([Self.call("a"), Message.assistant("then this")])
        #expect(r.closed == ["a"])
        #expect(r.messages.map(\.role) == [.assistant, .user, .assistant])
    }

    @Test func restoringASessionClosesOpenCalls() throws {
        let a = try session([])
        a.restore([Message.user("q"), Self.call("call_00")])
        #expect(a.transcript.last?.blocks.first?.toolResult?.toolUseId == "call_00")
    }
}
