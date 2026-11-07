import Foundation

/// File checkpoints for `/rewind` (Claude Code / Reasonix style): before any file-writing tool
/// runs, the previous content of the target file is saved once per turn. Rewinding restores the
/// files and truncates the conversation to the chosen user turn.
public final class CheckpointStore: @unchecked Sendable {
    public struct Snapshot: Codable, Sendable {
        public var turn: Int
        public var path: String
        public var existed: Bool
        public var blob: String?       // file name inside the store
        public var at: Date
    }

    let dir: URL
    private let lock = NSLock()
    public private(set) var snapshots: [Snapshot] = []
    public var turn = 0
    private var seenThisTurn: Set<String> = []

    public init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func beginTurn(_ index: Int) {
        lock.lock(); turn = index; seenThisTurn = []; lock.unlock()
    }

    func snapshot(input: JSON, tool: String, ctx: ToolContext) {
        guard let p = input.str("path"), let url = try? ctx.resolve(p) else { return }
        lock.lock(); defer { lock.unlock() }
        guard !seenThisTurn.contains(url.path) else { return }
        seenThisTurn.insert(url.path)
        var snap = Snapshot(turn: turn, path: url.path, existed: false, blob: nil, at: Date())
        if let data = FileManager.default.contents(atPath: url.path) {
            let name = "\(snapshots.count)-\(Hashing.sha256Hex(data).prefix(12))"
            try? data.write(to: dir.appendingPathComponent(name))
            snap.existed = true
            snap.blob = name
        }
        snapshots.append(snap)
    }

    /// Restores every file changed at or after `turn` to its state before that turn.
    @discardableResult
    public func rewind(toTurn t: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var restored: [String] = []
        // The earliest snapshot per path at/after the turn holds the pre-turn content.
        var firstByPath: [String: Snapshot] = [:]
        for s in snapshots where s.turn >= t && firstByPath[s.path] == nil { firstByPath[s.path] = s }
        for (path, s) in firstByPath {
            if s.existed, let b = s.blob, let data = FileManager.default.contents(atPath: dir.appendingPathComponent(b).path) {
                try? data.write(to: URL(fileURLWithPath: path))
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
            restored.append(path)
        }
        snapshots.removeAll { $0.turn >= t }
        return restored.sorted()
    }
}

/// JSONL transcript per agent, for `/resume`, `/fork` and `/export`. Messages are stored exactly as
/// sent, so a resumed session replays identical bytes and hits the provider's prefix cache.
public final class SessionStore: @unchecked Sendable {
    public static let shared = SessionStore()
    private let lock = NSLock()

    public func append(_ m: Message, task: String, agent: String, dir: URL) {
        let url = dir.appendingPathComponent("transcript-\(agent).jsonl")
        lock.lock(); defer { lock.unlock() }
        guard let line = try? JSONCodec.canonicalData(encodable: m) else { return }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.appendSafely(line + Data("\n".utf8))
            try? fh.close()
        }
    }

    /// The whole conversation, as the user saw it (display, export, digests). Compaction marks are skipped.
    public static func load(dir: URL, agent: String) -> [Message] {
        let dec = JSONDecoder()
        return lines(dir: dir, agent: agent).compactMap { try? dec.decode(Message.self, from: Data($0.utf8)) }
    }

    /// What the model had in context when the session stopped: the conversation as of the last
    /// compaction mark, then everything appended after it. Without this a reopened task sent its whole
    /// history again — past a 1M-token window after a long run.
    public static func loadContext(dir: URL, agent: String) -> [Message] {
        let dec = JSONDecoder()
        var out: [Message] = []
        for line in lines(dir: dir, agent: agent) {
            let data = Data(line.utf8)
            if let m = try? dec.decode(Message.self, from: data) { out.append(m) }
            else if let mark = try? dec.decode(CompactionMark.self, from: data) { out = mark.compacted }
        }
        return out
    }

    /// A compaction, written into the transcript file. Not a `Message`, so `load` skips it.
    struct CompactionMark: Codable { var compacted: [Message]; var epoch: Int }

    public func markCompaction(_ context: [Message], epoch: Int, agent: String, dir: URL) {
        let url = dir.appendingPathComponent("transcript-\(agent).jsonl")
        lock.lock(); defer { lock.unlock() }
        guard let line = try? JSONCodec.canonicalData(encodable: CompactionMark(compacted: context, epoch: epoch)) else { return }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.appendSafely(line + Data("\n".utf8))
            try? fh.close()
        }
    }

    private static func lines(dir: URL, agent: String) -> [Substring] {
        // A reply that was streaming when the app stopped (quit, crash) is kept as an interrupted reply.
        let partial = dir.appendingPathComponent("transcript-\(agent).partial.json")
        if let d = try? Data(contentsOf: partial), let m = try? JSONDecoder().decode(Message.self, from: d) {
            shared.append(m, task: "", agent: agent, dir: dir)
            try? FileManager.default.removeItem(at: partial)
        }
        let url = dir.appendingPathComponent("transcript-\(agent).jsonl")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.split(separator: "\n")
    }

    /// The name the user gave a task (Rename). Its presence is the "named by hand" mark: generated
    /// titles never replace it.
    static let manualTitleFile = "title.txt"
    /// A title the worker model summarized from the first exchange (`TitleSummarizer`).
    static let autoTitleFile = "title-auto.txt"

    static func readTitle(_ url: URL) -> String? {
        guard let t = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Whether the user named this task by hand.
    public static func hasManualTitle(dir: URL) -> Bool { readTitle(dir.appendingPathComponent(manualTitleFile)) != nil }

    /// The generated title, if one was made.
    public static func autoTitle(dir: URL) -> String? { readTitle(dir.appendingPathComponent(autoTitleFile)) }

    /// Stores a generated title (an empty one removes it).
    public static func setAutoTitle(_ title: String, dir: URL) {
        let f = dir.appendingPathComponent(autoTitleFile)
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { try? FileManager.default.removeItem(at: f) } else { try? t.writeReliably(to: f) }
    }

    /// A task's title: the user's own name for it, else the generated one, else the first thing the
    /// user asked (first line, at most 80 characters).
    public static func title(dir: URL) -> String? {
        if let t = readTitle(dir.appendingPathComponent(manualTitleFile)) { return t }
        if let t = autoTitle(dir: dir) { return t }
        let url = dir.appendingPathComponent("transcript-main.jsonl")
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        // The first user message is near the top; read a bounded prefix, not the whole transcript.
        let head = String(decoding: h.readSome(256 * 1024), as: UTF8.self)
        let dec = JSONDecoder()
        for line in head.split(separator: "\n") {
            guard let m = try? dec.decode(Message.self, from: Data(line.utf8)), m.role == .user else { continue }
            for b in m.blocks {
                if let t = b.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") {
                    let first = t.split(separator: "\n").first.map(String.init) ?? t
                    return first.count > 80 ? String(first.prefix(79)) + "…" : first
                }
            }
        }
        return nil
    }

    /// Lists tasks in a workspace, most recent first.
    /// Only tasks with a conversation count: a session that was opened and left without a message
    /// leaves a folder behind, and listing those filled the sidebar with empty "new tasks". Ordered by
    /// the transcript's time (a folder's own date does not change when files inside it do).
    public static func tasks(in workspace: URL) -> [(id: String, modified: Date)] {
        let root = workspace.appendingPathComponent(".sievesci/tasks")
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return items.compactMap { dir -> (id: String, modified: Date)? in
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
            for name in ["transcript-main.jsonl", "transcript-main.partial.json"] {
                let f = dir.appendingPathComponent(name)
                guard let v = try? f.resourceValues(forKeys: keys), (v.fileSize ?? 0) > 0 else { continue }
                return (dir.lastPathComponent, v.contentModificationDate ?? .distantPast)
            }
            return nil
        }
        .sorted { $0.modified > $1.modified }
    }

    /// Moves a task's folder (transcript, audit log, notebook, outputs) to the Trash, so it can be restored.
    public static func trash(task: String, in workspace: URL) throws {
        let dir = workspace.appendingPathComponent(".sievesci/tasks").appendingPathComponent(task)
        guard !task.isEmpty, !task.contains("/"), FileManager.default.fileExists(atPath: dir.path) else { return }
        try Platform.moveToTrash(dir)
    }

    // MARK: Reading other conversations

    public static func taskDir(_ task: String, in workspace: URL) -> URL {
        workspace.appendingPathComponent(".sievesci/tasks").appendingPathComponent(task)
    }

    /// A user-set name (`title.txt`) wins over the generated title and the first question. An empty
    /// name clears it, so the generated title (or the first question) shows again.
    public static func setTitle(_ title: String, task: String, in workspace: URL) {
        let f = taskDir(task, in: workspace).appendingPathComponent(manualTitleFile)
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { try? FileManager.default.removeItem(at: f) } else { try? t.writeReliably(to: f) }
    }

    /// Resolves what someone typed as a task reference: an exact id, a unique id prefix, or a unique title match.
    public static func resolve(_ ref: String, in workspace: URL) -> String? {
        let r = ref.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "task:", with: "")
        guard !r.isEmpty else { return nil }
        let all = tasks(in: workspace).map(\.id)
        if all.contains(r) { return r }
        let byPrefix = all.filter { $0.hasPrefix(r) }
        if byPrefix.count == 1 { return byPrefix[0] }
        let byTitle = all.filter { (title(dir: taskDir($0, in: workspace)) ?? "").localizedCaseInsensitiveContains(r) }
        return byTitle.count == 1 ? byTitle[0] : nil
    }

    /// The user's own words in a message (host context blocks left out).
    static func userWords(_ m: Message) -> String? {
        for b in m.blocks {
            if let t = b.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("[tool result") {
                return t.components(separatedBy: "\n<").first ?? t
            }
        }
        return nil
    }

    /// What a conversation asked and concluded: each question and the reply that closed it, bounded.
    public static func digest(task: String, in workspace: URL, maxChars: Int = 6000) -> String {
        let msgs = load(dir: taskDir(task, in: workspace), agent: "main")
        var turns: [(q: String, a: String)] = []
        for m in msgs {
            if m.role == .user, let q = userWords(m) { turns.append((q, "")) }
            else if m.role == .assistant, !turns.isEmpty {
                let t = m.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { turns[turns.count - 1].a = t }
            }
        }
        var out = "Conversation \(task) — \(title(dir: taskDir(task, in: workspace)) ?? "untitled") (\(turns.count) turns)\n"
        // Newest turns matter most: keep the first question for context, then fill from the end.
        var body: [String] = []
        var budget = maxChars - out.count
        for (i, t) in turns.enumerated().reversed() {
            let block = "Q\(i + 1): \(t.q.truncated(400, marker: "…"))\nA\(i + 1): \(t.a.isEmpty ? "(no reply)" : t.a.truncated(900, marker: "…"))"
            guard budget - block.count > 0 else { body.insert("… \(i + 1) earlier turns omitted (session_read part \"full\" pages through all of it)", at: 0); break }
            budget -= block.count
            body.insert(block, at: 0)
        }
        out += body.joined(separator: "\n\n")
        return out
    }

    /// The last thing the assistant said, read from the end of the transcript.
    public static func lastReply(task: String, in workspace: URL) -> String? {
        let url = taskDir(task, in: workspace).appendingPathComponent("transcript-main.jsonl")
        guard let h = try? FileHandle(forReadingFrom: url), let size = try? h.seekToEnd() else { return nil }
        defer { try? h.close() }
        try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let tail = String(decoding: h.readRest(), as: UTF8.self)
        let dec = JSONDecoder()
        for line in tail.split(separator: "\n").reversed() {
            guard let m = try? dec.decode(Message.self, from: Data(line.utf8)), m.role == .assistant else { continue }
            let t = m.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }

    /// Cross-conversation memory for a new session: the workspace's other conversations, newest first,
    /// one line each (title and latest conclusion). No model call; bounded; first turn only.
    public static func index(workspace: URL, excluding: String, maxChars: Int = 1800) -> String {
        var lines: [String] = []
        var used = 0
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        for t in tasks(in: workspace) where t.id != excluding {
            let title = title(dir: taskDir(t.id, in: workspace)) ?? "untitled"
            let last = lastReply(task: t.id, in: workspace).map { " — " + ($0.split(separator: "\n").first.map(String.init) ?? $0).truncated(140, marker: "…") } ?? ""
            let line = "- \(t.id) · \(fmt.string(from: t.modified)) · \(title.truncated(80, marker: "…"))\(last)"
            if used + line.count > maxChars { break }
            used += line.count
            lines.append(line)
        }
        guard !lines.isEmpty else { return "" }
        return "<other_conversations note=\"Earlier conversations in this workspace. Read one with session_read before relying on it; the user may refer to them by id or title.\">\n" + lines.joined(separator: "\n") + "\n</other_conversations>"
    }

    /// Markdown export of a transcript (for `/export`).
    public static func markdown(_ msgs: [Message]) -> String {
        var out = ""
        for m in msgs {
            for b in m.blocks {
                switch b {
                case .text(let t): out += (m.role == .user ? "\n> " + t.replacingOccurrences(of: "\n", with: "\n> ") : "\n" + t) + "\n"
                case .toolUse(let tu): out += "\n⏺ **\(tu.name)** `\(tu.input.canonical.truncated(300))`\n"
                case .toolResult(let tr): out += "\n```\n\(tr.content.truncated(3000))\n```\n"
                case .thinking(let th) where !th.text.isEmpty: out += "\n<details><summary>thinking</summary>\n\n\(th.text)\n</details>\n"
                default: break
                }
            }
        }
        return out
    }
}
