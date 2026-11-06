import Foundation

/// Persisted app configuration, shared by every front end (the macOS app, `sievesci serve` and the UI
/// on top of it): `~/Library/Application Support/SieveSci/config.json` on macOS,
/// `%APPDATA%\SieveSci\config.json` on Windows, `~/.config/sievesci/config.json` elsewhere.
/// Secrets are never stored here; they live in the platform's credential store (`PlatformSecretStore`).
public struct AppConfig: Codable, Equatable, Sendable {
    public enum Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark }

    public init() {}

    public var providers: [ProviderProfile] = []
    public var roles = RoleAssignment()
    public var webSearch = WebSearchConfig()
    public var permissionMode: PermissionMode = .ask
    public var retention: CacheRetention = .short
    public var effort: Effort? = nil
    public var contactEmail = ""
    /// Save open-access PDFs of papers added to the library.
    public var downloadOAPDFs = true
    public var groundingRequired = true
    public var visionHelper: ModelRef? = nil
    public var recentWorkspaces: [String] = []
    /// Sidebar folders the user expanded or collapsed (path → open). A folder not listed is open only
    /// while it is the open workspace.
    public var folderOpen: [String: Bool] = [:]
    public var maxReviewsPerSession = 24
    public var maxDeliberationExchanges = 2
    /// Run independent parts of a request or plan on workers without waiting for the model to call `task`.
    public var autoDelegate = true
    public var maxParallelWorkers = 3
    public var sandboxMode: SandboxMode = .workspaceWrite
    public var appearance: Appearance = .system
    /// Wake the agent when background jobs report (exit, watched line, error, stall).
    public var autoWake = true
    public var notifyJobs = true
    public var notifyTurnFinished = true
    public var notifyPermission = true
    public var showThinking = true
    /// Name each conversation from its first exchange with the worker model (names given by hand stay).
    public var autoTitles = true
    /// Let the agent enter brainstorming mode on its own when the work needs new ideas.
    public var autoBrainstorm = true
    /// Look for a newer release on GitHub at launch and once a day.
    public var autoCheckUpdates = true
    /// Download it in the background and install it on quit (or from the sidebar banner).
    public var autoInstallUpdates = true

    /// The folder for the configuration and other per-user state.
    public static var directory: URL {
        // SIEVESCI_CONFIG_DIR: a separate configuration (fresh-install checks, several profiles).
        if let d = ProcessInfo.processInfo.environment["SIEVESCI_CONFIG_DIR"] { return URL(fileURLWithPath: d) }
        #if os(macOS)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SieveSci")
        #elseif os(Windows)
        let appData = ProcessInfo.processInfo.environment["APPDATA"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Roaming")
        return appData.appendingPathComponent("SieveSci")
        #else
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("sievesci")
        #endif
    }

    public static var url: URL {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    public static func load() -> AppConfig {
        guard let d = try? Data(contentsOf: url) else { return AppConfig() }
        // Decode leniently so new fields never wipe an existing configuration.
        if let c = try? JSONDecoder().decode(AppConfig.self, from: d) { return c.migrated() }
        var c = AppConfig()
        if let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let p = j["providers"], let pd = try? JSONSerialization.data(withJSONObject: p),
           let providers = try? JSONDecoder().decode([ProviderProfile].self, from: pd) {
            c.providers = providers
        }
        return c
    }

    /// A configuration saved by an earlier version, read with today's meaning. Before 0.2.5, auto mode
    /// with the sandbox off was how one ran without a sandbox or approvals; auto mode now always
    /// sandboxes, so that combination is YOLO mode.
    func migrated() -> AppConfig {
        var c = self
        if c.permissionMode == .auto && c.sandboxMode == .off { c.permissionMode = .yolo }
        return c
    }

    public func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.writeReliably(to: Self.url) }
    }
}

extension AppConfig {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        providers = v(.providers, d.providers)
        roles = v(.roles, d.roles)
        webSearch = v(.webSearch, d.webSearch)
        permissionMode = v(.permissionMode, d.permissionMode)
        retention = v(.retention, d.retention)
        effort = try? c.decodeIfPresent(Effort.self, forKey: .effort)
        contactEmail = v(.contactEmail, d.contactEmail)
        downloadOAPDFs = v(.downloadOAPDFs, d.downloadOAPDFs)
        groundingRequired = v(.groundingRequired, d.groundingRequired)
        visionHelper = try? c.decodeIfPresent(ModelRef.self, forKey: .visionHelper)
        recentWorkspaces = v(.recentWorkspaces, d.recentWorkspaces)
        folderOpen = v(.folderOpen, d.folderOpen)
        maxReviewsPerSession = v(.maxReviewsPerSession, d.maxReviewsPerSession)
        maxDeliberationExchanges = v(.maxDeliberationExchanges, d.maxDeliberationExchanges)
        autoDelegate = v(.autoDelegate, d.autoDelegate)
        maxParallelWorkers = v(.maxParallelWorkers, d.maxParallelWorkers)
        sandboxMode = v(.sandboxMode, d.sandboxMode)
        appearance = v(.appearance, d.appearance)
        autoWake = v(.autoWake, d.autoWake)
        notifyJobs = v(.notifyJobs, d.notifyJobs)
        notifyTurnFinished = v(.notifyTurnFinished, d.notifyTurnFinished)
        notifyPermission = v(.notifyPermission, d.notifyPermission)
        showThinking = v(.showThinking, d.showThinking)
        autoTitles = v(.autoTitles, d.autoTitles)
        autoBrainstorm = v(.autoBrainstorm, d.autoBrainstorm)
        autoCheckUpdates = v(.autoCheckUpdates, d.autoCheckUpdates)
        autoInstallUpdates = v(.autoInstallUpdates, d.autoInstallUpdates)
    }
}
