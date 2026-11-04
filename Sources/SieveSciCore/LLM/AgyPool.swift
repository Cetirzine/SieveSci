import Foundation

/// Long-lived Antigravity CLI processes, one per conversation.
///
/// Every `agy -p` run starts a language server and repeats the sign-in handshake with Google
/// (`loadCodeAssist`, `fetchAvailableModels`): 6–20 s before the model sees the prompt. With
/// `--input-format stream-json` one process takes one NDJSON user message per turn, so only the
/// first turn of a conversation pays that. A process is replaced when its settings change, ended by
/// Stop, and closed after `idleLimit` without use.
final class AgyPool: @unchecked Sendable {
    static let shared = AgyPool()
    static let idleLimit: TimeInterval = 20 * 60

    final class Proc: @unchecked Sendable {
        let process: Process
        let stdin: FileHandle
        let lines = LineQueue()
        let signature: String
        let errTail = OutputCollector(limit: 8000)
        var busy = false
        var lastUsed = Date()
        init(process: Process, stdin: FileHandle, signature: String) { self.process = process; self.stdin = stdin; self.signature = signature }
        func kill() {
            try? stdin.close()
            ProcessRunner.terminate(process)
            lines.finish()
        }
    }

    private let lock = NSLock()
    private var procs: [String: Proc] = [:]

    /// Whether `key` has a live, idle process whose settings match (so the next turn continues it).
    func hasLive(_ key: String, signature: String) -> Bool {
        lock.withLock { procs[key].map { $0.process.isRunning && $0.signature == signature && !$0.busy } ?? false }
    }

    func stop(_ key: String) {
        let p = lock.withLock { procs.removeValue(forKey: key) }
        p?.kill()
    }

    /// Sends one user message and streams the process's NDJSON lines up to and including `result`.
    func turn(key: String, signature: String, spawn: () throws -> Proc, message: String) -> AsyncThrowingStream<String, Error> {
        let proc: Proc
        do {
            proc = try lock.withLock { () throws -> Proc in
                if let p = procs[key], p.process.isRunning, p.signature == signature, !p.busy { p.busy = true; return p }
                procs.removeValue(forKey: key)?.kill()
                let p = try spawn()
                p.busy = true
                procs[key] = p
                return p
            }
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let line: JSON = ["event": "user", "message": ["role": "user", "content": .string(message)]]
        proc.stdin.writeSafely(Data((line.canonical + "\n").utf8))
        return AsyncThrowingStream { cont in
            let task = Task {
                while let l = await proc.lines.next() {
                    cont.yield(l)
                    if let j = try? JSONCodec.parse(l), j["event"]?.stringValue == "result" {
                        proc.busy = false
                        proc.lastUsed = Date()
                        self.reapLater(key, proc)
                        cont.finish()
                        return
                    }
                }
                self.lock.withLock { if self.procs[key] === proc { self.procs.removeValue(forKey: key) } }
                cont.finish(throwing: ProviderError.protocolError("agy exited \(proc.process.isRunning ? -1 : proc.process.terminationStatus): \(proc.errTail.err.suffix(1500))"))
            }
            // Stop (or any cancellation) ends the process: the next turn resumes the conversation by id.
            cont.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason { self.stop(key) }
            }
        }
    }

    private func reapLater(_ key: String, _ proc: Proc) {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.idleLimit + 1) { [weak self] in
            guard let self else { return }
            let idle = self.lock.withLock { self.procs[key] === proc && !proc.busy && Date().timeIntervalSince(proc.lastUsed) >= Self.idleLimit }
            if idle { self.stop(key) }
        }
    }

    static func spawn(_ executable: String, _ args: [String], cwd: URL?, env: [String: String]?, signature: String) throws -> Proc {
        let p = try ProcessRunner.makeProcess(executable, args, cwd: cwd, env: env)
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = inPipe
        let proc = Proc(process: p, stdin: inPipe.fileHandleForWriting, signature: signature)
        let buffer = LineBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; if let rest = buffer.flush() { proc.lines.push(rest) }; proc.lines.finish(); return }
            for l in buffer.feed(d) { proc.lines.push(l) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            proc.errTail.appendErr(d)
        }
        p.terminationHandler = { _ in
            // Let the reader deliver what is buffered, then end the queue even if a grandchild holds the pipe.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { proc.lines.finish() }
        }
        try p.run()
        return proc
    }
}

/// A single-consumer queue of lines with an async `next()`.
final class LineQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var finished = false

    func push(_ s: String) {
        let w: CheckedContinuation<String?, Never>? = lock.withLock {
            guard !finished else { return nil }
            if let w = waiter { waiter = nil; return w }
            items.append(s)
            return nil
        }
        w?.resume(returning: s)
    }

    func finish() {
        let w: CheckedContinuation<String?, Never>? = lock.withLock { finished = true; defer { waiter = nil }; return waiter }
        w?.resume(returning: nil)
    }

    func next() async -> String? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                let now: String?? = lock.withLock {
                    if !items.isEmpty { return .some(items.removeFirst()) }
                    if finished || Task.isCancelled { return .some(nil) }
                    waiter = c
                    return nil
                }
                if let v = now { c.resume(returning: v) }
            }
        } onCancel: {
            let w: CheckedContinuation<String?, Never>? = lock.withLock { defer { waiter = nil }; return waiter }
            w?.resume(returning: nil)
        }
    }
}
