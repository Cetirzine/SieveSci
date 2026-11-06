import Foundation
import Testing
@testable import SieveSciCore

/// A naming model that fails, or answers only after a delay.
private final class SlowOrFailingModel: LLMProvider, @unchecked Sendable {
    let profile = ProviderProfile(id: "title-fake", displayName: "title", family: .openaiChat, baseURL: "http://localhost", auth: .none, apiKeyRef: "", models: ["w"])
    let fail: Bool
    let delayMs: UInt64
    let reply: String
    let calls = LockedBox(0)
    /// Runs while the call is in flight (e.g. the user renaming the conversation).
    var during: (@Sendable () -> Void)?
    init(fail: Bool = false, delayMs: UInt64 = 0, reply: String = "Title") { self.fail = fail; self.delayMs = delayMs; self.reply = reply }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        calls.mutate { $0 += 1 }
        let (fail, delay, reply, during) = (self.fail, delayMs, self.reply, self.during)
        return AsyncThrowingStream { c in
            let t = Task {
                during?()
                do { try await Task.sleep(nanoseconds: delay * 1_000_000) } catch { c.finish(throwing: error); return }
                if fail { c.finish(throwing: ProviderError.http(status: 500, body: "boom")); return }
                c.yield(.completed(LLMResponse(message: Message(role: .assistant, blocks: [.text(reply)]), stopReason: .endTurn, usage: Usage(input: 10, output: 3))))
                c.finish()
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
}

private func exchange(_ q: String = "SpCas9-HF1 在 EMX1 位点的脱靶率是否比野生型低？请查文献。", _ a: String = "是的，GUIDE-seq 显示脱靶位点从 25 个降到 1 个。") -> [Message] {
    // The first user message carries host context blocks before the user's words, as in a real session.
    [Message(role: .user, blocks: [.text("<context>turn 1</context>"), .text(q + "\n\n<context>\nmodel: m\n</context>")]),
     Message(role: .assistant, blocks: [.text("Let me search.")]),
     Message(role: .user, blocks: [.text("[tool result] …")]),
     Message(role: .assistant, blocks: [.text(a)])]
}

private func services(main: LLMProvider, worker: LLMProvider?) throws -> (SessionServices, LockedBox<[AgentEvent]>) {
    let ws = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    let s = try SessionServices(taskId: "t1", workspace: ws, models: RoleModels(main: (main, "main-m"), worker: worker.map { ($0, "worker-m") }),
                                secrets: EnvironmentSecretStore())
    let events = LockedBox<[AgentEvent]>([])
    s.emit = { ev in if case .titleChanged = ev { events.mutate { $0.append(ev) } } }
    return (s, events)
}

@Suite struct TitleCleaning {
    @Test func stripsQuotesLabelsAndPeriods() {
        #expect(TitleSummarizer.clean("\"CRISPR off-target screening.\"") == "CRISPR off-target screening")
        #expect(TitleSummarizer.clean("“SpCas9-HF1 脱靶评估”。") == "SpCas9-HF1 脱靶评估")
        #expect(TitleSummarizer.clean("Title: Kinase hit selectivity") == "Kinase hit selectivity")
        #expect(TitleSummarizer.clean("标题：激酶抑制剂选择性") == "激酶抑制剂选择性")
        #expect(TitleSummarizer.clean("**IC50 curve refitting**") == "IC50 curve refitting")
        #expect(TitleSummarizer.clean("# 「单细胞测序质控」") == "单细胞测序质控")
    }

    @Test func takesTheFirstLineAndDropsReasoning() {
        #expect(TitleSummarizer.clean("<think>the user asks about Cas9</think>\n\nCas9 fidelity at EMX1\nThis title names…") == "Cas9 fidelity at EMX1")
        #expect(TitleSummarizer.clean("\n\n  Protein   folding   stability  \n") == "Protein folding stability")
    }

    @Test func cutsToTheLengthLimits() throws {
        let zh = try #require(TitleSummarizer.clean("基于单细胞转录组测序数据的小鼠二十个器官细胞图谱构建与比较分析研究"))
        #expect(zh.count == TitleSummarizer.maxCJKCharacters)
        let en = try #require(TitleSummarizer.clean("A very long title that keeps going on about many different research topics forever"))
        #expect(en.split(separator: " ").count == TitleSummarizer.maxWords)
        #expect(en == "A very long title that keeps going on")
        let word = try #require(TitleSummarizer.clean(String(repeating: "x", count: 200)))
        #expect(word.count <= TitleSummarizer.maxCharacters)
    }

    @Test func emptyOrJunkGivesNothing() {
        #expect(TitleSummarizer.clean("") == nil)
        #expect(TitleSummarizer.clean("  \n \"\" 。") == nil)
        #expect(TitleSummarizer.clean("<think>only thinking</think>") == nil)
        #expect(TitleSummarizer.clean("A") == nil)
    }

    @Test func firstExchangeSkipsHostContext() throws {
        let ex = try #require(TitleSummarizer.firstExchange(exchange()))
        #expect(ex.question == "SpCas9-HF1 在 EMX1 位点的脱靶率是否比野生型低？请查文献。")
        #expect(ex.reply.hasPrefix("是的，GUIDE-seq"), "the reply that closed the turn, not the first tool-call text")
        #expect(TitleSummarizer.firstExchange([Message.user("<context>x</context>")]) == nil)
    }
}

@Suite struct AutoTitles {
    @Test func theWorkerModelNamesTheConversation() async throws {
        let main = ScriptedProvider(id: "main", replies: [])
        let worker = ScriptedProvider(id: "worker", replies: ["「SpCas9-HF1 脱靶率」"])
        let (s, events) = try services(main: main, worker: worker)
        let out = await TitleSummarizer.autoTitle(services: s, transcript: exchange())
        #expect(out == .titled("SpCas9-HF1 脱靶率"))
        #expect(main.requests.isEmpty, "the main model is not used when a worker is set")
        let req = try #require(worker.requests.first)
        #expect(req.model == "worker-m")
        #expect(req.system == TitleSummarizer.system)
        #expect(req.tools.isEmpty && req.maxTokens <= 256, "a cheap call")
        #expect(req.messages.first?.plainText.contains("SpCas9-HF1 在 EMX1") == true)
        #expect(req.messages.first?.plainText.contains("<context>") == false, "host context is not sent")
        #expect(SessionStore.title(dir: s.taskDir) == "SpCas9-HF1 脱靶率")
        #expect(SessionStore.autoTitle(dir: s.taskDir) == "SpCas9-HF1 脱靶率")
        #expect(!SessionStore.hasManualTitle(dir: s.taskDir))
        guard case .titleChanged(let task, let title)? = events.value.first else { Issue.record("no titleChanged event"); return }
        #expect(task == "t1" && title == "SpCas9-HF1 脱靶率")
        // Once named, later turns do not call the model again.
        #expect(await TitleSummarizer.autoTitle(services: s, transcript: exchange()) == .skipped)
        #expect(worker.requests.count == 1)
    }

    @Test func withoutAWorkerTheMainModelIsUsed() async throws {
        let main = ScriptedProvider(id: "main", replies: ["Cas9 fidelity at EMX1"])
        let (s, _) = try services(main: main, worker: nil)
        #expect(await TitleSummarizer.autoTitle(services: s, transcript: exchange()) == .titled("Cas9 fidelity at EMX1"))
        #expect(main.requests.first?.model == "main-m")
    }

    @Test func aFailedCallKeepsTheFirstQuestion() async throws {
        let (s, events) = try services(main: ScriptedProvider(replies: []), worker: SlowOrFailingModel(fail: true))
        let transcript = exchange()
        for m in transcript { SessionStore.shared.append(m, task: "t1", agent: "main", dir: s.taskDir) }
        let before = SessionStore.title(dir: s.taskDir)
        #expect(await TitleSummarizer.autoTitle(services: s, transcript: transcript) == .failed)
        #expect(SessionStore.autoTitle(dir: s.taskDir) == nil)
        #expect(SessionStore.title(dir: s.taskDir) == before)
        #expect(before?.hasPrefix("SpCas9-HF1 在 EMX1") == true)
        #expect(events.value.isEmpty)
    }

    @Test func anUnusableReplyIsAFailure() async throws {
        let (s, _) = try services(main: ScriptedProvider(replies: []), worker: ScriptedProvider(replies: ["  \"\" "]))
        #expect(await TitleSummarizer.autoTitle(services: s, transcript: exchange()) == .failed)
        #expect(SessionStore.autoTitle(dir: s.taskDir) == nil)
    }

    @Test func aSlowCallTimesOut() async throws {
        let (s, _) = try services(main: ScriptedProvider(replies: []), worker: SlowOrFailingModel(delayMs: 5000))
        let started = Date()
        #expect(await TitleSummarizer.autoTitle(services: s, transcript: exchange(), timeout: 0.2) == .failed)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(SessionStore.autoTitle(dir: s.taskDir) == nil)
    }

    @Test func aNameGivenByHandIsNeverReplaced() async throws {
        let worker = ScriptedProvider(replies: ["Generated name"])
        let (s, events) = try services(main: ScriptedProvider(replies: []), worker: worker)
        SessionStore.setTitle("My EMX1 notes", task: "t1", in: s.workspace)
        #expect(await TitleSummarizer.autoTitle(services: s, transcript: exchange()) == .skipped)
        #expect(worker.requests.isEmpty, "no call for a conversation named by hand")
        #expect(SessionStore.title(dir: s.taskDir) == "My EMX1 notes")
        #expect(events.value.isEmpty)
    }

    @Test func aRenameDuringTheCallWins() async throws {
        let worker = SlowOrFailingModel(delayMs: 50, reply: "Generated name")
        let box = LockedBox<SessionServices?>(nil)
        worker.during = { if let s = box.value { SessionStore.setTitle("Renamed meanwhile", task: "t1", in: s.workspace) } }
        let (s, events) = try services(main: ScriptedProvider(replies: []), worker: worker)
        box.mutate { $0 = s }
        #expect(await TitleSummarizer.autoTitle(services: s, transcript: exchange()) == .skipped)
        #expect(SessionStore.autoTitle(dir: s.taskDir) == nil)
        #expect(SessionStore.title(dir: s.taskDir) == "Renamed meanwhile")
        #expect(events.value.isEmpty)
    }

    @Test func clearingAManualNameShowsTheGeneratedOne() async throws {
        let (s, _) = try services(main: ScriptedProvider(replies: []), worker: ScriptedProvider(replies: ["Cas9 fidelity"]))
        _ = await TitleSummarizer.autoTitle(services: s, transcript: exchange())
        SessionStore.setTitle("Mine", task: "t1", in: s.workspace)
        #expect(SessionStore.title(dir: s.taskDir) == "Mine")
        SessionStore.setTitle("  ", task: "t1", in: s.workspace)
        #expect(SessionStore.title(dir: s.taskDir) == "Cas9 fidelity")
    }

    @Test func theWorkbenchNamesAfterTheFirstTurnInTheBackground() async throws {
        let worker = ScriptedProvider(id: "worker", replies: ["Cas9 fidelity at EMX1"])
        let (s, events) = try services(main: ScriptedProvider(id: "main", replies: Array(repeating: "HF1 lowers off-target editing at EMX1.", count: 8)), worker: worker)
        s.research.groundingRequired = false
        let b = Workbench(services: s)
        await b.runTurn("Does SpCas9-HF1 reduce off-target editing at EMX1?")
        for _ in 0..<100 where b.isNamingConversation || events.value.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(SessionStore.title(dir: s.taskDir) == "Cas9 fidelity at EMX1")
        #expect(events.value.count == 1)
        await b.runTurn("And at VEGFA?")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(worker.requests.count == 1, "named once")
    }

    @Test func theWorkbenchSwitchOff() async throws {
        let worker = ScriptedProvider(id: "worker", replies: ["Should not be used"])
        let (s, _) = try services(main: ScriptedProvider(id: "main", replies: Array(repeating: "Done.", count: 8)), worker: worker)
        s.research.groundingRequired = false
        let b = Workbench(services: s)
        b.autoTitle = false
        await b.runTurn("Summarize the plate reader data")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(worker.requests.isEmpty)
        #expect(SessionStore.autoTitle(dir: s.taskDir) == nil)
    }
}
