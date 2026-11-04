import Foundation

/// SieveSci's plugin for Antigravity CLI. agy cannot switch its built-in tools off per run, but a
/// plugin agent can list the tools it gets: the `sievesci` agent has only `finish` plus the plugin's
/// MCP server (the SieveSci bridge), so `agy --agent sievesci` can do nothing that bypasses SieveSci.
/// `sievesci-text` has no tools at all, for when the bridge is unavailable.
///
/// The plugin lives in `~/Library/Application Support/SieveSci/agy-plugin/sievesci` and is
/// (re)installed with `agy plugin install` whenever its content changes (e.g. the app moved).
public actor AgyPlugin {
    public static let shared = AgyPlugin()
    private var installed: String?

    static func files(bridge: [String]?) -> [String: String] {
        var f: [String: String] = [:]
        f["plugin.json"] = #"{"name": "sievesci", "displayName": "SieveSci", "version": "1.0.0", "description": "Agents restricted to SieveSci's tools (receipts, sandbox, permissions)."}"#
        // One plugin for every copy of SieveSci (the app, a development build, the CLI): the bridge is
        // whatever SIEVESCI_BRIDGE_EXE names in the environment SieveSci starts agy with. A plugin that
        // pointed at one copy was reinstalled by the next, and while `agy plugin install` runs the
        // `sievesci` agent does not exist, so agy fell back to its default agent and its own tools.
        _ = bridge
        let server: JSON = ["command": "/bin/sh",
                            "args": ["-c", "exec \"${SIEVESCI_BRIDGE_EXE:?started outside SieveSci}\" mcp-bridge"]]
        f["mcp_config.json"] = JSON.object(["mcpServers": ["sievesci": server]]).canonical
        func agent(_ name: String, mcp: Bool, body: String) -> String {
            """
            ---
            name: \(name)
            description: "SieveSci research agent. Its only tools are SieveSci's, served by the sievesci MCP server; it has no built-in shell, file or web tools."
            tools:
              - finish
            inheritMcp: \(mcp)
            mainAgent: true
            subagent: false
            ---
            # SieveSci agent

            \(body)
            """
        }
        f["agents/sievesci.md"] = agent(CLIAgentProvider.agyAgent, mcp: true, body: CLIHost.toolInstructions)
        f["agents/sievesci-text.md"] = agent(CLIAgentProvider.agyTextAgent, mcp: false, body: CLIHost.noToolsInstructions)
        return f
    }

    static var directory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("SieveSci/agy-plugin/sievesci")
    }

    /// Writes and installs the plugin unless the same content is already installed.
    func ensure(exe: String, bridge: [String]?) async throws {
        let files = Self.files(bridge: bridge)
        let stamp = Hashing.sha256Hex(files.sorted { $0.key < $1.key }.map { $0.key + "\n" + $0.value }.joined(separator: "\n--\n"))
        if installed == stamp { return }
        let dir = Self.directory, fm = FileManager.default
        let stampFile = dir.appendingPathComponent(".installed")
        let agents = (try? await ProcessRunner.run(exe, ["agents"], timeout: 60))?.stdout ?? ""
        let listed = agents.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp, listed.contains(CLIAgentProvider.agyAgent) {
            installed = stamp
            return
        }
        try? fm.removeItem(at: dir)
        for (path, text) in files {
            let u = dir.appendingPathComponent(path)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.writeReliably(to: u)
        }
        let r = try await ProcessRunner.run(exe, ["plugin", "install", dir.path], timeout: 120)
        let after = (try? await ProcessRunner.run(exe, ["agents"], timeout: 60))?.stdout ?? ""
        guard after.contains(CLIAgentProvider.agyAgent) else {
            throw ProviderError.protocolError(L10n.s("Could not install SieveSci's agent into Antigravity CLI, so it cannot be run without its own tools: %@", (r.stderr + r.stdout).truncated(400)))
        }
        try stamp.writeReliably(to: stampFile)
        installed = stamp
    }
}
