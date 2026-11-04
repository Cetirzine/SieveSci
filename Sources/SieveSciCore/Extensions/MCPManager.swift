import Foundation
import MCP
#if canImport(System)
import System
#else
import SystemPackage
#endif

/// MCP client built on the official Swift SDK. Config files use the Claude Code / Claude Desktop
/// shape, so existing server configs work unchanged:
///   { "mcpServers": { "name": { "command": "...", "args": [...], "env": {...} },
///                     "web":  { "type": "http", "url": "https://...", "headers": {...} } } }
/// Read from `<workspace>/.mcp.json`, `<workspace>/.sievesci/mcp.json` and `~/.sievesci/mcp.json`.
/// Tools are exposed as `mcp__<server>__<tool>` and frozen into the session's tool list.
public final class MCPManager: @unchecked Sendable {
    public struct ServerConfig: Sendable, Equatable {
        public var name: String
        public var command: String?
        public var args: [String]
        public var env: [String: String]
        public var url: String?
        public var headers: [String: String]
    }

    public struct ServerStatus: Sendable { public var name: String; public var connected: Bool; public var tools: Int; public var error: String? }

    let workspace: URL
    private let lock = NSLock()
    private var clients: [String: Client] = [:]
    private var processes: [String: Process] = [:]
    public private(set) var status: [ServerStatus] = []

    public init(workspace: URL) { self.workspace = workspace }

    /// Use `PipeTransport` for stdio servers everywhere (tests of the Windows path).
    static var forcePipeTransport = ProcessInfo.processInfo.environment["SIEVESCI_PIPE_MCP"] == "1"

    public var configs: [ServerConfig] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let files = [workspace.appendingPathComponent(".mcp.json"), workspace.appendingPathComponent(".sievesci/mcp.json"),
                     home.appendingPathComponent(".sievesci/mcp.json")]
        var out: [String: ServerConfig] = [:]
        for f in files {
            guard let d = try? Data(contentsOf: f), let j = try? JSONCodec.parse(d), let servers = j["mcpServers"]?.objectValue else { continue }
            for (name, s) in servers where out[name] == nil && s["disabled"]?.boolValue != true {
                out[name] = ServerConfig(
                    name: name, command: s.str("command"), args: s["args"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                    env: (s["env"]?.objectValue ?? [:]).compactMapValues(\.stringValue),
                    url: s.str("url"), headers: (s["headers"]?.objectValue ?? [:]).compactMapValues(\.stringValue))
            }
        }
        return out.values.sorted { $0.name < $1.name }
    }

    /// Connects every configured server and returns adapters for their tools.
    public func connectAll() async -> [Tool] {
        var tools: [Tool] = []
        var st: [ServerStatus] = []
        for cfg in configs {
            do {
                let client = Client(name: "SieveSci", version: SieveSci.version)
                if let url = cfg.url.flatMap(URL.init(string:)) {
                    let headers = cfg.headers
                    let transport = HTTPClientTransport(endpoint: url, requestModifier: { r in
                        var r = r
                        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
                        return r
                    })
                    _ = try await client.connect(transport: transport)
                } else if let cmd = cfg.command {
                    let p = try ProcessRunner.makeProcess(cmd, cfg.args, cwd: workspace, env: cfg.env)
                    let toServer = Pipe(), fromServer = Pipe()
                    p.standardInput = toServer
                    p.standardOutput = fromServer
                    p.standardError = FileHandle.nullDevice
                    try p.run()
                    lock.lock(); processes[cfg.name] = p; lock.unlock()
                    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                    if !Self.forcePipeTransport {
                        let transport = StdioTransport(input: FileDescriptor(rawValue: fromServer.fileHandleForReading.fileDescriptor),
                                                       output: FileDescriptor(rawValue: toServer.fileHandleForWriting.fileDescriptor))
                        _ = try await client.connect(transport: transport)
                    } else {
                        _ = try await client.connect(transport: PipeTransport(reader: fromServer.fileHandleForReading, writer: toServer.fileHandleForWriting))
                    }
                    #else
                    // Windows: the SDK's StdioTransport is POSIX-only.
                    _ = try await client.connect(transport: PipeTransport(reader: fromServer.fileHandleForReading, writer: toServer.fileHandleForWriting))
                    #endif
                } else { continue }
                var listed: [MCP.Tool] = []
                var cursor: String?
                repeat {
                    let page = try await client.listTools(cursor: cursor)
                    listed += page.tools
                    cursor = page.nextCursor
                } while cursor != nil
                lock.lock(); clients[cfg.name] = client; lock.unlock()
                tools += listed.map { MCPToolAdapter(server: cfg.name, tool: $0, manager: self) }
                st.append(ServerStatus(name: cfg.name, connected: true, tools: listed.count, error: nil))
            } catch {
                st.append(ServerStatus(name: cfg.name, connected: false, tools: 0, error: error.localizedDescription))
            }
        }
        lock.lock(); status = st; lock.unlock()
        return tools
    }

    func call(server: String, tool: String, args: [String: Value]) async throws -> (String, Bool, [ImageBlock]) {
        lock.lock()
        let c = clients[server]
        lock.unlock()
        guard let c else { throw ToolError.unknownTool("MCP server \(server) is not connected") }
        let (content, isError) = try await c.callTool(name: tool, arguments: args)
        var text: [String] = []
        var images: [ImageBlock] = []
        for item in content {
            switch item {
            case .text(let t, _, _): text.append(t)
            case .image(let data, let mime, _, _): images.append(ImageBlock(mediaType: mime, base64: data))
            case .resource(let r, _, _): text.append("\(r)")
            default: text.append("\(item)")
            }
        }
        return (text.joined(separator: "\n"), isError ?? false, images)
    }

    public func shutdown() async {
        lock.lock()
        let cs = clients
        let ps = processes
        clients = [:]
        processes = [:]
        lock.unlock()
        for c in cs.values { await c.disconnect() }
        for p in ps.values { ProcessRunner.terminate(p) }
    }
}

struct MCPToolAdapter: Tool {
    let server: String
    let tool: MCP.Tool
    let manager: MCPManager

    var name: String {
        let safe = { (s: String) in s.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression) }
        return "mcp__\(safe(server))__\(safe(tool.name))".truncated(64, marker: "")
    }
    var description: String { (tool.description ?? tool.name).truncated(1024, marker: "…") }
    var inputSchema: JSON { tool.inputSchema }

    func effect(for input: JSON) -> ToolEffect {
        tool.annotations.readOnlyHint == true ? .readOnly : .external
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let (text, isError, images) = try await manager.call(server: server, tool: tool.name, args: input.objectValue ?? [:])
        return ToolOutput(text, isError: isError, images: images)
    }
}

/// Scientific MCP servers SieveSci can connect in one step. Only configurations taken from each
/// project's own documentation; connecting writes the entry into `~/.sievesci/mcp.json` next to any
/// servers already there, and takes effect from the next session.
public enum ScienceConnectors {
    public struct Connector: Sendable {
        public var id: String
        public var title: String
        public var license: String
        public var source: String
        public var notes: String
        public var requires: String
        public var command: String
        public var args: [String]
        public var env: [String: String]
    }

    public static let all: [Connector] = [
        // github.com/mims-harvard/ToolUniverse README (Apache-2.0): `uvx tooluniverse` as a stdio server.
        Connector(id: "tooluniverse", title: "ToolUniverse (Harvard Zitnik Lab)", license: "Apache-2.0",
                  source: "https://github.com/mims-harvard/ToolUniverse",
                  notes: "600+ scientific tools behind one server: find a tool by describing it, then call it (literature, omics, drugs, targets, clinical, structures).",
                  requires: "uvx", command: "uvx", args: ["tooluniverse"], env: ["PYTHONIOENCODING": "utf-8"]),
    ]

    public static var userConfig: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/mcp.json") }

    public static func isConnected(_ id: String, config: URL = userConfig) -> Bool {
        guard let d = try? Data(contentsOf: config), let j = try? JSONCodec.parse(d) else { return false }
        return j["mcpServers"]?[id] != nil
    }

    /// Adds the connector to the MCP config, keeping every other server. Returns what to tell the user.
    @discardableResult
    public static func connect(_ id: String, config: URL = userConfig) throws -> String {
        guard let c = all.first(where: { $0.id == id }) else {
            throw ToolError.invalidInput("Unknown connector \(id). Available: \(all.map(\.id).joined(separator: ", "))")
        }
        var root: [String: JSON] = [:]
        if let d = try? Data(contentsOf: config), let j = try? JSONCodec.parse(d), let o = j.objectValue { root = o }
        var servers = root["mcpServers"]?.objectValue ?? [:]
        servers[c.id] = ["command": .string(c.command), "args": .array(c.args.map { .string($0) }),
                         "env": .object(c.env.mapValues { .string($0) })]
        root["mcpServers"] = .object(servers)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(JSONCodec.pretty(.object(root)).utf8).write(to: config, options: .atomic)
        let missing = ProcessRunner.which(c.requires) == nil
        return "Connected \(c.title) in \(config.path). It starts with the next session." +
            (missing ? " It needs `\(c.requires)` (install uv: https://docs.astral.sh/uv/)." : "")
    }
}
