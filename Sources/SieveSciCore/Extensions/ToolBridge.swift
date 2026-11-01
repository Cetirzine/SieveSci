import Foundation
#if canImport(Network)
import Network
#endif

/// Gives CLI agents (Claude Code, Codex, Antigravity …) SieveSci's own tools.
///
/// A CLI runs its own agent loop, so without this it would use its built-in shell, file and web
/// tools: no receipts, no sandbox, no permission policy, nothing for the checker or verifier to
/// check. Here each agent session is served as an MCP server over HTTP on 127.0.0.1 (one bearer
/// token per session), and the CLI reaches it through `sievesci mcp-bridge`, a stdio MCP server
/// that forwards each JSON-RPC line. Every `tools/call` runs through `AgentSession.execute`, exactly
/// like a tool call from an API model.
public final class ToolBridge: @unchecked Sendable {
    public static let shared = ToolBridge()

    /// How a CLI starts the stdio bridge, e.g. `[".../SieveSci.app/Contents/MacOS/sievesci-cli", "mcp-bridge"]`.
    /// Set by the host at launch; without it CLI agents keep their built-in tools.
    public var bridgeCommand: [String]?

    private final class Weak { weak var session: AgentSession?; init(_ s: AgentSession) { session = s } }
    private let lock = NSLock()
    private var sessions: [String: Weak] = [:]
    private var port: UInt16?
    /// Tool calls in flight per session token, so Stop can cancel them.
    private var calls: [String: [UUID: Task<(String, Data), Never>]] = [:]

    func cancelCalls(for session: AgentSession) {
        let tasks: [Task<(String, Data), Never>] = lock.withLock {
            guard let t = sessions.first(where: { $0.value.session === session })?.key else { return [] }
            return Array(calls.removeValue(forKey: t)?.values ?? [:].values)
        }
        tasks.forEach { $0.cancel() }
        // Only this session's calls: Stop in one task must not end another task's tools.
        let owner = ObjectIdentifier(session)
        Self.pendingLock.withLock {
            for (id, p) in Self.pending where p.owner == owner {
                p.task.cancel()
                Self.pending.removeValue(forKey: id)
                Self.pendingNotes.removeValue(forKey: id)
            }
        }
    }
    #if canImport(Network)
    private var listener: NWListener?
    #endif
    private let queue = DispatchQueue(label: "app.sievesci.toolbridge")

    /// The endpoint for this session's tools, starting the listener on first use.
    func endpoint(for session: AgentSession) async -> CLIHost.MCP? {
        guard let command = bridgeCommand, !command.isEmpty, let port = await start() else { return nil }
        let token = lock.withLock {
            let t = sessions.first { $0.value.session === session }?.key ?? UUID().uuidString
            sessions[t] = Weak(session)
            sessions = sessions.filter { $0.value.session != nil }
            return t
        }
        return CLIHost.MCP(url: "http://127.0.0.1:\(port)/mcp", token: token, command: command)
    }

    private func start() async -> UInt16? {
        if let p = lock.withLock({ port }) { return p }
        #if canImport(Network)
        return await withCheckedContinuation { (cont: CheckedContinuation<UInt16?, Never>) in
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            guard let l = try? NWListener(using: params) else { cont.resume(returning: nil); return }
            let once = OnceFlag()
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    let p = l.port?.rawValue
                    self?.lock.withLock { self?.port = p }
                    if once.claim() { cont.resume(returning: p) }
                case .failed, .cancelled:
                    if once.claim() { cont.resume(returning: nil) }
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            listener = l
            l.start(queue: queue)
        }
        #else
        return nil
        #endif
    }

    #if canImport(Network)
    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    /// Reads one HTTP/1.1 request (headers + Content-Length body), answers it and closes.
    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest(buf) {
                Task { await self.respond(c, req) }
            } else if done || err != nil || buf.count > 8 << 20 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func respond(_ c: NWConnection, _ req: HTTPRequest) async {
        let (status, body) = await handle(req)
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        c.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
    #endif

    func handle(_ req: HTTPRequest) async -> (String, Data) {
        guard req.method == "POST", req.path.hasPrefix("/mcp") else { return ("404 Not Found", Data()) }
        let token = req.headers["authorization"].map { $0.replacingOccurrences(of: "Bearer ", with: "") } ?? ""
        let session = lock.withLock { sessions[token]?.session }
        guard let session else { return ("401 Unauthorized", Data()) }
        guard let msg = try? JSONCodec.parse(req.body) else { return ("400 Bad Request", Data()) }
        let arrived = Date()
        defer {
            if msg.str("method") == "tools/call" {
                session.services.log("mcp_call", actor: "host", ["tool": .string(msg["params"]?.str("name") ?? ""), "rpc_id": msg["id"] ?? .null,
                                                                  "seconds": .double(Date().timeIntervalSince(arrived))])
            }
        }
        let id = UUID()
        let work = Task { () -> (String, Data) in
            guard let reply = await Self.rpc(msg, session: session) else { return ("202 Accepted", Data()) }
            return ("200 OK", Data(reply.canonical.utf8))
        }
        lock.withLock { calls[token, default: [:]][id] = work }
        let out = await work.value
        lock.withLock { _ = calls[token]?.removeValue(forKey: id) }
        return out
    }

    /// CLIs give an MCP call a fixed time (agy: 3 min). A SieveSci tool still running after this
    /// answers "still running" instead, keeps going, and its result is collected with `tool_result`.
    static var answerWithin: TimeInterval = 150

    /// Calls that outlived `answerWithin`, by id, until collected.
    private static let pendingLock = NSLock()
    nonisolated(unsafe) private static var pending: [String: (task: Task<ToolResult, Never>, owner: ObjectIdentifier)] = [:]

    static let resultTool: JSON = [
        "name": "tool_result",
        "description": "Wait for (up to 150 s) and return the result of a SieveSci tool call that answered \"still running\".",
        "inputSchema": ["type": "object", "properties": ["id": ["type": "string", "description": "The id from the \"still running\" answer"]],
                        "required": ["id"]],
    ]

    /// Waits for a running call up to `answerWithin`; nil if it is still going.
    /// Not a task group: a group waits for all its children before returning, and awaiting a running
    /// `Task` cannot be cancelled, so the timeout would only "win" once the tool had finished anyway.
    static func await(_ task: Task<ToolResult, Never>, within seconds: TimeInterval) async -> ToolResult? {
        await withCheckedContinuation { (cont: CheckedContinuation<ToolResult?, Never>) in
            let once = OnceFlag()
            Task { let r = await task.value; if once.claim() { cont.resume(returning: r) } }
            // A dispatch timer, not a sleeping task: when the cooperative pool is busy, a sleeping
            // task can wake late, and the CLI's deadline would pass first.
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { if once.claim() { cont.resume(returning: nil) } }
        }
    }

    /// What a call that is still running is doing, said in its "still running" answer (by tool call id).
    nonisolated(unsafe) private static var pendingNotes: [String: String] = [:]

    static func setPendingNote(for id: String?, _ note: String) {
        guard let id else { return }
        pendingLock.withLock { pendingNotes[id] = note }
    }

    static func answer(_ result: ToolResult?, id: String, task: Task<ToolResult, Never>, session: AgentSession) -> JSON {
        if let r = result {
            pendingLock.withLock { _ = pending.removeValue(forKey: id); _ = pendingNotes.removeValue(forKey: id) }
            return ["content": [["type": "text", "text": .string(r.content)]], "isError": .bool(r.isError)]
        }
        let doing = pendingLock.withLock { pending[id] = (task, ObjectIdentifier(session)); return pendingNotes[id].map { " " + $0 } ?? "" }
        let note = "Still running in SieveSci (id \(id)); it keeps going and gets a receipt when it finishes.\(doing) Do other work, or call the sievesci tool `tool_result` with {\"id\": \"\(id)\"} to wait for it."
        return ["content": [["type": "text", "text": .string(note)]], "isError": false]
    }

    /// One JSON-RPC message. Notifications (no id) get no reply.
    static func rpc(_ msg: JSON, session: AgentSession) async -> JSON? {
        guard let id = msg["id"], !id.isNull else { return nil }
        let method = msg.str("method") ?? ""
        func ok(_ result: JSON) -> JSON { ["jsonrpc": "2.0", "id": id, "result": result] }
        switch method {
        case "initialize":
            let version = msg["params"]?.str("protocolVersion") ?? "2025-06-18"
            return ok(["protocolVersion": .string(version), "capabilities": ["tools": [:]],
                       "serverInfo": ["name": "sievesci", "version": .string(SieveSci.version)],
                       "instructions": .string(CLIHost.toolInstructions)])
        case "ping":
            return ok([:])
        case "tools/list":
            let tools: [JSON] = session.tools.map { t in
                let s = t.spec
                return ["name": .string(s.name), "description": .string(s.description), "inputSchema": s.inputSchema]
            }
            return ok(["tools": .array(tools + [resultTool])])
        case "tools/call":
            let p = msg["params"]
            let name = p?.str("name") ?? ""
            if name == "tool_result" {
                let id = p?["arguments"]?.str("id") ?? ""
                guard let task = pendingLock.withLock({ pending[id]?.task }) else {
                    return ok(["content": [["type": "text", "text": .string("No running call with id \(id) (it may have been collected already).")]], "isError": true])
                }
                return ok(answer(await Self.await(task, within: answerWithin), id: id, task: task, session: session))
            }
            let id = "mcp-" + UUID().uuidString.prefix(8).lowercased()
            let use = ToolUse(id: id, name: name, input: p?["arguments"] ?? [:])
            // Not tied to this HTTP request: a call that outlives the CLI's deadline keeps running.
            let task = Task { () -> ToolResult in
                guard case .toolResult(let r) = await session.execute(use) else { return ToolResult(toolUseId: id, content: "no result", isError: true) }
                let receipt = r.content.range(of: #"\[r\d+\]\s*$"#, options: .regularExpression).map { String(r.content[$0]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                session.draft?.note("⏺ \(name)(\((p?["arguments"]?.canonical ?? "").prefix(160))) \(r.isError ? "✗" : "→") \(receipt)")
                return r
            }
            return ok(answer(await Self.await(task, within: answerWithin), id: id, task: task, session: session))
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("method not found: \(method)")]]
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

/// The few parts of an HTTP/1.1 request the bridge needs; nil until the whole body has arrived.
struct HTTPRequest {
    var method: String, path: String
    var headers: [String: String]
    var body: Data

    init?(_ data: Data) {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<sep.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        method = String(start[0]); path = String(start[1])
        var h: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        headers = h
        let length = Int(h["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        body = data[bodyStart..<(bodyStart + length)]
    }
}
