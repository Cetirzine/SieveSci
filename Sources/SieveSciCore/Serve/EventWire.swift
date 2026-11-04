import Foundation

/// JSON forms of agent events and their payloads for `sievesci serve` (docs/SERVE_PROTOCOL.md).
/// Payload types that are already `Codable` keep their stored shape; enums with associated values
/// get explicit `kind` fields instead of Swift's synthesized `{"case": {"_0": …}}` coding.
public enum Wire {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Any Codable value as JSON (null if it cannot be encoded).
    public static func value<T: Encodable>(_ v: T) -> JSON {
        guard let d = try? encoder.encode(v), let j = try? JSONCodec.parse(d) else { return .null }
        return j
    }

    public static func meter(_ m: ContextMeter) -> JSON {
        ["model": .string(m.model), "contextWindow": .int(m.contextWindow), "lastPromptTokens": .int(m.lastPromptTokens),
         "lastOutputTokens": .int(m.lastOutputTokens), "fill": .double(m.fill), "cacheHitRate": .double(m.cacheHitRate),
         "session": value(m.session)]
    }

    public static func permission(_ r: PermissionRequest) -> JSON {
        ["id": .string(r.id), "tool": .string(r.tool), "summary": .string(r.summary), "input": r.input,
         "effect": .string(r.effect.rawValue), "rememberPattern": .string(r.rememberPattern)]
    }

    public static func diff(_ d: FileDiff) -> JSON {
        func kind(_ k: FileDiff.LineKind) -> String { switch k { case .context: "context"; case .added: "added"; case .removed: "removed" } }
        return ["path": .string(d.path), "added": .int(d.added), "removed": .int(d.removed), "isNewFile": .bool(d.isNewFile),
                "isBinaryOrLarge": .bool(d.isBinaryOrLarge),
                "hunks": .array(d.hunks.map { h in
                    ["header": .string(h.header), "lines": .array(h.lines.map { l in
                        ["kind": .string(kind(l.kind)), "text": .string(l.text),
                         "old": l.oldNumber.map { .int($0) } ?? .null, "new": l.newNumber.map { .int($0) } ?? .null]
                    })]
                })]
    }

    public static func ask(_ o: AskOutcome) -> JSON {
        switch o {
        case .answered(let a): return ["kind": "answered", "answers": .array(a.map(answer))]
        case .dismissed(let note): return ["kind": "dismissed", "note": note.map { .string($0) } ?? .null]
        case .timedOut(let s): return ["kind": "timedOut", "seconds": .int(s)]
        case .unavailable: return ["kind": "unavailable"]
        }
    }

    /// `{kind: "answered", answers: [...]}` or `{kind: "dismissed", note?}` from a front end.
    public static func askOutcome(_ j: JSON) -> AskOutcome? {
        switch j.str("kind") {
        case "answered":
            guard let raw = j["answers"]?.arrayValue else { return nil }
            var answers: [AskAnswer] = []
            for a in raw {
                guard let q = a.str("questionId") ?? a.str("question_id") else { return nil }
                answers.append(AskAnswer(questionId: q, selected: a["selected"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                         other: a.str("other"), text: a.str("text")))
            }
            return .answered(answers)
        case "dismissed": return .dismissed(j.str("note"))
        default: return nil
        }
    }

    public static func answer(_ a: AskAnswer) -> JSON {
        ["questionId": .string(a.questionId), "selected": .array(a.selected.map { .string($0) }),
         "other": a.other.map { .string($0) } ?? .null, "text": a.text.map { .string($0) } ?? .null]
    }

    public static func event(_ e: AgentEvent) -> JSON {
        func ev(_ type: String, _ fields: [String: JSON]) -> JSON {
            var o = fields
            o["type"] = .string(type)
            return .object(o)
        }
        switch e {
        case .turnStarted(let role, let a): return ev("turnStarted", ["role": .string(role.rawValue), "agentId": .string(a)])
        case .textDelta(let a, let t): return ev("textDelta", ["agentId": .string(a), "text": .string(t)])
        case .thinkingDelta(let a, let t): return ev("thinkingDelta", ["agentId": .string(a), "text": .string(t)])
        case .toolStarted(let a, let id, let name, let input):
            return ev("toolStarted", ["agentId": .string(a), "id": .string(id), "name": .string(name), "input": input])
        case .toolFinished(let a, let id, let name, let out, let err, let receipt):
            return ev("toolFinished", ["agentId": .string(a), "id": .string(id), "name": .string(name), "output": .string(out),
                                       "isError": .bool(err), "receipt": .string(receipt)])
        case .assistantMessage(let a, let m): return ev("assistantMessage", ["agentId": .string(a), "message": value(m)])
        case .usage(let a, let m): return ev("usage", ["agentId": .string(a), "meter": meter(m)])
        case .permissionRequested(let r): return ev("permissionRequested", ["request": permission(r)])
        case .integrity(let s): return ev("integrity", ["signals": value(s)])
        case .supervisorStarted(let k, let r): return ev("supervisorStarted", ["kind": .string(k), "reason": .string(r)])
        case .supervisorReview(let k, let v, let b): return ev("supervisorReview", ["kind": .string(k), "verdict": .string(v), "body": .string(b)])
        case .planChanged(let p): return ev("planChanged", ["plan": value(p)])
        case .claimsChanged(let c): return ev("claimsChanged", ["claims": value(c)])
        case .notice(let t): return ev("notice", ["text": .string(t)])
        case .error(let t): return ev("error", ["text": .string(t)])
        case .turnFinished(let a, let stop): return ev("turnFinished", ["agentId": .string(a), "stop": .string(stop.rawValue)])
        case .agentStarted(let id, let role, let parent, let purpose):
            return ev("agentStarted", ["id": .string(id), "role": .string(role.rawValue), "parent": .string(parent), "purpose": .string(purpose)])
        case .agentFinished(let id, let role, let result):
            return ev("agentFinished", ["id": .string(id), "role": .string(role.rawValue), "result": .string(result)])
        case .literature(let a, let action, let key, let title, let detail):
            return ev("literature", ["agentId": .string(a), "action": .string(action.rawValue), "key": .string(key), "title": .string(title), "detail": .string(detail)])
        case .fileChanged(let a, let path, let d): return ev("fileChanged", ["agentId": .string(a), "path": .string(path), "diff": diff(d)])
        case .committed(let h, let s, let n): return ev("committed", ["hash": .string(h), "subject": .string(s), "files": .int(n)])
        case .toolProgress(let a, let id, let lines):
            return ev("toolProgress", ["agentId": .string(a), "id": .string(id), "lines": .array(lines.map { .string($0) })])
        case .jobOutput(let job, let lines): return ev("jobOutput", ["job": .string(job), "lines": .array(lines.map { .string($0) })])
        case .jobFinished(let job, let code, let secs): return ev("jobFinished", ["job": .string(job), "exitCode": .int(Int(code)), "seconds": .int(secs)])
        case .jobNotification(let n): return ev("jobNotification", ["notification": value(n)])
        case .deliberation(let t, let from, let to, let kind, let text):
            return ev("deliberation", ["thread": .string(t), "from": .string(from), "to": .string(to), "kind": .string(kind), "text": .string(text)])
        case .askRequested(let r): return ev("askRequested", ["request": value(r)])
        case .askResolved(let id, let o): return ev("askResolved", ["id": .string(id), "outcome": ask(o)])
        case .brainstormChanged(let s): return ev("brainstormChanged", ["state": value(s)])
        case .ideasChanged(let i): return ev("ideasChanged", ["ideas": value(i)])
        }
    }
}
