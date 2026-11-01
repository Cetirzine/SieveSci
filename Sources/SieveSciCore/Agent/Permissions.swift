import Foundation

/// Claude-Code-style permission policy: a mode, allow rules (`tool` or `tool(prefix:*)`), and a
/// hard deny list that no mode overrides. Decisions are logged to the audit trail.
public final class PermissionPolicy: @unchecked Sendable {
    private let lock = NSLock()
    public var mode: PermissionMode
    private var allowRules: [String]
    /// Commands that are refused in every mode.
    public static let hardDeny: [String] = [
        #"(?i)\brm\s+-[a-z]*r[a-z]*f?\s+(/|~|\$HOME)(\s|$)"#, #"(?i)\bsudo\b"#, #"(?i)\bmkfs\b"#, #"(?i)\bdd\s+if="#,
        #"(?i):\(\)\s*\{\s*:\|:&\s*\};:"#, #"(?i)curl[^|]*\|\s*(ba|z)?sh"#, #"(?i)wget[^|]*\|\s*(ba|z)?sh"#,
        #"(?i)\bchmod\s+-R\s+777\s+/"#, #"(?i)git\s+push\s+.*--force"#, #"(?i)\bshutdown\b|\breboot\b"#,
    ]

    public init(mode: PermissionMode = .ask, allowRules: [String] = []) {
        self.mode = mode
        self.allowRules = allowRules
    }

    public var rules: [String] { lock.lock(); defer { lock.unlock() }; return allowRules }

    public func remember(_ pattern: String) {
        lock.lock(); defer { lock.unlock() }
        if !allowRules.contains(pattern) { allowRules.append(pattern) }
    }

    static func commandText(_ tool: String, _ input: JSON) -> String {
        input.str("command") ?? input.str("code") ?? input.str("path") ?? ""
    }

    /// What the user is shown when asked to approve a call.
    public static func summary(_ tool: String, _ input: JSON) -> String {
        switch tool {
        case "dispatch":
            let n = input["items"]?.arrayValue?.count ?? 0
            return L10n.s("%@ batch of %@ items with worker agents (they may run code in their sandbox): %@",
                          input.str("mode") ?? "map", String(n), input.str("instructions") ?? "")
        case "task":
            return L10n.s("Worker agent (may run code in its sandbox): %@", input.str("prompt") ?? "")
        case "claim_finding":
            return L10n.s("Independent verifier (re-runs the analysis in its own sandbox): %@", input.str("statement") ?? "")
        case "skill_env":
            return L10n.s("Set up a Python environment for skill %@ (downloads and installs its packages from PyPI)", input.str("name") ?? "")
        default:
            return commandText(tool, input)
        }
    }

    public static func rememberPattern(tool: String, input: JSON) -> String {
        if tool == "bash", let cmd = input.str("command") {
            let head = cmd.split(separator: " ").prefix(2).joined(separator: " ")
            return "bash(\(head):*)"
        }
        return tool
    }

    func matchesRule(_ tool: String, _ input: JSON) -> Bool {
        let text = Self.commandText(tool, input)
        for r in rules {
            if r == tool { return true }
            if r.hasPrefix(tool + "("), r.hasSuffix(":*)") {
                let prefix = String(r.dropFirst(tool.count + 1).dropLast(3))
                if text.hasPrefix(prefix) { return true }
            }
        }
        return false
    }

    public enum Outcome: Equatable { case allow, ask, deny(String) }

    public func evaluate(tool: String, input: JSON, effect: ToolEffect) -> Outcome {
        let text = Self.commandText(tool, input)
        if effect >= .executes {
            for p in Self.hardDeny where text.range(of: p, options: .regularExpression) != nil {
                return .deny("blocked by the safety deny list")
            }
        }
        if effect == .readOnly { return .allow }
        switch mode {
        case .plan: return .deny("plan mode is read-only; ask the user to leave plan mode to run or edit")
        case .auto: return .allow
        case .acceptEdits: if effect == .writesFiles { return .allow }
        case .ask: break
        }
        return matchesRule(tool, input) ? .allow : .ask
    }
}

/// Asks the user one permission question at a time. Workers run in parallel, but the app and the
/// CLI each show a single prompt; without this queue a second request would replace the first and
/// the first agent would wait forever.
public final class PermissionQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func ask(_ req: PermissionRequest, _ handler: @Sendable (PermissionRequest) async -> PermissionDecision) async -> PermissionDecision {
        await acquire()
        defer { release() }
        return await handler(req)
    }

    private func acquire() async {
        let free: Bool = lock.withLock {
            if !busy { busy = true; return true }
            return false
        }
        if free { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let run: Bool = lock.withLock {
                if !busy { busy = true; return true }
                waiters.append(c)
                return false
            }
            if run { c.resume() }
        }
    }

    private func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty { busy = false; return nil }
            return waiters.removeFirst()   // ownership passes straight to the next waiter
        }
        next?.resume()
    }
}
