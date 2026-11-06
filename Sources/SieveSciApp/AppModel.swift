import AppKit
import Foundation
import SieveSciCore
import SwiftUI

@MainActor
/// The window's state. Stored properties live here (extensions cannot hold them), so the ones the
/// `AppModel+Events` and `AppModel+Panels` extensions use are internal rather than private.
final class AppModel: ObservableObject {
    @Published var config = AppConfig.load() {
        didSet {
            if config != oldValue, !Self.isDemo { config.save() }
            // Effort applies from the next model call of the open task, not only to new sessions.
            if config.effort != oldValue.effort { bench?.services.effort = config.effort }
            if config.autoBrainstorm != oldValue.autoBrainstorm { bench?.services.ideas.autoAllowed = config.autoBrainstorm }
            if config.autoCheckUpdates != oldValue.autoCheckUpdates || config.autoInstallUpdates != oldValue.autoInstallUpdates {
                configureUpdater()
            }
        }
    }
    @Published var language = L10n.language
    @Published var workspace: URL?
    @Published var taskId = ""
    /// For rows that call actions without observing the model (see `ModelLink`).
    lazy var link = ModelLink(self)
    var traceCache: (url: URL, offset: UInt64, events: [TraceEvent])?
    /// A trace read is in flight; a refresh asked for meanwhile runs once it lands.
    var traceReading = false
    /// How many receipts of which task the figure list has seen (`refreshSidePanels`).
    var figureScan: (audit: URL, count: Int)?
    var traceRefreshQueued = false
    /// Transcript streams: "main" plus one per dispatched agent (nested cards).
    @Published var streams: [String: [TranscriptItem]] = ["main": []]
    @Published var cards: [String: AgentCard] = [:]
    @Published var meter = ContextMeter(model: "", contextWindow: 0)
    @Published var running = false
    @Published var runStarted = Date()
    @Published var pendingPermission: PermissionRequest?
    /// The structured question (`ask_user`) the open task waits on.
    @Published var pendingAsk: AskRequest?
    /// The open task's brainstorm: live while it runs, kept until the next message once it ends.
    @Published var brainstorm: BrainstormState?
    @Published var ideas: [Idea] = []
    /// Workspaces whose dream ideas were already announced this launch.
    var dreamNoticeShown: Set<String> = []
    @Published var plan = ResearchPlan()
    @Published var claims: [Claim] = []
    @Published var contested: [(thread: String, kind: String, issue: String, reason: String)] = []
    @Published var quotas: [String: QuotaSnapshot] = [:]
    @Published var library: [PaperRecord] = []
    @Published var literatureLog: [LiteratureEvent] = []
    @Published var proposals: [EvolutionProposal] = []
    @Published var tasks: [(id: String, modified: Date)] = [] { didSet { refreshTaskTitles() } }
    /// Conversations of the other sidebar folders that are expanded, by folder path.
    @Published var folderTasks: [String: [(id: String, modified: Date)]] = [:]
    /// task id → its first question, shown instead of the generated id.
    @Published var taskTitles: [String: String] = [:]
    @Published var commandCatalog: [SlashCommandInfo] = SlashCommands.builtins
    @Published var lastError: String?
    @Published var spinnerVerb = "Sieving"
    @Published var jobs: [String: JobState] = [:]
    @Published var jobOrder: [String] = []
    @Published var changedFiles: [String] = []
    @Published var history: [GitHistory.Commit] = []
    @Published var figures: [URL] = []
    @Published var queued: [String] = []
    /// Text placed back into the prompt box ("edit & resend").
    @Published var draft = ""
    @Published var inspectorTab: InspectorTab = .files
    @Published var showInspector = false
    /// What the main area shows: the conversation or one of the research views.
    @Published var mainTab: MainTab = .chat
    /// Where each task's conversation was scrolled to, as the distance from its top. A task that is
    /// absent was at the end, and opens there. Not published: scrolling must not redraw the window.
    var chatScroll: [String: CGFloat] = [:]
    /// How many of each task's first rows the conversation leaves undrawn (see `ChatView.page`).
    var chatHidden: [String: Int] = [:]
    /// Settings open as a full page inside the window.
    @Published var showSettingsPage = false {
        // Coming back from Settings (a key was added, a provider enabled): start the session if none runs.
        didSet { if oldValue && !showSettingsPage { resumeIfNeeded() } }
    }
    /// Sample permission prompt for the UI demo (debug builds only).
    @Published var demoAsk: PermissionAsk?

    /// `SIEVESCI_UI_DEMO=1` (debug builds): fill the window with sample research data for UI work and
    /// screenshots. Nothing is saved, no workspace is opened and no model is called.
    static var isDemo: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SIEVESCI_UI_DEMO"] == "1"
        #else
        return false
        #endif
    }

    /// Opens a research view where it lives: the main area for reading-heavy views, the side panel otherwise.
    func show(_ tab: InspectorTab) {
        if tab.inMain {
            mainTab = .panel(tab)
        } else {
            inspectorTab = tab
            showInspector = true
            if tab == .jobs { markJobsRead() }
        }
    }

    private(set) var bench: Workbench?
    /// Sessions still working after the user switched to another task; they finish on their own.
    var background: [String: Workbench] = [:]
    @Published var backgroundTasks: Set<String> = []
    /// Workspace of each background task, so its folder row can show that it is still working.
    @Published var backgroundWorkspaces: [String: String] = [:]
    /// The task's trace, from its audit log (complete across restarts and for CLI agents).
    @Published var trace: [TraceEvent] = []
    /// Each known task's stage (dsh-superagent's "what does it wait for"), for the sidebar and the
    /// "Needs you" list. A finished background task keeps its last stage until it is opened.
    @Published var attention: [String: Attention] = [:]
    struct Attention: Equatable {
        var stage: TaskStage
        var workspace: String
    }
    /// The error that ended a task's last turn, until its next turn starts.
    var turnFailures: [String: String] = [:]
    var traceRefreshPending = false
    /// Permission requests from background sessions, shown when the user returns to that task.
    var backgroundAsks: [String: (PermissionRequest, CheckedContinuation<PermissionDecision, Never>)] = [:]
    /// The running session's start-up (toolset, baseline commit); submissions wait for it.
    private var starting: Task<Void, Never>?
    private var permissionContinuation: CheckedContinuation<PermissionDecision, Never>?
    /// tool-use id → (stream, index)
    var toolIndex: [String: (String, Int)] = [:]
    var openText: [String: Int] = [:]
    var openThinking: [String: Int] = [:]
    /// Most recent tool call per agent (file diffs attach to it).
    var lastTool: [String: (String, Int)] = [:]
    /// Streamed deltas waiting for the next flush (see `route`).
    var pendingDeltas: [AgentEvent] = []
    var pendingTask = ""
    var deltaFlushScheduled = false
    let secrets = KeychainSecretStore()
    let notifier = Notifier()

    var items: [TranscriptItem] { streams["main"] ?? [] }

    init() {
        // CLI agents get SieveSci's tools through the bundled CLI acting as a stdio MCP bridge.
        if let dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let cli = dir.appendingPathComponent("sievesci-cli").path
            if FileManager.default.isExecutableFile(atPath: cli) { ToolBridge.shared.bridgeCommand = [cli, "mcp-bridge"] }
        }
        #if DEBUG
        if Self.isDemo { loadDemo(); return }
        #endif
        config.addPresets()
        if let last = config.recentWorkspaces.first, FileManager.default.fileExists(atPath: last) {
            workspace = URL(fileURLWithPath: last)
            // Pick up where the user left off: the workspace's most recent task.
            DispatchQueue.main.async { [weak self] in self?.resumeIfNeeded() }
        }
        notifier.requestAuthorization()
        configureUpdater()
        if !Self.isDemo { Updater.shared.start() }
    }

    func configureUpdater() {
        let u = Updater.shared
        u.autoCheck = config.autoCheckUpdates
        u.autoInstall = config.autoInstallUpdates
        u.isBusy = { [weak self] in self?.running ?? false }
        u.notify = { [weak self] title, body in self?.notifier.post(title: title, body: body, id: "update") }
    }

    func setLanguage(_ l: L10n.Language) {
        L10n.language = l
        language = l
        commandCatalog = commandCatalog.map { $0 }   // re-render
        objectWillChange.send()
    }

    // MARK: Providers & roles

    // The rules live in the core (`ConfiguredModels`), shared with `sievesci serve`.
    func isUsable(_ p: ProviderProfile) -> Bool { ConfiguredModels.isUsable(p, secrets: secrets) }
    var usableProviders: [ProviderProfile] { ConfiguredModels.usable(config, secrets: secrets) }
    var candidates: [RoleModelAdvisor.Candidate] { ConfiguredModels.candidates(config, secrets: secrets) }
    func provider(_ ref: ModelRef) -> (LLMProvider, String)? { ConfiguredModels.provider(ref, config: config, secrets: secrets) }
    func roleModels() throws -> RoleModels { try ConfiguredModels.roleModels(config, secrets: secrets) }

    /// Switches the main model and resumes the same task (the transcript is kept; the provider's
    /// prompt cache starts cold for the new model).
    func switchMainModel(_ ref: ModelRef) {
        if config.roles.mode == .same {
            config.roles.same = ref
        } else {
            config.roles.mode = .custom
            if config.roles.custom.isEmpty {
                for (role, r) in RoleModelAdvisor.resolve(config.roles, candidates: candidates) { config.roles.custom[role.rawValue] = r }
            }
            config.roles.custom[AgentRole.main.rawValue] = ref
        }
        if workspace != nil { startSession(task: taskId.isEmpty ? nil : taskId, restart: true) }
    }

    // MARK: Session lifecycle

    func open(workspace url: URL, task: String? = nil, newTask: Bool = false) {
        // Clicking the folder that is already open just shows it (a new task only via its + button).
        if !newTask, task == nil, workspace?.standardizedFileURL.path == url.standardizedFileURL.path, bench != nil { return }
        // A whole home / Documents / Desktop / Downloads folder is almost never the project.
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let broad = [home] + ["Documents", "Desktop", "Downloads", "Library"].map { home.appendingPathComponent($0) } + [URL(fileURLWithPath: "/")]
        if broad.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
            let a = NSAlert()
            a.messageText = L10n.f("Use all of “%@” as the workspace?", url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
            a.informativeText = L("SieveSci keeps a history of the workspace and lets agents read and write inside it. A folder for one project is safer and faster.")
            a.addButton(withTitle: L("Choose a project folder…"))
            a.addButton(withTitle: L("Use it anyway"))
            if a.runModal() == .alertFirstButtonReturn {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.directoryURL = url
                panel.prompt = L("Open Workspace")
                if panel.runModal() == .OK, let picked = panel.url, picked != url { open(workspace: picked, task: task) }
                return
            }
        }
        // The folder being left stays as it was shown: open by default while current, it would
        // otherwise fold away in the sidebar on the switch.
        if let old = workspace?.path, old != url.path, config.folderOpen[old] == nil { config.folderOpen[old] = true }
        workspace = url
        config.recentWorkspaces.removeAll { $0 == url.path }
        config.recentWorkspaces.insert(url.path, at: 0)
        config.recentWorkspaces = Array(config.recentWorkspaces.prefix(12))
        // Opening a folder resumes its latest task; a new one is started only when asked (the + button).
        startSession(task: newTask ? nil : (task ?? SessionStore.tasks(in: url).first?.id))
    }

    func resetActivity() {
        streams = ["main": []]
        cards = [:]
        toolIndex = [:]
        lastTool = [:]
        openText = [:]
        openThinking = [:]
        jobs = [:]
        jobOrder = []
        changedFiles = []
        literatureLog = []
        figures = []
        history = []
        queued = []
        contested = []
        pendingAsk = nil
        brainstorm = nil
        ideas = []
    }

    /// Opens a task. A turn still running elsewhere keeps going in the background (switching never
    /// stops or hijacks it); restarting the same task (e.g. a model switch) stops its turn first, so
    /// two sessions never work on one task.
    func startSession(task: String? = nil, restart: Bool = false) {
        guard workspace != nil else { return }
        // Opening the task that is already open is not a restart: it must never stop a running turn.
        if let task, task == taskId, bench != nil, !restart { return }
        if let old = bench, old.isRunning, !taskId.isEmpty {
            if task == taskId {
                old.interrupt()
                Task { @MainActor in
                    for _ in 0..<60 where old.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
                    old.services.kernel.shutdownAll()
                    self.beginSession(task: task)
                }
                return
            }
            background[taskId] = old
            backgroundTasks.insert(taskId)
            if let ws = workspace { backgroundWorkspaces[taskId] = ws.standardizedFileURL.path }
        } else {
            bench?.services.kernel.shutdownAll()
        }
        beginSession(task: task)
    }

    private func beginSession(task: String?) {
        guard let ws = workspace else { return }
        resetActivity()
        let id = task ?? (ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate]) + "-" + String(UUID().uuidString.prefix(6)).lowercased())
        taskId = id
        if let live = background.removeValue(forKey: id) {
            backgroundTasks.remove(id)
            backgroundWorkspaces.removeValue(forKey: id)
            attach(live, id: id)
            return
        }
        do {
            let services = try SessionServices(taskId: id, workspace: ws, models: try roleModels(), secrets: secrets,
                                               webSearch: config.webSearch, permissionMode: config.permissionMode,
                                               contactEmail: config.contactEmail, retention: config.retention)
            ConfiguredModels.apply(config, to: services, secrets: secrets)
            services.asks.interactive = true
            // Ideas a background dream left: said once, when a task of this workspace opens.
            let unseen = DreamInbox.unseen(ws).count
            if unseen > 0, !dreamNoticeShown.contains(ws.path) {
                dreamNoticeShown.insert(ws.path)
                notifier.post(title: L("SieveSci dreamed"), body: L10n.f("%d new idea(s) from dreaming. Type /ideas dream to read them.", unseen), id: "dream-\(ws.path.hashValue)")
                if task != nil { append(.notice(L10n.f("%d new idea(s) from dreaming. Type /ideas dream to read them.", unseen)), to: "main") }
            }
            services.emit = { [weak self] ev in Task { @MainActor in self?.route(ev, task: id) } }
            services.requestPermission = { [weak self] req in
                await withCheckedContinuation { cont in
                    Task { @MainActor in
                        guard let self else { cont.resume(returning: .deny("window closed")); return }
                        if id != self.taskId {
                            // A background task asks: it waits for the user to come back to it.
                            self.backgroundAsks[id] = (req, cont)
                            self.refreshStage(id, notify: false)   // the ask posts its own notification
                            self.notifier.post(title: L("Permission needed"), body: self.title(of: id) + " · \(req.tool): \(req.summary.prefix(120))", id: "perm-\(req.id)")
                            return
                        }
                        self.permissionContinuation = cont
                        self.pendingPermission = req
                        self.refreshStage(id, notify: false)
                        NSApp.requestUserAttention(.informationalRequest)
                        if self.config.notifyPermission {
                            self.notifier.post(title: L("Permission needed"), body: "\(req.tool): \(req.summary.prefix(140))", id: "perm-\(req.id)")
                        }
                    }
                }
            }
            let bench = Workbench(services: services)
            bench.autoWake = config.autoWake
            bench.autoTitle = config.autoTitles && !Self.isDemo
            bench.onOutput = { [weak self] text in Task { @MainActor in self?.append(.notice(text), to: "main") } }
            self.bench = bench
            let (p, m) = services.models.main
            meter = ContextMeter(model: m, contextWindow: ModelDiscovery.effectiveSettings(model: m, profile: p.profile, discovered: nil).contextWindow)
            let start = Task { await bench.start() }
            starting = start
            Task {
                await start.value
                // Decoded off the main thread: a long task's audit log is tens of MB (this froze the window).
                let transcript = bench.main.transcript
                let restored = await Task.detached(priority: .userInitiated) {
                    DisplayTimeline.merge(transcript, audit: DisplayTimeline.auditEntries(services.audit.url))
                }.value
                await MainActor.run {
                    self.commandCatalog = SlashCommands.catalog(workspace: ws, skills: services.skills)
                    self.replay(restored)
                    self.refreshSidePanels()
                }
                await self.refreshHistory()
                await self.refreshQuotas()
            }
            refreshTaskList()
            lastError = nil
            refreshStage(id, notify: false)
        } catch {
            bench = nil
            starting = nil
            lastError = error.localizedDescription
        }
    }

    /// Returns to a task whose session kept working in the background.
    private func attach(_ live: Workbench, id: String) {
        bench = live
        let (p, m) = live.services.models.main
        meter = ContextMeter(model: m, contextWindow: ModelDiscovery.effectiveSettings(model: m, profile: p.profile, discovered: nil).contextWindow)
        replay(live.main.transcript)
        running = live.isRunning
        if running {
            runStarted = Date()
            spinnerVerb = Self.verbs.randomElement()!
            append(.notice(L("Still working on this task; new output appears below.")), to: "main")
        }
        // A CLI agent's tool calls are only in the audit log; they are merged in off the main thread. The chat
        // is rebuilt only while idle, since live tool rows keep indices into it.
        let transcript = live.main.transcript, url = live.services.audit.url
        if !running {
            Task {
                let merged = await Task.detached(priority: .userInitiated) { DisplayTimeline.merge(transcript, audit: DisplayTimeline.auditEntries(url)) }.value
                guard self.bench === live, !self.running, !live.isRunning, merged.count != transcript.count else { return }
                self.streams["main"] = []
                self.replay(merged)
            }
        }
        if let (req, cont) = backgroundAsks.removeValue(forKey: id) {
            permissionContinuation = cont
            pendingPermission = req
        }
        pendingAsk = live.services.asks.first
        ideas = live.services.ideas.snapshot
        brainstorm = live.services.ideas.live
        refreshSidePanels()
        refreshStage(id, notify: false)
        Task { await refreshHistory() }
    }

    /// Rebuilds the visible transcript from a restored session.
    func replay(_ msgs: [Message]) {
        var results: [String: ToolResult] = [:]
        for m in msgs { for b in m.blocks { if case .toolResult(let r) = b { results[r.toolUseId] = r } } }
        for m in msgs {
            for b in m.blocks {
                switch b {
                case .text(let t) where m.role == .user && !HostContext.isHostBlock(t):
                    let own = HostContext.userText(t)
                    if !own.isEmpty, !own.hasPrefix("[tool result") { append(.user(own, attachments: []), to: "main") }
                case .text(let t) where m.role == .assistant:
                    append(.assistant(t), to: "main")
                case .toolUse(let tu):
                    var c = ToolCallView(id: tu.id, name: tu.name, summary: Self.summary(tu.name, tu.input), input: tu.input)
                    c.ended = Date()
                    if let r = results[tu.id] { c.output = r.content; c.isError = r.isError }
                    append(.tool(c), to: "main")
                default: break
                }
            }
        }
    }

    // MARK: Input

    func submit(_ text: String, attachments: [URL]) {
        if bench == nil { resumeIfNeeded() }
        guard let bench else {
            // Never drop what the user typed: put it back and let the setup card explain what is missing.
            draft = text
            if lastError == nil { lastError = workspace == nil ? L("Open a workspace first.") : L("No model is set up yet.") }
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        // Commands that open native UI.
        if trimmed == "/providers" { openSettings(.providers); return }
        if trimmed == "/config" { openSettings(); return }
        if trimmed == "/clear" { startSession(); return }
        if trimmed == "/fork" { fork(); return }
        if trimmed == "/doctor" { Task { let r = await Doctor.run(model: self); append(.notice(r), to: "main") }; return }
        append(.user(trimmed, attachments: attachments.map(\.lastPathComponent)), to: "main")
        if brainstorm?.endedAt != nil { brainstorm = nil }
        openText["main"] = nil
        openThinking["main"] = nil
        if running {
            queued.append(trimmed)
        } else {
            running = true
            runStarted = Date()
            spinnerVerb = Self.verbs.randomElement()!
        }
        let atts = attachments.map { Attachment.file($0) }
        if taskTitles[taskId] == nil, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("!") {
            let first = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
            taskTitles[taskId] = first.count > 80 ? String(first.prefix(79)) + "…" : first
        }
        let starting = self.starting
        Task {
            // A message sent right after a task opens waits until the session has started.
            await starting?.value
            await bench.submit(trimmed, attachments: atts)
            await MainActor.run { self.turnMaybeEnded() }
            await self.refreshQuotas()
        }
    }

    /// What an integrity signal means, in the interface language (the detail stays as detected).
    static func signalTitle(_ k: IntegritySignal.Kind) -> String {
        switch k {
        case .codeHack: return L("Questionable code")
        case .falseCompletion: return L("Success claimed after a failure")
        case .ignoredError: return L("Error not mentioned")
        case .scopeShrink: return L("Scope reduced")
        case .syntheticData: return L("Synthetic data")
        case .ungrounded: return L("Not backed by evidence")
        case .harking: return L("Criteria changed after results")
        case .breakthrough: return L("Strong claim — needs verification")
        case .checkpoint: return L("Checkpoint")
        case .ideation: return L("Idea under review")
        }
    }

    static let verbs = ["Sieving", "Hypothesizing", "Assaying", "Titrating", "Sequencing", "Pipetting", "Cross-checking", "Annotating", "Centrifuging", "Incubating"]

    func turnMaybeEnded() {
        guard let bench else { return }
        queued = bench.queuedPrompts
        let was = running
        running = bench.isRunning
        if was && !running {
            refreshSidePanels()
            refreshTaskList()
            Task { await refreshHistory() }
            if config.notifyTurnFinished {
                let last = items.last { if case .assistant = $0.kind { return true }; return false }
                notifier.post(title: L("SieveSci finished"), body: String(last?.searchableText.prefix(160) ?? ""), id: "turn-\(taskId)")
            }
        }
    }

    func interrupt() {
        bench?.interrupt()
        running = false
    }

    func fork() {
        guard let bench, let ws = workspace else { return }
        let msgs = bench.main.transcript
        let newId = taskId + "-fork-" + String(UUID().uuidString.prefix(4)).lowercased()
        let dir = ws.appendingPathComponent(".sievesci/tasks/\(newId)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for m in msgs { SessionStore.shared.append(m, task: newId, agent: "main", dir: dir) }
        startSession(task: newId)
    }

    /// "Rewind to here": number of user turns after (and including) this item.
    func rewind(to item: TranscriptItem, edit: Bool) {
        let users = items.filter { if case .user = $0.kind { return true }; return false }
        guard let i = users.firstIndex(where: { $0.id == item.id }) else { return }
        let n = users.count - i
        if edit, case .user(let t, _) = item.kind { draft = t }
        submit("/rewind \(n)", attachments: [])
        if let cut = streams["main"]?.firstIndex(where: { $0.id == item.id }) { streams["main"]?.removeSubrange(cut...) }
    }

    /// Answers the open question card (the waiting tool call, or a question left from the last run).
    func answerAsk(_ outcome: AskOutcome) {
        guard let req = pendingAsk, let bench else { return }
        pendingAsk = nil
        Task {
            await bench.answerAsk(req.id, outcome)
            await MainActor.run {
                self.pendingAsk = bench.services.asks.first
                self.refreshStage(self.taskId)
                if case .answered = outcome, !bench.isRunning { self.turnMaybeEnded() }
            }
        }
    }

    /// Brainstorm controls: finish with what is there, or stop the turn.
    func wrapUpBrainstorm() { bench?.wrapUpBrainstorm() }

    func answerPermission(_ d: PermissionDecision) {
        pendingPermission = nil
        permissionContinuation?.resume(returning: d)
        permissionContinuation = nil
        refreshStage(taskId)
    }

    func cyclePermissionMode() {
        let all = PermissionMode.allCases
        let next = all[(all.firstIndex(of: config.permissionMode)! + 1) % all.count]
        setPermissionMode(next)
    }

    func setPermissionMode(_ m: PermissionMode) {
        config.permissionMode = m
        bench?.services.permissions.mode = m
    }

    /// Plan mode → approve the plan and let the agent execute with edits auto-accepted.
    func approvePlan() {
        setPermissionMode(.acceptEdits)
        submit(L("The plan is approved. Proceed with it."), attachments: [])
    }

    func openSettings(_ pane: SettingsPane? = nil) {
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: SettingsPane.storageKey) }
        showSettingsPage = true
    }

    /// The workspace's conversations, plus the open one even before its first message (it is listed
    /// on disk only once it has one).
    func refreshTaskList() {
        guard let ws = workspace else { return }
        var list = SessionStore.tasks(in: ws)
        if !taskId.isEmpty, !list.contains(where: { $0.id == taskId }) {
            list.insert((taskId, tasks.first { $0.id == taskId }?.modified ?? Date()), at: 0)
        }
        if list.map(\.id) != tasks.map(\.id) || list.map(\.modified) != tasks.map(\.modified) { tasks = list }
    }

    /// Moves a conversation to the Trash after confirming. A turn still running in it is stopped first;
    /// deleting the open conversation opens the next most recent one (or a new one).
    func deleteTask(_ id: String) {
        guard let ws = workspace else { return }
        let a = NSAlert()
        a.messageText = L10n.f("Delete “%@”?", title(of: id))
        a.informativeText = L("The conversation and its records are moved to the Trash.")
        a.addButton(withTitle: L("Move to Trash"))
        a.addButton(withTitle: L("Cancel"))
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if let b = background.removeValue(forKey: id) {
            b.interrupt(); b.services.kernel.shutdownAll()
            backgroundTasks.remove(id); backgroundWorkspaces.removeValue(forKey: id)
        }
        let wasOpen = id == taskId
        if wasOpen, let b = bench {
            b.interrupt(); b.services.kernel.shutdownAll()
            bench = nil; taskId = ""; resetActivity()
        }
        attention[id] = nil
        do { try SessionStore.trash(task: id, in: ws) } catch { lastError = error.localizedDescription }
        refreshTaskList()
        if wasOpen { startSession(task: tasks.first?.id) }
    }

    /// Starts (or resumes) a session when a workspace is open but none is running — after launch,
    /// after Settings, or when the user sends a message.
    func resumeIfNeeded() {
        guard let ws = workspace, bench == nil, !Self.isDemo else { return }
        startSession(task: taskId.isEmpty ? SessionStore.tasks(in: ws).first?.id : taskId)
    }

    /// Welcome checklist: which models are ready, and how web search will work right now.
    var modelStatus: (ready: Bool, text: String) { ConfiguredModels.modelStatus(config, secrets: secrets) }
    var searchStatus: (ready: Bool, text: String) { ConfiguredModels.searchStatus(config, secrets: secrets) }

    /// No usable model yet: the composer shows a setup card instead of failing silently.
    var needsModelSetup: Bool { workspace != nil && bench == nil && usableProviders.isEmpty }

    func refreshTaskTitles() {
        guard let ws = workspace else { return }
        var t = taskTitles
        for task in tasks where t[task.id] == nil {
            if let title = SessionStore.title(dir: ws.appendingPathComponent(".sievesci/tasks/\(task.id)")) { t[task.id] = title }
        }
        if t != taskTitles { taskTitles = t }
    }

    func title(of task: String) -> String { taskTitles[task] ?? L("New task") }

}
