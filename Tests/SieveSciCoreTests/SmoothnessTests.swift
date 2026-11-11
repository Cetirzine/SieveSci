import Foundation
import Testing
@testable import SieveSciCore

/// 0.4.0: searches that do not stall on a large workspace, reviews that end, modes for light requests,
/// the shared board, and the built-in web search.
@Suite struct FileSearching {
    func tree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-search-" + UUID().uuidString)
        let fm = FileManager.default
        for d in ["data", "src/deep", "node_modules/pkg", ".git"] { try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        try "id\tscore\nA\t0.8096\nB\t0.1200\nC\t0.4312\n".write(to: root.appendingPathComponent("data/scores.tsv"), atomically: true, encoding: .utf8)
        try "def top_pocket_changed(x):\n    return x  # n_entity_clusters\n".write(to: root.appendingPathComponent("src/deep/a.py"), atomically: true, encoding: .utf8)
        try "top_pocket_changed in a dependency\n".write(to: root.appendingPathComponent("node_modules/pkg/index.js"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x00, 0x00] + Array("top_pocket_changed".utf8)).write(to: root.appendingPathComponent("data/blob.dat"))
        try Data(Array("top_pocket_changed".utf8)).write(to: root.appendingPathComponent("data/picture.png"))
        return root
    }

    @Test func literalsAreReadFromThePattern() {
        #expect(FileSearch.literals(of: #"0\.8096|0\.4312"#) == ["0.8096", "0.4312"])
        #expect(FileSearch.literals(of: "n_entity_clusters") == ["n_entity_clusters"])
        #expect(FileSearch.literals(of: "scoring functions.*correl") == nil)
        #expect(FileSearch.literals(of: #"\d+ GB"#) == nil)
        #expect(FileSearch.literals(of: "a|") == nil, "an empty alternative matches every line")
    }

    @Test func aLiteralSearchFindsLinesWithTheirNumbers() async throws {
        let root = try tree()
        let r = try await FileSearch.grep(pattern: #"0\.8096|0\.4312"#, root: root)
        #expect(r.lines.count == 2)
        #expect(r.lines.contains { $0.hasSuffix("scores.tsv:2:A\t0.8096") })
        #expect(r.lines.contains { $0.hasSuffix("scores.tsv:4:C\t0.4312") })
        #expect(r.note == nil)
    }

    @Test func dependenciesAndBinaryFilesAreLeftOut() async throws {
        let root = try tree()
        let r = try await FileSearch.grep(pattern: "top_pocket_changed", root: root)
        #expect(r.lines.count == 1)
        #expect(r.lines[0].contains("src/deep/a.py:1:"))
    }

    @Test func otherExpressionsStillWork() async throws {
        let root = try tree()
        var o = FileSearch.Options()
        o.ignoreCase = true
        let r = try await FileSearch.grep(pattern: #"RETURN\s+x"#, root: root, options: o)
        #expect(r.lines.count == 1 && r.lines[0].contains("a.py:2:"))
        let anchored = try await FileSearch.grep(pattern: #"^B\t"#, root: root)
        #expect(anchored.lines.count == 1 && anchored.lines[0].contains("scores.tsv:3:"))
    }

    @Test func oneNamedFileIsSearchedWhateverItsKind() async throws {
        let root = try tree()
        let r = try await FileSearch.grep(pattern: "top_pocket_changed", root: root.appendingPathComponent("node_modules/pkg/index.js"))
        #expect(r.lines.count == 1)
    }

    @Test func aLargeFileIsNamedNotSearched() async throws {
        let root = try tree()
        var o = FileSearch.Options()
        o.maxFileBytes = 20
        let r = try await FileSearch.grep(pattern: "0\\.8096", root: root, options: o)
        #expect(r.lines.isEmpty)
        #expect(r.skippedLarge.contains { $0.hasSuffix("scores.tsv") })
        #expect(r.note?.contains("not searched") == true)
    }

    @Test func aBigTableIsSearchedInWellUnderASecond() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-big-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var text = ""
        text.reserveCapacity(24_000_000)
        for i in 0..<400_000 { text += "row\(i)\t0.\(i % 9973)\tsome filler text to make the line longer\n" }
        text += "needle_here\t1\n"
        try text.write(to: root.appendingPathComponent("big.tsv"), atomically: true, encoding: .utf8)
        let started = Date()
        let r = try await FileSearch.grep(pattern: "needle_here", root: root)
        #expect(r.lines.count == 1 && r.lines[0].contains(":400001:"))
        #expect(Date().timeIntervalSince(started) < 5, "alone it takes a few hundredths of a second")
    }

    /// Times searches on a real workspace: SIEVESCI_SEARCH_PROBE=<folder> [SIEVESCI_SEARCH_PATTERNS=a;;b].
    @Test func realWorkspaceProbe() async throws {
        guard let dir = ProcessInfo.processInfo.environment["SIEVESCI_SEARCH_PROBE"] else { return }
        let patterns = (ProcessInfo.processInfo.environment["SIEVESCI_SEARCH_PATTERNS"] ?? "top_pocket_changed").components(separatedBy: ";;")
        for p in patterns {
            let t = Date()
            let r = try await FileSearch.grep(pattern: p, root: URL(fileURLWithPath: dir))
            print("PROBE grep \(p.prefix(40)): \(String(format: "%.2f", Date().timeIntervalSince(t))) s, \(r.lines.count) lines, \(r.filesSearched)/\(r.filesTotal) files, note: \(r.note ?? "-")")
        }
        let t = Date()
        let w = FileSearch.walk(URL(fileURLWithPath: dir), deadline: Date().addingTimeInterval(10))
        print("PROBE walk: \(String(format: "%.2f", Date().timeIntervalSince(t))) s, \(w.files.count) files, truncated \(w.truncated)")
    }

    @Test func partOfALargeFileIsReadWithoutLoadingIt() async throws {
        let (s, ws) = try makeServices()
        var text = ""
        text.reserveCapacity(10_000_000)
        for i in 1...300_000 { text += "line \(i) with some padding to make it long enough\r\n" }
        try text.write(to: ws.appendingPathComponent("big.log"), atomically: true, encoding: .utf8)
        let ctx = ToolContext(workspace: ws, sessionId: "main", role: .main, ledger: s.ledger, audit: s.audit, services: s)
        let out = try await ReadFileTool().run(["path": "big.log", "offset": 250_000, "limit": 2], ctx)
        #expect(out.text.contains("250000\tline 250000 with some padding") && out.text.contains("250001\tline 250001"))
        #expect(out.text.contains("continue with offset 250002"))
        let end = try await ReadFileTool().run(["path": "big.log", "offset": 300_000, "limit": 5], ctx)
        #expect(end.text.hasSuffix("line 300000 with some padding to make it long enough"))
    }

    @Test func aGlobWalksOnlyWhereItCanMatch() throws {
        #expect(FileSearch.scope(of: "benchmark/*.tsv").prefix == "benchmark")
        #expect(FileSearch.scope(of: "benchmark/*.tsv").depth == 1)
        #expect(FileSearch.scope(of: "**/*.py").depth == nil)
        #expect(FileSearch.scope(of: "*.csv").prefix == "" && FileSearch.scope(of: "*.csv").depth == 1)
        #expect(FileSearch.scope(of: "a/b/*/c.txt").prefix == "a/b" && FileSearch.scope(of: "a/b/*/c.txt").depth == 2)
    }

    @Test func theToolsUseIt() async throws {
        let (s, ws) = try makeServices()
        let fm = FileManager.default
        try fm.createDirectory(at: ws.appendingPathComponent("data/sub"), withIntermediateDirectories: true)
        try "x,y\n1,2\n".write(to: ws.appendingPathComponent("data/a.csv"), atomically: true, encoding: .utf8)
        try "x,y\n3,4\n".write(to: ws.appendingPathComponent("data/sub/b.csv"), atomically: true, encoding: .utf8)
        let ctx = ToolContext(workspace: ws, sessionId: "main", role: .main, ledger: s.ledger, audit: s.audit, services: s)
        let flat = try await GlobTool().run(["pattern": "data/*.csv"], ctx)
        #expect(flat.text == "data/a.csv")
        let deep = try await GlobTool().run(["pattern": "**/*.csv"], ctx)
        #expect(Set(deep.text.split(separator: "\n").map(String.init)) == ["data/a.csv", "data/sub/b.csv"])
        let hit = try await GrepTool().run(["pattern": "3,4", "path": "data"], ctx)
        #expect(hit.text.contains("data/sub/b.csv:2:3,4"))
        let missing = try await GrepTool().run(["pattern": "x", "path": "nowhere"], ctx)
        #expect(missing.isError)
    }
}

@Suite struct Modes {
    @Test func aQuestionAboutAFieldIsALookup() {
        #expect(TurnScale.classify("总结一下多肽-蛋白对接这个方向有哪些东西") == .lookup)
        #expect(TurnScale.classify("What are the main approaches to peptide–protein docking?") == .lookup)
        #expect(TurnScale.classify("CRISPR 碱基编辑的最新进展") == .lookup)
        #expect(TurnScale.classify("总结一下 data/results.csv 里的结果") != .lookup, "the user's own file is not a lookup")
        #expect(TurnScale.classify("调研后设计一个新的打分函数并在基准上评估") == .research, "work to do is research")
    }

    @Test func learningReadingAndWritingHaveTheirOwnModes() {
        #expect(TurnScale.classify("教我什么是药效团，零基础") == .learn)
        #expect(TurnScale.classify("Quiz me on enzyme kinetics") == .learn)
        #expect(TurnScale.classify("解读这篇 10.1038/s41586-024-07487-w") == .read)
        #expect(TurnScale.classify("Summarize https://arxiv.org/abs/2401.00001") == .read)
        #expect(TurnScale.classify("润色这段话：We has found that the protein bind strongly.") == .write)
        #expect(TurnScale.classify("Translate into English:\n\n本研究提出了一种新的方法。\n\n结果表明其有效。") == .write)
        #expect(TurnScale.classify("写一篇关于多肽对接的综述并润色") == .research, "writing a new document is work")
    }

    @Test func theOldCallsStillHold() {
        #expect(TurnScale.classify("你好") == .chat)
        #expect(TurnScale.classify("which file is the biggest here?") == .quick)
        #expect(TurnScale.classify("分析一下这个报错") == .quick, "a small concrete task, whatever its verb")
        #expect(TurnScale.classify("分析一下这个靶点") == .unclear)
        #expect(TurnScale.classify("/brainstorm mobile inference") == .research)
        #expect(TurnScale.unclear.contextLine?.contains("lightest reading") == true)
        #expect(TurnScale.lookup.isLight && !TurnScale.research.isLight)
    }

    @Test func aNamedModeWinsOnce() async throws {
        let (s, _) = try makeServices(ScriptedProvider(replies: ["Short answer.", "Again."]))
        s.research.groundingRequired = false
        await s.freezeToolset()
        let main = AgentSession(id: "main", role: .main, services: s, tools: s.toolset)
        s.research.forceNextScale(.learn)
        _ = try await main.send("蛋白质折叠")
        #expect(s.research.turnScale == .learn)
        #expect(main.transcript.first?.plainText.contains("turn: learning") == true)
        _ = try await main.send("蛋白质折叠的机制研究")
        #expect(s.research.turnScale != .learn, "the named mode covers one message")
    }
}

@Suite struct Board {
    @Test func entriesAreLayeredAndSurviveReopening() throws {
        let (s, ws) = try makeServices()
        let e = s.board.post(kind: .fact, title: "Recall@100 is 0.81 on the leakage-controlled test", summary: "Measured by scripts/eval.py.", evidence: ["r3"], author: "worker")
        #expect(e?.id == "b1")
        #expect(s.board.post(kind: .fact, title: "Recall@100 is 0.81 on the leakage-controlled test", summary: "Measured by scripts/eval.py.", author: "worker") == nil, "no duplicates")
        s.board.post(kind: .deadEnd, title: "局部 MMFF 最小化拉不回出袋肽", summary: "strict 仅 36.5%→38.2%", author: "main")
        #expect(s.board.index().split(separator: "\n").count == 2)
        #expect(!s.board.index().contains("Measured by"), "the index is titles only")
        #expect(SharedBoard.render(s.board.entry("b1")!).contains("r3"))
        #expect(s.board.search("出袋肽 最小化").first?.id == "b2", "Chinese is matched without spaces")
        let again = SharedBoard(url: ws.appendingPathComponent(".sievesci/tasks/t1/state/board.jsonl"))
        #expect(again.all.count == 2)
        #expect(SharedBoard.carryOver(workspace: ws, excluding: "other").contains("t1/b1"))
        #expect(SharedBoard.carryOver(workspace: ws, excluding: "t1").isEmpty)
        #expect(SharedBoard.foreign("t1/b2", workspace: ws)?.kind == .deadEnd)
    }

    @Test func aWorkerReportIsLeftForItsSuccessor() async throws {
        let report = String(repeating: "Cleaned the table and wrote data/clean.tsv; 12 rows dropped for missing ids. ", count: 3)
        let (s, _) = try makeServices(ScriptedProvider(replies: [report, "ok"]))
        await s.freezeToolset()
        let w = s.makeSubagent(role: .worker, purpose: "S2 · clean the table")
        _ = try await w.send("Clean the table.")
        #expect(s.board.all.first?.kind == .handoff)
        #expect(s.board.all.first?.title == "S2 · clean the table")
        // The next worker starts with the index; a blind verifier never sees it.
        #expect(s.roleIntro(.worker, task: "continue S2").contains("S2 · clean the table"))
        #expect(!s.roleIntro(.verifier, task: "x").contains("shared_board"))
        #expect(!s.roleIntro(.worker, task: "x", blind: true).contains("shared_board"))
    }

    @Test func factsNeedEvidenceAndTheVerifierIsKeptOut() async throws {
        let (s, ws) = try makeServices()
        let ctx = ToolContext(workspace: ws, sessionId: "w", role: .worker, ledger: s.ledger, audit: s.audit, services: s)
        let bare = try await BoardTool().run(["action": "post", "kind": "fact", "title": "It works"], ctx)
        #expect(bare.isError)
        let open = try await BoardTool().run(["action": "post", "kind": "open", "title": "Is the split leaky?"], ctx)
        #expect(!open.isError)
        let blind = ToolContext(workspace: ws, sessionId: "v", role: .verifier, readableRoots: [ws.appendingPathComponent("v").path], ledger: s.ledger, audit: s.audit, services: s)
        let hidden = try await BoardTool().run(["action": "list"], blind)
        #expect(hidden.isError)
    }
}

@Suite struct ReviewsThatEnd {
    @Test func aSkippedReviewIsNotCalledAPass() async throws {
        let pass = #"{"verdict":"pass","issues":[{"severity":"low","what":"axis label missing","evidence":"fig1"}],"notes":"fine"}"#
        let (s, _) = try makeServices(ScriptedProvider(replies: []), checker: ScriptedProvider(id: "chk", replies: [pass, pass]))
        await s.freezeToolset()
        var step = PlanStep(id: "S1", title: "Measure", detail: "", status: "done", checkpoint: true, criteria: "n>10", evidence: ["r1"], note: "first")
        let first = await s.supervisor.reviewCheckpoint(step)
        #expect(first.contains("passed independent review"))
        #expect(first.contains("axis label missing"), "minor points ride along with a pass")
        let same = await s.supervisor.reviewCheckpoint(step)
        #expect(same.contains("NOT reviewed"), "the same work is not reviewed twice, and is not called passed")
        step.note = "second, with other evidence"
        step.evidence = ["r1", "r2"]
        let changed = await s.supervisor.reviewCheckpoint(step)
        #expect(changed.contains("passed independent review"), "changed work is reviewed again")
        #expect(s.board.all.contains { $0.kind == .review && $0.title.contains("S1") })
    }

    @Test func aReReviewIsToldWhatWasAskedBefore() async throws {
        let revise = #"{"verdict":"revise","issues":[{"severity":"high","what":"n is 8, the criterion says 10","evidence":"r1"}],"required_actions":["rerun with n>=10"]}"#
        let checker = ScriptedProvider(id: "chk", replies: [revise, #"{"verdict":"pass","issues":[]}"#])
        let (s, _) = try makeServices(ScriptedProvider(replies: []), checker: checker)
        await s.freezeToolset()
        var step = PlanStep(id: "S1", title: "Measure", detail: "", status: "done", checkpoint: true, criteria: "n>10", evidence: ["r1"], note: "a")
        _ = await s.supervisor.reviewCheckpoint(step)
        step.note = "b"
        _ = await s.supervisor.reviewCheckpoint(step)
        let second = checker.requests.last?.messages.first?.plainText ?? ""
        #expect(second.contains("This is a re-review"))
        #expect(second.contains("n is 8, the criterion says 10"))
    }

    @Test func reviewersHaveATimeBudget() throws {
        let (s, _) = try makeServices()
        #expect(s.makeSubagent(role: .checker).timeBudget == s.supervisorPolicy.reviewSeconds)
        #expect(s.makeSubagent(role: .verifier).timeBudget == s.supervisorPolicy.verifySeconds)
        #expect(s.makeSubagent(role: .worker).timeBudget == nil)
    }
}

@Suite struct SearchBackends {
    struct Keys: SecretStore {
        let keys: [String: String]
        func secret(for ref: String) -> String? { keys[ref] }
    }

    func client(_ b: WebSearchBackend, _ routes: [(String, String)]) -> WebSearchClient {
        var c = WebSearchConfig()
        c.backend = b
        c.apiKeyRef = WebSearchClient.keyRefs[b] ?? ""
        return WebSearchClient(config: c, secrets: Keys(keys: [c.apiKeyRef: "k"]), http: RoutedHTTP(routes))
    }

    @Test func noKeyNeededByDefault() {
        let c = WebSearchClient(config: WebSearchConfig(), secrets: Keys(keys: [:]))
        #expect(c.config.backend == .builtin && c.config.apiKeyRef.isEmpty && c.effectiveBackend == .builtin)
    }

    @Test func enginesThatAnswerFromMainlandChina() async throws {
        let bocha = #"{"code":200,"data":{"webPages":{"value":[{"name":"AlphaFold 3","url":"https://www.nature.com/articles/x","snippet":"s","summary":"Joint structure prediction.","datePublished":"2024-05-08"}]}}}"#
        let b = try await client(.bocha, [("api.bochaai.com/v1/web-search", bocha)]).search("AlphaFold 3")
        #expect(b == [SearchHit(title: "AlphaFold 3", url: "https://www.nature.com/articles/x", snippet: "Joint structure prediction.", published: "2024-05-08")])
        let zhipu = #"{"id":"1","search_result":[{"title":"PepPCBench","link":"https://example.org/p","content":"A benchmark.","publish_date":"2026-01-02"},{"title":"repost","link":"https://blog.csdn.net/a","content":"x"}]}"#
        let z = try await client(.zhipu, [("open.bigmodel.cn/api/paas/v4/web_search", zhipu)]).search("peptide benchmark")
        #expect(z.count == 1 && z[0].url == "https://example.org/p" && z[0].snippet == "A benchmark.", "content farms are dropped as for every engine")
    }

    @Test func serperAndJina() async throws {
        let s = try await client(.serper, [("google.serper.dev/search", #"{"organic":[{"title":"T","link":"https://a.org/1","snippet":"S","date":"2025"}]}"#)]).search("q")
        #expect(s.first?.url == "https://a.org/1")
        let j = try await client(.jina, [("s.jina.ai", #"{"data":[{"title":"T","url":"https://b.org/1","description":"D"}]}"#)]).search("q")
        #expect(j.first?.snippet == "D")
    }

    @Test func anUnreachableBuiltInSearchSaysWhatWorksInstead() async throws {
        let c = WebSearchClient(config: WebSearchConfig(), secrets: Keys(keys: [:]), http: RoutedHTTP(sequenced: [("duckduckgo.com", [(503, "")])]))
        do { _ = try await c.search("q"); Issue.record("expected an error") } catch {
            #expect(error.localizedDescription.contains("Bocha or Zhipu"))
        }
    }
}
