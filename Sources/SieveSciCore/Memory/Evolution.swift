import Foundation

/// Governed self-evolution for every agent role.
///
/// Principle: **know-how may evolve; rules may not.** Grounding gates, supervisor triggers, review
/// budgets and the integrity rules live in host code and in the frozen system prompts. Nothing an
/// agent learns can change them: learned memory and skills are context the agent reads, explicitly
/// subordinate to the integrity rules.
///
/// Every memory or skill write is a *proposal* that must pass, in order:
///  1. a deterministic scan — integrity anti-patterns (HackDetector) and an oversight-weakening
///     lexicon (learning to pass reviews, avoid verification, chase significance, be lenient …);
///  2. a provenance check — it must cite the receipts / review that taught it;
///  3. an independent evolution review by a fresh agent with a strict rubric;
///  4. for the checker's and verifier's own proposals, the user's approval (a reviewer that learns
///     to be lenient is the most dangerous drift, so a human signs off).
/// Accepted proposals are versioned in `~/.sievesci/evolution/` and in the task's audit log, and
/// can be reverted. Learned skills that keep preceding `revise`/`block` reviews are quarantined.
public struct EvolutionProposal: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case memory, skill }
    public enum Status: String, Codable, Sendable { case pending, accepted, rejected, reverted, quarantined }
    public var id: String
    public var role: AgentRole
    public var kind: Kind
    public var target: String           // e.g. "LESSONS" or skill name
    public var operation: String        // add | replace | remove | create | patch
    public var content: String
    public var match: String?
    public var provenance: [String]     // receipt ids / review ids it was learned from
    public var task: String
    public var status: Status
    public var reason: String
    public var createdAt: Date
    public var previous: String?        // prior content, for revert
}

public final class EvolutionGovernor: @unchecked Sendable {
    public let dir: URL
    private let lock = NSLock()
    public private(set) var proposals: [EvolutionProposal] = []

    /// Phrases that signal learning to game oversight or the science rather than to do it better.
    public static let driftPatterns: [String] = [
        #"(?i)(pass|get past|satisfy|appease|avoid|bypass|evade|circumvent|skip|not trigger)\w*\s+(the\s+)?(checker|reviewer|review|supervisor|verifier|verification|audit|grounding|gate)"#,
        #"(?i)(avoid|don'?t use|never use)\s+(words|phrases|language)\s+like\s+.{0,40}(significant|novel|breakthrough)"#,
        #"(?i)(until|so that)\s+(p|the p-?value)\s*[<≤]"#,
        #"(?i)(only|just)\s+report\s+(the\s+)?(significant|positive|best)"#,
        #"(?i)(drop|remove|exclude)\s+(outliers|samples|points|replicates)\s+(to|until|so)"#,
        #"(?i)(try|test|run)\s+(several|many|multiple|different)\s+(seeds|tests|thresholds|cutoffs)\s+(and|to)\s+(pick|choose|keep|report)"#,
        #"(?i)\b(be|being)\s+(more\s+)?(lenient|permissive|generous)\b"#,
        #"(?i)(approve|pass)\s+(faster|quickly|by default|without)"#,
        #"(?i)(assume|treat)\s+.{0,30}(as\s+)?(verified|correct|true)\s+(without|unless)"#,
        #"(?i)(cite|use)\s+.{0,30}(without (reading|checking|fetching))"#,
        #"(?i)(fabricat|invent|make up|guess)\w*\s+(data|values|numbers|citations?|references?)"#,
        #"(?i)(synthetic|simulated|mock)\s+data\s+(instead|in place)\s+of"#,
        #"(?i)(hide|suppress|silence|ignore)\s+(errors|warnings|failures|exceptions)"#,
    ]

    public init(dir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/evolution")) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let t = try? String(contentsOf: dir.appendingPathComponent("proposals.jsonl"), encoding: .utf8) {
            proposals = t.split(separator: "\n").compactMap { try? dec.decode(EvolutionProposal.self, from: Data($0.utf8)) }
        }
    }

    func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let lines = proposals.compactMap { try? enc.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        try? lines.joined(separator: "\n").writeReliably(to: dir.appendingPathComponent("proposals.jsonl"))
    }

    /// Step 1 — deterministic screening. Returns the reasons a proposal is rejected outright.
    public static func screen(_ text: String) -> [String] {
        var reasons: [String] = []
        for p in driftPatterns where text.range(of: p, options: .regularExpression) != nil {
            reasons.append("matches an oversight-weakening / unscientific pattern")
            break
        }
        for s in HackDetector.scan(code: text) where s.severity >= 3 { reasons.append(s.detail) }
        return reasons
    }

    func record(_ p: EvolutionProposal) {
        lock.lock()
        if let i = proposals.firstIndex(where: { $0.id == p.id }) { proposals[i] = p } else { proposals.append(p) }
        persist()
        lock.unlock()
    }

    public var pending: [EvolutionProposal] { lock.lock(); defer { lock.unlock() }; return proposals.filter { $0.status == .pending } }

    /// Runs the full gate. Applies the change when accepted (or stages it for the user).
    public func submit(_ draft: EvolutionProposal, services: SessionServices) async -> EvolutionProposal {
        var p = draft
        let screened = Self.screen(p.content)
        if !screened.isEmpty {
            p.status = .rejected
            p.reason = "Rejected by integrity screen: " + screened.joined(separator: "; ")
            return finish(p, services)
        }
        if p.operation != "remove" {
            let valid = p.provenance.filter { services.ledger.receipt($0) != nil || $0.hasPrefix("review:") || $0.hasPrefix("claim:") }
            if valid.isEmpty {
                p.status = .rejected
                p.reason = "Rejected: cite the receipts (r…) or review that this was learned from — learning must be grounded in what actually happened."
                return finish(p, services)
            }
        }
        // Independent evolution review (fresh checker-role agent, strict rubric, no tools needed).
        let verdict = await review(p, services: services)
        if !verdict.approve {
            p.status = .rejected
            p.reason = "Rejected by evolution review: " + verdict.reason
            return finish(p, services)
        }
        if p.role == .checker || p.role == .verifier {
            p.status = .pending
            p.reason = "Passed screening and review; awaiting your approval (reviewer/verifier learning is human-gated). " + verdict.reason
            return finish(p, services)
        }
        return apply(p, services: services, reason: verdict.reason)
    }

    struct Verdict { var approve: Bool; var reason: String }

    func review(_ p: EvolutionProposal, services: SessionServices) async -> Verdict {
        let reviewer = services.makeSubagent(role: .checker, purpose: "Evolution review of a \(p.role.rawValue) \(p.kind.rawValue) proposal (\(p.target))", parent: p.role.rawValue)
        let prompt = """
        <evolution_review>
        An agent (role: \(p.role.rawValue)) proposes to change its long-term \(p.kind.rawValue) (\(p.target), \(p.operation)):
        \"\"\"
        \(p.content.truncated(6000))
        \"\"\"
        Learned from: \(p.provenance.joined(separator: ", "))

        Approve only if ALL hold:
        1. It makes the agent do science better: more rigorous, reproducible, honest, or efficient without cutting corners.
        2. It cannot be read as a way to pass reviews, avoid verification or the grounding gate, obtain significant \
        results, or present work as better than it is. Anything that weakens oversight is rejected.
        3. It is specific and supported by what actually happened (read the cited receipts with `receipt` if needed).
        4. It does not encode a factual claim about science that was not verified against sources.
        Reply with JSON only: {"approve": true|false, "reason": "..."}
        </evolution_review>
        """
        guard let reply = try? await reviewer.send(prompt)?.plainText, let j = Supervisor.parseJSON(reply) else {
            return Verdict(approve: false, reason: "review unavailable — proposal held back")
        }
        return Verdict(approve: j.bool("approve") == true, reason: j.str("reason") ?? "")
    }

    /// Applies an accepted proposal to the role's store or skill directory.
    public func apply(_ draft: EvolutionProposal, services: SessionServices, reason: String) -> EvolutionProposal {
        var p = draft
        do {
            switch p.kind {
            case .memory:
                guard let store = MemoryStore.Store(rawValue: p.target), let op = MemoryStore.Op(rawValue: p.operation) else { throw ToolError.invalidInput("bad target") }
                let mem = services.memory(for: p.role)
                p.previous = mem.entries(store).joined(separator: MemoryStore.separator)
                _ = try mem.apply(op, store: store, text: p.content, match: p.match)
            case .skill:
                let file = SkillRegistry.learnedDir.appendingPathComponent("\(p.target)/SKILL.md")
                p.previous = try? String(contentsOf: file, encoding: .utf8)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try p.content.writeReliably(to: file)
                services.skills.reload()
            }
            p.status = .accepted
            p.reason = "Accepted. " + reason
        } catch {
            p.status = .rejected
            p.reason = "Could not apply: \(error.localizedDescription)"
        }
        return finish(p, services)
    }

    /// User decision on a pending proposal (`/evolution approve|reject <id>`).
    public func decide(_ id: String, approve: Bool, services: SessionServices) -> String {
        guard var p = (lock.locked { proposals.first { $0.id == id } }), p.status == .pending else { return L10n.s("No pending proposal %@.", id) }
        // The record keeps the English reason; the user reads it localized.
        if approve { return L(apply(p, services: services, reason: "Approved by the user.").reason) }
        p.status = .rejected
        p.reason = "Rejected by the user."
        return L(finish(p, services).reason)
    }

    /// Restores the content that an accepted proposal replaced.
    public func revert(_ id: String, services: SessionServices) -> String {
        guard var p = (lock.locked { proposals.first { $0.id == id } }), p.status == .accepted else { return L10n.s("No accepted proposal %@.", id) }
        switch p.kind {
        case .memory:
            if let s = MemoryStore.Store(rawValue: p.target) {
                try? (p.previous ?? "").writeReliably(to: services.memory(for: p.role).url(s))
            }
        case .skill:
            let file = SkillRegistry.learnedDir.appendingPathComponent("\(p.target)/SKILL.md")
            if let prev = p.previous { try? prev.writeReliably(to: file) } else { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            services.skills.reload()
        }
        p.status = .reverted
        p.reason = "Reverted by the user."
        return L(finish(p, services).reason)
    }

    @discardableResult
    func finish(_ p: EvolutionProposal, _ services: SessionServices) -> EvolutionProposal {
        record(p)
        services.log("evolution", actor: p.role.rawValue, ["id": .string(p.id), "kind": .string(p.kind.rawValue), "target": .string(p.target),
                                                           "op": .string(p.operation), "status": .string(p.status.rawValue), "reason": .string(p.reason),
                                                           "content_sha256": .string(Hashing.sha256Hex(p.content)), "provenance": .array(p.provenance.map { .string($0) })])
        services.emit(.notice(L10n.s("Learning %@ (%@ · %@): %@", L(p.status.rawValue), L(p.role.rawValue), p.target, p.reason.truncated(200))))
        return p
    }

    // MARK: Skill outcome tracking (quarantine)

    /// Records that a learned skill was used in a turn and what the supervisor concluded afterwards.
    public func recordSkillOutcome(skill: String, verdict: String) {
        let url = dir.appendingPathComponent("skill-outcomes.json")
        lock.lock(); defer { lock.unlock() }
        var stats = ((try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: [String: Int]].self, from: $0) }) ?? [:]
        stats[skill, default: [:]][verdict, default: 0] += 1
        try? JSONEncoder().encode(stats).write(to: url)
        let s = stats[skill] ?? [:]
        let bad = (s["revise"] ?? 0) + (s["block"] ?? 0) * 2
        let total = s.values.reduce(0, +)
        // Quarantine: at least 4 uses and more than half followed by a revise/block review.
        if total >= 4 && Double(bad) / Double(total) > 0.5 {
            let file = SkillRegistry.learnedDir.appendingPathComponent("\(skill)/SKILL.md")
            let q = SkillRegistry.learnedDir.appendingPathComponent(".quarantine/\(skill)")
            try? FileManager.default.createDirectory(at: q.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: file.deletingLastPathComponent(), to: q)
        }
    }
}

extension NSLock {
    func locked<T>(_ f: () -> T) -> T { lock(); defer { unlock() }; return f() }
}
