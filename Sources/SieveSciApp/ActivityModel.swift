import Foundation
import SieveSciCore

// MARK: - Activity model

/// One tool call as the UI shows it, with live output while it runs.
struct ToolCallView: Equatable {
    var id: String
    var name: String
    var summary: String
    var input: JSON
    var output = ""
    var isError = false
    var receipt: String?
    var started = Date()
    var ended: Date?
    var live: [String] = []
    var diff: FileDiff?
    var running: Bool { ended == nil }
}

/// A dispatched agent (checker, verifier, worker) and what it did.
struct AgentCard: Equatable {
    var id: String
    var role: AgentRole
    var parent: String
    var purpose: String
    var started = Date()
    var ended: Date?
    var result: String?
}

struct TranscriptItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(String, attachments: [String])
        case assistant(String)
        case thinking(String, started: Date, ended: Date?)
        case tool(ToolCallView)
        case agent(String)                                    // card id; contents live in `streams[id]`
        case review(kind: String, verdict: String, body: String)
        case deliberation(thread: String, from: String, to: String, kind: String, text: String)
        case literature(action: LiteratureAction, key: String, title: String, detail: String)
        case fileChange(path: String, diff: FileDiff)
        case commit(hash: String, subject: String, files: Int)
        case job(JobNotification)
        case signal(String)
        case notice(String)
        case error(String)
    }
    let id: String
    var kind: Kind
    var at = Date()

    /// Plain text for search and copy.
    var searchableText: String {
        switch kind {
        case .user(let t, _), .assistant(let t), .notice(let t), .error(let t), .signal(let t): return t
        case .thinking(let t, _, _): return t
        case .tool(let c): return c.name + " " + c.summary + " " + c.output
        case .review(let k, let v, let b): return k + " " + v + " " + b
        case .deliberation(_, let f, let to, let k, let t): return f + " " + to + " " + k + " " + t
        case .literature(_, let k, let t, let d): return k + " " + t + " " + d
        case .fileChange(let p, _): return p
        case .commit(let h, let s, _): return h + " " + s
        case .job(let n): return n.text
        case .agent: return ""
        }
    }
}

/// Live state of a background job for the Jobs panel.
struct JobState: Identifiable, Equatable {
    var id: String
    var label: String
    var lines: [String] = []
    var running = true
    var exitCode: Int32?
    var seconds: Int?
    var unread = 0
}

struct LiteratureEvent: Identifiable, Equatable {
    let id = UUID()
    var agent: String
    var action: LiteratureAction
    var key: String
    var title: String
    var detail: String
    var at = Date()
}


/// Main-area views: the conversation, or a research view shown full width.
enum MainTab: Hashable {
    case chat
    case panel(InspectorTab)

    static let all: [MainTab] = [.chat] + InspectorTab.allCases.filter(\.inMain).map { .panel($0) }

    var title: String {
        switch self {
        case .chat: return L("Chat")
        case .panel(.activity): return L("Trace")
        case .panel(let t): return t.title
        }
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case activity, plan, claims, library, changes, files, figures, jobs, history, notebook, learning
    var id: String { rawValue }
    /// Reading-heavy research views open as main-area tabs; workspace tools stay in the side panel.
    var inMain: Bool { [.activity, .plan, .claims, .library, .notebook].contains(self) }
    static var side: [InspectorTab] { allCases.filter { !$0.inMain } }

    var title: String {
        switch self {
        case .activity: return L("Activity")
        case .plan: return L("Plan")
        case .claims: return L("Claims")
        case .library: return L("Library")
        case .changes: return L("Changes")
        case .files: return L("Files")
        case .figures: return L("Figures")
        case .jobs: return L("Jobs")
        case .history: return L("History")
        case .notebook: return L("Notebook")
        case .learning: return L("Learning")
        }
    }
    var icon: String {
        switch self {
        case .activity: return "waveform.path.ecg"
        case .plan: return "list.bullet.clipboard"
        case .claims: return "checkmark.seal"
        case .library: return "books.vertical"
        case .changes: return "plusminus"
        case .files: return "folder"
        case .figures: return "photo.on.rectangle"
        case .jobs: return "terminal"
        case .history: return "clock.arrow.circlepath"
        case .notebook: return "book.closed"
        case .learning: return "brain"
        }
    }
}
