import Foundation

/// Live, streaming background jobs (after Claude Code's background shells + Monitor tool, Codex's
/// exec streams and OpenHands' event stream).
///
/// Every background job — a process the agent started, or a log file it tails (a cluster job, an
/// instrument export, a process started outside SieveSci) — streams its output line by line:
/// - to the UI as `jobOutput` events (live log panel), batched every ~0.3 s;
/// - to `.sievesci/tasks/<id>/jobs/<job>.log` on disk (kept for provenance);
/// - through watch patterns: when the job exits, a line matches `notify_on` (or the built-in error
///   patterns), or the output stalls, the host raises a **notification**.
///
/// Notifications reach the agent without polling: mid-turn they are appended to the next tool
/// results; when the agent is idle the workbench wakes it with a new turn. The agent never needs to
/// `sleep` and re-check. The UI shows each notification and can post a macOS notification.
public struct JobNotification: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case exited, matched, stalled, failed }
    public var job: String
    public var agentId: String
    public var kind: Kind
    public var text: String
    public var at: Date

    public var rendered: String {
        "<job-notification job=\"\(job)\" event=\"\(kind.rawValue)\">\n\(text)\n</job-notification>"
    }
}

public final class JobMonitor: @unchecked Sendable {
    public enum Source: Sendable { case process(String), file(String) }

    public struct Snapshot: Sendable, Identifiable {
        public var id: String
        public var source: Source
        public var agentId: String
        public var started: Date
        public var finished: Date?
        public var exitCode: Int32?
        public var lineCount: Int
        public var tail: [String]
        public var logPath: String
        public var watches: [String]
        public var running: Bool { finished == nil }
        public var label: String {
            switch source { case .process(let c): return c; case .file(let p): return "tail " + p }
        }
    }

    /// Errors worth waking the agent for even without a pattern.
    public static let defaultErrorPattern =
        #"Traceback \(most recent call last\)|\b(Error|ERROR|FATAL|Fatal error)\b[:\]]|Segmentation fault|Killed|MemoryError|CUDA out of memory|OOM|core dumped|loss(:|=)\s*nan"#

    final class Job: @unchecked Sendable {
        let id: String, source: Source, agentId: String, started = Date(), log: URL
        var process: Process?
        var finished: Date?, exitCode: Int32?
        var lines = 0
        var tail: [String] = []
        var unseenFrom = 0                // index (line number) the agent has not read yet
        var pendingUI: [String] = []
        var watches: [(String, NSRegularExpression)] = []
        var errorWatch: NSRegularExpression?
        var pendingMatches: [String] = []
        var lastNotify = Date.distantPast
        /// Seconds before the next match notification: 5 s first, then backing off to 5 min, so a job that
        /// keeps printing errors wakes the agent a few times with batched lines, not every few seconds.
        var matchInterval: TimeInterval = 5
        var lastOutput = Date()
        var stallAfter: TimeInterval?
        var stallNotified = false
        var fileOffset: UInt64 = 0
        var untilPattern: NSRegularExpression?
        var handle: FileHandle?
        init(id: String, source: Source, agentId: String, log: URL) { self.id = id; self.source = source; self.agentId = agentId; self.log = log }
    }

    public let dir: URL
    public var emit: @Sendable (AgentEvent) -> Void = { _ in }
    /// Called once per notification (the workbench wakes the agent from here).
    public var onNotify: @Sendable (JobNotification) -> Void = { _ in }
    let lock = NSLock()
    var jobs: [String: Job] = [:]
    var order: [String] = []
    var inbox: [JobNotification] = []
    var n = 0
    static let tailLimit = 400

    public init(dir: URL) { self.dir = dir }

    // MARK: Starting

    /// Starts a process whose output streams live. `notifyOn` = extra regex; error patterns are
    /// always watched unless `notifyErrors` is false.
    public func start(command: String, cwd: URL, agentId: String, sandbox: SandboxMode, writableRoots: [URL], protected: [URL],
                      readHidden: [URL] = [], readAllowed: [URL] = [], readRehidden: [URL] = [],
                      notifyOn: String? = nil, notifyErrors: Bool = true, stallMinutes: Double? = nil) throws -> String {
        let job = makeJob(.process(command), agentId: agentId, notifyOn: notifyOn, notifyErrors: notifyErrors, stallMinutes: stallMinutes)
        let (exe, args) = Seatbelt.wrap(Platform.bash, ["-lc", command], mode: sandbox, writableRoots: writableRoots, protected: protected,
                                        readHidden: readHidden, readAllowed: readAllowed, readRehidden: readRehidden)
        let p = try ProcessRunner.makeProcess(exe, args, cwd: cwd, env: ["PYTHONUNBUFFERED": "1"])
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out   // interleaved, as a terminal would show it
        p.standardInput = FileHandle.nullDevice
        let buffer = LineBuffer()
        var status: Int32 = 0
        // Finish after the output is drained, without blocking: `cmd &` inside a job can keep the pipe
        // open after the job itself exited, and a blocking read here would leave the job running forever.
        let drain = ExitDrain { [weak self] in
            out.fileHandleForReading.readabilityHandler = nil
            if let r = buffer.flush() { self?.ingest(job, [r]) }
            self?.finish(job, code: status)
        }
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; drain.endOfFile(); return }
            self?.ingest(job, buffer.feed(d))
        }
        p.terminationHandler = { proc in status = proc.terminationStatus; drain.processExited() }
        job.process = p
        try p.run()
        tick(job)
        return job.id
    }

    /// Tails a file that something else writes (e.g. a SLURM/LSF log, `nohup` output, instrument
    /// export). Ends when `until` matches, the file is removed, or `stop` is called.
    public func watchFile(_ url: URL, agentId: String, notifyOn: String?, until: String?, notifyErrors: Bool = true,
                          stallMinutes: Double? = nil, fromStart: Bool = false) -> String {
        let job = makeJob(.file(url.path), agentId: agentId, notifyOn: notifyOn, notifyErrors: notifyErrors, stallMinutes: stallMinutes)
        if let until { job.untilPattern = try? NSRegularExpression(pattern: until) }
        job.handle = try? FileHandle(forReadingFrom: url)
        if !fromStart, let h = job.handle { job.fileOffset = (try? h.seekToEnd()) ?? 0 }
        tick(job)
        return job.id
    }

    func makeJob(_ source: Source, agentId: String, notifyOn: String?, notifyErrors: Bool, stallMinutes: Double?) -> Job {
        lock.lock(); defer { lock.unlock() }
        n += 1
        let id = "job\(n)"
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("\(id).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let j = Job(id: id, source: source, agentId: agentId, log: log)
        if let p = notifyOn, let r = try? NSRegularExpression(pattern: p) { j.watches.append((p, r)) }
        if notifyErrors { j.errorWatch = try? NSRegularExpression(pattern: Self.defaultErrorPattern) }
        j.stallAfter = stallMinutes.map { $0 * 60 }
        jobs[id] = j
        order.append(id)
        return j
    }

    // MARK: Streaming

    func ingest(_ job: Job, _ new: [String]) {
        guard !new.isEmpty else { return }
        let text = new.joined(separator: "\n") + "\n"
        if let h = try? FileHandle(forWritingTo: job.log) { h.appendSafely(Data(text.utf8)); try? h.close() }
        lock.lock()
        job.lines += new.count
        job.tail.append(contentsOf: new)
        if job.tail.count > Self.tailLimit { job.tail.removeFirst(job.tail.count - Self.tailLimit) }
        job.pendingUI.append(contentsOf: new)
        job.lastOutput = Date()
        job.stallNotified = false
        for line in new {
            let r = NSRange(line.startIndex..., in: line)
            let hit = job.watches.contains { $0.1.firstMatch(in: line, range: r) != nil }
                || job.errorWatch?.firstMatch(in: line, range: r) != nil
            if hit && job.pendingMatches.count < 40 { job.pendingMatches.append(line.truncated(500)) }
        }
        let done = job.untilPattern.map { u in new.contains { u.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil } } ?? false
        lock.unlock()
        if done { finish(job, code: 0) }
    }

    /// Per-job ticker: flushes UI batches, coalesces match notifications (5 s, then backing off), detects
    /// stalls, and polls tailed files.
    func tick(_ job: Job) {
        Task.detached { [weak self] in
            while let self {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if case .file(let path) = job.source { self.pollFile(job, path: path) }
                let (batch, note, finished) = self.step(job)
                if !batch.isEmpty { self.emit(.jobOutput(job: job.id, lines: batch)) }
                if let note { self.notify(note) }
                if finished { return }
            }
        }
    }

    /// One ticker step (synchronous, under the lock): UI batch, notification to raise, finished?
    func step(_ job: Job) -> ([String], JobNotification?, Bool) {
        lock.lock(); defer { lock.unlock() }
        let batch = job.pendingUI; job.pendingUI = []
        var note: JobNotification?
        if !job.pendingMatches.isEmpty, Date().timeIntervalSince(job.lastNotify) >= job.matchInterval {
            note = JobNotification(job: job.id, agentId: job.agentId, kind: .matched,
                                   text: "Watched pattern matched in \(job.id) (\(Self.label(job.source).truncated(80))):\n" + job.pendingMatches.joined(separator: "\n"),
                                   at: Date())
            job.pendingMatches = []
            job.lastNotify = Date()
            job.matchInterval = min(300, max(60, job.matchInterval * 2))
        }
        if note == nil, let s = job.stallAfter, !job.stallNotified, job.finished == nil, Date().timeIntervalSince(job.lastOutput) > s {
            job.stallNotified = true
            note = JobNotification(job: job.id, agentId: job.agentId, kind: .stalled,
                                   text: "\(job.id) has printed nothing for \(Int(s / 60)) min (still running). Last lines:\n" + job.tail.suffix(5).joined(separator: "\n"),
                                   at: Date())
        }
        return (batch, note, job.finished != nil)
    }

    func pollFile(_ job: Job, path: String) {
        if job.handle == nil { job.handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) }
        guard let h = job.handle else { return }
        try? h.seek(toOffset: job.fileOffset)
        let d = h.readRest()
        guard !d.isEmpty else { return }
        job.fileOffset += UInt64(d.count)
        let lines = String(decoding: d, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        ingest(job, lines.last == "" ? Array(lines.dropLast()) : lines)
    }

    func finish(_ job: Job, code: Int32) {
        lock.lock()
        guard job.finished == nil else { lock.unlock(); return }
        job.finished = Date()
        job.exitCode = code
        let secs = Int(job.finished!.timeIntervalSince(job.started))
        let matches = job.pendingMatches; job.pendingMatches = []
        let tail = job.tail.suffix(15).joined(separator: "\n")
        let batch = job.pendingUI; job.pendingUI = []
        lock.unlock()
        if !batch.isEmpty { emit(.jobOutput(job: job.id, lines: batch)) }
        try? job.handle?.close()
        var text = "\(job.id) (\(Self.label(job.source).truncated(100))) \(code == 0 ? "finished" : "FAILED with exit \(code)") after \(secs) s, \(job.lines) lines of output."
        if !matches.isEmpty { text += "\nMatched lines:\n" + matches.joined(separator: "\n") }
        text += "\nLast lines:\n" + tail + "\nFull log: \(job.log.path) (use job_output for more)."
        emit(.jobFinished(job: job.id, exitCode: code, seconds: secs))
        notify(JobNotification(job: job.id, agentId: job.agentId, kind: code == 0 ? .exited : .failed, text: text, at: Date()))
    }

    func notify(_ n: JobNotification) {
        lock.lock(); inbox.append(n); lock.unlock()
        emit(.jobNotification(n))
        onNotify(n)
    }

    static func label(_ s: Source) -> String {
        switch s { case .process(let c): return c; case .file(let p): return "tail " + p }
    }

    // MARK: Agent-facing

    /// Removes and returns notifications for `agentId` (or for jobs whose agent is gone, when
    /// `adoptOrphans`, so a finished worker's jobs still reach the main agent).
    public func drain(for agentId: String, adoptOrphans: Bool = false, liveAgents: Set<String> = []) -> [JobNotification] {
        lock.lock(); defer { lock.unlock() }
        let mine = inbox.filter { $0.agentId == agentId || (adoptOrphans && !liveAgents.contains($0.agentId)) }
        inbox.removeAll { n in mine.contains(n) }
        return mine
    }

    public var hasPendingAny: Bool { lock.lock(); defer { lock.unlock() }; return !inbox.isEmpty }

    public func hasPending(for agentId: String) -> Bool { lock.lock(); defer { lock.unlock() }; return inbox.contains { $0.agentId == agentId } }

    /// New output since the agent last read it (or the last `maxLines` lines).
    public func output(_ id: String, onlyNew: Bool = true, maxLines: Int = 200) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let j = jobs[id] else { return nil }
        let firstInTail = j.lines - j.tail.count
        let from = onlyNew ? max(j.unseenFrom, firstInTail) : max(firstInTail, j.lines - maxLines)
        var lines = Array(j.tail[(from - firstInTail)...])
        let skipped = onlyNew && j.unseenFrom < firstInTail ? firstInTail - j.unseenFrom : 0
        if lines.count > maxLines { lines = Array(lines.suffix(maxLines)) }
        j.unseenFrom = j.lines
        let state = j.finished == nil ? "running \(Int(Date().timeIntervalSince(j.started))) s" : "exit \(j.exitCode ?? -1)"
        return "[\(id) · \(state) · \(j.lines) lines total\(skipped > 0 ? " · \(skipped) older lines only in \(j.log.path)" : "")]\n"
            + (lines.isEmpty ? "(no new output)" : lines.joined(separator: "\n"))
    }

    public func addWatch(_ id: String, pattern: String) -> Bool {
        guard let r = try? NSRegularExpression(pattern: pattern) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let j = jobs[id], j.finished == nil else { return false }
        j.watches.append((pattern, r))
        return true
    }

    public func stop(_ id: String) -> Bool {
        lock.lock()
        guard let j = jobs[id], j.finished == nil else { lock.unlock(); return false }
        let p = j.process
        lock.unlock()
        if let p, p.isRunning { p.terminate() } else { finish(j, code: 0) }
        return true
    }

    public var all: [Snapshot] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { jobs[$0] }.map {
            Snapshot(id: $0.id, source: $0.source, agentId: $0.agentId, started: $0.started, finished: $0.finished, exitCode: $0.exitCode,
                     lineCount: $0.lines, tail: Array($0.tail.suffix(200)), logPath: $0.log.path, watches: $0.watches.map(\.0))
        }
    }

    public var runningCount: Int { all.filter(\.running).count }
}
