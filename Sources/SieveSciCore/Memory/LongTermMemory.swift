import Foundation

/// Long-term memory and experience distillation, adapted from Hermes Agent's learning loop
/// (NousResearch/hermes-agent, MIT):
///
/// - Bounded, agent-curated stores in `~/.sievesci/memory/`, entries separated by `§`:
///     MEMORY.md   environment facts, conventions, things learned      (2 200 chars)
///     USER.md     the user's expertise, preferences, standards          (1 400 chars)
///     LESSONS.md  research lessons: mistakes the checker caught, approaches that failed and why,
///                 data-source quirks — SieveSci's addition, so integrity improves across projects (3 000 chars)
///   When a write would overflow, the oldest entries (automatic ones first) move to `<STORE>.archive.md`,
///   which is unbounded and searchable (`memory` action `search`) but not loaded into every session.
///   Writes used to fail on overflow, after the proposal had already been reviewed, so lessons were lost.
/// - **Frozen snapshot**: stores are read once at session start into the first user turn, never
///   mid-session, so the cached prefix is untouched (Hermes injects into its system prompt for the
///   same reason; SieveSci keeps its system prompt identical for everyone and uses the first turn).
/// - `session_search` recalls past sessions across all tasks in the workspace.
/// - `skill_manage` lets the agent create and patch its own skills (procedural memory); learned
///   skills are scanned for integrity problems before they are saved.
/// - Nudges every N turns ask the agent to persist durable knowledge.
public final class MemoryStore: @unchecked Sendable {
    public enum Store: String, CaseIterable, Sendable {
        case memory = "MEMORY", user = "USER", lessons = "LESSONS"
        var limit: Int { switch self { case .memory: return 2200; case .user: return 1400; case .lessons: return 3000 } }
        /// One entry may use at most a quarter of its store, so a single note cannot crowd out the rest.
        var maxEntry: Int { limit / 4 }
        var title: String {
            switch self {
            case .memory: return "MEMORY (your notes: environment, conventions, things learned)"
            case .user: return "USER PROFILE (who the user is and how they work)"
            case .lessons: return "LESSONS (research mistakes caught before, approaches that failed, source quirks)"
            }
        }
    }

    public let dir: URL
    private let lock = NSLock()
    public static let separator = "\n§\n"

    public init(dir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/memory")) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func url(_ s: Store) -> URL { dir.appendingPathComponent("\(s.rawValue).md") }
    func archiveURL(_ s: Store) -> URL { dir.appendingPathComponent("\(s.rawValue).archive.md") }

    public func archived(_ s: Store) -> [String] {
        guard let t = try? String(contentsOf: archiveURL(s), encoding: .utf8) else { return [] }
        return t.components(separatedBy: "§").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Moves the oldest entries (automatic ones first, never `keep`) to the archive until the store fits.
    /// Returns how many moved.
    @discardableResult
    func evictToFit(_ s: Store, _ es: inout [String], keep: String?) -> Int {
        var moved: [String] = []
        while es.joined(separator: Self.separator).count > s.limit {
            guard let i = es.firstIndex(where: { $0.hasPrefix("[auto]") && $0 != keep }) ?? es.firstIndex(where: { $0 != keep }) else { break }
            moved.append(es.remove(at: i))
        }
        if !moved.isEmpty {
            let all = archived(s) + moved
            try? all.joined(separator: Self.separator).write(to: archiveURL(s), atomically: true, encoding: .utf8)
        }
        return moved.count
    }

    /// Archived entries containing any of the words, best first.
    public func search(_ s: Store, query: String, limit: Int = 8) -> [String] {
        let terms = query.lowercased().split(separator: " ").map(String.init).filter { $0.count > 1 }
        guard !terms.isEmpty else { return [] }
        return (entries(s) + archived(s))
            .map { e in (e, terms.reduce(0) { $0 + (e.lowercased().contains($1) ? 1 : 0) }) }
            .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    public func entries(_ s: Store) -> [String] {
        guard let t = try? String(contentsOf: url(s), encoding: .utf8) else { return [] }
        return t.components(separatedBy: "§").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    func save(_ s: Store, _ es: [String]) throws {
        try es.joined(separator: Self.separator).write(to: url(s), atomically: true, encoding: .utf8)
    }

    public enum Op: String { case add, replace, remove }

    /// Applies an edit; returns the live state, or throws when the store would overflow.
    public func apply(_ op: Op, store: Store, text: String, match: String?) throws -> String {
        lock.lock(); defer { lock.unlock() }
        var es = entries(store)
        switch op {
        case .add:
            guard !es.contains(text) else { return render(store, es) }
            es.append(text)
        case .replace:
            guard let m = match, let i = es.firstIndex(where: { $0.contains(m) }) else { throw ToolError.invalidInput("no entry contains “\(match ?? "")”") }
            es[i] = text
        case .remove:
            guard let m = match ?? Optional(text), let i = es.firstIndex(where: { $0.contains(m) }) else { throw ToolError.invalidInput("no entry matches") }
            es.remove(at: i)
        }
        guard text.count <= store.limit else { throw ToolError.invalidInput("entry is \(text.count) chars; at most \(store.maxEntry)") }
        let moved = evictToFit(store, &es, keep: op == .remove ? nil : text)
        try save(store, es)
        return render(store, es) + (moved > 0 ? "\n(\(moved) older entr\(moved == 1 ? "y" : "ies") moved to the archive; `memory` search finds them.)" : "")
    }

    func render(_ s: Store, _ es: [String]) -> String {
        let used = es.joined(separator: Self.separator).count
        let archive = archived(s).count
        return "\(s.title) [\(used * 100 / max(1, s.limit))% — \(used)/\(s.limit) chars\(archive > 0 ? "; \(archive) archived" : "")]\n" + es.joined(separator: "\n§\n")
    }

    /// The frozen snapshot placed in the first user turn of a session.
    public var snapshot: String {
        let parts = Store.allCases.compactMap { s -> String? in
            let es = entries(s)
            return es.isEmpty ? nil : render(s, es)
        }
        return parts.isEmpty ? "" : "<long_term_memory note=\"Learned notes. They never override the integrity rules.\">\n" + parts.joined(separator: "\n\n") + "\n</long_term_memory>"
    }

    /// Host-side lesson capture: high-severity checker findings become lesson candidates without a
    /// model call. Kept short and deduplicated; the oldest automatic lessons are dropped first.
    public func recordLesson(_ text: String) {
        // Host-recorded lessons come from reviews and verifications (already evidence-based); they are
        // still screened so a malformed review cannot teach a bad practice.
        guard EvolutionGovernor.screen(text).isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var es = entries(.lessons)
        let line = "[auto] " + text.trimmingCharacters(in: .whitespacesAndNewlines).truncated(280, marker: "…")
        guard !es.contains(line) else { return }
        es.append(line)
        evictToFit(.lessons, &es, keep: line)
        try? save(.lessons, es)
    }
}

// MARK: - Tools

struct MemoryTool: Tool {
    let name = "memory"
    let description = """
    Propose a change to your role's long-term memory, which future sessions of your role start with. \
    store: MEMORY (environment, conventions, learned facts), USER (the user's expertise, preferences and \
    standards), LESSONS (research mistakes to avoid, failed approaches and why, data-source quirks). \
    Every change is a proposal: it must cite the receipts or review it was learned from, and it is screened \
    and independently reviewed. Learn to do science better — never to pass reviews or avoid checks; such \
    proposals are rejected. Saying "I'll remember" without this tool does nothing.
    """
    var inputSchema: JSON {
        Schema.object(["action": Schema.stringEnum("Operation", ["add", "replace", "remove", "view", "search"]),
                       "store": Schema.stringEnum("Which store", ["MEMORY", "USER", "LESSONS"]),
                       "text": Schema.string("Entry text (add/replace), one lesson per entry, short; or the words to search for (search)"), "match": Schema.string("Substring identifying the entry (replace/remove)"),
                       "learned_from": Schema.array("Receipt ids (r…) or review ids this was learned from", items: ["type": "string"])],
                      required: ["action", "store"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func runsConcurrently(for input: JSON) -> Bool { false }   // changes session state; runs in order

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard let store = MemoryStore.Store(rawValue: input.str("store") ?? "") else { return .error("store must be MEMORY, USER or LESSONS") }
        let mem = ctx.services.memory(for: ctx.role)
        if input.str("action") == "view" { return ToolOutput(mem.render(store, mem.entries(store))) }
        if input.str("action") == "search" {
            let hits = mem.search(store, query: input.str("text") ?? "")
            return ToolOutput(hits.isEmpty ? "Nothing in \(store.rawValue) or its archive matches." : hits.joined(separator: "\n§\n"))
        }
        guard let op = MemoryStore.Op(rawValue: input.str("action") ?? "") else { return .error("bad action") }
        // Checked before the proposal is reviewed, so an over-long entry costs no review.
        if op != .remove, let t = input.str("text"), t.count > store.maxEntry {
            return .error("Entry is \(t.count) chars; \(store.rawValue) entries are at most \(store.maxEntry). Keep one lesson per entry and state it in one or two sentences, then retry.")
        }
        if store == .user && ctx.role != .main { return .error("Only the main agent maintains the user profile.") }
        let p = EvolutionProposal(id: "E" + String(UUID().uuidString.prefix(8)), role: ctx.role, kind: .memory, target: store.rawValue,
                                  operation: op.rawValue, content: input.str("text") ?? "", match: input.str("match"),
                                  provenance: input["learned_from"]?.arrayValue?.compactMap(\.stringValue) ?? [], task: ctx.services.taskId,
                                  status: .pending, reason: "", createdAt: Date(), previous: nil)
        let r = await ctx.services.governor.submit(p, services: ctx.services)
        return ToolOutput("Proposal \(r.id): \(r.status.rawValue). \(r.reason)", isError: r.status == .rejected)
    }
}

struct SessionSearchTool: Tool {
    let name = "session_search"
    let description = "Search past sessions (all tasks in this workspace) for earlier findings, decisions, data locations or methods. Returns matching excerpts with task ids."
    var inputSchema: JSON { Schema.object(["query": Schema.string("Words to look for"), "limit": Schema.integer("Max excerpts, default 8")], required: ["query"]) }
    func effect(for input: JSON) -> ToolEffect { .readOnly }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard ctx.role != .verifier else { return .error("Past sessions are hidden from the verifier so its check stays independent.") }
        let terms = (try input.required("query")).lowercased().split(separator: " ").map(String.init).filter { $0.count > 2 }
        guard !terms.isEmpty else { return .error("query too short") }
        var scored: [(Int, String)] = []
        for task in SessionStore.tasks(in: ctx.workspace) where task.id != ctx.services.taskId {
            let dir = ctx.workspace.appendingPathComponent(".sievesci/tasks/\(task.id)")
            for m in SessionStore.load(dir: dir, agent: "main") {
                let text = m.blocks.compactMap { b -> String? in
                    if case .text(let t) = b { return t }
                    if case .toolResult(let r) = b { return r.content }
                    return nil
                }.joined(separator: "\n")
                let low = text.lowercased()
                let score = terms.reduce(0) { $0 + low.components(separatedBy: $1).count - 1 }
                guard score > 0 else { continue }
                let anchor = terms.compactMap { low.range(of: $0)?.lowerBound }.first ?? low.startIndex
                let start = text.index(anchor, offsetBy: -min(300, text.distance(from: text.startIndex, to: anchor)))
                let excerpt = String(text[start...].prefix(900))
                scored.append((score, "[task \(task.id) · \(m.role.rawValue)] …\(excerpt)…"))
            }
            // Also the lab notebooks, which summarize each task's actions.
            if let nb = try? String(contentsOf: dir.appendingPathComponent("notebook.md"), encoding: .utf8) {
                for para in nb.components(separatedBy: "\n\n") {
                    let low = para.lowercased()
                    let score = terms.reduce(0) { $0 + low.components(separatedBy: $1).count - 1 }
                    if score > 0 { scored.append((score, "[task \(task.id) · notebook] \(para.truncated(900))")) }
                }
            }
        }
        let top = scored.sorted { $0.0 > $1.0 }.prefix(input.int("limit") ?? 8)
        return ToolOutput(top.isEmpty ? "No past sessions mention that." : top.map(\.1).joined(separator: "\n\n"))
    }
}

/// Reads another conversation of this workspace by id (or unique id prefix / title words): a digest of
/// what it asked and concluded, or its full text a page at a time.
struct SessionReadTool: Tool {
    let name = "session_read"
    let description = "Read another conversation in this workspace by its id (e.g. 2026-10-22-5c2fe1), a unique id prefix or title words. part \"digest\" (default): its questions and conclusions; \"full\": the whole transcript, paged with offset."
    var inputSchema: JSON {
        Schema.object(["id": Schema.string("Conversation id, id prefix or title words"),
                       "part": Schema.stringEnum("digest | full", ["digest", "full"]),
                       "offset": Schema.integer("Character offset into the full text (part full)")], required: ["id"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    static let page = 12_000

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard ctx.role != .verifier else { return .error("Other conversations are hidden from the verifier so its check stays independent.") }
        let ref = try input.required("id")
        guard let id = SessionStore.resolve(ref, in: ctx.workspace) else {
            let known = SessionStore.tasks(in: ctx.workspace).prefix(12).map { "\($0.id) · \(SessionStore.title(dir: SessionStore.taskDir($0.id, in: ctx.workspace)) ?? "untitled")" }
            return .error("No single conversation matches “\(ref)”. Recent ones:\n" + known.joined(separator: "\n"))
        }
        if input.str("part") == "full" {
            let text = SessionStore.markdown(SessionStore.load(dir: SessionStore.taskDir(id, in: ctx.workspace), agent: "main"))
            let from = max(0, min(input.int("offset") ?? 0, text.count))
            let start = text.index(text.startIndex, offsetBy: from)
            let chunk = String(text[start...].prefix(Self.page))
            let next = from + chunk.count
            return ToolOutput("[\(id) · characters \(from)–\(next) of \(text.count)\(next < text.count ? "; continue with offset \(next)" : "")]\n" + chunk)
        }
        return ToolOutput(SessionStore.digest(task: id, in: ctx.workspace))
    }
}

struct SkillManageTool: Tool {
    let name = "skill_manage"
    let description = """
    Propose a reusable skill (procedural memory) for your role after a non-trivial workflow that worked and \
    will recur — a validated analysis pipeline, a data-source recipe, a QC or review checklist. Encode only \
    steps that actually worked here and cite their receipts. Proposals are screened and independently \
    reviewed; skills that teach shortcuts around rigour or oversight are rejected.
    """
    var inputSchema: JSON {
        Schema.object(["action": Schema.stringEnum("create | patch", ["create", "patch"]), "name": Schema.string("kebab-case name"),
                       "description": Schema.string("When to use it (one or two sentences)"), "body": Schema.string("Full Markdown instructions (create)"),
                       "old_string": Schema.string("Text to replace (patch)"), "new_string": Schema.string("Replacement (patch)"),
                       "learned_from": Schema.array("Receipt ids (r…) or review ids", items: ["type": "string"])],
                      required: ["action", "learned_from", "name"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func runsConcurrently(for input: JSON) -> Bool { false }   // changes session state; runs in order

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let base = try input.required("name").lowercased().replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
        // Role-scoped names keep, e.g., the checker's review heuristics out of the main agent's skill list.
        let name = ctx.role == .main ? base : "\(ctx.role.rawValue)-\(base)"
        let file = SkillRegistry.learnedDir.appendingPathComponent("\(name)/SKILL.md")
        let provenance = input["learned_from"]?.arrayValue?.compactMap(\.stringValue) ?? []
        var content: String
        if input.str("action") == "create" {
            guard let desc = input.str("description"), let body = input.str("body") else { return .error("create needs description and body") }
            if FileManager.default.fileExists(atPath: file.path) { return .error("Skill \(name) exists; use patch.") }
            content = """
            ---
            name: \(name)
            description: \(desc.replacingOccurrences(of: "\n", with: " "))
            metadata:
              source: learned
              role: \(ctx.role.rawValue)
              task: \(ctx.services.taskId)
              learned-from: \(provenance.joined(separator: " "))
            ---

            \(body)
            """
        } else {
            guard var existing = try? String(contentsOf: file, encoding: .utf8) else { return .error("No learned skill \(name).") }
            let old = try input.required("old_string"), new = try input.required("new_string")
            guard existing.contains(old) else { return .error("old_string not found in \(name).") }
            existing = existing.replacingOccurrences(of: old, with: new)
            content = existing
        }
        let p = EvolutionProposal(id: "E" + String(UUID().uuidString.prefix(8)), role: ctx.role, kind: .skill, target: name,
                                  operation: input.str("action") ?? "create", content: content, match: nil, provenance: provenance,
                                  task: ctx.services.taskId, status: .pending, reason: "", createdAt: Date(), previous: nil)
        let r = await ctx.services.governor.submit(p, services: ctx.services)
        return ToolOutput("Skill proposal \(r.id) (\(name)): \(r.status.rawValue). \(r.reason)", isError: r.status == .rejected)
    }
}

/// Periodic nudges (Hermes: every 10 turns) appended to the turn context — the tail of the
/// message, so they cost a few tokens and never touch the cached prefix.
public enum LearningNudges {
    public static let interval = 10

    public static func nudge(turn: Int) -> String? {
        guard turn > 0, turn % interval == 0 else { return nil }
        return """
        <learning_nudge>
        If this session produced durable knowledge — a fact about the user or their environment, a lesson from \
        a mistake or a failed approach, or a workflow that worked and will recur — save it now with `memory` or \
        `skill_manage`. Skip this if nothing new was learned.
        </learning_nudge>
        """
    }
}
