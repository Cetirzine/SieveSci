import Foundation

/// From the saved configuration to running models and session settings — the part of the macOS app's
/// `AppModel` that every front end needs (the app itself and `sievesci serve`).
public enum ConfiguredModels {
    /// Enabled, and either signed in (CLI agents found on PATH) or holding an API key.
    public static func isUsable(_ p: ProviderProfile, secrets: SecretStore) -> Bool {
        p.enabled && (p.family == .cliAgent ? ProcessRunner.which(p.executable ?? "") != nil : secrets.secret(for: p.apiKeyRef) != nil)
    }

    public static func usable(_ c: AppConfig, secrets: SecretStore) -> [ProviderProfile] {
        c.providers.filter { isUsable($0, secrets: secrets) }
    }

    public static func candidates(_ c: AppConfig, secrets: SecretStore) -> [RoleModelAdvisor.Candidate] {
        usable(c, secrets: secrets).flatMap { p in p.models.map { (p, $0, nil as String?) } }
    }

    public static func provider(_ ref: ModelRef, config c: AppConfig, secrets: SecretStore) -> (LLMProvider, String)? {
        guard let p = c.providers.first(where: { $0.id == ref.providerId }),
              let llm = try? ProviderFactory.make(p, secrets: secrets) else { return nil }
        return (llm, ref.model)
    }

    /// The model for each role, as configured (same for all, by benchmark, or custom), with a pool of
    /// alternates for a second reviewer when one declines or fails.
    public static func roleModels(_ c: AppConfig, secrets: SecretStore) throws -> RoleModels {
        let resolved = RoleModelAdvisor.resolve(c.roles, candidates: candidates(c, secrets: secrets))
        guard let mainRef = resolved[.main], let main = provider(mainRef, config: c, secrets: secrets) else {
            throw ProviderError.missingAPIKey(L("Add a provider with an API key (Settings → Providers), or sign in to Claude Code / Codex / Gemini CLI."))
        }
        func pick(_ r: AgentRole) -> (LLMProvider, String)? { resolved[r].flatMap { provider($0, config: c, secrets: secrets) } }
        var rm = RoleModels(main: main, checker: pick(.checker), verifier: pick(.verifier), worker: pick(.worker))
        rm.alternates = usable(c, secrets: secrets).compactMap { p in
            let m = p.defaultModel.isEmpty ? p.models.first : p.defaultModel
            return m.flatMap { provider(ModelRef(providerId: p.id, model: $0), config: c, secrets: secrets) }
        }
        return rm
    }

    /// New services for a task, with every session setting from the configuration applied.
    public static func services(task: String, workspace: URL, config c: AppConfig, secrets: SecretStore) throws -> SessionServices {
        let s = try SessionServices(taskId: task, workspace: workspace, models: try roleModels(c, secrets: secrets), secrets: secrets,
                                    webSearch: c.webSearch, permissionMode: c.permissionMode, contactEmail: c.contactEmail, retention: c.retention)
        apply(c, to: s, secrets: secrets)
        return s
    }

    public static func apply(_ c: AppConfig, to s: SessionServices, secrets: SecretStore) {
        s.research.groundingRequired = c.groundingRequired
        s.library.downloadPDFs = c.downloadOAPDFs
        s.effort = c.effort
        s.sandboxMode = c.sandboxMode
        s.supervisorPolicy.maxReviewsPerSession = c.maxReviewsPerSession
        s.deliberation.policy.maxExchanges = c.maxDeliberationExchanges
        s.delegation.auto = c.autoDelegate
        s.delegation.maxParallel = max(1, c.maxParallelWorkers)
        s.ideas.autoAllowed = c.autoBrainstorm
        if let v = c.visionHelper { s.vision.helper = provider(v, config: c, secrets: secrets) }
    }

    /// Welcome checklist: which models are ready, in plain words.
    public static func modelStatus(_ c: AppConfig, secrets: SecretStore) -> (ready: Bool, text: String) {
        let ready = usable(c, secrets: secrets)
        guard !ready.isEmpty else {
            return (false, L("An API key (DeepSeek, Anthropic, OpenAI, Gemini, GLM …), a relay, or a signed-in Claude Code / Codex / Gemini CLI."))
        }
        let names = ready.prefix(3).map { $0.family == .cliAgent ? L10n.s("%@ — found on this Mac", $0.displayName) : $0.displayName }
        return (true, L10n.s("Ready: %@", names.joined(separator: ", ") + (ready.count > 3 ? " …" : "")))
    }

    /// Welcome checklist: how web search will work right now.
    public static func searchStatus(_ c: AppConfig, secrets: SecretStore) -> (ready: Bool, text: String) {
        for p in usable(c, secrets: secrets) {
            let m = p.defaultModel.isEmpty ? (p.models.first ?? "") : p.defaultModel
            if NativeWebSearch.forProfile(p, model: m, secrets: secrets) != nil { return (true, L10n.s("Built into %@.", p.displayName)) }
        }
        let client = WebSearchClient(config: c.webSearch, secrets: secrets)
        switch client.effectiveBackend {
        case .duckduckgo where c.webSearch.backend != .duckduckgo:
            return (false, L("Works now with DuckDuckGo (best effort, may be rate-limited). Add a Brave, Tavily or Exa key for reliable results."))
        case .duckduckgo: return (true, L("DuckDuckGo (best effort, may be rate-limited)."))
        case .searxng: return (true, L10n.s("SearXNG at %@.", c.webSearch.searxngURL))
        case let b: return (true, L10n.s("%@ search API.", b.rawValue.capitalized))
        }
    }
}

extension AppConfig {
    /// Every built-in provider preset: all of them on first launch (enabled only once a key is
    /// present), and presets added in later versions joining an existing configuration. Renamed
    /// presets keep the user's edits but take the current name and notes.
    public mutating func addPresets() {
        if providers.isEmpty { providers = ProviderPresets.all; return }
        let known = Set(providers.map(\.id))
        let added = ProviderPresets.all.filter { !known.contains($0.id) }
        if !added.isEmpty { providers += added }
        for (i, p) in providers.enumerated() {
            if let preset = ProviderPresets.profile(id: p.id), preset.notes != p.notes, p.family == preset.family {
                providers[i].notes = preset.notes
                if p.displayName.hasPrefix("Gemini CLI") { providers[i].displayName = preset.displayName }
            }
        }
    }
}
