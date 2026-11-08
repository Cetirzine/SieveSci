import Foundation
import Testing
@testable import SieveSciCore

/// Issues #6–#10 and their kin: a reopened task shows what the user saw live (no host notes as their
/// messages, their own words for a command), queued and inserted messages can be taken back,
/// compaction never runs under a turn, and a reviewer's reply reads as words.
@Suite struct ReplayAndQueue {
    let refresh = "<state_refresh>\ntool rounds this turn: 12\nobjective (the user's request; fixed): X\n</state_refresh>"

    @Test func hostNotesAreNotTheUsersWords() {
        for note in [refresh, "<brainstorm_wrap_up>wrap up</brainstorm_wrap_up>", "<recovery>go on</recovery>",
                     "<result_review_needed>x</result_review_needed>", "<supervisor_review kind=\"plan\">x</supervisor_review>",
                     "<delegation_hint>x</delegation_hint>", "<goal_round n=\"2\">x</goal_round>", "<hook_feedback>x</hook_feedback>"] {
            #expect(HostContext.isHostBlock(note), "\(note.prefix(30))")
            #expect(HostContext.ownWords(note) == nil)
        }
        // Notes appended to what the user typed are removed; their words stay.
        let typed = "Find binders for PD-L1\n\n<planning_note>several parts</planning_note>\n<file path=\"a.txt\">secret</file>"
        #expect(HostContext.userText(typed) == "Find binders for PD-L1")
        #expect(!HostContext.isHostBlock("<b>bold</b> is how I write"), "only the host's own tags")
    }

    @Test func aMessageInsertedMidTurnIsTheUsers() {
        let note = AgentSession.insertNote(["also check PD-1", "and CTLA-4"])
        #expect(HostContext.insertedText(note) == "also check PD-1\n\nand CTLA-4")
        let carrier = Message(role: .user, blocks: [.toolResult(ToolResult(toolUseId: "c1", content: "ok")), .text(refresh), .text(note)])
        #expect(HostContext.ownWords(carrier) == "also check PD-1\n\nand CTLA-4")
        let plain = Message(role: .user, blocks: [.toolResult(ToolResult(toolUseId: "c1", content: "ok")), .text(refresh)])
        #expect(HostContext.ownWords(plain) == nil)
    }

    @Test func aReopenedTaskShowsWhatTheUserTyped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let expanded = "Brainstorm: novel enzymes. Use the skill “brainstorm” (load it with the skill tool first) and start with `brainstorm` start so I can watch."
        let call = Message(role: .assistant, blocks: [.toolUse(ToolUse(id: "c1", name: "web_search", input: ["query": "enzymes"]))])
        for m in [Message.user(expanded), call,
                  Message(role: .user, blocks: [.toolResult(ToolResult(toolUseId: "c1", content: "hits\n[receipt r1]")), .text(refresh)]),
                  Message(role: .assistant, blocks: [.text("Done.")])] {
            SessionStore.shared.append(m, task: "t", agent: "main", dir: dir)
        }
        let log = try AuditLog(url: dir.appendingPathComponent("audit.jsonl"))
        _ = log.append(session: "t", kind: "user_turn", actor: "user", ["text": .string(expanded), "shown": "/brainstorm novel enzymes"])
        let h = ServeServer.timeline(taskDir: dir)
        let users = h.filter { $0.str("kind") == "user" }.compactMap { $0.str("text") }
        #expect(users == ["/brainstorm novel enzymes"], "\(users)")
        #expect(!h.contains { ($0.str("text") ?? "").contains("state_refresh") })
        // The export and the digest another conversation reads leave the host's notes out too.
        let md = SessionStore.markdown(SessionStore.load(dir: dir, agent: "main"))
        #expect(!md.contains("state_refresh") && md.contains("> Brainstorm: novel enzymes"))
    }

    @Test func aSlashCommandLeavesItsArgumentsAsTheObjective() {
        #expect(AgentSession.withoutCommand("/brainstorm 帮我写一个读书论文") == "帮我写一个读书论文")
        #expect(AgentSession.withoutCommand("/brainstorm") == "")
        #expect(AgentSession.withoutCommand("plain words") == "plain words")
    }

    @Test func aReviewersReplyReadsAsWords() {
        let verdict = #"{"verdict":"revise","issues":[{"severity":"medium","what":"The grid is underpowered","evidence":"r12"}],"notes":"n"}"#
        let r = Supervisor.readable(verdict)
        #expect(!r.contains("{") && r.contains("The grid is underpowered"))
        let position = #"{"position":"narrow","reason":"Only the first claim stands.","evidence":[],"question":null}"#
        #expect(Supervisor.readable(position).contains("Only the first claim stands."))
        #expect(Supervisor.readable("plain text") == "plain text")
    }

    @Test func queuedMessagesCanBeTakenBackOneByOne() throws {
        let (s, _) = try makeServices()
        let bench = Workbench(services: s)
        // Nothing queued: nothing to take back, and the queue is untouched.
        #expect(!bench.discardQueued("hello"))
        #expect(bench.queuedPrompts.isEmpty)
    }

    @Test func anInsertNotYetReadCanBeTakenBack() throws {
        let (s, _) = try makeServices()
        let bench = Workbench(services: s)
        bench.main.insert("also check PD-1")
        #expect(bench.main.retractInsert("also check PD-1"))
        #expect(!bench.main.retractInsert("also check PD-1"), "only once")
        #expect(bench.main.takeInserts().isEmpty)
    }

    @Test func aCutBeforeAnInsertLeavesAValidTranscript() throws {
        let (s, _) = try makeServices()
        let bench = Workbench(services: s)
        bench.main.restore([Message.user("go"), Message(role: .assistant, blocks: [.toolUse(ToolUse(id: "c1", name: "bash", input: ["command": "ls"]))]),
                            Message(role: .user, blocks: [.toolResult(ToolResult(toolUseId: "c1", content: "a")), .text(AgentSession.insertNote(["stop"]))])])
        bench.main.truncate(to: 2)
        let results = bench.main.transcript.flatMap(\.blocks).filter { if case .toolResult = $0 { return true }; return false }
        #expect(results.count == 1, "the call keeps a result")
    }
}
