import Foundation
import Testing
@testable import SieveSciCore

/// A reopened task shows what the chat showed live: reasoning with its duration, tool rows with the
/// diff a file edit made, and each worker's card with its own steps after the call that delegated it.
@Suite struct ReopenedTimeline {
    @Test func reasoningDiffsAndWorkerCardsComeBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let reply = Message(role: .assistant, blocks: [
            .thinking(ThinkingBlock(text: "Plan the edit, then hand S2 to a worker.")),
            .text("Editing, then delegating."),
            .toolUse(ToolUse(id: "c1", name: "edit_file", input: ["path": "a.py", "old_string": "x = 1\n", "new_string": "x = 2\ny = 3\n"])),
            .toolUse(ToolUse(id: "c2", name: "task", input: ["description": "Build S2", "prompt": "do it"])),
        ])
        for m in [Message.user("Start the work"), reply,
                  Message(role: .user, blocks: [.toolResult(ToolResult(toolUseId: "c1", content: "ok\n[receipt r1]")),
                                                .toolResult(ToolResult(toolUseId: "c2", content: "done\n[receipt r2]"))])] {
            SessionStore.shared.append(m, task: "t", agent: "main", dir: dir)
        }
        let log = try AuditLog(url: dir.appendingPathComponent("audit.jsonl"))
        _ = log.append(session: "t", kind: "user_turn", actor: "user", ["text": "Start the work"])
        _ = log.append(session: "t", kind: "model_call", actor: "main", ["agent": "main", "message": .string(reply.id), "thinking_seconds": 4.2])
        _ = log.append(session: "t", kind: "tool_call", actor: "main", ["agent": "main", "tool": "edit_file", "receipt": "r1", "input": [:]])
        _ = log.append(session: "t", kind: "agent_start", actor: "worker", ["agent": "worker-abc123", "parent": "main", "purpose": "Build S2"])
        _ = log.append(session: "t", kind: "tool_call", actor: "worker", ["agent": "worker-abc123", "tool": "bash", "receipt": "r9",
                                                                         "input": ["command": "python build.py"], "output_excerpt": "built", "success": true])
        _ = log.append(session: "t", kind: "tool_call", actor: "main", ["agent": "main", "tool": "task", "receipt": "r2", "input": ["description": "Build S2"]])

        let h = ServeServer.timeline(taskDir: dir)
        let kinds = h.compactMap { $0.str("kind") }
        #expect(kinds == ["user", "thinking", "assistant", "tool", "tool", "agent"], "\(kinds)")
        #expect(h[1]["seconds"]?.doubleValue == 4.2)
        #expect(h[3]["diff"]?["added"]?.intValue == 2 && h[3]["diff"]?["removed"]?.intValue == 1)
        #expect(h[4].str("receipt") == "r2" && h[4].str("output") == "done")
        let card = h[5]
        #expect(card.str("id") == "worker-abc123" && card.str("role") == "worker" && card.str("purpose") == "Build S2")
        #expect(card["steps"]?.arrayValue?.first?.str("name") == "bash" && card["steps"]?.arrayValue?.first?.str("receipt") == "r9")
    }
}
