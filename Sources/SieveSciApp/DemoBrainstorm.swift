import Foundation
import SieveSciCore

/// `SIEVESCI_UI_BRAINSTORM=1`: a brainstorm in its novelty stage; `SIEVESCI_UI_ASK=1`: the card that
/// offers its ideas to the user. Debug builds only, like the rest of the demo content.
extension AppModel {
    func loadBrainstormDemo(ask: Bool) {
        let now = Date().timeIntervalSinceReferenceDate
        streams = ["main": [
            TranscriptItem(id: "bu", kind: .user("Our electrolyte additive stopped helping above 45 °C. Give me some new angles.", attachments: [])),
            TranscriptItem(id: "bt", kind: .thinking("The pool is thin on interface effects.\nAnalogy from load balancing: a second additive that takes over at high temperature. Checking whether dual-additive studies already exist.",
                                                     started: Date().addingTimeInterval(-20), ended: nil)),
        ]]
        cards = [:]
        contested = []
        demoAsk = nil
        running = !ask
        func idea(_ id: String, _ st: String, _ op: String, _ status: String, novelty: String? = nil, rank: Int? = nil, merged: String? = nil) -> String {
            var extra = ""
            if let merged { extra += "\"mergedInto\":\"\(merged)\"," }
            if let novelty { extra += "\"novelty\":\"\(novelty)\"," }
            if let rank { extra += "\"rank\":\(rank)," }
            return "{\"id\":\"\(id)\",\"statement\":\"\(st)\",\"mechanism\":\"\",\"test\":\"\",\"falsifier\":\"\",\"op\":\"\(op)\",\"seeds\":[],\"evidence\":[],"
                + "\"status\":\"\(status)\",\(extra)\"noveltyReceipts\":[],\"closestPrior\":[],\"origin\":\"brainstorm:Bdemo\",\"createdAt\":\(now - 30)}"
        }
        let list = [
            idea("I1", "A second additive that only decomposes above 45 °C takes over film formation", "analogy", "checked", novelty: "not_found_in_search", rank: 1),
            idea("I2", "The interphase cracks from thermal mismatch, not chemistry", "invert", "checked", novelty: "incremental", rank: 2),
            idea("I3", "Additive is consumed faster at high temperature; dose it from a reservoir", "seed", "raw", rank: 3),
            idea("I4", "Two additives that switch roles with temperature", "analogy", "merged", merged: "I1"),
            idea("I5", "Salt concentration shift changes which species reaches the surface first", "facet", "raw", rank: 4),
            idea("I6", "Coat the cathode instead of relying on the electrolyte", "free", "discarded", novelty: "known"),
            idea("I7", "Trace water catalyses additive breakdown above 45 °C", "invert", "raw"),
        ]
        ideas = AppModel.decodeDemo([Idea].self, "[" + list.joined(separator: ",") + "]") ?? []
        brainstorm = AppModel.decodeDemo(BrainstormState.self, """
        {"id":"Bdemo","topic":"Why the additive fails above 45 °C","reason":"The current hypothesis was refuted at 50 °C","trigger":"auto",
         "stage":"novelty","stageNote":"Searching prior work for I1 (dual-additive, temperature-gated film formation)",
         "stagesDone":["ground","diverge","dedupe","rank"],"startedAt":\(now - 95),"wrapUpRequested":false,"stopped":false}
        """)
        if ask {
            // Ended: the brainstorm becomes a row of the conversation, and the reply continues below it.
            var ended = brainstorm
            ended?.endedAt = Date()
            ended?.summary = "Seven ideas, five distinct; I1 found no prior work in 6 searches."
            ended?.stage = "report"
            ended?.stagesDone = BrainstormState.stages
            showBrainstorm(ended)
            streams["main"]?.append(TranscriptItem(id: "ba", kind: .assistant("I1 is the strongest lead: no prior work turned up in six searches, and your existing cells can test it. Two quick questions before I plan it.")))
            pendingAsk = AskRequest(id: "ask-demo", agentId: "main", questions: [
                AskQuestion(id: "dir", header: "Direction", question: "Which ideas should I pursue first?", kind: .multi, reason: .direction, options: [
                    AskOption(label: "Temperature-gated second additive", description: "No prior work found in 6 searches; testable with existing cells", recommended: true, evidence: ["@lee2024additive", "r31"], idea: "I1"),
                    AskOption(label: "Thermal-mismatch cracking", description: "Incremental on known interphase studies", evidence: ["@chen2023sei"], idea: "I2"),
                    AskOption(label: "Additive reservoir dosing", description: "Not checked yet", idea: "I3"),
                ]),
                AskQuestion(id: "cells", header: "Cells", question: "Which cells can you test in the next two weeks?", kind: .text, reason: .missingValue,
                            placeholder: "e.g. 12 coin cells, NMC811/graphite"),
            ])
        }
    }

    static func decodeDemo<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
