import Foundation

/// Git history for every change the agents make.
///
/// A **shadow repository** (`<workspace>/.sievesci/history.git`, work-tree = the workspace) gets a
/// commit after every turn that changed files, so the full history is kept and browsable without
/// touching the user's own `.git`. Large files (default > 20 MB: BAMs, FASTQs, images stacks …)
/// are skipped and listed in the commit message with their SHA-256 instead. Each commit carries
/// trailers linking it to the task, the receipts that produced the changes and the audit-log range;
/// the commit hash is written back into the audit log, so the link runs both ways.
/// `/commit` can additionally commit to the user's own repository, with the same trailers.
public final class GitHistory: @unchecked Sendable {
    public let workspace: URL
    public let gitDir: URL
    public var maxFileBytes = 20 * 1024 * 1024
    /// A snapshot that would add more than this is not taken: the workspace is probably a whole
    /// home or Documents folder rather than a project, and copying it would cost disk and minutes.
    public var maxSnapshotFiles = 20_000
    public var maxSnapshotBytes = 500 * 1024 * 1024
    /// Why the last snapshot was not taken (shown to the user), nil when it was.
    public private(set) var skippedReason: String?
    private let lock = NSLock()
    public private(set) var available = false

    public init(workspace: URL) {
        self.workspace = workspace
        gitDir = workspace.appendingPathComponent(".sievesci/history.git")
    }

    func git(_ args: [String], shadow: Bool = true, timeout: TimeInterval = 120) async -> ProcessResult? {
        let base = shadow ? ["--git-dir=\(gitDir.path)", "--work-tree=\(workspace.path)"] : ["-C", workspace.path]
        return try? await ProcessRunner.run("git", base + args, cwd: workspace,
                                            env: ["GIT_AUTHOR_NAME": "SieveSci", "GIT_AUTHOR_EMAIL": "agent@sievesci.local",
                                                  "GIT_COMMITTER_NAME": "SieveSci", "GIT_COMMITTER_EMAIL": "agent@sievesci.local"],
                                            timeout: timeout)
    }

    /// Creates the shadow repository on first use.
    public func prepare() async {
        guard ProcessRunner.which("git") != nil else { return }
        if !FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("HEAD").path) {
            _ = try? await ProcessRunner.run("git", ["init", "--bare", "-q", gitDir.path], timeout: 30)
            _ = await git(["config", "core.bare", "false"])
            _ = await git(["config", "core.quotepath", "false"])
            // Never snapshot SieveSci's own state, VCS dirs or common caches.
            let exclude = [".sievesci/", ".git/", ".DS_Store", "__pycache__/", ".ipynb_checkpoints/", ".venv/", "venv/", "node_modules/", ".build/"]
            try? FileManager.default.createDirectory(at: gitDir.appendingPathComponent("info"), withIntermediateDirectories: true)
            try? exclude.joined(separator: "\n").writeReliably(to: gitDir.appendingPathComponent("info/exclude"))
        }
        available = true
    }

    public struct Commit: Sendable, Equatable {
        public var hash: String
        public var subject: String
        public var date: String
        public var files: Int
    }

    /// Commits every change since the last snapshot. Returns nil when nothing changed.
    public func snapshot(subject: String, trailers: [String: String]) async -> (commit: String, skipped: [(String, String)])? {
        guard available else { return nil }
        // Candidates: modified/deleted tracked files + new untracked files (respecting .gitignore).
        _ = await git(["add", "-u"])
        let untracked = (await git(["ls-files", "--others", "--exclude-standard", "-z"]))?.stdout.split(separator: "\0").map(String.init) ?? []
        var skipped: [(String, String)] = []
        var toAdd: [String] = []
        var bytes = 0
        skippedReason = nil
        if untracked.count > maxSnapshotFiles {
            skippedReason = L10n.s("History is off for this workspace: it has %@ new files, too many for a project folder. Open the project's own folder instead.", String(untracked.count))
            return nil
        }
        for rel in untracked {
            let url = workspace.appendingPathComponent(rel)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > maxFileBytes { skipped.append((rel, "(\(size) bytes, not hashed)")) } else { toAdd.append(rel); bytes += size }
        }
        if bytes > maxSnapshotBytes {
            skippedReason = L10n.s("History is off for this workspace: its files add up to %@ MB, too much for a project folder. Open the project's own folder instead.", String(bytes / 1_048_576))
            return nil
        }
        // Hash large files only when the snapshot is actually taken (hashing gigabytes is slow).
        skipped = skipped.map { ($0.0, Hashing.sha256OfFile(workspace.appendingPathComponent($0.0)) ?? "?") }
        for chunk in stride(from: 0, to: toAdd.count, by: 200) {
            _ = await git(["add", "--"] + Array(toAdd[chunk..<min(chunk + 200, toAdd.count)]))
        }
        let staged = await git(["diff", "--cached", "--quiet"])
        guard staged?.exitCode == 1 else { return nil }  // 0 = no changes
        var message = subject + "\n\n"
        if !skipped.isEmpty {
            message += "Large files not stored (sha256):\n" + skipped.map { "  \($0.0)  \($0.1)" }.joined(separator: "\n") + "\n\n"
        }
        message += trailers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        guard let r = await git(["commit", "-q", "--no-verify", "-m", message]), r.exitCode == 0,
              let hash = await git(["rev-parse", "HEAD"])?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return (hash, skipped)
    }

    public func log(limit: Int = 50) async -> [Commit] {
        guard available, let r = await git(["log", "--pretty=format:%H%x1f%s%x1f%ci", "--shortstat", "-n", "\(limit)"]) else { return [] }
        var out: [Commit] = []
        for block in r.stdout.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map(String.init)
            guard let first = lines.first(where: { $0.contains("\u{1f}") }) else { continue }
            let f = first.components(separatedBy: "\u{1f}")
            let files = lines.last.flatMap { Int($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") } ?? 0
            out.append(Commit(hash: f[0], subject: f.count > 1 ? f[1] : "", date: f.count > 2 ? f[2] : "", files: files))
        }
        return out
    }

    /// Per-file diffs of one commit against its parent.
    public func diffs(of commit: String) async -> [FileDiff] {
        guard available, let names = await git(["show", "--pretty=format:", "--name-only", commit])?.stdout else { return [] }
        var out: [FileDiff] = []
        for path in names.split(separator: "\n").map(String.init).filter({ !$0.isEmpty }).prefix(200) {
            let old = await git(["show", "\(commit)^:\(path)"])
            let new = await git(["show", "\(commit):\(path)"])
            out.append(FileDiff.make(path: path, old: old?.exitCode == 0 ? old?.stdout : nil, new: new?.exitCode == 0 ? new?.stdout : nil))
        }
        return out
    }

    /// Restores the workspace files to their state at `commit` (used by "restore to here").
    public func restore(_ commit: String, paths: [String] = []) async -> Bool {
        guard available else { return false }
        let r = await git(["checkout", commit, "--"] + (paths.isEmpty ? ["."] : paths))
        return r?.exitCode == 0
    }

    // MARK: The user's own repository

    public var userRepoExists: Bool { FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".git").path) }

    /// Commits the current changes to the user's repository (only on explicit request).
    public func commitUserRepo(message: String, trailers: [String: String]) async -> String {
        guard userRepoExists else { return L("This workspace is not a git repository.") }
        _ = await git(["add", "-A"], shadow: false)
        let staged = await git(["diff", "--cached", "--quiet"], shadow: false)
        guard staged?.exitCode == 1 else { return L("Nothing to commit.") }
        let full = message + "\n\n" + trailers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        let r = await git(["commit", "-q", "-m", full], shadow: false)
        let hash = await git(["rev-parse", "--short", "HEAD"], shadow: false)?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        return r?.exitCode == 0 ? L10n.s("Committed %@ to your repository.", hash) : L10n.s("git commit failed: %@", r?.stderr.truncated(300) ?? "")
    }
}
