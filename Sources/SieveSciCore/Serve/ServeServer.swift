import Foundation

/// The JSON-RPC side of `sievesci serve` (docs/SERVE_PROTOCOL.md): requests in, responses and
/// notifications out, one JSON object per line. It does for a front end what the macOS app's
/// `AppModel` does for SwiftUI: the configuration and keys, workspaces, live tasks (the open one and
/// any still running in the background), their events and stages, and conversation actions.
/// Transport is the caller's: `handle` takes request lines, `write` sends lines.
public final class ServeServer: @unchecked Sendable {
    public static let protocolVersion = 2

    /// Builds the services for a task in a workspace from the current configuration.
    public typealias ServicesFactory = @Sendable (_ taskId: String, _ workspace: URL, _ config: AppConfig) throws -> SessionServices

    let info: [String: JSON]
    let makeServices: ServicesFactory
    let write: @Sendable (String) -> Void
    /// Where API keys are read (the store the factory uses) and, when writable, saved.
    let secrets: SecretStore
    let keyStore: PlatformSecretStore?

    final class Live {
        let id: String
        let workspace: URL
        let bench: Workbench
        var permission: String?
        /// The request on screen, sent again when the task is reopened (a front end that switched away
        /// dropped it, and the agent waits for it).
        var pendingRequest: PermissionRequest?
        /// The session's start (tools and MCP servers, the workspace's baseline commit, the saved
        /// transcript): `task.open` answers before it ends, as the app shows a task at once; a message
        /// waits for it.
        var ready: Task<Void, Never>?
        var lastError: String?
        var stage: TaskStage?
        init(id: String, workspace: URL, bench: Workbench) { self.id = id; self.workspace = workspace; self.bench = bench }
    }

    let lock = NSLock()
    var config: AppConfig
    private var saveConfig: Bool
    private var workspace: URL?
    var live: [String: Live] = [:]
    /// Tasks being started: a second `task.open` of the same task waits for the first instead of
    /// starting the same task twice (two sessions writing one transcript).
    var opening: [String: Task<Live, Error>] = [:]
    /// Tasks still shutting down after a switch away (`close(background:)`): reopening one waits for that,
    /// so two sessions never write one task's audit log and transcript at once.
    var closing: [String: Task<Void, Never>] = [:]
    var currentKey: String?
    /// The catalog and leaderboard refresh under way (one at a time; a second request joins it).
    var catalogRefresh: Task<[String], Never>?
    /// Permission request id → the live task asking.
    private var askers: [String: String] = [:]
    private var waiters: [String: CheckedContinuation<PermissionDecision, Never>] = [:]
    /// Answers that arrived before their request reached the front of the permission queue.
    private var early: [String: PermissionDecision] = [:]
    private var closed = false

    /// `info` is merged into the `initialize` result. `saveConfig` writes configuration changes to disk
    /// (off in tests and when models come from command-line flags).
    public init(workspace: URL?, info: [String: JSON], config: AppConfig = AppConfig.load(), saveConfig: Bool = true,
                secrets: SecretStore = PlatformSecretStore.shared, keyStore: PlatformSecretStore? = PlatformSecretStore.shared,
                makeServices: @escaping ServicesFactory, write: @escaping @Sendable (String) -> Void) {
        self.workspace = workspace
        self.info = info
        self.config = config
        self.saveConfig = saveConfig
        self.secrets = secrets
        self.keyStore = keyStore
        self.makeServices = makeServices
        self.write = write
    }

    public var isClosed: Bool { lock.withLock { closed } }

    static func key(_ ws: URL, _ id: String) -> String { ws.standardizedFileURL.path + "|" + id }

    // MARK: Wire

    struct RPCError: Error { var code: Int; var message: String }

    func send(_ msg: JSON) {
        var m = msg.objectValue ?? [:]
        m["jsonrpc"] = "2.0"
        write(JSONCodec.canonicalString(.object(m)))
    }

    func notify(_ method: String, _ params: JSON) { send(["method": .string(method), "params": params]) }

    /// Handles one request line and writes its response. Lines that are not requests are answered
    /// with an error when they carry an id, and ignored otherwise.
    public func handle(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let msg = try? JSONCodec.parse(trimmed), msg.objectValue != nil else {
            send(["id": .null, "error": ["code": -32700, "message": "unreadable JSON"]])
            return
        }
        let id = msg["id"] ?? .null
        guard let method = msg.str("method") else {
            if !id.isNull { send(["id": id, "error": ["code": -32600, "message": "not a request"]]) }
            return
        }
        do {
            let result = try await dispatch(method, msg["params"] ?? .object([:]))
            if !id.isNull { send(["id": id, "result": result]) }
        } catch let e as RPCError {
            if !id.isNull { send(["id": id, "error": ["code": .int(e.code), "message": .string(e.message)]]) }
        } catch {
            if !id.isNull { send(["id": id, "error": ["code": -32000, "message": .string(error.localizedDescription)]]) }
        }
    }

    // MARK: Methods

    func dispatch(_ method: String, _ p: JSON) async throws -> JSON {
        switch method {
        case "initialize":
            var r = info
            r["name"] = "sievesci"
            r["version"] = .string(SieveSci.version)
            r["protocol"] = .int(Self.protocolVersion)
            r["workspace"] = lock.withLock { workspace }.map { .string($0.path) } ?? .null
            r["language"] = .string(L10n.resolved)
            r["languageChoice"] = .string(L10n.language.rawValue)
            #if os(macOS)
            r["platform"] = "macos"
            #elseif os(Windows)
            r["platform"] = "windows"
            #else
            r["platform"] = "linux"
            #endif
            // Whether commands can run sandboxed here (Seatbelt; none on Windows and Linux yet).
            r["sandbox"] = .bool(Seatbelt.available)
            return .object(r)
        case "language.set":
            // The interface language, shared with the macOS app and the CLI; texts serve sends
            // (stage labels, statuses, notices) follow it.
            guard let l = p.str("language").flatMap(L10n.Language.init(rawValue:)) else {
                throw RPCError(code: -32602, message: "language must be one of " + L10n.Language.allCases.map(\.rawValue).joined(separator: ", "))
            }
            L10n.language = l
            if let s = p.str("systemLanguage") { L10n.systemLanguage = s }
            return ["language": .string(L10n.resolved), "languageChoice": .string(l.rawValue)]

        case "config.get": return configPayload()
        case "config.set":
            guard let patch = p["patch"]?.objectValue else { throw RPCError(code: -32602, message: "patch (an object of configuration fields) is required") }
            try updateConfig(patch)
            return configPayload()
        case "secrets.set":
            guard let ref = p.str("ref"), !ref.isEmpty else { throw RPCError(code: -32602, message: "ref is required") }
            guard let store = keyStore else { throw RPCError(code: -32000, message: "keys come from the environment in this run") }
            try store.set(p.str("value") ?? "", for: ref)
            return configPayload()
        case "models.switchMain":
            // AppModel.switchMainModel: the lead agent's model; the open task restarts on it (task.open restart).
            guard let pid = p.str("providerId"), let m = p.str("model") else { throw RPCError(code: -32602, message: "providerId and model are required") }
            var c = lock.withLock { config }
            let ref = ModelRef(providerId: pid, model: m)
            if c.roles.mode == .same {
                c.roles.same = ref
            } else {
                c.roles.mode = .custom
                if c.roles.custom.isEmpty {
                    for (role, r) in RoleModelAdvisor.resolve(c.roles, candidates: ConfiguredModels.candidates(c, secrets: secrets)) { c.roles.custom[role.rawValue] = r }
                }
                c.roles.custom[AgentRole.main.rawValue] = ref
            }
            try updateConfig(["roles": Wire.value(c.roles)])
            return configPayload()
        case "commands.list":
            let catalog: [SlashCommandInfo] = lock.withLock { currentKey.flatMap { live[$0] } }
                .map { SlashCommands.catalog(workspace: $0.workspace, skills: $0.bench.services.skills) } ?? SlashCommands.builtins
            return ["commands": .array(catalog.map { ["name": .string($0.name), "args": .string($0.args), "summary": .string($0.summary), "group": .string($0.group)] })]

        case "workspace.open":
            guard let path = p.str("path") else { throw RPCError(code: -32602, message: "path is required") }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue else { throw RPCError(code: -32602, message: "no such folder: \(path)") }
            lock.withLock { workspace = url }
            // The first task opened here scans the installed skills; start that now, while the list shows.
            Task.detached(priority: .userInitiated) { _ = SkillRegistry(workspace: url) }
            // The sidebar keeps its folders where they are: an opened folder already on the list keeps its
            // place; a new one joins at the top.
            let listed = config.recentWorkspaces
            let order = listed.contains(url.path) ? listed : [url.path] + listed
            try updateConfig(["recentWorkspaces": .array(order.prefix(12).map { .string($0) })])
            return ["workspace": .string(url.path), "tasks": .array(taskList(url))]
        case "tasks.list":
            guard let ws = try? target(p).ws else { return ["tasks": []] }
            return ["tasks": .array(taskList(ws))]

        case "task.open": return try await open(p)
        case "task.send":
            let l = try current(p)
            // Files to attach (absolute paths, e.g. dropped on the window); text may then be empty.
            let files = (p["attachments"]?.arrayValue ?? []).compactMap(\.stringValue).filter { FileManager.default.fileExists(atPath: $0) }
            let text = p.str("text") ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { throw RPCError(code: -32602, message: "text is required") }
            let atts = files.map { Attachment.file(URL(fileURLWithPath: $0)) }
            // The turn runs on; its progress arrives as events. A message sent right after the task opened
            // waits until its session has started.
            Task.detached { await l.ready?.value; await l.bench.submit(text, attachments: atts) }
            return ["accepted": true]
        case "task.insert":
            // Into the running turn, read at the agent's next step (DeepSeek Harness's steering). With no
            // turn running the text is sent as an ordinary message; `fromQueue` moves a queued message.
            let l = try current(p)
            let text = p.str("text") ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RPCError(code: -32602, message: "text is required") }
            await l.ready?.value
            let fromQueue = p["fromQueue"]?.boolValue == true
            let inserted = l.bench.insert(text, fromQueue: fromQueue)
            if !inserted && !fromQueue { Task.detached { await l.bench.submit(text) } }
            return ["inserted": .bool(inserted)]
        case "task.stop":
            // Stop also answers the request on screen: an agent waiting for it would keep the turn alive.
            let l = try current(p)
            l.bench.interrupt()
            let k = Self.key(l.workspace, l.id)
            for id in lock.withLock({ askers.filter { $0.value == k }.map(\.key) }) { resolvePermission(id, .deny("stopped by the user")) }
            return .object([:])
        case "permission.respond":
            guard let id = p.str("id") else { throw RPCError(code: -32602, message: "id is required") }
            let d: PermissionDecision
            switch p.str("decision") {
            case "allow": d = .allowOnce
            case "always": d = .allowAlways
            case "deny": d = .deny(p.str("reason") ?? "")
            default: throw RPCError(code: -32602, message: "decision must be allow, always or deny")
            }
            resolvePermission(id, d)
            return .object([:])
        case "ask.respond":
            let l = try current(p)
            guard let id = p.str("id"), let o = p["outcome"].flatMap(Wire.askOutcome) else {
                throw RPCError(code: -32602, message: "id and outcome ({kind: answered, answers} or {kind: dismissed}) are required")
            }
            await l.bench.answerAsk(id, o)
            refreshStage(l)
            return .object([:])
        case "history.agent":
            // A reopened task's subagent card, expanded: the steps it took (left out of task.open).
            let l = try current(p)
            guard let agent = p.str("id") else { throw RPCError(code: -32602, message: "id is required") }
            return ["steps": .array(Self.agentSteps(taskDir: l.bench.services.taskDir, agent: agent))]
        case "brainstorm.wrapUp":
            try current(p).bench.wrapUpBrainstorm()
            return .object([:])

        case "task.rename":
            let (ws, id) = try target(p, needsTask: true)
            SessionStore.setTitle(p.str("title") ?? "", task: id!, in: ws)
            let title = SessionStore.title(dir: SessionStore.taskDir(id!, in: ws))
            return ["task": .string(id!), "title": title.map { .string($0) } ?? .null]
        case "task.delete":
            let (ws, id) = try target(p, needsTask: true)
            let k = Self.key(ws, id!)
            if let l = lock.withLock({ live[k] }) { await close(l) }
            try SessionStore.trash(task: id!, in: ws)
            return .object([:])
        case "task.fork":
            let (ws, id) = try target(p, needsTask: true)
            let newId = id! + "-fork-" + String(UUID().uuidString.prefix(4)).lowercased()
            let src = SessionStore.taskDir(id!, in: ws), dir = SessionStore.taskDir(newId, in: ws)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for m in SessionStore.load(dir: src, agent: "main") { SessionStore.shared.append(m, task: newId, agent: "main", dir: dir) }
            return ["task": .string(newId)]
        case "task.markdown":
            let (ws, id) = try target(p, needsTask: true)
            let dir = SessionStore.taskDir(id!, in: ws)
            let title = SessionStore.title(dir: dir) ?? L("New task")
            let md = "# " + title + "\n\n`" + id! + "`\n" + SessionStore.markdown(SessionStore.load(dir: dir, agent: "main"))
            // With `path` (from a save dialog), it is also written there.
            if let path = p.str("path"), !path.isEmpty { try md.writeReliably(to: URL(fileURLWithPath: path)) }
            return ["markdown": .string(md), "dir": .string(dir.path)]

        case "shutdown":
            await shutdown()
            return .object([:])
        default:
            if let r = try await settingsDispatch(method, p) { return r }
            if let r = try await panelsDispatch(method, p) { return r }
            throw RPCError(code: -32601, message: "unknown method \(method)")
        }
    }

    // MARK: Configuration

    func configPayload() -> JSON {
        let c = lock.withLock { config }
        let models = ConfiguredModels.modelStatus(c, secrets: secrets), search = ConfiguredModels.searchStatus(c, secrets: secrets)
        var keys: [String: JSON] = [:]
        for ref in c.providers.map(\.apiKeyRef) + [c.webSearch.apiKeyRef] where !ref.isEmpty { keys[ref] = .bool(secrets.secret(for: ref) != nil) }
        return ["config": Wire.value(c), "keys": .object(keys),
                "usable": .array(ConfiguredModels.usable(c, secrets: secrets).map { .string($0.id) }),
                "providers": providerInfo(c),
                "status": ["models": ["ready": .bool(models.ready), "text": .string(models.text)],
                           "search": ["ready": .bool(search.ready), "text": .string(search.text)]]]
    }

    /// Merges top-level fields into the configuration, saves it, and applies what live tasks use.
    func updateConfig(_ patch: [String: JSON]) throws {
        var merged = (Wire.value(lock.withLock { config }).objectValue) ?? [:]
        for (k, v) in patch { merged[k] = v }
        let data = try JSONEncoder().encode(JSON.object(merged))
        guard let next = try? JSONDecoder().decode(AppConfig.self, from: data) else { throw RPCError(code: -32602, message: "the configuration does not decode") }
        // AppConfig decodes leniently (an unknown value falls back to the default, so a newer field never
        // wipes a configuration); a front end gets told instead.
        let stored = Wire.value(next).objectValue ?? [:]
        // An optional field set to null is left out of the encoding.
        for (k, v) in patch where (stored[k] ?? .null) != v {
            throw RPCError(code: -32602, message: "invalid value for \(k)")
        }
        let lives = lock.withLock { () -> [Live] in config = next; return Array(live.values) }
        if saveConfig { next.save() }
        for l in lives {
            ConfiguredModels.apply(next, to: l.bench.services, secrets: secrets)
            l.bench.services.permissions.mode = next.permissionMode
            l.bench.autoTitle = next.autoTitles
            l.bench.autoWake = next.autoWake
            // Switching to a mode that allows the call on screen (auto, YOLO, accept edits for an edit)
            // lets it through, as if it had been asked under the new mode.
            if let r = lock.withLock({ l.pendingRequest }),
               l.bench.services.permissions.evaluate(tool: r.tool, input: r.input, effect: r.effect) == .allow {
                resolvePermission(r.id, .allowOnce)
            }
        }
    }

    // MARK: Tasks

    /// The workspace (`workspace` param, else the open one) and task (`id` or `task` param).
    func target(_ p: JSON, needsTask: Bool = false) throws -> (ws: URL, id: String?) {
        let ws = p.str("workspace").map { URL(fileURLWithPath: $0).standardizedFileURL } ?? lock.withLock { workspace }
        guard let ws else { throw RPCError(code: -32000, message: "no workspace is open; call workspace.open first") }
        let id = p.str("id") ?? p.str("task")
        if let id { guard Self.isValidTaskId(id) else { throw RPCError(code: -32602, message: "invalid task id") } }
        if needsTask, id == nil { throw RPCError(code: -32602, message: "id is required") }
        return (ws, id)
    }

    /// The live task a request acts on: the one named by `task`, else the open one.
    func current(_ p: JSON) throws -> Live {
        let l: Live? = lock.withLock {
            if let t = p.str("task"), let ws = p.str("workspace").map({ URL(fileURLWithPath: $0) }) ?? workspace { return live[Self.key(ws, t)] }
            return currentKey.flatMap { live[$0] }
        }
        guard let l else { throw RPCError(code: -32000, message: "no task is open; call task.open first") }
        return l
    }

    /// The task's live session: the one being started, the open one, or a new one. Opening a task
    /// twice at once (a double click, a restart racing a switch) starts it once.
    func liveTask(_ k: String, id: String, ws: URL) async throws -> Live {
        if let shuttingDown = lock.withLock({ closing[k] }) { await shuttingDown.value }
        let pending: Task<Live, Error> = lock.withLock {
            if let t = opening[k] { return t }
            if let l = live[k] { return Task { l } }
            let c = config
            let t = Task<Live, Error> { [self] in
                do {
                    let services = try makeServices(id, ws, c)
                    services.asks.interactive = true
                    let b = Workbench(services: services)
                    b.autoTitle = c.autoTitles
                    b.autoWake = c.autoWake
                    let made = Live(id: id, workspace: ws, bench: b)
                    services.emit = { [weak self, weak made] e in if let self, let made { self.event(e, made) } }
                    services.requestPermission = { [weak self] req in await self?.waitForPermission(req.id) ?? .deny("front end gone") }
                    b.onOutput = { [weak self] text in self?.notify("output", ["task": .string(id), "workspace": .string(ws.path), "text": .string(text)]) }
                    lock.withLock { live[k] = made }
                    made.ready = Task { await b.start() }
                    lock.withLock { opening[k] = nil }
                    return made
                } catch {
                    lock.withLock { opening[k] = nil }
                    throw error
                }
            }
            opening[k] = t
            return t
        }
        return try await pending.value
    }

    func taskList(_ ws: URL) -> [JSON] {
        let byKey = lock.withLock { live }
        return SessionStore.tasks(in: ws).map { t -> JSON in
            let l = byKey[Self.key(ws, t.id)]
            return ["id": .string(t.id), "title": SessionStore.title(dir: SessionStore.taskDir(t.id, in: ws)).map { .string($0) } ?? .null,
                    "modified": .string(ISO8601DateFormatter().string(from: t.modified)),
                    "running": .bool(l?.bench.isRunning ?? false), "stage": l?.stage.map(Self.stageJSON) ?? .null]
        }
    }

    func open(_ p: JSON) async throws -> JSON {
        let (ws, requested) = try target(p)
        let id = requested ?? Self.newTaskId()
        let k = Self.key(ws, id)
        // The task left open keeps running in the background when it is busy or waits for the user.
        let prev = lock.withLock { currentKey.flatMap { live[$0] } }.flatMap { Self.key($0.workspace, $0.id) != k ? $0 : nil }
        if let prev, !prev.bench.isRunning && prev.stage?.needsPerson != true { await close(prev, background: true) }
        // A restart (a model switch) stops the task's turn and starts it again on the new configuration.
        if p["restart"]?.boolValue == true, let old = lock.withLock({ live[k] }) {
            old.bench.interrupt()
            for _ in 0..<60 where old.bench.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
            await close(old, background: true)
        }
        let l = try await liveTask(k, id: id, ws: ws)
        lock.withLock { currentKey = k; workspace = ws }
        // Starting this one took a moment: the previous task may have finished meanwhile, while it was
        // still the open one (so its own release skipped it).
        if let prev, lock.withLock({ live[Self.key(prev.workspace, prev.id)] === prev }), !prev.bench.isRunning, prev.stage?.needsPerson != true {
            await close(prev, background: true)
        }
        let s = l.bench.services
        return [
            "task": .string(id), "workspace": .string(ws.path),
            "title": SessionStore.title(dir: s.taskDir).map { .string($0) } ?? .null,
            "running": .bool(l.bench.isRunning),
            // The lead agent's model and window, shown in the composer before the first reply (AppModel.open).
            "meter": Wire.meter(l.bench.main.meter),
            // The conversation as the chat showed it: reasoning, tool rows with diffs, subagent cards and their steps.
            "history": .array(Self.timeline(taskDir: s.taskDir)),
            "plan": Wire.value(s.research.snapshot), "claims": Wire.value(s.claims.snapshot), "ideas": Wire.value(s.ideas.snapshot), "brainstorm": s.ideas.live.map { Wire.value($0) } ?? .null,
            "asks": Wire.value(s.asks.pending), "stage": l.stage.map(Self.stageJSON) ?? .null,
            // The approval an agent of this task waits for; shown again, since a front end that switched away dropped it.
            "permission": lock.withLock { l.pendingRequest }.map(Wire.permission) ?? .null,
            // Ideas a background dream left in this workspace, not yet read (the app says so once).
            "dreams": .int(DreamInbox.unseen(ws).count),
            "contested": .array(s.deliberation.contested.map { ["thread": .string($0.thread), "kind": .string($0.kind), "issue": .string($0.issue), "reason": .string($0.reason)] }),
            "grounding": { let g = s.research.hasGrounding(); return ["web": .bool(g.web), "literature": .bool(g.literature)] }(),
        ]
    }

    // MARK: Events and stages

    func event(_ e: AgentEvent, _ l: Live) {
        switch e {
        case .permissionRequested(let r):
            lock.withLock { l.permission = "\(r.tool): \(r.summary)"; l.pendingRequest = r; askers[r.id] = Self.key(l.workspace, l.id) }
        case .turnStarted(_, "main"): lock.withLock { l.lastError = nil }
        case .error(let m): lock.withLock { l.lastError = m }
        default: break
        }
        var params = Wire.event(e).objectValue ?? [:]
        params["task"] = .string(l.id)
        params["workspace"] = .string(l.workspace.path)
        // Messages sent during a turn wait their turn; the list shrinks as each starts (the queued pills).
        switch e {
        case .turnStarted(_, "main"), .turnFinished("main", _): params["queued"] = .array(l.bench.queuedPrompts.map { .string($0) })
        default: break
        }
        notify("event", .object(params))
        switch e {
        case .textDelta, .thinkingDelta, .toolProgress, .jobOutput: return
        default: refreshStage(l)
        }
        // A background task is released once its turn has ended and it needs nobody (as the app does).
        // Work after the turn (a generated title, a job wake-up) can keep it busy a while: wait for that.
        if case .turnFinished("main", _) = e {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                for _ in 0..<3000 where l.bench.isRunning { try? await Task.sleep(nanoseconds: 200_000_000) }
                guard let self else { return }
                let isCurrent = self.lock.withLock { self.currentKey == Self.key(l.workspace, l.id) }
                let stillLive = self.lock.withLock { self.live[Self.key(l.workspace, l.id)] === l }
                self.refreshStage(l)
                if stillLive, !isCurrent, !l.bench.isRunning, l.stage?.needsPerson != true { await self.close(l) }
            }
        }
    }

    func refreshStage(_ l: Live) {
        var f = TaskStage.Facts()
        let s = l.bench.services
        lock.withLock { f.permissionAsk = l.permission; f.lastError = l.lastError }
        f.pendingAsk = s.asks.first?.summary
        f.goal = s.goal.current
        f.planMode = s.permissions.mode == .plan
        f.planHasSteps = !s.research.snapshot.steps.isEmpty
        f.contested = s.deliberation.contested.first.map { $0.issue }
        f.running = l.bench.isRunning
        f.runningJobs = s.jobs.runningCount
        let stage = TaskStage.of(f)
        let changed: Bool = lock.withLock { let c = l.stage != stage; l.stage = stage; return c }
        if changed {
            notify("taskStatus", ["task": .string(l.id), "workspace": .string(l.workspace.path), "running": .bool(l.bench.isRunning), "stage": Self.stageJSON(stage)])
        }
    }

    static func stageJSON(_ s: TaskStage) -> JSON {
        let kind: String
        switch s {
        case .answer: kind = "answer"
        case .review: kind = "review"
        case .blocked: kind = "blocked"
        case .working: kind = "working"
        case .waitingForJobs: kind = "waitingForJobs"
        case .idle: kind = "idle"
        }
        return ["kind": .string(kind), "label": .string(s.label), "detail": .string(s.detail), "needsPerson": .bool(s.needsPerson), "showsChip": .bool(s.showsChip)]
    }

    /// Task ids name folders under `.sievesci/tasks/`: no separators or `..` from a client.
    static func isValidTaskId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 100 && !id.contains("..")
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
    }

    static func newTaskId() -> String {
        ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate]) + "-" + String(UUID().uuidString.prefix(6)).lowercased()
    }

    // MARK: Permissions

    func waitForPermission(_ id: String) async -> PermissionDecision {
        await withCheckedContinuation { (c: CheckedContinuation<PermissionDecision, Never>) in
            let ready: PermissionDecision? = lock.withLock {
                if closed { return .deny("serve is shutting down") }
                if let d = early.removeValue(forKey: id) { return d }
                waiters[id] = c
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }

    func resolvePermission(_ id: String, _ d: PermissionDecision) {
        let (c, asker): (CheckedContinuation<PermissionDecision, Never>?, Live?) = lock.withLock {
            let l = askers.removeValue(forKey: id).flatMap { live[$0] }
            l?.permission = nil
            if l?.pendingRequest?.id == id { l?.pendingRequest = nil }
            if let c = waiters.removeValue(forKey: id) { return (c, l) }
            early[id] = d
            return (nil, l)
        }
        c?.resume(returning: d)
        if let asker {
            // Answered here (a mode switch, Stop) or by another window: the prompt goes away.
            notify("event", ["type": "permissionResolved", "id": .string(id), "task": .string(asker.id), "workspace": .string(asker.workspace.path)])
            refreshStage(asker)
        }
    }

    // MARK: Closing

    /// Closes a task. In the background (a switch to another task) its kernels and MCP servers stop
    /// after the call returns, so opening the next one does not wait for them.
    func close(_ l: Live, background: Bool = false) async {
        let k = Self.key(l.workspace, l.id)
        l.bench.interrupt()
        let pending: [CheckedContinuation<PermissionDecision, Never>] = lock.withLock {
            live[k] = nil
            if currentKey == k { currentKey = nil }
            let mine = askers.filter { $0.value == k }.map(\.key)
            mine.forEach { askers[$0] = nil }
            return mine.compactMap { waiters.removeValue(forKey: $0) }
        }
        for c in pending { c.resume(returning: .deny("task closed")) }
        notify("taskStatus", ["task": .string(l.id), "workspace": .string(l.workspace.path), "running": false, "stage": .null])
        let services = l.bench.services, ready = l.ready
        let stop = { await ready?.value; services.kernel.shutdownAll(); await services.mcp.shutdown() }
        if background {
            let t = Task.detached { await stop() }
            lock.withLock { closing[k] = t }
            Task.detached { [weak self] in await t.value; self?.lock.withLock { if self?.closing[k] == t { self?.closing[k] = nil } } }
        } else { await stop() }
    }

    /// Stops every live task and refuses further work.
    public func shutdown() async {
        let all: [Live] = lock.withLock { closed = true; return Array(live.values) }
        for l in all { await close(l) }
    }
}
