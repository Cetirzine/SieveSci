import Foundation

/// Structured questions to the user (`ask_user`): single choice, multiple choice and fill-in, each
/// choice question with an automatic "Other" answer. After Claude Code's AskUserQuestion and
/// Reasonix's `ask` tool (decision barrier, distinct results for dismissed / timed out / no user).
///
/// The core owns the whole exchange: the tool suspends on `AskCenter.ask`, the host emits
/// `.askRequested`, and any front end (SwiftUI, terminal, a future web UI) renders the request and
/// calls `AskCenter.answer`. Everything is Codable with stable snake_case keys, so a web front end
/// can render the same JSON.
public struct AskOption: Codable, Sendable, Equatable {
    public var label: String
    public var description: String?
    /// The agent's recommendation (at most one per question; shown first).
    public var recommended: Bool
    /// Library keys (`@key`) or receipt ids (`r12`) the option rests on.
    public var evidence: [String]
    /// The idea this option came from (`I7`), when it came from brainstorming.
    public var idea: String?

    public init(label: String, description: String? = nil, recommended: Bool = false, evidence: [String] = [], idea: String? = nil) {
        self.label = label; self.description = description; self.recommended = recommended; self.evidence = evidence; self.idea = idea
    }
}

public struct AskQuestion: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case single, multi, text }
    /// Why only the user can answer. `direction`: research directions found by searching and
    /// brainstorming; asking those requires the grounding searches first.
    public enum Reason: String, Codable, Sendable { case userDecision = "user_decision", missingValue = "missing_value", direction }
    public var id: String
    public var header: String
    public var question: String
    public var kind: Kind
    public var reason: Reason
    public var options: [AskOption]
    /// Choice questions get an "Other" answer with a text field (added by the front end).
    public var allowOther: Bool
    public var placeholder: String?
    /// May be left unanswered; an unanswered question never counts as a default.
    public var optional: Bool

    public init(id: String, header: String, question: String, kind: Kind, reason: Reason = .userDecision, options: [AskOption] = [],
                allowOther: Bool = true, placeholder: String? = nil, optional: Bool = false) {
        self.id = id; self.header = header; self.question = question; self.kind = kind; self.reason = reason
        self.options = options; self.allowOther = allowOther; self.placeholder = placeholder; self.optional = optional
    }

    enum CodingKeys: String, CodingKey {
        case id, header, question, kind, reason, options, placeholder, optional
        case allowOther = "allow_other"
    }
}

public struct AskRequest: Codable, Sendable, Equatable, Identifiable {
    /// The tool-use id of the `ask_user` call.
    public var id: String
    public var agentId: String
    public var questions: [AskQuestion]
    public var createdAt: Date

    public init(id: String, agentId: String, questions: [AskQuestion], createdAt: Date = Date()) {
        self.id = id; self.agentId = agentId; self.questions = questions; self.createdAt = createdAt
    }

    /// One line for the sidebar and notifications.
    public var summary: String { questions.map { $0.header.isEmpty ? $0.question : $0.header }.joined(separator: " · ") }

    enum CodingKeys: String, CodingKey {
        case id, questions
        case agentId = "agent_id"
        case createdAt = "created_at"
    }
}

public struct AskAnswer: Codable, Sendable, Equatable {
    public var questionId: String
    /// Chosen option labels.
    public var selected: [String]
    /// Text typed into "Other".
    public var other: String?
    /// The answer to a fill-in question.
    public var text: String?

    public init(questionId: String, selected: [String] = [], other: String? = nil, text: String? = nil) {
        self.questionId = questionId; self.selected = selected; self.other = other; self.text = text
    }

    public var isEmpty: Bool {
        selected.isEmpty && (other ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case selected, other, text
        case questionId = "question_id"
    }
}

public enum AskOutcome: Codable, Sendable, Equatable {
    /// Answers to some or all questions (unanswered ones are absent).
    case answered([AskAnswer])
    /// The user closed the card ("don't decide for me, let's talk"), optionally with a message.
    case dismissed(String?)
    case timedOut(Int)
    /// No interactive user (headless or scheduled run).
    case unavailable

    public var label: String {
        switch self {
        case .answered: return "answered"
        case .dismissed: return "dismissed"
        case .timedOut: return "timed_out"
        case .unavailable: return "unavailable"
        }
    }
}

public enum AskFormat {
    /// Validates and normalises the tool input.
    public static func parse(_ input: JSON) throws -> [AskQuestion] {
        let raw = input["questions"]?.arrayValue ?? []
        guard (1...4).contains(raw.count) else { throw ToolError.invalidInput("Ask 1 to 4 questions at once.") }
        var out: [AskQuestion] = []
        var ids: Set<String> = []
        for (i, q) in raw.enumerated() {
            let n = i + 1
            let question = (q.str("question") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { throw ToolError.invalidInput("Question \(n) has no text.") }
            let kind = AskQuestion.Kind(rawValue: q.str("kind") ?? (q["multi_select"]?.boolValue == true ? "multi" : "single")) ?? .single
            let reason = AskQuestion.Reason(rawValue: q.str("reason") ?? "") ?? .userDecision
            var id = (q.str("id") ?? "").trimmingCharacters(in: .whitespaces)
            if id.isEmpty || ids.contains(id) { id = "q\(n)" }
            ids.insert(id)
            var header = (q.str("header") ?? "").trimmingCharacters(in: .whitespaces)
            if header.isEmpty { header = String(question.prefix(12)) }
            if header.count > 16 { header = String(header.prefix(16)) }
            var options: [AskOption] = []
            var labels: Set<String> = []
            for (j, o) in (q["options"]?.arrayValue ?? []).enumerated() {
                let label = (o.str("label") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { throw ToolError.invalidInput("Question \(n) option \(j + 1) has no label.") }
                guard !labels.contains(label) else { throw ToolError.invalidInput("Question \(n) repeats the option “\(label)”.") }
                guard !Self.isOther(label) else { continue }   // the front end adds "Other" itself
                labels.insert(label)
                options.append(AskOption(label: label, description: o.str("description").flatMap { $0.isEmpty ? nil : $0 },
                                         recommended: o["recommended"]?.boolValue ?? false,
                                         evidence: o["evidence"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                         idea: o.str("idea").flatMap { $0.isEmpty ? nil : $0 }))
            }
            if kind == .text {
                options = []
            } else {
                guard (2...5).contains(options.count) else { throw ToolError.invalidInput("Question \(n): a choice question needs 2 to 5 options (\"Other\" is added automatically).") }
                // At most one recommendation, and it goes first.
                if let r = options.firstIndex(where: \.recommended) {
                    for k in options.indices where k != r { options[k].recommended = false }
                    options.insert(options.remove(at: r), at: 0)
                }
            }
            out.append(AskQuestion(id: id, header: header, question: question, kind: kind, reason: reason, options: options,
                                   allowOther: kind == .text ? false : (q["allow_other"]?.boolValue ?? true),
                                   placeholder: q.str("placeholder").flatMap { $0.isEmpty ? nil : $0 },
                                   optional: q["optional"]?.boolValue ?? false))
        }
        return out
    }

    static func isOther(_ label: String) -> Bool {
        ["other", "others", "其他", "其它", "其他（请填写）", "autre", "otro", "другое"].contains(label.lowercased())
    }

    /// The model-facing tool result.
    public static func result(_ req: AskRequest, _ outcome: AskOutcome) -> String {
        switch outcome {
        case .answered(let answers):
            let by = Dictionary(answers.map { ($0.questionId, $0) }, uniquingKeysWith: { a, _ in a })
            let any = req.questions.contains { !(by[$0.id]?.isEmpty ?? true) }
            guard any else { return result(req, .dismissed(nil)) }
            var lines = ["<ask_answer id=\"\(req.id)\">", "The user answered:"]
            for q in req.questions {
                let label = q.header.isEmpty ? q.question : q.header
                guard let a = by[q.id], !a.isEmpty else {
                    lines.append("- \(label): (left unanswered — do not assume a choice)")
                    continue
                }
                var parts: [String] = a.selected
                if let o = a.other?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty { parts.append("other: \"\(o)\"") }
                if let t = a.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { parts.append("\"\(t)\"") }
                lines.append("- \(label): \(parts.joined(separator: "; "))")
            }
            lines.append("These are the user's decisions; cite this receipt when the plan follows them.")
            lines.append("</ask_answer>")
            return lines.joined(separator: "\n")
        case .dismissed(let note):
            let said = (note?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            return "<ask_answer id=\"\(req.id)\" outcome=\"dismissed\">The user closed the question without choosing — read this as "
                + "\"don't decide for me, let's talk\"." + (said.map { " They wrote: \"\($0)\"" } ?? "")
                + " Do not pick an option or act on any of them; reply briefly and wait for the user's next message.</ask_answer>"
        case .timedOut(let s):
            return "<ask_answer id=\"\(req.id)\" outcome=\"timed_out\">No answer within \(s) seconds. That is a timeout, not a preference: "
                + "no option was chosen. Do only what the task allows without this decision, state the assumption you proceed under, "
                + "and say which decision is still missing.</ask_answer>"
        case .unavailable:
            return "<ask_answer id=\"\(req.id)\" outcome=\"unavailable\">This run has no interactive user, and the answer is theirs to give. "
                + "Do not choose for them. Do what the task allows without this decision, then list the missing decisions in your reply.</ask_answer>"
        }
    }

    /// The same answer as a user message, for a question whose waiting call was lost (the app quit
    /// while it waited): the answer then arrives as the next user turn.
    public static func lateAnswerMessage(_ req: AskRequest, _ outcome: AskOutcome) -> String {
        "Answer to your earlier question (the session restarted while it waited):\n" + result(req, outcome)
    }
}

/// Owns pending questions: one card at a time, the waiting call's continuation, and the copy on disk
/// (`state/asks.json`) that lets a question survive an app restart.
public final class AskCenter: @unchecked Sendable {
    private let lock = NSLock()
    private let stateURL: URL?
    private var waiting: [String: CheckedContinuation<AskOutcome, Never>] = [:]
    /// Questions waiting for an answer, oldest first (the front end shows the first).
    public private(set) var pending: [AskRequest] = []
    /// Whether a person can answer. Headless runs leave it false and get `.unavailable`.
    public var interactive = false
    /// Seconds before an unanswered question is skipped; nil = wait indefinitely.
    public var timeout: Int?
    /// Questions asked before the first plan, capped so asking never replaces work.
    public private(set) var askedBeforePlan = 0
    public static let maxBeforePlan = 3

    public init(stateURL: URL? = nil) {
        self.stateURL = stateURL
        pending = StateFile.load([AskRequest].self, from: stateURL) ?? []
    }

    public var first: AskRequest? { lock.withLock { pending.first } }

    func noteAskedBeforePlan() { lock.withLock { askedBeforePlan += 1 } }

    /// Suspends until the user answers (or the timeout passes). `emit` announces the card.
    func ask(_ req: AskRequest, emit: @Sendable (AgentEvent) -> Void) async -> AskOutcome {
        guard interactive else { return .unavailable }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<AskOutcome, Never>) in
                if Task.isCancelled { c.resume(returning: .dismissed(nil)); return }
                lock.withLock {
                    waiting[req.id] = c
                    pending.append(req)
                    persist()
                }
                emit(.askRequested(req))
                if let t = timeout, t > 0 {
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(t) * 1_000_000_000)
                        _ = self?.resolve(req.id, .timedOut(t))
                    }
                }
            }
        } onCancel: { [weak self] in
            _ = self?.resolve(req.id, .dismissed(nil))
        }
    }

    /// Delivers an answer. Returns the request and whether a call was waiting for it (false for a
    /// question left over from an earlier run: its answer must then be sent as a message).
    @discardableResult
    public func resolve(_ id: String, _ outcome: AskOutcome) -> (request: AskRequest, live: Bool)? {
        let (req, c): (AskRequest?, CheckedContinuation<AskOutcome, Never>?) = lock.withLock {
            guard let i = pending.firstIndex(where: { $0.id == id }) else { return (nil, nil) }
            let r = pending.remove(at: i)
            persist()
            return (r, waiting.removeValue(forKey: id))
        }
        guard let req else { return nil }
        c?.resume(returning: outcome)
        return (req, c != nil)
    }

    /// Drops questions from an earlier run nobody can answer any more (e.g. on /clear).
    public func clearStale() {
        lock.withLock {
            pending.removeAll { waiting[$0.id] == nil }
            persist()
        }
    }

    private func persist() { StateFile.save(pending, to: stateURL) }
}
