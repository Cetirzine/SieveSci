import Foundation

/// The JSON-RPC side of `sievesci serve` (docs/SERVE_PROTOCOL.md): one workspace, at most one open
/// task, requests in, responses and `event` notifications out, one JSON object per line. Transport
/// is the caller's: `handle` takes request lines, `write` sends lines.
public final class ServeServer: @unchecked Sendable {
    public static let protocolVersion = 1

    /// Builds the services for a task id (models, keys and settings come from the caller).
    public typealias ServicesFactory = @Sendable (_ taskId: String) throws -> SessionServices

    let workspace: URL
    let info: [String: JSON]
    let makeServices: ServicesFactory
    let write: @Sendable (String) -> Void

    private let lock = NSLock()
    private var bench: Workbench?
    private var waiters: [String: CheckedContinuation<PermissionDecision, Never>] = [:]
    /// Answers that arrived before their request reached the front of the permission queue.
    private var early: [String: PermissionDecision] = [:]
    private var closed = false

    /// `info` is merged into the `initialize` result (provider, model, mode).
    public init(workspace: URL, info: [String: JSON], makeServices: @escaping ServicesFactory, write: @escaping @Sendable (String) -> Void) {
        self.workspace = workspace
        self.info = info
        self.makeServices = makeServices
        self.write = write
    }

    public var isClosed: Bool { lock.withLock { closed } }

    // MARK: Wire

    struct RPCError: Error { var code: Int; var message: String }

    func send(_ msg: JSON) {
        var m = msg.objectValue ?? [:]
        m["jsonrpc"] = "2.0"
        write(JSONCodec.canonicalString(.object(m)))
    }

    func notify(_ method: String, _ params: JSON) { send(["method": .string(method), "params": params]) }

    /// Handles one request line and writes its response. Lines that are not requests are answered
    /// with an error when they carry an id, and ignored otherwise.
    public func handle(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let msg = try? JSONCodec.parse(trimmed), msg.objectValue != nil else {
            send(["id": .null, "error": ["code": -32700, "message": "unreadable JSON"]])
            return
        }
        let id = msg["id"] ?? .null
        guard let method = msg.str("method") else {
            if !id.isNull { send(["id": id, "error": ["code": -32600, "message": "not a request"]]) }
            return
        }
        do {
            let result = try await dispatch(method, msg["params"] ?? .object([:]))
            if !id.isNull { send(["id": id, "result": result]) }
        } catch let e as RPCError {
            if !id.isNull { send(["id": id, "error": ["code": .int(e.code), "message": .string(e.message)]]) }
        } catch {
            if !id.isNull { send(["id": id, "error": ["code": -32000, "message": .string(error.localizedDescription)]]) }
        }
    }

    // MARK: Methods

    func dispatch(_ method: String, _ p: JSON) async throws -> JSON {
        switch method {
        case "initialize":
            var r = info
            r["name"] = "sievesci"
            r["version"] = .string(SieveSci.version)
            r["protocol"] = .int(Self.protocolVersion)
            r["workspace"] = .string(workspace.path)
            return .object(r)
        case "tasks.list":
            let tasks = SessionStore.tasks(in: workspace).map { t -> JSON in
                ["id": .string(t.id), "title": SessionStore.title(dir: SessionStore.taskDir(t.id, in: workspace)).map { .string($0) } ?? .null,
                 "modified": .string(ISO8601DateFormatter().string(from: t.modified))]
            }
            return ["tasks": .array(tasks)]
        case "task.open": return try await open(p.str("id"))
        case "task.send":
            let b = try current()
            guard let text = p.str("text"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RPCError(code: -32602, message: "text is required") }
            // The turn runs on; its progress arrives as events.
            Task.detached { await b.submit(text) }
            return ["accepted": true]
        case "task.stop":
            try current().interrupt()
            return .object([:])
        case "permission.respond":
            guard let id = p.str("id") else { throw RPCError(code: -32602, message: "id is required") }
            let d: PermissionDecision
            switch p.str("decision") {
            case "allow": d = .allowOnce
            case "always": d = .allowAlways
            case "deny": d = .deny(p.str("reason") ?? "")
            default: throw RPCError(code: -32602, message: "decision must be allow, always or deny")
            }
            resolvePermission(id, d)
            return .object([:])
        case "ask.respond":
            let b = try current()
            guard let id = p.str("id"), let o = p["outcome"].flatMap(Wire.askOutcome) else {
                throw RPCError(code: -32602, message: "id and outcome ({kind: answered, answers} or {kind: dismissed}) are required")
            }
            await b.answerAsk(id, o)
            return .object([:])
        case "brainstorm.wrapUp":
            try current().wrapUpBrainstorm()
            return .object([:])
        case "shutdown":
            await shutdown()
            return .object([:])
        default:
            throw RPCError(code: -32601, message: "unknown method \(method)")
        }
    }

    func current() throws -> Workbench {
        guard let b = lock.withLock({ bench }) else { throw RPCError(code: -32000, message: "no task is open; call task.open first") }
        return b
    }

    func open(_ requested: String?) async throws -> JSON {
        if let b = lock.withLock({ bench }) {
            guard !b.isRunning else { throw RPCError(code: -32000, message: "the open task is running; stop it first") }
            await close(b)
        }
        if let id = requested {
            guard Self.isValidTaskId(id) else { throw RPCError(code: -32602, message: "invalid task id") }
        }
        let id = requested ?? Self.newTaskId()
        let services = try makeServices(id)
        services.asks.interactive = true
        services.emit = { [weak self] e in self?.notify("event", Wire.event(e)) }
        services.requestPermission = { [weak self] req in await self?.waitForPermission(req.id) ?? .deny("front end gone") }
        let b = Workbench(services: services)
        b.onOutput = { [weak self] text in self?.notify("output", ["text": .string(text)]) }
        lock.withLock { bench = b }
        await b.start()
        return [
            "task": .string(id),
            "title": SessionStore.title(dir: services.taskDir).map { .string($0) } ?? .null,
            "running": .bool(b.isRunning),
            "history": .array(Self.history(SessionStore.load(dir: services.taskDir, agent: "main"))),
            "plan": Wire.value(services.research.snapshot),
            "claims": Wire.value(services.claims.snapshot),
            "ideas": Wire.value(services.ideas.snapshot),
            "asks": Wire.value(services.asks.pending),
        ]
    }

    /// The saved transcript as a front end shows it: what the user typed (host context removed),
    /// the replies, and each tool call with its result.
    static func history(_ msgs: [Message]) -> [JSON] {
        var results: [String: ToolResult] = [:]
        for m in msgs { for b in m.blocks { if case .toolResult(let r) = b { results[r.toolUseId] = r } } }
        var out: [JSON] = []
        for m in msgs {
            for b in m.blocks {
                switch b {
                case .text(let t) where m.role == .user && !HostContext.isHostBlock(t):
                    let own = HostContext.userText(t)
                    if !own.isEmpty, !own.hasPrefix("[tool result") { out.append(["kind": "user", "text": .string(own)]) }
                case .text(let t) where m.role == .assistant && !t.isEmpty:
                    out.append(["kind": "assistant", "text": .string(t)])
                case .toolUse(let tu):
                    var item: [String: JSON] = ["kind": "tool", "id": .string(tu.id), "name": .string(tu.name), "input": tu.input]
                    if let r = results[tu.id] {
                        var content = r.content
                        // Results end with their receipt id, e.g. "[receipt r12]".
                        if let range = content.range(of: #"\n*\[receipt (r\d+)\]\s*$"#, options: .regularExpression) {
                            item["receipt"] = .string(String(content[range]).filter { $0.isLetter || $0.isNumber }.replacingOccurrences(of: "receipt", with: ""))
                            content.removeSubrange(range)
                        }
                        item["output"] = .string(content)
                        item["isError"] = .bool(r.isError)
                    }
                    out.append(.object(item))
                default: break
                }
            }
        }
        return out
    }

    /// Task ids name folders under `.sievesci/tasks/`: no separators or `..` from a client.
    static func isValidTaskId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 100 && !id.contains("..")
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
    }

    static func newTaskId() -> String {
        ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate]) + "-" + String(UUID().uuidString.prefix(6)).lowercased()
    }

    // MARK: Permissions

    func waitForPermission(_ id: String) async -> PermissionDecision {
        await withCheckedContinuation { (c: CheckedContinuation<PermissionDecision, Never>) in
            let ready: PermissionDecision? = lock.withLock {
                if closed { return .deny("serve is shutting down") }
                if let d = early.removeValue(forKey: id) { return d }
                waiters[id] = c
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }

    func resolvePermission(_ id: String, _ d: PermissionDecision) {
        let c: CheckedContinuation<PermissionDecision, Never>? = lock.withLock {
            if let c = waiters.removeValue(forKey: id) { return c }
            early[id] = d
            return nil
        }
        c?.resume(returning: d)
    }

    // MARK: Closing

    func close(_ b: Workbench) async {
        b.interrupt()
        let pending: [CheckedContinuation<PermissionDecision, Never>] = lock.withLock {
            let w = Array(waiters.values)
            waiters = [:]
            early = [:]
            if bench === b { bench = nil }
            return w
        }
        for c in pending { c.resume(returning: .deny("task closed")) }
        b.services.kernel.shutdownAll()
        await b.services.mcp.shutdown()
    }

    /// Stops the open task and refuses further work.
    public func shutdown() async {
        let b: Workbench? = lock.withLock { closed = true; return bench }
        if let b { await close(b) }
    }
}
