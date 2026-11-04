import Foundation
import Testing
@testable import SieveSciCore

/// Replies with one tool call, then with text.
private final class ToolThenTextProvider: LLMProvider, @unchecked Sendable {
    let profile = ProviderProfile(id: "fake", displayName: "fake", family: .openaiChat, baseURL: "http://localhost", auth: .none, apiKeyRef: "", models: ["m"])
    private let calls = LockedBox(0)
    let command: String
    init(command: String) { self.command = command }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        var n = 0
        calls.mutate { $0 += 1; n = $0 }
        let first = n == 1
        let command = self.command
        return AsyncThrowingStream { c in
            if first {
                let use = ToolUse(id: "call_1", name: "bash", input: ["command": .string(command)], echo: nil)
                c.yield(.completed(LLMResponse(message: Message(role: .assistant, blocks: [.toolUse(use)]), stopReason: .toolUse, usage: Usage(input: 10, output: 5))))
            } else {
                c.yield(.textDelta("done"))
                c.yield(.completed(LLMResponse(message: Message(role: .assistant, blocks: [.text("done")]), stopReason: .endTurn, usage: Usage(input: 10, output: 5))))
            }
            c.finish()
        }
    }
}

/// Drives a ServeServer the way a front end does and records what it writes.
private final class Client: @unchecked Sendable {
    let lines = LockedBox<[JSON]>([])
    var server: ServeServer!
    private var next = 0

    init(workspace: URL, provider: @escaping @Sendable () -> LLMProvider) {
        server = ServeServer(workspace: workspace, info: ["provider": "fake", "model": "m", "mode": "ask"], makeServices: { id in
            let s = try SessionServices(taskId: id, workspace: workspace, models: RoleModels(main: (provider(), "m")), secrets: EnvironmentSecretStore())
            s.research.groundingRequired = false
            s.delegation.auto = false
            return s
        }, write: { [lines] l in
            guard let j = try? JSONCodec.parse(l) else { Issue.record("not JSON: \(l)"); return }
            lines.mutate { $0.append(j) }
        })
    }

    /// Sends a request and waits for its response.
    func call(_ method: String, _ params: JSON = .object([:])) async throws -> JSON {
        next += 1
        let id = next
        await server.handle(JSONCodec.canonicalString(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params]))
        let r = try #require(lines.value.first { $0["id"]?.intValue == id })
        if let e = r["error"] { throw ServeTestError(message: e.str("message") ?? "?") }
        return r["result"] ?? .null
    }

    var events: [JSON] { lines.value.filter { $0.str("method") == "event" }.compactMap { $0["params"] } }

    func waitFor(_ timeout: TimeInterval = 20, _ match: (JSON) -> Bool) async -> JSON? {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            if let e = events.first(where: match) { return e }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }
}

private struct ServeTestError: Error { var message: String }

@Suite(.serialized) struct Serve {
    func workspace() throws -> URL {
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("serve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        return ws
    }

    @Test func turnStreamsAndTheTaskReopensWithItsHistory() async throws {
        let ws = try workspace()
        let c = Client(workspace: ws) { ScriptedProvider(replies: ["Hello from the model.", "again"]) }
        let info = try await c.call("initialize", ["client": "test"])
        #expect(info["protocol"]?.intValue == 1 && info.str("name") == "sievesci" && info.str("workspace") == ws.path)

        let opened = try await c.call("task.open")
        let task = try #require(opened.str("task"))
        #expect(opened["messages"]?.arrayValue?.isEmpty == true && opened["running"]?.boolValue == false)

        #expect(try await c.call("task.send", ["text": "Say hello"])["accepted"]?.boolValue == true)
        let done = await c.waitFor { $0.str("type") == "turnFinished" && $0.str("agentId") == "main" }
        #expect(done != nil, "the turn finishes")
        let text = c.events.filter { $0.str("type") == "textDelta" && $0.str("agentId") == "main" }.compactMap { $0.str("text") }.joined()
        #expect(text.contains("Hello from the model."))
        #expect(c.events.contains { $0.str("type") == "usage" && $0["meter"]?["contextWindow"]?.intValue != nil })

        let list = try await c.call("tasks.list")
        #expect(list["tasks"]?.arrayValue?.contains { $0.str("id") == task } == true)

        // Reopening replays the saved transcript.
        let again = try await c.call("task.open", ["id": .string(task)])
        let msgs = try #require(again["messages"]?.arrayValue)
        #expect(msgs.count >= 2 && msgs.first?.str("role") == "user")
        try await c.call("shutdown")
        #expect(c.server.isClosed)
    }

    @Test func permissionIsAskedAndAnswered() async throws {
        let ws = try workspace()
        let c = Client(workspace: ws) { ToolThenTextProvider(command: "echo serve-ok") }
        _ = try await c.call("task.open")
        _ = try await c.call("task.send", ["text": "run it"])
        let ask = try #require(await c.waitFor { $0.str("type") == "permissionRequested" })
        let req = try #require(ask["request"])
        #expect(req.str("tool") == "bash" && req["input"]?.str("command") == "echo serve-ok")
        _ = try await c.call("permission.respond", ["id": .string(req.str("id") ?? ""), "decision": "allow"])
        let finished = await c.waitFor { $0.str("type") == "toolFinished" && $0.str("name") == "bash" }
        #expect(finished?.str("output")?.contains("serve-ok") == true, "\(String(describing: finished))")
        #expect(await c.waitFor { $0.str("type") == "turnFinished" && $0.str("agentId") == "main" } != nil)
        try await c.call("shutdown")
    }

    @Test func refusalsAndBadInput() async throws {
        let ws = try workspace()
        let c = Client(workspace: ws) { ScriptedProvider(replies: []) }
        await #expect(throws: ServeTestError.self) { try await c.call("task.send", ["text": "hi"]) }
        await #expect(throws: ServeTestError.self) { try await c.call("task.open", ["id": "../outside"]) }
        await #expect(throws: ServeTestError.self) { try await c.call("no.such") }
        await c.server.handle("not json")
        #expect(c.lines.value.contains { $0["error"]?["code"]?.intValue == -32700 })
        // Ask outcomes use explicit kinds, not Swift's enum coding.
        #expect(Wire.askOutcome(["kind": "answered", "answers": [["questionId": "q1", "selected": ["A"]]]]) == .answered([AskAnswer(questionId: "q1", selected: ["A"])]))
        #expect(Wire.askOutcome(["kind": "dismissed"]) == .dismissed(nil))
        #expect(Wire.ask(.dismissed("later")).str("kind") == "dismissed")
    }
}
