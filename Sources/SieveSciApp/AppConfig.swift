import Foundation
import SieveSciCore

/// Persisted app configuration (`~/Library/Application Support/SieveSci/config.json`).
/// Secrets are never stored here; they live in the macOS Keychain.
struct AppConfig: Codable, Equatable {
    enum Appearance: String, Codable, CaseIterable { case system, light, dark }

    var providers: [ProviderProfile] = []
    var roles = RoleAssignment()
    var webSearch = WebSearchConfig()
    var permissionMode: PermissionMode = .ask
    var retention: CacheRetention = .short
    var effort: Effort? = nil
    var contactEmail = ""
    var groundingRequired = true
    var visionHelper: ModelRef? = nil
    var recentWorkspaces: [String] = []
    var maxReviewsPerSession = 24
    var maxDeliberationExchanges = 2
    /// Run independent parts of a request or plan on workers without waiting for the model to call `task`.
    var autoDelegate = true
    var maxParallelWorkers = 3
    var sandboxMode: SandboxMode = .workspaceWrite
    var appearance: Appearance = .system
    /// Wake the agent when background jobs report (exit, watched line, error, stall).
    var autoWake = true
    var notifyJobs = true
    var notifyTurnFinished = true
    var notifyPermission = true
    var showThinking = true
    /// Look for a newer release on GitHub at launch and once a day.
    var autoCheckUpdates = true
    /// Download it in the background and install it on quit (or from the sidebar banner).
    var autoInstallUpdates = true

    static var url: URL {
        // SIEVESCI_CONFIG_DIR: a separate configuration (fresh-install checks, several profiles).
        let dir = ProcessInfo.processInfo.environment["SIEVESCI_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SieveSci")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() -> AppConfig {
        guard let d = try? Data(contentsOf: url) else { return AppConfig() }
        // Decode leniently so new fields never wipe an existing configuration.
        if let c = try? JSONDecoder().decode(AppConfig.self, from: d) { return c }
        var c = AppConfig()
        if let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let p = j["providers"], let pd = try? JSONSerialization.data(withJSONObject: p),
           let providers = try? JSONDecoder().decode([ProviderProfile].self, from: pd) {
            c.providers = providers
        }
        return c
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Self.url)
    }
}

extension AppConfig {
    init(from decoder: Decoder) throws {
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
        groundingRequired = v(.groundingRequired, d.groundingRequired)
        visionHelper = try? c.decodeIfPresent(ModelRef.self, forKey: .visionHelper)
        recentWorkspaces = v(.recentWorkspaces, d.recentWorkspaces)
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
        autoCheckUpdates = v(.autoCheckUpdates, d.autoCheckUpdates)
        autoInstallUpdates = v(.autoInstallUpdates, d.autoInstallUpdates)
    }
}
