import Foundation

/// The Settings pages' requests (docs/SERVE_PROTOCOL.md, "Settings"): what the SwiftUI settings
/// views compute with the core directly — provider status and models, key checks, quotas, catalogs,
/// role recommendations, connectors, memory, schedules — for a front end that only has the protocol.
extension ServeServer {
    func settingsDispatch(_ method: String, _ p: JSON) async throws -> JSON? {
        switch method {
        case "providers.discover":
            // Lists what the key (or signed-in CLI) can use; nothing is billed. A subscription CLI's own list
            // is the truth: its models become the profile's.
            let prof = try provider(p)
            let list = try await ModelDiscovery.list(prof, apiKey: secrets.secret(for: prof.apiKeyRef))
            if prof.family == .cliAgent, !list.isEmpty {
                var c = lock.withLock { config }
                if let i = c.providers.firstIndex(where: { $0.id == prof.id }) {
                    c.providers[i].models = list.map(\.id)
                    if !c.providers[i].models.contains(c.providers[i].defaultModel) { c.providers[i].defaultModel = "default" }
                    try updateConfig(["providers": Wire.value(c.providers)])
                }
            }
            var r = configPayload().objectValue ?? [:]
            r["models"] = .array(list.map { d in
                let st = ModelDiscovery.effectiveSettings(model: d.id, profile: prof, discovered: d)
                return ["id": .string(d.id), "displayName": d.displayName.map { .string($0) } ?? .null,
                        "contextWindow": d.contextWindow.map { .int($0) } ?? .null,
                        "supportsImages": .bool(st.supportsImages), "supportsReasoning": .bool(st.supportsReasoning)]
            })
            return .object(r)

        case "providers.test":
            return ["status": .string(await testConnection(try provider(p)))]

        case "providers.quota":
            let prof = try provider(p)
            return Self.quotaJSON(await QuotaService.shared.refresh(prof, secrets: secrets))
        case "providers.quotas":
            var out: [String: JSON] = [:]
            for prof in ConfiguredModels.usable(lock.withLock { config }, secrets: secrets) where out[prof.id] == nil {
                out[prof.id] = Self.quotaJSON(await QuotaService.shared.refresh(prof, secrets: secrets))
            }
            return ["quotas": .object(out)]

        case "providers.catalog":
            let presets: [JSON] = ProviderPresets.all.map { pr in
                ["id": .string(pr.id), "title": .string(pr.displayName), "detail": .string(Self.formatName(pr.family) + " · " + pr.baseURL)]
            }
            let endpoints: [JSON] = ProviderCatalog.shared.entries.map { e in
                ["id": .string(e.id), "title": .string("\(e.vendor) · \(e.region) · \(e.plan)"),
                 "detail": .string(e.routes.keys.map(Self.formatName).sorted().joined(separator: ", "))]
            }
            let dev: [JSON] = ModelsDevCatalog.shared.providers.values.filter { $0.api != nil }.sorted { $0.name < $1.name }.map { mp in
                ["id": .string(mp.id), "title": .string(mp.name), "detail": .string((mp.api ?? "") + " · " + L10n.f("%d models", mp.models.count))]
            }
            return ["presets": .array(presets), "endpoints": .array(endpoints), "modelsDev": .array(dev)]

        case "providers.add":
            var prof = try newProvider(p)
            var c = lock.withLock { config }
            if c.providers.contains(where: { $0.id == prof.id }) { prof.id += "-" + String(UUID().uuidString.prefix(4)).lowercased() }
            c.providers.append(prof)
            try updateConfig(["providers": Wire.value(c.providers)])
            var r = configPayload().objectValue ?? [:]
            r["id"] = .string(prof.id)
            return .object(r)

        case "providers.detectOptions":
            guard let f = p.str("family").flatMap(ProviderFamily.init(rawValue:)) else { throw RPCError(code: -32602, message: "family is required") }
            return ["options": Wire.value(ProviderOptions.detected(family: f, baseURL: p.str("baseURL") ?? ""))]

        case "models.overview":
            let c = lock.withLock { config }
            let cands = ConfiguredModels.candidates(c, secrets: secrets)
            let resolved = RoleModelAdvisor.resolve(c.roles, candidates: cands)
            let recs = RoleModelAdvisor.recommend(candidates: cands)
            var roles: [String: JSON] = [:]
            for role in AgentRole.allCases {
                roles[role.rawValue] = ["model": resolved[role].map { Wire.value($0) } ?? .null,
                                        "reasons": .string(recs.first { $0.role == role }?.reasons.joined(separator: " · ") ?? "")]
            }
            let vision: [JSON] = ConfiguredModels.usable(c, secrets: secrets).flatMap { pr in
                pr.models.filter { ModelDiscovery.effectiveSettings(model: $0, profile: pr, discovered: nil).supportsImages }
                    .map { Wire.value(ModelRef(providerId: pr.id, model: $0)) }
            }
            let bench = BenchmarkSnapshot.current().benchmarks.sorted { $0.key < $1.key }.map { _, b -> JSON in
                ["title": .string(b.title), "asOf": .string(b.asOf), "source": .string(b.source)]
            }
            return ["roles": .object(roles), "vision": .array(vision), "benchmarks": .array(bench)]
        case "models.refreshCatalogs":
            let main = try? ConfiguredModels.roleModels(lock.withLock { config }, secrets: secrets).main
            let r = await CatalogRefresher.refreshAll(extractor: main?.0, extractorModel: main?.1)
            return ["report": .string(r.lines.joined(separator: "\n"))]

        case "connectors.list":
            return ["connectors": .array(ScienceConnectors.all.map { c in
                ["id": .string(c.id), "title": .string(c.title), "license": .string(c.license), "notes": .string(c.notes),
                 "source": .string(c.source), "connected": .bool(ScienceConnectors.isConnected(c.id))]
            })]
        case "connectors.connect":
            guard let id = p.str("id") else { throw RPCError(code: -32602, message: "id is required") }
            return ["message": .string(try ScienceConnectors.connect(id))]

        case "memory.list":
            let role = p.str("role").flatMap(AgentRole.init(rawValue:)) ?? .main
            let store = MemoryStore(dir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/memory/\(role.rawValue)"))
            let pending = lock.withLock { currentKey.flatMap { live[$0] } }?.bench.services.governor.proposals.filter { $0.status == .pending }.count ?? 0
            return ["dir": .string(store.dir.path),
                    "learnedSkills": .string(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/learned-skills").path),
                    "stores": .object(Dictionary(uniqueKeysWithValues: MemoryStore.Store.allCases.map { ($0.rawValue, JSON.array(store.entries($0).map { .string($0) })) })),
                    "pendingProposals": .int(pending)]

        case "schedules.list":
            return ["schedules": Wire.value(Scheduler.list())]
        case "schedules.add":
            guard let when = p.str("when"), let prompt = p.str("prompt"), !prompt.isEmpty else { throw RPCError(code: -32602, message: "when and prompt are required") }
            let (ws, _) = try target(p)
            return ["message": .string(await Scheduler.add(workspace: ws, when: when, prompt: prompt)), "schedules": Wire.value(Scheduler.list())]
        case "schedules.remove":
            guard let id = p.str("id") else { throw RPCError(code: -32602, message: "id is required") }
            return ["message": .string(await Scheduler.remove(id)), "schedules": Wire.value(Scheduler.list())]

        case "system.open":
            // A folder, file or web page in the system's own app (Finder / Explorer, the browser).
            guard let target = p.str("url") ?? p.str("path"), !target.isEmpty else { throw RPCError(code: -32602, message: "path or url is required") }
            if p.str("url") != nil {
                guard let u = URL(string: target), u.scheme == "https" || u.scheme == "http" else { throw RPCError(code: -32602, message: "only web links can be opened") }
            } else if p.str("path") != nil, p["reveal"]?.boolValue != true, (target as NSString).pathExtension.isEmpty {
                try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
            }
            // `reveal`: show the file selected in Finder / Explorer instead of opening it.
            let reveal = p["reveal"]?.boolValue == true && p.str("path") != nil
            #if os(macOS)
            _ = try await ProcessRunner.run("/usr/bin/open", reveal ? ["-R", target] : [target], timeout: 10)
            #elseif os(Windows)
            _ = try await ProcessRunner.run("explorer.exe", reveal ? ["/select,", target] : [target], timeout: 10)
            #else
            _ = try await ProcessRunner.run("xdg-open", [reveal ? URL(fileURLWithPath: target).deletingLastPathComponent().path : target], timeout: 10)
            #endif
            return .object([:])

        case "agents.install":
            // The provider's CLI agent, from its vendor's own installer; output streams as `agentInstall`.
            let prof = try provider(p)
            guard prof.family == .cliAgent, let exe = prof.executable else { throw RPCError(code: -32602, message: "not a CLI agent") }
            let id = prof.id
            let r = await AgentInstaller.install(exe) { [weak self] lines in
                self?.notify("agentInstall", ["id": .string(id), "lines": .array(lines.map { .string($0) })])
            }
            var out = configPayload().objectValue ?? [:]
            out["ok"] = .bool(r.ok); out["message"] = .string(r.message)
            return .object(out)
        case "agents.signIn":
            let prof = try provider(p)
            guard let exe = prof.executable else { throw RPCError(code: -32602, message: "not a CLI agent") }
            return ["message": .string(await AgentInstaller.openSignIn(exe))]
        case "cli.install":
            return ["message": .string(Self.installCLI())]

        case "updates.check":
            return try await Self.latestRelease()

        default:
            return nil
        }
    }

    func provider(_ p: JSON) throws -> ProviderProfile {
        guard let id = p.str("id"), let prof = lock.withLock({ config.providers.first { $0.id == id } }) else {
            throw RPCError(code: -32602, message: "no provider \(p.str("id") ?? "")")
        }
        return prof
    }

    /// What a provider needs before it can be used, in plain words (the app's ProviderStatus), with the
    /// settings of each of its models.
    func providerInfo(_ c: AppConfig) -> JSON {
        var out: [String: JSON] = [:]
        for prof in c.providers {
            var ready = false, short: String, path: String? = nil
            if !prof.enabled {
                short = L("Turned off")
            } else if prof.family == .cliAgent {
                path = ProcessRunner.which(prof.executable ?? "")
                ready = path != nil
                #if os(macOS)
                short = ready ? L("Found on this Mac — uses your sign-in") : L("CLI not installed")
                #else
                short = ready ? L("Found on this computer — uses your sign-in") : L("CLI not installed")
                #endif
            } else {
                ready = secrets.secret(for: prof.apiKeyRef) != nil
                short = ready ? L("Ready") : (prof.billing == "relay" || prof.billing == "local" ? L("Needs a URL and key") : L("Needs an API key"))
            }
            var models: [String: JSON] = [:]
            for m in prof.models {
                let st = ModelDiscovery.effectiveSettings(model: m, profile: prof, discovered: nil)
                // What the catalogs and the provider's listing say, for "Reset" next to the user's own values.
                var plain = prof
                plain.modelSettings.removeAll { $0.id == m }
                let detected = ModelDiscovery.effectiveSettings(model: m, profile: plain, discovered: nil)
                models[m] = ["contextWindow": .int(st.contextWindow), "maxOutput": .int(st.maxOutput), "supportsImages": .bool(st.supportsImages),
                             "supportsReasoning": .bool(st.supportsReasoning), "custom": .bool(prof.modelSettings.contains { $0.id == m }),
                             "detected": Wire.value(detected)]
            }
            out[prof.id] = ["ready": .bool(ready), "short": .string(short), "cliPath": path.map { .string($0) } ?? .null,
                            "hasKey": .bool(secrets.secret(for: prof.apiKeyRef) != nil), "models": .object(models)]
        }
        return .object(out)
    }

    static func formatName(_ f: ProviderFamily) -> String {
        switch f {
        case .anthropic: return "Anthropic Messages"
        case .openaiResponses: return "OpenAI Responses"
        case .openaiChat: return "OpenAI Chat Completions"
        case .gemini: return "Gemini"
        case .cliAgent: return "CLI"
        }
    }

    static func quotaJSON(_ q: QuotaSnapshot) -> JSON {
        let iso = ISO8601DateFormatter()
        return ["plan": q.plan.map { .string($0) } ?? .null, "note": q.note.map { .string(L($0)) } ?? .null,
                "summary": QuotaText.summary(q).map { .string($0) } ?? .null,
                "meters": .array(q.meters.map { m in
                    ["title": .string(QuotaText.title(m)), "value": .string(QuotaText.value(m)),
                     "usedFraction": m.usedFraction.map { .double($0) } ?? .null, "exhausted": .bool(m.exhausted),
                     "resetsAt": m.resetsAt.map { .string(iso.string(from: $0)) } ?? .null]
                })]
    }

    /// AddProviderSheet: a preset, an endpoint-catalog entry, a models.dev provider, or a custom relay.
    func newProvider(_ p: JSON) throws -> ProviderProfile {
        let id = p.str("id") ?? ""
        switch p.str("source") {
        case "preset":
            guard let pr = ProviderPresets.profile(id: id) else { throw RPCError(code: -32602, message: "no preset \(id)") }
            return pr
        case "endpoint":
            guard let e = ProviderCatalog.shared.entries.first(where: { $0.id == id }), let pr = ProviderCatalog.shared.profile(for: e) else {
                throw RPCError(code: -32602, message: "no catalog entry \(id)")
            }
            return pr
        case "modelsDev":
            guard let mp = ModelsDevCatalog.shared.providers[id] else { throw RPCError(code: -32602, message: "no models.dev provider \(id)") }
            return ProviderProfile(id: mp.id, displayName: mp.name, family: .openaiChat, baseURL: mp.api ?? "", auth: .bearer,
                                   apiKeyRef: mp.env.first ?? mp.id.uppercased() + "_API_KEY", models: Array(mp.models.keys.sorted().prefix(30)))
        case "custom":
            let name = p.str("name") ?? "", url = p.str("baseURL") ?? ""
            guard !url.isEmpty else { throw RPCError(code: -32602, message: "baseURL is required") }
            let family = p.str("family").flatMap(ProviderFamily.init(rawValue:)) ?? .openaiChat
            let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
            let auth: AuthStyle = family == .anthropic ? .xApiKey : family == .gemini ? .googApiKey : .bearer
            return ProviderProfile(id: slug.isEmpty ? "relay" : slug, displayName: name.isEmpty ? "Relay" : name, family: family,
                                   baseURL: url, auth: auth, apiKeyRef: (slug.isEmpty ? "RELAY" : slug.uppercased().replacingOccurrences(of: "-", with: "_")) + "_API_KEY",
                                   models: [], billing: "relay", options: ProviderOptions.detected(family: family, baseURL: url))
        default:
            throw RPCError(code: -32602, message: "source must be preset, endpoint, modelsDev or custom")
        }
    }

    /// Two identical small requests: the first shows connectivity and latency, the second whether the
    /// provider's prefix cache answers (cached tokens > 0). Long enough to be cacheable everywhere.
    func testConnection(_ prof: ProviderProfile) async -> String {
        guard let llm = try? ProviderFactory.make(prof, secrets: secrets) else { return L("No API key.") }
        let m = prof.defaultModel.isEmpty ? (prof.models.first ?? "") : prof.defaultModel
        let filler = String(repeating: "SieveSci cache probe. ", count: 900)
        let req = LLMRequest(model: m, system: "Reply with the single word: ok. " + filler, tools: [], messages: [Message.user("ping")],
                             maxTokens: 16, cache: CacheHints(lineageKey: "probe-" + prof.id, retention: .short))
        var lines: [String] = []
        for i in 1...2 {
            let t0 = Date()
            do {
                let r = try await llm.complete(req)
                lines.append(L10n.f("Request %d: %.1fs · input %d · cached %d · output %d", i, Date().timeIntervalSince(t0), r.usage.input, r.usage.cacheRead, r.usage.output)
                             + (r.servedModel.map { " · \($0)" } ?? ""))
            } catch {
                lines.append(L10n.f("Request %d failed:", i) + " \(error.localizedDescription)")
                break
            }
        }
        _ = await QuotaService.shared.refresh(prof, secrets: secrets)
        return lines.joined(separator: "\n")
    }

    /// Puts this `sievesci` on the command line: a link in ~/.local/bin (no administrator rights);
    /// on Windows the folder to add to PATH.
    static func installCLI() -> String {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        #if os(Windows)
        return L10n.f("Add %@ to your PATH to run sievesci from a terminal.", exe.deletingLastPathComponent().path)
        #else
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let dst = bin.appendingPathComponent("sievesci")
        if dst.resolvingSymlinksInPath().path == exe.resolvingSymlinksInPath().path { return L10n.f("Linked %@ (make sure ~/.local/bin is on your PATH).", dst.path) }
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.createSymbolicLink(at: dst, withDestinationURL: exe) } catch { return error.localizedDescription }
        return L10n.f("Linked %@ (make sure ~/.local/bin is on your PATH).", dst.path)
        #endif
    }

    /// The newest release on GitHub (the desktop app installs it from the release page).
    static func latestRelease() async throws -> JSON {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/Cetirzine/SieveSci/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SieveSci/" + SieveSci.version, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let j = try? JSONCodec.parse(data) else {
            throw RPCError(code: -32000, message: L("Could not reach GitHub."))
        }
        let tag = (j.str("tag_name") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let newer = tag.compare(SieveSci.version, options: .numeric) == .orderedDescending
        return ["current": .string(SieveSci.version), "latest": .string(tag), "available": .bool(newer),
                "url": .string(j.str("html_url") ?? "https://github.com/Cetirzine/SieveSci/releases")]
    }
}
