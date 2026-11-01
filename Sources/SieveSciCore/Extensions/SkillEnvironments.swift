import Foundation

// MARK: - What a skill needs

/// A CPython 3.x version range: `minMinor` inclusive, `maxMinor` exclusive (3.10 ≤ v < 3.13 → 10, 13).
public struct PythonRange: Sendable, Equatable, CustomStringConvertible {
    public var minMinor: Int?
    public var maxMinor: Int?

    public init(minMinor: Int? = nil, maxMinor: Int? = nil) { self.minMinor = minMinor; self.maxMinor = maxMinor }

    public var isEmpty: Bool { if let a = minMinor, let b = maxMinor { return a >= b }; return false }
    public var isUnconstrained: Bool { minMinor == nil && maxMinor == nil }
    public func contains(minor: Int) -> Bool { (minMinor.map { minor >= $0 } ?? true) && (maxMinor.map { minor < $0 } ?? true) }
    public func intersect(_ o: PythonRange) -> PythonRange {
        PythonRange(minMinor: [minMinor, o.minMinor].compactMap { $0 }.max(), maxMinor: [maxMinor, o.maxMinor].compactMap { $0 }.min())
    }
    /// PEP 440 specifier, as uv and pip take it.
    public var spec: String {
        [minMinor.map { ">=3.\($0)" }, maxMinor.map { "<3.\($0)" }].compactMap { $0 }.joined(separator: ",")
    }
    public var description: String { isUnconstrained ? "any Python 3" : "Python " + spec }
}

public struct SkillRequirements: Sendable, Equatable {
    public enum GPU: String, Sendable { case none, recommended, required }

    public var python = PythonRange()
    /// Installable with pip / uv pip (PEP 508 requirement strings).
    public var packages: [String] = []
    /// Things SieveSci cannot install for the user (conda-only, GitHub source, licensed tools …).
    public var manual: [String] = []
    /// Executables the skill expects on PATH.
    public var binaries: [String] = []
    public var gpu = GPU.none
    /// Environment variables it reads (API keys, data paths).
    public var envVars: [String] = []
    /// Mentions an API key or account without naming the variable.
    public var unnamedKey = false
    /// A metered, billed service.
    public var metered = false
    /// Where the requirements came from: front matter, requirements.txt or compatibility text.
    public var source = "none"
    /// Contradicting Python constraints (the range is then the last one stated).
    public var conflict: String?

    public var needsEnvironment: Bool { !packages.isEmpty }

    /// Stable id of what the environment must contain; a change makes a new environment.
    public var fingerprint: String { String(Hashing.sha256Hex(python.spec + "|" + packages.sorted().joined(separator: "\n")).prefix(10)) }
}

/// Reads requirements from a skill. Explicit declarations win:
///   1. front matter `metadata.sievesci: {python: ">=3.11,<3.13", packages: [...], gpu: required, env: [KEY]}`
///   2. `requirements.txt` next to SKILL.md
///   3. the free-text `compatibility` field (and the body) as K-Dense and other packs write it:
///      "Python >=3.10 and <3.13", "Python 3.10+", "3.7–3.11", "CPython 3.11", "pip install boltz",
///      "datamol (uv pip install)", "`esm` 3.2.3 from PyPI", "needs admet-ai 2.0+ (pip", "with pandas, numpy and scipy".
public enum SkillRequirementsParser {
    public static func parse(meta: [String: Any], body: String, dir: URL?) -> SkillRequirements {
        var r = SkillRequirements()
        let compat = (meta["compatibility"] as? String) ?? ""
        let text = compat.isEmpty ? String(body.prefix(4000)) : compat
        let explicit = (meta["metadata"] as? [String: Any])?["sievesci"] as? [String: Any]

        // Python range
        if let p = explicit?["python"] as? String {
            r.python = range(fromSpec: p)
        } else {
            let (range, conflict) = pythonRange(in: text)
            r.python = range
            r.conflict = conflict
        }
        // Packages
        if let ps = explicit?["packages"] as? [String] {
            r.packages = ps; r.source = "front matter"
        } else if let dir, let req = try? String(contentsOf: dir.appendingPathComponent("requirements.txt"), encoding: .utf8) {
            r.packages = req.split(separator: "\n").map { line in String(line[..<(line.firstIndex(of: "#") ?? line.endIndex)]) }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("-") }
            r.source = "requirements.txt"
        } else {
            let (ps, manual) = packages(in: text)
            r.packages = ps
            r.manual += manual
            if !ps.isEmpty || !r.python.isUnconstrained { r.source = "compatibility text" }
        }
        // GPU
        if let g = (explicit?["gpu"] as? String).flatMap(SkillRequirements.GPU.init(rawValue:)) { r.gpu = g } else { r.gpu = gpu(in: text) }
        // Environment variables, keys, cost
        r.envVars = (explicit?["env"] as? [String]) ?? Array(Set(Grounding.matches(#"\b([A-Z][A-Z0-9]+(?:_[A-Z0-9]+)*_(?:API_KEY|TOKEN|KEY|DATA|HOME))\b"#, in: text, group: 1))).sorted()
        let keyMentions = Grounding.matches(#"(?i)[^.;]*\bapi key\b[^.;]*"#, in: text)
        r.unnamedKey = r.envVars.isEmpty && keyMentions.contains { $0.range(of: #"(?i)\b(no|needs no|without( an)?|not need)\b[^.;]*api key|api key[^.;]*\bnot (needed|required)"#, options: .regularExpression) == nil }
        r.metered = text.range(of: #"(?i)\b(metered|billed|commercial hosted|real cost)\b"#, options: .regularExpression) != nil
        // Binaries and things to install by hand
        let bins = Grounding.matches(#"(?i)\b(?:the )?([A-Za-z][\w-]{2,}) binary(?=\s*(?:\(|on\b|,|\.|;|$))"#, in: text, group: 1) + Grounding.matches(#"\b([a-z][\w-]{2,}) on PATH\b"#, in: text, group: 1)
        r.binaries = Array(Set(bins.map { $0.lowercased() }.filter { !["the", "vina's", "a"].contains($0) })).sorted()
        for m in Grounding.matches(#"(?i)conda install(?: -c [\w-]+)* ([\w.-]+)"#, in: text, group: 1) { r.manual.append("conda: \(m)") }
        if text.range(of: #"(?i)\bfrom GitHub\b|not on PyPI|\brepository\b|official Docker image"#, options: .regularExpression) != nil {
            r.manual.append("install from source (repository or Docker image) as the skill describes")
        }
        if text.range(of: #"(?i)conda-forge"#, options: .regularExpression) != nil, !r.manual.contains(where: { $0.hasPrefix("conda:") }) {
            r.manual.append("conda-forge builds, which the skill recommends (SieveSci manages pip environments only)")
        }
        if text.range(of: #"(?i)\b(signed licen[cs]e|academic licen[cs]e|not redistributable|requires a licen[cs]e)\b"#, options: .regularExpression) != nil {
            r.manual.append("a licensed external tool (obtain it as the skill describes)")
        }
        r.manual = Array(NSOrderedSet(array: r.manual)) as? [String] ?? r.manual
        return r
    }

    static func range(fromSpec s: String) -> PythonRange {
        var r = PythonRange()
        for part in s.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            guard let minor = Grounding.matches(#"3\.(\d+)"#, in: p, group: 1).first.flatMap(Int.init) else { continue }
            if p.hasPrefix(">=") { r = r.intersect(PythonRange(minMinor: minor)) }
            else if p.hasPrefix(">") { r = r.intersect(PythonRange(minMinor: minor + 1)) }
            else if p.hasPrefix("<=") { r = r.intersect(PythonRange(maxMinor: minor + 1)) }
            else if p.hasPrefix("<") { r = r.intersect(PythonRange(maxMinor: minor)) }
            else if p.hasPrefix("==") || p.first?.isNumber == true { r = r.intersect(PythonRange(minMinor: minor, maxMinor: minor + 1)) }
        }
        return r
    }

    /// Every version constraint in the text, intersected.
    static func pythonRange(in text: String) -> (PythonRange, String?) {
        var parts: [PythonRange] = []
        let t = text.replacingOccurrences(of: "≥", with: ">=").replacingOccurrences(of: "≤", with: "<=")
        // "Python 3.7–3.11", "Python 3.9-3.10" (inclusive upper)
        for m in CodePaperLinker.matchGroups(#"(?i)python\s+3\.(\d+)\s*[–-]\s*3\.(\d+)"#, t) {
            if let a = Int(m[1]), let b = Int(m[2]) { parts.append(PythonRange(minMinor: a, maxMinor: b + 1)) }
        }
        // "Python >=3.10 and <3.13", "requires-python >=3.11", "Python >=3.12,<3.13", "Python 3.10+", "CPython 3.11", "Python 3.9 environment"
        for m in CodePaperLinker.matchGroups(#"(?i)\b(c?python|requires-python)\s*(>=|>|<=|<|==)?\s*3\.(\d+)(\+)?(?:\s*(?:,|and)?\s*(<=|<)\s*3\.(\d+))?(\s+environment)?"#, t) {
            guard let minor = Int(m[3]) else { continue }
            if t.range(of: #"(?i)python\s+3\.\#(minor)\s*[–-]\s*3\.\d+"#, options: .regularExpression) != nil, m[2].isEmpty, m[4].isEmpty { continue }   // already a range
            var r: PythonRange
            switch m[2] {
            case ">=": r = PythonRange(minMinor: minor)
            case ">": r = PythonRange(minMinor: minor + 1)
            case "<=": r = PythonRange(maxMinor: minor + 1)
            case "<": r = PythonRange(maxMinor: minor)
            case "==": r = PythonRange(minMinor: minor, maxMinor: minor + 1)
            default:
                let exact = m[1].lowercased() == "cpython" || !m[7].isEmpty
                r = exact && m[4].isEmpty ? PythonRange(minMinor: minor, maxMinor: minor + 1) : PythonRange(minMinor: minor)
            }
            if let up = Int(m[6]) { r = r.intersect(PythonRange(maxMinor: m[5] == "<=" ? up + 1 : up)) }
            parts.append(r)
        }
        // "caps at <3.12", "requires-python <3.11"
        for m in Grounding.matches(#"(?i)caps at\s*<\s*3\.(\d+)"#, in: t, group: 1) { if let u = Int(m) { parts.append(PythonRange(maxMinor: u)) } }
        var r = PythonRange()
        for p in parts {
            let next = r.intersect(p)
            if next.isEmpty { return (p, "the skill states incompatible Python versions (\(r) and \(p)); using \(p)") }
            r = next
        }
        return (r, nil)
    }

    static let notPackages: Set<String> = ["the", "and", "or", "with", "from", "python", "a", "an", "it", "its", "uv", "pip", "install", "only", "standard", "library"]

    /// pip-installable packages, and what must be installed by hand.
    static func packages(in text: String) -> ([String], [String]) {
        var out: [String] = [], manual: [String] = []
        func add(_ p: String) {
            let name = p.trimmingCharacters(in: CharacterSet(charactersIn: " `'\",;:()"))
            guard !name.isEmpty, let first = name.first, first.isLetter, !notPackages.contains(name.lowercased()) else { return }
            if !out.contains(where: { $0.lowercased() == name.lowercased() }) { out.append(name) }
        }
        // "pip install boltz", "uv pip install anarci", "pip install vina 1.2.7" (→ vina==1.2.7)
        let pipRe = try! NSRegularExpression(pattern: #"(?i)(?:uv\s+)?pip install\s+((?:[A-Za-z0-9][\w.\-\[\]]*(?:[=<>!~]=?[\w.*]+)?\s*)+)"#)
        let ns = text as NSString
        for m in pipRe.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let after = ns.substring(with: NSRange(location: m.range.upperBound, length: min(80, ns.length - m.range.upperBound)))
            let args = ns.substring(with: m.range(at: 1))
            if after.range(of: #"(?i)^\W{0,3}(fetches|installs|gives) an? (unrelated|wrong|placeholder)|placeholder"#, options: .regularExpression) != nil {
                manual.append("not `pip install \(args.trimmingCharacters(in: .whitespaces))` (the skill warns it installs the wrong package)")
                continue
            }
            var tokens = args.split(separator: " ").map(String.init)
            var i = 0
            while i < tokens.count {
                if i + 1 < tokens.count, tokens[i + 1].range(of: #"^\d+(\.\d+)+$"#, options: .regularExpression) != nil {
                    tokens[i] += "==" + tokens[i + 1]; tokens.remove(at: i + 1)
                }
                if tokens[i].first?.isLetter == true { add(tokens[i]) }
                i += 1
            }
        }
        // "datamol (uv pip install)"
        for m in Grounding.matches(#"\b([A-Za-z][\w-]*) \((?:uv )?pip install\)"#, in: text, group: 1) { add(m) }
        // "`esm` 3.2.3 from PyPI", "PyPI package `rdkit`"
        for m in CodePaperLinker.matchGroups(#"`([A-Za-z][\w-]*)` (\d+(?:\.\d+)+) from PyPI"#, text) { add("\(m[1])==\(m[2])") }
        for m in Grounding.matches(#"PyPI package `([A-Za-z][\w-]*)`"#, in: text, group: 1) { add(m) }
        // "needs aizynthfinder 4.4+ (pip", "needs admet-ai 2.0+ (pip"
        for m in CodePaperLinker.matchGroups(#"\bneeds ([a-z][\w-]*) (\d+(?:\.\d+)*)\+ \(pip"#, text) { add("\(m[1])>=\(m[2])") }
        // "Python 3.10+ with pandas, numpy, scipy and requests" — a list item followed by more prose
        // ("…and mdanalysis, best installed from conda-forge") starts the next clause, not a package.
        let version = #"(?:[<>=≥≤]*\s*3\.\d+\+?(?:\s*(?:,|and)\s*[<>=≤]*\s*3\.\d+)?)"#
        let withRe = try! NSRegularExpression(pattern: #"(?i)python\s+"# + version + #"\s+with\s+([a-z][\w-]*(?:(?:,\s*(?:and\s+)?|\s+and\s+)[a-z][\w-]*)*)"#)
        for m in withRe.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var items = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: " and ", with: ", ").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let rest = ns.substring(from: m.range.upperBound)
            if rest.range(of: #"^ [a-z]"#, options: .regularExpression) != nil, items.count > 1 { items.removeLast() }
            items.forEach(add)
        }
        // "Requires uv, CPython 3.11, PyTDC 1.1.15, and setuptools 80.9.0": pinned names in a requirements sentence.
        for sentence in text.components(separatedBy: ". ") where sentence.hasPrefix("Requires") {
            for m in CodePaperLinker.matchGroups(#"\b([A-Za-z][\w-]*) (\d+\.\d+\.\d+)\b"#, sentence) where !["python", "cpython", "pypi"].contains(m[1].lowercased()) {
                add("\(m[1].lowercased())==\(m[2])")
            }
        }
        // "Uses the `requests` library"
        for m in Grounding.matches(#"`([A-Za-z][\w-]*)` (?:library|package)"#, in: text, group: 1) { add(m) }
        // One entry per package; a pinned mention beats an unpinned one.
        var byName: [String: String] = [:], order: [String] = []
        for p in out {
            let name = String(p.prefix { !"=<>!~[".contains($0) }).lowercased()
            if let existing = byName[name] {
                if !existing.contains(where: { "=<>!~".contains($0) }) { byName[name] = p }
            } else { order.append(name); byName[name] = p }
        }
        out = order.compactMap { byName[$0] }
        return (out, manual)
    }

    static func gpu(in text: String) -> SkillRequirements.GPU {
        var required = false, recommended = false, negated = false
        for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".;—")) where sentence.range(of: #"\b(GPU|CUDA)\b"#, options: .regularExpression) != nil {
            if sentence.range(of: #"(?i)\bno (local )?gpu\b|gpu (is )?not (needed|required)|no gpu is required|\bcpu only\b|without a gpu"#, options: .regularExpression) != nil { negated = true }
            else if sentence.range(of: #"(?i)\b(optional|speeds? up|recommended|helps)\b"#, options: .regularExpression) != nil { recommended = true }
            else { required = true }
        }
        let cpuWorks = text.range(of: #"(?i)\bcpu (works|is (sufficient|adequate|fine))\b"#, options: .regularExpression) != nil
        if required && !negated && !cpuWorks { return .required }
        if required || recommended { return .recommended }
        return .none
    }
}

// MARK: - Environments

/// Runs installer commands; replaced in tests.
public struct EnvironmentError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

public protocol EnvironmentInstaller: Sendable {
    func which(_ name: String) -> String?
    func run(_ exe: String, _ args: [String]) async throws -> ProcessResult
}

public struct SystemInstaller: EnvironmentInstaller {
    public init() {}
    public func which(_ name: String) -> String? { ProcessRunner.which(name) }
    public func run(_ exe: String, _ args: [String]) async throws -> ProcessResult { try await ProcessRunner.run(exe, args, timeout: 1800) }
}

/// One Python environment per skill and requirement set, under `~/.sievesci/envs/<skill>-<fingerprint>`.
/// Built with `uv` when it is installed (it can also fetch a matching Python), otherwise with a
/// system interpreter in range and `python -m venv` + pip. Creating one downloads packages, so it is
/// only done through the `skill_env` tool, which is approved like any external call. Agent code
/// can read an environment but not write to it (the sandbox write roots exclude it).
public final class SkillEnvironments: @unchecked Sendable {
    public let root: URL
    let installer: EnvironmentInstaller
    private let lock = NSLock()

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sievesci/envs"),
                installer: EnvironmentInstaller = SystemInstaller()) {
        self.root = root
        self.installer = installer
    }

    public static func requirements(of skill: Skill) -> SkillRequirements {
        guard let text = try? String(contentsOf: skill.path, encoding: .utf8) else { return SkillRequirements() }
        let (meta, body) = SkillRegistry.frontMatter(text)
        return SkillRequirementsParser.parse(meta: meta, body: body, dir: skill.path.deletingLastPathComponent())
    }

    public func directory(for skill: Skill, _ req: SkillRequirements) -> URL {
        let safe = skill.name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        return root.appendingPathComponent(String(safe) + "-" + req.fingerprint)
    }

    /// The environment's interpreter, if it has been set up for these requirements.
    public func interpreter(for skill: Skill, _ req: SkillRequirements) -> String? {
        let dir = directory(for: skill, req)
        let py = dir.appendingPathComponent("bin/python").path
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("sievesci-env.json").path),
              FileManager.default.isExecutableFile(atPath: py) else { return nil }
        return py
    }

    /// Python minor version of an interpreter.
    func minor(of exe: String) async -> Int? {
        guard let r = try? await installer.run(exe, ["-c", "import sys; print(sys.version_info[0], sys.version_info[1])"]), r.exitCode == 0 else { return nil }
        let p = r.stdout.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return p.count == 2 && p[0] == "3" ? Int(p[1]) : nil
    }

    /// The newest system interpreter inside the range.
    func systemPython(in range: PythonRange) async -> (String, Int)? {
        var best: (String, Int)?
        var seen = Set<String>()
        for name in (8...14).reversed().map({ "python3.\($0)" }) + ["python3"] {
            guard let exe = installer.which(name), seen.insert(exe).inserted, let m = await minor(of: exe), range.contains(minor: m) else { continue }
            if best == nil || m > best!.1 { best = (exe, m) }
        }
        return best
    }

    /// What the machine lacks for this skill, in plain terms (GPU, keys, binaries, manual installs).
    public func gaps(_ req: SkillRequirements, secrets: SecretStore) -> [String] {
        var out: [String] = []
        if req.gpu != .none && installer.which("nvidia-smi") == nil {
            out.append(req.gpu == .required
                       ? "needs an NVIDIA GPU (CUDA); none was found on this machine — expect it to fail or be impractically slow here; consider a cluster or a hosted service"
                       : "runs faster with an NVIDIA GPU (CUDA); none was found, so it will run on the CPU (slower)")
        }
        let missing = req.envVars.filter { (secrets.secret(for: $0) ?? ProcessRunner.loginEnvironment[$0] ?? "").isEmpty }
        if !missing.isEmpty { out.append("needs \(missing.joined(separator: ", ")) — not set; ask the user to add it (Settings → Keys, or the environment)") }
        if req.unnamedKey { out.append("needs an account / API key for an external service (the skill says where to get one)") }
        if req.metered { out.append("uses a metered, billed service — confirm cost with the user before large batches") }
        let absent = req.binaries.filter { installer.which($0) == nil }
        if !absent.isEmpty { out.append("expects \(absent.joined(separator: ", ")) on PATH — not found") }
        for m in req.manual { out.append("install by hand: \(m)") }
        if let c = req.conflict { out.append(c) }
        return out
    }

    /// The `<environment>` block shown with a skill's instructions.
    public func describe(_ skill: Skill, secrets: SecretStore) -> String? {
        let req = Self.requirements(of: skill)
        let gaps = gaps(req, secrets: secrets)
        guard req.needsEnvironment || !gaps.isEmpty || !req.python.isUnconstrained else { return nil }
        var s = "<environment skill=\"\(skill.name)\" source=\"\(req.source)\">\n"
        s += "Needs \(req.python)" + (req.packages.isEmpty ? "" : " with: \(req.packages.joined(separator: ", "))") + "\n"
        if req.needsEnvironment {
            if let py = interpreter(for: skill, req) {
                s += "Environment ready: \(py). Run this skill's code with `python` / `bash` and env \"\(skill.name)\".\n"
            } else {
                s += "Environment not set up. Before running code that needs these packages, call `skill_env` with action \"setup\" and name \"\(skill.name)\" (the user approves the download), then pass env \"\(skill.name)\" to `python` / `bash`.\n"
            }
        }
        if !gaps.isEmpty { s += "Missing on this machine:\n" + gaps.map { "- " + $0 }.joined(separator: "\n") + "\n" }
        return s + "</environment>"
    }

    public struct SetupResult: Sendable { public var python: String; public var log: String; public var created: Bool }

    /// Creates the environment and installs the packages. Call only after the user approved.
    public func setup(_ skill: Skill, _ req: SkillRequirements) async throws -> SetupResult {
        if let py = interpreter(for: skill, req) { return SetupResult(python: py, log: "already set up", created: false) }
        let dir = directory(for: skill, req)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var log: [String] = []
        func step(_ exe: String, _ args: [String]) async throws {
            log.append("$ " + ([exe] + args).joined(separator: " "))
            let r = try await installer.run(exe, args)
            log.append((r.stdout + r.stderr).truncated(4000))
            guard r.exitCode == 0 else {
                try? FileManager.default.removeItem(at: dir)
                throw EnvironmentError(message: "`\(([exe] + args).joined(separator: " "))` failed (exit \(r.exitCode)):\n" + (r.stderr.isEmpty ? r.stdout : r.stderr).truncated(2000))
            }
        }
        let tool: String
        if let uv = installer.which("uv") {
            tool = "uv"
            try await step(uv, ["venv", "--python", req.python.isUnconstrained ? ">=3.9" : req.python.spec, dir.path])
            if !req.packages.isEmpty { try await step(uv, ["pip", "install", "--python", dir.appendingPathComponent("bin/python").path] + req.packages) }
        } else {
            guard let (exe, m) = await systemPython(in: req.python) else {
                throw EnvironmentError(message: "No installed Python matches \(req.python), and uv is not installed. Install uv (`brew install uv`), which can fetch a matching Python, or install Python 3.\(req.python.minMinor ?? 11).")
            }
            tool = "venv (python 3.\(m))"
            try await step(exe, ["-m", "venv", dir.path])
            let py = dir.appendingPathComponent("bin/python").path
            if !req.packages.isEmpty { try await step(py, ["-m", "pip", "install", "--disable-pip-version-check"] + req.packages) }
        }
        let marker: JSON = ["skill": .string(skill.name), "python": .string(req.python.spec), "packages": .array(req.packages.map { .string($0) }),
                            "tool": .string(tool), "created": .string(ISO8601DateFormatter().string(from: Date()))]
        try JSONCodec.pretty(marker).write(to: dir.appendingPathComponent("sievesci-env.json"), atomically: true, encoding: .utf8)
        try log.joined(separator: "\n").write(to: dir.appendingPathComponent("install.log"), atomically: true, encoding: .utf8)
        guard let py = interpreter(for: skill, req) else { throw EnvironmentError(message: "the environment was created but has no bin/python") }
        return SetupResult(python: py, log: log.joined(separator: "\n"), created: true)
    }

    /// Shell prefix that activates an environment for one command.
    public static func activation(python: String) -> String {
        let bin = URL(fileURLWithPath: python).deletingLastPathComponent()
        let venv = bin.deletingLastPathComponent().path
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "export VIRTUAL_ENV=\(q(venv)); export PATH=\(q(bin.path)):\"$PATH\"; unset PYTHONHOME; "
    }
}
