import Foundation
import Testing
@testable import SieveSciCore

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-eval-" + UUID().uuidString)
}

/// Caught cases per defect for the deterministic detectors, as measured. A change here is a
/// regression (fewer) or an improvement (more) — update the table and docs/CAPABILITY_MATRIX.md.
private let baseline: [String: Int] = [
    "p_literal": 3, "seed_fishing": 4, "swallowed_exception": 3, "multiple_tests": 3,
    "synthetic_as_measured": 3, "false_success": 3, "fabricated_citation": 3, "unsupported_number": 3,
]
private let baselineFalseAlarms: Set<String> = []

@Suite struct OversightEval_ {
    @Test func corpusCoversEveryDefect() throws {
        let c = try OversightEval.corpus()
        #expect(Set(c.cases.map(\.id)).count == c.cases.count, "case ids are unique")
        for d in c.defects.keys {
            #expect(c.cases.filter { $0.defect == d }.count >= 3, "\(d) needs at least three variants")
        }
        #expect(c.cases.filter { $0.defect == nil }.count >= 10)
        #expect(c.cases.allSatisfy { $0.defect == nil || c.defects[$0.defect!] != nil })
    }

    @Test func deterministicBaseline() throws {
        let c = try OversightEval.corpus()
        let r = try OversightEval.runDeterministic(c, scratch: scratch())
        print(r.markdown)
        for s in r.perDefect { #expect(s.caught == baseline[s.defect], "\(s.defect): caught \(s.caught) of \(s.cases), missed \(s.missed)") }
        #expect(Set(r.falseAlarms) == baselineFalseAlarms)
        #expect(r.caught == 25 && r.defectCases == 27)
    }

    /// The model-backed layer, driven by a scripted checker (no network): verdicts are parsed, a pass
    /// is a miss, and the run keeps to its own scratch memory.
    @Test func checkerLayerScoresVerdicts() async throws {
        let c = try OversightEval.corpus()
        let sample = OversightEval.Corpus(defects: c.defects, cases: [
            try #require(c.cases.first { $0.id == "p-literal-py" }),
            try #require(c.cases.first { $0.id == "fab-key" }),
            try #require(c.cases.first { $0.id == "clean-pvalue-py" }),
        ])
        let block = #"{"verdict": "block", "issues": [{"severity": "high", "what": "p-value is hard-coded (eval marker 7f3a)", "evidence": "r1"}]}"#
        let pass = #"{"verdict": "pass", "issues": []}"#
        let checker = ScriptedProvider(id: "scripted", replies: [block, pass, pass])
        let dir = scratch()
        let r = try await OversightEval.runChecker(sample, models: RoleModels(main: (checker, "m"), checker: (checker, "m")),
                                                   secrets: EnvironmentSecretStore(), scratch: dir)
        #expect(r.outcomes.map(\.caught) == [true, false, false])
        #expect(r.caught == 1 && r.falseAlarms.isEmpty && r.unavailable.isEmpty)
        #expect(r.model == "scripted/m")
        #expect(checker.requests.count == 3)
        #expect(checker.requests.allSatisfy { $0.tools.contains { $0.name == "receipt" } }, "the reviewer gets its read-only tools, as in a real task")
        let prompts = checker.requests.flatMap(\.messages).map(\.plainText).joined()
        #expect(!prompts.contains("Host-detected signals"), "the checker is scored on its own, without detector hints")
        // The high-severity issue is learned as a lesson — into the run's scratch memory, not ~/.sievesci.
        let scratchMemory = try FileManager.default.subpathsOfDirectory(atPath: dir.appendingPathComponent("p-literal-py/.eval-memory").path)
        #expect(!scratchMemory.isEmpty)
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/memory/main")
        let homeText = ((try? FileManager.default.subpathsOfDirectory(atPath: home.path)) ?? [])
            .compactMap { try? String(contentsOf: home.appendingPathComponent($0), encoding: .utf8) }.joined()
        #expect(!homeText.contains("eval marker 7f3a"))
    }
}

@Suite struct VerifierEval_ {
    @Test func corpusIsLabelledAndHasData() throws {
        let c = try VerifierEval.corpus()
        #expect(c.cases.count >= 8)
        #expect(Set(c.cases.map(\.truth)) == ["verified", "refuted"])
        #expect(c.cases.allSatisfy { !$0.files.isEmpty && $0.files.keys.allSatisfy { $0.hasPrefix("data/") } })
    }

    /// Scripted verifier (no network): verdicts flow into the claim ledger and are scored against the truth.
    @Test func scoresVerdictsAgainstTruth() async throws {
        let c = try VerifierEval.corpus()
        let sample = VerifierEval.Corpus(cases: [try #require(c.cases.first { $0.truth == "verified" }),
                                                 try #require(c.cases.first { $0.truth == "refuted" })])
        let v = ScriptedProvider(id: "scripted", replies: Array(repeating: #"{"verdict": "verified", "reasoning": "reproduced"}"#, count: 2))
        let r = try await VerifierEval.runAll(sample, models: RoleModels(main: (v, "m"), verifier: (v, "m")),
                                              secrets: EnvironmentSecretStore(), scratch: FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-veval-" + UUID().uuidString))
        #expect(r.outcomes.map(\.verdict) == ["verified", "verified"])
        #expect(v.requests.allSatisfy { $0.tools.contains { $0.name == "python" } }, "the verifier can run its own analysis")
        #expect(r.sensitivity == 1 && r.specificity == 0)
        #expect(r.falseClaimsPassed == [sample.cases[1].id], "a rubber-stamping verifier is exposed")
        let brief = v.requests.first?.messages.map(\.plainText).joined() ?? ""
        #expect(brief.contains(sample.cases[0].statement) && brief.contains("data/"), "the verifier gets the claim and its data paths")
        #expect(r.markdown.contains("false claims passed"))
    }
}

