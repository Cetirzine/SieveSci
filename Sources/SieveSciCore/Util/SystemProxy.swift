import Foundation
#if os(Windows)
import ucrt
#endif

/// The proxy the user set for the whole computer (macOS Network settings, Windows Internet Options),
/// as the environment variables command-line tools read. The app's own requests already go through it,
/// but child processes — the CLI agents' installers (`curl … | sh`, `irm … | iex`), the agents
/// themselves, pip, git, download scripts — read only `https_proxy` and friends, which an app started
/// from the Dock or Start menu does not have. Where the network blocks direct connections (a TLS
/// handshake cut off: "curl: (35) … unexpected eof while reading"), those tools fail without it.
public enum SystemProxy {
    static let names = ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY"]

    /// Gives this process the computer's proxy when its environment has none. On Windows and Linux the
    /// engine's own requests (URLSession over libcurl, and curl.exe) read only `https_proxy` and friends,
    /// never the system setting, so GitHub, arXiv and the vendors' APIs failed with "Connection was reset"
    /// where a proxy is needed. (On macOS URLSession already follows the system proxy.) Called once at start;
    /// `refresh()` keeps it current afterwards.
    public static func adoptForThisProcess() {
        #if !os(macOS)
        guard !hasProxy(ProcessInfo.processInfo.environment) else { return }   // the user's own export: theirs to change
        apply(current(), replacing: [:])
        #endif
    }

    /// Follows the system setting after start: a proxy switched off (or Clash quit) is dropped, one switched
    /// on is taken up, for this process's requests and the programs it starts. Only variables this process set
    /// itself change; read at most every 10 s. Called before requests and child processes.
    public static func refresh() {
        #if !os(macOS)
        guard let was = adopted.value else { return }
        let now = current()
        if now != was { apply(now, replacing: was) }
        #endif
    }

    /// A child's environment with the proxy as it is now, when the proxy is the one this process adopted:
    /// an environment captured at start (`ProcessRunner.loginEnvironment`) would keep the old one.
    public static func live(_ base: [String: String]) -> [String: String] {
        #if os(macOS)
        return base
        #else
        refresh()
        guard let now = adopted.value else { return base }
        var e = base
        for k in names + ["no_proxy", "NO_PROXY"] { e[k] = nil }
        for (k, v) in now { e[k] = v }
        return e
        #endif
    }

    /// What `adoptForThisProcess` put in the environment; nil when the environment's proxy is the user's.
    private static let adopted = LockedValue<[String: String]?>(nil)

    static func apply(_ env: [String: String], replacing previous: [String: String]) {
        for k in previous.keys where env[k] == nil { unset(k) }
        for (k, v) in env where previous[k] != v { set(k, v) }
        adopted.mutate { $0 = env }
    }

    private static func set(_ k: String, _ v: String) {
        #if os(Windows)
        _ = _putenv_s(k, v)
        #else
        setenv(k, v, 1)
        #endif
    }

    private static func unset(_ k: String) {
        #if os(Windows)
        _ = _putenv_s(k, "")   // an empty value removes the variable
        #else
        unsetenv(k)
        #endif
    }

    /// True when the environment already names a proxy (a shell profile's export wins over the system).
    public static func hasProxy(_ env: [String: String]) -> Bool {
        names.contains { !(env[$0] ?? "").isEmpty }
    }

    public struct Settings: Equatable, Sendable {
        public var http: String?      // host:port
        public var https: String?
        public var socks: String?
        public var exceptions: [String] = []
    }

    /// Variables for `settings`: lower and upper case (curl reads only lower-case `http_proxy`).
    public static func environment(_ s: Settings) -> [String: String] {
        var env: [String: String] = [:]
        func set(_ name: String, _ v: String) { env[name] = v; env[name.uppercased()] = v }
        if let h = s.https ?? s.http { set("https_proxy", "http://" + h) }
        if let h = s.http ?? s.https { set("http_proxy", "http://" + h) }
        if env.isEmpty, let socks = s.socks { set("all_proxy", "socks5h://" + socks) }
        guard !env.isEmpty else { return [:] }
        set("no_proxy", noProxy(s.exceptions).joined(separator: ","))
        return env
    }

    /// Bypass entries in the form curl, Python and Go accept: domain suffixes and CIDR ranges.
    static func noProxy(_ exceptions: [String]) -> [String] {
        var out = ["localhost", "127.0.0.1", "::1"]
        for raw in exceptions {
            var e = raw.trimmingCharacters(in: .whitespaces)
            if e.isEmpty || e == "<local>" || e == "<-loopback>" { continue }
            let octets = e.split(separator: ".", omittingEmptySubsequences: false)
            if octets.last == "*", octets.dropLast().allSatisfy({ UInt8($0) != nil }), (1...3).contains(octets.count - 1) {
                let fixed = octets.dropLast().map(String.init)
                e = (fixed + Array(repeating: "0", count: 4 - fixed.count)).joined(separator: ".") + "/\(fixed.count * 8)"
            } else {
                while e.hasPrefix("*") { e.removeFirst() }
                if e.hasPrefix(".") { e.removeFirst() }
                if e.contains("*") || e.isEmpty { continue }   // other patterns have no equivalent
            }
            if !out.contains(e) { out.append(e) }
        }
        return out
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (at: Date, env: [String: String])?

    /// The system proxy now (read again after 10 s: the user may switch their proxy on or off).
    public static func current() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let c = cached, Date().timeIntervalSince(c.at) < 10 { return c.env }
        let env = read().map(environment) ?? [:]
        cached = (Date(), env)
        return env
    }

    static func read() -> Settings? {
        #if os(macOS)
        guard let d = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        func endpoint(_ kind: String) -> String? {
            guard (d[kind + "Enable"] as? Int) == 1, let host = d[kind + "Proxy"] as? String, !host.isEmpty else { return nil }
            return (d[kind + "Port"] as? Int).map { "\(host):\($0)" } ?? host
        }
        let s = Settings(http: endpoint("HTTP"), https: endpoint("HTTPS"), socks: endpoint("SOCKS"),
                         exceptions: d["ExceptionsList"] as? [String] ?? [])
        return s.http == nil && s.https == nil && s.socks == nil ? nil : s
        #elseif os(Windows)
        return windowsSettings()
        #else
        return nil
        #endif
    }

    #if os(Windows)
    /// HKCU\…\Internet Settings: ProxyEnable, ProxyServer ("host:port" or "http=h:p;https=h:p;socks=h:p"),
    /// ProxyOverride (";"-separated bypass list).
    static func windowsSettings() -> Settings? {
        let key = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings"
        func value(_ name: String) -> String? {
            let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: root + "\\System32\\reg.exe")
            p.arguments = ["query", key, "/v", name]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            // "    ProxyServer    REG_SZ    127.0.0.1:7890"
            guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.contains(name) && $0.contains("REG_") }) else { return nil }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            return parts.count >= 3 ? parts[2...].joined(separator: " ") : nil
        }
        guard let enabled = value("ProxyEnable"), enabled.hasSuffix("1"), let server = value("ProxyServer") else { return nil }
        return parseWindows(server: server, override: value("ProxyOverride") ?? "")
    }
    #endif

    static func parseWindows(server: String, override: String) -> Settings? {
        var s = Settings()
        if server.contains("=") {
            for part in server.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2, !kv[1].isEmpty else { continue }
                switch kv[0].lowercased() {
                case "http": s.http = kv[1]
                case "https": s.https = kv[1]
                case "socks": s.socks = kv[1]
                default: break
                }
            }
        } else if !server.trimmingCharacters(in: .whitespaces).isEmpty {
            s.http = server.trimmingCharacters(in: .whitespaces)
            s.https = s.http
        }
        s.exceptions = override.split(separator: ";").map(String.init)
        return s.http == nil && s.https == nil && s.socks == nil ? nil : s
    }
}
