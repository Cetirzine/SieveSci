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
    /// A folder with more new files than this (fpocket output per structure, AlphaFold downloads,
    /// per-sample results …) is generated data: it is left out of the history, which keeps versioning
    /// the scripts, notes, reports and small results around it. Recorded in the shadow repository's
    /// `info/exclude`, so later snapshots do not list it again.
    public var bulkDirFiles = 2_000
    /// Why the last snapshot was not taken (shown to the user), nil when it was.
    public private(set) var skippedReason: String?
    /// Folders the last snapshot newly left out as bulk data, with their file counts (shown once).
    public private(set) var newlyExcluded: [(dir: String, files: Int)] = []
    static let bulkHeader = "# SieveSci: generated bulk data, left out of the history (kept automatically)"
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
        var untracked = (await git(["ls-files", "--others", "--exclude-standard", "-z"], timeout: 300))?.stdout.split(separator: "\0").map(String.init) ?? []
        var skipped: [(String, String)] = []
        var toAdd: [String] = []
        var bytes = 0
        skippedReason = nil
        newlyExcluded = []
        // Folders of generated data leave the history; the rest of the project stays in it.
        let bulk = Self.bulkDirectories(untracked, budget: bulkDirFiles)
        if !bulk.isEmpty {
            excludeForGood(bulk.map(\.dir))
            newlyExcluded = bulk
            let prefixes = bulk.map(\.dir)
            untracked.removeAll { p in prefixes.contains { p.hasPrefix($0) } }
        }
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
        if !newlyExcluded.isEmpty {
            message += "Generated data left out of the history from now on:\n" + newlyExcluded.map { "  \($0.dir)  (\($0.files) files)" }.joined(separator: "\n") + "\n\n"
        }
        if !skipped.isEmpty {
            message += "Large files not stored (sha256):\n" + skipped.map { "  \($0.0)  \($0.1)" }.joined(separator: "\n") + "\n\n"
        }
        message += trailers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        guard let r = await git(["commit", "-q", "--no-verify", "-m", message]), r.exitCode == 0,
              let hash = await git(["rev-parse", "HEAD"])?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return (hash, skipped)
    }

    /// The folders that hold the bulk, as few and as deep as possible, so results beside them stay in the
    /// history. A folder with more than `budget` new files is left out whole when it is a dump: thousands
    /// of per-item subfolders (fpocket's output per structure) or more than `budget` files of its own.
    /// Otherwise its biggest subfolders go, largest first, until the rest fits. Paths end in "/".
    static func bulkDirectories(_ paths: [String], budget: Int, maxDepth: Int = 6, perItemFolders: Int = 100) -> [(dir: String, files: Int)] {
        guard paths.count > budget else { return [] }
        var count: [String: Int] = [:], direct: [String: Int] = [:], children: [String: Set<String>] = [:]
        for p in paths {
            let parts = p.split(separator: "/", omittingEmptySubsequences: false).dropLast()
            var dir = ""
            count[dir, default: 0] += 1
            for (depth, part) in parts.enumerated() where depth < maxDepth {
                let child = dir + part + "/"
                children[dir, default: []].insert(child)
                count[child, default: 0] += 1
                dir = child
            }
            direct[dir, default: 0] += 1
        }
        var out: [(dir: String, files: Int)] = []
        /// Files of `dir` still in the history after its bulk is left out.
        func prune(_ dir: String, depth: Int) -> Int {
            let n = count[dir] ?? 0
            guard n > budget else { return n }
            let kids = children[dir] ?? []
            if !dir.isEmpty && (depth >= maxDepth || kids.count > perItemFolders || (direct[dir] ?? 0) > budget) {
                out.append((dir, n))
                return 0
            }
            var kept: [(dir: String, files: Int)] = []
            var remaining = direct[dir] ?? 0
            for c in kids.sorted() {
                let r = prune(c, depth: depth + 1)
                remaining += r
                if r > 0 { kept.append((c, r)) }
            }
            kept.sort { $0.files > $1.files }
            while remaining > budget, let big = kept.first {
                kept.removeFirst()
                out.removeAll { $0.dir.hasPrefix(big.dir) }
                out.append((big.dir, count[big.dir] ?? big.files))
                remaining -= big.files
            }
            return remaining
        }
        _ = prune("", depth: 0)
        return out
    }

    /// Adds folders to the shadow repository's exclude list (kept across snapshots).
    func excludeForGood(_ dirs: [String]) {
        let url = gitDir.appendingPathComponent("info/exclude")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !text.contains(Self.bulkHeader) { text += (text.hasSuffix("\n") || text.isEmpty ? "" : "\n") + Self.bulkHeader + "\n" }
        for d in dirs {
            // Anchored to the workspace root; characters git reads as patterns are escaped.
            var line = "/"
            for ch in d { if "*?[\\".contains(ch) { line.append("\\") }; line.append(ch) }
            if line.hasPrefix("/#") || line.hasPrefix("/!") { line.insert("\\", at: line.index(after: line.startIndex)) }
            if !text.split(separator: "\n").contains(Substring(line)) { text += line + "\n" }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.writeReliably(to: url)
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
