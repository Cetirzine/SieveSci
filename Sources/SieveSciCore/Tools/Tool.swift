import Foundation

/// What a tool may do, used by the permission system and by read-only agents (checker, verifier,
/// plan mode). The tool *list* never changes inside a session — changing it would invalidate every
/// vendor's prompt cache — so restrictions are enforced at call time instead.
public enum ToolEffect: String, Codable, Sendable, Comparable {
    case readOnly       // reads workspace / network metadata
    case writesFiles    // edits files in the workspace
    case executes       // runs code or shell commands
    case external       // contacts external services with side effects

    var rank: Int { ["readOnly": 0, "writesFiles": 1, "executes": 2, "external": 3][rawValue]! }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

public struct ToolOutput: Sendable {
    public var text: String
    public var isError: Bool
    public var images: [ImageBlock]
    /// Files this call created or modified (absolute paths); fingerprinted into the receipt.
    public var filesWritten: [String]
    public var exitCode: Int32?
    /// Structured facts for the ledger/notebook (e.g. plan revision, claim id).
    public var facts: [String: JSON]

    public init(_ text: String, isError: Bool = false, images: [ImageBlock] = [], filesWritten: [String] = [],
                exitCode: Int32? = nil, facts: [String: JSON] = [:]) {
        self.text = text
        self.isError = isError
        self.images = images
        self.filesWritten = filesWritten
        self.exitCode = exitCode
        self.facts = facts
    }

    public static func error(_ s: String) -> ToolOutput { ToolOutput(s, isError: true) }
}

public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: JSON { get }
    func effect(for input: JSON) -> ToolEffect
    /// Whether this call may run at the same time as the other calls of the same step. Only pure
    /// reads may: a tool that is read-only for permissions but changes session state (plan, todos,
    /// goal, ideas, deliberation, memory) runs in order, so its bookkeeping stays serial and the
    /// outcome does not depend on thread timing.
    func runsConcurrently(for input: JSON) -> Bool
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput
}

extension Tool {
    public func runsConcurrently(for input: JSON) -> Bool { effect(for: input) == .readOnly }
    public var spec: ToolSpec { ToolSpec(name: name, description: description, inputSchema: inputSchema) }
}

/// JSON-schema helpers so tool definitions stay compact and canonical.
public enum Schema {
    public static func object(_ props: [String: JSON], required: [String] = []) -> JSON {
        ["type": "object", "properties": .object(props), "required": .array(required.sorted().map { .string($0) }),
         "additionalProperties": false]
    }
    public static func string(_ d: String) -> JSON { ["type": "string", "description": .string(d)] }
    public static func integer(_ d: String) -> JSON { ["type": "integer", "description": .string(d)] }
    public static func number(_ d: String) -> JSON { ["type": "number", "description": .string(d)] }
    public static func bool(_ d: String) -> JSON { ["type": "boolean", "description": .string(d)] }
    public static func stringEnum(_ d: String, _ values: [String]) -> JSON {
        ["type": "string", "description": .string(d), "enum": .array(values.map { .string($0) })]
    }
    public static func array(_ d: String, items: JSON) -> JSON { ["type": "array", "description": .string(d), "items": items] }
}

/// Per-agent role. The same tool list is offered to every role that shares a prompt prefix; the
/// role only changes what is *allowed* at call time.
public enum AgentRole: String, Codable, Sendable, CaseIterable {
    case main
    case worker      // delegated subtask; may write in its own scratch dir
    case checker     // supervisor review: read-only
    case verifier    // blind re-implementation: may execute, writes only in its sandbox dir
}

/// Everything a tool needs, owned by the session.
/// The tool call being executed (task-local, so concurrent read-only calls stay separate). Lets
/// long-running tools stream live progress to the UI.
public enum CurrentToolCall {
    @TaskLocal public static var id: String?
}

/// Batches streamed lines so the UI gets at most ~4 updates per second.
public final class ProgressBatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []
    private var last = Date.distantPast
    private let send: @Sendable ([String]) -> Void
    public init(_ send: @escaping @Sendable ([String]) -> Void) { self.send = send }
    public func add(_ lines: [String]) {
        lock.lock()
        pending += lines
        guard Date().timeIntervalSince(last) >= 0.25 else { lock.unlock(); return }
        let out = pending; pending = []; last = Date()
        lock.unlock()
        send(out)
    }
    public func flush() {
        lock.lock(); let out = pending; pending = []; lock.unlock()
        if !out.isEmpty { send(out) }
    }
}

public final class ToolContext: @unchecked Sendable {
    public let workspace: URL
    public let sessionId: String
    public let role: AgentRole
    /// Files the verifier must not read (the main agent's analysis code), so its check is blind.
    public let blindedPaths: [String]
    /// Directory the role may write into (verifier/worker sandboxes). nil = whole workspace.
    public let writeRoot: URL?
    /// Blind agents (the verifier): inside the workspace, only these paths are readable — its own
    /// sandbox and the declared raw data. Enforced for file tools here and for code it runs by the
    /// sandbox (`sandboxReadHidden`). nil = no restriction.
    public let readableRoots: [String]?
    public let ledger: EvidenceLedger
    public let audit: AuditLog?
    public let services: SessionServices

    public init(workspace: URL, sessionId: String, role: AgentRole, blindedPaths: [String] = [], writeRoot: URL? = nil,
                readableRoots: [String]? = nil, ledger: EvidenceLedger, audit: AuditLog?, services: SessionServices) {
        self.workspace = workspace
        self.sessionId = sessionId
        self.role = role
        self.blindedPaths = blindedPaths
        self.writeRoot = writeRoot
        self.readableRoots = readableRoots
        self.ledger = ledger
        self.audit = audit
        self.services = services
    }

    /// Streams live output lines of the current tool call to the UI (batched by the caller).
    public func progress(_ lines: [String]) {
        guard !lines.isEmpty, let id = CurrentToolCall.id else { return }
        services.emit(.toolProgress(agentId: sessionId, id: id, lines: lines))
    }

    /// Resolves a user/model-supplied path against the workspace and refuses escapes.
    public func resolve(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : workspace.appendingPathComponent(expanded)
        let std = url.standardizedFileURL
        let root = workspace.standardizedFileURL.path
        // Read-only folders the user added: readable (writes are refused in checkWritable), never by blind agents.
        if !isBlind, !(std.path == root || std.path.hasPrefix(root + "/")),
           services.readOnlyFolders.contains(where: { Self.isUnder(FilePaths.canonical(std.path), FilePaths.canonical($0.path)) }) {
            return std
        }
        guard std.path == root || std.path.hasPrefix(root + "/") else {
            throw ToolError.denied("\(path) is outside the workspace \(root)")
        }
        return std
    }

    static func real(_ p: String) -> String { FilePaths.canonical(p) }
    static func isUnder(_ p: String, _ root: String) -> Bool { p == root || p.hasPrefix(root.hasSuffix("/") ? root : root + "/") }

    public var isBlind: Bool { readableRoots != nil || !blindedPaths.isEmpty }

    /// Shared temp folders. Every agent may write there, so for a blind agent they would be a side
    /// channel to the main agent's work (and they hold other programs' files): hidden from it too.
    public static var sharedTempRoots: [String] {
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { FilePaths.canonical($0) }
        return Array(Set(["/private/tmp", FilePaths.canonical(NSTemporaryDirectory())] + [tmp].compactMap { $0 })).filter { $0.count > 1 }.sorted()
    }

    /// Where a blind agent's own temporary files go (TMPDIR for the code it runs).
    public var privateTempDir: URL? {
        guard readableRoots != nil, let w = writeRoot else { return nil }
        let t = w.appendingPathComponent(".tmp")
        try? FileManager.default.createDirectory(at: t, withIntermediateDirectories: true)
        return t
    }

    public func checkReadable(_ url: URL) throws {
        // Symlinks resolved, so a link the agent plants in its sandbox cannot reach a hidden file.
        let p = Self.real(url.path)
        let hidden = "\(url.lastPathComponent) is hidden from this agent so its check stays independent."
        for b in blindedPaths where Self.isUnder(url.path, b) || Self.isUnder(p, Self.real(b)) { throw ToolError.denied(hidden) }
        if let roots = readableRoots, !roots.contains(where: { Self.isUnder(p, Self.real($0)) }),
           Self.isUnder(p, Self.real(workspace.path)) || Self.sharedTempRoots.contains(where: { Self.isUnder(p, $0) }) {
            throw ToolError.denied(hidden)
        }
    }

    /// Sandbox mode for code this agent runs. A blind agent is always sandboxed where Seatbelt
    /// exists, even if the user turned the sandbox off: without it, its code could read the very
    /// files it is blinded to.
    public var sandboxMode: SandboxMode {
        let m = services.sandboxMode.effective(for: services.permissions.mode)
        return isBlind && m == .off ? .workspaceWrite : m
    }

    /// Whether this agent's blinding also holds for code it runs (false on platforms without Seatbelt).
    public var blindingEnforced: Bool { !isBlind || Seatbelt.available }

    /// Subtrees whose contents code run by a blind agent may not read, and the exceptions.
    public var sandboxReadHidden: (hidden: [URL], allowed: [URL], rehidden: [URL]) {
        let blinded = blindedPaths.map { URL(fileURLWithPath: $0) }
        guard let roots = readableRoots else { return (blinded, [], []) }
        // Environments inside the workspace hold installed packages, not the agent's analysis; the
        // verifier's interpreter needs them to start.
        let envs = [".venv", "venv", "env", ".conda", ".pixi", "renv"].map { workspace.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        // SieveSci's own resources (the kernel driver) and the Python installation stay readable even
        // when they live under a temp folder (development builds, venvs created in /tmp).
        var runtime = [SieveSciResources.bundle.bundleURL]
        if let py = ProcessRunner.which(Platform.python) {
            runtime.append(URL(fileURLWithPath: FilePaths.canonical(py)).deletingLastPathComponent().deletingLastPathComponent())
        }
        return ([workspace] + Self.sharedTempRoots.map { URL(fileURLWithPath: $0) }, roots.map { URL(fileURLWithPath: $0) } + envs + runtime, blinded)
    }

    public func checkWritable(_ url: URL) throws {
        if role == .checker { throw ToolError.denied("The checker is read-only.") }
        // Symlinks resolved on both sides, so a link planted inside a writable dir cannot point out of it.
        let p = FilePaths.canonical(url.path)
        if let w = writeRoot.map({ FilePaths.canonical($0.path) }) {
            if !(p == w || p.hasPrefix(w + "/")) { throw ToolError.denied("This agent may only write under \(w).") }
            return
        }
        // An agent's own write root (above) may lie outside; otherwise writes stay in the workspace, so
        // added read-only folders really are read-only.
        let ws = FilePaths.canonical(workspace.path)
        if !(p == ws || p.hasPrefix(ws + "/")) { throw ToolError.denied("\(url.path) is outside the workspace; added folders are read-only.") }
        // The task record (audit log, receipts, plan, claims, shadow git) is host-written only — the
        // same paths the sandbox protects from agent-run code.
        for d in [".sievesci", ".git"] {
            let root = FilePaths.canonical(workspace.appendingPathComponent(d).path)
            if p == root || p.hasPrefix(root + "/") { throw ToolError.denied("\(d)/ is SieveSci's record of this task and cannot be edited by agents.") }
        }
    }
}

public enum ToolError: Error, LocalizedError, Sendable {
    case denied(String)
    case invalidInput(String)
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .denied(let s): return "Permission denied: \(s)"
        case .invalidInput(let s): return "Invalid input: \(s)"
        case .unknownTool(let s): return "Unknown tool: \(s)"
        }
    }
}

extension JSON {
    public func str(_ k: String) -> String? { self[k]?.stringValue }
    public func int(_ k: String) -> Int? { self[k]?.intValue ?? self[k]?.numberValue.map { Int($0) } }
    public func bool(_ k: String) -> Bool? { self[k]?.boolValue }
    func required(_ k: String) throws -> String {
        // Common spellings models use instead (cmd for command, file for path …): one wasted step less.
        let aliases = ["command": ["cmd", "commandLine", "CommandLine", "script"], "path": ["file", "file_path", "filename", "AbsolutePath"],
                       "code": ["source", "python"], "query": ["q", "search"]]
        guard let v = self[k]?.stringValue ?? aliases[k]?.lazy.compactMap({ self[$0]?.stringValue }).first else {
            throw ToolError.invalidInput("missing '\(k)'")
        }
        return v
    }
}
