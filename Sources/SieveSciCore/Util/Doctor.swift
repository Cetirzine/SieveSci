import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `/doctor`: checks the tools and credentials research work depends on. Shared by the macOS app and
/// `sievesci serve` (the desktop app), so both report the same lines.
public enum Doctor {
    public static func run(config: AppConfig, secrets: SecretStore) async -> String {
        var lines: [String] = [L("SieveSci doctor")]
        func check(_ name: String, _ exe: String, _ args: [String] = ["--version"]) async {
            guard let path = ProcessRunner.which(exe) else { lines.append("✗ \(name): " + L("not found")); return }
            let r = try? await ProcessRunner.run(path, args, timeout: 15)
            let v = (r?.stdout.isEmpty == false ? r?.stdout : r?.stderr)?.split(separator: "\n").first.map(String.init) ?? ""
            lines.append("✓ \(name): \(v.prefix(80))")
        }
        await check("git", "git")
        await check("python3", Platform.isWindows ? "python" : "python3")
        await check("R", "Rscript")
        await check("pandoc", "pandoc")
        await check("Claude Code CLI", "claude")
        await check("Codex CLI", "codex")
        await check("Gemini CLI", "gemini")
        lines.append(Seatbelt.available ? "✓ " + L("Seatbelt sandbox available") : "✗ " + L("Seatbelt sandbox unavailable (commands run unsandboxed)"))
        let usable = ConfiguredModels.usable(config, secrets: secrets)
        lines.append(usable.isEmpty ? "✗ " + L("No usable model provider") : "✓ " + L("Providers") + ": " + usable.map(\.displayName).joined(separator: ", "))
        let ws = config.webSearch
        let searchKey = ws.apiKeyRef.isEmpty || secrets.secret(for: ws.apiKeyRef) != nil
        lines.append(searchKey ? "✓ " + L("Web search") + ": \(ws.backend.rawValue)" : "✗ " + L("Web search key missing") + ": \(ws.apiKeyRef)")
        do {
            var req = URLRequest(url: URL(string: "https://api.openalex.org/works?per-page=1")!)
            req.timeoutInterval = 10
            let (_, resp) = try await URLSession.shared.data(for: req)
            lines.append("✓ OpenAlex: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        } catch {
            lines.append("✗ OpenAlex: \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }
}
