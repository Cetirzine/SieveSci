import Foundation

/// One-click setup for the subscription CLI agents SieveSci drives (Claude Code, Codex, Antigravity,
/// Gemini CLI), without npm where the vendor ships a native build: each vendor's own installer script,
/// from its own domain, run headless; then a terminal opened on its sign-in command (sign-in happens in
/// the vendor's own browser flow, so SieveSci never sees the login).
public enum AgentInstaller {
    public struct Recipe: Sendable {
        public var executable: String
        /// The official installer, as a shell command (macOS / Linux) and a PowerShell command (Windows).
        public var unix: String?
        public var windows: String?
        public var env: [String: String] = [:]
        public var signIn: [String]
        public var source: String
    }

    public static let recipes: [String: Recipe] = [
        "claude": Recipe(executable: "claude", unix: "curl -fsSL https://claude.ai/install.sh | bash",
                         windows: "irm https://claude.ai/install.ps1 | iex", signIn: [], source: "claude.ai"),
        "codex": Recipe(executable: "codex", unix: "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
                        windows: "irm https://chatgpt.com/codex/install.ps1 | iex", env: ["CODEX_NON_INTERACTIVE": "1"],
                        signIn: ["login"], source: "chatgpt.com"),
        "agy": Recipe(executable: "agy", unix: "curl -fsSL https://antigravity.google/cli/install.sh | bash",
                      windows: "irm https://antigravity.google/cli/install.ps1 | iex", signIn: [], source: "antigravity.google"),
        // No native build exists for Gemini CLI: Homebrew or npm (Node.js 20+) when one is there.
        "gemini": Recipe(executable: "gemini", unix: nil, windows: nil, signIn: [], source: "github.com/google-gemini/gemini-cli"),
    ]

    /// Folders the official installers use, searched after PATH: the app's PATH predates an install made
    /// from it (Windows never refreshes a running process's PATH), and a shell profile may not list them.
    public static var installFolders: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #if os(Windows)
        let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? home + "\\AppData\\Local"
        let roaming = ProcessInfo.processInfo.environment["APPDATA"] ?? home + "\\AppData\\Roaming"
        return [home + "\\.local\\bin", local + "\\Programs\\OpenAI\\Codex\\bin", roaming + "\\npm"]
        #else
        return [home + "/.local/bin", home + "/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
        #endif
    }

    public struct Result: Sendable { public var ok: Bool; public var path: String?; public var message: String }

    /// Runs the vendor's installer; `onLines` gets its output as it arrives.
    public static func install(_ executable: String, onLines: (@Sendable ([String]) -> Void)? = nil) async -> Result {
        guard let r = recipes[executable] else { return Result(ok: false, path: nil, message: L10n.s("No installer for %@.", executable)) }
        let run: (exe: String, args: [String])
        #if os(Windows)
        if let cmd = r.windows {
            run = ("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", cmd])
        } else if ProcessRunner.which("npm") != nil {
            run = ("npm", ["install", "-g", "@google/gemini-cli"])
        } else {
            return Result(ok: false, path: nil, message: L("Gemini CLI needs Node.js 20 or newer (there is no standalone build). Install Node.js from nodejs.org, then click Install again."))
        }
        #else
        if let cmd = r.unix {
            run = ("bash", ["-c", cmd])
        } else if ProcessRunner.which("brew") != nil {
            run = ("brew", ["install", "gemini-cli"])
        } else if ProcessRunner.which("npm") != nil {
            run = ("npm", ["install", "-g", "@google/gemini-cli"])
        } else {
            return Result(ok: false, path: nil, message: L("Gemini CLI needs Node.js 20 or newer (there is no standalone build). Install Node.js from nodejs.org, then click Install again."))
        }
        #endif
        do {
            let res = try await ProcessRunner.run(run.exe, run.args, env: r.env, timeout: 900, onLines: onLines)
            let path = ProcessRunner.which(executable)
            if res.exitCode == 0, let path { return Result(ok: true, path: path, message: L10n.s("Installed %@.", path)) }
            let tail = (res.stderr.isEmpty ? res.stdout : res.stderr).split(separator: "\n").suffix(4).joined(separator: "\n")
            return Result(ok: false, path: path, message: L("The installer did not finish:") + " " + tail)
        } catch {
            return Result(ok: false, path: nil, message: L("The installer did not finish:") + " " + error.localizedDescription)
        }
    }

    /// Opens a terminal window on the agent's sign-in command (its own browser login).
    public static func openSignIn(_ executable: String) async -> String {
        guard let path = ProcessRunner.which(executable) else { return L10n.s("%@ is not installed on this computer.", executable) }
        let args = recipes[executable]?.signIn ?? []
        #if os(macOS)
        let line = ([path] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let script = "tell application \"Terminal\" to do script \"\(line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"\ntell application \"Terminal\" to activate"
        let r = try? await ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 20)
        #elseif os(Windows)
        let inner = "& '" + path.replacingOccurrences(of: "'", with: "''") + "'" + args.map { " " + $0 }.joined()
        let r = try? await ProcessRunner.run("cmd.exe", ["/c", "start", "", "powershell.exe", "-NoExit", "-Command", inner], timeout: 20)
        #else
        let r = try? await ProcessRunner.run("x-terminal-emulator", ["-e", path] + args, timeout: 20)
        #endif
        return r?.exitCode == 0 ? L("A terminal opened for signing in. Finish there, then come back.")
                                : L("Could not open a terminal. Run the sign-in command yourself:") + " " + ([executable] + args).joined(separator: " ")
    }
}
