import Foundation
#if os(Windows)
import WinSDK
#endif

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var duration: TimeInterval
}

public enum ProcessRunner {
    /// GUI apps on macOS start with a minimal PATH, so `python3`, `Rscript`, `claude`, `conda` etc.
    /// would not resolve. The login shell's PATH is captured once and used for every child process.
    public static let loginEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        #if os(macOS)
        let shell = env["SHELL"] ?? "/bin/zsh"
        // Interactive first (conda and friends extend PATH in .zshrc), then a plain login shell.
        // Started from a terminal, an interactive shell with job control tries to take over that
        // terminal from its background process group and stops: `+m` turns job control off, stdin
        // is closed, and each try still has a deadline.
        for flags in [["-i", "+m", "-l", "-c"], ["-l", "-c"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            // PATH, and the proxy a profile exports (an app started from the Dock has neither).
            p.arguments = flags + ["printf 'PATH=%s\\n' \"$PATH\"; env | grep -iE '^(https?|all|no)_proxy='"]
            let out = Pipe()
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if p.isRunning { p.terminate(); continue }
            let text = String(decoding: out.fileHandleForReading.readRest(), as: UTF8.self)
            var found: [String: String] = [:]
            for line in text.split(separator: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                found[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
            guard let path = found["PATH"], !path.isEmpty else { continue }
            env["PATH"] = path
            if !SystemProxy.hasProxy(env) {
                for (k, v) in found where k != "PATH" && !v.isEmpty { env[k] = v }
            }
            break
        }
        #endif
        #if os(Windows)
        // Python on Windows reads and writes pipes in the ANSI code page unless told otherwise, which
        // mangles non-ASCII text between SieveSci and the kernel, skills and MCP servers.
        if env["PYTHONUTF8"] == nil { env["PYTHONUTF8"] = "1" }
        if env["PYTHONIOENCODING"] == nil { env["PYTHONIOENCODING"] = "utf-8" }
        #endif
        return env
    }()

    /// False once the pid is gone (reaped). A zombie still counts as alive until it is reaped.
    static func alive(_ pid: Int32) -> Bool {
        #if os(Windows)
        guard pid > 0, let h = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) else { return false }
        defer { CloseHandle(h) }
        var code: DWORD = 0
        return GetExitCodeProcess(h, &code) && code == 259   // STILL_ACTIVE
        #else
        return pid > 0 && (kill(pid, 0) == 0 || errno != ESRCH)
        #endif
    }

    /// The exit code of a process that has ended, where the OS can still say (Windows, while a
    /// handle to it is open); nil elsewhere or while it runs.
    static func exitCode(_ pid: Int32) -> Int32? {
        #if os(Windows)
        guard pid > 0, let h = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) else { return nil }
        defer { CloseHandle(h) }
        var code: DWORD = 0
        guard GetExitCodeProcess(h, &code), code != 259 else { return nil }
        return Int32(bitPattern: UInt32(code))
        #else
        return nil
        #endif
    }

    /// Ends the process at once (SIGKILL; on Windows the whole tree, see `terminate`).
    static func forceKill(_ pid: Int32) {
        #if os(Windows)
        killTree(pid)
        #else
        kill(pid, SIGKILL)
        #endif
    }

    /// Stops a child process. On Windows CLIs are `.cmd` shims and commands run under Git Bash, so
    /// the process SieveSci started is only the root of a tree (`cmd` → `node`, `bash` → `sleep`);
    /// ending just the root would leave the work running, so the tree goes.
    public static func terminate(_ p: Process) {
        guard p.isRunning else { return }
        #if os(Windows)
        killTree(p.processIdentifier)
        if p.isRunning { p.terminate() }
        #else
        p.terminate()
        #endif
    }

    #if os(Windows)
    static func killTree(_ pid: Int32) {
        guard pid > 0 else { return }
        let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        let k = Process()
        k.executableURL = URL(fileURLWithPath: root + "\\System32\\taskkill.exe")
        k.arguments = ["/T", "/F", "/PID", String(pid)]
        k.standardOutput = FileHandle.nullDevice
        k.standardError = FileHandle.nullDevice
        k.standardInput = FileHandle.nullDevice
        if (try? k.run()) != nil { k.waitUntilExit() }
        if alive(pid), let h = OpenProcess(DWORD(PROCESS_TERMINATE), false, DWORD(pid)) {
            _ = TerminateProcess(h, 1)
            CloseHandle(h)
        }
    }
    #endif

    public static func which(_ name: String) -> String? { allOnPath(name).first }

    /// The login PATH (Windows spells the variable `Path`).
    static var searchPath: String { loginEnvironment.first { $0.key.uppercased() == "PATH" }?.value ?? "" }

    /// Every match for `name` on PATH, in PATH order. On Windows a bare name also tries the PATHEXT
    /// extensions (`claude` → `claude.cmd`), and the extensionless shell scripts npm installs beside
    /// them are skipped, since Windows cannot start those.
    static func allOnPath(_ name: String) -> [String] {
        let fm = FileManager.default
        #if os(Windows)
        func runnable(_ p: String) -> Bool { var dir: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &dir) && !dir.boolValue }
        let hasExt = !(name as NSString).pathExtension.isEmpty
        let exts = hasExt ? [""] : (ProcessInfo.processInfo.environment["PATHEXT"] ?? ".COM;.EXE;.BAT;.CMD")
            .split(separator: ";").map { String($0).lowercased() }
        if name.contains("\\") || name.contains("/") || name.contains(":") {
            return exts.map { name + $0 }.first(where: runnable).map { [$0] } ?? []
        }
        #else
        func runnable(_ p: String) -> Bool { fm.isExecutableFile(atPath: p) }
        let exts = [""]
        if name.hasPrefix("/") { return runnable(name) ? [name] : [] }
        #endif
        var out: [String] = []
        // PATH first, then the folders the agents' own installers use (see AgentInstaller).
        let dirs = searchPath.split(separator: Platform.pathSeparator).map(String.init) + AgentInstaller.installFolders
        for dir in dirs where !dir.isEmpty {
            let base = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
            if let hit = exts.map({ base + $0 }).first(where: runnable), !out.contains(hit) { out.append(hit) }
        }
        return out
    }

    /// Writing to a child that has exited raises SIGPIPE, which kills the whole process by default;
    /// the app and CLI ignore it at launch, and anything else spawning through here does too.
    private static let brokenPipesIgnored: Void = Signals.ignoreBrokenPipes()

    static func makeProcess(_ executable: String, _ args: [String], cwd: URL?, env: [String: String]?) throws -> Process {
        _ = brokenPipesIgnored
        guard let exe = which(executable) else { throw ProviderError.cliNotFound(executable) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var e = loginEnvironment
        // No proxy from the launch environment or the shell profile: the one set for the computer.
        if !SystemProxy.hasProxy(e) { for (k, v) in SystemProxy.current() { e[k] = v } }
        for (k, v) in env ?? [:] { e[k] = v }
        p.environment = e
        return p
    }

    /// Runs to completion with a timeout, capturing (bounded) stdout/stderr.
    public static func run(_ executable: String, _ args: [String], cwd: URL? = nil, env: [String: String]? = nil,
                           stdin: String? = nil, timeout: TimeInterval = 600, maxOutput: Int = 2_000_000,
                           onLines: (@Sendable ([String]) -> Void)? = nil) async throws -> ProcessResult {
        let p = try makeProcess(executable, args, cwd: cwd, env: env)
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = inPipe
        let start = Date()
        let collector = OutputCollector(limit: maxOutput)
        let outLines = LineBuffer(), errLines = LineBuffer()
        // At end of file the handler keeps firing with empty data; it must unregister itself or it
        // spins a core for as long as the pipe object lives.
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; collector.closeOut(); return }
            collector.appendOut(d)
            if let onLines { let l = outLines.feed(d); if !l.isEmpty { onLines(l) } }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; collector.closeErr(); return }
            collector.appendErr(d)
            if let onLines { let l = errLines.feed(d); if !l.isEmpty { onLines(l) } }
        }
        // Never `waitUntilExit()`: it waits on the calling thread's run loop for a wake-up that can
        // be lost (seen in the CLI: the child was long gone and the call never returned). The
        // termination handler records the status, and a liveness probe backs it up.
        let exit = ExitStatus()
        p.terminationHandler = { exit.record($0) }
        try p.run()
        let pid = p.processIdentifier
        if let stdin { inPipe.fileHandleForWriting.writeSafely(Data(stdin.utf8)) }
        try? inPipe.fileHandleForWriting.close()

        func waitForExit(_ seconds: TimeInterval) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if exit.done || !ProcessRunner.alive(pid) { return true }
                if Task.isCancelled { return false }   // Stop: end the child instead of waiting for it
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return exit.done || !ProcessRunner.alive(pid)
        }
        var timedOut = false
        if !(await waitForExit(timeout)) {
            timedOut = !Task.isCancelled
            ProcessRunner.terminate(p)
            // While cancelled, waitForExit returns at once, so give the child a moment to go.
            let grace = Date().addingTimeInterval(0.5)
            while Date() < grace && ProcessRunner.alive(pid) && !exit.done { Thread.sleep(forTimeInterval: 0.02) }
            if ProcessRunner.alive(pid) && !exit.done { ProcessRunner.forceKill(pid) }
        }
        // The handler can trail the probe by a moment.
        for _ in 0..<20 where !exit.done { try? await Task.sleep(nanoseconds: 10_000_000) }
        // Let the handlers drain what is still buffered. Never block on end of file: a background
        // grandchild (`cmd &`) can hold the pipe open long after the command itself exited.
        for _ in 0..<40 where !collector.closed { try? await Task.sleep(nanoseconds: 25_000_000) }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if let onLines {
            let tail = [outLines.flush(), errLines.flush()].compactMap { $0 }
            if !tail.isEmpty { onLines(tail) }
        }
        return ProcessResult(exitCode: exit.status ?? ProcessRunner.exitCode(pid) ?? (timedOut ? 137 : -1), stdout: collector.out, stderr: collector.err,
                             timedOut: timedOut, duration: Date().timeIntervalSince(start))
    }

    /// Streams stdout line by line (NDJSON CLIs). The final element is delivered via `onExit`.
    public static func lines(_ executable: String, _ args: [String], cwd: URL? = nil, env: [String: String]? = nil,
                             stdin: String? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let p: Process
            do { p = try makeProcess(executable, args, cwd: cwd, env: env) } catch { cont.finish(throwing: error); return }
            let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            p.standardInput = inPipe
            let buffer = LineBuffer()
            let errTail = OutputCollector(limit: 8000)
            var proc: Process?
            let drain = ExitDrain {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if let rest = buffer.flush() { cont.yield(rest) }
                guard let proc else { cont.finish(); return }
                if proc.terminationStatus != 0 && proc.terminationReason != .uncaughtSignal {
                    cont.finish(throwing: ProviderError.protocolError("\(executable) exited \(proc.terminationStatus): \(errTail.err.suffix(2000))"))
                } else {
                    cont.finish()
                }
            }
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; drain.endOfFile(); return }
                for line in buffer.feed(d) { cont.yield(line) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; return }
                errTail.appendErr(d)
            }
            p.terminationHandler = { pr in proc = pr; drain.processExited() }
            do { try p.run() } catch { cont.finish(throwing: error); return }
            if let stdin { inPipe.fileHandleForWriting.writeSafely(Data(stdin.utf8)) }
            try? inPipe.fileHandleForWriting.close()
            cont.onTermination = { _ in ProcessRunner.terminate(p) }
        }
    }
}

/// The exit status as delivered to `terminationHandler`.
final class ExitStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32?
    func record(_ p: Process) { let c = p.terminationStatus; lock.lock(); code = c; lock.unlock() }
    var status: Int32? { lock.lock(); defer { lock.unlock() }; return code }
    var done: Bool { status != nil }
}

/// Runs `finish` once, after the process has exited and its pipe reached end of file — or one second
/// after exit if a background grandchild still holds the pipe open (never blocks on the pipe).
final class ExitDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false, eof = false, done = false
    private let finish: () -> Void
    init(_ finish: @escaping () -> Void) { self.finish = finish }
    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    func endOfFile() { lock.lock(); eof = true; let go = exited && !done; if go { done = true }; lock.unlock(); if go { finish() } }
    func processExited() {
        lock.lock(); exited = true; let go = eof && !done; if go { done = true }; lock.unlock()
        if go { finish(); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock(); let late = !done; done = true; lock.unlock()
            if late { finish() }
        }
    }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var o = Data(), e = Data()
    let limit: Int
    init(limit: Int) { self.limit = limit }
    private var outClosed = false, errClosed = false
    func closeOut() { lock.lock(); outClosed = true; lock.unlock() }
    func closeErr() { lock.lock(); errClosed = true; lock.unlock() }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return outClosed && errClosed }
    func appendOut(_ d: Data) { lock.lock(); if o.count < limit { o.append(d.prefix(limit - o.count)) }; lock.unlock() }
    func appendErr(_ d: Data) { lock.lock(); e.append(d); if e.count > limit { e = e.suffix(limit) }; lock.unlock() }
    var out: String { lock.lock(); defer { lock.unlock() }; return String(decoding: o, as: UTF8.self) }
    var err: String { lock.lock(); defer { lock.unlock() }; return String(decoding: e, as: UTF8.self) }
}

final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    func feed(_ d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(d)
        // One pass, one copy of the remainder (re-slicing per line was quadratic on large output).
        var lines: [String] = []
        var start = pending.startIndex
        while let nl = pending[start...].firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[start..<nl], as: UTF8.self))
            start = pending.index(after: nl)
        }
        if start != pending.startIndex { pending = Data(pending[start...]) }
        // A runaway line without newlines must not grow without bound.
        if pending.count > 1_000_000 { lines.append(String(decoding: pending.prefix(4000), as: UTF8.self) + " …"); pending = Data() }
        return lines
    }
    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        defer { pending = Data() }
        return String(decoding: pending, as: UTF8.self)
    }
}
