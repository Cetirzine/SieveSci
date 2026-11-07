import Foundation

/// What to do after a result that went against the plan, from the least to the most change.
///
/// The ladder follows the references studied for 0.3.0: AIDE bounds debugging (`max_debug_depth` 3)
/// before it drafts something new; AI Scientist v2 gives each stage a budget and ends a stage that
/// found no working implementation with an explicit failure instead of carrying on; Reflexion turns a
/// failure into a diagnosis plus a new high-level plan that the next attempt reads; adaptive clinical
/// trials allow changing course only by rules written down before the interim results.
public enum ReviewDecision: String, Codable, Sendable, CaseIterable {
    /// A bug, a broken environment, a wrong path: fix it and run again. The plan stays as it is.
    case repair
    /// Same objective and hypothesis, another method, parameter or data source: a plan revision.
    case adjust
    /// This route cannot reach the objective: take the next idea, or brainstorm again from what was learned.
    case pivot
    /// The negative result answers the question: report it, with why.
    case stop
    /// The way forward changes the objective, the scope or the cost: the user decides.
    case ask
}

/// A structured look back at a result that went against the plan, recorded before the work goes on.
public struct ResultReview: Codable, Sendable, Equatable, Identifiable {
    public var id: String              // RV1, RV2, …
    public var at: Date
    /// What prompted it (the host's words: "S3 failed", "H1 marked refuted", "three failed runs in a row").
    public var trigger: String
    /// The plan item it concerns (H1, S3, C2), or "".
    public var subject: String
    public var expected: String
    public var observed: String
    /// Possible explanations, most likely first (a bug, the data, an assumption, the hypothesis itself).
    public var causes: [String]
    /// How the leading explanation was, or will be, told apart from the others.
    public var check: String
    public var decision: ReviewDecision
    /// The decision is the one written down in advance (`on_negative` / `on_failure`), so it is not a deviation.
    public var followsRule: Bool
    /// How the decision still serves the task's objective.
    public var servesObjective: String
    /// The new high-level plan for what comes next.
    public var next: String
    public var receipts: [String]
    /// For a pivot: the idea taken next (an id from the idea pool), or "brainstorm".
    public var alternative: String?
}

/// A review the host is waiting for.
public struct PendingReview: Codable, Sendable, Equatable {
    public var trigger: String
    public var subject: String
}
