import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Installs skills from where people share them: a GitHub link (a repository, or a folder inside one,
/// `…/tree/<ref>/<path>`), any git URL, a `.zip` on disk or at an https URL. Every folder with a valid
/// `SKILL.md` (name and description) is copied to the user's skills (`~/.sievesci/skills`) or the
/// workspace's (`.sievesci/skills`), where `SkillRegistry` finds it.
///
/// What is refused: entries that would land outside the unpacked folder, archives over the size cap, and
/// skills whose `SKILL.md` fails the same integrity screen as learned skills. Symbolic links are not copied.
public enum SkillInstaller {
    public enum Scope: String, Sendable { case user, workspace }

    public struct Outcome: Sendable {
        public var installed: [String] = []
        public var skipped: [String] = []
        public var refused: [String] = []
    }

    /// At most this much unpacked content, and this many files.
    static let maxBytes = 300_000_000
    static let maxFiles = 30_000

    public static func destination(_ scope: Scope, workspace: URL) -> URL {
        scope == .user ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/skills")
            : workspace.appendingPathComponent(".sievesci/skills")
    }

    /// A GitHub link split into what to clone and which folder inside it.
    struct GitSource: Equatable { var repo: String; var ref: String?; var path: String }

    static func gitSource(_ s: String) -> GitSource? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: t), let host = u.host?.lowercased(), host == "github.com" || host == "www.github.com" {
            let parts = u.path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
            var ref: String?, path = ""
            if parts.count >= 4, parts[2] == "tree" || parts[2] == "blob" {
                ref = parts[3]
                var rest = Array(parts.dropFirst(4))
                if parts[2] == "blob", rest.last == "SKILL.md" { rest.removeLast() }
                path = rest.joined(separator: "/")
            }
            return GitSource(repo: "https://github.com/\(parts[0])/\(repo).git", ref: ref, path: path)
        }
        if t.hasPrefix("git@") || (t.hasPrefix("https://") && t.hasSuffix(".git")) { return GitSource(repo: t, ref: nil, path: "") }
        return nil
    }

    public static func install(_ source: String, scope: Scope, workspace: URL, replace: Bool) async throws -> Outcome {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("sievesci-skill-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let unpacked = work.appendingPathComponent("src")
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)

        var root = unpacked
        if trimmed.lowercased().hasSuffix(".zip") && fm.fileExists(atPath: local.path) {
            try await unzip(local, into: unpacked)
        } else if trimmed.lowercased().hasPrefix("https://"), trimmed.lowercased().hasSuffix(".zip") {
            let file = work.appendingPathComponent("download.zip")
            try await download(trimmed, to: file)
            try await unzip(file, into: unpacked)
        } else if let g = gitSource(trimmed) {
            try await clone(g, into: unpacked)
            if !g.path.isEmpty { root = unpacked.appendingPathComponent(g.path) }
        } else if fm.fileExists(atPath: local.path) {
            root = local   // a folder on disk
        } else {
            throw ToolError.invalidInput("Give a GitHub link, a git URL, or a .zip (a path on this computer or an https URL).")
        }
        guard fm.fileExists(atPath: root.path) else { throw ToolError.invalidInput("\(source) has no folder \(root.lastPathComponent).") }
        try checkContents(root)

        let dest = destination(scope, workspace: workspace)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var out = Outcome()
        let skills = findSkills(root)
        if skills.isEmpty { throw ToolError.invalidInput("No SKILL.md (with name and description) found in \(source).") }
        for dir in skills {
            let md = dir.appendingPathComponent("SKILL.md")
            guard let skill = SkillRegistry.parse(md, source: scope.rawValue) else {
                out.refused.append("\(dir.lastPathComponent): SKILL.md needs front matter with name and description"); continue
            }
            let screened = EvolutionGovernor.screen((try? String(contentsOf: md, encoding: .utf8)) ?? "")
            if !screened.isEmpty { out.refused.append("\(skill.name): " + screened.joined(separator: "; ")); continue }
            let name = String(skill.name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) })
            guard !name.isEmpty, name != ".", name != ".." else { out.refused.append("\(skill.name): not a usable folder name"); continue }
            let target = dest.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) {
                guard replace else { out.skipped.append("\(name) (already installed; pass replace to update it)"); continue }
                try fm.removeItem(at: target)
            }
            try copyTree(dir, to: target)
            out.installed.append(name)
        }
        return out
    }

    // MARK: Fetching

    static func clone(_ g: GitSource, into dir: URL) async throws {
        guard let git = ProcessRunner.which("git") else { throw ToolError.invalidInput("git is not installed; download the repository as a .zip and install that.") }
        var args = ["clone", "--depth", "1"]
        if let ref = g.ref { args += ["--branch", ref] }
        var r = try await ProcessRunner.run(git, args + [g.repo, dir.path], timeout: 600)
        if r.exitCode != 0, g.ref != nil {
            // A ref that is a commit, not a branch or tag: clone the default branch and check it out.
            try? FileManager.default.removeItem(at: dir)
            r = try await ProcessRunner.run(git, ["clone", g.repo, dir.path], timeout: 900)
            if r.exitCode == 0, let ref = g.ref { r = try await ProcessRunner.run(git, ["-C", dir.path, "checkout", ref], timeout: 120) }
        }
        guard r.exitCode == 0 else { throw ToolError.invalidInput("git clone failed: " + r.stderr.truncated(400)) }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(".git"))
    }

    static func download(_ url: String, to file: URL) async throws {
        guard let u = URL(string: url) else { throw ToolError.invalidInput("Not a URL: \(url)") }
        let (tmp, resp) = try await URLSession.shared.download(from: u)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { throw ToolError.invalidInput("Download failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)).") }
        let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw ToolError.invalidInput("The archive is over \(maxBytes / 1_000_000) MB.") }
        try FileManager.default.moveItem(at: tmp, to: file)
    }

    static func unzip(_ zip: URL, into dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r: ProcessResult
        #if os(macOS)
        r = try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path], timeout: 300)
        #elseif os(Windows)
        r = try await ProcessRunner.run(ProcessRunner.which("tar") ?? "tar", ["-xf", zip.path, "-C", dir.path], timeout: 300)
        #else
        guard let unzip = ProcessRunner.which("unzip") else { throw ToolError.invalidInput("unzip is not installed.") }
        r = try await ProcessRunner.run(unzip, ["-q", zip.path, "-d", dir.path], timeout: 300)
        #endif
        guard r.exitCode == 0 else { throw ToolError.invalidInput("Could not unpack the archive: " + r.stderr.truncated(400)) }
    }

    // MARK: Checking and copying

    /// Everything stays inside the unpacked folder (no `..` escapes) and within the size and file caps.
    static func checkContents(_ root: URL) throws {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey], options: []) else { return }
        var bytes = 0, files = 0
        for case let u as URL in en {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true { continue }   // not copied
            let p = u.resolvingSymlinksInPath().standardizedFileURL.path
            guard p == base || p.hasPrefix(base + "/") else { throw ToolError.invalidInput("The archive has an entry outside its folder (\(u.lastPathComponent)); refused.") }
            files += 1; bytes += v?.fileSize ?? 0
            if files > maxFiles || bytes > maxBytes { throw ToolError.invalidInput("Too large to install as skills (over \(maxFiles) files or \(maxBytes / 1_000_000) MB).") }
        }
    }

    /// Folders holding a SKILL.md: the root itself, or skills up to four levels down (`skills/<name>/`).
    static func findSkills(_ root: URL) -> [URL] {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("SKILL.md").path) { return [root] }
        let base = root.standardizedFileURL.pathComponents.count
        var out: [URL] = []
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        for case let u as URL in en {
            let depth = u.standardizedFileURL.pathComponents.count - base
            if u.lastPathComponent == "SKILL.md" { out.append(u.deletingLastPathComponent()); continue }
            if ["node_modules", "__pycache__", ".venv", "venv"].contains(u.lastPathComponent) || depth >= 5 { en.skipDescendants() }
        }
        // A skill folder nested in another skill's folder belongs to it.
        return out.filter { d in !out.contains { $0 != d && d.path.hasPrefix($0.path + "/") } }
    }

    static func copyTree(_ from: URL, to: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: from, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) {
            let v = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true || item.lastPathComponent == ".git" { continue }
            let dest = to.appendingPathComponent(item.lastPathComponent)
            if v?.isDirectory == true { try copyTree(item, to: dest) } else { try fm.copyItem(at: item, to: dest) }
        }
    }
}

/// `skill_install`: install skills the user points to (a GitHub link, a git URL, a .zip).
struct SkillInstallTool: Tool {
    let name = "skill_install"
    let description = """
    Install skills from a GitHub link (a repository, or a folder inside one: …/tree/<branch>/<path>), a git URL, \
    or a .zip (a path on this computer or an https URL). Every folder with a SKILL.md (front matter: name, \
    description) is installed — for the user (all workspaces, default) or for this workspace only (scope \
    workspace). An installed skill with the same name is kept unless replace is true. Use it when the user asks \
    to install skills; afterwards load one by name with `skill`.
    """
    var inputSchema: JSON {
        Schema.object(["source": Schema.string("GitHub link, git URL, or .zip path / https URL"),
                       "scope": Schema.stringEnum("user (default) or workspace", ["user", "workspace"]),
                       "replace": Schema.bool("Replace skills of the same name that are already installed")],
                      required: ["source"])
    }
    // It fetches and unpacks files and writes outside the workspace: asked about like running a command.
    func effect(for input: JSON) -> ToolEffect { .executes }
    func runsConcurrently(for input: JSON) -> Bool { false }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard ctx.role == .main else { return .error("Only the main agent installs skills.") }
        guard let source = input.str("source"), !source.isEmpty else { return .error("Give the source: a GitHub link, a git URL or a .zip.") }
        let scope = SkillInstaller.Scope(rawValue: input.str("scope") ?? "user") ?? .user
        do {
            let r = try await SkillInstaller.install(source, scope: scope, workspace: ctx.services.workspace, replace: input["replace"]?.boolValue == true)
            ctx.services.skills.reload()
            ctx.services.log("skill_install", actor: "agent", ["source": .string(source), "scope": .string(scope.rawValue),
                                                               "installed": .array(r.installed.map { .string($0) }),
                                                               "skipped": .array(r.skipped.map { .string($0) }), "refused": .array(r.refused.map { .string($0) })])
            var lines: [String] = []
            if !r.installed.isEmpty { lines.append("Installed (\(scope.rawValue)): " + r.installed.joined(separator: ", ") + ". Load one with `skill` by name.") }
            if !r.skipped.isEmpty { lines.append("Kept: " + r.skipped.joined(separator: "; ")) }
            if !r.refused.isEmpty { lines.append("Refused: " + r.refused.joined(separator: "; ")) }
            return ToolOutput(lines.joined(separator: "\n"), isError: r.installed.isEmpty && r.skipped.isEmpty)
        } catch let e as ToolError {
            return .error("\(e)")
        }
    }
}
