import Foundation

/// Model routing for the roles. The checker and verifier may use a different vendor than the main
/// agent (cross-vendor review is the strongest independence), or the same one.
public struct RoleModels: Sendable {
    public var main: (LLMProvider, String)
    public var checker: (LLMProvider, String)
    public var verifier: (LLMProvider, String)
    public var worker: (LLMProvider, String)

    public init(main: (LLMProvider, String), checker: (LLMProvider, String)? = nil, verifier: (LLMProvider, String)? = nil,
                worker: (LLMProvider, String)? = nil) {
        self.main = main
        self.checker = checker ?? main
        self.verifier = verifier ?? main
        self.worker = worker ?? main
    }

    /// Every other usable model, for picking a different reviewer when one declines or fails.
    /// Preferably a different vendor than the role's primary model.
    public var alternates: [(LLMProvider, String)] = []

    /// An alternate reviewer for `role`, preferring a different vendor than the one that failed.
    public func alternate(for role: AgentRole, excluding tried: Set<String>) -> (LLMProvider, String)? {
        let primary = pick(role)
        let pool = alternates.filter { !tried.contains($0.0.profile.id + "/" + $0.1) && ($0.0.profile.id != primary.0.profile.id || $0.1 != primary.1) }
        return pool.first { $0.0.profile.id != primary.0.profile.id } ?? pool.first
    }

    func pick(_ role: AgentRole) -> (LLMProvider, String) {
        switch role {
        case .main: return main
        case .checker: return checker
        case .verifier: return verifier
        case .worker: return worker
        }
    }
}

public struct SupervisorPolicy: Codable, Sendable {
    /// Upper bound on checker/verifier runs per session (each costs tokens).
    public var maxReviewsPerSession = 24
    /// Max consecutive supervisor interventions inside one user turn before handing back to the user.
    public var maxInterventionsPerTurn = 2
    /// Minimum severity that dispatches the checker on its own (checkpoints/claims always do).
    public var minSeverity = 3
    public var verifyClaims = true
    public init() {}
}

/// Shared, per-task services. One instance per research task; the main agent and all its
/// subagents use it, so they share the ledger, library, plan, claims and audit trail.
public final class SessionServices: @unchecked Sendable {
    public let taskId: String
    public let workspace: URL
    /// Folders outside the workspace that agents may read but never write (`.sievesci/folders.json`),
    /// e.g. an earlier project whose results the task builds on. Hidden from blind agents.
    public var readOnlyFolders: [URL] { ReadOnlyFolders.load(workspace: workspace) }
    public let taskDir: URL
    public let ledger: EvidenceLedger
    public let audit: AuditLog
    public let research: ResearchProtocol
    public let claims: ClaimLedger
    public let library: LiteratureLibrary
    public let notebook: LabNotebook
    public let permissions: PermissionPolicy
    public var webSearch: WebSearchClient
    /// Provider-native search (ZCode-style nested request), preferred when the main vendor offers it.
    public var nativeSearch: NativeWebSearch?
    public var models: RoleModels
    public var supervisorPolicy: SupervisorPolicy
    /// When the host hands independent plan steps to workers on its own (see `HostDelegation`).
    public var delegation = DelegationPolicy()
    /// Live subagents, so Stop ends them with the main agent.
    let subagents = SubagentRegistry()
    public let skills: SkillRegistry
    public let mcp: MCPManager
    public let hooks: HookRunner
    public let kernel: PythonKernelPool
    public let checkpoints: CheckpointStore
    public let goal: GoalController
    public let todos: TodoList
    public let governor: EvolutionGovernor
    public let git: GitHistory
    public let changes = ChangeTracker()
    /// Describes images for roles whose model cannot read them.
    public let vision = VisionAdapter()
    private var memories: [AgentRole: MemoryStore] = [:]
    private let memLock = NSLock()
    /// Streaming background jobs and file tails, with notifications to the agents.
    public let jobs: JobMonitor
    /// The tool list, frozen once per session (built-ins + MCP tools discovered at start). Every
    /// role gets the same list so prefixes stay identical; roles differ only in what is allowed.
    public internal(set) var toolset: [Tool] = []
    private var _supervisor: Supervisor?
    public var effort: Effort?
    /// Seatbelt sandbox for agent-run shell commands and Python (macOS; no-op elsewhere).
    public var sandboxMode: SandboxMode = .workspaceWrite
    public var retention: CacheRetention
    public let secrets: SecretStore

    /// UI callbacks. `emit` must be cheap; `requestPermission` may suspend until the user answers.
    public var emit: @Sendable (AgentEvent) -> Void = { _ in }
    public var requestPermission: @Sendable (PermissionRequest) async -> PermissionDecision = { _ in .deny("no UI attached") }
    let permissionQueue = PermissionQueue()

    /// Asks the user, one request at a time (parallel workers may ask concurrently).
    func askUser(_ req: PermissionRequest) async -> PermissionDecision {
        let handler = requestPermission
        return await permissionQueue.ask(req, handler)
    }

    public init(taskId: String, workspace: URL, models: RoleModels, secrets: SecretStore, webSearch: WebSearchConfig = WebSearchConfig(),
                permissionMode: PermissionMode = .ask, contactEmail: String = "", retention: CacheRetention = .short,
                http: HTTPStreaming = URLSessionStreaming()) throws {
        self.taskId = taskId
        self.workspace = workspace.standardizedFileURL
        taskDir = workspace.appendingPathComponent(".sievesci/tasks/\(taskId)")
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        // Research state persists per task, so a resumed session keeps the receipts, plan and claims
        // its transcript cites (see ResearchState.swift).
        let state = taskDir.appendingPathComponent("state")
        ledger = EvidenceLedger(dir: state)
        audit = try AuditLog(url: taskDir.appendingPathComponent("audit.jsonl"))
        research = ResearchProtocol(ledger: ledger, stateURL: state.appendingPathComponent("plan.json"))
        claims = ClaimLedger(stateURL: state.appendingPathComponent("claims.json"))
        // One library per workspace: a new task starts with the papers earlier tasks fetched.
        let shared = workspace.appendingPathComponent(".sievesci/library")
        LiteratureLibrary.adoptTaskLibraries(into: shared, tasks: workspace.appendingPathComponent(".sievesci/tasks"))
        library = try LiteratureLibrary(dir: shared, contactEmail: contactEmail, http: http)
        library.openAlexKey = secrets.secret(for: "OPENALEX_API_KEY")
        notebook = LabNotebook(url: taskDir.appendingPathComponent("notebook.md"), taskId: taskId)
        permissions = PermissionPolicy(mode: permissionMode)
        self.webSearch = WebSearchClient(config: webSearch, secrets: secrets, http: http)
        nativeSearch = NativeWebSearch.forProfile(models.main.0.profile, model: models.main.1, secrets: secrets)
        self.models = models
        supervisorPolicy = SupervisorPolicy()
        skills = SkillRegistry(workspace: workspace)
        mcp = MCPManager(workspace: workspace)
        hooks = HookRunner(workspace: workspace)
        kernel = PythonKernelPool(workspace: workspace)
        checkpoints = CheckpointStore(dir: taskDir.appendingPathComponent("checkpoints"))
        goal = GoalController()
        todos = TodoList()
        governor = EvolutionGovernor()
        git = GitHistory(workspace: workspace.standardizedFileURL)
        jobs = JobMonitor(dir: taskDir.appendingPathComponent("jobs"))
        self.retention = retention
        self.secrets = secrets
        notebook.attach(to: audit)
        if !ledger.tamperedOutputs.isEmpty {
            audit.append(session: taskId, kind: "state_integrity", actor: "host",
                         ["tampered_outputs": .array(ledger.tamperedOutputs.map { .string($0) })])
        }
        jobs.emit = { [weak self] e in self?.emit(e) }
    }

    /// Builds the frozen toolset: built-ins plus tools from connected MCP servers. Call once,
    /// before the first model request; later MCP changes apply to the next session.
    public func freezeToolset(extra: [Tool] = []) async {
        guard toolset.isEmpty else { return }
        let mcpTools = await mcp.connectAll()
        toolset = (BuiltinTools.all() + mcpTools + extra).sorted { $0.name < $1.name }
    }

    public func supervisor(for session: AgentSession) -> Supervisor {
        if let s = _supervisor { return s }
        let s = Supervisor(services: self)
        _supervisor = s
        return s
    }

    private var _deliberation: Deliberation?
    private let delibLock = NSLock()
    /// Reviews that could not be obtained (declined, failed, no verdict). See `Refusals`.
    public let refusals = RefusalLog()

    /// Bounded agent-to-agent deliberation over reviews (see `Deliberation`).
    public var deliberation: Deliberation {
        delibLock.lock(); defer { delibLock.unlock() }
        if let d = _deliberation { return d }
        let d = Deliberation(services: self)
        _deliberation = d
        return d
    }

    public var supervisor: Supervisor {
        if let s = _supervisor { return s }
        let s = Supervisor(services: self)
        _supervisor = s
        return s
    }

    /// Creates a subagent sharing this task's ledger, library and audit trail. Subagents of one
    /// role share a lineage key, so repeated checker runs hit the same cached prefix.
    public func makeSubagent(role: AgentRole, writeRoot: URL? = nil, blinded: [String] = [], readable: [String]? = nil,
                             purpose: String = "", parent: String = "main") -> AgentSession {
        let window = ModelDiscovery.effectiveSettings(model: models.pick(role).1, profile: models.pick(role).0.profile, discovered: nil).contextWindow
        // The checker is read-only, so it is offered only what it may use.
        let tools = role == .checker ? toolset.filter { $0.effect(for: [:]) == .readOnly } : toolset
        let s = AgentSession(id: "\(role.rawValue)-" + String(UUID().uuidString.prefix(6)).lowercased(), role: role, services: self, tools: tools,
                             lineageKey: taskId + "-" + role.rawValue,
                             writeRoot: writeRoot ?? (role == .worker ? taskDir.appendingPathComponent("workers") : nil),
                             blindedPaths: blinded, readableRoots: readable, contextWindow: window)
        s.purpose = purpose
        s.parentId = parent
        subagents.add(s)
        // A review reads what exists and gives a verdict; a verifier reruns one claim. Bounded, so a
        // wandering reviewer cannot spend a main turn's worth of tokens.
        s.maxSteps = switch role { case .checker: 18; case .verifier: 40; case .worker: 80; case .main: 200 }
        return s
    }

    /// Where role memories live. Evaluation runs point it at a scratch directory so they neither read
    /// nor teach the user's real memories. Set it before the first `memory(for:)` call.
    public var memoryRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/memory")

    /// Per-skill Python environments (`~/.sievesci/envs`). Replaceable for tests and evaluation runs.
    public var environments = SkillEnvironments()

    /// Role-scoped long-term memory (`<memoryRoot>/<role>/`, by default `~/.sievesci/memory/<role>/`).
    public func memory(for role: AgentRole) -> MemoryStore {
        memLock.lock(); defer { memLock.unlock() }
        if let m = memories[role] { return m }
        let m = MemoryStore(dir: memoryRoot.appendingPathComponent(role.rawValue))
        memories[role] = m
        return m
    }

    /// Whether the model a role uses accepts image input (models.dev / listing / ZCode rules / overrides).
    public func supportsImages(_ role: AgentRole) -> Bool {
        let (p, m) = models.pick(role)
        if ModelDiscovery.effectiveSettings(model: m, profile: p.profile, discovered: nil).supportsImages { return true }
        // Not known to take images: catalogs lag behind models that gain vision, so images go natively
        // once; a refusal is learned and falls back to the vision helper (`AgentSession.callModel`).
        // A setting the user made, and CLI agents (they attach files themselves), are left as they are.
        return p.profile.family != .cliAgent && !p.profile.modelSettings.contains { $0.id == m }
            && ModelCapabilities.shared.learnedImages(m, profile: p.profile.id) == nil
    }

    /// Session-constant context for a role's first user turn: its memory snapshot and its skills.
    public func roleIntro(_ role: AgentRole) -> String {
        [memory(for: role).snapshot, skills.index(for: role)].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Files written by a given role so far (used to blind the verifier to the main agent's work).
    public func filesWritten(by role: AgentRole) -> [String] {
        Array(Set(ledger.all.filter { $0.role == role }.flatMap { $0.filesWritten.keys })).sorted()
    }

    public func log(_ kind: String, actor: String, _ data: JSON) {
        audit.append(session: taskId, kind: kind, actor: actor, data)
    }
}

/// The workspace's list of read-only folders, `.sievesci/folders.json` (an array of absolute paths).
public enum ReadOnlyFolders {
    static func url(_ workspace: URL) -> URL { workspace.appendingPathComponent(".sievesci/folders.json") }

    public static func load(workspace: URL) -> [URL] {
        guard let d = try? Data(contentsOf: url(workspace)), let paths = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func add(_ folder: URL, workspace: URL) throws {
        var paths = load(workspace: workspace).map(\.path)
        let p = FilePaths.canonical(folder.path)
        guard !paths.contains(p), p != FilePaths.canonical(workspace.path) else { return }
        paths.append(p)
        try FileManager.default.createDirectory(at: url(workspace).deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(paths.sorted()).write(to: url(workspace), options: .atomic)
    }

    public static func remove(_ folder: URL, workspace: URL) throws {
        let paths = load(workspace: workspace).map(\.path).filter { $0 != FilePaths.canonical(folder.path) }
        try JSONEncoder().encode(paths).write(to: url(workspace), options: .atomic)
    }
}
