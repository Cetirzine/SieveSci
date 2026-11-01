import Foundation

/// The task's trace, read from the audit log: it survives restarts and covers CLI agents, whose
/// tool calls never appear as tool blocks in the saved transcript.
public struct TraceEvent: Sendable, Identifiable, Equatable {
    public enum Category: String, Sendable { case literature, agents, work }
    public var id: Int                  // audit sequence number
    public var at: Date
    public var actor: String            // "main", "checker-1a2b3c", "host", "user", "git"
    public var kind: String             // tool name or audit kind
    public var text: String
    public var isError: Bool
    public var category: Category
}

public enum Trace {
    static let literature: Set<String> = ["web_search", "literature_search", "paper_fetch", "library_search", "paper_graph", "verify_citation", "bio_db"]
    /// Reading around is not worth a trace line; work, sources, plans and checks are.
    static let quiet: Set<String> = ["read_file", "glob", "grep", "repo_map", "session_search", "tool_result", "job_output", "memory"]

    public static func events(_ entries: [AuditLog.Entry]) -> [TraceEvent] {
        entries.compactMap { e -> TraceEvent? in
            let d = e.data
            let agent = d.str("agent") ?? e.actor
            func ev(_ kind: String, _ text: String, error: Bool = false, _ cat: TraceEvent.Category) -> TraceEvent {
                TraceEvent(id: e.seq, at: e.time, actor: agent, kind: kind, text: text, isError: error, category: cat)
            }
            switch e.kind {
            case "tool_call":
                let tool = d.str("tool") ?? "tool"
                guard !quiet.contains(tool) else { return nil }
                let input = d["input"]
                let what = input?.str("command") ?? input?.str("query") ?? input?.str("path") ?? input?.str("claim") ?? input?.str("ref")
                    ?? input?.str("code")?.split(separator: "\n").first.map(String.init) ?? input?.str("purpose") ?? input?.str("action") ?? ""
                let receipt = d.str("receipt").map { " [\($0)]" } ?? ""
                let failed = d["success"]?.boolValue == false
                let cat: TraceEvent.Category = literature.contains(tool) ? .literature
                    : (["dispatch", "task", "claim_finding", "respond_review"].contains(tool) || e.actor != "main") ? .agents : .work
                return ev(tool, String(what.prefix(200)) + receipt + (failed ? " ✗" : ""), error: failed, cat)
            case "supervisor_review":
                return ev("review", "\(d.str("kind") ?? "review") → \(d.str("verdict") ?? "?")", error: d.str("verdict") == "block", .agents)
            case "review_unavailable":
                return ev("review", "review unavailable: \((d.str("reason") ?? "").prefix(160))", error: true, .agents)
            case "integrity_signal":
                let details = (d["signals"]?.arrayValue ?? []).compactMap { $0.str("detail") }
                return details.isEmpty ? nil : TraceEvent(id: e.seq, at: e.time, actor: "host", kind: "signal", text: details.joined(separator: " · "), isError: true, category: .agents)
            case "deliberation":
                let text = "\(d.str("thread") ?? "") \(d.str("from") ?? "") → \(d.str("to") ?? "") [\(d.str("kind") ?? "")] \((d.str("text") ?? "").prefix(160))"
                return TraceEvent(id: e.seq, at: e.time, actor: d.str("from") ?? agent, kind: "deliberation", text: text, isError: false, category: .agents)
            case "git_commit":
                return TraceEvent(id: e.seq, at: e.time, actor: "git", kind: "commit", text: "\((d.str("commit") ?? "").prefix(8)) \(d.str("subject") ?? "")", isError: false, category: .work)
            case "preregistration_gate":
                return TraceEvent(id: e.seq, at: e.time, actor: "host", kind: "gate", text: "analysis held until the plan exists (\(d.str("tool") ?? ""))", isError: true, category: .agents)
            case "permission" where d.str("decision") == "deny":
                return TraceEvent(id: e.seq, at: e.time, actor: "host", kind: "permission", text: "denied \(d.str("tool") ?? ""): \((d.str("reason") ?? "").prefix(160))", isError: true, category: .agents)
            case "compaction":
                return TraceEvent(id: e.seq, at: e.time, actor: "host", kind: "compaction", text: "context compacted", isError: false, category: .work)
            case "error":
                return TraceEvent(id: e.seq, at: e.time, actor: "host", kind: "error", text: String((d.str("message") ?? "").prefix(200)), isError: true, category: .work)
            case "user_turn" where e.actor == "user":
                return TraceEvent(id: e.seq, at: e.time, actor: "user", kind: "user", text: String((d.str("text") ?? "").prefix(160)), isError: false, category: .work)
            default:
                return nil
            }
        }
    }
}
