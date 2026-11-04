import Foundation
import Yams

/// Agent Skills (the `SKILL.md` format shared by Claude Code, Codex, Gemini CLI, OpenCode, Reasonix
/// and DeepSeek Harness). Discovery roots, in precedence order:
///   <workspace>/.sievesci/skills, <workspace>/.claude/skills, <workspace>/.agents/skills,
///   ~/.sievesci/skills, ~/.claude/skills, ~/.agents/skills, ~/.codex/skills, ~/.sievesci/skill-packs/*/skills
/// Progressive disclosure: only names + descriptions enter the context (once, in the first user
/// turn, so they never disturb the cached prefix); the body loads when the `skill` tool is called
/// or the user types `/<skill-name>`.
public struct Skill: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var path: URL                // SKILL.md
    public var allowedTools: [String]
    public var source: String           // workspace | user | learned | pack:<name>
    public var userInvocable: Bool
    /// Learned skills are scoped to the role that learned them; nil = every role.
    public var role: AgentRole?
}

public struct SkillPack: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var repo: String
    public var license: String
    public var notes: String
}

public final class SkillRegistry: @unchecked Sendable {
    public let workspace: URL
    private let lock = NSLock()
    public private(set) var skills: [Skill] = []

    /// Curated packs offered in `/plugins`. Installing clones the repo; nothing is vendored.
    public static let knownPacks: [SkillPack] = [
        SkillPack(id: "k-dense-scientific", title: "K-Dense Scientific Skills (≈180 skills)", repo: "https://github.com/K-Dense-AI/claude-scientific-skills",
                  license: "MIT", notes: "Biopython, RDKit, scanpy, PubMed, UniProt, PDB, ChEMBL, plotting, statistics…"),
        SkillPack(id: "k-dense-drug-discovery", title: "K-Dense Drug Discovery Skills", repo: "https://github.com/K-Dense-AI/drug-discovery-agent-skills",
                  license: "MIT", notes: "Pharmacophores, docking, molecular dynamics, ADMET."),
    ]

    public init(workspace: URL) {
        self.workspace = workspace
        reload()
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var packsDir: URL { home.appendingPathComponent(".sievesci/skill-packs") }
    /// Where governed, agent-learned skills live.
    public static var learnedDir: URL { home.appendingPathComponent(".sievesci/learned-skills") }

    var roots: [(URL, String)] {
        var r: [(URL, String)] = [
            (workspace.appendingPathComponent(".sievesci/skills"), "workspace"),
            (workspace.appendingPathComponent(".claude/skills"), "workspace"),
            (workspace.appendingPathComponent(".agents/skills"), "workspace"),
            (Self.home.appendingPathComponent(".sievesci/skills"), "user"),
            (Self.learnedDir, "learned"),
            (Self.home.appendingPathComponent(".claude/skills"), "user"),
            // Skills installed for other agents on this Mac (Codex, the shared .agents folder).
            (Self.home.appendingPathComponent(".agents/skills"), "user"),
            (Self.home.appendingPathComponent(".codex/skills"), "user"),
        ]
        // Workflow skills shipped with SieveSci (lowest precedence: users can override them by name).
        if let builtin = SieveSciResources.directory("Resources/skills") { r.append((builtin, "builtin")) }
        for pack in (try? FileManager.default.contentsOfDirectory(at: Self.packsDir, includingPropertiesForKeys: nil)) ?? [] {
            r.append((pack.appendingPathComponent("skills"), "pack:\(pack.lastPathComponent)"))
            r.append((pack, "pack:\(pack.lastPathComponent)"))
        }
        return r
    }

    public func reload() {
        var found: [String: Skill] = [:]
        for (root, source) in roots {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en {
                // ~/.claude/skills/synced/<account>/ holds skills the Claude app syncs for its own tools
                // (built-in browser, computer use, Chrome …); they refer to tools SieveSci does not have.
                if url.lastPathComponent == "synced", root.path.hasSuffix("/.claude/skills") { en.skipDescendants(); continue }
                guard url.lastPathComponent == "SKILL.md" else { continue }
                guard let s = Self.parse(url, source: source), found[s.name] == nil else { continue }
                found[s.name] = s
            }
        }
        lock.lock()
        skills = found.values.sorted { $0.name < $1.name }
        lock.unlock()
    }

    public static func frontMatter(_ text: String) -> (meta: [String: Any], body: String) {
        // Files checked out or edited on Windows may have CRLF line ends.
        let text = text.contains("\r\n") ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        guard text.hasPrefix("---") else { return ([:], text) }
        let parts = text.components(separatedBy: "\n---")
        guard parts.count >= 2 else { return ([:], text) }
        let yaml = String(parts[0].dropFirst(3))
        let body = parts.dropFirst().joined(separator: "\n---").drop { $0 == "\n" || $0 == "-" }
        let meta = ((try? Yams.load(yaml: yaml)) as? [String: Any]) ?? [:]
        return (meta, String(body))
    }

    static func parse(_ url: URL, source: String) -> Skill? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let (meta, _) = frontMatter(text)
        let name = (meta["name"] as? String) ?? url.deletingLastPathComponent().lastPathComponent
        guard let desc = meta["description"] as? String else { return nil }
        let allowed: [String]
        if let s = meta["allowed-tools"] as? String { allowed = s.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init) }
        else { allowed = (meta["allowed-tools"] as? [String]) ?? [] }
        let invocable = (meta["user-invocable"] as? Bool) ?? true
        let role = ((meta["metadata"] as? [String: Any])?["role"] as? String).flatMap(AgentRole.init(rawValue:))
        return Skill(name: name, description: desc, path: url, allowedTools: allowed, source: source, userInvocable: invocable, role: role)
    }

    public func skill(_ name: String) -> Skill? {
        lock.lock(); defer { lock.unlock() }
        return skills.first { $0.name == name }
    }

    /// Full instructions, with the skill directory so relative references (scripts/, references/) resolve.
    public func body(_ name: String) -> String? {
        guard let s = skill(name), let text = try? String(contentsOf: s.path, encoding: .utf8) else { return nil }
        return "<skill name=\"\(s.name)\" dir=\"\(s.path.deletingLastPathComponent().path)\">\n\(Self.frontMatter(text).body)\n</skill>"
    }

    /// The index shown to a role (once per session, in the first user turn).
    public func index(for role: AgentRole) -> String {
        lock.lock(); defer { lock.unlock() }
        let visible = skills.filter { $0.role == nil || $0.role == role || (role == .main && $0.role == .main) }
        guard !visible.isEmpty else { return "" }
        // Research and writing skills with their descriptions; the rest by name only, so a folder full
        // of design or firmware skills costs a few tokens, not thousands.
        let research = visible.filter { Self.isResearchSkill($0) }
        let other = visible.filter { !Self.isResearchSkill($0) }
        var out = "<available_skills>\n" + research.map { "- \($0.name): \($0.description.truncated(240, marker: "…"))" }.joined(separator: "\n")
        if !other.isEmpty { out += "\nOther skills (load by name if one fits): " + other.map(\.name).joined(separator: ", ") }
        if let route = Self.writingRoute(Set(visible.map(\.name))) { out += "\n\n" + route }
        return out + "\nLoad one with the `skill` tool when a task matches its description.\n</available_skills>"
    }

    static func isResearchSkill(_ s: Skill) -> Bool {
        if s.source == "builtin" || s.source.hasPrefix("pack:") || s.source == "learned" || s.source == "workspace" { return true }
        let name = s.name.lowercased()
        if ["nature-", "paper", "aigc", "shuorenhua", "academic", "citation", "literature", "biomni", "research", "scientific"].contains(where: name.contains) { return true }
        // Science words only, whole words: "review", "figure" or "generate" also describe UI and slide skills.
        let science = #"(?i)\b(manuscripts?|journals?|peer[- ]review|literature|citations?|academic|thesis|biolog\w*|chemi\w*|proteins?|genes?|genom\w*|molecul\w*|drug discovery|assays?|(dna|rna|amplicon|genome|next-generation) sequencing|statistics|statistical (tests?|analysis|reporting)|single-cell|omics|pubmed|uniprot|rdkit|biopython|clinical)\b|论文|文献|期刊|降 ?AI|AI ?味"#
        return s.description.range(of: science, options: .regularExpression) != nil
    }

    /// Which skill to use at each stage of writing a paper, from the skills this Mac has.
    static func writingRoute(_ have: Set<String>) -> String? {
        let stages: [(String, [String])] = [
            ("whole Chinese review / course paper, end to end", ["paper-pipeline"]),
            ("find and screen literature", ["nature-academic-search", "nature-literature-pipeline", "nature-downloader"]),
            ("read a paper (bilingual reader)", ["nature-reader"]),
            ("draft or restructure sections", ["nature-writing", "nature-proposal-writer"]),
            ("submission-grade figures (R or Python)", ["nature-figure"]),
            ("statistical reporting", ["nature-statistics"]),
            ("add and check citations", ["nature-citation", "nature-ref-verifier"]),
            ("polish English prose", ["nature-polishing"]),
            ("data availability", ["nature-data"]),
            ("pre-submission review / rebuttal", ["nature-reviewer", "nature-response"]),
            ("remove AI tone, last (facts, numbers and citations unchanged)", ["shuorenhua", "aigc-reduce"]),
        ]
        let lines = stages.compactMap { stage, names -> String? in
            let ok = names.filter(have.contains)
            return ok.isEmpty ? nil : "- \(stage): " + ok.map { "`\($0)`" }.joined(separator: ", ")
        }
        guard lines.count >= 2 else { return nil }
        return "Writing a paper or report? Load the skill for each stage before doing it:\n" + lines.joined(separator: "\n")
            + "\nSkills written for other agents name their tools (Bash, Read, Write …): use SieveSci's equivalents (bash, read_file, write_file …), and keep SieveSci's integrity rules and receipts."
    }

    public static func install(_ pack: SkillPack) async throws -> String {
        try FileManager.default.createDirectory(at: packsDir, withIntermediateDirectories: true)
        let dest = packsDir.appendingPathComponent(pack.id)
        if FileManager.default.fileExists(atPath: dest.path) {
            let r = try await ProcessRunner.run("git", ["-C", dest.path, "pull", "--ff-only"], timeout: 300)
            return r.exitCode == 0 ? L10n.s("Updated %@.", pack.title) : L10n.s("Update failed: %@", r.stderr.truncated(500))
        }
        let r = try await ProcessRunner.run("git", ["clone", "--depth", "1", pack.repo, dest.path], timeout: 600)
        return r.exitCode == 0 ? L10n.s("Installed %@ into %@.", pack.title, dest.path) : L10n.s("Install failed: %@", r.stderr.truncated(500))
    }
}

/// Custom slash commands: `.sievesci/commands/*.md`, `.claude/commands/*.md` (workspace and home).
/// Front matter `description` / `argument-hint`; `$ARGUMENTS`, `$1`…`$9` are substituted.
public struct CustomCommand: Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var argumentHint: String
    public var template: String

    public func expand(_ args: String) -> String {
        var t = template.replacingOccurrences(of: "$ARGUMENTS", with: args)
        let parts = args.split(separator: " ").map(String.init)
        for i in (1...9).reversed() { t = t.replacingOccurrences(of: "$\(i)", with: i <= parts.count ? parts[i - 1] : "") }
        return t
    }

    public static func load(workspace: URL) -> [CustomCommand] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = [workspace.appendingPathComponent(".sievesci/commands"), workspace.appendingPathComponent(".claude/commands"),
                    home.appendingPathComponent(".sievesci/commands"), home.appendingPathComponent(".claude/commands")]
        var out: [String: CustomCommand] = [:]
        for d in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "md" {
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                let (meta, body) = SkillRegistry.frontMatter(text)
                let name = f.deletingPathExtension().lastPathComponent
                if out[name] == nil {
                    out[name] = CustomCommand(name: name, description: (meta["description"] as? String) ?? body.split(separator: "\n").first.map(String.init) ?? "",
                                              argumentHint: (meta["argument-hint"] as? String) ?? "", template: body)
                }
            }
        }
        return out.values.sorted { $0.name < $1.name }
    }
}

/// Project memory files, read once per session into the first user turn:
/// `SIEVESCI.md`, `AGENTS.md`, `CLAUDE.md` in the workspace, and `~/.sievesci/SIEVESCI.md`.
public enum ProjectMemory {
    public static let fileNames = ["SIEVESCI.md", "AGENTS.md", "CLAUDE.md"]

    public static func load(workspace: URL) -> String {
        var parts: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/SIEVESCI.md")
        if let t = try? String(contentsOf: home, encoding: .utf8) { parts.append("<memory source=\"user\">\n\(t)\n</memory>") }
        for n in fileNames {
            if let t = try? String(contentsOf: workspace.appendingPathComponent(n), encoding: .utf8) {
                parts.append("<memory source=\"\(n)\">\n\(t.truncated(40_000))\n</memory>")
            }
        }
        return parts.joined(separator: "\n")
    }

    /// `#` prefix in the input box: append a line to the workspace memory file.
    public static func remember(_ line: String, workspace: URL) throws {
        let url = workspace.appendingPathComponent("SIEVESCI.md")
        var t = (try? String(contentsOf: url, encoding: .utf8)) ?? "# SieveSci project memory\n"
        if !t.hasSuffix("\n") { t += "\n" }
        t += "- \(line.trimmingCharacters(in: .whitespaces))\n"
        try t.write(to: url, atomically: true, encoding: .utf8)
    }
}
