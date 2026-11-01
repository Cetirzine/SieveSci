import AppKit
import Foundation
import SieveSciCore
import UserNotifications

/// macOS notifications for job events, finished turns and permission prompts. Only posted while
/// SieveSci is not the active app (in the foreground the transcript already shows them).
@MainActor
final class Notifier {
    private var authorized = false

    /// UNUserNotificationCenter needs a bundled app; a bare `swift run` binary has no bundle id.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            Task { @MainActor in self.authorized = ok }
        }
    }

    func post(title: String, body: String, id: String) {
        guard !NSApp.isActive else { return }
        guard available, authorized else {
            NSApp.requestUserAttention(.informationalRequest)
            return
        }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
}

/// `/doctor`: checks the tools and credentials research work depends on.
enum Doctor {
    @MainActor
    static func run(model: AppModel) async -> String {
        var lines: [String] = [L("SieveSci doctor")]
        func check(_ name: String, _ exe: String, _ args: [String] = ["--version"]) async {
            guard let path = ProcessRunner.which(exe) else { lines.append("✗ \(name): " + L("not found")); return }
            let r = try? await ProcessRunner.run(path, args, timeout: 15)
            let v = (r?.stdout.isEmpty == false ? r?.stdout : r?.stderr)?.split(separator: "\n").first.map(String.init) ?? ""
            lines.append("✓ \(name): \(v.prefix(80))")
        }
        await check("git", "git")
        await check("python3", "python3")
        await check("R", "Rscript")
        await check("pandoc", "pandoc")
        await check("Claude Code CLI", "claude")
        await check("Codex CLI", "codex")
        await check("Gemini CLI", "gemini")
        lines.append(Seatbelt.available ? "✓ " + L("Seatbelt sandbox available") : "✗ " + L("Seatbelt sandbox unavailable (commands run unsandboxed)"))
        let usable = model.usableProviders
        lines.append(usable.isEmpty ? "✗ " + L("No usable model provider") : "✓ " + L("Providers") + ": " + usable.map(\.displayName).joined(separator: ", "))
        let ws = model.config.webSearch
        let searchKey = ws.apiKeyRef.isEmpty || model.secrets.secret(for: ws.apiKeyRef) != nil
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
