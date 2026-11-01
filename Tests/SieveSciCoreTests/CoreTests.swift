// XCTest ships with Xcode, not with the Command Line Tools; the swift-testing suites run on either.
#if canImport(XCTest)
import XCTest
@testable import SieveSciCore

final class JSONAndCacheTests: XCTestCase {
    func testCanonicalJSONSortsKeys() throws {
        let a = try JSONCodec.parse(#"{"b":1,"a":{"d":2,"c":3}}"#)
        let b = try JSONCodec.parse(#"{"a":{"c":3,"d":2},"b":1}"#)
        XCTAssertEqual(a.canonical, b.canonical)
        XCTAssertTrue(a.canonical.hasPrefix(#"{"a""#))
    }

    func testCachePlanUsesAtMostThreeMessageBreakpoints() {
        let msg: [JSON] = [["type": "text", "text": "x"]]
        let messages = Array(repeating: msg, count: 80)
        let plan = AnthropicCachePlan.make(messages: messages, prefixTTL: "1h")
        XCTAssertLessThanOrEqual(plan.messageBreakpoints.count, 3)
        XCTAssertTrue(plan.messageBreakpoints.contains { $0.0 == 79 && $0.1 == 0 }, "the rolling breakpoint is on the last block")
    }

    func testCachePlanCollapsesToolRuns() {
        let uses: [JSON] = (0..<30).map { _ in ["type": "tool_use"] }
        let plan = AnthropicCachePlan.make(messages: [[["type": "text"]], uses], prefixTTL: "5m")
        // 30 consecutive tool_use blocks are one position, so no intermediate breakpoint is needed.
        XCTAssertEqual(plan.messageBreakpoints.count, 1)
    }
}

final class DiffTests: XCTestCase {
    func testAddedAndRemovedLines() {
        let d = FileDiff.make(path: "a.py", old: "a\nb\nc\n", new: "a\nB\nc\nd\n")
        XCTAssertEqual(d.added, 2)
        XCTAssertEqual(d.removed, 1)
        XCTAssertTrue(d.unified.contains("-b"))
        XCTAssertTrue(d.unified.contains("+B"))
    }

    func testNewFile() {
        let d = FileDiff.make(path: "n.txt", old: nil, new: "x\ny")
        XCTAssertTrue(d.isNewFile)
        XCTAssertEqual(d.added, 2)
        XCTAssertEqual(d.removed, 0)
    }
}

final class ProvenanceTests: XCTestCase {
    func testAuditChainDetectsTampering() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        let log = try AuditLog(url: url)
        for i in 0..<5 { _ = log.append(session: "s", kind: "k", actor: "host", ["i": .int(i)]) }
        XCTAssertNil(try AuditLog.verify(url), "intact chain verifies")
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: #""i":2"#, with: #""i":7"#)
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNotNil(try AuditLog.verify(url), "edited entry breaks the chain")
    }
}

final class IntegrityTests: XCTestCase {
    func testHackDetectorFlagsSeedFishingAndMaskedFailures() {
        let s = HackDetector.scan(code: "for seed in range(100):\n    run(seed)\nmake || true\n")
        XCTAssertTrue(s.contains { $0.detail.contains("seed") })
        XCTAssertTrue(s.contains { $0.detail.contains("|| true") })
    }

    func testMultipleTestsWithoutCorrection() {
        let code = "from scipy.stats import ttest_ind\nttest_ind(a,b)\nttest_ind(c,d)\nttest_ind(e,f)\n"
        XCTAssertTrue(HackDetector.scan(code: code).contains { $0.detail.contains("multiple-comparison") })
        XCTAssertFalse(HackDetector.scan(code: code + "multipletests(ps)").contains { $0.detail.contains("multiple-comparison") })
    }

    func testGroundingFlagsUnknownCitationAndUnsupportedNumber() {
        let r = Grounding.check(text: "The effect was large (p = 0.0003) [@nobody2020x].", library: nil, evidenceCorpus: "")
        XCTAssertFalse(r.isClean)
        XCTAssertTrue(r.unresolvedCitations.contains("nobody2020x"))
        XCTAssertFalse(r.unsupportedNumbers.isEmpty)
    }

    func testGroundingIgnoresCodeSpans() {
        let r = Grounding.check(text: "Use `[@key]` syntax to cite.", library: nil, evidenceCorpus: "")
        XCTAssertTrue(r.unresolvedCitations.isEmpty)
    }

    func testPaperRefNormalization() {
        XCTAssertEqual(PaperRef.normalize("https://doi.org/10.1038/s41586-020-2649-2").1, "10.1038/s41586-020-2649-2")
        XCTAssertEqual(PaperRef.normalize("PMID: 12345678").0, .pmid)
        XCTAssertEqual(PaperRef.normalize("arXiv:2401.01234v2").0, .arxiv)
    }
}

final class RefusalTests: XCTestCase {
    func testClassification() {
        XCTAssertEqual(Refusals.classify(reply: "{\"verdict\":\"pass\"}", stop: nil, hasVerdict: true)?.0, nil)
        XCTAssertEqual(Refusals.classify(reply: "I can't help with that request.", stop: nil, hasVerdict: false)?.0, .policy)
        XCTAssertEqual(Refusals.classify(reply: "I cannot run code, but…", stop: nil, hasVerdict: false)?.0, .capability)
        XCTAssertEqual(Refusals.classify(reply: "", stop: nil, hasVerdict: false)?.0, .unusable)
        XCTAssertEqual(Refusals.classify(reply: "x", stop: .refusal, hasVerdict: false)?.0, .policy)
        XCTAssertEqual(Refusals.classify(error: ProviderError.http(status: 429, body: "rate limited")).0, .transient)
        XCTAssertEqual(Refusals.classify(error: ProviderError.http(status: 400, body: "flagged by safety system")).0, .policy)
    }

    /// A reviewer that declines must not produce a pass: the checkpoint result says NOT reviewed.
    func testDeclinedReviewIsNeverAPass() async throws {
        let checker = ScriptedProvider(id: "checker", replies: ["I can't help with that.", "I can't help with that."])
        let (s, _) = try makeServices(checker: checker)
        let step = PlanStep(id: "s1", title: "Fit model", detail: "", status: "done", checkpoint: true, criteria: "R2 > 0.5", evidence: [], note: "")
        let r = await s.supervisor.reviewCheckpoint(step)
        XCTAssertTrue(r.contains("NOT reviewed"), r)
        XCTAssertEqual(s.refusals.unreviewed.count, 1)
    }

    func testRetryUsesAlternateReviewer() async throws {
        let checker = ScriptedProvider(id: "checker", replies: ["I can't help with that."])
        let backup = ScriptedProvider(id: "backup", replies: [#"{"verdict":"pass","issues":[],"required_actions":[],"notes":"ok"}"#])
        let (s, _) = try makeServices(checker: checker)
        s.models.alternates = [(backup, "m")]
        let step = PlanStep(id: "s1", title: "Fit model", detail: "", status: "done", checkpoint: true, criteria: "R2 > 0.5", evidence: [], note: "")
        let r = await s.supervisor.reviewCheckpoint(step)
        XCTAssertTrue(r.contains("passed"), r)
        XCTAssertEqual(backup.requests.count, 1)
    }
}

final class DeliberationTests: XCTestCase {
    func testRebuttalNeedsNewEvidenceAndIsBounded() async throws {
        let reviewer = ScriptedProvider(id: "checker", replies: [
            #"{"position":"maintain","reason":"The receipt shows n=3 only; underpowered.","evidence":[],"question":null}"#,
            #"{"position":"maintain","reason":"Still underpowered with n=3 per group.","evidence":[],"question":null}"#,
        ])
        let (s, ws) = try makeServices(checker: reviewer)
        try "data".write(to: ws.appendingPathComponent("power.csv"), atomically: true, encoding: .utf8)
        try "data".write(to: ws.appendingPathComponent("power2.csv"), atomically: true, encoding: .utf8)
        let agent = s.makeSubagent(role: .checker)
        let d = s.deliberation
        let tid = d.open(kind: "integrity", reviewer: agent, issues: ["Sample size too small"])

        // No evidence → refused without calling the reviewer.
        let r0 = await d.respond(thread: tid, issue: 1, position: .disagree, argument: "It is fine.", evidence: [], from: "main")
        XCTAssertTrue(r0.hasPrefix("Refused"))
        XCTAssertEqual(reviewer.requests.count, 0)

        let r1 = await d.respond(thread: tid, issue: 1, position: .disagree, argument: "Power analysis shows 0.9 power at this effect size.",
                                 evidence: ["power.csv"], from: "main")
        XCTAssertTrue(r1.contains("maintains"), r1)

        // Re-using the same evidence is refused.
        let r2 = await d.respond(thread: tid, issue: 1, position: .disagree, argument: "Different words entirely about variance estimates.",
                                 evidence: ["power.csv"], from: "main")
        XCTAssertTrue(r2.hasPrefix("Refused"))

        let r3 = await d.respond(thread: tid, issue: 1, position: .disagree, argument: "A second simulation with bootstrap resampling confirms it.",
                                 evidence: ["power2.csv"], from: "main")
        XCTAssertTrue(r3.contains("CONTESTED"), r3)
        XCTAssertEqual(d.contested.count, 1)

        // Closed: no further argument.
        let r4 = await d.respond(thread: tid, issue: 1, position: .clarify, argument: "One more thing.", evidence: [], from: "main")
        XCTAssertTrue(r4.contains("already closed"))
        XCTAssertEqual(reviewer.requests.count, 2)
    }

    func testConcessionWithdrawsIssue() async throws {
        let reviewer = ScriptedProvider(id: "checker", replies: [#"{"position":"concede","reason":"The control resolves it.","evidence":[]}"#])
        let (s, ws) = try makeServices(checker: reviewer)
        try "x".write(to: ws.appendingPathComponent("control.csv"), atomically: true, encoding: .utf8)
        let tid = s.deliberation.open(kind: "integrity", reviewer: s.makeSubagent(role: .checker), issues: ["Missing control"])
        let r = await s.deliberation.respond(thread: tid, issue: 1, position: .disagree, argument: "The control is in control.csv.",
                                             evidence: ["control.csv"], from: "main")
        XCTAssertTrue(r.contains("conceded"))
        XCTAssertTrue(s.deliberation.contested.isEmpty)
    }
}

final class JobMonitorTests: XCTestCase {
    func testStreamingJobNotifiesOnExitAndMatch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString)")
        let jobs = JobMonitor(dir: dir)
        let lines = LockedBox<[String]>([])
        jobs.emit = { ev in if case .jobOutput(_, let l) = ev { lines.mutate { $0 += l } } }
        let id = try jobs.start(command: "echo one; echo READY; echo two", cwd: dir, agentId: "main", sandbox: .off,
                                writableRoots: [dir], protected: [], notifyOn: "READY")
        for _ in 0..<50 {
            if jobs.runningCount == 0 && jobs.hasPendingAny { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let notes = jobs.drain(for: "main")
        XCTAssertTrue(notes.contains { $0.kind == .exited && $0.job == id })
        XCTAssertTrue(notes.contains { $0.text.contains("READY") })
        XCTAssertEqual(lines.value, ["one", "READY", "two"])
        XCTAssertTrue(jobs.output(id, onlyNew: true)?.contains("two") ?? false)
        XCTAssertTrue(jobs.output(id, onlyNew: true)?.contains("(no new output)") ?? false, "a second read shows only new lines")
    }

    func testFailingJobIsReportedAsFailed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString)")
        let jobs = JobMonitor(dir: dir)
        _ = try jobs.start(command: "echo 'Traceback (most recent call last):'; exit 3", cwd: dir, agentId: "main", sandbox: .off,
                           writableRoots: [dir], protected: [])
        for _ in 0..<50 {
            if jobs.runningCount == 0 && jobs.hasPendingAny { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let notes = jobs.drain(for: "main")
        XCTAssertTrue(notes.contains { $0.kind == .failed && $0.text.contains("exit 3") })
    }

    func testSleepPollingIsRefused() {
        XCTAssertTrue(BashTool.isSleepPoll("sleep 60; cat log.txt"))
        XCTAssertTrue(BashTool.isSleepPoll("while true; do tail -1 log; sleep 5; done"))
        XCTAssertFalse(BashTool.isSleepPoll("sleep 2 && echo ok"))
        XCTAssertFalse(BashTool.isSleepPoll("python fit.py"))
    }
}

final class SchedulerAndL10nTests: XCTestCase {
    func testScheduleParsing() {
        XCTAssertEqual(Scheduler.parse("daily 08:30 summarize new papers")?.0, "daily 08:30")
        XCTAssertEqual(Scheduler.parse("weekly mon 09:00 literature watch")?.1, "literature watch")
        XCTAssertNil(Scheduler.parse("sometimes do it"))
        XCTAssertEqual(Scheduler.launchdTiming("daily 08:30")?.calendar?["Hour"], 8)
        XCTAssertEqual(Scheduler.launchdTiming("every 6h")?.interval, 21600)
        XCTAssertNil(Scheduler.launchdTiming("every 5m"), "intervals under 15 minutes are refused")
    }

    func testEnglishFallback() {
        let saved = L10n.language
        defer { L10n.language = saved }
        L10n.language = .en
        XCTAssertEqual(L("Settings that do not exist"), "Settings that do not exist")
        XCTAssertEqual(L10n.f("%d papers", 3), "3 papers")
    }

    func testAllLanguagesLoadAndTranslate() {
        let saved = L10n.language
        defer { L10n.language = saved }
        for lang in L10n.Language.allCases where lang != .system && lang != .en {
            L10n.language = lang
            XCTAssertNotEqual(L("Copy"), "Copy", "\(lang.rawValue) bundle should translate 'Copy'")
            XCTAssertTrue(L10n.f("%d papers", 7).contains("7"), lang.rawValue)
        }
    }
}
#endif
