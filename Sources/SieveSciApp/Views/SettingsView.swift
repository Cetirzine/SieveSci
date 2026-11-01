import AppKit
import SieveSciCore
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, providers, models, search, research, memory, schedules
    var id: String { rawValue }
    static let storageKey = "settingsPane"

    var title: String {
        switch self {
        case .general: return L("General")
        case .providers: return L("Providers")
        case .models: return L("Models")
        case .search: return L("Web search")
        case .research: return L("Research")
        case .memory: return L("Memory & learning")
        case .schedules: return L("Schedules")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .providers: return "server.rack"
        case .models: return "cpu"
        case .search: return "globe"
        case .research: return "flask"
        case .memory: return "brain"
        case .schedules: return "calendar.badge.clock"
        }
    }
}

/// Settings as a full page inside the main window: navigation on the left, the pane's grouped form on the right.
struct SettingsPage: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(SettingsPane.storageKey) private var pane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Button { model.showSettingsPage = false } label: {
                    Label(L("Back to app"), systemImage: "chevron.left")
                        .font(Theme.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Space.s)
                        .frame(height: Theme.Control.row)
                }
                .buttonStyle(HoverRowStyle(radius: Theme.Radius.s + 2))
                .keyboardShortcut(.escape, modifiers: [])
                .padding(.top, 44)

                Text(L("Settings")).font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.top, Theme.Space.l)
                    .padding(.bottom, Theme.Space.m)

                ForEach(SettingsPane.allCases) { p in
                    Button { pane = p } label: {
                        HStack(spacing: Theme.Space.s + 2) {
                            Image(systemName: p.icon).font(.system(size: 13))
                                .foregroundStyle(pane == p ? Theme.accent : .secondary).frame(width: 18)
                            Text(p.title).font(Theme.body.weight(pane == p ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Theme.Space.s)
                        .frame(height: Theme.Control.row)
                        .background(Rectangle().fill(pane == p ? Theme.selection : .clear))
                        .overlay(alignment: .leading) { if pane == p { Rectangle().fill(Theme.accent).frame(width: 2) } }
                    }
                    .buttonStyle(HoverRowStyle(radius: 0))
                }
                Spacer()
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(width: 240)
            .background(Theme.sidebar)

            Rectangle().fill(Theme.separator).frame(width: 1)

            VStack(alignment: .leading, spacing: 0) {
                Text(pane.title).font(.system(size: 26, weight: .semibold)).tracking(-0.6)
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.top, 44)
                    .padding(.bottom, Theme.Space.xs)
                Group {
                    switch pane {
                    case .general: GeneralSettings()
                    case .providers: ProvidersSettings()
                    case .models: ModelsSettings()
                    case .search: SearchSettings()
                    case .research: ResearchSettings()
                    case .memory: MemorySettings()
                    case .schedules: ScheduleSettings()
                    }
                }
                .scrollContentBackground(.hidden)
                // Every settings button shares the app's button style (explicit link/plain styles still win).
                .buttonStyle(.action)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Theme.canvas)
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(AccentTheme.storageKey) private var accent = AccentTheme.blue.rawValue
    @State private var cliMessage = ""

    var body: some View {
        Form {
            Section(spec: L("Language")) {
                Picker(L("Interface language"), selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                    ForEach(L10n.Language.allCases) { Text($0.nativeName).tag($0) }
                }
                Text(L("Agents reply in the language you write in; the interface language is also passed to them as a hint."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(spec: L("Appearance")) {
                Picker(L("Theme"), selection: $model.config.appearance) {
                    Text(L("System")).tag(AppConfig.Appearance.system)
                    Text(L("Light")).tag(AppConfig.Appearance.light)
                    Text(L("Dark")).tag(AppConfig.Appearance.dark)
                }
                LabeledContent(L("Accent color")) {
                    HStack(spacing: Theme.Space.s + 2) {
                        ForEach(AccentTheme.allCases) { a in
                            Button { accent = a.rawValue } label: {
                                Rectangle().fill(a.color).frame(width: 18, height: 18)
                                    .padding(3)
                                    .overlay(Rectangle().strokeBorder(accent == a.rawValue ? a.color : .clear, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                            .help(a.name)
                        }
                    }
                }
                Toggle(L("Show thinking"), isOn: $model.config.showThinking)
            }
            Section(spec: L("Live monitoring")) {
                Toggle(L("Wake the agent when background jobs finish, fail, match a pattern or stall"), isOn: $model.config.autoWake)
                    .onChange(of: model.config.autoWake) { _, v in model.bench?.autoWake = v }
                Toggle(L("Notify me about job events"), isOn: $model.config.notifyJobs)
                Toggle(L("Notify me when a turn finishes (while SieveSci is in the background)"), isOn: $model.config.notifyTurnFinished)
                Toggle(L("Notify me when permission is needed"), isOn: $model.config.notifyPermission)
            }
            Section(spec: L("Identity")) {
                TextField(L("Contact email (polite pool for OpenAlex / Crossref / Unpaywall)"), text: $model.config.contactEmail)
            }
            Section(spec: L("About")) {
                LabeledContent("SieveSci", value: SieveSci.version).font(Theme.body)
                Text(Credits.line).font(Theme.monoSmall).foregroundStyle(.secondary)
                Link("github.com/Cetirzine/SieveSci", destination: URL(string: "https://github.com/Cetirzine/SieveSci")!).font(.caption)
            }
            Section(spec: L("Command line")) {
                HStack {
                    Button(L("Install command-line tool")) { cliMessage = Self.installCLI() }
                    Text(cliMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text(L("`sievesci` runs the same agent headless (scripts, scheduled tasks, SSH)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Links the bundled CLI into ~/.local/bin (no administrator rights needed).
    static func installCLI() -> String {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [exe.appendingPathComponent("sievesci"), exe.deletingLastPathComponent().appendingPathComponent("Resources/sievesci")]
        guard let src = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            return L("The CLI is not bundled with this build.")
        }
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let dst = bin.appendingPathComponent("sievesci")
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.createSymbolicLink(at: dst, withDestinationURL: src) } catch { return error.localizedDescription }
        return L10n.f("Linked %@ (make sure ~/.local/bin is on your PATH).", dst.path)
    }
}

// MARK: - Providers (ZCode-style)

struct ProvidersSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: String?
    @State private var adding = false

    /// Ready providers first, then the rest by how you pay for them.
    var groups: [(title: String, items: [ProviderProfile])] {
        let ready = model.config.providers.filter(model.isUsable)
        let rest = model.config.providers.filter { !model.isUsable($0) }
        return [(L("Ready"), ready),
                (L("Subscription plans"), rest.filter { $0.family == .cliAgent || Self.isPlan($0) }),
                (L("API keys"), rest.filter { $0.family != .cliAgent && $0.billing == "api" }),
                (L("Relays & custom"), rest.filter { $0.family != .cliAgent && $0.billing != "api" && !Self.isPlan($0) })]
            .filter { !$0.items.isEmpty }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(groups, id: \.title) { g in
                        Section(g.title) {
                            ForEach(g.items) { p in
                                HStack(spacing: Theme.Space.s) {
                                    Rectangle().fill(model.isUsable(p) ? Theme.ok : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(p.displayName).lineLimit(1)
                                        Text(model.isUsable(p) ? (model.quotas[p.id].flatMap(QuotaText.summary) ?? ProviderStatus(p, model: model).short)
                                                               : ProviderStatus(p, model: model).short)
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .padding(.vertical, 2)
                                .tag(p.id)
                                .help(ProvidersSettings.formatName(p.family) + " · " + L(p.billing))
                            }
                        }
                    }
                }
                HStack {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .help(L("Add provider…")).accessibilityLabel(L("Add provider…"))
                    Button {
                        if let s = selection { model.config.providers.removeAll { $0.id == s }; selection = nil }
                    } label: { Image(systemName: "minus") }.disabled(selection == nil)
                        .help(L("Remove provider")).accessibilityLabel(L("Remove provider"))
                    Spacer()
                }
                .buttonStyle(QuietIconButtonStyle())
                .padding(6)
            }
            .frame(minWidth: 230, maxWidth: 300)
            Group {
                if let s = selection, let i = model.config.providers.firstIndex(where: { $0.id == s }) {
                    ProviderDetail(profile: $model.config.providers[i])
                } else {
                    ProvidersOverview(add: { adding = true }, select: { selection = $0 })
                }
            }
            .frame(minWidth: 480)
        }
        .onAppear {
            if selection == nil { selection = model.usableProviders.first?.id }
            Task { await model.refreshQuotas() }
        }
        .sheet(isPresented: $adding) {
            AddProviderSheet { p in
                var p = p
                if model.config.providers.contains(where: { $0.id == p.id }) { p.id += "-" + String(UUID().uuidString.prefix(4)).lowercased() }
                model.config.providers.append(p)
                selection = p.id
            }
            .environmentObject(model)
        }
    }

    /// Coding plans and subscriptions (presets say "plan"; older configurations said "coding").
    static func isPlan(_ p: ProviderProfile) -> Bool { p.billing == "plan" || p.billing == "coding" }

    static func formatName(_ f: ProviderFamily) -> String {
        switch f {
        case .anthropic: return "Anthropic Messages"
        case .openaiResponses: return "OpenAI Responses"
        case .openaiChat: return "OpenAI Chat Completions"
        case .gemini: return "Gemini"
        case .cliAgent: return "CLI"
        }
    }
}

/// What a provider needs before it can be used, in plain words.
struct ProviderStatus {
    let ready: Bool
    let short: String

    init(_ p: ProviderProfile, model: AppModel) {
        if !p.enabled { ready = false; short = L("Turned off"); return }
        if p.family == .cliAgent {
            let found = ProcessRunner.which(p.executable ?? "") != nil
            ready = found
            short = found ? L("Found on this Mac — uses your sign-in") : L("CLI not installed")
        } else {
            ready = model.secrets.secret(for: p.apiKeyRef) != nil
            short = ready ? L("Ready") : (p.billing == "relay" || p.billing == "local" ? L("Needs a URL and key") : L("Needs an API key"))
        }
    }

    /// Where to create a key, for the built-in presets.
    static func keyPage(_ p: ProviderProfile) -> URL? {
        let pages = ["anthropic": "https://console.anthropic.com/settings/keys", "openai": "https://platform.openai.com/api-keys",
                     "gemini": "https://aistudio.google.com/apikey", "deepseek": "https://platform.deepseek.com/api_keys",
                     "glm-coding-cn": "https://open.bigmodel.cn/usercenter/apikeys", "glm-api": "https://open.bigmodel.cn/usercenter/apikeys",
                     "glm-coding-intl": "https://z.ai/manage-apikey/apikey-list", "openrouter": "https://openrouter.ai/keys",
                     "closeai": "https://platform.closeai-asia.com/dashboard", "closeai-anthropic": "https://platform.closeai-asia.com/dashboard"]
        return pages[p.id].flatMap(URL.init(string:))
    }

    /// How to install and sign in to a subscription CLI.
    static func cliHelp(_ executable: String) -> (install: String, signIn: String)? {
        switch executable {
        case "claude": return ("npm install -g @anthropic-ai/claude-code", "claude")
        case "codex": return ("npm install -g @openai/codex", "codex login")
        case "gemini": return ("npm install -g @google/gemini-cli", "gemini")
        case "agy": return ("curl -fsSL https://antigravity.google/cli/install.sh | bash", "agy")
        default: return nil
        }
    }

    /// A second key some relays need just to read the balance (CloseAI management keys).
    static func adminKeyRef(_ p: ProviderProfile) -> String? {
        URL(string: p.baseURL)?.host?.lowercased() == "api.openai-proxy.org" ? "CLOSEAI_ADMIN_KEY" : nil
    }
}

/// Right side of the providers page when nothing is selected.
struct ProvidersOverview: View {
    @EnvironmentObject var model: AppModel
    let add: () -> Void
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(model.usableProviders.isEmpty ? L("No model provider is ready yet") : L("Pick a provider to change it"))
                .font(.system(size: 17, weight: .semibold))
            Text(L("One is enough to start. The quickest options:")).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(["claude-code", "deepseek", "anthropic", "glm-coding-cn"], id: \.self) { id in
                    if let p = model.config.providers.first(where: { $0.id == id }) {
                        Button { select(p.id) } label: {
                            HStack {
                                Text(p.displayName)
                                Spacer()
                                Text(ProviderStatus(p, model: model).short).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, Theme.Space.m).frame(height: Theme.Control.row + 6)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).fill(Theme.raised))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).strokeBorder(Theme.separator))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button(L("Add another provider…"), action: add).padding(.top, Theme.Space.xs)
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct ProviderDetail: View {
    @Binding var profile: ProviderProfile
    @EnvironmentObject var model: AppModel
    @State private var key = ""
    @State private var fetching = false
    @State private var discovered: [DiscoveredModel] = []
    @State private var status = ""
    @State private var keyCheck: (ok: Bool, text: String)?
    @State private var checkingKey = false
    @State private var testing = false
    @State private var newHeaderName = ""
    @State private var newHeaderValue = ""
    @State private var newModel = ""
    @State private var showAdvanced = false
    @State private var adminKey = ""
    @State private var refreshingUsage = false

    func refreshUsage() async {
        guard model.isUsable(profile) || ProviderStatus.adminKeyRef(profile) != nil else { return }
        refreshingUsage = true
        await model.refreshQuota(profile)
        refreshingUsage = false
    }

    /// Plan limits (5-hour / weekly windows) and balances, with when they reset.
    @ViewBuilder var usageSection: some View {
        Section {
            if let q = model.quotas[profile.id] {
                if let plan = q.plan { LabeledContent(L("Plan"), value: plan) }
                ForEach(Array(q.meters.enumerated()), id: \.offset) { _, m in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(QuotaText.title(m))
                            Spacer()
                            Text(QuotaText.value(m)).monospacedDigit()
                                .foregroundStyle(m.exhausted ? Theme.bad : (m.usedFraction ?? 0) > 0.85 ? Theme.warn : .primary)
                        }
                        if let u = m.usedFraction {
                            ProgressView(value: min(max(u, 0), 1)).tint(u > 0.85 ? Theme.bad : Theme.accent)
                        }
                        if let r = QuotaText.reset(m) { Text(r).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 2)
                }
                if q.meters.isEmpty || q.note != nil {
                    Text(q.note.map(L) ?? L("No balance or quota API for this provider.")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(refreshingUsage ? L("Checking…") : L("Not checked yet.")).font(.caption).foregroundStyle(.secondary)
            }
            if let ref = ProviderStatus.adminKeyRef(profile) {
                HStack(spacing: Theme.Space.s) {
                    SecureField(KeychainSecretStore.has(ref) ? "••••••••••••" : L("Management key (sk-admin-…)"), text: $adminKey)
                        .textFieldStyle(.roundedBorder)
                    Button(L("Save")) {
                        KeychainSecretStore.set(adminKey.trimmingCharacters(in: .whitespacesAndNewlines), for: ref)
                        adminKey = ""
                        Task { await refreshUsage() }
                    }
                    .disabled(adminKey.isEmpty)
                }
                Text(L("Used only to read the balance; it cannot call models.")).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(L("Usage & limits"))
                Spacer()
                Button { Task { await refreshUsage() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(QuietIconButtonStyle())
                    .disabled(refreshingUsage)
                    .help(L("Refresh")).accessibilityLabel(L("Refresh"))
            }
        }
    }

    var body: some View {
        let st = ProviderStatus(profile, model: model)
        Form {
            Section {
                HStack(spacing: Theme.Space.s) {
                    Text(profile.displayName).font(.system(size: 16, weight: .semibold))
                    Text(st.short)
                        .font(Theme.caption.weight(.medium))
                        .foregroundStyle(st.ready ? Theme.ok : .secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(st.ready ? Theme.ok.opacity(0.12) : Color.secondary.opacity(0.1)))
                    Spacer()
                    Toggle(L("Enabled"), isOn: $profile.enabled).labelsHidden().toggleStyle(.switch)
                        .help(L("Enabled")).accessibilityLabel(L("Enabled"))
                }
                if profile.family == .cliAgent {
                    cliSection
                } else {
                    keySection
                }
            }
            if st.ready || profile.family == .cliAgent || ProviderStatus.adminKeyRef(profile) != nil { usageSection }
            Section(spec: L("Models")) {
                HStack {
                    Button(fetching ? L("Fetching…") : L("Fetch models from provider")) { Task { await fetch() } }
                        .disabled(fetching || (profile.family == .cliAgent ? !(profile.flavor == .antigravity || profile.flavor == .codex) : !KeychainSecretStore.has(profile.apiKeyRef)))
                    TextField(L("Add model id"), text: $newModel).onSubmit { addModel() }
                    Button(L("Add")) { addModel() }.disabled(newModel.isEmpty)
                }
                ForEach(profile.models, id: \.self) { m in
                    let st = ModelDiscovery.effectiveSettings(model: m, profile: profile, discovered: discovered.first { $0.id == m })
                    HStack {
                        Button { profile.defaultModel = m } label: {
                            Image(systemName: profile.defaultModel == m ? "star.fill" : "star").foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .help(L("Default model")).accessibilityLabel(L("Default model"))
                        Text(m).font(Theme.monoSmall)
                        Spacer()
                        Text(L10n.f("%@ ctx", Self.tokens(st.contextWindow))).font(.caption).foregroundStyle(.secondary)
                        if st.supportsImages { Image(systemName: "photo").foregroundStyle(.secondary).help(L("Accepts images")) }
                        if st.supportsReasoning { Image(systemName: "brain").foregroundStyle(.secondary).help(L("Reasoning model")) }
                        Button { profile.models.removeAll { $0 == m } } label: { Image(systemName: "xmark") }.buttonStyle(QuietIconButtonStyle())
                            .help(L("Remove")).accessibilityLabel(L("Remove"))
                    }
                }
                if !discovered.isEmpty {
                    DisclosureGroup(L10n.f("%d models available", discovered.count)) {
                        ForEach(discovered.filter { !profile.models.contains($0.id) }) { d in
                            HStack {
                                Text(d.id).font(Theme.monoTiny)
                                if let c = d.contextWindow { Text(Self.tokens(c)).font(.caption2).foregroundStyle(.secondary) }
                                Spacer()
                                Button(L("Add")) { profile.models.append(d.id) }
                            }
                        }
                    }
                }
            }
            Section {
                DisclosureGroup(L("Advanced"), isExpanded: $showAdvanced) {
                    if !profile.notes.isEmpty { Text(profile.notes).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    advanced
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if profile.billing == "coding" { profile.billing = "plan" }
            Task { await refreshUsage() }
            if profile.flavor == .antigravity || profile.flavor == .codex { Task { await fetch() } }
        }
        .onChange(of: profile.id) { _, _ in
            discovered = []; status = ""; keyCheck = nil; key = ""; adminKey = ""
            if profile.billing == "coding" { profile.billing = "plan" }
            Task { await refreshUsage() }
            if profile.flavor == .antigravity || profile.flavor == .codex { Task { await fetch() } }
        }
    }

    @ViewBuilder var keySection: some View {
        let hasKey = KeychainSecretStore.has(profile.apiKeyRef)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(hasKey ? L("API key saved in the macOS Keychain. Paste a new one to replace it.") : L("Paste your API key. It is stored in the macOS Keychain, never in a file."))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: Theme.Space.s) {
                SecureField(hasKey ? "••••••••••••" : L("API key"), text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await saveAndCheck() } }
                Button(checkingKey ? L("Checking…") : L("Save & check")) { Task { await saveAndCheck() } }
                    .buttonStyle(.primaryAction)
                    .disabled(key.isEmpty || checkingKey)
            }
            HStack(spacing: Theme.Space.m) {
                if let page = ProviderStatus.keyPage(profile) {
                    Link(L("Get an API key ↗"), destination: page).font(.caption)
                }
                if hasKey {
                    Button(checkingKey ? L("Checking…") : L("Check key")) { Task { await checkKey() } }
                        .buttonStyle(.link).font(.caption).disabled(checkingKey)
                    Button(L("Remove key")) { KeychainSecretStore.set("", for: profile.apiKeyRef); keyCheck = nil; model.objectWillChange.send() }
                        .buttonStyle(.link).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let c = keyCheck {
                Label(c.text, systemImage: c.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(c.ok ? Theme.ok : Theme.warn)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder var cliSection: some View {
        let exe = profile.executable ?? ""
        let path = ProcessRunner.which(exe)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let path {
                Label(L10n.f("Found %@ — SieveSci drives it with your existing sign-in, so usage counts against your plan. Your login token is never read.", path),
                      systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(Theme.ok)
            } else {
                Label(L10n.f("%@ is not installed on this Mac.", exe), systemImage: "xmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            if let help = ProviderStatus.cliHelp(exe) {
                Text(path == nil ? L("Install it in Terminal, then sign in once:") : L("Not signed in yet? Run this once in Terminal:"))
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    if path == nil { Text(help.install) }
                    Text(help.signIn)
                }
                .font(Theme.monoTiny).textSelection(.enabled)
                .padding(Theme.Space.s).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.s).fill(Theme.surface))
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder var advanced: some View {
        TextField(L("Name"), text: $profile.displayName)
        Picker(L("API format"), selection: $profile.family) {
            ForEach(ProviderFamily.allCases, id: \.self) { Text(ProvidersSettings.formatName($0)).tag($0) }
        }
        .onChange(of: profile.family) { _, f in profile.options = ProviderOptions.detected(family: f, baseURL: profile.baseURL) }
        if profile.family == .cliAgent {
            TextField(L("Executable"), text: Binding(get: { profile.executable ?? "" }, set: { profile.executable = $0 }))
        } else {
            TextField(L("Base URL"), text: $profile.baseURL)
                .onSubmit { profile.options = ProviderOptions.detected(family: profile.family, baseURL: profile.baseURL) }
            TextField(L("Keychain / environment name"), text: $profile.apiKeyRef)
        }
        Picker(L("Billing"), selection: $profile.billing) {
            Text(L("API (pay per token)")).tag("api")
            Text(L("Coding plan / subscription")).tag("plan")
            Text(L("Relay (中转站)")).tag("relay")
            Text(L("Local")).tag("local")
        }
        Text(L("Cache & compatibility")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, Theme.Space.s)
        Toggle(L("Anthropic cache_control breakpoints"), isOn: $profile.options.anthropicCacheControl)
        Toggle(L("Long cache retention (1h / 24h)"), isOn: $profile.options.supportsLongRetention)
        Toggle(L("Send prompt_cache_key"), isOn: $profile.options.sendPromptCacheKey)
        Toggle(L("cache_control in chat content parts (OpenRouter-style relays)"), isOn: $profile.options.cacheControlInChatParts)
        Toggle(L("Explicit Gemini context cache"), isOn: $profile.options.explicitPromptCacheMode)
        Toggle(L("Stream usage"), isOn: $profile.options.streamUsage)
        TextField(L("Session-affinity header"), text: $profile.options.sessionAffinity)
        Button(L("Reset to detected defaults")) { profile.options = ProviderOptions.detected(family: profile.family, baseURL: profile.baseURL) }
        Text(L("Extra headers")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, Theme.Space.s)
        ForEach(profile.options.headers.sorted { $0.key < $1.key }, id: \.key) { k, v in
            HStack {
                Text(k).font(Theme.monoTiny)
                Text(v).font(Theme.monoTiny).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { profile.options.headers[k] = nil } label: { Image(systemName: "xmark") }.buttonStyle(QuietIconButtonStyle())
                    .accessibilityLabel(L("Remove"))
            }
        }
        HStack {
            TextField(L("Header"), text: $newHeaderName)
            TextField(L("Value"), text: $newHeaderValue)
            Button(L("Add")) { profile.options.headers[newHeaderName] = newHeaderValue; newHeaderName = ""; newHeaderValue = "" }
                .disabled(newHeaderName.isEmpty)
        }
        Text(L("Check")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, Theme.Space.s)
        HStack {
            Button(testing ? L("Testing…") : L("Test connection and cache")) { Task { await test() } }.disabled(testing)
            Text(L("sends two short requests (a few thousand tokens)")).font(.caption).foregroundStyle(.secondary)
        }
        if !status.isEmpty { Text(status).font(Theme.monoTiny).textSelection(.enabled) }
    }

    /// Saves the pasted key, then checks it by listing models — free, no tokens spent.
    func saveAndCheck() async {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        KeychainSecretStore.set(k, for: profile.apiKeyRef)
        key = ""
        profile.enabled = true
        model.objectWillChange.send()
        await checkKey()
    }

    func checkKey() async {
        checkingKey = true
        defer { checkingKey = false }
        do {
            let list = try await ModelDiscovery.list(profile, apiKey: model.secrets.secret(for: profile.apiKeyRef))
            discovered = list
            keyCheck = (true, list.isEmpty ? L("Key saved. The provider does not list models, so it could not be checked for free; use Test connection under Advanced.")
                                           : L10n.f("The key works — %d models available.", list.count))
        } catch {
            keyCheck = (false, L("The provider did not accept the request:") + " " + error.localizedDescription)
        }
    }

    static func tokens(_ n: Int) -> String { n >= 1_000_000 ? "\(n / 1_000_000)M" : "\(n / 1000)k" }

    func addModel() {
        let m = newModel.trimmingCharacters(in: .whitespaces)
        if !m.isEmpty && !profile.models.contains(m) { profile.models.append(m) }
        if profile.defaultModel.isEmpty { profile.defaultModel = m }
        newModel = ""
    }

    func fetch() async {
        fetching = true
        defer { fetching = false }
        do {
            discovered = try await ModelDiscovery.list(profile, apiKey: model.secrets.secret(for: profile.apiKeyRef))
            status = L10n.f("%d models listed.", discovered.count)
            // A subscription CLI can use everything its account lists, so offer all of it right away.
            if profile.family == .cliAgent, !discovered.isEmpty {
                // The CLI's own list is the truth: models it no longer offers are dropped.
                profile.models = discovered.map(\.id)
                if !profile.models.contains(profile.defaultModel) { profile.defaultModel = "default" }
            }
        } catch {
            status = L("Listing failed:") + " \(error.localizedDescription)"
        }
    }

    /// Two identical small requests: the first shows connectivity and latency, the second whether
    /// the provider's prefix cache answers (cached tokens > 0). The prompt is long enough to be
    /// cacheable on every vendor (≥ 1024 tokens for OpenAI/Anthropic, ≥ 4096 for some Gemini models).
    func test() async {
        testing = true
        defer { testing = false }
        guard let llm = try? ProviderFactory.make(profile, secrets: model.secrets) else { status = L("No API key."); return }
        let m = profile.defaultModel.isEmpty ? (profile.models.first ?? "") : profile.defaultModel
        let filler = String(repeating: "SieveSci cache probe. ", count: 900)
        let req = LLMRequest(model: m, system: "Reply with the single word: ok. " + filler, tools: [], messages: [Message.user("ping")],
                             maxTokens: 16, cache: CacheHints(lineageKey: "probe-" + profile.id, retention: .short))
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
        status = lines.joined(separator: "\n")
        let q = await QuotaService.shared.refresh(profile, secrets: model.secrets)
        model.quotas[profile.id] = q
    }
}

struct AddProviderSheet: View {
    let onAdd: (ProviderProfile) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var tab = 0
    @State private var query = ""
    @State private var customName = ""
    @State private var customURL = ""
    @State private var customFamily: ProviderFamily = .openaiChat

    var presets: [ProviderProfile] { ProviderPresets.all.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) } }
    var catalog: [ProviderCatalog.Entry] {
        ProviderCatalog.shared.entries.filter { query.isEmpty || $0.vendor.localizedCaseInsensitiveContains(query) }
    }
    var modelsDev: [ModelsDevProvider] {
        ModelsDevCatalog.shared.providers.values.filter { $0.api != nil && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Add provider")).font(.title3.weight(.semibold))
            Picker("", selection: $tab) {
                Text(L("Presets")).tag(0)
                Text(L("Endpoint catalog")).tag(1)
                Text("models.dev").tag(2)
                Text(L("Custom / relay")).tag(3)
            }.pickerStyle(.segmented).labelsHidden()
            if tab < 3 { TextField(L("Search"), text: $query).textFieldStyle(.roundedBorder) }
            List {
                switch tab {
                case 0:
                    ForEach(presets) { p in
                        row(p.displayName, ProvidersSettings.formatName(p.family) + " · " + p.baseURL) { onAdd(p); dismiss() }
                    }
                case 1:
                    ForEach(catalog) { e in
                        row("\(e.vendor) · \(e.region) · \(e.plan)", e.routes.keys.map(ProvidersSettings.formatName).sorted().joined(separator: ", ")) {
                            if let p = ProviderCatalog.shared.profile(for: e) { onAdd(p); dismiss() }
                        }
                    }
                case 2:
                    ForEach(modelsDev, id: \.id) { mp in
                        row(mp.name, (mp.api ?? "") + " · " + L10n.f("%d models", mp.models.count)) {
                            let models = mp.models.keys.sorted()
                            onAdd(ProviderProfile(id: mp.id, displayName: mp.name, family: .openaiChat, baseURL: mp.api ?? "",
                                                  auth: .bearer, apiKeyRef: mp.env.first ?? mp.id.uppercased() + "_API_KEY", models: Array(models.prefix(30))))
                            dismiss()
                        }
                    }
                default:
                    Form {
                        TextField(L("Name"), text: $customName)
                        TextField(L("Base URL (e.g. https://relay.example.com/v1)"), text: $customURL)
                        Picker(L("API format"), selection: $customFamily) {
                            ForEach(ProviderFamily.allCases.filter { $0 != .cliAgent }, id: \.self) { Text(ProvidersSettings.formatName($0)).tag($0) }
                        }
                        Text(L("Relays (new-api / one-api, OpenRouter, resellers) usually speak OpenAI Chat Completions; many also offer Anthropic Messages or Gemini routes, which keep vendor-native caching."))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(L("Add")) {
                            let id = customName.lowercased().replacingOccurrences(of: " ", with: "-")
                            let auth: AuthStyle = customFamily == .anthropic ? .xApiKey : customFamily == .gemini ? .googApiKey : .bearer
                            onAdd(ProviderProfile(id: id.isEmpty ? "relay" : id, displayName: customName.isEmpty ? "Relay" : customName, family: customFamily,
                                                  baseURL: customURL, auth: auth, apiKeyRef: (id.isEmpty ? "RELAY" : id.uppercased().replacingOccurrences(of: "-", with: "_")) + "_API_KEY",
                                                  models: [], billing: "relay",
                                                  options: ProviderOptions.detected(family: customFamily, baseURL: customURL)))
                            dismiss()
                        }.disabled(customURL.isEmpty)
                    }
                }
            }
            HStack { Spacer(); Button(L("Cancel")) { dismiss() } }
        }
        .padding(16)
        .frame(width: 620, height: 520)
    }

    func row(_ title: String, _ sub: String, _ action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(L("Add"), action: action)
        }
    }
}

// MARK: - Models per role

struct ModelsSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var refreshing = false
    @State private var report = ""

    var refs: [ModelRef] { model.usableProviders.flatMap { p in p.models.map { ModelRef(providerId: p.id, model: $0) } } }

    func label(_ r: ModelRef) -> String {
        (model.config.providers.first { $0.id == r.providerId }?.displayName ?? r.providerId) + " / " + r.model
    }

    var body: some View {
        let recs = RoleModelAdvisor.recommend(candidates: model.candidates)
        let resolved = RoleModelAdvisor.resolve(model.config.roles, candidates: model.candidates)
        Form {
            Section {
                Picker(L("Assignment"), selection: $model.config.roles.mode) {
                    Text(L("Automatic (benchmarks)")).tag(RoleAssignment.Mode.auto)
                    Text(L("Same model for all roles")).tag(RoleAssignment.Mode.same)
                    Text(L("Custom per role")).tag(RoleAssignment.Mode.custom)
                }
                .pickerStyle(.segmented)
                Text(L("Automatic picks, from your providers, the best model per role on LAB-Bench 2, RiemannBench, Terminal-Bench Science and PostTrainBench (cited snapshot, refreshable), preferring a different vendor for the checker and verifier than for the research agent."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.config.roles.mode == .same {
                Section(spec: L("Model")) {
                    Picker(L("All roles"), selection: Binding(get: { model.config.roles.same }, set: { model.config.roles.same = $0 })) {
                        Text(L("Choose…")).tag(ModelRef?.none)
                        ForEach(refs, id: \.self) { Text(label($0)).tag(Optional($0)) }
                    }
                }
            }
            Section(spec: L("Roles")) {
                ForEach(AgentRole.allCases, id: \.self) { role in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            RoleGhostIcon(role: role, size: 18)
                            Text(Theme.roleName(role)).fontWeight(.medium)
                            Spacer()
                            if model.config.roles.mode == .custom {
                                Picker("", selection: Binding(get: { model.config.roles.custom[role.rawValue] }, set: { model.config.roles.custom[role.rawValue] = $0 })) {
                                    Text(L("Automatic")).tag(ModelRef?.none)
                                    ForEach(refs, id: \.self) { Text(label($0)).tag(Optional($0)) }
                                }.labelsHidden().frame(maxWidth: 320)
                            } else {
                                Text(resolved[role].map(label) ?? L("none")).font(Theme.monoSmall)
                            }
                        }
                        if let rec = recs.first(where: { $0.role == role }) {
                            Text(rec.reasons.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section(spec: L("Workers")) {
                Toggle(L("Run independent parts on workers automatically"), isOn: $model.config.autoDelegate)
                if model.config.autoDelegate {
                    Stepper(L10n.f("Workers at once: %d", model.config.maxParallelWorkers), value: $model.config.maxParallelWorkers, in: 1...8)
                }
                Text(L("When a request or plan has independent parts, SieveSci runs them on workers automatically."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(spec: L("Vision")) {
                Picker(L("Image helper for text-only models"), selection: $model.config.visionHelper) {
                    Text(L("None")).tag(ModelRef?.none)
                    ForEach(refs.filter { r in
                        model.config.providers.first { $0.id == r.providerId }.map { ModelDiscovery.effectiveSettings(model: r.model, profile: $0, discovered: nil).supportsImages } ?? false
                    }, id: \.self) { Text(label($0)).tag(Optional($0)) }
                }
                Text(L("Input modalities are detected per model (models.dev, provider listings, ZCode rules). Images sent to a text-only model are described by this helper first."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(spec: L("Benchmarks")) {
                let snap = BenchmarkSnapshot.current()
                ForEach(snap.benchmarks.sorted { $0.key < $1.key }, id: \.key) { _, b in
                    HStack {
                        Text(b.title)
                        Spacer()
                        Text(L("as of") + " \(b.asOf)").font(.caption).foregroundStyle(.secondary)
                        if let u = URL(string: b.source) { Link(L("source"), destination: u).font(.caption) }
                    }
                }
                HStack {
                    Button(refreshing ? L("Refreshing…") : L("Refresh catalogs and leaderboards")) { Task { await refresh() } }.disabled(refreshing)
                    Text(L("Uses the research agent's model to extract leaderboard rows; every row must appear verbatim on the page."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !report.isEmpty { Text(report).font(Theme.monoTiny).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
    }

    func refresh() async {
        refreshing = true
        defer { refreshing = false }
        let main = try? model.roleModels().main
        let r = await CatalogRefresher.refreshAll(extractor: main?.0, extractorModel: main?.1)
        report = r.lines.joined(separator: "\n")
    }
}

// MARK: - Web search

struct SearchSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var key = ""
    @State private var excluded = ""

    var body: some View {
        Form {
            Section(spec: L("Search engine")) {
                Picker(L("Backend"), selection: $model.config.webSearch.backend) {
                    ForEach(WebSearchBackend.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: model.config.webSearch.backend) { _, b in
                    model.config.webSearch.apiKeyRef = ["brave": "BRAVE_API_KEY", "tavily": "TAVILY_API_KEY", "exa": "EXA_API_KEY", "googleCSE": "GOOGLE_CSE_KEY"][b.rawValue] ?? ""
                }
                if !model.config.webSearch.apiKeyRef.isEmpty {
                    HStack {
                        SecureField(L("API key"), text: $key)
                        Button(L("Save key")) { KeychainSecretStore.set(key, for: model.config.webSearch.apiKeyRef); key = "" }.disabled(key.isEmpty)
                        Text(KeychainSecretStore.has(model.config.webSearch.apiKeyRef) ? "✓" : "✗")
                    }
                }
                if model.config.webSearch.backend == .searxng { TextField("SearXNG URL", text: $model.config.webSearch.searxngURL) }
                if model.config.webSearch.backend == .googleCSE { TextField("Google CX", text: $model.config.webSearch.googleCX) }
                Text(L("Models with native search (Claude API, DeepSeek and GLM Anthropic endpoints) search natively first; this engine is the fallback and the independent cross-check."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(spec: L("Excluded domains")) {
                TextEditor(text: $excluded).font(Theme.monoTiny).frame(height: 140)
                    .onAppear { excluded = model.config.webSearch.excludedDomains.joined(separator: "\n") }
                    .onChange(of: excluded) { _, v in
                        model.config.webSearch.excludedDomains = v.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                Text(L("Content farms and low-quality aggregators are excluded from every search by default."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Research rules

struct ResearchSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var connectorMessage = ""
    @State private var connected: Set<String> = Set(ScienceConnectors.all.filter { ScienceConnectors.isConnected($0.id) }.map(\.id))

    var body: some View {
        Form {
            Section(spec: L("Science connectors")) {
                ForEach(ScienceConnectors.all, id: \.id) { c in
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Theme.Space.xs) {
                                Text(c.title).font(Theme.body.weight(.medium))
                                Chip(text: c.license)
                            }
                            Text(c.notes).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Link(c.source, destination: URL(string: c.source)!).font(.caption)
                        }
                        Spacer()
                        Button(connected.contains(c.id) ? L("Connected") : L("Connect")) {
                            connectorMessage = (try? ScienceConnectors.connect(c.id)) ?? ""
                            connected.insert(c.id)
                        }
                        .buttonStyle(.action(connected.contains(c.id) ? .secondary : .primary, width: Theme.Control.buttonWidth))
                        .disabled(connected.contains(c.id))
                    }
                }
                if !connectorMessage.isEmpty { Text(connectorMessage).font(.caption).foregroundStyle(.secondary) }
            }
            Section(spec: L("Grounding")) {
                Toggle(L("Require web and literature search before plans, claims and conclusions"), isOn: $model.config.groundingRequired)
            }
            Section(spec: L("Independent review")) {
                Stepper(L10n.f("Review budget per session: %d", model.config.maxReviewsPerSession), value: $model.config.maxReviewsPerSession, in: 4...200, step: 4)
                Stepper(L10n.f("Exchanges per disagreement: %d", model.config.maxDeliberationExchanges), value: $model.config.maxDeliberationExchanges, in: 1...4)
                Text(L("Agents may question and rebut each other, but only with new evidence, without repetition and within this limit; unsettled points are marked contested and shown to you."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(spec: L("Sandbox")) {
                Picker(L("Commands the agents run"), selection: $model.config.sandboxMode) {
                    Text(L("Write workspace only, network on")).tag(SandboxMode.workspaceWrite)
                    Text(L("Write workspace only, offline")).tag(SandboxMode.workspaceWriteOffline)
                    Text(L("No sandbox")).tag(SandboxMode.off)
                }
                Text(L("The audit log, provenance and history (.sievesci, .git) are always write-protected from agent code."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(spec: L("Model calls")) {
                Picker(L("Prompt cache retention"), selection: $model.config.retention) {
                    Text(L("Vendor default")).tag(CacheRetention.short)
                    Text(L("Long (1h / 24h; best for long sessions)")).tag(CacheRetention.long)
                    Text(L("Off")).tag(CacheRetention.none)
                }
                LabeledContent(L("Reasoning effort")) {
                    EffortSlider(effort: $model.config.effort).frame(width: 320)
                }
            }
            Text(L("Changes apply to new tasks.")).font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Memory & learning

struct MemorySettings: View {
    @EnvironmentObject var model: AppModel
    @State private var role: AgentRole = .main

    var store: MemoryStore {
        MemoryStore(dir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/memory/\(role.rawValue)"))
    }

    var body: some View {
        Form {
            Section {
                Picker(L("Role"), selection: $role) {
                    ForEach(AgentRole.allCases, id: \.self) { Text(Theme.roleName($0)).tag($0) }
                }.pickerStyle(.segmented)
                Text(L("Every role keeps long-term memory and can propose skills. Proposals are screened against gaming and unscientific shortcuts, must cite the receipts they were learned from, and are reviewed independently; checker and verifier learning needs your approval."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(MemoryStore.Store.allCases, id: \.self) { s in
                Section {
                    let es = store.entries(s)
                    if es.isEmpty { Text(L("Empty")).foregroundStyle(.secondary) }
                    ForEach(Array(es.enumerated()), id: \.offset) { _, e in Text(e).font(.caption).textSelection(.enabled) }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title(s))
                        Text(Self.hint(s)).font(.caption).foregroundStyle(.secondary).textCase(nil)
                    }
                }
            }
            Section {
                HStack {
                    EqualWidthButtons {
                        Button(L("Open memory folder")) { NSWorkspace.shared.open(store.dir) }
                        Button(L("Open learned skills")) {
                            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/learned-skills"))
                        }
                    }
                    Spacer()
                    let pending = model.proposals.filter { $0.status == .pending }.count
                    if pending > 0 {
                        Button(L10n.f("%d proposals await approval", pending)) { model.show(.learning) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    static func title(_ s: MemoryStore.Store) -> String {
        switch s {
        case .memory: return L("Notes")
        case .user: return L("About you")
        case .lessons: return L("Lessons")
        }
    }

    static func hint(_ s: MemoryStore.Store) -> String {
        switch s {
        case .memory: return L("Environment, conventions and facts this role has learned.")
        case .user: return L("Who you are and how you like to work.")
        case .lessons: return L("Mistakes caught before, approaches that failed, quirks of sources.")
        }
    }
}

// MARK: - Schedules

struct ScheduleSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var tasks = Scheduler.list()
    @State private var when = "daily 08:30"
    @State private var prompt = ""
    @State private var message = ""

    var body: some View {
        Form {
            Section(spec: L("Scheduled tasks")) {
                if tasks.isEmpty { Text(L("None. Example: a daily literature watch on your topic.")).foregroundStyle(.secondary) }
                ForEach(tasks, id: \.id) { t in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.prompt).lineLimit(2)
                            Text("\(t.when) · \(URL(fileURLWithPath: t.workspace).lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Remove"), role: .destructive) {
                            Task { message = await Scheduler.remove(t.id); tasks = Scheduler.list() }
                        }
                    }
                }
            }
            Section(spec: L("New")) {
                TextField(L("When (daily 08:30 · weekly mon 09:00 · every 6h)"), text: $when)
                TextField(L("Prompt"), text: $prompt, axis: .vertical).lineLimit(2...5)
                HStack {
                    Button(L("Schedule in current workspace")) {
                        guard let ws = model.workspace else { message = L("Open a workspace first."); return }
                        Task { message = await Scheduler.add(workspace: ws, when: when, prompt: prompt); tasks = Scheduler.list(); prompt = "" }
                    }.disabled(prompt.isEmpty || model.workspace == nil)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Text(L("Runs headless as a macOS LaunchAgent with the same research rules, audit log and notebook; results land in the workspace's task list."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}


/// A form section headed by the app's monospaced section label.
extension Section where Parent == SectionLabel, Footer == EmptyView, Content: View {
    init(spec title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { SectionLabel(title) })
    }
}
