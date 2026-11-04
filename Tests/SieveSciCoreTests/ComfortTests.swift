import Foundation
import Testing
@testable import SieveSciCore

@Suite struct TaskTitles {
    @Test func titleIsTheFirstQuestionNotTheContextBlocks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-title-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(SessionStore.title(dir: dir) == nil, "no transcript yet")
        let first = Message(role: .user, blocks: [.text("<long_term_memory>\nnotes\n</long_term_memory>"),
                                                  .text("Does BRCA1 loss sensitize cells to PARP inhibitors?\nUse the 2024 screen."),
                                                  .text("<context>\nturn 1\n</context>")])
        SessionStore.shared.append(first, task: "t", agent: "main", dir: dir)
        SessionStore.shared.append(Message(role: .user, blocks: [.text("Second question")]), task: "t", agent: "main", dir: dir)
        #expect(SessionStore.title(dir: dir) == "Does BRCA1 loss sensitize cells to PARP inhibitors?")

        let long = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-title-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: long, withIntermediateDirectories: true)
        SessionStore.shared.append(Message(role: .user, blocks: [.text(String(repeating: "x", count: 200))]), task: "t", agent: "main", dir: long)
        #expect(SessionStore.title(dir: long)?.count == 80)
    }
}

@Suite struct SearchFallback {
    struct Keys: SecretStore {
        let keys: [String: String]
        func secret(for ref: String) -> String? { keys[ref] }
    }

    @Test func keyedBackendWithoutKeyFallsBackToDuckDuckGo() {
        var c = WebSearchConfig()
        c.backend = .brave
        c.apiKeyRef = "SIEVESCI_TEST_NO_SUCH_KEY"
        #expect(WebSearchClient(config: c, secrets: Keys(keys: [:])).effectiveBackend == .duckduckgo)
        #expect(WebSearchClient(config: c, secrets: Keys(keys: ["SIEVESCI_TEST_NO_SUCH_KEY": "k"])).effectiveBackend == .brave)
        c.backend = .searxng
        #expect(WebSearchClient(config: c, secrets: Keys(keys: [:])).effectiveBackend == .searxng, "keyless backends are used as configured")
    }

    @Test func toolSaysWhenItFellBack() async throws {
        let html = #"<div class="result__body"><a class="result__a" href="https://example.org/parp">PARP inhibitors in BRCA1-deficient cells</a><a class="result__snippet">Synthetic lethality…</a></div>"#
        let (ctx, s) = try toolContext(http: RoutedHTTP([("html.duckduckgo.com", html)]))
        s.webSearch.config.backend = .brave
        s.webSearch.config.apiKeyRef = "SIEVESCI_TEST_NO_SUCH_KEY"
        let out = try await WebSearchTool().run(["query": "PARP BRCA1"], ctx)
        #expect(out.text.hasPrefix("(DuckDuckGo, best effort: no key is set for brave)"), "\(out.text)")
    }
}

@Suite struct ModelsDevParsing {
    @Test func readsLimitsModalitiesReasoningAndPrices() throws {
        let json = #"{"deepseek":{"name":"DeepSeek","api":"https://api.deepseek.com","env":["DEEPSEEK_API_KEY"],"models":{"deepseek-v4-pro":{"id":"deepseek-v4-pro","name":"DeepSeek V4 Pro","limit":{"context":1000000,"output":65536},"modalities":{"input":["text","image"]},"reasoning":true,"tool_call":true,"reasoning_options":[{"type":"effort","values":["low","high"]}],"cost":{"input":0.5,"output":2,"cache_read":0.05}}}}}"#
        let c = ModelsDevCatalog()
        #expect(try c.load(Data(json.utf8)) == 1)
        let p = try #require(c.providers["deepseek"])
        #expect(p.api == "https://api.deepseek.com" && p.env == ["DEEPSEEK_API_KEY"])
        let m = try #require(p.models["deepseek-v4-pro"])
        #expect(m.context == 1_000_000 && m.output == 65_536)
        #expect(m.inputModalities == ["text", "image"] && m.reasoning && m.toolCall && m.effortLevels == ["low", "high"])
        #expect(m.cost.input == 0.5 && m.cost.output == 2 && m.cost.cacheRead == 0.05 && m.cost.cacheWrite == nil)
    }
}

@Suite struct HistoryBudget {
    @Test(.enabled(if: ProcessRunner.which("git") != nil)) func oversizedWorkspaceIsNotSnapshotted() async throws {
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-hist-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        for i in 0..<30 { try "row \(i)\n".writeReliably(to: ws.appendingPathComponent("f\(i).csv")) }
        let g = GitHistory(workspace: ws)
        await g.prepare()
        g.maxSnapshotFiles = 10
        #expect(await g.snapshot(subject: "baseline", trailers: [:]) == nil)
        #expect(g.skippedReason?.contains("30") == true)
        g.maxSnapshotFiles = 1000
        g.maxSnapshotBytes = 10
        #expect(await g.snapshot(subject: "baseline", trailers: [:]) == nil, "byte budget applies too")
        g.maxSnapshotBytes = 1_000_000
        let ok = await g.snapshot(subject: "baseline", trailers: [:])
        #expect(ok != nil && g.skippedReason == nil)
    }
}

@Suite struct StrongClaimAttribution {
    @Test func citedFindingsDoNotNeedBlindVerification() {
        let summary = """
        Farmer 等 2005 年首次证明 BRCA 缺陷细胞对 PARP 抑制极为敏感 [@farmer2005targeting]。
        Bryant et al. proved the same in BRCA2-deficient tumours (doi:10.1038/nature03443).
        """
        #expect(!NarrativeDetector.ownStrongClaim(summary), "attributed statements report published results")
        #expect(NarrativeDetector.ownStrongClaim("我们首次证明了该抑制剂在所有细胞系中有效。"), "the agent's own unattributed claim still triggers")
        #expect(NarrativeDetector.ownStrongClaim("Our screen proves a novel mechanism. See [@x2020] for background."),
                "a cited sentence elsewhere does not excuse an uncited strong claim")
        #expect(!NarrativeDetector.ownStrongClaim("Accuracy improved to 0.87 [r3]."), "\"improved\" is not a strong claim")
    }
}

@Suite struct TempFolderBlinding {
    /// Seatbelt enforces this; elsewhere blinding is advisory and reported as such.
    @Test(.enabled(if: Seatbelt.available)) func blindAgentCannotReadSharedTempFiles() async throws {
        let (s, ws) = try makeServices()
        s.sandboxMode = .workspaceWrite
        let planted = URL(fileURLWithPath: "/private/tmp/sievesci-leak-\(UUID().uuidString).txt")
        try "main agent result p=0.001".writeReliably(to: planted)
        defer { try? FileManager.default.removeItem(at: planted) }
        let data = ws.appendingPathComponent("data.csv")
        try "x,y\n1,2\n".writeReliably(to: data)
        let sandbox = s.taskDir.appendingPathComponent("verify/C1")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let v = s.makeSubagent(role: .verifier, writeRoot: sandbox, readable: [sandbox.path, data.path])
        let ctx = v.toolContext
        #expect(throws: ToolError.self) { try ctx.checkReadable(planted) }
        #expect(throws: Never.self) { try ctx.checkReadable(data) }
        #expect(ctx.privateTempDir?.path.hasPrefix(sandbox.path) == true)
        if Seatbelt.available {
            let out = try await PythonTool().run(["code": "import tempfile, os\nprint(open('\(data.path)').read().splitlines()[0])\ntry:\n    print(open('\(planted.path)').read())\nexcept Exception as e:\n    print('blocked', type(e).__name__)\nprint(tempfile.gettempdir())"], ctx)
            #expect(out.text.contains("x,y"), "declared data stays readable: \(out.text)")
            #expect(out.text.contains("blocked") && !out.text.contains("p=0.001"), "\(out.text)")
            #expect(out.text.contains(sandbox.lastPathComponent), "its own temp dir is inside the sandbox")
            s.kernel.shutdownAll()
        }
    }
}

@Suite struct InterruptedTurnsAreKept {
    @Test func aDraftLeftOnDiskBecomesAnInterruptedReply() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("draft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SessionStore.shared.append(Message.user("analyse the data"), task: "t", agent: "main", dir: dir)
        let d = TurnDraft(url: dir.appendingPathComponent("transcript-main.partial.json"))
        d.add(.thinkingDelta("⏺ bash(echo hi)\n"))
        d.add(.textDelta("The first result is 42"))
        d.note("⏺ python(...) → [r3]")
        // The app quits here: the draft stays on disk.
        let msgs = SessionStore.load(dir: dir, agent: "main")
        #expect(msgs.count == 2 && msgs[1].role == .assistant)
        #expect(msgs[1].plainText.contains("The first result is 42") && msgs[1].plainText.contains(TurnDraft.interruptedNote))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript-main.partial.json").path))
        #expect(SessionStore.load(dir: dir, agent: "main").count == 2, "kept for good, not re-added")
    }

    @Test func aTurnWithoutAnyReplyIsRebuiltFromTheAuditLog() throws {
        let (s, _) = try makeServices()
        s.log("user_turn", actor: "user", ["text": "go"])
        s.log("tool_call", actor: "main", ["tool": "bash", "input": ["command": "ls"], "receipt": "r1", "success": true])
        s.log("tool_call", actor: "main", ["tool": "python", "input": ["code": "1/0"], "receipt": "r2", "success": false])
        let m = try #require(Workbench.recoveredReply(audit: s.audit.url))
        let thinking = m.blocks.compactMap { if case .thinking(let t) = $0 { return t.text } else { return nil } }.joined()
        #expect(thinking.contains("bash") && thinking.contains("[r1]") && thinking.contains("✗ [r2]"))
        #expect(m.plainText.contains(TurnDraft.interruptedNote))
    }
}

@Suite struct PreregistrationGate {
    @Test func analysisWaitsForThePlanButExplorationDoesNot() throws {
        let (s, _) = try makeServices()
        let r = s.research
        func allowed(_ tool: String, _ input: JSON) -> Bool { if case .allow = r.requirePlan(tool: tool, input: input) { return true }; return false }
        #expect(!allowed("python", ["code": "print(1)"]))
        #expect(allowed("bash", ["command": "ls -la data && head -5 data/a.csv | wc -l"]))
        #expect(allowed("bash", ["command": "sed -n '1,40p' report.md; git log --oneline -5"]))
        #expect(!allowed("bash", ["command": "python3 analysis.py"]))
        #expect(!allowed("bash", ["command": "cat a.csv > b.csv"]))
        #expect(!allowed("bash", ["command": "find . -name '*.tmp' -delete"]))
        #expect(!allowed("bash", ["command": "echo $(rm -rf x)"]))
        #expect(allowed("read_file", ["path": "a"]))
        #expect(!allowed("write_file", ["path": "paper.md", "content": "x"]), "a deliverable waits for the plan too")
        #expect(!allowed("edit_file", ["path": "paper.md"]))
        if case .refuse(let why) = r.requirePlan(tool: "python", input: [:]) { #expect(why.contains("search first")) }

        // Grounded and planned: analysis may start.
        s.ledger.record(tool: "web_search", args: [:], output: ToolOutput("ok"), role: .main, startedAt: Date(), duration: 0)
        s.ledger.record(tool: "library_search", args: [:], output: ToolOutput("ok"), role: .main, startedAt: Date(), duration: 0)
        #expect(r.hasGrounding().literature, "library_search over this workspace's papers counts as literature")
        let step = PlanStep(id: "S1", title: "fit", detail: "", status: "pending", checkpoint: false, criteria: "AUC > 0.7", evidence: [], note: "")
        _ = r.setPlan(goal: "g", background: "b", hypotheses: [], steps: [step], rationale: "first plan")
        #expect(allowed("python", ["code": "print(1)"]))
        #expect(r.snapshot.steps.last?.checkpoint == true, "a plan without a checkpoint gets its final step as one")

        // The gate follows the research-protocol setting.
        let (s2, _) = try makeServices()
        s2.research.groundingRequired = false
        if case .allow = s2.research.requirePlan(tool: "python", input: [:]) {} else { Issue.record("gate should be off") }
    }

    @Test func taskLibrariesMergeIntoTheWorkspaceLibrary() throws {
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        let tasks = ws.appendingPathComponent(".sievesci/tasks")
        for (task, key) in [("t1", "smith2020"), ("t2", "lee2021"), ("t3", "smith2020")] {
            let lib = tasks.appendingPathComponent("\(task)/library")
            try FileManager.default.createDirectory(at: lib.appendingPathComponent("text"), withIntermediateDirectories: true)
            try #"[{"key":"\#(key)","title":"T","authors":[],"source":"manual","addedAt":"2026-10-17T00:00:00Z"}]"#.writeReliably(to: lib.appendingPathComponent("library.json"))
            try "text".writeReliably(to: lib.appendingPathComponent("text/\(key).txt"))
        }
        let shared = ws.appendingPathComponent(".sievesci/library")
        LiteratureLibrary.adoptTaskLibraries(into: shared, tasks: tasks)
        let lib = try LiteratureLibrary(dir: shared)
        #expect(Set(lib.records.map(\.key)) == ["smith2020", "lee2021"])
        #expect(FileManager.default.fileExists(atPath: shared.appendingPathComponent("text/lee2021.txt").path))
    }
}

@Suite struct TraceFromAudit {
    @Test func auditBecomesATraceWithCategories() throws {
        let (s, _) = try makeServices()
        s.log("user_turn", actor: "user", ["text": "build the scorer"])
        s.log("tool_call", actor: "main", ["tool": "read_file", "input": ["path": "a"], "receipt": "r1", "success": true])
        s.log("tool_call", actor: "main", ["tool": "literature_search", "input": ["query": "pharmacophore"], "receipt": "r2", "success": true])
        s.log("tool_call", actor: "main", ["tool": "python", "input": ["code": "fit()\nmore"], "receipt": "r3", "success": false])
        s.log("supervisor_review", actor: "checker", ["kind": "integrity", "verdict": "revise"])
        s.log("integrity_signal", actor: "host", ["signals": [["detail": "criteria changed after results", "kind": "harking"]]])
        let t = Trace.events(try AuditLog.read(s.audit.url))
        #expect(!t.contains { $0.kind == "read_file" }, "reading around is not a trace line")
        #expect(t.first { $0.kind == "literature_search" }?.category == .literature)
        let py = try #require(t.first { $0.kind == "python" })
        #expect(py.isError && py.text.hasPrefix("fit()") && py.text.contains("[r3]"))
        #expect(t.contains { $0.kind == "review" && $0.text.contains("revise") && $0.category == .agents })
        #expect(t.contains { $0.kind == "signal" && $0.text.contains("criteria changed") })
        #expect(t.contains { $0.kind == "user" })
    }

    /// Read-only: SIEVESCI_TRACE_AUDIT=<audit.jsonl> prints what the Trace tab would show.
    @Test func realAuditProbe() throws {
        guard let p = ProcessInfo.processInfo.environment["SIEVESCI_TRACE_AUDIT"] else { return }
        let t = Trace.events(try AuditLog.read(URL(fileURLWithPath: p)))
        print("TRACE events:", t.count, Dictionary(grouping: t, by: \.category).mapValues(\.count))
        for e in t.suffix(5) { print("TRACE", e.actor, e.kind, e.text.prefix(80)) }
    }
}

@Suite struct ScanSpeedProbe {
    /// Read-only: SIEVESCI_SCAN_AUDIT=<audit.jsonl> times the integrity scan on that task's code inputs.
    @Test func probe() throws {
        guard let p = ProcessInfo.processInfo.environment["SIEVESCI_SCAN_AUDIT"] else { return }
        for e in try AuditLog.read(URL(fileURLWithPath: p)) where e.kind == "tool_call" {
            let i = e.data["input"]
            guard let code = i?.str("code") ?? i?.str("command") ?? i?.str("content") ?? i?.str("new_string"), code.count > 2000 else { continue }
            let t0 = Date()
            _ = HackDetector.scan(code: code, location: "x")
            let dt = Date().timeIntervalSince(t0)
            if dt > 0.5 { print("SCAN slow", e.data.str("receipt") ?? "", e.data.str("tool") ?? "", code.count, "chars", String(format: "%.1f s", dt)) }
        }
        print("SCAN done")
    }
}

@Suite struct DisplayTimelineMerge {
    @Test func cliTurnsGetTheirToolCallsBackForDisplay() throws {
        let (s, _) = try makeServices()
        s.log("user_turn", actor: "user", ["text": "first"])
        s.log("tool_call", actor: "main", ["tool": "bash", "input": ["command": "ls"], "receipt": "r1", "success": true, "output_excerpt": "a.csv"])
        s.log("tool_call", actor: "checker", ["tool": "read_file", "input": ["path": "a"], "receipt": "r2", "success": true])
        s.log("user_turn", actor: "user", ["text": "second"])
        s.log("tool_call", actor: "main", ["tool": "python", "input": ["code": "1/0"], "receipt": "r3", "success": false, "output_excerpt": "ZeroDivisionError"])
        let transcript = [Message.user("first"), Message(role: .assistant, blocks: [.text("done 1")]), Message.user("second")]   // turn 2 still running
        let shown = DisplayTimeline.merge(transcript, audit: try AuditLog.read(s.audit.url))
        let uses = shown.flatMap(\.blocks).compactMap { if case .toolUse(let u) = $0 { return u.name } else { return nil } }
        #expect(uses == ["bash", "python"], "main agent's calls only, in their turns")
        #expect(shown[1].blocks.contains { if case .toolUse = $0 { return true }; return false }, "tools sit between the question and the reply")
        let results = shown.flatMap(\.blocks).compactMap { if case .toolResult(let r) = $0 { return r } else { return nil } }
        #expect(results.last?.isError == true && results.last?.content.contains("ZeroDivisionError") == true)

        // A transcript that already shows its tool calls (API models) is left alone.
        let api = [Message.user("first"), Message(role: .assistant, blocks: [.toolUse(ToolUse(id: "t1", name: "bash", input: [:]))])]
        #expect(DisplayTimeline.merge(api, audit: try AuditLog.read(s.audit.url)).count == api.count)
    }

    /// Read-only: SIEVESCI_TIMELINE_TASK=<task dir> prints how many tool calls the chat regains.
    @Test func realTaskProbe() throws {
        guard let d = ProcessInfo.processInfo.environment["SIEVESCI_TIMELINE_TASK"] else { return }
        let dir = URL(fileURLWithPath: d)
        let msgs = (try? String(contentsOf: dir.appendingPathComponent("transcript-main.jsonl"), encoding: .utf8))?.split(separator: "\n")
            .compactMap { try? JSONDecoder().decode(Message.self, from: Data($0.utf8)) } ?? []
        let merged = DisplayTimeline.merge(msgs, audit: try AuditLog.read(dir.appendingPathComponent("audit.jsonl")))
        let n = merged.flatMap(\.blocks).filter { if case .toolUse = $0 { return true }; return false }.count
        print("TIMELINE messages \(msgs.count) → \(merged.count), tool calls shown: \(n)")
    }
}

@Suite struct SkillIndexProbe {
    /// Read-only: SIEVESCI_SKILL_INDEX=1 prints the skills index built from this Mac's skill folders.
    @Test func probe() throws {
        guard ProcessInfo.processInfo.environment["SIEVESCI_SKILL_INDEX"] == "1" else { return }
        let reg = SkillRegistry(workspace: FileManager.default.temporaryDirectory)
        reg.reload()
        let idx = reg.index(for: .main)
        print("SKILLS total \(reg.skills.count) · index \(idx.count) chars ≈ \(idx.count / 4) tokens")
        print("SKILLS research: " + reg.skills.filter { SkillRegistry.isResearchSkill($0) }.map(\.name).joined(separator: ", "))
        print("SKILLS route:\n" + (SkillRegistry.writingRoute(Set(reg.skills.map(\.name))) ?? "none"))
    }

    @Test func writingRouteNamesOnlyInstalledSkills() {
        let r = SkillRegistry.writingRoute(["nature-writing", "nature-figure", "shuorenhua"]) ?? ""
        #expect(r.contains("`nature-figure`") && r.contains("`shuorenhua`") && !r.contains("aigc-reduce") && !r.contains("paper-pipeline"))
        #expect(SkillRegistry.writingRoute(["nature-figure"]) == nil, "one skill is not a route")
    }
}

private struct NopTool: Tool {
    let name: String
    var description: String { name }
    var inputSchema: JSON { Schema.object([:]) }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput { ToolOutput("ok") }
}

@Suite struct DelegationHints {
    @Test func hintsAfterAMultiStepPlanAndAtCallCounts() throws {
        let (s, _) = try makeServices()
        let session = AgentSession(role: .main, services: s, tools: [NopTool(name: "task"), NopTool(name: "bash")])
        let steps = (1...3).map { PlanStep(id: "S\($0)", title: "step \($0)", detail: "", status: "pending", checkpoint: false, criteria: "", evidence: [], note: "") }
        s.research.groundingRequired = false
        _ = s.research.setPlan(goal: "g", background: "b", hypotheses: [], steps: steps, rationale: "first plan")
        let plan = session.delegationHint(after: ToolUse(id: "1", name: "update_plan", input: [:]), output: ToolOutput("ok"))
        #expect(plan?.contains("3 pending steps") == true && plan?.contains("`task`") == true)
        #expect(session.delegationHint(after: ToolUse(id: "2", name: "update_plan", input: [:]), output: ToolOutput("ok")) == nil, "once per turn")
        var hints: [Int] = []
        for i in 3...160 where session.delegationHint(after: ToolUse(id: "\(i)", name: "bash", input: [:]), output: ToolOutput("ok")) != nil { hints.append(i) }
        #expect(hints == [30, 80, 150])
        // Without workers there is nothing to suggest.
        let solo = AgentSession(role: .main, services: s, tools: [NopTool(name: "bash")])
        #expect(solo.delegationHint(after: ToolUse(id: "x", name: "update_plan", input: [:]), output: ToolOutput("ok")) == nil)
    }
}

@Suite struct ScanStaysFast {
    @Test func longScriptsScanInBoundedTime() {
        // Whitespace runs, a huge inline data line, thousands of loops: each once took the old
        // whole-file regexes minutes.
        let code = String(repeating: "x = 1\n" + String(repeating: "    \n", count: 200), count: 50)
            + "data = [" + (0..<40000).map { "\($0).\($0 % 97)" }.joined(separator: ", ") + "]\n"
            + String(repeating: "for i in range(10):\n    try:\n        y = f(i)\n    except Exception:\n        z = 1\n", count: 3000)
        let t = Date()
        _ = HackDetector.scan(code: code)
        #expect(Date().timeIntervalSince(t) < 3)
        // The multi-line rules still fire.
        #expect(HackDetector.scan(code: "try:\n    f()\nexcept Exception:\n    pass\n").contains { $0.detail.contains("swallowed") })
        #expect(HackDetector.scan(code: "for s in range(50):\n    np.random.seed(s)\n    run()\n").contains { $0.detail.contains("seed") })
        #expect(HackDetector.scan(code: "r <- tryCatch({\n  fit(x)\n}, error = function(e) NULL)\n").contains { $0.detail.contains("tryCatch") })
    }

    @Test func auditFollowsAppendedLinesOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = try AuditLog(url: dir.appendingPathComponent("audit.jsonl"))
        _ = log.append(session: "s", kind: "a", actor: "main", ["n": .int(1)])
        let (first, off) = AuditLog.readNew(log.url, from: 0)
        _ = log.append(session: "s", kind: "b", actor: "main", ["n": .int(2)])
        let (next, _) = AuditLog.readNew(log.url, from: off)
        #expect(first.map(\.kind).suffix(1) == ["a"] && next.map(\.kind) == ["b"])
    }
}
