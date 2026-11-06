import Foundation

/// Scheduled tasks (after Goose's recipes schedule and Hermes' cron): a recurring prompt that runs
/// headless (`sievesci -p`) in a workspace, even when the app is closed, and survives reboots:
/// - macOS: a per-user LaunchAgent (`~/Library/LaunchAgents/app.sievesci.schedule.<id>.plist`);
/// - Windows: a task in Task Scheduler (`\SieveSci\<id>`) running `sievesci run-schedule <id>`;
/// - Linux and other Unixes: a line in the user's crontab, tagged so it can be removed again.
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
        try? enc.encode(ts).writeReliably(to: registry)
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

    /// The cron line for a schedule: `sievesci run-schedule <id>`, tagged with the schedule's id.
    static func cronLine(_ t: ScheduledTask, cli: String) -> String? {
        guard let timing = launchdTiming(t.when) else { return nil }
        let spec: String
        if let c = timing.calendar {
            spec = "\(c["Minute"] ?? 0) \(c["Hour"] ?? 0) * * " + (c["Weekday"].map(String.init) ?? "*")
        } else {
            let i = timing.interval ?? 3600
            spec = i % 3600 == 0 ? (i == 3600 ? "0 * * * *" : "0 */\(i / 3600) * * *") : "*/\(i / 60) * * * *"
        }
        let log = logsDir.appendingPathComponent("\(t.id).log").path
        return "\(spec) \(shellQuote(cli)) run-schedule \(t.id) >> \(shellQuote(log)) 2>&1 \(cronTag)\(t.id)"
    }

    static let cronTag = "# sievesci-schedule "

    /// Task Scheduler arguments (`schtasks /Create`) for a schedule.
    static func schtasksArgs(_ t: ScheduledTask, cli: String) -> [String]? {
        guard let timing = launchdTiming(t.when) else { return nil }
        let log = logsDir.appendingPathComponent("\(t.id).log").path
        var a = ["/Create", "/F", "/TN", "SieveSci\\" + t.id, "/TR", "cmd.exe /c \"\"\(cli)\" run-schedule \(t.id) >> \"\(log)\" 2>&1\""]
        if let c = timing.calendar {
            let time = String(format: "%02d:%02d", c["Hour"] ?? 0, c["Minute"] ?? 0)
            if let d = c["Weekday"] {
                a += ["/SC", "WEEKLY", "/D", ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"][d], "/ST", time]
            } else {
                a += ["/SC", "DAILY", "/ST", time]
            }
        } else {
            let i = timing.interval ?? 3600
            a += i % 3600 == 0 ? ["/SC", "HOURLY", "/MO", String(i / 3600)] : ["/SC", "MINUTE", "/MO", String(i / 60)]
        }
        return a
    }

    /// Rewrites the user's crontab with `line` for the schedule (nil removes it). Returns an error text.
    static func updateCrontab(id: String, line: String?) async -> String? {
        let current = (try? await ProcessRunner.run("crontab", ["-l"], timeout: 30))
        // `crontab -l` fails when there is no crontab yet: that is an empty one.
        var lines = current?.exitCode == 0 ? current!.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) : []
        while lines.last?.isEmpty == true { lines.removeLast() }
        lines.removeAll { $0.hasSuffix(cronTag + id) }
        if let line { lines.append(line) }
        guard let r = try? await ProcessRunner.run("crontab", ["-"], stdin: lines.joined(separator: "\n") + "\n", timeout: 30) else {
            return L("crontab is not available.")
        }
        return r.exitCode == 0 ? nil : r.stderr.truncated(200)
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
        do { try data.writeReliably(to: url) } catch { return L10n.s("Could not write %@: %@", url.path, error.localizedDescription) }
        let r = try? await ProcessRunner.run("launchctl", ["bootstrap", "gui/\(getuid())", url.path], timeout: 30)
        save(list() + [t])
        return L10n.s("Scheduled %@: “%@” %@ in %@", t.id, prompt.truncated(80, marker: "…"), when, workspace.lastPathComponent)
            + (r?.exitCode == 0 ? "" : " " + L10n.s("(launchctl: %@; it will load at next login)", r?.stderr.truncated(200) ?? L("failed")))
            + "\n" + L10n.s("Logs: %@ · runs use permission mode %@ inside the sandbox.", "\(logsDir.path)/\(t.id).log", mode.rawValue)
        #elseif os(Windows)
        guard let args = schtasksArgs(t, cli: cli) else { return L("Could not build the scheduled task.") }
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let r = try? await ProcessRunner.run("schtasks.exe", args, timeout: 30)
        guard r?.exitCode == 0 else { return L10n.s("Task Scheduler refused the schedule: %@", (r.map { $0.stderr + $0.stdout } ?? L("failed")).truncated(200)) }
        save(list() + [t])
        return L10n.s("Scheduled %@: “%@” %@ in %@", t.id, prompt.truncated(80, marker: "…"), when, workspace.lastPathComponent)
            + "\n" + L10n.s("Logs: %@ · runs use permission mode %@ inside the sandbox.", logsDir.appendingPathComponent("\(t.id).log").path, mode.rawValue)
        #else
        guard let line = cronLine(t, cli: cli) else { return L("Could not build the scheduled task.") }
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        if let error = await updateCrontab(id: t.id, line: line) {
            return L10n.s("Could not add the schedule to your crontab (%@). Add this line with `crontab -e`:", error) + "\n" + line
        }
        save(list() + [t])
        return L10n.s("Scheduled %@: “%@” %@ in %@", t.id, prompt.truncated(80, marker: "…"), when, workspace.lastPathComponent)
            + "\n" + L10n.s("Logs: %@ · runs use permission mode %@ inside the sandbox.", logsDir.appendingPathComponent("\(t.id).log").path, mode.rawValue)
        #endif
    }

    public static func remove(_ id: String) async -> String {
        var ts = list()
        guard let i = ts.firstIndex(where: { $0.id == id }) else { return L10n.s("No schedule %@.", id) }
        ts.remove(at: i); save(ts)
        #if os(macOS)
        _ = try? await ProcessRunner.run("launchctl", ["bootout", "gui/\(getuid())/\(label + id)"], timeout: 30)
        try? FileManager.default.removeItem(at: agentsDir.appendingPathComponent(label + id + ".plist"))
        #elseif os(Windows)
        _ = try? await ProcessRunner.run("schtasks.exe", ["/Delete", "/F", "/TN", "SieveSci\\" + id], timeout: 30)
        #else
        _ = await updateCrontab(id: id, line: nil)
        #endif
        return L10n.s("Removed schedule %@.", id)
    }

    public static func describe() -> String {
        let ts = list()
        if ts.isEmpty { return L("No scheduled tasks. Usage: /schedule daily 08:30 <prompt> · /schedule remove <id>") }
        return ts.map { "\($0.id)  \($0.when)  \(URL(fileURLWithPath: $0.workspace).lastPathComponent)  “\($0.prompt.truncated(70, marker: "…"))”" }
            .joined(separator: "\n")
    }

    /// The command line a schedule runs with (`sievesci run-schedule <id>`), and where its output goes.
    public static func runArguments(_ id: String) -> (args: [String], log: URL)? {
        guard let t = list().first(where: { $0.id == id }) else { return nil }
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return (["--workspace", t.workspace, "--mode", t.mode ?? "auto", "-p", t.prompt], logsDir.appendingPathComponent("\(t.id).log"))
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
