import Foundation
import Testing
@testable import SieveSciCore

/// The user profile and notes fill up: what the user said is evidence for their profile (quoted, and
/// checked against their messages), and each store is reviewed for what it is for.
@Suite struct UserMemory {
    func services(review: String) throws -> SessionServices {
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-mem-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let s = try SessionServices(taskId: "t1", workspace: ws, models: RoleModels(main: (ScriptedProvider(replies: [review, review]), "m")),
                                    secrets: EnvironmentSecretStore())
        s.memoryRoot = ws.appendingPathComponent("memory")
        s.log("user_turn", actor: "user", ["agent": "main", "text": "请用中文回复，这个项目不要求新颖性，好用就行"])
        return s
    }

    func proposal(_ store: String, _ text: String, from: [String]) -> EvolutionProposal {
        EvolutionProposal(id: "E1", role: .main, kind: .memory, target: store, operation: "add", content: text, match: nil,
                          provenance: from, task: "t1", status: .pending, reason: "", createdAt: Date(), previous: nil)
    }

    @Test func theUsersOwnWordsBackTheirProfile() async throws {
        let s = try services(review: #"{"approve": true, "reason": "states the user's preference faithfully"}"#)
        let r = await s.governor.submit(proposal("USER", "Replies in Chinese; usefulness over novelty in this project.",
                                                 from: ["user: 请用中文回复", "user:不要求新颖性，好用就行"]), services: s)
        #expect(r.status == .accepted, "\(r.reason)")
        #expect(s.memory(for: .main).entries(.user).first?.contains("Chinese") == true)
    }

    @Test func wordsTheUserNeverWroteDoNotCount() async throws {
        let s = try services(review: #"{"approve": true, "reason": "ok"}"#)
        let r = await s.governor.submit(proposal("USER", "Prefers English.", from: ["user: please answer in English"]), services: s)
        #expect(r.status == .rejected && r.reason.contains("not in the user's messages"), "\(r.reason)")
        #expect(s.memory(for: .main).entries(.user).isEmpty)
    }

    @Test func eachStoreIsReviewedForWhatItIsFor() {
        func rubric(_ store: String) -> String { EvolutionGovernor.rubric(proposal(store, "x", from: [])) }
        #expect(rubric("USER").contains("what the user said about themselves"))
        #expect(rubric("MEMORY").contains("installed tools"))
        #expect(rubric("LESSONS").contains("do science better"))
        #expect(EvolutionGovernor.quotesUser("user: 好用就行", ["这个项目不要求新颖性，好用就行"]))
        #expect(!EvolutionGovernor.quotesUser("user: 行", ["好用就行"]), "too short to identify a statement")
    }
}
