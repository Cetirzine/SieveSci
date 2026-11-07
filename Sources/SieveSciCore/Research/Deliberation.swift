import Foundation

/// Bounded deliberation between agents: the research agent may question, answer or rebut a
/// reviewer (checker or verifier), and the reviewer may concede or hold its position — but the
/// host keeps it from turning into an argument that burns tokens without settling anything.
///
/// Rules (enforced by the host, not by asking the models nicely):
/// 1. **Threads are anchored to a review.** Every exchange belongs to one review (`rv3`) and one
///    issue in it; no open-ended chat between agents.
/// 2. **Evidence or nothing.** A rebuttal must cite at least one item of evidence not already used
///    in the thread (a receipt id, a library key, a workspace file). An argument without new
///    evidence is refused before any model is called, and does not count as an exchange.
/// 3. **No repetition.** An argument too similar to one already made in the thread (token overlap)
///    is refused; a reviewer reply that repeats itself counts as a stalemate.
/// 4. **Hard limits.** At most `maxExchanges` rebuttal→reply rounds per thread and
///    `maxExchangesPerSession` overall. Replies are length-capped.
/// 5. **Settle, don't win.** A thread ends as *accepted* (the agent agrees and acts), *withdrawn*
///    (the reviewer concedes), or *contested* (the limit is reached or a side has nothing new). A
///    contested issue is recorded in the audit log, shown to the user, listed in every turn's
///    context and in the report; empirical disputes are routed to the blind verifier via
///    `claim_finding` instead of more argument. Conceding to good evidence is correct behaviour for
///    either side and is never penalised.
public struct DeliberationPolicy: Codable, Sendable {
    public var maxExchanges = 2
    public var maxExchangesPerSession = 20
    public var repetitionThreshold = 0.6
    public var maxArgumentChars = 2000
    public init() {}
}

public final class Deliberation: @unchecked Sendable {
    public enum Outcome: String, Codable, Sendable { case open, accepted, withdrawn, contested }

    public struct Issue: Sendable {
        public var text: String
        public var outcome: Outcome = .open
        public var resolution = ""
    }

    final class Thread: @unchecked Sendable {
        let id: String, kind: String, reviewer: AgentSession, claimId: String?
        var issues: [Issue]
        var exchanges = 0
        var arguments: [(side: String, words: Set<String>)] = []
        var evidence: Set<String> = []
        init(id: String, kind: String, reviewer: AgentSession, issues: [Issue], claimId: String?) {
            self.id = id; self.kind = kind; self.reviewer = reviewer; self.issues = issues; self.claimId = claimId
        }
    }

    let services: SessionServices
    public var policy = DeliberationPolicy()
    private let lock = NSLock()
    private var threads: [String: Thread] = [:]
    private var n = 0
    private var total = 0

    init(services: SessionServices) { self.services = services }

    // MARK: Opening

    /// Registers a review as a thread the research agent may respond to. Returns its id.
    func open(kind: String, reviewer: AgentSession, issues: [String], claimId: String? = nil) -> String {
        lock.lock(); defer { lock.unlock() }
        n += 1
        let id = "rv\(n)"
        threads[id] = Thread(id: id, kind: kind, reviewer: reviewer, issues: (issues.isEmpty ? ["(the review as a whole)"] : issues).map { Issue(text: $0) },
                             claimId: claimId)
        return id
    }

    /// The footer appended to reviews so the agent knows how to respond.
    func instructions(_ id: String) -> String {
        """
        (Review \(id). Fix each issue, or respond with `respond_review` id=\(id): position "agree", "answer" \
        (to a reviewer question), "clarify", or "disagree" with NEW evidence — receipt ids, [@key] library \
        entries or files. At most \(policy.maxExchanges) exchanges; arguments without new evidence or that \
        repeat earlier points are refused. Unsettled issues are marked contested and shown to the user.)
        """
    }

    // MARK: Exchanges

    public enum Position: String, CaseIterable, Sendable { case agree, answer, clarify, disagree }

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 })
    }

    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    /// Evidence items that actually resolve: receipts in the ledger, library keys, workspace files.
    func resolvable(_ items: [String]) -> (ok: [String], bad: [String]) {
        var ok: [String] = [], bad: [String] = []
        for raw in items {
            let e = raw.trimmingCharacters(in: CharacterSet(charactersIn: " []@"))
            if services.ledger.receipt(e) != nil || services.library.records.contains(where: { $0.key == e })
                || FileManager.default.fileExists(atPath: services.workspace.appendingPathComponent(e).path) {
                ok.append(e)
            } else { bad.append(raw) }
        }
        return (ok, bad)
    }

    enum Gate {
        case reply(String)
        case contest(Thread, Int, String)
        case proceed(Thread, Int, [String], Int, Int)
    }

    /// The host-side rules, applied before any model is called (synchronous, under the lock).
    func gate(_ tid: String, issue: Int?, position: Position, argument: String, evidence: [String], from agentId: String) -> Gate {
        lock.lock(); defer { lock.unlock() }
        guard let t = threads[tid] else { return .reply("No review thread \(tid).") }
        let idx = max(0, min((issue ?? 1) - 1, t.issues.count - 1))
        guard t.issues[idx].outcome == .open else {
            let o = t.issues[idx]
            return .reply("Issue \(idx + 1) of \(tid) is already closed (\(o.outcome.rawValue): \(o.resolution)). No further argument on it.")
        }
        if position == .agree {
            t.issues[idx].outcome = .accepted
            t.issues[idx].resolution = "research agent accepted the issue"
            return .proceed(t, idx, [], -1, 0)
        }
        // Rule 4: limits.
        if t.exchanges >= policy.maxExchanges || total >= policy.maxExchangesPerSession {
            return .contest(t, idx, t.exchanges >= policy.maxExchanges ? "exchange limit for this review reached" : "session deliberation budget used up")
        }
        // Rule 2: new evidence for a rebuttal.
        let (ok, bad) = resolvable(evidence)
        let fresh = ok.filter { !t.evidence.contains($0) }
        if position == .disagree && fresh.isEmpty {
            return .reply("""
            Refused (not sent to the reviewer, no exchange used): a rebuttal needs at least one item of evidence \
            not already used in \(tid) — a receipt id, a library key or a workspace file\(bad.isEmpty ? "" : "; these did not resolve: \(bad.joined(separator: ", "))"). \
            Produce the evidence (run the check, fetch the paper) or act on the issue.
            """)
        }
        // Rule 3: no repetition.
        let w = Self.words(argument)
        if let prev = t.arguments.filter({ $0.side == "agent" }).map({ Self.similarity($0.words, w) }).max(), prev >= policy.repetitionThreshold {
            return .reply("Refused (no exchange used): this repeats an argument you already made in \(tid). Bring something new or act on the issue.")
        }
        t.exchanges += 1
        total += 1
        t.arguments.append(("agent", w))
        t.evidence.formUnion(fresh)
        return .proceed(t, idx, fresh, t.exchanges, policy.maxExchanges)
    }

    /// Records the reviewer's reply; returns whether it repeats itself and its new evidence.
    func absorb(_ t: Thread, reason: String, evidence: [String]) -> (repeats: Bool, fresh: [String]) {
        lock.lock(); defer { lock.unlock() }
        let rw = Self.words(reason)
        let repeats = (t.arguments.filter { $0.side == "reviewer" }.map { Self.similarity($0.words, rw) }.max() ?? 0) >= policy.repetitionThreshold
        t.arguments.append(("reviewer", rw))
        let fresh = resolvable(evidence).ok.filter { !t.evidence.contains($0) }
        t.evidence.formUnion(fresh)
        return (repeats, fresh)
    }

    func narrow(_ t: Thread, _ idx: Int, _ text: String) { lock.lock(); t.issues[idx].text = "(narrowed) " + text; lock.unlock() }

    /// Handles one response from `agentId`. Returns the text the tool hands back to the agent.
    public func respond(thread tid: String, issue: Int?, position: Position, argument: String, evidence: [String], from agentId: String) async -> String {
        let t: Thread, idx: Int, fresh: [String], exchange: Int, maxEx: Int
        switch gate(tid, issue: issue, position: position, argument: argument, evidence: evidence, from: agentId) {
        case .reply(let text): return text
        case .contest(let th, let i, let reason): return contest(th, i, reason: reason)
        case .proceed(let th, let i, let f, let e, let m): (t, idx, fresh, exchange, maxEx) = (th, i, f, e, m)
        }
        if exchange < 0 {
            record(t, idx, from: agentId, to: t.reviewer.id, kind: "agree", text: argument)
            return "Recorded: you accepted issue \(idx + 1) of \(tid). Act on it."
        }

        let arg = argument.truncated(policy.maxArgumentChars, marker: " …[truncated]")
        record(t, idx, from: agentId, to: t.reviewer.id, kind: position.rawValue, text: arg + (fresh.isEmpty ? "" : "\nEvidence: " + fresh.joined(separator: ", ")))
        let ask = """
        <\(position.rawValue) review="\(tid)" issue="\(idx + 1)" exchange="\(exchange)/\(maxEx)">
        Issue: \(t.issues[idx].text)
        The research agent says: \(arg)
        New evidence it cites: \(fresh.isEmpty ? "none" : fresh.joined(separator: ", ")) (read receipts with `receipt`, files with `read_file`)
        </\(position.rawValue)>
        Examine the evidence itself, then reply with one JSON object and nothing else:
        {"position": "concede" | "maintain" | "narrow", "reason": "≤ 4 sentences, about the evidence, not the agent", \
        "evidence": ["receipt / key / file:line you rely on"], "question": "one precise question, or null"\
        \(t.kind == "verification" ? ", \"verdict\": \"verified\" | \"refuted\" | \"inconclusive\" (re-run your analysis first if the evidence warrants)" : "")}
        Concede when the evidence answers the issue — that is the correct outcome, not a loss. Maintain only with \
        evidence or a specific flaw in theirs; do not restate earlier points. "narrow" = the issue stands in a \
        reduced form (say which). This is exchange \(exchange) of \(maxEx); unsettled issues go to the user.
        """
        let reply: String
        do { reply = try await t.reviewer.send(ask)?.plainText ?? "" } catch {
            return contest(t, idx, reason: "reviewer failed to reply: \(error.localizedDescription)",
                                                     shown: L10n.s("reviewer failed to reply: %@", error.localizedDescription))
        }
        let j = Supervisor.parseJSON(reply)
        let pos = j?.str("position") ?? "maintain"
        let reason = j?.str("reason") ?? reply.truncated(1500)
        let revEvidence = (j?["evidence"]?.arrayValue ?? []).compactMap(\.stringValue)
        let question = j?.str("question").flatMap { $0 == "null" || $0.isEmpty ? nil : $0 }
        record(t, idx, from: t.reviewer.id, to: agentId, kind: pos, text: reason + (question.map { "\nQuestion: \($0)" } ?? ""))

        let (repeats, revFresh) = absorb(t, reason: reason, evidence: revEvidence)

        if t.kind == "verification", let cid = t.claimId, let v = j?.str("verdict") {
            let status: Claim.Status = v == "verified" ? .verified : (v == "refuted" ? .refuted : .inconclusive)
            services.claims.hostSet(cid, status: status, verdict: "after deliberation \(tid): " + reason)
            services.emit(.claimsChanged(services.claims.snapshot))
            if status != .verified { services.research.requestReview(trigger: "claim \(cid) \(v) after deliberation", subject: cid) }
        }
        switch pos {
        case "concede":
            close(t, idx, .withdrawn, "reviewer conceded: \(reason)")
            return "The reviewer conceded issue \(idx + 1) of \(tid): \(reason)\nThe issue is withdrawn."
        case "narrow":
            narrow(t, idx, reason)
            return "The reviewer narrowed issue \(idx + 1) of \(tid): \(reason)\(question.map { "\nQuestion: \($0)" } ?? "")\nAddress the narrowed issue, or respond once more with new evidence."
        default:
            if repeats && revFresh.isEmpty { return contest(t, idx, reason: "the reviewer repeated its position without new evidence") }
            if exchange >= maxEx { return contest(t, idx, reason: "no agreement within \(maxEx) exchanges",
                                                     shown: L10n.s("no agreement within %@ exchanges", String(maxEx)), reviewerLast: reason) }
            return "The reviewer maintains issue \(idx + 1) of \(tid): \(reason)\(question.map { "\nQuestion for you: \($0)" } ?? "")\nAct on it, or answer once more with new evidence (\(maxEx - exchange) exchange left)."
        }
    }

    func close(_ t: Thread, _ idx: Int, _ outcome: Outcome, _ resolution: String) {
        lock.lock(); t.issues[idx].outcome = outcome; t.issues[idx].resolution = resolution; lock.unlock()
        services.log("deliberation_closed", actor: "host", ["thread": .string(t.id), "issue": .int(idx + 1),
                                                            "outcome": .string(outcome.rawValue), "resolution": .string(resolution.truncated(2000))])
    }

    /// `reason` goes to the record and the agents (English); `shown` is the user's localized version.
    func contest(_ t: Thread, _ idx: Int, reason: String, shown: String? = nil, reviewerLast: String = "") -> String {
        close(t, idx, .contested, reason)
        services.emit(.notice(L10n.s("Contested: issue %@ of %@ (%@) — %@. %@. Shown in /claims and the report; your call.",
                                     String(idx + 1), t.id, L(t.kind), t.issues[idx].text.truncated(160), shown ?? L(reason))))
        return """
        Deliberation on issue \(idx + 1) of \(t.id) is closed as CONTESTED (\(reason)). No further argument on it. \
        Do not present the disputed point as settled: state both positions briefly in your reply\(reviewerLast.isEmpty ? "" : " (reviewer: \(reviewerLast.truncated(300)))"). \
        If it can be settled empirically, register it with `claim_finding` so the blind verifier tests it; otherwise \
        the user decides.
        """
    }

    func record(_ t: Thread, _ idx: Int, from: String, to: String, kind: String, text: String) {
        services.emit(.deliberation(thread: t.id, from: from, to: to, kind: kind, text: text))
        services.log("deliberation", actor: from.hasPrefix("main") ? "main" : t.kind == "verification" ? "verifier" : "checker",
                     ["thread": .string(t.id), "issue": .int(idx + 1), "from": .string(from), "to": .string(to), "kind": .string(kind), "text": .string(text.truncated(4000))])
    }

    /// Contested issues, for the turn context, /claims and the report.
    public var contested: [(thread: String, kind: String, issue: String, reason: String)] {
        lock.lock(); defer { lock.unlock() }
        return threads.values.sorted { $0.id < $1.id }.flatMap { t in
            t.issues.filter { $0.outcome == .contested }.map { (t.id, t.kind, $0.text, $0.resolution) }
        }
    }
}

struct RespondReviewTool: Tool {
    let name = "respond_review"
    let description = """
    Respond to a checker or verifier review (id rvN from the review) about one issue: "agree" (you will act \
    on it), "answer" (a reviewer question), "clarify" (a misunderstanding of what was done), or "disagree" \
    (rebuttal). Rebuttals must cite NEW evidence — receipt ids, library keys or workspace files not already \
    used in the thread. The host limits each review to a few exchanges and refuses repetition; unsettled \
    issues become contested and go to the user. Prefer fixing the issue when it is right.
    """
    var inputSchema: JSON {
        Schema.object(["id": Schema.string("Review id, e.g. rv3"), "issue": Schema.integer("Issue number in the review (1-based)"),
                       "position": Schema.stringEnum("agree | answer | clarify | disagree", Deliberation.Position.allCases.map(\.rawValue)),
                       "argument": Schema.string("Your point, concise and about the evidence"),
                       "evidence": Schema.array("New evidence: receipt ids, library keys or file paths", items: Schema.string("receipt id, library key or file path"))],
                      required: ["id", "position", "argument"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func runsConcurrently(for input: JSON) -> Bool { false }   // changes session state; runs in order
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard ctx.role == .main else { return .error("Only the research agent responds to reviews; report disagreements in your result.") }
        guard let pos = Deliberation.Position(rawValue: try input.required("position")) else { return .error("position must be agree, answer, clarify or disagree") }
        let text = await ctx.services.deliberation.respond(thread: try input.required("id"), issue: input.int("issue"), position: pos,
                                                           argument: input.str("argument") ?? "",
                                                           evidence: (input["evidence"]?.arrayValue ?? []).compactMap(\.stringValue), from: ctx.sessionId)
        return ToolOutput(text, isError: text.hasPrefix("Refused"))
    }
}
