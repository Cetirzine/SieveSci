import Foundation

/// Scheduled tasks (after Goose's recipes schedule and Hermes' cron): a recurring prompt that runs
/// headless (`sievesci -p`) in a workspace. On macOS each schedule is a per-user LaunchAgent
/// (`~/Library/LaunchAgents/app.sievesci.schedule.<id>.plist`), so it runs even when the app is
/// closed and survives reboots; elsewhere the matching crontab line is printed for the user.
/// Every run writes its own task directory, audit log and notebook like an interactive session.
public struct ScheduledTask: Codable, Sendable, Equatable {
    public var id: String
    public var workspace: String
    public var prompt: String
    /// "daily 08:30", "weekly mon 09:00", "hourly", or "every 6h".
    public var when: String
    public var created: Date
    /// Permission mode of the run; nil = auto. Dreaming runs use plan (read-only).
    public var mode: String?

    public init(id: String, workspace: String, prompt: String, when: String, created: Date = Date(), mode: String? = nil) {
        self.id = id; self.workspace = workspace; self.prompt = prompt; self.when = when; self.created = created; self.mode = mode
    }
}

public enum Scheduler {
    public static let label = "app.sievesci.schedule."
    static var agentsDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents") }
    static var registry: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/schedules.json") }
    static var logsDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/schedule-logs") }

    public static func list() -> [ScheduledTask] {
        guard let d = try? Data(contentsOf: registry) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([ScheduledTask].self, from: d)) ?? []
    }

    static func save(_ ts: [ScheduledTask]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: registry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(ts).write(to: registry, options: .atomic)
    }

    /// Parses the schedule into launchd keys: either StartCalendarInterval or StartInterval.
    static func launchdTiming(_ when: String) -> (calendar: [String: Int]?, interval: Int?)? {
        let p = when.lowercased().split(separator: " ").map(String.init)
        func hm(_ s: String) -> (Int, Int)? {
            let x = s.split(separator: ":").compactMap { Int($0) }
            guard x.count == 2, (0..<24).contains(x[0]), (0..<60).contains(x[1]) else { return nil }
            return (x[0], x[1])
        }
        let days = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
        switch p.first {
        case "hourly": return (nil, 3600)
        case "every" where p.count == 2:
            let n = Int(p[1].dropLast()) ?? 0
            guard n > 0 else { return nil }
            if p[1].hasSuffix("h") { return (nil, n * 3600) }
            if p[1].hasSuffix("m"), n >= 15 { return (nil, n * 60) }
            return nil
        case "daily" where p.count == 2:
            guard let (h, m) = hm(p[1]) else { return nil }
            return (["Hour": h, "Minute": m], nil)
        case "weekly" where p.count == 3:
            guard let d = days[String(p[1].prefix(3))], let (h, m) = hm(p[2]) else { return nil }
            return (["Weekday": d, "Hour": h, "Minute": m], nil)
        default: return nil
        }
    }

    static func cronLine(_ t: ScheduledTask, cli: String) -> String {
        let p = t.when.lowercased().split(separator: " ").map(String.init)
        var spec = "0 * * * *"
        if p.first == "daily", p.count == 2 {
            let x = p[1].split(separator: ":"); spec = "\(x.last ?? "0") \(x.first ?? "0") * * *"
        } else if p.first == "weekly", p.count == 3 {
            let x = p[2].split(separator: ":"); spec = "\(x.last ?? "0") \(x.first ?? "0") * * \(p[1].prefix(3))"
        } else if p.first == "every", p.count == 2, p[1].hasSuffix("h") {
            spec = "0 */\(p[1].dropLast()) * * *"
        }
        return "\(spec) cd \(shellQuote(t.workspace)) && \(shellQuote(cli)) --mode \(t.mode ?? "auto") -p \(shellQuote(t.prompt))"
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func plist(_ t: ScheduledTask, cli: String) -> [String: Any]? {
        guard let timing = launchdTiming(t.when) else { return nil }
        var d: [String: Any] = [
            "Label": label + t.id,
            "ProgramArguments": [cli, "--workspace", t.workspace, "--mode", t.mode ?? "auto", "-p", t.prompt],
            "WorkingDirectory": t.workspace,
            "StandardOutPath": logsDir.appendingPathComponent("\(t.id).log").path,
            "StandardErrorPath": logsDir.appendingPathComponent("\(t.id).err").path,
            "EnvironmentVariables": ["PATH": ProcessRunner.loginEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"],
            "ProcessType": "Background",
        ]
        if let c = timing.calendar { d["StartCalendarInterval"] = c }
        if let i = timing.interval { d["StartInterval"] = i }
        return d
    }

    /// The headless CLI next to the running executable (app bundle or build dir), else on PATH.
    public static func cliPath() -> String? {
        let exe = URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent()
        for c in [exe.appendingPathComponent("sievesci-cli"), exe.appendingPathComponent("sievesci"),
                  exe.deletingLastPathComponent().appendingPathComponent("Resources/sievesci-cli")]
        where FileManager.default.isExecutableFile(atPath: c.path) { return c.path }
        return ProcessRunner.which("sievesci") ?? ProcessRunner.which("sievesci-cli")
    }

    /// Creates the schedule. Returns a message for the user.
    public static func add(workspace: URL, when: String, prompt: String, mode: PermissionMode = .auto) async -> String {
        guard launchdTiming(when) != nil else {
            return L10n.s("Unrecognised schedule “%@”. Use: daily HH:MM · weekly mon HH:MM · hourly · every 6h · every 30m (≥15m).", when)
        }
        guard let cli = cliPath() else { return L("Cannot find the sievesci CLI to run the schedule. Install it (Settings → General → Install command-line tool).") }
        let t = ScheduledTask(id: String(UUID().uuidString.prefix(8)).lowercased(), workspace: workspace.path, prompt: prompt, when: when, mode: mode == .auto ? nil : mode.rawValue)
        #if os(macOS)
        guard let p = plist(t, cli: cli),
              let data = try? PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0) else { return L("Could not build the LaunchAgent.") }
        try? FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let url = agentsDir.appendingPathComponent(label + t.id + ".plist")
        do { try data.write(to: url, options: .atomic) } catch { return L10n.s("Could not write %@: %@", url.path, error.localizedDescription) }
        let r = try? await ProcessRunner.run("launchctl", ["bootstrap", "gui/\(getuid())", url.path], timeout: 30)
        save(list() + [t])
        return L10n.s("Scheduled %@: “%@” %@ in %@", t.id, prompt.truncated(80, marker: "…"), when, workspace.lastPathComponent)
            + (r?.exitCode == 0 ? "" : " " + L10n.s("(launchctl: %@; it will load at next login)", r?.stderr.truncated(200) ?? L("failed")))
            + "\n" + L10n.s("Logs: %@ · runs use permission mode %@ inside the sandbox.", "\(logsDir.path)/\(t.id).log", mode.rawValue)
        #else
        save(list() + [t])
        return L("LaunchAgents are macOS-only. Add this line with `crontab -e`:") + "\n" + cronLine(t, cli: cli)
        #endif
    }

    public static func remove(_ id: String) async -> String {
        var ts = list()
        guard let i = ts.firstIndex(where: { $0.id == id }) else { return L10n.s("No schedule %@.", id) }
        ts.remove(at: i); save(ts)
        #if os(macOS)
        _ = try? await ProcessRunner.run("launchctl", ["bootout", "gui/\(getuid())/\(label + id)"], timeout: 30)
        try? FileManager.default.removeItem(at: agentsDir.appendingPathComponent(label + id + ".plist"))
        #endif
        return L10n.s("Removed schedule %@.", id)
    }

    public static func describe() -> String {
        let ts = list()
        if ts.isEmpty { return L("No scheduled tasks. Usage: /schedule daily 08:30 <prompt> · /schedule remove <id>") }
        return ts.map { "\($0.id)  \($0.when)  \(URL(fileURLWithPath: $0.workspace).lastPathComponent)  “\($0.prompt.truncated(70, marker: "…"))”" }
            .joined(separator: "\n")
    }

    /// Splits "daily 08:30 summarize new papers" into (when, prompt).
    public static func parse(_ args: String) -> (String, String)? {
        let w = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let f = w.first?.lowercased() else { return nil }
        let n: Int
        switch f {
        case "hourly": n = 1
        case "daily", "every": n = 2
        case "weekly": n = 3
        default: return nil
        }
        guard w.count > n else { return nil }
        return (w[0..<n].joined(separator: " "), w[n...].joined(separator: " "))
    }
}
