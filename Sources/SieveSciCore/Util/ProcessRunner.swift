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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let path = String(decoding: out.fileHandleForReading.readRest(), as: UTF8.self)
            if !path.isEmpty { env["PATH"] = path }
        }
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

    /// Ends the process at once (SIGKILL; TerminateProcess on Windows).
    static func forceKill(_ pid: Int32) {
        #if os(Windows)
        guard let h = OpenProcess(DWORD(PROCESS_TERMINATE), false, DWORD(pid)) else { return }
        defer { CloseHandle(h) }
        _ = TerminateProcess(h, 1)
        #else
        kill(pid, SIGKILL)
        #endif
    }

    public static func which(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in (loginEnvironment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func makeProcess(_ executable: String, _ args: [String], cwd: URL?, env: [String: String]?) throws -> Process {
        guard let exe = which(executable) else { throw ProviderError.cliNotFound(executable) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var e = loginEnvironment
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
            p.terminate()
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
        return ProcessResult(exitCode: exit.status ?? (timedOut ? 137 : -1), stdout: collector.out, stderr: collector.err,
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
            cont.onTermination = { _ in if p.isRunning { p.terminate() } }
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
