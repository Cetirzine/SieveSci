import Foundation

/// Persistent Python interpreters, one per agent (so the blind verifier never shares the main
/// agent's namespace). Uses the user's own `python3` (conda/venv on the login PATH), so their
/// installed scientific stack is available without SieveSci bundling anything.
public final class PythonKernel: @unchecked Sendable {
    let workspace: URL
    let python: String
    var sandbox: SandboxMode = .off
    var protected: [URL] = []
    var readHidden: [URL] = []
    var readAllowed: [URL] = []
    var readRehidden: [URL] = []
    var tempDir: URL?
    private var process: Process?
    private var stdin: FileHandle?
    private let buffer = LineBuffer()
    private var reader: FileHandle?
    private var waiting: [String: CheckedContinuation<JSON, Error>] = [:]
    private let lock = NSLock()
    private var counter = 0

    init(workspace: URL, python: String = "python3") {
        self.workspace = workspace
        self.python = python
    }

    func start() throws {
        guard let script = SieveSciResources.bundle.url(forResource: "driver", withExtension: "py", subdirectory: "Resources/kernel") else {
            throw ToolError.invalidInput("kernel driver missing from bundle")
        }
        let (exe, args) = Seatbelt.wrap(ProcessRunner.which(python) ?? python, ["-u", script.path], mode: sandbox,
                                        writableRoots: [workspace], protected: protected, readHidden: readHidden, readAllowed: readAllowed, readRehidden: readRehidden)
        var env = ["SIEVESCI_FIGURES": workspace.appendingPathComponent("figures").path, "MPLBACKEND": "Agg", "PYTHONUNBUFFERED": "1"]
        if let tempDir { env["TMPDIR"] = tempDir.path; env["MPLCONFIGDIR"] = tempDir.appendingPathComponent("mpl").path }
        let p = try ProcessRunner.makeProcess(exe, args, cwd: workspace, env: env)
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            // End of file (the kernel exited): unregister, or the handler spins a core.
            guard !d.isEmpty, let self else { h.readabilityHandler = nil; return }
            for line in self.buffer.feed(d) { self.deliver(line) }
        }
        p.terminationHandler = { [weak self] _ in self?.failAll("Python kernel exited") }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        reader = outPipe.fileHandleForReading
    }

    func deliver(_ line: String) {
        guard let j = try? JSONCodec.parse(line), let id = j.str("id") else { return }
        lock.lock()
        let c = waiting.removeValue(forKey: id)
        lock.unlock()
        c?.resume(returning: j)
    }

    func failAll(_ why: String) {
        lock.lock()
        let ws = waiting
        waiting = [:]
        process = nil
        lock.unlock()
        for c in ws.values { c.resume(throwing: ToolError.invalidInput(why)) }
    }

    public func execute(_ code: String, timeout: TimeInterval = 600, reset: Bool = false) async throws -> JSON {
        if process?.isRunning != true { try start() }
        lock.lock()
        counter += 1
        let id = "c\(counter)"
        lock.unlock()
        let req: JSON = reset ? ["id": .string(id), "reset": true] : ["id": .string(id), "code": .string(code)]
        return try await withThrowingTaskGroup(of: JSON.self) { g in
            g.addTask {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSON, Error>) in
                    self.lock.lock()
                    self.waiting[id] = c
                    self.lock.unlock()
                    // The interpreter may have died since the last cell: fail this one instead of aborting.
                    if self.stdin?.writeSafely(JSONCodec.canonicalData(req) + Data("\n".utf8)) != true {
                        self.lock.lock()
                        let w = self.waiting.removeValue(forKey: id)
                        self.lock.unlock()
                        w?.resume(throwing: ToolError.invalidInput("the Python interpreter had exited; run the cell again to start a fresh one"))
                    }
                }
            }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // A runaway cell: kill the interpreter (state is lost; the agent is told).
                self.process?.terminate()
                throw ToolError.invalidInput("timed out after \(Int(timeout)) s; the Python kernel was restarted and its variables were lost")
            }
            let r = try await g.next()!
            g.cancelAll()
            return r
        }
    }

    public func shutdown() { process?.terminate() }
}

public final class PythonKernelPool: @unchecked Sendable {
    let workspace: URL
    private let lock = NSLock()
    private var kernels: [String: PythonKernel] = [:]
    public var python = "python3"

    init(workspace: URL) { self.workspace = workspace }

    /// `cwd` lets sandboxed agents (verifier, workers) run with their sandbox as working directory.
    /// `python`: a skill environment's interpreter; each agent gets one kernel per interpreter.
    public func kernel(for agentId: String, cwd: URL? = nil, sandbox: SandboxMode = .off, protected: [URL] = [],
                       readHidden: [URL] = [], readAllowed: [URL] = [], readRehidden: [URL] = [], python interpreter: String? = nil,
                       tempDir: URL? = nil) -> PythonKernel {
        lock.lock(); defer { lock.unlock() }
        let key = agentId + (interpreter.map { "@" + $0 } ?? "")
        if let k = kernels[key] { return k }
        let k = PythonKernel(workspace: cwd ?? workspace, python: interpreter ?? python)
        k.sandbox = sandbox
        k.protected = protected
        k.readHidden = readHidden
        k.readAllowed = readAllowed
        k.readRehidden = readRehidden
        k.tempDir = tempDir
        kernels[key] = k
        return k
    }

    public func shutdownAll() {
        lock.lock(); let ks = kernels.values; kernels = [:]; lock.unlock()
        for k in ks { k.shutdown() }
    }
}
