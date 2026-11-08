import Foundation

/// What the chat shows for a saved task. The transcript holds what the model saw; a CLI agent's tool
/// calls (and those of a turn still running) are only in the audit log, so those turns would come back
/// as a question and a reply with nothing between. This fills them in, for display only.
public enum DisplayTimeline {
    static func isUserTurn(_ m: Message) -> Bool {
        HostContext.ownWords(m) != nil   // an inserted message counts: it is logged as a user turn too
    }

    /// The only audit entries `merge` uses; the rest of a long log is never decoded.
    public static func auditEntries(_ url: URL) -> [AuditLog.Entry] {
        (try? AuditLog.read(url, kinds: ["user_turn", "tool_call"])) ?? []
    }

    public static func merge(_ msgs: [Message], audit: [AuditLog.Entry]) -> [Message] {
        // Tool calls of the main agent, grouped by the user turn they followed.
        var turns: [[AuditLog.Entry]] = []
        for e in audit {
            // Host-started turns were logged as the user's before 0.3.3: they open no turn here either.
            if e.kind == "user_turn" && e.actor == "user" && !HostContext.isHostBlock(e.data.str("text") ?? "") { turns.append([]) }
            else if e.kind == "tool_call" && e.actor == "main" && !turns.isEmpty { turns[turns.count - 1].append(e) }
        }
        var out: [Message] = []
        var k = -1
        var i = 0
        while i < msgs.count {
            let m = msgs[i]
            out.append(m)
            i += 1
            guard isUserTurn(m) else { continue }
            k += 1
            // This turn's messages up to the next user turn: does the transcript already show its tools?
            var j = i
            var shown = false
            while j < msgs.count && !isUserTurn(msgs[j]) {
                if msgs[j].blocks.contains(where: { if case .toolUse = $0 { return true }; return false }) { shown = true }
                j += 1
            }
            guard !shown, k < turns.count, !turns[k].isEmpty else { continue }
            var uses: [ContentBlock] = [], results: [ContentBlock] = []
            for e in turns[k] {
                let id = e.data.str("receipt") ?? "a\(e.seq)"
                uses.append(.toolUse(ToolUse(id: id, name: e.data.str("tool") ?? "tool", input: e.data["input"] ?? [:])))
                results.append(.toolResult(ToolResult(toolUseId: id, content: (e.data.str("output_excerpt") ?? "") + "\n[receipt \(id)]",
                                                      isError: e.data["success"]?.boolValue == false)))
            }
            out.append(Message(role: .assistant, blocks: uses))
            out.append(Message(role: .user, blocks: results))
        }
        return out
    }
}
