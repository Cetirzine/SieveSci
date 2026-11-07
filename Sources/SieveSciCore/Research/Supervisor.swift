import Foundation

/// Decides when to spend tokens on oversight, and runs it.
///
/// Signals are cheap and deterministic (regex scans, receipt checks, grounding checks). Only these
/// dispatch a model-backed review:
/// - a checkpoint step was marked done           → checker reviews it against its criteria
/// - a claim was registered / strong-claim words → blind verifier re-implements the analysis
/// - high-severity signals (fabricated citation, unsupported numbers, success over a failed run,
///   error-hiding code, synthetic data, HARKing, ungrounded conclusions) → checker
/// Reviews are deduplicated by signal fingerprint and capped per session (`SupervisorPolicy`).
public final class Supervisor: @unchecked Sendable {
    let services: SessionServices
    private let lock = NSLock()
    private var pending: [IntegritySignal] = []
    private var reviewed: Set<String> = []
    private var reviewCount = 0
    private var receiptMark = 0
    private var passedCheckpoints: [String] = []

    init(services: SessionServices) { self.services = services }

    func add(_ s: [IntegritySignal]) {
        guard !s.isEmpty else { return }
        lock.lock(); pending += s; lock.unlock()
        services.emit(.integrity(s))
        services.log("integrity_signal", actor: "host", ["signals": .array(s.map { sig in
            ["kind": .string(sig.kind.rawValue), "severity": .int(sig.severity), "detail": .string(sig.detail), "location": .string(sig.location ?? "")]
        })])
    }

    // MARK: Hooks from the loop

    func afterTool(use: ToolUse, output: ToolOutput, receipt: Receipt) async {
        var code: String?
        var location: String?
        switch use.name {
        case "python": code = use.input.str("code")
        case "bash": code = use.input.str("command")
        case "write_file", "edit_file":
            code = use.input.str("content") ?? use.input.str("new_string")
            location = use.input.str("path")
            if let p = location, HackDetector.isTestTampering(path: p) {
                add([IntegritySignal(kind: .codeHack, severity: 2, detail: "edited a test/fixture file \(p)", location: p)])
            }
        default: break
        }
        if let code {
            // Off the tool's path (the result goes back at once; signals follow) and bounded in size.
            let loc = location ?? receipt.id
            let text = code.count > 200_000 ? String(code.prefix(200_000)) : code
            Task.detached(priority: .utility) { [weak self] in self?.add(HackDetector.scan(code: text, location: loc)) }
        }
        if let rev = output.facts["plan_revision"], rev["after_results"]?.boolValue == true {
            add([IntegritySignal(kind: .harking, severity: 3, detail: "success criteria changed after results existed: \(rev["changed"]?.canonical ?? "")",
                                 location: receipt.id)])
        }
    }

    /// Runs after the model ends a turn. Returns a message to append (and continue the loop), or nil.
    func endOfTurn(final: Message) async -> String? {
        let text = final.plainText
        let recent: [Receipt] = lock.withLock {
            let r = services.ledger.since(receiptMark)
            receiptMark = services.ledger.count
            return r
        }

        // A chat reply (a greeting, "what can you do?") is not research output: nothing to review.
        let scale = services.research.turnScale
        if scale == .chat { return nil }
        var signals = NarrativeDetector.scan(text: text, recentReceipts: recent)
        let grounding = Grounding.check(text: text, library: services.library, evidenceCorpus: services.ledger.corpus())
        if !grounding.isClean {
            signals.append(IntegritySignal(kind: .ungrounded, severity: grounding.unresolvedCitations.isEmpty && grounding.unretrievedIdentifiers.isEmpty ? 2 : 3,
                                           detail: grounding.summary, location: nil))
        }
        let g = services.research.hasGrounding()
        let substantive = text.count > 600 || grounding.citationCount > 0
        if services.research.groundingRequired && scale == .research && substantive && !(g.web && g.literature) {
            signals.append(IntegritySignal(kind: .ungrounded, severity: 3,
                                           detail: "substantive answer given before web and literature searches were run", location: nil))
        }
        // A report that leaves out what did not work: the task has reviews, the reply reads like a report,
        // and none of the reviewed items or a failure is mentioned. Selective reporting is cheating too.
        let reviews = services.research.reviews
        if !reviews.isEmpty, text.count > 1500 {
            let lower = text.lowercased()
            let mentions = reviews.contains { !$0.subject.isEmpty && text.contains($0.subject) }
                || ["did not work", "didn't work", "failed", "negative", "refuted", "inconclusive", "未成功", "失败", "没有成功", "否定", "不成立", "负结果"]
                    .contains { lower.contains($0) }
            if !mentions {
                signals.append(IntegritySignal(kind: .omission, severity: 3,
                    detail: "the report does not mention the results that went against the plan (\(reviews.map(\.id).joined(separator: ", ")))", location: nil))
            }
        }
        add(signals)

        lock.lock()
        let all = pending
        pending = []
        lock.unlock()

        // Breakthrough language → every pending claim must go through the verifier (it does, in
        // claim_finding); here we ask for the claim to be registered if none covers the text.
        if all.contains(where: { $0.kind == .breakthrough }),
           !services.claims.snapshot.contains(where: { $0.status == .verified }) {
            return """
            <supervisor_review kind="claim-required">
            Your reply uses strong-claim language (significant / novel / breakthrough / proves). Before stating it as a \
            conclusion, register it with `claim_finding` (statement, pre-stated success criteria, evidence receipts, raw \
            data paths) so an independent verifier can test it. Until then, describe it as a preliminary observation.
            </supervisor_review>
            """
        }

        let serious = all.filter { $0.severity >= services.supervisorPolicy.minSeverity && $0.kind != .breakthrough && $0.kind != .checkpoint }
        guard !serious.isEmpty else { return nil }
        return await review(kind: "integrity", signals: serious, focus: text)
    }

    // MARK: Reviews

    // MARK: Getting a verdict (or honestly reporting that there is none)

    struct VerdictOutcome {
        var reply: String
        var json: JSON?
        /// Set when no verdict could be obtained; already recorded and emitted.
        var unavailable: String?
    }

    /// Runs a reviewer and insists on a parsable verdict. A decline, failure or unusable reply is
    /// classified and recorded; the host retries once with a different (preferably different-vendor)
    /// reviewer, and if that also fails it escalates. It never rewrites the request to get a
    /// different safety decision, and never treats a missing review as approval.
    func obtainVerdict(_ agent: AgentSession, role: AgentRole, purpose: String, prompt: String) async -> VerdictOutcome {
        var tried: Set<String> = []
        var lastEvent: RefusalEvent?
        var retriedWith: String?
        for attempt in 0..<2 {
            tried.insert(agent.provider.profile.id + "/" + agent.model)
            var reply = ""
            var kindDetail: (RefusalKind, String)?
            do {
                let msg = try await agent.send(prompt)
                reply = msg?.plainText ?? ""
                let j = Self.parseJSON(reply)
                kindDetail = Refusals.classify(reply: reply, stop: nil, hasVerdict: j?.str("verdict") != nil)
                if kindDetail == nil { return VerdictOutcome(reply: reply, json: j, unavailable: nil) }
            } catch {
                kindDetail = Refusals.classify(error: error)
            }
            guard let (kind, detail) = kindDetail else { break }
            let event = RefusalEvent(kind: kind, role: role.rawValue, purpose: purpose, detail: detail,
                                     model: agent.provider.profile.id + "/" + agent.model, at: Date())
            services.refusals.record(event)
            lastEvent = event
            services.log("review_unavailable", actor: "host", [
                "kind": .string(kind.rawValue), "role": .string(role.rawValue), "purpose": .string(purpose),
                "detail": .string(detail.truncated(2000)), "model": .string(event.model), "attempt": .int(attempt + 1),
                "reply_excerpt": .string(reply.truncated(800)),
            ])
            // One retry, on a different reviewer where one exists.
            if attempt == 0, let alt = services.models.alternate(for: role, excluding: tried) {
                agent.useModel(alt.0, alt.1)
                retriedWith = alt.0.profile.displayName + " / " + alt.1
                services.emit(.notice(Refusals.userNotice(event, retriedWith: retriedWith, escalated: false)))
                continue
            }
            break
        }
        guard let e = lastEvent else { return VerdictOutcome(reply: "", json: nil, unavailable: "review unavailable") }
        let note = Refusals.notice(e, retriedWith: retriedWith, escalated: true)
        let shown = Refusals.userNotice(e, retriedWith: retriedWith, escalated: true)
        services.emit(.notice(shown))
        services.emit(.supervisorReview(kind: purpose, verdict: "unavailable", body: shown))
        if services.refusals.streak(kind: e.kind, role: e.role) >= 2 {
            services.emit(.notice(L10n.s("Two reviews in a row could not be obtained from the %@ (%@). Review coverage is broken: choose another reviewer model in Settings → Models, or decide to proceed without independent review (recorded as such).",
                                         L(e.role), e.kind.rawValue)))
        }
        return VerdictOutcome(reply: e.detail, json: nil, unavailable: note)
    }

    func canReview(_ fingerprint: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard reviewCount < services.supervisorPolicy.maxReviewsPerSession, !reviewed.contains(fingerprint) else { return false }
        reviewed.insert(fingerprint)
        reviewCount += 1
        return true
    }

    /// Dispatches the checker and returns its review as a message for the main agent.
    public func review(kind: String, signals: [IntegritySignal], focus: String, step: PlanStep? = nil) async -> String? {
        let fp = (kind + signals.map { $0.kind.rawValue + $0.detail }.sorted().joined() + (step?.id ?? "")).stableHash
        guard canReview(fp) else { return nil }
        services.emit(.supervisorStarted(kind: kind, reason: signals.map(\.detail).joined(separator: "; ")))

        var dossier = "<review_request kind=\"\(kind)\">\n"
        if let step {
            dossier += "Checkpoint \(step.id): \(step.title)\nAcceptance criteria: \(step.criteria)\nCited receipts: \(step.evidence.joined(separator: ", "))\nAgent's note: \(step.note)\n\n"
        }
        if !signals.isEmpty {
            dossier += "Host-detected signals:\n" + signals.map { "- [\($0.kind.rawValue), sev \($0.severity)] \($0.detail)\($0.location.map { " @ \($0)" } ?? "")" }.joined(separator: "\n") + "\n\n"
        }
        dossier += "Research plan:\n\(services.research.snapshot.markdown)\n"
        let receipts = services.ledger.all.suffix(25)
        dossier += "Recent receipts (id · tool · ok · args):\n" + receipts.map { "\($0.id) · \($0.tool) · \($0.success ? "ok" : "FAILED") · \($0.argsSummary.prefix(160))" }.joined(separator: "\n")
        dossier += "\n\nText under review:\n\"\"\"\n\(focus.truncated(12_000))\n\"\"\"\n"
        dossier += "Use `receipt` to read any receipt's full output, and `read_file`/`grep` for code. Then answer with the JSON verdict.\n</review_request>"

        let purpose = step.map { "Review checkpoint \($0.id): \($0.title)" } ?? "Review (\(kind)): " + signals.map(\.detail).joined(separator: "; ").truncated(160)
        let checker = services.makeSubagent(role: .checker, purpose: purpose)
        let outcome = await obtainVerdict(checker, role: .checker, purpose: purpose, prompt: dossier)
        if let unavailable = outcome.unavailable {
            // No review was obtained. Nothing is approved; the main agent must report it as such.
            return """
            <supervisor_review kind="\(kind)" verdict="unavailable">
            \(unavailable)
            </supervisor_review>
            """
        }
        let reply = outcome.reply
        let verdict = outcome.json
        let v = verdict?.str("verdict") ?? "revise"
        services.log("supervisor_review", actor: "checker", ["kind": .string(kind), "verdict": .string(v), "review": verdict ?? .string(reply.truncated(8000)),
                                                             "step": .string(step?.id ?? ""), "checker_agent": .string(checker.id)])
        services.emit(.supervisorReview(kind: kind, verdict: v, body: reply))
        learn(fromReview: verdict, verdict: v, kind: kind, step: step)
        // The reviewer's view of the route (checkpoints): a pivot or stop, or a block, asks for a result review.
        let direction = verdict?.str("direction") ?? "continue"
        let directionLine = direction == "continue" ? "" : "Reviewer's direction: \(direction) — \(verdict?.str("direction_reason") ?? "")"
        if kind == "checkpoint", ["pivot", "stop"].contains(direction) {
            services.research.requestReview(trigger: "the reviewer suggests \(direction) after \(step?.id ?? "the checkpoint")", subject: step?.id ?? "")
        } else if kind == "checkpoint", v == "block" {
            services.research.requestReview(trigger: "the reviewer blocked \(step?.id ?? "the checkpoint")", subject: step?.id ?? "")
        }
        if v == "pass" {
            return directionLine.isEmpty ? nil : "<supervisor_review kind=\"\(kind)\" verdict=\"pass\">\n\(directionLine)\n</supervisor_review>"
        }
        let rawIssues = verdict?["issues"]?.arrayValue ?? []
        let issueTexts = rawIssues.map { "[\($0.str("severity") ?? "?")] \($0.str("what") ?? "") (\($0.str("evidence") ?? ""))" }
        let questions = (verdict?["questions"]?.arrayValue ?? []).compactMap(\.stringValue)
        let actions = (verdict?["required_actions"]?.arrayValue ?? []).compactMap(\.stringValue).map { "- \($0)" }
        // The checker session stays alive as the other side of a bounded deliberation thread.
        let tid = services.deliberation.open(kind: kind, reviewer: checker, issues: issueTexts + questions.map { "Question: " + $0 })
        let numbered = (issueTexts + questions.map { "Question: " + $0 }).enumerated().map { "\($0.offset + 1). \($0.element)" }
        return """
        <supervisor_review id="\(tid)" kind="\(kind)" verdict="\(v)">
        \(numbered.isEmpty ? reply.truncated(4000) : "Issues:\n" + numbered.joined(separator: "\n"))
        \(actions.isEmpty ? "" : "Required actions:\n" + actions.joined(separator: "\n"))
        \(directionLine)
        \(v == "block" ? "Do not continue the analysis or state conclusions until these are resolved." : "")
        \(services.deliberation.instructions(tid))
        </supervisor_review>
        """
    }

    /// Checkpoint review, run synchronously from `update_plan` so its verdict is the tool result.
    public func reviewCheckpoint(_ step: PlanStep) async -> String {
        let text = step.evidence.compactMap { services.ledger.receipt($0).map { "[\($0.id)] \($0.outputExcerpt)" } }.joined(separator: "\n\n")
        let r = await review(kind: "checkpoint", signals: [IntegritySignal(kind: .checkpoint, severity: 2, detail: "checkpoint \(step.id) reached", location: nil)],
                             focus: text, step: step)
        guard let r else { return "Checkpoint \(step.id) passed independent review." }
        if r.contains("verdict=\"unavailable\"") {
            return "Checkpoint \(step.id) is NOT reviewed — no independent verdict could be obtained.\n" + r
        }
        return r
    }

    /// Blind verification of a claim: the verifier works in its own sandbox and cannot read files
    /// the main agent wrote (except the declared raw data).
    public func verify(_ claim: Claim) async -> String {
        guard services.supervisorPolicy.verifyClaims, canReview("verify" + claim.id) else {
            return "Verification skipped (disabled or review budget exhausted); claim \(claim.id) remains unverified."
        }
        services.claims.hostSet(claim.id, status: .verifying, verdict: nil)
        services.emit(.claimsChanged(services.claims.snapshot))
        services.emit(.supervisorStarted(kind: "verification", reason: claim.statement))
        let sandbox = services.taskDir.appendingPathComponent("verify/\(claim.id)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let data = Set(claim.dataPaths.compactMap { try? toolPath($0) })
        let blinded = services.filesWritten(by: .main).filter { !data.contains($0) }
        // Inside the workspace the verifier reads only its sandbox and the declared raw data — not
        // the main agent's scripts, notebooks, outputs, receipts or the audit log (which records the
        // main agent's code). Its own code runs under a sandbox that enforces the same.
        let verifier = services.makeSubagent(role: .verifier, writeRoot: sandbox, blinded: blinded, readable: [sandbox.path] + data.sorted(),
                                             purpose: "Blind re-implementation of \(claim.id): \(claim.statement.truncated(140))")
        let enforced = verifier.toolContext.blindingEnforced
        let blindNote = enforced ? "" : "\nBlinding was advisory only: this platform has no sandbox, so code the verifier ran could have read the main agent's files."
        let brief = """
        <claim id="\(claim.id)">
        Statement: \(claim.statement)
        Pre-stated success criteria: \(claim.successCriteria)
        Raw data you may use (absolute paths; open them directly, do not search for them):
        \(data.sorted().map { "  " + $0 }.joined(separator: "\n"))
        Your sandbox (write all code and outputs here): \(sandbox.path)
        Everything else in the workspace is hidden from you; if a file the analysis needs is not listed, report that instead of guessing.
        </claim>
        Re-implement the analysis independently and test the claim. Search the literature if the method needs it.
        """
        let mark = services.ledger.count
        let outcome = await obtainVerdict(verifier, role: .verifier, purpose: "Verify \(claim.id)", prompt: brief)
        if let unavailable = outcome.unavailable {
            services.claims.hostSet(claim.id, status: .inconclusive, verdict: "not verified — " + unavailable.truncated(1200))
            services.emit(.claimsChanged(services.claims.snapshot))
            return """
            <verification_report claim="\(claim.id)" verdict="unavailable">
            \(unavailable)
            Claim \(claim.id) is NOT verified. Report it as an unverified preliminary observation, with the reason \
            verification could not be obtained, and leave the decision to the user.
            </verification_report>
            """
        }
        let reply = outcome.reply
        let j = outcome.json
        let verdict = j?.str("verdict") ?? "inconclusive"
        let status: Claim.Status = verdict == "verified" ? .verified : (verdict == "refuted" ? .refuted : .inconclusive)
        let vReceipts = services.ledger.since(mark).filter { $0.role == .verifier }.map(\.id)
        services.claims.hostSet(claim.id, status: status, verdict: (j?.str("reasoning") ?? reply.truncated(2000)) + blindNote, receipts: vReceipts)
        // A claim that did not hold up is a result to look back at before going on.
        if status != .verified { services.research.requestReview(trigger: "claim \(claim.id) \(verdict)", subject: claim.id) }
        services.emit(.claimsChanged(services.claims.snapshot))
        services.log("verification", actor: "verifier", ["claim": .string(claim.id), "verdict": .string(verdict), "blinding_enforced": .bool(enforced),
                                                         "report": j ?? .string(reply.truncated(8000)), "receipts": .array(vReceipts.map { .string($0) })])
        services.emit(.supervisorReview(kind: "verification", verdict: verdict, body: reply))
        calibrate(after: claim, verdict: verdict, reasoning: j?.str("reasoning") ?? "")
        let tid = services.deliberation.open(kind: "verification", reviewer: verifier,
                                             issues: ["Verifier verdict \(verdict): " + (j?.str("reasoning") ?? reply).truncated(600)], claimId: claim.id)
        return """
        <verification_report id="\(tid)" claim="\(claim.id)" verdict="\(verdict)">
        \(j.map { JSONCodec.pretty($0) } ?? reply.truncated(6000))\(blindNote)
        \(status == .verified ? "" : services.deliberation.instructions(tid))
        </verification_report>
        \(status == .verified ? "" : "This claim is \(verdict). Do not state it as a conclusion; report it as \(verdict) with the verifier's reasoning.")
        """
    }

    // MARK: Learning signals (host-side, deterministic; see EvolutionGovernor for the rules)

    /// High-severity checker findings become lessons for the main agent; learned skills used this
    /// session get an outcome record (repeated revise/block → quarantine).
    func learn(fromReview j: JSON?, verdict: String, kind: String, step: PlanStep?) {
        for issue in j?["issues"]?.arrayValue ?? [] where issue.str("severity") == "high" {
            if let what = issue.str("what") { services.memory(for: .main).recordLesson("Checker (\(kind)) caught: \(what)") }
        }
        let usedSkills = Set(services.ledger.all.filter { $0.tool == "skill" && $0.success }
            .compactMap { r in Grounding.matches(#"<skill name=\"([^\"]+)\""#, in: services.ledger.output(r.id) ?? "", group: 1).first })
        for s in usedSkills where services.skills.skill(s)?.source == "learned" {
            services.governor.recordSkillOutcome(skill: s, verdict: verdict)
        }
        if kind == "checkpoint", verdict == "pass", let step { lock.lock(); passedCheckpoints.append(step.id); lock.unlock() }
    }

    /// Calibration: if the verifier refutes a claim after the checker passed checkpoints in this
    /// task, the checker learns that its review missed something — the direction of learning is
    /// always toward catching more, never toward passing more.
    func calibrate(after claim: Claim, verdict: String, reasoning: String) {
        guard verdict == "refuted" else { return }
        lock.lock(); let passed = passedCheckpoints; lock.unlock()
        if !passed.isEmpty {
            services.memory(for: .checker).recordLesson("Passed checkpoint(s) \(passed.joined(separator: ", ")) but the verifier refuted claim “\(claim.statement.truncated(140))”: \(reasoning.truncated(160))")
        }
        services.memory(for: .main).recordLesson("Claim refuted by independent verification: “\(claim.statement.truncated(140))” — \(reasoning.truncated(160))")
    }

    func toolPath(_ p: String) throws -> String {
        let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : services.workspace.appendingPathComponent(p)
        return url.standardizedFileURL.path
    }

    /// Extracts the last top-level JSON object from a model reply (tolerates code fences / prose).
    static func parseJSON(_ s: String) -> JSON? {
        var depth = 0
        var start: String.Index?
        var last: Substring?
        var inString = false
        var escape = false
        for i in s.indices {
            let c = s[i]
            if inString {
                if escape { escape = false } else if c == "\\" { escape = true } else if c == "\"" { inString = false }
                continue
            }
            if c == "\"" { inString = true }
            else if c == "{" { if depth == 0 { start = i }; depth += 1 }
            else if c == "}" && depth > 0 {
                depth -= 1
                if depth == 0, let st = start { last = s[st...i] }
            }
        }
        return last.flatMap { try? JSONCodec.parse(String($0)) }
    }
}
