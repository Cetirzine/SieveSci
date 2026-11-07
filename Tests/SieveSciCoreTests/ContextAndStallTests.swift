import Foundation
import Testing
@testable import SieveSciCore

/// A provider whose first `hangs` requests never answer (or close without a final message), then replies.
final class FlakyProvider: LLMProvider, @unchecked Sendable {
    let profile = ProviderProfile(id: "flaky", displayName: "flaky", family: .anthropic, baseURL: "http://localhost", auth: .none, apiKeyRef: "", models: ["m"])
    private let lock = NSLock()
    private var calls = 0
    let failures: Int, hang: Bool
    var count: Int { lock.withLock { calls } }
    init(failures: Int, hang: Bool) { self.failures = failures; self.hang = hang }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let n = lock.withLock { calls += 1; return calls }
        let fail = n <= failures, hang = self.hang
        return AsyncThrowingStream { c in
            if fail {
                if !hang { c.finish() }   // closed without a final message
                return                    // hang: never yields, never finishes
            }
            c.yield(.textDelta("ok"))
            c.yield(.completed(LLMResponse(message: .assistant("ok"), stopReason: .endTurn, usage: Usage(input: 10, output: 2))))
            c.finish()
        }
    }
}

@Suite struct ReopenedContext {
    @Test func aReopenedTaskResumesFromItsLastCompaction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SessionStore.shared
        for i in 0..<6 { store.append(.user("old \(i)"), task: "t", agent: "main", dir: dir) }
        store.markCompaction([.user("<session_summary>…</session_summary>"), .assistant("recent")], epoch: 1, agent: "main", dir: dir)
        store.append(.user("after"), task: "t", agent: "main", dir: dir)

        let context = SessionStore.loadContext(dir: dir, agent: "main")
        #expect(context.map(\.plainText) == ["<session_summary>…</session_summary>", "recent", "after"])
        let shown = SessionStore.load(dir: dir, agent: "main")
        #expect(shown.count == 7, "the whole conversation stays for display and export; the mark is not a message")
        #expect(shown.first?.plainText == "old 0" && shown.last?.plainText == "after")
    }

    @Test func aRestoredSessionKnowsItsSizeBeforeTheFirstCall() throws {
        let (s, _) = try makeServices()
        let a = AgentSession(id: "main", role: .main, services: s, tools: [])
        a.restore([.user(String(repeating: "word ", count: 30_000)), .assistant("done")])
        #expect(a.meter.lastPromptTokens > 40_000, "estimated from the restored transcript, not 0")
    }

    @Test func providerOverflowWordingsAreRecognised() {
        #expect(ProviderError.isContextOverflow(ProviderError.protocolError("The input (1058608 tokens) is longer than the model's context length (1048576 tokens).")))
        #expect(ProviderError.isContextOverflow(ProviderError.http(status: 400, body: #"{"error":{"message":"prompt is too long: 210000 tokens > 200000 maximum"}}"#)))
        #expect(ProviderError.isContextOverflow(ProviderError.http(status: 400, body: #"{"error":{"code":"context_length_exceeded"}}"#)))
        #expect(!ProviderError.isContextOverflow(ProviderError.http(status: 429, body: "rate limited")))
    }
}

@Suite struct SilentStreams {
    @Test func aSilentStreamIsStopped() async throws {
        let p = FlakyProvider(failures: 1, hang: true)
        let req = LLMRequest(model: "m", system: "s", tools: [], messages: [.user("hi")], maxTokens: 10, cache: CacheHints(lineageKey: "l"))
        let started = Date()
        await #expect(throws: ProviderError.self) {
            try await StreamWatch.$stallLimit.withValue(0.4) { try await p.complete(req) }
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func theAgentAsksAgainWhenNothingCameBack() async throws {
        for hang in [true, false] {
            let p = FlakyProvider(failures: 1, hang: hang)
            let (s, _) = try makeServices(p)
            let a = AgentSession(id: "main", role: .main, services: s, tools: [])
            let reply = try await StreamWatch.$stallLimit.withValue(0.4) { try await a.send("hello") }
            #expect(reply?.plainText == "ok")
            #expect(p.count == 2)
        }
    }
}

/// Replies from a list: a tool call (`"tool"`) or text.
final class StepProvider: LLMProvider, @unchecked Sendable {
    let profile = ProviderProfile(id: "steps", displayName: "steps", family: .anthropic, baseURL: "http://localhost", auth: .none, apiKeyRef: "", models: ["m"])
    private let lock = NSLock()
    private var replies: [String]
    private(set) var requests: [LLMRequest] = []
    var onCall: (@Sendable (Int) -> Void)?
    init(_ replies: [String]) { self.replies = replies }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let (r, n) = lock.withLock { () -> (String, Int) in requests.append(request); return (replies.isEmpty ? "done" : replies.removeFirst(), requests.count) }
        onCall?(n)
        let msg: Message = r == "tool"
            ? Message(role: .assistant, blocks: [.toolUse(ToolUse(id: "t\(n)", name: "glob", input: ["pattern": "*.none"]))])
            : .assistant(r)
        return AsyncThrowingStream { c in
            c.yield(.completed(LLMResponse(message: msg, stopReason: r == "tool" ? .toolUse : .endTurn, usage: Usage(input: 10, output: 2))))
            c.finish()
        }
    }
}

@Suite struct InsertDuringATurn {
    func lastUserText(_ r: LLMRequest) -> String {
        r.messages.last { $0.role == .user }?.blocks.compactMap { b -> String? in if case .text(let t) = b { return t }; return nil }.joined() ?? ""
    }

    @Test func anInsertReachesTheNextStep() async throws {
        let p = StepProvider(["tool", "ok"])
        let (s, _) = try makeServices(p)
        let a = AgentSession(id: "main", role: .main, services: s, tools: BuiltinTools.all())
        p.onCall = { n in if n == 1 { a.insert("use the 2024 data instead") } }   // typed while the first call runs
        let reply = try await a.send("analyse the data")
        #expect(reply?.plainText == "ok")
        #expect(p.requests.count == 2)
        let second = lastUserText(p.requests[1])
        #expect(second.contains("<user_insert>") && second.contains("use the 2024 data instead"), "read at the next step, after the tool result")
        #expect(!lastUserText(p.requests[0]).contains("2024"))
    }

    @Test func aReplyThatEndsMeanwhileContinuesWithTheInsert() async throws {
        let p = StepProvider(["first answer", "revised answer"])
        let (s, _) = try makeServices(p)
        let a = AgentSession(id: "main", role: .main, services: s, tools: [])
        p.onCall = { n in if n == 1 { a.insert("also cite sources") } }
        let reply = try await a.send("question")
        #expect(reply?.plainText == "revised answer")
        #expect(lastUserText(p.requests[1]).contains("also cite sources"))
        #expect(a.takeInserts().isEmpty)
    }
}

/// Two tool calls in one step; the agent is stopped while the first runs.
final class TwoCallProvider: LLMProvider, @unchecked Sendable {
    let profile = ProviderProfile(id: "two", displayName: "two", family: .anthropic, baseURL: "http://localhost", auth: .none, apiKeyRef: "", models: ["m"])
    let calls = LockedBox(0)
    var onCall: (@Sendable () -> Void)?
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        calls.mutate { $0 += 1 }
        onCall?()   // Stop pressed while this reply streams
        let msg = Message(role: .assistant, blocks: [.toolUse(ToolUse(id: "a", name: "bash", input: ["command": "sleep 2"])),
                                                     .toolUse(ToolUse(id: "b", name: "glob", input: ["pattern": "*"]))])
        return AsyncThrowingStream { c in
            c.yield(.completed(LLMResponse(message: msg, stopReason: .toolUse, usage: Usage(input: 10, output: 2))))
            c.finish()
        }
    }
}

@Suite struct StopEndsTheTurn {
    @Test func stopMidStepSkipsTheRestAndReportsTheEnd() async throws {
        let p = TwoCallProvider()
        let (s, _) = try makeServices(p)
        s.permissions.mode = .yolo
        let finished = LockedBox<[String]>([])
        s.emit = { e in if case .turnFinished(let id, _) = e { finished.mutate { $0.append(id) } } }
        let a = AgentSession(id: "main", role: .main, services: s, tools: BuiltinTools.all())
        p.onCall = { a.cancel() }
        _ = try? await a.send("go")
        #expect(finished.value == ["main"], "the front end hears the turn end")
        #expect(p.calls.value == 1, "no further model call after Stop")
        #expect(s.subagents.isStopped)
    }

    @Test func aTurnEndedByAnErrorStillReportsItsEnd() async throws {
        final class Failing: LLMProvider, @unchecked Sendable {
            let profile = ProviderProfile(id: "f", displayName: "f", family: .anthropic, baseURL: "http://localhost", auth: .none, apiKeyRef: "", models: ["m"])
            func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
                AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
            }
        }
        let (s, _) = try makeServices(Failing())
        let finished = LockedBox<[String]>([])
        s.emit = { e in if case .turnFinished(let id, _) = e { finished.mutate { $0.append(id) } } }
        let a = AgentSession(id: "main", role: .main, services: s, tools: [])
        await #expect(throws: (any Error).self) { try await a.send("go") }
        #expect(finished.value == ["main"])
    }
}
