import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import SieveSciCore

@Suite struct ProcessRunnerRobustness {
    @Test func backgroundGrandchildDoesNotHangTheCall() async throws {
        let t0 = Date()
        // The grandchild keeps stdout open for 30 s; the call must return when `bash` itself exits.
        let r = try await ProcessRunner.run(Platform.bash, ["-c", "echo started; sleep 30 & echo done"], timeout: 60)
        #expect(Date().timeIntervalSince(t0) < 5, "returned after \(Date().timeIntervalSince(t0)) s")
        #expect(r.stdout.contains("started") && r.stdout.contains("done"))
    }

    @Test func exitCodeAndTimeoutAreReported() async throws {
        let ok = try await ProcessRunner.run(Platform.bash, ["-c", "exit 3"], timeout: 10)
        #expect(ok.exitCode == 3 && !ok.timedOut)
        let t0 = Date()
        let slow = try await ProcessRunner.run(Platform.bash, ["-c", "sleep 30"], timeout: 0.5)
        #expect(slow.timedOut && Date().timeIntervalSince(t0) < 5)
    }

    /// The CLI's async `main` runs on the main thread; a blocking wait there hung an eval for 35 min.
    @MainActor @Test func manyShortCallsFromTheMainActorReturn() async throws {
        let t0 = Date()
        for i in 0..<40 {
            let r = try await ProcessRunner.run(Platform.bash, ["-c", "echo \(i)"], timeout: 10)
            #expect(r.exitCode == 0 && r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "\(i)")
        }
        #expect(Date().timeIntervalSince(t0) < 20)
    }

    @Test func largeOutputIsSplitInLinearTime() async throws {
        let t0 = Date()
        let lines = LockedBox(0)
        let r = try await ProcessRunner.run(Platform.bash, ["-c", "seq 1 200000"], timeout: 60, onLines: { l in lines.mutate { $0 += l.count } })
        #expect(r.exitCode == 0)
        #expect(lines.value == 200_000)
        #expect(Date().timeIntervalSince(t0) < 10)
    }

    @Test func lineBufferHandlesHugeLinesAndSplits() {
        let b = LineBuffer()
        #expect(b.feed(Data("a\nb\nc".utf8)) == ["a", "b"])
        #expect(b.feed(Data("d\n".utf8)) == ["cd"])
        let huge = b.feed(Data(repeating: 0x78, count: 1_200_000))
        #expect(huge.count == 1 && huge[0].hasSuffix(" …"), "a runaway line is cut, not buffered forever")
    }

    @Test func jobWithBackgroundChildStillFinishes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString)")
        let jobs = JobMonitor(dir: dir)
        let id = try jobs.start(command: "echo hi; sleep 30 &", cwd: dir, agentId: "main", sandbox: .off, writableRoots: [dir], protected: [])
        let t0 = Date()
        while jobs.runningCount > 0, Date().timeIntervalSince(t0) < 8 { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(jobs.runningCount == 0, "the job ends when its command exits")
        #expect(jobs.drain(for: "main").contains { $0.kind == .exited && $0.job == id })
    }
}

@Suite struct StopEndsWork {
    @Test func cancellingARunningCommandKillsIt() async throws {
        let t0 = Date()
        let task = Task { try await ProcessRunner.run(Platform.bash, ["-c", "sleep 30"], timeout: 60) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let r = try await task.value
        #expect(Date().timeIntervalSince(t0) < 4, "Stop must not wait for the command")
        #expect(!r.timedOut)
    }

    /// A CLI agent that never answers (a hung `agy`): Stop must end the call and the process.
    @Test func cancellingACLIAgentKillsItsProcess() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hung-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appendingPathComponent("pid")
        let script = try makeScript(in: dir, name: "fake-agy", "\(bashPidCommand) > '\(pidFile.path)'\n\(Platform.isWindows ? "" : "exec ")sleep 60\n")
        var profile = ProviderPresets.profile(id: "codex")!
        profile.executable = script.path
        let p = CLIAgentProvider(profile: profile)
        let req = LLMRequest(model: "m", system: "s", tools: [], messages: [Message.user("hi")], maxTokens: 10,
                             cache: CacheHints(lineageKey: "stop-test", retention: .short))
        let task = Task { try await p.complete(req) }
        // The shell creates the file before it writes the pid into it.
        func readPid() -> Int32? { (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
        for _ in 0..<200 where readPid() == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        let pid = readPid() ?? 0
        let t0 = Date()
        task.cancel()
        _ = try? await task.value
        for _ in 0..<40 where ProcessRunner.alive(pid) { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(Date().timeIntervalSince(t0) < 6, "Stop ends the call promptly")
        #expect(pid > 0 && !ProcessRunner.alive(pid), "the CLI process is gone after Stop")
    }
}

private struct SlowTool: Tool {
    var name: String { "slow_echo" }
    var description: String { "Sleeps, then echoes." }
    var inputSchema: JSON { Schema.object(["text": ["type": "string"]]) }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return ToolOutput("echo: " + (input.str("text") ?? ""))
    }
}

@Suite(.serialized) struct ToolBridgeCalls {
    /// A call that outlives the CLI's MCP deadline answers "still running" and is collected later,
    /// with the tool's real result and a receipt.
    @Test func slowCallsAnswerStillRunningThenDeliver() async throws {
        let (services, _) = try makeServices()
        let session = AgentSession(role: .main, services: services, tools: [SlowTool()])
        let saved = ToolBridge.answerWithin
        ToolBridge.answerWithin = 0.2
        defer { ToolBridge.answerWithin = saved }

        let list = await ToolBridge.rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], session: session)
        let names = list?["result"]?["tools"]?.arrayValue?.compactMap { $0.str("name") } ?? []
        #expect(names.contains("slow_echo") && names.contains("tool_result"))

        let t0 = Date()
        let first = await ToolBridge.rpc(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                          "params": ["name": "slow_echo", "arguments": ["text": "hi"]]], session: session)
        #expect(Date().timeIntervalSince(t0) < 1.8, "the answer must come at the deadline, before the tool (2 s) ends")
        let note = first?["result"]?["content"]?.arrayValue?.first?.str("text") ?? ""
        #expect(note.contains("Still running"))
        let id = try #require(note.range(of: #"mcp-[0-9a-f]{8}"#, options: .regularExpression).map { String(note[$0]) })

        ToolBridge.answerWithin = 5
        let done = await ToolBridge.rpc(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                         "params": ["name": "tool_result", "arguments": ["id": .string(id)]]], session: session)
        let text = done?["result"]?["content"]?.arrayValue?.first?.str("text") ?? ""
        #expect(text.contains("echo: hi"))
        #expect(services.ledger.count == 1, "the call got its receipt")
    }
}

@Suite(.serialized) struct ToolBridgeHTTP {
    /// Many calls over real HTTP, as the stdio bridge makes them: none may stall.
    @Test func manyCallsOverHTTPAllAnswerPromptly() async throws {
        let (services, _) = try makeServices()
        let session = AgentSession(role: .main, services: services, tools: [QuickTool()])
        ToolBridge.shared.bridgeCommand = ToolBridge.shared.bridgeCommand ?? ["/bin/true"]
        let ep = try #require(await ToolBridge.shared.endpoint(for: session))
        var worst: TimeInterval = 0
        for i in 0..<40 {
            var r = URLRequest(url: URL(string: ep.url)!)
            r.httpMethod = "POST"
            r.setValue("Bearer \(ep.token)", forHTTPHeaderField: "authorization")
            r.setValue("application/json", forHTTPHeaderField: "content-type")
            r.httpBody = Data(#"{"jsonrpc":"2.0","id":\#(i),"method":"tools/call","params":{"name":"quick","arguments":{}}}"#.utf8)
            r.timeoutInterval = 20
            let t0 = Date()
            let (data, resp) = try await URLSession.shared.data(for: r)
            worst = max(worst, Date().timeIntervalSince(t0))
            #expect((resp as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self).contains("quick-ok"))
            if i % 7 == 0 { try await Task.sleep(nanoseconds: 300_000_000) }   // idle gaps, like a model thinking
        }
        #expect(worst < 3, "slowest call took \(worst) s")
    }
}

private struct QuickTool: Tool {
    var name: String { "quick" }
    var description: String { "Answers at once." }
    var inputSchema: JSON { Schema.object([:]) }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput { ToolOutput("quick-ok") }
}

extension ToolBridgeHTTP {
    /// The real `sievesci mcp-bridge` binary between a CLI and SieveSci, driven over stdio like agy does.
    @Test func stdioBridgeForwardsEveryCallPromptly() async throws {
        let cli = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/sievesci")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { return }
        let (services, _) = try makeServices()
        let session = AgentSession(role: .main, services: services, tools: [QuickTool()])
        ToolBridge.shared.bridgeCommand = ToolBridge.shared.bridgeCommand ?? ["/bin/true"]
        let ep = try #require(await ToolBridge.shared.endpoint(for: session))
        let proc = try AgyPool.spawn(cli.path, ["mcp-bridge"], cwd: nil, env: ep.env, signature: "test")
        defer { proc.kill() }
        func call(_ i: Int, _ method: String, _ params: String = "{}") async -> (String?, TimeInterval) {
            proc.stdin.write(Data((#"{"jsonrpc":"2.0","id":\#(i),"method":"\#(method)","params":\#(params)}"# + "\n").utf8))
            let t0 = Date()
            let line = await withTaskGroup(of: String?.self) { g in
                g.addTask { await proc.lines.next() }
                g.addTask { try? await Task.sleep(nanoseconds: 15_000_000_000); return nil }
                defer { g.cancelAll() }
                return await g.next() ?? nil
            }
            return (line, Date().timeIntervalSince(t0))
        }
        _ = await call(0, "initialize", #"{"protocolVersion":"2025-06-18"}"#)
        proc.stdin.write(Data((#"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n").utf8))
        var worst: TimeInterval = 0
        for i in 1...25 {
            let (line, dt) = await call(i, "tools/call", #"{"name":"quick","arguments":{}}"#)
            worst = max(worst, dt)
            #expect(line?.contains("quick-ok") == true, "call \(i): \(line ?? "no answer within 15 s")")
            if i % 5 == 0 { try await Task.sleep(nanoseconds: 2_500_000_000) }
        }
        #expect(worst < 3, "slowest call took \(worst) s")
    }
}

/// The plain-socket server ToolBridge uses off macOS, exercised on every platform.
@Suite struct LoopbackServer {
    @Test func answersLargeAndConcurrentRequests() async throws {
        let server = try #require(LoopbackHTTPServer { req in
            ("200 OK", Data(#"{"path":"\#(req.path)","bytes":\#(req.body.count),"auth":"\#(req.headers["authorization"] ?? "")"}"#.utf8))
        })
        #expect(server.port > 0)
        func call(_ i: Int, bytes: Int) async throws -> String {
            var r = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/mcp/\(i)")!)
            r.httpMethod = "POST"
            r.setValue("Bearer t\(i)", forHTTPHeaderField: "authorization")
            r.httpBody = Data(repeating: 65, count: bytes)
            r.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: r)
            #expect((resp as? HTTPURLResponse)?.statusCode == 200)
            return String(decoding: data, as: UTF8.self)
        }
        // A body far larger than one read, over the bridge's own client (URLSession on Apple
        // platforms, raw sockets elsewhere), then many at once.
        let big = try await LoopbackHTTPClient.post(URL(string: "http://127.0.0.1:\(server.port)/mcp/0")!, headers: ["Authorization": "Bearer t0"],
                                                    body: Data(repeating: 65, count: 300_000))
        #expect(big.0 == 200 && String(decoding: big.1, as: UTF8.self) == #"{"path":"/mcp/0","bytes":300000,"auth":"Bearer t0"}"#)
        let replies = try await withThrowingTaskGroup(of: (Int, String).self) { g in
            for i in 1...24 { g.addTask { (i, try await call(i, bytes: 64)) } }
            return try await g.reduce(into: [Int: String]()) { $0[$1.0] = $1.1 }
        }
        #expect(replies.count == 24)
        #expect(replies.allSatisfy { $0.value == #"{"path":"/mcp/\#($0.key)","bytes":64,"auth":"Bearer t\#($0.key)"}"# })
    }
}
