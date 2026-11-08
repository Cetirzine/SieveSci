import Foundation

/// Brainstorming: ideas are speculation, kept apart from hypotheses (registered in the plan) and
/// claims (verified by the blind verifier). After Google's AI co-scientist (generate → review →
/// rank → evolve), Stanford's Virtual Lab (parallel creative meetings merged with attribution),
/// Scideator (facet recombination) and Si et al. (LLM ideas repeat themselves, so deduplicate).
///
/// An idea becomes a hypothesis only through `IdeaLedger.promote`, which the host gates: a novelty
/// verdict backed by searches run after the idea was written, a stated test and falsifier, and an
/// independent checker review.
public struct Idea: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable { case raw, merged, checked, promoted, discarded }
    public enum Novelty: String, Codable, Sendable {
        /// Never "novel": only "no prior work found by these searches".
        case notFound = "not_found_in_search"
        case incremental, known
    }
    /// The check of an idea when the goal is what works best: how well published results back it.
    public enum Support: String, Codable, Sendable {
        /// Reported to work well on comparable problems (benchmarks, wide use).
        case established
        /// Some results, on other problems or with mixed outcomes.
        case partial
        /// No results found that show it works.
        case unproven
    }
    public var id: String
    public var statement: String
    public var mechanism: String
    public var test: String
    public var falsifier: String
    /// The divergence operator that produced it: facet, analogy, invert, seed, verbalized, merge, evolve:<id>, free.
    public var op: String
    public var seeds: [String]
    public var evidence: [String]
    public var status: Status
    /// For `merged`: the idea it duplicates.
    public var mergedInto: String?
    public var novelty: Novelty?
    public var noveltyReceipts: [String]
    public var closestPrior: [String]
    public var rank: Int?
    public var review: String?
    public var reviewFingerprint: String?
    public var hypothesisId: String?
    public var note: String?
    /// session | brainstorm:<id> | dream:<yyyy-mm-dd>
    public var origin: String
    public var createdAt: Date
    /// "proven" when written in a brainstorm after what works best (nil: novelty first).
    public var aim: String?
    /// Its evidence check in such a brainstorm; `closestPrior` then holds the published results and
    /// `noveltyReceipts` the searches.
    public var support: Support?

    public var isLive: Bool { status != .merged && status != .discarded && novelty != .known }
}

/// One brainstorming episode, as the UI shows it: what it is about, who started it, which stage it
/// is in, and how the ideas thin out through the sieve.
public struct BrainstormState: Codable, Sendable, Equatable, Identifiable {
    public enum Trigger: String, Codable, Sendable { case user, auto, dream }
    /// What the ideas are for, settled with the user before the brainstorm: something new (checked for
    /// novelty), or what works best (checked for published evidence that it works, prior work preferred).
    public enum Goal: String, Codable, Sendable { case novel, proven }
    public static let stages = ["ground", "diverge", "dedupe", "rank", "novelty", "review", "evolve", "report"]
    /// The stages when the goal is what works best: an evidence check takes the novelty check's place.
    public static let provenStages = ["ground", "diverge", "dedupe", "rank", "evidence", "review", "evolve", "report"]
    public static let allStages = stages + ["evidence"]
    public var id: String
    public var topic: String
    public var reason: String
    public var trigger: Trigger
    public var stage: String
    public var stageNote: String
    public var stagesDone: [String]
    public var startedAt: Date
    public var endedAt: Date?
    public var summary: String?
    /// The user asked to wrap up with what is there.
    public var wrapUpRequested: Bool
    public var stopped: Bool
    /// Times the brainstorm went from `evolve` back to `dedupe`/`rank` (a second round). Optional so state saved
    /// by earlier versions still decodes.
    public var evolveRounds: Int?
    /// Optional so brainstorms saved by earlier versions (always novelty-first) still decode.
    public var goal: Goal?
    /// A focused brainstorm after a result review that chose to pivot (its id): it builds on what the
    /// review learned and on the task's searches, so it needs fewer ideas and no new grounding round.
    public var afterReview: String? = nil

    /// This brainstorm's stage order.
    public var order: [String] { goal == .proven ? Self.provenStages : Self.stages }

    /// Ideas recorded during this episode carry this origin.
    public var origin: String { (trigger == .dream ? "dream:" : "brainstorm:") + id }
}

public final class IdeaLedger: @unchecked Sendable {
    private let lock = NSLock()
    private let stateURL: URL?
    public private(set) var ideas: [Idea] = []
    public private(set) var current: BrainstormState?
    /// Whether the agent may start brainstorming on its own (a setting; the user can always ask).
    public var autoAllowed = true
    /// Set by `/brainstorm` and `/dream now`: the next `brainstorm start` was asked for.
    var requested: BrainstormState.Trigger?
    private var wrapUpPending = false
    /// Searches an idea needs, after it was written, before its novelty verdict counts.
    public static let minNoveltySearches = 3
    /// Two ideas sharing this much of their vocabulary are the same idea.
    public static let duplicateThreshold = 0.6

    struct Saved: Codable { var ideas: [Idea]; var current: BrainstormState? }

    public init(stateURL: URL? = nil) {
        self.stateURL = stateURL
        if let s = StateFile.load(Saved.self, from: stateURL) {
            ideas = s.ideas
            // A brainstorm cut off by a quit is over.
            current = s.current.map { var c = $0; if c.endedAt == nil { c.endedAt = Date(); c.stopped = true }; return c }
        }
    }

    public var snapshot: [Idea] { lock.withLock { ideas } }
    public var live: BrainstormState? { lock.withLock { current?.endedAt == nil ? current : nil } }

    public func request(_ t: BrainstormState.Trigger) { lock.withLock { requested = t } }
    /// A brainstorm is running or was just asked for (`/brainstorm`, `/dream now`).
    public var isBrainstorming: Bool { lock.withLock { requested != nil || current?.endedAt == nil && current != nil } }

    // MARK: Episodes

    public func start(topic: String, reason: String, goal: BrainstormState.Goal? = nil, afterReview: String? = nil) -> Result<BrainstormState, GateRefusal> {
        lock.lock(); defer { lock.unlock() }
        if let c = current, c.endedAt == nil { return .success(c) }
        // A focused re-brainstorm keeps the earlier brainstorm's goal unless told otherwise.
        let goal = goal ?? (afterReview != nil ? current?.goal : nil)
        let trigger = requested ?? .auto
        if trigger == .auto && !autoAllowed {
            return .failure(GateRefusal("Autonomous brainstorming is turned off in the user's settings. Continue without it; "
                + "suggest /brainstorm in your reply if new ideas would help."))
        }
        // Whether the ideas must be new is the user's decision; an unattended dream looks for new ones.
        guard let goal = goal ?? (trigger == .dream ? .novel : nil) else {
            return .failure(GateRefusal("First settle what the ideas are for. Unless the user already said, ask once with `ask_user` "
                + "(kind single, reason user_decision): is novelty required, or does what works best matter most — methods others "
                + "have used with good results preferred, the field's best answers combined? Then `brainstorm` start with goal novel or proven."))
        }
        requested = nil
        wrapUpPending = false
        let s = BrainstormState(id: "B" + String(UUID().uuidString.prefix(6)).lowercased(), topic: topic, reason: reason, trigger: trigger,
                                stage: "ground", stageNote: "", stagesDone: [], startedAt: Date(), endedAt: nil, summary: nil,
                                wrapUpRequested: false, stopped: false, goal: goal)
        var focused = s
        focused.afterReview = afterReview
        current = focused
        persist()
        return .success(focused)
    }

    public func stage(_ name: String, note: String) -> BrainstormState? {
        lock.lock(); defer { lock.unlock() }
        guard var c = current, c.endedAt == nil else { return nil }
        if c.stage != name, !c.stagesDone.contains(c.stage) { c.stagesDone.append(c.stage) }
        if c.stage == "evolve", name == "dedupe" || name == "rank" { c.evolveRounds = (c.evolveRounds ?? 0) + 1 }
        c.stage = name
        c.stageNote = note
        current = c
        persist()
        return c
    }

    public func end(summary: String, stopped: Bool = false) -> BrainstormState? {
        lock.lock(); defer { lock.unlock() }
        guard var c = current, c.endedAt == nil else { return nil }
        if !c.stagesDone.contains(c.stage) { c.stagesDone.append(c.stage) }
        c.endedAt = Date()
        c.summary = summary
        c.stopped = stopped
        current = c
        wrapUpPending = false
        persist()
        return c
    }

    /// The user pressed "wrap up": the agent is told at its next step.
    public func requestWrapUp() -> BrainstormState? {
        lock.lock(); defer { lock.unlock() }
        guard var c = current, c.endedAt == nil, !c.wrapUpRequested else { return nil }
        c.wrapUpRequested = true
        current = c
        wrapUpPending = true
        persist()
        return c
    }

    /// The wrap-up note, delivered once with the next tool results.
    func drainWrapUp() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard wrapUpPending else { return nil }
        wrapUpPending = false
        return "<brainstorm_wrap_up>The user asked you to wrap up the brainstorm now: generate no more ideas and start no new batches. "
            + "Finish only the checks already running, then report the best ideas so far (marked as speculation, with what was and was not checked) "
            + "and call `brainstorm` end.</brainstorm_wrap_up>"
    }


    // MARK: The brainstorming procedure (enforced, not advisory)

    /// Live ideas a brainstorm needs before it may converge (the skill asks for 12–24; this is the floor).
    public static let minIdeasToConverge = 6
    /// A focused re-brainstorm after a review: fewer, targeted ideas (the earlier pool is still there).
    public static let minIdeasFocused = 4
    /// Evolve → rank rounds allowed after the first pass.
    public static let maxEvolveRounds = 2
    /// Stages that may be passed over on the way to `report`.
    static let optionalStages: Set<String> = ["review", "evolve"]

    /// Tools the main agent may not call while a brainstorm is live. Brainstorming is a closed phase that
    /// comes before the plan: it searches, reads, writes ideas down and checks them. Planning, workers,
    /// analysis, files and findings come after `brainstorm` end, built on the ideas the user chose.
    public static let closedDuringBrainstorm: Set<String> =
        Set(["update_plan", "task", "dispatch", "claim_finding"]).union(ResearchProtocol.gatedBeforePlan)

    /// Why `tool` may not run now, or nil. Read-only shell stays open, as it does before a plan.
    public func brainstormBlocker(tool: String, input: JSON) -> String? {
        guard let b = live, Self.closedDuringBrainstorm.contains(tool) else { return nil }
        if tool == "bash", let cmd = input.str("command") ?? input.str("cmd"), ResearchProtocol.isReadOnlyShell(cmd) { return nil }
        let what: String
        switch tool {
        case "update_plan": what = "Planning"
        case "task", "dispatch": what = "Handing work to workers"
        case "claim_finding": what = "Claiming a finding"
        default: what = "Running analyses and writing files"
        }
        return "\(what) is not part of brainstorming (\(b.id), stage \(b.stage)). The order is fixed: brainstorm (ground → diverge → "
            + "dedupe → rank → novelty → [review → evolve] → report) → the user chooses → `brainstorm` end → `idea` promote the chosen "
            + "ideas → `update_plan` → work, with workers if useful. Write what this would have checked into the idea's `test` instead, "
            + "and continue with stage \(b.stage)."
    }

    /// What the agent must do before entering `next`, or nil when the move is allowed.
    /// `grounded`: the grounding searches the session requires have succeeded.
    public func stageBlocker(_ next: String, grounded: Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let c = current, c.endedAt == nil else { return nil }
        let order = c.order
        guard let to = order.firstIndex(of: next) else {
            return c.goal == .proven
                ? "This brainstorm is after what works best: its check is stage evidence (published results that the idea works), not novelty."
                : "This brainstorm is after new ideas: its check is stage novelty, not evidence."
        }
        guard let from = order.firstIndex(of: c.stage) else { return nil }
        if to == from { return nil }
        let mine = ideas.filter { $0.origin == c.origin }
        let live = mine.filter(\.isLive)
        let checked = mine.filter { c.goal == .proven ? $0.support != nil : $0.novelty != nil }
        let needChecked = min(3, max(1, mine.filter { $0.status != .merged && $0.status != .discarded || $0.novelty != nil }.count))
        if c.wrapUpRequested && next == "report" { return nil }
        if to < from {
            guard c.stage == "evolve", ["dedupe", "rank"].contains(next) else {
                return "Stages run forward (\(order.joined(separator: " → "))). The only way back is evolve → dedupe or rank for another round."
            }
            if (c.evolveRounds ?? 0) >= Self.maxEvolveRounds { return "\(Self.maxEvolveRounds) evolve rounds are done; go to report." }
            return nil
        }
        // Forward: one stage at a time; only review and evolve may be passed over.
        let skipped = order[(from + 1)..<to].filter { !Self.optionalStages.contains($0) }
        if let first = skipped.first { return "Stage \(first) comes before \(next). Enter \(first) first and do it." }
        // Leaving a stage requires its work.
        for st in order[from..<to] {
            switch st {
            case "ground" where !grounded:
                return "Grounding is not done: run `web_search` and `literature_search`, fetch the papers that matter and write the evidence brief before generating ideas."
            case "diverge" where live.count < (c.afterReview == nil ? Self.minIdeasToConverge : Self.minIdeasFocused):
                return c.afterReview == nil
                    ? "Only \(live.count) live ideas recorded in this brainstorm; diverge needs at least \(Self.minIdeasToConverge) (aim for 12–24) "
                        + "from several operators, recorded with `idea` add."
                    : "Only \(live.count) live ideas in this focused brainstorm; it needs at least \(Self.minIdeasFocused), each built on what review "
                        + "\(c.afterReview!) learned (invert the assumption that failed; transfer from an analogous system)."
            case "rank" where !live.contains(where: { $0.rank != nil }):
                return "Rank the live ideas yourself (compare them pairwise on grounding, mechanistic specificity and testability) and record the order with `idea` rank."
            case "novelty" where checked.count < needChecked:
                return "Novelty-check the top \(needChecked) ranked ideas (≥\(Self.minNoveltySearches) searches each, then `idea` novelty); \(checked.count) done."
            case "evidence" where checked.count < needChecked:
                return "Check the evidence for the top \(needChecked) ranked ideas (≥\(Self.minNoveltySearches) searches each for published results, "
                    + "then `idea` evidence); \(checked.count) done."
            default: continue
            }
        }
        return nil
    }

    /// Whether an `idea` action fits the current stage of a live brainstorm (always, outside one).
    public func ideaActionBlocker(_ action: String) -> String? {
        guard let c = live else { return nil }
        switch action {
        case "add" where !["diverge", "evolve"].contains(c.stage):
            return "Ideas are recorded in the diverge stage (or as evolved versions in evolve); the brainstorm is in \(c.stage)."
        case "rank" where c.stage != "rank":
            return "Ranking happens in the rank stage; the brainstorm is in \(c.stage). Enter it with `brainstorm` stage first."
        case "novelty" where c.goal == .proven:
            return "This brainstorm is after what works best: record `idea` evidence (published results that it works), not novelty."
        case "evidence" where c.goal != .proven:
            return "This brainstorm is after new ideas: record `idea` novelty."
        case "novelty" where !["novelty", "review", "evolve"].contains(c.stage) && !c.wrapUpRequested,
             "evidence" where !["evidence", "review", "evolve"].contains(c.stage) && !c.wrapUpRequested:
            return "Verdicts are recorded from the \(action) stage on; the brainstorm is in \(c.stage)."
        case "promote":
            return "An idea is promoted after the brainstorm: report, let the user choose with `ask_user`, call `brainstorm` end, then promote what they chose."
        default:
            return nil
        }
    }

    // MARK: Ideas

    /// Adds ideas; near-duplicates of a live idea are recorded as `merged` into it.
    public func add(_ new: [Idea]) -> [Idea] {
        lock.lock(); defer { lock.unlock() }
        var added: [Idea] = []
        for var idea in new {
            idea.id = "I\(ideas.count + 1)"
            let words = Self.terms(idea.statement + " " + idea.mechanism)
            if let dup = ideas.first(where: { $0.status != .merged && $0.status != .discarded
                && Self.similarity(words, Self.terms($0.statement + " " + $0.mechanism)) >= Self.duplicateThreshold }) {
                idea.status = .merged
                idea.mergedInto = dup.id
            }
            ideas.append(idea)
            added.append(idea)
        }
        persist()
        return added
    }

    public func discard(_ id: String, reason: String) -> Idea? {
        mutate(id) { $0.status = .discarded; $0.note = reason }
    }

    public func setRanks(_ order: [String]) {
        lock.lock(); defer { lock.unlock() }
        for (i, id) in order.enumerated() { if let k = ideas.firstIndex(where: { $0.id == id }) { ideas[k].rank = i + 1 } }
        persist()
    }

    /// Successful searches run since an idea was written, oldest first: what a novelty or evidence verdict
    /// may rest on. `extra` admits more tools (`bio_db` for evidence).
    func searchesSince(_ idea: Idea, ledger: EvidenceLedger, extra: Set<String> = []) -> [String] {
        let tools = ResearchProtocol.webSearchTools.union(ResearchProtocol.literatureTools).union(extra)
        return ledger.all.filter { $0.success && tools.contains($0.tool) && $0.startedAt >= idea.createdAt.addingTimeInterval(-1) }.map(\.id)
    }

    /// The searches a verdict rests on: the cited ones that qualify, or — none cited — every qualifying
    /// search the host saw since the idea was written. (A model that left `receipts` out was refused 47
    /// times in a row with "Valid so far: none" while it kept searching.) The checker reads them at promotion.
    func qualifying(_ cited: [String], since idea: Idea, ledger: EvidenceLedger, extra: Set<String> = []) -> (valid: [String], seen: [String]) {
        let seen = searchesSince(idea, ledger: ledger, extra: extra)
        return (cited.isEmpty ? seen : cited.filter(seen.contains), seen)
    }

    static func notEnough(_ kind: String, _ id: String, valid: [String], seen: [String], what: String) -> String {
        "A \(kind) verdict needs at least \(minNoveltySearches) successful searches (\(what)) run after \(id) was written, cited in `receipts`. "
            + "Valid so far: \(valid.isEmpty ? "none" : valid.joined(separator: ", ")). "
            + (seen.isEmpty ? "No search has succeeded since \(id) was written: search first, then record the verdict."
               : "Searches since \(id) was written: \(seen.suffix(12).joined(separator: ", ")) (\(seen.count)) — cite those that are about \(id), or search more.")
    }

    /// Records a novelty verdict. The searches must exist, have succeeded, and postdate the idea.
    public func setNovelty(_ id: String, _ verdict: Idea.Novelty, prior: [String], receipts: [String], ledger: EvidenceLedger) -> Result<Idea, GateRefusal> {
        guard let idea = snapshot.first(where: { $0.id == id }) else { return .failure(GateRefusal("No idea \(id).")) }
        let (valid, seen) = qualifying(receipts, since: idea, ledger: ledger)
        if verdict != .known && valid.count < Self.minNoveltySearches {
            return .failure(GateRefusal(Self.notEnough("novelty", id, valid: valid, seen: seen, what: "web_search, literature_search, paper_graph …")
                + " Search synonyms, the mechanism, the method and the organism, read the closest papers, then record the verdict."))
        }
        if verdict == .incremental && prior.isEmpty || verdict == .known && prior.isEmpty {
            return .failure(GateRefusal("Name the prior work ([@key] or a URL) that makes \(id) \(verdict.rawValue)."))
        }
        guard let out = mutate(id, { i in
            i.novelty = verdict
            i.noveltyReceipts = valid
            i.closestPrior = prior
            if i.status == .raw { i.status = .checked }
            if verdict == .known { i.status = .discarded; i.note = "already published" }
        }) else { return .failure(GateRefusal("No idea \(id).")) }
        return .success(out)
    }

    /// Records how well published results support an idea (a brainstorm after what works best). The searches
    /// must have succeeded and postdate the idea; established or partial support names the results.
    public func setSupport(_ id: String, _ verdict: Idea.Support, results: [String], receipts: [String], ledger: EvidenceLedger) -> Result<Idea, GateRefusal> {
        guard let idea = snapshot.first(where: { $0.id == id }) else { return .failure(GateRefusal("No idea \(id).")) }
        let (valid, seen) = qualifying(receipts, since: idea, ledger: ledger, extra: ["bio_db"])
        if valid.count < Self.minNoveltySearches {
            return .failure(GateRefusal(Self.notEnough("evidence", id, valid: valid, seen: seen, what: "benchmarks, reviews, comparisons, leaderboards")))
        }
        if verdict != .unproven && results.isEmpty {
            return .failure(GateRefusal("Name the published results ([@key] or a URL, with the reported numbers) that support \(id)."))
        }
        guard let out = mutate(id, { i in
            i.support = verdict
            i.noveltyReceipts = valid
            i.closestPrior = results
            if i.status == .raw { i.status = .checked }
        }) else { return .failure(GateRefusal("No idea \(id).")) }
        return .success(out)
    }

    /// What must hold before an idea may become a hypothesis (the review comes on top).
    public func promotionBlocker(_ id: String) -> String? {
        guard let i = snapshot.first(where: { $0.id == id }) else { return "No idea \(id)." }
        if i.status == .promoted { return "\(id) is already hypothesis \(i.hypothesisId ?? "?")." }
        if i.status == .merged { return "\(id) duplicates \(i.mergedInto ?? "another idea"); promote that one." }
        if i.status == .discarded { return "\(id) was discarded (\(i.note ?? ""))." }
        if i.aim == "proven" {
            // After what works best: published results must back it; prior work is what is wanted.
            guard let s = i.support else {
                return "\(id) has no evidence check yet: search for published results (at least \(Self.minNoveltySearches) searches) and record `idea` evidence."
            }
            if s == .unproven { return "No published results show that \(id) works; choose a better-supported idea, or brainstorm for new ideas instead." }
            if i.test.trimmingCharacters(in: .whitespaces).isEmpty || i.falsifier.trimmingCharacters(in: .whitespaces).isEmpty {
                return "\(id) needs a concrete test and a falsifier (the result that would show it does not work here) before it can be registered."
            }
            return nil
        }
        guard let n = i.novelty else {
            return "\(id) has no novelty check yet: search for prior work (at least \(Self.minNoveltySearches) searches) and record it with `idea` action novelty."
        }
        if n == .known { return "\(id) is already published." }
        if i.test.trimmingCharacters(in: .whitespaces).isEmpty || i.falsifier.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(id) needs a concrete test and a falsifier (what result would refute it) before it can be registered."
        }
        return nil
    }

    public func setReview(_ id: String, verdict: String, fingerprint: String) {
        _ = mutate(id) { $0.review = verdict; $0.reviewFingerprint = fingerprint }
    }

    public func markPromoted(_ id: String, hypothesis: String) -> Idea? {
        mutate(id) { $0.status = .promoted; $0.hypothesisId = hypothesis }
    }

    @discardableResult
    func mutate(_ id: String, _ f: (inout Idea) -> Void) -> Idea? {
        lock.lock(); defer { lock.unlock() }
        guard let k = ideas.firstIndex(where: { $0.id == id }) else { return nil }
        f(&ideas[k])
        persist()
        return ideas[k]
    }

    private func persist() { StateFile.save(Saved(ideas: ideas, current: current), to: stateURL) }

    // MARK: Similarity (cheap and language-agnostic: words, plus character bigrams for CJK)

    static let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "into", "are", "was", "via", "its", "their",
                                    "which", "can", "may", "will", "not", "but", "has", "have", "been", "more", "less", "than", "by", "of", "in", "on", "to", "a", "an", "is", "be", "as", "or", "at"]

    static func terms(_ s: String) -> Set<String> {
        var out: Set<String> = []
        var word = ""
        var cjk: [Character] = []
        func flushWord() { let w = word.lowercased(); if w.count >= 3, !stop.contains(w) { out.insert(w) }; word = "" }
        func flushCJK() {
            if cjk.count == 1 { out.insert(String(cjk)) }
            if cjk.count >= 2 { for i in 0..<(cjk.count - 1) { out.insert(String(cjk[i...i + 1])) } }
            cjk = []
        }
        for ch in s {
            if ch.unicodeScalars.first.map({ (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }) == true {
                flushWord(); cjk.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushCJK(); word.append(ch)
            } else {
                flushWord(); flushCJK()
            }
        }
        flushWord(); flushCJK()
        return out
    }

    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}

public struct GateRefusal: Error, Sendable { public let message: String; public init(_ m: String) { message = m } }

/// Seeds for divergent thinking. Not random tokens: concepts drawn from controlled sources (the task
/// library's own vocabulary, a curated cross-domain list), with a recorded RNG seed so a run can be
/// replayed. A seed is a provocation; whatever it suggests still has to be searched.
public enum IdeationSeeds {
    /// Mechanisms and design patterns from many fields, for forced association and analogy.
    public static let crossDomain: [String] = [
        "negative feedback loop", "positive feedback / bistability", "phase separation", "percolation threshold", "allostery",
        "kinetic proofreading", "error-correcting codes", "redundancy and degeneracy", "modularity", "scale-free networks",
        "quorum sensing", "public goods dilemma", "predator–prey oscillation", "niche construction", "island biogeography",
        "evolutionary arms race", "bet hedging", "division of labour", "self-assembly", "templating",
        "catalytic cycle", "autocatalysis", "chirality transfer", "host–guest recognition", "metal–organic frameworks",
        "click chemistry", "photoswitching", "mechanochemistry", "flow chemistry", "directed evolution",
        "compartmentalisation", "gradient sensing", "temporal coding", "adaptation / desensitisation", "hysteresis",
        "load balancing", "caching", "garbage collection", "backpressure", "consensus protocols",
        "supply chains / bottlenecks", "inventory buffers", "auction mechanisms", "insurance / risk pooling", "market makers",
        "lock-and-key", "induced fit", "conformational selection", "lever and fulcrum", "springs and dampers",
        "resonance", "impedance matching", "signal-to-noise / averaging", "stochastic resonance", "sparsity",
        "dimensionality reduction", "transfer learning", "adversarial examples", "active learning", "curriculum",
        "origami folding", "tensegrity", "porous media transport", "capillarity", "biofilms",
        "symbiosis", "horizontal gene transfer", "genetic drift", "founder effect", "epistasis",
        "circadian timing", "dormancy", "regeneration", "senescence", "immune memory",
        "decoys and sinks", "sequestration", "prodrugs / latent activation", "targeted degradation", "molecular glues",
        "barcoding", "lineage tracing", "pooled screens", "multiplexing", "single-molecule counting",
        "inverse problems", "tomography", "interferometry", "time-resolved snapshots", "perturbation–response mapping",
    ]

    /// Distinctive words from the library's titles and abstracts (frequent but not ubiquitous).
    public static func libraryTerms(_ records: [PaperRecord]) -> [String] {
        var df: [String: Int] = [:]
        for r in records {
            for t in IdeaLedger.terms(r.title + " " + (r.abstract ?? "")) where t.count >= 5 || t.unicodeScalars.contains(where: { $0.value >= 0x3400 }) {
                df[t, default: 0] += 1
            }
        }
        let n = max(records.count, 1)
        return df.filter { $0.value >= 1 && Double($0.value) / Double(n) < 0.5 }
            .sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(200).map(\.key)
    }

    /// Library papers sharing the least vocabulary with the topic: distant material for analogy.
    public static func farPapers(_ records: [PaperRecord], topic: String, k: Int) -> [PaperRecord] {
        let t = IdeaLedger.terms(topic)
        return records.map { ($0, IdeaLedger.similarity(t, IdeaLedger.terms($0.title + " " + ($0.abstract ?? "")))) }
            .sorted { $0.1 < $1.1 }.prefix(k).map(\.0)
    }

    /// SplitMix64: small, seedable and the same on every platform.
    public struct RNG: RandomNumberGenerator {
        var state: UInt64
        public init(seed: UInt64) { state = seed }
        public mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    public static func sample<T>(_ pool: [T], k: Int, rng: inout RNG) -> [T] {
        var p = pool
        p.shuffle(using: &rng)
        return Array(p.prefix(k))
    }
}

/// Ideas from background dreaming, kept per workspace until the user has seen them.
public enum DreamInbox {
    public struct Entry: Codable, Sendable, Equatable {
        public var task: String
        public var idea: Idea
        public var seen: Bool
    }
    static func url(_ ws: URL) -> URL { ws.appendingPathComponent(".sievesci/dreams/inbox.json") }
    static let lock = NSLock()

    public static func load(_ ws: URL) -> [Entry] { StateFile.load([Entry].self, from: url(ws)) ?? [] }
    public static func unseen(_ ws: URL) -> [Entry] { load(ws).filter { !$0.seen } }

    public static func add(_ ideas: [Idea], task: String, workspace ws: URL) {
        lock.withLock {
            var all = load(ws)
            all += ideas.map { Entry(task: task, idea: $0, seen: false) }
            StateFile.save(Array(all.suffix(200)), to: url(ws))
        }
    }

    public static func markSeen(_ ws: URL) {
        lock.withLock {
            var all = load(ws)
            for i in all.indices { all[i].seen = true }
            StateFile.save(all, to: url(ws))
        }
    }

    /// The dream diary for people: what was looked at, what came out, and what was checked.
    public static func writeDiary(_ s: BrainstormState, ideas: [Idea], workspace ws: URL) -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let file = ws.appendingPathComponent(".sievesci/dreams/\(f.string(from: s.startedAt)).md")
        var md = "# Dream \(f.string(from: s.startedAt)) — \(s.topic)\n\n"
        md += "Ideas below are speculation. None has been tested or verified.\n\n"
        if let sum = s.summary, !sum.isEmpty { md += sum + "\n\n" }
        for i in ideas {
            md += "## \(i.id) \(i.statement)\n\n"
            if !i.mechanism.isEmpty { md += "- Mechanism: \(i.mechanism)\n" }
            if !i.test.isEmpty { md += "- Test: \(i.test)\n" }
            if !i.falsifier.isEmpty { md += "- Would be refuted by: \(i.falsifier)\n" }
            md += "- Operator: \(i.op)" + (i.seeds.isEmpty ? "" : " · seeds: \(i.seeds.joined(separator: ", "))") + "\n"
            md += "- Novelty: \(i.novelty?.rawValue ?? "not checked")" + (i.closestPrior.isEmpty ? "" : " · closest: \(i.closestPrior.joined(separator: ", "))") + "\n"
            if !i.evidence.isEmpty { md += "- Evidence: \(i.evidence.joined(separator: ", "))\n" }
            md += "\n"
        }
        let prior = (try? String(contentsOf: file, encoding: .utf8)).map { $0 + "\n---\n\n" } ?? ""
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (prior + md).writeReliably(to: file)
        return file
    }
}

/// The background "dream": consolidate open threads across the workspace's tasks and brainstorm a
/// few grounded ideas, read-only. Runs headless in plan mode (`/dream on` schedules it).
public enum DreamProtocol {
    public static let schedulePrompt = "/dream now"
    public static let prompt = """
    <dream>
    This is a background dreaming run: no user is present, the workspace is read-only, and nothing you produce \
    here is a result. Work in three phases and keep it short.
    1. Light — gather open threads: use `session_search` and `session_read` on recent tasks in this workspace for \
    unanswered questions, refuted or inconclusive claims, contested points and recurring checker issues; note new \
    papers in the library (`library_search`).
    2. REM — call `brainstorm` start (topic: the open thread worth most), then generate 5–10 ideas linking those \
    threads, using `ideation_seeds` with the facet and analogy operators; every idea states mechanism, test and \
    falsifier and cites what it builds on. Record them with `idea` add.
    3. Deep — deduplicate, rank the survivors, run a light novelty check on the top 3 (3 searches each, recorded with \
    `idea` novelty), then `brainstorm` end with a two-line summary.
    Do not register hypotheses, claims or plans, and do not edit memory: the user decides tomorrow.
    </dream>
    """
}
