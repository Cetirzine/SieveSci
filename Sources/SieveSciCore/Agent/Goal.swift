import Foundation

/// `/goal` — one durable objective per session with automatic continuation rounds.
///
/// Semantics follow Reasonix's goal enforcement and DeepSeek Harness's goal packages:
/// - only the human creates, edits, pauses, resumes or clears a goal (`/goal …`);
/// - the model may only mark it `complete` or `blocked` (via the `goal` tool), and `blocked`
///   requires at least 3 rounds so the model cannot bail out on the first obstacle;
/// - while the goal is active and the agent goes idle, the driver starts the next round;
/// - a round never starts while background jobs run (their notification wakes the agent, as in
///   dsh-superagent's worker slots), and a round that does no work, or repeats the previous one,
///   moves the goal to `waiting` until the user replies — rounds are never spent on polling;
/// - the model can hand off with `wait` when it needs the user's decision;
/// - round (default 30) and token budgets turn the goal `blocked` with a reason code when exhausted.
public struct Goal: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case active, waiting, paused, blocked, complete }
    public static let defaultMaxRounds = 30
    public var id: String
    public var objective: String
    public var phase: Phase
    public var maxRounds: Int?
    public var tokenBudget: Int?
    public var roundsStarted: Int
    public var tokensUsed: Int
    public var blockedReason: String?
    public var completionNote: String?
    /// What a `waiting` goal waits for (the model's question, or why the host stopped the rounds).
    public var waitingFor: String?
}

public final class GoalController: @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var current: Goal?

    public init() {}

    // Human operations
    /// `maxRounds` nil = the default cap; 0 = no cap.
    public func create(_ objective: String, maxRounds: Int? = nil, tokenBudget: Int? = nil) -> Goal {
        lock.lock(); defer { lock.unlock() }
        let cap = maxRounds ?? Goal.defaultMaxRounds
        let g = Goal(id: UUID().uuidString, objective: objective, phase: .active, maxRounds: cap > 0 ? cap : nil, tokenBudget: tokenBudget,
                     roundsStarted: 0, tokensUsed: 0, blockedReason: nil, completionNote: nil, waitingFor: nil)
        current = g
        return g
    }
    public func pause() { mutate { $0.phase = .paused } }
    public func resume() { mutate { if $0.phase != .complete { $0.phase = .active; $0.blockedReason = nil; $0.waitingFor = nil } } }
    /// A message from the user answers a waiting goal.
    public func userReplied() { mutate { if $0.phase == .waiting { $0.phase = .active; $0.waitingFor = nil } } }
    /// Host: stop starting rounds until the user replies.
    public func hostWait(_ reason: String) { mutate { if $0.phase == .active { $0.phase = .waiting; $0.waitingFor = reason } } }
    public func clear() { lock.lock(); current = nil; lock.unlock() }

    // Model operations
    public func modelComplete(note: String) -> String {
        lock.lock(); defer { lock.unlock() }
        guard var g = current, g.phase == .active else { return "No active goal." }
        g.phase = .complete
        g.completionNote = note
        current = g
        return "Goal marked complete."
    }

    public func modelWait(question: String) -> String {
        lock.lock(); defer { lock.unlock() }
        guard var g = current, g.phase == .active else { return "No active goal." }
        g.phase = .waiting
        g.waitingFor = question
        current = g
        return "Goal waiting for the user. End your turn now with the question, stated once and concretely."
    }

    public func modelBlocked(reason: String) -> String {
        lock.lock(); defer { lock.unlock() }
        guard var g = current, g.phase == .active else { return "No active goal." }
        guard g.roundsStarted >= 3 else {
            return "Refused: a goal can be marked blocked only after 3 rounds. Try another approach, or explain the obstacle to the user."
        }
        g.phase = .blocked
        g.blockedReason = "model: " + reason
        current = g
        return "Goal marked blocked."
    }

    /// Driver: called when the agent is idle. Returns the continuation prompt for the next round.
    public func nextRound(tokensSoFar: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard var g = current, g.phase == .active else { return nil }
        g.tokensUsed = tokensSoFar
        if let m = g.maxRounds, g.roundsStarted >= m { g.phase = .blocked; g.blockedReason = "round-limit"; current = g; return nil }
        if let b = g.tokenBudget, g.tokensUsed >= b { g.phase = .blocked; g.blockedReason = "resource-budget"; current = g; return nil }
        g.roundsStarted += 1
        current = g
        return """
        <goal_round n="\(g.roundsStarted)">
        Goal: \(g.objective)
        Do the next most valuable step and verify it. Achieved and verified → `goal` complete. Need the user's \
        decision → `ask_user` with concrete options (or `goal` wait with one question). Waiting for a background job → end the turn without \
        polling; its result wakes you. Blocked after several different attempts → `goal` blocked.
        </goal_round>
        """
    }

    private func mutate(_ f: (inout Goal) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if var g = current { f(&g); current = g }
    }
}

/// Turn-level todo list (Claude Code's TodoWrite): distinct from the research plan, which is the
/// durable scientific plan. Todos are the agent's short-term working checklist.
public final class TodoList: @unchecked Sendable {
    public struct Item: Codable, Sendable, Equatable { public var content: String; public var status: String }
    private let lock = NSLock()
    public private(set) var items: [Item] = []
    public init() {}
    public func set(_ i: [Item]) { lock.lock(); items = i; lock.unlock() }
}

