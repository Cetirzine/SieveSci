import Foundation
import Testing
@testable import SieveSciCore

/// A worker model: first call lists files (a receipt), second returns a report naming its step.
/// Tracks how many requests are in flight at once.
private final class FakeWorkerModel: LLMProvider, @unchecked Sendable {
    let profile = ProviderProfile(id: "worker-fake", displayName: "worker", family: .openaiChat, baseURL: "http://localhost", auth: .none, apiKeyRef: "", models: ["w"])
    let delay: UInt64
    let inFlight = LockedBox(0), peak = LockedBox(0), calls = LockedBox(0)
    init(delayMs: UInt64 = 80) { delay = delayMs * 1_000_000 }

    var split = true

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        if request.system == HostDelegation.decomposer {
            let parts = (1...3).map { #"{"title": "Review topic \#($0)", "brief": "Review topic \#($0) in 150 words"}"# }.joined(separator: ",")
            let text = split ? #"{"split": true, "parts": [\#(parts)]}"# : #"{"split": false, "parts": []}"#
            return AsyncThrowingStream { c in
                c.yield(.completed(LLMResponse(message: Message(role: .assistant, blocks: [.text(text)]), stopReason: .endTurn, usage: Usage(input: 10, output: 5))))
                c.finish()
            }
        }
        let first = request.messages.first?.blocks.compactMap(\.text).joined() ?? ""
        let step = first.range(of: #"id="[^"]+""#, options: .regularExpression).map { String(first[$0].dropFirst(4).dropLast()) } ?? "?"
        let hasResult = request.messages.last?.blocks.contains { if case .toolResult = $0 { return true }; return false } ?? false
        let delay = self.delay
        return AsyncThrowingStream { c in
            let task = Task {
                self.calls.mutate { $0 += 1 }
                self.inFlight.mutate { $0 += 1 }
                let now = self.inFlight.value
                self.peak.mutate { $0 = max($0, now) }
                defer { self.inFlight.mutate { $0 -= 1 } }
                do { try await Task.sleep(nanoseconds: delay) } catch { c.finish(throwing: error); return }
                let msg = hasResult
                    ? Message(role: .assistant, blocks: [.text("Report for \(step): found what was asked.")])
                    : Message(role: .assistant, blocks: [.toolUse(ToolUse(id: "g-\(step)", name: "glob", input: ["pattern": "*"]))])
                c.yield(.completed(LLMResponse(message: msg, stopReason: hasResult ? .endTurn : .toolUse, usage: Usage(input: 10, output: 5))))
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

private func step(_ id: String, _ title: String, parallel: Bool? = nil, dependsOn: [String]? = nil, status: String = "pending", checkpoint: Bool = false) -> PlanStep {
    PlanStep(id: id, title: title, detail: "", status: status, checkpoint: checkpoint, criteria: "", evidence: [], note: "", parallel: parallel, dependsOn: dependsOn)
}

private func plan(_ steps: [PlanStep]) -> ResearchPlan {
    var p = ResearchPlan(goal: "g")
    p.steps = steps
    return p
}

@Suite struct HostDelegationSelection {
    @Test func explicitAnnotationsDecide() {
        let p = plan([step("S1", "Review A", parallel: true), step("S2", "Review B", parallel: true), step("S3", "Review C", parallel: false),
                      step("S4", "Synthesize", dependsOn: ["S1", "S2"]), step("S5", "Fetch data", dependsOn: []),
                      step("S6", "Review D", parallel: true, dependsOn: ["S5"])])
        #expect(HostDelegation.eligible(p).map(\.id) == ["S1", "S2", "S5"])
        #expect(HostDelegation.eligible(p, excluding: ["S1"]).map(\.id) == ["S2", "S5"])
        // Once its dependency is done, a parallel step qualifies; a synthesis step stays with the lead agent.
        var later = p
        later.steps[0].status = "done"; later.steps[1].status = "done"; later.steps[4].status = "done"
        #expect(HostDelegation.eligible(later).map(\.id) == ["S6"])
    }

    @Test func unannotatedPlansUseTheStepText() {
        let p = plan([step("S1", "Literature review: CRISPR off-target detection"), step("S2", "Literature review: base editor specificity"),
                      step("S3", "Use the results of S1 to pick an assay"), step("S4", "Synthesize the three reviews into a report"),
                      step("S5", "Summary"), step("S6", "Already running", status: "in_progress")])
        #expect(HostDelegation.eligible(p).map(\.id) == ["S1", "S2"])
        // One annotation anywhere switches the plan to explicit mode.
        var annotated = p
        annotated.steps[0].parallel = true
        #expect(HostDelegation.eligible(annotated).map(\.id) == ["S1"])
    }

    @Test func plansSavedBeforeTheFieldsStillLoad() throws {
        let old = #"{"id":"S1","title":"t","detail":"","status":"pending","checkpoint":false,"criteria":"","evidence":[],"note":""}"#
        let s = try JSONDecoder().decode(PlanStep.self, from: Data(old.utf8))
        #expect(s.parallel == nil && s.dependsOn == nil && s.title == "t")
        let round = try JSONDecoder().decode(PlanStep.self, from: JSONEncoder().encode(step("S2", "x", parallel: true, dependsOn: ["S1"])))
        #expect(round.parallel == true && round.dependsOn == ["S1"])
    }

    @Test func multiPartRequestsAreRecognised() {
        #expect(HostDelegation.looksMultiPart("Write three mini-reviews: (1) CRISPR off-targets, (2) AlphaFold complexes, (3) microbiome drugs."))
        #expect(HostDelegation.looksMultiPart("Compare:\n1. scanpy\n2. Seurat\n3. Bioconductor"))
        #expect(HostDelegation.looksMultiPart("请写综述：\n- 碱基编辑脱靶\n- AlphaFold 复合物"))
        #expect(HostDelegation.looksMultiPart("（一）基因组（二）转录组"))
        #expect(!HostDelegation.looksMultiPart("What is the half-life of 3.5 mg doses of drug X in mice?"))
        #expect(!HostDelegation.looksMultiPart("Fix the bug in step 2. Then rerun."))
    }

    @Test func turnSplitWaitsForThePlan() {
        // Research protocol on, no plan yet: the lead agent grounds and plans first.
        #expect(!HostDelegation.mayDelegateTurn(groundingRequired: true, plan: ResearchPlan(goal: "g")))
        #expect(HostDelegation.mayDelegateTurn(groundingRequired: true, plan: plan([step("S1", "Review A")])))
        #expect(HostDelegation.mayDelegateTurn(groundingRequired: false, plan: ResearchPlan(goal: "g")))
    }

    @Test func briefCarriesTheStepAndThePlan() {
        var p = plan([step("S1", "Review A"), step("S2", "Review B")])
        p.background = "known: X [@k1]"
        var s = p.steps[0]
        s.detail = "search PubMed"; s.criteria = "5 papers"
        let b = HostDelegation.brief(step: s, plan: p, others: [p.steps[1]])
        #expect(b.contains("<delegated_step id=\"S1\">") && b.contains("Plan goal: g") && b.contains("[@k1]")
                && b.contains("How: search PubMed") && b.contains("Done when: 5 papers") && b.contains("S2 Review B"))
    }
}

@Suite struct HostDelegationRuns {
    func services(worker: LLMProvider, mode: PermissionMode = .auto) throws -> SessionServices {
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let s = try SessionServices(taskId: "t1", workspace: ws, models: RoleModels(main: (ScriptedProvider(replies: []), "m"), worker: (worker, "w")),
                                    secrets: EnvironmentSecretStore(), permissionMode: mode)
        s.memoryRoot = ws.appendingPathComponent("memory")
        s.research.groundingRequired = false
        s.toolset = BuiltinTools.all().sorted { $0.name < $1.name }
        return s
    }

    static let setPlan: JSON = ["action": "set", "goal": "three mini-reviews", "steps": [
        ["id": "S1", "title": "Review topic A", "parallel": true],
        ["id": "S2", "title": "Review topic B", "parallel": true],
        ["id": "S3", "title": "Review topic C", "parallel": true, "checkpoint": true],
        ["id": "S4", "title": "Synthesize the reviews", "depends_on": ["S1", "S2", "S3"]],
    ]]

    @Test func planUpdateRunsIndependentStepsOnWorkers() async throws {
        let model = FakeWorkerModel()
        let s = try services(worker: model)
        s.delegation.maxParallel = 2
        let agents = LockedBox<[String]>([])
        s.emit = { e in if case .agentStarted(let id, let role, let parent, let purpose) = e { agents.mutate { $0.append("\(role.rawValue)|\(parent)|\(purpose)|\(id)") } } }
        let main = AgentSession(id: "main", role: .main, services: s, tools: s.toolset)
        guard case .toolResult(let r) = await main.execute(ToolUse(id: "u1", name: "update_plan", input: Self.setPlan)) else { Issue.record("no result"); return }

        #expect(r.content.contains("<host_delegation>") && r.content.contains("Report for S1") && r.content.contains("Report for S2") && r.content.contains("Report for S3"))
        #expect(!r.content.contains("Report for S4"), "the synthesis step stays with the lead agent")
        #expect(model.peak.value == 2, "bounded concurrency, and really parallel (peak \(model.peak.value))")
        let steps = Dictionary(uniqueKeysWithValues: s.research.snapshot.steps.map { ($0.id, $0) })
        #expect(steps["S1"]?.status == "done" && steps["S2"]?.status == "done")
        #expect(steps["S3"]?.status == "in_progress", "a checkpoint is left for the lead agent to pass")
        #expect(steps["S4"]?.status == "pending")
        #expect(steps["S1"]?.evidence.count == 1 && s.ledger.receipt(steps["S1"]!.evidence[0])?.role == .worker)
        #expect(agents.value.count == 3 && agents.value.allSatisfy { $0.hasPrefix("worker|main|S") })
        // Worker tool calls are in the audit trail, and each report is saved.
        let audit = try AuditLog.read(s.taskDir.appendingPathComponent("audit.jsonl"))
        #expect(audit.filter { $0.kind == "tool_call" && $0.actor == "worker" }.count == 3)
        #expect(audit.contains { $0.kind == "host_delegation" })
        let files = try FileManager.default.contentsOfDirectory(atPath: s.taskDir.appendingPathComponent("workers").path).filter { $0.hasSuffix(".md") }
        #expect(files.count == 3)

        // Steps already handed out are not run again on the next plan update.
        let calls = model.calls.value
        var revised = Self.setPlan.objectValue ?? [:]
        revised["rationale"] = "same steps, reworded after the reviews came back"
        guard case .toolResult(let r2) = await main.execute(ToolUse(id: "u2", name: "update_plan", input: .object(revised))) else { Issue.record("no result"); return }
        #expect(!r2.content.contains("<host_delegation>"))
        #expect(model.calls.value == calls)
    }

    @Test func multiPartTurnRunsOnWorkersBeforeTheMainModel() async throws {
        // Long enough that all three workers are mid-call together even when setting one up is slow.
        let model = FakeWorkerModel(delayMs: 400)
        let s = try services(worker: model)
        // With the research protocol on and no plan yet, the lead agent plans first: nothing is split.
        s.research.groundingRequired = true
        let planner = ScriptedProvider(replies: ["I will ground and plan first."])
        s.models.main = (planner, "m")
        _ = try await AgentSession(id: "main", role: .main, services: s, tools: s.toolset)
            .send("Write three mini-reviews: (1) topic one, (2) topic two, (3) topic three.")
        let asked = planner.requests.first?.messages.last?.blocks.compactMap(\.text).joined() ?? ""
        #expect(model.calls.value == 0 && !asked.contains("<host_delegation>") && asked.contains("<planning_note>"))

        s.research.groundingRequired = false
        let mainModel = ScriptedProvider(replies: ["Combined answer."])
        s.models.main = (mainModel, "m")
        let main = AgentSession(id: "main", role: .main, services: s, tools: s.toolset)
        let reply = try await main.send("Write three mini-reviews: (1) topic one, (2) topic two, (3) topic three. Then summarise.")
        #expect(reply?.plainText == "Combined answer.")
        let first = mainModel.requests.first?.messages.last?.blocks.compactMap(\.text).joined() ?? ""
        #expect(first.contains("<host_delegation>") && first.contains("Report for T1") && first.contains("Report for T2") && first.contains("Report for T3"))
        #expect(model.peak.value == 3)
        let audit = try AuditLog.read(s.taskDir.appendingPathComponent("audit.jsonl"))
        #expect(audit.filter { $0.kind == "tool_call" && $0.actor == "worker" }.count == 3)
        #expect(audit.contains { $0.kind == "host_decomposition" })
        #expect(s.research.snapshot.steps.isEmpty, "the request's parts are not plan steps")

        // A request the decomposer will not split, or one without a list, goes straight to the main model.
        model.split = false
        let calls = model.calls.value
        let main2 = AgentSession(id: "main", role: .main, services: s, tools: s.toolset)
        _ = try await main2.send("Do these: (1) read the file, (2) fix the typo in it.")
        _ = try await main2.send("What is the boiling point of ethanol?")
        #expect(model.calls.value == calls)
    }

    @Test func nothingHappensWithoutPermissionOrWithAutoOff() async throws {
        let model = FakeWorkerModel()
        let s = try services(worker: model, mode: .plan)
        let main = AgentSession(id: "main", role: .main, services: s, tools: s.toolset)
        guard case .toolResult(let r) = await main.execute(ToolUse(id: "u1", name: "update_plan", input: Self.setPlan)) else { Issue.record("no result"); return }
        #expect(r.content.contains("not allowed") && model.calls.value == 0)
        #expect(s.research.snapshot.steps.allSatisfy { $0.status == "pending" })

        let s2 = try services(worker: model)
        s2.delegation.auto = false
        let main2 = AgentSession(id: "main", role: .main, services: s2, tools: s2.toolset)
        guard case .toolResult(let r2) = await main2.execute(ToolUse(id: "u1", name: "update_plan", input: Self.setPlan)) else { Issue.record("no result"); return }
        #expect(!r2.content.contains("<host_delegation>") && model.calls.value == 0)
        // Nor is a multi-part request split at the start of the turn (the app's and CLI's off switch).
        let mainModel = ScriptedProvider(replies: ["Answer."])
        s2.models.main = (mainModel, "m")
        let main3 = AgentSession(id: "main", role: .main, services: s2, tools: s2.toolset)
        _ = try await main3.send("Write three mini-reviews: (1) topic one, (2) topic two, (3) topic three.")
        let first = mainModel.requests.first?.messages.last?.blocks.compactMap(\.text).joined() ?? ""
        #expect(!first.contains("<host_delegation>") && model.calls.value == 0)
        let audit = (try? AuditLog.read(s2.taskDir.appendingPathComponent("audit.jsonl"))) ?? []
        #expect(!audit.contains { $0.kind.hasPrefix("host_") })
    }

    @Test func stopEndsTheWorkers() async throws {
        let model = FakeWorkerModel(delayMs: 30_000)
        let s = try services(worker: model)
        let main = AgentSession(id: "main", role: .main, services: s, tools: s.toolset)
        let started = Date()
        let run = Task { await main.execute(ToolUse(id: "u1", name: "update_plan", input: Self.setPlan)) }
        while model.inFlight.value < 3 && Date().timeIntervalSince(started) < 5 { try await Task.sleep(nanoseconds: 20_000_000) }
        main.cancel()
        run.cancel()
        guard case .toolResult(let r) = await run.value else { Issue.record("no result"); return }
        #expect(Date().timeIntervalSince(started) < 10, "Stop must not wait for the workers")
        #expect(r.content.contains("was stopped"))
        #expect(s.research.snapshot.steps.filter { ["S1", "S2", "S3"].contains($0.id) }.allSatisfy { $0.status == "pending" && $0.note == "worker stopped" })
    }
}

@Suite struct SubagentCLIConversations {
    /// Workers of one role share a lineage key (cache routing) but each gets its own CLI conversation,
    /// so concurrent workers on a CLI model neither share nor kill one agy process.
    @Test func eachSubagentHasItsOwnCLIConversation() throws {
        let (s, _) = try makeServices()
        let a = s.makeSubagent(role: .worker), b = s.makeSubagent(role: .worker)
        let main = AgentSession(id: "main", role: .main, services: s, tools: [])
        #expect(a.cache.lineageKey == b.cache.lineageKey)
        #expect(a.cliConversation != nil && a.cliConversation != b.cliConversation && main.cliConversation == nil)
        let profile = ProviderProfile(id: "agy", displayName: "agy", family: .cliAgent, baseURL: "", auth: .none, apiKeyRef: "", models: [])
        var req = LLMRequest(model: "m", system: "", tools: [], messages: [], maxTokens: 10, cache: a.cache)
        #expect(CLIAgentProvider.conversationKey(req, profile: profile) == a.cache.lineageKey + "|agy")
        req.host.conversation = a.cliConversation
        #expect(CLIAgentProvider.conversationKey(req, profile: profile) == a.cliConversation! + "|agy")
    }
}
