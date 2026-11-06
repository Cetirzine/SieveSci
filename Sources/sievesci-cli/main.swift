import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SieveSciCore

Signals.ignoreBrokenPipes()

// sievesci — headless/terminal front end over the same Workbench the macOS app uses.
//
//   sievesci [--workspace DIR] [--provider ID] [--model M] [--task ID] [--mode ask|acceptEdits|auto|plan]
//            [--checker PROVIDER/MODEL] [--worker PROVIDER/MODEL] [--search brave|tavily|exa|googleCSE|searxng|duckduckgo]
//            [--retention short|long] [--no-grounding] [--no-auto-delegate] [--max-workers N] [-p "prompt"]
//   sievesci serve [same options]   JSON-RPC over stdio for a front end (docs/SERVE_PROTOCOL.md)
//   sievesci eval oversight [--checker PROVIDER/MODEL | --provider ID [--model M]] [--deterministic-only]
//            [--corpus FILE] [--out DIR]
//   sievesci eval verifier  [--checker PROVIDER/MODEL | --provider ID [--model M]] [--corpus FILE] [--out DIR]
//
// Keys come from environment variables named by each provider preset (e.g. DEEPSEEK_API_KEY), or
// from the macOS Keychain where the SieveSci app saves them.

struct Options {
    var workspace = FileManager.default.currentDirectoryPath
    var provider = "deepseek"
    var model: String?
    var task: String?
    var mode = PermissionMode.ask
    var checker: String?
    var worker: String?
    var search: WebSearchBackend?
    var retention = CacheRetention.short
    var grounding = true
    /// Run independent parts of a request or plan on workers without waiting for the model to call `task`.
    var autoDelegate = true
    /// Name the conversation with the worker model after the first exchange (as the app does).
    var autoTitle = true
    var maxWorkers: Int?
    var prompt: String?
    var effort: Effort?
    /// Set when the flags name a provider or a workspace (serve otherwise uses the saved configuration).
    var providerGiven = false
    var workspaceGiven = false
}

func parse(_ args: [String] = Array(CommandLine.arguments.dropFirst())) -> Options {
    var o = Options()
    var a = args
    while !a.isEmpty {
        let k = a.removeFirst()
        func v() -> String { a.isEmpty ? "" : a.removeFirst() }
        switch k {
        case "--workspace", "-w": o.workspace = v(); o.workspaceGiven = true
        case "--provider": o.provider = v(); o.providerGiven = true
        case "--model", "-m": o.model = v()
        case "--task": o.task = v()
        case "--mode": o.mode = PermissionMode(rawValue: v()) ?? .ask
        case "--checker": o.checker = v()
        case "--worker": o.worker = v()
        case "--search": o.search = WebSearchBackend(rawValue: v())
        case "--retention": o.retention = CacheRetention(rawValue: v()) ?? .short
        case "--effort": o.effort = Effort(rawValue: v())
        case "--no-grounding": o.grounding = false
        case "--no-auto-delegate": o.autoDelegate = false
        case "--no-auto-title": o.autoTitle = false
        case "--max-workers":
            guard let n = Int(v()), n >= 1 else { print("--max-workers needs a number of at least 1"); exit(2) }
            o.maxWorkers = n
        case "-p", "--print": o.prompt = v()
        case "-h", "--help":
            print("sievesci [--workspace DIR] [--provider ID] [--model M] [--task ID] [--mode ask|acceptEdits|auto|plan] [--checker P/M] [--worker P/M] [--search backend] [--retention short|long] [--effort level] [--no-grounding] [--no-auto-delegate] [--no-auto-title] [--max-workers N] [-p prompt]")
            print("       sievesci eval oversight --help")
            print("providers: " + ProviderPresets.all.map(\.id).joined(separator: ", "))
            exit(0)
        default: o.prompt = ([o.prompt, k].compactMap { $0 }).joined(separator: " ")
        }
    }
    return o
}

func makeProvider(_ id: String, _ model: String?) throws -> (LLMProvider, String) {
    guard let p = ProviderPresets.profile(id: id) else { throw ToolError.invalidInput("unknown provider \(id)") }
    return (try ProviderFactory.make(p, secrets: cliSecrets), model ?? p.defaultModel)
}

setvbuf(stdout, nil, _IONBF, 0)
/// Keys: environment variables, then those saved by the SieveSci app (macOS Keychain).
let cliSecrets = KeychainFallbackSecretStore()
let dim = "\u{1B}[2m", reset = "\u{1B}[0m", orange = "\u{1B}[38;5;173m", red = "\u{1B}[31m", green = "\u{1B}[32m"

/// Models, search and session settings from the command line, for one task.
func buildServices(_ o: Options, task: String) throws -> (SessionServices, (LLMProvider, String)) {
    let mainModel = try makeProvider(o.provider, o.model)
    var checker: (LLMProvider, String)?
    if let c = o.checker {
        let parts = c.split(separator: "/", maxSplits: 1).map(String.init)
        checker = try makeProvider(parts[0], parts.count > 1 ? parts[1] : nil)
    }
    var search = WebSearchConfig()
    if let b = o.search {
        search.backend = b
        search.apiKeyRef = ["brave": "BRAVE_API_KEY", "tavily": "TAVILY_API_KEY", "exa": "EXA_API_KEY", "googleCSE": "GOOGLE_CSE_KEY"][b.rawValue] ?? ""
    }
    search.searxngURL = ProcessInfo.processInfo.environment["SEARXNG_URL"] ?? search.searxngURL
    var worker: (LLMProvider, String)?
    if let w = o.worker {
        let parts = w.split(separator: "/", maxSplits: 1).map(String.init)
        worker = try makeProvider(parts[0], parts.count > 1 ? parts[1] : nil)
    }
    var roleModels = RoleModels(main: mainModel, checker: checker, verifier: checker, worker: worker)
    // A second reviewer when the first declines or fails (the main model when a separate checker is set).
    if checker != nil { roleModels.alternates = [mainModel] }
    let services = try SessionServices(taskId: task, workspace: URL(fileURLWithPath: o.workspace),
                                       models: roleModels,
                                       secrets: cliSecrets, webSearch: search, permissionMode: o.mode,
                                       contactEmail: ProcessInfo.processInfo.environment["SIEVESCI_EMAIL"] ?? "", retention: o.retention)
    services.research.groundingRequired = o.grounding
    services.effort = o.effort
    services.delegation.auto = o.autoDelegate
    if let n = o.maxWorkers { services.delegation.maxParallel = n }
    return (services, mainModel)
}

/// `sievesci serve [options]`: JSON-RPC over stdio for a front end (docs/SERVE_PROTOCOL.md). Models,
/// keys and settings come from the saved configuration (shared with the macOS app) unless `--provider`
/// names them on the command line.
func serve(_ args: [String]) async {
    let o = parse(args)
    let flags = o.providerGiven
    var info: [String: JSON] = [:]
    if flags {
        do {
            let model = try makeProvider(o.provider, o.model).1
            info = ["provider": .string(o.provider), "model": .string(model), "mode": .string(o.mode.rawValue)]
        } catch {
            FileHandle.standardError.writeSafely(Data("sievesci serve: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    let out = NSLock()
    var config = AppConfig.load()
    config.addPresets()
    let server = ServeServer(
        workspace: o.workspaceGiven ? URL(fileURLWithPath: o.workspace) : nil, info: info, config: config,
        secrets: flags ? cliSecrets : PlatformSecretStore.shared,
        makeServices: { id, ws, config in
            if flags { var f = o; f.workspace = ws.path; return try buildServices(f, task: id).0 }
            return try ConfiguredModels.services(task: id, workspace: ws, config: config, secrets: PlatformSecretStore.shared)
        },
        write: { line in out.withLock { _ = FileHandle.standardOutput.writeSafely(Data((line + "\n").utf8)) } })
    // The engine belongs to the window that started it: when that process is gone (a crash, a forced
    // quit), the engine goes too, even if something still holds its stdin open.
    #if !os(Windows)
    let parent = getppid()
    Task.detached {
        while true {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if getppid() != parent { await server.shutdown(); exit(0) }
        }
    }
    #endif
    // Each request is handled on its own, so an answer to a permission request never waits behind
    // a slow one. A `shutdown` ends the process once it has answered.
    let inFlight = DispatchGroup()
    while let line = readLine(strippingNewline: true) {
        inFlight.enter()
        Task {
            await server.handle(line)
            inFlight.leave()
            // Replies to requests still in flight get a moment to go out before the process ends.
            if server.isClosed { try? await Task.sleep(nanoseconds: 300_000_000); exit(0) }
        }
    }
    // stdin closed: answer what is in flight (for at most 8 s: a request that never finishes must not
    // keep the engine alive), then stop the work and exit.
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async { _ = inFlight.wait(timeout: .now() + 8); c.resume() }
    }
    await server.shutdown()
    exit(0)
}

@MainActor
func main(_ args: [String] = Array(CommandLine.arguments.dropFirst())) async {
    let o = parse(args)
    do {
        let task = o.task ?? ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate]) + "-" + String(UUID().uuidString.prefix(6)).lowercased()
        let (services, mainModel) = try buildServices(o, task: task)
        // Only an interactive terminal can answer questions; `-p` runs get "nobody to ask".
        services.asks.interactive = o.prompt == nil
        services.emit = { ev in
            switch ev {
            case .askRequested(let req):
                Task.detached { services.asks.resolve(req.id, TerminalAsk.prompt(req)) }
            case .brainstormChanged(let b):
                let mark = b.endedAt == nil ? (b.wrapUpRequested ? "wrapping up" : b.stage) : (b.stopped ? "stopped" : "done")
                print("\n\(orange)✺ brainstorm · \(mark)\(reset) \(dim)\(b.topic.prefix(80))\(b.stageNote.isEmpty ? "" : " — " + b.stageNote.prefix(120))\(reset)")
            case .textDelta(_, let t): FileHandle.standardOutput.writeSafely(Data(t.utf8))
            case .thinkingDelta: break
            case .toolStarted(_, _, let name, let input):
                let arg = input["command"]?.stringValue ?? input["code"]?.stringValue ?? input["query"]?.stringValue ?? input["path"]?.stringValue ?? input.canonical
                print("\n\(orange)⏺\(reset) \(name)(\(arg.prefix(120).replacingOccurrences(of: "\n", with: "⏎")))")
            case .toolFinished(_, _, _, let out, let err, let receipt):
                let first = out.split(separator: "\n").prefix(3).joined(separator: "\n    ")
                print("  \(dim)⎿ \(err ? red + "✗ " : "")\(first.prefix(300))\(reset) \(dim)[\(receipt)]\(reset)")
            case .usage(_, let m):
                print("\(dim)  · ctx \(m.lastPromptTokens)/\(m.contextWindow) · cache hit \(String(format: "%.0f", m.cacheHitRate * 100))% (session) · out \(m.lastOutputTokens)\(reset)")
            case .integrity(let sigs):
                for s in sigs { print("\(orange)  ⚠ \(s.kind.rawValue): \(s.detail)\(reset)") }
            case .supervisorStarted(let k, let r): print("\n\(orange)✻ \(k) review: \(r.prefix(200))\(reset)")
            case .supervisorReview(let k, let v, _): print("\(v == "pass" || v == "verified" ? green : orange)✻ \(k) → \(v)\(reset)")
            case .notice(let n): print("\(dim)\(n)\(reset)")
            case .agentStarted(let id, let role, _, let purpose) where role == .worker:
                print("\n\(orange)✻ \(id) started\(reset) \(dim)\(purpose.prefix(160))\(reset)")
            case .agentFinished(let id, let role, let result) where role == .worker:
                print("\(orange)✻ \(id) finished\(reset) \(dim)\(result.prefix(200).replacingOccurrences(of: "\n", with: " "))\(reset)")
            case .error(let e): print("\(red)Error: \(e)\(reset)")
            case .turnFinished(let a, _) where a == "main": print("")
            case .titleChanged(_, let t): print("\(dim)✻ title · \(t)\(reset)")
            case .toolProgress(_, _, let lines):
                for l in lines.suffix(20) { print("\(dim)  │ \(l.prefix(200))\(reset)") }
            case .jobOutput(let job, let lines):
                for l in lines.suffix(20) { print("\(dim)  [\(job)] \(l.prefix(200))\(reset)") }
            case .jobNotification(let n):
                print("\n\(n.kind == .failed ? red : orange)🔔 \(n.job) \(n.kind.rawValue)\(reset) \(dim)\(n.text.split(separator: "\n").first ?? "")\(reset)")
            case .deliberation(let t, let from, let to, let kind, let text):
                print("\(orange)⇄ \(t) \(from) → \(to) [\(kind)]\(reset) \(dim)\(text.prefix(300).replacingOccurrences(of: "\n", with: " "))\(reset)")
            default: break
            }
        }
        services.requestPermission = { req in
            print("\n\(orange)Allow \(req.tool)?\(reset) \(req.summary.prefix(300))\n  [y] yes  [a] always (\(req.rememberPattern))  [n] no: ", terminator: "")
            let ans = readLine()?.lowercased() ?? "n"
            return ans.hasPrefix("a") ? .allowAlways : ans.hasPrefix("y") ? .allowOnce : .deny("")
        }
        let bench = Workbench(services: services)
        bench.onOutput = { print($0) }
        bench.autoTitle = o.autoTitle
        await bench.start()
        print("\(orange)✻ SieveSci \(SieveSci.version)\(reset) \(dim)task \(task) · \(mainModel.0.profile.displayName) / \(mainModel.1) · \(services.toolset.count) tools · \(o.mode.rawValue)\(reset)")
        if let p = o.prompt {
            await bench.submit(p)
            // Headless: stay alive while background jobs run; their notifications wake the agent.
            while services.jobs.runningCount > 0 || bench.isRunning || services.jobs.hasPendingAny || bench.isNamingConversation {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } else {
            while true {
                print("\n\(orange)>\(reset) ", terminator: "")
                guard let line = readLine() else { break }
                if line == "/exit" || line == "/quit" { break }
                await bench.submit(line)
            }
        }
        services.kernel.shutdownAll()
        await services.mcp.shutdown()
    } catch {
        print("\(red)\(error.localizedDescription)\(reset)")
        exit(1)
    }
}

// MARK: - sievesci eval oversight

/// Scores oversight on the planted-error corpus: the deterministic detectors always, the checker
/// model unless `--deterministic-only`. Writes oversight-report.json and oversight-report.md.
@MainActor
func evalOversight(_ args: [String]) async {
    var a = args
    var checkerSpec: String?, provider: String?, model: String?, corpusPath: String?, outDir: String?
    var deterministicOnly = false
    while !a.isEmpty {
        let k = a.removeFirst()
        func v() -> String { a.isEmpty ? "" : a.removeFirst() }
        switch k {
        case "--checker": checkerSpec = v()
        case "--provider": provider = v()
        case "--model", "-m": model = v()
        case "--corpus": corpusPath = v()
        case "--out", "-o": outDir = v()
        case "--deterministic-only": deterministicOnly = true
        case "-h", "--help":
            print("sievesci eval oversight [--checker P/M | --provider ID [--model M]] [--deterministic-only] [--corpus FILE] [--out DIR]")
            exit(0)
        default:
            print("\(red)unknown option \(k)\(reset)")
            exit(2)
        }
    }
    do {
        let corpus = try OversightEval.corpus(from: corpusPath.map { URL(fileURLWithPath: $0) })
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
            .replacingOccurrences(of: ":", with: "")
        let out = URL(fileURLWithPath: outDir ?? "sievesci-eval/oversight-\(stamp)")
        let scratch = out.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        print("\(orange)✻ oversight evaluation\(reset) \(dim)\(corpus.cases.count) cases · \(out.path)\(reset)")

        // Resolve the checker (and its key) before spending time on anything.
        var checker: (LLMProvider, String)?
        if !deterministicOnly {
            let spec = checkerSpec ?? provider.map { $0 + (model.map { "/" + $0 } ?? "") } ?? "deepseek"
            let parts = spec.split(separator: "/", maxSplits: 1).map(String.init)
            checker = try makeProvider(parts[0], parts.count > 1 ? parts[1] : model)
        }

        var reports = [try OversightEval.runDeterministic(corpus, scratch: scratch.appendingPathComponent("deterministic"))]
        print(reports[0].markdown)

        if let checker {
            print("\(dim)checker \(checker.0.profile.displayName) / \(checker.1) — one review per case, no host signals shown\(reset)")
            let r = try await OversightEval.runChecker(corpus, models: RoleModels(main: checker, checker: checker),
                                                       secrets: cliSecrets, scratch: scratch.appendingPathComponent("checker")) { o in
                let mark = o.unavailable ? "\(orange)?" : o.defect == nil ? (o.flagged ? "\(red)✗ false alarm" : "\(green)✓ clean") : (o.caught ? "\(green)✓ caught" : "\(red)✗ missed")
                print("  \(mark)\(reset) \(o.id) \(dim)\(o.findings.first ?? "")\(reset)")
            }
            print(r.markdown)
            reports.append(r)
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        struct LayerSummary: Encodable {
            let layer: String, model: String?, recall: Double, falseAlarmRate: Double
            let perDefectRecall: [String: Double]
            let report: OversightEval.Report
        }
        let summaries = reports.map {
            LayerSummary(layer: $0.layer, model: $0.model, recall: $0.recall, falseAlarmRate: $0.falseAlarmRate,
                         perDefectRecall: Dictionary(uniqueKeysWithValues: $0.perDefect.map { ($0.defect, $0.recall) }), report: $0)
        }
        try enc.encode(summaries).write(to: out.appendingPathComponent("oversight-report.json"))
        var md = "# SieveSci oversight evaluation\n\n\(SieveSci.version) · \(stamp) · \(corpus.cases.count) cases " +
            "(\(corpus.cases.filter { $0.defect != nil }.count) planted defects, \(corpus.cases.filter { $0.defect == nil }.count) clean controls)\n\n"
        md += reports.map(\.markdown).joined(separator: "\n")
        md += "\nA defect counts as caught only when it is flagged for that defect; a clean control counts as a false alarm on any flag. " +
            "The checker sees no detector signals, so its score is its own.\n"
        try md.write(to: out.appendingPathComponent("oversight-report.md"), atomically: true, encoding: .utf8)
        print("\(green)✓\(reset) \(out.appendingPathComponent("oversight-report.md").path)")
    } catch {
        print("\(red)\(error.localizedDescription)\(reset)")
        exit(1)
    }
}

// MARK: - sievesci eval verifier

/// Scores the blind verifier on claims with known truth. Writes verifier-report.json and verifier-report.md.
@MainActor
func evalVerifier(_ args: [String]) async {
    var a = args
    var spec: String?, provider: String?, model: String?, corpusPath: String?, outDir: String?
    while !a.isEmpty {
        let k = a.removeFirst()
        func v() -> String { a.isEmpty ? "" : a.removeFirst() }
        switch k {
        case "--checker", "--verifier": spec = v()
        case "--provider": provider = v()
        case "--model", "-m": model = v()
        case "--corpus": corpusPath = v()
        case "--out", "-o": outDir = v()
        case "-h", "--help":
            print("sievesci eval verifier [--checker P/M | --provider ID [--model M]] [--corpus FILE] [--out DIR]")
            exit(0)
        default:
            print("\(red)unknown option \(k)\(reset)")
            exit(2)
        }
    }
    do {
        let corpus = try VerifierEval.corpus(from: corpusPath.map { URL(fileURLWithPath: $0) })
        let s = spec ?? provider.map { $0 + (model.map { "/" + $0 } ?? "") } ?? "deepseek"
        let parts = s.split(separator: "/", maxSplits: 1).map(String.init)
        let verifier = try makeProvider(parts[0], parts.count > 1 ? parts[1] : model)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
            .replacingOccurrences(of: ":", with: "")
        let out = URL(fileURLWithPath: outDir ?? "sievesci-eval/verifier-\(stamp)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        print("\(orange)✻ blind-verifier evaluation\(reset) \(dim)\(corpus.cases.count) claims · \(verifier.0.profile.displayName) / \(verifier.1) · \(out.path)\(reset)")
        let r = try await VerifierEval.runAll(corpus, models: RoleModels(main: verifier, verifier: verifier), secrets: cliSecrets,
                                              scratch: out.appendingPathComponent("runs")) { o in
            print("  \(o.verdict == "unavailable" ? orange + "?" : o.correct ? green + "✓" : red + "✗")\(reset) \(o.id) \(dim)truth \(o.truth) · verdict \(o.verdict)\(reset)")
        }
        print(r.markdown)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        struct Summary: Encodable { let model: String, accuracy: Double, sensitivity: Double, specificity: Double, falseClaimsPassed: [String], report: VerifierEval.Report }
        try enc.encode(Summary(model: r.model, accuracy: r.accuracy, sensitivity: r.sensitivity, specificity: r.specificity,
                               falseClaimsPassed: r.falseClaimsPassed, report: r)).write(to: out.appendingPathComponent("verifier-report.json"))
        try ("# SieveSci blind-verifier evaluation\n\n\(SieveSci.version) · \(stamp)\n\n" + r.markdown).write(to: out.appendingPathComponent("verifier-report.md"), atomically: true, encoding: .utf8)
        print("\(green)✓\(reset) \(out.appendingPathComponent("verifier-report.md").path)")
    } catch {
        print("\(red)\(error.localizedDescription)\(reset)")
        exit(1)
    }
}

/// `sievesci quota ID… [--raw]`: plan limits and balances as the app shows them. `--raw` also prints
/// the provider's quota response (never the key).
@MainActor
func quota(_ args: [String]) async {
    let raw = args.contains("--raw")
    let ids = args.filter { !$0.hasPrefix("--") }
    guard !ids.isEmpty else { print("usage: sievesci quota PROVIDER_ID… [--raw]"); exit(2) }
    for id in ids {
        guard let p = ProviderPresets.profile(id: id) else { print("\(red)unknown provider \(id)\(reset)"); continue }
        let q = await QuotaService.shared.refresh(p, secrets: cliSecrets)
        print("\(orange)\(p.displayName)\(reset)\(q.plan.map { " · \($0)" } ?? "")")
        for m in q.meters {
            let reset = m.resetsAt.map { " · resets " + ISO8601DateFormatter().string(from: $0) } ?? ""
            print("  \(m.kind.rawValue) [\(m.label)\(m.detail.map { ", \($0)" } ?? "")] \(m.remaining)\(reset)")
        }
        if let n = q.note { print("  \(dim)\(n)\(reset)") }
        if raw, let body = await QuotaService.shared.rawResponse(p, secrets: cliSecrets) { print("\(dim)\(body)\(reset)") }
    }
}

/// `sievesci ping [ID…]`: one tiny request ("Reply with exactly: OK", no tools, 64 output tokens) to
/// each enabled provider in the app's configuration, to see which are reachable.
@MainActor
func ping(_ args: [String]) async {
    struct Saved: Decodable { var providers: [ProviderProfile] }
    let dir = ProcessInfo.processInfo.environment["SIEVESCI_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SieveSci")
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
          let saved = try? JSONDecoder().decode(Saved.self, from: data) else { print("\(red)no SieveSci configuration in \(dir.path)\(reset)"); exit(1) }
    let ids = args.filter { !$0.hasPrefix("--") }
    let ws = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-ping")
    try? FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    for p in saved.providers where p.enabled && (ids.isEmpty || ids.contains(p.id)) {
        let model = p.defaultModel.isEmpty ? (p.models.first ?? "") : p.defaultModel
        let label = "\(p.id) / \(model)"
        if p.family == .cliAgent {
            guard ProcessRunner.which(p.executable ?? "") != nil else { print("\(dim)–  \(label): \(p.executable ?? "CLI") not installed\(reset)"); continue }
        } else if p.auth != .none, (cliSecrets.secret(for: p.apiKeyRef) ?? "").isEmpty {
            print("\(dim)–  \(label): no key saved\(reset)"); continue
        }
        let started = Date()
        do {
            let llm = try ProviderFactory.make(p, secrets: cliSecrets)
            var req = LLMRequest(model: model, system: "Connectivity check. Answer as briefly as possible.", tools: [],
                                 messages: [Message.user("Reply with exactly: OK")], maxTokens: 64,
                                 cache: CacheHints(lineageKey: "ping-" + UUID().uuidString, retention: .short))
            req.host = CLIHost(workspace: ws, readOnly: true)
            let resp = try await withThrowingTaskGroup(of: LLMResponse.self) { g in
                g.addTask { try await llm.complete(req) }
                g.addTask { try await Task.sleep(nanoseconds: 150_000_000_000); throw ProviderError.protocolError("no answer within 150 s") }
                defer { g.cancelAll() }
                return try await g.next()!
            }
            let reply = resp.message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            print("\(green)✓\(reset)  \(label) \(dim)\(String(format: "%.1f s", Date().timeIntervalSince(started))) · in \(resp.usage.input + resp.usage.cacheRead) out \(resp.usage.output)\(reset) \(reply.isEmpty ? "(empty reply)" : "“\(reply.prefix(40))”")")
        } catch {
            print("\(red)✗\(reset)  \(label) \(dim)\(String(format: "%.1f s", Date().timeIntervalSince(started)))\(reset) \(String(error.localizedDescription.prefix(240)))")
        }
    }
}

/// `sievesci mcp-bridge`: a stdio MCP server that forwards each JSON-RPC line to the SieveSci session
/// named by SIEVESCI_MCP_URL / SIEVESCI_MCP_TOKEN (set when SieveSci starts a CLI agent). Without
/// them, e.g. when agy runs on its own, it offers no tools.
func mcpBridge() async {
    let env = ProcessInfo.processInfo.environment
    let target = env["SIEVESCI_MCP_URL"].flatMap(URL.init(string:)), token = env["SIEVESCI_MCP_TOKEN"] ?? ""
    let out = NSLock()
    func emit(_ s: String) { out.withLock { FileHandle.standardOutput.writeSafely(Data((s + "\n").utf8)) }; trace("→cli " + s.prefix(120)) }
    // A timing trace, to see where a call waits: ~/Library/Logs/SieveSci/mcp-bridge.log (kept small).
    let logURL = Platform.logsDirectory.appendingPathComponent("mcp-bridge.log")
    try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if ((try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0) ?? 0 > 2_000_000 { try? FileManager.default.removeItem(at: logURL) }
    let pid = ProcessInfo.processInfo.processIdentifier
    func trace(_ s: some StringProtocol) {
        let line = "\(ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime, .withFractionalSeconds, .withColonSeparatorInTime, .withDashSeparatorInDate])) [\(pid)] \(s)\n"
        out.withLock {
            if let h = try? FileHandle(forWritingTo: logURL) { h.appendSafely(Data(line.utf8)); try? h.close() }
            else { try? Data(line.utf8).write(to: logURL) }
        }
    }
    trace("start, session \(target == nil ? "none" : "set")")
    // Each request is forwarded on its own, so a long tool call never holds up the ones after it.
    await withTaskGroup(of: Void.self) { group in
    while let line = readLine(strippingNewline: true) {
        trace("←cli " + line.prefix(160))
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let msg = try? JSONCodec.parse(line) else { continue }
        guard let target else {
            guard let id = msg["id"], !id.isNull else { continue }
            let result: JSON = msg.str("method") == "initialize"
                ? ["protocolVersion": .string(msg["params"]?.str("protocolVersion") ?? "2025-06-18"), "capabilities": ["tools": [:]],
                   "serverInfo": ["name": "sievesci", "version": .string(SieveSci.version)]]
                : ["tools": []]
            emit(JSON.object(["jsonrpc": "2.0", "id": id, "result": result]).canonical)
            continue
        }
        group.addTask {
        var r = URLRequest(url: target)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        r.httpBody = Data(line.utf8)
        r.timeoutInterval = 3600   // a tool call (a long analysis) can take a while
        do {
            trace("→sieve id \(msg["id"]?.canonical ?? "-")")
            #if canImport(Darwin)
            let (data, resp) = try await URLSession.shared.data(for: r)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            #else
            let (status, data) = try await LoopbackHTTPClient.post(target, headers: ["Content-Type": "application/json", "Authorization": "Bearer \(token)"], body: r.httpBody ?? Data())
            #endif
            trace("←sieve id \(msg["id"]?.canonical ?? "-") status \(status)")
            if status == 200, !data.isEmpty { emit(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: " ")) }
            else if status >= 400, let id = msg["id"], !id.isNull {
                emit(JSON.object(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": .string("SieveSci session unavailable (HTTP \(status))")]]).canonical)
            }
        } catch {
            if let id = msg["id"], !id.isNull {
                emit(JSON.object(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": .string("SieveSci is not reachable: \(error.localizedDescription)")]]).canonical)
            }
        }
        }
    }
    }
    trace("stdin closed")
}

// CLI agents started from here reach this process's sessions through the bridge (this executable).
ToolBridge.shared.bridgeCommand = (Bundle.main.executableURL?.resolvingSymlinksInPath().path).map { [$0, "mcp-bridge"] }
let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.first == "mcp-bridge" {
    await mcpBridge()
} else if cliArgs.first == "serve" {
    await serve(Array(cliArgs.dropFirst()))
} else if cliArgs.first == "run-schedule", let id = cliArgs.dropFirst().first {
    // Task Scheduler (Windows) and cron run schedules through this, so a long prompt never has to fit a
    // command line; they append the output to the schedule's log.
    guard let run = Scheduler.runArguments(id) else {
        FileHandle.standardError.writeSafely(Data("sievesci: no schedule \(id)\n".utf8))
        exit(2)
    }
    print("— \(ISO8601DateFormatter().string(from: Date())) schedule \(id)")
    await main(run.args)
} else if cliArgs.first == "quota" {
    await quota(Array(cliArgs.dropFirst()))
} else if cliArgs.first == "ping" {
    await ping(Array(cliArgs.dropFirst()))
} else if cliArgs.first == "eval" {
    let rest = Array(cliArgs.dropFirst(2))
    switch cliArgs.dropFirst().first {
    case "oversight": await evalOversight(rest)
    case "verifier": await evalVerifier(rest)
    default:
        print("usage: sievesci eval oversight [--checker P/M | --provider ID [--model M]] [--deterministic-only] [--corpus FILE] [--out DIR]")
        print("       sievesci eval verifier  [--checker P/M | --provider ID [--model M]] [--corpus FILE] [--out DIR]")
        exit(2)
    }
} else {
    await main()
}


/// `ask_user` in the terminal: numbered options, several numbers for multiple choice, any other text
/// as "Other" (or as the answer to a fill-in question), an empty line to skip, `q` to dismiss.
enum TerminalAsk {
    static func prompt(_ req: AskRequest) -> AskOutcome {
        var answers: [AskAnswer] = []
        print("\n\(orange)? \(req.questions.count == 1 ? "Question" : "\(req.questions.count) questions")\(reset) \(dim)(Enter skips · q dismisses)\(reset)")
        for q in req.questions {
            print("\n\(orange)\(q.header)\(reset) \(q.question)")
            for (i, o) in q.options.enumerated() {
                let rec = o.recommended ? " \(green)(recommended)\(reset)" : ""
                print("  \(i + 1). \(o.label)\(rec)\(o.description.map { " \(dim)— \($0)\(reset)" } ?? "")\(o.evidence.isEmpty ? "" : " \(dim)[\(o.evidence.joined(separator: ", "))]\(reset)")")
            }
            if q.kind == .text {
                print("  \(dim)\(q.placeholder.map { "e.g. \($0)" } ?? "type your answer")\(reset)")
            } else if q.allowOther {
                print("  \(dim)or type your own answer\(q.kind == .multi ? " · several numbers: 1,3" : "")\(reset)")
            }
            print("> ", terminator: "")
            guard let line = readLine()?.trimmingCharacters(in: .whitespaces) else { return .dismissed(nil) }
            if line.lowercased() == "q" { return .dismissed(nil) }
            if line.isEmpty { continue }
            if q.kind == .text { answers.append(AskAnswer(questionId: q.id, text: line)); continue }
            let nums = line.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
            let picked = nums.filter { (1...q.options.count).contains($0) }.map { q.options[$0 - 1].label }
            if !picked.isEmpty, picked.count == nums.count {
                answers.append(AskAnswer(questionId: q.id, selected: q.kind == .multi ? picked : [picked[0]]))
            } else if q.allowOther {
                answers.append(AskAnswer(questionId: q.id, other: line))
            }
        }
        return answers.isEmpty ? .dismissed(nil) : .answered(answers)
    }
}
