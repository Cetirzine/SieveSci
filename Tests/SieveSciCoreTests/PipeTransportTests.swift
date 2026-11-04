import Foundation
import Testing
@testable import SieveSciCore

/// The stdio MCP transport Windows uses, run against a real (tiny) server on every platform.
@Suite(.serialized) struct PipeMCP {
    static let server = #"""
    import json, sys
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        m = json.loads(line)
        if "id" not in m:
            continue
        method, mid = m.get("method"), m["id"]
        if method == "initialize":
            r = {"protocolVersion": m["params"]["protocolVersion"], "capabilities": {"tools": {}},
                 "serverInfo": {"name": "fake", "version": "1"}}
        elif method == "tools/list":
            r = {"tools": [{"name": "echo", "description": "Echo text.",
                            "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}]}
        elif method == "tools/call":
            r = {"content": [{"type": "text", "text": "echo:" + m["params"]["arguments"]["text"]}], "isError": False}
        else:
            r = {}
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": r}) + "\n")
        sys.stdout.flush()
    """#

    @Test func stdioServerOverPipes() async throws {
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("pipe-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }
        let script = ws.appendingPathComponent("server.py")
        try Self.server.write(to: script, atomically: true, encoding: .utf8)
        let config: JSON = ["mcpServers": ["fake": ["command": .string(Platform.python), "args": [.string(script.path)]]]]
        try JSONCodec.pretty(config).write(to: ws.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)

        MCPManager.forcePipeTransport = true
        defer { MCPManager.forcePipeTransport = false }
        let m = MCPManager(workspace: ws)
        let tools = await m.connectAll()
        #expect(m.status.first?.connected == true, "\(m.status)")
        #expect(tools.map(\.name).contains("mcp__fake__echo"))
        let (text, isError, _) = try await m.call(server: "fake", tool: "echo", args: ["text": .string("héllo")])
        #expect(text.contains("echo:héllo") && !isError)
        await m.shutdown()
    }
}
