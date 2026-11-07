import Foundation

/// What to do when a reviewer (checker or verifier) does not deliver a verdict: it declined, hit a
/// capability limit, or the call failed.
///
/// The rule that matters for integrity: **a review that did not happen is never a pass.** A refused
/// or failed review leaves the checkpoint unreviewed and the claim unverified, says so in the
/// transcript, the audit log and the report, and (after one retry on a different reviewer model)
/// goes to the user. The host never rewords a request to get a different safety decision out of a
/// model, and never lowers the bar because a review could not be obtained.
public enum RefusalKind: String, Codable, Sendable {
    /// The model declined on policy grounds (safety classifier, content policy).
    case policy
    /// The model says it cannot do something (run code, access a file) — usually answerable another way.
    case capability
    /// Transport, quota or protocol failure: worth retrying.
    case transient
    /// A reply arrived but carried no verdict (truncated, malformed JSON, empty).
    case unusable
}

public struct RefusalEvent: Sendable, Codable, Equatable {
    public var kind: RefusalKind
    public var role: String
    public var purpose: String
    public var detail: String
    public var model: String
    public var at: Date
}

public final class RefusalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RefusalEvent] = []

    public init() {}

    public func record(_ e: RefusalEvent) {
        lock.lock(); events.append(e); lock.unlock()
    }

    public var all: [RefusalEvent] { lock.lock(); defer { lock.unlock() }; return events }

    /// Consecutive events of the same kind for a role, counting back from the most recent.
    public func streak(kind: RefusalKind, role: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        var n = 0
        for e in events.reversed() where e.role == role {
            if e.kind == kind { n += 1 } else { break }
        }
        return n
    }

    /// Reviews that never produced a verdict, for the report's limitations section.
    public var unreviewed: [RefusalEvent] { all.filter { $0.kind == .policy || $0.kind == .unusable } }
}

public enum Refusals {
    /// Classifies an error thrown by a provider.
    public static func classify(error: Error) -> (RefusalKind, String) {
        if let p = error as? ProviderError {
            switch p {
            case .refused(let m): return (.policy, m)
            case .missingAPIKey(let r): return (.transient, "no API key for \(r)")
            case .cliNotFound(let c): return (.transient, "CLI not found: \(c)")
            case .protocolError(let m): return (.transient, m)
            case .stalled(let s): return (.transient, "no response for \(s) s")
            case .http(let status, let body):
                // 400 with a safety/policy body is a refusal; 429/5xx are transient.
                if status == 400 || status == 403 {
                    return (bodyLooksLikePolicy(body) ? .policy : .transient, "HTTP \(status): " + body.truncated(400))
                }
                return (.transient, "HTTP \(status): " + body.truncated(400))
            }
        }
        return (.transient, error.localizedDescription)
    }

    static func bodyLooksLikePolicy(_ body: String) -> Bool {
        let b = body.lowercased()
        for marker in ["safety", "safeguard", "content policy", "usage policy", "flagged", "blocked", "prohibited_content", "refusal"]
        where b.contains(marker) { return true }
        return false
    }

    /// Classifies a reply that arrived but carried no parsable verdict.
    public static func classify(reply: String, stop: StopReason?, hasVerdict: Bool) -> (RefusalKind, String)? {
        if hasVerdict { return nil }
        if stop == .refusal { return (.policy, reply.truncated(600)) }
        if stop == .maxTokens { return (.unusable, "the reply was cut off by the output limit") }
        if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (.unusable, "empty reply") }
        let t = reply.lowercased()
        // "I can't run code / access that file" is a capability limit, not a policy refusal.
        let capability = ["can't run", "cannot run", "unable to run", "can't execute", "cannot execute", "unable to execute",
                          "can't access", "cannot access", "unable to access", "can't open", "cannot open", "can't browse",
                          "无法运行", "无法执行", "无法访问", "不能运行"]
        if capability.contains(where: t.contains) { return (.capability, reply.truncated(600)) }
        let declines = ["i can't help", "i cannot help", "i can't assist", "i cannot assist", "i won't", "i'm not able to help",
                        "i am unable to help", "can't provide", "cannot provide", "我无法", "我不能提供", "我不会协助"]
        if declines.contains(where: t.contains) { return (.policy, reply.truncated(600)) }
        return (.unusable, "no JSON verdict in the reply")
    }

    /// The same event for the person reading the app (localized; the model gets `notice`).
    public static func userNotice(_ e: RefusalEvent, retriedWith: String?, escalated: Bool) -> String {
        let role = L(e.role), detail = e.detail.truncated(200)
        var s: String
        switch e.kind {
        case .policy: s = L10n.s("The %@ declined to review this (%@). The work is therefore NOT reviewed and nothing is approved.", role, detail)
        case .capability: s = L10n.s("The %@ could not carry out part of the review (%@).", role, detail)
        case .transient: s = L10n.s("The %@ call failed (%@).", role, detail)
        case .unusable: s = L10n.s("The %@ returned no usable verdict (%@).", role, detail)
        }
        if let m = retriedWith { s += " " + L10n.s("Retried with %@.", m) }
        if escalated { s += " " + L("Unresolved: the checkpoint stays open and any claim stays unverified. You decide how to proceed.") }
        return s
    }

    /// The message the host shows and records when a review could not be obtained. It states the
    /// consequence (nothing is approved) rather than suggesting a way around the refusal.
    public static func notice(_ e: RefusalEvent, retriedWith: String?, escalated: Bool) -> String {
        var s: String
        switch e.kind {
        case .policy:
            s = "The \(e.role) declined to review this (\(e.detail.truncated(200))). The work is therefore NOT reviewed and nothing is approved."
        case .capability:
            s = "The \(e.role) could not carry out part of the review (\(e.detail.truncated(200))). Supply what it needs — receipts, file contents, a numeric result — and ask again."
        case .transient:
            s = "The \(e.role) call failed (\(e.detail.truncated(200)))."
        case .unusable:
            s = "The \(e.role) returned no usable verdict (\(e.detail.truncated(200)))."
        }
        if let m = retriedWith { s += " Retried with \(m)." }
        if escalated {
            s += " This is unresolved: the checkpoint stays open and any claim stays unverified. Say so plainly in your reply, "
                + "report the result as unreviewed, and let the user decide how to proceed. Do not reword the request to obtain a different "
                + "safety decision, and do not treat the absence of a review as approval."
        }
        return s
    }
}
