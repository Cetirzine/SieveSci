import Foundation

/// The automatically written experiment log (实验日志).
///
/// It is a deterministic projection of the audit trail — no model call, so it costs no tokens and
/// cannot hallucinate. Each entry is timestamped and carries the receipt id / audit sequence it
/// came from, so every line of the notebook can be traced back to the hash-chained audit log.
public final class LabNotebook: @unchecked Sendable {
    public let url: URL
    let taskId: String
    private let lock = NSLock()
    private var lastDay = ""

    public init(url: URL, taskId: String) {
        self.url = url
        self.taskId = taskId
        if !FileManager.default.fileExists(atPath: url.path) {
            let header = "# " + L10n.s("Lab notebook — task %@", taskId) + "\n\n"
                + L("Written automatically by SieveSci from the provenance log (`audit.jsonl`). Each entry cites the audit sequence number `§n` and, for tool runs, the receipt id. Verify integrity with `/audit`.")
                + "\n\n"
            try? header.writeReliably(to: url)
        }
    }

    func attach(to audit: AuditLog) {
        audit.onAppend { [weak self] e in self?.record(e) }
    }

    func write(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.appendSafely(Data(s.utf8))
            try? fh.close()
        }
    }

    func record(_ e: AuditLog.Entry) {
        let day = ISO8601DateFormatter.string(from: e.time, timeZone: .current, formatOptions: [.withFullDate])
        let time = ISO8601DateFormatter.string(from: e.time, timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
        var out = ""
        // Audit listeners run on the logging thread, and tool calls of one step log concurrently.
        let newDay: Bool = lock.withLock { guard day != lastDay else { return false }; lastDay = day; return true }
        if newDay { out += "\n## \(day)\n" }
        let d = e.data
        let ref = "§\(e.seq)"
        switch e.kind {
        case "user_turn" where e.actor == "user":
            out += "\n**\(time)** · " + L10n.s("Request: %@", d.str("text").map { $0.truncated(400) } ?? "") + " \(ref)\n"
        case "tool_call":
            let tool = d.str("tool") ?? ""
            let ok = d.bool("success") == true
            let receipt = d.str("receipt") ?? ""
            let input = d["input"] ?? .null
            switch tool {
            case "python", "bash":
                let code = input.str("code") ?? input.str("command") ?? ""
                out += "\n**\(time)** · " + L10n.s("Ran %@", tool) + " [\(receipt)] — \(ok ? L("ok") : "**" + L("failed") + "**") \(ref)\n```\(tool == "python" ? "python" : "bash")\n\(code.truncated(1500))\n```\n"
                if let ex = d.str("output_excerpt"), !ex.isEmpty { out += L("Output (excerpt):") + "\n```\n\(ex.truncated(800))\n```\n" }
            case "write_file", "edit_file":
                let files = d["files_written"]?.objectValue ?? [:]
                out += "\n**\(time)** · \(L(tool == "write_file" ? "Wrote" : "Edited")) " + files.map { "`\($0.key)` (sha256 \($0.value.stringValue?.prefix(12) ?? ""))" }.joined(separator: ", ") + " [\(receipt)] \(ref)\n"
            case "web_search", "literature_search":
                out += "\n**\(time)** · " + L10n.s("Searched (%@): “%@”", tool, input.str("query") ?? "") + " [\(receipt)] \(ref)\n"
            case "bio_db":
                let what = input.str("query") ?? input.str("id") ?? ""
                out += "\n**\(time)** · " + L10n.s("Searched (%@): “%@”", "bio_db · " + (input.str("database") ?? ""), what) + " [\(receipt)] \(ref)\n"
            case "paper_graph":
                out += "\n**\(time)** · " + L10n.s("Searched (%@): “%@”", "paper_graph", input.str("ref") ?? "") + " [\(receipt)] \(ref)\n"
            case "paper_fetch":
                out += "\n**\(time)** · " + L10n.s("Added to library: %@", input.str("ref") ?? "") + " [\(receipt)] \(ref)\n"
            case "update_plan":
                if let a = input.str("action") { out += "\n**\(time)** · " + L10n.s("Plan %@", a) + "\(input.str("rationale").map { ": \($0)" } ?? "") [\(receipt)] \(ref)\n" }
            case "claim_finding":
                out += "\n**\(time)** · " + L10n.s("Claim registered: %@", input.str("statement") ?? "") + " [\(receipt)] \(ref)\n"
            default:
                if !ok { out += "\n**\(time)** · " + L10n.s("%@ failed", tool) + " [\(receipt)] \(ref)\n" }
            }
        case "supervisor_review":
            out += "\n**\(time)** · " + L10n.s("Independent review (%@)", L(d.str("kind") ?? "")) + " → **\(L((d.str("verdict") ?? "")))** \(ref)\n"
            if let issues = d["review"]?["issues"]?.arrayValue, !issues.isEmpty {
                out += issues.map { "  - \($0.str("severity") ?? ""): \($0.str("what") ?? "")" }.joined(separator: "\n") + "\n"
            }
        case "verification":
            out += "\n**\(time)** · " + L10n.s("Verification of %@", d.str("claim") ?? "") + " → **\(L((d.str("verdict") ?? "")))** ("
                + L10n.s("verifier receipts: %@", (d["receipts"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")) + ") \(ref)\n"
            if let r = d["report"]?.str("reasoning") { out += "  > \(r.truncated(800))\n" }
        case "integrity_signal":
            for s in d["signals"]?.arrayValue ?? [] where (s.int("severity") ?? 0) >= 2 {
                out += "\n**\(time)** · ⚠︎ " + L10n.s("Integrity signal (%@): %@", s.str("kind") ?? "", s.str("detail") ?? "") + " \(ref)\n"
            }
        case "compaction":
            out += "\n**\(time)** · " + L10n.s("Context compacted (%@).", L(d.str("reason") ?? "")) + " \(ref)\n"
        case "goal":
            out += "\n**\(time)** · " + L10n.s("Goal %@", L((d.str("event") ?? ""))) + ": \(d.str("objective") ?? "") \(ref)\n"
        default:
            return
        }
        write(out)
    }
}
