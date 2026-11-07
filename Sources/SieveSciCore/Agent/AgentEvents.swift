import Foundation

/// Everything the UI renders, in order. The SwiftUI transcript is a projection of these events.
public enum AgentEvent: Sendable {
    case turnStarted(role: AgentRole, agentId: String)
    case textDelta(agentId: String, String)
    case thinkingDelta(agentId: String, String)
    case toolStarted(agentId: String, id: String, name: String, input: JSON)
    case toolFinished(agentId: String, id: String, name: String, output: String, isError: Bool, receipt: String)
    case assistantMessage(agentId: String, Message)
    case usage(agentId: String, ContextMeter)
    case permissionRequested(PermissionRequest)
    case integrity([IntegritySignal])
    case supervisorStarted(kind: String, reason: String)
    case supervisorReview(kind: String, verdict: String, body: String)
    case planChanged(ResearchPlan)
    case claimsChanged([Claim])
    case notice(String)
    case error(String)
    case turnFinished(agentId: String, stop: StopReason)
    /// A sub-agent was dispatched (checker / verifier / worker), by whom and why.
    case agentStarted(id: String, role: AgentRole, parent: String, purpose: String)
    /// A sub-agent finished; `result` is its final message (verdict, report).
    case agentFinished(id: String, role: AgentRole, result: String)
    /// Literature activity, for the "what was read / checked" views.
    case literature(agentId: String, action: LiteratureAction, key: String, title: String, detail: String)
    /// A file was created or edited by an agent; the diff covers this one edit.
    case fileChanged(agentId: String, path: String, diff: FileDiff)
    /// A shadow-git snapshot was committed after a turn.
    case committed(hash: String, subject: String, files: Int)
    /// Live output of a running tool call (foreground bash), batched lines.
    case toolProgress(agentId: String, id: String, lines: [String])
    /// Live output of a background job, batched lines.
    case jobOutput(job: String, lines: [String])
    case jobFinished(job: String, exitCode: Int32, seconds: Int)
    /// A job event that is delivered to the agent (exit, watched match, stall). The app may also
    /// post a system notification.
    case jobNotification(JobNotification)
    /// One message in a bounded deliberation between agents (question, rebuttal, concession).
    case deliberation(thread: String, from: String, to: String, kind: String, text: String)
    /// A structured question waits for the user (`ask_user`); answer with `AskCenter.resolve`.
    case askRequested(AskRequest)
    /// The question was answered, dismissed, timed out or could not be asked; the card seals.
    case askResolved(id: String, outcome: AskOutcome)
    /// Brainstorming mode started, moved to another stage, was asked to wrap up, or ended.
    case brainstormChanged(BrainstormState)
    /// The idea ledger changed (ideas added, merged, checked, ranked, discarded or promoted).
    case ideasChanged([Idea])
    /// The conversation got a generated title (`TitleSummarizer`); front ends show it in place of the
    /// first question. Never sent for a conversation the user named.
    case titleChanged(task: String, title: String)
    /// A message the user inserted during a turn reached the agent (at its next step, or as the next
    /// turn when the one it was meant for had ended). Front ends show it where it landed.
    case userInserted(agentId: String, text: String)
}

public enum LiteratureAction: String, Sendable {
    case searched, added, read, verified, flagged
}

/// Context-window fill and spend for the Claude-Code-style ring next to the model picker.
public struct ContextMeter: Sendable, Equatable {
    public var model: String
    public var contextWindow: Int
    /// Prompt tokens of the most recent request = how full the window is now.
    public var lastPromptTokens: Int
    public var lastOutputTokens: Int
    public var session: Usage
    /// Session-wide share of prompt tokens served from cache.
    public var cacheHitRate: Double { session.hitRate }
    public var fill: Double { contextWindow > 0 ? min(1, Double(lastPromptTokens) / Double(contextWindow)) : 0 }

    public init(model: String, contextWindow: Int, lastPromptTokens: Int = 0, lastOutputTokens: Int = 0, session: Usage = Usage()) {
        self.model = model
        self.contextWindow = contextWindow
        self.lastPromptTokens = lastPromptTokens
        self.lastOutputTokens = lastOutputTokens
        self.session = session
    }
}

public struct PermissionRequest: Sendable, Identifiable {
    public var id: String
    public var tool: String
    public var summary: String
    public var input: JSON
    public var effect: ToolEffect
    /// Pattern offered for "don't ask again", e.g. `bash(git status:*)`.
    public var rememberPattern: String
}

public enum PermissionDecision: Sendable, Equatable {
    case allowOnce
    case allowAlways
    case deny(String)
}

public enum PermissionMode: String, Codable, Sendable, CaseIterable {
    case ask          // ask before edits and execution
    case acceptEdits  // auto-allow file edits inside the workspace, ask before execution
    case auto         // allow everything not on the deny list; commands always run in the sandbox
    case plan         // read-only: research and planning only
    case yolo         // allow everything not on the deny list, with no sandbox

    /// The modes Shift+Tab cycles through. YOLO is chosen on purpose, never stepped into.
    public static let cycle: [PermissionMode] = [.ask, .acceptEdits, .auto, .plan]
    /// The order the mode menus list them in.
    public static let menu: [PermissionMode] = [.ask, .acceptEdits, .auto, .yolo, .plan]
}
