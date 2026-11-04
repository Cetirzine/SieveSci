import Foundation

public enum BuiltinTools {
    public static func all() -> [Tool] {
        [BashTool(), PythonTool(), ReadFileTool(), WriteFileTool(), EditFileTool(), GlobTool(), GrepTool(),
         WebSearchTool(), WebFetchTool(), LiteratureSearchTool(), PaperFetchTool(), PaperReadTool(), PaperCodeLinksTool(), PaperGraphTool(),
         UpdatePlanTool(), ClaimFindingTool(), TodoWriteTool(), GoalTool(), TaskTool(), SkillTool(), SkillEnvTool(), ReceiptTool(), JobOutputTool(), JobWatchTool(), RespondReviewTool(),
         VerifyCitationTool(), DispatchTool(), MemoryTool(), SessionSearchTool(), SessionReadTool(), SkillManageTool(),
         LibrarySearchTool(), ChemLookupTool(), BioDatabaseTool(), BioToolSearchTool(), RepoMapTool(),
         AskUserTool(), BrainstormTool(), IdeaTool(), IdeationSeedsTool()]
    }
}

// MARK: - Execution

struct BashTool: Tool {
    let name = "bash"
    let description = """
    Run a shell command in the workspace (bash -lc). Use for CLI bioinformatics/chemistry tools (samtools, \
    blast, obabel, gmx, Rscript …), git and file management. Output streams live to the user. \
    Anything that may take more than a minute or two (alignments, simulations, training, downloads): set \
    run_in_background. The job's output streams to the user and a log file, and you are notified \
    automatically when it exits, when a line matches notify_on, when an error appears (tracebacks, \
    Killed, OOM, NaN loss), or when it stalls — so never sleep or poll in a loop; end your turn or do other \
    work, and read new output with `job_output` when you need it. Foreground output is truncated to the \
    last 30k characters.
    """
    var inputSchema: JSON {
        Schema.object(["command": Schema.string("The command"), "timeout": Schema.integer("Seconds (default 600, max 7200; foreground only)"),
                       "run_in_background": Schema.bool("Start as a streaming background job and return immediately"),
                       "notify_on": Schema.string("Background: regex; notify when an output line matches (e.g. 'epoch \\d+ done|converged')"),
                       "notify_errors": Schema.bool("Background: notify on error-looking lines (default true)"),
                       "stall_minutes": Schema.number("Background: notify if no output for this many minutes"),
                       "env": Schema.string("Activate a skill's Python environment for this command (skill name; see `skill_env`)")],
                      required: ["command"])
    }
    func effect(for input: JSON) -> ToolEffect { .executes }

    /// `sleep N; check` loops waste turns and tokens; streaming jobs notify instead.
    static func isSleepPoll(_ cmd: String) -> Bool {
        for m in Grounding.matches(#"(?:^|[;&|]\s*|\bdo\s+)sleep\s+(\d+)"#, in: cmd, group: 1) where (Int(m) ?? 0) >= 30 { return true }
        return cmd.contains("while") && cmd.contains("sleep")
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        var cmd = try input.required("command")
        if let env = input.str("env"), !env.isEmpty {
            switch SkillEnvTool.interpreter(env, ctx) {
            case .success(let py): cmd = SkillEnvironments.activation(python: py) + cmd
            case .failure(let why): return .error(why.message)
            }
        }
        if let t = ctx.privateTempDir { cmd = "export TMPDIR='\(t.path)'; " + cmd }
        let cwd = ctx.writeRoot ?? ctx.workspace
        let protected = [ctx.workspace.appendingPathComponent(".sievesci"), ctx.workspace.appendingPathComponent(".git")]
        let read = ctx.sandboxReadHidden
        if input.bool("run_in_background") == true {
            let id = try ctx.services.jobs.start(command: cmd, cwd: cwd, agentId: ctx.sessionId, sandbox: ctx.sandboxMode,
                                                 writableRoots: [cwd], protected: protected, readHidden: read.hidden, readAllowed: read.allowed, readRehidden: read.rehidden,
                                                 notifyOn: input.str("notify_on"),
                                                 notifyErrors: input.bool("notify_errors") ?? true, stallMinutes: input["stall_minutes"]?.numberValue)
            ctx.services.log("job_start", actor: ctx.role.rawValue, ["job": .string(id), "command": .string(cmd), "agent": .string(ctx.sessionId)])
            return ToolOutput("""
            Started \(id). Its output streams live to the user and to .sievesci/tasks/\(ctx.services.taskId)/jobs/\(id).log. \
            You will be notified automatically when it exits\(input.str("notify_on").map { ", when a line matches /\($0)/" } ?? ""), \
            on errors\(input["stall_minutes"] != nil ? ", or if it stalls" : ""). Do not sleep or poll: continue with other work or end your turn.
            """, facts: ["job": .string(id)])
        }
        if Self.isSleepPoll(cmd) {
            return .error("""
            Refused: waiting with sleep/polling loops wastes the session. Start the long-running command with \
            run_in_background (optionally notify_on / stall_minutes), or follow an existing log with `job_watch` \
            (path + notify_on/until); you will be notified when something happens.
            """)
        }
        let before = Self.snapshot(cwd)
        let (exe, args) = Seatbelt.wrap("/bin/bash", ["-lc", cmd], mode: ctx.sandboxMode, writableRoots: [cwd], protected: protected,
                                        readHidden: read.hidden, readAllowed: read.allowed, readRehidden: read.rehidden)
        let batcher = ProgressBatcher { [ctx] in ctx.progress($0) }
        let r = try await ProcessRunner.run(exe, args, cwd: cwd, env: ["PYTHONUNBUFFERED": "1"], timeout: Double(min(input.int("timeout") ?? 600, 7200)),
                                            onLines: { batcher.add($0) })
        batcher.flush()
        var text = r.stdout
        if !r.stderr.isEmpty { text += (text.isEmpty ? "" : "\n") + "[stderr]\n" + r.stderr }
        if r.timedOut { text += "\n[timed out — rerun long commands with run_in_background]" }
        text = text.count > 30_000 ? "…" + String(text.suffix(30_000)) : text
        text += "\n[exit \(r.exitCode), \(String(format: "%.1f", r.duration)) s]"
        return ToolOutput(text, isError: r.exitCode != 0 || r.timedOut, filesWritten: Self.changed(cwd, since: before), exitCode: r.exitCode)
    }

    /// Cheap mtime snapshot of the top two directory levels, to fingerprint outputs a command wrote.
    static func snapshot(_ dir: URL) -> [String: Date] {
        var out: [String: Date] = [:]
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { return out }
        for case let u as URL in en {
            if en.level > 3 { en.skipDescendants(); continue }
            if let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true {
                out[u.path] = v.contentModificationDate
            }
            if out.count > 20_000 { break }
        }
        return out
    }

    static func changed(_ dir: URL, since before: [String: Date]) -> [String] {
        snapshot(dir).filter { before[$0.key] != $0.value }.map(\.key).sorted().prefix(200).map { $0 }
    }
}

struct PythonTool: Tool {
    let name = "python"
    let description = """
    Execute Python in a persistent interpreter (variables persist between calls, like a notebook). Use the \
    installed scientific stack (numpy, pandas, scipy, statsmodels, Biopython, RDKit, scanpy …). Print what \
    you need to see. Matplotlib figures are saved automatically to figures/ and their paths returned. Set \
    random seeds explicitly. For analyses that must be re-runnable, also save the code to a .py file.
    """
    var inputSchema: JSON {
        Schema.object(["code": Schema.string("Python source to execute"), "timeout": Schema.integer("Seconds (default 600)"),
                       "reset": Schema.bool("Clear all variables first"),
                       "env": Schema.string("Run in a skill's Python environment (skill name; see `skill_env`). Default: the user's python3")],
                      required: ["code"])
    }
    func effect(for input: JSON) -> ToolEffect { .executes }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let code = try input.required("code")
        let read = ctx.sandboxReadHidden
        var interpreter: String?
        if let env = input.str("env"), !env.isEmpty {
            switch SkillEnvTool.interpreter(env, ctx) {
            case .success(let py): interpreter = py
            case .failure(let why): return .error(why.message)
            }
        }
        let kernel = ctx.services.kernel.kernel(for: ctx.sessionId, cwd: ctx.writeRoot, sandbox: ctx.sandboxMode,
                                                protected: [ctx.workspace.appendingPathComponent(".sievesci"), ctx.workspace.appendingPathComponent(".git")],
                                                readHidden: read.hidden, readAllowed: read.allowed, readRehidden: read.rehidden, python: interpreter,
                                                tempDir: ctx.privateTempDir)
        if input.bool("reset") == true { _ = try await kernel.execute("", reset: true) }
        let r = try await kernel.execute(code, timeout: Double(input.int("timeout") ?? 600))
        var text = r.str("stdout") ?? ""
        if let e = r.str("stderr"), !e.isEmpty { text += "\n[stderr]\n" + e }
        let err = r.str("error")
        if let err { text += "\n[error]\n" + err }
        let figs = r["figures"]?.arrayValue?.compactMap(\.stringValue) ?? []
        var images: [ImageBlock] = []
        for f in figs.prefix(3) {
            if let d = FileManager.default.contents(atPath: f), d.count < 3_000_000 { images.append(ImageBlock(mediaType: "image/png", base64: d.base64EncodedString())) }
        }
        if !figs.isEmpty { text += "\n[figures]\n" + figs.joined(separator: "\n") }
        if text.count > 30_000 { text = String(text.prefix(15_000)) + "\n…\n" + String(text.suffix(15_000)) }
        return ToolOutput(text.isEmpty ? "(no output)" : text, isError: err != nil, images: images, filesWritten: figs, exitCode: err == nil ? 0 : 1)
    }
}

// MARK: - Files

struct ReadFileTool: Tool {
    let name = "read_file"
    let description = "Read a text file (with line numbers), an image (returned as an image), or a PDF (text extracted). Use offset/limit for large files."
    var inputSchema: JSON {
        Schema.object(["path": Schema.string("File path (relative to the workspace or absolute inside it)"),
                       "offset": Schema.integer("1-based line to start at"), "limit": Schema.integer("Max lines (default 2000)")], required: ["path"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let url = try ctx.resolve(try input.required("path"))
        try ctx.checkReadable(url)
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext), let d = FileManager.default.contents(atPath: url.path) {
            return ToolOutput("Image \(url.lastPathComponent) (\(d.count) bytes)", images: [ImageBlock(mediaType: ext == "jpg" ? "image/jpeg" : "image/\(ext)", base64: d.base64EncodedString())])
        }
        if ext == "pdf" {
            return ToolOutput(LiteratureLibrary.extractText(url).map { $0.truncated(80_000) } ?? "Could not extract text from this PDF.")
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .error("Cannot read \(url.path) as UTF-8 text.") }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max(1, input.int("offset") ?? 1)
        let limit = input.int("limit") ?? 2000
        let slice = lines.dropFirst(start - 1).prefix(limit)
        var out = slice.enumerated().map { String(format: "%6d\t", start + $0.offset) + String($0.element).truncated(2000, marker: "…") }.joined(separator: "\n")
        if start - 1 + slice.count < lines.count { out += "\n… (\(lines.count) lines total; continue with offset \(start + slice.count))" }
        return ToolOutput(out)
    }
}

struct WriteFileTool: Tool {
    let name = "write_file"
    let description = "Create or overwrite a file with the given content. Never overwrite raw data; write results to new files."
    var inputSchema: JSON {
        Schema.object(["path": Schema.string("File path"), "content": Schema.string("Full file content")], required: ["content", "path"])
    }
    func effect(for input: JSON) -> ToolEffect { .writesFiles }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let url = try ctx.resolve(try input.required("path"))
        try ctx.checkWritable(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = try input.required("content")
        let previous = try? String(contentsOf: url, encoding: .utf8)
        let previouslyValid = previous == nil ? true : (await SyntaxCheck.check(path: url.path) == nil)
        try content.write(to: url, atomically: true, encoding: .utf8)
        if let err = await SyntaxCheck.check(path: url.path) {
            if let previous, previouslyValid {
                try previous.write(to: url, atomically: true, encoding: .utf8)
                return .error("Rejected: the new content does not parse, so the file was left unchanged.\n\(err)")
            }
            return ToolOutput("Wrote \(url.path), but it does not parse — fix it:\n\(err)", isError: true, filesWritten: [url.path])
        }
        return ToolOutput("Wrote \(content.split(separator: "\n", omittingEmptySubsequences: false).count) lines to \(url.path)", filesWritten: [url.path])
    }
}

struct EditFileTool: Tool {
    let name = "edit_file"
    let description = "Replace an exact string in a file. old_string must match exactly once unless replace_all is set. Read the file first."
    var inputSchema: JSON {
        Schema.object(["path": Schema.string("File path"), "old_string": Schema.string("Exact text to replace"),
                       "new_string": Schema.string("Replacement"), "replace_all": Schema.bool("Replace every occurrence")],
                      required: ["new_string", "old_string", "path"])
    }
    func effect(for input: JSON) -> ToolEffect { .writesFiles }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let url = try ctx.resolve(try input.required("path"))
        try ctx.checkReadable(url)
        try ctx.checkWritable(url)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .error("Cannot read \(url.path).") }
        let old = try input.required("old_string"), new = try input.required("new_string")
        let n = text.components(separatedBy: old).count - 1
        if n == 0 { return .error("old_string not found in \(url.lastPathComponent).") }
        if n > 1 && input.bool("replace_all") != true { return .error("old_string occurs \(n) times; add context or set replace_all.") }
        let updated = input.bool("replace_all") == true ? text.replacingOccurrences(of: old, with: new)
            : text.replacingCharacters(in: text.range(of: old)!, with: new)
        let previouslyValid = await SyntaxCheck.check(path: url.path) == nil
        try updated.write(to: url, atomically: true, encoding: .utf8)
        if previouslyValid, let err = await SyntaxCheck.check(path: url.path) {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return .error("Rejected: this edit would leave \(url.lastPathComponent) unparseable, so it was not applied.\n\(err)")
        }
        return ToolOutput("Edited \(url.path) (\(n) replacement\(n == 1 ? "" : "s"))", filesWritten: [url.path])
    }
}

struct GlobTool: Tool {
    let name = "glob"
    let description = "Find files by glob pattern (e.g. **/*.fasta, data/*.csv). Returns paths sorted by modification time."
    var inputSchema: JSON { Schema.object(["pattern": Schema.string("Glob pattern"), "path": Schema.string("Directory (default workspace)")], required: ["pattern"]) }
    func effect(for input: JSON) -> ToolEffect { .readOnly }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let root = try ctx.resolve(input.str("path") ?? ".")
        let pattern = try input.required("pattern")
        let re = try NSRegularExpression(pattern: "^" + Self.globToRegex(pattern) + "$")
        var hits: [(String, Date)] = []
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return .error("No such directory.")
        }
        for case let u as URL in en {
            if ["node_modules", ".build", "__pycache__", ".venv"].contains(u.lastPathComponent) { en.skipDescendants(); continue }
            let rel = String(u.path.dropFirst(root.path.count + 1))
            if re.firstMatch(in: rel, range: NSRange(rel.startIndex..., in: rel)) != nil, (try? ctx.checkReadable(u)) != nil {
                hits.append((rel, (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
            }
            if hits.count >= 1000 { break }
        }
        return ToolOutput(hits.isEmpty ? "No files match." : hits.sorted { $0.1 > $1.1 }.map(\.0).joined(separator: "\n"))
    }

    static func globToRegex(_ g: String) -> String {
        var r = ""
        var i = g.startIndex
        while i < g.endIndex {
            let c = g[i]
            if c == "*" {
                let n = g.index(after: i)
                if n < g.endIndex && g[n] == "*" {
                    r += ".*"
                    i = g.index(after: n)
                    if i < g.endIndex && g[i] == "/" { i = g.index(after: i); r += "(?:/)?" }
                    continue
                }
                r += "[^/]*"
            } else if c == "?" { r += "[^/]" }
            else if c == "{" { r += "(?:" } else if c == "}" { r += ")" } else if c == "," { r += "|" }
            else { r += NSRegularExpression.escapedPattern(for: String(c)) }
            i = g.index(after: i)
        }
        return r
    }
}

struct GrepTool: Tool {
    let name = "grep"
    let description = "Search file contents with a regular expression (ripgrep when installed). Returns file:line:text matches."
    var inputSchema: JSON {
        Schema.object(["pattern": Schema.string("Regular expression"), "path": Schema.string("Directory or file (default workspace)"),
                       "glob": Schema.string("Only files matching this glob, e.g. *.py"), "ignore_case": Schema.bool("Case-insensitive")], required: ["pattern"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let root = try ctx.resolve(input.str("path") ?? ".")
        let pattern = try input.required("pattern")
        // Blind agents take the per-file path below, where every file passes checkReadable.
        if ProcessRunner.which("rg") != nil && !ctx.isBlind {
            var args = ["-n", "--no-heading", "--max-count", "50", "-M", "400"]
            if input.bool("ignore_case") == true { args.append("-i") }
            if let g = input.str("glob") { args += ["-g", g] }
            args += ["-e", pattern, root.path]
            let r = try await ProcessRunner.run("rg", args, timeout: 60)
            return ToolOutput(r.stdout.isEmpty ? "No matches." : r.stdout.truncated(30_000))
        }
        let re = try NSRegularExpression(pattern: pattern, options: input.bool("ignore_case") == true ? [.caseInsensitive] : [])
        let globRe = try input.str("glob").map { try NSRegularExpression(pattern: "^" + GlobTool.globToRegex($0) + "$") }
        var out: [String] = []
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let u = en?.nextObject() as? URL, out.count < 500 {
            let name = u.lastPathComponent
            if let g = globRe, g.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) == nil { continue }
            guard (try? ctx.checkReadable(u)) != nil, let t = try? String(contentsOf: u, encoding: .utf8) else { continue }
            for (i, l) in t.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let s = String(l)
                if re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { out.append("\(u.path):\(i + 1):\(s.truncated(400, marker: "…"))") }
            }
        }
        return ToolOutput(out.isEmpty ? "No matches." : out.joined(separator: "\n"))
    }
}

// MARK: - Search & literature

struct WebSearchTool: Tool {
    let name = "web_search"
    let description = """
    Search the international web. Uses the model provider's native search when available (Claude API, \
    DeepSeek, GLM), otherwise the configured search API (Brave/Tavily/Exa/SearXNG/Google). Content farms are \
    excluded. Use before forming judgements and cite the URLs you rely on.
    """
    var inputSchema: JSON {
        Schema.object(["query": Schema.string("Search query (English usually gives the best scientific results)"),
                       "allowed_domains": Schema.array("Only these domains (optional)", items: ["type": "string"])], required: ["query"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let q = try input.required("query")
        let allowed = input["allowed_domains"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let s = ctx.services
        var errors: [String] = []
        if let native = s.nativeSearch {
            do {
                let r = try await native.search(q, blockedDomains: s.webSearch.config.excludedDomains, allowedDomains: allowed)
                let hits = r.hits.filter { !s.webSearch.excluded($0.url) }
                if !hits.isEmpty {
                    s.log("native_web_search", actor: "host", ["query": .string(q), "endpoint": .string(native.endpoint.baseURL), "searches": .int(r.searches),
                                                               "input": .int(r.usage.input), "cache_read": .int(r.usage.cacheRead), "output": .int(r.usage.output)])
                    return ToolOutput("Results (provider-native search):\n" + hits.enumerated().map { "\($0.offset + 1). \($0.element.title)\n   \($0.element.url)" }.joined(separator: "\n")
                                      + "\n\nSearch digest (verify against the sources before relying on it):\n" + r.summary.truncated(6000))
                }
                errors.append("native search returned no results")
            } catch { errors.append("native: \(error.localizedDescription.truncated(200))") }
        }
        do {
            var hits = try await s.webSearch.search(q, count: 8)
            if !allowed.isEmpty { hits = hits.filter { h in allowed.contains { URL(string: h.url)?.host?.hasSuffix($0) == true } } }
            let backend = s.webSearch.effectiveBackend
            let fallback = backend != s.webSearch.config.backend
                ? "(DuckDuckGo, best effort: no key is set for \(s.webSearch.config.backend.rawValue))\n" : ""
            if !hits.isEmpty {
                return ToolOutput(fallback + hits.enumerated().map { "\($0.offset + 1). \($0.element.title)\n   \($0.element.url)\($0.element.published.map { " (\($0))" } ?? "")\n   \($0.element.snippet.truncated(400, marker: "…"))" }.joined(separator: "\n"))
            }
            errors.append("\(backend.rawValue): no results")
        } catch { errors.append("\(s.webSearch.effectiveBackend.rawValue): \(error.localizedDescription.truncated(200))") }
        // A search that finds nothing is not grounding; it fails so it cannot satisfy the gate.
        return ToolOutput("Web search failed: " + errors.joined(separator: "; ") + ". Configure a search provider in Settings → Web search.", isError: true)
    }
}

struct WebFetchTool: Tool {
    let name = "web_fetch"
    let description = "Fetch a web page and return its readable text."
    var inputSchema: JSON { Schema.object(["url": Schema.string("http(s) URL")], required: ["url"]) }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        ToolOutput(try await ctx.services.webSearch.fetchText(try input.required("url")))
    }
}

struct LiteratureSearchTool: Tool {
    let name = "literature_search"
    let description = """
    Search scholarly literature: OpenAlex (all fields, with open-access links), Europe PMC (biomedical, incl. \
    PubMed and preprints), arXiv. Returns candidates with DOI/PMID/arXiv ids. Add the ones you rely on to the \
    task library with `paper_fetch`.
    """
    var inputSchema: JSON {
        Schema.object(["query": Schema.string("Search query"), "source": Schema.stringEnum("Which index", ["all", "openalex", "europepmc", "arxiv"]),
                       "limit": Schema.integer("Per source, default 8"), "from_year": Schema.integer("Earliest publication year")], required: ["query"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let q = try input.required("query")
        let src = input.str("source") ?? "all"
        let lim = input.int("limit") ?? 8
        let lib = ctx.services.library
        var results: [PaperRecord] = []
        var errors: [String] = []
        if src == "all" || src == "openalex" { do { results += try await lib.searchOpenAlex(q, limit: lim, fromYear: input.int("from_year")) } catch { errors.append("OpenAlex: \(error.localizedDescription)") } }
        if src == "all" || src == "europepmc" { do { results += try await lib.searchEuropePMC(q, limit: lim) } catch { errors.append("Europe PMC: \(error.localizedDescription)") } }
        if src == "all" || src == "arxiv" { do { results += try await lib.searchArXiv(q, limit: lim) } catch { errors.append("arXiv: \(error.localizedDescription)") } }
        var seen = Set<String>()
        let unique = results.filter { r in
            let k = (r.doi ?? r.arxiv ?? r.title).lowercased()
            return seen.insert(k).inserted
        }
        if unique.isEmpty { return ToolOutput(errors.isEmpty ? "No results. Refine the query." : errors.joined(separator: "\n"), isError: true) }
        ctx.services.emit(.literature(agentId: ctx.sessionId, action: .searched, key: q, title: q, detail: "\(unique.count) candidates"))
        let text = unique.enumerated().map { i, r in
            let ids = [r.doi.map { "doi:\($0)" }, r.pmid.map { "pmid:\($0)" }, r.arxiv.map { "arXiv:\($0)" }].compactMap { $0 }.joined(separator: " ")
            return "\(i + 1). \(r.title) — \(r.authors.prefix(3).joined(separator: ", "))\(r.authors.count > 3 ? " et al." : "") (\(r.year.map(String.init) ?? "n.d."), \(r.venue ?? r.source))\(r.citedBy.map { " · cited \($0)×" } ?? "")\n   \(ids)\(r.oaPdfURL != nil ? "  [open access]" : "")\n   \((r.abstract ?? "").truncated(350, marker: "…"))"
        }.joined(separator: "\n")
        return ToolOutput(text + (errors.isEmpty ? "" : "\n\n(partial: \(errors.joined(separator: "; ")))"))
    }
}

struct PaperFetchTool: Tool {
    let name = "paper_fetch"
    let description = """
    Add a paper to this task's library by DOI, PMID, PMCID or arXiv id: records metadata and BibTeX, downloads the \
    open-access PDF when one exists, and extracts its text. Returns the citation key to use as [@key] and in \
    `@cite key` code comments.
    """
    var inputSchema: JSON { Schema.object(["ref": Schema.string("DOI (10.xxxx/…), PMID, PMCID or arXiv id")], required: ["ref"]) }
    func effect(for input: JSON) -> ToolEffect { .readOnly }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let raw = try input.required("ref").trimmingCharacters(in: .whitespaces)
        let lib = ctx.services.library
        if let existing = lib.find(PaperRef.normalize(raw).1) {
            return ToolOutput("Already in library as [@\(existing.key)]: \(existing.title)")
        }
        let (kind, id) = PaperRef.normalize(raw)
        var rec: PaperRecord?
        var errors: [String] = []
        func attempt(_ f: () async throws -> PaperRecord?) async {
            guard rec == nil else { return }
            do { rec = try await f() } catch { errors.append(error.localizedDescription.truncated(160)) }
        }
        switch kind {
        case .arxiv:
            await attempt { try await lib.searchArXiv("id:\(id)", limit: 1).first }
        case .doi:
            // Europe PMC first (keyless), then OpenAlex (metered; needs OPENALEX_API_KEY for heavy use).
            await attempt { try await lib.searchEuropePMC("DOI:\"\(id)\"", limit: 1).first.flatMap { $0.doi?.lowercased() == id.lowercased() ? $0 : nil } }
            await attempt { try await lib.searchOpenAlex("doi:\(id)", limit: 1).first.flatMap { $0.doi?.lowercased() == id.lowercased() ? $0 : nil } }
            await attempt { try await lib.crossref(doi: id) }
        case .pmid:
            await attempt { try await lib.searchEuropePMC("EXT_ID:\(id) AND SRC:MED", limit: 1).first }
        case .pmcid:
            await attempt { try await lib.searchEuropePMC("PMCID:\(id)", limit: 1).first }
        case .unknown:
            await attempt { try await lib.searchEuropePMC(id, limit: 1).first }
        }
        guard let found = rec else {
            ctx.services.emit(.literature(agentId: ctx.sessionId, action: .flagged, key: raw, title: raw, detail: "could not be resolved"))
            return .error("Could not resolve \(raw) (\(kind)) via Europe PMC, OpenAlex, Crossref or arXiv." + (errors.isEmpty ? "" : " Errors: " + errors.joined(separator: " | ")))
        }
        let added = lib.add(found)
        let r = try await lib.download(added.key)
        let abstractOnly = lib.text(r.key)?.hasPrefix("[abstract only") ?? true
        ctx.services.emit(.literature(agentId: ctx.sessionId, action: .added, key: r.key, title: r.title,
                                      detail: "\(r.year.map(String.init) ?? "n.d.") · \(r.venue ?? r.source) · \(abstractOnly ? "abstract only" : "full text")"))
        let status = r.pdfPath != nil ? "Open-access PDF saved (sha256 \(r.pdfSHA256?.prefix(12) ?? "")); text extracted."
            : (abstractOnly ? (lib.downloadPDFs ? "No open-access full text; abstract stored." : "PDF downloads are off in Settings; abstract stored. Ask the user to turn them on if the full text is needed.")
               : "Open-access full text retrieved (Europe PMC).")
        return ToolOutput("Added [@\(r.key)] \(r.title) (\(r.year.map(String.init) ?? "n.d.")).\n" + status
            + "\nRead passages with paper_read.", facts: ["paper": .string(r.key)])
    }
}

struct PaperReadTool: Tool {
    let name = "paper_read"
    let description = "Read a library paper's text: passages matching a query (with surrounding context), or a page range of the full text."
    var inputSchema: JSON {
        Schema.object(["key": Schema.string("Citation key"), "query": Schema.string("Words to find (optional)"),
                       "offset": Schema.integer("Character offset when reading sequentially"), "length": Schema.integer("Characters, default 12000")], required: ["key"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let key = try input.required("key")
        guard let text = ctx.services.library.text(key) else { return .error("No text for [@\(key)]; run paper_fetch first.") }
        ctx.services.emit(.literature(agentId: ctx.sessionId, action: .read, key: key, title: ctx.services.library.find(key)?.title ?? key,
                                      detail: input.str("query").map { "passages about “\($0)”" } ?? "full text"))
        if let q = input.str("query"), !q.isEmpty {
            let terms = q.lowercased().split(separator: " ").map(String.init).filter { $0.count > 2 }
            let paras = text.components(separatedBy: "\n\n")
            let scored = paras.enumerated().map { (i, p) -> (Int, Int) in (i, terms.reduce(0) { $0 + p.lowercased().components(separatedBy: $1).count - 1 }) }
                .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(6)
            if scored.isEmpty { return ToolOutput("No passage in [@\(key)] mentions: \(q)") }
            return ToolOutput(scored.map { "[@\(key) ¶\($0.0)] " + paras[$0.0].truncated(1500, marker: "…") }.joined(separator: "\n\n"))
        }
        let off = input.int("offset") ?? 0
        let len = input.int("length") ?? 12_000
        let start = text.index(text.startIndex, offsetBy: min(off, text.count))
        let end = text.index(start, offsetBy: min(len, text.distance(from: start, to: text.endIndex)))
        return ToolOutput(String(text[start..<end]) + (end < text.endIndex ? "\n… (\(text.count) chars; continue at offset \(off + len))" : ""))
    }
}

struct PaperCodeLinksTool: Tool {
    let name = "paper_code_links"
    let description = "Index of links between library papers and the code that implements them (from `@cite key` comments, DOIs, arXiv ids, PMIDs in source files). Filter by paper key or file."
    var inputSchema: JSON { Schema.object(["key": Schema.string("Citation key (optional)"), "file": Schema.string("File path substring (optional)")]) }
    func effect(for input: JSON) -> ToolEffect { .readOnly }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        var links = CodePaperLinker.scan(workspace: ctx.workspace, library: ctx.services.library)
        if let k = input.str("key") { links = links.filter { $0.paperKey == k || $0.identifier == k } }
        if let f = input.str("file") { links = links.filter { $0.file.contains(f) } }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(links).write(to: ctx.services.library.dir.appendingPathComponent("links.json"))
        if links.isEmpty { return ToolOutput("No paper↔code links found. Annotate implementations with `# @cite <key> <locator>`.") }
        return ToolOutput(links.map { "\($0.file):\($0.line)  → \($0.paperKey.map { "[@\($0)]" } ?? "\($0.identifier) (not in library)")\($0.locator.map { " \($0)" } ?? "")" }.joined(separator: "\n"))
    }
}

// MARK: - Research state

struct UpdatePlanTool: Tool {
    let name = "update_plan"
    let description = """
    Manage the research plan. action "set": write or revise the whole plan (goal, background with [@key] \
    citations, hypotheses with prediction + falsification, steps with criteria and checkpoint flags) — needs \
    prior web and literature searches, and a rationale for revisions. Mark steps that need no other step's \
    results `parallel: true` (the rest `depends_on`): SieveSci runs pending parallel steps on workers at once \
    and returns their reports in this call's result. action "step": change one step's status; marking a \
    checkpoint "done" requires evidence receipt ids and triggers an independent review.
    """
    var inputSchema: JSON {
        let hyp = Schema.object(["id": Schema.string("H1…"), "statement": Schema.string("Hypothesis"), "prediction": Schema.string("What you expect to observe if true"),
                                 "falsification": Schema.string("Observation that would refute it"), "status": Schema.stringEnum("Status", ["open", "supported", "refuted", "inconclusive"])],
                                required: ["falsification", "id", "prediction", "statement"])
        let step = Schema.object(["id": Schema.string("S1…"), "title": Schema.string("Step"), "detail": Schema.string("How"),
                                  "status": Schema.stringEnum("Status", ["pending", "in_progress", "done", "skipped", "failed"]),
                                  "checkpoint": Schema.bool("Results matter for the conclusion; reviewed when done"), "criteria": Schema.string("Soft acceptance criteria"),
                                  "parallel": Schema.bool("Needs no other step's results: SieveSci runs pending parallel steps on workers at once"),
                                  "depends_on": Schema.array("Ids of the steps whose results this step needs ([] for none)", items: ["type": "string"])],
                                 required: ["id", "title"])
        return Schema.object([
            "action": Schema.stringEnum("set | step", ["set", "step"]),
            "goal": Schema.string("Research goal (set)"), "background": Schema.string("What the searches established, with [@key] (set)"),
            "hypotheses": Schema.array("Hypotheses (set)", items: hyp), "steps": Schema.array("Plan steps (set)", items: step),
            "rationale": Schema.string("Why the plan changed (required for revisions)"),
            "step_id": Schema.string("Step to update (step)"), "status": Schema.stringEnum("New status (step)", ["pending", "in_progress", "done", "skipped", "failed"]),
            "evidence": Schema.array("Receipt ids proving the step (step)", items: ["type": "string"]), "note": Schema.string("Result summary (step)"),
        ], required: ["action"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard ctx.role == .main else { return .error("Only the main agent manages the plan.") }
        let rp = ctx.services.research
        if input.str("action") == "set" {
            let hs: [Hypothesis] = (input["hypotheses"]?.arrayValue ?? []).map {
                Hypothesis(id: $0.str("id") ?? "H?", statement: $0.str("statement") ?? "", prediction: $0.str("prediction") ?? "",
                           falsification: $0.str("falsification") ?? "", status: $0.str("status") ?? "open", registeredAt: Date())
            }
            let ss: [PlanStep] = (input["steps"]?.arrayValue ?? []).map {
                PlanStep(id: $0.str("id") ?? "S?", title: $0.str("title") ?? "", detail: $0.str("detail") ?? "", status: $0.str("status") ?? "pending",
                         checkpoint: $0.bool("checkpoint") ?? false, criteria: $0.str("criteria") ?? "", evidence: [], note: "",
                         parallel: $0.bool("parallel"), dependsOn: $0["depends_on"]?.arrayValue?.compactMap(\.stringValue))
            }
            let (d, rev) = rp.setPlan(goal: input.str("goal") ?? "", background: input.str("background") ?? "", hypotheses: hs, steps: ss,
                                      rationale: input.str("rationale") ?? "")
            if case .refuse(let m) = d { return .error(m) }
            ctx.services.emit(.planChanged(rp.snapshot))
            var facts: [String: JSON] = [:]
            if let rev, !rev.changedCriteria.isEmpty {
                facts["plan_revision"] = ["after_results": .bool(rev.afterResults), "changed": .array(rev.changedCriteria.map { .string($0) })]
            }
            return ToolOutput("Plan saved.\n\n" + rp.snapshot.markdown, facts: facts)
        }
        let id = try input.required("step_id")
        let (d, checkpoint) = rp.updateStep(id: id, status: input.str("status") ?? "done",
                                            evidence: input["evidence"]?.arrayValue?.compactMap(\.stringValue) ?? [], note: input.str("note") ?? "")
        if case .refuse(let m) = d { return .error(m) }
        ctx.services.emit(.planChanged(rp.snapshot))
        if let step = checkpoint {
            if case .refuse(let m) = rp.requireGrounding("passing a checkpoint") { return .error(m) }
            let review = await ctx.services.supervisor.reviewCheckpoint(step)
            return ToolOutput("Step \(id) marked done.\n\n" + review)
        }
        return ToolOutput("Step \(id) → \(input.str("status") ?? "done").")
    }
}

struct ClaimFindingTool: Tool {
    let name = "claim_finding"
    let description = """
    Register a finding you consider significant, novel or a breakthrough. An independent verifier who cannot \
    see your code re-implements the analysis from the raw data and returns verified / refuted / inconclusive. \
    Only verified findings may be stated as conclusions. Requires prior web + literature search.
    """
    var inputSchema: JSON {
        Schema.object(["statement": Schema.string("The finding, precisely, with the key numbers"),
                       "success_criteria": Schema.string("What result would confirm it (stated before verification)"),
                       "evidence": Schema.array("Receipt ids of the analysis that produced it", items: ["type": "string"]),
                       "data_paths": Schema.array("Raw input data files the verifier may read", items: ["type": "string"])],
                      required: ["data_paths", "evidence", "statement", "success_criteria"])
    }
    /// The verifier re-runs the analysis, so registering a claim is approved like running code.
    func effect(for input: JSON) -> ToolEffect { .executes }

    /// A data path that would expose the main agent's work: the workspace itself (or a parent),
    /// or anything inside SieveSci's task record.
    static func unblindingPath(_ paths: [String], _ ctx: ToolContext) -> String? {
        let ws = ToolContext.real(ctx.workspace.path)
        let record = ToolContext.real(ctx.workspace.appendingPathComponent(".sievesci").path)
        for raw in paths {
            // Data outside the workspace (a shared /data volume) is fine unless it contains the workspace.
            let e = (raw as NSString).expandingTildeInPath
            let p = ToolContext.real(e.hasPrefix("/") ? e : ctx.workspace.appendingPathComponent(e).path)
            if ToolContext.isUnder(ws, p) || ToolContext.isUnder(p, record) { return raw }
        }
        return nil
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard ctx.role == .main else { return .error("Only the main agent registers claims.") }
        if case .refuse(let m) = ctx.services.research.requireGrounding("claiming a finding") { return .error(m) }
        let ev = input["evidence"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let bad = ev.filter { ctx.ledger.receipt($0)?.success != true }
        if ev.isEmpty || !bad.isEmpty { return .error("Cite the successful receipts that produced this result\(bad.isEmpty ? "" : " (invalid: \(bad.joined(separator: ", ")))").") }
        let dataPaths = input["data_paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let bad = Self.unblindingPath(dataPaths, ctx) {
            return .error("data_paths must name the raw input files or data directories, not \(bad): the verifier would then see your code and outputs.")
        }
        let claim = ctx.services.claims.add(statement: try input.required("statement"), criteria: try input.required("success_criteria"),
                                            evidence: ev, dataPaths: dataPaths)
        ctx.services.emit(.claimsChanged(ctx.services.claims.snapshot))
        let report = await ctx.services.supervisor.verify(claim)
        return ToolOutput(report, facts: ["claim": .string(claim.id)])
    }
}

struct TodoWriteTool: Tool {
    let name = "todo_write"
    let description = "Maintain your short-term working checklist for the current turn (separate from the research plan). Exactly one item in_progress."
    var inputSchema: JSON {
        Schema.object(["todos": Schema.array("Full list", items: Schema.object(["content": Schema.string("Task"),
                                                                                "status": Schema.stringEnum("Status", ["pending", "in_progress", "completed"])],
                                                                               required: ["content", "status"]))], required: ["todos"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let items = (input["todos"]?.arrayValue ?? []).map { TodoList.Item(content: $0.str("content") ?? "", status: $0.str("status") ?? "pending") }
        if items.filter({ $0.status == "in_progress" }).count > 1 { return .error("Only one item may be in_progress.") }
        ctx.services.todos.set(items)
        return ToolOutput(items.map { ($0.status == "completed" ? "☒ " : $0.status == "in_progress" ? "◐ " : "☐ ") + $0.content }.joined(separator: "\n"))
    }
}

struct GoalTool: Tool {
    let name = "goal"
    let description = "Read the session goal, mark it complete (note) or blocked (reason), or wait for the user's decision (note = the one question). Only the user creates, pauses or edits goals."
    var inputSchema: JSON { Schema.object(["action": Schema.stringEnum("Action", ["get", "complete", "wait", "blocked"]), "note": Schema.string("Completion note, the question for the user, or the blocking reason")], required: ["action"]) }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let g = ctx.services.goal
        switch input.str("action") {
        case "complete": return ToolOutput(g.modelComplete(note: input.str("note") ?? ""))
        case "blocked": return ToolOutput(g.modelBlocked(reason: input.str("note") ?? ""))
        case "wait": return ToolOutput(g.modelWait(question: input.str("note") ?? ""))
        default:
            guard let cur = g.current else { return ToolOutput("No goal set.") }
            return ToolOutput("Goal: \(cur.objective)\nPhase: \(cur.phase.rawValue), round \(cur.roundsStarted)\(cur.maxRounds.map { "/\($0)" } ?? "")")
        }
    }
}

struct TaskTool: Tool {
    let name = "task"
    let description = """
    Delegate a self-contained subtask to a worker agent with a fresh context (e.g. a literature sweep on one \
    sub-question, a data-cleaning pass). It shares the task library and receipts; it writes only under \
    .sievesci/tasks/<task>/workers. Returns its report. Give it everything it needs in the prompt.
    """
    var inputSchema: JSON { Schema.object(["description": Schema.string("3-6 word label"), "prompt": Schema.string("Full instructions")], required: ["description", "prompt"]) }
    /// The worker may run code, so starting one is approved like running code.
    func effect(for input: JSON) -> ToolEffect { .executes }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard ctx.role == .main else { return .error("Subagents cannot spawn further subagents.") }
        let w = ctx.services.makeSubagent(role: .worker, purpose: input.str("description") ?? "subtask")
        let reply = try await w.send(try input.required("prompt"))
        return ToolOutput("<worker_report label=\"\(input.str("description") ?? "")\">\n\(reply?.plainText ?? "(no report)")\n</worker_report>")
    }
}

struct SkillTool: Tool {
    let name = "skill"
    let description = "Load a skill's full instructions by name (see <available_skills>). Follow them for the matching task."
    var inputSchema: JSON { Schema.object(["name": Schema.string("Skill name")], required: ["name"]) }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let n = try input.required("name")
        guard let body = ctx.services.skills.body(n), let skill = ctx.services.skills.skill(n) else { return .error("No skill named \(n).") }
        let env = ctx.services.environments.describe(skill, secrets: ctx.services.secrets)
        return ToolOutput(body.truncated(60_000) + (env.map { "\n" + $0 } ?? ""))
    }
}

struct ReceiptTool: Tool {
    let name = "receipt"
    let description = "Read the full recorded output of a tool call by its receipt id (e.g. r12)."
    var inputSchema: JSON { Schema.object(["id": Schema.string("Receipt id")], required: ["id"]) }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let id = try input.required("id")
        guard let r = ctx.ledger.receipt(id) else { return .error("No receipt \(id).") }
        // The verifier sees only its own work: other roles' receipts hold the analysis it must re-derive.
        if ctx.role == .verifier && r.role != .verifier {
            return .error("Receipt \(id) belongs to another agent and is hidden from the verifier so its check stays independent.")
        }
        return ToolOutput("\(r.id) · \(r.tool) · \(r.success ? "ok" : "FAILED") · role \(r.role.rawValue)\nargs: \(r.argsSummary)\nfiles: \(r.filesWritten.keys.joined(separator: ", "))\n---\n" + (ctx.ledger.output(id) ?? r.outputExcerpt).truncated(40_000))
    }
}

struct JobOutputTool: Tool {
    let name = "job_output"
    let description = """
    Read a background job's output: by default only the lines you have not seen yet (omit id to list jobs \
    with their state). You do not need to call this to find out whether a job finished — you are notified.
    """
    var inputSchema: JSON {
        Schema.object(["id": Schema.string("Job id, e.g. job3"), "all": Schema.bool("Last max_lines lines instead of only new ones"),
                       "max_lines": Schema.integer("Default 200")])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let jobs = ctx.services.jobs
        let visible = jobs.all.filter { ctx.role != .verifier || $0.agentId == ctx.sessionId }
        guard let id = input.str("id") else {
            let all = visible
            return ToolOutput(all.isEmpty ? "No jobs." : all.map {
                "\($0.id)  \($0.running ? "running" : "exit \($0.exitCode ?? -1)")  \($0.lineCount) lines  \($0.label.truncated(100))"
            }.joined(separator: "\n"))
        }
        guard visible.contains(where: { $0.id == id }) else { return .error("No job \(id).") }
        guard let out = jobs.output(id, onlyNew: input.bool("all") != true, maxLines: input.int("max_lines") ?? 200) else { return .error("No job \(id).") }
        return ToolOutput(out)
    }
}

struct JobWatchTool: Tool {
    let name = "job_watch"
    let description = """
    Monitor without polling. Either (a) follow a log file something else writes — a cluster job \
    (SLURM/LSF/PBS .out), nohup output, an instrument export — as a streaming job: give `path`, plus \
    `notify_on` (regex) and/or `until` (regex that marks completion, e.g. 'DONE|Exited with exit code'); or \
    (b) add a `notify_on` pattern to a running job (`id`); or (c) `stop` a job. You are notified on \
    matches, errors, completion and stalls.
    """
    var inputSchema: JSON {
        Schema.object(["path": Schema.string("Log file to follow"), "id": Schema.string("Existing job id"),
                       "notify_on": Schema.string("Regex"), "until": Schema.string("Regex marking completion (path mode)"),
                       "from_start": Schema.bool("Read the file from the beginning (default: only new lines)"),
                       "stall_minutes": Schema.number("Notify if nothing new for this many minutes"),
                       "stop": Schema.bool("Stop job `id`")])
    }
    func effect(for input: JSON) -> ToolEffect { input.bool("stop") == true ? .executes : .readOnly }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let jobs = ctx.services.jobs
        if let id = input.str("id") {
            if input.bool("stop") == true { return jobs.stop(id) ? ToolOutput("Stopping \(id).") : .error("\(id) is not running.") }
            guard let p = input.str("notify_on") else { return .error("Give notify_on, or stop: true.") }
            return jobs.addWatch(id, pattern: p) ? ToolOutput("Watching \(id) for /\(p)/.") : .error("\(id) is not running or the regex is invalid.")
        }
        guard let path = input.str("path") else { return .error("Give path (follow a file) or id (existing job).") }
        let url = try ctx.resolve(path)
        try ctx.checkReadable(url)
        let id = jobs.watchFile(url, agentId: ctx.sessionId, notifyOn: input.str("notify_on"), until: input.str("until"),
                                stallMinutes: input["stall_minutes"]?.numberValue, fromStart: input.bool("from_start") == true)
        ctx.services.log("job_start", actor: ctx.role.rawValue, ["job": .string(id), "tail": .string(path), "agent": .string(ctx.sessionId)])
        return ToolOutput("Following \(path) as \(id); new lines stream to the user. You will be notified on matches, errors\(input.str("until") != nil ? ", completion" : "") and stalls. Do not poll.",
                          facts: ["job": .string(id)])
    }
}
