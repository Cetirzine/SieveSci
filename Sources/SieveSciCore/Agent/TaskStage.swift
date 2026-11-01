import Foundation

/// What a task is waiting for, after dsh-superagent's Ticket stages: the rows are checked top to
/// bottom and the first match wins, so every task has exactly one stage. A person stage cannot go on
/// without the user; the sidebar lists those first, and only those raise a notification. Healthy
/// stages take no extra space.
public enum TaskStage: Equatable, Sendable {
    /// A question waits for the user: a permission ask, the goal's question, or a disagreement between
    /// agents that did not settle.
    case answer(String)
    /// A plan waits for approval (plan mode is read-only until then).
    case review
    /// The last turn failed, or the goal is blocked; a new message from the user releases it.
    case blocked(String)
    case working
    /// Idle while background jobs run; their notification wakes the agent.
    case waitingForJobs(Int)
    case idle

    public var needsPerson: Bool {
        switch self {
        case .answer, .review, .blocked: return true
        default: return false
        }
    }

    /// Stages the sidebar labels; a working task shows its live badge instead, an idle one its date.
    public var showsChip: Bool {
        if case .waitingForJobs = self { return true }
        return needsPerson
    }

    /// Short label that says whom the task waits for and what it needs.
    public var label: String {
        switch self {
        case .answer: return L("Needs your answer")
        case .review: return L("Plan to approve")
        case .blocked: return L("Blocked")
        case .working: return L("Working")
        case .waitingForJobs: return L("Waiting for jobs")
        case .idle: return ""
        }
    }

    public var detail: String {
        switch self {
        case .answer(let s), .blocked(let s): return s
        case .review: return L("Approve the plan or leave plan mode to continue.")
        case .waitingForJobs(let n): return L10n.s("%@ background job(s) running; the agent continues when one reports.", String(n))
        case .working, .idle: return ""
        }
    }

    public struct Facts: Sendable {
        public var permissionAsk: String?
        public var goal: Goal?
        public var planMode = false
        public var planHasSteps = false
        public var contested: String?
        public var lastError: String?
        public var running = false
        public var runningJobs = 0
        public init() {}
    }

    public static func of(_ f: Facts) -> TaskStage {
        if let ask = f.permissionAsk { return .answer(ask) }
        if let g = f.goal, g.phase == .waiting { return .answer(g.waitingFor ?? g.objective) }
        if f.running { return .working }
        if f.planMode && f.planHasSteps { return .review }
        if let g = f.goal, g.phase == .blocked { return .blocked(g.blockedReason ?? g.objective) }
        if let e = f.lastError { return .blocked(e) }
        if let c = f.contested { return .answer(c) }
        if f.runningJobs > 0 { return .waitingForJobs(f.runningJobs) }
        return .idle
    }
}
