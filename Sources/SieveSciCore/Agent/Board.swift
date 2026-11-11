import Foundation

/// The task's shared board: what the agents of one task have established, in a form the next agent
/// can pick up.
///
/// Every worker starts with an empty context, and so does every reviewer; the main agent used to
/// re-brief each of them in the prompt ("the previous worker already did …"), and a reviewer found
/// earlier results by searching the workspace. The board is the record that outlives a single agent
/// (after sapper-v2's fact graph, MIT: "sessions die, the graph survives, successors read the graph
/// and take over"), in its three layers: an index of titles that every new agent reads, a summary
/// per entry, and the evidence (receipts, files) behind it, opened only when needed — so one agent's
/// conclusion can be checked rather than believed, and reading the board costs little context.
///
/// Entries are written by the host at the moments results become stable (a worker's report, a
/// checkpoint's verdict, a claim's verification, the end of a research turn) and by the agents
/// themselves (`board` post). The file is append-only (`state/board.jsonl`). A blind verifier never
/// reads it: it holds the main agent's results.
public final class SharedBoard: @unchecked Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Something established, with the receipts or files that show it.
        case fact
        /// Where a piece of work stands for whoever continues it: done, not done, what is next.
        case handoff
        /// A reviewer's verdict on a checkpoint.
        case review
        /// Something that did not work, and why.
        case deadEnd = "dead_end"
        /// An open question or a risk someone should look at.
        case open
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var kind: Kind
        public var title: String
        public var summary: String
        public var evidence: [String]
        public var files: [String]
        public var author: String
        public var at: Date
    }

    private let url: URL
    private let lock = NSLock()
    private var entries: [Entry] = []
    public var onPost: (@Sendable (Entry) -> Void)?

    public init(url: URL) {
        self.url = url
        entries = Self.load(url)
    }

    static func load(_ url: URL) -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? dec.decode(Entry.self, from: Data($0.utf8)) }
    }

    public var all: [Entry] { lock.withLock { entries } }

    public func entry(_ id: String) -> Entry? { lock.withLock { entries.first { $0.id == id } } }

    /// Adds an entry. A repeat of the newest entry with the same title and summary is not added twice.
    @discardableResult
    public func post(kind: Kind, title: String, summary: String, evidence: [String] = [], files: [String] = [], author: String) -> Entry? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ").truncated(160, marker: "…")
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines).truncated(2400, marker: "…")
        guard !title.isEmpty else { return nil }
        let e: Entry? = lock.withLock {
            if let last = entries.last(where: { $0.title == title }), last.summary == summary { return nil }
            let e = Entry(id: "b\(entries.count + 1)", kind: kind, title: title, summary: summary, evidence: Array(evidence.prefix(40)),
                          files: Array(files.prefix(40)), author: author, at: Date())
            entries.append(e)
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let d = try? enc.encode(e), var line = String(data: d, encoding: .utf8) {
                line += "\n"
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let h = try? FileHandle(forWritingTo: url) {
                    defer { try? h.close() }
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: Data(line.utf8))
                } else {
                    try? Data(line.utf8).write(to: url)
                }
            }
            return e
        }
        if let e { onPost?(e) }
        return e
    }

    /// The first layer: one line per entry, newest last.
    public func index(limit: Int = 40, prefix: String = "") -> String {
        let es = all.suffix(limit)
        return es.map { "\(prefix)\($0.id) [\($0.kind.rawValue) · \($0.author)] \($0.title)" }.joined(separator: "\n")
    }

    /// The second and third layers of one entry.
    public static func render(_ e: Entry) -> String {
        var lines = ["\(e.id) [\(e.kind.rawValue) · \(e.author)] \(e.title)", e.summary]
        if !e.evidence.isEmpty { lines.append("Evidence (open with `receipt`): " + e.evidence.joined(separator: ", ")) }
        if !e.files.isEmpty { lines.append("Files: " + e.files.joined(separator: ", ")) }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Entries whose title or summary holds the query's words, best first.
    public func search(_ query: String, limit: Int = 8) -> [Entry] {
        let terms = Recall.terms(query)
        guard !terms.isEmpty else { return [] }
        return all.map { e in (e, Recall.score(terms, in: e.title + "\n" + e.summary)) }.filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// What earlier tasks in the workspace left on their boards (facts, hand-offs and dead ends), newest
    /// first: a new task starts from what is already known here instead of from nothing.
    public static func carryOver(workspace: URL, excluding task: String, limit: Int = 12) -> String {
        let root = workspace.appendingPathComponent(".sievesci/tasks")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return "" }
        var lines: [(Date, String)] = []
        for d in dirs.sorted().reversed().prefix(12) where d != task {
            for e in load(root.appendingPathComponent(d).appendingPathComponent("state/board.jsonl")) where e.kind != .review {
                lines.append((e.at, "\(d)/\(e.id) [\(e.kind.rawValue)] \(e.title)"))
            }
        }
        guard !lines.isEmpty else { return "" }
        return lines.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1).joined(separator: "\n")
    }

    /// An entry of another task's board, `<task>/<id>`.
    public static func foreign(_ ref: String, workspace: URL) -> Entry? {
        let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].contains("..") else { return nil }
        return load(workspace.appendingPathComponent(".sievesci/tasks/\(parts[0])/state/board.jsonl")).first { $0.id == parts[1] }
    }
}

/// Word matching for recall that also works for Chinese (no spaces): Latin words, and pairs of
/// adjacent CJK characters.
public enum Recall {
    public static func terms(_ text: String) -> Set<String> {
        var out = Set<String>(), word = "", prev: Character?
        func flush() { if word.count > 2, !stop.contains(word) { out.insert(word) }; word = "" }
        for c in text.lowercased() {
            if let s = c.unicodeScalars.first, (0x4E00...0x9FFF).contains(s.value) {
                flush()
                if let p = prev { out.insert(String([p, c])) }
                prev = c
            } else {
                prev = nil
                if c.isLetter || c.isNumber || c == "_" { word.append(c) } else { flush() }
            }
        }
        flush()
        return out
    }

    static let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "are", "was", "not", "but", "have", "has", "you", "your", "its", "can", "all", "any"]

    /// How many of the terms the text holds.
    public static func score(_ terms: Set<String>, in text: String) -> Int {
        let have = Self.terms(text)
        return terms.reduce(0) { $0 + (have.contains($1) ? 1 : 0) }
    }
}

struct BoardTool: Tool {
    let name = "board"
    let description = """
    The task's shared board: what the agents of this task have established, for whoever works next (workers and \
    reviewers start with an empty context; the board is what they share). action "list": the index of titles \
    (optionally `query` to search). action "read": one entry's summary and evidence (`id`, e.g. b7; an earlier \
    task's entry as <task>/<id>). action "post": record something a successor needs — kind fact (established, \
    with receipts), handoff (where the work stands: done, not done, next), dead_end (what did not work and why), \
    open (a question or risk). Post results, not narration: a short title, a summary someone can act on, the \
    receipt ids and file paths behind it. Read before redoing work; cite entry ids instead of repeating them.
    """
    var inputSchema: JSON {
        Schema.object(["action": Schema.stringEnum("list | read | post", ["list", "read", "post"]),
                       "id": Schema.string("read: entry id"), "query": Schema.string("list: words to search for"),
                       "kind": Schema.stringEnum("post: kind", ["fact", "handoff", "dead_end", "open"]),
                       "title": Schema.string("post: one line"), "summary": Schema.string("post: what was found / where it stands"),
                       "evidence": Schema.array("post: receipt ids", items: ["type": "string"]),
                       "files": Schema.array("post: file paths", items: ["type": "string"])], required: ["action"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func runsConcurrently(for input: JSON) -> Bool { input.str("action") != "post" }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        // The board holds the main agent's results: a blind verifier works without it.
        if ctx.isBlind { return .error("The shared board is hidden from this agent so its check stays independent.") }
        let board = ctx.services.board
        switch input.str("action") {
        case "read":
            let id = try input.required("id")
            guard let e = board.entry(id) ?? SharedBoard.foreign(id, workspace: ctx.workspace) else { return .error("No board entry \(id).") }
            return ToolOutput(SharedBoard.render(e))
        case "post":
            guard ctx.role != .checker else { return .error("The checker's verdicts are posted by the host; it does not write to the board.") }
            let title = try input.required("title")
            let evidence = input["evidence"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let bad = evidence.filter { ctx.ledger.receipt($0) == nil }
            if !bad.isEmpty { return .error("Unknown receipts: \(bad.joined(separator: ", ")). Cite receipts that exist.") }
            let kind = SharedBoard.Kind(rawValue: input.str("kind") ?? "fact") ?? .fact
            if kind == .fact, evidence.isEmpty, (input["files"]?.arrayValue ?? []).isEmpty {
                return .error("A fact needs its evidence: cite the receipt ids or files that show it (or post it as kind open).")
            }
            guard kind != .review, let e = board.post(kind: kind, title: title, summary: input.str("summary") ?? "", evidence: evidence,
                                                      files: input["files"]?.arrayValue?.compactMap(\.stringValue) ?? [], author: ctx.role.rawValue) else {
                return ToolOutput("Already on the board.")
            }
            return ToolOutput("Posted \(e.id).")
        default:
            if let q = input.str("query"), !q.isEmpty {
                let hits = board.search(q)
                return ToolOutput(hits.isEmpty ? "Nothing on the board matches." : hits.map { "\($0.id) [\($0.kind.rawValue) · \($0.author)] \($0.title)" }.joined(separator: "\n"))
            }
            let idx = board.index(limit: 80)
            return ToolOutput(idx.isEmpty ? "The board is empty." : idx)
        }
    }
}
