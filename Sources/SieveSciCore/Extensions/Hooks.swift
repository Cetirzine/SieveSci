import Foundation

/// Command hooks with Claude Code's configuration shape and exit-code contract, so existing hook
/// scripts work unchanged:
///   { "hooks": { "PreToolUse": [ { "matcher": "bash|python", "hooks": [ { "type": "command", "command": "..." } ] } ] } }
/// Read from `<workspace>/.sievesci/settings.json`, `<workspace>/.claude/settings.json` and
/// `~/.sievesci/settings.json`. The hook gets the event payload as JSON on stdin.
/// Exit 0 → continue (stdout becomes added context for UserPromptSubmit/SessionStart);
/// exit 2 → block, stderr is the reason; JSON stdout `{"decision":"block","reason":...}` also blocks.
public final class HookRunner: @unchecked Sendable {
    public enum Event: String, CaseIterable, Sendable {
        case preToolUse = "PreToolUse", postToolUse = "PostToolUse", userPromptSubmit = "UserPromptSubmit"
        case stop = "Stop", sessionStart = "SessionStart", preCompact = "PreCompact", notification = "Notification"
    }

    public struct Result: Sendable { public var blocked: Bool; public var message: String }

    let workspace: URL
    public init(workspace: URL) { self.workspace = workspace }

    struct Entry { var matcher: String?; var command: String; var timeout: Double }

    func entries(for event: Event) -> [Entry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let files = [workspace.appendingPathComponent(".sievesci/settings.json"), workspace.appendingPathComponent(".claude/settings.json"),
                     home.appendingPathComponent(".sievesci/settings.json")]
        var out: [Entry] = []
        for f in files {
            guard let d = try? Data(contentsOf: f), let j = try? JSONCodec.parse(d) else { continue }
            for group in j["hooks"]?[event.rawValue]?.arrayValue ?? [] {
                for h in group["hooks"]?.arrayValue ?? [] where h.str("type") == "command" {
                    if let c = h.str("command") {
                        out.append(Entry(matcher: group.str("matcher"), command: c, timeout: h["timeout"]?.numberValue ?? 60))
                    }
                }
            }
        }
        return out
    }

    public func run(_ event: Event, payload: JSON, matcher target: String? = nil) async -> Result {
        let hooks = entries(for: event).filter { e in
            guard let m = e.matcher, !m.isEmpty, m != "*", let t = target else { return true }
            return t.range(of: "^(?:\(m))$", options: .regularExpression) != nil
        }
        guard !hooks.isEmpty else { return Result(blocked: false, message: "") }
        var messages: [String] = []
        let input = payload.setting("hook_event_name", .string(event.rawValue)).setting("cwd", .string(workspace.path)).canonical
        for h in hooks {
            guard let r = try? await ProcessRunner.run("/bin/sh", ["-c", h.command], cwd: workspace, stdin: input, timeout: h.timeout) else { continue }
            if r.exitCode == 2 { return Result(blocked: true, message: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let j = try? JSONCodec.parse(r.stdout), j.str("decision") == "block" {
                return Result(blocked: true, message: j.str("reason") ?? "")
            }
            let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty { messages.append(out) }
        }
        return Result(blocked: false, message: messages.joined(separator: "\n"))
    }
}
