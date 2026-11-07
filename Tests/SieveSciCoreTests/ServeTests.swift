import Foundation
import Testing
@testable import SieveSciCore

/// Replies with one tool call, then with text.
private final class ToolThenTextProvider: LLMProvider, @unchecked Sendable {
    let profile = ProviderProfile(id: "fake", displayName: "fake", family: .openaiChat, baseURL: "http://localhost", auth: .none, apiKeyRef: "", models: ["m"])
    private let calls = LockedBox(0)
    let command: String
    /// Every turn starts with the tool call (odd calls), not only the first.
    let everyTurn: Bool
    init(command: String, everyTurn: Bool = false) { self.command = command; self.everyTurn = everyTurn }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        var n = 0
        calls.mutate { $0 += 1; n = $0 }
        let first = everyTurn ? n % 2 == 1 : n == 1
        let command = self.command
        return AsyncThrowingStream { c in
            if first {
                let use = ToolUse(id: "call_\(n)", name: "bash", input: ["command": .string(command)], echo: nil)
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
        server = ServeServer(workspace: workspace, info: ["provider": "fake", "model": "m", "mode": "ask"], config: AppConfig(), saveConfig: false,
                             secrets: EnvironmentSecretStore(), keyStore: nil, makeServices: { id, ws, _ in
            let s = try SessionServices(taskId: id, workspace: ws, models: RoleModels(main: (provider(), "m")), secrets: EnvironmentSecretStore())
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
    var statuses: [JSON] { lines.value.filter { $0.str("method") == "taskStatus" }.compactMap { $0["params"] } }

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

/// Answers after a second, so a turn is still running when the client moves on.
private final class SlowProvider: LLMProvider, @unchecked Sendable {
    let profile = ProviderProfile(id: "fake", displayName: "fake", family: .openaiChat, baseURL: "http://localhost", auth: .none, apiKeyRef: "", models: ["m"])
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { c in
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                c.yield(.textDelta("slow"))
                c.yield(.completed(LLMResponse(message: Message(role: .assistant, blocks: [.text("slow")]), stopReason: .endTurn, usage: Usage(input: 1, output: 1))))
                c.finish()
            }
        }
    }
}

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
        #expect(info["protocol"]?.intValue == 2 && info.str("name") == "sievesci" && info.str("workspace") == ws.path)
        #expect(info["sandbox"]?.boolValue == Seatbelt.available)

        let opened = try await c.call("task.open")
        let task = try #require(opened.str("task"))
        #expect(opened["history"]?.arrayValue?.isEmpty == true && opened["running"]?.boolValue == false)
        #expect(opened["meter"]?["model"]?.stringValue?.isEmpty == false, "the composer shows the model before the first reply")

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
        let items = try #require(again["history"]?.arrayValue)
        #expect(items.map { $0.str("kind") ?? "" } == ["user", "assistant"], "\(items)")
        #expect(items.first?.str("text") == "Say hello", "host context is not shown")
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

    @Test func configurationAndWorkspaces() async throws {
        let ws = try workspace(), other = try workspace()
        let c = Client(workspace: ws) { ScriptedProvider(replies: []) }
        let got = try await c.call("config.get")
        #expect(got["config"]?.str("permissionMode") == "ask" && got["status"]?["models"]?["ready"]?.boolValue == false)
        let set = try await c.call("config.set", ["patch": ["permissionMode": "plan", "showThinking": false]])
        #expect(set["config"]?.str("permissionMode") == "plan" && set["config"]?["showThinking"]?.boolValue == false)
        await #expect(throws: ServeTestError.self) { try await c.call("config.set", ["patch": ["permissionMode": "sideways"]]) }
        #expect(try await c.call("config.set", ["patch": ["effort": "high"]])["config"]?.str("effort") == "high")
        #expect(try await c.call("config.set", ["patch": ["effort": .null]])["config"]?["effort"] == nil)   // back to the default
        await #expect(throws: ServeTestError.self) { try await c.call("language.set", ["language": "klingon"]) }
        let opened = try await c.call("workspace.open", ["path": .string(other.path)])
        #expect(opened.str("workspace") == other.standardizedFileURL.path && opened["tasks"]?.arrayValue?.isEmpty == true)
        #expect(try await c.call("config.get")["config"]?["recentWorkspaces"]?.arrayValue?.first?.stringValue == other.standardizedFileURL.path)
        // Reopening a listed folder keeps the list's order (the sidebar does not reshuffle).
        _ = try await c.call("workspace.open", ["path": .string(ws.path)])
        let before = try await c.call("config.get")["config"]?["recentWorkspaces"]?.arrayValue?.compactMap(\.stringValue) ?? []
        _ = try await c.call("workspace.open", ["path": .string(other.path)])
        #expect(try await c.call("config.get")["config"]?["recentWorkspaces"]?.arrayValue?.compactMap(\.stringValue) == before)
        await #expect(throws: ServeTestError.self) { try await c.call("workspace.open", ["path": "/no/such/folder"]) }
        await #expect(throws: ServeTestError.self) { try await c.call("secrets.set", ["ref": "X_KEY", "value": "v"]) }
    }

    @Test func settingsRequests() async throws {
        let ws = try workspace()
        let c = Client(workspace: ws) { ScriptedProvider(replies: []) }
        let added = try await c.call("providers.add", ["source": "custom", "name": "My Relay", "baseURL": "https://relay.example.com/v1", "family": "anthropic"])
        #expect(added.str("id") == "my-relay")
        let relay = added["config"]?["providers"]?.arrayValue?.first { $0.str("id") == "my-relay" }
        #expect(relay?.str("apiKeyRef") == "MY_RELAY_API_KEY" && relay?.str("auth") == "xApiKey" && relay?.str("billing") == "relay")
        #expect(added["providers"]?["my-relay"]?["ready"]?.boolValue == false)
        #expect(try await c.call("providers.add", ["source": "custom", "name": "My Relay", "baseURL": "https://other.example.com"]).str("id")?.hasPrefix("my-relay-") == true)
        #expect(try await c.call("providers.detectOptions", ["family": "anthropic", "baseURL": "https://api.anthropic.com"])["options"]?["anthropicCacheControl"]?.boolValue == true)
        let overview = try await c.call("models.overview")
        #expect(overview["roles"]?["main"] != nil && overview["benchmarks"]?.arrayValue?.isEmpty == false)
        #expect(try await c.call("connectors.list")["connectors"]?.arrayValue?.isEmpty == false)
        await #expect(throws: ServeTestError.self) { try await c.call("providers.test", ["id": "nope"]) }
        await #expect(throws: ServeTestError.self) { try await c.call("system.open", ["url": "file:///etc/passwd"]) }
    }

    @Test func panelData() async throws {
        let ws = try workspace()
        try "x,y\n1,2\n".write(to: ws.appendingPathComponent("data.csv"), atomically: true, encoding: .utf8)
        let c = Client(workspace: ws) { ScriptedProvider(replies: ["Done."]) }
        _ = try await c.call("task.open")
        _ = try await c.call("task.send", ["text": "Summarise the data"])
        #expect(await c.waitFor { $0.str("type") == "turnFinished" && $0.str("agentId") == "main" } != nil)
        let trace = try await c.call("panels.trace", ["offset": 0])
        #expect(trace["events"]?.arrayValue?.contains { $0.str("actor") == "user" } == true)
        let again = try await c.call("panels.trace", ["offset": trace["offset"] ?? 0])
        #expect(again["events"]?.arrayValue?.isEmpty == true)   // incremental: nothing new
        let files = try await c.call("files.list")
        #expect(files["entries"]?.arrayValue?.contains { $0.str("name") == "data.csv" } == true)
        #expect(files["entries"]?.arrayValue?.contains { $0.str("name") == ".sievesci" } == false)
        #expect(try await c.call("files.read", ["path": "data.csv"]).str("text") == "x,y\n1,2\n")
        await #expect(throws: ServeTestError.self) { try await c.call("files.read", ["path": "/etc/hosts"]) }
        await #expect(throws: ServeTestError.self) { try await c.call("files.list", ["path": "../"]) }
        #expect(try await c.call("panels.changes")["files"]?.arrayValue != nil)
        #expect(try await c.call("panels.notebook").str("path")?.hasSuffix("notebook.md") == true)
        try await c.call("shutdown")
    }

    @Test func renameForkAndMarkdown() async throws {
        let ws = try workspace()
        let c = Client(workspace: ws) { ScriptedProvider(replies: ["Reply one."]) }
        let task = try #require(try await c.call("task.open").str("task"))
        _ = try await c.call("task.send", ["text": "First question"])
        #expect(await c.waitFor { $0.str("type") == "turnFinished" && $0.str("agentId") == "main" } != nil)
        #expect(try await c.call("task.rename", ["id": .string(task), "title": "My name"]).str("title") == "My name")
        #expect(try await c.call("tasks.list")["tasks"]?.arrayValue?.first { $0.str("id") == task }?.str("title") == "My name")
        let fork = try #require(try await c.call("task.fork", ["id": .string(task)]).str("task"))
        let md = try await c.call("task.markdown", ["id": .string(fork)]).str("markdown") ?? ""
        #expect(md.contains("First question") && md.contains("Reply one."), "\(md)")
        try await c.call("shutdown")
    }

    @Test func stagesFollowAPermissionRequest() async throws {
        let ws = try workspace()
        let c = Client(workspace: ws) { ToolThenTextProvider(command: "echo stage-ok") }
        _ = try await c.call("task.open")
        _ = try await c.call("task.send", ["text": "run it"])
        let ask = try #require(await c.waitFor { $0.str("type") == "permissionRequested" })
        let t0 = Date()
        while !c.statuses.contains(where: { $0["stage"]?.str("kind") == "answer" }), Date().timeIntervalSince(t0) < 10 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(c.statuses.contains { $0["stage"]?.str("kind") == "answer" && $0["stage"]?["needsPerson"]?.boolValue == true }, "\(c.statuses)")
        #expect(ask.str("task") != nil && ask.str("workspace") == ws.standardizedFileURL.path)
        _ = try await c.call("permission.respond", ["id": .string(ask["request"]?.str("id") ?? ""), "decision": "allow"])
        #expect(await c.waitFor { $0.str("type") == "turnFinished" && $0.str("agentId") == "main" } != nil)
        try await c.call("shutdown")
    }

    @Test func aWaitingApprovalSurvivesASwitchAndStopAnswersIt() async throws {
        let ws = try workspace()
        let c = Client(workspace: ws) { ToolThenTextProvider(command: "echo stage-ok") }
        let first = try #require(try await c.call("task.open").str("task"))
        _ = try await c.call("task.send", ["text": "run it"])
        let ask = try #require(await c.waitFor { $0.str("type") == "permissionRequested" })
        let id = try #require(ask["request"]?.str("id"))
        // Another task is shown, then this one again: the approval it waits for comes back with it.
        _ = try await c.call("task.open")
        let again = try await c.call("task.open", ["id": .string(first)])
        #expect(again["permission"]?.str("id") == id, "\(again["permission"] ?? .null)")
        // Stop answers it, so the turn ends instead of waiting for a prompt no one sees.
        _ = try await c.call("task.stop")
        #expect(await c.waitFor { $0.str("type") == "turnFinished" && $0.str("task") == first && $0.str("agentId") == "main" } != nil)
        try await c.call("shutdown")
    }

    @Test func aRequestNamingItsTaskNeverReachesAnother() async throws {
        let ws = try workspace()
        let c = Client(workspace: ws) { ScriptedProvider(replies: ["one", "two"]) }
        let first = try #require(try await c.call("task.open").str("task"))
        let second = try #require(try await c.call("task.open").str("task"))   // the first, idle, is released
        let path = ws.standardizedFileURL.path
        // The window still shows the first: its message must not land in the second.
        await #expect(throws: ServeTestError.self) { try await c.call("task.send", ["text": "hello", "task": .string(first), "workspace": .string(path)]) }
        #expect(try await c.call("task.send", ["text": "hello", "task": .string(second), "workspace": .string(path)])["accepted"]?.boolValue == true)
        #expect(await c.waitFor { $0.str("type") == "turnFinished" && $0.str("task") == second && $0.str("agentId") == "main" } != nil)
        try await c.call("shutdown")
    }

    @Test func switchingToAutoReachesTheLiveTask() async throws {
        let ws = try workspace()
        let c = Client(workspace: ws) { ToolThenTextProvider(command: "echo mode-ok", everyTurn: true) }
        let task = try #require(try await c.call("task.open").str("task"))
        _ = try await c.call("task.send", ["text": "run it"])
        let ask = try #require(await c.waitFor { $0.str("type") == "permissionRequested" })
        // Switched to auto while the prompt is on screen: the call goes through and the prompt is withdrawn.
        _ = try await c.call("config.set", ["patch": ["permissionMode": "auto"]])
        #expect(await c.waitFor { $0.str("type") == "permissionResolved" && $0.str("id") == ask["request"]?.str("id") } != nil)
        #expect(await c.waitFor { $0.str("type") == "turnFinished" && $0.str("task") == task && $0.str("agentId") == "main" } != nil)
        // The next turn of the same task, after Stop or not, does not ask again.
        let before = c.events.filter { $0.str("type") == "permissionRequested" }.count
        _ = try await c.call("task.stop")
        _ = try await c.call("task.send", ["text": "run it again"])
        let t0 = Date()
        while c.events.filter({ $0.str("type") == "turnFinished" && $0.str("agentId") == "main" }).count < 2, Date().timeIntervalSince(t0) < 10 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(c.events.filter { $0.str("type") == "permissionRequested" }.count == before)
        try await c.call("shutdown")
    }

    @Test func queuedMessagesDreamsAndDoctor() async throws {
        let ws = try workspace()
        let c = Client(workspace: ws) { SlowProvider() }
        let opened = try await c.call("task.open")
        #expect(opened["dreams"]?.intValue == 0)
        _ = try await c.call("task.send", ["text": "first"])
        #expect(await c.waitFor { $0.str("type") == "turnStarted" && $0.str("agentId") == "main" } != nil)
        _ = try await c.call("task.send", ["text": "second"])
        // The first turn ends with the second waiting; the second starts with nothing left behind it.
        #expect(await c.waitFor(10) { $0.str("type") == "turnFinished" && $0.str("agentId") == "main" && $0["queued"]?.arrayValue?.compactMap(\.stringValue) == ["second"] } != nil, "\(c.events.filter { $0["queued"] != nil })")
        #expect(await c.waitFor(10) { $0.str("type") == "turnStarted" && $0.str("agentId") == "main" && $0["queued"]?.arrayValue?.isEmpty == true } != nil)
        let doctor = try await c.call("system.doctor")
        #expect(doctor.str("text")?.hasPrefix(L("SieveSci doctor")) == true)
        try await c.call("shutdown")
    }

    @Test func openingATaskTwiceAtOnceStartsItOnce() async throws {
        let ws = try workspace()
        let c = Client(workspace: ws) { ScriptedProvider(replies: ["hi"]) }
        let id = try #require(try await c.call("task.open").str("task"))
        _ = try await c.call("task.open")   // another task: the first, idle, is released
        async let a = c.call("task.open", ["id": .string(id)])
        async let b = c.call("task.open", ["id": .string(id)])
        let (ra, rb) = try await (a, b)
        #expect(ra.str("task") == id && rb.str("task") == id)
        // The session starts in the background after task.open answers: wait for the starts to be logged.
        let audit = ws.appendingPathComponent(".sievesci/tasks/\(id)/audit.jsonl")
        func starts() -> [String] {
            ((try? String(contentsOf: audit, encoding: .utf8)) ?? "").split(separator: "\n")
                .compactMap { try? JSONDecoder().decode(JSON.self, from: Data($0.utf8)).str("kind") }.filter { $0 == "session_start" }
        }
        let t0 = Date()
        while starts().count < 2, Date().timeIntervalSince(t0) < 10 { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 500_000_000)   // a third, duplicate start would have been logged by now
        #expect(starts().count == 2, "started when first opened and once when reopened: \(starts().count)")
        try await c.call("shutdown")
    }

    @Test func aRunningTaskContinuesInTheBackground() async throws {
        let ws = try workspace()
        let c = Client(workspace: ws) { SlowProvider() }
        let first = try #require(try await c.call("task.open").str("task"))
        _ = try await c.call("task.send", ["text": "take your time"])
        #expect(await c.waitFor { $0.str("type") == "turnStarted" && $0.str("task") == first } != nil)
        let second = try #require(try await c.call("task.open").str("task"))
        #expect(second != first)
        // The first finishes on its own, then is released (a closing status with no stage).
        #expect(await c.waitFor(10) { $0.str("type") == "turnFinished" && $0.str("task") == first && $0.str("agentId") == "main" } != nil)
        let t0 = Date()
        while !c.statuses.contains(where: { $0.str("task") == first && $0["stage"]?.isNull == true }), Date().timeIntervalSince(t0) < 5 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(c.statuses.contains { $0.str("task") == first && $0["stage"]?.isNull == true }, "\(c.statuses)")
        try await c.call("shutdown")
    }
}
