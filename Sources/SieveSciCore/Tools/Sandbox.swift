import Foundation

/// macOS Seatbelt sandbox for agent-run shell commands and the Python kernel, built on the policies
/// from OpenAI Codex (`codex-rs/sandboxing`, Apache-2.0; see THIRD_PARTY_NOTICES.md).
///
/// Policy = Codex base policy (deny-by-default process/IPC rules) + read everywhere + write only
/// to the workspace (or the agent's own sandbox dir) and temp dirs + optional network. Two paths
/// are always write-protected, even inside the workspace: `.sievesci/` (audit log, receipts'
/// provenance, shadow git history) and `.git/` — so code an agent runs cannot rewrite the record
/// of what it did. The verifier's sandbox (inside `.sievesci/tasks/…/verify`) is re-allowed
/// explicitly for that agent only.
public enum SandboxMode: String, Codable, Sendable, CaseIterable {
    case off                    // no sandbox (Linux, or the user opted out)
    case workspaceWrite         // write workspace only; network allowed (default: research needs APIs)
    case workspaceWriteOffline  // write workspace only; no network (strict reproducibility)
}

public enum Seatbelt {
    static let executable = "/usr/bin/sandbox-exec"

    static func policyFile(_ name: String) -> String {
        guard let u = SieveSciResources.bundle.url(forResource: name, withExtension: "sbpl", subdirectory: "Resources/sandbox") else { return "" }
        return (try? String(contentsOf: u, encoding: .utf8)) ?? ""
    }

    public static var available: Bool {
        #if os(macOS)
        return FileManager.default.isExecutableFile(atPath: executable)
        #else
        return false
        #endif
    }

    /// Wraps `executable args` so it runs under the policy. Returns the original command when the
    /// sandbox is off or unavailable.
    ///
    /// `readHidden`: subtrees whose file *contents* (and directory listings) are unreadable, except
    /// under `readAllowed`. Used to blind the verifier: the workspace is hidden apart from its own
    /// sandbox and the declared raw data. Seatbelt applies the last matching rule, so the allow
    /// rules come after the deny rule.
    public static func wrap(_ exe: String, _ args: [String], mode: SandboxMode, writableRoots: [URL], protected: [URL],
                            readHidden: [URL] = [], readAllowed: [URL] = [], readRehidden: [URL] = []) -> (String, [String]) {
        guard mode != .off, available else { return (exe, args) }
        var params: [(String, String)] = []
        var writeRules: [String] = []
        for (i, root) in writableRoots.enumerated() {
            let key = "WRITABLE_ROOT_\(i)"
            params.append((key, FilePaths.canonical(root.path)))
            var excludes: [String] = []
            for (j, p) in protected.enumerated() where p.path.hasPrefix(root.path) {
                let pk = "\(key)_PROTECTED_\(j)"
                params.append((pk, FilePaths.canonical(p.path)))
                excludes.append("(require-not (subpath (param \"\(pk)\")))")
            }
            writeRules.append(excludes.isEmpty ? "(subpath (param \"\(key)\"))" : "(require-all (subpath (param \"\(key)\")) \(excludes.joined(separator: " ")))")
        }
        // Temp directories (TMPDIR lives under /private/var/folders on macOS).
        let tmp = ["/private/tmp", "/private/var/folders", ProcessInfo.processInfo.environment["TMPDIR"] ?? ""].filter { !$0.isEmpty }
        for (i, t) in tmp.enumerated() {
            params.append(("TMP_ROOT_\(i)", t))
            writeRules.append("(subpath (param \"TMP_ROOT_\(i)\"))")
        }
        var policy = policyFile("seatbelt_base_policy")
        policy += "\n; SieveSci: read anywhere, write only to the writable roots\n(allow file-read*)\n"
        policy += "(allow file-write*\n  " + writeRules.joined(separator: "\n  ") + ")\n"
        if !readHidden.isEmpty {
            var hide: [String] = [], allow: [String] = []
            for (i, u) in readHidden.enumerated() {
                params.append(("READ_HIDDEN_\(i)", FilePaths.canonical(u.path)))
                hide.append("(subpath (param \"READ_HIDDEN_\(i)\"))")
            }
            for (i, u) in readAllowed.enumerated() {
                params.append(("READ_ALLOWED_\(i)", FilePaths.canonical(u.path)))
                allow.append("(subpath (param \"READ_ALLOWED_\(i)\"))")
            }
            policy += "; SieveSci: blinded agent\n(deny file-read-data\n  " + hide.joined(separator: "\n  ") + ")\n"
            if !allow.isEmpty { policy += "(allow file-read-data\n  " + allow.joined(separator: "\n  ") + ")\n" }
            // Files the main agent wrote inside an allowed data directory stay hidden.
            var again: [String] = []
            for (i, u) in readRehidden.enumerated() {
                params.append(("READ_REHIDDEN_\(i)", FilePaths.canonical(u.path)))
                again.append("(subpath (param \"READ_REHIDDEN_\(i)\"))")
            }
            if !again.isEmpty { policy += "(deny file-read-data\n  " + again.joined(separator: "\n  ") + ")\n" }
        }
        if mode == .workspaceWrite { policy += policyFile("seatbelt_network_policy") + "\n(allow network-outbound)\n(allow network-inbound (local ip))\n" }
        let defs = params.map { "-D\($0.0)=\($0.1)" }
        return (executable, ["-p", policy] + defs + ["--", exe] + args)
    }
}
