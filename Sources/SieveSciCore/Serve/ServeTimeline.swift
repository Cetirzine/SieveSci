import Foundation

/// A saved task's conversation as the chat showed it live: the lead agent's messages, reasoning and
/// tool calls (with their file diffs), and a card for every worker, checker and verifier with the
/// steps it took. The transcript holds what the lead agent saw; the audit log adds what only it
/// recorded (a CLI agent's tool calls, subagents' steps, how long each reply thought).
extension ServeServer {
    static func timeline(taskDir: URL) -> [JSON] {
        let audit = (try? AuditLog.read(taskDir.appendingPathComponent("audit.jsonl"),
                                        kinds: ["user_turn", "tool_call", "model_call", "agent_start"])) ?? []
        let msgs = DisplayTimeline.merge(SessionStore.load(dir: taskDir, agent: "main"), audit: audit.filter { $0.kind == "user_turn" || $0.kind == "tool_call" })

        // How long each saved reply thought (recorded since 0.2.5; older tasks show no duration).
        var thought: [String: Double] = [:]
        for e in audit where e.kind == "model_call" {
            if let m = e.data.str("message"), let s = e.data["thinking_seconds"]?.doubleValue { thought[m] = s }
        }

        var results: [String: ToolResult] = [:]
        for m in msgs { for b in m.blocks { if case .toolResult(let r) = b { results[r.toolUseId] = r } } }

        var out: [JSON] = []
        var toolAt: [String: Int] = [:]   // receipt → index in `out`
        // Delegating calls with no result yet (SieveSci stopped while they ran): their workers' cards go after them.
        var unfinished: [(at: Int, input: JSON)] = []
        for m in msgs {
            for b in m.blocks {
                switch b {
                case .text(let t) where m.role == .user && !HostContext.isHostBlock(t):
                    let own = HostContext.userText(t)
                    if !own.isEmpty, !own.hasPrefix("[tool result") { out.append(["kind": "user", "text": .string(own)]) }
                case .thinking(let t) where m.role == .assistant && !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    out.append(["kind": "thinking", "text": .string(t.text), "seconds": thought[m.id].map { .double($0) } ?? .null])
                case .text(let t) where m.role == .assistant && !t.isEmpty:
                    out.append(["kind": "assistant", "text": .string(t)])
                case .toolUse(let tu):
                    var item = toolItem(id: tu.id, name: tu.name, input: tu.input)
                    var receipt: String?
                    if let r = results[tu.id] {
                        let (content, rid) = splitReceipt(r.content)
                        receipt = rid
                        item["output"] = .string(content)
                        item["isError"] = .bool(r.isError)
                        if let rid { item["receipt"] = .string(rid); toolAt[rid] = out.count }
                    }
                    // No result, or the "not recorded" one written after a crash (it has no receipt).
                    if receipt == nil, tu.name == "task" || tu.name == "dispatch" { unfinished.append((out.count, tu.input)) }
                    out.append(.object(item))
                default: break
                }
            }
        }

        // Subagents, from the audit: each card goes after the lead agent's call that was running when it
        // started (the call that delegated, reviewed or verified), with the steps it took inside.
        struct Sub { var id: String; var role: String; var first: Int; var last: Int; var firstAt: Date; var lastAt: Date; var brief: String?; var title: String?; var parent: String; var steps: Int }
        var subs: [String: Sub] = [:], order: [String] = []
        var mainCalls: [(seq: Int, receipt: String?, tool: String, input: JSON)] = []
        for e in audit {
            let agent = e.data.str("agent") ?? ""
            if e.kind == "tool_call", e.actor == "main" {
                mainCalls.append((e.seq, e.data.str("receipt"), e.data.str("tool") ?? "", e.data["input"] ?? [:]))
                continue
            }
            guard !agent.isEmpty, agent != "main", !agent.hasPrefix("quiet-"),
                  ["worker", "checker", "verifier", "host"].contains(e.actor) || e.kind == "agent_start" else { continue }
            if subs[agent] == nil {
                let role = String(agent.split(separator: "-").first ?? "worker")
                subs[agent] = Sub(id: agent, role: role, first: e.seq, last: e.seq, firstAt: e.time, lastAt: e.time, brief: nil, title: nil, parent: "main", steps: 0)
                order.append(agent)
            }
            subs[agent]!.last = e.seq
            subs[agent]!.lastAt = e.time
            if e.kind == "user_turn", subs[agent]!.brief == nil { subs[agent]!.brief = e.data.str("text") }
            if e.kind == "agent_start" { subs[agent]!.title = e.data.str("purpose"); subs[agent]!.parent = e.data.str("parent") ?? "main" }
            if e.kind == "tool_call" { subs[agent]!.steps += 1 }
        }
        var after: [Int: [JSON]] = [:], trailing: [JSON] = []
        for id in order {
            guard let s = subs[id] else { continue }
            let host = mainCalls.first { $0.seq > s.first }
            // No call of the lead agent finished after this one started: it was delegated by the call still open.
            let open = host == nil && !unfinished.isEmpty ? unfinished.removeLast() : nil
            let card: [String: JSON] = ["kind": "agent", "id": .string(s.id), "role": .string(s.role), "parent": .string(s.parent),
                                        "purpose": .string(s.title ?? purpose(brief: s.brief, delegatedBy: host.map { ($0.tool, $0.input) } ?? open.map { ("task", $0.input) })),
                                        // The steps themselves come with `history.agent` when the card is opened.
                                        "seconds": .double(s.lastAt.timeIntervalSince(s.firstAt)), "stepCount": .int(s.steps)]
            if let r = host?.receipt, let at = toolAt[r] { after[at, default: []].append(.object(card)) }
            else if let open { after[open.at, default: []].append(.object(card)) }
            else { trailing.append(.object(card)) }
        }
        var merged: [JSON] = []
        for (i, item) in out.enumerated() {
            merged.append(item)
            merged += after[i] ?? []
        }
        return merged + trailing
    }

    /// One subagent's steps, from the audit (its transcript is not kept): tool rows as the card showed them.
    static func agentSteps(taskDir: URL, agent: String) -> [JSON] {
        let audit = (try? AuditLog.read(taskDir.appendingPathComponent("audit.jsonl"), kinds: ["tool_call"])) ?? []
        return audit.filter { $0.data.str("agent") == agent }.map { e in
            let id = e.data.str("receipt") ?? "a\(e.seq)"
            var item = toolItem(id: id, name: e.data.str("tool") ?? "tool", input: e.data["input"] ?? [:])
            item["output"] = .string(e.data.str("output_excerpt") ?? "")
            item["isError"] = .bool(e.data["success"]?.boolValue == false || (e.data["exit_code"]?.intValue).map { $0 != 0 } == true)
            if let r = e.data.str("receipt") { item["receipt"] = .string(r) }
            return .object(item)
        }
    }

    /// A tool row: name, input, and the diff a file edit made (as `fileChanged` gives it live).
    static func toolItem(id: String, name: String, input: JSON) -> [String: JSON] {
        var item: [String: JSON] = ["kind": "tool", "id": .string(id), "name": .string(name), "input": input]
        if let path = input.str("path") {
            if name == "edit_file", let old = input.str("old_string"), let new = input.str("new_string") {
                item["diff"] = Wire.diff(FileDiff.make(path: path, old: old, new: new))
            } else if name == "write_file", let content = input.str("content") {
                item["diff"] = Wire.diff(FileDiff.make(path: path, old: nil, new: content))
            }
        }
        return item
    }

    /// Results end with their receipt id, e.g. "[receipt r12]".
    static func splitReceipt(_ s: String) -> (String, String?) {
        guard let range = s.range(of: #"\n*\[receipt (r\d+)\]\s*$"#, options: .regularExpression) else { return (s, nil) }
        let receipt = String(s[range]).replacingOccurrences(of: "receipt", with: "").filter { $0.isLetter || $0.isNumber }
        var content = s
        content.removeSubrange(range)
        return (content, receipt)
    }

    /// What the card says the agent was for, as live (`agentStarted` purpose): a delegated plan step's
    /// title, the delegating call's description, else the start of its brief.
    static func purpose(brief: String?, delegatedBy: (String, JSON)?) -> String {
        if let b = brief, let line = b.split(separator: "\n").first(where: { $0.hasPrefix("Your step: ") }) {
            return String(line.dropFirst("Your step: ".count))
        }
        if let (tool, input) = delegatedBy, tool == "task", let d = input.str("description"), !d.isEmpty { return d }
        // A review (Supervisor.review): "Review checkpoint S2: …", else "Review (kind): signal details".
        if let b = brief, let m = b.range(of: #"^<review_request kind="([^"]+)">"#, options: .regularExpression) {
            let kind = String(b[m]).replacingOccurrences(of: "<review_request kind=\"", with: "").replacingOccurrences(of: "\">", with: "")
            let lines = b.split(separator: "\n").map(String.init)
            if let cp = lines.first(where: { $0.hasPrefix("Checkpoint ") }) { return "Review checkpoint " + cp.dropFirst("Checkpoint ".count) }
            let details = lines.filter { $0.hasPrefix("- [") }.compactMap { l in l.range(of: "] ").map { String(l[$0.upperBound...]) } }
            return "Review (\(kind)): " + details.joined(separator: "; ").truncated(160)
        }
        let text = (brief ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return String(text.prefix(200))
    }
}
