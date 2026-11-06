import Foundation

/// Makes a saved conversation sendable again after the app stopped between a model's tool calls and
/// their results (crash, force quit, power loss). The transcript then ends with — or contains — an
/// assistant message whose tool calls have no results, and every provider refuses the whole
/// conversation from then on (OpenAI-style: "An assistant message with 'tool_calls' must be followed
/// by tool messages…"), however often the user presses continue.
///
/// Each unanswered call gets a result saying it was not recorded; results that answer no call are
/// dropped. A well-formed transcript comes back unchanged (same messages, same bytes), so the
/// provider's prompt cache is kept.
public enum TranscriptRepair {
    static let notRecorded = "Not recorded: SieveSci stopped (a crash or a forced quit) before this call's result was saved. "
        + "It may or may not have run. Check its effect (a file, the plan, the review thread) before relying on it, and call it again if it is still needed."

    public struct Outcome: Sendable {
        public var messages: [Message]
        /// Calls that got a "not recorded" result.
        public var closed: [String] = []
        /// Results removed because no call in the preceding assistant message matches them.
        public var dropped: [String] = []
        /// The message appended at the end when the transcript ended with unanswered calls; persist it
        /// so the saved transcript matches what is sent.
        public var appended: Message?
        public var changed: Bool { !closed.isEmpty || !dropped.isEmpty }
    }

    static func placeholder(_ u: ToolUse) -> ContentBlock {
        .toolResult(ToolResult(toolUseId: u.id, content: notRecorded, isError: true))
    }

    public static func repair(_ messages: [Message]) -> Outcome {
        var out: [Message] = []
        var closed: [String] = [], dropped: [String] = []
        /// Calls of the last assistant message still waiting for their results.
        var open: [ToolUse] = []

        for m in messages {
            switch m.role {
            case .assistant:
                if !open.isEmpty {
                    // Two assistant messages in a row: the first one's calls were never answered.
                    out.append(Message(role: .user, blocks: open.map(placeholder)))
                    closed += open.map(\.id)
                }
                out.append(m)
                open = m.toolUses
            default:
                let results = m.blocks.compactMap(\.toolResult)
                let wanted = Set(open.map(\.id))
                var seen = Set<String>()
                let stray = results.filter { !wanted.contains($0.toolUseId) || !seen.insert($0.toolUseId).inserted }.map(\.toolUseId)
                let missing = open.filter { id in !results.contains { $0.toolUseId == id.id } }
                if stray.isEmpty && missing.isEmpty {
                    out.append(m)
                } else {
                    // Results first, in call order (where providers expect them), then the rest as it was.
                    var byId: [String: ContentBlock] = [:]
                    for b in m.blocks { if let r = b.toolResult, wanted.contains(r.toolUseId), byId[r.toolUseId] == nil { byId[r.toolUseId] = b } }
                    let answers = open.map { byId[$0.id] ?? placeholder($0) }
                    let rest = m.blocks.filter { $0.toolResult == nil }
                    closed += missing.map(\.id)
                    dropped += stray
                    let blocks = answers + rest
                    if !blocks.isEmpty { out.append(Message(id: m.id, role: m.role, blocks: blocks)) }
                }
                open = []
            }
        }
        var appended: Message?
        if !open.isEmpty {
            let patch = Message(role: .user, blocks: open.map(placeholder))
            out.append(patch)
            closed += open.map(\.id)
            appended = patch
        }
        return Outcome(messages: out, closed: closed, dropped: dropped, appended: appended)
    }
}
