import Foundation
import Testing
@testable import SieveSciCore

private func services(at ws: URL, provider: LLMProvider = ScriptedProvider(replies: [])) throws -> SessionServices {
    try SessionServices(taskId: "t1", workspace: ws, models: RoleModels(main: (provider, "m")), secrets: EnvironmentSecretStore())
}

private func tempWorkspace() throws -> URL {
    let ws = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    return ws
}

@discardableResult
private func record(_ s: SessionServices, _ tool: String, _ text: String, role: AgentRole = .main) -> Receipt {
    s.ledger.record(tool: tool, args: ["q": "x"], output: ToolOutput(text), role: role, startedAt: Date(), duration: 0)
}

// MARK: - Research state survives a resumed session

@Suite struct ResearchStatePersistence {
    @Test func receiptsPlanAndClaimsSurviveRestart() throws {
        let ws = try tempWorkspace()
        do {
            let s = try services(at: ws)
            record(s, "web_search", "hit one")
            record(s, "literature_search", "paper two")
            let analysis = record(s, "python", "p = 0.003")
            let step = PlanStep(id: "s1", title: "Fit", detail: "", status: "pending", checkpoint: true, criteria: "R2 > 0.5", evidence: [], note: "")
            let h = Hypothesis(id: "H1", statement: "X raises Y", prediction: "Y up", falsification: "no change", status: "open", registeredAt: Date())
            #expect(s.research.setPlan(goal: "g", background: "b", hypotheses: [h], steps: [step], rationale: "").0 == .allow)
            #expect(s.research.updateStep(id: "s1", status: "done", evidence: [analysis.id], note: "ok").0 == .allow)
            let c = s.claims.add(statement: "X raises Y", criteria: "p < 0.05", evidence: [analysis.id], dataPaths: ["data.csv"])
            s.claims.hostSet(c.id, status: .verifying, verdict: nil)
        }
        let s = try services(at: ws)
        #expect(s.ledger.count == 3)
        #expect(s.ledger.output("r3") == "p = 0.003")
        #expect(s.research.hasGrounding().web && s.research.hasGrounding().literature, "grounding must not reset on resume")
        #expect(record(s, "bash", "next").id == "r4", "receipt ids continue instead of reusing r1…")
        #expect(s.research.snapshot.steps.first?.status == "done")
        #expect(s.research.snapshot.hypotheses.first?.id == "H1")
        let claim = try #require(s.claims.snapshot.first)
        #expect(claim.status == .inconclusive, "an interrupted verification never looks in progress or passed")
        #expect(s.claims.add(statement: "s", criteria: "c", evidence: [], dataPaths: []).id == "C2")
    }

    @Test func editedReceiptOutputIsNotTrusted() throws {
        let ws = try tempWorkspace()
        do { record(try services(at: ws), "python", "p = 0.20") }
        let out = ws.appendingPathComponent(".sievesci/tasks/t1/state/outputs/r1.txt")
        try "p = 0.001".write(to: out, atomically: true, encoding: .utf8)
        let s = try services(at: ws)
        #expect(s.ledger.tamperedOutputs == ["r1"])
        #expect(s.ledger.output("r1") == nil)
        #expect(!s.ledger.corpus().contains("0.001"))
    }

    @Test func agentsCannotEditTheTaskRecord() throws {
        let ws = try tempWorkspace()
        let ctx = try services(at: ws).makeSubagent(role: .main).toolContext
        #expect(throws: ToolError.self) { try ctx.checkWritable(ws.appendingPathComponent(".sievesci/tasks/t1/state/claims.json")) }
        #expect(throws: ToolError.self) { try ctx.checkWritable(ws.appendingPathComponent(".git/config")) }
        try ctx.checkWritable(ws.appendingPathComponent("analysis.py"))
    }
}

// MARK: - The verifier is blind

@Suite struct VerifierBlinding {
    struct Fixture {
        let services: SessionServices
        let ws: URL
        let sandbox: URL
        let verifier: AgentSession
    }

    func fixture() throws -> Fixture {
        let ws = try tempWorkspace()
        let s = try services(at: ws)
        try "print('secret method')".write(to: ws.appendingPathComponent("analysis.py"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: ws.appendingPathComponent("data"), withIntermediateDirectories: true)
        try "a,b\n1,2\n".write(to: ws.appendingPathComponent("data/raw.csv"), atomically: true, encoding: .utf8)
        let sandbox = s.taskDir.appendingPathComponent("verify/C1")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let v = s.makeSubagent(role: .verifier, writeRoot: sandbox, readable: [sandbox.path, ws.appendingPathComponent("data/raw.csv").path])
        return Fixture(services: s, ws: ws, sandbox: sandbox, verifier: v)
    }

    @Test func fileToolsSeeOnlySandboxAndDeclaredData() throws {
        let f = try fixture()
        let ctx = f.verifier.toolContext
        #expect(throws: ToolError.self) { try ctx.checkReadable(f.ws.appendingPathComponent("analysis.py")) }
        #expect(throws: ToolError.self) { try ctx.checkReadable(f.services.taskDir.appendingPathComponent("audit.jsonl")) }
        try ctx.checkReadable(f.ws.appendingPathComponent("data/raw.csv"))
        try ctx.checkReadable(f.sandbox.appendingPathComponent("mine.py"))
        // A link planted in the sandbox does not reach a hidden file.
        let link = f.sandbox.appendingPathComponent("link.py")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.ws.appendingPathComponent("analysis.py"))
        #expect(throws: ToolError.self) { try ctx.checkReadable(link) }
    }

    @Test func verifierCannotReadOtherAgentsReceiptsOrPastSessions() async throws {
        let f = try fixture()
        let mainReceipt = record(f.services, "python", "secret result 0.003")
        let own = record(f.services, "python", "my result", role: .verifier)
        let ctx = f.verifier.toolContext
        let hidden = try await ReceiptTool().run(["id": .string(mainReceipt.id)], ctx)
        #expect(hidden.isError)
        #expect(!hidden.text.contains("0.003"))
        #expect(try await !ReceiptTool().run(["id": .string(own.id)], ctx).isError)
        #expect(try await SessionSearchTool().run(["query": "secret method"], ctx).isError)
        // The checker still reads everything: reviewing the main agent's work is its job.
        let checker = f.services.makeSubagent(role: .checker)
        #expect(try await !ReceiptTool().run(["id": .string(mainReceipt.id)], checker.toolContext).isError)
    }

    @Test func grepDoesNotLeakHiddenFiles() async throws {
        let f = try fixture()
        let out = try await GrepTool().run(["pattern": "secret", "path": "."], f.verifier.toolContext)
        #expect(!out.text.contains("analysis.py"), "\(out.text)")
    }

    @Test func claimDataPathsCannotUnblindTheVerifier() throws {
        let f = try fixture()
        let ctx = f.services.makeSubagent(role: .main).toolContext
        #expect(ClaimFindingTool.unblindingPath(["."], ctx) == ".")
        #expect(ClaimFindingTool.unblindingPath([".sievesci/tasks/t1"], ctx) == ".sievesci/tasks/t1")
        #expect(ClaimFindingTool.unblindingPath(["data/raw.csv", "/Volumes/shared/genome.fa"], ctx) == nil)
    }

    /// `URL.resolvingSymlinksInPath()` strips `/private` from existing paths, which made sandbox
    /// rules for workspaces under /var or /tmp silently miss.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/private/var/tmp"), "macOS layout"))
    func canonicalPathsKeepPrivatePrefix() {
        #expect(FilePaths.canonical("/var/tmp") == "/private/var/tmp")
        #expect(FilePaths.canonical("/var/tmp/does/not/exist.txt") == "/private/var/tmp/does/not/exist.txt")
        #expect(FilePaths.canonical("/private/var/tmp/x/../y") == "/private/var/tmp/y")
    }

    /// Code the verifier runs is blinded by the sandbox, not only its file tools.
    @Test(.enabled(if: Seatbelt.available, "Seatbelt is macOS-only"))
    func sandboxHidesWorkspaceFromVerifierCode() async throws {
        let f = try fixture()
        f.services.sandboxMode = .off   // the user turned the sandbox off; the verifier is sandboxed anyway
        let ctx = f.verifier.toolContext
        #expect(ctx.sandboxMode == .workspaceWrite)
        let raw = f.ws.appendingPathComponent("data/raw.csv").path
        let secret = f.ws.appendingPathComponent("analysis.py").path
        let audit = f.services.taskDir.appendingPathComponent("audit.jsonl").path

        let bash = try await BashTool().run(["command": .string("cat '\(raw)'; cat '\(secret)'; cat '\(audit)'; ls '\(f.ws.path)'")], ctx)
        #expect(bash.text.contains("a,b"), "\(bash.text)")
        #expect(!bash.text.contains("secret method"), "\(bash.text)")
        #expect(!bash.text.contains("session_start"), "\(bash.text)")
        #expect(!bash.text.contains("analysis.py\n"), "workspace listing must be hidden: \(bash.text)")

        let py = try await PythonTool().run(["code": .string("""
        print(open(r'\(raw)').read().strip())
        try:
            print(open(r'\(secret)').read())
        except Exception as e:
            print('blocked', type(e).__name__)
        """)], ctx)
        f.services.kernel.shutdownAll()
        #expect(py.text.contains("a,b"), "\(py.text)")
        #expect(py.text.contains("blocked"), "\(py.text)")
        #expect(!py.text.contains("secret method"), "\(py.text)")

        // The main agent's code is not affected.
        let mainOut = try await BashTool().run(["command": .string("cat '\(secret)'")], f.services.makeSubagent(role: .main).toolContext)
        #expect(mainOut.text.contains("secret method"), "\(mainOut.text)")
    }
}

// MARK: - Subagents follow the permission policy

@Suite struct SubagentPermissions {
    func recordAsks(_ s: SessionServices) -> LockedBox<[String]> {
        let box = LockedBox<[String]>([])
        s.requestPermission = { req in box.mutate { $0.append(req.summary) }; return .deny("") }
        return box
    }

    @Test func delegatingToolsNeedApprovalLikeRunningCode() {
        let p = PermissionPolicy(mode: .ask)
        let tools: [Tool] = [DispatchTool(), TaskTool(), ClaimFindingTool()]
        for t in tools {
            #expect(t.effect(for: [:]) == .executes, "\(t.name)")
            #expect(p.evaluate(tool: t.name, input: [:], effect: .executes) == .ask, "\(t.name)")
        }
    }

    @Test func unsandboxedWorkerCodeIsAskedAbout() async throws {
        let (s, _) = try makeServices()
        s.sandboxMode = .off
        let box = recordAsks(s)
        let w = s.makeSubagent(role: .worker, purpose: "screen abstracts")
        let denial = await w.authorize(BashTool(), ToolUse(id: "u1", name: "bash", input: ["command": "echo hi"]), .executes)
        #expect(denial != nil)
        #expect(box.value.count == 1)
        #expect(box.value.first?.contains("worker · screen abstracts") == true, "\(box.value)")
    }

    @Test(.enabled(if: Seatbelt.available, "Seatbelt is macOS-only"))
    func sandboxedWorkerCodeRunsUnderTheBatchApproval() async throws {
        let (s, _) = try makeServices()
        s.sandboxMode = .workspaceWrite
        let box = recordAsks(s)
        let w = s.makeSubagent(role: .worker)
        let ok = await w.authorize(BashTool(), ToolUse(id: "u1", name: "bash", input: ["command": "echo hi"]), .executes)
        #expect(ok == nil)
        #expect(box.value.isEmpty)
        // The hard deny list still applies inside the sandbox.
        let sudo = await w.authorize(BashTool(), ToolUse(id: "u2", name: "bash", input: ["command": "sudo rm -rf /tmp/x"]), .executes)
        #expect(sudo != nil)
    }

    @Test func subagentsCannotActInPlanModeOrAsChecker() async throws {
        let (s, _) = try makeServices()
        let use = ToolUse(id: "u1", name: "bash", input: ["command": "echo hi"])
        s.permissions.mode = .plan
        #expect(await s.makeSubagent(role: .worker).authorize(BashTool(), use, .executes) != nil)
        s.permissions.mode = .auto
        #expect(await s.makeSubagent(role: .checker).authorize(BashTool(), use, .external) != nil,
                "the checker stays read-only, including external tools")
    }

    @Test func permissionRequestsAreAskedOneAtATime() async {
        let q = PermissionQueue()
        let live = LockedBox(0), peak = LockedBox(0)
        let handler: @Sendable (PermissionRequest) async -> PermissionDecision = { _ in
            live.mutate { $0 += 1 }
            peak.mutate { $0 = max($0, live.value) }
            try? await Task.sleep(nanoseconds: 20_000_000)
            live.mutate { $0 -= 1 }
            return .allowOnce
        }
        await withTaskGroup(of: PermissionDecision.self) { g in
            for i in 0..<6 {
                let req = PermissionRequest(id: "p\(i)", tool: "bash", summary: "", input: [:], effect: .executes, rememberPattern: "bash")
                g.addTask { await q.ask(req, handler) }
            }
            for await d in g { #expect(d == .allowOnce) }
        }
        #expect(peak.value == 1)
    }

    @Test func emptyRankBatchDoesNotCrash() async {
        #expect(await DispatchTool().runPool(count: 0, par: 4) { _ in "x" }.isEmpty)
    }
}
