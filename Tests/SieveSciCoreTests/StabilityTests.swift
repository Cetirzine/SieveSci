import Foundation
import Testing
@testable import SieveSciCore

/// Regressions from the 2026-11 crash-log bundle: reopening a task with a 35 MB audit log froze the
/// window, and `/goal` kept starting rounds (4,871 in one task) while nothing could progress.
@Suite struct FastJSONParsing {
    static let samples = [
        #"{"a":1,"b":2.5,"c":true,"d":false,"e":null,"f":"x","g":[1,"y",{"h":[]}],"i":{}}"#,
        #"{"n":2.0,"big":12345678901,"neg":-3,"exp":1e3,"small":0.001,"zero":0}"#,
        #"{"s":"line\nbreak \"quoted\" é 中文 😀","url":"https://x.org/a?b=c&d=e"}"#,
        #"{"img":"data:image/png;base64,iVBORw0KGgo=","notdata":"data: just text"}"#,
        #"[1,2,3]"#, #""fragment""#, #"42"#, #"true"#,
    ]

    @Test func matchesTheSDKDecoder() throws {
        for s in Self.samples {
            let fast = try JSONCodec.parse(s)
            let sdk = try JSONDecoder().decode(JSON.self, from: Data(s.utf8))
            #expect(fast == sdk, "\(s)")
            #expect(fast.canonical == sdk.canonical, "\(s)")
        }
    }

    @Test func rejectsMalformedInput() {
        #expect(throws: (any Error).self) { try JSONCodec.parse("{\"a\":") }
    }
}

@Suite struct AuditLogReading {
    func tempLog() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-audit-" + UUID().uuidString)
        return dir.appendingPathComponent("audit.jsonl")
    }

    @Test func reopenContinuesTheChainFromTheTail() throws {
        let url = try tempLog()
        let log = try AuditLog(url: url)
        for i in 0..<300 { log.append(session: "s", kind: i % 3 == 0 ? "tool_call" : "model_call", actor: "main", ["i": .int(i), "text": .string(String(repeating: "x", count: 400))]) }
        let head = log.head
        let reopened = try AuditLog(url: url)
        #expect(reopened.head.seq == head.seq && reopened.head.hash == head.hash)
        reopened.append(session: "s", kind: "user_turn", actor: "user", ["text": "next"])
        #expect(try AuditLog.verify(url) == nil, "the chain stays intact across a reopen")
    }

    @Test func kindFilterDecodesOnlyWhatIsAsked() throws {
        let url = try tempLog()
        let log = try AuditLog(url: url)
        for i in 0..<30 { log.append(session: "s", kind: i % 3 == 0 ? "tool_call" : "model_call", actor: "main", ["i": .int(i)]) }
        // A string that merely mentions a kind is not a match.
        log.append(session: "s", kind: "model_call", actor: "main", ["note": "\"kind\":\"tool_call\""])
        let calls = try AuditLog.read(url, kinds: ["tool_call"])
        #expect(calls.count == 10 && calls.allSatisfy { $0.kind == "tool_call" })
        #expect(try AuditLog.read(url).count == 31)
    }

    @Test func timeParserMatchesTheFormatter() {
        let f = ISO8601DateFormatter()
        for t in ["2026-10-22T12:08:35Z", "2000-02-29T23:59:59Z", "1970-01-01T00:00:00Z", "2099-12-31T00:00:01Z", "2026-03-01T00:00:00Z"] {
            #expect(AuditLog.parseTime(t) == f.date(from: t), "\(t)")
        }
        #expect(AuditLog.parseTime("2026-10-22T12:08:35.123Z") == f.date(from: "2026-10-22T12:08:35.123Z"))
    }

    @Test func tornLastLineIsSkipped() throws {
        let url = try tempLog()
        let log = try AuditLog(url: url)
        log.append(session: "s", kind: "a", actor: "host", [:])
        let good = log.append(session: "s", kind: "b", actor: "host", [:])
        let h = try FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        h.write(Data(#"{"actor":"host","data":{"#.utf8))   // crash mid-write
        try h.close()
        #expect(try AuditLog(url: url).head.seq == good.seq)
    }
}

@Suite struct GoalRounds {
    func bench(_ replies: [String]) throws -> (Workbench, SessionServices) {
        let (s, _) = try makeServices(ScriptedProvider(replies: replies))
        s.research.groundingRequired = false
        return (Workbench(services: s), s)
    }

    @Test func aRoundThatDoesNoWorkHandsTheGoalBack() async throws {
        let (b, s) = try bench(Array(repeating: "Still waiting for the analysis to finish.", count: 50))
        _ = s.goal.create("analyse the data")
        try await b.driveGoal()
        let g = try #require(s.goal.current)
        #expect(g.roundsStarted == 1, "one idle round, not dozens")
        #expect(g.phase == .waiting && g.waitingFor != nil)
        s.goal.userReplied()
        #expect(s.goal.current?.phase == .active, "a reply resumes it")
    }

    @Test func runningJobsWakeTheGoalInsteadOfARound() async throws {
        let (b, s) = try bench(["should not be sent"])
        _ = s.goal.create("wait for the job")
        let job = try s.jobs.start(command: "sleep 5", cwd: s.workspace, agentId: "main", sandbox: .off, writableRoots: [], protected: [])
        defer { _ = s.jobs.stop(job) }
        try await b.driveGoal()
        #expect(s.goal.current?.roundsStarted == 0)
        #expect(s.goal.current?.phase == .active, "still active: the job's notification starts the next round")
    }

    @Test func planModeDoesNotSpinRounds() async throws {
        let (b, s) = try bench(["x"])
        s.permissions.mode = .plan
        _ = s.goal.create("g")
        try await b.driveGoal()
        #expect(s.goal.current?.roundsStarted == 0 && s.goal.current?.phase == .waiting)
    }

    @Test func roundsAreCappedByDefault() {
        let c = GoalController()
        #expect(c.create("g").maxRounds == Goal.defaultMaxRounds)
        #expect(c.create("g", maxRounds: 0).maxRounds == nil)
        _ = c.create("g", maxRounds: 3)
        var n = 0
        while c.nextRound(tokensSoFar: 0) != nil { n += 1 }
        #expect(n == 3 && c.current?.phase == .blocked && c.current?.blockedReason == "round-limit")
    }

    @Test func modelCanWaitForTheUser() {
        let c = GoalController()
        _ = c.create("g")
        _ = c.nextRound(tokensSoFar: 0)
        _ = c.modelWait(question: "Use dataset A or B?")
        #expect(c.current?.phase == .waiting && c.current?.waitingFor == "Use dataset A or B?")
        #expect(c.nextRound(tokensSoFar: 0) == nil)
    }
}

@Suite struct ContextPruning {
    @Test func oldOutputsGiveWayToReceiptsAndRecentOnesStay() throws {
        let (s, _) = try makeServices()
        let a = AgentSession(id: "main", role: .main, services: s, tools: [])
        var msgs: [Message] = [Message.user("start")]
        for i in 0..<12 {
            let id = "t\(i)"
            let tool = i == 0 ? "skill" : "bash"
            msgs.append(Message(role: .assistant, blocks: [.toolUse(ToolUse(id: id, name: tool, input: ["i": .int(i)]))]))
            let body = "line one of output \(i)\n" + String(repeating: "data ", count: 6_000) + "\n[receipt r\(i)]"
            msgs.append(Message(role: .user, blocks: [.toolResult(ToolResult(toolUseId: id, content: body))]))
        }
        a.restore(msgs)
        let freed = a.prune()
        #expect(freed >= ContextPruning.minimum)
        let results = a.transcript.flatMap(\.blocks).compactMap { b -> ToolResult? in if case .toolResult(let r) = b { return r }; return nil }
        #expect(!results[0].content.hasPrefix(AgentSession.prunedMarker), "skill output is working state and is kept")
        #expect(results[1].content.hasPrefix(AgentSession.prunedMarker) && results[1].content.contains("receipt r1"))
        #expect(!results.last!.content.hasPrefix(AgentSession.prunedMarker), "the newest outputs stay verbatim")
        #expect(a.prune() == 0, "a second pass has nothing left to free")
    }

    static let minimum = AgentSession.pruneMinimum
}

@Suite struct TaskStages {
    func goal(_ phase: Goal.Phase, waiting: String? = nil) -> Goal {
        Goal(id: "g", objective: "o", phase: phase, maxRounds: nil, tokenBudget: nil, roundsStarted: 1, tokensUsed: 0,
             blockedReason: phase == .blocked ? "round-limit" : nil, completionNote: nil, waitingFor: waiting)
    }

    @Test func firstMatchingRowWins() {
        var f = TaskStage.Facts()
        #expect(TaskStage.of(f) == .idle && !TaskStage.of(f).needsPerson)
        f.runningJobs = 2
        #expect(TaskStage.of(f) == .waitingForJobs(2))
        f.contested = "OT3 pooled across replicates"
        #expect(TaskStage.of(f) == .answer("OT3 pooled across replicates"))
        f.lastError = "HTTP 529"
        #expect(TaskStage.of(f) == .blocked("HTTP 529"))
        f.planMode = true; f.planHasSteps = true
        #expect(TaskStage.of(f) == .review)
        f.running = true
        #expect(TaskStage.of(f) == .working, "a running task is working, whatever waits behind it")
        f.goal = goal(.waiting, waiting: "A or B?")
        #expect(TaskStage.of(f) == .answer("A or B?"), "a question to the user comes first")
        f.permissionAsk = "bash: rm -rf data"
        #expect(TaskStage.of(f) == .answer("bash: rm -rf data"))
    }

    @Test func blockedGoalNeedsThePerson() {
        var f = TaskStage.Facts()
        f.goal = goal(.blocked)
        #expect(TaskStage.of(f) == .blocked("round-limit") && TaskStage.of(f).needsPerson)
    }
}

@Suite struct Conversations {
    func workspace(_ tasks: [(String, [Message])]) throws -> URL {
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-conv-" + UUID().uuidString)
        for (id, msgs) in tasks {
            let dir = SessionStore.taskDir(id, in: ws)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for m in msgs { SessionStore.shared.append(m, task: id, agent: "main", dir: dir) }
        }
        return ws
    }

    @Test func emptySessionsAreNotListed() throws {
        let ws = try workspace([("2026-11-01-aaaaaa", [Message.user("How stable is EMX1 editing?"), Message(role: .assistant, blocks: [.text("Stable across replicates.")])]),
                                ("2026-11-01-empty1", [])])
        #expect(SessionStore.tasks(in: ws).map(\.id) == ["2026-11-01-aaaaaa"])
    }

    @Test func resolveRenameDigestAndIndex() throws {
        let ws = try workspace([("2026-11-01-aaaaaa", [Message.user("How stable is EMX1 editing?"), Message(role: .assistant, blocks: [.text("Stable across replicates.\nDetails follow.")])]),
                                ("2026-10-30-bbbbbb", [Message.user("Design guides for VEGFA"), Message(role: .assistant, blocks: [.text("Three guides chosen.")])])])
        #expect(SessionStore.resolve("2026-11-01-aaa", in: ws) == "2026-11-01-aaaaaa")
        #expect(SessionStore.resolve("task:2026-10-30-bbbbbb", in: ws) == "2026-10-30-bbbbbb")
        #expect(SessionStore.resolve("VEGFA", in: ws) == "2026-10-30-bbbbbb")
        #expect(SessionStore.resolve("2026", in: ws) == nil, "ambiguous references resolve to nothing")
        SessionStore.setTitle("EMX1 stability", task: "2026-11-01-aaaaaa", in: ws)
        #expect(SessionStore.title(dir: SessionStore.taskDir("2026-11-01-aaaaaa", in: ws)) == "EMX1 stability")
        let d = SessionStore.digest(task: "2026-11-01-aaaaaa", in: ws)
        #expect(d.contains("Q1: How stable is EMX1 editing?") && d.contains("A1: Stable across replicates."))
        let idx = SessionStore.index(workspace: ws, excluding: "2026-11-01-aaaaaa")
        #expect(idx.contains("2026-10-30-bbbbbb") && idx.contains("Three guides chosen.") && !idx.contains("2026-11-01-aaaaaa"))
    }

    @Test func trashRemovesTheConversation() throws {
        let ws = try workspace([("2026-11-01-cccccc", [Message.user("q")])])
        try SessionStore.trash(task: "2026-11-01-cccccc", in: ws)
        #expect(SessionStore.tasks(in: ws).isEmpty)
    }

    @Test func sessionReadToolReadsByPrefix() async throws {
        let (s, ws) = try makeServices()
        let dir = SessionStore.taskDir("2026-09-09-dddddd", in: ws)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SessionStore.shared.append(Message.user("Which buffer?"), task: "x", agent: "main", dir: dir)
        SessionStore.shared.append(Message(role: .assistant, blocks: [.text("Tris-HCl pH 7.5.")]), task: "x", agent: "main", dir: dir)
        let ctx = ToolContext(workspace: ws, sessionId: "main", role: .main, blindedPaths: [], writeRoot: nil, readableRoots: nil,
                              ledger: s.ledger, audit: s.audit, services: s)
        let out = try await SessionReadTool().run(["id": "2026-09-09"], ctx)
        #expect(out.text.contains("Tris-HCl pH 7.5."))
        let full = try await SessionReadTool().run(["id": "2026-09-09-dddddd", "part": "full"], ctx)
        #expect(full.text.contains("characters 0–") && full.text.contains("Which buffer?"))
    }
}

@Suite struct MemoryOverflow {
    @Test func overflowArchivesInsteadOfFailing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-mem-" + UUID().uuidString)
        let mem = MemoryStore(dir: dir)
        for i in 0..<12 { mem.recordLesson("automatic lesson \(i) " + String(repeating: "x", count: 200)) }
        var last = ""
        for i in 0..<10 { last = try mem.apply(.add, store: .lessons, text: "Lesson \(i): " + String(repeating: "y", count: 300), match: nil) }
        let kept = mem.entries(.lessons)
        #expect(kept.joined(separator: MemoryStore.separator).count <= MemoryStore.Store.lessons.limit)
        #expect(kept.contains { $0.hasPrefix("Lesson 9") }, "the newest lesson is always recorded")
        #expect(!kept.contains { $0.hasPrefix("[auto]") }, "automatic lessons make room first")
        #expect(!mem.archived(.lessons).isEmpty && last.contains("archive"))
        #expect(mem.search(.lessons, query: "automatic lesson").count > 0, "archived lessons stay searchable")
    }
}

@Suite struct LearnedCapabilities {
    @Test func learnedImageSupportOverridesTheCatalog() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("caps-\(UUID().uuidString).json")
        let caps = ModelCapabilities(url: url)
        #expect(caps.learnedImages("deepseek-flash", profile: "deepseek") == nil)
        caps.learn(images: true, model: "deepseek-flash", profile: "deepseek")
        #expect(ModelCapabilities(url: url).learnedImages("deepseek-flash", profile: "deepseek") == true, "persisted")
    }

    @Test func recognisesImageRefusals() {
        #expect(ModelCapabilities.isImageRefusal(ProviderError.http(status: 400, body: #"{"error":"image_url is not supported by this model"}"#)))
        #expect(!ModelCapabilities.isImageRefusal(ProviderError.http(status: 400, body: "max_tokens too large")))
        #expect(!ModelCapabilities.isImageRefusal(ProviderError.http(status: 500, body: "image service down")))
    }
}

@Suite struct ScienceIntegrations {
    @Test func connectingKeepsOtherServers() throws {
        let cfg = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString).json")
        try Data(#"{"mcpServers":{"playwright":{"command":"npx","args":["@playwright/mcp"]}}}"#.utf8).write(to: cfg)
        #expect(!ScienceConnectors.isConnected("tooluniverse", config: cfg))
        try ScienceConnectors.connect("tooluniverse", config: cfg)
        let j = try JSONCodec.parse(Data(contentsOf: cfg))
        #expect(j["mcpServers"]?["playwright"]?.str("command") == "npx", "existing servers are kept")
        #expect(j["mcpServers"]?["tooluniverse"]?.str("command") == "uvx")
        #expect(ScienceConnectors.isConnected("tooluniverse", config: cfg))
        #expect(throws: (any Error).self) { try ScienceConnectors.connect("nope", config: cfg) }
    }

    @Test func virtualLabSkillIsBundled() throws {
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-skills-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let reg = SkillRegistry(workspace: ws)
        #expect(reg.skills.contains { $0.name == "virtual-lab-meeting" })
        #expect(reg.skills.first { $0.name == "hypothesis-tournament" }?.description.contains("evolve") == true)
    }
}
